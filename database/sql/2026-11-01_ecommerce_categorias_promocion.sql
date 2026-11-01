-- ============================================================================
-- ECOMMERCE · CATEGORÍAS EN PROMOCIÓN
-- ============================================================================
-- Fecha: 2026-11-01
--
-- La sección `mosaico` de la portada se llenaba sola con cualquier categoría
-- que tuviera imagen vigente. Era una regla implícita: para sacar una
-- categoría de ahí había que quitarle la imagen, y para meterla había que
-- ponerle una, aunque lo que se quisiera fuese sólo lo primero.
--
-- AHORA ES UNA MARCA, como las destacadas: `promocion`. Se enciende y sale;
-- se apaga y deja de salir. Y la sección pasa a llamarse lo que de verdad
-- es, «Categorías en promoción», que es como se habla de ella.
--
-- SON DOS MARCAS Y DOS SECCIONES:
--
--   · DESTACADAS   los círculos de arriba   (destacada / destacada_orden)
--   · PROMOCIÓN    las tarjetas grandes     (promocion / promocion_orden)
--
-- Una categoría puede estar en las dos, en una o en ninguna. La imagen que
-- usan es la misma, la programada en `categorias_imagenes`: una categoría
-- tiene una imagen, no una por sitio donde salga. Sin imagen la tarjeta sale
-- igual, con su nombre y su botón.
--
-- `orden_web` SE QUEDA: sigue ordenando el menú de la tienda, que es otra
-- cosa distinta de estas dos secciones.
--
-- Idempotente.
-- ============================================================================
\set ON_ERROR_STOP on

BEGIN;

-- ----------------------------------------------------------------------------
-- 1. LA MARCA Y SU ORDEN
-- ----------------------------------------------------------------------------
ALTER TABLE ecommerce.categorias_web
    ADD COLUMN IF NOT EXISTS promocion boolean NOT NULL DEFAULT false;

ALTER TABLE ecommerce.categorias_web
    ADD COLUMN IF NOT EXISTS promocion_orden integer;

-- Las que ya salían en el mosaico siguen saliendo: hasta ahora la regla era
-- «tiene imagen vigente», así que se marcan esas y nadie nota el cambio.
DO $arranque$
DECLARE
    v integer;
BEGIN
    IF EXISTS (SELECT 1 FROM ecommerce.categorias_web WHERE promocion) THEN
        RAISE NOTICE 'Ya hay categorías en promoción: no se toca nada.';
        RETURN;
    END IF;

    INSERT INTO ecommerce.categorias_web (categoria_id, promocion)
    SELECT DISTINCT i.categoria_id, true
      FROM ecommerce.categorias_imagenes i
     WHERE i.deleted_at IS NULL AND i.activo
       AND ecommerce.fn_vigente(i.desde, i.hasta)
    ON CONFLICT (categoria_id) DO UPDATE SET promocion = true;
    GET DIAGNOSTICS v = ROW_COUNT;

    RAISE NOTICE 'Marcadas % categorías que ya salían en el mosaico.', v;
END
$arranque$;

-- ----------------------------------------------------------------------------
-- 2. EL ESTADO LAS TRAE
-- ----------------------------------------------------------------------------
-- Cambia el tipo que devuelve (dos columnas más), así que hay que tirarla
-- antes: CREATE OR REPLACE no deja cambiar la firma de salida.
DROP FUNCTION IF EXISTS ecommerce.fn_categorias_web_estado();

CREATE FUNCTION ecommerce.fn_categorias_web_estado()
 RETURNS TABLE(id bigint, padre_id bigint, nivel integer, orden integer,
               nombre text, estado text, destacada boolean, destacada_orden integer,
               orden_web integer, promocion boolean, promocion_orden integer)
 LANGUAGE sql
 STABLE SECURITY DEFINER
