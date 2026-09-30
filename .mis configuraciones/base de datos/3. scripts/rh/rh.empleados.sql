-- Table: rh.empleados

-- DROP TABLE IF EXISTS rh.empleados;

CREATE TABLE IF NOT EXISTS rh.empleados
(
    id bigserial NOT NULL,
    numero_identificacion character varying(20) COLLATE pg_catalog."default" NOT NULL,
    tipo_identificacion character varying(10) COLLATE pg_catalog."default" NOT NULL,
    nombres character varying(100) COLLATE pg_catalog."default" NOT NULL,
    apellidos character varying(100) COLLATE pg_catalog."default" NOT NULL,
    email character varying(150) COLLATE pg_catalog."default" NOT NULL,
    email_personal character varying(150) COLLATE pg_catalog."default",
    telefono character varying(20) COLLATE pg_catalog."default",
    celular character varying(20) COLLATE pg_catalog."default",
    fecha_nacimiento date,
    genero character(1) COLLATE pg_catalog."default",
    direccion text COLLATE pg_catalog."default",
    cargo_id bigint NOT NULL,
    departamento_id bigint NOT NULL,
    jefe_id bigint,
    fecha_ingreso date NOT NULL,
    fecha_salida date,
    estado character varying(20) COLLATE pg_catalog."default" DEFAULT 'ACTIVO'::character varying,
    tipo_contrato character varying(20) COLLATE pg_catalog."default" NOT NULL,
    salario numeric(12,2),
    activo boolean DEFAULT true,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    created_by character varying(100) COLLATE pg_catalog."default",
    updated_by character varying(100) COLLATE pg_catalog."default",
    CONSTRAINT pk_empleados PRIMARY KEY (id),
    CONSTRAINT uk_empleados_email UNIQUE (email),
    CONSTRAINT uk_empleados_numero_identificacion UNIQUE (numero_identificacion, tipo_identificacion),
    CONSTRAINT fk_empleados_cargo FOREIGN KEY (cargo_id)
        REFERENCES rh.cargos (id) MATCH SIMPLE
        ON UPDATE NO ACTION
        ON DELETE NO ACTION,
    CONSTRAINT fk_empleados_departamento FOREIGN KEY (departamento_id)
        REFERENCES rh.departamentos (id) MATCH SIMPLE
        ON UPDATE NO ACTION
        ON DELETE NO ACTION,
    CONSTRAINT fk_empleados_jefe FOREIGN KEY (jefe_id)
        REFERENCES rh.empleados (id) MATCH SIMPLE
        ON UPDATE NO ACTION
        ON DELETE NO ACTION,
    CONSTRAINT ck_empleados_apellidos_min CHECK (length(TRIM(BOTH FROM apellidos)) >= 2),
    CONSTRAINT ck_empleados_estado CHECK (estado::text = ANY (ARRAY['ACTIVO'::character varying::text, 'INACTIVO'::character varying::text, 'VACACIONES'::character varying::text, 'LICENCIA'::character varying::text, 'SUSPENDIDO'::character varying::text])),
    CONSTRAINT ck_empleados_fechas CHECK (fecha_salida IS NULL OR fecha_salida >= fecha_ingreso),
    CONSTRAINT ck_empleados_genero CHECK (genero = ANY (ARRAY['M'::bpchar, 'F'::bpchar, 'O'::bpchar])),
    CONSTRAINT ck_empleados_nombres_min CHECK (length(TRIM(BOTH FROM nombres)) >= 2),
    CONSTRAINT ck_empleados_tipo_contrato CHECK (tipo_contrato::text = ANY (ARRAY['INDEFINIDO'::character varying::text, 'TEMPORAL'::character varying::text, 'PRACTICAS'::character varying::text, 'CONSULTORIA'::character varying::text]))
)

TABLESPACE pg_default;

ALTER TABLE IF EXISTS rh.empleados
    OWNER to postgres;
-- Index: idx_empleados_activo

-- DROP INDEX IF EXISTS rh.idx_empleados_activo;

CREATE INDEX IF NOT EXISTS idx_empleados_activo
    ON rh.empleados USING btree
    (activo ASC NULLS LAST)
    TABLESPACE pg_default
    WHERE activo = true;
-- Index: idx_empleados_cargo

-- DROP INDEX IF EXISTS rh.idx_empleados_cargo;

CREATE INDEX IF NOT EXISTS idx_empleados_cargo
    ON rh.empleados USING btree
    (cargo_id ASC NULLS LAST)
    TABLESPACE pg_default;
-- Index: idx_empleados_departamento

-- DROP INDEX IF EXISTS rh.idx_empleados_departamento;

CREATE INDEX IF NOT EXISTS idx_empleados_departamento
    ON rh.empleados USING btree
    (departamento_id ASC NULLS LAST)
    TABLESPACE pg_default;
-- Index: idx_empleados_estado

-- DROP INDEX IF EXISTS rh.idx_empleados_estado;

CREATE INDEX IF NOT EXISTS idx_empleados_estado
    ON rh.empleados USING btree
    (estado COLLATE pg_catalog."default" ASC NULLS LAST)
    TABLESPACE pg_default;
-- Index: idx_empleados_fecha_ingreso

-- DROP INDEX IF EXISTS rh.idx_empleados_fecha_ingreso;

CREATE INDEX IF NOT EXISTS idx_empleados_fecha_ingreso
    ON rh.empleados USING btree
    (fecha_ingreso ASC NULLS LAST)
    TABLESPACE pg_default;
-- Index: idx_empleados_jefe

-- DROP INDEX IF EXISTS rh.idx_empleados_jefe;

CREATE INDEX IF NOT EXISTS idx_empleados_jefe
    ON rh.empleados USING btree
    (jefe_id ASC NULLS LAST)
    TABLESPACE pg_default;
-- Index: idx_empleados_numero_identificacion

-- DROP INDEX IF EXISTS rh.idx_empleados_numero_identificacion;

CREATE INDEX IF NOT EXISTS idx_empleados_numero_identificacion
    ON rh.empleados USING btree
    (numero_identificacion COLLATE pg_catalog."default" ASC NULLS LAST)
    TABLESPACE pg_default;

-- Trigger: trg_empleados_audit

-- DROP TRIGGER IF EXISTS trg_empleados_audit ON rh.empleados;

CREATE OR REPLACE TRIGGER trg_empleados_audit
    AFTER INSERT OR DELETE OR UPDATE 
    ON rh.empleados
    FOR EACH ROW
    EXECUTE FUNCTION auditoria.fn_auditar_cambios();

-- Trigger: trigger_empleados_set_users

-- DROP TRIGGER IF EXISTS trigger_empleados_set_users ON rh.empleados;

CREATE OR REPLACE TRIGGER trigger_empleados_set_users
    BEFORE INSERT OR UPDATE 
    ON rh.empleados
    FOR EACH ROW
    EXECUTE FUNCTION auditoria.fn_set_audit_users();

-- Trigger: trigger_empleados_updated_at

-- DROP TRIGGER IF EXISTS trigger_empleados_updated_at ON rh.empleados;

CREATE OR REPLACE TRIGGER trigger_empleados_updated_at
    BEFORE UPDATE 
    ON rh.empleados
    FOR EACH ROW
    EXECUTE FUNCTION auditoria.fn_update_updated_at_column();