-- FUNCTION: auditoria.fn_auditar_cambios()

-- DROP FUNCTION IF EXISTS auditoria.fn_auditar_cambios();

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
    v_datos_nuevos JSONB;
    v_datos_anteriores JSONB;
BEGIN
    -- Obtener contexto de la aplicación
    v_usuario_id := NULLIF(current_setting('app.usuario_id', true), '')::BIGINT;
    v_usuario_login := NULLIF(current_setting('app.usuario_login', true), '');
    v_usuario_nombre := NULLIF(current_setting('app.usuario_nombre', true), '');
    v_ip := NULLIF(current_setting('app.ip_address', true), '')::INET;
    v_user_agent := NULLIF(current_setting('app.user_agent', true), '');
    v_request_id := NULLIF(current_setting('app.request_id', true), '')::UUID;
    v_modulo := NULLIF(current_setting('app.modulo', true), '');
    
    -- Obtener datos del contexto (usando nombres consistentes)
    -- Para datos NUEVOS: app.datos_nuevos
    -- Para datos ANTERIORES: app.datos_anteriores
    BEGIN
        v_datos_nuevos := NULLIF(current_setting('app.datos_nuevos', true), '')::JSONB;
    EXCEPTION WHEN OTHERS THEN
        v_datos_nuevos := NULL;
    END;
    
    BEGIN
        v_datos_anteriores := NULLIF(current_setting('app.datos_anteriores', true), '')::JSONB;
    EXCEPTION WHEN OTHERS THEN
        v_datos_anteriores := NULL;
    END;
    
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
        IF v_datos_nuevos IS NULL THEN
            v_datos_nuevos := row_to_json(NEW)::JSONB;
        END IF;
        
        INSERT INTO auditoria.logs_cambios (
            schema_nombre, tabla_nombre, registro_id, operacion,
            datos_nuevos,
            usuario_id, usuario_login, usuario_nombre,
            ip_address, user_agent, request_id, modulo,
            fecha_operacion
        ) VALUES (
            TG_TABLE_SCHEMA, TG_TABLE_NAME, NEW.id, 'INSERT',
            v_datos_nuevos,
            v_usuario_id, v_usuario_login, v_usuario_nombre,
            v_ip, v_user_agent, v_request_id, v_modulo,
            CURRENT_TIMESTAMP
        );
        RETURN NEW;
    
    -- UPDATE
    ELSIF TG_OP = 'UPDATE' THEN
        IF NEW IS DISTINCT FROM OLD THEN
            IF v_datos_nuevos IS NULL THEN
                v_datos_nuevos := row_to_json(NEW)::JSONB;
            END IF;
            
            IF v_datos_anteriores IS NULL THEN
                v_datos_anteriores := row_to_json(OLD)::JSONB;
            END IF;
            
            INSERT INTO auditoria.logs_cambios (
                schema_nombre, tabla_nombre, registro_id, operacion,
                datos_anteriores, datos_nuevos,
                usuario_id, usuario_login, usuario_nombre,
                ip_address, user_agent, request_id, modulo,
                fecha_operacion
            ) VALUES (
                TG_TABLE_SCHEMA, TG_TABLE_NAME, NEW.id, 'UPDATE',
                v_datos_anteriores, v_datos_nuevos,
                v_usuario_id, v_usuario_login, v_usuario_nombre,
                v_ip, v_user_agent, v_request_id, v_modulo,
                CURRENT_TIMESTAMP
            );
        END IF;
        RETURN NEW;
    
    -- DELETE
    ELSIF TG_OP = 'DELETE' THEN
        IF v_datos_anteriores IS NULL THEN
            v_datos_anteriores := row_to_json(OLD)::JSONB;
        END IF;
        
        INSERT INTO auditoria.logs_cambios (
            schema_nombre, tabla_nombre, registro_id, operacion,
            datos_anteriores,
            usuario_id, usuario_login, usuario_nombre,
            ip_address, user_agent, request_id, modulo,
            fecha_operacion
        ) VALUES (
            TG_TABLE_SCHEMA, TG_TABLE_NAME, OLD.id, 'DELETE',
            v_datos_anteriores,
            v_usuario_id, v_usuario_login, v_usuario_nombre,
            v_ip, v_user_agent, v_request_id, v_modulo,
            CURRENT_TIMESTAMP
        );
        RETURN OLD;
    END IF;
    
    RETURN NULL;
END;
$BODY$;

ALTER FUNCTION auditoria.fn_auditar_cambios()
    OWNER TO postgres;
