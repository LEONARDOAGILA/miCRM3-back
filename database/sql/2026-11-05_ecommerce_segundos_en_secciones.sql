-- ============================================================================
-- ECOMMERCE · LOS SEGUNDOS TAMBIÉN EN LAS SECCIONES DE PRODUCTOS
-- ============================================================================
-- Fecha: 2026-11-05
--
-- Esta mañana los segundos eran sólo de los banners y la columna se llamaba
-- `banner_segundos`. Ahora una sección de productos también puede pasar sola
-- de tarjeta, así que la columna pasa a llamarse `segundos` a secas: una
-- sección de productos con un campo que se llama «banner» es la clase de
-- nombre que dentro de un año no explica nadie.
--
-- NULL NO SIGNIFICA LO MISMO EN LAS DOS, y es a propósito: es «lo que hace esa
-- sección cuando nadie ha elegido nada».
--
--   · En un banner, rotar cada 5 segundos. Un banner se mueve; que lo haga no
--     es algo que haya que ir a encender.
--   · En una sección de productos, quedarse quieta. La fila se mueve con las
--     flechas, como ha sido siempre, y empezar a moverse sola el día que se
--     publique esto sorprendería a quien no pidió nada.
--
-- Por eso en la pantalla la sección de productos lleva una palanca —«pasa
-- sola» sí o no— y el banner no: en el banner la pregunta es cada cuánto, y en
-- la sección de productos es primero si se mueve.
--
-- Idempotente.
-- ============================================================================
\set ON_ERROR_STOP on

BEGIN;

-- ----------------------------------------------------------------------------
-- 1. LA COLUMNA, CON SU NOMBRE NUEVO
-- ----------------------------------------------------------------------------
DO $columna$
BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.columns
                WHERE table_schema = 'ecommerce' AND table_name = 'inicio_secciones'
                  AND column_name = 'segundos') THEN
        RAISE NOTICE 'La columna ya se llamaba «segundos»: no la toco.';
    ELSIF EXISTS (SELECT 1 FROM information_schema.columns
                   WHERE table_schema = 'ecommerce' AND table_name = 'inicio_secciones'
                     AND column_name = 'banner_segundos') THEN
        ALTER TABLE ecommerce.inicio_secciones RENAME COLUMN banner_segundos TO segundos;
        RAISE NOTICE 'Columna renombrada a «segundos».';
    ELSE
        RAISE EXCEPTION 'No está ni banner_segundos ni segundos en ecommerce.inicio_secciones';
    END IF;

    IF EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'ck_inicio_secciones_banner_segundos') THEN
        ALTER TABLE ecommerce.inicio_secciones
            RENAME CONSTRAINT ck_inicio_secciones_banner_segundos TO ck_inicio_secciones_segundos;
    END IF;
END
$columna$;

COMMENT ON COLUMN ecommerce.inicio_secciones.segundos IS
    'Cada cuántos segundos se mueve sola la sección. NULL = lo que haga de siempre: un banner rota cada 5, una sección de productos se queda quieta.';

-- ----------------------------------------------------------------------------
-- 2. LAS TRES FUNCIONES QUE LA NOMBRABAN
-- ----------------------------------------------------------------------------
-- Cambia el nombre en el cuerpo y nada más: lo que hacían ya estaba bien.
DO $renombrar$
DECLARE
    f   text;
    def text;
BEGIN
    FOREACH f IN ARRAY ARRAY['fn_inicio_seccion_guardar', 'fn_inicio_listar', 'fn_inicio_publico'] LOOP
        SELECT pg_get_functiondef(p.oid) INTO def
          FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
         WHERE n.nspname = 'ecommerce' AND p.proname = f;

        IF def IS NULL THEN
            RAISE EXCEPTION 'No está ecommerce.%', f;
        END IF;

        IF strpos(def, 'banner_segundos') = 0 THEN
            RAISE NOTICE '% ya usaba «segundos»: no la toco.', f;
            CONTINUE;
        END IF;

        EXECUTE replace(def, 'banner_segundos', 'segundos');
        RAISE NOTICE '% ya usa «segundos».', f;
    END LOOP;
END
$renombrar$;

-- ----------------------------------------------------------------------------
-- 3. Y LA SECCIÓN DE PRODUCTOS LOS MANDA A LA TIENDA
-- ----------------------------------------------------------------------------
DO $publico$
DECLARE
    def   text;
    ancla text := E'                            ''id'', v.producto_seccion_id,';
