-- ============================================================
-- RESPALDO DE ESPAÑA MOTOS — 07/11/2026 22:04
-- ============================================================
-- Se sacó justo antes de borrarlo (migración del 08/11/2026).
-- Para devolverlo: este fichero entero, en orden. Hace falta que el
-- esquema ecommerce y las tablas a las que apunta (galerias, marcas)
-- sigan existiendo.

-- ---------- Las secuencias ----------
CREATE SEQUENCE IF NOT EXISTS ecommerce.espana_motos_marcas_id_seq;
CREATE SEQUENCE IF NOT EXISTS ecommerce.espana_motos_pestanas_id_seq;

-- ---------- Las tablas ----------
CREATE TABLE IF NOT EXISTS ecommerce.espana_motos (
    id bigint NOT NULL DEFAULT 1,
    publicada boolean NOT NULL DEFAULT false,
    banner_visible boolean NOT NULL DEFAULT true,
    galeria_banner_id bigint,
    fondo_visible boolean NOT NULL DEFAULT false,
    fondo_imagen character varying(200),
    fondo_titulo character varying(60),
    fondo_subtitulo character varying(120),
    tarjetas_visible boolean NOT NULL DEFAULT false,
    galeria_tarjetas_id bigint,
    marcas_visible boolean NOT NULL DEFAULT true,
    created_at timestamp with time zone NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp with time zone NOT NULL DEFAULT CURRENT_TIMESTAMP,
    created_by character varying(100),
    updated_by character varying(100)
);
CREATE TABLE IF NOT EXISTS ecommerce.espana_motos_marcas (
    id bigint NOT NULL DEFAULT nextval('ecommerce.espana_motos_marcas_id_seq'::regclass),
    marca_id bigint NOT NULL,
    orden integer NOT NULL DEFAULT 0,
    activo boolean NOT NULL DEFAULT true,
    created_at timestamp with time zone NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp with time zone NOT NULL DEFAULT CURRENT_TIMESTAMP,
    created_by character varying(100),
    updated_by character varying(100),
    deleted_at timestamp with time zone,
    deleted_by character varying(100)
);
CREATE TABLE IF NOT EXISTS ecommerce.espana_motos_pestanas (
    id bigint NOT NULL DEFAULT nextval('ecommerce.espana_motos_pestanas_id_seq'::regclass),
    nombre character varying(30) NOT NULL,
    categorias bigint[] NOT NULL DEFAULT '{}'::bigint[],
    orden integer NOT NULL DEFAULT 0,
    activo boolean NOT NULL DEFAULT true,
    created_at timestamp with time zone NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp with time zone NOT NULL DEFAULT CURRENT_TIMESTAMP,
    created_by character varying(100),
    updated_by character varying(100),
    deleted_at timestamp with time zone,
    deleted_by character varying(100)
);

