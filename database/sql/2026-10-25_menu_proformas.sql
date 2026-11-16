-- El menú y los accesos de «Proformas» (ventas/allProformas).
--
-- Sin esto la ruta cae en el 404 aunque el componente esté bien: el
-- AccessResolver busca el programa por el segundo tramo de la url
-- (ventas/allProformas -> ALLPROFORMAS).
--
-- Va colgado de «Ventas» y no dentro de «Clientes»: una proforma no es
-- mantenimiento de un cliente, es el documento con el que se vende. Queda
-- después de Sucursales, al final de lo que ya hay.
--
-- Los accesos se copian de ventas/allClientes, que es la pantalla de ventas
-- que todos los perfiles que venden ya tienen: así nadie se queda sin entrar
-- y, sobre todo, el permiso «vaciar» —el único que el back exige aparte, por
-- ser el que no tiene vuelta atrás— llega tal como esté allí y no abierto a
-- todo el mundo.
\set ON_ERROR_STOP on
\pset tuples_only on
\pset format unaligned

BEGIN;

INSERT INTO seguridad.menus (padre_id, orden, nivel, nombre, url, descripcion, icono, created_by, updated_by)
SELECT 58,
       (SELECT COALESCE(MAX(orden), 0) + 1 FROM seguridad.menus WHERE padre_id = 58),
       1,
       '📄 Proformas',
       'ventas/allProformas',
       'Cotizaciones a clientes: cabecera, líneas con producto, cantidad, precio, descuento e IVA, y su ciclo de vida (borrador, enviada, aprobada, rechazada, vencida, anulada)',
       'fa-solid fa-file-invoice-dollar',
       'postgres', 'postgres'
 WHERE NOT EXISTS (SELECT 1 FROM seguridad.menus WHERE url = 'ventas/allProformas');

INSERT INTO seguridad.accesos (perfil_id, menu_id, ver, crear, editar, eliminar, listar,
                               reporte, auditar, ejecutar, papelera, vaciar)
SELECT a.perfil_id,
       (SELECT id FROM seguridad.menus WHERE url = 'ventas/allProformas'),
       a.ver, a.crear, a.editar, a.eliminar, a.listar,
       a.reporte, a.auditar, a.ejecutar, a.papelera, a.vaciar
  FROM seguridad.accesos a
 WHERE a.menu_id = (SELECT id FROM seguridad.menus WHERE url = 'ventas/allClientes')
   AND NOT EXISTS (
       SELECT 1 FROM seguridad.accesos x
        WHERE x.perfil_id = a.perfil_id
          AND x.menu_id = (SELECT id FROM seguridad.menus WHERE url = 'ventas/allProformas'));

SELECT 'menú creado: id ' || id || ' · ' || nombre || ' · ' || url || ' · padre ' || padre_id || ' · orden ' || orden
  FROM seguridad.menus WHERE url = 'ventas/allProformas';

SELECT 'accesos: ' || string_agg(p.nombre || ' (ver=' || a.ver || ', crear=' || a.crear || ', papelera=' || a.papelera || ', vaciar=' || a.vaciar || ')', ', ' ORDER BY p.nombre)
  FROM seguridad.accesos a
  JOIN seguridad.perfiles p ON p.id = a.perfil_id
 WHERE a.menu_id = (SELECT id FROM seguridad.menus WHERE url = 'ventas/allProformas');

COMMIT;
