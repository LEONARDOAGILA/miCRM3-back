-- ============================================================================
-- LA LISTA SIMPLE DE PRODUCTOS DEVUELVE TAMBIÉN SU CATEGORÍA
-- ============================================================================
-- Fecha: 2026-10-31
--
-- `inventarios.fn_productos_listar` daba id, codigo, nombre, precio y activo.
-- Le falta `categoria_id`, y sin él la pantalla de productos no puede pintar
-- la chapita de cada rama del árbol de categorías: contaba cero en todas.
--
-- POR QUÉ SE CUENTA EN EL NAVEGADOR Y NO AQUÍ. Lo mismo hace la pantalla de
-- características: se traen las categorías por un lado y la lista simple por
-- otro, y el recuento se arma en el cliente. Son DOS llamadas en vez de una
-- por categoría —con 28 categorías serían 28 viajes para pintar unos
-- contadores—. Si el catálogo crece mucho, lo que habrá que hacer es una
-- función que devuelva los recuentos ya agregados, no traerse la lista
-- entera; pero eso es cambiar el patrón de las dos pantallas, no de ésta.
--
-- Es ADITIVO: se añade una clave al JSON. Quien ya usaba esta lista para sus
-- combos sigue recibiendo lo mismo más un campo que puede ignorar.
--
-- Se conserva tal cual estaba lo demás: el filtro de papelera
-- (`deleted_at IS NULL`, lo de la papelera no se puede elegir), el de activos
-- y el orden por nombre.
-- ============================================================================
\set ON_ERROR_STOP on

BEGIN;

CREATE OR REPLACE FUNCTION inventarios.fn_productos_listar(p_solo_activos boolean DEFAULT true)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
AS $function$
    SELECT jsonb_build_object(
        'success', true,
        'data', COALESCE(jsonb_agg(
            jsonb_build_object('id', p.id, 'codigo', p.codigo, 'nombre', p.nombre,
                               'precio', p.precio, 'activo', p.activo,
                               'categoria_id', p.categoria_id)
            ORDER BY p.nombre
        ), '[]'::jsonb)
    )
      FROM inventarios.productos p
     WHERE p.deleted_at IS NULL            -- lo de la papelera no se puede elegir
       AND (NOT p_solo_activos OR p.activo);
$function$;

-- Que no se quede a medias sin avisar
DO $comprobar$
DECLARE v_falta boolean;
BEGIN
    SELECT NOT (inventarios.fn_productos_listar(false) -> 'data' -> 0 ? 'categoria_id')
      INTO v_falta;
    IF v_falta THEN
        RAISE EXCEPTION 'fn_productos_listar sigue sin devolver categoria_id';
    END IF;
END
$comprobar$;

SELECT 'productos en la lista simple: '
       || jsonb_array_length(inventarios.fn_productos_listar(false) -> 'data') AS resultado;

COMMIT;