-- ---------- Las claves ----------
ALTER TABLE ecommerce.espana_motos ADD CONSTRAINT ck_espana_motos_fila_unica CHECK ((id = 1));
ALTER TABLE ecommerce.espana_motos ADD CONSTRAINT espana_motos_banner_visible_not_null NOT NULL banner_visible;
ALTER TABLE ecommerce.espana_motos ADD CONSTRAINT espana_motos_created_at_not_null NOT NULL created_at;
ALTER TABLE ecommerce.espana_motos ADD CONSTRAINT espana_motos_fondo_visible_not_null NOT NULL fondo_visible;
ALTER TABLE ecommerce.espana_motos ADD CONSTRAINT espana_motos_id_not_null NOT NULL id;
ALTER TABLE ecommerce.espana_motos ADD CONSTRAINT espana_motos_marcas_visible_not_null NOT NULL marcas_visible;
ALTER TABLE ecommerce.espana_motos ADD CONSTRAINT espana_motos_publicada_not_null NOT NULL publicada;
ALTER TABLE ecommerce.espana_motos ADD CONSTRAINT espana_motos_tarjetas_visible_not_null NOT NULL tarjetas_visible;
ALTER TABLE ecommerce.espana_motos ADD CONSTRAINT espana_motos_updated_at_not_null NOT NULL updated_at;
ALTER TABLE ecommerce.espana_motos ADD CONSTRAINT fk_espana_motos_galeria_banner FOREIGN KEY (galeria_banner_id) REFERENCES ecommerce.galerias(id);
ALTER TABLE ecommerce.espana_motos ADD CONSTRAINT fk_espana_motos_galeria_tarjetas FOREIGN KEY (galeria_tarjetas_id) REFERENCES ecommerce.galerias(id);
ALTER TABLE ecommerce.espana_motos ADD CONSTRAINT pk_espana_motos PRIMARY KEY (id);
ALTER TABLE ecommerce.espana_motos_marcas ADD CONSTRAINT espana_motos_marcas_activo_not_null NOT NULL activo;
ALTER TABLE ecommerce.espana_motos_marcas ADD CONSTRAINT espana_motos_marcas_created_at_not_null NOT NULL created_at;
ALTER TABLE ecommerce.espana_motos_marcas ADD CONSTRAINT espana_motos_marcas_id_not_null NOT NULL id;
ALTER TABLE ecommerce.espana_motos_marcas ADD CONSTRAINT espana_motos_marcas_marca_id_not_null NOT NULL marca_id;
ALTER TABLE ecommerce.espana_motos_marcas ADD CONSTRAINT espana_motos_marcas_orden_not_null NOT NULL orden;
ALTER TABLE ecommerce.espana_motos_marcas ADD CONSTRAINT espana_motos_marcas_updated_at_not_null NOT NULL updated_at;
ALTER TABLE ecommerce.espana_motos_marcas ADD CONSTRAINT fk_espana_motos_marcas_marca FOREIGN KEY (marca_id) REFERENCES inventarios.marcas(id);
ALTER TABLE ecommerce.espana_motos_marcas ADD CONSTRAINT pk_espana_motos_marcas PRIMARY KEY (id);
ALTER TABLE ecommerce.espana_motos_pestanas ADD CONSTRAINT ck_espana_motos_pestanas_categorias CHECK ((cardinality(categorias) > 0));
ALTER TABLE ecommerce.espana_motos_pestanas ADD CONSTRAINT ck_espana_motos_pestanas_nombre CHECK ((length(btrim((nombre)::text)) >= 1));
ALTER TABLE ecommerce.espana_motos_pestanas ADD CONSTRAINT espana_motos_pestanas_activo_not_null NOT NULL activo;
ALTER TABLE ecommerce.espana_motos_pestanas ADD CONSTRAINT espana_motos_pestanas_categorias_not_null NOT NULL categorias;
ALTER TABLE ecommerce.espana_motos_pestanas ADD CONSTRAINT espana_motos_pestanas_created_at_not_null NOT NULL created_at;
ALTER TABLE ecommerce.espana_motos_pestanas ADD CONSTRAINT espana_motos_pestanas_id_not_null NOT NULL id;
ALTER TABLE ecommerce.espana_motos_pestanas ADD CONSTRAINT espana_motos_pestanas_nombre_not_null NOT NULL nombre;
ALTER TABLE ecommerce.espana_motos_pestanas ADD CONSTRAINT espana_motos_pestanas_orden_not_null NOT NULL orden;
ALTER TABLE ecommerce.espana_motos_pestanas ADD CONSTRAINT espana_motos_pestanas_updated_at_not_null NOT NULL updated_at;
ALTER TABLE ecommerce.espana_motos_pestanas ADD CONSTRAINT pk_espana_motos_pestanas PRIMARY KEY (id);

-- ---------- Lo que tenían dentro ----------
INSERT INTO ecommerce.espana_motos (id, publicada, banner_visible, galeria_banner_id, fondo_visible, fondo_imagen, fondo_titulo, fondo_subtitulo, tarjetas_visible, galeria_tarjetas_id, marcas_visible, created_at, updated_at, created_by, updated_by) VALUES (1, true, true, 26, true, 'zisym1gF87d9GyHNl51BRO3HDSElT38aIOTzyyQ1.png', 'MOVILIDAD TOTAL', 'Motos de combustión y eléctricas, con crédito directo', true, 27, true, '2026-11-01 08:25:03.796739-05', '2026-11-01 10:17:44.912222-05', 'postgres', 'LAGILA');

-- Las secuencias, donde se quedaron
SELECT setval('ecommerce.espana_motos_marcas_id_seq', 3);
SELECT setval('ecommerce.espana_motos_pestanas_id_seq', 5);

