-- ============================================================================
-- EL TAMAÑO DE LA FRANJA, EN PÍXELES
-- ============================================================================
-- Se guardaba una clave —pequeno, normal, grande— y los píxeles los ponía la
-- tienda, como con el alto de las secciones. Para la franja no sirve: es UNA
-- FRASE, se elige mirándola, y quien la escribe quiere decir «15» y verla de
-- 15, no «grande» y descubrir cuánto es eso.
--
-- Pasa a ser un número entre 8 y 48. Fuera de ahí no se guarda: por debajo de
-- 8 no se lee y por encima de 48 la franja deja de ser una franja.
--
-- EN EL TELÉFONO SIGUE ENCOGIENDO, pero en proporción al número elegido (la
-- tienda la baja a seis séptimos, que es lo que ya hacía con los 14 px de
-- siempre), así que un 24 se sigue viendo grande en un móvil sin romper la
-- línea.
--
-- Lo que hubiera guardado con la clave vieja se borra: «normal» no es un
-- número y la función lo rechazaría al guardar cualquier otra cosa del
-- encabezado, dejando una pantalla que no se puede guardar hasta que alguien
-- adivine por qué.
--
-- ----------------------------------------------------------------------------
-- SE EJECUTA A MANO. Para ensayar sin guardar, cambiar el COMMIT del final por
-- ROLLBACK: la comprobación se hace igual y no queda rastro.
-- ============================================================================

BEGIN;

-- ---------- Lo que quedó de la versión anterior ----------
UPDATE ecommerce.encabezado
   SET config = config - 'franja_tamano'
 WHERE config ? 'franja_tamano'
   AND jsonb_typeof(config -> 'franja_tamano') <> 'number';

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
        -- un accidente.
        --
        -- EL TAMAÑO VA EN PÍXELES, entre 8 y 48. Es la excepción a lo que se
        -- hace en las secciones —allá se guarda «grande» y los píxeles los pone
        -- la tienda—: aquí es una sola frase, se elige mirándola y quien la
        -- escribe quiere el número. La tienda sigue encogiéndola en el teléfono,
        -- pero en proporción al que se elija, no a uno fijo.
        --
        -- NULL = los 14 px de siempre.
        'franja_tamano',       ecommerce.fn_validar_entero(p_config ->> 'franja_tamano',
                                   'El tamaño de la franja', 8, 48),
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
    v_falta  text[] := '{}';
    v_salida jsonb;
    v_base   jsonb := jsonb_build_object(
        'barra_superior', jsonb_build_object('activo', false),
        'buscador_frases', jsonb_build_array('Buscar'));
BEGIN
    -- Un número pasa, y sale como número
    v_salida := ecommerce.fn_encabezado_validar_config(v_base || jsonb_build_object('franja_tamano', 15));
    IF jsonb_typeof(v_salida -> 'franja_tamano') <> 'number'
       OR (v_salida ->> 'franja_tamano') <> '15' THEN
        v_falta := array_append(v_falta, 'no devuelve el 15 como número: ' || (v_salida -> 'franja_tamano')::text);
    END IF;

    -- Vacío sigue siendo «el de siempre»
    v_salida := ecommerce.fn_encabezado_validar_config(v_base);
    IF (v_salida -> 'franja_tamano') <> 'null'::jsonb THEN
        v_falta := array_append(v_falta, 'sin tamaño no queda en null');
    END IF;

    -- Fuera de rango, no
    FOREACH v_base IN ARRAY ARRAY['4'::jsonb, '60', '"grande"'] LOOP
        BEGIN
            PERFORM ecommerce.fn_encabezado_validar_config(jsonb_build_object(
                'barra_superior', jsonb_build_object('activo', false),
                'buscador_frases', jsonb_build_array('Buscar'),
                'franja_tamano', v_base));
            v_falta := array_append(v_falta, 'se dejó pasar ' || v_base::text);
        EXCEPTION WHEN others THEN NULL;
        END;
    END LOOP;

    -- Y no quedó ninguna clave vieja guardada
    IF EXISTS (SELECT 1 FROM ecommerce.encabezado
                WHERE config ? 'franja_tamano'
                  AND jsonb_typeof(config -> 'franja_tamano') <> 'number') THEN
        v_falta := array_append(v_falta, 'queda algún encabezado con el tamaño viejo');
    END IF;

    IF array_length(v_falta, 1) > 0 THEN
        RAISE EXCEPTION 'El tamaño en píxeles no quedó bien: %', array_to_string(v_falta, '; ');
    END IF;

    RAISE NOTICE 'El tamaño de la franja ya se guarda en píxeles (entre 8 y 48)';
END;
$comprobar$;
