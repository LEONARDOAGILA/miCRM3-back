-- ===========================================================================
-- MENÚ DE «RESPUESTAS DE WHATSAPP»
-- ===========================================================================
-- Fecha: 2026-10-05
--
-- La pantalla que mantiene ventas.whatsapp_plantillas
-- (ver 2026-10-05_ventas_whatsapp_plantillas.sql) ya existe en Angular, pero
-- una ruta sin menú no se puede abrir: el AccessResolver busca el perfil en
-- seguridad.accesos y, si no encuentra fila con ejecutar = true, manda a
-- access-deny. Y el menú lateral tampoco la enseña. Así que la pantalla no es
-- la pantalla hasta que está aquí.
--
-- Va de cuarta hija de Ventas (58), detrás del catálogo de gestiones: las dos
-- son mantenimiento, y el vendedor no entra en ninguna.
--
-- Los permisos no se escriben a mano, se copian de «Catálogo de Gestiones»:
-- es la pantalla análoga y quien mantiene una mantiene la otra. Si mañana se
-- revisa quién administra ventas, se revisa en un sitio y no en dos.
--
-- Se puede volver a ejecutar sin duplicar nada.
-- ===========================================================================

BEGIN;

-- 1. El menú ------------------------------------------------------------------
-- descripcion, etiqueta e icono se quedan vacíos como en los otros hijos de
-- Ventas: el emoji del nombre ya hace de icono.
INSERT INTO seguridad.menus (padre_id, orden, nivel, nombre, url, created_by, updated_by)
SELECT 58, 4, 1, '💬 Respuestas de WhatsApp', 'ventas/plantillasWhatsapp', 'LAGILA', 'LAGILA'
 WHERE NOT EXISTS (
       SELECT 1 FROM seguridad.menus WHERE url = 'ventas/plantillasWhatsapp');

-- 2. Los accesos, calcados del catálogo de gestiones --------------------------
INSERT INTO seguridad.accesos (
            perfil_id, menu_id,
            ver, crear, editar, eliminar, listar, reporte, auditar, ejecutar, papelera,
            created_by, updated_by)
SELECT a.perfil_id,
       (SELECT id FROM seguridad.menus WHERE url = 'ventas/plantillasWhatsapp'),
       a.ver, a.crear, a.editar, a.eliminar, a.listar, a.reporte, a.auditar, a.ejecutar, a.papelera,
       'LAGILA', 'LAGILA'
  FROM seguridad.accesos a
 WHERE a.menu_id = (SELECT id FROM seguridad.menus WHERE url = 'ventas/catalogoGestion')
   AND NOT EXISTS (
       SELECT 1
         FROM seguridad.accesos x
        WHERE x.perfil_id = a.perfil_id
          AND x.menu_id = (SELECT id FROM seguridad.menus WHERE url = 'ventas/plantillasWhatsapp'));

COMMIT;

-- 3. Cómo queda ---------------------------------------------------------------
SELECT m.id, m.padre_id, m.orden, m.nivel, m.nombre, m.url
  FROM seguridad.menus m
 WHERE m.padre_id = 58
 ORDER BY m.orden;

SELECT p.id AS perfil_id, p.nombre AS perfil,
       a.ver, a.crear, a.editar, a.eliminar, a.listar, a.ejecutar
  FROM seguridad.accesos a
  JOIN seguridad.perfiles p ON p.id = a.perfil_id
 WHERE a.menu_id = (SELECT id FROM seguridad.menus WHERE url = 'ventas/plantillasWhatsapp')
 ORDER BY p.id;
