-- ============================================================================
-- PAPELERA DE RECICLAJE DE USUARIOS (borrado lógico), como la del
-- administrador de archivos: "eliminar" un usuario lo manda a la papelera
-- (deleted_at / deleted_by), desde donde se restaura o se borra de verdad.
--
--   seguridad.users.deleted_at / deleted_by           nuevas columnas
--   seguridad.fn_usuarios_eliminar(...)               AHORA borrado lógico (+ cierra sus sesiones)
--   seguridad.fn_usuarios_papelera_listar()           lo que hay en la papelera
--   seguridad.fn_usuarios_restaurar(ids, ...)         vuelven a estar activos
--   seguridad.fn_usuarios_eliminar_definitivo(ids,..) DELETE real (sólo de la papelera)
--   seguridad.fn_usuarios_papelera_vaciar(...)        DELETE real de todo lo que hay
--
-- Los eliminados NO salen en ningún listado ni cuentan en los grupos:
-- se reescriben fn_usuarios_listar_paginado, fn_usuarios_listar_por_grupo,
-- fn_usuarios_mover_grupo, fn_grupos_listar y fn_grupos_json con
-- «deleted_at IS NULL», y fn_usuarios_crear / modificar avisan cuando el
-- login o el email que se repite es de alguien que está en la papelera.
-- El login y el middleware (back) también rechazan a los eliminados.
--
-- Errores de negocio nuevos: P0018 no puede eliminarse a sí mismo;
-- P0019 el usuario no está en la papelera.
-- Idempotente: IF NOT EXISTS / CREATE OR REPLACE.
-- ============================================================================

ALTER TABLE seguridad.users ADD COLUMN IF NOT EXISTS deleted_at timestamptz;
ALTER TABLE seguridad.users ADD COLUMN IF NOT EXISTS deleted_by varchar;
COMMENT ON COLUMN seguridad.users.deleted_at IS 'Fecha en que se envió a la papelera de reciclaje (NULL = vigente)';
COMMENT ON COLUMN seguridad.users.deleted_by IS 'Login de quien lo envió a la papelera';
CREATE INDEX IF NOT EXISTS ix_users_deleted_at ON seguridad.users (deleted_at) WHERE deleted_at IS NOT NULL;

-- ---------------------------------------------------------------------------
-- Fila de usuario en json (sin password ni códigos), común a varias funciones
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION seguridad.fn_usuarios_json(p_id bigint)
RETURNS jsonb
LANGUAGE sql
STABLE
AS $function$
    SELECT jsonb_build_object(
        'id',                u.id,
        'login_user',        u.login_user,
        'name',              u.name,
        'surname',           u.surname,
        'email',             u.email,
        'phone',             u.phone,
        'avatar',            u.avatar,
        'type_user',         u.type_user,
        'isactive',          u.isactive,
        'islogin',           u.islogin,
        'isreset',           u.isreset,
        'perfil_id',         u.perfil_id,
        'perfil_nombre',     p.nombre,
        'chorario_id',       u.chorario_id,
        'chorario_nombre',   h.nombre,
        'grupo_id',          u.grupo_id,
        'grupo_nombre',      g.nombre,
        'created_by',        u.created_by,
        'updated_by',        u.updated_by,
        'created_at',        to_char(u.created_at, 'YYYY-MM-DD HH24:MI:SS'),
        'updated_at',        to_char(u.updated_at, 'YYYY-MM-DD HH24:MI:SS'),
        'email_verified_at', to_char(u.email_verified_at, 'YYYY-MM-DD HH24:MI:SS'),
        'user_verified_at',  to_char(u.user_verified_at, 'YYYY-MM-DD HH24:MI:SS'),
        'last_login_at',     to_char(u.last_login_at, 'YYYY-MM-DD HH24:MI:SS'),
        'deleted_at',        to_char(u.deleted_at, 'YYYY-MM-DD HH24:MI:SS'),
        'deleted_by',        u.deleted_by
    )
    FROM seguridad.users u
    LEFT JOIN seguridad.perfiles  p ON p.id = u.perfil_id
    LEFT JOIN seguridad.chorarios h ON h.id = u.chorario_id
    LEFT JOIN seguridad.grupos    g ON g.id = u.grupo_id
    WHERE u.id = p_id;
$function$;

