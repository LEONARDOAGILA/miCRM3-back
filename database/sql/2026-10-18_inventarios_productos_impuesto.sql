-- ===========================================================================
-- EL PRODUCTO DICE SI GRAVA IMPUESTO; LA TARIFA YA NO VIVE AQUÍ
-- ===========================================================================
-- Fecha: 2026-10-18
--
-- QUÉ CAMBIA. El producto llevaba `iva_porcentaje` (15 / 5 / 0) escrito a
-- mano en su ficha. Eso obliga a repasar el catálogo entero cada vez que
-- cambia la tarifa por decreto, y a que cada quien recuerde qué partida va
-- exenta. En su lugar el producto sólo dice SI GRAVA O NO —`impuesto`,
-- true/false— y el porcentaje saldrá de las tablas de impuestos cuando
-- existan, igual que se hace con las demás tarifas.
--
-- EL PUNTO DE PARTIDA sale de lo que cada producto tenía: graba impuesto el
-- que llevaba un IVA mayor que cero. Hoy los 16 productos están en 15 %, así
-- que todos quedan en «sí».
--
-- LA COLUMNA `iva_porcentaje` NO SE BORRA. Deja de leerse y de escribirse
-- (sale de la ficha JSON y de los parámetros de crear/modificar), pero se
-- queda con sus datos por si al montar las tablas de impuestos hace falta
-- saber con qué tarifa estaba cada producto. Cuando ya no haga falta:
--
--     ALTER TABLE inventarios.productos DROP COLUMN iva_porcentaje;
--
-- FUNCIONES. `fn_productos_crear` y `fn_productos_modificar` cambian su
-- parámetro 11 (`p_iva_porcentaje numeric` -> `p_impuesto boolean`) y
-- `fn_productos_validar` pierde el suyo, así que hay que BORRARLAS antes de
-- volver a crearlas: con otro tipo, CREATE OR REPLACE no las sustituye, crea
-- una segunda función con el mismo nombre y luego la llamada es ambigua.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- 1. LA COLUMNA
-- ---------------------------------------------------------------------------
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                    WHERE table_schema = 'inventarios'
                      AND table_name   = 'productos'
                      AND column_name  = 'impuesto') THEN

        ALTER TABLE inventarios.productos
            ADD COLUMN impuesto boolean NOT NULL DEFAULT true;

        -- Sólo la primera vez: después manda lo que diga cada ficha
        UPDATE inventarios.productos
           SET impuesto = (COALESCE(iva_porcentaje, 0) > 0);

        RAISE NOTICE 'inventarios.productos.impuesto creada y rellenada desde iva_porcentaje';
    ELSE
        RAISE NOTICE 'inventarios.productos.impuesto ya existía: no se toca';
    END IF;
END $$;

COMMENT ON COLUMN inventarios.productos.impuesto
IS 'Si el producto grava impuesto. La TARIFA no está aquí: saldrá de las tablas de impuestos.';

COMMENT ON COLUMN inventarios.productos.iva_porcentaje
IS 'EN DESUSO desde 2026-10-18: ni se lee ni se escribe. Se conserva como histórico hasta que estén las tablas de impuestos; entonces se puede borrar la columna.';

-- ---------------------------------------------------------------------------
-- 2. FUERA LAS VERSIONES VIEJAS (firmas con el IVA)
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS inventarios.fn_productos_crear(
    character varying, character varying, character varying, text, bigint, bigint,
    character varying, character varying, numeric, numeric, numeric, boolean, numeric,
    numeric, boolean, integer, numeric, numeric, numeric, numeric, boolean, bigint,
    character varying, character varying, inet, text, uuid);

DROP FUNCTION IF EXISTS inventarios.fn_productos_modificar(
    bigint, character varying, character varying, character varying, text, bigint, bigint,
    character varying, character varying, numeric, numeric, numeric, boolean, numeric,
    numeric, boolean, integer, numeric, numeric, numeric, numeric, boolean, bigint,
    character varying, character varying, inet, text, uuid);

