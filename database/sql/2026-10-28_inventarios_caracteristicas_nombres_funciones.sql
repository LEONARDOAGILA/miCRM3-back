-- ============================================================================
-- DICCIONARIO DE NOMBRES DE CARACTERÍSTICAS — FUNCIONES
-- ============================================================================
-- Fecha: 2026-10-28
-- Va después de `2026-10-28_inventarios_caracteristicas_nombres.sql`.
--
-- La familia de siempre (json, listar, listar_paginado, obtener, crear,
-- modificar, activar, eliminar, papelera_listar, restaurar,
-- eliminar_definitivo, papelera_vaciar), con dos reglas propias:
--
-- · NO se manda a la papelera un nombre QUE ESTÉ EN USO. Si 30 categorías lo
--   apuntan y se borra, esas 30 se quedan enseñando un nombre fantasma. El
--   mensaje dice cuántas lo usan para que se pueda ir a quitarlo.
--
-- · La UNIDAD sólo existe para los numéricos. Un «Color» en kg no significa
--   nada, así que al guardar se limpia sola si el tipo no es NUMERO.
--
-- Idempotente: todo es CREATE OR REPLACE.
-- ============================================================================
\set ON_ERROR_STOP on

BEGIN;

-- ---------------------------------------------------------------------------
-- JSON de una fila
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION inventarios.fn_caracteristicas_nombres_json(p_id bigint)
RETURNS jsonb
LANGUAGE sql
STABLE SECURITY DEFINER
AS $$
    SELECT jsonb_build_object(
        'id',          n.id,
        'nombre',      n.nombre,
        'unidad',      n.unidad,
        -- Lo que se enseña en el combo y en la ficha del producto:
        -- «Potencia (W)», «Color»
        'etiqueta',    n.nombre || COALESCE(' (' || n.unidad || ')', ''),
        'tipo',        n.tipo,
        'tipo_nombre', CASE n.tipo WHEN 'TEXTO'  THEN 'Texto'
                                   WHEN 'NUMERO' THEN 'Número'
                                   WHEN 'SI_NO'  THEN 'Sí / No'
                                   WHEN 'LISTA'  THEN 'Lista'
                                   ELSE n.tipo END,
        'descripcion', n.descripcion,
        'activo',      n.activo,
        -- En cuántas categorías se está usando ahora mismo: es lo que avisa
        -- de que renombrarlo o borrarlo no es gratis
        'num_categorias', (SELECT COUNT(*) FROM inventarios.caracteristicas_categorias k
                            WHERE k.nombre_id = n.id AND k.deleted_at IS NULL),
        'num_productos',  (SELECT COUNT(*) FROM inventarios.caracteristicas_productos v
                             JOIN inventarios.productos p ON p.id = v.producto_id
                            WHERE v.nombre_id = n.id AND p.deleted_at IS NULL),
        'deleted_at',  to_char(n.deleted_at, 'YYYY-MM-DD HH24:MI:SS'),
        'deleted_by',  n.deleted_by,
        'created_by',  n.created_by,
        'updated_by',  n.updated_by,
        'created_at',  to_char(n.created_at, 'YYYY-MM-DD HH24:MI:SS'),
        'updated_at',  to_char(n.updated_at, 'YYYY-MM-DD HH24:MI:SS')
    )
      FROM inventarios.caracteristicas_nombres n
     WHERE n.id = p_id;
$$;

-- ---------------------------------------------------------------------------
-- La lista para el combo
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION inventarios.fn_caracteristicas_nombres_listar(
    p_solo_activos boolean DEFAULT true)
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'pg_catalog', 'inventarios'
AS $$
DECLARE
    v_data jsonb;
BEGIN
    SELECT COALESCE(jsonb_agg(inventarios.fn_caracteristicas_nombres_json(n.id)
                              ORDER BY n.nombre), '[]'::jsonb)
      INTO v_data
      FROM inventarios.caracteristicas_nombres n
     WHERE n.deleted_at IS NULL
       AND (NOT p_solo_activos OR n.activo);

    RETURN jsonb_build_object('success', true, 'data', v_data);

EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false,
        'message', 'Error al listar los nombres: ' || SQLERRM, 'error_code', SQLSTATE);
END;
$$;

