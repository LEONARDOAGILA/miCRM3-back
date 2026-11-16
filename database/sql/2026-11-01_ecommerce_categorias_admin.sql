-- ============================================================================
-- ECOMMERCE · ADMINISTRAR LAS CATEGORÍAS DE LA TIENDA
-- ============================================================================
-- Fecha: 2026-11-01
--
-- La tabla `ecommerce.categorias_web` y la vista de estado ya existen (ver
-- 2026-11-01_ecommerce_categorias_web.sql). Esto es lo que necesita la
-- pantalla: leer el árbol con el porqué de cada estado y poder apagar una
-- rama o cambiarle el nombre para la web.
--
-- AQUÍ NO SE REORDENA NI SE RENOMBRA EL CATÁLOGO. El orden y el nombre de la
-- categoría son de `inventarios.categorias`, que es de inventarios: esta
-- pantalla sólo decide qué sale en la tienda y con qué nombre se enseña ahí.
-- Para cambiar el árbol de verdad está Inventarios → Categorías.
--
-- SÓLO SE GUARDA LO QUE SE APARTA DE LO NORMAL. Una categoría visible y con
-- su nombre de siempre NO tiene fila: al dejarla así, la fila se borra. Si
-- no, la tabla acabaría con una fila por categoría diciendo «todo normal».
--
-- Idempotente.
-- ============================================================================
\set ON_ERROR_STOP on

BEGIN;

-- ----------------------------------------------------------------------------
-- 0. ARREGLO DE LA TABLA: LE FALTABA `id`
-- ----------------------------------------------------------------------------
-- La creé con `categoria_id` como clave primaria y sin `id`, saliéndome de la
-- convención de la casa. Eso rompe el disparador de auditoría, que busca la
-- columna `id` para saber a qué fila se refiere el apunte: al guardar
-- cualquier cosa fallaba con «el registro new no tiene un campo id».
--
-- Se añade `id` como clave y `categoria_id` se queda como único, que es lo
-- que de verdad quería decir: una configuración por categoría.
DO $arreglar$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                    WHERE table_schema = 'ecommerce' AND table_name = 'categorias_web'
                      AND column_name = 'id') THEN

        ALTER TABLE ecommerce.categorias_web DROP CONSTRAINT IF EXISTS pk_categorias_web;
        ALTER TABLE ecommerce.categorias_web ADD COLUMN id bigint;

        CREATE SEQUENCE IF NOT EXISTS ecommerce.categorias_web_id_seq
            OWNED BY ecommerce.categorias_web.id;
        ALTER TABLE ecommerce.categorias_web
            ALTER COLUMN id SET DEFAULT nextval('ecommerce.categorias_web_id_seq');

        UPDATE ecommerce.categorias_web SET id = nextval('ecommerce.categorias_web_id_seq')
         WHERE id IS NULL;

        ALTER TABLE ecommerce.categorias_web ALTER COLUMN id SET NOT NULL;
        ALTER TABLE ecommerce.categorias_web ADD CONSTRAINT pk_categorias_web PRIMARY KEY (id);
        ALTER TABLE ecommerce.categorias_web ADD CONSTRAINT uq_categorias_web_categoria
            UNIQUE (categoria_id);

        RAISE NOTICE 'categorias_web: añadida la columna id, categoria_id pasa a único.';
    END IF;
END
$arreglar$;

-- ----------------------------------------------------------------------------
-- 1. EL ÁRBOL PARA LA PANTALLA
-- ----------------------------------------------------------------------------
-- Con el porqué de cada estado, que es lo que hace útil la pantalla: no es lo
-- mismo «la apagaste tú» que «no tiene ninguna categoría de producto debajo»,
-- y cada una se arregla de una forma distinta.
CREATE OR REPLACE FUNCTION ecommerce.fn_categorias_web_listar()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
AS $function$
    SELECT jsonb_build_object('success', true, 'message', 'Categorías de la tienda',
        'data', COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
                       'id',             e.id,
                       'padre_id',       e.padre_id,
                       'nivel',          e.nivel,
                       'orden',          e.orden,
                       -- El de la tienda (el propio si no se cambió)
                       'nombre',         e.nombre,
                       -- El del catálogo, para poder compararlos
                       'nombre_catalogo', c.nombre,
                       'nombre_web',     w.nombre_web,
                       'oculta',         COALESCE(w.oculta, false),
                       'es_transaccion', c.es_transaccion,
                       'activo',         c.activo,
                       'estado',         e.estado)
                   ORDER BY e.nivel, e.orden, e.nombre)
              FROM ecommerce.fn_categorias_web_estado() e
              JOIN inventarios.categorias c ON c.id = e.id
              LEFT JOIN ecommerce.categorias_web w ON w.categoria_id = e.id), '[]'::jsonb));
$function$;

