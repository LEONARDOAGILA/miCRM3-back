-- ============================================================================
-- EL BANNER DE UNA CATEGORÍA: ENLACE, SEGUNDOS Y VARIOS QUE SE TURNAN
-- ============================================================================
-- El 22/11/2026 por la mañana cada categoría pasó a tener sus banners, pero
-- se quedaron a medias de lo que ya hacen los banners del inicio:
--
--   1. SE TURNAN. Antes salía uno solo —el primero en fecha, como la imagen
--      del círculo—. Ahora salen TODOS los que estén encendidos y en fecha,
--      uno detrás de otro, que es lo que hace app-banner-rotativo en el
--      inicio y en las páginas de marca.
--
--   2. CADA UNO LLEVA SU ENLACE, con su «abrir en otra pestaña» decidido por
--      el servidor según la dirección (fn_nueva_pestana), igual que las
--      imágenes de una galería.
--
--   3. Y LA CATEGORÍA DICE CADA CUÁNTOS SEGUNDOS cambian: de 2 a 60, el
--      mismo rango que los demás banners. Vacío es el ritmo de siempre.
--
-- EL ENLACE Y LOS SEGUNDOS SON DE LOS BANNERS, no de las imágenes de
-- siempre: el círculo de la portada ya lleva a su categoría y no se turna
-- con nadie. La columna es la misma para las dos listas porque la tabla es
-- la misma; lo que no se usa se queda en NULL.
--
-- ----------------------------------------------------------------------------
-- SE EJECUTA A MANO. Para ensayar: comentar el COMMIT y poner un ROLLBACK al
-- final del todo.
--
--   psql -U postgres -d crm3 -f 2026-11-22_ecommerce_banner_categoria_enlace_y_segundos.sql
-- ============================================================================

BEGIN;

-- ----------------------------------------------------------------------------
-- 1. LAS COLUMNAS
-- ----------------------------------------------------------------------------
ALTER TABLE ecommerce.categorias_imagenes
    ADD COLUMN IF NOT EXISTS enlace varchar(250);

ALTER TABLE ecommerce.categorias_imagenes
    ADD COLUMN IF NOT EXISTS nueva_pestana boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN ecommerce.categorias_imagenes.enlace IS
    'A dónde lleva el banner al pulsarlo. Sólo lo usan los de tipo «banner»; NULL = no lleva a ninguna parte.';
COMMENT ON COLUMN ecommerce.categorias_imagenes.nueva_pestana IS
    'Si ese enlace abre otra pestaña. Lo decide el servidor por la dirección (fn_nueva_pestana).';

ALTER TABLE ecommerce.categorias_web
    ADD COLUMN IF NOT EXISTS banner_segundos smallint;

ALTER TABLE ecommerce.categorias_web
    DROP CONSTRAINT IF EXISTS categorias_web_banner_segundos_check;

ALTER TABLE ecommerce.categorias_web
    ADD CONSTRAINT categorias_web_banner_segundos_check
    CHECK (banner_segundos IS NULL OR banner_segundos BETWEEN 2 AND 60);

COMMENT ON COLUMN ecommerce.categorias_web.banner_segundos IS
    'Cada cuántos segundos cambia el banner de esta categoría (2 a 60). NULL = el ritmo de siempre de la tienda.';


-- ----------------------------------------------------------------------------
-- 2. LO QUE LA TIENDA RECIBE DE CADA CATEGORÍA
-- ----------------------------------------------------------------------------
-- DEVUELVE TODOS LOS QUE TOCAN HOY, no el primero: la tienda los va pasando.
-- Y con ellos, cada cuántos segundos. Sin banners devuelve NULL, que es lo
-- que la tienda lee como «esta categoría no tiene».
--
-- La vigencia la decide fn_vigente, igual que en la lista de siempre.
-- ----------------------------------------------------------------------------
DROP FUNCTION IF EXISTS ecommerce.fn_categoria_banner(bigint);

