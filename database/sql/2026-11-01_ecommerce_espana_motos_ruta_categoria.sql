-- ============================================================================
-- ESPAÑA MOTOS: las categorías de una pestaña, por su RUTA
-- ----------------------------------------------------------------------------
-- La fila de una pestaña enseñaba el nombre suelto de cada categoría, y el
-- combo donde se eligen enseña la ruta entera («Línea Blanca > Refrigeración»).
-- Fuera del árbol, «Refrigeración» a secas no dice de qué: hay una debajo de
-- Línea Blanca y puede haber otra debajo de Vehículos, y en la fila se verían
-- iguales. Peor aún, se elige mirando una cosa y se comprueba mirando otra.
--
-- Se añade `inventarios.fn_categoria_ruta`, que arma la misma ruta que ya
-- devuelve `inventarios.fn_categorias_json`, y se usa aquí. Vive en
-- inventarios porque el árbol es suyo: ecommerce sólo lo lee.
--
-- Se puede volver a ejecutar sin romper nada.
-- ============================================================================
\set ON_ERROR_STOP on
\pset tuples_only on
\pset format unaligned
BEGIN;

-- ----------------------------------------------------------------------------
-- 1. LA RUTA DE UNA CATEGORÍA
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION inventarios.fn_categoria_ruta(p_id bigint)
 RETURNS text
 LANGUAGE sql
 STABLE
AS $function$
    WITH RECURSIVE subida AS (
        SELECT c.id, c.padre_id, c.nombre, 0 AS salto
          FROM inventarios.categorias c
         WHERE c.id = p_id
        UNION ALL
        SELECT p.id, p.padre_id, p.nombre, s.salto + 1
          FROM inventarios.categorias p
          JOIN subida s ON s.padre_id = p.id
    )
    SELECT string_agg(s.nombre, ' > ' ORDER BY s.salto DESC) FROM subida s;
$function$;

COMMENT ON FUNCTION inventarios.fn_categoria_ruta(bigint) IS
    'La ruta completa de una categoría, «Padre > Hija», como la enseña el combo.';

-- ----------------------------------------------------------------------------
-- 2. Y LA PANTALLA DE ESPAÑA MOTOS LA USA
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ecommerce.fn_espana_motos_obtener()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
AS $function$
    SELECT jsonb_build_object('success', true, 'message', 'España Motos',
        'data', jsonb_build_object(
            'publicada',           e.publicada,
            'banner_visible',      e.banner_visible,
            'galeria_banner',      (SELECT clave FROM ecommerce.galerias g WHERE g.id = e.galeria_banner_id),
            'fondo_visible',       e.fondo_visible,
            'fondo_imagen',        e.fondo_imagen,
            'fondo_titulo',        e.fondo_titulo,
            'fondo_subtitulo',     e.fondo_subtitulo,
            'tarjetas_visible',    e.tarjetas_visible,
            'galeria_tarjetas',    (SELECT clave FROM ecommerce.galerias g WHERE g.id = e.galeria_tarjetas_id),
            'marcas_visible',      e.marcas_visible,
            'updated_at',          to_char(e.updated_at, 'YYYY-MM-DD HH24:MI:SS'),
            'updated_by',          e.updated_by,

            -- Las pestañas, con la RUTA de cada categoría al lado: sin eso la
            -- pantalla enseñaría «416, 420» y nadie sabría qué son, y con el
            -- nombre suelto no se distinguen dos «Refrigeración» de ramas
            -- distintas.
            'pestanas', COALESCE((
                SELECT jsonb_agg(jsonb_build_object(
                           'id', p.id, 'nombre', p.nombre, 'orden', p.orden, 'activo', p.activo,
                           'categorias', p.categorias,
                           'categorias_nombres', COALESCE((
                               SELECT jsonb_agg(jsonb_build_object(
                                          'id', c.id,
                                          'nombre', inventarios.fn_categoria_ruta(c.id))
                                      ORDER BY inventarios.fn_categoria_ruta(c.id))
                                 FROM inventarios.categorias c
                                WHERE c.id = ANY(p.categorias) AND c.deleted_at IS NULL), '[]'::jsonb))
                       ORDER BY p.orden, p.id)
                  FROM ecommerce.espana_motos_pestanas p WHERE p.deleted_at IS NULL), '[]'::jsonb),

            'marcas', COALESCE((
                SELECT jsonb_agg(jsonb_build_object(
                           'id', m.id, 'marca_id', m.marca_id, 'orden', m.orden, 'activo', m.activo,
                           'nombre', mk.nombre)
                       ORDER BY m.orden, m.id)
                  FROM ecommerce.espana_motos_marcas m
                  JOIN inventarios.marcas mk ON mk.id = m.marca_id
                 WHERE m.deleted_at IS NULL), '[]'::jsonb)))
      FROM ecommerce.espana_motos e WHERE e.id = 1;
$function$;

-- ---------------------------------------------------------------------------
-- Comprobación, con una categoría que de verdad cuelgue de otra. Todo se
-- calcula sin condiciones, para que un NULL no deje pasar la prueba en verde.
-- ---------------------------------------------------------------------------
DO $c$
DECLARE
    v_hija   bigint;
    v_ruta   text;
    v_nombre text;
    v_pest   bigint;
    v_datos  jsonb;
    v_leido  text;
BEGIN
    SELECT c.id INTO v_hija
      FROM inventarios.categorias c
      JOIN inventarios.categorias p ON p.id = c.padre_id
     WHERE c.deleted_at IS NULL AND p.deleted_at IS NULL
     LIMIT 1;

    IF v_hija IS NULL THEN
        RAISE EXCEPTION 'No hay ninguna categoría con padre con la que comprobar';
    END IF;

    SELECT inventarios.fn_categoria_ruta(v_hija) INTO v_ruta;
    SELECT nombre INTO v_nombre FROM inventarios.categorias WHERE id = v_hija;

    IF v_ruta IS NULL OR strpos(v_ruta, ' > ') = 0 THEN
        RAISE EXCEPTION 'La ruta de la categoría % no trae a su padre: %', v_hija, COALESCE(v_ruta, 'nula');
    END IF;
    IF right(v_ruta, length(v_nombre)) <> v_nombre THEN
        RAISE EXCEPTION 'La ruta % no acaba en la propia categoría (%)', v_ruta, v_nombre;
    END IF;

    -- Y que la pantalla la enseñe así. Se crea una pestaña, se lee y se borra.
    v_datos := ecommerce.fn_espana_motos_pestanas_guardar(
                   NULL, 'ZZ comprobación ruta', jsonb_build_array(v_hija), true) -> 'data';

    SELECT (p ->> 'id')::bigint INTO v_pest
      FROM jsonb_array_elements(v_datos -> 'pestanas') p
     WHERE p ->> 'nombre' = 'ZZ comprobación ruta';

    SELECT p -> 'categorias_nombres' -> 0 ->> 'nombre' INTO v_leido
      FROM jsonb_array_elements(v_datos -> 'pestanas') p
     WHERE (p ->> 'id')::bigint = v_pest;

    PERFORM ecommerce.fn_espana_motos_quitar('pestana', v_pest);

    IF v_leido IS DISTINCT FROM v_ruta THEN
        RAISE EXCEPTION 'La pantalla enseña «%» donde la ruta es «%»',
              COALESCE(v_leido, 'nada'), v_ruta;
    END IF;

    RAISE NOTICE 'Comprobado: la pestaña enseña «%», la misma ruta del combo.', v_leido;
END
$c$;

COMMIT;
