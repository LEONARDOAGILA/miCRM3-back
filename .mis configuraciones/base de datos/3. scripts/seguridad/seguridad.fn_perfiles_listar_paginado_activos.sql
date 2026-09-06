-- FUNCTION: seguridad.fn_perfiles_listar_paginado_activos(integer, integer, text)

-- DROP FUNCTION IF EXISTS seguridad.fn_perfiles_listar_paginado_activos(integer, integer, text);

CREATE OR REPLACE FUNCTION seguridad.fn_perfiles_listar_paginado_activos(
	p_page integer DEFAULT 1,
	p_per_page integer DEFAULT 15,
	p_search text DEFAULT ''::text)
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
BEGIN
    -- Calcular offset
    v_offset := (p_page - 1) * p_per_page;
    
    -- 1. Contar total con filtro (solo activos)
    IF p_search IS NOT NULL AND p_search != '' THEN
        SELECT COUNT(*) INTO v_total
        FROM seguridad.perfiles
        WHERE activo = true
          AND (nombre ILIKE '%' || p_search || '%' 
           OR id::text ILIKE '%' || p_search || '%');
    ELSE
        SELECT COUNT(*) INTO v_total 
        FROM seguridad.perfiles
        WHERE activo = true;
    END IF;
    
    -- 2. Consulta paginada
    IF p_search IS NOT NULL AND p_search != '' THEN
        SELECT COALESCE(
            jsonb_agg(
                jsonb_build_object(
                    'id', id,
                    'nombre', nombre,
                    'inactividad', inactividad,
                    'activo', activo,
                    'created_by', created_by,
                    'updated_by', updated_by,
                    'created_at', to_char(created_at, 'YYYY-MM-DD HH24:MI:SS'),
                    'updated_at', to_char(updated_at, 'YYYY-MM-DD HH24:MI:SS')
                )
                ORDER BY id DESC
            ), '[]'::jsonb
        ) INTO v_data
        FROM (
            SELECT id, nombre, inactividad, activo, created_by, updated_by, created_at, updated_at
            FROM seguridad.perfiles
            WHERE activo = true
              AND (nombre ILIKE '%' || p_search || '%' 
               OR id::text ILIKE '%' || p_search || '%')
            ORDER BY id DESC
            LIMIT p_per_page OFFSET v_offset
        ) AS subquery;
    ELSE
        SELECT COALESCE(
            jsonb_agg(
                jsonb_build_object(
                    'id', id,
                    'nombre', nombre,
                    'inactividad', inactividad,
                    'activo', activo,
                    'created_by', created_by,
                    'updated_by', updated_by,
                    'created_at', to_char(created_at, 'YYYY-MM-DD HH24:MI:SS'),
                    'updated_at', to_char(updated_at, 'YYYY-MM-DD HH24:MI:SS')
                )
                ORDER BY id DESC
            ), '[]'::jsonb
        ) INTO v_data
        FROM (
            SELECT id, nombre, inactividad, activo, created_by, updated_by, created_at, updated_at
            FROM seguridad.perfiles
            WHERE activo = true
            ORDER BY id DESC
            LIMIT p_per_page OFFSET v_offset
        ) AS subquery;
    END IF;
    
    -- 3. Construir resultado
    v_resultado := jsonb_build_object(
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
            'message', 'Error al listar perfiles activos: ' || SQLERRM,
            'error_code', SQLSTATE
        );
END;
$BODY$;

ALTER FUNCTION seguridad.fn_perfiles_listar_paginado_activos(integer, integer, text)
    OWNER TO postgres;

