-- ============================================================================
-- EL LOGO DEL ENCABEZADO Y LOS COLORES DE SUS DOS FRANJAS
-- ============================================================================
-- Dos cosas que hasta ahora no se podían cambiar sin tocar código:
--
-- EL LOGO. Estaba dibujado dentro de la tienda (app-brand-logo). Ahora se
-- sube desde el CRM y se guarda como cualquier otra imagen del ecommerce: el
-- NOMBRE del fichero en la base, la dirección la arma el controlador. Sin
-- logo subido, la tienda sigue pintando el suyo, así que no hay manera de
-- dejar la tienda sin marca.
--
-- VA EN UNA COLUMNA Y NO EN EL `config`: el config lo reescribe entero
-- `fn_encabezado_validar_config` cada vez que se guarda la pantalla, así que
-- un logo metido ahí se borraría al cambiar cualquier otra cosa. En su
-- columna, cada uno se guarda por su puerta.
--
-- LOS COLORES. La franja de arriba y la fila del logo tienen ahora su fondo y
-- su letra, como ya los tenían los desplegables. NULL = los de siempre.
-- ============================================================================

BEGIN;

-- ---------- El logo ----------
ALTER TABLE ecommerce.encabezado
    ADD COLUMN IF NOT EXISTS logo character varying(200);

COMMENT ON COLUMN ecommerce.encabezado.logo IS
    'Fichero del logo subido desde el CRM (img/ecommerce). NULL = el que trae dibujado la tienda.';

