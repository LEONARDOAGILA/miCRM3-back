-- ============================================================================
-- LA PINTA DE CADA ENLACE DEL MENÚ, uno por uno
-- ============================================================================
-- El 20/11/2026, esta misma mañana, el menú entero empezó a poder llevar su
-- color, su tamaño y su tipo de letra: los tres valen para toda la barra. Eso
-- resuelve «quiero el menú más grande», pero no «quiero que MOTOS se vea y lo
-- demás no», que es lo que pide una campaña: un enlace destaca y los otros se
-- quedan donde estaban.
--
-- Así que ahora CADA ENLACE puede llevar lo suyo, igual que cada botón de la
-- franja: color, tamaño (8 a 48) y tipo de letra. En blanco —lo normal— manda
-- lo del menú, que sigue siendo lo que pinta a todos.
--
-- VIVE EN EL `config` DEL ENCABEZADO Y NO EN LA TABLA DE ENLACES, y es a
-- propósito. El menú es UNO SOLO para todos los encabezados —añadir una
-- categoría se hace una vez—, pero la pinta es de la campaña: el encabezado de
-- Navidad pinta «REGALOS» de dorado y el de siempre lo deja como los demás. En
-- una columna de `encabezado_enlaces` el dorado saldría también en enero.
--
-- SE GUARDA POR ID: { "12": { "color": "#ffcc00", "tamano": 18, "fuente": "deportiva" } }.
-- Un enlace borrado deja su entrada ahí sin hacer nada, y eso es lo que se
-- quiere: restaurarlo desde la papelera le devuelve su color. Una entrada que
-- se queda sin nada elegido se cae sola.
--
-- EL FONDO NO ESTÁ, por lo mismo que en el menú entero: la barra va del color
-- de la tienda, junto con los botones y el pie.
--
-- Y SÓLO SE PINTA EN LA BARRA: lo que se elige es cómo destaca un enlace entre
-- sus vecinos. Dentro del desplegable «MÁS» o del panel del celular —los dos
-- blancos— un color pensado para la barra se perdería, así que allá mandan los
-- colores del desplegable, como hasta hoy.
--
-- ----------------------------------------------------------------------------
-- SE EJECUTA A MANO. Para ensayar sin guardar: comentar el COMMIT y poner un
-- ROLLBACK al FINAL DEL TODO, detrás de la comprobación. Con el ROLLBACK en el
-- sitio del COMMIT la comprobación se hace contra las funciones VIEJAS —ya se
-- deshicieron— y dice que falla todo.
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
               'color',  ecommerce.fn_validar_color(t.v ->> 'color', 'El color de un enlace del menú'),
               'tamano', ecommerce.fn_validar_entero(t.v ->> 'tamano', 'El tamaño de un enlace del menú', 8, 48),
               'fuente', ecommerce.fn_validar_opcion(t.v ->> 'fuente',
                             ARRAY['titulos', 'texto', 'deportiva', 'serif'], 'La letra de un enlace del menú'))),
           '{}'::jsonb)
      INTO v_enlaces
      FROM jsonb_each(v_enlaces) AS t(k, v)
     WHERE t.k ~ '^[0-9]+$'
       AND jsonb_typeof(t.v) = 'object'
       AND (nullif(btrim(COALESCE(t.v ->> 'color',  '')), '') IS NOT NULL
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
$function$;


-- ----------------------------------------------------------------------------
-- EL MENÚ DE LA TIENDA: cada enlace de la barra, con su pinta puesta
-- ----------------------------------------------------------------------------
-- La tienda no recibe ids —el menú le llega como un árbol de textos—, así que
-- el color no puede ir a buscarlo ella: se lo lleva puesto cada elemento, en
-- un `estilo` que ya trae el color, el tamaño y el nombre de la tipografía.
--
-- SÓLO LOS DE LA BARRA (p_padre IS NULL): lo que cuelga de un desplegable se
-- pinta con los colores del desplegable, que es un panel blanco donde un color
-- elegido para la barra no se leería.
CREATE OR REPLACE FUNCTION ecommerce.fn_encabezado_menu_publico(p_padre bigint DEFAULT NULL::bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'ecommerce'
AS $function$
DECLARE
    v_salida jsonb := '[]'::jsonb;
    v_hijos  jsonb;
    v_fila   record;
    -- La pinta de cada enlace, la del encabezado que mande hoy. Sólo en la
    -- barra: dentro de un desplegable no se pinta, así que ni se busca.
    v_estilos jsonb := CASE WHEN p_padre IS NULL THEN COALESCE(
        (SELECT e.config -> 'menu_enlaces' FROM ecommerce.encabezado e
          WHERE e.id = ecommerce.fn_encabezado_vigente_id()), '{}'::jsonb)
        ELSE '{}'::jsonb END;
BEGIN
    FOR v_fila IN
        SELECT e.id, e.texto, e.enlace, e.icono, e.nueva_pestana, e.destacado
          FROM ecommerce.encabezado_enlaces e
         WHERE e.padre_id IS NOT DISTINCT FROM p_padre
           AND e.activo AND e.deleted_at IS NULL
           -- Y DENTRO DE SUS FECHAS: un enlace de campaña se apaga solo. Sin
           -- fechas, fn_vigente dice que sí siempre
           AND ecommerce.fn_vigente(e.desde, e.hasta)
         ORDER BY e.orden, e.id
    LOOP
        v_hijos := ecommerce.fn_encabezado_menu_publico(v_fila.id);

        IF v_hijos <> '[]'::jsonb THEN
            v_salida := v_salida || jsonb_build_object(
                'texto',         v_fila.texto,
                'enlace',        NULL,
                'icono',         v_fila.icono,
                'nueva_pestana', false,
                'destacado',     false,
                -- NULL si no se le eligió nada, que es lo normal: entonces
                -- manda la letra del menú entero
                'estilo',        v_estilos -> v_fila.id::text,
                'hijos',         v_hijos);

        ELSIF v_fila.enlace IS NOT NULL
              AND ecommerce.fn_enlace_a_pagina_visible(v_fila.enlace) THEN
            v_salida := v_salida || jsonb_build_object(
                'texto',         v_fila.texto,
                'enlace',        v_fila.enlace,
                'icono',         v_fila.icono,
                'nueva_pestana', v_fila.nueva_pestana,
                'destacado',     v_fila.destacado AND p_padre IS NULL,
                'estilo',        v_estilos -> v_fila.id::text,
                'hijos',         '[]'::jsonb);
        END IF;
    END LOOP;

    RETURN v_salida;
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
    v_menu   jsonb;
    v_publico jsonb;
    v_antes  jsonb;
    v_id     bigint;
    v_vigente bigint;
    v_base   jsonb := jsonb_build_object(
        'barra_superior', jsonb_build_object('activo', false),
        'buscador_frases', jsonb_build_array('Buscar'));
BEGIN
    -- ---------- Lo que se guarda ----------
    v_salida := ecommerce.fn_encabezado_validar_config(v_base || jsonb_build_object(
        'menu_enlaces', jsonb_build_object(
            '12', jsonb_build_object('color', '#ffcc00', 'tamano', 18, 'fuente', 'deportiva'),
            -- Sólo el tamaño: lo demás, lo del menú
            '34', jsonb_build_object('tamano', 20),
            -- Sin nada elegido: se cae
            '56', jsonb_build_object('color', '', 'tamano', '', 'fuente', ''),
            -- Una clave que no es un id: se cae
            'hola', jsonb_build_object('color', '#ffffff'))));

    v_menu := v_salida -> 'menu_enlaces';

    IF (v_menu -> '12' ->> 'color') <> '#ffcc00'
       OR (v_menu -> '12' ->> 'tamano') <> '18'
       OR (v_menu -> '12' ->> 'fuente') <> 'deportiva' THEN
        v_falta := array_append(v_falta, 'un enlace no guarda su pinta: ' || COALESCE(v_menu::text, 'null'));
    END IF;

    IF jsonb_typeof(v_menu -> '12' -> 'tamano') <> 'number' THEN
        v_falta := array_append(v_falta, 'el tamaño de un enlace no sale como número');
    END IF;

    -- El que sólo lleva el tamaño: los otros dos en null, para que mande el menú
    IF (v_menu -> '34' -> 'color') <> 'null'::jsonb
       OR (v_menu -> '34' -> 'fuente') <> 'null'::jsonb
       OR (v_menu -> '34' ->> 'tamano') <> '20' THEN
        v_falta := array_append(v_falta, 'un enlace con sólo el tamaño no queda bien: ' || COALESCE(v_menu::text, 'null'));
    END IF;

    IF v_menu ? '56' THEN
        v_falta := array_append(v_falta, 'una entrada sin nada elegido no se cayó');
    END IF;
    IF v_menu ? 'hola' THEN
        v_falta := array_append(v_falta, 'una clave que no es un id no se cayó');
    END IF;

    -- Sin tocar nada, el objeto vacío (y no null: la tienda lo recorre)
    v_salida := ecommerce.fn_encabezado_validar_config(v_base);
    IF (v_salida -> 'menu_enlaces') <> '{}'::jsonb THEN
        v_falta := array_append(v_falta, 'sin pintar ningún enlace no queda el objeto vacío');
    END IF;

    -- Lo que no vale, no pasa
    FOR v_menu IN SELECT x FROM unnest(ARRAY[
        jsonb_build_object('7', jsonb_build_object('color', 'azulito')),
        jsonb_build_object('7', jsonb_build_object('tamano', 60)),
        jsonb_build_object('7', jsonb_build_object('fuente', 'gotica'))]) x
    LOOP
        BEGIN
            PERFORM ecommerce.fn_encabezado_validar_config(v_base || jsonb_build_object('menu_enlaces', v_menu));
            v_falta := array_append(v_falta, 'se dejó pasar ' || v_menu::text);
        EXCEPTION WHEN others THEN NULL;
        END;
    END LOOP;

    -- ---------- Y que llegue a la tienda ----------
    -- Se pinta un enlace de verdad del encabezado que manda hoy, se mira el
    -- menú público y se deshace: así se comprueba el camino entero sin dejar
    -- un color puesto que nadie eligió.
    SELECT id INTO v_id FROM ecommerce.encabezado_enlaces
     WHERE padre_id IS NULL AND activo AND deleted_at IS NULL
       AND ecommerce.fn_vigente(desde, hasta)
     ORDER BY orden, id LIMIT 1;

    IF v_id IS NULL THEN
        v_falta := array_append(v_falta, 'no hay enlaces en la barra: el menú público se quedó sin comprobar');
    ELSE
        SELECT e.id, e.config INTO v_vigente, v_antes
          FROM ecommerce.encabezado e WHERE e.id = ecommerce.fn_encabezado_vigente_id();

        UPDATE ecommerce.encabezado
           SET config = jsonb_set(config, '{menu_enlaces}', jsonb_build_object(
                   v_id::text, jsonb_build_object('color', '#ffcc00', 'tamano', 18, 'fuente', 'deportiva')))
         WHERE id = v_vigente;

        v_publico := ecommerce.fn_encabezado_menu_publico(NULL);

        -- EL QUE SE PINTÓ, con su pinta puesta
        SELECT x INTO v_menu
          FROM jsonb_array_elements(v_publico) x
         WHERE (x -> 'estilo' ->> 'color') = '#ffcc00';

        IF v_menu IS NULL THEN
            v_falta := array_append(v_falta, 'la pinta no llega al menú de la tienda: ' || v_publico::text);
        ELSIF (v_menu -> 'estilo' ->> 'tamano') <> '18'
           OR (v_menu -> 'estilo' ->> 'fuente') <> 'deportiva' THEN
            v_falta := array_append(v_falta, 'la pinta llega a medias: ' || (v_menu -> 'estilo')::text);
        END IF;

        -- Y LOS DEMÁS EN NULL, para que les mande el menú entero. (Puede que
        -- no haya otros: entonces no hay nada que comprobar aquí.)
        IF jsonb_array_length(v_publico) > 1
           AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_publico) x
                            WHERE (x -> 'estilo') = 'null'::jsonb) THEN
            v_falta := array_append(v_falta, 'los enlaces sin pinta propia no llegan en null');
        END IF;

        -- Deshecho: ese color era de mentira
        UPDATE ecommerce.encabezado SET config = v_antes WHERE id = v_vigente;
    END IF;

    -- Y lo que ya estaba guardado se sigue entendiendo: si alguno no pasara,
    -- esto reventaría y nadie podría guardar ese encabezado desde la pantalla
    PERFORM ecommerce.fn_encabezado_validar_config(config) FROM ecommerce.encabezado;

    IF array_length(v_falta, 1) > 0 THEN
        RAISE EXCEPTION 'La pinta de cada enlace no quedó bien: %', array_to_string(v_falta, '; ');
    END IF;

    RAISE NOTICE 'Cada enlace del menú puede llevar ya su color, su tamaño y su letra';
END;
$comprobar$;
