-- ============================================================================
-- CRUD de DEPARTAMENTOS (esquema rh) — funciones PL/pgSQL, mismo esquema que
-- rh.fn_cargos_* y seguridad.fn_usuarios_*:
--   rh.fn_departamentos_listar_paginado(page, per_page, search)
--   rh.fn_departamentos_listar(solo_activos)          lista simple (combos / selector)
--   rh.fn_departamentos_responsables()                empleados activos para el combo "Responsable"
--   rh.fn_departamentos_obtener(id)
--   rh.fn_departamentos_crear / modificar / eliminar (contexto de auditoría)
--
-- La tabla rh.departamentos ya existe (id, nombre UNIQUE, codigo UNIQUE,
-- descripcion, empleado_id → rh.empleados (responsable), activo, audit cols)
-- con sus tres triggers de auditoría.
--
-- Sustituye a las funciones antiguas rh.fn_departamentos_* (otra firma, sin
-- usuario_id ni datos_anteriores/nuevos; ningún controlador las usaba):
-- se eliminan para que no queden sobrecargas ambiguas.
--
-- Reglas de negocio (RAISE EXCEPTION + SQLSTATE propio → 4xx en el back):
--   P0001 nombre obligatorio     P0006 nombre duplicado     P0016 código duplicado
--   P0013 no existe              P0014 tiene empleados / historial
--   P0017 responsable inexistente o inactivo
-- Idempotente.
-- ============================================================================

DROP FUNCTION IF EXISTS rh.fn_departamentos_listar(integer, integer, boolean, varchar, varchar, varchar);
DROP FUNCTION IF EXISTS rh.fn_departamentos_obtener(bigint);
DROP FUNCTION IF EXISTS rh.fn_departamentos_crear(varchar, text, varchar, bigint, varchar, inet, text, uuid);
DROP FUNCTION IF EXISTS rh.fn_departamentos_actualizar(bigint, varchar, text, varchar, bigint, boolean, varchar, inet, text, uuid);
DROP FUNCTION IF EXISTS rh.fn_departamentos_eliminar(bigint, varchar, inet, text, uuid, boolean);
DROP FUNCTION IF EXISTS rh.fn_departamentos_toggle(bigint, varchar, inet, text, uuid);

