-- ============================================================================
-- ECOMMERCE · EL COLOR DE LA LETRA DE LOS BOTONES
-- ============================================================================
-- Fecha: 2026-11-02
--
-- Los cuatro botones de la tarjeta ya tenían fondo configurable; la letra y el
-- icono los calculaba la tienda —blanco o negro, el que se leyera encima—. Eso
-- garantiza que SIEMPRE se lea, pero quita decisiones: con el corazón sobre un
-- fondo ámbar salía negro, y antes era rojo.
--
-- AHORA LA LETRA TAMBIÉN SE ELIGE, y el cálculo automático se queda como valor
-- por defecto: sin elegir letra, la tienda sigue poniendo la que se lea encima
-- del fondo. Nadie tiene que elegir dos colores para cambiar uno.
--
-- `botones` PASA A LLEVAR UN OBJETO POR BOTÓN, `{fondo, texto}`, en vez de un
-- color suelto. Con ocho claves planas —favorito, favorito_texto…— la mitad de
-- las consultas acaban escribiendo el sufijo a mano, y la primera que lo
-- escriba mal se queda sin color sin decir nada.
--
-- NO SE PROHÍBE UNA COMBINACIÓN ILEGIBLE, se avisa en la pantalla, igual que
-- con el color del rótulo: un amarillo sobre blanco puede ser justo lo que se
-- quiere para una campaña, y quien administra está mirando la muestra.
--
-- Idempotente.
-- ============================================================================
\set ON_ERROR_STOP on

BEGIN;

-- ----------------------------------------------------------------------------
-- 1. LAS COLUMNAS DE LA LETRA
-- ----------------------------------------------------------------------------
ALTER TABLE ecommerce.inicio_secciones
    ADD COLUMN IF NOT EXISTS boton_favorito_texto varchar(7),
    ADD COLUMN IF NOT EXISTS boton_carrito_texto  varchar(7),
    ADD COLUMN IF NOT EXISTS boton_whatsapp_texto varchar(7),
    ADD COLUMN IF NOT EXISTS boton_tarjeta_texto  varchar(7);

DO $reglas$
DECLARE
    c text;
BEGIN
    FOREACH c IN ARRAY ARRAY['favorito', 'carrito', 'whatsapp', 'tarjeta'] LOOP
        IF NOT EXISTS (SELECT 1 FROM pg_constraint
                        WHERE conname = 'ck_inicio_secciones_texto_' || c) THEN
            EXECUTE format(
                'ALTER TABLE ecommerce.inicio_secciones ADD CONSTRAINT %I CHECK (%I IS NULL OR %I ~ ''^#[0-9a-f]{6}$'')',
                'ck_inicio_secciones_texto_' || c, 'boton_' || c || '_texto', 'boton_' || c || '_texto');
        END IF;
    END LOOP;
END
$reglas$;

-- ----------------------------------------------------------------------------
-- 2. LOS COLORES, AHORA EN PAREJAS
-- ----------------------------------------------------------------------------
-- La de cuatro argumentos se borra: con las dos puestas, una llamada vieja
-- seguiría compilando y devolvería la forma antigua a quien la use.
DROP FUNCTION IF EXISTS ecommerce.fn_botones_colores(text, text, text, text);

CREATE OR REPLACE FUNCTION ecommerce.fn_botones_colores(
    p_favorito text, p_favorito_texto text,
    p_carrito  text, p_carrito_texto  text,
    p_whatsapp text, p_whatsapp_texto text,
    p_tarjeta  text, p_tarjeta_texto  text)
 RETURNS jsonb
 LANGUAGE sql
 IMMUTABLE PARALLEL SAFE
AS $function$
    -- Los nulos se quedan nulos: null en `fondo` es «el de la tienda», y null
    -- en `texto` es «el que se lea encima del fondo», que lo calcula la
    -- tienda. Resolverlos aquí obligaría a esta función a conocer la hoja de
    -- estilos de la tienda.
    SELECT jsonb_build_object(
        'favorito', jsonb_build_object('fondo', nullif(btrim(COALESCE(p_favorito, '')), ''),
                                       'texto', nullif(btrim(COALESCE(p_favorito_texto, '')), '')),
        'carrito',  jsonb_build_object('fondo', nullif(btrim(COALESCE(p_carrito, '')), ''),
                                       'texto', nullif(btrim(COALESCE(p_carrito_texto, '')), '')),
        'whatsapp', jsonb_build_object('fondo', nullif(btrim(COALESCE(p_whatsapp, '')), ''),
                                       'texto', nullif(btrim(COALESCE(p_whatsapp_texto, '')), '')),
        'tarjeta',  jsonb_build_object('fondo', nullif(btrim(COALESCE(p_tarjeta, '')), ''),
                                       'texto', nullif(btrim(COALESCE(p_tarjeta_texto, '')), '')));
