-- ============================================================================
-- Y EL FONDO DE CADA ENLACE DEL MENÚ
-- ============================================================================
-- Esta misma tarde cada enlace de la barra empezó a poder llevar su color, su
-- tamaño y su tipo de letra. Faltaba el fondo, y hace falta: un enlace de
-- campaña se ve a la primera cuando es una píldora de otro color, no cuando es
-- la misma letra de otro tono.
--
-- EL DE LA BARRA SIGUE SIN ELEGIRSE, que no es lo mismo: la barra entera va del
-- color de la tienda, junto con los botones y el pie, y teñirla aparte la
-- separaría del resto. Esto es el fondo de UNA píldora dentro de ella.
--
-- En NULL —lo normal— el enlace no lleva fondo: se lee directamente sobre la
-- barra, como hasta hoy. El tono del mouse encima NO SE GUARDA: lo calcula la
-- tienda a partir de éste, como con el color principal.
--
-- ----------------------------------------------------------------------------
-- SE EJECUTA A MANO. Para ensayar sin guardar: comentar el COMMIT y poner un
-- ROLLBACK al FINAL DEL TODO, detrás de la comprobación. Con el ROLLBACK en el
-- sitio del COMMIT la comprobación se hace contra la función VIEJA.
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
    v_enlaces jsonb;
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

    -- ------------------------------------------------------------------
    -- LA PINTA DE CADA ENLACE DEL MENÚ, por id (desde el 20/11/2026).
    --
    -- { "12": { "color": …, "tamano": …, "fuente": … } }. Lo normal es que
    -- esto esté vacío y mande el menú entero (menu_texto, menu_tamano,
    -- menu_fuente); se llena cuando un enlace tiene que destacar entre sus
    -- vecinos, que es lo que no se podía hacer con un solo color para todos.
    --
    -- LA CLAVE TIENE QUE SER UN NÚMERO —el id del enlace— y la entrada tiene
    -- que decir algo: una que se queda sin nada elegido se cae, y así el
    -- `config` no acumula enlaces que ya no se pintan de nada.
    --
    -- NO SE COMPRUEBA QUE EL ENLACE EXISTA, y es a propósito por dos razones:
    -- esta función es IMMUTABLE (no mira tablas), y un enlace borrado puede
    -- volver de la papelera, en cuyo caso vuelve con su color.
    -- ------------------------------------------------------------------
    v_enlaces := CASE WHEN jsonb_typeof(p_config -> 'menu_enlaces') = 'object'
                      THEN p_config -> 'menu_enlaces' ELSE '{}'::jsonb END;

    SELECT COALESCE(jsonb_object_agg(t.k, jsonb_build_object(
               -- SU FONDO: lo pedido el 20/11/2026, después de lo demás. El de la
               -- BARRA sigue sin elegirse —va del color de la tienda, con los
               -- botones y el pie—; esto es el de UN enlace, que es una píldora
               -- dentro de ella.
               'fondo',  ecommerce.fn_validar_color(t.v ->> 'fondo', 'El fondo de un enlace del menú'),
               'color',  ecommerce.fn_validar_color(t.v ->> 'color', 'El color de un enlace del menú'),
               'tamano', ecommerce.fn_validar_entero(t.v ->> 'tamano', 'El tamaño de un enlace del menú', 8, 48),
               'fuente', ecommerce.fn_validar_opcion(t.v ->> 'fuente',
                             ARRAY['titulos', 'texto', 'deportiva', 'serif'], 'La letra de un enlace del menú'))),
           '{}'::jsonb)
      INTO v_enlaces
      FROM jsonb_each(v_enlaces) AS t(k, v)
     WHERE t.k ~ '^[0-9]+$'
       AND jsonb_typeof(t.v) = 'object'
       AND (nullif(btrim(COALESCE(t.v ->> 'fondo',  '')), '') IS NOT NULL
         OR nullif(btrim(COALESCE(t.v ->> 'color',  '')), '') IS NOT NULL
         OR nullif(btrim(COALESCE(t.v ->> 'tamano', '')), '') IS NOT NULL
         OR nullif(btrim(COALESCE(t.v ->> 'fuente', '')), '') IS NOT NULL);

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
                           ARRAY['titulos', 'texto', 'deportiva', 'serif'], 'El tipo de letra del menú'),
        -- Y LO DE CADA ENLACE, por id, para el que tenga que destacar entre
        -- sus vecinos. Vacío = todos con lo del menú.
        'menu_enlaces', v_enlaces
    );
