-- FUNCTION: seguridad.fn_usuarios_obtener(bigint)

-- DROP FUNCTION IF EXISTS seguridad.fn_usuarios_obtener(bigint);

CREATE OR REPLACE FUNCTION seguridad.fn_usuarios_obtener(
	p_id bigint)
    RETURNS jsonb
    LANGUAGE 'plpgsql'
    COST 100
    VOLATILE SECURITY DEFINER PARALLEL UNSAFE
AS $BODY$
DECLARE
    v_data JSONB;
    v_resultado JSONB;
BEGIN
    -- Consulta el usuario con su perfil asociado
    SELECT jsonb_build_object(
        'id', u.id,
        'name', u.name,
        'surname', u.surname,
        'email', u.email,
        'phone', u.phone,
        'login_user', u.login_user,
        'avatar', u.avatar,
        'type_user', u.type_user,
        'isactive', u.isactive,
		'isreset', u.isreset,
        'islogin', u.islogin,
        'perfil_id', u.perfil_id,
        'perfil_nombre', p.nombre,
        'chorario_id', u.chorario_id,
		'chorario_nombre', h.nombre,
        'created_by', u.created_by,
        'updated_by', u.updated_by,
        'created_at', to_char(u.created_at, 'YYYY-MM-DD HH24:MI:SS'),
        'updated_at', to_char(u.updated_at, 'YYYY-MM-DD HH24:MI:SS'),
        'email_verified_at', to_char(u.email_verified_at, 'YYYY-MM-DD HH24:MI:SS'),
        'user_verified_at', to_char(u.user_verified_at, 'YYYY-MM-DD HH24:MI:SS'),
        'last_login_at', to_char(u.last_login_at, 'YYYY-MM-DD HH24:MI:SS')
    ) INTO v_data
    FROM seguridad.users u
    LEFT JOIN seguridad.perfiles p ON p.id = u.perfil_id
	LEFT JOIN seguridad.chorarios h ON h.id = u.chorario_id
    WHERE u.id = p_id;
    
    -- Verifica si se encontró el usuario
    IF v_data IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'message', 'Usuario no encontrado',
            'error_code', 'USER_NOT_FOUND',
            'data', null
        );
    END IF;
    
    -- Construye respuesta exitosa
    v_resultado := jsonb_build_object(
        'success', true,
        'message', 'Usuario obtenido exitosamente',
        'data', v_data
    );
    
    RETURN v_resultado;
    
EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object(
            'success', false,
            'message', 'Error al obtener usuario: ' || SQLERRM,
            'error_code', SQLSTATE
        );
END;
$BODY$;

ALTER FUNCTION seguridad.fn_usuarios_obtener(bigint)
    OWNER TO postgres;

