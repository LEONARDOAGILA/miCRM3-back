-- ============================================================================
-- INVENTARIOS — FUNCIONES DE PRODUCTOS Y SU GALERÍA
-- ============================================================================
-- Fecha: 2026-10-14
-- Se aplica después de 2026-10-14_inventarios_marcas_categorias.sql.
--
-- Códigos de error, los mismos del módulo:
--   P0001 falta un dato obligatorio    P0006 duplicado
--   P0013 no existe                    P0014 tiene dependencias
--   P0015 valor inválido               P0016 la referencia no existe
--
-- LAS IMÁGENES SE GUARDAN EN DOS SITIOS Y EL ORDEN IMPORTA: el fichero va a
-- storage (lo hace el controlador) y su nombre a la tabla (lo hace esto). Las
-- funciones de borrado DEVUELVEN el nombre del fichero para que el
-- controlador lo quite del disco DESPUÉS de que la base haya confirmado;
-- borrar el fichero antes dejaría la fila apuntando a nada si la transacción
-- se cae.
--
-- Idempotente: CREATE OR REPLACE.
-- ============================================================================


-- ---------------------------------------------------------------------------
-- UN PRODUCTO, EN LA FORMA EN QUE LO PINTA LA REJILLA
--
-- Trae los nombres de marca y categoría ya resueltos —la rejilla no va a
-- hacer una consulta por fila— y la imagen principal, que es la que sale en
-- la columna Foto.
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
        'iva_porcentaje',  p.iva_porcentaje,

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

        'created_by',      p.created_by,
        'updated_by',      p.updated_by,
        'created_at',      to_char(p.created_at, 'YYYY-MM-DD HH24:MI:SS'),
        'updated_at',      to_char(p.updated_at, 'YYYY-MM-DD HH24:MI:SS')
    )
      FROM inventarios.productos p
     WHERE p.id = p_id;
$function$;


-- ---------------------------------------------------------------------------
-- LA GALERÍA DE UN PRODUCTO
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION inventarios.fn_productos_imagenes(p_producto_id bigint)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
AS $function$
    SELECT COALESCE(jsonb_agg(
        jsonb_build_object(
            'id',              i.id,
            'producto_id',     i.producto_id,
            'archivo',         i.archivo,
            'nombre_original', i.nombre_original,
            'orden',           i.orden,
            'principal',       i.principal
        ) ORDER BY i.orden, i.id
    ), '[]'::jsonb)
      FROM inventarios.productos_imagenes i
     WHERE i.producto_id = p_producto_id;
$function$;


