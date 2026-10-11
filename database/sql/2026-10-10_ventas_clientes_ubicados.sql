-- ===========================================================================
-- LOS CLIENTES QUE TIENEN COORDENADAS, PARA PINTARLOS EN EL MAPA
-- ===========================================================================
-- Fecha: 2026-10-10
-- Se aplica después de 2026-10-10_ventas_zonas.sql (usa fn_coordenada_lat/lng).
--
-- El mapa de zonas enseñaba sólo los clientes de la zona elegida, y eso llega
-- tarde: para dibujar un polígono alrededor de un grupo de clientes hay que
-- VER antes dónde están. Esto devuelve todos los que tienen coordenadas, con
-- lo justo para pintar un punto y decir de quién es al pasar por encima.
--
-- VA APARTE DE fn_zonas_clientes a propósito. Aquél contesta «quién cae
-- dentro de ESTA zona» y devuelve la ficha resumida —identificación,
-- teléfono, dirección, cantón— para la tabla de abajo. Éste contesta «dónde
-- está todo el mundo» y devuelve cuatro campos: son mil puntos, y mandar la
-- ficha entera de cada uno sería mover un megabyte para dibujar puntitos.
--
-- EL TOPE NO ES UN ADORNO. Con ochenta mil clientes, pintarlos todos de una
-- vez deja el navegador pensando; se devuelven los primeros y se dice cuántos
-- hay en total, para que la pantalla pueda avisar de que no están todos.
--
-- SE PUEDE ACOTAR POR CAJA (p_min_lat … p_max_lng): lo que se ve en el mapa.
-- Hoy no hace falta —son mil—, pero el día que haga falta la pantalla sólo
-- tiene que mandar los límites del mapa y aquí no cambia nada.
--
-- Idempotente.
-- ===========================================================================

CREATE OR REPLACE FUNCTION ventas.fn_clientes_ubicados(
    p_limite  integer DEFAULT 2000,
    p_min_lat numeric DEFAULT NULL,
    p_max_lat numeric DEFAULT NULL,
    p_min_lng numeric DEFAULT NULL,
    p_max_lng numeric DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'ventas'
AS $function$
DECLARE
    v_limite integer := LEAST(GREATEST(COALESCE(p_limite, 2000), 1), 20000);
    v_total  bigint;
    v_data   jsonb;
BEGIN
    WITH ubicados AS (
        SELECT c.id,
               c.nombre_completo,
               c.activo,
               ventas.fn_coordenada_lat(c.coordenadas) AS lat,
               ventas.fn_coordenada_lng(c.coordenadas) AS lng
          FROM ventas.clientes c
         WHERE c.deleted_at IS NULL
           AND ventas.fn_coordenada_lat(c.coordenadas) IS NOT NULL
    ),
    dentro AS (
        SELECT * FROM ubicados u
         WHERE (p_min_lat IS NULL OR u.lat BETWEEN p_min_lat AND p_max_lat)
           AND (p_min_lng IS NULL OR u.lng BETWEEN p_min_lng AND p_max_lng)
    ),
    pagina AS (
        SELECT * FROM dentro ORDER BY id LIMIT v_limite
    )
    SELECT (SELECT COUNT(*) FROM dentro),
           COALESCE((SELECT jsonb_agg(jsonb_build_object(
                                'id',     p.id,
                                'nombre', p.nombre_completo,
                                'activo', p.activo,
                                'lat',    p.lat,
                                'lng',    p.lng)
                             ORDER BY p.id)
                       FROM pagina p), '[]'::jsonb)
      INTO v_total, v_data;

    RETURN jsonb_build_object(
        'success', true,
        'message', 'Clientes ubicados obtenidos exitosamente',
        'data', v_data,
        'meta', jsonb_build_object(
            'total',     v_total,
            'devueltos', jsonb_array_length(v_data),
            -- Para que la pantalla pueda decir «se ven 2000 de 80000»
            'recortado', v_total > jsonb_array_length(v_data)
        )
    );
EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object('success', false,
               'message', 'Error al obtener los clientes ubicados: ' || SQLERRM,
               'error_code', SQLSTATE);
END;
$function$;
