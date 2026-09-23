-- ===========================================================================
-- BOLETINES: cuántos hay en la papelera
--
-- El listado devuelve además el número de boletines eliminados, para que el
-- botón de la papelera pueda llevar su contador sin una llamada aparte.
--
--   psql -h 192.168.2.173 -U postgres -d crm3 -f 2026-09-22_core_boletines_contador_papelera.sql
-- Además, cada boletín dice cuándo y quién lo eliminó, que es lo que se ve
-- en la papelera.
-- ===========================================================================

CREATE OR REPLACE FUNCTION core.fn_boletines_json(p_id bigint)
RETURNS jsonb
LANGUAGE sql
STABLE
AS $function$
    SELECT jsonb_build_object(
        'id',            b.id,
        'titulo',        b.titulo,
        'descripcion',   b.descripcion,
        'desde',         to_char(b.desde, 'YYYY-MM-DD'),
        'hasta',         to_char(b.hasta, 'YYYY-MM-DD'),
        'prioridad',     b.prioridad,
        'obligatorio',   b.obligatorio,
        'activo',        b.activo,
        'vigente',       (b.activo AND CURRENT_DATE BETWEEN b.desde AND b.hasta),
        'estado',        CASE WHEN NOT b.activo               THEN 'INACTIVO'
                              WHEN CURRENT_DATE < b.desde     THEN 'PROGRAMADO'
                              WHEN CURRENT_DATE > b.hasta     THEN 'CADUCADO'
                              ELSE 'VIGENTE' END,
        'en_papelera',   (b.deleted_at IS NOT NULL),
        -- Para la papelera: cuándo y quién lo eliminó
        'deleted_at',    to_char(b.deleted_at, 'YYYY-MM-DD HH24:MI'),
        'deleted_by',    b.deleted_by,
        'imagenes',      COALESCE((
                            SELECT jsonb_agg(jsonb_build_object(
                                     'id', i.id, 'archivo', i.archivo, 'titulo', i.titulo,
                                     'descripcion', i.descripcion, 'orden', i.orden,
                                     'segundos', i.segundos, 'tipo', i.tipo
                                   ) ORDER BY i.orden, i.id)
                              FROM core.boletines_imagenes i WHERE i.boletin_id = b.id), '[]'::jsonb),
        'usuarios',      COALESCE((
                            SELECT jsonb_agg(jsonb_build_object(
                                     'user_id', u.id, 'login_user', u.login_user,
                                     'name', u.name, 'surname', u.surname, 'isactive', u.isactive
                                   ) ORDER BY u.login_user)
                              FROM core.boletines_usuarios bu
                              JOIN seguridad.users u ON u.id = bu.user_id AND u.deleted_at IS NULL
                             WHERE bu.boletin_id = b.id), '[]'::jsonb),
        'grupos',        COALESCE((
                            SELECT jsonb_agg(jsonb_build_object(
                                     'grupo_id', g.id, 'nombre', g.nombre,
                                     'incluir_subgrupos', bg.incluir_subgrupos
                                   ) ORDER BY g.nombre)
                              FROM core.boletines_grupos bg
                              JOIN seguridad.grupos g ON g.id = bg.grupo_id
                             WHERE bg.boletin_id = b.id), '[]'::jsonb),
        'num_imagenes',  (SELECT COUNT(*) FROM core.boletines_imagenes i WHERE i.boletin_id = b.id),
        'num_usuarios',  (SELECT COUNT(*) FROM core.boletines_usuarios bu WHERE bu.boletin_id = b.id),
        'num_grupos',    (SELECT COUNT(*) FROM core.boletines_grupos bg WHERE bg.boletin_id = b.id),
        'num_vistos',    (SELECT COUNT(*) FROM core.boletines_vistos v WHERE v.boletin_id = b.id),
        'created_by',    b.created_by,
        'updated_by',    b.updated_by,
        'created_at',    to_char(b.created_at, 'YYYY-MM-DD HH24:MI:SS'),
        'updated_at',    to_char(b.updated_at, 'YYYY-MM-DD HH24:MI:SS')
    )
    FROM core.boletines b
    WHERE b.id = p_id;
$function$;

CREATE OR REPLACE FUNCTION core.fn_boletines_listar_paginado(
    p_page     integer DEFAULT 1,
    p_per_page integer DEFAULT 15,
    p_search   text    DEFAULT '',
    p_estado   text    DEFAULT 'TODOS'
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
AS $function$
DECLARE
    v_offset integer;
    v_total  bigint;
    v_filtro text;
    v_estado text;
    v_data   jsonb;
BEGIN
    v_offset := (GREATEST(p_page, 1) - 1) * p_per_page;
    v_filtro := NULLIF(TRIM(COALESCE(p_search, '')), '');
    v_estado := UPPER(COALESCE(NULLIF(TRIM(p_estado), ''), 'TODOS'));

    SELECT COUNT(*) INTO v_total
      FROM core.boletines b
     WHERE b.deleted_at IS NULL
       AND (v_filtro IS NULL
            OR b.titulo ILIKE '%' || v_filtro || '%'
            OR b.descripcion ILIKE '%' || v_filtro || '%'
            OR b.id::text ILIKE '%' || v_filtro || '%')
       AND (v_estado = 'TODOS'
            OR (v_estado = 'VIGENTE'    AND b.activo AND CURRENT_DATE BETWEEN b.desde AND b.hasta)
            OR (v_estado = 'PROGRAMADO' AND b.activo AND CURRENT_DATE < b.desde)
            OR (v_estado = 'CADUCADO'   AND b.activo AND CURRENT_DATE > b.hasta)
            OR (v_estado = 'INACTIVO'   AND NOT b.activo));

    SELECT COALESCE(jsonb_agg(core.fn_boletines_json(t.id) ORDER BY t.prioridad DESC, t.desde DESC, t.id DESC), '[]'::jsonb)
      INTO v_data
      FROM (
        SELECT b.id, b.prioridad, b.desde
          FROM core.boletines b
         WHERE b.deleted_at IS NULL
           AND (v_filtro IS NULL
                OR b.titulo ILIKE '%' || v_filtro || '%'
                OR b.descripcion ILIKE '%' || v_filtro || '%'
                OR b.id::text ILIKE '%' || v_filtro || '%')
           AND (v_estado = 'TODOS'
                OR (v_estado = 'VIGENTE'    AND b.activo AND CURRENT_DATE BETWEEN b.desde AND b.hasta)
                OR (v_estado = 'PROGRAMADO' AND b.activo AND CURRENT_DATE < b.desde)
                OR (v_estado = 'CADUCADO'   AND b.activo AND CURRENT_DATE > b.hasta)
                OR (v_estado = 'INACTIVO'   AND NOT b.activo))
         ORDER BY b.prioridad DESC, b.desde DESC, b.id DESC
         LIMIT p_per_page OFFSET v_offset
      ) t;

    RETURN jsonb_build_object(
        'success', true,
        'message', 'La solicitud ha tenido éxito',
        'data', jsonb_build_object(
            'data', v_data,
            'current_page', GREATEST(p_page, 1),
            'per_page', p_per_page,
            'total', v_total,
            'last_page', GREATEST(CEIL(v_total::numeric / NULLIF(p_per_page, 0))::int, 1),
            -- Para el contador del botón de la papelera, sin pedir otra vuelta
            'en_papelera', (SELECT COUNT(*) FROM core.boletines WHERE deleted_at IS NOT NULL)
        )
    );
END;
$function$;