$function$;

-- ----------------------------------------------------------------------------
-- 3. GUARDAR
-- ----------------------------------------------------------------------------
-- Se le añaden los cuatro campos de letra. Cirugía sobre el UPDATE y no
-- reescribir la función: esa la han ido ampliando el rótulo, el alto y el
-- fondo de los botones.
DO $guardar$
DECLARE
    def   text;
    ancla text := E'           boton_tarjeta_color  = ecommerce.fn_validar_color(p_datos ->> ''boton_tarjeta_color'',\n                                      ''El color del botón de comprar con tarjeta''),';
BEGIN
    SELECT pg_get_functiondef(p.oid) INTO def
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'ecommerce' AND p.proname = 'fn_inicio_seccion_guardar';

    IF def IS NULL THEN
        RAISE EXCEPTION 'No está ecommerce.fn_inicio_seccion_guardar';
    END IF;

    IF strpos(def, 'boton_favorito_texto') > 0 THEN
        RAISE NOTICE 'Guardar ya aceptaba el color de la letra: no lo toco.';
        RETURN;
    END IF;

    IF strpos(def, ancla) = 0 THEN
        RAISE EXCEPTION 'No encontré dónde añadir la letra: ¿cambió fn_inicio_seccion_guardar?';
    END IF;

    def := replace(def, ancla, ancla
        || E'\n           boton_favorito_texto = ecommerce.fn_validar_color(p_datos ->> ''boton_favorito_texto'','
        || E'\n                                      ''La letra del botón de favorito''),'
        || E'\n           boton_carrito_texto  = ecommerce.fn_validar_color(p_datos ->> ''boton_carrito_texto'','
        || E'\n                                      ''La letra del botón de agregar''),'
        || E'\n           boton_whatsapp_texto = ecommerce.fn_validar_color(p_datos ->> ''boton_whatsapp_texto'','
        || E'\n                                      ''La letra del botón de WhatsApp''),'
        || E'\n           boton_tarjeta_texto  = ecommerce.fn_validar_color(p_datos ->> ''boton_tarjeta_texto'','
        || E'\n                                      ''La letra del botón de comprar con tarjeta''),');

    EXECUTE def;
    RAISE NOTICE 'Guardar ya acepta el color de la letra de los cuatro botones.';
END
$guardar$;

-- ----------------------------------------------------------------------------
-- 4. EL LISTADO DEL CRM
-- ----------------------------------------------------------------------------
DO $listar$
DECLARE
    def   text;
    ancla text := E'                       ''botones'',    ecommerce.fn_botones_colores(\n                                           s.boton_favorito_color, s.boton_carrito_color,\n                                           s.boton_whatsapp_color, s.boton_tarjeta_color),';
BEGIN
    SELECT pg_get_functiondef(p.oid) INTO def
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'ecommerce' AND p.proname = 'fn_inicio_listar';

    IF def IS NULL THEN
        RAISE EXCEPTION 'No está ecommerce.fn_inicio_listar';
    END IF;

    IF strpos(def, 'boton_favorito_texto') > 0 THEN
        RAISE NOTICE 'El listado ya traía el color de la letra: no lo toco.';
        RETURN;
    END IF;

    IF strpos(def, ancla) = 0 THEN
        RAISE EXCEPTION 'No encontré la llamada vieja: ¿cambió fn_inicio_listar?';
    END IF;

    def := replace(def, ancla,
        E'                       ''botones'',    ecommerce.fn_botones_colores('
        || E'\n                                           s.boton_favorito_color, s.boton_favorito_texto,'
        || E'\n                                           s.boton_carrito_color,  s.boton_carrito_texto,'
        || E'\n                                           s.boton_whatsapp_color, s.boton_whatsapp_texto,'
        || E'\n                                           s.boton_tarjeta_color,  s.boton_tarjeta_texto),');

    EXECUTE def;
    RAISE NOTICE 'El listado del CRM ya trae el color de la letra.';
END
$listar$;

-- ----------------------------------------------------------------------------
-- 5. LA PORTADA PÚBLICA
-- ----------------------------------------------------------------------------
-- Aquí sólo cambia la llamada, así que va por cirugía igual.
DO $publica$
DECLARE
    def   text;
    ancla text := E'               ecommerce.fn_botones_colores(s.boton_favorito_color, s.boton_carrito_color,\n                                            s.boton_whatsapp_color, s.boton_tarjeta_color) AS botones,';
