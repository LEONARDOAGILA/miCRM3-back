-- ============================================================================
-- BOLETINES (esquema core): avisos con imágenes que se muestran al usuario
-- nada más entrar al sistema.
--
--   core.boletines            el boletín: título, texto y vigencia
--   core.boletines_imagenes   las imágenes del carrusel, en orden
--   core.boletines_usuarios   destinatarios uno a uno
--   core.boletines_grupos     destinatarios por grupo (con o sin subgrupos)
--   core.boletines_vistos     quién lo vio y quién pidió no volver a verlo
--
--   core.fn_boletines_listar_paginado(...)  grilla con filtro y estado
--   core.fn_boletines_obtener(id)           con imágenes y destinatarios
--   core.fn_boletines_crear(datos, ...)
--   core.fn_boletines_modificar(id, datos, ...)
--   core.fn_boletines_eliminar(id, ...)     borrado lógico (papelera)
--   core.fn_boletines_restaurar(id, ...)
--   core.fn_boletines_destinatarios(id)     usuarios que lo verán (resueltos)
--   core.fn_boletines_mios(user_id)         los vigentes de un usuario
--   core.fn_boletines_marcar_visto(...)     registra la lectura
--   core.fn_boletines_imagen(imagen_id)     datos del fichero para servirlo
--
-- Mismo esquema que el resto del sistema: la lógica vive aquí, el contexto de
-- auditoría lo leen los triggers y las reglas de negocio se lanzan con
-- RAISE EXCEPTION + SQLSTATE propio para que el back las traduzca a 4xx:
--   P0001 datos obligatorios   P0010 valor no admitido   P0013 no existe
-- Idempotente: IF NOT EXISTS / CREATE OR REPLACE.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- TABLAS
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS core.boletines (
    id           bigserial PRIMARY KEY,
    titulo       varchar(200) NOT NULL,
    descripcion  text,
    /** Vigencia: fuera de estas fechas el boletín no se muestra */
    desde        date         NOT NULL DEFAULT CURRENT_DATE,
    hasta        date         NOT NULL,
    /** Orden en el carrusel cuando el usuario tiene varios (mayor primero) */
    prioridad    smallint     NOT NULL DEFAULT 0,
    /** Obliga a confirmar la lectura antes de poder cerrarlo */
    obligatorio  boolean      NOT NULL DEFAULT false,
    activo       boolean      NOT NULL DEFAULT true,
    deleted_at   timestamptz,
    deleted_by   varchar,
    created_at   timestamptz DEFAULT now(),
    updated_at   timestamptz DEFAULT now(),
    created_by   varchar,
    updated_by   varchar,
    CONSTRAINT ck_boletines_vigencia CHECK (hasta >= desde)
);

COMMENT ON TABLE  core.boletines IS 'Boletines informativos que se muestran al usuario al iniciar sesión';
COMMENT ON COLUMN core.boletines.prioridad IS 'Orden en el carrusel: los de mayor prioridad se muestran primero';

CREATE INDEX IF NOT EXISTS ix_boletines_vigencia ON core.boletines (desde, hasta) WHERE deleted_at IS NULL AND activo;

CREATE TABLE IF NOT EXISTS core.boletines_imagenes (
    id          bigserial PRIMARY KEY,
    boletin_id  bigint       NOT NULL REFERENCES core.boletines(id) ON DELETE CASCADE,
    /** Nombre del fichero dentro de storage/app/public/img/boletines */
    archivo     varchar(255) NOT NULL,
    titulo      varchar(200),
    descripcion text,
    orden       integer      NOT NULL DEFAULT 0,
    /** IMAGEN, VIDEO o AUDIO: lo decide la extensión del fichero */
    tipo        varchar(10)  NOT NULL DEFAULT 'IMAGEN' CHECK (tipo IN ('IMAGEN', 'VIDEO', 'AUDIO')),
    /** Segundos que la imagen se queda en pantalla dentro del carrusel
        (el video y el audio duran lo que dure su reproducción) */
    segundos    smallint     NOT NULL DEFAULT 6 CHECK (segundos BETWEEN 1 AND 120),
    created_at  timestamptz DEFAULT now(),
    updated_at  timestamptz DEFAULT now(),
    created_by  varchar,
    updated_by  varchar
);

COMMENT ON TABLE core.boletines_imagenes IS 'Imágenes del carrusel de un boletín, en el orden en que se muestran';
CREATE INDEX IF NOT EXISTS ix_boletines_imagenes_boletin ON core.boletines_imagenes (boletin_id, orden);

CREATE TABLE IF NOT EXISTS core.boletines_usuarios (
    id         bigserial PRIMARY KEY,
    boletin_id bigint NOT NULL REFERENCES core.boletines(id) ON DELETE CASCADE,
    user_id    bigint NOT NULL REFERENCES seguridad.users(id) ON DELETE CASCADE,
    created_at timestamptz DEFAULT now(),
    created_by varchar,
    CONSTRAINT uk_boletines_usuarios UNIQUE (boletin_id, user_id)
);

COMMENT ON TABLE core.boletines_usuarios IS 'Destinatarios añadidos uno a uno';

CREATE TABLE IF NOT EXISTS core.boletines_grupos (
    id                 bigserial PRIMARY KEY,
    boletin_id         bigint  NOT NULL REFERENCES core.boletines(id) ON DELETE CASCADE,
    grupo_id           bigint  NOT NULL REFERENCES seguridad.grupos(id) ON DELETE CASCADE,
    /** Incluye a los usuarios de los subgrupos */
    incluir_subgrupos  boolean NOT NULL DEFAULT true,
    created_at timestamptz DEFAULT now(),
    created_by varchar,
    CONSTRAINT uk_boletines_grupos UNIQUE (boletin_id, grupo_id)
);

COMMENT ON TABLE core.boletines_grupos IS 'Destinatarios por grupo de usuarios (opcionalmente con sus subgrupos)';

CREATE TABLE IF NOT EXISTS core.boletines_vistos (
    id          bigserial PRIMARY KEY,
    boletin_id  bigint  NOT NULL REFERENCES core.boletines(id) ON DELETE CASCADE,
    user_id     bigint  NOT NULL REFERENCES seguridad.users(id) ON DELETE CASCADE,
    visto_at    timestamptz NOT NULL DEFAULT now(),
    veces       integer NOT NULL DEFAULT 1,
    /** El usuario pidió no volver a verlo (deja de aparecer al entrar) */
    no_mostrar  boolean NOT NULL DEFAULT false,
    CONSTRAINT uk_boletines_vistos UNIQUE (boletin_id, user_id)
);

COMMENT ON TABLE core.boletines_vistos IS 'Lectura de un boletín por usuario: cuándo, cuántas veces y si pidió no volver a verlo';

-- Auditoría: los mismos tres triggers que el resto del sistema
DO $bloque$
DECLARE t text;
BEGIN
    FOREACH t IN ARRAY ARRAY['boletines', 'boletines_imagenes'] LOOP
        EXECUTE format('DROP TRIGGER IF EXISTS trg_%s_audit ON core.%s', t, t);
        EXECUTE format('CREATE TRIGGER trg_%s_audit AFTER INSERT OR DELETE OR UPDATE ON core.%s FOR EACH ROW EXECUTE FUNCTION auditoria.fn_auditar_cambios()', t, t);
        EXECUTE format('DROP TRIGGER IF EXISTS trigger_%s_set_users ON core.%s', t, t);
        EXECUTE format('CREATE TRIGGER trigger_%s_set_users BEFORE INSERT OR UPDATE ON core.%s FOR EACH ROW EXECUTE FUNCTION auditoria.fn_set_audit_users()', t, t);
        EXECUTE format('DROP TRIGGER IF EXISTS trigger_%s_updated_at ON core.%s', t, t);
        EXECUTE format('CREATE TRIGGER trigger_%s_updated_at BEFORE UPDATE ON core.%s FOR EACH ROW EXECUTE FUNCTION auditoria.fn_update_updated_at_column()', t, t);
    END LOOP;
END;
$bloque$;

