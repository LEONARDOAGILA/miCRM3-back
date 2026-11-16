-- ============================================================================
-- MENÚ: Ecommerce → Marcas de la tienda
-- ----------------------------------------------------------------------------
-- La pantalla ya existe en el front (ecommerce/allMarcasWeb) y el back ya
-- responde, pero sin esta fila la ruta cae en el 404 de «sin acceso».
--
-- Va justo debajo de «Categorías de la tienda»: son la misma pantalla con
-- otra cosa dentro, y se usan seguidas.
--
-- Los permisos se copian de las categorías, que es de donde sale.
--
-- Se puede volver a ejecutar sin romper nada.
-- ============================================================================
\set ON_ERROR_STOP on
\pset tuples_only on
\pset format unaligned
BEGIN;

INSERT INTO seguridad.menus (padre_id, orden, nivel, nombre, url, descripcion, icono)
SELECT p.id, 3, 1, '🏷️ Marcas de la tienda', 'ecommerce/allMarcasWeb',
       'Qué marcas salen en la tienda, en qué orden y con qué imagen', '-'
  FROM seguridad.menus p
 WHERE p.nivel = 0 AND p.nombre = 'Ecommerce'
   AND NOT EXISTS (SELECT 1 FROM seguridad.menus WHERE url = 'ecommerce/allMarcasWeb');

INSERT INTO seguridad.accesos (perfil_id, menu_id, ver, crear, editar, eliminar, listar,
                               reporte, auditar, ejecutar, papelera, vaciar)
SELECT a.perfil_id, (SELECT id FROM seguridad.menus WHERE url = 'ecommerce/allMarcasWeb'),
       a.ver, a.crear, a.editar, a.eliminar, a.listar,
       a.reporte, a.auditar, a.ejecutar, a.papelera, a.vaciar
  FROM seguridad.accesos a
 WHERE a.menu_id = (SELECT id FROM seguridad.menus WHERE url = 'ecommerce/allCategoriasWeb')
   AND NOT EXISTS (SELECT 1 FROM seguridad.accesos x
                    WHERE x.perfil_id = a.perfil_id
                      AND x.menu_id = (SELECT id FROM seguridad.menus
                                        WHERE url = 'ecommerce/allMarcasWeb'));

-- ---------------------------------------------------------------------------
-- Comprobación. Las cuentas se calculan siempre, para que un NULL no deje
-- pasar la comprobación en verde.
-- ---------------------------------------------------------------------------
DO $c$
DECLARE
    v_menu  bigint;
    v_padre bigint;
    v_quien integer;
BEGIN
    SELECT id INTO v_menu FROM seguridad.menus WHERE url = 'ecommerce/allMarcasWeb';
    IF v_menu IS NULL THEN
        RAISE EXCEPTION 'No se creó el menú de las marcas (¿existe el padre Ecommerce?)';
    END IF;

    SELECT padre_id INTO v_padre FROM seguridad.menus WHERE id = v_menu;
    IF v_padre IS NULL
       OR v_padre <> (SELECT id FROM seguridad.menus WHERE nivel = 0 AND nombre = 'Ecommerce') THEN
        RAISE EXCEPTION 'El menú no quedó colgado de Ecommerce';
    END IF;

    SELECT count(*) INTO v_quien FROM seguridad.accesos WHERE menu_id = v_menu AND ejecutar;
    IF v_quien IS NULL OR v_quien = 0 THEN
        RAISE EXCEPTION 'Ningún perfil puede abrir las marcas de la tienda';
    END IF;

    RAISE NOTICE 'Comprobado: menú % bajo Ecommerce y % perfiles pueden abrirlo.', v_menu, v_quien;
END
$c$;

COMMIT;
