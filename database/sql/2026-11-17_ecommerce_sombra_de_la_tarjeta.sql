-- ============================================================================
-- LA SOMBRA DE LA TARJETA DE PRODUCTO
-- ============================================================================
-- La tarjeta de producto es UNA SOLA en toda la tienda —la de los escaparates,
-- la de /shop, la de los relacionados— y hasta hoy era plana: sólo se levantaba
-- con una sombra al pasar el mouse por encima. Sobre un fondo de página claro
-- eso deja una rejilla de rectángulos sin relieve, y sobre uno oscuro casi no
-- se distinguen unas de otras.
--
-- SE AÑADE `tarjeta_sombra`, que se elige POR SECCIÓN, como el fondo y el borde
-- de la tarjeta: cada escaparate y el catálogo tienen los suyos.
--
--   ninguna  plana, y se levanta al pasar el mouse. Es lo de hoy, y lo que
--            vale mientras nadie elija otra cosa
--   suave    se nota que está despegada del fondo
--   media    la de una tarjeta de verdad
--   fuerte   bien levantada, para pocas tarjetas grandes
--
-- ES UNA CLAVE Y NO UNA MEDIDA, por lo mismo que el alto: un `0 2px 8px rgba…`
-- guardado aquí sería la hoja de estilos de la tienda escrita desde el CRM, y
-- cambiarla luego obligaría a repasar cada sección. Los píxeles de cada clave
-- están en la tienda (boton-color.util.ts), QUE ES QUIEN MANDA, y de ahí sale
-- también la sombra más levantada que se usa al pasar el mouse.
--
-- `fn_tarjeta_colores` CAMBIA DE FIRMA: pasa de siete argumentos a ocho. Se
-- crea la nueva, se cambian las dos que la llaman y se borra la vieja, todo en
-- la misma transacción, para que no quede un rato con las dos.
--
-- ----------------------------------------------------------------------------
-- SE EJECUTA A MANO. Para ensayar sin guardar, cambiar el COMMIT del final por
-- ROLLBACK: la comprobación se hace igual y no queda rastro.
-- ============================================================================

BEGIN;

-- ---------- La columna ----------
ALTER TABLE ecommerce.inicio_secciones
    ADD COLUMN IF NOT EXISTS tarjeta_sombra character varying(10);

COMMENT ON COLUMN ecommerce.inicio_secciones.tarjeta_sombra IS
    'La sombra de las tarjetas de producto de la sección: ninguna | suave | media | fuerte. NULL = «ninguna», plana como siempre. Los píxeles los pone la tienda.';

ALTER TABLE ecommerce.inicio_secciones
    DROP CONSTRAINT IF EXISTS ck_inicio_secciones_tarjeta_sombra;

ALTER TABLE ecommerce.inicio_secciones
    ADD CONSTRAINT ck_inicio_secciones_tarjeta_sombra
    CHECK (tarjeta_sombra IS NULL
           OR tarjeta_sombra::text = ANY (ARRAY['ninguna', 'suave', 'media', 'fuerte']::text[]));

-- ---------- Los colores de la tarjeta viajan con su sombra ----------
CREATE OR REPLACE FUNCTION ecommerce.fn_tarjeta_colores(p_fondo text, p_borde text, p_descuento text, p_descuento_texto text, p_etiqueta text, p_etiqueta_color text, p_etiqueta_texto text, p_sombra text)
 RETURNS jsonb
 LANGUAGE sql
 IMMUTABLE PARALLEL SAFE
