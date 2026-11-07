-- ============================================================================
-- ECOMMERCE · LAS MARCAS DE LA TIENDA, CON IMAGEN PROGRAMADA
-- ============================================================================
-- Fecha: 2026-11-01
--
-- Lo mismo que se hizo con las categorías, para las marcas:
--
--   · qué marcas salen en la tienda y con qué nombre   (marcas_web)
--   · su orden en la sección «Nuestras marcas»          (orden_web)
--   · y sus imágenes programadas por fechas            (marcas_imagenes)
--
-- EL CATÁLOGO ES DE INVENTARIOS. Aquí no se crea, ni se borra, ni se renombra
-- una marca: sólo se decide qué hace la tienda con ella.
--
-- LA IMAGEN PROGRAMADA MANDA SOBRE EL LOGO DEL CATÁLOGO. Una marca ya tiene
-- su logo en Inventarios y con eso basta para salir; la imagen de aquí es
-- para la campaña —el logo de navidad, el del aniversario— y sólo mientras
-- esté en fecha. Sin ninguna programada, se usa el logo de siempre: nadie
-- tiene que volver a subir lo que ya está.
--
-- OJO, SON DOS CARPETAS: el logo del catálogo vive en `img/marcas` y las
-- imágenes programadas en `img/ecommerce`. Por eso la función pública
-- devuelve las dos por separado y es el controlador el que arma la dirección
-- de la que toque.
--
-- Idempotente.
-- ============================================================================
\set ON_ERROR_STOP on

BEGIN;

-- ----------------------------------------------------------------------------
-- 1. QUÉ HACE LA TIENDA CON CADA MARCA
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS ecommerce.marcas_web (
    id         bigint       NOT NULL,
    marca_id   bigint       NOT NULL,
    -- Apagada a mano: deja de salir en la tienda
    oculta     boolean      NOT NULL DEFAULT false,
    -- Otro nombre para la tienda; vacío = el del catálogo
    nombre_web varchar(80),
    -- Su sitio en «Nuestras marcas». Nulo = al final
    orden_web  integer,
    created_at timestamptz  NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamptz  NOT NULL DEFAULT CURRENT_TIMESTAMP,
    created_by varchar(100),
    updated_by varchar(100),
    CONSTRAINT pk_marcas_web PRIMARY KEY (id),
    CONSTRAINT uq_marcas_web_marca UNIQUE (marca_id),
    CONSTRAINT fk_marcas_web_marca FOREIGN KEY (marca_id) REFERENCES inventarios.marcas (id)
);

CREATE SEQUENCE IF NOT EXISTS ecommerce.marcas_web_id_seq OWNED BY ecommerce.marcas_web.id;
ALTER TABLE ecommerce.marcas_web ALTER COLUMN id SET DEFAULT nextval('ecommerce.marcas_web_id_seq');

-- ----------------------------------------------------------------------------
-- 2. SUS IMÁGENES, PROGRAMADAS POR FECHAS
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS ecommerce.marcas_imagenes (
    id         bigint       NOT NULL,
    marca_id   bigint       NOT NULL,
    -- El nombre del fichero dentro de img/ecommerce. Nunca una dirección.
    imagen     varchar(150) NOT NULL,
    nombre     varchar(100),
    desde      timestamptz,
    hasta      timestamptz,
    orden      integer      NOT NULL DEFAULT 0,
    activo     boolean      NOT NULL DEFAULT true,
    created_at timestamptz  NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamptz  NOT NULL DEFAULT CURRENT_TIMESTAMP,
    created_by varchar(100),
    updated_by varchar(100),
    deleted_at timestamptz,
    deleted_by varchar(100),
    CONSTRAINT pk_marcas_imagenes PRIMARY KEY (id),
    CONSTRAINT fk_marcas_imagenes_marca FOREIGN KEY (marca_id) REFERENCES inventarios.marcas (id),
    CONSTRAINT ck_marcas_imagenes_vigencia
        CHECK (desde IS NULL OR hasta IS NULL OR hasta >= desde),
    CONSTRAINT ck_marcas_imagenes_fichero
        CHECK (imagen ~ '^[A-Za-z0-9][A-Za-z0-9._-]*\.(jpg|jpeg|png|webp|gif)$')
);

CREATE SEQUENCE IF NOT EXISTS ecommerce.marcas_imagenes_id_seq OWNED BY ecommerce.marcas_imagenes.id;
ALTER TABLE ecommerce.marcas_imagenes ALTER COLUMN id SET DEFAULT nextval('ecommerce.marcas_imagenes_id_seq');

CREATE INDEX IF NOT EXISTS ix_marcas_imagenes_marca
    ON ecommerce.marcas_imagenes (marca_id) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_marcas_imagenes_deleted_at
    ON ecommerce.marcas_imagenes (deleted_at) WHERE deleted_at IS NOT NULL;

DO $disparadores$
DECLARE
    t text;
