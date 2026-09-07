-- FUNCTION: rh.fn_departamentos_obtener(bigint)

-- DROP FUNCTION IF EXISTS rh.fn_departamentos_obtener(bigint);

CREATE OR REPLACE FUNCTION rh.fn_departamentos_obtener(
	p_id bigint)
    RETURNS jsonb
    LANGUAGE 'plpgsql'
    COST 100
    VOLATILE PARALLEL UNSAFE
AS $BODY$
DECLARE
    v_resultado JSONB;
BEGIN
    SELECT jsonb_build_object(
        'success', true,
        'data', jsonb_build_object(
            'id', d.id,
            'nombre', d.nombre,
            'descripcion', d.descripcion,
            'codigo', d.codigo,
            'empleado_id', d.empleado_id,
            'empleado_nombre', e.nombres || ' ' || e.apellidos,
            'empleado_cargo', c.nombre,
            'activo', d.activo,
            'created_at', d.created_at,
            'updated_at', d.updated_at,
            'created_by', d.created_by,
            'updated_by', d.updated_by
        )
    ) INTO v_resultado
    FROM rh.departamentos d
    LEFT JOIN rh.empleados e ON d.empleado_id = e.id
    LEFT JOIN rh.cargos c ON e.cargo_id = c.id
    WHERE d.id = p_id;
    
    IF v_resultado IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'message', 'Departamento no encontrado',
            'error_code', 'NOT_FOUND'
        );
    END IF;
    
    RETURN v_resultado;
END;
$BODY$;

ALTER FUNCTION rh.fn_departamentos_obtener(bigint)
    OWNER TO postgres;

