-- Table: auditoria.logs_cambios

-- DROP TABLE IF EXISTS auditoria.logs_cambios;

CREATE TABLE IF NOT EXISTS auditoria.logs_cambios
(
    id bigserial NOT NULL,
    schema_nombre character varying(50) COLLATE pg_catalog."default" NOT NULL,
    tabla_nombre character varying(50) COLLATE pg_catalog."default" NOT NULL,
    registro_id bigint NOT NULL,
    operacion character varying(10) COLLATE pg_catalog."default" NOT NULL,
    datos_anteriores jsonb,
    datos_nuevos jsonb,
    usuario_id bigint,
    usuario_login character varying(100) COLLATE pg_catalog."default",
    usuario_nombre character varying(200) COLLATE pg_catalog."default",
    ip_address inet,
    user_agent text COLLATE pg_catalog."default",
    request_id uuid,
    modulo character varying(50) COLLATE pg_catalog."default",
    fecha_operacion timestamp with time zone NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT logs_cambios_pkey PRIMARY KEY (id, fecha_operacion)
) PARTITION BY RANGE (fecha_operacion);

ALTER TABLE IF EXISTS auditoria.logs_cambios
    OWNER to postgres;
-- Index: idx_logs_cambios_fecha_brin

-- DROP INDEX IF EXISTS auditoria.idx_logs_cambios_fecha_brin;

CREATE INDEX IF NOT EXISTS idx_logs_cambios_fecha_brin
    ON auditoria.logs_cambios USING brin
    (fecha_operacion)
    TABLESPACE pg_default;
-- Index: idx_logs_cambios_registro

-- DROP INDEX IF EXISTS auditoria.idx_logs_cambios_registro;

CREATE INDEX IF NOT EXISTS idx_logs_cambios_registro
    ON auditoria.logs_cambios USING btree
    (schema_nombre COLLATE pg_catalog."default" ASC NULLS LAST, tabla_nombre COLLATE pg_catalog."default" ASC NULLS LAST, registro_id ASC NULLS LAST)
    TABLESPACE pg_default;
-- Index: idx_logs_cambios_tabla_registro

-- DROP INDEX IF EXISTS auditoria.idx_logs_cambios_tabla_registro;

CREATE INDEX IF NOT EXISTS idx_logs_cambios_tabla_registro
    ON auditoria.logs_cambios USING btree
    (tabla_nombre COLLATE pg_catalog."default" ASC NULLS LAST, registro_id ASC NULLS LAST)
    TABLESPACE pg_default;
-- Index: idx_logs_cambios_usuario

-- DROP INDEX IF EXISTS auditoria.idx_logs_cambios_usuario;

CREATE INDEX IF NOT EXISTS idx_logs_cambios_usuario
    ON auditoria.logs_cambios USING btree
    (usuario_id ASC NULLS LAST)
    TABLESPACE pg_default;
-- Index: idx_logs_cambios_usuario_login

-- DROP INDEX IF EXISTS auditoria.idx_logs_cambios_usuario_login;

CREATE INDEX IF NOT EXISTS idx_logs_cambios_usuario_login
    ON auditoria.logs_cambios USING btree
    (usuario_login COLLATE pg_catalog."default" ASC NULLS LAST)
    TABLESPACE pg_default;

-- Partitions SQL

CREATE TABLE auditoria.logs_cambios_2025_09 PARTITION OF auditoria.logs_cambios
    FOR VALUES FROM ('2025-09-01 00:00:00-05') TO ('2025-10-01 00:00:00-05')
TABLESPACE pg_default;

ALTER TABLE IF EXISTS auditoria.logs_cambios_2025_09
    OWNER to postgres;
CREATE TABLE auditoria.logs_cambios_2025_10 PARTITION OF auditoria.logs_cambios
    FOR VALUES FROM ('2025-10-01 00:00:00-05') TO ('2025-11-01 00:00:00-05')
TABLESPACE pg_default;

ALTER TABLE IF EXISTS auditoria.logs_cambios_2025_10
    OWNER to postgres;
