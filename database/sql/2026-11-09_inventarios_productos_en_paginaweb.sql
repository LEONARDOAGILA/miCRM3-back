-- ============================================================================
-- «SE VENDE POR LA WEB»: UNA PALANCA APARTE DE `activo`
-- ============================================================================
-- Hasta hoy la tienda enseñaba TODOS los productos activos, y eso estaba mal:
-- no todo lo que se vende en el local se puede vender por internet. La única
-- salida era desactivar el producto, pero `activo` manda también en el local,
-- en la caja y en el stock: apagarlo para esconderlo de la web impedía
-- venderlo en la tienda física.
--
-- Son dos preguntas distintas y necesitan dos columnas distintas:
--
--   · `activo`        ¿existe y se puede vender?
--   · `en_paginaweb`  ¿se publica en la web?
--
-- La regla pública es `activo AND en_paginaweb`, y encima sigue mandando
-- `ecommerce.categorias_web.oculta`: gana la más restrictiva.
--
-- NACE ENCENDIDA, como `activo`. Los 264 productos de hoy quedan publicados
-- —que es lo que ya pasaba— y el producto nuevo nace publicado también. Si
-- naciera apagado, cada producto nuevo necesitaría que alguien se acordara de
-- encenderlo, y lo normal sería que se olvidaran.
--
-- ----------------------------------------------------------------------------
-- QUÉ TOCA
-- ----------------------------------------------------------------------------
-- 1. La columna.
-- 2. `fn_productos_json`: la palanca viaja a la ficha y a la rejilla.
-- 3. `fn_productos_crear` y `fn_productos_modificar`: parámetro NUEVO AL
--    FINAL con valor por defecto, para que las llamadas de hoy sigan valiendo.
-- 4. `fn_productos_en_paginaweb`: la hermana de `fn_productos_activar`, para
--    la casilla de la rejilla.
-- 5. `fn_productos_listar_paginado`: filtro de cabecera, como el del impuesto.
-- 6. LAS SEIS FUNCIONES PÚBLICAS de la tienda. `fn_tienda_buscador` no está
--    en la lista a propósito: no filtra productos por su cuenta, delega en
--    `fn_tienda_casan`, y arreglando ésa queda arreglado el buscador.
--
-- Las funciones del CRM —`fn_inicio_listar`, `fn_producto_seccion_productos`,
-- `fn_producto_secciones_json`, `fn_inicio_escaparates_disponibles`,
-- `fn_resumen`— NO se filtran: ahí hay que seguir viendo todos los productos.
--
-- ----------------------------------------------------------------------------
-- SE EJECUTA A MANO. Para probar sin guardar nada, cambiar el COMMIT del final
-- por ROLLBACK: la comprobación se hace igual y no queda rastro.
-- ============================================================================

BEGIN;

-- ----------------------------------------------------------------------------
-- Un parcheador con portero
-- ----------------------------------------------------------------------------
-- Las funciones son largas y los cambios son pequeños: se traen con
-- `pg_get_functiondef`, se les cambia el trozo y se vuelven a crear. El
-- portero es imprescindible: si el texto esperado no está —porque alguien la
-- cambió antes—, `replace` no haría nada y la migración diría que todo fue
-- bien dejando la función sin tocar.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION pg_temp.parchar(p_texto text, p_viejo text, p_nuevo text, p_donde text)
RETURNS text
LANGUAGE plpgsql
AS $parchar$
DECLARE
    v_veces int;
BEGIN
    v_veces := (length(p_texto) - length(replace(p_texto, p_viejo, '')))
               / GREATEST(length(p_viejo), 1);

    IF v_veces <> 1 THEN
        RAISE EXCEPTION 'Parche de %: esperaba UNA aparición de «%…» y encontré %',
              p_donde, left(p_viejo, 70), v_veces;
    END IF;

    RETURN replace(p_texto, p_viejo, p_nuevo);