-- ---------------------------------------------------------------------------
-- Contexto de auditoría (lo leen los triggers)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION core.fn_boletines_contexto_auditoria(
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
    PERFORM set_config('app.modulo',         'boletines', true);
END;
$function$;

-- ---------------------------------------------------------------------------
-- Usuarios de un grupo, con o sin sus subgrupos
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION core.fn_boletines_usuarios_de_grupo(p_grupo_id bigint, p_subgrupos boolean)
RETURNS TABLE (user_id bigint)
LANGUAGE sql
STABLE
AS $function$
    WITH RECURSIVE rama AS (
        SELECT g.id FROM seguridad.grupos g WHERE g.id = p_grupo_id
        UNION ALL
        SELECT h.id
          FROM seguridad.grupos h
          JOIN rama r ON h.padre_id = r.id
         WHERE p_subgrupos
    )
    SELECT u.id
      FROM seguridad.users u
      JOIN rama r ON r.id = u.grupo_id
     WHERE u.deleted_at IS NULL;
$function$;

-- ---------------------------------------------------------------------------
-- Qué es cada fichero: la extensión manda, no lo que diga la pantalla
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION core.fn_boletines_tipo_archivo(p_archivo text)
RETURNS varchar
LANGUAGE sql
IMMUTABLE
AS $function$
    SELECT CASE
             WHEN lower(COALESCE(p_archivo, '')) ~ '\.(mp4|m4v|webm|ogv|mov)
CREATE OR REPLACE FUNCTION core.fn_boletines_json(p_id bigint)
RETURNS jsonb
LANGUAGE sql
STABLE
AS $function$
    SELECT jsonb_build_object(
        'id',            b.id,
        'titulo',        b.titulo,
        'descripcion',   b.descripcion,
        'desde',         to_char(b.desde, 'YYYY-MM-DD'),
        'hasta',         to_char(b.hasta, 'YYYY-MM-DD'),
        'prioridad',     b.prioridad,
        'obligatorio',   b.obligatorio,
        'activo',        b.activo,
        'vigente',       (b.activo AND CURRENT_DATE BETWEEN b.desde AND b.hasta),
        'estado',        CASE WHEN NOT b.activo               THEN 'INACTIVO'
                              WHEN CURRENT_DATE < b.desde     THEN 'PROGRAMADO'
                              WHEN CURRENT_DATE > b.hasta     THEN 'CADUCADO'
                              ELSE 'VIGENTE' END,
        'en_papelera',   (b.deleted_at IS NOT NULL),
        -- Para la papelera: cuándo y quién lo eliminó
        'deleted_at',    to_char(b.deleted_at, 'YYYY-MM-DD HH24:MI'),
        'deleted_by',    b.deleted_by,
        'imagenes',      COALESCE((
                            SELECT jsonb_agg(jsonb_build_object(
                                     'id', i.id, 'archivo', i.archivo, 'titulo', i.titulo,
                                     'descripcion', i.descripcion, 'orden', i.orden,
                                     'segundos', i.segundos, 'tipo', i.tipo
                                   ) ORDER BY i.orden, i.id)
                              FROM core.boletines_imagenes i WHERE i.boletin_id = b.id), '[]'::jsonb),
        'usuarios',      COALESCE((
                            SELECT jsonb_agg(jsonb_build_object(
                                     'user_id', u.id, 'login_user', u.login_user,
                                     'name', u.name, 'surname', u.surname, 'isactive', u.isactive
                                   ) ORDER BY u.login_user)
                              FROM core.boletines_usuarios bu
                              JOIN seguridad.users u ON u.id = bu.user_id AND u.deleted_at IS NULL
                             WHERE bu.boletin_id = b.id), '[]'::jsonb),
        'grupos',        COALESCE((
                            SELECT jsonb_agg(jsonb_build_object(
                                     'grupo_id', g.id, 'nombre', g.nombre,
                                     'incluir_subgrupos', bg.incluir_subgrupos
                                   ) ORDER BY g.nombre)
                              FROM core.boletines_grupos bg
                              JOIN seguridad.grupos g ON g.id = bg.grupo_id
                             WHERE bg.boletin_id = b.id), '[]'::jsonb),
        'num_imagenes',  (SELECT COUNT(*) FROM core.boletines_imagenes i WHERE i.boletin_id = b.id),
        'num_usuarios',  (SELECT COUNT(*) FROM core.boletines_usuarios bu WHERE bu.boletin_id = b.id),
        'num_grupos',    (SELECT COUNT(*) FROM core.boletines_grupos bg WHERE bg.boletin_id = b.id),
        'num_vistos',    (SELECT COUNT(*) FROM core.boletines_vistos v WHERE v.boletin_id = b.id),
        'created_by',    b.created_by,
        'updated_by',    b.updated_by,
        'created_at',    to_char(b.created_at, 'YYYY-MM-DD HH24:MI:SS'),
        'updated_at',    to_char(b.updated_at, 'YYYY-MM-DD HH24:MI:SS')
    )
    FROM core.boletines b
    WHERE b.id = p_id;
$function$;

-- ---------------------------------------------------------------------------
-- Listado paginado para la grilla
--   p_estado: TODOS | VIGENTE | PROGRAMADO | CADUCADO | INACTIVO
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION core.fn_boletines_listar_paginado(
    p_page     integer DEFAULT 1,
    p_per_page integer DEFAULT 15,
    p_search   text    DEFAULT '',
    p_estado   text    DEFAULT 'TODOS'
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
AS $function$
DECLARE
    v_offset integer;
    v_total  bigint;
    v_filtro text;
    v_estado text;
    v_data   jsonb;
BEGIN
    v_offset := (GREATEST(p_page, 1) - 1) * p_per_page;
    v_filtro := NULLIF(TRIM(COALESCE(p_search, '')), '');
    v_estado := UPPER(COALESCE(NULLIF(TRIM(p_estado), ''), 'TODOS'));

    SELECT COUNT(*) INTO v_total
      FROM core.boletines b
     WHERE b.deleted_at IS NULL
       AND (v_filtro IS NULL
            OR b.titulo ILIKE '%' || v_filtro || '%'
            OR b.descripcion ILIKE '%' || v_filtro || '%'
            OR b.id::text ILIKE '%' || v_filtro || '%')
       AND (v_estado = 'TODOS'
            OR (v_estado = 'VIGENTE'    AND b.activo AND CURRENT_DATE BETWEEN b.desde AND b.hasta)
            OR (v_estado = 'PROGRAMADO' AND b.activo AND CURRENT_DATE < b.desde)
            OR (v_estado = 'CADUCADO'   AND b.activo AND CURRENT_DATE > b.hasta)
            OR (v_estado = 'INACTIVO'   AND NOT b.activo));

    SELECT COALESCE(jsonb_agg(core.fn_boletines_json(t.id) ORDER BY t.prioridad DESC, t.desde DESC, t.id DESC), '[]'::jsonb)
      INTO v_data
      FROM (
        SELECT b.id, b.prioridad, b.desde
          FROM core.boletines b
         WHERE b.deleted_at IS NULL
           AND (v_filtro IS NULL
                OR b.titulo ILIKE '%' || v_filtro || '%'
                OR b.descripcion ILIKE '%' || v_filtro || '%'
                OR b.id::text ILIKE '%' || v_filtro || '%')
           AND (v_estado = 'TODOS'
                OR (v_estado = 'VIGENTE'    AND b.activo AND CURRENT_DATE BETWEEN b.desde AND b.hasta)
                OR (v_estado = 'PROGRAMADO' AND b.activo AND CURRENT_DATE < b.desde)
                OR (v_estado = 'CADUCADO'   AND b.activo AND CURRENT_DATE > b.hasta)
                OR (v_estado = 'INACTIVO'   AND NOT b.activo))
         ORDER BY b.prioridad DESC, b.desde DESC, b.id DESC
         LIMIT p_per_page OFFSET v_offset
      ) t;

    RETURN jsonb_build_object(
        'success', true,
        'message', 'La solicitud ha tenido éxito',
        'data', jsonb_build_object(
            'data', v_data,
            'current_page', GREATEST(p_page, 1),
            'per_page', p_per_page,
            'total', v_total,
            'last_page', GREATEST(CEIL(v_total::numeric / NULLIF(p_per_page, 0))::int, 1),
            -- Para el contador del botón de la papelera, sin pedir otra vuelta
            'en_papelera', (SELECT COUNT(*) FROM core.boletines WHERE deleted_at IS NOT NULL)
        )
    );
END;
$function$;

-- ---------------------------------------------------------------------------
-- Obtener uno
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION core.fn_boletines_obtener(p_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
AS $function$
DECLARE v_data jsonb;
BEGIN
    SELECT core.fn_boletines_json(p_id) INTO v_data;
    IF v_data IS NULL THEN
        RETURN jsonb_build_object('success', false, 'message', 'El boletín no existe', 'data', NULL);
    END IF;
    RETURN jsonb_build_object('success', true, 'message', 'La solicitud ha tenido éxito', 'data', v_data);
END;
$function$;

-- ---------------------------------------------------------------------------
-- Guardar las imágenes y los destinatarios de un boletín (uso interno)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION core.fn_boletines_guardar_detalle(p_id bigint, p_datos jsonb)
RETURNS void
LANGUAGE plpgsql
AS $function$
DECLARE
    v_item jsonb;
    v_i    integer := 0;
BEGIN
    -- Imágenes: se reemplazan por las que manda la pantalla, en su orden
    IF p_datos ? 'imagenes' THEN
        DELETE FROM core.boletines_imagenes
         WHERE boletin_id = p_id
           AND (p_datos->'imagenes' = '[]'::jsonb
                OR id NOT IN (SELECT (x->>'id')::bigint
                                FROM jsonb_array_elements(p_datos->'imagenes') x
                               WHERE x->>'id' IS NOT NULL));

        FOR v_item IN SELECT * FROM jsonb_array_elements(p_datos->'imagenes') LOOP
            v_i := v_i + 1;
            IF v_item->>'id' IS NOT NULL THEN
                UPDATE core.boletines_imagenes
                   SET titulo      = NULLIF(TRIM(COALESCE(v_item->>'titulo', '')), ''),
                       descripcion = NULLIF(TRIM(COALESCE(v_item->>'descripcion', '')), ''),
                       orden       = v_i,
                       segundos    = GREATEST(1, LEAST(120, COALESCE(NULLIF(v_item->>'segundos', '')::smallint, segundos)))
                 WHERE id = (v_item->>'id')::bigint AND boletin_id = p_id;
            ELSE
                IF NULLIF(TRIM(COALESCE(v_item->>'archivo', '')), '') IS NULL THEN
                    RAISE EXCEPTION 'Cada imagen necesita su fichero' USING ERRCODE = 'P0001';
                END IF;
                INSERT INTO core.boletines_imagenes (boletin_id, archivo, titulo, descripcion, orden, segundos, tipo)
                VALUES (p_id,
                        v_item->>'archivo',
                        NULLIF(TRIM(COALESCE(v_item->>'titulo', '')), ''),
                        NULLIF(TRIM(COALESCE(v_item->>'descripcion', '')), ''),
                        v_i,
                        GREATEST(1, LEAST(120, COALESCE(NULLIF(v_item->>'segundos', '')::smallint, 6))),
                        core.fn_boletines_tipo_archivo(v_item->>'archivo'));
            END IF;
        END LOOP;
    END IF;

    -- Destinatarios uno a uno
    IF p_datos ? 'usuarios' THEN
        DELETE FROM core.boletines_usuarios
         WHERE boletin_id = p_id
           AND (p_datos->'usuarios' = '[]'::jsonb
                OR user_id NOT IN (SELECT (x)::bigint FROM jsonb_array_elements_text(p_datos->'usuarios') x));

        INSERT INTO core.boletines_usuarios (boletin_id, user_id)
        SELECT p_id, (x)::bigint
          FROM jsonb_array_elements_text(p_datos->'usuarios') x
         WHERE EXISTS (SELECT 1 FROM seguridad.users u WHERE u.id = (x)::bigint AND u.deleted_at IS NULL)
        ON CONFLICT (boletin_id, user_id) DO NOTHING;
    END IF;

    -- Destinatarios por grupo
    IF p_datos ? 'grupos' THEN
        DELETE FROM core.boletines_grupos
         WHERE boletin_id = p_id
           AND (p_datos->'grupos' = '[]'::jsonb
                OR grupo_id NOT IN (SELECT (x->>'grupo_id')::bigint
                                      FROM jsonb_array_elements(p_datos->'grupos') x));

        FOR v_item IN SELECT * FROM jsonb_array_elements(p_datos->'grupos') LOOP
            IF NOT EXISTS (SELECT 1 FROM seguridad.grupos g WHERE g.id = (v_item->>'grupo_id')::bigint) THEN
                CONTINUE;
            END IF;
            INSERT INTO core.boletines_grupos (boletin_id, grupo_id, incluir_subgrupos)
            VALUES (p_id, (v_item->>'grupo_id')::bigint, COALESCE((v_item->>'incluir_subgrupos')::boolean, true))
            ON CONFLICT (boletin_id, grupo_id)
            DO UPDATE SET incluir_subgrupos = EXCLUDED.incluir_subgrupos;
        END LOOP;
    END IF;
END;
$function$;

-- ---------------------------------------------------------------------------
-- Crear
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION core.fn_boletines_crear(
    p_datos jsonb,
    p_usuario_id bigint DEFAULT NULL, p_usuario_login varchar DEFAULT NULL, p_usuario_nombre varchar DEFAULT NULL,
    p_ip_address inet DEFAULT NULL, p_user_agent text DEFAULT NULL, p_request_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
AS $function$
DECLARE
    v_id     bigint;
    v_titulo varchar(200);
    v_desde  date;
    v_hasta  date;
BEGIN
    PERFORM core.fn_boletines_contexto_auditoria(p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    v_titulo := NULLIF(TRIM(COALESCE(p_datos->>'titulo', '')), '');
    IF v_titulo IS NULL THEN
        RAISE EXCEPTION 'El título del boletín es obligatorio' USING ERRCODE = 'P0001';
    END IF;

    v_desde := COALESCE((p_datos->>'desde')::date, CURRENT_DATE);
    v_hasta := (p_datos->>'hasta')::date;
    IF v_hasta IS NULL THEN
        RAISE EXCEPTION 'La fecha hasta la que rige el boletín es obligatoria' USING ERRCODE = 'P0001';
    END IF;
    IF v_hasta < v_desde THEN
        RAISE EXCEPTION 'La vigencia termina antes de empezar' USING ERRCODE = 'P0010';
    END IF;

    INSERT INTO core.boletines (titulo, descripcion, desde, hasta, prioridad, obligatorio, activo)
    VALUES (v_titulo,
            NULLIF(TRIM(COALESCE(p_datos->>'descripcion', '')), ''),
            v_desde,
            v_hasta,
            COALESCE((p_datos->>'prioridad')::smallint, 0),
            COALESCE((p_datos->>'obligatorio')::boolean, false),
            COALESCE((p_datos->>'activo')::boolean, true))
    RETURNING id INTO v_id;

    PERFORM core.fn_boletines_guardar_detalle(v_id, p_datos);

    RETURN jsonb_build_object('success', true, 'message', 'Boletín creado con éxito', 'data', core.fn_boletines_json(v_id));
END;
$function$;

-- ---------------------------------------------------------------------------
-- Modificar
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION core.fn_boletines_modificar(
    p_id bigint,
    p_datos jsonb,
    p_usuario_id bigint DEFAULT NULL, p_usuario_login varchar DEFAULT NULL, p_usuario_nombre varchar DEFAULT NULL,
    p_ip_address inet DEFAULT NULL, p_user_agent text DEFAULT NULL, p_request_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
AS $function$
DECLARE
    v_actual core.boletines;
    v_desde  date;
    v_hasta  date;
BEGIN
    PERFORM core.fn_boletines_contexto_auditoria(p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    SELECT * INTO v_actual FROM core.boletines WHERE id = p_id AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'El boletín no existe' USING ERRCODE = 'P0013';
    END IF;

    v_desde := COALESCE((p_datos->>'desde')::date, v_actual.desde);
    v_hasta := COALESCE((p_datos->>'hasta')::date, v_actual.hasta);
    IF v_hasta < v_desde THEN
        RAISE EXCEPTION 'La vigencia termina antes de empezar' USING ERRCODE = 'P0010';
    END IF;

    UPDATE core.boletines
       SET titulo      = COALESCE(NULLIF(TRIM(COALESCE(p_datos->>'titulo', '')), ''), titulo),
           descripcion = CASE WHEN p_datos ? 'descripcion'
                              THEN NULLIF(TRIM(COALESCE(p_datos->>'descripcion', '')), '')
                              ELSE descripcion END,
           desde       = v_desde,
           hasta       = v_hasta,
           prioridad   = COALESCE((p_datos->>'prioridad')::smallint, prioridad),
           obligatorio = COALESCE((p_datos->>'obligatorio')::boolean, obligatorio),
           activo      = COALESCE((p_datos->>'activo')::boolean, activo)
     WHERE id = p_id;

    PERFORM core.fn_boletines_guardar_detalle(p_id, p_datos);

    RETURN jsonb_build_object('success', true, 'message', 'Boletín modificado con éxito', 'data', core.fn_boletines_json(p_id));
END;
$function$;

-- ---------------------------------------------------------------------------
-- Eliminar (lógico) y restaurar
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION core.fn_boletines_eliminar(
    p_id bigint,
    p_usuario_id bigint DEFAULT NULL, p_usuario_login varchar DEFAULT NULL, p_usuario_nombre varchar DEFAULT NULL,
    p_ip_address inet DEFAULT NULL, p_user_agent text DEFAULT NULL, p_request_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
AS $function$
DECLARE v_titulo varchar(200);
BEGIN
    PERFORM core.fn_boletines_contexto_auditoria(p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    SELECT titulo INTO v_titulo FROM core.boletines WHERE id = p_id AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'El boletín no existe' USING ERRCODE = 'P0013';
    END IF;

    UPDATE core.boletines
       SET deleted_at = now(),
           deleted_by = COALESCE(p_usuario_login, current_user),
           activo     = false
     WHERE id = p_id;

    RETURN jsonb_build_object('success', true, 'message', format('Boletín «%s» eliminado', v_titulo), 'data', NULL);
END;
$function$;

CREATE OR REPLACE FUNCTION core.fn_boletines_restaurar(
    p_id bigint,
    p_usuario_id bigint DEFAULT NULL, p_usuario_login varchar DEFAULT NULL, p_usuario_nombre varchar DEFAULT NULL,
    p_ip_address inet DEFAULT NULL, p_user_agent text DEFAULT NULL, p_request_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
AS $function$
BEGIN
    PERFORM core.fn_boletines_contexto_auditoria(p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    UPDATE core.boletines
       SET deleted_at = NULL, deleted_by = NULL
     WHERE id = p_id AND deleted_at IS NOT NULL;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'El boletín no está en la papelera' USING ERRCODE = 'P0013';
    END IF;

    RETURN jsonb_build_object('success', true, 'message', 'Boletín restaurado', 'data', core.fn_boletines_json(p_id));
END;
$function$;

-- ---------------------------------------------------------------------------
-- Destinatarios resueltos: quién verá el boletín (directos + por grupo)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION core.fn_boletines_destinatarios(p_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
AS $function$
DECLARE v_data jsonb;
BEGIN
    SELECT COALESCE(jsonb_agg(t ORDER BY t->>'login_user'), '[]'::jsonb) INTO v_data
      FROM (
        SELECT DISTINCT ON (u.id) jsonb_build_object(
                 'user_id',  u.id,
                 'login_user', u.login_user,
                 'name',     u.name,
                 'surname',  u.surname,
                 'isactive', u.isactive,
                 'origen',   d.origen,
                 'desde',    d.desde_nombre,
                 'visto_at', to_char(v.visto_at, 'YYYY-MM-DD HH24:MI:SS'),
                 'no_mostrar', COALESCE(v.no_mostrar, false)
               ) AS t, u.id
          FROM (
                SELECT bu.user_id, 'DIRECTO'::text AS origen, NULL::varchar AS desde_nombre
                  FROM core.boletines_usuarios bu WHERE bu.boletin_id = p_id
                UNION ALL
                SELECT g.user_id, 'GRUPO'::text, gr.nombre
                  FROM core.boletines_grupos bg
                  JOIN seguridad.grupos gr ON gr.id = bg.grupo_id
                  CROSS JOIN LATERAL core.fn_boletines_usuarios_de_grupo(bg.grupo_id, bg.incluir_subgrupos) g
                 WHERE bg.boletin_id = p_id
               ) d
          JOIN seguridad.users u ON u.id = d.user_id AND u.deleted_at IS NULL
          LEFT JOIN core.boletines_vistos v ON v.boletin_id = p_id AND v.user_id = u.id
         ORDER BY u.id, (d.origen = 'DIRECTO') DESC
      ) x;

    RETURN jsonb_build_object('success', true, 'message', 'La solicitud ha tenido éxito', 'data', v_data);
END;
$function$;

-- ---------------------------------------------------------------------------
-- Mis boletines: los vigentes de un usuario, para el carrusel de bienvenida
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION core.fn_boletines_mios(p_user_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
AS $function$
DECLARE v_data jsonb;
BEGIN
    SELECT COALESCE(jsonb_agg(core.fn_boletines_json(t.id) ORDER BY t.prioridad DESC, t.desde DESC, t.id DESC), '[]'::jsonb)
      INTO v_data
      FROM (
        SELECT DISTINCT b.id, b.prioridad, b.desde
          FROM core.boletines b
         WHERE b.deleted_at IS NULL
           AND b.activo
           AND CURRENT_DATE BETWEEN b.desde AND b.hasta
           AND EXISTS (SELECT 1 FROM core.boletines_imagenes i WHERE i.boletin_id = b.id)
           AND (
                EXISTS (SELECT 1 FROM core.boletines_usuarios bu
                         WHERE bu.boletin_id = b.id AND bu.user_id = p_user_id)
             OR EXISTS (SELECT 1 FROM core.boletines_grupos bg
                          CROSS JOIN LATERAL core.fn_boletines_usuarios_de_grupo(bg.grupo_id, bg.incluir_subgrupos) g
                         WHERE bg.boletin_id = b.id AND g.user_id = p_user_id)
               )
           AND NOT EXISTS (SELECT 1 FROM core.boletines_vistos v
                            WHERE v.boletin_id = b.id AND v.user_id = p_user_id AND v.no_mostrar)
      ) t;

    RETURN jsonb_build_object('success', true, 'message', 'La solicitud ha tenido éxito', 'data', v_data);
END;
$function$;

-- ---------------------------------------------------------------------------
-- Registrar la lectura (y el "no volver a mostrar")
-- ---------------------------------------------------------------------------
-- ---------------------------------------------------------------------------
-- Un boletín concreto, para quien lo va a ver
--
-- Es el hermano de fn_boletines_mios, con dos diferencias: va por id y NO
-- mira la vigencia. Se usa cuando el administrador lanza un boletín a mano:
-- si decide lanzar uno programado o ya caducado, manda su decisión. Lo que
-- no se salta es el resto: tiene que estar activo, con contenido, y quien
-- pregunta tiene que ser destinatario y no haber dicho «no volver a mostrar».
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION core.fn_boletines_mio(p_id bigint, p_user_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
AS $function$
DECLARE v_data jsonb;
BEGIN
    SELECT core.fn_boletines_json(b.id) INTO v_data
      FROM core.boletines b
     WHERE b.id = p_id
       AND b.deleted_at IS NULL
       AND b.activo
       AND EXISTS (SELECT 1 FROM core.boletines_imagenes i WHERE i.boletin_id = b.id)
       AND (
            EXISTS (SELECT 1 FROM core.boletines_usuarios bu
                     WHERE bu.boletin_id = b.id AND bu.user_id = p_user_id)
         OR EXISTS (SELECT 1 FROM core.boletines_grupos bg
                      CROSS JOIN LATERAL core.fn_boletines_usuarios_de_grupo(bg.grupo_id, bg.incluir_subgrupos) g
                     WHERE bg.boletin_id = b.id AND g.user_id = p_user_id)
           )
       AND NOT EXISTS (SELECT 1 FROM core.boletines_vistos v
                        WHERE v.boletin_id = b.id AND v.user_id = p_user_id AND v.no_mostrar);

    RETURN jsonb_build_object('success', true, 'message', 'La solicitud ha tenido éxito', 'data', v_data);
END;
$function$;

-- ---------------------------------------------------------------------------
-- Quitar el «no volver a mostrar» de un boletín
--
-- Lo usa el lanzamiento a mano cuando el administrador marca «ignorar el
-- no volver a mostrar»: el boletín vuelve a salirle a quien lo había
-- ocultado, ahora y la próxima vez que entre. Es la única forma de
-- revertir esa marca, que el usuario sólo puede poner.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION core.fn_boletines_ignorar_no_mostrar(p_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
AS $function$
DECLARE v_cuantos integer;
BEGIN
    UPDATE core.boletines_vistos
       SET no_mostrar = false
     WHERE boletin_id = p_id
       AND no_mostrar;

    GET DIAGNOSTICS v_cuantos = ROW_COUNT;

    RETURN jsonb_build_object('success', true,
                              'message', 'Marca de «no volver a mostrar» retirada',
                              'data', jsonb_build_object('reactivados', v_cuantos));
END;
$function$;
CREATE OR REPLACE FUNCTION core.fn_boletines_marcar_visto(
    p_boletin_id bigint,
    p_user_id    bigint,
    p_no_mostrar boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
AS $function$
BEGIN
    IF p_boletin_id IS NULL OR p_user_id IS NULL THEN
        RAISE EXCEPTION 'Faltan el boletín o el usuario' USING ERRCODE = 'P0001';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM core.boletines WHERE id = p_boletin_id AND deleted_at IS NULL) THEN
        RAISE EXCEPTION 'El boletín no existe' USING ERRCODE = 'P0013';
    END IF;

    INSERT INTO core.boletines_vistos (boletin_id, user_id, no_mostrar)
    VALUES (p_boletin_id, p_user_id, COALESCE(p_no_mostrar, false))
    ON CONFLICT (boletin_id, user_id) DO UPDATE
       SET visto_at   = now(),
           veces      = core.boletines_vistos.veces + 1,
           no_mostrar = core.boletines_vistos.no_mostrar OR COALESCE(EXCLUDED.no_mostrar, false);

    RETURN jsonb_build_object('success', true, 'message', 'Lectura registrada', 'data', NULL);
END;
$function$;

-- ---------------------------------------------------------------------------
-- Datos de una imagen para servirla: sólo si el usuario es destinatario
-- (o si administra el boletín, lo que decide el back)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION core.fn_boletines_imagen(p_imagen_id bigint, p_user_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
AS $function$
DECLARE
    v_archivo    varchar(255);
    v_boletin_id bigint;
    v_destino    boolean;
BEGIN
    SELECT i.archivo, i.boletin_id INTO v_archivo, v_boletin_id
      FROM core.boletines_imagenes i
      JOIN core.boletines b ON b.id = i.boletin_id AND b.deleted_at IS NULL
     WHERE i.id = p_imagen_id;

    IF v_archivo IS NULL THEN
        RETURN jsonb_build_object('success', false, 'message', 'La imagen no existe', 'data', NULL);
    END IF;

    SELECT EXISTS (SELECT 1 FROM core.boletines_usuarios bu
                    WHERE bu.boletin_id = v_boletin_id AND bu.user_id = p_user_id)
        OR EXISTS (SELECT 1 FROM core.boletines_grupos bg
                     CROSS JOIN LATERAL core.fn_boletines_usuarios_de_grupo(bg.grupo_id, bg.incluir_subgrupos) g
                    WHERE bg.boletin_id = v_boletin_id AND g.user_id = p_user_id)
      INTO v_destino;

    RETURN jsonb_build_object('success', true, 'message', 'La solicitud ha tenido éxito',
                              'data', jsonb_build_object('archivo', v_archivo,
                                                         'boletin_id', v_boletin_id,
                                                         'destinatario', v_destino));
END;
$function$;

-- ---------------------------------------------------------------------------
-- Papelera
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION core.fn_boletines_papelera()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
AS $function$
DECLARE v_data jsonb;
BEGIN
    SELECT COALESCE(jsonb_agg(core.fn_boletines_json(b.id) ORDER BY b.deleted_at DESC), '[]'::jsonb)
      INTO v_data
      FROM core.boletines b
     WHERE b.deleted_at IS NOT NULL;

    RETURN jsonb_build_object('success', true, 'message', 'La solicitud ha tenido éxito', 'data', v_data);
END;
$function$;

-- ---------------------------------------------------------------------------
-- Borrado definitivo: devuelve los ficheros que hay que quitar del disco
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION core.fn_boletines_eliminar_definitivo(
    p_id bigint,
    p_usuario_id bigint DEFAULT NULL, p_usuario_login varchar DEFAULT NULL, p_usuario_nombre varchar DEFAULT NULL,
    p_ip_address inet DEFAULT NULL, p_user_agent text DEFAULT NULL, p_request_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
AS $function$
DECLARE
    v_titulo    varchar(200);
    v_archivos  jsonb;
BEGIN
    PERFORM core.fn_boletines_contexto_auditoria(p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    SELECT titulo INTO v_titulo FROM core.boletines WHERE id = p_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'El boletín no existe' USING ERRCODE = 'P0013';
    END IF;

    SELECT COALESCE(jsonb_agg(i.archivo), '[]'::jsonb) INTO v_archivos
      FROM core.boletines_imagenes i WHERE i.boletin_id = p_id;

    DELETE FROM core.boletines WHERE id = p_id;

    RETURN jsonb_build_object('success', true,
                              'message', format('Boletín «%s» eliminado definitivamente', v_titulo),
                              'data', jsonb_build_object('archivos', v_archivos));
END;
$function$;

CREATE OR REPLACE FUNCTION core.fn_boletines_vaciar_papelera(
    p_usuario_id bigint DEFAULT NULL, p_usuario_login varchar DEFAULT NULL, p_usuario_nombre varchar DEFAULT NULL,
    p_ip_address inet DEFAULT NULL, p_user_agent text DEFAULT NULL, p_request_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
AS $function$
DECLARE
    v_archivos jsonb;
    v_cuantos  integer;
BEGIN
    PERFORM core.fn_boletines_contexto_auditoria(p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    SELECT COALESCE(jsonb_agg(i.archivo), '[]'::jsonb) INTO v_archivos
      FROM core.boletines_imagenes i
      JOIN core.boletines b ON b.id = i.boletin_id
     WHERE b.deleted_at IS NOT NULL;

    WITH borrados AS (DELETE FROM core.boletines WHERE deleted_at IS NOT NULL RETURNING 1)
    SELECT COUNT(*) INTO v_cuantos FROM borrados;

    RETURN jsonb_build_object('success', true,
                              'message', format('%s boletín(es) eliminados de la papelera', v_cuantos),
                              'data', jsonb_build_object('archivos', v_archivos, 'cuantos', v_cuantos));
END;
$function$;
  THEN 'VIDEO'
             WHEN lower(COALESCE(p_archivo, '')) ~ '\.(mp3|m4a|wav|ogg|oga)
CREATE OR REPLACE FUNCTION core.fn_boletines_json(p_id bigint)
RETURNS jsonb
LANGUAGE sql
STABLE
AS $function$
    SELECT jsonb_build_object(
        'id',            b.id,
        'titulo',        b.titulo,
        'descripcion',   b.descripcion,
        'desde',         to_char(b.desde, 'YYYY-MM-DD'),
        'hasta',         to_char(b.hasta, 'YYYY-MM-DD'),
        'prioridad',     b.prioridad,
        'obligatorio',   b.obligatorio,
        'activo',        b.activo,
        'vigente',       (b.activo AND CURRENT_DATE BETWEEN b.desde AND b.hasta),
        'estado',        CASE WHEN NOT b.activo               THEN 'INACTIVO'
                              WHEN CURRENT_DATE < b.desde     THEN 'PROGRAMADO'
                              WHEN CURRENT_DATE > b.hasta     THEN 'CADUCADO'
                              ELSE 'VIGENTE' END,
        'en_papelera',   (b.deleted_at IS NOT NULL),
        'imagenes',      COALESCE((
                            SELECT jsonb_agg(jsonb_build_object(
                                     'id', i.id, 'archivo', i.archivo, 'titulo', i.titulo,
                                     'descripcion', i.descripcion, 'orden', i.orden,
                                     'segundos', i.segundos
                                   ) ORDER BY i.orden, i.id)
                              FROM core.boletines_imagenes i WHERE i.boletin_id = b.id), '[]'::jsonb),
        'usuarios',      COALESCE((
                            SELECT jsonb_agg(jsonb_build_object(
                                     'user_id', u.id, 'login_user', u.login_user,
                                     'name', u.name, 'surname', u.surname, 'isactive', u.isactive
                                   ) ORDER BY u.login_user)
                              FROM core.boletines_usuarios bu
                              JOIN seguridad.users u ON u.id = bu.user_id AND u.deleted_at IS NULL
                             WHERE bu.boletin_id = b.id), '[]'::jsonb),
        'grupos',        COALESCE((
                            SELECT jsonb_agg(jsonb_build_object(
                                     'grupo_id', g.id, 'nombre', g.nombre,
                                     'incluir_subgrupos', bg.incluir_subgrupos
                                   ) ORDER BY g.nombre)
                              FROM core.boletines_grupos bg
                              JOIN seguridad.grupos g ON g.id = bg.grupo_id
                             WHERE bg.boletin_id = b.id), '[]'::jsonb),
        'num_imagenes',  (SELECT COUNT(*) FROM core.boletines_imagenes i WHERE i.boletin_id = b.id),
        'num_usuarios',  (SELECT COUNT(*) FROM core.boletines_usuarios bu WHERE bu.boletin_id = b.id),
        'num_grupos',    (SELECT COUNT(*) FROM core.boletines_grupos bg WHERE bg.boletin_id = b.id),
        'num_vistos',    (SELECT COUNT(*) FROM core.boletines_vistos v WHERE v.boletin_id = b.id),
        'created_by',    b.created_by,
        'updated_by',    b.updated_by,
        'created_at',    to_char(b.created_at, 'YYYY-MM-DD HH24:MI:SS'),
        'updated_at',    to_char(b.updated_at, 'YYYY-MM-DD HH24:MI:SS')
    )
    FROM core.boletines b
    WHERE b.id = p_id;
$function$;

-- ---------------------------------------------------------------------------
-- Listado paginado para la grilla
--   p_estado: TODOS | VIGENTE | PROGRAMADO | CADUCADO | INACTIVO
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION core.fn_boletines_listar_paginado(
    p_page     integer DEFAULT 1,
    p_per_page integer DEFAULT 15,
    p_search   text    DEFAULT '',
    p_estado   text    DEFAULT 'TODOS'
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
AS $function$
DECLARE
    v_offset integer;
    v_total  bigint;
    v_filtro text;
    v_estado text;
    v_data   jsonb;
BEGIN
    v_offset := (GREATEST(p_page, 1) - 1) * p_per_page;
    v_filtro := NULLIF(TRIM(COALESCE(p_search, '')), '');
    v_estado := UPPER(COALESCE(NULLIF(TRIM(p_estado), ''), 'TODOS'));

    SELECT COUNT(*) INTO v_total
      FROM core.boletines b
     WHERE b.deleted_at IS NULL
       AND (v_filtro IS NULL
            OR b.titulo ILIKE '%' || v_filtro || '%'
            OR b.descripcion ILIKE '%' || v_filtro || '%'
            OR b.id::text ILIKE '%' || v_filtro || '%')
       AND (v_estado = 'TODOS'
            OR (v_estado = 'VIGENTE'    AND b.activo AND CURRENT_DATE BETWEEN b.desde AND b.hasta)
            OR (v_estado = 'PROGRAMADO' AND b.activo AND CURRENT_DATE < b.desde)
            OR (v_estado = 'CADUCADO'   AND b.activo AND CURRENT_DATE > b.hasta)
            OR (v_estado = 'INACTIVO'   AND NOT b.activo));

    SELECT COALESCE(jsonb_agg(core.fn_boletines_json(t.id) ORDER BY t.prioridad DESC, t.desde DESC, t.id DESC), '[]'::jsonb)
      INTO v_data
      FROM (
        SELECT b.id, b.prioridad, b.desde
          FROM core.boletines b
         WHERE b.deleted_at IS NULL
           AND (v_filtro IS NULL
                OR b.titulo ILIKE '%' || v_filtro || '%'
                OR b.descripcion ILIKE '%' || v_filtro || '%'
                OR b.id::text ILIKE '%' || v_filtro || '%')
           AND (v_estado = 'TODOS'
                OR (v_estado = 'VIGENTE'    AND b.activo AND CURRENT_DATE BETWEEN b.desde AND b.hasta)
                OR (v_estado = 'PROGRAMADO' AND b.activo AND CURRENT_DATE < b.desde)
                OR (v_estado = 'CADUCADO'   AND b.activo AND CURRENT_DATE > b.hasta)
                OR (v_estado = 'INACTIVO'   AND NOT b.activo))
         ORDER BY b.prioridad DESC, b.desde DESC, b.id DESC
         LIMIT p_per_page OFFSET v_offset
      ) t;

    RETURN jsonb_build_object(
        'success', true,
        'message', 'La solicitud ha tenido éxito',
        'data', jsonb_build_object(
            'data', v_data,
            'current_page', GREATEST(p_page, 1),
            'per_page', p_per_page,
            'total', v_total,
            'last_page', GREATEST(CEIL(v_total::numeric / NULLIF(p_per_page, 0))::int, 1)
        )
    );
END;
$function$;

-- ---------------------------------------------------------------------------
-- Obtener uno
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION core.fn_boletines_obtener(p_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
AS $function$
DECLARE v_data jsonb;
BEGIN
    SELECT core.fn_boletines_json(p_id) INTO v_data;
    IF v_data IS NULL THEN
        RETURN jsonb_build_object('success', false, 'message', 'El boletín no existe', 'data', NULL);
    END IF;
    RETURN jsonb_build_object('success', true, 'message', 'La solicitud ha tenido éxito', 'data', v_data);
END;
$function$;

-- ---------------------------------------------------------------------------
-- Guardar las imágenes y los destinatarios de un boletín (uso interno)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION core.fn_boletines_guardar_detalle(p_id bigint, p_datos jsonb)
RETURNS void
LANGUAGE plpgsql
AS $function$
DECLARE
    v_item jsonb;
    v_i    integer := 0;
BEGIN
    -- Imágenes: se reemplazan por las que manda la pantalla, en su orden
    IF p_datos ? 'imagenes' THEN
        DELETE FROM core.boletines_imagenes
         WHERE boletin_id = p_id
           AND (p_datos->'imagenes' = '[]'::jsonb
                OR id NOT IN (SELECT (x->>'id')::bigint
                                FROM jsonb_array_elements(p_datos->'imagenes') x
                               WHERE x->>'id' IS NOT NULL));

        FOR v_item IN SELECT * FROM jsonb_array_elements(p_datos->'imagenes') LOOP
            v_i := v_i + 1;
            IF v_item->>'id' IS NOT NULL THEN
                UPDATE core.boletines_imagenes
                   SET titulo      = NULLIF(TRIM(COALESCE(v_item->>'titulo', '')), ''),
                       descripcion = NULLIF(TRIM(COALESCE(v_item->>'descripcion', '')), ''),
                       orden       = v_i,
                       segundos    = GREATEST(1, LEAST(120, COALESCE(NULLIF(v_item->>'segundos', '')::smallint, segundos)))
                 WHERE id = (v_item->>'id')::bigint AND boletin_id = p_id;
            ELSE
                IF NULLIF(TRIM(COALESCE(v_item->>'archivo', '')), '') IS NULL THEN
                    RAISE EXCEPTION 'Cada imagen necesita su fichero' USING ERRCODE = 'P0001';
                END IF;
                INSERT INTO core.boletines_imagenes (boletin_id, archivo, titulo, descripcion, orden, segundos)
                VALUES (p_id,
                        v_item->>'archivo',
                        NULLIF(TRIM(COALESCE(v_item->>'titulo', '')), ''),
                        NULLIF(TRIM(COALESCE(v_item->>'descripcion', '')), ''),
                        v_i,
                        GREATEST(1, LEAST(120, COALESCE(NULLIF(v_item->>'segundos', '')::smallint, 6))));
            END IF;
        END LOOP;
    END IF;

    -- Destinatarios uno a uno
    IF p_datos ? 'usuarios' THEN
        DELETE FROM core.boletines_usuarios
         WHERE boletin_id = p_id
           AND (p_datos->'usuarios' = '[]'::jsonb
                OR user_id NOT IN (SELECT (x)::bigint FROM jsonb_array_elements_text(p_datos->'usuarios') x));

        INSERT INTO core.boletines_usuarios (boletin_id, user_id)
        SELECT p_id, (x)::bigint
          FROM jsonb_array_elements_text(p_datos->'usuarios') x
         WHERE EXISTS (SELECT 1 FROM seguridad.users u WHERE u.id = (x)::bigint AND u.deleted_at IS NULL)
        ON CONFLICT (boletin_id, user_id) DO NOTHING;
    END IF;

    -- Destinatarios por grupo
    IF p_datos ? 'grupos' THEN
        DELETE FROM core.boletines_grupos
         WHERE boletin_id = p_id
           AND (p_datos->'grupos' = '[]'::jsonb
                OR grupo_id NOT IN (SELECT (x->>'grupo_id')::bigint
                                      FROM jsonb_array_elements(p_datos->'grupos') x));

        FOR v_item IN SELECT * FROM jsonb_array_elements(p_datos->'grupos') LOOP
            IF NOT EXISTS (SELECT 1 FROM seguridad.grupos g WHERE g.id = (v_item->>'grupo_id')::bigint) THEN
                CONTINUE;
            END IF;
            INSERT INTO core.boletines_grupos (boletin_id, grupo_id, incluir_subgrupos)
            VALUES (p_id, (v_item->>'grupo_id')::bigint, COALESCE((v_item->>'incluir_subgrupos')::boolean, true))
            ON CONFLICT (boletin_id, grupo_id)
            DO UPDATE SET incluir_subgrupos = EXCLUDED.incluir_subgrupos;
        END LOOP;
    END IF;
END;
$function$;

-- ---------------------------------------------------------------------------
-- Crear
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION core.fn_boletines_crear(
    p_datos jsonb,
    p_usuario_id bigint DEFAULT NULL, p_usuario_login varchar DEFAULT NULL, p_usuario_nombre varchar DEFAULT NULL,
    p_ip_address inet DEFAULT NULL, p_user_agent text DEFAULT NULL, p_request_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
AS $function$
DECLARE
    v_id     bigint;
    v_titulo varchar(200);
    v_desde  date;
    v_hasta  date;
BEGIN
    PERFORM core.fn_boletines_contexto_auditoria(p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    v_titulo := NULLIF(TRIM(COALESCE(p_datos->>'titulo', '')), '');
    IF v_titulo IS NULL THEN
        RAISE EXCEPTION 'El título del boletín es obligatorio' USING ERRCODE = 'P0001';
    END IF;

    v_desde := COALESCE((p_datos->>'desde')::date, CURRENT_DATE);
    v_hasta := (p_datos->>'hasta')::date;
    IF v_hasta IS NULL THEN
        RAISE EXCEPTION 'La fecha hasta la que rige el boletín es obligatoria' USING ERRCODE = 'P0001';
    END IF;
    IF v_hasta < v_desde THEN
        RAISE EXCEPTION 'La vigencia termina antes de empezar' USING ERRCODE = 'P0010';
    END IF;

    INSERT INTO core.boletines (titulo, descripcion, desde, hasta, prioridad, obligatorio, activo)
    VALUES (v_titulo,
            NULLIF(TRIM(COALESCE(p_datos->>'descripcion', '')), ''),
            v_desde,
            v_hasta,
            COALESCE((p_datos->>'prioridad')::smallint, 0),
            COALESCE((p_datos->>'obligatorio')::boolean, false),
            COALESCE((p_datos->>'activo')::boolean, true))
    RETURNING id INTO v_id;

    PERFORM core.fn_boletines_guardar_detalle(v_id, p_datos);

    RETURN jsonb_build_object('success', true, 'message', 'Boletín creado con éxito', 'data', core.fn_boletines_json(v_id));
END;
$function$;

-- ---------------------------------------------------------------------------
-- Modificar
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION core.fn_boletines_modificar(
    p_id bigint,
    p_datos jsonb,
    p_usuario_id bigint DEFAULT NULL, p_usuario_login varchar DEFAULT NULL, p_usuario_nombre varchar DEFAULT NULL,
    p_ip_address inet DEFAULT NULL, p_user_agent text DEFAULT NULL, p_request_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
AS $function$
DECLARE
    v_actual core.boletines;
    v_desde  date;
    v_hasta  date;
BEGIN
    PERFORM core.fn_boletines_contexto_auditoria(p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    SELECT * INTO v_actual FROM core.boletines WHERE id = p_id AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'El boletín no existe' USING ERRCODE = 'P0013';
    END IF;

    v_desde := COALESCE((p_datos->>'desde')::date, v_actual.desde);
    v_hasta := COALESCE((p_datos->>'hasta')::date, v_actual.hasta);
    IF v_hasta < v_desde THEN
        RAISE EXCEPTION 'La vigencia termina antes de empezar' USING ERRCODE = 'P0010';
    END IF;

    UPDATE core.boletines
       SET titulo      = COALESCE(NULLIF(TRIM(COALESCE(p_datos->>'titulo', '')), ''), titulo),
           descripcion = CASE WHEN p_datos ? 'descripcion'
                              THEN NULLIF(TRIM(COALESCE(p_datos->>'descripcion', '')), '')
                              ELSE descripcion END,
           desde       = v_desde,
           hasta       = v_hasta,
           prioridad   = COALESCE((p_datos->>'prioridad')::smallint, prioridad),
           obligatorio = COALESCE((p_datos->>'obligatorio')::boolean, obligatorio),
           activo      = COALESCE((p_datos->>'activo')::boolean, activo)
     WHERE id = p_id;

    PERFORM core.fn_boletines_guardar_detalle(p_id, p_datos);

    RETURN jsonb_build_object('success', true, 'message', 'Boletín modificado con éxito', 'data', core.fn_boletines_json(p_id));
END;
$function$;

-- ---------------------------------------------------------------------------
-- Eliminar (lógico) y restaurar
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION core.fn_boletines_eliminar(
    p_id bigint,
    p_usuario_id bigint DEFAULT NULL, p_usuario_login varchar DEFAULT NULL, p_usuario_nombre varchar DEFAULT NULL,
    p_ip_address inet DEFAULT NULL, p_user_agent text DEFAULT NULL, p_request_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
AS $function$
DECLARE v_titulo varchar(200);
BEGIN
    PERFORM core.fn_boletines_contexto_auditoria(p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    SELECT titulo INTO v_titulo FROM core.boletines WHERE id = p_id AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'El boletín no existe' USING ERRCODE = 'P0013';
    END IF;

    UPDATE core.boletines
       SET deleted_at = now(),
           deleted_by = COALESCE(p_usuario_login, current_user),
           activo     = false
     WHERE id = p_id;

    RETURN jsonb_build_object('success', true, 'message', format('Boletín «%s» eliminado', v_titulo), 'data', NULL);
END;
$function$;

CREATE OR REPLACE FUNCTION core.fn_boletines_restaurar(
    p_id bigint,
    p_usuario_id bigint DEFAULT NULL, p_usuario_login varchar DEFAULT NULL, p_usuario_nombre varchar DEFAULT NULL,
    p_ip_address inet DEFAULT NULL, p_user_agent text DEFAULT NULL, p_request_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
AS $function$
BEGIN
    PERFORM core.fn_boletines_contexto_auditoria(p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    UPDATE core.boletines
       SET deleted_at = NULL, deleted_by = NULL
     WHERE id = p_id AND deleted_at IS NOT NULL;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'El boletín no está en la papelera' USING ERRCODE = 'P0013';
    END IF;

    RETURN jsonb_build_object('success', true, 'message', 'Boletín restaurado', 'data', core.fn_boletines_json(p_id));
END;
$function$;

-- ---------------------------------------------------------------------------
-- Destinatarios resueltos: quién verá el boletín (directos + por grupo)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION core.fn_boletines_destinatarios(p_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
AS $function$
DECLARE v_data jsonb;
BEGIN
    SELECT COALESCE(jsonb_agg(t ORDER BY t->>'login_user'), '[]'::jsonb) INTO v_data
      FROM (
        SELECT DISTINCT ON (u.id) jsonb_build_object(
                 'user_id',  u.id,
                 'login_user', u.login_user,
                 'name',     u.name,
                 'surname',  u.surname,
                 'isactive', u.isactive,
                 'origen',   d.origen,
                 'desde',    d.desde_nombre,
                 'visto_at', to_char(v.visto_at, 'YYYY-MM-DD HH24:MI:SS'),
                 'no_mostrar', COALESCE(v.no_mostrar, false)
               ) AS t, u.id
          FROM (
                SELECT bu.user_id, 'DIRECTO'::text AS origen, NULL::varchar AS desde_nombre
                  FROM core.boletines_usuarios bu WHERE bu.boletin_id = p_id
                UNION ALL
                SELECT g.user_id, 'GRUPO'::text, gr.nombre
                  FROM core.boletines_grupos bg
                  JOIN seguridad.grupos gr ON gr.id = bg.grupo_id
                  CROSS JOIN LATERAL core.fn_boletines_usuarios_de_grupo(bg.grupo_id, bg.incluir_subgrupos) g
                 WHERE bg.boletin_id = p_id
               ) d
          JOIN seguridad.users u ON u.id = d.user_id AND u.deleted_at IS NULL
          LEFT JOIN core.boletines_vistos v ON v.boletin_id = p_id AND v.user_id = u.id
         ORDER BY u.id, (d.origen = 'DIRECTO') DESC
      ) x;

    RETURN jsonb_build_object('success', true, 'message', 'La solicitud ha tenido éxito', 'data', v_data);
END;
$function$;

-- ---------------------------------------------------------------------------
-- Mis boletines: los vigentes de un usuario, para el carrusel de bienvenida
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION core.fn_boletines_mios(p_user_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
AS $function$
DECLARE v_data jsonb;
BEGIN
    SELECT COALESCE(jsonb_agg(core.fn_boletines_json(t.id) ORDER BY t.prioridad DESC, t.desde DESC, t.id DESC), '[]'::jsonb)
      INTO v_data
      FROM (
        SELECT DISTINCT b.id, b.prioridad, b.desde
          FROM core.boletines b
         WHERE b.deleted_at IS NULL
           AND b.activo
           AND CURRENT_DATE BETWEEN b.desde AND b.hasta
           AND EXISTS (SELECT 1 FROM core.boletines_imagenes i WHERE i.boletin_id = b.id)
           AND (
                EXISTS (SELECT 1 FROM core.boletines_usuarios bu
                         WHERE bu.boletin_id = b.id AND bu.user_id = p_user_id)
             OR EXISTS (SELECT 1 FROM core.boletines_grupos bg
                          CROSS JOIN LATERAL core.fn_boletines_usuarios_de_grupo(bg.grupo_id, bg.incluir_subgrupos) g
                         WHERE bg.boletin_id = b.id AND g.user_id = p_user_id)
               )
           AND NOT EXISTS (SELECT 1 FROM core.boletines_vistos v
                            WHERE v.boletin_id = b.id AND v.user_id = p_user_id AND v.no_mostrar)
      ) t;

    RETURN jsonb_build_object('success', true, 'message', 'La solicitud ha tenido éxito', 'data', v_data);
END;
$function$;

-- ---------------------------------------------------------------------------
-- Registrar la lectura (y el "no volver a mostrar")
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION core.fn_boletines_marcar_visto(
    p_boletin_id bigint,
    p_user_id    bigint,
    p_no_mostrar boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
AS $function$
BEGIN
    IF p_boletin_id IS NULL OR p_user_id IS NULL THEN
        RAISE EXCEPTION 'Faltan el boletín o el usuario' USING ERRCODE = 'P0001';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM core.boletines WHERE id = p_boletin_id AND deleted_at IS NULL) THEN
        RAISE EXCEPTION 'El boletín no existe' USING ERRCODE = 'P0013';
    END IF;

    INSERT INTO core.boletines_vistos (boletin_id, user_id, no_mostrar)
    VALUES (p_boletin_id, p_user_id, COALESCE(p_no_mostrar, false))
    ON CONFLICT (boletin_id, user_id) DO UPDATE
       SET visto_at   = now(),
           veces      = core.boletines_vistos.veces + 1,
           no_mostrar = core.boletines_vistos.no_mostrar OR COALESCE(EXCLUDED.no_mostrar, false);

    RETURN jsonb_build_object('success', true, 'message', 'Lectura registrada', 'data', NULL);
END;
$function$;

-- ---------------------------------------------------------------------------
-- Datos de una imagen para servirla: sólo si el usuario es destinatario
-- (o si administra el boletín, lo que decide el back)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION core.fn_boletines_imagen(p_imagen_id bigint, p_user_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
AS $function$
DECLARE
    v_archivo    varchar(255);
    v_boletin_id bigint;
    v_destino    boolean;
BEGIN
    SELECT i.archivo, i.boletin_id INTO v_archivo, v_boletin_id
      FROM core.boletines_imagenes i
      JOIN core.boletines b ON b.id = i.boletin_id AND b.deleted_at IS NULL
     WHERE i.id = p_imagen_id;

    IF v_archivo IS NULL THEN
        RETURN jsonb_build_object('success', false, 'message', 'La imagen no existe', 'data', NULL);
    END IF;

    SELECT EXISTS (SELECT 1 FROM core.boletines_usuarios bu
                    WHERE bu.boletin_id = v_boletin_id AND bu.user_id = p_user_id)
        OR EXISTS (SELECT 1 FROM core.boletines_grupos bg
                     CROSS JOIN LATERAL core.fn_boletines_usuarios_de_grupo(bg.grupo_id, bg.incluir_subgrupos) g
                    WHERE bg.boletin_id = v_boletin_id AND g.user_id = p_user_id)
      INTO v_destino;

    RETURN jsonb_build_object('success', true, 'message', 'La solicitud ha tenido éxito',
                              'data', jsonb_build_object('archivo', v_archivo,
                                                         'boletin_id', v_boletin_id,
                                                         'destinatario', v_destino));
END;
$function$;

-- ---------------------------------------------------------------------------
-- Papelera
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION core.fn_boletines_papelera()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
AS $function$
DECLARE v_data jsonb;
BEGIN
    SELECT COALESCE(jsonb_agg(core.fn_boletines_json(b.id) ORDER BY b.deleted_at DESC), '[]'::jsonb)
      INTO v_data
      FROM core.boletines b
     WHERE b.deleted_at IS NOT NULL;

    RETURN jsonb_build_object('success', true, 'message', 'La solicitud ha tenido éxito', 'data', v_data);
END;
$function$;

-- ---------------------------------------------------------------------------
-- Borrado definitivo: devuelve los ficheros que hay que quitar del disco
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION core.fn_boletines_eliminar_definitivo(
    p_id bigint,
    p_usuario_id bigint DEFAULT NULL, p_usuario_login varchar DEFAULT NULL, p_usuario_nombre varchar DEFAULT NULL,
    p_ip_address inet DEFAULT NULL, p_user_agent text DEFAULT NULL, p_request_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
AS $function$
DECLARE
    v_titulo    varchar(200);
    v_archivos  jsonb;
BEGIN
    PERFORM core.fn_boletines_contexto_auditoria(p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    SELECT titulo INTO v_titulo FROM core.boletines WHERE id = p_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'El boletín no existe' USING ERRCODE = 'P0013';
    END IF;

    SELECT COALESCE(jsonb_agg(i.archivo), '[]'::jsonb) INTO v_archivos
      FROM core.boletines_imagenes i WHERE i.boletin_id = p_id;

    DELETE FROM core.boletines WHERE id = p_id;

    RETURN jsonb_build_object('success', true,
                              'message', format('Boletín «%s» eliminado definitivamente', v_titulo),
                              'data', jsonb_build_object('archivos', v_archivos));
END;
$function$;

CREATE OR REPLACE FUNCTION core.fn_boletines_vaciar_papelera(
    p_usuario_id bigint DEFAULT NULL, p_usuario_login varchar DEFAULT NULL, p_usuario_nombre varchar DEFAULT NULL,
    p_ip_address inet DEFAULT NULL, p_user_agent text DEFAULT NULL, p_request_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
AS $function$
DECLARE
    v_archivos jsonb;
    v_cuantos  integer;
BEGIN
    PERFORM core.fn_boletines_contexto_auditoria(p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    SELECT COALESCE(jsonb_agg(i.archivo), '[]'::jsonb) INTO v_archivos
      FROM core.boletines_imagenes i
      JOIN core.boletines b ON b.id = i.boletin_id
     WHERE b.deleted_at IS NOT NULL;

    WITH borrados AS (DELETE FROM core.boletines WHERE deleted_at IS NOT NULL RETURNING 1)
    SELECT COUNT(*) INTO v_cuantos FROM borrados;

    RETURN jsonb_build_object('success', true,
                              'message', format('%s boletín(es) eliminados de la papelera', v_cuantos),
                              'data', jsonb_build_object('archivos', v_archivos, 'cuantos', v_cuantos));
END;
$function$;
   THEN 'AUDIO'
             ELSE 'IMAGEN'
           END;
$function$;

COMMENT ON FUNCTION core.fn_boletines_tipo_archivo(text) IS 'IMAGEN, VIDEO o AUDIO según la extensión del fichero';

-- ---------------------------------------------------------------------------
-- Un boletín en json: con sus imágenes y sus destinatarios
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION core.fn_boletines_json(p_id bigint)
RETURNS jsonb
LANGUAGE sql
STABLE
AS $function$
    SELECT jsonb_build_object(
        'id',            b.id,
        'titulo',        b.titulo,
        'descripcion',   b.descripcion,
        'desde',         to_char(b.desde, 'YYYY-MM-DD'),
        'hasta',         to_char(b.hasta, 'YYYY-MM-DD'),
        'prioridad',     b.prioridad,
        'obligatorio',   b.obligatorio,
        'activo',        b.activo,
        'vigente',       (b.activo AND CURRENT_DATE BETWEEN b.desde AND b.hasta),
        'estado',        CASE WHEN NOT b.activo               THEN 'INACTIVO'
                              WHEN CURRENT_DATE < b.desde     THEN 'PROGRAMADO'
                              WHEN CURRENT_DATE > b.hasta     THEN 'CADUCADO'
                              ELSE 'VIGENTE' END,
        'en_papelera',   (b.deleted_at IS NOT NULL),
        'imagenes',      COALESCE((
                            SELECT jsonb_agg(jsonb_build_object(
                                     'id', i.id, 'archivo', i.archivo, 'titulo', i.titulo,
                                     'descripcion', i.descripcion, 'orden', i.orden,
                                     'segundos', i.segundos
                                   ) ORDER BY i.orden, i.id)
                              FROM core.boletines_imagenes i WHERE i.boletin_id = b.id), '[]'::jsonb),
        'usuarios',      COALESCE((
                            SELECT jsonb_agg(jsonb_build_object(
                                     'user_id', u.id, 'login_user', u.login_user,
                                     'name', u.name, 'surname', u.surname, 'isactive', u.isactive
                                   ) ORDER BY u.login_user)
                              FROM core.boletines_usuarios bu
                              JOIN seguridad.users u ON u.id = bu.user_id AND u.deleted_at IS NULL
                             WHERE bu.boletin_id = b.id), '[]'::jsonb),
        'grupos',        COALESCE((
                            SELECT jsonb_agg(jsonb_build_object(
                                     'grupo_id', g.id, 'nombre', g.nombre,
                                     'incluir_subgrupos', bg.incluir_subgrupos
                                   ) ORDER BY g.nombre)
                              FROM core.boletines_grupos bg
                              JOIN seguridad.grupos g ON g.id = bg.grupo_id
                             WHERE bg.boletin_id = b.id), '[]'::jsonb),
        'num_imagenes',  (SELECT COUNT(*) FROM core.boletines_imagenes i WHERE i.boletin_id = b.id),
        'num_usuarios',  (SELECT COUNT(*) FROM core.boletines_usuarios bu WHERE bu.boletin_id = b.id),
        'num_grupos',    (SELECT COUNT(*) FROM core.boletines_grupos bg WHERE bg.boletin_id = b.id),
        'num_vistos',    (SELECT COUNT(*) FROM core.boletines_vistos v WHERE v.boletin_id = b.id),
        'created_by',    b.created_by,
        'updated_by',    b.updated_by,
        'created_at',    to_char(b.created_at, 'YYYY-MM-DD HH24:MI:SS'),
        'updated_at',    to_char(b.updated_at, 'YYYY-MM-DD HH24:MI:SS')
    )
    FROM core.boletines b
    WHERE b.id = p_id;
$function$;

-- ---------------------------------------------------------------------------
-- Listado paginado para la grilla
--   p_estado: TODOS | VIGENTE | PROGRAMADO | CADUCADO | INACTIVO
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION core.fn_boletines_listar_paginado(
    p_page     integer DEFAULT 1,
    p_per_page integer DEFAULT 15,
    p_search   text    DEFAULT '',
    p_estado   text    DEFAULT 'TODOS'
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
AS $function$
DECLARE
    v_offset integer;
    v_total  bigint;
    v_filtro text;
    v_estado text;
    v_data   jsonb;
BEGIN
    v_offset := (GREATEST(p_page, 1) - 1) * p_per_page;
    v_filtro := NULLIF(TRIM(COALESCE(p_search, '')), '');
    v_estado := UPPER(COALESCE(NULLIF(TRIM(p_estado), ''), 'TODOS'));

    SELECT COUNT(*) INTO v_total
      FROM core.boletines b
     WHERE b.deleted_at IS NULL
       AND (v_filtro IS NULL
            OR b.titulo ILIKE '%' || v_filtro || '%'
            OR b.descripcion ILIKE '%' || v_filtro || '%'
            OR b.id::text ILIKE '%' || v_filtro || '%')
       AND (v_estado = 'TODOS'
            OR (v_estado = 'VIGENTE'    AND b.activo AND CURRENT_DATE BETWEEN b.desde AND b.hasta)
            OR (v_estado = 'PROGRAMADO' AND b.activo AND CURRENT_DATE < b.desde)
            OR (v_estado = 'CADUCADO'   AND b.activo AND CURRENT_DATE > b.hasta)
            OR (v_estado = 'INACTIVO'   AND NOT b.activo));

    SELECT COALESCE(jsonb_agg(core.fn_boletines_json(t.id) ORDER BY t.prioridad DESC, t.desde DESC, t.id DESC), '[]'::jsonb)
      INTO v_data
      FROM (
        SELECT b.id, b.prioridad, b.desde
          FROM core.boletines b
         WHERE b.deleted_at IS NULL
           AND (v_filtro IS NULL
                OR b.titulo ILIKE '%' || v_filtro || '%'
                OR b.descripcion ILIKE '%' || v_filtro || '%'
                OR b.id::text ILIKE '%' || v_filtro || '%')
           AND (v_estado = 'TODOS'
                OR (v_estado = 'VIGENTE'    AND b.activo AND CURRENT_DATE BETWEEN b.desde AND b.hasta)
                OR (v_estado = 'PROGRAMADO' AND b.activo AND CURRENT_DATE < b.desde)
                OR (v_estado = 'CADUCADO'   AND b.activo AND CURRENT_DATE > b.hasta)
                OR (v_estado = 'INACTIVO'   AND NOT b.activo))
         ORDER BY b.prioridad DESC, b.desde DESC, b.id DESC
         LIMIT p_per_page OFFSET v_offset
      ) t;

    RETURN jsonb_build_object(
        'success', true,
        'message', 'La solicitud ha tenido éxito',
        'data', jsonb_build_object(
            'data', v_data,
            'current_page', GREATEST(p_page, 1),
            'per_page', p_per_page,
            'total', v_total,
            'last_page', GREATEST(CEIL(v_total::numeric / NULLIF(p_per_page, 0))::int, 1)
        )
    );
END;
$function$;

-- ---------------------------------------------------------------------------
-- Obtener uno
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION core.fn_boletines_obtener(p_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
AS $function$
DECLARE v_data jsonb;
BEGIN
    SELECT core.fn_boletines_json(p_id) INTO v_data;
    IF v_data IS NULL THEN
        RETURN jsonb_build_object('success', false, 'message', 'El boletín no existe', 'data', NULL);
    END IF;
    RETURN jsonb_build_object('success', true, 'message', 'La solicitud ha tenido éxito', 'data', v_data);
END;
$function$;

-- ---------------------------------------------------------------------------
-- Guardar las imágenes y los destinatarios de un boletín (uso interno)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION core.fn_boletines_guardar_detalle(p_id bigint, p_datos jsonb)
RETURNS void
LANGUAGE plpgsql
AS $function$
DECLARE
    v_item jsonb;
    v_i    integer := 0;
BEGIN
    -- Imágenes: se reemplazan por las que manda la pantalla, en su orden
    IF p_datos ? 'imagenes' THEN
        DELETE FROM core.boletines_imagenes
         WHERE boletin_id = p_id
           AND (p_datos->'imagenes' = '[]'::jsonb
                OR id NOT IN (SELECT (x->>'id')::bigint
                                FROM jsonb_array_elements(p_datos->'imagenes') x
                               WHERE x->>'id' IS NOT NULL));

        FOR v_item IN SELECT * FROM jsonb_array_elements(p_datos->'imagenes') LOOP
            v_i := v_i + 1;
            IF v_item->>'id' IS NOT NULL THEN
                UPDATE core.boletines_imagenes
                   SET titulo      = NULLIF(TRIM(COALESCE(v_item->>'titulo', '')), ''),
                       descripcion = NULLIF(TRIM(COALESCE(v_item->>'descripcion', '')), ''),
                       orden       = v_i,
                       segundos    = GREATEST(1, LEAST(120, COALESCE(NULLIF(v_item->>'segundos', '')::smallint, segundos)))
                 WHERE id = (v_item->>'id')::bigint AND boletin_id = p_id;
            ELSE
                IF NULLIF(TRIM(COALESCE(v_item->>'archivo', '')), '') IS NULL THEN
                    RAISE EXCEPTION 'Cada imagen necesita su fichero' USING ERRCODE = 'P0001';
                END IF;
                INSERT INTO core.boletines_imagenes (boletin_id, archivo, titulo, descripcion, orden, segundos)
                VALUES (p_id,
                        v_item->>'archivo',
                        NULLIF(TRIM(COALESCE(v_item->>'titulo', '')), ''),
                        NULLIF(TRIM(COALESCE(v_item->>'descripcion', '')), ''),
                        v_i,
                        GREATEST(1, LEAST(120, COALESCE(NULLIF(v_item->>'segundos', '')::smallint, 6))));
            END IF;
        END LOOP;
    END IF;

    -- Destinatarios uno a uno
    IF p_datos ? 'usuarios' THEN
        DELETE FROM core.boletines_usuarios
         WHERE boletin_id = p_id
           AND (p_datos->'usuarios' = '[]'::jsonb
                OR user_id NOT IN (SELECT (x)::bigint FROM jsonb_array_elements_text(p_datos->'usuarios') x));

        INSERT INTO core.boletines_usuarios (boletin_id, user_id)
        SELECT p_id, (x)::bigint
          FROM jsonb_array_elements_text(p_datos->'usuarios') x
         WHERE EXISTS (SELECT 1 FROM seguridad.users u WHERE u.id = (x)::bigint AND u.deleted_at IS NULL)
        ON CONFLICT (boletin_id, user_id) DO NOTHING;
    END IF;

    -- Destinatarios por grupo
    IF p_datos ? 'grupos' THEN
        DELETE FROM core.boletines_grupos
         WHERE boletin_id = p_id
           AND (p_datos->'grupos' = '[]'::jsonb
                OR grupo_id NOT IN (SELECT (x->>'grupo_id')::bigint
                                      FROM jsonb_array_elements(p_datos->'grupos') x));

        FOR v_item IN SELECT * FROM jsonb_array_elements(p_datos->'grupos') LOOP
            IF NOT EXISTS (SELECT 1 FROM seguridad.grupos g WHERE g.id = (v_item->>'grupo_id')::bigint) THEN
                CONTINUE;
            END IF;
            INSERT INTO core.boletines_grupos (boletin_id, grupo_id, incluir_subgrupos)
            VALUES (p_id, (v_item->>'grupo_id')::bigint, COALESCE((v_item->>'incluir_subgrupos')::boolean, true))
            ON CONFLICT (boletin_id, grupo_id)
            DO UPDATE SET incluir_subgrupos = EXCLUDED.incluir_subgrupos;
        END LOOP;
    END IF;
END;
$function$;

-- ---------------------------------------------------------------------------
-- Crear
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION core.fn_boletines_crear(
    p_datos jsonb,
    p_usuario_id bigint DEFAULT NULL, p_usuario_login varchar DEFAULT NULL, p_usuario_nombre varchar DEFAULT NULL,
    p_ip_address inet DEFAULT NULL, p_user_agent text DEFAULT NULL, p_request_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
AS $function$
DECLARE
    v_id     bigint;
    v_titulo varchar(200);
    v_desde  date;
    v_hasta  date;
BEGIN
    PERFORM core.fn_boletines_contexto_auditoria(p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    v_titulo := NULLIF(TRIM(COALESCE(p_datos->>'titulo', '')), '');
    IF v_titulo IS NULL THEN
        RAISE EXCEPTION 'El título del boletín es obligatorio' USING ERRCODE = 'P0001';
    END IF;

    v_desde := COALESCE((p_datos->>'desde')::date, CURRENT_DATE);
    v_hasta := (p_datos->>'hasta')::date;
    IF v_hasta IS NULL THEN
        RAISE EXCEPTION 'La fecha hasta la que rige el boletín es obligatoria' USING ERRCODE = 'P0001';
    END IF;
    IF v_hasta < v_desde THEN
        RAISE EXCEPTION 'La vigencia termina antes de empezar' USING ERRCODE = 'P0010';
    END IF;

    INSERT INTO core.boletines (titulo, descripcion, desde, hasta, prioridad, obligatorio, activo)
    VALUES (v_titulo,
            NULLIF(TRIM(COALESCE(p_datos->>'descripcion', '')), ''),
            v_desde,
            v_hasta,
            COALESCE((p_datos->>'prioridad')::smallint, 0),
            COALESCE((p_datos->>'obligatorio')::boolean, false),
            COALESCE((p_datos->>'activo')::boolean, true))
    RETURNING id INTO v_id;

    PERFORM core.fn_boletines_guardar_detalle(v_id, p_datos);

    RETURN jsonb_build_object('success', true, 'message', 'Boletín creado con éxito', 'data', core.fn_boletines_json(v_id));
END;
$function$;

-- ---------------------------------------------------------------------------
-- Modificar
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION core.fn_boletines_modificar(
    p_id bigint,
    p_datos jsonb,
    p_usuario_id bigint DEFAULT NULL, p_usuario_login varchar DEFAULT NULL, p_usuario_nombre varchar DEFAULT NULL,
    p_ip_address inet DEFAULT NULL, p_user_agent text DEFAULT NULL, p_request_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
AS $function$
DECLARE
    v_actual core.boletines;
    v_desde  date;
    v_hasta  date;
BEGIN
    PERFORM core.fn_boletines_contexto_auditoria(p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    SELECT * INTO v_actual FROM core.boletines WHERE id = p_id AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'El boletín no existe' USING ERRCODE = 'P0013';
    END IF;

    v_desde := COALESCE((p_datos->>'desde')::date, v_actual.desde);
    v_hasta := COALESCE((p_datos->>'hasta')::date, v_actual.hasta);
    IF v_hasta < v_desde THEN
        RAISE EXCEPTION 'La vigencia termina antes de empezar' USING ERRCODE = 'P0010';
    END IF;

    UPDATE core.boletines
       SET titulo      = COALESCE(NULLIF(TRIM(COALESCE(p_datos->>'titulo', '')), ''), titulo),
           descripcion = CASE WHEN p_datos ? 'descripcion'
                              THEN NULLIF(TRIM(COALESCE(p_datos->>'descripcion', '')), '')
                              ELSE descripcion END,
           desde       = v_desde,
           hasta       = v_hasta,
           prioridad   = COALESCE((p_datos->>'prioridad')::smallint, prioridad),
           obligatorio = COALESCE((p_datos->>'obligatorio')::boolean, obligatorio),
           activo      = COALESCE((p_datos->>'activo')::boolean, activo)
     WHERE id = p_id;

    PERFORM core.fn_boletines_guardar_detalle(p_id, p_datos);

    RETURN jsonb_build_object('success', true, 'message', 'Boletín modificado con éxito', 'data', core.fn_boletines_json(p_id));
END;
$function$;

-- ---------------------------------------------------------------------------
-- Eliminar (lógico) y restaurar
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION core.fn_boletines_eliminar(
    p_id bigint,
    p_usuario_id bigint DEFAULT NULL, p_usuario_login varchar DEFAULT NULL, p_usuario_nombre varchar DEFAULT NULL,
    p_ip_address inet DEFAULT NULL, p_user_agent text DEFAULT NULL, p_request_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
AS $function$
DECLARE v_titulo varchar(200);
BEGIN
    PERFORM core.fn_boletines_contexto_auditoria(p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    SELECT titulo INTO v_titulo FROM core.boletines WHERE id = p_id AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'El boletín no existe' USING ERRCODE = 'P0013';
    END IF;

    UPDATE core.boletines
       SET deleted_at = now(),
           deleted_by = COALESCE(p_usuario_login, current_user),
           activo     = false
     WHERE id = p_id;

    RETURN jsonb_build_object('success', true, 'message', format('Boletín «%s» eliminado', v_titulo), 'data', NULL);
END;
$function$;

CREATE OR REPLACE FUNCTION core.fn_boletines_restaurar(
    p_id bigint,
    p_usuario_id bigint DEFAULT NULL, p_usuario_login varchar DEFAULT NULL, p_usuario_nombre varchar DEFAULT NULL,
    p_ip_address inet DEFAULT NULL, p_user_agent text DEFAULT NULL, p_request_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
AS $function$
BEGIN
    PERFORM core.fn_boletines_contexto_auditoria(p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    UPDATE core.boletines
       SET deleted_at = NULL, deleted_by = NULL
     WHERE id = p_id AND deleted_at IS NOT NULL;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'El boletín no está en la papelera' USING ERRCODE = 'P0013';
    END IF;

    RETURN jsonb_build_object('success', true, 'message', 'Boletín restaurado', 'data', core.fn_boletines_json(p_id));
END;
$function$;

-- ---------------------------------------------------------------------------
-- Destinatarios resueltos: quién verá el boletín (directos + por grupo)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION core.fn_boletines_destinatarios(p_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
AS $function$
DECLARE v_data jsonb;
BEGIN
    SELECT COALESCE(jsonb_agg(t ORDER BY t->>'login_user'), '[]'::jsonb) INTO v_data
      FROM (
        SELECT DISTINCT ON (u.id) jsonb_build_object(
                 'user_id',  u.id,
                 'login_user', u.login_user,
                 'name',     u.name,
                 'surname',  u.surname,
                 'isactive', u.isactive,
                 'origen',   d.origen,
                 'desde',    d.desde_nombre,
                 'visto_at', to_char(v.visto_at, 'YYYY-MM-DD HH24:MI:SS'),
                 'no_mostrar', COALESCE(v.no_mostrar, false)
               ) AS t, u.id
          FROM (
                SELECT bu.user_id, 'DIRECTO'::text AS origen, NULL::varchar AS desde_nombre
                  FROM core.boletines_usuarios bu WHERE bu.boletin_id = p_id
                UNION ALL
                SELECT g.user_id, 'GRUPO'::text, gr.nombre
                  FROM core.boletines_grupos bg
                  JOIN seguridad.grupos gr ON gr.id = bg.grupo_id
                  CROSS JOIN LATERAL core.fn_boletines_usuarios_de_grupo(bg.grupo_id, bg.incluir_subgrupos) g
                 WHERE bg.boletin_id = p_id
               ) d
          JOIN seguridad.users u ON u.id = d.user_id AND u.deleted_at IS NULL
          LEFT JOIN core.boletines_vistos v ON v.boletin_id = p_id AND v.user_id = u.id
         ORDER BY u.id, (d.origen = 'DIRECTO') DESC
      ) x;

    RETURN jsonb_build_object('success', true, 'message', 'La solicitud ha tenido éxito', 'data', v_data);
END;
$function$;

-- ---------------------------------------------------------------------------
-- Mis boletines: los vigentes de un usuario, para el carrusel de bienvenida
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION core.fn_boletines_mios(p_user_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
AS $function$
DECLARE v_data jsonb;
BEGIN
    SELECT COALESCE(jsonb_agg(core.fn_boletines_json(t.id) ORDER BY t.prioridad DESC, t.desde DESC, t.id DESC), '[]'::jsonb)
      INTO v_data
      FROM (
        SELECT DISTINCT b.id, b.prioridad, b.desde
          FROM core.boletines b
         WHERE b.deleted_at IS NULL
           AND b.activo
           AND CURRENT_DATE BETWEEN b.desde AND b.hasta
           AND EXISTS (SELECT 1 FROM core.boletines_imagenes i WHERE i.boletin_id = b.id)
           AND (
                EXISTS (SELECT 1 FROM core.boletines_usuarios bu
                         WHERE bu.boletin_id = b.id AND bu.user_id = p_user_id)
             OR EXISTS (SELECT 1 FROM core.boletines_grupos bg
                          CROSS JOIN LATERAL core.fn_boletines_usuarios_de_grupo(bg.grupo_id, bg.incluir_subgrupos) g
                         WHERE bg.boletin_id = b.id AND g.user_id = p_user_id)
               )
           AND NOT EXISTS (SELECT 1 FROM core.boletines_vistos v
                            WHERE v.boletin_id = b.id AND v.user_id = p_user_id AND v.no_mostrar)
      ) t;

    RETURN jsonb_build_object('success', true, 'message', 'La solicitud ha tenido éxito', 'data', v_data);
END;
$function$;

-- ---------------------------------------------------------------------------
-- Registrar la lectura (y el "no volver a mostrar")
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION core.fn_boletines_marcar_visto(
    p_boletin_id bigint,
    p_user_id    bigint,
    p_no_mostrar boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
AS $function$
BEGIN
    IF p_boletin_id IS NULL OR p_user_id IS NULL THEN
        RAISE EXCEPTION 'Faltan el boletín o el usuario' USING ERRCODE = 'P0001';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM core.boletines WHERE id = p_boletin_id AND deleted_at IS NULL) THEN
        RAISE EXCEPTION 'El boletín no existe' USING ERRCODE = 'P0013';
    END IF;

    INSERT INTO core.boletines_vistos (boletin_id, user_id, no_mostrar)
    VALUES (p_boletin_id, p_user_id, COALESCE(p_no_mostrar, false))
    ON CONFLICT (boletin_id, user_id) DO UPDATE
       SET visto_at   = now(),
           veces      = core.boletines_vistos.veces + 1,
           no_mostrar = core.boletines_vistos.no_mostrar OR COALESCE(EXCLUDED.no_mostrar, false);

    RETURN jsonb_build_object('success', true, 'message', 'Lectura registrada', 'data', NULL);
END;
$function$;

-- ---------------------------------------------------------------------------
-- Datos de una imagen para servirla: sólo si el usuario es destinatario
-- (o si administra el boletín, lo que decide el back)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION core.fn_boletines_imagen(p_imagen_id bigint, p_user_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
AS $function$
DECLARE
    v_archivo    varchar(255);
    v_boletin_id bigint;
    v_destino    boolean;
BEGIN
    SELECT i.archivo, i.boletin_id INTO v_archivo, v_boletin_id
      FROM core.boletines_imagenes i
      JOIN core.boletines b ON b.id = i.boletin_id AND b.deleted_at IS NULL
     WHERE i.id = p_imagen_id;

    IF v_archivo IS NULL THEN
        RETURN jsonb_build_object('success', false, 'message', 'La imagen no existe', 'data', NULL);
    END IF;

    SELECT EXISTS (SELECT 1 FROM core.boletines_usuarios bu
                    WHERE bu.boletin_id = v_boletin_id AND bu.user_id = p_user_id)
        OR EXISTS (SELECT 1 FROM core.boletines_grupos bg
                     CROSS JOIN LATERAL core.fn_boletines_usuarios_de_grupo(bg.grupo_id, bg.incluir_subgrupos) g
                    WHERE bg.boletin_id = v_boletin_id AND g.user_id = p_user_id)
      INTO v_destino;

    RETURN jsonb_build_object('success', true, 'message', 'La solicitud ha tenido éxito',
                              'data', jsonb_build_object('archivo', v_archivo,
                                                         'boletin_id', v_boletin_id,
                                                         'destinatario', v_destino));
END;
$function$;

-- ---------------------------------------------------------------------------
-- Papelera
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION core.fn_boletines_papelera()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
AS $function$
DECLARE v_data jsonb;
BEGIN
    SELECT COALESCE(jsonb_agg(core.fn_boletines_json(b.id) ORDER BY b.deleted_at DESC), '[]'::jsonb)
      INTO v_data
      FROM core.boletines b
     WHERE b.deleted_at IS NOT NULL;

    RETURN jsonb_build_object('success', true, 'message', 'La solicitud ha tenido éxito', 'data', v_data);
END;
$function$;

-- ---------------------------------------------------------------------------
-- Borrado definitivo: devuelve los ficheros que hay que quitar del disco
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION core.fn_boletines_eliminar_definitivo(
    p_id bigint,
    p_usuario_id bigint DEFAULT NULL, p_usuario_login varchar DEFAULT NULL, p_usuario_nombre varchar DEFAULT NULL,
    p_ip_address inet DEFAULT NULL, p_user_agent text DEFAULT NULL, p_request_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
AS $function$
DECLARE
    v_titulo    varchar(200);
    v_archivos  jsonb;
BEGIN
    PERFORM core.fn_boletines_contexto_auditoria(p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    SELECT titulo INTO v_titulo FROM core.boletines WHERE id = p_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'El boletín no existe' USING ERRCODE = 'P0013';
    END IF;

    SELECT COALESCE(jsonb_agg(i.archivo), '[]'::jsonb) INTO v_archivos
      FROM core.boletines_imagenes i WHERE i.boletin_id = p_id;

    DELETE FROM core.boletines WHERE id = p_id;

    RETURN jsonb_build_object('success', true,
                              'message', format('Boletín «%s» eliminado definitivamente', v_titulo),
                              'data', jsonb_build_object('archivos', v_archivos));
END;
$function$;

CREATE OR REPLACE FUNCTION core.fn_boletines_vaciar_papelera(
    p_usuario_id bigint DEFAULT NULL, p_usuario_login varchar DEFAULT NULL, p_usuario_nombre varchar DEFAULT NULL,
    p_ip_address inet DEFAULT NULL, p_user_agent text DEFAULT NULL, p_request_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
AS $function$
DECLARE
    v_archivos jsonb;
    v_cuantos  integer;
BEGIN
    PERFORM core.fn_boletines_contexto_auditoria(p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    SELECT COALESCE(jsonb_agg(i.archivo), '[]'::jsonb) INTO v_archivos
      FROM core.boletines_imagenes i
      JOIN core.boletines b ON b.id = i.boletin_id
     WHERE b.deleted_at IS NOT NULL;

    WITH borrados AS (DELETE FROM core.boletines WHERE deleted_at IS NOT NULL RETURNING 1)
    SELECT COUNT(*) INTO v_cuantos FROM borrados;

    RETURN jsonb_build_object('success', true,
                              'message', format('%s boletín(es) eliminados de la papelera', v_cuantos),
                              'data', jsonb_build_object('archivos', v_archivos, 'cuantos', v_cuantos));
END;
$function$;
