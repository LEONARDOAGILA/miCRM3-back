-- ===========================================================================
-- LO QUE EL SRI SABE DE UN CLIENTE (ventas.clientes_sri)
-- ===========================================================================
-- La ficha ya consulta el RUC al SRI para traer la razón social, pero lo
-- demás —estado del contribuyente, régimen, si está obligado a llevar
-- contabilidad, el representante legal— se perdía al cerrar el modal. Y hace
-- falta: el régimen y «obligado a llevar contabilidad» se imprimen en la
-- factura electrónica, y el estado dice si a ese RUC se le puede facturar.
--
-- POR QUÉ EN SU PROPIA TABLA Y NO EN COLUMNAS DE ventas.clientes:
--
--   · son DIECIOCHO datos y ventas.clientes ya tiene 24 parámetros en
--     fn_clientes_crear; meterlos ahí dejaría una función de cuarenta
--     parámetros posicionales, que es una trampa para el que venga después;
--   · no son datos del cliente, son UNA FOTO DE LO QUE DIJO EL SRI un día:
--     por eso llevan `consultado_at` y se vuelven a pedir cuando hace falta;
--   · un cliente sin RUC —una persona con cédula— simplemente no tiene fila.
--
-- Se guarda también el JSON entero (`datos`): si mañana el SRI añade un
-- campo, está ahí sin tener que migrar nada.
\set ON_ERROR_STOP on

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. LA TABLA
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS ventas.clientes_sri (
    /* El `id` no es un capricho: auditoria.fn_auditar_cambios() guarda
       NEW.id en cada cambio, así que toda tabla auditada tiene que tenerlo.
       La clave de verdad es cliente_id, que va UNIQUE: una foto por cliente. */
    id           bigserial    PRIMARY KEY,
    cliente_id   bigint       NOT NULL UNIQUE REFERENCES ventas.clientes(id) ON DELETE CASCADE,

    ruc          varchar(13)  NOT NULL,
    razon_social varchar(300),

    /* ---- LO QUE DECIDE SI SE LE FACTURA ---- */
    estado             varchar(20),     -- ACTIVO · SUSPENDIDO · PASIVO
    motivo_suspension  varchar(200),
    fantasma           boolean NOT NULL DEFAULT false,
    transacciones_inexistentes boolean NOT NULL DEFAULT false,

    /* ---- LO QUE VA EN LA FACTURA ELECTRÓNICA ---- */
    tipo_contribuyente     varchar(50),  -- SOCIEDAD · PERSONA NATURAL
    regimen                varchar(50),  -- GENERAL · RIMPE
    categoria              varchar(50),  -- NEGOCIO POPULAR, cuando es RIMPE
    obligado_contabilidad  boolean NOT NULL DEFAULT false,
    agente_retencion       boolean NOT NULL DEFAULT false,
    contribuyente_especial boolean NOT NULL DEFAULT false,

    actividad    text,

    fecha_inicio             date,
    fecha_cese               date,
    fecha_actualizacion_sri  date,

    /* ---- QUIÉN FIRMA POR LA EMPRESA ---- */
    representante_identificacion varchar(20),
    representante_nombre         varchar(200),

    /* La respuesta entera, por si mañana hace falta algo que hoy no se usa */
    datos        jsonb,

    /** Cuándo se le preguntó al SRI: esto es una foto, no la verdad de hoy */
    consultado_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,

    created_at   timestamptz  NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at   timestamptz  NOT NULL DEFAULT CURRENT_TIMESTAMP,
    created_by   varchar(100),
    updated_by   varchar(100)
);

COMMENT ON TABLE  ventas.clientes_sri IS 'Foto de lo que el SRI devolvió para el RUC de un cliente; se refresca al consultar';
COMMENT ON COLUMN ventas.clientes_sri.datos IS 'La respuesta completa del SRI, por si hace falta algo que hoy no se guarda aparte';
COMMENT ON COLUMN ventas.clientes_sri.consultado_at IS 'Cuándo se preguntó: el estado de un RUC cambia con el tiempo';

CREATE INDEX IF NOT EXISTS ix_clientes_sri_ruc    ON ventas.clientes_sri (ruc);
CREATE INDEX IF NOT EXISTS ix_clientes_sri_estado ON ventas.clientes_sri (estado);

