-- FUNCTION: auditoria.fn_set_audit_users()

-- DROP FUNCTION IF EXISTS auditoria.fn_set_audit_users();

CREATE OR REPLACE FUNCTION auditoria.fn_set_audit_users()
    RETURNS trigger
    LANGUAGE 'plpgsql'
    COST 100
    VOLATILE NOT LEAKPROOF
AS $BODY$
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
$BODY$;

ALTER FUNCTION auditoria.fn_set_audit_users()
    OWNER TO postgres;
