-- ============================================================================
-- CLIENTES (esquema ventas) — tablas + CRUD en PL/pgSQL.
--
-- Mismo esquema que rh.fn_empleados_* / rh.fn_cargos_*: toda la lógica vive
-- aquí (validaciones, contexto de auditoría, transacción) y el controlador
-- sólo llama a la función y traduce el error.
--
--   ventas.fn_clientes_listar_paginado(page, per_page, search)  grilla
--   ventas.fn_clientes_listar(solo_activos)                     combos / selector
--   ventas.fn_clientes_obtener(id)                              un cliente
--   ventas.fn_clientes_crear(...)                               alta
--   ventas.fn_clientes_modificar(...)                           modificación
--   ventas.fn_clientes_eliminar(...)                            baja
--   ventas.fn_clientes_imagen(id, foto, …)                      foto del cliente
--   ventas.fn_clientes_ubicacion(id, jsonb, …)                  dirección del mapa
--   ventas.fn_clientes_foto_ubicacion(id, campo, archivo, …)    capturas del mapa
--   ventas.fn_contactos_clientes_listar(cliente_id)             contactos
--   ventas.fn_contactos_clientes_guardar(cliente_id, jsonb, …)  sincroniza contactos
--
-- Las tres triggers de auditoría son las mismas que usan las tablas de rh
-- (auditoria.fn_auditar_cambios, fn_set_audit_users, fn_update_updated_at_column):
-- las funciones dejan el contexto app.* y los datos_anteriores/datos_nuevos y
-- el trigger los graba en auditoria.logs_cambios.
--
-- Reglas de negocio con RAISE EXCEPTION y SQLSTATE propio, para que la
-- transacción aborte sola y el back lo traduzca a 4xx:
--   P0001 falta un dato obligatorio      P0002 prioridad de contacto inválida
--   P0003 correo con formato inválido    P0006 identificación duplicada
--   P0010 campo de foto inválido         P0013 el cliente no existe
--   P0014 tiene registros asociados      P0015 crédito o descuento inválido
--   P0016 el vendedor no existe
-- Idempotente: CREATE TABLE IF NOT EXISTS + CREATE OR REPLACE FUNCTION.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- TABLAS
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS ventas.clientes (
    id                      bigserial      NOT NULL,

    -- Identificación
    tipo_cliente            varchar(10)    NOT NULL DEFAULT 'PERSONA',   -- PERSONA | EMPRESA
    numero_identificacion   varchar(20)    NOT NULL,
    tipo_identificacion     varchar(10)    NOT NULL DEFAULT 'CC',        -- CC | RUC | PAS

    -- Quién es. En EMPRESA manda razón social; en PERSONA, nombres y apellidos.
    razon_social            varchar(200),
    nombre_comercial        varchar(200),
    nombres                 varchar(100),
    apellidos               varchar(100),
    -- Lo que se enseña en grillas y comprobantes; se calcula solo
    nombre_completo         varchar(250)   GENERATED ALWAYS AS (
        CASE WHEN tipo_cliente = 'EMPRESA'
             THEN COALESCE(NULLIF(TRIM(razon_social), ''), NULLIF(TRIM(nombre_comercial), ''), '')
             ELSE TRIM(COALESCE(nombres, '') || ' ' || COALESCE(apellidos, ''))
        END
    ) STORED,

    -- Contacto
    email                   varchar(150),
    email_alterno           varchar(150),
    telefono                varchar(20),
    celular                 varchar(20),
    sitio_web               varchar(200),
    fecha_nacimiento        date,
    genero                  char(1),

    -- Dirección: la escrita y la que trae Google Maps (igual que rh.empleados)
    direccion               text,
    provincia               varchar(100),
    canton                  varchar(100),
    parroquia               varchar(100),
    calle_principal         varchar(200),
    calle_secundaria        varchar(200),
    numeracion              varchar(50),
    ubicacion               text,
    codigo_postal           varchar(20),
    coordenadas             varchar(60),
    link_coordenadas        text,
    url_foto_mapa           varchar(255),
    url_foto_casa           varchar(255),

    -- Comercial
    vendedor_id             bigint,                                      -- rh.empleados
    forma_pago              varchar(20)    NOT NULL DEFAULT 'EFECTIVO',
    limite_credito          numeric(12,2)  NOT NULL DEFAULT 0,
    dias_credito            integer        NOT NULL DEFAULT 0,
    descuento               numeric(5,2)   NOT NULL DEFAULT 0,           -- % de descuento habitual
    estado                  varchar(20)             DEFAULT 'ACTIVO',
    observaciones           text,

    foto                    varchar(255),
    activo                  boolean                 DEFAULT true,

    created_at              timestamptz             DEFAULT CURRENT_TIMESTAMP,
    updated_at              timestamptz             DEFAULT CURRENT_TIMESTAMP,
    created_by              varchar(100),
    updated_by              varchar(100),

    CONSTRAINT pk_clientes PRIMARY KEY (id),
    CONSTRAINT uk_clientes_identificacion UNIQUE (numero_identificacion),

    CONSTRAINT ck_clientes_tipo_cliente CHECK (tipo_cliente IN ('PERSONA', 'EMPRESA')),
    CONSTRAINT ck_clientes_tipo_identificacion CHECK (tipo_identificacion IN ('CC', 'RUC', 'PAS')),
    CONSTRAINT ck_clientes_estado CHECK (estado IN ('ACTIVO', 'INACTIVO', 'SUSPENDIDO', 'MOROSO')),
    CONSTRAINT ck_clientes_forma_pago CHECK (forma_pago IN ('EFECTIVO', 'TRANSFERENCIA', 'TARJETA', 'CHEQUE', 'CREDITO')),
    CONSTRAINT ck_clientes_genero CHECK (genero IS NULL OR genero IN ('M', 'F', 'O')),
    CONSTRAINT ck_clientes_credito CHECK (limite_credito >= 0 AND dias_credito >= 0),
    CONSTRAINT ck_clientes_descuento CHECK (descuento >= 0 AND descuento <= 100),
    -- El nombre depende del tipo: sin esto una empresa podría quedarse sin razón social
    CONSTRAINT ck_clientes_nombre CHECK (
        (tipo_cliente = 'EMPRESA' AND length(TRIM(COALESCE(razon_social, ''))) >= 2)
        OR
        (tipo_cliente = 'PERSONA' AND length(TRIM(COALESCE(nombres, ''))) >= 2
                                  AND length(TRIM(COALESCE(apellidos, ''))) >= 2)
    ),
    CONSTRAINT fk_clientes_vendedor FOREIGN KEY (vendedor_id) REFERENCES rh.empleados(id)
);

