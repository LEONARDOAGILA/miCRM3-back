-- ============================================
-- FUNCIÓN: rh.fn_departamento_crear
-- ============================================
CREATE OR REPLACE FUNCTION rh.fn_departamento_crear(
    p_nombre VARCHAR,
    p_descripcion TEXT DEFAULT NULL,
    p_codigo VARCHAR DEFAULT NULL,
    p_empleado_id BIGINT DEFAULT NULL,
    p_usuario_login VARCHAR DEFAULT NULL,
    p_ip_address INET DEFAULT NULL,
    p_user_agent TEXT DEFAULT NULL,
    p_request_id UUID DEFAULT NULL
)
RETURNS JSONB AS $$
DECLARE
    v_id BIGINT;
    v_resultado JSONB;
    v_usuario_id BIGINT;
BEGIN
    -- Establecer contexto para auditoría
    PERFORM set_config('app.usuario_login', p_usuario_login, true);
    PERFORM set_config('app.ip_address', p_ip_address::TEXT, true);
    PERFORM set_config('app.user_agent', p_user_agent, true);
    PERFORM set_config('app.request_id', p_request_id::TEXT, true);
    PERFORM set_config('app.modulo', 'rh.departamentos', true);
    
    -- Validar que el empleado existe (si se envió)
    IF p_empleado_id IS NOT NULL THEN
        IF NOT EXISTS (SELECT 1 FROM rh.empleados WHERE id = p_empleado_id AND activo = true) THEN
            RETURN jsonb_build_object(
                'success', false,
                'message', 'El empleado seleccionado no existe o no está activo',
                'error_code', 'EMPLEADO_NOT_FOUND'
            );
        END IF;
    END IF;
    
    -- Insertar departamento
    INSERT INTO rh.departamentos (
        nombre, descripcion, codigo, empleado_id, activo
    ) VALUES (
        TRIM(p_nombre), 
        p_descripcion, 
        UPPER(TRIM(p_codigo)), 
        p_empleado_id, 
        true
    ) RETURNING id INTO v_id;
    
    -- Obtener resultado completo
    SELECT jsonb_build_object(
        'success', true,
        'message', 'Departamento creado exitosamente',
        'data', jsonb_build_object(
            'id', d.id,
            'nombre', d.nombre,
            'descripcion', d.descripcion,
            'codigo', d.codigo,
            'empleado_id', d.empleado_id,
            'empleado_nombre', e.nombres || ' ' || e.apellidos,
            'activo', d.activo,
            'created_at', d.created_at
        )
    ) INTO v_resultado
    FROM rh.departamentos d
    LEFT JOIN rh.empleados e ON d.empleado_id = e.id
    WHERE d.id = v_id;
    
    RETURN v_resultado;
    
EXCEPTION
    WHEN unique_violation THEN
        RETURN jsonb_build_object(
            'success', false,
            'message', 'Ya existe un departamento con ese nombre o código',
            'error_code', 'DUPLICATE'
        );
    WHEN OTHERS THEN
        RETURN jsonb_build_object(
            'success', false,
            'message', 'Error al crear departamento: ' || SQLERRM,
            'error_code', SQLSTATE
        );
END;
$$ LANGUAGE plpgsql;




-- ============================================
-- FUNCIÓN: rh.fn_departamento_modificar
-- ============================================
CREATE OR REPLACE FUNCTION rh.fn_departamento_modificar(
    p_id BIGINT,
    p_nombre VARCHAR DEFAULT NULL,
    p_descripcion TEXT DEFAULT NULL,
    p_codigo VARCHAR DEFAULT NULL,
    p_empleado_id BIGINT DEFAULT NULL,
    p_activo BOOLEAN DEFAULT NULL,
    p_usuario_login VARCHAR DEFAULT NULL,
    p_ip_address INET DEFAULT NULL,
    p_user_agent TEXT DEFAULT NULL,
    p_request_id UUID DEFAULT NULL
)
RETURNS JSONB AS $$
DECLARE
    v_departamento RECORD;
    v_resultado JSONB;
