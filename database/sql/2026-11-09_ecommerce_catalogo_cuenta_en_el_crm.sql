-- ============================================================================
-- EL CATÁLOGO, CONTADO BIEN EN LA LISTA DEL CRM
-- ============================================================================
-- Recién convertido /shop en página, su sección de catálogo salía en el CRM
-- con dos avisos falsos:
--
--   · «Falta su fuente» —cuando su fuente son todos los productos publicados—
--   · «No sale: está vacía» —con 263 productos detrás—
--
-- Los dos salen de `fn_inicio_listar`, que calcula cuántas cosas tiene cada
-- sección y si tiene alguna. Su CASE no conocía el tipo `catalogo` y caía en
-- el `ELSE false`, que es «no tiene nada».
--
-- ----------------------------------------------------------------------------
-- Y DE PASO, LOS ESCAPARATES DICEN LA VERDAD
-- ----------------------------------------------------------------------------
-- El aviso «No sale: está vacía» existe para avisar de una sección encendida
-- que la tienda se va a saltar. Un escaparate cuyos productos estén todos
-- inactivos o fuera de la web es exactamente eso, y hasta ahora se contaba
-- como lleno: contaba los productos que NO están en la papelera, nada más.
--
-- Ahora cuenta los que la tienda va a enseñar de verdad —`activo AND
-- en_paginaweb`—, que es la misma regla que aplica `fn_producto_seccion_publica`.
--
-- ----------------------------------------------------------------------------
-- SE EJECUTA A MANO. Para ensayar, cambiar el COMMIT del final por ROLLBACK.
-- ============================================================================

BEGIN;

CREATE OR REPLACE FUNCTION pg_temp.parchar(p_texto text, p_viejo text, p_nuevo text, p_donde text)
RETURNS text
LANGUAGE plpgsql
AS $parchar$
DECLARE
    v_veces int;
BEGIN
    v_veces := (length(p_texto) - length(replace(p_texto, p_viejo, '')))
               / GREATEST(length(p_viejo), 1);

    IF v_veces <> 1 THEN
        RAISE EXCEPTION 'Parche de %: esperaba UNA aparición de «%…» y encontré %',
              p_donde, left(p_viejo, 70), v_veces;
    END IF;

    RETURN replace(p_texto, p_viejo, p_nuevo);
END;
$parchar$;


DO $listar$
DECLARE
    v_firma text := 'ecommerce.fn_inicio_listar(bigint)';
    v_def   text;
BEGIN
    BEGIN
        v_def := pg_get_functiondef(v_firma::regprocedure);
    EXCEPTION WHEN undefined_function THEN
        -- Sin parámetro, que es como estaba antes de las páginas
        v_firma := 'ecommerce.fn_inicio_listar()';
        v_def   := pg_get_functiondef(v_firma::regprocedure);
    END;

    -- ---------- 1. Cuántos productos enseña el catálogo ----------
    v_def := pg_temp.parchar(v_def,
        E'                           WHEN ''productos'' THEN\n'
        || E'                               (SELECT count(*)\n'
        || E'                                  FROM ecommerce.producto_secciones_items it\n'
        || E'                                  JOIN inventarios.productos p ON p.id = it.producto_id\n'
        || E'                                 WHERE it.seccion_id = s.producto_seccion_id\n'
        || E'                                   AND p.deleted_at IS NULL)',
        E'                           WHEN ''productos'' THEN\n'
        || E'                               (SELECT count(*)\n'
        || E'                                  FROM ecommerce.producto_secciones_items it\n'
        || E'                                  JOIN inventarios.productos p ON p.id = it.producto_id\n'
        || E'                                 WHERE it.seccion_id = s.producto_seccion_id\n'
        || E'                                   AND p.deleted_at IS NULL\n'
        || E'                                   -- Los que la tienda va a enseñar DE VERDAD: un\n'
        || E'                                   -- escaparate lleno de productos apagados es un\n'
        || E'                                   -- escaparate que la tienda se salta\n'
        || E'                                   AND p.activo AND p.en_paginaweb)\n'
        || E'                           -- El catálogo no se llena a mano: son todos los publicados\n'
        || E'                           WHEN ''catalogo'' THEN\n'
        || E'                               (SELECT count(*) FROM inventarios.productos p\n'
        || E'                                 WHERE p.deleted_at IS NULL AND p.activo AND p.en_paginaweb)',
        'fn_inicio_listar (cuantas)');

    -- ---------- 2. Si tiene algo que enseñar ----------
    v_def := pg_temp.parchar(v_def,
        E'                           WHEN ''productos'' THEN\n'
        || E'                               EXISTS (SELECT 1\n'
        || E'                                         FROM ecommerce.producto_secciones_items it\n'
        || E'                                         JOIN inventarios.productos p ON p.id = it.producto_id\n'
        || E'                                        WHERE it.seccion_id = s.producto_seccion_id\n'
        || E'                                          AND p.deleted_at IS NULL)\n'
        || E'                           ELSE false END)',
        E'                           WHEN ''productos'' THEN\n'
        || E'                               EXISTS (SELECT 1\n'
        || E'                                         FROM ecommerce.producto_secciones_items it\n'
        || E'                                         JOIN inventarios.productos p ON p.id = it.producto_id\n'
        || E'                                        WHERE it.seccion_id = s.producto_seccion_id\n'
        || E'                                          AND p.deleted_at IS NULL\n'
        || E'                                          AND p.activo AND p.en_paginaweb)\n'
        || E'                           WHEN ''catalogo'' THEN\n'
        || E'                               EXISTS (SELECT 1 FROM inventarios.productos p\n'
        || E'                                        WHERE p.deleted_at IS NULL AND p.activo AND p.en_paginaweb)\n'
        || E'                           ELSE false END)',
        'fn_inicio_listar (con_contenido)');

    EXECUTE v_def;
