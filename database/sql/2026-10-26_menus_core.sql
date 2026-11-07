-- ===========================================================================
-- LOS MENÚS DE SUCURSALES Y PUNTOS DE VENTA APUNTAN AL MÓDULO CORE
-- ===========================================================================
-- Las dos pantallas se mudaron de /ventas a /core (front y API), así que la
-- url del menú tiene que decir lo mismo o la pantalla cae en el 404.
--
-- EL PERMISO NO CAMBIA: sale del SEGUNDO TRAMO de la url
-- (core/allSucursales -> ALLSUCURSALES), que es el mismo de antes. Por eso
-- `seguridad.accesos` no se toca: los cuatro accesos que había siguen
-- valiendo.
--
-- EL SITIO EN LA BARRA LATERAL TAMPOCO CAMBIA: el árbol del menú lo arma
-- `padre_id`, no la url. Sucursales y Puntos de Venta se siguen viendo donde
-- la gente los busca —bajo Ventas— aunque por dentro sean de core.
-- ===========================================================================
\set ON_ERROR_STOP on

BEGIN;

UPDATE seguridad.menus SET url = 'core/allSucursales'
 WHERE url = 'ventas/allSucursales';

UPDATE seguridad.menus SET url = 'core/allPuntosVenta'
 WHERE url = 'ventas/allPuntosVenta';

-- Que no quede ninguno apuntando a donde ya no hay nada
DO $comprobar$
DECLARE viejos integer;
BEGIN
    SELECT count(*) INTO viejos FROM seguridad.menus
     WHERE url IN ('ventas/allSucursales', 'ventas/allPuntosVenta');
    IF viejos > 0 THEN
        RAISE EXCEPTION 'Quedan % menús apuntando al módulo ventas', viejos;
    END IF;
END
$comprobar$;

COMMIT;