BEGIN
    -- Establecer contexto para auditoría
    PERFORM set_config('app.usuario_login', p_usuario_login, true);
    PERFORM set_config('app.ip_address', p_ip_address::TEXT, true);
    PERFORM set_config('app.user_agent', p_user_agent, true);
    PERFORM set_config('app.request_id', p_request_id::TEXT, true);
    PERFORM set_config('app.modulo', 'rh.departamentos', true);
    
    -- Verificar existencia
    SELECT * INTO v_departamento 
    FROM rh.departamentos 
    WHERE id = p_id;
    
    IF NOT FOUND THEN
        RETURN jsonb_build_object(
            'success', false,
            'message', 'Departamento no encontrado',
            'error_code', 'NOT_FOUND'
        );
    END IF;
    
    -- Validar empleado si se envió
    IF p_empleado_id IS NOT NULL THEN
        IF NOT EXISTS (SELECT 1 FROM rh.empleados WHERE id = p_empleado_id AND activo = true) THEN
            RETURN jsonb_build_object(
                'success', false,
                'message', 'El empleado seleccionado no existe o no está activo',
                'error_code', 'EMPLEADO_NOT_FOUND'
            );
        END IF;
    END IF;
    
    -- Actualizar
    UPDATE rh.departamentos SET
        nombre = COALESCE(TRIM(p_nombre), nombre),
        descripcion = COALESCE(p_descripcion, descripcion),
        codigo = COALESCE(UPPER(TRIM(p_codigo)), codigo),
        empleado_id = COALESCE(p_empleado_id, empleado_id),
        activo = COALESCE(p_activo, activo)
    WHERE id = p_id;
    
    -- Obtener resultado
    SELECT jsonb_build_object(
        'success', true,
        'message', 'Departamento actualizado exitosamente',
        'data', jsonb_build_object(
            'id', d.id,
            'nombre', d.nombre,
            'descripcion', d.descripcion,
            'codigo', d.codigo,
            'empleado_id', d.empleado_id,
            'empleado_nombre', e.nombres || ' ' || e.apellidos,
            'activo', d.activo,
            'created_at', d.created_at,
            'updated_at', d.updated_at
        )
    ) INTO v_resultado
    FROM rh.departamentos d
    LEFT JOIN rh.empleados e ON d.empleado_id = e.id
    WHERE d.id = p_id;
    
    RETURN v_resultado;
    
EXCEPTION
    WHEN unique_violation THEN
        RETURN jsonb_build_object(
            'success', false,
            'message', 'Ya existe otro departamento con ese nombre o código',
            'error_code', 'DUPLICATE'
        );
    WHEN OTHERS THEN
        RETURN jsonb_build_object(
            'success', false,
            'message', 'Error al actualizar: ' || SQLERRM,
            'error_code', SQLSTATE
        );
END;
$$ LANGUAGE plpgsql;




-- ============================================
-- FUNCIÓN: rh.fn_departamento_eliminar
-- ============================================
CREATE OR REPLACE FUNCTION rh.fn_departamento_eliminar(
    p_id BIGINT,
    p_usuario_login VARCHAR DEFAULT NULL,
    p_ip_address INET DEFAULT NULL,
    p_user_agent TEXT DEFAULT NULL,
    p_request_id UUID DEFAULT NULL,
    p_fisico BOOLEAN DEFAULT false
)
RETURNS JSONB AS $$
DECLARE
    v_departamento RECORD;
    v_empleados_count BIGINT;
BEGIN
    -- Establecer contexto para auditoría
    PERFORM set_config('app.usuario_login', p_usuario_login, true);
    PERFORM set_config('app.ip_address', p_ip_address::TEXT, true);
    PERFORM set_config('app.user_agent', p_user_agent, true);
    PERFORM set_config('app.request_id', p_request_id::TEXT, true);
    PERFORM set_config('app.modulo', 'rh.departamentos', true);
    
    -- Verificar existencia
    SELECT * INTO v_departamento 
    FROM rh.departamentos 
    WHERE id = p_id;
    
    IF NOT FOUND THEN
        RETURN jsonb_build_object(
            'success', false,
            'message', 'Departamento no encontrado',
            'error_code', 'NOT_FOUND'
        );
    END IF;
    
    -- Verificar dependencias (empleados)
    SELECT COUNT(*) INTO v_empleados_count 
    FROM rh.empleados 
    WHERE departamento_id = p_id;
    
    IF v_empleados_count > 0 THEN
        RETURN jsonb_build_object(
            'success', false,
            'message', 'No se puede eliminar el departamento porque tiene ' || v_empleados_count || ' empleados asociados',
            'error_code', 'HAS_EMPLOYEES',
            'empleados_count', v_empleados_count
        );
    END IF;
    
    IF p_fisico THEN
        -- Eliminación física
        DELETE FROM rh.departamentos WHERE id = p_id;
        
        RETURN jsonb_build_object(
            'success', true,
            'message', 'Departamento eliminado físicamente',
            'data', jsonb_build_object(
                'id', p_id,
                'nombre', v_departamento.nombre,
                'deleted_at', CURRENT_TIMESTAMP
            )
        );
    ELSE
        -- Soft delete: desactivar
        UPDATE rh.departamentos SET
            activo = false
        WHERE id = p_id;
        
        RETURN jsonb_build_object(
            'success', true,
            'message', 'Departamento desactivado exitosamente',
            'data', jsonb_build_object(
                'id', p_id,
                'nombre', v_departamento.nombre,
                'activo', false
            )
        );
    END IF;
    
EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object(
            'success', false,
            'message', 'Error al eliminar: ' || SQLERRM,
            'error_code', SQLSTATE
        );
END;
$$ LANGUAGE plpgsql;



-- ============================================
-- FUNCIÓN: rh.fn_departamento_obtener
-- ============================================
CREATE OR REPLACE FUNCTION rh.fn_departamento_obtener(
    p_id BIGINT
)
RETURNS JSONB AS $$
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
$$ LANGUAGE plpgsql;






-- ============================================
-- FUNCIÓN: rh.fn_departamentos_listar
-- ============================================
CREATE OR REPLACE FUNCTION rh.fn_departamentos_listar(
    p_pagina INTEGER DEFAULT 1,
    p_limite INTEGER DEFAULT 15,
    p_activo BOOLEAN DEFAULT NULL,
    p_busqueda VARCHAR DEFAULT NULL,
    p_order_by VARCHAR DEFAULT 'nombre',
    p_order_dir VARCHAR DEFAULT 'ASC'
)
RETURNS JSONB AS $$
DECLARE
    v_offset INTEGER := (p_pagina - 1) * p_limite;
    v_query TEXT;
    v_result JSONB;
    v_total INTEGER;
    v_total_paginas INTEGER;
BEGIN
    -- Query principal
    v_query := format('
        SELECT jsonb_agg(jsonb_build_object(
            ''id'', d.id,
            ''nombre'', d.nombre,
            ''descripcion'', d.descripcion,
            ''codigo'', d.codigo,
            ''empleado_id'', d.empleado_id,
            ''empleado_nombre'', e.nombres || '' '' || e.apellidos,
            ''activo'', d.activo,
            ''created_at'', d.created_at,
            ''total_empleados'', (SELECT COUNT(*) FROM rh.empleados WHERE departamento_id = d.id AND activo = true)
        )) FROM (
            SELECT d.*
            FROM rh.departamentos d
            WHERE 1=1
    ');
    
    -- Filtro activo
    IF p_activo IS NOT NULL THEN
        v_query := v_query || format(' AND d.activo = %L', p_activo);
    END IF;
    
    -- Búsqueda
    IF p_busqueda IS NOT NULL AND p_busqueda != '' THEN
        v_query := v_query || format(
            ' AND (d.nombre ILIKE %L OR d.codigo ILIKE %L OR d.descripcion ILIKE %L)',
            '%' || p_busqueda || '%',
            '%' || p_busqueda || '%',
            '%' || p_busqueda || '%'
        );
    END IF;
    
    -- Ordenamiento
    IF p_order_by IN ('id', 'nombre', 'codigo', 'activo', 'created_at') THEN
        v_query := v_query || format(' ORDER BY d.%I %s', 
            p_order_by, 
            CASE WHEN UPPER(p_order_dir) IN ('ASC', 'DESC') THEN p_order_dir ELSE 'ASC' END
        );
    ELSE
        v_query := v_query || ' ORDER BY d.nombre ASC';
    END IF;
    
    -- Paginación
    v_query := v_query || format(' LIMIT %s OFFSET %s', p_limite, v_offset);
    v_query := v_query || ') d
    LEFT JOIN rh.empleados e ON d.empleado_id = e.id';
    
    EXECUTE v_query INTO v_result;
    
    -- Contar total
    v_query := 'SELECT COUNT(*) FROM rh.departamentos d WHERE 1=1';
    IF p_activo IS NOT NULL THEN
        v_query := v_query || format(' AND d.activo = %L', p_activo);
    END IF;
    IF p_busqueda IS NOT NULL AND p_busqueda != '' THEN
        v_query := v_query || format(
            ' AND (d.nombre ILIKE %L OR d.codigo ILIKE %L OR d.descripcion ILIKE %L)',
            '%' || p_busqueda || '%',
            '%' || p_busqueda || '%',
            '%' || p_busqueda || '%'
        );
    END IF;
    EXECUTE v_query INTO v_total;
    
    v_total_paginas := CEIL(v_total::DECIMAL / p_limite);
    
    RETURN jsonb_build_object(
        'success', true,
        'data', COALESCE(v_result, '[]'::jsonb),
        'paginacion', jsonb_build_object(
            'pagina_actual', p_pagina,
            'limite', p_limite,
            'total_registros', v_total,
            'total_paginas', v_total_paginas,
            'desde', v_offset + 1,
            'hasta', LEAST(v_offset + p_limite, v_total)
        )
    );
END;
$$ LANGUAGE plpgsql;































-- ============================================
-- EJEMPLOS PRÁCTICOS
-- ============================================

-- 1. CREAR DEPARTAMENTO
SELECT rh.fn_crear_departamento(
    'Tecnología',                           -- nombre
    'Departamento de Tecnología y Sistemas', -- descripción
    'TEC',                                   -- código
    2,                                       -- empleado_id (María Gómez)
    'admin',                                 -- usuario_login
    '192.168.1.100'::inet,                   -- ip_address
    'Mozilla/5.0...',                        -- user_agent
    gen_random_uuid()                        -- request_id
);

-- 2. LISTAR DEPARTAMENTOS (página 1, 10 por página)
SELECT rh.fn_listar_departamentos(1, 10, true, NULL, 'nombre', 'ASC');

-- 3. BUSCAR DEPARTAMENTOS
SELECT rh.fn_listar_departamentos(1, 10, NULL, 'Tecnología', 'nombre', 'ASC');

-- 4. OBTENER DEPARTAMENTO POR ID
SELECT rh.fn_obtener_departamento(1);

-- 5. ACTUALIZAR DEPARTAMENTO
SELECT rh.fn_actualizar_departamento(
    1,                                       -- id
    'Tecnología y Sistemas',                 -- nuevo nombre
    NULL,                                    -- descripción (no cambia)
    'SIST',                                  -- nuevo código
    3,                                       -- nuevo responsable (Carlos López)
    true,                                    -- activo
    'admin',                                 -- usuario_login
    '192.168.1.100'::inet,                   -- ip_address
    'Mozilla/5.0...',                        -- user_agent
    gen_random_uuid()                        -- request_id
);

-- 6. DESACTIVAR DEPARTAMENTO
SELECT rh.fn_toggle_departamento(
    1,                                       -- id
    'admin',                                 -- usuario_login
    '192.168.1.100'::inet,                   -- ip_address
    'Mozilla/5.0...',                        -- user_agent
    gen_random_uuid()                        -- request_id
);

-- 7. ELIMINAR DEPARTAMENTO (soft delete)
SELECT rh.fn_eliminar_departamento(
    1,                                       -- id
    'admin',                                 -- usuario_login
    '192.168.1.100'::inet,                   -- ip_address
    'Mozilla/5.0...',                        -- user_agent
    gen_random_uuid(),                       -- request_id
    false                                    -- p_fisico = false (soft delete)
);

-- 8. ELIMINAR DEPARTAMENTO (físico - solo si no tiene empleados)
SELECT rh.fn_eliminar_departamento(
    2,                                       -- id
    'admin',                                 -- usuario_login
    '192.168.1.100'::inet,                   -- ip_address
    'Mozilla/5.0...',                        -- user_agent
    gen_random_uuid(),                       -- request_id
    true                                     -- p_fisico = true
);

-- 9. VER AUDITORÍA DE DEPARTAMENTOS
SELECT 
    fecha_operacion,
    operacion,
    usuario_login,
    usuario_nombre,
    ip_address,
    datos_anteriores->>'nombre' AS nombre_anterior,
    datos_nuevos->>'nombre' AS nombre_nuevo,
    datos_anteriores->>'codigo' AS codigo_anterior,
    datos_nuevos->>'codigo' AS codigo_nuevo
FROM auditoria.logs_cambios 
WHERE tabla_nombre = 'departamentos' 
ORDER BY fecha_operacion DESC;