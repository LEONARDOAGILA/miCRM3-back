-- ============================================================================
-- GRUPOS DE USUARIOS (esquema seguridad), al estilo de las unidades
-- organizativas de Active Directory: un árbol de grupos y cada usuario
-- pertenece a UN grupo (users.grupo_id, 1 grupo → N usuarios).
--
-- El grupo lleva los valores POR DEFECTO que heredan sus usuarios (base para
-- la carga masiva): perfil_id, chorario_id, es_administrador y tipo_acceso
-- (SISTEMA / WEB). En este paso type_user sigue existiendo en users y se
-- sigue grabando; el grupo sólo lo sugiere desde el front.
--
--   seguridad.fn_grupos_listar()                          árbol completo (plano, con nivel y ruta)
--   seguridad.fn_grupos_obtener(id)                       un grupo
--   seguridad.fn_grupos_crear(...)                        alta (orden = último entre sus hermanos)
--   seguridad.fn_grupos_modificar(...)                    modificación (cambio de padre con control de ciclos)
--   seguridad.fn_grupos_eliminar(...)                     baja (sin usuarios ni subgrupos)
--   seguridad.fn_grupos_mover(id, padre, antes_de, ...)   arrastrar y soltar (como fn_menus_mover)
--   seguridad.fn_usuarios_mover_grupo(ids, grupo, ...)    arrastrar usuarios a un grupo
--   seguridad.fn_usuarios_listar_por_grupo(...)           grilla de usuarios de un grupo (y subgrupos)
--
-- Además se REEMPLAZAN fn_usuarios_crear / modificar / obtener /
-- listar_paginado para que reciban y devuelvan grupo_id y grupo_nombre
-- (nuevo parámetro p_grupo_id justo después de p_chorario_id; en modificar
-- NULL = no cambia y 0 = dejar sin grupo).
--
-- Errores de negocio (RAISE EXCEPTION, el back los traduce a 4xx):
--   P0001 nombre obligatorio     P0006 nombre duplicado entre hermanos
--   P0008 perfil inexistente     P0009 horario inexistente
--   P0010 tipo de acceso inválido
--   P0013 el grupo no existe     P0014 tiene usuarios o subgrupos
--   P0016 el grupo padre / destino no existe
--   P0017 ciclo (no puede colgar de sí mismo ni de un descendiente)
-- Idempotente: IF NOT EXISTS / CREATE OR REPLACE.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- TABLA
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS seguridad.grupos (
    id               bigserial PRIMARY KEY,
    padre_id         bigint       REFERENCES seguridad.grupos(id) ON DELETE RESTRICT,
    nombre           varchar(100) NOT NULL,
    descripcion      text,
    orden            integer      NOT NULL DEFAULT 0,
    perfil_id        bigint       REFERENCES seguridad.perfiles(id),
    chorario_id      bigint       REFERENCES seguridad.chorarios(id),
    es_administrador boolean      NOT NULL DEFAULT false,
    tipo_acceso      varchar(10)  NOT NULL DEFAULT 'SISTEMA',
    activo           boolean      NOT NULL DEFAULT true,
    created_at       timestamptz  DEFAULT now(),
    updated_at       timestamptz  DEFAULT now(),
    created_by       varchar,
    updated_by       varchar,
    CONSTRAINT ck_grupos_tipo_acceso CHECK (tipo_acceso IN ('SISTEMA', 'WEB'))
);

COMMENT ON TABLE  seguridad.grupos IS 'Grupos de usuarios (árbol, como las OU de Active Directory); un usuario pertenece a un grupo';
COMMENT ON COLUMN seguridad.grupos.perfil_id        IS 'Perfil por defecto de los usuarios del grupo';
COMMENT ON COLUMN seguridad.grupos.chorario_id      IS 'Horario por defecto de los usuarios del grupo';
COMMENT ON COLUMN seguridad.grupos.es_administrador IS 'Los usuarios del grupo administran (equivale a type_user 1/2)';
COMMENT ON COLUMN seguridad.grupos.tipo_acceso      IS 'SISTEMA (type_user 3) o WEB (type_user 4)';

-- Nombre único entre hermanos (la raíz cuenta como padre 0)
CREATE UNIQUE INDEX IF NOT EXISTS uk_grupos_padre_nombre ON seguridad.grupos (COALESCE(padre_id, 0), UPPER(nombre));
CREATE INDEX IF NOT EXISTS ix_grupos_padre ON seguridad.grupos (padre_id, orden);

-- Auditoría: los mismos tres triggers que seguridad.users
DROP TRIGGER IF EXISTS trg_grupos_audit ON seguridad.grupos;
CREATE TRIGGER trg_grupos_audit AFTER INSERT OR DELETE OR UPDATE ON seguridad.grupos
    FOR EACH ROW EXECUTE FUNCTION auditoria.fn_auditar_cambios();
DROP TRIGGER IF EXISTS trigger_grupos_set_users ON seguridad.grupos;
CREATE TRIGGER trigger_grupos_set_users BEFORE INSERT OR UPDATE ON seguridad.grupos
    FOR EACH ROW EXECUTE FUNCTION auditoria.fn_set_audit_users();
DROP TRIGGER IF EXISTS trigger_grupos_updated_at ON seguridad.grupos;
CREATE TRIGGER trigger_grupos_updated_at BEFORE UPDATE ON seguridad.grupos
    FOR EACH ROW EXECUTE FUNCTION auditoria.fn_update_updated_at_column();

-- El usuario pertenece a un grupo (opcional: los usuarios de antes quedan sin grupo)
ALTER TABLE seguridad.users ADD COLUMN IF NOT EXISTS grupo_id bigint REFERENCES seguridad.grupos(id) ON DELETE SET NULL;
CREATE INDEX IF NOT EXISTS ix_users_grupo ON seguridad.users (grupo_id);
COMMENT ON COLUMN seguridad.users.grupo_id IS 'Grupo (seguridad.grupos) al que pertenece el usuario';

-- ---------------------------------------------------------------------------
-- Fila de un grupo en json (lo comparten obtener / crear / modificar)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION seguridad.fn_grupos_json(p_id bigint)
RETURNS jsonb
LANGUAGE sql
STABLE
AS $function$
    WITH RECURSIVE ruta AS (
        SELECT g.id, g.padre_id, g.nombre::text AS ruta, 0 AS nivel
          FROM seguridad.grupos g WHERE g.id = p_id
        UNION ALL
        SELECT p.id, p.padre_id, p.nombre || ' / ' || ruta.ruta, ruta.nivel + 1
          FROM seguridad.grupos p JOIN ruta ON p.id = ruta.padre_id
    )
    SELECT jsonb_build_object(
        'id',               g.id,
        'padre_id',         g.padre_id,
        'padre_nombre',     pg.nombre,
        'nombre',           g.nombre,
        'descripcion',      g.descripcion,
        'orden',            g.orden,
        'perfil_id',        g.perfil_id,
        'perfil_nombre',    p.nombre,
        'chorario_id',      g.chorario_id,
        'chorario_nombre',  h.nombre,
        'es_administrador', g.es_administrador,
        'tipo_acceso',      g.tipo_acceso,
        'activo',           g.activo,
        'nivel',            (SELECT MAX(nivel) FROM ruta),
        'ruta',             (SELECT ruta FROM ruta WHERE padre_id IS NULL),
        'num_usuarios',     (SELECT COUNT(*) FROM seguridad.users u WHERE u.grupo_id = g.id),
        'num_hijos',        (SELECT COUNT(*) FROM seguridad.grupos c WHERE c.padre_id = g.id),
        'created_by',       g.created_by,
        'updated_by',       g.updated_by,
        'created_at',       to_char(g.created_at, 'YYYY-MM-DD HH24:MI:SS'),
        'updated_at',       to_char(g.updated_at, 'YYYY-MM-DD HH24:MI:SS')
    )
    FROM seguridad.grupos g
    LEFT JOIN seguridad.grupos    pg ON pg.id = g.padre_id
    LEFT JOIN seguridad.perfiles  p  ON p.id  = g.perfil_id
    LEFT JOIN seguridad.chorarios h  ON h.id  = g.chorario_id
    WHERE g.id = p_id;
$function$;

-- ---------------------------------------------------------------------------
-- LISTAR: el árbol completo, plano y ordenado (padre antes que hijos, por
-- orden y nombre), con nivel, ruta y contadores. El front arma el árbol.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION seguridad.fn_grupos_listar(p_solo_activos boolean DEFAULT false)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
    v_data jsonb;