DROP FUNCTION IF EXISTS inventarios.fn_productos_validar(
    bigint, character varying, character varying, character varying, bigint, bigint,
    numeric, numeric, numeric, numeric, numeric, integer);

-- ---------------------------------------------------------------------------
-- 3. VALIDACIONES (sin el tramo del IVA)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION inventarios.fn_productos_validar(
    p_id            bigint,
    p_codigo        varchar,
    p_nombre        varchar,
    p_codigo_barras varchar,
    p_marca_id      bigint,
    p_categoria_id  bigint,
    p_costo         numeric,
    p_precio        numeric,
    p_stock_minimo  numeric,
    p_stock_maximo  numeric,
    p_garantia      integer
)
RETURNS void
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
AS $function$
BEGIN
    IF p_codigo IS NULL OR length(TRIM(p_codigo)) < 2 THEN
        RAISE EXCEPTION 'El código del producto es obligatorio (mínimo 2 caracteres)' USING ERRCODE = 'P0001';
    END IF;
    IF p_nombre IS NULL OR length(TRIM(p_nombre)) < 3 THEN
        RAISE EXCEPTION 'El nombre del producto es obligatorio (mínimo 3 caracteres)' USING ERRCODE = 'P0001';
    END IF;

    IF EXISTS (SELECT 1 FROM inventarios.productos
                WHERE UPPER(TRIM(codigo)) = UPPER(TRIM(p_codigo))
                  AND (p_id IS NULL OR id <> p_id)) THEN
        -- Puede estar en la papelera: sin decirlo, el mensaje desconcierta
        -- porque ese código no aparece en ningún listado.
        IF EXISTS (SELECT 1 FROM inventarios.productos
                    WHERE UPPER(TRIM(codigo)) = UPPER(TRIM(p_codigo))
                      AND (p_id IS NULL OR id <> p_id)
                      AND deleted_at IS NOT NULL) THEN
            RAISE EXCEPTION 'Ya existe un producto con el código % en la papelera de reciclaje', UPPER(TRIM(p_codigo)) USING ERRCODE = 'P0006';
        END IF;
        RAISE EXCEPTION 'Ya existe un producto con el código %', UPPER(TRIM(p_codigo)) USING ERRCODE = 'P0006';
    END IF;

    IF NULLIF(TRIM(COALESCE(p_codigo_barras, '')), '') IS NOT NULL
       AND EXISTS (SELECT 1 FROM inventarios.productos
                    WHERE UPPER(TRIM(codigo_barras)) = UPPER(TRIM(p_codigo_barras))
                      AND (p_id IS NULL OR id <> p_id)) THEN
        RAISE EXCEPTION 'Ya existe un producto con ese código de barras' USING ERRCODE = 'P0006';
    END IF;

    -- Y que no esté en la papelera: no sale en ningún combo, así que si
    -- llega es de una pantalla con datos viejos.
    IF p_marca_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM inventarios.marcas WHERE id = p_marca_id AND deleted_at IS NULL) THEN
        RAISE EXCEPTION 'La marca indicada no existe' USING ERRCODE = 'P0016';
    END IF;
    IF p_categoria_id IS NOT NULL THEN
        -- Igual que la marca: tampoco vale una que esté en la papelera
        IF NOT EXISTS (SELECT 1 FROM inventarios.categorias
                        WHERE id = p_categoria_id AND deleted_at IS NULL) THEN
            RAISE EXCEPTION 'La categoría indicada no existe' USING ERRCODE = 'P0016';
        END IF;

        -- SÓLO LAS DE TRANSACCIÓN ADMITEN PRODUCTOS. Las de arriba del
        -- árbol agrupan: «Tecnología» o «Computadores» no son sitios
        -- donde poner un producto, lo son «Portátiles» o «Monitores».
        IF NOT EXISTS (SELECT 1 FROM inventarios.categorias
                        WHERE id = p_categoria_id AND es_transaccion) THEN
            RAISE EXCEPTION 'La categoría «%» agrupa, no admite productos: elija una de transacción',
                  (SELECT nombre FROM inventarios.categorias WHERE id = p_categoria_id)
                  USING ERRCODE = 'P0016';
        END IF;
    END IF;

    IF COALESCE(p_costo, 0)  < 0 THEN RAISE EXCEPTION 'El costo no puede ser negativo'  USING ERRCODE = 'P0015'; END IF;
    IF COALESCE(p_precio, 0) < 0 THEN RAISE EXCEPTION 'El precio no puede ser negativo' USING ERRCODE = 'P0015'; END IF;
    -- El IVA ya no se valida aquí: el producto sólo dice si grava o no, y eso
    -- es un booleano, no hay nada que comprobar.
    IF COALESCE(p_stock_minimo, 0) < 0 THEN
        RAISE EXCEPTION 'El stock mínimo no puede ser negativo' USING ERRCODE = 'P0015';
    END IF;
    IF p_stock_maximo IS NOT NULL AND p_stock_maximo < COALESCE(p_stock_minimo, 0) THEN
        RAISE EXCEPTION 'El stock máximo no puede ser menor que el mínimo' USING ERRCODE = 'P0015';
    END IF;
    IF COALESCE(p_garantia, 0) < 0 OR COALESCE(p_garantia, 0) > 600 THEN
        RAISE EXCEPTION 'La garantía debe estar entre 0 y 600 meses' USING ERRCODE = 'P0015';
    END IF;
