-- ============================================================================
-- ECOMMERCE · EL ORDEN DE LAS CATEGORÍAS DESTACADAS
-- ============================================================================
-- Fecha: 2026-11-01
--
-- Los círculos de la portada salían en el orden del catálogo, que no es el
-- que interesa: lo que se quiere empujar esta semana va primero. Este orden
-- se arrastra en la pantalla y es el que ve el cliente.
--
-- EL ORDEN ES DE LAS DESTACADAS, NO DE LA CATEGORÍA. Por eso la columna se
-- llama `destacada_orden` y no `orden`: el del catálogo es de Inventarios y
-- no se toca desde aquí.
--
-- EL ORDEN LLEGA ENTERO O NO LLEGA. Mandar «ésta ahora es la primera» obliga
-- a recalcular aquí lo que en la pantalla ya está resuelto, y deja huecos en
-- cuanto dos personas tocan a la vez.
--
-- UNA DESTACADA NUEVA VA AL FINAL: `destacada_orden` nace nulo y los nulos
-- se ordenan los últimos. Así marcar una no reordena las que ya estaban.
--
-- Idempotente.
-- ============================================================================
\set ON_ERROR_STOP on

BEGIN;

-- ----------------------------------------------------------------------------
-- 1. LA COLUMNA
-- ----------------------------------------------------------------------------
ALTER TABLE ecommerce.categorias_web
    ADD COLUMN IF NOT EXISTS destacada_orden integer;

-- ----------------------------------------------------------------------------
-- 2. EL ESTADO LO TRAE
-- ----------------------------------------------------------------------------
-- Cambia el tipo que devuelve (una columna más), así que hay que tirarla
-- antes: CREATE OR REPLACE no deja cambiar la firma de salida.
DROP FUNCTION IF EXISTS ecommerce.fn_categorias_web_estado();

CREATE FUNCTION ecommerce.fn_categorias_web_estado()
 RETURNS TABLE(id bigint, padre_id bigint, nivel integer, orden integer,
               nombre text, estado text, destacada boolean, destacada_orden integer)
 LANGUAGE sql
 STABLE SECURITY DEFINER
AS $function$
    WITH RECURSIVE
    vivas AS (
        SELECT c.id, c.padre_id, c.nivel, c.orden, c.nombre, c.es_transaccion, c.activo,
               COALESCE(w.oculta, false) AS oculta,
               COALESCE(w.destacada, false) AS destacada,
               w.destacada_orden,
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
           v.destacada_orden
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
                       'es_transaccion', c.es_transaccion,
                       'activo',         c.activo,
                       'estado',         e.estado)
                   ORDER BY e.nivel, e.orden, e.nombre)
              FROM ecommerce.fn_categorias_web_estado() e
              JOIN inventarios.categorias c ON c.id = e.id
              LEFT JOIN ecommerce.categorias_web w ON w.categoria_id = e.id), '[]'::jsonb));
$function$;

-- ----------------------------------------------------------------------------
-- 4. GUARDAR EL ORDEN
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ecommerce.fn_categorias_destacadas_ordenar(
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
        RAISE EXCEPTION 'Hace falta el orden de las destacadas' USING ERRCODE = 'P0001';
    END IF;

    v_recibidas := jsonb_array_length(p_ids);

    -- Que todas las que llegan estén destacadas de verdad
    SELECT count(*) INTO v_marcadas
      FROM ecommerce.categorias_web w
     WHERE w.destacada
       AND w.categoria_id IN (SELECT (x)::bigint FROM jsonb_array_elements_text(p_ids) x);

    -- Y que no falte ninguna: un orden a medias deja las que faltan en un
    -- sitio que nadie eligió
    SELECT count(*) INTO v_todas FROM ecommerce.categorias_web WHERE destacada;

    IF v_marcadas <> v_recibidas OR v_recibidas <> v_todas THEN
        RAISE EXCEPTION 'El orden tiene que traer las % destacadas, y trae % válidas de %',
              v_todas, v_marcadas, v_recibidas USING ERRCODE = 'P0016';
    END IF;

    UPDATE ecommerce.categorias_web w
       SET destacada_orden = n.pos
      FROM (SELECT (x.valor)::bigint AS id, x.pos
              FROM jsonb_array_elements_text(p_ids) WITH ORDINALITY AS x(valor, pos)) n
     WHERE w.categoria_id = n.id;

    RETURN jsonb_build_object('success', true, 'message', 'Orden de las destacadas guardado',
                              'data', (ecommerce.fn_categorias_web_listar() -> 'data'));
END;
$function$;

-- ----------------------------------------------------------------------------
-- 5. LA TIENDA LAS ENSEÑA EN ESE ORDEN
-- ----------------------------------------------------------------------------
-- Las recién marcadas (sin orden todavía) van al final, y entre ellas por el
-- orden del catálogo: así marcar una no mueve a las que ya estaban puestas.
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
           AND ecommerce.fn_vigente(i.desde, i.hasta)
         ORDER BY i.categoria_id, i.orden, i.id
    )
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'id', d.id, 'nombre', d.nombre, 'imagen', m.imagen)
           ORDER BY d.destacada_orden NULLS LAST, d.orden, d.nombre), '[]'::jsonb)
      FROM destacadas d
      LEFT JOIN mandona m ON m.categoria_id = d.id;