AS $function$
    WITH RECURSIVE
    vivas AS (
        SELECT c.id, c.padre_id, c.nivel, c.orden, c.nombre, c.es_transaccion, c.activo,
               COALESCE(w.oculta, false) AS oculta,
               COALESCE(w.destacada, false) AS destacada,
               w.destacada_orden,
               w.orden_web,
               COALESCE(w.promocion, false) AS promocion,
               w.promocion_orden,
               COALESCE(NULLIF(btrim(w.nombre_web), ''), c.nombre) AS nombre_web
          FROM inventarios.categorias c
          LEFT JOIN ecommerce.categorias_web w ON w.categoria_id = c.id
         WHERE c.deleted_at IS NULL
    ),
    -- Apagadas: las que lo están, y todo lo que cuelgue de ellas
    apagadas AS (
        SELECT v.id FROM vivas v WHERE v.oculta OR NOT v.activo
        UNION
        SELECT h.id FROM vivas h JOIN apagadas a ON h.padre_id = a.id
    ),
    -- Las que de verdad llevan productos y no están apagadas
    con_productos AS (
        SELECT v.id, v.padre_id FROM vivas v
         WHERE v.es_transaccion AND v.id NOT IN (SELECT id FROM apagadas)
    ),
    -- Ésas y sus padres: una rama sin ninguna de producto debajo no sale
    visibles AS (
        SELECT p.id, p.padre_id FROM con_productos p
        UNION
        SELECT v.id, v.padre_id
          FROM vivas v
          JOIN visibles s ON s.padre_id = v.id
         WHERE v.id NOT IN (SELECT id FROM apagadas)
    )
    SELECT v.id, v.padre_id, v.nivel, v.orden, v.nombre_web,
           CASE
               WHEN vi.id IS NOT NULL                       THEN 'visible'
               WHEN v.oculta                                THEN 'oculta'
               WHEN NOT v.activo                            THEN 'inactiva'
               WHEN v.id IN (SELECT id FROM apagadas)       THEN 'oculta_por_padre'
               ELSE                                              'sin_categorias_de_producto'
           END,
           v.destacada,
           v.destacada_orden,
           v.orden_web,
           v.promocion,
           v.promocion_orden
      FROM vivas v
      LEFT JOIN (SELECT DISTINCT visibles.id FROM visibles) vi ON vi.id = v.id;
$function$;

-- ----------------------------------------------------------------------------
-- 3. LA LISTA DE LA PANTALLA
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
                       'destacada',      e.destacada,
                       'destacada_orden', e.destacada_orden,
                       'promocion',      e.promocion,
                       'promocion_orden', e.promocion_orden,
                       'orden_web',      e.orden_web,
                       'es_transaccion', c.es_transaccion,
                       'activo',         c.activo,
                       'estado',         e.estado)
                   -- En el orden de la TIENDA: es el que se administra aquí
                   ORDER BY e.nivel, e.orden_web NULLS LAST, e.orden, e.nombre)
              FROM ecommerce.fn_categorias_web_estado() e
              JOIN inventarios.categorias c ON c.id = e.id
              LEFT JOIN ecommerce.categorias_web w ON w.categoria_id = e.id), '[]'::jsonb));
$function$;

-- ----------------------------------------------------------------------------
-- 4. GUARDARLA
-- ----------------------------------------------------------------------------
-- Otro parámetro al final y con valor por omisión: las llamadas que ya
-- existen siguen funcionando, y sin decir nada la marca se queda como estaba.
CREATE OR REPLACE FUNCTION ecommerce.fn_categorias_web_guardar(
    p_categoria_id bigint, p_oculta boolean, p_nombre_web character varying,
    p_usuario_id bigint DEFAULT NULL, p_usuario_login character varying DEFAULT NULL,
    p_usuario_nombre character varying DEFAULT NULL, p_ip_address inet DEFAULT NULL,
    p_user_agent text DEFAULT NULL, p_request_id uuid DEFAULT NULL,
    p_destacada boolean DEFAULT NULL, p_promocion boolean DEFAULT NULL)
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

    v_nombre := ecommerce.fn_validar_texto(p_nombre_web, 'El nombre para la tienda', 80);

    -- El mismo nombre del catálogo no es «otro nombre»: se guarda como nada,
    -- para que al renombrar la categoría en Inventarios la tienda la siga.
    IF v_nombre IS NOT NULL AND lower(btrim(v_nombre)) = lower(btrim(v_catalogo)) THEN
        v_nombre := NULL;
    END IF;

    IF v_oculta OR v_nombre IS NOT NULL OR v_destacada OR v_promocion THEN
        INSERT INTO ecommerce.categorias_web (categoria_id, oculta, nombre_web, destacada, promocion)
        VALUES (p_categoria_id, v_oculta, v_nombre, v_destacada, v_promocion)
        ON CONFLICT (categoria_id) DO UPDATE
            SET oculta = EXCLUDED.oculta,
                nombre_web = EXCLUDED.nombre_web,
                destacada = EXCLUDED.destacada,
                promocion = EXCLUDED.promocion;
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
-- 5. EL ORDEN DE LAS PROMOCIONES
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ecommerce.fn_categorias_promocion_ordenar(
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
    v_marcadas  integer;
    v_todas     integer;
BEGIN
    PERFORM ecommerce.fn_contexto_auditoria('ecommerce.categorias_web',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    IF p_ids IS NULL OR jsonb_typeof(p_ids) <> 'array' OR jsonb_array_length(p_ids) = 0 THEN
        RAISE EXCEPTION 'Hace falta el orden de las promociones' USING ERRCODE = 'P0001';
    END IF;

    v_recibidas := jsonb_array_length(p_ids);

    SELECT count(*) INTO v_marcadas
      FROM ecommerce.categorias_web w
     WHERE w.promocion
       AND w.categoria_id IN (SELECT (x)::bigint FROM jsonb_array_elements_text(p_ids) x);

    SELECT count(*) INTO v_todas FROM ecommerce.categorias_web WHERE promocion;

    IF v_marcadas <> v_recibidas OR v_recibidas <> v_todas THEN
        RAISE EXCEPTION 'El orden tiene que traer las % en promoción, y trae % válidas de %',
              v_todas, v_marcadas, v_recibidas USING ERRCODE = 'P0016';
    END IF;

    UPDATE ecommerce.categorias_web w
       SET promocion_orden = n.pos
      FROM (SELECT (x.valor)::bigint AS id, x.pos
              FROM jsonb_array_elements_text(p_ids) WITH ORDINALITY AS x(valor, pos)) n
     WHERE w.categoria_id = n.id;

    RETURN jsonb_build_object('success', true, 'message', 'Orden de las promociones guardado',
                              'data', (ecommerce.fn_categorias_web_listar() -> 'data'));
END;
$function$;

-- ----------------------------------------------------------------------------
-- 6. LO QUE VE LA TIENDA
-- ----------------------------------------------------------------------------
-- Las marcadas y que de verdad salen en la tienda, con su imagen vigente si
-- la tienen. SIN IMAGEN TAMBIÉN SALEN: la tarjeta se pinta con su nombre y
-- su botón, y obligar a subir una foto para poder poner una categoría en
-- promoción sería una traba que no ayuda a nadie.
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
           AND ecommerce.fn_vigente(i.desde, i.hasta)
         ORDER BY i.categoria_id, i.orden, i.id
    )
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'id', p.id, 'nombre', p.nombre, 'imagen', m.imagen)
           ORDER BY p.promocion_orden NULLS LAST, p.orden, p.nombre), '[]'::jsonb)
      FROM enPromocion p
      LEFT JOIN mandona m ON m.categoria_id = p.id;
