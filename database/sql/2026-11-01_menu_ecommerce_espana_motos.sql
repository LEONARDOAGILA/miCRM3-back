-- ============================================================================
-- MENÚ: Ecommerce → España Motos
-- ----------------------------------------------------------------------------
-- La pantalla ya existe en el front (ecommerce/editEspanaMotos) y el back ya
-- responde, pero sin esta fila la ruta cae en el 404 de «sin acceso».
--
-- Los permisos se copian de «Categorías de la tienda», que es la pantalla de
-- ecommerce más parecida: quien administra el catálogo de la tienda es quien
-- administra este micro-sitio.
--
-- Se puede volver a ejecutar sin romper nada.
-- ============================================================================
\set ON_ERROR_STOP on
\pset tuples_only on
\pset format unaligned
BEGIN;

INSERT INTO seguridad.menus (padre_id, orden, nivel, nombre, url, descripcion, icono)
SELECT p.id, 4, 1, '🏍️ España Motos', 'ecommerce/editEspanaMotos',
       'El micro-sitio de España Motos: portada, pestañas del catálogo y marcas', '-'
  FROM seguridad.menus p
 WHERE p.nivel = 0 AND p.nombre = 'Ecommerce'
   AND NOT EXISTS (SELECT 1 FROM seguridad.menus WHERE url = 'ecommerce/editEspanaMotos');

INSERT INTO seguridad.accesos (perfil_id, menu_id, ver, crear, editar, eliminar, listar,
                               reporte, auditar, ejecutar, papelera, vaciar)
SELECT a.perfil_id, (SELECT id FROM seguridad.menus WHERE url = 'ecommerce/editEspanaMotos'),
       a.ver, a.crear, a.editar, a.eliminar, a.listar,
       a.reporte, a.auditar, a.ejecutar, a.papelera, a.vaciar
  FROM seguridad.accesos a
 WHERE a.menu_id = (SELECT id FROM seguridad.menus WHERE url = 'ecommerce/allCategoriasWeb')
   AND NOT EXISTS (SELECT 1 FROM seguridad.accesos x
                    WHERE x.perfil_id = a.perfil_id
                      AND x.menu_id = (SELECT id FROM seguridad.menus
                                        WHERE url = 'ecommerce/editEspanaMotos'));

-- ---------------------------------------------------------------------------
-- Comprobación: que la fila esté y que alguien pueda abrirla. Las cuentas se
-- calculan siempre, para que un NULL no deje pasar la comprobación en verde.
-- ---------------------------------------------------------------------------
DO $c$
DECLARE
    v_menu   bigint;
    v_padre  bigint;
    v_quien  integer;
BEGIN
    SELECT id INTO v_menu  FROM seguridad.menus WHERE url = 'ecommerce/editEspanaMotos';
    IF v_menu IS NULL THEN
        RAISE EXCEPTION 'No se creó el menú de España Motos (¿existe el padre Ecommerce?)';
    END IF;

    SELECT padre_id INTO v_padre FROM seguridad.menus WHERE id = v_menu;
    IF v_padre IS NULL
       OR v_padre <> (SELECT id FROM seguridad.menus WHERE nivel = 0 AND nombre = 'Ecommerce') THEN
        RAISE EXCEPTION 'El menú no quedó colgado de Ecommerce';
    END IF;

    SELECT count(*) INTO v_quien
      FROM seguridad.accesos WHERE menu_id = v_menu AND ejecutar;
    IF v_quien IS NULL OR v_quien = 0 THEN
        RAISE EXCEPTION 'Ningún perfil puede abrir España Motos';
    END IF;

    RAISE NOTICE 'Comprobado: menú % bajo Ecommerce y % perfiles pueden abrirlo.', v_menu, v_quien;
END
$c$;

COMMIT;
