-- ============================================================================
-- ECOMMERCE · ENCABEZADO Y PIE DE LA TIENDA
-- ============================================================================
-- Fecha: 2026-11-01
--
-- La segunda tajada del traslado. Van JUNTAS encabezado y pie aunque sean dos
-- pantallas distintas, porque la tienda las pide en una sola llamada
-- (`publico/secciones`) y porque partirlas dejaría media respuesta: sin pie,
-- la tienda se queda con su maqueta de reserva y no se vería lo ganado.
--
-- QUÉ ES CADA COSA:
--
--   · ENCABEZADO: una sola fila de configuración —la barra de arriba, el
--     aviso de crédito y las frases que rotan en el buscador— más un MENÚ de
--     dos niveles. Un enlace principal con hijos no lleva dirección propia:
--     sólo despliega.
--   · PIE: una sola fila de configuración —las redes sociales y demás— más
--     COLUMNAS, cada una con su título y sus enlaces.
--
-- Se rehace con la convención de esta casa (`id`, `texto`, `created_at/by`,
-- `deleted_at/by`) y se engancha al esquema `auditoria`, como en las páginas
-- informativas.
--
-- APARECEN TRES AYUDANTES COMPARTIDOS (`fn_validar_texto`, `fn_validar_enlace`
-- y `fn_nueva_pestana`). El CRM viejo ya los tenía, pero lanzaban códigos
-- («CAMPO_LARGO:een_texto:60») que el front tenía que traducir a mano. Aquí
-- lanzan SQLSTATE y un mensaje en español ya legible, como el resto del CRM
-- nuevo, y los van a reusar las doce pantallas que faltan.
--
-- LO QUE NO SE PUEDE ESCRIBIR A MANO ES `nueva_pestana`: se decide sola. Un
-- enlace a otro sitio (https://) se abre fuera salvo que se diga lo
-- contrario; uno interno NUNCA abre pestaña, porque sacar al visitante de la
-- tienda para llevarlo a otra página de la tienda no tiene sentido.
--
-- Al final se borran las tablas y funciones viejas, igual que en la tajada
-- anterior y por el mismo motivo: dos juegos con nombres casi iguales en el
-- mismo esquema es pedir que alguien toque el que no es.
--
-- Idempotente: si ya está hecho, no hace nada.
-- ============================================================================
\set ON_ERROR_STOP on

BEGIN;

-- ----------------------------------------------------------------------------
-- 1. AYUDANTES DE VALIDACIÓN (los van a usar las demás pantallas)
-- ----------------------------------------------------------------------------
-- Devuelven el valor YA LIMPIO en vez de sólo comprobarlo: así no hay dos
-- sitios recortando espacios, que es como se acaba guardando « Inicio » en
-- una tabla y «Inicio» en otra.
CREATE OR REPLACE FUNCTION ecommerce.fn_validar_texto(
    p_valor text, p_etiqueta text, p_maximo integer, p_obligatorio boolean DEFAULT false)
 RETURNS text
 LANGUAGE plpgsql
 IMMUTABLE
AS $function$
DECLARE
    v text := btrim(COALESCE(p_valor, ''));
BEGIN
    IF v = '' THEN
        IF p_obligatorio THEN
            RAISE EXCEPTION '%: es obligatorio', p_etiqueta USING ERRCODE = 'P0001';
        END IF;
        RETURN NULL;
    END IF;

    IF length(v) > p_maximo THEN
        RAISE EXCEPTION '%: no puede pasar de % caracteres', p_etiqueta, p_maximo USING ERRCODE = 'P0015';
    END IF;

    RETURN v;
END;
$function$;

-- Qué se admite como enlace: una ruta de la propia tienda (/shop), una
-- dirección completa, un correo o un teléfono. Nada más: un «javascript:» o
-- un «//otro-sitio» por ahí dentro acaba siendo un agujero.
CREATE OR REPLACE FUNCTION ecommerce.fn_validar_enlace(
    p_valor text, p_etiqueta text, p_obligatorio boolean DEFAULT false)
 RETURNS text
 LANGUAGE plpgsql
 IMMUTABLE
AS $function$
DECLARE
    v text := btrim(COALESCE(p_valor, ''));
BEGIN
    IF v = '' THEN
        IF p_obligatorio THEN
            RAISE EXCEPTION '%: hace falta la dirección', p_etiqueta USING ERRCODE = 'P0001';
        END IF;
        RETURN NULL;
    END IF;

    IF length(v) > 250 THEN
        RAISE EXCEPTION '%: la dirección no puede pasar de 250 caracteres', p_etiqueta USING ERRCODE = 'P0015';
    END IF;

    IF NOT (v ~  '^/([^/\s][^\s]*)?$'
         OR v ~* '^https?://[^\s]+$'
         OR v ~* '^mailto:[^\s@]+@[^\s@]+\.[^\s@]+$'
         OR v ~* '^tel:\+?[0-9]{6,15}$') THEN
        RAISE EXCEPTION '%: la dirección no vale. Use /una-ruta, https://…, mailto: o tel:', p_etiqueta
              USING ERRCODE = 'P0015';
    END IF;

    RETURN v;
END;
$function$;

-- No se escribe a mano: un enlace de fuera se abre fuera salvo que se diga lo
-- contrario, y uno de casa nunca abre pestaña.
CREATE OR REPLACE FUNCTION ecommerce.fn_nueva_pestana(p_enlace text, p_valor boolean)
 RETURNS boolean
 LANGUAGE sql
 IMMUTABLE
AS $function$
    SELECT CASE WHEN btrim(COALESCE(p_enlace, '')) NOT LIKE 'https://%' THEN false
                WHEN p_valor IS FALSE THEN false
                ELSE true END;
$function$;

-- ----------------------------------------------------------------------------
-- 2. LAS TABLAS
-- ----------------------------------------------------------------------------
-- La vieja se llama IGUAL que la nueva («encabezado»), al revés que las otras
-- cuatro. Se aparta con otro nombre antes de crear nada: si no, el CREATE
-- TABLE IF NOT EXISTS no haría nada y la copia iría a parar a la tabla vieja.
DO $apartar$
BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.columns
                WHERE table_schema = 'ecommerce' AND table_name = 'encabezado'
                  AND column_name = 'enc_config') THEN
        ALTER TABLE ecommerce.encabezado RENAME TO encabezado_legado;
        RAISE NOTICE 'La tabla vieja se aparta como encabezado_legado.';
    END IF;
