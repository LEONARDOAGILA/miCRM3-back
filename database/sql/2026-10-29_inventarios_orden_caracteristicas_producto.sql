-- ============================================================================
-- EL ORDEN QUE EL PRODUCTO LE DA A SUS CARACTERÍSTICAS
-- ============================================================================
-- Fecha: 2026-10-29
--
-- EL FALLO
--
-- En la ficha del producto se pueden arrastrar las características para
-- cambiarles el orden, pero al volver a abrir estaban como antes. Medido: el
-- arrastre y el envío son correctos —la posición llega bien al servidor—, y
-- lo que fallaba era que `fn_productos_caracteristicas_guardar` **descartaba
-- las filas sin valor**. Sin fila guardada no hay dónde apuntar la posición,
-- así que al releer esas características volvían al orden de su categoría.
--
-- Con seis de siete rellenas casi no se nota; con ninguna rellena no se
-- recordaba nada, que es justo el caso de un producto recién creado.
--
-- EL ARREGLO
--
-- Una fila de `caracteristicas_productos` pasa a significar «esta
-- característica está en la lista de este producto, EN ESTA POSICIÓN», y el
-- valor puede estar vacío. Antes significaba «tiene este valor».
--
-- Eso obliga a mirar dónde se contaba una fila como «lo tiene relleno»:
--   · fn_caracteristicas_json         -> num_productos
--   · fn_caracteristicas_nombres_json -> num_productos
--   · fn_caracteristicas_nombres_eliminar -> el portero de «está en uso»
-- En los tres se pide ahora que el valor NO esté vacío. Hasta hoy daba igual
-- porque no había filas vacías; a partir de ahora sí las hay.
--
-- Y lo requerido se comprueba contra un valor DE VERDAD, no contra la
-- presencia de la fila: si no, una requerida vacía pasaría el portero.
--
-- Idempotente.
-- ============================================================================
\set ON_ERROR_STOP on

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. GUARDAR: TAMBIÉN LAS VACÍAS, PARA RECORDAR SU SITIO
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION inventarios.fn_productos_caracteristicas_guardar(
    p_producto_id    bigint,
    p_items          jsonb,
    p_usuario_id     bigint  DEFAULT NULL,
    p_usuario_login  character varying DEFAULT NULL,
    p_usuario_nombre character varying DEFAULT NULL,
    p_ip_address     inet    DEFAULT NULL,
    p_user_agent     text    DEFAULT NULL,
    p_request_id     uuid    DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'inventarios', 'auditoria'
AS $$
DECLARE
    v_guardadas integer := 0;
    v_borradas  integer := 0;
    v_huerfano  text;
    v_malo      text;
    v_faltan    text;
    v_categoria bigint;
BEGIN
    PERFORM inventarios.fn_contexto_auditoria('inventarios.caracteristicas_productos',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    SELECT categoria_id INTO v_categoria FROM inventarios.productos WHERE id = p_producto_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'El producto no existe' USING ERRCODE = 'P0013';
    END IF;

    -- TODO lo que manda la pantalla, con valor o sin él: la fila vacía es la
    -- que recuerda en qué puesto quedó esa característica.
    CREATE TEMP TABLE IF NOT EXISTS tmp_carac_prod (
        caracteristica_id bigint,
        nombre_id         bigint,
        nombre            varchar(100),
        valor             text,
        orden             integer
    ) ON COMMIT DROP;
    DELETE FROM tmp_carac_prod;

    INSERT INTO tmp_carac_prod (caracteristica_id, nombre_id, nombre, valor, orden)
    SELECT NULLIF(e->>'caracteristica_id', '')::bigint,
           NULLIF(e->>'nombre_id', '')::bigint,
           TRIM(COALESCE(e->>'nombre', '')),
           NULLIF(TRIM(COALESCE(e->>'valor', '')), ''),
           COALESCE(NULLIF(e->>'orden', '')::integer, 1)
      FROM jsonb_array_elements(COALESCE(p_items, '[]'::jsonb)) e
     WHERE NULLIF(e->>'caracteristica_id', '') IS NOT NULL
        OR NULLIF(e->>'nombre_id', '') IS NOT NULL
        OR length(TRIM(COALESCE(e->>'nombre', ''))) > 0;

    -- Una SUELTA sin valor no es nada: no está en ninguna plantilla, así que
    -- sin valor no hay nada que recordar de ella.
    DELETE FROM tmp_carac_prod WHERE caracteristica_id IS NULL AND valor IS NULL;

    -- El nombre del diccionario
    UPDATE tmp_carac_prod t
       SET nombre_id = k.nombre_id, nombre = k.nombre
      FROM inventarios.caracteristicas_categorias k
     WHERE k.id = t.caracteristica_id;

    UPDATE tmp_carac_prod t
       SET nombre_id = n.id, nombre = n.nombre
      FROM inventarios.caracteristicas_nombres n
     WHERE t.caracteristica_id IS NULL
       AND t.nombre_id IS NULL
       AND n.deleted_at IS NULL
       AND inventarios.fn_normalizar_nombre(n.nombre) = inventarios.fn_normalizar_nombre(t.nombre);

    UPDATE tmp_carac_prod t
       SET nombre = n.nombre
      FROM inventarios.caracteristicas_nombres n
     WHERE t.nombre_id = n.id
       AND t.nombre IS DISTINCT FROM n.nombre;

    SELECT string_agg(DISTINCT t.nombre, ', ') INTO v_huerfano
      FROM tmp_carac_prod t WHERE t.nombre_id IS NULL;

    IF v_huerfano IS NOT NULL THEN
        RAISE EXCEPTION 'No está en el diccionario de características: %. Créelo en Inventarios → Nombres de característica', v_huerfano
            USING ERRCODE = 'P0016';
    END IF;

    -- ---------------------------------------------------------------
    -- LAS REQUERIDAS, CON VALOR DE VERDAD
    -- ---------------------------------------------------------------
    -- Contra el VALOR y no contra la presencia de la fila: ahora las filas
    -- vacías también llegan, y sin esto una requerida en blanco pasaría.
    SELECT string_agg(k.nombre, ', ' ORDER BY k.orden) INTO v_faltan
      FROM inventarios.caracteristicas_categorias k
     WHERE k.categoria_id = v_categoria
       AND k.deleted_at IS NULL
       AND k.activo
       AND k.requerido
       AND NOT EXISTS (SELECT 1 FROM tmp_carac_prod t
                        WHERE t.caracteristica_id = k.id AND t.valor IS NOT NULL);

    IF v_faltan IS NOT NULL THEN
        RAISE EXCEPTION 'Falta rellenar: %', v_faltan USING ERRCODE = 'P0001';
    END IF;

    -- ---------------------------------------------------------------
    -- EL VALOR, CONTRA EL TIPO (las vacías no se miran: no hay nada que mirar)
    -- ---------------------------------------------------------------
    UPDATE tmp_carac_prod t
       SET valor = replace(t.valor, ',', '.')
      FROM inventarios.caracteristicas_nombres n
     WHERE n.id = t.nombre_id AND n.tipo = 'NUMERO' AND t.valor LIKE '%,%';

    SELECT string_agg(format('«%s» tiene que ser un número y dice «%s»', t.nombre, t.valor), '; ')
      INTO v_malo
      FROM tmp_carac_prod t
      JOIN inventarios.caracteristicas_nombres n ON n.id = t.nombre_id
     WHERE n.tipo = 'NUMERO'
       AND t.valor IS NOT NULL
       AND t.valor !~ '^-?[0-9]+(\.[0-9]+)?$';

    IF v_malo IS NOT NULL THEN
        RAISE EXCEPTION '%', v_malo USING ERRCODE = 'P0015';
    END IF;

    UPDATE tmp_carac_prod t
       SET valor = CASE WHEN inventarios.fn_normalizar_nombre(t.valor) IN ('si', 's', 'true', '1')
                        THEN 'Sí' ELSE 'No' END
      FROM inventarios.caracteristicas_nombres n
     WHERE n.id = t.nombre_id AND n.tipo = 'SI_NO'
       AND t.valor IS NOT NULL
       AND inventarios.fn_normalizar_nombre(t.valor) IN ('si', 's', 'true', '1', 'no', 'n', 'false', '0');

    SELECT string_agg(format('«%s» tiene que ser Sí o No, y dice «%s»', t.nombre, t.valor), '; ')
      INTO v_malo
      FROM tmp_carac_prod t
      JOIN inventarios.caracteristicas_nombres n ON n.id = t.nombre_id
     WHERE n.tipo = 'SI_NO' AND t.valor IS NOT NULL AND t.valor NOT IN ('Sí', 'No');

    IF v_malo IS NOT NULL THEN
        RAISE EXCEPTION '%', v_malo USING ERRCODE = 'P0015';
    END IF;

    SELECT string_agg(format('«%s» tiene que ser una de: %s', t.nombre,
                             array_to_string(k.valores_lista, ', ')), '; ')
      INTO v_malo
      FROM tmp_carac_prod t
      JOIN inventarios.caracteristicas_categorias k ON k.id = t.caracteristica_id
      JOIN inventarios.caracteristicas_nombres n ON n.id = k.nombre_id
     WHERE n.tipo = 'LISTA'
       AND t.valor IS NOT NULL
       AND COALESCE(array_length(k.valores_lista, 1), 0) > 0
       AND NOT EXISTS (SELECT 1 FROM unnest(k.valores_lista) o
                        WHERE inventarios.fn_normalizar_nombre(o)
                            = inventarios.fn_normalizar_nombre(t.valor));

    IF v_malo IS NOT NULL THEN
        RAISE EXCEPTION '%', v_malo USING ERRCODE = 'P0015';
    END IF;

    -- La opción, tal como está escrita en la categoría
    UPDATE tmp_carac_prod t
       SET valor = o.opcion
      FROM inventarios.caracteristicas_categorias k
      JOIN inventarios.caracteristicas_nombres n ON n.id = k.nombre_id
      CROSS JOIN LATERAL unnest(k.valores_lista) AS o(opcion)
     WHERE k.id = t.caracteristica_id
       AND n.tipo = 'LISTA'
       AND t.valor IS NOT NULL
       AND inventarios.fn_normalizar_nombre(o.opcion) = inventarios.fn_normalizar_nombre(t.valor)
       AND o.opcion IS DISTINCT FROM t.valor;

    -- ---------------------------------------------------------------

    -- Fuera lo que ya no está en la lista que mandó la pantalla
    DELETE FROM inventarios.caracteristicas_productos v
     WHERE v.producto_id = p_producto_id
       AND NOT EXISTS (
           SELECT 1 FROM tmp_carac_prod t
            WHERE (t.caracteristica_id IS NOT NULL AND t.caracteristica_id = v.caracteristica_id)
               OR (t.caracteristica_id IS NULL AND v.caracteristica_id IS NULL
                   AND (t.nombre_id = v.nombre_id
                     OR (v.nombre_id IS NULL
                         AND UPPER(TRIM(t.nombre)) = UPPER(TRIM(v.nombre))))));
    GET DIAGNOSTICS v_borradas = ROW_COUNT;

    INSERT INTO inventarios.caracteristicas_productos
                (producto_id, caracteristica_id, nombre_id, nombre, valor, orden)
    SELECT p_producto_id, t.caracteristica_id, t.nombre_id, t.nombre, t.valor, t.orden
      FROM tmp_carac_prod t
     WHERE t.caracteristica_id IS NOT NULL
        ON CONFLICT (producto_id, caracteristica_id) WHERE caracteristica_id IS NOT NULL
        DO UPDATE SET nombre_id = EXCLUDED.nombre_id,
                      nombre    = EXCLUDED.nombre,
                      valor     = EXCLUDED.valor,
                      orden     = EXCLUDED.orden;
    GET DIAGNOSTICS v_guardadas = ROW_COUNT;

    INSERT INTO inventarios.caracteristicas_productos
                (producto_id, caracteristica_id, nombre_id, nombre, valor, orden)
    SELECT p_producto_id, NULL, t.nombre_id, t.nombre, t.valor, t.orden
      FROM tmp_carac_prod t
     WHERE t.caracteristica_id IS NULL
        ON CONFLICT (producto_id, nombre_id)
             WHERE caracteristica_id IS NULL AND nombre_id IS NOT NULL
        DO UPDATE SET nombre = EXCLUDED.nombre,
                      valor  = EXCLUDED.valor,
                      orden  = EXCLUDED.orden;

    RETURN jsonb_build_object('success', true,
        'message', 'Características guardadas',
        'data', jsonb_build_object('guardadas', v_guardadas, 'borradas', v_borradas));
END;
$$;

-- ---------------------------------------------------------------------------
-- 2. CONTAR «RELLENA» ES CONTAR VALOR, NO CONTAR FILA
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION inventarios.fn_caracteristicas_json(p_id bigint)
RETURNS jsonb
LANGUAGE sql
STABLE SECURITY DEFINER
AS $$
    WITH RECURSIVE subida AS (
        SELECT c.id, c.padre_id, c.nombre, 0 AS salto
          FROM inventarios.categorias c
          JOIN inventarios.caracteristicas_categorias k ON k.categoria_id = c.id
         WHERE k.id = p_id
        UNION ALL
        SELECT p.id, p.padre_id, p.nombre, s.salto + 1
          FROM inventarios.categorias p JOIN subida s ON p.id = s.padre_id
    )
    SELECT jsonb_build_object(
        'id',             k.id,
        'categoria_id',   k.categoria_id,
        'categoria_nombre', c.nombre,
        'categoria_ruta', (SELECT string_agg(s.nombre, ' > ' ORDER BY s.salto DESC) FROM subida s),
        'nombre_id',      k.nombre_id,
        'nombre',         k.nombre,
        'unidad',         n.unidad,
        'etiqueta',       n.nombre || COALESCE(' (' || n.unidad || ')', ''),
        'tipo',           n.tipo,
        'tipo_nombre',    CASE n.tipo WHEN 'TEXTO'  THEN 'Texto'
                                      WHEN 'NUMERO' THEN 'Número'
                                      WHEN 'SI_NO'  THEN 'Sí / No'
                                      WHEN 'LISTA'  THEN 'Lista'
                                      ELSE n.tipo END,
        'valores_lista',  COALESCE(to_jsonb(k.valores_lista), 'null'::jsonb),
        'orden',          k.orden,
        'activo',         k.activo,
        'requerido',      k.requerido,
        -- RELLENA = con valor. Desde que el producto guarda también su ORDEN,
        -- hay filas sin valor y contar filas diría de más.
        'num_productos',  (SELECT COUNT(*) FROM inventarios.caracteristicas_productos v
                            JOIN inventarios.productos p ON p.id = v.producto_id
                           WHERE v.caracteristica_id = k.id AND p.deleted_at IS NULL
                             AND NULLIF(TRIM(v.valor), '') IS NOT NULL),
        'num_sin_valor',  (SELECT COUNT(*) FROM inventarios.productos p
                           WHERE p.categoria_id = k.categoria_id
                             AND p.deleted_at IS NULL
                             AND NOT EXISTS (SELECT 1 FROM inventarios.caracteristicas_productos v
                                              WHERE v.producto_id = p.id
                                                AND v.caracteristica_id = k.id
                                                AND NULLIF(TRIM(v.valor), '') IS NOT NULL)),
        'deleted_at',     to_char(k.deleted_at, 'YYYY-MM-DD HH24:MI:SS'),
        'deleted_by',     k.deleted_by,
        'created_by',     k.created_by,
        'updated_by',     k.updated_by,
        'created_at',     to_char(k.created_at, 'YYYY-MM-DD HH24:MI:SS'),
        'updated_at',     to_char(k.updated_at, 'YYYY-MM-DD HH24:MI:SS')
    )
      FROM inventarios.caracteristicas_categorias k
      JOIN inventarios.categorias c ON c.id = k.categoria_id
      JOIN inventarios.caracteristicas_nombres n ON n.id = k.nombre_id
     WHERE k.id = p_id;
$$;

CREATE OR REPLACE FUNCTION inventarios.fn_caracteristicas_nombres_json(p_id bigint)
RETURNS jsonb
LANGUAGE sql
STABLE SECURITY DEFINER
AS $$
    SELECT jsonb_build_object(
        'id',          n.id,
        'nombre',      n.nombre,
        'unidad',      n.unidad,
        'etiqueta',    n.nombre || COALESCE(' (' || n.unidad || ')', ''),
        'tipo',        n.tipo,
        'tipo_nombre', CASE n.tipo WHEN 'TEXTO'  THEN 'Texto'
                                   WHEN 'NUMERO' THEN 'Número'
                                   WHEN 'SI_NO'  THEN 'Sí / No'
                                   WHEN 'LISTA'  THEN 'Lista'
                                   ELSE n.tipo END,
        'descripcion', n.descripcion,
        'activo',      n.activo,
        'num_categorias', (SELECT COUNT(*) FROM inventarios.caracteristicas_categorias k
                            WHERE k.nombre_id = n.id AND k.deleted_at IS NULL),
        -- Rellena = con valor, igual que arriba
        'num_productos',  (SELECT COUNT(*) FROM inventarios.caracteristicas_productos v
                             JOIN inventarios.productos p ON p.id = v.producto_id
                            WHERE v.nombre_id = n.id AND p.deleted_at IS NULL
                              AND NULLIF(TRIM(v.valor), '') IS NOT NULL),
        'deleted_at',  to_char(n.deleted_at, 'YYYY-MM-DD HH24:MI:SS'),
        'deleted_by',  n.deleted_by,
        'created_by',  n.created_by,
        'updated_by',  n.updated_by,
        'created_at',  to_char(n.created_at, 'YYYY-MM-DD HH24:MI:SS'),
        'updated_at',  to_char(n.updated_at, 'YYYY-MM-DD HH24:MI:SS')
    )
      FROM inventarios.caracteristicas_nombres n
     WHERE n.id = p_id;
$$;

-- ---------------------------------------------------------------------------
-- 3. EL PORTERO DE «ESTÁ EN USO», IGUAL
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION inventarios.fn_caracteristicas_nombres_eliminar(
    p_id             bigint,
    p_usuario_id     bigint  DEFAULT NULL,
    p_usuario_login  varchar DEFAULT NULL,
    p_usuario_nombre varchar DEFAULT NULL,
    p_ip_address     inet    DEFAULT NULL,
    p_user_agent     text    DEFAULT NULL,
    p_request_id     uuid    DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'inventarios', 'auditoria'
AS $$
DECLARE
    v_nombre     varchar;
    v_categorias integer;
    v_productos  integer;
    v_quien      varchar;
    v_antes      jsonb;
BEGIN
    PERFORM inventarios.fn_contexto_auditoria('inventarios.caracteristicas_nombres',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    SELECT nombre INTO v_nombre FROM inventarios.caracteristicas_nombres
     WHERE id = p_id AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'El nombre de característica no existe o ya está en la papelera' USING ERRCODE = 'P0013';
    END IF;

    SELECT COUNT(*) INTO v_categorias
      FROM inventarios.caracteristicas_categorias k
     WHERE k.nombre_id = p_id AND k.deleted_at IS NULL;

    IF v_categorias > 0 THEN
        RAISE EXCEPTION 'No se puede eliminar «%»: lo usan % %. Quítelo de esas categorías primero',
            v_nombre, v_categorias,
            CASE WHEN v_categorias = 1 THEN 'categoría' ELSE 'categorías' END
            USING ERRCODE = 'P0021';
    END IF;

    -- Con VALOR: una fila vacía sólo guarda una posición, y eso no es usarlo
    SELECT COUNT(*) INTO v_productos
      FROM inventarios.caracteristicas_productos v
      JOIN inventarios.productos p ON p.id = v.producto_id
     WHERE v.nombre_id = p_id AND p.deleted_at IS NULL
       AND NULLIF(TRIM(v.valor), '') IS NOT NULL;

    IF v_productos > 0 THEN
        RAISE EXCEPTION 'No se puede eliminar «%»: % % lo tienen relleno',
            v_nombre, v_productos,
            CASE WHEN v_productos = 1 THEN 'producto' ELSE 'productos' END
            USING ERRCODE = 'P0021';
    END IF;

    v_quien := COALESCE(p_usuario_nombre, p_usuario_login, 'SISTEMA');
    v_antes := inventarios.fn_caracteristicas_nombres_json(p_id);

    PERFORM set_config('app.datos_anteriores', v_antes::text, true);
    PERFORM set_config('app.datos_nuevos',
        (v_antes || jsonb_build_object('deleted_by', v_quien))::text, true);

    UPDATE inventarios.caracteristicas_nombres
       SET deleted_at = CURRENT_TIMESTAMP, deleted_by = v_quien
     WHERE id = p_id;

    PERFORM set_config('app.datos_anteriores', '', true);
    PERFORM set_config('app.datos_nuevos', '', true);

    RETURN jsonb_build_object('success', true,
        'message', 'Nombre «' || v_nombre || '» enviado a la papelera de reciclaje',
        'data', inventarios.fn_caracteristicas_nombres_json(p_id));
END;
$$;

COMMIT;
