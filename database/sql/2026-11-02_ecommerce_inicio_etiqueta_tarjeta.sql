-- ============================================================================
-- ECOMMERCE · LA ETIQUETA DE LA TARJETA, ENCIMA DEL DESCUENTO
-- ============================================================================
-- Fecha: 2026-11-02
--
-- Una pastilla más en la esquina de la tarjeta, encima del «-12%»: la pone
-- quien arma la sección y dice lo que quiera —«NUEVO», «LIQUIDACIÓN», «ÚLTIMAS
-- UNIDADES»—. Se configura igual que el cartel de descuento: su fondo y su
-- letra, en el mismo sitio y con la misma paleta.
--
-- PERO LLEVA UNA COSA MÁS QUE EL DESCUENTO: el TEXTO. El del descuento lo
-- calcula la tienda de los dos precios; éste no sale de ningún dato, así que
-- hay que escribirlo. Por eso van tres columnas y no dos:
--
--     etiqueta         lo que se lee          (hasta 30 caracteres)
--     etiqueta_color   el fondo de la pastilla
--     etiqueta_texto   el color de su letra
--
-- El par `_color` / `_texto` es el mismo convenio que los botones y el
-- descuento: `_color` es SIEMPRE el fondo y `_texto` SIEMPRE el color de la
-- letra. `etiqueta` a secas son las palabras.
--
-- SIN TEXTO NO HAY ETIQUETA, y eso se resuelve aquí: `fn_tarjeta_colores`
-- devuelve `rotulo` en null y la tienda no pinta nada. Si la regla viviera
-- allí, un color elegido sin texto dejaría una pastilla vacía en la esquina de
-- cada tarjeta.
--
-- LA ETIQUETA ES DE LA SECCIÓN, NO DEL PRODUCTO: sale igual en todas sus
-- tarjetas. Es lo que se pidió, y es lo que la hace útil para una campaña
-- entera; una etiqueta por producto sería otra cosa y viviría en el catálogo.
--
-- Idempotente.
-- ============================================================================
\set ON_ERROR_STOP on

BEGIN;

-- ----------------------------------------------------------------------------
-- 1. LAS COLUMNAS
-- ----------------------------------------------------------------------------
ALTER TABLE ecommerce.inicio_secciones
    ADD COLUMN IF NOT EXISTS etiqueta        varchar(30),
    ADD COLUMN IF NOT EXISTS etiqueta_color  varchar(7),
    ADD COLUMN IF NOT EXISTS etiqueta_texto  varchar(7);

DO $reglas$
DECLARE
    c text;
BEGIN
    FOREACH c IN ARRAY ARRAY['etiqueta_color', 'etiqueta_texto'] LOOP
        IF NOT EXISTS (SELECT 1 FROM pg_constraint
                        WHERE conname = 'ck_inicio_secciones_' || c) THEN
            EXECUTE format(
                'ALTER TABLE ecommerce.inicio_secciones ADD CONSTRAINT %I CHECK (%I IS NULL OR %I ~ ''^#[0-9a-f]{6}$'')',
                'ck_inicio_secciones_' || c, c, c);
        END IF;
    END LOOP;
END
$reglas$;

-- ----------------------------------------------------------------------------
-- 2. LOS COLORES DE LA TARJETA, CON LA ETIQUETA DENTRO
-- ----------------------------------------------------------------------------
-- La de cuatro argumentos se borra: con las dos puestas, una llamada vieja
-- seguiría compilando y devolvería una tarjeta sin etiqueta sin decir nada.
DROP FUNCTION IF EXISTS ecommerce.fn_tarjeta_colores(text, text, text, text);

CREATE OR REPLACE FUNCTION ecommerce.fn_tarjeta_colores(
    p_fondo           text,
    p_borde           text,
    p_descuento       text,
    p_descuento_texto text,
    p_etiqueta        text,
    p_etiqueta_color  text,
    p_etiqueta_texto  text)
 RETURNS jsonb
 LANGUAGE sql
 IMMUTABLE PARALLEL SAFE
AS $function$
    -- Los nulos se quedan nulos, como en fn_botones_colores: null en `fondo`
    -- es «el de la tienda» y null en el `texto` de un cartel es «el que se lea
    -- encima», que lo calcula la tienda. Resolverlos aquí obligaría a esta
    -- función a conocer la hoja de estilos de la tienda.
    SELECT jsonb_build_object(
        'fondo',     nullif(btrim(COALESCE(p_fondo, '')), ''),
        'borde',     nullif(btrim(COALESCE(p_borde, '')), ''),
        'descuento', jsonb_build_object(
                         'fondo', nullif(btrim(COALESCE(p_descuento, '')), ''),
                         'texto', nullif(btrim(COALESCE(p_descuento_texto, '')), '')),
        -- `rotulo` son las palabras; `fondo` y `texto`, los dos colores. SIN
        -- PALABRAS NO HAY ETIQUETA: la tienda mira `rotulo` y, en null, no
        -- pinta nada. Así un color elegido y un texto que se borró después no
        -- dejan una pastilla vacía en cada tarjeta.
        'etiqueta',  jsonb_build_object(
                         'rotulo', nullif(btrim(COALESCE(p_etiqueta, '')), ''),
                         'fondo',  nullif(btrim(COALESCE(p_etiqueta_color, '')), ''),
                         'texto',  nullif(btrim(COALESCE(p_etiqueta_texto, '')), '')));
