-- ===========================================================================
-- PAPELERA DE RECICLAJE DE PRODUCTOS (borrado lógico)
-- ===========================================================================
-- Fecha: 2026-10-15
-- Se aplica después de 2026-10-15_inventarios_productos_filtros_de_columna.sql.
--
-- La misma papelera que ya tienen usuarios y clientes
-- (ventas.fn_clientes_papelera_*): «eliminar» un producto lo manda a la
-- papelera (deleted_at / deleted_by), desde donde se restaura tal cual estaba
-- —con sus imágenes— o se borra de verdad.
--
--   inventarios.productos.deleted_at / deleted_by         columnas nuevas
--   inventarios.fn_productos_eliminar(...)                AHORA borrado lógico
--   inventarios.fn_productos_papelera_listar()            lo que hay en la papelera
--   inventarios.fn_productos_restaurar(ids, ...)          vuelven a estar vigentes
--   inventarios.fn_productos_eliminar_definitivo(ids, ...) DELETE real (sólo de la papelera)
--   inventarios.fn_productos_papelera_vaciar(...)         DELETE real de todo lo que hay
--
-- LO QUE ESTÁ EN LA PAPELERA NO SE VE EN NINGÚN SITIO: se reescriben
-- fn_productos_listar_paginado (la versión con filtros de columna de hoy) y
-- fn_productos_listar. fn_productos_json SÍ los devuelve —de ahí saca sus
-- datos la papelera— y ahora trae deleted_at / deleted_by.
--
-- Y TAMPOCO CUENTAN PARA NADA MÁS: el contador de productos de marcas y
-- categorías los descuenta, y dejan de impedir que se borre su marca o su
-- categoría. Un producto que no se ve no puede bloquear nada.
--
-- Las imágenes del producto se quedan en disco mientras está en la papelera
-- (vuelve con ellas); se borran en eliminar_definitivo / vaciar, que
-- devuelven la lista de ficheros para que lo haga el controlador.
--
-- Error de negocio nuevo: P0019 el producto no está en la papelera.
-- Idempotente: IF NOT EXISTS / CREATE OR REPLACE.
-- ===========================================================================

ALTER TABLE inventarios.productos ADD COLUMN IF NOT EXISTS deleted_at timestamptz;
ALTER TABLE inventarios.productos ADD COLUMN IF NOT EXISTS deleted_by varchar(100);
COMMENT ON COLUMN inventarios.productos.deleted_at IS 'Fecha en que se envió a la papelera de reciclaje (NULL = vigente)';
COMMENT ON COLUMN inventarios.productos.deleted_by IS 'Login de quien lo envió a la papelera';
CREATE INDEX IF NOT EXISTS ix_productos_deleted_at ON inventarios.productos (deleted_at) WHERE deleted_at IS NOT NULL;


