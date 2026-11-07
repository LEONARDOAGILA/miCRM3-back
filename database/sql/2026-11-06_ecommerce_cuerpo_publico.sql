-- ============================================================================
-- ECOMMERCE · UN CUERPO, COMO LO PIDE LA TIENDA
-- ============================================================================
-- Fecha: 2026-11-06
-- Va DESPUÉS de 2026-11-06_ecommerce_secciones_por_cuerpo.sql.
--
-- La tienda pedía la portada y nada más (`fn_inicio_publico`). Ahora pide UNA
-- PÁGINA POR SU DIRECCIÓN y recibe lo mismo de siempre más lo que es del
-- cuerpo: su título, su texto y si debajo va el catálogo de su categoría.
--
--     fn_cuerpo_publico(NULL)          el principal  → /
--     fn_cuerpo_publico('movilidad')   su página     → /movilidad
--     fn_inicio_publico()              lo de antes, que ahora llama al de arriba
--
-- DEVUELVE NULL SI NO HAY PÁGINA: no existe, está apagada o está en la
-- papelera. El controlador lo convierte en un 404 y la tienda enseña su
-- pantalla de «no encontrado», que es la verdad: esa dirección no es nada.
--
-- EL ALCANCE DE CADA SECCIÓN. «Categorías destacadas», «Categorías en
-- promoción» y «Marcas» sacaban lo de toda la tienda. En la página de
-- Movilidad eso enseñaría categorías de Línea Blanca, así que cada sección
-- dice de dónde come:
--
--     alcance = 'tienda'   las destacadas / en promoción / las marcas, como siempre
--     alcance = 'cuerpo'   lo que cuelga de la categoría del cuerpo, o
--                          lo que tiene productos de su marca
--
-- Y EL ENCABEZADO LLEVA EL MAPA. Los enlaces a categorías y marcas se arman en
-- muchos sitios de la tienda (el menú, las destacadas, el mosaico, los logos).
-- En vez de que cada uno pregunte si esa categoría tiene página, el
-- encabezado —que la tienda pide al abrir CUALQUIER pantalla, y que ya viene
-- con caché— trae la lista de qué categoría y qué marca tienen cuerpo. Así la
-- tienda decide una vez, en un sitio.
--
-- Idempotente.
-- ============================================================================
\set ON_ERROR_STOP on

BEGIN;

-- ----------------------------------------------------------------------------
-- 1. LA RAMA DE UNA CATEGORÍA
-- ----------------------------------------------------------------------------
-- Ella y todo lo que cuelga. Los productos cuelgan de las hojas, así que
-- «las marcas de Movilidad» son las de sus hijas y nietas, no las suyas.
CREATE OR REPLACE FUNCTION ecommerce.fn_categorias_rama(p_id bigint)
 RETURNS bigint[]
 LANGUAGE sql
 STABLE
AS $function$
    WITH RECURSIVE bajada AS (
        SELECT c.id FROM inventarios.categorias c
         WHERE c.id = p_id AND c.deleted_at IS NULL
        UNION ALL
        SELECT h.id FROM inventarios.categorias h
          JOIN bajada b ON h.padre_id = b.id
         WHERE h.deleted_at IS NULL
    )
    SELECT COALESCE(array_agg(b.id), ARRAY[]::bigint[]) FROM bajada b;
$function$;

COMMENT ON FUNCTION ecommerce.fn_categorias_rama(bigint) IS
    'La categoría y todas sus descendientes. Los productos cuelgan de las hojas.';

-- ----------------------------------------------------------------------------
-- 2. LO QUE ENSEÑA UNA SECCIÓN CUANDO MIRA A SU CUERPO
-- ----------------------------------------------------------------------------
-- A DÓNDE LLEVA CADA CATEGORÍA Y CADA MARCA lo resuelve el fichero siguiente
-- (2026-11-06_ecommerce_enlaces_de_cuerpo.sql): cada lista trae su `enlace`
-- hecho, y por eso aquí no hay ningún mapa de cuerpos.
-- Las hijas visibles de una categoría, con la misma pinta que las destacadas:
-- la tienda pinta el mismo círculo o el mismo cuadro sin enterarse.
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
               'id', h.id, 'nombre', h.nombre, 'imagen', m.imagen)
           ORDER BY h.orden, h.nombre), '[]'::jsonb)
      FROM hijas h
      LEFT JOIN mandona m ON m.categoria_id = h.id;
