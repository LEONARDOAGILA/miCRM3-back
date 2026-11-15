-- ============================================================================
-- UN ENLACE DEL MENÚ PUEDE IR DESTACADO, Y SE VA EL AVISO DE CRÉDITO
-- ============================================================================
-- El encabezado tenía un bloque aparte —«ACTIVA TU CRÉDITO DIRECTO» con su
-- botón «APLICA AQUÍ»— pegado a la derecha de la barra roja. Era de cuando el
-- menú no se podía administrar: hoy se añaden los enlaces que haga falta, así
-- que ese bloque es un segundo sitio donde poner lo mismo, con sus propios
-- campos, su propia validación y su propio hueco en la barra.
--
-- SE CAMBIA POR UNA PALANCA EN EL ENLACE: «destacado». Un enlace principal
-- destacado sale como píldora blanca al final de la barra, que es exactamente
-- lo que se veía antes, pero administrado donde se administra todo lo demás.
--
-- SÓLO LOS PRINCIPALES. Dentro de un desplegable no hay barra donde poner una
-- píldora, y un principal que abre desplegable no lleva a ningún sitio: la
-- función lo apaga sola en los dos casos en vez de fiarse de la pantalla.
--
-- Lo que había escrito en el aviso NO SE MIGRA a un enlace: son dos textos y
-- una dirección que alguien tiene que decidir dónde quiere, y adivinarlo sería
-- dejarle un enlace en el menú que no pidió. Se borra del config.
-- ============================================================================

BEGIN;

-- ---------- La columna ----------
ALTER TABLE ecommerce.encabezado_enlaces
    ADD COLUMN IF NOT EXISTS destacado boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN ecommerce.encabezado_enlaces.destacado IS
    'Sale como píldora blanca al final de la barra roja. Sólo los principales sin desplegable.';

-- ---------- El aviso de crédito se va del config ----------
UPDATE ecommerce.encabezado
   SET config = config - 'credito'
 WHERE config ? 'credito';

-- ---------- La función de guardar cambia de forma ----------
-- Se borra la vieja a propósito: dejarla sería tener dos maneras de guardar un
-- enlace y una de ellas apagaría el destacado sin decirlo.
DROP FUNCTION IF EXISTS ecommerce.fn_encabezado_enlaces_guardar(
    bigint, bigint, character varying, character varying, character varying,
    boolean, boolean, bigint, character varying, character varying, inet, text, uuid);

