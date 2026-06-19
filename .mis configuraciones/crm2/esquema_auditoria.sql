
-- ============================================
-- CREACIÓN DE ESQUEMA AUDITORIA
-- ============================================
CREATE SCHEMA IF NOT EXISTS auditoria;


-- FUNCIÓN PARA ACTUALIZAR updated_at
CREATE OR REPLACE FUNCTION auditoria.fn_update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = CURRENT_TIMESTAMP;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;
ALTER FUNCTION auditoria.fn_update_updated_at_column() OWNER TO postgres;



-- FUNCIÓN GENÉRICA PARA created_by Y updated_by
CREATE OR REPLACE FUNCTION auditoria.fn_set_audit_users()
RETURNS TRIGGER AS $$
DECLARE
    v_usuario VARCHAR(100);
    v_has_created_by BOOLEAN := FALSE;
    v_has_updated_by BOOLEAN := FALSE;
BEGIN
    -- Verificar si la tabla tiene la columna created_by
    BEGIN
        PERFORM NEW.created_by;
        v_has_created_by := TRUE;
    EXCEPTION WHEN undefined_column THEN
        -- La columna no existe, ignorar
    END;    
    -- Verificar si la tabla tiene la columna updated_by
    BEGIN
        PERFORM NEW.updated_by;
        v_has_updated_by := TRUE;
    EXCEPTION WHEN undefined_column THEN
        -- La columna no existe, ignorar
    END;    
    -- Si ninguna columna existe, no hacer nada
    IF NOT v_has_created_by AND NOT v_has_updated_by THEN
        RETURN NEW;
    END IF;    
    -- Obtener usuario del contexto de la aplicación
    v_usuario := NULLIF(current_setting('app.usuario_login', true), '');    
    -- Si no hay contexto (operación directa en BD), usar el usuario de la base de datos
    IF v_usuario IS NULL THEN
        v_usuario := current_user;
    END IF;    
    -- Para INSERT: asignar created_by y updated_by si existen
    IF TG_OP = 'INSERT' THEN
        IF v_has_created_by THEN
            NEW.created_by := v_usuario;
        END IF;
        IF v_has_updated_by THEN
            NEW.updated_by := v_usuario;
        END IF;    
    -- Para UPDATE: solo actualizar updated_by si existe
    ELSIF TG_OP = 'UPDATE' THEN
        IF v_has_updated_by THEN
            NEW.updated_by := v_usuario;
        END IF;
    END IF;
    
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;
ALTER FUNCTION auditoria.fn_set_audit_users() OWNER TO postgres;



-- TABLA DE AUDITORIA: logs_cambios (PARTICIONADA)
CREATE TABLE auditoria.logs_cambios (
    id BIGSERIAL,
    schema_nombre VARCHAR(50) NOT NULL,
    tabla_nombre VARCHAR(50) NOT NULL,
    registro_id BIGINT NOT NULL,
    operacion VARCHAR(10) NOT NULL,
    datos_anteriores JSONB,
    datos_nuevos JSONB,
    usuario_id BIGINT,
    usuario_login VARCHAR(100),
    usuario_nombre VARCHAR(200),
    ip_address INET,
    user_agent TEXT,
    request_id UUID,
    modulo VARCHAR(50),
    fecha_operacion TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (id, fecha_operacion)
) PARTITION BY RANGE (fecha_operacion);
-- Crear particiones para los próximos meses
DO $$
DECLARE
    v_start_date DATE;
    v_end_date DATE;
    v_partition_name TEXT;
    v_current_date DATE := date_trunc('month', CURRENT_DATE);
BEGIN
    -- Crear particiones para 12 meses (6 pasados y 6 futuros)
    FOR i IN -6..6 LOOP
        v_start_date := v_current_date + (i || ' months')::INTERVAL;
        v_end_date := v_start_date + INTERVAL '1 month';
        v_partition_name := 'logs_cambios_' || to_char(v_start_date, 'YYYY_MM');
        
        EXECUTE format('
            CREATE TABLE IF NOT EXISTS auditoria.%I PARTITION OF auditoria.logs_cambios
            FOR VALUES FROM (%L) TO (%L)',
            v_partition_name,
            v_start_date,
            v_end_date
        );
    END LOOP;
