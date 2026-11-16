-- ============================================================================
-- ECOMMERCE · CÓMO SE ENSEÑA UN BANNER: ROTANDO O EN CARTELES
-- ============================================================================
-- Fecha: 2026-11-02
--
-- Cada banner pasa a tener dos formas de verse:
--
--     rotativo   la de siempre: una imagen a la vez, que va rotando
--     carteles   todas a la vez, en los mismos carteles verticales que
--                «Categorías en promoción», pero SIN rótulo, sin nombre y sin
--                botón: sólo la imagen
--
-- LA GRACIA ES QUE NO CAMBIA NADA MÁS. Las imágenes son las mismas, con su
-- vigencia, su orden y —lo que hace útil esta vista— SU PROPIO ENLACE: cada
-- imagen ya se configura con «a dónde lleva», así que en carteles cada una
-- lleva a su sitio. Es la misma función del banner, enseñada de otra forma.
--
-- ES DE CADA BANNER, no de todos: uno puede ir rotando y el de al lado en
-- carteles. Por eso vive en la fila de la portada y no en la galería.
--
-- NULL ES «rotativo», no un hueco: los banners que ya existen siguen como
-- estaban sin tener que tocarlos.
--
-- Idempotente.
-- ============================================================================
\set ON_ERROR_STOP on

BEGIN;

-- ----------------------------------------------------------------------------
-- 1. LA COLUMNA
-- ----------------------------------------------------------------------------
ALTER TABLE ecommerce.inicio_secciones
    ADD COLUMN IF NOT EXISTS banner_vista varchar(12);

DO $reglas$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'ck_inicio_secciones_banner_vista') THEN
        ALTER TABLE ecommerce.inicio_secciones
            ADD CONSTRAINT ck_inicio_secciones_banner_vista
            CHECK (banner_vista IS NULL OR banner_vista IN ('rotativo', 'carteles'));
    END IF;
END
$reglas$;

-- ----------------------------------------------------------------------------
-- 2. GUARDAR
-- ----------------------------------------------------------------------------
DO $guardar$
DECLARE
    def   text;
    ancla text := E'           disposicion   = ecommerce.fn_validar_opcion(p_datos ->> ''disposicion'',\n                               ARRAY[''sola'', ''izquierda'', ''derecha''], ''La disposición de la sección''),';
BEGIN
    SELECT pg_get_functiondef(p.oid) INTO def
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'ecommerce' AND p.proname = 'fn_inicio_seccion_guardar';

    IF def IS NULL THEN
        RAISE EXCEPTION 'No está ecommerce.fn_inicio_seccion_guardar';
    END IF;

    IF strpos(def, 'banner_vista') > 0 THEN
        RAISE NOTICE 'Guardar ya aceptaba la vista del banner: no lo toco.';
        RETURN;
    END IF;

    IF strpos(def, ancla) = 0 THEN
        RAISE EXCEPTION 'No encontré dónde añadirla: ¿cambió fn_inicio_seccion_guardar?';
    END IF;

    def := replace(def, ancla, ancla
        || E'\n           -- Cómo se enseña un banner. Sólo lo miran las secciones con'
        || E'\n           -- galería; en las demás se guarda y no lo lee nadie.'
        || E'\n           banner_vista  = ecommerce.fn_validar_opcion(p_datos ->> ''banner_vista'','
        || E'\n                               ARRAY[''rotativo'', ''carteles''], ''La vista del banner''),');

    EXECUTE def;
    RAISE NOTICE 'Guardar ya acepta la vista del banner.';
END
$guardar$;

-- ----------------------------------------------------------------------------
-- 3. EL LISTADO DEL CRM
-- ----------------------------------------------------------------------------
DO $listar$
DECLARE
    def   text;
    ancla text := E'                       ''es_banner'',  s.galeria_id IS NOT NULL,';
BEGIN
    SELECT pg_get_functiondef(p.oid) INTO def
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'ecommerce' AND p.proname = 'fn_inicio_listar';

    IF def IS NULL THEN
        RAISE EXCEPTION 'No está ecommerce.fn_inicio_listar';
    END IF;

    IF strpos(def, 'banner_vista') > 0 THEN
        RAISE NOTICE 'El listado ya traía la vista del banner: no lo toco.';
        RETURN;
    END IF;

    IF strpos(def, ancla) = 0 THEN
        RAISE EXCEPTION 'No encontré dónde colgarla: ¿cambió fn_inicio_listar?';
    END IF;

    -- Resuelto, como el alto: que la pantalla tenga que acordarse de que NULL
    -- es «rotativo» es la manera de que un día se olvide
    def := replace(def, ancla, ancla
        || E'\n                       ''banner_vista'', COALESCE(nullif(btrim(COALESCE(s.banner_vista, '''')), ''''), ''rotativo''),');

    EXECUTE def;
    RAISE NOTICE 'El listado del CRM ya trae la vista del banner.';
END
$listar$;

-- ----------------------------------------------------------------------------
-- 4. LA PORTADA PÚBLICA
-- ----------------------------------------------------------------------------
DO $publica$
DECLARE
    def    text;
    ancla1 text := E'        SELECT s.clave, s.hasta, s.orden, s.producto_seccion_id, g.clave AS galeria_clave,';
    ancla2 text := E'                   WHEN v.galeria_clave IS NOT NULL THEN\n                        jsonb_build_object(''clave'', ''banner_simple'',\n                            ''imagenes'', COALESCE(ecommerce.fn_galerias_publica(v.galeria_clave) -> ''imagenes'', ''[]''::jsonb))';
