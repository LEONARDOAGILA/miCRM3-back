-- Table: seguridad.perfiles

-- DROP TABLE IF EXISTS seguridad.perfiles;

CREATE TABLE IF NOT EXISTS seguridad.perfiles
(
    id bigserial NOT NULL,
    nombre character varying(100) COLLATE pg_catalog."default" NOT NULL,
    activo boolean DEFAULT true,
    inactividad integer DEFAULT 60,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    created_by character varying(30) COLLATE pg_catalog."default",
    updated_by character varying(30) COLLATE pg_catalog."default",
    CONSTRAINT pk_perfiles PRIMARY KEY (id),
    CONSTRAINT uk_nombre_perfiles UNIQUE (nombre)
)

TABLESPACE pg_default;

ALTER TABLE IF EXISTS seguridad.perfiles
    OWNER to postgres;
-- Index: idx_perfiles_activo

-- DROP INDEX IF EXISTS seguridad.idx_perfiles_activo;

CREATE INDEX IF NOT EXISTS idx_perfiles_activo
    ON seguridad.perfiles USING btree
    (activo ASC NULLS LAST)
    TABLESPACE pg_default;
-- Index: idx_perfiles_inactividad

-- DROP INDEX IF EXISTS seguridad.idx_perfiles_inactividad;

CREATE INDEX IF NOT EXISTS idx_perfiles_inactividad
    ON seguridad.perfiles USING btree
    (inactividad ASC NULLS LAST)
    TABLESPACE pg_default;

-- Trigger: trg_perfiles_audit

-- DROP TRIGGER IF EXISTS trg_perfiles_audit ON seguridad.perfiles;

CREATE OR REPLACE TRIGGER trg_perfiles_audit
    AFTER INSERT OR DELETE OR UPDATE 
    ON seguridad.perfiles
    FOR EACH ROW
    EXECUTE FUNCTION auditoria.fn_auditar_cambios();

-- Trigger: trigger_perfiles_set_users

-- DROP TRIGGER IF EXISTS trigger_perfiles_set_users ON seguridad.perfiles;

CREATE OR REPLACE TRIGGER trigger_perfiles_set_users
    BEFORE INSERT OR UPDATE 
    ON seguridad.perfiles
    FOR EACH ROW
    EXECUTE FUNCTION auditoria.fn_set_audit_users();

-- Trigger: trigger_perfiles_updated_at

-- DROP TRIGGER IF EXISTS trigger_perfiles_updated_at ON seguridad.perfiles;

CREATE OR REPLACE TRIGGER trigger_perfiles_updated_at
    BEFORE UPDATE 
    ON seguridad.perfiles
    FOR EACH ROW
    EXECUTE FUNCTION auditoria.fn_update_updated_at_column();