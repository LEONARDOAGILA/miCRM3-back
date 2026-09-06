-- FUNCTION: seguridad.fn_menus_listar()

-- DROP FUNCTION IF EXISTS seguridad.fn_menus_listar();

CREATE OR REPLACE FUNCTION seguridad.fn_menus_listar(
	)
    RETURNS jsonb
    LANGUAGE 'plpgsql'
    COST 100
    VOLATILE SECURITY DEFINER PARALLEL UNSAFE
AS $BODY$
DECLARE
    v_resultado JSONB;
BEGIN
    WITH RECURSIVE menu_tree AS (
        -- Nodos raíz (padre_id = NULL)
        SELECT 
            m.id,
            m.padre_id,
            m.orden,
            m.nivel,
            m.nombre,
            m.url,
            m.descripcion,
            m.etiqueta,
            m.icono,
            m.created_at,
            m.updated_at,
            m.created_by,
            m.updated_by,
            0 as nivel_hierarchy,
            LPAD(m.orden::text, 5, '0') as orden_path,
            LOWER(REPLACE(TRIM(m.nombre), ' ', '-'))::text as url_path
        FROM seguridad.menus m
        WHERE m.padre_id IS NULL
        
        UNION ALL
        
        -- Hijos recursivos
        SELECT 
            m.id,
            m.padre_id,
            m.orden,
            m.nivel,
            m.nombre,
            m.url,
            m.descripcion,
            m.etiqueta,
            m.icono,
            m.created_at,
            m.updated_at,
            m.created_by,
            m.updated_by,
            mt.nivel_hierarchy + 1,
            mt.orden_path || '.' || LPAD(m.orden::text, 5, '0'),
            (mt.url_path || '/' || LOWER(REPLACE(TRIM(m.nombre), ' ', '-')))::text
        FROM seguridad.menus m
        INNER JOIN menu_tree mt ON m.padre_id = mt.id
    )
    SELECT jsonb_build_object(
        'success', true,
        'message', 'Menús obtenidos exitosamente',
        'data', COALESCE((
            SELECT jsonb_agg(
                jsonb_build_object(
                    'id', id,
                    'padre_id', padre_id,
                    'orden', orden,
                    'nivel', nivel,
                    'nombre', nombre,
                    'url', url,
                    'descripcion', descripcion,
                    'etiqueta', etiqueta,
                    'icono', icono,
                    'created_at', to_char(created_at, 'YYYY-MM-DD HH24:MI:SS'),
                    'updated_at', to_char(updated_at, 'YYYY-MM-DD HH24:MI:SS'),
                    'created_by', created_by,
                    'updated_by', updated_by,
                    'nivel_hierarchy', nivel_hierarchy,
                    'orden_path', orden_path,
                    'path', url_path
                )
                ORDER BY orden_path
            )
            FROM menu_tree
        ), '[]'::jsonb)
    ) INTO v_resultado;
    
    RETURN v_resultado;
    
EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object(
            'success', false,
            'message', 'Error al listar menús: ' || SQLERRM,
            'error_code', SQLSTATE
        );
END;
$BODY$;

ALTER FUNCTION seguridad.fn_menus_listar()
    OWNER TO postgres;

