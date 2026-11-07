-- ============================================================================
-- EL LISTADO DE PRODUCTOS: VARIAS CATEGORÍAS Y RANGOS DE PRECIO Y COSTO
-- ============================================================================
-- Fecha: 2026-10-31
--
-- Acompaña al panel de filtros de la derecha en la pantalla de productos.
-- `fn_productos_listar_paginado` gana:
--
--   p_categoria_ids bigint[]   antes era UNA categoría (p_categoria_id)
--   p_precio_min / p_precio_max numeric
--   p_costo_min  / p_costo_max  numeric
--
-- LAS CATEGORÍAS SIGUEN BAJANDO POR LA RAMA. Pedir «Línea Blanca» trae
-- también lo que cuelga de ella, porque los productos cuelgan de las hojas;
-- lo único que cambia es que ahora se pueden pedir VARIAS ramas a la vez y
-- el CTE recursivo se siembra con todas.
--
-- Esto es lo que permite que el árbol de la izquierda y el filtro de
-- categorías de la derecha sean EL MISMO filtro con dos mandos: el árbol
-- mete una rama en la lista; el panel deja elegir varias. Si fueran dos
-- filtros distintos habría que explicar cuál gana.
--
-- LOS RANGOS SON ABIERTOS POR LOS DOS LADOS: sólo mínimo, sólo máximo, los
-- dos o ninguno. NULL en un extremo significa «sin tope por ahí».
--
-- Idempotente, y la función no se reescribe a mano: se vuelca con
-- pg_get_functiondef y se le hace cirugía, que son 94 líneas y copiarlas
-- para cambiar cinco es la mejor forma de perder algo por el camino.
-- ============================================================================
\set ON_ERROR_STOP on

BEGIN;

DO $cambiar$
DECLARE
    r       record;
    def     text;
    v_vieja text;
BEGIN
    SELECT p.oid, p.oid::regprocedure::text AS firma
      INTO r
      FROM pg_proc p
      JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'inventarios'
       AND p.proname = 'fn_productos_listar_paginado'
       AND pg_get_function_identity_arguments(p.oid) LIKE '%p_categoria_id bigint%';

    IF NOT FOUND THEN
        RAISE NOTICE 'Ya tiene los filtros nuevos: no hay nada que hacer.';
        RETURN;
    END IF;

    v_vieja := r.firma;
    def := pg_get_functiondef(r.oid);

    -- a) La categoría pasa a lista, y de paso entran los cuatro rangos
    def := replace(def,
        'p_categoria_id bigint DEFAULT NULL::bigint, p_filtros jsonb DEFAULT ''{}''::jsonb)',
        'p_categoria_ids bigint[] DEFAULT NULL::bigint[], p_filtros jsonb DEFAULT ''{}''::jsonb,'
        || ' p_precio_min numeric DEFAULT NULL::numeric, p_precio_max numeric DEFAULT NULL::numeric,'
        || ' p_costo_min numeric DEFAULT NULL::numeric, p_costo_max numeric DEFAULT NULL::numeric)');

    -- b) La semilla del CTE recursivo: ahora son varias ramas
    def := replace(def,
        'SELECT c.id FROM inventarios.categorias c WHERE c.id = p_categoria_id',
        'SELECT c.id FROM inventarios.categorias c WHERE c.id = ANY(p_categoria_ids)');

    -- c) La condición, con el caso del array vacío = «todas»
    def := replace(def,
        '(p_categoria_id IS NULL OR p.categoria_id IN (SELECT id FROM rama))',
        '(p_categoria_ids IS NULL OR cardinality(p_categoria_ids) = 0'
        || ' OR p.categoria_id IN (SELECT id FROM rama))'
        || E'\n           AND (p_precio_min IS NULL OR p.precio >= p_precio_min)'
        || E'\n           AND (p_precio_max IS NULL OR p.precio <= p_precio_max)'
        || E'\n           AND (p_costo_min  IS NULL OR p.costo  >= p_costo_min)'
        || E'\n           AND (p_costo_max  IS NULL OR p.costo  <= p_costo_max)');

    IF strpos(def, 'p_categoria_id ') > 0 OR strpos(def, 'p_categoria_id)') > 0 THEN
        RAISE EXCEPTION 'Quedó alguna referencia a p_categoria_id sin cambiar';
    END IF;
    IF strpos(def, 'p_precio_min') = 0 OR strpos(def, 'p_costo_max') = 0 THEN
        RAISE EXCEPTION 'No entraron los rangos';
    END IF;

    EXECUTE def;
    EXECUTE 'DROP FUNCTION IF EXISTS ' || v_vieja;
    RAISE NOTICE 'regenerada, y borrada la vieja: %', v_vieja;
END
$cambiar$;

-- Que de verdad filtre
DO $comprobar$
DECLARE
    v_todas bigint;
    v_rama  bigint;
    v_dos   bigint;
    v_caro  bigint;
    v_c1    bigint;
    v_c2    bigint;
    v_corte numeric;
BEGIN
    SELECT categoria_id INTO v_c1 FROM inventarios.productos
     WHERE deleted_at IS NULL AND categoria_id IS NOT NULL
     GROUP BY 1 ORDER BY count(*) DESC, 1 LIMIT 1;
    SELECT categoria_id INTO v_c2 FROM inventarios.productos
     WHERE deleted_at IS NULL AND categoria_id IS NOT NULL AND categoria_id <> v_c1
     GROUP BY 1 ORDER BY count(*) DESC, 1 LIMIT 1;
    SELECT percentile_disc(0.5) WITHIN GROUP (ORDER BY precio) INTO v_corte
      FROM inventarios.productos WHERE deleted_at IS NULL;

    v_todas := (inventarios.fn_productos_listar_paginado(1,1,'',NULL,NULL,'{}'::jsonb) -> 'meta' ->> 'total')::bigint;
    v_rama  := (inventarios.fn_productos_listar_paginado(1,1,'',NULL,ARRAY[v_c1],'{}'::jsonb) -> 'meta' ->> 'total')::bigint;
    v_dos   := (inventarios.fn_productos_listar_paginado(1,1,'',NULL,ARRAY[v_c1,v_c2],'{}'::jsonb) -> 'meta' ->> 'total')::bigint;
    v_caro  := (inventarios.fn_productos_listar_paginado(1,1,'',NULL,NULL,'{}'::jsonb, v_corte, NULL) -> 'meta' ->> 'total')::bigint;

    RAISE NOTICE 'todas=% una_rama(%)=% dos_ramas=% precio>=%: %',
                 v_todas, v_c1, v_rama, v_dos, v_corte, v_caro;

    -- Si cambia la forma del JSON esto sale NULL y las comparaciones de abajo
    -- darían NULL —que NO es TRUE—, así que pasaría sin comprobar nada.
    IF v_todas IS NULL OR v_rama IS NULL OR v_dos IS NULL OR v_caro IS NULL THEN
        RAISE EXCEPTION 'No pude leer los totales: ¿cambió la forma del JSON?';
    END IF;

    IF v_rama > v_todas THEN RAISE EXCEPTION 'Una rama no puede traer más que todas'; END IF;
    IF v_dos < v_rama   THEN RAISE EXCEPTION 'Dos ramas deberían traer al menos lo de una'; END IF;
    IF v_caro >= v_todas AND v_todas > 1 THEN RAISE EXCEPTION 'El filtro de precio no recortó nada'; END IF;
END
$comprobar$;

COMMIT;
