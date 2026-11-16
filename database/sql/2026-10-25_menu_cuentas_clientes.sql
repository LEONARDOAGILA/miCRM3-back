-- El menú y los accesos de «Cuentas por Cliente»
-- (contabilidad/allCuentasClientes). Sin esto la ruta cae en el 404 aunque
-- el componente esté bien: el AccessResolver busca el programa por el segundo
-- tramo de la url (contabilidad/allCuentasClientes -> ALLCUENTASCLIENTES).
--
-- Se cuelga de Contabilidad, detrás de «Cuentas por Categoría» —que es su
-- hermana: una mira el producto que se vende y la otra el cliente al que se
-- le vende—, y los accesos se copian de ella.
\set ON_ERROR_STOP on
\pset tuples_only on
\pset format unaligned

BEGIN;

INSERT INTO seguridad.menus (padre_id, orden, nivel, nombre, url, descripcion, icono, created_by, updated_by)
SELECT m.padre_id,
       (SELECT COALESCE(MAX(orden), 0) + 1 FROM seguridad.menus WHERE padre_id = m.padre_id),
       m.nivel,
       '🧾 Cuentas por Cliente',
       'contabilidad/allCuentasClientes',
       'Con qué cuentas contables se asienta cada grupo de clientes: cuenta por cobrar, anticipos, intereses por mora e incobrables',
       m.icono,
       'postgres', 'postgres'
  FROM seguridad.menus m
 WHERE m.url = 'contabilidad/allCuentasCategorias'
   AND NOT EXISTS (SELECT 1 FROM seguridad.menus WHERE url = 'contabilidad/allCuentasClientes');

INSERT INTO seguridad.accesos (perfil_id, menu_id, ver, crear, editar, eliminar, listar,
                               reporte, auditar, ejecutar, papelera, vaciar)
SELECT a.perfil_id,
       (SELECT id FROM seguridad.menus WHERE url = 'contabilidad/allCuentasClientes'),
       a.ver, a.crear, a.editar, a.eliminar, a.listar,
       a.reporte, a.auditar, a.ejecutar,
       false,                     -- aquí no hay papelera
       false                      -- ni nada que vaciar
  FROM seguridad.accesos a
 WHERE a.menu_id = (SELECT id FROM seguridad.menus WHERE url = 'contabilidad/allCuentasCategorias')
   AND NOT EXISTS (
       SELECT 1 FROM seguridad.accesos x
        WHERE x.perfil_id = a.perfil_id
          AND x.menu_id = (SELECT id FROM seguridad.menus WHERE url = 'contabilidad/allCuentasClientes'));

SELECT 'menú creado: id ' || id || ' · ' || nombre || ' · ' || url || ' · padre ' || padre_id || ' · orden ' || orden
  FROM seguridad.menus WHERE url = 'contabilidad/allCuentasClientes';

SELECT 'accesos: ' || string_agg(p.nombre || ' (ver=' || a.ver || ', editar=' || a.editar || ')', ', ' ORDER BY p.nombre)
  FROM seguridad.accesos a
  JOIN seguridad.perfiles p ON p.id = a.perfil_id
 WHERE a.menu_id = (SELECT id FROM seguridad.menus WHERE url = 'contabilidad/allCuentasClientes');

COMMIT;
