-- FUNCTION: seguridad.fn_usuarios_crear(character varying, character varying, character varying, character varying, character varying, character varying, character varying, boolean, integer, integer, bigint, character varying, character varying, inet, text, uuid)

-- DROP FUNCTION IF EXISTS seguridad.fn_usuarios_crear(character varying, character varying, character varying, character varying, character varying, character varying, character varying, boolean, integer, integer, bigint, character varying, character varying, inet, text, uuid);

CREATE OR REPLACE FUNCTION seguridad.fn_usuarios_crear(
	p_name character varying,
	p_surname character varying,
	p_email character varying,
	p_phone character varying DEFAULT NULL::character varying,
	p_login_user character varying DEFAULT NULL::character varying,
	p_password character varying DEFAULT NULL::character varying,
	p_avatar character varying DEFAULT NULL::character varying,
	p_isactive boolean DEFAULT true,
	p_perfil_id integer DEFAULT 1,
	p_chorario_id integer DEFAULT NULL::integer,
	p_usuario_id bigint DEFAULT NULL::bigint,
	p_usuario_login character varying DEFAULT NULL::character varying,
	p_usuario_nombre character varying DEFAULT NULL::character varying,
	p_ip_address inet DEFAULT NULL::inet,
	p_user_agent text DEFAULT NULL::text,
	p_request_id uuid DEFAULT NULL::uuid)
    RETURNS jsonb
    LANGUAGE 'plpgsql'
    COST 100
    VOLATILE SECURITY DEFINER PARALLEL UNSAFE
AS $BODY$
DECLARE
    v_user_id BIGINT;
    v_resultado JSONB;
    v_datos_nuevos JSONB;
    v_fecha_actual TIMESTAMP;
    v_fecha_texto TEXT;
    v_perfil_data RECORD;
    v_chorario_data RECORD;
    v_usuario_creado RECORD;
