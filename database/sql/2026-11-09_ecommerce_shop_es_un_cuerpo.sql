-- ============================================================================
-- /shop DEJA DE SER UNA PANTALLA A PELO Y PASA A SER UNA PÁGINA
-- ============================================================================
-- /shop era una ruta escrita en `app.routes.ts` y nada más: no tenía fila en
-- ninguna tabla, así que no había dónde guardarle un color. Para configurarla
-- había dos caminos: una pantalla nueva en el CRM con su propio juego de
-- veinte perillas —las mismas que ya existen, duplicadas—, o convertirla en un
-- cuerpo como las demás. Se eligió lo segundo: todo en cuerpos.
--
-- ----------------------------------------------------------------------------
-- EL CATÁLOGO PASA A SER UNA SECCIÓN
-- ----------------------------------------------------------------------------
-- Hasta hoy el catálogo de una página salía de `cuerpos.catalogo`, un booleano,
-- y la tienda lo pintaba DEBAJO de todas las secciones, sin orden ni estilo
-- propios. Ahora es una sección más, con clave `catalogo`:
--
--   · se coloca donde se quiera dentro de la página, como las demás;
--   · usa las perillas que ya existen en `inicio_secciones` —los colores de la
--     tarjeta, los cuatro botones, la etiqueta, el descuento, cuántos por
--     tanda—, así que se edita con el editor de secciones de siempre;
--   · y se enciende y se apaga sola.
--
-- LA CASILLA «catálogo» DEL CUERPO SIGUE VALIENDO: ahora es el atajo que crea
-- o apaga esa sección, para que el gesto que ya existe en el CRM siga
-- funcionando y no haya dos sitios donde decir lo mismo.
--
-- APAGAR NO BORRA. Si se quita el catálogo de una página, la sección se apaga
-- pero se queda con sus colores: volver a encenderlo los recupera. Borrarla
-- los perdería sin avisar.
--
-- ----------------------------------------------------------------------------
-- QUÉ TOCA
-- ----------------------------------------------------------------------------
-- 1. `cuerpos.fijo`: la página de la tienda no se puede borrar ni mudar de
--    dirección. Hay ~20 enlaces apuntando a /shop.
-- 2. `fn_cuerpos_validar` suelta la palabra `shop`, que estaba reservada.
-- 3. `fn_cuerpos_eliminar` y `fn_cuerpos_guardar` respetan `fijo`.
-- 4. `fn_cuerpo_catalogo_sincronizar`, nueva: la casilla crea o apaga.
-- 5. `fn_inicio_fuente` (las dos versiones) sabe qué es una sección `catalogo`.
-- 6. `fn_cuerpo_publico` la manda a la tienda con sus colores.
-- 7. Y se siembra la página «Tienda» en /shop con su catálogo encendido.
--
-- ----------------------------------------------------------------------------
-- SE EJECUTA A MANO. Para ensayar sin guardar, cambiar el COMMIT del final por
-- ROLLBACK: la comprobación se hace igual y no queda rastro.
-- ============================================================================

BEGIN;

-- El mismo parcheador con portero de la migración de `en_paginaweb`: si el
-- texto que se espera no está, revienta en vez de dejar la función intacta
-- diciendo que todo fue bien.
CREATE OR REPLACE FUNCTION pg_temp.parchar(p_texto text, p_viejo text, p_nuevo text, p_donde text)
RETURNS text
LANGUAGE plpgsql
AS $parchar$
DECLARE
    v_veces int;
BEGIN
    v_veces := (length(p_texto) - length(replace(p_texto, p_viejo, '')))
               / GREATEST(length(p_viejo), 1);

    IF v_veces <> 1 THEN
        RAISE EXCEPTION 'Parche de %: esperaba UNA aparición de «%…» y encontré %',
              p_donde, left(p_viejo, 70), v_veces;
    END IF;

    RETURN replace(p_texto, p_viejo, p_nuevo);
END;
$parchar$;


-- ============================================================================
-- 1. LAS PÁGINAS QUE LA TIENDA NECESITA
-- ============================================================================
ALTER TABLE ecommerce.cuerpos
    ADD COLUMN IF NOT EXISTS fijo boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN ecommerce.cuerpos.fijo IS
    'Página que la tienda necesita para funcionar: no se puede borrar ni cambiar de '
    'dirección. Lo demás —título, fondo, secciones— se edita como en cualquier otra. '
    'La usa /shop, a donde apuntan el menú, el buscador y los filtros.';


