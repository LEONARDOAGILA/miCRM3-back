-- ============================================================================
-- ECOMMERCE · EL MENÚ DE CATEGORÍAS DE LA TIENDA
-- ============================================================================
-- Fecha: 2026-11-01
--
-- Es el desplegable «CATEGORÍAS» del encabezado y lo que arma el panel de
-- filtros de /shop. La tienda lo pide en `publico/categorias-menu` y hasta
-- ahora daba 404.
--
-- NO SE TRAE NADA DEL CRM VIEJO, y conviene entender por qué. Allí la
-- configuración de la web vivía EN LA PROPIA TABLA DEL ERP
-- (`public.tipo_producto.tpr_web_visible`, `tpr_web_oculta`,
-- `tpr_web_nombre`): el ERP y la tienda compartían base, así que se añadieron
-- columnas y ya está. Aquí el catálogo es `inventarios.categorias`, que es de
-- inventarios y no de la tienda, y meterle columnas de la web sería que un
-- módulo escriba en la tabla de otro. Va aparte, en
-- `ecommerce.categorias_web`, apuntando a la categoría por su id.
--
-- POR DEFECTO SE VE TODO. En el CRM viejo había que ENCENDER cada
-- departamento (`tpr_web_visible`), y una tienda nueva arrancaba con el menú
-- vacío sin que nadie supiera por qué. Aquí sólo se guarda lo que se APAGA:
-- sin una fila en esta tabla, la categoría se ve. Lo normal no necesita
-- configurarse.
--
-- LA REGLA DE QUÉ SALE, que sí se conserva del CRM viejo porque es buena:
--
--   · se parte de las categorías DE TRANSACCIÓN, que son donde cuelgan los
--     productos;
--   · se descarta la que esté oculta, ella o cualquiera de sus padres;
--   · y salen ésas MÁS SUS PADRES. Así una rama que agrupa pero que no tiene
--     ninguna categoría de producto visible debajo no aparece: sería un menú
--     que se abre y no lleva a ningún sitio.
--
-- Idempotente.
-- ============================================================================
\set ON_ERROR_STOP on

BEGIN;

-- ----------------------------------------------------------------------------
-- 1. LO QUE SE APAGA
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS ecommerce.categorias_web (
    categoria_id bigint      NOT NULL,
    -- Oculta ESTA categoría y todo lo que cuelgue de ella
    oculta       boolean     NOT NULL DEFAULT false,
    -- El nombre con el que se enseña en la tienda, si no vale el del catálogo
    -- («Línea Blanca» dentro, «Electrodomésticos» fuera)
    nombre_web   varchar(80),
    created_at   timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at   timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    created_by   varchar(100),
    updated_by   varchar(100),
    CONSTRAINT pk_categorias_web PRIMARY KEY (categoria_id),
    CONSTRAINT fk_categorias_web_categoria
        FOREIGN KEY (categoria_id) REFERENCES inventarios.categorias(id)
);

COMMENT ON TABLE ecommerce.categorias_web IS
    'Lo que la tienda hace DISTINTO con una categoría del catálogo. Sin fila, se ve con su nombre.';

DO $disparadores$
BEGIN
    DROP TRIGGER IF EXISTS trg_categorias_web_audit ON ecommerce.categorias_web;
    CREATE TRIGGER trg_categorias_web_audit AFTER INSERT OR UPDATE OR DELETE
        ON ecommerce.categorias_web FOR EACH ROW EXECUTE FUNCTION auditoria.fn_auditar_cambios();

    DROP TRIGGER IF EXISTS trg_categorias_web_updated_at ON ecommerce.categorias_web;
    CREATE TRIGGER trg_categorias_web_updated_at BEFORE UPDATE
        ON ecommerce.categorias_web FOR EACH ROW EXECUTE FUNCTION auditoria.fn_update_updated_at_column();

    DROP TRIGGER IF EXISTS trg_categorias_web_users ON ecommerce.categorias_web;
    CREATE TRIGGER trg_categorias_web_users BEFORE INSERT OR UPDATE
        ON ecommerce.categorias_web FOR EACH ROW EXECUTE FUNCTION auditoria.fn_set_audit_users();
END
$disparadores$;

