-- ===========================================================================
-- CARACTERÍSTICAS DE CATEGORÍA (plantilla) Y DE PRODUCTO (lo que se rellena)
-- ===========================================================================
-- Fecha: 2026-10-18
--
-- EL PROBLEMA: la ficha de un producto se queda corta. Un portátil necesita
-- procesador, memoria y almacenamiento; un televisor, pulgadas y resolución.
-- Meterlo todo en la descripción no sirve: no se puede buscar ni comparar, y
-- cada quien lo escribe a su manera.
--
-- LA SOLUCIÓN: cada categoría lleva su LISTA de características, que es una
-- plantilla. Al crear un producto se carga la lista de su categoría y quien
-- lo crea rellena el valor de cada una.
--
--   inventarios.caracteristicas_categorias   la plantilla (por categoría)
--   inventarios.caracteristicas_productos    lo relleno (por producto)
--
-- POR QUÉ LA TABLA DE PRODUCTO GUARDA TAMBIÉN EL NOMBRE: porque es una foto
-- de lo que se rellenó. Si mañana se renombra «Memoria RAM» a «RAM», o se
-- quita de la plantilla, el producto sigue diciendo lo que decía. Sin esa
-- copia, cambiar la plantilla reescribiría la historia de todos los
-- productos.
--
-- La plantilla va con papelera (deleted_at), como categorías y marcas. Los
-- valores de un producto NO: cuelgan del producto en cascada, igual que sus
-- imágenes, porque fuera del producto no significan nada.
--
-- Se puede volver a aplicar: tablas e índices con IF NOT EXISTS y las
-- funciones son CREATE OR REPLACE.
-- ===========================================================================


-- ---------------------------------------------------------------------------
-- 1. LA PLANTILLA: inventarios.caracteristicas_categorias
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS inventarios.caracteristicas_categorias (
    id           bigserial    PRIMARY KEY,
    categoria_id bigint       NOT NULL REFERENCES inventarios.categorias(id),
    nombre       varchar(100) NOT NULL,
    -- En qué orden se le enseñan a quien rellena el producto
    orden        integer      NOT NULL DEFAULT 1,
    activo       boolean      NOT NULL DEFAULT true,

    created_at   timestamptz  NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at   timestamptz  NOT NULL DEFAULT CURRENT_TIMESTAMP,
    created_by   varchar(100),
    updated_by   varchar(100),
    deleted_at   timestamptz,
    deleted_by   varchar(100)
);

COMMENT ON TABLE inventarios.caracteristicas_categorias IS
    'Plantilla de características por categoría: lo que hay que rellenar al crear un producto de esa categoría';

-- Dentro de una categoría el nombre no se repite. Cuenta también a las de la
-- papelera, como en categorías: si no, restaurar una chocaría con la nueva.
CREATE UNIQUE INDEX IF NOT EXISTS uq_caracteristicas_cat_nombre
    ON inventarios.caracteristicas_categorias (categoria_id, UPPER(TRIM(nombre)));

CREATE INDEX IF NOT EXISTS ix_caracteristicas_cat
    ON inventarios.caracteristicas_categorias (categoria_id, orden);

CREATE INDEX IF NOT EXISTS ix_caracteristicas_deleted_at
    ON inventarios.caracteristicas_categorias (deleted_at) WHERE deleted_at IS NOT NULL;

-- Los tres de siempre: quién lo tocó, cuándo, y el registro del cambio
DROP TRIGGER IF EXISTS trigger_caracteristicas_cat_set_users ON inventarios.caracteristicas_categorias;
CREATE TRIGGER trigger_caracteristicas_cat_set_users
    BEFORE INSERT OR UPDATE ON inventarios.caracteristicas_categorias
    FOR EACH ROW EXECUTE FUNCTION auditoria.fn_set_audit_users();

DROP TRIGGER IF EXISTS trigger_caracteristicas_cat_updated_at ON inventarios.caracteristicas_categorias;
CREATE TRIGGER trigger_caracteristicas_cat_updated_at
    BEFORE UPDATE ON inventarios.caracteristicas_categorias
    FOR EACH ROW EXECUTE FUNCTION auditoria.fn_update_updated_at_column();

