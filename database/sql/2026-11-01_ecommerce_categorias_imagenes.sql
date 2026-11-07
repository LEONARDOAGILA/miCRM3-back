-- ============================================================================
-- ECOMMERCE · LA IMAGEN DE CADA CATEGORÍA, PROGRAMADA POR FECHAS
-- ============================================================================
-- Fecha: 2026-11-01
--
-- Una categoría puede tener VARIAS imágenes preparadas y cada una con sus
-- fechas: la de siempre, la de navidad del 1 al 26 de diciembre, la del día
-- de la madre. La tienda enseña la que toque hoy, sin que nadie tenga que
-- acordarse de cambiarla.
--
-- SIN FECHAS, ILIMITADA. `desde` y `hasta` en nulo quieren decir «desde
-- siempre» y «para siempre»: es el caso normal y no hay que escribir nada.
--
-- SI DOS SE PISAN, MANDA EL ORDEN. Dos imágenes vigentes a la vez no es un
-- error —la de navidad se programa encima de la de siempre—, así que sale la
-- primera por orden y la pantalla avisa de cuál queda tapada en vez de
-- negarse a guardar.
--
-- EL FICHERO VA EN storage/app/public/img/ecommerce, que es donde el CRM
-- guarda el resto de sus imágenes (usuarios, marcas, productos) y se sirve
-- por el enlace `public/storage`. En la base va SÓLO EL NOMBRE: la dirección
-- la arma el controlador al leer, así que mover el CRM de máquina no obliga a
-- repasar la base.
--
-- Idempotente.
-- ============================================================================
\set ON_ERROR_STOP on

BEGIN;

-- ----------------------------------------------------------------------------
-- 1. LA TABLA
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS ecommerce.categorias_imagenes (
    id           bigint       NOT NULL,
    categoria_id bigint       NOT NULL,
    -- El nombre del fichero dentro de img/ecommerce. Nunca una dirección.
    imagen       varchar(150) NOT NULL,
    -- Para reconocerla en la lista: «Navidad 2026», «La de siempre»
    nombre       varchar(100),
    desde        timestamptz,
    hasta        timestamptz,
    orden        integer      NOT NULL DEFAULT 0,
    activo       boolean      NOT NULL DEFAULT true,
    created_at   timestamptz  NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at   timestamptz  NOT NULL DEFAULT CURRENT_TIMESTAMP,
    created_by   varchar(100),
    updated_by   varchar(100),
    deleted_at   timestamptz,
    deleted_by   varchar(100),
    CONSTRAINT pk_categorias_imagenes PRIMARY KEY (id),
    CONSTRAINT fk_categorias_imagenes_categoria
        FOREIGN KEY (categoria_id) REFERENCES inventarios.categorias (id),
    CONSTRAINT ck_categorias_imagenes_vigencia
        CHECK (desde IS NULL OR hasta IS NULL OR hasta >= desde),
    -- El nombre del fichero, no una dirección: un `/` aquí significaría que
    -- alguien guardó la URL entera y el día que cambie el servidor se rompe.
    CONSTRAINT ck_categorias_imagenes_fichero
        CHECK (imagen ~ '^[A-Za-z0-9][A-Za-z0-9._-]*\.(jpg|jpeg|png|webp|gif)$')
);

CREATE SEQUENCE IF NOT EXISTS ecommerce.categorias_imagenes_id_seq
    OWNED BY ecommerce.categorias_imagenes.id;
ALTER TABLE ecommerce.categorias_imagenes
    ALTER COLUMN id SET DEFAULT nextval('ecommerce.categorias_imagenes_id_seq');

CREATE INDEX IF NOT EXISTS ix_categorias_imagenes_categoria
    ON ecommerce.categorias_imagenes (categoria_id) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_categorias_imagenes_deleted_at
    ON ecommerce.categorias_imagenes (deleted_at) WHERE deleted_at IS NOT NULL;

