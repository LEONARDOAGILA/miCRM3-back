-- El menú y los accesos de la pantalla nueva. Sin esto la ruta cae en el 404
-- aunque el componente esté bien: el AccessResolver busca el programa.
--
-- Se cuelga de «Inventarios» (padre 59) detrás de Productos, y se copian los
-- accesos TAL CUAL los tiene Marcas: quien administra marcas administra
-- características. `vaciar` se queda como esté en marcas (hoy, en nadie).
\set ON_ERROR_STOP on
\pset tuples_only on
\pset format unaligned

BEGIN;

INSERT INTO seguridad.menus (padre_id, orden, nivel, nombre, url, descripcion, icono)
SELECT m.padre_id,
       (SELECT COALESCE(MAX(orden), 0) + 1 FROM seguridad.menus WHERE padre_id = m.padre_id),
       m.nivel,
       '🧩 Características',
       'inventarios/allCaracteristicas',
       'Lo que hay que rellenar en cada producto, por categoría',
       m.icono
  FROM seguridad.menus m
 WHERE m.url = 'inventarios/allMarcas'
   AND NOT EXISTS (SELECT 1 FROM seguridad.menus WHERE url = 'inventarios/allCaracteristicas');

-- Los mismos accesos que Marcas, para los mismos perfiles
INSERT INTO seguridad.accesos (perfil_id, menu_id, ver, crear, editar, eliminar, listar,
                               reporte, auditar, ejecutar, papelera, vaciar)
SELECT a.perfil_id,
       (SELECT id FROM seguridad.menus WHERE url = 'inventarios/allCaracteristicas'),
       a.ver, a.crear, a.editar, a.eliminar, a.listar,
       a.reporte, a.auditar, a.ejecutar, a.papelera, a.vaciar
  FROM seguridad.accesos a
 WHERE a.menu_id = (SELECT id FROM seguridad.menus WHERE url = 'inventarios/allMarcas')
   AND NOT EXISTS (
       SELECT 1 FROM seguridad.accesos x
        WHERE x.perfil_id = a.perfil_id
          AND x.menu_id = (SELECT id FROM seguridad.menus WHERE url = 'inventarios/allCaracteristicas'));

SELECT 'menú creado: id ' || id || ' · ' || nombre || ' · ' || url || ' · orden ' || orden
  FROM seguridad.menus WHERE url = 'inventarios/allCaracteristicas';

SELECT 'accesos: ' || string_agg(p.nombre || ' (ver=' || a.ver || ' crear=' || a.crear
       || ' editar=' || a.editar || ' eliminar=' || a.eliminar || ' papelera=' || a.papelera
       || ' vaciar=' || a.vaciar || ')', ', ')
  FROM seguridad.accesos a
  JOIN seguridad.perfiles p ON p.id = a.perfil_id
 WHERE a.menu_id = (SELECT id FROM seguridad.menus WHERE url = 'inventarios/allCaracteristicas');

COMMIT;
