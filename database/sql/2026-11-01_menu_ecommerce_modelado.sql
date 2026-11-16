-- ============================================================================
-- MENÚ: Ecommerce → Modelado de la portada
-- ----------------------------------------------------------------------------
-- La pantalla dibuja la portada de la tienda a escala: las secciones en su
-- orden, cada una del tamaño que ocupa de verdad, y se arrastran y se estiran
-- con el ratón.
--
-- Va justo debajo de «Inicio de la tienda»: son la misma portada vista de dos
-- maneras —una por dentro, la otra por fuera— y se usan seguidas.
--
-- Los permisos se copian de «Inicio de la tienda», que es la misma portada:
-- quien pueda ordenarla en una lista puede ordenarla en un dibujo.
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
SELECT p.id, 2, 1, '📐 Modelado de la portada', 'ecommerce/modelado',
       'La portada dibujada a escala: arrastra las secciones y estíralas para ver cómo queda', '-'
  FROM seguridad.menus p
 WHERE p.nivel = 0 AND p.nombre = 'Ecommerce'
   AND NOT EXISTS (SELECT 1 FROM seguridad.menus WHERE url = 'ecommerce/modelado');

INSERT INTO seguridad.accesos (perfil_id, menu_id, ver, crear, editar, eliminar, listar,
                               reporte, auditar, ejecutar, papelera, vaciar)
SELECT a.perfil_id, (SELECT id FROM seguridad.menus WHERE url = 'ecommerce/modelado'),
       a.ver, a.crear, a.editar, a.eliminar, a.listar,
       a.reporte, a.auditar, a.ejecutar, a.papelera, a.vaciar
  FROM seguridad.accesos a
 WHERE a.menu_id = (SELECT id FROM seguridad.menus WHERE url = 'ecommerce/editInicio')
   AND NOT EXISTS (SELECT 1 FROM seguridad.accesos x
                    WHERE x.perfil_id = a.perfil_id
                      AND x.menu_id = (SELECT id FROM seguridad.menus
                                        WHERE url = 'ecommerce/modelado'));

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
    SELECT id INTO v_menu FROM seguridad.menus WHERE url = 'ecommerce/modelado';
    IF v_menu IS NULL THEN
        RAISE EXCEPTION 'No se creó el menú del modelado (¿existe el padre Ecommerce?)';
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