-- ============================================================================
-- 2. `shop` DEJA DE ESTAR RESERVADA
-- ============================================================================
-- Estaba en la lista de direcciones tomadas porque `app.routes.ts` tenía una
-- pantalla con ese nombre y la pantalla gana a la página. Ahora /shop ES la
-- página, así que la ruta a pelo desaparece de la tienda y la palabra queda
-- libre. Las demás siguen reservadas.
-- ============================================================================
DO $validar$
DECLARE
    v_def text;
BEGIN
    v_def := pg_get_functiondef(
        'ecommerce.fn_cuerpos_validar(bigint,text,text,bigint,bigint)'::regprocedure);

    v_def := pg_temp.parchar(v_def,
        E'    c_tomadas text[] := ARRAY[\n        ''shop'', ''cart'', ''login''',
        E'    c_tomadas text[] := ARRAY[\n        -- ''shop'' NO está: desde el 09/11/2026 es una página de verdad\n'
        || E'        -- (`ecommerce.cuerpos`, fija), no una pantalla de app.routes.ts\n'
        || E'        ''cart'', ''login''',
        'fn_cuerpos_validar (lista de reservadas)');

    EXECUTE v_def;
END;
$validar$;


-- ============================================================================
-- 3. `fijo` SE RESPETA AL BORRAR Y AL GUARDAR
-- ============================================================================
DO $eliminar$
DECLARE
    v_def text;
BEGIN
    v_def := pg_get_functiondef(
        'ecommerce.fn_cuerpos_eliminar(bigint,bigint,character varying,character varying,inet,text,uuid)'::regprocedure);

    v_def := pg_temp.parchar(v_def,
        E'    v_nombre    text;\n    v_principal boolean;',
        E'    v_nombre    text;\n    v_principal boolean;\n    v_fijo      boolean;',
        'fn_cuerpos_eliminar (declaración)');

    v_def := pg_temp.parchar(v_def,
        E'    SELECT nombre, principal INTO v_nombre, v_principal\n'
        || E'      FROM ecommerce.cuerpos WHERE id = p_id AND deleted_at IS NULL;',
        E'    SELECT nombre, principal, fijo INTO v_nombre, v_principal, v_fijo\n'
        || E'      FROM ecommerce.cuerpos WHERE id = p_id AND deleted_at IS NULL;',
        'fn_cuerpos_eliminar (lectura)');

    v_def := pg_temp.parchar(v_def,
        E'    SELECT count(*) INTO v_cuantas FROM ecommerce.inicio_secciones WHERE cuerpo_id = p_id;',
        E'    -- Las páginas que la tienda necesita tampoco: /shop es el destino de\n'
        || E'    -- los enlaces del menú, del buscador y de todos los filtros.\n'
        || E'    IF v_fijo THEN\n'
        || E'        RAISE EXCEPTION ''No se puede borrar «%»: la tienda la necesita para funcionar'', v_nombre\n'
        || E'              USING ERRCODE = ''P0015'';\n'
        || E'    END IF;\n\n'
        || E'    SELECT count(*) INTO v_cuantas FROM ecommerce.inicio_secciones WHERE cuerpo_id = p_id;',
        'fn_cuerpos_eliminar (portero)');

    EXECUTE v_def;
END;
$eliminar$;


-- ============================================================================
-- 4. LA CASILLA DEL CATÁLOGO CREA O APAGA LA SECCIÓN
-- ============================================================================
CREATE OR REPLACE FUNCTION ecommerce.fn_cuerpo_catalogo_sincronizar(
    p_cuerpo_id bigint,
    p_quiere    boolean)
RETURNS void
LANGUAGE plpgsql
AS $function$
DECLARE
    v_orden integer;
BEGIN
    IF COALESCE(p_quiere, false) THEN
        -- Al final de lo que haya: es la parte larga de la página y encima de
        -- los escaparates los dejaría sin ver.
        SELECT COALESCE(max(orden), 0) + 1 INTO v_orden
          FROM ecommerce.inicio_secciones WHERE cuerpo_id = p_cuerpo_id;

        INSERT INTO ecommerce.inicio_secciones (cuerpo_id, clave, nombre, orden, activo)
        VALUES (p_cuerpo_id, 'catalogo', 'Catálogo', v_orden, true)
        ON CONFLICT (cuerpo_id, clave) DO UPDATE SET activo = true;
    ELSE
        -- SE APAGA, NO SE BORRA: borrarla se llevaría los colores que se le
        -- hubieran puesto, y volver a encender el catálogo los daría por
        -- perdidos sin decir nada.
        UPDATE ecommerce.inicio_secciones
           SET activo = false
         WHERE cuerpo_id = p_cuerpo_id AND clave = 'catalogo';
    END IF;
