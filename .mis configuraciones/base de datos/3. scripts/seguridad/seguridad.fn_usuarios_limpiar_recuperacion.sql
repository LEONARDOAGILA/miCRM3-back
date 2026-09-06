-- FUNCTION: seguridad.fn_usuarios_limpiar_recuperacion(bigint)

-- DROP FUNCTION IF EXISTS seguridad.fn_usuarios_limpiar_recuperacion(bigint);

CREATE OR REPLACE FUNCTION seguridad.fn_usuarios_limpiar_recuperacion(
	p_user_id bigint)
    RETURNS jsonb
    LANGUAGE 'plpgsql'
    COST 100
    VOLATILE SECURITY DEFINER PARALLEL UNSAFE
AS $BODY$
BEGIN
    UPDATE seguridad.users
    SET 
        recovery_code = NULL,
        recovery_code_expires_at = NULL,
        updated_at = CURRENT_TIMESTAMP
    WHERE id = p_user_id;
    
    RETURN jsonb_build_object(
        'success', true,
        'message', 'Código de recuperación limpiado'
    );
    
EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object(
            'success', false,
            'message', 'Error al limpiar código: ' || SQLERRM,
            'error_code', SQLSTATE
        );
END;
$BODY$;

ALTER FUNCTION seguridad.fn_usuarios_limpiar_recuperacion(bigint)
    OWNER TO postgres;

