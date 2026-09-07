-- Table: rh.cargos

-- DROP TABLE IF EXISTS rh.cargos;

CREATE TABLE IF NOT EXISTS rh.cargos
(
    id bigserial NOT NULL,
    nombre character varying(100) COLLATE pg_catalog."default" NOT NULL,
    descripcion text COLLATE pg_catalog."default",
    nivel character varying(50) COLLATE pg_catalog."default",
    salario_base numeric(12,2),
    activo boolean DEFAULT true,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    created_by character varying(100) COLLATE pg_catalog."default",
    updated_by character varying(100) COLLATE pg_catalog."default",
    CONSTRAINT pk_cargos PRIMARY KEY (id),
    CONSTRAINT uk_cargos_nombre UNIQUE (nombre),
    CONSTRAINT ck_cargos_nombre_min CHECK (length(TRIM(BOTH FROM nombre)) >= 3),
    CONSTRAINT ck_cargos_salario_base CHECK (salario_base IS NULL OR salario_base >= 0::numeric)
)

TABLESPACE pg_default;

ALTER TABLE IF EXISTS rh.cargos
    OWNER to postgres;
-- Index: idx_cargos_activo

-- DROP INDEX IF EXISTS rh.idx_cargos_activo;

CREATE INDEX IF NOT EXISTS idx_cargos_activo
    ON rh.cargos USING btree
    (activo ASC NULLS LAST)
    TABLESPACE pg_default
    WHERE activo = true;
-- Index: idx_cargos_nivel

-- DROP INDEX IF EXISTS rh.idx_cargos_nivel;

CREATE INDEX IF NOT EXISTS idx_cargos_nivel
    ON rh.cargos USING btree
    (nivel COLLATE pg_catalog."default" ASC NULLS LAST)
    TABLESPACE pg_default;

-- Trigger: trg_cargos_audit

-- DROP TRIGGER IF EXISTS trg_cargos_audit ON rh.cargos;

CREATE OR REPLACE TRIGGER trg_cargos_audit
    AFTER INSERT OR DELETE OR UPDATE 
    ON rh.cargos
    FOR EACH ROW
    EXECUTE FUNCTION auditoria.fn_auditar_cambios();

-- Trigger: trigger_cargos_set_users

-- DROP TRIGGER IF EXISTS trigger_cargos_set_users ON rh.cargos;

CREATE OR REPLACE TRIGGER trigger_cargos_set_users
    BEFORE INSERT OR UPDATE 
    ON rh.cargos
    FOR EACH ROW
    EXECUTE FUNCTION auditoria.fn_set_audit_users();

-- Trigger: trigger_cargos_updated_at

-- DROP TRIGGER IF EXISTS trigger_cargos_updated_at ON rh.cargos;

CREATE OR REPLACE TRIGGER trigger_cargos_updated_at
    BEFORE UPDATE 
    ON rh.cargos
    FOR EACH ROW
    EXECUTE FUNCTION auditoria.fn_update_updated_at_column();