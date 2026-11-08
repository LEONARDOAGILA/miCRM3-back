-- ============================================================================
-- LA FRANJA DE ABAJO DEL PIE, Y LOS DERECHOS RESERVADOS
-- ============================================================================
-- Abajo del todo del pie, debajo de las columnas, la tienda tenía DOS COSAS
-- ESCRITAS EN EL CÓDIGO que nadie podía cambiar:
--
--   · una franja con las galerías «Depósitos y transferencias» y «Tarjetas de
--     crédito», con sus títulos puestos a mano en el HTML;
--   · y, debajo, la línea de los derechos reservados, que la tienda sabía
--     pintar desde `config.barra_inferior` pero que el CRM NUNCA dejó
--     escribir: no había dónde. Por eso la línea no salía.
--
-- Con esto, las dos pasan a administrarse:
--
--   `zona` EN LAS COLUMNAS. La misma tabla, el mismo CRUD y el mismo arrastre
--   que las de arriba; lo único que cambia es en qué franja salen. Se eligió
--   así, y no una tabla nueva, porque una columna de abajo es exactamente una
--   columna: un título con sus enlaces, o un título con una imagen.
--
--   `barra_inferior` EN LA CONFIGURACIÓN. El texto («Todos los derechos
--   reservados»), y opcionalmente un enlace a la derecha. En el texto,
--   {anio} lo cambia la tienda por el año que sea: así no hay que volver cada
--   enero a corregir el pie.
--
-- LA FRANJA EMPIEZA VACÍA. Las dos galerías de pago dejan de salir y la franja
-- se monta desde el CRM; se decidió así a propósito. Las galerías y sus
-- imágenes NO se borran: siguen en «Galerías», y la columna «Para Pagos:» de
-- arriba, que ya tiene su imagen, se queda como está.
--
-- Es idempotente: la columna sólo se añade si falta y el resto son funciones.
-- ============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. EN QUÉ FRANJA VA CADA COLUMNA
-- ---------------------------------------------------------------------------
ALTER TABLE ecommerce.pie_columnas
    ADD COLUMN IF NOT EXISTS zona varchar(10) NOT NULL DEFAULT 'arriba';

DO $zona$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'pie_columnas_zona_check'
                      AND conrelid = 'ecommerce.pie_columnas'::regclass) THEN
        ALTER TABLE ecommerce.pie_columnas
            ADD CONSTRAINT pie_columnas_zona_check CHECK (zona IN ('arriba', 'abajo'));
        RAISE NOTICE 'Columna «zona» puesta: las que había se quedan arriba.';
    ELSE
        RAISE NOTICE 'La columna «zona» ya estaba.';
    END IF;
END;
$zona$;

COMMENT ON COLUMN ecommerce.pie_columnas.zona IS
    'En qué franja del pie sale: «arriba» (las de siempre) o «abajo» (la franja de debajo, encima de los derechos reservados).';

-- ---------------------------------------------------------------------------
-- 2. GUARDAR UNA COLUMNA: AHORA CON SU FRANJA
-- ---------------------------------------------------------------------------
-- `p_zona` va AL FINAL y con valor por defecto: así lo que ya llamaba a esta
-- función sin ella sigue funcionando y crea columnas arriba, como antes.
-- Cambiar la firma obliga a borrar la anterior: con CREATE OR REPLACE
-- quedarían las dos y la llamada sería ambigua.
DROP FUNCTION IF EXISTS ecommerce.fn_pie_columnas_guardar(
    bigint, character varying, boolean, character varying, character varying, boolean,
    bigint, character varying, character varying, inet, text, uuid);