$function$;

-- ----------------------------------------------------------------------------
-- 6. QUE HAGA LO QUE DICE
-- ----------------------------------------------------------------------------
-- Se da la vuelta al orden, se comprueba y se deja como estaba. Todo se
-- cuenta sin condiciones, para que un NULL no deje pasar la prueba en verde.
DO $comprobar$
DECLARE
    v_antes     jsonb;
    v_ids       jsonb;
    v_alreves   jsonb;
    v_cuantas   integer;
    v_primera   bigint;
    v_esperada  bigint;
    v_fallo     text;
BEGIN
    SELECT COALESCE(jsonb_agg(jsonb_build_object('id', w.categoria_id, 'orden', w.destacada_orden)
                              ORDER BY w.categoria_id), '[]'::jsonb)
      INTO v_antes
      FROM ecommerce.categorias_web w WHERE w.destacada;

    SELECT count(*) INTO v_cuantas FROM ecommerce.categorias_web WHERE destacada;
    IF v_cuantas IS NULL OR v_cuantas < 2 THEN
        RAISE NOTICE 'Sólo hay % destacada(s): no se puede comprobar el orden, pero las funciones están.',
              COALESCE(v_cuantas, 0);
        RETURN;
    END IF;

    -- Un orden a medias no entra
    v_fallo := NULL;
    BEGIN
        SELECT jsonb_agg(c.id) INTO v_ids
          FROM (SELECT categoria_id AS id FROM ecommerce.categorias_web
                 WHERE destacada LIMIT 1) c;
        PERFORM ecommerce.fn_categorias_destacadas_ordenar(v_ids);
    EXCEPTION WHEN SQLSTATE 'P0016' THEN v_fallo := 'bien';
    END;
    IF v_fallo IS NULL THEN
        RAISE EXCEPTION 'Se tragó un orden con una sola destacada de %', v_cuantas;
    END IF;

    -- El entero sí, y al revés
    SELECT jsonb_agg(d.id ORDER BY d.destacada_orden NULLS LAST, d.orden, d.nombre) INTO v_ids
      FROM ecommerce.fn_categorias_web_estado() d WHERE d.destacada;

    SELECT jsonb_agg(x.valor ORDER BY x.pos DESC) INTO v_alreves
      FROM jsonb_array_elements_text(v_ids) WITH ORDINALITY AS x(valor, pos);

    PERFORM ecommerce.fn_categorias_destacadas_ordenar(v_alreves);

    SELECT (c ->> 'id')::bigint INTO v_primera
      FROM jsonb_array_elements(ecommerce.fn_categorias_destacadas_publicas()) c LIMIT 1;
    v_esperada := (v_alreves ->> 0)::bigint;

    -- Se deja como estaba ANTES de juzgar, para no dejarlo del revés si falla
    UPDATE ecommerce.categorias_web w
       SET destacada_orden = (SELECT (a ->> 'orden')::integer
                                FROM jsonb_array_elements(v_antes) a
                               WHERE (a ->> 'id')::bigint = w.categoria_id)
     WHERE w.destacada;

    -- Sólo cuenta si la primera de la lista pública es una de las que de
    -- verdad se ven: una destacada sin productos debajo no sale.
    IF v_primera IS NOT NULL AND v_primera IS DISTINCT FROM v_esperada
       AND EXISTS (SELECT 1 FROM ecommerce.fn_categorias_web_estado() e
                    WHERE e.id = v_esperada AND e.estado = 'visible') THEN
        RAISE EXCEPTION 'El orden no mandó: arriba quedó % y se pidió %', v_primera, v_esperada;
    END IF;

    RAISE NOTICE 'Comprobado: % destacadas, el orden entra entero o no entra, y manda en la tienda.',
          v_cuantas;
END
$comprobar$;

COMMIT;