CREATE OR REPLACE FUNCTION ecommerce.fn_categoria_banner(p_categoria_id bigint)
RETURNS jsonb
LANGUAGE sql
STABLE
AS $function$
    SELECT CASE WHEN x.imagenes IS NULL THEN NULL ELSE jsonb_build_object(
               'segundos', (SELECT banner_segundos FROM ecommerce.categorias_web
                             WHERE categoria_id = p_categoria_id),
               'imagenes', x.imagenes) END
      FROM (SELECT jsonb_agg(jsonb_build_object(
                       'imagen',        i.imagen,
                       'nombre',        COALESCE(i.nombre, ''),
                       'enlace',        i.enlace,
                       'nueva_pestana', i.nueva_pestana)
                   ORDER BY i.orden, i.id) AS imagenes
              FROM ecommerce.categorias_imagenes i
             WHERE i.categoria_id = p_categoria_id
               AND i.tipo = 'banner'
               AND i.deleted_at IS NULL
               AND i.activo
               AND ecommerce.fn_vigente(i.desde, i.hasta)) x;
$function$;


-- ----------------------------------------------------------------------------
-- 3. GUARDAR UN BANNER: SU ENLACE
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
    v_enlace text;
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

    -- EL ENLACE ES SÓLO DE LOS BANNERS. En una imagen de las de siempre no se
    -- guarda aunque llegue: el círculo de la portada ya lleva a su categoría,
    -- y un enlace ahí sería un ajuste que no hace nada.
    v_enlace := CASE WHEN v_tipo = 'banner'
                     THEN ecommerce.fn_validar_enlace(p_datos ->> 'enlace', 'El enlace del banner')
                     ELSE NULL END;

    IF v_nuevo THEN
        SELECT COALESCE(max(orden), 0) + 1 INTO v_orden FROM ecommerce.categorias_imagenes
         WHERE categoria_id = p_categoria_id AND tipo = v_tipo AND deleted_at IS NULL;

        INSERT INTO ecommerce.categorias_imagenes
               (categoria_id, tipo, imagen, nombre, desde, hasta, orden, activo,
                enlace, nueva_pestana)
        VALUES (p_categoria_id, v_tipo, v_imagen,
                ecommerce.fn_validar_texto(p_datos ->> 'nombre', 'El nombre', 100),
                v_desde, v_hasta, v_orden,
                COALESCE((p_datos ->> 'activo')::boolean, true),
                v_enlace,
                ecommerce.fn_nueva_pestana(v_enlace, (p_datos ->> 'nueva_pestana')::boolean));
    ELSE
        UPDATE ecommerce.categorias_imagenes
           SET imagen = v_imagen,
               nombre = ecommerce.fn_validar_texto(p_datos ->> 'nombre', 'El nombre', 100),
               desde  = v_desde,
               hasta  = v_hasta,
               activo = COALESCE((p_datos ->> 'activo')::boolean, true),
               enlace = v_enlace,
               nueva_pestana = ecommerce.fn_nueva_pestana(v_enlace, (p_datos ->> 'nueva_pestana')::boolean)
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
-- 4. LA LISTA DE ADMINISTRACIÓN, CON EL ENLACE DE CADA UNO
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ecommerce.fn_categorias_imagenes_json(p_categoria_id bigint, p_tipo text DEFAULT 'imagen'::text)
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
                       -- El enlace es de los BANNERS: una imagen de círculo ya
                       -- lleva a su categoría, y ahí no se elige
                       'enlace',        v.enlace,
                       'nueva_pestana', v.nueva_pestana,
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


