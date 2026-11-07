-- ============================================================================
-- ECOMMERCE · CADA CUÁNTO CAMBIA LA IMAGEN DE UN BANNER
-- ============================================================================
-- Fecha: 2026-11-05
--
-- Hasta hoy el banner cambiaba de imagen cada 5 segundos y ese número vivía en
-- la tienda (INTERVALO_BANNER_MS). Ahora lo elige quien arma la portada, banner
-- por banner: el principal y cada uno de los simples.
--
-- VACÍO SIGNIFICA «EL DE SIEMPRE» y no cero. Una columna NULL es la manera de
-- que un banner al que nadie le ha tocado nada siga rotando como rotaba, y de
-- que el día que la tienda cambie su ritmo de fábrica lo hereden todos los que
-- no hayan elegido uno propio.
--
-- ENTRE 2 Y 60 SEGUNDOS. Por debajo de dos la imagen no llega ni a verse —el
-- navegador todavía la está pintando cuando ya toca la siguiente—, y por
-- encima de un minuto el banner deja de parecer un banner: quien entra ve una
-- imagen fija y se va.
--
-- NO LO MIRAN TODAS LAS SECCIONES: sólo las que tienen galería, que son los
-- banners. En una sección de productos no hay nada que rote, y en un banner
-- «en carteles» tampoco: ahí salen todas las imágenes a la vez.
--
-- Idempotente.
-- ============================================================================
\set ON_ERROR_STOP on

BEGIN;

-- ----------------------------------------------------------------------------
-- 1. LA COLUMNA
-- ----------------------------------------------------------------------------
ALTER TABLE ecommerce.inicio_secciones
    ADD COLUMN IF NOT EXISTS banner_segundos smallint;

DO $reglas$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'ck_inicio_secciones_banner_segundos') THEN
        ALTER TABLE ecommerce.inicio_secciones
            ADD CONSTRAINT ck_inicio_secciones_banner_segundos
            CHECK (banner_segundos IS NULL OR banner_segundos BETWEEN 2 AND 60);
    END IF;
END
$reglas$;

COMMENT ON COLUMN ecommerce.inicio_secciones.banner_segundos IS
    'Cada cuántos segundos cambia la imagen del banner. NULL = el de siempre de la tienda.';

-- ----------------------------------------------------------------------------
-- 2. UN NÚMERO ENTERO, COMPROBADO
-- ----------------------------------------------------------------------------
-- Como fn_validar_color o fn_validar_opcion: vacío es NULL, y lo que no sea un
-- entero dentro del rango no entra. La regla vive aquí y no en PHP ni en la
-- pantalla porque es la base la que tiene que poder decir que no.
CREATE OR REPLACE FUNCTION ecommerce.fn_validar_entero(
    p_valor    text,
    p_etiqueta text,
    p_minimo   integer,
    p_maximo   integer)
 RETURNS integer
 LANGUAGE plpgsql
 IMMUTABLE
AS $function$
DECLARE
    v text := btrim(COALESCE(p_valor, ''));
    n integer;
BEGIN
    IF v = '' THEN
        RETURN NULL;
    END IF;

    IF v !~ '^-?[0-9]{1,9}$' THEN
        RAISE EXCEPTION '%: «%» no es un número entero', p_etiqueta, p_valor
              USING ERRCODE = 'P0015';
    END IF;

    n := v::integer;

    IF n < p_minimo OR n > p_maximo THEN
        RAISE EXCEPTION '%: % no está entre % y %', p_etiqueta, n, p_minimo, p_maximo
              USING ERRCODE = 'P0015';
    END IF;

    RETURN n;
END;
$function$;

COMMENT ON FUNCTION ecommerce.fn_validar_entero(text, text, integer, integer) IS
    'Un entero dentro de un rango, o NULL si no viene. Fuera de rango o no numérico: P0015.';

-- ----------------------------------------------------------------------------
-- 3. GUARDAR
-- ----------------------------------------------------------------------------
DO $guardar$
DECLARE
    def   text;
    ancla text := E'                               ARRAY[''rotativo'', ''carteles''], ''La vista del banner''),';
