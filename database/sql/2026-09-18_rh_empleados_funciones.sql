-- ============================================================================
-- CRUD de EMPLEADOS (esquema rh) — mismo esquema que rh.fn_cargos_* /
-- rh.fn_departamentos_* / seguridad.fn_usuarios_*:
--   rh.fn_empleados_listar_paginado(page, per_page, search)
--   rh.fn_empleados_listar(solo_activos)      lista simple (selector listEmpleados / combos)
--   rh.fn_empleados_obtener(id)
--   rh.fn_empleados_crear / modificar / eliminar (contexto de auditoría)
--   rh.fn_empleados_imagen(id, foto, ...)     guarda el nombre del fichero de la foto
--
-- La tabla rh.empleados ya existe con sus triggers de auditoría; se añade
-- la columna `foto` (nombre del fichero en storage/app/public/img/empleados,
-- como `avatar` en seguridad.users).
--
-- Reglas (RAISE EXCEPTION + SQLSTATE propio → 4xx en el back):
--   P0001 nombres obligatorios       P0002 apellidos obligatorios
--   P0003 identificación obligatoria P0004 email obligatorio
--   P0006 identificación duplicada   P0007 email duplicado
--   P0008 cargo inexistente          P0009 departamento inexistente
--   P0010 jefe inexistente / es él mismo   P0011 fecha de ingreso obligatoria
--   P0012 fecha de salida anterior al ingreso   P0013 no existe
--   P0014 tiene registros asociados  P0015 salario negativo
--   P0016 tipo de contrato inválido  P0017 género inválido
-- Idempotente.
-- ============================================================================

ALTER TABLE rh.empleados ADD COLUMN IF NOT EXISTS foto varchar(255);
COMMENT ON COLUMN rh.empleados.foto IS 'Nombre del fichero de la foto en storage/app/public/img/empleados (NULL = sin foto)';

