-- ===========================================================================
-- MARCAS: FILTROS DE COLUMNA Y PAPELERA DE RECICLAJE
-- ===========================================================================
-- Fecha: 2026-10-16
-- Se aplica después de 2026-10-15_inventarios_categorias_papelera.sql.
--
-- Lo mismo que ya tienen productos y categorías, ahora en marcas:
--
--   1) LOS FILTROS DE LA CABECERA SE APLICAN EN EL SERVIDOR. La rejilla
--      pagina, así que ag-Grid sólo tiene las filas de la página y filtrar
--      ahí buscaría dentro de quince. El modelo llega en p_filtros:
--
--          {"nombre": {"op":"contains","valor":"sam"},
--           "num_productos": {"op":"greaterThan","valor":0}}
--
--      Se reusan ventas.fn_filtro_texto y ventas.fn_filtro_numero.
--
--   2) PAPELERA DE RECICLAJE. «Eliminar» una marca la manda a la papelera
--      (deleted_at / deleted_by); desde allí se restaura o se borra de
--      verdad. Su logo se queda en disco mientras está en la papelera —vuelve
--      con ella— y se borra en eliminar_definitivo / vaciar, que devuelven
--      los ficheros para que lo haga el controlador.
--
-- LO QUE ESTÁ EN LA PAPELERA NO SE VE EN NINGÚN SITIO: ni en el listado, ni
-- en el combo de marcas, ni se puede asignar a un producto.
--
-- Se mantiene la regla de siempre: una marca con productos no se elimina.
--
-- Cambia la firma del listado, así que se suelta la función antes.
-- Error de negocio nuevo: P0019 la marca no está en la papelera.
-- Idempotente.
-- ===========================================================================

ALTER TABLE inventarios.marcas ADD COLUMN IF NOT EXISTS deleted_at timestamptz;
ALTER TABLE inventarios.marcas ADD COLUMN IF NOT EXISTS deleted_by varchar(100);
COMMENT ON COLUMN inventarios.marcas.deleted_at IS 'Fecha en que se envió a la papelera de reciclaje (NULL = vigente)';
COMMENT ON COLUMN inventarios.marcas.deleted_by IS 'Login de quien la envió a la papelera';
CREATE INDEX IF NOT EXISTS ix_marcas_deleted_at ON inventarios.marcas (deleted_at) WHERE deleted_at IS NOT NULL;


-- ---------------------------------------------------------------------------
-- LA FICHA, AHORA CON LOS DATOS DE LA PAPELERA
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
        -- La papelera: NULL mientras la marca está vigente
        'deleted_at',    to_char(m.deleted_at, 'YYYY-MM-DD HH24:MI:SS'),
        'deleted_by',    m.deleted_by,

        'created_by',    m.created_by,
        'updated_by',    m.updated_by,
        'created_at',    to_char(m.created_at, 'YYYY-MM-DD HH24:MI:SS'),
        'updated_at',    to_char(m.updated_at, 'YYYY-MM-DD HH24:MI:SS')
    )
      FROM inventarios.marcas m
     WHERE m.id = p_id;
$function$;

-- ---------------------------------------------------------------------------
-- EL COMBO DE MARCAS: fuera lo que está en la papelera
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION inventarios.fn_marcas_listar(p_solo_activos boolean DEFAULT true)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
AS $function$
    SELECT jsonb_build_object(
        'success', true,
        'data', COALESCE(jsonb_agg(
            jsonb_build_object('id', m.id, 'nombre', m.nombre, 'logo', m.logo, 'activo', m.activo)
            ORDER BY m.nombre
        ), '[]'::jsonb)
    )
      FROM inventarios.marcas m
     WHERE m.deleted_at IS NULL            -- lo de la papelera no se puede elegir
       AND (NOT p_solo_activos OR m.activo);
$function$;