BEGIN
    FOREACH t IN ARRAY ARRAY['marcas_web', 'marcas_imagenes'] LOOP
        EXECUTE format('DROP TRIGGER IF EXISTS trg_%1$s_audit ON ecommerce.%1$s', t);
        EXECUTE format('CREATE TRIGGER trg_%1$s_audit AFTER INSERT OR UPDATE OR DELETE
                            ON ecommerce.%1$s FOR EACH ROW
                            EXECUTE FUNCTION auditoria.fn_auditar_cambios()', t);
        EXECUTE format('DROP TRIGGER IF EXISTS trg_%1$s_updated_at ON ecommerce.%1$s', t);
        EXECUTE format('CREATE TRIGGER trg_%1$s_updated_at BEFORE UPDATE
                            ON ecommerce.%1$s FOR EACH ROW
                            EXECUTE FUNCTION auditoria.fn_update_updated_at_column()', t);
        EXECUTE format('DROP TRIGGER IF EXISTS trg_%1$s_users ON ecommerce.%1$s', t);
        EXECUTE format('CREATE TRIGGER trg_%1$s_users BEFORE INSERT OR UPDATE
                            ON ecommerce.%1$s FOR EACH ROW
                            EXECUTE FUNCTION auditoria.fn_set_audit_users()', t);
    END LOOP;
END
$disparadores$;

-- ----------------------------------------------------------------------------
-- 3. EL ESTADO DE CADA MARCA
-- ----------------------------------------------------------------------------
-- Más simple que el de las categorías: una marca no cuelga de nadie, así que
-- no hay «apagada por su padre» ni «sin productos debajo».
CREATE OR REPLACE FUNCTION ecommerce.fn_marcas_web_estado()
 RETURNS TABLE(id bigint, nombre text, nombre_catalogo text, logo text,
               oculta boolean, activo boolean, orden_web integer, estado text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
AS $function$
    SELECT m.id,
           COALESCE(NULLIF(btrim(w.nombre_web), ''), m.nombre)::text,
           m.nombre::text,
           m.logo::text,
           COALESCE(w.oculta, false),
           m.activo,
           w.orden_web,
           CASE
               WHEN COALESCE(w.oculta, false) THEN 'oculta'
               WHEN NOT m.activo              THEN 'inactiva'
               ELSE                                'visible'
           END
      FROM inventarios.marcas m
      LEFT JOIN ecommerce.marcas_web w ON w.marca_id = m.id
     WHERE m.deleted_at IS NULL;
$function$;

CREATE OR REPLACE FUNCTION ecommerce.fn_marcas_web_listar()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
AS $function$
    SELECT jsonb_build_object('success', true, 'message', 'Marcas de la tienda',
        'data', COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
                       'id',              e.id,
                       'nombre',          e.nombre,
                       'nombre_catalogo', e.nombre_catalogo,
                       'nombre_web',      w.nombre_web,
                       'logo',            e.logo,
                       'oculta',          e.oculta,
                       'activo',          e.activo,
                       'orden_web',       e.orden_web,
                       'estado',          e.estado)
                   -- En el orden de la TIENDA: es el que se administra aquí
                   ORDER BY e.orden_web NULLS LAST, e.nombre)
              FROM ecommerce.fn_marcas_web_estado() e
              LEFT JOIN ecommerce.marcas_web w ON w.marca_id = e.id), '[]'::jsonb));
$function$;

