-- ============================================================================
-- ECOMMERCE · EL COLOR DE LA TARJETA Y DE SU CARTEL DE DESCUENTO
-- ============================================================================
-- Fecha: 2026-11-02
--
-- Los cuatro botones de la tarjeta ya se podían pintar desde el CRM. Faltaban
-- las otras tres cosas que se ven en la misma tarjeta:
--
--   · EL CARTEL DEL DESCUENTO, el «-12%» de la esquina: fondo y letra, igual
--     que un botón.
--   · EL FONDO DE LA TARJETA.
--   · EL BORDE DE LA TARJETA.
--
-- NO VAN DENTRO DE `botones`, QUE ES LO QUE PARECERÍA MÁS CORTO. Un cartel no
-- es un botón y el fondo de la tarjeta menos todavía: metidos ahí, el día que
-- alguien recorra `botones` para pintar botones se encontraría con tres cosas
-- que no lo son. Van en su propia llave, `tarjeta`:
--
--     "tarjeta": {"fondo": "#fff7f7", "borde": "#f3c6c6",
--                 "descuento": {"fondo": "#df1122", "texto": "#ffffff"}}
--
-- OJO CON EL NOMBRE: `botones.tarjeta` es el BOTÓN de comprar con tarjeta de
-- crédito, y esta llave `tarjeta` de arriba es LA TARJETA DEL PRODUCTO. Son
-- dos niveles distintos y el choque viene de antes; se deja así porque en esta
-- casa «la tarjeta» siempre ha sido la del producto (BOTONES_TARJETA en el CRM
-- son «los botones de la tarjeta», .ae-seccion-prod__tarjeta en la tienda).
--
-- EL FONDO ARRASTRA LA LETRA DE LA TARJETA, y eso lo resuelve la tienda, no
-- esta función: con un fondo oscuro, el nombre del producto y los precios
-- —que son gris oscuro— desaparecerían. La tienda calcula la letra que se lea
-- encima, igual que ya hace con los botones. Por eso aquí no hay columna para
-- la letra de la tarjeta: nadie tiene que elegir dos colores para cambiar uno.
--
-- Idempotente.
-- ============================================================================
\set ON_ERROR_STOP on

BEGIN;

-- ----------------------------------------------------------------------------
-- 1. LAS COLUMNAS
-- ----------------------------------------------------------------------------
ALTER TABLE ecommerce.inicio_secciones
    ADD COLUMN IF NOT EXISTS descuento_color      varchar(7),
    ADD COLUMN IF NOT EXISTS descuento_texto      varchar(7),
    ADD COLUMN IF NOT EXISTS tarjeta_fondo_color  varchar(7),
    ADD COLUMN IF NOT EXISTS tarjeta_borde_color  varchar(7);

-- La misma regla que los botones: o es un «#rrggbb» en minúsculas, o no hay
-- color. El validador de la casa ya lo deja así, pero la columna no se fía de
-- quien escriba por otro lado.
DO $reglas$
DECLARE
    c text;
BEGIN
    FOREACH c IN ARRAY ARRAY['descuento_color', 'descuento_texto',
                             'tarjeta_fondo_color', 'tarjeta_borde_color'] LOOP
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
-- 2. LOS COLORES DE LA TARJETA, ARMADOS EN UN SITIO
-- ----------------------------------------------------------------------------
-- Una sola función para el CRM y para la tienda: si cada uno armara el objeto
-- por su lado, el día que entre un color más habría dos sitios que tocar y uno
-- se quedaría atrás sin decir nada.
CREATE OR REPLACE FUNCTION ecommerce.fn_tarjeta_colores(
    p_fondo           text,
    p_borde           text,
    p_descuento       text,
    p_descuento_texto text)
 RETURNS jsonb
 LANGUAGE sql
 IMMUTABLE PARALLEL SAFE
AS $function$
    -- Los nulos se quedan nulos, como en fn_botones_colores: null en `fondo`
    -- es «el de la tienda» y null en el `texto` del cartel es «el que se lea
    -- encima», que lo calcula la tienda. Resolverlos aquí obligaría a esta
    -- función a conocer la hoja de estilos de la tienda.
    SELECT jsonb_build_object(
        'fondo',     nullif(btrim(COALESCE(p_fondo, '')), ''),
        'borde',     nullif(btrim(COALESCE(p_borde, '')), ''),
        'descuento', jsonb_build_object(
                         'fondo', nullif(btrim(COALESCE(p_descuento, '')), ''),
                         'texto', nullif(btrim(COALESCE(p_descuento_texto, '')), '')));
$function$;

COMMENT ON FUNCTION ecommerce.fn_tarjeta_colores(text, text, text, text) IS
    'Los colores de la TARJETA DEL PRODUCTO (fondo, borde y cartel de descuento), como los manda el CRM. Los botones van aparte, en fn_botones_colores.';

