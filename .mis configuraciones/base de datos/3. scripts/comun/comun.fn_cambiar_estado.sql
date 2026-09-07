-- FUNCTION: comun.fn_cambiar_estado(regclass, bigint, boolean, text, text, character varying, inet, text, uuid)

-- DROP FUNCTION IF EXISTS comun.fn_cambiar_estado(regclass, bigint, boolean, text, text, character varying, inet, text, uuid);

CREATE OR REPLACE FUNCTION comun.fn_cambiar_estado(
	p_tabla regclass,
	p_id bigint,
	p_estado boolean,
	p_id_columna text DEFAULT 'id'::text,
	p_estado_columna text DEFAULT 'activo'::text,
	p_usuario_login character varying DEFAULT NULL::character varying,
	p_ip_address inet DEFAULT NULL::inet,
	p_user_agent text DEFAULT NULL::text,
	p_request_id uuid DEFAULT NULL::uuid)
    RETURNS jsonb
    LANGUAGE 'plpgsql'
    COST 100
    VOLATILE PARALLEL UNSAFE
AS $BODY$
DECLARE
    v_esquema TEXT;
    v_tabla TEXT;
    v_modulo TEXT;
    v_sql TEXT;
    v_estado_anterior BOOLEAN;
    v_nombre_registro TEXT;
    v_nombre_columna TEXT;
    v_tiene_updated_at BOOLEAN;
BEGIN
    -- Extraer esquema y tabla de REGCLASS
    SELECT 
        split_part(p_tabla::TEXT, '.', 1),
        split_part(p_tabla::TEXT, '.', 2)
    INTO v_esquema, v_tabla;
    
    IF v_tabla IS NULL THEN
        v_tabla := v_esquema;
        v_esquema := 'public';
    END IF;
    
    v_modulo := v_esquema || '.' || v_tabla;
    
    -- Establecer contexto para auditoría
    PERFORM set_config('app.usuario_login', p_usuario_login, true);
    PERFORM set_config('app.ip_address', p_ip_address::TEXT, true);
    PERFORM set_config('app.user_agent', p_user_agent, true);
    PERFORM set_config('app.request_id', p_request_id::TEXT, true);
    PERFORM set_config('app.modulo', v_modulo, true);
    PERFORM set_config('app.operacion', CASE WHEN p_estado THEN 'activar' ELSE 'desactivar' END, true);
    
    -- Validar columnas
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = v_esquema AND table_name = v_tabla AND column_name = p_estado_columna) THEN
        RETURN jsonb_build_object('success', false, 'message', format('Columna %s no existe', p_estado_columna), 'error_code', 'COLUMN_NOT_FOUND');
    END IF;
    
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = v_esquema AND table_name = v_tabla AND column_name = p_id_columna) THEN
        RETURN jsonb_build_object('success', false, 'message', format('Columna %s no existe', p_id_columna), 'error_code', 'COLUMN_NOT_FOUND');
    END IF;
    
    -- Buscar columna de nombre
    SELECT column_name INTO v_nombre_columna
    FROM information_schema.columns 
    WHERE table_schema = v_esquema 
      AND table_name = v_tabla 
      AND column_name IN ('nombre', 'name', 'descripcion', 'description', 'titulo', 'title')
    LIMIT 1;
    
    -- Verificar updated_at
    SELECT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = v_esquema AND table_name = v_tabla AND column_name = 'updated_at') INTO v_tiene_updated_at;
    
    -- ============================================
    -- PRIMERO: Obtener el estado actual ANTES de actualizar
    -- ============================================
    IF v_nombre_columna IS NOT NULL THEN
        v_sql := FORMAT('
            SELECT %I, %I 
            FROM %I.%I 
            WHERE %I = $1',
            p_estado_columna, v_nombre_columna,
            v_esquema, v_tabla,
            p_id_columna
        );
        EXECUTE v_sql INTO v_estado_anterior, v_nombre_registro USING p_id;
    ELSE
        v_sql := FORMAT('
            SELECT %I 
            FROM %I.%I 
            WHERE %I = $1',
            p_estado_columna,
            v_esquema, v_tabla,
            p_id_columna
        );
        EXECUTE v_sql INTO v_estado_anterior USING p_id;
    END IF;
    
    -- Verificar si existe el registro
    IF v_estado_anterior IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'message', format('Registro con %s = %s no encontrado', p_id_columna, p_id),
            'error_code', 'NOT_FOUND'
        );
    END IF;
    
    -- ============================================
    -- SEGUNDO: Si ya está en el estado deseado, retornar sin actualizar
    -- ============================================
    IF v_estado_anterior = p_estado THEN
        RETURN jsonb_build_object(
            'success', true,
            'message', CASE 
                WHEN p_estado THEN format('El registro "%s" ya estaba activo', COALESCE(v_nombre_registro, 'desconocido'))
                ELSE format('El registro "%s" ya estaba inactivo', COALESCE(v_nombre_registro, 'desconocido'))
            END,
            'data', jsonb_build_object(
                'id', p_id,
                'nombre', v_nombre_registro,
                p_estado_columna, p_estado,
                'ya_estaba', true
            )
        );
    END IF;
    
    -- ============================================
    -- TERCERO: Actualizar el estado
    -- ============================================
    IF v_tiene_updated_at THEN
        v_sql := FORMAT('
            UPDATE %I.%I 
            SET %I = $2,
                updated_at = NOW()
            WHERE %I = $1',
            v_esquema, v_tabla,
            p_estado_columna,
            p_id_columna
        );
    ELSE
        v_sql := FORMAT('
            UPDATE %I.%I 
            SET %I = $2
            WHERE %I = $1',
            v_esquema, v_tabla,
            p_estado_columna,
            p_id_columna
        );
    END IF;
    
    EXECUTE v_sql USING p_id, p_estado;
    
    -- ============================================
    -- CUARTO: Retornar resultado exitoso
    -- ============================================
    RETURN jsonb_build_object(
        'success', true,
        'message', CASE 
            WHEN p_estado THEN format('Registro "%s" activado exitosamente', COALESCE(v_nombre_registro, 'desconocido'))
            ELSE format('Registro "%s" desactivado exitosamente', COALESCE(v_nombre_registro, 'desconocido'))
        END,
        'data', jsonb_build_object(
            'id', p_id,
            'nombre', v_nombre_registro,
            p_estado_columna, p_estado,
            'estado_anterior', v_estado_anterior
        )
    );
    
EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object(
            'success', false,
            'message', 'Error al cambiar estado: ' || SQLERRM,
            'error_code', SQLSTATE
        );
END;
$BODY$;

ALTER FUNCTION comun.fn_cambiar_estado(regclass, bigint, boolean, text, text, character varying, inet, text, uuid)
    OWNER TO postgres;

