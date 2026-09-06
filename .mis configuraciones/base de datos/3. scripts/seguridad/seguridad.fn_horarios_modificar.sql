-- FUNCTION: seguridad.fn_horarios_modificar(bigint, character varying, boolean, jsonb, bigint, character varying, character varying, inet, text, uuid)

-- DROP FUNCTION IF EXISTS seguridad.fn_horarios_modificar(bigint, character varying, boolean, jsonb, bigint, character varying, character varying, inet, text, uuid);

CREATE OR REPLACE FUNCTION seguridad.fn_horarios_modificar(
	p_id bigint,
	p_nombre character varying,
	p_activo boolean DEFAULT true,
	p_dhorario jsonb DEFAULT NULL::jsonb,
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
    v_horario_existe BOOLEAN;
    v_dhorario_item JSONB;
    v_dhorario_viejos JSONB;
    v_resultado JSONB;
BEGIN
    -- Establecer contexto de auditoría
    PERFORM set_config('app.usuario_id', COALESCE(p_usuario_id::TEXT, ''), true);
    PERFORM set_config('app.usuario_login', COALESCE(p_usuario_login, current_user), true);
    PERFORM set_config('app.usuario_nombre', COALESCE(p_usuario_nombre, current_user), true);
    PERFORM set_config('app.ip_address', p_ip_address::TEXT, true);
    PERFORM set_config('app.user_agent', p_user_agent, true);
    PERFORM set_config('app.request_id', p_request_id::TEXT, true);
    PERFORM set_config('app.modulo', 'seguridad.chorarios', true);
    
    -- Validar que el horario existe
    SELECT EXISTS(SELECT 1 FROM seguridad.chorarios WHERE id = p_id) INTO v_horario_existe;
    IF NOT v_horario_existe THEN
        RETURN jsonb_build_object('success', false, 'message', 'El horario no existe', 'error_code', 'HORARIO_NO_EXISTE');
    END IF;
    
    -- Validaciones
    IF p_nombre IS NULL OR TRIM(p_nombre) = '' THEN
        RETURN jsonb_build_object('success', false, 'message', 'El nombre del horario es obligatorio', 'error_code', 'NOMBRE_REQUERIDO');
    END IF;
    
    -- Verificar nombre único (excluyendo el propio horario)
    IF EXISTS (SELECT 1 FROM seguridad.chorarios WHERE nombre = TRIM(p_nombre) AND id != p_id) THEN
        RETURN jsonb_build_object('success', false, 'message', 'Ya existe otro horario con ese nombre', 'error_code', 'NOMBRE_DUPLICADO');
    END IF;
    
    -- Obtener los dhorarios VIEJOS antes de actualizar (para auditoría)
    SELECT COALESCE(
        jsonb_agg(
            jsonb_build_object(
                'id', d.id,
                'dia', d.dia,
                'hora_inicio', d.hora_inicio,
                'hora_fin', d.hora_fin,
                'activo', d.activo
            )
            ORDER BY d.dia
        ), '[]'::jsonb
    ) INTO v_dhorario_viejos
    FROM seguridad.dhorarios d
    WHERE d.chorario_id = p_id;
    
    -- PASAR EL DHORARIO AL CONTEXTO PARA EL TRIGGER
    IF p_dhorario IS NOT NULL THEN
        PERFORM set_config('app.dhorario_nuevos', p_dhorario::TEXT, true);
    END IF;
    
    -- PASAR LOS DHORARIOS VIEJOS AL CONTEXTO PARA EL TRIGGER
    PERFORM set_config('app.dhorario_viejos', v_dhorario_viejos::TEXT, true);
    
    -- Actualizar cabecera
    UPDATE seguridad.chorarios
    SET nombre = TRIM(p_nombre),
        activo = COALESCE(p_activo, activo)
    WHERE id = p_id;
    
    -- Reemplazar dhorario (borrar viejos e insertar nuevos)
    DELETE FROM seguridad.dhorarios WHERE chorario_id = p_id;
    
    IF p_dhorario IS NOT NULL AND jsonb_array_length(p_dhorario) > 0 THEN
        FOR v_dhorario_item IN SELECT * FROM jsonb_array_elements(p_dhorario) LOOP
            INSERT INTO seguridad.dhorarios (
                chorario_id, dia, hora_inicio, hora_fin, activo
            ) VALUES (
                p_id,
                (v_dhorario_item->>'dia')::INTEGER,
                (v_dhorario_item->>'hora_inicio')::INTERVAL,
                (v_dhorario_item->>'hora_fin')::INTERVAL,
                COALESCE((v_dhorario_item->>'activo')::BOOLEAN, true)
            );
        END LOOP;
    END IF;
    
    -- Obtener el horario completo actualizado
    SELECT jsonb_build_object(
        'success', true,
        'message', 'Horario actualizado exitosamente',
        'data', jsonb_build_object(
            'id', c.id,
            'nombre', c.nombre,
            'activo', c.activo,
            'created_at', to_char(c.created_at, 'YYYY-MM-DD HH24:MI:SS'),
            'updated_at', to_char(c.updated_at, 'YYYY-MM-DD HH24:MI:SS'),
            'dhorario', COALESCE((
                SELECT jsonb_agg(
                    jsonb_build_object(
                        'id', d.id,
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
                )
                FROM seguridad.dhorarios d
                WHERE d.chorario_id = c.id
            ), '[]'::jsonb)
        )
    ) INTO v_resultado
    FROM seguridad.chorarios c
    WHERE c.id = p_id;
    
    RETURN v_resultado;
    
EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object(
            'success', false,
            'message', 'Error al actualizar horario: ' || SQLERRM,
            'error_code', SQLSTATE
        );
END;
$BODY$;

ALTER FUNCTION seguridad.fn_horarios_modificar(bigint, character varying, boolean, jsonb, bigint, character varying, character varying, inet, text, uuid)
    OWNER TO postgres;

