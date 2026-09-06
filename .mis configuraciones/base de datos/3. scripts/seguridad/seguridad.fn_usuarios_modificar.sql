-- FUNCTION: seguridad.fn_usuarios_modificar(bigint, character varying, character varying, character varying, character varying, character varying, character varying, boolean, integer, integer, integer, bigint, character varying, character varying, inet, text, uuid)

-- DROP FUNCTION IF EXISTS seguridad.fn_usuarios_modificar(bigint, character varying, character varying, character varying, character varying, character varying, character varying, boolean, integer, integer, integer, bigint, character varying, character varying, inet, text, uuid);

CREATE OR REPLACE FUNCTION seguridad.fn_usuarios_modificar(
	p_id bigint,
	p_name character varying,
	p_surname character varying,
	p_email character varying,
	p_phone character varying DEFAULT NULL::character varying,
	p_login_user character varying DEFAULT NULL::character varying,
	p_avatar character varying DEFAULT NULL::character varying,
	p_isactive boolean DEFAULT true,
	p_type_user integer DEFAULT NULL::integer,
	p_perfil_id integer DEFAULT NULL::integer,
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
    v_resultado JSONB;
    v_datos_anteriores JSONB;
    v_datos_nuevos JSONB;
    v_usuario_actual RECORD;
    v_perfil_data RECORD;
    v_chorario_data RECORD;
    v_fecha_actual TIMESTAMP;
    v_perfil_nuevo_id INTEGER;
    v_chorario_nuevo_id INTEGER;
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
    
    -- 4. Validaciones
    IF p_name IS NULL OR TRIM(p_name) = '' THEN
        RETURN jsonb_build_object('success', false, 'message', 'El nombre es obligatorio', 'error_code', 'NOMBRE_REQUERIDO');
    END IF;
    
    IF p_surname IS NULL OR TRIM(p_surname) = '' THEN
        RETURN jsonb_build_object('success', false, 'message', 'El apellido es obligatorio', 'error_code', 'APELLIDO_REQUERIDO');
    END IF;
    
    IF p_login_user IS NULL OR TRIM(p_login_user) = '' THEN
        RETURN jsonb_build_object('success', false, 'message', 'El login de usuario es obligatorio', 'error_code', 'LOGIN_REQUERIDO');
    END IF;
    
    IF p_email IS NULL OR TRIM(p_email) = '' THEN
        RETURN jsonb_build_object('success', false, 'message', 'El email es obligatorio', 'error_code', 'EMAIL_REQUERIDO');
    END IF;
    
    -- 5. Verificar login único (excluyendo el propio usuario)
    IF EXISTS (SELECT 1 FROM seguridad.users WHERE login_user = TRIM(p_login_user) AND id != p_id) THEN
        RETURN jsonb_build_object('success', false, 'message', 'Ya existe otro usuario con ese login', 'error_code', 'LOGIN_DUPLICADO');
    END IF;
    
    -- 6. Verificar email único (excluyendo el propio usuario)
    IF EXISTS (SELECT 1 FROM seguridad.users WHERE email = TRIM(p_email) AND id != p_id) THEN
        RETURN jsonb_build_object('success', false, 'message', 'Ya existe otro usuario con ese email', 'error_code', 'EMAIL_DUPLICADO');
    END IF;
    
    -- 7. Determinar IDs nuevos
    v_perfil_nuevo_id := COALESCE(p_perfil_id, v_usuario_actual.perfil_id);
    v_chorario_nuevo_id := COALESCE(p_chorario_id, v_usuario_actual.chorario_id);
    
    -- 8. Verificar que el perfil existe (si se cambió)
    IF p_perfil_id IS NOT NULL THEN
        IF NOT EXISTS (SELECT 1 FROM seguridad.perfiles WHERE id = p_perfil_id) THEN
            RETURN jsonb_build_object('success', false, 'message', 'El perfil no existe', 'error_code', 'PERFIL_NO_EXISTE');
        END IF;
        SELECT id, nombre INTO v_perfil_data FROM seguridad.perfiles WHERE id = p_perfil_id;
    ELSE
        SELECT id, nombre INTO v_perfil_data FROM seguridad.perfiles WHERE id = v_perfil_nuevo_id;
    END IF;
    
    -- 9. Verificar que el horario existe (si se cambió)
    IF p_chorario_id IS NOT NULL THEN
        IF NOT EXISTS (SELECT 1 FROM seguridad.chorarios WHERE id = p_chorario_id) THEN
            RETURN jsonb_build_object('success', false, 'message', 'El horario no existe', 'error_code', 'CHORARIO_NO_EXISTE');
        END IF;
        SELECT id, nombre INTO v_chorario_data FROM seguridad.chorarios WHERE id = p_chorario_id;
    ELSE
        SELECT id, nombre INTO v_chorario_data FROM seguridad.chorarios WHERE id = v_chorario_nuevo_id;
    END IF;
    
    -- 10. Construir JSON de datos ANTERIORES (con estructura anidada)
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
    
    -- 11. Guardar datos ANTERIORES en el contexto (ANTES del UPDATE)
    PERFORM set_config('app.datos_anteriores', v_datos_anteriores::TEXT, true);
    
    -- 12. Construir JSON de datos NUEVOS (con estructura anidada)
    v_datos_nuevos := jsonb_build_object(
        'id', p_id,
        'name', TRIM(p_name),
        'surname', TRIM(p_surname),
        'email', TRIM(p_email),
        'phone', p_phone,
        'login_user', TRIM(p_login_user),
        'avatar', p_avatar,
        'type_user', COALESCE(p_type_user, v_usuario_actual.type_user),
        'isactive', p_isactive,
        'islogin', v_usuario_actual.islogin,
        'isreset', v_usuario_actual.isreset,
        'perfil', jsonb_build_object(
            'id', v_perfil_data.id,
            'nombre', v_perfil_data.nombre
        ),
        'chorario', jsonb_build_object(
            'id', v_chorario_data.id,
            'nombre', v_chorario_data.nombre
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
    
    -- 13. Guardar datos NUEVOS en el contexto (ANTES del UPDATE)
    PERFORM set_config('app.datos_nuevos', v_datos_nuevos::TEXT, true);
    
    -- 14. Actualizar usuario
    UPDATE seguridad.users
    SET 
        name = TRIM(p_name),
        surname = TRIM(p_surname),
        email = TRIM(p_email),
        phone = p_phone,
        login_user = TRIM(p_login_user),
        avatar = p_avatar,
        isactive = p_isactive,
        type_user = COALESCE(p_type_user, v_usuario_actual.type_user),
        perfil_id = v_perfil_nuevo_id,
        chorario_id = v_chorario_nuevo_id,
        updated_at = v_fecha_actual,
        updated_by = COALESCE(p_usuario_login, v_usuario_actual.updated_by)
    WHERE id = p_id;
    
    -- 15. Obtener el usuario actualizado
    SELECT jsonb_build_object(
        'success', true,
        'message', 'Usuario actualizado exitosamente',
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
            'message', 'Error al actualizar usuario: ' || SQLERRM,
            'error_code', SQLSTATE
        );
END;
$BODY$;

ALTER FUNCTION seguridad.fn_usuarios_modificar(bigint, character varying, character varying, character varying, character varying, character varying, character varying, boolean, integer, integer, integer, bigint, character varying, character varying, inet, text, uuid)
    OWNER TO postgres;

