-- ============================================================================
-- CUATRO LETRAS MÁS PARA LA TIENDA
-- ============================================================================
-- Hasta hoy se podía elegir entre cuatro: «titulos» (Poppins), «texto»
-- (Inter), «deportiva» (Barlow Condensed en cursiva) y «serif» (Georgia).
-- Se añaden otras cuatro, con sus claves:
--
--   impacto     Bebas Neue         alta, estrecha y en mayúsculas, para precios
--   manuscrita  Pacifico           escrita a mano, para campañas de temporada
--   elegante    Playfair Display   serifa con contraste, para algo caro
--   gruesa      Montserrat         ancha y sólida, para una palabra grande
--
-- LA CLAVE NO ES EL NOMBRE DE LA LETRA, y eso es lo que hace que esto sea
-- una lista cerrada: la tienda traduce la clave a una familia que ELLA
-- descarga (index.html de miEcommerce). Guardar aquí «Pacifico» a secas
-- sería pedirle al navegador del cliente una letra que nadie le ha mandado.
-- Las cuatro nuevas se añaden a esa descarga en el mismo cambio.
--
-- EL PIE SIGUE SIN «serif» a propósito: Georgia no la manda la tienda, la
-- pone el equipo del cliente si la tiene, y así se decidió el 07/11/2026.
-- Las cuatro nuevas sí se descargan, así que el pie también las admite.
--
-- Las funciones de aquí abajo salen tal cual de la base (pg_get_functiondef)
-- con la lista cambiada: no se reescribe el cuerpo de ninguna.
--
-- ----------------------------------------------------------------------------
-- SE EJECUTA A MANO. Para ensayar: comentar el COMMIT y poner un ROLLBACK al
-- final del todo.
--
--   psql -U postgres -d crm3 -f 2026-11-21_ecommerce_mas_tipos_de_letra.sql
-- ============================================================================

BEGIN;

-- ----------------------------------------------------------------------------
-- 1. FN_ENCABEZADO_VALIDAR_CONFIG  (4 listas de letras)
-- ----------------------------------------------------------------------------
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
                             ARRAY['titulos', 'texto', 'deportiva', 'serif',
                                      'impacto', 'manuscrita', 'elegante', 'gruesa'], 'La letra de un enlace del menú'))),
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
                                       ARRAY['titulos', 'texto', 'deportiva', 'serif',
                                      'impacto', 'manuscrita', 'elegante', 'gruesa'], 'La letra del texto de la franja'),
            'destacado_color',     ecommerce.fn_validar_color(v_barra ->> 'destacado_color', 'El color del destacado de la franja'),
            'destacado_tamano',    ecommerce.fn_validar_entero(v_barra ->> 'destacado_tamano', 'El tamaño del destacado de la franja', 8, 48),
            'destacado_fuente',    ecommerce.fn_validar_opcion(v_barra ->> 'destacado_fuente',
                                       ARRAY['titulos', 'texto', 'deportiva', 'serif',
                                      'impacto', 'manuscrita', 'elegante', 'gruesa'], 'La letra del destacado de la franja'),
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
                           ARRAY['titulos', 'texto', 'deportiva', 'serif',
                                      'impacto', 'manuscrita', 'elegante', 'gruesa'], 'El tipo de letra del menú'),
        -- Y LO DE CADA ENLACE, por id, para el que tenga que destacar entre
        -- sus vecinos. Vacío = todos con lo del menú.
        'menu_enlaces', v_enlaces
    );
END;
$function$;

-- ----------------------------------------------------------------------------
-- 2. FN_FRANJA_MENSAJE  (2 listas de letras)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ecommerce.fn_franja_mensaje(p_mensaje jsonb)
 RETURNS jsonb
 LANGUAGE sql
 IMMUTABLE
AS $function$
    SELECT jsonb_build_object(
        'texto',            ecommerce.fn_validar_texto(p_mensaje ->> 'texto', 'El texto de un mensaje de la franja', 80, true),
        'texto_color',      ecommerce.fn_validar_color(p_mensaje ->> 'texto_color', 'El color de un texto de la franja'),
        'texto_tamano',     ecommerce.fn_validar_entero(p_mensaje ->> 'texto_tamano', 'El tamaño de un texto de la franja', 8, 48),
        'texto_fuente',     ecommerce.fn_validar_opcion(p_mensaje ->> 'texto_fuente',
                                ARRAY['titulos', 'texto', 'deportiva', 'serif',
                                      'impacto', 'manuscrita', 'elegante', 'gruesa'], 'La letra de un texto de la franja'),
        'destacado',        ecommerce.fn_validar_texto(p_mensaje ->> 'destacado', 'El destacado de un mensaje de la franja', 60),
        'destacado_color',  ecommerce.fn_validar_color(p_mensaje ->> 'destacado_color', 'El color de un destacado de la franja'),
        'destacado_tamano', ecommerce.fn_validar_entero(p_mensaje ->> 'destacado_tamano', 'El tamaño de un destacado de la franja', 8, 48),
        'destacado_fuente', ecommerce.fn_validar_opcion(p_mensaje ->> 'destacado_fuente',
                                ARRAY['titulos', 'texto', 'deportiva', 'serif',
                                      'impacto', 'manuscrita', 'elegante', 'gruesa'], 'La letra de un destacado de la franja'));
