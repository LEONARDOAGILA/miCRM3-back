-- ============================================================================
-- CÓDIGOS ALTERNOS DEL PRODUCTO (codigo2, codigo3, codigo4)
-- ============================================================================
-- Fecha: 2026-10-31
--
-- El mismo producto se llama de tres maneras según con quién hables: tu SKU
-- («ACC-HDMI»), el EAN del fabricante, y el código con el que lo factura CADA
-- proveedor. Cuando llega la lista de precios de un proveedor y dice
-- «H2M-0200», hoy no hay forma de saber qué producto es.
--
-- Tres columnas sueltas y no una tabla aparte: son tres, no N; no hay que
-- saber de QUÉ proveedor es cada una (el día que haga falta, eso es una tabla
-- producto-proveedor con precio y plazo, no esto); y así se ven y se escriben
-- en la misma ficha sin abrir nada.
--
-- SIN UNICIDAD, a diferencia de `codigo` y `codigo_barras`. Dos proveedores
-- distintos pueden usar la misma referencia para cosas distintas, y al no
-- haber columna de proveedor no hay forma de distinguirlas: un índice único
-- rechazaría un dato bueno. Si algún día se quiere, se añade.
--
-- SE BUSCAN. Es el motivo entero de tenerlos: se añaden al buscador general
-- del listado, junto al código y al código de barras. Guardar el código del
-- proveedor y que luego no lo encuentre nadie no sirve de nada.
--
-- Qué cambia:
--   · inventarios.productos          -> tres columnas nuevas
--   · fn_productos_json              -> las devuelve (la ficha las lee de aquí)
--   · fn_productos_crear             -> CAMBIA LA FIRMA (tres parámetros más)
--   · fn_productos_modificar         -> CAMBIA LA FIRMA (tres parámetros más)
--   · fn_productos_listar_paginado   -> sólo el buscador; la firma NO cambia
--
-- Las dos que cambian de firma se borran y se vuelven a crear: PostgreSQL no
-- deja meter parámetros en medio con CREATE OR REPLACE, y si se dejara viva la
-- vieja habría dos candidatas para la misma llamada y saldría ambigua. Van
-- enteras y a mano porque se tocan seis sitios de cada una; la del listado,
-- que sólo cambia una condición, se opera sobre su propio volcado.
--
-- Idempotente: si ya está hecho, no hace nada.
-- ============================================================================
\set ON_ERROR_STOP on

BEGIN;

-- ----------------------------------------------------------------------------
-- 1. LAS COLUMNAS
-- ----------------------------------------------------------------------------
-- 50 y no 30 como el SKU: el código es tuyo y lo eliges corto, pero el del
-- proveedor te lo dan, y las referencias de fabricante son largas.
ALTER TABLE inventarios.productos
    ADD COLUMN IF NOT EXISTS codigo2 character varying(50),
    ADD COLUMN IF NOT EXISTS codigo3 character varying(50),
    ADD COLUMN IF NOT EXISTS codigo4 character varying(50);

COMMENT ON COLUMN inventarios.productos.codigo2 IS
    'Código alterno: la referencia con la que un proveedor llama a este producto. Sin unicidad.';
COMMENT ON COLUMN inventarios.productos.codigo3 IS
    'Código alterno: la referencia con la que un proveedor llama a este producto. Sin unicidad.';
COMMENT ON COLUMN inventarios.productos.codigo4 IS
    'Código alterno: la referencia con la que un proveedor llama a este producto. Sin unicidad.';

