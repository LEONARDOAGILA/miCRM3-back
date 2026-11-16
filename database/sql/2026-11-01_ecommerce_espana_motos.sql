-- ============================================================================
-- ECOMMERCE · ESPAÑA MOTOS
-- ============================================================================
-- Fecha: 2026-11-01
--
-- Un micro-sitio dentro de la tienda: su propia portada (/espana-motos) y su
-- propio catálogo (/espana-motos/catalogo), que es la misma pantalla de /shop
-- pero limitada a unas categorías concretas.
--
-- Tiene cuatro piezas que se encienden por separado:
--
--   · el BANNER de arriba, que sale de una galería;
--   · el FONDO, una imagen a pantalla ancha con su título y su subtítulo;
--   · las TARJETAS, otra galería;
--   · y las MARCAS, los logos de las que se venden ahí.
--
-- Más las PESTAÑAS del catálogo: cada una agrupa unas categorías («A gasolina»,
-- «Eléctricas») y es lo que decide qué productos salen.
--
-- NO SE TRAE NINGÚN DATO DEL CRM VIEJO, a propósito. Allí las pestañas y las
-- marcas guardaban ids del ERP anterior (marcas 337, 264, 380…; categorías
-- 416, 420) y NINGUNO existe en este catálogo, que tiene 14 marcas con ids
-- 13-26 y 33 categorías con ids 26-74. Copiarlos dejaría filas apuntando a
-- nada: o las rechaza la clave ajena, o —peor— se guardan y la pantalla
-- enseña huecos que nadie sabe de dónde salen. Las tablas nacen vacías y se
-- configuran contra el catálogo de verdad.
--
-- LAS CATEGORÍAS DE UNA PESTAÑA SE GUARDAN COMO ARRAY y no en una tabla
-- aparte: son dos o tres por pestaña, siempre se leen juntas y nunca se
-- consultan al revés («en qué pestañas está esta categoría»). Una tabla de
-- cruce aquí sería una unión más en cada lectura para no ganar nada.
--
-- Idempotente.
-- ============================================================================
\set ON_ERROR_STOP on

BEGIN;

-- ----------------------------------------------------------------------------
-- 1. FUERA LO VIEJO
-- ----------------------------------------------------------------------------
-- Es referencia, no datos a conservar: sus filas apuntan a otro catálogo.
DO $limpiar$
DECLARE
    r record;
BEGIN
    FOR r IN SELECT p.oid::regprocedure::text AS firma
               FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
              WHERE n.nspname = 'ecommerce' AND p.prokind = 'f'
                AND p.proname LIKE 'fn\_espana\_motos\_%' LOOP
        EXECUTE 'DROP FUNCTION IF EXISTS ' || r.firma;
    END LOOP;

    DROP TABLE IF EXISTS ecommerce.espana_motos_marca;
    DROP TABLE IF EXISTS ecommerce.espana_motos_pestana;
    -- Ojo: esta es la vieja, con emo_id. La nueva se llama igual y se crea
    -- justo debajo, así que hay que borrarla primero.
    IF EXISTS (SELECT 1 FROM information_schema.columns
                WHERE table_schema = 'ecommerce' AND table_name = 'espana_motos'
                  AND column_name = 'emo_id') THEN
        DROP TABLE ecommerce.espana_motos;
        RAISE NOTICE 'Borradas las tablas viejas de España Motos.';
    END IF;
END
$limpiar$;

-- ----------------------------------------------------------------------------
-- 2. LAS TABLAS
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS ecommerce.espana_motos (
    id                  bigint       NOT NULL DEFAULT 1,
    -- Apagada, la tienda devuelve 404 en /espana-motos: sirve para prepararla
    -- entera antes de enseñarla.
    publicada           boolean      NOT NULL DEFAULT false,

    banner_visible      boolean      NOT NULL DEFAULT true,
    galeria_banner_id   bigint,

    fondo_visible       boolean      NOT NULL DEFAULT true,
    -- SÓLO EL NOMBRE del fichero; la dirección la arma el controlador
    fondo_imagen        varchar(200),
    fondo_titulo        varchar(60),
    fondo_subtitulo     varchar(120),

    tarjetas_visible    boolean      NOT NULL DEFAULT false,
    galeria_tarjetas_id bigint,

    marcas_visible      boolean      NOT NULL DEFAULT true,

    created_at          timestamptz  NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at          timestamptz  NOT NULL DEFAULT CURRENT_TIMESTAMP,
    created_by          varchar(100),
    updated_by          varchar(100),
    CONSTRAINT pk_espana_motos PRIMARY KEY (id),
    CONSTRAINT ck_espana_motos_fila_unica CHECK (id = 1),
    CONSTRAINT fk_espana_motos_galeria_banner
        FOREIGN KEY (galeria_banner_id) REFERENCES ecommerce.galerias(id),
    CONSTRAINT fk_espana_motos_galeria_tarjetas
        FOREIGN KEY (galeria_tarjetas_id) REFERENCES ecommerce.galerias(id)
);

