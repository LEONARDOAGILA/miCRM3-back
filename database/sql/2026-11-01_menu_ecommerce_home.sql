-- La portada del módulo: la primera entrada del apartado «Ecommerce» y, de
-- paso, el destino del propio apartado (hasta ahora su url era 'ecommerce',
-- que no lleva a ninguna pantalla).
\set ON_ERROR_STOP on
\pset tuples_only on
\pset format unaligned
BEGIN;

INSERT INTO seguridad.menus (padre_id, orden, nivel, nombre, url, descripcion, icono)
SELECT p.id, -1, 1, '🏠 Portada', 'ecommerce/home',
       'Las once áreas de la página web, con lo que hay configurado en cada una', '-'
  FROM seguridad.menus p
 WHERE p.nivel = 0 AND p.url = 'ecommerce'
   AND NOT EXISTS (SELECT 1 FROM seguridad.menus WHERE url = 'ecommerce/home');

INSERT INTO seguridad.accesos (perfil_id, menu_id, ver, crear, editar, eliminar, listar,
                               reporte, auditar, ejecutar, papelera, vaciar)
SELECT a.perfil_id, (SELECT id FROM seguridad.menus WHERE url = 'ecommerce/home'),
       a.ver, a.crear, a.editar, a.eliminar, a.listar,
       a.reporte, a.auditar, a.ejecutar, a.papelera, a.vaciar
  FROM seguridad.accesos a
 WHERE a.menu_id = (SELECT id FROM seguridad.menus WHERE url = 'ecommerce/editEncabezado')
   AND NOT EXISTS (SELECT 1 FROM seguridad.accesos x
                    WHERE x.perfil_id = a.perfil_id
                      AND x.menu_id = (SELECT id FROM seguridad.menus WHERE url = 'ecommerce/home'));

-- El apartado pasa a abrir la portada en vez de no hacer nada
UPDATE seguridad.menus SET url = 'ecommerce/home'
 WHERE nivel = 0 AND url = 'ecommerce';

DO $c$
DECLARE v bigint; n integer;
BEGIN
    SELECT id INTO v FROM seguridad.menus WHERE url = 'ecommerce/home' AND nivel = 1;
    IF v IS NULL THEN RAISE EXCEPTION 'No se creo la portada'; END IF;
    SELECT count(*) INTO n FROM seguridad.accesos WHERE menu_id = v AND ejecutar;
    IF n = 0 THEN RAISE EXCEPTION 'Ningun perfil puede abrirla'; END IF;
    RAISE NOTICE 'Portada: menu % y % perfiles pueden abrirla.', v, n;
END
$c$;
COMMIT;
