-- Table: rh.ausencias

-- DROP TABLE IF EXISTS rh.ausencias;

CREATE TABLE IF NOT EXISTS rh.ausencias
(
    id bigserial NOT NULL,
    empleado_id bigint NOT NULL,
    tipo_ausencia character varying(30) COLLATE pg_catalog."default" NOT NULL,
    fecha_inicio date NOT NULL,
    fecha_fin date NOT NULL,
    dias_totales integer GENERATED ALWAYS AS (((fecha_fin - fecha_inicio) + 1)) STORED,
    motivo text COLLATE pg_catalog."default",
    documento_url text COLLATE pg_catalog."default",
    aprobado_por bigint,
    estado character varying(20) COLLATE pg_catalog."default" DEFAULT 'PENDIENTE'::character varying,
    observaciones text COLLATE pg_catalog."default",
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    created_by character varying(100) COLLATE pg_catalog."default",
    updated_by character varying(100) COLLATE pg_catalog."default",
    CONSTRAINT pk_ausencias PRIMARY KEY (id),
    CONSTRAINT fk_ausencias_aprobador FOREIGN KEY (aprobado_por)
        REFERENCES rh.empleados (id) MATCH SIMPLE
        ON UPDATE NO ACTION
        ON DELETE NO ACTION,
    CONSTRAINT fk_ausencias_empleado FOREIGN KEY (empleado_id)
        REFERENCES rh.empleados (id) MATCH SIMPLE
        ON UPDATE NO ACTION
        ON DELETE NO ACTION,
    CONSTRAINT ck_ausencias_estado CHECK (estado::text = ANY (ARRAY['PENDIENTE'::character varying::text, 'APROBADO'::character varying::text, 'RECHAZADO'::character varying::text, 'CANCELADO'::character varying::text])),
    CONSTRAINT ck_ausencias_fechas CHECK (fecha_fin >= fecha_inicio),
    CONSTRAINT ck_ausencias_tipo CHECK (tipo_ausencia::text = ANY (ARRAY['VACACIONES'::character varying::text, 'LICENCIA_MEDICA'::character varying::text, 'LICENCIA_REMUNERADA'::character varying::text, 'LICENCIA_NO_REMUNERADA'::character varying::text, 'PERMISO'::character varying::text, 'SUSPENSION'::character varying::text]))
)

TABLESPACE pg_default;

ALTER TABLE IF EXISTS rh.ausencias
    OWNER to postgres;
-- Index: idx_ausencias_empleado

-- DROP INDEX IF EXISTS rh.idx_ausencias_empleado;

CREATE INDEX IF NOT EXISTS idx_ausencias_empleado
    ON rh.ausencias USING btree
    (empleado_id ASC NULLS LAST)
    TABLESPACE pg_default;
-- Index: idx_ausencias_estado

-- DROP INDEX IF EXISTS rh.idx_ausencias_estado;

CREATE INDEX IF NOT EXISTS idx_ausencias_estado
    ON rh.ausencias USING btree
    (estado COLLATE pg_catalog."default" ASC NULLS LAST)
    TABLESPACE pg_default;
-- Index: idx_ausencias_fechas

-- DROP INDEX IF EXISTS rh.idx_ausencias_fechas;

CREATE INDEX IF NOT EXISTS idx_ausencias_fechas
    ON rh.ausencias USING btree
    (fecha_inicio ASC NULLS LAST, fecha_fin ASC NULLS LAST)
    TABLESPACE pg_default;
-- Index: idx_ausencias_tipo

-- DROP INDEX IF EXISTS rh.idx_ausencias_tipo;

CREATE INDEX IF NOT EXISTS idx_ausencias_tipo
    ON rh.ausencias USING btree
    (tipo_ausencia COLLATE pg_catalog."default" ASC NULLS LAST)
    TABLESPACE pg_default;

-- Trigger: trg_ausencias_audit

-- DROP TRIGGER IF EXISTS trg_ausencias_audit ON rh.ausencias;

CREATE OR REPLACE TRIGGER trg_ausencias_audit
    AFTER INSERT OR DELETE OR UPDATE 
    ON rh.ausencias
    FOR EACH ROW
    EXECUTE FUNCTION auditoria.fn_auditar_cambios();

-- Trigger: trigger_ausencias_set_users

-- DROP TRIGGER IF EXISTS trigger_ausencias_set_users ON rh.ausencias;

CREATE OR REPLACE TRIGGER trigger_ausencias_set_users
    BEFORE INSERT OR UPDATE 
    ON rh.ausencias
    FOR EACH ROW
    EXECUTE FUNCTION auditoria.fn_set_audit_users();

-- Trigger: trigger_ausencias_updated_at

-- DROP TRIGGER IF EXISTS trigger_ausencias_updated_at ON rh.ausencias;

CREATE OR REPLACE TRIGGER trigger_ausencias_updated_at
    BEFORE UPDATE 
    ON rh.ausencias
    FOR EACH ROW
    EXECUTE FUNCTION auditoria.fn_update_updated_at_column();