-- ===========================================================================
-- EL ORDEN QUE PONE EL PRODUCTO MANDA SOBRE EL DE LA PLANTILLA
-- ===========================================================================
-- Fecha: 2026-10-18
--
-- EL FALLO: en el formulario del producto se suben y bajan las
-- características, se guarda, y al volver a abrirlo salían otra vez en el
-- orden de la categoría.
--
-- La tabla guardaba bien lo que el usuario pidió —comprobado: con el orden
-- al revés, caracteristicas_productos tenía Almacenamiento=1, Memoria RAM=2,
-- Procesador=3— pero fn_productos_caracteristicas devolvía `k.orden`, que es
-- el de la PLANTILLA, y tiraba lo guardado.
--
-- CÓMO QUEDA:
--   · Las que el producto tiene rellenas van en SU orden, el que se guardó.
--   · Las de la plantilla que están vacías van detrás, en el orden de la
--     categoría. No pueden conservar posición propia porque una
--     característica sin valor no se guarda (no hay dónde apuntarla), y
--     dejarlas intercaladas con un orden inventado las haría bailar de una
--     visita a otra.
--   · Lo que el producto rellenó y ya no está en la plantilla, al final.
-- ===========================================================================

CREATE OR REPLACE FUNCTION inventarios.fn_productos_caracteristicas(p_producto_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'inventarios'
AS $function$
DECLARE
    v_categoria bigint;
    v_data      jsonb;
BEGIN
    SELECT categoria_id INTO v_categoria FROM inventarios.productos WHERE id = p_producto_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'El producto no existe' USING ERRCODE = 'P0013';
    END IF;

    SELECT COALESCE(jsonb_agg(t.fila ORDER BY t.clave_orden, t.nombre), '[]'::jsonb)
      INTO v_data
      FROM (
        -- La plantilla vigente de su categoría, con el valor si lo tiene
        SELECT jsonb_build_object(
                   'caracteristica_id', k.id,
                   'nombre',            k.nombre,
                   -- El del producto si lo guardó; si no, el de la categoría
                   'orden',             COALESCE(v.orden, k.orden),
                   'valor',             v.valor,
                   'en_plantilla',      true
               ) AS fila,
               -- Las rellenas, en su orden; las vacías detrás (el +1000), en
               -- el de la categoría
               CASE WHEN v.id IS NULL THEN 1000 + k.orden ELSE v.orden END AS clave_orden,
               k.nombre AS nombre
          FROM inventarios.caracteristicas_categorias k
          LEFT JOIN inventarios.caracteristicas_productos v
                 ON v.caracteristica_id = k.id AND v.producto_id = p_producto_id
         WHERE k.categoria_id = v_categoria
           AND k.deleted_at IS NULL
           AND k.activo

        UNION ALL

        -- Lo que el producto tiene relleno y ya no está en la plantilla: al
        -- final de todo (el +2000), que es material de otra época
        SELECT jsonb_build_object(
                   'caracteristica_id', v.caracteristica_id,
                   'nombre',            v.nombre,
                   'orden',             v.orden,
                   'valor',             v.valor,
                   'en_plantilla',      false
               ),
               2000 + v.orden,
               v.nombre
          FROM inventarios.caracteristicas_productos v
         WHERE v.producto_id = p_producto_id
           AND NOT EXISTS (
               SELECT 1 FROM inventarios.caracteristicas_categorias k
                WHERE k.id = v.caracteristica_id
                  AND k.categoria_id = v_categoria
                  AND k.deleted_at IS NULL
                  AND k.activo)
      ) t;

    RETURN jsonb_build_object('success', true, 'data', v_data);
END;
$function$;
