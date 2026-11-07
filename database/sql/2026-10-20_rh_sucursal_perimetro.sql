-- ===========================================================================
-- EL EMPLEADO, SU SUCURSAL Y EL PERÍMETRO AL MARCAR
-- ===========================================================================
-- Fecha: 2026-10-20
--
-- Va con 2026-10-20_ventas_sucursales.sql (que crea la tabla y la columna
-- rh.empleados.sucursal_id). Aquí se añade la sucursal a las fichas de
-- empleado, la función para asignarla y la regla que impide marcar fuera
-- del perímetro.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- 1. LA SUCURSAL, EN LAS FICHAS DE EMPLEADO
-- ---------------------------------------------------------------------------
-- Se vuelven a crear tal como estaban, con dos campos más: sucursal_id y el
-- nombre de la sucursal. Así la rejilla de empleados puede enseñar dónde
-- trabaja cada uno y el modal de asignar sabe qué tiene puesto.

CREATE OR REPLACE FUNCTION rh.fn_empleados_obtener(p_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    v_data jsonb;
BEGIN
    SELECT jsonb_build_object(
        'id',                    e.id,
        'numero_identificacion', e.numero_identificacion,
        'tipo_identificacion',   e.tipo_identificacion,
        'nombres',               e.nombres,
        'apellidos',             e.apellidos,
        'nombre_completo',       TRIM(CONCAT_WS(' ', e.nombres, e.apellidos)),
        'email',                 e.email,
        'email_personal',        e.email_personal,
        'telefono',              e.telefono,
        'celular',               e.celular,
        'fecha_nacimiento',      to_char(e.fecha_nacimiento, 'YYYY-MM-DD'),
        'genero',                e.genero,
        'direccion',             e.direccion,
        -- La dirección que vino del mapa
        'provincia',             e.provincia,
        'canton',                e.canton,
        'parroquia',             e.parroquia,
        'calle_principal',       e.calle_principal,
        'calle_secundaria',      e.calle_secundaria,
        'numeracion',            e.numeracion,
        'ubicacion',             e.ubicacion,
        'codigo_postal',         e.codigo_postal,
        'coordenadas',           e.coordenadas,
        'link_coordenadas',      e.link_coordenadas,
        'url_foto_mapa',         e.url_foto_mapa,
        'url_foto_casa',         e.url_foto_casa,
        'cargo_id',              e.cargo_id,
        'cargo_nombre',          c.nombre,
        'sucursal_id',           e.sucursal_id,
        'sucursal_nombre',       s.nombre,
        'departamento_id',       e.departamento_id,
        'departamento_nombre',   d.nombre,
        'jefe_id',               e.jefe_id,
        'jefe_nombre',           NULLIF(TRIM(CONCAT_WS(' ', j.nombres, j.apellidos)), ''),
        'fecha_ingreso',         to_char(e.fecha_ingreso, 'YYYY-MM-DD'),
        'fecha_salida',          to_char(e.fecha_salida, 'YYYY-MM-DD'),
        'estado',                e.estado,
        'tipo_contrato',         e.tipo_contrato,
        'salario',               e.salario,
        'foto',                  e.foto,
        'activo',                e.activo,
        'created_by',            e.created_by,
        'updated_by',            e.updated_by,
        'created_at',            to_char(e.created_at, 'YYYY-MM-DD HH24:MI:SS'),
        'updated_at',            to_char(e.updated_at, 'YYYY-MM-DD HH24:MI:SS')
    ) INTO v_data
    FROM rh.empleados e
    LEFT JOIN rh.cargos c        ON c.id = e.cargo_id
    LEFT JOIN ventas.sucursales s ON s.id = e.sucursal_id
    LEFT JOIN rh.departamentos d ON d.id = e.departamento_id
    LEFT JOIN rh.empleados j     ON j.id = e.jefe_id
    WHERE e.id = p_id;

    IF v_data IS NULL THEN
        RETURN jsonb_build_object('success', false, 'message', 'Empleado no encontrado', 'error_code', 'EMPLEADO_NOT_FOUND', 'data', null);
    END IF;
    RETURN jsonb_build_object('success', true, 'message', 'Empleado obtenido exitosamente', 'data', v_data);
EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object('success', false, 'message', 'Error al obtener el empleado: ' || SQLERRM, 'error_code', SQLSTATE);
END;
$function$;

CREATE OR REPLACE FUNCTION rh.fn_empleados_listar_paginado(p_page integer DEFAULT 1, p_per_page integer DEFAULT 15, p_search text DEFAULT ''::text)
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
      FROM rh.empleados e
      LEFT JOIN rh.cargos c        ON c.id = e.cargo_id
      LEFT JOIN rh.departamentos d ON d.id = e.departamento_id
     WHERE v_filtro IS NULL
        OR CONCAT_WS(' ', e.nombres, e.apellidos) ILIKE '%' || v_filtro || '%'
        OR CONCAT_WS(' ', e.apellidos, e.nombres) ILIKE '%' || v_filtro || '%'
        OR e.numero_identificacion ILIKE '%' || v_filtro || '%'
        OR e.email  ILIKE '%' || v_filtro || '%'
        OR c.nombre ILIKE '%' || v_filtro || '%'
        OR d.nombre ILIKE '%' || v_filtro || '%'
        OR e.id::text ILIKE '%' || v_filtro || '%';

    SELECT COALESCE(jsonb_agg(
        jsonb_build_object(
            'id',                    t.id,
            'numero_identificacion', t.numero_identificacion,
            'tipo_identificacion',   t.tipo_identificacion,
            'nombres',               t.nombres,
            'apellidos',             t.apellidos,
            'nombre_completo',       TRIM(CONCAT_WS(' ', t.nombres, t.apellidos)),
            'email',                 t.email,
            'email_personal',        t.email_personal,
            'telefono',              t.telefono,
            'celular',               t.celular,
            'fecha_nacimiento',      to_char(t.fecha_nacimiento, 'YYYY-MM-DD'),
            'genero',                t.genero,
            'direccion',             t.direccion,
            'cargo_id',              t.cargo_id,
            'cargo_nombre',          t.cargo_nombre,
            'sucursal_id',           t.sucursal_id,
            'sucursal_nombre',       t.sucursal_nombre,
            'departamento_id',       t.departamento_id,
            'departamento_nombre',   t.departamento_nombre,
            'jefe_id',               t.jefe_id,
            'jefe_nombre',           t.jefe_nombre,
            'fecha_ingreso',         to_char(t.fecha_ingreso, 'YYYY-MM-DD'),
            'fecha_salida',          to_char(t.fecha_salida, 'YYYY-MM-DD'),
            'estado',                t.estado,
            'tipo_contrato',         t.tipo_contrato,
            'salario',               t.salario,
            'foto',                  t.foto,
            'activo',                t.activo,
            'created_by',            t.created_by,
            'updated_by',            t.updated_by,
            'created_at',            to_char(t.created_at, 'YYYY-MM-DD HH24:MI:SS'),
            'updated_at',            to_char(t.updated_at, 'YYYY-MM-DD HH24:MI:SS')
        ) ORDER BY t.id DESC
    ), '[]'::jsonb) INTO v_data
    FROM (
        SELECT e.*, c.nombre AS cargo_nombre, d.nombre AS departamento_nombre,
               s.nombre AS sucursal_nombre,
               NULLIF(TRIM(CONCAT_WS(' ', j.nombres, j.apellidos)), '') AS jefe_nombre
          FROM rh.empleados e
          LEFT JOIN rh.cargos c        ON c.id = e.cargo_id
          LEFT JOIN ventas.sucursales s ON s.id = e.sucursal_id
          LEFT JOIN rh.departamentos d ON d.id = e.departamento_id
          LEFT JOIN rh.empleados j     ON j.id = e.jefe_id
         WHERE v_filtro IS NULL
            OR CONCAT_WS(' ', e.nombres, e.apellidos) ILIKE '%' || v_filtro || '%'
            OR CONCAT_WS(' ', e.apellidos, e.nombres) ILIKE '%' || v_filtro || '%'
            OR e.numero_identificacion ILIKE '%' || v_filtro || '%'
            OR e.email  ILIKE '%' || v_filtro || '%'
            OR c.nombre ILIKE '%' || v_filtro || '%'
            OR d.nombre ILIKE '%' || v_filtro || '%'
            OR e.id::text ILIKE '%' || v_filtro || '%'
         ORDER BY e.id DESC
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
        RETURN jsonb_build_object('success', false, 'message', 'Error al listar empleados: ' || SQLERRM, 'error_code', SQLSTATE);
END;
$function$;

CREATE OR REPLACE FUNCTION rh.fn_empleados_listar(p_solo_activos boolean DEFAULT true)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    v_data jsonb;
BEGIN
    SELECT COALESCE(jsonb_agg(
        jsonb_build_object(
            'id', e.id,
            'nombre', TRIM(CONCAT_WS(' ', e.nombres, e.apellidos)),
            'numero_identificacion', e.numero_identificacion,
            'cargo_nombre', c.nombre,
            'sucursal_id',  e.sucursal_id,
            'sucursal_nombre', s.nombre,
            'departamento_nombre', d.nombre,
            'activo', e.activo
        ) ORDER BY e.apellidos, e.nombres
    ), '[]'::jsonb) INTO v_data
    FROM rh.empleados e
    LEFT JOIN rh.cargos c        ON c.id = e.cargo_id
    LEFT JOIN ventas.sucursales s ON s.id = e.sucursal_id
    LEFT JOIN rh.departamentos d ON d.id = e.departamento_id
    WHERE NOT p_solo_activos OR (e.activo AND COALESCE(e.estado, 'ACTIVO') = 'ACTIVO');

    RETURN jsonb_build_object('success', true, 'message', 'Empleados obtenidos exitosamente', 'data', v_data);
EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object('success', false, 'message', 'Error al listar empleados: ' || SQLERRM, 'error_code', SQLSTATE);
END;
$function$;

-- ---------------------------------------------------------------------------
-- 2. ASIGNAR LA SUCURSAL A UN EMPLEADO
-- ---------------------------------------------------------------------------
-- Función propia y no un parámetro más en fn_empleados_modificar: esa tiene
-- treinta argumentos posicionales y cambiarla por esto obligaría a tocar el
-- formulario entero. Aquí se cambia una sola cosa y queda auditada.
CREATE OR REPLACE FUNCTION rh.fn_empleados_asignar_sucursal(
    p_id             bigint,
    p_sucursal_id    bigint  DEFAULT NULL,      -- NULL = quitarle la sucursal
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
SET search_path TO 'pg_catalog', 'rh', 'ventas', 'auditoria'
AS $function$
DECLARE
    v_emp      record;
    v_sucursal record;
    v_mensaje  text;
BEGIN
    PERFORM rh.fn_contexto_auditoria('rh.empleados',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    SELECT id, TRIM(CONCAT_WS(' ', nombres, apellidos)) AS nombre, sucursal_id
      INTO v_emp FROM rh.empleados WHERE id = p_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'El empleado no existe' USING ERRCODE = 'P0013';
    END IF;

    IF p_sucursal_id IS NOT NULL THEN
        SELECT id, nombre, activo INTO v_sucursal
          FROM ventas.sucursales WHERE id = p_sucursal_id AND deleted_at IS NULL;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'La sucursal indicada no existe o está en la papelera' USING ERRCODE = 'P0016';
        END IF;
        IF NOT v_sucursal.activo THEN
            RAISE EXCEPTION 'La sucursal «%» está inactiva', v_sucursal.nombre USING ERRCODE = 'P0021';
        END IF;
    END IF;

    UPDATE rh.empleados SET sucursal_id = p_sucursal_id WHERE id = p_id;

    -- EL MENSAJE SE ARMA CON UN IF Y NO CON UN CASE DENTRO DEL jsonb: quitarle
    -- la sucursal a alguien deja `v_sucursal` sin asignar, y PL/pgSQL no
    -- compila una expresión que lo nombre —aunque sea en la rama que no se
    -- toma— porque todavía no conoce la forma de ese registro.
    IF p_sucursal_id IS NULL THEN
        v_mensaje := format('«%s» se queda sin sucursal asignada', v_emp.nombre);
    ELSE
        v_mensaje := format('«%s» queda asignado a %s', v_emp.nombre, v_sucursal.nombre);
    END IF;

    RETURN jsonb_build_object('success', true,
        'message', v_mensaje,
        'data', rh.fn_empleados_obtener(p_id)->'data');
END;
$function$;

-- ---------------------------------------------------------------------------
-- 3. AL MARCAR: SÓLO DENTRO DEL PERÍMETRO DE SU SUCURSAL
-- ---------------------------------------------------------------------------
-- La regla vive AQUÍ y no en las pantallas porque las marcaciones entran por
-- tres sitios (el kiosco, el celular del empleado y el alta a mano) y una
-- comprobación en el navegador se la salta cualquiera con la consola abierta.
--
-- Qué hace:
--   · Empleado sin sucursal, o sucursal sin perímetro -> no se exige nada.
--   · Con perímetro y sin coordenadas -> se rechaza (P0025): hay que dar
--     permiso de ubicación.
--   · Con perímetro y fuera (contando la tolerancia) -> se rechaza (P0024)
--     diciendo a cuántos metros está.
--   · El alta MANUAL (la de la pantalla de marcaciones, que lleva su fecha y
--     su tipo) NO se controla: la hace Recursos Humanos para corregir, y
--     quien corrige no está en la puerta.
DROP FUNCTION IF EXISTS rh.fn_marcaciones_registrar(
    bigint, character varying, character varying, numeric, character varying,
    numeric, numeric, character varying, text, timestamp with time zone, integer, numeric,
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

    -- 5. EL PERÍMETRO DE SU SUCURSAL
    --    El alta a mano de Recursos Humanos se queda fuera de esta regla.
    IF v_emp.sucursal_id IS NOT NULL AND UPPER(COALESCE(p_origen, 'FACIAL')) <> 'MANUAL' THEN
        v_perimetro := ventas.fn_sucursales_contiene(v_emp.sucursal_id, v_lat, v_lng);

        IF (v_perimetro->>'exige')::boolean AND NOT (v_perimetro->>'dentro')::boolean THEN
            IF v_lat IS NULL THEN
                RAISE EXCEPTION 'Para marcar en «%» hay que permitir la ubicación: su sucursal exige marcar dentro del perímetro',
                      v_perimetro->>'sucursal' USING ERRCODE = 'P0025';
            ELSE
                RAISE EXCEPTION '«%» está a % m del perímetro de «%»: sólo se puede marcar dentro',
                      v_emp.nombre, ROUND((v_perimetro->>'distancia_m')::numeric), v_perimetro->>'sucursal'
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