BEGIN
    SELECT pg_get_functiondef(p.oid) INTO def
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'ecommerce' AND p.proname = 'fn_inicio_seccion_guardar';

    IF def IS NULL THEN
        RAISE EXCEPTION 'No está ecommerce.fn_inicio_seccion_guardar';
    END IF;

    IF strpos(def, 'banner_segundos') > 0 THEN
        RAISE NOTICE 'Guardar ya aceptaba los segundos: no lo toco.';
        RETURN;
    END IF;

    IF strpos(def, ancla) = 0 THEN
        RAISE EXCEPTION 'No encontré dónde añadir los segundos: ¿cambió fn_inicio_seccion_guardar?';
    END IF;

    def := replace(def, ancla, ancla
        || E'\n           -- Cada cuántos segundos cambia la imagen. Vacío = el de la tienda.'
        || E'\n           banner_segundos = ecommerce.fn_validar_entero(p_datos ->> ''banner_segundos'','
        || E'\n                               ''Los segundos del banner'', 2, 60),');

    EXECUTE def;
    RAISE NOTICE 'Guardar ya acepta los segundos del banner.';
END
$guardar$;

-- ----------------------------------------------------------------------------
-- 4. EL LISTADO DEL CRM
-- ----------------------------------------------------------------------------
-- Sin COALESCE a propósito: aquí NULL es un dato —«no he elegido ninguno»— y
-- la pantalla tiene que poder enseñar el campo vacío.
DO $listar$
DECLARE
    def   text;
    ancla text := E'                       ''banner_vista'', COALESCE(nullif(btrim(COALESCE(s.banner_vista, '''')), ''''), ''rotativo''),';
BEGIN
    SELECT pg_get_functiondef(p.oid) INTO def
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'ecommerce' AND p.proname = 'fn_inicio_listar';

    IF def IS NULL THEN
        RAISE EXCEPTION 'No está ecommerce.fn_inicio_listar';
    END IF;

    IF strpos(def, 'banner_segundos') > 0 THEN
        RAISE NOTICE 'El listado ya traía los segundos: no lo toco.';
        RETURN;
    END IF;

    IF strpos(def, ancla) = 0 THEN
        RAISE EXCEPTION 'No encontré dónde añadir los segundos: ¿cambió fn_inicio_listar?';
    END IF;

    def := replace(def, ancla, ancla
        || E'\n                       ''banner_segundos'', s.banner_segundos,');

    EXECUTE def;
    RAISE NOTICE 'El listado del CRM ya trae los segundos.';
END
$listar$;

-- ----------------------------------------------------------------------------
-- 5. LO QUE RECIBE LA TIENDA
-- ----------------------------------------------------------------------------
-- En los DOS banners: el principal y cada uno de los simples.
DO $publico$
DECLARE
    def           text;
    anclaVisibles text := E'               COALESCE(nullif(btrim(COALESCE(s.banner_vista, '''')), ''''), ''rotativo'') AS banner_vista,';
    anclaPrincipal text := E'                            ''imagenes'', COALESCE(ecommerce.fn_galerias_publica(''inicio_banner'') -> ''imagenes'', ''[]''::jsonb))';
    anclaSimple   text := E'                            ''vista'', v.banner_vista,';
BEGIN
    SELECT pg_get_functiondef(p.oid) INTO def
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'ecommerce' AND p.proname = 'fn_inicio_publico';

    IF def IS NULL THEN
        RAISE EXCEPTION 'No está ecommerce.fn_inicio_publico';
    END IF;

    IF strpos(def, 'banner_segundos') > 0 THEN
        RAISE NOTICE 'La tienda ya recibía los segundos: no lo toco.';
        RETURN;
    END IF;

    IF strpos(def, anclaVisibles) = 0 OR strpos(def, anclaPrincipal) = 0 OR strpos(def, anclaSimple) = 0 THEN
        RAISE EXCEPTION 'No encontré dónde añadir los segundos: ¿cambió fn_inicio_publico?';
    END IF;

    def := replace(def, anclaVisibles, anclaVisibles
        || E'\n               s.banner_segundos,');

    -- El principal: los segundos van ANTES de las imágenes, que es lo largo
    def := replace(def, anclaPrincipal,
           E'                            ''segundos'', v.banner_segundos,\n' || anclaPrincipal);

    def := replace(def, anclaSimple, anclaSimple
        || E'\n                            -- Cada cuántos segundos cambia; null = el de la tienda'
        || E'\n                            ''segundos'', v.banner_segundos,');

    EXECUTE def;
    RAISE NOTICE 'La tienda ya recibe los segundos de los dos banners.';
