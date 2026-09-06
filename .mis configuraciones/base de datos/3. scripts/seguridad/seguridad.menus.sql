-- Table: seguridad.menus

-- DROP TABLE IF EXISTS seguridad.menus;

CREATE TABLE IF NOT EXISTS seguridad.menus
(
    id bigserial NOT NULL,
    padre_id bigint,
    orden integer DEFAULT 0,
    nivel integer DEFAULT 0,
    nombre character varying(100) COLLATE pg_catalog."default" NOT NULL,
    url character varying(255) COLLATE pg_catalog."default",
    descripcion character varying(255) COLLATE pg_catalog."default",
    etiqueta character varying(100) COLLATE pg_catalog."default",
    icono character varying(50) COLLATE pg_catalog."default",
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    created_by character varying(100) COLLATE pg_catalog."default",
    updated_by character varying(100) COLLATE pg_catalog."default",
    CONSTRAINT pk_menus PRIMARY KEY (id),
    CONSTRAINT fk_menus_padre FOREIGN KEY (padre_id)
        REFERENCES seguridad.menus (id) MATCH SIMPLE
        ON UPDATE NO ACTION
        ON DELETE NO ACTION
)

TABLESPACE pg_default;

ALTER TABLE IF EXISTS seguridad.menus
    OWNER to postgres;
-- Index: idx_menus_nombre

-- DROP INDEX IF EXISTS seguridad.idx_menus_nombre;

CREATE INDEX IF NOT EXISTS idx_menus_nombre
    ON seguridad.menus USING btree
    (nombre COLLATE pg_catalog."default" ASC NULLS LAST)
    TABLESPACE pg_default;
-- Index: idx_menus_padre_id

-- DROP INDEX IF EXISTS seguridad.idx_menus_padre_id;

CREATE INDEX IF NOT EXISTS idx_menus_padre_id
    ON seguridad.menus USING btree
    (padre_id ASC NULLS LAST)
    TABLESPACE pg_default;
-- Index: idx_menus_padre_orden

-- DROP INDEX IF EXISTS seguridad.idx_menus_padre_orden;

CREATE INDEX IF NOT EXISTS idx_menus_padre_orden
    ON seguridad.menus USING btree
    (padre_id ASC NULLS LAST, orden ASC NULLS LAST)
    TABLESPACE pg_default;

-- Trigger: trg_menus_audit

-- DROP TRIGGER IF EXISTS trg_menus_audit ON seguridad.menus;

CREATE OR REPLACE TRIGGER trg_menus_audit
    AFTER INSERT OR DELETE OR UPDATE 
    ON seguridad.menus
    FOR EACH ROW
    EXECUTE FUNCTION auditoria.fn_auditar_cambios();

-- Trigger: trigger_menus_set_users

-- DROP TRIGGER IF EXISTS trigger_menus_set_users ON seguridad.menus;

CREATE OR REPLACE TRIGGER trigger_menus_set_users
    BEFORE INSERT OR UPDATE 
    ON seguridad.menus
    FOR EACH ROW
    EXECUTE FUNCTION auditoria.fn_set_audit_users();

-- Trigger: trigger_menus_updated_at

-- DROP TRIGGER IF EXISTS trigger_menus_updated_at ON seguridad.menus;

CREATE OR REPLACE TRIGGER trigger_menus_updated_at
    BEFORE UPDATE 
    ON seguridad.menus
    FOR EACH ROW
    EXECUTE FUNCTION auditoria.fn_update_updated_at_column();