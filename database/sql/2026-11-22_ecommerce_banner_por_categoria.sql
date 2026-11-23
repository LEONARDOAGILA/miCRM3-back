-- ============================================================================
-- UN BANNER POR CATEGORÍA
-- ============================================================================
-- Cada categoría ya tenía sus IMÁGENES PROGRAMADAS: varias preparadas con sus
-- fechas —la de siempre, la de navidad— de las que la tienda enseña la que
-- toque hoy. Es la foto redonda de la portada y la de los mosaicos.
--
-- Ahora tiene ADEMÁS SUS BANNERS, con la misma maquinaria y en la misma tabla:
-- los mismos nombres, las mismas fechas, el mismo encendido y la misma
-- papelera. Lo que cambia es dónde salen: el banner se pinta ARRIBA DEL TODO
-- en /shop cuando se entra a esa categoría, antes del título.
--
-- LAS DOS LISTAS SE DISTINGUEN POR `tipo`:
--
--   'imagen'  la de siempre: el círculo de la portada y los mosaicos
--   'banner'  la nueva: la tira ancha de la página de la categoría
--
-- POR QUÉ LA MISMA TABLA Y NO UNA NUEVA: son el mismo dato con el mismo
-- comportamiento —un fichero, un nombre, unas fechas, un orden y un
-- encendido—, y diez funciones ya saben tratarlo. Una tabla gemela habría
-- sido diez funciones gemelas que se van separando en cuanto se toque una.
--
-- CUIDADO, Y ES LO QUE MÁS IMPORTA DE ESTE CAMBIO: las cinco funciones
-- públicas que sacaban «la imagen que manda» de esta tabla NO MIRABAN EL
-- TIPO, porque no había tipos. Sin el filtro, un banner con orden 1 se
-- convertiría en el círculo de la portada de esa categoría. Aquí abajo se
-- filtran las cinco.
--
-- SE HEREDA HACIA ARRIBA: una subcategoría sin banner propio enseña el de su
-- categoría, y ésa el de su departamento. Eso NO se resuelve aquí: la tienda
-- ya tiene el árbol entero en memoria y el camino hasta la categoría, así que
-- lo decide ella sin pedir nada. Lo que da la base es el banner de CADA
-- categoría, dentro del menú público.
--
-- ----------------------------------------------------------------------------
-- SE EJECUTA A MANO. Para ensayar: comentar el COMMIT y poner un ROLLBACK al
-- final del todo.
--
--   psql -U postgres -d crm3 -f 2026-11-22_ecommerce_banner_por_categoria.sql
-- ============================================================================

BEGIN;

-- ----------------------------------------------------------------------------
-- 1. LA COLUMNA
-- ----------------------------------------------------------------------------
-- Lo que ya está guardado es de la lista de siempre: 'imagen' por defecto, y
-- así ninguna fila cambia de sitio.
-- ----------------------------------------------------------------------------
ALTER TABLE ecommerce.categorias_imagenes
    ADD COLUMN IF NOT EXISTS tipo varchar(10) NOT NULL DEFAULT 'imagen';

ALTER TABLE ecommerce.categorias_imagenes
    DROP CONSTRAINT IF EXISTS categorias_imagenes_tipo_check;

ALTER TABLE ecommerce.categorias_imagenes
    ADD CONSTRAINT categorias_imagenes_tipo_check CHECK (tipo IN ('imagen', 'banner'));

COMMENT ON COLUMN ecommerce.categorias_imagenes.tipo IS
    'imagen = el círculo de la portada y los mosaicos; banner = la tira ancha de /shop de esa categoría.';

-- Las dos listas se piden por separado y siempre por categoría y tipo
CREATE INDEX IF NOT EXISTS categorias_imagenes_cat_tipo_idx
    ON ecommerce.categorias_imagenes (categoria_id, tipo)
 WHERE deleted_at IS NULL;


-- ----------------------------------------------------------------------------
-- 2. EL BANNER QUE TOCA HOY EN UNA CATEGORÍA
-- ----------------------------------------------------------------------------
-- Sólo el de ELLA: lo de heredar del padre lo hace la tienda con el árbol que
-- ya tiene. Aquí, el primero encendido y en fecha, por orden.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ecommerce.fn_categoria_banner(p_categoria_id bigint)
RETURNS text
LANGUAGE sql
STABLE
AS $function$
    SELECT i.imagen
      FROM ecommerce.categorias_imagenes i
     WHERE i.categoria_id = p_categoria_id
       AND i.tipo = 'banner'
       AND i.deleted_at IS NULL
       AND i.activo
       AND ecommerce.fn_vigente(i.desde, i.hasta)
     ORDER BY i.orden, i.id
     LIMIT 1;
$function$;


