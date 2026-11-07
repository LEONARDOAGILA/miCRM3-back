-- ============================================================================
-- ECOMMERCE · A DÓNDE LLEVA CADA CATEGORÍA Y CADA MARCA
-- ============================================================================
-- Fecha: 2026-11-06
-- Va DESPUÉS de 2026-11-06_ecommerce_cuerpo_publico.sql.
--
-- Con cuerpos, el clic en una categoría ya no lleva siempre al catálogo
-- filtrado: si esa categoría tiene su página, lleva a su página.
--
--     Movilidad, con cuerpo      →  /movilidad
--     Refrigeración, sin cuerpo  →  /shop?categoria=18   (lo de siempre)
--
-- Y ESO LO DECIDE EL SERVIDOR, en un solo sitio. Los enlaces de categorías y
-- marcas se arman en seis pantallas de la tienda —el menú del encabezado, las
-- destacadas, el mosaico, los carteles de marcas, la tira de logos, las
-- categorías de una página—, y si cada una preguntara por su cuenta si hay
-- cuerpo, la primera que se olvidara dejaría una página a la que no se llega.
-- Así cada lista ya trae su `enlace` hecho y la tienda sólo lo abre, que es
-- justo lo que `fn_marcas_publicas` hacía desde el principio.
--
-- POR ESO SE QUITA EL MAPA DEL ENCABEZADO que puso el fichero anterior: dos
-- maneras de resolver el mismo enlace son una de más, y la que sobra es la
-- que obliga a la tienda a acordarse.
--
-- Idempotente.
-- ============================================================================
\set ON_ERROR_STOP on

BEGIN;

-- ----------------------------------------------------------------------------
-- 1. ¿TIENE PÁGINA?
-- ----------------------------------------------------------------------------
-- La dirección de su cuerpo, o NULL si no tiene. Quien llama pone el respaldo:
-- casi siempre /shop con su filtro, pero no siempre el mismo filtro.
CREATE OR REPLACE FUNCTION ecommerce.fn_cuerpo_de_categoria(p_categoria_id bigint)
 RETURNS text
 LANGUAGE sql
 STABLE
AS $function$
    SELECT '/' || c.ruta
      FROM ecommerce.cuerpos c
     WHERE c.categoria_id = p_categoria_id
       AND c.deleted_at IS NULL AND c.activo AND NOT c.principal;
$function$;

COMMENT ON FUNCTION ecommerce.fn_cuerpo_de_categoria(bigint) IS
    'La dirección de la página de esa categoría, o NULL si no tiene.';

CREATE OR REPLACE FUNCTION ecommerce.fn_cuerpo_de_marca(p_marca_id bigint)
 RETURNS text
 LANGUAGE sql
 STABLE
AS $function$
    SELECT '/' || c.ruta
      FROM ecommerce.cuerpos c
     WHERE c.marca_id = p_marca_id
       AND c.deleted_at IS NULL AND c.activo AND NOT c.principal;
$function$;

COMMENT ON FUNCTION ecommerce.fn_cuerpo_de_marca(bigint) IS
    'La dirección de la página de esa marca, o NULL si no tiene.';