-- ---------------------------------------------------------------------------
-- LISTADO PAGINADO (grilla)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION rh.fn_empleados_listar_paginado(
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
      FROM rh.empleados e
      LEFT JOIN rh.cargos c        ON c.id = e.cargo_id
      LEFT JOIN rh.departamentos d ON d.id = e.departamento_id
     WHERE v_filtro IS NULL
        OR CONCAT_WS(' ', e.nombres, e.apellidos) ILIKE '%' || v_filtro || '%'
        OR CONCAT_WS(' ', e.apellidos, e.nombres) ILIKE '%' || v_filtro || '%'
        OR e.numero_identificacion ILIKE '%' || v_filtro || '%'
        OR e.email  ILIKE '%' || v_filtro || '%'
        OR c.nombre ILIKE '%' || v_filtro || '%'
        OR d.nombre ILIKE '%' || v_filtro || '%'
        OR e.id::text ILIKE '%' || v_filtro || '%';

    SELECT COALESCE(jsonb_agg(
        jsonb_build_object(
            'id',                    t.id,
            'numero_identificacion', t.numero_identificacion,
            'tipo_identificacion',   t.tipo_identificacion,
            'nombres',               t.nombres,
            'apellidos',             t.apellidos,
            'nombre_completo',       TRIM(CONCAT_WS(' ', t.nombres, t.apellidos)),
            'email',                 t.email,
            'email_personal',        t.email_personal,
            'telefono',              t.telefono,
            'celular',               t.celular,
            'fecha_nacimiento',      to_char(t.fecha_nacimiento, 'YYYY-MM-DD'),
            'genero',                t.genero,
            'direccion',             t.direccion,
            'cargo_id',              t.cargo_id,
            'cargo_nombre',          t.cargo_nombre,
            'departamento_id',       t.departamento_id,
            'departamento_nombre',   t.departamento_nombre,
            'jefe_id',               t.jefe_id,
            'jefe_nombre',           t.jefe_nombre,
            'fecha_ingreso',         to_char(t.fecha_ingreso, 'YYYY-MM-DD'),
            'fecha_salida',          to_char(t.fecha_salida, 'YYYY-MM-DD'),
            'estado',                t.estado,
            'tipo_contrato',         t.tipo_contrato,
            'salario',               t.salario,
            'foto',                  t.foto,
            'activo',                t.activo,
            'created_by',            t.created_by,
            'updated_by',            t.updated_by,
            'created_at',            to_char(t.created_at, 'YYYY-MM-DD HH24:MI:SS'),
            'updated_at',            to_char(t.updated_at, 'YYYY-MM-DD HH24:MI:SS')
        ) ORDER BY t.id DESC
    ), '[]'::jsonb) INTO v_data
    FROM (
        SELECT e.*, c.nombre AS cargo_nombre, d.nombre AS departamento_nombre,
               NULLIF(TRIM(CONCAT_WS(' ', j.nombres, j.apellidos)), '') AS jefe_nombre
          FROM rh.empleados e
          LEFT JOIN rh.cargos c        ON c.id = e.cargo_id
          LEFT JOIN rh.departamentos d ON d.id = e.departamento_id
          LEFT JOIN rh.empleados j     ON j.id = e.jefe_id
         WHERE v_filtro IS NULL
            OR CONCAT_WS(' ', e.nombres, e.apellidos) ILIKE '%' || v_filtro || '%'
            OR CONCAT_WS(' ', e.apellidos, e.nombres) ILIKE '%' || v_filtro || '%'
            OR e.numero_identificacion ILIKE '%' || v_filtro || '%'
            OR e.email  ILIKE '%' || v_filtro || '%'
            OR c.nombre ILIKE '%' || v_filtro || '%'
            OR d.nombre ILIKE '%' || v_filtro || '%'
            OR e.id::text ILIKE '%' || v_filtro || '%'
         ORDER BY e.id DESC
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
        RETURN jsonb_build_object('success', false, 'message', 'Error al listar empleados: ' || SQLERRM, 'error_code', SQLSTATE);
END;
$function$;

-- ---------------------------------------------------------------------------
-- LISTA SIMPLE (selector / combos: jefe, responsable…)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION rh.fn_empleados_listar(p_solo_activos boolean DEFAULT true)
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
            'numero_identificacion', e.numero_identificacion,
            'cargo_nombre', c.nombre,
            'departamento_nombre', d.nombre,
            'activo', e.activo
        ) ORDER BY e.apellidos, e.nombres
    ), '[]'::jsonb) INTO v_data
    FROM rh.empleados e
    LEFT JOIN rh.cargos c        ON c.id = e.cargo_id
    LEFT JOIN rh.departamentos d ON d.id = e.departamento_id
    WHERE NOT p_solo_activos OR (e.activo AND COALESCE(e.estado, 'ACTIVO') = 'ACTIVO');

    RETURN jsonb_build_object('success', true, 'message', 'Empleados obtenidos exitosamente', 'data', v_data);
EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object('success', false, 'message', 'Error al listar empleados: ' || SQLERRM, 'error_code', SQLSTATE);
END;
$function$;

