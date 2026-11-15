-- ============================================================================
-- EL MENÚ DE CATEGORÍAS, CON EL ICONO DE CADA UNA
-- ============================================================================
-- El icono se elige en la ficha de la categoría (Inventarios → Categorías) y
-- se guarda como clase de Font Awesome. La tienda NO tiene esa fuente, así que
-- el menú manda el DIBUJO ya resuelto —`{caja, trazo}`— y allá se pinta un
-- <svg>. Los dibujos están en ecommerce.iconos_fa y los resuelve
-- ecommerce.fn_icono_fa.
--
-- Una categoría sin icono manda `icono: null` y en el menú no sale nada: no
-- hay icono de relleno, que sería peor que ninguno.
-- ============================================================================

BEGIN;

CREATE OR REPLACE FUNCTION ecommerce.fn_categorias_web_menu_publico()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
AS $function$
    WITH v AS (
        -- El icono de cada categoría viene de su ficha de inventarios, que es
        -- donde se elige, y sale YA DIBUJADO: la tienda no tiene la fuente de
        -- iconos y no la va a tener (ver ecommerce.iconos_fa)
        SELECT e.*, ecommerce.fn_icono_fa(c.icono) AS icono
          FROM ecommerce.fn_categorias_web_estado() e
          JOIN inventarios.categorias c ON c.id = e.id
         WHERE e.estado = 'visible'
    )
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'id', d.id, 'nombre', d.nombre, 'icono', d.icono,
               'enlace', COALESCE(ecommerce.fn_cuerpo_de_categoria(d.id), '/shop?categoria=' || d.id),
               'hijos', COALESCE((
                   SELECT jsonb_agg(jsonb_build_object(
                              'id', c.id, 'nombre', c.nombre, 'icono', c.icono,
                              'enlace', COALESCE(ecommerce.fn_cuerpo_de_categoria(c.id), '/shop?categoria=' || c.id),
                              'hijos', COALESCE((
                                  SELECT jsonb_agg(jsonb_build_object('id', s.id, 'nombre', s.nombre, 'icono', s.icono,
                                             'enlace', COALESCE(ecommerce.fn_cuerpo_de_categoria(s.id), '/shop?categoria=' || s.id),
                                             'hijos', '[]'::jsonb)
                                         ORDER BY s.orden_web NULLS LAST, s.orden, s.nombre)
                                    FROM v s WHERE s.padre_id = c.id), '[]'::jsonb))
                          ORDER BY c.orden_web NULLS LAST, c.orden, c.nombre)
                     FROM v c WHERE c.padre_id = d.id), '[]'::jsonb))
           ORDER BY d.orden_web NULLS LAST, d.orden, d.nombre), '[]'::jsonb)
      FROM v d
     WHERE d.padre_id IS NULL;
$function$;

COMMIT;


-- ============================================================================
-- COMPROBACIÓN — no escribe nada
-- ============================================================================
DO $comprobar$
DECLARE
    v_falta text[] := '{}';
    v_menu  jsonb;
    v_uno   jsonb;
    v_con   int;
BEGIN
    v_menu := ecommerce.fn_categorias_web_menu_publico();

    IF jsonb_array_length(v_menu) = 0 THEN
        v_falta := array_append(v_falta, 'el menú vino vacío');
    ELSE
        v_uno := v_menu -> 0;

        IF NOT (v_uno ? 'icono') THEN
            v_falta := array_append(v_falta, 'los departamentos no traen icono');
        END IF;
        IF jsonb_array_length(v_uno -> 'hijos') > 0 AND NOT ((v_uno -> 'hijos' -> 0) ? 'icono') THEN
            v_falta := array_append(v_falta, 'las categorías no traen icono');
        END IF;

        -- Los que tienen icono lo traen dibujado, con su caja y su trazo
        SELECT count(*) INTO v_con
          FROM jsonb_array_elements(v_menu) d
         WHERE d -> 'icono' IS NOT NULL AND jsonb_typeof(d -> 'icono') = 'object';

        IF v_con = 0 THEN
            v_falta := array_append(v_falta, 'ningún departamento trajo dibujo (y en la base hay iconos puestos)');
        END IF;

        IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_menu) d
                    WHERE jsonb_typeof(d -> 'icono') = 'object'
                      AND (COALESCE(d -> 'icono' ->> 'trazo', '') = ''
                           OR COALESCE(d -> 'icono' ->> 'caja', '') = '')) THEN
            v_falta := array_append(v_falta, 'hay un icono a medias (sin trazo o sin caja)');
        END IF;
    END IF;

    IF array_length(v_falta, 1) > 0 THEN
        RAISE EXCEPTION 'El menú con iconos no quedó bien: %', array_to_string(v_falta, '; ');
    END IF;

    RAISE NOTICE 'Menú de categorías: % departamentos, % con icono',
                 jsonb_array_length(v_menu), v_con;
END;
$comprobar$;
