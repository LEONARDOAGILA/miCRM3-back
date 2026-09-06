-- FUNCTION: seguridad.fn_usuarios_solicitar_recuperacion(character varying, bigint, character varying, character varying, inet, text, uuid)

-- DROP FUNCTION IF EXISTS seguridad.fn_usuarios_solicitar_recuperacion(character varying, bigint, character varying, character varying, inet, text, uuid);

CREATE OR REPLACE FUNCTION seguridad.fn_usuarios_solicitar_recuperacion(
	p_login_user character varying,
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
    v_user_data RECORD;
    v_datos_anteriores JSONB;
    v_datos_nuevos JSONB;
    v_perfil_data RECORD;
    v_chorario_data RECORD;
    v_codigo TEXT;
    v_expiracion TIMESTAMP;
    v_fecha_actual TIMESTAMP;
    v_fecha_texto TEXT;
    v_resultado JSONB;
BEGIN
    -- 1. Obtener fecha actual
    v_fecha_actual := CURRENT_TIMESTAMP;
    v_fecha_texto := to_char(v_fecha_actual, 'YYYY-MM-DD HH24:MI:SS');
    
    -- 2. Establecer contexto de auditoría (usando los datos del usuario)
    PERFORM set_config('app.usuario_id', COALESCE(p_usuario_id::TEXT, ''), true);
    PERFORM set_config('app.usuario_login', COALESCE(p_usuario_login, current_user), true);
    PERFORM set_config('app.usuario_nombre', COALESCE(p_usuario_nombre, current_user), true);
    PERFORM set_config('app.ip_address', p_ip_address::TEXT, true);
    PERFORM set_config('app.user_agent', p_user_agent, true);
    PERFORM set_config('app.request_id', p_request_id::TEXT, true);
    PERFORM set_config('app.modulo', 'seguridad.users', true);
    
    -- 3. Buscar usuario activo con todos sus datos
    SELECT 
        u.id, u.name, u.surname, u.email, u.phone, u.login_user, u.avatar,
        u.isactive, u.islogin, u.isreset, u.type_user, u.perfil_id, u.chorario_id,
        u.created_by, u.updated_by, u.created_at, u.updated_at,
        u.last_login_at, u.user_verified_at, u.email_verified_at,
        u.recovery_code, u.recovery_code_expires_at,
        p.nombre as perfil_nombre,
        c.nombre as chorario_nombre
    INTO v_user_data
    FROM seguridad.users u
    LEFT JOIN seguridad.perfiles p ON p.id = u.perfil_id
    LEFT JOIN seguridad.chorarios c ON c.id = u.chorario_id
    WHERE u.login_user = p_login_user AND u.isactive = true;
    
    IF NOT FOUND THEN
        RETURN jsonb_build_object(
            'success', false, 
            'message', 'Usuario no encontrado o inactivo',
            'error_code', 'USUARIO_NO_ENCONTRADO'
        );
    END IF;
    
    -- 4. Obtener datos del perfil
    SELECT id, nombre INTO v_perfil_data
    FROM seguridad.perfiles 
    WHERE id = v_user_data.perfil_id;
    
    -- 5. Obtener datos del horario
    SELECT id, nombre INTO v_chorario_data
    FROM seguridad.chorarios 
    WHERE id = v_user_data.chorario_id;
    
    -- 6. Generar código de 6 dígitos
    v_codigo := LPAD(FLOOR(RANDOM() * 1000000)::TEXT, 6, '0');
    v_expiracion := NOW() + INTERVAL '15 minutes';
    
    -- 7. Construir JSON de datos ANTERIORES
    v_datos_anteriores := jsonb_build_object(
        'id', v_user_data.id,
        'name', v_user_data.name,
        'surname', v_user_data.surname,
        'email', v_user_data.email,
        'phone', v_user_data.phone,
        'login_user', v_user_data.login_user,
        'avatar', v_user_data.avatar,
        'type_user', v_user_data.type_user,
        'isactive', v_user_data.isactive,
        'islogin', v_user_data.islogin,
        'isreset', v_user_data.isreset,
        'perfil', jsonb_build_object(
            'id', v_perfil_data.id,
            'nombre', v_perfil_data.nombre
        ),
        'chorario', jsonb_build_object(
            'id', v_chorario_data.id,
            'nombre', v_chorario_data.nombre
        ),
        'created_by', v_user_data.created_by,
        'created_at', to_char(v_user_data.created_at, 'YYYY-MM-DD HH24:MI:SS'),
        'updated_by', v_user_data.updated_by,
        'updated_at', to_char(v_user_data.updated_at, 'YYYY-MM-DD HH24:MI:SS'),
        'last_login_at', to_char(v_user_data.last_login_at, 'YYYY-MM-DD HH24:MI:SS'),
        'user_verified_at', to_char(v_user_data.user_verified_at, 'YYYY-MM-DD HH24:MI:SS'),
        'email_verified_at', to_char(v_user_data.email_verified_at, 'YYYY-MM-DD HH24:MI:SS'),
        'recovery_code', v_user_data.recovery_code,
        'recovery_code_expires_at', to_char(v_user_data.recovery_code_expires_at, 'YYYY-MM-DD HH24:MI:SS')
    );
    
    -- 8. Guardar datos ANTERIORES en el contexto (ANTES del UPDATE)
    PERFORM set_config('app.datos_anteriores', v_datos_anteriores::TEXT, true);
    
    -- 9. Construir JSON de datos NUEVOS
    v_datos_nuevos := jsonb_build_object(
        'id', v_user_data.id,
        'name', v_user_data.name,
        'surname', v_user_data.surname,
        'email', v_user_data.email,
        'phone', v_user_data.phone,
        'login_user', v_user_data.login_user,
        'avatar', v_user_data.avatar,
        'type_user', v_user_data.type_user,
        'isactive', v_user_data.isactive,
        'islogin', v_user_data.islogin,
        'isreset', false,
        'perfil', jsonb_build_object(
            'id', v_perfil_data.id,
            'nombre', v_perfil_data.nombre
        ),
        'chorario', jsonb_build_object(
            'id', v_chorario_data.id,
            'nombre', v_chorario_data.nombre
        ),
        'created_by', v_user_data.created_by,
        'created_at', to_char(v_user_data.created_at, 'YYYY-MM-DD HH24:MI:SS'),
        'updated_by', v_user_data.login_user,
        'updated_at', v_fecha_texto,
        'last_login_at', to_char(v_user_data.last_login_at, 'YYYY-MM-DD HH24:MI:SS'),
        'user_verified_at', to_char(v_user_data.user_verified_at, 'YYYY-MM-DD HH24:MI:SS'),
        'email_verified_at', to_char(v_user_data.email_verified_at, 'YYYY-MM-DD HH24:MI:SS'),
        'recovery_code', v_codigo,
        'recovery_code_expires_at', to_char(v_expiracion, 'YYYY-MM-DD HH24:MI:SS')
    );
    
    -- 10. Guardar datos NUEVOS en el contexto (ANTES del UPDATE)
    PERFORM set_config('app.datos_nuevos', v_datos_nuevos::TEXT, true);
    
    -- 11. Actualizar campos de recuperación
    UPDATE seguridad.users
    SET 
        recovery_code = v_codigo,
        recovery_code_expires_at = v_expiracion,
        isreset = false,
        updated_at = v_fecha_actual,
        updated_by = v_user_data.login_user
    WHERE id = v_user_data.id;
    
    -- 12. Obtener el usuario actualizado
    SELECT jsonb_build_object(
        'success', true,
        'message', 'Código generado correctamente',
        'data', jsonb_build_object(
            'id', u.id,
            'email', u.email,
            'name', u.name,
            'login_user', u.login_user,
            'codigo', u.recovery_code,
            'expira_en', '15 minutos',
            'recovery_code_expires_at', to_char(u.recovery_code_expires_at, 'YYYY-MM-DD HH24:MI:SS')
        )
    ) INTO v_resultado
    FROM seguridad.users u
    WHERE u.id = v_user_data.id;
    
    RETURN v_resultado;
    
EXCEPTION
    WHEN OTHERS THEN
        -- Limpiar contexto en caso de error
        PERFORM set_config('app.datos_anteriores', '', true);
        PERFORM set_config('app.datos_nuevos', '', true);
        
        RETURN jsonb_build_object(
            'success', false,
            'message', 'Error al generar código: ' || SQLERRM,
            'error_code', SQLSTATE
        );
END;
$BODY$;

ALTER FUNCTION seguridad.fn_usuarios_solicitar_recuperacion(character varying, bigint, character varying, character varying, inet, text, uuid)
    OWNER TO postgres;

