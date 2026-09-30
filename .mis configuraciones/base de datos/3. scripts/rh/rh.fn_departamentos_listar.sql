-- FUNCTION: rh.fn_departamentos_listar(integer, integer, boolean, character varying, character varying, character varying)

-- DROP FUNCTION IF EXISTS rh.fn_departamentos_listar(integer, integer, boolean, character varying, character varying, character varying);

CREATE OR REPLACE FUNCTION rh.fn_departamentos_listar(
	p_pagina integer DEFAULT 1,
	p_limite integer DEFAULT 15,
	p_activo boolean DEFAULT NULL::boolean,
	p_busqueda character varying DEFAULT NULL::character varying,
	p_order_by character varying DEFAULT 'nombre'::character varying,
	p_order_dir character varying DEFAULT 'ASC'::character varying)
    RETURNS jsonb
    LANGUAGE 'plpgsql'
    COST 100
    VOLATILE PARALLEL UNSAFE
AS $BODY$
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
$BODY$;

ALTER FUNCTION rh.fn_departamentos_listar(integer, integer, boolean, character varying, character varying, character varying)
    OWNER TO postgres;