DROP TRIGGER IF EXISTS trg_caracteristicas_cat_audit ON inventarios.caracteristicas_categorias;
CREATE TRIGGER trg_caracteristicas_cat_audit
    AFTER INSERT OR UPDATE OR DELETE ON inventarios.caracteristicas_categorias
    FOR EACH ROW EXECUTE FUNCTION auditoria.fn_auditar_cambios();


-- ---------------------------------------------------------------------------
-- 2. LO RELLENO: inventarios.caracteristicas_productos
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS inventarios.caracteristicas_productos (
    id                bigserial    PRIMARY KEY,
    producto_id       bigint       NOT NULL REFERENCES inventarios.productos(id) ON DELETE CASCADE,
    -- De qué fila de la plantilla salió. Se pone a NULL si esa fila se borra
    -- definitivamente: el valor del producto no se pierde por eso.
    caracteristica_id bigint       REFERENCES inventarios.caracteristicas_categorias(id) ON DELETE SET NULL,
    -- El nombre, COPIADO al guardar: ver la cabecera del fichero
    nombre            varchar(100) NOT NULL,
    valor             text,
    orden             integer      NOT NULL DEFAULT 1,

    created_at        timestamptz  NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at        timestamptz  NOT NULL DEFAULT CURRENT_TIMESTAMP,
    created_by        varchar(100),
    updated_by        varchar(100)
);

COMMENT ON TABLE inventarios.caracteristicas_productos IS
    'Lo que se rellenó de la plantilla para un producto concreto';

-- Una fila por característica y producto
CREATE UNIQUE INDEX IF NOT EXISTS uq_caracteristicas_prod
    ON inventarios.caracteristicas_productos (producto_id, caracteristica_id)
    WHERE caracteristica_id IS NOT NULL;

-- Las que se quedaron huérfanas (plantilla borrada) se distinguen por nombre
CREATE UNIQUE INDEX IF NOT EXISTS uq_caracteristicas_prod_suelta
    ON inventarios.caracteristicas_productos (producto_id, UPPER(TRIM(nombre)))
    WHERE caracteristica_id IS NULL;

CREATE INDEX IF NOT EXISTS ix_caracteristicas_prod
    ON inventarios.caracteristicas_productos (producto_id, orden);

DROP TRIGGER IF EXISTS trigger_caracteristicas_prod_set_users ON inventarios.caracteristicas_productos;
CREATE TRIGGER trigger_caracteristicas_prod_set_users
    BEFORE INSERT OR UPDATE ON inventarios.caracteristicas_productos
    FOR EACH ROW EXECUTE FUNCTION auditoria.fn_set_audit_users();

DROP TRIGGER IF EXISTS trigger_caracteristicas_prod_updated_at ON inventarios.caracteristicas_productos;
CREATE TRIGGER trigger_caracteristicas_prod_updated_at
    BEFORE UPDATE ON inventarios.caracteristicas_productos
    FOR EACH ROW EXECUTE FUNCTION auditoria.fn_update_updated_at_column();

DROP TRIGGER IF EXISTS trg_caracteristicas_prod_audit ON inventarios.caracteristicas_productos;
CREATE TRIGGER trg_caracteristicas_prod_audit
    AFTER INSERT OR UPDATE OR DELETE ON inventarios.caracteristicas_productos
    FOR EACH ROW EXECUTE FUNCTION auditoria.fn_auditar_cambios();


-- ---------------------------------------------------------------------------
-- 3. UNA CARACTERÍSTICA DE LA PLANTILLA, EN JSON
-- ---------------------------------------------------------------------------
-- Lleva la RUTA de la categoría («Tecnología > Computadores > Portátiles») y
-- no sólo su nombre: hay dos «Accesorios» en el árbol y a secas no se sabe
-- de cuál cuelga la característica.
CREATE OR REPLACE FUNCTION inventarios.fn_caracteristicas_json(p_id bigint)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
AS $function$
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
        'nombre',         k.nombre,
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
     WHERE k.id = p_id;
$function$;


