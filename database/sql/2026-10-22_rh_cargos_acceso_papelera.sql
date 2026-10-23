-- ===========================================================================
-- EL ACCESO «papelera» EN LA PANTALLA DE CARGOS
-- ===========================================================================
-- La pantalla ya tiene papelera de reciclaje, pero el botón sólo sale con el
-- acceso `papelera` del perfil, y en rh/allCargos nadie lo tenía salvo
-- PRUEBA. Se le da a los perfiles que YA pueden eliminar cargos: quien puede
-- mandar a la papelera tiene que poder entrar a sacarlos.
--
-- `vaciar` NO se toca: borrar de verdad es otro permiso y se da a mano en
-- Seguridad > Perfiles, como en el resto de pantallas.
\set ON_ERROR_STOP on
\pset tuples_only on
\pset format unaligned

BEGIN;

UPDATE seguridad.accesos a
   SET papelera = true
  FROM seguridad.menus m
 WHERE m.id = a.menu_id
   AND m.url = 'rh/allCargos'
   AND a.eliminar = true
   AND a.papelera = false;

SELECT 'accesos de rh/allCargos: '
    || string_agg(p.nombre || ' (eliminar=' || a.eliminar || ', papelera=' || a.papelera || ', vaciar=' || a.vaciar || ')', ', ' ORDER BY p.nombre)
  FROM seguridad.accesos a
  JOIN seguridad.perfiles p ON p.id = a.perfil_id
  JOIN seguridad.menus m ON m.id = a.menu_id
 WHERE m.url = 'rh/allCargos';

COMMIT;
