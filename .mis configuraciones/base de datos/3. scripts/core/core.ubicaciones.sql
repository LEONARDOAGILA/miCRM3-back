-- Table: core.ubicaciones

-- DROP TABLE IF EXISTS core.ubicaciones;

CREATE TABLE IF NOT EXISTS core.ubicaciones
(
    id bigserial NOT NULL,
    padre_id bigint,
    codigo character varying(20) COLLATE pg_catalog."default" NOT NULL,
    tipo character varying(20) COLLATE pg_catalog."default" NOT NULL,
    nombre character varying(100) COLLATE pg_catalog."default" NOT NULL,
    nombre_oficial character varying(200) COLLATE pg_catalog."default",
    capital boolean DEFAULT false,
    latitud numeric(11,8),
    longitud numeric(11,8),
    activo boolean DEFAULT true,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    created_by character varying(100) COLLATE pg_catalog."default",
    updated_by character varying(100) COLLATE pg_catalog."default",
    CONSTRAINT pk_ubicaciones PRIMARY KEY (id),
    CONSTRAINT uk_ubicaciones_codigo UNIQUE (codigo),
    CONSTRAINT fk_ubicaciones_padre FOREIGN KEY (padre_id)
        REFERENCES core.ubicaciones (id) MATCH SIMPLE
        ON UPDATE NO ACTION
        ON DELETE RESTRICT,
    CONSTRAINT chk_ubicaciones_tipo CHECK (tipo::text = ANY (ARRAY['PAIS'::character varying::text, 'PROVINCIA'::character varying::text, 'CANTON'::character varying::text, 'PARROQUIA'::character varying::text]))
)

TABLESPACE pg_default;

ALTER TABLE IF EXISTS core.ubicaciones
    OWNER to postgres;
-- Index: idx_ubicaciones_codigo

-- DROP INDEX IF EXISTS core.idx_ubicaciones_codigo;

CREATE INDEX IF NOT EXISTS idx_ubicaciones_codigo
    ON core.ubicaciones USING btree
    (codigo COLLATE pg_catalog."default" ASC NULLS LAST)
    TABLESPACE pg_default;
-- Index: idx_ubicaciones_nombre

-- DROP INDEX IF EXISTS core.idx_ubicaciones_nombre;

CREATE INDEX IF NOT EXISTS idx_ubicaciones_nombre
    ON core.ubicaciones USING btree
    (nombre COLLATE pg_catalog."default" ASC NULLS LAST)
    TABLESPACE pg_default;
-- Index: idx_ubicaciones_padre_id

-- DROP INDEX IF EXISTS core.idx_ubicaciones_padre_id;

CREATE INDEX IF NOT EXISTS idx_ubicaciones_padre_id
    ON core.ubicaciones USING btree
    (padre_id ASC NULLS LAST)
    TABLESPACE pg_default;
-- Index: idx_ubicaciones_tipo

-- DROP INDEX IF EXISTS core.idx_ubicaciones_tipo;

CREATE INDEX IF NOT EXISTS idx_ubicaciones_tipo
    ON core.ubicaciones USING btree
    (tipo COLLATE pg_catalog."default" ASC NULLS LAST)
    TABLESPACE pg_default;

-- Trigger: trg_ubicaciones_audit

-- DROP TRIGGER IF EXISTS trg_ubicaciones_audit ON core.ubicaciones;

CREATE OR REPLACE TRIGGER trg_ubicaciones_audit
    AFTER INSERT OR DELETE OR UPDATE 
    ON core.ubicaciones
    FOR EACH ROW
    EXECUTE FUNCTION auditoria.fn_auditar_cambios();

-- Trigger: trigger_ubicaciones_set_users

-- DROP TRIGGER IF EXISTS trigger_ubicaciones_set_users ON core.ubicaciones;

CREATE OR REPLACE TRIGGER trigger_ubicaciones_set_users
    BEFORE INSERT OR UPDATE 
    ON core.ubicaciones
    FOR EACH ROW
    EXECUTE FUNCTION auditoria.fn_set_audit_users();

-- Trigger: trigger_ubicaciones_updated_at

-- DROP TRIGGER IF EXISTS trigger_ubicaciones_updated_at ON core.ubicaciones;

CREATE OR REPLACE TRIGGER trigger_ubicaciones_updated_at
    BEFORE UPDATE 
    ON core.ubicaciones
    FOR EACH ROW
    EXECUTE FUNCTION auditoria.fn_update_updated_at_column();