CREATE TABLE IF NOT EXISTS ecommerce.espana_motos_pestanas (
    id          bigint       NOT NULL,
    nombre      varchar(30)  NOT NULL,
    -- Las categorías del catálogo que agrupa. Array y no tabla de cruce: ver
    -- la cabecera.
    categorias  bigint[]     NOT NULL DEFAULT '{}',
    orden       integer      NOT NULL DEFAULT 0,
    activo      boolean      NOT NULL DEFAULT true,
    created_at  timestamptz  NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at  timestamptz  NOT NULL DEFAULT CURRENT_TIMESTAMP,
    created_by  varchar(100),
    updated_by  varchar(100),
    deleted_at  timestamptz,
    deleted_by  varchar(100),
    CONSTRAINT pk_espana_motos_pestanas PRIMARY KEY (id),
    CONSTRAINT ck_espana_motos_pestanas_nombre CHECK (length(btrim(nombre)) >= 1),
    -- Una pestaña sin categorías no enseña nada: es un botón que no hace nada
    CONSTRAINT ck_espana_motos_pestanas_categorias CHECK (cardinality(categorias) > 0)
);

CREATE SEQUENCE IF NOT EXISTS ecommerce.espana_motos_pestanas_id_seq
    OWNED BY ecommerce.espana_motos_pestanas.id;
ALTER TABLE ecommerce.espana_motos_pestanas
    ALTER COLUMN id SET DEFAULT nextval('ecommerce.espana_motos_pestanas_id_seq');

CREATE TABLE IF NOT EXISTS ecommerce.espana_motos_marcas (
    id          bigint       NOT NULL,
    -- CONTRA EL CATÁLOGO DE VERDAD: si la marca se borra, esto lo impide, que
    -- es justo lo que faltaba antes.
    marca_id    bigint       NOT NULL,
    orden       integer      NOT NULL DEFAULT 0,
    activo      boolean      NOT NULL DEFAULT true,
    created_at  timestamptz  NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at  timestamptz  NOT NULL DEFAULT CURRENT_TIMESTAMP,
    created_by  varchar(100),
    updated_by  varchar(100),
    deleted_at  timestamptz,
    deleted_by  varchar(100),
    CONSTRAINT pk_espana_motos_marcas PRIMARY KEY (id),
    CONSTRAINT fk_espana_motos_marcas_marca
        FOREIGN KEY (marca_id) REFERENCES inventarios.marcas(id)
);

CREATE SEQUENCE IF NOT EXISTS ecommerce.espana_motos_marcas_id_seq
    OWNED BY ecommerce.espana_motos_marcas.id;
ALTER TABLE ecommerce.espana_motos_marcas
    ALTER COLUMN id SET DEFAULT nextval('ecommerce.espana_motos_marcas_id_seq');

-- La misma marca dos veces sería el mismo logo repetido
CREATE UNIQUE INDEX IF NOT EXISTS uq_espana_motos_marcas
    ON ecommerce.espana_motos_marcas (marca_id) WHERE deleted_at IS NULL;

CREATE INDEX IF NOT EXISTS ix_espana_motos_pestanas_deleted_at
    ON ecommerce.espana_motos_pestanas (deleted_at) WHERE deleted_at IS NOT NULL;
CREATE INDEX IF NOT EXISTS ix_espana_motos_marcas_deleted_at
    ON ecommerce.espana_motos_marcas (deleted_at) WHERE deleted_at IS NOT NULL;

