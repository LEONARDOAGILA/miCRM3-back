-- ============================================================================
-- ECOMMERCE · SECCIONES DE PRODUCTOS
-- ============================================================================
-- Fecha: 2026-11-01
--
-- Una SECCIÓN DE PRODUCTOS es una lista con nombre —«Los más vendidos»,
-- «Ofertas de navidad», «Lo nuevo de Samsung»— y los productos que marketing
-- mete en ella a mano. Nada más: no es una categoría ni una marca.
--
-- Y POR ESO HACE FALTA. La categoría y la marca ya están en el catálogo y las
-- decide quien da de alta el producto; una sección la decide quien vende, y
-- junta cosas que el catálogo no junta: tres televisores de tres marcas y una
-- barra de sonido, porque ése es el escaparate de esta semana.
--
-- SON DOS TABLAS Y UNA ES UN CRUCE:
--
--     producto_secciones        la lista: nombre, orden, si está encendida y
--                               entre qué fechas se ve
--     producto_secciones_items  qué productos tiene y en qué orden
--
-- EL CRUCE NO BORRA NI DUPLICA. Un producto puede estar en varias secciones
-- —un televisor en «Más vendidos» y en «Ofertas»— pero sólo una vez en cada
-- una: eso lo garantiza la clave primaria, así que «agregar» puede llamarse
-- dos veces sin dejar la sección con el producto repetido.
--
-- LO QUE ESTÁ EN LA PAPELERA NO CUENTA. Un producto borrado sigue en el cruce
-- —su fila no se toca— pero no sale en la lista de la sección ni en la
-- cuenta. Si se restaura, vuelve a su sitio con su orden; si se borra de
-- verdad, la clave ajena se lleva su fila del cruce.
--
-- LA SECCIÓN NO SABE PINTARSE. Esto es el dato; que la tienda enseñe estas
-- secciones es otro trabajo, y mientras no esté hecho la pantalla del CRM es
-- lo único que las usa. Se guarda igual: primero hay que poder armarlas.
--
-- Idempotente.
-- ============================================================================
\set ON_ERROR_STOP on

BEGIN;

-- ----------------------------------------------------------------------------
-- 1. LAS TABLAS
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS ecommerce.producto_secciones (
    id          bigint       NOT NULL,
    nombre      varchar(80)  NOT NULL,
    orden       integer      NOT NULL DEFAULT 0,
    activo      boolean      NOT NULL DEFAULT true,
    -- Vigencia: para dejar armada la sección de navidad y que se apague sola
    desde       timestamptz,
    hasta       timestamptz,
    created_at  timestamptz  NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at  timestamptz  NOT NULL DEFAULT CURRENT_TIMESTAMP,
    created_by  varchar(100),
    updated_by  varchar(100),
    deleted_at  timestamptz,
    deleted_by  varchar(100),
    CONSTRAINT pk_producto_secciones PRIMARY KEY (id),
    CONSTRAINT ck_producto_secciones_vigencia
        CHECK (desde IS NULL OR hasta IS NULL OR hasta >= desde)
);

CREATE SEQUENCE IF NOT EXISTS ecommerce.producto_secciones_id_seq
    OWNED BY ecommerce.producto_secciones.id;
ALTER TABLE ecommerce.producto_secciones
    ALTER COLUMN id SET DEFAULT nextval('ecommerce.producto_secciones_id_seq');

-- El cruce. `ON DELETE CASCADE` por los dos lados: si la sección o el
-- producto desaparecen DE VERDAD —no de la papelera—, su fila aquí no tiene
-- a qué apuntar.
--
-- LA CLAVE ES UN `id` SUELTO Y EL PAR VA EN UN ÚNICO, que para el dato da lo
-- mismo. Lo pide la auditoría: `fn_auditar_cambios` guarda `NEW.id` en
-- `registro_id`, y con la clave primaria compuesta el disparador revienta con
-- «el registro new no tiene un campo id» en el primer INSERT.
CREATE TABLE IF NOT EXISTS ecommerce.producto_secciones_items (
    id          bigint      NOT NULL,
    seccion_id  bigint      NOT NULL,
    producto_id bigint      NOT NULL,
    orden       integer     NOT NULL DEFAULT 0,
    created_at  timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    created_by  varchar(100),
    CONSTRAINT pk_producto_secciones_items PRIMARY KEY (id),
    -- El par sigue siendo único: un producto, una vez por sección. Es lo que
    -- hace que «agregar» se pueda llamar dos veces sin duplicar nada.
    CONSTRAINT uq_producto_secciones_items UNIQUE (seccion_id, producto_id),
    CONSTRAINT fk_producto_secciones_items_seccion FOREIGN KEY (seccion_id)
        REFERENCES ecommerce.producto_secciones (id) ON DELETE CASCADE,
    CONSTRAINT fk_producto_secciones_items_producto FOREIGN KEY (producto_id)
        REFERENCES inventarios.productos (id) ON DELETE CASCADE
);

CREATE SEQUENCE IF NOT EXISTS ecommerce.producto_secciones_items_id_seq
    OWNED BY ecommerce.producto_secciones_items.id;
ALTER TABLE ecommerce.producto_secciones_items
    ALTER COLUMN id SET DEFAULT nextval('ecommerce.producto_secciones_items_id_seq');

-- Para la pregunta del revés: «¿en qué secciones está este producto?», que es
-- la que contesta la columna de la rejilla.
CREATE INDEX IF NOT EXISTS ix_producto_secciones_items_producto
    ON ecommerce.producto_secciones_items (producto_id);