-- ----------------------------------------------------------------------------
-- 5. LA CATEGORÍA GUARDA SUS SEGUNDOS
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ecommerce.fn_categorias_web_guardar(p_categoria_id bigint, p_oculta boolean, p_nombre_web character varying, p_usuario_id bigint DEFAULT NULL::bigint, p_usuario_login character varying DEFAULT NULL::character varying, p_usuario_nombre character varying DEFAULT NULL::character varying, p_ip_address inet DEFAULT NULL::inet, p_user_agent text DEFAULT NULL::text, p_request_id uuid DEFAULT NULL::uuid, p_destacada boolean DEFAULT NULL::boolean, p_promocion boolean DEFAULT NULL::boolean, p_banner_segundos smallint DEFAULT NULL::smallint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'ecommerce', 'auditoria'
AS $function$
DECLARE
    v_nombre    text;
    v_oculta    boolean := COALESCE(p_oculta, false);
    v_destacada boolean;
    v_promocion boolean;
    v_catalogo  text;
    v_segundos  smallint;
BEGIN
    PERFORM ecommerce.fn_contexto_auditoria('ecommerce.categorias_web',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    SELECT nombre INTO v_catalogo FROM inventarios.categorias
     WHERE id = p_categoria_id AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'La categoría no existe' USING ERRCODE = 'P0013';
    END IF;

    -- Sin decir nada, se quedan como estaban: así quien sólo cambia el
    -- nombre no desmarca la categoría sin querer.
    v_destacada := COALESCE(p_destacada,
                            (SELECT destacada FROM ecommerce.categorias_web
                              WHERE categoria_id = p_categoria_id), false);
    v_promocion := COALESCE(p_promocion,
                            (SELECT promocion FROM ecommerce.categorias_web
                              WHERE categoria_id = p_categoria_id), false);

    -- LOS SEGUNDOS DEL BANNER, con el mismo rango que los demás banners de
    -- la tienda (2 a 60). Sin decir nada se quedan como estaban, igual que
    -- las dos marcas: quien sólo cambia el nombre no los borra.
    --
    -- Y UN CERO LOS VACÍA, que es lo que manda la pantalla cuando se borra
    -- la caja: con NULL no se podría: NULL es «no dije nada».
    IF p_banner_segundos = 0 THEN
        v_segundos := NULL;
    ELSE
        v_segundos := COALESCE(p_banner_segundos,
                               (SELECT banner_segundos FROM ecommerce.categorias_web
                                 WHERE categoria_id = p_categoria_id));
    END IF;
    IF v_segundos IS NOT NULL AND (v_segundos < 2 OR v_segundos > 60) THEN
        RAISE EXCEPTION 'Los segundos del banner van de 2 a 60' USING ERRCODE = 'P0015';
    END IF;

    v_nombre := ecommerce.fn_validar_texto(p_nombre_web, 'El nombre para la tienda', 80);

    -- El mismo nombre del catálogo no es «otro nombre»: se guarda como nada,
    -- para que al renombrar la categoría en Inventarios la tienda la siga.
    IF v_nombre IS NOT NULL AND lower(btrim(v_nombre)) = lower(btrim(v_catalogo)) THEN
        v_nombre := NULL;
    END IF;

    IF v_oculta OR v_nombre IS NOT NULL OR v_destacada OR v_promocion
       OR v_segundos IS NOT NULL THEN
        INSERT INTO ecommerce.categorias_web (categoria_id, oculta, nombre_web, destacada,
                                              promocion, banner_segundos)
        VALUES (p_categoria_id, v_oculta, v_nombre, v_destacada, v_promocion, v_segundos)
        ON CONFLICT (categoria_id) DO UPDATE
            SET oculta = EXCLUDED.oculta,
                nombre_web = EXCLUDED.nombre_web,
                destacada = EXCLUDED.destacada,
                promocion = EXCLUDED.promocion,
                banner_segundos = EXCLUDED.banner_segundos;
    ELSE
        -- Visible, con su nombre de siempre y sin marcas: no hay nada que
        -- guardar, y una fila con todo por omisión sólo estorba. El orden del
        -- menú se va con ella, que es lo coherente: no había nada que ordenar.
        DELETE FROM ecommerce.categorias_web WHERE categoria_id = p_categoria_id;
    END IF;

    RETURN jsonb_build_object('success', true,
        'message', format('«%s» %s', COALESCE(v_nombre, v_catalogo),
                          CASE WHEN v_oculta THEN 'no saldrá en la tienda' ELSE 'saldrá en la tienda' END),
        'data', (ecommerce.fn_categorias_web_listar() -> 'data'));
END;
$function$;


-- ----------------------------------------------------------------------------
-- 6. Y LA PANTALLA LOS RECIBE
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ecommerce.fn_categorias_web_listar()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
AS $function$
    SELECT jsonb_build_object('success', true, 'message', 'Categorías de la tienda',
        'data', COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
                       'id',             e.id,
                       'padre_id',       e.padre_id,
                       'nivel',          e.nivel,
                       'orden',          e.orden,
                       -- El de la tienda (el propio si no se cambió)
                       'nombre',         e.nombre,
                       -- El del catálogo, para poder compararlos
                       'nombre_catalogo', c.nombre,
                       'nombre_web',     w.nombre_web,
                       'oculta',         COALESCE(w.oculta, false),
                       -- Cada cuánto cambia el banner de esta categoría (NULL = el de siempre)
                       'banner_segundos', w.banner_segundos,
                       'destacada',      e.destacada,
                       'destacada_orden', e.destacada_orden,
                       'promocion',      e.promocion,
                       'promocion_orden', e.promocion_orden,
                       'orden_web',      e.orden_web,
                       'es_transaccion', c.es_transaccion,
                       'activo',         c.activo,
                       'estado',         e.estado,
                       -- Su página, si tiene. Es lo que decide a dónde lleva el
                       -- clic en esta categoría en toda la tienda
                       'cuerpo',         ecommerce.fn_cuerpo_json_de(e.id, NULL))
                   -- En el orden de la TIENDA: es el que se administra aquí
                   ORDER BY e.nivel, e.orden_web NULLS LAST, e.orden, e.nombre)
              FROM ecommerce.fn_categorias_web_estado() e
              JOIN inventarios.categorias c ON c.id = e.id
              LEFT JOIN ecommerce.categorias_web w ON w.categoria_id = e.id), '[]'::jsonb));
