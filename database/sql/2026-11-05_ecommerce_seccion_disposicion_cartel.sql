-- ============================================================================
-- ECOMMERCE · UNA CUARTA MANERA DE ENSEÑAR UNA SECCIÓN DE PRODUCTOS: EN CARTELES
-- ============================================================================
-- Fecha: 2026-11-05
--
-- Hasta hoy una sección de productos se enseñaba de tres maneras: `sola`,
-- `izquierda` y `derecha`. Se añade la cuarta:
--
--   · `cartel` — los productos en carteles cuadrados, tres por fila, con la
--     foto a todo el cartel y el nombre y el precio escritos encima, como los
--     carteles de «Categorías en promoción» y los de un banner en carteles.
--
-- NO LLEVA IMAGEN DE AL LADO, y por eso `lado` sale 'cartel' tal cual: la
-- regla de «sin fichero no hay lado» es para 'izquierda' y 'derecha', que
-- dejarían una columna vacía al lado de los productos. Aquí no hay columna que
-- llenar, así que no hay nada que esperar.
--
-- `lado` SIGUE SIENDO UN SOLO CAMPO y no se parte en dos. Las cuatro maneras
-- se excluyen —o hay imagen a un lado, o no la hay, o los productos van en
-- carteles—, y la pantalla del CRM es un solo grupo de botones. Con dos campos
-- habría que inventarse qué significa «carteles con imagen a la izquierda»,
-- que no es nada.
--
-- Lo elegido se guarda igual aunque luego se cambie de idea: pasar por
-- 'cartel' y volver a 'izquierda' recupera la imagen que ya estaba subida,
-- porque el fichero nunca se borra al guardar la disposición.
--
-- Idempotente.
-- ============================================================================
\set ON_ERROR_STOP on

BEGIN;

-- ----------------------------------------------------------------------------
-- 1. LA REGLA DE LA COLUMNA
-- ----------------------------------------------------------------------------
-- Se vuelve a escribir entera: una restricción CHECK no se amplía, se cambia.
DO $reglas$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_constraint
                WHERE conname = 'ck_inicio_secciones_disposicion'
                  AND pg_get_constraintdef(oid) LIKE '%cartel%') THEN
        RAISE NOTICE 'La columna ya admitía «cartel»: no la toco.';
        RETURN;
    END IF;

    ALTER TABLE ecommerce.inicio_secciones
        DROP CONSTRAINT IF EXISTS ck_inicio_secciones_disposicion;

    ALTER TABLE ecommerce.inicio_secciones
        ADD CONSTRAINT ck_inicio_secciones_disposicion
        CHECK (disposicion IS NULL OR disposicion IN ('sola', 'izquierda', 'derecha', 'cartel'));
END
$reglas$;

-- ----------------------------------------------------------------------------
-- 2. CÓMO SE VE LA SECCIÓN
-- ----------------------------------------------------------------------------
-- Lo único que cambia: 'cartel' no necesita fichero, así que la regla de «sin
-- imagen no hay lado» no le toca.
CREATE OR REPLACE FUNCTION ecommerce.fn_seccion_imagen(
    p_disposicion   text,
    p_imagen        text,
    p_alt           text,
    p_enlace        text,
    p_nueva_pestana boolean)
 RETURNS jsonb
 LANGUAGE sql
 IMMUTABLE PARALLEL SAFE
