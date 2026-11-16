-- ============================================================================
-- FUERA ESPAÑA MOTOS
-- ============================================================================
-- Era un micro-sitio con pantalla propia en el CRM (editEspanaMotos) y dos
-- páginas en la tienda (/espana-motos y su catálogo). Se quita entero porque
-- ya no se usa: la entrada del menú del CRM se borró el 07/11/2026 y la
-- pantalla llevaba desde entonces sin poder abrirse.
--
-- SE VA TAMBIÉN LA REGLA DE LAS MOTOS. Una moto —un producto de una categoría
-- de España Motos— no se podía meter al carrito: sólo salía «Comprar por
-- WhatsApp». Esa regla miraba estas tablas, así que se fue con ellas: una moto
-- es ahora un producto como cualquier otro.
--
-- QUÉ SE BORRA
--   · Las 3 tablas (espana_motos, _pestanas, _marcas) y sus 2 secuencias.
--   · Las 7 funciones fn_espana_motos_*.
--   · El bloque de España Motos de fn_resumen (la portada del módulo).
--   · Sus dos galerías (espana_motos_banner y espana_motos_tarjetas) con sus
--     3 imágenes. Los FICHEROS de las fotos NO se tocan.
--
-- QUÉ NO SE BORRA
--   · Los enlaces de la tienda que apuntaban ahí («ESPAÑA MOTOS» en el menú de
--     arriba y una fila del pie): son datos suyos y los quita él desde el CRM.
--   · Las marcas ni las categorías: son de inventarios y las usa el catálogo.
--
-- ANTES DE CORRERLA se sacó el respaldo que está al lado:
--   2026-11-08_ecommerce_espana_motos_RESPALDO.sql
-- Ese fichero devuelve las tablas, las funciones, la fila de configuración y
-- las dos galerías tal como estaban.
--
-- Es idempotente: correrla dos veces no falla ni cambia nada la segunda.
-- ============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. LA PORTADA DEL MÓDULO
-- ---------------------------------------------------------------------------
-- El bloque nunca llegó a contar nada: preguntaba por `espana_motos_marca` y
-- `espana_motos_pestana`, en singular, y las tablas son en plural. El
-- to_regclass daba NULL y el IF no entraba jamás. Se va igual.
DO $portada$
DECLARE
    v_def text;