BEGIN
    SELECT pg_get_functiondef(p.oid) INTO def
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'ecommerce' AND p.proname = 'fn_inicio_publico';

    IF def IS NULL THEN
        RAISE EXCEPTION 'No está ecommerce.fn_inicio_publico';
    END IF;

    IF strpos(def, 'boton_favorito_texto') > 0 THEN
        RAISE NOTICE 'La portada pública ya traía el color de la letra: no la toco.';
        RETURN;
    END IF;

    IF strpos(def, ancla) = 0 THEN
        RAISE EXCEPTION 'No encontré la llamada vieja: ¿cambió fn_inicio_publico?';
    END IF;

    def := replace(def, ancla,
        E'               ecommerce.fn_botones_colores(s.boton_favorito_color, s.boton_favorito_texto,'
        || E'\n                                            s.boton_carrito_color,  s.boton_carrito_texto,'
        || E'\n                                            s.boton_whatsapp_color, s.boton_whatsapp_texto,'
        || E'\n                                            s.boton_tarjeta_color,  s.boton_tarjeta_texto) AS botones,');

    EXECUTE def;
    RAISE NOTICE 'La portada pública ya trae el color de la letra.';
END
$publica$;

-- ----------------------------------------------------------------------------
-- 6. COMPROBACIÓN
-- ----------------------------------------------------------------------------
DO $comprobar$
DECLARE
    v_id      bigint;
    v_clave   text;
    v_p       bigint;
    v_vacios  jsonb;
    v_fila    jsonb;
    v_publica jsonb;
    v_solo    jsonb;
BEGIN
    SELECT p.id INTO v_p FROM inventarios.productos p
     WHERE p.deleted_at IS NULL AND p.activo ORDER BY p.id LIMIT 1;
    IF v_p IS NULL THEN
        RAISE NOTICE 'No hay productos activos con los que comprobar; las columnas están.';
        RETURN;
    END IF;

    BEGIN
        v_id    := (ecommerce.fn_producto_secciones_crear('ZZ letra ' || clock_timestamp())
                    -> 'data' ->> 'id')::bigint;
        v_clave := 'seccion_' || v_id;
        PERFORM ecommerce.fn_producto_seccion_agregar(v_id, jsonb_build_array(v_p));

        SELECT x -> 'botones' INTO v_vacios
          FROM jsonb_array_elements(ecommerce.fn_inicio_listar() -> 'data') x
         WHERE x ->> 'clave' = v_clave;

        -- Fondo y letra en uno; SÓLO LETRA en otro, que es el caso que pidió
        -- el usuario: el corazón rojo sobre el círculo blanco de siempre
        PERFORM ecommerce.fn_inicio_seccion_guardar(v_clave, jsonb_build_object(
            'boton_carrito_color', '#f4d35e', 'boton_carrito_texto', '#1d3557',
            'boton_favorito_texto', '#df1122'));

        SELECT x -> 'botones' INTO v_fila
          FROM jsonb_array_elements(ecommerce.fn_inicio_listar() -> 'data') x
         WHERE x ->> 'clave' = v_clave;

        SELECT x -> 'botones' INTO v_publica
          FROM jsonb_array_elements(ecommerce.fn_inicio_publico() -> 'secciones') x
         WHERE (x ->> 'id')::bigint = v_id;

        v_solo := v_fila -> 'favorito';

        RAISE EXCEPTION 'deshacer' USING ERRCODE = 'P0099';
    EXCEPTION WHEN SQLSTATE 'P0099' THEN
        NULL;
    END;

    IF v_vacios IS NULL
       OR v_vacios -> 'carrito' <> '{"fondo": null, "texto": null}'::jsonb THEN
        RAISE EXCEPTION 'Recién creada, cada botón tendría que venir con fondo y letra vacíos: %', v_vacios;
    END IF;
    IF v_fila -> 'carrito' ->> 'fondo' <> '#f4d35e'
       OR v_fila -> 'carrito' ->> 'texto' <> '#1d3557' THEN
        RAISE EXCEPTION 'El fondo y la letra del carrito no se guardaron: %', v_fila -> 'carrito';
    END IF;
    -- El caso del corazón: letra elegida y fondo sin tocar
    IF v_solo ->> 'texto' <> '#df1122' OR v_solo ->> 'fondo' IS NOT NULL THEN
        RAISE EXCEPTION 'Se tiene que poder elegir SÓLO la letra, sin tocar el fondo: %', v_solo;
    END IF;
    IF v_publica IS DISTINCT FROM v_fila THEN
        RAISE EXCEPTION 'La tienda recibe otra cosa que el CRM: % vs %', v_publica, v_fila;
    END IF;
    IF EXISTS (SELECT 1 FROM ecommerce.inicio_secciones WHERE clave = v_clave) THEN
        RAISE EXCEPTION 'La sección de prueba se quedó en la portada';
    END IF;

    RAISE NOTICE 'Comprobado: cada botón lleva {fondo, texto}, se puede elegir sólo la letra sin tocar el fondo, y la tienda recibe lo mismo que el CRM. No quedó nada.';
END
$comprobar$;

COMMIT;
