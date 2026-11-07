-- ============================================================================
-- ECOMMERCE · PÁGINAS INFORMATIVAS (primera tajada de la página web)
-- ============================================================================
-- Fecha: 2026-10-31
--
-- Lo que restauramos del CRM viejo trae su propia convención: `pin_id`,
-- `pin_titulo`, `usu_id`, `pin_fecha_creacion`, `pin_eliminado_en`. Aquí se
-- rehace con la de esta casa —`id`, `titulo`, `created_at/by`,
-- `deleted_at/by`— y se engancha al esquema `auditoria`, que es lo que hacen
-- los otros módulos.
--
-- Se empieza por aquí porque es la pantalla que menos depende del catálogo:
-- fija el patrón que seguirán las otras catorce.
--
-- QUÉ SON. Las páginas de sólo texto de la tienda: términos, políticas,
-- garantías, «Conócenos». Cada una tiene una CLAVE estable (`terminos`,
-- `garantia`) porque la tienda las pide por ahí, no por id. Las FIJAS son las
-- que la tienda tiene en una ruta propia (/politicas-de-garantia); no se
-- borran ni se meten en carpeta. Las demás se agrupan en CARPETAS y salen
-- listadas en /documentos.
--
-- CAMBIA UNA COSA DE FONDO: el PDF y la imagen se guardaban como URL ABSOLUTA,
-- con el servidor dentro:
--
--     "pdf": "http://192.168.1.146:8009/api/public/pagina-web/documentos/5IMB….pdf"
--
-- Así, mover el servidor de sitio deja la base apuntando a donde ya no está, y
-- copiar los datos a otra máquina se trae el host viejo puesto. Ahora se
-- guarda SÓLO EL NOMBRE DEL FICHERO y la dirección la arma el controlador al
-- leer. Al copiar los datos se recorta lo que ya estaba guardado.
--
-- LA PAPELERA ES UNA SOLA para páginas y carpetas, a diferencia del resto de
-- la casa donde va una por entidad: en la pantalla es un único cesto con dos
-- niveles (la carpeta y, debajo, las páginas que se fueron con ella), y
-- partirla en dos obligaría a pintar dos listas que el usuario ve como una.
--
-- AL FINAL SE BORRA LO VIEJO: las dos tablas con prefijos y sus 24 funciones,
-- en la misma transacción y sólo después de comprobar que el dato está
-- completo en las nuevas. No rompe nada: la tienda de hoy habla con el CRM
-- viejo, que vive en otra base (alm10-9-2026), no en ésta.
--
-- Idempotente: si ya está hecho, no hace nada.
-- ============================================================================
\set ON_ERROR_STOP on

BEGIN;

-- ----------------------------------------------------------------------------
-- 0. LO COMÚN DEL ESQUEMA
-- ----------------------------------------------------------------------------
-- Cada módulo tiene su propio contexto de auditoría (inventarios, ventas, rh y
-- contabilidad ya lo tienen); ecommerce necesita el suyo. Es lo que deja el
-- usuario, la IP y el request en variables de sesión para que los disparadores
-- de `auditoria` los recojan.
CREATE OR REPLACE FUNCTION ecommerce.fn_contexto_auditoria(
    p_modulo text,
    p_usuario_id bigint DEFAULT NULL,
    p_usuario_login character varying DEFAULT NULL,
    p_usuario_nombre character varying DEFAULT NULL,
    p_ip_address inet DEFAULT NULL,
    p_user_agent text DEFAULT NULL,
    p_request_id uuid DEFAULT NULL)
 RETURNS void
 LANGUAGE plpgsql
AS $function$
BEGIN
    PERFORM set_config('app.usuario_id',     COALESCE(p_usuario_id::text, ''), true);
    PERFORM set_config('app.usuario_login',  COALESCE(p_usuario_login, current_user), true);
    PERFORM set_config('app.usuario_nombre', COALESCE(p_usuario_nombre, current_user), true);
    PERFORM set_config('app.ip_address',     COALESCE(p_ip_address::text, ''), true);
    PERFORM set_config('app.user_agent',     COALESCE(p_user_agent, ''), true);
    PERFORM set_config('app.request_id',     COALESCE(p_request_id::text, ''), true);
    PERFORM set_config('app.modulo',         p_modulo, true);
END;
$function$;

