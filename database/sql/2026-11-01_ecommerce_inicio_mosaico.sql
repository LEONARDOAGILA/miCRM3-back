-- ============================================================================
-- ECOMMERCE · EL MOSAICO DE LA PORTADA YA TIENE DE DÓNDE COMER
-- ============================================================================
-- Fecha: 2026-11-01
--
-- La sección `mosaico` de la portada enseña una tarjeta por categoría con su
-- imagen. Hasta ahora no tenía fuente —no había imagen por categoría— y la
-- portada se la saltaba.
--
-- Ya la hay: `ecommerce.categorias_imagenes`. Y la regla es la más simple que
-- se puede explicar: PROGRAMAR UNA IMAGEN ES LO QUE METE LA CATEGORÍA EN EL
-- MOSAICO. No hay que encenderla en otro sitio, ni marcarla, ni acordarse de
-- dos cosas; si tiene imagen vigente hoy, sale.
--
-- Idempotente.
-- ============================================================================
\set ON_ERROR_STOP on

BEGIN;

-- ----------------------------------------------------------------------------
-- 1. EL MOSAICO YA NO ESTÁ PENDIENTE
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ecommerce.fn_inicio_fuente(p_clave text)
 RETURNS jsonb
 LANGUAGE sql
 IMMUTABLE
AS $function$
    SELECT CASE p_clave
        WHEN 'banner_principal' THEN
            jsonb_build_object('tipo', 'galeria', 'galeria', 'inicio_banner')
        WHEN 'banner_simple' THEN
            jsonb_build_object('tipo', 'galeria', 'galeria', 'inicio_banner_simple')
        -- Se llena en «Categorías de la tienda»: la categoría que tenga
        -- imagen vigente sale aquí.
        WHEN 'mosaico' THEN
            jsonb_build_object('tipo', 'categorias', 'pantalla', 'allCategoriasWeb')
        WHEN 'categorias_destacadas' THEN
            jsonb_build_object('tipo', 'pendiente', 'falta', 'la marca de «destacada» en las categorías')
        WHEN 'ofertas_flash' THEN
            jsonb_build_object('tipo', 'pendiente', 'falta', 'el catálogo de la tienda (precio y existencias)')
        WHEN 'grilla' THEN
            jsonb_build_object('tipo', 'pendiente', 'falta', 'el catálogo de la tienda (precio y existencias)')
        WHEN 'bloques' THEN
            jsonb_build_object('tipo', 'pendiente', 'falta', 'los bloques de productos destacados')
        WHEN 'marcas' THEN
            jsonb_build_object('tipo', 'pendiente', 'falta', 'las marcas de la tienda')
        ELSE jsonb_build_object('tipo', 'pendiente', 'falta', 'su fuente')
    END;
$function$;

-- La cuenta de la pantalla: cuántas categorías saldrían hoy en el mosaico.
CREATE OR REPLACE FUNCTION ecommerce.fn_inicio_listar()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
AS $function$
    SELECT jsonb_build_object('success', true, 'message', 'Portada de la tienda',
        'data', COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
                       'id',         s.id,
                       'clave',      s.clave,
                       'nombre',     s.nombre,
                       'titulo',     s.titulo,
                       'subtitulo',  s.subtitulo,
                       'orden',      s.orden,
                       'activo',     s.activo,
                       'desde',      to_char(s.desde, 'YYYY-MM-DD"T"HH24:MI'),
                       'hasta',      to_char(s.hasta, 'YYYY-MM-DD"T"HH24:MI'),
                       'updated_at', to_char(s.updated_at, 'YYYY-MM-DD HH24:MI'),
                       'updated_by', s.updated_by,
                       'estado',     CASE
                           WHEN NOT s.activo THEN 'oculta'
                           WHEN s.desde IS NOT NULL AND CURRENT_TIMESTAMP < s.desde THEN 'programada'
                           WHEN s.hasta IS NOT NULL AND CURRENT_TIMESTAMP > s.hasta THEN 'terminada'
                           ELSE 'visible' END,
                       'fuente',     ecommerce.fn_inicio_fuente(s.clave),
                       -- Cuántas cosas tiene hoy, cuando se puede saber
                       'cuantas',    CASE ecommerce.fn_inicio_fuente(s.clave) ->> 'tipo'
                           WHEN 'galeria' THEN
                               (SELECT count(*) FROM ecommerce.galerias_imagenes i
                                  JOIN ecommerce.galerias g ON g.id = i.galeria_id
                                 WHERE g.clave = ecommerce.fn_inicio_fuente(s.clave) ->> 'galeria'
                                   AND i.deleted_at IS NULL)
                           WHEN 'categorias' THEN
                               jsonb_array_length(ecommerce.fn_categorias_imagenes_publicas())
                           END,
                       'con_contenido', CASE ecommerce.fn_inicio_fuente(s.clave) ->> 'tipo'
                           WHEN 'galeria' THEN
                               EXISTS (SELECT 1 FROM ecommerce.galerias_imagenes i
                                         JOIN ecommerce.galerias g ON g.id = i.galeria_id
                                        WHERE g.clave = ecommerce.fn_inicio_fuente(s.clave) ->> 'galeria'
                                          AND i.deleted_at IS NULL AND i.activo
                                          AND ecommerce.fn_vigente(i.desde, i.hasta))
                           WHEN 'categorias' THEN
                               jsonb_array_length(ecommerce.fn_categorias_imagenes_publicas()) > 0
                           ELSE false END)
                   ORDER BY s.orden, s.id)
              FROM ecommerce.inicio_secciones s), '[]'::jsonb));
