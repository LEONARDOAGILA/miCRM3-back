-- ============================================================================
-- ECOMMERCE · LA QUINTA MANERA DE ENSEÑAR UNA SECCIÓN: PAGINADA
-- ============================================================================
-- Fecha: 2026-11-06
-- Va DESPUÉS de 2026-11-06_ecommerce_secciones_por_cuerpo.sql.
--
-- Una sección de productos se enseñaba de cuatro maneras —sola, con imagen a
-- un lado, o en carteles—, y las cuatro son UNA FILA que se mueve con las
-- flechas. Con muchos productos eso esconde casi todos: hay que empujar la
-- fila veinte veces para llegar al último.
--
-- LA QUINTA LOS ENSEÑA TODOS, de doce en doce, con un botón «Ver más
-- productos» debajo, como el catálogo:
--
--     sola | izquierda | derecha | cartel | paginada
--
-- `paginada` NO LLEVA IMAGEN DE AL LADO, como `cartel`: lo que cambia es la
-- forma de enseñar las tarjetas, no lo que hay junto a ellas.
--
-- CUÁNTOS SALEN ANTES DEL BOTÓN se elige: `por_pagina`, de 2 a 48. Vacío son
-- doce, que es lo que usa el catálogo de la tienda.
--
-- Idempotente.
-- ============================================================================
\set ON_ERROR_STOP on

BEGIN;

-- ----------------------------------------------------------------------------
-- 1. LA NUEVA DISPOSICIÓN
-- ----------------------------------------------------------------------------
DO $disposicion$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_constraint
                WHERE conname = 'ck_inicio_secciones_disposicion'
                  AND pg_get_constraintdef(oid) LIKE '%paginada%') THEN
        RAISE NOTICE 'La disposición «paginada» ya está admitida.';
        RETURN;
    END IF;

    ALTER TABLE ecommerce.inicio_secciones
        DROP CONSTRAINT IF EXISTS ck_inicio_secciones_disposicion;
    ALTER TABLE ecommerce.inicio_secciones
        ADD CONSTRAINT ck_inicio_secciones_disposicion
        CHECK (disposicion IS NULL
            OR disposicion IN ('sola', 'izquierda', 'derecha', 'cartel', 'paginada'));

    RAISE NOTICE 'La disposición «paginada» ya está admitida.';
END
$disposicion$;

-- ----------------------------------------------------------------------------
-- 2. CUÁNTOS SALEN ANTES DEL BOTÓN
-- ----------------------------------------------------------------------------
ALTER TABLE ecommerce.inicio_secciones
    ADD COLUMN IF NOT EXISTS por_pagina smallint;

DO $porpagina$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'ck_inicio_secciones_por_pagina') THEN
        -- Menos de dos no es una página y más de cuarenta y ocho es la lista
        -- entera: para eso está el botón
        ALTER TABLE ecommerce.inicio_secciones
            ADD CONSTRAINT ck_inicio_secciones_por_pagina
            CHECK (por_pagina IS NULL OR (por_pagina BETWEEN 2 AND 48));
    END IF;
END
$porpagina$;

-- ----------------------------------------------------------------------------
-- 3. «paginada» TAMPOCO PIDE IMAGEN
-- ----------------------------------------------------------------------------
-- Como `cartel`: sin fichero, las demás disposiciones caen a 'sola' para no
-- dejar un hueco al lado de los productos; éstas dos no enseñan nada al lado.
CREATE OR REPLACE FUNCTION ecommerce.fn_seccion_imagen(
    p_disposicion text, p_imagen text, p_alt text, p_enlace text, p_nueva_pestana boolean)
 RETURNS jsonb
 LANGUAGE sql
 IMMUTABLE PARALLEL SAFE