END;
$parchar$;


-- ============================================================================
-- 1. LA COLUMNA
-- ============================================================================
ALTER TABLE inventarios.productos
    ADD COLUMN IF NOT EXISTS en_paginaweb boolean NOT NULL DEFAULT true;

COMMENT ON COLUMN inventarios.productos.en_paginaweb IS
    'Si el producto se publica en la tienda web. APARTE de `activo`: `activo` dice si '
    'se puede vender (local, caja, stock) y esto sólo si sale en internet. La regla '
    'pública es `activo AND en_paginaweb`. Nace en true, como `activo`.';


-- ============================================================================
-- 2. fn_productos_json — la palanca viaja al front
-- ============================================================================
DO $json$
DECLARE
    v_def text;
BEGIN
    v_def := pg_get_functiondef('inventarios.fn_productos_json(bigint)'::regprocedure);

    v_def := pg_temp.parchar(v_def,
        E'        ''activo'',          p.activo,\n',
        E'        ''activo'',          p.activo,\n'
        || E'        -- La palanca de la tienda. Aparte de `activo` a propósito: un\n'
        || E'        -- producto puede seguir vendiéndose en el local sin salir en la web.\n'
        || E'        ''en_paginaweb'',    p.en_paginaweb,\n',
        'fn_productos_json');

    EXECUTE v_def;
END;
$json$;


-- ============================================================================
-- 3. fn_productos_crear y fn_productos_modificar
-- ============================================================================
-- El parámetro va AL FINAL y con valor por defecto, así que las llamadas
-- posicionales que ya existen siguen funcionando sin tocarlas.
--
-- Cambiar la lista de parámetros obliga a BORRAR la función con su firma vieja
-- entera: `CREATE OR REPLACE` con una firma distinta no reemplaza nada, crea
-- una sobrecarga, y a partir de ahí toda llamada queda ambigua.
-- ============================================================================
DO $crear$
DECLARE
    v_firma text := 'inventarios.fn_productos_crear(character varying,character varying,'
                 || 'character varying,character varying,character varying,character varying,'
                 || 'text,bigint,bigint,character varying,character varying,numeric,numeric,'
                 || 'boolean,boolean,numeric,numeric,boolean,integer,boolean,bigint,'
                 || 'character varying,character varying,inet,text,uuid,numeric,numeric,numeric)';
    v_def   text;
BEGIN
    v_def := pg_get_functiondef(v_firma::regprocedure);

    -- a) La firma
    v_def := pg_temp.parchar(v_def,
        'p_cuota_credito_directo numeric DEFAULT NULL::numeric)',
        'p_cuota_credito_directo numeric DEFAULT NULL::numeric, p_en_paginaweb boolean DEFAULT true)',
        'fn_productos_crear (firma)');

    -- b) Lo que va a la auditoría
    v_def := pg_temp.parchar(v_def,
        E'        ''activo'',         COALESCE(p_activo, true)\n    );',
        E'        ''activo'',         COALESCE(p_activo, true),\n'
        || E'        ''en_paginaweb'',   COALESCE(p_en_paginaweb, true)\n    );',
        'fn_productos_crear (auditoría)');

    -- c) Las columnas del INSERT
    v_def := pg_temp.parchar(v_def,
        E'        activo)\n    VALUES (',
        E'        activo, en_paginaweb)\n    VALUES (',
        'fn_productos_crear (columnas)');

    -- d) Los valores
    v_def := pg_temp.parchar(v_def,
        E'        COALESCE(p_activo, true))\n    RETURNING id INTO v_id;',
        E'        COALESCE(p_activo, true), COALESCE(p_en_paginaweb, true))\n'
        || '    RETURNING id INTO v_id;',
        'fn_productos_crear (valores)');

    EXECUTE 'DROP FUNCTION ' || v_firma;
    EXECUTE v_def;
END;
$crear$;


