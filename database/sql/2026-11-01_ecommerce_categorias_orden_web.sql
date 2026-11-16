-- ============================================================================
-- ECOMMERCE · EL ORDEN DE LAS CATEGORÍAS EN LA TIENDA
-- ============================================================================
-- Fecha: 2026-11-01
--
-- Las categorías salían en la tienda en el orden del catálogo. Ése lo decide
-- Inventarios y responde a cómo se trabaja por dentro; el de la tienda
-- responde a qué se quiere enseñar primero, y no tienen por qué coincidir.
--
-- SE ORDENA DENTRO DE CADA RAMA, no en una lista plana. La tienda pinta un
-- menú de tres niveles: lo que se decide es en qué orden salen las hijas de
-- cada padre. Mover una categoría a otra rama es cambiar el árbol, y eso es
-- de Inventarios.
--
-- SIN ORDEN PROPIO, EL DEL CATÁLOGO. `orden_web` nace nulo y los nulos van
-- los últimos dentro de su rama: una categoría nueva aparece al final en vez
-- de colarse en medio de lo ya colocado.
--
-- Idempotente.
-- ============================================================================
\set ON_ERROR_STOP on

BEGIN;

-- ----------------------------------------------------------------------------
-- 1. LA COLUMNA
-- ----------------------------------------------------------------------------
ALTER TABLE ecommerce.categorias_web
    ADD COLUMN IF NOT EXISTS orden_web integer;

-- ----------------------------------------------------------------------------
-- 2. EL ESTADO LO TRAE
-- ----------------------------------------------------------------------------
-- Cambia el tipo que devuelve (una columna más), así que hay que tirarla
-- antes: CREATE OR REPLACE no deja cambiar la firma de salida.
DROP FUNCTION IF EXISTS ecommerce.fn_categorias_web_estado();

CREATE FUNCTION ecommerce.fn_categorias_web_estado()
 RETURNS TABLE(id bigint, padre_id bigint, nivel integer, orden integer,
               nombre text, estado text, destacada boolean, destacada_orden integer,
               orden_web integer)
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
           v.orden_web
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
-- 4. GUARDAR EL ORDEN DE UNA RAMA
-- ----------------------------------------------------------------------------
-- Llegan las hijas de UN MISMO PADRE, en su orden. No hacen falta todas las
-- hermanas: las que no salen en la tienda no están en la pantalla, y
-- exigirlas haría imposible ordenar las que sí.
CREATE OR REPLACE FUNCTION ecommerce.fn_categorias_web_ordenar(
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
    v_existen   integer;
    v_padres    integer;
BEGIN
    PERFORM ecommerce.fn_contexto_auditoria('ecommerce.categorias_web',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    IF p_ids IS NULL OR jsonb_typeof(p_ids) <> 'array' OR jsonb_array_length(p_ids) = 0 THEN
        RAISE EXCEPTION 'Hace falta el orden de las categorías' USING ERRCODE = 'P0001';
    END IF;

    v_recibidas := jsonb_array_length(p_ids);

    SELECT count(*), count(DISTINCT COALESCE(c.padre_id, 0))
      INTO v_existen, v_padres
      FROM inventarios.categorias c
     WHERE c.deleted_at IS NULL
       AND c.id IN (SELECT (x)::bigint FROM jsonb_array_elements_text(p_ids) x);

    IF v_existen <> v_recibidas THEN
        RAISE EXCEPTION 'Alguna de esas categorías no existe' USING ERRCODE = 'P0013';
    END IF;

    -- TODAS DE LA MISMA RAMA. Un orden que mezcle ramas no significa nada: la
    -- tienda pinta cada una por su lado, y lo que se vería no sería lo que se
    -- arrastró.
    IF v_padres <> 1 THEN
        RAISE EXCEPTION 'Las categorías tienen que ser hijas del mismo padre' USING ERRCODE = 'P0016';
    END IF;

    -- Una fila por categoría, aunque no tuviera nada guardado todavía
    INSERT INTO ecommerce.categorias_web (categoria_id, orden_web)
    SELECT (x.valor)::bigint, x.pos
      FROM jsonb_array_elements_text(p_ids) WITH ORDINALITY AS x(valor, pos)
    ON CONFLICT (categoria_id) DO UPDATE SET orden_web = EXCLUDED.orden_web;

    RETURN jsonb_build_object('success', true, 'message', 'Orden de la tienda guardado',
                              'data', (ecommerce.fn_categorias_web_listar() -> 'data'));
END;
$function$;

-- ----------------------------------------------------------------------------
-- 5. LA TIENDA LAS ENSEÑA EN ESE ORDEN
-- ----------------------------------------------------------------------------
-- El menú, nivel a nivel.
CREATE OR REPLACE FUNCTION ecommerce.fn_categorias_web_menu_publico()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
AS $function$
    WITH v AS (
        SELECT * FROM ecommerce.fn_categorias_web_estado() WHERE estado = 'visible'
    )
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'id', d.id, 'nombre', d.nombre,
               'hijos', COALESCE((
                   SELECT jsonb_agg(jsonb_build_object(
                              'id', c.id, 'nombre', c.nombre,
                              'hijos', COALESCE((
                                  SELECT jsonb_agg(jsonb_build_object('id', s.id, 'nombre', s.nombre, 'hijos', '[]'::jsonb)
                                         ORDER BY s.orden_web NULLS LAST, s.orden, s.nombre)
                                    FROM v s WHERE s.padre_id = c.id), '[]'::jsonb))
                          ORDER BY c.orden_web NULLS LAST, c.orden, c.nombre)
                     FROM v c WHERE c.padre_id = d.id), '[]'::jsonb))
           ORDER BY d.orden_web NULLS LAST, d.orden, d.nombre), '[]'::jsonb)
      FROM v d
     WHERE d.padre_id IS NULL;