-- ---------------------------------------------------------------------------
-- LISTADO PAGINADO (rejilla)
--
-- Con filtro por marca y categoría además del buscador: en un catálogo de
-- electrodomésticos «ver sólo las refrigeradoras Samsung» es la consulta de
-- todos los días, y hacerlo con el buscador de texto es adivinar.
--
-- La categoría filtra POR RAMA: pedir «Línea Blanca» trae también lo que
-- cuelga de Refrigeración y de Lavado. Filtrar sólo por el nodo exacto no
-- serviría de nada, porque los productos cuelgan de las hojas.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION inventarios.fn_productos_listar_paginado(
    p_page         integer DEFAULT 1,
    p_per_page     integer DEFAULT 15,
    p_search       text    DEFAULT '',
    p_marca_id     bigint  DEFAULT NULL,
    p_categoria_id bigint  DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'inventarios'
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
         WHERE (p_marca_id     IS NULL OR p.marca_id = p_marca_id)
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


-- ---------------------------------------------------------------------------
-- LISTA SIMPLE (combos / buscadores de otras pantallas)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION inventarios.fn_productos_listar(p_solo_activos boolean DEFAULT true)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
AS $function$
    SELECT jsonb_build_object(
        'success', true,
        'data', COALESCE(jsonb_agg(
            jsonb_build_object('id', p.id, 'codigo', p.codigo, 'nombre', p.nombre,
                               'precio', p.precio, 'activo', p.activo)
            ORDER BY p.nombre
        ), '[]'::jsonb)
    )
      FROM inventarios.productos p
     WHERE NOT p_solo_activos OR p.activo;
$function$;


-- ---------------------------------------------------------------------------
-- UNO SOLO, CON SU GALERÍA
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION inventarios.fn_productos_obtener(p_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
AS $function$
DECLARE
    v_data jsonb;
BEGIN
    v_data := inventarios.fn_productos_json(p_id);
    IF v_data IS NULL THEN
        RAISE EXCEPTION 'El producto no existe' USING ERRCODE = 'P0013';
    END IF;

    -- La galería sólo aquí, no en el listado: son N filas por producto y la
    -- rejilla con quince productos pediría quince consultas para nada
    v_data := v_data || jsonb_build_object('imagenes', inventarios.fn_productos_imagenes(p_id));

    RETURN jsonb_build_object('success', true, 'message', 'Producto encontrado', 'data', v_data);
END;
$function$;


-- ---------------------------------------------------------------------------
-- REGLAS COMUNES AL ALTA Y A LA MODIFICACIÓN
--
-- En una función aparte porque son las mismas y tenerlas dos veces es
-- garantizar que acaben distintas. `p_id` es NULL al crear.
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
    p_iva           numeric,
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
        RAISE EXCEPTION 'Ya existe un producto con el código %', UPPER(TRIM(p_codigo)) USING ERRCODE = 'P0006';
    END IF;

    IF NULLIF(TRIM(COALESCE(p_codigo_barras, '')), '') IS NOT NULL
       AND EXISTS (SELECT 1 FROM inventarios.productos
                    WHERE UPPER(TRIM(codigo_barras)) = UPPER(TRIM(p_codigo_barras))
                      AND (p_id IS NULL OR id <> p_id)) THEN
        RAISE EXCEPTION 'Ya existe un producto con ese código de barras' USING ERRCODE = 'P0006';
    END IF;

    IF p_marca_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM inventarios.marcas WHERE id = p_marca_id) THEN
        RAISE EXCEPTION 'La marca indicada no existe' USING ERRCODE = 'P0016';
    END IF;
    IF p_categoria_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM inventarios.categorias WHERE id = p_categoria_id) THEN
        RAISE EXCEPTION 'La categoría indicada no existe' USING ERRCODE = 'P0016';
    END IF;

    IF COALESCE(p_costo, 0)  < 0 THEN RAISE EXCEPTION 'El costo no puede ser negativo'  USING ERRCODE = 'P0015'; END IF;
    IF COALESCE(p_precio, 0) < 0 THEN RAISE EXCEPTION 'El precio no puede ser negativo' USING ERRCODE = 'P0015'; END IF;
    IF COALESCE(p_iva, 0) < 0 OR COALESCE(p_iva, 0) > 100 THEN
        RAISE EXCEPTION 'El IVA debe estar entre 0 y 100' USING ERRCODE = 'P0015';
    END IF;
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
-- ALTA
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
    p_iva_porcentaje numeric DEFAULT 15,
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
        p_costo, p_precio, p_iva_porcentaje, p_stock_minimo, p_stock_maximo, p_garantia_meses);

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
        'iva_porcentaje', COALESCE(p_iva_porcentaje, 15),
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

    INSERT INTO inventarios.productos (
        codigo, codigo_barras, nombre, descripcion,
        marca_id, categoria_id, modelo,
        unidad, costo, precio, iva_porcentaje,
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
        COALESCE(p_costo, 0), COALESCE(p_precio, 0), COALESCE(p_iva_porcentaje, 15),
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
-- MODIFICACIÓN
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
    p_iva_porcentaje numeric DEFAULT 15,
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
        p_costo, p_precio, p_iva_porcentaje, p_stock_minimo, p_stock_maximo, p_garantia_meses);

    -- A la auditoría va la ficha comercial, no la fila entera: las fechas y
    -- el usuario ya van en el apunte, y repetirlos sólo estorba al leerlo
    v_antes := jsonb_build_object(
        'codigo', v_actual.codigo, 'codigo_barras', v_actual.codigo_barras,
        'nombre', v_actual.nombre, 'descripcion', v_actual.descripcion,
        'marca_id', v_actual.marca_id, 'categoria_id', v_actual.categoria_id,
        'modelo', v_actual.modelo, 'unidad', v_actual.unidad,
        'costo', v_actual.costo, 'precio', v_actual.precio, 'iva_porcentaje', v_actual.iva_porcentaje,
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
        'iva_porcentaje', COALESCE(p_iva_porcentaje, 15),
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
           iva_porcentaje = COALESCE(p_iva_porcentaje, 15),
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
-- BAJA
--
-- DEVUELVE LA LISTA DE FICHEROS de la galería: el ON DELETE CASCADE se lleva
-- las filas, pero los ficheros los tiene que quitar el controlador, que es
-- quien sabe de disco. Sin esta lista quedarían huérfanos en storage para
-- siempre.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION inventarios.fn_productos_eliminar(
    p_id             bigint,
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
    v_antes    jsonb;
    v_archivos jsonb;
BEGIN
    PERFORM inventarios.fn_contexto_auditoria('inventarios.productos',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    v_antes := inventarios.fn_productos_json(p_id);
    IF v_antes IS NULL THEN
        RAISE EXCEPTION 'El producto no existe' USING ERRCODE = 'P0013';
    END IF;

    SELECT COALESCE(jsonb_agg(i.archivo), '[]'::jsonb) INTO v_archivos
      FROM inventarios.productos_imagenes i WHERE i.producto_id = p_id;

    -- La ficha entera a la auditoría: es lo único que no se puede volver a
    -- escribir de memoria si se borró por error
    PERFORM set_config('app.datos_anteriores', v_antes::text, true);
    DELETE FROM inventarios.productos WHERE id = p_id;
    PERFORM set_config('app.datos_anteriores', '', true);

    RETURN jsonb_build_object('success', true, 'message', 'Producto eliminado exitosamente',
                              'data', jsonb_build_object('id', p_id, 'archivos', v_archivos));
END;
$function$;


-- ---------------------------------------------------------------------------
-- ACTIVAR / DESACTIVAR (sólo esa columna)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION inventarios.fn_productos_activar(
    p_id             bigint,
    p_activo         boolean DEFAULT NULL,
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
    v_antes      boolean;
    v_nuevo      boolean;
    v_updated_by varchar;
    v_updated_at text;
BEGIN
    PERFORM inventarios.fn_contexto_auditoria('inventarios.productos',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    SELECT activo INTO v_antes FROM inventarios.productos WHERE id = p_id;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'error_code', 'NO_EXISTE', 'message', 'El producto no existe');
    END IF;

    v_nuevo := COALESCE(p_activo, NOT v_antes);

    IF v_nuevo IS NOT DISTINCT FROM v_antes THEN
        SELECT updated_by, to_char(updated_at, 'YYYY-MM-DD HH24:MI:SS')
          INTO v_updated_by, v_updated_at FROM inventarios.productos WHERE id = p_id;
        RETURN jsonb_build_object('success', true,
            'message', CASE WHEN v_nuevo THEN 'El producto ya estaba activo' ELSE 'El producto ya estaba inactivo' END,
            'data', jsonb_build_object('id', p_id, 'activo', v_nuevo,
                                       'updated_by', v_updated_by, 'updated_at', v_updated_at));
    END IF;

    PERFORM set_config('app.datos_anteriores', jsonb_build_object('id', p_id, 'activo', v_antes)::text, true);
    PERFORM set_config('app.datos_nuevos',     jsonb_build_object('id', p_id, 'activo', v_nuevo)::text, true);

    UPDATE inventarios.productos SET activo = v_nuevo WHERE id = p_id
    RETURNING activo, updated_by, to_char(updated_at, 'YYYY-MM-DD HH24:MI:SS')
         INTO v_nuevo, v_updated_by, v_updated_at;

    PERFORM set_config('app.datos_anteriores', '', true);
    PERFORM set_config('app.datos_nuevos', '', true);

    RETURN jsonb_build_object('success', true,
        'message', CASE WHEN v_nuevo THEN 'Producto activado' ELSE 'Producto desactivado' END,
        'data', jsonb_build_object('id', p_id, 'activo', v_nuevo,
                                   'updated_by', v_updated_by, 'updated_at', v_updated_at));

EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false, 'error_code', 'ERROR',
                              'message', 'No se pudo cambiar el estado del producto: ' || SQLERRM);
END;
$function$;


-- ===========================================================================
--                         L A   G A L E R Í A
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- AÑADIR UNA IMAGEN
--
-- La primera que entra se marca PRINCIPAL sola: un producto con fotos y
-- ninguna principal saldría sin foto en la rejilla, y nadie entiende por qué.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION inventarios.fn_productos_imagen_agregar(
    p_producto_id     bigint,
    p_archivo         varchar,
    p_nombre_original varchar DEFAULT NULL,
    p_usuario_id      bigint  DEFAULT NULL,
    p_usuario_login   varchar DEFAULT NULL,
    p_usuario_nombre  varchar DEFAULT NULL,
    p_ip_address      inet    DEFAULT NULL,
    p_user_agent      text    DEFAULT NULL,
    p_request_id      uuid    DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'inventarios', 'auditoria'
AS $function$
DECLARE
    v_id        bigint;
    v_orden     integer;
    v_principal boolean;
BEGIN
    PERFORM inventarios.fn_contexto_auditoria('inventarios.productos_imagenes',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    IF NOT EXISTS (SELECT 1 FROM inventarios.productos WHERE id = p_producto_id) THEN
        RAISE EXCEPTION 'El producto no existe' USING ERRCODE = 'P0013';
    END IF;
    IF p_archivo IS NULL OR TRIM(p_archivo) = '' THEN
        RAISE EXCEPTION 'Falta el nombre del fichero' USING ERRCODE = 'P0001';
    END IF;

    SELECT COALESCE(MAX(orden), 0) + 1 INTO v_orden
      FROM inventarios.productos_imagenes WHERE producto_id = p_producto_id;

    v_principal := NOT EXISTS (SELECT 1 FROM inventarios.productos_imagenes
                                WHERE producto_id = p_producto_id AND principal);

    INSERT INTO inventarios.productos_imagenes (producto_id, archivo, nombre_original, orden, principal)
    VALUES (p_producto_id, TRIM(p_archivo),
            NULLIF(TRIM(COALESCE(p_nombre_original, '')), ''), v_orden, v_principal)
    RETURNING id INTO v_id;

    RETURN jsonb_build_object('success', true, 'message', 'Imagen agregada',
                              'data', jsonb_build_object(
                                  'id', v_id, 'principal', v_principal,
                                  'imagenes', inventarios.fn_productos_imagenes(p_producto_id)));

EXCEPTION
    WHEN unique_violation THEN
        RAISE EXCEPTION 'Ese fichero ya está en la galería del producto' USING ERRCODE = 'P0006';
END;
$function$;


-- ---------------------------------------------------------------------------
-- QUITAR UNA IMAGEN
--
-- Si la que se va era la principal, otra ocupa su sitio: dejar al producto
-- sin principal teniendo fotos es el mismo problema de antes.
-- Devuelve el nombre del fichero para que el controlador lo borre del disco.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION inventarios.fn_productos_imagen_eliminar(
    p_id             bigint,
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
    v_producto  bigint;
    v_archivo   varchar;
    v_principal boolean;
    v_relevo    bigint;
BEGIN
    PERFORM inventarios.fn_contexto_auditoria('inventarios.productos_imagenes',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    SELECT producto_id, archivo, principal INTO v_producto, v_archivo, v_principal
      FROM inventarios.productos_imagenes WHERE id = p_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'La imagen no existe' USING ERRCODE = 'P0013';
    END IF;

    DELETE FROM inventarios.productos_imagenes WHERE id = p_id;

    IF v_principal THEN
        SELECT id INTO v_relevo FROM inventarios.productos_imagenes
         WHERE producto_id = v_producto ORDER BY orden, id LIMIT 1;
        IF v_relevo IS NOT NULL THEN
            UPDATE inventarios.productos_imagenes SET principal = true WHERE id = v_relevo;
        END IF;
    END IF;

    RETURN jsonb_build_object('success', true, 'message', 'Imagen eliminada',
                              'data', jsonb_build_object(
                                  'id', p_id, 'archivo', v_archivo, 'producto_id', v_producto,
                                  'imagenes', inventarios.fn_productos_imagenes(v_producto)));
END;
$function$;


-- ---------------------------------------------------------------------------
-- MARCAR LA PRINCIPAL
--
-- Primero se apaga la que había y DESPUÉS se enciende la nueva: el índice
-- único parcial sólo deja una principal por producto, y hacerlo al revés
-- choca contra él.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION inventarios.fn_productos_imagen_principal(
    p_id             bigint,
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
    v_producto bigint;
BEGIN
    PERFORM inventarios.fn_contexto_auditoria('inventarios.productos_imagenes',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    SELECT producto_id INTO v_producto FROM inventarios.productos_imagenes WHERE id = p_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'La imagen no existe' USING ERRCODE = 'P0013';
    END IF;

    UPDATE inventarios.productos_imagenes SET principal = false
     WHERE producto_id = v_producto AND principal AND id <> p_id;

    UPDATE inventarios.productos_imagenes SET principal = true
     WHERE id = p_id AND NOT principal;

    RETURN jsonb_build_object('success', true, 'message', 'Imagen principal actualizada',
                              'data', jsonb_build_object(
                                  'id', p_id, 'producto_id', v_producto,
                                  'imagenes', inventarios.fn_productos_imagenes(v_producto)));
END;
$function$;


-- ---------------------------------------------------------------------------
-- REORDENAR LA GALERÍA
--
-- Llega la lista de ids en el orden que quedó tras arrastrar. Las que no
-- vengan en la lista se van detrás, por su orden de antes: así una imagen
-- subida en otra pestaña mientras se arrastraba no desaparece ni rompe nada.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION inventarios.fn_productos_imagenes_ordenar(
    p_producto_id    bigint,
    p_ids            jsonb,
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
    v_fila record;
    v_i    integer := 0;
BEGIN
    PERFORM inventarios.fn_contexto_auditoria('inventarios.productos_imagenes',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    IF NOT EXISTS (SELECT 1 FROM inventarios.productos WHERE id = p_producto_id) THEN
        RAISE EXCEPTION 'El producto no existe' USING ERRCODE = 'P0013';
    END IF;

    FOR v_fila IN
        SELECT i.id
          FROM inventarios.productos_imagenes i
          LEFT JOIN LATERAL (
              SELECT ord.pos
                FROM jsonb_array_elements_text(COALESCE(p_ids, '[]'::jsonb))
                     WITH ORDINALITY AS ord(id_txt, pos)
               WHERE ord.id_txt = i.id::text
          ) pedido ON true
         WHERE i.producto_id = p_producto_id
         ORDER BY pedido.pos NULLS LAST, i.orden, i.id
    LOOP
        v_i := v_i + 1;
        UPDATE inventarios.productos_imagenes SET orden = v_i
         WHERE id = v_fila.id AND orden IS DISTINCT FROM v_i;
    END LOOP;

    RETURN jsonb_build_object('success', true, 'message', 'Orden de la galería actualizado',
                              'data', jsonb_build_object(
                                  'producto_id', p_producto_id,
                                  'imagenes', inventarios.fn_productos_imagenes(p_producto_id)));
END;
$function$;


-- ---------------------------------------------------------------------------
-- PROPIEDAD
-- ---------------------------------------------------------------------------
DO $$
DECLARE r record;
BEGIN
    FOR r IN SELECT p.oid::regprocedure AS firma
               FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
              WHERE n.nspname = 'inventarios'
    LOOP
        EXECUTE format('ALTER FUNCTION %s OWNER TO postgres', r.firma);
    END LOOP;
END $$;


-- ---------------------------------------------------------------------------
-- COMPROBACIÓN
-- ---------------------------------------------------------------------------
SELECT p.proname
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname = 'inventarios' AND p.proname LIKE 'fn_productos%'
 ORDER BY 1;
