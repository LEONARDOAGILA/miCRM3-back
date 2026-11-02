-- ============================================================================
-- MENÚ: Ecommerce → Productos por sección
-- ----------------------------------------------------------------------------
-- La pantalla arma las secciones de productos: a la izquierda la lista de
-- secciones, en el medio el catálogo con sus casillas, y a la derecha los
-- filtros para meter de golpe todo lo que cumple uno.
--
-- Va al final del bloque de Ecommerce (orden 20): no es una parte de la
-- portada como el inicio y el modelado, sino el almacén del que esas
-- secciones tirarán.
--
-- Los permisos se copian de «Productos» de Inventarios, que es el catálogo
-- que se está repartiendo: quien puede ver y editar productos puede decidir
-- en qué escaparate van. Si no estuviera, se cae a «Inicio de la tienda».
--
-- Sin esta fila la ruta cae en /access-deny y parece un fallo del componente.
--
-- Se puede volver a ejecutar sin romper nada.
-- ============================================================================
\set ON_ERROR_STOP on
\pset tuples_only on
\pset format unaligned
BEGIN;

INSERT INTO seguridad.menus (padre_id, orden, nivel, nombre, url, descripcion, icono)
SELECT p.id, 20, 1, '🧺 Productos por sección', 'ecommerce/producto-por-seccion',
       'Secciones de productos: arma escaparates y mete productos de uno en uno o por filtro', '-'
  FROM seguridad.menus p
 WHERE p.nivel = 0 AND p.nombre = 'Ecommerce'
   AND NOT EXISTS (SELECT 1 FROM seguridad.menus WHERE url = 'ecommerce/producto-por-seccion');

-- De «Productos»; y si ese menú no existe, de «Inicio de la tienda». Se mira
-- con COALESCE para no copiar dos veces si existieran los dos.
INSERT INTO seguridad.accesos (perfil_id, menu_id, ver, crear, editar, eliminar, listar,
                               reporte, auditar, ejecutar, papelera, vaciar)
SELECT a.perfil_id, (SELECT id FROM seguridad.menus WHERE url = 'ecommerce/producto-por-seccion'),
       a.ver, a.crear, a.editar, a.eliminar, a.listar,
       a.reporte, a.auditar, a.ejecutar, a.papelera, a.vaciar
  FROM seguridad.accesos a
 WHERE a.menu_id = COALESCE(
           (SELECT id FROM seguridad.menus WHERE url = 'inventarios/allProductos'),
           (SELECT id FROM seguridad.menus WHERE url = 'ecommerce/editInicio'))
   AND NOT EXISTS (SELECT 1 FROM seguridad.accesos x
                    WHERE x.perfil_id = a.perfil_id
                      AND x.menu_id = (SELECT id FROM seguridad.menus
                                        WHERE url = 'ecommerce/producto-por-seccion'));

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
    SELECT id INTO v_menu FROM seguridad.menus WHERE url = 'ecommerce/producto-por-seccion';
    IF v_menu IS NULL THEN
        RAISE EXCEPTION 'No se creó el menú de productos por sección (¿existe el padre Ecommerce?)';
    END IF;

    SELECT padre_id INTO v_padre FROM seguridad.menus WHERE id = v_menu;
    IF v_padre IS NULL
       OR v_padre <> (SELECT id FROM seguridad.menus WHERE nivel = 0 AND nombre = 'Ecommerce') THEN
        RAISE EXCEPTION 'El menú no quedó colgado de Ecommerce';
    END IF;

    SELECT count(*) INTO v_quien FROM seguridad.accesos WHERE menu_id = v_menu AND ejecutar;
    IF v_quien IS NULL OR v_quien = 0 THEN
        RAISE EXCEPTION 'Nadie puede abrir la pantalla: no se copió ningún acceso';
    END IF;

    RAISE NOTICE 'Menú % bajo Ecommerce y % perfiles pueden abrirlo.', v_menu, v_quien;
END
$c$;

COMMIT;