-- ----------------------------------------------------------------------------
-- 2. LA FICHA EN JSON
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION inventarios.fn_productos_json(p_id bigint)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
AS $function$
    SELECT jsonb_build_object(
        'id',              p.id,
        'codigo',          p.codigo,
        'codigo_barras',   p.codigo_barras,
        -- Los tres de los proveedores. Van pegados a los otros dos códigos
        -- porque en la ficha se ven juntos, en la misma columna.
        'codigo2',         p.codigo2,
        'codigo3',         p.codigo3,
        'codigo4',         p.codigo4,
        'nombre',          p.nombre,
        'descripcion',     p.descripcion,

        'marca_id',        p.marca_id,
        'marca_nombre',    (SELECT m.nombre FROM inventarios.marcas m WHERE m.id = p.marca_id),
        'categoria_id',    p.categoria_id,
        'categoria_nombre',(SELECT c.nombre FROM inventarios.categorias c WHERE c.id = p.categoria_id),
        -- El camino completo: fuera del árbol, «Accesorios» a secas no dice de qué
        'categoria_ruta',  (inventarios.fn_categorias_json(p.categoria_id))->>'ruta',
        'modelo',          p.modelo,

        'unidad',          p.unidad,
        'costo',           p.costo,
        'precio',          p.precio,
        -- Sólo SI grava; la tarifa vendrá de las tablas de impuestos
        'impuesto',        p.impuesto,

        'maneja_stock',    p.maneja_stock,
        'stock_minimo',    p.stock_minimo,
        'stock_maximo',    p.stock_maximo,

        'maneja_serie',    p.maneja_serie,
        'garantia_meses',  p.garantia_meses,


        'activo',          p.activo,

        -- El NOMBRE del fichero (para saber si hay foto) y el ID de la
        -- imagen, que es por donde se pide: la ruta getImagen va por id de
        -- imagen, no por id de producto ni por nombre de fichero.
        'foto',            (SELECT i.archivo FROM inventarios.productos_imagenes i
                             WHERE i.producto_id = p.id AND i.principal LIMIT 1),
        'foto_id',         (SELECT i.id FROM inventarios.productos_imagenes i
                             WHERE i.producto_id = p.id AND i.principal LIMIT 1),
        'num_imagenes',    (SELECT COUNT(*) FROM inventarios.productos_imagenes i WHERE i.producto_id = p.id),

        -- La papelera: NULL mientras el producto está vigente
        'deleted_at',      to_char(p.deleted_at, 'YYYY-MM-DD HH24:MI:SS'),
        'deleted_by',      p.deleted_by,

        'created_by',      p.created_by,
        'updated_by',      p.updated_by,
        'created_at',      to_char(p.created_at, 'YYYY-MM-DD HH24:MI:SS'),
        'updated_at',      to_char(p.updated_at, 'YYYY-MM-DD HH24:MI:SS')
    )
      FROM inventarios.productos p
     WHERE p.id = p_id;
$function$;

-- ----------------------------------------------------------------------------
-- 3. CREAR
-- ----------------------------------------------------------------------------
DROP FUNCTION IF EXISTS inventarios.fn_productos_crear(
    character varying, character varying, character varying, text, bigint, bigint,
    character varying, character varying, numeric, numeric, boolean, boolean,
    numeric, numeric, boolean, integer, boolean,
    bigint, character varying, character varying, inet, text, uuid);