-- ---------- Las dos galerías suyas, y sus imágenes ----------
-- Los FICHEROS de las imágenes no se borran, sólo estas filas: si se
-- devuelven, las fotos siguen donde estaban.
INSERT INTO ecommerce.galerias (id, clave, nombre, descripcion, tipo, mostrar, maximo, created_at, updated_at, created_by, updated_by) VALUES (26, 'espana_motos_banner', 'Banner de España Motos', 'España Motos: banner de arriba.', 'banner', NULL, 10, '2026-10-31 23:46:46.552073-05', '2026-10-31 23:46:46.552073-05', 'postgres', 'postgres');
INSERT INTO ecommerce.galerias (id, clave, nombre, descripcion, tipo, mostrar, maximo, created_at, updated_at, created_by, updated_by) VALUES (27, 'espana_motos_tarjetas', 'Tarjetas de España Motos', 'España Motos: tarjetas del final (cascos…).', 'tarjetas', NULL, 4, '2026-10-31 23:46:46.552073-05', '2026-10-31 23:46:46.552073-05', 'postgres', 'postgres');
INSERT INTO ecommerce.galerias_imagenes (id, galeria_id, imagen, imagen_movil, nombre, enlace, nueva_pestana, mostrar_en, desde, hasta, titulo, subtitulo, color, boton, orden, activo, created_at, updated_at, created_by, updated_by, deleted_at, deleted_by) VALUES (43, 26, 'lihPqmZK3wHrduPhAqxNQfEfW7HSEb4ocOQtHnez.webp', NULL, 'espanamotos-banners-scaled', NULL, false, 'todos', NULL, NULL, NULL, NULL, NULL, NULL, 1, true, '2026-10-23 09:37:37.641553-05', '2026-10-23 09:37:37.641553-05', 'postgres', 'postgres', NULL, NULL);
INSERT INTO ecommerce.galerias_imagenes (id, galeria_id, imagen, imagen_movil, nombre, enlace, nueva_pestana, mostrar_en, desde, hasta, titulo, subtitulo, color, boton, orden, activo, created_at, updated_at, created_by, updated_by, deleted_at, deleted_by) VALUES (44, 27, 'dX1db1S4Zn3QmPvRWZhip1HcTAhUcGX6lXiqD1Uw.webp', NULL, 'Moto', NULL, false, 'todos', NULL, NULL, 'Moto', NULL, 'rojo', 'Ver más', 1, true, '2026-10-23 09:50:58.020295-05', '2026-10-23 09:50:58.020295-05', 'postgres', 'postgres', NULL, NULL);
INSERT INTO ecommerce.galerias_imagenes (id, galeria_id, imagen, imagen_movil, nombre, enlace, nueva_pestana, mostrar_en, desde, hasta, titulo, subtitulo, color, boton, orden, activo, created_at, updated_at, created_by, updated_by, deleted_at, deleted_by) VALUES (49, 26, 'svfhZqO3B8aWqp8lNYeFY8GlKifuXxOTzyDtZIR7.webp', NULL, 'Españaflix Motos', NULL, false, 'todos', NULL, NULL, NULL, NULL, NULL, NULL, 2, true, '2026-11-01 10:03:30.009571-05', '2026-11-01 10:03:30.009571-05', 'LAGILA', 'LAGILA', NULL, NULL);

-- ---------- Las funciones ----------
CREATE OR REPLACE FUNCTION ecommerce.fn_espana_motos_marcas_guardar(p_marca_id bigint, p_activo boolean, p_usuario_id bigint DEFAULT NULL::bigint, p_usuario_login character varying DEFAULT NULL::character varying, p_usuario_nombre character varying DEFAULT NULL::character varying, p_ip_address inet DEFAULT NULL::inet, p_user_agent text DEFAULT NULL::text, p_request_id uuid DEFAULT NULL::uuid)
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
$function$
;
CREATE OR REPLACE FUNCTION ecommerce.fn_espana_motos_modificar(p_datos jsonb, p_usuario_id bigint DEFAULT NULL::bigint, p_usuario_login character varying DEFAULT NULL::character varying, p_usuario_nombre character varying DEFAULT NULL::character varying, p_ip_address inet DEFAULT NULL::inet, p_user_agent text DEFAULT NULL::text, p_request_id uuid DEFAULT NULL::uuid)
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
$function$
;
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

            -- Las pestañas, con la RUTA de cada categoría al lado: sin eso la
            -- pantalla enseñaría «416, 420» y nadie sabría qué son, y con el
            -- nombre suelto no se distinguen dos «Refrigeración» de ramas
            -- distintas.
            'pestanas', COALESCE((
                SELECT jsonb_agg(jsonb_build_object(
                           'id', p.id, 'nombre', p.nombre, 'orden', p.orden, 'activo', p.activo,
                           'categorias', p.categorias,
                           'categorias_nombres', COALESCE((
                               SELECT jsonb_agg(jsonb_build_object(
                                          'id', c.id,
                                          'nombre', inventarios.fn_categoria_ruta(c.id))
                                      ORDER BY inventarios.fn_categoria_ruta(c.id))
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
$function$
;
CREATE OR REPLACE FUNCTION ecommerce.fn_espana_motos_ordenar(p_que text, p_ids jsonb, p_usuario_id bigint DEFAULT NULL::bigint, p_usuario_login character varying DEFAULT NULL::character varying, p_usuario_nombre character varying DEFAULT NULL::character varying, p_ip_address inet DEFAULT NULL::inet, p_user_agent text DEFAULT NULL::text, p_request_id uuid DEFAULT NULL::uuid)
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
$function$
;
CREATE OR REPLACE FUNCTION ecommerce.fn_espana_motos_pestanas_guardar(p_id bigint, p_nombre character varying, p_categorias jsonb, p_activo boolean, p_usuario_id bigint DEFAULT NULL::bigint, p_usuario_login character varying DEFAULT NULL::character varying, p_usuario_nombre character varying DEFAULT NULL::character varying, p_ip_address inet DEFAULT NULL::inet, p_user_agent text DEFAULT NULL::text, p_request_id uuid DEFAULT NULL::uuid)
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
$function$
;
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
$function$
;
CREATE OR REPLACE FUNCTION ecommerce.fn_espana_motos_quitar(p_que text, p_id bigint, p_usuario_id bigint DEFAULT NULL::bigint, p_usuario_login character varying DEFAULT NULL::character varying, p_usuario_nombre character varying DEFAULT NULL::character varying, p_ip_address inet DEFAULT NULL::inet, p_user_agent text DEFAULT NULL::text, p_request_id uuid DEFAULT NULL::uuid)
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
$function$
;
