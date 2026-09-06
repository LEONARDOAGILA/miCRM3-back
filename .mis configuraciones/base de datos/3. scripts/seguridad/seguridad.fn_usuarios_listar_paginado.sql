-- FUNCTION: seguridad.fn_usuarios_listar_paginado(integer, integer, text)

-- DROP FUNCTION IF EXISTS seguridad.fn_usuarios_listar_paginado(integer, integer, text);

CREATE OR REPLACE FUNCTION seguridad.fn_usuarios_listar_paginado(
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
    v_search_terms TEXT[];
BEGIN
    -- Calcular offset
    v_offset := (p_page - 1) * p_per_page;
    
    -- Convertir búsqueda en array de palabras
    v_search_terms := string_to_array(trim(p_search), ' ');
    
    -- 1. Contar total con filtro
    IF p_search IS NOT NULL AND p_search != '' THEN
        SELECT COUNT(*) INTO v_total
        FROM seguridad.users u
        WHERE u.login_user ILIKE '%' || p_search || '%' 
           OR u.name ILIKE '%' || p_search || '%'
           OR u.surname ILIKE '%' || p_search || '%'
           OR u.email ILIKE '%' || p_search || '%'
           OR u.id::text ILIKE '%' || p_search || '%'
           -- Buscar cada palabra en el nombre completo
           OR (
               SELECT bool_and(
                   EXISTS (
                       SELECT 1 
                       WHERE CONCAT_WS(' ', u.name, u.surname) ILIKE '%' || term || '%'
                       OR CONCAT_WS(' ', u.surname, u.name) ILIKE '%' || term || '%'
                   )
               )
               FROM unnest(v_search_terms) AS term
           );
    ELSE
        SELECT COUNT(*) INTO v_total FROM seguridad.users;
    END IF;
    
    -- 2. Consulta paginada
    IF p_search IS NOT NULL AND p_search != '' THEN
        SELECT COALESCE(
            (SELECT jsonb_agg(
                jsonb_build_object(
                    'id', t.id,
                    'login_user', t.login_user,
                    'name', t.name,
                    'surname', t.surname,
                    'email', t.email,
                    'phone', t.phone,
                    'avatar', t.avatar,
                    'type_user', t.type_user,
                    'isactive', t.isactive,
                    'islogin', t.islogin,
                    'isreset', t.isreset,
                    'perfil_id', t.perfil_id,
                    'perfil_nombre', p.nombre,
                    'chorario_id', t.chorario_id,
                    'chorario_nombre', h.nombre,
                    'created_by', t.created_by,
                    'updated_by', t.updated_by,
                    'created_at', to_char(t.created_at, 'YYYY-MM-DD HH24:MI:SS'),
                    'updated_at', to_char(t.updated_at, 'YYYY-MM-DD HH24:MI:SS'),
                    'email_verified_at', to_char(t.email_verified_at, 'YYYY-MM-DD HH24:MI:SS'),
                    'user_verified_at', to_char(t.user_verified_at, 'YYYY-MM-DD HH24:MI:SS'),
                    'last_login_at', to_char(t.last_login_at, 'YYYY-MM-DD HH24:MI:SS')
                )
                ORDER BY t.id DESC
            )
            FROM (
                SELECT u.id, u.login_user, u.name, u.surname, u.email, u.phone, u.avatar,
                       u.type_user, u.isactive, u.islogin, u.isreset, u.perfil_id, u.chorario_id,
                       u.created_by, u.updated_by, u.created_at, u.updated_at,
                       u.email_verified_at, u.user_verified_at, u.last_login_at
                FROM seguridad.users u
                WHERE u.login_user ILIKE '%' || p_search || '%' 
                   OR u.name ILIKE '%' || p_search || '%'
                   OR u.surname ILIKE '%' || p_search || '%'
                   OR u.email ILIKE '%' || p_search || '%'
                   OR u.id::text ILIKE '%' || p_search || '%'
                   -- Buscar cada palabra en el nombre completo
                   OR (
                       SELECT bool_and(
                           EXISTS (
                               SELECT 1 
                               WHERE CONCAT_WS(' ', u.name, u.surname) ILIKE '%' || term || '%'
                               OR CONCAT_WS(' ', u.surname, u.name) ILIKE '%' || term || '%'
                           )
                       )
                       FROM unnest(v_search_terms) AS term
                   )
                ORDER BY u.id DESC
                LIMIT p_per_page OFFSET v_offset
            ) t
            LEFT JOIN seguridad.perfiles p ON p.id = t.perfil_id
            LEFT JOIN seguridad.chorarios h ON h.id = t.chorario_id
            ), '[]'::jsonb) INTO v_data;
    ELSE
        SELECT COALESCE(
            (SELECT jsonb_agg(
                jsonb_build_object(
                    'id', t.id,
                    'login_user', t.login_user,
                    'name', t.name,
                    'surname', t.surname,
                    'email', t.email,
                    'phone', t.phone,
                    'avatar', t.avatar,
                    'type_user', t.type_user,
                    'isactive', t.isactive,
                    'islogin', t.islogin,
                    'isreset', t.isreset,
                    'perfil_id', t.perfil_id,
                    'perfil_nombre', p.nombre,
                    'chorario_id', t.chorario_id,
                    'chorario_nombre', h.nombre,
                    'created_by', t.created_by,
                    'updated_by', t.updated_by,
                    'created_at', to_char(t.created_at, 'YYYY-MM-DD HH24:MI:SS'),
                    'updated_at', to_char(t.updated_at, 'YYYY-MM-DD HH24:MI:SS'),
                    'email_verified_at', to_char(t.email_verified_at, 'YYYY-MM-DD HH24:MI:SS'),
                    'user_verified_at', to_char(t.user_verified_at, 'YYYY-MM-DD HH24:MI:SS'),
                    'last_login_at', to_char(t.last_login_at, 'YYYY-MM-DD HH24:MI:SS')
                )
                ORDER BY t.id DESC
            )
            FROM (
                SELECT u.id, u.login_user, u.name, u.surname, u.email, u.phone, u.avatar,
                       u.type_user, u.isactive, u.islogin, u.isreset, u.perfil_id, u.chorario_id,
                       u.created_by, u.updated_by, u.created_at, u.updated_at,
                       u.email_verified_at, u.user_verified_at, u.last_login_at
                FROM seguridad.users u
                ORDER BY u.id DESC
                LIMIT p_per_page OFFSET v_offset
            ) t
            LEFT JOIN seguridad.perfiles p ON p.id = t.perfil_id
            LEFT JOIN seguridad.chorarios h ON h.id = t.chorario_id
            ), '[]'::jsonb) INTO v_data;
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
            'message', 'Error al listar usuarios: ' || SQLERRM,
            'error_code', SQLSTATE
        );
END;
$BODY$;

ALTER FUNCTION seguridad.fn_usuarios_listar_paginado(integer, integer, text)
    OWNER TO postgres;

