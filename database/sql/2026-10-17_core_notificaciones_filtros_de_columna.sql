-- ===========================================================================
-- NOTIFICACIONES: FILTROS DE COLUMNA EN EL SERVIDOR
-- ===========================================================================
-- Fecha: 2026-10-17
-- Se aplica después de 2026-10-17_core_boletines_filtros_de_columna.sql.
--
-- Lo mismo que el resto de las rejillas: LOS FILTROS DE LA CABECERA SE
-- APLICAN AQUÍ, no en el navegador. La pantalla pagina, así que ag-Grid sólo
-- tiene las filas de la página y filtrar ahí buscaría dentro de diez. El
-- modelo llega en p_filtros, ya traducido por el controlador:
--
--     {"titulo": {"op":"contains","valor":"clave"},
--      "leidas": {"op":"equals","valor":"0"}}
--
-- Se reusan ventas.fn_filtro_texto y ventas.fn_filtro_numero (comparan sin
-- tildes y sin distinguir mayúsculas).
--
-- SE FILTRA POR LO QUE SE VE, NO POR LO QUE HAY DEBAJO:
--   · «Tipo» guarda INFO / EXITO / AVISO / ERROR pero la rejilla enseña
--     Información, Éxito, Aviso y Problema. Se filtra por ESE texto: quien
--     escribe «problema» no tiene por qué saber que dentro pone ERROR. El
--     combo de la barra sigue estando con los valores de siempre y se suma.
--   · «Leída por» es una cuenta de notificaciones_usuarios; se filtra con el
--     mismo subselect que la pinta.
--   · Las fechas se filtran como texto sobre lo que se ve («2026-10» es el mes).
--
-- El resto no cambia: sigue sin enseñar lo eliminado y sigue ordenando por
-- fecha de envío descendente.
--
-- Cambia la firma, así que se suelta la función antes: un CREATE OR REPLACE
-- con otra firma deja DOS funciones y la llamada de cuatro argumentos se
-- vuelve ambigua. El único que la llama es NotificacionController.
-- Idempotente.
-- ===========================================================================

DROP FUNCTION IF EXISTS core.fn_notificaciones_listar_paginado(integer, integer, text, text);

CREATE OR REPLACE FUNCTION core.fn_notificaciones_listar_paginado(
    p_page     integer DEFAULT 1,
    p_per_page integer DEFAULT 15,
    p_search   text    DEFAULT NULL,
    p_tipo     text    DEFAULT NULL,
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
    v_tipo   text;
    v_data   jsonb;
BEGIN
    v_offset := (GREATEST(COALESCE(p_page, 1), 1) - 1) * GREATEST(COALESCE(p_per_page, 15), 1);
    v_filtro := NULLIF(TRIM(COALESCE(p_search, '')), '');
    v_tipo   := UPPER(COALESCE(NULLIF(TRIM(p_tipo), ''), 'TODOS'));

    WITH filtradas AS (
        SELECT n.id, n.created_at
          FROM core.notificaciones n
         WHERE n.deleted_at IS NULL
           AND (v_filtro IS NULL
                OR n.titulo  ILIKE '%' || v_filtro || '%'
                OR n.mensaje ILIKE '%' || v_filtro || '%'
                OR n.id::text ILIKE '%' || v_filtro || '%')

           -- El combo de la barra, como siempre
           AND (v_tipo = 'TODOS' OR n.tipo = v_tipo)

           -- ---------- LOS FILTROS DE LA CABECERA ----------
           AND (p_filtros->'id'      IS NULL OR ventas.fn_filtro_numero(n.id,      p_filtros->'id'))
           AND (p_filtros->'titulo'  IS NULL OR ventas.fn_filtro_texto(n.titulo,   p_filtros->'titulo'))
           AND (p_filtros->'mensaje' IS NULL OR ventas.fn_filtro_texto(n.mensaje,  p_filtros->'mensaje'))
           -- El tipo, con el nombre que sale en la rejilla
           AND (p_filtros->'tipo'    IS NULL OR ventas.fn_filtro_texto(
                   CASE n.tipo WHEN 'INFO'  THEN 'Información'
                               WHEN 'EXITO' THEN 'Éxito'
                               WHEN 'AVISO' THEN 'Aviso'
                               WHEN 'ERROR' THEN 'Problema'
                               ELSE n.tipo END, p_filtros->'tipo'))
           AND (p_filtros->'origen'  IS NULL OR ventas.fn_filtro_texto(n.origen,     p_filtros->'origen'))
           AND (p_filtros->'created_by' IS NULL OR ventas.fn_filtro_texto(n.created_by, p_filtros->'created_by'))
           -- Las fechas, como texto sobre lo que se ve: «2026-10» busca el mes
           AND (p_filtros->'created_at' IS NULL OR ventas.fn_filtro_texto(
                   to_char(n.created_at, 'YYYY-MM-DD HH24:MI'), p_filtros->'created_at'))
           AND (p_filtros->'caduca_at'  IS NULL OR ventas.fn_filtro_texto(
                   to_char(n.caduca_at,  'YYYY-MM-DD HH24:MI'), p_filtros->'caduca_at'))
           -- Cuántos la han leído: el mismo subselect que pinta la columna
           AND (p_filtros->'leidas'  IS NULL OR ventas.fn_filtro_numero(
                   (SELECT COUNT(*) FROM core.notificaciones_usuarios u
                     WHERE u.notificacion_id = n.id AND u.leida_at IS NOT NULL),
                   p_filtros->'leidas'))
    )
    SELECT COUNT(*),
           COALESCE((SELECT jsonb_agg(core.fn_notificaciones_json(t.id)
                                      ORDER BY t.created_at DESC, t.id DESC)
                       FROM (SELECT f.id, f.created_at FROM filtradas f
                              ORDER BY f.created_at DESC, f.id DESC
                              LIMIT GREATEST(COALESCE(p_per_page, 15), 1) OFFSET v_offset) t), '[]'::jsonb)
      INTO v_total, v_data
      FROM filtradas;

    RETURN jsonb_build_object(
        'success', true,
        'message', 'La solicitud ha tenido éxito',
        'data', jsonb_build_object(
            'data',         v_data,
            'current_page', GREATEST(COALESCE(p_page, 1), 1),
            'per_page',     GREATEST(COALESCE(p_per_page, 15), 1),
            'total',        v_total,
            'last_page',    GREATEST(CEIL(v_total::numeric / NULLIF(GREATEST(COALESCE(p_per_page, 15), 1), 0))::int, 1)
        )
    );
END;
$function$;

ALTER FUNCTION core.fn_notificaciones_listar_paginado(integer, integer, text, text, jsonb) OWNER TO postgres;

COMMENT ON FUNCTION core.fn_notificaciones_listar_paginado(integer, integer, text, text, jsonb) IS
'Listado paginado de notificaciones; p_filtros trae los filtros de columna de ag-Grid y se aplican sobre todas, no sobre la página';
