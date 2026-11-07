-- ============================================================================
-- ECOMMERCE · LAS SECCIONES, DENTRO DE SU CUERPO
-- ============================================================================
-- Fecha: 2026-11-06
-- Va DESPUÉS de 2026-11-06_ecommerce_cuerpos.sql.
--
-- Las funciones de la portada trabajaban por `clave`, que era única en toda la
-- tabla. Con varios cuerpos la clave se repite —cada cuerpo tiene su
-- «banner_principal» y sus «categorias_destacadas»—, así que TODAS pasan a
-- trabajar por el `id` de la fila:
--
--     fn_inicio_seccion_guardar(p_clave …)   →  (p_id …)
--     fn_inicio_seccion_activar(p_clave …)   →  (p_id …)
--     fn_inicio_seccion_alto(p_clave …)      →  (p_id …)
--     fn_inicio_seccion_imagen(p_clave …)    →  (p_id …)
--     fn_inicio_banner_nombre(p_clave …)     →  (p_id …)
--     fn_inicio_banner_eliminar(p_clave …)   →  (p_id …)
--     fn_inicio_ordenar(p_claves …)          →  (p_ids, p_cuerpo_id …)
--     fn_inicio_banner_crear(p_nombre …)     →  (p_cuerpo_id, p_nombre …)
--     fn_inicio_listar()                     →  (p_cuerpo_id)
--
-- SE BORRAN Y SE VUELVEN A CREAR porque cambia la lista de argumentos, y eso
-- CREATE OR REPLACE no lo puede hacer. Las viejas se van: si se quedaran, una
-- llamada con dos argumentos no sabría a cuál ir.
--
-- CADA UNA DEVUELVE LA LISTA DE SU CUERPO, no la del principal. Es lo que hace
-- que la pantalla de tres columnas se refresque sola sin preguntar quién está
-- elegido.
--
-- «FIJA» YA NO ES «NO TIENE NADA DETRÁS». Era `producto_seccion_id IS NULL AND
-- galeria_id IS NULL`, y con eso «banner_simple» —que es de fábrica y tiene
-- galería— salía como un banner cualquiera, con su botón de borrar. Ahora fija
-- es DE FÁBRICA: la tienda sabe pintarla y no se puede borrar, sólo apagar.
-- Las que se crean y se borran son las que el servidor nombra él mismo,
-- `banner_7` y `seccion_12`, y se reconocen por ahí.
--
-- UN CUERPO NUEVO NACE CON LAS SECCIONES DE FÁBRICA DEL PRINCIPAL, apagadas y
-- sin rótulo, cada banner con SU galería. Si naciera vacío habría que
-- inventar una pantalla para añadir secciones que la tienda ya sabe pintar, y
-- lo primero que se vería de un cuerpo nuevo sería un hueco.
--
-- Idempotente.
-- ============================================================================
\set ON_ERROR_STOP on

BEGIN;

-- ----------------------------------------------------------------------------
-- 1. QUÉ SECCIÓN ES DE FÁBRICA
-- ----------------------------------------------------------------------------
-- Las que el servidor nombra él mismo llevan su id en la clave («banner_42»,
-- «seccion_121»); ésas se crean y se borran. Todo lo demás es de fábrica.
-- La regla vive aquí y no repetida en cada consulta.
CREATE OR REPLACE FUNCTION ecommerce.fn_inicio_seccion_de_fabrica(p_clave text)
 RETURNS boolean
 LANGUAGE sql
 IMMUTABLE PARALLEL SAFE
AS $function$
    SELECT COALESCE(p_clave, '') !~ '^(banner|seccion)_[0-9]+$';
$function$;

COMMENT ON FUNCTION ecommerce.fn_inicio_seccion_de_fabrica(text) IS
    'true si la sección existe porque la tienda sabe pintarla: no se borra, sólo se apaga.';

-- ----------------------------------------------------------------------------
-- 2. EL BANNER PRINCIPAL, TAMBIÉN POR SU GALERÍA
-- ----------------------------------------------------------------------------
-- Leía la galería «inicio_banner» a pelo, por su nombre. Con varios cuerpos
-- eso significaría que el banner de Movilidad enseña las imágenes de la
-- portada. Se le engancha su galería como a los demás, y a partir de aquí hay
-- un solo camino: la sección que tiene galería saca sus imágenes de ahí.
UPDATE ecommerce.inicio_secciones s
   SET galeria_id = g.id
  FROM ecommerce.galerias g
 WHERE s.clave = 'banner_principal'
   AND s.galeria_id IS NULL
   AND g.clave = 'inicio_banner'
   AND NOT EXISTS (SELECT 1 FROM ecommerce.inicio_secciones o
                    WHERE o.galeria_id = g.id);

-- ----------------------------------------------------------------------------
-- 3. LA LISTA DE UN CUERPO
-- ----------------------------------------------------------------------------
DROP FUNCTION IF EXISTS ecommerce.fn_inicio_listar();

