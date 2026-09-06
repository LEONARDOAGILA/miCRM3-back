-- Table: seguridad.sesiones_activas

-- DROP TABLE IF EXISTS seguridad.sesiones_activas;

CREATE TABLE IF NOT EXISTS seguridad.sesiones_activas
(
    id bigserial NOT NULL,
    user_id bigint NOT NULL,
    token_id character varying(100) COLLATE pg_catalog."default" NOT NULL,
    ip_address inet,
    user_agent text COLLATE pg_catalog."default",
    navegador character varying(100) COLLATE pg_catalog."default",
    sistema_operativo character varying(100) COLLATE pg_catalog."default",
    dispositivo character varying(50) COLLATE pg_catalog."default",
    last_activity timestamp with time zone DEFAULT now(),
    created_at timestamp with time zone DEFAULT now(),
    is_active boolean DEFAULT true,
    CONSTRAINT sesiones_activas_pkey PRIMARY KEY (id),
    CONSTRAINT uk_user_token UNIQUE (user_id, token_id),
    CONSTRAINT sesiones_activas_user_id_fkey FOREIGN KEY (user_id)
        REFERENCES seguridad.users (id) MATCH SIMPLE
        ON UPDATE NO ACTION
        ON DELETE CASCADE
)

TABLESPACE pg_default;

ALTER TABLE IF EXISTS seguridad.sesiones_activas
    OWNER to postgres;

COMMENT ON TABLE seguridad.sesiones_activas
    IS 'Control de sesiones activas de usuarios';

COMMENT ON COLUMN seguridad.sesiones_activas.token_id
    IS 'JWT ID (jti) del token';

COMMENT ON COLUMN seguridad.sesiones_activas.last_activity
    IS 'Última actividad del usuario';
-- Index: idx_sesiones_is_active

-- DROP INDEX IF EXISTS seguridad.idx_sesiones_is_active;

CREATE INDEX IF NOT EXISTS idx_sesiones_is_active
    ON seguridad.sesiones_activas USING btree
    (is_active ASC NULLS LAST)
    TABLESPACE pg_default;
-- Index: idx_sesiones_last_activity

-- DROP INDEX IF EXISTS seguridad.idx_sesiones_last_activity;

CREATE INDEX IF NOT EXISTS idx_sesiones_last_activity
    ON seguridad.sesiones_activas USING btree
    (last_activity ASC NULLS LAST)
    TABLESPACE pg_default;
-- Index: idx_sesiones_token_id

-- DROP INDEX IF EXISTS seguridad.idx_sesiones_token_id;

CREATE INDEX IF NOT EXISTS idx_sesiones_token_id
    ON seguridad.sesiones_activas USING btree
    (token_id COLLATE pg_catalog."default" ASC NULLS LAST)
    TABLESPACE pg_default;
-- Index: idx_sesiones_user_id

-- DROP INDEX IF EXISTS seguridad.idx_sesiones_user_id;

CREATE INDEX IF NOT EXISTS idx_sesiones_user_id
    ON seguridad.sesiones_activas USING btree
    (user_id ASC NULLS LAST)
    TABLESPACE pg_default;