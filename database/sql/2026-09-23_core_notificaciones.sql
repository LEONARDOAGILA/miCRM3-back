-- ============================================================================
-- NOTIFICACIONES
--
--   core.notificaciones           el aviso: qué dice, de qué tipo y a dónde lleva
--   core.notificaciones_usuarios  una fila por destinatario, con su «leída»
--
-- A diferencia de los boletines —que se muestran a pantalla completa al entrar
-- y son un acto de lectura— la notificación es un aviso breve que cuelga de la
-- campana: llega, se acumula sin estorbar y el usuario la lee cuando quiere.
--
-- Al enviarla se resuelven los grupos y se escribe una fila por usuario. Eso
-- hace que leer la campana sea una consulta directa por user_id (lo que se
-- hace cien veces) a cambio de un poco más de trabajo al enviar (una vez).
--
-- Mismo esquema que el resto del sistema: la lógica vive en estas funciones,
-- el contexto de auditoría lo leen los triggers y las reglas de negocio se
-- lanzan con RAISE EXCEPTION + SQLSTATE propio:
--   P0001 datos obligatorios   P0010 valor no admitido   P0013 no existe
-- Idempotente: IF NOT EXISTS / CREATE OR REPLACE.
--
--   psql -h 192.168.2.173 -U postgres -d crm3 -f 2026-09-23_core_notificaciones.sql
-- ============================================================================

-- ---------------------------------------------------------------------------
-- TABLAS
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS core.notificaciones (
    id           bigserial PRIMARY KEY,
    titulo       varchar(200) NOT NULL,
    mensaje      text,
    /** Da el color y el icono por defecto en la campana */
    tipo         varchar(10)  NOT NULL DEFAULT 'INFO'
                 CHECK (tipo IN ('INFO', 'EXITO', 'AVISO', 'ERROR')),
    /** Icono propio (clase de Font Awesome); si va vacío, manda el tipo */
    icono        varchar(60),
    /** A dónde lleva al pulsarla: una ruta del front, p. ej. /config/boletines */
    url          varchar(500),
    url_texto    varchar(60),
    /** Quién la generó: una persona desde la pantalla o el propio sistema */
    origen       varchar(10)  NOT NULL DEFAULT 'MANUAL'
                 CHECK (origen IN ('MANUAL', 'SISTEMA')),
    /** De qué módulo viene y a qué registro apunta (para rastrearla) */
    modulo           varchar(50),
    referencia_tabla varchar(60),
    referencia_id    bigint,
    /** Desde cuándo deja de mostrarse (NULL = no caduca) */
    caduca_at    timestamptz,
    deleted_at   timestamptz,
    deleted_by   varchar,
    created_at   timestamptz DEFAULT now(),
    updated_at   timestamptz DEFAULT now(),
    created_by   varchar,
    updated_by   varchar
);

COMMENT ON TABLE  core.notificaciones IS 'Avisos breves que se acumulan en la campana de cada usuario';
COMMENT ON COLUMN core.notificaciones.url IS 'Ruta del front a la que lleva la notificación al pulsarla';
COMMENT ON COLUMN core.notificaciones.caduca_at IS 'A partir de esta fecha deja de mostrarse en la campana';

CREATE INDEX IF NOT EXISTS ix_notificaciones_creadas ON core.notificaciones (created_at DESC) WHERE deleted_at IS NULL;


CREATE TABLE IF NOT EXISTS core.notificaciones_usuarios (
    id              bigserial PRIMARY KEY,
    notificacion_id bigint NOT NULL REFERENCES core.notificaciones(id) ON DELETE CASCADE,
    user_id         bigint NOT NULL REFERENCES seguridad.users(id) ON DELETE CASCADE,
    /** Cuándo la leyó; NULL mientras esté sin leer */
    leida_at        timestamptz,
    /** El usuario la quitó de su campana (no borra la notificación) */
    archivada_at    timestamptz,
    created_at      timestamptz DEFAULT now(),
    CONSTRAINT uk_notificaciones_usuarios UNIQUE (notificacion_id, user_id)
);

COMMENT ON TABLE core.notificaciones_usuarios IS 'Una fila por destinatario: si la leyó y si la archivó';

-- La consulta de la campana: las de un usuario, las no leídas primero
CREATE INDEX IF NOT EXISTS ix_notificaciones_usuarios_campana
    ON core.notificaciones_usuarios (user_id, leida_at, archivada_at);