CREATE OR REPLACE FUNCTION inventarios.fn_productos_crear(
    p_codigo character varying,
    p_nombre character varying,
    p_codigo_barras character varying DEFAULT NULL::character varying,
    p_codigo2 character varying DEFAULT NULL::character varying,
    p_codigo3 character varying DEFAULT NULL::character varying,
    p_codigo4 character varying DEFAULT NULL::character varying,
    p_descripcion text DEFAULT NULL::text,
    p_marca_id bigint DEFAULT NULL::bigint,
    p_categoria_id bigint DEFAULT NULL::bigint,
    p_modelo character varying DEFAULT NULL::character varying,
    p_unidad character varying DEFAULT 'UNIDAD'::character varying,
    p_costo numeric DEFAULT 0,
    p_precio numeric DEFAULT 0,
    p_impuesto boolean DEFAULT true,
    p_maneja_stock boolean DEFAULT true,
    p_stock_minimo numeric DEFAULT 0,
    p_stock_maximo numeric DEFAULT NULL::numeric,
    p_maneja_serie boolean DEFAULT false,
    p_garantia_meses integer DEFAULT 0,
    p_activo boolean DEFAULT true,
    p_usuario_id bigint DEFAULT NULL::bigint,
    p_usuario_login character varying DEFAULT NULL::character varying,
    p_usuario_nombre character varying DEFAULT NULL::character varying,
    p_ip_address inet DEFAULT NULL::inet,
    p_user_agent text DEFAULT NULL::text,
    p_request_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'inventarios', 'auditoria'
AS $function$
DECLARE
    v_id    bigint;
    v_nuevo jsonb;
BEGIN
    PERFORM inventarios.fn_contexto_auditoria('inventarios.productos',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    -- Los alternos no se validan: no son únicos y no hay nada que comprobar
    -- de ellos más allá del largo, que ya lo pone la columna.
    PERFORM inventarios.fn_productos_validar(
        NULL, p_codigo, p_nombre, p_codigo_barras, p_marca_id, p_categoria_id,
        p_costo, p_precio, p_stock_minimo, p_stock_maximo, p_garantia_meses);

    v_nuevo := jsonb_build_object(
        'codigo',         UPPER(TRIM(p_codigo)),
        'codigo_barras',  NULLIF(TRIM(COALESCE(p_codigo_barras, '')), ''),
        'codigo2',        NULLIF(TRIM(COALESCE(p_codigo2, '')), ''),
        'codigo3',        NULLIF(TRIM(COALESCE(p_codigo3, '')), ''),
        'codigo4',        NULLIF(TRIM(COALESCE(p_codigo4, '')), ''),
        'nombre',         TRIM(p_nombre),
        'descripcion',    NULLIF(TRIM(COALESCE(p_descripcion, '')), ''),
        'marca_id',       p_marca_id,
        'categoria_id',   p_categoria_id,
        'modelo',         NULLIF(TRIM(COALESCE(p_modelo, '')), ''),
        'unidad',         COALESCE(NULLIF(TRIM(COALESCE(p_unidad, '')), ''), 'UNIDAD'),
        'costo',          COALESCE(p_costo, 0),
        'precio',         COALESCE(p_precio, 0),
        'impuesto',       COALESCE(p_impuesto, true),
        'maneja_stock',   COALESCE(p_maneja_stock, true),
        'stock_minimo',   COALESCE(p_stock_minimo, 0),
        'stock_maximo',   p_stock_maximo,
        'maneja_serie',   COALESCE(p_maneja_serie, false),
        'garantia_meses', COALESCE(p_garantia_meses, 0),
        'activo',         COALESCE(p_activo, true)
    );
    PERFORM set_config('app.datos_nuevos', v_nuevo::text, true);

    -- `iva_porcentaje` no se nombra: se queda con el valor por defecto de la
    -- columna y nadie lo mira.
    --
    -- Los alternos se guardan TAL CUAL llegan (sólo recortados), no en
    -- mayúsculas como el SKU: el código es del proveedor, y es él quien
    -- decide cómo se escribe. Para buscarlo da igual, el buscador no
    -- distingue mayúsculas.
    INSERT INTO inventarios.productos (
        codigo, codigo_barras, codigo2, codigo3, codigo4, nombre, descripcion,
        marca_id, categoria_id, modelo,
        unidad, costo, precio, impuesto,
        maneja_stock, stock_minimo, stock_maximo,
        maneja_serie, garantia_meses,
        activo)
    VALUES (
        UPPER(TRIM(p_codigo)),
        NULLIF(TRIM(COALESCE(p_codigo_barras, '')), ''),
        NULLIF(TRIM(COALESCE(p_codigo2, '')), ''),
        NULLIF(TRIM(COALESCE(p_codigo3, '')), ''),
        NULLIF(TRIM(COALESCE(p_codigo4, '')), ''),
        TRIM(p_nombre),
        NULLIF(TRIM(COALESCE(p_descripcion, '')), ''),
        p_marca_id, p_categoria_id,
        NULLIF(TRIM(COALESCE(p_modelo, '')), ''),
        COALESCE(NULLIF(TRIM(COALESCE(p_unidad, '')), ''), 'UNIDAD'),
        COALESCE(p_costo, 0), COALESCE(p_precio, 0), COALESCE(p_impuesto, true),
        COALESCE(p_maneja_stock, true), COALESCE(p_stock_minimo, 0), p_stock_maximo,
        COALESCE(p_maneja_serie, false), COALESCE(p_garantia_meses, 0),
        COALESCE(p_activo, true))
    RETURNING id INTO v_id;

    PERFORM set_config('app.datos_nuevos', '', true);

    RETURN jsonb_build_object('success', true, 'message', 'Producto creado exitosamente',
                              'data', inventarios.fn_productos_json(v_id));

EXCEPTION
    WHEN unique_violation THEN
        RAISE EXCEPTION 'Ya existe un producto con ese código o código de barras' USING ERRCODE = 'P0006';
END;
$function$;

-- ----------------------------------------------------------------------------
-- 4. MODIFICAR
-- ----------------------------------------------------------------------------
DROP FUNCTION IF EXISTS inventarios.fn_productos_modificar(
    bigint, character varying, character varying, character varying, text, bigint, bigint,
    character varying, character varying, numeric, numeric, boolean, boolean,
    numeric, numeric, boolean, integer, boolean,
    bigint, character varying, character varying, inet, text, uuid);

CREATE OR REPLACE FUNCTION inventarios.fn_productos_modificar(
    p_id bigint,
    p_codigo character varying,
    p_nombre character varying,
    p_codigo_barras character varying DEFAULT NULL::character varying,
    p_codigo2 character varying DEFAULT NULL::character varying,
    p_codigo3 character varying DEFAULT NULL::character varying,
    p_codigo4 character varying DEFAULT NULL::character varying,
    p_descripcion text DEFAULT NULL::text,
    p_marca_id bigint DEFAULT NULL::bigint,
    p_categoria_id bigint DEFAULT NULL::bigint,
    p_modelo character varying DEFAULT NULL::character varying,
    p_unidad character varying DEFAULT 'UNIDAD'::character varying,
    p_costo numeric DEFAULT 0,
    p_precio numeric DEFAULT 0,
    p_impuesto boolean DEFAULT true,
    p_maneja_stock boolean DEFAULT true,
    p_stock_minimo numeric DEFAULT 0,
    p_stock_maximo numeric DEFAULT NULL::numeric,
    p_maneja_serie boolean DEFAULT false,
    p_garantia_meses integer DEFAULT 0,
    p_activo boolean DEFAULT true,
    p_usuario_id bigint DEFAULT NULL::bigint,
    p_usuario_login character varying DEFAULT NULL::character varying,
    p_usuario_nombre character varying DEFAULT NULL::character varying,
    p_ip_address inet DEFAULT NULL::inet,
    p_user_agent text DEFAULT NULL::text,
    p_request_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'inventarios', 'auditoria'
AS $function$
DECLARE
    v_actual inventarios.productos%ROWTYPE;
    v_antes  jsonb;
    v_nuevo  jsonb;
BEGIN
    PERFORM inventarios.fn_contexto_auditoria('inventarios.productos',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    SELECT * INTO v_actual FROM inventarios.productos WHERE id = p_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'El producto no existe' USING ERRCODE = 'P0013';
    END IF;

    PERFORM inventarios.fn_productos_validar(
        p_id, p_codigo, p_nombre, p_codigo_barras, p_marca_id, p_categoria_id,
        p_costo, p_precio, p_stock_minimo, p_stock_maximo, p_garantia_meses);

    -- A la auditoría va la ficha comercial, no la fila entera: las fechas y
    -- el usuario ya van en el apunte, y repetirlos sólo estorba al leerlo.
    -- Los alternos SÍ van: cambiar el código de un proveedor es justo la
    -- clase de cosa que luego hay que poder rastrear.
    v_antes := jsonb_build_object(
        'codigo', v_actual.codigo, 'codigo_barras', v_actual.codigo_barras,
        'codigo2', v_actual.codigo2, 'codigo3', v_actual.codigo3, 'codigo4', v_actual.codigo4,
        'nombre', v_actual.nombre, 'descripcion', v_actual.descripcion,
        'marca_id', v_actual.marca_id, 'categoria_id', v_actual.categoria_id,
        'modelo', v_actual.modelo, 'unidad', v_actual.unidad,
        'costo', v_actual.costo, 'precio', v_actual.precio, 'impuesto', v_actual.impuesto,
        'maneja_stock', v_actual.maneja_stock, 'stock_minimo', v_actual.stock_minimo, 'stock_maximo', v_actual.stock_maximo,
        'maneja_serie', v_actual.maneja_serie, 'garantia_meses', v_actual.garantia_meses,
        'activo', v_actual.activo);

    v_nuevo := jsonb_build_object(
        'codigo',         UPPER(TRIM(p_codigo)),
        'codigo_barras',  NULLIF(TRIM(COALESCE(p_codigo_barras, '')), ''),
        'codigo2',        NULLIF(TRIM(COALESCE(p_codigo2, '')), ''),
        'codigo3',        NULLIF(TRIM(COALESCE(p_codigo3, '')), ''),
        'codigo4',        NULLIF(TRIM(COALESCE(p_codigo4, '')), ''),
        'nombre',         TRIM(p_nombre),
        'descripcion',    NULLIF(TRIM(COALESCE(p_descripcion, '')), ''),
        'marca_id',       p_marca_id,
        'categoria_id',   p_categoria_id,
        'modelo',         NULLIF(TRIM(COALESCE(p_modelo, '')), ''),
        'unidad',         COALESCE(NULLIF(TRIM(COALESCE(p_unidad, '')), ''), 'UNIDAD'),
        'costo',          COALESCE(p_costo, 0),
        'precio',         COALESCE(p_precio, 0),
        'impuesto',       COALESCE(p_impuesto, true),
        'maneja_stock',   COALESCE(p_maneja_stock, true),
        'stock_minimo',   COALESCE(p_stock_minimo, 0),
        'stock_maximo',   p_stock_maximo,
        'maneja_serie',   COALESCE(p_maneja_serie, false),
        'garantia_meses', COALESCE(p_garantia_meses, 0),
        'activo',         COALESCE(p_activo, true)
    );
    PERFORM set_config('app.datos_anteriores', v_antes::text, true);
    PERFORM set_config('app.datos_nuevos',     v_nuevo::text, true);

    UPDATE inventarios.productos
       SET codigo         = UPPER(TRIM(p_codigo)),
           codigo_barras  = NULLIF(TRIM(COALESCE(p_codigo_barras, '')), ''),
           codigo2        = NULLIF(TRIM(COALESCE(p_codigo2, '')), ''),
           codigo3        = NULLIF(TRIM(COALESCE(p_codigo3, '')), ''),
           codigo4        = NULLIF(TRIM(COALESCE(p_codigo4, '')), ''),
           nombre         = TRIM(p_nombre),
           descripcion    = NULLIF(TRIM(COALESCE(p_descripcion, '')), ''),
           marca_id       = p_marca_id,
           categoria_id   = p_categoria_id,
           modelo         = NULLIF(TRIM(COALESCE(p_modelo, '')), ''),
           unidad         = COALESCE(NULLIF(TRIM(COALESCE(p_unidad, '')), ''), 'UNIDAD'),
           costo          = COALESCE(p_costo, 0),
           precio         = COALESCE(p_precio, 0),
           impuesto       = COALESCE(p_impuesto, true),
           maneja_stock   = COALESCE(p_maneja_stock, true),
           stock_minimo   = COALESCE(p_stock_minimo, 0),
           stock_maximo   = p_stock_maximo,
           maneja_serie   = COALESCE(p_maneja_serie, false),
           garantia_meses = COALESCE(p_garantia_meses, 0),
           activo         = COALESCE(p_activo, true)
     WHERE id = p_id;

    PERFORM set_config('app.datos_anteriores', '', true);
    PERFORM set_config('app.datos_nuevos', '', true);

    RETURN jsonb_build_object('success', true, 'message', 'Producto actualizado exitosamente',
                              'data', inventarios.fn_productos_json(p_id));

EXCEPTION
    WHEN unique_violation THEN
        RAISE EXCEPTION 'Ya existe otro producto con ese código o código de barras' USING ERRCODE = 'P0006';
END;
$function$;

-- ----------------------------------------------------------------------------
-- 5. QUE EL BUSCADOR DEL LISTADO LOS ENCUENTRE
-- ----------------------------------------------------------------------------
-- Aquí la firma no cambia y sólo se añaden tres condiciones al OR del
-- buscador, así que la función no se copia: se vuelca, se le añade lo que
-- falta y se vuelve a crear.
DO $buscador$
DECLARE
    r   record;
    def text;
BEGIN
    SELECT p.oid INTO r
      FROM pg_proc p
      JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'inventarios'
       AND p.proname = 'fn_productos_listar_paginado';

    IF NOT FOUND THEN
        RAISE EXCEPTION 'No encuentro fn_productos_listar_paginado';
    END IF;

    def := pg_get_functiondef(r.oid);

    IF strpos(def, 'p.codigo2') > 0 THEN
        RAISE NOTICE 'El buscador ya mira los códigos alternos: no hay nada que hacer.';
        RETURN;
    END IF;

    IF strpos(def, 'OR p.codigo_barras ILIKE') = 0 THEN
        RAISE EXCEPTION 'No encuentro la línea del código de barras en el buscador: ¿cambió la función?';
    END IF;

    def := replace(def,
        'OR p.codigo_barras ILIKE ''%'' || v_filtro || ''%''',
        'OR p.codigo_barras ILIKE ''%'' || v_filtro || ''%''' || E'\n' ||
        '                OR p.codigo2       ILIKE ''%'' || v_filtro || ''%''' || E'\n' ||
        '                OR p.codigo3       ILIKE ''%'' || v_filtro || ''%''' || E'\n' ||
        '                OR p.codigo4       ILIKE ''%'' || v_filtro || ''%''');

    IF strpos(def, 'p.codigo4') = 0 THEN
        RAISE EXCEPTION 'No se añadieron las condiciones nuevas';
    END IF;

    EXECUTE def;
    RAISE NOTICE 'El buscador del listado ya mira los tres códigos alternos.';
END
$buscador$;

-- ----------------------------------------------------------------------------
-- 6. QUE DE VERDAD HAGA LO QUE DICE
-- ----------------------------------------------------------------------------
-- Se crea un producto con los tres alternos, se le cambian, se busca por uno
-- de ellos y se borra. Todo dentro de la transacción que está abierta, así
-- que no queda nada aunque algo falle.
DO $comprobar$
DECLARE
    v_cat   bigint;
    v_res   jsonb;
    v_id    bigint;
    v_json  jsonb;
    v_total bigint;
    v_marca text := 'ZZTEST-' || to_char(clock_timestamp(), 'HH24MISSUS');
BEGIN
    SELECT id INTO v_cat FROM inventarios.categorias
     WHERE deleted_at IS NULL AND COALESCE(es_transaccion, true) LIMIT 1;

    v_res := inventarios.fn_productos_crear(
        v_marca, 'Producto de prueba de códigos alternos', NULL,
        v_marca || '-A', v_marca || '-B', v_marca || '-C',
        NULL, NULL, v_cat);

    v_id := (v_res -> 'data' ->> 'id')::bigint;
    IF v_id IS NULL THEN
        RAISE EXCEPTION 'No pude crear el producto de prueba: %', v_res;
    END IF;

    -- a) Se guardaron y vuelven en la ficha
    v_json := inventarios.fn_productos_json(v_id);
    IF v_json ->> 'codigo2' <> v_marca || '-A'
       OR v_json ->> 'codigo3' <> v_marca || '-B'
       OR v_json ->> 'codigo4' <> v_marca || '-C' THEN
        RAISE EXCEPTION 'Los alternos no volvieron bien al crear: %', v_json;
    END IF;

    -- b) El buscador los encuentra (por el tercero, que es el último añadido)
    v_total := (inventarios.fn_productos_listar_paginado(1, 1, v_marca || '-C') -> 'meta' ->> 'total')::bigint;
    IF v_total IS NULL THEN
        RAISE EXCEPTION 'No pude leer el total: ¿cambió la forma del JSON?';
    END IF;
    IF v_total <> 1 THEN
        RAISE EXCEPTION 'Buscando por el código alterno 4 esperaba 1 producto y salieron %', v_total;
    END IF;

    -- c) Modificar los cambia, y vaciar uno lo deja en NULL (no en '')
    v_res := inventarios.fn_productos_modificar(
        v_id, v_marca, 'Producto de prueba de códigos alternos', NULL,
        v_marca || '-Z', '   ', NULL,
        NULL, NULL, v_cat);

    v_json := inventarios.fn_productos_json(v_id);
    IF v_json ->> 'codigo2' <> v_marca || '-Z' THEN
        RAISE EXCEPTION 'El alterno 2 no se modificó: %', v_json;
    END IF;
    IF v_json -> 'codigo3' <> 'null'::jsonb OR v_json -> 'codigo4' <> 'null'::jsonb THEN
        RAISE EXCEPTION 'Los alternos vaciados deberían quedar en NULL: %', v_json;
    END IF;

    DELETE FROM inventarios.productos WHERE id = v_id;
    RAISE NOTICE 'Comprobado: se guardan, se modifican, se vacían y se buscan.';
END
$comprobar$;

COMMIT;