DO $disparadores$
BEGIN
    DROP TRIGGER IF EXISTS trg_categorias_imagenes_audit ON ecommerce.categorias_imagenes;
    CREATE TRIGGER trg_categorias_imagenes_audit AFTER INSERT OR UPDATE OR DELETE
        ON ecommerce.categorias_imagenes FOR EACH ROW EXECUTE FUNCTION auditoria.fn_auditar_cambios();
    DROP TRIGGER IF EXISTS trg_categorias_imagenes_updated_at ON ecommerce.categorias_imagenes;
    CREATE TRIGGER trg_categorias_imagenes_updated_at BEFORE UPDATE
        ON ecommerce.categorias_imagenes FOR EACH ROW EXECUTE FUNCTION auditoria.fn_update_updated_at_column();
    DROP TRIGGER IF EXISTS trg_categorias_imagenes_users ON ecommerce.categorias_imagenes;
    CREATE TRIGGER trg_categorias_imagenes_users BEFORE INSERT OR UPDATE
        ON ecommerce.categorias_imagenes FOR EACH ROW EXECUTE FUNCTION auditoria.fn_set_audit_users();
END
$disparadores$;

-- ----------------------------------------------------------------------------
-- 2. LAS IMÁGENES DE UNA CATEGORÍA, COMO LAS VE LA PANTALLA
-- ----------------------------------------------------------------------------
-- Con TODAS: las apagadas, las que ya terminaron y las que aún no empiezan.
-- Eso es lo que se administra, y el estado es lo que distingue «se me olvidó
-- encenderla» de «ya pasó su fecha», que se arreglan de maneras distintas.
--
-- `sale_ahora` dice cuál es LA QUE SE VE en la tienda en este momento, y
-- `tapada` las que están vigentes pero detrás de ella. Sin eso, dos imágenes
-- vigentes se ven iguales en la lista y no hay forma de saber cuál manda.
CREATE OR REPLACE FUNCTION ecommerce.fn_categorias_imagenes_json(p_categoria_id bigint)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
AS $function$
    WITH vivas AS (
        SELECT i.*,
               (i.activo AND ecommerce.fn_vigente(i.desde, i.hasta)) AS vigente
          FROM ecommerce.categorias_imagenes i
         WHERE i.categoria_id = p_categoria_id AND i.deleted_at IS NULL
    ),
    mandona AS (
        SELECT id FROM vivas WHERE vigente ORDER BY orden, id LIMIT 1
    )
    SELECT jsonb_build_object(
        'categoria_id', p_categoria_id,
        'en_papelera', (SELECT count(*) FROM ecommerce.categorias_imagenes b
                         WHERE b.categoria_id = p_categoria_id AND b.deleted_at IS NOT NULL),
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

CREATE OR REPLACE FUNCTION ecommerce.fn_categorias_imagenes_listar(p_categoria_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'ecommerce', 'auditoria'
AS $function$
DECLARE
    v_nombre text;
BEGIN
    SELECT nombre INTO v_nombre FROM inventarios.categorias
     WHERE id = p_categoria_id AND deleted_at IS NULL;
    IF v_nombre IS NULL THEN
        RAISE EXCEPTION 'La categoría no existe' USING ERRCODE = 'P0013';
    END IF;

    RETURN jsonb_build_object('success', true, 'message', format('Imágenes de «%s»', v_nombre),
                              'data', ecommerce.fn_categorias_imagenes_json(p_categoria_id));
END;
$function$;

-- Cuántas tiene cada categoría y si alguna sale hoy: es la chapita del árbol.
CREATE OR REPLACE FUNCTION ecommerce.fn_categorias_imagenes_cuentas()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
AS $function$
    SELECT jsonb_build_object('success', true, 'message', 'Imágenes por categoría',
        'data', COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
                       'categoria_id', x.categoria_id,
                       'cuantas',      x.cuantas,
                       'sale_alguna',  x.sale_alguna))
              FROM (SELECT i.categoria_id,
                           count(*) AS cuantas,
                           bool_or(i.activo AND ecommerce.fn_vigente(i.desde, i.hasta)) AS sale_alguna
                      FROM ecommerce.categorias_imagenes i
                     WHERE i.deleted_at IS NULL
                     GROUP BY i.categoria_id) x), '[]'::jsonb));
$function$;