END;
$function$;

COMMENT ON FUNCTION ecommerce.fn_cuerpo_catalogo_sincronizar(bigint, boolean) IS
    'Pone al día la sección «catalogo» de una página según su casilla. Encender crea '
    'la sección (o la vuelve a encender); apagar NO la borra, para no perder sus colores.';


DO $guardar$
DECLARE
    v_def text;
BEGIN
    v_def := pg_get_functiondef(
        'ecommerce.fn_cuerpos_guardar(bigint,jsonb,bigint,character varying,character varying,inet,text,uuid)'::regprocedure);

    v_def := pg_temp.parchar(v_def,
        E'    v_principal boolean := false;\n    v_sembradas integer := 0;',
        E'    v_principal boolean := false;\n    v_fijo      boolean := false;\n'
        || E'    v_ruta_vieja text;\n    v_sembradas integer := 0;',
        'fn_cuerpos_guardar (declaración)');

    v_def := pg_temp.parchar(v_def,
        E'        SELECT principal INTO v_principal FROM ecommerce.cuerpos\n'
        || E'         WHERE id = p_id AND deleted_at IS NULL;',
        E'        SELECT principal, fijo, ruta INTO v_principal, v_fijo, v_ruta_vieja\n'
        || E'          FROM ecommerce.cuerpos\n'
        || E'         WHERE id = p_id AND deleted_at IS NULL;',
        'fn_cuerpos_guardar (lectura)');

    -- El portero de la dirección, justo antes de validar
    v_def := pg_temp.parchar(v_def,
        E'    PERFORM ecommerce.fn_cuerpos_validar(p_id, v_nombre, v_ruta, v_categoria, v_marca);',
        E'    -- Una página fija no se muda: /shop es a donde apuntan el menú, el\n'
        || E'    -- buscador y cada filtro, y moverla los rompería todos de golpe. Lo\n'
        || E'    -- demás —nombre, título, fondo, secciones— se cambia con libertad.\n'
        || E'    IF v_fijo AND v_ruta IS DISTINCT FROM v_ruta_vieja THEN\n'
        || E'        RAISE EXCEPTION ''«%» es una página que la tienda necesita: su dirección «/%» no se puede cambiar'',\n'
        || E'              v_nombre, v_ruta_vieja USING ERRCODE = ''P0015'';\n'
        || E'    END IF;\n\n'
        || E'    PERFORM ecommerce.fn_cuerpos_validar(p_id, v_nombre, v_ruta, v_categoria, v_marca);',
        'fn_cuerpos_guardar (portero de la ruta)');

    -- Y la sección del catálogo al día, tanto al crear como al modificar
    v_def := pg_temp.parchar(v_def,
        E'    RETURN jsonb_build_object(''success'', true,\n'
        || E'        ''message'', CASE',
        E'    -- El catálogo es una SECCIÓN; la casilla sólo la crea o la apaga\n'
        || E'    PERFORM ecommerce.fn_cuerpo_catalogo_sincronizar(\n'
        || E'        v_id, COALESCE((p_datos ->> ''catalogo'')::boolean, false));\n\n'
        || E'    RETURN jsonb_build_object(''success'', true,\n'
        || E'        ''message'', CASE',
        'fn_cuerpos_guardar (sincronizar)');

    EXECUTE v_def;
END;
$guardar$;


-- ============================================================================
-- 5. EL CRM SABE QUÉ ES UNA SECCIÓN «catalogo»
-- ============================================================================
-- `fn_inicio_fuente` dice de dónde saca sus datos cada sección, para pintarlo
-- en la lista del CRM. Sin esto, el catálogo saldría como «pendiente: le falta
-- su fuente», que es justo lo contrario de lo que pasa.
--
-- Hay DOS versiones de la función (una vieja de dos parámetros y la de tres);
-- se parchean las dos, porque no está claro cuál llama cada pantalla.
-- ============================================================================
DO $fuente$
DECLARE
    v_firma text;
    v_def   text;
