-- ============================================================================
-- ECOMMERCE · LA IMAGEN DE AL LADO DE UNA SECCIÓN DE PRODUCTOS
-- ============================================================================
-- Fecha: 2026-11-02
--
-- Una sección de productos se puede enseñar de tres maneras:
--
--   · `sola`       — sólo las tarjetas, como hasta ahora.
--   · `izquierda`  — una imagen a la izquierda y las tarjetas a su derecha.
--   · `derecha`    — al revés.
--
-- La imagen puede llevar a otro sitio, dentro o fuera de la tienda. El enlace
-- pasa por `fn_validar_enlace`, el mismo de la cabecera y el pie: sólo se
-- admite una ruta de la casa (/ofertas), una dirección http(s), un correo o un
-- teléfono. Un «javascript:» ahí dentro es un agujero, y quien administra la
-- portada no tiene por qué poder abrirlo.
--
-- Y la pestaña nueva la decide `fn_nueva_pestana`, también de la casa: un
-- enlace de dentro nunca abre pestaña, y uno de fuera la abre salvo que se
-- diga lo contrario. No se escribe a mano porque nadie se acuerda de la regla.
--
-- SIN FICHERO NO HAY DISPOSICIÓN. `fn_seccion_imagen` fuerza `lado` a 'sola'
-- cuando no hay imagen subida, y esa regla vive AQUÍ y no en la tienda: si
-- viviera allí, el CRM podría mandar «imagen a la izquierda» sin imagen y la
-- tienda dejaría una columna vacía al lado de los productos.
--
-- EL FICHERO NO SE GUARDA CON EL RESTO. `fn_inicio_seccion_guardar` pone todos
-- sus campos sin mirar si vienen, así que meter ahí `imagen` haría que
-- cualquier guardado que no la mandara la borrara. Va por su propia puerta,
-- `fn_inicio_seccion_imagen`, que es la que usa la subida.
--
-- EN LA BASE VA SÓLO EL NOMBRE DEL FICHERO, como en el resto del ecommerce: la
-- dirección la arma PHP al leer (ImagenesDelEcommerce), y así mover el CRM de
-- máquina no deja imágenes rotas.
--
-- Idempotente.
-- ============================================================================
\set ON_ERROR_STOP on

BEGIN;

-- ----------------------------------------------------------------------------
-- 1. LAS COLUMNAS
-- ----------------------------------------------------------------------------
ALTER TABLE ecommerce.inicio_secciones
    ADD COLUMN IF NOT EXISTS disposicion          varchar(12),
    ADD COLUMN IF NOT EXISTS imagen               varchar(255),
    ADD COLUMN IF NOT EXISTS imagen_alt           varchar(120),
    ADD COLUMN IF NOT EXISTS imagen_enlace        varchar(250),
    ADD COLUMN IF NOT EXISTS imagen_nueva_pestana boolean NOT NULL DEFAULT false;

DO $reglas$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'ck_inicio_secciones_disposicion') THEN
        ALTER TABLE ecommerce.inicio_secciones
            ADD CONSTRAINT ck_inicio_secciones_disposicion
            CHECK (disposicion IS NULL OR disposicion IN ('sola', 'izquierda', 'derecha'));
    END IF;
END
$reglas$;

-- ----------------------------------------------------------------------------
-- 2. CÓMO SE VE LA SECCIÓN, ARMADO EN UN SITIO
-- ----------------------------------------------------------------------------
-- Devuelve SIEMPRE el objeto, también cuando no hay nada: el CRM necesita ver
-- el fichero subido aunque la disposición esté en 'sola' —si no, cambiar de
-- idea obligaría a volver a subir la misma imagen—, y la tienda mira `lado`
-- para saber si pinta la columna.
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
        -- dejaría un hueco al lado de los productos
        'lado', CASE WHEN nullif(btrim(COALESCE(p_imagen, '')), '') IS NULL THEN 'sola'
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
    'La imagen de al lado de una sección de productos. `lado` sale ''sola'' siempre que no haya fichero.';

-- ----------------------------------------------------------------------------
-- 3. GUARDAR LO QUE NO ES EL FICHERO
-- ----------------------------------------------------------------------------
DO $guardar$
DECLARE
    def   text;
    ancla text := E'           tarjeta_borde_color  = ecommerce.fn_validar_color(p_datos ->> ''tarjeta_borde_color'',\n                                      ''El borde de la tarjeta''),';
