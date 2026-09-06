-- FUNCTION: seguridad.fn_horarios_obtener(bigint)

-- DROP FUNCTION IF EXISTS seguridad.fn_horarios_obtener(bigint);

CREATE OR REPLACE FUNCTION seguridad.fn_horarios_obtener(
	p_id bigint)
    RETURNS jsonb
    LANGUAGE 'plpgsql'
    COST 100
    VOLATILE SECURITY DEFINER PARALLEL UNSAFE
AS $BODY$
DECLARE
    v_data JSONB;
    v_dhorario JSONB;
    v_resultado JSONB;
BEGIN
    -- Obtener la cabecera del horario
    SELECT jsonb_build_object(
        'id', c.id,
        'nombre', c.nombre,
        'activo', c.activo,
        'created_at', to_char(c.created_at, 'YYYY-MM-DD HH24:MI:SS'),
        'updated_at', to_char(c.updated_at, 'YYYY-MM-DD HH24:MI:SS'),
        'created_by', c.created_by,
        'updated_by', c.updated_by
    ) INTO v_data
    FROM seguridad.chorarios c
    WHERE c.id = p_id;
    
    IF v_data IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'message', 'Horario no encontrado',
            'error_code', 'HORARIO_NO_ENCONTRADO',
            'data', null
        );
    END IF;
    
    -- Obtener el dhorario (días y horarios)
    SELECT COALESCE(
        jsonb_agg(
            jsonb_build_object(
                'id', d.id,
                'chorario_id', d.chorario_id,
                'dia', d.dia,
                'dia_nombre', CASE d.dia
                    WHEN 1 THEN 'Lunes'
                    WHEN 2 THEN 'Martes'
                    WHEN 3 THEN 'Miércoles'
                    WHEN 4 THEN 'Jueves'
                    WHEN 5 THEN 'Viernes'
                    WHEN 6 THEN 'Sábado'
                    WHEN 7 THEN 'Domingo'
                END,
                'hora_inicio', d.hora_inicio,
                'hora_fin', d.hora_fin,
                'activo', d.activo
            )
            ORDER BY d.dia
        ), '[]'::jsonb
    ) INTO v_dhorario
    FROM seguridad.dhorarios d
    WHERE d.chorario_id = p_id;
    
    -- Agregar el dhorario al objeto principal
    v_data := v_data || jsonb_build_object('dhorario', v_dhorario);
    
    v_resultado := jsonb_build_object(
        'success', true,
        'message', 'Horario obtenido exitosamente',
        'data', v_data
    );
    
    RETURN v_resultado;
    
EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object(
            'success', false,
            'message', 'Error al obtener horario: ' || SQLERRM,
            'error_code', SQLSTATE
        );
END;
$BODY$;

ALTER FUNCTION seguridad.fn_horarios_obtener(bigint)
    OWNER TO postgres;

