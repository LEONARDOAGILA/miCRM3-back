-- ============================================================================
-- FUERA PESO Y MEDIDAS DEL PRODUCTO
-- ============================================================================
-- Fecha: 2026-10-29
--
-- `peso_kg`, `alto_cm`, `ancho_cm` y `profundidad_cm` salen de
-- `inventarios.productos`: desde que las características tienen UNIDAD y TIPO
-- DE DATO, el peso y las medidas se llevan ahí como cualquier otra magnitud,
-- y tenerlas además como columnas era el mismo dato en dos sitios.
--
-- LO QUE HABÍA DENTRO: alto, ancho y fondo estaban vacíos en los 15
-- productos. El peso estaba relleno en TODOS, y queda guardado —con un
-- script listo para volver a meterlo como característica— en
-- `2026-10-29_productos_pesos_respaldo.sql`. Este script no lo borra sin más:
-- antes de soltar las columnas hay que haber leído aquél.
--
-- LAS FUNCIONES NO SE REESCRIBEN A MANO. Son dos de doscientas líneas y
-- copiarlas para quitar cuatro parámetros es la mejor forma de perder algo
-- por el camino. Se vuelcan con `pg_get_functiondef`, se les quitan los
-- cuatro parámetros de la cabecera y las líneas del cuerpo que los nombran
-- —están todas aisladas, comprobado— y se vuelven a crear.
--
-- Idempotente: si las columnas ya no están, no hace nada.
-- ============================================================================
\set ON_ERROR_STOP on

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. LAS FUNCIONES, SIN ESOS CUATRO
-- ---------------------------------------------------------------------------
DO $quitar$
DECLARE
    r        record;
    def      text;
    campo    text;
    v_viejas text[] := '{}';
BEGIN
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                    WHERE table_schema = 'inventarios' AND table_name = 'productos'
                      AND column_name = 'peso_kg') THEN
        RAISE NOTICE 'Las columnas ya no están: no hay nada que hacer.';
        RETURN;
    END IF;

    FOR r IN SELECT p.oid, p.proname,
                    p.oid::regprocedure::text AS firma
               FROM pg_proc p
               JOIN pg_namespace n ON n.oid = p.pronamespace
              WHERE n.nspname = 'inventarios'
                AND p.proname IN ('fn_productos_crear', 'fn_productos_modificar', 'fn_productos_json')
    LOOP
        def := pg_get_functiondef(r.oid);

        -- a) Los cuatro parámetros de la cabecera, con su DEFAULT si lo traen
        FOREACH campo IN ARRAY ARRAY['p_peso_kg', 'p_alto_cm', 'p_ancho_cm', 'p_profundidad_cm'] LOOP
            def := regexp_replace(def, ',\s*' || campo || '\s+numeric(\s+DEFAULT[^,)]*)?', '', 'g');
        END LOOP;

        -- b) Las líneas del cuerpo que los nombran. Van todas solas: el
        --    jsonb_build_object, la lista de columnas del INSERT, la de
        --    valores y los SET del UPDATE.
        def := (SELECT string_agg(l, E'\n' ORDER BY i)
                  FROM regexp_split_to_table(def, E'\n') WITH ORDINALITY AS t(l, i)
                 WHERE l !~ '(peso_kg|alto_cm|ancho_cm|profundidad_cm)');

        -- c) Y la coma que pueda quedar colgando antes de un paréntesis
        def := regexp_replace(def, ',(\s*\))', E'\\1', 'g');

        EXECUTE def;
        RAISE NOTICE 'regenerada: %', r.proname;

        -- Las dos que cambian de firma dejan la vieja viva: se apunta para
        -- borrarla después (ahora no, que `def` todavía la está mirando).
        IF r.proname IN ('fn_productos_crear', 'fn_productos_modificar') THEN
            v_viejas := v_viejas || r.firma;
        END IF;
    END LOOP;

    FOREACH campo IN ARRAY v_viejas LOOP
        EXECUTE 'DROP FUNCTION IF EXISTS ' || campo;
        RAISE NOTICE 'borrada la vieja: %', campo;
    END LOOP;
END
$quitar$;

-- ---------------------------------------------------------------------------
-- 2. LAS COLUMNAS
-- ---------------------------------------------------------------------------
ALTER TABLE inventarios.productos
    DROP COLUMN IF EXISTS peso_kg,
    DROP COLUMN IF EXISTS alto_cm,
    DROP COLUMN IF EXISTS ancho_cm,
    DROP COLUMN IF EXISTS profundidad_cm;

-- ---------------------------------------------------------------------------
-- 3. QUE NO QUEDE NADIE NOMBRÁNDOLAS
-- ---------------------------------------------------------------------------
DO $comprobar$
DECLARE v_quedan text;
BEGIN
    SELECT string_agg(n.nspname || '.' || p.proname, ', ') INTO v_quedan
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname NOT IN ('pg_catalog', 'information_schema')
       AND p.prosrc ~ '(peso_kg|alto_cm|ancho_cm|profundidad_cm)';

    IF v_quedan IS NOT NULL THEN
        RAISE EXCEPTION 'Todavía las nombran: %', v_quedan;
    END IF;
END
$comprobar$;

SELECT 'productos: ' || count(*) || ' columnas' FROM information_schema.columns
 WHERE table_schema = 'inventarios' AND table_name = 'productos';

COMMIT;