$function$;

-- Las hijas que además están en promoción, para el mosaico de un cuerpo
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
               'id', h.id, 'nombre', h.nombre, 'imagen', m.imagen)
           ORDER BY h.promocion_orden NULLS LAST, h.orden, h.nombre), '[]'::jsonb)
      FROM hijas h
      LEFT JOIN mandona m ON m.categoria_id = h.id;
$function$;

-- Las marcas que tienen productos dentro de la rama de una categoría
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
               'enlace', COALESCE(
                   (SELECT '/' || c.ruta FROM ecommerce.cuerpos c
                     WHERE c.marca_id = e.id AND c.activo AND c.deleted_at IS NULL),
                   '/shop?marca=' || e.id || '&categoria=' || p_categoria_id))
           ORDER BY e.orden_web NULLS LAST, e.nombre), '[]'::jsonb)
      FROM ecommerce.fn_marcas_web_estado() e
     WHERE e.estado = 'visible'
       AND EXISTS (SELECT 1 FROM inventarios.productos p
                    WHERE p.marca_id = e.id AND p.deleted_at IS NULL AND p.activo
                      AND p.categoria_id = ANY (ecommerce.fn_categorias_rama(p_categoria_id)));
$function$;

-- Y las categorías que tienen productos de una marca, para la página de una marca
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
               'id', s.id, 'nombre', s.nombre, 'imagen', m.imagen)
           ORDER BY s.orden, s.nombre), '[]'::jsonb)
      FROM suyas s
      LEFT JOIN mandona m ON m.categoria_id = s.id;
$function$;

