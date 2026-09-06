-- FUNCTION: seguridad.fn_menus_crear(character varying, character varying, character varying, character varying, character varying, integer, bigint, bigint, character varying, character varying, inet, text, uuid)

-- DROP FUNCTION IF EXISTS seguridad.fn_menus_crear(character varying, character varying, character varying, character varying, character varying, integer, bigint, bigint, character varying, character varying, inet, text, uuid);

CREATE OR REPLACE FUNCTION seguridad.fn_menus_crear(
	p_nombre character varying,
	p_url character varying DEFAULT NULL::character varying,
	p_descripcion character varying DEFAULT NULL::character varying,
	p_etiqueta character varying DEFAULT NULL::character varying,
	p_icono character varying DEFAULT NULL::character varying,
	p_orden integer DEFAULT 0,
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
    v_menu_id BIGINT;
    v_nivel INTEGER;
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
    
    -- 2. Validaciones
    IF p_nombre IS NULL OR TRIM(p_nombre) = '' THEN
        RETURN jsonb_build_object('success', false, 'message', 'El nombre del menú es obligatorio', 'error_code', 'NOMBRE_REQUERIDO');
    END IF;
    
    -- 3. Verificar nombre único
    IF EXISTS (SELECT 1 FROM seguridad.menus WHERE nombre = TRIM(p_nombre)) THEN
        RETURN jsonb_build_object('success', false, 'message', 'Ya existe un menú con ese nombre', 'error_code', 'NOMBRE_DUPLICADO');
    END IF;
    
    -- 4. Verificar que el padre existe (si se proporcionó)
    IF p_padre_id IS NOT NULL THEN
        IF NOT EXISTS (SELECT 1 FROM seguridad.menus WHERE id = p_padre_id) THEN
            RETURN jsonb_build_object('success', false, 'message', 'El menú padre no existe', 'error_code', 'PADRE_NO_EXISTE');
        END IF;
        
        -- Calcular el nivel del menú (nivel del padre + 1)
        SELECT COALESCE(nivel, 0) + 1 INTO v_nivel
        FROM seguridad.menus WHERE id = p_padre_id;
    ELSE
        v_nivel := 0;
    END IF;
    
    -- 5. Insertar el menú
    INSERT INTO seguridad.menus (
        nombre, url, descripcion, etiqueta, icono, 
        orden, padre_id, nivel
    ) VALUES (
        TRIM(p_nombre), 
        p_url, 
        p_descripcion, 
        p_etiqueta, 
        p_icono, 
        COALESCE(p_orden, 0), 
        p_padre_id, 
        v_nivel
    )
    RETURNING id INTO v_menu_id;
    
    -- 6. Obtener el menú recién creado
    SELECT jsonb_build_object(
        'success', true,
        'message', 'Menú creado exitosamente',
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
    WHERE m.id = v_menu_id;
    
    RETURN v_resultado;
    
EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object(
            'success', false,
            'message', 'Error al crear menú: ' || SQLERRM,
            'error_code', SQLSTATE
        );
END;
$BODY$;

ALTER FUNCTION seguridad.fn_menus_crear(character varying, character varying, character varying, character varying, character varying, integer, bigint, bigint, character varying, character varying, inet, text, uuid)
    OWNER TO postgres;

