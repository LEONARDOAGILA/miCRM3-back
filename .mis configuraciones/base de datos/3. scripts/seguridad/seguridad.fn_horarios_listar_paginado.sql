-- FUNCTION: seguridad.fn_horarios_listar_paginado(integer, integer, text)

-- DROP FUNCTION IF EXISTS seguridad.fn_horarios_listar_paginado(integer, integer, text);

CREATE OR REPLACE FUNCTION seguridad.fn_horarios_listar_paginado(
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
    v_offset := (p_page - 1) * p_per_page;
    
    -- 1. Contar total con filtro
    IF p_search IS NOT NULL AND p_search != '' THEN
        SELECT COUNT(*) INTO v_total
        FROM seguridad.chorarios c
        WHERE c.nombre ILIKE '%' || p_search || '%' 
           OR c.id::text ILIKE '%' || p_search || '%';
    ELSE
        SELECT COUNT(*) INTO v_total FROM seguridad.chorarios;
    END IF;
    
    -- 2. Consulta paginada
    IF p_search IS NOT NULL AND p_search != '' THEN
        SELECT COALESCE(
            (SELECT jsonb_agg(
                jsonb_build_object(
                    'id', c.id,
                    'nombre', c.nombre,
                    'activo', c.activo,
                    'created_at', to_char(c.created_at, 'YYYY-MM-DD HH24:MI:SS'),
                    'updated_at', to_char(c.updated_at, 'YYYY-MM-DD HH24:MI:SS'),
                    'created_by', c.created_by,
                    'updated_by', c.updated_by
                )
                ORDER BY c.id DESC
            )
            FROM (
                SELECT c.id, c.nombre, c.activo, c.created_at, c.updated_at, c.created_by, c.updated_by
                FROM seguridad.chorarios c
                WHERE c.nombre ILIKE '%' || p_search || '%' 
                   OR c.id::text ILIKE '%' || p_search || '%'
                ORDER BY c.id DESC
                LIMIT p_per_page OFFSET v_offset
            ) c
            ), '[]'::jsonb) INTO v_data;
    ELSE
        SELECT COALESCE(
            (SELECT jsonb_agg(
                jsonb_build_object(
                    'id', c.id,
                    'nombre', c.nombre,
                    'activo', c.activo,
                    'created_at', to_char(c.created_at, 'YYYY-MM-DD HH24:MI:SS'),
                    'updated_at', to_char(c.updated_at, 'YYYY-MM-DD HH24:MI:SS'),
                    'created_by', c.created_by,
                    'updated_by', c.updated_by
                )
                ORDER BY c.id DESC
            )
            FROM (
                SELECT c.id, c.nombre, c.activo, c.created_at, c.updated_at, c.created_by, c.updated_by
                FROM seguridad.chorarios c
                ORDER BY c.id DESC
                LIMIT p_per_page OFFSET v_offset
            ) c
            ), '[]'::jsonb) INTO v_data;
    END IF;
    
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
            'message', 'Error al listar horarios: ' || SQLERRM,
            'error_code', SQLSTATE
        );
END;
$BODY$;

ALTER FUNCTION seguridad.fn_horarios_listar_paginado(integer, integer, text)
    OWNER TO postgres;

