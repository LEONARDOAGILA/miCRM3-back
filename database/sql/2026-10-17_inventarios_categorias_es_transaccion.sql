-- ===========================================================================
-- CATEGORÍAS DE TRANSACCIÓN
-- ===========================================================================
-- Fecha: 2026-10-17
--
-- EL PROBLEMA: al crear un producto se podía elegir CUALQUIER nodo del árbol
-- de categorías, incluidos los que sólo agrupan. Un producto colgado de
-- «Tecnología» o de «Computadores» no se encuentra donde se le busca y
-- descuadra cualquier informe por categoría.
--
-- LA SOLUCIÓN: una marca por categoría, `es_transaccion`. Sólo las marcadas
-- admiten productos; las demás siguen en el árbol para colocar y agrupar.
--
-- REPARTO INICIAL (sólo la primera vez que se aplica): es de transacción la
-- que NO tiene hijas. Medido en la base antes de escribir esto: 19 hojas, 9
-- con hijas y NINGUNA con hijas y productos a la vez, así que ningún
-- producto existente se queda apuntando a una categoría que ya no lo admite.
-- Por si acaso, las que tengan productos se marcan igualmente.
--
-- Qué cambia:
--   1. La columna `es_transaccion` en inventarios.categorias.
--   2. fn_categorias_json devuelve la marca (y con ella listar y obtener).
--   3. fn_categorias_crear y fn_categorias_modificar la reciben.
--      Modificar NO deja quitarla si la categoría ya tiene productos.
--   4. fn_productos_validar rechaza una categoría que no sea de transacción
--      (y, de paso, una que esté en la papelera, que antes colaba).
--
-- Se puede volver a aplicar: la columna y el reparto van con guardia, y las
-- funciones son CREATE OR REPLACE.
-- ===========================================================================


-- ---------------------------------------------------------------------------
-- 1. LA COLUMNA (y el reparto inicial, sólo al crearla)
-- ---------------------------------------------------------------------------
DO $migracion$
DECLARE
    v_nueva boolean;
BEGIN
    v_nueva := NOT EXISTS (
        SELECT 1 FROM information_schema.columns
         WHERE table_schema = 'inventarios'
           AND table_name   = 'categorias'
           AND column_name  = 'es_transaccion');

    IF NOT v_nueva THEN
        RAISE NOTICE 'La columna es_transaccion ya existía: no se toca el reparto';
        RETURN;
    END IF;

    ALTER TABLE inventarios.categorias
        ADD COLUMN es_transaccion boolean NOT NULL DEFAULT true;

    COMMENT ON COLUMN inventarios.categorias.es_transaccion IS
        'true = se le pueden asignar productos; false = sólo agrupa en el árbol';

    -- Las que tienen hijas pasan a agrupar...
    UPDATE inventarios.categorias c
       SET es_transaccion = false
     WHERE EXISTS (SELECT 1 FROM inventarios.categorias h
                    WHERE h.padre_id = c.id AND h.deleted_at IS NULL);

    -- ...salvo que ya tengan productos colgando, que entonces manda el hecho
    UPDATE inventarios.categorias c
       SET es_transaccion = true
     WHERE EXISTS (SELECT 1 FROM inventarios.productos p
                    WHERE p.categoria_id = c.id AND p.deleted_at IS NULL);

    RAISE NOTICE 'Reparto inicial: % de transacción, % agrupan',
        (SELECT COUNT(*) FROM inventarios.categorias WHERE es_transaccion AND deleted_at IS NULL),
        (SELECT COUNT(*) FROM inventarios.categorias WHERE NOT es_transaccion AND deleted_at IS NULL);
END
$migracion$;