-- ----------------------------------------------------------------------------
-- 4. LA PÁGINA
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ecommerce.fn_cuerpo_publico(p_ruta text DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
AS $function$
    WITH elegido AS (
        SELECT c.*
          FROM ecommerce.cuerpos c
         WHERE c.deleted_at IS NULL AND c.activo
           AND CASE WHEN nullif(btrim(COALESCE(p_ruta, '')), '') IS NULL
                    THEN c.principal
                    ELSE c.ruta = lower(btrim(p_ruta)) END
    ),
    visibles AS (
        SELECT s.clave, s.hasta, s.orden, s.producto_seccion_id, g.clave AS galeria_clave,
               COALESCE(nullif(btrim(COALESCE(s.banner_vista, '')), ''), 'rotativo') AS banner_vista,
               s.segundos,
               COALESCE(nullif(btrim(COALESCE(s.forma, '')), ''), 'circulo') AS forma,
               COALESCE(nullif(btrim(COALESCE(s.alcance, '')), ''), 'tienda') AS alcance,
               nullif(btrim(COALESCE(s.titulo, '')), '')    AS titulo,
               nullif(btrim(COALESCE(s.subtitulo, '')), '') AS subtitulo,
               ecommerce.fn_rotulo_estilo(s.rotulo_tamano, s.rotulo_color, s.rotulo_fuente) AS estilo,
               ecommerce.fn_botones_colores(s.boton_favorito_color, s.boton_favorito_texto,
                                            s.boton_carrito_color,  s.boton_carrito_texto,
                                            s.boton_whatsapp_color, s.boton_whatsapp_texto,
                                            s.boton_tarjeta_color,  s.boton_tarjeta_texto) AS botones,
               ecommerce.fn_tarjeta_colores(s.tarjeta_fondo_color, s.tarjeta_borde_color,
                                            s.descuento_color,     s.descuento_texto,
                                            s.etiqueta, s.etiqueta_color, s.etiqueta_texto) AS tarjeta,
               ecommerce.fn_seccion_imagen(s.disposicion, s.imagen, s.imagen_alt,
                                           s.imagen_enlace, s.imagen_nueva_pestana) AS imagen,
               COALESCE(nullif(btrim(COALESCE(s.alto, '')), ''), 'normal') AS alto,
               e.categoria_id, e.marca_id
          FROM elegido e
          JOIN ecommerce.inicio_secciones s ON s.cuerpo_id = e.id
          LEFT JOIN ecommerce.galerias g ON g.id = s.galeria_id
         WHERE s.activo AND ecommerce.fn_vigente(s.desde, s.hasta)
           AND ecommerce.fn_inicio_seccion_viva(s.producto_seccion_id)
    ),
    armadas AS (
        SELECT v.orden, v.titulo, v.subtitulo, v.estilo, v.alto,
               CASE
                   -- Las de productos van primero y se reconocen por a quién
                   -- apuntan: su clave (`seccion_7`) la fabrica el servidor y
                   -- no hay lista donde buscarla.
                   WHEN v.producto_seccion_id IS NOT NULL THEN
                        jsonb_build_object('clave', 'productos',
                            'id', v.producto_seccion_id,
                            -- Cada cuántos segundos pasa sola de tarjeta; null = quieta
                            'segundos', v.segundos,
                            'botones', v.botones,
                            'tarjeta', v.tarjeta,
                            'imagen', v.imagen,
                            'productos', ecommerce.fn_producto_seccion_publica(v.producto_seccion_id))
                   WHEN v.clave = 'banner_principal' THEN
                        jsonb_build_object('clave', v.clave,
                            'segundos', v.segundos,
                            -- Su galería; «inicio_banner» sólo si todavía no la
                            -- tiene enganchada
                            'imagenes', COALESCE(ecommerce.fn_galerias_publica(
                                COALESCE(v.galeria_clave, 'inicio_banner')) -> 'imagenes', '[]'::jsonb))
                   -- Cualquier otra sección con galería es un banner, y sale con
                   -- la clave que la tienda sabe pintar. Pueden ser varios.
                   WHEN v.galeria_clave IS NOT NULL THEN
                        jsonb_build_object('clave', 'banner_simple',
                            -- Rotando o en carteles. La tienda pinta una cosa u
                            -- otra con las MISMAS imágenes y sus mismos enlaces.
                            'vista', v.banner_vista,
                            -- Cada cuántos segundos cambia; null = el de la tienda
                            'segundos', v.segundos,
                            'imagenes', COALESCE(ecommerce.fn_galerias_publica(v.galeria_clave) -> 'imagenes', '[]'::jsonb))
                   WHEN v.clave = 'mosaico' THEN
                        jsonb_build_object('clave', v.clave,
                            'categorias', CASE
                                WHEN v.alcance = 'cuerpo' AND v.categoria_id IS NOT NULL
                                     THEN ecommerce.fn_categorias_promocion_hijas_publicas(v.categoria_id)
                                ELSE ecommerce.fn_categorias_promocion_publicas() END)
                   WHEN v.clave = 'categorias_destacadas' THEN
                        jsonb_build_object('clave', v.clave,
                            -- En círculo (lo de siempre) o en cuadros con el nombre encima
                            'forma', v.forma,
                            'categorias', CASE
                                -- Lo que cuelga de su categoría, o lo que tiene
                                -- productos de su marca
                                WHEN v.alcance = 'cuerpo' AND v.categoria_id IS NOT NULL
                                     THEN ecommerce.fn_categorias_hijas_publicas(v.categoria_id)
                                WHEN v.alcance = 'cuerpo' AND v.marca_id IS NOT NULL
                                     THEN ecommerce.fn_categorias_de_marca_publicas(v.marca_id)
                                ELSE ecommerce.fn_categorias_destacadas_publicas() END)
                   WHEN v.clave = 'marcas_promocion' THEN
                        jsonb_build_object('clave', v.clave,
                            'marcas', ecommerce.fn_marcas_promocion_publicas())
                   WHEN v.clave = 'marcas' THEN
                        jsonb_build_object('clave', v.clave,
                            'marcas', CASE
                                WHEN v.alcance = 'cuerpo' AND v.categoria_id IS NOT NULL
                                     THEN ecommerce.fn_marcas_de_categoria_publicas(v.categoria_id)
                                ELSE ecommerce.fn_marcas_publicas() END)
                   -- Las demás todavía no tienen de dónde sacar datos. Se
                   -- devuelven NULL y se caen en el filtro de abajo; la tienda
                   -- ni se entera.
                   ELSE NULL
               END AS seccion
          FROM visibles v
    )
    SELECT jsonb_build_object(
        -- De qué página se habla: su título, su texto y si debajo va el
        -- catálogo. La tienda lo necesita antes de pintar nada.
        'cuerpo', (SELECT jsonb_build_object(
                       'id',          e.id,
                       'ruta',        e.ruta,
                       'url',         CASE WHEN e.principal THEN '/' ELSE '/' || e.ruta END,
                       'principal',   e.principal,
                       'titulo',      e.titulo,
                       'descripcion', e.descripcion,
                       'catalogo',    e.catalogo,
                       'categoria_id', e.categoria_id,
                       -- El nombre con el que la tienda la llama, que puede no
                       -- ser el del catálogo
                       'categoria',   (SELECT COALESCE(w.nombre_web, c.nombre)
                                         FROM inventarios.categorias c
                                         LEFT JOIN ecommerce.categorias_web w ON w.categoria_id = c.id
                                        WHERE c.id = e.categoria_id),
                       'categoria_ruta', inventarios.fn_categoria_ruta(e.categoria_id),
                       -- La categoría Y TODAS LAS QUE CUELGAN de ella: los
                       -- productos cuelgan de las hojas, así que el catálogo
                       -- de Movilidad son los de sus hijas y sus nietas
                       'categorias_base', to_jsonb(ecommerce.fn_categorias_rama(e.categoria_id)),
                       'marca_id',    e.marca_id,
                       'marca',       (SELECT m.nombre FROM inventarios.marcas m WHERE m.id = e.marca_id))
                     FROM elegido e),
        'secciones', COALESCE((
            SELECT jsonb_agg(
                       -- El rótulo, su pinta y el alto se añaden aquí y no en
                       -- cada rama: son de la sección, no de lo que la llena, y
                       -- así no se olvidan en la siguiente que se traslade
                       a.seccion || jsonb_build_object('titulo', a.titulo, 'subtitulo', a.subtitulo,
                                                       'estilo', a.estilo, 'alto', a.alto)
                       ORDER BY a.orden)
              FROM armadas a
             WHERE a.seccion IS NOT NULL
               AND (a.seccion -> 'imagenes'   IS NULL OR jsonb_array_length(a.seccion -> 'imagenes') > 0)
               AND (a.seccion -> 'categorias' IS NULL OR jsonb_array_length(a.seccion -> 'categorias') > 0)
               AND (a.seccion -> 'marcas'     IS NULL OR jsonb_array_length(a.seccion -> 'marcas') > 0)
               -- Una sección de productos vacía no se manda: dejaría su título
               -- y nada debajo, que es peor que no estar.
               AND (a.seccion -> 'productos'  IS NULL OR jsonb_array_length(a.seccion -> 'productos') > 0)
            ), '[]'::jsonb))
      -- Sin página no se devuelve un objeto vacío: se devuelve nada, y el
      -- controlador contesta 404
     WHERE EXISTS (SELECT 1 FROM elegido);
$function$;

COMMENT ON FUNCTION ecommerce.fn_cuerpo_publico(text) IS
    'La página de la tienda que vive en esa dirección; sin dirección, la principal. NULL si no hay.';

-- Lo de siempre, por donde siempre: la portada es el cuerpo principal.
CREATE OR REPLACE FUNCTION ecommerce.fn_inicio_publico()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
AS $function$
    SELECT ecommerce.fn_cuerpo_publico(NULL);
$function$;

-- ----------------------------------------------------------------------------
-- 5. COMPROBACIÓN
-- ----------------------------------------------------------------------------
DO $comprobar$
DECLARE
    v_principal bigint;
    v_portada   jsonb;
    v_pagina    jsonb;
    v_cuerpo    bigint;
    v_categoria bigint;
    v_id        bigint;
    v_cuantas   integer;
BEGIN
    v_principal := ecommerce.fn_cuerpo_principal_id();

    -- La portada de siempre sigue saliendo, y ahora dice de qué cuerpo es
    v_portada := ecommerce.fn_inicio_publico();
    IF v_portada IS NULL THEN
        RAISE EXCEPTION 'La portada se quedó sin nada';
    END IF;
    IF v_portada -> 'cuerpo' ->> 'url' <> '/' THEN
        RAISE EXCEPTION 'La portada tiene que decir que vive en /: %', v_portada -> 'cuerpo';
    END IF;
    IF jsonb_typeof(v_portada -> 'secciones') <> 'array' THEN
        RAISE EXCEPTION 'La portada no trae secciones: %', v_portada;
    END IF;
    v_cuantas := jsonb_array_length(v_portada -> 'secciones');
    IF v_cuantas = 0 THEN
        RAISE EXCEPTION 'La portada se quedó sin secciones';
    END IF;
    -- Y el banner principal sigue llegando con sus imágenes
    IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_portada -> 'secciones') s
                    WHERE s ->> 'clave' = 'banner_principal'
                      AND jsonb_array_length(s -> 'imagenes') > 0) THEN
        RAISE EXCEPTION 'El banner principal perdió sus imágenes al colgarlo de su galería';
    END IF;

    -- Una dirección que no existe no es una página
    IF ecommerce.fn_cuerpo_publico('zz-no-existe-claude') IS NOT NULL THEN
        RAISE EXCEPTION 'Una dirección inventada devolvió página';
    END IF;

    BEGIN
        -- Una categoría cualquiera que tenga hijas visibles, para probar el alcance
        SELECT e.padre_id INTO v_categoria
          FROM ecommerce.fn_categorias_web_estado() e
         WHERE e.estado = 'visible' AND e.padre_id IS NOT NULL
         GROUP BY e.padre_id ORDER BY count(*) DESC LIMIT 1;

        v_cuerpo := (ecommerce.fn_cuerpos_guardar(NULL, jsonb_build_object(
                         'nombre', 'ZZ pagina claude', 'ruta', 'zz-pagina-claude',
                         'titulo', 'ZZ título', 'descripcion', 'ZZ texto de arriba',
                         'categoria_id', v_categoria, 'catalogo', true)) -> 'data' ->> 'id')::bigint;

        -- Apagado no es página
        PERFORM ecommerce.fn_cuerpos_activar(v_cuerpo, false);
        IF ecommerce.fn_cuerpo_publico('zz-pagina-claude') IS NOT NULL THEN
            RAISE EXCEPTION 'Un cuerpo apagado sigue saliendo en la tienda';
        END IF;
        PERFORM ecommerce.fn_cuerpos_activar(v_cuerpo, true);

        -- Encendido, con sus datos y sin secciones (nacen apagadas)
        v_pagina := ecommerce.fn_cuerpo_publico('zz-pagina-claude');
        IF v_pagina IS NULL THEN
            RAISE EXCEPTION 'La página no salió por su dirección';
        END IF;
        IF v_pagina -> 'cuerpo' ->> 'titulo' <> 'ZZ título'
           OR v_pagina -> 'cuerpo' ->> 'descripcion' <> 'ZZ texto de arriba'
           OR (v_pagina -> 'cuerpo' ->> 'catalogo')::boolean IS NOT TRUE THEN
            RAISE EXCEPTION 'La página no trae lo suyo: %', v_pagina -> 'cuerpo';
        END IF;
        IF v_pagina -> 'cuerpo' ->> 'categoria' IS NULL THEN
            RAISE EXCEPTION 'La página de una categoría tiene que decir cuál: %', v_pagina -> 'cuerpo';
        END IF;
        -- Y con qué categorías se llena su catálogo: ella y las que cuelgan
        IF jsonb_array_length(v_pagina -> 'cuerpo' -> 'categorias_base') < 2 THEN
            RAISE EXCEPTION 'La rama de la categoría tiene que llevarla a ella y a sus hijas: %',
                  v_pagina -> 'cuerpo' -> 'categorias_base';
        END IF;
        IF NOT (v_pagina -> 'cuerpo' -> 'categorias_base') @> to_jsonb(v_categoria) THEN
            RAISE EXCEPTION 'La rama no se incluye a sí misma: %', v_pagina -> 'cuerpo' -> 'categorias_base';
        END IF;
        IF jsonb_array_length(v_pagina -> 'secciones') <> 0 THEN
            RAISE EXCEPTION 'Las secciones nacen apagadas: no debería salir ninguna';
        END IF;

        -- El alcance: las destacadas de ESTA página son las hijas de su categoría
        SELECT id INTO v_id FROM ecommerce.inicio_secciones
         WHERE cuerpo_id = v_cuerpo AND clave = 'categorias_destacadas';
        PERFORM ecommerce.fn_inicio_seccion_guardar(v_id, jsonb_build_object(
            'alcance', 'cuerpo', 'activo', true));

        v_pagina := ecommerce.fn_cuerpo_publico('zz-pagina-claude');
        IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_pagina -> 'secciones') s
                        WHERE s ->> 'clave' = 'categorias_destacadas') THEN
            RAISE EXCEPTION 'La sección de destacadas con alcance de cuerpo no salió (¿su categoría no tiene hijas visibles?)';
        END IF;
        IF (SELECT jsonb_array_length(s -> 'categorias')
              FROM jsonb_array_elements(v_pagina -> 'secciones') s
             WHERE s ->> 'clave' = 'categorias_destacadas')
           <> jsonb_array_length(ecommerce.fn_categorias_hijas_publicas(v_categoria)) THEN
            RAISE EXCEPTION 'Con alcance de cuerpo tiene que enseñar las hijas de su categoría';
        END IF;

        -- Y con alcance de tienda, las destacadas de siempre
        PERFORM ecommerce.fn_inicio_seccion_guardar(v_id, jsonb_build_object(
            'alcance', 'tienda', 'activo', true));
        v_pagina := ecommerce.fn_cuerpo_publico('zz-pagina-claude');
        IF (SELECT jsonb_array_length(s -> 'categorias')
              FROM jsonb_array_elements(v_pagina -> 'secciones') s
             WHERE s ->> 'clave' = 'categorias_destacadas')
           <> jsonb_array_length(ecommerce.fn_categorias_destacadas_publicas()) THEN
            RAISE EXCEPTION 'Con alcance de tienda tiene que enseñar las destacadas de siempre';
        END IF;

        -- La rama de una categoría se incluye a sí misma
        IF NOT (v_categoria = ANY (ecommerce.fn_categorias_rama(v_categoria))) THEN
            RAISE EXCEPTION 'La rama de una categoría tiene que llevarla a ella también';
        END IF;

        -- Y la portada no se ha enterado de nada
        IF jsonb_array_length(ecommerce.fn_inicio_publico() -> 'secciones') <> v_cuantas THEN
            RAISE EXCEPTION 'La portada cambió al crear otra página';
        END IF;

        RAISE EXCEPTION 'deshacer' USING ERRCODE = 'P0099';
    EXCEPTION WHEN SQLSTATE 'P0099' THEN
        NULL;
    END;

    IF EXISTS (SELECT 1 FROM ecommerce.cuerpos WHERE nombre LIKE 'ZZ %claude') THEN
        RAISE EXCEPTION 'El cuerpo de prueba se quedó en la base';
    END IF;

    RAISE NOTICE 'Comprobado: la portada sigue igual y dice que vive en /, una dirección inventada o apagada no es página, la página trae su título y su texto, y el alcance cambia entre las hijas de su categoría y las destacadas de la tienda. No quedó nada.';
END
$comprobar$;

COMMIT;