END;
$$;
-- Índices (se aplican a todas las particiones)
CREATE INDEX idx_logs_cambios_registro ON auditoria.logs_cambios(schema_nombre, tabla_nombre, registro_id);
CREATE INDEX idx_logs_cambios_tabla_registro ON auditoria.logs_cambios(tabla_nombre, registro_id);
CREATE INDEX idx_logs_cambios_usuario ON auditoria.logs_cambios(usuario_id);
CREATE INDEX idx_logs_cambios_usuario_login ON auditoria.logs_cambios(usuario_login);
CREATE INDEX idx_logs_cambios_fecha_brin ON auditoria.logs_cambios USING BRIN (fecha_operacion);







-- FUNCTION: auditoria.fn_registrar_evento(character varying, bigint, character varying, jsonb, jsonb, bigint, character varying, character varying, inet, text, uuid, character varying)
-- DROP FUNCTION IF EXISTS auditoria.fn_registrar_evento(character varying, bigint, character varying, jsonb, jsonb, bigint, character varying, character varying, inet, text, uuid, character varying);
CREATE OR REPLACE FUNCTION auditoria.fn_registrar_evento(
	p_tabla_afectada character varying,
	p_id_registro_afectado bigint,
	p_tipo_operacion character varying,
	p_datos_anteriores jsonb DEFAULT NULL::jsonb,
	p_datos_nuevos jsonb DEFAULT NULL::jsonb,
	p_usuario_id bigint DEFAULT NULL::bigint,
	p_usuario_login character varying DEFAULT NULL::character varying,
	p_usuario_nombre character varying DEFAULT NULL::character varying,
	p_ip_address inet DEFAULT NULL::inet,
	p_user_agent text DEFAULT NULL::text,
	p_request_id uuid DEFAULT NULL::uuid,
	p_modulo character varying DEFAULT NULL::character varying)
    RETURNS void
    LANGUAGE 'plpgsql'
    COST 100
    VOLATILE SECURITY DEFINER PARALLEL UNSAFE
AS $BODY$
BEGIN
    INSERT INTO auditoria.auditoria (
        tabla_afectada,
        id_registro_afectado,
        tipo_operacion,
        datos_anteriores,
        datos_nuevos,
        fecha_operacion,
        usuario_operador,
        ip_address,
        user_agent,
        request_id,
        modulo
    ) VALUES (
        p_tabla_afectada,
        p_id_registro_afectado,
        p_tipo_operacion,
        p_datos_anteriores,
        p_datos_nuevos,
        CURRENT_TIMESTAMP,
        CONCAT_WS(' - ', p_usuario_id, p_usuario_login, p_usuario_nombre),
        p_ip_address,
        p_user_agent,
        p_request_id,
        COALESCE(p_modulo, p_tabla_afectada)
    );
END;
$BODY$;
ALTER FUNCTION auditoria.fn_registrar_evento(character varying, bigint, character varying, jsonb, jsonb, bigint, character varying, character varying, inet, text, uuid, character varying)
    OWNER TO postgres;














CREATE OR REPLACE FUNCTION auditoria.fn_auditar_cambios()
    RETURNS trigger
    LANGUAGE 'plpgsql'
    COST 100
    VOLATILE NOT LEAKPROOF SECURITY DEFINER
AS $BODY$
DECLARE
    v_usuario_id BIGINT;
    v_usuario_login VARCHAR(100);
    v_usuario_nombre VARCHAR(200);
    v_ip INET;
    v_user_agent TEXT;
    v_request_id UUID;
    v_modulo VARCHAR(50);
    v_accesos_nuevos JSONB;
    v_accesos_viejos JSONB;
    v_datos_completos JSONB;
    v_datos_anteriores_completos JSONB;
