-- FUNCTION: seguridad.fn_perfiles_modificar(bigint, character varying, integer, boolean, jsonb, bigint, character varying, character varying, inet, text, uuid)

-- DROP FUNCTION IF EXISTS seguridad.fn_perfiles_modificar(bigint, character varying, integer, boolean, jsonb, bigint, character varying, character varying, inet, text, uuid);

CREATE OR REPLACE FUNCTION seguridad.fn_perfiles_modificar(
	p_id bigint,
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
    v_acceso JSONB;
    v_perfil_existente RECORD;
    v_accesos_anteriores JSONB;
    v_accesos_nuevos JSONB;
    v_item RECORD;
    v_datos_anteriores JSONB;
    v_datos_nuevos JSONB;
    v_perfil_actual RECORD;
    v_fecha_actual TIMESTAMP;
    v_fecha_texto TEXT;
    v_perfil_data RECORD;
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
    
    -- 3. Obtener datos ACTUALES del perfil (antes de modificar)
    SELECT 
        id, nombre, inactividad, activo, 
        created_by, updated_by,
        created_at, updated_at
    INTO v_perfil_data
    FROM seguridad.perfiles 
    WHERE id = p_id;
    
    IF NOT FOUND THEN
        RAISE EXCEPTION 'El perfil no existe' USING ERRCODE = 'P0001';
    END IF;
    
    -- 4. Obtener los accesos ACTUALES (con nombre del menú)
    WITH permisos_por_menu AS (
        SELECT jsonb_agg(
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
            )
            ORDER BY a.menu_id ASC
        ) AS permisos_json
        FROM seguridad.accesos a
        JOIN seguridad.perfiles p ON p.id = a.perfil_id
        JOIN seguridad.menus m ON a.menu_id = m.id
        WHERE a.perfil_id = p_id
    )
    SELECT COALESCE(permisos_json, '[]'::jsonb) 
    INTO v_accesos_anteriores
    FROM permisos_por_menu;
    
    -- 5. Construir JSON de datos ANTERIORES
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
    
    -- 6. Guardar datos ANTERIORES en el contexto
    PERFORM set_config('app.datos_anteriores', v_datos_anteriores::TEXT, true);
    
    -- 7. Validaciones
    IF p_nombre IS NULL OR TRIM(p_nombre) = '' THEN
        RAISE EXCEPTION 'El nombre del perfil es obligatorio' USING ERRCODE = 'P0002';
    END IF;
    
    IF p_inactividad IS NULL OR p_inactividad < 0 THEN
        RAISE EXCEPTION 'La inactividad debe ser un número no negativo' USING ERRCODE = 'P0003';
    END IF;
    
    -- 8. Verificar nombre único (excluyendo el perfil actual)
    IF EXISTS (SELECT 1 FROM seguridad.perfiles WHERE nombre = TRIM(p_nombre) AND id != p_id) THEN
        RAISE EXCEPTION 'Ya existe otro perfil con ese nombre' USING ERRCODE = 'P0004';
    END IF;
    
    -- 9. Verificar que todos los menu_id existan
    IF p_accesos IS NOT NULL AND jsonb_array_length(p_accesos) > 0 THEN
        FOR v_item IN SELECT * FROM jsonb_array_elements(p_accesos) LOOP
            IF NOT EXISTS (SELECT 1 FROM seguridad.menus WHERE id = (v_item.value->>'menu_id')::BIGINT) THEN
                RAISE EXCEPTION 'El menu_id % no existe', (v_item.value->>'menu_id') USING ERRCODE = 'P0005';
            END IF;
        END LOOP;
    END IF;
    
    -- 10. Transformar p_accesos al formato con nombres de menú (datos NUEVOS)
    IF p_accesos IS NOT NULL AND jsonb_array_length(p_accesos) > 0 THEN
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
    ELSE
        v_accesos_nuevos := '[]'::jsonb;
    END IF;
    
    -- 11. Construir JSON de datos NUEVOS
    v_datos_nuevos := jsonb_build_object(
        'id', p_id,
        'nombre', TRIM(p_nombre),
        'inactividad', p_inactividad,
        'activo', p_activo,
        'created_by', v_perfil_data.created_by,
        'created_at', to_char(v_perfil_data.created_at, 'YYYY-MM-DD HH24:MI:SS'),
        'updated_by', COALESCE(p_usuario_login, v_perfil_data.updated_by),
        'updated_at', v_fecha_texto,
        'acceso', v_accesos_nuevos
    );
    
    -- 12. Guardar datos NUEVOS en el contexto
    PERFORM set_config('app.datos_nuevos', v_datos_nuevos::TEXT, true);
    
    -- 13. Actualizar el perfil
    UPDATE seguridad.perfiles 
    SET 
        nombre = TRIM(p_nombre),
        inactividad = p_inactividad,
        activo = p_activo,
        updated_by = COALESCE(p_usuario_login, v_perfil_data.updated_by),
        updated_at = v_fecha_actual
    WHERE id = p_id
    RETURNING 
        id, nombre, inactividad, activo, 
        created_by, updated_by,
        created_at, updated_at
    INTO v_perfil_actual;
    
    -- 14. Actualizar accesos (borrar y crear nuevos)
    IF p_accesos IS NOT NULL THEN
        -- Eliminar accesos existentes
        DELETE FROM seguridad.accesos WHERE perfil_id = p_id;
        
        -- Insertar nuevos accesos
        FOR v_item IN SELECT * FROM jsonb_array_elements(p_accesos) LOOP
            INSERT INTO seguridad.accesos (
                perfil_id, menu_id, ver, crear, editar, eliminar, listar, reporte, auditar, ejecutar
            ) VALUES (
                p_id,
                (v_item.value->>'menu_id')::BIGINT,
                COALESCE((v_item.value->>'ver')::BOOLEAN, false),
                COALESCE((v_item.value->>'crear')::BOOLEAN, false),
                COALESCE((v_item.value->>'editar')::BOOLEAN, false),
                COALESCE((v_item.value->>'eliminar')::BOOLEAN, false),
                COALESCE((v_item.value->>'listar')::BOOLEAN, false),
                COALESCE((v_item.value->>'reporte')::BOOLEAN, false),
                COALESCE((v_item.value->>'auditar')::BOOLEAN, false),
                COALESCE((v_item.value->>'ejecutar')::BOOLEAN, false)
            );
        END LOOP;
    END IF;
    
    -- 15. Devolver el perfil actualizado
    RETURN jsonb_build_object(
        'success', true,
        'message', 'Perfil actualizado exitosamente',
        'data', jsonb_build_object(
            'id', v_perfil_actual.id,
            'nombre', v_perfil_actual.nombre,
            'inactividad', v_perfil_actual.inactividad,
            'activo', v_perfil_actual.activo,
            'created_by', v_perfil_actual.created_by,
            'updated_by', v_perfil_actual.updated_by, 
            'created_at', to_char(v_perfil_actual.created_at, 'YYYY-MM-DD HH24:MI:SS'),
            'updated_at', to_char(v_perfil_actual.updated_at, 'YYYY-MM-DD HH24:MI:SS'),
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
                WHERE a.perfil_id = v_perfil_actual.id
            ), '[]'::jsonb)
        )
    );

EXCEPTION
    WHEN OTHERS THEN
        -- Limpiar contexto en caso de error
        PERFORM set_config('app.datos_anteriores', '', true);
        PERFORM set_config('app.datos_nuevos', '', true);
        PERFORM set_config('app.usuario_id', '', true);
        PERFORM set_config('app.usuario_login', '', true);
        PERFORM set_config('app.usuario_nombre', '', true);
        PERFORM set_config('app.ip_address', '', true);
        PERFORM set_config('app.user_agent', '', true);
        PERFORM set_config('app.request_id', '', true);
        PERFORM set_config('app.modulo', '', true);
        
        RETURN jsonb_build_object(
            'success', false,
            'message', 'Error al actualizar perfil: ' || SQLERRM,
            'error_code', SQLSTATE
        );
END;
$BODY$;

ALTER FUNCTION seguridad.fn_perfiles_modificar(bigint, character varying, integer, boolean, jsonb, bigint, character varying, character varying, inet, text, uuid)
    OWNER TO postgres;

