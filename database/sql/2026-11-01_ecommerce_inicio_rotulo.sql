-- ============================================================================
-- EL RÓTULO DE CADA SECCIÓN VIAJA A LA TIENDA
--
-- La portada ya guardaba un `titulo` por sección, pero `fn_inicio_publico` no
-- lo mandaba: la tienda pintaba «Categorías Destacadas» porque lo tenía
-- escrito en su código. Así, cambiar ese rótulo para una campaña —«Lo más
-- buscado», «Regalos de navidad»— era tocar el código de la tienda y volver a
-- publicarla.
--
-- A PARTIR DE AQUÍ EL RÓTULO LO PONE QUIEN ADMINISTRA, desde «Inicio de la
-- tienda», y la tienda lo pinta tal cual. VACÍO SIGUE VALIENDO: la sección se
-- ve como hasta hoy, con el rótulo que la tienda trae de fábrica o sin
-- ninguno. Por eso el campo no se vuelve obligatorio y las ocho secciones
-- siguen saliendo igual sin tocar nada.
--
-- El rótulo viaja en TODAS las secciones, también en las que hoy no lo pintan
-- (los dos banners son imágenes de borde a borde). Mandarlo siempre es una
-- regla menos que recordar cuando la tienda cambie de idea, y una sección que
-- no lo usa simplemente lo ignora.
--
-- Idempotente: sólo rehace una función.
-- ============================================================================

BEGIN;

-- ----------------------------------------------------------------------------
-- 1. LA PORTADA QUE LEE LA TIENDA, AHORA CON SU RÓTULO
-- ----------------------------------------------------------------------------
-- Igual que antes —sólo las encendidas, en vigencia y con algo que enseñar—,
-- con `titulo` y `subtitulo` añadidos a cada sección. Van NULL cuando están
-- vacíos: la tienda distingue «no se puso» de «se puso en blanco» sin tener
-- que recortar espacios.
CREATE OR REPLACE FUNCTION ecommerce.fn_inicio_publico()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
AS $function$
    WITH visibles AS (
        SELECT s.clave, s.hasta, s.orden,
               nullif(btrim(COALESCE(s.titulo, '')), '')    AS titulo,
               nullif(btrim(COALESCE(s.subtitulo, '')), '') AS subtitulo
          FROM ecommerce.inicio_secciones s
         WHERE s.activo AND ecommerce.fn_vigente(s.desde, s.hasta)
    ),
    armadas AS (
        SELECT v.orden, v.titulo, v.subtitulo,
               CASE v.clave
                   WHEN 'banner_principal' THEN
                        jsonb_build_object('clave', v.clave,
                            'imagenes', COALESCE(ecommerce.fn_galerias_publica('inicio_banner') -> 'imagenes', '[]'::jsonb))
                   WHEN 'banner_simple' THEN
                        jsonb_build_object('clave', v.clave,
                            'imagenes', COALESCE(ecommerce.fn_galerias_publica('inicio_banner_simple') -> 'imagenes', '[]'::jsonb))
                   WHEN 'mosaico' THEN
                        jsonb_build_object('clave', v.clave,
                            'categorias', ecommerce.fn_categorias_promocion_publicas())
                   WHEN 'categorias_destacadas' THEN
                        jsonb_build_object('clave', v.clave,
                            'categorias', ecommerce.fn_categorias_destacadas_publicas())
                   WHEN 'marcas' THEN
                        jsonb_build_object('clave', v.clave,
                            'marcas', ecommerce.fn_marcas_publicas())
                   ELSE NULL
               END AS seccion
          FROM visibles v
    )
    SELECT jsonb_build_object('secciones', COALESCE(jsonb_agg(
               -- El rótulo se añade aquí y no en cada rama: es de la sección,
               -- no de lo que la llena, y así no se olvida en la siguiente
               a.seccion || jsonb_build_object('titulo', a.titulo, 'subtitulo', a.subtitulo)
               ORDER BY a.orden), '[]'::jsonb))
      FROM armadas a
     WHERE a.seccion IS NOT NULL
       AND (a.seccion -> 'imagenes'   IS NULL OR jsonb_array_length(a.seccion -> 'imagenes') > 0)
       AND (a.seccion -> 'categorias' IS NULL OR jsonb_array_length(a.seccion -> 'categorias') > 0)
       AND (a.seccion -> 'marcas'     IS NULL OR jsonb_array_length(a.seccion -> 'marcas') > 0);