BEGIN
    SELECT pg_get_functiondef(p.oid) INTO v_def
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'ecommerce' AND p.proname = 'fn_resumen';

    IF v_def IS NULL THEN
        RAISE NOTICE 'No hay fn_resumen: no había nada que quitarle.';
        RETURN;
    END IF;

    IF v_def NOT LIKE '%espana_motos%' THEN
        RAISE NOTICE 'fn_resumen ya no hablaba de España Motos.';
        RETURN;
    END IF;

    v_def := replace(v_def,
'    IF to_regclass(''ecommerce.espana_motos_marca'') IS NOT NULL THEN
        EXECUTE ''SELECT count(*) FILTER (WHERE emm_eliminado_en IS NULL) FROM ecommerce.espana_motos_marca'' INTO n;
        EXECUTE ''SELECT count(*) FILTER (WHERE emp_eliminado_en IS NULL) FROM ecommerce.espana_motos_pestana'' INTO m;
        v := v || jsonb_build_object(''espana_motos'', jsonb_build_object(''marcas'', n, ''pestanas'', m));
    END IF;

', '');

    IF v_def LIKE '%espana_motos%' THEN
        RAISE EXCEPTION 'El bloque de España Motos de fn_resumen no es el que se esperaba: revísalo a mano'
            USING ERRCODE = 'P0015';
    END IF;

    EXECUTE v_def;
    RAISE NOTICE 'fn_resumen: bloque de España Motos quitado.';
END;
$portada$;

-- ---------------------------------------------------------------------------
-- 2. LAS FUNCIONES
-- ---------------------------------------------------------------------------
-- Por el nombre Y la firma: DROP FUNCTION sin argumentos falla si hay dos
-- versiones de la misma, y aquí se quieren todas.
DO $funciones$
DECLARE
    v_f record;
    v_n integer := 0;
BEGIN
    FOR v_f IN
        SELECT p.oid::regprocedure AS firma
          FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
         WHERE n.nspname = 'ecommerce' AND p.proname LIKE 'fn\_espana\_motos%'
    LOOP
        EXECUTE 'DROP FUNCTION ' || v_f.firma;
        v_n := v_n + 1;
    END LOOP;
    RAISE NOTICE 'Funciones borradas: %.', v_n;
END;
$funciones$;

-- ---------------------------------------------------------------------------
-- 3. LAS TABLAS
-- ---------------------------------------------------------------------------
-- CASCADE se lleva sus secuencias, sus índices y sus claves. No hay nada
-- fuera de España Motos que apunte a estas tablas: lo que ellas apuntaban
-- (galerias, inventarios.marcas) va al revés y no se toca.
DROP TABLE IF EXISTS ecommerce.espana_motos_marcas   CASCADE;
DROP TABLE IF EXISTS ecommerce.espana_motos_pestanas CASCADE;
DROP TABLE IF EXISTS ecommerce.espana_motos          CASCADE;

-- Por si alguna secuencia quedó suelta (se crearon con la tabla, pero si
-- alguien las separó alguna vez, CASCADE no las alcanza)
DO $secuencias$
DECLARE
    v_s record;
    v_n integer := 0;
BEGIN
    FOR v_s IN
        SELECT schemaname, sequencename FROM pg_sequences
         WHERE schemaname = 'ecommerce' AND sequencename LIKE 'espana\_motos%'
    LOOP
        EXECUTE format('DROP SEQUENCE %I.%I', v_s.schemaname, v_s.sequencename);
        v_n := v_n + 1;
    END LOOP;
    IF v_n > 0 THEN
        RAISE NOTICE 'Secuencias sueltas borradas: %.', v_n;
    END IF;
END;
$secuencias$;

-- ---------------------------------------------------------------------------
-- 4. LAS GALERÍAS SUYAS
-- ---------------------------------------------------------------------------
-- Primero las imágenes: la clave ajena lo pide, y además así se puede contar
-- cuántas se fueron.
DO $galerias$
DECLARE
    v_imagenes integer;
    v_galerias integer;
BEGIN
    DELETE FROM ecommerce.galerias_imagenes i
     USING ecommerce.galerias g
     WHERE g.id = i.galeria_id AND g.clave LIKE 'espana\_motos%';
    GET DIAGNOSTICS v_imagenes = ROW_COUNT;

    DELETE FROM ecommerce.galerias WHERE clave LIKE 'espana\_motos%';
    GET DIAGNOSTICS v_galerias = ROW_COUNT;

    RAISE NOTICE 'Galerías borradas: % (con % imagen(es)).', v_galerias, v_imagenes;
END;
$galerias$;

-- ---------------------------------------------------------------------------
-- COMPROBACIÓN
-- ---------------------------------------------------------------------------
DO $comprobar$
DECLARE
    v_tablas    integer;
    v_funciones integer;
    v_galerias  integer;
    v_resumen   boolean;
    v_enlaces   integer;
BEGIN
    SELECT count(*) INTO v_tablas
      FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'ecommerce' AND c.relname LIKE 'espana\_motos%';

    SELECT count(*) INTO v_funciones
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'ecommerce' AND p.proname LIKE 'fn\_espana\_motos%';

    SELECT count(*) INTO v_galerias
      FROM ecommerce.galerias WHERE clave LIKE 'espana\_motos%';

    SELECT COALESCE(bool_or(pg_get_functiondef(p.oid) LIKE '%espana_motos%'), false) INTO v_resumen
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'ecommerce' AND p.proname = 'fn_resumen';

    IF v_tablas > 0 OR v_funciones > 0 OR v_galerias > 0 OR v_resumen THEN
        RAISE EXCEPTION 'Quedó algo: % tabla(s)/secuencia(s), % función(es), % galería(s), fn_resumen=%',
            v_tablas, v_funciones, v_galerias, v_resumen USING ERRCODE = 'P0015';
    END IF;

    -- Esto no es un error: son datos suyos, y los quita él desde el CRM
    SELECT count(*) INTO v_enlaces
      FROM (SELECT enlace FROM ecommerce.encabezado_enlaces
            UNION ALL SELECT enlace FROM ecommerce.pie_enlaces) e
     WHERE e.enlace ILIKE '%motos%';

    RAISE NOTICE 'Comprobado: no queda nada de España Motos en la base.';
    IF v_enlaces > 0 THEN
        RAISE NOTICE 'OJO: siguen % enlace(s) a /motos en el encabezado o el pie. Se quitan desde el CRM.', v_enlaces;
    END IF;
END;
$comprobar$;

COMMIT;
