-- FUNCTION: seguridad.fn_menus_eliminar(bigint, bigint, character varying, character varying, inet, text, uuid)

-- DROP FUNCTION IF EXISTS seguridad.fn_menus_eliminar(bigint, bigint, character varying, character varying, inet, text, uuid);

CREATE OR REPLACE FUNCTION seguridad.fn_menus_eliminar(
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
    v_menu_existe BOOLEAN;
    v_tiene_hijos BOOLEAN;
    v_menu RECORD;
    v_resultado JSONB;
BEGIN
    -- 1. Establecer contexto de auditoría
    PERFORM set_config('app.usuario_id', COALESCE(p_usuario_id::TEXT, ''), true);
    PERFORM set_config('app.usuario_login', COALESCE(p_usuario_login, current_user), true);
    PERFORM set_config('app.usuario_nombre', COALESCE(p_usuario_nombre, current_user), true);
    PERFORM set_config('app.ip_address', p_ip_address::TEXT, true);
    PERFORM set_config('app.user_agent', p_user_agent, true);
    PERFORM set_config('app.request_id', p_request_id::TEXT, true);
    PERFORM set_config('app.modulo', 'seguridad.menus', true);
    
    -- 2. Validar que el menú existe y obtener sus datos
    SELECT id, nombre, padre_id, orden, nivel, url, descripcion, etiqueta, icono INTO v_menu
    FROM seguridad.menus WHERE id = p_id;
    
    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'message', 'El menú no existe', 'error_code', 'MENU_NO_EXISTE');
    END IF;
    
    -- 3. Verificar si el menú tiene hijos
    SELECT EXISTS(SELECT 1 FROM seguridad.menus WHERE padre_id = p_id) INTO v_tiene_hijos;
    IF v_tiene_hijos THEN
        RETURN jsonb_build_object('success', false, 'message', 'No se puede eliminar este menú porque tiene hijos.', 'error_code', 'TIENE_HIJOS');
    END IF;
    
    -- 4. Eliminar accesos asociados al menú
    DELETE FROM seguridad.accesos WHERE menu_id = p_id;
    
    -- 5. Eliminar el menú
    DELETE FROM seguridad.menus WHERE id = p_id;
    
    -- 6. Devolver respuesta exitosa con los datos eliminados
    RETURN jsonb_build_object(
        'success', true,
        'message', 'Menú eliminado exitosamente',
        'data', jsonb_build_object(
            'id', v_menu.id,
            'nombre', v_menu.nombre,
            'url', v_menu.url,
            'descripcion', v_menu.descripcion,
            'etiqueta', v_menu.etiqueta,
            'icono', v_menu.icono,
            'orden', v_menu.orden,
            'padre_id', v_menu.padre_id,
            'nivel', v_menu.nivel
        )
    );
    
EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object(
            'success', false,
            'message', 'Error al eliminar menú: ' || SQLERRM,
            'error_code', SQLSTATE
        );
END;
$BODY$;

ALTER FUNCTION seguridad.fn_menus_eliminar(bigint, bigint, character varying, character varying, inet, text, uuid)
    OWNER TO postgres;

