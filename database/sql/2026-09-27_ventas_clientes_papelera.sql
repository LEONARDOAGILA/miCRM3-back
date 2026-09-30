-- ============================================================================
-- PAPELERA DE RECICLAJE DE CLIENTES (borrado lógico), como la de usuarios
-- (seguridad.fn_usuarios_papelera_*): "eliminar" un cliente lo manda a la
-- papelera (deleted_at / deleted_by), desde donde se restaura o se borra de
-- verdad.
--
--   ventas.clientes.deleted_at / deleted_by            columnas nuevas
--   ventas.fn_clientes_eliminar(...)                   AHORA borrado lógico
--   ventas.fn_clientes_papelera_listar()               lo que hay en la papelera
--   ventas.fn_clientes_restaurar(ids, ...)             vuelven a estar vigentes
--   ventas.fn_clientes_eliminar_definitivo(ids, ...)   DELETE real (sólo de la papelera)
--   ventas.fn_clientes_papelera_vaciar(...)            DELETE real de todo lo que hay
--
-- Los eliminados NO salen en ningún listado: se reescriben
-- fn_clientes_listar_paginado y fn_clientes_listar con «deleted_at IS NULL».
-- fn_clientes_obtener SÍ los devuelve (los necesita la papelera) y ahora
-- incluye deleted_at / deleted_by. Al crear o modificar, si la identificación
-- que se repite es de alguien que está en la papelera, el mensaje lo dice:
-- el índice único también cuenta a los eliminados.
--
-- Error de negocio nuevo: P0019 el cliente no está en la papelera.
-- Idempotente: IF NOT EXISTS / CREATE OR REPLACE.
-- ============================================================================

ALTER TABLE ventas.clientes ADD COLUMN IF NOT EXISTS deleted_at timestamptz;
ALTER TABLE ventas.clientes ADD COLUMN IF NOT EXISTS deleted_by varchar(100);
COMMENT ON COLUMN ventas.clientes.deleted_at IS 'Fecha en que se envió a la papelera de reciclaje (NULL = vigente)';
COMMENT ON COLUMN ventas.clientes.deleted_by IS 'Login de quien lo envió a la papelera';
CREATE INDEX IF NOT EXISTS ix_clientes_deleted_at ON ventas.clientes (deleted_at) WHERE deleted_at IS NOT NULL;

