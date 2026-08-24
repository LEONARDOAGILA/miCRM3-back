-- FUNCTION: auditoria.fn_auditoria_listar_paginado(text, text, text, text, text, integer, integer)

-- DROP FUNCTION IF EXISTS auditoria.fn_auditoria_listar_paginado(text, text, text, text, text, integer, integer);

CREATE OR REPLACE FUNCTION auditoria.fn_auditoria_listar_paginado(
	p_tabla_nombre text DEFAULT NULL::text,
	p_registro_id text DEFAULT NULL::text,
	p_operacion text DEFAULT NULL::text,
	p_fecha_desde text DEFAULT NULL::text,
	p_fecha_hasta text DEFAULT NULL::text,
	p_page integer DEFAULT 1,
	p_per_page integer DEFAULT 15)
    RETURNS jsonb
    LANGUAGE 'plpgsql'
    COST 100
    VOLATILE SECURITY DEFINER PARALLEL UNSAFE
AS $BODY$
DECLARE
    v_offset INTEGER;
    v_total BIGINT;
    v_data JSONB;
    v_resultado JSONB;
    v_fecha_desde TIMESTAMP;
    v_fecha_hasta TIMESTAMP;
BEGIN
    -- Calcular offset
    v_offset := (p_page - 1) * p_per_page;
    
    -- Convertir fechas si vienen
    IF p_fecha_desde IS NOT NULL AND p_fecha_desde != '' THEN
        v_fecha_desde := p_fecha_desde::TIMESTAMP;
    END IF;
    
    IF p_fecha_hasta IS NOT NULL AND p_fecha_hasta != '' THEN
        v_fecha_hasta := (p_fecha_hasta::TIMESTAMP) + INTERVAL '1 day' - INTERVAL '1 second';
    END IF;
    
    -- 1. Contar total con filtros (case-insensitive para operación)
    SELECT COUNT(*) INTO v_total
    FROM auditoria.logs_cambios
    WHERE (p_tabla_nombre IS NULL OR tabla_nombre = p_tabla_nombre)
      AND (p_registro_id IS NULL OR registro_id::text = p_registro_id)
      AND (p_operacion IS NULL OR operacion ILIKE p_operacion)  -- ILIKE para case-insensitive
      AND (v_fecha_desde IS NULL OR fecha_operacion >= v_fecha_desde)
      AND (v_fecha_hasta IS NULL OR fecha_operacion <= v_fecha_hasta);
    
    -- 2. Consulta paginada
    SELECT COALESCE(
        jsonb_agg(
            jsonb_build_object(
                'id', id,
                'schema_nombre', schema_nombre,
                'tabla_nombre', tabla_nombre,
                'registro_id', registro_id,
                'operacion', operacion,
                'datos_anteriores', datos_anteriores,
                'datos_nuevos', datos_nuevos,
                'usuario_id', usuario_id,
                'usuario_login', usuario_login,
                'usuario_nombre', usuario_nombre,
                'ip_address', ip_address,
                'user_agent', user_agent,
                'request_id', request_id,
                'modulo', modulo,
                'fecha_operacion', to_char(fecha_operacion, 'YYYY-MM-DD HH24:MI:SS')
            )
            ORDER BY fecha_operacion DESC
        ), '[]'::jsonb
    ) INTO v_data
    FROM (
        SELECT id, schema_nombre, tabla_nombre, registro_id, operacion,
               datos_anteriores, datos_nuevos, usuario_id, usuario_login, 
               usuario_nombre, ip_address, user_agent, request_id, modulo, fecha_operacion
        FROM auditoria.logs_cambios
        WHERE (p_tabla_nombre IS NULL OR tabla_nombre = p_tabla_nombre)
          AND (p_registro_id IS NULL OR registro_id::text = p_registro_id)
          AND (p_operacion IS NULL OR operacion ILIKE p_operacion)  -- ILIKE para case-insensitive
          AND (v_fecha_desde IS NULL OR fecha_operacion >= v_fecha_desde)
          AND (v_fecha_hasta IS NULL OR fecha_operacion <= v_fecha_hasta)
        ORDER BY fecha_operacion DESC
        LIMIT p_per_page OFFSET v_offset
    ) AS subquery;
    
    -- 3. Construir resultado
    v_resultado := jsonb_build_object(
        'success', true,
        'data', v_data,
        'meta', jsonb_build_object(
            'total', v_total,
            'per_page', p_per_page,
            'current_page', p_page,
            'last_page', CASE WHEN v_total = 0 THEN 1 ELSE ceil(v_total::NUMERIC / p_per_page) END
        )
    );
    
    RETURN v_resultado;
    
EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object(
            'success', false,
            'message', 'Error al listar auditoría: ' || SQLERRM,
            'error_code', SQLSTATE
        );
END;
$BODY$;

ALTER FUNCTION auditoria.fn_auditoria_listar_paginado(text, text, text, text, text, integer, integer)
    OWNER TO postgres;