-- ----------------------------------------------------------------------------
-- 3. GUARDAR
-- ----------------------------------------------------------------------------
-- Cirugía sobre el UPDATE y no reescribir la función: a ésta la han ido
-- ampliando el rótulo, el alto y los dos juegos de color de los botones, y
-- volver a escribirla entera aquí sería pisar todo eso con una copia de hoy.
DO $guardar$
DECLARE
    def   text;
    ancla text := E'           boton_tarjeta_texto  = ecommerce.fn_validar_color(p_datos ->> ''boton_tarjeta_texto'',\n                                      ''La letra del botón de comprar con tarjeta''),';
BEGIN
    SELECT pg_get_functiondef(p.oid) INTO def
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'ecommerce' AND p.proname = 'fn_inicio_seccion_guardar';

    IF def IS NULL THEN
        RAISE EXCEPTION 'No está ecommerce.fn_inicio_seccion_guardar';
    END IF;

    IF strpos(def, 'tarjeta_fondo_color') > 0 THEN
        RAISE NOTICE 'Guardar ya aceptaba los colores de la tarjeta: no lo toco.';
        RETURN;
    END IF;

    IF strpos(def, ancla) = 0 THEN
        RAISE EXCEPTION 'No encontré dónde añadir los colores de la tarjeta: ¿cambió fn_inicio_seccion_guardar?';
    END IF;

    def := replace(def, ancla, ancla
        || E'\n           -- El cartel del descuento de la esquina, y el fondo y el borde'
        || E'\n           -- de la tarjeta entera. Mismo validador que todo lo demás.'
        || E'\n           descuento_color      = ecommerce.fn_validar_color(p_datos ->> ''descuento_color'','
        || E'\n                                      ''El color del cartel de descuento''),'
        || E'\n           descuento_texto      = ecommerce.fn_validar_color(p_datos ->> ''descuento_texto'','
        || E'\n                                      ''La letra del cartel de descuento''),'
        || E'\n           tarjeta_fondo_color  = ecommerce.fn_validar_color(p_datos ->> ''tarjeta_fondo_color'','
        || E'\n                                      ''El fondo de la tarjeta''),'
        || E'\n           tarjeta_borde_color  = ecommerce.fn_validar_color(p_datos ->> ''tarjeta_borde_color'','
        || E'\n                                      ''El borde de la tarjeta''),');

    EXECUTE def;
    RAISE NOTICE 'Guardar ya acepta el cartel de descuento y el fondo y el borde de la tarjeta.';
END
$guardar$;

-- ----------------------------------------------------------------------------
-- 4. EL LISTADO DEL CRM
-- ----------------------------------------------------------------------------
DO $listar$
DECLARE
    def   text;
    ancla text := E'                                           s.boton_tarjeta_color,  s.boton_tarjeta_texto),';
BEGIN
    SELECT pg_get_functiondef(p.oid) INTO def
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'ecommerce' AND p.proname = 'fn_inicio_listar';

    IF def IS NULL THEN
        RAISE EXCEPTION 'No está ecommerce.fn_inicio_listar';
    END IF;

    IF strpos(def, 'fn_tarjeta_colores') > 0 THEN
        RAISE NOTICE 'El listado ya traía los colores de la tarjeta: no lo toco.';
        RETURN;
    END IF;

    IF strpos(def, ancla) = 0 THEN
        RAISE EXCEPTION 'No encontré la llamada a los botones: ¿cambió fn_inicio_listar?';
    END IF;

    def := replace(def, ancla, ancla
        || E'\n                       ''tarjeta'',    ecommerce.fn_tarjeta_colores('
        || E'\n                                           s.tarjeta_fondo_color, s.tarjeta_borde_color,'
        || E'\n                                           s.descuento_color,     s.descuento_texto),');

    EXECUTE def;
    RAISE NOTICE 'El listado del CRM ya trae los colores de la tarjeta.';
END
$listar$;

-- ----------------------------------------------------------------------------
-- 5. LA PORTADA PÚBLICA
-- ----------------------------------------------------------------------------
-- Aquí hay DOS sitios: la lectura de la fila y el armado de la sección de
-- productos. Se tocan en el mismo bloque para que no pueda quedar uno hecho y
-- el otro no.
DO $publica$
DECLARE
    def    text;
    ancla1 text := E'                                            s.boton_tarjeta_color,  s.boton_tarjeta_texto) AS botones,';
    ancla2 text := E'                            ''botones'', v.botones,';
BEGIN
    SELECT pg_get_functiondef(p.oid) INTO def
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'ecommerce' AND p.proname = 'fn_inicio_publico';

    IF def IS NULL THEN
        RAISE EXCEPTION 'No está ecommerce.fn_inicio_publico';
    END IF;

    IF strpos(def, 'fn_tarjeta_colores') > 0 THEN
        RAISE NOTICE 'La portada pública ya traía los colores de la tarjeta: no la toco.';
        RETURN;
    END IF;

    IF strpos(def, ancla1) = 0 OR strpos(def, ancla2) = 0 THEN
        RAISE EXCEPTION 'No encontré los dos sitios que hay que tocar: ¿cambió fn_inicio_publico?';
    END IF;

    def := replace(def, ancla1, ancla1
        || E'\n               ecommerce.fn_tarjeta_colores(s.tarjeta_fondo_color, s.tarjeta_borde_color,'
        || E'\n                                            s.descuento_color,     s.descuento_texto) AS tarjeta,');

    def := replace(def, ancla2, ancla2
        || E'\n                            ''tarjeta'', v.tarjeta,');

    EXECUTE def;
    RAISE NOTICE 'La portada pública ya manda los colores de la tarjeta.';