-- ---------------------------------------------------------------------------
-- Contexto de auditoría (lo leen los triggers de seguridad.users)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION seguridad.fn_usuarios_contexto_auditoria(
    p_usuario_id bigint, p_usuario_login varchar, p_usuario_nombre varchar,
    p_ip_address inet, p_user_agent text, p_request_id uuid
)
RETURNS void
LANGUAGE plpgsql
AS $function$
BEGIN
    PERFORM set_config('app.usuario_id',     COALESCE(p_usuario_id::text, ''), true);
    PERFORM set_config('app.usuario_login',  COALESCE(p_usuario_login, current_user), true);
    PERFORM set_config('app.usuario_nombre', COALESCE(p_usuario_nombre, current_user), true);
    PERFORM set_config('app.ip_address',     COALESCE(p_ip_address::text, ''), true);
    PERFORM set_config('app.user_agent',     COALESCE(p_user_agent, ''), true);
    PERFORM set_config('app.request_id',     COALESCE(p_request_id::text, ''), true);
    PERFORM set_config('app.modulo',         'seguridad.users', true);
END;
$function$;

-- ---------------------------------------------------------------------------
-- ELIMINAR = enviar a la papelera (borrado lógico). Cierra sus sesiones.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION seguridad.fn_usuarios_eliminar(
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
    v_antes  jsonb;
    v_fecha  timestamptz := CURRENT_TIMESTAMP;
    v_actual record;
BEGIN
    PERFORM seguridad.fn_usuarios_contexto_auditoria(p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    SELECT id, login_user, deleted_at INTO v_actual FROM seguridad.users WHERE id = p_id;
    IF NOT FOUND OR v_actual.deleted_at IS NOT NULL THEN
        RAISE EXCEPTION 'El usuario no existe' USING ERRCODE = 'P0013';
    END IF;
    IF p_usuario_id IS NOT NULL AND p_usuario_id = p_id THEN
        RAISE EXCEPTION 'No puede enviarse a sí mismo a la papelera' USING ERRCODE = 'P0018';
    END IF;

    v_antes := seguridad.fn_usuarios_json(p_id);
    PERFORM set_config('app.datos_anteriores', v_antes::text, true);
    PERFORM set_config('app.datos_nuevos', (v_antes || jsonb_build_object(
        'deleted_at', to_char(v_fecha, 'YYYY-MM-DD HH24:MI:SS'), 'deleted_by', p_usuario_login, 'islogin', false
    ))::text, true);

    -- Fuera sus sesiones: deja de poder usar el sistema en el acto
    DELETE FROM seguridad.sesiones_activas WHERE user_id = p_id;

    UPDATE seguridad.users
       SET deleted_at = v_fecha,
           deleted_by = p_usuario_login,
           islogin    = false,
           updated_by = COALESCE(p_usuario_login, updated_by),
           updated_at = v_fecha
     WHERE id = p_id;

    PERFORM set_config('app.datos_anteriores', '', true);
    PERFORM set_config('app.datos_nuevos', '', true);

    RETURN jsonb_build_object(
        'success', true,
        'message', format('Usuario «%s» enviado a la papelera de reciclaje', v_actual.login_user),
        'data', seguridad.fn_usuarios_json(p_id)
    );
END;
$function$;

-- ---------------------------------------------------------------------------
-- PAPELERA: lo que hay (más reciente primero)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION seguridad.fn_usuarios_papelera_listar()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
    v_data jsonb;
BEGIN
    SELECT COALESCE(jsonb_agg(seguridad.fn_usuarios_json(u.id) ORDER BY u.deleted_at DESC, u.id DESC), '[]'::jsonb)
      INTO v_data
      FROM seguridad.users u
     WHERE u.deleted_at IS NOT NULL;
    RETURN jsonb_build_object('success', true, 'data', v_data, 'total', jsonb_array_length(v_data));
END;
$function$;

-- ---------------------------------------------------------------------------
-- RESTAURAR (uno o varios): vuelven a la lista tal como estaban
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION seguridad.fn_usuarios_restaurar(
    p_ids            jsonb,
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
    v_u        record;
    v_antes    jsonb;
    v_n        integer := 0;
    v_fecha    timestamptz := CURRENT_TIMESTAMP;
    v_nombres  text[] := '{}';
BEGIN
    PERFORM seguridad.fn_usuarios_contexto_auditoria(p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);
    IF p_ids IS NULL OR jsonb_typeof(p_ids) <> 'array' OR jsonb_array_length(p_ids) = 0 THEN
        RAISE EXCEPTION 'No se indicó ningún usuario' USING ERRCODE = 'P0001';
    END IF;

    FOR v_u IN
        SELECT u.id, u.login_user
          FROM seguridad.users u
         WHERE u.id IN (SELECT (x)::bigint FROM jsonb_array_elements_text(p_ids) x)
           AND u.deleted_at IS NOT NULL
    LOOP
        v_antes := seguridad.fn_usuarios_json(v_u.id);
        PERFORM set_config('app.datos_anteriores', v_antes::text, true);
        PERFORM set_config('app.datos_nuevos', (v_antes || jsonb_build_object('deleted_at', NULL, 'deleted_by', NULL))::text, true);

        UPDATE seguridad.users
           SET deleted_at = NULL, deleted_by = NULL,
               updated_by = COALESCE(p_usuario_login, updated_by), updated_at = v_fecha
         WHERE id = v_u.id;

        v_n := v_n + 1;
        v_nombres := v_nombres || v_u.login_user::text;
    END LOOP;

    PERFORM set_config('app.datos_anteriores', '', true);
    PERFORM set_config('app.datos_nuevos', '', true);

    IF v_n = 0 THEN
        RAISE EXCEPTION 'Ninguno de esos usuarios está en la papelera' USING ERRCODE = 'P0019';
    END IF;

    RETURN jsonb_build_object(
        'success', true,
        'message', CASE WHEN v_n = 1 THEN format('Usuario «%s» restaurado', v_nombres[1]) ELSE format('%s usuarios restaurados', v_n) END,
        'data', jsonb_build_object('restaurados', v_n, 'logins', to_jsonb(v_nombres))
    );
END;
$function$;

-- ---------------------------------------------------------------------------
-- ELIMINAR DEFINITIVAMENTE (uno o varios de la papelera). Devuelve los
-- avatares para que el back borre los ficheros. sesiones_activas cae en cascada.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION seguridad.fn_usuarios_eliminar_definitivo(
    p_ids            jsonb,
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
    v_u        record;
    v_n        integer := 0;
    v_avatares text[] := '{}';
    v_nombres  text[] := '{}';
BEGIN
    PERFORM seguridad.fn_usuarios_contexto_auditoria(p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);
    IF p_ids IS NULL OR jsonb_typeof(p_ids) <> 'array' OR jsonb_array_length(p_ids) = 0 THEN
        RAISE EXCEPTION 'No se indicó ningún usuario' USING ERRCODE = 'P0001';
    END IF;

    FOR v_u IN
        SELECT u.id, u.login_user, u.avatar
          FROM seguridad.users u
         WHERE u.id IN (SELECT (x)::bigint FROM jsonb_array_elements_text(p_ids) x)
           AND u.deleted_at IS NOT NULL      -- sólo lo que está en la papelera
    LOOP
        PERFORM set_config('app.datos_anteriores', seguridad.fn_usuarios_json(v_u.id)::text, true);
        DELETE FROM seguridad.users WHERE id = v_u.id;
        v_n := v_n + 1;
        v_nombres := v_nombres || v_u.login_user::text;
        IF v_u.avatar IS NOT NULL AND v_u.avatar <> '' THEN v_avatares := v_avatares || v_u.avatar::text; END IF;
    END LOOP;

    PERFORM set_config('app.datos_anteriores', '', true);

    IF v_n = 0 THEN
        RAISE EXCEPTION 'Ninguno de esos usuarios está en la papelera' USING ERRCODE = 'P0019';
    END IF;

    RETURN jsonb_build_object(
        'success', true,
        'message', CASE WHEN v_n = 1 THEN format('Usuario «%s» eliminado definitivamente', v_nombres[1]) ELSE format('%s usuarios eliminados definitivamente', v_n) END,
        'data', jsonb_build_object('borrados', v_n, 'logins', to_jsonb(v_nombres), 'avatares', to_jsonb(v_avatares))
    );

EXCEPTION
    WHEN foreign_key_violation THEN
        RAISE EXCEPTION 'No se puede eliminar definitivamente: el usuario tiene registros asociados' USING ERRCODE = 'P0014';
END;
$function$;

-- ---------------------------------------------------------------------------
-- VACIAR LA PAPELERA
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION seguridad.fn_usuarios_papelera_vaciar(
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
    v_ids jsonb;
    v_res jsonb;
BEGIN
    SELECT COALESCE(jsonb_agg(u.id), '[]'::jsonb) INTO v_ids FROM seguridad.users u WHERE u.deleted_at IS NOT NULL;
    IF jsonb_array_length(v_ids) = 0 THEN
        RETURN jsonb_build_object('success', true, 'message', 'La papelera ya estaba vacía',
                                  'data', jsonb_build_object('borrados', 0, 'logins', '[]'::jsonb, 'avatares', '[]'::jsonb));
    END IF;
    v_res := seguridad.fn_usuarios_eliminar_definitivo(v_ids, p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);
    RETURN v_res || jsonb_build_object('message', format('Papelera vaciada: %s usuario(s) eliminado(s) definitivamente', v_res->'data'->>'borrados'));
END;
$function$;

-- ===========================================================================
-- LISTADOS: sin los usuarios de la papelera
-- ===========================================================================

-- Búsqueda común a los dos listados: login, nombre, apellido, email, id y
-- cada palabra del filtro contra "nombre apellido" / "apellido nombre".
CREATE OR REPLACE FUNCTION seguridad.fn_usuarios_coincide(p_u seguridad.users, p_filtro text)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
AS $function$
    SELECT p_filtro IS NULL
        OR (p_u).login_user ILIKE '%' || p_filtro || '%'
        OR (p_u).name       ILIKE '%' || p_filtro || '%'
        OR (p_u).surname    ILIKE '%' || p_filtro || '%'
        OR (p_u).email      ILIKE '%' || p_filtro || '%'
        OR (p_u).id::text   ILIKE '%' || p_filtro || '%'
        OR (SELECT bool_and(CONCAT_WS(' ', (p_u).name, (p_u).surname) ILIKE '%' || term || '%'
                         OR CONCAT_WS(' ', (p_u).surname, (p_u).name) ILIKE '%' || term || '%')
              FROM unnest(string_to_array(p_filtro, ' ')) AS term);
$function$;

-- LISTADO PAGINADO (allUsers). Misma respuesta de siempre: {data, meta}.
CREATE OR REPLACE FUNCTION seguridad.fn_usuarios_listar_paginado(
    p_page     integer DEFAULT 1,
    p_per_page integer DEFAULT 15,
    p_search   text    DEFAULT ''
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
    v_offset integer;
    v_total  bigint;
    v_data   jsonb;
    v_filtro text;
BEGIN
    v_offset := (GREATEST(COALESCE(p_page, 1), 1) - 1) * p_per_page;
    v_filtro := NULLIF(TRIM(COALESCE(p_search, '')), '');

    SELECT COUNT(*) INTO v_total
      FROM seguridad.users u
     WHERE u.deleted_at IS NULL AND seguridad.fn_usuarios_coincide(u, v_filtro);

    SELECT COALESCE(jsonb_agg(seguridad.fn_usuarios_json(t.id) ORDER BY t.id DESC), '[]'::jsonb) INTO v_data
      FROM (
        SELECT u.id
          FROM seguridad.users u
         WHERE u.deleted_at IS NULL AND seguridad.fn_usuarios_coincide(u, v_filtro)
         ORDER BY u.id DESC
         LIMIT p_per_page OFFSET v_offset
      ) t;

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

-- USUARIOS DE UN GRUPO (árbol + grilla). NULL = todos, 0 = sin grupo.
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
    v_offset integer;
    v_total  bigint;
    v_data   jsonb;
    v_filtro text;
    v_grupos bigint[];
BEGIN
    v_offset := (GREATEST(COALESCE(p_page, 1), 1) - 1) * p_per_page;
    v_filtro := NULLIF(TRIM(COALESCE(p_search, '')), '');

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
     WHERE u.deleted_at IS NULL
       AND (   p_grupo_id IS NULL
            OR (p_grupo_id = 0 AND u.grupo_id IS NULL)
            OR (v_grupos IS NOT NULL AND u.grupo_id = ANY (v_grupos)))
       AND seguridad.fn_usuarios_coincide(u, v_filtro);

    SELECT COUNT(*) INTO v_total FROM tmp_usuarios_grupo;

    SELECT COALESCE(jsonb_agg(seguridad.fn_usuarios_json(t.id) ORDER BY t.surname, t.name, t.id), '[]'::jsonb) INTO v_data
      FROM (
        SELECT u.id, u.surname, u.name
          FROM seguridad.users u
          JOIN tmp_usuarios_grupo f ON f.id = u.id
         ORDER BY u.surname, u.name, u.id
         LIMIT p_per_page OFFSET v_offset
      ) t;

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

-- MOVER USUARIOS A UN GRUPO: ignora los de la papelera
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
    PERFORM seguridad.fn_usuarios_contexto_auditoria(p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

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
           AND u.deleted_at IS NULL
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

-- GRUPO EN JSON: los contadores no incluyen la papelera
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
        'num_usuarios',     (SELECT COUNT(*) FROM seguridad.users u WHERE u.grupo_id = g.id AND u.deleted_at IS NULL),
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

-- ÁRBOL DE GRUPOS: contadores sin la papelera, más cuántos hay en ella
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
        WITH RECURSIVE d AS (
            SELECT g.id AS raiz, g.id
              FROM seguridad.grupos g
            UNION ALL
            SELECT d.raiz, c.id
              FROM seguridad.grupos c JOIN d ON c.padre_id = d.id
        )
        SELECT d.raiz AS id, COUNT(u.id) AS num_usuarios_total
          FROM d LEFT JOIN seguridad.users u ON u.grupo_id = d.id AND u.deleted_at IS NULL
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
            'num_usuarios',       (SELECT COUNT(*) FROM seguridad.users u WHERE u.grupo_id = a.id AND u.deleted_at IS NULL),
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
        'sin_grupo',      (SELECT COUNT(*) FROM seguridad.users u WHERE u.grupo_id IS NULL AND u.deleted_at IS NULL),
        'total_usuarios', (SELECT COUNT(*) FROM seguridad.users u WHERE u.deleted_at IS NULL),
        'en_papelera',    (SELECT COUNT(*) FROM seguridad.users u WHERE u.deleted_at IS NOT NULL)
    );
END;
$function$;

-- ===========================================================================
-- fn_usuarios_crear / fn_usuarios_modificar: mismo cuerpo, con aviso cuando el
-- login o el email repetido pertenece a alguien de la papelera (se generan
-- a partir de las funciones actuales: ver más abajo).
-- ===========================================================================

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
    IF EXISTS (SELECT 1 FROM seguridad.users WHERE login_user = TRIM(p_login_user) AND deleted_at IS NOT NULL) THEN
        RAISE EXCEPTION 'Ya existe un usuario con ese login en la papelera de reciclaje: restáurelo o elimínelo definitivamente' USING ERRCODE = 'P0006';
    END IF;
    IF EXISTS (SELECT 1 FROM seguridad.users WHERE login_user = TRIM(p_login_user)) THEN
        RAISE EXCEPTION 'Ya existe un usuario con ese login' USING ERRCODE = 'P0006';
    END IF;

    -- 6. Email único
    IF EXISTS (SELECT 1 FROM seguridad.users WHERE email = TRIM(p_email) AND deleted_at IS NOT NULL) THEN
        RAISE EXCEPTION 'Ya existe un usuario con ese email en la papelera de reciclaje: restáurelo o elimínelo definitivamente' USING ERRCODE = 'P0006';
    END IF;
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

    IF NOT FOUND OR EXISTS (SELECT 1 FROM seguridad.users WHERE id = p_id AND deleted_at IS NOT NULL) THEN
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
    IF EXISTS (SELECT 1 FROM seguridad.users WHERE login_user = TRIM(p_login_user) AND deleted_at IS NOT NULL AND id <> p_id) THEN
        RAISE EXCEPTION 'Ya existe un usuario con ese login en la papelera de reciclaje: restáurelo o elimínelo definitivamente' USING ERRCODE = 'P0006';
    END IF;
    IF EXISTS (SELECT 1 FROM seguridad.users WHERE login_user = TRIM(p_login_user) AND id <> p_id) THEN
        RAISE EXCEPTION 'Ya existe otro usuario con ese login' USING ERRCODE = 'P0006';
    END IF;

    -- 6. Email único (excluyendo el propio usuario)
    IF EXISTS (SELECT 1 FROM seguridad.users WHERE email = TRIM(p_email) AND deleted_at IS NOT NULL AND id <> p_id) THEN
        RAISE EXCEPTION 'Ya existe un usuario con ese email en la papelera de reciclaje: restáurelo o elimínelo definitivamente' USING ERRCODE = 'P0006';
    END IF;
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
