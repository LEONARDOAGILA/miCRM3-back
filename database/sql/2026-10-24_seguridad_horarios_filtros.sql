-- ===========================================================================
-- EL LISTADO DE HORARIOS DE ACCESO: LOS FILTROS DE LAS COLUMNAS NUEVAS
-- ===========================================================================
-- La rejilla ganó Semana, Jornadas, Horas/semana, Usuarios y Descripción, y
-- sus cajas de filtro no servían de nada: lo que no está en esta función se
-- tira en silencio. Las tres listas --pantalla, controlador y esto-- tienen
-- que decir lo mismo.
--
-- Se regenera a partir de la definición VIVA, con los filtros añadidos.
\set ON_ERROR_STOP on

BEGIN;

CREATE OR REPLACE FUNCTION seguridad.fn_horarios_listar_paginado(p_page integer DEFAULT 1, p_per_page integer DEFAULT 15, p_search text DEFAULT ''::text, p_filtros jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
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
         WHERE c.deleted_at IS NULL            -- lo de la papelera no sale
           AND (v_filtro IS NULL
                OR c.nombre   ILIKE '%' || v_filtro || '%'
                OR c.id::text ILIKE '%' || v_filtro || '%')

           -- ---------- LOS FILTROS DE LA CABECERA ----------
           AND (p_filtros->'id'     IS NULL OR ventas.fn_filtro_numero(c.id,     p_filtros->'id'))
           AND (p_filtros->'nombre' IS NULL OR ventas.fn_filtro_texto(c.nombre,  p_filtros->'nombre'))
           AND (p_filtros->'descripcion' IS NULL OR ventas.fn_filtro_texto(c.descripcion, p_filtros->'descripcion'))
           -- Los contadores: los mismos subselects que pintan las columnas
           AND (p_filtros->'num_dias' IS NULL OR ventas.fn_filtro_numero(
                   (SELECT COUNT(DISTINCT d.dia) FROM seguridad.dhorarios d
                     WHERE d.chorario_id = c.id AND d.activo), p_filtros->'num_dias'))
           AND (p_filtros->'num_jornadas' IS NULL OR ventas.fn_filtro_numero(
                   (SELECT COUNT(*) FROM seguridad.dhorarios d
                     WHERE d.chorario_id = c.id AND d.activo), p_filtros->'num_jornadas'))
           AND (p_filtros->'num_usuarios' IS NULL OR ventas.fn_filtro_numero(
                   (SELECT COUNT(*) FROM seguridad.users u
                     WHERE u.chorario_id = c.id AND u.deleted_at IS NULL), p_filtros->'num_usuarios'))
           -- Las fechas, como texto sobre lo que se ve: «2026-10» busca el mes
           AND (p_filtros->'created_at' IS NULL OR ventas.fn_filtro_texto(
                   to_char(c.created_at, 'YYYY-MM-DD HH24:MI:SS'), p_filtros->'created_at'))
           AND (p_filtros->'updated_at' IS NULL OR ventas.fn_filtro_texto(
                   to_char(c.updated_at, 'YYYY-MM-DD HH24:MI:SS'), p_filtros->'updated_at'))
    )
    SELECT COUNT(*),
           COALESCE((SELECT jsonb_agg(seguridad.fn_horarios_json(t.id) ORDER BY t.id DESC)
                       FROM (SELECT f.id FROM filtrados f
                              ORDER BY f.id DESC
                              LIMIT GREATEST(COALESCE(p_per_page, 15), 1) OFFSET v_offset) t), '[]'::jsonb)
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

COMMIT;
