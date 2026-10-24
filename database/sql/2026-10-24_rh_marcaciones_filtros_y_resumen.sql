-- ===========================================================================
-- MARCACIONES: FILTROS DE COLUMNA Y RESUMEN PAGINADO
-- ===========================================================================
-- Las dos pestañas de la pantalla pasan a comportarse igual que el resto de
-- rejillas del sistema:
--
--   · MARCACIONES       el listado gana `p_filtros`, la lista blanca de
--                       siempre, para filtrar por la cabecera.
--   · HORAS TRABAJADAS  deja de devolverse entero: se pagina y se filtra como
--                       cualquier otra rejilla. Con un mes de rango y
--                       cincuenta empleados eran mil quinientas filas en una
--                       sola respuesta.
--
-- `p_filtros` es {columna: {op, valor}} YA NORMALIZADO por el trait
-- FiltrosDeColumna de PHP, que además tira lo que no esté en su lista blanca.
-- Las tres listas —pantalla, controlador y este fichero— tienen que decir lo
-- mismo: una columna que sólo esté en la pantalla pinta un filtro que no
-- filtra.
\set ON_ERROR_STOP on

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. EL LISTADO, CON FILTROS DE CABECERA
-- ---------------------------------------------------------------------------
-- El parámetro nuevo va al final, así que la versión de ocho argumentos se
-- queda viva y se la lleva por delante una llamada posicional. Se tira.
DROP FUNCTION IF EXISTS rh.fn_marcaciones_listar_paginado(
    integer, integer, text, date, date, bigint, character varying, character varying);

CREATE OR REPLACE FUNCTION rh.fn_marcaciones_listar_paginado(
    p_page        integer     DEFAULT 1,
    p_per_page    integer     DEFAULT 15,
    p_search      text        DEFAULT ''::text,
    p_desde       date        DEFAULT NULL::date,
    p_hasta       date        DEFAULT NULL::date,
    p_empleado_id bigint      DEFAULT NULL::bigint,
    p_tipo        varchar     DEFAULT NULL::varchar,
    p_origen      varchar     DEFAULT NULL::varchar,
    p_filtros     jsonb       DEFAULT '{}'::jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'rh', 'ventas'
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
      LEFT JOIN rh.departamentos d ON d.id = e.departamento_id
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
            OR m.observacion ILIKE '%' || v_filtro || '%')

       -- ---------- LOS FILTROS DE LA CABECERA ----------
       AND (p_filtros->'fecha'          IS NULL OR ventas.fn_filtro_texto(to_char(m.fecha, 'YYYY-MM-DD'),        p_filtros->'fecha'))
       AND (p_filtros->'hora'           IS NULL OR ventas.fn_filtro_texto(to_char(m.fecha_hora, 'HH24:MI:SS'),   p_filtros->'hora'))
       AND (p_filtros->'empleado'       IS NULL OR ventas.fn_filtro_texto(TRIM(CONCAT_WS(' ', e.nombres, e.apellidos)), p_filtros->'empleado'))
       AND (p_filtros->'identificacion' IS NULL OR ventas.fn_filtro_texto(e.numero_identificacion,               p_filtros->'identificacion'))
       AND (p_filtros->'tipo'           IS NULL OR ventas.fn_filtro_texto(m.tipo,                                p_filtros->'tipo'))
       AND (p_filtros->'origen'         IS NULL OR ventas.fn_filtro_texto(m.origen,                              p_filtros->'origen'))
       AND (p_filtros->'similitud'      IS NULL OR ventas.fn_filtro_numero(m.similitud,                          p_filtros->'similitud'))
       -- Sin departamento también se busca: «sin» no encuentra un NULL
       AND (p_filtros->'departamento'   IS NULL OR ventas.fn_filtro_texto(COALESCE(d.nombre, 'Sin departamento'), p_filtros->'departamento'))
       AND (p_filtros->'dispositivo'    IS NULL OR ventas.fn_filtro_texto(m.dispositivo,                         p_filtros->'dispositivo'))
       AND (p_filtros->'observacion'    IS NULL OR ventas.fn_filtro_texto(m.observacion,                         p_filtros->'observacion'))
       AND (p_filtros->'created_by'     IS NULL OR ventas.fn_filtro_texto(m.created_by,                          p_filtros->'created_by'))

       -- EL ATRASO Y LA HORA ESPERADA salen de evaluar el horario del
       -- empleado, así que sólo se calculan cuando de verdad se filtra por
       -- ellos: el `IS NULL` de delante es lo que evita hacerlo por cada fila
       -- del rango en todas las demás consultas.
       --
       -- Una SALIDA no tiene atraso, así que filtrar por él la deja fuera:
       -- es lo que se quiere al pedir «los que llegaron tarde».
       AND (p_filtros->'hora_esperada'  IS NULL OR ventas.fn_filtro_texto(
               (rh.fn_horarios_empleados_evaluar(e.horario_id, m.fecha_hora)->'data'->>'hora_inicio'),
               p_filtros->'hora_esperada'))
       AND (p_filtros->'atraso_min'     IS NULL OR (m.tipo = 'ENTRADA' AND e.horario_id IS NOT NULL
            AND ventas.fn_filtro_numero(
               (rh.fn_horarios_empleados_evaluar(e.horario_id, m.fecha_hora)->'data'->>'atraso_min')::numeric,
               p_filtros->'atraso_min')));

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
            'current_page', GREATEST(COALESCE(p_page, 1), 1),
            'last_page',    CASE WHEN v_total = 0 THEN 1 ELSE ceil(v_total::numeric / p_per_page) END
        )
    );
