-- FUNCTION: seguridad.fn_usuarios_imagen(bigint, character varying, bigint, character varying, character varying, inet, text, uuid)

-- DROP FUNCTION IF EXISTS seguridad.fn_usuarios_imagen(bigint, character varying, bigint, character varying, character varying, inet, text, uuid);

CREATE OR REPLACE FUNCTION seguridad.fn_usuarios_imagen(
	p_id bigint,
	p_avatar character varying,
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
    v_resultado JSONB;
    v_datos_anteriores JSONB;
    v_datos_nuevos JSONB;
    v_usuario_actual RECORD;
    v_perfil_data RECORD;
    v_chorario_data RECORD;
    v_fecha_actual TIMESTAMP;
    v_fecha_texto TEXT;
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
    
    -- 3. Obtener datos ACTUALES del usuario (antes de modificar)
    SELECT 
        u.id, u.name, u.surname, u.email, u.phone, u.login_user, u.avatar,
        u.isactive, u.islogin, u.isreset, u.type_user, u.perfil_id, u.chorario_id,
        u.created_by, u.updated_by, u.created_at, u.updated_at,
        u.last_login_at, u.user_verified_at, u.email_verified_at,
        u.recovery_code, u.recovery_code_expires_at,
        p.nombre as perfil_nombre,
        c.nombre as chorario_nombre
    INTO v_usuario_actual
    FROM seguridad.users u
    LEFT JOIN seguridad.perfiles p ON p.id = u.perfil_id
    LEFT JOIN seguridad.chorarios c ON c.id = u.chorario_id
    WHERE u.id = p_id;
    
    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'message', 'El usuario no existe', 'error_code', 'USUARIO_NO_EXISTE');
    END IF;
    
    -- 4. Construir JSON de datos ANTERIORES
    v_datos_anteriores := jsonb_build_object(
        'id', v_usuario_actual.id,
        'name', v_usuario_actual.name,
        'surname', v_usuario_actual.surname,
        'email', v_usuario_actual.email,
        'phone', v_usuario_actual.phone,
        'login_user', v_usuario_actual.login_user,
        'avatar', v_usuario_actual.avatar,
        'type_user', v_usuario_actual.type_user,
        'isactive', v_usuario_actual.isactive,
        'islogin', v_usuario_actual.islogin,
        'isreset', v_usuario_actual.isreset,
        'perfil', jsonb_build_object(
            'id', v_usuario_actual.perfil_id,
            'nombre', v_usuario_actual.perfil_nombre
        ),
        'chorario', jsonb_build_object(
            'id', v_usuario_actual.chorario_id,
            'nombre', v_usuario_actual.chorario_nombre
        ),
        'created_by', v_usuario_actual.created_by,
        'created_at', to_char(v_usuario_actual.created_at, 'YYYY-MM-DD HH24:MI:SS'),
        'updated_by', v_usuario_actual.updated_by,
        'updated_at', to_char(v_usuario_actual.updated_at, 'YYYY-MM-DD HH24:MI:SS'),
        'last_login_at', to_char(v_usuario_actual.last_login_at, 'YYYY-MM-DD HH24:MI:SS'),
        'user_verified_at', to_char(v_usuario_actual.user_verified_at, 'YYYY-MM-DD HH24:MI:SS'),
        'email_verified_at', to_char(v_usuario_actual.email_verified_at, 'YYYY-MM-DD HH24:MI:SS'),
        'recovery_code', v_usuario_actual.recovery_code,
        'recovery_code_expires_at', to_char(v_usuario_actual.recovery_code_expires_at, 'YYYY-MM-DD HH24:MI:SS')
    );
    
    -- 5. Guardar datos ANTERIORES en el contexto (ANTES del UPDATE)
    PERFORM set_config('app.datos_anteriores', v_datos_anteriores::TEXT, true);
    
    -- 6. Construir JSON de datos NUEVOS (solo cambia el avatar)
    v_datos_nuevos := jsonb_build_object(
        'id', p_id,
        'name', v_usuario_actual.name,
        'surname', v_usuario_actual.surname,
        'email', v_usuario_actual.email,
        'phone', v_usuario_actual.phone,
        'login_user', v_usuario_actual.login_user,
        'avatar', p_avatar,
        'type_user', v_usuario_actual.type_user,
        'isactive', v_usuario_actual.isactive,
        'islogin', v_usuario_actual.islogin,
        'isreset', v_usuario_actual.isreset,
        'perfil', jsonb_build_object(
            'id', v_usuario_actual.perfil_id,
            'nombre', v_usuario_actual.perfil_nombre
        ),
        'chorario', jsonb_build_object(
            'id', v_usuario_actual.chorario_id,
            'nombre', v_usuario_actual.chorario_nombre
        ),
        'created_by', v_usuario_actual.created_by,
        'created_at', to_char(v_usuario_actual.created_at, 'YYYY-MM-DD HH24:MI:SS'),
        'updated_by', COALESCE(p_usuario_login, v_usuario_actual.updated_by),
        'updated_at', v_fecha_texto,
        'last_login_at', to_char(v_usuario_actual.last_login_at, 'YYYY-MM-DD HH24:MI:SS'),
        'user_verified_at', to_char(v_usuario_actual.user_verified_at, 'YYYY-MM-DD HH24:MI:SS'),
        'email_verified_at', to_char(v_usuario_actual.email_verified_at, 'YYYY-MM-DD HH24:MI:SS'),
        'recovery_code', v_usuario_actual.recovery_code,
        'recovery_code_expires_at', to_char(v_usuario_actual.recovery_code_expires_at, 'YYYY-MM-DD HH24:MI:SS')
    );
    
    -- 7. Guardar datos NUEVOS en el contexto (ANTES del UPDATE)
    PERFORM set_config('app.datos_nuevos', v_datos_nuevos::TEXT, true);
    
    -- 8. Actualizar el avatar
    UPDATE seguridad.users
    SET 
        avatar = p_avatar,
        updated_at = v_fecha_actual,
        updated_by = COALESCE(p_usuario_login, v_usuario_actual.updated_by)
    WHERE id = p_id;
    
    -- 9. Obtener el usuario actualizado
    SELECT jsonb_build_object(
        'success', true,
        'message', 'Imagen actualizada exitosamente',
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
    WHERE u.id = p_id;
    
    RETURN v_resultado;
    
EXCEPTION
    WHEN OTHERS THEN
        -- Limpiar contexto en caso de error
        PERFORM set_config('app.datos_anteriores', '', true);
        PERFORM set_config('app.datos_nuevos', '', true);
        
        RETURN jsonb_build_object(
            'success', false,
            'message', 'Error al actualizar imagen: ' || SQLERRM,
            'error_code', SQLSTATE
        );
END;
$BODY$;

ALTER FUNCTION seguridad.fn_usuarios_imagen(bigint, character varying, bigint, character varying, character varying, inet, text, uuid)
    OWNER TO postgres;

