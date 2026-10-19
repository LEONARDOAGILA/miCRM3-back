-- ===========================================================================
-- REORDENAR LAS CARACTERÍSTICAS DE UNA CATEGORÍA ARRASTRANDO LAS FILAS
-- ===========================================================================
-- Fecha: 2026-10-18
--
-- En la pantalla de Características (inventarios/allCaracteristicas) se elige
-- una categoría en el árbol de la izquierda y la rejilla de la derecha enseña
-- su lista. Ese orden es el que ve después quien rellena un producto, así que
-- se cambia arrastrando las filas; esto es lo que lo guarda.
--
-- POR QUÉ NO SE RENUMERA 1..N. La rejilla pagina en el servidor: lo que se
-- arrastra es la PÁGINA, no la categoría entera. Si una categoría tuviera 20
-- características, al reordenar las 15 de la primera página y renumerarlas
-- 1..15 se pisaría el sitio de las otras cinco.
--
-- Lo que se hace es repartir entre las filas de la lista los MISMOS números
-- de orden que ya tenían, empezando por el más bajo. Como el listado sale
-- ordenado por `orden`, las filas de una página ocupan un tramo seguido:
-- barajar los números dentro de ese tramo nunca se mete en el de las demás.
--
--   antes:  Capacidad 1 · Tipo de puerta 2 · Color 3
--   se arrastra Color arriba del todo
--   después: Color 1 · Capacidad 2 · Tipo de puerta 3
--
-- NO vale para mover una característica de categoría: eso es modificarla, y
-- se hace en su formulario. Aquí, si la lista trae ids de dos categorías, se
-- rechaza.
-- ===========================================================================

CREATE OR REPLACE FUNCTION inventarios.fn_caracteristicas_ordenar(
    p_ids            jsonb,                 -- los ids EN EL ORDEN NUEVO
    p_usuario_id     bigint  DEFAULT NULL,
    p_usuario_login  varchar DEFAULT NULL,
    p_usuario_nombre varchar DEFAULT NULL,
    p_ip_address     inet    DEFAULT NULL,
    p_user_agent     text    DEFAULT NULL,
    p_request_id     uuid    DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'inventarios', 'auditoria'
AS $function$
DECLARE
    v_pedidas    integer;
    v_distintas  integer;
    v_reales     integer;
    v_categorias integer;
    v_categoria  bigint;
    v_min        integer;
    v_cambiadas  integer;
BEGIN
    PERFORM inventarios.fn_contexto_auditoria('inventarios.caracteristicas_categorias',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    IF p_ids IS NULL OR jsonb_typeof(p_ids) <> 'array' OR jsonb_array_length(p_ids) < 2 THEN
        RAISE EXCEPTION 'Hacen falta al menos dos características para cambiar el orden'
            USING ERRCODE = 'P0001';
    END IF;

    v_pedidas := jsonb_array_length(p_ids);

    -- Un id repetido haría que dos filas pelearan por el mismo sitio
    SELECT COUNT(DISTINCT (t.valor)::bigint) INTO v_distintas
      FROM jsonb_array_elements_text(p_ids) AS t(valor);

    IF v_distintas <> v_pedidas THEN
        RAISE EXCEPTION 'La lista trae características repetidas' USING ERRCODE = 'P0015';
    END IF;

    -- Tienen que existir TODAS, estar vigentes y ser de la MISMA categoría
    SELECT COUNT(*), COUNT(DISTINCT k.categoria_id), MIN(k.categoria_id), MIN(k.orden)
      INTO v_reales, v_categorias, v_categoria, v_min
      FROM inventarios.caracteristicas_categorias k
     WHERE k.id IN (SELECT (jsonb_array_elements_text(p_ids))::bigint)
       AND k.deleted_at IS NULL;

    IF v_reales <> v_pedidas THEN
        RAISE EXCEPTION 'Alguna de esas características ya no existe o está en la papelera de reciclaje'
            USING ERRCODE = 'P0013';
    END IF;

    IF v_categorias > 1 THEN
        RAISE EXCEPTION 'Sólo se puede cambiar el orden dentro de una misma categoría'
            USING ERRCODE = 'P0015';
    END IF;

    -- El tramo de números que ya ocupaban, repartido en el orden pedido
    WITH pedido AS (
        SELECT (t.valor)::bigint AS id, t.n AS posicion
          FROM jsonb_array_elements_text(p_ids) WITH ORDINALITY AS t(valor, n)
    )
    UPDATE inventarios.caracteristicas_categorias k
       SET orden = v_min + (p.posicion - 1)::integer
      FROM pedido p
     WHERE k.id = p.id
       -- Sólo las que de verdad cambian: así no se audita una fila que se
       -- quedó donde estaba ni se le toca el updated_at
       AND k.orden IS DISTINCT FROM v_min + (p.posicion - 1)::integer;

    GET DIAGNOSTICS v_cambiadas = ROW_COUNT;

    RETURN jsonb_build_object(
        'success', true,
        'message', CASE WHEN v_cambiadas = 0 THEN 'El orden ya era ese'
                        ELSE 'Orden guardado' END,
        'data', jsonb_build_object(
            'categoria_id', v_categoria,
            'cambiadas',    v_cambiadas,
            -- La categoría entera, ya ordenada: la rejilla repinta con esto
            'caracteristicas', (
                SELECT COALESCE(jsonb_agg(inventarios.fn_caracteristicas_json(k.id)
                                          ORDER BY k.orden, k.id), '[]'::jsonb)
                  FROM inventarios.caracteristicas_categorias k
                 WHERE k.categoria_id = v_categoria
                   AND k.deleted_at IS NULL)));
END;
$function$;

COMMENT ON FUNCTION inventarios.fn_caracteristicas_ordenar(jsonb, bigint, varchar, varchar, inet, text, uuid)
IS 'Cambia el orden de varias características de una misma categoría: reparte entre ellas los números de orden que ya ocupaban, en el orden en que llegan los ids.';
