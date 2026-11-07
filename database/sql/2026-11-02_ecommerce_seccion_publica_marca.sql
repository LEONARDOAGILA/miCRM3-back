-- ============================================================================
-- ECOMMERCE · LA MARCA EN LA TARJETA DE UNA SECCIÓN DE PRODUCTOS
-- ============================================================================
-- Fecha: 2026-11-02
--
-- La tarjeta pasa a enseñar, debajo del nombre, la REFERENCIA del producto
-- —su id en el catálogo— y el LOGO DE SU MARCA en pequeño.
--
-- VAN LAS DOS COSAS DE LA MARCA, el logo y el nombre, y no sólo el logo:
--
--   · HOY CASI NINGUNA MARCA TIENE LOGO. De los trece productos que están en
--     las secciones, dos. Si viajara sólo el logo, once tarjetas de trece
--     dejarían ese hueco en blanco; con el nombre, la tienda escribe «Samsung»
--     y la tarjeta se lee igual de bien.
--   · Y UN LOGO SIN NOMBRE NO SE PUEDE DESCRIBIR. El `alt` de esa imagen es lo
--     único que oye quien navega sin ver, y «logo.webp» no dice nada.
--
-- EL LOGO ES EL DEL CATÁLOGO (inventarios.marcas.logo), que vive en
-- `img/marcas` y no en la carpeta del ecommerce: lo sube quien da de alta la
-- marca, no quien arma la tienda. Aquí viaja el NOMBRE DEL FICHERO y la
-- dirección la arma PHP (ImagenesDelEcommerce::urlLogoDeMarca), como con todo
-- lo demás.
--
-- LA REFERENCIA NO SE AÑADE: es `id`, que ya viajaba. La tienda sólo tenía que
-- pintarlo.
--
-- Idempotente.
-- ============================================================================
\set ON_ERROR_STOP on

BEGIN;

-- ----------------------------------------------------------------------------
-- 1. LOS PRODUCTOS DE UNA SECCIÓN, CON SU MARCA
-- ----------------------------------------------------------------------------
-- Se reescribe entera y no por cirugía: lo que cambia es la lista de campos y
-- un JOIN, y un parche con ancla sobre las dos cosas a la vez sería más frágil
-- que volver a escribir doce líneas.
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
                   -- La marca, para la pastilla de debajo del nombre. Van el
                   -- nombre Y el fichero del logo: casi ninguna marca tiene
                   -- logo todavía, y sin el nombre esas tarjetas se quedarían
                   -- con un hueco. Además es lo que describe al logo para
                   -- quien no ve la pantalla.
                   'marca',       nullif(btrim(COALESCE(m.nombre, '')), ''),
                   'marca_logo',  nullif(btrim(COALESCE(m.logo, '')), ''),
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
-- 2. COMPROBACIÓN
-- ----------------------------------------------------------------------------
DO $comprobar$
DECLARE
    v_id       bigint;
    v_con      bigint;   -- producto con marca CON logo
    v_sin      bigint;   -- producto con marca SIN logo
    v_lista    jsonb;
    v_uno      jsonb;
    v_otro     jsonb;
BEGIN
    SELECT p.id INTO v_con
      FROM inventarios.productos p
      JOIN inventarios.marcas m ON m.id = p.marca_id AND m.deleted_at IS NULL
     WHERE p.deleted_at IS NULL AND p.activo
       AND nullif(btrim(COALESCE(m.logo, '')), '') IS NOT NULL
     ORDER BY p.id LIMIT 1;

    SELECT p.id INTO v_sin
      FROM inventarios.productos p
      JOIN inventarios.marcas m ON m.id = p.marca_id AND m.deleted_at IS NULL
     WHERE p.deleted_at IS NULL AND p.activo
       AND nullif(btrim(COALESCE(m.logo, '')), '') IS NULL
       AND nullif(btrim(COALESCE(m.nombre, '')), '') IS NOT NULL
     ORDER BY p.id LIMIT 1;

    IF v_con IS NULL OR v_sin IS NULL THEN
        RAISE NOTICE 'No hay con qué comparar los dos casos (con logo: %, sin logo: %); la función está.', v_con, v_sin;
        RETURN;
    END IF;

    BEGIN
        v_id := (ecommerce.fn_producto_secciones_crear('ZZ marca ' || clock_timestamp())
                 -> 'data' ->> 'id')::bigint;
        PERFORM ecommerce.fn_producto_seccion_agregar(v_id, jsonb_build_array(v_con, v_sin));

        v_lista := ecommerce.fn_producto_seccion_publica(v_id);

        SELECT x INTO v_uno  FROM jsonb_array_elements(v_lista) x WHERE (x ->> 'id')::bigint = v_con;
        SELECT x INTO v_otro FROM jsonb_array_elements(v_lista) x WHERE (x ->> 'id')::bigint = v_sin;

        RAISE EXCEPTION 'deshacer' USING ERRCODE = 'P0099';
    EXCEPTION WHEN SQLSTATE 'P0099' THEN
        NULL;
    END;

    IF v_uno IS NULL OR v_otro IS NULL THEN
        RAISE EXCEPTION 'La sección de prueba no devolvió los dos productos: %', v_lista;
    END IF;
    IF v_uno ->> 'marca' IS NULL OR v_uno ->> 'marca_logo' IS NULL THEN
        RAISE EXCEPTION 'Una marca con logo tiene que traer las dos cosas: %', v_uno;
    END IF;
    -- El caso que más se va a dar: marca sin logo
    IF v_otro ->> 'marca' IS NULL THEN
        RAISE EXCEPTION 'Sin logo, la marca tiene que viajar igual por su nombre: %', v_otro;
    END IF;
    IF v_otro ->> 'marca_logo' IS NOT NULL THEN
        RAISE EXCEPTION 'Sin logo no puede venir un fichero: %', v_otro;
    END IF;
    -- Y lo que ya iba, que no se haya caído por el camino
    IF v_uno ->> 'nombre' IS NULL OR NOT (v_uno ? 'imagen') OR NOT (v_uno ? 'categoria_id') THEN
        RAISE EXCEPTION 'Se perdió algo de lo que ya viajaba: %', v_uno;
    END IF;
    IF EXISTS (SELECT 1 FROM ecommerce.producto_secciones WHERE id = v_id) THEN
        RAISE EXCEPTION 'La sección de prueba se quedó';
    END IF;

    RAISE NOTICE 'Comprobado: con logo viajan nombre y fichero (%), sin logo viaja el nombre solo (%), y lo de antes sigue. No quedó nada.',
          v_uno ->> 'marca', v_otro ->> 'marca';
END
$comprobar$;

COMMIT;