DO $disparadores$
DECLARE
    t text;
BEGIN
    FOREACH t IN ARRAY ARRAY['espana_motos', 'espana_motos_pestanas', 'espana_motos_marcas'] LOOP
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

-- La fila de configuración, apagada: se enciende cuando esté lista
INSERT INTO ecommerce.espana_motos (id, publicada) VALUES (1, false)
 ON CONFLICT (id) DO NOTHING;

-- Y sus dos galerías, por clave, que ya existen de la tajada de galerías
UPDATE ecommerce.espana_motos
   SET galeria_banner_id   = COALESCE(galeria_banner_id,
                                      (SELECT id FROM ecommerce.galerias WHERE clave = 'espana_motos_banner')),
       galeria_tarjetas_id = COALESCE(galeria_tarjetas_id,
                                      (SELECT id FROM ecommerce.galerias WHERE clave = 'espana_motos_tarjetas'))
 WHERE id = 1;

-- ----------------------------------------------------------------------------
-- 3. LO QUE VE LA PANTALLA
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ecommerce.fn_espana_motos_obtener()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
AS $function$
    SELECT jsonb_build_object('success', true, 'message', 'España Motos',
        'data', jsonb_build_object(
            'publicada',           e.publicada,
            'banner_visible',      e.banner_visible,
            'galeria_banner',      (SELECT clave FROM ecommerce.galerias g WHERE g.id = e.galeria_banner_id),
            'fondo_visible',       e.fondo_visible,
            'fondo_imagen',        e.fondo_imagen,
            'fondo_titulo',        e.fondo_titulo,
            'fondo_subtitulo',     e.fondo_subtitulo,
            'tarjetas_visible',    e.tarjetas_visible,
            'galeria_tarjetas',    (SELECT clave FROM ecommerce.galerias g WHERE g.id = e.galeria_tarjetas_id),
            'marcas_visible',      e.marcas_visible,
            'updated_at',          to_char(e.updated_at, 'YYYY-MM-DD HH24:MI:SS'),
            'updated_by',          e.updated_by,

            -- Las pestañas, con el NOMBRE de cada categoría al lado: sin eso
            -- la pantalla enseñaría «416, 420» y nadie sabría qué son.
            'pestanas', COALESCE((
                SELECT jsonb_agg(jsonb_build_object(
                           'id', p.id, 'nombre', p.nombre, 'orden', p.orden, 'activo', p.activo,
                           'categorias', p.categorias,
                           'categorias_nombres', COALESCE((
                               SELECT jsonb_agg(jsonb_build_object('id', c.id, 'nombre', c.nombre)
                                      ORDER BY c.nombre)
                                 FROM inventarios.categorias c
                                WHERE c.id = ANY(p.categorias) AND c.deleted_at IS NULL), '[]'::jsonb))
                       ORDER BY p.orden, p.id)
                  FROM ecommerce.espana_motos_pestanas p WHERE p.deleted_at IS NULL), '[]'::jsonb),

            'marcas', COALESCE((
                SELECT jsonb_agg(jsonb_build_object(
                           'id', m.id, 'marca_id', m.marca_id, 'orden', m.orden, 'activo', m.activo,
                           'nombre', mk.nombre)
                       ORDER BY m.orden, m.id)
                  FROM ecommerce.espana_motos_marcas m
                  JOIN inventarios.marcas mk ON mk.id = m.marca_id
                 WHERE m.deleted_at IS NULL), '[]'::jsonb)))
      FROM ecommerce.espana_motos e WHERE e.id = 1;
$function$;