$function$;

-- ----------------------------------------------------------------------------
-- 3. FN_INICIO_SECCION_GUARDAR  (1 lista de letras)
-- ----------------------------------------------------------------------------
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
                               ARRAY['titulos', 'texto', 'deportiva', 'serif',
                                      'impacto', 'manuscrita', 'elegante', 'gruesa'], 'La letra del rótulo'),
           alto          = ecommerce.fn_validar_opcion(p_datos ->> 'alto',
                               ARRAY['compacta', 'normal', 'amplia', 'extra'], 'El alto de la sección'),
           -- EL ALTO DE SUS IMÁGENES, que no es el alto de la sección: aquél
           -- es el aire de alrededor y éste la franja que ocupan las fotos.
           -- Sólo lo miran los banners; 'imagen' —o nada— es lo de siempre:
           -- cada foto con el alto que traiga.
           alto_imagen   = ecommerce.fn_validar_opcion(p_datos ->> 'alto_imagen',
                               ARRAY['imagen', 'bajo', 'medio', 'alto', 'extra'], 'El alto de las imágenes'),
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
           -- LA SOMBRA DE LA TARJETA. Es una clave y no una medida, como el
           -- alto: los píxeles de cada una los pone la tienda. 'ninguna' —o
           -- nada— es lo de siempre: plana, y sólo se levanta al pasar el mouse.
           tarjeta_sombra       = ecommerce.fn_validar_opcion(p_datos ->> 'tarjeta_sombra',
                                      ARRAY['ninguna', 'suave', 'media', 'fuerte'], 'La sombra de la tarjeta'),
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