CREATE OR REPLACE FUNCTION ecommerce.fn_marcas_web_guardar(
    p_marca_id bigint, p_oculta boolean, p_nombre_web character varying,
    p_usuario_id bigint DEFAULT NULL, p_usuario_login character varying DEFAULT NULL,
    p_usuario_nombre character varying DEFAULT NULL, p_ip_address inet DEFAULT NULL,
    p_user_agent text DEFAULT NULL, p_request_id uuid DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'ecommerce', 'auditoria'
AS $function$
DECLARE
    v_nombre   text;
    v_oculta   boolean := COALESCE(p_oculta, false);
    v_catalogo text;
    v_orden    integer;
BEGIN
    PERFORM ecommerce.fn_contexto_auditoria('ecommerce.marcas_web',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    SELECT nombre INTO v_catalogo FROM inventarios.marcas
     WHERE id = p_marca_id AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'La marca no existe' USING ERRCODE = 'P0013';
    END IF;

    v_nombre := ecommerce.fn_validar_texto(p_nombre_web, 'El nombre para la tienda', 80);

    -- El mismo nombre del catálogo no es «otro nombre»: se guarda como nada,
    -- para que al renombrar la marca en Inventarios la tienda la siga.
    IF v_nombre IS NOT NULL AND lower(btrim(v_nombre)) = lower(btrim(v_catalogo)) THEN
        v_nombre := NULL;
    END IF;

    -- El orden que ya tuviera se respeta: esto no es una reordenación
    SELECT orden_web INTO v_orden FROM ecommerce.marcas_web WHERE marca_id = p_marca_id;

    IF v_oculta OR v_nombre IS NOT NULL OR v_orden IS NOT NULL THEN
        INSERT INTO ecommerce.marcas_web (marca_id, oculta, nombre_web, orden_web)
        VALUES (p_marca_id, v_oculta, v_nombre, v_orden)
        ON CONFLICT (marca_id) DO UPDATE
            SET oculta = EXCLUDED.oculta, nombre_web = EXCLUDED.nombre_web;
    ELSE
        -- Visible, con su nombre de siempre y sin orden propio: no hay nada
        -- que guardar, y una fila con todo por omisión sólo estorba.
        DELETE FROM ecommerce.marcas_web WHERE marca_id = p_marca_id;
    END IF;

    RETURN jsonb_build_object('success', true,
        'message', format('«%s» %s', COALESCE(v_nombre, v_catalogo),
                          CASE WHEN v_oculta THEN 'no saldrá en la tienda' ELSE 'saldrá en la tienda' END),
        'data', (ecommerce.fn_marcas_web_listar() -> 'data'));
END;
$function$;

-- El orden de «Nuestras marcas». Llega entero: todas las que salen.
CREATE OR REPLACE FUNCTION ecommerce.fn_marcas_web_ordenar(
    p_ids jsonb,
    p_usuario_id bigint DEFAULT NULL, p_usuario_login character varying DEFAULT NULL,
    p_usuario_nombre character varying DEFAULT NULL, p_ip_address inet DEFAULT NULL,
    p_user_agent text DEFAULT NULL, p_request_id uuid DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'ecommerce', 'auditoria'
AS $function$
DECLARE
    v_recibidas integer;
    v_visibles  integer;
    v_todas     integer;
BEGIN
    PERFORM ecommerce.fn_contexto_auditoria('ecommerce.marcas_web',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    IF p_ids IS NULL OR jsonb_typeof(p_ids) <> 'array' OR jsonb_array_length(p_ids) = 0 THEN
        RAISE EXCEPTION 'Hace falta el orden de las marcas' USING ERRCODE = 'P0001';
    END IF;

    v_recibidas := jsonb_array_length(p_ids);

    SELECT count(*) INTO v_visibles FROM ecommerce.fn_marcas_web_estado() e
     WHERE e.estado = 'visible'
       AND e.id IN (SELECT (x)::bigint FROM jsonb_array_elements_text(p_ids) x);

    SELECT count(*) INTO v_todas FROM ecommerce.fn_marcas_web_estado() WHERE estado = 'visible';

    IF v_visibles <> v_recibidas OR v_recibidas <> v_todas THEN
        RAISE EXCEPTION 'El orden tiene que traer las % marcas de la tienda, y trae % válidas de %',
              v_todas, v_visibles, v_recibidas USING ERRCODE = 'P0016';
    END IF;

    INSERT INTO ecommerce.marcas_web (marca_id, orden_web)
    SELECT (x.valor)::bigint, x.pos
      FROM jsonb_array_elements_text(p_ids) WITH ORDINALITY AS x(valor, pos)
    ON CONFLICT (marca_id) DO UPDATE SET orden_web = EXCLUDED.orden_web;

    RETURN jsonb_build_object('success', true, 'message', 'Orden de las marcas guardado',
                              'data', (ecommerce.fn_marcas_web_listar() -> 'data'));
END;
$function$;

-- ----------------------------------------------------------------------------
-- 4. LAS IMÁGENES DE UNA MARCA
-- ----------------------------------------------------------------------------
-- Calcado de las categorías: con todas, su estado, cuál sale hoy y cuáles
-- quedan tapadas.
CREATE OR REPLACE FUNCTION ecommerce.fn_marcas_imagenes_json(p_marca_id bigint)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
AS $function$
    WITH vivas AS (
        SELECT i.*,
               (i.activo AND ecommerce.fn_vigente(i.desde, i.hasta)) AS vigente
          FROM ecommerce.marcas_imagenes i
         WHERE i.marca_id = p_marca_id AND i.deleted_at IS NULL
    ),
    mandona AS (
        SELECT id FROM vivas WHERE vigente ORDER BY orden, id LIMIT 1
    )
    SELECT jsonb_build_object(
        'marca_id', p_marca_id,
        'en_papelera', (SELECT count(*) FROM ecommerce.marcas_imagenes b
                         WHERE b.marca_id = p_marca_id AND b.deleted_at IS NOT NULL),
        'imagenes', COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
                       'id',         v.id,
                       'imagen',     v.imagen,
                       'nombre',     v.nombre,
                       'desde',      to_char(v.desde, 'YYYY-MM-DD"T"HH24:MI'),
                       'hasta',      to_char(v.hasta, 'YYYY-MM-DD"T"HH24:MI'),
                       'orden',      v.orden,
                       'activo',     v.activo,
                       'sale_ahora', (m.id IS NOT NULL),
                       'tapada',     (v.vigente AND m.id IS NULL),
                       'estado',     CASE
                           WHEN NOT v.activo THEN 'apagada'
                           WHEN v.desde IS NOT NULL AND CURRENT_TIMESTAMP < v.desde THEN 'programada'
                           WHEN v.hasta IS NOT NULL AND CURRENT_TIMESTAMP > v.hasta THEN 'terminada'
                           ELSE 'vigente' END,
                       'updated_at', to_char(v.updated_at, 'YYYY-MM-DD HH24:MI'),
                       'updated_by', v.updated_by)
                   ORDER BY v.orden, v.id)
              FROM vivas v
              LEFT JOIN mandona m ON m.id = v.id), '[]'::jsonb));
$function$;

