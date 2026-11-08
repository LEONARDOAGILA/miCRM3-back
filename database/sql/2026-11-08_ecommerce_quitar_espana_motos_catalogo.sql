-- ============================================================================
-- FUERA ESPAÑA MOTOS (2): LO QUE QUEDABA EN EL CATÁLOGO
-- ============================================================================
-- Continuación de 2026-11-08_ecommerce_quitar_espana_motos.sql. Aquélla quitó
-- las tablas, y con eso DEJÓ ROTA la búsqueda del catálogo: fn_tienda_productos
-- llamaba a fn_tienda_motos_categorias(), que leía espana_motos_pestanas. La
-- tienda contestaba «No pudimos cargar los productos» en /shop entero.
--
-- No saltó antes porque esa función no se llama fn_espana_motos_*: el filtro de
-- las motos vivía dentro del catálogo, no en el micro-sitio.
--
-- QUÉ HACE
--   · fn_tienda_productos: se le quita el filtro `motos=solo` entero —el
--     parámetro, el CTE y el WHERE—. Era lo que servía /espana-motos/catalogo.
--   · fn_tienda_motos_categorias: se borra.
--   · fn_cuerpos_validar: 'espana-motos' deja de ser una dirección reservada,
--     porque ya no hay ninguna pantalla con ese nombre. Desde ahora un cuerpo
--     del CRM puede llamarse así.
--
-- Idempotente: la segunda vez avisa y no toca nada.
-- ============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. LA BÚSQUEDA DEL CATÁLOGO
-- ---------------------------------------------------------------------------
DO $catalogo$
DECLARE
    v_def text;
    v_antes text;
BEGIN
    SELECT pg_get_functiondef(p.oid) INTO v_def
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'ecommerce' AND p.proname = 'fn_tienda_productos';

    IF v_def IS NULL THEN
        RAISE EXCEPTION 'No existe ecommerce.fn_tienda_productos' USING ERRCODE = 'P0015';
    END IF;

    IF v_def NOT ILIKE '%motos%' THEN
        RAISE NOTICE 'fn_tienda_productos ya no hablaba de motos.';
        RETURN;
    END IF;

    v_antes := v_def;

    -- El parámetro del filtro (es el último de la lista: se va con su coma)
    v_def := replace(v_def,
'                                                                                     AS por_pagina,
           (COALESCE(p_filtros ->> ''motos'', '''') = ''solo'')                            AS solo_motos
),',
'                                                                                     AS por_pagina
),');

    -- El CTE con las categorías de las motos
    v_def := replace(v_def,
'motos AS (
    SELECT CASE WHEN (SELECT solo_motos FROM param)
                THEN ecommerce.fn_tienda_motos_categorias()
                ELSE NULL::bigint[] END AS ramas
),
', '');

    -- Y el recorte que dejaba fuera todo lo que no fuera moto
    v_def := replace(v_def,
'      FROM base b
     WHERE (SELECT ramas FROM motos) IS NULL
        OR b.categoria_id = ANY (SELECT unnest(m2.ramas) FROM motos m2)
),',
'      FROM base b
),');

    IF v_def = v_antes OR v_def ILIKE '%motos%' THEN
        RAISE EXCEPTION 'El filtro de motos de fn_tienda_productos no es el que se esperaba: revísalo a mano'
            USING ERRCODE = 'P0015';
    END IF;

    EXECUTE v_def;
    RAISE NOTICE 'fn_tienda_productos: filtro de motos quitado.';
END;
$catalogo$;

DROP FUNCTION IF EXISTS ecommerce.fn_tienda_motos_categorias();

-- ---------------------------------------------------------------------------
-- 2. LA DIRECCIÓN RESERVADA
-- ---------------------------------------------------------------------------
DO $cuerpos$
DECLARE
    v_def text;
BEGIN
    SELECT pg_get_functiondef(p.oid) INTO v_def
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'ecommerce' AND p.proname = 'fn_cuerpos_validar';

    IF v_def IS NULL OR v_def NOT LIKE '%espana-motos%' THEN
        RAISE NOTICE 'fn_cuerpos_validar ya no reservaba «espana-motos».';
        RETURN;
    END IF;

    v_def := replace(v_def,
        '''documentos'', ''tiendas'', ''conocenos'', ''espana-motos'', ''vista-previa'',',
        '''documentos'', ''tiendas'', ''conocenos'', ''vista-previa'',');

    IF v_def LIKE '%espana-motos%' THEN
        RAISE EXCEPTION 'La lista de direcciones de fn_cuerpos_validar no es la esperada: revísala a mano'
            USING ERRCODE = 'P0015';
    END IF;

    EXECUTE v_def;
    RAISE NOTICE 'fn_cuerpos_validar: «espana-motos» ya no está reservada.';
END;
$cuerpos$;

-- ---------------------------------------------------------------------------
-- COMPROBACIÓN
-- ---------------------------------------------------------------------------
-- Además de mirar que no quede el nombre, SE BUSCA DE VERDAD: es lo que estaba
-- roto, y una función que compila puede seguir fallando al ejecutarse.
DO $comprobar$
DECLARE
    v_quedan integer;
    v_json   jsonb;
    v_total  integer;
BEGIN
    SELECT count(*) INTO v_quedan
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE p.prokind = 'f' AND n.nspname NOT IN ('pg_catalog', 'information_schema')
       AND p.prosrc ILIKE '%motos%';

    IF v_quedan > 0 THEN
        RAISE EXCEPTION 'Todavía hay % función(es) que hablan de motos', v_quedan USING ERRCODE = 'P0015';
    END IF;

    v_json := ecommerce.fn_tienda_productos('{"per_page":"2"}'::jsonb);
    v_total := (v_json ->> 'total')::int;

    IF v_total IS NULL THEN
        RAISE EXCEPTION 'La búsqueda del catálogo no devolvió un total: %', left(v_json::text, 200)
            USING ERRCODE = 'P0015';
    END IF;

    RAISE NOTICE 'Comprobado: el catálogo vuelve a buscar (% productos visibles).', v_total;
END;
$comprobar$;

COMMIT;