BEGIN
    FOREACH v_firma IN ARRAY ARRAY[
        'ecommerce.fn_inicio_fuente(text,bigint)',
        'ecommerce.fn_inicio_fuente(text,bigint,text)']
    LOOP
        v_def := pg_get_functiondef(v_firma::regprocedure);

        v_def := pg_temp.parchar(v_def,
            E'        WHEN p_clave = ''mosaico'' THEN',
            E'        -- El catálogo no se llena en ninguna pantalla: son TODOS los\n'
            || E'        -- productos publicados, y lo que se elige aquí es su pinta\n'
            || E'        WHEN p_clave = ''catalogo'' THEN\n'
            || E'            jsonb_build_object(''tipo'', ''catalogo'', ''pantalla'', ''allProductos'')\n'
            || E'        WHEN p_clave = ''mosaico'' THEN',
            v_firma);

        EXECUTE v_def;
    END LOOP;
END;
$fuente$;


-- ============================================================================
-- 6. LA TIENDA RECIBE LA SECCIÓN CON SUS COLORES
-- ============================================================================
-- Va ANTES de `ELSE NULL`, que es donde caen las claves que todavía no saben
-- de dónde sacar datos.
--
-- NO LLEVA `productos`, `imagenes`, `categorias` NI `marcas` a propósito: el
-- filtro de abajo tira las secciones que traen una de esas listas vacía, y el
-- catálogo no trae lista ninguna —sus productos los pide la tienda, paginados—.
-- Con una lista vacía se caería siempre y /shop saldría en blanco.
-- ============================================================================
DO $publico$
DECLARE
    v_def text;
BEGIN
    v_def := pg_get_functiondef('ecommerce.fn_cuerpo_publico(text)'::regprocedure);

    v_def := pg_temp.parchar(v_def,
        E'                   -- Las demás todavía no tienen de dónde sacar datos. Se',
        E'                   -- EL CATÁLOGO. Sus productos NO van aquí: los pide la\n'
        || E'                   -- tienda, paginados, porque son cientos. Lo que viaja es\n'
        || E'                   -- cómo se pinta y de qué habla la página, que sale del\n'
        || E'                   -- cuerpo (sin categoría ni marca: todo el catálogo).\n'
        || E'                   WHEN v.clave = ''catalogo'' THEN\n'
        || E'                        jsonb_build_object(''clave'', ''catalogo'',\n'
        || E'                            -- Cuántas tarjetas antes de «Ver más productos»\n'
        || E'                            ''por_pagina'', v.por_pagina,\n'
        || E'                            ''botones'', v.botones,\n'
        || E'                            ''tarjeta'', v.tarjeta)\n'
        || E'                   -- Las demás todavía no tienen de dónde sacar datos. Se',
        'fn_cuerpo_publico (rama del catálogo)');

    EXECUTE v_def;
END;
$publico$;


-- ============================================================================
-- 7. LA PÁGINA «Tienda», EN /shop
-- ============================================================================
-- Se siembra aquí y no a mano para que exista sí o sí: sin ella, /shop se
-- queda sin catálogo en cuanto la tienda deje de tener su ruta a pelo.
--
-- SIN CATEGORÍA NI MARCA: eso es lo que significa «todo el catálogo». Las
-- páginas de categoría (`/tecnologia`, `/audio`) sí las llevan, y por eso su
-- catálogo sale acotado.
--
-- Y SIN TÍTULO NI TEXTO: el encabezado de un cuerpo es para una página de
-- categoría o de campaña, donde dice de qué va. Aquí sobra, porque el catálogo
-- ya se encabeza solo en cuanto se elige algo —«Inicio / Productos / Línea
-- Blanca»— y se leían dos títulos seguidos. Lo que se escriba desde el CRM se
-- respeta; sembrarlo era inventarle a nadie un rótulo.
-- ============================================================================
DO $sembrar$
DECLARE
    v_id bigint;
BEGIN
    SELECT id INTO v_id FROM ecommerce.cuerpos
     WHERE ruta = 'shop' AND deleted_at IS NULL;

    IF v_id IS NULL THEN
        INSERT INTO ecommerce.cuerpos (nombre, ruta, titulo, descripcion,
                                       catalogo, activo, fijo)
        VALUES ('Tienda', 'shop', NULL, NULL,
                true, true, true)
        RETURNING id INTO v_id;

        RAISE NOTICE 'Creada la página «Tienda» en /shop (id %)', v_id;
    ELSE
        UPDATE ecommerce.cuerpos
           SET fijo = true, activo = true, catalogo = true
         WHERE id = v_id;

        RAISE NOTICE 'La página de /shop ya existía (id %); queda fija y encendida', v_id;
    END IF;

    -- Su sección de catálogo, encendida
    PERFORM ecommerce.fn_cuerpo_catalogo_sincronizar(v_id, true);
