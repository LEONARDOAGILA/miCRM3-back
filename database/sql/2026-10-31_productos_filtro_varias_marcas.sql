-- ============================================================================
-- EL LISTADO DE PRODUCTOS ACEPTA VARIAS MARCAS A LA VEZ
-- ============================================================================
-- Fecha: 2026-10-31
--
-- `fn_productos_listar_paginado` filtraba por UNA marca (`p_marca_id bigint`).
-- En un catálogo de electrodomésticos «ver las Samsung Y las LG» es una
-- pregunta normal, y con un filtro de uno en uno hay que mirar dos veces y
-- sumar a mano.
--
-- Pasa a `p_marca_ids bigint[]`:
--
--     NULL o {}  -> todas las marcas, como antes con NULL
--     {3}        -> una, exactamente igual que antes
--     {3,7,11}   -> cualquiera de ellas
--
-- LA FUNCIÓN NO SE REESCRIBE A MANO. Son noventa y cuatro líneas y copiarlas
-- para cambiar dos es la mejor forma de perder algo por el camino: se vuelca
-- con `pg_get_functiondef`, se cambian el parámetro y la condición, y se
-- vuelve a crear. Como cambia la firma, la vieja se queda viva y hay que
-- borrarla aparte; si no, PostgreSQL tendría dos candidatas y la llamada del
-- controlador se volvería ambigua.
--
-- Idempotente: si ya está hecho, no hace nada.
-- ============================================================================
\set ON_ERROR_STOP on

BEGIN;

DO $cambiar$
DECLARE
    r        record;
    def      text;
    v_vieja  text;
BEGIN
    SELECT p.oid, p.oid::regprocedure::text AS firma
      INTO r
      FROM pg_proc p
      JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'inventarios'
       AND p.proname = 'fn_productos_listar_paginado'
       AND pg_get_function_identity_arguments(p.oid) LIKE '%p_marca_id bigint%';

    IF NOT FOUND THEN
        RAISE NOTICE 'Ya acepta varias marcas: no hay nada que hacer.';
        RETURN;
    END IF;

    v_vieja := r.firma;
    def := pg_get_functiondef(r.oid);

    -- a) El parámetro
    def := replace(def,
        'p_marca_id bigint DEFAULT NULL::bigint',
        'p_marca_ids bigint[] DEFAULT NULL::bigint[]');

    -- b) La condición. El `cardinality = 0` es para que un array VACÍO
    --    signifique «todas», que es lo que manda el front cuando se quitan
    --    todas las marcas del selector: sin eso no saldría ningún producto.
    def := regexp_replace(def,
        '\(p_marca_id\s+IS NULL OR p\.marca_id = p_marca_id\)',
        '(p_marca_ids IS NULL OR cardinality(p_marca_ids) = 0 OR p.marca_id = ANY(p_marca_ids))',
        'g');

    -- OJO con LIKE aquí: el guión bajo es COMODÍN, así que
    -- LIKE '%p_marca_id %' casa también con «p.marca_id », que es
    -- correcto y debe quedarse. Se compara literalmente con strpos.
    IF strpos(def, 'p_marca_id ') > 0 OR strpos(def, 'p_marca_id)') > 0 THEN
        RAISE EXCEPTION 'Quedó alguna referencia a p_marca_id sin cambiar';
    END IF;

    EXECUTE def;
    EXECUTE 'DROP FUNCTION IF EXISTS ' || v_vieja;
    RAISE NOTICE 'regenerada, y borrada la vieja: %', v_vieja;
END
$cambiar$;

-- Que de verdad haga lo que dice
DO $comprobar$
DECLARE
    v_todas  bigint;
    v_una    bigint;
    v_dos    bigint;
    v_vacio  bigint;
    v_m1     bigint;
    v_m2     bigint;
BEGIN
    SELECT marca_id INTO v_m1
      FROM inventarios.productos
     WHERE deleted_at IS NULL AND marca_id IS NOT NULL
     GROUP BY marca_id ORDER BY count(*) DESC LIMIT 1;

    SELECT marca_id INTO v_m2
      FROM inventarios.productos
     WHERE deleted_at IS NULL AND marca_id IS NOT NULL AND marca_id <> v_m1
     GROUP BY marca_id ORDER BY count(*) DESC LIMIT 1;

    IF v_m1 IS NULL OR v_m2 IS NULL THEN
        RAISE NOTICE 'No hay dos marcas con productos: me salto la comprobación.';
        RETURN;
    END IF;

    v_todas := (inventarios.fn_productos_listar_paginado(1, 1, '', NULL, NULL, '{}'::jsonb) -> 'meta' ->> 'total')::bigint;
    v_vacio := (inventarios.fn_productos_listar_paginado(1, 1, '', '{}'::bigint[], NULL, '{}'::jsonb) -> 'meta' ->> 'total')::bigint;
    v_una   := (inventarios.fn_productos_listar_paginado(1, 1, '', ARRAY[v_m1], NULL, '{}'::jsonb) -> 'meta' ->> 'total')::bigint;
    v_dos   := (inventarios.fn_productos_listar_paginado(1, 1, '', ARRAY[v_m1, v_m2], NULL, '{}'::jsonb) -> 'meta' ->> 'total')::bigint;

    RAISE NOTICE 'todas=% vacio=% una(%)=% dos(%,%)=%', v_todas, v_vacio, v_m1, v_una, v_m1, v_m2, v_dos;

    -- Si el camino del JSON cambia, estos salen NULL y las comparaciones de
    -- abajo darían NULL —que NO es TRUE—, asi que la comprobación pasaría
    -- sin comprobar nada. Ya ocurrió: el total está en «meta», no en «data».
    IF v_todas IS NULL OR v_vacio IS NULL OR v_una IS NULL OR v_dos IS NULL THEN
        RAISE EXCEPTION 'No pude leer los totales: ¿cambió la forma del JSON?';
    END IF;

    IF v_vacio <> v_todas THEN RAISE EXCEPTION 'El array vacío debería traer TODAS'; END IF;
    IF v_una >= v_todas   THEN RAISE EXCEPTION 'Una marca debería traer menos que todas'; END IF;
    IF v_dos <= v_una     THEN RAISE EXCEPTION 'Dos marcas deberían traer más que una'; END IF;
END
$comprobar$;

COMMIT;
