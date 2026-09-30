-- Table: rh.historial_cargos

-- DROP TABLE IF EXISTS rh.historial_cargos;

CREATE TABLE IF NOT EXISTS rh.historial_cargos
(
    id bigserial NOT NULL,
    empleado_id bigint NOT NULL,
    cargo_id bigint NOT NULL,
    departamento_id bigint NOT NULL,
    salario numeric(12,2),
    fecha_inicio date NOT NULL,
    fecha_fin date,
    motivo character varying(100) COLLATE pg_catalog."default",
    observaciones text COLLATE pg_catalog."default",
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    created_by character varying(100) COLLATE pg_catalog."default",
    CONSTRAINT pk_historial_cargos PRIMARY KEY (id),
    CONSTRAINT fk_historial_cargo FOREIGN KEY (cargo_id)
        REFERENCES rh.cargos (id) MATCH SIMPLE
        ON UPDATE NO ACTION
        ON DELETE NO ACTION,
    CONSTRAINT fk_historial_departamento FOREIGN KEY (departamento_id)
        REFERENCES rh.departamentos (id) MATCH SIMPLE
        ON UPDATE NO ACTION
        ON DELETE NO ACTION,
    CONSTRAINT fk_historial_empleado FOREIGN KEY (empleado_id)
        REFERENCES rh.empleados (id) MATCH SIMPLE
        ON UPDATE NO ACTION
        ON DELETE NO ACTION,
    CONSTRAINT ck_historial_cargos_fechas CHECK (fecha_fin IS NULL OR fecha_fin >= fecha_inicio)
)

TABLESPACE pg_default;

ALTER TABLE IF EXISTS rh.historial_cargos
    OWNER to postgres;
-- Index: idx_historial_cargo

-- DROP INDEX IF EXISTS rh.idx_historial_cargo;

CREATE INDEX IF NOT EXISTS idx_historial_cargo
    ON rh.historial_cargos USING btree
    (cargo_id ASC NULLS LAST)
    TABLESPACE pg_default;
-- Index: idx_historial_empleado

-- DROP INDEX IF EXISTS rh.idx_historial_empleado;

CREATE INDEX IF NOT EXISTS idx_historial_empleado
    ON rh.historial_cargos USING btree
    (empleado_id ASC NULLS LAST)
    TABLESPACE pg_default;
-- Index: idx_historial_fechas

-- DROP INDEX IF EXISTS rh.idx_historial_fechas;

CREATE INDEX IF NOT EXISTS idx_historial_fechas
    ON rh.historial_cargos USING btree
    (fecha_inicio ASC NULLS LAST, fecha_fin ASC NULLS LAST)
    TABLESPACE pg_default;

-- Trigger: trg_historial_cargos_audit

-- DROP TRIGGER IF EXISTS trg_historial_cargos_audit ON rh.historial_cargos;

CREATE OR REPLACE TRIGGER trg_historial_cargos_audit
    AFTER INSERT OR DELETE OR UPDATE 
    ON rh.historial_cargos
    FOR EACH ROW
    EXECUTE FUNCTION auditoria.fn_auditar_cambios();

-- Trigger: trigger_historial_set_users

-- DROP TRIGGER IF EXISTS trigger_historial_set_users ON rh.historial_cargos;

CREATE OR REPLACE TRIGGER trigger_historial_set_users
    BEFORE INSERT
    ON rh.historial_cargos
    FOR EACH ROW
    EXECUTE FUNCTION auditoria.fn_set_audit_users();