-- ----------------------------------------------------------------------------
-- 3. LAS DOS LISTAS, EN LAS FUNCIONES DE ADMINISTRACIÓN
-- ----------------------------------------------------------------------------
-- `p_tipo` lleva DEFAULT 'imagen' en todas: lo que no diga nada sigue
-- hablando de la lista de siempre. Las viejas se tiran antes de crear las
-- nuevas; si no, una llamada con los argumentos de antes queda ambigua.
-- ----------------------------------------------------------------------------
DROP FUNCTION IF EXISTS ecommerce.fn_categorias_imagenes_json(bigint);
DROP FUNCTION IF EXISTS ecommerce.fn_categorias_imagenes_listar(bigint);
DROP FUNCTION IF EXISTS ecommerce.fn_categorias_imagenes_papelera(bigint);
DROP FUNCTION IF EXISTS ecommerce.fn_categorias_imagenes_vaciar(bigint, bigint, varchar, varchar, inet, text, uuid);

CREATE OR REPLACE FUNCTION ecommerce.fn_categorias_imagenes_json(p_categoria_id bigint,
                                                                 p_tipo text DEFAULT 'imagen')
RETURNS jsonb
LANGUAGE sql
STABLE
AS $function$
    WITH vivas AS (
        SELECT i.*,
               (i.activo AND ecommerce.fn_vigente(i.desde, i.hasta)) AS vigente
          FROM ecommerce.categorias_imagenes i
         WHERE i.categoria_id = p_categoria_id
           AND i.tipo = p_tipo
           AND i.deleted_at IS NULL
    ),
    mandona AS (
        SELECT id FROM vivas WHERE vigente ORDER BY orden, id LIMIT 1
    )
    SELECT jsonb_build_object(
        'categoria_id', p_categoria_id,
        'tipo', p_tipo,
        'en_papelera', (SELECT count(*) FROM ecommerce.categorias_imagenes b
                         WHERE b.categoria_id = p_categoria_id AND b.tipo = p_tipo
                           AND b.deleted_at IS NOT NULL),
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


CREATE OR REPLACE FUNCTION ecommerce.fn_categorias_imagenes_listar(p_categoria_id bigint,
                                                                   p_tipo text DEFAULT 'imagen')
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'pg_catalog', 'ecommerce', 'auditoria'
AS $function$
DECLARE
    v_nombre text;
BEGIN
    IF p_tipo NOT IN ('imagen', 'banner') THEN
        RAISE EXCEPTION 'Esa lista de imágenes no existe' USING ERRCODE = 'P0015';
    END IF;

    SELECT nombre INTO v_nombre FROM inventarios.categorias
     WHERE id = p_categoria_id AND deleted_at IS NULL;
    IF v_nombre IS NULL THEN
        RAISE EXCEPTION 'La categoría no existe' USING ERRCODE = 'P0013';
    END IF;

    RETURN jsonb_build_object('success', true,
        'message', format('%s de «%s»',
                          CASE WHEN p_tipo = 'banner' THEN 'Banners' ELSE 'Imágenes' END, v_nombre),
        'data', ecommerce.fn_categorias_imagenes_json(p_categoria_id, p_tipo));
END;
$function$;


CREATE OR REPLACE FUNCTION ecommerce.fn_categorias_imagenes_papelera(p_categoria_id bigint,
                                                                     p_tipo text DEFAULT 'imagen')
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
             WHERE i.categoria_id = p_categoria_id
               AND i.tipo = p_tipo
               AND i.deleted_at IS NOT NULL), '[]'::jsonb));
$function$;


-- CADA LISTA TIENE SU PAPELERA: vaciar la de los banners no se lleva por
-- delante las imágenes borradas de la misma categoría.
CREATE OR REPLACE FUNCTION ecommerce.fn_categorias_imagenes_vaciar(p_categoria_id bigint,
                                                                   p_tipo text DEFAULT 'imagen',
                                                                   p_usuario_id bigint DEFAULT NULL::bigint,
                                                                   p_usuario_login character varying DEFAULT NULL::character varying,
                                                                   p_usuario_nombre character varying DEFAULT NULL::character varying,
                                                                   p_ip_address inet DEFAULT NULL::inet,
                                                                   p_user_agent text DEFAULT NULL::text,
                                                                   p_request_id uuid DEFAULT NULL::uuid)
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

    IF p_tipo NOT IN ('imagen', 'banner') THEN
        RAISE EXCEPTION 'Esa lista de imágenes no existe' USING ERRCODE = 'P0015';
    END IF;

    WITH borradas AS (
        DELETE FROM ecommerce.categorias_imagenes
         WHERE categoria_id = p_categoria_id AND tipo = p_tipo AND deleted_at IS NOT NULL
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
            'categoria', ecommerce.fn_categorias_imagenes_json(p_categoria_id, p_tipo)));
END;
$function$;


