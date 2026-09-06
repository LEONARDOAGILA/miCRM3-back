-- FUNCTION: seguridad.fn_usuarios_eliminar(bigint, bigint, character varying, character varying, inet, text, uuid)

-- DROP FUNCTION IF EXISTS seguridad.fn_usuarios_eliminar(bigint, bigint, character varying, character varying, inet, text, uuid);

CREATE OR REPLACE FUNCTION seguridad.fn_usuarios_eliminar(
	p_id bigint,
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
    v_datos_anteriores JSONB;
    v_usuario_data RECORD;
    v_perfil_data RECORD;
    v_chorario_data RECORD;
    v_resultado JSONB;
BEGIN
    -- 1. Establecer contexto de auditoría
    PERFORM set_config('app.usuario_id', COALESCE(p_usuario_id::TEXT, ''), true);
    PERFORM set_config('app.usuario_login', COALESCE(p_usuario_login, current_user), true);
    PERFORM set_config('app.usuario_nombre', COALESCE(p_usuario_nombre, current_user), true);
    PERFORM set_config('app.ip_address', p_ip_address::TEXT, true);
    PERFORM set_config('app.user_agent', p_user_agent, true);
    PERFORM set_config('app.request_id', p_request_id::TEXT, true);
    PERFORM set_config('app.modulo', 'seguridad.users', true);
    
    -- 2. Obtener datos del usuario antes de eliminar (con perfil y horario)
    SELECT 
        u.id, u.name, u.surname, u.email, u.phone, u.login_user, u.avatar,
        u.isactive, u.islogin, u.isreset, u.type_user, u.perfil_id, u.chorario_id,
        u.created_by, u.updated_by, u.created_at, u.updated_at,
        u.last_login_at, u.user_verified_at, u.email_verified_at,
        u.recovery_code, u.recovery_code_expires_at,
        p.nombre as perfil_nombre,
        c.nombre as chorario_nombre
    INTO v_usuario_data
    FROM seguridad.users u
    LEFT JOIN seguridad.perfiles p ON p.id = u.perfil_id
    LEFT JOIN seguridad.chorarios c ON c.id = u.chorario_id
    WHERE u.id = p_id;
    
    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'message', 'El usuario no existe', 'error_code', 'USUARIO_NO_EXISTE');
    END IF;
    
    -- 3. Obtener datos del perfil
    SELECT id, nombre INTO v_perfil_data
    FROM seguridad.perfiles 
    WHERE id = v_usuario_data.perfil_id;
    
    -- 4. Obtener datos del horario
    SELECT id, nombre INTO v_chorario_data
    FROM seguridad.chorarios 
    WHERE id = v_usuario_data.chorario_id;
    
    -- 5. Construir JSON de datos ANTERIORES
    v_datos_anteriores := jsonb_build_object(
        'id', v_usuario_data.id,
        'name', v_usuario_data.name,
        'surname', v_usuario_data.surname,
        'email', v_usuario_data.email,
        'phone', v_usuario_data.phone,
        'login_user', v_usuario_data.login_user,
        'avatar', v_usuario_data.avatar,
        'type_user', v_usuario_data.type_user,
        'isactive', v_usuario_data.isactive,
        'islogin', v_usuario_data.islogin,
        'isreset', v_usuario_data.isreset,
        'perfil', jsonb_build_object(
            'id', v_perfil_data.id,
            'nombre', v_perfil_data.nombre
        ),
        'chorario', jsonb_build_object(
            'id', v_chorario_data.id,
            'nombre', v_chorario_data.nombre
        ),
        'created_by', v_usuario_data.created_by,
        'created_at', to_char(v_usuario_data.created_at, 'YYYY-MM-DD HH24:MI:SS'),
        'updated_by', v_usuario_data.updated_by,
        'updated_at', to_char(v_usuario_data.updated_at, 'YYYY-MM-DD HH24:MI:SS'),
        'last_login_at', to_char(v_usuario_data.last_login_at, 'YYYY-MM-DD HH24:MI:SS'),
        'user_verified_at', to_char(v_usuario_data.user_verified_at, 'YYYY-MM-DD HH24:MI:SS'),
        'email_verified_at', to_char(v_usuario_data.email_verified_at, 'YYYY-MM-DD HH24:MI:SS'),
        'recovery_code', v_usuario_data.recovery_code,
        'recovery_code_expires_at', to_char(v_usuario_data.recovery_code_expires_at, 'YYYY-MM-DD HH24:MI:SS')
    );
    
    -- 6. Guardar datos ANTERIORES en el contexto (ANTES del DELETE)
    PERFORM set_config('app.datos_anteriores', v_datos_anteriores::TEXT, true);
    
    -- 7. Eliminar el usuario
    DELETE FROM seguridad.users WHERE id = p_id;
    
    -- 8. Devolver respuesta exitosa con los datos eliminados
    RETURN jsonb_build_object(
        'success', true,
        'message', 'Usuario eliminado exitosamente',
        'data', v_datos_anteriores
    );
    
EXCEPTION
    WHEN OTHERS THEN
        -- Limpiar contexto en caso de error
        PERFORM set_config('app.datos_anteriores', '', true);
        
        RETURN jsonb_build_object(
            'success', false,
            'message', 'Error al eliminar usuario: ' || SQLERRM,
            'error_code', SQLSTATE
        );
END;
$BODY$;

ALTER FUNCTION seguridad.fn_usuarios_eliminar(bigint, bigint, character varying, character varying, inet, text, uuid)
    OWNER TO postgres;