-- Lo pone y lo quita su propia puerta, y devuelve el anterior para que el
-- controlador borre el fichero que deja de usarse (igual que con la imagen de
-- una sección).
CREATE OR REPLACE FUNCTION ecommerce.fn_encabezado_logo(
    p_archivo        text,
    p_usuario_id     bigint      DEFAULT NULL,
    p_usuario_login  character varying DEFAULT NULL,
    p_usuario_nombre character varying DEFAULT NULL,
    p_ip_address     inet        DEFAULT NULL,
    p_user_agent     text        DEFAULT NULL,
    p_request_id     uuid        DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'ecommerce', 'auditoria'
AS $function$
DECLARE
    v_anterior text;
BEGIN
    PERFORM ecommerce.fn_contexto_auditoria('ecommerce.encabezado',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    SELECT logo INTO v_anterior FROM ecommerce.encabezado WHERE id = 1;

    UPDATE ecommerce.encabezado
       SET logo = nullif(btrim(COALESCE(p_archivo, '')), '')
     WHERE id = 1;

    RETURN jsonb_build_object(
        'success', true,
        'message', CASE WHEN p_archivo IS NULL THEN 'Logo quitado' ELSE 'Logo actualizado' END,
        'anterior', v_anterior,
        'data', (ecommerce.fn_encabezado_obtener() -> 'data'));
END;
$function$;

COMMENT ON FUNCTION ecommerce.fn_encabezado_logo(text, bigint, character varying, character varying, inet, text, uuid) IS
    'Pone o quita el logo del encabezado y devuelve el fichero anterior, para que el controlador lo borre del disco.';

-- ---------- La configuración, con los cuatro colores ----------
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
        'encabezado_fondo',  ecommerce.fn_validar_color(p_config ->> 'encabezado_fondo', 'El fondo del encabezado'),
        'encabezado_texto',  ecommerce.fn_validar_color(p_config ->> 'encabezado_texto', 'La letra del encabezado')
    );
END;
$function$;

-- ---------- Lo que ve el CRM ----------
CREATE OR REPLACE FUNCTION ecommerce.fn_encabezado_obtener()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
AS $function$
    SELECT jsonb_build_object('success', true, 'message', 'Encabezado',
        'data', jsonb_build_object(
            'config',  e.config,
            -- El fichero del logo, o NULL para el de la casa. La dirección la
            -- arma el controlador, como con el resto de imágenes del ecommerce
            'logo',    e.logo,
            'enlaces', ecommerce.fn_encabezado_enlaces_json(),
            'updated_at', to_char(e.updated_at, 'YYYY-MM-DD HH24:MI:SS'),
            'updated_by', e.updated_by))
      FROM ecommerce.encabezado e WHERE e.id = 1;
$function$;

-- ---------- Y lo que ve la tienda ----------
CREATE OR REPLACE FUNCTION ecommerce.fn_secciones_publicas()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
AS $function$
    WITH menu AS (
        SELECT p.id, p.texto, p.enlace, p.icono, p.nueva_pestana, p.orden, p.destacado,
               COALESCE((
                   SELECT jsonb_agg(jsonb_build_object(
                              'texto', h.texto, 'enlace', h.enlace, 'icono', h.icono,
                              'nueva_pestana', h.nueva_pestana)
                          ORDER BY h.orden, h.id)
                     FROM ecommerce.encabezado_enlaces h
                    WHERE h.padre_id = p.id AND h.activo AND h.deleted_at IS NULL
                      -- Un hijo que lleva a una página oculta no se enseña
                      AND ecommerce.fn_enlace_a_pagina_visible(h.enlace)), '[]'::jsonb) AS hijos
          FROM ecommerce.encabezado_enlaces p
         WHERE p.padre_id IS NULL AND p.activo AND p.deleted_at IS NULL
    ),
    -- Una columna del pie, montada una sola vez y usada por las dos franjas
    columnas AS (
        SELECT c.zona, c.orden, c.id,
               jsonb_build_object(
                   'titulo', c.titulo,
                   'imagen', CASE WHEN nullif(btrim(COALESCE(c.imagen, '')), '') IS NOT NULL
                                  THEN jsonb_build_object(
                                      'archivo',       c.imagen,
                                      'alt',           c.imagen_alt,
                                      'enlace',        c.imagen_enlace,
                                      'nueva_pestana', c.imagen_nueva_pestana)
                             END,
                   'items', COALESCE((
                       SELECT jsonb_agg(jsonb_build_object(
                                  'texto', l.texto, 'enlace', l.enlace,
                                  'icono', l.icono, 'nueva_pestana', l.nueva_pestana)
                              ORDER BY l.orden, l.id)
                         FROM ecommerce.pie_enlaces l
                        WHERE l.columna_id = c.id AND l.activo AND l.deleted_at IS NULL
                          AND ecommerce.fn_enlace_a_pagina_visible(l.enlace)), '[]'::jsonb)) AS grupo
          FROM ecommerce.pie_columnas c
         WHERE c.activo AND c.deleted_at IS NULL
    )
    SELECT jsonb_build_array(
        jsonb_build_object(
            'clave', 'header', 'tipo', 'header', 'ubicacion', 'arriba', 'orden', 1, 'titulo', 'Header',
            'config', (SELECT config FROM ecommerce.encabezado WHERE id = 1),
            -- El logo que se subió en el CRM; sin él, la tienda pinta el suyo
            'logo', (SELECT logo FROM ecommerce.encabezado WHERE id = 1),
            'menu', COALESCE((
                SELECT jsonb_agg(jsonb_build_object(
                           'texto', m.texto,
                           -- Con desplegables, el principal no lleva enlace
                           'enlace', CASE WHEN m.hijos = '[]'::jsonb THEN m.enlace END,
                           'icono', m.icono,
                           'nueva_pestana', CASE WHEN m.hijos = '[]'::jsonb THEN m.nueva_pestana ELSE false END,
                           -- Un desplegable no puede ser una píldora: se abre, no lleva a ningún sitio
                           'destacado', m.destacado AND m.hijos = '[]'::jsonb,
                           'hijos', m.hijos)
                       ORDER BY m.orden, m.id)
                  FROM menu m
                 -- Con hijos se queda (su enlace ni se usa); sin hijos, sólo si
                 -- lleva a alguna parte que se pueda ver
                 WHERE m.hijos <> '[]'::jsonb
                    OR (m.enlace IS NOT NULL AND ecommerce.fn_enlace_a_pagina_visible(m.enlace))), '[]'::jsonb),
            'grupos', '[]'::jsonb),
        jsonb_build_object(
            'clave', 'footer', 'tipo', 'footer', 'ubicacion', 'abajo', 'orden', 1, 'titulo', 'Footer',
            'config', jsonb_build_object(
                'titulo_redes', (SELECT config ->> 'titulo_redes' FROM ecommerce.pie WHERE id = 1),
                'titulo_redes_estilo', (SELECT COALESCE(config -> 'titulo_redes_estilo', '{}'::jsonb)
                                          FROM ecommerce.pie WHERE id = 1),
                -- Los derechos reservados, de la configuración del pie
                'barra_inferior', (SELECT COALESCE(config -> 'barra_inferior', '{}'::jsonb)
                                     FROM ecommerce.pie WHERE id = 1),
                'redes', COALESCE((
                    SELECT jsonb_agg(jsonb_build_object(
                               'icono',  r ->> 'icono',
                               'nombre', r ->> 'nombre',
                               'enlace', r ->> 'enlace'))
                      FROM ecommerce.pie p, jsonb_array_elements(COALESCE(p.config -> 'redes', '[]'::jsonb)) r
                     WHERE p.id = 1 AND (r -> 'activo') = 'true'::jsonb), '[]'::jsonb)),
            'menu', '[]'::jsonb,
            'grupos', COALESCE((SELECT jsonb_agg(c.grupo ORDER BY c.orden, c.id)
                                  FROM columnas c WHERE c.zona = 'arriba'), '[]'::jsonb),
            'grupos_abajo', COALESCE((SELECT jsonb_agg(c.grupo ORDER BY c.orden, c.id)
                                        FROM columnas c WHERE c.zona = 'abajo'), '[]'::jsonb))
    );
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
    v_header jsonb;
BEGIN
    -- ---------- La columna ----------
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                    WHERE table_schema = 'ecommerce' AND table_name = 'encabezado'
                      AND column_name = 'logo') THEN
        v_falta := array_append(v_falta, 'no está la columna del logo');
    END IF;

    -- ---------- Los cuatro colores ----------
    SELECT config INTO v_config FROM ecommerce.encabezado WHERE id = 1;
    v_salida := ecommerce.fn_encabezado_validar_config(v_config);

    IF NOT (v_salida ? 'franja_fondo' AND v_salida ? 'franja_texto'
            AND v_salida ? 'encabezado_fondo' AND v_salida ? 'encabezado_texto') THEN
        v_falta := array_append(v_falta, 'faltan los colores de las dos franjas');
    END IF;
    IF NOT (v_salida ? 'barra_superior' AND v_salida ? 'color_principal'
            AND v_salida ? 'desplegable_fondo') THEN
        v_falta := array_append(v_falta, 'la validación se llevó algo por delante');
    END IF;
    IF ecommerce.fn_encabezado_validar_config(
           v_config || '{"franja_fondo":"#101010"}'::jsonb) ->> 'franja_fondo' IS DISTINCT FROM '#101010' THEN
        v_falta := array_append(v_falta, 'un color bueno no se guardó');
    END IF;

    -- ---------- El logo viaja a los dos lados ----------
    IF NOT ((ecommerce.fn_encabezado_obtener() -> 'data') ? 'logo') THEN
        v_falta := array_append(v_falta, 'el CRM no recibe el logo');
    END IF;

    v_header := ecommerce.fn_secciones_publicas() -> 0;
    IF NOT (v_header ? 'logo') THEN
        v_falta := array_append(v_falta, 'la tienda no recibe el logo');
    END IF;
    IF (v_header ->> 'clave') IS DISTINCT FROM 'header' THEN
        v_falta := array_append(v_falta, 'la primera sección pública ya no es el encabezado');
    END IF;

    IF array_length(v_falta, 1) > 0 THEN
        RAISE EXCEPTION 'El logo y los colores no quedaron bien: %', array_to_string(v_falta, '; ');
    END IF;

    RAISE NOTICE 'Encabezado: logo propio %, colores de franja % / %',
                 COALESCE((SELECT logo FROM ecommerce.encabezado WHERE id = 1), '(el de la tienda)'),
                 COALESCE(v_salida ->> 'franja_fondo', 'de siempre'),
                 COALESCE(v_salida ->> 'franja_texto', 'de siempre');
END;
$comprobar$;
