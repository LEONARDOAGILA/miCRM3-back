-- ============================================================================
-- REPORTES: EL MOTOR DEL TABLERO DE VENTAS DEMO
-- ============================================================================
-- Fecha: 2026-10-29
-- Va después de `2026-10-29_reportes_ventas_demo.sql`.
--
-- Tres funciones:
--
--   fn_ventas_demo_opciones()        qué se puede poner en filas, en columnas
--                                    y como medida. La LISTA BLANCA vive aquí
--                                    y el front sólo la pinta: así no hay dos
--                                    sitios que puedan decir cosas distintas.
--   fn_ventas_demo_pivote(...)       la tabla cruzada: filas × columnas con
--                                    sus totales.
--   fn_ventas_demo_listar_paginado() el detalle, fila a fila, con los filtros
--                                    de cabecera de siempre.
--
-- SOBRE LA INYECCIÓN SQL: el pivote arma SQL dinámico, que es la única forma
-- de que las columnas salgan de los datos. Pero lo que se interpola NO es lo
-- que escribe el usuario: es la expresión que devuelve la lista blanca para
-- esa clave. Una clave desconocida no se interpola, se rechaza.
--
-- POR QUÉ GROUPING SETS Y NO SUMAR LAS CELDAS: el total de una fila no es la
-- suma de sus celdas cuando la medida es un PROMEDIO (ni un mínimo, ni un
-- máximo, ni un conteo de distintos). Con GROUPING SETS, PostgreSQL calcula
-- la celda, el total de la fila y el total general con la MISMA función de
-- agregación, en una sola pasada.
--
-- Idempotente.
-- ============================================================================
\set ON_ERROR_STOP on

BEGIN;

-- ---------------------------------------------------------------------------
-- LA LISTA BLANCA
-- ---------------------------------------------------------------------------
-- Clave -> expresión SQL. Lo que no esté aquí no existe para el tablero.
CREATE OR REPLACE FUNCTION reportes.fn_ventas_demo_expresion(p_clave text)
RETURNS text
LANGUAGE plpgsql
IMMUTABLE
AS $$
BEGIN
    RETURN CASE lower(COALESCE(p_clave, ''))
        WHEN 'region'     THEN 'v.region'
        WHEN 'ciudad'     THEN 'v.ciudad'
        WHEN 'vendedor'   THEN 'v.vendedor'
        WHEN 'canal'      THEN 'v.canal'
        WHEN 'categoria'  THEN 'v.categoria'
        WHEN 'producto'   THEN 'v.producto'
        WHEN 'cliente'    THEN 'v.cliente'
        WHEN 'forma_pago' THEN 'v.forma_pago'
        WHEN 'anio'       THEN 'v.anio::text'
        WHEN 'trimestre'  THEN E'v.anio::text || \'-T\' || v.trimestre::text'
        WHEN 'mes'        THEN E'to_char(v.fecha, \'YYYY-MM\')'
        WHEN 'dia_semana' THEN E'(ARRAY[\'1 Lunes\',\'2 Martes\',\'3 Miércoles\',\'4 Jueves\',\'5 Viernes\',\'6 Sábado\',\'7 Domingo\'])[EXTRACT(ISODOW FROM v.fecha)::int]'
        ELSE NULL
    END;
END;
$$;

CREATE OR REPLACE FUNCTION reportes.fn_ventas_demo_medida(p_clave text)
RETURNS text
LANGUAGE plpgsql
IMMUTABLE
AS $$
BEGIN
    RETURN CASE lower(COALESCE(p_clave, ''))
        WHEN 'total'      THEN 'v.total'
        WHEN 'margen'     THEN 'v.margen'
        WHEN 'costo'      THEN 'v.costo'
        WHEN 'cantidad'   THEN 'v.cantidad::numeric'
        WHEN 'descuento'  THEN 'v.descuento'
        WHEN 'ventas'     THEN '1::numeric'        -- para contar ventas
        ELSE NULL
    END;
END;
$$;