AS $function$
    SELECT jsonb_build_object(
        -- SIN FICHERO NO HAY LADO: con 'izquierda' y sin imagen, la tienda
        -- dejaría un hueco al lado de los productos. 'cartel' queda fuera de
        -- esa regla porque no enseña ninguna imagen de al lado: lo que cambia
        -- es la forma de las tarjetas
        'lado', CASE WHEN COALESCE(nullif(btrim(COALESCE(p_disposicion, '')), ''), 'sola') = 'cartel'
                     THEN 'cartel'
                     WHEN nullif(btrim(COALESCE(p_imagen, '')), '') IS NULL THEN 'sola'
                     ELSE COALESCE(nullif(btrim(COALESCE(p_disposicion, '')), ''), 'sola') END,
        -- Lo que se ELIGIÓ, que no siempre es lo que se va a ver. El CRM
        -- necesita los dos: si al quitar la imagen se perdiera la elección,
        -- volver a subirla obligaría a elegir el lado otra vez, y nadie
        -- entendería por qué se le olvidó
        'elegido', COALESCE(nullif(btrim(COALESCE(p_disposicion, '')), ''), 'sola'),
        'archivo',       nullif(btrim(COALESCE(p_imagen, '')), ''),
        'alt',           nullif(btrim(COALESCE(p_alt, '')), ''),
        'enlace',        nullif(btrim(COALESCE(p_enlace, '')), ''),
        'nueva_pestana', COALESCE(p_nueva_pestana, false));
$function$;

COMMENT ON FUNCTION ecommerce.fn_seccion_imagen(text, text, text, text, boolean) IS
    'Cómo se enseña una sección de productos y la imagen de al lado. `lado` sale ''sola'' siempre que se haya pedido un lado y no haya fichero; ''cartel'' no necesita ninguno.';

-- ----------------------------------------------------------------------------
-- 3. GUARDAR: LA CUARTA OPCIÓN
-- ----------------------------------------------------------------------------
-- Cirugía sobre la función que ya existe: se cambia SÓLO la lista de opciones.
DO $guardar$
DECLARE
    def   text;
    viejo text := E'                               ARRAY[''sola'', ''izquierda'', ''derecha''], ''La disposición de la sección''),';
    nuevo text := E'                               ARRAY[''sola'', ''izquierda'', ''derecha'', ''cartel''], ''La disposición de la sección''),';
BEGIN
    SELECT pg_get_functiondef(p.oid) INTO def
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'ecommerce' AND p.proname = 'fn_inicio_seccion_guardar';

    IF def IS NULL THEN
        RAISE EXCEPTION 'No está ecommerce.fn_inicio_seccion_guardar';
    END IF;

    -- Se pregunta por el texto NUEVO, no por la palabra suelta: así una
    -- aplicación a medias se puede reparar volviendo a pasar el fichero
    IF strpos(def, nuevo) > 0 THEN
        RAISE NOTICE 'Guardar ya admitía «cartel»: no lo toco.';
        RETURN;
    END IF;

    IF strpos(def, viejo) = 0 THEN
        RAISE EXCEPTION 'No encontré la lista de disposiciones: ¿cambió fn_inicio_seccion_guardar?';
    END IF;

    EXECUTE replace(def, viejo, nuevo);
    RAISE NOTICE 'Guardar ya acepta «cartel».';
END
$guardar$;

-- ----------------------------------------------------------------------------
-- 4. COMPROBACIÓN
-- ----------------------------------------------------------------------------
-- Sobre una sección de verdad, y se deshace: la portada no puede quedarse con
-- una sección de prueba.
DO $comprobar$
DECLARE
    v_id      bigint;
    v_clave   text;
    v_p       bigint;
    v_cartel  jsonb;
    v_publica jsonb;
    v_vuelta  jsonb;
    v_sinfoto jsonb;
    v_malo    text := NULL;