$function$;

-- ----------------------------------------------------------------------------
-- 2. Y LA PORTADA PÚBLICA LO ENSEÑA
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ecommerce.fn_inicio_publico()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
AS $function$
    WITH visibles AS (
        SELECT s.clave, s.titulo, s.subtitulo, s.hasta, s.orden
          FROM ecommerce.inicio_secciones s
         WHERE s.activo AND ecommerce.fn_vigente(s.desde, s.hasta)
    ),
    armadas AS (
        SELECT v.orden, v.clave,
               CASE v.clave
                   -- Los dos banners salen de su galería. `imagenes` trae el
                   -- NOMBRE del fichero; el controlador le pone la dirección.
                   WHEN 'banner_principal' THEN
                        jsonb_build_object('clave', v.clave,
                            'imagenes', COALESCE(ecommerce.fn_galerias_publica('inicio_banner') -> 'imagenes', '[]'::jsonb))
                   WHEN 'banner_simple' THEN
                        jsonb_build_object('clave', v.clave,
                            'imagenes', COALESCE(ecommerce.fn_galerias_publica('inicio_banner_simple') -> 'imagenes', '[]'::jsonb))
                   -- Una tarjeta por categoría con imagen vigente hoy
                   WHEN 'mosaico' THEN
                        jsonb_build_object('clave', v.clave,
                            'categorias', ecommerce.fn_categorias_imagenes_publicas())
                   -- Las demás todavía no tienen de dónde sacar datos. Se
                   -- devuelven como NULL y se caen en el filtro de abajo; la
                   -- tienda ni se entera.
                   ELSE NULL
               END AS seccion
          FROM visibles v
    )
    SELECT jsonb_build_object('secciones', COALESCE(jsonb_agg(a.seccion ORDER BY a.orden), '[]'::jsonb))
      FROM armadas a
     WHERE a.seccion IS NOT NULL
       -- Y si la sección se quedó sin contenido, tampoco sale: un título con
       -- nada debajo es peor que no estar.
       AND (a.seccion -> 'imagenes'   IS NULL OR jsonb_array_length(a.seccion -> 'imagenes') > 0)
       AND (a.seccion -> 'categorias' IS NULL OR jsonb_array_length(a.seccion -> 'categorias') > 0);
$function$;

-- ----------------------------------------------------------------------------
-- 3. QUE HAGA LO QUE DICE
-- ----------------------------------------------------------------------------
DO $comprobar$
DECLARE
    v_cat    bigint;
    v_fuente text;
    v_id     bigint;
    v_antes  integer;
    v_con    integer;
BEGIN
    SELECT ecommerce.fn_inicio_fuente('mosaico') ->> 'tipo' INTO v_fuente;
    IF v_fuente IS DISTINCT FROM 'categorias' THEN
        RAISE EXCEPTION 'El mosaico sigue sin fuente (dice «%»)', COALESCE(v_fuente, 'nada');
    END IF;

    SELECT count(*) INTO v_antes
      FROM jsonb_array_elements(ecommerce.fn_inicio_publico() -> 'secciones') s
     WHERE s ->> 'clave' = 'mosaico';

    IF v_antes <> 0 THEN
        RAISE EXCEPTION 'Sin ninguna categoría con imagen, el mosaico no debería salir';
    END IF;

    -- Una categoría que de verdad esté en la tienda
    SELECT e.id INTO v_cat FROM ecommerce.fn_categorias_web_estado() e
     WHERE e.estado = 'visible' ORDER BY e.orden, e.id LIMIT 1;
    IF v_cat IS NULL THEN
        RAISE EXCEPTION 'No hay ninguna categoría visible en la tienda con la que comprobar';
    END IF;

    PERFORM ecommerce.fn_categorias_imagenes_guardar(NULL, v_cat,
        jsonb_build_object('imagen', 'zz-mosaico.png', 'nombre', 'ZZ mosaico'));

    SELECT jsonb_array_length(s -> 'categorias') INTO v_con
      FROM jsonb_array_elements(ecommerce.fn_inicio_publico() -> 'secciones') s
     WHERE s ->> 'clave' = 'mosaico';

    -- Fuera lo de la prueba antes de juzgar, para no dejar basura si falla
    SELECT id INTO v_id FROM ecommerce.categorias_imagenes
     WHERE categoria_id = v_cat AND nombre = 'ZZ mosaico';
    DELETE FROM ecommerce.categorias_imagenes WHERE id = v_id;

    IF v_con IS NULL OR v_con < 1 THEN
        RAISE EXCEPTION 'Con una categoría con imagen, el mosaico debería traerla (trajo %)',
              COALESCE(v_con::text, 'nada');
    END IF;

    RAISE NOTICE 'Comprobado: el mosaico sale sólo cuando hay categorías con imagen vigente (salió con %).', v_con;
END
$comprobar$;

COMMIT;