CREATE OR REPLACE FUNCTION inventarios.fn_caracteristicas_obtener(p_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
AS $function$
DECLARE
    v_data jsonb;
BEGIN
    v_data := inventarios.fn_caracteristicas_json(p_id);
    IF v_data IS NULL THEN
        RAISE EXCEPTION 'La característica no existe' USING ERRCODE = 'P0013';
    END IF;
    RETURN jsonb_build_object('success', true, 'message', 'Característica encontrada', 'data', v_data);
END;
$function$;


-- ---------------------------------------------------------------------------
-- 4. LA PLANTILLA DE UNA CATEGORÍA
-- ---------------------------------------------------------------------------
-- Es lo que carga el formulario del producto al elegir categoría. Sólo las
-- activas y nunca las de la papelera: si una se quitó, no se vuelve a pedir.
CREATE OR REPLACE FUNCTION inventarios.fn_caracteristicas_listar(
    p_categoria_id bigint  DEFAULT NULL,
    p_solo_activas boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'inventarios'
AS $function$
DECLARE
    v_data jsonb;
BEGIN
    SELECT COALESCE(jsonb_agg(inventarios.fn_caracteristicas_json(k.id) ORDER BY k.orden, k.id), '[]'::jsonb)
      INTO v_data
      FROM inventarios.caracteristicas_categorias k
     WHERE k.deleted_at IS NULL
       AND (p_categoria_id IS NULL OR k.categoria_id = p_categoria_id)
       AND (NOT p_solo_activas OR k.activo);

    RETURN jsonb_build_object('success', true, 'data', v_data);

EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false,
                              'message', 'Error al listar características: ' || SQLERRM,
                              'error_code', SQLSTATE);
END;
$function$;


-- ---------------------------------------------------------------------------
-- 5. EL LISTADO DE LA PANTALLA (paginado, con buscador y filtros de columna)
-- ---------------------------------------------------------------------------
-- Mismo trato que marcas o perfiles: la página la arma el servidor y los
-- filtros de la cabecera llegan en p_filtros. SE FILTRA POR LO QUE SE VE: la
-- categoría, por su ruta; el estado, por «Activa»/«Inactiva».
CREATE OR REPLACE FUNCTION inventarios.fn_caracteristicas_listar_paginado(
    p_page         integer DEFAULT 1,
    p_per_page     integer DEFAULT 15,
    p_search       text    DEFAULT ''::text,
    p_categoria_id bigint  DEFAULT NULL,
    p_filtros      jsonb   DEFAULT '{}'::jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'inventarios', 'ventas'
AS $function$
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
$function$;


-- ---------------------------------------------------------------------------
-- 6. ALTA
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION inventarios.fn_caracteristicas_crear(
    p_categoria_id   bigint,
    p_nombre         varchar,
    p_orden          integer DEFAULT NULL,
    p_activo         boolean DEFAULT true,
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
    v_id    bigint;
    v_orden integer;
    v_nuevo jsonb;
BEGIN
    PERFORM inventarios.fn_contexto_auditoria('inventarios.caracteristicas_categorias',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    IF p_nombre IS NULL OR length(TRIM(p_nombre)) < 2 THEN
        RAISE EXCEPTION 'El nombre de la característica es obligatorio (mínimo 2 caracteres)' USING ERRCODE = 'P0001';
    END IF;

    IF p_categoria_id IS NULL OR NOT EXISTS (SELECT 1 FROM inventarios.categorias
                                              WHERE id = p_categoria_id AND deleted_at IS NULL) THEN
        RAISE EXCEPTION 'La categoría indicada no existe' USING ERRCODE = 'P0016';
    END IF;

    -- Mensaje claro antes de que salte el índice único
    IF EXISTS (SELECT 1 FROM inventarios.caracteristicas_categorias
                WHERE categoria_id = p_categoria_id
                  AND UPPER(TRIM(nombre)) = UPPER(TRIM(p_nombre))) THEN
        IF EXISTS (SELECT 1 FROM inventarios.caracteristicas_categorias
                    WHERE categoria_id = p_categoria_id
                      AND UPPER(TRIM(nombre)) = UPPER(TRIM(p_nombre))
                      AND deleted_at IS NOT NULL) THEN
            RAISE EXCEPTION 'Esa categoría ya tiene una característica con ese nombre, y está en la papelera de reciclaje' USING ERRCODE = 'P0006';
        END IF;
        RAISE EXCEPTION 'Esa categoría ya tiene una característica con ese nombre' USING ERRCODE = 'P0006';
    END IF;

    -- Sin orden, la última de su categoría
    v_orden := COALESCE(p_orden, (SELECT COALESCE(MAX(orden), 0) + 1
                                    FROM inventarios.caracteristicas_categorias
                                   WHERE categoria_id = p_categoria_id AND deleted_at IS NULL));

    v_nuevo := jsonb_build_object(
        'categoria_id', p_categoria_id,
        'nombre',       TRIM(p_nombre),
        'orden',        v_orden,
        'activo',       COALESCE(p_activo, true)
    );
    PERFORM set_config('app.datos_nuevos', v_nuevo::text, true);

    INSERT INTO inventarios.caracteristicas_categorias (categoria_id, nombre, orden, activo)
    VALUES (p_categoria_id, TRIM(p_nombre), v_orden, COALESCE(p_activo, true))
    RETURNING id INTO v_id;

    PERFORM set_config('app.datos_nuevos', '', true);

    RETURN jsonb_build_object('success', true, 'message', 'Característica creada exitosamente',
                              'data', inventarios.fn_caracteristicas_json(v_id));

EXCEPTION
    WHEN unique_violation THEN
        RAISE EXCEPTION 'Esa categoría ya tiene una característica con ese nombre' USING ERRCODE = 'P0006';
END;
$function$;


-- ---------------------------------------------------------------------------
-- 7. MODIFICACIÓN
-- ---------------------------------------------------------------------------
-- La categoría SÍ se puede cambiar: una característica mal colocada se mueve
-- en vez de borrarla y volverla a escribir. Lo que ya rellenaron los
-- productos no se toca (guardan su propio nombre).
CREATE OR REPLACE FUNCTION inventarios.fn_caracteristicas_modificar(
    p_id             bigint,
    p_categoria_id   bigint,
    p_nombre         varchar,
    p_orden          integer DEFAULT NULL,
    p_activo         boolean DEFAULT true,
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
    v_antes jsonb;
    v_nuevo jsonb;
    v_orden integer;
BEGIN
    PERFORM inventarios.fn_contexto_auditoria('inventarios.caracteristicas_categorias',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    v_antes := inventarios.fn_caracteristicas_json(p_id);
    IF v_antes IS NULL THEN
        RAISE EXCEPTION 'La característica no existe' USING ERRCODE = 'P0013';
    END IF;

    IF p_nombre IS NULL OR length(TRIM(p_nombre)) < 2 THEN
        RAISE EXCEPTION 'El nombre de la característica es obligatorio (mínimo 2 caracteres)' USING ERRCODE = 'P0001';
    END IF;

    IF p_categoria_id IS NULL OR NOT EXISTS (SELECT 1 FROM inventarios.categorias
                                              WHERE id = p_categoria_id AND deleted_at IS NULL) THEN
        RAISE EXCEPTION 'La categoría indicada no existe' USING ERRCODE = 'P0016';
    END IF;

    IF EXISTS (SELECT 1 FROM inventarios.caracteristicas_categorias
                WHERE categoria_id = p_categoria_id
                  AND UPPER(TRIM(nombre)) = UPPER(TRIM(p_nombre))
                  AND id <> p_id) THEN
        RAISE EXCEPTION 'Esa categoría ya tiene otra característica con ese nombre (puede estar en la papelera de reciclaje)' USING ERRCODE = 'P0006';
    END IF;

    v_orden := COALESCE(p_orden, (v_antes->>'orden')::integer);

    v_nuevo := jsonb_build_object(
        'categoria_id', p_categoria_id,
        'nombre',       TRIM(p_nombre),
        'orden',        v_orden,
        'activo',       COALESCE(p_activo, true)
    );
    PERFORM set_config('app.datos_anteriores',
        jsonb_build_object('categoria_id', (v_antes->>'categoria_id')::bigint,
                           'nombre',       v_antes->>'nombre',
                           'orden',        (v_antes->>'orden')::integer,
                           'activo',       (v_antes->>'activo')::boolean)::text, true);
    PERFORM set_config('app.datos_nuevos', v_nuevo::text, true);

    UPDATE inventarios.caracteristicas_categorias
       SET categoria_id = p_categoria_id,
           nombre       = TRIM(p_nombre),
           orden        = v_orden,
           activo       = COALESCE(p_activo, true)
     WHERE id = p_id;

    PERFORM set_config('app.datos_anteriores', '', true);
    PERFORM set_config('app.datos_nuevos', '', true);

    RETURN jsonb_build_object('success', true, 'message', 'Característica actualizada exitosamente',
                              'data', inventarios.fn_caracteristicas_json(p_id));

EXCEPTION
    WHEN unique_violation THEN
        RAISE EXCEPTION 'Esa categoría ya tiene otra característica con ese nombre (puede estar en la papelera de reciclaje)' USING ERRCODE = 'P0006';
END;
$function$;


-- ---------------------------------------------------------------------------
-- 8. ACTIVAR / DESACTIVAR
-- ---------------------------------------------------------------------------
-- Desactivarla la saca de la plantilla (no se pide en productos nuevos) pero
-- deja intacto lo que ya rellenaron los productos que la tienen.
CREATE OR REPLACE FUNCTION inventarios.fn_caracteristicas_activar(
    p_id             bigint,
    p_activo         boolean DEFAULT NULL,
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
    v_antes  boolean;
    v_nuevo  boolean;
    v_nombre varchar;
BEGIN
    PERFORM inventarios.fn_contexto_auditoria('inventarios.caracteristicas_categorias',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    SELECT activo, nombre INTO v_antes, v_nombre
      FROM inventarios.caracteristicas_categorias WHERE id = p_id AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'La característica no existe' USING ERRCODE = 'P0013';
    END IF;

    v_nuevo := COALESCE(p_activo, NOT v_antes);   -- sin valor, alterna

    PERFORM set_config('app.datos_anteriores', jsonb_build_object('activo', v_antes)::text, true);
    PERFORM set_config('app.datos_nuevos',     jsonb_build_object('activo', v_nuevo)::text, true);

    UPDATE inventarios.caracteristicas_categorias SET activo = v_nuevo WHERE id = p_id;

    PERFORM set_config('app.datos_anteriores', '', true);
    PERFORM set_config('app.datos_nuevos', '', true);

    RETURN jsonb_build_object('success', true,
        'message', 'Característica «' || v_nombre || '» ' || CASE WHEN v_nuevo THEN 'activada' ELSE 'desactivada' END,
        'data', inventarios.fn_caracteristicas_json(p_id));
END;
$function$;


-- ---------------------------------------------------------------------------
-- 9. A LA PAPELERA (borrado lógico)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION inventarios.fn_caracteristicas_eliminar(
    p_id             bigint,
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
    v_nombre varchar;
    v_quien  varchar;
BEGIN
    PERFORM inventarios.fn_contexto_auditoria('inventarios.caracteristicas_categorias',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    SELECT nombre INTO v_nombre FROM inventarios.caracteristicas_categorias
     WHERE id = p_id AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'La característica no existe' USING ERRCODE = 'P0013';
    END IF;

    v_quien := COALESCE(p_usuario_nombre, p_usuario_login, 'SISTEMA');

    UPDATE inventarios.caracteristicas_categorias
       SET deleted_at = CURRENT_TIMESTAMP, deleted_by = v_quien
     WHERE id = p_id;

    RETURN jsonb_build_object('success', true,
        'message', 'Característica «' || v_nombre || '» enviada a la papelera de reciclaje',
        'data', inventarios.fn_caracteristicas_json(p_id));
END;
$function$;


-- ---------------------------------------------------------------------------
-- 10. LA PAPELERA
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION inventarios.fn_caracteristicas_papelera_listar()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'inventarios'
AS $function$
DECLARE
    v_data jsonb;
BEGIN
    SELECT COALESCE(jsonb_agg(inventarios.fn_caracteristicas_json(k.id) ORDER BY k.deleted_at DESC), '[]'::jsonb)
      INTO v_data
      FROM inventarios.caracteristicas_categorias k
     WHERE k.deleted_at IS NOT NULL;

    RETURN jsonb_build_object('success', true, 'data', v_data);
END;
$function$;


CREATE OR REPLACE FUNCTION inventarios.fn_caracteristicas_restaurar(
    p_ids            jsonb,
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
    v_nombres text[];
    v_cuantas integer;
BEGIN
    PERFORM inventarios.fn_contexto_auditoria('inventarios.caracteristicas_categorias',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    -- Sólo las que están EN la papelera: restaurar una vigente no significa nada
    SELECT array_agg(nombre) INTO v_nombres
      FROM inventarios.caracteristicas_categorias
     WHERE id IN (SELECT (jsonb_array_elements_text(p_ids))::bigint)
       AND deleted_at IS NOT NULL;

    IF v_nombres IS NULL THEN
        RAISE EXCEPTION 'No hay nada que restaurar: esas características no están en la papelera' USING ERRCODE = 'P0019';
    END IF;

    UPDATE inventarios.caracteristicas_categorias
       SET deleted_at = NULL, deleted_by = NULL
     WHERE id IN (SELECT (jsonb_array_elements_text(p_ids))::bigint)
       AND deleted_at IS NOT NULL;

    GET DIAGNOSTICS v_cuantas = ROW_COUNT;

    RETURN jsonb_build_object('success', true,
        'message', v_cuantas || ' característica(s) restaurada(s)',
        'data', jsonb_build_object('nombres', to_jsonb(v_nombres), 'restauradas', v_cuantas));
END;
$function$;


CREATE OR REPLACE FUNCTION inventarios.fn_caracteristicas_eliminar_definitivo(
    p_ids            jsonb,
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
    v_nombres text[];
    v_cuantas integer;
BEGIN
    PERFORM inventarios.fn_contexto_auditoria('inventarios.caracteristicas_categorias',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    SELECT array_agg(nombre) INTO v_nombres
      FROM inventarios.caracteristicas_categorias
     WHERE id IN (SELECT (jsonb_array_elements_text(p_ids))::bigint)
       AND deleted_at IS NOT NULL;

    IF v_nombres IS NULL THEN
        RAISE EXCEPTION 'Sólo se puede eliminar definitivamente lo que está en la papelera' USING ERRCODE = 'P0019';
    END IF;

    -- Lo que los productos ya rellenaron NO se borra: se queda suelto, con su
    -- nombre (la FK es ON DELETE SET NULL). Borrar la plantilla no puede
    -- borrar la ficha de un producto.
    DELETE FROM inventarios.caracteristicas_categorias
     WHERE id IN (SELECT (jsonb_array_elements_text(p_ids))::bigint)
       AND deleted_at IS NOT NULL;

    GET DIAGNOSTICS v_cuantas = ROW_COUNT;

    RETURN jsonb_build_object('success', true,
        'message', v_cuantas || ' característica(s) eliminada(s) definitivamente',
        'data', jsonb_build_object('nombres', to_jsonb(v_nombres), 'borradas', v_cuantas));
END;
$function$;


CREATE OR REPLACE FUNCTION inventarios.fn_caracteristicas_papelera_vaciar(
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
    v_cuantas integer;
BEGIN
    PERFORM inventarios.fn_contexto_auditoria('inventarios.caracteristicas_categorias',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    DELETE FROM inventarios.caracteristicas_categorias WHERE deleted_at IS NOT NULL;
    GET DIAGNOSTICS v_cuantas = ROW_COUNT;

    RETURN jsonb_build_object('success', true,
        'message', 'Papelera vaciada: ' || v_cuantas || ' característica(s)',
        'data', jsonb_build_object('borradas', v_cuantas));
END;
$function$;


-- ---------------------------------------------------------------------------
-- 11. LAS CARACTERÍSTICAS DE UN PRODUCTO (plantilla + lo relleno)
-- ---------------------------------------------------------------------------
-- Devuelve lo que hay que enseñar en el formulario de un producto que YA
-- existe: la plantilla vigente de su categoría con los valores rellenos, MÁS
-- lo que se rellenó en su día y hoy ya no está en la plantilla (se enseña
-- igual, marcado como fuera de plantilla; esconderlo sería perder datos a la
-- vista del usuario).
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

    SELECT COALESCE(jsonb_agg(x ORDER BY x->>'en_plantilla' DESC, (x->>'orden')::integer, x->>'nombre'), '[]'::jsonb)
      INTO v_data
      FROM (
        -- La plantilla vigente de su categoría, con el valor si lo tiene
        SELECT jsonb_build_object(
                   'caracteristica_id', k.id,
                   'nombre',            k.nombre,
                   'orden',             k.orden,
                   'valor',             v.valor,
                   'en_plantilla',      true
               ) AS x
          FROM inventarios.caracteristicas_categorias k
          LEFT JOIN inventarios.caracteristicas_productos v
                 ON v.caracteristica_id = k.id AND v.producto_id = p_producto_id
         WHERE k.categoria_id = v_categoria
           AND k.deleted_at IS NULL
           AND k.activo

        UNION ALL

        -- Lo que el producto tiene relleno y ya no está en la plantilla
        SELECT jsonb_build_object(
                   'caracteristica_id', v.caracteristica_id,
                   'nombre',            v.nombre,
                   'orden',             v.orden,
                   'valor',             v.valor,
                   'en_plantilla',      false
               )
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


-- ---------------------------------------------------------------------------
-- 12. GUARDAR LAS CARACTERÍSTICAS DE UN PRODUCTO
-- ---------------------------------------------------------------------------
-- p_items es lo que mandó el formulario:
--   [{ "caracteristica_id": 3, "nombre": "Procesador", "valor": "i5" }, …]
--
-- Lo que llega VACÍO se borra: una característica sin valor no es un dato, y
-- guardarla como fila vacía ensucia la ficha y las búsquedas. Lo que no
-- llega en la lista también se borra: es la foto completa de la ficha.
CREATE OR REPLACE FUNCTION inventarios.fn_productos_caracteristicas_guardar(
    p_producto_id    bigint,
    p_items          jsonb,
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
    v_guardadas integer := 0;
    v_borradas  integer := 0;
BEGIN
    PERFORM inventarios.fn_contexto_auditoria('inventarios.caracteristicas_productos',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    IF NOT EXISTS (SELECT 1 FROM inventarios.productos WHERE id = p_producto_id) THEN
        RAISE EXCEPTION 'El producto no existe' USING ERRCODE = 'P0013';
    END IF;

    -- Lo que viene con valor, en una tabla de trabajo
    CREATE TEMP TABLE IF NOT EXISTS tmp_carac_prod (
        caracteristica_id bigint,
        nombre            varchar(100),
        valor             text,
        orden             integer
    ) ON COMMIT DROP;
    DELETE FROM tmp_carac_prod;

    INSERT INTO tmp_carac_prod (caracteristica_id, nombre, valor, orden)
    SELECT NULLIF(e->>'caracteristica_id', '')::bigint,
           TRIM(COALESCE(e->>'nombre', '')),
           NULLIF(TRIM(COALESCE(e->>'valor', '')), ''),
           COALESCE(NULLIF(e->>'orden', '')::integer, 1)
      FROM jsonb_array_elements(COALESCE(p_items, '[]'::jsonb)) e
     WHERE NULLIF(TRIM(COALESCE(e->>'valor', '')), '') IS NOT NULL
       AND length(TRIM(COALESCE(e->>'nombre', ''))) > 0;

    -- Fuera lo que ya no está (vaciado o quitado de la lista)
    DELETE FROM inventarios.caracteristicas_productos v
     WHERE v.producto_id = p_producto_id
       AND NOT EXISTS (
           SELECT 1 FROM tmp_carac_prod t
            WHERE (t.caracteristica_id IS NOT NULL AND t.caracteristica_id = v.caracteristica_id)
               OR (t.caracteristica_id IS NULL AND v.caracteristica_id IS NULL
                   AND UPPER(TRIM(t.nombre)) = UPPER(TRIM(v.nombre))));
    GET DIAGNOSTICS v_borradas = ROW_COUNT;

    -- Las que vienen de la plantilla: una fila por característica
    INSERT INTO inventarios.caracteristicas_productos (producto_id, caracteristica_id, nombre, valor, orden)
    SELECT p_producto_id, t.caracteristica_id, t.nombre, t.valor, t.orden
      FROM tmp_carac_prod t
     WHERE t.caracteristica_id IS NOT NULL
        ON CONFLICT (producto_id, caracteristica_id) WHERE caracteristica_id IS NOT NULL
        DO UPDATE SET nombre = EXCLUDED.nombre,
                      valor  = EXCLUDED.valor,
                      orden  = EXCLUDED.orden;
    GET DIAGNOSTICS v_guardadas = ROW_COUNT;

    -- Las sueltas (sin plantilla detrás), por nombre
    INSERT INTO inventarios.caracteristicas_productos (producto_id, caracteristica_id, nombre, valor, orden)
    SELECT p_producto_id, NULL, t.nombre, t.valor, t.orden
      FROM tmp_carac_prod t
     WHERE t.caracteristica_id IS NULL
        ON CONFLICT (producto_id, (UPPER(TRIM(nombre)))) WHERE caracteristica_id IS NULL
        DO UPDATE SET valor = EXCLUDED.valor,
                      orden = EXCLUDED.orden;

    RETURN jsonb_build_object('success', true,
        'message', 'Características guardadas',
        'data', jsonb_build_object('guardadas', v_guardadas, 'borradas', v_borradas));
END;
$function$;