$function$;

COMMENT ON FUNCTION ecommerce.fn_tarjeta_colores(text, text, text, text, text, text, text) IS
    'Los colores de la TARJETA DEL PRODUCTO (fondo, borde, cartel de descuento y etiqueta), como los manda el CRM. Los botones van aparte, en fn_botones_colores.';

-- ----------------------------------------------------------------------------
-- 3. GUARDAR
-- ----------------------------------------------------------------------------
DO $guardar$
DECLARE
    def   text;
    ancla text := E'           descuento_texto      = ecommerce.fn_validar_color(p_datos ->> ''descuento_texto'',\n                                      ''La letra del cartel de descuento''),';
BEGIN
    SELECT pg_get_functiondef(p.oid) INTO def
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'ecommerce' AND p.proname = 'fn_inicio_seccion_guardar';

    IF def IS NULL THEN
        RAISE EXCEPTION 'No está ecommerce.fn_inicio_seccion_guardar';
    END IF;

    IF strpos(def, 'etiqueta_color') > 0 THEN
        RAISE NOTICE 'Guardar ya aceptaba la etiqueta: no lo toco.';
        RETURN;
    END IF;

    IF strpos(def, ancla) = 0 THEN
        RAISE EXCEPTION 'No encontré dónde añadir la etiqueta: ¿cambió fn_inicio_seccion_guardar?';
    END IF;

    -- El texto pasa por fn_validar_texto, el mismo del rótulo: recorta los
    -- espacios de los lados y se queja si pasa de 30
    def := replace(def, ancla, ancla
        || E'\n           -- La etiqueta de encima del descuento: sus palabras y sus dos colores'
        || E'\n           etiqueta             = ecommerce.fn_validar_texto(p_datos ->> ''etiqueta'','
        || E'\n                                      ''La etiqueta de la tarjeta'', 30),'
        || E'\n           etiqueta_color       = ecommerce.fn_validar_color(p_datos ->> ''etiqueta_color'','
        || E'\n                                      ''El color de la etiqueta''),'
        || E'\n           etiqueta_texto       = ecommerce.fn_validar_color(p_datos ->> ''etiqueta_texto'','
        || E'\n                                      ''La letra de la etiqueta''),');

    EXECUTE def;
    RAISE NOTICE 'Guardar ya acepta la etiqueta y sus dos colores.';
END
$guardar$;

-- ----------------------------------------------------------------------------
-- 4. EL LISTADO DEL CRM Y LA PORTADA PÚBLICA
-- ----------------------------------------------------------------------------
-- Las dos llaman a fn_tarjeta_colores, que ahora pide tres argumentos más. Van
-- en el mismo bloque para que no pueda quedar una al día y la otra no: con
-- siete argumentos en una y cuatro en la otra, la segunda ni siquiera
-- encontraría función que llamar.
DO $llamadas$
DECLARE
    def    text;
    ancla1 text := E'                                           s.descuento_color,     s.descuento_texto),';
    ancla2 text := E'                                            s.descuento_color,     s.descuento_texto) AS tarjeta,';
    v_hecho boolean := true;
BEGIN
    -- El listado del CRM
    SELECT pg_get_functiondef(p.oid) INTO def
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'ecommerce' AND p.proname = 'fn_inicio_listar';

    IF def IS NULL THEN
        RAISE EXCEPTION 'No está ecommerce.fn_inicio_listar';
    END IF;

    IF strpos(def, 'etiqueta_color') = 0 THEN
        IF strpos(def, ancla1) = 0 THEN
            RAISE EXCEPTION 'No encontré la llamada en fn_inicio_listar';
        END IF;
        def := replace(def, ancla1,
            E'                                           s.descuento_color,     s.descuento_texto,'
            || E'\n                                           s.etiqueta, s.etiqueta_color, s.etiqueta_texto),');
        EXECUTE def;
        v_hecho := false;
    END IF;

    -- La portada pública
    SELECT pg_get_functiondef(p.oid) INTO def
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'ecommerce' AND p.proname = 'fn_inicio_publico';

    IF def IS NULL THEN
        RAISE EXCEPTION 'No está ecommerce.fn_inicio_publico';
    END IF;

    IF strpos(def, 'etiqueta_color') = 0 THEN
        IF strpos(def, ancla2) = 0 THEN
            RAISE EXCEPTION 'No encontré la llamada en fn_inicio_publico';
        END IF;
        def := replace(def, ancla2,
            E'                                            s.descuento_color,     s.descuento_texto,'
            || E'\n                                            s.etiqueta, s.etiqueta_color, s.etiqueta_texto) AS tarjeta,');
        EXECUTE def;
        v_hecho := false;
    END IF;

    IF v_hecho THEN
        RAISE NOTICE 'El listado y la portada ya pasaban la etiqueta: no los toco.';
    ELSE
        RAISE NOTICE 'El listado del CRM y la portada pública ya pasan la etiqueta.';
    END IF;