-- ---------------------------------------------------------------------------
-- OBTENER UNO
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION rh.fn_empleados_obtener(p_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
    v_data jsonb;
BEGIN
    SELECT jsonb_build_object(
        'id',                    e.id,
        'numero_identificacion', e.numero_identificacion,
        'tipo_identificacion',   e.tipo_identificacion,
        'nombres',               e.nombres,
        'apellidos',             e.apellidos,
        'nombre_completo',       TRIM(CONCAT_WS(' ', e.nombres, e.apellidos)),
        'email',                 e.email,
        'email_personal',        e.email_personal,
        'telefono',              e.telefono,
        'celular',               e.celular,
        'fecha_nacimiento',      to_char(e.fecha_nacimiento, 'YYYY-MM-DD'),
        'genero',                e.genero,
        'direccion',             e.direccion,
        'cargo_id',              e.cargo_id,
        'cargo_nombre',          c.nombre,
        'departamento_id',       e.departamento_id,
        'departamento_nombre',   d.nombre,
        'jefe_id',               e.jefe_id,
        'jefe_nombre',           NULLIF(TRIM(CONCAT_WS(' ', j.nombres, j.apellidos)), ''),
        'fecha_ingreso',         to_char(e.fecha_ingreso, 'YYYY-MM-DD'),
        'fecha_salida',          to_char(e.fecha_salida, 'YYYY-MM-DD'),
        'estado',                e.estado,
        'tipo_contrato',         e.tipo_contrato,
        'salario',               e.salario,
        'foto',                  e.foto,
        'activo',                e.activo,
        'created_by',            e.created_by,
        'updated_by',            e.updated_by,
        'created_at',            to_char(e.created_at, 'YYYY-MM-DD HH24:MI:SS'),
        'updated_at',            to_char(e.updated_at, 'YYYY-MM-DD HH24:MI:SS')
    ) INTO v_data
    FROM rh.empleados e
    LEFT JOIN rh.cargos c        ON c.id = e.cargo_id
    LEFT JOIN rh.departamentos d ON d.id = e.departamento_id
    LEFT JOIN rh.empleados j     ON j.id = e.jefe_id
    WHERE e.id = p_id;

    IF v_data IS NULL THEN
        RETURN jsonb_build_object('success', false, 'message', 'Empleado no encontrado', 'error_code', 'EMPLEADO_NOT_FOUND', 'data', null);
    END IF;
    RETURN jsonb_build_object('success', true, 'message', 'Empleado obtenido exitosamente', 'data', v_data);
EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object('success', false, 'message', 'Error al obtener el empleado: ' || SQLERRM, 'error_code', SQLSTATE);
END;
$function$;

-- ---------------------------------------------------------------------------
-- VALIDACIÓN COMÚN (crear / modificar). Lanza las excepciones de negocio.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION rh.fn_empleados_validar(
    p_id                    bigint,      -- NULL al crear
    p_numero_identificacion varchar,
    p_tipo_identificacion   varchar,
    p_nombres               varchar,
    p_apellidos             varchar,
    p_email                 varchar,
    p_genero                char,
    p_cargo_id              bigint,
    p_departamento_id       bigint,
    p_jefe_id               bigint,
    p_fecha_ingreso         date,
    p_fecha_salida          date,
    p_tipo_contrato         varchar,
    p_salario               numeric
)
RETURNS void
LANGUAGE plpgsql
AS $function$
BEGIN
    IF p_nombres IS NULL OR length(TRIM(p_nombres)) < 2 THEN
        RAISE EXCEPTION 'Los nombres son obligatorios (mínimo 2 caracteres)' USING ERRCODE = 'P0001';
    END IF;
    IF p_apellidos IS NULL OR length(TRIM(p_apellidos)) < 2 THEN
        RAISE EXCEPTION 'Los apellidos son obligatorios (mínimo 2 caracteres)' USING ERRCODE = 'P0002';
    END IF;
    IF p_numero_identificacion IS NULL OR TRIM(p_numero_identificacion) = '' THEN
        RAISE EXCEPTION 'El número de identificación es obligatorio' USING ERRCODE = 'P0003';
    END IF;
    IF p_email IS NULL OR TRIM(p_email) = '' THEN
        RAISE EXCEPTION 'El correo electrónico es obligatorio' USING ERRCODE = 'P0004';
    END IF;
    IF EXISTS (SELECT 1 FROM rh.empleados WHERE numero_identificacion = TRIM(p_numero_identificacion)
                  AND tipo_identificacion = COALESCE(p_tipo_identificacion, 'CC') AND (p_id IS NULL OR id <> p_id)) THEN
        RAISE EXCEPTION 'Ya existe un empleado con esa identificación' USING ERRCODE = 'P0006';
    END IF;
    IF EXISTS (SELECT 1 FROM rh.empleados WHERE LOWER(email) = LOWER(TRIM(p_email)) AND (p_id IS NULL OR id <> p_id)) THEN
        RAISE EXCEPTION 'Ya existe un empleado con ese correo' USING ERRCODE = 'P0007';
    END IF;
    IF p_cargo_id IS NULL OR NOT EXISTS (SELECT 1 FROM rh.cargos WHERE id = p_cargo_id) THEN
        RAISE EXCEPTION 'Debe asignar un cargo válido' USING ERRCODE = 'P0008';
    END IF;
    IF p_departamento_id IS NULL OR NOT EXISTS (SELECT 1 FROM rh.departamentos WHERE id = p_departamento_id) THEN
        RAISE EXCEPTION 'Debe asignar un departamento válido' USING ERRCODE = 'P0009';
    END IF;
    IF p_jefe_id IS NOT NULL THEN
        IF p_id IS NOT NULL AND p_jefe_id = p_id THEN
            RAISE EXCEPTION 'Un empleado no puede ser su propio jefe' USING ERRCODE = 'P0010';
        END IF;
        IF NOT EXISTS (SELECT 1 FROM rh.empleados WHERE id = p_jefe_id) THEN
            RAISE EXCEPTION 'El jefe seleccionado no existe' USING ERRCODE = 'P0010';
        END IF;
    END IF;
    IF p_fecha_ingreso IS NULL THEN
        RAISE EXCEPTION 'La fecha de ingreso es obligatoria' USING ERRCODE = 'P0011';
    END IF;
    IF p_fecha_salida IS NOT NULL AND p_fecha_salida < p_fecha_ingreso THEN
        RAISE EXCEPTION 'La fecha de salida no puede ser anterior a la de ingreso' USING ERRCODE = 'P0012';
    END IF;
    IF p_salario IS NOT NULL AND p_salario < 0 THEN
        RAISE EXCEPTION 'El salario no puede ser negativo' USING ERRCODE = 'P0015';
    END IF;
    IF COALESCE(p_tipo_contrato, 'INDEFINIDO') NOT IN ('INDEFINIDO', 'TEMPORAL', 'PRACTICAS', 'CONSULTORIA') THEN
        RAISE EXCEPTION 'El tipo de contrato % no es válido', p_tipo_contrato USING ERRCODE = 'P0016';
    END IF;
    IF p_genero IS NOT NULL AND p_genero NOT IN ('M', 'F', 'O') THEN
        RAISE EXCEPTION 'El género % no es válido', p_genero USING ERRCODE = 'P0017';
    END IF;
END;
$function$;

-- ---------------------------------------------------------------------------
-- CREAR
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION rh.fn_empleados_crear(
    p_numero_identificacion varchar,
    p_tipo_identificacion   varchar,
    p_nombres               varchar,
    p_apellidos             varchar,
    p_email                 varchar,
    p_email_personal        varchar DEFAULT NULL,
    p_telefono              varchar DEFAULT NULL,
    p_celular               varchar DEFAULT NULL,
    p_fecha_nacimiento      date    DEFAULT NULL,
    p_genero                char    DEFAULT NULL,
    p_direccion             text    DEFAULT NULL,
    p_cargo_id              bigint  DEFAULT NULL,
    p_departamento_id       bigint  DEFAULT NULL,
    p_jefe_id               bigint  DEFAULT NULL,
    p_fecha_ingreso         date    DEFAULT NULL,
    p_fecha_salida          date    DEFAULT NULL,
    p_estado                varchar DEFAULT 'ACTIVO',
    p_tipo_contrato         varchar DEFAULT 'INDEFINIDO',
    p_salario               numeric DEFAULT NULL,
    p_activo                boolean DEFAULT true,
    p_usuario_id            bigint  DEFAULT NULL,
    p_usuario_login         varchar DEFAULT NULL,
    p_usuario_nombre        varchar DEFAULT NULL,
    p_ip_address            inet    DEFAULT NULL,
    p_user_agent            text    DEFAULT NULL,
    p_request_id            uuid    DEFAULT NULL
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
BEGIN
    PERFORM set_config('app.usuario_id',     COALESCE(p_usuario_id::text, ''), true);
    PERFORM set_config('app.usuario_login',  COALESCE(p_usuario_login, current_user), true);
    PERFORM set_config('app.usuario_nombre', COALESCE(p_usuario_nombre, current_user), true);
    PERFORM set_config('app.ip_address',     COALESCE(p_ip_address::text, ''), true);
    PERFORM set_config('app.user_agent',     COALESCE(p_user_agent, ''), true);
    PERFORM set_config('app.request_id',     COALESCE(p_request_id::text, ''), true);
    PERFORM set_config('app.modulo',         'rh.empleados', true);

    PERFORM rh.fn_empleados_validar(NULL, p_numero_identificacion, p_tipo_identificacion, p_nombres, p_apellidos, p_email,
                                    p_genero, p_cargo_id, p_departamento_id, p_jefe_id, p_fecha_ingreso, p_fecha_salida,
                                    p_tipo_contrato, p_salario);

    v_datos_nuevos := jsonb_build_object(
        'numero_identificacion', TRIM(p_numero_identificacion), 'tipo_identificacion', COALESCE(p_tipo_identificacion, 'CC'),
        'nombres', TRIM(p_nombres), 'apellidos', TRIM(p_apellidos), 'email', LOWER(TRIM(p_email)),
        'email_personal', NULLIF(LOWER(TRIM(COALESCE(p_email_personal, ''))), ''),
        'telefono', NULLIF(TRIM(COALESCE(p_telefono, '')), ''), 'celular', NULLIF(TRIM(COALESCE(p_celular, '')), ''),
        'fecha_nacimiento', to_char(p_fecha_nacimiento, 'YYYY-MM-DD'), 'genero', p_genero,
        'direccion', NULLIF(TRIM(COALESCE(p_direccion, '')), ''),
        'cargo', jsonb_build_object('id', p_cargo_id, 'nombre', (SELECT nombre FROM rh.cargos WHERE id = p_cargo_id)),
        'departamento', jsonb_build_object('id', p_departamento_id, 'nombre', (SELECT nombre FROM rh.departamentos WHERE id = p_departamento_id)),
        'jefe_id', p_jefe_id,
        'fecha_ingreso', to_char(p_fecha_ingreso, 'YYYY-MM-DD'), 'fecha_salida', to_char(p_fecha_salida, 'YYYY-MM-DD'),
        'estado', COALESCE(p_estado, 'ACTIVO'), 'tipo_contrato', COALESCE(p_tipo_contrato, 'INDEFINIDO'),
        'salario', p_salario, 'activo', COALESCE(p_activo, true),
        'created_by', p_usuario_login, 'created_at', to_char(v_fecha, 'YYYY-MM-DD HH24:MI:SS'),
        'updated_by', p_usuario_login, 'updated_at', to_char(v_fecha, 'YYYY-MM-DD HH24:MI:SS')
    );
    PERFORM set_config('app.datos_nuevos', v_datos_nuevos::text, true);

    INSERT INTO rh.empleados (
        numero_identificacion, tipo_identificacion, nombres, apellidos, email, email_personal, telefono, celular,
        fecha_nacimiento, genero, direccion, cargo_id, departamento_id, jefe_id, fecha_ingreso, fecha_salida,
        estado, tipo_contrato, salario, activo, created_by, updated_by, created_at, updated_at
    ) VALUES (
        TRIM(p_numero_identificacion), COALESCE(p_tipo_identificacion, 'CC'), TRIM(p_nombres), TRIM(p_apellidos),
        LOWER(TRIM(p_email)), NULLIF(LOWER(TRIM(COALESCE(p_email_personal, ''))), ''),
        NULLIF(TRIM(COALESCE(p_telefono, '')), ''), NULLIF(TRIM(COALESCE(p_celular, '')), ''),
        p_fecha_nacimiento, p_genero, NULLIF(TRIM(COALESCE(p_direccion, '')), ''),
        p_cargo_id, p_departamento_id, p_jefe_id, p_fecha_ingreso, p_fecha_salida,
        COALESCE(p_estado, 'ACTIVO'), COALESCE(p_tipo_contrato, 'INDEFINIDO'), p_salario, COALESCE(p_activo, true),
        p_usuario_login, p_usuario_login, v_fecha, v_fecha
    )
    RETURNING id INTO v_id;

    PERFORM set_config('app.datos_nuevos', '', true);

    RETURN jsonb_build_object('success', true, 'message', 'Empleado creado exitosamente',
                              'data', (rh.fn_empleados_obtener(v_id))->'data');
EXCEPTION
    WHEN unique_violation THEN
        RAISE EXCEPTION 'Ya existe un empleado con esa identificación o correo' USING ERRCODE = 'P0006';
END;
$function$;

-- ---------------------------------------------------------------------------
-- MODIFICAR
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION rh.fn_empleados_modificar(
    p_id                    bigint,
    p_numero_identificacion varchar,
    p_tipo_identificacion   varchar,
    p_nombres               varchar,
    p_apellidos             varchar,
    p_email                 varchar,
    p_email_personal        varchar DEFAULT NULL,
    p_telefono              varchar DEFAULT NULL,
    p_celular               varchar DEFAULT NULL,
    p_fecha_nacimiento      date    DEFAULT NULL,
    p_genero                char    DEFAULT NULL,
    p_direccion             text    DEFAULT NULL,
    p_cargo_id              bigint  DEFAULT NULL,
    p_departamento_id       bigint  DEFAULT NULL,
    p_jefe_id               bigint  DEFAULT NULL,
    p_fecha_ingreso         date    DEFAULT NULL,
    p_fecha_salida          date    DEFAULT NULL,
    p_estado                varchar DEFAULT 'ACTIVO',
    p_tipo_contrato         varchar DEFAULT 'INDEFINIDO',
    p_salario               numeric DEFAULT NULL,
    p_activo                boolean DEFAULT true,
    p_usuario_id            bigint  DEFAULT NULL,
    p_usuario_login         varchar DEFAULT NULL,
    p_usuario_nombre        varchar DEFAULT NULL,
    p_ip_address            inet    DEFAULT NULL,
    p_user_agent            text    DEFAULT NULL,
    p_request_id            uuid    DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'rh', 'auditoria'
AS $function$
DECLARE
    v_actual           rh.empleados%ROWTYPE;
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
    PERFORM set_config('app.modulo',         'rh.empleados', true);

    SELECT * INTO v_actual FROM rh.empleados WHERE id = p_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'El empleado no existe' USING ERRCODE = 'P0013';
    END IF;

    PERFORM rh.fn_empleados_validar(p_id, p_numero_identificacion, p_tipo_identificacion, p_nombres, p_apellidos, p_email,
                                    p_genero, p_cargo_id, p_departamento_id, p_jefe_id, p_fecha_ingreso, p_fecha_salida,
                                    p_tipo_contrato, p_salario);

    v_datos_anteriores := (rh.fn_empleados_obtener(p_id))->'data';
    v_datos_nuevos := jsonb_build_object(
        'id', p_id,
        'numero_identificacion', TRIM(p_numero_identificacion), 'tipo_identificacion', COALESCE(p_tipo_identificacion, 'CC'),
        'nombres', TRIM(p_nombres), 'apellidos', TRIM(p_apellidos), 'email', LOWER(TRIM(p_email)),
        'email_personal', NULLIF(LOWER(TRIM(COALESCE(p_email_personal, ''))), ''),
        'telefono', NULLIF(TRIM(COALESCE(p_telefono, '')), ''), 'celular', NULLIF(TRIM(COALESCE(p_celular, '')), ''),
        'fecha_nacimiento', to_char(p_fecha_nacimiento, 'YYYY-MM-DD'), 'genero', p_genero,
        'direccion', NULLIF(TRIM(COALESCE(p_direccion, '')), ''),
        'cargo', jsonb_build_object('id', p_cargo_id, 'nombre', (SELECT nombre FROM rh.cargos WHERE id = p_cargo_id)),
        'departamento', jsonb_build_object('id', p_departamento_id, 'nombre', (SELECT nombre FROM rh.departamentos WHERE id = p_departamento_id)),
        'jefe_id', p_jefe_id,
        'fecha_ingreso', to_char(p_fecha_ingreso, 'YYYY-MM-DD'), 'fecha_salida', to_char(p_fecha_salida, 'YYYY-MM-DD'),
        'estado', COALESCE(p_estado, 'ACTIVO'), 'tipo_contrato', COALESCE(p_tipo_contrato, 'INDEFINIDO'),
        'salario', p_salario, 'foto', v_actual.foto, 'activo', COALESCE(p_activo, true),
        'created_by', v_actual.created_by, 'created_at', to_char(v_actual.created_at, 'YYYY-MM-DD HH24:MI:SS'),
        'updated_by', p_usuario_login, 'updated_at', to_char(v_fecha, 'YYYY-MM-DD HH24:MI:SS')
    );
    PERFORM set_config('app.datos_anteriores', v_datos_anteriores::text, true);
    PERFORM set_config('app.datos_nuevos',     v_datos_nuevos::text, true);

    UPDATE rh.empleados
       SET numero_identificacion = TRIM(p_numero_identificacion),
           tipo_identificacion   = COALESCE(p_tipo_identificacion, 'CC'),
           nombres               = TRIM(p_nombres),
           apellidos             = TRIM(p_apellidos),
           email                 = LOWER(TRIM(p_email)),
           email_personal        = NULLIF(LOWER(TRIM(COALESCE(p_email_personal, ''))), ''),
           telefono              = NULLIF(TRIM(COALESCE(p_telefono, '')), ''),
           celular               = NULLIF(TRIM(COALESCE(p_celular, '')), ''),
           fecha_nacimiento      = p_fecha_nacimiento,
           genero                = p_genero,
           direccion             = NULLIF(TRIM(COALESCE(p_direccion, '')), ''),
           cargo_id              = p_cargo_id,
           departamento_id       = p_departamento_id,
           jefe_id               = p_jefe_id,
           fecha_ingreso         = p_fecha_ingreso,
           fecha_salida          = p_fecha_salida,
           estado                = COALESCE(p_estado, 'ACTIVO'),
           tipo_contrato         = COALESCE(p_tipo_contrato, 'INDEFINIDO'),
           salario               = p_salario,
           activo                = COALESCE(p_activo, true),
           updated_by            = p_usuario_login,
           updated_at            = v_fecha
     WHERE id = p_id;

    PERFORM set_config('app.datos_anteriores', '', true);
    PERFORM set_config('app.datos_nuevos', '', true);

    RETURN jsonb_build_object('success', true, 'message', 'Empleado actualizado exitosamente',
                              'data', (rh.fn_empleados_obtener(p_id))->'data');
EXCEPTION
    WHEN unique_violation THEN
        RAISE EXCEPTION 'Ya existe otro empleado con esa identificación o correo' USING ERRCODE = 'P0006';
END;
$function$;

-- ---------------------------------------------------------------------------
-- FOTO: guarda el nombre del fichero (el back ya lo dejó en disco)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION rh.fn_empleados_imagen(
    p_id             bigint,
    p_foto           varchar,
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
    v_anterior varchar;
BEGIN
    PERFORM set_config('app.usuario_id',     COALESCE(p_usuario_id::text, ''), true);
    PERFORM set_config('app.usuario_login',  COALESCE(p_usuario_login, current_user), true);
    PERFORM set_config('app.usuario_nombre', COALESCE(p_usuario_nombre, current_user), true);
    PERFORM set_config('app.ip_address',     COALESCE(p_ip_address::text, ''), true);
    PERFORM set_config('app.user_agent',     COALESCE(p_user_agent, ''), true);
    PERFORM set_config('app.request_id',     COALESCE(p_request_id::text, ''), true);
    PERFORM set_config('app.modulo',         'rh.empleados', true);

    SELECT foto INTO v_anterior FROM rh.empleados WHERE id = p_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'El empleado no existe' USING ERRCODE = 'P0013';
    END IF;

    PERFORM set_config('app.datos_anteriores', jsonb_build_object('id', p_id, 'foto', v_anterior)::text, true);
    PERFORM set_config('app.datos_nuevos',     jsonb_build_object('id', p_id, 'foto', p_foto)::text, true);

    UPDATE rh.empleados SET foto = p_foto, updated_by = p_usuario_login, updated_at = CURRENT_TIMESTAMP WHERE id = p_id;

    PERFORM set_config('app.datos_anteriores', '', true);
    PERFORM set_config('app.datos_nuevos', '', true);

    RETURN jsonb_build_object('success', true, 'message', 'Foto guardada exitosamente',
                              'data', jsonb_build_object('id', p_id, 'foto', p_foto, 'foto_anterior', v_anterior));
END;
$function$;

-- ---------------------------------------------------------------------------
-- ELIMINAR
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION rh.fn_empleados_eliminar(
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
    v_datos_anteriores jsonb;
    v_n                bigint;
BEGIN
    PERFORM set_config('app.usuario_id',     COALESCE(p_usuario_id::text, ''), true);
    PERFORM set_config('app.usuario_login',  COALESCE(p_usuario_login, current_user), true);
    PERFORM set_config('app.usuario_nombre', COALESCE(p_usuario_nombre, current_user), true);
    PERFORM set_config('app.ip_address',     COALESCE(p_ip_address::text, ''), true);
    PERFORM set_config('app.user_agent',     COALESCE(p_user_agent, ''), true);
    PERFORM set_config('app.request_id',     COALESCE(p_request_id::text, ''), true);
    PERFORM set_config('app.modulo',         'rh.empleados', true);

    v_datos_anteriores := (rh.fn_empleados_obtener(p_id))->'data';
    IF v_datos_anteriores IS NULL THEN
        RAISE EXCEPTION 'El empleado no existe' USING ERRCODE = 'P0013';
    END IF;

    -- Referencias que impiden el borrado (mensaje de negocio, no el del constraint)
    SELECT COUNT(*) INTO v_n FROM rh.empleados WHERE jefe_id = p_id;
    IF v_n > 0 THEN RAISE EXCEPTION 'No se puede eliminar: es jefe de % empleado(s). Reasígnelos o desactívelo.', v_n USING ERRCODE = 'P0014'; END IF;
    SELECT COUNT(*) INTO v_n FROM rh.departamentos WHERE empleado_id = p_id;
    IF v_n > 0 THEN RAISE EXCEPTION 'No se puede eliminar: es responsable de % departamento(s). Cambie el responsable o desactívelo.', v_n USING ERRCODE = 'P0014'; END IF;
    SELECT COUNT(*) INTO v_n FROM rh.historial_cargos WHERE empleado_id = p_id;
    IF v_n > 0 THEN RAISE EXCEPTION 'No se puede eliminar: tiene % registro(s) en el historial de cargos. Desactívelo en su lugar.', v_n USING ERRCODE = 'P0014'; END IF;
    SELECT COUNT(*) INTO v_n FROM rh.ausencias WHERE empleado_id = p_id OR aprobado_por = p_id;
    IF v_n > 0 THEN RAISE EXCEPTION 'No se puede eliminar: tiene % ausencia(s) registrada(s). Desactívelo en su lugar.', v_n USING ERRCODE = 'P0014'; END IF;

    PERFORM set_config('app.datos_anteriores', v_datos_anteriores::text, true);

    DELETE FROM rh.empleados WHERE id = p_id;   -- contactos_emergencia cae por ON DELETE CASCADE

    PERFORM set_config('app.datos_anteriores', '', true);

    RETURN jsonb_build_object('success', true, 'message', 'Empleado eliminado exitosamente', 'data', v_datos_anteriores);
EXCEPTION
    WHEN foreign_key_violation THEN
        RAISE EXCEPTION 'No se puede eliminar el empleado porque tiene registros asociados' USING ERRCODE = 'P0014';
END;
$function$;

ALTER FUNCTION rh.fn_empleados_listar_paginado(integer, integer, text) OWNER TO postgres;
ALTER FUNCTION rh.fn_empleados_listar(boolean) OWNER TO postgres;
ALTER FUNCTION rh.fn_empleados_obtener(bigint) OWNER TO postgres;
ALTER FUNCTION rh.fn_empleados_validar(bigint, varchar, varchar, varchar, varchar, varchar, char, bigint, bigint, bigint, date, date, varchar, numeric) OWNER TO postgres;
ALTER FUNCTION rh.fn_empleados_crear(varchar, varchar, varchar, varchar, varchar, varchar, varchar, varchar, date, char, text, bigint, bigint, bigint, date, date, varchar, varchar, numeric, boolean, bigint, varchar, varchar, inet, text, uuid) OWNER TO postgres;
ALTER FUNCTION rh.fn_empleados_modificar(bigint, varchar, varchar, varchar, varchar, varchar, varchar, varchar, varchar, date, char, text, bigint, bigint, bigint, date, date, varchar, varchar, numeric, boolean, bigint, varchar, varchar, inet, text, uuid) OWNER TO postgres;
ALTER FUNCTION rh.fn_empleados_imagen(bigint, varchar, bigint, varchar, varchar, inet, text, uuid) OWNER TO postgres;
ALTER FUNCTION rh.fn_empleados_eliminar(bigint, bigint, varchar, varchar, inet, text, uuid) OWNER TO postgres;