END;
$function$;;

COMMIT;


-- ============================================================================
-- COMPROBACIÓN — no escribe nada
-- ============================================================================
DO $comprobar$
DECLARE
    v_falta  text[] := '{}';
    v_salida jsonb;
    v_menu   jsonb;
    v_base   jsonb := jsonb_build_object(
        'barra_superior', jsonb_build_object('activo', false),
        'buscador_frases', jsonb_build_array('Buscar'));
BEGIN
    -- ---------- El fondo se guarda, con lo demás ----------
    v_salida := ecommerce.fn_encabezado_validar_config(v_base || jsonb_build_object(
        'menu_enlaces', jsonb_build_object(
            '12', jsonb_build_object('fondo', '#ffcc00', 'color', '#1d1d1f',
                                     'tamano', 18, 'fuente', 'deportiva'),
            -- Sólo el fondo: lo demás, lo del menú
            '34', jsonb_build_object('fondo', '#00c853'))));

    v_menu := v_salida -> 'menu_enlaces';

    IF (v_menu -> '12' ->> 'fondo') <> '#ffcc00'
       OR (v_menu -> '12' ->> 'color') <> '#1d1d1f'
       OR (v_menu -> '12' ->> 'tamano') <> '18'
       OR (v_menu -> '12' ->> 'fuente') <> 'deportiva' THEN
        v_falta := array_append(v_falta, 'un enlace no guarda sus cuatro cosas: ' || COALESCE(v_menu::text, 'null'));
    END IF;

    -- UNA ENTRADA CON SÓLO EL FONDO SE QUEDA: antes de hoy, los tres campos
    -- que se miraban eran otros y una así se habría caído entera
    IF (v_menu -> '34' ->> 'fondo') <> '#00c853'
       OR (v_menu -> '34' -> 'color') <> 'null'::jsonb THEN
        v_falta := array_append(v_falta, 'un enlace con sólo el fondo no se guarda: ' || COALESCE(v_menu::text, 'null'));
    END IF;

    -- Y lo que ya estaba guardado sigue entero: el color, el tamaño y la letra
    -- de esta mañana tienen que seguir pasando
    v_salida := ecommerce.fn_encabezado_validar_config(v_base || jsonb_build_object(
        'menu_enlaces', jsonb_build_object('7', jsonb_build_object('color', '#ff00ff', 'tamano', 24, 'fuente', 'serif'))));
    IF (v_salida -> 'menu_enlaces' -> '7' ->> 'color') <> '#ff00ff'
       OR (v_salida -> 'menu_enlaces' -> '7' -> 'fondo') <> 'null'::jsonb THEN
        v_falta := array_append(v_falta, 'lo de antes dejó de entenderse: ' || (v_salida -> 'menu_enlaces')::text);
    END IF;

    -- Un fondo inventado, no
    BEGIN
        PERFORM ecommerce.fn_encabezado_validar_config(v_base || jsonb_build_object(
            'menu_enlaces', jsonb_build_object('7', jsonb_build_object('fondo', 'amarillito'))));
        v_falta := array_append(v_falta, 'se dejó pasar un fondo inventado');
    EXCEPTION WHEN others THEN NULL;
    END;

    -- Y lo que hay guardado se sigue entendiendo: si alguno no pasara, nadie
    -- podría guardar ese encabezado desde la pantalla
    PERFORM ecommerce.fn_encabezado_validar_config(config) FROM ecommerce.encabezado;

    IF array_length(v_falta, 1) > 0 THEN
        RAISE EXCEPTION 'El fondo de cada enlace no quedó bien: %', array_to_string(v_falta, '; ');
    END IF;

    RAISE NOTICE 'Cada enlace del menú puede llevar ya su fondo';
END;
$comprobar$;