END;
$function$;

-- ---------------------------------------------------------------------------
-- 2. EL RESUMEN DE HORAS, PAGINADO Y CON FILTROS
-- ---------------------------------------------------------------------------
-- Una fila por empleado y día. Los TOTALES de la cabecera son de TODO lo que
-- cumple el filtro, no de la página: si dijeran lo de la página, cambiarían al
-- pasar de hoja y no servirían para nada.
CREATE OR REPLACE FUNCTION rh.fn_marcaciones_resumen_paginado(
    p_page        integer DEFAULT 1,
    p_per_page    integer DEFAULT 15,
    p_search      text    DEFAULT ''::text,
    p_desde       date    DEFAULT NULL::date,
    p_hasta       date    DEFAULT NULL::date,
    p_empleado_id bigint  DEFAULT NULL::bigint,
    p_filtros     jsonb   DEFAULT '{}'::jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'rh', 'ventas'
AS $function$
DECLARE
    v_desde  date := COALESCE(p_desde, CURRENT_DATE);
    v_hasta  date := COALESCE(p_hasta, CURRENT_DATE);
    v_offset integer;
    v_filtro text;
    v_total  bigint;
    v_data   jsonb;
    v_tot    jsonb;
BEGIN
    v_offset := (GREATEST(COALESCE(p_page, 1), 1) - 1) * GREATEST(p_per_page, 1);
    v_filtro := NULLIF(TRIM(COALESCE(p_search, '')), '');

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
    ),
    -- La fila tal como se ve, para poder filtrarla por lo que se ve
    filas AS (
        SELECT d.empleado_id,
               d.fecha,
               TRIM(CONCAT_WS(' ', e.nombres, e.apellidos)) AS empleado,
               e.numero_identificacion                      AS identificacion,
               dep.nombre                                   AS departamento,
               to_char(d.primera_entrada, 'HH24:MI:SS')     AS primera_entrada,
               to_char(d.ultima_salida,   'HH24:MI:SS')     AS ultima_salida,
               d.marcaciones,
               ROUND((d.segundos / 3600.0)::numeric, 2)     AS horas,
               to_char((d.segundos || ' seconds')::interval, 'HH24:MI') AS horas_texto,
               (d.ultima_salida IS NULL OR d.primera_entrada IS NULL)   AS incompleto
          FROM dias d
          JOIN rh.empleados e ON e.id = d.empleado_id
          LEFT JOIN rh.departamentos dep ON dep.id = e.departamento_id
    ),
    filtradas AS (
        SELECT f.* FROM filas f
         WHERE (v_filtro IS NULL
                OR f.empleado       ILIKE '%' || v_filtro || '%'
                OR f.identificacion ILIKE '%' || v_filtro || '%'
                OR f.departamento   ILIKE '%' || v_filtro || '%')

           -- ---------- LOS FILTROS DE LA CABECERA ----------
           AND (p_filtros->'fecha'           IS NULL OR ventas.fn_filtro_texto(to_char(f.fecha, 'YYYY-MM-DD'), p_filtros->'fecha'))
           AND (p_filtros->'empleado'        IS NULL OR ventas.fn_filtro_texto(f.empleado,        p_filtros->'empleado'))
           AND (p_filtros->'identificacion'  IS NULL OR ventas.fn_filtro_texto(f.identificacion,  p_filtros->'identificacion'))
           AND (p_filtros->'departamento'    IS NULL OR ventas.fn_filtro_texto(COALESCE(f.departamento, 'Sin departamento'), p_filtros->'departamento'))
           AND (p_filtros->'primera_entrada' IS NULL OR ventas.fn_filtro_texto(f.primera_entrada, p_filtros->'primera_entrada'))
           AND (p_filtros->'ultima_salida'   IS NULL OR ventas.fn_filtro_texto(f.ultima_salida,   p_filtros->'ultima_salida'))
           AND (p_filtros->'marcaciones'     IS NULL OR ventas.fn_filtro_numero(f.marcaciones,    p_filtros->'marcaciones'))
           AND (p_filtros->'horas'           IS NULL OR ventas.fn_filtro_numero(f.horas,          p_filtros->'horas'))
    )
    SELECT COUNT(*),
           -- Los totales, de todo lo filtrado
           jsonb_build_object(
               'empleados', COUNT(DISTINCT empleado_id),
               'dias',      COUNT(*),
               'horas',     ROUND(COALESCE(SUM(horas), 0), 2)),
           COALESCE((
               SELECT jsonb_agg(jsonb_build_object(
                          'empleado_id',     t.empleado_id,
                          'empleado',        t.empleado,
                          'identificacion',  t.identificacion,
                          'departamento',    t.departamento,
                          'fecha',           to_char(t.fecha, 'YYYY-MM-DD'),
                          'primera_entrada', t.primera_entrada,
                          'ultima_salida',   t.ultima_salida,
                          'marcaciones',     t.marcaciones,
                          'horas',           t.horas,
                          'horas_texto',     t.horas_texto,
                          'incompleto',      t.incompleto)
                      ORDER BY t.fecha DESC, t.empleado)
                 FROM (SELECT * FROM filtradas
                        ORDER BY fecha DESC, empleado
                        LIMIT GREATEST(p_per_page, 1) OFFSET v_offset) t), '[]'::jsonb)
      INTO v_total, v_tot, v_data
      FROM filtradas;

    RETURN jsonb_build_object(
        'success', true,
        'data',    v_data,
        'totales', v_tot,
        'desde',   to_char(v_desde, 'YYYY-MM-DD'),
        'hasta',   to_char(v_hasta, 'YYYY-MM-DD'),
        'meta', jsonb_build_object(
            'total',        v_total,
            'per_page',     GREATEST(p_per_page, 1),
            'current_page', GREATEST(COALESCE(p_page, 1), 1),
            'last_page',    CASE WHEN v_total = 0 THEN 1
                                 ELSE ceil(v_total::numeric / GREATEST(p_per_page, 1)) END
        )
    );
END;
$function$;

COMMIT;
