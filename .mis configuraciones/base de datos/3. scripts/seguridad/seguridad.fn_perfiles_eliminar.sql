-- FUNCTION: seguridad.fn_perfiles_eliminar(bigint, bigint, character varying, character varying, inet, text, uuid)

-- DROP FUNCTION IF EXISTS seguridad.fn_perfiles_eliminar(bigint, bigint, character varying, character varying, inet, text, uuid);

CREATE OR REPLACE FUNCTION seguridad.fn_perfiles_eliminar(
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
    v_datos_anteriores JSONB;
    v_accesos_anteriores JSONB;
    v_perfil_data RECORD;
    v_resultado JSONB;
BEGIN
    -- 1. Establecer contexto de auditoría
    PERFORM set_config('app.usuario_id', COALESCE(p_usuario_id::TEXT, ''), true);
    PERFORM set_config('app.usuario_login', COALESCE(p_usuario_login, current_user), true);
    PERFORM set_config('app.usuario_nombre', COALESCE(p_usuario_nombre, current_user), true);
    PERFORM set_config('app.ip_address', p_ip_address::TEXT, true);
    PERFORM set_config('app.user_agent', p_user_agent, true);
    PERFORM set_config('app.request_id', p_request_id::TEXT, true);
    PERFORM set_config('app.modulo', 'seguridad.perfiles', true);
    
    -- 2. Obtener el perfil antes de eliminarlo (con todas sus columnas)
    SELECT 
        id, nombre, inactividad, activo,
        created_by, updated_by,
        created_at, updated_at
    INTO v_perfil_data
    FROM seguridad.perfiles
    WHERE id = p_id;
    
    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'message', 'El perfil no existe', 'error_code', 'PERFIL_NO_EXISTE');
    END IF;
    
    -- 3. Obtener los accesos actuales con nombre de menú (para auditoría)
    SELECT COALESCE(
        jsonb_agg(
            jsonb_build_object(
                'menu_id', a.menu_id,
                'menu_nombre', m.nombre,
                'permisos', jsonb_build_object(
                    'ver', a.ver,
                    'crear', a.crear,
                    'editar', a.editar,
                    'eliminar', a.eliminar,
                    'listar', a.listar,
                    'reporte', a.reporte,
                    'ejecutar', a.ejecutar,
                    'auditar', a.auditar
                )
            ) ORDER BY a.menu_id
        ),
        '[]'::jsonb
    ) INTO v_accesos_anteriores
    FROM seguridad.accesos a
    JOIN seguridad.menus m ON a.menu_id = m.id
    WHERE a.perfil_id = p_id;
    
    -- 4. Construir JSON de datos ANTERIORES
    v_datos_anteriores := jsonb_build_object(
        'id', v_perfil_data.id,
        'nombre', v_perfil_data.nombre,
        'inactividad', v_perfil_data.inactividad,
        'activo', v_perfil_data.activo,
        'created_by', v_perfil_data.created_by,
        'created_at', to_char(v_perfil_data.created_at, 'YYYY-MM-DD HH24:MI:SS'),
        'updated_by', v_perfil_data.updated_by,
        'updated_at', to_char(v_perfil_data.updated_at, 'YYYY-MM-DD HH24:MI:SS'),
        'acceso', v_accesos_anteriores
    );
    
    -- 5. Guardar datos ANTERIORES en el contexto (ANTES del DELETE)
    PERFORM set_config('app.datos_anteriores', v_datos_anteriores::TEXT, true);
    
    -- 6. Eliminar accesos y perfil
    DELETE FROM seguridad.accesos WHERE perfil_id = p_id;
    DELETE FROM seguridad.perfiles WHERE id = p_id;
    
    -- 7. Devolver respuesta exitosa con los datos eliminados
    RETURN jsonb_build_object(
        'success', true,
        'message', 'Perfil eliminado exitosamente',
        'data', v_datos_anteriores
    );
    
EXCEPTION
    WHEN OTHERS THEN
        -- Limpiar contexto en caso de error
        PERFORM set_config('app.datos_anteriores', '', true);
        
        RETURN jsonb_build_object(
            'success', false,
            'message', 'Error al eliminar perfil: ' || SQLERRM,
            'error_code', SQLSTATE
        );
END;
$BODY$;

ALTER FUNCTION seguridad.fn_perfiles_eliminar(bigint, bigint, character varying, character varying, inet, text, uuid)
    OWNER TO postgres;