END;
$function$;

-- ---------------------------------------------------------------------------
-- 4. CREAR
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION inventarios.fn_productos_crear(
    p_codigo         varchar,
    p_nombre         varchar,
    p_codigo_barras  varchar DEFAULT NULL,
    p_descripcion    text    DEFAULT NULL,
    p_marca_id       bigint  DEFAULT NULL,
    p_categoria_id   bigint  DEFAULT NULL,
    p_modelo         varchar DEFAULT NULL,
    p_unidad         varchar DEFAULT 'UNIDAD',
    p_costo          numeric DEFAULT 0,
    p_precio         numeric DEFAULT 0,
    p_impuesto       boolean DEFAULT true,     -- antes era p_iva_porcentaje
    p_maneja_stock   boolean DEFAULT true,
    p_stock_minimo   numeric DEFAULT 0,
    p_stock_maximo   numeric DEFAULT NULL,
    p_maneja_serie   boolean DEFAULT false,
    p_garantia_meses integer DEFAULT 0,
    p_peso_kg        numeric DEFAULT NULL,
    p_alto_cm        numeric DEFAULT NULL,
    p_ancho_cm       numeric DEFAULT NULL,
    p_profundidad_cm numeric DEFAULT NULL,
    p_activo         boolean DEFAULT true,
    p_usuario_id     bigint  DEFAULT NULL,
    p_usuario_login  varchar DEFAULT NULL,
    p_usuario_nombre varchar DEFAULT NULL,
    p_ip_address     inet    DEFAULT NULL,
    p_user_agent     text    DEFAULT NULL,
    p_request_id     uuid    DEFAULT NULL
)
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

    PERFORM inventarios.fn_productos_validar(
        NULL, p_codigo, p_nombre, p_codigo_barras, p_marca_id, p_categoria_id,
        p_costo, p_precio, p_stock_minimo, p_stock_maximo, p_garantia_meses);

    v_nuevo := jsonb_build_object(
        'codigo',         UPPER(TRIM(p_codigo)),
        'codigo_barras',  NULLIF(TRIM(COALESCE(p_codigo_barras, '')), ''),
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
        'peso_kg',        p_peso_kg,
        'alto_cm',        p_alto_cm,
        'ancho_cm',       p_ancho_cm,
        'profundidad_cm', p_profundidad_cm,
        'activo',         COALESCE(p_activo, true)
    );
    PERFORM set_config('app.datos_nuevos', v_nuevo::text, true);

    -- `iva_porcentaje` no se nombra: se queda con el valor por defecto de la
    -- columna y nadie lo mira.
    INSERT INTO inventarios.productos (
        codigo, codigo_barras, nombre, descripcion,
        marca_id, categoria_id, modelo,
        unidad, costo, precio, impuesto,
        maneja_stock, stock_minimo, stock_maximo,
        maneja_serie, garantia_meses,
        peso_kg, alto_cm, ancho_cm, profundidad_cm,
        activo)
    VALUES (
        UPPER(TRIM(p_codigo)),
        NULLIF(TRIM(COALESCE(p_codigo_barras, '')), ''),
        TRIM(p_nombre),
        NULLIF(TRIM(COALESCE(p_descripcion, '')), ''),
        p_marca_id, p_categoria_id,
        NULLIF(TRIM(COALESCE(p_modelo, '')), ''),
        COALESCE(NULLIF(TRIM(COALESCE(p_unidad, '')), ''), 'UNIDAD'),
        COALESCE(p_costo, 0), COALESCE(p_precio, 0), COALESCE(p_impuesto, true),
        COALESCE(p_maneja_stock, true), COALESCE(p_stock_minimo, 0), p_stock_maximo,
        COALESCE(p_maneja_serie, false), COALESCE(p_garantia_meses, 0),
        p_peso_kg, p_alto_cm, p_ancho_cm, p_profundidad_cm,
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

-- ---------------------------------------------------------------------------
-- 5. MODIFICAR
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION inventarios.fn_productos_modificar(
    p_id             bigint,
    p_codigo         varchar,
    p_nombre         varchar,
    p_codigo_barras  varchar DEFAULT NULL,
    p_descripcion    text    DEFAULT NULL,
    p_marca_id       bigint  DEFAULT NULL,
    p_categoria_id   bigint  DEFAULT NULL,
    p_modelo         varchar DEFAULT NULL,
    p_unidad         varchar DEFAULT 'UNIDAD',
    p_costo          numeric DEFAULT 0,
    p_precio         numeric DEFAULT 0,
    p_impuesto       boolean DEFAULT true,     -- antes era p_iva_porcentaje
    p_maneja_stock   boolean DEFAULT true,
    p_stock_minimo   numeric DEFAULT 0,
    p_stock_maximo   numeric DEFAULT NULL,
    p_maneja_serie   boolean DEFAULT false,
    p_garantia_meses integer DEFAULT 0,
    p_peso_kg        numeric DEFAULT NULL,
    p_alto_cm        numeric DEFAULT NULL,
    p_ancho_cm       numeric DEFAULT NULL,
    p_profundidad_cm numeric DEFAULT NULL,
    p_activo         boolean DEFAULT true,
    p_usuario_id     bigint  DEFAULT NULL,
    p_usuario_login  varchar DEFAULT NULL,
    p_usuario_nombre varchar DEFAULT NULL,
    p_ip_address     inet    DEFAULT NULL,
    p_user_agent     text    DEFAULT NULL,
    p_request_id     uuid    DEFAULT NULL
)
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
    -- el usuario ya van en el apunte, y repetirlos sólo estorba al leerlo
    v_antes := jsonb_build_object(
        'codigo', v_actual.codigo, 'codigo_barras', v_actual.codigo_barras,
        'nombre', v_actual.nombre, 'descripcion', v_actual.descripcion,
        'marca_id', v_actual.marca_id, 'categoria_id', v_actual.categoria_id,
        'modelo', v_actual.modelo, 'unidad', v_actual.unidad,
        'costo', v_actual.costo, 'precio', v_actual.precio, 'impuesto', v_actual.impuesto,
        'maneja_stock', v_actual.maneja_stock, 'stock_minimo', v_actual.stock_minimo, 'stock_maximo', v_actual.stock_maximo,
        'maneja_serie', v_actual.maneja_serie, 'garantia_meses', v_actual.garantia_meses,
        'peso_kg', v_actual.peso_kg, 'alto_cm', v_actual.alto_cm,
        'ancho_cm', v_actual.ancho_cm, 'profundidad_cm', v_actual.profundidad_cm,
        'activo', v_actual.activo);

    v_nuevo := jsonb_build_object(
        'codigo',         UPPER(TRIM(p_codigo)),
        'codigo_barras',  NULLIF(TRIM(COALESCE(p_codigo_barras, '')), ''),
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
        'peso_kg',        p_peso_kg,
        'alto_cm',        p_alto_cm,
        'ancho_cm',       p_ancho_cm,
        'profundidad_cm', p_profundidad_cm,
        'activo',         COALESCE(p_activo, true)
    );
    PERFORM set_config('app.datos_anteriores', v_antes::text, true);
    PERFORM set_config('app.datos_nuevos',     v_nuevo::text, true);

    UPDATE inventarios.productos
       SET codigo         = UPPER(TRIM(p_codigo)),
           codigo_barras  = NULLIF(TRIM(COALESCE(p_codigo_barras, '')), ''),
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
           peso_kg        = p_peso_kg,
           alto_cm        = p_alto_cm,
           ancho_cm       = p_ancho_cm,
           profundidad_cm = p_profundidad_cm,
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

-- ---------------------------------------------------------------------------
-- 6. LA FICHA JSON: sale el IVA, entra el impuesto
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION inventarios.fn_productos_json(p_id bigint)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
AS $function$
    SELECT jsonb_build_object(
        'id',              p.id,
        'codigo',          p.codigo,
        'codigo_barras',   p.codigo_barras,
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

        'peso_kg',         p.peso_kg,
        'alto_cm',         p.alto_cm,
        'ancho_cm',        p.ancho_cm,
        'profundidad_cm',  p.profundidad_cm,

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

-- ---------------------------------------------------------------------------
-- 7. EL LISTADO: el filtro de columna del IVA pasa a ser el del impuesto
-- ---------------------------------------------------------------------------
-- Se vuelve a crear entera (misma firma) porque sólo cambia esa condición;
-- el resto es tal cual estaba en la base.
CREATE OR REPLACE FUNCTION inventarios.fn_productos_listar_paginado(
    p_page         integer DEFAULT 1,
    p_per_page     integer DEFAULT 15,
    p_search       text    DEFAULT ''::text,
    p_marca_id     bigint  DEFAULT NULL,
    p_categoria_id bigint  DEFAULT NULL,
    p_filtros      jsonb   DEFAULT '{}'::jsonb
)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'inventarios', 'ventas'
AS $function$
DECLARE
    v_offset integer;
    v_total  bigint;
    v_data   jsonb;
    v_filtro text;
BEGIN
    v_offset := (GREATEST(p_page, 1) - 1) * GREATEST(p_per_page, 1);
    v_filtro := NULLIF(TRIM(COALESCE(p_search, '')), '');

    -- RECURSIVE es obligatorio: `rama` se llama a si misma. Sin el, plpgsql
    -- deja crear la funcion igual (no valida el SQL de dentro) y revienta la
    -- primera vez que alguien abre la rejilla.
    WITH RECURSIVE rama AS (
        -- La categoría pedida y todo lo que cuelga de ella
        SELECT c.id FROM inventarios.categorias c WHERE c.id = p_categoria_id
        UNION ALL
        SELECT h.id FROM inventarios.categorias h JOIN rama r ON h.padre_id = r.id
    ),
    filtrados AS (
        SELECT p.id
          FROM inventarios.productos p
          LEFT JOIN inventarios.marcas     m ON m.id = p.marca_id
          LEFT JOIN inventarios.categorias c ON c.id = p.categoria_id
         WHERE p.deleted_at IS NULL          -- lo de la papelera no sale
           AND (p_marca_id     IS NULL OR p.marca_id = p_marca_id)
           AND (p_categoria_id IS NULL OR p.categoria_id IN (SELECT id FROM rama))
           AND (v_filtro IS NULL
                OR p.codigo        ILIKE '%' || v_filtro || '%'
                OR p.codigo_barras ILIKE '%' || v_filtro || '%'
                OR p.nombre        ILIKE '%' || v_filtro || '%'
                OR p.descripcion   ILIKE '%' || v_filtro || '%'
                OR p.modelo        ILIKE '%' || v_filtro || '%'
                OR m.nombre        ILIKE '%' || v_filtro || '%'
                OR c.nombre        ILIKE '%' || v_filtro || '%'
                OR p.id::text      ILIKE '%' || v_filtro || '%')

           -- ---------- LOS FILTROS DE LA CABECERA ----------
           AND (p_filtros->'id'               IS NULL OR ventas.fn_filtro_numero(p.id,              p_filtros->'id'))
           AND (p_filtros->'codigo'           IS NULL OR ventas.fn_filtro_texto(p.codigo,           p_filtros->'codigo'))
           AND (p_filtros->'nombre'           IS NULL OR ventas.fn_filtro_texto(p.nombre,           p_filtros->'nombre'))
           -- Marca y categoría se filtran por su NOMBRE, que es lo que se ve
           -- en la rejilla; el id ya tiene sus propios desplegables arriba.
           AND (p_filtros->'marca_nombre'     IS NULL OR ventas.fn_filtro_texto(m.nombre,           p_filtros->'marca_nombre'))
           AND (p_filtros->'categoria_nombre' IS NULL OR ventas.fn_filtro_texto(c.nombre,           p_filtros->'categoria_nombre'))
           AND (p_filtros->'modelo'           IS NULL OR ventas.fn_filtro_texto(p.modelo,           p_filtros->'modelo'))
           AND (p_filtros->'costo'            IS NULL OR ventas.fn_filtro_numero(p.costo,           p_filtros->'costo'))
           AND (p_filtros->'precio'           IS NULL OR ventas.fn_filtro_numero(p.precio,          p_filtros->'precio'))
           -- El impuesto se filtra por lo que SE VE en la celda («Sí» / «No»),
           -- igual que el estado en las demás rejillas
           AND (p_filtros->'impuesto'         IS NULL OR ventas.fn_filtro_texto(
                   CASE WHEN p.impuesto THEN 'Sí' ELSE 'No' END, p_filtros->'impuesto'))
           AND (p_filtros->'garantia_meses'   IS NULL OR ventas.fn_filtro_numero(p.garantia_meses,  p_filtros->'garantia_meses'))
           AND (p_filtros->'stock_minimo'     IS NULL OR ventas.fn_filtro_numero(p.stock_minimo,    p_filtros->'stock_minimo'))
           -- El contador de fotos: el mismo subselect que pinta la columna
           AND (p_filtros->'num_imagenes'     IS NULL OR ventas.fn_filtro_numero(
                   (SELECT COUNT(*) FROM inventarios.productos_imagenes i WHERE i.producto_id = p.id),
                   p_filtros->'num_imagenes'))
           AND (p_filtros->'updated_by'       IS NULL OR ventas.fn_filtro_texto(p.updated_by,       p_filtros->'updated_by'))
           -- Las fechas, como texto sobre lo que se ve: «2026-10» busca el mes
           AND (p_filtros->'created_at'       IS NULL OR ventas.fn_filtro_texto(
                   to_char(p.created_at, 'YYYY-MM-DD HH24:MI:SS'), p_filtros->'created_at'))
           AND (p_filtros->'updated_at'       IS NULL OR ventas.fn_filtro_texto(
                   to_char(p.updated_at, 'YYYY-MM-DD HH24:MI:SS'), p_filtros->'updated_at'))
    )
    SELECT COUNT(*),
           COALESCE((SELECT jsonb_agg(inventarios.fn_productos_json(t.id) ORDER BY t.id DESC)
                       FROM (SELECT f.id FROM filtrados f
                              ORDER BY f.id DESC
                              LIMIT GREATEST(p_per_page, 1) OFFSET v_offset) t), '[]'::jsonb)
      INTO v_total, v_data
      FROM filtrados;

    RETURN jsonb_build_object(
        'data', v_data,
        'meta', jsonb_build_object(
            'total',        v_total,
            'per_page',     GREATEST(p_per_page, 1),
            'current_page', GREATEST(p_page, 1),
            'last_page',    CASE WHEN v_total = 0 THEN 1
                                 ELSE ceil(v_total::numeric / GREATEST(p_per_page, 1)) END
        )
    );

EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false, 'message', 'Error al listar productos: ' || SQLERRM, 'error_code', SQLSTATE);
END;
$function$;
