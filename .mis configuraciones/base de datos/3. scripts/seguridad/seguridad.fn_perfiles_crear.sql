-- FUNCTION: seguridad.fn_perfiles_crear(character varying, integer, boolean, jsonb, bigint, character varying, character varying, inet, text, uuid)

-- DROP FUNCTION IF EXISTS seguridad.fn_perfiles_crear(character varying, integer, boolean, jsonb, bigint, character varying, character varying, inet, text, uuid);

CREATE OR REPLACE FUNCTION seguridad.fn_perfiles_crear(
	p_nombre character varying,
	p_inactividad integer,
	p_activo boolean,
	p_accesos jsonb,
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
    v_perfil_id BIGINT;
    v_acceso JSONB;
    v_resultado JSONB;
    v_accesos_nuevos JSONB;
    v_fecha_actual TIMESTAMP;
    v_fecha_texto TEXT;
    v_datos_nuevos JSONB;
    v_perfil_creado RECORD;
BEGIN
    -- 1. Obtener fecha actual
    v_fecha_actual := CURRENT_TIMESTAMP;
    v_fecha_texto := to_char(v_fecha_actual, 'YYYY-MM-DD HH24:MI:SS');
    
    -- 2. Establecer contexto de auditoría
    PERFORM set_config('app.usuario_id', COALESCE(p_usuario_id::TEXT, ''), true);
    PERFORM set_config('app.usuario_login', COALESCE(p_usuario_login, current_user), true);
    PERFORM set_config('app.usuario_nombre', COALESCE(p_usuario_nombre, current_user), true);
    PERFORM set_config('app.ip_address', p_ip_address::TEXT, true);
    PERFORM set_config('app.user_agent', p_user_agent, true);
    PERFORM set_config('app.request_id', p_request_id::TEXT, true);
    PERFORM set_config('app.modulo', 'seguridad.perfiles', true);
    
    -- 3. Validaciones
    IF p_nombre IS NULL OR TRIM(p_nombre) = '' THEN
        RETURN jsonb_build_object('success', false, 'message', 'El nombre del perfil es obligatorio', 'error_code', 'NOMBRE_REQUERIDO');
    END IF;
    
    IF p_inactividad IS NULL OR p_inactividad < 0 THEN
        RETURN jsonb_build_object('success', false, 'message', 'La inactividad debe ser un número no negativo', 'error_code', 'INACTIVIDAD_INVALIDA');
    END IF;
    
    IF p_accesos IS NULL OR jsonb_array_length(p_accesos) = 0 THEN
        RETURN jsonb_build_object('success', false, 'message', 'Debe especificar al menos un acceso', 'error_code', 'ACCESOS_VACIOS');
    END IF;
    
    -- 4. Verificar nombre único
    IF EXISTS (SELECT 1 FROM seguridad.perfiles WHERE nombre = TRIM(p_nombre)) THEN
        RETURN jsonb_build_object('success', false, 'message', 'Ya existe un perfil con ese nombre.', 'error_code', 'NOMBRE_DUPLICADO');
    END IF;
    
    -- 5. Verificar que todos los menu_id existan
    FOR v_acceso IN SELECT * FROM jsonb_array_elements(p_accesos) LOOP
        IF NOT EXISTS (SELECT 1 FROM seguridad.menus WHERE id = (v_acceso->>'menu_id')::BIGINT) THEN
            RETURN jsonb_build_object('success', false, 'message', 'El menu_id ' || (v_acceso->>'menu_id') || ' no existe', 'error_code', 'MENU_INEXISTENTE');
        END IF;
    END LOOP;
    
    -- 6. Transformar p_accesos al formato con nombres de menú (para auditoría)
    SELECT jsonb_agg(
        jsonb_build_object(
            'menu_id', (elem->>'menu_id')::BIGINT,
            'menu_nombre', COALESCE(m.nombre, ''),
            'permisos', jsonb_build_object(
                'ver', COALESCE((elem->>'ver')::BOOLEAN, false),
                'crear', COALESCE((elem->>'crear')::BOOLEAN, false),
                'editar', COALESCE((elem->>'editar')::BOOLEAN, false),
                'eliminar', COALESCE((elem->>'eliminar')::BOOLEAN, false),
                'listar', COALESCE((elem->>'listar')::BOOLEAN, false),
                'reporte', COALESCE((elem->>'reporte')::BOOLEAN, false),
                'ejecutar', COALESCE((elem->>'ejecutar')::BOOLEAN, false),
                'auditar', COALESCE((elem->>'auditar')::BOOLEAN, false)
            )
        )
        ORDER BY (elem->>'menu_id')::BIGINT ASC
    ) INTO v_accesos_nuevos
    FROM jsonb_array_elements(p_accesos) AS elem
    LEFT JOIN seguridad.menus m ON m.id = (elem->>'menu_id')::BIGINT;
    
    -- 7. Construir JSON de datos NUEVOS (ANTES del INSERT)
    v_datos_nuevos := jsonb_build_object(
        'nombre', TRIM(p_nombre),
        'inactividad', p_inactividad,
        'activo', p_activo,
        'created_by', p_usuario_login,
        'created_at', v_fecha_texto,
        'updated_by', p_usuario_login,
        'updated_at', v_fecha_texto,
        'acceso', COALESCE(v_accesos_nuevos, '[]'::jsonb)
    );
    
    -- 8. Guardar datos NUEVOS en el contexto (ANTES del INSERT)
    PERFORM set_config('app.datos_nuevos', v_datos_nuevos::TEXT, true);
    
    -- 9. Insertar el perfil
    INSERT INTO seguridad.perfiles (
        nombre, 
        inactividad, 
        activo,
        created_by,
        updated_by,
        created_at,
        updated_at
    ) VALUES (
        TRIM(p_nombre), 
        p_inactividad, 
        p_activo,
        p_usuario_login,
        p_usuario_login,
        v_fecha_actual,
        v_fecha_actual
    )
    RETURNING 
        id, nombre, inactividad, activo,
        created_by, updated_by,
        created_at, updated_at
    INTO v_perfil_creado;
    
    -- 10. Obtener el ID del perfil creado
    v_perfil_id := v_perfil_creado.id;
    
    -- 11. Insertar los accesos
    FOR v_acceso IN SELECT * FROM jsonb_array_elements(p_accesos) LOOP
        INSERT INTO seguridad.accesos (
            perfil_id, menu_id, ver, crear, editar, eliminar, listar, reporte, auditar, ejecutar
        ) VALUES (
            v_perfil_id,
            (v_acceso->>'menu_id')::BIGINT,
            COALESCE((v_acceso->>'ver')::BOOLEAN, false),
            COALESCE((v_acceso->>'crear')::BOOLEAN, false),
            COALESCE((v_acceso->>'editar')::BOOLEAN, false),
            COALESCE((v_acceso->>'eliminar')::BOOLEAN, false),
            COALESCE((v_acceso->>'listar')::BOOLEAN, false),
            COALESCE((v_acceso->>'reporte')::BOOLEAN, false),
            COALESCE((v_acceso->>'auditar')::BOOLEAN, false),
            COALESCE((v_acceso->>'ejecutar')::BOOLEAN, false)
        );
    END LOOP;
    
    -- 12. Devolver el perfil recién creado con sus accesos
    SELECT jsonb_build_object(
        'success', true,
        'message', 'Perfil creado exitosamente',
        'data', jsonb_build_object(
            'id', perf.id,
            'nombre', perf.nombre,
            'inactividad', perf.inactividad,
            'activo', perf.activo,
            'created_by', perf.created_by,
            'updated_by', perf.updated_by, 
            'created_at', to_char(perf.created_at, 'YYYY-MM-DD HH24:MI:SS'),
            'updated_at', to_char(perf.updated_at, 'YYYY-MM-DD HH24:MI:SS'),
            'acceso', COALESCE((
                SELECT jsonb_agg(
                    jsonb_build_object(
                        'id', a.id,
                        'perfil_id', a.perfil_id,
                        'menu_id', a.menu_id,
                        'ver', a.ver,
                        'crear', a.crear,
                        'editar', a.editar,
                        'eliminar', a.eliminar,
                        'listar', a.listar,
                        'reporte', a.reporte,
                        'ejecutar', a.ejecutar,
                        'auditar', a.auditar,
                        'menu', jsonb_build_object(
                            'id', m.id,
                            'padre_id', m.padre_id,
                            'orden', m.orden,
                            'nivel', m.nivel,
                            'nombre', m.nombre,
                            'url', m.url,
                            'descripcion', m.descripcion,
                            'etiqueta', m.etiqueta,
                            'icono', m.icono
                        )
                    )
                    ORDER BY m.orden ASC, m.id ASC
                )
                FROM seguridad.accesos a
                JOIN seguridad.menus m ON a.menu_id = m.id
                WHERE a.perfil_id = perf.id
            ), '[]'::jsonb)
        )
    ) INTO v_resultado
    FROM seguridad.perfiles perf
    WHERE perf.id = v_perfil_id;
    
    RETURN v_resultado;
    
EXCEPTION
    WHEN OTHERS THEN
        -- Limpiar contexto en caso de error
        PERFORM set_config('app.datos_nuevos', '', true);
        
        RETURN jsonb_build_object(
            'success', false,
            'message', 'Error al crear perfil: ' || SQLERRM,
            'error_code', SQLSTATE
        );
END;
$BODY$;

ALTER FUNCTION seguridad.fn_perfiles_crear(character varying, integer, boolean, jsonb, bigint, character varying, character varying, inet, text, uuid)
    OWNER TO postgres;

