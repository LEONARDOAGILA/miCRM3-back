-- ============================================================================
-- ECOMMERCE · LA CATEGORÍA DEL PRODUCTO EN LA SECCIÓN PÚBLICA
-- ============================================================================
-- Fecha: 2026-11-02
--
-- Las tarjetas de las secciones de productos pasan a llevar botones de compra,
-- y la tienda tiene una regla para ellos: UNA MOTO SÓLO SE VENDE POR WHATSAPP
-- —nada de carrito ni de pago con tarjeta—, y para saber si lo es mira la
-- categoría del producto contra las de España Motos.
--
-- Sin este campo, una moto en un escaparate saldría con «Agregar al carrito» y
-- «Comprar con tarjeta», que es justo lo que la tienda evita en todas las
-- demás pantallas. No es un dato de precio: es el que decide qué botones se
-- pintan.
--
-- SIGUE SIN VIAJAR NADA DE PRECIO NI DE EXISTENCIAS. La tarjeta de la tienda
-- los lleva, pero el catálogo todavía no los tiene y media tarjeta sacaría
-- todo a $0 y «Agotado».
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
                   'imagen', (SELECT i.archivo
                                FROM inventarios.productos_imagenes i
                               WHERE i.producto_id = p.id
                               ORDER BY i.principal DESC, i.orden, i.id
                               LIMIT 1))
               ORDER BY it.orden, p.id)
          FROM ecommerce.producto_secciones_items it
          JOIN inventarios.productos p ON p.id = it.producto_id
         WHERE it.seccion_id = p_seccion_id
           AND p.deleted_at IS NULL
           AND p.activo), '[]'::jsonb);
$function$;

-- ----------------------------------------------------------------------------
-- COMPROBACIÓN
-- ----------------------------------------------------------------------------
-- Los mismos campos de antes más la categoría, y NINGUNO de precio: la lista
-- se compara entera, no se mira «si está», porque lo que hay que impedir es
-- que un día se cuele un `precio` sin que nadie lo note.
DO $comprobar$
DECLARE
    v_id       bigint;
    v_p        bigint;
    v_cat      bigint;
    v_producto jsonb;
    v_claves   text;
BEGIN
    SELECT p.id, p.categoria_id INTO v_p, v_cat
      FROM inventarios.productos p
     WHERE p.deleted_at IS NULL AND p.activo AND p.categoria_id IS NOT NULL
     ORDER BY p.id LIMIT 1;

    IF v_p IS NULL THEN
        RAISE NOTICE 'No hay productos activos con categoría; la función está.';
        RETURN;
    END IF;

    BEGIN
        v_id := (ecommerce.fn_producto_secciones_crear('ZZ categoria ' || clock_timestamp())
                 -> 'data' ->> 'id')::bigint;
        PERFORM ecommerce.fn_producto_seccion_agregar(v_id, jsonb_build_array(v_p));

        v_producto := ecommerce.fn_producto_seccion_publica(v_id) -> 0;
        v_claves := (SELECT string_agg(k, ',' ORDER BY k) FROM jsonb_object_keys(v_producto) k);

        RAISE EXCEPTION 'deshacer' USING ERRCODE = 'P0099';
    EXCEPTION WHEN SQLSTATE 'P0099' THEN
        NULL;
    END;

    IF v_producto IS NULL THEN
        RAISE EXCEPTION 'La sección de prueba no devolvió su producto';
    END IF;
    IF v_claves IS DISTINCT FROM 'categoria_id,id,imagen,nombre' THEN
        RAISE EXCEPTION 'El producto tendría que viajar con id, nombre, categoria_id e imagen y viaja con: %',
              v_claves;
    END IF;
    IF (v_producto ->> 'categoria_id')::bigint IS DISTINCT FROM v_cat THEN
        RAISE EXCEPTION 'La categoría que viaja (%) no es la del producto (%)',
              v_producto ->> 'categoria_id', v_cat;
    END IF;

    RAISE NOTICE 'Comprobado: el producto viaja con su categoría y sin nada de precio (%).', v_claves;
END
$comprobar$;

COMMIT;
