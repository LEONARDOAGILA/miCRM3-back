-- El menú y los accesos del «Plan de Cuentas» (contabilidad/allPlanCuentas).
-- Sin esto la ruta cae en el 404 aunque el componente esté bien: el
-- AccessResolver busca el programa por el segundo tramo de la url
-- (contabilidad/allPlanCuentas -> ALLPLANCUENTAS).
--
-- El nodo del módulo «Contabilidad» ya existe (id 61, contabilidad/home-contabilidad)
-- y ya tiene accesos, así que aquí sólo se cuelga la pantalla. Los accesos se
-- copian de inventarios/allCategorias, que es el mismo CRUD de árbol del que
-- sale este. `vaciar` NO se copia encendido a nadie: borrar de verdad es otro
-- permiso y se da a mano en Seguridad > Perfiles.
\set ON_ERROR_STOP on
\pset tuples_only on
\pset format unaligned

BEGIN;

INSERT INTO seguridad.menus (padre_id, orden, nivel, nombre, url, descripcion, icono, created_by, updated_by)
SELECT m.id,
       (SELECT COALESCE(MAX(orden), 0) + 1 FROM seguridad.menus WHERE padre_id = m.id),
       m.nivel + 1,
       '🧾 Plan de Cuentas',
       'contabilidad/allPlanCuentas',
       'El árbol de cuentas contables, sin tope de niveles: código, tipo, naturaleza y qué cuentas reciben asientos',
       m.icono,
       'postgres', 'postgres'
  FROM seguridad.menus m
 WHERE m.url = 'contabilidad/home-contabilidad'
   AND NOT EXISTS (SELECT 1 FROM seguridad.menus WHERE url = 'contabilidad/allPlanCuentas');

-- Los accesos de un CRUD de árbol, para los perfiles que ya tienen el de categorías
INSERT INTO seguridad.accesos (perfil_id, menu_id, ver, crear, editar, eliminar, listar,
                               reporte, auditar, ejecutar, papelera, vaciar)
SELECT a.perfil_id,
       (SELECT id FROM seguridad.menus WHERE url = 'contabilidad/allPlanCuentas'),
       a.ver, a.crear, a.editar, a.eliminar, a.listar,
       a.reporte, a.auditar, a.ejecutar, a.papelera,
       false                      -- `vaciar` se da a mano, nunca heredado
  FROM seguridad.accesos a
 WHERE a.menu_id = (SELECT id FROM seguridad.menus WHERE url = 'inventarios/allCategorias')
   AND NOT EXISTS (
       SELECT 1 FROM seguridad.accesos x
        WHERE x.perfil_id = a.perfil_id
          AND x.menu_id = (SELECT id FROM seguridad.menus WHERE url = 'contabilidad/allPlanCuentas'));

SELECT 'menú creado: id ' || id || ' · ' || nombre || ' · ' || url || ' · padre ' || padre_id || ' · orden ' || orden
  FROM seguridad.menus WHERE url = 'contabilidad/allPlanCuentas';

SELECT 'accesos: ' || string_agg(p.nombre || ' (ver=' || a.ver || ', papelera=' || a.papelera || ', vaciar=' || a.vaciar || ')', ', ' ORDER BY p.nombre)
  FROM seguridad.accesos a
  JOIN seguridad.perfiles p ON p.id = a.perfil_id
 WHERE a.menu_id = (SELECT id FROM seguridad.menus WHERE url = 'contabilidad/allPlanCuentas');

COMMIT;