$function$;

-- La de antes ya no la usa nadie: dos nombres para lo mismo es como acaban
-- diciendo cosas distintas.
DROP FUNCTION IF EXISTS ecommerce.fn_categorias_imagenes_publicas();

-- ----------------------------------------------------------------------------
-- 7. LA SECCIÓN SE LLAMA COMO ES
-- ----------------------------------------------------------------------------
-- La CLAVE no se toca: es la que conoce la tienda y está en su código. Lo
-- que cambia es el nombre con el que se habla de ella.
UPDATE ecommerce.inicio_secciones
   SET nombre = 'Categorías en promoción'
 WHERE clave = 'mosaico' AND nombre <> 'Categorías en promoción';

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
        -- Las dos se llenan en «Categorías de la tienda», cada una con su
        -- marca: una categoría puede estar en las dos, en una o en ninguna.
        WHEN 'mosaico' THEN
            jsonb_build_object('tipo', 'promocion', 'pantalla', 'allCategoriasWeb')
        WHEN 'categorias_destacadas' THEN
            jsonb_build_object('tipo', 'destacadas', 'pantalla', 'allCategoriasWeb')
        WHEN 'ofertas_flash' THEN
            jsonb_build_object('tipo', 'pendiente', 'falta', 'el catálogo de la tienda (precio y existencias)')
        WHEN 'grilla' THEN
            jsonb_build_object('tipo', 'pendiente', 'falta', 'el catálogo de la tienda (precio y existencias)')
        WHEN 'bloques' THEN
            jsonb_build_object('tipo', 'pendiente', 'falta', 'los bloques de productos destacados')
        WHEN 'marcas' THEN
            jsonb_build_object('tipo', 'pendiente', 'falta', 'las marcas de la tienda')
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
                       -- Cuántas cosas tiene hoy, cuando se puede saber
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
                   -- Los dos banners salen de su galería. `imagenes` trae el
                   -- NOMBRE del fichero; el controlador le pone la dirección.
                   WHEN 'banner_principal' THEN
                        jsonb_build_object('clave', v.clave,
                            'imagenes', COALESCE(ecommerce.fn_galerias_publica('inicio_banner') -> 'imagenes', '[]'::jsonb))
                   WHEN 'banner_simple' THEN
                        jsonb_build_object('clave', v.clave,
                            'imagenes', COALESCE(ecommerce.fn_galerias_publica('inicio_banner_simple') -> 'imagenes', '[]'::jsonb))
                   -- Las tarjetas grandes: las categorías en promoción
                   WHEN 'mosaico' THEN
                        jsonb_build_object('clave', v.clave,
                            'categorias', ecommerce.fn_categorias_promocion_publicas())
                   -- Los círculos de arriba: sólo las marcadas a dedo
                   WHEN 'categorias_destacadas' THEN
                        jsonb_build_object('clave', v.clave,
                            'categorias', ecommerce.fn_categorias_destacadas_publicas())
                   -- Las demás todavía no tienen de dónde sacar datos. Se
                   -- devuelven como NULL y se caen en el filtro de abajo; la
                   -- tienda ni se entera.
                   ELSE NULL
               END AS seccion
          FROM visibles v
    )
    SELECT jsonb_build_object('secciones', COALESCE(jsonb_agg(a.seccion ORDER BY a.orden), '[]'::jsonb))
      FROM armadas a
     WHERE a.seccion IS NOT NULL
       -- Y si la sección se quedó sin contenido, tampoco sale: un título con
       -- nada debajo es peor que no estar.
       AND (a.seccion -> 'imagenes'   IS NULL OR jsonb_array_length(a.seccion -> 'imagenes') > 0)
       AND (a.seccion -> 'categorias' IS NULL OR jsonb_array_length(a.seccion -> 'categorias') > 0);
