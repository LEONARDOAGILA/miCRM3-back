-- ===========================================================================
-- PROFORMAS · EL LISTADO DE PRODUCTOS PARA COTIZAR
-- ===========================================================================
-- POR QUÉ NO SE USA inventarios.fn_productos_listar_paginado.
--
-- Esa función devuelve el catálogo tal cual: el costo, los mínimos de stock,
-- las medidas, la descripción en HTML del editor… y NO devuelve el
-- iva_porcentaje, que es justo lo que la línea de una proforma necesita para
-- calcularse. Usarla obligaría a volver a preguntar por cada producto elegido
-- sólo para saber su IVA.
--
-- Esto devuelve las filas YA CON LA FORMA DE UNA LÍNEA (las mismas claves que
-- fn_proformas_producto_buscar), así el modal y el teclear-el-código hablan
-- el mismo idioma y la rejilla no tiene que saber de dónde vino cada cosa.
--
-- Tampoco enseña el costo: esta pantalla la usa quien vende, y el costo no
-- tiene por qué estar a un clic en el sitio donde se cotiza.
\set ON_ERROR_STOP on

BEGIN;

CREATE OR REPLACE FUNCTION ventas.fn_proformas_productos_paginado(
    p_page         integer DEFAULT 1,
    p_per_page     integer DEFAULT 10,
    p_search       text    DEFAULT ''::text,
    p_categoria_id bigint  DEFAULT NULL::bigint,
    p_marca_id     bigint  DEFAULT NULL::bigint
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'pg_catalog', 'ventas', 'inventarios'
AS $fn$
DECLARE
    v_offset integer;
    v_filtro text;
    v_total  bigint;
    v_data   jsonb;
BEGIN
    v_offset := (GREATEST(p_page, 1) - 1) * GREATEST(p_per_page, 1);
    v_filtro := NULLIF(TRIM(COALESCE(p_search, '')), '');

    WITH base AS (
        SELECT pr.*
          FROM inventarios.productos pr
         WHERE pr.deleted_at IS NULL
           -- SÓLO LOS ACTIVOS: un producto desactivado es uno que ya no se
           -- vende, y ofrecerlo aquí es ofrecer lo que no se puede entregar
           AND pr.activo
           AND (p_categoria_id IS NULL OR pr.categoria_id = p_categoria_id)
           AND (p_marca_id     IS NULL OR pr.marca_id     = p_marca_id)
           AND (v_filtro IS NULL
            OR ventas.fn_sin_tildes(pr.codigo)        LIKE '%' || ventas.fn_sin_tildes(v_filtro) || '%'
            OR ventas.fn_sin_tildes(pr.codigo_barras) LIKE '%' || ventas.fn_sin_tildes(v_filtro) || '%'
            OR ventas.fn_sin_tildes(pr.nombre)        LIKE '%' || ventas.fn_sin_tildes(v_filtro) || '%'
            OR ventas.fn_sin_tildes(pr.modelo)        LIKE '%' || ventas.fn_sin_tildes(v_filtro) || '%')
    )
    SELECT
        (SELECT COUNT(*) FROM base),
        -- Sin `detalle`: es la descripción larga del editor, HTML con
        -- imágenes dentro, y en una página de veinte productos son cientos de
        -- kilobytes que el selector no enseña
        (SELECT COALESCE(jsonb_agg((ventas.fn_proformas_producto_json(t) - 'detalle') ORDER BY t.nombre), '[]'::jsonb)
           FROM (SELECT b.* FROM base b ORDER BY b.nombre
                  LIMIT GREATEST(p_per_page, 1) OFFSET v_offset) t)
      INTO v_total, v_data;

    RETURN jsonb_build_object(
        'data', v_data,
        'meta', jsonb_build_object(
            'total',        v_total,
            'per_page',     GREATEST(p_per_page, 1),
            'current_page', GREATEST(p_page, 1),
            'last_page',    CASE WHEN v_total = 0 THEN 1 ELSE ceil(v_total::numeric / GREATEST(p_per_page, 1)) END
        )
    );
EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object('success', false,
                                  'message', 'Error al listar productos: ' || SQLERRM,
                                  'error_code', SQLSTATE);
END;
$fn$;

COMMENT ON FUNCTION ventas.fn_proformas_productos_paginado(integer,integer,text,bigint,bigint) IS
'El catálogo paginado con la forma de una línea de proforma (precio e IVA incluidos). Sólo productos activos y sin el costo.';

COMMIT;
