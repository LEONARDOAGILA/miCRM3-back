-- Table: rh.contactos_emergencia

-- DROP TABLE IF EXISTS rh.contactos_emergencia;

CREATE TABLE IF NOT EXISTS rh.contactos_emergencia
(
    id bigserial NOT NULL,
    empleado_id bigint NOT NULL,
    nombres character varying(100) COLLATE pg_catalog."default" NOT NULL,
    parentesco character varying(50) COLLATE pg_catalog."default" NOT NULL,
    telefono character varying(20) COLLATE pg_catalog."default" NOT NULL,
    telefono_alterno character varying(20) COLLATE pg_catalog."default",
    email character varying(150) COLLATE pg_catalog."default",
    prioridad integer DEFAULT 1,
    activo boolean DEFAULT true,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    created_by character varying(100) COLLATE pg_catalog."default",
    updated_by character varying(100) COLLATE pg_catalog."default",
    CONSTRAINT pk_contactos_emergencia PRIMARY KEY (id),
    CONSTRAINT fk_contactos_empleado FOREIGN KEY (empleado_id)
        REFERENCES rh.empleados (id) MATCH SIMPLE
        ON UPDATE NO ACTION
        ON DELETE CASCADE,
    CONSTRAINT ck_contactos_prioridad CHECK (prioridad > 0)
)

TABLESPACE pg_default;

ALTER TABLE IF EXISTS rh.contactos_emergencia
    OWNER to postgres;
-- Index: idx_contactos_activo

-- DROP INDEX IF EXISTS rh.idx_contactos_activo;

CREATE INDEX IF NOT EXISTS idx_contactos_activo
    ON rh.contactos_emergencia USING btree
    (activo ASC NULLS LAST)
    TABLESPACE pg_default
    WHERE activo = true;
-- Index: idx_contactos_empleado

-- DROP INDEX IF EXISTS rh.idx_contactos_empleado;

CREATE INDEX IF NOT EXISTS idx_contactos_empleado
    ON rh.contactos_emergencia USING btree
    (empleado_id ASC NULLS LAST)
    TABLESPACE pg_default;

-- Trigger: trg_contactos_emergencia_audit

-- DROP TRIGGER IF EXISTS trg_contactos_emergencia_audit ON rh.contactos_emergencia;

CREATE OR REPLACE TRIGGER trg_contactos_emergencia_audit
    AFTER INSERT OR DELETE OR UPDATE 
    ON rh.contactos_emergencia
    FOR EACH ROW
    EXECUTE FUNCTION auditoria.fn_auditar_cambios();

-- Trigger: trigger_contactos_emergencia_updated_at

-- DROP TRIGGER IF EXISTS trigger_contactos_emergencia_updated_at ON rh.contactos_emergencia;

CREATE OR REPLACE TRIGGER trigger_contactos_emergencia_updated_at
    BEFORE UPDATE 
    ON rh.contactos_emergencia
    FOR EACH ROW
    EXECUTE FUNCTION auditoria.fn_update_updated_at_column();

-- Trigger: trigger_contactos_set_users

-- DROP TRIGGER IF EXISTS trigger_contactos_set_users ON rh.contactos_emergencia;

CREATE OR REPLACE TRIGGER trigger_contactos_set_users
    BEFORE INSERT OR UPDATE 
    ON rh.contactos_emergencia
    FOR EACH ROW
    EXECUTE FUNCTION auditoria.fn_set_audit_users();