-- ----------------------------------------------------------------------------
-- 2. EL MENÚ DEL ENCABEZADO
-- ----------------------------------------------------------------------------
-- Tres niveles, y los tres pueden tener página.
CREATE OR REPLACE FUNCTION ecommerce.fn_categorias_web_menu_publico()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
AS $function$
    WITH v AS (
        SELECT * FROM ecommerce.fn_categorias_web_estado() WHERE estado = 'visible'
    )
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'id', d.id, 'nombre', d.nombre,
               'enlace', COALESCE(ecommerce.fn_cuerpo_de_categoria(d.id), '/shop?categoria=' || d.id),
               'hijos', COALESCE((
                   SELECT jsonb_agg(jsonb_build_object(
                              'id', c.id, 'nombre', c.nombre,
                              'enlace', COALESCE(ecommerce.fn_cuerpo_de_categoria(c.id), '/shop?categoria=' || c.id),
                              'hijos', COALESCE((
                                  SELECT jsonb_agg(jsonb_build_object('id', s.id, 'nombre', s.nombre,
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

-- ----------------------------------------------------------------------------
-- 3. LAS LISTAS DE LA PORTADA Y DE CADA PÁGINA
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ecommerce.fn_categorias_destacadas_publicas()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
AS $function$
    WITH destacadas AS (
        SELECT e.id, e.nombre, e.orden, e.destacada_orden
          FROM ecommerce.fn_categorias_web_estado() e
         WHERE e.estado = 'visible' AND e.destacada
    ),
    mandona AS (
        SELECT DISTINCT ON (i.categoria_id) i.categoria_id, i.imagen
          FROM ecommerce.categorias_imagenes i
         WHERE i.deleted_at IS NULL AND i.activo
           AND ecommerce.fn_vigente(i.desde, i.hasta)
         ORDER BY i.categoria_id, i.orden, i.id
    )
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'id', d.id, 'nombre', d.nombre, 'imagen', m.imagen,
               -- Su página si la tiene; si no, el catálogo filtrado de siempre
               'enlace', COALESCE(ecommerce.fn_cuerpo_de_categoria(d.id), '/shop?categoria=' || d.id))
           ORDER BY d.destacada_orden NULLS LAST, d.orden, d.nombre), '[]'::jsonb)
      FROM destacadas d
      LEFT JOIN mandona m ON m.categoria_id = d.id;
$function$;

CREATE OR REPLACE FUNCTION ecommerce.fn_categorias_promocion_publicas()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
AS $function$
    WITH enPromocion AS (
        SELECT e.id, e.nombre, e.orden, e.promocion_orden
          FROM ecommerce.fn_categorias_web_estado() e
         WHERE e.estado = 'visible' AND e.promocion
    ),
    mandona AS (
        SELECT DISTINCT ON (i.categoria_id) i.categoria_id, i.imagen
          FROM ecommerce.categorias_imagenes i
         WHERE i.deleted_at IS NULL AND i.activo
           AND ecommerce.fn_vigente(i.desde, i.hasta)
         ORDER BY i.categoria_id, i.orden, i.id
    )
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'id', p.id, 'nombre', p.nombre, 'imagen', m.imagen,
               'enlace', COALESCE(ecommerce.fn_cuerpo_de_categoria(p.id), '/shop?categoria=' || p.id))
           ORDER BY p.promocion_orden NULLS LAST, p.orden, p.nombre), '[]'::jsonb)
      FROM enPromocion p
      LEFT JOIN mandona m ON m.categoria_id = p.id;
$function$;

CREATE OR REPLACE FUNCTION ecommerce.fn_categorias_hijas_publicas(p_padre_id bigint)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
AS $function$
    WITH hijas AS (
        SELECT e.id, e.nombre, e.orden
          FROM ecommerce.fn_categorias_web_estado() e
         WHERE e.estado = 'visible' AND e.padre_id = p_padre_id
    ),
    mandona AS (
        SELECT DISTINCT ON (i.categoria_id) i.categoria_id, i.imagen
          FROM ecommerce.categorias_imagenes i
         WHERE i.deleted_at IS NULL AND i.activo
           AND ecommerce.fn_vigente(i.desde, i.hasta)
         ORDER BY i.categoria_id, i.orden, i.id
    )
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'id', h.id, 'nombre', h.nombre, 'imagen', m.imagen,
               'enlace', COALESCE(ecommerce.fn_cuerpo_de_categoria(h.id), '/shop?categoria=' || h.id))
           ORDER BY h.orden, h.nombre), '[]'::jsonb)
      FROM hijas h
      LEFT JOIN mandona m ON m.categoria_id = h.id;
$function$;