BEGIN
    -- Obtener contexto de la aplicación
    v_usuario_id := NULLIF(current_setting('app.usuario_id', true), '')::BIGINT;
    v_usuario_login := NULLIF(current_setting('app.usuario_login', true), '');
    v_usuario_nombre := NULLIF(current_setting('app.usuario_nombre', true), '');
    v_ip := NULLIF(current_setting('app.ip_address', true), '')::INET;
    v_user_agent := NULLIF(current_setting('app.user_agent', true), '');
    v_request_id := NULLIF(current_setting('app.request_id', true), '')::UUID;
    v_modulo := NULLIF(current_setting('app.modulo', true), '');
    
    -- Obtener accesos del contexto (solo para tabla perfiles)
    IF TG_TABLE_NAME = 'perfiles' THEN
        v_accesos_nuevos := NULLIF(current_setting('app.accesos_nuevos', true), '')::JSONB;
        v_accesos_viejos := NULLIF(current_setting('app.accesos_viejos', true), '')::JSONB;
    END IF;
    
    -- Si no hay usuario desde aplicación, usar el usuario de BD
    IF v_usuario_login IS NULL THEN
        v_usuario_login := current_user;
        v_usuario_nombre := current_user;
        v_user_agent := 'DIRECT_DB_OPERATION';
    END IF;
    
    IF v_modulo IS NULL THEN
        v_modulo := TG_TABLE_SCHEMA || '.' || TG_TABLE_NAME;
    END IF;
    
    -- INSERT
    IF TG_OP = 'INSERT' THEN
        
        -- Para la tabla perfiles, construir JSON con accesos del contexto
        IF TG_TABLE_NAME = 'perfiles' AND v_accesos_nuevos IS NOT NULL THEN
            v_datos_completos := jsonb_build_object(
                'id', NEW.id,
                'nombre', NEW.nombre,
                'inactividad', NEW.inactividad,
                'activo', NEW.activo,
                'created_by', NEW.created_by,
                'updated_by', NEW.updated_by,
                'created_at', to_char(NEW.created_at, 'YYYY-MM-DD HH24:MI:SS'),
                'updated_at', to_char(NEW.updated_at, 'YYYY-MM-DD HH24:MI:SS'),
                'acceso', v_accesos_nuevos
            );
        ELSE
            -- Para otras tablas, usar solo la fila
            v_datos_completos := row_to_json(NEW)::JSONB;
        END IF;
        
        INSERT INTO auditoria.logs_cambios (
            schema_nombre, tabla_nombre, registro_id, operacion,
            datos_nuevos,
            usuario_id, usuario_login, usuario_nombre,
            ip_address, user_agent, request_id, modulo,
            fecha_operacion
        ) VALUES (
            TG_TABLE_SCHEMA, TG_TABLE_NAME, NEW.id, 'INSERT',
            v_datos_completos,
            v_usuario_id, v_usuario_login, v_usuario_nombre,
            v_ip, v_user_agent, v_request_id, v_modulo,
            CURRENT_TIMESTAMP
        );
        RETURN NEW;
    
    -- UPDATE
    ELSIF TG_OP = 'UPDATE' THEN
        IF NEW IS DISTINCT FROM OLD THEN
            
            -- Para la tabla perfiles, construir JSON con accesos del contexto
            IF TG_TABLE_NAME = 'perfiles' THEN
                -- Datos nuevos con accesos nuevos
                IF v_accesos_nuevos IS NOT NULL THEN
                    v_datos_completos := jsonb_build_object(
                        'id', NEW.id,
                        'nombre', NEW.nombre,
                        'inactividad', NEW.inactividad,
                        'activo', NEW.activo,
                        'created_by', NEW.created_by,
                        'updated_by', NEW.updated_by,
                        'created_at', to_char(NEW.created_at, 'YYYY-MM-DD HH24:MI:SS'),
                        'updated_at', to_char(NEW.updated_at, 'YYYY-MM-DD HH24:MI:SS'),
                        'acceso', v_accesos_nuevos
                    );
                ELSE
                    v_datos_completos := row_to_json(NEW)::JSONB;
                END IF;
                
                -- Datos anteriores con accesos viejos
                IF v_accesos_viejos IS NOT NULL THEN
                    v_datos_anteriores_completos := jsonb_build_object(
                        'id', OLD.id,
                        'nombre', OLD.nombre,
                        'inactividad', OLD.inactividad,
                        'activo', OLD.activo,
                        'created_by', OLD.created_by,
                        'updated_by', OLD.updated_by,
                        'created_at', to_char(OLD.created_at, 'YYYY-MM-DD HH24:MI:SS'),
                        'updated_at', to_char(OLD.updated_at, 'YYYY-MM-DD HH24:MI:SS'),
                        'acceso', v_accesos_viejos
                    );
                ELSE
                    v_datos_anteriores_completos := row_to_json(OLD)::JSONB;
                END IF;
            ELSE
                v_datos_completos := row_to_json(NEW)::JSONB;
                v_datos_anteriores_completos := row_to_json(OLD)::JSONB;
            END IF;
            
            INSERT INTO auditoria.logs_cambios (
                schema_nombre, tabla_nombre, registro_id, operacion,
                datos_anteriores, datos_nuevos,
                usuario_id, usuario_login, usuario_nombre,
                ip_address, user_agent, request_id, modulo,
                fecha_operacion
            ) VALUES (
                TG_TABLE_SCHEMA, TG_TABLE_NAME, NEW.id, 'UPDATE',
                v_datos_anteriores_completos, v_datos_completos,
                v_usuario_id, v_usuario_login, v_usuario_nombre,
                v_ip, v_user_agent, v_request_id, v_modulo,
                CURRENT_TIMESTAMP
            );
        END IF;
        RETURN NEW;
    
    -- DELETE
    ELSIF TG_OP = 'DELETE' THEN
        
        -- Para DELETE, también podemos incluir los accesos si están en contexto
        IF TG_TABLE_NAME = 'perfiles' AND v_accesos_viejos IS NOT NULL THEN
            v_datos_anteriores_completos := jsonb_build_object(
                'id', OLD.id,
                'nombre', OLD.nombre,
                'inactividad', OLD.inactividad,
                'activo', OLD.activo,
                'created_by', OLD.created_by,
                'updated_by', OLD.updated_by,
                'created_at', to_char(OLD.created_at, 'YYYY-MM-DD HH24:MI:SS'),
                'updated_at', to_char(OLD.updated_at, 'YYYY-MM-DD HH24:MI:SS'),
                'acceso', v_accesos_viejos
            );
        ELSE
            v_datos_anteriores_completos := row_to_json(OLD)::JSONB;
        END IF;
        
        INSERT INTO auditoria.logs_cambios (
            schema_nombre, tabla_nombre, registro_id, operacion,
            datos_anteriores,
            usuario_id, usuario_login, usuario_nombre,
            ip_address, user_agent, request_id, modulo,
            fecha_operacion
        ) VALUES (
            TG_TABLE_SCHEMA, TG_TABLE_NAME, OLD.id, 'DELETE',
            v_datos_anteriores_completos,
            v_usuario_id, v_usuario_login, v_usuario_nombre,
            v_ip, v_user_agent, v_request_id, v_modulo,
            CURRENT_TIMESTAMP
        );
        RETURN OLD;
    END IF;
    
    RETURN NULL;