-- ---------------------------------------------------------------------------
-- El listado paginado de la pantalla
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION inventarios.fn_caracteristicas_nombres_listar_paginado(
    p_page integer DEFAULT 1, p_per_page integer DEFAULT 15,
    p_search text DEFAULT ''::text, p_filtros jsonb DEFAULT '{}'::jsonb)
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'pg_catalog', 'inventarios', 'ventas'
AS $$
DECLARE
    v_offset integer;
    v_total  bigint;
    v_data   jsonb;
    v_filtro text;
BEGIN
    v_offset := (GREATEST(p_page, 1) - 1) * GREATEST(p_per_page, 1);
    v_filtro := NULLIF(TRIM(COALESCE(p_search, '')), '');

    WITH filtrados AS (
        SELECT n.id
          FROM inventarios.caracteristicas_nombres n
         WHERE n.deleted_at IS NULL
           AND (v_filtro IS NULL
                OR n.nombre      ILIKE '%' || v_filtro || '%'
                OR n.unidad      ILIKE '%' || v_filtro || '%'
                OR n.descripcion ILIKE '%' || v_filtro || '%'
                OR n.id::text    ILIKE '%' || v_filtro || '%')

           -- ---------- LOS FILTROS DE LA CABECERA ----------
           AND (p_filtros->'id'          IS NULL OR ventas.fn_filtro_numero(n.id,          p_filtros->'id'))
           AND (p_filtros->'nombre'      IS NULL OR ventas.fn_filtro_texto(n.nombre,       p_filtros->'nombre'))
           AND (p_filtros->'unidad'      IS NULL OR ventas.fn_filtro_texto(n.unidad,       p_filtros->'unidad'))
           AND (p_filtros->'tipo'        IS NULL OR ventas.fn_filtro_texto(n.tipo,         p_filtros->'tipo'))
           AND (p_filtros->'descripcion' IS NULL OR ventas.fn_filtro_texto(n.descripcion,  p_filtros->'descripcion'))
           AND (p_filtros->'num_categorias' IS NULL OR ventas.fn_filtro_numero(
                   (SELECT COUNT(*) FROM inventarios.caracteristicas_categorias k
                     WHERE k.nombre_id = n.id AND k.deleted_at IS NULL),
                   p_filtros->'num_categorias'))
           AND (p_filtros->'created_by'  IS NULL OR ventas.fn_filtro_texto(n.created_by,   p_filtros->'created_by'))
           AND (p_filtros->'updated_by'  IS NULL OR ventas.fn_filtro_texto(n.updated_by,   p_filtros->'updated_by'))
           AND (p_filtros->'created_at'  IS NULL OR ventas.fn_filtro_texto(
                   to_char(n.created_at, 'YYYY-MM-DD HH24:MI:SS'), p_filtros->'created_at'))
           AND (p_filtros->'updated_at'  IS NULL OR ventas.fn_filtro_texto(
                   to_char(n.updated_at, 'YYYY-MM-DD HH24:MI:SS'), p_filtros->'updated_at'))
    )
    SELECT COUNT(*),
           COALESCE((SELECT jsonb_agg(inventarios.fn_caracteristicas_nombres_json(t.id) ORDER BY t.nombre)
                       FROM (SELECT f.id, n2.nombre FROM filtrados f
                               JOIN inventarios.caracteristicas_nombres n2 ON n2.id = f.id
                              ORDER BY n2.nombre
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
    RETURN jsonb_build_object('success', false,
        'message', 'Error al listar los nombres: ' || SQLERRM, 'error_code', SQLSTATE);
END;
$$;

-- ---------------------------------------------------------------------------
-- Uno
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION inventarios.fn_caracteristicas_nombres_obtener(p_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
AS $$
DECLARE
    v_data jsonb;
BEGIN
    v_data := inventarios.fn_caracteristicas_nombres_json(p_id);
    IF v_data IS NULL THEN
        RAISE EXCEPTION 'El nombre de característica no existe' USING ERRCODE = 'P0013';
    END IF;
    RETURN jsonb_build_object('success', true, 'message', 'Nombre encontrado', 'data', v_data);
END;
$$;

-- ---------------------------------------------------------------------------
-- Crear
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION inventarios.fn_caracteristicas_nombres_crear(
    p_nombre         varchar,
    p_unidad         varchar DEFAULT NULL,
    p_tipo           varchar DEFAULT 'TEXTO',
    p_descripcion    text    DEFAULT NULL,
    p_activo         boolean DEFAULT true,
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
AS $$
DECLARE
    v_id     bigint;
    v_tipo   varchar;
    v_unidad varchar;
    v_nuevo  jsonb;
BEGIN
    PERFORM inventarios.fn_contexto_auditoria('inventarios.caracteristicas_nombres',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    IF p_nombre IS NULL OR length(TRIM(p_nombre)) < 2 THEN
        RAISE EXCEPTION 'El nombre es obligatorio (mínimo 2 caracteres)' USING ERRCODE = 'P0001';
    END IF;

    v_tipo := UPPER(TRIM(COALESCE(p_tipo, 'TEXTO')));
    IF v_tipo NOT IN ('TEXTO', 'NUMERO', 'SI_NO', 'LISTA') THEN
        RAISE EXCEPTION 'El tipo debe ser TEXTO, NUMERO, SI_NO o LISTA' USING ERRCODE = 'P0015';
    END IF;

    -- La unidad sólo tiene sentido en los numéricos
    v_unidad := CASE WHEN v_tipo = 'NUMERO' THEN NULLIF(TRIM(COALESCE(p_unidad, '')), '') END;

    -- Mensaje claro antes de que salte el índice único, y distinguiendo el
    -- que está en la papelera: si no, «ya existe» y no se ve dónde
    IF EXISTS (SELECT 1 FROM inventarios.caracteristicas_nombres
                WHERE inventarios.fn_normalizar_nombre(nombre)
                    = inventarios.fn_normalizar_nombre(p_nombre)) THEN
        IF EXISTS (SELECT 1 FROM inventarios.caracteristicas_nombres
                    WHERE inventarios.fn_normalizar_nombre(nombre)
                        = inventarios.fn_normalizar_nombre(p_nombre)
                      AND deleted_at IS NOT NULL) THEN
            RAISE EXCEPTION 'Ese nombre ya existe y está en la papelera de reciclaje' USING ERRCODE = 'P0006';
        END IF;
        RAISE EXCEPTION 'Ese nombre ya está en el diccionario' USING ERRCODE = 'P0006';
    END IF;

    v_nuevo := jsonb_build_object(
        'nombre', TRIM(p_nombre), 'unidad', v_unidad, 'tipo', v_tipo,
        'descripcion', NULLIF(TRIM(COALESCE(p_descripcion, '')), ''),
        'activo', COALESCE(p_activo, true));
    PERFORM set_config('app.datos_nuevos', v_nuevo::text, true);

    INSERT INTO inventarios.caracteristicas_nombres (nombre, unidad, tipo, descripcion, activo)
    VALUES (TRIM(p_nombre), v_unidad, v_tipo,
            NULLIF(TRIM(COALESCE(p_descripcion, '')), ''), COALESCE(p_activo, true))
    RETURNING id INTO v_id;

    PERFORM set_config('app.datos_nuevos', '', true);

    RETURN jsonb_build_object('success', true, 'message', 'Nombre creado exitosamente',
                              'data', inventarios.fn_caracteristicas_nombres_json(v_id));

EXCEPTION
    WHEN unique_violation THEN
        RAISE EXCEPTION 'Ese nombre ya está en el diccionario' USING ERRCODE = 'P0006';
END;
$$;

-- ---------------------------------------------------------------------------
-- Modificar
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION inventarios.fn_caracteristicas_nombres_modificar(
    p_id             bigint,
    p_nombre         varchar,
    p_unidad         varchar DEFAULT NULL,
    p_tipo           varchar DEFAULT 'TEXTO',
    p_descripcion    text    DEFAULT NULL,
    p_activo         boolean DEFAULT NULL,
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
AS $$
DECLARE
    v_antes  jsonb;
    v_tipo   varchar;
    v_unidad varchar;
BEGIN
    PERFORM inventarios.fn_contexto_auditoria('inventarios.caracteristicas_nombres',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    v_antes := inventarios.fn_caracteristicas_nombres_json(p_id);
    IF v_antes IS NULL THEN
        RAISE EXCEPTION 'El nombre de característica no existe' USING ERRCODE = 'P0013';
    END IF;

    IF p_nombre IS NULL OR length(TRIM(p_nombre)) < 2 THEN
        RAISE EXCEPTION 'El nombre es obligatorio (mínimo 2 caracteres)' USING ERRCODE = 'P0001';
    END IF;

    v_tipo := UPPER(TRIM(COALESCE(p_tipo, 'TEXTO')));
    IF v_tipo NOT IN ('TEXTO', 'NUMERO', 'SI_NO', 'LISTA') THEN
        RAISE EXCEPTION 'El tipo debe ser TEXTO, NUMERO, SI_NO o LISTA' USING ERRCODE = 'P0015';
    END IF;

    v_unidad := CASE WHEN v_tipo = 'NUMERO' THEN NULLIF(TRIM(COALESCE(p_unidad, '')), '') END;

    IF EXISTS (SELECT 1 FROM inventarios.caracteristicas_nombres
                WHERE id <> p_id
                  AND inventarios.fn_normalizar_nombre(nombre)
                    = inventarios.fn_normalizar_nombre(p_nombre)) THEN
        RAISE EXCEPTION 'Ya hay otro nombre igual en el diccionario (puede estar en la papelera de reciclaje)' USING ERRCODE = 'P0006';
    END IF;

    PERFORM set_config('app.datos_anteriores', v_antes::text, true);
    PERFORM set_config('app.datos_nuevos', jsonb_build_object(
        'nombre', TRIM(p_nombre), 'unidad', v_unidad, 'tipo', v_tipo,
        'descripcion', NULLIF(TRIM(COALESCE(p_descripcion, '')), ''),
        'activo', COALESCE(p_activo, (v_antes->>'activo')::boolean))::text, true);

    UPDATE inventarios.caracteristicas_nombres
       SET nombre      = TRIM(p_nombre),
           unidad      = v_unidad,
           tipo        = v_tipo,
           descripcion = NULLIF(TRIM(COALESCE(p_descripcion, '')), ''),
           activo      = COALESCE(p_activo, activo)
     WHERE id = p_id;

    PERFORM set_config('app.datos_anteriores', '', true);
    PERFORM set_config('app.datos_nuevos', '', true);

    RETURN jsonb_build_object('success', true, 'message', 'Nombre actualizado exitosamente',
                              'data', inventarios.fn_caracteristicas_nombres_json(p_id));

EXCEPTION
    WHEN unique_violation THEN
        RAISE EXCEPTION 'Ya hay otro nombre igual en el diccionario (puede estar en la papelera de reciclaje)' USING ERRCODE = 'P0006';
END;
$$;

-- ---------------------------------------------------------------------------
-- Activar / desactivar
-- ---------------------------------------------------------------------------
-- Inactivo = no sale en el combo para elegirlo de nuevo, pero donde ya está
-- puesto se queda. Es el mismo trato que en marcas y categorías.
CREATE OR REPLACE FUNCTION inventarios.fn_caracteristicas_nombres_activar(
    p_id             bigint,
    p_activo         boolean DEFAULT NULL,
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
AS $$
DECLARE
    v_antes  boolean;
    v_nuevo  boolean;
    v_nombre varchar;
BEGIN
    PERFORM inventarios.fn_contexto_auditoria('inventarios.caracteristicas_nombres',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    SELECT activo, nombre INTO v_antes, v_nombre
      FROM inventarios.caracteristicas_nombres WHERE id = p_id AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'El nombre de característica no existe' USING ERRCODE = 'P0013';
    END IF;

    v_nuevo := COALESCE(p_activo, NOT v_antes);

    PERFORM set_config('app.datos_anteriores', jsonb_build_object('activo', v_antes)::text, true);
    PERFORM set_config('app.datos_nuevos',     jsonb_build_object('activo', v_nuevo)::text, true);

    UPDATE inventarios.caracteristicas_nombres SET activo = v_nuevo WHERE id = p_id;

    PERFORM set_config('app.datos_anteriores', '', true);
    PERFORM set_config('app.datos_nuevos', '', true);

    RETURN jsonb_build_object('success', true,
        'message', 'Nombre «' || v_nombre || '» ' || CASE WHEN v_nuevo THEN 'activado' ELSE 'desactivado' END,
        'data', inventarios.fn_caracteristicas_nombres_json(p_id));
END;
$$;

-- ---------------------------------------------------------------------------
-- A la papelera
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION inventarios.fn_caracteristicas_nombres_eliminar(
    p_id             bigint,
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
AS $$
DECLARE
    v_nombre     varchar;
    v_categorias integer;
    v_productos  integer;
    v_quien      varchar;
    v_antes      jsonb;
BEGIN
    PERFORM inventarios.fn_contexto_auditoria('inventarios.caracteristicas_nombres',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    SELECT nombre INTO v_nombre FROM inventarios.caracteristicas_nombres
     WHERE id = p_id AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'El nombre de característica no existe o ya está en la papelera' USING ERRCODE = 'P0013';
    END IF;

    -- EN USO: no se borra. Si se dejara, las categorías que lo apuntan
    -- quedarían enseñando un nombre que está en la papelera.
    SELECT COUNT(*) INTO v_categorias
      FROM inventarios.caracteristicas_categorias k
     WHERE k.nombre_id = p_id AND k.deleted_at IS NULL;

    IF v_categorias > 0 THEN
        RAISE EXCEPTION 'No se puede eliminar «%»: lo usan % %. Quítelo de esas categorías primero',
            v_nombre, v_categorias,
            CASE WHEN v_categorias = 1 THEN 'categoría' ELSE 'categorías' END
            USING ERRCODE = 'P0021';
    END IF;

    SELECT COUNT(*) INTO v_productos
      FROM inventarios.caracteristicas_productos v
      JOIN inventarios.productos p ON p.id = v.producto_id
     WHERE v.nombre_id = p_id AND p.deleted_at IS NULL;

    IF v_productos > 0 THEN
        RAISE EXCEPTION 'No se puede eliminar «%»: % % lo tienen relleno',
            v_nombre, v_productos,
            CASE WHEN v_productos = 1 THEN 'producto' ELSE 'productos' END
            USING ERRCODE = 'P0021';
    END IF;

    v_quien := COALESCE(p_usuario_nombre, p_usuario_login, 'SISTEMA');
    v_antes := inventarios.fn_caracteristicas_nombres_json(p_id);

    PERFORM set_config('app.datos_anteriores', v_antes::text, true);
    PERFORM set_config('app.datos_nuevos',
        (v_antes || jsonb_build_object('deleted_by', v_quien))::text, true);

    UPDATE inventarios.caracteristicas_nombres
       SET deleted_at = CURRENT_TIMESTAMP, deleted_by = v_quien
     WHERE id = p_id;

    PERFORM set_config('app.datos_anteriores', '', true);
    PERFORM set_config('app.datos_nuevos', '', true);

    RETURN jsonb_build_object('success', true,
        'message', 'Nombre «' || v_nombre || '» enviado a la papelera de reciclaje',
        'data', inventarios.fn_caracteristicas_nombres_json(p_id));
END;
$$;

-- ---------------------------------------------------------------------------
-- La papelera
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION inventarios.fn_caracteristicas_nombres_papelera_listar()
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
AS $$
DECLARE
    v_data jsonb;
BEGIN
    SELECT COALESCE(jsonb_agg(inventarios.fn_caracteristicas_nombres_json(n.id)
                              ORDER BY n.deleted_at DESC, n.id DESC), '[]'::jsonb)
      INTO v_data
      FROM inventarios.caracteristicas_nombres n
     WHERE n.deleted_at IS NOT NULL;

    RETURN jsonb_build_object('success', true, 'data', v_data,
                              'total', jsonb_array_length(v_data));
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false,
        'message', 'Error al listar la papelera: ' || SQLERRM, 'error_code', SQLSTATE);
END;
$$;

CREATE OR REPLACE FUNCTION inventarios.fn_caracteristicas_nombres_restaurar(
    p_ids            jsonb,
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
AS $$
DECLARE
    v_n       record;
    v_antes   jsonb;
    v_cuantos integer := 0;
    v_nombres text[] := '{}';
BEGIN
    PERFORM inventarios.fn_contexto_auditoria('inventarios.caracteristicas_nombres',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    IF p_ids IS NULL OR jsonb_typeof(p_ids) <> 'array' OR jsonb_array_length(p_ids) = 0 THEN
        RAISE EXCEPTION 'No se indicó ningún nombre' USING ERRCODE = 'P0001';
    END IF;

    FOR v_n IN
        SELECT n.id, n.nombre
          FROM inventarios.caracteristicas_nombres n
         WHERE n.id IN (SELECT (x)::bigint FROM jsonb_array_elements_text(p_ids) x)
           AND n.deleted_at IS NOT NULL
    LOOP
        v_antes := inventarios.fn_caracteristicas_nombres_json(v_n.id);
        PERFORM set_config('app.datos_anteriores', v_antes::text, true);
        PERFORM set_config('app.datos_nuevos',
            (v_antes || jsonb_build_object('deleted_at', NULL, 'deleted_by', NULL))::text, true);

        UPDATE inventarios.caracteristicas_nombres
           SET deleted_at = NULL, deleted_by = NULL
         WHERE id = v_n.id;

        v_cuantos := v_cuantos + 1;
        v_nombres := v_nombres || v_n.nombre::text;
    END LOOP;

    PERFORM set_config('app.datos_anteriores', '', true);
    PERFORM set_config('app.datos_nuevos', '', true);

    IF v_cuantos = 0 THEN
        RAISE EXCEPTION 'Ninguno de esos nombres está en la papelera' USING ERRCODE = 'P0019';
    END IF;

    RETURN jsonb_build_object('success', true,
        'message', CASE WHEN v_cuantos = 1 THEN format('Nombre «%s» restaurado', v_nombres[1])
                        ELSE format('%s nombres restaurados', v_cuantos) END,
        'data', jsonb_build_object('restaurados', v_cuantos, 'nombres', to_jsonb(v_nombres)));
END;
$$;

CREATE OR REPLACE FUNCTION inventarios.fn_caracteristicas_nombres_eliminar_definitivo(
    p_ids            jsonb,
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
AS $$
DECLARE
    v_nombres text[];
    v_cuantas integer := 0;
BEGIN
    PERFORM inventarios.fn_contexto_auditoria('inventarios.caracteristicas_nombres',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    IF p_ids IS NULL OR jsonb_typeof(p_ids) <> 'array' OR jsonb_array_length(p_ids) = 0 THEN
        RAISE EXCEPTION 'No se indicó ningún nombre' USING ERRCODE = 'P0001';
    END IF;

    SELECT array_agg(nombre) INTO v_nombres
      FROM inventarios.caracteristicas_nombres
     WHERE id IN (SELECT (x)::bigint FROM jsonb_array_elements_text(p_ids) x)
       AND deleted_at IS NOT NULL;

    IF v_nombres IS NULL THEN
        RAISE EXCEPTION 'Ninguno de esos nombres está en la papelera' USING ERRCODE = 'P0019';
    END IF;

    -- La FK es la que manda: si algo lo sigue apuntando (aunque sea una
    -- característica que también está en la papelera, o el valor de un
    -- producto borrado) no se borra, y se dice por qué.
    BEGIN
        DELETE FROM inventarios.caracteristicas_nombres
         WHERE id IN (SELECT (x)::bigint FROM jsonb_array_elements_text(p_ids) x)
           AND deleted_at IS NOT NULL;
        GET DIAGNOSTICS v_cuantas = ROW_COUNT;
    EXCEPTION WHEN foreign_key_violation THEN
        RAISE EXCEPTION 'No se puede eliminar definitivamente: alguna característica o algún valor de producto sigue apuntando a ese nombre' USING ERRCODE = 'P0014';
    END;

    RETURN jsonb_build_object('success', true,
        'message', CASE WHEN v_cuantas = 1 THEN format('Nombre «%s» eliminado definitivamente', v_nombres[1])
                        ELSE format('%s nombres eliminados definitivamente', v_cuantas) END,
        'data', jsonb_build_object('nombres', to_jsonb(v_nombres), 'borrados', v_cuantas));
END;
$$;

CREATE OR REPLACE FUNCTION inventarios.fn_caracteristicas_nombres_papelera_vaciar(
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
AS $$
DECLARE
    v_cuantas integer := 0;
BEGIN
    PERFORM inventarios.fn_contexto_auditoria('inventarios.caracteristicas_nombres',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    BEGIN
        DELETE FROM inventarios.caracteristicas_nombres WHERE deleted_at IS NOT NULL;
        GET DIAGNOSTICS v_cuantas = ROW_COUNT;
    EXCEPTION WHEN foreign_key_violation THEN
        RAISE EXCEPTION 'No se puede vaciar la papelera: algún nombre sigue estando apuntado por una característica o por el valor de un producto' USING ERRCODE = 'P0014';
    END;

    RETURN jsonb_build_object('success', true,
        'message', CASE WHEN v_cuantas = 0 THEN 'La papelera ya estaba vacía'
                        WHEN v_cuantas = 1 THEN '1 nombre eliminado definitivamente'
                        ELSE v_cuantas || ' nombres eliminados definitivamente' END,
        'data', jsonb_build_object('borrados', v_cuantas));
END;
$$;

COMMIT;