CREATE OR REPLACE FUNCTION ecommerce.fn_categorias_promocion_hijas_publicas(p_padre_id bigint)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
AS $function$
    WITH hijas AS (
        SELECT e.id, e.nombre, e.orden, e.promocion_orden
          FROM ecommerce.fn_categorias_web_estado() e
         WHERE e.estado = 'visible' AND e.promocion AND e.padre_id = p_padre_id
    ),
    mandona AS (
        SELECT DISTINCT ON (i.categoria_id) i.categoria_id, i.imagen
          FROM ecommerce.categorias_imagenes i
         WHERE i.deleted_at IS NULL AND i.activo
           AND ecommerce.fn_vigente(i.desde, i.hasta)
         ORDER BY i.categoria_id, i.orden, i.id
    )
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'id', h.id, 'nombre', h.nombre, 'imagen', m.imagen,
               'enlace', COALESCE(ecommerce.fn_cuerpo_de_categoria(h.id), '/shop?categoria=' || h.id))
           ORDER BY h.promocion_orden NULLS LAST, h.orden, h.nombre), '[]'::jsonb)
      FROM hijas h
      LEFT JOIN mandona m ON m.categoria_id = h.id;
$function$;

CREATE OR REPLACE FUNCTION ecommerce.fn_categorias_de_marca_publicas(p_marca_id bigint)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
AS $function$
    WITH suyas AS (
        SELECT e.id, e.nombre, e.orden
          FROM ecommerce.fn_categorias_web_estado() e
         WHERE e.estado = 'visible'
           AND EXISTS (SELECT 1 FROM inventarios.productos p
                        WHERE p.marca_id = p_marca_id AND p.deleted_at IS NULL AND p.activo
                          AND p.categoria_id = e.id)
    ),
    mandona AS (
        SELECT DISTINCT ON (i.categoria_id) i.categoria_id, i.imagen
          FROM ecommerce.categorias_imagenes i
         WHERE i.deleted_at IS NULL AND i.activo
           AND ecommerce.fn_vigente(i.desde, i.hasta)
         ORDER BY i.categoria_id, i.orden, i.id
    )
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'id', s.id, 'nombre', s.nombre, 'imagen', m.imagen,
               -- Con la marca puesta: se está mirando una página de marca, y
               -- su categoría sin esa marca enseñaría cosas de otras
               'enlace', COALESCE(ecommerce.fn_cuerpo_de_categoria(s.id),
                                  '/shop?categoria=' || s.id || '&marca=' || p_marca_id))
           ORDER BY s.orden, s.nombre), '[]'::jsonb)
      FROM suyas s
      LEFT JOIN mandona m ON m.categoria_id = s.id;
$function$;

-- ----------------------------------------------------------------------------
-- 4. LAS MARCAS
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ecommerce.fn_marcas_publicas()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
AS $function$
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'id', e.id,
               'nombre', e.nombre,
               -- El del catálogo de Inventarios, que vive en img/marcas. Es el
               -- que se sube en el CRUD de marcas y el que se quiere ver aquí:
               -- esta sección es una tira de logos.
               'logo', e.logo,
               'enlace', COALESCE(ecommerce.fn_cuerpo_de_marca(e.id), '/shop?marca=' || e.id))
           ORDER BY e.orden_web NULLS LAST, e.nombre), '[]'::jsonb)
      FROM ecommerce.fn_marcas_web_estado() e
     WHERE e.estado = 'visible';
$function$;

CREATE OR REPLACE FUNCTION ecommerce.fn_marcas_de_categoria_publicas(p_categoria_id bigint)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
AS $function$
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'id', e.id,
               'nombre', e.nombre,
               'logo', e.logo,
               -- Con cuerpo propio, a su página; si no, al catálogo filtrado
               -- por la marca Y por la categoría, que es lo que se estaba
               -- mirando
               'enlace', COALESCE(ecommerce.fn_cuerpo_de_marca(e.id),
                                  '/shop?marca=' || e.id || '&categoria=' || p_categoria_id))
           ORDER BY e.orden_web NULLS LAST, e.nombre), '[]'::jsonb)
      FROM ecommerce.fn_marcas_web_estado() e
     WHERE e.estado = 'visible'
       AND EXISTS (SELECT 1 FROM inventarios.productos p
                    WHERE p.marca_id = e.id AND p.deleted_at IS NULL AND p.activo
                      AND p.categoria_id = ANY (ecommerce.fn_categorias_rama(p_categoria_id)));
$function$;

