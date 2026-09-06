-- FUNCTION: seguridad.fn_usuarios_verificar_recuperacion(character varying, character varying)

-- DROP FUNCTION IF EXISTS seguridad.fn_usuarios_verificar_recuperacion(character varying, character varying);

CREATE OR REPLACE FUNCTION seguridad.fn_usuarios_verificar_recuperacion(
	p_login_user character varying,
	p_codigo character varying)
    RETURNS jsonb
    LANGUAGE 'plpgsql'
    COST 100
    VOLATILE SECURITY DEFINER PARALLEL UNSAFE
AS $BODY$
DECLARE
    v_user_record RECORD;
BEGIN
    -- Buscar usuario con código válido
    SELECT id, login_user, email, name, recovery_code, recovery_code_expires_at
    INTO v_user_record
    FROM seguridad.users 
    WHERE login_user = p_login_user 
      AND isactive = true
      AND recovery_code IS NOT NULL
      AND recovery_code_expires_at > NOW();
    
    IF NOT FOUND THEN
        RETURN jsonb_build_object(
            'success', false, 
            'message', 'Código inválido o expirado',
            'error_code', 'CODIGO_INVALIDO'
        );
    END IF;
    
    -- Verificar código
    IF v_user_record.recovery_code != p_codigo THEN
        RETURN jsonb_build_object(
            'success', false, 
            'message', 'Código incorrecto',
            'error_code', 'CODIGO_INCORRECTO'
        );
    END IF;
    
    -- Código válido, retornar datos
    RETURN jsonb_build_object(
        'success', true,
        'message', 'Código verificado correctamente',
        'data', jsonb_build_object(
            'id', v_user_record.id,
            'email', v_user_record.email,
            'name', v_user_record.name,
            'login_user', v_user_record.login_user
        )
    );
    
EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object(
            'success', false,
            'message', 'Error al verificar código: ' || SQLERRM,
            'error_code', SQLSTATE
        );
END;
$BODY$;

ALTER FUNCTION seguridad.fn_usuarios_verificar_recuperacion(character varying, character varying)
    OWNER TO postgres;

