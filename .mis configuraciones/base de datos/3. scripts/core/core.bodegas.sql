-- Table: core.bodegas

-- DROP TABLE IF EXISTS core.bodegas;

CREATE TABLE IF NOT EXISTS core.bodegas
(
    id bigserial NOT NULL,
    sucursal_id bigint NOT NULL,
    codigo character varying(20) COLLATE pg_catalog."default" NOT NULL,
    nombre character varying(100) COLLATE pg_catalog."default" NOT NULL,
    direccion text COLLATE pg_catalog."default",
    activo boolean DEFAULT true,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    created_by character varying(100) COLLATE pg_catalog."default",
    updated_by character varying(100) COLLATE pg_catalog."default",
    CONSTRAINT pk_bodegas PRIMARY KEY (id),
    CONSTRAINT uk_bodegas_codigo UNIQUE (codigo),
    CONSTRAINT fk_sucursales_bodegas_id FOREIGN KEY (sucursal_id)
        REFERENCES core.sucursales (id) MATCH SIMPLE
        ON UPDATE NO ACTION
        ON DELETE NO ACTION
)

TABLESPACE pg_default;

ALTER TABLE IF EXISTS core.bodegas
    OWNER to postgres;
-- Index: idx_bodegas_activo

-- DROP INDEX IF EXISTS core.idx_bodegas_activo;

CREATE INDEX IF NOT EXISTS idx_bodegas_activo
    ON core.bodegas USING btree
    (activo ASC NULLS LAST)
    TABLESPACE pg_default
    WHERE activo = true;

-- Trigger: trg_bodegas_audit

-- DROP TRIGGER IF EXISTS trg_bodegas_audit ON core.bodegas;

CREATE OR REPLACE TRIGGER trg_bodegas_audit
    AFTER INSERT OR DELETE OR UPDATE 
    ON core.bodegas
    FOR EACH ROW
    EXECUTE FUNCTION auditoria.fn_auditar_cambios();

-- Trigger: trigger_bodegas_set_users

-- DROP TRIGGER IF EXISTS trigger_bodegas_set_users ON core.bodegas;

CREATE OR REPLACE TRIGGER trigger_bodegas_set_users
    BEFORE INSERT OR UPDATE 
    ON core.bodegas
    FOR EACH ROW
    EXECUTE FUNCTION auditoria.fn_set_audit_users();

-- Trigger: trigger_bodegas_updated_at

-- DROP TRIGGER IF EXISTS trigger_bodegas_updated_at ON core.bodegas;

CREATE OR REPLACE TRIGGER trigger_bodegas_updated_at
    BEFORE UPDATE 
    ON core.bodegas
    FOR EACH ROW
    EXECUTE FUNCTION auditoria.fn_update_updated_at_column();