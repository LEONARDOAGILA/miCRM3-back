-- ============================================================================
-- MENÚ: Ecommerce → «Inicio de la tienda» pasa a «Cuerpos de la tienda»
-- ----------------------------------------------------------------------------
-- La pantalla ya no administra UNA portada: administra los CUERPOS de la
-- tienda, que son varias páginas de secciones. El menú tiene que decir lo
-- mismo que la pantalla, porque es por donde se la busca.
--
-- LA URL NO SE TOCA. El programa sale del segundo tramo
-- —ecommerce/editInicio da EDITINICIO— y es con lo que `findByProgramProfile`
-- busca los accesos: cambiarla dejaría a todo el mundo sin permiso sobre la
-- pantalla hasta rehacer sus accesos uno por uno. Lo que se ve es el nombre.
--
-- Se puede volver a ejecutar sin romper nada.
-- ============================================================================
\set ON_ERROR_STOP on
\pset tuples_only on
\pset format unaligned
BEGIN;

UPDATE seguridad.menus
   SET nombre      = '🏪 Cuerpos de la tienda',
       descripcion = 'Las páginas de secciones de la tienda: la de entrada y las de cada categoría o marca'
 WHERE url = 'ecommerce/editInicio';

-- ---------------------------------------------------------------------------
-- Comprobación
-- ---------------------------------------------------------------------------
DO $c$
DECLARE
    v_nombre text;
    v_url    text;
BEGIN
    SELECT nombre, url INTO v_nombre, v_url
      FROM seguridad.menus WHERE url = 'ecommerce/editInicio';

    IF v_nombre IS NULL THEN
        RAISE EXCEPTION 'No está la fila del menú de ecommerce/editInicio';
    END IF;
    IF v_nombre NOT LIKE '%Cuerpos de la tienda' THEN
        RAISE EXCEPTION 'El menú no se renombró: %', v_nombre;
    END IF;
    IF v_url <> 'ecommerce/editInicio' THEN
        RAISE EXCEPTION 'La url cambió, y eso deja a todos sin accesos: %', v_url;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM seguridad.accesos a
                    JOIN seguridad.menus m ON m.id = a.menu_id
                   WHERE m.url = 'ecommerce/editInicio') THEN
        RAISE EXCEPTION 'La pantalla se quedó sin accesos';
    END IF;

    RAISE NOTICE 'Comprobado: el menú se llama «%» y sigue en %, con sus accesos.', v_nombre, v_url;
END
$c$;

COMMIT;