CREATE OR REPLACE FUNCTION ecommerce.fn_marcas_imagenes_listar(p_marca_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'ecommerce', 'auditoria'
AS $function$
DECLARE
    v_nombre text;
BEGIN
    SELECT nombre INTO v_nombre FROM inventarios.marcas
     WHERE id = p_marca_id AND deleted_at IS NULL;
    IF v_nombre IS NULL THEN
        RAISE EXCEPTION 'La marca no existe' USING ERRCODE = 'P0013';
    END IF;

    RETURN jsonb_build_object('success', true, 'message', format('Imágenes de «%s»', v_nombre),
                              'data', ecommerce.fn_marcas_imagenes_json(p_marca_id));
END;
$function$;

CREATE OR REPLACE FUNCTION ecommerce.fn_marcas_imagenes_cuentas()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
AS $function$
    SELECT jsonb_build_object('success', true, 'message', 'Imágenes por marca',
        'data', COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
                       'marca_id',    x.marca_id,
                       'cuantas',     x.cuantas,
                       'sale_alguna', x.sale_alguna))
              FROM (SELECT i.marca_id,
                           count(*) AS cuantas,
                           bool_or(i.activo AND ecommerce.fn_vigente(i.desde, i.hasta)) AS sale_alguna
                      FROM ecommerce.marcas_imagenes i
                     WHERE i.deleted_at IS NULL
                     GROUP BY i.marca_id) x), '[]'::jsonb));
$function$;