BEGIN
    SELECT pg_get_functiondef(p.oid) INTO def
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'ecommerce' AND p.proname = 'fn_inicio_publico';

    IF def IS NULL THEN
        RAISE EXCEPTION 'No está ecommerce.fn_inicio_publico';
    END IF;

    IF strpos(def, E'''segundos'', v.segundos,\n                            ''botones''') > 0 THEN
        RAISE NOTICE 'La sección de productos ya mandaba los segundos: no la toco.';
        RETURN;
    END IF;

    IF strpos(def, ancla) = 0 THEN
        RAISE EXCEPTION 'No encontré la sección de productos: ¿cambió fn_inicio_publico?';
    END IF;

    def := replace(def, ancla, ancla
        || E'\n                            -- Cada cuántos segundos pasa sola de tarjeta; null = quieta'
        || E'\n                            ''segundos'', v.segundos,');

    EXECUTE def;
    RAISE NOTICE 'La sección de productos ya manda los segundos.';
END
$publico$;

-- ----------------------------------------------------------------------------
-- 4. COMPROBACIÓN
-- ----------------------------------------------------------------------------
DO $comprobar$
DECLARE
    v_id       bigint;
    v_clave    text;
    v_p        bigint;
    v_crm      jsonb;
    v_tienda   jsonb;
    v_quieta   jsonb;
    v_banner   jsonb;
    v_malo     text := NULL;
BEGIN
    SELECT p.id INTO v_p FROM inventarios.productos p
     WHERE p.deleted_at IS NULL AND p.activo ORDER BY p.id LIMIT 1;
    IF v_p IS NULL THEN
        RAISE NOTICE 'No hay productos activos con los que comprobar; la columna y las funciones están.';
        RETURN;
    END IF;

    BEGIN
        v_id    := (ecommerce.fn_producto_secciones_crear('ZZ segundos ' || clock_timestamp())
                    -> 'data' ->> 'id')::bigint;
        v_clave := 'seccion_' || v_id;
        PERFORM ecommerce.fn_producto_seccion_agregar(v_id, jsonb_build_array(v_p));

        -- Recién creada: quieta
        SELECT x INTO v_quieta
          FROM jsonb_array_elements(ecommerce.fn_inicio_publico() -> 'secciones') x
         WHERE (x ->> 'id')::bigint = v_id;

        PERFORM ecommerce.fn_inicio_seccion_guardar(v_clave, jsonb_build_object('segundos', 6));

        SELECT x INTO v_crm
          FROM jsonb_array_elements(ecommerce.fn_inicio_listar() -> 'data') x
         WHERE x ->> 'clave' = v_clave;

        SELECT x INTO v_tienda
          FROM jsonb_array_elements(ecommerce.fn_inicio_publico() -> 'secciones') x
         WHERE (x ->> 'id')::bigint = v_id;

        -- Un minuto y medio sigue sin entrar
        BEGIN
            PERFORM ecommerce.fn_inicio_seccion_guardar(v_clave, jsonb_build_object('segundos', 90));
            v_malo := 'entraron 90 segundos';
        EXCEPTION WHEN SQLSTATE 'P0015' THEN
            NULL;
        END;

        -- Y el banner sigue funcionando como antes
        SELECT x INTO v_banner
          FROM jsonb_array_elements(ecommerce.fn_inicio_publico() -> 'secciones') x
         WHERE x ->> 'clave' = 'banner_principal';

        RAISE EXCEPTION 'deshacer' USING ERRCODE = 'P0099';
    EXCEPTION WHEN SQLSTATE 'P0099' THEN
        NULL;
    END;

    IF v_quieta IS NULL OR v_quieta -> 'segundos' <> 'null'::jsonb THEN
        RAISE EXCEPTION 'Recién creada, una sección de productos tiene que salir quieta: %', v_quieta -> 'segundos';
    END IF;
    IF (v_crm ->> 'segundos')::int <> 6 THEN
        RAISE EXCEPTION 'El CRM no lee los segundos de una sección de productos: %', v_crm -> 'segundos';
    END IF;
    IF (v_tienda ->> 'segundos')::int <> 6 THEN
        RAISE EXCEPTION 'La tienda no los recibe: %', v_tienda;
    END IF;
    IF v_banner IS NULL OR NOT (v_banner ? 'segundos') THEN
        RAISE EXCEPTION 'El banner principal perdió los suyos: %', v_banner;
    END IF;
    IF v_malo IS NOT NULL THEN
        RAISE EXCEPTION '%', v_malo;
    END IF;
    IF EXISTS (SELECT 1 FROM ecommerce.inicio_secciones WHERE clave = v_clave) THEN
        RAISE EXCEPTION 'La sección de prueba se quedó en la portada';
    END IF;

    RAISE NOTICE 'Comprobado: una sección de productos nace quieta, guarda sus segundos, los leen el CRM y la tienda, 90 sigue sin entrar y el banner no perdió los suyos. No quedó nada.';
END
$comprobar$;

COMMIT;
