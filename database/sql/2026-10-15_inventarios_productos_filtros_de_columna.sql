-- ===========================================================================
-- LOS FILTROS DE COLUMNA DE ag-Grid, TAMBIÉN EN LISTAR PRODUCTOS
-- ===========================================================================
-- Fecha: 2026-10-15
-- Se aplica después de 2026-10-14_inventarios_productos.sql.
--
-- El mismo arreglo que ya tienen Clientes, Gestiones y la pantalla de
-- reparto: la rejilla de Inventarios > Productos pagina en el servidor, así
-- que a ag-Grid sólo le llegan las quince filas de la página y sus filtros de
-- cabecera buscaban dentro de quince. Escribir «Samsung» y que salgan dos de
-- trescientos es peor que no tener filtro.
--
-- Ahora la cabecera sólo recoge lo que el usuario pidió y el filtrado se hace
-- aquí, sobre TODOS los productos. El modelo llega en p_filtros:
--
--     {"marca_nombre": {"op":"contains","valor":"samsung"},
--      "precio":       {"op":"greaterThan","valor":300},
--      "codigo":       {"op":"startsWith","valor":"TV-"}}
--
-- La columna que no esté, no filtra.
--
-- SE REUSAN ventas.fn_filtro_texto y ventas.fn_filtro_numero, que existen
-- desde el arreglo de la pantalla de reparto. Están en el esquema `ventas`
-- por dónde nacieron, pero no saben nada de ventas: reciben un valor y el
-- trozo de JSON con la operación. Copiarlas a `inventarios` sería tener dos
-- sitios donde arreglar el mismo operador.
--
-- NADA DE SQL DINÁMICO: las columnas filtrables están escritas una a una en
-- el WHERE, cada una detrás de `p_filtros->'columna' IS NULL OR …`, que es
-- constante en toda la consulta.
--
-- Cambia la firma, así que se suelta la función antes: CREATE OR REPLACE con
-- otros parámetros no reemplaza, crea una segunda con el mismo nombre.
--
-- Idempotente.
-- ===========================================================================

DROP FUNCTION IF EXISTS inventarios.fn_productos_listar_paginado(integer, integer, text, bigint, bigint);