BEGIN
    SELECT pg_get_functiondef(p.oid) INTO def
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'ecommerce' AND p.proname = 'fn_inicio_seccion_guardar';

    IF def IS NULL THEN
        RAISE EXCEPTION 'No está ecommerce.fn_inicio_seccion_guardar';
    END IF;

    IF strpos(def, 'imagen_enlace') > 0 THEN
        RAISE NOTICE 'Guardar ya aceptaba la disposición y el enlace: no lo toco.';
        RETURN;
    END IF;

    IF strpos(def, ancla) = 0 THEN
        RAISE EXCEPTION 'No encontré dónde añadir la disposición: ¿cambió fn_inicio_seccion_guardar?';
    END IF;

    -- El FICHERO no está aquí a propósito: lo pone fn_inicio_seccion_imagen.
    -- La pestaña nueva se calcula del enlace ya validado, no se copia tal cual.
    def := replace(def, ancla, ancla
        || E'\n           -- Cómo se enseña la sección y la imagen de al lado. El fichero NO'
        || E'\n           -- está aquí: lo pone fn_inicio_seccion_imagen, porque este UPDATE'
        || E'\n           -- escribe todos sus campos y lo borraría al guardar cualquier otra cosa.'
        || E'\n           disposicion   = ecommerce.fn_validar_opcion(p_datos ->> ''disposicion'','
        || E'\n                               ARRAY[''sola'', ''izquierda'', ''derecha''], ''La disposición de la sección''),'
        || E'\n           imagen_alt    = ecommerce.fn_validar_texto(p_datos ->> ''imagen_alt'','
        || E'\n                               ''El texto de la imagen'', 120),'
        || E'\n           imagen_enlace = ecommerce.fn_validar_enlace(p_datos ->> ''imagen_enlace'','
        || E'\n                               ''El enlace de la imagen''),'
        || E'\n           imagen_nueva_pestana = ecommerce.fn_nueva_pestana('
        || E'\n                               ecommerce.fn_validar_enlace(p_datos ->> ''imagen_enlace'', ''El enlace de la imagen''),'
        || E'\n                               (p_datos ->> ''imagen_nueva_pestana'')::boolean),');

    EXECUTE def;
    RAISE NOTICE 'Guardar ya acepta la disposición, el texto y el enlace de la imagen.';
END
$guardar$;