END
$llamadas$;

-- ----------------------------------------------------------------------------
-- 5. COMPROBACIÓN
-- ----------------------------------------------------------------------------
DO $comprobar$
DECLARE
    v_id      bigint;
    v_clave   text;
    v_p       bigint;
    v_vacia   jsonb;
    v_puesta  jsonb;
    v_publica jsonb;
    v_sinTexto jsonb;
BEGIN
    SELECT p.id INTO v_p FROM inventarios.productos p
     WHERE p.deleted_at IS NULL AND p.activo ORDER BY p.id LIMIT 1;
    IF v_p IS NULL THEN
        RAISE NOTICE 'No hay productos activos con los que comprobar; las columnas están.';
        RETURN;
    END IF;

    BEGIN
        v_id    := (ecommerce.fn_producto_secciones_crear('ZZ etiqueta ' || clock_timestamp())
                    -> 'data' ->> 'id')::bigint;
        v_clave := 'seccion_' || v_id;
        PERFORM ecommerce.fn_producto_seccion_agregar(v_id, jsonb_build_array(v_p));

        SELECT x -> 'tarjeta' -> 'etiqueta' INTO v_vacia
          FROM jsonb_array_elements(ecommerce.fn_inicio_listar() -> 'data') x
         WHERE x ->> 'clave' = v_clave;

        PERFORM ecommerce.fn_inicio_seccion_guardar(v_clave, jsonb_build_object(
            'etiqueta', '  LIQUIDACIÓN  ',
            'etiqueta_color', '#1d3557'));

        SELECT x -> 'tarjeta' -> 'etiqueta' INTO v_puesta
          FROM jsonb_array_elements(ecommerce.fn_inicio_listar() -> 'data') x
         WHERE x ->> 'clave' = v_clave;

        SELECT x -> 'tarjeta' -> 'etiqueta' INTO v_publica
          FROM jsonb_array_elements(ecommerce.fn_inicio_publico() -> 'secciones') x
         WHERE (x ->> 'id')::bigint = v_id;

        -- Color elegido y texto borrado: no puede quedar etiqueta
        PERFORM ecommerce.fn_inicio_seccion_guardar(v_clave, jsonb_build_object(
            'etiqueta', '', 'etiqueta_color', '#1d3557'));

        SELECT x -> 'tarjeta' -> 'etiqueta' INTO v_sinTexto
          FROM jsonb_array_elements(ecommerce.fn_inicio_listar() -> 'data') x
         WHERE x ->> 'clave' = v_clave;

        RAISE EXCEPTION 'deshacer' USING ERRCODE = 'P0099';
    EXCEPTION WHEN SQLSTATE 'P0099' THEN
        NULL;
    END;

    IF v_vacia IS NULL THEN
        RAISE EXCEPTION 'El listado del CRM no trae la llave «etiqueta»';
    END IF;
    IF v_vacia <> '{"fondo": null, "texto": null, "rotulo": null}'::jsonb THEN
        RAISE EXCEPTION 'Recién creada, la etiqueta tendría que venir vacía: %', v_vacia;
    END IF;
    IF v_puesta ->> 'rotulo' <> 'LIQUIDACIÓN' THEN
        RAISE EXCEPTION 'El texto no se guardó o no se recortaron los espacios: %', v_puesta;
    END IF;
    IF v_puesta ->> 'fondo' <> '#1d3557' THEN
        RAISE EXCEPTION 'El fondo de la etiqueta no se guardó: %', v_puesta;
    END IF;
    -- Se tiene que poder elegir sólo el fondo y dejar la letra a la tienda
    IF v_puesta ->> 'texto' IS NOT NULL THEN
        RAISE EXCEPTION 'La letra tendría que quedarse en manos de la tienda: %', v_puesta;
    END IF;
    IF v_publica IS DISTINCT FROM v_puesta THEN
        RAISE EXCEPTION 'La tienda recibe otra cosa que el CRM: % vs %', v_publica, v_puesta;
    END IF;
    IF v_sinTexto ->> 'rotulo' IS NOT NULL THEN
        RAISE EXCEPTION 'Sin texto no puede haber etiqueta: %', v_sinTexto;
    END IF;
    IF EXISTS (SELECT 1 FROM ecommerce.inicio_secciones WHERE clave = v_clave) THEN
        RAISE EXCEPTION 'La sección de prueba se quedó en la portada';
    END IF;

    RAISE NOTICE 'Comprobado: la etiqueta viaja con sus palabras y sus dos colores, se recortan los espacios, se puede elegir sólo el fondo, sin texto no hay etiqueta y la tienda recibe lo mismo que el CRM. No quedó nada.';
END
$comprobar$;

COMMIT;