-- Los carteles de «Marcas en promoción» no llevaban enlace: el cartel lo
-- armaba la tienda. Ahora lo trae hecho, como todo lo demás.
CREATE OR REPLACE FUNCTION ecommerce.fn_marcas_promocion_publicas()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
AS $function$
    WITH enPromocion AS (
        SELECT e.id, e.nombre, e.logo, e.orden_web, e.promocion_orden
          FROM ecommerce.fn_marcas_web_estado() e
         -- Oculta o inactiva no sale, aunque esté marcada: lo que no se ve en
         -- la tienda no puede salir en un cartel de la portada
         WHERE e.estado = 'visible' AND e.promocion
    ),
    mandona AS (
        SELECT DISTINCT ON (i.marca_id) i.marca_id, i.imagen
          FROM ecommerce.marcas_imagenes i
         WHERE i.deleted_at IS NULL AND i.activo
           AND ecommerce.fn_vigente(i.desde, i.hasta)
         ORDER BY i.marca_id, i.orden, i.id
    )
    -- SÓLO LA IMAGEN PROGRAMADA, SIN EL LOGO DE RESPALDO, y es a propósito:
    -- el cartel pone la foto a sangre, de arriba abajo, y un logo —ancho y
    -- con sus márgenes— sale recortado por la mitad. Sin foto el cartel se
    -- pinta igual con su color y su nombre, que es exactamente lo que hacen
    -- las categorías. Para que una marca salga con foto, se le programa una
    -- imagen, igual que a una categoría.
    --
    -- Al no venir la llave `logo`, el controlador no tiene nada con lo que
    -- rellenar y deja la imagen en null: no hace falta que sepa de esto.
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'id', p.id,
               'nombre', p.nombre,
               'imagen', m.imagen,
               'enlace', COALESCE(ecommerce.fn_cuerpo_de_marca(p.id), '/shop?marca=' || p.id))
           ORDER BY p.promocion_orden NULLS LAST, p.orden_web NULLS LAST, p.nombre), '[]'::jsonb)
      FROM enPromocion p
      LEFT JOIN mandona m ON m.marca_id = p.id;
$function$;

-- ----------------------------------------------------------------------------
-- 5. FUERA EL MAPA DEL ENCABEZADO
-- ----------------------------------------------------------------------------
-- Lo puso el fichero anterior para que la tienda resolviera los enlaces por su
-- cuenta. Ya no hace falta: cada lista trae el suyo hecho, y dos maneras de
-- resolver lo mismo acaban diciendo cosas distintas.
DO $cirugia$
DECLARE
    v_def text;