-- ----------------------------------------------------------------------------
-- 4. GUARDAR: EL TIPO VIAJA EN LOS DATOS
-- ----------------------------------------------------------------------------
-- Y SÓLO AL CREAR. Al modificar se respeta el que ya tenía: cambiarlo movería
-- la fila de lista sin decírselo a nadie, y el `orden` dejaría de tener
-- sentido en las dos.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ecommerce.fn_categorias_imagenes_guardar(p_id bigint,
                                                                    p_categoria_id bigint,
                                                                    p_datos jsonb,
                                                                    p_usuario_id bigint DEFAULT NULL::bigint,
                                                                    p_usuario_login character varying DEFAULT NULL::character varying,
                                                                    p_usuario_nombre character varying DEFAULT NULL::character varying,
                                                                    p_ip_address inet DEFAULT NULL::inet,
                                                                    p_user_agent text DEFAULT NULL::text,
                                                                    p_request_id uuid DEFAULT NULL::uuid)
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
    v_tipo   text;
    v_nuevo  boolean := p_id IS NULL;
BEGIN
    PERFORM ecommerce.fn_contexto_auditoria('ecommerce.categorias_imagenes',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    IF NOT EXISTS (SELECT 1 FROM inventarios.categorias
                    WHERE id = p_categoria_id AND deleted_at IS NULL) THEN
        RAISE EXCEPTION 'La categoría no existe' USING ERRCODE = 'P0013';
    END IF;

    IF v_nuevo THEN
        v_tipo := COALESCE(nullif(btrim(p_datos ->> 'tipo'), ''), 'imagen');
        IF v_tipo NOT IN ('imagen', 'banner') THEN
            RAISE EXCEPTION 'Esa lista de imágenes no existe' USING ERRCODE = 'P0015';
        END IF;
    ELSE
        SELECT tipo INTO v_tipo FROM ecommerce.categorias_imagenes
         WHERE id = p_id AND categoria_id = p_categoria_id AND deleted_at IS NULL;
        IF v_tipo IS NULL THEN
            RAISE EXCEPTION 'La imagen no existe en esta categoría' USING ERRCODE = 'P0013';
        END IF;
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
        -- EL ÚLTIMO DE SU LISTA, no de la categoría: las dos se ordenan aparte
        SELECT COALESCE(max(orden), 0) + 1 INTO v_orden FROM ecommerce.categorias_imagenes
         WHERE categoria_id = p_categoria_id AND tipo = v_tipo AND deleted_at IS NULL;

        INSERT INTO ecommerce.categorias_imagenes
               (categoria_id, tipo, imagen, nombre, desde, hasta, orden, activo)
        VALUES (p_categoria_id, v_tipo, v_imagen,
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
        'message', CASE
            WHEN v_nuevo AND v_tipo = 'banner' THEN 'Banner programado'
            WHEN v_nuevo THEN 'Imagen programada'
            WHEN v_tipo = 'banner' THEN 'Banner guardado'
            ELSE 'Imagen guardada' END,
        'data', ecommerce.fn_categorias_imagenes_json(p_categoria_id, v_tipo));
END;
$function$;


-- ----------------------------------------------------------------------------
-- 5. LAS QUE TRABAJAN POR ID: DEVUELVEN LA LISTA DE LA QUE TOCARON
-- ----------------------------------------------------------------------------
-- No les hace falta que les digan el tipo —lo trae la propia fila—, pero sí
-- devolver la lista correcta: con la de siempre, encender un banner dejaba la
-- pantalla pintando las imágenes.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ecommerce.fn_categorias_imagenes_activar(p_id bigint,
                                                                    p_activo boolean,
                                                                    p_usuario_id bigint DEFAULT NULL::bigint,
                                                                    p_usuario_login character varying DEFAULT NULL::character varying,
                                                                    p_usuario_nombre character varying DEFAULT NULL::character varying,
                                                                    p_ip_address inet DEFAULT NULL::inet,
                                                                    p_user_agent text DEFAULT NULL::text,
                                                                    p_request_id uuid DEFAULT NULL::uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'ecommerce', 'auditoria'
AS $function$
DECLARE
    v_categoria bigint;
    v_tipo      text;
    v_nuevo     boolean;
BEGIN
    PERFORM ecommerce.fn_contexto_auditoria('ecommerce.categorias_imagenes',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    SELECT categoria_id, tipo, COALESCE(p_activo, NOT activo)
      INTO v_categoria, v_tipo, v_nuevo
      FROM ecommerce.categorias_imagenes WHERE id = p_id AND deleted_at IS NULL;
    IF v_categoria IS NULL THEN
        RAISE EXCEPTION 'La imagen no existe' USING ERRCODE = 'P0013';
    END IF;

    UPDATE ecommerce.categorias_imagenes SET activo = v_nuevo WHERE id = p_id;

    RETURN jsonb_build_object('success', true,
        'message', CASE WHEN v_nuevo THEN 'Imagen encendida' ELSE 'Imagen apagada' END,
        'data', ecommerce.fn_categorias_imagenes_json(v_categoria, v_tipo));
END;
$function$;


CREATE OR REPLACE FUNCTION ecommerce.fn_categorias_imagenes_eliminar(p_id bigint,
                                                                     p_usuario_id bigint DEFAULT NULL::bigint,
                                                                     p_usuario_login character varying DEFAULT NULL::character varying,
                                                                     p_usuario_nombre character varying DEFAULT NULL::character varying,
                                                                     p_ip_address inet DEFAULT NULL::inet,
                                                                     p_user_agent text DEFAULT NULL::text,
                                                                     p_request_id uuid DEFAULT NULL::uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'ecommerce', 'auditoria'
AS $function$
DECLARE
    v_categoria bigint;
    v_tipo      text;
BEGIN
    PERFORM ecommerce.fn_contexto_auditoria('ecommerce.categorias_imagenes',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    SELECT categoria_id, tipo INTO v_categoria, v_tipo
      FROM ecommerce.categorias_imagenes
     WHERE id = p_id AND deleted_at IS NULL;
    IF v_categoria IS NULL THEN
        RAISE EXCEPTION 'La imagen no existe' USING ERRCODE = 'P0013';
    END IF;

    UPDATE ecommerce.categorias_imagenes
       SET deleted_at = CURRENT_TIMESTAMP,
           deleted_by = COALESCE(current_setting('app.usuario_login', true), current_user)
     WHERE id = p_id;

    RETURN jsonb_build_object('success', true, 'message', 'Imagen quitada',
                              'data', ecommerce.fn_categorias_imagenes_json(v_categoria, v_tipo));
END;
$function$;


-- Y EL ORDEN, QUE AHORA ES DE UNA LISTA: mezclar las dos en el mismo arrastre
-- dejaría las dos renumeradas a la vez y cada una con huecos.
CREATE OR REPLACE FUNCTION ecommerce.fn_categorias_imagenes_ordenar(p_ids jsonb,
                                                                    p_usuario_id bigint DEFAULT NULL::bigint,
                                                                    p_usuario_login character varying DEFAULT NULL::character varying,
                                                                    p_usuario_nombre character varying DEFAULT NULL::character varying,
                                                                    p_ip_address inet DEFAULT NULL::inet,
                                                                    p_user_agent text DEFAULT NULL::text,
                                                                    p_request_id uuid DEFAULT NULL::uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'ecommerce', 'auditoria'
AS $function$
DECLARE
    v_categoria bigint;
    v_tipo      text;
    v_cuantas   integer;
    v_tipos     integer;
    v_recibido  integer;
BEGIN
    PERFORM ecommerce.fn_contexto_auditoria('ecommerce.categorias_imagenes',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    IF p_ids IS NULL OR jsonb_typeof(p_ids) <> 'array' OR jsonb_array_length(p_ids) = 0 THEN
        RAISE EXCEPTION 'Hace falta el orden de las imágenes' USING ERRCODE = 'P0001';
    END IF;

    SELECT count(DISTINCT i.categoria_id), count(DISTINCT i.tipo), count(*)
      INTO v_cuantas, v_tipos, v_recibido
      FROM ecommerce.categorias_imagenes i
     WHERE i.id IN (SELECT (x)::bigint FROM jsonb_array_elements_text(p_ids) x)
       AND i.deleted_at IS NULL;

    IF v_cuantas <> 1 OR v_recibido <> jsonb_array_length(p_ids) THEN
        RAISE EXCEPTION 'El orden no corresponde a una sola categoría' USING ERRCODE = 'P0016';
    END IF;
    IF v_tipos <> 1 THEN
        RAISE EXCEPTION 'El orden mezcla imágenes y banners' USING ERRCODE = 'P0016';
    END IF;

    SELECT DISTINCT categoria_id, tipo INTO v_categoria, v_tipo
      FROM ecommerce.categorias_imagenes
     WHERE id IN (SELECT (x)::bigint FROM jsonb_array_elements_text(p_ids) x);

    UPDATE ecommerce.categorias_imagenes i
       SET orden = n.pos
      FROM (SELECT (x.valor)::bigint AS id, x.pos
              FROM jsonb_array_elements_text(p_ids) WITH ORDINALITY AS x(valor, pos)) n
     WHERE i.id = n.id;

    RETURN jsonb_build_object('success', true, 'message', 'Orden guardado',
                              'data', ecommerce.fn_categorias_imagenes_json(v_categoria, v_tipo));
END;
$function$;


CREATE OR REPLACE FUNCTION ecommerce.fn_categorias_imagenes_restaurar(p_ids jsonb,
                                                                      p_usuario_id bigint DEFAULT NULL::bigint,
                                                                      p_usuario_login character varying DEFAULT NULL::character varying,
                                                                      p_usuario_nombre character varying DEFAULT NULL::character varying,
                                                                      p_ip_address inet DEFAULT NULL::inet,
                                                                      p_user_agent text DEFAULT NULL::text,
                                                                      p_request_id uuid DEFAULT NULL::uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'ecommerce', 'auditoria'
AS $function$
DECLARE
    v_categoria bigint;
    v_tipo      text;
    v_cuantas   integer;
    v_tipos     integer;
    v_borradas  integer;
BEGIN
    PERFORM ecommerce.fn_contexto_auditoria('ecommerce.categorias_imagenes',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    IF p_ids IS NULL OR jsonb_typeof(p_ids) <> 'array' OR jsonb_array_length(p_ids) = 0 THEN
        RAISE EXCEPTION 'Hace falta decir qué imágenes restaurar' USING ERRCODE = 'P0001';
    END IF;

    SELECT count(DISTINCT i.categoria_id), count(DISTINCT i.tipo), count(*)
      INTO v_cuantas, v_tipos, v_borradas
      FROM ecommerce.categorias_imagenes i
     WHERE i.id IN (SELECT (x)::bigint FROM jsonb_array_elements_text(p_ids) x)
       AND i.deleted_at IS NOT NULL;

    IF v_borradas <> jsonb_array_length(p_ids) THEN
        RAISE EXCEPTION 'Alguna de esas imágenes no está en la papelera' USING ERRCODE = 'P0019';
    END IF;
    IF v_cuantas <> 1 THEN
        RAISE EXCEPTION 'Las imágenes tienen que ser de una sola categoría' USING ERRCODE = 'P0016';
    END IF;
    IF v_tipos <> 1 THEN
        RAISE EXCEPTION 'No se pueden restaurar imágenes y banners a la vez' USING ERRCODE = 'P0016';
    END IF;

    SELECT DISTINCT categoria_id, tipo INTO v_categoria, v_tipo
      FROM ecommerce.categorias_imagenes
     WHERE id IN (SELECT (x)::bigint FROM jsonb_array_elements_text(p_ids) x);

    UPDATE ecommerce.categorias_imagenes
       SET deleted_at = NULL, deleted_by = NULL,
           -- Vuelve al final DE SU LISTA: su sitio de antes ya lo ocupa otra
           orden = (SELECT COALESCE(max(x.orden), 0) FROM ecommerce.categorias_imagenes x
                     WHERE x.categoria_id = v_categoria AND x.tipo = v_tipo
                       AND x.deleted_at IS NULL) + 1
     WHERE id IN (SELECT (x)::bigint FROM jsonb_array_elements_text(p_ids) x);

    RETURN jsonb_build_object('success', true,
        'message', format('%s imagen(es) restaurada(s)', jsonb_array_length(p_ids)),
        'data', ecommerce.fn_categorias_imagenes_json(v_categoria, v_tipo));
END;
$function$;


-- ----------------------------------------------------------------------------
-- 6. LAS CHAPITAS DEL ÁRBOL: UNA CUENTA POR LISTA
-- ----------------------------------------------------------------------------
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
                       'sale_alguna',  x.sale_alguna,
                       'banners',      x.banners,
                       'sale_banner',  x.sale_banner))
              FROM (SELECT i.categoria_id,
                           count(*) FILTER (WHERE i.tipo = 'imagen') AS cuantas,
                           COALESCE(bool_or(i.activo AND ecommerce.fn_vigente(i.desde, i.hasta))
                                    FILTER (WHERE i.tipo = 'imagen'), false) AS sale_alguna,
                           count(*) FILTER (WHERE i.tipo = 'banner') AS banners,
                           COALESCE(bool_or(i.activo AND ecommerce.fn_vigente(i.desde, i.hasta))
                                    FILTER (WHERE i.tipo = 'banner'), false) AS sale_banner
                      FROM ecommerce.categorias_imagenes i
                     WHERE i.deleted_at IS NULL
                     GROUP BY i.categoria_id) x), '[]'::jsonb));
$function$;


-- ----------------------------------------------------------------------------
-- 7. LAS CINCO PÚBLICAS QUE YA LEÍAN ESTA TABLA
-- ----------------------------------------------------------------------------
-- Salen tal cual de la base con el filtro del tipo añadido.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ecommerce.fn_categorias_destacadas_publicas()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
AS $function$
    WITH destacadas AS (
        SELECT e.id, e.nombre, e.orden, e.destacada_orden
          FROM ecommerce.fn_categorias_web_estado() e
         WHERE e.estado = 'visible' AND e.destacada
    ),
    mandona AS (
        SELECT DISTINCT ON (i.categoria_id) i.categoria_id, i.imagen
          FROM ecommerce.categorias_imagenes i
         WHERE i.deleted_at IS NULL AND i.activo
           -- LA DE SIEMPRE Y NO UN BANNER: desde el 22/11/2026 la misma tabla
           -- guarda los dos, y sin esto el banner de una categoría podría
           -- acabar de círculo en la portada
           AND i.tipo = 'imagen'
           AND ecommerce.fn_vigente(i.desde, i.hasta)
         ORDER BY i.categoria_id, i.orden, i.id
    )
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'id', d.id, 'nombre', d.nombre, 'imagen', m.imagen,
               -- Su página si la tiene; si no, el catálogo filtrado de siempre
               'enlace', COALESCE(ecommerce.fn_cuerpo_de_categoria(d.id), '/shop?categoria=' || d.id))
           ORDER BY d.destacada_orden NULLS LAST, d.orden, d.nombre), '[]'::jsonb)
      FROM destacadas d
      LEFT JOIN mandona m ON m.categoria_id = d.id;
$function$;

CREATE OR REPLACE FUNCTION ecommerce.fn_categorias_hijas_publicas(p_padre_id bigint)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
AS $function$
    WITH hijas AS (
        SELECT e.id, e.nombre, e.orden
          FROM ecommerce.fn_categorias_web_estado() e
         WHERE e.estado = 'visible' AND e.padre_id = p_padre_id
    ),
    mandona AS (
        SELECT DISTINCT ON (i.categoria_id) i.categoria_id, i.imagen
          FROM ecommerce.categorias_imagenes i
         WHERE i.deleted_at IS NULL AND i.activo
           -- LA DE SIEMPRE Y NO UN BANNER: desde el 22/11/2026 la misma tabla
           -- guarda los dos, y sin esto el banner de una categoría podría
           -- acabar de círculo en la portada
           AND i.tipo = 'imagen'
           AND ecommerce.fn_vigente(i.desde, i.hasta)
         ORDER BY i.categoria_id, i.orden, i.id
    )
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'id', h.id, 'nombre', h.nombre, 'imagen', m.imagen,
               'enlace', COALESCE(ecommerce.fn_cuerpo_de_categoria(h.id), '/shop?categoria=' || h.id))
           ORDER BY h.orden, h.nombre), '[]'::jsonb)
      FROM hijas h
      LEFT JOIN mandona m ON m.categoria_id = h.id;