-- ---------------------------------------------------------------------------
-- QUÉ SE PUEDE ELEGIR (lo pinta el front)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION reportes.fn_ventas_demo_opciones()
RETURNS jsonb
LANGUAGE sql
STABLE SECURITY DEFINER
AS $$
    SELECT jsonb_build_object(
        'success', true,
        'dimensiones', jsonb_build_array(
            jsonb_build_object('id', 'region',     'name', 'Región'),
            jsonb_build_object('id', 'ciudad',     'name', 'Ciudad'),
            jsonb_build_object('id', 'vendedor',   'name', 'Vendedor'),
            jsonb_build_object('id', 'canal',      'name', 'Canal'),
            jsonb_build_object('id', 'categoria',  'name', 'Categoría'),
            jsonb_build_object('id', 'producto',   'name', 'Producto'),
            jsonb_build_object('id', 'cliente',    'name', 'Cliente'),
            jsonb_build_object('id', 'forma_pago', 'name', 'Forma de pago'),
            jsonb_build_object('id', 'anio',       'name', 'Año'),
            jsonb_build_object('id', 'trimestre',  'name', 'Trimestre'),
            jsonb_build_object('id', 'mes',        'name', 'Mes'),
            jsonb_build_object('id', 'dia_semana', 'name', 'Día de la semana')
        ),
        'medidas', jsonb_build_array(
            jsonb_build_object('id', 'total',     'name', 'Venta ($)',      'dinero', true),
            jsonb_build_object('id', 'margen',    'name', 'Margen ($)',     'dinero', true),
            jsonb_build_object('id', 'costo',     'name', 'Costo ($)',      'dinero', true),
            jsonb_build_object('id', 'descuento', 'name', 'Descuento ($)',  'dinero', true),
            jsonb_build_object('id', 'cantidad',  'name', 'Unidades',       'dinero', false),
            jsonb_build_object('id', 'ventas',    'name', 'Nº de ventas',   'dinero', false)
        ),
        'agregaciones', jsonb_build_array(
            jsonb_build_object('id', 'SUM',   'name', 'Suma'),
            jsonb_build_object('id', 'AVG',   'name', 'Promedio'),
            jsonb_build_object('id', 'COUNT', 'name', 'Cuenta'),
            jsonb_build_object('id', 'MIN',   'name', 'Mínimo'),
            jsonb_build_object('id', 'MAX',   'name', 'Máximo')
        ),
        -- Los valores que hay, para los desplegables de filtro
        'filtros', jsonb_build_object(
            'region',    (SELECT jsonb_agg(DISTINCT region    ORDER BY region)    FROM reportes.ventas_demo),
            'categoria', (SELECT jsonb_agg(DISTINCT categoria ORDER BY categoria) FROM reportes.ventas_demo),
            'canal',     (SELECT jsonb_agg(DISTINCT canal     ORDER BY canal)     FROM reportes.ventas_demo),
            'vendedor',  (SELECT jsonb_agg(DISTINCT vendedor  ORDER BY vendedor)  FROM reportes.ventas_demo)
        ),
        'rango', (SELECT jsonb_build_object('desde', min(fecha), 'hasta', max(fecha),
                                            'ventas', count(*))
                    FROM reportes.ventas_demo)
    );
$$;

-- ---------------------------------------------------------------------------
-- EL FILTRO, EN UN SITIO
-- ---------------------------------------------------------------------------
-- Devuelve el trozo de WHERE. Los textos van por quote_literal, así que una
-- comilla en el nombre de un cliente no rompe nada ni abre ninguna puerta.
CREATE OR REPLACE FUNCTION reportes.fn_ventas_demo_donde(p_filtros jsonb)
RETURNS text
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_donde text := 'true';
    v_clave text;
    v_lista jsonb;