CREATE TABLE auditoria.logs_cambios_2025_11 PARTITION OF auditoria.logs_cambios
    FOR VALUES FROM ('2025-11-01 00:00:00-05') TO ('2025-12-01 00:00:00-05')
TABLESPACE pg_default;

ALTER TABLE IF EXISTS auditoria.logs_cambios_2025_11
    OWNER to postgres;
CREATE TABLE auditoria.logs_cambios_2025_12 PARTITION OF auditoria.logs_cambios
    FOR VALUES FROM ('2025-12-01 00:00:00-05') TO ('2026-01-01 00:00:00-05')
TABLESPACE pg_default;

ALTER TABLE IF EXISTS auditoria.logs_cambios_2025_12
    OWNER to postgres;
CREATE TABLE auditoria.logs_cambios_2026_01 PARTITION OF auditoria.logs_cambios
    FOR VALUES FROM ('2026-01-01 00:00:00-05') TO ('2026-02-01 00:00:00-05')
TABLESPACE pg_default;

ALTER TABLE IF EXISTS auditoria.logs_cambios_2026_01
    OWNER to postgres;
CREATE TABLE auditoria.logs_cambios_2026_02 PARTITION OF auditoria.logs_cambios
    FOR VALUES FROM ('2026-02-01 00:00:00-05') TO ('2026-03-01 00:00:00-05')
TABLESPACE pg_default;

ALTER TABLE IF EXISTS auditoria.logs_cambios_2026_02
    OWNER to postgres;
CREATE TABLE auditoria.logs_cambios_2026_03 PARTITION OF auditoria.logs_cambios
    FOR VALUES FROM ('2026-03-01 00:00:00-05') TO ('2026-04-01 00:00:00-05')
TABLESPACE pg_default;

ALTER TABLE IF EXISTS auditoria.logs_cambios_2026_03
    OWNER to postgres;
CREATE TABLE auditoria.logs_cambios_2026_04 PARTITION OF auditoria.logs_cambios
    FOR VALUES FROM ('2026-04-01 00:00:00-05') TO ('2026-05-01 00:00:00-05')
TABLESPACE pg_default;

ALTER TABLE IF EXISTS auditoria.logs_cambios_2026_04
    OWNER to postgres;
CREATE TABLE auditoria.logs_cambios_2026_05 PARTITION OF auditoria.logs_cambios
    FOR VALUES FROM ('2026-05-01 00:00:00-05') TO ('2026-06-01 00:00:00-05')
TABLESPACE pg_default;

ALTER TABLE IF EXISTS auditoria.logs_cambios_2026_05
    OWNER to postgres;
CREATE TABLE auditoria.logs_cambios_2026_06 PARTITION OF auditoria.logs_cambios
    FOR VALUES FROM ('2026-06-01 00:00:00-05') TO ('2026-07-01 00:00:00-05')
TABLESPACE pg_default;

ALTER TABLE IF EXISTS auditoria.logs_cambios_2026_06
    OWNER to postgres;
CREATE TABLE auditoria.logs_cambios_2026_07 PARTITION OF auditoria.logs_cambios
    FOR VALUES FROM ('2026-07-01 00:00:00-05') TO ('2026-08-01 00:00:00-05')
TABLESPACE pg_default;

ALTER TABLE IF EXISTS auditoria.logs_cambios_2026_07
    OWNER to postgres;
CREATE TABLE auditoria.logs_cambios_2026_08 PARTITION OF auditoria.logs_cambios
    FOR VALUES FROM ('2026-08-01 00:00:00-05') TO ('2026-09-01 00:00:00-05')
TABLESPACE pg_default;

ALTER TABLE IF EXISTS auditoria.logs_cambios_2026_08
    OWNER to postgres;
CREATE TABLE auditoria.logs_cambios_2026_09 PARTITION OF auditoria.logs_cambios
    FOR VALUES FROM ('2026-09-01 00:00:00-05') TO ('2026-10-01 00:00:00-05')
TABLESPACE pg_default;

ALTER TABLE IF EXISTS auditoria.logs_cambios_2026_09
    OWNER to postgres;