$function$;

CREATE OR REPLACE FUNCTION ecommerce.fn_categorias_promocion_publicas()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
AS $function$
    WITH enPromocion AS (
        SELECT e.id, e.nombre, e.orden, e.promocion_orden
          FROM ecommerce.fn_categorias_web_estado() e
         WHERE e.estado = 'visible' AND e.promocion
    ),
    mandona AS (
        SELECT DISTINCT ON (i.categoria_id) i.categoria_id, i.imagen
          FROM ecommerce.categorias_imagenes i
         WHERE i.deleted_at IS NULL AND i.activo
           -- LA DE SIEMPRE Y NO UN BANNER: desde el 22/11/2026 la misma tabla
           -- guarda los dos, y sin esto el banner de una categoría podría
           -- acabar de círculo en la portada
           AND i.tipo = 'imagen'
           AND ecommerce.fn_vigente(i.desde, i.hasta)
         ORDER BY i.categoria_id, i.orden, i.id
    )
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'id', p.id, 'nombre', p.nombre, 'imagen', m.imagen,
               'enlace', COALESCE(ecommerce.fn_cuerpo_de_categoria(p.id), '/shop?categoria=' || p.id))
           ORDER BY p.promocion_orden NULLS LAST, p.orden, p.nombre), '[]'::jsonb)
      FROM enPromocion p
      LEFT JOIN mandona m ON m.categoria_id = p.id;
