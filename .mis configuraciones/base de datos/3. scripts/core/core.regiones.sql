-- Table: core.regiones

-- DROP TABLE IF EXISTS core.regiones;

CREATE TABLE IF NOT EXISTS core.regiones
(
    id bigserial NOT NULL,
    codigo character varying(20) COLLATE pg_catalog."default" NOT NULL,
    nombre character varying(100) COLLATE pg_catalog."default" NOT NULL,
    activo boolean DEFAULT true,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    created_by character varying(100) COLLATE pg_catalog."default",
    updated_by character varying(100) COLLATE pg_catalog."default",
    CONSTRAINT pk_regiones PRIMARY KEY (id),
    CONSTRAINT uk_regiones_codigo UNIQUE (codigo)
)

TABLESPACE pg_default;

ALTER TABLE IF EXISTS core.regiones
    OWNER to postgres;
-- Index: idx_regiones_activo

-- DROP INDEX IF EXISTS core.idx_regiones_activo;

CREATE INDEX IF NOT EXISTS idx_regiones_activo
    ON core.regiones USING btree
    (activo ASC NULLS LAST)
    TABLESPACE pg_default
    WHERE activo = true;

-- Trigger: trg_regiones_audit

-- DROP TRIGGER IF EXISTS trg_regiones_audit ON core.regiones;

CREATE OR REPLACE TRIGGER trg_regiones_audit
    AFTER INSERT OR DELETE OR UPDATE 
    ON core.regiones
    FOR EACH ROW
    EXECUTE FUNCTION auditoria.fn_auditar_cambios();

-- Trigger: trigger_regiones_set_users

-- DROP TRIGGER IF EXISTS trigger_regiones_set_users ON core.regiones;

CREATE OR REPLACE TRIGGER trigger_regiones_set_users
    BEFORE INSERT OR UPDATE 
    ON core.regiones
    FOR EACH ROW
    EXECUTE FUNCTION auditoria.fn_set_audit_users();

-- Trigger: trigger_regiones_updated_at

-- DROP TRIGGER IF EXISTS trigger_regiones_updated_at ON core.regiones;

CREATE OR REPLACE TRIGGER trigger_regiones_updated_at
    BEFORE UPDATE 
    ON core.regiones
    FOR EACH ROW
    EXECUTE FUNCTION auditoria.fn_update_updated_at_column();