$function$;


-- ----------------------------------------------------------------------------
-- COMPROBACIÓN
-- ----------------------------------------------------------------------------
DO $comprobar$
DECLARE
    v_falta   text[] := ARRAY[]::text[];
    v_cat     bigint;
    v_uno     bigint;
    v_dos     bigint;
    v_banner  jsonb;
BEGIN
    SELECT id INTO v_cat FROM inventarios.categorias WHERE deleted_at IS NULL ORDER BY id LIMIT 1;

    -- DOS banners sembrados, para ver que se turnan. Se buscan por su fichero,
    -- que es de esta comprobación: por posición se cogería el de otro.
    PERFORM ecommerce.fn_categorias_imagenes_guardar(NULL, v_cat,
                jsonb_build_object('imagen', 'zz-rota-uno.jpg', 'nombre', 'ZZ uno',
                                   'tipo', 'banner', 'enlace', '/shop'));
    PERFORM ecommerce.fn_categorias_imagenes_guardar(NULL, v_cat,
                jsonb_build_object('imagen', 'zz-rota-dos.jpg', 'nombre', 'ZZ dos',
                                   'tipo', 'banner', 'enlace', 'https://ejemplo.com'));
    SELECT id INTO v_uno FROM ecommerce.categorias_imagenes
     WHERE categoria_id = v_cat AND imagen = 'zz-rota-uno.jpg';
    SELECT id INTO v_dos FROM ecommerce.categorias_imagenes
     WHERE categoria_id = v_cat AND imagen = 'zz-rota-dos.jpg';
    IF v_uno IS NULL OR v_dos IS NULL THEN
        RAISE EXCEPTION 'No se pudieron sembrar los banners de prueba';
    END IF;

    v_banner := ecommerce.fn_categoria_banner(v_cat);

    -- Salen los dos, no uno
    IF (SELECT count(*) FROM jsonb_array_elements(v_banner -> 'imagenes') e
         WHERE e ->> 'imagen' IN ('zz-rota-uno.jpg', 'zz-rota-dos.jpg')) <> 2 THEN
        v_falta := array_append(v_falta, 'los banners no se turnan: no salen los dos');
    END IF;

    -- Y cada uno con su enlace
    IF (SELECT e ->> 'enlace' FROM jsonb_array_elements(v_banner -> 'imagenes') e
         WHERE e ->> 'imagen' = 'zz-rota-uno.jpg') IS DISTINCT FROM '/shop' THEN
        v_falta := array_append(v_falta, 'se perdió el enlace del banner');
    END IF;

    -- El de fuera abre en otra pestaña sin que nadie lo pida
    IF NOT (SELECT (e ->> 'nueva_pestana')::boolean FROM jsonb_array_elements(v_banner -> 'imagenes') e
             WHERE e ->> 'imagen' = 'zz-rota-dos.jpg') THEN
        v_falta := array_append(v_falta, 'un enlace de fuera no abre en otra pestaña');
    END IF;

    -- Los segundos: de la categoría, y con su tope
    PERFORM ecommerce.fn_categorias_web_guardar(v_cat, false, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
                                                NULL, NULL, 7::smallint);
    IF (ecommerce.fn_categoria_banner(v_cat) ->> 'segundos')::int IS DISTINCT FROM 7 THEN
        v_falta := array_append(v_falta, 'no se guardaron los segundos del banner');
    END IF;

    BEGIN
        PERFORM ecommerce.fn_categorias_web_guardar(v_cat, false, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
                                                    NULL, NULL, 999::smallint);
        v_falta := array_append(v_falta, 'admite 999 segundos: el tope no sirve');
    EXCEPTION WHEN OTHERS THEN
        NULL;
    END;

    -- Y SE PUEDEN VACIAR: con un cero vuelven al ritmo de siempre
    PERFORM ecommerce.fn_categorias_web_guardar(v_cat, false, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
                                                NULL, NULL, 0::smallint);
    IF (SELECT banner_segundos FROM ecommerce.categorias_web WHERE categoria_id = v_cat) IS NOT NULL THEN
        v_falta := array_append(v_falta, 'los segundos no se pueden volver a vaciar');
    END IF;

    -- Una imagen de las de siempre no se queda con el enlace
    PERFORM ecommerce.fn_categorias_imagenes_guardar(NULL, v_cat,
                jsonb_build_object('imagen', 'zz-rota-tres.jpg', 'nombre', 'ZZ tres',
                                   'enlace', '/shop'));
    IF (SELECT enlace FROM ecommerce.categorias_imagenes
         WHERE categoria_id = v_cat AND imagen = 'zz-rota-tres.jpg') IS NOT NULL THEN
        v_falta := array_append(v_falta, 'una imagen de círculo se quedó con un enlace');
    END IF;

    -- Lo sembrado, fuera, y sólo lo sembrado
    DELETE FROM ecommerce.categorias_imagenes
     WHERE categoria_id = v_cat
       AND imagen IN ('zz-rota-uno.jpg', 'zz-rota-dos.jpg', 'zz-rota-tres.jpg');
    UPDATE ecommerce.categorias_web SET banner_segundos = NULL WHERE categoria_id = v_cat;

    IF array_length(v_falta, 1) IS NULL THEN
        RAISE NOTICE 'Comprobado: los banners de una categoría se turnan todos, cada uno con su enlace, el de fuera abre aparte, los segundos se guardan con su tope y el círculo sigue sin enlace';
    ELSE
        RAISE EXCEPTION 'FALTA: %', array_to_string(v_falta, ' | ');
    END IF;
END
$comprobar$;

COMMIT;
