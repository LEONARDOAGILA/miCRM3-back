-- ============================================================================
-- CARACTERÍSTICAS REQUERIDAS
-- ============================================================================
-- Fecha: 2026-10-28
-- Va después de `2026-10-28_inventarios_caracteristicas_valor_por_tipo.sql`.
--
-- Una característica de la plantilla puede marcarse como REQUERIDA: entonces
-- el producto de esa categoría no se puede guardar sin ella. Es lo mismo que
-- ya hace `activo` —una palanca por fila— pero para otra pregunta: `activo`
-- dice si se PIDE, `requerido` dice si se puede dejar en blanco.
--
-- Las dos se miran juntas: lo inactivo no se pide, así que tampoco se exige
-- aunque esté marcado como requerido. Y lo que está en la papelera, igual.
--
-- EL PORTERO ESTÁ EN `fn_productos_caracteristicas_guardar`, no en la
-- pantalla: la ficha del producto avisa antes (es más cómodo), pero quien no
-- deja guardar es el servidor, que es el único al que no se le puede dar la
-- vuelta.
--
-- OJO CON LO QUE YA EXISTE: marcar requerida una característica que los
-- productos de esa categoría tienen vacía hace que esos productos no se
-- puedan guardar hasta rellenarla. Es lo que se ha pedido, pero conviene
-- saberlo antes de marcar media plantilla.
--
-- Idempotente.
-- ============================================================================
\set ON_ERROR_STOP on

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. LA COLUMNA
-- ---------------------------------------------------------------------------
ALTER TABLE inventarios.caracteristicas_categorias
    ADD COLUMN IF NOT EXISTS requerido boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN inventarios.caracteristicas_categorias.requerido IS
  'Si el producto de esta categoría no se puede guardar sin ella. Sólo cuenta si además está activa.';

-- ---------------------------------------------------------------------------
-- 2. EL JSON
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
        -- Lo que se enseña al rellenar el producto: «Potencia (W)»
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
        -- Cuántos productos la tienen rellena: es lo que avisa de que tocarla
        -- no es gratis
        'num_productos',  (SELECT COUNT(*) FROM inventarios.caracteristicas_productos v
                            JOIN inventarios.productos p ON p.id = v.producto_id
                           WHERE v.caracteristica_id = k.id AND p.deleted_at IS NULL),
        -- Y cuántos de su categoría la tienen VACÍA: es lo que dice cuánto
        -- cuesta marcarla requerida (esos no se podrán guardar sin rellenarla)
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

-- ---------------------------------------------------------------------------
-- 3. CREAR Y MODIFICAR
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS inventarios.fn_caracteristicas_crear(
    bigint, bigint, text[], integer, boolean, bigint,
    character varying, character varying, inet, text, uuid);