-- Los disparadores de siempre, en las dos tablas.
--
-- SÍ, TAMBIÉN EN EL CRUCE, y eso significa que asignar cien productos de
-- golpe escribe cien filas de auditoría. Es a propósito: «¿quién sacó el
-- televisor de Ofertas y cuándo?» es la pregunta que se hace en una pantalla
-- donde trabajan varias personas, y sin la fila de auditoría no se puede
-- contestar. La tabla de auditoría sólo crece.
DO $disparadores$
BEGIN
    DROP TRIGGER IF EXISTS trg_producto_secciones_audit ON ecommerce.producto_secciones;
    CREATE TRIGGER trg_producto_secciones_audit AFTER INSERT OR UPDATE OR DELETE
        ON ecommerce.producto_secciones FOR EACH ROW
        EXECUTE FUNCTION auditoria.fn_auditar_cambios();
    DROP TRIGGER IF EXISTS trg_producto_secciones_updated_at ON ecommerce.producto_secciones;
    CREATE TRIGGER trg_producto_secciones_updated_at BEFORE UPDATE
        ON ecommerce.producto_secciones FOR EACH ROW
        EXECUTE FUNCTION auditoria.fn_update_updated_at_column();
    DROP TRIGGER IF EXISTS trg_producto_secciones_users ON ecommerce.producto_secciones;
    CREATE TRIGGER trg_producto_secciones_users BEFORE INSERT OR UPDATE
        ON ecommerce.producto_secciones FOR EACH ROW
        EXECUTE FUNCTION auditoria.fn_set_audit_users();

    DROP TRIGGER IF EXISTS trg_producto_secciones_items_audit ON ecommerce.producto_secciones_items;
    CREATE TRIGGER trg_producto_secciones_items_audit AFTER INSERT OR UPDATE OR DELETE
        ON ecommerce.producto_secciones_items FOR EACH ROW
        EXECUTE FUNCTION auditoria.fn_auditar_cambios();
    -- Sin `updated_at`: una fila del cruce no se modifica más que en su orden,
    -- y para eso ya está la auditoría. `fn_set_audit_users` se apaña sola con
    -- las tablas que no tienen `updated_by`.
    DROP TRIGGER IF EXISTS trg_producto_secciones_items_users ON ecommerce.producto_secciones_items;
    CREATE TRIGGER trg_producto_secciones_items_users BEFORE INSERT
        ON ecommerce.producto_secciones_items FOR EACH ROW
        EXECUTE FUNCTION auditoria.fn_set_audit_users();
END
$disparadores$;

-- ----------------------------------------------------------------------------
-- 2. LA SECCIÓN, EN JSON
-- ----------------------------------------------------------------------------
-- `productos` es lo que se enseña al lado del nombre, y cuenta SÓLO los que
-- de verdad están: sin los de la papelera. Si contara las filas del cruce, la
-- sección diría «8 productos» y la lista enseñaría seis.
CREATE OR REPLACE FUNCTION ecommerce.fn_producto_secciones_json(p_id bigint)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
AS $function$
    SELECT jsonb_build_object(
        'id',         s.id,
        'nombre',     s.nombre,
        'orden',      s.orden,
        'activo',     s.activo,
        'desde',      to_char(s.desde, 'YYYY-MM-DD"T"HH24:MI'),
        'hasta',      to_char(s.hasta, 'YYYY-MM-DD"T"HH24:MI'),
        -- Encendida Y en fechas: es lo que decide si el cliente la vería
        'visible',    s.activo AND ecommerce.fn_vigente(s.desde, s.hasta),
        'productos',  (SELECT count(*)
                         FROM ecommerce.producto_secciones_items i
                         JOIN inventarios.productos p ON p.id = i.producto_id
                        WHERE i.seccion_id = s.id AND p.deleted_at IS NULL),
        'deleted_at', to_char(s.deleted_at, 'YYYY-MM-DD HH24:MI:SS'),
        'deleted_by', s.deleted_by,
        'created_by', s.created_by,
        'updated_by', s.updated_by,
        'created_at', to_char(s.created_at, 'YYYY-MM-DD HH24:MI:SS'),
        'updated_at', to_char(s.updated_at, 'YYYY-MM-DD HH24:MI:SS')
    )
      FROM ecommerce.producto_secciones s
     WHERE s.id = p_id;
$function$;

CREATE OR REPLACE FUNCTION ecommerce.fn_producto_secciones_listar()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
AS $function$
    SELECT jsonb_build_object('success', true, 'message', 'Secciones de productos',
        'data', COALESCE((
            SELECT jsonb_agg(ecommerce.fn_producto_secciones_json(s.id) ORDER BY s.orden, s.id)
              FROM ecommerce.producto_secciones s
             WHERE s.deleted_at IS NULL), '[]'::jsonb));
$function$;

-- ----------------------------------------------------------------------------
-- 3. VALIDAR
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ecommerce.fn_producto_secciones_validar(
    p_id bigint, p_nombre character varying,
    p_desde timestamptz DEFAULT NULL, p_hasta timestamptz DEFAULT NULL)
 RETURNS void
 LANGUAGE plpgsql
 STABLE