$function$;

CREATE OR REPLACE FUNCTION ecommerce.fn_categorias_promocion_hijas_publicas(p_padre_id bigint)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
AS $function$
    WITH hijas AS (
        SELECT e.id, e.nombre, e.orden, e.promocion_orden
          FROM ecommerce.fn_categorias_web_estado() e
         WHERE e.estado = 'visible' AND e.promocion AND e.padre_id = p_padre_id
    ),
    mandona AS (
        SELECT DISTINCT ON (i.categoria_id) i.categoria_id, i.imagen
          FROM ecommerce.categorias_imagenes i
         WHERE i.deleted_at IS NULL AND i.activo
           -- LA DE SIEMPRE Y NO UN BANNER: desde el 22/11/2026 la misma tabla
           -- guarda los dos, y sin esto el banner de una categoría podría
           -- acabar de círculo en la portada
           AND i.tipo = 'imagen'
           AND ecommerce.fn_vigente(i.desde, i.hasta)
         ORDER BY i.categoria_id, i.orden, i.id
    )
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'id', h.id, 'nombre', h.nombre, 'imagen', m.imagen,
               'enlace', COALESCE(ecommerce.fn_cuerpo_de_categoria(h.id), '/shop?categoria=' || h.id))
           ORDER BY h.promocion_orden NULLS LAST, h.orden, h.nombre), '[]'::jsonb)
      FROM hijas h
      LEFT JOIN mandona m ON m.categoria_id = h.id;