DO $modificar$
DECLARE
    v_firma text := 'inventarios.fn_productos_modificar(bigint,character varying,character varying,'
                 || 'character varying,character varying,character varying,character varying,'
                 || 'text,bigint,bigint,character varying,character varying,numeric,numeric,'
                 || 'boolean,boolean,numeric,numeric,boolean,integer,boolean,bigint,'
                 || 'character varying,character varying,inet,text,uuid,numeric,numeric,numeric)';
    v_def   text;
BEGIN
    v_def := pg_get_functiondef(v_firma::regprocedure);

    -- a) La firma
    v_def := pg_temp.parchar(v_def,
        'p_cuota_credito_directo numeric DEFAULT NULL::numeric)',
        'p_cuota_credito_directo numeric DEFAULT NULL::numeric, p_en_paginaweb boolean DEFAULT true)',
        'fn_productos_modificar (firma)');

    -- b) La foto de ANTES, para el apunte de auditoría
    v_def := pg_temp.parchar(v_def,
        E'        ''activo'', v_actual.activo);',
        E'        ''activo'', v_actual.activo, ''en_paginaweb'', v_actual.en_paginaweb);',
        'fn_productos_modificar (antes)');

    -- c) La foto de DESPUÉS
    v_def := pg_temp.parchar(v_def,
        E'        ''activo'',         COALESCE(p_activo, true)\n    );',
        E'        ''activo'',         COALESCE(p_activo, true),\n'
        || E'        ''en_paginaweb'',   COALESCE(p_en_paginaweb, true)\n    );',
        'fn_productos_modificar (después)');

    -- d) El UPDATE
    v_def := pg_temp.parchar(v_def,
        E'           activo         = COALESCE(p_activo, true)\n     WHERE id = p_id;',
        E'           activo         = COALESCE(p_activo, true),\n'
        || E'           en_paginaweb   = COALESCE(p_en_paginaweb, true)\n     WHERE id = p_id;',
        'fn_productos_modificar (update)');

    EXECUTE 'DROP FUNCTION ' || v_firma;
    EXECUTE v_def;
END;
$modificar$;


-- ============================================================================
-- 4. fn_productos_en_paginaweb — la casilla de la rejilla
-- ============================================================================
-- Calcada de `fn_productos_activar`: con `p_en_paginaweb` en NULL hace de
-- interruptor (pone lo contrario de lo que había), y con un valor pone ése.
-- Así la rejilla puede tanto alternar de un clic como marcar en lote.
-- ============================================================================
CREATE OR REPLACE FUNCTION inventarios.fn_productos_en_paginaweb(
    p_id             bigint,
    p_en_paginaweb   boolean DEFAULT NULL,
    p_usuario_id     bigint  DEFAULT NULL,
    p_usuario_login  varchar DEFAULT NULL,
    p_usuario_nombre varchar DEFAULT NULL,
    p_ip_address     inet    DEFAULT NULL,
    p_user_agent     text    DEFAULT NULL,
    p_request_id     uuid    DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'inventarios', 'auditoria'
AS $function$
DECLARE
    v_antes      boolean;
    v_nuevo      boolean;
    v_updated_by varchar;
    v_updated_at text;
BEGIN
    PERFORM inventarios.fn_contexto_auditoria('inventarios.productos',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    SELECT en_paginaweb INTO v_antes
      FROM inventarios.productos
     WHERE id = p_id AND deleted_at IS NULL;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'error_code', 'NO_EXISTE',
                                  'message', 'El producto no existe');
    END IF;

    v_nuevo := COALESCE(p_en_paginaweb, NOT v_antes);

    IF v_nuevo IS NOT DISTINCT FROM v_antes THEN
        SELECT updated_by, to_char(updated_at, 'YYYY-MM-DD HH24:MI:SS')
          INTO v_updated_by, v_updated_at
          FROM inventarios.productos WHERE id = p_id;

        RETURN jsonb_build_object('success', true,
            'message', CASE WHEN v_nuevo THEN 'El producto ya estaba en la página web'
                                         ELSE 'El producto ya estaba fuera de la página web' END,
            'data', jsonb_build_object('id', p_id, 'en_paginaweb', v_nuevo,
                                       'updated_by', v_updated_by, 'updated_at', v_updated_at));
    END IF;

    PERFORM set_config('app.datos_anteriores',
        jsonb_build_object('id', p_id, 'en_paginaweb', v_antes)::text, true);
    PERFORM set_config('app.datos_nuevos',
        jsonb_build_object('id', p_id, 'en_paginaweb', v_nuevo)::text, true);

    UPDATE inventarios.productos SET en_paginaweb = v_nuevo WHERE id = p_id
    RETURNING en_paginaweb, updated_by, to_char(updated_at, 'YYYY-MM-DD HH24:MI:SS')
         INTO v_nuevo, v_updated_by, v_updated_at;

    PERFORM set_config('app.datos_anteriores', '', true);
    PERFORM set_config('app.datos_nuevos', '', true);

    RETURN jsonb_build_object('success', true,
        'message', CASE WHEN v_nuevo THEN 'El producto ya sale en la página web'
                                     ELSE 'El producto ya no sale en la página web' END,
        'data', jsonb_build_object('id', p_id, 'en_paginaweb', v_nuevo,
                                   'updated_by', v_updated_by, 'updated_at', v_updated_at));

EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false, 'error_code', 'ERROR',
        'message', 'No se pudo cambiar la publicación en la web: ' || SQLERRM);