END
$publico$;

-- ----------------------------------------------------------------------------
-- 6. COMPROBACIÓN
-- ----------------------------------------------------------------------------
DO $comprobar$
DECLARE
    v_antes    smallint;
    v_guardado smallint;
    v_crm      jsonb;
    v_tienda   jsonb;
    v_vacio    jsonb;
    v_malo     text := NULL;
BEGIN
    SELECT banner_segundos INTO v_antes
      FROM ecommerce.inicio_secciones WHERE clave = 'banner_principal';

    BEGIN
        -- Siete segundos en el banner principal
        PERFORM ecommerce.fn_inicio_seccion_guardar('banner_principal',
                jsonb_build_object('banner_segundos', 7));

        SELECT banner_segundos INTO v_guardado
          FROM ecommerce.inicio_secciones WHERE clave = 'banner_principal';

        SELECT x INTO v_crm
          FROM jsonb_array_elements(ecommerce.fn_inicio_listar() -> 'data') x
         WHERE x ->> 'clave' = 'banner_principal';

        SELECT x INTO v_tienda
          FROM jsonb_array_elements(ecommerce.fn_inicio_publico() -> 'secciones') x
         WHERE x ->> 'clave' = 'banner_principal';

        -- Borrarlo lo devuelve al de siempre
        PERFORM ecommerce.fn_inicio_seccion_guardar('banner_principal',
                jsonb_build_object('banner_segundos', ''));

        SELECT x INTO v_vacio
          FROM jsonb_array_elements(ecommerce.fn_inicio_publico() -> 'secciones') x
         WHERE x ->> 'clave' = 'banner_principal';

        -- Medio minuto de más no entra
        BEGIN
            PERFORM ecommerce.fn_inicio_seccion_guardar('banner_principal',
                    jsonb_build_object('banner_segundos', 90));
            v_malo := 'entraron 90 segundos';
        EXCEPTION WHEN SQLSTATE 'P0015' THEN
            NULL;
        END;

        -- Ni «rápido»
        BEGIN
            PERFORM ecommerce.fn_inicio_seccion_guardar('banner_principal',
                    jsonb_build_object('banner_segundos', 'rapido'));
            v_malo := COALESCE(v_malo, 'entró un texto como segundos');
        EXCEPTION WHEN SQLSTATE 'P0015' THEN
            NULL;
        END;

        RAISE EXCEPTION 'deshacer' USING ERRCODE = 'P0099';
    EXCEPTION WHEN SQLSTATE 'P0099' THEN
        NULL;
    END;

    IF v_guardado <> 7 THEN
        RAISE EXCEPTION 'Los siete segundos no se guardaron: %', v_guardado;
    END IF;
    IF (v_crm ->> 'banner_segundos')::int <> 7 THEN
        RAISE EXCEPTION 'El CRM no los lee: %', v_crm -> 'banner_segundos';
    END IF;
    IF (v_tienda ->> 'segundos')::int <> 7 THEN
        RAISE EXCEPTION 'La tienda no los recibe: %', v_tienda;
    END IF;
    IF v_vacio -> 'segundos' <> 'null'::jsonb THEN
        RAISE EXCEPTION 'Borrarlos tendría que devolver null, y salió %', v_vacio -> 'segundos';
    END IF;
    IF v_malo IS NOT NULL THEN
        RAISE EXCEPTION '%', v_malo;
    END IF;
    IF (SELECT banner_segundos FROM ecommerce.inicio_secciones WHERE clave = 'banner_principal')
       IS DISTINCT FROM v_antes THEN
        RAISE EXCEPTION 'El banner principal se quedó cambiado';
    END IF;

    RAISE NOTICE 'Comprobado: los segundos se guardan, los lee el CRM, llegan a la tienda, vaciarlos devuelve el ritmo de siempre y ni 90 ni «rapido» entran. El banner principal quedó como estaba.';
END
$comprobar$;

COMMIT;