-- ----------------------------------------------------------------------------
-- 4. GUARDAR LA CONFIGURACIÓN
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ecommerce.fn_espana_motos_modificar(
    p_datos jsonb,
    p_usuario_id bigint DEFAULT NULL, p_usuario_login character varying DEFAULT NULL,
    p_usuario_nombre character varying DEFAULT NULL, p_ip_address inet DEFAULT NULL,
    p_user_agent text DEFAULT NULL, p_request_id uuid DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'ecommerce', 'auditoria'
AS $function$
DECLARE
    v_publicada boolean := COALESCE((p_datos ->> 'publicada')::boolean, false);
    v_fondo_on  boolean := COALESCE((p_datos ->> 'fondo_visible')::boolean, false);
    v_imagen    text;
BEGIN
    PERFORM ecommerce.fn_contexto_auditoria('ecommerce.espana_motos',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    v_imagen := nullif(btrim(COALESCE(p_datos ->> 'fondo_imagen', '')), '');
    IF v_imagen IS NOT NULL AND v_imagen !~ '^[A-Za-z0-9._-]+\.(jpg|jpeg|png|webp)$' THEN
        RAISE EXCEPTION 'La imagen de fondo debe ser un fichero subido (jpg, png o webp)' USING ERRCODE = 'P0015';
    END IF;

    -- El fondo encendido sin imagen deja una franja en blanco con el título
    -- flotando: o se apaga, o se le pone imagen.
    IF v_fondo_on AND v_imagen IS NULL THEN
        RAISE EXCEPTION 'Para enseñar el fondo hace falta su imagen' USING ERRCODE = 'P0001';
    END IF;

    UPDATE ecommerce.espana_motos
       SET publicada        = v_publicada,
           banner_visible   = COALESCE((p_datos ->> 'banner_visible')::boolean, false),
           fondo_visible    = v_fondo_on,
           fondo_imagen     = v_imagen,
           fondo_titulo     = ecommerce.fn_validar_texto(p_datos ->> 'fondo_titulo', 'El título del fondo', 60),
           fondo_subtitulo  = ecommerce.fn_validar_texto(p_datos ->> 'fondo_subtitulo', 'El subtítulo del fondo', 120),
           tarjetas_visible = COALESCE((p_datos ->> 'tarjetas_visible')::boolean, false),
           marcas_visible   = COALESCE((p_datos ->> 'marcas_visible')::boolean, false)
     WHERE id = 1;

    RETURN jsonb_build_object('success', true,
        'message', CASE WHEN v_publicada THEN 'España Motos guardada y publicada'
                        ELSE 'España Motos guardada (sin publicar)' END,
        'data', (ecommerce.fn_espana_motos_obtener() -> 'data'));
END;
$function$;

-- ----------------------------------------------------------------------------
-- 5. PESTAÑAS Y MARCAS
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ecommerce.fn_espana_motos_pestanas_guardar(
    p_id bigint, p_nombre character varying, p_categorias jsonb, p_activo boolean,
    p_usuario_id bigint DEFAULT NULL, p_usuario_login character varying DEFAULT NULL,
    p_usuario_nombre character varying DEFAULT NULL, p_ip_address inet DEFAULT NULL,
    p_user_agent text DEFAULT NULL, p_request_id uuid DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'ecommerce', 'auditoria'
AS $function$
DECLARE
    v_id     bigint := p_id;
    v_nombre text;
    v_cats   bigint[];
    v_faltan text;
BEGIN
    PERFORM ecommerce.fn_contexto_auditoria('ecommerce.espana_motos_pestanas',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    v_nombre := ecommerce.fn_validar_texto(p_nombre, 'El nombre de la pestaña', 30, true);

    IF jsonb_typeof(p_categorias) <> 'array' THEN
        RAISE EXCEPTION 'Se esperaba la lista de categorías' USING ERRCODE = 'P0015';
    END IF;

    SELECT array_agg(DISTINCT valor::bigint) INTO v_cats
      FROM jsonb_array_elements_text(p_categorias) AS x(valor);

    IF v_cats IS NULL OR cardinality(v_cats) = 0 THEN
        RAISE EXCEPTION 'La pestaña «%» necesita al menos una categoría: si no, es un botón que no enseña nada', v_nombre
              USING ERRCODE = 'P0001';
    END IF;

    -- Que existan de verdad, y decir CUÁLES fallan en vez de un «no válido»
    SELECT string_agg(c::text, ', ') INTO v_faltan
      FROM unnest(v_cats) c
     WHERE NOT EXISTS (SELECT 1 FROM inventarios.categorias k
                        WHERE k.id = c AND k.deleted_at IS NULL);
    IF v_faltan IS NOT NULL THEN
        RAISE EXCEPTION 'Estas categorías no existen: %', v_faltan USING ERRCODE = 'P0016';
    END IF;

    IF p_id IS NULL THEN
        INSERT INTO ecommerce.espana_motos_pestanas (nombre, categorias, activo, orden)
        VALUES (v_nombre, v_cats, COALESCE(p_activo, true),
                (SELECT COALESCE(max(orden), 0) + 1 FROM ecommerce.espana_motos_pestanas WHERE deleted_at IS NULL))
        RETURNING id INTO v_id;
    ELSE
        UPDATE ecommerce.espana_motos_pestanas
           SET nombre = v_nombre, categorias = v_cats, activo = COALESCE(p_activo, true)
         WHERE id = p_id AND deleted_at IS NULL;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'La pestaña no existe' USING ERRCODE = 'P0013';
        END IF;
    END IF;

    RETURN jsonb_build_object('success', true,
        'message', CASE WHEN p_id IS NULL THEN 'Pestaña creada' ELSE 'Pestaña actualizada' END,
        'data', (ecommerce.fn_espana_motos_obtener() -> 'data'));
END;
$function$;

CREATE OR REPLACE FUNCTION ecommerce.fn_espana_motos_marcas_guardar(
    p_marca_id bigint, p_activo boolean,
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
BEGIN
    PERFORM ecommerce.fn_contexto_auditoria('ecommerce.espana_motos_marcas',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    SELECT nombre INTO v_nombre FROM inventarios.marcas
     WHERE id = p_marca_id AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'La marca no existe' USING ERRCODE = 'P0016';
    END IF;

    -- Volver a añadir una que estaba en la papelera la devuelve, en vez de
    -- chocar contra el índice único y decir «ya existe» de algo que no se ve.
    IF EXISTS (SELECT 1 FROM ecommerce.espana_motos_marcas
                WHERE marca_id = p_marca_id AND deleted_at IS NOT NULL) THEN
        UPDATE ecommerce.espana_motos_marcas
           SET deleted_at = NULL, deleted_by = NULL, activo = COALESCE(p_activo, true)
         WHERE marca_id = p_marca_id AND deleted_at IS NOT NULL;
    ELSIF EXISTS (SELECT 1 FROM ecommerce.espana_motos_marcas
                   WHERE marca_id = p_marca_id AND deleted_at IS NULL) THEN
        RAISE EXCEPTION '«%» ya está en España Motos', v_nombre USING ERRCODE = 'P0006';
    ELSE
        INSERT INTO ecommerce.espana_motos_marcas (marca_id, activo, orden)
        VALUES (p_marca_id, COALESCE(p_activo, true),
                (SELECT COALESCE(max(orden), 0) + 1 FROM ecommerce.espana_motos_marcas WHERE deleted_at IS NULL));
    END IF;

    RETURN jsonb_build_object('success', true, 'message', format('«%s» añadida', v_nombre),
                              'data', (ecommerce.fn_espana_motos_obtener() -> 'data'));
END;
$function$;

-- Quitar y ordenar valen para los dos: cambia la tabla, no la idea.
CREATE OR REPLACE FUNCTION ecommerce.fn_espana_motos_quitar(
    p_que text, p_id bigint,
    p_usuario_id bigint DEFAULT NULL, p_usuario_login character varying DEFAULT NULL,
    p_usuario_nombre character varying DEFAULT NULL, p_ip_address inet DEFAULT NULL,
    p_user_agent text DEFAULT NULL, p_request_id uuid DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'ecommerce', 'auditoria'
AS $function$
BEGIN
    IF p_que NOT IN ('pestana', 'marca') THEN
        RAISE EXCEPTION 'Sólo se quitan pestañas o marcas' USING ERRCODE = 'P0015';
    END IF;

    PERFORM ecommerce.fn_contexto_auditoria('ecommerce.espana_motos',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    IF p_que = 'pestana' THEN
        UPDATE ecommerce.espana_motos_pestanas
           SET deleted_at = CURRENT_TIMESTAMP, deleted_by = p_usuario_login
         WHERE id = p_id AND deleted_at IS NULL;
    ELSE
        UPDATE ecommerce.espana_motos_marcas
           SET deleted_at = CURRENT_TIMESTAMP, deleted_by = p_usuario_login
         WHERE id = p_id AND deleted_at IS NULL;
    END IF;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'No existe' USING ERRCODE = 'P0013';
    END IF;

    RETURN jsonb_build_object('success', true, 'message', 'Quitado',
                              'data', (ecommerce.fn_espana_motos_obtener() -> 'data'));
END;
$function$;

CREATE OR REPLACE FUNCTION ecommerce.fn_espana_motos_ordenar(
    p_que text, p_ids jsonb,
    p_usuario_id bigint DEFAULT NULL, p_usuario_login character varying DEFAULT NULL,
    p_usuario_nombre character varying DEFAULT NULL, p_ip_address inet DEFAULT NULL,
    p_user_agent text DEFAULT NULL, p_request_id uuid DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'ecommerce', 'auditoria'
AS $function$
BEGIN
    IF p_que NOT IN ('pestanas', 'marcas') OR jsonb_typeof(p_ids) <> 'array' THEN
        RAISE EXCEPTION 'Se esperaba la lista en el orden nuevo' USING ERRCODE = 'P0015';
    END IF;

    PERFORM ecommerce.fn_contexto_auditoria('ecommerce.espana_motos',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    IF p_que = 'pestanas' THEN
        UPDATE ecommerce.espana_motos_pestanas e SET orden = t.posicion
          FROM (SELECT valor::bigint AS id, ordinalidad::integer AS posicion
                  FROM jsonb_array_elements_text(p_ids) WITH ORDINALITY AS x(valor, ordinalidad)) t
         WHERE e.id = t.id AND e.deleted_at IS NULL;
    ELSE
        UPDATE ecommerce.espana_motos_marcas e SET orden = t.posicion
          FROM (SELECT valor::bigint AS id, ordinalidad::integer AS posicion
                  FROM jsonb_array_elements_text(p_ids) WITH ORDINALITY AS x(valor, ordinalidad)) t
         WHERE e.id = t.id AND e.deleted_at IS NULL;
    END IF;

    RETURN jsonb_build_object('success', true, 'message', 'Orden guardado',
                              'data', (ecommerce.fn_espana_motos_obtener() -> 'data'));
END;
$function$;

-- ----------------------------------------------------------------------------
-- 6. LO QUE LEE LA TIENDA
-- ----------------------------------------------------------------------------
-- NULL si no está publicada: el controlador lo convierte en 404 y la tienda
-- enseña su propio aviso, en vez de una página a medio montar.
CREATE OR REPLACE FUNCTION ecommerce.fn_espana_motos_publica()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
AS $function$
    SELECT CASE WHEN NOT e.publicada THEN NULL ELSE
        jsonb_build_object(
            'banner', CASE WHEN e.banner_visible THEN
                COALESCE((SELECT ecommerce.fn_galerias_publica(g.clave) -> 'imagenes'
                            FROM ecommerce.galerias g WHERE g.id = e.galeria_banner_id), '[]'::jsonb)
                ELSE '[]'::jsonb END,
            'fondo', CASE WHEN e.fondo_visible AND e.fondo_imagen IS NOT NULL THEN
                jsonb_build_object('imagen', e.fondo_imagen,
                                   'titulo', e.fondo_titulo,
                                   'subtitulo', e.fondo_subtitulo) END,
            'tarjetas', CASE WHEN e.tarjetas_visible THEN
                COALESCE((SELECT ecommerce.fn_galerias_publica(g.clave) -> 'imagenes'
                            FROM ecommerce.galerias g WHERE g.id = e.galeria_tarjetas_id), '[]'::jsonb)
                ELSE '[]'::jsonb END,
            'marcas', CASE WHEN e.marcas_visible THEN COALESCE((
                SELECT jsonb_agg(jsonb_build_object('id', mk.id, 'nombre', mk.nombre) ORDER BY m.orden, m.id)
                  FROM ecommerce.espana_motos_marcas m
                  JOIN inventarios.marcas mk ON mk.id = m.marca_id AND mk.deleted_at IS NULL
                 WHERE m.deleted_at IS NULL AND m.activo), '[]'::jsonb)
                ELSE '[]'::jsonb END,
            -- Las pestañas del catálogo: su nombre y qué categorías agrupa
            'pestanas', COALESCE((
                SELECT jsonb_agg(jsonb_build_object('nombre', p.nombre, 'categorias', p.categorias)
                       ORDER BY p.orden, p.id)
                  FROM ecommerce.espana_motos_pestanas p
                 WHERE p.deleted_at IS NULL AND p.activo), '[]'::jsonb))
        END
      FROM ecommerce.espana_motos e WHERE e.id = 1;
$function$;

-- ----------------------------------------------------------------------------
-- 7. COMPROBACIÓN
-- ----------------------------------------------------------------------------
DO $comprobar$
DECLARE
    v       jsonb;
    v_marca bigint;
    v_cat   bigint;
    v_pest  bigint;
BEGIN
    v := ecommerce.fn_espana_motos_obtener() -> 'data';
    IF v IS NULL THEN RAISE EXCEPTION 'No hay fila de configuración'; END IF;
    IF v -> 'pestanas' <> '[]'::jsonb OR v -> 'marcas' <> '[]'::jsonb THEN
        RAISE EXCEPTION 'Las tablas deberían nacer vacías';
    END IF;

    -- Sin publicar, la tienda no la ve
    IF ecommerce.fn_espana_motos_publica() IS NOT NULL THEN
        RAISE EXCEPTION 'Sin publicar no debería devolver nada';
    END IF;

    -- Una pestaña sin categorías no se deja crear
    BEGIN
        PERFORM ecommerce.fn_espana_motos_pestanas_guardar(NULL, 'ZZ vacía', '[]'::jsonb, true);
        RAISE EXCEPTION 'Dejó crear una pestaña sin categorías';
    EXCEPTION WHEN sqlstate 'P0001' THEN NULL;
    END;

    -- Una con una categoría que no existe, tampoco
    BEGIN
        PERFORM ecommerce.fn_espana_motos_pestanas_guardar(NULL, 'ZZ mala', '[999999]'::jsonb, true);
        RAISE EXCEPTION 'Dejó crear una pestaña con una categoría inexistente';
    EXCEPTION WHEN sqlstate 'P0016' THEN NULL;
    END;

    -- Y una buena sí, con el nombre de la categoría al lado
    SELECT id INTO v_cat FROM inventarios.categorias WHERE deleted_at IS NULL AND es_transaccion LIMIT 1;
    v := ecommerce.fn_espana_motos_pestanas_guardar(NULL, 'ZZ prueba',
             jsonb_build_array(v_cat), true) -> 'data';
    IF jsonb_array_length(v -> 'pestanas') <> 1 THEN
        RAISE EXCEPTION 'No se creó la pestaña';
    END IF;
    IF jsonb_array_length(v -> 'pestanas' -> 0 -> 'categorias_nombres') <> 1 THEN
        RAISE EXCEPTION 'La pestaña no trae el nombre de su categoría';
    END IF;
    SELECT (v -> 'pestanas' -> 0 ->> 'id')::bigint INTO v_pest;

    -- Una marca del catálogo
    SELECT id INTO v_marca FROM inventarios.marcas WHERE deleted_at IS NULL LIMIT 1;
    v := ecommerce.fn_espana_motos_marcas_guardar(v_marca, true) -> 'data';
    IF jsonb_array_length(v -> 'marcas') <> 1 THEN
        RAISE EXCEPTION 'No se añadió la marca';
    END IF;

    -- Repetirla avisa
    BEGIN
        PERFORM ecommerce.fn_espana_motos_marcas_guardar(v_marca, true);
        RAISE EXCEPTION 'Dejó añadir la misma marca dos veces';
    EXCEPTION WHEN sqlstate 'P0006' THEN NULL;
    END;

    -- Se limpia lo de la prueba
    PERFORM ecommerce.fn_espana_motos_quitar('pestana', v_pest);
    PERFORM ecommerce.fn_espana_motos_quitar('marca',
        (SELECT id FROM ecommerce.espana_motos_marcas WHERE marca_id = v_marca AND deleted_at IS NULL));
    DELETE FROM ecommerce.espana_motos_pestanas WHERE nombre LIKE 'ZZ %';
    DELETE FROM ecommerce.espana_motos_marcas WHERE marca_id = v_marca;

    RAISE NOTICE 'Comprobado: nace vacía, exige categorías que existan, no repite marcas y sin publicar no sale.';
END
$comprobar$;

COMMIT;
