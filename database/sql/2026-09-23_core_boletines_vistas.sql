-- ===========================================================================
-- BOLETINES: cuántas veces lo abrió cada destinatario
--
-- La lista de destinatarios ya decía quién lo vio y cuándo; ahora dice
-- también cuántas veces. Es lo que muestra la pantalla «Vistas del boletín».
--
--   psql -h 192.168.2.173 -U postgres -d crm3 -f 2026-09-23_core_boletines_vistas.sql
-- ===========================================================================

CREATE OR REPLACE FUNCTION core.fn_boletines_destinatarios(p_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE v_data jsonb;
BEGIN
    SELECT COALESCE(jsonb_agg(t ORDER BY t->>'login_user'), '[]'::jsonb) INTO v_data
      FROM (
        SELECT DISTINCT ON (u.id) jsonb_build_object(
                 'user_id',  u.id,
                 'login_user', u.login_user,
                 'name',     u.name,
                 'surname',  u.surname,
                 'isactive', u.isactive,
                 'origen',   d.origen,
                 'desde',    d.desde_nombre,
                 'visto_at', to_char(v.visto_at, 'YYYY-MM-DD HH24:MI:SS'),
                 'veces',    COALESCE(v.veces, 0),
                 'no_mostrar', COALESCE(v.no_mostrar, false)
               ) AS t, u.id
          FROM (
                SELECT bu.user_id, 'DIRECTO'::text AS origen, NULL::varchar AS desde_nombre
                  FROM core.boletines_usuarios bu WHERE bu.boletin_id = p_id
                UNION ALL
                SELECT g.user_id, 'GRUPO'::text, gr.nombre
                  FROM core.boletines_grupos bg
                  JOIN seguridad.grupos gr ON gr.id = bg.grupo_id
                  CROSS JOIN LATERAL core.fn_boletines_usuarios_de_grupo(bg.grupo_id, bg.incluir_subgrupos) g
                 WHERE bg.boletin_id = p_id
               ) d
          JOIN seguridad.users u ON u.id = d.user_id AND u.deleted_at IS NULL
          LEFT JOIN core.boletines_vistos v ON v.boletin_id = p_id AND v.user_id = u.id
         ORDER BY u.id, (d.origen = 'DIRECTO') DESC
      ) x;

    RETURN jsonb_build_object('success', true, 'message', 'La solicitud ha tenido éxito', 'data', v_data);
END;
$function$;
