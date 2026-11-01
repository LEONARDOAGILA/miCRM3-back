-- El menú y los accesos de la administración de la PÁGINA WEB. Sin esto la
-- ruta cae en el 404 aunque el componente esté bien: el AccessResolver busca
-- el programa por el último tramo de la url y exige `ejecutar`.
--
-- Se crea un apartado NUEVO de primer nivel, «Ecommerce», porque no cuelga de
-- ninguno de los que hay: no es inventario ni ventas, es el escaparate. De él
-- irán colgando las quince pantallas que se trasladan del CRM viejo; por ahora
-- sólo las páginas informativas.
--
-- Los accesos se copian TAL CUAL los tiene «Productos»: quien administra el
-- catálogo es quien administra la tienda. Si mañana hay que afinarlo, se hace
-- desde la pantalla de perfiles, que para eso está.
--
-- Idempotente: si ya está hecho, no hace nada.
\set ON_ERROR_STOP on
\pset tuples_only on
\pset format unaligned

BEGIN;

-- ----------------------------------------------------------------------------
-- 1. EL APARTADO DE PRIMER NIVEL
-- ----------------------------------------------------------------------------
-- En la primera versión de este fichero el apartado se llamaba «Pagina Web».
-- Si quedó creado así, se RENOMBRA en vez de crear otro al lado: el apartado
-- se reconoce por su url, que es lo que no cambia.
UPDATE seguridad.menus
   SET nombre = 'Ecommerce'
 WHERE nivel = 0 AND url = 'ecommerce' AND nombre <> 'Ecommerce';

INSERT INTO seguridad.menus (padre_id, orden, nivel, nombre, url, descripcion, icono)
SELECT NULL,
       (SELECT COALESCE(MAX(orden), 0) + 1 FROM seguridad.menus WHERE nivel = 0),
       0,
       'Ecommerce',
       'ecommerce',
       'El contenido de la tienda en línea: páginas, encabezado, pie, galerías y sucursales',
       'fa-solid fa-globe'
 WHERE NOT EXISTS (SELECT 1 FROM seguridad.menus WHERE nivel = 0 AND url = 'ecommerce');

-- ----------------------------------------------------------------------------
-- 2. LA PANTALLA
-- ----------------------------------------------------------------------------
INSERT INTO seguridad.menus (padre_id, orden, nivel, nombre, url, descripcion, icono)
SELECT p.id,
       (SELECT COALESCE(MAX(orden), 0) + 1 FROM seguridad.menus WHERE padre_id = p.id),
       1,
       '📄 Páginas informativas',
       'ecommerce/allPaginasInformativas',
       'Términos, políticas, garantías: el texto que la tienda enseña en /paginas y /documentos',
       '-'
  FROM seguridad.menus p
 WHERE p.nivel = 0 AND p.url = 'ecommerce'
   AND NOT EXISTS (SELECT 1 FROM seguridad.menus WHERE url = 'ecommerce/allPaginasInformativas');

-- ----------------------------------------------------------------------------
-- 3. LOS ACCESOS, LOS MISMOS QUE PRODUCTOS
-- ----------------------------------------------------------------------------
INSERT INTO seguridad.accesos (perfil_id, menu_id, ver, crear, editar, eliminar, listar,
                               reporte, auditar, ejecutar, papelera, vaciar)
SELECT a.perfil_id,
       (SELECT id FROM seguridad.menus WHERE url = 'ecommerce/allPaginasInformativas'),
       a.ver, a.crear, a.editar, a.eliminar, a.listar,
       a.reporte, a.auditar, a.ejecutar, a.papelera, a.vaciar
  FROM seguridad.accesos a
 WHERE a.menu_id = (SELECT id FROM seguridad.menus WHERE url = 'inventarios/allProductos')
   AND NOT EXISTS (
       SELECT 1 FROM seguridad.accesos x
        WHERE x.perfil_id = a.perfil_id
          AND x.menu_id = (SELECT id FROM seguridad.menus WHERE url = 'ecommerce/allPaginasInformativas'));

-- ----------------------------------------------------------------------------
-- 4. QUE DE VERDAD QUEDE USABLE
-- ----------------------------------------------------------------------------
-- Sin `ejecutar` el resolver manda a /access-deny y parece un fallo del
-- componente, así que se comprueba aquí y no al abrir la pantalla.
DO $comprobar$
DECLARE
    v_menu    bigint;
    v_con_ejecutar integer;
BEGIN
    SELECT id INTO v_menu FROM seguridad.menus WHERE url = 'ecommerce/allPaginasInformativas';
    IF v_menu IS NULL THEN
        RAISE EXCEPTION 'No se creó el menú de la pantalla';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM seguridad.menus WHERE nivel = 0 AND url = 'ecommerce') THEN
        RAISE EXCEPTION 'No se creó el apartado «Ecommerce»';
    END IF;

    SELECT count(*) INTO v_con_ejecutar FROM seguridad.accesos WHERE menu_id = v_menu AND ejecutar;
    IF v_con_ejecutar = 0 THEN
        RAISE EXCEPTION 'Ningún perfil puede ejecutar la pantalla: el resolver mandaría a /access-deny';
    END IF;

    RAISE NOTICE 'Menú % creado y % perfiles pueden abrirlo.', v_menu, v_con_ejecutar;
END
$comprobar$;

SELECT 'apartado: id ' || id || ' · ' || nombre || ' · orden ' || orden
  FROM seguridad.menus WHERE nivel = 0 AND url = 'ecommerce';

SELECT 'pantalla: id ' || id || ' · ' || nombre || ' · ' || url
  FROM seguridad.menus WHERE url = 'ecommerce/allPaginasInformativas';

SELECT 'accesos: ' || string_agg(p.nombre || ' (ver=' || a.ver || ' crear=' || a.crear
       || ' editar=' || a.editar || ' eliminar=' || a.eliminar || ' papelera=' || a.papelera
       || ' vaciar=' || a.vaciar || ')', ', ')
  FROM seguridad.accesos a
  JOIN seguridad.perfiles p ON p.id = a.perfil_id
 WHERE a.menu_id = (SELECT id FROM seguridad.menus WHERE url = 'ecommerce/allPaginasInformativas');

COMMIT;
