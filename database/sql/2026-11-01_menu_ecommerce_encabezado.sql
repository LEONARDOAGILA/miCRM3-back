-- El menú y los accesos de la pantalla del encabezado. Sin esto la ruta cae en
-- el 404 aunque el componente esté bien: el AccessResolver busca el programa
-- por el último tramo de la url y exige `ejecutar`.
--
-- Cuelga de «Ecommerce», que ya existe, y copia los accesos de Páginas
-- informativas: quien administra el contenido de la tienda administra su
-- encabezado.
--
-- Va PRIMERA dentro del apartado (orden 0) porque es lo primero que se ve en
-- la tienda, y porque es lo que más se toca: la franja de arriba cambia con
-- cada promoción.
--
-- Idempotente.
\set ON_ERROR_STOP on
\pset tuples_only on
\pset format unaligned

BEGIN;

INSERT INTO seguridad.menus (padre_id, orden, nivel, nombre, url, descripcion, icono)
SELECT p.id, 0, 1,
       '🧭 Encabezado',
       'ecommerce/editEncabezado',
       'La franja de arriba, el aviso de crédito, las frases del buscador y el menú',
       '-'
  FROM seguridad.menus p
 WHERE p.nivel = 0 AND p.url = 'ecommerce'
   AND NOT EXISTS (SELECT 1 FROM seguridad.menus WHERE url = 'ecommerce/editEncabezado');

INSERT INTO seguridad.accesos (perfil_id, menu_id, ver, crear, editar, eliminar, listar,
                               reporte, auditar, ejecutar, papelera, vaciar)
SELECT a.perfil_id,
       (SELECT id FROM seguridad.menus WHERE url = 'ecommerce/editEncabezado'),
       a.ver, a.crear, a.editar, a.eliminar, a.listar,
       a.reporte, a.auditar, a.ejecutar, a.papelera, a.vaciar
  FROM seguridad.accesos a
 WHERE a.menu_id = (SELECT id FROM seguridad.menus WHERE url = 'ecommerce/allPaginasInformativas')
   AND NOT EXISTS (
       SELECT 1 FROM seguridad.accesos x
        WHERE x.perfil_id = a.perfil_id
          AND x.menu_id = (SELECT id FROM seguridad.menus WHERE url = 'ecommerce/editEncabezado'));

DO $comprobar$
DECLARE
    v_menu bigint;
    v_n    integer;
BEGIN
    SELECT id INTO v_menu FROM seguridad.menus WHERE url = 'ecommerce/editEncabezado';
    IF v_menu IS NULL THEN
        RAISE EXCEPTION 'No se creó el menú del encabezado. ¿Existe el apartado «Ecommerce»?';
    END IF;

    SELECT count(*) INTO v_n FROM seguridad.accesos WHERE menu_id = v_menu AND ejecutar;
    IF v_n = 0 THEN
        RAISE EXCEPTION 'Ningún perfil puede abrirla: el resolver mandaría a /access-deny';
    END IF;

    RAISE NOTICE 'Menú % creado y % perfiles pueden abrirlo.', v_menu, v_n;
END
$comprobar$;

SELECT 'pantalla: id ' || id || ' · ' || nombre || ' · ' || url
  FROM seguridad.menus WHERE url = 'ecommerce/editEncabezado';

COMMIT;