END;
$sembrar$;


-- ============================================================================
-- COMPROBACIÓN — no escribe nada
-- ============================================================================
DO $comprobar$
DECLARE
    v_falta    text[] := '{}';
    v_id       bigint;
    v_pagina   jsonb;
    v_catalogo jsonb;
BEGIN
    -- ---------- La columna ----------
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                    WHERE table_schema = 'ecommerce' AND table_name = 'cuerpos'
                      AND column_name = 'fijo') THEN
        v_falta := array_append(v_falta, 'no se creó cuerpos.fijo');
    END IF;

    -- ---------- La página ----------
    SELECT id INTO v_id FROM ecommerce.cuerpos
     WHERE ruta = 'shop' AND deleted_at IS NULL AND fijo AND activo;
    IF v_id IS NULL THEN
        v_falta := array_append(v_falta, 'no hay página fija y encendida en /shop');
    END IF;

    -- ---------- Su sección ----------
    IF v_id IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM ecommerce.inicio_secciones
         WHERE cuerpo_id = v_id AND clave = 'catalogo' AND activo) THEN
        v_falta := array_append(v_falta, 'la página de /shop no tiene su sección «catalogo» encendida');
    END IF;

    -- ---------- Y que la tienda la recibe ----------
    v_pagina := ecommerce.fn_cuerpo_publico('shop');
    IF v_pagina IS NULL THEN
        v_falta := array_append(v_falta, 'fn_cuerpo_publico(''shop'') no devuelve nada');
    ELSE
        SELECT s INTO v_catalogo
          FROM jsonb_array_elements(v_pagina -> 'secciones') s
         WHERE s ->> 'clave' = 'catalogo';

        IF v_catalogo IS NULL THEN
            v_falta := array_append(v_falta,
                'la tienda no recibe la sección «catalogo» de /shop (secciones: '
                || COALESCE((SELECT string_agg(s ->> 'clave', ', ')
                               FROM jsonb_array_elements(v_pagina -> 'secciones') s), 'ninguna') || ')');
        ELSIF NOT (v_catalogo ? 'tarjeta' AND v_catalogo ? 'botones') THEN
            v_falta := array_append(v_falta, 'la sección «catalogo» llega sin `tarjeta` o sin `botones`');
        END IF;
    END IF;

    -- ---------- La palabra `shop` quedó libre ----------
    -- SE PREGUNTA POR EL COMPORTAMIENTO, no por el texto: buscar «shop» en el
    -- código de la función lo encuentra en el COMENTARIO que explica que ya no
    -- está reservada, y la comprobación fallaba por haber hecho bien el
    -- trabajo. Se valida con el id de la propia página, para que no salte el
    -- «ya hay un cuerpo en esa dirección», que es otra cosa.
    BEGIN
        PERFORM ecommerce.fn_cuerpos_validar(v_id, 'Tienda', 'shop', NULL, NULL);
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM LIKE '%ya es de una pantalla%' THEN
            v_falta := array_append(v_falta, '`shop` sigue reservada como pantalla de la tienda');
        ELSE
            v_falta := array_append(v_falta, 'fn_cuerpos_validar rechaza /shop: ' || SQLERRM);
        END IF;
    END;

    -- ---------- Los porteros ----------
    BEGIN
        PERFORM ecommerce.fn_cuerpos_eliminar(v_id, NULL, 'prueba', 'prueba', NULL, NULL, NULL);
        v_falta := array_append(v_falta, 'se pudo BORRAR la página fija de /shop');
    EXCEPTION WHEN sqlstate 'P0015' THEN
        NULL;   -- lo esperado
    END;

    IF EXISTS (SELECT 1 FROM ecommerce.cuerpos WHERE id = v_id AND deleted_at IS NOT NULL) THEN
        v_falta := array_append(v_falta, 'la página de /shop acabó en la papelera');
    END IF;

    -- ---------- El veredicto ----------
    IF cardinality(v_falta) > 0 THEN
        RAISE EXCEPTION E'LA MIGRACIÓN NO QUEDÓ BIEN:\n  · %', array_to_string(v_falta, E'\n  · ');
    END IF;

    RAISE NOTICE '/shop es la página % y la tienda ya recibe su sección de catálogo.', v_id;
END;
$comprobar$;

COMMIT;