AS $function$
    SELECT jsonb_build_object(
        -- SIN FICHERO NO HAY LADO: con 'izquierda' y sin imagen, la tienda
        -- dejaría un hueco al lado de los productos. 'cartel' y 'paginada'
        -- quedan fuera de esa regla porque no enseñan ninguna imagen de al
        -- lado: lo que cambia es la forma de las tarjetas
        'lado', CASE WHEN COALESCE(nullif(btrim(COALESCE(p_disposicion, '')), ''), 'sola')
                          IN ('cartel', 'paginada')
                     THEN COALESCE(nullif(btrim(COALESCE(p_disposicion, '')), ''), 'sola')
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

-- ----------------------------------------------------------------------------
-- 4. GUARDARLA, LISTARLA Y SERVIRLA
-- ----------------------------------------------------------------------------
-- Cirugía sobre las tres funciones: lo que cambia en cada una es una línea, y
-- rehacerlas enteras aquí sería copiar cien líneas que no se tocan.
DO $cirugia$
DECLARE
    v_def text;
    v_cuantas integer := 0;
BEGIN
    -- 4.1 La lista de disposiciones que admite el guardado
    SELECT pg_get_functiondef(p.oid) INTO v_def
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'ecommerce' AND p.proname = 'fn_inicio_seccion_guardar';

    IF v_def IS NULL THEN
        RAISE EXCEPTION 'No está ecommerce.fn_inicio_seccion_guardar';
    END IF;

    IF position('''paginada''' IN v_def) > 0 THEN
        RAISE NOTICE 'Guardar ya admitía «paginada».';
    ELSE
        IF position('ARRAY[''sola'', ''izquierda'', ''derecha'', ''cartel'']' IN v_def) = 0 THEN
            RAISE EXCEPTION 'No encuentro la lista de disposiciones en fn_inicio_seccion_guardar';
        END IF;
        v_def := replace(v_def,
            'ARRAY[''sola'', ''izquierda'', ''derecha'', ''cartel'']',
            'ARRAY[''sola'', ''izquierda'', ''derecha'', ''cartel'', ''paginada'']');

        -- Y el campo nuevo, junto a los segundos, que es el otro número de la
        -- sección. Se escribe donde el UPDATE ya tiene su sitio
        IF position('           forma         = ecommerce.fn_validar_opcion(p_datos ->> ''forma'',' IN v_def) = 0 THEN
            RAISE EXCEPTION 'No encuentro dónde meter `por_pagina` en fn_inicio_seccion_guardar';
        END IF;
        v_def := replace(v_def,
            '           forma         = ecommerce.fn_validar_opcion(p_datos ->> ''forma'',',
            '           -- Cuántas tarjetas salen antes del botón «Ver más'    || E'\n' ||
            '           -- productos». Vacío = doce, el del catálogo'          || E'\n' ||
            '           por_pagina    = ecommerce.fn_validar_entero(p_datos ->> ''por_pagina'','  || E'\n' ||
            '                               ''Cuántos productos por página'', 2, 48),'           || E'\n' ||
            '           forma         = ecommerce.fn_validar_opcion(p_datos ->> ''forma'',');

        EXECUTE v_def;
        v_cuantas := v_cuantas + 1;
    END IF;

    -- 4.2 El listado del CRM
    SELECT pg_get_functiondef(p.oid) INTO v_def
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'ecommerce' AND p.proname = 'fn_inicio_listar';

    IF position('''por_pagina''' IN v_def) > 0 THEN
        RAISE NOTICE 'El listado ya traía `por_pagina`.';
    ELSE
        IF position('''segundos'', s.segundos,' IN v_def) = 0 THEN
            RAISE EXCEPTION 'No encuentro dónde meter `por_pagina` en fn_inicio_listar';
        END IF;
        v_def := replace(v_def, '''segundos'', s.segundos,',
            '''segundos'', s.segundos,' || E'\n                       ' ||
            '''por_pagina'', s.por_pagina,');
        EXECUTE v_def;
        v_cuantas := v_cuantas + 1;
    END IF;

    -- 4.3 Y lo que ve la tienda
    SELECT pg_get_functiondef(p.oid) INTO v_def
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'ecommerce' AND p.proname = 'fn_cuerpo_publico';

    IF position('''por_pagina''' IN v_def) > 0 THEN
        RAISE NOTICE 'La tienda ya recibía `por_pagina`.';
    ELSE
        -- En la rama de las secciones de productos, que es la única que lo usa
        IF position('''segundos'', v.segundos,' IN v_def) = 0 THEN
            RAISE EXCEPTION 'No encuentro dónde meter `por_pagina` en fn_cuerpo_publico';
        END IF;
        v_def := replace(v_def,
            '''segundos'', v.segundos,',
            '''segundos'', v.segundos,' || E'\n                            ' ||
            '-- Cuántas tarjetas antes del botón «Ver más productos»' || E'\n                            ' ||
            '''por_pagina'', v.por_pagina,');

        -- Y el campo tiene que viajar desde la tabla hasta ahí
        IF position('               s.segundos,' IN v_def) = 0 THEN
            RAISE EXCEPTION 'No encuentro `s.segundos` en el SELECT de fn_cuerpo_publico';
        END IF;
        v_def := replace(v_def, '               s.segundos,',
            '               s.segundos, s.por_pagina,');

        EXECUTE v_def;
        v_cuantas := v_cuantas + 1;
    END IF;

    RAISE NOTICE 'Funciones rehechas: %.', v_cuantas;
END
$cirugia$;

-- ----------------------------------------------------------------------------
-- 5. COMPROBACIÓN
-- ----------------------------------------------------------------------------
DO $comprobar$
DECLARE
    v_principal bigint;
    v_fila      bigint;
    v_lista     jsonb;
    v_antes     text;
    v_antes_pp  smallint;
    v_malo      text;
BEGIN
    v_principal := ecommerce.fn_cuerpo_principal_id();

    -- Una sección de productos de verdad, para no inventar uno
    SELECT id INTO v_fila FROM ecommerce.inicio_secciones
     WHERE cuerpo_id = v_principal AND producto_seccion_id IS NOT NULL
       AND ecommerce.fn_inicio_seccion_viva(producto_seccion_id)
     ORDER BY id LIMIT 1;
    IF v_fila IS NULL THEN
        RAISE NOTICE 'No hay secciones de productos: me salto la comprobación.';
        RETURN;
    END IF;

    SELECT disposicion, por_pagina INTO v_antes, v_antes_pp
      FROM ecommerce.inicio_secciones WHERE id = v_fila;

    BEGIN
        -- Entra «paginada» con su número
        PERFORM ecommerce.fn_inicio_seccion_guardar(v_fila, jsonb_build_object(
            'disposicion', 'paginada', 'por_pagina', '8', 'activo', true));

        v_lista := ecommerce.fn_inicio_listar(v_principal) -> 'data';
        IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_lista) s
                        WHERE (s ->> 'id')::bigint = v_fila
                          AND s -> 'imagen' ->> 'lado' = 'paginada'
                          AND (s ->> 'por_pagina')::integer = 8) THEN
            RAISE EXCEPTION 'El CRM no devolvió la sección como paginada de 8: %',
                  (SELECT s FROM jsonb_array_elements(v_lista) s WHERE (s ->> 'id')::bigint = v_fila);
        END IF;

        -- Y la tienda la recibe igual
        IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(
                         ecommerce.fn_cuerpo_publico(NULL) -> 'secciones') s
                        WHERE s ->> 'clave' = 'productos'
                          AND s -> 'imagen' ->> 'lado' = 'paginada'
                          AND (s ->> 'por_pagina')::integer = 8) THEN
            RAISE EXCEPTION 'La tienda no recibe la sección paginada con su número';
        END IF;

        -- Sin fichero sigue siendo paginada: no cae a 'sola' como las de imagen
        IF ecommerce.fn_seccion_imagen('paginada', NULL, NULL, NULL, NULL) ->> 'lado' <> 'paginada' THEN
            RAISE EXCEPTION '«paginada» no puede caer a «sola» por no tener imagen';
        END IF;
        IF ecommerce.fn_seccion_imagen('izquierda', NULL, NULL, NULL, NULL) ->> 'lado' <> 'sola' THEN
            RAISE EXCEPTION 'Una disposición con imagen SÍ tiene que caer a «sola» sin fichero';
        END IF;

        -- Un número fuera de rango se rechaza, no se guarda a medias
        BEGIN
            PERFORM ecommerce.fn_inicio_seccion_guardar(v_fila, jsonb_build_object(
                'disposicion', 'paginada', 'por_pagina', '99', 'activo', true));
            v_malo := 'entró un por_pagina de 99';
        EXCEPTION WHEN SQLSTATE 'P0015' THEN NULL;
        END;

        -- Y una disposición inventada tampoco
        BEGIN
            PERFORM ecommerce.fn_inicio_seccion_guardar(v_fila, jsonb_build_object(
                'disposicion', 'zzclaude', 'activo', true));
            v_malo := COALESCE(v_malo, 'entró una disposición inventada');
        EXCEPTION WHEN SQLSTATE 'P0015' THEN NULL;
        END;

        RAISE EXCEPTION 'deshacer' USING ERRCODE = 'P0099';
    EXCEPTION WHEN SQLSTATE 'P0099' THEN
        NULL;
    END;

    IF v_malo IS NOT NULL THEN
        RAISE EXCEPTION '%', v_malo;
    END IF;
    -- La sección de verdad se quedó como estaba
    IF (SELECT COALESCE(disposicion, '') FROM ecommerce.inicio_secciones WHERE id = v_fila)
       <> COALESCE(v_antes, '') THEN
        RAISE EXCEPTION 'La sección de prueba no volvió a su disposición';
    END IF;

    RAISE NOTICE 'Comprobado: «paginada» entra con su número de tarjetas, llega al CRM y a la tienda, no pide imagen, y un número fuera de rango o una disposición inventada se rechazan. No quedó nada.';
END
$comprobar$;

COMMIT;
