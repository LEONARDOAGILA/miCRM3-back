-- ============================================================================
-- MARCACIONES DE EMPLEADOS (esquema rh): control de entradas y salidas, con
-- reconocimiento facial o a mano.
--
--   rh.marcaciones          cada entrada / salida registrada
--   rh.rostros_empleados    plantillas faciales (descriptores de 128 números)
--
--   rh.fn_marcaciones_registrar(...)        registra (tipo automático + anti-duplicado)
--   rh.fn_marcaciones_listar_paginado(...)  listado con filtros (grilla)
--   rh.fn_marcaciones_obtener(id)
--   rh.fn_marcaciones_modificar(...)        corregir hora / tipo / observación
--   rh.fn_marcaciones_eliminar(id, ...)
--   rh.fn_marcaciones_resumen(...)          horas trabajadas por empleado y día
--   rh.fn_rostros_listar(empleado_id)       plantillas para el kiosco
--   rh.fn_rostros_guardar(...)              añade muestras a un empleado
--   rh.fn_rostros_eliminar(...)             una muestra o todas las del empleado
--
-- Mismo esquema que el resto de rh: la lógica vive aquí, el contexto de
-- auditoría lo leen los triggers y las reglas de negocio se lanzan con
-- RAISE EXCEPTION + SQLSTATE propio para que el back las traduzca a 4xx:
--   P0001 datos obligatorios        P0013 el registro no existe
--   P0010 valor no admitido         P0020 marcación repetida (dentro de la espera)
--   P0021 el empleado está inactivo P0022 descriptor facial inválido
-- Idempotente: IF NOT EXISTS / CREATE OR REPLACE.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- TABLAS
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS rh.marcaciones (
    id           bigserial PRIMARY KEY,
    empleado_id  bigint       NOT NULL REFERENCES rh.empleados(id) ON DELETE CASCADE,
    tipo         varchar(10)  NOT NULL,
    fecha_hora   timestamptz  NOT NULL DEFAULT now(),
    /** Día al que pertenece la marcación (para agrupar y buscar sin depender de la zona) */
    fecha        date         NOT NULL,
    origen       varchar(10)  NOT NULL DEFAULT 'FACIAL',
    /** Parecido con la plantilla facial, 0..100 (null si fue a mano) */
    similitud    numeric(5,2),
    dispositivo  varchar(150),
    latitud      numeric(10,7),
    longitud     numeric(10,7),
    /** Nombre del fichero de la foto del momento (storage/img/marcaciones) */
    foto         varchar(255),
    observacion  text,
    created_at   timestamptz DEFAULT now(),
    updated_at   timestamptz DEFAULT now(),
    created_by   varchar,
    updated_by   varchar,
    CONSTRAINT ck_marcaciones_tipo   CHECK (tipo IN ('ENTRADA', 'SALIDA')),
    CONSTRAINT ck_marcaciones_origen CHECK (origen IN ('FACIAL', 'MANUAL', 'WEB', 'MOVIL'))
);

COMMENT ON TABLE  rh.marcaciones IS 'Entradas y salidas de los empleados (reconocimiento facial o registro manual)';
COMMENT ON COLUMN rh.marcaciones.similitud IS 'Parecido con la plantilla facial (0-100); null si se registró a mano';

CREATE INDEX IF NOT EXISTS ix_marcaciones_empleado_fecha ON rh.marcaciones (empleado_id, fecha DESC, fecha_hora DESC);
CREATE INDEX IF NOT EXISTS ix_marcaciones_fecha ON rh.marcaciones (fecha DESC);

CREATE TABLE IF NOT EXISTS rh.rostros_empleados (
    id          bigserial PRIMARY KEY,
    empleado_id bigint      NOT NULL REFERENCES rh.empleados(id) ON DELETE CASCADE,
    /** 128 números que describen el rostro (face-api.js) */
    descriptor  jsonb       NOT NULL,
    origen      varchar(10) NOT NULL DEFAULT 'CAMARA',
    activo      boolean     NOT NULL DEFAULT true,
    created_at  timestamptz DEFAULT now(),
    updated_at  timestamptz DEFAULT now(),
    created_by  varchar,
    updated_by  varchar,
    CONSTRAINT ck_rostros_origen CHECK (origen IN ('CAMARA', 'FOTO'))
);

