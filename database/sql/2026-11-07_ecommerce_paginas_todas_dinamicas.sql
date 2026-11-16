-- ============================================================================
-- PÁGINAS INFORMATIVAS: NINGUNA ES FIJA
-- ============================================================================
-- Fecha: 2026-11-07
--
-- SE VA LA COLUMNA `fija`. Era una bandera que la pantalla no podía cambiar
-- («fija se decide en la base») y que hacía tres cosas a la vez:
--
--   1. impedía borrar la página,
--   2. impedía reordenarla (su sitio era el de arriba, con orden 0),
--   3. la dejaba FUERA del índice de /documentos, porque la tienda le tiene
--      una dirección propia en el menú (/politicas-de-garantia, /conocenos…).
--
-- Las tres se van. Ahora las once páginas son iguales: se editan, se mueven,
-- se borran y SALEN TODAS en /documentos, cada una por /paginas/<clave>.
--
-- LO QUE ESTO SIGNIFICA Y SE ACEPTÓ A SABIENDAS: las cuatro que tenían
-- pantalla propia quedan en dos direcciones —la suya, completa, y la genérica
-- de sólo texto a la que lleva la lista—, y borrar una deja su dirección del
-- menú en la pantalla de error. Antes eso no podía pasar; ahora sí.
--
-- EL ORDEN SE RENUMERA UNA VEZ. Las cuatro fijas tenían orden 0 y habrían
-- salido las primeras en la lista de documentos legales; se les da el sitio
-- del final. Las demás conservan el orden que se ve hoy, numerado 1..n sin
-- repetidos (había tres pares con el mismo número).
--
-- SE EJECUTA A MANO, como el resto de ficheros de esta carpeta, y se puede
-- repetir: lo que ya esté hecho no vuelve a hacerse.
--
--   psql -U postgres -d crm3 -f 2026-11-07_ecommerce_paginas_todas_dinamicas.sql
--
-- OJO AL ORDEN: primero las funciones que dejan de nombrar la columna, luego
-- la renumeración (que todavía la necesita) y al final el DROP. Al revés,
-- PostgreSQL se niega mientras una función la nombre.
-- ============================================================================

BEGIN;

-- ----------------------------------------------------------------------------
-- 1. LAS FUNCIONES QUE DEJAN DE NOMBRAR LA COLUMNA
-- ----------------------------------------------------------------------------
-- Van enteras y no como un ALTER: una función se reemplaza completa, y
-- dejarla a medias no existe. Los parámetros no cambian en ninguna, así que
-- no hay que tirar la de antes.

