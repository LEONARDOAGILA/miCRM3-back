-- ============================================================================
-- EL MENÚ «MARCAS» DEL ENCABEZADO
-- ============================================================================
-- Al lado del de categorías, y con lo mismo detrás: una lista ya ordenada de
-- {id, nombre, enlace} que la tienda sólo tiene que pintar.
--
-- SE PARECE AL DE CATEGORÍAS A PROPÓSITO, hasta en la forma de cada nodo
-- (`hijos` siempre vacío): así la tienda usa el mismo modelo, el mismo
-- servicio y la misma plantilla para los dos. Una marca no tiene marcas
-- dentro, pero el día que el menú aprenda a agrupar, esto ya cabe.
--
-- A DÓNDE LLEVA CADA UNA LA DECIDE LA BASE, igual que con las categorías: su
-- página si alguien le armó una (`ecommerce.cuerpos.marca_id`) y, si no, el
-- catálogo filtrado de siempre, `/shop?marca=12`.
--
-- QUIÉN SALE: lo que ya decide `fn_marcas_web_estado` —ni las ocultas en el
-- CRM ni las inactivas—. No se le pide además que tenga productos publicados,
-- por lo mismo que al menú de categorías no se le pide: esconder una marca es
-- una decisión que se toma en su pantalla, no un efecto de cuántas fichas
-- quedaron encendidas esta semana.
-- ============================================================================

BEGIN;

CREATE OR REPLACE FUNCTION ecommerce.fn_marcas_web_menu_publico()
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
AS $function$
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'id',     e.id,
               'nombre', e.nombre,
               'enlace', COALESCE(ecommerce.fn_cuerpo_de_marca(e.id), '/shop?marca=' || e.id),
               'hijos',  '[]'::jsonb)
           ORDER BY e.orden_web NULLS LAST, e.nombre), '[]'::jsonb)
      FROM ecommerce.fn_marcas_web_estado() e
     WHERE e.estado = 'visible';
$function$;

COMMENT ON FUNCTION ecommerce.fn_marcas_web_menu_publico() IS
    'El menú «Marcas» del encabezado de la tienda: las visibles, en su orden, con su enlace ya decidido.';

COMMIT;


-- ============================================================================
-- COMPROBACIÓN — no escribe nada
-- ============================================================================
DO $comprobar$
DECLARE
    v_falta  text[] := '{}';
    v_menu   jsonb;
    v_una    jsonb;
    v_cuantas int;
BEGIN
    v_menu := ecommerce.fn_marcas_web_menu_publico();

    IF jsonb_typeof(v_menu) IS DISTINCT FROM 'array' THEN
        v_falta := v_falta || 'el menú no es una lista';
    END IF;

    SELECT count(*) INTO v_cuantas
      FROM ecommerce.fn_marcas_web_estado() WHERE estado = 'visible';

    IF jsonb_array_length(v_menu) <> v_cuantas THEN
        v_falta := v_falta || format('salen %s marcas y hay %s visibles',
                                     jsonb_array_length(v_menu), v_cuantas);
    END IF;

    IF jsonb_array_length(v_menu) > 0 THEN
        v_una := v_menu -> 0;

        IF (v_una ->> 'id') IS NULL OR COALESCE(btrim(v_una ->> 'nombre'), '') = '' THEN
            v_falta := v_falta || 'hay una marca sin id o sin nombre';
        END IF;

        IF COALESCE(v_una ->> 'enlace', '') NOT LIKE '/%' THEN
            v_falta := v_falta || format('el enlace no es una ruta de la tienda: %s', v_una ->> 'enlace');
        END IF;

        IF v_una -> 'hijos' IS DISTINCT FROM '[]'::jsonb THEN
            v_falta := v_falta || 'los hijos tienen que venir, y vacíos';
        END IF;

        -- Ordenadas: orden_web primero y, sin él, por nombre
        IF (SELECT bool_or(x.nombre > y.nombre)
              FROM jsonb_array_elements(v_menu) WITH ORDINALITY a(valor, i)
              CROSS JOIN LATERAL (SELECT a.valor ->> 'nombre' AS nombre) x
              JOIN LATERAL (SELECT (v_menu -> (a.i::int)) ->> 'nombre' AS nombre) y ON true
             WHERE a.i < jsonb_array_length(v_menu)
               AND (SELECT count(*) FROM ecommerce.fn_marcas_web_estado()
                     WHERE estado = 'visible' AND orden_web IS NOT NULL) = 0)
        THEN
            v_falta := v_falta || 'sin orden_web tenían que salir por nombre';
        END IF;
    END IF;

    IF array_length(v_falta, 1) > 0 THEN
        RAISE EXCEPTION 'El menú de marcas no quedó bien: %', array_to_string(v_falta, '; ');
    END IF;

    RAISE NOTICE 'Menú de marcas: % visibles, la primera «%» → %',
                 jsonb_array_length(v_menu),
                 COALESCE(v_menu -> 0 ->> 'nombre', '-'),
                 COALESCE(v_menu -> 0 ->> 'enlace', '-');
END;
$comprobar$;