BEGIN
    WITH RECURSIVE arbol AS (
        SELECT g.id, g.padre_id, g.nombre, g.descripcion, g.orden, g.perfil_id, g.chorario_id,
               g.es_administrador, g.tipo_acceso, g.activo, g.created_by, g.updated_by, g.created_at, g.updated_at,
               0 AS nivel,
               g.nombre::text AS ruta,
               ARRAY[g.orden, g.id::integer] AS camino
          FROM seguridad.grupos g
         WHERE g.padre_id IS NULL
        UNION ALL
        SELECT g.id, g.padre_id, g.nombre, g.descripcion, g.orden, g.perfil_id, g.chorario_id,
               g.es_administrador, g.tipo_acceso, g.activo, g.created_by, g.updated_by, g.created_at, g.updated_at,
               a.nivel + 1,
               a.ruta || ' / ' || g.nombre,
               a.camino || ARRAY[g.orden, g.id::integer]
          FROM seguridad.grupos g
          JOIN arbol a ON a.id = g.padre_id
    ),
    totales AS (
        -- usuarios del grupo y de todos sus descendientes
        WITH RECURSIVE d AS (
            SELECT g.id AS raiz, g.id
              FROM seguridad.grupos g
            UNION ALL
            SELECT d.raiz, c.id
              FROM seguridad.grupos c JOIN d ON c.padre_id = d.id
        )
        SELECT d.raiz AS id, COUNT(u.id) AS num_usuarios_total
          FROM d LEFT JOIN seguridad.users u ON u.grupo_id = d.id
         GROUP BY d.raiz
    )
    SELECT COALESCE(jsonb_agg(
        jsonb_build_object(
            'id',                 a.id,
            'padre_id',           a.padre_id,
            'nombre',             a.nombre,
            'descripcion',        a.descripcion,
            'orden',              a.orden,
            'perfil_id',          a.perfil_id,
            'perfil_nombre',      p.nombre,
            'chorario_id',        a.chorario_id,
            'chorario_nombre',    h.nombre,
            'es_administrador',   a.es_administrador,
            'tipo_acceso',        a.tipo_acceso,
            'activo',             a.activo,
            'nivel',              a.nivel,
            'ruta',               a.ruta,
            'num_usuarios',       (SELECT COUNT(*) FROM seguridad.users u WHERE u.grupo_id = a.id),
            'num_usuarios_total', COALESCE(t.num_usuarios_total, 0),
            'num_hijos',          (SELECT COUNT(*) FROM seguridad.grupos c WHERE c.padre_id = a.id),
            'created_by',         a.created_by,
            'updated_by',         a.updated_by,
            'created_at',         to_char(a.created_at, 'YYYY-MM-DD HH24:MI:SS'),
            'updated_at',         to_char(a.updated_at, 'YYYY-MM-DD HH24:MI:SS')
        ) ORDER BY a.camino
    ), '[]'::jsonb) INTO v_data
    FROM arbol a
    LEFT JOIN totales t             ON t.id = a.id
    LEFT JOIN seguridad.perfiles p  ON p.id = a.perfil_id
    LEFT JOIN seguridad.chorarios h ON h.id = a.chorario_id
    WHERE NOT p_solo_activos OR a.activo;

    RETURN jsonb_build_object(
        'success', true,
        'data',    v_data,
        'sin_grupo', (SELECT COUNT(*) FROM seguridad.users u WHERE u.grupo_id IS NULL),
        'total_usuarios', (SELECT COUNT(*) FROM seguridad.users)
    );
END;
$function$;

-- ---------------------------------------------------------------------------
-- OBTENER
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION seguridad.fn_grupos_obtener(p_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
    v_data jsonb;
BEGIN
    v_data := seguridad.fn_grupos_json(p_id);
    IF v_data IS NULL THEN
        RETURN jsonb_build_object('success', false, 'message', 'Grupo no encontrado', 'error_code', 'GRUPO_NO_EXISTE', 'data', null);
    END IF;
    RETURN jsonb_build_object('success', true, 'message', 'Grupo obtenido exitosamente', 'data', v_data);
END;
$function$;

-- ---------------------------------------------------------------------------
-- Comprobaciones comunes de crear / modificar (perfil, horario, tipo)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION seguridad.fn_grupos_validar(
    p_nombre      varchar,
    p_perfil_id   bigint,
    p_chorario_id bigint,
    p_tipo_acceso varchar
)
RETURNS void
LANGUAGE plpgsql
AS $function$
BEGIN
    IF p_nombre IS NULL OR length(TRIM(p_nombre)) < 2 THEN
        RAISE EXCEPTION 'El nombre del grupo es obligatorio (mínimo 2 caracteres)' USING ERRCODE = 'P0001';
    END IF;
    IF p_perfil_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM seguridad.perfiles WHERE id = p_perfil_id) THEN
        RAISE EXCEPTION 'El perfil % no existe', p_perfil_id USING ERRCODE = 'P0008';
    END IF;
    IF p_chorario_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM seguridad.chorarios WHERE id = p_chorario_id) THEN
        RAISE EXCEPTION 'El horario % no existe', p_chorario_id USING ERRCODE = 'P0009';
    END IF;
    IF COALESCE(p_tipo_acceso, 'SISTEMA') NOT IN ('SISTEMA', 'WEB') THEN
        RAISE EXCEPTION 'El tipo de acceso debe ser SISTEMA o WEB' USING ERRCODE = 'P0010';
    END IF;
END;
$function$;

-- ---------------------------------------------------------------------------
-- CREAR
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION seguridad.fn_grupos_crear(
    p_nombre           varchar,
    p_padre_id         bigint  DEFAULT NULL,
    p_descripcion      text    DEFAULT NULL,
    p_perfil_id        bigint  DEFAULT NULL,
    p_chorario_id      bigint  DEFAULT NULL,
    p_es_administrador boolean DEFAULT false,
    p_tipo_acceso      varchar DEFAULT 'SISTEMA',
    p_activo           boolean DEFAULT true,
    p_usuario_id       bigint  DEFAULT NULL,
    p_usuario_login    varchar DEFAULT NULL,
    p_usuario_nombre   varchar DEFAULT NULL,
    p_ip_address       inet    DEFAULT NULL,
    p_user_agent       text    DEFAULT NULL,
    p_request_id       uuid    DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'seguridad', 'auditoria'
AS $function$
DECLARE
    v_id           bigint;
    v_orden        integer;
    v_fecha        timestamptz := CURRENT_TIMESTAMP;
    v_datos_nuevos jsonb;
BEGIN
    -- 1. Contexto de auditoría (lo leen los triggers de seguridad.grupos)
    PERFORM set_config('app.usuario_id',     COALESCE(p_usuario_id::text, ''), true);
    PERFORM set_config('app.usuario_login',  COALESCE(p_usuario_login, current_user), true);
    PERFORM set_config('app.usuario_nombre', COALESCE(p_usuario_nombre, current_user), true);
    PERFORM set_config('app.ip_address',     COALESCE(p_ip_address::text, ''), true);
    PERFORM set_config('app.user_agent',     COALESCE(p_user_agent, ''), true);
    PERFORM set_config('app.request_id',     COALESCE(p_request_id::text, ''), true);
    PERFORM set_config('app.modulo',         'seguridad.grupos', true);

    -- 2. Reglas
    PERFORM seguridad.fn_grupos_validar(p_nombre, p_perfil_id, p_chorario_id, p_tipo_acceso);
    IF p_padre_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM seguridad.grupos WHERE id = p_padre_id) THEN
        RAISE EXCEPTION 'El grupo padre no existe' USING ERRCODE = 'P0016';
    END IF;
    IF EXISTS (SELECT 1 FROM seguridad.grupos WHERE padre_id IS NOT DISTINCT FROM p_padre_id AND UPPER(nombre) = UPPER(TRIM(p_nombre))) THEN
        RAISE EXCEPTION 'Ya existe un grupo con ese nombre en el mismo nivel' USING ERRCODE = 'P0006';
    END IF;

    -- Último entre sus hermanos
    SELECT COALESCE(MAX(orden), 0) + 1 INTO v_orden FROM seguridad.grupos WHERE padre_id IS NOT DISTINCT FROM p_padre_id;

    -- 3. Datos NUEVOS para la auditoría
    v_datos_nuevos := jsonb_build_object(
        'nombre',           TRIM(p_nombre),
        'padre_id',         p_padre_id,
        'descripcion',      NULLIF(TRIM(COALESCE(p_descripcion, '')), ''),
        'orden',            v_orden,
        'perfil_id',        p_perfil_id,
        'chorario_id',      p_chorario_id,
        'es_administrador', COALESCE(p_es_administrador, false),
        'tipo_acceso',      COALESCE(p_tipo_acceso, 'SISTEMA'),
        'activo',           COALESCE(p_activo, true),
        'created_by',       p_usuario_login,
        'created_at',       to_char(v_fecha, 'YYYY-MM-DD HH24:MI:SS'),
        'updated_by',       p_usuario_login,
        'updated_at',       to_char(v_fecha, 'YYYY-MM-DD HH24:MI:SS')
    );
    PERFORM set_config('app.datos_nuevos', v_datos_nuevos::text, true);

    -- 4. Insertar
    INSERT INTO seguridad.grupos (nombre, padre_id, descripcion, orden, perfil_id, chorario_id, es_administrador, tipo_acceso, activo,
                                  created_by, updated_by, created_at, updated_at)
    VALUES (TRIM(p_nombre), p_padre_id, NULLIF(TRIM(COALESCE(p_descripcion, '')), ''), v_orden, p_perfil_id, p_chorario_id,
            COALESCE(p_es_administrador, false), COALESCE(p_tipo_acceso, 'SISTEMA'), COALESCE(p_activo, true),
            p_usuario_login, p_usuario_login, v_fecha, v_fecha)
    RETURNING id INTO v_id;

    PERFORM set_config('app.datos_nuevos', '', true);

    RETURN jsonb_build_object('success', true, 'message', 'Grupo creado exitosamente', 'data', seguridad.fn_grupos_json(v_id));

EXCEPTION
    WHEN unique_violation THEN
        RAISE EXCEPTION 'Ya existe un grupo con ese nombre en el mismo nivel' USING ERRCODE = 'P0006';
END;
$function$;