-- ---------------------------------------------------------------------------
-- LISTADO PAGINADO (grilla)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION rh.fn_departamentos_listar_paginado(
    p_page     integer DEFAULT 1,
    p_per_page integer DEFAULT 15,
    p_search   text    DEFAULT ''
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
    v_offset integer;
    v_total  bigint;
    v_data   jsonb;
    v_filtro text;
BEGIN
    v_offset := (GREATEST(p_page, 1) - 1) * p_per_page;
    v_filtro := NULLIF(TRIM(COALESCE(p_search, '')), '');

    SELECT COUNT(*) INTO v_total
      FROM rh.departamentos d
      LEFT JOIN rh.empleados e ON e.id = d.empleado_id
     WHERE v_filtro IS NULL
        OR d.nombre      ILIKE '%' || v_filtro || '%'
        OR d.codigo      ILIKE '%' || v_filtro || '%'
        OR d.descripcion ILIKE '%' || v_filtro || '%'
        OR CONCAT_WS(' ', e.nombres, e.apellidos) ILIKE '%' || v_filtro || '%'
        OR d.id::text    ILIKE '%' || v_filtro || '%';

    SELECT COALESCE(jsonb_agg(
        jsonb_build_object(
            'id',              t.id,
            'nombre',          t.nombre,
            'codigo',          t.codigo,
            'descripcion',     t.descripcion,
            'empleado_id',     t.empleado_id,
            'responsable',     t.responsable,
            'activo',          t.activo,
            'num_empleados',   t.num_empleados,
            'created_by',      t.created_by,
            'updated_by',      t.updated_by,
            'created_at',      to_char(t.created_at, 'YYYY-MM-DD HH24:MI:SS'),
            'updated_at',      to_char(t.updated_at, 'YYYY-MM-DD HH24:MI:SS')
        ) ORDER BY t.id DESC
    ), '[]'::jsonb) INTO v_data
    FROM (
        SELECT d.*,
               NULLIF(TRIM(CONCAT_WS(' ', e.nombres, e.apellidos)), '') AS responsable,
               (SELECT COUNT(*) FROM rh.empleados x WHERE x.departamento_id = d.id) AS num_empleados
          FROM rh.departamentos d
          LEFT JOIN rh.empleados e ON e.id = d.empleado_id
         WHERE v_filtro IS NULL
            OR d.nombre      ILIKE '%' || v_filtro || '%'
            OR d.codigo      ILIKE '%' || v_filtro || '%'
            OR d.descripcion ILIKE '%' || v_filtro || '%'
            OR CONCAT_WS(' ', e.nombres, e.apellidos) ILIKE '%' || v_filtro || '%'
            OR d.id::text    ILIKE '%' || v_filtro || '%'
         ORDER BY d.id DESC
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
        RETURN jsonb_build_object('success', false, 'message', 'Error al listar departamentos: ' || SQLERRM, 'error_code', SQLSTATE);
END;
$function$;

-- ---------------------------------------------------------------------------
-- LISTA SIMPLE (combos y selector listDepartamentos)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION rh.fn_departamentos_listar(p_solo_activos boolean DEFAULT true)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
    v_data jsonb;
BEGIN
    SELECT COALESCE(jsonb_agg(
        jsonb_build_object('id', d.id, 'nombre', d.nombre, 'codigo', d.codigo, 'activo', d.activo) ORDER BY d.nombre
    ), '[]'::jsonb) INTO v_data
    FROM rh.departamentos d
    WHERE NOT p_solo_activos OR d.activo;

    RETURN jsonb_build_object('success', true, 'message', 'Departamentos obtenidos exitosamente', 'data', v_data);
EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object('success', false, 'message', 'Error al listar departamentos: ' || SQLERRM, 'error_code', SQLSTATE);
END;
$function$;

-- ---------------------------------------------------------------------------
-- RESPONSABLES: empleados activos para el combo del formulario
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION rh.fn_departamentos_responsables()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
    v_data jsonb;
BEGIN
    SELECT COALESCE(jsonb_agg(
        jsonb_build_object(
            'id', e.id,
            'nombre', TRIM(CONCAT_WS(' ', e.nombres, e.apellidos)),
            'cargo', c.nombre,
            'departamento_id', e.departamento_id
        ) ORDER BY e.apellidos, e.nombres
    ), '[]'::jsonb) INTO v_data
    FROM rh.empleados e
    LEFT JOIN rh.cargos c ON c.id = e.cargo_id
    WHERE e.activo AND COALESCE(e.estado, 'ACTIVO') = 'ACTIVO';

    RETURN jsonb_build_object('success', true, 'message', 'Responsables obtenidos exitosamente', 'data', v_data);
EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object('success', false, 'message', 'Error al listar responsables: ' || SQLERRM, 'error_code', SQLSTATE);
END;
$function$;

-- ---------------------------------------------------------------------------
-- OBTENER UNO
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION rh.fn_departamentos_obtener(p_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
    v_data jsonb;
BEGIN
    SELECT jsonb_build_object(
        'id',            d.id,
        'nombre',        d.nombre,
        'codigo',        d.codigo,
        'descripcion',   d.descripcion,
        'empleado_id',   d.empleado_id,
        'responsable',   NULLIF(TRIM(CONCAT_WS(' ', e.nombres, e.apellidos)), ''),
        'activo',        d.activo,
        'num_empleados', (SELECT COUNT(*) FROM rh.empleados x WHERE x.departamento_id = d.id),
        'created_by',    d.created_by,
        'updated_by',    d.updated_by,
        'created_at',    to_char(d.created_at, 'YYYY-MM-DD HH24:MI:SS'),
        'updated_at',    to_char(d.updated_at, 'YYYY-MM-DD HH24:MI:SS')
    ) INTO v_data
    FROM rh.departamentos d
    LEFT JOIN rh.empleados e ON e.id = d.empleado_id
    WHERE d.id = p_id;

    IF v_data IS NULL THEN
        RETURN jsonb_build_object('success', false, 'message', 'Departamento no encontrado', 'error_code', 'DEPARTAMENTO_NOT_FOUND', 'data', null);
    END IF;
    RETURN jsonb_build_object('success', true, 'message', 'Departamento obtenido exitosamente', 'data', v_data);
EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object('success', false, 'message', 'Error al obtener el departamento: ' || SQLERRM, 'error_code', SQLSTATE);
END;
$function$;

-- ---------------------------------------------------------------------------
-- CREAR
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION rh.fn_departamentos_crear(
    p_nombre         varchar,
    p_codigo         varchar DEFAULT NULL,
    p_descripcion    text    DEFAULT NULL,
    p_empleado_id    bigint  DEFAULT NULL,
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
    v_codigo       varchar;
    v_fecha        timestamptz := CURRENT_TIMESTAMP;
    v_datos_nuevos jsonb;
BEGIN
    PERFORM set_config('app.usuario_id',     COALESCE(p_usuario_id::text, ''), true);
    PERFORM set_config('app.usuario_login',  COALESCE(p_usuario_login, current_user), true);
    PERFORM set_config('app.usuario_nombre', COALESCE(p_usuario_nombre, current_user), true);
    PERFORM set_config('app.ip_address',     COALESCE(p_ip_address::text, ''), true);
    PERFORM set_config('app.user_agent',     COALESCE(p_user_agent, ''), true);
    PERFORM set_config('app.request_id',     COALESCE(p_request_id::text, ''), true);
    PERFORM set_config('app.modulo',         'rh.departamentos', true);

    v_codigo := NULLIF(UPPER(TRIM(COALESCE(p_codigo, ''))), '');

    IF p_nombre IS NULL OR length(TRIM(p_nombre)) < 3 THEN
        RAISE EXCEPTION 'El nombre del departamento es obligatorio (mínimo 3 caracteres)' USING ERRCODE = 'P0001';
    END IF;
    IF EXISTS (SELECT 1 FROM rh.departamentos WHERE UPPER(nombre) = UPPER(TRIM(p_nombre))) THEN
        RAISE EXCEPTION 'Ya existe un departamento con ese nombre' USING ERRCODE = 'P0006';
    END IF;
    IF v_codigo IS NOT NULL AND EXISTS (SELECT 1 FROM rh.departamentos WHERE codigo = v_codigo) THEN
        RAISE EXCEPTION 'Ya existe un departamento con el código %', v_codigo USING ERRCODE = 'P0016';
    END IF;
    IF p_empleado_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM rh.empleados WHERE id = p_empleado_id AND activo) THEN
        RAISE EXCEPTION 'El responsable seleccionado no existe o no está activo' USING ERRCODE = 'P0017';
    END IF;

    v_datos_nuevos := jsonb_build_object(
        'nombre',      TRIM(p_nombre),
        'codigo',      v_codigo,
        'descripcion', NULLIF(TRIM(COALESCE(p_descripcion, '')), ''),
        'empleado_id', p_empleado_id,
        'activo',      COALESCE(p_activo, true),
        'created_by',  p_usuario_login, 'created_at', to_char(v_fecha, 'YYYY-MM-DD HH24:MI:SS'),
        'updated_by',  p_usuario_login, 'updated_at', to_char(v_fecha, 'YYYY-MM-DD HH24:MI:SS')
    );
    PERFORM set_config('app.datos_nuevos', v_datos_nuevos::text, true);

    INSERT INTO rh.departamentos (nombre, codigo, descripcion, empleado_id, activo, created_by, updated_by, created_at, updated_at)
    VALUES (TRIM(p_nombre), v_codigo, NULLIF(TRIM(COALESCE(p_descripcion, '')), ''), p_empleado_id, COALESCE(p_activo, true),
            p_usuario_login, p_usuario_login, v_fecha, v_fecha)
    RETURNING id INTO v_id;

    PERFORM set_config('app.datos_nuevos', '', true);

    RETURN jsonb_build_object('success', true, 'message', 'Departamento creado exitosamente',
                              'data', (rh.fn_departamentos_obtener(v_id))->'data');
EXCEPTION
    WHEN unique_violation THEN
        RAISE EXCEPTION 'Ya existe un departamento con ese nombre o código' USING ERRCODE = 'P0006';
END;
$function$;

-- ---------------------------------------------------------------------------
-- MODIFICAR
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION rh.fn_departamentos_modificar(
    p_id             bigint,
    p_nombre         varchar,
    p_codigo         varchar DEFAULT NULL,
    p_descripcion    text    DEFAULT NULL,
    p_empleado_id    bigint  DEFAULT NULL,
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
    v_actual           rh.departamentos%ROWTYPE;
    v_codigo           varchar;
    v_fecha            timestamptz := CURRENT_TIMESTAMP;
    v_datos_anteriores jsonb;
    v_datos_nuevos     jsonb;
BEGIN
    PERFORM set_config('app.usuario_id',     COALESCE(p_usuario_id::text, ''), true);
    PERFORM set_config('app.usuario_login',  COALESCE(p_usuario_login, current_user), true);
    PERFORM set_config('app.usuario_nombre', COALESCE(p_usuario_nombre, current_user), true);
    PERFORM set_config('app.ip_address',     COALESCE(p_ip_address::text, ''), true);
    PERFORM set_config('app.user_agent',     COALESCE(p_user_agent, ''), true);
    PERFORM set_config('app.request_id',     COALESCE(p_request_id::text, ''), true);
    PERFORM set_config('app.modulo',         'rh.departamentos', true);

    SELECT * INTO v_actual FROM rh.departamentos WHERE id = p_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'El departamento no existe' USING ERRCODE = 'P0013';
    END IF;

    v_codigo := NULLIF(UPPER(TRIM(COALESCE(p_codigo, ''))), '');

    IF p_nombre IS NULL OR length(TRIM(p_nombre)) < 3 THEN
        RAISE EXCEPTION 'El nombre del departamento es obligatorio (mínimo 3 caracteres)' USING ERRCODE = 'P0001';
    END IF;
    IF EXISTS (SELECT 1 FROM rh.departamentos WHERE UPPER(nombre) = UPPER(TRIM(p_nombre)) AND id <> p_id) THEN
        RAISE EXCEPTION 'Ya existe otro departamento con ese nombre' USING ERRCODE = 'P0006';
    END IF;
    IF v_codigo IS NOT NULL AND EXISTS (SELECT 1 FROM rh.departamentos WHERE codigo = v_codigo AND id <> p_id) THEN
        RAISE EXCEPTION 'Ya existe otro departamento con el código %', v_codigo USING ERRCODE = 'P0016';
    END IF;
    IF p_empleado_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM rh.empleados WHERE id = p_empleado_id AND activo) THEN
        RAISE EXCEPTION 'El responsable seleccionado no existe o no está activo' USING ERRCODE = 'P0017';
    END IF;

    v_datos_anteriores := jsonb_build_object(
        'id', v_actual.id, 'nombre', v_actual.nombre, 'codigo', v_actual.codigo, 'descripcion', v_actual.descripcion,
        'empleado_id', v_actual.empleado_id, 'activo', v_actual.activo,
        'created_by', v_actual.created_by, 'created_at', to_char(v_actual.created_at, 'YYYY-MM-DD HH24:MI:SS'),
        'updated_by', v_actual.updated_by, 'updated_at', to_char(v_actual.updated_at, 'YYYY-MM-DD HH24:MI:SS')
    );
    v_datos_nuevos := jsonb_build_object(
        'id', v_actual.id, 'nombre', TRIM(p_nombre), 'codigo', v_codigo,
        'descripcion', NULLIF(TRIM(COALESCE(p_descripcion, '')), ''),
        'empleado_id', p_empleado_id, 'activo', COALESCE(p_activo, true),
        'created_by', v_actual.created_by, 'created_at', to_char(v_actual.created_at, 'YYYY-MM-DD HH24:MI:SS'),
        'updated_by', p_usuario_login, 'updated_at', to_char(v_fecha, 'YYYY-MM-DD HH24:MI:SS')
    );
    PERFORM set_config('app.datos_anteriores', v_datos_anteriores::text, true);
    PERFORM set_config('app.datos_nuevos',     v_datos_nuevos::text, true);

    UPDATE rh.departamentos
       SET nombre      = TRIM(p_nombre),
           codigo      = v_codigo,
           descripcion = NULLIF(TRIM(COALESCE(p_descripcion, '')), ''),
           empleado_id = p_empleado_id,
           activo      = COALESCE(p_activo, true),
           updated_by  = p_usuario_login,
           updated_at  = v_fecha
     WHERE id = p_id;

    PERFORM set_config('app.datos_anteriores', '', true);
    PERFORM set_config('app.datos_nuevos', '', true);

    RETURN jsonb_build_object('success', true, 'message', 'Departamento actualizado exitosamente',
                              'data', (rh.fn_departamentos_obtener(p_id))->'data');
EXCEPTION
    WHEN unique_violation THEN
        RAISE EXCEPTION 'Ya existe otro departamento con ese nombre o código' USING ERRCODE = 'P0006';
END;
$function$;

-- ---------------------------------------------------------------------------
-- ELIMINAR
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION rh.fn_departamentos_eliminar(
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
    v_actual           rh.departamentos%ROWTYPE;
    v_empleados        bigint;
    v_historial        bigint;
    v_datos_anteriores jsonb;
BEGIN
    PERFORM set_config('app.usuario_id',     COALESCE(p_usuario_id::text, ''), true);
    PERFORM set_config('app.usuario_login',  COALESCE(p_usuario_login, current_user), true);
    PERFORM set_config('app.usuario_nombre', COALESCE(p_usuario_nombre, current_user), true);
    PERFORM set_config('app.ip_address',     COALESCE(p_ip_address::text, ''), true);
    PERFORM set_config('app.user_agent',     COALESCE(p_user_agent, ''), true);
    PERFORM set_config('app.request_id',     COALESCE(p_request_id::text, ''), true);
    PERFORM set_config('app.modulo',         'rh.departamentos', true);

    SELECT * INTO v_actual FROM rh.departamentos WHERE id = p_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'El departamento no existe' USING ERRCODE = 'P0013';
    END IF;

    SELECT COUNT(*) INTO v_empleados FROM rh.empleados        WHERE departamento_id = p_id;
    SELECT COUNT(*) INTO v_historial FROM rh.historial_cargos WHERE departamento_id = p_id;
    IF v_empleados > 0 THEN
        RAISE EXCEPTION 'No se puede eliminar: el departamento tiene % empleado(s). Desactívelo en su lugar.', v_empleados USING ERRCODE = 'P0014';
    END IF;
    IF v_historial > 0 THEN
        RAISE EXCEPTION 'No se puede eliminar: el departamento aparece en el historial de % empleado(s). Desactívelo en su lugar.', v_historial USING ERRCODE = 'P0014';
    END IF;

    v_datos_anteriores := jsonb_build_object(
        'id', v_actual.id, 'nombre', v_actual.nombre, 'codigo', v_actual.codigo, 'descripcion', v_actual.descripcion,
        'empleado_id', v_actual.empleado_id, 'activo', v_actual.activo,
        'created_by', v_actual.created_by, 'created_at', to_char(v_actual.created_at, 'YYYY-MM-DD HH24:MI:SS'),
        'updated_by', v_actual.updated_by, 'updated_at', to_char(v_actual.updated_at, 'YYYY-MM-DD HH24:MI:SS')
    );
    PERFORM set_config('app.datos_anteriores', v_datos_anteriores::text, true);

    DELETE FROM rh.departamentos WHERE id = p_id;

    PERFORM set_config('app.datos_anteriores', '', true);

    RETURN jsonb_build_object('success', true, 'message', 'Departamento eliminado exitosamente', 'data', v_datos_anteriores);
EXCEPTION
    WHEN foreign_key_violation THEN
        RAISE EXCEPTION 'No se puede eliminar el departamento porque tiene registros asociados' USING ERRCODE = 'P0014';
END;
$function$;

ALTER FUNCTION rh.fn_departamentos_listar_paginado(integer, integer, text) OWNER TO postgres;
ALTER FUNCTION rh.fn_departamentos_listar(boolean) OWNER TO postgres;
ALTER FUNCTION rh.fn_departamentos_responsables() OWNER TO postgres;
ALTER FUNCTION rh.fn_departamentos_obtener(bigint) OWNER TO postgres;
ALTER FUNCTION rh.fn_departamentos_crear(varchar, varchar, text, bigint, boolean, bigint, varchar, varchar, inet, text, uuid) OWNER TO postgres;
ALTER FUNCTION rh.fn_departamentos_modificar(bigint, varchar, varchar, text, bigint, boolean, bigint, varchar, varchar, inet, text, uuid) OWNER TO postgres;
ALTER FUNCTION rh.fn_departamentos_eliminar(bigint, bigint, varchar, varchar, inet, text, uuid) OWNER TO postgres;

COMMENT ON FUNCTION rh.fn_departamentos_listar_paginado(integer, integer, text) IS 'Departamentos paginados con filtro (grilla allDepartamentos)';
COMMENT ON FUNCTION rh.fn_departamentos_listar(boolean)      IS 'Lista simple de departamentos para combos y selectores';
COMMENT ON FUNCTION rh.fn_departamentos_responsables()       IS 'Empleados activos para elegir el responsable de un departamento';
COMMENT ON FUNCTION rh.fn_departamentos_obtener(bigint)      IS 'Un departamento por id';
COMMENT ON FUNCTION rh.fn_departamentos_crear(varchar, varchar, text, bigint, boolean, bigint, varchar, varchar, inet, text, uuid)            IS 'Alta de departamento con contexto de auditoría';
COMMENT ON FUNCTION rh.fn_departamentos_modificar(bigint, varchar, varchar, text, bigint, boolean, bigint, varchar, varchar, inet, text, uuid) IS 'Modificación de departamento con contexto de auditoría';
COMMENT ON FUNCTION rh.fn_departamentos_eliminar(bigint, bigint, varchar, varchar, inet, text, uuid) IS 'Baja de departamento (rechaza si tiene empleados o historial)';