COMMENT ON TABLE rh.rostros_empleados IS 'Plantillas faciales de los empleados: una fila por muestra capturada';
CREATE INDEX IF NOT EXISTS ix_rostros_empleado ON rh.rostros_empleados (empleado_id) WHERE activo;

-- Auditoría: los mismos tres triggers que el resto de rh
DO $bloque$
DECLARE t text;
BEGIN
    FOREACH t IN ARRAY ARRAY['marcaciones', 'rostros_empleados'] LOOP
        EXECUTE format('DROP TRIGGER IF EXISTS trg_%s_audit ON rh.%s', t, t);
        EXECUTE format('CREATE TRIGGER trg_%s_audit AFTER INSERT OR DELETE OR UPDATE ON rh.%s FOR EACH ROW EXECUTE FUNCTION auditoria.fn_auditar_cambios()', t, t);
        EXECUTE format('DROP TRIGGER IF EXISTS trigger_%s_set_users ON rh.%s', t, t);
        EXECUTE format('CREATE TRIGGER trigger_%s_set_users BEFORE INSERT OR UPDATE ON rh.%s FOR EACH ROW EXECUTE FUNCTION auditoria.fn_set_audit_users()', t, t);
        EXECUTE format('DROP TRIGGER IF EXISTS trigger_%s_updated_at ON rh.%s', t, t);
        EXECUTE format('CREATE TRIGGER trigger_%s_updated_at BEFORE UPDATE ON rh.%s FOR EACH ROW EXECUTE FUNCTION auditoria.fn_update_updated_at_column()', t, t);
    END LOOP;
END;
$bloque$;

