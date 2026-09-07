-- Table: core.puntos_venta

-- DROP TABLE IF EXISTS core.puntos_venta;

CREATE TABLE IF NOT EXISTS core.puntos_venta
(
    id bigserial NOT NULL,
    sucursal_id bigint NOT NULL,
    region_id bigint NOT NULL,
    codigo character varying(20) COLLATE pg_catalog."default" NOT NULL,
    nombre character varying(100) COLLATE pg_catalog."default" NOT NULL,
    numero integer NOT NULL,
    activo boolean DEFAULT true,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    created_by character varying(100) COLLATE pg_catalog."default",
    updated_by character varying(100) COLLATE pg_catalog."default",
    CONSTRAINT pk_puntos_venta PRIMARY KEY (id),
    CONSTRAINT uk_puntos_venta_codigo UNIQUE (codigo),
    CONSTRAINT fk_regiones_almacen_id FOREIGN KEY (region_id)
        REFERENCES core.regiones (id) MATCH SIMPLE
        ON UPDATE NO ACTION
        ON DELETE NO ACTION,
    CONSTRAINT fk_sucursales_almacen_id FOREIGN KEY (sucursal_id)
        REFERENCES core.sucursales (id) MATCH SIMPLE
        ON UPDATE NO ACTION
        ON DELETE NO ACTION
)

TABLESPACE pg_default;

ALTER TABLE IF EXISTS core.puntos_venta
    OWNER to postgres;
-- Index: idx_puntos_venta_activo

-- DROP INDEX IF EXISTS core.idx_puntos_venta_activo;

CREATE INDEX IF NOT EXISTS idx_puntos_venta_activo
    ON core.puntos_venta USING btree
    (activo ASC NULLS LAST)
    TABLESPACE pg_default
    WHERE activo = true;

-- Trigger: trg_puntos_venta_audit

-- DROP TRIGGER IF EXISTS trg_puntos_venta_audit ON core.puntos_venta;

CREATE OR REPLACE TRIGGER trg_puntos_venta_audit
    AFTER INSERT OR DELETE OR UPDATE 
    ON core.puntos_venta
    FOR EACH ROW
    EXECUTE FUNCTION auditoria.fn_auditar_cambios();

-- Trigger: trigger_puntos_venta_set_users

-- DROP TRIGGER IF EXISTS trigger_puntos_venta_set_users ON core.puntos_venta;

CREATE OR REPLACE TRIGGER trigger_puntos_venta_set_users
    BEFORE INSERT OR UPDATE 
    ON core.puntos_venta
    FOR EACH ROW
    EXECUTE FUNCTION auditoria.fn_set_audit_users();

-- Trigger: trigger_puntos_venta_updated_at

-- DROP TRIGGER IF EXISTS trigger_puntos_venta_updated_at ON core.puntos_venta;

CREATE OR REPLACE TRIGGER trigger_puntos_venta_updated_at
    BEFORE UPDATE 
    ON core.puntos_venta
    FOR EACH ROW
    EXECUTE FUNCTION auditoria.fn_update_updated_at_column();