AS $function$
    -- Los nulos se quedan nulos, como en fn_botones_colores: null en `fondo`
    -- es «el de la tienda» y null en el `texto` de un cartel es «el que se lea
    -- encima», que lo calcula la tienda. Resolverlos aquí obligaría a esta
    -- función a conocer la hoja de estilos de la tienda.
    --
    -- LA SOMBRA SÍ SE RESUELVE, como el alto de la sección: es una de cuatro
    -- palabras y no un color, y que la tienda y la pantalla del CRM tengan que
    -- acordarse las dos de que null es «ninguna» es la manera de que un día
    -- una de las dos se olvide.
    SELECT jsonb_build_object(
        'fondo',     nullif(btrim(COALESCE(p_fondo, '')), ''),
        'borde',     nullif(btrim(COALESCE(p_borde, '')), ''),
        'sombra',    COALESCE(nullif(btrim(COALESCE(p_sombra, '')), ''), 'ninguna'),
        'descuento', jsonb_build_object(
                         'fondo', nullif(btrim(COALESCE(p_descuento, '')), ''),
                         'texto', nullif(btrim(COALESCE(p_descuento_texto, '')), '')),
        -- `rotulo` son las palabras; `fondo` y `texto`, los dos colores. SIN
        -- PALABRAS NO HAY ETIQUETA: la tienda mira `rotulo` y, en null, no
        -- pinta nada. Así un color elegido y un texto que se borró después no
        -- dejan una pastilla vacía en cada tarjeta.
        'etiqueta',  jsonb_build_object(
                         'rotulo', nullif(btrim(COALESCE(p_etiqueta, '')), ''),
                         'fondo',  nullif(btrim(COALESCE(p_etiqueta_color, '')), ''),
                         'texto',  nullif(btrim(COALESCE(p_etiqueta_texto, '')), '')));
$function$;