BEGIN
    IF p_filtros IS NULL THEN RETURN v_donde; END IF;

    IF (p_filtros ->> 'desde') IS NOT NULL AND (p_filtros ->> 'desde') <> '' THEN
        v_donde := v_donde || ' AND v.fecha >= ' || quote_literal(p_filtros ->> 'desde') || '::date';
    END IF;
    IF (p_filtros ->> 'hasta') IS NOT NULL AND (p_filtros ->> 'hasta') <> '' THEN
        v_donde := v_donde || ' AND v.fecha <= ' || quote_literal(p_filtros ->> 'hasta') || '::date';
    END IF;

    -- Los de lista: region, categoria, canal, vendedor…
    FOREACH v_clave IN ARRAY ARRAY['region', 'ciudad', 'vendedor', 'canal', 'categoria',
                                   'producto', 'cliente', 'forma_pago'] LOOP
        v_lista := p_filtros -> v_clave;
        IF v_lista IS NOT NULL AND jsonb_typeof(v_lista) = 'array' AND jsonb_array_length(v_lista) > 0 THEN
            v_donde := v_donde || ' AND ' || reportes.fn_ventas_demo_expresion(v_clave) || ' IN ('
                     || (SELECT string_agg(quote_literal(x), ', ')
                           FROM jsonb_array_elements_text(v_lista) x) || ')';
        END IF;
    END LOOP;

    -- Y el buscador libre, sobre lo que se lee
    IF NULLIF(TRIM(COALESCE(p_filtros ->> 'buscar', '')), '') IS NOT NULL THEN
        v_donde := v_donde || ' AND (v.producto || '' '' || v.cliente || '' '' || v.vendedor || '' '' '
                 || '|| v.ciudad || '' '' || v.categoria) ILIKE '
                 || quote_literal('%' || TRIM(p_filtros ->> 'buscar') || '%');
    END IF;

    RETURN v_donde;
END;
$$;

-- ---------------------------------------------------------------------------
-- EL PIVOTE
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION reportes.fn_ventas_demo_pivote(
    p_filas      text    DEFAULT 'region',
    p_columnas   text    DEFAULT 'mes',
    p_medida     text    DEFAULT 'total',
    p_agregacion text    DEFAULT 'SUM',
    p_filtros    jsonb   DEFAULT '{}'::jsonb,
    p_orden      text    DEFAULT 'valor',     -- 'valor' | 'etiqueta'
    p_limite     integer DEFAULT 200)         -- cuántas filas como mucho
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'pg_catalog', 'reportes'
AS $$
DECLARE
    v_exprFilas  text := reportes.fn_ventas_demo_expresion(p_filas);
    v_exprCols   text := reportes.fn_ventas_demo_expresion(p_columnas);
    v_exprMedida text := reportes.fn_ventas_demo_medida(p_medida);
    v_agg        text := upper(COALESCE(p_agregacion, 'SUM'));
    v_donde      text;
    v_sql        text;
    v_columnas   text[];
    v_filas      jsonb;
    v_totales    jsonb := '{}'::jsonb;
    v_granTotal  numeric;
    v_cuantas    integer;