-- Sin cuerpo, el principal: lo que pedía quien llamaba sin argumentos.
CREATE OR REPLACE FUNCTION ecommerce.fn_inicio_listar(p_cuerpo_id bigint DEFAULT NULL)
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
                                           s.etiqueta, s.etiqueta_color, s.etiqueta_texto),
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
                                   AND p.deleted_at IS NULL)
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
                                          AND p.deleted_at IS NULL)
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

-- El cuerpo de una sección, que es lo que todas las de abajo necesitan para
-- devolver la lista correcta.
CREATE OR REPLACE FUNCTION ecommerce.fn_inicio_seccion_cuerpo(p_id bigint)
 RETURNS bigint
 LANGUAGE sql
 STABLE
AS $function$
    SELECT s.cuerpo_id FROM ecommerce.inicio_secciones s WHERE s.id = p_id;
$function$;

-- ----------------------------------------------------------------------------
-- 4. GUARDAR UNA SECCIÓN
-- ----------------------------------------------------------------------------
DROP FUNCTION IF EXISTS ecommerce.fn_inicio_seccion_guardar(text, jsonb, bigint, varchar, varchar, inet, text, uuid);

CREATE OR REPLACE FUNCTION ecommerce.fn_inicio_seccion_guardar(
    p_id             bigint,
    p_datos          jsonb,
    p_usuario_id     bigint  DEFAULT NULL,
    p_usuario_login  varchar DEFAULT NULL,
    p_usuario_nombre varchar DEFAULT NULL,
    p_ip_address     inet    DEFAULT NULL,
    p_user_agent     text    DEFAULT NULL,
    p_request_id     uuid    DEFAULT NULL)
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
           -- Cómo se enseña la sección y la imagen de al lado. El fichero NO
           -- está aquí: lo pone fn_inicio_seccion_imagen, porque este UPDATE
           -- escribe todos sus campos y lo borraría al guardar cualquier otra cosa.
           disposicion   = ecommerce.fn_validar_opcion(p_datos ->> 'disposicion',
                               ARRAY['sola', 'izquierda', 'derecha', 'cartel'], 'La disposición de la sección'),
           -- Cómo se enseña un banner. Sólo lo miran las secciones con
           -- galería; en las demás se guarda y no lo lee nadie.
           banner_vista  = ecommerce.fn_validar_opcion(p_datos ->> 'banner_vista',
                               ARRAY['rotativo', 'carteles'], 'La vista del banner'),
           -- Cada cuántos segundos cambia la imagen. Vacío = el de la tienda.
           segundos = ecommerce.fn_validar_entero(p_datos ->> 'segundos',
                               'Los segundos de la sección', 2, 60),
           -- En qué forma se pintan sus fichas. Hoy sólo las destacadas.
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

-- ----------------------------------------------------------------------------
-- 5. ENCENDER, ALTO E IMAGEN
-- ----------------------------------------------------------------------------
DROP FUNCTION IF EXISTS ecommerce.fn_inicio_seccion_activar(text, boolean, bigint, varchar, varchar, inet, text, uuid);

