-- ============================================================================
-- LAS CARACTERÍSTICAS DE CATEGORÍA, ENGANCHADAS AL DICCIONARIO
-- ============================================================================
-- Fecha: 2026-10-28
-- Va después de `..._caracteristicas_nombres.sql` y `..._nombres_funciones.sql`.
--
-- LA DECISIÓN QUE EXPLICA TODO ESTE FICHERO
--
-- `caracteristicas_categorias.nombre` NO se borra: se convierte en una CACHÉ
-- que mantiene un disparador desde el diccionario. Nadie más la escribe.
--
-- Borrarla era lo primero que pensé, y habría obligado a reescribir catorce
-- funciones —el listado paginado, los nueve filtros de columna, la búsqueda,
-- los mensajes de activar/eliminar/restaurar— para ir a buscar el nombre por
-- un JOIN. Con la caché hay que tocar cinco, y la columna no puede quedarse
-- vieja porque:
--
--   · al insertar o modificar una fila, el disparador la recalcula SIEMPRE
--     desde `nombre_id` (así que escribirla a mano no sirve de nada), y
--   · al renombrar en el diccionario, el otro disparador refresca de golpe
--     todas las filas que lo apuntan.
--
-- Lo que NO es caché es `caracteristicas_productos.nombre`: ahí el nombre es
-- una FOTO de cómo se llamaba cuando el producto se rellenó, y la pantalla ya
-- lo promete así («cada producto conserva el nombre con el que lo rellenó»).
-- Para los informes está `nombre_id`, que es por donde hay que agrupar.
--
-- Idempotente.
-- ============================================================================
\set ON_ERROR_STOP on

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. LA CACHÉ DEL NOMBRE
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION inventarios.fn_caracteristicas_cache_nombre()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    -- Siempre desde el diccionario, se haya mandado lo que se haya mandado en
    -- NEW.nombre: la columna es una caché, no un dato que se pueda escribir.
    SELECT n.nombre INTO NEW.nombre
      FROM inventarios.caracteristicas_nombres n
     WHERE n.id = NEW.nombre_id;

    IF NEW.nombre IS NULL THEN
        RAISE EXCEPTION 'El nombre de característica % no existe en el diccionario', NEW.nombre_id
            USING ERRCODE = 'P0016';
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_caracteristicas_cache_nombre ON inventarios.caracteristicas_categorias;
CREATE TRIGGER trg_caracteristicas_cache_nombre
    BEFORE INSERT OR UPDATE ON inventarios.caracteristicas_categorias
    FOR EACH ROW EXECUTE FUNCTION inventarios.fn_caracteristicas_cache_nombre();

COMMENT ON COLUMN inventarios.caracteristicas_categorias.nombre IS
  'CACHÉ del nombre del diccionario (caracteristicas_nombres). La mantienen los disparadores: no se escribe a mano. El dato real es nombre_id.';

-- Al renombrar en el diccionario, refrescar a todos los que lo apuntan. Es lo
-- que hace que arreglar «pezo» una vez lo arregle en todas las categorías.
CREATE OR REPLACE FUNCTION inventarios.fn_caracteristicas_nombres_propagar()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.nombre IS DISTINCT FROM OLD.nombre THEN
        UPDATE inventarios.caracteristicas_categorias
           SET nombre = NEW.nombre
         WHERE nombre_id = NEW.id
           AND nombre IS DISTINCT FROM NEW.nombre;
    END IF;
    RETURN NULL;
END;
$$;

DROP TRIGGER IF EXISTS trg_caracteristicas_nombres_propagar ON inventarios.caracteristicas_nombres;
CREATE TRIGGER trg_caracteristicas_nombres_propagar
    AFTER UPDATE OF nombre ON inventarios.caracteristicas_nombres
    FOR EACH ROW EXECUTE FUNCTION inventarios.fn_caracteristicas_nombres_propagar();

-- Y la primera sincronización: las filas cuyo nombre viejo traía la unidad o
-- las opciones dentro («Potencia (W)») tienen que quedarse con el del
-- diccionario («Potencia»).
UPDATE inventarios.caracteristicas_categorias k
   SET nombre = n.nombre
  FROM inventarios.caracteristicas_nombres n
 WHERE n.id = k.nombre_id
   AND k.nombre IS DISTINCT FROM n.nombre;

-- ---------------------------------------------------------------------------
-- 2. LAS OPCIONES QUE ESCRIBE EL USUARIO
-- ---------------------------------------------------------------------------
-- Sin vacías, sin repetidas, en el orden en que las escribió y sólo si el
-- nombre es de tipo LISTA. En un sitio, que lo usan crear y modificar.
CREATE OR REPLACE FUNCTION inventarios.fn_caracteristicas_valores_limpios(
    p_valores text[], p_tipo varchar)