BEGIN
    SELECT p.id INTO v_p FROM inventarios.productos p
     WHERE p.deleted_at IS NULL AND p.activo ORDER BY p.id LIMIT 1;
    IF v_p IS NULL THEN
        RAISE NOTICE 'No hay productos activos con los que comprobar; la regla y las funciones están.';
        RETURN;
    END IF;

    BEGIN
        v_id    := (ecommerce.fn_producto_secciones_crear('ZZ cartel ' || clock_timestamp())
                    -> 'data' ->> 'id')::bigint;
        v_clave := 'seccion_' || v_id;
        PERFORM ecommerce.fn_producto_seccion_agregar(v_id, jsonb_build_array(v_p));

        -- En carteles, y SIN subir ninguna imagen
        PERFORM ecommerce.fn_inicio_seccion_guardar(v_clave, jsonb_build_object('disposicion', 'cartel'));

        SELECT x -> 'imagen' INTO v_cartel
          FROM jsonb_array_elements(ecommerce.fn_inicio_listar() -> 'data') x
         WHERE x ->> 'clave' = v_clave;

        SELECT x -> 'imagen' INTO v_publica
          FROM jsonb_array_elements(ecommerce.fn_inicio_publico() -> 'secciones') x
         WHERE (x ->> 'id')::bigint = v_id;

        -- La regla de siempre sigue en pie: pedir un lado sin fichero no vale
        PERFORM ecommerce.fn_inicio_seccion_guardar(v_clave, jsonb_build_object('disposicion', 'izquierda'));

        SELECT x -> 'imagen' INTO v_sinfoto
          FROM jsonb_array_elements(ecommerce.fn_inicio_listar() -> 'data') x
         WHERE x ->> 'clave' = v_clave;

        -- Y se puede volver a carteles
        PERFORM ecommerce.fn_inicio_seccion_guardar(v_clave, jsonb_build_object('disposicion', 'cartel'));

        SELECT x -> 'imagen' INTO v_vuelta
          FROM jsonb_array_elements(ecommerce.fn_inicio_listar() -> 'data') x
         WHERE x ->> 'clave' = v_clave;

        -- Una disposición inventada no entra
        BEGIN
            PERFORM ecommerce.fn_inicio_seccion_guardar(v_clave, jsonb_build_object('disposicion', 'mosaico'));
            v_malo := 'entró una disposición que no existe';
        EXCEPTION WHEN SQLSTATE 'P0015' THEN
            NULL;
        END;

        RAISE EXCEPTION 'deshacer' USING ERRCODE = 'P0099';
    EXCEPTION WHEN SQLSTATE 'P0099' THEN
        NULL;
    END;

    IF v_cartel ->> 'lado' <> 'cartel' OR v_cartel ->> 'elegido' <> 'cartel' THEN
        RAISE EXCEPTION 'En carteles y sin fichero tendría que salir «cartel»: %', v_cartel;
    END IF;
    IF v_cartel ->> 'archivo' IS NOT NULL THEN
        RAISE EXCEPTION 'Los carteles no llevan imagen de al lado: %', v_cartel;
    END IF;
    IF v_publica IS DISTINCT FROM v_cartel THEN
        RAISE EXCEPTION 'La tienda recibe otra cosa que el CRM: % vs %', v_publica, v_cartel;
    END IF;
    IF v_sinfoto ->> 'lado' <> 'sola' OR v_sinfoto ->> 'elegido' <> 'izquierda' THEN
        RAISE EXCEPTION 'Pedir un lado sin fichero sigue teniendo que quedarse en «sola»: %', v_sinfoto;
    END IF;
    IF v_vuelta ->> 'lado' <> 'cartel' THEN
        RAISE EXCEPTION 'Volver a carteles tendría que valer: %', v_vuelta;
    END IF;
    IF v_malo IS NOT NULL THEN
        RAISE EXCEPTION '%', v_malo;
    END IF;
    IF EXISTS (SELECT 1 FROM ecommerce.inicio_secciones WHERE clave = v_clave) THEN
        RAISE EXCEPTION 'La sección de prueba se quedó en la portada';
    END IF;

    RAISE NOTICE 'Comprobado: «cartel» se guarda y llega igual al CRM y a la tienda sin subir ninguna imagen, pedir un lado sin fichero sigue quedándose en «sola», y una disposición inventada no entra. No quedó nada.';
END
$comprobar$;

COMMIT;