END;
$function$;

COMMENT ON FUNCTION inventarios.fn_productos_en_paginaweb(bigint, boolean, bigint, varchar, varchar, inet, text, uuid) IS
    'Enciende o apaga la publicación de un producto en la tienda web. Con `p_en_paginaweb` '
    'en NULL hace de interruptor. No toca `activo`: el producto sigue vendiéndose en el local.';


-- ============================================================================
-- 5. fn_productos_listar_paginado — filtro de cabecera
-- ============================================================================
-- Por lo que SE VE en la celda («Sí» / «No»), igual que el del impuesto.
-- ============================================================================
DO $listar$
DECLARE
    v_firma text := 'inventarios.fn_productos_listar_paginado(integer,integer,text,bigint[],'
                 || 'bigint[],jsonb,numeric,numeric,numeric,numeric)';
    v_def   text;
BEGIN
    v_def := pg_get_functiondef(v_firma::regprocedure);

    v_def := pg_temp.parchar(v_def,
        E'           AND (p_filtros->''garantia_meses''   IS NULL OR ventas.fn_filtro_numero(p.garantia_meses,  p_filtros->''garantia_meses''))\n',
        E'           AND (p_filtros->''garantia_meses''   IS NULL OR ventas.fn_filtro_numero(p.garantia_meses,  p_filtros->''garantia_meses''))\n'
        || E'           -- La palanca de la web, también por lo que se ve en la celda\n'
        || E'           AND (p_filtros->''en_paginaweb''     IS NULL OR ventas.fn_filtro_texto(\n'
        || E'                   CASE WHEN p.en_paginaweb THEN ''Sí'' ELSE ''No'' END, p_filtros->''en_paginaweb''))\n',
        'fn_productos_listar_paginado');

    EXECUTE v_def;
END;
$listar$;


