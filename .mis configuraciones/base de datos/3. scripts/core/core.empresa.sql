-- Table: core.empresa

-- DROP TABLE IF EXISTS core.empresa;

CREATE TABLE IF NOT EXISTS core.empresa
(
    id bigserial NOT NULL,
    ruc character varying(13) COLLATE pg_catalog."default" NOT NULL,
    razon_social character varying(300) COLLATE pg_catalog."default" NOT NULL,
    nombre_comercial character varying(200) COLLATE pg_catalog."default",
    regimen character varying(50) COLLATE pg_catalog."default" DEFAULT 'GENERAL'::character varying,
    es_contribuyente_especial boolean DEFAULT false,
    resolucion_contribuyente_especial text COLLATE pg_catalog."default",
    email character varying(100) COLLATE pg_catalog."default",
    telefono character varying(100) COLLATE pg_catalog."default",
    ubicacion_id bigint NOT NULL,
    direccion text COLLATE pg_catalog."default",
    codigo_postal character varying(10) COLLATE pg_catalog."default",
    representante_legal character varying(200) COLLATE pg_catalog."default",
    contador character varying(200) COLLATE pg_catalog."default",
    ambiente character varying(10) COLLATE pg_catalog."default" DEFAULT 'PRUEBAS'::character varying,
    tipo_emision character varying(10) COLLATE pg_catalog."default" DEFAULT 'NORMAL'::character varying,
    logo_url text COLLATE pg_catalog."default",
    sitio_web character varying(255) COLLATE pg_catalog."default",
    zona_horaria character varying(50) COLLATE pg_catalog."default" DEFAULT 'America/Guayaquil'::character varying,
    formato_fecha character varying(20) COLLATE pg_catalog."default" DEFAULT 'DD/MM/YYYY'::character varying,
    moneda character varying(3) COLLATE pg_catalog."default" DEFAULT 'USD'::character varying,
    simbolo_moneda character varying(5) COLLATE pg_catalog."default" DEFAULT '$'::character varying,
    activo boolean DEFAULT true,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    created_by character varying(100) COLLATE pg_catalog."default",
    updated_by character varying(100) COLLATE pg_catalog."default",
    CONSTRAINT pk_empresa PRIMARY KEY (id),
    CONSTRAINT empresa_ruc_key UNIQUE (ruc),
    CONSTRAINT fk_empresa_ubicacion_id FOREIGN KEY (ubicacion_id)
        REFERENCES core.ubicaciones (id) MATCH SIMPLE
        ON UPDATE NO ACTION
        ON DELETE NO ACTION,
    CONSTRAINT empresa_ambiente_check CHECK (ambiente::text = ANY (ARRAY['PRUEBAS'::character varying::text, 'PRODUCCION'::character varying::text])),
    CONSTRAINT empresa_regimen_check CHECK (regimen::text = ANY (ARRAY['GENERAL'::character varying::text, 'RIMPE'::character varying::text, 'RISE'::character varying::text, 'NEGOCIO_POPULAR'::character varying::text])),
    CONSTRAINT empresa_tipo_emision_check CHECK (tipo_emision::text = ANY (ARRAY['NORMAL'::character varying::text, 'CONTINGENCIA'::character varying::text]))
)

TABLESPACE pg_default;

ALTER TABLE IF EXISTS core.empresa
    OWNER to postgres;

-- Trigger: trg_empresa_audit

-- DROP TRIGGER IF EXISTS trg_empresa_audit ON core.empresa;

CREATE OR REPLACE TRIGGER trg_empresa_audit
    AFTER INSERT OR DELETE OR UPDATE 
    ON core.empresa
    FOR EACH ROW
    EXECUTE FUNCTION auditoria.fn_auditar_cambios();

-- Trigger: trigger_empresa_set_users

-- DROP TRIGGER IF EXISTS trigger_empresa_set_users ON core.empresa;

CREATE OR REPLACE TRIGGER trigger_empresa_set_users
    BEFORE INSERT OR UPDATE 
    ON core.empresa
    FOR EACH ROW
    EXECUTE FUNCTION auditoria.fn_set_audit_users();

-- Trigger: trigger_empresa_updated_at

-- DROP TRIGGER IF EXISTS trigger_empresa_updated_at ON core.empresa;

CREATE OR REPLACE TRIGGER trigger_empresa_updated_at
    BEFORE UPDATE 
    ON core.empresa
    FOR EACH ROW
    EXECUTE FUNCTION auditoria.fn_update_updated_at_column();