CREATE OR REPLACE FUNCTION inventarios.fn_caracteristicas_crear(
    p_categoria_id   bigint,
    p_nombre_id      bigint,
    p_valores_lista  text[]  DEFAULT NULL,
    p_orden          integer DEFAULT NULL,
    p_activo         boolean DEFAULT true,
    p_requerido      boolean DEFAULT false,
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
    v_id      bigint;
    v_orden   integer;
    v_nombre  varchar;
    v_tipo    varchar;
    v_valores text[];
    v_nuevo   jsonb;
BEGIN
    PERFORM inventarios.fn_contexto_auditoria('inventarios.caracteristicas_categorias',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    SELECT n.nombre, n.tipo INTO v_nombre, v_tipo
      FROM inventarios.caracteristicas_nombres n
     WHERE n.id = p_nombre_id AND n.deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Elija un nombre del diccionario de características' USING ERRCODE = 'P0001';
    END IF;

    IF p_categoria_id IS NULL OR NOT EXISTS (SELECT 1 FROM inventarios.categorias
                                              WHERE id = p_categoria_id AND deleted_at IS NULL) THEN
        RAISE EXCEPTION 'La categoría indicada no existe' USING ERRCODE = 'P0016';
    END IF;

    -- Mensaje claro antes de que salte el índice único
    IF EXISTS (SELECT 1 FROM inventarios.caracteristicas_categorias
                WHERE categoria_id = p_categoria_id AND nombre_id = p_nombre_id) THEN
        IF EXISTS (SELECT 1 FROM inventarios.caracteristicas_categorias
                    WHERE categoria_id = p_categoria_id AND nombre_id = p_nombre_id
                      AND deleted_at IS NOT NULL) THEN
            RAISE EXCEPTION 'Esa categoría ya pide «%», y está en la papelera de reciclaje', v_nombre USING ERRCODE = 'P0006';
        END IF;
        RAISE EXCEPTION 'Esa categoría ya pide «%»', v_nombre USING ERRCODE = 'P0006';
    END IF;

    -- Las opciones son de la categoría, pero sólo si el nombre es de lista
    v_valores := inventarios.fn_caracteristicas_valores_limpios(p_valores_lista, v_tipo);

    -- Sin orden, la última de su categoría
    v_orden := COALESCE(p_orden, (SELECT COALESCE(MAX(orden), 0) + 1
                                    FROM inventarios.caracteristicas_categorias
                                   WHERE categoria_id = p_categoria_id AND deleted_at IS NULL));

    v_nuevo := jsonb_build_object(
        'categoria_id',  p_categoria_id,
        'nombre_id',     p_nombre_id,
        'nombre',        v_nombre,
        'valores_lista', to_jsonb(v_valores),
        'orden',         v_orden,
        'activo',        COALESCE(p_activo, true),
        'requerido',     COALESCE(p_requerido, false)
    );
    PERFORM set_config('app.datos_nuevos', v_nuevo::text, true);

    INSERT INTO inventarios.caracteristicas_categorias
                (categoria_id, nombre_id, valores_lista, orden, activo, requerido)
    VALUES (p_categoria_id, p_nombre_id, v_valores, v_orden,
            COALESCE(p_activo, true), COALESCE(p_requerido, false))
    RETURNING id INTO v_id;

    PERFORM set_config('app.datos_nuevos', '', true);

    RETURN jsonb_build_object('success', true, 'message', 'Característica creada exitosamente',
                              'data', inventarios.fn_caracteristicas_json(v_id));

EXCEPTION
    WHEN unique_violation THEN
        RAISE EXCEPTION 'Esa categoría ya pide «%»', v_nombre USING ERRCODE = 'P0006';
END;
$$;

DROP FUNCTION IF EXISTS inventarios.fn_caracteristicas_modificar(
    bigint, bigint, bigint, text[], integer, boolean, bigint,
    character varying, character varying, inet, text, uuid);

CREATE OR REPLACE FUNCTION inventarios.fn_caracteristicas_modificar(
    p_id             bigint,
    p_categoria_id   bigint,
    p_nombre_id      bigint,
    p_valores_lista  text[]  DEFAULT NULL,
    p_orden          integer DEFAULT NULL,
    p_activo         boolean DEFAULT true,
    p_requerido      boolean DEFAULT false,
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
    v_antes   jsonb;
    v_nuevo   jsonb;
    v_orden   integer;
    v_nombre  varchar;
    v_tipo    varchar;
    v_valores text[];
BEGIN
    PERFORM inventarios.fn_contexto_auditoria('inventarios.caracteristicas_categorias',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    v_antes := inventarios.fn_caracteristicas_json(p_id);
    IF v_antes IS NULL THEN
        RAISE EXCEPTION 'La característica no existe' USING ERRCODE = 'P0013';
    END IF;

    SELECT n.nombre, n.tipo INTO v_nombre, v_tipo
      FROM inventarios.caracteristicas_nombres n
     WHERE n.id = p_nombre_id AND n.deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Elija un nombre del diccionario de características' USING ERRCODE = 'P0001';
    END IF;

    IF p_categoria_id IS NULL OR NOT EXISTS (SELECT 1 FROM inventarios.categorias
                                              WHERE id = p_categoria_id AND deleted_at IS NULL) THEN
        RAISE EXCEPTION 'La categoría indicada no existe' USING ERRCODE = 'P0016';
    END IF;

    IF EXISTS (SELECT 1 FROM inventarios.caracteristicas_categorias
                WHERE categoria_id = p_categoria_id AND nombre_id = p_nombre_id
                  AND id <> p_id) THEN
        RAISE EXCEPTION 'Esa categoría ya pide «%» (puede estar en la papelera de reciclaje)', v_nombre USING ERRCODE = 'P0006';
    END IF;

    v_valores := inventarios.fn_caracteristicas_valores_limpios(p_valores_lista, v_tipo);
    v_orden   := COALESCE(p_orden, (v_antes->>'orden')::integer);

    v_nuevo := jsonb_build_object(
        'categoria_id',  p_categoria_id,
        'nombre_id',     p_nombre_id,
        'nombre',        v_nombre,
        'valores_lista', to_jsonb(v_valores),
        'orden',         v_orden,
        'activo',        COALESCE(p_activo, true),
        'requerido',     COALESCE(p_requerido, false)
    );
    PERFORM set_config('app.datos_anteriores',
        jsonb_build_object('categoria_id',  (v_antes->>'categoria_id')::bigint,
                           'nombre_id',     (v_antes->>'nombre_id')::bigint,
                           'nombre',        v_antes->>'nombre',
                           'valores_lista', v_antes->'valores_lista',
                           'orden',         (v_antes->>'orden')::integer,
                           'activo',        (v_antes->>'activo')::boolean,
                           'requerido',     (v_antes->>'requerido')::boolean)::text, true);
    PERFORM set_config('app.datos_nuevos', v_nuevo::text, true);

    UPDATE inventarios.caracteristicas_categorias
       SET categoria_id  = p_categoria_id,
           nombre_id     = p_nombre_id,
           valores_lista = v_valores,
           orden         = v_orden,
           activo        = COALESCE(p_activo, true),
           requerido     = COALESCE(p_requerido, false)
     WHERE id = p_id;

    PERFORM set_config('app.datos_anteriores', '', true);
    PERFORM set_config('app.datos_nuevos', '', true);

    RETURN jsonb_build_object('success', true, 'message', 'Característica actualizada exitosamente',
                              'data', inventarios.fn_caracteristicas_json(p_id));

EXCEPTION
    WHEN unique_violation THEN
        RAISE EXCEPTION 'Esa categoría ya pide «%» (puede estar en la papelera de reciclaje)', v_nombre USING ERRCODE = 'P0006';
END;
$$;

-- ---------------------------------------------------------------------------
-- 4. LA PALANCA, COMO LA DE ACTIVO
-- ---------------------------------------------------------------------------
-- Para marcarla desde la rejilla sin abrir la ficha, igual que `activo`.
CREATE OR REPLACE FUNCTION inventarios.fn_caracteristicas_requerido(
    p_id             bigint,
    p_requerido      boolean DEFAULT NULL,
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
    v_antes  boolean;
    v_nuevo  boolean;
    v_nombre varchar;
    v_sin    integer;
BEGIN
    PERFORM inventarios.fn_contexto_auditoria('inventarios.caracteristicas_categorias',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    SELECT requerido, nombre INTO v_antes, v_nombre
      FROM inventarios.caracteristicas_categorias WHERE id = p_id AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'La característica no existe' USING ERRCODE = 'P0013';
    END IF;

    v_nuevo := COALESCE(p_requerido, NOT v_antes);

    PERFORM set_config('app.datos_anteriores', jsonb_build_object('requerido', v_antes)::text, true);
    PERFORM set_config('app.datos_nuevos',     jsonb_build_object('requerido', v_nuevo)::text, true);

    UPDATE inventarios.caracteristicas_categorias SET requerido = v_nuevo WHERE id = p_id;

    PERFORM set_config('app.datos_anteriores', '', true);
    PERFORM set_config('app.datos_nuevos', '', true);

    -- Cuántos productos de esa categoría se quedan sin poder guardarse hasta
    -- que alguien la rellene: es lo que hay que decir, no un «guardado».
    v_sin := (inventarios.fn_caracteristicas_json(p_id)->>'num_sin_valor')::integer;

    RETURN jsonb_build_object('success', true,
        'message', CASE
            WHEN NOT v_nuevo THEN 'Característica «' || v_nombre || '» ya no es obligatoria'
            WHEN COALESCE(v_sin, 0) = 0 THEN 'Característica «' || v_nombre || '» es obligatoria'
            ELSE 'Característica «' || v_nombre || '» es obligatoria. OJO: '
                 || v_sin || ' producto(s) de esa categoría la tienen vacía y no se podrán guardar sin rellenarla'
        END,
        'data', inventarios.fn_caracteristicas_json(p_id));
END;
$$;

-- ---------------------------------------------------------------------------
-- 5. EL FILTRO DE LA COLUMNA
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION inventarios.fn_caracteristicas_listar_paginado(
    p_page integer DEFAULT 1, p_per_page integer DEFAULT 15,
    p_search text DEFAULT ''::text, p_categoria_id bigint DEFAULT NULL::bigint,
    p_filtros jsonb DEFAULT '{}'::jsonb)
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'pg_catalog', 'inventarios', 'ventas'
AS $$
DECLARE
    v_offset integer;
    v_total  bigint;
    v_data   jsonb;
    v_filtro text;
BEGIN
    v_offset := (GREATEST(p_page, 1) - 1) * GREATEST(p_per_page, 1);
    v_filtro := NULLIF(TRIM(COALESCE(p_search, '')), '');

    WITH RECURSIVE rutas AS (
        -- La ruta de cada categoría, de una vez: se filtra y se busca por
        -- ella, y calcularla fila a fila dentro del WHERE sería repetir el
        -- mismo recorrido del árbol por cada característica.
        SELECT c.id, c.nombre::text AS ruta
          FROM inventarios.categorias c
         WHERE c.padre_id IS NULL
        UNION ALL
        SELECT h.id, r.ruta || ' > ' || h.nombre
          FROM inventarios.categorias h JOIN rutas r ON h.padre_id = r.id
    ),
    filtradas AS (
        SELECT k.id, k.categoria_id, k.orden
          FROM inventarios.caracteristicas_categorias k
          JOIN rutas r ON r.id = k.categoria_id
         WHERE k.deleted_at IS NULL          -- lo de la papelera no sale
           AND (p_categoria_id IS NULL OR k.categoria_id = p_categoria_id)
           AND (v_filtro IS NULL
                OR k.nombre   ILIKE '%' || v_filtro || '%'
                OR r.ruta     ILIKE '%' || v_filtro || '%'
                OR k.id::text ILIKE '%' || v_filtro || '%')

           -- ---------- LOS FILTROS DE LA CABECERA ----------
           -- Se filtra por lo que SE VE: la categoría por su ruta y el
           -- estado por la palabra que sale en la celda.
           AND (p_filtros->'id'             IS NULL OR ventas.fn_filtro_numero(k.id,     p_filtros->'id'))
           AND (p_filtros->'nombre'         IS NULL OR ventas.fn_filtro_texto(k.nombre,  p_filtros->'nombre'))
           AND (p_filtros->'categoria_ruta' IS NULL OR ventas.fn_filtro_texto(r.ruta,    p_filtros->'categoria_ruta'))
           AND (p_filtros->'orden'          IS NULL OR ventas.fn_filtro_numero(k.orden,  p_filtros->'orden'))
           AND (p_filtros->'estado'         IS NULL OR ventas.fn_filtro_texto(
                   CASE WHEN k.activo THEN 'Activa' ELSE 'Inactiva' END, p_filtros->'estado'))
           AND (p_filtros->'requerida'      IS NULL OR ventas.fn_filtro_texto(
                   CASE WHEN k.requerido THEN 'Requerida' ELSE 'Opcional' END, p_filtros->'requerida'))
           AND (p_filtros->'num_productos'  IS NULL OR ventas.fn_filtro_numero(
                   (SELECT COUNT(*) FROM inventarios.caracteristicas_productos v
                     JOIN inventarios.productos p ON p.id = v.producto_id
                    WHERE v.caracteristica_id = k.id AND p.deleted_at IS NULL),
                   p_filtros->'num_productos'))
           AND (p_filtros->'created_by'     IS NULL OR ventas.fn_filtro_texto(k.created_by, p_filtros->'created_by'))
           AND (p_filtros->'updated_by'     IS NULL OR ventas.fn_filtro_texto(k.updated_by, p_filtros->'updated_by'))
           -- Las fechas, como texto sobre lo que se ve: «2026-10» busca el mes
           AND (p_filtros->'created_at'     IS NULL OR ventas.fn_filtro_texto(
                   to_char(k.created_at, 'YYYY-MM-DD HH24:MI:SS'), p_filtros->'created_at'))
           AND (p_filtros->'updated_at'     IS NULL OR ventas.fn_filtro_texto(
                   to_char(k.updated_at, 'YYYY-MM-DD HH24:MI:SS'), p_filtros->'updated_at'))
    )
    SELECT COUNT(*),
           COALESCE((SELECT jsonb_agg(inventarios.fn_caracteristicas_json(t.id)
                                      ORDER BY t.categoria_id, t.orden, t.id)
                       FROM (SELECT f.id, f.categoria_id, f.orden FROM filtradas f
                              ORDER BY f.categoria_id, f.orden, f.id
                              LIMIT GREATEST(p_per_page, 1) OFFSET v_offset) t), '[]'::jsonb)
      INTO v_total, v_data
      FROM filtradas;

    RETURN jsonb_build_object(
        'data', v_data,
        'meta', jsonb_build_object(
            'total',        v_total,
            'per_page',     GREATEST(p_per_page, 1),
            'current_page', GREATEST(p_page, 1),
            'last_page',    CASE WHEN v_total = 0 THEN 1
                                 ELSE ceil(v_total::numeric / GREATEST(p_per_page, 1)) END
        )
    );

EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false,
                              'message', 'Error al listar características: ' || SQLERRM,
                              'error_code', SQLSTATE);
END;
$$;

-- ---------------------------------------------------------------------------
-- 6. LA LISTA QUE SE RELLENA EN EL PRODUCTO, CON LA MARCA
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION inventarios.fn_productos_caracteristicas(p_producto_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'pg_catalog', 'inventarios'
AS $$
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
                   'nombre_id',         k.nombre_id,
                   'nombre',            n.nombre,
                   'unidad',            n.unidad,
                   'etiqueta',          n.nombre || COALESCE(' (' || n.unidad || ')', ''),
                   'tipo',              n.tipo,
                   'valores_lista',     COALESCE(to_jsonb(k.valores_lista), 'null'::jsonb),
                   'requerido',         k.requerido,
                   -- El del producto si lo guardó; si no, el de la categoría
                   'orden',             COALESCE(v.orden, k.orden),
                   'valor',             v.valor,
                   'en_plantilla',      true
               ) AS fila,
               -- Las rellenas, en su orden; las vacías detrás (el +1000), en
               -- el de la categoría
               CASE WHEN v.id IS NULL THEN 1000 + k.orden ELSE v.orden END AS clave_orden,
               n.nombre AS nombre
          FROM inventarios.caracteristicas_categorias k
          JOIN inventarios.caracteristicas_nombres n ON n.id = k.nombre_id
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
                   'nombre_id',         v.nombre_id,
                   'nombre',            v.nombre,
                   'unidad',            n.unidad,
                   'etiqueta',          v.nombre || COALESCE(' (' || n.unidad || ')', ''),
                   'tipo',              COALESCE(n.tipo, 'TEXTO'),
                   'valores_lista',     'null'::jsonb,
                   'requerido',         false,
                   'orden',             v.orden,
                   'valor',             v.valor,
                   'en_plantilla',      false
               ),
               2000 + v.orden,
               v.nombre
          FROM inventarios.caracteristicas_productos v
          LEFT JOIN inventarios.caracteristicas_nombres n ON n.id = v.nombre_id
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
$$;

-- ---------------------------------------------------------------------------
-- 7. EL PORTERO: SIN LAS REQUERIDAS NO SE GUARDA
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

    -- Lo que viene con valor, en una tabla de trabajo
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
     WHERE NULLIF(TRIM(COALESCE(e->>'valor', '')), '') IS NOT NULL
       AND (NULLIF(e->>'caracteristica_id', '') IS NOT NULL
         OR NULLIF(e->>'nombre_id', '') IS NOT NULL
         OR length(TRIM(COALESCE(e->>'nombre', ''))) > 0);

    -- El nombre del diccionario: de la plantilla cuando viene de ella, y si no
    -- por el id que mandó la pantalla o por el texto (que es como se guardaban
    -- las sueltas antes).
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
    -- LAS REQUERIDAS TIENEN QUE VENIR
    -- ---------------------------------------------------------------
    -- Sólo las ACTIVAS: lo que no se pide tampoco se exige. Y se mira contra
    -- lo que llega, no contra lo guardado: vaciar una requerida es tan malo
    -- como no haberla puesto nunca.
    SELECT string_agg(k.nombre, ', ' ORDER BY k.orden) INTO v_faltan
      FROM inventarios.caracteristicas_categorias k
     WHERE k.categoria_id = v_categoria
       AND k.deleted_at IS NULL
       AND k.activo
       AND k.requerido
       AND NOT EXISTS (SELECT 1 FROM tmp_carac_prod t WHERE t.caracteristica_id = k.id);

    IF v_faltan IS NOT NULL THEN
        RAISE EXCEPTION 'Falta rellenar: %', v_faltan USING ERRCODE = 'P0001';
    END IF;

    -- ---------------------------------------------------------------
    -- EL VALOR, CONTRA EL TIPO
    -- ---------------------------------------------------------------

    -- NUMERO: la coma a punto ANTES de comprobar, que «15,5» es un número
    -- escrito como se escribe aquí.
    UPDATE tmp_carac_prod t
       SET valor = replace(t.valor, ',', '.')
      FROM inventarios.caracteristicas_nombres n
     WHERE n.id = t.nombre_id AND n.tipo = 'NUMERO' AND t.valor LIKE '%,%';

    SELECT string_agg(format('«%s» tiene que ser un número y dice «%s»', t.nombre, t.valor), '; ')
      INTO v_malo
      FROM tmp_carac_prod t
      JOIN inventarios.caracteristicas_nombres n ON n.id = t.nombre_id
     WHERE n.tipo = 'NUMERO'
       AND t.valor !~ '^-?[0-9]+(\.[0-9]+)?$';

    IF v_malo IS NOT NULL THEN
        RAISE EXCEPTION '%', v_malo USING ERRCODE = 'P0015';
    END IF;

    -- SI_NO: se guarda siempre igual, se escriba como se escriba
    UPDATE tmp_carac_prod t
       SET valor = CASE WHEN inventarios.fn_normalizar_nombre(t.valor) IN ('si', 's', 'true', '1')
                        THEN 'Sí' ELSE 'No' END
      FROM inventarios.caracteristicas_nombres n
     WHERE n.id = t.nombre_id AND n.tipo = 'SI_NO'
       AND inventarios.fn_normalizar_nombre(t.valor) IN ('si', 's', 'true', '1', 'no', 'n', 'false', '0');

    SELECT string_agg(format('«%s» tiene que ser Sí o No, y dice «%s»', t.nombre, t.valor), '; ')
      INTO v_malo
      FROM tmp_carac_prod t
      JOIN inventarios.caracteristicas_nombres n ON n.id = t.nombre_id
     WHERE n.tipo = 'SI_NO' AND t.valor NOT IN ('Sí', 'No');

    IF v_malo IS NOT NULL THEN
        RAISE EXCEPTION '%', v_malo USING ERRCODE = 'P0015';
    END IF;

    -- LISTA: una de las opciones de ESA categoría. Las sueltas no tienen
    -- categoría detrás, así que no hay lista que exigirles.
    SELECT string_agg(format('«%s» tiene que ser una de: %s', t.nombre,
                             array_to_string(k.valores_lista, ', ')), '; ')
      INTO v_malo
      FROM tmp_carac_prod t
      JOIN inventarios.caracteristicas_categorias k ON k.id = t.caracteristica_id
      JOIN inventarios.caracteristicas_nombres n ON n.id = k.nombre_id
     WHERE n.tipo = 'LISTA'
       AND COALESCE(array_length(k.valores_lista, 1), 0) > 0
       AND NOT EXISTS (SELECT 1 FROM unnest(k.valores_lista) o
                        WHERE inventarios.fn_normalizar_nombre(o)
                            = inventarios.fn_normalizar_nombre(t.valor));

    IF v_malo IS NOT NULL THEN
        RAISE EXCEPTION '%', v_malo USING ERRCODE = 'P0015';
    END IF;

    -- Y se guarda la opción TAL COMO ESTÁ ESCRITA EN LA CATEGORÍA: si la
    -- lista dice «Gas» y llega «gas», se guarda «Gas». Si no, agrupar por el
    -- valor daría dos grupos para la misma opción.
    UPDATE tmp_carac_prod t
       SET valor = o.opcion
      FROM inventarios.caracteristicas_categorias k
      JOIN inventarios.caracteristicas_nombres n ON n.id = k.nombre_id
      CROSS JOIN LATERAL unnest(k.valores_lista) AS o(opcion)
     WHERE k.id = t.caracteristica_id
       AND n.tipo = 'LISTA'
       AND inventarios.fn_normalizar_nombre(o.opcion) = inventarios.fn_normalizar_nombre(t.valor)
       AND o.opcion IS DISTINCT FROM t.valor;

    -- ---------------------------------------------------------------

    -- Fuera lo que ya no está (vaciado o quitado de la lista)
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

    -- Las que vienen de la plantilla: una fila por característica
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

    -- Las sueltas (sin plantilla detrás), por id del diccionario
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

COMMIT;