CREATE OR REPLACE FUNCTION ecommerce.fn_pie_columnas_guardar(
    p_id bigint,
    p_titulo character varying,
    p_activo boolean,
    p_imagen_alt character varying DEFAULT NULL::character varying,
    p_imagen_enlace character varying DEFAULT NULL::character varying,
    p_imagen_nueva_pestana boolean DEFAULT NULL::boolean,
    p_usuario_id bigint DEFAULT NULL::bigint,
    p_usuario_login character varying DEFAULT NULL::character varying,
    p_usuario_nombre character varying DEFAULT NULL::character varying,
    p_ip_address inet DEFAULT NULL::inet,
    p_user_agent text DEFAULT NULL::text,
    p_request_id uuid DEFAULT NULL::uuid,
    p_zona text DEFAULT NULL::text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'ecommerce', 'auditoria'
AS $function$
DECLARE
    v_id     bigint := p_id;
    v_titulo text;
    v_alt    text;
    v_enlace text;
    v_zona   text;
BEGIN
    PERFORM ecommerce.fn_contexto_auditoria('ecommerce.pie_columnas',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    v_titulo := ecommerce.fn_validar_texto(p_titulo, 'El título de la columna', 60, true);
    v_alt    := ecommerce.fn_validar_texto(p_imagen_alt, 'El texto de la imagen', 120);
    -- El mismo portero que en el encabezado y el inicio: ni «javascript:» ni
    -- direcciones inventadas
    v_enlace := ecommerce.fn_validar_enlace(p_imagen_enlace, 'El enlace de la imagen');

    -- Sin decir nada, arriba: es donde estaban todas hasta el 08/11/2026
    v_zona := lower(btrim(COALESCE(p_zona, '')));
    IF v_zona = '' THEN
        v_zona := NULL;
    ELSIF v_zona NOT IN ('arriba', 'abajo') THEN
        RAISE EXCEPTION 'La columna sólo puede ir arriba o abajo' USING ERRCODE = 'P0015';
    END IF;

    IF p_id IS NULL THEN
        INSERT INTO ecommerce.pie_columnas (titulo, activo, zona, orden,
                    imagen_alt, imagen_enlace, imagen_nueva_pestana)
        VALUES (v_titulo, COALESCE(p_activo, true), COALESCE(v_zona, 'arriba'),
                -- El orden se cuenta DENTRO de su franja: las dos empiezan en 1
                (SELECT COALESCE(max(orden), 0) + 1
                   FROM ecommerce.pie_columnas
                  WHERE deleted_at IS NULL AND zona = COALESCE(v_zona, 'arriba')),
                v_alt, v_enlace, ecommerce.fn_nueva_pestana(v_enlace, p_imagen_nueva_pestana))
        RETURNING id INTO v_id;
    ELSE
        -- `imagen` NO está aquí a propósito: la pone fn_pie_columna_imagen.
        -- `zona` sólo se toca si la mandan: modificar el título de una columna
        -- no puede cambiarla de franja sin querer.
        UPDATE ecommerce.pie_columnas
           SET titulo = v_titulo,
               activo = COALESCE(p_activo, true),
               zona   = COALESCE(v_zona, zona),
               imagen_alt = v_alt,
               imagen_enlace = v_enlace,
               imagen_nueva_pestana = ecommerce.fn_nueva_pestana(v_enlace, p_imagen_nueva_pestana)
         WHERE id = p_id AND deleted_at IS NULL;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'La columna no existe' USING ERRCODE = 'P0013';
        END IF;
    END IF;

    RETURN jsonb_build_object('success', true,
        'message', CASE WHEN p_id IS NULL THEN 'Columna creada' ELSE 'Columna actualizada' END,
        'data', (ecommerce.fn_pie_obtener() -> 'data'));
END;
$function$;

-- ---------------------------------------------------------------------------
-- 3. LA CONFIGURACIÓN: LOS DERECHOS RESERVADOS
-- ---------------------------------------------------------------------------
DO $config$
DECLARE
    v_def text;
BEGIN
    SELECT pg_get_functiondef(p.oid) INTO v_def
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'ecommerce' AND p.proname = 'fn_pie_validar_config';

    IF v_def IS NULL THEN
        RAISE EXCEPTION 'No existe ecommerce.fn_pie_validar_config' USING ERRCODE = 'P0015';
    END IF;

    IF v_def LIKE '%barra_inferior%' THEN
        RAISE NOTICE 'fn_pie_validar_config ya sabía de la barra de abajo.';
        RETURN;
    END IF;

    -- Se engancha justo antes del RETURN: el validador devuelve SÓLO las
    -- claves que le llegan, y así la barra se suma a ese mismo trato
    v_def := replace(v_def,
'    RETURN v_salida;',
'    -- LOS DERECHOS RESERVADOS (y un enlace opcional a su derecha).
    -- Como todo lo demás aquí: sólo se toca si viene, para que guardar las
    -- redes no se lleve por delante lo que no se mandó.
    IF p_config ? ''barra_inferior'' THEN
        v_barra := COALESCE(p_config -> ''barra_inferior'', ''{}''::jsonb);
        v_salida := v_salida || jsonb_build_object(''barra_inferior'', jsonb_build_object(
            -- {anio} lo cambia la tienda por el año que sea
            ''texto'',        ecommerce.fn_validar_texto(v_barra ->> ''texto'', ''El texto de los derechos'', 200),
            ''enlace_texto'', ecommerce.fn_validar_texto(v_barra ->> ''enlace_texto'', ''El texto del enlace'', 60),
            ''enlace'',       ecommerce.fn_validar_enlace(v_barra ->> ''enlace'', ''El enlace de la barra''),
            ''enlace_nueva_pestana'', ecommerce.fn_nueva_pestana(
                ecommerce.fn_validar_enlace(v_barra ->> ''enlace'', ''El enlace de la barra''),
                CASE WHEN jsonb_typeof(v_barra -> ''enlace_nueva_pestana'') = ''boolean''
                     THEN (v_barra -> ''enlace_nueva_pestana'')::boolean END)));
    END IF;

    RETURN v_salida;');

    -- La variable del bloque DECLARE
    v_def := replace(v_def, 'DECLARE', 'DECLARE' || E'\n    v_barra jsonb;');

    IF v_def NOT LIKE '%barra_inferior%' OR v_def NOT LIKE '%v_barra jsonb%' THEN
        RAISE EXCEPTION 'fn_pie_validar_config no es como se esperaba: revísala a mano'
            USING ERRCODE = 'P0015';
    END IF;

    EXECUTE v_def;
    RAISE NOTICE 'fn_pie_validar_config: ya acepta la barra de los derechos.';
END;
$config$;

-- ---------------------------------------------------------------------------
-- 4. LO QUE VE EL CRM: CADA COLUMNA CON SU FRANJA
-- ---------------------------------------------------------------------------
DO $obtener$
DECLARE
    v_def text;
BEGIN
    SELECT pg_get_functiondef(p.oid) INTO v_def
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'ecommerce' AND p.proname = 'fn_pie_obtener';

    IF v_def IS NULL THEN
        RAISE EXCEPTION 'No existe ecommerce.fn_pie_obtener' USING ERRCODE = 'P0015';
    END IF;

    IF v_def LIKE '%''zona'', c.zona%' THEN
        RAISE NOTICE 'fn_pie_obtener ya devolvía la franja de cada columna.';
        RETURN;
    END IF;

    v_def := replace(v_def,
        '''id'', c.id, ''titulo'', c.titulo, ''orden'', c.orden, ''activo'', c.activo,',
        '''id'', c.id, ''titulo'', c.titulo, ''orden'', c.orden, ''activo'', c.activo,
                           ''zona'', c.zona,');

    IF v_def NOT LIKE '%''zona'', c.zona%' THEN
        RAISE EXCEPTION 'La lista de columnas de fn_pie_obtener no es la esperada: revísala a mano'
            USING ERRCODE = 'P0015';
    END IF;

    EXECUTE v_def;
    RAISE NOTICE 'fn_pie_obtener: cada columna dice en qué franja va.';
END;
$obtener$;

-- ---------------------------------------------------------------------------
-- 5. LO QUE VE LA TIENDA
-- ---------------------------------------------------------------------------
-- `grupos` se queda con las de arriba, para no cambiarle el significado a lo
-- que ya existe, y la franja nueva llega en `grupos_abajo`. La tienda ignora
-- las claves que no conoce, así que esto no rompe una versión vieja.
CREATE OR REPLACE FUNCTION ecommerce.fn_secciones_publicas()
RETURNS jsonb
LANGUAGE sql
STABLE SECURITY DEFINER
AS $function$
    WITH menu AS (
        SELECT p.id, p.texto, p.enlace, p.icono, p.nueva_pestana, p.orden,
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

-- ---------------------------------------------------------------------------
-- COMPROBACIÓN
-- ---------------------------------------------------------------------------
DO $comprobar$
DECLARE
    v_arriba integer;
    v_abajo  integer;
    v_salida jsonb;
    v_id     bigint;
BEGIN
    -- Las que había siguen arriba y nadie se ha movido
    SELECT count(*) FILTER (WHERE zona = 'arriba'), count(*) FILTER (WHERE zona = 'abajo')
      INTO v_arriba, v_abajo
      FROM ecommerce.pie_columnas WHERE deleted_at IS NULL;

    IF v_abajo <> 0 THEN
        RAISE NOTICE 'OJO: ya había % columna(s) abajo.', v_abajo;
    END IF;

    v_salida := ecommerce.fn_secciones_publicas();
    IF jsonb_array_length(v_salida -> 1 -> 'grupos') <> (
        SELECT count(*) FROM ecommerce.pie_columnas
         WHERE deleted_at IS NULL AND activo AND zona = 'arriba') THEN
        RAISE EXCEPTION 'La tienda no está sacando las columnas de arriba que toca' USING ERRCODE = 'P0015';
    END IF;
    IF NOT (v_salida -> 1 ? 'grupos_abajo') THEN
        RAISE EXCEPTION 'Falta «grupos_abajo» en lo que ve la tienda' USING ERRCODE = 'P0015';
    END IF;
    IF NOT (v_salida -> 1 -> 'config' ? 'barra_inferior') THEN
        RAISE EXCEPTION 'Falta «barra_inferior» en lo que ve la tienda' USING ERRCODE = 'P0015';
    END IF;

    -- Crear una columna abajo y borrarla: que el camino entero funcione.
    -- Se deshace con el mismo truco de siempre, sin dejar rastro.
    BEGIN
        PERFORM ecommerce.fn_pie_columnas_guardar(
            NULL, 'Prueba de la franja', true, NULL, NULL, NULL,
            NULL, NULL, NULL, NULL, NULL, NULL, 'abajo');

        SELECT id INTO v_id FROM ecommerce.pie_columnas
         WHERE titulo = 'Prueba de la franja' AND deleted_at IS NULL;

        IF v_id IS NULL THEN
            RAISE EXCEPTION 'No se creó la columna de abajo' USING ERRCODE = 'P0015';
        END IF;

        v_salida := ecommerce.fn_secciones_publicas();
        IF jsonb_array_length(v_salida -> 1 -> 'grupos_abajo') <> v_abajo + 1 THEN
            RAISE EXCEPTION 'La columna nueva no sale en la franja de abajo' USING ERRCODE = 'P0015';
        END IF;
        IF jsonb_array_length(v_salida -> 1 -> 'grupos') <> (
            SELECT count(*) FROM ecommerce.pie_columnas
             WHERE deleted_at IS NULL AND activo AND zona = 'arriba' AND id <> v_id) THEN
            RAISE EXCEPTION 'La columna nueva se coló entre las de arriba' USING ERRCODE = 'P0015';
        END IF;

        RAISE EXCEPTION 'deshacer la prueba' USING ERRCODE = 'P0100';
    EXCEPTION WHEN sqlstate 'P0100' THEN
        NULL;   -- la columna de prueba queda deshecha
    END;

    RAISE NOTICE 'Comprobado: % columna(s) siguen arriba, la franja de abajo funciona y la tienda recibe los derechos.', v_arriba;
END;
$comprobar$;

COMMIT;
