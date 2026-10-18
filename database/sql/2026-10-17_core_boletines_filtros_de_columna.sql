-- ===========================================================================
-- BOLETINES: FILTROS DE COLUMNA EN EL SERVIDOR
-- ===========================================================================
-- Fecha: 2026-10-17
-- Se aplica después de 2026-10-16_seguridad_usuarios_filtros_de_columna.sql.
--
-- Lo mismo que ya tienen clientes, productos, categorías, marcas y usuarios,
-- ahora en boletines: LOS FILTROS DE LA CABECERA SE APLICAN AQUÍ, no en el
-- navegador. La pantalla pagina, así que ag-Grid sólo tiene las filas de la
-- página y filtrar ahí buscaría dentro de diez. El modelo llega en p_filtros,
-- ya traducido por el controlador:
--
--     {"titulo": {"op":"contains","valor":"sistema"},
--      "num_vistos": {"op":"greaterThan","valor":"0"}}
--
-- Se reusan ventas.fn_filtro_texto y ventas.fn_filtro_numero (comparan sin
-- tildes y sin distinguir mayúsculas).
--
-- SE FILTRA POR LO QUE SE VE, NO POR LO QUE HAY DEBAJO:
--   · «Estado» no es una columna de la tabla, se calcula con `activo` y las
--     fechas. Se filtra por ese valor calculado, que es el que sale en la
--     rejilla (VIGENTE, PROGRAMADO, CADUCADO, INACTIVO). El combo de la barra
--     sigue estando y se suma: los dos son «y», no «o».
--   · «Imágenes», «Destinatarios» y «Vistos» son cuentas de otras tablas; se
--     filtran con el mismo subselect que las pinta.
--   · Las fechas se filtran como texto sobre lo que se ve («2026-10» es el mes).
--
-- El resto no cambia: sigue sin enseñar lo que está en la papelera, sigue
-- ordenando por `orden` —que es el que se arrastra— y sigue devolviendo
-- `en_papelera` para el contador del botón.
--
-- Cambia la firma, así que se suelta la función antes: un CREATE OR REPLACE
-- con otra firma deja DOS funciones y la llamada de cuatro argumentos se
-- vuelve ambigua. El único que la llama es BoletinController.
-- Idempotente.
-- ===========================================================================

DROP FUNCTION IF EXISTS core.fn_boletines_listar_paginado(integer, integer, text, text);