-- ---------------------------------------------------------------------------
-- VALIDAR UN PRODUCTO: su marca tiene que estar vigente
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

    -- Y que no esté en la papelera: no sale en ningún combo, así que si
    -- llega es de una pantalla con datos viejos.
    IF p_marca_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM inventarios.marcas WHERE id = p_marca_id AND deleted_at IS NULL) THEN
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
-- EL LISTADO DE LA REJILLA: filtros de columna y sin la papelera
--
-- NADA DE SQL DINÁMICO: las columnas filtrables están escritas una a una,
-- cada una detrás de `p_filtros->'columna' IS NULL OR …`.
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS inventarios.fn_marcas_listar_paginado(integer, integer, text);

CREATE OR REPLACE FUNCTION inventarios.fn_marcas_listar_paginado(
    p_page     integer DEFAULT 1,
    p_per_page integer DEFAULT 15,
    p_search   text    DEFAULT '',
    -- Los filtros de la cabecera de ag-Grid, columna por columna
    p_filtros  jsonb   DEFAULT '{}'::jsonb
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

    WITH filtradas AS (
        SELECT m.id
          FROM inventarios.marcas m
         WHERE m.deleted_at IS NULL          -- lo de la papelera no sale
           AND (v_filtro IS NULL
                OR m.nombre      ILIKE '%' || v_filtro || '%'
                OR m.descripcion ILIKE '%' || v_filtro || '%'
                OR m.pais_origen ILIKE '%' || v_filtro || '%'
                OR m.sitio_web   ILIKE '%' || v_filtro || '%'
                OR m.id::text    ILIKE '%' || v_filtro || '%')

           -- ---------- LOS FILTROS DE LA CABECERA ----------
           AND (p_filtros->'id'            IS NULL OR ventas.fn_filtro_numero(m.id,          p_filtros->'id'))
           AND (p_filtros->'nombre'        IS NULL OR ventas.fn_filtro_texto(m.nombre,       p_filtros->'nombre'))
           AND (p_filtros->'pais_origen'   IS NULL OR ventas.fn_filtro_texto(m.pais_origen,  p_filtros->'pais_origen'))
           AND (p_filtros->'sitio_web'     IS NULL OR ventas.fn_filtro_texto(m.sitio_web,    p_filtros->'sitio_web'))
           AND (p_filtros->'descripcion'   IS NULL OR ventas.fn_filtro_texto(m.descripcion,  p_filtros->'descripcion'))
           -- El contador de productos: el mismo subselect que pinta la columna
           AND (p_filtros->'num_productos' IS NULL OR ventas.fn_filtro_numero(
                   (SELECT COUNT(*) FROM inventarios.productos p WHERE p.marca_id = m.id AND p.deleted_at IS NULL),
                   p_filtros->'num_productos'))
           AND (p_filtros->'created_by'    IS NULL OR ventas.fn_filtro_texto(m.created_by,   p_filtros->'created_by'))
           AND (p_filtros->'updated_by'    IS NULL OR ventas.fn_filtro_texto(m.updated_by,   p_filtros->'updated_by'))
           -- Las fechas, como texto sobre lo que se ve: «2026-10» busca el mes
           AND (p_filtros->'created_at'    IS NULL OR ventas.fn_filtro_texto(
                   to_char(m.created_at, 'YYYY-MM-DD HH24:MI:SS'), p_filtros->'created_at'))
           AND (p_filtros->'updated_at'    IS NULL OR ventas.fn_filtro_texto(
                   to_char(m.updated_at, 'YYYY-MM-DD HH24:MI:SS'), p_filtros->'updated_at'))
    )
    SELECT COUNT(*),
           COALESCE((SELECT jsonb_agg(inventarios.fn_marcas_json(t.id) ORDER BY t.id DESC)
                       FROM (SELECT f.id FROM filtradas f
                              ORDER BY f.id DESC
                              LIMIT GREATEST(p_per_page, 1) OFFSET v_offset) t), '[]'::jsonb)
      INTO v_total, v_data
      FROM filtradas;

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
    RETURN jsonb_build_object('success', false, 'message', 'Error al listar marcas: ' || SQLERRM, 'error_code', SQLSTATE);
END;
$function$;


-- ---------------------------------------------------------------------------
-- ELIMINAR = MANDAR A LA PAPELERA
--
-- Se mantiene la condición de siempre: una marca con productos vigentes no
-- se elimina. El logo NO se toca: la marca puede volver y lo necesita.
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
    v_actual    record;
    v_antes     jsonb;
    v_productos bigint;
    v_fecha     timestamptz := CURRENT_TIMESTAMP;
BEGIN
    PERFORM inventarios.fn_contexto_auditoria('inventarios.marcas',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    SELECT id, nombre, deleted_at INTO v_actual FROM inventarios.marcas WHERE id = p_id;
    IF NOT FOUND OR v_actual.deleted_at IS NOT NULL THEN
        RAISE EXCEPTION 'La marca no existe' USING ERRCODE = 'P0013';
    END IF;

    -- Los de la papelera no cuentan: no se ven en ningún listado
    SELECT COUNT(*) INTO v_productos
      FROM inventarios.productos WHERE marca_id = p_id AND deleted_at IS NULL;
    IF v_productos > 0 THEN
        RAISE EXCEPTION 'No se puede eliminar: la marca tiene % producto(s). Desactívela en lugar de borrarla.', v_productos
            USING ERRCODE = 'P0014';
    END IF;

    v_antes := inventarios.fn_marcas_json(p_id);
    PERFORM set_config('app.datos_anteriores', v_antes::text, true);
    PERFORM set_config('app.datos_nuevos', (v_antes || jsonb_build_object(
        'deleted_at', to_char(v_fecha, 'YYYY-MM-DD HH24:MI:SS'), 'deleted_by', p_usuario_login
    ))::text, true);

    UPDATE inventarios.marcas
       SET deleted_at = v_fecha,
           deleted_by = p_usuario_login,
           updated_by = COALESCE(p_usuario_login, updated_by),
           updated_at = v_fecha
     WHERE id = p_id;

    PERFORM set_config('app.datos_anteriores', '', true);
    PERFORM set_config('app.datos_nuevos', '', true);

    RETURN jsonb_build_object(
        'success', true,
        'message', format('Marca «%s» enviada a la papelera de reciclaje', v_actual.nombre),
        'data', inventarios.fn_marcas_json(p_id)
    );
END;
$function$;


-- ---------------------------------------------------------------------------
-- LO QUE HAY EN LA PAPELERA (más reciente primero)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION inventarios.fn_marcas_papelera_listar()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
AS $function$
DECLARE
    v_data jsonb;
BEGIN
    SELECT COALESCE(jsonb_agg(inventarios.fn_marcas_json(m.id)
                              ORDER BY m.deleted_at DESC, m.id DESC), '[]'::jsonb)
      INTO v_data
      FROM inventarios.marcas m
     WHERE m.deleted_at IS NOT NULL;

    RETURN jsonb_build_object('success', true, 'data', v_data, 'total', jsonb_array_length(v_data));
EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object('success', false, 'message', 'Error al listar la papelera: ' || SQLERRM, 'error_code', SQLSTATE);
END;
$function$;


-- ---------------------------------------------------------------------------
-- RESTAURAR (una o varias)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION inventarios.fn_marcas_restaurar(
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
    v_m       record;
    v_antes   jsonb;
    v_n       integer := 0;
    v_fecha   timestamptz := CURRENT_TIMESTAMP;
    v_nombres text[] := '{}';
BEGIN
    PERFORM inventarios.fn_contexto_auditoria('inventarios.marcas',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    IF p_ids IS NULL OR jsonb_typeof(p_ids) <> 'array' OR jsonb_array_length(p_ids) = 0 THEN
        RAISE EXCEPTION 'No se indicó ninguna marca' USING ERRCODE = 'P0001';
    END IF;

    FOR v_m IN
        SELECT m.id, m.nombre
          FROM inventarios.marcas m
         WHERE m.id IN (SELECT (x)::bigint FROM jsonb_array_elements_text(p_ids) x)
           AND m.deleted_at IS NOT NULL
    LOOP
        v_antes := inventarios.fn_marcas_json(v_m.id);
        PERFORM set_config('app.datos_anteriores', v_antes::text, true);
        PERFORM set_config('app.datos_nuevos', (v_antes || jsonb_build_object('deleted_at', NULL, 'deleted_by', NULL))::text, true);

        UPDATE inventarios.marcas
           SET deleted_at = NULL, deleted_by = NULL,
               updated_by = COALESCE(p_usuario_login, updated_by), updated_at = v_fecha
         WHERE id = v_m.id;

        v_n := v_n + 1;
        v_nombres := v_nombres || v_m.nombre::text;
    END LOOP;

    PERFORM set_config('app.datos_anteriores', '', true);
    PERFORM set_config('app.datos_nuevos', '', true);

    IF v_n = 0 THEN
        RAISE EXCEPTION 'Ninguna de esas marcas está en la papelera' USING ERRCODE = 'P0019';
    END IF;

    RETURN jsonb_build_object(
        'success', true,
        'message', CASE WHEN v_n = 1 THEN format('Marca «%s» restaurada', v_nombres[1])
                        ELSE format('%s marcas restauradas', v_n) END,
        'data', jsonb_build_object('restauradas', v_n, 'nombres', to_jsonb(v_nombres))
    );

EXCEPTION
    WHEN unique_violation THEN
        RAISE EXCEPTION 'Ya existe otra marca vigente con ese nombre: cámbiele el nombre antes de restaurarla' USING ERRCODE = 'P0006';
END;
$function$;


-- ---------------------------------------------------------------------------
-- BORRADO REAL (sólo de lo que está en la papelera)
--
-- Devuelve el fichero del logo para que el controlador lo borre del disco:
-- la base no puede tocar storage.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION inventarios.fn_marcas_eliminar_definitivo(
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
    v_m         record;
    v_n         integer := 0;
    v_productos bigint;
    v_ficheros  text[] := '{}';
    v_nombres   text[] := '{}';
BEGIN
    PERFORM inventarios.fn_contexto_auditoria('inventarios.marcas',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    IF p_ids IS NULL OR jsonb_typeof(p_ids) <> 'array' OR jsonb_array_length(p_ids) = 0 THEN
        RAISE EXCEPTION 'No se indicó ninguna marca' USING ERRCODE = 'P0001';
    END IF;

    FOR v_m IN
        SELECT m.id, m.nombre, m.logo
          FROM inventarios.marcas m
         WHERE m.id IN (SELECT (x)::bigint FROM jsonb_array_elements_text(p_ids) x)
           AND m.deleted_at IS NOT NULL      -- sólo lo que está en la papelera
    LOOP
        -- Aquí cuentan TODOS los productos, también los de la papelera: la
        -- clave ajena no distingue, y el error de integridad sería peor.
        SELECT COUNT(*) INTO v_productos FROM inventarios.productos WHERE marca_id = v_m.id;
        IF v_productos > 0 THEN
            RAISE EXCEPTION 'No se puede eliminar «%» definitivamente: todavía tiene % producto(s), aunque estén en la papelera.', v_m.nombre, v_productos
                USING ERRCODE = 'P0014';
        END IF;

        -- La ficha entera a la auditoría: es lo único que no se puede volver
        -- a escribir de memoria si se borró por error
        PERFORM set_config('app.datos_anteriores', (inventarios.fn_marcas_json(v_m.id))::text, true);
        DELETE FROM inventarios.marcas WHERE id = v_m.id;

        v_n := v_n + 1;
        v_nombres := v_nombres || v_m.nombre::text;
        IF NULLIF(v_m.logo, '') IS NOT NULL THEN v_ficheros := v_ficheros || v_m.logo::text; END IF;
    END LOOP;

    PERFORM set_config('app.datos_anteriores', '', true);

    IF v_n = 0 THEN
        RAISE EXCEPTION 'Ninguna de esas marcas está en la papelera' USING ERRCODE = 'P0019';
    END IF;

    RETURN jsonb_build_object(
        'success', true,
        'message', CASE WHEN v_n = 1 THEN format('Marca «%s» eliminada definitivamente', v_nombres[1])
                        ELSE format('%s marcas eliminadas definitivamente', v_n) END,
        'data', jsonb_build_object('borradas', v_n, 'nombres', to_jsonb(v_nombres), 'ficheros', to_jsonb(v_ficheros))
    );

EXCEPTION
    WHEN foreign_key_violation THEN
        RAISE EXCEPTION 'No se puede eliminar definitivamente: algo sigue apuntando a esa marca' USING ERRCODE = 'P0014';
END;
$function$;


-- ---------------------------------------------------------------------------
-- VACIAR LA PAPELERA
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION inventarios.fn_marcas_papelera_vaciar(
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
    SELECT COALESCE(jsonb_agg(m.id), '[]'::jsonb) INTO v_ids
      FROM inventarios.marcas m WHERE m.deleted_at IS NOT NULL;

    IF jsonb_array_length(v_ids) = 0 THEN
        RETURN jsonb_build_object('success', true, 'message', 'La papelera ya estaba vacía',
                                  'data', jsonb_build_object('borradas', 0, 'nombres', '[]'::jsonb, 'ficheros', '[]'::jsonb));
    END IF;

    -- Se delega en eliminar_definitivo para no tener dos sitios donde se
    -- borra de verdad: uno de los dos acabaría olvidándose de algo.
    RETURN inventarios.fn_marcas_eliminar_definitivo(v_ids,
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);
END;
$function$;


-- ---------------------------------------------------------------------------
-- PERMISOS Y COMENTARIOS
-- ---------------------------------------------------------------------------
ALTER FUNCTION inventarios.fn_marcas_listar_paginado(integer, integer, text, jsonb) OWNER TO postgres;
ALTER FUNCTION inventarios.fn_marcas_papelera_listar() OWNER TO postgres;
ALTER FUNCTION inventarios.fn_marcas_restaurar(jsonb, bigint, varchar, varchar, inet, text, uuid) OWNER TO postgres;
ALTER FUNCTION inventarios.fn_marcas_eliminar_definitivo(jsonb, bigint, varchar, varchar, inet, text, uuid) OWNER TO postgres;
ALTER FUNCTION inventarios.fn_marcas_papelera_vaciar(bigint, varchar, varchar, inet, text, uuid) OWNER TO postgres;

COMMENT ON FUNCTION inventarios.fn_marcas_listar_paginado(integer, integer, text, jsonb) IS 'Listado paginado de marcas; p_filtros trae los filtros de columna de ag-Grid y se aplican sobre todas las marcas, no sobre la página';
COMMENT ON FUNCTION inventarios.fn_marcas_eliminar(bigint, bigint, varchar, varchar, inet, text, uuid) IS 'Envía la marca a la papelera de reciclaje (borrado lógico)';
COMMENT ON FUNCTION inventarios.fn_marcas_papelera_listar() IS 'Marcas que están en la papelera de reciclaje';
COMMENT ON FUNCTION inventarios.fn_marcas_restaurar(jsonb, bigint, varchar, varchar, inet, text, uuid) IS 'Saca de la papelera una o varias marcas';
COMMENT ON FUNCTION inventarios.fn_marcas_eliminar_definitivo(jsonb, bigint, varchar, varchar, inet, text, uuid) IS 'Borrado real de marcas de la papelera; devuelve los logos a borrar del disco';
COMMENT ON FUNCTION inventarios.fn_marcas_papelera_vaciar(bigint, varchar, varchar, inet, text, uuid) IS 'Borrado real de todo lo que hay en la papelera de marcas';