DROP TRIGGER IF EXISTS trigger_clientes_sri_set_users  ON ventas.clientes_sri;
DROP TRIGGER IF EXISTS trigger_clientes_sri_updated_at ON ventas.clientes_sri;
DROP TRIGGER IF EXISTS trg_clientes_sri_audit          ON ventas.clientes_sri;

CREATE TRIGGER trigger_clientes_sri_set_users
    BEFORE INSERT OR UPDATE ON ventas.clientes_sri
    FOR EACH ROW EXECUTE FUNCTION auditoria.fn_set_audit_users();
CREATE TRIGGER trigger_clientes_sri_updated_at
    BEFORE UPDATE ON ventas.clientes_sri
    FOR EACH ROW EXECUTE FUNCTION auditoria.fn_update_updated_at_column();
CREATE TRIGGER trg_clientes_sri_audit
    AFTER INSERT OR UPDATE OR DELETE ON ventas.clientes_sri
    FOR EACH ROW EXECUTE FUNCTION auditoria.fn_auditar_cambios();

-- ---------------------------------------------------------------------------
-- 2. GUARDAR LA FOTO
-- ---------------------------------------------------------------------------
-- Recibe el JSON tal como lo deja el servicio del back (ya con nombres de
-- aquí) y lo escribe entero: si ya había una foto, se reemplaza. No se
-- acumulan versiones a propósito —para eso está la auditoría, que guarda el
-- antes y el después de cada cambio—.
CREATE OR REPLACE FUNCTION ventas.fn_clientes_sri_guardar(
    p_cliente_id bigint,
    p_datos jsonb,
    p_usuario_id bigint DEFAULT NULL::bigint,
    p_usuario_login character varying DEFAULT NULL::character varying,
    p_usuario_nombre character varying DEFAULT NULL::character varying,
    p_ip_address inet DEFAULT NULL::inet,
    p_user_agent text DEFAULT NULL::text,
    p_request_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'ventas', 'auditoria'
AS $function$
DECLARE
    v_existe boolean;
    v_ruc    varchar(13);
    v_rep    jsonb;
BEGIN
    PERFORM ventas.fn_contexto_auditoria('ventas.clientes_sri',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    SELECT true INTO v_existe FROM ventas.clientes WHERE id = p_cliente_id AND deleted_at IS NULL;
    IF v_existe IS NULL THEN
        RAISE EXCEPTION 'El cliente no existe' USING ERRCODE = 'P0013';
    END IF;

    v_ruc := NULLIF(TRIM(COALESCE(p_datos->>'ruc', '')), '');
    IF v_ruc IS NULL THEN
        RAISE EXCEPTION 'No vino el RUC consultado' USING ERRCODE = 'P0001';
    END IF;

    -- El primero: las sociedades suelen tener uno y es el que firma
    v_rep := CASE WHEN jsonb_typeof(p_datos->'representantes') = 'array'
                  THEN p_datos->'representantes'->0 END;

    INSERT INTO ventas.clientes_sri (
        cliente_id, ruc, razon_social, estado, motivo_suspension,
        fantasma, transacciones_inexistentes,
        tipo_contribuyente, regimen, categoria,
        obligado_contabilidad, agente_retencion, contribuyente_especial,
        actividad, fecha_inicio, fecha_cese, fecha_actualizacion_sri,
        representante_identificacion, representante_nombre,
        datos, consultado_at
    ) VALUES (
        p_cliente_id, v_ruc,
        NULLIF(TRIM(COALESCE(p_datos->>'razon_social', '')), ''),
        NULLIF(TRIM(COALESCE(p_datos->>'estado', '')), ''),
        NULLIF(TRIM(COALESCE(p_datos->>'motivo_suspension', '')), ''),
        COALESCE((p_datos->>'fantasma')::boolean, false),
        COALESCE((p_datos->>'transacciones_inexistentes')::boolean, false),
        NULLIF(TRIM(COALESCE(p_datos->>'tipo_contribuyente', '')), ''),
        NULLIF(TRIM(COALESCE(p_datos->>'regimen', '')), ''),
        NULLIF(TRIM(COALESCE(p_datos->>'categoria', '')), ''),
        COALESCE((p_datos->>'obligado_contabilidad')::boolean, false),
        COALESCE((p_datos->>'agente_retencion')::boolean, false),
        COALESCE((p_datos->>'contribuyente_especial')::boolean, false),
        NULLIF(TRIM(COALESCE(p_datos->>'actividad', '')), ''),
        NULLIF(p_datos->>'fecha_inicio', '')::date,
        NULLIF(p_datos->>'fecha_cese', '')::date,
        NULLIF(p_datos->>'fecha_actualizacion', '')::date,
        NULLIF(TRIM(COALESCE(v_rep->>'identificacion', '')), ''),
        NULLIF(TRIM(COALESCE(v_rep->>'nombre', '')), ''),
        p_datos, CURRENT_TIMESTAMP
    )
    ON CONFLICT (cliente_id) DO UPDATE SET
        ruc = EXCLUDED.ruc,
        razon_social = EXCLUDED.razon_social,
        estado = EXCLUDED.estado,
        motivo_suspension = EXCLUDED.motivo_suspension,
        fantasma = EXCLUDED.fantasma,
        transacciones_inexistentes = EXCLUDED.transacciones_inexistentes,
        tipo_contribuyente = EXCLUDED.tipo_contribuyente,
        regimen = EXCLUDED.regimen,
        categoria = EXCLUDED.categoria,
        obligado_contabilidad = EXCLUDED.obligado_contabilidad,
        agente_retencion = EXCLUDED.agente_retencion,
        contribuyente_especial = EXCLUDED.contribuyente_especial,
        actividad = EXCLUDED.actividad,
        fecha_inicio = EXCLUDED.fecha_inicio,
        fecha_cese = EXCLUDED.fecha_cese,
        fecha_actualizacion_sri = EXCLUDED.fecha_actualizacion_sri,
        representante_identificacion = EXCLUDED.representante_identificacion,
        representante_nombre = EXCLUDED.representante_nombre,
        datos = EXCLUDED.datos,
        consultado_at = EXCLUDED.consultado_at;

    RETURN jsonb_build_object('success', true, 'message', 'Datos del SRI guardados',
                              'data', ventas.fn_clientes_sri_json(p_cliente_id));
END;
$function$;

-- ---------------------------------------------------------------------------
-- 3. LA FOTO, COMO LA LEE LA PANTALLA
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ventas.fn_clientes_sri_json(p_cliente_id bigint)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
AS $function$
    SELECT jsonb_build_object(
        'ruc',                 s.ruc,
        'razon_social',        s.razon_social,
        'estado',              s.estado,
        'activo',              s.estado = 'ACTIVO',
        'motivo_suspension',   s.motivo_suspension,
        'fantasma',            s.fantasma,
        'transacciones_inexistentes', s.transacciones_inexistentes,
        'tipo_contribuyente',  s.tipo_contribuyente,
        'regimen',             s.regimen,
        'categoria',           s.categoria,
        'obligado_contabilidad',  s.obligado_contabilidad,
        'agente_retencion',       s.agente_retencion,
        'contribuyente_especial', s.contribuyente_especial,
        'actividad',           s.actividad,
        'fecha_inicio',        to_char(s.fecha_inicio, 'YYYY-MM-DD'),
        'fecha_cese',          to_char(s.fecha_cese, 'YYYY-MM-DD'),
        'fecha_actualizacion', to_char(s.fecha_actualizacion_sri, 'YYYY-MM-DD'),
        'representante_identificacion', s.representante_identificacion,
        'representante_nombre',         s.representante_nombre,
        'consultado_at',       to_char(s.consultado_at, 'YYYY-MM-DD HH24:MI:SS'),
        'consultado_por',      s.updated_by
    )
      FROM ventas.clientes_sri s
     WHERE s.cliente_id = p_cliente_id;
$function$;

-- ---------------------------------------------------------------------------
-- 4. Y LA FICHA DEL CLIENTE LA DEVUELVE
-- ---------------------------------------------------------------------------
-- Una clave más en el mismo objeto donde ya va el grupo comercial. Va en
-- ese segundo `jsonb_build_object` y no en el primero porque aquél está al
-- tope: la función no admite más de 100 argumentos.
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
        ,
        -- LO QUE DIJO EL SRI DE SU RUC, si se consultó alguna vez. Es una
        -- foto con fecha, no la verdad de hoy: por eso lleva dentro
        -- `consultado_at` y la pantalla ofrece volver a preguntar.
        'sri',                   ventas.fn_clientes_sri_json(c.id)
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

COMMIT;
