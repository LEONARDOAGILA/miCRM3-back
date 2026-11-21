-- ============================================================================
-- LA FRANJA DE ARRIBA, CON SU PROPIO ESTILO
-- ============================================================================
-- La franja tenía dos colores —el fondo y la letra— y nada más: el destacado
-- y la píldora del botón se pintaban con el color de la tienda, el mismo de
-- los botones y los descuentos. Para una campaña eso es poco: lo que se quiere
-- resaltar ahí arriba no siempre es del color de la marca.
--
-- SE AÑADEN CINCO COSAS, todas opcionales y todas del encabezado que las
-- guarde —así una campaña de Navidad puede tener su franja sin tocar la de
-- siempre—:
--
--   franja_destacado      el color de la parte resaltada
--   franja_boton_fondo    el fondo de la píldora
--   franja_boton_texto    su letra
--   franja_tamano         pequeno | normal | grande
--   franja_fuente         titulos | texto | deportiva | serif
--
-- VACÍAS SE QUEDA TODO COMO ESTÁ: el destacado con el color de la tienda y su
-- brillo, y la píldora con los dos tonos que la tienda calcula del fondo. Eso
-- importa: hay un encabezado en producción y esto no puede cambiarle la cara.
--
-- EL TAMAÑO Y LA LETRA SON DE LA FRANJA ENTERA y no de cada trozo. Es una sola
-- línea de texto: tres tipografías ahí no es una opción, es un accidente.
--
-- Como el resto del encabezado, esto vive en el `config` y lo valida
-- fn_encabezado_validar_config, que es la que decide qué claves existen: lo
-- que no esté ahí no se guarda, venga de donde venga.
--
-- ----------------------------------------------------------------------------
-- SE EJECUTA A MANO. Para ensayar sin guardar, cambiar el COMMIT del final por
-- ROLLBACK: la comprobación se hace igual y no queda rastro.
-- ============================================================================

BEGIN;