$function$;

CREATE OR REPLACE FUNCTION ecommerce.fn_categorias_de_marca_publicas(p_marca_id bigint)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
AS $function$
    WITH suyas AS (
        SELECT e.id, e.nombre, e.orden
          FROM ecommerce.fn_categorias_web_estado() e
         WHERE e.estado = 'visible'
           AND EXISTS (SELECT 1 FROM inventarios.productos p
                        WHERE p.marca_id = p_marca_id AND p.deleted_at IS NULL AND p.activo AND p.en_paginaweb
                          AND p.categoria_id = e.id)
    ),
    mandona AS (
        SELECT DISTINCT ON (i.categoria_id) i.categoria_id, i.imagen
          FROM ecommerce.categorias_imagenes i
         WHERE i.deleted_at IS NULL AND i.activo
           -- LA DE SIEMPRE Y NO UN BANNER: desde el 22/11/2026 la misma tabla
           -- guarda los dos, y sin esto el banner de una categoría podría
           -- acabar de círculo en la portada
           AND i.tipo = 'imagen'
           AND ecommerce.fn_vigente(i.desde, i.hasta)
         ORDER BY i.categoria_id, i.orden, i.id
    )
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'id', s.id, 'nombre', s.nombre, 'imagen', m.imagen,
               -- Con la marca puesta: se está mirando una página de marca, y
               -- su categoría sin esa marca enseñaría cosas de otras
               'enlace', COALESCE(ecommerce.fn_cuerpo_de_categoria(s.id),
                                  '/shop?categoria=' || s.id || '&marca=' || p_marca_id))
           ORDER BY s.orden, s.nombre), '[]'::jsonb)
      FROM suyas s
      LEFT JOIN mandona m ON m.categoria_id = s.id;
