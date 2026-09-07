-- FUNCTION: rh.fn_departamentos_actualizar(bigint, character varying, text, character varying, bigint, boolean, character varying, inet, text, uuid)

-- DROP FUNCTION IF EXISTS rh.fn_departamentos_actualizar(bigint, character varying, text, character varying, bigint, boolean, character varying, inet, text, uuid);

CREATE OR REPLACE FUNCTION rh.fn_departamentos_actualizar(
	p_id bigint,
	p_nombre character varying DEFAULT NULL::character varying,
	p_descripcion text DEFAULT NULL::text,
	p_codigo character varying DEFAULT NULL::character varying,
	p_empleado_id bigint DEFAULT NULL::bigint,
	p_activo boolean DEFAULT NULL::boolean,
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
    v_resultado JSONB;
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
    
    -- Validar empleado si se envió
    IF p_empleado_id IS NOT NULL THEN
        IF NOT EXISTS (SELECT 1 FROM rh.empleados WHERE id = p_empleado_id AND activo = true) THEN
            RETURN jsonb_build_object(
                'success', false,
                'message', 'El empleado seleccionado no existe o no está activo',
                'error_code', 'EMPLEADO_NOT_FOUND'
            );
        END IF;
    END IF;
    
    -- Actualizar
    UPDATE rh.departamentos SET
        nombre = COALESCE(TRIM(p_nombre), nombre),
        descripcion = COALESCE(p_descripcion, descripcion),
        codigo = COALESCE(UPPER(TRIM(p_codigo)), codigo),
        empleado_id = COALESCE(p_empleado_id, empleado_id),
        activo = COALESCE(p_activo, activo)
    WHERE id = p_id;
    
    -- Obtener resultado
    SELECT jsonb_build_object(
        'success', true,
        'message', 'Departamento actualizado exitosamente',
        'data', jsonb_build_object(
            'id', d.id,
            'nombre', d.nombre,
            'descripcion', d.descripcion,
            'codigo', d.codigo,
            'empleado_id', d.empleado_id,
            'empleado_nombre', e.nombres || ' ' || e.apellidos,
            'activo', d.activo,
            'created_at', d.created_at,
            'updated_at', d.updated_at
        )
    ) INTO v_resultado
    FROM rh.departamentos d
    LEFT JOIN rh.empleados e ON d.empleado_id = e.id
    WHERE d.id = p_id;
    
    RETURN v_resultado;
    
EXCEPTION
    WHEN unique_violation THEN
        RETURN jsonb_build_object(
            'success', false,
            'message', 'Ya existe otro departamento con ese nombre o código',
            'error_code', 'DUPLICATE'
        );
    WHEN OTHERS THEN
        RETURN jsonb_build_object(
            'success', false,
            'message', 'Error al actualizar: ' || SQLERRM,
            'error_code', SQLSTATE
        );
END;
$BODY$;

ALTER FUNCTION rh.fn_departamentos_actualizar(bigint, character varying, text, character varying, bigint, boolean, character varying, inet, text, uuid)
    OWNER TO postgres;

