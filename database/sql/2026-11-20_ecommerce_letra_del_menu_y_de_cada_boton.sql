-- ============================================================================
-- LA LETRA DEL MENÚ, Y LA PINTA DE CADA BOTÓN DE LA FRANJA
-- ============================================================================
-- DOS COSAS QUE HASTA AHORA NO SE PODÍAN TOCAR:
--
-- 1. EL MENÚ —la barra de CATEGORÍAS, PRODUCTOS, NUESTRAS TIENDAS— se leía
--    siempre igual: blanco, 12 px y la letra de la tienda, escrito en la hoja
--    de estilos. Ahora se elige el color, el tamaño (8 a 48) y el tipo de
--    letra. El FONDO no: la barra va del color de la tienda, junto con los
--    botones y el pie, y teñirla aparte la separaría del resto.
--
-- 2. LOS BOTONES DE LA FRANJA compartían fondo y letra, los de la franja. Para
--    una campaña hace falta que uno destaque sobre el otro —«COMPRAR» al lado
--    de «Ver condiciones»—, así que cada uno puede llevar ahora su fondo, su
--    color de letra y su tamaño. En NULL (lo normal) manda lo de la franja, que
--    sigue siendo lo que pinta a todos.
--
-- EL TIPO DE LETRA SIGUE SIENDO DE LA FRANJA ENTERA y no de cada botón: es una
-- sola línea, y tres tipografías en una línea no es una opción, es un
-- accidente. El tamaño sí es de cada uno, porque es lo que hace que uno pese
-- más que otro.
--
-- Dentro de un botón, `texto` es lo que DICE y `letra` el color con el que se
-- lee: el rótulo ya se llamaba así desde que son varios.
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
               -- CADA BOTÓN CON SU PINTA (desde el 20/11/2026). Son píldoras de
               -- la misma franja, así que lo normal es que vayan iguales: estos
               -- tres en NULL y manda lo de la franja (franja_boton_fondo,
               -- franja_boton_texto y el tamaño de la franja). Se llenan cuando
               -- uno tiene que destacar sobre los otros —«COMPRAR» al lado de
               -- «Ver condiciones»—, que es justo lo que no se podía hacer
               -- teniendo un solo color para todos.
               --
               -- 'texto' es lo que DICE el botón y 'letra' el color con el que
               -- se lee: dentro del botón el rótulo ya se llamaba así.
               'fondo',  ecommerce.fn_validar_color(b ->> 'fondo', 'El fondo del botón'),
               'letra',  ecommerce.fn_validar_color(b ->> 'letra', 'La letra del botón'),
               'tamano', ecommerce.fn_validar_entero(b ->> 'tamano', 'El tamaño del botón', 8, 48),
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
        'encabezado_texto',  ecommerce.fn_validar_color(p_config ->> 'encabezado_texto', 'La letra del encabezado'),
        -- EL MENÚ: la barra de enlaces (CATEGORÍAS, PRODUCTOS, NUESTRAS
        -- TIENDAS…). SU FONDO NO ESTÁ AQUÍ: la barra va del color de la tienda,
        -- igual que los botones y el pie, y teñirla aparte la separaría del
        -- resto. Lo que se elige es cómo se lee encima.
        --
        -- NULL en los tres = blanco, 12 px y la letra de la tienda, que es lo
        -- que tiene escrito su hoja de estilos.
        'menu_texto',  ecommerce.fn_validar_color(p_config ->> 'menu_texto', 'La letra del menú'),
        'menu_tamano', ecommerce.fn_validar_entero(p_config ->> 'menu_tamano',
                           'El tamaño del menú', 8, 48),
        'menu_fuente', ecommerce.fn_validar_opcion(p_config ->> 'menu_fuente',
                           ARRAY['titulos', 'texto', 'deportiva', 'serif'], 'El tipo de letra del menú')
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
    -- ---------- El menú ----------
    v_salida := ecommerce.fn_encabezado_validar_config(v_base || jsonb_build_object(
        'menu_texto', '#ffcc00', 'menu_tamano', 16, 'menu_fuente', 'deportiva'));

    IF (v_salida ->> 'menu_texto') <> '#ffcc00'
       OR (v_salida ->> 'menu_tamano') <> '16'
       OR (v_salida ->> 'menu_fuente') <> 'deportiva' THEN
        v_falta := array_append(v_falta, 'el menú no guarda sus tres cosas: ' || v_salida::text);
    END IF;

    IF jsonb_typeof(v_salida -> 'menu_tamano') <> 'number' THEN
        v_falta := array_append(v_falta, 'el tamaño del menú no sale como número');
    END IF;

    -- Sin elegir nada, los tres en null (manda la hoja de estilos)
    v_salida := ecommerce.fn_encabezado_validar_config(v_base);
    IF (v_salida -> 'menu_texto') <> 'null'::jsonb
       OR (v_salida -> 'menu_tamano') <> 'null'::jsonb
       OR (v_salida -> 'menu_fuente') <> 'null'::jsonb THEN
        v_falta := array_append(v_falta, 'sin elegir nada el menú no queda en null');
    END IF;

    -- Fuera de rango, no
    FOR v_salida IN SELECT x FROM unnest(ARRAY['4'::jsonb, '60']) x LOOP
        BEGIN
            PERFORM ecommerce.fn_encabezado_validar_config(v_base || jsonb_build_object('menu_tamano', v_salida));
            v_falta := array_append(v_falta, 'se dejó pasar un menú de ' || v_salida::text);
        EXCEPTION WHEN others THEN NULL;
        END;
    END LOOP;

    -- ---------- Cada botón con su pinta ----------
    v_salida := ecommerce.fn_encabezado_validar_config(v_base || jsonb_build_object(
        'barra_superior', jsonb_build_object('activo', true, 'texto', 'Hola',
            'botones', jsonb_build_array(
                jsonb_build_object('texto', 'Con pinta', 'enlace', '/shop',
                    'fondo', '#00ff00', 'letra', '#000080', 'tamano', 20),
                jsonb_build_object('texto', 'Sin pinta', 'enlace', '/shop')))));

    IF (v_salida -> 'barra_superior' -> 'botones' -> 0 ->> 'fondo') <> '#00ff00'
       OR (v_salida -> 'barra_superior' -> 'botones' -> 0 ->> 'letra') <> '#000080'
       OR (v_salida -> 'barra_superior' -> 'botones' -> 0 ->> 'tamano') <> '20' THEN
        v_falta := array_append(v_falta, 'un botón no guarda su pinta: '
            || (v_salida -> 'barra_superior' -> 'botones' -> 0)::text);
    END IF;

    -- El de al lado, sin nada: en null, para que mande la franja
    IF (v_salida -> 'barra_superior' -> 'botones' -> 1 -> 'fondo') <> 'null'::jsonb
       OR (v_salida -> 'barra_superior' -> 'botones' -> 1 -> 'letra') <> 'null'::jsonb
       OR (v_salida -> 'barra_superior' -> 'botones' -> 1 -> 'tamano') <> 'null'::jsonb THEN
        v_falta := array_append(v_falta, 'un botón sin pinta propia no queda en null');
    END IF;

    -- Un color inventado en un botón, no
    BEGIN
        PERFORM ecommerce.fn_encabezado_validar_config(v_base || jsonb_build_object(
            'barra_superior', jsonb_build_object('activo', false,
                'botones', jsonb_build_array(jsonb_build_object('texto', 'X', 'fondo', 'azulito')))));
        v_falta := array_append(v_falta, 'se dejó pasar un color inventado en un botón');
    EXCEPTION WHEN others THEN NULL;
    END;

    -- Y lo que ya estaba guardado se sigue entendiendo: si alguno no pasara,
    -- esto reventaría y nadie podría guardar ese encabezado desde la pantalla
    PERFORM ecommerce.fn_encabezado_validar_config(config) FROM ecommerce.encabezado;

    IF array_length(v_falta, 1) > 0 THEN
        RAISE EXCEPTION 'La letra del menú y la pinta de los botones no quedaron bien: %', array_to_string(v_falta, '; ');
    END IF;

    RAISE NOTICE 'El menú ya tiene color, tamaño y letra, y cada botón de la franja su pinta';
END;
$comprobar$;