-- ---------------------------------------------------------------------------
-- MODIFICAR (si cambia el padre, se coloca al final del nuevo padre)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION seguridad.fn_grupos_modificar(
    p_id               bigint,
    p_nombre           varchar,
    p_padre_id         bigint  DEFAULT NULL,
    p_descripcion      text    DEFAULT NULL,
    p_perfil_id        bigint  DEFAULT NULL,
    p_chorario_id      bigint  DEFAULT NULL,
    p_es_administrador boolean DEFAULT false,
    p_tipo_acceso      varchar DEFAULT 'SISTEMA',
    p_activo           boolean DEFAULT true,
    p_usuario_id       bigint  DEFAULT NULL,
    p_usuario_login    varchar DEFAULT NULL,
    p_usuario_nombre   varchar DEFAULT NULL,
    p_ip_address       inet    DEFAULT NULL,
    p_user_agent       text    DEFAULT NULL,
    p_request_id       uuid    DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'seguridad', 'auditoria'
AS $function$
DECLARE
    v_actual           record;
    v_orden            integer;
    v_fecha            timestamptz := CURRENT_TIMESTAMP;
    v_datos_anteriores jsonb;
    v_datos_nuevos     jsonb;
BEGIN
    -- 1. Contexto de auditoría
    PERFORM set_config('app.usuario_id',     COALESCE(p_usuario_id::text, ''), true);
    PERFORM set_config('app.usuario_login',  COALESCE(p_usuario_login, current_user), true);
    PERFORM set_config('app.usuario_nombre', COALESCE(p_usuario_nombre, current_user), true);
    PERFORM set_config('app.ip_address',     COALESCE(p_ip_address::text, ''), true);
    PERFORM set_config('app.user_agent',     COALESCE(p_user_agent, ''), true);
    PERFORM set_config('app.request_id',     COALESCE(p_request_id::text, ''), true);
    PERFORM set_config('app.modulo',         'seguridad.grupos', true);

    -- 2. Datos actuales
    SELECT * INTO v_actual FROM seguridad.grupos WHERE id = p_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'El grupo no existe' USING ERRCODE = 'P0013';
    END IF;

    -- 3. Reglas
    PERFORM seguridad.fn_grupos_validar(p_nombre, p_perfil_id, p_chorario_id, p_tipo_acceso);
    IF p_padre_id IS NOT NULL THEN
        IF p_padre_id = p_id THEN
            RAISE EXCEPTION 'Un grupo no puede estar dentro de sí mismo' USING ERRCODE = 'P0017';
        END IF;
        IF NOT EXISTS (SELECT 1 FROM seguridad.grupos WHERE id = p_padre_id) THEN
            RAISE EXCEPTION 'El grupo padre no existe' USING ERRCODE = 'P0016';
        END IF;
        IF EXISTS (
            WITH RECURSIVE d AS (
                SELECT id FROM seguridad.grupos WHERE padre_id = p_id
                UNION ALL
                SELECT g.id FROM seguridad.grupos g JOIN d ON g.padre_id = d.id
            )
            SELECT 1 FROM d WHERE d.id = p_padre_id
        ) THEN
            RAISE EXCEPTION 'No se puede mover un grupo dentro de uno de sus propios subgrupos' USING ERRCODE = 'P0017';
        END IF;
    END IF;
    IF EXISTS (SELECT 1 FROM seguridad.grupos WHERE padre_id IS NOT DISTINCT FROM p_padre_id AND UPPER(nombre) = UPPER(TRIM(p_nombre)) AND id <> p_id) THEN
        RAISE EXCEPTION 'Ya existe otro grupo con ese nombre en el mismo nivel' USING ERRCODE = 'P0006';
    END IF;

    -- Si cambia de padre va al final del nuevo; si no, conserva su orden
    IF v_actual.padre_id IS DISTINCT FROM p_padre_id THEN
        SELECT COALESCE(MAX(orden), 0) + 1 INTO v_orden FROM seguridad.grupos WHERE padre_id IS NOT DISTINCT FROM p_padre_id;
    ELSE
        v_orden := v_actual.orden;
    END IF;

    -- 4. Auditoría: anteriores y nuevos
    v_datos_anteriores := to_jsonb(v_actual);
    v_datos_nuevos := jsonb_build_object(
        'id',               p_id,
        'nombre',           TRIM(p_nombre),
        'padre_id',         p_padre_id,
        'descripcion',      NULLIF(TRIM(COALESCE(p_descripcion, '')), ''),
        'orden',            v_orden,
        'perfil_id',        p_perfil_id,
        'chorario_id',      p_chorario_id,
        'es_administrador', COALESCE(p_es_administrador, false),
        'tipo_acceso',      COALESCE(p_tipo_acceso, 'SISTEMA'),
        'activo',           COALESCE(p_activo, true),
        'created_by',       v_actual.created_by,
        'created_at',       to_char(v_actual.created_at, 'YYYY-MM-DD HH24:MI:SS'),
        'updated_by',       COALESCE(p_usuario_login, v_actual.updated_by),
        'updated_at',       to_char(v_fecha, 'YYYY-MM-DD HH24:MI:SS')
    );
    PERFORM set_config('app.datos_anteriores', v_datos_anteriores::text, true);
    PERFORM set_config('app.datos_nuevos',     v_datos_nuevos::text, true);

    -- 5. Actualizar
    UPDATE seguridad.grupos
       SET nombre           = TRIM(p_nombre),
           padre_id         = p_padre_id,
           descripcion      = NULLIF(TRIM(COALESCE(p_descripcion, '')), ''),
           orden            = v_orden,
           perfil_id        = p_perfil_id,
           chorario_id      = p_chorario_id,
           es_administrador = COALESCE(p_es_administrador, false),
           tipo_acceso      = COALESCE(p_tipo_acceso, 'SISTEMA'),
           activo           = COALESCE(p_activo, true),
           updated_by       = COALESCE(p_usuario_login, v_actual.updated_by),
           updated_at       = v_fecha
     WHERE id = p_id;

    PERFORM set_config('app.datos_anteriores', '', true);
    PERFORM set_config('app.datos_nuevos', '', true);

    RETURN jsonb_build_object('success', true, 'message', 'Grupo actualizado exitosamente', 'data', seguridad.fn_grupos_json(p_id));

EXCEPTION
    WHEN unique_violation THEN
        RAISE EXCEPTION 'Ya existe otro grupo con ese nombre en el mismo nivel' USING ERRCODE = 'P0006';
END;
$function$;

-- ---------------------------------------------------------------------------
-- ELIMINAR (sólo si no tiene usuarios ni subgrupos)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION seguridad.fn_grupos_eliminar(
    p_id             bigint,
    p_usuario_id     bigint  DEFAULT NULL,
    p_usuario_login  varchar DEFAULT NULL,
    p_usuario_nombre varchar DEFAULT NULL,
    p_ip_address     inet    DEFAULT NULL,
    p_user_agent     text    DEFAULT NULL,
    p_request_id     uuid    DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'seguridad', 'auditoria'
AS $function$
DECLARE
    v_actual   record;
    v_usuarios bigint;
    v_hijos    bigint;
    v_datos    jsonb;
BEGIN
    PERFORM set_config('app.usuario_id',     COALESCE(p_usuario_id::text, ''), true);
    PERFORM set_config('app.usuario_login',  COALESCE(p_usuario_login, current_user), true);
    PERFORM set_config('app.usuario_nombre', COALESCE(p_usuario_nombre, current_user), true);
    PERFORM set_config('app.ip_address',     COALESCE(p_ip_address::text, ''), true);
    PERFORM set_config('app.user_agent',     COALESCE(p_user_agent, ''), true);
    PERFORM set_config('app.request_id',     COALESCE(p_request_id::text, ''), true);
    PERFORM set_config('app.modulo',         'seguridad.grupos', true);

    SELECT * INTO v_actual FROM seguridad.grupos WHERE id = p_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'El grupo no existe' USING ERRCODE = 'P0013';
    END IF;

    SELECT COUNT(*) INTO v_usuarios FROM seguridad.users  WHERE grupo_id = p_id;
    SELECT COUNT(*) INTO v_hijos    FROM seguridad.grupos WHERE padre_id = p_id;
    IF v_usuarios > 0 OR v_hijos > 0 THEN
        RAISE EXCEPTION 'No se puede eliminar: el grupo tiene % usuario(s) y % subgrupo(s). Muévelos primero.', v_usuarios, v_hijos
            USING ERRCODE = 'P0014';
    END IF;

    v_datos := to_jsonb(v_actual);
    PERFORM set_config('app.datos_anteriores', v_datos::text, true);

    DELETE FROM seguridad.grupos WHERE id = p_id;

    PERFORM set_config('app.datos_anteriores', '', true);

    RETURN jsonb_build_object('success', true, 'message', 'Grupo eliminado exitosamente',
                              'data', jsonb_build_object('id', v_actual.id, 'nombre', v_actual.nombre));
END;
$function$;

-- ---------------------------------------------------------------------------
-- MOVER (arrastrar y soltar): a otro padre y/o delante de un hermano.
-- Mismo algoritmo que seguridad.fn_menus_mover, sin límite de niveles.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION seguridad.fn_grupos_mover(
    p_id             bigint,
    p_padre_id       bigint  DEFAULT NULL,
    p_antes_de       bigint  DEFAULT NULL,
    p_usuario_id     bigint  DEFAULT NULL,
    p_usuario_login  varchar DEFAULT NULL,
    p_usuario_nombre varchar DEFAULT NULL,
    p_ip_address     inet    DEFAULT NULL,
    p_user_agent     text    DEFAULT NULL,
    p_request_id     uuid    DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'seguridad', 'auditoria'
AS $function$
DECLARE
    v_padre_actual bigint;
    v_pos          integer;
    v_i            integer;
    v_fila         record;
BEGIN
    PERFORM set_config('app.usuario_id',     COALESCE(p_usuario_id::text, ''), true);
    PERFORM set_config('app.usuario_login',  COALESCE(p_usuario_login, current_user), true);
    PERFORM set_config('app.usuario_nombre', COALESCE(p_usuario_nombre, current_user), true);
    PERFORM set_config('app.ip_address',     COALESCE(p_ip_address::text, ''), true);
    PERFORM set_config('app.user_agent',     COALESCE(p_user_agent, ''), true);
    PERFORM set_config('app.request_id',     COALESCE(p_request_id::text, ''), true);
    PERFORM set_config('app.modulo',         'seguridad.grupos', true);

    SELECT padre_id INTO v_padre_actual FROM seguridad.grupos WHERE id = p_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'El grupo no existe' USING ERRCODE = 'P0013';
    END IF;

    IF p_padre_id IS NOT NULL THEN
        IF p_padre_id = p_id THEN
            RAISE EXCEPTION 'Un grupo no puede estar dentro de sí mismo' USING ERRCODE = 'P0017';
        END IF;
        IF NOT EXISTS (SELECT 1 FROM seguridad.grupos WHERE id = p_padre_id) THEN
            RAISE EXCEPTION 'El grupo destino no existe' USING ERRCODE = 'P0016';
        END IF;
        IF EXISTS (
            WITH RECURSIVE d AS (
                SELECT id FROM seguridad.grupos WHERE padre_id = p_id
                UNION ALL
                SELECT g.id FROM seguridad.grupos g JOIN d ON g.padre_id = d.id
            )
            SELECT 1 FROM d WHERE d.id = p_padre_id
        ) THEN
            RAISE EXCEPTION 'No se puede mover un grupo dentro de uno de sus propios subgrupos' USING ERRCODE = 'P0017';
        END IF;
    END IF;
    IF v_padre_actual IS DISTINCT FROM p_padre_id
       AND EXISTS (SELECT 1 FROM seguridad.grupos g1, seguridad.grupos g2
                    WHERE g1.id = p_id AND g2.id <> p_id
                      AND g2.padre_id IS NOT DISTINCT FROM p_padre_id AND UPPER(g2.nombre) = UPPER(g1.nombre)) THEN
        RAISE EXCEPTION 'En el grupo destino ya hay otro grupo con ese nombre' USING ERRCODE = 'P0006';
    END IF;

    -- Padre nuevo
    UPDATE seguridad.grupos SET padre_id = p_padre_id, updated_at = CURRENT_TIMESTAMP
     WHERE id = p_id AND padre_id IS DISTINCT FROM p_padre_id;

    -- Orden entre los hermanos del padre nuevo
    CREATE TEMP TABLE IF NOT EXISTS tmp_hermanos_grupos (id bigint, pos integer) ON COMMIT DROP;
    DELETE FROM tmp_hermanos_grupos;

    INSERT INTO tmp_hermanos_grupos (id, pos)
    SELECT id, ROW_NUMBER() OVER (ORDER BY orden, nombre)
      FROM seguridad.grupos
     WHERE padre_id IS NOT DISTINCT FROM p_padre_id AND id <> p_id;

    IF p_antes_de IS NOT NULL AND p_antes_de <> p_id THEN
        SELECT pos INTO v_pos FROM tmp_hermanos_grupos WHERE id = p_antes_de;
    END IF;
    IF v_pos IS NULL THEN
        SELECT COALESCE(MAX(pos), 0) + 1 INTO v_pos FROM tmp_hermanos_grupos;
    END IF;

    UPDATE tmp_hermanos_grupos SET pos = pos + 1 WHERE pos >= v_pos;
    INSERT INTO tmp_hermanos_grupos (id, pos) VALUES (p_id, v_pos);

    v_i := 0;
    FOR v_fila IN SELECT id FROM tmp_hermanos_grupos ORDER BY pos LOOP
        v_i := v_i + 1;
        UPDATE seguridad.grupos SET orden = v_i, updated_at = CURRENT_TIMESTAMP
         WHERE id = v_fila.id AND orden IS DISTINCT FROM v_i;
    END LOOP;

    -- Hermanos que dejó atrás, sin huecos
    IF v_padre_actual IS DISTINCT FROM p_padre_id THEN
        v_i := 0;
        FOR v_fila IN SELECT id FROM seguridad.grupos WHERE padre_id IS NOT DISTINCT FROM v_padre_actual ORDER BY orden, nombre LOOP
            v_i := v_i + 1;
            UPDATE seguridad.grupos SET orden = v_i, updated_at = CURRENT_TIMESTAMP
             WHERE id = v_fila.id AND orden IS DISTINCT FROM v_i;
        END LOOP;
    END IF;

    RETURN jsonb_build_object(
        'success', true,
        'message', CASE WHEN v_padre_actual IS DISTINCT FROM p_padre_id THEN 'Grupo movido' ELSE 'Orden actualizado' END,
        'data', seguridad.fn_grupos_json(p_id)
    );
END;
$function$;

-- ---------------------------------------------------------------------------
-- MOVER USUARIOS A UN GRUPO (arrastrar usuarios al árbol). p_grupo_id NULL =
-- dejarlos sin grupo. Cada usuario se audita con anteriores / nuevos.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION seguridad.fn_usuarios_mover_grupo(
    p_ids            jsonb,
    p_grupo_id       bigint  DEFAULT NULL,
    p_usuario_id     bigint  DEFAULT NULL,
    p_usuario_login  varchar DEFAULT NULL,
    p_usuario_nombre varchar DEFAULT NULL,
    p_ip_address     inet    DEFAULT NULL,
    p_user_agent     text    DEFAULT NULL,
    p_request_id     uuid    DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'seguridad', 'auditoria'
AS $function$
DECLARE
    v_grupo_nombre varchar;
    v_u            record;
    v_movidos      integer := 0;
    v_fecha        timestamptz := CURRENT_TIMESTAMP;
BEGIN
    PERFORM set_config('app.usuario_id',     COALESCE(p_usuario_id::text, ''), true);
    PERFORM set_config('app.usuario_login',  COALESCE(p_usuario_login, current_user), true);
    PERFORM set_config('app.usuario_nombre', COALESCE(p_usuario_nombre, current_user), true);
    PERFORM set_config('app.ip_address',     COALESCE(p_ip_address::text, ''), true);
    PERFORM set_config('app.user_agent',     COALESCE(p_user_agent, ''), true);
    PERFORM set_config('app.request_id',     COALESCE(p_request_id::text, ''), true);
    PERFORM set_config('app.modulo',         'seguridad.users', true);

    IF p_grupo_id IS NOT NULL THEN
        SELECT nombre INTO v_grupo_nombre FROM seguridad.grupos WHERE id = p_grupo_id;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'El grupo destino no existe' USING ERRCODE = 'P0016';
        END IF;
    END IF;
    IF p_ids IS NULL OR jsonb_typeof(p_ids) <> 'array' OR jsonb_array_length(p_ids) = 0 THEN
        RAISE EXCEPTION 'No se indicó ningún usuario' USING ERRCODE = 'P0001';
    END IF;

    FOR v_u IN
        SELECT u.id, u.login_user, u.name, u.surname, u.grupo_id, g.nombre AS grupo_nombre
          FROM seguridad.users u
          LEFT JOIN seguridad.grupos g ON g.id = u.grupo_id
         WHERE u.id IN (SELECT (x)::bigint FROM jsonb_array_elements_text(p_ids) x)
           AND u.grupo_id IS DISTINCT FROM p_grupo_id
    LOOP
        PERFORM set_config('app.datos_anteriores', jsonb_build_object(
            'id', v_u.id, 'login_user', v_u.login_user, 'name', v_u.name, 'surname', v_u.surname,
            'grupo', CASE WHEN v_u.grupo_id IS NULL THEN NULL ELSE jsonb_build_object('id', v_u.grupo_id, 'nombre', v_u.grupo_nombre) END
        )::text, true);
        PERFORM set_config('app.datos_nuevos', jsonb_build_object(
            'id', v_u.id, 'login_user', v_u.login_user, 'name', v_u.name, 'surname', v_u.surname,
            'grupo', CASE WHEN p_grupo_id IS NULL THEN NULL ELSE jsonb_build_object('id', p_grupo_id, 'nombre', v_grupo_nombre) END,
            'updated_by', p_usuario_login, 'updated_at', to_char(v_fecha, 'YYYY-MM-DD HH24:MI:SS')
        )::text, true);

        UPDATE seguridad.users
           SET grupo_id = p_grupo_id, updated_by = COALESCE(p_usuario_login, updated_by), updated_at = v_fecha
         WHERE id = v_u.id;

        v_movidos := v_movidos + 1;
    END LOOP;

    PERFORM set_config('app.datos_anteriores', '', true);
    PERFORM set_config('app.datos_nuevos', '', true);

    RETURN jsonb_build_object(
        'success', true,
        'message', CASE
                       WHEN v_movidos = 0 THEN 'Los usuarios ya estaban en ese grupo'
                       WHEN p_grupo_id IS NULL THEN format('%s usuario(s) quedaron sin grupo', v_movidos)
                       ELSE format('%s usuario(s) movido(s) a «%s»', v_movidos, v_grupo_nombre)
                   END,
        'data', jsonb_build_object('movidos', v_movidos, 'grupo_id', p_grupo_id, 'grupo_nombre', v_grupo_nombre)
    );
END;
$function$;

-- ---------------------------------------------------------------------------
-- USUARIOS DE UN GRUPO (grilla de la pantalla árbol + usuarios).
--   p_grupo_id NULL  → todos los usuarios
--   p_grupo_id 0     → usuarios sin grupo
--   otro             → los del grupo (y de sus subgrupos si p_incluir_subgrupos)
-- Misma forma que fn_usuarios_listar_paginado: {data, meta}.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION seguridad.fn_usuarios_listar_por_grupo(
    p_grupo_id          bigint  DEFAULT NULL,
    p_incluir_subgrupos boolean DEFAULT false,
    p_page              integer DEFAULT 1,
    p_per_page          integer DEFAULT 15,
    p_search            text    DEFAULT ''
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
    v_offset  integer;
    v_total   bigint;
    v_data    jsonb;
    v_filtro  text;
    v_terms   text[];
    v_grupos  bigint[];
BEGIN
    v_offset := (GREATEST(COALESCE(p_page, 1), 1) - 1) * p_per_page;
    v_filtro := NULLIF(TRIM(COALESCE(p_search, '')), '');
    v_terms  := string_to_array(COALESCE(v_filtro, ''), ' ');

    -- Grupos que entran en la consulta
    IF p_grupo_id IS NOT NULL AND p_grupo_id > 0 THEN
        IF p_incluir_subgrupos THEN
            WITH RECURSIVE d AS (
                SELECT id FROM seguridad.grupos WHERE id = p_grupo_id
                UNION ALL
                SELECT g.id FROM seguridad.grupos g JOIN d ON g.padre_id = d.id
            )
            SELECT array_agg(id) INTO v_grupos FROM d;
        ELSE
            v_grupos := ARRAY[p_grupo_id];
        END IF;
    END IF;

    CREATE TEMP TABLE IF NOT EXISTS tmp_usuarios_grupo (id bigint) ON COMMIT DROP;
    DELETE FROM tmp_usuarios_grupo;

    INSERT INTO tmp_usuarios_grupo (id)
    SELECT u.id
      FROM seguridad.users u
     WHERE (   p_grupo_id IS NULL
            OR (p_grupo_id = 0 AND u.grupo_id IS NULL)
            OR (v_grupos IS NOT NULL AND u.grupo_id = ANY (v_grupos)))
       AND (   v_filtro IS NULL
            OR u.login_user ILIKE '%' || v_filtro || '%'
            OR u.name       ILIKE '%' || v_filtro || '%'
            OR u.surname    ILIKE '%' || v_filtro || '%'
            OR u.email      ILIKE '%' || v_filtro || '%'
            OR u.id::text   ILIKE '%' || v_filtro || '%'
            OR (SELECT bool_and(CONCAT_WS(' ', u.name, u.surname) ILIKE '%' || term || '%'
                             OR CONCAT_WS(' ', u.surname, u.name) ILIKE '%' || term || '%')
                  FROM unnest(v_terms) AS term));

    SELECT COUNT(*) INTO v_total FROM tmp_usuarios_grupo;

    SELECT COALESCE(jsonb_agg(
        jsonb_build_object(
            'id',                t.id,
            'login_user',        t.login_user,
            'name',              t.name,
            'surname',           t.surname,
            'email',             t.email,
            'phone',             t.phone,
            'avatar',            t.avatar,
            'type_user',         t.type_user,
            'isactive',          t.isactive,
            'islogin',           t.islogin,
            'isreset',           t.isreset,
            'perfil_id',         t.perfil_id,
            'perfil_nombre',     p.nombre,
            'chorario_id',       t.chorario_id,
            'chorario_nombre',   h.nombre,
            'grupo_id',          t.grupo_id,
            'grupo_nombre',      g.nombre,
            'created_by',        t.created_by,
            'updated_by',        t.updated_by,
            'created_at',        to_char(t.created_at, 'YYYY-MM-DD HH24:MI:SS'),
            'updated_at',        to_char(t.updated_at, 'YYYY-MM-DD HH24:MI:SS'),
            'email_verified_at', to_char(t.email_verified_at, 'YYYY-MM-DD HH24:MI:SS'),
            'user_verified_at',  to_char(t.user_verified_at, 'YYYY-MM-DD HH24:MI:SS'),
            'last_login_at',     to_char(t.last_login_at, 'YYYY-MM-DD HH24:MI:SS')
        ) ORDER BY t.surname, t.name, t.id
    ), '[]'::jsonb) INTO v_data
    FROM (
        SELECT u.*
          FROM seguridad.users u
          JOIN tmp_usuarios_grupo f ON f.id = u.id
         ORDER BY u.surname, u.name, u.id
         LIMIT p_per_page OFFSET v_offset
    ) t
    LEFT JOIN seguridad.perfiles  p ON p.id = t.perfil_id
    LEFT JOIN seguridad.chorarios h ON h.id = t.chorario_id
    LEFT JOIN seguridad.grupos    g ON g.id = t.grupo_id;

    RETURN jsonb_build_object(
        'data', v_data,
        'meta', jsonb_build_object(
            'total',        v_total,
            'per_page',     p_per_page,
            'current_page', p_page,
            'last_page',    CASE WHEN v_total = 0 THEN 1 ELSE ceil(v_total::numeric / p_per_page) END
        )
    );
END;
$function$;

-- ===========================================================================
-- fn_usuarios_crear / modificar / obtener / listar_paginado CON GRUPO.
-- Son las funciones existentes con el parámetro p_grupo_id (después de
-- p_chorario_id) y grupo_id / grupo_nombre en lo que devuelven. Las firmas
-- viejas de crear y modificar se eliminan para que no haya ambigüedad.
-- ===========================================================================
DROP FUNCTION IF EXISTS seguridad.fn_usuarios_crear(character varying, character varying, character varying, character varying, character varying, character varying, character varying, boolean, integer, integer, integer, bigint, character varying, character varying, inet, text, uuid);
DROP FUNCTION IF EXISTS seguridad.fn_usuarios_modificar(bigint, character varying, character varying, character varying, character varying, character varying, character varying, boolean, integer, integer, integer, bigint, character varying, character varying, inet, text, uuid);


-- ---------------------------------------------------------------------------
-- fn_usuarios_crear (con p_grupo_id)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION seguridad.fn_usuarios_crear(p_name character varying, p_surname character varying, p_email character varying, p_phone character varying DEFAULT NULL::character varying, p_login_user character varying DEFAULT NULL::character varying, p_password character varying DEFAULT NULL::character varying, p_avatar character varying DEFAULT NULL::character varying, p_isactive boolean DEFAULT true, p_type_user integer DEFAULT 4, p_perfil_id integer DEFAULT 1, p_chorario_id integer DEFAULT NULL::integer, p_grupo_id bigint DEFAULT NULL::bigint, p_usuario_id bigint DEFAULT NULL::bigint, p_usuario_login character varying DEFAULT NULL::character varying, p_usuario_nombre character varying DEFAULT NULL::character varying, p_ip_address inet DEFAULT NULL::inet, p_user_agent text DEFAULT NULL::text, p_request_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'seguridad', 'auditoria'
AS $function$
DECLARE
    v_user_id BIGINT;
    v_resultado JSONB;
    v_datos_nuevos JSONB;
    v_fecha_actual TIMESTAMPTZ;
    v_perfil_data RECORD;
    v_chorario_data RECORD;
    v_usuario_creado RECORD;
    v_type_user INTEGER;
    v_grupo_nombre VARCHAR;
BEGIN
    -- 1. Fecha única para todo el registro
    v_fecha_actual := CURRENT_TIMESTAMP;

    -- 2. Contexto de auditoría (lo leen los triggers de seguridad.users)
    PERFORM set_config('app.usuario_id', COALESCE(p_usuario_id::TEXT, ''), true);
    PERFORM set_config('app.usuario_login', COALESCE(p_usuario_login, current_user), true);
    PERFORM set_config('app.usuario_nombre', COALESCE(p_usuario_nombre, current_user), true);
    PERFORM set_config('app.ip_address', COALESCE(p_ip_address::TEXT, ''), true);
    PERFORM set_config('app.user_agent', COALESCE(p_user_agent, ''), true);
    PERFORM set_config('app.request_id', COALESCE(p_request_id::TEXT, ''), true);
    PERFORM set_config('app.modulo', 'seguridad.users', true);

    -- 3. Campos obligatorios
    IF p_name IS NULL OR TRIM(p_name) = '' THEN
        RAISE EXCEPTION 'El nombre es obligatorio' USING ERRCODE = 'P0001';
    END IF;

    IF p_surname IS NULL OR TRIM(p_surname) = '' THEN
        RAISE EXCEPTION 'El apellido es obligatorio' USING ERRCODE = 'P0002';
    END IF;

    IF p_login_user IS NULL OR TRIM(p_login_user) = '' THEN
        RAISE EXCEPTION 'El login de usuario es obligatorio' USING ERRCODE = 'P0003';
    END IF;

    IF p_email IS NULL OR TRIM(p_email) = '' THEN
        RAISE EXCEPTION 'El email es obligatorio' USING ERRCODE = 'P0004';
    END IF;

    IF p_password IS NULL OR TRIM(p_password) = '' THEN
        RAISE EXCEPTION 'La contraseña es obligatoria' USING ERRCODE = 'P0005';
    END IF;

    -- phone es NOT NULL en la tabla: mejor un mensaje de negocio que el del constraint
    IF p_phone IS NULL OR TRIM(p_phone) = '' THEN
        RAISE EXCEPTION 'El teléfono es obligatorio' USING ERRCODE = 'P0011';
    END IF;

    -- chorario_id también es NOT NULL, y sin horario el middleware deniega el acceso
    IF p_chorario_id IS NULL THEN
        RAISE EXCEPTION 'Debe asignar un horario al usuario' USING ERRCODE = 'P0012';
    END IF;

    -- 4. Tipo de usuario: 1 SUPER USUARIO, 2 ADMINISTRADOR, 3 USUARIO SISTEMA, 4 USUARIO WEB
    v_type_user := COALESCE(p_type_user, 4);
    IF v_type_user NOT IN (1, 2, 3, 4) THEN
        RAISE EXCEPTION 'El tipo de usuario % no es válido', v_type_user USING ERRCODE = 'P0010';
    END IF;

    -- 5. Login único.
    --    Esta comprobación es sólo para dar un mensaje claro; quien garantiza la
    --    unicidad es el índice, y por eso unique_violation se maneja más abajo.
    IF EXISTS (SELECT 1 FROM seguridad.users WHERE login_user = TRIM(p_login_user)) THEN
        RAISE EXCEPTION 'Ya existe un usuario con ese login' USING ERRCODE = 'P0006';
    END IF;

    -- 6. Email único
    IF EXISTS (SELECT 1 FROM seguridad.users WHERE email = TRIM(p_email)) THEN
        RAISE EXCEPTION 'Ya existe un usuario con ese email' USING ERRCODE = 'P0007';
    END IF;

    -- 7. El perfil debe existir (también cuando se usa el valor por defecto)
    SELECT id, nombre INTO v_perfil_data
    FROM seguridad.perfiles
    WHERE id = COALESCE(p_perfil_id, 1);

    IF NOT FOUND THEN
        RAISE EXCEPTION 'El perfil % no existe', COALESCE(p_perfil_id, 1) USING ERRCODE = 'P0008';
    END IF;

    -- 8. El horario debe existir
    SELECT id, nombre INTO v_chorario_data
    FROM seguridad.chorarios
    WHERE id = p_chorario_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'El horario % no existe', p_chorario_id USING ERRCODE = 'P0009';
    END IF;

    -- 8b. El grupo (opcional) debe existir
    IF p_grupo_id IS NOT NULL THEN
        SELECT nombre INTO v_grupo_nombre FROM seguridad.grupos WHERE id = p_grupo_id;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'El grupo % no existe', p_grupo_id USING ERRCODE = 'P0016';
        END IF;
    END IF;

    -- 9. Datos NUEVOS para la auditoría.
    --    Se construye ANTES del INSERT porque el trigger AFTER lo lee del
    --    contexto. Deliberadamente NO incluye password ni recovery_code.
    v_datos_nuevos := jsonb_build_object(
        'name', TRIM(p_name),
        'surname', TRIM(p_surname),
        'email', TRIM(p_email),
        'phone', TRIM(p_phone),
        'login_user', TRIM(p_login_user),
        'avatar', p_avatar,
        'type_user', v_type_user,
        'isactive', COALESCE(p_isactive, true),
        'islogin', false,
        'isreset', false,
        'perfil', jsonb_build_object('id', v_perfil_data.id, 'nombre', v_perfil_data.nombre),
        'chorario', jsonb_build_object('id', v_chorario_data.id, 'nombre', v_chorario_data.nombre),
        'grupo', CASE WHEN p_grupo_id IS NULL THEN NULL ELSE jsonb_build_object('id', p_grupo_id, 'nombre', v_grupo_nombre) END,
        'created_by', p_usuario_login,
        'created_at', to_char(v_fecha_actual, 'YYYY-MM-DD HH24:MI:SS'),
        'updated_by', p_usuario_login,
        'updated_at', to_char(v_fecha_actual, 'YYYY-MM-DD HH24:MI:SS')
    );
    PERFORM set_config('app.datos_nuevos', v_datos_nuevos::TEXT, true);

    -- 10. Insertar usuario
    INSERT INTO seguridad.users (
        name, surname, email, phone, login_user, password, avatar,
        type_user, isactive, islogin, perfil_id, chorario_id, grupo_id,
        created_by, updated_by, created_at, updated_at
    ) VALUES (
        TRIM(p_name),
        TRIM(p_surname),
        TRIM(p_email),
        TRIM(p_phone),
        TRIM(p_login_user),
        p_password,
        p_avatar,
        v_type_user,
        COALESCE(p_isactive, true),
        false,
        v_perfil_data.id,
        v_chorario_data.id,
        p_grupo_id,
        p_usuario_login,
        p_usuario_login,
        v_fecha_actual,
        v_fecha_actual
    )
    RETURNING id INTO v_user_id;

    -- 11. El trigger de auditoría ya disparó al cerrar el INSERT: soltamos el
    --     contexto para no contaminar lo que venga después en esta transacción.
    PERFORM set_config('app.datos_nuevos', '', true);

    -- 12. Devolver el usuario recién creado (sin password ni recovery_code)
    SELECT jsonb_build_object(
        'success', true,
        'message', 'Usuario creado exitosamente',
        'data', jsonb_build_object(
            'id', u.id,
            'name', u.name,
            'surname', u.surname,
            'email', u.email,
            'phone', u.phone,
            'login_user', u.login_user,
            'avatar', u.avatar,
            'type_user', u.type_user,
            'isactive', u.isactive,
            'islogin', u.islogin,
            'isreset', u.isreset,
            'perfil_id', u.perfil_id,
            'perfil_nombre', p.nombre,
            'chorario_id', u.chorario_id,
            'chorario_nombre', h.nombre,
            'grupo_id', u.grupo_id,
            'grupo_nombre', g.nombre,
            'perfil', jsonb_build_object('id', p.id, 'nombre', p.nombre),
            'chorario', jsonb_build_object('id', h.id, 'nombre', h.nombre),
            'created_by', u.created_by,
            'created_at', to_char(u.created_at, 'YYYY-MM-DD HH24:MI:SS'),
            'updated_by', u.updated_by,
            'updated_at', to_char(u.updated_at, 'YYYY-MM-DD HH24:MI:SS'),
            'last_login_at', to_char(u.last_login_at, 'YYYY-MM-DD HH24:MI:SS'),
            'user_verified_at', to_char(u.user_verified_at, 'YYYY-MM-DD HH24:MI:SS'),
            'email_verified_at', to_char(u.email_verified_at, 'YYYY-MM-DD HH24:MI:SS')
        )
    ) INTO v_resultado
    FROM seguridad.users u
    LEFT JOIN seguridad.perfiles p ON p.id = u.perfil_id
    LEFT JOIN seguridad.chorarios h ON h.id = u.chorario_id
    LEFT JOIN seguridad.grupos    g ON g.id = u.grupo_id
    WHERE u.id = v_user_id;

    RETURN v_resultado;

EXCEPTION
    -- Único caso capturado, y se RE-LANZA: las comprobaciones EXISTS de arriba
    -- pueden perder la carrera contra otra petición simultánea. Aquí manda el
    -- índice único; lo único que hacemos es traducir el mensaje.
    -- Nunca un «WHEN OTHERS»: cualquier otro error debe abortar la transacción.
    WHEN unique_violation THEN
        RAISE EXCEPTION 'Ya existe un usuario con ese login o email'
            USING ERRCODE = 'P0006';
END;
$function$;

-- ---------------------------------------------------------------------------
-- fn_usuarios_modificar (con p_grupo_id: NULL no cambia, 0 sin grupo)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION seguridad.fn_usuarios_modificar(p_id bigint, p_name character varying, p_surname character varying, p_email character varying, p_phone character varying DEFAULT NULL::character varying, p_login_user character varying DEFAULT NULL::character varying, p_avatar character varying DEFAULT NULL::character varying, p_isactive boolean DEFAULT true, p_type_user integer DEFAULT NULL::integer, p_perfil_id integer DEFAULT NULL::integer, p_chorario_id integer DEFAULT NULL::integer, p_grupo_id bigint DEFAULT NULL::bigint, p_usuario_id bigint DEFAULT NULL::bigint, p_usuario_login character varying DEFAULT NULL::character varying, p_usuario_nombre character varying DEFAULT NULL::character varying, p_ip_address inet DEFAULT NULL::inet, p_user_agent text DEFAULT NULL::text, p_request_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'seguridad', 'auditoria'
AS $function$
DECLARE
    v_resultado JSONB;
    v_datos_anteriores JSONB;
    v_datos_nuevos JSONB;
    v_usuario_actual RECORD;
    v_perfil_data RECORD;
    v_chorario_data RECORD;
    v_fecha_actual TIMESTAMPTZ;
    v_perfil_nuevo_id INTEGER;
    v_chorario_nuevo_id INTEGER;
    v_type_user INTEGER;
    v_grupo_nuevo_id BIGINT;
    v_grupo_nombre VARCHAR;
BEGIN
    v_fecha_actual := CURRENT_TIMESTAMP;

    -- 1. Contexto de auditoría
    PERFORM set_config('app.usuario_id', COALESCE(p_usuario_id::TEXT, ''), true);
    PERFORM set_config('app.usuario_login', COALESCE(p_usuario_login, current_user), true);
    PERFORM set_config('app.usuario_nombre', COALESCE(p_usuario_nombre, current_user), true);
    PERFORM set_config('app.ip_address', COALESCE(p_ip_address::TEXT, ''), true);
    PERFORM set_config('app.user_agent', COALESCE(p_user_agent, ''), true);
    PERFORM set_config('app.request_id', COALESCE(p_request_id::TEXT, ''), true);
    PERFORM set_config('app.modulo', 'seguridad.users', true);

    -- 2. Datos ACTUALES del usuario (antes de modificar)
    SELECT
        u.id, u.name, u.surname, u.email, u.phone, u.login_user, u.avatar,
        u.isactive, u.islogin, u.isreset, u.type_user, u.perfil_id, u.chorario_id, u.grupo_id,
        u.created_by, u.updated_by, u.created_at, u.updated_at,
        u.last_login_at, u.user_verified_at, u.email_verified_at,
        p.nombre as perfil_nombre,
        c.nombre as chorario_nombre,
        g.nombre as grupo_nombre
    INTO v_usuario_actual
    FROM seguridad.users u
    LEFT JOIN seguridad.perfiles p ON p.id = u.perfil_id
    LEFT JOIN seguridad.chorarios c ON c.id = u.chorario_id
    LEFT JOIN seguridad.grupos    g ON g.id = u.grupo_id
    WHERE u.id = p_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'El usuario no existe' USING ERRCODE = 'P0013';
    END IF;

    -- 3. Campos obligatorios
    IF p_name IS NULL OR TRIM(p_name) = '' THEN
        RAISE EXCEPTION 'El nombre es obligatorio' USING ERRCODE = 'P0001';
    END IF;

    IF p_surname IS NULL OR TRIM(p_surname) = '' THEN
        RAISE EXCEPTION 'El apellido es obligatorio' USING ERRCODE = 'P0002';
    END IF;

    IF p_login_user IS NULL OR TRIM(p_login_user) = '' THEN
        RAISE EXCEPTION 'El login de usuario es obligatorio' USING ERRCODE = 'P0003';
    END IF;

    IF p_email IS NULL OR TRIM(p_email) = '' THEN
        RAISE EXCEPTION 'El email es obligatorio' USING ERRCODE = 'P0004';
    END IF;

    -- 4. Tipo de usuario: 1 SUPER USUARIO, 2 ADMINISTRADOR, 3 USUARIO SISTEMA, 4 USUARIO WEB
    v_type_user := COALESCE(p_type_user, v_usuario_actual.type_user);
    IF v_type_user NOT IN (1, 2, 3, 4) THEN
        RAISE EXCEPTION 'El tipo de usuario % no es válido', v_type_user USING ERRCODE = 'P0010';
    END IF;

    -- 5. Login único (excluyendo el propio usuario).
    --    Mensaje amable; quien garantiza la unicidad es el índice, por eso
    --    unique_violation se maneja más abajo.
    IF EXISTS (SELECT 1 FROM seguridad.users WHERE login_user = TRIM(p_login_user) AND id <> p_id) THEN
        RAISE EXCEPTION 'Ya existe otro usuario con ese login' USING ERRCODE = 'P0006';
    END IF;

    -- 6. Email único (excluyendo el propio usuario)
    IF EXISTS (SELECT 1 FROM seguridad.users WHERE email = TRIM(p_email) AND id <> p_id) THEN
        RAISE EXCEPTION 'Ya existe otro usuario con ese email' USING ERRCODE = 'P0007';
    END IF;

    -- 7. Perfil y horario destino
    v_perfil_nuevo_id := COALESCE(p_perfil_id, v_usuario_actual.perfil_id);
    v_chorario_nuevo_id := COALESCE(p_chorario_id, v_usuario_actual.chorario_id);

    SELECT id, nombre INTO v_perfil_data
    FROM seguridad.perfiles WHERE id = v_perfil_nuevo_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'El perfil % no existe', v_perfil_nuevo_id USING ERRCODE = 'P0008';
    END IF;

    SELECT id, nombre INTO v_chorario_data
    FROM seguridad.chorarios WHERE id = v_chorario_nuevo_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'El horario % no existe', v_chorario_nuevo_id USING ERRCODE = 'P0009';
    END IF;

    -- 7b. Grupo destino: NULL = no cambia, 0 = sin grupo, otro = debe existir
    v_grupo_nuevo_id := CASE WHEN p_grupo_id IS NULL THEN v_usuario_actual.grupo_id
                             WHEN p_grupo_id = 0 THEN NULL
                             ELSE p_grupo_id END;
    IF v_grupo_nuevo_id IS NOT NULL THEN
        SELECT nombre INTO v_grupo_nombre FROM seguridad.grupos WHERE id = v_grupo_nuevo_id;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'El grupo % no existe', v_grupo_nuevo_id USING ERRCODE = 'P0016';
        END IF;
    END IF;

    -- 8. Datos ANTERIORES para la auditoría (sin password ni recovery_code)
    v_datos_anteriores := jsonb_build_object(
        'id', v_usuario_actual.id,
        'name', v_usuario_actual.name,
        'surname', v_usuario_actual.surname,
        'email', v_usuario_actual.email,
        'phone', v_usuario_actual.phone,
        'login_user', v_usuario_actual.login_user,
        'avatar', v_usuario_actual.avatar,
        'type_user', v_usuario_actual.type_user,
        'isactive', v_usuario_actual.isactive,
        'islogin', v_usuario_actual.islogin,
        'isreset', v_usuario_actual.isreset,
        'perfil', jsonb_build_object('id', v_usuario_actual.perfil_id, 'nombre', v_usuario_actual.perfil_nombre),
        'chorario', jsonb_build_object('id', v_usuario_actual.chorario_id, 'nombre', v_usuario_actual.chorario_nombre),
        'grupo', CASE WHEN v_usuario_actual.grupo_id IS NULL THEN NULL ELSE jsonb_build_object('id', v_usuario_actual.grupo_id, 'nombre', v_usuario_actual.grupo_nombre) END,
        'created_by', v_usuario_actual.created_by,
        'created_at', to_char(v_usuario_actual.created_at, 'YYYY-MM-DD HH24:MI:SS'),
        'updated_by', v_usuario_actual.updated_by,
        'updated_at', to_char(v_usuario_actual.updated_at, 'YYYY-MM-DD HH24:MI:SS'),
        'last_login_at', to_char(v_usuario_actual.last_login_at, 'YYYY-MM-DD HH24:MI:SS')
    );
    PERFORM set_config('app.datos_anteriores', v_datos_anteriores::TEXT, true);

    -- 9. Datos NUEVOS
    v_datos_nuevos := jsonb_build_object(
        'id', p_id,
        'name', TRIM(p_name),
        'surname', TRIM(p_surname),
        'email', TRIM(p_email),
        'phone', p_phone,
        'login_user', TRIM(p_login_user),
        'avatar', p_avatar,
        'type_user', v_type_user,
        'isactive', p_isactive,
        'islogin', v_usuario_actual.islogin,
        'isreset', v_usuario_actual.isreset,
        'perfil', jsonb_build_object('id', v_perfil_data.id, 'nombre', v_perfil_data.nombre),
        'chorario', jsonb_build_object('id', v_chorario_data.id, 'nombre', v_chorario_data.nombre),
        'grupo', CASE WHEN v_grupo_nuevo_id IS NULL THEN NULL ELSE jsonb_build_object('id', v_grupo_nuevo_id, 'nombre', v_grupo_nombre) END,
        'created_by', v_usuario_actual.created_by,
        'created_at', to_char(v_usuario_actual.created_at, 'YYYY-MM-DD HH24:MI:SS'),
        'updated_by', COALESCE(p_usuario_login, v_usuario_actual.updated_by),
        'updated_at', to_char(v_fecha_actual, 'YYYY-MM-DD HH24:MI:SS'),
        'last_login_at', to_char(v_usuario_actual.last_login_at, 'YYYY-MM-DD HH24:MI:SS')
    );
    PERFORM set_config('app.datos_nuevos', v_datos_nuevos::TEXT, true);

    -- 10. Actualizar
    UPDATE seguridad.users
    SET
        name = TRIM(p_name),
        surname = TRIM(p_surname),
        email = TRIM(p_email),
        phone = p_phone,
        login_user = TRIM(p_login_user),
        avatar = p_avatar,
        isactive = p_isactive,
        type_user = v_type_user,
        perfil_id = v_perfil_nuevo_id,
        chorario_id = v_chorario_nuevo_id,
        grupo_id = v_grupo_nuevo_id,
        updated_at = v_fecha_actual,
        updated_by = COALESCE(p_usuario_login, v_usuario_actual.updated_by)
    WHERE id = p_id;

    -- 11. El trigger ya disparó al cerrar el UPDATE: soltamos el contexto.
    PERFORM set_config('app.datos_anteriores', '', true);
    PERFORM set_config('app.datos_nuevos', '', true);

    -- 12. Devolver el usuario actualizado (sin password ni recovery_code)
    SELECT jsonb_build_object(
        'success', true,
        'message', 'Usuario actualizado exitosamente',
        'data', jsonb_build_object(
            'id', u.id,
            'name', u.name,
            'surname', u.surname,
            'email', u.email,
            'phone', u.phone,
            'login_user', u.login_user,
            'avatar', u.avatar,
            'type_user', u.type_user,
            'isactive', u.isactive,
            'islogin', u.islogin,
            'isreset', u.isreset,
            'perfil_id', u.perfil_id,
            'perfil_nombre', p.nombre,
            'chorario_id', u.chorario_id,
            'chorario_nombre', h.nombre,
            'grupo_id', u.grupo_id,
            'grupo_nombre', g.nombre,
            'perfil', jsonb_build_object('id', p.id, 'nombre', p.nombre),
            'chorario', jsonb_build_object('id', h.id, 'nombre', h.nombre),
            'created_by', u.created_by,
            'created_at', to_char(u.created_at, 'YYYY-MM-DD HH24:MI:SS'),
            'updated_by', u.updated_by,
            'updated_at', to_char(u.updated_at, 'YYYY-MM-DD HH24:MI:SS'),
            'last_login_at', to_char(u.last_login_at, 'YYYY-MM-DD HH24:MI:SS'),
            'user_verified_at', to_char(u.user_verified_at, 'YYYY-MM-DD HH24:MI:SS'),
            'email_verified_at', to_char(u.email_verified_at, 'YYYY-MM-DD HH24:MI:SS')
        )
    ) INTO v_resultado
    FROM seguridad.users u
    LEFT JOIN seguridad.perfiles p ON p.id = u.perfil_id
    LEFT JOIN seguridad.chorarios h ON h.id = u.chorario_id
    LEFT JOIN seguridad.grupos    g ON g.id = u.grupo_id
    WHERE u.id = p_id;

    RETURN v_resultado;

EXCEPTION
    -- Único caso capturado, y se RE-LANZA. Nunca un «WHEN OTHERS».
    WHEN unique_violation THEN
        RAISE EXCEPTION 'Ya existe otro usuario con ese login o email'
            USING ERRCODE = 'P0006';
END;
$function$;

-- ---------------------------------------------------------------------------
-- fn_usuarios_obtener (devuelve grupo)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION seguridad.fn_usuarios_obtener(p_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    v_data JSONB;
    v_resultado JSONB;
BEGIN
    -- Consulta el usuario con su perfil asociado
    SELECT jsonb_build_object(
        'id', u.id,
        'name', u.name,
        'surname', u.surname,
        'email', u.email,
        'phone', u.phone,
        'login_user', u.login_user,
        'avatar', u.avatar,
        'type_user', u.type_user,
        'isactive', u.isactive,
		'isreset', u.isreset,
        'islogin', u.islogin,
        'perfil_id', u.perfil_id,
        'perfil_nombre', p.nombre,
        'chorario_id', u.chorario_id,
		'chorario_nombre', h.nombre,
        'grupo_id', u.grupo_id,
        'grupo_nombre', g.nombre,
        'created_by', u.created_by,
        'updated_by', u.updated_by,
        'created_at', to_char(u.created_at, 'YYYY-MM-DD HH24:MI:SS'),
        'updated_at', to_char(u.updated_at, 'YYYY-MM-DD HH24:MI:SS'),
        'email_verified_at', to_char(u.email_verified_at, 'YYYY-MM-DD HH24:MI:SS'),
        'user_verified_at', to_char(u.user_verified_at, 'YYYY-MM-DD HH24:MI:SS'),
        'last_login_at', to_char(u.last_login_at, 'YYYY-MM-DD HH24:MI:SS')
    ) INTO v_data
    FROM seguridad.users u
    LEFT JOIN seguridad.perfiles p ON p.id = u.perfil_id
	LEFT JOIN seguridad.chorarios h ON h.id = u.chorario_id
    LEFT JOIN seguridad.grupos    g ON g.id = u.grupo_id
    WHERE u.id = p_id;
    
    -- Verifica si se encontró el usuario
    IF v_data IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'message', 'Usuario no encontrado',
            'error_code', 'USER_NOT_FOUND',
            'data', null
        );
    END IF;
    
    -- Construye respuesta exitosa
    v_resultado := jsonb_build_object(
        'success', true,
        'message', 'Usuario obtenido exitosamente',
        'data', v_data
    );
    
    RETURN v_resultado;
    
EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object(
            'success', false,
            'message', 'Error al obtener usuario: ' || SQLERRM,
            'error_code', SQLSTATE
        );
END;
$function$;

-- ---------------------------------------------------------------------------
-- fn_usuarios_listar_paginado (devuelve grupo)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION seguridad.fn_usuarios_listar_paginado(p_page integer DEFAULT 1, p_per_page integer DEFAULT 15, p_search text DEFAULT ''::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    v_offset INTEGER;
    v_total BIGINT;
    v_data JSONB;
    v_resultado JSONB;
    v_search_terms TEXT[];
BEGIN
    -- Calcular offset
    v_offset := (p_page - 1) * p_per_page;
    
    -- Convertir búsqueda en array de palabras
    v_search_terms := string_to_array(trim(p_search), ' ');
    
    -- 1. Contar total con filtro
    IF p_search IS NOT NULL AND p_search != '' THEN
        SELECT COUNT(*) INTO v_total
        FROM seguridad.users u
        WHERE u.login_user ILIKE '%' || p_search || '%' 
           OR u.name ILIKE '%' || p_search || '%'
           OR u.surname ILIKE '%' || p_search || '%'
           OR u.email ILIKE '%' || p_search || '%'
           OR u.id::text ILIKE '%' || p_search || '%'
           -- Buscar cada palabra en el nombre completo
           OR (
               SELECT bool_and(
                   EXISTS (
                       SELECT 1 
                       WHERE CONCAT_WS(' ', u.name, u.surname) ILIKE '%' || term || '%'
                       OR CONCAT_WS(' ', u.surname, u.name) ILIKE '%' || term || '%'
                   )
               )
               FROM unnest(v_search_terms) AS term
           );
    ELSE
        SELECT COUNT(*) INTO v_total FROM seguridad.users;
    END IF;
    
    -- 2. Consulta paginada
    IF p_search IS NOT NULL AND p_search != '' THEN
        SELECT COALESCE(
            (SELECT jsonb_agg(
                jsonb_build_object(
                    'id', t.id,
                    'login_user', t.login_user,
                    'name', t.name,
                    'surname', t.surname,
                    'email', t.email,
                    'phone', t.phone,
                    'avatar', t.avatar,
                    'type_user', t.type_user,
                    'isactive', t.isactive,
                    'islogin', t.islogin,
                    'isreset', t.isreset,
                    'perfil_id', t.perfil_id,
                    'perfil_nombre', p.nombre,
                    'chorario_id', t.chorario_id,
                    'chorario_nombre', h.nombre,
                    'grupo_id', t.grupo_id,
                    'grupo_nombre', g.nombre,
                    'created_by', t.created_by,
                    'updated_by', t.updated_by,
                    'created_at', to_char(t.created_at, 'YYYY-MM-DD HH24:MI:SS'),
                    'updated_at', to_char(t.updated_at, 'YYYY-MM-DD HH24:MI:SS'),
                    'email_verified_at', to_char(t.email_verified_at, 'YYYY-MM-DD HH24:MI:SS'),
                    'user_verified_at', to_char(t.user_verified_at, 'YYYY-MM-DD HH24:MI:SS'),
                    'last_login_at', to_char(t.last_login_at, 'YYYY-MM-DD HH24:MI:SS')
                )
                ORDER BY t.id DESC
            )
            FROM (
                SELECT u.id, u.login_user, u.name, u.surname, u.email, u.phone, u.avatar,
                       u.type_user, u.isactive, u.islogin, u.isreset, u.perfil_id, u.chorario_id, u.grupo_id,
                       u.created_by, u.updated_by, u.created_at, u.updated_at,
                       u.email_verified_at, u.user_verified_at, u.last_login_at
                FROM seguridad.users u
                WHERE u.login_user ILIKE '%' || p_search || '%' 
                   OR u.name ILIKE '%' || p_search || '%'
                   OR u.surname ILIKE '%' || p_search || '%'
                   OR u.email ILIKE '%' || p_search || '%'
                   OR u.id::text ILIKE '%' || p_search || '%'
                   -- Buscar cada palabra en el nombre completo
                   OR (
                       SELECT bool_and(
                           EXISTS (
                               SELECT 1 
                               WHERE CONCAT_WS(' ', u.name, u.surname) ILIKE '%' || term || '%'
                               OR CONCAT_WS(' ', u.surname, u.name) ILIKE '%' || term || '%'
                           )
                       )
                       FROM unnest(v_search_terms) AS term
                   )
                ORDER BY u.id DESC
                LIMIT p_per_page OFFSET v_offset
            ) t
            LEFT JOIN seguridad.perfiles p ON p.id = t.perfil_id
            LEFT JOIN seguridad.chorarios h ON h.id = t.chorario_id
            LEFT JOIN seguridad.grupos    g ON g.id = t.grupo_id
            ), '[]'::jsonb) INTO v_data;
    ELSE
        SELECT COALESCE(
            (SELECT jsonb_agg(
                jsonb_build_object(
                    'id', t.id,
                    'login_user', t.login_user,
                    'name', t.name,
                    'surname', t.surname,
                    'email', t.email,
                    'phone', t.phone,
                    'avatar', t.avatar,
                    'type_user', t.type_user,
                    'isactive', t.isactive,
                    'islogin', t.islogin,
                    'isreset', t.isreset,
                    'perfil_id', t.perfil_id,
                    'perfil_nombre', p.nombre,
                    'chorario_id', t.chorario_id,
                    'chorario_nombre', h.nombre,
                    'grupo_id', t.grupo_id,
                    'grupo_nombre', g.nombre,
                    'created_by', t.created_by,
                    'updated_by', t.updated_by,
                    'created_at', to_char(t.created_at, 'YYYY-MM-DD HH24:MI:SS'),
                    'updated_at', to_char(t.updated_at, 'YYYY-MM-DD HH24:MI:SS'),
                    'email_verified_at', to_char(t.email_verified_at, 'YYYY-MM-DD HH24:MI:SS'),
                    'user_verified_at', to_char(t.user_verified_at, 'YYYY-MM-DD HH24:MI:SS'),
                    'last_login_at', to_char(t.last_login_at, 'YYYY-MM-DD HH24:MI:SS')
                )
                ORDER BY t.id DESC
            )
            FROM (
                SELECT u.id, u.login_user, u.name, u.surname, u.email, u.phone, u.avatar,
                       u.type_user, u.isactive, u.islogin, u.isreset, u.perfil_id, u.chorario_id, u.grupo_id,
                       u.created_by, u.updated_by, u.created_at, u.updated_at,
                       u.email_verified_at, u.user_verified_at, u.last_login_at
                FROM seguridad.users u
                ORDER BY u.id DESC
                LIMIT p_per_page OFFSET v_offset
            ) t
            LEFT JOIN seguridad.perfiles p ON p.id = t.perfil_id
            LEFT JOIN seguridad.chorarios h ON h.id = t.chorario_id
            LEFT JOIN seguridad.grupos    g ON g.id = t.grupo_id
            ), '[]'::jsonb) INTO v_data;
    END IF;
    
    -- 3. Construir resultado
    v_resultado := jsonb_build_object(
        'data', v_data,
        'meta', jsonb_build_object(
            'total', v_total,
            'per_page', p_per_page,
            'current_page', p_page,
            'last_page', CASE WHEN v_total = 0 THEN 1 ELSE ceil(v_total::NUMERIC / p_per_page) END
        )
    );
    
    RETURN v_resultado;
    
EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object(
            'success', false,
            'message', 'Error al listar usuarios: ' || SQLERRM,
            'error_code', SQLSTATE
        );
END;
$function$;
