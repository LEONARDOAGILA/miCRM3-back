-- ===========================================================================
-- MARCAR EN CUALQUIERA DE SUS SUCURSALES
-- ===========================================================================
-- Hasta aquí sólo se aceptaba la marcación dentro del perímetro de
-- rh.empleados.sucursal_id. Ahora valen además las de
-- rh.empleados_marcacion_sucursal, y basta con estar dentro de UNA.
--
-- El cuerpo es el que había —sacado de la base— con el bloque 5 cambiado.
-- Se aplica sobre 2026-10-21_rh_empleados_marcacion_sucursal.sql.
\set ON_ERROR_STOP on

BEGIN;

CREATE OR REPLACE FUNCTION rh.fn_marcaciones_registrar(p_empleado_id bigint, p_tipo character varying DEFAULT NULL::character varying, p_origen character varying DEFAULT 'FACIAL'::character varying, p_similitud numeric DEFAULT NULL::numeric, p_dispositivo character varying DEFAULT NULL::character varying, p_latitud numeric DEFAULT NULL::numeric, p_longitud numeric DEFAULT NULL::numeric, p_foto character varying DEFAULT NULL::character varying, p_observacion text DEFAULT NULL::text, p_fecha_hora timestamp with time zone DEFAULT NULL::timestamp with time zone, p_espera_segundos integer DEFAULT 60, p_precision_m numeric DEFAULT NULL::numeric, p_usuario_id bigint DEFAULT NULL::bigint, p_usuario_login character varying DEFAULT NULL::character varying, p_usuario_nombre character varying DEFAULT NULL::character varying, p_ip_address inet DEFAULT NULL::inet, p_user_agent text DEFAULT NULL::text, p_request_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'rh', 'ventas', 'auditoria'
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
    v_perimetro jsonb;
    v_cerca     jsonb;      -- la sucursal suya que le queda más cerca
    v_suc       record;
    v_dentro    boolean;
    v_exige     boolean;
BEGIN
    PERFORM rh.fn_contexto_auditoria('rh.marcaciones', p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);
    v_dia := v_fecha::date;

    -- 1. El empleado debe existir y estar activo
    SELECT id, activo, estado, sucursal_id, TRIM(CONCAT_WS(' ', nombres, apellidos)) AS nombre
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

    -- 5. EL PERÍMETRO: SU SUCURSAL, O CUALQUIERA DE LAS AUTORIZADAS
    --
    --    Un cobrador, un jefe de zona o un gerente marcan en varios
    --    locales: además de la suya valen las de
    --    rh.empleados_marcacion_sucursal. BASTA CON ESTAR DENTRO DE UNA.
    --
    --    Si alguna de ellas no tiene perímetro, no hay nada que controlar y
    --    se acepta: tener autorizado un sitio sin perímetro es, justamente,
    --    poder marcar desde donde sea.
    --
    --    El alta a mano de Recursos Humanos se queda fuera de la regla.
    IF UPPER(COALESCE(p_origen, 'FACIAL')) <> 'MANUAL' THEN
        v_dentro := false;
        v_exige  := false;
        v_cerca  := NULL;

        FOR v_suc IN
            SELECT id FROM (
                SELECT v_emp.sucursal_id AS id WHERE v_emp.sucursal_id IS NOT NULL
                UNION
                SELECT ems.sucursal_id
                  FROM rh.empleados_marcacion_sucursal ems
                  JOIN ventas.sucursales s ON s.id = ems.sucursal_id
                 WHERE ems.empleado_id = p_empleado_id
                   AND ems.activo
                   AND s.activo
                   AND s.deleted_at IS NULL
            ) q
        LOOP
            v_perimetro := ventas.fn_sucursales_contiene(v_suc.id, v_lat, v_lng);

            IF NOT (v_perimetro->>'exige')::boolean THEN
                v_dentro := true;      -- esa sucursal no controla nada
                EXIT;
            END IF;

            v_exige := true;
            IF (v_perimetro->>'dentro')::boolean THEN
                v_dentro := true;
                EXIT;
            END IF;

            -- La que le quede más cerca, para poder decirle a cuánto se
            -- quedó. Sin ubicación no hay distancia, de ahí el COALESCE.
            IF v_cerca IS NULL
               OR COALESCE((v_perimetro->>'distancia_m')::numeric, 1e12)
                  < COALESCE((v_cerca->>'distancia_m')::numeric, 1e12) THEN
                v_cerca := v_perimetro;
            END IF;
        END LOOP;

        IF v_exige AND NOT v_dentro THEN
            IF v_lat IS NULL THEN
                RAISE EXCEPTION 'Para marcar en «%» hay que permitir la ubicación: su sucursal exige marcar dentro del perímetro',
                      v_cerca->>'sucursal' USING ERRCODE = 'P0025';
            ELSE
                RAISE EXCEPTION '«%» está a % m del perímetro de «%»: sólo se puede marcar dentro de sus sucursales',
                      v_emp.nombre, ROUND((v_cerca->>'distancia_m')::numeric), v_cerca->>'sucursal'
                      USING ERRCODE = 'P0024';
            END IF;
        END IF;
    END IF;

    -- 6. Insertar (el trigger de auditoría graba el registro completo)
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

COMMIT;
