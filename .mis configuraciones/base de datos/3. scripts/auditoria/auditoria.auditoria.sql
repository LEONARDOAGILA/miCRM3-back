-- Table: auditoria.auditoria

-- DROP TABLE IF EXISTS auditoria.auditoria;

CREATE TABLE IF NOT EXISTS auditoria.auditoria
(
    id bigserial NOT NULL,
    tabla_afectada character varying(50) COLLATE pg_catalog."default" NOT NULL,
    id_registro_afectado bigint NOT NULL,
    tipo_operacion character varying(10) COLLATE pg_catalog."default" NOT NULL,
    datos_anteriores jsonb,
    datos_nuevos jsonb,
    fecha_operacion timestamp with time zone NOT NULL DEFAULT now(),
    usuario_operador character varying(100) COLLATE pg_catalog."default",
    ip_address inet,
    user_agent text COLLATE pg_catalog."default",
    request_id uuid,
    modulo character varying(50) COLLATE pg_catalog."default",
    CONSTRAINT auditoria_pkey PRIMARY KEY (id, fecha_operacion)
) PARTITION BY RANGE (fecha_operacion);

ALTER TABLE IF EXISTS auditoria.auditoria
    OWNER to postgres;
-- Index: idx_auditoria_fecha_brin

-- DROP INDEX IF EXISTS auditoria.idx_auditoria_fecha_brin;

CREATE INDEX IF NOT EXISTS idx_auditoria_fecha_brin
    ON auditoria.auditoria USING brin
    (fecha_operacion)
    TABLESPACE pg_default;
-- Index: idx_auditoria_tabla_id

-- DROP INDEX IF EXISTS auditoria.idx_auditoria_tabla_id;

CREATE INDEX IF NOT EXISTS idx_auditoria_tabla_id
    ON auditoria.auditoria USING btree
    (tabla_afectada COLLATE pg_catalog."default" ASC NULLS LAST, id_registro_afectado ASC NULLS LAST)
    TABLESPACE pg_default;
-- Index: idx_auditoria_tipo

-- DROP INDEX IF EXISTS auditoria.idx_auditoria_tipo;

CREATE INDEX IF NOT EXISTS idx_auditoria_tipo
    ON auditoria.auditoria USING btree
    (tipo_operacion COLLATE pg_catalog."default" ASC NULLS LAST)
    TABLESPACE pg_default;
-- Index: idx_auditoria_usuario

-- DROP INDEX IF EXISTS auditoria.idx_auditoria_usuario;

CREATE INDEX IF NOT EXISTS idx_auditoria_usuario
    ON auditoria.auditoria USING btree
    (usuario_operador COLLATE pg_catalog."default" ASC NULLS LAST)
    TABLESPACE pg_default;

-- Partitions SQL

CREATE TABLE auditoria.auditoria_2025_10 PARTITION OF auditoria.auditoria
    FOR VALUES FROM ('2025-10-05 00:00:00-05') TO ('2025-11-05 00:00:00-05')
TABLESPACE pg_default;

ALTER TABLE IF EXISTS auditoria.auditoria_2025_10
    OWNER to postgres;
CREATE TABLE auditoria.auditoria_2025_11 PARTITION OF auditoria.auditoria
    FOR VALUES FROM ('2025-11-05 00:00:00-05') TO ('2025-12-05 00:00:00-05')
TABLESPACE pg_default;

ALTER TABLE IF EXISTS auditoria.auditoria_2025_11
    OWNER to postgres;
CREATE TABLE auditoria.auditoria_2025_12 PARTITION OF auditoria.auditoria
    FOR VALUES FROM ('2025-12-05 00:00:00-05') TO ('2026-01-05 00:00:00-05')
TABLESPACE pg_default;

ALTER TABLE IF EXISTS auditoria.auditoria_2025_12
    OWNER to postgres;
CREATE TABLE auditoria.auditoria_2026_01 PARTITION OF auditoria.auditoria
    FOR VALUES FROM ('2026-01-05 00:00:00-05') TO ('2026-02-05 00:00:00-05')
TABLESPACE pg_default;

ALTER TABLE IF EXISTS auditoria.auditoria_2026_01
    OWNER to postgres;
CREATE TABLE auditoria.auditoria_2026_02 PARTITION OF auditoria.auditoria
    FOR VALUES FROM ('2026-02-05 00:00:00-05') TO ('2026-03-05 00:00:00-05')
TABLESPACE pg_default;

ALTER TABLE IF EXISTS auditoria.auditoria_2026_02
    OWNER to postgres;
CREATE TABLE auditoria.auditoria_2026_03 PARTITION OF auditoria.auditoria
    FOR VALUES FROM ('2026-03-05 00:00:00-05') TO ('2026-04-05 00:00:00-05')
