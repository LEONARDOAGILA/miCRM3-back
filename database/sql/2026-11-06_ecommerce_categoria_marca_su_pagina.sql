-- ============================================================================
-- ECOMMERCE · CADA CATEGORÍA Y CADA MARCA DICEN SI TIENEN PÁGINA
-- ============================================================================
-- Fecha: 2026-11-06
-- Va DESPUÉS de 2026-11-06_ecommerce_enlaces_de_cuerpo.sql.
--
-- Las pantallas de categorías y de marcas explican, campo por campo, QUÉ PASA
-- en la tienda con lo que se marca: «Destacada la pone en los círculos de
-- arriba», «la imagen que usan las dos secciones». Lo único que no decían es
-- lo más gordo que puede pasar ahora: que al pincharla se abra SU PÁGINA en
-- vez del catálogo filtrado.
--
-- Así que el listado del CRM trae `cuerpo`: la página de esa categoría o de
-- esa marca, o null. VIENE TAMBIÉN SI ESTÁ APAGADA —por eso no se usa
-- `fn_cuerpo_de_categoria`, que sólo mira las encendidas—: una página apagada
-- existe, no recibe clics, y eso es justo lo que hay que poder ver desde aquí.
--
-- AQUÍ NO SE CREA NI SE EDITA EL CUERPO. Se enseña y se enlaza. Un cuerpo es
-- una página con su dirección, su título, su texto y sus secciones; meterlo en
-- un campo de esta pantalla sería tener dos sitios que editan lo mismo, y el
-- día que no digan lo mismo nadie sabrá cuál manda.
--
-- Idempotente.
-- ============================================================================
\set ON_ERROR_STOP on

BEGIN;

-- ----------------------------------------------------------------------------
-- 1. LA PÁGINA DE UNA CATEGORÍA O DE UNA MARCA, PARA EL CRM
-- ----------------------------------------------------------------------------
-- Con su estado: la pantalla tiene que poder decir «tiene página, pero está
-- apagada», que es distinto de no tenerla.
CREATE OR REPLACE FUNCTION ecommerce.fn_cuerpo_json_de(p_categoria_id bigint, p_marca_id bigint)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
AS $function$
    SELECT jsonb_build_object(
               'id',     c.id,
               'nombre', c.nombre,
               'ruta',   c.ruta,
               'url',    CASE WHEN c.principal THEN '/' ELSE '/' || c.ruta END,
               'activo', c.activo)
      FROM ecommerce.cuerpos c
     WHERE c.deleted_at IS NULL
       AND ((p_categoria_id IS NOT NULL AND c.categoria_id = p_categoria_id)
         OR (p_marca_id     IS NOT NULL AND c.marca_id     = p_marca_id));
$function$;

COMMENT ON FUNCTION ecommerce.fn_cuerpo_json_de(bigint, bigint) IS
    'La página de esa categoría o marca como la ve el CRM, encendida o no; null si no tiene.';

-- ----------------------------------------------------------------------------
-- 2. EL LISTADO DE CATEGORÍAS
-- ----------------------------------------------------------------------------
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
                       'destacada',      e.destacada,
                       'destacada_orden', e.destacada_orden,
                       'promocion',      e.promocion,
                       'promocion_orden', e.promocion_orden,
                       'orden_web',      e.orden_web,
                       'es_transaccion', c.es_transaccion,
                       'activo',         c.activo,
                       'estado',         e.estado,
                       -- Su página, si tiene. Es lo que decide a dónde lleva el
                       -- clic en esta categoría en toda la tienda
                       'cuerpo',         ecommerce.fn_cuerpo_json_de(e.id, NULL))
                   -- En el orden de la TIENDA: es el que se administra aquí
                   ORDER BY e.nivel, e.orden_web NULLS LAST, e.orden, e.nombre)
              FROM ecommerce.fn_categorias_web_estado() e
              JOIN inventarios.categorias c ON c.id = e.id
              LEFT JOIN ecommerce.categorias_web w ON w.categoria_id = e.id), '[]'::jsonb));
$function$;

-- ----------------------------------------------------------------------------
-- 3. Y EL DE MARCAS, QUE TIENE LA MISMA PREGUNTA
-- ----------------------------------------------------------------------------
-- Cirugía: la función de marcas es larga y lo único que cambia es una clave.
DO $cirugia$
DECLARE
    v_def text;