-- ---------------------------------------------------------------------------
-- OBTENER UNO (+ deleted_at / deleted_by)
-- Devuelve también los que están en la papelera: de ahí saca sus datos la
-- pantalla de la papelera.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ventas.fn_clientes_obtener(p_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
    v_data jsonb;
BEGIN
    SELECT jsonb_build_object(
        'id',                    c.id,
        'tipo_cliente',          c.tipo_cliente,
        'numero_identificacion', c.numero_identificacion,
        'tipo_identificacion',   c.tipo_identificacion,
        'razon_social',          c.razon_social,
        'nombre_comercial',      c.nombre_comercial,
        'nombres',               c.nombres,
        'apellidos',             c.apellidos,
        'nombre_completo',       c.nombre_completo,
        'email',                 c.email,
        'email_alterno',         c.email_alterno,
        'telefono',              c.telefono,
        'celular',               c.celular,
        'sitio_web',             c.sitio_web,
        'fecha_nacimiento',      to_char(c.fecha_nacimiento, 'YYYY-MM-DD'),
        'genero',                c.genero,
        'direccion',             c.direccion,
        'provincia',             c.provincia,
        'canton',                c.canton,
        'parroquia',             c.parroquia,
        'calle_principal',       c.calle_principal,
        'calle_secundaria',      c.calle_secundaria,
        'numeracion',            c.numeracion,
        'ubicacion',             c.ubicacion,
        'codigo_postal',         c.codigo_postal,
        'coordenadas',           c.coordenadas,
        'link_coordenadas',      c.link_coordenadas,
        'url_foto_mapa',         c.url_foto_mapa,
        'url_foto_casa',         c.url_foto_casa,
        'vendedor_id',           c.vendedor_id,
        'vendedor_nombre',       (SELECT TRIM(COALESCE(e.nombres, '') || ' ' || COALESCE(e.apellidos, ''))
                                    FROM rh.empleados e WHERE e.id = c.vendedor_id),
        'forma_pago',            c.forma_pago,
        'limite_credito',        c.limite_credito,
        'dias_credito',          c.dias_credito,
        'descuento',             c.descuento,
        'estado',                c.estado,
        'observaciones',         c.observaciones,
        'foto',                  c.foto,
        'activo',                c.activo,
        'num_contactos',         (SELECT COUNT(*) FROM ventas.contactos_clientes cc WHERE cc.cliente_id = c.id),
        'deleted_at',            to_char(c.deleted_at, 'YYYY-MM-DD HH24:MI:SS'),
        'deleted_by',            c.deleted_by,
        'created_by',            c.created_by,
        'updated_by',            c.updated_by,
        'created_at',            to_char(c.created_at, 'YYYY-MM-DD HH24:MI:SS'),
        'updated_at',            to_char(c.updated_at, 'YYYY-MM-DD HH24:MI:SS')
    ) INTO v_data
    FROM ventas.clientes c
    WHERE c.id = p_id;

    IF v_data IS NULL THEN
        RETURN jsonb_build_object('success', false, 'message', 'Cliente no encontrado', 'error_code', 'CLIENTE_NOT_FOUND', 'data', null);
    END IF;

    RETURN jsonb_build_object('success', true, 'message', 'Cliente obtenido exitosamente', 'data', v_data);
EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object('success', false, 'message', 'Error al obtener el cliente: ' || SQLERRM, 'error_code', SQLSTATE);
END;
$function$;

-- ---------------------------------------------------------------------------
-- LISTADO PAGINADO — sin los de la papelera
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ventas.fn_clientes_listar_paginado(
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
    v_offset := (GREATEST(p_page, 1) - 1) * p_per_page;
    v_filtro := NULLIF(TRIM(COALESCE(p_search, '')), '');

    SELECT COUNT(*) INTO v_total
      FROM ventas.clientes c
     WHERE c.deleted_at IS NULL
       AND (v_filtro IS NULL
        OR c.nombre_completo       ILIKE '%' || v_filtro || '%'
        OR c.razon_social          ILIKE '%' || v_filtro || '%'
        OR c.nombre_comercial      ILIKE '%' || v_filtro || '%'
        OR c.numero_identificacion ILIKE '%' || v_filtro || '%'
        OR c.email                 ILIKE '%' || v_filtro || '%'
        OR c.celular               ILIKE '%' || v_filtro || '%'
        OR c.telefono              ILIKE '%' || v_filtro || '%'
        OR c.id::text              ILIKE '%' || v_filtro || '%');

    SELECT COALESCE(jsonb_agg(
        jsonb_build_object(
            'id',                    t.id,
            'tipo_cliente',          t.tipo_cliente,
            'numero_identificacion', t.numero_identificacion,
            'tipo_identificacion',   t.tipo_identificacion,
            'razon_social',          t.razon_social,
            'nombre_comercial',      t.nombre_comercial,
            'nombres',               t.nombres,
            'apellidos',             t.apellidos,
            'nombre_completo',       t.nombre_completo,
            'email',                 t.email,
            'telefono',              t.telefono,
            'celular',               t.celular,
            'direccion',             t.direccion,
            'provincia',             t.provincia,
            'canton',                t.canton,
            'vendedor_id',           t.vendedor_id,
            'vendedor_nombre',       t.vendedor_nombre,
            'forma_pago',            t.forma_pago,
            'limite_credito',        t.limite_credito,
            'dias_credito',          t.dias_credito,
            'descuento',             t.descuento,
            'estado',                t.estado,
            'foto',                  t.foto,
            'activo',                t.activo,
            'created_by',            t.created_by,
            'updated_by',            t.updated_by,
            'created_at',            to_char(t.created_at, 'YYYY-MM-DD HH24:MI:SS'),
            'updated_at',            to_char(t.updated_at, 'YYYY-MM-DD HH24:MI:SS')
        ) ORDER BY t.id DESC
    ), '[]'::jsonb) INTO v_data
    FROM (
        SELECT c.*,
               (SELECT TRIM(COALESCE(e.nombres, '') || ' ' || COALESCE(e.apellidos, ''))
                  FROM rh.empleados e WHERE e.id = c.vendedor_id) AS vendedor_nombre
          FROM ventas.clientes c
         WHERE c.deleted_at IS NULL
           AND (v_filtro IS NULL
            OR c.nombre_completo       ILIKE '%' || v_filtro || '%'
            OR c.razon_social          ILIKE '%' || v_filtro || '%'
            OR c.nombre_comercial      ILIKE '%' || v_filtro || '%'
            OR c.numero_identificacion ILIKE '%' || v_filtro || '%'
            OR c.email                 ILIKE '%' || v_filtro || '%'
            OR c.celular               ILIKE '%' || v_filtro || '%'
            OR c.telefono              ILIKE '%' || v_filtro || '%'
            OR c.id::text              ILIKE '%' || v_filtro || '%')
         ORDER BY c.id DESC
         LIMIT p_per_page OFFSET v_offset
    ) t;

    RETURN jsonb_build_object(
        'data', v_data,
        'meta', jsonb_build_object(
            'total',        v_total,
            'per_page',     p_per_page,
            'current_page', GREATEST(p_page, 1),
            'last_page',    CASE WHEN v_total = 0 THEN 1 ELSE ceil(v_total::numeric / p_per_page) END
        )
    );
EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object('success', false, 'message', 'Error al listar clientes: ' || SQLERRM, 'error_code', SQLSTATE);
END;
$function$;

-- ---------------------------------------------------------------------------
-- LISTA SIMPLE — sin los de la papelera
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ventas.fn_clientes_listar(p_solo_activos boolean DEFAULT true)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
    v_data jsonb;
BEGIN
    SELECT COALESCE(jsonb_agg(
        jsonb_build_object(
            'id',                    c.id,
            'identificacion',        c.numero_identificacion,
            'numero_identificacion', c.numero_identificacion,
            'tipo_identificacion',   c.tipo_identificacion,
            'nombre_completo',       c.nombre_completo,
            'nombre',                COALESCE(c.nombres, c.razon_social),
            'apellido',              c.apellidos,
            'email',                 c.email,
            'telefono',              COALESCE(c.celular, c.telefono),
            'direccion',             c.direccion,
            'estado',                c.activo,
            'activo',                c.activo
        ) ORDER BY c.nombre_completo
    ), '[]'::jsonb) INTO v_data
    FROM ventas.clientes c
    WHERE c.deleted_at IS NULL
      AND (NOT p_solo_activos OR c.activo);

    RETURN jsonb_build_object('success', true, 'message', 'Clientes obtenidos exitosamente', 'data', v_data);
EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object('success', false, 'message', 'Error al listar clientes: ' || SQLERRM, 'error_code', SQLSTATE);
END;
$function$;

-- ---------------------------------------------------------------------------
-- VALIDACIONES — el duplicado que está en la papelera se avisa aparte
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ventas.fn_clientes_validar(
    p_id                    bigint,
    p_tipo_cliente          varchar,
    p_numero_identificacion varchar,
    p_razon_social          varchar,
    p_nombres               varchar,
    p_apellidos             varchar,
    p_email                 varchar,
    p_email_alterno         varchar,
    p_vendedor_id           bigint,
    p_limite_credito        numeric,
    p_dias_credito          integer,
    p_descuento             numeric
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
    v_en_papelera boolean;
BEGIN
    IF COALESCE(p_tipo_cliente, '') NOT IN ('PERSONA', 'EMPRESA') THEN
        RAISE EXCEPTION 'El tipo de cliente debe ser PERSONA o EMPRESA' USING ERRCODE = 'P0001';
    END IF;

    IF NULLIF(TRIM(COALESCE(p_numero_identificacion, '')), '') IS NULL THEN
        RAISE EXCEPTION 'El número de identificación es obligatorio' USING ERRCODE = 'P0001';
    END IF;

    IF p_tipo_cliente = 'EMPRESA' THEN
        IF length(TRIM(COALESCE(p_razon_social, ''))) < 2 THEN
            RAISE EXCEPTION 'La razón social es obligatoria (mínimo 2 caracteres)' USING ERRCODE = 'P0001';
        END IF;
    ELSE
        IF length(TRIM(COALESCE(p_nombres, ''))) < 2 THEN
            RAISE EXCEPTION 'Los nombres son obligatorios (mínimo 2 caracteres)' USING ERRCODE = 'P0001';
        END IF;
        IF length(TRIM(COALESCE(p_apellidos, ''))) < 2 THEN
            RAISE EXCEPTION 'Los apellidos son obligatorios (mínimo 2 caracteres)' USING ERRCODE = 'P0001';
        END IF;
    END IF;

    IF NULLIF(TRIM(COALESCE(p_email, '')), '') IS NOT NULL
       AND TRIM(p_email) !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' THEN
        RAISE EXCEPTION 'El correo electrónico no es válido' USING ERRCODE = 'P0003';
    END IF;

    IF NULLIF(TRIM(COALESCE(p_email_alterno, '')), '') IS NOT NULL
       AND TRIM(p_email_alterno) !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' THEN
        RAISE EXCEPTION 'El correo alterno no es válido' USING ERRCODE = 'P0003';
    END IF;

    -- El índice único cuenta también a los de la papelera, así que se distingue
    SELECT (deleted_at IS NOT NULL) INTO v_en_papelera
      FROM ventas.clientes
     WHERE UPPER(numero_identificacion) = UPPER(TRIM(p_numero_identificacion))
       AND (p_id IS NULL OR id <> p_id)
     LIMIT 1;

    IF FOUND THEN
        IF v_en_papelera THEN
            RAISE EXCEPTION 'Ya existe un cliente con esa identificación en la papelera de reciclaje. Restáurelo o elimínelo definitivamente.' USING ERRCODE = 'P0006';
        ELSE
            RAISE EXCEPTION 'Ya existe un cliente con esa identificación' USING ERRCODE = 'P0006';
        END IF;
    END IF;

    IF p_vendedor_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM rh.empleados WHERE id = p_vendedor_id) THEN
        RAISE EXCEPTION 'El vendedor asignado no existe' USING ERRCODE = 'P0016';
    END IF;

    IF COALESCE(p_limite_credito, 0) < 0 THEN
        RAISE EXCEPTION 'El límite de crédito no puede ser negativo' USING ERRCODE = 'P0015';
    END IF;
    IF COALESCE(p_dias_credito, 0) < 0 THEN
        RAISE EXCEPTION 'Los días de crédito no pueden ser negativos' USING ERRCODE = 'P0015';
    END IF;
    IF COALESCE(p_descuento, 0) < 0 OR COALESCE(p_descuento, 0) > 100 THEN
        RAISE EXCEPTION 'El descuento debe estar entre 0 y 100' USING ERRCODE = 'P0015';
    END IF;
END;
$function$;

-- ---------------------------------------------------------------------------
-- ELIMINAR — ahora manda a la papelera (borrado lógico)
-- Los contactos y las fotos NO se tocan: al restaurar tiene que quedar igual.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ventas.fn_clientes_eliminar(
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
SET search_path TO 'pg_catalog', 'ventas', 'rh', 'auditoria'
AS $function$
DECLARE
    v_actual record;
    v_antes  jsonb;
    v_fecha  timestamptz := CURRENT_TIMESTAMP;
BEGIN
    -- 1. Contexto de auditoría
    PERFORM set_config('app.usuario_id',     COALESCE(p_usuario_id::text, ''), true);
    PERFORM set_config('app.usuario_login',  COALESCE(p_usuario_login, current_user), true);
    PERFORM set_config('app.usuario_nombre', COALESCE(p_usuario_nombre, current_user), true);
    PERFORM set_config('app.ip_address',     COALESCE(p_ip_address::text, ''), true);
    PERFORM set_config('app.user_agent',     COALESCE(p_user_agent, ''), true);
    PERFORM set_config('app.request_id',     COALESCE(p_request_id::text, ''), true);
    PERFORM set_config('app.modulo',         'ventas.clientes', true);

    SELECT id, nombre_completo, deleted_at INTO v_actual FROM ventas.clientes WHERE id = p_id;
    IF NOT FOUND OR v_actual.deleted_at IS NOT NULL THEN
        RAISE EXCEPTION 'El cliente no existe' USING ERRCODE = 'P0013';
    END IF;

    v_antes := (ventas.fn_clientes_obtener(p_id))->'data';
    PERFORM set_config('app.datos_anteriores', v_antes::text, true);
    PERFORM set_config('app.datos_nuevos', (v_antes || jsonb_build_object(
        'deleted_at', to_char(v_fecha, 'YYYY-MM-DD HH24:MI:SS'), 'deleted_by', p_usuario_login
    ))::text, true);

    UPDATE ventas.clientes
       SET deleted_at = v_fecha,
           deleted_by = p_usuario_login,
           updated_by = COALESCE(p_usuario_login, updated_by),
           updated_at = v_fecha
     WHERE id = p_id;

    PERFORM set_config('app.datos_anteriores', '', true);
    PERFORM set_config('app.datos_nuevos', '', true);

    RETURN jsonb_build_object(
        'success', true,
        'message', format('Cliente «%s» enviado a la papelera de reciclaje', v_actual.nombre_completo),
        'data', (ventas.fn_clientes_obtener(p_id))->'data'
    );
END;
$function$;

-- ---------------------------------------------------------------------------
-- LO QUE HAY EN LA PAPELERA (más reciente primero)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ventas.fn_clientes_papelera_listar()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
    v_data jsonb;
BEGIN
    SELECT COALESCE(jsonb_agg((ventas.fn_clientes_obtener(c.id))->'data'
                              ORDER BY c.deleted_at DESC, c.id DESC), '[]'::jsonb)
      INTO v_data
      FROM ventas.clientes c
     WHERE c.deleted_at IS NOT NULL;

    RETURN jsonb_build_object('success', true, 'data', v_data, 'total', jsonb_array_length(v_data));
EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object('success', false, 'message', 'Error al listar la papelera: ' || SQLERRM, 'error_code', SQLSTATE);
END;
$function$;

-- ---------------------------------------------------------------------------
-- RESTAURAR (uno o varios)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ventas.fn_clientes_restaurar(
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
SET search_path TO 'pg_catalog', 'ventas', 'rh', 'auditoria'
AS $function$
DECLARE
    v_c       record;
    v_antes   jsonb;
    v_n       integer := 0;
    v_fecha   timestamptz := CURRENT_TIMESTAMP;
    v_nombres text[] := '{}';
BEGIN
    PERFORM set_config('app.usuario_id',     COALESCE(p_usuario_id::text, ''), true);
    PERFORM set_config('app.usuario_login',  COALESCE(p_usuario_login, current_user), true);
    PERFORM set_config('app.usuario_nombre', COALESCE(p_usuario_nombre, current_user), true);
    PERFORM set_config('app.ip_address',     COALESCE(p_ip_address::text, ''), true);
    PERFORM set_config('app.user_agent',     COALESCE(p_user_agent, ''), true);
    PERFORM set_config('app.request_id',     COALESCE(p_request_id::text, ''), true);
    PERFORM set_config('app.modulo',         'ventas.clientes', true);

    IF p_ids IS NULL OR jsonb_typeof(p_ids) <> 'array' OR jsonb_array_length(p_ids) = 0 THEN
        RAISE EXCEPTION 'No se indicó ningún cliente' USING ERRCODE = 'P0001';
    END IF;

    FOR v_c IN
        SELECT c.id, c.nombre_completo
          FROM ventas.clientes c
         WHERE c.id IN (SELECT (x)::bigint FROM jsonb_array_elements_text(p_ids) x)
           AND c.deleted_at IS NOT NULL
    LOOP
        v_antes := (ventas.fn_clientes_obtener(v_c.id))->'data';
        PERFORM set_config('app.datos_anteriores', v_antes::text, true);
        PERFORM set_config('app.datos_nuevos', (v_antes || jsonb_build_object('deleted_at', NULL, 'deleted_by', NULL))::text, true);

        UPDATE ventas.clientes
           SET deleted_at = NULL, deleted_by = NULL,
               updated_by = COALESCE(p_usuario_login, updated_by), updated_at = v_fecha
         WHERE id = v_c.id;

        v_n := v_n + 1;
        v_nombres := v_nombres || v_c.nombre_completo::text;
    END LOOP;

    PERFORM set_config('app.datos_anteriores', '', true);
    PERFORM set_config('app.datos_nuevos', '', true);

    IF v_n = 0 THEN
        RAISE EXCEPTION 'Ninguno de esos clientes está en la papelera' USING ERRCODE = 'P0019';
    END IF;

    RETURN jsonb_build_object(
        'success', true,
        'message', CASE WHEN v_n = 1 THEN format('Cliente «%s» restaurado', v_nombres[1]) ELSE format('%s clientes restaurados', v_n) END,
        'data', jsonb_build_object('restaurados', v_n, 'nombres', to_jsonb(v_nombres))
    );
END;
$function$;

-- ---------------------------------------------------------------------------
-- ELIMINAR DEFINITIVAMENTE (sólo lo que está en la papelera)
-- Devuelve los ficheros del cliente para que el back los quite del disco una
-- vez confirmada la transacción.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ventas.fn_clientes_eliminar_definitivo(
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
SET search_path TO 'pg_catalog', 'ventas', 'rh', 'auditoria'
AS $function$
DECLARE
    v_c        record;
    v_n        integer := 0;
    v_ficheros text[] := '{}';
    v_nombres  text[] := '{}';
BEGIN
    PERFORM set_config('app.usuario_id',     COALESCE(p_usuario_id::text, ''), true);
    PERFORM set_config('app.usuario_login',  COALESCE(p_usuario_login, current_user), true);
    PERFORM set_config('app.usuario_nombre', COALESCE(p_usuario_nombre, current_user), true);
    PERFORM set_config('app.ip_address',     COALESCE(p_ip_address::text, ''), true);
    PERFORM set_config('app.user_agent',     COALESCE(p_user_agent, ''), true);
    PERFORM set_config('app.request_id',     COALESCE(p_request_id::text, ''), true);
    PERFORM set_config('app.modulo',         'ventas.clientes', true);

    IF p_ids IS NULL OR jsonb_typeof(p_ids) <> 'array' OR jsonb_array_length(p_ids) = 0 THEN
        RAISE EXCEPTION 'No se indicó ningún cliente' USING ERRCODE = 'P0001';
    END IF;

    FOR v_c IN
        SELECT c.id, c.nombre_completo, c.foto, c.url_foto_mapa, c.url_foto_casa
          FROM ventas.clientes c
         WHERE c.id IN (SELECT (x)::bigint FROM jsonb_array_elements_text(p_ids) x)
           AND c.deleted_at IS NOT NULL      -- sólo lo que está en la papelera
    LOOP
        PERFORM set_config('app.datos_anteriores', ((ventas.fn_clientes_obtener(v_c.id))->'data')::text, true);

        -- Los contactos caen con el cliente (ON DELETE CASCADE)
        DELETE FROM ventas.clientes WHERE id = v_c.id;

        v_n := v_n + 1;
        v_nombres := v_nombres || v_c.nombre_completo::text;
        IF NULLIF(v_c.foto, '')          IS NOT NULL THEN v_ficheros := v_ficheros || v_c.foto::text; END IF;
        IF NULLIF(v_c.url_foto_mapa, '') IS NOT NULL THEN v_ficheros := v_ficheros || v_c.url_foto_mapa::text; END IF;
        IF NULLIF(v_c.url_foto_casa, '') IS NOT NULL THEN v_ficheros := v_ficheros || v_c.url_foto_casa::text; END IF;
    END LOOP;

    PERFORM set_config('app.datos_anteriores', '', true);

    IF v_n = 0 THEN
        RAISE EXCEPTION 'Ninguno de esos clientes está en la papelera' USING ERRCODE = 'P0019';
    END IF;

    RETURN jsonb_build_object(
        'success', true,
        'message', CASE WHEN v_n = 1 THEN format('Cliente «%s» eliminado definitivamente', v_nombres[1]) ELSE format('%s clientes eliminados definitivamente', v_n) END,
        'data', jsonb_build_object('borrados', v_n, 'nombres', to_jsonb(v_nombres), 'ficheros', to_jsonb(v_ficheros))
    );

EXCEPTION
    WHEN foreign_key_violation THEN
        RAISE EXCEPTION 'No se puede eliminar definitivamente: el cliente tiene registros asociados' USING ERRCODE = 'P0014';
END;
$function$;

-- ---------------------------------------------------------------------------
-- VACIAR LA PAPELERA
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ventas.fn_clientes_papelera_vaciar(
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
SET search_path TO 'pg_catalog', 'ventas', 'rh', 'auditoria'
AS $function$
DECLARE
    v_ids jsonb;
    v_res jsonb;
BEGIN
    SELECT COALESCE(jsonb_agg(c.id), '[]'::jsonb) INTO v_ids FROM ventas.clientes c WHERE c.deleted_at IS NOT NULL;

    IF jsonb_array_length(v_ids) = 0 THEN
        RETURN jsonb_build_object('success', true, 'message', 'La papelera ya estaba vacía',
                                  'data', jsonb_build_object('borrados', 0, 'nombres', '[]'::jsonb, 'ficheros', '[]'::jsonb));
    END IF;

    v_res := ventas.fn_clientes_eliminar_definitivo(v_ids, p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);
    RETURN v_res || jsonb_build_object('message', format('Papelera vaciada: %s cliente(s) eliminado(s) definitivamente', v_res->'data'->>'borrados'));
END;
$function$;

-- ---------------------------------------------------------------------------
-- PROPIETARIO Y COMENTARIOS
-- ---------------------------------------------------------------------------
ALTER FUNCTION ventas.fn_clientes_papelera_listar() OWNER TO postgres;
ALTER FUNCTION ventas.fn_clientes_restaurar(jsonb, bigint, varchar, varchar, inet, text, uuid) OWNER TO postgres;
ALTER FUNCTION ventas.fn_clientes_eliminar_definitivo(jsonb, bigint, varchar, varchar, inet, text, uuid) OWNER TO postgres;
ALTER FUNCTION ventas.fn_clientes_papelera_vaciar(bigint, varchar, varchar, inet, text, uuid) OWNER TO postgres;

COMMENT ON FUNCTION ventas.fn_clientes_eliminar(bigint, bigint, varchar, varchar, inet, text, uuid) IS 'Envía el cliente a la papelera de reciclaje (borrado lógico)';
COMMENT ON FUNCTION ventas.fn_clientes_papelera_listar() IS 'Clientes que están en la papelera de reciclaje';
COMMENT ON FUNCTION ventas.fn_clientes_restaurar(jsonb, bigint, varchar, varchar, inet, text, uuid) IS 'Saca de la papelera uno o varios clientes';
COMMENT ON FUNCTION ventas.fn_clientes_eliminar_definitivo(jsonb, bigint, varchar, varchar, inet, text, uuid) IS 'Borrado real de clientes que están en la papelera';
COMMENT ON FUNCTION ventas.fn_clientes_papelera_vaciar(bigint, varchar, varchar, inet, text, uuid) IS 'Borrado real de todo lo que hay en la papelera';
