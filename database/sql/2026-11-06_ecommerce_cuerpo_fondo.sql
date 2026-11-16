-- ============================================================================
-- ECOMMERCE · EL COLOR DE FONDO DE UNA PÁGINA
-- ============================================================================
-- Fecha: 2026-11-06
-- Va DESPUÉS de 2026-11-06_ecommerce_cuerpos.sql.
--
-- El fondo de las páginas de la tienda es blanco. Cada cuerpo puede llevar el
-- suyo: una página de campaña en gris claro, una de Navidad en crema.
--
-- ES EL FONDO DE LA PÁGINA, NO EL DE LA TIENDA. El color de la tienda —el rojo
-- de los botones y del encabezado— se elige una sola vez en «Encabezado» y vale
-- para todas (`encabezado.config.color_principal`). Éste es de una página.
--
-- VACÍO ES BLANCO, y es lo que hay hoy: el que no ponga nada no nota nada.
--
-- SE GUARDA COMO «#rrggbb» COMPROBADO (`fn_validar_color`, el mismo del rótulo
-- y de los botones): por esta puerta no entra nada a la hoja de estilos de la
-- tienda. Que el color se LEA es otra cosa, y eso lo avisa la pantalla: aquí
-- no se prohíbe un fondo oscuro, porque puede ser justo lo que se quiere.
--
-- Idempotente.
-- ============================================================================
\set ON_ERROR_STOP on

BEGIN;

-- ----------------------------------------------------------------------------
-- 1. LA COLUMNA
-- ----------------------------------------------------------------------------
ALTER TABLE ecommerce.cuerpos
    ADD COLUMN IF NOT EXISTS fondo varchar(7);

DO $fondo$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'ck_cuerpos_fondo') THEN
        ALTER TABLE ecommerce.cuerpos
            ADD CONSTRAINT ck_cuerpos_fondo
            CHECK (fondo IS NULL OR fondo ~ '^#[0-9a-f]{6}$');
    END IF;
END
$fondo$;

COMMENT ON COLUMN ecommerce.cuerpos.fondo IS
    'El fondo de ESA página, «#rrggbb». NULL = blanco, que es lo de siempre.';

-- ----------------------------------------------------------------------------
-- 2. GUARDARLO
-- ----------------------------------------------------------------------------
-- Cirugía sobre `fn_cuerpos_guardar`: una línea en el INSERT y otra en el
-- UPDATE. Rehacer la función entera aquí sería copiar noventa líneas que no se
-- tocan, y la de este fichero se quedaría vieja en cuanto se tocara la otra.
DO $cirugia$
DECLARE
    v_def text;
BEGIN
    SELECT pg_get_functiondef(p.oid) INTO v_def
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'ecommerce' AND p.proname = 'fn_cuerpos_guardar';

    IF v_def IS NULL THEN
        RAISE EXCEPTION 'No está ecommerce.fn_cuerpos_guardar';
    END IF;

    IF position('''fondo''' IN v_def) > 0 THEN
        RAISE NOTICE 'Guardar ya recibía el fondo: no se toca.';
        RETURN;
    END IF;

    -- En el INSERT: la lista de columnas y la de valores
    IF position('INSERT INTO ecommerce.cuerpos (nombre, ruta, categoria_id, marca_id, titulo, descripcion,' IN v_def) = 0 THEN
        RAISE EXCEPTION 'No encuentro el INSERT de fn_cuerpos_guardar';
    END IF;
    v_def := replace(v_def,
        'INSERT INTO ecommerce.cuerpos (nombre, ruta, categoria_id, marca_id, titulo, descripcion,',
        'INSERT INTO ecommerce.cuerpos (nombre, ruta, categoria_id, marca_id, titulo, descripcion, fondo,');
    v_def := replace(v_def,
        '                nullif(btrim(COALESCE(p_datos ->> ''descripcion'', '''')), ''''),',
        '                nullif(btrim(COALESCE(p_datos ->> ''descripcion'', '''')), ''''),' || E'\n' ||
        '                ecommerce.fn_validar_color(p_datos ->> ''fondo'', ''El fondo de la página''),');

    -- Y en el UPDATE
    IF position('               descripcion  = nullif(btrim(COALESCE(p_datos ->> ''descripcion'', '''')), ''''),' IN v_def) = 0 THEN
        RAISE EXCEPTION 'No encuentro el UPDATE de fn_cuerpos_guardar';
    END IF;
    v_def := replace(v_def,
        '               descripcion  = nullif(btrim(COALESCE(p_datos ->> ''descripcion'', '''')), ''''),',
        '               descripcion  = nullif(btrim(COALESCE(p_datos ->> ''descripcion'', '''')), ''''),' || E'\n' ||
        '               -- El fondo de ESTA página; vacío, blanco' || E'\n' ||
        '               fondo        = ecommerce.fn_validar_color(p_datos ->> ''fondo'', ''El fondo de la página''),');

    EXECUTE v_def;
    RAISE NOTICE 'Guardar ya recibe el fondo.';
END
$cirugia$;

