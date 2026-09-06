-- FUNCTION: seguridad.fn_menus_modificar(bigint, character varying, character varying, character varying, character varying, character varying, integer, bigint, bigint, character varying, character varying, inet, text, uuid)

-- DROP FUNCTION IF EXISTS seguridad.fn_menus_modificar(bigint, character varying, character varying, character varying, character varying, character varying, integer, bigint, bigint, character varying, character varying, inet, text, uuid);

CREATE OR REPLACE FUNCTION seguridad.fn_menus_modificar(
	p_id bigint,
	p_nombre character varying,
	p_url character varying DEFAULT NULL::character varying,
	p_descripcion character varying DEFAULT NULL::character varying,
	p_etiqueta character varying DEFAULT NULL::character varying,
	p_icono character varying DEFAULT NULL::character varying,
	p_orden integer DEFAULT NULL::integer,
	p_padre_id bigint DEFAULT NULL::bigint,
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
    v_padre_existe BOOLEAN;
    v_nivel INTEGER;
    v_padre_nivel INTEGER;
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
    
    -- 2. Validar que el menú existe
    SELECT EXISTS(SELECT 1 FROM seguridad.menus WHERE id = p_id) INTO v_menu_existe;
    IF NOT v_menu_existe THEN
        RETURN jsonb_build_object('success', false, 'message', 'El menú no existe', 'error_code', 'MENU_NO_EXISTE');
    END IF;
    
    -- 3. Validaciones básicas
    IF p_nombre IS NULL OR TRIM(p_nombre) = '' THEN
        RETURN jsonb_build_object('success', false, 'message', 'El nombre del menú es obligatorio', 'error_code', 'NOMBRE_REQUERIDO');
    END IF;
    
    -- 4. Verificar nombre único (excluyendo el propio menú)
    IF EXISTS (SELECT 1 FROM seguridad.menus WHERE nombre = TRIM(p_nombre) AND id != p_id) THEN
        RETURN jsonb_build_object('success', false, 'message', 'Ya existe otro menú con ese nombre', 'error_code', 'NOMBRE_DUPLICADO');
    END IF;
    
    -- 5. Validar que el padre existe (si se proporcionó y no es el mismo menú)
    IF p_padre_id IS NOT NULL THEN
        IF p_padre_id = p_id THEN
            RETURN jsonb_build_object('success', false, 'message', 'Un menú no puede ser padre de sí mismo', 'error_code', 'AUTOREFERENCIA');
        END IF;
        
        SELECT EXISTS(SELECT 1 FROM seguridad.menus WHERE id = p_padre_id) INTO v_padre_existe;
        IF NOT v_padre_existe THEN
            RETURN jsonb_build_object('success', false, 'message', 'El menú padre no existe', 'error_code', 'PADRE_NO_EXISTE');
        END IF;
        
        -- Calcular el nivel del padre
        SELECT nivel INTO v_padre_nivel FROM seguridad.menus WHERE id = p_padre_id;
        v_nivel := v_padre_nivel + 1;
    ELSE
        v_nivel := 0;
    END IF;
    
    -- 6. Actualizar el menú
    UPDATE seguridad.menus
    SET 
        nombre = TRIM(p_nombre),
        url = p_url,
        descripcion = p_descripcion,
        etiqueta = p_etiqueta,
        icono = p_icono,
        orden = COALESCE(p_orden, orden),
        padre_id = p_padre_id,
        nivel = v_nivel,
        updated_at = CURRENT_TIMESTAMP
    WHERE id = p_id;
    
    -- 7. Devolver el menú actualizado
    SELECT jsonb_build_object(
        'success', true,
        'message', 'Menú actualizado exitosamente',
        'data', jsonb_build_object(
            'id', m.id,
            'nombre', m.nombre,
            'url', m.url,
            'descripcion', m.descripcion,
            'etiqueta', m.etiqueta,
            'icono', m.icono,
            'orden', m.orden,
            'padre_id', m.padre_id,
            'nivel', m.nivel,
            'created_at', to_char(m.created_at, 'YYYY-MM-DD HH24:MI:SS'),
            'updated_at', to_char(m.updated_at, 'YYYY-MM-DD HH24:MI:SS'),
            'created_by', m.created_by,
            'updated_by', m.updated_by
        )
    ) INTO v_resultado
    FROM seguridad.menus m
    WHERE m.id = p_id;
    
    RETURN v_resultado;
    
EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object(
            'success', false,
            'message', 'Error al actualizar menú: ' || SQLERRM,
            'error_code', SQLSTATE
        );
END;
$BODY$;

ALTER FUNCTION seguridad.fn_menus_modificar(bigint, character varying, character varying, character varying, character varying, character varying, integer, bigint, bigint, character varying, character varying, inet, text, uuid)
    OWNER TO postgres;