$function$;

-- ----------------------------------------------------------------------------
-- 2. QUE EL RÓTULO LLEGUE, Y QUE BORRARLO TAMBIÉN LLEGUE
-- ----------------------------------------------------------------------------
-- Se prueba sobre una sección que de verdad esté saliendo hoy —cuál da igual—
-- y NO SE LE CAMBIA NADA: las dos pruebas van dentro de un bloque con
-- EXCEPTION, que en plpgsql es una subtransacción. Al salir de él con un error
-- se deshacen sus UPDATE, mientras que las variables se quedan con lo que
-- leyeron: son memoria, no base. Así el rótulo del usuario no se toca, no
-- queda un «último cambio» falso y la auditoría no se llena de ruido.
DO $comprobar$
DECLARE
    v_clave  text;
    v_antes  text;
    v_puesto text;
    v_vacio  text;
    v_cuantas integer;
    v_con_clave integer;
BEGIN
    SELECT jsonb_array_length(ecommerce.fn_inicio_publico() -> 'secciones') INTO v_cuantas;
    IF COALESCE(v_cuantas, 0) = 0 THEN
        RAISE EXCEPTION 'Hoy no sale ninguna sección en la portada: no se puede comprobar el rótulo';
    END IF;

    -- Todas tienen que traer la clave y el par del rótulo, aunque vaya vacío:
    -- una sección a la que le falte la pareja obliga a la tienda a adivinar
    SELECT count(*) INTO v_con_clave
      FROM jsonb_array_elements(ecommerce.fn_inicio_publico() -> 'secciones') s
     WHERE COALESCE(s ->> 'clave', '') <> ''
       AND s ? 'titulo' AND s ? 'subtitulo';
    IF v_con_clave <> v_cuantas THEN
        RAISE EXCEPTION 'De % secciones, sólo % traen clave y rótulo', v_cuantas, v_con_clave;
    END IF;

    SELECT s ->> 'clave' INTO v_clave
      FROM jsonb_array_elements(ecommerce.fn_inicio_publico() -> 'secciones') s LIMIT 1;

    SELECT titulo INTO v_antes FROM ecommerce.inicio_secciones WHERE clave = v_clave;

    BEGIN
        -- Puesto, llega tal cual
        UPDATE ecommerce.inicio_secciones SET titulo = 'ZZ rótulo de prueba' WHERE clave = v_clave;
        SELECT s ->> 'titulo' INTO v_puesto
          FROM jsonb_array_elements(ecommerce.fn_inicio_publico() -> 'secciones') s
         WHERE s ->> 'clave' = v_clave;

        -- En blanco, llega vacío y no como una cadena de espacios
        UPDATE ecommerce.inicio_secciones SET titulo = '   ' WHERE clave = v_clave;
        SELECT s ->> 'titulo' INTO v_vacio
          FROM jsonb_array_elements(ecommerce.fn_inicio_publico() -> 'secciones') s
         WHERE s ->> 'clave' = v_clave;

        -- Y aquí se deshace todo lo de arriba
        RAISE EXCEPTION 'deshacer la prueba' USING ERRCODE = 'P0001';
    EXCEPTION WHEN SQLSTATE 'P0001' THEN
        NULL;
    END;

    IF v_puesto IS DISTINCT FROM 'ZZ rótulo de prueba' THEN
        RAISE EXCEPTION 'El rótulo de «%» no llega a la tienda (llegó «%»)', v_clave, COALESCE(v_puesto, 'nada');
    END IF;
    IF v_vacio IS NOT NULL THEN
        RAISE EXCEPTION 'Un rótulo en blanco llega como «%» en vez de vacío', v_vacio;
    END IF;

    -- Y la sección se quedó como estaba
    IF (SELECT titulo FROM ecommerce.inicio_secciones WHERE clave = v_clave) IS DISTINCT FROM v_antes THEN
        RAISE EXCEPTION 'La prueba cambió el rótulo de «%»', v_clave;
    END IF;

    RAISE NOTICE 'Comprobado: las % secciones de hoy llevan su rótulo, y en blanco viaja vacío.', v_cuantas;
END
$comprobar$;

COMMIT;
