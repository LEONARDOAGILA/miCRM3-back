-- Table: rh.departamentos

-- DROP TABLE IF EXISTS rh.departamentos;

CREATE TABLE IF NOT EXISTS rh.departamentos
(
    id bigserial NOT NULL,
    nombre character varying(100) COLLATE pg_catalog."default" NOT NULL,
    descripcion text COLLATE pg_catalog."default",
    codigo character varying(20) COLLATE pg_catalog."default",
    empleado_id bigint,
    activo boolean DEFAULT true,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    created_by character varying(100) COLLATE pg_catalog."default",
    updated_by character varying(100) COLLATE pg_catalog."default",
    prueba boolean DEFAULT true,
    CONSTRAINT pk_departamentos PRIMARY KEY (id),
    CONSTRAINT uk_departamentos_codigo UNIQUE (codigo),
    CONSTRAINT uk_departamentos_nombre UNIQUE (nombre),
    CONSTRAINT ck_departamentos_nombre_min CHECK (length(TRIM(BOTH FROM nombre)) >= 3)
)

TABLESPACE pg_default;

ALTER TABLE IF EXISTS rh.departamentos
    OWNER to postgres;
-- Index: idx_departamentos_activo

-- DROP INDEX IF EXISTS rh.idx_departamentos_activo;

CREATE INDEX IF NOT EXISTS idx_departamentos_activo
    ON rh.departamentos USING btree
    (activo ASC NULLS LAST)
    TABLESPACE pg_default
    WHERE activo = true;

-- Trigger: trg_departamentos_audit

-- DROP TRIGGER IF EXISTS trg_departamentos_audit ON rh.departamentos;

CREATE OR REPLACE TRIGGER trg_departamentos_audit
    AFTER INSERT OR DELETE OR UPDATE 
    ON rh.departamentos
    FOR EACH ROW
    EXECUTE FUNCTION auditoria.fn_auditar_cambios();

-- Trigger: trigger_departamentos_set_users

-- DROP TRIGGER IF EXISTS trigger_departamentos_set_users ON rh.departamentos;

CREATE OR REPLACE TRIGGER trigger_departamentos_set_users
    BEFORE INSERT OR UPDATE 
    ON rh.departamentos
    FOR EACH ROW
    EXECUTE FUNCTION auditoria.fn_set_audit_users();

-- Trigger: trigger_departamentos_updated_at

-- DROP TRIGGER IF EXISTS trigger_departamentos_updated_at ON rh.departamentos;

CREATE OR REPLACE TRIGGER trigger_departamentos_updated_at
    BEFORE UPDATE 
    ON rh.departamentos
    FOR EACH ROW
    EXECUTE FUNCTION auditoria.fn_update_updated_at_column();