BEGIN
    -- 1. Obtener fecha actual
    v_fecha_actual := CURRENT_TIMESTAMP;
    v_fecha_texto := to_char(v_fecha_actual, 'YYYY-MM-DD HH24:MI:SS');
    
    -- 2. Establecer contexto de auditoría
    PERFORM set_config('app.usuario_id', COALESCE(p_usuario_id::TEXT, ''), true);
    PERFORM set_config('app.usuario_login', COALESCE(p_usuario_login, current_user), true);
    PERFORM set_config('app.usuario_nombre', COALESCE(p_usuario_nombre, current_user), true);
    PERFORM set_config('app.ip_address', p_ip_address::TEXT, true);
    PERFORM set_config('app.user_agent', p_user_agent, true);
    PERFORM set_config('app.request_id', p_request_id::TEXT, true);
    PERFORM set_config('app.modulo', 'seguridad.users', true);
    
    -- 3. Validaciones
    IF p_name IS NULL OR TRIM(p_name) = '' THEN
        RAISE EXCEPTION 'El nombre es obligatorio' USING ERRCODE = 'P0001';
    END IF;
    
    IF p_surname IS NULL OR TRIM(p_surname) = '' THEN
        RAISE EXCEPTION 'El apellido es obligatorio' USING ERRCODE = 'P0002';
    END IF;
    
    IF p_login_user IS NULL OR TRIM(p_login_user) = '' THEN
        RAISE EXCEPTION 'El login de usuario es obligatorio' USING ERRCODE = 'P0003';
    END IF;
    
    IF p_email IS NULL OR TRIM(p_email) = '' THEN
        RAISE EXCEPTION 'El email es obligatorio' USING ERRCODE = 'P0004';
    END IF;
    
    IF p_password IS NULL OR TRIM(p_password) = '' THEN
        RAISE EXCEPTION 'La contraseña es obligatoria' USING ERRCODE = 'P0005';
    END IF;
    
    -- 4. Verificar login único
    IF EXISTS (SELECT 1 FROM seguridad.users WHERE login_user = TRIM(p_login_user)) THEN
        RAISE EXCEPTION 'Ya existe un usuario con ese login' USING ERRCODE = 'P0006';
    END IF;
    
    -- 5. Verificar email único
    IF EXISTS (SELECT 1 FROM seguridad.users WHERE email = TRIM(p_email)) THEN
        RAISE EXCEPTION 'Ya existe un usuario con ese email' USING ERRCODE = 'P0007';
    END IF;
    
    -- 6. Verificar que el perfil existe
    IF p_perfil_id IS NOT NULL THEN
        IF NOT EXISTS (SELECT 1 FROM seguridad.perfiles WHERE id = p_perfil_id) THEN
            RAISE EXCEPTION 'El perfil no existe' USING ERRCODE = 'P0008';
        END IF;
        SELECT id, nombre INTO v_perfil_data FROM seguridad.perfiles WHERE id = p_perfil_id;
    ELSE
        SELECT id, nombre INTO v_perfil_data FROM seguridad.perfiles WHERE id = 1;
    END IF;
    
    -- 7. Verificar que el horario existe (si se proporcionó)
    IF p_chorario_id IS NOT NULL THEN
        IF NOT EXISTS (SELECT 1 FROM seguridad.chorarios WHERE id = p_chorario_id) THEN
            RAISE EXCEPTION 'El horario no existe' USING ERRCODE = 'P0009';
        END IF;
        SELECT id, nombre INTO v_chorario_data FROM seguridad.chorarios WHERE id = p_chorario_id;
    ELSE
        v_chorario_data := NULL;
    END IF;
    
    -- 8. Insertar usuario
    INSERT INTO seguridad.users (
        name, surname, email, phone, login_user, password, avatar,
        type_user, isactive, islogin, perfil_id, chorario_id,
        created_by, updated_by, created_at, updated_at
    ) VALUES (
        TRIM(p_name),
        TRIM(p_surname),
        TRIM(p_email),
        p_phone,
        TRIM(p_login_user),
        p_password,
        p_avatar,
        1,
        COALESCE(p_isactive, true),
        false,
        v_perfil_data.id,
        p_chorario_id,
        p_usuario_login,
        p_usuario_login,
        v_fecha_actual,
        v_fecha_actual
    )
    RETURNING 
        id, name, surname, email, phone, login_user, avatar,
        type_user, isactive, islogin, isreset, perfil_id, chorario_id,
        created_by, updated_by, created_at, updated_at
    INTO v_usuario_creado;
    
    -- 9. Obtener el ID del usuario creado
    v_user_id := v_usuario_creado.id;
    
    -- 10. Construir JSON de datos NUEVOS
    v_datos_nuevos := jsonb_build_object(
        'id', v_usuario_creado.id,
        'name', v_usuario_creado.name,
        'surname', v_usuario_creado.surname,
        'email', v_usuario_creado.email,
        'phone', v_usuario_creado.phone,
        'login_user', v_usuario_creado.login_user,
        'avatar', v_usuario_creado.avatar,
        'type_user', v_usuario_creado.type_user,
        'isactive', v_usuario_creado.isactive,
        'islogin', v_usuario_creado.islogin,
        'isreset', v_usuario_creado.isreset,
        'perfil', jsonb_build_object(
            'id', v_perfil_data.id,
            'nombre', v_perfil_data.nombre
        ),
        'chorario', CASE 
            WHEN v_chorario_data IS NOT NULL THEN 
                jsonb_build_object(
                    'id', v_chorario_data.id,
                    'nombre', v_chorario_data.nombre
                )
            ELSE NULL
        END,
        'created_by', v_usuario_creado.created_by,
        'created_at', to_char(v_usuario_creado.created_at, 'YYYY-MM-DD HH24:MI:SS'),
        'updated_by', v_usuario_creado.updated_by,
        'updated_at', to_char(v_usuario_creado.updated_at, 'YYYY-MM-DD HH24:MI:SS'),
        'last_login_at', NULL,
        'user_verified_at', NULL,
        'email_verified_at', NULL,
        'recovery_code', NULL,
        'recovery_code_expires_at', NULL
    );
    
    -- 11. Guardar datos NUEVOS en el contexto
    PERFORM set_config('app.datos_nuevos', v_datos_nuevos::TEXT, true);
    
    -- 12. Obtener el usuario recién creado con datos completos
    SELECT jsonb_build_object(
        'success', true,
        'message', 'Usuario creado exitosamente',
        'data', jsonb_build_object(
            'id', u.id,
            'name', u.name,
            'surname', u.surname,
            'email', u.email,
            'phone', u.phone,
            'login_user', u.login_user,
            'avatar', u.avatar,
            'type_user', u.type_user,
            'isactive', u.isactive,
            'islogin', u.islogin,
            'isreset', u.isreset,
            'perfil', jsonb_build_object(
                'id', p.id,
                'nombre', p.nombre
            ),
            'chorario', jsonb_build_object(
                'id', h.id,
                'nombre', h.nombre
            ),
            'created_by', u.created_by,
            'created_at', to_char(u.created_at, 'YYYY-MM-DD HH24:MI:SS'),
            'updated_by', u.updated_by,
            'updated_at', to_char(u.updated_at, 'YYYY-MM-DD HH24:MI:SS'),
            'last_login_at', to_char(u.last_login_at, 'YYYY-MM-DD HH24:MI:SS'),
            'user_verified_at', to_char(u.user_verified_at, 'YYYY-MM-DD HH24:MI:SS'),
            'email_verified_at', to_char(u.email_verified_at, 'YYYY-MM-DD HH24:MI:SS'),
            'recovery_code', u.recovery_code,
            'recovery_code_expires_at', to_char(u.recovery_code_expires_at, 'YYYY-MM-DD HH24:MI:SS')
        )
    ) INTO v_resultado
    FROM seguridad.users u
    LEFT JOIN seguridad.perfiles p ON p.id = u.perfil_id
    LEFT JOIN seguridad.chorarios h ON h.id = u.chorario_id
    WHERE u.id = v_user_id;
    
    -- Retornar resultado exitoso
    RETURN v_resultado;

EXCEPTION
    WHEN OTHERS THEN
        -- Limpiar contexto
        PERFORM set_config('app.datos_nuevos', '', true);
        PERFORM set_config('app.usuario_id', '', true);
        PERFORM set_config('app.usuario_login', '', true);
        PERFORM set_config('app.usuario_nombre', '', true);
        PERFORM set_config('app.ip_address', '', true);
        PERFORM set_config('app.user_agent', '', true);
        PERFORM set_config('app.request_id', '', true);
        PERFORM set_config('app.modulo', '', true);
        
        -- Retornar error
        RETURN jsonb_build_object(
            'success', false,
            'message', 'Error al crear usuario: ' || SQLERRM,
            'error_code', SQLSTATE
        );
END;
$BODY$;

ALTER FUNCTION seguridad.fn_usuarios_crear(character varying, character varying, character varying, character varying, character varying, character varying, character varying, boolean, integer, integer, bigint, character varying, character varying, inet, text, uuid)
    OWNER TO postgres;

