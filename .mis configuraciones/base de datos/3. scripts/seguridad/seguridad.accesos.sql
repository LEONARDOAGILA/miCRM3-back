-- Table: seguridad.accesos

-- DROP TABLE IF EXISTS seguridad.accesos;

CREATE TABLE IF NOT EXISTS seguridad.accesos
(
    id bigserial NOT NULL,
    perfil_id bigint,
    menu_id bigint,
    ver boolean DEFAULT false,
    crear boolean DEFAULT false,
    editar boolean DEFAULT false,
    eliminar boolean DEFAULT false,
    listar boolean DEFAULT false,
    reporte boolean DEFAULT false,
    auditar boolean DEFAULT false,
    ejecutar boolean DEFAULT false,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    created_by character varying(100) COLLATE pg_catalog."default",
    updated_by character varying(100) COLLATE pg_catalog."default",
    CONSTRAINT pk_accesos PRIMARY KEY (id),
    CONSTRAINT uk_accesos_perfiles_menus UNIQUE (perfil_id, menu_id),
    CONSTRAINT fk_accesos_menus FOREIGN KEY (menu_id)
        REFERENCES seguridad.menus (id) MATCH SIMPLE
        ON UPDATE NO ACTION
        ON DELETE NO ACTION,
    CONSTRAINT fk_accesos_perfiles FOREIGN KEY (perfil_id)
        REFERENCES seguridad.perfiles (id) MATCH SIMPLE
        ON UPDATE NO ACTION
        ON DELETE NO ACTION
)

TABLESPACE pg_default;

ALTER TABLE IF EXISTS seguridad.accesos
    OWNER to postgres;
-- Index: idx_accesos_menu_id

-- DROP INDEX IF EXISTS seguridad.idx_accesos_menu_id;

CREATE INDEX IF NOT EXISTS idx_accesos_menu_id
    ON seguridad.accesos USING btree
    (menu_id ASC NULLS LAST)
    TABLESPACE pg_default;
-- Index: idx_accesos_perfil_id

-- DROP INDEX IF EXISTS seguridad.idx_accesos_perfil_id;

CREATE INDEX IF NOT EXISTS idx_accesos_perfil_id
    ON seguridad.accesos USING btree
    (perfil_id ASC NULLS LAST)
    TABLESPACE pg_default;
-- Index: idx_accesos_perfil_menu

-- DROP INDEX IF EXISTS seguridad.idx_accesos_perfil_menu;

CREATE INDEX IF NOT EXISTS idx_accesos_perfil_menu
    ON seguridad.accesos USING btree
    (perfil_id ASC NULLS LAST, menu_id ASC NULLS LAST)
    TABLESPACE pg_default;

-- Trigger: trg_accesos_audit

-- DROP TRIGGER IF EXISTS trg_accesos_audit ON seguridad.accesos;

CREATE OR REPLACE TRIGGER trg_accesos_audit
    AFTER INSERT OR DELETE OR UPDATE 
    ON seguridad.accesos
    FOR EACH ROW
    EXECUTE FUNCTION auditoria.fn_auditar_cambios();

-- Trigger: trigger_accesos_set_users

-- DROP TRIGGER IF EXISTS trigger_accesos_set_users ON seguridad.accesos;

CREATE OR REPLACE TRIGGER trigger_accesos_set_users
    BEFORE INSERT OR UPDATE 
    ON seguridad.accesos
    FOR EACH ROW
    EXECUTE FUNCTION auditoria.fn_set_audit_users();

-- Trigger: trigger_accesos_updated_at

-- DROP TRIGGER IF EXISTS trigger_accesos_updated_at ON seguridad.accesos;

CREATE OR REPLACE TRIGGER trigger_accesos_updated_at
    BEFORE UPDATE 
    ON seguridad.accesos
    FOR EACH ROW
    EXECUTE FUNCTION auditoria.fn_update_updated_at_column();