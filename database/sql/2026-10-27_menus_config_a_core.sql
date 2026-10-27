-- ===========================================================================
-- LAS PANTALLAS DE CONFIGURACIÓN PASAN AL MÓDULO CORE (front)
-- ===========================================================================
-- Archivos, boletines y notificaciones viven en la base como `core.archivos`,
-- `core.boletines` y `core.notificaciones`, y en el back ya estaban en
-- `Controllers/core`. Ahora también el front: sus pantallas se mudaron de
-- `modules/config` a `modules/core`, así que la ruta pasa de `config/...` a
-- `core/...` y la url del menú tiene que decir lo mismo o la pantalla cae en
-- el 404.
--
-- EL PERMISO NO CAMBIA: sale del SEGUNDO TRAMO de la url
-- (core/filemanager -> FILEMANAGER), que es el mismo de antes. Por eso
-- `seguridad.accesos` no se toca.
--
-- EL SITIO EN LA BARRA LATERAL TAMPOCO: el árbol lo arma `padre_id`, y
-- «Configuracion» sigue siendo el padre de todas ellas.
--
-- Las tres pantallas de la plantilla (extra-profile, extra-settings,
-- extra-search-results) no tienen menú: cuelgan del desplegable del
-- encabezado y del pie del menú lateral, y esos enlaces se cambiaron en el
-- front.
-- ===========================================================================
\set ON_ERROR_STOP on

BEGIN;

UPDATE seguridad.menus
   SET url = 'core/' || split_part(url, '/', 2)
 WHERE url IN ('config/home-config',
               'config/filemanager',
               'config/misArchivos',
               'config/boletines',
               'config/notificaciones');

DO $comprobar$
DECLARE viejos integer;
BEGIN
    SELECT count(*) INTO viejos FROM seguridad.menus WHERE url LIKE 'config/%';
    IF viejos > 0 THEN
        RAISE EXCEPTION 'Quedan % menús apuntando a config/', viejos;
    END IF;
END
$comprobar$;

COMMIT;
