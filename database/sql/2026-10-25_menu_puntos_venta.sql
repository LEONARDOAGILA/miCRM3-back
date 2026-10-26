-- El menú y los accesos de «Puntos de Venta» (ventas/allPuntosVenta).
--
-- Sin esto la ruta cae en el 404 aunque el componente esté bien: el
-- AccessResolver busca el programa por el segundo tramo de la url
-- (ventas/allPuntosVenta -> ALLPUNTOSVENTA).
--
-- DÓNDE CUELGA: de «Ventas», junto a Sucursales, porque un punto de venta es
-- una caja de una sucursal y es ahí donde se va a buscar. Si se prefiere
-- tenerlo con lo contable, se mueve con un UPDATE del padre_id al 61
-- (Contabilidad); la url no cambia.
--
-- QUIÉN LO VE: los accesos se copian de contabilidad/allPlanCuentas y NO de
-- la pantalla de clientes. Las cajas las crean los contadores —son ellos los
-- que saben qué cuenta va en cada concepto—, así que hereda exactamente los
-- permisos que hoy tiene quien mantiene el plan de cuentas. Un vendedor no
-- verá la opción.
\set ON_ERROR_STOP on
\pset tuples_only on
\pset format unaligned

BEGIN;

INSERT INTO seguridad.menus (padre_id, orden, nivel, nombre, url, descripcion, icono, created_by, updated_by)
SELECT 58,
       (SELECT COALESCE(MAX(orden), 0) + 1 FROM seguridad.menus WHERE padre_id = 58),
       1,
       '🧰 Puntos de Venta',
       'ventas/allPuntosVenta',
       'Las cajas de cada sucursal y las cuentas contables con las que asienta cada una (efectivo, tarjetas, banco, sobrantes y faltantes)',
       'fa-solid fa-cash-register',
       'postgres', 'postgres'
 WHERE NOT EXISTS (SELECT 1 FROM seguridad.menus WHERE url = 'ventas/allPuntosVenta');

INSERT INTO seguridad.accesos (perfil_id, menu_id, ver, crear, editar, eliminar, listar,
                               reporte, auditar, ejecutar, papelera, vaciar)
SELECT a.perfil_id,
       (SELECT id FROM seguridad.menus WHERE url = 'ventas/allPuntosVenta'),
       a.ver, a.crear, a.editar, a.eliminar, a.listar,
       a.reporte, a.auditar, a.ejecutar, a.papelera, a.vaciar
  FROM seguridad.accesos a
 WHERE a.menu_id = (SELECT id FROM seguridad.menus WHERE url = 'contabilidad/allPlanCuentas')
   AND NOT EXISTS (
       SELECT 1 FROM seguridad.accesos x
        WHERE x.perfil_id = a.perfil_id
          AND x.menu_id = (SELECT id FROM seguridad.menus WHERE url = 'ventas/allPuntosVenta'));

SELECT 'menú creado: id ' || id || ' · ' || nombre || ' · ' || url || ' · padre ' || padre_id || ' · orden ' || orden
  FROM seguridad.menus WHERE url = 'ventas/allPuntosVenta';

SELECT 'accesos: ' || string_agg(p.nombre || ' (ver=' || a.ver || ', crear=' || a.crear || ', papelera=' || a.papelera || ', vaciar=' || a.vaciar || ')', ', ' ORDER BY p.nombre)
  FROM seguridad.accesos a
  JOIN seguridad.perfiles p ON p.id = a.perfil_id
 WHERE a.menu_id = (SELECT id FROM seguridad.menus WHERE url = 'ventas/allPuntosVenta');

COMMIT;
