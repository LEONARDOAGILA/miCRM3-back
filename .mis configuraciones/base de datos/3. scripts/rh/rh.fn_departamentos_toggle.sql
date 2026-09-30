-- FUNCTION: rh.fn_departamentos_toggle(bigint, character varying, inet, text, uuid)

-- DROP FUNCTION IF EXISTS rh.fn_departamentos_toggle(bigint, character varying, inet, text, uuid);

CREATE OR REPLACE FUNCTION rh.fn_departamentos_toggle(
	p_id bigint,
	p_usuario_login character varying DEFAULT NULL::character varying,
	p_ip_address inet DEFAULT NULL::inet,
	p_user_agent text DEFAULT NULL::text,
	p_request_id uuid DEFAULT NULL::uuid)
    RETURNS jsonb
    LANGUAGE 'plpgsql'
    COST 100
    VOLATILE PARALLEL UNSAFE
AS $BODY$
DECLARE
    v_departamento RECORD;
BEGIN
    -- Establecer contexto para auditoría
    PERFORM set_config('app.usuario_login', p_usuario_login, true);
    PERFORM set_config('app.ip_address', p_ip_address::TEXT, true);
    PERFORM set_config('app.user_agent', p_user_agent, true);
    PERFORM set_config('app.request_id', p_request_id::TEXT, true);
    PERFORM set_config('app.modulo', 'rh.departamentos', true);
    
    -- Verificar existencia
    SELECT * INTO v_departamento 
    FROM rh.departamentos 
    WHERE id = p_id;
    
    IF NOT FOUND THEN
        RETURN jsonb_build_object(
            'success', false,
            'message', 'Departamento no encontrado',
            'error_code', 'NOT_FOUND'
        );
    END IF;
    
    -- Cambiar estado
    UPDATE rh.departamentos SET
        activo = NOT activo
    WHERE id = p_id;
    
    RETURN jsonb_build_object(
        'success', true,
        'message', CASE 
            WHEN v_departamento.activo THEN 'Departamento desactivado exitosamente'
            ELSE 'Departamento activado exitosamente'
        END,
        'data', jsonb_build_object(
            'id', p_id,
            'nombre', v_departamento.nombre,
            'activo', NOT v_departamento.activo
        )
    );
    
EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object(
            'success', false,
            'message', 'Error al cambiar estado: ' || SQLERRM,
            'error_code', SQLSTATE
        );
END;
$BODY$;

ALTER FUNCTION rh.fn_departamentos_toggle(bigint, character varying, inet, text, uuid)
    OWNER TO postgres;

