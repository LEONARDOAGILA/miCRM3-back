-- Table: seguridad.chorarios

-- DROP TABLE IF EXISTS seguridad.chorarios;

CREATE TABLE IF NOT EXISTS seguridad.chorarios
(
    id bigserial NOT NULL,
    nombre character varying(100) COLLATE pg_catalog."default" NOT NULL,
    activo boolean DEFAULT true,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    created_by character varying(100) COLLATE pg_catalog."default",
    updated_by character varying(100) COLLATE pg_catalog."default",
    CONSTRAINT pk_chorarios PRIMARY KEY (id)
)

TABLESPACE pg_default;

ALTER TABLE IF EXISTS seguridad.chorarios
    OWNER to postgres;
-- Index: idx_chorarios_activo

-- DROP INDEX IF EXISTS seguridad.idx_chorarios_activo;

CREATE INDEX IF NOT EXISTS idx_chorarios_activo
    ON seguridad.chorarios USING btree
    (activo ASC NULLS LAST)
    TABLESPACE pg_default;

-- Trigger: trg_chorarios_audit

-- DROP TRIGGER IF EXISTS trg_chorarios_audit ON seguridad.chorarios;

CREATE OR REPLACE TRIGGER trg_chorarios_audit
    AFTER INSERT OR DELETE OR UPDATE 
    ON seguridad.chorarios
    FOR EACH ROW
    EXECUTE FUNCTION auditoria.fn_auditar_cambios();

-- Trigger: trigger_chorarios_set_users

-- DROP TRIGGER IF EXISTS trigger_chorarios_set_users ON seguridad.chorarios;

CREATE OR REPLACE TRIGGER trigger_chorarios_set_users
    BEFORE INSERT OR UPDATE 
    ON seguridad.chorarios
    FOR EACH ROW
    EXECUTE FUNCTION auditoria.fn_set_audit_users();

-- Trigger: trigger_chorarios_updated_at

-- DROP TRIGGER IF EXISTS trigger_chorarios_updated_at ON seguridad.chorarios;

CREATE OR REPLACE TRIGGER trigger_chorarios_updated_at
    BEFORE UPDATE 
    ON seguridad.chorarios
    FOR EACH ROW
    EXECUTE FUNCTION auditoria.fn_update_updated_at_column();