-- ----------------------------------------------------------------------------
-- 4. FN_PIE_VALIDAR_CONFIG  (1 lista de letras)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ecommerce.fn_pie_validar_config(p_config jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 IMMUTABLE
AS $function$
DECLARE
    v_barra jsonb;
    v_salida jsonb := '{}'::jsonb;
    v_redes  jsonb;
    v_lista  jsonb := '[]'::jsonb;
    v_red    jsonb;
    v_activo boolean;
    v_icono  text;
    v_nombre text;
    v_enlace text;
    v_estilo jsonb;
BEGIN
    IF p_config IS NULL OR jsonb_typeof(p_config) <> 'object' THEN
        RAISE EXCEPTION 'La configuración del pie no tiene la forma esperada' USING ERRCODE = 'P0015';
    END IF;

    -- ---------- El título de la sección de redes ----------
    IF p_config ? 'titulo_redes' THEN
        v_salida := v_salida || jsonb_build_object('titulo_redes',
            ecommerce.fn_validar_texto(p_config ->> 'titulo_redes', 'El título de las redes', 60, false));
    END IF;

    -- ---------- Cómo se pinta ese título ----------
    -- Los tres en nulo valen: «el que la tienda le dé».
    IF p_config ? 'titulo_redes_estilo' THEN
        v_estilo := COALESCE(p_config -> 'titulo_redes_estilo', '{}'::jsonb);
        IF jsonb_typeof(v_estilo) <> 'object' THEN
            RAISE EXCEPTION 'El estilo del título no tiene la forma esperada' USING ERRCODE = 'P0015';
        END IF;

        v_salida := v_salida || jsonb_build_object('titulo_redes_estilo', jsonb_build_object(
            -- Por debajo de 10 no se lee y por encima de 60 no es un título de
            -- columna, es un cartel: el pie se descuadra entero.
            'tamano', ecommerce.fn_validar_entero(v_estilo ->> 'tamano', 'El tamaño del título', 10, 60),
            'color',  ecommerce.fn_validar_color(v_estilo ->> 'color', 'El color del título'),
            -- Las tres letras que la tienda carga. Ver la cabecera.
            'fuente', ecommerce.fn_validar_opcion(v_estilo ->> 'fuente',
                          ARRAY['titulos', 'texto', 'deportiva',
                                      'impacto', 'manuscrita', 'elegante', 'gruesa'], 'La letra del título')));
    END IF;

    -- ---------- Las redes ----------
    IF p_config ? 'redes' THEN
        v_redes := COALESCE(p_config -> 'redes', '[]'::jsonb);
        IF jsonb_typeof(v_redes) <> 'array' THEN
            RAISE EXCEPTION 'Las redes sociales deben venir en una lista' USING ERRCODE = 'P0015';
        END IF;

        FOR v_red IN SELECT * FROM jsonb_array_elements(v_redes) LOOP
            -- UNA FILA APAGADA PUEDE ESTAR A MEDIAS: se guarda lo escrito y se
            -- termina otro día. Encendida, se le exige todo, porque va a salir.
            v_activo := COALESCE((v_red -> 'activo') = 'true'::jsonb, false);

            v_icono := ecommerce.fn_validar_texto(v_red ->> 'icono', 'El icono del enlace', 30, v_activo);
            IF v_icono IS NOT NULL AND v_icono !~ '^[a-z0-9_-]+$' THEN
                RAISE EXCEPTION 'El icono «%» sólo admite letras minúsculas, números y guiones', v_icono
                      USING ERRCODE = 'P0015';
            END IF;

            -- El nombre no es decoración: es lo que se lee en voz alta sobre
            -- un enlace que por pantalla es sólo un dibujo.
            v_nombre := ecommerce.fn_validar_texto(v_red ->> 'nombre', 'El nombre del enlace', 40, v_activo);

            v_enlace := ecommerce.fn_validar_enlace(v_red ->> 'enlace',
                            format('El enlace «%s»', COALESCE(v_nombre, v_icono, 'sin nombre')), v_activo);

            v_lista := v_lista || jsonb_build_array(jsonb_build_object(
                'icono',  v_icono,
                'nombre', v_nombre,
                'enlace', v_enlace,
                'activo', v_activo));
        END LOOP;

        v_salida := v_salida || jsonb_build_object('redes', v_lista);
    END IF;

    -- LOS DERECHOS RESERVADOS (y un enlace opcional a su derecha).
    -- Como todo lo demás aquí: sólo se toca si viene, para que guardar las
    -- redes no se lleve por delante lo que no se mandó.
    IF p_config ? 'barra_inferior' THEN
        v_barra := COALESCE(p_config -> 'barra_inferior', '{}'::jsonb);
        v_salida := v_salida || jsonb_build_object('barra_inferior', jsonb_build_object(
            -- {anio} lo cambia la tienda por el año que sea
            'texto',        ecommerce.fn_validar_texto(v_barra ->> 'texto', 'El texto de los derechos', 200),
            'enlace_texto', ecommerce.fn_validar_texto(v_barra ->> 'enlace_texto', 'El texto del enlace', 60),
            'enlace',       ecommerce.fn_validar_enlace(v_barra ->> 'enlace', 'El enlace de la barra'),
            'enlace_nueva_pestana', ecommerce.fn_nueva_pestana(
                ecommerce.fn_validar_enlace(v_barra ->> 'enlace', 'El enlace de la barra'),
                CASE WHEN jsonb_typeof(v_barra -> 'enlace_nueva_pestana') = 'boolean'
                     THEN (v_barra -> 'enlace_nueva_pestana')::boolean END)));
    END IF;

    RETURN v_salida;
END;
$function$;

-- ----------------------------------------------------------------------------
-- 5. Y EL CANDADO DE LA PORTADA
-- ----------------------------------------------------------------------------
-- El rótulo de una sección guarda su letra en una columna suya, con un CHECK
-- aparte: sin esto, la función admitiría la letra nueva y la tabla la
-- rechazaría al guardarla.
-- ----------------------------------------------------------------------------
ALTER TABLE ecommerce.inicio_secciones
    DROP CONSTRAINT IF EXISTS inicio_secciones_rotulo_fuente_check;

ALTER TABLE ecommerce.inicio_secciones
    ADD CONSTRAINT inicio_secciones_rotulo_fuente_check
    CHECK (rotulo_fuente IS NULL OR rotulo_fuente IN (
        'titulos', 'texto', 'deportiva', 'serif',
        'impacto', 'manuscrita', 'elegante', 'gruesa'));

COMMENT ON COLUMN ecommerce.inicio_secciones.rotulo_fuente IS
    'Letra del rótulo: titulos, texto, deportiva, serif, impacto, manuscrita, elegante o gruesa. NULL = la de los títulos.';


-- ----------------------------------------------------------------------------
-- COMPROBACIÓN
-- ----------------------------------------------------------------------------
DO $comprobar$
DECLARE
    v_falta  text[] := ARRAY[]::text[];
    v_letra  text;
    v_jsonb  jsonb;
    v_fallo  boolean;
BEGIN
    -- Las cuatro nuevas pasan por los cuatro validadores
    FOREACH v_letra IN ARRAY ARRAY['impacto', 'manuscrita', 'elegante', 'gruesa'] LOOP

        v_jsonb := ecommerce.fn_franja_mensaje(
                       jsonb_build_object('texto', 'hola', 'texto_fuente', v_letra,
                                          'destacado_fuente', v_letra));
        IF v_jsonb ->> 'texto_fuente' IS DISTINCT FROM v_letra
           OR v_jsonb ->> 'destacado_fuente' IS DISTINCT FROM v_letra THEN
            v_falta := array_append(v_falta, 'fn_franja_mensaje se come «' || v_letra || '»');
        END IF;

        -- Con frase de buscador: el validador del encabezado pide entre una y
        -- cinco, y sin ellas ni llega a mirar la letra
        v_jsonb := ecommerce.fn_encabezado_validar_config(
                       jsonb_build_object('buscador_frases', jsonb_build_array('¿Qué buscas?'),
                                          'menu_fuente', v_letra));
        IF v_jsonb ->> 'menu_fuente' IS DISTINCT FROM v_letra THEN
            v_falta := array_append(v_falta, 'fn_encabezado_validar_config se come «' || v_letra || '»');
        END IF;

        v_jsonb := ecommerce.fn_pie_validar_config(
                       jsonb_build_object('titulo_redes_estilo', jsonb_build_object('fuente', v_letra)));
        IF v_jsonb #>> '{titulo_redes_estilo,fuente}' IS DISTINCT FROM v_letra THEN
            v_falta := array_append(v_falta, 'fn_pie_validar_config se come «' || v_letra || '»');
        END IF;

        -- EL CANDADO DE LA PORTADA SE MIRA, NO SE PRUEBA CON UNA FILA: una
        -- sección necesita nombre y cuerpo, y sembrar una para borrarla deja
        -- al vecino con una portada rara mientras dura la transacción.
        IF pg_get_constraintdef((SELECT oid FROM pg_constraint
                                  WHERE conname = 'inicio_secciones_rotulo_fuente_check'))
           NOT LIKE '%' || v_letra || '%' THEN
            v_falta := array_append(v_falta, 'el CHECK de inicio_secciones no admite «' || v_letra || '»');
        END IF;

        -- Y la de la portada, que se valida al guardar la sección entera
        IF (SELECT p.prosrc FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
             WHERE n.nspname = 'ecommerce' AND p.proname = 'fn_inicio_seccion_guardar')
           NOT LIKE '%' || v_letra || '%' THEN
            v_falta := array_append(v_falta, 'fn_inicio_seccion_guardar no conoce «' || v_letra || '»');
        END IF;
    END LOOP;

    -- Las de antes siguen estando
    IF ecommerce.fn_franja_mensaje(jsonb_build_object('texto', 'hola', 'texto_fuente', 'deportiva'))
         ->> 'texto_fuente' IS DISTINCT FROM 'deportiva' THEN
        v_falta := array_append(v_falta, 'se perdió «deportiva» por el camino');
    END IF;

    -- Y una inventada se sigue rechazando: la lista está cerrada
    BEGIN
        v_fallo := false;
        PERFORM ecommerce.fn_franja_mensaje(
                    jsonb_build_object('texto', 'hola', 'texto_fuente', 'comic sans'));
        v_fallo := true;
    EXCEPTION WHEN OTHERS THEN
        NULL;
    END;
    IF v_fallo THEN
        v_falta := array_append(v_falta, 'una letra inventada entra: la lista dejó de estar cerrada');
    END IF;

    -- El pie sigue sin Georgia, que no la descarga la tienda
    BEGIN
        v_fallo := false;
        PERFORM ecommerce.fn_pie_validar_config(
                    jsonb_build_object('titulo_redes_estilo', jsonb_build_object('fuente', 'serif')));
        v_fallo := true;
    EXCEPTION WHEN OTHERS THEN
        NULL;
    END;
    IF v_fallo THEN
        v_falta := array_append(v_falta, 'el pie empezó a admitir «serif», que no se descarga');
    END IF;

    IF array_length(v_falta, 1) IS NULL THEN
        RAISE NOTICE 'Comprobado: las cuatro letras nuevas entran en la franja, el menú, el pie y la portada; «deportiva» sigue, una inventada no entra y el pie sigue sin Georgia';
    ELSE
        RAISE EXCEPTION 'FALTA: %', array_to_string(v_falta, ' | ');
    END IF;
END
$comprobar$;

COMMIT;
