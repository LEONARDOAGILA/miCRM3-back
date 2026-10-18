-- ===========================================================================
-- HORARIOS: FILTROS DE COLUMNA EN EL SERVIDOR
-- ===========================================================================
-- Fecha: 2026-10-17
-- Se aplica después de 2026-10-17_core_notificaciones_filtros_de_columna.sql.
--
-- Lo mismo que el resto de las rejillas: LOS FILTROS DE LA CABECERA SE
-- APLICAN AQUÍ, no en el navegador. La pantalla pagina, así que ag-Grid sólo
-- tiene las filas de la página y filtrar ahí buscaría dentro de diez. El
-- modelo llega en p_filtros, ya traducido por el controlador:
--
--     {"nombre": {"op":"contains","valor":"oficina"},
--      "id": {"op":"greaterThan","valor":"3"}}
--
-- Se reusan ventas.fn_filtro_texto y ventas.fn_filtro_numero (comparan sin
-- tildes y sin distinguir mayúsculas). Las fechas se filtran como texto sobre
-- lo que se ve («2026-10» busca el mes).
--
-- De paso se quita la duplicación que tenía: la consulta estaba escrita dos
-- veces, una con búsqueda y otra sin ella, y había que acordarse de tocar las
-- dos. Ahora es una sola con el filtro dentro. Lo que devuelve no cambia:
-- {data, meta} y el mismo orden, por id descendente.
--
-- Cambia la firma, así que se suelta la función antes: un CREATE OR REPLACE
-- con otra firma deja DOS funciones y la llamada de tres argumentos se vuelve
-- ambigua. El único que la llama es HorarioController (la de «activos» es
-- otra función y no se toca).
-- Idempotente.
-- ===========================================================================

DROP FUNCTION IF EXISTS seguridad.fn_horarios_listar_paginado(integer, integer, text);

CREATE OR REPLACE FUNCTION seguridad.fn_horarios_listar_paginado(
    p_page     integer DEFAULT 1,
    p_per_page integer DEFAULT 15,
    p_search   text    DEFAULT '',
    -- Los filtros de la cabecera de ag-Grid, columna por columna
    p_filtros  jsonb   DEFAULT '{}'::jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'seguridad', 'ventas'
AS $function$
DECLARE
    v_offset integer;
    v_total  bigint;
    v_filtro text;
    v_data   jsonb;
BEGIN
    v_offset := (GREATEST(COALESCE(p_page, 1), 1) - 1) * GREATEST(COALESCE(p_per_page, 15), 1);
    v_filtro := NULLIF(TRIM(COALESCE(p_search, '')), '');

    WITH filtrados AS (
        SELECT c.id
          FROM seguridad.chorarios c
         WHERE (v_filtro IS NULL
                OR c.nombre   ILIKE '%' || v_filtro || '%'
                OR c.id::text ILIKE '%' || v_filtro || '%')

           -- ---------- LOS FILTROS DE LA CABECERA ----------
           AND (p_filtros->'id'     IS NULL OR ventas.fn_filtro_numero(c.id,     p_filtros->'id'))
           AND (p_filtros->'nombre' IS NULL OR ventas.fn_filtro_texto(c.nombre,  p_filtros->'nombre'))
           -- Las fechas, como texto sobre lo que se ve: «2026-10» busca el mes
           AND (p_filtros->'created_at' IS NULL OR ventas.fn_filtro_texto(
                   to_char(c.created_at, 'YYYY-MM-DD HH24:MI:SS'), p_filtros->'created_at'))
           AND (p_filtros->'updated_at' IS NULL OR ventas.fn_filtro_texto(
                   to_char(c.updated_at, 'YYYY-MM-DD HH24:MI:SS'), p_filtros->'updated_at'))
    )
    SELECT COUNT(*),
           COALESCE((SELECT jsonb_agg(jsonb_build_object(
                                'id',         c.id,
                                'nombre',     c.nombre,
                                'activo',     c.activo,
                                'created_at', to_char(c.created_at, 'YYYY-MM-DD HH24:MI:SS'),
                                'updated_at', to_char(c.updated_at, 'YYYY-MM-DD HH24:MI:SS'),
                                'created_by', c.created_by,
                                'updated_by', c.updated_by
                              ) ORDER BY c.id DESC)
                       FROM seguridad.chorarios c
                      WHERE c.id IN (SELECT f.id FROM filtrados f
                                      ORDER BY f.id DESC
                                      LIMIT GREATEST(COALESCE(p_per_page, 15), 1) OFFSET v_offset)),
                    '[]'::jsonb)
      INTO v_total, v_data
      FROM filtrados;

    RETURN jsonb_build_object(
        'data', v_data,
        'meta', jsonb_build_object(
            'total',        v_total,
            'per_page',     GREATEST(COALESCE(p_per_page, 15), 1),
            'current_page', GREATEST(COALESCE(p_page, 1), 1),
            'last_page',    CASE WHEN v_total = 0 THEN 1
                                 ELSE ceil(v_total::numeric / GREATEST(COALESCE(p_per_page, 15), 1)) END
        )
    );

EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object('success', false,
                                  'message', 'Error al listar horarios: ' || SQLERRM,
                                  'error_code', SQLSTATE);
END;
$function$;

ALTER FUNCTION seguridad.fn_horarios_listar_paginado(integer, integer, text, jsonb) OWNER TO postgres;

COMMENT ON FUNCTION seguridad.fn_horarios_listar_paginado(integer, integer, text, jsonb) IS
'Listado paginado de horarios; p_filtros trae los filtros de columna de ag-Grid y se aplican sobre todos, no sobre la página';