-- La ficha de una página. Pierde 'fija' del JSON, y con ella la columna «Tipo»
-- de la rejilla, que ya sólo tenía un valor posible.
CREATE OR REPLACE FUNCTION ecommerce.fn_paginas_informativas_json(p_id bigint)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
AS $function$
    SELECT jsonb_build_object(
        'id',           p.id,
        'clave',        p.clave,
        'titulo',       p.titulo,
        'contenido',    p.contenido,
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

-- La lista del CRM. Ya no hay nada que subir arriba: el orden es el orden.
CREATE OR REPLACE FUNCTION ecommerce.fn_paginas_informativas_listar()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
AS $function$
    -- Sin el contenido: la lista enseña título y estado, y el texto de diez
    -- páginas con su HTML son cientos de kilobytes para nada.
    --
    -- DE TODO EL CONTENIDO SE SALVA EL NOMBRE DE LA IMAGEN, que la rejilla
    -- pinta en miniatura. Traerla aparte costaría una consulta por fila, y
    -- traer el contenido entero por una miniatura, todo lo demás.
    SELECT jsonb_build_object('success', true, 'message', 'Páginas informativas',
        'data', COALESCE((
            SELECT jsonb_agg(
                     (ecommerce.fn_paginas_informativas_json(p.id) - 'contenido')
                     || jsonb_build_object('imagen', p.contenido ->> 'imagen')
                     ORDER BY p.orden, p.id)
              FROM ecommerce.paginas_informativas p
             WHERE p.deleted_at IS NULL), '[]'::jsonb));
$function$;

-- El índice de /documentos: TODAS las páginas visibles, en el orden que se
-- arrastró en el CRM. Antes se quedaban fuera las fijas.
--
-- LA FORMA DE LA RESPUESTA NO CAMBIA —sigue siendo un arreglo con UNA sección
-- sin nombre—, así que la tienda no se toca.
CREATE OR REPLACE FUNCTION ecommerce.fn_paginas_informativas_listar_publicas()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
AS $function$
    SELECT CASE WHEN t.paginas = '[]'::jsonb THEN '[]'::jsonb
                ELSE jsonb_build_array(jsonb_build_object(
                         'grupo_id', NULL, 'grupo', NULL, 'orden', 1, 'paginas', t.paginas)) END
      FROM (SELECT COALESCE(jsonb_agg(jsonb_build_object('clave', p.clave, 'titulo', p.titulo)
                                      ORDER BY p.orden, p.id), '[]'::jsonb) AS paginas
              FROM ecommerce.paginas_informativas p
             WHERE p.activo AND p.deleted_at IS NULL) t;
$function$;

-- Crear. La página nueva ya no tiene que declararse «no fija».
CREATE OR REPLACE FUNCTION ecommerce.fn_paginas_informativas_crear(
    p_clave text, p_titulo character varying, p_contenido jsonb,
    p_activo boolean DEFAULT true,
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
    v_id    bigint;
    v_clave text;
BEGIN
    PERFORM ecommerce.fn_contexto_auditoria('ecommerce.paginas_informativas',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    -- Sin clave, se saca del título: «Política de datos» -> «politica-de-datos»
    v_clave := COALESCE(nullif(btrim(COALESCE(p_clave, '')), ''),
                        ecommerce.fn_paginas_informativas_slug(p_titulo));

    PERFORM ecommerce.fn_paginas_informativas_validar(NULL, v_clave, p_titulo);

    INSERT INTO ecommerce.paginas_informativas (clave, titulo, contenido, orden, activo)
    VALUES (v_clave, btrim(p_titulo),
            ecommerce.fn_paginas_informativas_contenido_validar(p_contenido),
            (SELECT COALESCE(max(orden), 0) + 1 FROM ecommerce.paginas_informativas
              WHERE deleted_at IS NULL),
            COALESCE(p_activo, true))
    RETURNING id INTO v_id;

    RETURN jsonb_build_object('success', true, 'message', 'Página creada',
                              'data', ecommerce.fn_paginas_informativas_json(v_id));
END;
$function$;

-- Borrar. Se va el portero que negaba el borrado de las fijas, y con él el
-- código de error P0021, que no lo levanta nadie más.
CREATE OR REPLACE FUNCTION ecommerce.fn_paginas_informativas_eliminar(
    p_id bigint,
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
    v_actual record;
BEGIN
    PERFORM ecommerce.fn_contexto_auditoria('ecommerce.paginas_informativas',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    SELECT titulo, deleted_at INTO v_actual
      FROM ecommerce.paginas_informativas WHERE id = p_id;
    IF NOT FOUND OR v_actual.deleted_at IS NOT NULL THEN
        RAISE EXCEPTION 'La página no existe' USING ERRCODE = 'P0013';
    END IF;

    UPDATE ecommerce.paginas_informativas
       SET deleted_at = CURRENT_TIMESTAMP, deleted_by = p_usuario_login WHERE id = p_id;

    RETURN jsonb_build_object('success', true,
        'message', format('Página «%s» enviada a la papelera', v_actual.titulo),
        'data', ecommerce.fn_paginas_informativas_json(p_id));
END;
$function$;

-- ----------------------------------------------------------------------------
-- 2. EL ORDEN, UNA SOLA VEZ
-- ----------------------------------------------------------------------------
-- Se renumera 1..n: las de siempre en el orden que se ve hoy y las cuatro
-- fijas detrás. Va dentro de un DO porque la segunda pasada ya no tiene
-- columna por la que ordenar, y entonces no hay nada que renumerar.
DO $renumerar$
DECLARE
    v_tocadas integer;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                    WHERE table_schema = 'ecommerce'
                      AND table_name   = 'paginas_informativas'
                      AND column_name  = 'fija') THEN
        RAISE NOTICE 'El orden ya estaba renumerado: la columna «fija» no existe.';
        RETURN;
    END IF;

    -- El UPDATE es en masa y el disparador de auditoría lo anotará fila por
    -- fila: es un cambio de orden, no de contenido, y así queda la huella.
    WITH nuevo AS (
        SELECT id, row_number() OVER (ORDER BY fija, orden, id) AS n
          FROM ecommerce.paginas_informativas
         WHERE deleted_at IS NULL
    )
    UPDATE ecommerce.paginas_informativas p
       SET orden = nuevo.n
      FROM nuevo
     WHERE p.id = nuevo.id AND p.orden <> nuevo.n;

    GET DIAGNOSTICS v_tocadas = ROW_COUNT;
    RAISE NOTICE 'Orden renumerado: % página(s) cambiaron de sitio.', v_tocadas;
END;
$renumerar$;

-- ----------------------------------------------------------------------------
-- 3. Y LA COLUMNA
-- ----------------------------------------------------------------------------
-- Sin índices ni restricciones que la nombren (la última, la que prohibía
-- carpeta en una fija, se fue con las carpetas esta misma mañana). Lo que ya
-- esté anotado en auditoría se queda como está: es la foto de lo que pasó.
ALTER TABLE ecommerce.paginas_informativas DROP COLUMN IF EXISTS fija;

-- ----------------------------------------------------------------------------
-- COMPROBACIÓN (no cambia nada; si algo no cuadra, el COMMIT no llega)
-- ----------------------------------------------------------------------------
DO $comprobar$
DECLARE
    v_paginas   integer;
    v_activas   integer;
    v_publicas  jsonb;
    v_en_lista  integer;
    v_ordenes   integer;
    v_quedan    integer;
BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.columns
                WHERE table_schema = 'ecommerce'
                  AND table_name   = 'paginas_informativas'
                  AND column_name  = 'fija') THEN
        RAISE EXCEPTION 'La columna «fija» sigue en la tabla';
    END IF;

    -- Ninguna función la nombra ya: si quedara una, fallaría al llamarla y no
    -- al crearla, que plpgsql no mira dentro hasta que corre.
    SELECT count(*) INTO v_quedan
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'ecommerce' AND p.prosrc ILIKE '%fija%'
       AND p.prosrc ILIKE '%paginas_informativas%';
    IF v_quedan > 0 THEN
        RAISE EXCEPTION 'Quedan % función(es) de páginas nombrando «fija»', v_quedan;
    END IF;

    SELECT count(*), count(*) FILTER (WHERE activo)
      INTO v_paginas, v_activas
      FROM ecommerce.paginas_informativas WHERE deleted_at IS NULL;

    -- El orden es 1..n sin repetidos: es lo que hace que arrastrar signifique algo
    SELECT count(DISTINCT orden) INTO v_ordenes
      FROM ecommerce.paginas_informativas WHERE deleted_at IS NULL;
    IF v_ordenes <> v_paginas THEN
        RAISE EXCEPTION 'Hay % páginas pero sólo % órdenes distintos', v_paginas, v_ordenes;
    END IF;

    -- Y ahora TODAS las visibles salen en /documentos
    v_publicas := ecommerce.fn_paginas_informativas_listar_publicas();
    v_en_lista := CASE WHEN jsonb_array_length(v_publicas) = 0 THEN 0
                       ELSE jsonb_array_length(v_publicas -> 0 -> 'paginas') END;
    IF v_en_lista <> v_activas THEN
        RAISE EXCEPTION 'Hay % páginas visibles y % en /documentos', v_activas, v_en_lista;
    END IF;

    RAISE NOTICE 'Comprobado: % páginas (% visibles), todas dinámicas y todas en /documentos.',
        v_paginas, v_activas;
END;
$comprobar$;

COMMIT;