TABLESPACE pg_default;

ALTER TABLE IF EXISTS auditoria.auditoria_2026_03
    OWNER to postgres;
CREATE TABLE auditoria.auditoria_2026_04 PARTITION OF auditoria.auditoria
    FOR VALUES FROM ('2026-04-05 00:00:00-05') TO ('2026-05-05 00:00:00-05')
TABLESPACE pg_default;

ALTER TABLE IF EXISTS auditoria.auditoria_2026_04
    OWNER to postgres;
CREATE TABLE auditoria.auditoria_2026_05 PARTITION OF auditoria.auditoria
    FOR VALUES FROM ('2026-05-05 00:00:00-05') TO ('2026-06-05 00:00:00-05')
TABLESPACE pg_default;

ALTER TABLE IF EXISTS auditoria.auditoria_2026_05
    OWNER to postgres;
CREATE TABLE auditoria.auditoria_2026_06 PARTITION OF auditoria.auditoria
    FOR VALUES FROM ('2026-06-05 00:00:00-05') TO ('2026-07-05 00:00:00-05')
TABLESPACE pg_default;

ALTER TABLE IF EXISTS auditoria.auditoria_2026_06
    OWNER to postgres;
CREATE TABLE auditoria.auditoria_2026_07 PARTITION OF auditoria.auditoria
    FOR VALUES FROM ('2026-07-05 00:00:00-05') TO ('2026-08-05 00:00:00-05')
TABLESPACE pg_default;

ALTER TABLE IF EXISTS auditoria.auditoria_2026_07
    OWNER to postgres;
CREATE TABLE auditoria.auditoria_2026_08 PARTITION OF auditoria.auditoria
    FOR VALUES FROM ('2026-08-05 00:00:00-05') TO ('2026-09-05 00:00:00-05')
TABLESPACE pg_default;

ALTER TABLE IF EXISTS auditoria.auditoria_2026_08
    OWNER to postgres;
CREATE TABLE auditoria.auditoria_2026_09 PARTITION OF auditoria.auditoria
    FOR VALUES FROM ('2026-09-05 00:00:00-05') TO ('2026-10-05 00:00:00-05')
TABLESPACE pg_default;

ALTER TABLE IF EXISTS auditoria.auditoria_2026_09
    OWNER to postgres;
CREATE TABLE auditoria.auditoria_2026_10 PARTITION OF auditoria.auditoria
    FOR VALUES FROM ('2026-10-05 00:00:00-05') TO ('2026-11-05 00:00:00-05')
TABLESPACE pg_default;

ALTER TABLE IF EXISTS auditoria.auditoria_2026_10
    OWNER to postgres;
CREATE TABLE auditoria.auditoria_2026_11 PARTITION OF auditoria.auditoria
    FOR VALUES FROM ('2026-11-05 00:00:00-05') TO ('2026-12-05 00:00:00-05')
TABLESPACE pg_default;

ALTER TABLE IF EXISTS auditoria.auditoria_2026_11
    OWNER to postgres;
CREATE TABLE auditoria.auditoria_2026_12 PARTITION OF auditoria.auditoria
    FOR VALUES FROM ('2026-12-05 00:00:00-05') TO ('2027-01-05 00:00:00-05')
TABLESPACE pg_default;

ALTER TABLE IF EXISTS auditoria.auditoria_2026_12
    OWNER to postgres;
CREATE TABLE auditoria.auditoria_2027_01 PARTITION OF auditoria.auditoria
    FOR VALUES FROM ('2027-01-05 00:00:00-05') TO ('2027-02-05 00:00:00-05')
TABLESPACE pg_default;

ALTER TABLE IF EXISTS auditoria.auditoria_2027_01
    OWNER to postgres;
CREATE TABLE auditoria.auditoria_2027_02 PARTITION OF auditoria.auditoria
    FOR VALUES FROM ('2027-02-05 00:00:00-05') TO ('2027-03-05 00:00:00-05')
TABLESPACE pg_default;

ALTER TABLE IF EXISTS auditoria.auditoria_2027_02
    OWNER to postgres;
CREATE TABLE auditoria.auditoria_2027_03 PARTITION OF auditoria.auditoria
    FOR VALUES FROM ('2027-03-05 00:00:00-05') TO ('2027-04-05 00:00:00-05')
TABLESPACE pg_default;

ALTER TABLE IF EXISTS auditoria.auditoria_2027_03
    OWNER to postgres;
CREATE TABLE auditoria.auditoria_2027_04 PARTITION OF auditoria.auditoria
    FOR VALUES FROM ('2027-04-05 00:00:00-05') TO ('2027-05-05 00:00:00-05')
TABLESPACE pg_default;

ALTER TABLE IF EXISTS auditoria.auditoria_2027_04
    OWNER to postgres;