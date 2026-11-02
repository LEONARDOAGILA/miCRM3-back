-- ============================================================================
-- ECOMMERCE · LA SEGUNDA FOTO DEL PRODUCTO EN LA SECCIÓN PÚBLICA
-- ============================================================================
-- Fecha: 2026-11-02
--
-- Las tarjetas de las secciones de productos cambian de foto al pasar el mouse
-- por encima: la principal y, debajo, la siguiente. Es el gesto de siempre en
-- una tienda —ver el producto por el otro lado sin entrar en la ficha— y aquí
-- vale todavía más, porque la ficha del producto aún no se puede abrir.
--
-- VAN DOS, NO LA GALERÍA ENTERA. La tarjeta sólo enseña dos y mandar seis
-- serían seis direcciones por producto que el navegador se pondría a descargar
-- para no usar cuatro. Cuando la tarjeta de verdad esté (con su carrusel de
-- carátulas) ya se mandará la lista completa.
--
-- CUÁL ES CADA UNA: la principal es la marcada como tal y, si no hay ninguna
-- marcada, la primera de su orden; la segunda es la siguiente de ese mismo
-- orden. Un producto con una sola foto viaja con `imagen_secundaria` en null y
-- la tienda no hace el cambio: no se inventa un efecto con la misma imagen.
--
-- SIGUE SIN VIAJAR NADA DE PRECIO NI DE EXISTENCIAS.
--
-- Idempotente.
-- ============================================================================
\set ON_ERROR_STOP on

BEGIN;

CREATE OR REPLACE FUNCTION ecommerce.fn_producto_seccion_publica(p_seccion_id bigint)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
AS $function$
    SELECT COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
                   'id',     p.id,
                   'nombre', p.nombre,
                   -- La del catálogo. La tienda la usa SÓLO para saber si el
                   -- producto es una moto y enseñar nada más el botón de
                   -- WhatsApp; no se pinta en ningún sitio.
                   'categoria_id', p.categoria_id,
                   -- Las dos primeras de su galería, en el mismo orden con el
                   -- que se eligen en el CRM. Una sola consulta con LIMIT 2 y
                   -- no dos subconsultas: así no hay forma de que la «segunda»
                   -- acabe siendo la misma que la primera.
                   'imagen',             fotos.primera,
                   'imagen_secundaria',  fotos.segunda)
               ORDER BY it.orden, p.id)
          FROM ecommerce.producto_secciones_items it
          JOIN inventarios.productos p ON p.id = it.producto_id
          LEFT JOIN LATERAL (
              SELECT min(g.archivo) FILTER (WHERE g.puesto = 1) AS primera,
                     min(g.archivo) FILTER (WHERE g.puesto = 2) AS segunda
                FROM (SELECT i.archivo,
                             row_number() OVER (ORDER BY i.principal DESC, i.orden, i.id) AS puesto
                        FROM inventarios.productos_imagenes i
                       WHERE i.producto_id = p.id) g
               WHERE g.puesto <= 2
          ) fotos ON true
         WHERE it.seccion_id = p_seccion_id
           AND p.deleted_at IS NULL
           AND p.activo), '[]'::jsonb);
$function$;

-- ----------------------------------------------------------------------------
-- COMPROBACIÓN
-- ----------------------------------------------------------------------------
-- Con un producto de DOS fotos o más: que lleguen dos y que no sean la misma.
-- Con uno de una sola: que la segunda venga vacía. Y la lista de campos
-- entera, para que no se cuele nunca un precio sin que nadie lo note.
DO $comprobar$
DECLARE
    v_id       bigint;
    v_varias   bigint;
    v_una      bigint;
    v_dos      jsonb;
    v_sola     jsonb;
    v_claves   text;
BEGIN
    SELECT p.id INTO v_varias
      FROM inventarios.productos p
     WHERE p.deleted_at IS NULL AND p.activo
       AND (SELECT count(*) FROM inventarios.productos_imagenes i WHERE i.producto_id = p.id) >= 2
     ORDER BY p.id LIMIT 1;

    SELECT p.id INTO v_una
      FROM inventarios.productos p
     WHERE p.deleted_at IS NULL AND p.activo
       AND (SELECT count(*) FROM inventarios.productos_imagenes i WHERE i.producto_id = p.id) = 1
     ORDER BY p.id LIMIT 1;

    IF v_varias IS NULL THEN
        RAISE NOTICE 'No hay ningún producto con dos fotos; la función está puesta.';
        RETURN;
    END IF;

    BEGIN
        v_id := (ecommerce.fn_producto_secciones_crear('ZZ dos fotos ' || clock_timestamp())
                 -> 'data' ->> 'id')::bigint;
        PERFORM ecommerce.fn_producto_seccion_agregar(v_id,
                    jsonb_build_array(v_varias) || CASE WHEN v_una IS NULL THEN '[]'::jsonb
                                                        ELSE jsonb_build_array(v_una) END);

        SELECT x INTO v_dos
          FROM jsonb_array_elements(ecommerce.fn_producto_seccion_publica(v_id)) x
         WHERE (x ->> 'id')::bigint = v_varias;

        IF v_una IS NOT NULL THEN
            SELECT x INTO v_sola
              FROM jsonb_array_elements(ecommerce.fn_producto_seccion_publica(v_id)) x
             WHERE (x ->> 'id')::bigint = v_una;
        END IF;

        v_claves := (SELECT string_agg(k, ',' ORDER BY k) FROM jsonb_object_keys(v_dos) k);

        RAISE EXCEPTION 'deshacer' USING ERRCODE = 'P0099';
    EXCEPTION WHEN SQLSTATE 'P0099' THEN
        NULL;
    END;

    IF v_dos IS NULL THEN
        RAISE EXCEPTION 'El producto de dos fotos no salió en la sección';
    END IF;
    IF v_claves IS DISTINCT FROM 'categoria_id,id,imagen,imagen_secundaria,nombre' THEN
        RAISE EXCEPTION 'Los campos que viajan cambiaron: %', v_claves;
    END IF;
    IF (v_dos ->> 'imagen') IS NULL OR (v_dos ->> 'imagen_secundaria') IS NULL THEN
        RAISE EXCEPTION 'Un producto con dos fotos tiene que traer las dos (% / %)',
              v_dos ->> 'imagen', v_dos ->> 'imagen_secundaria';
    END IF;
    IF (v_dos ->> 'imagen') = (v_dos ->> 'imagen_secundaria') THEN
        RAISE EXCEPTION 'La segunda foto no puede ser la misma que la primera: %',
              v_dos ->> 'imagen';
    END IF;
    IF v_una IS NOT NULL THEN
        IF v_sola IS NULL OR (v_sola ->> 'imagen') IS NULL THEN
            RAISE EXCEPTION 'El producto de una foto tendría que traer la suya';
        END IF;
        IF (v_sola ->> 'imagen_secundaria') IS NOT NULL THEN
            RAISE EXCEPTION 'Con una sola foto, la segunda tiene que venir vacía y vino: %',
                  v_sola ->> 'imagen_secundaria';
        END IF;
    END IF;

    RAISE NOTICE 'Comprobado: con dos fotos llegan las dos y son distintas (% y %); con una, la segunda viene vacía.',
          v_dos ->> 'imagen', v_dos ->> 'imagen_secundaria';
END
$comprobar$;

COMMIT;
