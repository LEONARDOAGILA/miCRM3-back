-- ============================================================================
-- LA FRANJA SUPERIOR ADMITE VARIOS BOTONES
-- ============================================================================
-- La franja tenía UN botón: `boton_texto` y `boton_enlace`. Para una campaña
-- hace falta más de uno —«+ meses de gracia» y «Ver condiciones», por ejemplo—,
-- y hasta ahora el segundo había que meterlo en el texto, sin ser un botón.
--
-- Pasa a ser una LISTA de hasta cuatro, cada uno con su texto y su URL:
--
--   barra_superior.botones = [ { texto, enlace, nueva_pestana }, … ]
--
-- CUATRO COMO MUCHO: la franja es una línea y en un teléfono cinco píldoras no
-- caben. SIN TEXTO NO HAY BOTÓN: uno en blanco no se puede pulsar porque no se
-- ve, así que se cae de la lista al guardar.
--
-- LO QUE HAY GUARDADO SE CONVIERTE, aquí y también al vuelo: un config con el
-- `boton_texto` de antes se sigue entendiendo —se lee como el primero de la
-- lista—, para que nada pierda su botón por el camino.
--
-- `nueva_pestana` lo sigue decidiendo la base: una dirección de fuera se abre
-- en otra pestaña y una de la tienda, nunca.
--
-- Y SE LLAMA «FRANJA SUPERIOR» EN LOS AVISOS. Antes era «la barra superior» en
-- unos y «la franja de arriba» en otros, y en la pantalla se lee «Franja
-- superior»: tres nombres para lo mismo obligan a adivinar de qué habla el
-- aviso que salió al guardar.
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
    v_botones jsonb;
    v_frases  jsonb := p_config -> 'buscador_frases';
    v_barra_on   boolean;
    v_frase   text;