END;
$listar$;


-- ============================================================================
-- COMPROBACIÓN — no escribe nada
-- ============================================================================
DO $comprobar$
DECLARE
    v_falta    text[] := '{}';
    v_id       bigint;
    v_lista    jsonb;
    v_catalogo jsonb;
    v_publicados int;
BEGIN
    SELECT id INTO v_id FROM ecommerce.cuerpos WHERE ruta = 'shop' AND deleted_at IS NULL;
    IF v_id IS NULL THEN
        RAISE EXCEPTION 'No hay página en /shop: esta migración va DESPUÉS de la que la crea';
    END IF;

    SELECT count(*) INTO v_publicados FROM inventarios.productos
     WHERE deleted_at IS NULL AND activo AND en_paginaweb;

    v_lista := ecommerce.fn_inicio_listar(v_id);

    -- `data` ES YA la lista de secciones, no un objeto que la contenga
    IF jsonb_typeof(v_lista -> 'data') <> 'array' THEN
        RAISE EXCEPTION 'fn_inicio_listar cambió de forma: `data` es % y se esperaba una lista',
              jsonb_typeof(v_lista -> 'data');
    END IF;

    SELECT s INTO v_catalogo
      FROM jsonb_array_elements(v_lista -> 'data') s
     WHERE s ->> 'clave' = 'catalogo';

    IF v_catalogo IS NULL THEN
        v_falta := array_append(v_falta, 'fn_inicio_listar no devuelve la sección «catalogo» de /shop');
    ELSE
        IF (v_catalogo -> 'fuente' ->> 'tipo') IS DISTINCT FROM 'catalogo' THEN
            v_falta := v_falta || format('su fuente dice «%s» y debería decir «catalogo»',
                                         v_catalogo -> 'fuente' ->> 'tipo');
        END IF;

        IF (v_catalogo ->> 'con_contenido')::boolean IS NOT TRUE THEN
            v_falta := array_append(v_falta, 'el catálogo sigue saliendo como «está vacía»');
        END IF;

        IF (v_catalogo ->> 'cuantas')::int IS DISTINCT FROM v_publicados THEN
            v_falta := v_falta || format('cuenta %s productos y hay %s publicados',
                                         v_catalogo ->> 'cuantas', v_publicados);
        END IF;
    END IF;

    IF cardinality(v_falta) > 0 THEN
        RAISE EXCEPTION E'NO QUEDÓ BIEN:\n  · %', array_to_string(v_falta, E'\n  · ');
    END IF;

    RAISE NOTICE 'El catálogo de /shop se cuenta bien: % productos publicados.', v_publicados;
END;
$comprobar$;

COMMIT;