-- ----------------------------------------------------------------------------
-- 2. APAGAR UNA RAMA O CAMBIARLE EL NOMBRE
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ecommerce.fn_categorias_web_guardar(
    p_categoria_id bigint, p_oculta boolean, p_nombre_web character varying,
    p_usuario_id bigint DEFAULT NULL, p_usuario_login character varying DEFAULT NULL,
    p_usuario_nombre character varying DEFAULT NULL, p_ip_address inet DEFAULT NULL,
    p_user_agent text DEFAULT NULL, p_request_id uuid DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'ecommerce', 'auditoria'
AS $function$
DECLARE
    v_nombre  text;
    v_oculta  boolean := COALESCE(p_oculta, false);
    v_catalogo text;
BEGIN
    PERFORM ecommerce.fn_contexto_auditoria('ecommerce.categorias_web',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    SELECT nombre INTO v_catalogo FROM inventarios.categorias
     WHERE id = p_categoria_id AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'La categoría no existe' USING ERRCODE = 'P0013';
    END IF;

    v_nombre := ecommerce.fn_validar_texto(p_nombre_web, 'El nombre para la tienda', 80);

    -- El mismo nombre del catálogo no es «otro nombre»: se guarda como nada,
    -- para que al renombrar la categoría en Inventarios la tienda la siga.
    IF v_nombre IS NOT NULL AND lower(btrim(v_nombre)) = lower(btrim(v_catalogo)) THEN
        v_nombre := NULL;
    END IF;

    IF v_oculta OR v_nombre IS NOT NULL THEN
        INSERT INTO ecommerce.categorias_web (categoria_id, oculta, nombre_web)
        VALUES (p_categoria_id, v_oculta, v_nombre)
        ON CONFLICT (categoria_id) DO UPDATE
            SET oculta = EXCLUDED.oculta, nombre_web = EXCLUDED.nombre_web;
    ELSE
        -- Visible y con su nombre de siempre: no hace falta guardar nada
        DELETE FROM ecommerce.categorias_web WHERE categoria_id = p_categoria_id;
    END IF;

    RETURN jsonb_build_object('success', true,
        'message', format('«%s» %s', COALESCE(v_nombre, v_catalogo),
                          CASE WHEN v_oculta THEN 'no saldrá en la tienda' ELSE 'saldrá en la tienda' END),
        'data', (ecommerce.fn_categorias_web_listar() -> 'data'));
END;
$function$;

-- ----------------------------------------------------------------------------
-- 3. QUE HAGA LO QUE DICE
-- ----------------------------------------------------------------------------
DO $comprobar$
DECLARE
    v_id    bigint;
    v_antes integer;
    v_desp  integer;
    v       jsonb;
BEGIN
    -- Una categoría de producto cualquiera, con hermanas, para no dejar su
    -- rama entera fuera y poder comparar
    SELECT e.id INTO v_id
      FROM ecommerce.fn_categorias_web_estado() e
      JOIN inventarios.categorias c ON c.id = e.id
     WHERE e.estado = 'visible' AND c.es_transaccion
       AND EXISTS (SELECT 1 FROM inventarios.categorias h
                    WHERE h.padre_id = c.padre_id AND h.id <> c.id AND h.deleted_at IS NULL)
     LIMIT 1;

    IF v_id IS NULL THEN
        RAISE NOTICE 'No hay una categoría con hermanas: me salto la comprobación.';
        RETURN;
    END IF;

    SELECT count(*) INTO v_antes FROM ecommerce.fn_categorias_web_estado() WHERE estado = 'visible';

    PERFORM ecommerce.fn_categorias_web_guardar(v_id, true, NULL);
    SELECT count(*) INTO v_desp FROM ecommerce.fn_categorias_web_estado() WHERE estado = 'visible';
    IF v_desp >= v_antes THEN
        RAISE EXCEPTION 'Apagarla no la quitó del menú (antes % visibles, después %)', v_antes, v_desp;
    END IF;

    -- Y vuelve
    PERFORM ecommerce.fn_categorias_web_guardar(v_id, false, NULL);
    SELECT count(*) INTO v_desp FROM ecommerce.fn_categorias_web_estado() WHERE estado = 'visible';
    IF v_desp <> v_antes THEN
        RAISE EXCEPTION 'Encenderla no la devolvió (% vs %)', v_desp, v_antes;
    END IF;

    -- Y, al dejarla como estaba, no queda fila de configuración
    IF EXISTS (SELECT 1 FROM ecommerce.categorias_web WHERE categoria_id = v_id) THEN
        RAISE EXCEPTION 'Quedó una fila de configuración para una categoría que está como siempre';
    END IF;

    -- El nombre igual al del catálogo tampoco se guarda
    PERFORM ecommerce.fn_categorias_web_guardar(v_id, false,
        (SELECT nombre FROM inventarios.categorias WHERE id = v_id));
    IF EXISTS (SELECT 1 FROM ecommerce.categorias_web WHERE categoria_id = v_id) THEN
        RAISE EXCEPTION 'Se guardó un «nombre para la web» que es el mismo del catálogo';
    END IF;

    RAISE NOTICE 'Comprobado: apagar quita del menú, encender devuelve, y lo normal no se guarda.';
END
$comprobar$;

COMMIT;
