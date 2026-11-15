-- ============================================================================
-- EL BANNER SIMPLE, TAMBIÉN DE BORDE A BORDE
-- ============================================================================
-- Un banner de una sección se podía enseñar de dos maneras: «rotativo» —una
-- imagen a la vez, del ancho del contenido y con las esquinas redondeadas— y
-- «carteles» —todas a la vez, en carteles verticales—.
--
-- SE AÑADE «completo»: una a la vez como el rotativo, pero DE BORDE A BORDE,
-- igual que el banner principal del inicio. Es lo que hacía falta para que un
-- banner ancho no se quede con márgenes a los lados en una página en la que
-- todo lo demás ya llega al borde.
--
-- No hace falta tocar `fn_inicio_listar` ni `fn_cuerpo_publico`: las dos pasan
-- el valor tal cual.
-- ============================================================================

BEGIN;

-- ---------- La columna admite la tercera manera ----------
ALTER TABLE ecommerce.inicio_secciones
    DROP CONSTRAINT IF EXISTS ck_inicio_secciones_banner_vista;

ALTER TABLE ecommerce.inicio_secciones
    ADD CONSTRAINT ck_inicio_secciones_banner_vista
    CHECK (banner_vista IS NULL
           OR banner_vista::text = ANY (ARRAY['rotativo', 'carteles', 'completo']::text[]));

-- ---------- Y guardar la deja pasar ----------
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

COMMIT;


-- ============================================================================
-- COMPROBACIÓN — no escribe nada
-- ============================================================================
DO $comprobar$
DECLARE
    v_falta text[] := '{}';
    v_regla text;
BEGIN
    SELECT pg_get_constraintdef(oid) INTO v_regla
      FROM pg_constraint
     WHERE conrelid = 'ecommerce.inicio_secciones'::regclass
       AND conname = 'ck_inicio_secciones_banner_vista';

    IF v_regla IS NULL THEN
        v_falta := array_append(v_falta, 'no está la regla de la columna');
    ELSE
        IF v_regla NOT LIKE '%completo%' THEN
            v_falta := array_append(v_falta, 'la regla no admite «completo»');
        END IF;
        IF v_regla NOT LIKE '%rotativo%' OR v_regla NOT LIKE '%carteles%' THEN
            v_falta := array_append(v_falta, 'la regla se llevó por delante las otras dos');
        END IF;
    END IF;

    -- La validación de guardar: «completo» pasa y un invento no
    IF ecommerce.fn_validar_opcion('completo', ARRAY['rotativo', 'carteles', 'completo'], 'x') IS DISTINCT FROM 'completo' THEN
        v_falta := array_append(v_falta, 'la validación no deja pasar «completo»');
    END IF;
    IF (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
         WHERE n.nspname = 'ecommerce' AND p.proname = 'fn_inicio_seccion_guardar'
           AND p.prosrc LIKE '%''rotativo'', ''carteles'', ''completo''%') = 0 THEN
        v_falta := array_append(v_falta, 'guardar sigue con las dos de antes');
    END IF;

    IF array_length(v_falta, 1) > 0 THEN
        RAISE EXCEPTION 'El banner completo no quedó bien: %', array_to_string(v_falta, '; ');
    END IF;

    RAISE NOTICE 'El banner simple admite tres maneras: rotativo, carteles y completo';
END;
$comprobar$;