-- ---------------------------------------------------------------------------
-- 2. EL JSON DE UNA CATEGORÍA
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION inventarios.fn_categorias_json(p_id bigint)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
AS $function$
    WITH RECURSIVE subida AS (
        SELECT c.id, c.padre_id, c.nombre, 0 AS salto
          FROM inventarios.categorias c WHERE c.id = p_id
        UNION ALL
        SELECT p.id, p.padre_id, p.nombre, s.salto + 1
          FROM inventarios.categorias p JOIN subida s ON p.id = s.padre_id
    )
    SELECT jsonb_build_object(
        'id',            c.id,
        'padre_id',      c.padre_id,
        'padre_nombre',  (SELECT x.nombre FROM inventarios.categorias x WHERE x.id = c.padre_id),
        'orden',         c.orden,
        'nivel',         c.nivel,
        'nombre',        c.nombre,
        'ruta',          (SELECT string_agg(s.nombre, ' > ' ORDER BY s.salto DESC) FROM subida s),
        'descripcion',   c.descripcion,
        'icono',         c.icono,
        'activo',        c.activo,
        -- true = se le pueden colgar productos. Las de arriba del árbol
        -- agrupan y no deben salir en el selector de productos.
        'es_transaccion', c.es_transaccion,
        'num_hijos',     (SELECT COUNT(*) FROM inventarios.categorias h WHERE h.padre_id = c.id AND h.deleted_at IS NULL),
        'num_productos', (SELECT COUNT(*) FROM inventarios.productos p WHERE p.categoria_id = c.id AND p.deleted_at IS NULL),
        -- La papelera: NULL mientras la categoría está vigente
        'deleted_at',    to_char(c.deleted_at, 'YYYY-MM-DD HH24:MI:SS'),
        'deleted_by',    c.deleted_by,

        'created_by',    c.created_by,
        'updated_by',    c.updated_by,
        'created_at',    to_char(c.created_at, 'YYYY-MM-DD HH24:MI:SS'),
        'updated_at',    to_char(c.updated_at, 'YYYY-MM-DD HH24:MI:SS')
    )
      FROM inventarios.categorias c
     WHERE c.id = p_id;
$function$;


-- ---------------------------------------------------------------------------
-- 3. ALTA
-- ---------------------------------------------------------------------------
-- El parámetro va detrás de p_activo, así que la firma cambia y hay que
-- soltar la vieja: si no, quedarían las dos y la llamada sería ambigua.
DROP FUNCTION IF EXISTS inventarios.fn_categorias_crear(character varying, bigint, text, character varying, boolean, bigint, character varying, character varying, inet, text, uuid);