AS $function$
BEGIN
    IF p_nombre IS NULL OR length(btrim(p_nombre)) < 2 THEN
        RAISE EXCEPTION 'El nombre de la sección es obligatorio (mínimo 2 caracteres)'
            USING ERRCODE = 'P0001';
    END IF;
    IF length(btrim(p_nombre)) > 80 THEN
        RAISE EXCEPTION 'El nombre de la sección no puede pasar de 80 caracteres'
            USING ERRCODE = 'P0015';
    END IF;
    -- Sin tildes ni mayúsculas: «Más vendidos» y «mas vendidos» son la misma,
    -- y dos secciones con el mismo nombre no se distinguen en la lista.
    IF EXISTS (SELECT 1 FROM ecommerce.producto_secciones
                WHERE ecommerce.fn_normalizar_nombre(nombre) = ecommerce.fn_normalizar_nombre(p_nombre)
                  AND deleted_at IS NULL
                  AND (p_id IS NULL OR id <> p_id)) THEN
        RAISE EXCEPTION 'Ya existe una sección llamada «%»', btrim(p_nombre)
            USING ERRCODE = 'P0006';
    END IF;
    IF p_desde IS NOT NULL AND p_hasta IS NOT NULL AND p_hasta < p_desde THEN
        RAISE EXCEPTION 'La fecha «hasta» no puede ser anterior a la fecha «desde»'
            USING ERRCODE = 'P0015';
    END IF;
END;
$function$;

