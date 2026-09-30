-- ============================================================================
-- CRUD de CARGOS (esquema rh) — funciones PL/pgSQL, mismo esquema que las
-- de seguridad.fn_usuarios_*:
--   rh.fn_cargos_listar_paginado(page, per_page, search)  listado para la grilla
--   rh.fn_cargos_listar(solo_activos)                     lista simple (combos / selector)
--   rh.fn_cargos_obtener(id)                              un cargo
--   rh.fn_cargos_crear(...)                               alta
--   rh.fn_cargos_modificar(...)                           modificación
--   rh.fn_cargos_eliminar(...)                            baja
--
-- La tabla rh.cargos ya existe (id, nombre UNIQUE, descripcion, nivel,
-- salario_base, activo, created_at/by, updated_at/by) con sus tres triggers
-- de auditoría (auditoria.fn_auditar_cambios, fn_set_audit_users,
-- fn_update_updated_at_column): las funciones sólo dejan el contexto app.*
-- y los datos_anteriores/datos_nuevos para que el trigger los grabe.
--
-- Reglas de negocio: se lanzan con RAISE EXCEPTION y un SQLSTATE propio
-- (Pxxxx) para que la transacción aborte sola y el back lo traduzca a 4xx:
--   P0001 nombre obligatorio      P0006 nombre duplicado
--   P0013 el cargo no existe      P0014 tiene empleados / historial asociado
--   P0015 salario inválido
-- Idempotente: CREATE OR REPLACE.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- LISTADO PAGINADO (grilla)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION rh.fn_cargos_listar_paginado(
    p_page     integer DEFAULT 1,
    p_per_page integer DEFAULT 15,
    p_search   text    DEFAULT ''
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
    v_offset    integer;
    v_total     bigint;
    v_data      jsonb;
    v_filtro    text;
BEGIN
    v_offset := (GREATEST(p_page, 1) - 1) * p_per_page;
    v_filtro := NULLIF(TRIM(COALESCE(p_search, '')), '');

    -- 1. Total con filtro (nombre, descripción, nivel, id)
    SELECT COUNT(*) INTO v_total
      FROM rh.cargos c
     WHERE v_filtro IS NULL
        OR c.nombre      ILIKE '%' || v_filtro || '%'
        OR c.descripcion ILIKE '%' || v_filtro || '%'
        OR c.nivel       ILIKE '%' || v_filtro || '%'
        OR c.id::text    ILIKE '%' || v_filtro || '%';

    -- 2. Página, con cuántos empleados tiene cada cargo (para saber si se puede borrar)
    SELECT COALESCE(jsonb_agg(
        jsonb_build_object(
            'id',            t.id,
            'nombre',        t.nombre,
            'descripcion',   t.descripcion,
            'nivel',         t.nivel,
            'salario_base',  t.salario_base,
            'activo',        t.activo,
            'num_empleados', t.num_empleados,
            'created_by',    t.created_by,
            'updated_by',    t.updated_by,
            'created_at',    to_char(t.created_at, 'YYYY-MM-DD HH24:MI:SS'),
            'updated_at',    to_char(t.updated_at, 'YYYY-MM-DD HH24:MI:SS')
        ) ORDER BY t.id DESC
    ), '[]'::jsonb) INTO v_data
    FROM (
        SELECT c.*,
               (SELECT COUNT(*) FROM rh.empleados e WHERE e.cargo_id = c.id) AS num_empleados
          FROM rh.cargos c
         WHERE v_filtro IS NULL
            OR c.nombre      ILIKE '%' || v_filtro || '%'
            OR c.descripcion ILIKE '%' || v_filtro || '%'
            OR c.nivel       ILIKE '%' || v_filtro || '%'
            OR c.id::text    ILIKE '%' || v_filtro || '%'
         ORDER BY c.id DESC
         LIMIT p_per_page OFFSET v_offset
    ) t;

    RETURN jsonb_build_object(
        'data', v_data,
        'meta', jsonb_build_object(
            'total',        v_total,
            'per_page',     p_per_page,
            'current_page', GREATEST(p_page, 1),
            'last_page',    CASE WHEN v_total = 0 THEN 1 ELSE ceil(v_total::numeric / p_per_page) END
        )
    );

EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object('success', false, 'message', 'Error al listar cargos: ' || SQLERRM, 'error_code', SQLSTATE);
END;
$function$;

-- ---------------------------------------------------------------------------
-- LISTA SIMPLE (combos y selector listCargos)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION rh.fn_cargos_listar(p_solo_activos boolean DEFAULT true)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
    v_data jsonb;
BEGIN
    SELECT COALESCE(jsonb_agg(
        jsonb_build_object(
            'id', c.id, 'nombre', c.nombre, 'nivel', c.nivel,
            'salario_base', c.salario_base, 'activo', c.activo
        ) ORDER BY c.nombre
    ), '[]'::jsonb) INTO v_data
    FROM rh.cargos c
    WHERE NOT p_solo_activos OR c.activo;

    RETURN jsonb_build_object('success', true, 'message', 'Cargos obtenidos exitosamente', 'data', v_data);
EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object('success', false, 'message', 'Error al listar cargos: ' || SQLERRM, 'error_code', SQLSTATE);
END;
$function$;

-- ---------------------------------------------------------------------------
-- OBTENER UNO
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION rh.fn_cargos_obtener(p_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
    v_data jsonb;
BEGIN
    SELECT jsonb_build_object(
        'id',            c.id,
        'nombre',        c.nombre,
        'descripcion',   c.descripcion,
        'nivel',         c.nivel,
        'salario_base',  c.salario_base,
        'activo',        c.activo,
        'num_empleados', (SELECT COUNT(*) FROM rh.empleados e WHERE e.cargo_id = c.id),
        'created_by',    c.created_by,
        'updated_by',    c.updated_by,
        'created_at',    to_char(c.created_at, 'YYYY-MM-DD HH24:MI:SS'),
        'updated_at',    to_char(c.updated_at, 'YYYY-MM-DD HH24:MI:SS')
    ) INTO v_data
    FROM rh.cargos c
    WHERE c.id = p_id;

    IF v_data IS NULL THEN
        RETURN jsonb_build_object('success', false, 'message', 'Cargo no encontrado', 'error_code', 'CARGO_NOT_FOUND', 'data', null);
    END IF;

    RETURN jsonb_build_object('success', true, 'message', 'Cargo obtenido exitosamente', 'data', v_data);
EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object('success', false, 'message', 'Error al obtener el cargo: ' || SQLERRM, 'error_code', SQLSTATE);
END;
$function$;

-- ---------------------------------------------------------------------------
-- CREAR
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION rh.fn_cargos_crear(
    p_nombre         varchar,
    p_descripcion    text    DEFAULT NULL,
    p_nivel          varchar DEFAULT NULL,
    p_salario_base   numeric DEFAULT NULL,
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
SET search_path TO 'pg_catalog', 'rh', 'auditoria'
AS $function$
DECLARE
    v_id           bigint;
    v_fecha        timestamptz := CURRENT_TIMESTAMP;
    v_datos_nuevos jsonb;
    v_resultado    jsonb;
BEGIN
    -- 1. Contexto de auditoría (lo leen los triggers de rh.cargos)
    PERFORM set_config('app.usuario_id',     COALESCE(p_usuario_id::text, ''), true);
    PERFORM set_config('app.usuario_login',  COALESCE(p_usuario_login, current_user), true);
    PERFORM set_config('app.usuario_nombre', COALESCE(p_usuario_nombre, current_user), true);
    PERFORM set_config('app.ip_address',     COALESCE(p_ip_address::text, ''), true);
    PERFORM set_config('app.user_agent',     COALESCE(p_user_agent, ''), true);
    PERFORM set_config('app.request_id',     COALESCE(p_request_id::text, ''), true);
    PERFORM set_config('app.modulo',         'rh.cargos', true);

    -- 2. Reglas
    IF p_nombre IS NULL OR length(TRIM(p_nombre)) < 3 THEN
        RAISE EXCEPTION 'El nombre del cargo es obligatorio (mínimo 3 caracteres)' USING ERRCODE = 'P0001';
    END IF;
    IF p_salario_base IS NOT NULL AND p_salario_base < 0 THEN
        RAISE EXCEPTION 'El salario base no puede ser negativo' USING ERRCODE = 'P0015';
    END IF;
    -- Mensaje claro; la unicidad la garantiza uk_cargos_nombre (unique_violation más abajo)
    IF EXISTS (SELECT 1 FROM rh.cargos WHERE UPPER(nombre) = UPPER(TRIM(p_nombre))) THEN
        RAISE EXCEPTION 'Ya existe un cargo con ese nombre' USING ERRCODE = 'P0006';
    END IF;

    -- 3. Datos NUEVOS para la auditoría (antes del INSERT: el trigger AFTER los lee del contexto)
    v_datos_nuevos := jsonb_build_object(
        'nombre',       TRIM(p_nombre),
        'descripcion',  NULLIF(TRIM(COALESCE(p_descripcion, '')), ''),
        'nivel',        NULLIF(TRIM(COALESCE(p_nivel, '')), ''),
        'salario_base', p_salario_base,
        'activo',       COALESCE(p_activo, true),
        'created_by',   p_usuario_login,
        'created_at',   to_char(v_fecha, 'YYYY-MM-DD HH24:MI:SS'),
        'updated_by',   p_usuario_login,
        'updated_at',   to_char(v_fecha, 'YYYY-MM-DD HH24:MI:SS')
    );
    PERFORM set_config('app.datos_nuevos', v_datos_nuevos::text, true);

    -- 4. Insertar
    INSERT INTO rh.cargos (nombre, descripcion, nivel, salario_base, activo, created_by, updated_by, created_at, updated_at)
    VALUES (
        TRIM(p_nombre),
        NULLIF(TRIM(COALESCE(p_descripcion, '')), ''),
        NULLIF(TRIM(COALESCE(p_nivel, '')), ''),
        p_salario_base,
        COALESCE(p_activo, true),
        p_usuario_login, p_usuario_login, v_fecha, v_fecha
    )
    RETURNING id INTO v_id;

    PERFORM set_config('app.datos_nuevos', '', true);

    -- 5. Devolver el cargo creado
    SELECT jsonb_build_object(
        'success', true,
        'message', 'Cargo creado exitosamente',
        'data', (rh.fn_cargos_obtener(v_id))->'data'
    ) INTO v_resultado;

    RETURN v_resultado;

EXCEPTION
    -- Único caso capturado, y se RE-LANZA: manda el índice único. Nunca un «WHEN OTHERS».
    WHEN unique_violation THEN
        RAISE EXCEPTION 'Ya existe un cargo con ese nombre' USING ERRCODE = 'P0006';
END;
$function$;

-- ---------------------------------------------------------------------------
-- MODIFICAR
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION rh.fn_cargos_modificar(
    p_id             bigint,
    p_nombre         varchar,
    p_descripcion    text    DEFAULT NULL,
    p_nivel          varchar DEFAULT NULL,
    p_salario_base   numeric DEFAULT NULL,
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
SET search_path TO 'pg_catalog', 'rh', 'auditoria'
AS $function$
DECLARE
    v_actual           rh.cargos%ROWTYPE;
    v_fecha            timestamptz := CURRENT_TIMESTAMP;
    v_datos_anteriores jsonb;
    v_datos_nuevos     jsonb;
BEGIN
    -- 1. Contexto de auditoría
    PERFORM set_config('app.usuario_id',     COALESCE(p_usuario_id::text, ''), true);
    PERFORM set_config('app.usuario_login',  COALESCE(p_usuario_login, current_user), true);
    PERFORM set_config('app.usuario_nombre', COALESCE(p_usuario_nombre, current_user), true);
    PERFORM set_config('app.ip_address',     COALESCE(p_ip_address::text, ''), true);
    PERFORM set_config('app.user_agent',     COALESCE(p_user_agent, ''), true);
    PERFORM set_config('app.request_id',     COALESCE(p_request_id::text, ''), true);
    PERFORM set_config('app.modulo',         'rh.cargos', true);

    -- 2. Datos actuales
    SELECT * INTO v_actual FROM rh.cargos WHERE id = p_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'El cargo no existe' USING ERRCODE = 'P0013';
    END IF;

    -- 3. Reglas
    IF p_nombre IS NULL OR length(TRIM(p_nombre)) < 3 THEN
        RAISE EXCEPTION 'El nombre del cargo es obligatorio (mínimo 3 caracteres)' USING ERRCODE = 'P0001';
    END IF;
    IF p_salario_base IS NOT NULL AND p_salario_base < 0 THEN
        RAISE EXCEPTION 'El salario base no puede ser negativo' USING ERRCODE = 'P0015';
    END IF;
    IF EXISTS (SELECT 1 FROM rh.cargos WHERE UPPER(nombre) = UPPER(TRIM(p_nombre)) AND id <> p_id) THEN
        RAISE EXCEPTION 'Ya existe otro cargo con ese nombre' USING ERRCODE = 'P0006';
    END IF;

    -- 4. Antes / después para la auditoría
    v_datos_anteriores := jsonb_build_object(
        'id', v_actual.id, 'nombre', v_actual.nombre, 'descripcion', v_actual.descripcion,
        'nivel', v_actual.nivel, 'salario_base', v_actual.salario_base, 'activo', v_actual.activo,
        'created_by', v_actual.created_by, 'created_at', to_char(v_actual.created_at, 'YYYY-MM-DD HH24:MI:SS'),
        'updated_by', v_actual.updated_by, 'updated_at', to_char(v_actual.updated_at, 'YYYY-MM-DD HH24:MI:SS')
    );
    v_datos_nuevos := jsonb_build_object(
        'id', v_actual.id,
        'nombre',       TRIM(p_nombre),
        'descripcion',  NULLIF(TRIM(COALESCE(p_descripcion, '')), ''),
        'nivel',        NULLIF(TRIM(COALESCE(p_nivel, '')), ''),
        'salario_base', p_salario_base,
        'activo',       COALESCE(p_activo, true),
        'created_by', v_actual.created_by, 'created_at', to_char(v_actual.created_at, 'YYYY-MM-DD HH24:MI:SS'),
        'updated_by', p_usuario_login, 'updated_at', to_char(v_fecha, 'YYYY-MM-DD HH24:MI:SS')
    );
    PERFORM set_config('app.datos_anteriores', v_datos_anteriores::text, true);
    PERFORM set_config('app.datos_nuevos',     v_datos_nuevos::text, true);

    -- 5. Actualizar
    UPDATE rh.cargos
       SET nombre       = TRIM(p_nombre),
           descripcion  = NULLIF(TRIM(COALESCE(p_descripcion, '')), ''),
           nivel        = NULLIF(TRIM(COALESCE(p_nivel, '')), ''),
           salario_base = p_salario_base,
           activo       = COALESCE(p_activo, true),
           updated_by   = p_usuario_login,
           updated_at   = v_fecha
     WHERE id = p_id;

    PERFORM set_config('app.datos_anteriores', '', true);
    PERFORM set_config('app.datos_nuevos', '', true);

    RETURN jsonb_build_object(
        'success', true,
        'message', 'Cargo actualizado exitosamente',
        'data', (rh.fn_cargos_obtener(p_id))->'data'
    );

EXCEPTION
    WHEN unique_violation THEN
        RAISE EXCEPTION 'Ya existe otro cargo con ese nombre' USING ERRCODE = 'P0006';
END;
$function$;

-- ---------------------------------------------------------------------------
-- ELIMINAR
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION rh.fn_cargos_eliminar(
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
SET search_path TO 'pg_catalog', 'rh', 'auditoria'
AS $function$
DECLARE
    v_actual           rh.cargos%ROWTYPE;
    v_empleados        bigint;
    v_historial        bigint;
    v_datos_anteriores jsonb;
BEGIN
    -- 1. Contexto de auditoría
    PERFORM set_config('app.usuario_id',     COALESCE(p_usuario_id::text, ''), true);
    PERFORM set_config('app.usuario_login',  COALESCE(p_usuario_login, current_user), true);
    PERFORM set_config('app.usuario_nombre', COALESCE(p_usuario_nombre, current_user), true);
    PERFORM set_config('app.ip_address',     COALESCE(p_ip_address::text, ''), true);
    PERFORM set_config('app.user_agent',     COALESCE(p_user_agent, ''), true);
    PERFORM set_config('app.request_id',     COALESCE(p_request_id::text, ''), true);
    PERFORM set_config('app.modulo',         'rh.cargos', true);

    -- 2. Datos antes de eliminar
    SELECT * INTO v_actual FROM rh.cargos WHERE id = p_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'El cargo no existe' USING ERRCODE = 'P0013';
    END IF;

    -- 3. No se borra un cargo con empleados o historial: mensaje de negocio, no el del constraint
    SELECT COUNT(*) INTO v_empleados FROM rh.empleados        WHERE cargo_id = p_id;
    SELECT COUNT(*) INTO v_historial FROM rh.historial_cargos WHERE cargo_id = p_id;
    IF v_empleados > 0 THEN
        RAISE EXCEPTION 'No se puede eliminar: el cargo tiene % empleado(s) asignado(s). Desactívelo en su lugar.', v_empleados USING ERRCODE = 'P0014';
    END IF;
    IF v_historial > 0 THEN
        RAISE EXCEPTION 'No se puede eliminar: el cargo aparece en el historial de % empleado(s). Desactívelo en su lugar.', v_historial USING ERRCODE = 'P0014';
    END IF;

    v_datos_anteriores := jsonb_build_object(
        'id', v_actual.id, 'nombre', v_actual.nombre, 'descripcion', v_actual.descripcion,
        'nivel', v_actual.nivel, 'salario_base', v_actual.salario_base, 'activo', v_actual.activo,
        'created_by', v_actual.created_by, 'created_at', to_char(v_actual.created_at, 'YYYY-MM-DD HH24:MI:SS'),
        'updated_by', v_actual.updated_by, 'updated_at', to_char(v_actual.updated_at, 'YYYY-MM-DD HH24:MI:SS')
    );
    PERFORM set_config('app.datos_anteriores', v_datos_anteriores::text, true);

    -- 4. Eliminar
    DELETE FROM rh.cargos WHERE id = p_id;

    PERFORM set_config('app.datos_anteriores', '', true);

    RETURN jsonb_build_object('success', true, 'message', 'Cargo eliminado exitosamente', 'data', v_datos_anteriores);

EXCEPTION
    WHEN foreign_key_violation THEN
        RAISE EXCEPTION 'No se puede eliminar el cargo porque tiene registros asociados' USING ERRCODE = 'P0014';
END;
$function$;

ALTER FUNCTION rh.fn_cargos_listar_paginado(integer, integer, text) OWNER TO postgres;
ALTER FUNCTION rh.fn_cargos_listar(boolean) OWNER TO postgres;
ALTER FUNCTION rh.fn_cargos_obtener(bigint) OWNER TO postgres;
ALTER FUNCTION rh.fn_cargos_crear(varchar, text, varchar, numeric, boolean, bigint, varchar, varchar, inet, text, uuid) OWNER TO postgres;
ALTER FUNCTION rh.fn_cargos_modificar(bigint, varchar, text, varchar, numeric, boolean, bigint, varchar, varchar, inet, text, uuid) OWNER TO postgres;
ALTER FUNCTION rh.fn_cargos_eliminar(bigint, bigint, varchar, varchar, inet, text, uuid) OWNER TO postgres;

COMMENT ON FUNCTION rh.fn_cargos_listar_paginado(integer, integer, text) IS 'Cargos paginados con filtro (grilla allCargos)';
COMMENT ON FUNCTION rh.fn_cargos_listar(boolean)  IS 'Lista simple de cargos para combos y selectores';
COMMENT ON FUNCTION rh.fn_cargos_obtener(bigint)  IS 'Un cargo por id';
COMMENT ON FUNCTION rh.fn_cargos_crear(varchar, text, varchar, numeric, boolean, bigint, varchar, varchar, inet, text, uuid)         IS 'Alta de cargo con contexto de auditoría';
COMMENT ON FUNCTION rh.fn_cargos_modificar(bigint, varchar, text, varchar, numeric, boolean, bigint, varchar, varchar, inet, text, uuid) IS 'Modificación de cargo con contexto de auditoría';
COMMENT ON FUNCTION rh.fn_cargos_eliminar(bigint, bigint, varchar, varchar, inet, text, uuid)  IS 'Baja de cargo (rechaza si tiene empleados o historial)';
