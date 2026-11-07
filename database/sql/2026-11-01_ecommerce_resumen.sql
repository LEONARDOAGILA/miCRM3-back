-- ============================================================================
-- ECOMMERCE · EL RESUMEN DE LA PORTADA DEL MÓDULO
-- ============================================================================
-- Fecha: 2026-11-01
--
-- La portada de «Ecommerce» es una rejilla de tarjetas, una por área, y cada
-- una enseña cuántas cosas hay dentro: «4 enlaces, 1 oculto», «3 columnas con
-- 12 enlaces». Sirve para saber de un vistazo qué está configurado y qué
-- está vacío sin entrar en diez pantallas.
--
-- UNA SOLA FUNCIÓN Y UNA SOLA CONSULTA. Hacerlo con once llamadas —una por
-- tarjeta, que es como lo hacía el CRM viejo— deja la portada parpadeando
-- mientras llegan, y con una sola de ellas caída la tarjeta se queda en
-- «No se pudo cargar» para siempre.
--
-- CADA CUENTA VA PROTEGIDA CON `to_regclass`. Las áreas que aún no se han
-- migrado leen de las tablas viejas, y esas tablas van desapareciendo según
-- avanza el traslado: sin la protección, migrar una pantalla rompería la
-- portada de todas. Lo que no existe devuelve null y la tarjeta lo dice.
--
-- Idempotente.
-- ============================================================================
\set ON_ERROR_STOP on

BEGIN;

CREATE OR REPLACE FUNCTION ecommerce.fn_resumen()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
AS $function$
DECLARE
    v jsonb := '{}'::jsonb;
    n bigint;
    m bigint;
BEGIN
    -- ---------- Lo ya migrado ----------
    SELECT count(*) FILTER (WHERE deleted_at IS NULL),
           count(*) FILTER (WHERE deleted_at IS NULL AND NOT activo)
      INTO n, m FROM ecommerce.paginas_informativas;
    v := v || jsonb_build_object('paginas', jsonb_build_object('total', n, 'ocultas', m));

    SELECT count(*) FILTER (WHERE deleted_at IS NULL),
           count(*) FILTER (WHERE deleted_at IS NULL AND NOT activo)
      INTO n, m FROM ecommerce.encabezado_enlaces;
    v := v || jsonb_build_object('encabezado', jsonb_build_object('enlaces', n, 'ocultos', m));

    SELECT count(*) FILTER (WHERE deleted_at IS NULL) INTO n FROM ecommerce.pie_columnas;
    SELECT count(*) FILTER (WHERE deleted_at IS NULL) INTO m FROM ecommerce.pie_enlaces;
    v := v || jsonb_build_object('pie', jsonb_build_object('columnas', n, 'enlaces', m));

    SELECT count(*) FILTER (WHERE estado = 'visible'), count(*)
      INTO n, m FROM ecommerce.fn_categorias_web_estado();
    v := v || jsonb_build_object('categorias', jsonb_build_object('visibles', n, 'total', m));

    SELECT count(*) INTO n FROM ecommerce.galerias;
    SELECT count(*) FILTER (WHERE deleted_at IS NULL) INTO m FROM ecommerce.galerias_imagenes;
    v := v || jsonb_build_object('galerias', jsonb_build_object('galerias', n, 'imagenes', m));

    SELECT count(*) FILTER (WHERE activo), count(*)
      INTO n, m FROM ecommerce.inicio_secciones;
    v := v || jsonb_build_object('inicio', jsonb_build_object('visibles', n, 'total', m));

    -- ---------- Lo que todavía lee de las tablas viejas ----------
    -- Cuando se migre cada una, esta parte se cambia por la nueva. Mientras
    -- tanto, `to_regclass` evita que la portada entera reviente.
    IF to_regclass('ecommerce.sucursal') IS NOT NULL THEN
        EXECUTE 'SELECT count(*) FILTER (WHERE suc_eliminado_en IS NULL) FROM ecommerce.sucursal' INTO n;
        EXECUTE 'SELECT count(*) FILTER (WHERE sci_eliminado_en IS NULL) FROM ecommerce.sucursal_ciudad' INTO m;
        v := v || jsonb_build_object('sucursales', jsonb_build_object('tiendas', n, 'ciudades', m));
    END IF;

    IF to_regclass('ecommerce.pagina_marca') IS NOT NULL THEN
        EXECUTE 'SELECT count(*) FILTER (WHERE pma_eliminado_en IS NULL) FROM ecommerce.pagina_marca' INTO n;
        v := v || jsonb_build_object('paginas_marca', jsonb_build_object('paginas', n));
    END IF;

    IF to_regclass('ecommerce.espana_motos_marca') IS NOT NULL THEN
        EXECUTE 'SELECT count(*) FILTER (WHERE emm_eliminado_en IS NULL) FROM ecommerce.espana_motos_marca' INTO n;
        EXECUTE 'SELECT count(*) FILTER (WHERE emp_eliminado_en IS NULL) FROM ecommerce.espana_motos_pestana' INTO m;
        v := v || jsonb_build_object('espana_motos', jsonb_build_object('marcas', n, 'pestanas', m));
    END IF;

    IF to_regclass('ecommerce.franjas_detalle') IS NOT NULL THEN
        EXECUTE 'SELECT count(*) FILTER (WHERE fde_eliminado_en IS NULL) FROM ecommerce.franjas_detalle' INTO n;
        v := v || jsonb_build_object('franjas', jsonb_build_object('franjas', n));
    END IF;

    IF to_regclass('ecommerce.bloque_producto') IS NOT NULL THEN
        EXECUTE 'SELECT count(*) FILTER (WHERE bpr_eliminado_en IS NULL) FROM ecommerce.bloque_producto' INTO n;
        v := v || jsonb_build_object('bloques', jsonb_build_object('bloques', n));
    END IF;

    -- El catálogo sale de inventarios, que es de otro módulo
    SELECT count(*) FILTER (WHERE deleted_at IS NULL) INTO n FROM inventarios.productos;
    SELECT count(*) FILTER (WHERE deleted_at IS NULL) INTO m FROM inventarios.marcas;
    v := v || jsonb_build_object('productos', jsonb_build_object('productos', n),
                                 'marcas_tienda', jsonb_build_object('marcas', m));

    RETURN jsonb_build_object('success', true, 'message', 'Resumen de la página web', 'data', v);
END;
$function$;

DO $comprobar$
DECLARE
    v jsonb;
BEGIN
    v := ecommerce.fn_resumen() -> 'data';

    -- Las seis áreas ya migradas tienen que venir siempre
    IF v -> 'paginas' IS NULL OR v -> 'encabezado' IS NULL OR v -> 'pie' IS NULL
       OR v -> 'categorias' IS NULL OR v -> 'galerias' IS NULL OR v -> 'inicio' IS NULL THEN
        RAISE EXCEPTION 'Falta alguna de las áreas migradas en el resumen: %', v;
    END IF;

    RAISE NOTICE 'Resumen: % áreas con datos.', (SELECT count(*) FROM jsonb_object_keys(v));
END
$comprobar$;

COMMIT;