CREATE INDEX IF NOT EXISTS idx_clientes_activo          ON ventas.clientes (activo) WHERE activo = true;
CREATE INDEX IF NOT EXISTS idx_clientes_estado          ON ventas.clientes (estado);
CREATE INDEX IF NOT EXISTS idx_clientes_identificacion  ON ventas.clientes (numero_identificacion);
CREATE INDEX IF NOT EXISTS idx_clientes_nombre_completo ON ventas.clientes (nombre_completo);
CREATE INDEX IF NOT EXISTS idx_clientes_vendedor        ON ventas.clientes (vendedor_id);

-- Personas de contacto dentro del cliente (mismo esquema que rh.contactos_emergencia)
CREATE TABLE IF NOT EXISTS ventas.contactos_clientes (
    id               bigserial     NOT NULL,
    cliente_id       bigint        NOT NULL,
    nombres          varchar(100)  NOT NULL,
    cargo            varchar(100),
    telefono         varchar(20)   NOT NULL,
    telefono_alterno varchar(20),
    email            varchar(150),
    prioridad        integer       NOT NULL DEFAULT 1,
    activo           boolean                DEFAULT true,
    created_at       timestamptz            DEFAULT CURRENT_TIMESTAMP,
    updated_at       timestamptz            DEFAULT CURRENT_TIMESTAMP,
    created_by       varchar(100),
    updated_by       varchar(100),

    CONSTRAINT pk_contactos_clientes PRIMARY KEY (id),
    CONSTRAINT ck_contactos_clientes_prioridad CHECK (prioridad >= 1),
    CONSTRAINT fk_contactos_clientes_cliente FOREIGN KEY (cliente_id)
        REFERENCES ventas.clientes (id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_contactos_clientes_cliente ON ventas.contactos_clientes (cliente_id);

-- ---------------------------------------------------------------------------
-- TRIGGERS DE AUDITORÍA (las mismas tres que llevan las tablas de rh)
-- DROP + CREATE porque CREATE TRIGGER no admite IF NOT EXISTS en PG < 14.
-- ---------------------------------------------------------------------------
DROP TRIGGER IF EXISTS trigger_clientes_set_users  ON ventas.clientes;
DROP TRIGGER IF EXISTS trigger_clientes_updated_at ON ventas.clientes;
DROP TRIGGER IF EXISTS trg_clientes_audit          ON ventas.clientes;

CREATE TRIGGER trigger_clientes_set_users
    BEFORE INSERT OR UPDATE ON ventas.clientes
    FOR EACH ROW EXECUTE FUNCTION auditoria.fn_set_audit_users();

CREATE TRIGGER trigger_clientes_updated_at
    BEFORE UPDATE ON ventas.clientes
    FOR EACH ROW EXECUTE FUNCTION auditoria.fn_update_updated_at_column();

CREATE TRIGGER trg_clientes_audit
    AFTER INSERT OR UPDATE OR DELETE ON ventas.clientes
    FOR EACH ROW EXECUTE FUNCTION auditoria.fn_auditar_cambios();

DROP TRIGGER IF EXISTS trigger_contactos_clientes_set_users  ON ventas.contactos_clientes;
DROP TRIGGER IF EXISTS trigger_contactos_clientes_updated_at ON ventas.contactos_clientes;
DROP TRIGGER IF EXISTS trg_contactos_clientes_audit          ON ventas.contactos_clientes;

CREATE TRIGGER trigger_contactos_clientes_set_users
    BEFORE INSERT OR UPDATE ON ventas.contactos_clientes
    FOR EACH ROW EXECUTE FUNCTION auditoria.fn_set_audit_users();

CREATE TRIGGER trigger_contactos_clientes_updated_at
    BEFORE UPDATE ON ventas.contactos_clientes
    FOR EACH ROW EXECUTE FUNCTION auditoria.fn_update_updated_at_column();

CREATE TRIGGER trg_contactos_clientes_audit
    AFTER INSERT OR UPDATE OR DELETE ON ventas.contactos_clientes
    FOR EACH ROW EXECUTE FUNCTION auditoria.fn_auditar_cambios();

-- ---------------------------------------------------------------------------
-- OBTENER UNO
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
-- LISTADO PAGINADO (grilla allClientes)
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
     WHERE v_filtro IS NULL
        OR c.nombre_completo       ILIKE '%' || v_filtro || '%'
        OR c.razon_social          ILIKE '%' || v_filtro || '%'
        OR c.nombre_comercial      ILIKE '%' || v_filtro || '%'
        OR c.numero_identificacion ILIKE '%' || v_filtro || '%'
        OR c.email                 ILIKE '%' || v_filtro || '%'
        OR c.celular               ILIKE '%' || v_filtro || '%'
        OR c.telefono              ILIKE '%' || v_filtro || '%'
        OR c.id::text              ILIKE '%' || v_filtro || '%';

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
         WHERE v_filtro IS NULL
            OR c.nombre_completo       ILIKE '%' || v_filtro || '%'
            OR c.razon_social          ILIKE '%' || v_filtro || '%'
            OR c.nombre_comercial      ILIKE '%' || v_filtro || '%'
            OR c.numero_identificacion ILIKE '%' || v_filtro || '%'
            OR c.email                 ILIKE '%' || v_filtro || '%'
            OR c.celular               ILIKE '%' || v_filtro || '%'
            OR c.telefono              ILIKE '%' || v_filtro || '%'
            OR c.id::text              ILIKE '%' || v_filtro || '%'
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
-- LISTA SIMPLE (combos y selector listClientes)
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
    WHERE NOT p_solo_activos OR c.activo;

    RETURN jsonb_build_object('success', true, 'message', 'Clientes obtenidos exitosamente', 'data', v_data);
EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object('success', false, 'message', 'Error al listar clientes: ' || SQLERRM, 'error_code', SQLSTATE);
END;
$function$;

-- ---------------------------------------------------------------------------
-- VALIDACIONES COMUNES A CREAR Y MODIFICAR
-- p_id: null al crear; el id propio al modificar (para excluirse del duplicado)
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

    IF EXISTS (SELECT 1 FROM ventas.clientes
                WHERE UPPER(numero_identificacion) = UPPER(TRIM(p_numero_identificacion))
                  AND (p_id IS NULL OR id <> p_id)) THEN
        RAISE EXCEPTION 'Ya existe un cliente con esa identificación' USING ERRCODE = 'P0006';
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
-- CREAR
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ventas.fn_clientes_crear(
    p_tipo_cliente          varchar,
    p_numero_identificacion varchar,
    p_tipo_identificacion   varchar DEFAULT 'CC',
    p_razon_social          varchar DEFAULT NULL,
    p_nombre_comercial      varchar DEFAULT NULL,
    p_nombres               varchar DEFAULT NULL,
    p_apellidos             varchar DEFAULT NULL,
    p_email                 varchar DEFAULT NULL,
    p_email_alterno         varchar DEFAULT NULL,
    p_telefono              varchar DEFAULT NULL,
    p_celular               varchar DEFAULT NULL,
    p_sitio_web             varchar DEFAULT NULL,
    p_fecha_nacimiento      date    DEFAULT NULL,
    p_genero                char    DEFAULT NULL,
    p_direccion             text    DEFAULT NULL,
    p_vendedor_id           bigint  DEFAULT NULL,
    p_forma_pago            varchar DEFAULT 'EFECTIVO',
    p_limite_credito        numeric DEFAULT 0,
    p_dias_credito          integer DEFAULT 0,
    p_descuento             numeric DEFAULT 0,
    p_estado                varchar DEFAULT 'ACTIVO',
    p_observaciones         text    DEFAULT NULL,
    p_activo                boolean DEFAULT true,
    p_usuario_id            bigint  DEFAULT NULL,
    p_usuario_login         varchar DEFAULT NULL,
    p_usuario_nombre        varchar DEFAULT NULL,
    p_ip_address            inet    DEFAULT NULL,
    p_user_agent            text    DEFAULT NULL,
    p_request_id            uuid    DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'ventas', 'rh', 'auditoria'
AS $function$
DECLARE
    v_id           bigint;
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
        vendedor_id, forma_pago, limite_credito, dias_credito, descuento,
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
$function$;

-- ---------------------------------------------------------------------------
-- MODIFICAR
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ventas.fn_clientes_modificar(
    p_id                    bigint,
    p_tipo_cliente          varchar,
    p_numero_identificacion varchar,
    p_tipo_identificacion   varchar DEFAULT 'CC',
    p_razon_social          varchar DEFAULT NULL,
    p_nombre_comercial      varchar DEFAULT NULL,
    p_nombres               varchar DEFAULT NULL,
    p_apellidos             varchar DEFAULT NULL,
    p_email                 varchar DEFAULT NULL,
    p_email_alterno         varchar DEFAULT NULL,
    p_telefono              varchar DEFAULT NULL,
    p_celular               varchar DEFAULT NULL,
    p_sitio_web             varchar DEFAULT NULL,
    p_fecha_nacimiento      date    DEFAULT NULL,
    p_genero                char    DEFAULT NULL,
    p_direccion             text    DEFAULT NULL,
    p_vendedor_id           bigint  DEFAULT NULL,
    p_forma_pago            varchar DEFAULT 'EFECTIVO',
    p_limite_credito        numeric DEFAULT 0,
    p_dias_credito          integer DEFAULT 0,
    p_descuento             numeric DEFAULT 0,
    p_estado                varchar DEFAULT 'ACTIVO',
    p_observaciones         text    DEFAULT NULL,
    p_activo                boolean DEFAULT true,
    p_usuario_id            bigint  DEFAULT NULL,
    p_usuario_login         varchar DEFAULT NULL,
    p_usuario_nombre        varchar DEFAULT NULL,
    p_ip_address            inet    DEFAULT NULL,
    p_user_agent            text    DEFAULT NULL,
    p_request_id            uuid    DEFAULT NULL
)
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
        'vendedor_id', v_actual.vendedor_id,
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
           vendedor_id           = p_vendedor_id,
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
$function$;

-- ---------------------------------------------------------------------------
-- ELIMINAR
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
    v_actual           ventas.clientes%ROWTYPE;
    v_datos_anteriores jsonb;
BEGIN
    -- 1. Contexto de auditoría
    PERFORM set_config('app.usuario_id',     COALESCE(p_usuario_id::text, ''), true);
    PERFORM set_config('app.usuario_login',  COALESCE(p_usuario_login, current_user), true);
    PERFORM set_config('app.usuario_nombre', COALESCE(p_usuario_nombre, current_user), true);
    PERFORM set_config('app.ip_address',     COALESCE(p_ip_address::text, ''), true);
    PERFORM set_config('app.user_agent',     COALESCE(p_user_agent, ''), true);
    PERFORM set_config('app.request_id',     COALESCE(p_request_id::text, ''), true);
    PERFORM set_config('app.modulo',         'ventas.clientes', true);

    SELECT * INTO v_actual FROM ventas.clientes WHERE id = p_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'El cliente no existe' USING ERRCODE = 'P0013';
    END IF;

    v_datos_anteriores := jsonb_build_object(
        'id', v_actual.id,
        'tipo_cliente', v_actual.tipo_cliente,
        'numero_identificacion', v_actual.numero_identificacion,
        'nombre_completo', v_actual.nombre_completo,
        'email', v_actual.email,
        'celular', v_actual.celular,
        'estado', v_actual.estado,
        'activo', v_actual.activo,
        'foto', v_actual.foto,
        'url_foto_mapa', v_actual.url_foto_mapa,
        'url_foto_casa', v_actual.url_foto_casa,
        'created_by', v_actual.created_by,
        'created_at', to_char(v_actual.created_at, 'YYYY-MM-DD HH24:MI:SS'),
        'updated_by', v_actual.updated_by,
        'updated_at', to_char(v_actual.updated_at, 'YYYY-MM-DD HH24:MI:SS')
    );
    PERFORM set_config('app.datos_anteriores', v_datos_anteriores::text, true);

    -- Los contactos caen con el cliente (ON DELETE CASCADE)
    DELETE FROM ventas.clientes WHERE id = p_id;

    PERFORM set_config('app.datos_anteriores', '', true);

    RETURN jsonb_build_object('success', true, 'message', 'Cliente eliminado exitosamente', 'data', v_datos_anteriores);

EXCEPTION
    WHEN foreign_key_violation THEN
        RAISE EXCEPTION 'No se puede eliminar el cliente porque tiene registros asociados. Desactívelo en su lugar.' USING ERRCODE = 'P0014';
END;
$function$;

-- ---------------------------------------------------------------------------
-- FOTO DEL CLIENTE
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ventas.fn_clientes_imagen(
    p_id             bigint,
    p_foto           varchar,
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
SET search_path TO 'pg_catalog', 'ventas', 'auditoria'
AS $function$
DECLARE
    v_anterior varchar;
BEGIN
    PERFORM set_config('app.usuario_id',     COALESCE(p_usuario_id::text, ''), true);
    PERFORM set_config('app.usuario_login',  COALESCE(p_usuario_login, current_user), true);
    PERFORM set_config('app.usuario_nombre', COALESCE(p_usuario_nombre, current_user), true);
    PERFORM set_config('app.ip_address',     COALESCE(p_ip_address::text, ''), true);
    PERFORM set_config('app.user_agent',     COALESCE(p_user_agent, ''), true);
    PERFORM set_config('app.request_id',     COALESCE(p_request_id::text, ''), true);
    PERFORM set_config('app.modulo',         'ventas.clientes', true);

    SELECT foto INTO v_anterior FROM ventas.clientes WHERE id = p_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'El cliente no existe' USING ERRCODE = 'P0013';
    END IF;

    PERFORM set_config('app.datos_anteriores', jsonb_build_object('id', p_id, 'foto', v_anterior)::text, true);
    PERFORM set_config('app.datos_nuevos',     jsonb_build_object('id', p_id, 'foto', p_foto)::text, true);

    UPDATE ventas.clientes
       SET foto = p_foto, updated_by = p_usuario_login, updated_at = CURRENT_TIMESTAMP
     WHERE id = p_id;

    PERFORM set_config('app.datos_anteriores', '', true);
    PERFORM set_config('app.datos_nuevos', '', true);

    RETURN jsonb_build_object('success', true, 'message', 'Foto guardada exitosamente',
                              'data', jsonb_build_object('id', p_id, 'foto', p_foto, 'foto_anterior', v_anterior));
END;
$function$;

-- ---------------------------------------------------------------------------
-- DIRECCIÓN QUE TRAE EL MAPA
-- Los diez campos llegan juntos de Google Maps y se pueden volver a tomar sin
-- tocar el resto de la ficha (igual que rh.fn_empleados_ubicacion).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ventas.fn_clientes_ubicacion(
    p_id             bigint,
    p_datos          jsonb,
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
SET search_path TO 'pg_catalog', 'ventas', 'auditoria'
AS $function$
BEGIN
    PERFORM set_config('app.usuario_id',     COALESCE(p_usuario_id::text, ''), true);
    PERFORM set_config('app.usuario_login',  COALESCE(p_usuario_login, current_user), true);
    PERFORM set_config('app.usuario_nombre', COALESCE(p_usuario_nombre, current_user), true);
    PERFORM set_config('app.ip_address',     COALESCE(p_ip_address::text, ''), true);
    PERFORM set_config('app.user_agent',     COALESCE(p_user_agent, ''), true);
    PERFORM set_config('app.request_id',     COALESCE(p_request_id::text, ''), true);
    PERFORM set_config('app.modulo',         'ventas.clientes', true);

    IF NOT EXISTS (SELECT 1 FROM ventas.clientes WHERE id = p_id) THEN
        RAISE EXCEPTION 'El cliente no existe' USING ERRCODE = 'P0013';
    END IF;

    -- Un campo que viene vacío se borra; uno que no viene se deja como estaba
    UPDATE ventas.clientes SET
        provincia        = COALESCE(NULLIF(TRIM(p_datos->>'provincia'), ''),        CASE WHEN p_datos ? 'provincia'        THEN NULL ELSE provincia        END),
        canton           = COALESCE(NULLIF(TRIM(p_datos->>'canton'), ''),           CASE WHEN p_datos ? 'canton'           THEN NULL ELSE canton           END),
        parroquia        = COALESCE(NULLIF(TRIM(p_datos->>'parroquia'), ''),        CASE WHEN p_datos ? 'parroquia'        THEN NULL ELSE parroquia        END),
        calle_principal  = COALESCE(NULLIF(TRIM(p_datos->>'calle_principal'), ''),  CASE WHEN p_datos ? 'calle_principal'  THEN NULL ELSE calle_principal  END),
        calle_secundaria = COALESCE(NULLIF(TRIM(p_datos->>'calle_secundaria'), ''), CASE WHEN p_datos ? 'calle_secundaria' THEN NULL ELSE calle_secundaria END),
        numeracion       = COALESCE(NULLIF(TRIM(p_datos->>'numeracion'), ''),       CASE WHEN p_datos ? 'numeracion'       THEN NULL ELSE numeracion       END),
        ubicacion        = COALESCE(NULLIF(TRIM(p_datos->>'ubicacion'), ''),        CASE WHEN p_datos ? 'ubicacion'        THEN NULL ELSE ubicacion        END),
        codigo_postal    = COALESCE(NULLIF(TRIM(p_datos->>'codigo_postal'), ''),    CASE WHEN p_datos ? 'codigo_postal'    THEN NULL ELSE codigo_postal    END),
        coordenadas      = COALESCE(NULLIF(TRIM(p_datos->>'coordenadas'), ''),      CASE WHEN p_datos ? 'coordenadas'      THEN NULL ELSE coordenadas      END),
        link_coordenadas = COALESCE(NULLIF(TRIM(p_datos->>'link_coordenadas'), ''), CASE WHEN p_datos ? 'link_coordenadas' THEN NULL ELSE link_coordenadas END),
        updated_by       = COALESCE(p_usuario_login, updated_by),
        updated_at       = CURRENT_TIMESTAMP
    WHERE id = p_id;

    RETURN jsonb_build_object('success', true, 'message', 'Ubicación guardada',
                              'data', (ventas.fn_clientes_obtener(p_id))->'data');
END;
$function$;

-- ---------------------------------------------------------------------------
-- LAS DOS CAPTURAS DEL MAPA (vista de arriba y de la calle)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ventas.fn_clientes_foto_ubicacion(
    p_id             bigint,
    p_campo          text,                -- 'mapa' | 'casa'
    p_archivo        varchar,
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
SET search_path TO 'pg_catalog', 'ventas', 'auditoria'
AS $function$
BEGIN
    PERFORM set_config('app.usuario_id',     COALESCE(p_usuario_id::text, ''), true);
    PERFORM set_config('app.usuario_login',  COALESCE(p_usuario_login, current_user), true);
    PERFORM set_config('app.usuario_nombre', COALESCE(p_usuario_nombre, current_user), true);
    PERFORM set_config('app.ip_address',     COALESCE(p_ip_address::text, ''), true);
    PERFORM set_config('app.user_agent',     COALESCE(p_user_agent, ''), true);
    PERFORM set_config('app.request_id',     COALESCE(p_request_id::text, ''), true);
    PERFORM set_config('app.modulo',         'ventas.clientes', true);

    IF p_campo NOT IN ('mapa', 'casa') THEN
        RAISE EXCEPTION 'La foto debe ser «mapa» o «casa»' USING ERRCODE = 'P0010';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM ventas.clientes WHERE id = p_id) THEN
        RAISE EXCEPTION 'El cliente no existe' USING ERRCODE = 'P0013';
    END IF;

    IF p_campo = 'mapa' THEN
        UPDATE ventas.clientes
           SET url_foto_mapa = NULLIF(TRIM(COALESCE(p_archivo, '')), ''),
               updated_by = COALESCE(p_usuario_login, updated_by), updated_at = CURRENT_TIMESTAMP
         WHERE id = p_id;
    ELSE
        UPDATE ventas.clientes
           SET url_foto_casa = NULLIF(TRIM(COALESCE(p_archivo, '')), ''),
               updated_by = COALESCE(p_usuario_login, updated_by), updated_at = CURRENT_TIMESTAMP
         WHERE id = p_id;
    END IF;

    RETURN jsonb_build_object('success', true, 'message', 'Foto guardada',
                              'data', (ventas.fn_clientes_obtener(p_id))->'data');
END;
$function$;

-- ---------------------------------------------------------------------------
-- CONTACTOS DEL CLIENTE
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ventas.fn_contactos_clientes_listar(p_cliente_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
    v_data jsonb;
BEGIN
    SELECT COALESCE(jsonb_agg(
        jsonb_build_object(
            'id',               c.id,
            'cliente_id',       c.cliente_id,
            'nombres',          c.nombres,
            'cargo',            c.cargo,
            'telefono',         c.telefono,
            'telefono_alterno', c.telefono_alterno,
            'email',            c.email,
            'prioridad',        c.prioridad,
            'activo',           c.activo,
            'created_by',       c.created_by,
            'updated_by',       c.updated_by,
            'created_at',       to_char(c.created_at, 'YYYY-MM-DD HH24:MI:SS'),
            'updated_at',       to_char(c.updated_at, 'YYYY-MM-DD HH24:MI:SS')
        ) ORDER BY c.prioridad, c.id
    ), '[]'::jsonb) INTO v_data
    FROM ventas.contactos_clientes c
    WHERE c.cliente_id = p_cliente_id;

    RETURN jsonb_build_object('success', true, 'message', 'Contactos obtenidos exitosamente', 'data', v_data);
EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object('success', false, 'message', 'Error al listar contactos: ' || SQLERRM, 'error_code', SQLSTATE);
END;
$function$;

/**
 * Sincroniza la lista completa que manda la grilla del formulario: los que
 * traen id se actualizan, los que no lo traen se insertan y los que ya no
 * vienen se eliminan.
 */
CREATE OR REPLACE FUNCTION ventas.fn_contactos_clientes_guardar(
    p_cliente_id     bigint,
    p_contactos      jsonb,               -- [{id?, nombres, cargo?, telefono, telefono_alterno?, email?, prioridad?, activo?}, …]
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
SET search_path TO 'pg_catalog', 'ventas', 'auditoria'
AS $function$
DECLARE
    v_c          jsonb;
    v_id         bigint;
    v_ids        bigint[] := ARRAY[]::bigint[];
    v_fecha      timestamptz := CURRENT_TIMESTAMP;
    v_insertados integer := 0;
    v_editados   integer := 0;
    v_borrados   integer := 0;
    v_prioridad  integer;
BEGIN
    PERFORM set_config('app.usuario_id',     COALESCE(p_usuario_id::text, ''), true);
    PERFORM set_config('app.usuario_login',  COALESCE(p_usuario_login, current_user), true);
    PERFORM set_config('app.usuario_nombre', COALESCE(p_usuario_nombre, current_user), true);
    PERFORM set_config('app.ip_address',     COALESCE(p_ip_address::text, ''), true);
    PERFORM set_config('app.user_agent',     COALESCE(p_user_agent, ''), true);
    PERFORM set_config('app.request_id',     COALESCE(p_request_id::text, ''), true);
    PERFORM set_config('app.modulo',         'ventas.contactos_clientes', true);

    IF NOT EXISTS (SELECT 1 FROM ventas.clientes WHERE id = p_cliente_id) THEN
        RAISE EXCEPTION 'El cliente no existe' USING ERRCODE = 'P0013';
    END IF;

    FOR v_c IN SELECT * FROM jsonb_array_elements(COALESCE(p_contactos, '[]'::jsonb)) LOOP
        IF NULLIF(TRIM(COALESCE(v_c->>'nombres', '')), '') IS NULL
           OR NULLIF(TRIM(COALESCE(v_c->>'telefono', '')), '') IS NULL THEN
            RAISE EXCEPTION 'Cada contacto necesita nombres y teléfono' USING ERRCODE = 'P0001';
        END IF;
        v_prioridad := COALESCE(NULLIF(v_c->>'prioridad', '')::integer, 1);
        IF v_prioridad < 1 THEN
            RAISE EXCEPTION 'La prioridad debe ser 1 o mayor' USING ERRCODE = 'P0002';
        END IF;

        v_id := NULLIF(v_c->>'id', '')::bigint;

        IF v_id IS NOT NULL AND EXISTS (SELECT 1 FROM ventas.contactos_clientes WHERE id = v_id AND cliente_id = p_cliente_id) THEN
            UPDATE ventas.contactos_clientes
               SET nombres          = TRIM(v_c->>'nombres'),
                   cargo            = NULLIF(TRIM(COALESCE(v_c->>'cargo', '')), ''),
                   telefono         = TRIM(v_c->>'telefono'),
                   telefono_alterno = NULLIF(TRIM(COALESCE(v_c->>'telefono_alterno', '')), ''),
                   email            = NULLIF(LOWER(TRIM(COALESCE(v_c->>'email', ''))), ''),
                   prioridad        = v_prioridad,
                   activo           = COALESCE((v_c->>'activo')::boolean, true),
                   updated_by       = p_usuario_login,
                   updated_at       = v_fecha
             WHERE id = v_id
               AND (nombres, COALESCE(cargo, ''), telefono, COALESCE(telefono_alterno, ''), COALESCE(email, ''), prioridad, activo)
                   IS DISTINCT FROM
                   (TRIM(v_c->>'nombres'),
                    COALESCE(NULLIF(TRIM(COALESCE(v_c->>'cargo', '')), ''), ''),
                    TRIM(v_c->>'telefono'),
                    COALESCE(NULLIF(TRIM(COALESCE(v_c->>'telefono_alterno', '')), ''), ''),
                    COALESCE(NULLIF(LOWER(TRIM(COALESCE(v_c->>'email', ''))), ''), ''),
                    v_prioridad, COALESCE((v_c->>'activo')::boolean, true));
            IF FOUND THEN v_editados := v_editados + 1; END IF;
        ELSE
            INSERT INTO ventas.contactos_clientes (cliente_id, nombres, cargo, telefono, telefono_alterno, email, prioridad, activo,
                                                   created_by, updated_by, created_at, updated_at)
            VALUES (p_cliente_id, TRIM(v_c->>'nombres'),
                    NULLIF(TRIM(COALESCE(v_c->>'cargo', '')), ''),
                    TRIM(v_c->>'telefono'),
                    NULLIF(TRIM(COALESCE(v_c->>'telefono_alterno', '')), ''),
                    NULLIF(LOWER(TRIM(COALESCE(v_c->>'email', ''))), ''),
                    v_prioridad, COALESCE((v_c->>'activo')::boolean, true),
                    p_usuario_login, p_usuario_login, v_fecha, v_fecha)
            RETURNING id INTO v_id;
            v_insertados := v_insertados + 1;
        END IF;
        v_ids := array_append(v_ids, v_id);
    END LOOP;

    -- Los que ya no vienen en la lista
    DELETE FROM ventas.contactos_clientes
     WHERE cliente_id = p_cliente_id
       AND NOT (id = ANY (v_ids));
    GET DIAGNOSTICS v_borrados = ROW_COUNT;

    RETURN jsonb_build_object(
        'success', true,
        'message', format('Contactos guardados: %s nuevo(s), %s modificado(s), %s eliminado(s)', v_insertados, v_editados, v_borrados),
        'data', (ventas.fn_contactos_clientes_listar(p_cliente_id))->'data'
    );
END;
$function$;

-- ---------------------------------------------------------------------------
-- PROPIETARIO Y COMENTARIOS
-- ---------------------------------------------------------------------------
ALTER TABLE ventas.clientes            OWNER TO postgres;
ALTER TABLE ventas.contactos_clientes  OWNER TO postgres;

ALTER FUNCTION ventas.fn_clientes_obtener(bigint) OWNER TO postgres;
ALTER FUNCTION ventas.fn_clientes_listar_paginado(integer, integer, text) OWNER TO postgres;
ALTER FUNCTION ventas.fn_clientes_listar(boolean) OWNER TO postgres;
ALTER FUNCTION ventas.fn_clientes_validar(bigint, varchar, varchar, varchar, varchar, varchar, varchar, varchar, bigint, numeric, integer, numeric) OWNER TO postgres;
ALTER FUNCTION ventas.fn_clientes_crear(varchar, varchar, varchar, varchar, varchar, varchar, varchar, varchar, varchar, varchar, varchar, varchar, date, char, text, bigint, varchar, numeric, integer, numeric, varchar, text, boolean, bigint, varchar, varchar, inet, text, uuid) OWNER TO postgres;
ALTER FUNCTION ventas.fn_clientes_modificar(bigint, varchar, varchar, varchar, varchar, varchar, varchar, varchar, varchar, varchar, varchar, varchar, varchar, date, char, text, bigint, varchar, numeric, integer, numeric, varchar, text, boolean, bigint, varchar, varchar, inet, text, uuid) OWNER TO postgres;
ALTER FUNCTION ventas.fn_clientes_eliminar(bigint, bigint, varchar, varchar, inet, text, uuid) OWNER TO postgres;
ALTER FUNCTION ventas.fn_clientes_imagen(bigint, varchar, bigint, varchar, varchar, inet, text, uuid) OWNER TO postgres;
ALTER FUNCTION ventas.fn_clientes_ubicacion(bigint, jsonb, bigint, varchar, varchar, inet, text, uuid) OWNER TO postgres;
ALTER FUNCTION ventas.fn_clientes_foto_ubicacion(bigint, text, varchar, bigint, varchar, varchar, inet, text, uuid) OWNER TO postgres;
ALTER FUNCTION ventas.fn_contactos_clientes_listar(bigint) OWNER TO postgres;
ALTER FUNCTION ventas.fn_contactos_clientes_guardar(bigint, jsonb, bigint, varchar, varchar, inet, text, uuid) OWNER TO postgres;

COMMENT ON TABLE ventas.clientes           IS 'Clientes del módulo de ventas, con dirección de Google Maps y datos comerciales';
COMMENT ON TABLE ventas.contactos_clientes IS 'Personas de contacto de cada cliente';
COMMENT ON FUNCTION ventas.fn_clientes_listar_paginado(integer, integer, text) IS 'Clientes paginados con filtro (grilla allClientes)';
COMMENT ON FUNCTION ventas.fn_clientes_listar(boolean) IS 'Lista simple de clientes para combos y selectores';
COMMENT ON FUNCTION ventas.fn_clientes_obtener(bigint) IS 'Un cliente por id';