$function$;

-- El mosaico de la portada.
CREATE OR REPLACE FUNCTION ecommerce.fn_categorias_imagenes_publicas()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
AS $function$
    WITH visibles AS (
        SELECT e.id, e.nombre, e.nivel, e.orden, e.orden_web
          FROM ecommerce.fn_categorias_web_estado() e
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
           ORDER BY v.nivel, v.orden_web NULLS LAST, v.orden, v.nombre), '[]'::jsonb)
      FROM visibles v
      JOIN mandona m ON m.categoria_id = v.id;
$function$;

-- ----------------------------------------------------------------------------
-- 6. QUE HAGA LO QUE DICE
-- ----------------------------------------------------------------------------
-- Se da la vuelta al orden de una rama, se comprueba y se deja como estaba.
-- Todo se cuenta sin condiciones, para que un NULL no deje pasar en verde.
DO $comprobar$
DECLARE
    v_padre    bigint;
    v_ids      jsonb;
    v_alreves  jsonb;
    v_antes    jsonb;
    v_cuantas  integer;
    v_primera  bigint;
    v_esperada bigint;
    v_fallo    text;
BEGIN
    -- Una rama con al menos dos hijas visibles
    SELECT e.padre_id, count(*) INTO v_padre, v_cuantas
      FROM ecommerce.fn_categorias_web_estado() e
     WHERE e.estado = 'visible' AND e.padre_id IS NOT NULL
     GROUP BY e.padre_id HAVING count(*) > 1
     ORDER BY count(*) DESC LIMIT 1;

    IF v_padre IS NULL THEN
        RAISE NOTICE 'No hay ninguna rama con dos hijas visibles: las funciones están, pero no se pudo probar el orden.';
        RETURN;
    END IF;

    SELECT COALESCE(jsonb_agg(jsonb_build_object('id', w.categoria_id, 'orden', w.orden_web)), '[]'::jsonb)
      INTO v_antes
      FROM ecommerce.categorias_web w
      JOIN inventarios.categorias c ON c.id = w.categoria_id
     WHERE c.padre_id = v_padre;

    SELECT jsonb_agg(e.id ORDER BY e.orden_web NULLS LAST, e.orden, e.nombre) INTO v_ids
      FROM ecommerce.fn_categorias_web_estado() e
     WHERE e.estado = 'visible' AND e.padre_id = v_padre;

    SELECT jsonb_agg(x.valor ORDER BY x.pos DESC) INTO v_alreves
      FROM jsonb_array_elements_text(v_ids) WITH ORDINALITY AS x(valor, pos);

    -- Mezclar ramas no entra
    v_fallo := NULL;
    BEGIN
        PERFORM ecommerce.fn_categorias_web_ordenar(
            jsonb_build_array((v_ids ->> 0)::bigint,
                              (SELECT e.id FROM ecommerce.fn_categorias_web_estado() e
                                WHERE e.padre_id IS DISTINCT FROM v_padre AND e.estado = 'visible'
                                LIMIT 1)));
    EXCEPTION WHEN SQLSTATE 'P0016' THEN v_fallo := 'bien';
    END;
    IF v_fallo IS NULL THEN
        RAISE EXCEPTION 'Se tragó un orden que mezclaba dos ramas';
    END IF;

    -- El de la rama sí
    PERFORM ecommerce.fn_categorias_web_ordenar(v_alreves);

    SELECT e.id INTO v_primera
      FROM ecommerce.fn_categorias_web_estado() e
     WHERE e.estado = 'visible' AND e.padre_id = v_padre
     ORDER BY e.orden_web NULLS LAST, e.orden, e.nombre LIMIT 1;
    v_esperada := (v_alreves ->> 0)::bigint;

    -- Se deja como estaba ANTES de juzgar, para no dejarlo del revés si falla
    UPDATE ecommerce.categorias_web w
       SET orden_web = (SELECT (a ->> 'orden')::integer FROM jsonb_array_elements(v_antes) a
                         WHERE (a ->> 'id')::bigint = w.categoria_id)
      FROM inventarios.categorias c
     WHERE c.id = w.categoria_id AND c.padre_id = v_padre;

    IF v_primera IS DISTINCT FROM v_esperada THEN
        RAISE EXCEPTION 'El orden no mandó: arriba quedó % y se pidió %', v_primera, v_esperada;
    END IF;

    RAISE NOTICE 'Comprobado: % hermanas, el orden manda dentro de su rama y no deja mezclarlas.', v_cuantas;
END
$comprobar$;

COMMIT;