$function$;

-- ----------------------------------------------------------------------------
-- 8. Y EL MENÚ PÚBLICO, QUE ES POR DONDE VIAJA EL BANNER
-- ----------------------------------------------------------------------------
-- La tienda ya pide este árbol al abrir cualquier página y ya sabe el camino
-- hasta la categoría que se está mirando (la miga de pan sale de aquí). Con
-- el banner dentro, enseñarlo no cuesta ni una petición más, y heredar del
-- padre es mirar el camino de atrás hacia delante.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ecommerce.fn_categorias_web_menu_publico()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
AS $function$
    WITH v AS (
        -- El icono de cada categoría viene de su ficha de inventarios, que es
        -- donde se elige, y sale YA DIBUJADO: la tienda no tiene la fuente de
        -- iconos y no la va a tener (ver ecommerce.iconos_fa)
        SELECT e.*, ecommerce.fn_icono_fa(c.icono) AS icono
          FROM ecommerce.fn_categorias_web_estado() e
          JOIN inventarios.categorias c ON c.id = e.id
         WHERE e.estado = 'visible'
    )
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'id', d.id, 'nombre', d.nombre, 'icono', d.icono,
               'banner', ecommerce.fn_categoria_banner(d.id),
               'enlace', COALESCE(ecommerce.fn_cuerpo_de_categoria(d.id), '/shop?categoria=' || d.id),
               'hijos', COALESCE((
                   SELECT jsonb_agg(jsonb_build_object(
                              'id', c.id, 'nombre', c.nombre, 'icono', c.icono,
                              'banner', ecommerce.fn_categoria_banner(c.id),
                              'enlace', COALESCE(ecommerce.fn_cuerpo_de_categoria(c.id), '/shop?categoria=' || c.id),
                              'hijos', COALESCE((
                                  SELECT jsonb_agg(jsonb_build_object('id', s.id, 'nombre', s.nombre, 'icono', s.icono,
                                             'banner', ecommerce.fn_categoria_banner(s.id),
                                             'enlace', COALESCE(ecommerce.fn_cuerpo_de_categoria(s.id), '/shop?categoria=' || s.id),
                                             'hijos', '[]'::jsonb)
                                         ORDER BY s.orden_web NULLS LAST, s.orden, s.nombre)
                                    FROM v s WHERE s.padre_id = c.id), '[]'::jsonb))
                          ORDER BY c.orden_web NULLS LAST, c.orden, c.nombre)
                     FROM v c WHERE c.padre_id = d.id), '[]'::jsonb))
           ORDER BY d.orden_web NULLS LAST, d.orden, d.nombre), '[]'::jsonb)
      FROM v d
     WHERE d.padre_id IS NULL;
$function$;


-- ----------------------------------------------------------------------------
-- COMPROBACIÓN
-- ----------------------------------------------------------------------------
DO $comprobar$
DECLARE
    v_falta   text[] := ARRAY[]::text[];
    v_cat     bigint;
    v_img     bigint;
    v_ban     bigint;
    v_json    jsonb;