CREATE OR REPLACE FUNCTION ecommerce.fn_inicio_seccion_activar(
    p_id             bigint,
    p_activo         boolean DEFAULT NULL,
    p_usuario_id     bigint  DEFAULT NULL,
    p_usuario_login  varchar DEFAULT NULL,
    p_usuario_nombre varchar DEFAULT NULL,
    p_ip_address     inet    DEFAULT NULL,
    p_user_agent     text    DEFAULT NULL,
    p_request_id     uuid    DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'ecommerce', 'auditoria'
AS $function$
DECLARE
    v_nombre text;
    v_cuerpo bigint;
    v_nuevo  boolean;
BEGIN
    PERFORM ecommerce.fn_contexto_auditoria('ecommerce.inicio_secciones',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    SELECT nombre, cuerpo_id, COALESCE(p_activo, NOT activo)
      INTO v_nombre, v_cuerpo, v_nuevo
      FROM ecommerce.inicio_secciones WHERE id = p_id;
    IF v_nombre IS NULL THEN
        RAISE EXCEPTION 'Esa sección no existe' USING ERRCODE = 'P0013';
    END IF;

    UPDATE ecommerce.inicio_secciones SET activo = v_nuevo WHERE id = p_id;

    RETURN jsonb_build_object('success', true,
        'message', format('«%s» %s', v_nombre,
                          CASE WHEN v_nuevo THEN 'se verá en la página' ELSE 'ya no se ve' END),
        'data', (ecommerce.fn_inicio_listar(v_cuerpo) -> 'data'));
END;
$function$;

DROP FUNCTION IF EXISTS ecommerce.fn_inicio_seccion_alto(text, text, bigint, varchar, varchar, inet, text, uuid);

CREATE OR REPLACE FUNCTION ecommerce.fn_inicio_seccion_alto(
    p_id             bigint,
    p_alto           text,
    p_usuario_id     bigint  DEFAULT NULL,
    p_usuario_login  varchar DEFAULT NULL,
    p_usuario_nombre varchar DEFAULT NULL,
    p_ip_address     inet    DEFAULT NULL,
    p_user_agent     text    DEFAULT NULL,
    p_request_id     uuid    DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'ecommerce', 'auditoria'
AS $function$
DECLARE
    v_nombre text;
    v_cuerpo bigint;
    v_alto   text;
BEGIN
    PERFORM ecommerce.fn_contexto_auditoria('ecommerce.inicio_secciones',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    SELECT nombre, cuerpo_id INTO v_nombre, v_cuerpo
      FROM ecommerce.inicio_secciones WHERE id = p_id;
    IF v_nombre IS NULL THEN
        RAISE EXCEPTION 'Esa sección no existe' USING ERRCODE = 'P0013';
    END IF;

    -- La misma lista de siempre, comprobada en el mismo sitio
    v_alto := COALESCE(ecommerce.fn_validar_opcion(p_alto,
                  ARRAY['compacta', 'normal', 'amplia', 'extra'], 'El alto de la sección'), 'normal');

    UPDATE ecommerce.inicio_secciones SET alto = v_alto WHERE id = p_id;

    RETURN jsonb_build_object('success', true,
        'message', format('«%s» ahora es %s', v_nombre, v_alto),
        'data', (ecommerce.fn_inicio_listar(v_cuerpo) -> 'data'));
END;
$function$;

DROP FUNCTION IF EXISTS ecommerce.fn_inicio_seccion_imagen(text, text, bigint, varchar, varchar, inet, text, uuid);

CREATE OR REPLACE FUNCTION ecommerce.fn_inicio_seccion_imagen(
    p_id             bigint,
    p_imagen         text,
    p_usuario_id     bigint  DEFAULT NULL,
    p_usuario_login  varchar DEFAULT NULL,
    p_usuario_nombre varchar DEFAULT NULL,
    p_ip_address     inet    DEFAULT NULL,
    p_user_agent     text    DEFAULT NULL,
    p_request_id     uuid    DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'ecommerce', 'auditoria'
AS $function$
DECLARE
    v_nombre   text;
    v_cuerpo   bigint;
    v_anterior text;
    v_nueva    text := nullif(btrim(COALESCE(p_imagen, '')), '');
BEGIN
    PERFORM ecommerce.fn_contexto_auditoria('ecommerce.inicio_secciones',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    SELECT nombre, cuerpo_id, imagen INTO v_nombre, v_cuerpo, v_anterior
      FROM ecommerce.inicio_secciones WHERE id = p_id;
    IF v_nombre IS NULL THEN
        RAISE EXCEPTION 'Esa sección no existe' USING ERRCODE = 'P0013';
    END IF;

    UPDATE ecommerce.inicio_secciones SET imagen = v_nueva WHERE id = p_id;

    RETURN jsonb_build_object('success', true,
        'message', CASE WHEN v_nueva IS NULL THEN format('Imagen quitada de «%s»', v_nombre)
                        ELSE format('Imagen guardada en «%s»', v_nombre) END,
        -- El de antes, para que PHP lo borre del disco si no lo usa nadie más
        'anterior', v_anterior,
        'data', (ecommerce.fn_inicio_listar(v_cuerpo) -> 'data'));
END;
$function$;

-- ----------------------------------------------------------------------------
-- 6. EL ORDEN, DENTRO DEL CUERPO
-- ----------------------------------------------------------------------------
DROP FUNCTION IF EXISTS ecommerce.fn_inicio_ordenar(jsonb, bigint, varchar, varchar, inet, text, uuid);

CREATE OR REPLACE FUNCTION ecommerce.fn_inicio_ordenar(
    p_ids            jsonb,
    p_cuerpo_id      bigint  DEFAULT NULL,
    p_usuario_id     bigint  DEFAULT NULL,
    p_usuario_login  varchar DEFAULT NULL,
    p_usuario_nombre varchar DEFAULT NULL,
    p_ip_address     inet    DEFAULT NULL,
    p_user_agent     text    DEFAULT NULL,
    p_request_id     uuid    DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'ecommerce', 'auditoria'
AS $function$
DECLARE
    v_cuerpo    bigint := COALESCE(p_cuerpo_id, ecommerce.fn_cuerpo_principal_id());
    v_recibidas integer;
    v_conocidas integer;
    v_todas     integer;
BEGIN
    PERFORM ecommerce.fn_contexto_auditoria('ecommerce.inicio_secciones',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    IF p_ids IS NULL OR jsonb_typeof(p_ids) <> 'array' OR jsonb_array_length(p_ids) = 0 THEN
        RAISE EXCEPTION 'Hace falta el orden de las secciones' USING ERRCODE = 'P0001';
    END IF;

    v_recibidas := jsonb_array_length(p_ids);

    -- Las que llegan Y son de este cuerpo: así un id de otro cuerpo no
    -- reordena nada a escondidas, se queja
    SELECT count(*) INTO v_conocidas FROM ecommerce.inicio_secciones
     WHERE cuerpo_id = v_cuerpo
       AND id IN (SELECT x::bigint FROM jsonb_array_elements_text(p_ids) x)
       AND ecommerce.fn_inicio_seccion_viva(producto_seccion_id);

    SELECT count(*) INTO v_todas FROM ecommerce.inicio_secciones
     WHERE cuerpo_id = v_cuerpo
       AND ecommerce.fn_inicio_seccion_viva(producto_seccion_id);

    IF v_conocidas <> v_recibidas OR v_recibidas <> v_todas THEN
        RAISE EXCEPTION 'El orden tiene que traer las % secciones del cuerpo, y trae % válidas de %',
              v_todas, v_conocidas, v_recibidas USING ERRCODE = 'P0016';
    END IF;

    UPDATE ecommerce.inicio_secciones s
       SET orden = n.pos
      FROM (SELECT x.id::bigint AS id, x.pos
              FROM jsonb_array_elements_text(p_ids) WITH ORDINALITY AS x(id, pos)) n
     WHERE s.id = n.id AND s.cuerpo_id = v_cuerpo;

    RETURN jsonb_build_object('success', true, 'message', 'Orden guardado',
                              'data', (ecommerce.fn_inicio_listar(v_cuerpo) -> 'data'));
END;
$function$;

-- ----------------------------------------------------------------------------
-- 7. LOS BANNERS DE UN CUERPO
-- ----------------------------------------------------------------------------
DROP FUNCTION IF EXISTS ecommerce.fn_inicio_banner_crear(text, bigint, varchar, varchar, inet, text, uuid);

CREATE OR REPLACE FUNCTION ecommerce.fn_inicio_banner_crear(
    p_cuerpo_id      bigint,
    p_nombre         text,
    p_usuario_id     bigint  DEFAULT NULL,
    p_usuario_login  varchar DEFAULT NULL,
    p_usuario_nombre varchar DEFAULT NULL,
    p_ip_address     inet    DEFAULT NULL,
    p_user_agent     text    DEFAULT NULL,
    p_request_id     uuid    DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'ecommerce', 'auditoria'
AS $function$
DECLARE
    v_nombre  text;
    v_galeria bigint;
    v_orden   integer;
    v_cuerpo  bigint := COALESCE(p_cuerpo_id, ecommerce.fn_cuerpo_principal_id());
BEGIN
    PERFORM ecommerce.fn_contexto_auditoria('ecommerce.inicio_secciones',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    IF NOT EXISTS (SELECT 1 FROM ecommerce.cuerpos WHERE id = v_cuerpo AND deleted_at IS NULL) THEN
        RAISE EXCEPTION 'Ese cuerpo no existe' USING ERRCODE = 'P0013';
    END IF;

    v_nombre := ecommerce.fn_validar_texto(p_nombre, 'El nombre del banner', 100);
    IF v_nombre IS NULL THEN
        RAISE EXCEPTION 'Hace falta el nombre del banner' USING ERRCODE = 'P0001';
    END IF;

    -- El id se pide antes para poder meterlo en la clave: así la galería de un
    -- banner se reconoce de un vistazo y nunca choca con otra
    v_galeria := nextval('ecommerce.galerias_id_seq');

    INSERT INTO ecommerce.galerias (id, clave, nombre, descripcion, tipo, maximo)
    VALUES (v_galeria, 'inicio_banner_' || v_galeria, v_nombre,
            'Inicio: banner simple (rota; cada imagen con su vigencia).', 'banner', 10);

    -- El orden es DENTRO del cuerpo: cada uno tiene su primera y su última
    SELECT COALESCE(max(orden), 0) + 1 INTO v_orden
      FROM ecommerce.inicio_secciones WHERE cuerpo_id = v_cuerpo;

    -- Nace APAGADA: se enciende cuando tenga imágenes. Encendida y vacía la
    -- tienda se la salta igual, pero la lista diría que está en la página.
    INSERT INTO ecommerce.inicio_secciones (cuerpo_id, clave, nombre, galeria_id, orden, activo)
    VALUES (v_cuerpo, 'banner_' || v_galeria, v_nombre, v_galeria, v_orden, false);

    -- Se devuelve la lista entera y nada más, como el resto: la respuesta HTTP
    -- de la casa sólo lleva `message` y `data`, así que una clave suelta aquí
    -- no llegaría a ninguna parte. Quien necesite saber cuál es la nueva la
    -- reconoce porque antes no estaba.
    RETURN jsonb_build_object('success', true,
        'message', format('Banner «%s» creado', v_nombre),
        'data', (ecommerce.fn_inicio_listar(v_cuerpo) -> 'data'));
END;
$function$;

DROP FUNCTION IF EXISTS ecommerce.fn_inicio_banner_nombre(text, text, bigint, varchar, varchar, inet, text, uuid);

CREATE OR REPLACE FUNCTION ecommerce.fn_inicio_banner_nombre(
    p_id             bigint,
    p_nombre         text,
    p_usuario_id     bigint  DEFAULT NULL,
    p_usuario_login  varchar DEFAULT NULL,
    p_usuario_nombre varchar DEFAULT NULL,
    p_ip_address     inet    DEFAULT NULL,
    p_user_agent     text    DEFAULT NULL,
    p_request_id     uuid    DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'ecommerce', 'auditoria'
AS $function$
DECLARE
    v_galeria bigint;
    v_clave   text;
    v_cuerpo  bigint;
    v_nombre  text;
BEGIN
    PERFORM ecommerce.fn_contexto_auditoria('ecommerce.inicio_secciones',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    SELECT galeria_id, clave, cuerpo_id INTO v_galeria, v_clave, v_cuerpo
      FROM ecommerce.inicio_secciones WHERE id = p_id;
    IF v_clave IS NULL THEN
        RAISE EXCEPTION 'Esa sección no existe' USING ERRCODE = 'P0013';
    END IF;
    -- De fábrica: su nombre es el que la tienda sabe pintar, y es como se
    -- reconoce en la lista
    IF ecommerce.fn_inicio_seccion_de_fabrica(v_clave) THEN
        RAISE EXCEPTION 'Esa sección es de fábrica: su nombre no se cambia' USING ERRCODE = 'P0015';
    END IF;

    v_nombre := ecommerce.fn_validar_texto(p_nombre, 'El nombre del banner', 100);
    IF v_nombre IS NULL THEN
        RAISE EXCEPTION 'Hace falta el nombre del banner' USING ERRCODE = 'P0001';
    END IF;

    UPDATE ecommerce.inicio_secciones SET nombre = v_nombre WHERE id = p_id;
    UPDATE ecommerce.galerias SET nombre = v_nombre WHERE id = v_galeria;

    RETURN jsonb_build_object('success', true,
        'message', format('Banner «%s» guardado', v_nombre),
        'data', (ecommerce.fn_inicio_listar(v_cuerpo) -> 'data'));
END;
$function$;

DROP FUNCTION IF EXISTS ecommerce.fn_inicio_banner_eliminar(text, bigint, varchar, varchar, inet, text, uuid);

CREATE OR REPLACE FUNCTION ecommerce.fn_inicio_banner_eliminar(
    p_id             bigint,
    p_usuario_id     bigint  DEFAULT NULL,
    p_usuario_login  varchar DEFAULT NULL,
    p_usuario_nombre varchar DEFAULT NULL,
    p_ip_address     inet    DEFAULT NULL,
    p_user_agent     text    DEFAULT NULL,
    p_request_id     uuid    DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'ecommerce', 'auditoria'
AS $function$
DECLARE
    v_galeria bigint;
    v_clave   text;
    v_cuerpo  bigint;
    v_nombre  text;
    v_cuantas integer;
BEGIN
    PERFORM ecommerce.fn_contexto_auditoria('ecommerce.inicio_secciones',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    SELECT galeria_id, clave, cuerpo_id, nombre
      INTO v_galeria, v_clave, v_cuerpo, v_nombre
      FROM ecommerce.inicio_secciones WHERE id = p_id;
    IF v_clave IS NULL THEN
        RAISE EXCEPTION 'Esa sección no existe' USING ERRCODE = 'P0013';
    END IF;
    -- De fábrica no se borra: la tienda sabe pintarla y volver a ponerla
    -- querría decir inventar una pantalla para añadir secciones. Se apaga.
    IF ecommerce.fn_inicio_seccion_de_fabrica(v_clave) THEN
        RAISE EXCEPTION 'Esa sección es de fábrica: no se borra, se apaga' USING ERRCODE = 'P0015';
    END IF;
    IF v_galeria IS NULL THEN
        RAISE EXCEPTION 'Esa sección no es un banner: no se puede borrar desde aquí'
              USING ERRCODE = 'P0015';
    END IF;

    SELECT count(*) INTO v_cuantas
      FROM ecommerce.galerias_imagenes WHERE galeria_id = v_galeria;

    -- En orden: primero lo que cuelga, al final la fila de la página
    DELETE FROM ecommerce.galerias_imagenes WHERE galeria_id = v_galeria;
    DELETE FROM ecommerce.inicio_secciones  WHERE id = p_id;
    DELETE FROM ecommerce.galerias          WHERE id = v_galeria;

    -- El orden se compacta para que no queden huecos, sólo en su cuerpo
    WITH nuevo AS (
        SELECT id, row_number() OVER (ORDER BY orden, id) AS n
          FROM ecommerce.inicio_secciones WHERE cuerpo_id = v_cuerpo
    )
    UPDATE ecommerce.inicio_secciones s
       SET orden = nuevo.n
      FROM nuevo
     WHERE nuevo.id = s.id AND s.orden <> nuevo.n;

    RETURN jsonb_build_object('success', true,
        'message', format('Banner «%s» borrado con sus %s imágenes', v_nombre, v_cuantas),
        'data', (ecommerce.fn_inicio_listar(v_cuerpo) -> 'data'));
END;
$function$;

-- ----------------------------------------------------------------------------
-- 8. UN CUERPO NUEVO NACE CON LAS SECCIONES DE FÁBRICA
-- ----------------------------------------------------------------------------
-- Copiadas del principal: las mismas, en su orden, con su nombre, APAGADAS y
-- sin rótulo. Cada una que coma de una galería recibe la SUYA, vacía: si
-- compartieran la del principal, el banner de Movilidad enseñaría las
-- imágenes de la portada.
CREATE OR REPLACE FUNCTION ecommerce.fn_cuerpo_sembrar(p_cuerpo_id bigint)
 RETURNS integer
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_fila    record;
    v_galeria bigint;
    v_cuantas integer := 0;
BEGIN
    -- El orden se vuelve a numerar 1..n y no se copia tal cual: el del
    -- principal tiene huecos, porque entre sus secciones de fábrica hay
    -- escaparates que aquí no se copian. Con huecos, lo siguiente que se
    -- añada cae en un número mayor que la cuenta de filas y cuesta leerlo.
    FOR v_fila IN
        SELECT s.clave, s.nombre, s.galeria_id,
               row_number() OVER (ORDER BY s.orden, s.id) AS orden
          FROM ecommerce.inicio_secciones s
         WHERE s.cuerpo_id = ecommerce.fn_cuerpo_principal_id()
           AND ecommerce.fn_inicio_seccion_de_fabrica(s.clave)
         ORDER BY s.orden, s.id
    LOOP
        v_galeria := NULL;

        IF v_fila.galeria_id IS NOT NULL THEN
            v_galeria := nextval('ecommerce.galerias_id_seq');
            INSERT INTO ecommerce.galerias (id, clave, nombre, descripcion, tipo, maximo)
            SELECT v_galeria, 'inicio_banner_' || v_galeria, g.nombre, g.descripcion, g.tipo, g.maximo
              FROM ecommerce.galerias g WHERE g.id = v_fila.galeria_id;
        END IF;

        INSERT INTO ecommerce.inicio_secciones (cuerpo_id, clave, nombre, orden, activo, galeria_id)
        VALUES (p_cuerpo_id, v_fila.clave, v_fila.nombre, v_fila.orden, false, v_galeria)
           ON CONFLICT (cuerpo_id, clave) DO NOTHING;

        v_cuantas := v_cuantas + 1;
    END LOOP;

    RETURN v_cuantas;
END;
$function$;

-- Y guardar un cuerpo nuevo las siembra. Mismo cuerpo de función que en
-- 2026-11-06_ecommerce_cuerpos.sql con una línea más; se repite entero porque
-- CREATE OR REPLACE no sabe añadir una línea.
CREATE OR REPLACE FUNCTION ecommerce.fn_cuerpos_guardar(
    p_id             bigint,
    p_datos          jsonb,
    p_usuario_id     bigint     DEFAULT NULL,
    p_usuario_login  varchar    DEFAULT NULL,
    p_usuario_nombre varchar    DEFAULT NULL,
    p_ip_address     inet       DEFAULT NULL,
    p_user_agent     text       DEFAULT NULL,
    p_request_id     uuid       DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'ecommerce', 'auditoria'
AS $function$
DECLARE
    v_id        bigint := p_id;
    v_nombre    text;
    v_ruta      text;
    v_categoria bigint;
    v_marca     bigint;
    v_principal boolean := false;
    v_sembradas integer := 0;
BEGIN
    PERFORM ecommerce.fn_contexto_auditoria('ecommerce.cuerpos',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    IF p_id IS NOT NULL THEN
        SELECT principal INTO v_principal FROM ecommerce.cuerpos
         WHERE id = p_id AND deleted_at IS NULL;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'Ese cuerpo no existe' USING ERRCODE = 'P0013';
        END IF;
    END IF;

    v_nombre    := btrim(COALESCE(p_datos ->> 'nombre', ''));
    v_ruta      := lower(btrim(COALESCE(p_datos ->> 'ruta', '')));
    v_categoria := nullif(btrim(COALESCE(p_datos ->> 'categoria_id', '')), '')::bigint;
    v_marca     := nullif(btrim(COALESCE(p_datos ->> 'marca_id', '')), '')::bigint;

    -- El principal no apunta a nada, y se dice aquí para que el mensaje
    -- explique qué hacer; la tabla lo prohíbe igual por si entra por otro lado
    IF v_principal AND (v_categoria IS NOT NULL OR v_marca IS NOT NULL) THEN
        RAISE EXCEPTION 'El cuerpo principal es la entrada de la tienda: no puede ser además la página de una categoría o de una marca'
              USING ERRCODE = 'P0015';
    END IF;

    PERFORM ecommerce.fn_cuerpos_validar(p_id, v_nombre, v_ruta, v_categoria, v_marca);

    IF p_id IS NULL THEN
        INSERT INTO ecommerce.cuerpos (nombre, ruta, categoria_id, marca_id, titulo, descripcion,
                                       catalogo, activo)
        VALUES (v_nombre, v_ruta, v_categoria, v_marca,
                ecommerce.fn_validar_texto(p_datos ->> 'titulo', 'El título de la página', 120),
                nullif(btrim(COALESCE(p_datos ->> 'descripcion', '')), ''),
                COALESCE((p_datos ->> 'catalogo')::boolean, false),
                COALESCE((p_datos ->> 'activo')::boolean, true))
        RETURNING id INTO v_id;

        -- Con las secciones que la tienda sabe pintar, apagadas: así se
        -- enciende lo que haga falta en vez de empezar con un hueco
        v_sembradas := ecommerce.fn_cuerpo_sembrar(v_id);
    ELSE
        UPDATE ecommerce.cuerpos
           SET nombre       = v_nombre,
               ruta         = v_ruta,
               categoria_id = v_categoria,
               marca_id     = v_marca,
               titulo       = ecommerce.fn_validar_texto(p_datos ->> 'titulo', 'El título de la página', 120),
               descripcion  = nullif(btrim(COALESCE(p_datos ->> 'descripcion', '')), ''),
               catalogo     = COALESCE((p_datos ->> 'catalogo')::boolean, false),
               -- El principal no se puede apagar: la tienda se quedaría sin
               -- página de entrada
               activo       = CASE WHEN principal THEN true
                                   ELSE COALESCE((p_datos ->> 'activo')::boolean, true) END
         WHERE id = p_id;
    END IF;

    RETURN jsonb_build_object('success', true,
        'message', CASE
            WHEN p_id IS NOT NULL THEN format('Cuerpo «%s» guardado', v_nombre)
            WHEN v_sembradas = 0   THEN format('Cuerpo «%s» creado', v_nombre)
            ELSE format('Cuerpo «%s» creado con sus %s secciones apagadas', v_nombre, v_sembradas) END,
        'data', ecommerce.fn_cuerpos_json(v_id));
END;
$function$;

-- ----------------------------------------------------------------------------
-- 9. COMPROBACIÓN
-- ----------------------------------------------------------------------------
DO $comprobar$
DECLARE
    v_principal bigint;
    v_cuantas   integer;
    v_nuevo     bigint;
    v_lista     jsonb;
    v_una       jsonb;
    v_id        bigint;
    v_otra      bigint;
    v_malo      text;
BEGIN
    v_principal := ecommerce.fn_cuerpo_principal_id();

    -- El banner principal ya saca sus imágenes de su galería
    IF EXISTS (SELECT 1 FROM ecommerce.inicio_secciones
                WHERE clave = 'banner_principal' AND galeria_id IS NULL) THEN
        RAISE EXCEPTION 'El banner principal se quedó sin galería: seguiría leyendo «inicio_banner» a pelo';
    END IF;

    -- De fábrica y fabricadas
    IF NOT ecommerce.fn_inicio_seccion_de_fabrica('banner_simple')
       OR NOT ecommerce.fn_inicio_seccion_de_fabrica('marcas')
       OR ecommerce.fn_inicio_seccion_de_fabrica('banner_42')
       OR ecommerce.fn_inicio_seccion_de_fabrica('seccion_121') THEN
        RAISE EXCEPTION 'fn_inicio_seccion_de_fabrica no distingue las de fábrica de las fabricadas';
    END IF;

    SELECT count(*) INTO v_cuantas FROM ecommerce.inicio_secciones
     WHERE cuerpo_id = v_principal AND ecommerce.fn_inicio_seccion_viva(producto_seccion_id);

    v_lista := ecommerce.fn_inicio_listar() -> 'data';
    IF jsonb_array_length(v_lista) <> v_cuantas THEN
        RAISE EXCEPTION 'Sin argumento tiene que dar el principal: % de %',
              jsonb_array_length(v_lista), v_cuantas;
    END IF;
    IF jsonb_array_length(ecommerce.fn_inicio_listar(v_principal) -> 'data') <> v_cuantas THEN
        RAISE EXCEPTION 'La lista del principal por su id no coincide con la de sin argumento';
    END IF;

    BEGIN
        -- Un cuerpo nuevo nace sembrado
        v_nuevo := (ecommerce.fn_cuerpos_guardar(NULL, jsonb_build_object(
                        'nombre', 'ZZ cuerpo claude', 'ruta', 'zz-cuerpo-claude')) -> 'data' ->> 'id')::bigint;

        v_lista := ecommerce.fn_inicio_listar(v_nuevo) -> 'data';
        IF jsonb_array_length(v_lista) = 0 THEN
            RAISE EXCEPTION 'El cuerpo nuevo nació vacío';
        END IF;
        IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_lista) s WHERE (s ->> 'activo')::boolean) THEN
            RAISE EXCEPTION 'Las secciones de un cuerpo nuevo nacen apagadas';
        END IF;
        IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_lista) s
                    WHERE NOT (s ->> 'fija')::boolean) THEN
            RAISE EXCEPTION 'Al sembrar sólo entran las de fábrica: %', v_lista;
        END IF;
        -- Y su banner no comparte galería con el del principal
        IF EXISTS (SELECT 1 FROM ecommerce.inicio_secciones a
                     JOIN ecommerce.inicio_secciones b ON b.galeria_id = a.galeria_id
                    WHERE a.cuerpo_id = v_nuevo AND b.cuerpo_id = v_principal
                      AND a.galeria_id IS NOT NULL) THEN
            RAISE EXCEPTION 'El cuerpo nuevo comparte galería con el principal';
        END IF;
        IF NOT EXISTS (SELECT 1 FROM ecommerce.inicio_secciones
                        WHERE cuerpo_id = v_nuevo AND clave = 'banner_principal'
                          AND galeria_id IS NOT NULL) THEN
            RAISE EXCEPTION 'El banner principal del cuerpo nuevo no tiene galería propia';
        END IF;

        -- Guardar, encender y el alto, por id
        v_id := (v_lista -> 0 ->> 'id')::bigint;
        v_una := ecommerce.fn_inicio_seccion_guardar(v_id, jsonb_build_object(
                     'titulo', 'ZZ rótulo', 'alcance', 'cuerpo', 'activo', true)) -> 'data';
        IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_una) s
                        WHERE (s ->> 'id')::bigint = v_id
                          AND s ->> 'titulo' = 'ZZ rótulo' AND s ->> 'alcance' = 'cuerpo') THEN
            RAISE EXCEPTION 'No guardó el rótulo o el alcance: %', v_una;
        END IF;
        -- Y devuelve la lista DE SU CUERPO, no la del principal
        IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_una) s
                    WHERE (s ->> 'cuerpo_id')::bigint <> v_nuevo) THEN
            RAISE EXCEPTION 'Devolvió secciones de otro cuerpo: %', v_una;
        END IF;

        PERFORM ecommerce.fn_inicio_seccion_activar(v_id, false);
        PERFORM ecommerce.fn_inicio_seccion_alto(v_id, 'amplia');
        IF (SELECT alto FROM ecommerce.inicio_secciones WHERE id = v_id) <> 'amplia'
           OR (SELECT activo FROM ecommerce.inicio_secciones WHERE id = v_id) THEN
            RAISE EXCEPTION 'El alto o el interruptor por id no hicieron efecto';
        END IF;

        -- Un banner propio del cuerpo, que sí se puede borrar
        PERFORM ecommerce.fn_inicio_banner_crear(v_nuevo, 'ZZ banner claude');
        SELECT id INTO v_otra FROM ecommerce.inicio_secciones
         WHERE cuerpo_id = v_nuevo AND nombre = 'ZZ banner claude';
        IF v_otra IS NULL THEN
            RAISE EXCEPTION 'El banner no se creó en el cuerpo que se le dijo';
        END IF;
        PERFORM ecommerce.fn_inicio_banner_nombre(v_otra, 'ZZ banner claude 2');

        -- Una de fábrica no se borra ni se renombra
        BEGIN
            PERFORM ecommerce.fn_inicio_banner_eliminar(v_id);
            v_malo := 'se pudo borrar una sección de fábrica';
        EXCEPTION WHEN SQLSTATE 'P0015' THEN NULL;
        END;
        BEGIN
            PERFORM ecommerce.fn_inicio_banner_nombre(v_id, 'ZZ otro nombre');
            v_malo := COALESCE(v_malo, 'se pudo renombrar una sección de fábrica');
        EXCEPTION WHEN SQLSTATE 'P0015' THEN NULL;
        END;

        -- El orden es del cuerpo: con un id de otro cuerpo se queja
        BEGIN
            PERFORM ecommerce.fn_inicio_ordenar(
                jsonb_build_array((SELECT id FROM ecommerce.inicio_secciones
                                    WHERE cuerpo_id = v_principal LIMIT 1)), v_nuevo);
            v_malo := COALESCE(v_malo, 'el orden aceptó una sección de otro cuerpo');
        EXCEPTION WHEN SQLSTATE 'P0016' THEN NULL;
        END;

        -- Y con los suyos, al revés, funciona
        PERFORM ecommerce.fn_inicio_ordenar(
            (SELECT jsonb_agg(s.id ORDER BY s.orden DESC)
               FROM ecommerce.inicio_secciones s WHERE s.cuerpo_id = v_nuevo), v_nuevo);
        IF (SELECT count(DISTINCT orden) FROM ecommerce.inicio_secciones WHERE cuerpo_id = v_nuevo)
           <> (SELECT count(*) FROM ecommerce.inicio_secciones WHERE cuerpo_id = v_nuevo) THEN
            RAISE EXCEPTION 'Tras ordenar quedaron dos secciones con el mismo orden';
        END IF;

        -- El borrado del banner se lleva su galería y compacta el orden
        PERFORM ecommerce.fn_inicio_banner_eliminar(v_otra);
        IF EXISTS (SELECT 1 FROM ecommerce.inicio_secciones WHERE id = v_otra) THEN
            RAISE EXCEPTION 'El banner no se borró';
        END IF;

        RAISE EXCEPTION 'deshacer' USING ERRCODE = 'P0099';
    EXCEPTION WHEN SQLSTATE 'P0099' THEN
        NULL;
    END;

    IF v_malo IS NOT NULL THEN
        RAISE EXCEPTION '%', v_malo;
    END IF;
    IF EXISTS (SELECT 1 FROM ecommerce.cuerpos WHERE nombre LIKE 'ZZ %claude') THEN
        RAISE EXCEPTION 'El cuerpo de prueba se quedó en la base';
    END IF;
    IF EXISTS (SELECT 1 FROM ecommerce.galerias WHERE nombre LIKE 'ZZ %claude%') THEN
        RAISE EXCEPTION 'Las galerías de prueba se quedaron en la base';
    END IF;

    RAISE NOTICE 'Comprobado: la lista es por cuerpo, guardar/encender/alto/orden van por id y devuelven el cuerpo que se tocó, un cuerpo nuevo nace con las de fábrica apagadas y con galerías propias, las de fábrica no se borran ni se renombran y el orden no acepta ids de otro cuerpo. No quedó nada.';
END
$comprobar$;

COMMIT;
