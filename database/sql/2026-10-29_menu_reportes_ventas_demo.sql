-- El menú y los accesos del tablero. Sin esto la ruta cae en el 404 aunque el
-- componente esté bien: el AccessResolver busca el programa, y el programa
-- sale del SEGUNDO tramo de la url (reportes/ventasDemo → VENTASDEMO).
--
-- Se cuelga de «Archivos» (menú 2, que es el que ya apunta al módulo
-- reportes) y se copian los accesos TAL CUAL los tiene ese padre: quien ve
-- los archivos ve los tableros. `reporte` es el permiso que enciende los
-- botones de imprimir/Excel/CSV.
\set ON_ERROR_STOP on
\pset tuples_only on
\pset format unaligned

BEGIN;

INSERT INTO seguridad.menus (padre_id, orden, nivel, nombre, url, descripcion, icono)
SELECT m.id,
       (SELECT COALESCE(MAX(orden), 0) + 1 FROM seguridad.menus WHERE padre_id = m.id),
       m.nivel + 1,
       '📊 Ventas (demo)',
       'reportes/ventasDemo',
       'Tablero de ejemplo: tabla dinámica y gráfico sobre ventas inventadas',
       m.icono
  FROM seguridad.menus m
 WHERE m.id = 2
   AND NOT EXISTS (SELECT 1 FROM seguridad.menus WHERE url = 'reportes/ventasDemo');

-- Los mismos accesos que su padre, para los mismos perfiles
INSERT INTO seguridad.accesos (perfil_id, menu_id, ver, crear, editar, eliminar, listar,
                               reporte, auditar, ejecutar, papelera, vaciar)
SELECT a.perfil_id,
       (SELECT id FROM seguridad.menus WHERE url = 'reportes/ventasDemo'),
       a.ver, a.crear, a.editar, a.eliminar, a.listar,
       a.reporte, a.auditar, a.ejecutar, a.papelera, a.vaciar
  FROM seguridad.accesos a
 WHERE a.menu_id = 2
   AND NOT EXISTS (
       SELECT 1 FROM seguridad.accesos x
        WHERE x.perfil_id = a.perfil_id
          AND x.menu_id = (SELECT id FROM seguridad.menus WHERE url = 'reportes/ventasDemo'));

SELECT 'menú creado: id ' || id || ' · ' || nombre || ' · ' || url || ' · nivel ' || nivel
  FROM seguridad.menus WHERE url = 'reportes/ventasDemo';

SELECT 'accesos: ' || string_agg(p.nombre || ' (ver=' || a.ver || ' reporte=' || a.reporte || ')', ', ')
  FROM seguridad.accesos a
  JOIN seguridad.perfiles p ON p.id = a.perfil_id
 WHERE a.menu_id = (SELECT id FROM seguridad.menus WHERE url = 'reportes/ventasDemo');

COMMIT;