CREATE OR REPLACE FUNCTION core.fn_boletines_listar_paginado(
    p_page     integer DEFAULT 1,
    p_per_page integer DEFAULT 15,
    p_search   text    DEFAULT '',
    p_estado   text    DEFAULT 'TODOS',
    -- Los filtros de la cabecera de ag-Grid, columna por columna
    p_filtros  jsonb   DEFAULT '{}'::jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'core', 'ventas'
AS $function$
DECLARE
    v_offset integer;
    v_total  bigint;
    v_filtro text;
    v_estado text;
    v_data   jsonb;
BEGIN
    v_offset := (GREATEST(COALESCE(p_page, 1), 1) - 1) * GREATEST(COALESCE(p_per_page, 15), 1);
    v_filtro := NULLIF(TRIM(COALESCE(p_search, '')), '');
    v_estado := UPPER(COALESCE(NULLIF(TRIM(p_estado), ''), 'TODOS'));

    WITH filtrados AS (
        SELECT b.id, b.orden
          FROM core.boletines b
         WHERE b.deleted_at IS NULL              -- lo de la papelera no sale
           AND (v_filtro IS NULL
                OR b.titulo      ILIKE '%' || v_filtro || '%'
                OR b.descripcion ILIKE '%' || v_filtro || '%'
                OR b.id::text    ILIKE '%' || v_filtro || '%')

           -- El combo de la barra, como siempre
           AND (v_estado = 'TODOS'
                OR (v_estado = 'VIGENTE'    AND b.activo AND CURRENT_DATE BETWEEN b.desde AND b.hasta)
                OR (v_estado = 'PROGRAMADO' AND b.activo AND CURRENT_DATE < b.desde)
                OR (v_estado = 'CADUCADO'   AND b.activo AND CURRENT_DATE > b.hasta)
                OR (v_estado = 'INACTIVO'   AND NOT b.activo))

           -- ---------- LOS FILTROS DE LA CABECERA ----------
           AND (p_filtros->'id'     IS NULL OR ventas.fn_filtro_numero(b.id,     p_filtros->'id'))
           AND (p_filtros->'orden'  IS NULL OR ventas.fn_filtro_numero(b.orden,  p_filtros->'orden'))
           AND (p_filtros->'titulo' IS NULL OR ventas.fn_filtro_texto(b.titulo,  p_filtros->'titulo'))
           -- El estado es el MISMO cálculo que pinta la columna
           AND (p_filtros->'estado' IS NULL OR ventas.fn_filtro_texto(
                   CASE WHEN NOT b.activo           THEN 'INACTIVO'
                        WHEN CURRENT_DATE < b.desde THEN 'PROGRAMADO'
                        WHEN CURRENT_DATE > b.hasta THEN 'CADUCADO'
                        ELSE 'VIGENTE' END, p_filtros->'estado'))
           -- Las fechas, como texto sobre lo que se ve: «2026-10» busca el mes
           AND (p_filtros->'desde'  IS NULL OR ventas.fn_filtro_texto(to_char(b.desde, 'YYYY-MM-DD'), p_filtros->'desde'))
           AND (p_filtros->'hasta'  IS NULL OR ventas.fn_filtro_texto(to_char(b.hasta, 'YYYY-MM-DD'), p_filtros->'hasta'))
           -- Las cuentas, con el mismo subselect que las pinta
           AND (p_filtros->'num_imagenes' IS NULL OR ventas.fn_filtro_numero(
                   (SELECT COUNT(*) FROM core.boletines_imagenes i WHERE i.boletin_id = b.id),
                   p_filtros->'num_imagenes'))
           AND (p_filtros->'num_usuarios' IS NULL OR ventas.fn_filtro_numero(
                   (SELECT COUNT(*) FROM core.boletines_usuarios bu WHERE bu.boletin_id = b.id),
                   p_filtros->'num_usuarios'))
           AND (p_filtros->'num_vistos'   IS NULL OR ventas.fn_filtro_numero(
                   (SELECT COUNT(*) FROM core.boletines_vistos v WHERE v.boletin_id = b.id),
                   p_filtros->'num_vistos'))
    )
    SELECT COUNT(*),
           COALESCE((SELECT jsonb_agg(core.fn_boletines_json(t.id) ORDER BY t.orden, t.id)
                       FROM (SELECT f.id, f.orden FROM filtrados f
                              ORDER BY f.orden, f.id
                              LIMIT GREATEST(COALESCE(p_per_page, 15), 1) OFFSET v_offset) t), '[]'::jsonb)
      INTO v_total, v_data
      FROM filtrados;

    RETURN jsonb_build_object(
        'success', true,
        'message', 'La solicitud ha tenido éxito',
        'data', jsonb_build_object(
            'data',         v_data,
            'current_page', GREATEST(COALESCE(p_page, 1), 1),
            'per_page',     GREATEST(COALESCE(p_per_page, 15), 1),
            'total',        v_total,
            'last_page',    GREATEST(CEIL(v_total::numeric / NULLIF(GREATEST(COALESCE(p_per_page, 15), 1), 0))::int, 1),
            -- Para el contador del botón de la papelera, sin pedir otra vuelta
            'en_papelera',  (SELECT COUNT(*) FROM core.boletines WHERE deleted_at IS NOT NULL)
        )
    );
END;
$function$;

ALTER FUNCTION core.fn_boletines_listar_paginado(integer, integer, text, text, jsonb) OWNER TO postgres;

COMMENT ON FUNCTION core.fn_boletines_listar_paginado(integer, integer, text, text, jsonb) IS
'Listado paginado de boletines; p_filtros trae los filtros de columna de ag-Grid y se aplican sobre todos los boletines, no sobre la página';