BEGIN
    SELECT pg_get_functiondef(p.oid) INTO v_def
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'ecommerce' AND p.proname = 'fn_marcas_web_listar';

    IF v_def IS NULL THEN
        RAISE EXCEPTION 'No está ecommerce.fn_marcas_web_listar';
    END IF;

    -- El guardia mira lo NUEVO
    IF position('fn_cuerpo_json_de' IN v_def) > 0 THEN
        RAISE NOTICE 'El listado de marcas ya decía si tienen página: no se toca.';
        RETURN;
    END IF;

    IF position('''estado'',' IN v_def) = 0 THEN
        RAISE EXCEPTION 'No encuentro dónde enganchar la página en fn_marcas_web_listar';
    END IF;

    v_def := replace(v_def, '''estado'',',
        '''cuerpo'', ecommerce.fn_cuerpo_json_de(NULL, e.id),' || E'\n                       ' ||
        '''estado'',');

    EXECUTE v_def;
    RAISE NOTICE 'El listado de marcas ya dice si tienen página.';
END
$cirugia$;

-- ----------------------------------------------------------------------------
-- 4. COMPROBACIÓN
-- ----------------------------------------------------------------------------
DO $comprobar$
DECLARE
    v_categoria bigint;
    v_cuerpo    bigint;
    v_fila      jsonb;
BEGIN
    SELECT id INTO v_categoria FROM ecommerce.fn_categorias_web_estado()
     WHERE estado = 'visible' ORDER BY id LIMIT 1;
    IF v_categoria IS NULL THEN
        RAISE EXCEPTION 'Sin categorías visibles no se puede comprobar';
    END IF;

    -- Sin página, null
    SELECT c INTO v_fila FROM jsonb_array_elements(ecommerce.fn_categorias_web_listar() -> 'data') c
     WHERE (c ->> 'id')::bigint = v_categoria;
    IF v_fila IS NULL THEN
        RAISE EXCEPTION 'La categoría % no sale en el listado', v_categoria;
    END IF;
    IF ecommerce.fn_cuerpo_json_de(v_categoria, NULL) IS NULL AND v_fila -> 'cuerpo' <> 'null'::jsonb THEN
        RAISE EXCEPTION 'Sin página, `cuerpo` tiene que ser null: %', v_fila -> 'cuerpo';
    END IF;

    -- Y el de marcas trae la clave
    IF NOT (ecommerce.fn_marcas_web_listar() -> 'data' -> 0 ? 'cuerpo')
       AND jsonb_array_length(ecommerce.fn_marcas_web_listar() -> 'data') > 0 THEN
        RAISE EXCEPTION 'El listado de marcas no trae `cuerpo`';
    END IF;

    BEGIN
        v_cuerpo := (ecommerce.fn_cuerpos_guardar(NULL, jsonb_build_object(
                         'nombre', 'ZZ pagina claude', 'ruta', 'zz-pagina-claude',
                         'categoria_id', v_categoria)) -> 'data' ->> 'id')::bigint;

        SELECT c INTO v_fila FROM jsonb_array_elements(ecommerce.fn_categorias_web_listar() -> 'data') c
         WHERE (c ->> 'id')::bigint = v_categoria;
        IF v_fila -> 'cuerpo' ->> 'ruta' <> 'zz-pagina-claude' THEN
            RAISE EXCEPTION 'La categoría no dice cuál es su página: %', v_fila -> 'cuerpo';
        END IF;
        IF (v_fila -> 'cuerpo' ->> 'activo')::boolean IS NOT TRUE THEN
            RAISE EXCEPTION 'Debería decir que está encendida: %', v_fila -> 'cuerpo';
        END IF;

        -- Apagada sigue saliendo, y diciendo que está apagada: es lo que hay
        -- que poder ver desde aquí
        PERFORM ecommerce.fn_cuerpos_activar(v_cuerpo, false);
        SELECT c INTO v_fila FROM jsonb_array_elements(ecommerce.fn_categorias_web_listar() -> 'data') c
         WHERE (c ->> 'id')::bigint = v_categoria;
        IF v_fila -> 'cuerpo' ->> 'ruta' IS NULL THEN
            RAISE EXCEPTION 'Una página apagada tiene que seguir saliendo en el CRM';
        END IF;
        IF (v_fila -> 'cuerpo' ->> 'activo')::boolean IS NOT FALSE THEN
            RAISE EXCEPTION 'Y tiene que decir que está apagada: %', v_fila -> 'cuerpo';
        END IF;

        RAISE EXCEPTION 'deshacer' USING ERRCODE = 'P0099';
    EXCEPTION WHEN SQLSTATE 'P0099' THEN
        NULL;
    END;

    IF EXISTS (SELECT 1 FROM ecommerce.cuerpos WHERE nombre LIKE 'ZZ %claude') THEN
        RAISE EXCEPTION 'El cuerpo de prueba se quedó en la base';
    END IF;

    RAISE NOTICE 'Comprobado: cada categoría y cada marca dicen si tienen página, con su dirección, y una apagada lo dice en vez de desaparecer. No quedó nada.';
END
$comprobar$;

COMMIT;