BEGIN
    IF v_exprFilas IS NULL THEN
        RAISE EXCEPTION 'No se puede agrupar por «%»', p_filas USING ERRCODE = 'P0015';
    END IF;
    IF v_exprMedida IS NULL THEN
        RAISE EXCEPTION 'No se puede medir «%»', p_medida USING ERRCODE = 'P0015';
    END IF;
    IF v_agg NOT IN ('SUM', 'AVG', 'COUNT', 'MIN', 'MAX') THEN
        RAISE EXCEPTION 'Esa operación no existe: «%»', p_agregacion USING ERRCODE = 'P0015';
    END IF;
    -- Sin dimensión de columnas, el pivote es una lista: una sola columna
    IF p_columnas IS NULL OR TRIM(p_columnas) = '' OR lower(p_columnas) = 'ninguna' THEN
        v_exprCols := E'\'Total\'';
    ELSIF v_exprCols IS NULL THEN
        RAISE EXCEPTION 'No se puede cruzar por «%»', p_columnas USING ERRCODE = 'P0015';
    END IF;

    v_donde := reportes.fn_ventas_demo_donde(p_filtros);

    -- Cuántas columnas saldrían. Una rejilla de 300 columnas no la lee nadie
    -- y el navegador se arrastra, así que se avisa en vez de pintarla.
    EXECUTE format(
        'SELECT count(DISTINCT %s) FROM reportes.ventas_demo v WHERE %s', v_exprCols, v_donde)
       INTO v_cuantas;

    IF v_cuantas > 60 THEN
        RAISE EXCEPTION 'Cruzar por «%» daría % columnas. Elija otra cosa para las columnas o acote las fechas',
            p_columnas, v_cuantas USING ERRCODE = 'P0015';
    END IF;

    -- UNA SOLA PASADA para las celdas, los totales de fila y el total
    -- general: GROUPING SETS. Sumar las celdas daría mal el total cuando la
    -- medida es un promedio.
    v_sql := format($q$
        WITH base AS (
            SELECT COALESCE(%1$s, '(sin dato)') AS grupo,
                   COALESCE(%2$s, '(sin dato)') AS columna,
                   %3$s AS medida
              FROM reportes.ventas_demo v
             WHERE %4$s
        ), cruzado AS (
            SELECT grupo, columna,
                   %5$s AS valor,
                   GROUPING(grupo) AS sin_grupo,
                   GROUPING(columna) AS sin_columna
              FROM base
             -- Los CUATRO conjuntos: la celda, el total de la fila, el total
             -- de la columna (el pie de la tabla) y el total general. Sin el
             -- de (columna) el pie sale vacío y no se nota hasta mirarlo.
             GROUP BY GROUPING SETS ((grupo, columna), (grupo), (columna), ())
        )
        SELECT jsonb_build_object(
            'columnas', COALESCE((SELECT jsonb_agg(DISTINCT columna ORDER BY columna)
                                    FROM cruzado WHERE sin_columna = 0), '[]'::jsonb),
            'filas', COALESCE((
                SELECT jsonb_agg(f ORDER BY %6$s)
                  FROM (
                    SELECT jsonb_build_object(
                               'grupo', t.grupo,
                               'valores', COALESCE((SELECT jsonb_object_agg(c.columna, round(c.valor, 2))
                                                      FROM cruzado c
                                                     WHERE c.sin_grupo = 0 AND c.sin_columna = 0
                                                       AND c.grupo = t.grupo), '{}'::jsonb),
                               'total', round(t.valor, 2)
                           ) AS f,
                           t.grupo AS etiqueta, t.valor AS valor
                      FROM cruzado t
                     WHERE t.sin_grupo = 0 AND t.sin_columna = 1
                  ) s), '[]'::jsonb),
            'totales', COALESCE((SELECT jsonb_object_agg(columna, round(valor, 2))
                                   FROM cruzado WHERE sin_grupo = 1 AND sin_columna = 0), '{}'::jsonb),
            'gran_total', (SELECT round(valor, 2) FROM cruzado WHERE sin_grupo = 1 AND sin_columna = 1)
        )
    $q$,
        v_exprFilas, v_exprCols, v_exprMedida, v_donde,
        CASE WHEN v_agg = 'COUNT' THEN 'count(*)::numeric' ELSE v_agg || '(medida)' END,
        CASE WHEN lower(COALESCE(p_orden, 'valor')) = 'etiqueta' THEN 'etiqueta ASC' ELSE 'valor DESC NULLS LAST' END
    );

    EXECUTE v_sql INTO v_filas;

    -- Las columnas, en su orden (los meses salen bien ordenados porque son
    -- '2026-01', '2026-02'…)
    SELECT array_agg(x ORDER BY x) INTO v_columnas
      FROM jsonb_array_elements_text(v_filas -> 'columnas') x;

    RETURN jsonb_build_object(
        'success', true,
        'meta', jsonb_build_object(
            'filas', p_filas, 'columnas', COALESCE(NULLIF(p_columnas, ''), 'ninguna'),
            'medida', p_medida, 'agregacion', v_agg,
            'cuantas_filas', jsonb_array_length(v_filas -> 'filas'),
            'cuantas_columnas', COALESCE(array_length(v_columnas, 1), 0)
        ),
        'columnas',   to_jsonb(COALESCE(v_columnas, ARRAY[]::text[])),
        'filas',      CASE WHEN p_limite IS NULL OR p_limite <= 0 THEN v_filas -> 'filas'
                           ELSE COALESCE((SELECT jsonb_agg(f) FROM (
                                    SELECT f FROM jsonb_array_elements(v_filas -> 'filas') f
                                     LIMIT p_limite) s), '[]'::jsonb) END,
        'totales',    v_filas -> 'totales',
        'gran_total', v_filas -> 'gran_total'
    );