$function$;

-- ----------------------------------------------------------------------------
-- 8. QUE HAGA LO QUE DICE
-- ----------------------------------------------------------------------------
DO $comprobar$
DECLARE
    v_cat     bigint;
    v_antes   boolean;
    v_con     integer;
    v_sin     integer;
    v_nombre  text;
    v_fuente  text;
BEGIN
    SELECT nombre INTO v_nombre FROM ecommerce.inicio_secciones WHERE clave = 'mosaico';
    IF v_nombre IS DISTINCT FROM 'Categorías en promoción' THEN
        RAISE EXCEPTION 'La sección no se renombró: se llama «%»', COALESCE(v_nombre, 'nada');
    END IF;

    SELECT ecommerce.fn_inicio_fuente('mosaico') ->> 'tipo' INTO v_fuente;
    IF v_fuente IS DISTINCT FROM 'promocion' THEN
        RAISE EXCEPTION 'La sección no come de la marca de promoción (dice «%»)', COALESCE(v_fuente, 'nada');
    END IF;

    -- Una categoría que de verdad esté en la tienda
    SELECT e.id INTO v_cat FROM ecommerce.fn_categorias_web_estado() e
     WHERE e.estado = 'visible' ORDER BY e.orden, e.id LIMIT 1;
    IF v_cat IS NULL THEN
        RAISE EXCEPTION 'No hay ninguna categoría visible con la que comprobar';
    END IF;

    SELECT COALESCE(promocion, false) INTO v_antes
      FROM ecommerce.categorias_web WHERE categoria_id = v_cat;
    v_antes := COALESCE(v_antes, false);

    -- Marcada: sale
    PERFORM ecommerce.fn_categorias_web_guardar(v_cat, false, NULL,
                NULL, NULL, NULL, NULL, NULL, NULL, NULL, true);
    SELECT count(*) INTO v_con
      FROM jsonb_array_elements(ecommerce.fn_categorias_promocion_publicas()) c
     WHERE (c ->> 'id')::bigint = v_cat;

    -- Sin marcar: no sale, AUNQUE TENGA IMAGEN. Ésa es toda la diferencia
    -- con la regla de antes.
    PERFORM ecommerce.fn_categorias_web_guardar(v_cat, false, NULL,
                NULL, NULL, NULL, NULL, NULL, NULL, NULL, false);
    SELECT count(*) INTO v_sin
      FROM jsonb_array_elements(ecommerce.fn_categorias_promocion_publicas()) c
     WHERE (c ->> 'id')::bigint = v_cat;

    -- Se deja como estaba ANTES de juzgar
    PERFORM ecommerce.fn_categorias_web_guardar(v_cat, false, NULL,
                NULL, NULL, NULL, NULL, NULL, NULL, NULL, v_antes);

    IF v_con <> 1 THEN
        RAISE EXCEPTION 'Marcada en promoción, la categoría debería salir (salió % veces)', v_con;
    END IF;
    IF v_sin <> 0 THEN
        RAISE EXCEPTION 'Sin marcar no debería salir, y salió % veces', v_sin;
    END IF;

    RAISE NOTICE 'Comprobado: la sección se llama «%», y la marca decide quién sale, no la imagen.', v_nombre;
END
$comprobar$;

COMMIT;