-- ----------------------------------------------------------------------------
-- 4. CREAR, MODIFICAR, ENCENDER, ORDENAR
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ecommerce.fn_producto_secciones_crear(
    p_nombre character varying,
    p_desde timestamptz DEFAULT NULL, p_hasta timestamptz DEFAULT NULL,
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
    PERFORM ecommerce.fn_contexto_auditoria('ecommerce.producto_secciones',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    PERFORM ecommerce.fn_producto_secciones_validar(NULL, p_nombre, p_desde, p_hasta);

    INSERT INTO ecommerce.producto_secciones (nombre, desde, hasta, orden)
    VALUES (btrim(p_nombre), p_desde, p_hasta,
            (SELECT COALESCE(max(orden), 0) + 1 FROM ecommerce.producto_secciones
              WHERE deleted_at IS NULL))
    RETURNING id INTO v_id;

    RETURN jsonb_build_object('success', true,
        'message', format('Sección «%s» creada', btrim(p_nombre)),
        'data', ecommerce.fn_producto_secciones_json(v_id));
END;
$function$;

CREATE OR REPLACE FUNCTION ecommerce.fn_producto_secciones_modificar(
    p_id bigint, p_nombre character varying,
    p_desde timestamptz DEFAULT NULL, p_hasta timestamptz DEFAULT NULL,
    p_usuario_id bigint DEFAULT NULL, p_usuario_login character varying DEFAULT NULL,
    p_usuario_nombre character varying DEFAULT NULL, p_ip_address inet DEFAULT NULL,
    p_user_agent text DEFAULT NULL, p_request_id uuid DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'ecommerce', 'auditoria'
AS $function$
BEGIN
    PERFORM ecommerce.fn_contexto_auditoria('ecommerce.producto_secciones',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    IF NOT EXISTS (SELECT 1 FROM ecommerce.producto_secciones
                    WHERE id = p_id AND deleted_at IS NULL) THEN
        RAISE EXCEPTION 'La sección no existe' USING ERRCODE = 'P0013';
    END IF;

    PERFORM ecommerce.fn_producto_secciones_validar(p_id, p_nombre, p_desde, p_hasta);

    UPDATE ecommerce.producto_secciones
       SET nombre = btrim(p_nombre), desde = p_desde, hasta = p_hasta
     WHERE id = p_id;

    RETURN jsonb_build_object('success', true, 'message', 'Sección actualizada',
        'data', ecommerce.fn_producto_secciones_json(p_id));
END;
$function$;

-- Sin `p_activo`, alterna: es lo que hace la palanca de la lista.
CREATE OR REPLACE FUNCTION ecommerce.fn_producto_secciones_activar(
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
    v_antes  boolean;
    v_nombre text;
BEGIN
    PERFORM ecommerce.fn_contexto_auditoria('ecommerce.producto_secciones',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    SELECT activo, nombre INTO v_antes, v_nombre
      FROM ecommerce.producto_secciones WHERE id = p_id AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'La sección no existe' USING ERRCODE = 'P0013';
    END IF;

    UPDATE ecommerce.producto_secciones
       SET activo = COALESCE(p_activo, NOT v_antes) WHERE id = p_id;

    RETURN jsonb_build_object('success', true,
        'message', format('Sección «%s» %s', v_nombre,
            CASE WHEN COALESCE(p_activo, NOT v_antes) THEN 'encendida' ELSE 'apagada' END),
        'data', ecommerce.fn_producto_secciones_json(p_id));
END;
$function$;

CREATE OR REPLACE FUNCTION ecommerce.fn_producto_secciones_ordenar(
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
    PERFORM ecommerce.fn_contexto_auditoria('ecommerce.producto_secciones',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    IF jsonb_typeof(p_ids) <> 'array' THEN
        RAISE EXCEPTION 'Se esperaba la lista de secciones en el orden nuevo' USING ERRCODE = 'P0015';
    END IF;

    -- El orden es la POSICIÓN en la lista que llega, no un número del cliente:
    -- así no hay huecos ni empates aunque se arrastre varias veces.
    UPDATE ecommerce.producto_secciones s
       SET orden = t.posicion
      FROM (SELECT valor::bigint AS id, ordinalidad::integer AS posicion
              FROM jsonb_array_elements_text(p_ids) WITH ORDINALITY AS x(valor, ordinalidad)) t
     WHERE s.id = t.id AND s.deleted_at IS NULL;
    GET DIAGNOSTICS v_cuantas = ROW_COUNT;

    RETURN jsonb_build_object('success', true,
        'message', CASE v_cuantas WHEN 1 THEN 'Sección movida'
                                  ELSE format('%s secciones reordenadas', v_cuantas) END,
        'data', (ecommerce.fn_producto_secciones_listar() -> 'data'));
END;
$function$;

-- ----------------------------------------------------------------------------
-- 5. PAPELERA
-- ----------------------------------------------------------------------------
-- Los productos de la sección NO se tocan al borrarla: el cruce se queda tal
-- cual, así que restaurarla la devuelve con todo lo que tenía dentro. Borrar
-- una sección es quitar un escaparate, no desarmarlo.
CREATE OR REPLACE FUNCTION ecommerce.fn_producto_secciones_eliminar(
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
    v_items  integer;
BEGIN
    PERFORM ecommerce.fn_contexto_auditoria('ecommerce.producto_secciones',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    SELECT nombre INTO v_nombre FROM ecommerce.producto_secciones
     WHERE id = p_id AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'La sección no existe' USING ERRCODE = 'P0013';
    END IF;

    SELECT count(*) INTO v_items FROM ecommerce.producto_secciones_items WHERE seccion_id = p_id;

    UPDATE ecommerce.producto_secciones
       SET deleted_at = CURRENT_TIMESTAMP, deleted_by = p_usuario_login
     WHERE id = p_id;

    RETURN jsonb_build_object('success', true,
        'message', CASE v_items
            WHEN 0 THEN format('Sección «%s» enviada a la papelera', v_nombre)
            WHEN 1 THEN format('Sección «%s» enviada a la papelera con su producto', v_nombre)
            ELSE format('Sección «%s» enviada a la papelera con sus %s productos', v_nombre, v_items) END,
        'data', ecommerce.fn_producto_secciones_json(p_id));
END;
$function$;

CREATE OR REPLACE FUNCTION ecommerce.fn_producto_secciones_restaurar(
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
    v_fecha  timestamptz;
BEGIN
    PERFORM ecommerce.fn_contexto_auditoria('ecommerce.producto_secciones',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    SELECT nombre, deleted_at INTO v_nombre, v_fecha
      FROM ecommerce.producto_secciones WHERE id = p_id;
    IF NOT FOUND OR v_fecha IS NULL THEN
        RAISE EXCEPTION 'Esa sección no está en la papelera' USING ERRCODE = 'P0019';
    END IF;

    -- Mientras estaba en la papelera pudieron crear otra con el mismo nombre
    PERFORM ecommerce.fn_producto_secciones_validar(p_id, v_nombre);

    UPDATE ecommerce.producto_secciones
       SET deleted_at = NULL, deleted_by = NULL WHERE id = p_id;

    RETURN jsonb_build_object('success', true,
        'message', format('Sección «%s» restaurada', v_nombre),
        'data', ecommerce.fn_producto_secciones_json(p_id));
END;
$function$;

CREATE OR REPLACE FUNCTION ecommerce.fn_producto_secciones_papelera_listar()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
AS $function$
    SELECT jsonb_build_object('success', true, 'message', 'Papelera de secciones',
        'data', COALESCE((
            SELECT jsonb_agg(ecommerce.fn_producto_secciones_json(s.id) ORDER BY s.deleted_at DESC)
              FROM ecommerce.producto_secciones s
             WHERE s.deleted_at IS NOT NULL), '[]'::jsonb));
$function$;

-- ----------------------------------------------------------------------------
-- 6. LOS PRODUCTOS DE UNA SECCIÓN
-- ----------------------------------------------------------------------------
-- Las filas salen de `inventarios.fn_productos_json`, LA MISMA que usa la
-- rejilla del catálogo. Así la pantalla puede pintar las dos vistas —el
-- catálogo y la sección— con las mismas columnas; si aquí se armara el JSON a
-- mano, cada columna nueva del catálogo habría que añadirla dos veces.
CREATE OR REPLACE FUNCTION ecommerce.fn_producto_seccion_productos(p_seccion_id bigint)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
AS $function$
    SELECT jsonb_build_object('success', true, 'message', 'Productos de la sección',
        'data', COALESCE((
            SELECT jsonb_agg(inventarios.fn_productos_json(p.id)
                             || jsonb_build_object('orden_seccion', i.orden)
                             ORDER BY i.orden, p.id)
              FROM ecommerce.producto_secciones_items i
              JOIN inventarios.productos p ON p.id = i.producto_id
             WHERE i.seccion_id = p_seccion_id
               AND p.deleted_at IS NULL), '[]'::jsonb));
$function$;

-- Sólo los ids, que es lo que necesita la rejilla del catálogo para marcar
-- qué filas ya están dentro. Aquí sí entran los de la papelera: si un
-- producto borrado vuelve, ya estaba en la sección y agregarlo otra vez no
-- haría nada; marcarlo evita que parezca que falta.
CREATE OR REPLACE FUNCTION ecommerce.fn_producto_seccion_ids(p_seccion_id bigint)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
AS $function$
    SELECT jsonb_build_object('success', true, 'message', 'Productos de la sección',
        'data', COALESCE((
            SELECT jsonb_agg(i.producto_id ORDER BY i.orden, i.producto_id)
              FROM ecommerce.producto_secciones_items i
             WHERE i.seccion_id = p_seccion_id), '[]'::jsonb));
$function$;

-- ----------------------------------------------------------------------------
-- 7. AGREGAR Y QUITAR
-- ----------------------------------------------------------------------------
-- Los dos reciben una LISTA, no un id: agregar de a uno y agregar cincuenta
-- es el mismo gesto desde la pantalla, y con dos funciones una de las dos se
-- queda sin arreglar cuando cambie la regla.
CREATE OR REPLACE FUNCTION ecommerce.fn_producto_seccion_agregar(
    p_seccion_id bigint, p_producto_ids jsonb,
    p_usuario_id bigint DEFAULT NULL, p_usuario_login character varying DEFAULT NULL,
    p_usuario_nombre character varying DEFAULT NULL, p_ip_address inet DEFAULT NULL,
    p_user_agent text DEFAULT NULL, p_request_id uuid DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'ecommerce', 'auditoria'
AS $function$
DECLARE
    v_nombre    text;
    v_pedidos   bigint[];
    v_faltan    bigint[];
    v_base      integer;
    v_metidos   integer;
BEGIN
    PERFORM ecommerce.fn_contexto_auditoria('ecommerce.producto_secciones_items',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    SELECT nombre INTO v_nombre FROM ecommerce.producto_secciones
     WHERE id = p_seccion_id AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'La sección no existe' USING ERRCODE = 'P0013';
    END IF;

    IF jsonb_typeof(p_producto_ids) <> 'array' THEN
        RAISE EXCEPTION 'Se esperaba la lista de productos' USING ERRCODE = 'P0015';
    END IF;

    SELECT array_agg(DISTINCT valor::bigint) INTO v_pedidos
      FROM jsonb_array_elements_text(p_producto_ids) AS x(valor);

    IF v_pedidos IS NULL OR cardinality(v_pedidos) = 0 THEN
        RAISE EXCEPTION 'No se eligió ningún producto' USING ERRCODE = 'P0001';
    END IF;

    -- Un id que no existe es un fallo del cliente, no un caso normal: se
    -- avisa en vez de meter los demás y callarse, porque entonces la pantalla
    -- diría «40 agregados» de los 41 que se pidieron y nadie lo notaría.
    SELECT array_agg(id) INTO v_faltan
      FROM unnest(v_pedidos) AS id
     WHERE NOT EXISTS (SELECT 1 FROM inventarios.productos p
                        WHERE p.id = id AND p.deleted_at IS NULL);
    IF v_faltan IS NOT NULL THEN
        RAISE EXCEPTION 'Estos productos ya no están en el catálogo: %',
            array_to_string(v_faltan, ', ') USING ERRCODE = 'P0013';
    END IF;

    -- Al final de la sección, en el orden en que llegaron
    SELECT COALESCE(max(orden), 0) INTO v_base
      FROM ecommerce.producto_secciones_items WHERE seccion_id = p_seccion_id;

    INSERT INTO ecommerce.producto_secciones_items (seccion_id, producto_id, orden)
    SELECT p_seccion_id, t.id, v_base + t.posicion
      FROM (SELECT id, row_number() OVER (ORDER BY id)::integer AS posicion
              FROM unnest(v_pedidos) AS id) t
        ON CONFLICT (seccion_id, producto_id) DO NOTHING;
    GET DIAGNOSTICS v_metidos = ROW_COUNT;

    RETURN jsonb_build_object('success', true,
        'message', CASE
            WHEN v_metidos = 0 THEN format('Ya estaban todos en «%s»', v_nombre)
            WHEN v_metidos = cardinality(v_pedidos) AND v_metidos = 1
                THEN format('1 producto agregado a «%s»', v_nombre)
            WHEN v_metidos = cardinality(v_pedidos)
                THEN format('%s productos agregados a «%s»', v_metidos, v_nombre)
            ELSE format('%s agregados a «%s»; %s ya estaban', v_metidos, v_nombre,
                        cardinality(v_pedidos) - v_metidos) END,
        'data', jsonb_build_object(
            'seccion',   ecommerce.fn_producto_secciones_json(p_seccion_id),
            'agregados', v_metidos,
            'repetidos', cardinality(v_pedidos) - v_metidos));
END;
$function$;

CREATE OR REPLACE FUNCTION ecommerce.fn_producto_seccion_quitar(
    p_seccion_id bigint, p_producto_ids jsonb,
    p_usuario_id bigint DEFAULT NULL, p_usuario_login character varying DEFAULT NULL,
    p_usuario_nombre character varying DEFAULT NULL, p_ip_address inet DEFAULT NULL,
    p_user_agent text DEFAULT NULL, p_request_id uuid DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'ecommerce', 'auditoria'
AS $function$
DECLARE
    v_nombre  text;
    v_pedidos bigint[];
    v_fuera   integer;
BEGIN
    PERFORM ecommerce.fn_contexto_auditoria('ecommerce.producto_secciones_items',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    SELECT nombre INTO v_nombre FROM ecommerce.producto_secciones
     WHERE id = p_seccion_id AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'La sección no existe' USING ERRCODE = 'P0013';
    END IF;

    IF jsonb_typeof(p_producto_ids) <> 'array' THEN
        RAISE EXCEPTION 'Se esperaba la lista de productos' USING ERRCODE = 'P0015';
    END IF;

    SELECT array_agg(DISTINCT valor::bigint) INTO v_pedidos
      FROM jsonb_array_elements_text(p_producto_ids) AS x(valor);

    IF v_pedidos IS NULL OR cardinality(v_pedidos) = 0 THEN
        RAISE EXCEPTION 'No se eligió ningún producto' USING ERRCODE = 'P0001';
    END IF;

    -- Quitar algo que no estaba no es un error: el producto acaba fuera, que
    -- es lo que se pedía. Lo que se dice es cuántos se fueron de verdad.
    DELETE FROM ecommerce.producto_secciones_items
     WHERE seccion_id = p_seccion_id AND producto_id = ANY(v_pedidos);
    GET DIAGNOSTICS v_fuera = ROW_COUNT;

    -- Renumerar: si no, quitar del medio deja huecos y el siguiente que se
    -- agregue cae con un orden que ya pasó.
    WITH nuevo AS (
        SELECT producto_id, row_number() OVER (ORDER BY orden, producto_id)::integer AS posicion
          FROM ecommerce.producto_secciones_items WHERE seccion_id = p_seccion_id)
    UPDATE ecommerce.producto_secciones_items i
       SET orden = n.posicion
      FROM nuevo n
     WHERE i.seccion_id = p_seccion_id AND i.producto_id = n.producto_id
       AND i.orden <> n.posicion;

    RETURN jsonb_build_object('success', true,
        'message', CASE
            WHEN v_fuera = 0 THEN format('Ninguno de esos productos estaba en «%s»', v_nombre)
            WHEN v_fuera = 1 THEN format('1 producto fuera de «%s»', v_nombre)
            ELSE format('%s productos fuera de «%s»', v_fuera, v_nombre) END,
        'data', jsonb_build_object(
            'seccion',  ecommerce.fn_producto_secciones_json(p_seccion_id),
            'quitados', v_fuera));
END;
$function$;

CREATE OR REPLACE FUNCTION ecommerce.fn_producto_seccion_ordenar(
    p_seccion_id bigint, p_producto_ids jsonb,
    p_usuario_id bigint DEFAULT NULL, p_usuario_login character varying DEFAULT NULL,
    p_usuario_nombre character varying DEFAULT NULL, p_ip_address inet DEFAULT NULL,
    p_user_agent text DEFAULT NULL, p_request_id uuid DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'ecommerce', 'auditoria'
AS $function$
DECLARE
    v_cuantos integer;
BEGIN
    PERFORM ecommerce.fn_contexto_auditoria('ecommerce.producto_secciones_items',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    IF NOT EXISTS (SELECT 1 FROM ecommerce.producto_secciones
                    WHERE id = p_seccion_id AND deleted_at IS NULL) THEN
        RAISE EXCEPTION 'La sección no existe' USING ERRCODE = 'P0013';
    END IF;

    IF jsonb_typeof(p_producto_ids) <> 'array' THEN
        RAISE EXCEPTION 'Se esperaba la lista de productos en el orden nuevo' USING ERRCODE = 'P0015';
    END IF;

    UPDATE ecommerce.producto_secciones_items i
       SET orden = t.posicion
      FROM (SELECT valor::bigint AS id, ordinalidad::integer AS posicion
              FROM jsonb_array_elements_text(p_producto_ids) WITH ORDINALITY AS x(valor, ordinalidad)) t
     WHERE i.seccion_id = p_seccion_id AND i.producto_id = t.id;
    GET DIAGNOSTICS v_cuantos = ROW_COUNT;

    RETURN jsonb_build_object('success', true,
        'message', CASE v_cuantos WHEN 1 THEN 'Producto movido'
                                  ELSE format('%s productos reordenados', v_cuantos) END,
        'data', (ecommerce.fn_producto_seccion_productos(p_seccion_id) -> 'data'));
END;
$function$;

-- ----------------------------------------------------------------------------
-- 8. AGREGAR TODO LO QUE CUMPLE EL FILTRO
-- ----------------------------------------------------------------------------
-- LA ASIGNACIÓN MASIVA DE VERDAD: no los de la página que se está viendo, sino
-- TODOS los que cumplen el filtro del panel —marca, categoría, rangos,
-- búsqueda y los filtros de cabecera—, que pueden ser mil y estar repartidos
-- en cien páginas.
--
-- Y LA LISTA LA RESUELVE `inventarios.fn_productos_listar_paginado`, la misma
-- función que llena la rejilla. No una copia de su WHERE: una copia se separa
-- del original en el primer filtro nuevo, y entonces la pantalla asigna algo
-- distinto de lo que estaba enseñando. Así «asignar todo lo que se ve» es
-- verdad por construcción.
CREATE OR REPLACE FUNCTION ecommerce.fn_producto_seccion_agregar_filtro(
    p_seccion_id bigint, p_filtro jsonb,
    p_usuario_id bigint DEFAULT NULL, p_usuario_login character varying DEFAULT NULL,
    p_usuario_nombre character varying DEFAULT NULL, p_ip_address inet DEFAULT NULL,
    p_user_agent text DEFAULT NULL, p_request_id uuid DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'ecommerce', 'auditoria', 'inventarios'
AS $function$
DECLARE
    v_search     text;
    v_marcas     bigint[];
    v_categorias bigint[];
    v_filtros    jsonb;
    v_total      bigint;
    v_ids        jsonb;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM ecommerce.producto_secciones
                    WHERE id = p_seccion_id AND deleted_at IS NULL) THEN
        RAISE EXCEPTION 'La sección no existe' USING ERRCODE = 'P0013';
    END IF;

    p_filtro := COALESCE(p_filtro, '{}'::jsonb);
    IF jsonb_typeof(p_filtro) <> 'object' THEN
        RAISE EXCEPTION 'Se esperaba el filtro del panel' USING ERRCODE = 'P0015';
    END IF;

    v_search  := COALESCE(p_filtro ->> 'search', '');
    v_filtros := CASE WHEN jsonb_typeof(p_filtro -> 'filtros') = 'object'
                      THEN p_filtro -> 'filtros' ELSE '{}'::jsonb END;

    SELECT array_agg(valor::bigint) INTO v_marcas
      FROM jsonb_array_elements_text(
               CASE WHEN jsonb_typeof(p_filtro -> 'marca_ids') = 'array'
                    THEN p_filtro -> 'marca_ids' ELSE '[]'::jsonb END) AS x(valor);

    SELECT array_agg(valor::bigint) INTO v_categorias
      FROM jsonb_array_elements_text(
               CASE WHEN jsonb_typeof(p_filtro -> 'categoria_ids') = 'array'
                    THEN p_filtro -> 'categoria_ids' ELSE '[]'::jsonb END) AS x(valor);

    -- Primero cuántos son: `p_per_page` tiene que ser un número de verdad y
    -- pedir «todos» con un tope inventado dejaría fuera lo que pase del tope
    -- sin avisar de nada.
    v_total := (inventarios.fn_productos_listar_paginado(
                    1, 1, v_search, v_marcas, v_categorias, v_filtros,
                    (p_filtro ->> 'precio_min')::numeric, (p_filtro ->> 'precio_max')::numeric,
                    (p_filtro ->> 'costo_min')::numeric,  (p_filtro ->> 'costo_max')::numeric
                ) -> 'meta' ->> 'total')::bigint;

    IF v_total IS NULL THEN
        RAISE EXCEPTION 'No pude contar los productos del filtro' USING ERRCODE = 'P0015';
    END IF;
    IF v_total = 0 THEN
        RAISE EXCEPTION 'Con ese filtro no hay ningún producto que agregar' USING ERRCODE = 'P0001';
    END IF;

    SELECT jsonb_agg(fila -> 'id') INTO v_ids
      FROM jsonb_array_elements(
               inventarios.fn_productos_listar_paginado(
                   1, v_total::integer, v_search, v_marcas, v_categorias, v_filtros,
                   (p_filtro ->> 'precio_min')::numeric, (p_filtro ->> 'precio_max')::numeric,
                   (p_filtro ->> 'costo_min')::numeric,  (p_filtro ->> 'costo_max')::numeric
               ) -> 'data') AS x(fila);

    RETURN ecommerce.fn_producto_seccion_agregar(p_seccion_id, v_ids,
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);
END;
$function$;

-- ----------------------------------------------------------------------------
-- 9. CUÁNTAS HAY, PARA LA PORTADA DEL MÓDULO
-- ----------------------------------------------------------------------------
-- La tarjeta de la portada dice «3 secciones, 24 productos». La portada pide
-- todo de una vez (ecommerce.fn_resumen), así que esto se le añade allí.
--
-- No se reescribe la función: se vuelca con pg_get_functiondef y se le
-- engancha la cuenta delante del RETURN. Ese resumen crece con cada pantalla
-- nueva, y copiarlo aquí dejaría dos versiones que un día dejan de coincidir.
DO $resumen$
DECLARE
    def   text;
    ancla text := E'\n    RETURN jsonb_build_object(''success'', true, ''message'', ''Resumen de la página web'', ''data'', v);';
BEGIN
    SELECT pg_get_functiondef(p.oid) INTO def
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'ecommerce' AND p.proname = 'fn_resumen';

    IF def IS NULL THEN
        RAISE NOTICE 'No está ecommerce.fn_resumen: la tarjeta de la portada se queda sin cuenta.';
        RETURN;
    END IF;

    IF strpos(def, 'producto_secciones') > 0 THEN
        RAISE NOTICE 'El resumen ya cuenta las secciones de productos.';
        RETURN;
    END IF;

    IF strpos(def, ancla) = 0 THEN
        RAISE EXCEPTION 'No encontré el RETURN de ecommerce.fn_resumen: ¿cambió la función?';
    END IF;

    def := replace(def, ancla,
        E'\n    v := v || jsonb_build_object(''producto_secciones'', jsonb_build_object('
        || E'\n            ''secciones'', (SELECT count(*) FROM ecommerce.producto_secciones'
        || E'\n                             WHERE deleted_at IS NULL),'
        || E'\n            ''productos'',  (SELECT count(*) FROM ecommerce.producto_secciones_items i'
        || E'\n                             JOIN ecommerce.producto_secciones s ON s.id = i.seccion_id'
        || E'\n                             JOIN inventarios.productos p ON p.id = i.producto_id'
        || E'\n                            WHERE s.deleted_at IS NULL AND p.deleted_at IS NULL)));'
        || ancla);

    EXECUTE def;
    RAISE NOTICE 'El resumen de la portada ya cuenta las secciones de productos.';
END
$resumen$;

-- ----------------------------------------------------------------------------
-- 10. COMPROBACIÓN
-- ----------------------------------------------------------------------------
-- Se prueba de verdad —crear, agregar, agregar lo mismo otra vez, quitar,
-- reordenar— y luego se DESHACE todo con el truco de la subtransacción: la
-- excepción tira los INSERT y los DELETE, pero las variables de plpgsql se
-- quedan con lo que leyeron. Así la comprobación no deja secciones de prueba
-- ni filas de auditoría en una tabla donde trabaja alguien más.
--
-- EL CÓDIGO DE LA EXCEPCIÓN ES P0099, QUE NO USA NADIE. Con P0001 —el de «te
-- falta un dato», que lanzan varias de las funciones de arriba— el handler
-- también se tragaría un fallo de verdad, las variables se quedarían en NULL,
-- y las comparaciones de abajo darían NULL, que no es TRUE: la comprobación
-- pasaría en verde sin haber comprobado nada. Por si acaso, cada una mira
-- también si su variable llegó a tener valor.
DO $comprobar$
DECLARE
    v_id        bigint;
    v_p1        bigint;
    v_p2        bigint;
    v_r         jsonb;
    v_primera   integer;
    v_repetida  integer;
    v_cuenta    integer;
    v_tras_quitar integer;
    v_orden     bigint;
    v_masiva    integer;
    v_catalogo  bigint;
BEGIN
    SELECT id INTO v_p1 FROM inventarios.productos WHERE deleted_at IS NULL ORDER BY id LIMIT 1;
    SELECT id INTO v_p2 FROM inventarios.productos WHERE deleted_at IS NULL AND id <> v_p1
     ORDER BY id LIMIT 1;
    IF v_p1 IS NULL OR v_p2 IS NULL THEN
        RAISE NOTICE 'Hacen falta dos productos para comprobar; las tablas y las funciones están.';
        RETURN;
    END IF;

    v_catalogo := (inventarios.fn_productos_listar_paginado(1, 1, '', NULL, NULL, '{}'::jsonb)
                   -> 'meta' ->> 'total')::bigint;

    BEGIN
        v_r := ecommerce.fn_producto_secciones_crear('Comprobación de la migración ' || clock_timestamp());
        v_id := (v_r -> 'data' ->> 'id')::bigint;

        -- Agregar dos, y los mismos dos otra vez: la segunda no mete nada
        v_primera  := (ecommerce.fn_producto_seccion_agregar(v_id,
                          jsonb_build_array(v_p1, v_p2)) -> 'data' ->> 'agregados')::integer;
        v_repetida := (ecommerce.fn_producto_seccion_agregar(v_id,
                          jsonb_build_array(v_p1, v_p2)) -> 'data' ->> 'agregados')::integer;

        v_cuenta := jsonb_array_length(ecommerce.fn_producto_seccion_productos(v_id) -> 'data');

        -- Al revés, y que el primero sea el que se puso segundo
        PERFORM ecommerce.fn_producto_seccion_ordenar(v_id, jsonb_build_array(v_p2, v_p1));
        v_orden := ((ecommerce.fn_producto_seccion_productos(v_id) -> 'data' -> 0) ->> 'id')::bigint;

        -- Quitar uno
        PERFORM ecommerce.fn_producto_seccion_quitar(v_id, jsonb_build_array(v_p2));
        v_tras_quitar := (ecommerce.fn_producto_secciones_json(v_id) ->> 'productos')::integer;

        -- Y la masiva sin filtro: tiene que traer el catálogo entero
        v_masiva := (ecommerce.fn_producto_seccion_agregar_filtro(v_id, '{}'::jsonb)
                     -> 'data' ->> 'agregados')::integer;

        RAISE EXCEPTION 'deshacer' USING ERRCODE = 'P0099';
    EXCEPTION WHEN SQLSTATE 'P0099' THEN
        NULL;   -- se tiran los cambios; las variables se quedan con lo leído
    END;

    IF v_primera IS NULL OR v_primera <> 2 THEN
        RAISE EXCEPTION 'Agregar dos productos metió % en vez de 2', v_primera;
    END IF;
    IF v_repetida IS NULL OR v_repetida <> 0 THEN
        RAISE EXCEPTION 'Los mismos dos otra vez metieron % en vez de 0', v_repetida;
    END IF;
    IF v_cuenta IS NULL OR v_cuenta <> 2 THEN
        RAISE EXCEPTION 'La sección tendría que tener 2 productos y tiene %', v_cuenta;
    END IF;
    IF v_orden IS NULL OR v_orden <> v_p2 THEN
        RAISE EXCEPTION 'El reorden no puso primero al producto % (primero: %)', v_p2, v_orden;
    END IF;
    IF v_tras_quitar IS NULL OR v_tras_quitar <> 1 THEN
        RAISE EXCEPTION 'Tras quitar uno quedarían 1 y quedan %', v_tras_quitar;
    END IF;
    -- Quedaba uno dentro, así que la masiva mete todos los demás
    IF v_catalogo IS NULL OR v_masiva IS NULL OR v_masiva <> (v_catalogo - 1)::integer THEN
        RAISE EXCEPTION 'La masiva sin filtro metió % y el catálogo tiene % (uno ya estaba)',
            v_masiva, v_catalogo;
    END IF;
    IF EXISTS (SELECT 1 FROM ecommerce.producto_secciones WHERE id = v_id) THEN
        RAISE EXCEPTION 'La sección de prueba se quedó en la tabla';
    END IF;

    RAISE NOTICE 'Comprobado: agregar no duplica, quitar renumera, el orden se guarda, y la masiva sin filtro trae el catálogo entero (% productos). No quedó nada de la prueba.', v_catalogo;
END
$comprobar$;

COMMIT;