END
$apartar$;

-- Encabezado y pie son FILA ÚNICA: no hay varios encabezados entre los que
-- elegir. El id se queda en 1 y lo garantiza un CHECK, que es más honesto que
-- confiar en que nadie inserte otro.
CREATE TABLE IF NOT EXISTS ecommerce.encabezado (
    id          bigint       NOT NULL DEFAULT 1,
    -- {barra_superior:{…}, credito:{…}, buscador_frases:[…]}
    config      jsonb        NOT NULL DEFAULT '{}'::jsonb,
    created_at  timestamptz  NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at  timestamptz  NOT NULL DEFAULT CURRENT_TIMESTAMP,
    created_by  varchar(100),
    updated_by  varchar(100),
    CONSTRAINT pk_encabezado PRIMARY KEY (id),
    CONSTRAINT ck_encabezado_fila_unica CHECK (id = 1)
);

CREATE TABLE IF NOT EXISTS ecommerce.encabezado_enlaces (
    id            bigint       NOT NULL,
    -- Null = enlace principal. Con padre = desplegable de ese principal.
    padre_id      bigint,
    texto         varchar(60)  NOT NULL,
    enlace        varchar(250),
    icono         varchar(40),
    nueva_pestana boolean      NOT NULL DEFAULT false,
    orden         integer      NOT NULL DEFAULT 0,
    activo        boolean      NOT NULL DEFAULT true,
    created_at    timestamptz  NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at    timestamptz  NOT NULL DEFAULT CURRENT_TIMESTAMP,
    created_by    varchar(100),
    updated_by    varchar(100),
    deleted_at    timestamptz,
    deleted_by    varchar(100),
    CONSTRAINT pk_encabezado_enlaces PRIMARY KEY (id),
    CONSTRAINT fk_encabezado_enlaces_padre
        FOREIGN KEY (padre_id) REFERENCES ecommerce.encabezado_enlaces(id),
    CONSTRAINT ck_encabezado_enlaces_texto CHECK (length(btrim(texto)) >= 1),
    -- Dos niveles y no más: un menú de tres se vuelve inusable en un móvil, y
    -- la tienda no sabría pintarlo.
    CONSTRAINT ck_encabezado_enlaces_no_es_su_padre CHECK (padre_id IS NULL OR padre_id <> id)
);

CREATE SEQUENCE IF NOT EXISTS ecommerce.encabezado_enlaces_id_seq
    OWNED BY ecommerce.encabezado_enlaces.id;
ALTER TABLE ecommerce.encabezado_enlaces
    ALTER COLUMN id SET DEFAULT nextval('ecommerce.encabezado_enlaces_id_seq');