BEGIN
    SELECT pg_get_functiondef(p.oid) INTO v_def
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'ecommerce' AND p.proname = 'fn_secciones_publicas';

    IF v_def IS NULL THEN
        RAISE EXCEPTION 'No está ecommerce.fn_secciones_publicas';
    END IF;

    -- El guardia mira lo NUEVO: sin el mapa, no hay nada que quitar
    IF position('fn_cuerpos_publicos' IN v_def) = 0 THEN
        RAISE NOTICE 'El encabezado ya no lleva el mapa de cuerpos.';
    ELSE
        v_def := replace(v_def,
            '''cuerpos'', ecommerce.fn_cuerpos_publicos(),' || E'\n            ', '');
        IF position('fn_cuerpos_publicos' IN v_def) > 0 THEN
            RAISE EXCEPTION 'No pude quitar el mapa de cuerpos del encabezado';
        END IF;
        EXECUTE v_def;
        RAISE NOTICE 'Quitado el mapa de cuerpos del encabezado.';
    END IF;
END
$cirugia$;

DROP FUNCTION IF EXISTS ecommerce.fn_cuerpos_publicos();

-- ----------------------------------------------------------------------------
-- 6. COMPROBACIÓN
-- ----------------------------------------------------------------------------
DO $comprobar$
DECLARE
    v_categoria bigint;
    v_marca     bigint;
    v_cuerpo    bigint;
    v_enlace    text;
    v_menu      jsonb;
BEGIN
    -- Una categoría visible cualquiera, y una marca visible cualquiera
    SELECT id INTO v_categoria FROM ecommerce.fn_categorias_web_estado()
     WHERE estado = 'visible' ORDER BY id LIMIT 1;
    SELECT id INTO v_marca FROM ecommerce.fn_marcas_web_estado()
     WHERE estado = 'visible' ORDER BY id LIMIT 1;

    IF v_categoria IS NULL OR v_marca IS NULL THEN
        RAISE EXCEPTION 'Sin categorías o marcas visibles no se puede comprobar';
    END IF;

    -- Sin cuerpo, al catálogo de siempre
    IF ecommerce.fn_cuerpo_de_categoria(v_categoria) IS NOT NULL THEN
        RAISE NOTICE 'La categoría % ya tiene página: me salto esa parte', v_categoria;
    ELSE
        v_menu := ecommerce.fn_categorias_web_menu_publico();
        IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_menu) d
                        WHERE d ->> 'enlace' LIKE '/shop?categoria=%') THEN
            RAISE EXCEPTION 'El menú no trae enlaces al catálogo: %', v_menu;
        END IF;
    END IF;

    IF ecommerce.fn_secciones_publicas()::text LIKE '%"cuerpos"%' THEN
        RAISE EXCEPTION 'El encabezado sigue llevando el mapa de cuerpos';
    END IF;

    BEGIN
        -- Con página, el enlace cambia solo en TODAS las listas
        v_cuerpo := (ecommerce.fn_cuerpos_guardar(NULL, jsonb_build_object(
                         'nombre', 'ZZ enlace claude', 'ruta', 'zz-enlace-claude',
                         'categoria_id', v_categoria)) -> 'data' ->> 'id')::bigint;

        IF ecommerce.fn_cuerpo_de_categoria(v_categoria) <> '/zz-enlace-claude' THEN
            RAISE EXCEPTION 'La categoría con página tiene que llevar a su página: %',
                  ecommerce.fn_cuerpo_de_categoria(v_categoria);
        END IF;

        -- El menú
        v_menu := ecommerce.fn_categorias_web_menu_publico();
        IF v_menu::text NOT LIKE '%/zz-enlace-claude%' THEN
            RAISE EXCEPTION 'El menú no se enteró de que la categoría tiene página';
        END IF;

        -- Las destacadas y el mosaico, si esa categoría está en ellos
        SELECT d ->> 'enlace' INTO v_enlace
          FROM jsonb_array_elements(ecommerce.fn_categorias_destacadas_publicas()) d
         WHERE (d ->> 'id')::bigint = v_categoria;
        IF v_enlace IS NOT NULL AND v_enlace <> '/zz-enlace-claude' THEN
            RAISE EXCEPTION 'Las destacadas no se enteraron: %', v_enlace;
        END IF;

        -- Apagado, los enlaces vuelven al catálogo
        PERFORM ecommerce.fn_cuerpos_activar(v_cuerpo, false);
        IF ecommerce.fn_cuerpo_de_categoria(v_categoria) IS NOT NULL THEN
            RAISE EXCEPTION 'Una página apagada no puede seguir recibiendo clics';
        END IF;

        RAISE EXCEPTION 'deshacer' USING ERRCODE = 'P0099';
    EXCEPTION WHEN SQLSTATE 'P0099' THEN
        NULL;
    END;

    -- Y las marcas siguen trayendo el suyo
    SELECT m ->> 'enlace' INTO v_enlace
      FROM jsonb_array_elements(ecommerce.fn_marcas_publicas()) m
     WHERE (m ->> 'id')::bigint = v_marca;
    IF v_enlace IS NULL THEN
        RAISE EXCEPTION 'Una marca visible se quedó sin enlace';
    END IF;

    IF EXISTS (SELECT 1 FROM ecommerce.cuerpos WHERE nombre LIKE 'ZZ %claude') THEN
        RAISE EXCEPTION 'El cuerpo de prueba se quedó en la base';
    END IF;

    RAISE NOTICE 'Comprobado: cada categoría y cada marca traen su enlace hecho, con página van a su página, apagada vuelven al catálogo y el encabezado ya no lleva el mapa. No quedó nada.';
END
$comprobar$;

COMMIT;