-- ----------------------------------------------------------------------------
-- 2. QUÉ CATEGORÍAS SE VEN, Y POR QUÉ
-- ----------------------------------------------------------------------------
-- Devuelve TODAS con su estado, no sólo las visibles: la pantalla de
-- administración tiene que poder decir «ésta no sale porque la apagaste» y
-- «ésta tampoco, pero porque no tiene ninguna de producto debajo», que son
-- dos problemas distintos con dos arreglos distintos.
CREATE OR REPLACE FUNCTION ecommerce.fn_categorias_web_estado()
 RETURNS TABLE(id bigint, padre_id bigint, nivel integer, orden integer,
               nombre text, estado text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
AS $function$
    WITH RECURSIVE
    vivas AS (
        SELECT c.id, c.padre_id, c.nivel, c.orden, c.nombre, c.es_transaccion, c.activo,
               COALESCE(w.oculta, false) AS oculta,
               COALESCE(NULLIF(btrim(w.nombre_web), ''), c.nombre) AS nombre_web
          FROM inventarios.categorias c
          LEFT JOIN ecommerce.categorias_web w ON w.categoria_id = c.id
         WHERE c.deleted_at IS NULL
    ),
    -- Apagadas: las que lo están, y todo lo que cuelgue de ellas
    apagadas AS (
        SELECT v.id FROM vivas v WHERE v.oculta OR NOT v.activo
        UNION
        SELECT h.id FROM vivas h JOIN apagadas a ON h.padre_id = a.id
    ),
    -- Las que de verdad llevan productos y no están apagadas
    con_productos AS (
        SELECT v.id, v.padre_id FROM vivas v
         WHERE v.es_transaccion AND v.id NOT IN (SELECT id FROM apagadas)
    ),
    -- Ésas y sus padres: una rama sin ninguna de producto debajo no sale
    visibles AS (
        SELECT p.id, p.padre_id FROM con_productos p
        UNION
        SELECT v.id, v.padre_id
          FROM vivas v
          JOIN visibles s ON s.padre_id = v.id
         WHERE v.id NOT IN (SELECT id FROM apagadas)
    )
    SELECT v.id, v.padre_id, v.nivel, v.orden, v.nombre_web,
           CASE
               WHEN vi.id IS NOT NULL                       THEN 'visible'
               WHEN v.oculta                                THEN 'oculta'
               WHEN NOT v.activo                            THEN 'inactiva'
               WHEN v.id IN (SELECT id FROM apagadas)       THEN 'oculta_por_padre'
               ELSE                                              'sin_categorias_de_producto'
           END
      FROM vivas v
      LEFT JOIN (SELECT DISTINCT visibles.id FROM visibles) vi ON vi.id = v.id;
$function$;

-- ----------------------------------------------------------------------------
-- 3. EL ÁRBOL QUE LEE LA TIENDA
-- ----------------------------------------------------------------------------
-- {id, nombre, hijos:[…]} anidado, que es lo que espera el menú. Tres niveles
-- —departamento, categoría, subcategoría—, que es lo que tiene el catálogo y
-- lo que la tienda sabe pintar.
CREATE OR REPLACE FUNCTION ecommerce.fn_categorias_web_menu_publico()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
AS $function$
    WITH v AS (
        SELECT * FROM ecommerce.fn_categorias_web_estado() WHERE estado = 'visible'
    )
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'id', d.id, 'nombre', d.nombre,
               'hijos', COALESCE((
                   SELECT jsonb_agg(jsonb_build_object(
                              'id', c.id, 'nombre', c.nombre,
                              'hijos', COALESCE((
                                  SELECT jsonb_agg(jsonb_build_object('id', s.id, 'nombre', s.nombre, 'hijos', '[]'::jsonb)
                                         ORDER BY s.orden, s.nombre)
                                    FROM v s WHERE s.padre_id = c.id), '[]'::jsonb))
                          ORDER BY c.orden, c.nombre)
                     FROM v c WHERE c.padre_id = d.id), '[]'::jsonb))
           ORDER BY d.orden, d.nombre), '[]'::jsonb)
      FROM v d
     WHERE d.padre_id IS NULL;
$function$;

-- ----------------------------------------------------------------------------
-- 4. QUE DE VERDAD DEVUELVA ALGO
-- ----------------------------------------------------------------------------
DO $comprobar$
DECLARE
    v_arbol   jsonb;
    v_raices  integer;
    v_visibles integer;
    v_total   integer;
BEGIN
    SELECT count(*) INTO v_total FROM inventarios.categorias WHERE deleted_at IS NULL;
    SELECT count(*) INTO v_visibles FROM ecommerce.fn_categorias_web_estado() WHERE estado = 'visible';

    v_arbol := ecommerce.fn_categorias_web_menu_publico();
    v_raices := jsonb_array_length(v_arbol);

    IF v_raices = 0 THEN
        RAISE EXCEPTION 'El menú de categorías salió vacío (de % categorías, % visibles)', v_total, v_visibles;
    END IF;

    -- Ninguna rama puede quedarse sin nombre: la tienda las tira y el hueco
    -- no se ve venir
    IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_arbol) d WHERE COALESCE(d ->> 'nombre', '') = '') THEN
        RAISE EXCEPTION 'Hay departamentos sin nombre en el menú';
    END IF;

    RAISE NOTICE 'Menú de categorías: % departamentos, % categorías visibles de %.',
          v_raices, v_visibles, v_total;
END
$comprobar$;

COMMIT;