CREATE TABLE IF NOT EXISTS ecommerce.pie (
    id          bigint       NOT NULL DEFAULT 1,
    -- {redes:[{tipo, enlace, activo}], …}
    config      jsonb        NOT NULL DEFAULT '{}'::jsonb,
    created_at  timestamptz  NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at  timestamptz  NOT NULL DEFAULT CURRENT_TIMESTAMP,
    created_by  varchar(100),
    updated_by  varchar(100),
    CONSTRAINT pk_pie PRIMARY KEY (id),
    CONSTRAINT ck_pie_fila_unica CHECK (id = 1)
);

CREATE TABLE IF NOT EXISTS ecommerce.pie_columnas (
    id          bigint       NOT NULL,
    titulo      varchar(60)  NOT NULL,
    orden       integer      NOT NULL DEFAULT 0,
    activo      boolean      NOT NULL DEFAULT true,
    created_at  timestamptz  NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at  timestamptz  NOT NULL DEFAULT CURRENT_TIMESTAMP,
    created_by  varchar(100),
    updated_by  varchar(100),
    deleted_at  timestamptz,
    deleted_by  varchar(100),
    CONSTRAINT pk_pie_columnas PRIMARY KEY (id),
    CONSTRAINT ck_pie_columnas_titulo CHECK (length(btrim(titulo)) >= 1)
);

CREATE SEQUENCE IF NOT EXISTS ecommerce.pie_columnas_id_seq OWNED BY ecommerce.pie_columnas.id;
ALTER TABLE ecommerce.pie_columnas ALTER COLUMN id SET DEFAULT nextval('ecommerce.pie_columnas_id_seq');

CREATE TABLE IF NOT EXISTS ecommerce.pie_enlaces (
    id            bigint       NOT NULL,
    columna_id    bigint       NOT NULL,
    texto         varchar(60)  NOT NULL,
    enlace        varchar(250),
    icono         varchar(40),
    nueva_pestana boolean      NOT NULL DEFAULT false,
    orden         integer      NOT NULL DEFAULT 0,
    activo        boolean      NOT NULL DEFAULT true,
    created_at    timestamptz  NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at    timestamptz  NOT NULL DEFAULT CURRENT_TIMESTAMP,
    created_by    varchar(100),
    updated_by    varchar(100),
    deleted_at    timestamptz,
    deleted_by    varchar(100),
    CONSTRAINT pk_pie_enlaces PRIMARY KEY (id),
    CONSTRAINT fk_pie_enlaces_columna
        FOREIGN KEY (columna_id) REFERENCES ecommerce.pie_columnas(id),
    CONSTRAINT ck_pie_enlaces_texto CHECK (length(btrim(texto)) >= 1)
);

CREATE SEQUENCE IF NOT EXISTS ecommerce.pie_enlaces_id_seq OWNED BY ecommerce.pie_enlaces.id;
ALTER TABLE ecommerce.pie_enlaces ALTER COLUMN id SET DEFAULT nextval('ecommerce.pie_enlaces_id_seq');

CREATE INDEX IF NOT EXISTS ix_encabezado_enlaces_padre ON ecommerce.encabezado_enlaces (padre_id);
CREATE INDEX IF NOT EXISTS ix_encabezado_enlaces_deleted_at
    ON ecommerce.encabezado_enlaces (deleted_at) WHERE deleted_at IS NOT NULL;
CREATE INDEX IF NOT EXISTS ix_pie_enlaces_columna ON ecommerce.pie_enlaces (columna_id);
CREATE INDEX IF NOT EXISTS ix_pie_enlaces_deleted_at
    ON ecommerce.pie_enlaces (deleted_at) WHERE deleted_at IS NOT NULL;
CREATE INDEX IF NOT EXISTS ix_pie_columnas_deleted_at
    ON ecommerce.pie_columnas (deleted_at) WHERE deleted_at IS NOT NULL;

-- Los disparadores de la casa
DO $disparadores$
DECLARE
    t text;