-- Auditoría: los mismos tres triggers que el resto del sistema
DO $bloque$
DECLARE t text;
BEGIN
    FOREACH t IN ARRAY ARRAY['notificaciones'] LOOP
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
CREATE OR REPLACE FUNCTION core.fn_notificaciones_contexto_auditoria(
    p_usuario_id bigint, p_usuario_login varchar, p_usuario_nombre varchar,
    p_ip_address inet, p_user_agent text, p_request_id uuid
)
RETURNS void
LANGUAGE plpgsql
AS $function$
BEGIN
    PERFORM set_config('app.usuario_id',     COALESCE(p_usuario_id::text, ''), true);
    PERFORM set_config('app.usuario_login',  COALESCE(p_usuario_login, ''),    true);
    PERFORM set_config('app.usuario_nombre', COALESCE(p_usuario_nombre, ''),   true);
    PERFORM set_config('app.ip_address',     COALESCE(p_ip_address::text, ''), true);
    PERFORM set_config('app.user_agent',     COALESCE(p_user_agent, ''),       true);
    PERFORM set_config('app.request_id',     COALESCE(p_request_id::text, ''), true);
    PERFORM set_config('app.modulo',         'core.notificaciones',            true);
END;
$function$;


-- ---------------------------------------------------------------------------
-- Una notificación en json, con su recuento de lecturas
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION core.fn_notificaciones_json(p_id bigint)
RETURNS jsonb
LANGUAGE sql
STABLE
AS $function$
    SELECT jsonb_build_object(
        'id',           n.id,
        'titulo',       n.titulo,
        'mensaje',      n.mensaje,
        'tipo',         n.tipo,
        'icono',        n.icono,
        'url',          n.url,
        'url_texto',    n.url_texto,
        'origen',       n.origen,
        'modulo',       n.modulo,
        'referencia_tabla', n.referencia_tabla,
        'referencia_id',    n.referencia_id,
        'caduca_at',    to_char(n.caduca_at, 'YYYY-MM-DD HH24:MI'),
        'caducada',     (n.caduca_at IS NOT NULL AND n.caduca_at <= now()),
        'created_at',   to_char(n.created_at, 'YYYY-MM-DD HH24:MI'),
        'created_by',   n.created_by,
        'destinatarios', (SELECT COUNT(*) FROM core.notificaciones_usuarios u WHERE u.notificacion_id = n.id),
        'leidas',        (SELECT COUNT(*) FROM core.notificaciones_usuarios u WHERE u.notificacion_id = n.id AND u.leida_at IS NOT NULL)
    )
    FROM core.notificaciones n
    WHERE n.id = p_id;
$function$;


