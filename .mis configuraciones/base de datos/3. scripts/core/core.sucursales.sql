-- Table: core.sucursales

-- DROP TABLE IF EXISTS core.sucursales;

CREATE TABLE IF NOT EXISTS core.sucursales
(
    id bigserial NOT NULL,
    empresa_id bigint NOT NULL,
    codigo character varying(3) COLLATE pg_catalog."default" NOT NULL,
    nombre character varying(100) COLLATE pg_catalog."default" NOT NULL,
    ubicacion_id bigint NOT NULL,
    direccion text COLLATE pg_catalog."default",
    telefono character varying(20) COLLATE pg_catalog."default",
    email character varying(100) COLLATE pg_catalog."default",
    es_matriz boolean DEFAULT false,
    activo boolean DEFAULT true,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    created_by character varying(100) COLLATE pg_catalog."default",
    updated_by character varying(100) COLLATE pg_catalog."default",
    CONSTRAINT pk_sucursales PRIMARY KEY (id),
    CONSTRAINT uk_sucursales_codigo UNIQUE (codigo),
    CONSTRAINT fk_empresa_ubicacion_id FOREIGN KEY (ubicacion_id)
        REFERENCES core.ubicaciones (id) MATCH SIMPLE
        ON UPDATE NO ACTION
        ON DELETE NO ACTION,
    CONSTRAINT fk_empresas_empresa_id FOREIGN KEY (empresa_id)
        REFERENCES core.empresa (id) MATCH SIMPLE
        ON UPDATE NO ACTION
        ON DELETE NO ACTION
)

TABLESPACE pg_default;

ALTER TABLE IF EXISTS core.sucursales
    OWNER to postgres;
-- Index: idx_sucursales_activo

-- DROP INDEX IF EXISTS core.idx_sucursales_activo;

CREATE INDEX IF NOT EXISTS idx_sucursales_activo
    ON core.sucursales USING btree
    (activo ASC NULLS LAST)
    TABLESPACE pg_default
    WHERE activo = true;

-- Trigger: trg_sucursales_audit

-- DROP TRIGGER IF EXISTS trg_sucursales_audit ON core.sucursales;

CREATE OR REPLACE TRIGGER trg_sucursales_audit
    AFTER INSERT OR DELETE OR UPDATE 
    ON core.sucursales
    FOR EACH ROW
    EXECUTE FUNCTION auditoria.fn_auditar_cambios();

-- Trigger: trigger_sucursales_set_users

-- DROP TRIGGER IF EXISTS trigger_sucursales_set_users ON core.sucursales;

CREATE OR REPLACE TRIGGER trigger_sucursales_set_users
    BEFORE INSERT OR UPDATE 
    ON core.sucursales
    FOR EACH ROW
    EXECUTE FUNCTION auditoria.fn_set_audit_users();

-- Trigger: trigger_sucursales_updated_at

-- DROP TRIGGER IF EXISTS trigger_sucursales_updated_at ON core.sucursales;

CREATE OR REPLACE TRIGGER trigger_sucursales_updated_at
    BEFORE UPDATE 
    ON core.sucursales
    FOR EACH ROW
    EXECUTE FUNCTION auditoria.fn_update_updated_at_column();