END;
$BODY$;





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





-- FUNCIÓN: auditoria.fn_listar_particiones
CREATE OR REPLACE FUNCTION auditoria.fn_listar_particiones()
RETURNS JSONB AS $$
DECLARE
    v_resultado JSONB;
BEGIN
    SELECT jsonb_agg(
        jsonb_build_object(
            'particion', c.relname,
            'tamano', pg_size_pretty(pg_total_relation_size(c.oid)),
            'filas', c.reltuples::BIGINT,
            'desde', split_part(pg_get_expr(c.relpartbound, c.oid), 'FROM (', 2),
            'hasta', split_part(split_part(pg_get_expr(c.relpartbound, c.oid), 'TO (', 2), ')', 1)
        ) ORDER BY c.relname DESC
    ) INTO v_resultado
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE c.relname LIKE 'logs_cambios_%'
      AND c.relkind = 'r'
      AND n.nspname = 'auditoria';
    
    RETURN COALESCE(v_resultado, '[]'::jsonb);
END;
$$ LANGUAGE plpgsql;
-- Ver todas las particiones
SELECT auditoria.fn_listar_particiones();






-- FUNCIÓN: auditoria.fn_crear_particion_mes_siguiente
-- Crea la partición para el próximo mes si no existe
CREATE OR REPLACE FUNCTION auditoria.fn_crear_particion_mes_siguiente()
RETURNS JSONB AS $$
DECLARE
    v_fecha_inicio DATE;
    v_fecha_fin DATE;
    v_nombre_particion TEXT;
    v_mes_actual TEXT;
    v_resultado JSONB;
    v_existe BOOLEAN;
BEGIN
    -- Calcular primer día del próximo mes
    v_fecha_inicio := date_trunc('month', CURRENT_DATE + INTERVAL '1 month');
    v_fecha_fin := v_fecha_inicio + INTERVAL '1 month';
    v_mes_actual := to_char(v_fecha_inicio, 'YYYY_MM');
    v_nombre_particion := 'logs_cambios_' || v_mes_actual;
    
    -- Verificar si la partición ya existe
    SELECT EXISTS(
        SELECT 1 FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'auditoria' 
          AND c.relname = v_nombre_particion
          AND c.relkind = 'r'
    ) INTO v_existe;
    
    IF NOT v_existe THEN
        -- Crear la partición
        EXECUTE format('
            CREATE TABLE IF NOT EXISTS auditoria.fn_%I PARTITION OF auditoria.logs_cambios
            FOR VALUES FROM (%L) TO (%L)',
            v_nombre_particion,
            v_fecha_inicio,
            v_fecha_fin
        );
        
        -- Crear índices en la nueva partición (opcional, se heredan automáticamente)
        EXECUTE format('
            CREATE INDEX IF NOT EXISTS idx_%I_registro ON auditoria.fn_%I (schema_nombre, tabla_nombre, registro_id)',
            v_nombre_particion, v_nombre_particion
        );
        
        EXECUTE format('
            CREATE INDEX IF NOT EXISTS idx_%I_fecha ON auditoria.fn_%I (fecha_operacion)',
            v_nombre_particion, v_nombre_particion
        );
        
        v_resultado := jsonb_build_object(
            'success', true,
            'message', 'Partición creada exitosamente',
            'particion', v_nombre_particion,
            'desde', v_fecha_inicio,
            'hasta', v_fecha_fin
        );
    ELSE
        v_resultado := jsonb_build_object(
            'success', false,
            'message', 'La partición ya existe',
            'particion', v_nombre_particion,
            'desde', v_fecha_inicio,
            'hasta', v_fecha_fin
        );
    END IF;
    
    RETURN v_resultado;
    
EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object(
            'success', false,
            'message', 'Error al crear partición: ' || SQLERRM,
            'error_code', SQLSTATE
        );
END;
$$ LANGUAGE plpgsql;
-- Crear partición para el próximo mes
SELECT auditoria.fn_crear_particion_mes_siguiente();






-- FUNCIÓN: auditoria.fn_archivar_particiones_viejas
-- Detacha particiones más antiguas que X meses
CREATE OR REPLACE FUNCTION auditoria.fn_archivar_particiones_viejas(
    p_meses_a_mantener INTEGER DEFAULT 12
)
RETURNS JSONB AS $$
DECLARE
    v_fecha_limite DATE;
    v_particion RECORD;
    v_resultado JSONB := '[]'::jsonb;
    v_fecha_particion DATE;
    v_anio INTEGER;
    v_mes INTEGER;
BEGIN
    -- Calcular fecha límite (primer día del mes, hace N meses)
    v_fecha_limite := date_trunc('month', CURRENT_DATE - (p_meses_a_mantener || ' months')::INTERVAL);
    
    -- Buscar particiones
    FOR v_particion IN 
        SELECT 
            c.relname as partition_name,
            pg_get_expr(c.relpartbound, c.oid) as range
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE c.relname LIKE 'logs_cambios_%'
          AND c.relkind = 'r'
          AND n.nspname = 'auditoria'
        ORDER BY c.relname
    LOOP
        -- Extraer año y mes del nombre de la partición (formato: logs_cambios_2026_03)
        BEGIN
            v_anio := split_part(v_particion.partition_name, '_', 3)::INTEGER;
            v_mes := split_part(v_particion.partition_name, '_', 4)::INTEGER;
            v_fecha_particion := make_date(v_anio, v_mes, 1);
            
            -- Si la partición es anterior a la fecha límite
            IF v_fecha_particion < v_fecha_limite THEN
                -- Detachar la partición (separar de la tabla principal)
                EXECUTE format('ALTER TABLE auditoria.logs_cambios DETACH PARTITION auditoria.fn_%I', 
                              v_particion.partition_name);
                
                v_resultado := v_resultado || jsonb_build_object(
                    'particion', v_particion.partition_name,
                    'fecha_particion', v_fecha_particion,
                    'accion', 'DETACHED',
                    'fecha_limite', v_fecha_limite,
                    'meses_a_mantener', p_meses_a_mantener
                );
            END IF;
        EXCEPTION WHEN OTHERS THEN
            -- Si no se puede parsear, continuar con la siguiente
            v_resultado := v_resultado || jsonb_build_object(
                'particion', v_particion.partition_name,
                'error', 'No se pudo parsear la fecha',
                'accion', 'SKIPPED'
            );
        END;
    END LOOP;
    
    RETURN v_resultado;
END;
$$ LANGUAGE plpgsql;
-- Archivar particiones con más de 12 meses
SELECT auditoria.fn_archivar_particiones_viejas(12);





-- Ver auditoría completa
SELECT * FROM auditoria.logs_cambios  
--WHERE tabla_nombre = 'departamentos' --AND registro_id = 1 
ORDER BY fecha_operacion DESC;

SELECT 
    fecha_operacion,
    operacion,
    usuario_login,
    usuario_nombre,
    ip_address,
    datos_anteriores->>'nombre' AS nombre_anterior,
    datos_nuevos->>'nombre' AS nombre_nuevo
FROM auditoria.logs_cambios 
WHERE tabla_nombre = 'departamentos' AND registro_id = 1 
ORDER BY fecha_operacion DESC;





