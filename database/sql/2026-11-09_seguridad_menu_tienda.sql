-- ============================================================================
-- EL APARTADO «TIENDA» EN EL MENÚ DEL CRM
-- ============================================================================
-- /shop ya es una página del CRM, pero para llegar a ella había que entrar en
-- «Cuerpo» y buscarla en la lista. Esto le pone su propia entrada, al lado de
-- las otras tres de «Pagina Web».
--
-- ES LA MISMA PANTALLA: la ruta `ecommerce/editTienda` abre el mismo
-- componente que `ecommerce/editInicio`, sólo que empezando por /shop. Tiene
-- ruta propia y no un parámetro en la dirección porque el menú pinta sus
-- enlaces con `[routerLink]="menu.url"`, y ahí un «?» se escapa entero.
--
-- LOS ACCESOS SE COPIAN DE «Cuerpo». Sin fila en `seguridad.accesos` el guard
-- manda al 404 aunque la ruta y el componente estén bien, y quien pueda editar
-- las páginas de la tienda tiene que poder editar ésta: es una de ellas.
--
-- ----------------------------------------------------------------------------
-- SE EJECUTA A MANO. Es idempotente: si la entrada ya existe, se pone al día.
-- Para ensayar, cambiar el COMMIT del final por ROLLBACK.
-- ============================================================================

BEGIN;

DO $menu$
DECLARE
    v_padre   bigint;
    v_cuerpo  bigint;
    v_id      bigint;
    v_copias  integer;
BEGIN
    -- ---------- Dónde va ----------
    SELECT id INTO v_padre FROM seguridad.menus
     WHERE url = '.' AND lower(btrim(nombre)) = 'pagina web';
    IF v_padre IS NULL THEN
        RAISE EXCEPTION 'No encontré el grupo «Pagina Web» del menú';
    END IF;

    SELECT id INTO v_cuerpo FROM seguridad.menus WHERE url = 'ecommerce/editInicio';
    IF v_cuerpo IS NULL THEN
        RAISE EXCEPTION 'No encontré la entrada «Cuerpo» (ecommerce/editInicio): de ahí se copian los accesos';
    END IF;

    -- ---------- La entrada ----------
    SELECT id INTO v_id FROM seguridad.menus WHERE url = 'ecommerce/editTienda';

    IF v_id IS NULL THEN
        -- Justo después de «Cuerpo», y lo que venía detrás se corre un puesto
        UPDATE seguridad.menus
           SET orden = orden + 1
         WHERE padre_id = v_padre
           AND orden > (SELECT orden FROM seguridad.menus WHERE id = v_cuerpo);

        INSERT INTO seguridad.menus (padre_id, orden, nivel, nombre, url, descripcion, icono)
        SELECT v_padre,
               (SELECT orden FROM seguridad.menus WHERE id = v_cuerpo) + 1,
               m.nivel,
               '🛒 Tienda',
               'ecommerce/editTienda',
               'La página /shop: su fondo, el orden de sus secciones y cómo se ven las tarjetas del catálogo',
               m.icono
          FROM seguridad.menus m WHERE m.id = v_cuerpo
        RETURNING id INTO v_id;

        RAISE NOTICE 'Creada la entrada «Tienda» en el menú (id %)', v_id;
    ELSE
        UPDATE seguridad.menus
           SET nombre      = '🛒 Tienda',
               descripcion = 'La página /shop: su fondo, el orden de sus secciones y cómo se ven las tarjetas del catálogo'
         WHERE id = v_id;

        RAISE NOTICE 'La entrada «Tienda» ya existía (id %); queda al día', v_id;
    END IF;

    -- ---------- Los accesos, calcados de «Cuerpo» ----------
    INSERT INTO seguridad.accesos (perfil_id, menu_id, ver, crear, editar, eliminar,
                                   listar, reporte, auditar, ejecutar, papelera, vaciar,
                                   created_by, updated_by)
    SELECT a.perfil_id, v_id, a.ver, a.crear, a.editar, a.eliminar,
           a.listar, a.reporte, a.auditar, a.ejecutar, a.papelera, a.vaciar,
           'migracion', 'migracion'
      FROM seguridad.accesos a
     WHERE a.menu_id = v_cuerpo
       AND NOT EXISTS (SELECT 1 FROM seguridad.accesos b
                        WHERE b.menu_id = v_id AND b.perfil_id = a.perfil_id);

    GET DIAGNOSTICS v_copias = ROW_COUNT;
    RAISE NOTICE 'Accesos copiados de «Cuerpo»: %', v_copias;
END;
$menu$;


-- ============================================================================
-- COMPROBACIÓN — no escribe nada
-- ============================================================================
DO $comprobar$
DECLARE
    v_falta  text[] := '{}';
    v_id     bigint;
    v_cuerpo bigint;
    v_a      integer;
    v_b      integer;
BEGIN
    SELECT id INTO v_id     FROM seguridad.menus WHERE url = 'ecommerce/editTienda';
    SELECT id INTO v_cuerpo FROM seguridad.menus WHERE url = 'ecommerce/editInicio';

    IF v_id IS NULL THEN
        v_falta := array_append(v_falta, 'no se creó la entrada ecommerce/editTienda');
    END IF;

    SELECT count(*) INTO v_a FROM seguridad.accesos WHERE menu_id = v_cuerpo;
    SELECT count(*) INTO v_b FROM seguridad.accesos WHERE menu_id = v_id;

    IF v_b < v_a THEN
        v_falta := v_falta || format('«Cuerpo» tiene %s accesos y «Tienda» sólo %s', v_a, v_b);
    END IF;

    -- Que nadie se quedó con dos entradas en el mismo puesto
    IF EXISTS (SELECT 1 FROM seguridad.menus
                WHERE padre_id = (SELECT padre_id FROM seguridad.menus WHERE id = v_id)
                GROUP BY orden HAVING count(*) > 1) THEN
        v_falta := array_append(v_falta, 'hay dos entradas del menú en el mismo orden');
    END IF;

    IF cardinality(v_falta) > 0 THEN
        RAISE EXCEPTION E'EL MENÚ NO QUEDÓ BIEN:\n  · %', array_to_string(v_falta, E'\n  · ');
    END IF;

    RAISE NOTICE 'Menú «Tienda» (id %) con % accesos, los mismos que «Cuerpo».', v_id, v_b;
END;
$comprobar$;

COMMIT;