-- ---------- Guardar la admite ----------
CREATE OR REPLACE FUNCTION ecommerce.fn_inicio_seccion_guardar(p_id bigint, p_datos jsonb, p_usuario_id bigint DEFAULT NULL::bigint, p_usuario_login character varying DEFAULT NULL::character varying, p_usuario_nombre character varying DEFAULT NULL::character varying, p_ip_address inet DEFAULT NULL::inet, p_user_agent text DEFAULT NULL::text, p_request_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'ecommerce', 'auditoria'
AS $function$
DECLARE
    v_nombre text;
    v_cuerpo bigint;
    v_desde  timestamptz;
    v_hasta  timestamptz;
BEGIN
    PERFORM ecommerce.fn_contexto_auditoria('ecommerce.inicio_secciones',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    SELECT nombre, cuerpo_id INTO v_nombre, v_cuerpo
      FROM ecommerce.inicio_secciones WHERE id = p_id;
    IF v_nombre IS NULL THEN
        RAISE EXCEPTION 'Esa sección no existe' USING ERRCODE = 'P0013';
    END IF;

    v_desde := nullif(btrim(COALESCE(p_datos ->> 'desde', '')), '')::timestamptz;
    v_hasta := nullif(btrim(COALESCE(p_datos ->> 'hasta', '')), '')::timestamptz;
    IF v_desde IS NOT NULL AND v_hasta IS NOT NULL AND v_hasta < v_desde THEN
        RAISE EXCEPTION 'Las fechas van al revés: «hasta» es anterior a «desde»' USING ERRCODE = 'P0015';
    END IF;

    UPDATE ecommerce.inicio_secciones
       SET titulo        = ecommerce.fn_validar_texto(p_datos ->> 'titulo', 'El título', 80),
           subtitulo     = ecommerce.fn_validar_texto(p_datos ->> 'subtitulo', 'El subtítulo', 80),
           rotulo_tamano = ecommerce.fn_validar_opcion(p_datos ->> 'rotulo_tamano',
                               ARRAY['pequeno', 'normal', 'grande', 'enorme'], 'El tamaño del rótulo'),
           rotulo_color  = ecommerce.fn_validar_color(p_datos ->> 'rotulo_color', 'El color del rótulo'),
           rotulo_fuente = ecommerce.fn_validar_opcion(p_datos ->> 'rotulo_fuente',
                               ARRAY['titulos', 'texto', 'deportiva', 'serif'], 'La letra del rótulo'),
           alto          = ecommerce.fn_validar_opcion(p_datos ->> 'alto',
                               ARRAY['compacta', 'normal', 'amplia', 'extra'], 'El alto de la sección'),
           -- EL ALTO DE SUS IMÁGENES, que no es el alto de la sección: aquél
           -- es el aire de alrededor y éste la franja que ocupan las fotos.
           -- Sólo lo miran los banners; 'imagen' —o nada— es lo de siempre:
           -- cada foto con el alto que traiga.
           alto_imagen   = ecommerce.fn_validar_opcion(p_datos ->> 'alto_imagen',
                               ARRAY['imagen', 'bajo', 'medio', 'alto', 'extra'], 'El alto de las imágenes'),
           -- El fondo de los cuatro botones de la tarjeta. Mismo validador que
           -- el del rótulo: con o sin almohadilla, y a minúsculas.
           boton_favorito_color = ecommerce.fn_validar_color(p_datos ->> 'boton_favorito_color',
                                      'El color del botón de favorito'),
           boton_carrito_color  = ecommerce.fn_validar_color(p_datos ->> 'boton_carrito_color',
                                      'El color del botón de agregar'),
           boton_whatsapp_color = ecommerce.fn_validar_color(p_datos ->> 'boton_whatsapp_color',
                                      'El color del botón de WhatsApp'),
           boton_tarjeta_color  = ecommerce.fn_validar_color(p_datos ->> 'boton_tarjeta_color',
                                      'El color del botón de comprar con tarjeta'),
           boton_favorito_texto = ecommerce.fn_validar_color(p_datos ->> 'boton_favorito_texto',
                                      'La letra del botón de favorito'),
           boton_carrito_texto  = ecommerce.fn_validar_color(p_datos ->> 'boton_carrito_texto',
                                      'La letra del botón de agregar'),
           boton_whatsapp_texto = ecommerce.fn_validar_color(p_datos ->> 'boton_whatsapp_texto',
                                      'La letra del botón de WhatsApp'),
           boton_tarjeta_texto  = ecommerce.fn_validar_color(p_datos ->> 'boton_tarjeta_texto',
                                      'La letra del botón de comprar con tarjeta'),
           -- El cartel del descuento de la esquina, y el fondo y el borde
           -- de la tarjeta entera. Mismo validador que todo lo demás.
           descuento_color      = ecommerce.fn_validar_color(p_datos ->> 'descuento_color',
                                      'El color del cartel de descuento'),
           descuento_texto      = ecommerce.fn_validar_color(p_datos ->> 'descuento_texto',
                                      'La letra del cartel de descuento'),
           -- La etiqueta de encima del descuento: sus palabras y sus dos colores
           etiqueta             = ecommerce.fn_validar_texto(p_datos ->> 'etiqueta',
                                      'La etiqueta de la tarjeta', 30),
           etiqueta_color       = ecommerce.fn_validar_color(p_datos ->> 'etiqueta_color',
                                      'El color de la etiqueta'),
           etiqueta_texto       = ecommerce.fn_validar_color(p_datos ->> 'etiqueta_texto',
                                      'La letra de la etiqueta'),
           tarjeta_fondo_color  = ecommerce.fn_validar_color(p_datos ->> 'tarjeta_fondo_color',
                                      'El fondo de la tarjeta'),
           tarjeta_borde_color  = ecommerce.fn_validar_color(p_datos ->> 'tarjeta_borde_color',
                                      'El borde de la tarjeta'),
           -- LA SOMBRA DE LA TARJETA. Es una clave y no una medida, como el
           -- alto: los píxeles de cada una los pone la tienda. 'ninguna' —o
           -- nada— es lo de siempre: plana, y sólo se levanta al pasar el mouse.
           tarjeta_sombra       = ecommerce.fn_validar_opcion(p_datos ->> 'tarjeta_sombra',
                                      ARRAY['ninguna', 'suave', 'media', 'fuerte'], 'La sombra de la tarjeta'),
           -- Cómo se enseña la sección y la imagen de al lado. El fichero NO
           -- está aquí: lo pone fn_inicio_seccion_imagen, porque este UPDATE
           -- escribe todos sus campos y lo borraría al guardar cualquier otra cosa.
           disposicion   = ecommerce.fn_validar_opcion(p_datos ->> 'disposicion',
                               ARRAY['sola', 'izquierda', 'derecha', 'cartel', 'paginada'], 'La disposición de la sección'),
           -- Cómo se enseña un banner. Sólo lo miran las secciones con
           -- galería; en las demás se guarda y no lo lee nadie.
           banner_vista  = ecommerce.fn_validar_opcion(p_datos ->> 'banner_vista',
                               ARRAY['rotativo', 'carteles', 'completo'], 'La vista del banner'),
           -- Cada cuántos segundos cambia la imagen. Vacío = el de la tienda.
           segundos = ecommerce.fn_validar_entero(p_datos ->> 'segundos',
                               'Los segundos de la sección', 2, 60),
           -- En qué forma se pintan sus fichas. Hoy sólo las destacadas.
           -- Cuántas tarjetas salen antes del botón «Ver más
           -- productos». Vacío = doce, el del catálogo
           por_pagina    = ecommerce.fn_validar_entero(p_datos ->> 'por_pagina',
                               'Cuántos productos por página', 2, 48),
           forma         = ecommerce.fn_validar_opcion(p_datos ->> 'forma',
                               ARRAY['circulo', 'cuadrado'], 'La forma de las categorías'),
           -- De dónde saca lo que enseña: de toda la tienda o de la categoría
           -- o la marca de su cuerpo. Lo miran las de categorías y de marcas.
           alcance       = ecommerce.fn_validar_opcion(p_datos ->> 'alcance',
                               ARRAY['tienda', 'cuerpo'], 'De dónde salen'),
           imagen_alt    = ecommerce.fn_validar_texto(p_datos ->> 'imagen_alt',
                               'El texto de la imagen', 120),
           imagen_enlace = ecommerce.fn_validar_enlace(p_datos ->> 'imagen_enlace',
                               'El enlace de la imagen'),
           imagen_nueva_pestana = ecommerce.fn_nueva_pestana(
                               ecommerce.fn_validar_enlace(p_datos ->> 'imagen_enlace', 'El enlace de la imagen'),
                               (p_datos ->> 'imagen_nueva_pestana')::boolean),
           activo        = COALESCE((p_datos ->> 'activo')::boolean, true),
           desde         = v_desde,
           hasta         = v_hasta
     WHERE id = p_id;

    RETURN jsonb_build_object('success', true,
        'message', format('«%s» guardada', v_nombre),
        'data', (ecommerce.fn_inicio_listar(v_cuerpo) -> 'data'));
END;
$function$;

-- ---------- El CRM la lee ----------
CREATE OR REPLACE FUNCTION ecommerce.fn_inicio_listar(p_cuerpo_id bigint DEFAULT NULL::bigint)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
AS $function$
    SELECT jsonb_build_object('success', true, 'message', 'Secciones del cuerpo',
        'data', COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
                       'id',         s.id,
                       'cuerpo_id',  s.cuerpo_id,
                       'clave',      s.clave,
                       'nombre',     s.nombre,
                       'titulo',     s.titulo,
                       'subtitulo',  s.subtitulo,
                       'estilo',     ecommerce.fn_rotulo_estilo(s.rotulo_tamano, s.rotulo_color, s.rotulo_fuente),
                       -- Resuelto, como el estilo: que la pantalla y la tienda
                       -- tengan que acordarse de que NULL es «normal» es la
                       -- manera de que un día una de las dos se olvide
                       'alto',       COALESCE(nullif(btrim(COALESCE(s.alto, '')), ''), 'normal'),
                       -- El alto de sus imágenes, resuelto igual. Sólo lo
                       -- miran los banners; 'imagen' es «el que traiga cada una»
                       'alto_imagen', COALESCE(nullif(btrim(COALESCE(s.alto_imagen, '')), ''), 'imagen'),
                       'orden',      s.orden,
                       'activo',     s.activo,
                       'desde',      to_char(s.desde, 'YYYY-MM-DD"T"HH24:MI'),
                       'hasta',      to_char(s.hasta, 'YYYY-MM-DD"T"HH24:MI'),
                       'updated_at', to_char(s.updated_at, 'YYYY-MM-DD HH24:MI'),
                       'updated_by', s.updated_by,
                       -- A qué escaparate o a qué galería apunta, y si es de
                       -- las de fábrica. `fija` lo decide el servidor: la
                       -- pantalla no tiene por qué saber cómo se escribe una
                       -- clave fabricada.
                       'producto_seccion_id', s.producto_seccion_id,
                       'galeria_id', s.galeria_id,
                       -- Con galería, la pantalla enseña sus imágenes
                       'es_banner',  s.galeria_id IS NOT NULL,
                       -- De fábrica: se apaga, no se borra ni se renombra
                       'fija',       ecommerce.fn_inicio_seccion_de_fabrica(s.clave),
                       'banner_vista', COALESCE(nullif(btrim(COALESCE(s.banner_vista, '')), ''), 'rotativo'),
                       'segundos', s.segundos,
                       'por_pagina', s.por_pagina,
                       'forma', COALESCE(nullif(btrim(COALESCE(s.forma, '')), ''), 'circulo'),
                       -- Lo de toda la tienda o lo que cuelga de la categoría
                       -- o la marca del cuerpo. Sólo lo miran las secciones de
                       -- categorías y de marcas.
                       'alcance', COALESCE(nullif(btrim(COALESCE(s.alcance, '')), ''), 'tienda'),
                       'botones',    ecommerce.fn_botones_colores(
                                           s.boton_favorito_color, s.boton_favorito_texto,
                                           s.boton_carrito_color,  s.boton_carrito_texto,
                                           s.boton_whatsapp_color, s.boton_whatsapp_texto,
                                           s.boton_tarjeta_color,  s.boton_tarjeta_texto),
                       'tarjeta',    ecommerce.fn_tarjeta_colores(
                                           s.tarjeta_fondo_color, s.tarjeta_borde_color,
                                           s.descuento_color,     s.descuento_texto,
                                           s.etiqueta, s.etiqueta_color, s.etiqueta_texto,
                                           s.tarjeta_sombra),
                       'imagen',     ecommerce.fn_seccion_imagen(s.disposicion, s.imagen,
                                           s.imagen_alt, s.imagen_enlace, s.imagen_nueva_pestana),
                       'estado',     CASE
                           WHEN NOT s.activo THEN 'oculta'
                           WHEN s.desde IS NOT NULL AND CURRENT_TIMESTAMP < s.desde THEN 'programada'
                           WHEN s.hasta IS NOT NULL AND CURRENT_TIMESTAMP > s.hasta THEN 'terminada'
                           ELSE 'visible' END,
                       'fuente',     fu.f,
                       'cuantas',    CASE fu.f ->> 'tipo'
                           WHEN 'galeria' THEN
                               (SELECT count(*) FROM ecommerce.galerias_imagenes i
                                  JOIN ecommerce.galerias gg ON gg.id = i.galeria_id
                                 WHERE gg.clave = fu.f ->> 'galeria'
                                   AND i.deleted_at IS NULL)
                           WHEN 'promocion' THEN
                               jsonb_array_length(ecommerce.fn_categorias_promocion_publicas())
                           WHEN 'destacadas' THEN
                               jsonb_array_length(ecommerce.fn_categorias_destacadas_publicas())
                           WHEN 'marcas' THEN
                               jsonb_array_length(ecommerce.fn_marcas_publicas())
                           WHEN 'marcas_promocion' THEN
                               jsonb_array_length(ecommerce.fn_marcas_promocion_publicas())
                           -- Los del escaparate, sin los que estén en la
                           -- papelera del catálogo: si contara las filas del
                           -- cruce diría ocho y la pantalla enseñaría seis.
                           WHEN 'productos' THEN
                               (SELECT count(*)
                                  FROM ecommerce.producto_secciones_items it
                                  JOIN inventarios.productos p ON p.id = it.producto_id
                                 WHERE it.seccion_id = s.producto_seccion_id
                                   AND p.deleted_at IS NULL
                                   -- Los que la tienda va a enseñar DE VERDAD: un
                                   -- escaparate lleno de productos apagados es un
                                   -- escaparate que la tienda se salta
                                   AND p.activo AND p.en_paginaweb)
                           -- El catálogo no se llena a mano: son todos los publicados
                           WHEN 'catalogo' THEN
                               (SELECT count(*) FROM inventarios.productos p
                                 WHERE p.deleted_at IS NULL AND p.activo AND p.en_paginaweb)
                           END,
                       'con_contenido', CASE fu.f ->> 'tipo'
                           WHEN 'galeria' THEN
                               EXISTS (SELECT 1 FROM ecommerce.galerias_imagenes i
                                         JOIN ecommerce.galerias gg ON gg.id = i.galeria_id
                                        WHERE gg.clave = fu.f ->> 'galeria'
                                          AND i.deleted_at IS NULL AND i.activo
                                          AND ecommerce.fn_vigente(i.desde, i.hasta))
                           WHEN 'promocion' THEN
                               jsonb_array_length(ecommerce.fn_categorias_promocion_publicas()) > 0
                           WHEN 'destacadas' THEN
                               jsonb_array_length(ecommerce.fn_categorias_destacadas_publicas()) > 0
                           -- Aquí basta con que haya alguna marcada: el cartel se
                           -- pinta con su color aunque no tenga foto, igual que
                           -- el de una categoría.
                           WHEN 'marcas_promocion' THEN
                               jsonb_array_length(ecommerce.fn_marcas_promocion_publicas()) > 0
                           -- La tienda sólo pinta las que tienen logo: una
                           -- marca sin imagen no cuenta como contenido.
                           WHEN 'marcas' THEN
                               EXISTS (SELECT 1 FROM jsonb_array_elements(ecommerce.fn_marcas_publicas()) m
                                        WHERE COALESCE(m ->> 'imagen', m ->> 'logo') IS NOT NULL)
                           WHEN 'productos' THEN
                               EXISTS (SELECT 1
                                         FROM ecommerce.producto_secciones_items it
                                         JOIN inventarios.productos p ON p.id = it.producto_id
                                        WHERE it.seccion_id = s.producto_seccion_id
                                          AND p.deleted_at IS NULL
                                          AND p.activo AND p.en_paginaweb)
                           WHEN 'catalogo' THEN
                               EXISTS (SELECT 1 FROM inventarios.productos p
                                        WHERE p.deleted_at IS NULL AND p.activo AND p.en_paginaweb)
                           ELSE false END)
                   ORDER BY s.orden, s.id)
              FROM ecommerce.inicio_secciones s
              LEFT JOIN ecommerce.galerias g ON g.id = s.galeria_id
              CROSS JOIN LATERAL (
                  SELECT ecommerce.fn_inicio_fuente(s.clave, s.producto_seccion_id, g.clave) AS f
              ) fu
             WHERE s.cuerpo_id = COALESCE(p_cuerpo_id, ecommerce.fn_cuerpo_principal_id())
               AND ecommerce.fn_inicio_seccion_viva(s.producto_seccion_id)), '[]'::jsonb));
