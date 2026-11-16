-- ============================================================================
-- EL COLOR DE LOS DESPLEGABLES DEL ENCABEZADO
-- ============================================================================
-- Dos colores más en la configuración del encabezado: el FONDO del panel que
-- se despliega y su LETRA. Valen para los tres desplegables de la barra —el de
-- categorías, el de marcas y los que cuelgan de un enlace del menú—, que se
-- pintan igual a propósito.
--
-- VAN EN EL CONFIG, que es jsonb: no hace falta tocar ninguna tabla.
--
-- NULL = BLANCO Y EL TEXTO DE SIEMPRE. Como con el color de la tienda, sin
-- elegir nada manda la hoja de estilos, y el día que allí cambie el blanco no
-- hay que acordarse de esto.
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
        'desplegable_texto', ecommerce.fn_validar_color(p_config ->> 'desplegable_texto', 'La letra de los desplegables')
    );
END;
$function$;

COMMIT;


-- ============================================================================
-- COMPROBACIÓN — no escribe nada
-- ============================================================================
DO $comprobar$
DECLARE
    v_falta  text[] := '{}';
    v_config jsonb;
    v_salida jsonb;
BEGIN
    SELECT config INTO v_config FROM ecommerce.encabezado WHERE id = 1;
    v_salida := ecommerce.fn_encabezado_validar_config(v_config);

    IF NOT (v_salida ? 'desplegable_fondo' AND v_salida ? 'desplegable_texto') THEN
        v_falta := array_append(v_falta, 'faltan los dos colores en la configuración');
    END IF;

    -- Lo de antes sigue
    IF NOT (v_salida ? 'barra_superior' AND v_salida ? 'buscador_frases' AND v_salida ? 'color_principal') THEN
        v_falta := array_append(v_falta, 'la validación se llevó algo por delante');
    END IF;
    IF v_salida ? 'credito' THEN
        v_falta := array_append(v_falta, 'volvió el aviso de crédito');
    END IF;

    -- Un color bueno se guarda y uno inventado se tira, como el principal
    IF ecommerce.fn_encabezado_validar_config(
           v_config || '{"desplegable_fondo":"#102A43","desplegable_texto":"#FFFFFF"}'::jsonb
       ) ->> 'desplegable_fondo' IS DISTINCT FROM '#102a43' THEN
        v_falta := array_append(v_falta, 'un color bueno no se guardó');
    END IF;
    -- Y uno inventado se RECHAZA con su aviso, no se guarda como nulo
    BEGIN
        PERFORM ecommerce.fn_encabezado_validar_config(
            v_config || '{"desplegable_fondo":"azulito"}'::jsonb);
        v_falta := array_append(v_falta, 'un color inventado pasó el filtro');
    EXCEPTION WHEN others THEN
        NULL;
    END;

    IF array_length(v_falta, 1) > 0 THEN
        RAISE EXCEPTION 'Los colores del desplegable no quedaron bien: %', array_to_string(v_falta, '; ');
    END IF;

    RAISE NOTICE 'Colores de los desplegables listos (ahora: fondo %, letra %)',
                 COALESCE(v_salida ->> 'desplegable_fondo', 'el de siempre'),
                 COALESCE(v_salida ->> 'desplegable_texto', 'el de siempre');
END;
$comprobar$;
