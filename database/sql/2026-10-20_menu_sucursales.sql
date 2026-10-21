-- El menú y los accesos de «Sucursales» (ventas/allSucursales). Sin esto la
-- ruta cae en el 404 aunque el componente esté bien: el AccessResolver busca
-- el programa por el segundo tramo de la url (ventas/allSucursales ->
-- ALLSUCURSALES).
--
-- Se cuelga de Ventas, al lado de Zonas de Clientes, y los accesos se copian
-- de un CRUD completo —inventarios/allMarcas—, que es el estándar al que se
-- parece esta pantalla: ver/crear/editar/eliminar/listar/reporte/auditar/
-- ejecutar/papelera. `vaciar` NO se copia encendido a nadie: borrar de verdad
-- es otro permiso y se da a mano en Seguridad > Perfiles.
\set ON_ERROR_STOP on
\pset tuples_only on
\pset format unaligned

BEGIN;

INSERT INTO seguridad.menus (padre_id, orden, nivel, nombre, url, descripcion, icono, created_by, updated_by)
SELECT m.padre_id,
       (SELECT COALESCE(MAX(orden), 0) + 1 FROM seguridad.menus WHERE padre_id = m.padre_id),
       m.nivel,
       '🏢 Sucursales',
       'ventas/allSucursales',
       'Las sucursales y su perímetro en el mapa; dentro de él es donde su gente puede marcar asistencia',
       m.icono,
       'postgres', 'postgres'
  FROM seguridad.menus m
 WHERE m.url = 'ventas/allZonas'
   AND NOT EXISTS (SELECT 1 FROM seguridad.menus WHERE url = 'ventas/allSucursales');

-- Los accesos de un CRUD completo, para los perfiles que ya tienen uno
INSERT INTO seguridad.accesos (perfil_id, menu_id, ver, crear, editar, eliminar, listar,
                               reporte, auditar, ejecutar, papelera, vaciar)
SELECT a.perfil_id,
       (SELECT id FROM seguridad.menus WHERE url = 'ventas/allSucursales'),
       a.ver, a.crear, a.editar, a.eliminar, a.listar,
       a.reporte, a.auditar, a.ejecutar, a.papelera,
       false                      -- `vaciar` se da a mano, nunca heredado
  FROM seguridad.accesos a
 WHERE a.menu_id = (SELECT id FROM seguridad.menus WHERE url = 'inventarios/allMarcas')
   AND NOT EXISTS (
       SELECT 1 FROM seguridad.accesos x
        WHERE x.perfil_id = a.perfil_id
          AND x.menu_id = (SELECT id FROM seguridad.menus WHERE url = 'ventas/allSucursales'));

SELECT 'menú creado: id ' || id || ' · ' || nombre || ' · ' || url || ' · orden ' || orden
  FROM seguridad.menus WHERE url = 'ventas/allSucursales';

SELECT 'accesos: ' || string_agg(p.nombre || ' (ver=' || a.ver || ', papelera=' || a.papelera || ', vaciar=' || a.vaciar || ')', ', ')
  FROM seguridad.accesos a
  JOIN seguridad.perfiles p ON p.id = a.perfil_id
 WHERE a.menu_id = (SELECT id FROM seguridad.menus WHERE url = 'ventas/allSucursales');

COMMIT;

-- ===========================================================================
-- DESPUÉS DE ESTO
-- ===========================================================================
-- 1. Crear la sucursal y DIBUJARLE EL PERÍMETRO. Sin perímetro, su gente
--    puede marcar asistencia desde cualquier lugar: la pantalla lo avisa,
--    pero no lo impide (hay locales que no lo quieren).
--
-- 2. Asignar la sucursal a cada empleado (Empleados > ACCIONES > Sucursal, o
--    rh.fn_empleados_asignar_sucursal). Quien no tenga sucursal marca como
--    hasta ahora, sin control de ubicación.
--
-- 3. El control se aplica a las marcaciones que NO son manuales: desde el
--    kiosco y desde el celular. Con `p_origen = 'MANUAL'` —la marcación que
--    alguien de RRHH registra a mano— no se exige estar dentro, porque quien
--    la registra no es quien estaba allí.
-- ===========================================================================