CREATE OR REPLACE FUNCTION ecommerce.fn_marcas_imagenes_guardar(
    p_id bigint, p_marca_id bigint, p_datos jsonb,
    p_usuario_id bigint DEFAULT NULL, p_usuario_login character varying DEFAULT NULL,
    p_usuario_nombre character varying DEFAULT NULL, p_ip_address inet DEFAULT NULL,
    p_user_agent text DEFAULT NULL, p_request_id uuid DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'ecommerce', 'auditoria'
AS $function$
DECLARE
    v_imagen text;
    v_desde  timestamptz;
    v_hasta  timestamptz;
    v_orden  integer;
    v_nuevo  boolean := p_id IS NULL;
BEGIN
    PERFORM ecommerce.fn_contexto_auditoria('ecommerce.marcas_imagenes',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    IF NOT EXISTS (SELECT 1 FROM inventarios.marcas WHERE id = p_marca_id AND deleted_at IS NULL) THEN
        RAISE EXCEPTION 'La marca no existe' USING ERRCODE = 'P0013';
    END IF;

    IF NOT v_nuevo AND NOT EXISTS (SELECT 1 FROM ecommerce.marcas_imagenes
                                    WHERE id = p_id AND marca_id = p_marca_id
                                      AND deleted_at IS NULL) THEN
        RAISE EXCEPTION 'La imagen no existe en esta marca' USING ERRCODE = 'P0013';
    END IF;

    v_imagen := btrim(COALESCE(p_datos ->> 'imagen', ''));
    IF v_imagen = '' THEN
        RAISE EXCEPTION 'Hace falta la imagen' USING ERRCODE = 'P0001';
    END IF;
    IF v_imagen !~ '^[A-Za-z0-9][A-Za-z0-9._-]*\.(jpg|jpeg|png|webp|gif)$' THEN
        RAISE EXCEPTION 'La imagen tiene que ser un fichero subido (jpg, png, webp o gif)'
              USING ERRCODE = 'P0015';
    END IF;

    v_desde := nullif(btrim(COALESCE(p_datos ->> 'desde', '')), '')::timestamptz;
    v_hasta := nullif(btrim(COALESCE(p_datos ->> 'hasta', '')), '')::timestamptz;
    IF v_desde IS NOT NULL AND v_hasta IS NOT NULL AND v_hasta < v_desde THEN
        RAISE EXCEPTION 'Las fechas van al revés: «hasta» es anterior a «desde»' USING ERRCODE = 'P0015';
    END IF;

    IF v_nuevo THEN
        SELECT COALESCE(max(orden), 0) + 1 INTO v_orden FROM ecommerce.marcas_imagenes
         WHERE marca_id = p_marca_id AND deleted_at IS NULL;

        INSERT INTO ecommerce.marcas_imagenes (marca_id, imagen, nombre, desde, hasta, orden, activo)
        VALUES (p_marca_id, v_imagen,
                ecommerce.fn_validar_texto(p_datos ->> 'nombre', 'El nombre', 100),
                v_desde, v_hasta, v_orden,
                COALESCE((p_datos ->> 'activo')::boolean, true));
    ELSE
        UPDATE ecommerce.marcas_imagenes
           SET imagen = v_imagen,
               nombre = ecommerce.fn_validar_texto(p_datos ->> 'nombre', 'El nombre', 100),
               desde  = v_desde,
               hasta  = v_hasta,
               activo = COALESCE((p_datos ->> 'activo')::boolean, true)
         WHERE id = p_id;
    END IF;

    RETURN jsonb_build_object('success', true,
        'message', CASE WHEN v_nuevo THEN 'Imagen programada' ELSE 'Imagen guardada' END,
        'data', ecommerce.fn_marcas_imagenes_json(p_marca_id));
END;
$function$;

CREATE OR REPLACE FUNCTION ecommerce.fn_marcas_imagenes_activar(
    p_id bigint, p_activo boolean,
    p_usuario_id bigint DEFAULT NULL, p_usuario_login character varying DEFAULT NULL,
    p_usuario_nombre character varying DEFAULT NULL, p_ip_address inet DEFAULT NULL,
    p_user_agent text DEFAULT NULL, p_request_id uuid DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'ecommerce', 'auditoria'
AS $function$
DECLARE
    v_marca bigint;
    v_nuevo boolean;
BEGIN
    PERFORM ecommerce.fn_contexto_auditoria('ecommerce.marcas_imagenes',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    SELECT marca_id, COALESCE(p_activo, NOT activo) INTO v_marca, v_nuevo
      FROM ecommerce.marcas_imagenes WHERE id = p_id AND deleted_at IS NULL;
    IF v_marca IS NULL THEN
        RAISE EXCEPTION 'La imagen no existe' USING ERRCODE = 'P0013';
    END IF;

    UPDATE ecommerce.marcas_imagenes SET activo = v_nuevo WHERE id = p_id;

    RETURN jsonb_build_object('success', true,
        'message', CASE WHEN v_nuevo THEN 'Imagen encendida' ELSE 'Imagen apagada' END,
        'data', ecommerce.fn_marcas_imagenes_json(v_marca));
END;
$function$;

CREATE OR REPLACE FUNCTION ecommerce.fn_marcas_imagenes_ordenar(
    p_ids jsonb,
    p_usuario_id bigint DEFAULT NULL, p_usuario_login character varying DEFAULT NULL,
    p_usuario_nombre character varying DEFAULT NULL, p_ip_address inet DEFAULT NULL,
    p_user_agent text DEFAULT NULL, p_request_id uuid DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'ecommerce', 'auditoria'
AS $function$
DECLARE
    v_marca    bigint;
    v_cuantas  integer;
    v_recibido integer;
BEGIN
    PERFORM ecommerce.fn_contexto_auditoria('ecommerce.marcas_imagenes',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    IF p_ids IS NULL OR jsonb_typeof(p_ids) <> 'array' OR jsonb_array_length(p_ids) = 0 THEN
        RAISE EXCEPTION 'Hace falta el orden de las imágenes' USING ERRCODE = 'P0001';
    END IF;

    SELECT count(DISTINCT i.marca_id), count(*) INTO v_cuantas, v_recibido
      FROM ecommerce.marcas_imagenes i
     WHERE i.id IN (SELECT (x)::bigint FROM jsonb_array_elements_text(p_ids) x)
       AND i.deleted_at IS NULL;

    IF v_cuantas <> 1 OR v_recibido <> jsonb_array_length(p_ids) THEN
        RAISE EXCEPTION 'El orden no corresponde a una sola marca' USING ERRCODE = 'P0016';
    END IF;

    SELECT DISTINCT marca_id INTO v_marca FROM ecommerce.marcas_imagenes
     WHERE id IN (SELECT (x)::bigint FROM jsonb_array_elements_text(p_ids) x);

    UPDATE ecommerce.marcas_imagenes i
       SET orden = n.pos
      FROM (SELECT (x.valor)::bigint AS id, x.pos
              FROM jsonb_array_elements_text(p_ids) WITH ORDINALITY AS x(valor, pos)) n
     WHERE i.id = n.id;

    RETURN jsonb_build_object('success', true, 'message', 'Orden guardado',
                              'data', ecommerce.fn_marcas_imagenes_json(v_marca));
END;
$function$;

CREATE OR REPLACE FUNCTION ecommerce.fn_marcas_imagenes_eliminar(
    p_id bigint,
    p_usuario_id bigint DEFAULT NULL, p_usuario_login character varying DEFAULT NULL,
    p_usuario_nombre character varying DEFAULT NULL, p_ip_address inet DEFAULT NULL,
    p_user_agent text DEFAULT NULL, p_request_id uuid DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'ecommerce', 'auditoria'
AS $function$
DECLARE
    v_marca bigint;
BEGIN
    PERFORM ecommerce.fn_contexto_auditoria('ecommerce.marcas_imagenes',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    SELECT marca_id INTO v_marca FROM ecommerce.marcas_imagenes
     WHERE id = p_id AND deleted_at IS NULL;
    IF v_marca IS NULL THEN
        RAISE EXCEPTION 'La imagen no existe' USING ERRCODE = 'P0013';
    END IF;

    UPDATE ecommerce.marcas_imagenes
       SET deleted_at = CURRENT_TIMESTAMP,
           deleted_by = COALESCE(current_setting('app.usuario_login', true), current_user)
     WHERE id = p_id;

    RETURN jsonb_build_object('success', true, 'message', 'Imagen quitada',
                              'data', ecommerce.fn_marcas_imagenes_json(v_marca));
END;
$function$;

CREATE OR REPLACE FUNCTION ecommerce.fn_marcas_imagenes_papelera(p_marca_id bigint)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
AS $function$
    SELECT jsonb_build_object('success', true, 'message', 'Papelera de la marca',
        'data', COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
                       'id', i.id, 'imagen', i.imagen, 'nombre', i.nombre,
                       'deleted_at', to_char(i.deleted_at, 'YYYY-MM-DD HH24:MI'),
                       'deleted_by', i.deleted_by)
                   ORDER BY i.deleted_at DESC)
              FROM ecommerce.marcas_imagenes i
             WHERE i.marca_id = p_marca_id AND i.deleted_at IS NOT NULL), '[]'::jsonb));
$function$;

CREATE OR REPLACE FUNCTION ecommerce.fn_marcas_imagenes_restaurar(
    p_ids jsonb,
    p_usuario_id bigint DEFAULT NULL, p_usuario_login character varying DEFAULT NULL,
    p_usuario_nombre character varying DEFAULT NULL, p_ip_address inet DEFAULT NULL,
    p_user_agent text DEFAULT NULL, p_request_id uuid DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'ecommerce', 'auditoria'
AS $function$
DECLARE
    v_marca   bigint;
    v_cuantas integer;
    v_borradas integer;
BEGIN
    PERFORM ecommerce.fn_contexto_auditoria('ecommerce.marcas_imagenes',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    IF p_ids IS NULL OR jsonb_typeof(p_ids) <> 'array' OR jsonb_array_length(p_ids) = 0 THEN
        RAISE EXCEPTION 'Hace falta decir qué imágenes restaurar' USING ERRCODE = 'P0001';
    END IF;

    SELECT count(DISTINCT i.marca_id), count(*) INTO v_cuantas, v_borradas
      FROM ecommerce.marcas_imagenes i
     WHERE i.id IN (SELECT (x)::bigint FROM jsonb_array_elements_text(p_ids) x)
       AND i.deleted_at IS NOT NULL;

    IF v_borradas <> jsonb_array_length(p_ids) THEN
        RAISE EXCEPTION 'Alguna de esas imágenes no está en la papelera' USING ERRCODE = 'P0019';
    END IF;
    IF v_cuantas <> 1 THEN
        RAISE EXCEPTION 'Las imágenes tienen que ser de una sola marca' USING ERRCODE = 'P0016';
    END IF;

    SELECT DISTINCT marca_id INTO v_marca FROM ecommerce.marcas_imagenes
     WHERE id IN (SELECT (x)::bigint FROM jsonb_array_elements_text(p_ids) x);

    UPDATE ecommerce.marcas_imagenes
       SET deleted_at = NULL, deleted_by = NULL,
           orden = (SELECT COALESCE(max(x.orden), 0) FROM ecommerce.marcas_imagenes x
                     WHERE x.marca_id = v_marca AND x.deleted_at IS NULL) + 1
     WHERE id IN (SELECT (x)::bigint FROM jsonb_array_elements_text(p_ids) x);

    RETURN jsonb_build_object('success', true,
        'message', format('%s imagen(es) restaurada(s)', jsonb_array_length(p_ids)),
        'data', ecommerce.fn_marcas_imagenes_json(v_marca));
END;
$function$;

-- Vacía la papelera y devuelve los ficheros que ya no usa nadie, para que el
-- controlador los borre. Se mira también en las de categorías: la misma
-- imagen puede estar programada en las dos.
CREATE OR REPLACE FUNCTION ecommerce.fn_marcas_imagenes_vaciar(
    p_marca_id bigint,
    p_usuario_id bigint DEFAULT NULL, p_usuario_login character varying DEFAULT NULL,
    p_usuario_nombre character varying DEFAULT NULL, p_ip_address inet DEFAULT NULL,
    p_user_agent text DEFAULT NULL, p_request_id uuid DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'ecommerce', 'auditoria'
AS $function$
DECLARE
    v_ficheros jsonb;
    v_cuantas  integer;
BEGIN
    PERFORM ecommerce.fn_contexto_auditoria('ecommerce.marcas_imagenes',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    WITH borradas AS (
        DELETE FROM ecommerce.marcas_imagenes
         WHERE marca_id = p_marca_id AND deleted_at IS NOT NULL
        RETURNING imagen
    )
    SELECT COALESCE(jsonb_agg(DISTINCT b.imagen), '[]'::jsonb), count(*)
      INTO v_ficheros, v_cuantas
      FROM borradas b;

    SELECT COALESCE(jsonb_agg(f.valor), '[]'::jsonb) INTO v_ficheros
      FROM jsonb_array_elements_text(v_ficheros) f(valor)
     WHERE NOT EXISTS (SELECT 1 FROM ecommerce.marcas_imagenes x WHERE x.imagen = f.valor)
       AND NOT EXISTS (SELECT 1 FROM ecommerce.categorias_imagenes y WHERE y.imagen = f.valor);

    RETURN jsonb_build_object('success', true,
        'message', format('Papelera vaciada: %s imagen(es)', v_cuantas),
        'data', jsonb_build_object(
            'ficheros', v_ficheros,
            'marca', ecommerce.fn_marcas_imagenes_json(p_marca_id)));
END;
$function$;

-- ----------------------------------------------------------------------------
-- 5. LO QUE VE LA TIENDA
-- ----------------------------------------------------------------------------
-- Las marcas que salen, en su orden, con la imagen que toque hoy: la
-- programada si hay alguna en fecha, y si no el logo del catálogo. Las dos
-- están en carpetas distintas, así que van por separado y el controlador
-- arma la dirección de la que haya.
CREATE OR REPLACE FUNCTION ecommerce.fn_marcas_publicas()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
AS $function$
    WITH visibles AS (
        SELECT e.id, e.nombre, e.logo, e.orden_web
          FROM ecommerce.fn_marcas_web_estado() e
         WHERE e.estado = 'visible'
    ),
    mandona AS (
        SELECT DISTINCT ON (i.marca_id) i.marca_id, i.imagen
          FROM ecommerce.marcas_imagenes i
         WHERE i.deleted_at IS NULL AND i.activo
           AND ecommerce.fn_vigente(i.desde, i.hasta)
         ORDER BY i.marca_id, i.orden, i.id
    )
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'id', v.id,
               'nombre', v.nombre,
               -- La programada, si hay; el controlador le pone img/ecommerce
               'imagen', m.imagen,
               -- El del catálogo, que vive en img/marcas
               'logo', v.logo,
               'enlace', '/shop?marca=' || v.id)
           ORDER BY v.orden_web NULLS LAST, v.nombre), '[]'::jsonb)
      FROM visibles v
      LEFT JOIN mandona m ON m.marca_id = v.id;
$function$;

-- ----------------------------------------------------------------------------
-- 6. LA SECCIÓN «NUESTRAS MARCAS» YA NO ESTÁ PENDIENTE
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ecommerce.fn_inicio_fuente(p_clave text)
 RETURNS jsonb
 LANGUAGE sql
 IMMUTABLE
AS $function$
    SELECT CASE p_clave
        WHEN 'banner_principal' THEN
            jsonb_build_object('tipo', 'galeria', 'galeria', 'inicio_banner')
        WHEN 'banner_simple' THEN
            jsonb_build_object('tipo', 'galeria', 'galeria', 'inicio_banner_simple')
        WHEN 'mosaico' THEN
            jsonb_build_object('tipo', 'promocion', 'pantalla', 'allCategoriasWeb')
        WHEN 'categorias_destacadas' THEN
            jsonb_build_object('tipo', 'destacadas', 'pantalla', 'allCategoriasWeb')
        WHEN 'marcas' THEN
            jsonb_build_object('tipo', 'marcas', 'pantalla', 'allMarcasWeb')
        WHEN 'ofertas_flash' THEN
            jsonb_build_object('tipo', 'pendiente', 'falta', 'el catálogo de la tienda (precio y existencias)')
        WHEN 'grilla' THEN
            jsonb_build_object('tipo', 'pendiente', 'falta', 'el catálogo de la tienda (precio y existencias)')
        WHEN 'bloques' THEN
            jsonb_build_object('tipo', 'pendiente', 'falta', 'los bloques de productos destacados')
        ELSE jsonb_build_object('tipo', 'pendiente', 'falta', 'su fuente')
    END;
$function$;

CREATE OR REPLACE FUNCTION ecommerce.fn_inicio_listar()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
AS $function$
    SELECT jsonb_build_object('success', true, 'message', 'Portada de la tienda',
        'data', COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
                       'id',         s.id,
                       'clave',      s.clave,
                       'nombre',     s.nombre,
                       'titulo',     s.titulo,
                       'subtitulo',  s.subtitulo,
                       'orden',      s.orden,
                       'activo',     s.activo,
                       'desde',      to_char(s.desde, 'YYYY-MM-DD"T"HH24:MI'),
                       'hasta',      to_char(s.hasta, 'YYYY-MM-DD"T"HH24:MI'),
                       'updated_at', to_char(s.updated_at, 'YYYY-MM-DD HH24:MI'),
                       'updated_by', s.updated_by,
                       'estado',     CASE
                           WHEN NOT s.activo THEN 'oculta'
                           WHEN s.desde IS NOT NULL AND CURRENT_TIMESTAMP < s.desde THEN 'programada'
                           WHEN s.hasta IS NOT NULL AND CURRENT_TIMESTAMP > s.hasta THEN 'terminada'
                           ELSE 'visible' END,
                       'fuente',     ecommerce.fn_inicio_fuente(s.clave),
                       'cuantas',    CASE ecommerce.fn_inicio_fuente(s.clave) ->> 'tipo'
                           WHEN 'galeria' THEN
                               (SELECT count(*) FROM ecommerce.galerias_imagenes i
                                  JOIN ecommerce.galerias g ON g.id = i.galeria_id
                                 WHERE g.clave = ecommerce.fn_inicio_fuente(s.clave) ->> 'galeria'
                                   AND i.deleted_at IS NULL)
                           WHEN 'promocion' THEN
                               jsonb_array_length(ecommerce.fn_categorias_promocion_publicas())
                           WHEN 'destacadas' THEN
                               jsonb_array_length(ecommerce.fn_categorias_destacadas_publicas())
                           WHEN 'marcas' THEN
                               jsonb_array_length(ecommerce.fn_marcas_publicas())
                           END,
                       'con_contenido', CASE ecommerce.fn_inicio_fuente(s.clave) ->> 'tipo'
                           WHEN 'galeria' THEN
                               EXISTS (SELECT 1 FROM ecommerce.galerias_imagenes i
                                         JOIN ecommerce.galerias g ON g.id = i.galeria_id
                                        WHERE g.clave = ecommerce.fn_inicio_fuente(s.clave) ->> 'galeria'
                                          AND i.deleted_at IS NULL AND i.activo
                                          AND ecommerce.fn_vigente(i.desde, i.hasta))
                           WHEN 'promocion' THEN
                               jsonb_array_length(ecommerce.fn_categorias_promocion_publicas()) > 0
                           WHEN 'destacadas' THEN
                               jsonb_array_length(ecommerce.fn_categorias_destacadas_publicas()) > 0
                           -- La tienda sólo pinta las que tienen logo: una
                           -- marca sin imagen no cuenta como contenido.
                           WHEN 'marcas' THEN
                               EXISTS (SELECT 1 FROM jsonb_array_elements(ecommerce.fn_marcas_publicas()) m
                                        WHERE COALESCE(m ->> 'imagen', m ->> 'logo') IS NOT NULL)
                           ELSE false END)
                   ORDER BY s.orden, s.id)
              FROM ecommerce.inicio_secciones s), '[]'::jsonb));
$function$;

CREATE OR REPLACE FUNCTION ecommerce.fn_inicio_publico()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
AS $function$
    WITH visibles AS (
        SELECT s.clave, s.titulo, s.subtitulo, s.hasta, s.orden
          FROM ecommerce.inicio_secciones s
         WHERE s.activo AND ecommerce.fn_vigente(s.desde, s.hasta)
    ),
    armadas AS (
        SELECT v.orden, v.clave,
               CASE v.clave
                   WHEN 'banner_principal' THEN
                        jsonb_build_object('clave', v.clave,
                            'imagenes', COALESCE(ecommerce.fn_galerias_publica('inicio_banner') -> 'imagenes', '[]'::jsonb))
                   WHEN 'banner_simple' THEN
                        jsonb_build_object('clave', v.clave,
                            'imagenes', COALESCE(ecommerce.fn_galerias_publica('inicio_banner_simple') -> 'imagenes', '[]'::jsonb))
                   WHEN 'mosaico' THEN
                        jsonb_build_object('clave', v.clave,
                            'categorias', ecommerce.fn_categorias_promocion_publicas())
                   WHEN 'categorias_destacadas' THEN
                        jsonb_build_object('clave', v.clave,
                            'categorias', ecommerce.fn_categorias_destacadas_publicas())
                   WHEN 'marcas' THEN
                        jsonb_build_object('clave', v.clave,
                            'marcas', ecommerce.fn_marcas_publicas())
                   ELSE NULL
               END AS seccion
          FROM visibles v
    )
    SELECT jsonb_build_object('secciones', COALESCE(jsonb_agg(a.seccion ORDER BY a.orden), '[]'::jsonb))
      FROM armadas a
     WHERE a.seccion IS NOT NULL
       AND (a.seccion -> 'imagenes'   IS NULL OR jsonb_array_length(a.seccion -> 'imagenes') > 0)
       AND (a.seccion -> 'categorias' IS NULL OR jsonb_array_length(a.seccion -> 'categorias') > 0)
       AND (a.seccion -> 'marcas'     IS NULL OR jsonb_array_length(a.seccion -> 'marcas') > 0);
$function$;

-- ----------------------------------------------------------------------------
-- 7. QUE HAGA LO QUE DICE
-- ----------------------------------------------------------------------------
DO $comprobar$
DECLARE
    v_marca   bigint;
    v_nombre  text;
    v_fuente  text;
    v_cuantas integer;
    v_con     integer;
    v_sin     integer;
    v_fallo   text;
BEGIN
    SELECT ecommerce.fn_inicio_fuente('marcas') ->> 'tipo' INTO v_fuente;
    IF v_fuente IS DISTINCT FROM 'marcas' THEN
        RAISE EXCEPTION 'La sección de marcas sigue sin fuente (dice «%»)', COALESCE(v_fuente, 'nada');
    END IF;

    SELECT count(*) INTO v_cuantas FROM ecommerce.fn_marcas_web_estado() WHERE estado = 'visible';
    IF v_cuantas IS NULL OR v_cuantas = 0 THEN
        RAISE EXCEPTION 'Ninguna marca sale en la tienda: no se puede comprobar';
    END IF;

    SELECT e.id, e.nombre INTO v_marca, v_nombre
      FROM ecommerce.fn_marcas_web_estado() e WHERE e.estado = 'visible' ORDER BY e.nombre LIMIT 1;

    -- Sale en la lista pública
    SELECT count(*) INTO v_con
      FROM jsonb_array_elements(ecommerce.fn_marcas_publicas()) m
     WHERE (m ->> 'id')::bigint = v_marca;

    -- Apagada no sale
    PERFORM ecommerce.fn_marcas_web_guardar(v_marca, true, NULL);
    SELECT count(*) INTO v_sin
      FROM jsonb_array_elements(ecommerce.fn_marcas_publicas()) m
     WHERE (m ->> 'id')::bigint = v_marca;

    -- Un orden a medias no entra
    v_fallo := NULL;
    BEGIN
        PERFORM ecommerce.fn_marcas_web_ordenar(jsonb_build_array(v_marca));
    EXCEPTION WHEN SQLSTATE 'P0016' THEN v_fallo := 'bien';
    END;

    -- Se deja como estaba ANTES de juzgar
    PERFORM ecommerce.fn_marcas_web_guardar(v_marca, false, NULL);

    IF v_con <> 1 THEN
        RAISE EXCEPTION 'La marca «%» debería salir en la tienda (salió % veces)', v_nombre, v_con;
    END IF;
    IF v_sin <> 0 THEN
        RAISE EXCEPTION 'Apagada no debería salir, y salió % veces', v_sin;
    END IF;
    IF v_fallo IS NULL THEN
        RAISE EXCEPTION 'Se tragó un orden con una sola marca de %', v_cuantas;
    END IF;

    RAISE NOTICE 'Comprobado: % marcas en la tienda, apagarlas las saca y el orden entra entero o no entra.',
          v_cuantas;
END
$comprobar$;

COMMIT;
