-- ============================================================================
-- ECOMMERCE · CADA PRODUCTO DE UNA SECCIÓN VIAJA CON SUS CARACTERÍSTICAS
-- ============================================================================
-- Fecha: 2026-11-07
-- Va DESPUÉS de 2026-11-06_ecommerce_seccion_paginada.sql.
--
-- La sección paginada enseña TODOS los productos del escaparate, y con
-- doscientos hace falta poder acotar: «sólo las negras», «sólo 4G», «sólo
-- Samsung». Los filtros de la tienda se arman con lo que ya se llena en el
-- CRM —la ficha de características de cada producto— y no con una lista
-- aparte que habría que mantener a mano.
--
-- SE MANDAN LAS QUE TIENEN VALOR, y nada más: una característica de la
-- plantilla que nadie rellenó no es un filtro, es una fila vacía que dejaría
-- un desplegable con una sola opción en blanco.
--
-- Y VIAJA TAMBIÉN LA CATEGORÍA con su nombre: un escaparate puede llevar
-- productos de varias —«Lo más vendido» mezcla televisores y licuadoras—, y
-- ahí la categoría es el primer filtro que alguien busca. El nombre es el de
-- la tienda (`categorias_web.nombre_web`) si se le puso otro.
--
-- NO SE MANDA EL PRECIO, y es a propósito: la tarjeta de la tienda enseña hoy
-- precios de muestra calculados sobre el id (seccion-productos.component), así
-- que un filtro por precio filtraría por un número inventado. Cuando el
-- catálogo dé precios de verdad, el filtro de precio entra aquí.
--
-- Idempotente.
-- ============================================================================
\set ON_ERROR_STOP on

BEGIN;

CREATE OR REPLACE FUNCTION ecommerce.fn_producto_seccion_publica(p_seccion_id bigint)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
AS $function$
    SELECT COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
                   -- `id` es además la REFERENCIA que se lee en la tarjeta
                   'id',     p.id,
                   'nombre', p.nombre,
                   -- La del catálogo. La tienda la usa SÓLO para saber si el
                   -- producto es una moto y enseñar nada más el botón de
                   -- WhatsApp; no se pinta en ningún sitio.
                   'categoria_id', p.categoria_id,
                   -- Y su nombre, que SÍ se pinta: es un filtro de la sección
                   -- paginada. El de la tienda si se le puso otro.
                   'categoria', nullif(btrim(COALESCE(cw.nombre_web, cat.nombre, '')), ''),
                   -- La marca, para la pastilla de debajo del nombre. Van el
                   -- nombre Y el fichero del logo: casi ninguna marca tiene
                   -- logo todavía, y sin el nombre esas tarjetas se quedarían
                   -- con un hueco. Además es lo que describe al logo para
                   -- quien no ve la pantalla.
                   'marca',       nullif(btrim(COALESCE(m.nombre, '')), ''),
                   'marca_logo',  nullif(btrim(COALESCE(m.logo, '')), ''),
                   -- Lo que se llenó de su ficha, para los filtros de la
                   -- sección paginada: sólo las que tienen valor, en el orden
                   -- de la plantilla de su categoría
                   'caracteristicas', COALESCE(fichas.lista, '[]'::jsonb),
                   -- Las dos primeras de su galería, en el mismo orden con el
                   -- que se eligen en el CRM. Una sola consulta con LIMIT 2 y
                   -- no dos subconsultas: así no hay forma de que la «segunda»
                   -- acabe siendo la misma que la primera.
                   'imagen',             fotos.primera,
                   'imagen_secundaria',  fotos.segunda)
               ORDER BY it.orden, p.id)
          FROM ecommerce.producto_secciones_items it
          JOIN inventarios.productos p ON p.id = it.producto_id
          -- LEFT: un producto sin marca sigue siendo un producto y su tarjeta
          -- tiene que salir igual
          LEFT JOIN inventarios.marcas m ON m.id = p.marca_id AND m.deleted_at IS NULL
          LEFT JOIN inventarios.categorias cat ON cat.id = p.categoria_id AND cat.deleted_at IS NULL
          LEFT JOIN ecommerce.categorias_web cw ON cw.categoria_id = p.categoria_id
          LEFT JOIN LATERAL (
              SELECT jsonb_agg(jsonb_build_object('nombre', c.nombre, 'valor', btrim(c.valor))
                     ORDER BY c.orden, c.id) AS lista
                FROM inventarios.caracteristicas_productos c
               WHERE c.producto_id = p.id
                 AND nullif(btrim(COALESCE(c.valor, '')), '') IS NOT NULL
                 AND nullif(btrim(COALESCE(c.nombre, '')), '') IS NOT NULL
          ) fichas ON true
          LEFT JOIN LATERAL (
              SELECT min(g.archivo) FILTER (WHERE g.puesto = 1) AS primera,
                     min(g.archivo) FILTER (WHERE g.puesto = 2) AS segunda
                FROM (SELECT i.archivo,
                             row_number() OVER (ORDER BY i.principal DESC, i.orden, i.id) AS puesto
                        FROM inventarios.productos_imagenes i
                       WHERE i.producto_id = p.id) g
               WHERE g.puesto <= 2
          ) fotos ON true
         WHERE it.seccion_id = p_seccion_id
           AND p.deleted_at IS NULL
           AND p.activo), '[]'::jsonb);
$function$;

-- ----------------------------------------------------------------------------
-- COMPROBACIÓN
-- ----------------------------------------------------------------------------
DO $comprobar$
DECLARE
    v_seccion bigint;
    v_lista   jsonb;
    v_uno     jsonb;
BEGIN
    -- Una sección con productos
    SELECT i.seccion_id INTO v_seccion
      FROM ecommerce.producto_secciones_items i
      JOIN ecommerce.producto_secciones s ON s.id = i.seccion_id AND s.deleted_at IS NULL
     GROUP BY i.seccion_id ORDER BY count(*) DESC LIMIT 1;

    IF v_seccion IS NULL THEN
        RAISE NOTICE 'No hay escaparates con productos: me salto la comprobación.';
        RETURN;
    END IF;

    v_lista := ecommerce.fn_producto_seccion_publica(v_seccion);
    IF jsonb_array_length(v_lista) = 0 THEN
        RAISE EXCEPTION 'El escaparate % salió vacío', v_seccion;
    END IF;

    v_uno := v_lista -> 0;
    IF NOT (v_uno ? 'caracteristicas') THEN
        RAISE EXCEPTION 'Falta `caracteristicas` en el producto: %', v_uno;
    END IF;
    IF jsonb_typeof(v_uno -> 'caracteristicas') <> 'array' THEN
        RAISE EXCEPTION '`caracteristicas` tiene que ser una lista, aunque esté vacía: %',
              v_uno -> 'caracteristicas';
    END IF;
    IF NOT (v_uno ? 'categoria') THEN
        RAISE EXCEPTION 'Falta el nombre de la categoría: %', v_uno;
    END IF;

    -- Ninguna puede venir sin valor: ésas no son filtros
    IF EXISTS (SELECT 1
                 FROM jsonb_array_elements(v_lista) p,
                      jsonb_array_elements(p -> 'caracteristicas') c
                WHERE nullif(btrim(COALESCE(c ->> 'valor', '')), '') IS NULL) THEN
        RAISE EXCEPTION 'Llegó una característica sin valor';
    END IF;

    RAISE NOTICE 'Comprobado: cada producto viaja con su categoría y con las características que tienen valor (escaparate %, % productos).',
          v_seccion, jsonb_array_length(v_lista);
END
$comprobar$;

COMMIT;