-- ----------------------------------------------------------------------------
-- 4. LA PUERTA DEL FICHERO
-- ----------------------------------------------------------------------------
-- Toca SÓLO la columna del fichero, y devuelve el que había para que PHP pueda
-- borrarlo del disco cuando ya no lo use nadie. Con null, se quita la imagen.
CREATE OR REPLACE FUNCTION ecommerce.fn_inicio_seccion_imagen(
    p_clave          text,
    p_imagen         text,
    p_usuario_id     bigint      DEFAULT NULL,
    p_usuario_login  varchar     DEFAULT NULL,
    p_usuario_nombre varchar     DEFAULT NULL,
    p_ip_address     inet        DEFAULT NULL,
    p_user_agent     text        DEFAULT NULL,
    p_request_id     uuid        DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'ecommerce', 'auditoria'
AS $function$
DECLARE
    v_nombre   text;
    v_anterior text;
    v_nueva    text := nullif(btrim(COALESCE(p_imagen, '')), '');
BEGIN
    PERFORM ecommerce.fn_contexto_auditoria('ecommerce.inicio_secciones',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    SELECT nombre, imagen INTO v_nombre, v_anterior
      FROM ecommerce.inicio_secciones WHERE clave = btrim(COALESCE(p_clave, ''));
    IF v_nombre IS NULL THEN
        RAISE EXCEPTION 'La sección «%» no existe', p_clave USING ERRCODE = 'P0013';
    END IF;

    UPDATE ecommerce.inicio_secciones
       SET imagen = v_nueva
     WHERE clave = btrim(p_clave);

    RETURN jsonb_build_object('success', true,
        'message', CASE WHEN v_nueva IS NULL THEN format('Imagen quitada de «%s»', v_nombre)
                        ELSE format('Imagen guardada en «%s»', v_nombre) END,
        -- El de antes, para que PHP lo borre del disco si no lo usa nadie más
        'anterior', v_anterior,
        'data', (ecommerce.fn_inicio_listar() -> 'data'));
END;
$function$;

-- ----------------------------------------------------------------------------
-- 5. EL LISTADO DEL CRM
-- ----------------------------------------------------------------------------
DO $listar$
DECLARE
    def   text;
    ancla text := E'                                           s.descuento_color,     s.descuento_texto),';
BEGIN
    SELECT pg_get_functiondef(p.oid) INTO def
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'ecommerce' AND p.proname = 'fn_inicio_listar';

    IF def IS NULL THEN
        RAISE EXCEPTION 'No está ecommerce.fn_inicio_listar';
    END IF;

    IF strpos(def, 'fn_seccion_imagen') > 0 THEN
        RAISE NOTICE 'El listado ya traía la imagen de al lado: no lo toco.';
        RETURN;
    END IF;

    IF strpos(def, ancla) = 0 THEN
        RAISE EXCEPTION 'No encontré dónde colgarlo: ¿cambió fn_inicio_listar?';
    END IF;

    def := replace(def, ancla, ancla
        || E'\n                       ''imagen'',     ecommerce.fn_seccion_imagen(s.disposicion, s.imagen,'
        || E'\n                                           s.imagen_alt, s.imagen_enlace, s.imagen_nueva_pestana),');

    EXECUTE def;
    RAISE NOTICE 'El listado del CRM ya trae la imagen de al lado.';
END
$listar$;

-- ----------------------------------------------------------------------------
-- 6. LA PORTADA PÚBLICA
-- ----------------------------------------------------------------------------
DO $publica$
DECLARE
    def    text;
    ancla1 text := E'                                            s.descuento_color,     s.descuento_texto) AS tarjeta,';
    ancla2 text := E'                            ''tarjeta'', v.tarjeta,';
BEGIN
    SELECT pg_get_functiondef(p.oid) INTO def
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'ecommerce' AND p.proname = 'fn_inicio_publico';

    IF def IS NULL THEN
        RAISE EXCEPTION 'No está ecommerce.fn_inicio_publico';
    END IF;

    IF strpos(def, 'fn_seccion_imagen') > 0 THEN
        RAISE NOTICE 'La portada pública ya traía la imagen de al lado: no la toco.';
        RETURN;
    END IF;

    IF strpos(def, ancla1) = 0 OR strpos(def, ancla2) = 0 THEN
        RAISE EXCEPTION 'No encontré los dos sitios que hay que tocar: ¿cambió fn_inicio_publico?';
    END IF;

    def := replace(def, ancla1, ancla1
        || E'\n               ecommerce.fn_seccion_imagen(s.disposicion, s.imagen, s.imagen_alt,'
        || E'\n                                           s.imagen_enlace, s.imagen_nueva_pestana) AS imagen,');

    def := replace(def, ancla2, ancla2
        || E'\n                            ''imagen'', v.imagen,');

    EXECUTE def;
    RAISE NOTICE 'La portada pública ya manda la imagen de al lado.';
END
$publica$;

-- ----------------------------------------------------------------------------
-- 7. COMPROBACIÓN
-- ----------------------------------------------------------------------------
DO $comprobar$
DECLARE
    v_id      bigint;
    v_clave   text;
    v_p       bigint;
    v_sola    jsonb;
    v_sinfoto jsonb;
    v_con     jsonb;
    v_publica jsonb;
    v_quitada jsonb;
    v_malo    text := NULL;
BEGIN
    SELECT p.id INTO v_p FROM inventarios.productos p
     WHERE p.deleted_at IS NULL AND p.activo ORDER BY p.id LIMIT 1;
    IF v_p IS NULL THEN
        RAISE NOTICE 'No hay productos activos con los que comprobar; las columnas están.';
        RETURN;
    END IF;

    BEGIN
        v_id    := (ecommerce.fn_producto_secciones_crear('ZZ imagen ' || clock_timestamp())
                    -> 'data' ->> 'id')::bigint;
        v_clave := 'seccion_' || v_id;
        PERFORM ecommerce.fn_producto_seccion_agregar(v_id, jsonb_build_array(v_p));

        SELECT x -> 'imagen' INTO v_sola
          FROM jsonb_array_elements(ecommerce.fn_inicio_listar() -> 'data') x
         WHERE x ->> 'clave' = v_clave;

        -- Disposición SIN fichero: tiene que quedarse en 'sola'
        PERFORM ecommerce.fn_inicio_seccion_guardar(v_clave, jsonb_build_object(
            'disposicion', 'izquierda',
            'imagen_alt', 'Promoción de motos',
            'imagen_enlace', 'https://almacenesespana.com/motos',
            'imagen_nueva_pestana', true));

        SELECT x -> 'imagen' INTO v_sinfoto
          FROM jsonb_array_elements(ecommerce.fn_inicio_listar() -> 'data') x
         WHERE x ->> 'clave' = v_clave;

        -- Y con fichero, ya sale a la izquierda
        PERFORM ecommerce.fn_inicio_seccion_imagen(v_clave, 'zzpruebaclaude.png');

        SELECT x -> 'imagen' INTO v_con
          FROM jsonb_array_elements(ecommerce.fn_inicio_listar() -> 'data') x
         WHERE x ->> 'clave' = v_clave;

        SELECT x -> 'imagen' INTO v_publica
          FROM jsonb_array_elements(ecommerce.fn_inicio_publico() -> 'secciones') x
         WHERE (x ->> 'id')::bigint = v_id;

        -- Quitarla devuelve el nombre del fichero de antes
        v_quitada := ecommerce.fn_inicio_seccion_imagen(v_clave, NULL);

        -- Un enlace con «javascript:» no puede entrar
        BEGIN
            PERFORM ecommerce.fn_inicio_seccion_guardar(v_clave, jsonb_build_object(
                'imagen_enlace', 'javascript:alert(1)'));
            v_malo := 'entró un javascript: como enlace';
        EXCEPTION WHEN SQLSTATE 'P0015' THEN
            NULL;
        END;

        RAISE EXCEPTION 'deshacer' USING ERRCODE = 'P0099';
    EXCEPTION WHEN SQLSTATE 'P0099' THEN
        NULL;
    END;

    IF v_sola IS NULL THEN
        RAISE EXCEPTION 'El listado del CRM no trae la llave «imagen»';
    END IF;
    IF v_sola ->> 'lado' <> 'sola' OR v_sola ->> 'archivo' IS NOT NULL THEN
        RAISE EXCEPTION 'Recién creada, la sección tendría que salir sola y sin imagen: %', v_sola;
    END IF;
    IF v_sinfoto ->> 'lado' <> 'sola' THEN
        RAISE EXCEPTION 'Sin fichero no puede haber lado, y salió «%»: %', v_sinfoto ->> 'lado', v_sinfoto;
    END IF;
    -- Pero lo elegido no se pierde: subir la imagen después lo recupera
    IF v_sinfoto ->> 'elegido' <> 'izquierda' THEN
        RAISE EXCEPTION 'Lo elegido se guarda aunque todavía no haya fichero: %', v_sinfoto;
    END IF;
    IF v_sinfoto ->> 'alt' <> 'Promoción de motos'
       OR v_sinfoto ->> 'enlace' <> 'https://almacenesespana.com/motos'
       OR (v_sinfoto ->> 'nueva_pestana')::boolean IS NOT TRUE THEN
        RAISE EXCEPTION 'El texto y el enlace sí se guardan aunque no haya fichero: %', v_sinfoto;
    END IF;
    IF v_con ->> 'lado' <> 'izquierda' OR v_con ->> 'archivo' <> 'zzpruebaclaude.png' THEN
        RAISE EXCEPTION 'Con fichero tendría que salir a la izquierda: %', v_con;
    END IF;
    IF v_publica IS DISTINCT FROM v_con THEN
        RAISE EXCEPTION 'La tienda recibe otra cosa que el CRM: % vs %', v_publica, v_con;
    END IF;
    IF v_quitada ->> 'anterior' <> 'zzpruebaclaude.png' THEN
        RAISE EXCEPTION 'Al quitarla hay que saber qué fichero borrar del disco: %', v_quitada -> 'anterior';
    END IF;
    IF v_malo IS NOT NULL THEN
        RAISE EXCEPTION '%', v_malo;
    END IF;
    IF EXISTS (SELECT 1 FROM ecommerce.inicio_secciones WHERE clave = v_clave) THEN
        RAISE EXCEPTION 'La sección de prueba se quedó en la portada';
    END IF;

    RAISE NOTICE 'Comprobado: sin fichero la sección sale sola, con él toma el lado elegido, la tienda recibe lo mismo que el CRM, al quitarla se sabe qué borrar y un «javascript:» no entra. No quedó nada.';
END
$comprobar$;

COMMIT;