-- ---------------------------------------------------------------------------
-- Contexto de auditoría (lo leen los triggers)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION rh.fn_contexto_auditoria(
    p_modulo text, p_usuario_id bigint, p_usuario_login varchar, p_usuario_nombre varchar,
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
    PERFORM set_config('app.modulo',         p_modulo, true);
END;
$function$;

-- ---------------------------------------------------------------------------
-- Una marcación en json (con los datos del empleado)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION rh.fn_marcaciones_json(p_id bigint)
RETURNS jsonb
LANGUAGE sql
STABLE
AS $function$
    SELECT jsonb_build_object(
        'id',                   m.id,
        'empleado_id',          m.empleado_id,
        'empleado',             TRIM(CONCAT_WS(' ', e.nombres, e.apellidos)),
        'identificacion',       e.numero_identificacion,
        'cargo',                c.nombre,
        'departamento',         d.nombre,
        'empleado_foto',        e.foto,
        'tipo',                 m.tipo,
        'fecha_hora',           to_char(m.fecha_hora, 'YYYY-MM-DD HH24:MI:SS'),
        'fecha',                to_char(m.fecha, 'YYYY-MM-DD'),
        'hora',                 to_char(m.fecha_hora, 'HH24:MI:SS'),
        'origen',               m.origen,
        'similitud',            m.similitud,
        'dispositivo',          m.dispositivo,
        'latitud',              m.latitud,
        'longitud',             m.longitud,
        'foto',                 m.foto,
        'observacion',          m.observacion,
        'created_by',           m.created_by,
        'updated_by',           m.updated_by,
        'created_at',           to_char(m.created_at, 'YYYY-MM-DD HH24:MI:SS'),
        'updated_at',           to_char(m.updated_at, 'YYYY-MM-DD HH24:MI:SS')
    )
    FROM rh.marcaciones m
    JOIN rh.empleados e      ON e.id = m.empleado_id
    LEFT JOIN rh.cargos c    ON c.id = e.cargo_id
    LEFT JOIN rh.departamentos d ON d.id = e.departamento_id
    WHERE m.id = p_id;
$function$;

-- ---------------------------------------------------------------------------
-- REGISTRAR una marcación.
--   p_tipo NULL  → se alterna con la última del día (primera = ENTRADA)
--   p_espera_segundos → si hay otra marcación suya dentro de ese margen, se
--                       rechaza (P0020) para no duplicar con la cámara
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION rh.fn_marcaciones_registrar(
    p_empleado_id     bigint,
    p_tipo            varchar DEFAULT NULL,
    p_origen          varchar DEFAULT 'FACIAL',
    p_similitud       numeric DEFAULT NULL,
    p_dispositivo     varchar DEFAULT NULL,
    p_latitud         numeric DEFAULT NULL,
    p_longitud        numeric DEFAULT NULL,
    p_foto            varchar DEFAULT NULL,
    p_observacion     text    DEFAULT NULL,
    p_fecha_hora      timestamptz DEFAULT NULL,
    p_espera_segundos integer DEFAULT 60,
    p_usuario_id      bigint  DEFAULT NULL,
    p_usuario_login   varchar DEFAULT NULL,
    p_usuario_nombre  varchar DEFAULT NULL,
    p_ip_address      inet    DEFAULT NULL,
    p_user_agent      text    DEFAULT NULL,
    p_request_id      uuid    DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'rh', 'auditoria'
AS $function$
DECLARE
    v_id        bigint;
    v_emp       record;
    v_fecha     timestamptz := COALESCE(p_fecha_hora, CURRENT_TIMESTAMP);
    v_dia       date;
    v_tipo      varchar(10);
    v_ultima    record;
    v_segundos  numeric;
BEGIN
    PERFORM rh.fn_contexto_auditoria('rh.marcaciones', p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);
    v_dia := v_fecha::date;

    -- 1. El empleado debe existir y estar activo
    SELECT id, activo, estado, TRIM(CONCAT_WS(' ', nombres, apellidos)) AS nombre
      INTO v_emp FROM rh.empleados WHERE id = p_empleado_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'El empleado no existe' USING ERRCODE = 'P0013';
    END IF;
    IF NOT v_emp.activo OR v_emp.estado IN ('INACTIVO', 'RETIRADO') THEN
        RAISE EXCEPTION 'El empleado «%» está inactivo: no puede marcar', v_emp.nombre USING ERRCODE = 'P0021';
    END IF;

    -- 2. Tipo: el que venga, o el contrario de la última del día
    IF p_tipo IS NOT NULL AND UPPER(p_tipo) NOT IN ('ENTRADA', 'SALIDA') THEN
        RAISE EXCEPTION 'El tipo de marcación debe ser ENTRADA o SALIDA' USING ERRCODE = 'P0010';
    END IF;
    IF p_origen IS NOT NULL AND UPPER(p_origen) NOT IN ('FACIAL', 'MANUAL', 'WEB', 'MOVIL') THEN
        RAISE EXCEPTION 'El origen no es válido' USING ERRCODE = 'P0010';
    END IF;

    SELECT tipo, fecha_hora INTO v_ultima
      FROM rh.marcaciones
     WHERE empleado_id = p_empleado_id AND fecha = v_dia
     ORDER BY fecha_hora DESC LIMIT 1;

    v_tipo := COALESCE(UPPER(p_tipo), CASE WHEN v_ultima.tipo = 'ENTRADA' THEN 'SALIDA' ELSE 'ENTRADA' END);

    -- 3. Anti-duplicado: nada de dos marcaciones seguidas en pocos segundos
    IF COALESCE(p_espera_segundos, 0) > 0 AND v_ultima.fecha_hora IS NOT NULL THEN
        v_segundos := EXTRACT(EPOCH FROM (v_fecha - v_ultima.fecha_hora));
        IF v_segundos < p_espera_segundos THEN
            RAISE EXCEPTION '«%» ya marcó hace % segundo(s); espere % segundos', v_emp.nombre, ROUND(v_segundos), p_espera_segundos
                USING ERRCODE = 'P0020';
        END IF;
    END IF;

    -- 4. Insertar (el trigger de auditoría graba el registro completo)
    INSERT INTO rh.marcaciones (empleado_id, tipo, fecha_hora, fecha, origen, similitud, dispositivo, latitud, longitud, foto, observacion, created_by, updated_by)
    VALUES (p_empleado_id, v_tipo, v_fecha, v_dia, COALESCE(UPPER(p_origen), 'FACIAL'),
            CASE WHEN p_similitud IS NULL THEN NULL ELSE ROUND(p_similitud, 2) END,
            NULLIF(TRIM(COALESCE(p_dispositivo, '')), ''), p_latitud, p_longitud,
            NULLIF(TRIM(COALESCE(p_foto, '')), ''), NULLIF(TRIM(COALESCE(p_observacion, '')), ''),
            p_usuario_login, p_usuario_login)
    RETURNING id INTO v_id;

    RETURN jsonb_build_object(
        'success', true,
        'message', format('%s de «%s» registrada a las %s', INITCAP(v_tipo), v_emp.nombre, to_char(v_fecha, 'HH24:MI:SS')),
        'data', rh.fn_marcaciones_json(v_id)
    );
END;
$function$;

-- ---------------------------------------------------------------------------
-- LISTADO PAGINADO con filtros (grilla)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION rh.fn_marcaciones_listar_paginado(
    p_page        integer DEFAULT 1,
    p_per_page    integer DEFAULT 15,
    p_search      text    DEFAULT '',
    p_desde       date    DEFAULT NULL,
    p_hasta       date    DEFAULT NULL,
    p_empleado_id bigint  DEFAULT NULL,
    p_tipo        varchar DEFAULT NULL,
    p_origen      varchar DEFAULT NULL
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

    CREATE TEMP TABLE IF NOT EXISTS tmp_marcaciones (id bigint) ON COMMIT DROP;
    DELETE FROM tmp_marcaciones;

    INSERT INTO tmp_marcaciones (id)
    SELECT m.id
      FROM rh.marcaciones m
      JOIN rh.empleados e ON e.id = m.empleado_id
     WHERE (p_desde IS NULL OR m.fecha >= p_desde)
       AND (p_hasta IS NULL OR m.fecha <= p_hasta)
       AND (p_empleado_id IS NULL OR m.empleado_id = p_empleado_id)
       AND (p_tipo IS NULL OR m.tipo = UPPER(p_tipo))
       AND (p_origen IS NULL OR m.origen = UPPER(p_origen))
       AND (v_filtro IS NULL
            OR e.nombres   ILIKE '%' || v_filtro || '%'
            OR e.apellidos ILIKE '%' || v_filtro || '%'
            OR e.numero_identificacion ILIKE '%' || v_filtro || '%'
            OR CONCAT_WS(' ', e.nombres, e.apellidos) ILIKE '%' || v_filtro || '%'
            OR m.observacion ILIKE '%' || v_filtro || '%');

    SELECT COUNT(*) INTO v_total FROM tmp_marcaciones;

    SELECT COALESCE(jsonb_agg(rh.fn_marcaciones_json(t.id) ORDER BY t.fecha_hora DESC, t.id DESC), '[]'::jsonb) INTO v_data
      FROM (
        SELECT m.id, m.fecha_hora
          FROM rh.marcaciones m
          JOIN tmp_marcaciones f ON f.id = m.id
         ORDER BY m.fecha_hora DESC, m.id DESC
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

-- ---------------------------------------------------------------------------
-- OBTENER
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION rh.fn_marcaciones_obtener(p_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
    v_data jsonb;
BEGIN
    v_data := rh.fn_marcaciones_json(p_id);
    IF v_data IS NULL THEN
        RETURN jsonb_build_object('success', false, 'message', 'Marcación no encontrada', 'data', null);
    END IF;
    RETURN jsonb_build_object('success', true, 'message', 'Marcación obtenida exitosamente', 'data', v_data);
END;
$function$;

-- ---------------------------------------------------------------------------
-- MODIFICAR (corregir tipo, fecha/hora u observación)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION rh.fn_marcaciones_modificar(
    p_id             bigint,
    p_tipo           varchar     DEFAULT NULL,
    p_fecha_hora     timestamptz DEFAULT NULL,
    p_observacion    text        DEFAULT NULL,
    p_usuario_id     bigint      DEFAULT NULL,
    p_usuario_login  varchar     DEFAULT NULL,
    p_usuario_nombre varchar     DEFAULT NULL,
    p_ip_address     inet        DEFAULT NULL,
    p_user_agent     text        DEFAULT NULL,
    p_request_id     uuid        DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'rh', 'auditoria'
AS $function$
DECLARE
    v_actual record;
    v_fecha  timestamptz;
    v_tipo   varchar(10);
BEGIN
    PERFORM rh.fn_contexto_auditoria('rh.marcaciones', p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    SELECT * INTO v_actual FROM rh.marcaciones WHERE id = p_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'La marcación no existe' USING ERRCODE = 'P0013';
    END IF;

    v_tipo  := COALESCE(UPPER(p_tipo), v_actual.tipo);
    v_fecha := COALESCE(p_fecha_hora, v_actual.fecha_hora);
    IF v_tipo NOT IN ('ENTRADA', 'SALIDA') THEN
        RAISE EXCEPTION 'El tipo de marcación debe ser ENTRADA o SALIDA' USING ERRCODE = 'P0010';
    END IF;

    PERFORM set_config('app.datos_anteriores', rh.fn_marcaciones_json(p_id)::text, true);

    UPDATE rh.marcaciones
       SET tipo        = v_tipo,
           fecha_hora  = v_fecha,
           fecha       = v_fecha::date,
           observacion = COALESCE(NULLIF(TRIM(COALESCE(p_observacion, '')), ''), observacion),
           updated_by  = COALESCE(p_usuario_login, updated_by),
           updated_at  = CURRENT_TIMESTAMP
     WHERE id = p_id;

    PERFORM set_config('app.datos_anteriores', '', true);

    RETURN jsonb_build_object('success', true, 'message', 'Marcación actualizada exitosamente', 'data', rh.fn_marcaciones_json(p_id));
END;
$function$;

-- ---------------------------------------------------------------------------
-- ELIMINAR
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION rh.fn_marcaciones_eliminar(
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
SET search_path TO 'pg_catalog', 'rh', 'auditoria'
AS $function$
DECLARE
    v_datos jsonb;
BEGIN
    PERFORM rh.fn_contexto_auditoria('rh.marcaciones', p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    v_datos := rh.fn_marcaciones_json(p_id);
    IF v_datos IS NULL THEN
        RAISE EXCEPTION 'La marcación no existe' USING ERRCODE = 'P0013';
    END IF;

    PERFORM set_config('app.datos_anteriores', v_datos::text, true);
    DELETE FROM rh.marcaciones WHERE id = p_id;
    PERFORM set_config('app.datos_anteriores', '', true);

    RETURN jsonb_build_object('success', true, 'message', 'Marcación eliminada exitosamente', 'data', v_datos);
END;
$function$;

-- ---------------------------------------------------------------------------
-- RESUMEN: por empleado y día, primera entrada, última salida y horas.
-- Las horas se calculan emparejando cada ENTRADA con la SALIDA siguiente.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION rh.fn_marcaciones_resumen(
    p_desde       date   DEFAULT NULL,
    p_hasta       date   DEFAULT NULL,
    p_empleado_id bigint DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
    v_desde date := COALESCE(p_desde, CURRENT_DATE);
    v_hasta date := COALESCE(p_hasta, CURRENT_DATE);
    v_data  jsonb;
    v_tot   jsonb;
BEGIN
    WITH base AS (
        SELECT m.*, LEAD(m.fecha_hora) OVER (PARTITION BY m.empleado_id, m.fecha ORDER BY m.fecha_hora) AS siguiente,
               LEAD(m.tipo) OVER (PARTITION BY m.empleado_id, m.fecha ORDER BY m.fecha_hora) AS tipo_siguiente
          FROM rh.marcaciones m
         WHERE m.fecha BETWEEN v_desde AND v_hasta
           AND (p_empleado_id IS NULL OR m.empleado_id = p_empleado_id)
    ),
    tramos AS (
        SELECT empleado_id, fecha,
               SUM(CASE WHEN tipo = 'ENTRADA' AND tipo_siguiente = 'SALIDA'
                        THEN EXTRACT(EPOCH FROM (siguiente - fecha_hora)) ELSE 0 END) AS segundos
          FROM base
         GROUP BY empleado_id, fecha
    ),
    dias AS (
        SELECT b.empleado_id, b.fecha,
               MIN(CASE WHEN b.tipo = 'ENTRADA' THEN b.fecha_hora END) AS primera_entrada,
               MAX(CASE WHEN b.tipo = 'SALIDA'  THEN b.fecha_hora END) AS ultima_salida,
               COUNT(*) AS marcaciones,
               COALESCE(MAX(t.segundos), 0) AS segundos
          FROM base b LEFT JOIN tramos t ON t.empleado_id = b.empleado_id AND t.fecha = b.fecha
         GROUP BY b.empleado_id, b.fecha
    )
    SELECT COALESCE(jsonb_agg(
        jsonb_build_object(
            'empleado_id',     d.empleado_id,
            'empleado',        TRIM(CONCAT_WS(' ', e.nombres, e.apellidos)),
            'identificacion',  e.numero_identificacion,
            'departamento',    dep.nombre,
            'fecha',           to_char(d.fecha, 'YYYY-MM-DD'),
            'primera_entrada', to_char(d.primera_entrada, 'HH24:MI:SS'),
            'ultima_salida',   to_char(d.ultima_salida, 'HH24:MI:SS'),
            'marcaciones',     d.marcaciones,
            'horas',           ROUND((d.segundos / 3600.0)::numeric, 2),
            'horas_texto',     to_char((d.segundos || ' seconds')::interval, 'HH24:MI'),
            'incompleto',      d.ultima_salida IS NULL OR d.primera_entrada IS NULL
        ) ORDER BY d.fecha DESC, e.apellidos, e.nombres
    ), '[]'::jsonb) INTO v_data
    FROM dias d
    JOIN rh.empleados e ON e.id = d.empleado_id
    LEFT JOIN rh.departamentos dep ON dep.id = e.departamento_id;

    SELECT jsonb_build_object(
        'empleados', COUNT(DISTINCT (x->>'empleado_id')),
        'dias',      COUNT(*),
        'horas',     ROUND(COALESCE(SUM((x->>'horas')::numeric), 0), 2)
    ) INTO v_tot
    FROM jsonb_array_elements(v_data) x;

    RETURN jsonb_build_object('success', true, 'data', v_data, 'totales', v_tot,
                              'desde', to_char(v_desde, 'YYYY-MM-DD'), 'hasta', to_char(v_hasta, 'YYYY-MM-DD'));
END;
$function$;

-- ===========================================================================
-- ROSTROS (plantillas faciales)
-- ===========================================================================

-- LISTAR: para el kiosco, los empleados activos con sus muestras
CREATE OR REPLACE FUNCTION rh.fn_rostros_listar(p_empleado_id bigint DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
    v_data jsonb;
BEGIN
    SELECT COALESCE(jsonb_agg(x ORDER BY x->>'empleado'), '[]'::jsonb) INTO v_data
    FROM (
        SELECT jsonb_build_object(
            'empleado_id',    e.id,
            'empleado',       TRIM(CONCAT_WS(' ', e.nombres, e.apellidos)),
            'identificacion', e.numero_identificacion,
            'cargo',          c.nombre,
            'departamento',   d.nombre,
            'foto',           e.foto,
            'activo',         e.activo,
            'muestras',       COALESCE(jsonb_agg(jsonb_build_object(
                                  'id', r.id, 'descriptor', r.descriptor, 'origen', r.origen,
                                  'created_at', to_char(r.created_at, 'YYYY-MM-DD HH24:MI:SS'), 'created_by', r.created_by
                              ) ORDER BY r.id) FILTER (WHERE r.id IS NOT NULL), '[]'::jsonb),
            'num_muestras',   COUNT(r.id)
        ) AS x
        FROM rh.empleados e
        LEFT JOIN rh.rostros_empleados r ON r.empleado_id = e.id AND r.activo
        LEFT JOIN rh.cargos c        ON c.id = e.cargo_id
        LEFT JOIN rh.departamentos d ON d.id = e.departamento_id
        WHERE (p_empleado_id IS NULL OR e.id = p_empleado_id)
          AND (p_empleado_id IS NOT NULL OR e.activo)
        GROUP BY e.id, c.nombre, d.nombre
        HAVING p_empleado_id IS NOT NULL OR COUNT(r.id) > 0
    ) s;

    RETURN jsonb_build_object('success', true, 'data', v_data,
                              'total', jsonb_array_length(v_data));
END;
$function$;

-- GUARDAR muestras (una o varias) de un empleado
CREATE OR REPLACE FUNCTION rh.fn_rostros_guardar(
    p_empleado_id    bigint,
    p_descriptores   jsonb,
    p_origen         varchar DEFAULT 'CAMARA',
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
SET search_path TO 'pg_catalog', 'rh', 'auditoria'
AS $function$
DECLARE
    v_emp    record;
    v_item   jsonb;
    v_n      integer := 0;
BEGIN
    PERFORM rh.fn_contexto_auditoria('rh.rostros_empleados', p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    SELECT id, TRIM(CONCAT_WS(' ', nombres, apellidos)) AS nombre INTO v_emp FROM rh.empleados WHERE id = p_empleado_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'El empleado no existe' USING ERRCODE = 'P0013';
    END IF;
    IF p_descriptores IS NULL OR jsonb_typeof(p_descriptores) <> 'array' OR jsonb_array_length(p_descriptores) = 0 THEN
        RAISE EXCEPTION 'No se recibió ninguna muestra facial' USING ERRCODE = 'P0001';
    END IF;
    IF COALESCE(UPPER(p_origen), 'CAMARA') NOT IN ('CAMARA', 'FOTO') THEN
        RAISE EXCEPTION 'El origen de la muestra debe ser CAMARA o FOTO' USING ERRCODE = 'P0010';
    END IF;

    FOR v_item IN SELECT * FROM jsonb_array_elements(p_descriptores) LOOP
        IF jsonb_typeof(v_item) <> 'array' OR jsonb_array_length(v_item) <> 128 THEN
            RAISE EXCEPTION 'Cada muestra facial debe tener 128 números' USING ERRCODE = 'P0022';
        END IF;
        INSERT INTO rh.rostros_empleados (empleado_id, descriptor, origen, created_by, updated_by)
        VALUES (p_empleado_id, v_item, COALESCE(UPPER(p_origen), 'CAMARA'), p_usuario_login, p_usuario_login);
        v_n := v_n + 1;
    END LOOP;

    RETURN jsonb_build_object(
        'success', true,
        'message', format('%s muestra(s) guardada(s) para «%s»', v_n, v_emp.nombre),
        'data', jsonb_build_object('empleado_id', p_empleado_id, 'guardadas', v_n,
                                   'total', (SELECT COUNT(*) FROM rh.rostros_empleados WHERE empleado_id = p_empleado_id AND activo))
    );
END;
$function$;

-- ELIMINAR: una muestra (p_id) o todas las del empleado (p_empleado_id)
CREATE OR REPLACE FUNCTION rh.fn_rostros_eliminar(
    p_id             bigint  DEFAULT NULL,
    p_empleado_id    bigint  DEFAULT NULL,
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
SET search_path TO 'pg_catalog', 'rh', 'auditoria'
AS $function$
DECLARE
    v_n integer;
BEGIN
    PERFORM rh.fn_contexto_auditoria('rh.rostros_empleados', p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    IF p_id IS NULL AND p_empleado_id IS NULL THEN
        RAISE EXCEPTION 'Indique la muestra o el empleado' USING ERRCODE = 'P0001';
    END IF;

    WITH borradas AS (
        DELETE FROM rh.rostros_empleados
         WHERE (p_id IS NOT NULL AND id = p_id)
            OR (p_id IS NULL AND empleado_id = p_empleado_id)
        RETURNING 1
    )
    SELECT COUNT(*) INTO v_n FROM borradas;

    IF v_n = 0 THEN
        RAISE EXCEPTION 'No se encontraron muestras para eliminar' USING ERRCODE = 'P0013';
    END IF;

    RETURN jsonb_build_object('success', true, 'message', format('%s muestra(s) eliminada(s)', v_n),
                              'data', jsonb_build_object('eliminadas', v_n));
END;
$function$;