-- ----------------------------------------------------------------------------
-- 3. GUARDAR
-- ----------------------------------------------------------------------------
-- Sin id crea, con id modifica. El fichero ya lo dejó el controlador en su
-- carpeta; aquí sólo entra su nombre.
CREATE OR REPLACE FUNCTION ecommerce.fn_categorias_imagenes_guardar(
    p_id bigint, p_categoria_id bigint, p_datos jsonb,
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
    PERFORM ecommerce.fn_contexto_auditoria('ecommerce.categorias_imagenes',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    IF NOT EXISTS (SELECT 1 FROM inventarios.categorias
                    WHERE id = p_categoria_id AND deleted_at IS NULL) THEN
        RAISE EXCEPTION 'La categoría no existe' USING ERRCODE = 'P0013';
    END IF;

    IF NOT v_nuevo AND NOT EXISTS (SELECT 1 FROM ecommerce.categorias_imagenes
                                    WHERE id = p_id AND categoria_id = p_categoria_id
                                      AND deleted_at IS NULL) THEN
        RAISE EXCEPTION 'La imagen no existe en esta categoría' USING ERRCODE = 'P0013';
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
        SELECT COALESCE(max(orden), 0) + 1 INTO v_orden FROM ecommerce.categorias_imagenes
         WHERE categoria_id = p_categoria_id AND deleted_at IS NULL;

        INSERT INTO ecommerce.categorias_imagenes
               (categoria_id, imagen, nombre, desde, hasta, orden, activo)
        VALUES (p_categoria_id, v_imagen,
                ecommerce.fn_validar_texto(p_datos ->> 'nombre', 'El nombre', 100),
                v_desde, v_hasta, v_orden,
                COALESCE((p_datos ->> 'activo')::boolean, true));
    ELSE
        UPDATE ecommerce.categorias_imagenes
           SET imagen = v_imagen,
               nombre = ecommerce.fn_validar_texto(p_datos ->> 'nombre', 'El nombre', 100),
               desde  = v_desde,
               hasta  = v_hasta,
               activo = COALESCE((p_datos ->> 'activo')::boolean, true)
         WHERE id = p_id;
    END IF;

    RETURN jsonb_build_object('success', true,
        'message', CASE WHEN v_nuevo THEN 'Imagen programada' ELSE 'Imagen guardada' END,
        'data', ecommerce.fn_categorias_imagenes_json(p_categoria_id));
END;
$function$;

-- ----------------------------------------------------------------------------
-- 4. ENCENDER, ORDENAR, BORRAR
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ecommerce.fn_categorias_imagenes_activar(
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
    v_categoria bigint;
    v_nuevo     boolean;
BEGIN
    PERFORM ecommerce.fn_contexto_auditoria('ecommerce.categorias_imagenes',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    SELECT categoria_id, COALESCE(p_activo, NOT activo) INTO v_categoria, v_nuevo
      FROM ecommerce.categorias_imagenes WHERE id = p_id AND deleted_at IS NULL;
    IF v_categoria IS NULL THEN
        RAISE EXCEPTION 'La imagen no existe' USING ERRCODE = 'P0013';
    END IF;

    UPDATE ecommerce.categorias_imagenes SET activo = v_nuevo WHERE id = p_id;

    RETURN jsonb_build_object('success', true,
        'message', CASE WHEN v_nuevo THEN 'Imagen encendida' ELSE 'Imagen apagada' END,
        'data', ecommerce.fn_categorias_imagenes_json(v_categoria));
END;
$function$;

-- El orden decide cuál sale cuando dos se pisan, así que llega entero y de
-- una sola categoría.
CREATE OR REPLACE FUNCTION ecommerce.fn_categorias_imagenes_ordenar(
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
    v_categoria bigint;
    v_cuantas   integer;
    v_recibido  integer;
BEGIN
    PERFORM ecommerce.fn_contexto_auditoria('ecommerce.categorias_imagenes',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    IF p_ids IS NULL OR jsonb_typeof(p_ids) <> 'array' OR jsonb_array_length(p_ids) = 0 THEN
        RAISE EXCEPTION 'Hace falta el orden de las imágenes' USING ERRCODE = 'P0001';
    END IF;

    SELECT count(DISTINCT i.categoria_id), count(*) INTO v_cuantas, v_recibido
      FROM ecommerce.categorias_imagenes i
     WHERE i.id IN (SELECT (x)::bigint FROM jsonb_array_elements_text(p_ids) x)
       AND i.deleted_at IS NULL;

    IF v_cuantas <> 1 OR v_recibido <> jsonb_array_length(p_ids) THEN
        RAISE EXCEPTION 'El orden no corresponde a una sola categoría' USING ERRCODE = 'P0016';
    END IF;

    SELECT DISTINCT categoria_id INTO v_categoria FROM ecommerce.categorias_imagenes
     WHERE id IN (SELECT (x)::bigint FROM jsonb_array_elements_text(p_ids) x);

    UPDATE ecommerce.categorias_imagenes i
       SET orden = n.pos
      FROM (SELECT (x.valor)::bigint AS id, x.pos
              FROM jsonb_array_elements_text(p_ids) WITH ORDINALITY AS x(valor, pos)) n
     WHERE i.id = n.id;

    RETURN jsonb_build_object('success', true, 'message', 'Orden guardado',
                              'data', ecommerce.fn_categorias_imagenes_json(v_categoria));
END;
$function$;

-- A la papelera. El fichero NO se borra aquí: si se restaura hay que poder
-- volver a verlo. Lo borra «vaciar», que es el único sitio del que no se
-- vuelve.
CREATE OR REPLACE FUNCTION ecommerce.fn_categorias_imagenes_eliminar(
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
    v_categoria bigint;
BEGIN
    PERFORM ecommerce.fn_contexto_auditoria('ecommerce.categorias_imagenes',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    SELECT categoria_id INTO v_categoria FROM ecommerce.categorias_imagenes
     WHERE id = p_id AND deleted_at IS NULL;
    IF v_categoria IS NULL THEN
        RAISE EXCEPTION 'La imagen no existe' USING ERRCODE = 'P0013';
    END IF;

    UPDATE ecommerce.categorias_imagenes
       SET deleted_at = CURRENT_TIMESTAMP,
           deleted_by = COALESCE(current_setting('app.usuario_login', true), current_user)
     WHERE id = p_id;

    RETURN jsonb_build_object('success', true, 'message', 'Imagen quitada',
                              'data', ecommerce.fn_categorias_imagenes_json(v_categoria));
END;
$function$;

-- ----------------------------------------------------------------------------
-- 5. LA PAPELERA, POR CATEGORÍA
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ecommerce.fn_categorias_imagenes_papelera(p_categoria_id bigint)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
AS $function$
    SELECT jsonb_build_object('success', true, 'message', 'Papelera de la categoría',
        'data', COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
                       'id', i.id, 'imagen', i.imagen, 'nombre', i.nombre,
                       'deleted_at', to_char(i.deleted_at, 'YYYY-MM-DD HH24:MI'),
                       'deleted_by', i.deleted_by)
                   ORDER BY i.deleted_at DESC)
              FROM ecommerce.categorias_imagenes i
             WHERE i.categoria_id = p_categoria_id AND i.deleted_at IS NOT NULL), '[]'::jsonb));
$function$;

CREATE OR REPLACE FUNCTION ecommerce.fn_categorias_imagenes_restaurar(
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
    v_categoria bigint;
    v_cuantas   integer;
    v_borradas  integer;
BEGIN
    PERFORM ecommerce.fn_contexto_auditoria('ecommerce.categorias_imagenes',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    IF p_ids IS NULL OR jsonb_typeof(p_ids) <> 'array' OR jsonb_array_length(p_ids) = 0 THEN
        RAISE EXCEPTION 'Hace falta decir qué imágenes restaurar' USING ERRCODE = 'P0001';
    END IF;

    SELECT count(DISTINCT i.categoria_id), count(*) INTO v_cuantas, v_borradas
      FROM ecommerce.categorias_imagenes i
     WHERE i.id IN (SELECT (x)::bigint FROM jsonb_array_elements_text(p_ids) x)
       AND i.deleted_at IS NOT NULL;

    IF v_borradas <> jsonb_array_length(p_ids) THEN
        RAISE EXCEPTION 'Alguna de esas imágenes no está en la papelera' USING ERRCODE = 'P0019';
    END IF;
    IF v_cuantas <> 1 THEN
        RAISE EXCEPTION 'Las imágenes tienen que ser de una sola categoría' USING ERRCODE = 'P0016';
    END IF;

    SELECT DISTINCT categoria_id INTO v_categoria FROM ecommerce.categorias_imagenes
     WHERE id IN (SELECT (x)::bigint FROM jsonb_array_elements_text(p_ids) x);

    UPDATE ecommerce.categorias_imagenes
       SET deleted_at = NULL, deleted_by = NULL,
           -- Vuelve al final: su sitio de antes ya lo ocupa otra
           orden = (SELECT COALESCE(max(x.orden), 0) FROM ecommerce.categorias_imagenes x
                     WHERE x.categoria_id = v_categoria AND x.deleted_at IS NULL) + 1
     WHERE id IN (SELECT (x)::bigint FROM jsonb_array_elements_text(p_ids) x);

    RETURN jsonb_build_object('success', true,
        'message', format('%s imagen(es) restaurada(s)', jsonb_array_length(p_ids)),
        'data', ecommerce.fn_categorias_imagenes_json(v_categoria));
END;
$function$;

-- Vacía la papelera DE ESTA CATEGORÍA y devuelve los ficheros que ya no usa
-- nadie, para que el controlador los borre del disco. Se comprueba que el
-- fichero no esté puesto en otra fila: la misma imagen puede estar
-- programada en dos categorías, y borrarla dejaría la otra rota.
CREATE OR REPLACE FUNCTION ecommerce.fn_categorias_imagenes_vaciar(
    p_categoria_id bigint,
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
    PERFORM ecommerce.fn_contexto_auditoria('ecommerce.categorias_imagenes',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    WITH borradas AS (
        DELETE FROM ecommerce.categorias_imagenes
         WHERE categoria_id = p_categoria_id AND deleted_at IS NOT NULL
        RETURNING imagen
    )
    SELECT COALESCE(jsonb_agg(DISTINCT b.imagen), '[]'::jsonb), count(*)
      INTO v_ficheros, v_cuantas
      FROM borradas b;

    -- Y de ésos, sólo los que ya no usa ninguna fila
    SELECT COALESCE(jsonb_agg(f.valor), '[]'::jsonb) INTO v_ficheros
      FROM jsonb_array_elements_text(v_ficheros) f(valor)
     WHERE NOT EXISTS (SELECT 1 FROM ecommerce.categorias_imagenes x WHERE x.imagen = f.valor);

    RETURN jsonb_build_object('success', true,
        'message', format('Papelera vaciada: %s imagen(es)', v_cuantas),
        'data', jsonb_build_object(
            'ficheros', v_ficheros,
            'categoria', ecommerce.fn_categorias_imagenes_json(p_categoria_id)));
END;
$function$;

-- ----------------------------------------------------------------------------
-- 6. LO QUE VE LA TIENDA
-- ----------------------------------------------------------------------------
-- Las categorías que están en la tienda Y tienen imagen vigente hoy, con esa
-- imagen. Programar una imagen es lo que mete la categoría en el mosaico de
-- la portada: no hace falta encenderla en otro sitio.
CREATE OR REPLACE FUNCTION ecommerce.fn_categorias_imagenes_publicas()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
AS $function$
    WITH visibles AS (
        SELECT e.id, e.nombre, e.orden FROM ecommerce.fn_categorias_web_estado() e
         WHERE e.estado = 'visible'
    ),
    mandona AS (
        SELECT DISTINCT ON (i.categoria_id) i.categoria_id, i.imagen
          FROM ecommerce.categorias_imagenes i
         WHERE i.deleted_at IS NULL AND i.activo
           AND ecommerce.fn_vigente(i.desde, i.hasta)
         ORDER BY i.categoria_id, i.orden, i.id
    )
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'id', v.id, 'nombre', v.nombre, 'imagen', m.imagen)
           ORDER BY v.orden, v.nombre), '[]'::jsonb)
      FROM visibles v
      JOIN mandona m ON m.categoria_id = v.id;
$function$;

-- ----------------------------------------------------------------------------
-- 7. QUE HAGA LO QUE DICE
-- ----------------------------------------------------------------------------
-- Todo se cuenta sin condiciones, para que un NULL no deje pasar la prueba en
-- verde. Lo que crea, lo borra.
DO $comprobar$
DECLARE
    v_cat     bigint;
    v_datos   jsonb;
    v_siempre bigint;
    v_navidad bigint;
    v_sale    text;
    v_fallo   text;
BEGIN
    SELECT id INTO v_cat FROM inventarios.categorias
     WHERE deleted_at IS NULL AND es_transaccion ORDER BY id LIMIT 1;
    IF v_cat IS NULL THEN
        RAISE EXCEPTION 'No hay ninguna categoría de producto con la que comprobar';
    END IF;

    -- Una dirección entera no entra
    v_fallo := NULL;
    BEGIN
        PERFORM ecommerce.fn_categorias_imagenes_guardar(NULL, v_cat,
            jsonb_build_object('imagen', 'http://192.168.2.173:8009/storage/img/ecommerce/x.png'));
    EXCEPTION WHEN SQLSTATE 'P0015' THEN v_fallo := 'bien';
    END;
    IF v_fallo IS NULL THEN
        RAISE EXCEPTION 'Se tragó una dirección entera donde va el nombre del fichero';
    END IF;

    -- Las fechas al revés tampoco
    v_fallo := NULL;
    BEGIN
        PERFORM ecommerce.fn_categorias_imagenes_guardar(NULL, v_cat,
            jsonb_build_object('imagen', 'zz-prueba.png',
                               'desde', '2026-12-26 00:00', 'hasta', '2026-12-01 00:00'));
    EXCEPTION WHEN SQLSTATE 'P0015' THEN v_fallo := 'bien';
    END;
    IF v_fallo IS NULL THEN
        RAISE EXCEPTION 'Se tragó un «hasta» anterior al «desde»';
    END IF;

    -- La de siempre, sin fechas
    v_datos := ecommerce.fn_categorias_imagenes_guardar(NULL, v_cat,
        jsonb_build_object('imagen', 'zz-siempre.png', 'nombre', 'ZZ la de siempre')) -> 'data';
    SELECT (i ->> 'id')::bigint INTO v_siempre
      FROM jsonb_array_elements(v_datos -> 'imagenes') i WHERE i ->> 'nombre' = 'ZZ la de siempre';

    SELECT i ->> 'nombre' INTO v_sale
      FROM jsonb_array_elements(v_datos -> 'imagenes') i WHERE (i ->> 'sale_ahora')::boolean;
    IF v_sale IS DISTINCT FROM 'ZZ la de siempre' THEN
        RAISE EXCEPTION 'Sin fechas tendría que salir ella, y sale «%»', COALESCE(v_sale, 'ninguna');
    END IF;

    -- Y una programada para dentro de un mes: NO sale todavía
    v_datos := ecommerce.fn_categorias_imagenes_guardar(NULL, v_cat,
        jsonb_build_object('imagen', 'zz-navidad.png', 'nombre', 'ZZ navidad',
                           'desde', to_char(CURRENT_TIMESTAMP + interval '30 days', 'YYYY-MM-DD HH24:MI'),
                           'hasta', to_char(CURRENT_TIMESTAMP + interval '60 days', 'YYYY-MM-DD HH24:MI'))) -> 'data';
    SELECT (i ->> 'id')::bigint INTO v_navidad
      FROM jsonb_array_elements(v_datos -> 'imagenes') i WHERE i ->> 'nombre' = 'ZZ navidad';

    SELECT i ->> 'nombre' INTO v_sale
      FROM jsonb_array_elements(v_datos -> 'imagenes') i WHERE (i ->> 'sale_ahora')::boolean;
    IF v_sale IS DISTINCT FROM 'ZZ la de siempre' THEN
        RAISE EXCEPTION 'La programada no debería salir todavía, y sale «%»', COALESCE(v_sale, 'ninguna');
    END IF;

    SELECT i ->> 'estado' INTO v_sale
      FROM jsonb_array_elements(v_datos -> 'imagenes') i WHERE (i ->> 'id')::bigint = v_navidad;
    IF v_sale IS DISTINCT FROM 'programada' THEN
        RAISE EXCEPTION 'La de navidad debería estar «programada» y está «%»', COALESCE(v_sale, 'nada');
    END IF;

    -- Apagar la de siempre deja a la categoría sin ninguna vigente
    v_datos := ecommerce.fn_categorias_imagenes_activar(v_siempre, false) -> 'data';
    IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_datos -> 'imagenes') i
                WHERE (i ->> 'sale_ahora')::boolean) THEN
        RAISE EXCEPTION 'Con la única vigente apagada no debería salir ninguna';
    END IF;

    -- Y entonces la categoría no sale en la tienda
    IF EXISTS (SELECT 1 FROM jsonb_array_elements(ecommerce.fn_categorias_imagenes_publicas()) c
                WHERE (c ->> 'id')::bigint = v_cat) THEN
        RAISE EXCEPTION 'Sin imagen vigente, la categoría no debería salir en la tienda';
    END IF;

    -- Limpieza: lo que creó la prueba se va del todo
    PERFORM ecommerce.fn_categorias_imagenes_eliminar(v_siempre);
    PERFORM ecommerce.fn_categorias_imagenes_eliminar(v_navidad);
    PERFORM ecommerce.fn_categorias_imagenes_vaciar(v_cat);

    IF EXISTS (SELECT 1 FROM ecommerce.categorias_imagenes WHERE categoria_id = v_cat) THEN
        RAISE EXCEPTION 'La prueba dejó filas detrás';
    END IF;

    RAISE NOTICE 'Comprobado: sin fechas sale, programada espera, apagada no sale, y no queda nada de la prueba.';
END
$comprobar$;

COMMIT;