CREATE OR REPLACE FUNCTION ecommerce.fn_encabezado_validar_config(p_config jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 IMMUTABLE
AS $function$
DECLARE
    v_barra   jsonb := COALESCE(p_config -> 'barra_superior', '{}'::jsonb);
    v_frases  jsonb := p_config -> 'buscador_frases';
    v_barra_on   boolean;
    v_frase   text;
    v_enlace_barra   text;
BEGIN
    IF p_config IS NULL OR jsonb_typeof(p_config) <> 'object' THEN
        RAISE EXCEPTION 'La configuración del encabezado no tiene la forma esperada' USING ERRCODE = 'P0015';
    END IF;
    IF jsonb_typeof(v_barra) <> 'object' THEN
        RAISE EXCEPTION 'La configuración del encabezado no tiene la forma esperada' USING ERRCODE = 'P0015';
    END IF;

    v_barra_on   := COALESCE((v_barra -> 'activo') = 'true'::jsonb, false);

    -- El texto sólo es obligatorio si la franja se va a ver: apagada, da igual
    -- lo que ponga, y exigirlo impediría apagarla para arreglarla luego.
    v_enlace_barra := ecommerce.fn_validar_enlace(v_barra ->> 'boton_enlace', 'La barra superior');

    -- Entre una y cinco frases: con ninguna el buscador se queda sin texto, y
    -- más de cinco no llegan a verse porque van rotando.
    IF v_frases IS NULL OR jsonb_typeof(v_frases) <> 'array'
       OR jsonb_array_length(v_frases) NOT BETWEEN 1 AND 5 THEN
        RAISE EXCEPTION 'El buscador necesita entre 1 y 5 frases' USING ERRCODE = 'P0015';
    END IF;

    FOR v_frase IN SELECT jsonb_array_elements_text(v_frases) LOOP
        PERFORM ecommerce.fn_validar_texto(v_frase, 'Cada frase del buscador', 60, true);
    END LOOP;

    RETURN jsonb_build_object(
        'barra_superior', jsonb_build_object(
            'activo',              v_barra_on,
            'texto',               ecommerce.fn_validar_texto(v_barra ->> 'texto', 'El texto de la barra superior', 80, v_barra_on),
            'destacado',           ecommerce.fn_validar_texto(v_barra ->> 'destacado', 'El destacado de la barra superior', 60),
            'boton_texto',         ecommerce.fn_validar_texto(v_barra ->> 'boton_texto', 'El botón de la barra superior', 40),
            'boton_enlace',        v_enlace_barra,
            'boton_nueva_pestana', ecommerce.fn_nueva_pestana(v_enlace_barra, (v_barra ->> 'boton_nueva_pestana')::boolean)),
        'buscador_frases', (SELECT jsonb_agg(btrim(f)) FROM jsonb_array_elements_text(v_frases) AS f),
        -- EL COLOR DE TODA LA TIENDA. NULL = el rojo de siempre. Los tonos de
        -- hover y de fondo suave los calcula la tienda a partir de éste.
        'color_principal', ecommerce.fn_validar_color(p_config ->> 'color_principal', 'El color de la tienda'),
        -- LOS DESPLEGABLES DEL ENCABEZADO: el fondo del panel y su letra. Los
        -- tres de la barra se pintan igual —categorías, marcas y los del menú
        -- del CRM—, así que son dos colores y no seis. NULL = blanco y el texto
        -- de siempre. Los tonos de al lado —el del mouse encima y el del borde—
        -- los calcula la tienda a partir del fondo, como con el color
        -- principal: guardarlos sería acertar cuatro colores que van juntos.
        'desplegable_fondo', ecommerce.fn_validar_color(p_config ->> 'desplegable_fondo', 'El fondo de los desplegables'),
        'desplegable_texto', ecommerce.fn_validar_color(p_config ->> 'desplegable_texto', 'La letra de los desplegables'),
        -- LA FRANJA DE ARRIBA y LA FILA DEL LOGO, cada una con su fondo y su
        -- letra. NULL = los de la hoja de estilos, como con el color de la
        -- tienda: así el día que cambie el de fábrica no hay que acordarse de
        -- esto. El destacado y el botón de la franja siguen con el color de la
        -- tienda, que es lo que los hace resaltar.
        'franja_fondo',      ecommerce.fn_validar_color(p_config ->> 'franja_fondo', 'El fondo de la franja de arriba'),
        'franja_texto',      ecommerce.fn_validar_color(p_config ->> 'franja_texto', 'La letra de la franja de arriba'),
        -- Y CADA TROZO DE LA FRANJA, por separado: el destacado —la parte que
        -- se mira— y la píldora del botón, con su fondo y su letra. NULL en
        -- cualquiera de los tres = lo de siempre, que es el color de la tienda
        -- en el destacado y la píldora que la tienda calcula del fondo.
        'franja_destacado',    ecommerce.fn_validar_color(p_config ->> 'franja_destacado', 'El destacado de la franja'),
        'franja_boton_fondo',  ecommerce.fn_validar_color(p_config ->> 'franja_boton_fondo', 'El fondo del botón de la franja'),
        'franja_boton_texto',  ecommerce.fn_validar_color(p_config ->> 'franja_boton_texto', 'La letra del botón de la franja'),
        -- EL TAMAÑO Y LA LETRA SON DE LA FRANJA ENTERA, no de cada trozo: es
        -- una sola línea, y tres tipografías en una línea no es una opción, es
        -- un accidente. Son claves y no medidas, como el alto de las secciones:
        -- los píxeles los pone la tienda, que es la que sabe cuánto encoge en
        -- un teléfono.
        'franja_tamano',       ecommerce.fn_validar_opcion(p_config ->> 'franja_tamano',
                                   ARRAY['pequeno', 'normal', 'grande'], 'El tamaño de la franja'),
        'franja_fuente',       ecommerce.fn_validar_opcion(p_config ->> 'franja_fuente',
                                   ARRAY['titulos', 'texto', 'deportiva', 'serif'], 'La letra de la franja'),
        'encabezado_fondo',  ecommerce.fn_validar_color(p_config ->> 'encabezado_fondo', 'El fondo del encabezado'),
        'encabezado_texto',  ecommerce.fn_validar_color(p_config ->> 'encabezado_texto', 'La letra del encabezado')
    );
END;
$function$;

COMMIT;


-- ============================================================================
-- COMPROBACIÓN — no escribe nada
-- ============================================================================
DO $comprobar$
DECLARE
    v_falta text[] := '{}';
    v_salida jsonb;
    v_base   jsonb;
BEGIN
    -- Lo mínimo que la función admite: una frase y la barra apagada
    v_base := jsonb_build_object(
        'barra_superior', jsonb_build_object('activo', false),
        'buscador_frases', jsonb_build_array('Buscar'));

    -- Las cinco claves nuevas salen, y vacías valen NULL
    v_salida := ecommerce.fn_encabezado_validar_config(v_base);
    FOREACH v_base IN ARRAY ARRAY['"franja_destacado"'::jsonb, '"franja_boton_fondo"', '"franja_boton_texto"',
                                  '"franja_tamano"', '"franja_fuente"'] LOOP
        IF NOT (v_salida ? (v_base #>> '{}')) THEN
            v_falta := array_append(v_falta, 'no sale ' || (v_base #>> '{}'));
        END IF;
    END LOOP;

    -- Y con valores, los devuelve
    v_salida := ecommerce.fn_encabezado_validar_config(jsonb_build_object(
        'barra_superior', jsonb_build_object('activo', false),
        'buscador_frases', jsonb_build_array('Buscar'),
        'franja_destacado', '#ff0000',
        'franja_boton_fondo', '#00ff00',
        'franja_boton_texto', '#0000ff',
        'franja_tamano', 'grande',
        'franja_fuente', 'deportiva'));

    IF (v_salida ->> 'franja_destacado') IS DISTINCT FROM '#ff0000'
       OR (v_salida ->> 'franja_boton_fondo') IS DISTINCT FROM '#00ff00'
       OR (v_salida ->> 'franja_boton_texto') IS DISTINCT FROM '#0000ff'
       OR (v_salida ->> 'franja_tamano') IS DISTINCT FROM 'grande'
       OR (v_salida ->> 'franja_fuente') IS DISTINCT FROM 'deportiva' THEN
        v_falta := array_append(v_falta, 'no devuelve lo que se le da: ' || v_salida::text);
    END IF;

    -- Un invento no pasa
    BEGIN
        PERFORM ecommerce.fn_encabezado_validar_config(jsonb_build_object(
            'barra_superior', jsonb_build_object('activo', false),
            'buscador_frases', jsonb_build_array('Buscar'),
            'franja_tamano', 'gigante'));
        v_falta := array_append(v_falta, 'se dejó pasar un tamaño inventado');
    EXCEPTION WHEN others THEN NULL;
    END;

    -- Y lo que ya había sigue estando
    v_salida := ecommerce.fn_encabezado_validar_config(jsonb_build_object(
        'barra_superior', jsonb_build_object('activo', false),
        'buscador_frases', jsonb_build_array('Buscar'),
        'franja_fondo', '#111111'));
    IF (v_salida ->> 'franja_fondo') IS DISTINCT FROM '#111111'
       OR NOT (v_salida ? 'color_principal') OR NOT (v_salida ? 'desplegable_fondo') THEN
        v_falta := array_append(v_falta, 'se perdió algo de lo que ya había');
    END IF;

    IF array_length(v_falta, 1) > 0 THEN
        RAISE EXCEPTION 'La franja con estilo no quedó bien: %', array_to_string(v_falta, '; ');
    END IF;

    RAISE NOTICE 'La franja de arriba ya lleva su destacado, su botón, su tamaño y su letra';
END;
$comprobar$;
