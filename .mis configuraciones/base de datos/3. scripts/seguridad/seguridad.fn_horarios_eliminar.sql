-- FUNCTION: seguridad.fn_horarios_eliminar(bigint, bigint, character varying, character varying, inet, text, uuid)

-- DROP FUNCTION IF EXISTS seguridad.fn_horarios_eliminar(bigint, bigint, character varying, character varying, inet, text, uuid);

CREATE OR REPLACE FUNCTION seguridad.fn_horarios_eliminar(
	p_id bigint,
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
    v_tiene_usuarios BOOLEAN;
    v_dhorario_viejos JSONB;
    v_datos_anteriores JSONB;
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
    
    -- Verificar si el horario tiene usuarios asociados
    SELECT EXISTS(SELECT 1 FROM seguridad.users WHERE chorario_id = p_id) INTO v_tiene_usuarios;
    IF v_tiene_usuarios THEN
        RETURN jsonb_build_object('success', false, 'message', 'No se puede eliminar este horario porque tiene usuarios asociados.', 'error_code', 'TIENE_USUARIOS');
    END IF;
    
    -- Obtener los dhorarios viejos (para auditoría)
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
    
    -- PASAR LOS DHORARIOS VIEJOS AL CONTEXTO PARA EL TRIGGER
    PERFORM set_config('app.dhorario_viejos', v_dhorario_viejos::TEXT, true);
    
    -- Obtener datos del horario antes de eliminar (incluyendo dhorario)
    SELECT jsonb_build_object(
        'id', c.id,
        'nombre', c.nombre,
        'activo', c.activo,
        'dhorario', v_dhorario_viejos
    ) INTO v_datos_anteriores
    FROM seguridad.chorarios c
    WHERE c.id = p_id;
    
    -- Eliminar detalle y cabecera
    DELETE FROM seguridad.dhorarios WHERE chorario_id = p_id;
    DELETE FROM seguridad.chorarios WHERE id = p_id;
    
    RETURN jsonb_build_object(
        'success', true,
        'message', 'Horario eliminado exitosamente',
        'data', v_datos_anteriores
    );
    
EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object(
            'success', false,
            'message', 'Error al eliminar horario: ' || SQLERRM,
            'error_code', SQLSTATE
        );
END;
$BODY$;

ALTER FUNCTION seguridad.fn_horarios_eliminar(bigint, bigint, character varying, character varying, inet, text, uuid)
    OWNER TO postgres;