-- ============================================================================
-- 6. LAS SEIS FUNCIONES PÚBLICAS DE LA TIENDA
-- ============================================================================
-- Todas comprobaban ya `activo`; lo que les falta es la otra mitad. El parche
-- es el mismo en todas: donde dice `activo`, que diga `activo AND en_paginaweb`.
-- ============================================================================
DO $publicas$
DECLARE
    v_cambios CONSTANT jsonb := jsonb_build_array(

        -- El catálogo: /shop y el catálogo empotrado en una página
        jsonb_build_object(
            'firma', 'ecommerce.fn_tienda_productos(jsonb)',
            'viejo', E'     WHERE pr.deleted_at IS NULL\n       AND pr.activo\n),',
            'nuevo', E'     WHERE pr.deleted_at IS NULL\n       AND pr.activo\n       AND pr.en_paginaweb\n),'),

        -- La ficha. Sin esto, quien tenga el enlace guardado sigue entrando
        jsonb_build_object(
            'firma', 'ecommerce.fn_tienda_producto(bigint)',
            'viejo', E'     WHERE pr.id = p_id\n       AND pr.deleted_at IS NULL\n       AND pr.activo\n),',
            'nuevo', E'     WHERE pr.id = p_id\n       AND pr.deleted_at IS NULL\n       AND pr.activo\n       AND pr.en_paginaweb\n),'),

        -- El emparejador del buscador del encabezado
        jsonb_build_object(
            'firma', 'ecommerce.fn_tienda_casan(text)',
            'viejo', E'     WHERE pr.deleted_at IS NULL\n       AND pr.activo\n',
            'nuevo', E'     WHERE pr.deleted_at IS NULL\n       AND pr.activo\n       AND pr.en_paginaweb\n'),

        -- Los escaparates del inicio y de las páginas
        jsonb_build_object(
            'firma', 'ecommerce.fn_producto_seccion_publica(bigint)',
            'viejo', E'           AND p.activo), ''[]''::jsonb);',
            'nuevo', E'           AND p.activo\n           AND p.en_paginaweb), ''[]''::jsonb);'),

        -- Los contadores de los filtros: una categoría que se queda sin
        -- productos publicados no tiene por qué seguir ofreciéndose
        jsonb_build_object(
            'firma', 'ecommerce.fn_categorias_de_marca_publicas(bigint)',
            'viejo', 'WHERE p.marca_id = p_marca_id AND p.deleted_at IS NULL AND p.activo',
            'nuevo', 'WHERE p.marca_id = p_marca_id AND p.deleted_at IS NULL AND p.activo AND p.en_paginaweb'),

        jsonb_build_object(
            'firma', 'ecommerce.fn_marcas_de_categoria_publicas(bigint)',
            'viejo', 'WHERE p.marca_id = e.id AND p.deleted_at IS NULL AND p.activo',
            'nuevo', 'WHERE p.marca_id = e.id AND p.deleted_at IS NULL AND p.activo AND p.en_paginaweb')
    );

    v_uno jsonb;
    v_def text;
BEGIN
    FOR v_uno IN SELECT * FROM jsonb_array_elements(v_cambios)
    LOOP
        v_def := pg_get_functiondef((v_uno ->> 'firma')::regprocedure);
        v_def := pg_temp.parchar(v_def, v_uno ->> 'viejo', v_uno ->> 'nuevo', v_uno ->> 'firma');
        EXECUTE v_def;
    END LOOP;
END;
$publicas$;


-- ============================================================================
-- COMPROBACIÓN — no escribe nada
-- ============================================================================
DO $comprobar$
DECLARE
    v_falta      text[] := '{}';
    v_publicadas int;
    v_total      int;
    v_firma      text;
    v_sin        text[] := '{}';