-- ----------------------------------------------------------------------------
-- 3. Y DEVOLVERLO: AL CRM Y A LA TIENDA
-- ----------------------------------------------------------------------------
DO $cirugia2$
DECLARE
    v_def text;
    v_hechas integer := 0;
BEGIN
    -- 3.1 El CRM
    SELECT pg_get_functiondef(p.oid) INTO v_def
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'ecommerce' AND p.proname = 'fn_cuerpos_json';

    IF position('''fondo''' IN v_def) > 0 THEN
        RAISE NOTICE 'El CRM ya recibía el fondo.';
    ELSE
        IF position('''descripcion'',  c.descripcion,' IN v_def) = 0 THEN
            RAISE EXCEPTION 'No encuentro dónde meter el fondo en fn_cuerpos_json';
        END IF;
        v_def := replace(v_def, '''descripcion'',  c.descripcion,',
            '''descripcion'',  c.descripcion,' || E'\n        ' ||
            '''fondo'',        c.fondo,');
        EXECUTE v_def;
        v_hechas := v_hechas + 1;
    END IF;

    -- 3.2 La tienda
    SELECT pg_get_functiondef(p.oid) INTO v_def
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'ecommerce' AND p.proname = 'fn_cuerpo_publico';

    IF position('''fondo''' IN v_def) > 0 THEN
        RAISE NOTICE 'La tienda ya recibía el fondo.';
    ELSE
        IF position('''descripcion'', e.descripcion,' IN v_def) = 0 THEN
            RAISE EXCEPTION 'No encuentro dónde meter el fondo en fn_cuerpo_publico';
        END IF;
        v_def := replace(v_def, '''descripcion'', e.descripcion,',
            '''descripcion'', e.descripcion,' || E'\n                       ' ||
            '-- El fondo de la página; null = blanco' || E'\n                       ' ||
            '''fondo'',       e.fondo,');
        EXECUTE v_def;
        v_hechas := v_hechas + 1;
    END IF;

    RAISE NOTICE 'Funciones rehechas: %.', v_hechas;
END
$cirugia2$;

-- ----------------------------------------------------------------------------
-- 4. COMPROBACIÓN
-- ----------------------------------------------------------------------------
DO $comprobar$
DECLARE
    v_id   bigint;
    v_json jsonb;
    v_malo text;
BEGIN
    BEGIN
        -- Con fondo
        v_json := ecommerce.fn_cuerpos_guardar(NULL, jsonb_build_object(
                      'nombre', 'ZZ fondo claude', 'ruta', 'zz-fondo-claude',
                      'fondo', '#F5F5DC')) -> 'data';
        v_id := (v_json ->> 'id')::bigint;

        -- Se guarda en minúsculas, como todos los colores de la casa
        IF v_json ->> 'fondo' <> '#f5f5dc' THEN
            RAISE EXCEPTION 'El fondo no se guardó: %', v_json -> 'fondo';
        END IF;

        -- Y la tienda lo recibe
        IF ecommerce.fn_cuerpo_publico('zz-fondo-claude') -> 'cuerpo' ->> 'fondo' <> '#f5f5dc' THEN
            RAISE EXCEPTION 'La tienda no recibe el fondo: %',
                  ecommerce.fn_cuerpo_publico('zz-fondo-claude') -> 'cuerpo' -> 'fondo';
        END IF;

        -- Quitarlo lo deja en blanco otra vez
        v_json := ecommerce.fn_cuerpos_guardar(v_id, jsonb_build_object(
                      'nombre', 'ZZ fondo claude', 'ruta', 'zz-fondo-claude',
                      'fondo', '')) -> 'data';
        IF v_json ->> 'fondo' IS NOT NULL THEN
            RAISE EXCEPTION 'Vacío tiene que quedar en null (blanco): %', v_json -> 'fondo';
        END IF;

        -- Y lo que no es un color no entra
        BEGIN
            PERFORM ecommerce.fn_cuerpos_guardar(v_id, jsonb_build_object(
                'nombre', 'ZZ fondo claude', 'ruta', 'zz-fondo-claude',
                'fondo', 'rojo; background: url(x)'));
            v_malo := 'entró un fondo que no es un color';
        EXCEPTION WHEN SQLSTATE 'P0015' THEN NULL;
        END;

        RAISE EXCEPTION 'deshacer' USING ERRCODE = 'P0099';
    EXCEPTION WHEN SQLSTATE 'P0099' THEN
        NULL;
    END;

    IF v_malo IS NOT NULL THEN
        RAISE EXCEPTION '%', v_malo;
    END IF;
    IF EXISTS (SELECT 1 FROM ecommerce.cuerpos WHERE nombre LIKE 'ZZ %claude') THEN
        RAISE EXCEPTION 'El cuerpo de prueba se quedó en la base';
    END IF;

    RAISE NOTICE 'Comprobado: el fondo se guarda comprobado y en minúsculas, llega al CRM y a la tienda, vacío vuelve a blanco y lo que no es un color se rechaza. No quedó nada.';
END
$comprobar$;

COMMIT;
