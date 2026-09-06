-- Table: seguridad.dhorarios

-- DROP TABLE IF EXISTS seguridad.dhorarios;

CREATE TABLE IF NOT EXISTS seguridad.dhorarios
(
    id bigserial NOT NULL,
    chorario_id bigint NOT NULL,
    dia integer NOT NULL,
    hora_inicio interval,
    hora_fin interval,
    activo boolean DEFAULT true,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    created_by character varying(100) COLLATE pg_catalog."default",
    updated_by character varying(100) COLLATE pg_catalog."default",
    CONSTRAINT pk_dhorarios PRIMARY KEY (id),
    CONSTRAINT fk_dhorarios_chorarios FOREIGN KEY (chorario_id)
        REFERENCES seguridad.chorarios (id) MATCH SIMPLE
        ON UPDATE NO ACTION
        ON DELETE NO ACTION,
    CONSTRAINT dhorarios_dia_check CHECK (dia >= 1 AND dia <= 7)
)

TABLESPACE pg_default;

ALTER TABLE IF EXISTS seguridad.dhorarios
    OWNER to postgres;
-- Index: idx_dhorarios_chorario_id

-- DROP INDEX IF EXISTS seguridad.idx_dhorarios_chorario_id;

CREATE INDEX IF NOT EXISTS idx_dhorarios_chorario_id
    ON seguridad.dhorarios USING btree
    (chorario_id ASC NULLS LAST)
    TABLESPACE pg_default;
-- Index: idx_dhorarios_dia

-- DROP INDEX IF EXISTS seguridad.idx_dhorarios_dia;

CREATE INDEX IF NOT EXISTS idx_dhorarios_dia
    ON seguridad.dhorarios USING btree
    (dia ASC NULLS LAST)
    TABLESPACE pg_default;

-- Trigger: trg_dhorarios_audit

-- DROP TRIGGER IF EXISTS trg_dhorarios_audit ON seguridad.dhorarios;

CREATE OR REPLACE TRIGGER trg_dhorarios_audit
    AFTER INSERT OR DELETE OR UPDATE 
    ON seguridad.dhorarios
    FOR EACH ROW
    EXECUTE FUNCTION auditoria.fn_auditar_cambios();

-- Trigger: trigger_dhorarios_set_users

-- DROP TRIGGER IF EXISTS trigger_dhorarios_set_users ON seguridad.dhorarios;

CREATE OR REPLACE TRIGGER trigger_dhorarios_set_users
    BEFORE INSERT OR UPDATE 
    ON seguridad.dhorarios
    FOR EACH ROW
    EXECUTE FUNCTION auditoria.fn_set_audit_users();

-- Trigger: trigger_dhorarios_updated_at

-- DROP TRIGGER IF EXISTS trigger_dhorarios_updated_at ON seguridad.dhorarios;

CREATE OR REPLACE TRIGGER trigger_dhorarios_updated_at
    BEFORE UPDATE 
    ON seguridad.dhorarios
    FOR EACH ROW
    EXECUTE FUNCTION auditoria.fn_update_updated_at_column();