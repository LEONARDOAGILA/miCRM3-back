\set ON_ERROR_STOP on
\pset tuples_only on
\pset format unaligned
BEGIN;
INSERT INTO seguridad.menus (padre_id, orden, nivel, nombre, url, descripcion, icono)
SELECT p.id, 1, 1, '🧱 Pie de página', 'ecommerce/editPie',
       'Las redes sociales y las columnas de enlaces del pie de la tienda', '-'
  FROM seguridad.menus p
 WHERE p.nivel = 0 AND p.url = 'ecommerce'
   AND NOT EXISTS (SELECT 1 FROM seguridad.menus WHERE url = 'ecommerce/editPie');

INSERT INTO seguridad.accesos (perfil_id, menu_id, ver, crear, editar, eliminar, listar,
                               reporte, auditar, ejecutar, papelera, vaciar)
SELECT a.perfil_id, (SELECT id FROM seguridad.menus WHERE url = 'ecommerce/editPie'),
       a.ver, a.crear, a.editar, a.eliminar, a.listar,
       a.reporte, a.auditar, a.ejecutar, a.papelera, a.vaciar
  FROM seguridad.accesos a
 WHERE a.menu_id = (SELECT id FROM seguridad.menus WHERE url = 'ecommerce/editEncabezado')
   AND NOT EXISTS (SELECT 1 FROM seguridad.accesos x
                    WHERE x.perfil_id = a.perfil_id
                      AND x.menu_id = (SELECT id FROM seguridad.menus WHERE url = 'ecommerce/editPie'));

DO $c$
DECLARE v bigint; n integer;
BEGIN
    SELECT id INTO v FROM seguridad.menus WHERE url = 'ecommerce/editPie';
    IF v IS NULL THEN RAISE EXCEPTION 'No se creo el menu del pie'; END IF;
    SELECT count(*) INTO n FROM seguridad.accesos WHERE menu_id = v AND ejecutar;
    IF n = 0 THEN RAISE EXCEPTION 'Ningun perfil puede abrirla'; END IF;
    RAISE NOTICE 'Menu % creado y % perfiles pueden abrirlo.', v, n;
END
$c$;
COMMIT;