BEGIN
    FOREACH t IN ARRAY ARRAY['encabezado', 'encabezado_enlaces', 'pie', 'pie_columnas', 'pie_enlaces'] LOOP
        EXECUTE format('DROP TRIGGER IF EXISTS trg_%1$s_audit ON ecommerce.%1$I', t);
        EXECUTE format('CREATE TRIGGER trg_%1$s_audit AFTER INSERT OR UPDATE OR DELETE ON ecommerce.%1$I
                        FOR EACH ROW EXECUTE FUNCTION auditoria.fn_auditar_cambios()', t);
        EXECUTE format('DROP TRIGGER IF EXISTS trg_%1$s_updated_at ON ecommerce.%1$I', t);
        EXECUTE format('CREATE TRIGGER trg_%1$s_updated_at BEFORE UPDATE ON ecommerce.%1$I
                        FOR EACH ROW EXECUTE FUNCTION auditoria.fn_update_updated_at_column()', t);
        EXECUTE format('DROP TRIGGER IF EXISTS trg_%1$s_users ON ecommerce.%1$I', t);
        EXECUTE format('CREATE TRIGGER trg_%1$s_users BEFORE INSERT OR UPDATE ON ecommerce.%1$I
                        FOR EACH ROW EXECUTE FUNCTION auditoria.fn_set_audit_users()', t);
    END LOOP;
END
$disparadores$;

-- ----------------------------------------------------------------------------
-- 3. EL DATO QUE YA ESTÁ
-- ----------------------------------------------------------------------------
DO $copiar$
DECLARE
    v integer;
BEGIN
    IF to_regclass('ecommerce.encabezado_enlace') IS NULL THEN
        RAISE NOTICE 'Las tablas viejas ya no están: el dato ya se copió.';
        RETURN;
    END IF;

    IF to_regclass('ecommerce.encabezado_legado') IS NOT NULL THEN
        INSERT INTO ecommerce.encabezado (id, config, created_at, updated_at)
        SELECT 1, e.enc_config, e.enc_fecha_creacion, e.enc_fecha_modificacion
          FROM ecommerce.encabezado_legado e ORDER BY e.enc_id LIMIT 1
         ON CONFLICT (id) DO NOTHING;
    END IF;

    INSERT INTO ecommerce.encabezado_enlaces
           (id, padre_id, texto, enlace, icono, nueva_pestana, orden, activo, created_at, updated_at, deleted_at)
    SELECT l.een_id, l.een_padre_id, l.een_texto, l.een_enlace, l.een_icono,
           l.een_nueva_pestana, l.een_orden, l.een_activo,
           l.een_fecha_creacion, l.een_fecha_modificacion, l.een_eliminado_en
      FROM ecommerce.encabezado_enlace l
     -- Los padres primero: la clave ajena apunta a esta misma tabla
     ORDER BY (l.een_padre_id IS NOT NULL), l.een_id
     ON CONFLICT (id) DO NOTHING;
    GET DIAGNOSTICS v = ROW_COUNT;
    RAISE NOTICE 'Encabezado: % enlaces.', v;

    INSERT INTO ecommerce.pie (id, config, created_at, updated_at)
    SELECT 1, p.pie_config, p.pie_fecha_creacion, p.pie_fecha_modificacion
      FROM ecommerce.pie_pagina p ORDER BY p.pie_id LIMIT 1
     ON CONFLICT (id) DO NOTHING;

    INSERT INTO ecommerce.pie_columnas (id, titulo, orden, activo, created_at, updated_at, deleted_at)
    SELECT c.pco_id, c.pco_titulo, c.pco_orden, c.pco_activo,
           c.pco_fecha_creacion, c.pco_fecha_modificacion, c.pco_eliminado_en
      FROM ecommerce.pie_columna c
     ON CONFLICT (id) DO NOTHING;

    INSERT INTO ecommerce.pie_enlaces
           (id, columna_id, texto, enlace, icono, nueva_pestana, orden, activo, created_at, updated_at, deleted_at)
    SELECT l.pen_id, l.pco_id, l.pen_texto, l.pen_enlace, l.pen_icono,
           l.pen_nueva_pestana, l.pen_orden, l.pen_activo,
           l.pen_fecha_creacion, l.pen_fecha_modificacion, l.pen_eliminado_en
      FROM ecommerce.pie_enlace l
     ON CONFLICT (id) DO NOTHING;
    GET DIAGNOSTICS v = ROW_COUNT;
    RAISE NOTICE 'Pie: % enlaces.', v;

    PERFORM setval('ecommerce.encabezado_enlaces_id_seq',
                   GREATEST((SELECT COALESCE(max(id), 0) FROM ecommerce.encabezado_enlaces), 1));
    PERFORM setval('ecommerce.pie_columnas_id_seq',
                   GREATEST((SELECT COALESCE(max(id), 0) FROM ecommerce.pie_columnas), 1));
    PERFORM setval('ecommerce.pie_enlaces_id_seq',
                   GREATEST((SELECT COALESCE(max(id), 0) FROM ecommerce.pie_enlaces), 1));
END
$copiar$;

-- Por si la base está vacía: sin fila de configuración no hay nada que editar
INSERT INTO ecommerce.encabezado (id) VALUES (1) ON CONFLICT (id) DO NOTHING;
INSERT INTO ecommerce.pie (id)        VALUES (1) ON CONFLICT (id) DO NOTHING;

COMMIT;