END
$publica$;

-- ----------------------------------------------------------------------------
-- 6. COMPROBACIÓN
-- ----------------------------------------------------------------------------
-- Se crea una sección de prueba, se le ponen colores, se mira lo que ven el
-- CRM y la tienda, y se deshace. Si algo falla, la transacción entera se va
-- abajo y no queda nada: la P0099 es la de deshacer a propósito, para no
-- confundirla con la P0001 de las funciones de negocio.
DO $comprobar$
DECLARE
    v_id      bigint;
    v_clave   text;
    v_p       bigint;
    v_vacios  jsonb;
    v_fila    jsonb;
    v_publica jsonb;
BEGIN
    SELECT p.id INTO v_p FROM inventarios.productos p
     WHERE p.deleted_at IS NULL AND p.activo ORDER BY p.id LIMIT 1;
    IF v_p IS NULL THEN
        RAISE NOTICE 'No hay productos activos con los que comprobar; las columnas están.';
        RETURN;
    END IF;

    BEGIN
        v_id    := (ecommerce.fn_producto_secciones_crear('ZZ tarjeta ' || clock_timestamp())
                    -> 'data' ->> 'id')::bigint;
        v_clave := 'seccion_' || v_id;
        PERFORM ecommerce.fn_producto_seccion_agregar(v_id, jsonb_build_array(v_p));

        SELECT x -> 'tarjeta' INTO v_vacios
          FROM jsonb_array_elements(ecommerce.fn_inicio_listar() -> 'data') x
         WHERE x ->> 'clave' = v_clave;

        -- El fondo y el borde, y el cartel con SÓLO el fondo: la letra del
        -- cartel se tiene que poder dejar en manos de la tienda, igual que la
        -- de los botones
        PERFORM ecommerce.fn_inicio_seccion_guardar(v_clave, jsonb_build_object(
            'tarjeta_fondo_color', '#fff7f7',
            'tarjeta_borde_color', '#f3c6c6',
            'descuento_color',     '#1d3557'));

        SELECT x -> 'tarjeta' INTO v_fila
          FROM jsonb_array_elements(ecommerce.fn_inicio_listar() -> 'data') x
         WHERE x ->> 'clave' = v_clave;

        SELECT x -> 'tarjeta' INTO v_publica
          FROM jsonb_array_elements(ecommerce.fn_inicio_publico() -> 'secciones') x
         WHERE (x ->> 'id')::bigint = v_id;

        RAISE EXCEPTION 'deshacer' USING ERRCODE = 'P0099';
    EXCEPTION WHEN SQLSTATE 'P0099' THEN
        NULL;
    END;

    IF v_vacios IS NULL THEN
        RAISE EXCEPTION 'El listado del CRM no trae la llave «tarjeta»';
    END IF;
    IF v_vacios ->> 'fondo' IS NOT NULL OR v_vacios ->> 'borde' IS NOT NULL
       OR v_vacios -> 'descuento' <> '{"fondo": null, "texto": null}'::jsonb THEN
        RAISE EXCEPTION 'Recién creada, la tarjeta tendría que venir sin colores: %', v_vacios;
    END IF;
    IF v_fila ->> 'fondo' <> '#fff7f7' OR v_fila ->> 'borde' <> '#f3c6c6' THEN
        RAISE EXCEPTION 'El fondo y el borde de la tarjeta no se guardaron: %', v_fila;
    END IF;
    IF v_fila -> 'descuento' ->> 'fondo' <> '#1d3557' THEN
        RAISE EXCEPTION 'El fondo del cartel de descuento no se guardó: %', v_fila -> 'descuento';
    END IF;
    -- El caso de dejar la letra a la tienda
    IF v_fila -> 'descuento' ->> 'texto' IS NOT NULL THEN
        RAISE EXCEPTION 'Se tiene que poder elegir sólo el fondo del cartel: %', v_fila -> 'descuento';
    END IF;
    IF v_publica IS DISTINCT FROM v_fila THEN
        RAISE EXCEPTION 'La tienda recibe otra cosa que el CRM: % vs %', v_publica, v_fila;
    END IF;
    IF EXISTS (SELECT 1 FROM ecommerce.inicio_secciones WHERE clave = v_clave) THEN
        RAISE EXCEPTION 'La sección de prueba se quedó en la portada';
    END IF;

    RAISE NOTICE 'Comprobado: la tarjeta lleva fondo, borde y cartel; se puede elegir sólo el fondo del cartel, y la tienda recibe lo mismo que el CRM. No quedó nada.';
END
$comprobar$;

COMMIT;
