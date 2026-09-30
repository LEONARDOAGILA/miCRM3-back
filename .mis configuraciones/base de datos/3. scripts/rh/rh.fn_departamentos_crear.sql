-- FUNCTION: rh.fn_departamentos_crear(character varying, text, character varying, bigint, character varying, inet, text, uuid)

-- DROP FUNCTION IF EXISTS rh.fn_departamentos_crear(character varying, text, character varying, bigint, character varying, inet, text, uuid);

CREATE OR REPLACE FUNCTION rh.fn_departamentos_crear(
	p_nombre character varying,
	p_descripcion text DEFAULT NULL::text,
	p_codigo character varying DEFAULT NULL::character varying,
	p_empleado_id bigint DEFAULT NULL::bigint,
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
    v_id BIGINT;
    v_resultado JSONB;
    v_usuario_id BIGINT;
BEGIN
    -- Establecer contexto para auditoría
    PERFORM set_config('app.usuario_login', p_usuario_login, true);
    PERFORM set_config('app.ip_address', p_ip_address::TEXT, true);
    PERFORM set_config('app.user_agent', p_user_agent, true);
    PERFORM set_config('app.request_id', p_request_id::TEXT, true);
    PERFORM set_config('app.modulo', 'rh.departamentos', true);
    
    -- Validar que el empleado existe (si se envió)
    IF p_empleado_id IS NOT NULL THEN
        IF NOT EXISTS (SELECT 1 FROM rh.empleados WHERE id = p_empleado_id AND activo = true) THEN
            RETURN jsonb_build_object(
                'success', false,
                'message', 'El empleado seleccionado no existe o no está activo',
                'error_code', 'EMPLEADO_NOT_FOUND'
            );
        END IF;
    END IF;
    
    -- Insertar departamento
    INSERT INTO rh.departamentos (
        nombre, descripcion, codigo, empleado_id, activo
    ) VALUES (
        TRIM(p_nombre), 
        p_descripcion, 
        UPPER(TRIM(p_codigo)), 
        p_empleado_id, 
        true
    ) RETURNING id INTO v_id;
    
    -- Obtener resultado completo
    SELECT jsonb_build_object(
        'success', true,
        'message', 'Departamento creado exitosamente',
        'data', jsonb_build_object(
            'id', d.id,
            'nombre', d.nombre,
            'descripcion', d.descripcion,
            'codigo', d.codigo,
            'empleado_id', d.empleado_id,
            'empleado_nombre', e.nombres || ' ' || e.apellidos,
            'activo', d.activo,
            'created_at', d.created_at
        )
    ) INTO v_resultado
    FROM rh.departamentos d
    LEFT JOIN rh.empleados e ON d.empleado_id = e.id
    WHERE d.id = v_id;
    
    RETURN v_resultado;
    
EXCEPTION
    WHEN unique_violation THEN
        RETURN jsonb_build_object(
            'success', false,
            'message', 'Ya existe un departamento con ese nombre o código',
            'error_code', 'DUPLICATE'
        );
    WHEN OTHERS THEN
        RETURN jsonb_build_object(
            'success', false,
            'message', 'Error al crear departamento: ' || SQLERRM,
            'error_code', SQLSTATE
        );
END;
$BODY$;

ALTER FUNCTION rh.fn_departamentos_crear(character varying, text, character varying, bigint, character varying, inet, text, uuid)
    OWNER TO postgres;