-- ---------- Guardar un enlace, ahora con su destacado ----------
CREATE OR REPLACE FUNCTION ecommerce.fn_encabezado_enlaces_guardar(p_id bigint, p_padre_id bigint, p_texto character varying, p_enlace character varying, p_icono character varying, p_activo boolean, p_nueva_pestana boolean, p_destacado boolean, p_usuario_id bigint DEFAULT NULL::bigint, p_usuario_login character varying DEFAULT NULL::character varying, p_usuario_nombre character varying DEFAULT NULL::character varying, p_ip_address inet DEFAULT NULL::inet, p_user_agent text DEFAULT NULL::text, p_request_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'ecommerce', 'auditoria'
AS $function$
DECLARE
    v_id     bigint := p_id;
    v_texto  text;
    v_enlace text;
    v_icono  text;
    v_padre  bigint := p_padre_id;
    v_nuevo  boolean := p_id IS NULL;
    v_destacado boolean;
BEGIN
    PERFORM ecommerce.fn_contexto_auditoria('ecommerce.encabezado_enlaces',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    v_texto  := ecommerce.fn_validar_texto(p_texto, 'El texto del enlace', 60, true);
    v_enlace := ecommerce.fn_validar_enlace(p_enlace, 'El enlace');
    v_icono  := ecommerce.fn_validar_texto(p_icono, 'El icono', 40);

    IF v_icono IS NOT NULL AND v_icono !~ '^[a-z0-9-]+$' THEN
        RAISE EXCEPTION 'El icono sólo admite letras minúsculas, números y guiones' USING ERRCODE = 'P0015';
    END IF;

    IF NOT v_nuevo THEN
        -- El padre no se cambia al modificar: mover un enlace de sitio es
        -- arrastrarlo, y mezclarlo aquí dejaría dos caminos para lo mismo.
        SELECT padre_id INTO v_padre FROM ecommerce.encabezado_enlaces
         WHERE id = p_id AND deleted_at IS NULL;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'El enlace no existe' USING ERRCODE = 'P0013';
        END IF;
    END IF;

    -- DESTACADO ES SÓLO DE LOS PRINCIPALES: es una píldora al final de la
    -- barra roja, y dentro de un desplegable no hay barra donde ponerla.
    v_destacado := COALESCE(p_destacado, false) AND v_padre IS NULL;

    IF v_padre IS NOT NULL THEN
        -- Dos niveles como mucho: el padre tiene que ser un principal
        IF NOT EXISTS (SELECT 1 FROM ecommerce.encabezado_enlaces
                        WHERE id = v_padre AND padre_id IS NULL AND deleted_at IS NULL) THEN
            RAISE EXCEPTION 'El enlace del que debería colgar no existe o ya es un desplegable' USING ERRCODE = 'P0016';
        END IF;
        -- Un hijo SIN dirección no lleva a ninguna parte: el principal puede
        -- no tenerla (sólo despliega), el hijo no.
        IF v_enlace IS NULL THEN
            RAISE EXCEPTION 'Un enlace del desplegable necesita su dirección' USING ERRCODE = 'P0001';
        END IF;
    END IF;

    IF v_nuevo THEN
        INSERT INTO ecommerce.encabezado_enlaces
               (padre_id, texto, enlace, icono, activo, nueva_pestana, destacado, orden)
        VALUES (v_padre, v_texto, v_enlace, v_icono,
                COALESCE(p_activo, true),
                ecommerce.fn_nueva_pestana(v_enlace, p_nueva_pestana),
                v_destacado,
                (SELECT COALESCE(max(orden), 0) + 1 FROM ecommerce.encabezado_enlaces
                  WHERE padre_id IS NOT DISTINCT FROM v_padre AND deleted_at IS NULL))
        RETURNING id INTO v_id;
    ELSE
        UPDATE ecommerce.encabezado_enlaces
           SET texto = v_texto, enlace = v_enlace, icono = v_icono,
               activo = COALESCE(p_activo, true),
               nueva_pestana = ecommerce.fn_nueva_pestana(v_enlace, p_nueva_pestana),
               destacado = v_destacado
         WHERE id = v_id;
    END IF;

    RETURN jsonb_build_object('success', true,
        'message', CASE WHEN v_nuevo THEN 'Enlace creado' ELSE 'Enlace actualizado' END,
        'data', (ecommerce.fn_encabezado_obtener() -> 'data'));
END;
$function$;

-- ---------- Lo que ve la pantalla del CRM ----------
CREATE OR REPLACE FUNCTION ecommerce.fn_encabezado_enlaces_json()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
AS $function$
    -- El árbol completo, apagados incluidos: esto es la pantalla de
    -- administración, no la tienda. Lo de ocultar pasa en fn_secciones_publicas.
    SELECT COALESCE(jsonb_agg(x ORDER BY (x ->> 'orden')::int, (x ->> 'id')::bigint), '[]'::jsonb)
      FROM (
        SELECT jsonb_build_object(
                   'id',            p.id,
                   'texto',         p.texto,
                   'enlace',        p.enlace,
                   'icono',         p.icono,
                   'nueva_pestana', p.nueva_pestana,
                   'orden',         p.orden,
                   'activo',        p.activo,
                   -- Sólo los principales pueden ir destacados: dentro de un
                   -- desplegable no hay barra donde poner una píldora
                   'destacado',     p.destacado,
                   'hijos', COALESCE((
                       SELECT jsonb_agg(jsonb_build_object(
                                  'id',            h.id,
                                  'texto',         h.texto,
                                  'enlace',        h.enlace,
                                  'icono',         h.icono,
                                  'nueva_pestana', h.nueva_pestana,
                                  'orden',         h.orden,
                                  'activo',        h.activo)
                              ORDER BY h.orden, h.id)
                         FROM ecommerce.encabezado_enlaces h
                        WHERE h.padre_id = p.id AND h.deleted_at IS NULL), '[]'::jsonb)
               ) AS x
          FROM ecommerce.encabezado_enlaces p
         WHERE p.padre_id IS NULL AND p.deleted_at IS NULL
      ) t;
$function$;

-- ---------- Lo que ve la tienda ----------
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

-- ---------- La configuración del encabezado, sin el aviso ----------
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
        'color_principal', ecommerce.fn_validar_color(p_config ->> 'color_principal', 'El color de la tienda')
    );
END;
$function$;

COMMIT;


-- ============================================================================
-- COMPROBACIÓN — no escribe nada
-- ============================================================================
DO $comprobar$
DECLARE
    v_falta    text[] := '{}';
    v_config   jsonb;
    v_crm      jsonb;
    v_publico  jsonb;
    v_uno      jsonb;
BEGIN
    -- ---------- La columna ----------
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                    WHERE table_schema = 'ecommerce' AND table_name = 'encabezado_enlaces'
                      AND column_name = 'destacado') THEN
        v_falta := array_append(v_falta, 'no está la columna destacado');
    END IF;

    -- ---------- El aviso, fuera ----------
    SELECT config INTO v_config FROM ecommerce.encabezado WHERE id = 1;
    IF v_config ? 'credito' THEN
        v_falta := array_append(v_falta, 'el aviso de crédito sigue en el config');
    END IF;
    IF ecommerce.fn_encabezado_validar_config(v_config) ? 'credito' THEN
        v_falta := array_append(v_falta, 'la validación vuelve a meter el aviso de crédito');
    END IF;
    -- Y lo que sí tiene que seguir estando
    IF NOT (ecommerce.fn_encabezado_validar_config(v_config) ? 'barra_superior'
            AND ecommerce.fn_encabezado_validar_config(v_config) ? 'buscador_frases') THEN
        v_falta := array_append(v_falta, 'la validación se llevó por delante algo más');
    END IF;

    -- ---------- El CRM lo ve ----------
    v_crm := ecommerce.fn_encabezado_enlaces_json();
    IF jsonb_array_length(v_crm) > 0 THEN
        v_uno := v_crm -> 0;
        IF NOT (v_uno ? 'destacado') THEN
            v_falta := array_append(v_falta, 'el JSON del CRM no trae destacado');
        END IF;
        IF jsonb_array_length(v_uno -> 'hijos') > 0 AND (v_uno -> 'hijos' -> 0) ? 'destacado' THEN
            v_falta := array_append(v_falta, 'un hijo no debería traer destacado');
        END IF;
    END IF;

    -- ---------- Y la tienda ----------
    v_publico := ecommerce.fn_secciones_publicas() -> 0 -> 'menu';
    IF jsonb_array_length(v_publico) > 0 AND NOT ((v_publico -> 0) ? 'destacado') THEN
        v_falta := array_append(v_falta, 'el menú público no trae destacado');
    END IF;
    IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_publico) e
                WHERE (e ->> 'destacado')::boolean AND jsonb_array_length(e -> 'hijos') > 0) THEN
        v_falta := array_append(v_falta, 'un desplegable salió destacado');
    END IF;

    IF array_length(v_falta, 1) > 0 THEN
        RAISE EXCEPTION 'El enlace destacado no quedó bien: %', array_to_string(v_falta, '; ');
    END IF;

    RAISE NOTICE 'Enlace destacado listo: % enlaces principales, % destacados; el aviso de crédito ya no está',
                 jsonb_array_length(v_crm),
                 (SELECT count(*) FROM ecommerce.encabezado_enlaces
                   WHERE destacado AND deleted_at IS NULL);
END;
$comprobar$;