BEGIN
    SELECT pg_get_functiondef(p.oid) INTO def
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'ecommerce' AND p.proname = 'fn_inicio_publico';

    IF def IS NULL THEN
        RAISE EXCEPTION 'No está ecommerce.fn_inicio_publico';
    END IF;

    IF strpos(def, 'banner_vista') > 0 THEN
        RAISE NOTICE 'La portada pública ya mandaba la vista del banner: no la toco.';
        RETURN;
    END IF;

    IF strpos(def, ancla1) = 0 OR strpos(def, ancla2) = 0 THEN
        RAISE EXCEPTION 'No encontré los dos sitios: ¿cambió fn_inicio_publico?';
    END IF;

    def := replace(def, ancla1,
        E'        SELECT s.clave, s.hasta, s.orden, s.producto_seccion_id, g.clave AS galeria_clave,\n'
        || E'               COALESCE(nullif(btrim(COALESCE(s.banner_vista, '''')), ''''), ''rotativo'') AS banner_vista,');

    def := replace(def, ancla2,
        E'                   WHEN v.galeria_clave IS NOT NULL THEN\n'
        || E'                        jsonb_build_object(''clave'', ''banner_simple'',\n'
        || E'                            -- Rotando o en carteles. La tienda pinta una cosa u\n'
        || E'                            -- otra con las MISMAS imágenes y sus mismos enlaces.\n'
        || E'                            ''vista'', v.banner_vista,\n'
        || E'                            ''imagenes'', COALESCE(ecommerce.fn_galerias_publica(v.galeria_clave) -> ''imagenes'', ''[]''::jsonb))');

    EXECUTE def;
    RAISE NOTICE 'La portada pública ya manda la vista del banner.';
END
$publica$;

-- ----------------------------------------------------------------------------
-- 5. COMPROBACIÓN
-- ----------------------------------------------------------------------------
DO $comprobar$
DECLARE
    v_clave   text;
    v_fila    jsonb;
    v_publica jsonb;
    v_antes   text;
BEGIN
    SELECT clave, banner_vista INTO v_clave, v_antes
      FROM ecommerce.inicio_secciones WHERE galeria_id IS NOT NULL ORDER BY orden LIMIT 1;
    IF v_clave IS NULL THEN
        RAISE NOTICE 'No hay banners con los que comprobar; la columna está.';
        RETURN;
    END IF;

    -- Recién puesta, todas tienen que salir como estaban: rotando
    SELECT x INTO v_fila
      FROM jsonb_array_elements(ecommerce.fn_inicio_listar() -> 'data') x
     WHERE x ->> 'clave' = v_clave;
    IF v_fila ->> 'banner_vista' <> COALESCE(v_antes, 'rotativo') THEN
        RAISE EXCEPTION 'Sin elegir nada tendría que seguir como estaba (%): %',
              COALESCE(v_antes, 'rotativo'), v_fila ->> 'banner_vista';
    END IF;

    BEGIN
        PERFORM ecommerce.fn_inicio_seccion_guardar(v_clave,
                jsonb_build_object('banner_vista', 'carteles'));

        SELECT x INTO v_fila
          FROM jsonb_array_elements(ecommerce.fn_inicio_listar() -> 'data') x
         WHERE x ->> 'clave' = v_clave;

        SELECT x INTO v_publica
          FROM jsonb_array_elements(ecommerce.fn_inicio_publico() -> 'secciones') x
         WHERE x ->> 'clave' = 'banner_simple'
           AND jsonb_array_length(COALESCE(x -> 'imagenes', '[]'::jsonb)) > 0
         LIMIT 1;

        RAISE EXCEPTION 'deshacer' USING ERRCODE = 'P0099';
    EXCEPTION WHEN SQLSTATE 'P0099' THEN
        NULL;
    END;

    IF v_fila ->> 'banner_vista' <> 'carteles' THEN
        RAISE EXCEPTION 'No se guardó la vista: %', v_fila ->> 'banner_vista';
    END IF;
    IF v_publica IS NULL OR NOT (v_publica ? 'vista') THEN
        RAISE EXCEPTION 'La tienda no recibe la vista: %', v_publica;
    END IF;
    -- Y las imágenes siguen viajando igual, con su enlace
    IF jsonb_array_length(v_publica -> 'imagenes') = 0 THEN
        RAISE EXCEPTION 'Se perdieron las imágenes del banner';
    END IF;
    IF NOT (v_publica -> 'imagenes' -> 0 ? 'enlace') THEN
        RAISE EXCEPTION 'Las imágenes tienen que seguir trayendo su enlace: %',
              v_publica -> 'imagenes' -> 0;
    END IF;
    IF (SELECT banner_vista FROM ecommerce.inicio_secciones WHERE clave = v_clave)
       IS DISTINCT FROM v_antes THEN
        RAISE EXCEPTION 'La prueba cambió la vista de un banner de verdad';
    END IF;

    RAISE NOTICE 'Comprobado: la vista se guarda, llega a la tienda, las imágenes siguen con su enlace y sin elegir nada los banners de antes siguen rotando. No quedó nada.';
END
$comprobar$;

COMMIT;
