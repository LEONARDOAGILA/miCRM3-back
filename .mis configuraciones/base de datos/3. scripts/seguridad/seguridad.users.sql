-- Table: seguridad.users

-- DROP TABLE IF EXISTS seguridad.users;

CREATE TABLE IF NOT EXISTS seguridad.users
(
    id bigserial NOT NULL,
    login_user character varying(30) COLLATE pg_catalog."default" NOT NULL,
    password character varying(255) COLLATE pg_catalog."default" NOT NULL,
    name character varying(100) COLLATE pg_catalog."default" NOT NULL,
    surname character varying(100) COLLATE pg_catalog."default" NOT NULL,
    email character varying(100) COLLATE pg_catalog."default" NOT NULL,
    phone character varying(30) COLLATE pg_catalog."default" NOT NULL,
    avatar text COLLATE pg_catalog."default",
    type_user integer DEFAULT 1,
    isactive boolean DEFAULT true,
    islogin boolean DEFAULT false,
    isreset boolean DEFAULT false,
    perfil_id bigint NOT NULL,
    chorario_id bigint NOT NULL,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    created_by character varying(100) COLLATE pg_catalog."default",
    updated_by character varying(100) COLLATE pg_catalog."default",
    email_verified_at timestamp with time zone,
    user_verified_at timestamp with time zone,
    last_login_at timestamp with time zone,
    recovery_code character varying(10) COLLATE pg_catalog."default",
    recovery_code_expires_at timestamp without time zone,
    CONSTRAINT pk_users PRIMARY KEY (id),
    CONSTRAINT uk_users_login_perfil UNIQUE (login_user, perfil_id),
    CONSTRAINT uk_users_login_user UNIQUE (login_user),
    CONSTRAINT fk_users_chorarios FOREIGN KEY (chorario_id)
        REFERENCES seguridad.chorarios (id) MATCH SIMPLE
        ON UPDATE NO ACTION
        ON DELETE NO ACTION,
    CONSTRAINT fk_users_perfiles FOREIGN KEY (perfil_id)
        REFERENCES seguridad.perfiles (id) MATCH SIMPLE
        ON UPDATE NO ACTION
        ON DELETE NO ACTION
)

TABLESPACE pg_default;

ALTER TABLE IF EXISTS seguridad.users
    OWNER to postgres;

COMMENT ON COLUMN seguridad.users.id
    IS 'Identificador único del usuario (PK)';

COMMENT ON COLUMN seguridad.users.login_user
    IS 'Nombre de usuario para login (único)';

COMMENT ON COLUMN seguridad.users.password
    IS 'Contraseña encriptada del usuario';

COMMENT ON COLUMN seguridad.users.name
    IS 'Nombre propio del usuario';

COMMENT ON COLUMN seguridad.users.surname
    IS 'Apellido del usuario';

COMMENT ON COLUMN seguridad.users.email
    IS 'Correo electrónico del usuario';

COMMENT ON COLUMN seguridad.users.phone
    IS 'Número de teléfono del usuario';

COMMENT ON COLUMN seguridad.users.avatar
    IS 'URL o ruta de la imagen del avatar';

COMMENT ON COLUMN seguridad.users.type_user
    IS 'Tipo de usuario: USUARIO, ADMINISTRADOR, SUPERVISOR';

COMMENT ON COLUMN seguridad.users.isactive
    IS 'Indica si el usuario está activo';

COMMENT ON COLUMN seguridad.users.islogin
    IS 'Indica si el usuario está actualmente logueado';

COMMENT ON COLUMN seguridad.users.isreset
    IS 'Indica si el usuario debe resetear su contraseña';

COMMENT ON COLUMN seguridad.users.perfil_id
    IS 'Referencia al perfil de seguridad del usuario (FK)';

COMMENT ON COLUMN seguridad.users.chorario_id
    IS 'Referencia al horario asignado al usuario (FK)';

COMMENT ON COLUMN seguridad.users.created_at
    IS 'Fecha y hora de creación del registro';

COMMENT ON COLUMN seguridad.users.updated_at
    IS 'Fecha y hora de última actualización del registro';

COMMENT ON COLUMN seguridad.users.created_by
    IS 'Usuario que creó el registro';

COMMENT ON COLUMN seguridad.users.updated_by
    IS 'Usuario que actualizó el registro';

COMMENT ON COLUMN seguridad.users.email_verified_at
    IS 'Fecha de verificación del correo electrónico';

COMMENT ON COLUMN seguridad.users.user_verified_at
    IS 'Fecha de verificación del usuario';

COMMENT ON COLUMN seguridad.users.last_login_at
    IS 'Fecha de ultimo inicio de sesion';
-- Index: idx_users_chorario_id

-- DROP INDEX IF EXISTS seguridad.idx_users_chorario_id;

CREATE INDEX IF NOT EXISTS idx_users_chorario_id
    ON seguridad.users USING btree
    (chorario_id ASC NULLS LAST)
    TABLESPACE pg_default;
-- Index: idx_users_isactive

-- DROP INDEX IF EXISTS seguridad.idx_users_isactive;

CREATE INDEX IF NOT EXISTS idx_users_isactive
    ON seguridad.users USING btree
    (isactive ASC NULLS LAST)
    TABLESPACE pg_default
    WHERE isactive = true;
-- Index: idx_users_perfil_id

-- DROP INDEX IF EXISTS seguridad.idx_users_perfil_id;

CREATE INDEX IF NOT EXISTS idx_users_perfil_id
    ON seguridad.users USING btree
    (perfil_id ASC NULLS LAST)
    TABLESPACE pg_default;
-- Index: idx_users_recovery_code

-- DROP INDEX IF EXISTS seguridad.idx_users_recovery_code;

CREATE INDEX IF NOT EXISTS idx_users_recovery_code
    ON seguridad.users USING btree
    (recovery_code COLLATE pg_catalog."default" ASC NULLS LAST, recovery_code_expires_at ASC NULLS LAST)
    TABLESPACE pg_default;

-- Trigger: trg_users_audit

-- DROP TRIGGER IF EXISTS trg_users_audit ON seguridad.users;

CREATE OR REPLACE TRIGGER trg_users_audit
    AFTER INSERT OR DELETE OR UPDATE 
    ON seguridad.users
    FOR EACH ROW
    EXECUTE FUNCTION auditoria.fn_auditar_cambios();

-- Trigger: trigger_users_set_users

-- DROP TRIGGER IF EXISTS trigger_users_set_users ON seguridad.users;

CREATE OR REPLACE TRIGGER trigger_users_set_users
    BEFORE INSERT OR UPDATE 
    ON seguridad.users
    FOR EACH ROW
    EXECUTE FUNCTION auditoria.fn_set_audit_users();

-- Trigger: trigger_users_updated_at

-- DROP TRIGGER IF EXISTS trigger_users_updated_at ON seguridad.users;

CREATE OR REPLACE TRIGGER trigger_users_updated_at
    BEFORE UPDATE 
    ON seguridad.users
    FOR EACH ROW
    EXECUTE FUNCTION auditoria.fn_update_updated_at_column();