CREATE OR REPLACE FUNCTION inventarios.fn_productos_listar_paginado(
    p_page         integer DEFAULT 1,
    p_per_page     integer DEFAULT 15,
    p_search       text    DEFAULT '',
    p_marca_id     bigint  DEFAULT NULL,
    p_categoria_id bigint  DEFAULT NULL,
    -- Los filtros de la cabecera de ag-Grid, columna por columna
    p_filtros      jsonb   DEFAULT '{}'::jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'inventarios', 'ventas'
AS $function$
DECLARE
    v_offset integer;
    v_total  bigint;
    v_data   jsonb;
    v_filtro text;
BEGIN
    v_offset := (GREATEST(p_page, 1) - 1) * GREATEST(p_per_page, 1);
    v_filtro := NULLIF(TRIM(COALESCE(p_search, '')), '');

    -- RECURSIVE es obligatorio: `rama` se llama a si misma. Sin el, plpgsql
    -- deja crear la funcion igual (no valida el SQL de dentro) y revienta la
    -- primera vez que alguien abre la rejilla.
    WITH RECURSIVE rama AS (
        -- La categoría pedida y todo lo que cuelga de ella
        SELECT c.id FROM inventarios.categorias c WHERE c.id = p_categoria_id
        UNION ALL
        SELECT h.id FROM inventarios.categorias h JOIN rama r ON h.padre_id = r.id
    ),
    filtrados AS (
        SELECT p.id
          FROM inventarios.productos p
          LEFT JOIN inventarios.marcas     m ON m.id = p.marca_id
          LEFT JOIN inventarios.categorias c ON c.id = p.categoria_id
         WHERE (p_marca_id     IS NULL OR p.marca_id = p_marca_id)
           AND (p_categoria_id IS NULL OR p.categoria_id IN (SELECT id FROM rama))
           AND (v_filtro IS NULL
                OR p.codigo        ILIKE '%' || v_filtro || '%'
                OR p.codigo_barras ILIKE '%' || v_filtro || '%'
                OR p.nombre        ILIKE '%' || v_filtro || '%'
                OR p.descripcion   ILIKE '%' || v_filtro || '%'
                OR p.modelo        ILIKE '%' || v_filtro || '%'
                OR m.nombre        ILIKE '%' || v_filtro || '%'
                OR c.nombre        ILIKE '%' || v_filtro || '%'
                OR p.id::text      ILIKE '%' || v_filtro || '%')

           -- ---------- LOS FILTROS DE LA CABECERA ----------
           AND (p_filtros->'id'               IS NULL OR ventas.fn_filtro_numero(p.id,              p_filtros->'id'))
           AND (p_filtros->'codigo'           IS NULL OR ventas.fn_filtro_texto(p.codigo,           p_filtros->'codigo'))
           AND (p_filtros->'nombre'           IS NULL OR ventas.fn_filtro_texto(p.nombre,           p_filtros->'nombre'))
           -- Marca y categoría se filtran por su NOMBRE, que es lo que se ve
           -- en la rejilla; el id ya tiene sus propios desplegables arriba.
           AND (p_filtros->'marca_nombre'     IS NULL OR ventas.fn_filtro_texto(m.nombre,           p_filtros->'marca_nombre'))
           AND (p_filtros->'categoria_nombre' IS NULL OR ventas.fn_filtro_texto(c.nombre,           p_filtros->'categoria_nombre'))
           AND (p_filtros->'modelo'           IS NULL OR ventas.fn_filtro_texto(p.modelo,           p_filtros->'modelo'))
           AND (p_filtros->'costo'            IS NULL OR ventas.fn_filtro_numero(p.costo,           p_filtros->'costo'))
           AND (p_filtros->'precio'           IS NULL OR ventas.fn_filtro_numero(p.precio,          p_filtros->'precio'))
           AND (p_filtros->'iva_porcentaje'   IS NULL OR ventas.fn_filtro_numero(p.iva_porcentaje,  p_filtros->'iva_porcentaje'))
           AND (p_filtros->'garantia_meses'   IS NULL OR ventas.fn_filtro_numero(p.garantia_meses,  p_filtros->'garantia_meses'))
           AND (p_filtros->'stock_minimo'     IS NULL OR ventas.fn_filtro_numero(p.stock_minimo,    p_filtros->'stock_minimo'))
           -- El contador de fotos: el mismo subselect que pinta la columna
           AND (p_filtros->'num_imagenes'     IS NULL OR ventas.fn_filtro_numero(
                   (SELECT COUNT(*) FROM inventarios.productos_imagenes i WHERE i.producto_id = p.id),
                   p_filtros->'num_imagenes'))
           AND (p_filtros->'updated_by'       IS NULL OR ventas.fn_filtro_texto(p.updated_by,       p_filtros->'updated_by'))
           -- Las fechas, como texto sobre lo que se ve: «2026-10» busca el mes
           AND (p_filtros->'created_at'       IS NULL OR ventas.fn_filtro_texto(
                   to_char(p.created_at, 'YYYY-MM-DD HH24:MI:SS'), p_filtros->'created_at'))
           AND (p_filtros->'updated_at'       IS NULL OR ventas.fn_filtro_texto(
                   to_char(p.updated_at, 'YYYY-MM-DD HH24:MI:SS'), p_filtros->'updated_at'))
    )
    SELECT COUNT(*),
           COALESCE((SELECT jsonb_agg(inventarios.fn_productos_json(t.id) ORDER BY t.id DESC)
                       FROM (SELECT f.id FROM filtrados f
                              ORDER BY f.id DESC
                              LIMIT GREATEST(p_per_page, 1) OFFSET v_offset) t), '[]'::jsonb)
      INTO v_total, v_data
      FROM filtrados;

    RETURN jsonb_build_object(
        'data', v_data,
        'meta', jsonb_build_object(
            'total',        v_total,
            'per_page',     GREATEST(p_per_page, 1),
            'current_page', GREATEST(p_page, 1),
            'last_page',    CASE WHEN v_total = 0 THEN 1
                                 ELSE ceil(v_total::numeric / GREATEST(p_per_page, 1)) END
        )
    );

EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false, 'message', 'Error al listar productos: ' || SQLERRM, 'error_code', SQLSTATE);
END;
$function$;

COMMENT ON FUNCTION inventarios.fn_productos_listar_paginado(integer, integer, text, bigint, bigint, jsonb) IS
'Listado paginado de productos. El texto de arriba (p_search) busca en código, nombre, descripción, modelo, marca y categoría; p_filtros trae los filtros de columna de ag-Grid ({"columna":{"op":"contains","valor":"x"}}) y se aplican sobre todos los productos, no sobre la página.';
