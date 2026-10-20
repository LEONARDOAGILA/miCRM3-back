-- El menú y los accesos de «Registro de marcaciones» (el celular del
-- empleado). Sin esto la ruta cae en el 404 aunque el componente esté bien:
-- el AccessResolver busca el programa por el segundo tramo de la url.
--
-- Se cuelga de Recursos Humanos, al lado del kiosco, y se copian los accesos
-- TAL CUAL los tiene el kiosco. OJO: esta pantalla la tiene que ver TODO EL
-- QUE MARQUE, así que lo normal es darle después `ver` a los perfiles de los
-- empleados (en Seguridad > Perfiles), no sólo a quien administra RRHH.
\set ON_ERROR_STOP on
\pset tuples_only on
\pset format unaligned

BEGIN;

INSERT INTO seguridad.menus (padre_id, orden, nivel, nombre, url, descripcion, icono)
SELECT m.padre_id,
       (SELECT COALESCE(MAX(orden), 0) + 1 FROM seguridad.menus WHERE padre_id = m.padre_id),
       m.nivel,
       '📱 Marcar desde mi celular',
       'rh/registroMarcaciones',
       'Cada empleado registra su entrada o salida desde su propio teléfono',
       m.icono
  FROM seguridad.menus m
 WHERE m.url = 'rh/kioscoMarcacion'
   AND NOT EXISTS (SELECT 1 FROM seguridad.menus WHERE url = 'rh/registroMarcaciones');

-- Los mismos accesos que el kiosco, para los mismos perfiles
INSERT INTO seguridad.accesos (perfil_id, menu_id, ver, crear, editar, eliminar, listar,
                               reporte, auditar, ejecutar, papelera, vaciar)
SELECT a.perfil_id,
       (SELECT id FROM seguridad.menus WHERE url = 'rh/registroMarcaciones'),
       a.ver, a.crear, a.editar, a.eliminar, a.listar,
       a.reporte, a.auditar, a.ejecutar, a.papelera, a.vaciar
  FROM seguridad.accesos a
 WHERE a.menu_id = (SELECT id FROM seguridad.menus WHERE url = 'rh/kioscoMarcacion')
   AND NOT EXISTS (
       SELECT 1 FROM seguridad.accesos x
        WHERE x.perfil_id = a.perfil_id
          AND x.menu_id = (SELECT id FROM seguridad.menus WHERE url = 'rh/registroMarcaciones'));

SELECT 'menú creado: id ' || id || ' · ' || nombre || ' · ' || url || ' · orden ' || orden
  FROM seguridad.menus WHERE url = 'rh/registroMarcaciones';

SELECT 'accesos: ' || string_agg(p.nombre || ' (ver=' || a.ver || ')', ', ')
  FROM seguridad.accesos a
  JOIN seguridad.perfiles p ON p.id = a.perfil_id
 WHERE a.menu_id = (SELECT id FROM seguridad.menus WHERE url = 'rh/registroMarcaciones');

COMMIT;

-- ===========================================================================
-- PARA QUE CADA EMPLEADO PUEDA MARCAR DESDE SU CELULAR
-- ===========================================================================
-- La pantalla pregunta al servidor QUIÉN ES quien ha entrado, y eso sale de
-- seguridad.users.empleado_id (y si está vacío, del correo). Hoy no hay
-- NINGÚN usuario enlazado, así que hay que enlazarlos; por ejemplo:
--
--     UPDATE seguridad.users SET empleado_id = 2 WHERE login_user = 'LAGILA';
--
-- O por correo, para los que coincidan:
--
--     UPDATE seguridad.users u
--        SET empleado_id = e.id
--       FROM rh.empleados e
--      WHERE u.empleado_id IS NULL
--        AND LOWER(u.email) = LOWER(e.email);
--
-- Y cada empleado necesita su rostro registrado (Empleados > botón
-- «Registrar rostro») y el acceso `ver` a esta pantalla en su perfil.
-- ===========================================================================
