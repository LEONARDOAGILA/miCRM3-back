-- El menú y los accesos de la pantalla nueva. Sin esto la ruta cae en el 404
-- aunque el componente esté bien: el AccessResolver busca el programa, y el
-- programa sale del segundo tramo de la url (ventas/rutaCobrador).
--
-- Se cuelga de «Ventas» (padre 58) detrás de Zonas de Clientes, y se copian
-- los accesos TAL CUAL los tiene Zonas: quien puede ver el mapa de zonas
-- puede ver por dónde anduvo un cobrador. Es una pantalla de sólo lectura
-- —no hay nada que crear ni borrar desde aquí—, pero los permisos se copian
-- enteros para no inventar un criterio distinto al del resto del módulo.
\set ON_ERROR_STOP on
\pset tuples_only on
\pset format unaligned

BEGIN;

INSERT INTO seguridad.menus (padre_id, orden, nivel, nombre, url, descripcion, icono)
SELECT m.padre_id,
       (SELECT COALESCE(MAX(orden), 0) + 1 FROM seguridad.menus WHERE padre_id = m.padre_id),
       m.nivel,
       '🛵 Ruta del Cobrador',
       'ventas/rutaCobrador',
       'Por dónde anduvo cada cobrador, dónde se detuvo y con qué cliente coincide cada parada',
       m.icono
  FROM seguridad.menus m
 WHERE m.url = 'ventas/allZonas'
   AND NOT EXISTS (SELECT 1 FROM seguridad.menus WHERE url = 'ventas/rutaCobrador');

-- Los mismos accesos que Zonas, para los mismos perfiles
INSERT INTO seguridad.accesos (perfil_id, menu_id, ver, crear, editar, eliminar, listar,
                               reporte, auditar, ejecutar, papelera, vaciar)
SELECT a.perfil_id,
       (SELECT id FROM seguridad.menus WHERE url = 'ventas/rutaCobrador'),
       a.ver, a.crear, a.editar, a.eliminar, a.listar,
       a.reporte, a.auditar, a.ejecutar, a.papelera, a.vaciar
  FROM seguridad.accesos a
 WHERE a.menu_id = (SELECT id FROM seguridad.menus WHERE url = 'ventas/allZonas')
   AND NOT EXISTS (
       SELECT 1 FROM seguridad.accesos x
        WHERE x.perfil_id = a.perfil_id
          AND x.menu_id = (SELECT id FROM seguridad.menus WHERE url = 'ventas/rutaCobrador'));

SELECT 'menú creado: id ' || id || ' · ' || nombre || ' · ' || url || ' · orden ' || orden
  FROM seguridad.menus WHERE url = 'ventas/rutaCobrador';

SELECT 'accesos: ' || string_agg(p.nombre || ' (ver=' || a.ver || ')', ', ')
  FROM seguridad.accesos a
  JOIN seguridad.perfiles p ON p.id = a.perfil_id
 WHERE a.menu_id = (SELECT id FROM seguridad.menus WHERE url = 'ventas/rutaCobrador');

COMMIT;