BEGIN
    IF p_config IS NULL OR jsonb_typeof(p_config) <> 'object' THEN
        RAISE EXCEPTION 'La configuración del encabezado no tiene la forma esperada' USING ERRCODE = 'P0015';
    END IF;
    IF jsonb_typeof(v_barra) <> 'object' THEN
        RAISE EXCEPTION 'La configuración del encabezado no tiene la forma esperada' USING ERRCODE = 'P0015';
    END IF;

    -- El texto sólo es obligatorio si la franja se va a ver: apagada, da igual
    -- lo que ponga, y exigirlo impediría apagarla para arreglarla luego.
    v_barra_on   := COALESCE((v_barra -> 'activo') = 'true'::jsonb, false);

    -- Entre una y cinco frases: con ninguna el buscador se queda sin texto, y
    -- más de cinco no llegan a verse porque van rotando.
    IF v_frases IS NULL OR jsonb_typeof(v_frases) <> 'array'
       OR jsonb_array_length(v_frases) NOT BETWEEN 1 AND 5 THEN
        RAISE EXCEPTION 'El buscador necesita entre 1 y 5 frases' USING ERRCODE = 'P0015';
    END IF;

    FOR v_frase IN SELECT jsonb_array_elements_text(v_frases) LOOP
        PERFORM ecommerce.fn_validar_texto(v_frase, 'Cada frase del buscador', 60, true);
    END LOOP;

    -- ------------------------------------------------------------------
    -- LOS BOTONES DE LA FRANJA: ahora son varios, cada uno con su URL.
    --
    -- Hasta el 20/11/2026 había UNO (`boton_texto` y `boton_enlace`). Lo que
    -- esté guardado así se sigue entendiendo —se lee como el primero de la
    -- lista—, para que un encabezado viejo no pierda su botón al guardarlo.
    --
    -- SIN TEXTO NO HAY BOTÓN: un botón en blanco con dirección no se puede
    -- pulsar porque no se ve, así que se cae de la lista. Y COMO MUCHO CUATRO:
    -- la franja es una línea, y en un teléfono cinco píldoras no caben.
    -- ------------------------------------------------------------------
    v_botones := CASE
        WHEN jsonb_typeof(v_barra -> 'botones') = 'array' THEN v_barra -> 'botones'
        -- Lo de antes, convertido
        WHEN nullif(btrim(COALESCE(v_barra ->> 'boton_texto', '')), '') IS NOT NULL
            THEN jsonb_build_array(jsonb_build_object(
                     'texto',         v_barra ->> 'boton_texto',
                     'enlace',        v_barra ->> 'boton_enlace',
                     'nueva_pestana', v_barra -> 'boton_nueva_pestana'))
        ELSE '[]'::jsonb END;

    IF jsonb_array_length(v_botones) > 4 THEN
        RAISE EXCEPTION 'La franja superior admite como mucho cuatro botones' USING ERRCODE = 'P0015';
    END IF;

    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'texto',  ecommerce.fn_validar_texto(b ->> 'texto', 'El texto del botón', 40, true),
               'enlace', ecommerce.fn_validar_enlace(b ->> 'enlace', 'La URL del botón'),
               -- Lo decide la base y no la pantalla: una dirección de fuera se
               -- abre en otra pestaña y una de la tienda, nunca
               'nueva_pestana', ecommerce.fn_nueva_pestana(
                   ecommerce.fn_validar_enlace(b ->> 'enlace', 'La URL del botón'),
                   (b ->> 'nueva_pestana')::boolean))
           ORDER BY i), '[]'::jsonb)
      INTO v_botones
      FROM jsonb_array_elements(v_botones) WITH ORDINALITY AS t(b, i)
     WHERE nullif(btrim(COALESCE(b ->> 'texto', '')), '') IS NOT NULL;

    RETURN jsonb_build_object(
        'barra_superior', jsonb_build_object(
            'activo',              v_barra_on,
            'texto',               ecommerce.fn_validar_texto(v_barra ->> 'texto', 'El texto de la franja superior', 80, v_barra_on),
            'destacado',           ecommerce.fn_validar_texto(v_barra ->> 'destacado', 'El destacado de la franja superior', 60),
            -- LOS BOTONES, en su orden. Los tres campos sueltos de antes
            -- (boton_texto, boton_enlace, boton_nueva_pestana) ya no salen: lo
            -- que había se convirtió, y dejarlos sería tener el mismo botón
            -- escrito en dos sitios que un día dejan de decir lo mismo.
            'botones', v_botones),
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
        -- LA FRANJA SUPERIOR y LA FILA DEL LOGO, cada una con su fondo y su
        -- letra. NULL = los de la hoja de estilos, como con el color de la
        -- tienda: así el día que cambie el de fábrica no hay que acordarse de
        -- esto. El destacado y el botón de la franja siguen con el color de la
        -- tienda, que es lo que los hace resaltar.
        'franja_fondo',      ecommerce.fn_validar_color(p_config ->> 'franja_fondo', 'El fondo de la franja superior'),
        'franja_texto',      ecommerce.fn_validar_color(p_config ->> 'franja_texto', 'La letra de la franja superior'),
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

-- ---------- Lo guardado, convertido ----------
-- Se pasa por el validador, que es quien sabe: así el config queda exactamente
-- como quedaría al guardar desde la pantalla, sin una segunda versión de la
-- regla escrita aquí.
UPDATE ecommerce.encabezado
   SET config = ecommerce.fn_encabezado_validar_config(config)
 WHERE NOT (config -> 'barra_superior' ? 'botones');

COMMIT;


-- ============================================================================
-- COMPROBACIÓN — no escribe nada
-- ============================================================================
DO $comprobar$
DECLARE
    v_falta  text[] := '{}';
    v_salida jsonb;
    v_base   jsonb := jsonb_build_object('buscador_frases', jsonb_build_array('Buscar'));
BEGIN
    -- Dos botones entran y salen en su orden
    v_salida := ecommerce.fn_encabezado_validar_config(v_base || jsonb_build_object(
        'barra_superior', jsonb_build_object('activo', true, 'texto', 'Hola',
            'botones', jsonb_build_array(
                jsonb_build_object('texto', 'Uno', 'enlace', '/shop'),
                jsonb_build_object('texto', 'Dos', 'enlace', 'https://ejemplo.test')))));

    IF jsonb_array_length(v_salida -> 'barra_superior' -> 'botones') <> 2 THEN
        v_falta := array_append(v_falta, 'no guarda los dos botones');
    ELSE
        IF (v_salida -> 'barra_superior' -> 'botones' -> 0 ->> 'texto') <> 'Uno'
           OR (v_salida -> 'barra_superior' -> 'botones' -> 1 ->> 'texto') <> 'Dos' THEN
            v_falta := array_append(v_falta, 'se desordenaron');
        END IF;
        -- El de casa no abre pestaña; el de fuera sí
        IF (v_salida -> 'barra_superior' -> 'botones' -> 0 ->> 'nueva_pestana') <> 'false'
           OR (v_salida -> 'barra_superior' -> 'botones' -> 1 ->> 'nueva_pestana') <> 'true' THEN
            v_falta := array_append(v_falta, 'la pestaña no la decide la dirección');
        END IF;
    END IF;

    -- Uno sin texto se cae
    v_salida := ecommerce.fn_encabezado_validar_config(v_base || jsonb_build_object(
        'barra_superior', jsonb_build_object('activo', false,
            'botones', jsonb_build_array(jsonb_build_object('texto', '   ', 'enlace', '/shop')))));
    IF jsonb_array_length(v_salida -> 'barra_superior' -> 'botones') <> 0 THEN
        v_falta := array_append(v_falta, 'un botón sin texto se guardó igual');
    END IF;

    -- Cinco, no
    BEGIN
        PERFORM ecommerce.fn_encabezado_validar_config(v_base || jsonb_build_object(
            'barra_superior', jsonb_build_object('activo', false,
                'botones', (SELECT jsonb_agg(jsonb_build_object('texto', 'B' || i))
                              FROM generate_series(1, 5) i))));
        v_falta := array_append(v_falta, 'se dejaron guardar cinco botones');
    EXCEPTION WHEN others THEN NULL;
    END;

    -- Lo viejo se entiende
    v_salida := ecommerce.fn_encabezado_validar_config(v_base || jsonb_build_object(
        'barra_superior', jsonb_build_object('activo', false,
            'boton_texto', 'El de antes', 'boton_enlace', '/shop')));
    IF (v_salida -> 'barra_superior' -> 'botones' -> 0 ->> 'texto') IS DISTINCT FROM 'El de antes' THEN
        v_falta := array_append(v_falta, 'el botón de antes se perdió');
    END IF;
    IF v_salida -> 'barra_superior' ? 'boton_texto' THEN
        v_falta := array_append(v_falta, 'sigue saliendo el campo suelto de antes');
    END IF;

    -- Y ninguno de los guardados se quedó sin convertir
    IF EXISTS (SELECT 1 FROM ecommerce.encabezado WHERE NOT (config -> 'barra_superior' ? 'botones')) THEN
        v_falta := array_append(v_falta, 'queda algún encabezado sin la lista');
    END IF;

    IF array_length(v_falta, 1) > 0 THEN
        RAISE EXCEPTION 'Los botones de la franja no quedaron bien: %', array_to_string(v_falta, '; ');
    END IF;

    RAISE NOTICE 'La franja superior ya admite hasta cuatro botones, cada uno con su URL';
END;
$comprobar$;