-- Para el único por nombre de las carpetas: «Legales» y «legales » son la
-- misma. Propia del esquema y no prestada de inventarios: un módulo, lo suyo.
CREATE OR REPLACE FUNCTION ecommerce.fn_normalizar_nombre(p_texto text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE PARALLEL SAFE
AS $function$
    SELECT btrim(regexp_replace(
               lower(translate(COALESCE(p_texto, ''),
                     'ÁÉÍÓÚÀÈÌÒÙÄËÏÖÜÂÊÎÔÛÑÇáéíóúàèìòùäëïöüâêîôûñç',
                     'AEIOUAEIOUAEIOUAEIOUNCaeiouaeiouaeiouaeiounc')),
               '\s+', ' ', 'g'));
$function$;

-- La clave de una página: lo que va en la dirección de la tienda.
CREATE OR REPLACE FUNCTION ecommerce.fn_paginas_informativas_slug(p_texto text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
AS $function$
    SELECT left(btrim(regexp_replace(
               lower(translate(COALESCE(p_texto, ''), 'ÁÉÍÓÚÜÑáéíóúüñ', 'AEIOUUNaeiouun')),
               '[^a-z0-9]+', '-', 'g'), '-'), 50);
$function$;

-- ----------------------------------------------------------------------------
-- 1. LAS TABLAS
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS ecommerce.paginas_informativas_grupos (
    id          bigint       NOT NULL,
    nombre      varchar(60)  NOT NULL,
    orden       integer      NOT NULL DEFAULT 0,
    created_at  timestamptz  NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at  timestamptz  NOT NULL DEFAULT CURRENT_TIMESTAMP,
    created_by  varchar(100),
    updated_by  varchar(100),
    deleted_at  timestamptz,
    deleted_by  varchar(100),
    CONSTRAINT pk_paginas_informativas_grupos PRIMARY KEY (id),
    CONSTRAINT ck_paginas_informativas_grupos_nombre CHECK (length(btrim(nombre)) >= 2)
);

CREATE SEQUENCE IF NOT EXISTS ecommerce.paginas_informativas_grupos_id_seq
    OWNED BY ecommerce.paginas_informativas_grupos.id;
ALTER TABLE ecommerce.paginas_informativas_grupos
    ALTER COLUMN id SET DEFAULT nextval('ecommerce.paginas_informativas_grupos_id_seq');

CREATE TABLE IF NOT EXISTS ecommerce.paginas_informativas (
    id          bigint       NOT NULL,
    -- La dirección de la tienda: /paginas/{clave}. Estable aunque cambie el título.
    clave       varchar(50)  NOT NULL,
    titulo      varchar(120) NOT NULL,
    grupo_id    bigint,
    -- {texto, imagen, imagen_alt, pdf, desplegables:[{titulo,texto,pdf,boton}]}
    contenido   jsonb        NOT NULL DEFAULT '{}'::jsonb,
    -- La tienda le tiene una ruta propia: ni se borra ni se mete en carpeta
    fija        boolean      NOT NULL DEFAULT false,
    orden       integer      NOT NULL DEFAULT 0,
    activo      boolean      NOT NULL DEFAULT true,
    created_at  timestamptz  NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at  timestamptz  NOT NULL DEFAULT CURRENT_TIMESTAMP,
    created_by  varchar(100),
    updated_by  varchar(100),
    deleted_at  timestamptz,
    deleted_by  varchar(100),
    CONSTRAINT pk_paginas_informativas PRIMARY KEY (id),
    CONSTRAINT fk_paginas_informativas_grupo
        FOREIGN KEY (grupo_id) REFERENCES ecommerce.paginas_informativas_grupos(id),
    CONSTRAINT ck_paginas_informativas_clave  CHECK (clave ~ '^[a-z0-9_-]+$'),
    CONSTRAINT ck_paginas_informativas_titulo CHECK (length(btrim(titulo)) >= 2),
    -- Una página fija no va en carpeta: la tienda la busca por su ruta
    CONSTRAINT ck_paginas_informativas_fija   CHECK (NOT fija OR grupo_id IS NULL)
);

CREATE SEQUENCE IF NOT EXISTS ecommerce.paginas_informativas_id_seq
    OWNED BY ecommerce.paginas_informativas.id;
ALTER TABLE ecommerce.paginas_informativas
    ALTER COLUMN id SET DEFAULT nextval('ecommerce.paginas_informativas_id_seq');

-- La clave es única aunque la página esté en la papelera: restaurarla no puede
-- chocar con una nueva que se llame igual.
CREATE UNIQUE INDEX IF NOT EXISTS uq_paginas_informativas_clave
    ON ecommerce.paginas_informativas (clave);
CREATE UNIQUE INDEX IF NOT EXISTS uq_paginas_informativas_grupos_nombre
    ON ecommerce.paginas_informativas_grupos (ecommerce.fn_normalizar_nombre(nombre))
    WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_paginas_informativas_grupo
    ON ecommerce.paginas_informativas (grupo_id);
CREATE INDEX IF NOT EXISTS ix_paginas_informativas_deleted_at
    ON ecommerce.paginas_informativas (deleted_at) WHERE deleted_at IS NOT NULL;
CREATE INDEX IF NOT EXISTS ix_paginas_informativas_grupos_deleted_at
    ON ecommerce.paginas_informativas_grupos (deleted_at) WHERE deleted_at IS NOT NULL;

COMMENT ON TABLE ecommerce.paginas_informativas IS
    'Páginas de sólo texto de la tienda (términos, políticas, garantías). La tienda las pide por «clave».';
COMMENT ON COLUMN ecommerce.paginas_informativas.contenido IS
    'jsonb {texto, imagen, imagen_alt, pdf, desplegables[]}. imagen y pdf son SÓLO EL NOMBRE del fichero; la URL la arma el controlador.';

-- Los tres disparadores de la casa
DO $disparadores$
DECLARE
    t text;
BEGIN
    FOREACH t IN ARRAY ARRAY['paginas_informativas', 'paginas_informativas_grupos'] LOOP
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
-- 2. EL DATO QUE YA ESTÁ
-- ----------------------------------------------------------------------------
-- Se conservan los ids: la tienda no los usa (pide por clave), pero así las
-- páginas siguen apuntando a su carpeta sin tener que traducir nada.
--
-- Del PDF y de la imagen se guarda sólo el nombre del fichero: de
-- «http://host/api/public/pagina-web/documentos/5IMB….pdf» queda «5IMB….pdf».
DO $copiar$
DECLARE
    v_grupos  integer := 0;
    v_paginas integer := 0;
BEGIN
    IF to_regclass('ecommerce.pagina_informativa_grupo') IS NULL THEN
        RAISE NOTICE 'Las tablas viejas ya no están: el dato ya se copió.';
        RETURN;
    END IF;

    INSERT INTO ecommerce.paginas_informativas_grupos (id, nombre, orden, created_at, updated_at, deleted_at)
    SELECT g.pig_id, g.pig_nombre, g.pig_orden,
           g.pig_fecha_creacion, COALESCE(g.pig_fecha_modificacion, g.pig_fecha_creacion),
           g.pig_eliminado_en
      FROM ecommerce.pagina_informativa_grupo g
     ON CONFLICT (id) DO NOTHING;
    GET DIAGNOSTICS v_grupos = ROW_COUNT;

    INSERT INTO ecommerce.paginas_informativas
           (id, clave, titulo, grupo_id, contenido, fija, orden, activo, created_at, updated_at, deleted_at)
    SELECT p.pin_id, p.pin_clave, p.pin_titulo, p.pig_id,
           -- El nombre del fichero, sin el servidor delante; los desplegables
           -- llevan su propio pdf y hay que recorrerlos uno a uno.
           jsonb_build_object(
               -- Dentro del HTML hay <img> y enlaces a nuestros ficheros con
               -- el servidor delante. Se les quita el principio y queda
               -- «imagenes/x.png» o «documentos/y.pdf»: ahí SÍ hace falta la
               -- carpeta, porque un mismo texto puede llevar de las dos. Los
               -- enlaces a sitios de fuera (almacenesespana.ec) no se tocan.
               'texto',      regexp_replace(p.pin_contenido ->> 'texto',
                                 'https?://[^"'' <>]*?/api/public/pagina-web/', '', 'g'),
               -- En los campos propios basta el nombre: el controlador ya sabe
               -- que uno es imagen y el otro documento.
               'imagen',     regexp_replace(p.pin_contenido ->> 'imagen', '^.*/', ''),
               'imagen_alt', p.pin_contenido ->> 'imagen_alt',
               'pdf',        regexp_replace(p.pin_contenido ->> 'pdf', '^.*/', ''),
               'desplegables', COALESCE((
                   SELECT jsonb_agg(jsonb_build_object(
                              'titulo', d ->> 'titulo',
                              'texto',  regexp_replace(d ->> 'texto',
                                            'https?://[^"'' <>]*?/api/public/pagina-web/', '', 'g'),
                              'pdf',    regexp_replace(d ->> 'pdf', '^.*/', ''),
                              'boton',  d ->> 'boton') ORDER BY i)
                     FROM jsonb_array_elements(COALESCE(p.pin_contenido -> 'desplegables', '[]'::jsonb))
                          WITH ORDINALITY AS t(d, i)
               ), '[]'::jsonb)
           ),
           p.pin_fija, p.pin_orden, p.pin_activo,
           p.pin_fecha_creacion, COALESCE(p.pin_fecha_modificacion, p.pin_fecha_creacion),
           p.pin_eliminado_en
      FROM ecommerce.pagina_informativa p
     ON CONFLICT (id) DO NOTHING;
    GET DIAGNOSTICS v_paginas = ROW_COUNT;

    PERFORM setval('ecommerce.paginas_informativas_grupos_id_seq',
                   GREATEST((SELECT COALESCE(max(id), 0) FROM ecommerce.paginas_informativas_grupos), 1));
    PERFORM setval('ecommerce.paginas_informativas_id_seq',
                   GREATEST((SELECT COALESCE(max(id), 0) FROM ecommerce.paginas_informativas), 1));

    RAISE NOTICE 'Copiadas % carpetas y % páginas.', v_grupos, v_paginas;
END
$copiar$;

-- ----------------------------------------------------------------------------
-- 3. LAS CARPETAS
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ecommerce.fn_paginas_informativas_grupos_json(p_id bigint)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
AS $function$
    SELECT jsonb_build_object(
        'id',          g.id,
        'nombre',      g.nombre,
        'orden',       g.orden,
        -- Cuántas páginas vivas cuelgan de ella: la pantalla lo enseña al lado
        -- del nombre y hace falta para no borrar una carpeta con contenido.
        'paginas',     (SELECT count(*) FROM ecommerce.paginas_informativas p
                         WHERE p.grupo_id = g.id AND p.deleted_at IS NULL),
        'deleted_at',  to_char(g.deleted_at, 'YYYY-MM-DD HH24:MI:SS'),
        'deleted_by',  g.deleted_by,
        'created_by',  g.created_by,
        'updated_by',  g.updated_by,
        'created_at',  to_char(g.created_at, 'YYYY-MM-DD HH24:MI:SS'),
        'updated_at',  to_char(g.updated_at, 'YYYY-MM-DD HH24:MI:SS')
    )
      FROM ecommerce.paginas_informativas_grupos g
     WHERE g.id = p_id;
$function$;

CREATE OR REPLACE FUNCTION ecommerce.fn_paginas_informativas_grupos_listar()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
AS $function$
    SELECT jsonb_build_object('success', true, 'message', 'Carpetas',
        'data', COALESCE((
            SELECT jsonb_agg(ecommerce.fn_paginas_informativas_grupos_json(g.id) ORDER BY g.orden, g.id)
              FROM ecommerce.paginas_informativas_grupos g
             WHERE g.deleted_at IS NULL), '[]'::jsonb));
$function$;

CREATE OR REPLACE FUNCTION ecommerce.fn_paginas_informativas_grupos_validar(
    p_id bigint, p_nombre character varying)
 RETURNS void
 LANGUAGE plpgsql
 STABLE
AS $function$
BEGIN
    IF p_nombre IS NULL OR length(btrim(p_nombre)) < 2 THEN
        RAISE EXCEPTION 'El nombre de la carpeta es obligatorio (mínimo 2 caracteres)' USING ERRCODE = 'P0001';
    END IF;
    IF length(btrim(p_nombre)) > 60 THEN
        RAISE EXCEPTION 'El nombre de la carpeta no puede pasar de 60 caracteres' USING ERRCODE = 'P0015';
    END IF;
    IF EXISTS (SELECT 1 FROM ecommerce.paginas_informativas_grupos
                WHERE ecommerce.fn_normalizar_nombre(nombre) = ecommerce.fn_normalizar_nombre(p_nombre)
                  AND deleted_at IS NULL
                  AND (p_id IS NULL OR id <> p_id)) THEN
        RAISE EXCEPTION 'Ya existe una carpeta llamada «%»', btrim(p_nombre) USING ERRCODE = 'P0006';
    END IF;
END;
$function$;

CREATE OR REPLACE FUNCTION ecommerce.fn_paginas_informativas_grupos_crear(
    p_nombre character varying,
    p_usuario_id bigint DEFAULT NULL, p_usuario_login character varying DEFAULT NULL,
    p_usuario_nombre character varying DEFAULT NULL, p_ip_address inet DEFAULT NULL,
    p_user_agent text DEFAULT NULL, p_request_id uuid DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'ecommerce', 'auditoria'
AS $function$
DECLARE
    v_id bigint;
BEGIN
    PERFORM ecommerce.fn_contexto_auditoria('ecommerce.paginas_informativas_grupos',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    PERFORM ecommerce.fn_paginas_informativas_grupos_validar(NULL, p_nombre);

    INSERT INTO ecommerce.paginas_informativas_grupos (nombre, orden)
    VALUES (btrim(p_nombre),
            -- Al final de la lista
            (SELECT COALESCE(max(orden), 0) + 1 FROM ecommerce.paginas_informativas_grupos WHERE deleted_at IS NULL))
    RETURNING id INTO v_id;

    RETURN jsonb_build_object('success', true, 'message', 'Carpeta creada',
                              'data', ecommerce.fn_paginas_informativas_grupos_json(v_id));
END;
$function$;

CREATE OR REPLACE FUNCTION ecommerce.fn_paginas_informativas_grupos_modificar(
    p_id bigint, p_nombre character varying,
    p_usuario_id bigint DEFAULT NULL, p_usuario_login character varying DEFAULT NULL,
    p_usuario_nombre character varying DEFAULT NULL, p_ip_address inet DEFAULT NULL,
    p_user_agent text DEFAULT NULL, p_request_id uuid DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'ecommerce', 'auditoria'
AS $function$
DECLARE
    v_antes jsonb;
BEGIN
    PERFORM ecommerce.fn_contexto_auditoria('ecommerce.paginas_informativas_grupos',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    v_antes := ecommerce.fn_paginas_informativas_grupos_json(p_id);
    IF v_antes IS NULL OR v_antes -> 'deleted_at' <> 'null'::jsonb THEN
        RAISE EXCEPTION 'La carpeta no existe' USING ERRCODE = 'P0013';
    END IF;

    PERFORM ecommerce.fn_paginas_informativas_grupos_validar(p_id, p_nombre);

    UPDATE ecommerce.paginas_informativas_grupos SET nombre = btrim(p_nombre) WHERE id = p_id;

    RETURN jsonb_build_object('success', true, 'message', 'Carpeta actualizada',
                              'data', ecommerce.fn_paginas_informativas_grupos_json(p_id));
END;
$function$;

CREATE OR REPLACE FUNCTION ecommerce.fn_paginas_informativas_grupos_ordenar(
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
    v_cuantas integer;
BEGIN
    PERFORM ecommerce.fn_contexto_auditoria('ecommerce.paginas_informativas_grupos',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    IF jsonb_typeof(p_ids) <> 'array' THEN
        RAISE EXCEPTION 'Se esperaba la lista de carpetas en el orden nuevo' USING ERRCODE = 'P0015';
    END IF;

    -- El orden es la POSICIÓN en la lista que llega, no un número que mande el
    -- cliente: así no hay huecos ni empates aunque se arrastre varias veces.
    UPDATE ecommerce.paginas_informativas_grupos g
       SET orden = t.posicion
      FROM (SELECT valor::bigint AS id, ordinalidad::integer AS posicion
              FROM jsonb_array_elements_text(p_ids) WITH ORDINALITY AS x(valor, ordinalidad)) t
     WHERE g.id = t.id AND g.deleted_at IS NULL;
    GET DIAGNOSTICS v_cuantas = ROW_COUNT;

    RETURN jsonb_build_object('success', true,
        'message', CASE v_cuantas WHEN 1 THEN 'Carpeta movida' ELSE format('%s carpetas reordenadas', v_cuantas) END,
        'data', (ecommerce.fn_paginas_informativas_grupos_listar() -> 'data'));
END;
$function$;

CREATE OR REPLACE FUNCTION ecommerce.fn_paginas_informativas_grupos_eliminar(
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
    v_nombre text;
    v_fecha  timestamptz := CURRENT_TIMESTAMP;
    v_hijas  integer;
BEGIN
    PERFORM ecommerce.fn_contexto_auditoria('ecommerce.paginas_informativas_grupos',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    SELECT nombre INTO v_nombre FROM ecommerce.paginas_informativas_grupos
     WHERE id = p_id AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'La carpeta no existe' USING ERRCODE = 'P0013';
    END IF;

    -- Las páginas se van CON la carpeta, no se quedan sueltas: una página sin
    -- carpeta no sale en ninguna lista y se perdería de vista. Restaurar la
    -- carpeta las devuelve a las dos.
    UPDATE ecommerce.paginas_informativas
       SET deleted_at = v_fecha, deleted_by = p_usuario_login
     WHERE grupo_id = p_id AND deleted_at IS NULL AND NOT fija;
    GET DIAGNOSTICS v_hijas = ROW_COUNT;

    UPDATE ecommerce.paginas_informativas_grupos
       SET deleted_at = v_fecha, deleted_by = p_usuario_login
     WHERE id = p_id;

    RETURN jsonb_build_object('success', true,
        'message', CASE v_hijas
                        WHEN 0 THEN format('Carpeta «%s» enviada a la papelera', v_nombre)
                        WHEN 1 THEN format('Carpeta «%s» enviada a la papelera con su página', v_nombre)
                        ELSE format('Carpeta «%s» enviada a la papelera con sus %s páginas', v_nombre, v_hijas) END,
        'data', ecommerce.fn_paginas_informativas_grupos_json(p_id));
END;
$function$;

CREATE OR REPLACE FUNCTION ecommerce.fn_paginas_informativas_grupos_restaurar(
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
    v_fecha  timestamptz;
    v_nombre text;
BEGIN
    PERFORM ecommerce.fn_contexto_auditoria('ecommerce.paginas_informativas_grupos',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    SELECT deleted_at, nombre INTO v_fecha, v_nombre
      FROM ecommerce.paginas_informativas_grupos WHERE id = p_id;
    IF NOT FOUND OR v_fecha IS NULL THEN
        RAISE EXCEPTION 'Esa carpeta no está en la papelera' USING ERRCODE = 'P0019';
    END IF;

    PERFORM ecommerce.fn_paginas_informativas_grupos_validar(p_id, v_nombre);

    -- Sólo vuelven las páginas que se fueron CON ella (misma marca de tiempo);
    -- las que ya estaban en la papelera antes se quedan donde están.
    UPDATE ecommerce.paginas_informativas
       SET deleted_at = NULL, deleted_by = NULL
     WHERE grupo_id = p_id AND deleted_at = v_fecha;

    UPDATE ecommerce.paginas_informativas_grupos
       SET deleted_at = NULL, deleted_by = NULL WHERE id = p_id;

    RETURN jsonb_build_object('success', true,
        'message', format('Carpeta «%s» restaurada', v_nombre),
        'data', ecommerce.fn_paginas_informativas_grupos_json(p_id));
END;
$function$;

-- ----------------------------------------------------------------------------
-- 4. LAS PÁGINAS
-- ----------------------------------------------------------------------------
-- El contenido, revisado y dejado en sus cinco campos. Lo que llegue de más se
-- descarta: es lo que acaba guardado tal cual.
--
-- La segunda barrera contra HTML peligroso se mantiene aunque el servidor ya
-- limpie: el que escribe la página es de la casa, pero una plantilla pegada de
-- internet trae de todo.
CREATE OR REPLACE FUNCTION ecommerce.fn_paginas_informativas_contenido_validar(p_contenido jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 IMMUTABLE
AS $function$
DECLARE
    v_texto        text;
    v_imagen       text;
    v_alt          text;
    v_pdf          text;
    v_d            jsonb;
    v_titulo_d     text;
    v_texto_d      text;
    v_pdf_d        text;
    v_boton_d      text;
    v_desplegables jsonb := '[]'::jsonb;
    -- Sólo el NOMBRE del fichero: la dirección la arma el controlador
    c_imagen constant text := '^[A-Za-z0-9._-]+\.(jpg|jpeg|png|webp)$';
    c_pdf    constant text := '^[A-Za-z0-9._-]+\.pdf$';
    c_malo   constant text := '<\s*/?\s*(script|iframe|object|embed|style|link|meta|form|input|button)\M';
BEGIN
    IF p_contenido IS NULL OR jsonb_typeof(p_contenido) <> 'object' THEN
        RAISE EXCEPTION 'El contenido de la página no tiene la forma esperada' USING ERRCODE = 'P0015';
    END IF;

    IF COALESCE(jsonb_typeof(p_contenido -> 'texto'), 'null')        NOT IN ('string', 'null')
       OR COALESCE(jsonb_typeof(p_contenido -> 'imagen'), 'null')     NOT IN ('string', 'null')
       OR COALESCE(jsonb_typeof(p_contenido -> 'imagen_alt'), 'null') NOT IN ('string', 'null')
       OR COALESCE(jsonb_typeof(p_contenido -> 'pdf'), 'null')        NOT IN ('string', 'null')
       OR COALESCE(jsonb_typeof(p_contenido -> 'desplegables'), 'null') NOT IN ('array', 'null') THEN
        RAISE EXCEPTION 'El contenido de la página no tiene la forma esperada' USING ERRCODE = 'P0015';
    END IF;

    v_texto := btrim(COALESCE(p_contenido ->> 'texto', ''));

    -- Vacío es no tener LETRAS: un <p>&nbsp;</p> del editor no es contenido
    IF btrim(replace(regexp_replace(v_texto, '<[^>]*>', '', 'g'), '&nbsp;', ' ')) = '' THEN
        RAISE EXCEPTION 'La página necesita texto' USING ERRCODE = 'P0001';
    END IF;
    IF length(v_texto) > 100000 THEN
        RAISE EXCEPTION 'El texto de la página es demasiado largo (el formato también ocupa)' USING ERRCODE = 'P0015';
    END IF;
    IF v_texto ~* c_malo OR v_texto ~* '<[^>]*\son[a-z]+\s*=' OR v_texto ~* '<[^>]*javascript\s*:' THEN
        RAISE EXCEPTION 'El texto trae etiquetas o atributos que no se permiten' USING ERRCODE = 'P0015';
    END IF;

    v_imagen := nullif(btrim(COALESCE(p_contenido ->> 'imagen', '')), '');
    IF v_imagen IS NOT NULL AND v_imagen !~ c_imagen THEN
        RAISE EXCEPTION 'La imagen debe ser un fichero subido (jpg, png o webp)' USING ERRCODE = 'P0015';
    END IF;

    -- El texto alternativo sólo tiene sentido con imagen
    v_alt := CASE WHEN v_imagen IS NULL THEN NULL
                  ELSE nullif(btrim(COALESCE(p_contenido ->> 'imagen_alt', '')), '') END;
    IF length(v_alt) > 150 THEN
        RAISE EXCEPTION 'El texto alternativo de la imagen no puede pasar de 150 caracteres' USING ERRCODE = 'P0015';
    END IF;

    v_pdf := nullif(btrim(COALESCE(p_contenido ->> 'pdf', '')), '');
    IF v_pdf IS NOT NULL AND v_pdf !~ c_pdf THEN
        RAISE EXCEPTION 'El documento debe ser un PDF subido' USING ERRCODE = 'P0015';
    END IF;

    IF jsonb_array_length(COALESCE(p_contenido -> 'desplegables', '[]'::jsonb)) > 6 THEN
        RAISE EXCEPTION 'No caben más de 6 desplegables en una página' USING ERRCODE = 'P0015';
    END IF;

    FOR v_d IN SELECT * FROM jsonb_array_elements(COALESCE(p_contenido -> 'desplegables', '[]'::jsonb)) LOOP
        IF jsonb_typeof(v_d) <> 'object' THEN
            RAISE EXCEPTION 'El contenido de la página no tiene la forma esperada' USING ERRCODE = 'P0015';
        END IF;

        v_titulo_d := btrim(COALESCE(v_d ->> 'titulo', ''));
        v_texto_d  := btrim(COALESCE(v_d ->> 'texto', ''));

        IF v_titulo_d = '' THEN
            RAISE EXCEPTION 'Cada desplegable necesita un título' USING ERRCODE = 'P0001';
        END IF;
        IF length(v_titulo_d) > 100 THEN
            RAISE EXCEPTION 'El título del desplegable no puede pasar de 100 caracteres' USING ERRCODE = 'P0015';
        END IF;
        IF btrim(replace(regexp_replace(v_texto_d, '<[^>]*>', '', 'g'), '&nbsp;', ' ')) = '' THEN
            RAISE EXCEPTION 'El desplegable «%» está sin texto', v_titulo_d USING ERRCODE = 'P0001';
        END IF;
        IF length(v_texto_d) > 20000 THEN
            RAISE EXCEPTION 'El texto del desplegable «%» es demasiado largo', v_titulo_d USING ERRCODE = 'P0015';
        END IF;
        IF v_texto_d ~* c_malo OR v_texto_d ~* '<[^>]*\son[a-z]+\s*=' OR v_texto_d ~* '<[^>]*javascript\s*:' THEN
            RAISE EXCEPTION 'El desplegable «%» trae etiquetas que no se permiten', v_titulo_d USING ERRCODE = 'P0015';
        END IF;

        v_pdf_d := nullif(btrim(COALESCE(v_d ->> 'pdf', '')), '');
        IF v_pdf_d IS NOT NULL AND v_pdf_d !~ c_pdf THEN
            RAISE EXCEPTION 'El documento del desplegable «%» debe ser un PDF subido', v_titulo_d USING ERRCODE = 'P0015';
        END IF;

        -- El texto del botón sólo tiene sentido con PDF; sin PDF se descarta
        v_boton_d := CASE WHEN v_pdf_d IS NULL THEN NULL
                          ELSE nullif(btrim(COALESCE(v_d ->> 'boton', '')), '') END;
        IF length(v_boton_d) > 40 THEN
            RAISE EXCEPTION 'El texto del botón no puede pasar de 40 caracteres' USING ERRCODE = 'P0015';
        END IF;
        IF v_boton_d ~ '[<>]' THEN
            RAISE EXCEPTION 'El texto del botón no admite etiquetas' USING ERRCODE = 'P0015';
        END IF;

        v_desplegables := v_desplegables || jsonb_build_array(jsonb_build_object(
            'titulo', v_titulo_d, 'texto', v_texto_d, 'pdf', v_pdf_d, 'boton', v_boton_d));
    END LOOP;

    RETURN jsonb_build_object('texto', v_texto, 'imagen', v_imagen,
                              'imagen_alt', v_alt, 'pdf', v_pdf, 'desplegables', v_desplegables);
END;
$function$;

CREATE OR REPLACE FUNCTION ecommerce.fn_paginas_informativas_json(p_id bigint)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
AS $function$
    SELECT jsonb_build_object(
        'id',           p.id,
        'clave',        p.clave,
        'titulo',       p.titulo,
        'grupo_id',     p.grupo_id,
        'grupo_nombre', (SELECT g.nombre FROM ecommerce.paginas_informativas_grupos g WHERE g.id = p.grupo_id),
        'contenido',    p.contenido,
        'fija',         p.fija,
        'orden',        p.orden,
        'activo',       p.activo,
        'deleted_at',   to_char(p.deleted_at, 'YYYY-MM-DD HH24:MI:SS'),
        'deleted_by',   p.deleted_by,
        'created_by',   p.created_by,
        'updated_by',   p.updated_by,
        'created_at',   to_char(p.created_at, 'YYYY-MM-DD HH24:MI:SS'),
        'updated_at',   to_char(p.updated_at, 'YYYY-MM-DD HH24:MI:SS')
    )
      FROM ecommerce.paginas_informativas p
     WHERE p.id = p_id;
$function$;

CREATE OR REPLACE FUNCTION ecommerce.fn_paginas_informativas_listar()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
AS $function$
    -- Sin el contenido: la lista enseña título, carpeta y estado, y el texto
    -- de diez páginas con su HTML son cientos de kilobytes para nada.
    SELECT jsonb_build_object('success', true, 'message', 'Páginas informativas',
        'data', COALESCE((
            SELECT jsonb_agg(
                     (ecommerce.fn_paginas_informativas_json(p.id) - 'contenido')
                     ORDER BY p.fija DESC, p.grupo_id NULLS FIRST, p.orden, p.id)
              FROM ecommerce.paginas_informativas p
             WHERE p.deleted_at IS NULL), '[]'::jsonb));
$function$;

CREATE OR REPLACE FUNCTION ecommerce.fn_paginas_informativas_obtener(p_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
AS $function$
DECLARE
    v_data jsonb;
BEGIN
    v_data := ecommerce.fn_paginas_informativas_json(p_id);
    IF v_data IS NULL THEN
        RAISE EXCEPTION 'La página no existe' USING ERRCODE = 'P0013';
    END IF;
    RETURN jsonb_build_object('success', true, 'message', 'Página encontrada', 'data', v_data);
END;
$function$;

-- Por CLAVE, que es como la pide la pantalla de edición y la tienda
CREATE OR REPLACE FUNCTION ecommerce.fn_paginas_informativas_buscar(p_clave text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
AS $function$
DECLARE
    v_id bigint;
BEGIN
    SELECT id INTO v_id FROM ecommerce.paginas_informativas
     WHERE clave = p_clave AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'La página «%» no existe', p_clave USING ERRCODE = 'P0013';
    END IF;
    RETURN ecommerce.fn_paginas_informativas_obtener(v_id);
END;
$function$;

-- Lo que ve la tienda: una página activa, con lo justo
CREATE OR REPLACE FUNCTION ecommerce.fn_paginas_informativas_publica(p_clave text)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
AS $function$
    SELECT jsonb_build_object('clave', p.clave, 'titulo', p.titulo, 'contenido', p.contenido)
      FROM ecommerce.paginas_informativas p
     WHERE p.clave = p_clave AND p.activo AND p.deleted_at IS NULL;
$function$;

-- El índice de /documentos: las de carpeta, agrupadas y en orden. Las fijas no
-- salen aquí: la tienda les tiene su propia ruta en el menú.
CREATE OR REPLACE FUNCTION ecommerce.fn_paginas_informativas_listar_publicas()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
AS $function$
    SELECT COALESCE(jsonb_agg(x ORDER BY (x ->> 'orden')::int, x ->> 'grupo'), '[]'::jsonb) FROM (
        SELECT jsonb_build_object(
                   'grupo_id', g.id,
                   'grupo',    g.nombre,
                   'orden',    g.orden,
                   'paginas',  COALESCE((
                       SELECT jsonb_agg(jsonb_build_object('clave', p.clave, 'titulo', p.titulo)
                                        ORDER BY p.orden, p.id)
                         FROM ecommerce.paginas_informativas p
                        WHERE p.grupo_id = g.id AND p.activo AND p.deleted_at IS NULL), '[]'::jsonb)
               ) AS x
          FROM ecommerce.paginas_informativas_grupos g
         WHERE g.deleted_at IS NULL
    ) t
    WHERE x -> 'paginas' <> '[]'::jsonb;
$function$;

CREATE OR REPLACE FUNCTION ecommerce.fn_paginas_informativas_validar(
    p_id bigint, p_clave text, p_titulo character varying, p_grupo_id bigint)
 RETURNS void
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
    v_fija boolean := false;
BEGIN
    IF p_titulo IS NULL OR length(btrim(p_titulo)) < 2 THEN
        RAISE EXCEPTION 'El título de la página es obligatorio (mínimo 2 caracteres)' USING ERRCODE = 'P0001';
    END IF;
    IF length(btrim(p_titulo)) > 120 THEN
        RAISE EXCEPTION 'El título no puede pasar de 120 caracteres' USING ERRCODE = 'P0015';
    END IF;

    IF p_clave IS NULL OR p_clave !~ '^[a-z0-9_-]+$' THEN
        RAISE EXCEPTION 'La dirección de la página sólo admite letras sin tilde, números, guiones y guiones bajos' USING ERRCODE = 'P0015';
    END IF;

    -- La clave choca aunque la otra esté en la papelera: restaurarla no puede
    -- dejar dos páginas respondiendo a la misma dirección.
    IF EXISTS (SELECT 1 FROM ecommerce.paginas_informativas
                WHERE clave = p_clave AND (p_id IS NULL OR id <> p_id)) THEN
        RAISE EXCEPTION 'Ya hay una página en la dirección «%»', p_clave USING ERRCODE = 'P0006';
    END IF;

    IF p_id IS NOT NULL THEN
        SELECT fija INTO v_fija FROM ecommerce.paginas_informativas WHERE id = p_id;
    END IF;

    IF p_grupo_id IS NOT NULL THEN
        IF v_fija THEN
            RAISE EXCEPTION 'Esta página tiene su propia dirección en la tienda: no va en una carpeta' USING ERRCODE = 'P0015';
        END IF;
        IF NOT EXISTS (SELECT 1 FROM ecommerce.paginas_informativas_grupos
                        WHERE id = p_grupo_id AND deleted_at IS NULL) THEN
            RAISE EXCEPTION 'La carpeta indicada no existe' USING ERRCODE = 'P0016';
        END IF;
    END IF;
END;
$function$;

CREATE OR REPLACE FUNCTION ecommerce.fn_paginas_informativas_crear(
    p_clave text, p_titulo character varying, p_contenido jsonb,
    p_grupo_id bigint DEFAULT NULL, p_activo boolean DEFAULT true,
    p_usuario_id bigint DEFAULT NULL, p_usuario_login character varying DEFAULT NULL,
    p_usuario_nombre character varying DEFAULT NULL, p_ip_address inet DEFAULT NULL,
    p_user_agent text DEFAULT NULL, p_request_id uuid DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'ecommerce', 'auditoria'
AS $function$
DECLARE
    v_id    bigint;
    v_clave text;
BEGIN
    PERFORM ecommerce.fn_contexto_auditoria('ecommerce.paginas_informativas',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    -- Sin clave, se saca del título: «Política de datos» -> «politica-de-datos»
    v_clave := COALESCE(nullif(btrim(COALESCE(p_clave, '')), ''),
                        ecommerce.fn_paginas_informativas_slug(p_titulo));

    PERFORM ecommerce.fn_paginas_informativas_validar(NULL, v_clave, p_titulo, p_grupo_id);

    INSERT INTO ecommerce.paginas_informativas (clave, titulo, grupo_id, contenido, fija, orden, activo)
    VALUES (v_clave, btrim(p_titulo), p_grupo_id,
            ecommerce.fn_paginas_informativas_contenido_validar(p_contenido),
            false,   -- fija se decide en la base, no desde la pantalla
            (SELECT COALESCE(max(orden), 0) + 1 FROM ecommerce.paginas_informativas
              WHERE grupo_id IS NOT DISTINCT FROM p_grupo_id AND deleted_at IS NULL),
            COALESCE(p_activo, true))
    RETURNING id INTO v_id;

    RETURN jsonb_build_object('success', true, 'message', 'Página creada',
                              'data', ecommerce.fn_paginas_informativas_json(v_id));
END;
$function$;

CREATE OR REPLACE FUNCTION ecommerce.fn_paginas_informativas_modificar(
    p_id bigint, p_titulo character varying, p_contenido jsonb,
    p_grupo_id bigint DEFAULT NULL, p_activo boolean DEFAULT true,
    p_usuario_id bigint DEFAULT NULL, p_usuario_login character varying DEFAULT NULL,
    p_usuario_nombre character varying DEFAULT NULL, p_ip_address inet DEFAULT NULL,
    p_user_agent text DEFAULT NULL, p_request_id uuid DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'ecommerce', 'auditoria'
AS $function$
DECLARE
    v_actual record;
    v_antes  jsonb;
BEGIN
    PERFORM ecommerce.fn_contexto_auditoria('ecommerce.paginas_informativas',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    SELECT clave, grupo_id, fija INTO v_actual
      FROM ecommerce.paginas_informativas WHERE id = p_id AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'La página no existe' USING ERRCODE = 'P0013';
    END IF;

    -- LA CLAVE NO SE CAMBIA: es la dirección por la que la tienda la pide y
    -- por la que la enlaza el menú. Cambiarla rompería los enlaces de fuera.
    PERFORM ecommerce.fn_paginas_informativas_validar(p_id, v_actual.clave, p_titulo, p_grupo_id);

    v_antes := ecommerce.fn_paginas_informativas_json(p_id);
    PERFORM set_config('app.datos_anteriores', v_antes::text, true);

    UPDATE ecommerce.paginas_informativas
       SET titulo    = btrim(p_titulo),
           grupo_id  = p_grupo_id,
           contenido = ecommerce.fn_paginas_informativas_contenido_validar(p_contenido),
           activo    = COALESCE(p_activo, true),
           -- Si cambia de carpeta va al final de la nueva; si no, se queda
           orden     = CASE WHEN p_grupo_id IS NOT DISTINCT FROM v_actual.grupo_id THEN orden
                            ELSE (SELECT COALESCE(max(o.orden), 0) + 1 FROM ecommerce.paginas_informativas o
                                   WHERE o.grupo_id IS NOT DISTINCT FROM p_grupo_id AND o.deleted_at IS NULL) END
     WHERE id = p_id;

    PERFORM set_config('app.datos_anteriores', '', true);

    RETURN jsonb_build_object('success', true, 'message', 'Página actualizada',
                              'data', ecommerce.fn_paginas_informativas_json(p_id));
END;
$function$;

CREATE OR REPLACE FUNCTION ecommerce.fn_paginas_informativas_activar(
    p_id bigint, p_activo boolean DEFAULT NULL,
    p_usuario_id bigint DEFAULT NULL, p_usuario_login character varying DEFAULT NULL,
    p_usuario_nombre character varying DEFAULT NULL, p_ip_address inet DEFAULT NULL,
    p_user_agent text DEFAULT NULL, p_request_id uuid DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'ecommerce', 'auditoria'
AS $function$
DECLARE
    v_actual boolean;
    v_nuevo  boolean;
    v_titulo text;
BEGIN
    PERFORM ecommerce.fn_contexto_auditoria('ecommerce.paginas_informativas',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    SELECT activo, titulo INTO v_actual, v_titulo
      FROM ecommerce.paginas_informativas WHERE id = p_id AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'La página no existe' USING ERRCODE = 'P0013';
    END IF;

    -- Sin valor, alterna: es lo que hace la palanca de la rejilla
    v_nuevo := COALESCE(p_activo, NOT v_actual);
    UPDATE ecommerce.paginas_informativas SET activo = v_nuevo WHERE id = p_id;

    RETURN jsonb_build_object('success', true,
        'message', format('Página «%s» %s', v_titulo, CASE WHEN v_nuevo THEN 'publicada' ELSE 'oculta en la tienda' END),
        'data', ecommerce.fn_paginas_informativas_json(p_id));
END;
$function$;

CREATE OR REPLACE FUNCTION ecommerce.fn_paginas_informativas_ordenar(
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
    v_cuantas integer;
BEGIN
    PERFORM ecommerce.fn_contexto_auditoria('ecommerce.paginas_informativas',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    IF jsonb_typeof(p_ids) <> 'array' THEN
        RAISE EXCEPTION 'Se esperaba la lista de páginas en el orden nuevo' USING ERRCODE = 'P0015';
    END IF;

    UPDATE ecommerce.paginas_informativas p
       SET orden = t.posicion
      FROM (SELECT valor::bigint AS id, ordinalidad::integer AS posicion
              FROM jsonb_array_elements_text(p_ids) WITH ORDINALITY AS x(valor, ordinalidad)) t
     WHERE p.id = t.id AND p.deleted_at IS NULL;
    GET DIAGNOSTICS v_cuantas = ROW_COUNT;

    RETURN jsonb_build_object('success', true,
        'message', CASE v_cuantas WHEN 1 THEN 'Página movida' ELSE format('%s páginas reordenadas', v_cuantas) END,
        'data', (ecommerce.fn_paginas_informativas_listar() -> 'data'));
END;
$function$;

CREATE OR REPLACE FUNCTION ecommerce.fn_paginas_informativas_eliminar(
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
    v_actual record;
BEGIN
    PERFORM ecommerce.fn_contexto_auditoria('ecommerce.paginas_informativas',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    SELECT titulo, fija, deleted_at INTO v_actual
      FROM ecommerce.paginas_informativas WHERE id = p_id;
    IF NOT FOUND OR v_actual.deleted_at IS NOT NULL THEN
        RAISE EXCEPTION 'La página no existe' USING ERRCODE = 'P0013';
    END IF;

    -- La tienda tiene una ruta fija apuntándole: borrarla deja esa ruta en un
    -- error que nadie entendería desde el CRM. Se oculta, no se borra.
    IF v_actual.fija THEN
        RAISE EXCEPTION 'La tienda tiene una dirección propia para «%»: se puede ocultar, no borrar', v_actual.titulo
              USING ERRCODE = 'P0021';
    END IF;

    UPDATE ecommerce.paginas_informativas
       SET deleted_at = CURRENT_TIMESTAMP, deleted_by = p_usuario_login WHERE id = p_id;

    RETURN jsonb_build_object('success', true,
        'message', format('Página «%s» enviada a la papelera', v_actual.titulo),
        'data', ecommerce.fn_paginas_informativas_json(p_id));
END;
$function$;

CREATE OR REPLACE FUNCTION ecommerce.fn_paginas_informativas_restaurar(
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
    v_cuantas integer;
BEGIN
    PERFORM ecommerce.fn_contexto_auditoria('ecommerce.paginas_informativas',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    IF jsonb_typeof(p_ids) <> 'array' OR jsonb_array_length(p_ids) = 0 THEN
        RAISE EXCEPTION 'No se indicó qué restaurar' USING ERRCODE = 'P0015';
    END IF;

    -- Una página cuya carpeta sigue en la papelera vuelve SIN carpeta: si no,
    -- se restauraría a un sitio que no se ve y parecería que no pasó nada.
    UPDATE ecommerce.paginas_informativas p
       SET deleted_at = NULL, deleted_by = NULL,
           grupo_id = CASE WHEN EXISTS (SELECT 1 FROM ecommerce.paginas_informativas_grupos g
                                         WHERE g.id = p.grupo_id AND g.deleted_at IS NULL)
                           THEN p.grupo_id END
     WHERE p.deleted_at IS NOT NULL
       AND p.id IN (SELECT valor::bigint FROM jsonb_array_elements_text(p_ids) AS x(valor));
    GET DIAGNOSTICS v_cuantas = ROW_COUNT;

    IF v_cuantas = 0 THEN
        RAISE EXCEPTION 'Ninguna de esas páginas está en la papelera' USING ERRCODE = 'P0019';
    END IF;

    RETURN jsonb_build_object('success', true,
        'message', CASE v_cuantas WHEN 1 THEN 'Página restaurada' ELSE format('%s páginas restauradas', v_cuantas) END, 'data', NULL);
END;
$function$;

CREATE OR REPLACE FUNCTION ecommerce.fn_paginas_informativas_papelera_listar()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
AS $function$
    -- Carpetas y páginas en un solo cesto, que es como se ve en la pantalla:
    -- la carpeta arriba y debajo las páginas que se fueron con ella.
    SELECT jsonb_build_object('success', true, 'message', 'Papelera de páginas informativas',
        'data', COALESCE((
            SELECT jsonb_agg(x ORDER BY x ->> 'deleted_at' DESC, x ->> 'texto')
              FROM (
                SELECT jsonb_build_object(
                           'tipo', 'carpeta', 'id', g.id, 'texto', g.nombre, 'detalle', NULL,
                           'deleted_at', to_char(g.deleted_at, 'YYYY-MM-DD HH24:MI:SS'),
                           'deleted_by', g.deleted_by) AS x
                  FROM ecommerce.paginas_informativas_grupos g WHERE g.deleted_at IS NOT NULL
                UNION ALL
                SELECT jsonb_build_object(
                           'tipo', 'pagina', 'id', p.id, 'texto', p.titulo, 'detalle', p.clave,
                           'grupo_id', p.grupo_id,
                           'deleted_at', to_char(p.deleted_at, 'YYYY-MM-DD HH24:MI:SS'),
                           'deleted_by', p.deleted_by)
                  FROM ecommerce.paginas_informativas p WHERE p.deleted_at IS NOT NULL
              ) t), '[]'::jsonb));
$function$;

CREATE OR REPLACE FUNCTION ecommerce.fn_paginas_informativas_papelera_vaciar(
    p_usuario_id bigint DEFAULT NULL, p_usuario_login character varying DEFAULT NULL,
    p_usuario_nombre character varying DEFAULT NULL, p_ip_address inet DEFAULT NULL,
    p_user_agent text DEFAULT NULL, p_request_id uuid DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'ecommerce', 'auditoria'
AS $function$
DECLARE
    v_paginas  integer;
    v_carpetas integer;
    v_ficheros jsonb;
BEGIN
    PERFORM ecommerce.fn_contexto_auditoria('ecommerce.paginas_informativas',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    -- Los ficheros de lo que se va: el controlador los borra del disco. Van en
    -- la respuesta y no se borran aquí porque la base no toca el disco, y si
    -- la transacción se deshace los ficheros ya no estarían.
    SELECT COALESCE(jsonb_agg(f), '[]'::jsonb) INTO v_ficheros FROM (
        SELECT p.contenido ->> 'imagen' AS f FROM ecommerce.paginas_informativas p
         WHERE p.deleted_at IS NOT NULL AND p.contenido ->> 'imagen' IS NOT NULL
        UNION ALL
        SELECT p.contenido ->> 'pdf' FROM ecommerce.paginas_informativas p
         WHERE p.deleted_at IS NOT NULL AND p.contenido ->> 'pdf' IS NOT NULL
        UNION ALL
        SELECT d ->> 'pdf' FROM ecommerce.paginas_informativas p,
               jsonb_array_elements(COALESCE(p.contenido -> 'desplegables', '[]'::jsonb)) d
         WHERE p.deleted_at IS NOT NULL AND d ->> 'pdf' IS NOT NULL
    ) t;

    DELETE FROM ecommerce.paginas_informativas WHERE deleted_at IS NOT NULL;
    GET DIAGNOSTICS v_paginas = ROW_COUNT;

    DELETE FROM ecommerce.paginas_informativas_grupos WHERE deleted_at IS NOT NULL;
    GET DIAGNOSTICS v_carpetas = ROW_COUNT;

    RETURN jsonb_build_object('success', true,
        'message', format('Papelera vaciada: %s y %s',
                   CASE v_paginas WHEN 1 THEN '1 página' ELSE v_paginas || ' páginas' END,
                   CASE v_carpetas WHEN 1 THEN '1 carpeta' ELSE v_carpetas || ' carpetas' END),
        'data', jsonb_build_object('paginas', v_paginas, 'carpetas', v_carpetas, 'ficheros', v_ficheros));
END;
$function$;

-- ----------------------------------------------------------------------------
-- 5. QUE DE VERDAD ESTÉ TODO
-- ----------------------------------------------------------------------------
DO $comprobar$
DECLARE
    v_viejas_p  integer := 0;
    v_viejas_g  integer := 0;
    v_nuevas_p  integer;
    v_nuevas_g  integer;
    v_con_host  integer;
    v_publica   jsonb;
BEGIN
    -- FUERA del IF a propósito: si se contaran sólo cuando las tablas viejas
    -- existen, en la segunda pasada quedarían en NULL y las comparaciones de
    -- abajo darían NULL —que no es TRUE—, así que la comprobación pasaría sin
    -- comprobar nada. Ya me pasó una vez.
    SELECT count(*) INTO v_nuevas_p FROM ecommerce.paginas_informativas;
    SELECT count(*) INTO v_nuevas_g FROM ecommerce.paginas_informativas_grupos;

    IF v_nuevas_p IS NULL OR v_nuevas_g IS NULL OR v_nuevas_p = 0 THEN
        RAISE EXCEPTION 'Las tablas nuevas están vacías o no se pudieron leer';
    END IF;

    IF to_regclass('ecommerce.pagina_informativa') IS NOT NULL THEN
        SELECT count(*) INTO v_viejas_p FROM ecommerce.pagina_informativa;
        SELECT count(*) INTO v_viejas_g FROM ecommerce.pagina_informativa_grupo;

        IF v_nuevas_p <> v_viejas_p OR v_nuevas_g <> v_viejas_g THEN
            RAISE EXCEPTION 'Falta dato: viejas %/% páginas/carpetas, nuevas %/%',
                  v_viejas_p, v_viejas_g, v_nuevas_p, v_nuevas_g;
        END IF;
    END IF;

    -- Ya no puede quedar NINGUNA dirección a un fichero nuestro con el
    -- servidor delante. Los enlaces a sitios de fuera sí se quedan: son parte
    -- del texto y no apuntan a nada que nosotros sirvamos.
    SELECT count(*) INTO v_con_host FROM ecommerce.paginas_informativas
     WHERE contenido::text ~ 'api/public/pagina-web';
    IF v_con_host > 0 THEN
        RAISE EXCEPTION 'Quedan % páginas con una dirección a un fichero nuestro con el servidor delante', v_con_host;
    END IF;

    -- Y en los campos propios, sólo el nombre: ni carpeta ni servidor
    SELECT count(*) INTO v_con_host FROM ecommerce.paginas_informativas
     WHERE contenido ->> 'imagen' LIKE '%/%' OR contenido ->> 'pdf' LIKE '%/%';
    IF v_con_host > 0 THEN
        RAISE EXCEPTION 'Quedan % páginas cuyo campo imagen o pdf lleva ruta', v_con_host;
    END IF;

    -- La que la tienda pide por su ruta propia
    v_publica := ecommerce.fn_paginas_informativas_publica('garantia');
    IF v_publica IS NULL OR v_publica ->> 'titulo' IS NULL THEN
        RAISE EXCEPTION 'La página pública «garantia» no responde';
    END IF;

    -- Y el índice de /documentos trae carpetas con páginas dentro
    IF jsonb_array_length(ecommerce.fn_paginas_informativas_listar_publicas()) = 0 THEN
        RAISE EXCEPTION 'El índice público de documentos salió vacío';
    END IF;

    IF jsonb_array_length(ecommerce.fn_paginas_informativas_listar() -> 'data') <> v_nuevas_p THEN
        RAISE EXCEPTION 'El listado no devuelve todas las páginas';
    END IF;

    RAISE NOTICE 'Comprobado: % páginas y % carpetas, sin direcciones absolutas, y lo público responde.',
          v_nuevas_p, v_nuevas_g;
END
$comprobar$;

-- ----------------------------------------------------------------------------
-- 6. FUERA LO VIEJO
-- ----------------------------------------------------------------------------
-- Sólo se llega aquí si la comprobación de arriba pasó. Las 24 funciones y las
-- dos tablas con prefijos se van: dejarlas al lado de las nuevas, con nombres
-- casi iguales (`pagina_informativa` / `paginas_informativas`), es pedir que
-- alguien toque la que no es.
DO $limpiar$
DECLARE
    r record;
BEGIN
    FOR r IN SELECT p.oid::regprocedure::text AS firma
               FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
              WHERE n.nspname = 'ecommerce' AND p.prokind = 'f'
                AND p.proname LIKE 'fn\_pagina\_informativa\_%' LOOP
        EXECUTE 'DROP FUNCTION IF EXISTS ' || r.firma;
    END LOOP;

    DROP TABLE IF EXISTS ecommerce.pagina_informativa;
    DROP TABLE IF EXISTS ecommerce.pagina_informativa_grupo;
    RAISE NOTICE 'Borradas las tablas y funciones viejas de páginas informativas.';
END
$limpiar$;

COMMIT;