EXCEPTION
    WHEN SQLSTATE 'P0015' THEN RAISE;
    WHEN OTHERS THEN
        RETURN jsonb_build_object('success', false,
            'message', 'Error al armar el pivote: ' || SQLERRM, 'error_code', SQLSTATE);
END;
$$;

-- ---------------------------------------------------------------------------
-- EL DETALLE
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION reportes.fn_ventas_demo_listar_paginado(
    p_page     integer DEFAULT 1,
    p_per_page integer DEFAULT 25,
    p_filtros  jsonb   DEFAULT '{}'::jsonb,
    p_ordenar  text    DEFAULT 'fecha',
    p_sentido  text    DEFAULT 'DESC')
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'pg_catalog', 'reportes'
AS $$
DECLARE
    v_donde   text := reportes.fn_ventas_demo_donde(p_filtros);
    v_orden   text;
    v_sentido text := CASE WHEN upper(COALESCE(p_sentido, 'DESC')) = 'ASC' THEN 'ASC' ELSE 'DESC' END;
    v_total   bigint;
    v_data    jsonb;
    v_offset  integer := (GREATEST(p_page, 1) - 1) * GREATEST(p_per_page, 1);
BEGIN
    -- Ordenar por una columna que exista, y nada más
    v_orden := CASE lower(COALESCE(p_ordenar, 'fecha'))
        WHEN 'fecha' THEN 'v.fecha' WHEN 'region' THEN 'v.region'
        WHEN 'ciudad' THEN 'v.ciudad' WHEN 'vendedor' THEN 'v.vendedor'
        WHEN 'canal' THEN 'v.canal' WHEN 'categoria' THEN 'v.categoria'
        WHEN 'producto' THEN 'v.producto' WHEN 'cliente' THEN 'v.cliente'
        WHEN 'forma_pago' THEN 'v.forma_pago' WHEN 'cantidad' THEN 'v.cantidad'
        WHEN 'total' THEN 'v.total' WHEN 'margen' THEN 'v.margen'
        WHEN 'costo' THEN 'v.costo' WHEN 'descuento' THEN 'v.descuento'
        ELSE 'v.fecha' END;

    EXECUTE format('SELECT count(*) FROM reportes.ventas_demo v WHERE %s', v_donde) INTO v_total;

    EXECUTE format($q$
        SELECT COALESCE(jsonb_agg(jsonb_build_object(
                   'id', v.id,
                   'fecha', to_char(v.fecha, 'YYYY-MM-DD'),
                   'region', v.region, 'ciudad', v.ciudad, 'vendedor', v.vendedor,
                   'canal', v.canal, 'categoria', v.categoria, 'producto', v.producto,
                   'cliente', v.cliente, 'forma_pago', v.forma_pago,
                   'cantidad', v.cantidad,
                   'precio_unitario', v.precio_unitario,
                   'descuento', v.descuento,
                   'total', v.total, 'costo', v.costo, 'margen', v.margen,
                   'margen_pct', CASE WHEN v.total <> 0 THEN round(100 * v.margen / v.total, 1) ELSE 0 END
               ) ORDER BY %s %s, v.id), '[]'::jsonb)
          FROM (SELECT * FROM reportes.ventas_demo v WHERE %s
                 ORDER BY %s %s, v.id LIMIT %s OFFSET %s) v
    $q$, v_orden, v_sentido, v_donde, v_orden, v_sentido,
         GREATEST(p_per_page, 1), v_offset)
    INTO v_data;

    RETURN jsonb_build_object(
        'data', v_data,
        'meta', jsonb_build_object(
            'total', v_total,
            'per_page', GREATEST(p_per_page, 1),
            'current_page', GREATEST(p_page, 1),
            'last_page', CASE WHEN v_total = 0 THEN 1
                              ELSE ceil(v_total::numeric / GREATEST(p_per_page, 1)) END
        ));

EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false,
        'message', 'Error al listar el detalle: ' || SQLERRM, 'error_code', SQLSTATE);
END;
$$;

COMMIT;