CREATE OR REPLACE FUNCTION inventarios.fn_categorias_crear(p_nombre character varying, p_padre_id bigint DEFAULT NULL::bigint, p_descripcion text DEFAULT NULL::text, p_icono character varying DEFAULT NULL::character varying, p_activo boolean DEFAULT true, p_es_transaccion boolean DEFAULT true, p_usuario_id bigint DEFAULT NULL::bigint, p_usuario_login character varying DEFAULT NULL::character varying, p_usuario_nombre character varying DEFAULT NULL::character varying, p_ip_address inet DEFAULT NULL::inet, p_user_agent text DEFAULT NULL::text, p_request_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'inventarios', 'auditoria'
AS $function$
DECLARE
    v_id    bigint;
    v_nivel integer := 0;
    v_orden integer;
    v_nuevo jsonb;
BEGIN
    PERFORM inventarios.fn_contexto_auditoria('inventarios.categorias',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    IF p_nombre IS NULL OR length(TRIM(p_nombre)) < 2 THEN
        RAISE EXCEPTION 'El nombre de la categoría es obligatorio (mínimo 2 caracteres)' USING ERRCODE = 'P0001';
    END IF;

    IF p_padre_id IS NOT NULL THEN
        SELECT nivel + 1 INTO v_nivel FROM inventarios.categorias WHERE id = p_padre_id;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'La categoría padre no existe' USING ERRCODE = 'P0016';
        END IF;
        IF v_nivel > 3 THEN
            RAISE EXCEPTION 'El árbol admite hasta cuatro niveles (0 a 3) y ahí quedaría en el %', v_nivel
                USING ERRCODE = 'P0015';
        END IF;
    END IF;

    -- Entre hermanos el nombre no se repite; en otra rama sí puede
    IF EXISTS (SELECT 1 FROM inventarios.categorias
                WHERE padre_id IS NOT DISTINCT FROM p_padre_id
                  AND UPPER(TRIM(nombre)) = UPPER(TRIM(p_nombre))) THEN
        -- Puede estar en la papelera: el índice único también cuenta a las
        -- eliminadas, y sin decirlo el mensaje desconcierta porque ese
        -- nombre no aparece en el árbol.
        IF EXISTS (SELECT 1 FROM inventarios.categorias
                    WHERE padre_id IS NOT DISTINCT FROM p_padre_id
                      AND UPPER(TRIM(nombre)) = UPPER(TRIM(p_nombre))
                      AND deleted_at IS NOT NULL) THEN
            RAISE EXCEPTION 'Ya existe una categoría con ese nombre en el mismo nivel, y está en la papelera de reciclaje' USING ERRCODE = 'P0006';
        END IF;
        RAISE EXCEPTION 'Ya existe una categoría con ese nombre en el mismo nivel' USING ERRCODE = 'P0006';
    END IF;

    -- Al final de sus hermanos, sin pisar el orden de los que ya están
    SELECT COALESCE(MAX(orden), 0) + 1 INTO v_orden
      FROM inventarios.categorias WHERE padre_id IS NOT DISTINCT FROM p_padre_id;

    v_nuevo := jsonb_build_object(
        'padre_id',    p_padre_id,
        'nivel',       v_nivel,
        'orden',       v_orden,
        'nombre',      TRIM(p_nombre),
        'descripcion', NULLIF(TRIM(COALESCE(p_descripcion, '')), ''),
        'icono',       NULLIF(TRIM(COALESCE(p_icono, '')), ''),
        'activo',      COALESCE(p_activo, true),
        'es_transaccion', COALESCE(p_es_transaccion, true)
    );
    PERFORM set_config('app.datos_nuevos', v_nuevo::text, true);

    INSERT INTO inventarios.categorias (padre_id, orden, nivel, nombre, descripcion, icono, activo, es_transaccion)
    VALUES (
        p_padre_id, v_orden, v_nivel,
        TRIM(p_nombre),
        NULLIF(TRIM(COALESCE(p_descripcion, '')), ''),
        NULLIF(TRIM(COALESCE(p_icono, '')), ''),
        COALESCE(p_activo, true),
        COALESCE(p_es_transaccion, true)
    )
    RETURNING id INTO v_id;

    PERFORM set_config('app.datos_nuevos', '', true);

    RETURN jsonb_build_object('success', true, 'message', 'Categoría creada exitosamente',
                              'data', inventarios.fn_categorias_json(v_id));

EXCEPTION
    WHEN unique_violation THEN
        RAISE EXCEPTION 'Ya existe una categoría con ese nombre en el mismo nivel' USING ERRCODE = 'P0006';
END;
$function$;


-- ---------------------------------------------------------------------------
-- 4. MODIFICACIÓN
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS inventarios.fn_categorias_modificar(bigint, character varying, text, character varying, boolean, bigint, character varying, character varying, inet, text, uuid);

CREATE OR REPLACE FUNCTION inventarios.fn_categorias_modificar(p_id bigint, p_nombre character varying, p_descripcion text DEFAULT NULL::text, p_icono character varying DEFAULT NULL::character varying, p_activo boolean DEFAULT true, p_es_transaccion boolean DEFAULT true, p_usuario_id bigint DEFAULT NULL::bigint, p_usuario_login character varying DEFAULT NULL::character varying, p_usuario_nombre character varying DEFAULT NULL::character varying, p_ip_address inet DEFAULT NULL::inet, p_user_agent text DEFAULT NULL::text, p_request_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'inventarios', 'auditoria'
AS $function$
DECLARE
    v_antes  jsonb;
    v_padre  bigint;
    v_nuevo  jsonb;
BEGIN
    PERFORM inventarios.fn_contexto_auditoria('inventarios.categorias',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    SELECT padre_id INTO v_padre FROM inventarios.categorias WHERE id = p_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'La categoría no existe' USING ERRCODE = 'P0013';
    END IF;
    v_antes := inventarios.fn_categorias_json(p_id);

    IF p_nombre IS NULL OR length(TRIM(p_nombre)) < 2 THEN
        RAISE EXCEPTION 'El nombre de la categoría es obligatorio (mínimo 2 caracteres)' USING ERRCODE = 'P0001';
    END IF;
    IF EXISTS (SELECT 1 FROM inventarios.categorias
                WHERE padre_id IS NOT DISTINCT FROM v_padre
                  AND UPPER(TRIM(nombre)) = UPPER(TRIM(p_nombre))
                  AND id <> p_id) THEN
        RAISE EXCEPTION 'Ya existe otra categoría con ese nombre en el mismo nivel' USING ERRCODE = 'P0006';
    END IF;

    -- Quitarle «es transacción» a una categoría que YA tiene productos
    -- dejaría esos productos colgando de algo que el selector no ofrece y
    -- que fn_productos_validar rechaza: no se podrían ni guardar al
    -- editarlos. Primero se mueven los productos.
    IF COALESCE(p_es_transaccion, true) = false
       AND EXISTS (SELECT 1 FROM inventarios.productos p
                    WHERE p.categoria_id = p_id AND p.deleted_at IS NULL) THEN
        RAISE EXCEPTION 'No se puede quitar «es transacción»: la categoría tiene % producto(s). Muévalos antes a otra categoría.',
              (SELECT COUNT(*) FROM inventarios.productos p WHERE p.categoria_id = p_id AND p.deleted_at IS NULL)
              USING ERRCODE = 'P0021';
    END IF;

    v_nuevo := jsonb_build_object(
        'nombre',      TRIM(p_nombre),
        'descripcion', NULLIF(TRIM(COALESCE(p_descripcion, '')), ''),
        'icono',       NULLIF(TRIM(COALESCE(p_icono, '')), ''),
        'activo',      COALESCE(p_activo, true),
        'es_transaccion', COALESCE(p_es_transaccion, true)
    );
    PERFORM set_config('app.datos_anteriores',
        jsonb_build_object('nombre',      v_antes->>'nombre',
                           'descripcion', v_antes->>'descripcion',
                           'icono',       v_antes->>'icono',
                           'activo',      (v_antes->>'activo')::boolean,
                           'es_transaccion', (v_antes->>'es_transaccion')::boolean)::text, true);
    PERFORM set_config('app.datos_nuevos', v_nuevo::text, true);

    UPDATE inventarios.categorias
       SET nombre      = TRIM(p_nombre),
           descripcion = NULLIF(TRIM(COALESCE(p_descripcion, '')), ''),
           icono       = NULLIF(TRIM(COALESCE(p_icono, '')), ''),
           activo      = COALESCE(p_activo, true),
           es_transaccion = COALESCE(p_es_transaccion, true)
     WHERE id = p_id;

    PERFORM set_config('app.datos_anteriores', '', true);
    PERFORM set_config('app.datos_nuevos', '', true);

    RETURN jsonb_build_object('success', true, 'message', 'Categoría actualizada exitosamente',
                              'data', inventarios.fn_categorias_json(p_id));

EXCEPTION
    WHEN unique_violation THEN
        -- El índice único cuenta también a las que están en la papelera
        RAISE EXCEPTION 'Ya existe otra categoría con ese nombre en el mismo nivel (puede estar en la papelera de reciclaje)' USING ERRCODE = 'P0006';
END;
$function$;


-- ---------------------------------------------------------------------------
-- 5. LA VALIDACIÓN DEL PRODUCTO
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION inventarios.fn_productos_validar(p_id bigint, p_codigo character varying, p_nombre character varying, p_codigo_barras character varying, p_marca_id bigint, p_categoria_id bigint, p_costo numeric, p_precio numeric, p_iva numeric, p_stock_minimo numeric, p_stock_maximo numeric, p_garantia integer)
 RETURNS void
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
AS $function$
BEGIN
    IF p_codigo IS NULL OR length(TRIM(p_codigo)) < 2 THEN
        RAISE EXCEPTION 'El código del producto es obligatorio (mínimo 2 caracteres)' USING ERRCODE = 'P0001';
    END IF;
    IF p_nombre IS NULL OR length(TRIM(p_nombre)) < 3 THEN
        RAISE EXCEPTION 'El nombre del producto es obligatorio (mínimo 3 caracteres)' USING ERRCODE = 'P0001';
    END IF;

    IF EXISTS (SELECT 1 FROM inventarios.productos
                WHERE UPPER(TRIM(codigo)) = UPPER(TRIM(p_codigo))
                  AND (p_id IS NULL OR id <> p_id)) THEN
        -- Puede estar en la papelera: sin decirlo, el mensaje desconcierta
        -- porque ese código no aparece en ningún listado.
        IF EXISTS (SELECT 1 FROM inventarios.productos
                    WHERE UPPER(TRIM(codigo)) = UPPER(TRIM(p_codigo))
                      AND (p_id IS NULL OR id <> p_id)
                      AND deleted_at IS NOT NULL) THEN
            RAISE EXCEPTION 'Ya existe un producto con el código % en la papelera de reciclaje', UPPER(TRIM(p_codigo)) USING ERRCODE = 'P0006';
        END IF;
        RAISE EXCEPTION 'Ya existe un producto con el código %', UPPER(TRIM(p_codigo)) USING ERRCODE = 'P0006';
    END IF;

    IF NULLIF(TRIM(COALESCE(p_codigo_barras, '')), '') IS NOT NULL
       AND EXISTS (SELECT 1 FROM inventarios.productos
                    WHERE UPPER(TRIM(codigo_barras)) = UPPER(TRIM(p_codigo_barras))
                      AND (p_id IS NULL OR id <> p_id)) THEN
        RAISE EXCEPTION 'Ya existe un producto con ese código de barras' USING ERRCODE = 'P0006';
    END IF;

    -- Y que no esté en la papelera: no sale en ningún combo, así que si
    -- llega es de una pantalla con datos viejos.
    IF p_marca_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM inventarios.marcas WHERE id = p_marca_id AND deleted_at IS NULL) THEN
        RAISE EXCEPTION 'La marca indicada no existe' USING ERRCODE = 'P0016';
    END IF;
    IF p_categoria_id IS NOT NULL THEN
        -- Igual que la marca: tampoco vale una que esté en la papelera
        IF NOT EXISTS (SELECT 1 FROM inventarios.categorias
                        WHERE id = p_categoria_id AND deleted_at IS NULL) THEN
            RAISE EXCEPTION 'La categoría indicada no existe' USING ERRCODE = 'P0016';
        END IF;

        -- SÓLO LAS DE TRANSACCIÓN ADMITEN PRODUCTOS. Las de arriba del
        -- árbol agrupan: «Tecnología» o «Computadores» no son sitios
        -- donde poner un producto, lo son «Portátiles» o «Monitores».
        IF NOT EXISTS (SELECT 1 FROM inventarios.categorias
                        WHERE id = p_categoria_id AND es_transaccion) THEN
            RAISE EXCEPTION 'La categoría «%» agrupa, no admite productos: elija una de transacción',
                  (SELECT nombre FROM inventarios.categorias WHERE id = p_categoria_id)
                  USING ERRCODE = 'P0016';
        END IF;
    END IF;

    IF COALESCE(p_costo, 0)  < 0 THEN RAISE EXCEPTION 'El costo no puede ser negativo'  USING ERRCODE = 'P0015'; END IF;
    IF COALESCE(p_precio, 0) < 0 THEN RAISE EXCEPTION 'El precio no puede ser negativo' USING ERRCODE = 'P0015'; END IF;
    IF COALESCE(p_iva, 0) < 0 OR COALESCE(p_iva, 0) > 100 THEN
        RAISE EXCEPTION 'El IVA debe estar entre 0 y 100' USING ERRCODE = 'P0015';
    END IF;
    IF COALESCE(p_stock_minimo, 0) < 0 THEN
        RAISE EXCEPTION 'El stock mínimo no puede ser negativo' USING ERRCODE = 'P0015';
    END IF;
    IF p_stock_maximo IS NOT NULL AND p_stock_maximo < COALESCE(p_stock_minimo, 0) THEN
        RAISE EXCEPTION 'El stock máximo no puede ser menor que el mínimo' USING ERRCODE = 'P0015';
    END IF;
    IF COALESCE(p_garantia, 0) < 0 OR COALESCE(p_garantia, 0) > 600 THEN
        RAISE EXCEPTION 'La garantía debe estar entre 0 y 600 meses' USING ERRCODE = 'P0015';
    END IF;
END;
$function$;
