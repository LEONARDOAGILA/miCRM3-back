-- El menú y los accesos de «Horarios» (rh/allHorariosEmpleados). Sin esto la
-- ruta cae en el 404 aunque el componente esté bien: el AccessResolver busca
-- el programa por el segundo tramo de la url (rh/allHorariosEmpleados ->
-- ALLHORARIOSEMPLEADOS).
--
-- Se cuelga de RRHH, detrás de Marcaciones —que es con lo que se cruza para
-- sacar los atrasos—, y los accesos se copian de rh/allCargos, que es el CRUD
-- del mismo módulo. `vaciar` NO se copia encendido a nadie: borrar de verdad
-- es otro permiso y se da a mano en Seguridad > Perfiles.
\set ON_ERROR_STOP on
\pset tuples_only on
\pset format unaligned

BEGIN;

INSERT INTO seguridad.menus (padre_id, orden, nivel, nombre, url, descripcion, icono, created_by, updated_by)
SELECT m.padre_id,
       (SELECT COALESCE(MAX(orden), 0) + 1 FROM seguridad.menus WHERE padre_id = m.padre_id),
       m.nivel,
       '🕗 Horarios',
       'rh/allHorariosEmpleados',
       'Los horarios de trabajo del personal, hasta cuatro jornadas por día; con ellos se miden los atrasos de las marcaciones',
       m.icono,
       'postgres', 'postgres'
  FROM seguridad.menus m
 WHERE m.url = 'rh/allCargos'
   AND NOT EXISTS (SELECT 1 FROM seguridad.menus WHERE url = 'rh/allHorariosEmpleados');

-- Los accesos de un CRUD completo, para los perfiles que ya tienen uno
INSERT INTO seguridad.accesos (perfil_id, menu_id, ver, crear, editar, eliminar, listar,
                               reporte, auditar, ejecutar, papelera, vaciar)
SELECT a.perfil_id,
       (SELECT id FROM seguridad.menus WHERE url = 'rh/allHorariosEmpleados'),
       a.ver, a.crear, a.editar, a.eliminar, a.listar,
       a.reporte, a.auditar, a.ejecutar, a.papelera,
       false                      -- `vaciar` se da a mano, nunca heredado
  FROM seguridad.accesos a
 WHERE a.menu_id = (SELECT id FROM seguridad.menus WHERE url = 'rh/allCargos')
   AND NOT EXISTS (
       SELECT 1 FROM seguridad.accesos x
        WHERE x.perfil_id = a.perfil_id
          AND x.menu_id = (SELECT id FROM seguridad.menus WHERE url = 'rh/allHorariosEmpleados'));

SELECT 'menú creado: id ' || id || ' · ' || nombre || ' · ' || url || ' · orden ' || orden
  FROM seguridad.menus WHERE url = 'rh/allHorariosEmpleados';

SELECT 'accesos: ' || string_agg(p.nombre || ' (ver=' || a.ver || ', papelera=' || a.papelera || ', vaciar=' || a.vaciar || ')', ', ' ORDER BY p.nombre)
  FROM seguridad.accesos a
  JOIN seguridad.perfiles p ON p.id = a.perfil_id
 WHERE a.menu_id = (SELECT id FROM seguridad.menus WHERE url = 'rh/allHorariosEmpleados');

COMMIT;
