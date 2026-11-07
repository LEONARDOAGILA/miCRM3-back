-- ===========================================================================
-- EL CLIENTE APUNTA A SU GRUPO (ventas.clientes.grupo_cliente_id)
-- ===========================================================================
-- La columna ya existe (2026-10-25_ventas_grupos_clientes.sql). Esto es lo
-- que falta para poder asignarla desde la ficha:
--
--   · fn_clientes_obtener devuelve el grupo, su ruta y SUS CONDICIONES YA
--     RESUELTAS, que es lo que la ficha ofrece copiar en los cuatro campos;
--   · fn_clientes_crear y fn_clientes_modificar reciben p_grupo_cliente_id.
--
-- LO QUE NO CAMBIA: las cuatro condiciones del cliente. Siguen siendo suyas y
-- siguen mandando; el grupo es de dónde se copian al elegirlo, no algo que se
-- aplique por detrás. Así ningún cliente de hoy cambia de comportamiento.
\set ON_ERROR_STOP on

BEGIN;
-- ---------------------------------------------------------------------------
-- 1. LA FICHA
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
        -- El vendedor pasó a ser un USUARIO. La clave del json se mantiene
        -- para no tener que tocar las pantallas; lo que lleva dentro es el id
        -- del usuario. El empleado de antes se devuelve aparte por si hiciera
        -- falta rastrearlo.
        'vendedor_id',           c.vendedor_usuario_id,
        'vendedor_nombre',       ventas.fn_nombre_usuario(c.vendedor_usuario_id),
        'vendedor_empleado_id',  c.vendedor_id,
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
    )
    -- EL GRUPO COMERCIAL. `grupo_condiciones` son las del grupo ya resueltas
    -- (las suyas o las que hereda de más arriba): es lo que la ficha ofrece
    -- copiar en los cuatro campos del cliente, no algo que se aplique por
    -- detrás. Va en otro objeto porque jsonb_build_object no admite más de
    -- 100 argumentos y el de arriba ya iba al tope.
    || jsonb_build_object(
        'grupo_cliente_id',      c.grupo_cliente_id,
        'grupo_nombre',          (SELECT g.nombre FROM ventas.grupos_clientes g WHERE g.id = c.grupo_cliente_id),
        'grupo_ruta',            CASE WHEN c.grupo_cliente_id IS NULL THEN NULL
                                      ELSE (ventas.fn_grupos_clientes_json(c.grupo_cliente_id))->>'ruta' END,
        'grupo_activo',          (SELECT g.activo FROM ventas.grupos_clientes g WHERE g.id = c.grupo_cliente_id),
        'grupo_condiciones',     CASE WHEN c.grupo_cliente_id IS NULL THEN NULL
                                      ELSE ventas.fn_grupos_clientes_condiciones(c.grupo_cliente_id) END
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
$function$
;

-- ---------------------------------------------------------------------------
-- 2. ALTA Y MODIFICACIÓN
-- ---------------------------------------------------------------------------
-- Las de antes, con la lista de parámetros vieja. Hay que BORRARLAS: el
-- parámetro nuevo va en medio, y un CREATE OR REPLACE dejaría dos funciones
-- con el mismo nombre y las llamadas quedarían ambiguas.
DROP FUNCTION IF EXISTS ventas.fn_clientes_crear(
    character varying, character varying, character varying, character varying, character varying,
    character varying, character varying, character varying, character varying, character varying,
    character varying, character varying, date, character, text, bigint, character varying,
    numeric, integer, numeric, character varying, text, boolean,
    bigint, character varying, character varying, inet, text, uuid);

DROP FUNCTION IF EXISTS ventas.fn_clientes_modificar(
    bigint, character varying, character varying, character varying, character varying, character varying,
    character varying, character varying, character varying, character varying, character varying,
    character varying, character varying, date, character, text, bigint, character varying,
    numeric, integer, numeric, character varying, text, boolean,
    bigint, character varying, character varying, inet, text, uuid);

CREATE OR REPLACE FUNCTION ventas.fn_clientes_crear(p_tipo_cliente character varying, p_numero_identificacion character varying, p_tipo_identificacion character varying DEFAULT 'CC'::character varying, p_razon_social character varying DEFAULT NULL::character varying, p_nombre_comercial character varying DEFAULT NULL::character varying, p_nombres character varying DEFAULT NULL::character varying, p_apellidos character varying DEFAULT NULL::character varying, p_email character varying DEFAULT NULL::character varying, p_email_alterno character varying DEFAULT NULL::character varying, p_telefono character varying DEFAULT NULL::character varying, p_celular character varying DEFAULT NULL::character varying, p_sitio_web character varying DEFAULT NULL::character varying, p_fecha_nacimiento date DEFAULT NULL::date, p_genero character DEFAULT NULL::bpchar, p_direccion text DEFAULT NULL::text, p_vendedor_id bigint DEFAULT NULL::bigint, p_grupo_cliente_id bigint DEFAULT NULL::bigint, p_forma_pago character varying DEFAULT 'EFECTIVO'::character varying, p_limite_credito numeric DEFAULT 0, p_dias_credito integer DEFAULT 0, p_descuento numeric DEFAULT 0, p_estado character varying DEFAULT 'ACTIVO'::character varying, p_observaciones text DEFAULT NULL::text, p_activo boolean DEFAULT true, p_usuario_id bigint DEFAULT NULL::bigint, p_usuario_login character varying DEFAULT NULL::character varying, p_usuario_nombre character varying DEFAULT NULL::character varying, p_ip_address inet DEFAULT NULL::inet, p_user_agent text DEFAULT NULL::text, p_request_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'ventas', 'rh', 'auditoria'
AS $function$
DECLARE
    v_id           bigint;
    v_grupo_vive   boolean;
    v_fecha        timestamptz := CURRENT_TIMESTAMP;
    v_datos_nuevos jsonb;
BEGIN
    -- 1. Contexto de auditoría (lo leen los triggers de ventas.clientes)
    PERFORM set_config('app.usuario_id',     COALESCE(p_usuario_id::text, ''), true);
    PERFORM set_config('app.usuario_login',  COALESCE(p_usuario_login, current_user), true);
    PERFORM set_config('app.usuario_nombre', COALESCE(p_usuario_nombre, current_user), true);
    PERFORM set_config('app.ip_address',     COALESCE(p_ip_address::text, ''), true);
    PERFORM set_config('app.user_agent',     COALESCE(p_user_agent, ''), true);
    PERFORM set_config('app.request_id',     COALESCE(p_request_id::text, ''), true);
    PERFORM set_config('app.modulo',         'ventas.clientes', true);

    -- 2. Reglas
    PERFORM ventas.fn_clientes_validar(
        NULL, p_tipo_cliente, p_numero_identificacion, p_razon_social, p_nombres, p_apellidos,
        p_email, p_email_alterno, p_vendedor_id, p_limite_credito, p_dias_credito, p_descuento
    );

    -- El grupo tiene que existir y no estar en la papelera. INACTIVO SÍ se
    -- admite: si se desactiva un grupo que ya usan clientes, sus fichas
    -- tienen que poder seguir guardándose.
    IF p_grupo_cliente_id IS NOT NULL THEN
        SELECT (g.deleted_at IS NULL) INTO v_grupo_vive
          FROM ventas.grupos_clientes g WHERE g.id = p_grupo_cliente_id;
        IF v_grupo_vive IS NULL THEN
            RAISE EXCEPTION 'El grupo de clientes no existe' USING ERRCODE = 'P0016';
        END IF;
        IF NOT v_grupo_vive THEN
            RAISE EXCEPTION 'Ese grupo de clientes está en la papelera de reciclaje' USING ERRCODE = 'P0016';
        END IF;
    END IF;

    -- 3. Datos NUEVOS para la auditoría
    v_datos_nuevos := jsonb_build_object(
        'tipo_cliente',          p_tipo_cliente,
        'numero_identificacion', UPPER(TRIM(p_numero_identificacion)),
        'tipo_identificacion',   COALESCE(p_tipo_identificacion, 'CC'),
        'razon_social',          NULLIF(TRIM(COALESCE(p_razon_social, '')), ''),
        'nombre_comercial',      NULLIF(TRIM(COALESCE(p_nombre_comercial, '')), ''),
        'nombres',               NULLIF(TRIM(COALESCE(p_nombres, '')), ''),
        'apellidos',             NULLIF(TRIM(COALESCE(p_apellidos, '')), ''),
        'email',                 NULLIF(LOWER(TRIM(COALESCE(p_email, ''))), ''),
        'vendedor_id',           p_vendedor_id,
        'grupo_cliente_id',      p_grupo_cliente_id,
        'forma_pago',            COALESCE(p_forma_pago, 'EFECTIVO'),
        'limite_credito',        COALESCE(p_limite_credito, 0),
        'dias_credito',          COALESCE(p_dias_credito, 0),
        'descuento',             COALESCE(p_descuento, 0),
        'estado',                COALESCE(p_estado, 'ACTIVO'),
        'activo',                COALESCE(p_activo, true),
        'created_by',            p_usuario_login,
        'created_at',            to_char(v_fecha, 'YYYY-MM-DD HH24:MI:SS')
    );
    PERFORM set_config('app.datos_nuevos', v_datos_nuevos::text, true);

    -- 4. Insertar
    INSERT INTO ventas.clientes (
        tipo_cliente, numero_identificacion, tipo_identificacion,
        razon_social, nombre_comercial, nombres, apellidos,
        email, email_alterno, telefono, celular, sitio_web,
        fecha_nacimiento, genero, direccion,
        vendedor_usuario_id, grupo_cliente_id, forma_pago, limite_credito, dias_credito, descuento,
        estado, observaciones, activo,
        created_by, updated_by, created_at, updated_at
    ) VALUES (
        p_tipo_cliente,
        UPPER(TRIM(p_numero_identificacion)),
        COALESCE(NULLIF(TRIM(COALESCE(p_tipo_identificacion, '')), ''), 'CC'),
        NULLIF(TRIM(COALESCE(p_razon_social, '')), ''),
        NULLIF(TRIM(COALESCE(p_nombre_comercial, '')), ''),
        NULLIF(TRIM(COALESCE(p_nombres, '')), ''),
        NULLIF(TRIM(COALESCE(p_apellidos, '')), ''),
        NULLIF(LOWER(TRIM(COALESCE(p_email, ''))), ''),
        NULLIF(LOWER(TRIM(COALESCE(p_email_alterno, ''))), ''),
        NULLIF(TRIM(COALESCE(p_telefono, '')), ''),
        NULLIF(TRIM(COALESCE(p_celular, '')), ''),
        NULLIF(TRIM(COALESCE(p_sitio_web, '')), ''),
        p_fecha_nacimiento,
        NULLIF(TRIM(COALESCE(p_genero, '')), ''),
        NULLIF(TRIM(COALESCE(p_direccion, '')), ''),
        p_vendedor_id,
        p_grupo_cliente_id,
        COALESCE(NULLIF(TRIM(COALESCE(p_forma_pago, '')), ''), 'EFECTIVO'),
        COALESCE(p_limite_credito, 0),
        COALESCE(p_dias_credito, 0),
        COALESCE(p_descuento, 0),
        COALESCE(NULLIF(TRIM(COALESCE(p_estado, '')), ''), 'ACTIVO'),
        NULLIF(TRIM(COALESCE(p_observaciones, '')), ''),
        COALESCE(p_activo, true),
        p_usuario_login, p_usuario_login, v_fecha, v_fecha
    )
    RETURNING id INTO v_id;

    PERFORM set_config('app.datos_nuevos', '', true);

    RETURN jsonb_build_object(
        'success', true,
        'message', 'Cliente creado exitosamente',
        'data', (ventas.fn_clientes_obtener(v_id))->'data'
    );

EXCEPTION
    -- Único caso capturado, y se RE-LANZA: manda el índice único
    WHEN unique_violation THEN
        RAISE EXCEPTION 'Ya existe un cliente con esa identificación' USING ERRCODE = 'P0006';
END;
$function$
;

CREATE OR REPLACE FUNCTION ventas.fn_clientes_modificar(p_id bigint, p_tipo_cliente character varying, p_numero_identificacion character varying, p_tipo_identificacion character varying DEFAULT 'CC'::character varying, p_razon_social character varying DEFAULT NULL::character varying, p_nombre_comercial character varying DEFAULT NULL::character varying, p_nombres character varying DEFAULT NULL::character varying, p_apellidos character varying DEFAULT NULL::character varying, p_email character varying DEFAULT NULL::character varying, p_email_alterno character varying DEFAULT NULL::character varying, p_telefono character varying DEFAULT NULL::character varying, p_celular character varying DEFAULT NULL::character varying, p_sitio_web character varying DEFAULT NULL::character varying, p_fecha_nacimiento date DEFAULT NULL::date, p_genero character DEFAULT NULL::bpchar, p_direccion text DEFAULT NULL::text, p_vendedor_id bigint DEFAULT NULL::bigint, p_grupo_cliente_id bigint DEFAULT NULL::bigint, p_forma_pago character varying DEFAULT 'EFECTIVO'::character varying, p_limite_credito numeric DEFAULT 0, p_dias_credito integer DEFAULT 0, p_descuento numeric DEFAULT 0, p_estado character varying DEFAULT 'ACTIVO'::character varying, p_observaciones text DEFAULT NULL::text, p_activo boolean DEFAULT true, p_usuario_id bigint DEFAULT NULL::bigint, p_usuario_login character varying DEFAULT NULL::character varying, p_usuario_nombre character varying DEFAULT NULL::character varying, p_ip_address inet DEFAULT NULL::inet, p_user_agent text DEFAULT NULL::text, p_request_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'ventas', 'rh', 'auditoria'
AS $function$
DECLARE
    v_actual           ventas.clientes%ROWTYPE;
    v_fecha            timestamptz := CURRENT_TIMESTAMP;
    v_datos_anteriores jsonb;
    v_datos_nuevos     jsonb;
    v_grupo_vive       boolean;
BEGIN
    -- 1. Contexto de auditoría
    PERFORM set_config('app.usuario_id',     COALESCE(p_usuario_id::text, ''), true);
    PERFORM set_config('app.usuario_login',  COALESCE(p_usuario_login, current_user), true);
    PERFORM set_config('app.usuario_nombre', COALESCE(p_usuario_nombre, current_user), true);
    PERFORM set_config('app.ip_address',     COALESCE(p_ip_address::text, ''), true);
    PERFORM set_config('app.user_agent',     COALESCE(p_user_agent, ''), true);
    PERFORM set_config('app.request_id',     COALESCE(p_request_id::text, ''), true);
    PERFORM set_config('app.modulo',         'ventas.clientes', true);

    -- 2. Datos actuales
    SELECT * INTO v_actual FROM ventas.clientes WHERE id = p_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'El cliente no existe' USING ERRCODE = 'P0013';
    END IF;

    -- 3. Reglas
    PERFORM ventas.fn_clientes_validar(
        p_id, p_tipo_cliente, p_numero_identificacion, p_razon_social, p_nombres, p_apellidos,
        p_email, p_email_alterno, p_vendedor_id, p_limite_credito, p_dias_credito, p_descuento
    );

    -- El grupo tiene que existir y no estar en la papelera. INACTIVO SÍ se
    -- admite: si se desactiva un grupo que ya usan clientes, sus fichas
    -- tienen que poder seguir guardándose.
    IF p_grupo_cliente_id IS NOT NULL THEN
        SELECT (g.deleted_at IS NULL) INTO v_grupo_vive
          FROM ventas.grupos_clientes g WHERE g.id = p_grupo_cliente_id;
        IF v_grupo_vive IS NULL THEN
            RAISE EXCEPTION 'El grupo de clientes no existe' USING ERRCODE = 'P0016';
        END IF;
        IF NOT v_grupo_vive THEN
            RAISE EXCEPTION 'Ese grupo de clientes está en la papelera de reciclaje' USING ERRCODE = 'P0016';
        END IF;
    END IF;

    -- 4. Antes / después para la auditoría
    v_datos_anteriores := jsonb_build_object(
        'id', v_actual.id,
        'tipo_cliente', v_actual.tipo_cliente,
        'numero_identificacion', v_actual.numero_identificacion,
        'tipo_identificacion', v_actual.tipo_identificacion,
        'razon_social', v_actual.razon_social,
        'nombre_comercial', v_actual.nombre_comercial,
        'nombres', v_actual.nombres,
        'apellidos', v_actual.apellidos,
        'email', v_actual.email,
        'email_alterno', v_actual.email_alterno,
        'telefono', v_actual.telefono,
        'celular', v_actual.celular,
        'sitio_web', v_actual.sitio_web,
        'fecha_nacimiento', to_char(v_actual.fecha_nacimiento, 'YYYY-MM-DD'),
        'genero', v_actual.genero,
        'direccion', v_actual.direccion,
        'vendedor_id', v_actual.vendedor_usuario_id,
        'grupo_cliente_id', v_actual.grupo_cliente_id,
        'forma_pago', v_actual.forma_pago,
        'limite_credito', v_actual.limite_credito,
        'dias_credito', v_actual.dias_credito,
        'descuento', v_actual.descuento,
        'estado', v_actual.estado,
        'observaciones', v_actual.observaciones,
        'activo', v_actual.activo,
        'updated_by', v_actual.updated_by,
        'updated_at', to_char(v_actual.updated_at, 'YYYY-MM-DD HH24:MI:SS')
    );
    v_datos_nuevos := jsonb_build_object(
        'id', v_actual.id,
        'tipo_cliente', p_tipo_cliente,
        'numero_identificacion', UPPER(TRIM(p_numero_identificacion)),
        'tipo_identificacion', COALESCE(p_tipo_identificacion, 'CC'),
        'razon_social', NULLIF(TRIM(COALESCE(p_razon_social, '')), ''),
        'nombre_comercial', NULLIF(TRIM(COALESCE(p_nombre_comercial, '')), ''),
        'nombres', NULLIF(TRIM(COALESCE(p_nombres, '')), ''),
        'apellidos', NULLIF(TRIM(COALESCE(p_apellidos, '')), ''),
        'email', NULLIF(LOWER(TRIM(COALESCE(p_email, ''))), ''),
        'email_alterno', NULLIF(LOWER(TRIM(COALESCE(p_email_alterno, ''))), ''),
        'telefono', NULLIF(TRIM(COALESCE(p_telefono, '')), ''),
        'celular', NULLIF(TRIM(COALESCE(p_celular, '')), ''),
        'sitio_web', NULLIF(TRIM(COALESCE(p_sitio_web, '')), ''),
        'fecha_nacimiento', to_char(p_fecha_nacimiento, 'YYYY-MM-DD'),
        'genero', NULLIF(TRIM(COALESCE(p_genero, '')), ''),
        'direccion', NULLIF(TRIM(COALESCE(p_direccion, '')), ''),
        'vendedor_id', p_vendedor_id,
        'grupo_cliente_id', p_grupo_cliente_id,
        'forma_pago', COALESCE(p_forma_pago, 'EFECTIVO'),
        'limite_credito', COALESCE(p_limite_credito, 0),
        'dias_credito', COALESCE(p_dias_credito, 0),
        'descuento', COALESCE(p_descuento, 0),
        'estado', COALESCE(p_estado, 'ACTIVO'),
        'observaciones', NULLIF(TRIM(COALESCE(p_observaciones, '')), ''),
        'activo', COALESCE(p_activo, true),
        'updated_by', p_usuario_login,
        'updated_at', to_char(v_fecha, 'YYYY-MM-DD HH24:MI:SS')
    );
    PERFORM set_config('app.datos_anteriores', v_datos_anteriores::text, true);
    PERFORM set_config('app.datos_nuevos',     v_datos_nuevos::text, true);

    -- 5. Actualizar (la dirección del mapa y la foto van por sus propias funciones)
    UPDATE ventas.clientes
       SET tipo_cliente          = p_tipo_cliente,
           numero_identificacion = UPPER(TRIM(p_numero_identificacion)),
           tipo_identificacion   = COALESCE(NULLIF(TRIM(COALESCE(p_tipo_identificacion, '')), ''), 'CC'),
           razon_social          = NULLIF(TRIM(COALESCE(p_razon_social, '')), ''),
           nombre_comercial      = NULLIF(TRIM(COALESCE(p_nombre_comercial, '')), ''),
           nombres               = NULLIF(TRIM(COALESCE(p_nombres, '')), ''),
           apellidos             = NULLIF(TRIM(COALESCE(p_apellidos, '')), ''),
           email                 = NULLIF(LOWER(TRIM(COALESCE(p_email, ''))), ''),
           email_alterno         = NULLIF(LOWER(TRIM(COALESCE(p_email_alterno, ''))), ''),
           telefono              = NULLIF(TRIM(COALESCE(p_telefono, '')), ''),
           celular               = NULLIF(TRIM(COALESCE(p_celular, '')), ''),
           sitio_web             = NULLIF(TRIM(COALESCE(p_sitio_web, '')), ''),
           fecha_nacimiento      = p_fecha_nacimiento,
           genero                = NULLIF(TRIM(COALESCE(p_genero, '')), ''),
           direccion             = NULLIF(TRIM(COALESCE(p_direccion, '')), ''),
           vendedor_usuario_id   = p_vendedor_id,
           grupo_cliente_id      = p_grupo_cliente_id,
           forma_pago            = COALESCE(NULLIF(TRIM(COALESCE(p_forma_pago, '')), ''), 'EFECTIVO'),
           limite_credito        = COALESCE(p_limite_credito, 0),
           dias_credito          = COALESCE(p_dias_credito, 0),
           descuento             = COALESCE(p_descuento, 0),
           estado                = COALESCE(NULLIF(TRIM(COALESCE(p_estado, '')), ''), 'ACTIVO'),
           observaciones         = NULLIF(TRIM(COALESCE(p_observaciones, '')), ''),
           activo                = COALESCE(p_activo, true),
           updated_by            = p_usuario_login,
           updated_at            = v_fecha
     WHERE id = p_id;

    PERFORM set_config('app.datos_anteriores', '', true);
    PERFORM set_config('app.datos_nuevos', '', true);

    RETURN jsonb_build_object(
        'success', true,
        'message', 'Cliente actualizado exitosamente',
        'data', (ventas.fn_clientes_obtener(p_id))->'data'
    );

EXCEPTION
    WHEN unique_violation THEN
        RAISE EXCEPTION 'Ya existe otro cliente con esa identificación' USING ERRCODE = 'P0006';
END;
$function$
;

-- Los permisos, como los tenían las de antes
ALTER FUNCTION ventas.fn_clientes_crear(
    character varying, character varying, character varying, character varying, character varying,
    character varying, character varying, character varying, character varying, character varying,
    character varying, character varying, date, character, text, bigint, bigint, character varying,
    numeric, integer, numeric, character varying, text, boolean,
    bigint, character varying, character varying, inet, text, uuid) OWNER TO postgres;

ALTER FUNCTION ventas.fn_clientes_modificar(
    bigint, character varying, character varying, character varying, character varying, character varying,
    character varying, character varying, character varying, character varying, character varying,
    character varying, character varying, date, character, text, bigint, bigint, character varying,
    numeric, integer, numeric, character varying, text, boolean,
    bigint, character varying, character varying, inet, text, uuid) OWNER TO postgres;

COMMIT;