$function$;

-- ---------- Y la tienda también ----------
CREATE OR REPLACE FUNCTION ecommerce.fn_cuerpo_publico(p_ruta text DEFAULT NULL::text)
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
               -- En crudo y no sólo dentro de `imagen`: 'paginada' es la única
               -- manera de enseñar que pagina, y de eso depende si sus
               -- productos viajan enteros o de a una página
               s.disposicion,
               COALESCE(nullif(btrim(COALESCE(s.banner_vista, '')), ''), 'rotativo') AS banner_vista,
               s.segundos, s.por_pagina,
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
                                            s.etiqueta, s.etiqueta_color, s.etiqueta_texto,
                                            s.tarjeta_sombra) AS tarjeta,
               ecommerce.fn_seccion_imagen(s.disposicion, s.imagen, s.imagen_alt,
                                           s.imagen_enlace, s.imagen_nueva_pestana) AS imagen,
               COALESCE(nullif(btrim(COALESCE(s.alto, '')), ''), 'normal') AS alto,
               COALESCE(nullif(btrim(COALESCE(s.alto_imagen, '')), ''), 'imagen') AS alto_imagen,
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
                            -- Cuántas tarjetas antes del botón «Ver más productos»
                            'por_pagina', v.por_pagina,
                            'botones', v.botones,
                            'tarjeta', v.tarjeta,
                            'imagen', v.imagen) || pag.datos
                   WHEN v.clave = 'banner_principal' THEN
                        jsonb_build_object('clave', v.clave,
                            -- Qué alto tiene su franja de imágenes. Va aquí y
                            -- no con el rótulo porque sólo lo tienen los dos
                            -- banners: en una sección de productos no hay
                            -- ninguna franja que medir
                            'alto_imagen', v.alto_imagen,
                            'segundos', v.segundos,
                            -- Cuántas tarjetas antes del botón «Ver más productos»
                            'por_pagina', v.por_pagina,
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
                            -- Y de qué alto, en las tres maneras
                            'alto_imagen', v.alto_imagen,
                            -- Cada cuántos segundos cambia; null = el de la tienda
                            'segundos', v.segundos,
                            -- Cuántas tarjetas antes del botón «Ver más productos»
                            'por_pagina', v.por_pagina,
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
                   -- EL CATÁLOGO. Sus productos NO van aquí: los pide la
                   -- tienda, paginados, porque son cientos. Lo que viaja es
                   -- cómo se pinta y de qué habla la página, que sale del
                   -- cuerpo (sin categoría ni marca: todo el catálogo).
                   WHEN v.clave = 'catalogo' THEN
                        jsonb_build_object('clave', 'catalogo',
                            -- Cuántas tarjetas antes de «Ver más productos»
                            'por_pagina', v.por_pagina,
                            'botones', v.botones,
                            'tarjeta', v.tarjeta)
                   -- Las demás todavía no tienen de dónde sacar datos. Se
                   -- devuelven NULL y se caen en el filtro de abajo; la tienda
                   -- ni se entera.
                   ELSE NULL
               END AS seccion
          FROM visibles v
          -- ===== Los productos de un escaparate =====
          --
          -- LOS DE FILA VIAJAN ENTEROS: son tres, cuatro, diez, los que alguien
          -- eligió para que se vean todos de una pasada con las flechas.
          --
          -- LOS PAGINADOS, UNA PÁGINA, y con sus filtros ya contados sobre la
          -- lista entera. Son los que hacen de catálogo: hasta el 09/11/2026
          -- también viajaban enteros y el navegador los iba soltando de a doce,
          -- y el de /tecnologia eran 63 KB para pintar doce tarjetas.
          --
          -- LA PRIMERA PÁGINA VIAJA CON LA PÁGINA, SIN FILTROS, a propósito: es
          -- lo que se ve al entrar, y pedirla aparte dejaría /motos con su
          -- encabezado y un hueco hasta que llegara la segunda petición. Lo que
          -- la dirección pida de más —otra página, algo marcado— ya lo pide la
          -- tienda. Por eso tampoco depende de la dirección: esta respuesta se
          -- guarda un minuto y la comparten todos los visitantes.
          LEFT JOIN LATERAL (
              SELECT CASE
                  WHEN v.producto_seccion_id IS NULL THEN NULL
                  WHEN v.disposicion = 'paginada' THEN (
                      SELECT jsonb_build_object(
                                 'productos',     p.pagina -> 'productos',
                                 'total',         p.pagina -> 'total',
                                 'por_pagina',    p.pagina -> 'por_pagina',
                                 'ultima_pagina', p.pagina -> 'ultima_pagina',
                                 -- Los filtros, contados en la base sobre los
                                 -- productos del escaparate: los de la ficha y
                                 -- los tres de la tienda
                                 'facetas',       p.pagina -> 'opciones' -> 'facetas')
                        FROM (SELECT ecommerce.fn_tienda_productos(jsonb_build_object(
                                         'escaparate', v.producto_seccion_id,
                                         'per_page',   COALESCE(v.por_pagina, 12))) AS pagina) p)
                  ELSE jsonb_build_object('productos',
                           ecommerce.fn_producto_seccion_publica(v.producto_seccion_id))
              END AS datos
          ) pag ON true
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
                       -- El fondo de la página; null = blanco
                       'fondo',       e.fondo,
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

-- ---------- Y la de siete argumentos ya no hace falta ----------
DROP FUNCTION IF EXISTS ecommerce.fn_tarjeta_colores(text, text, text, text, text, text, text);

COMMIT;


-- ============================================================================
-- COMPROBACIÓN — no escribe nada
-- ============================================================================
DO $comprobar$
DECLARE
    v_falta  text[] := '{}';
    v_regla  text;
    v_json   jsonb;
    v_seccion bigint;
BEGIN
    -- La columna y su regla
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                    WHERE table_schema = 'ecommerce' AND table_name = 'inicio_secciones'
                      AND column_name = 'tarjeta_sombra') THEN
        v_falta := array_append(v_falta, 'no está la columna');
    END IF;

    SELECT pg_get_constraintdef(oid) INTO v_regla
      FROM pg_constraint
     WHERE conrelid = 'ecommerce.inicio_secciones'::regclass
       AND conname = 'ck_inicio_secciones_tarjeta_sombra';

    IF v_regla IS NULL THEN
        v_falta := array_append(v_falta, 'no está la regla de la columna');
    ELSIF v_regla NOT LIKE '%fuerte%' OR v_regla NOT LIKE '%ninguna%' THEN
        v_falta := array_append(v_falta, 'la regla no admite las cuatro');
    END IF;

    -- Sólo queda la de ocho argumentos
    IF (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
         WHERE n.nspname = 'ecommerce' AND p.proname = 'fn_tarjeta_colores') <> 1 THEN
        v_falta := array_append(v_falta, 'quedan dos fn_tarjeta_colores');
    END IF;

    -- Resuelta: sin elegir nada, «ninguna»
    v_json := ecommerce.fn_tarjeta_colores(NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL);
    IF (v_json ->> 'sombra') IS DISTINCT FROM 'ninguna' THEN
        v_falta := array_append(v_falta, 'sin elegir nada no dice «ninguna»');
    END IF;
    v_json := ecommerce.fn_tarjeta_colores(NULL, NULL, NULL, NULL, NULL, NULL, NULL, 'media');
    IF (v_json ->> 'sombra') IS DISTINCT FROM 'media' THEN
        v_falta := array_append(v_falta, 'no devuelve la que se le da');
    END IF;

    -- El CRM la recibe dentro de «tarjeta»
    SELECT (e -> 'tarjeta' -> 'sombra')
      INTO v_json
      FROM jsonb_array_elements(ecommerce.fn_inicio_listar(NULL) -> 'data') e
     WHERE e ->> 'clave' = 'banner_principal'
     LIMIT 1;
    IF v_json IS NULL OR jsonb_typeof(v_json) <> 'string' THEN
        v_falta := array_append(v_falta, 'el CRM no la recibe resuelta');
    END IF;

    -- Y la tienda, en una sección que pinte tarjetas (si hoy hay alguna visible)
    SELECT (s -> 'tarjeta' -> 'sombra')
      INTO v_json
      FROM jsonb_array_elements(ecommerce.fn_cuerpo_publico(NULL) -> 'secciones') s
     WHERE s -> 'tarjeta' IS NOT NULL
     LIMIT 1;
    IF v_json IS NOT NULL AND jsonb_typeof(v_json) <> 'string' THEN
        v_falta := array_append(v_falta, 'la tienda la recibe sin resolver');
    END IF;

    -- Se guarda de verdad, y se deshace
    SELECT id INTO v_seccion FROM ecommerce.inicio_secciones
     WHERE producto_seccion_id IS NOT NULL ORDER BY id LIMIT 1;

    IF v_seccion IS NOT NULL THEN
        BEGIN
            UPDATE ecommerce.inicio_secciones SET tarjeta_sombra = 'fuerte' WHERE id = v_seccion;
            IF (SELECT tarjeta_sombra FROM ecommerce.inicio_secciones WHERE id = v_seccion)
               IS DISTINCT FROM 'fuerte' THEN
                v_falta := array_append(v_falta, 'no se guardó la sombra de prueba');
            END IF;
            RAISE EXCEPTION 'deshacer la prueba';
        EXCEPTION WHEN others THEN
            IF SQLERRM <> 'deshacer la prueba' THEN
                v_falta := array_append(v_falta, 'al guardar la sombra: ' || SQLERRM);
            END IF;
        END;
    END IF;

    IF array_length(v_falta, 1) > 0 THEN
        RAISE EXCEPTION 'La sombra de la tarjeta no quedó bien: %', array_to_string(v_falta, '; ');
    END IF;

    RAISE NOTICE 'Las tarjetas ya pueden llevar sombra (ninguna, suave, media, fuerte)';
END;
$comprobar$;
