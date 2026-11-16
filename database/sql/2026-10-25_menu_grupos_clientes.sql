-- El menú y los accesos de «Grupos de Clientes» (ventas/allGruposClientes).
-- Sin esto la ruta cae en el 404 aunque el componente esté bien: el
-- AccessResolver busca el programa por el segundo tramo de la url
-- (ventas/allGruposClientes -> ALLGRUPOSCLIENTES).
--
-- Se cuelga junto a «Mante. Clientes», que es desde donde se asigna el grupo,
-- y los accesos se copian de ventas/allClientes tal cual: esta pantalla tiene
-- papelera y vaciado igual que la de categorías, así que esos dos permisos se
-- respetan como estén en clientes.
\set ON_ERROR_STOP on
\pset tuples_only on
\pset format unaligned

BEGIN;

INSERT INTO seguridad.menus (padre_id, orden, nivel, nombre, url, descripcion, icono, created_by, updated_by)
SELECT m.padre_id,
       (SELECT COALESCE(MAX(orden), 0) + 1 FROM seguridad.menus WHERE padre_id = m.padre_id),
       m.nivel,
       '👥 Grupos de Clientes',
       'ventas/allGruposClientes',
       'Árbol de grupos comerciales: forma de pago, cupo de crédito, días de crédito y descuento que heredan los clientes del grupo',
       m.icono,
       'postgres', 'postgres'
  FROM seguridad.menus m
 WHERE m.url = 'ventas/allClientes'
   AND NOT EXISTS (SELECT 1 FROM seguridad.menus WHERE url = 'ventas/allGruposClientes');

INSERT INTO seguridad.accesos (perfil_id, menu_id, ver, crear, editar, eliminar, listar,
                               reporte, auditar, ejecutar, papelera, vaciar)
SELECT a.perfil_id,
       (SELECT id FROM seguridad.menus WHERE url = 'ventas/allGruposClientes'),
       a.ver, a.crear, a.editar, a.eliminar, a.listar,
       a.reporte, a.auditar, a.ejecutar, a.papelera, a.vaciar
  FROM seguridad.accesos a
 WHERE a.menu_id = (SELECT id FROM seguridad.menus WHERE url = 'ventas/allClientes')
   AND NOT EXISTS (
       SELECT 1 FROM seguridad.accesos x
        WHERE x.perfil_id = a.perfil_id
          AND x.menu_id = (SELECT id FROM seguridad.menus WHERE url = 'ventas/allGruposClientes'));

SELECT 'menú creado: id ' || id || ' · ' || nombre || ' · ' || url || ' · padre ' || padre_id || ' · orden ' || orden
  FROM seguridad.menus WHERE url = 'ventas/allGruposClientes';

SELECT 'accesos: ' || string_agg(p.nombre || ' (ver=' || a.ver || ', papelera=' || a.papelera || ', vaciar=' || a.vaciar || ')', ', ' ORDER BY p.nombre)
  FROM seguridad.accesos a
  JOIN seguridad.perfiles p ON p.id = a.perfil_id
 WHERE a.menu_id = (SELECT id FROM seguridad.menus WHERE url = 'ventas/allGruposClientes');

COMMIT;