-- ---------------------------------------------------------------------------
-- Listado del administrador, paginado
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION core.fn_notificaciones_listar_paginado(
    p_page integer DEFAULT 1,
    p_per_page integer DEFAULT 15,
    p_search text DEFAULT NULL,
    p_tipo text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
AS $function$
DECLARE
    v_offset integer;
    v_total  bigint;
    v_filtro text;
    v_tipo   text;
    v_data   jsonb;
BEGIN
    v_offset := (GREATEST(p_page, 1) - 1) * p_per_page;
    v_filtro := NULLIF(TRIM(COALESCE(p_search, '')), '');
    v_tipo   := UPPER(COALESCE(NULLIF(TRIM(p_tipo), ''), 'TODOS'));

    SELECT COUNT(*) INTO v_total
      FROM core.notificaciones n
     WHERE n.deleted_at IS NULL
       AND (v_filtro IS NULL
            OR n.titulo ILIKE '%' || v_filtro || '%'
            OR n.mensaje ILIKE '%' || v_filtro || '%'
            OR n.id::text ILIKE '%' || v_filtro || '%')
       AND (v_tipo = 'TODOS' OR n.tipo = v_tipo);

    SELECT COALESCE(jsonb_agg(core.fn_notificaciones_json(t.id) ORDER BY t.created_at DESC, t.id DESC), '[]'::jsonb)
      INTO v_data
      FROM (
        SELECT n.id, n.created_at
          FROM core.notificaciones n
         WHERE n.deleted_at IS NULL
           AND (v_filtro IS NULL
                OR n.titulo ILIKE '%' || v_filtro || '%'
                OR n.mensaje ILIKE '%' || v_filtro || '%'
                OR n.id::text ILIKE '%' || v_filtro || '%')
           AND (v_tipo = 'TODOS' OR n.tipo = v_tipo)
         ORDER BY n.created_at DESC, n.id DESC
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
-- Obtener una
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION core.fn_notificaciones_obtener(p_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
AS $function$
DECLARE v_data jsonb;
BEGIN
    SELECT core.fn_notificaciones_json(n.id) INTO v_data
      FROM core.notificaciones n
     WHERE n.id = p_id AND n.deleted_at IS NULL;

    IF v_data IS NULL THEN
        RETURN jsonb_build_object('success', false, 'message', 'La notificación no existe', 'data', NULL);
    END IF;

    RETURN jsonb_build_object('success', true, 'message', 'La solicitud ha tenido éxito', 'data', v_data);
END;
$function$;


-- ---------------------------------------------------------------------------
-- Usuarios de un grupo (con sus subgrupos si se pide)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION core.fn_notificaciones_usuarios_de_grupo(p_grupo_id bigint, p_subgrupos boolean)
RETURNS TABLE(user_id bigint)
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
-- Enviar: crea la notificación y le pone una fila a cada destinatario
--
-- p_datos:
--   { titulo, mensaje, tipo, icono, url, url_texto, origen, modulo,
--     referencia_tabla, referencia_id, caduca_at,
--     usuarios: [id…], grupos: [{grupo_id, incluir_subgrupos}…], todos: bool }
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION core.fn_notificaciones_enviar(
    p_datos jsonb,
    p_usuario_id bigint DEFAULT NULL, p_usuario_login varchar DEFAULT NULL, p_usuario_nombre varchar DEFAULT NULL,
    p_ip_address inet DEFAULT NULL, p_user_agent text DEFAULT NULL, p_request_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
AS $function$
DECLARE
    v_id      bigint;
    v_titulo  varchar(200);
    v_tipo    varchar(10);
    v_cuantos integer;
BEGIN
    PERFORM core.fn_notificaciones_contexto_auditoria(p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    v_titulo := NULLIF(TRIM(COALESCE(p_datos->>'titulo', '')), '');
    IF v_titulo IS NULL THEN
        RAISE EXCEPTION 'El título de la notificación es obligatorio' USING ERRCODE = 'P0001';
    END IF;

    v_tipo := UPPER(COALESCE(NULLIF(TRIM(p_datos->>'tipo'), ''), 'INFO'));
    IF v_tipo NOT IN ('INFO', 'EXITO', 'AVISO', 'ERROR') THEN
        RAISE EXCEPTION 'El tipo debe ser INFO, EXITO, AVISO o ERROR' USING ERRCODE = 'P0010';
    END IF;

    INSERT INTO core.notificaciones (
        titulo, mensaje, tipo, icono, url, url_texto, origen, modulo,
        referencia_tabla, referencia_id, caduca_at
    )
    VALUES (
        v_titulo,
        NULLIF(TRIM(COALESCE(p_datos->>'mensaje', '')), ''),
        v_tipo,
        NULLIF(TRIM(COALESCE(p_datos->>'icono', '')), ''),
        NULLIF(TRIM(COALESCE(p_datos->>'url', '')), ''),
        NULLIF(TRIM(COALESCE(p_datos->>'url_texto', '')), ''),
        UPPER(COALESCE(NULLIF(TRIM(p_datos->>'origen'), ''), 'MANUAL')),
        NULLIF(TRIM(COALESCE(p_datos->>'modulo', '')), ''),
        NULLIF(TRIM(COALESCE(p_datos->>'referencia_tabla', '')), ''),
        NULLIF(p_datos->>'referencia_id', '')::bigint,
        NULLIF(p_datos->>'caduca_at', '')::timestamptz
    )
    RETURNING id INTO v_id;

    -- Destinatarios: sueltos, por grupo o todo el mundo. Se escribe una fila
    -- por usuario para que leer la campana sea una consulta directa.
    WITH candidatos AS (
        SELECT u.id AS user_id
          FROM seguridad.users u
         WHERE u.deleted_at IS NULL
           AND u.isactive
           AND COALESCE((p_datos->>'todos')::boolean, false)

        UNION

        SELECT (x)::bigint
          FROM jsonb_array_elements_text(COALESCE(p_datos->'usuarios', '[]'::jsonb)) x

        UNION

        SELECT g.user_id
          FROM jsonb_array_elements(COALESCE(p_datos->'grupos', '[]'::jsonb)) gr
          CROSS JOIN LATERAL core.fn_notificaciones_usuarios_de_grupo(
                       (gr->>'grupo_id')::bigint,
                       COALESCE((gr->>'incluir_subgrupos')::boolean, true)) g
    ),
    validos AS (
        SELECT DISTINCT c.user_id
          FROM candidatos c
          JOIN seguridad.users u ON u.id = c.user_id AND u.deleted_at IS NULL
    ),
    puestas AS (
        INSERT INTO core.notificaciones_usuarios (notificacion_id, user_id)
        SELECT v_id, v.user_id FROM validos v
        ON CONFLICT (notificacion_id, user_id) DO NOTHING
        RETURNING 1
    )
    SELECT COUNT(*) INTO v_cuantos FROM puestas;

    IF v_cuantos = 0 THEN
        RAISE EXCEPTION 'No se indicó ningún destinatario' USING ERRCODE = 'P0001';
    END IF;

    RETURN jsonb_build_object(
        'success', true,
        'message', CASE WHEN v_cuantos = 1 THEN 'Notificación enviada a 1 usuario'
                        ELSE format('Notificación enviada a %s usuarios', v_cuantos) END,
        'data', jsonb_build_object(
            'notificacion', core.fn_notificaciones_json(v_id),
            'destinatarios', v_cuantos,
            'ids_usuarios', (SELECT COALESCE(jsonb_agg(u.user_id), '[]'::jsonb)
                               FROM core.notificaciones_usuarios u WHERE u.notificacion_id = v_id)
        )
    );
END;
$function$;


-- ---------------------------------------------------------------------------
-- Eliminar (lógico): deja de estar en la campana de todos
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION core.fn_notificaciones_eliminar(
    p_id bigint,
    p_usuario_id bigint DEFAULT NULL, p_usuario_login varchar DEFAULT NULL, p_usuario_nombre varchar DEFAULT NULL,
    p_ip_address inet DEFAULT NULL, p_user_agent text DEFAULT NULL, p_request_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
AS $function$
DECLARE v_titulo varchar(200);
BEGIN
    PERFORM core.fn_notificaciones_contexto_auditoria(p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    SELECT titulo INTO v_titulo FROM core.notificaciones WHERE id = p_id AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'La notificación no existe' USING ERRCODE = 'P0013';
    END IF;

    UPDATE core.notificaciones
       SET deleted_at = now(),
           deleted_by = COALESCE(p_usuario_login, current_user)
     WHERE id = p_id;

    RETURN jsonb_build_object('success', true,
                              'message', format('Notificación «%s» eliminada', v_titulo),
                              'data', NULL);
END;
$function$;


-- ---------------------------------------------------------------------------
-- Quiénes la recibieron y quiénes la leyeron
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION core.fn_notificaciones_destinatarios(p_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
AS $function$
DECLARE v_data jsonb;
BEGIN
    SELECT COALESCE(jsonb_agg(t ORDER BY t->>'login_user'), '[]'::jsonb) INTO v_data
      FROM (
        SELECT jsonb_build_object(
                 'user_id',    u.id,
                 'login_user', u.login_user,
                 'name',       u.name,
                 'surname',    u.surname,
                 'isactive',   u.isactive,
                 'leida_at',   to_char(nu.leida_at, 'YYYY-MM-DD HH24:MI:SS'),
                 'archivada',  (nu.archivada_at IS NOT NULL)
               ) AS t
          FROM core.notificaciones_usuarios nu
          JOIN seguridad.users u ON u.id = nu.user_id AND u.deleted_at IS NULL
         WHERE nu.notificacion_id = p_id
      ) x;

    RETURN jsonb_build_object('success', true, 'message', 'La solicitud ha tenido éxito', 'data', v_data);
END;
$function$;


-- ---------------------------------------------------------------------------
-- La campana: las notificaciones de un usuario
--
-- Fuera las eliminadas, las caducadas y las que él archivó. Van de la más
-- reciente a la más vieja; el contador de no leídas viene aparte porque la
-- campana lo enseña aunque no despliegue la lista.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION core.fn_notificaciones_mias(
    p_user_id bigint,
    p_solo_no_leidas boolean DEFAULT false,
    p_limite integer DEFAULT 20,
    p_desplazamiento integer DEFAULT 0
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
AS $function$
DECLARE
    v_data      jsonb;
    v_no_leidas integer;
    v_total     integer;
BEGIN
    SELECT COUNT(*) FILTER (WHERE nu.leida_at IS NULL), COUNT(*)
      INTO v_no_leidas, v_total
      FROM core.notificaciones_usuarios nu
      JOIN core.notificaciones n ON n.id = nu.notificacion_id
     WHERE nu.user_id = p_user_id
       AND nu.archivada_at IS NULL
       AND n.deleted_at IS NULL
       AND (n.caduca_at IS NULL OR n.caduca_at > now());

    SELECT COALESCE(jsonb_agg(t ORDER BY (t->>'created_at') DESC, (t->>'id')::bigint DESC), '[]'::jsonb)
      INTO v_data
      FROM (
        SELECT core.fn_notificaciones_json(n.id)
               || jsonb_build_object(
                    'leida',    (nu.leida_at IS NOT NULL),
                    'leida_at', to_char(nu.leida_at, 'YYYY-MM-DD HH24:MI')
                  ) AS t
          FROM core.notificaciones_usuarios nu
          JOIN core.notificaciones n ON n.id = nu.notificacion_id
         WHERE nu.user_id = p_user_id
           AND nu.archivada_at IS NULL
           AND n.deleted_at IS NULL
           AND (n.caduca_at IS NULL OR n.caduca_at > now())
           AND (NOT p_solo_no_leidas OR nu.leida_at IS NULL)
         ORDER BY n.created_at DESC, n.id DESC
         LIMIT GREATEST(p_limite, 1) OFFSET GREATEST(p_desplazamiento, 0)
      ) x;

    RETURN jsonb_build_object(
        'success', true,
        'message', 'La solicitud ha tenido éxito',
        'data', jsonb_build_object(
            'data', v_data,
            'no_leidas', v_no_leidas,
            'total', v_total
        )
    );
END;
$function$;


-- ---------------------------------------------------------------------------
-- Cuántas tiene sin leer (lo que enseña la campana)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION core.fn_notificaciones_contador(p_user_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
AS $function$
DECLARE v_no_leidas integer;
BEGIN
    SELECT COUNT(*) INTO v_no_leidas
      FROM core.notificaciones_usuarios nu
      JOIN core.notificaciones n ON n.id = nu.notificacion_id
     WHERE nu.user_id = p_user_id
       AND nu.leida_at IS NULL
       AND nu.archivada_at IS NULL
       AND n.deleted_at IS NULL
       AND (n.caduca_at IS NULL OR n.caduca_at > now());

    RETURN jsonb_build_object('success', true, 'message', 'La solicitud ha tenido éxito',
                              'data', jsonb_build_object('no_leidas', v_no_leidas));
END;
$function$;


-- ---------------------------------------------------------------------------
-- Marcar leídas: las de `p_ids`, o todas las del usuario si va NULL
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION core.fn_notificaciones_marcar_leidas(
    p_user_id bigint,
    p_ids bigint[] DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
AS $function$
DECLARE v_cuantas integer;
BEGIN
    IF p_user_id IS NULL THEN
        RAISE EXCEPTION 'Falta el usuario' USING ERRCODE = 'P0001';
    END IF;

    WITH marcadas AS (
        UPDATE core.notificaciones_usuarios nu
           SET leida_at = now()
         WHERE nu.user_id = p_user_id
           AND nu.leida_at IS NULL
           AND (p_ids IS NULL OR nu.notificacion_id = ANY(p_ids))
        RETURNING 1
    )
    SELECT COUNT(*) INTO v_cuantas FROM marcadas;

    RETURN jsonb_build_object('success', true,
                              'message', CASE WHEN v_cuantas = 0 THEN 'No había nada sin leer'
                                              WHEN v_cuantas = 1 THEN 'Notificación marcada como leída'
                                              ELSE format('%s notificaciones marcadas como leídas', v_cuantas) END,
                              'data', jsonb_build_object('marcadas', v_cuantas));
END;
$function$;


-- ---------------------------------------------------------------------------
-- Archivar: el usuario la quita de su campana (no toca la de los demás)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION core.fn_notificaciones_archivar(
    p_user_id bigint,
    p_ids bigint[] DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
AS $function$
DECLARE v_cuantas integer;
BEGIN
    IF p_user_id IS NULL THEN
        RAISE EXCEPTION 'Falta el usuario' USING ERRCODE = 'P0001';
    END IF;

    WITH archivadas AS (
        UPDATE core.notificaciones_usuarios nu
           SET archivada_at = now(),
               leida_at = COALESCE(nu.leida_at, now())
         WHERE nu.user_id = p_user_id
           AND nu.archivada_at IS NULL
           AND (p_ids IS NULL OR nu.notificacion_id = ANY(p_ids))
        RETURNING 1
    )
    SELECT COUNT(*) INTO v_cuantas FROM archivadas;

    RETURN jsonb_build_object('success', true,
                              'message', CASE WHEN v_cuantas = 0 THEN 'No había nada que quitar'
                                              WHEN v_cuantas = 1 THEN 'Notificación quitada de la campana'
                                              ELSE format('%s notificaciones quitadas de la campana', v_cuantas) END,
                              'data', jsonb_build_object('archivadas', v_cuantas));
END;
$function$;
