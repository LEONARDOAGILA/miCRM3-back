-- ===========================================================================
-- DÓNDE SE REGISTRÓ CADA MARCACIÓN
-- ===========================================================================
-- Fecha: 2026-10-19
--
-- Las columnas `latitud` y `longitud` ya existían en rh.marcaciones pero
-- nadie las llenaba (27 marcaciones, 0 con coordenadas): el kiosco no pedía
-- la ubicación. Ahora la piden las dos pantallas —el kiosco de la puerta y
-- «Registro de marcaciones», que el empleado abre en su celular— y hace
-- falta además el enlace para abrir el punto en un mapa.
--
-- EL ENLACE SE ARMA AQUÍ, no lo manda el navegador: así siempre apunta a las
-- coordenadas que de verdad se guardaron. El formato es el mismo que usan
-- las fichas de empleados y clientes (`link_coordenadas`).
--
-- Se guarda también la PRECISIÓN que declara el GPS: en un celular dentro de
-- un edificio pueden ser 2.000 metros, y sin ese dato un punto a dos cuadras
-- parece una mentira cuando es sólo mala señal.
-- ===========================================================================

ALTER TABLE rh.marcaciones
    ADD COLUMN IF NOT EXISTS link_ubicacion text,
    ADD COLUMN IF NOT EXISTS precision_m    numeric(10, 2);

COMMENT ON COLUMN rh.marcaciones.link_ubicacion
IS 'Enlace a Google Maps del punto donde se registró. Lo arma fn_marcaciones_registrar con la latitud y la longitud.';

COMMENT ON COLUMN rh.marcaciones.precision_m
IS 'Error que declaró el GPS, en metros. Grande = la ubicación es orientativa.';

-- ---------------------------------------------------------------------------
-- LA FICHA JSON: salen las coordenadas, el enlace y la precisión
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
        -- Dónde fue: el enlace para abrirlo en el mapa y con cuánto error
        'link_ubicacion',       m.link_ubicacion,
        'precision_m',          m.precision_m,
        'coordenadas',          CASE WHEN m.latitud IS NULL OR m.longitud IS NULL THEN NULL
                                     ELSE to_char(m.latitud, 'FM999990.000000') || ', ' ||
                                          to_char(m.longitud, 'FM999990.000000') END,
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
-- REGISTRAR: guarda la ubicación y arma el enlace
-- ---------------------------------------------------------------------------
-- La firma crece por el final (p_precision_m detrás de p_espera_segundos),
-- antes de los seis de auditoría: hay que borrar la anterior porque los
-- parámetros de auditoría se corren de sitio.
DROP FUNCTION IF EXISTS rh.fn_marcaciones_registrar(
    bigint, character varying, character varying, numeric, character varying,
    numeric, numeric, character varying, text, timestamp with time zone, integer,
    bigint, character varying, character varying, inet, text, uuid);

CREATE OR REPLACE FUNCTION rh.fn_marcaciones_registrar(
    p_empleado_id     bigint,
    p_tipo            varchar     DEFAULT NULL,
    p_origen          varchar     DEFAULT 'FACIAL',
    p_similitud       numeric     DEFAULT NULL,
    p_dispositivo     varchar     DEFAULT NULL,
    p_latitud         numeric     DEFAULT NULL,
    p_longitud        numeric     DEFAULT NULL,
    p_foto            varchar     DEFAULT NULL,
    p_observacion     text        DEFAULT NULL,
    p_fecha_hora      timestamptz DEFAULT NULL,
    p_espera_segundos integer     DEFAULT 60,
    p_precision_m     numeric     DEFAULT NULL,
    p_usuario_id      bigint      DEFAULT NULL,
    p_usuario_login   varchar     DEFAULT NULL,
    p_usuario_nombre  varchar     DEFAULT NULL,
    p_ip_address      inet        DEFAULT NULL,
    p_user_agent      text        DEFAULT NULL,
    p_request_id      uuid        DEFAULT NULL
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
    v_lat       numeric;
    v_lng       numeric;
    v_link      text;
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

    -- 4. La ubicación. Las dos coordenadas o ninguna: media coordenada no
    --    sitúa nada, y un punto fuera del mundo es un dato roto.
    IF p_latitud IS NOT NULL AND p_longitud IS NOT NULL
       AND p_latitud BETWEEN -90 AND 90 AND p_longitud BETWEEN -180 AND 180 THEN
        v_lat  := ROUND(p_latitud, 6);
        v_lng  := ROUND(p_longitud, 6);
        -- El mismo formato que las fichas de empleados y clientes
        v_link := 'https://www.google.com/maps/search/?api=1&query='
                  || to_char(v_lat, 'FM999990.000000') || ',' || to_char(v_lng, 'FM999990.000000');
    END IF;

    -- 5. Insertar (el trigger de auditoría graba el registro completo)
    INSERT INTO rh.marcaciones (empleado_id, tipo, fecha_hora, fecha, origen, similitud, dispositivo,
                                latitud, longitud, link_ubicacion, precision_m,
                                foto, observacion, created_by, updated_by)
    VALUES (p_empleado_id, v_tipo, v_fecha, v_dia, COALESCE(UPPER(p_origen), 'FACIAL'),
            CASE WHEN p_similitud IS NULL THEN NULL ELSE ROUND(p_similitud, 2) END,
            NULLIF(TRIM(COALESCE(p_dispositivo, '')), ''),
            v_lat, v_lng, v_link,
            CASE WHEN p_precision_m IS NULL OR v_lat IS NULL THEN NULL
                 ELSE ROUND(GREATEST(p_precision_m, 0), 2) END,
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