BEGIN
    -- Una categoría cualquiera que esté viva
    SELECT id INTO v_cat FROM inventarios.categorias WHERE deleted_at IS NULL ORDER BY id LIMIT 1;
    IF v_cat IS NULL THEN
        RAISE EXCEPTION 'No hay ninguna categoría con la que comprobar';
    END IF;

    -- Una imagen de las de siempre y un banner, en la misma categoría.
    --
    -- LA FILA SEMBRADA SE BUSCA POR SU FICHERO y no por «la primera de la
    -- lista»: esa categoría puede tener ya imágenes de alguien, y la
    -- primera por orden sería la suya. Cogiéndola por posición, la limpieza
    -- del final borraba una fila ajena; pasó el 22/11/2026 con la id 5.
    -- Los ficheros de verdad los nombra el servidor con cuarenta caracteres
    -- al azar, así que estos dos nombres no pueden ser de nadie más.
    PERFORM ecommerce.fn_categorias_imagenes_guardar(NULL, v_cat,
                 jsonb_build_object('imagen', 'zz-prueba-imagen.jpg', 'nombre', 'ZZ imagen'));
    SELECT id INTO v_img FROM ecommerce.categorias_imagenes
     WHERE categoria_id = v_cat AND imagen = 'zz-prueba-imagen.jpg';

    v_json := ecommerce.fn_categorias_imagenes_guardar(NULL, v_cat,
                  jsonb_build_object('imagen', 'zz-prueba-banner.jpg', 'nombre', 'ZZ banner',
                                     'tipo', 'banner'));
    SELECT id INTO v_ban FROM ecommerce.categorias_imagenes
     WHERE categoria_id = v_cat AND imagen = 'zz-prueba-banner.jpg';

    IF v_img IS NULL OR v_ban IS NULL THEN
        RAISE EXCEPTION 'No se pudieron sembrar las filas de prueba';
    END IF;

    IF (v_json #>> '{data,tipo}') IS DISTINCT FROM 'banner' THEN
        v_falta := array_append(v_falta, 'guardar un banner devuelve la lista de las imágenes');
    END IF;

    -- CADA LISTA, LA SUYA
    IF (SELECT count(*) FROM jsonb_array_elements(
            ecommerce.fn_categorias_imagenes_json(v_cat, 'banner') -> 'imagenes') e
         WHERE (e ->> 'id')::bigint = v_img) > 0 THEN
        v_falta := array_append(v_falta, 'la imagen de siempre aparece entre los banners');
    END IF;
    IF (SELECT count(*) FROM jsonb_array_elements(
            ecommerce.fn_categorias_imagenes_json(v_cat) -> 'imagenes') e
         WHERE (e ->> 'id')::bigint = v_ban) > 0 THEN
        v_falta := array_append(v_falta, 'el banner aparece entre las imágenes de siempre');
    END IF;

    -- El banner se ve desde el menú público. (Si esa categoría ya tenía uno
    -- de verdad con mejor orden, mandaría el suyo: por eso el sembrado va al
    -- final y esto mira que salga ALGUNO.)
    IF ecommerce.fn_categoria_banner(v_cat) IS DISTINCT FROM (
           SELECT i.imagen FROM ecommerce.categorias_imagenes i
            WHERE i.categoria_id = v_cat AND i.tipo = 'banner'
              AND i.deleted_at IS NULL AND i.activo
              AND ecommerce.fn_vigente(i.desde, i.hasta)
            ORDER BY i.orden, i.id LIMIT 1) THEN
        v_falta := array_append(v_falta, 'fn_categoria_banner no elige el que toca');
    END IF;

    -- Y NO SE CUELA DE CÍRCULO: lo que mandan las públicas sigue siendo la imagen
    IF EXISTS (SELECT 1 FROM ecommerce.categorias_imagenes i
                WHERE i.id = v_ban AND i.tipo <> 'banner') THEN
        v_falta := array_append(v_falta, 'el banner no se guardó como banner');
    END IF;

    -- Apagar el banner lo quita del menú, y no toca a la imagen
    -- APAGADO NO SALE. Se mira que no salga EL SEMBRADO y no que no salga
    -- ninguno: la categoria puede tener otros banners de verdad.
    PERFORM ecommerce.fn_categorias_imagenes_activar(v_ban, false);
    IF ecommerce.fn_categoria_banner(v_cat) = 'zz-prueba-banner.jpg' THEN
        v_falta := array_append(v_falta, 'un banner apagado sigue saliendo');
    END IF;
    IF NOT (SELECT activo FROM ecommerce.categorias_imagenes WHERE id = v_img) THEN
        v_falta := array_append(v_falta, 'apagar el banner apagó también la imagen');
    END IF;

    -- Las cuentas del árbol los separan: los banners se cuentan aparte de
    -- las imágenes, y las dos cuentas tienen que cuadrar con la tabla
    IF (SELECT (e ->> 'banners')::int
          FROM jsonb_array_elements(ecommerce.fn_categorias_imagenes_cuentas() -> 'data') e
         WHERE (e ->> 'categoria_id')::bigint = v_cat)
       IS DISTINCT FROM (SELECT count(*)::int FROM ecommerce.categorias_imagenes
                          WHERE categoria_id = v_cat AND tipo = 'banner' AND deleted_at IS NULL) THEN
        v_falta := array_append(v_falta, 'las cuentas no separan los banners');
    END IF;

    -- LO SEMBRADO, FUERA, Y SÓLO LO SEMBRADO: por el nombre del fichero, que
    -- es de esta comprobación y de nadie más
    DELETE FROM ecommerce.categorias_imagenes
     WHERE categoria_id = v_cat
       AND imagen IN ('zz-prueba-imagen.jpg', 'zz-prueba-banner.jpg');

    IF array_length(v_falta, 1) IS NULL THEN
        RAISE NOTICE 'Comprobado: las dos listas van cada una por su lado, el banner llega al menú público, apagarlo lo quita y las cuentas los separan';
    ELSE
        RAISE EXCEPTION 'FALTA: %', array_to_string(v_falta, ' | ');
    END IF;
END
$comprobar$;

COMMIT;
