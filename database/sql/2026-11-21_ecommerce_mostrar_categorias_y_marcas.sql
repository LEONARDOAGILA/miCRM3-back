-- ============================================================================
-- ENSEÑAR O NO «CATEGORÍAS» Y «MARCAS»
-- ============================================================================
-- La barra del menú lleva dos desplegables que NO son enlaces del CRM:
-- «CATEGORÍAS» y «MARCAS». No viven en `encabezado_enlaces` —los arma la
-- tienda con el catálogo, en cascada el primero y en lista el segundo—, así
-- que no había manera de quitarlos: una tienda que vende una sola marca
-- tenía que enseñar «MARCAS» igual, con una lista de uno.
--
-- Desde aquí son dos palancas del encabezado, `mostrar_menu_categorias` y
-- `mostrar_menu_marcas`, y como todo lo demás CADA ENCABEZADO LLEVA LAS
-- SUYAS: una campaña de motos puede esconder las categorías y dejar las
-- marcas, y el de siempre seguir con los dos.
--
-- SE GUARDA LO QUE SE APAGA. Lo que falte se entiende encendido, así que lo
-- que ya está guardado sigue enseñando los dos sin tocarle nada: es como
-- estaba, y es lo que se espera de una palanca que nadie ha visto todavía.
--
-- ----------------------------------------------------------------------------
-- SE EJECUTA A MANO. Para ensayar: comentar el COMMIT y poner un ROLLBACK al
-- final del todo.
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
    v_mensajes jsonb;
    v_efectos  jsonb;
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

    -- ------------------------------------------------------------------
    -- LOS MENSAJES QUE SE TURNAN (desde el 20/11/2026).
    --
    -- `texto` y `destacado` siguen siendo EL PRIMER MENSAJE, el de
    -- siempre; esta lista son los SIGUIENTES. Con la lista vacía la
    -- franja es la de toda la vida, una frase quieta, y no hay nada que
    -- cambiar en lo que ya está guardado.
    --
    -- HASTA CUATRO MÁS (cinco en total, como las frases del buscador):
    -- cada uno se ve unos segundos, y con diez nadie llega a leer el
    -- último antes de irse de la página.
    --
    -- SIN TEXTO NO HAY MENSAJE: uno en blanco dejaría la franja vacía
    -- unos segundos y parecería que la tienda se rompió. El destacado sí
    -- es opcional, como en el primero.
    -- ------------------------------------------------------------------
    v_mensajes := CASE WHEN jsonb_typeof(v_barra -> 'mensajes') = 'array'
                       THEN v_barra -> 'mensajes' ELSE '[]'::jsonb END;

    IF jsonb_array_length(v_mensajes) > 4 THEN
        RAISE EXCEPTION 'La franja admite cuatro mensajes más del primero, cinco en total'
              USING ERRCODE = 'P0015';
    END IF;

    SELECT COALESCE(jsonb_agg(
               ecommerce.fn_franja_mensaje(m) ORDER BY i), '[]'::jsonb)
      INTO v_mensajes
      FROM jsonb_array_elements(v_mensajes) WITH ORDINALITY AS t(m, i)
     WHERE nullif(btrim(COALESCE(m ->> 'texto', '')), '') IS NOT NULL;

    -- ------------------------------------------------------------------
    -- Y LOS EFECTOS (desde el 20/11/2026).
    --
    -- La franja llevaba un brillo escrito en la hoja de estilos de la
    -- tienda que se apagaba solo: iba por debajo del destacado, así que
    -- en cuanto se le elegía un color el color lo tapaba y la franja se
    -- quedaba quieta sin que nadie entendiera por qué. Ahora se eligen.
    --
    -- SON VARIOS A LA VEZ y por eso es una lista y no una opción: tocan
    -- tres sitios distintos —el destacado, las píldoras y el fondo— y
    -- combinarlos es decisión de quien lo mira.
    --
    --   destello  una luz cruza el destacado y las píldoras
    --   latido    las píldoras crecen y vuelven, muy poco, en bucle
    --   luz       el fondo de la franja lleva un resplandor que se desplaza
    --
    -- Lo que no esté en esa lista se cae: así un nombre mal escrito no
    -- llega a la tienda, que no sabría qué hacer con él.
    -- ------------------------------------------------------------------
    SELECT COALESCE(jsonb_agg(DISTINCT e ORDER BY e), '[]'::jsonb)
      INTO v_efectos
      FROM jsonb_array_elements_text(CASE WHEN jsonb_typeof(v_barra -> 'efectos') = 'array'
                                          THEN v_barra -> 'efectos' ELSE '[]'::jsonb END) AS t(e)
     WHERE e IN ('destello', 'latido', 'luz');

    RETURN jsonb_build_object(
        'barra_superior', jsonb_build_object(
            'activo',              v_barra_on,
            -- EL PRIMER MENSAJE, con sus dos partes. Se arma con la misma
            -- función que los demás —`texto` es obligatorio si la franja está
            -- encendida, de ahí el segundo parámetro— y luego se le añaden
            -- los botones y los efectos, que son de la franja entera.
            --
            -- POR QUÉ EL PRIMERO VIVE SUELTO Y NO DENTRO DE `mensajes`: porque
            -- SIEMPRE HAY UNO. Meterlo en la lista permitiría una franja
            -- encendida y sin nada que decir, y habría que inventar una regla
            -- para impedirlo; así la regla es la forma del dato.
            'texto',               ecommerce.fn_validar_texto(v_barra ->> 'texto', 'El texto de la franja superior', 80, v_barra_on),
            'destacado',           ecommerce.fn_validar_texto(v_barra ->> 'destacado', 'El destacado de la franja superior', 60),
            'texto_color',         ecommerce.fn_validar_color(v_barra ->> 'texto_color', 'El color del texto de la franja'),
            'texto_tamano',        ecommerce.fn_validar_entero(v_barra ->> 'texto_tamano', 'El tamaño del texto de la franja', 8, 48),
            'texto_fuente',        ecommerce.fn_validar_opcion(v_barra ->> 'texto_fuente',
                                       ARRAY['titulos', 'texto', 'deportiva', 'serif'], 'La letra del texto de la franja'),
            'destacado_color',     ecommerce.fn_validar_color(v_barra ->> 'destacado_color', 'El color del destacado de la franja'),
            'destacado_tamano',    ecommerce.fn_validar_entero(v_barra ->> 'destacado_tamano', 'El tamaño del destacado de la franja', 8, 48),
            'destacado_fuente',    ecommerce.fn_validar_opcion(v_barra ->> 'destacado_fuente',
                                       ARRAY['titulos', 'texto', 'deportiva', 'serif'], 'La letra del destacado de la franja'),
            -- LOS BOTONES, en su orden. Los tres campos sueltos de antes
            -- (boton_texto, boton_enlace, boton_nueva_pestana) ya no salen: lo
            -- que había se convirtió, y dejarlos sería tener el mismo botón
            -- escrito en dos sitios que un día dejan de decir lo mismo.
            'botones', v_botones,
            -- LOS SIGUIENTES MENSAJES, los que se turnan con el primero.
            -- Vacío = una frase quieta, que es la franja de siempre.
            'mensajes', v_mensajes,
            -- Y QUÉ SE MUEVE. Vacío = nada, como hasta hoy.
            'efectos', v_efectos),
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
        -- LA PÍLDORA DEL BOTÓN, con su fondo y su letra. NULL = la que la
        -- tienda calcula a partir del fondo de la franja.
        --
        -- `franja_texto` y `franja_destacado` YA NO ESTÁN (21/11/2026): el
        -- color de lo que se lee es de CADA PARTE DE CADA MENSAJE, igual que
        -- el tamaño y la letra. El fondo sí se queda aquí: es uno solo.
        'franja_boton_fondo',  ecommerce.fn_validar_color(p_config ->> 'franja_boton_fondo', 'El fondo del botón de la franja'),
        'franja_boton_texto',  ecommerce.fn_validar_color(p_config ->> 'franja_boton_texto', 'La letra del botón de la franja'),
        -- `franja_tamano` y `franja_fuente` YA NO ESTÁN (20/11/2026). Eran de
        -- la franja entera, y desde que los mensajes se turnan eso no se
        -- sostiene: cada uno dice una cosa distinta y pide su propio cuerpo.
        -- Viven en `barra_superior.tamano`/`fuente` para el primero y dentro
        -- de cada entrada de `mensajes` para los demás.
        --
        -- EL TAMAÑO VA EN PÍXELES, entre 8 y 48. Es la excepción a lo que se
        -- hace en las secciones —allá se guarda «grande» y los píxeles los pone
        -- la tienda—: aquí es una frase, se elige mirándola y quien la escribe
        -- quiere el número. La tienda la sigue encogiendo en el teléfono, pero
        -- en proporción al que se elija, no a uno fijo.
        'encabezado_fondo',  ecommerce.fn_validar_color(p_config ->> 'encabezado_fondo', 'El fondo del encabezado'),
        'encabezado_texto',  ecommerce.fn_validar_color(p_config ->> 'encabezado_texto', 'La letra del encabezado'),
        -- EL MENÚ: la barra de enlaces (CATEGORÍAS, PRODUCTOS, NUESTRAS
        -- TIENDAS…). SU FONDO NO ESTÁ AQUÍ: la barra va del color de la tienda,
        -- igual que los botones y el pie, y teñirla aparte la separaría del
        -- resto. Lo que se elige es cómo se lee encima.
        --
        -- NULL en los tres = blanco, 12 px y la letra de la tienda, que es lo
        -- que tiene escrito su hoja de estilos.
        -- LOS DOS DESPLEGABLES QUE PONE LA TIENDA: «CATEGORÍAS» y «MARCAS».
        --
        -- No son enlaces del menú —no están en `encabezado_enlaces`, los arma
        -- la tienda con el catálogo—, así que no se podían quitar: una tienda
        -- que sólo vende motos tenía que enseñar «MARCAS» igual.
        --
        -- SE GUARDA LO QUE SE APAGA, NO LO QUE SE ENCIENDE: lo que falte, o
        -- venga en nulo, se entiende como que SÍ se muestra. Así los
        -- encabezados de antes del 21/11/2026 siguen enseñando los dos sin
        -- tener que tocarles el config, que es como estaban.
        'mostrar_menu_categorias', (p_config -> 'mostrar_menu_categorias') IS DISTINCT FROM 'false'::jsonb,
        'mostrar_menu_marcas',     (p_config -> 'mostrar_menu_marcas')     IS DISTINCT FROM 'false'::jsonb,
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
$function$;

COMMIT;


-- ============================================================================
-- COMPROBACIÓN — no escribe nada
-- ============================================================================
DO $comprobar$
DECLARE
    v_falta text[] := '{}';
    v_sale  jsonb;
    v_base  jsonb := jsonb_build_object(
        'barra_superior', jsonb_build_object('activo', true, 'texto', 'uno'),
        'buscador_frases', jsonb_build_array('busca'));
BEGIN
    -- Sin decir nada, los dos encendidos: es como estaba
    v_sale := ecommerce.fn_encabezado_validar_config(v_base);
    IF v_sale -> 'mostrar_menu_categorias' <> 'true'::jsonb
       OR v_sale -> 'mostrar_menu_marcas' <> 'true'::jsonb THEN
        v_falta := array_append(v_falta, 'sin decir nada no salen los dos encendidos');
    END IF;

    -- Apagando uno, el otro se queda
    v_sale := ecommerce.fn_encabezado_validar_config(v_base || jsonb_build_object('mostrar_menu_marcas', false));
    IF v_sale -> 'mostrar_menu_marcas' <> 'false'::jsonb
       OR v_sale -> 'mostrar_menu_categorias' <> 'true'::jsonb THEN
        v_falta := array_append(v_falta, 'apagar las marcas no deja bien a las categorías');
    END IF;

    -- Y los dos apagados
    v_sale := ecommerce.fn_encabezado_validar_config(v_base || jsonb_build_object(
        'mostrar_menu_categorias', false, 'mostrar_menu_marcas', false));
    IF v_sale -> 'mostrar_menu_categorias' <> 'false'::jsonb
       OR v_sale -> 'mostrar_menu_marcas' <> 'false'::jsonb THEN
        v_falta := array_append(v_falta, 'no se pueden apagar los dos');
    END IF;

    -- Un nulo no apaga nada: apagar es decir false
    v_sale := ecommerce.fn_encabezado_validar_config(v_base || jsonb_build_object('mostrar_menu_categorias', null));
    IF v_sale -> 'mostrar_menu_categorias' <> 'true'::jsonb THEN
        v_falta := array_append(v_falta, 'un nulo apaga las categorías');
    END IF;

    IF array_length(v_falta, 1) > 0 THEN
        RAISE EXCEPTION 'Las palancas no quedaron bien: %', array_to_string(v_falta, '; ');
    END IF;

    RAISE NOTICE 'Comprobado: sin decir nada los dos se muestran, cada uno se apaga por su lado y un nulo no apaga nada. No quedó nada.';
END;
$comprobar$;
