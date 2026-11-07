-- ===========================================================================
-- LA SUCURSAL, DENTRO DE LA FICHA DEL EMPLEADO
-- ===========================================================================
-- Hasta aquí la sucursal se asignaba sólo desde la rejilla, con su propio
-- extremo (rh.fn_empleados_asignar_sucursal). Ahora es un campo más de la
-- ficha: se elige al crear o al modificar, como la marca de un producto.
--
-- `fn_empleados_asignar_sucursal` NO se toca: sigue sirviendo para cambiar
-- sólo eso sin abrir una ficha de treinta campos.
--
-- Las dos funciones se tiran y se vuelven a crear porque cambian los
-- parámetros; el cuerpo es el que había, sacado de la base, con el campo
-- nuevo en la validación, en el registro de auditoría y en la escritura.
\set ON_ERROR_STOP on

BEGIN;

DROP FUNCTION IF EXISTS rh.fn_empleados_crear(character varying, character varying, character varying, character varying, character varying, character varying, character varying, character varying, date, character, text, bigint, bigint, bigint, date, date, character varying, character varying, numeric, boolean, bigint, character varying, character varying, inet, text, uuid);

CREATE OR REPLACE FUNCTION rh.fn_empleados_crear(p_numero_identificacion character varying, p_tipo_identificacion character varying, p_nombres character varying, p_apellidos character varying, p_email character varying, p_email_personal character varying DEFAULT NULL::character varying, p_telefono character varying DEFAULT NULL::character varying, p_celular character varying DEFAULT NULL::character varying, p_fecha_nacimiento date DEFAULT NULL::date, p_genero character DEFAULT NULL::bpchar, p_direccion text DEFAULT NULL::text, p_cargo_id bigint DEFAULT NULL::bigint, p_departamento_id bigint DEFAULT NULL::bigint, p_jefe_id bigint DEFAULT NULL::bigint, p_fecha_ingreso date DEFAULT NULL::date, p_fecha_salida date DEFAULT NULL::date, p_estado character varying DEFAULT 'ACTIVO'::character varying, p_tipo_contrato character varying DEFAULT 'INDEFINIDO'::character varying, p_salario numeric DEFAULT NULL::numeric, p_activo boolean DEFAULT true, p_sucursal_id bigint DEFAULT NULL::bigint, p_usuario_id bigint DEFAULT NULL::bigint, p_usuario_login character varying DEFAULT NULL::character varying, p_usuario_nombre character varying DEFAULT NULL::character varying, p_ip_address inet DEFAULT NULL::inet, p_user_agent text DEFAULT NULL::text, p_request_id uuid DEFAULT NULL::uuid)
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

    -- LA SUCURSAL: tiene que existir, no estar en la papelera y estar activa.
    -- Es la misma regla que exige rh.fn_empleados_asignar_sucursal, que sigue
    -- estando para cambiarla sola sin abrir la ficha.
    IF p_sucursal_id IS NOT NULL THEN
        IF NOT EXISTS (SELECT 1 FROM ventas.sucursales
                        WHERE id = p_sucursal_id AND deleted_at IS NULL) THEN
            RAISE EXCEPTION 'La sucursal indicada no existe o está en la papelera' USING ERRCODE = 'P0016';
        END IF;
        IF NOT (SELECT activo FROM ventas.sucursales WHERE id = p_sucursal_id) THEN
            RAISE EXCEPTION 'La sucursal indicada está inactiva' USING ERRCODE = 'P0017';
        END IF;
    END IF;

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
        'salario', p_salario, 'activo', COALESCE(p_activo, true), 'sucursal_id', p_sucursal_id,
        'created_by', p_usuario_login, 'created_at', to_char(v_fecha, 'YYYY-MM-DD HH24:MI:SS'),
        'updated_by', p_usuario_login, 'updated_at', to_char(v_fecha, 'YYYY-MM-DD HH24:MI:SS')
    );
    PERFORM set_config('app.datos_nuevos', v_datos_nuevos::text, true);

    INSERT INTO rh.empleados (
        numero_identificacion, tipo_identificacion, nombres, apellidos, email, email_personal, telefono, celular,
        fecha_nacimiento, genero, direccion, cargo_id, departamento_id, jefe_id, fecha_ingreso, fecha_salida,
        estado, tipo_contrato, salario, activo, sucursal_id, created_by, updated_by, created_at, updated_at
    ) VALUES (
        TRIM(p_numero_identificacion), COALESCE(p_tipo_identificacion, 'CC'), TRIM(p_nombres), TRIM(p_apellidos),
        LOWER(TRIM(p_email)), NULLIF(LOWER(TRIM(COALESCE(p_email_personal, ''))), ''),
        NULLIF(TRIM(COALESCE(p_telefono, '')), ''), NULLIF(TRIM(COALESCE(p_celular, '')), ''),
        p_fecha_nacimiento, p_genero, NULLIF(TRIM(COALESCE(p_direccion, '')), ''),
        p_cargo_id, p_departamento_id, p_jefe_id, p_fecha_ingreso, p_fecha_salida,
        COALESCE(p_estado, 'ACTIVO'), COALESCE(p_tipo_contrato, 'INDEFINIDO'), p_salario, COALESCE(p_activo, true),
        p_sucursal_id,
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

DROP FUNCTION IF EXISTS rh.fn_empleados_modificar(bigint, character varying, character varying, character varying, character varying, character varying, character varying, character varying, character varying, date, character, text, bigint, bigint, bigint, date, date, character varying, character varying, numeric, boolean, bigint, character varying, character varying, inet, text, uuid);

CREATE OR REPLACE FUNCTION rh.fn_empleados_modificar(p_id bigint, p_numero_identificacion character varying, p_tipo_identificacion character varying, p_nombres character varying, p_apellidos character varying, p_email character varying, p_email_personal character varying DEFAULT NULL::character varying, p_telefono character varying DEFAULT NULL::character varying, p_celular character varying DEFAULT NULL::character varying, p_fecha_nacimiento date DEFAULT NULL::date, p_genero character DEFAULT NULL::bpchar, p_direccion text DEFAULT NULL::text, p_cargo_id bigint DEFAULT NULL::bigint, p_departamento_id bigint DEFAULT NULL::bigint, p_jefe_id bigint DEFAULT NULL::bigint, p_fecha_ingreso date DEFAULT NULL::date, p_fecha_salida date DEFAULT NULL::date, p_estado character varying DEFAULT 'ACTIVO'::character varying, p_tipo_contrato character varying DEFAULT 'INDEFINIDO'::character varying, p_salario numeric DEFAULT NULL::numeric, p_activo boolean DEFAULT true, p_sucursal_id bigint DEFAULT NULL::bigint, p_usuario_id bigint DEFAULT NULL::bigint, p_usuario_login character varying DEFAULT NULL::character varying, p_usuario_nombre character varying DEFAULT NULL::character varying, p_ip_address inet DEFAULT NULL::inet, p_user_agent text DEFAULT NULL::text, p_request_id uuid DEFAULT NULL::uuid)
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

    -- LA SUCURSAL: tiene que existir, no estar en la papelera y estar activa.
    -- Es la misma regla que exige rh.fn_empleados_asignar_sucursal, que sigue
    -- estando para cambiarla sola sin abrir la ficha.
    IF p_sucursal_id IS NOT NULL THEN
        IF NOT EXISTS (SELECT 1 FROM ventas.sucursales
                        WHERE id = p_sucursal_id AND deleted_at IS NULL) THEN
            RAISE EXCEPTION 'La sucursal indicada no existe o está en la papelera' USING ERRCODE = 'P0016';
        END IF;
        IF NOT (SELECT activo FROM ventas.sucursales WHERE id = p_sucursal_id) THEN
            RAISE EXCEPTION 'La sucursal indicada está inactiva' USING ERRCODE = 'P0017';
        END IF;
    END IF;

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
        'sucursal_id', p_sucursal_id,
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
           sucursal_id           = p_sucursal_id,
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

COMMIT;