-- ---------------------------------------------------------------------------
-- LA FICHA, AHORA CON LOS DATOS DE LA PAPELERA
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
-- EL LISTADO DE LA REJILLA: fuera lo que está en la papelera
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION inventarios.fn_productos_listar_paginado(
    p_page         integer DEFAULT 1,
    p_per_page     integer DEFAULT 15,
    p_search       text    DEFAULT '',
    p_marca_id     bigint  DEFAULT NULL,
    p_categoria_id bigint  DEFAULT NULL,
    -- Los filtros de la cabecera de ag-Grid, columna por columna
    p_filtros      jsonb   DEFAULT '{}'::jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
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
           AND (p_filtros->'iva_porcentaje'   IS NULL OR ventas.fn_filtro_numero(p.iva_porcentaje,  p_filtros->'iva_porcentaje'))
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

-- ---------------------------------------------------------------------------
-- EL COMBO (saveProducto, movimientos…): igual
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
     WHERE p.deleted_at IS NULL            -- lo de la papelera no se puede elegir
       AND (NOT p_solo_activos OR p.activo);
$function$;

-- ---------------------------------------------------------------------------
-- VALIDAR: el código repetido puede ser de uno que está en la papelera
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
-- ELIMINAR = MANDAR A LA PAPELERA
--
-- Las imágenes NO se tocan: el producto puede volver y las necesita. Se
-- borran en eliminar_definitivo / vaciar.
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
    v_actual record;
    v_antes  jsonb;
    v_fecha  timestamptz := CURRENT_TIMESTAMP;
BEGIN
    PERFORM inventarios.fn_contexto_auditoria('inventarios.productos',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    SELECT id, nombre, codigo, deleted_at INTO v_actual
      FROM inventarios.productos WHERE id = p_id;

    -- Uno que ya está en la papelera se trata como si no existiera: desde la
    -- pantalla no se puede volver a eliminar, y repetirlo tampoco debe
    -- pisar su deleted_at con una fecha nueva.
    IF NOT FOUND OR v_actual.deleted_at IS NOT NULL THEN
        RAISE EXCEPTION 'El producto no existe' USING ERRCODE = 'P0013';
    END IF;

    v_antes := inventarios.fn_productos_json(p_id);
    PERFORM set_config('app.datos_anteriores', v_antes::text, true);
    PERFORM set_config('app.datos_nuevos', (v_antes || jsonb_build_object(
        'deleted_at', to_char(v_fecha, 'YYYY-MM-DD HH24:MI:SS'), 'deleted_by', p_usuario_login
    ))::text, true);

    UPDATE inventarios.productos
       SET deleted_at = v_fecha,
           deleted_by = p_usuario_login,
           updated_by = COALESCE(p_usuario_login, updated_by),
           updated_at = v_fecha
     WHERE id = p_id;

    PERFORM set_config('app.datos_anteriores', '', true);
    PERFORM set_config('app.datos_nuevos', '', true);

    RETURN jsonb_build_object(
        'success', true,
        'message', format('Producto «%s» enviado a la papelera de reciclaje', v_actual.nombre),
        'data', inventarios.fn_productos_json(p_id)
    );
END;
$function$;


-- ---------------------------------------------------------------------------
-- LO QUE HAY EN LA PAPELERA (más reciente primero)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION inventarios.fn_productos_papelera_listar()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
AS $function$
DECLARE
    v_data jsonb;
BEGIN
    SELECT COALESCE(jsonb_agg(inventarios.fn_productos_json(p.id)
                              ORDER BY p.deleted_at DESC, p.id DESC), '[]'::jsonb)
      INTO v_data
      FROM inventarios.productos p
     WHERE p.deleted_at IS NOT NULL;

    RETURN jsonb_build_object('success', true, 'data', v_data, 'total', jsonb_array_length(v_data));
EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object('success', false, 'message', 'Error al listar la papelera: ' || SQLERRM, 'error_code', SQLSTATE);
END;
$function$;


-- ---------------------------------------------------------------------------
-- RESTAURAR (uno o varios)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION inventarios.fn_productos_restaurar(
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
    v_p       record;
    v_antes   jsonb;
    v_n       integer := 0;
    v_fecha   timestamptz := CURRENT_TIMESTAMP;
    v_nombres text[] := '{}';
BEGIN
    PERFORM inventarios.fn_contexto_auditoria('inventarios.productos',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    IF p_ids IS NULL OR jsonb_typeof(p_ids) <> 'array' OR jsonb_array_length(p_ids) = 0 THEN
        RAISE EXCEPTION 'No se indicó ningún producto' USING ERRCODE = 'P0001';
    END IF;

    FOR v_p IN
        SELECT p.id, p.nombre
          FROM inventarios.productos p
         WHERE p.id IN (SELECT (x)::bigint FROM jsonb_array_elements_text(p_ids) x)
           AND p.deleted_at IS NOT NULL
    LOOP
        v_antes := inventarios.fn_productos_json(v_p.id);
        PERFORM set_config('app.datos_anteriores', v_antes::text, true);
        PERFORM set_config('app.datos_nuevos', (v_antes || jsonb_build_object('deleted_at', NULL, 'deleted_by', NULL))::text, true);

        UPDATE inventarios.productos
           SET deleted_at = NULL, deleted_by = NULL,
               updated_by = COALESCE(p_usuario_login, updated_by), updated_at = v_fecha
         WHERE id = v_p.id;

        v_n := v_n + 1;
        v_nombres := v_nombres || v_p.nombre::text;
    END LOOP;

    PERFORM set_config('app.datos_anteriores', '', true);
    PERFORM set_config('app.datos_nuevos', '', true);

    IF v_n = 0 THEN
        RAISE EXCEPTION 'Ninguno de esos productos está en la papelera' USING ERRCODE = 'P0019';
    END IF;

    RETURN jsonb_build_object(
        'success', true,
        'message', CASE WHEN v_n = 1 THEN format('Producto «%s» restaurado', v_nombres[1])
                        ELSE format('%s productos restaurados', v_n) END,
        'data', jsonb_build_object('restaurados', v_n, 'nombres', to_jsonb(v_nombres))
    );
END;
$function$;


-- ---------------------------------------------------------------------------
-- BORRADO REAL (sólo de lo que está en la papelera)
--
-- Devuelve los ficheros de imagen para que el controlador los borre del
-- disco: la base no puede tocar storage.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION inventarios.fn_productos_eliminar_definitivo(
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
    v_p        record;
    v_n        integer := 0;
    v_ficheros text[] := '{}';
    v_nombres  text[] := '{}';
BEGIN
    PERFORM inventarios.fn_contexto_auditoria('inventarios.productos',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    IF p_ids IS NULL OR jsonb_typeof(p_ids) <> 'array' OR jsonb_array_length(p_ids) = 0 THEN
        RAISE EXCEPTION 'No se indicó ningún producto' USING ERRCODE = 'P0001';
    END IF;

    FOR v_p IN
        SELECT p.id, p.nombre
          FROM inventarios.productos p
         WHERE p.id IN (SELECT (x)::bigint FROM jsonb_array_elements_text(p_ids) x)
           AND p.deleted_at IS NOT NULL      -- sólo lo que está en la papelera
    LOOP
        -- La ficha entera a la auditoría: es lo único que no se puede volver
        -- a escribir de memoria si se borró por error
        PERFORM set_config('app.datos_anteriores', (inventarios.fn_productos_json(v_p.id))::text, true);

        SELECT v_ficheros || COALESCE(array_agg(i.archivo), '{}') INTO v_ficheros
          FROM inventarios.productos_imagenes i WHERE i.producto_id = v_p.id;

        -- Las imágenes caen con el producto (ON DELETE CASCADE)
        DELETE FROM inventarios.productos WHERE id = v_p.id;

        v_n := v_n + 1;
        v_nombres := v_nombres || v_p.nombre::text;
    END LOOP;

    PERFORM set_config('app.datos_anteriores', '', true);

    IF v_n = 0 THEN
        RAISE EXCEPTION 'Ninguno de esos productos está en la papelera' USING ERRCODE = 'P0019';
    END IF;

    RETURN jsonb_build_object(
        'success', true,
        'message', CASE WHEN v_n = 1 THEN format('Producto «%s» eliminado definitivamente', v_nombres[1])
                        ELSE format('%s productos eliminados definitivamente', v_n) END,
        'data', jsonb_build_object('borrados', v_n, 'nombres', to_jsonb(v_nombres), 'ficheros', to_jsonb(v_ficheros))
    );

EXCEPTION
    WHEN foreign_key_violation THEN
        RAISE EXCEPTION 'No se puede eliminar definitivamente: el producto tiene movimientos asociados' USING ERRCODE = 'P0014';
END;
$function$;


-- ---------------------------------------------------------------------------
-- VACIAR LA PAPELERA
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION inventarios.fn_productos_papelera_vaciar(
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
    v_ids jsonb;
BEGIN
    SELECT COALESCE(jsonb_agg(p.id), '[]'::jsonb) INTO v_ids
      FROM inventarios.productos p WHERE p.deleted_at IS NOT NULL;

    IF jsonb_array_length(v_ids) = 0 THEN
        RETURN jsonb_build_object('success', true, 'message', 'La papelera ya estaba vacía',
                                  'data', jsonb_build_object('borrados', 0, 'nombres', '[]'::jsonb, 'ficheros', '[]'::jsonb));
    END IF;

    -- Se delega en eliminar_definitivo para no tener dos sitios donde se
    -- borra de verdad: uno de los dos acabaría olvidándose de algo.
    RETURN inventarios.fn_productos_eliminar_definitivo(v_ids,
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);
END;
$function$;


-- ---------------------------------------------------------------------------
-- MARCAS Y CATEGORÍAS: sus contadores no cuentan lo de la papelera
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION inventarios.fn_marcas_json(p_id bigint)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
AS $function$
    SELECT jsonb_build_object(
        'id',            m.id,
        'nombre',        m.nombre,
        'descripcion',   m.descripcion,
        'pais_origen',   m.pais_origen,
        'sitio_web',     m.sitio_web,
        'logo',          m.logo,
        'activo',        m.activo,
        'num_productos', (SELECT COUNT(*) FROM inventarios.productos p WHERE p.marca_id = m.id AND p.deleted_at IS NULL),
        'created_by',    m.created_by,
        'updated_by',    m.updated_by,
        'created_at',    to_char(m.created_at, 'YYYY-MM-DD HH24:MI:SS'),
        'updated_at',    to_char(m.updated_at, 'YYYY-MM-DD HH24:MI:SS')
    )
      FROM inventarios.marcas m
     WHERE m.id = p_id;
$function$;

CREATE OR REPLACE FUNCTION inventarios.fn_categorias_json(p_id bigint)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
AS $function$
    WITH RECURSIVE subida AS (
        SELECT c.id, c.padre_id, c.nombre, 0 AS salto
          FROM inventarios.categorias c WHERE c.id = p_id
        UNION ALL
        SELECT p.id, p.padre_id, p.nombre, s.salto + 1
          FROM inventarios.categorias p JOIN subida s ON p.id = s.padre_id
    )
    SELECT jsonb_build_object(
        'id',            c.id,
        'padre_id',      c.padre_id,
        'padre_nombre',  (SELECT x.nombre FROM inventarios.categorias x WHERE x.id = c.padre_id),
        'orden',         c.orden,
        'nivel',         c.nivel,
        'nombre',        c.nombre,
        'ruta',          (SELECT string_agg(s.nombre, ' > ' ORDER BY s.salto DESC) FROM subida s),
        'descripcion',   c.descripcion,
        'icono',         c.icono,
        'activo',        c.activo,
        'num_hijos',     (SELECT COUNT(*) FROM inventarios.categorias h WHERE h.padre_id = c.id),
        'num_productos', (SELECT COUNT(*) FROM inventarios.productos p WHERE p.categoria_id = c.id AND p.deleted_at IS NULL),
        'created_by',    c.created_by,
        'updated_by',    c.updated_by,
        'created_at',    to_char(c.created_at, 'YYYY-MM-DD HH24:MI:SS'),
        'updated_at',    to_char(c.updated_at, 'YYYY-MM-DD HH24:MI:SS')
    )
      FROM inventarios.categorias c
     WHERE c.id = p_id;
$function$;

-- ---------------------------------------------------------------------------
-- NI LES IMPIDE BORRARSE
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION inventarios.fn_marcas_eliminar(
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
    v_antes     jsonb;
    v_productos bigint;
    v_logo      varchar;
BEGIN
    PERFORM inventarios.fn_contexto_auditoria('inventarios.marcas',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    v_antes := inventarios.fn_marcas_json(p_id);
    IF v_antes IS NULL THEN
        RAISE EXCEPTION 'La marca no existe' USING ERRCODE = 'P0013';
    END IF;

    -- Los de la papelera no cuentan: no se ven en ningún listado y
    -- bloquear por ellos no habría quien lo entendiera.
    SELECT COUNT(*) INTO v_productos FROM inventarios.productos WHERE marca_id = p_id AND deleted_at IS NULL;
    IF v_productos > 0 THEN
        RAISE EXCEPTION 'No se puede eliminar: la marca tiene % producto(s). Desactívela en lugar de borrarla.', v_productos
            USING ERRCODE = 'P0014';
    END IF;

    SELECT logo INTO v_logo FROM inventarios.marcas WHERE id = p_id;

    -- La marca entera queda en la auditoría: es lo único que no se puede
    -- volver a escribir de memoria si se borró por error
    PERFORM set_config('app.datos_anteriores', v_antes::text, true);
    DELETE FROM inventarios.marcas WHERE id = p_id;
    PERFORM set_config('app.datos_anteriores', '', true);

    -- El fichero del logo lo borra el controlador, que es quien sabe de disco
    RETURN jsonb_build_object('success', true, 'message', 'Marca eliminada exitosamente',
                              'data', jsonb_build_object('id', p_id, 'logo', v_logo));
END;
$function$;

CREATE OR REPLACE FUNCTION inventarios.fn_categorias_eliminar(
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
    v_antes     jsonb;
    v_padre     bigint;
    v_hijos     bigint;
    v_productos bigint;
    v_i         integer := 0;
    v_fila      record;
BEGIN
    PERFORM inventarios.fn_contexto_auditoria('inventarios.categorias',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    v_antes := inventarios.fn_categorias_json(p_id);
    IF v_antes IS NULL THEN
        RAISE EXCEPTION 'La categoría no existe' USING ERRCODE = 'P0013';
    END IF;
    SELECT padre_id INTO v_padre FROM inventarios.categorias WHERE id = p_id;

    SELECT COUNT(*) INTO v_hijos FROM inventarios.categorias WHERE padre_id = p_id;
    IF v_hijos > 0 THEN
        RAISE EXCEPTION 'No se puede eliminar: la categoría tiene % subcategoría(s). Muévalas o bórrelas primero.', v_hijos
            USING ERRCODE = 'P0014';
    END IF;

    -- Los de la papelera no cuentan (ver fn_marcas_eliminar)
    SELECT COUNT(*) INTO v_productos FROM inventarios.productos WHERE categoria_id = p_id AND deleted_at IS NULL;
    IF v_productos > 0 THEN
        RAISE EXCEPTION 'No se puede eliminar: la categoría tiene % producto(s). Desactívela en lugar de borrarla.', v_productos
            USING ERRCODE = 'P0014';
    END IF;

    PERFORM set_config('app.datos_anteriores', v_antes::text, true);
    DELETE FROM inventarios.categorias WHERE id = p_id;
    PERFORM set_config('app.datos_anteriores', '', true);

    -- Los hermanos que quedan se renumeran sin huecos: si no, el siguiente
    -- alta cogería un `orden` repetido y dos categorías empatarían
    FOR v_fila IN
        SELECT id FROM inventarios.categorias
         WHERE padre_id IS NOT DISTINCT FROM v_padre
         ORDER BY orden, nombre
    LOOP
        v_i := v_i + 1;
        UPDATE inventarios.categorias SET orden = v_i WHERE id = v_fila.id AND orden IS DISTINCT FROM v_i;
    END LOOP;

    RETURN jsonb_build_object('success', true, 'message', 'Categoría eliminada exitosamente',
                              'data', jsonb_build_object('id', p_id));
END;
$function$;

-- ---------------------------------------------------------------------------
-- PERMISOS Y COMENTARIOS
-- ---------------------------------------------------------------------------
ALTER FUNCTION inventarios.fn_productos_papelera_listar() OWNER TO postgres;
ALTER FUNCTION inventarios.fn_productos_restaurar(jsonb, bigint, varchar, varchar, inet, text, uuid) OWNER TO postgres;
ALTER FUNCTION inventarios.fn_productos_eliminar_definitivo(jsonb, bigint, varchar, varchar, inet, text, uuid) OWNER TO postgres;
ALTER FUNCTION inventarios.fn_productos_papelera_vaciar(bigint, varchar, varchar, inet, text, uuid) OWNER TO postgres;

COMMENT ON FUNCTION inventarios.fn_productos_eliminar(bigint, bigint, varchar, varchar, inet, text, uuid) IS 'Envía el producto a la papelera de reciclaje (borrado lógico)';
COMMENT ON FUNCTION inventarios.fn_productos_papelera_listar() IS 'Productos que están en la papelera de reciclaje';
COMMENT ON FUNCTION inventarios.fn_productos_restaurar(jsonb, bigint, varchar, varchar, inet, text, uuid) IS 'Saca de la papelera uno o varios productos';
COMMENT ON FUNCTION inventarios.fn_productos_eliminar_definitivo(jsonb, bigint, varchar, varchar, inet, text, uuid) IS 'Borrado real de productos que están en la papelera; devuelve los ficheros de imagen a borrar';
COMMENT ON FUNCTION inventarios.fn_productos_papelera_vaciar(bigint, varchar, varchar, inet, text, uuid) IS 'Borrado real de todo lo que hay en la papelera de productos';