BEGIN
    -- ---------- La columna ----------
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                    WHERE table_schema = 'inventarios' AND table_name = 'productos'
                      AND column_name = 'en_paginaweb' AND data_type = 'boolean'
                      AND is_nullable = 'NO' AND column_default = 'true') THEN
        v_falta := array_append(v_falta, 'la columna en_paginaweb no quedó boolean NOT NULL DEFAULT true');
    END IF;

    SELECT count(*), count(*) FILTER (WHERE en_paginaweb)
      INTO v_total, v_publicadas
      FROM inventarios.productos;

    IF v_publicadas <> v_total THEN
        v_falta := v_falta || format('%s de %s productos quedaron sin publicar',
                                     v_total - v_publicadas, v_total);
    END IF;

    -- ---------- Las seis públicas ----------
    FOREACH v_firma IN ARRAY ARRAY[
        'ecommerce.fn_tienda_productos(jsonb)',
        'ecommerce.fn_tienda_producto(bigint)',
        'ecommerce.fn_tienda_casan(text)',
        'ecommerce.fn_producto_seccion_publica(bigint)',
        'ecommerce.fn_categorias_de_marca_publicas(bigint)',
        'ecommerce.fn_marcas_de_categoria_publicas(bigint)']
    LOOP
        IF position('en_paginaweb' IN pg_get_functiondef(v_firma::regprocedure)) = 0 THEN
            v_sin := v_sin || v_firma;
        END IF;
    END LOOP;

    IF cardinality(v_sin) > 0 THEN
        v_falta := v_falta || ('estas funciones públicas no miran en_paginaweb: '
                               || array_to_string(v_sin, ', '));
    END IF;

    -- ---------- Y las del CRM NO deben mirarlo ----------
    FOREACH v_firma IN ARRAY ARRAY[
        'ecommerce.fn_producto_seccion_productos(bigint,integer,integer,text)']
    LOOP
        BEGIN
            IF position('AND p.en_paginaweb' IN pg_get_functiondef(v_firma::regprocedure)) > 0 THEN
                v_falta := v_falta || (v_firma || ' es del CRM y no debería filtrar por en_paginaweb');
            END IF;
        EXCEPTION WHEN undefined_function THEN
            NULL;   -- si cambió de firma, no es asunto de esta migración
        END;
    END LOOP;

    -- ---------- Las cuatro de inventarios ----------
    IF position('en_paginaweb' IN pg_get_functiondef('inventarios.fn_productos_json(bigint)'::regprocedure)) = 0 THEN
        v_falta := array_append(v_falta, 'fn_productos_json no devuelve en_paginaweb');
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
         WHERE n.nspname = 'inventarios' AND p.proname = 'fn_productos_en_paginaweb') THEN
        v_falta := array_append(v_falta, 'no se creó fn_productos_en_paginaweb');
    END IF;

    -- Que el parámetro nuevo quedó en crear y en modificar, y SÓLO UNA versión
    FOR v_firma IN
        SELECT p.proname FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
         WHERE n.nspname = 'inventarios'
           AND p.proname IN ('fn_productos_crear', 'fn_productos_modificar')
         GROUP BY p.proname HAVING count(*) <> 1
    LOOP
        v_falta := v_falta || (v_firma || ' quedó con más de una versión (sobrecarga ambigua)');
    END LOOP;

    IF position('p_en_paginaweb' IN
            pg_get_functiondef((SELECT p.oid FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                                 WHERE n.nspname = 'inventarios' AND p.proname = 'fn_productos_crear' LIMIT 1))) = 0 THEN
        v_falta := array_append(v_falta, 'fn_productos_crear no recibe p_en_paginaweb');
    END IF;

    IF position('p_en_paginaweb' IN
            pg_get_functiondef((SELECT p.oid FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                                 WHERE n.nspname = 'inventarios' AND p.proname = 'fn_productos_modificar' LIMIT 1))) = 0 THEN
        v_falta := array_append(v_falta, 'fn_productos_modificar no recibe p_en_paginaweb');
    END IF;

    -- ---------- El veredicto ----------
    IF cardinality(v_falta) > 0 THEN
        RAISE EXCEPTION E'LA MIGRACIÓN NO QUEDÓ BIEN:\n  · %', array_to_string(v_falta, E'\n  · ');
    END IF;

    RAISE NOTICE 'en_paginaweb: % productos, todos publicados. Seis funciones públicas filtrando.', v_total;
END;
$comprobar$;

COMMIT;
