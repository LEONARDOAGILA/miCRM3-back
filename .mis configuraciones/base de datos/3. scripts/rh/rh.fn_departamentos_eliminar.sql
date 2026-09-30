-- FUNCTION: rh.fn_departamentos_eliminar(bigint, character varying, inet, text, uuid, boolean)

-- DROP FUNCTION IF EXISTS rh.fn_departamentos_eliminar(bigint, character varying, inet, text, uuid, boolean);

CREATE OR REPLACE FUNCTION rh.fn_departamentos_eliminar(
	p_id bigint,
	p_usuario_login character varying DEFAULT NULL::character varying,
	p_ip_address inet DEFAULT NULL::inet,
	p_user_agent text DEFAULT NULL::text,
	p_request_id uuid DEFAULT NULL::uuid,
	p_fisico boolean DEFAULT false)
    RETURNS jsonb
    LANGUAGE 'plpgsql'
    COST 100
    VOLATILE PARALLEL UNSAFE
AS $BODY$
DECLARE
    v_departamento RECORD;
    v_empleados_count BIGINT;
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
    
    -- Verificar dependencias (empleados)
    SELECT COUNT(*) INTO v_empleados_count 
    FROM rh.empleados 
    WHERE departamento_id = p_id;
    
    IF v_empleados_count > 0 THEN
        RETURN jsonb_build_object(
            'success', false,
            'message', 'No se puede eliminar el departamento porque tiene ' || v_empleados_count || ' empleados asociados',
            'error_code', 'HAS_EMPLOYEES',
            'empleados_count', v_empleados_count
        );
    END IF;
    
    IF p_fisico THEN
        -- Eliminación física
        DELETE FROM rh.departamentos WHERE id = p_id;
        
        RETURN jsonb_build_object(
            'success', true,
            'message', 'Departamento eliminado físicamente',
            'data', jsonb_build_object(
                'id', p_id,
                'nombre', v_departamento.nombre,
                'deleted_at', CURRENT_TIMESTAMP
            )
        );
    ELSE
        -- Soft delete: desactivar
        UPDATE rh.departamentos SET
            activo = false
        WHERE id = p_id;
        
        RETURN jsonb_build_object(
            'success', true,
            'message', 'Departamento desactivado exitosamente',
            'data', jsonb_build_object(
                'id', p_id,
                'nombre', v_departamento.nombre,
                'activo', false
            )
        );
    END IF;
    
EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object(
            'success', false,
            'message', 'Error al eliminar: ' || SQLERRM,
            'error_code', SQLSTATE
        );
END;
$BODY$;

ALTER FUNCTION rh.fn_departamentos_eliminar(bigint, character varying, inet, text, uuid, boolean)
    OWNER TO postgres;