RETURNS text[]
LANGUAGE sql
IMMUTABLE
AS $$
    SELECT CASE WHEN p_tipo <> 'LISTA' THEN NULL ELSE
        NULLIF(ARRAY(
            SELECT s.v FROM (
                SELECT DISTINCT ON (inventarios.fn_normalizar_nombre(t.v))
                       btrim(t.v) AS v, t.ord
                  FROM unnest(COALESCE(p_valores, '{}'::text[])) WITH ORDINALITY AS t(v, ord)
                 WHERE length(btrim(t.v)) > 0
                 ORDER BY inventarios.fn_normalizar_nombre(t.v), t.ord
            ) s ORDER BY s.ord), '{}'::text[])
    END;
$$;

-- ---------------------------------------------------------------------------
-- 3. CREAR: AHORA SE ESCOGE EL NOMBRE, NO SE ESCRIBE
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS inventarios.fn_caracteristicas_crear(
    bigint, character varying, integer, boolean, bigint,
    character varying, character varying, inet, text, uuid);

CREATE OR REPLACE FUNCTION inventarios.fn_caracteristicas_crear(
    p_categoria_id   bigint,
    p_nombre_id      bigint,
    p_valores_lista  text[]  DEFAULT NULL,
    p_orden          integer DEFAULT NULL,
    p_activo         boolean DEFAULT true,
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
        'activo',        COALESCE(p_activo, true)
    );
    PERFORM set_config('app.datos_nuevos', v_nuevo::text, true);

    INSERT INTO inventarios.caracteristicas_categorias
                (categoria_id, nombre_id, valores_lista, orden, activo)
    VALUES (p_categoria_id, p_nombre_id, v_valores, v_orden, COALESCE(p_activo, true))
    RETURNING id INTO v_id;

    PERFORM set_config('app.datos_nuevos', '', true);

    RETURN jsonb_build_object('success', true, 'message', 'Característica creada exitosamente',
                              'data', inventarios.fn_caracteristicas_json(v_id));

EXCEPTION
    WHEN unique_violation THEN
        RAISE EXCEPTION 'Esa categoría ya pide «%»', v_nombre USING ERRCODE = 'P0006';
END;
$$;

-- ---------------------------------------------------------------------------
-- 4. MODIFICAR
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS inventarios.fn_caracteristicas_modificar(
    bigint, bigint, character varying, integer, boolean, bigint,
    character varying, character varying, inet, text, uuid);

CREATE OR REPLACE FUNCTION inventarios.fn_caracteristicas_modificar(
    p_id             bigint,
    p_categoria_id   bigint,
    p_nombre_id      bigint,
    p_valores_lista  text[]  DEFAULT NULL,
    p_orden          integer DEFAULT NULL,
    p_activo         boolean DEFAULT true,
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
        'activo',        COALESCE(p_activo, true)
    );
    PERFORM set_config('app.datos_anteriores',
        jsonb_build_object('categoria_id',  (v_antes->>'categoria_id')::bigint,
                           'nombre_id',     (v_antes->>'nombre_id')::bigint,
                           'nombre',        v_antes->>'nombre',
                           'valores_lista', v_antes->'valores_lista',
                           'orden',         (v_antes->>'orden')::integer,
                           'activo',        (v_antes->>'activo')::boolean)::text, true);
    PERFORM set_config('app.datos_nuevos', v_nuevo::text, true);

    UPDATE inventarios.caracteristicas_categorias
       SET categoria_id  = p_categoria_id,
           nombre_id     = p_nombre_id,
           valores_lista = v_valores,
           orden         = v_orden,
           activo        = COALESCE(p_activo, true)
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
-- 5. EL JSON, CON LO QUE AHORA VIENE DEL DICCIONARIO
-- ---------------------------------------------------------------------------
-- `nombre` sigue saliendo igual que siempre (de la caché), así que el listado,
-- la búsqueda y los nueve filtros de columna no se tocan. Lo que se añade es
-- el id del diccionario, la unidad, el tipo y las opciones.
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
        -- Cuántos productos la tienen rellena: es lo que avisa de que tocarla
        -- no es gratis
        'num_productos',  (SELECT COUNT(*) FROM inventarios.caracteristicas_productos v
                            JOIN inventarios.productos p ON p.id = v.producto_id
                           WHERE v.caracteristica_id = k.id AND p.deleted_at IS NULL),
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
-- 6. LA LISTA QUE SE RELLENA EN EL PRODUCTO
-- ---------------------------------------------------------------------------
-- Se le añade unidad, tipo y opciones: con eso la ficha del producto puede
-- pintar el campo que toca (un número, un combo, un sí/no) en vez de una caja
-- de texto para todo, que es la otra mitad del problema de la reportería.
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
-- 7. GUARDAR LOS VALORES DEL PRODUCTO
-- ---------------------------------------------------------------------------
-- La puerta que quedaba abierta: la característica SUELTA (la que sólo tiene
-- un producto) se escribía a mano, así que por ahí seguía entrando «pezo».
-- Ahora también tiene que ser un nombre del diccionario; si no lo es, se
-- rechaza diciendo cuál.
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
BEGIN
    PERFORM inventarios.fn_contexto_auditoria('inventarios.caracteristicas_productos',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    IF NOT EXISTS (SELECT 1 FROM inventarios.productos WHERE id = p_producto_id) THEN
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

    -- Las sueltas (sin plantilla detrás), ahora por id del diccionario
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
