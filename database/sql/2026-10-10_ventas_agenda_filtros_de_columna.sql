-- ===========================================================================
-- LOS FILTROS DE COLUMNA DE ag-Grid, TAMBIÉN EN «LO QUE TOCA HACER»
-- ===========================================================================
-- Fecha: 2026-10-10
-- Se aplica después de 2026-10-10_ventas_gestiones_filtros_de_columna.sql.
--
-- Lo mismo que ya tienen el listado de clientes, el reparto y las dos rejillas
-- de la ficha: la agenda pagina en el servidor, así que a ag-Grid sólo le
-- llegan quince filas y sus filtros de cabecera buscaban dentro de quince.
--
-- El modelo llega en p_filtros, columna por columna:
--
--     {"cliente_nombre": {"op":"contains","valor":"gomez"},
--      "prioridad":      {"op":"equals","valor":"alta"}}
--
-- La columna que no esté, no filtra.
--
-- LOS CONTADORES TAMBIÉN. «total», «vencidas» y «para hoy» se cuentan sobre lo
-- filtrado, igual que ya hacían con el buscador y el rango de fechas: si
-- dijeran otra cosa que la lista, no se sabría a cuál creer.
--
-- SE FILTRA POR LO QUE SE VE. En la celda pone «Llamada», «Alta» y «16/10
-- 22:00»; en la base dicen LLAMADA, ALTA y 2026-10-16 22:00. Donde hay
-- traducción se buscan las dos cosas, y la fecha se busca en los dos formatos,
-- así valen tanto «16/10» como «2026-10».
--
-- DE PASO SE DEJA DE REPETIR EL WHERE. La definición anterior lo tenía escrito
-- dos veces —una para los contadores y otra para la página— y había que
-- acordarse de tocar las dos; con ocho condiciones más sería pedirlo. Ahora
-- sale de un CTE y los contadores y la página no pueden discrepar. El recorte
-- de la página («la siete ya no existe») se hace dentro de la misma sentencia.
--
-- Cambia la firma —entra un parámetro décimo—, así que se suelta la función
-- antes: CREATE OR REPLACE con otros parámetros no reemplaza, crea una segunda
-- con el mismo nombre y las llamadas de nueve argumentos se quedarían
-- resolviendo a la vieja.
--
-- Idempotente.
-- ===========================================================================

DROP FUNCTION IF EXISTS ventas.fn_gestiones_agenda_paginado(
    bigint, character varying, date, date, boolean, text, integer, integer, bigint);

CREATE OR REPLACE FUNCTION ventas.fn_gestiones_agenda_paginado(
    p_usuario_id     bigint            DEFAULT NULL::bigint,
    p_usuario_login  character varying DEFAULT NULL::character varying,
    p_desde          date              DEFAULT NULL::date,
    p_hasta          date              DEFAULT NULL::date,
    p_solo_vencidas  boolean           DEFAULT false,
    p_search         text              DEFAULT ''::text,
    p_page           integer           DEFAULT 1,
    p_per_page       integer           DEFAULT 15,
    p_solicitante    bigint            DEFAULT NULL::bigint,
    -- Los filtros de la cabecera de ag-Grid, columna por columna
    p_filtros        jsonb             DEFAULT '{}'::jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'ventas', 'rh'
AS $function$
DECLARE
    v_page     integer := GREATEST(COALESCE(p_page, 1), 1);
    v_per_page integer := LEAST(GREATEST(COALESCE(p_per_page, 15), 1), 200);
    v_busca    text    := NULLIF(TRIM(COALESCE(p_search, '')), '');
    v_patron   text;

    v_data     jsonb;
    v_total    bigint;
    v_vencidas bigint;
    v_hoy      bigint;
    v_ultima   integer;

    v_ve_todo  boolean := false;
    v_ambito   bigint[] := '{}'::bigint[];
    v_visibles bigint[];
    v_yo       bigint;
BEGIN
    v_patron := CASE WHEN v_busca IS NULL THEN NULL ELSE '%' || lower(v_busca) || '%' END;

    -- El techo se resuelve UNA vez, no por cada gestión
    IF p_solicitante IS NOT NULL THEN
        SELECT COALESCE(g.es_administrador, false) INTO v_ve_todo
          FROM seguridad.users u
          LEFT JOIN seguridad.grupos g ON g.id = u.grupo_id
         WHERE u.id = p_solicitante;

        IF NOT COALESCE(v_ve_todo, false) THEN
            v_ambito := ventas.fn_usuarios_a_cargo(p_solicitante);
        END IF;

        -- El segundo techo: el alcance del perfil. NULL es «sin filtro»
        -- (alcance TODO), que es lo de los administradores y lo de todo el
        -- mundo mientras nadie configure nada; entonces esto no hace nada.
        --
        -- Se CRUZA con la jerarquía en vez de sustituirla: hay que estar en
        -- las dos listas. Si el cruce queda vacío no se ve ninguna gestión de
        -- nadie, que es lo prudente y lo que hace el historial.
        v_visibles := seguridad.fn_usuarios_visibles(p_solicitante, 'GESTION');
        IF v_visibles IS NOT NULL THEN
            v_ve_todo := false;
            v_ambito  := ARRAY(SELECT x FROM unnest(v_ambito)   AS x
                               INTERSECT
                               SELECT y FROM unnest(v_visibles) AS y);
        END IF;
    END IF;

    IF p_usuario_login IS NOT NULL THEN
        SELECT u.id INTO v_yo
          FROM seguridad.users u
         WHERE UPPER(u.login_user) = UPPER(p_usuario_login) AND u.deleted_at IS NULL;
    END IF;

    -- UNA sola sentencia: los contadores, el recorte de página y la página
    -- salen del mismo CTE, así no pueden discrepar.
    WITH base AS (
        SELECT g.id, g.fecha_programada
          FROM ventas.gestiones g
          JOIN ventas.clientes c ON c.id = g.cliente_id AND c.deleted_at IS NULL
         WHERE g.estado = 'PENDIENTE'
           -- El techo: nada de fuera del ámbito de quien pregunta
           AND (p_solicitante IS NULL OR v_ve_todo OR g.usuario_id = ANY(v_ambito))
           AND (p_usuario_id    IS NULL OR g.usuario_id = p_usuario_id)
           -- Lo que ME TOCA, no lo que yo registré: antes comparaba con
           -- created_by y por eso quien no registraba gestiones veía la agenda
           -- vacía aunque tuviera clientes asignados.
           AND (p_usuario_login IS NULL OR g.usuario_id = v_yo)
           AND (p_desde IS NULL OR g.fecha_programada >= p_desde::timestamptz)
           AND (p_hasta IS NULL OR g.fecha_programada < (p_hasta + 1)::timestamptz)
           AND (NOT p_solo_vencidas OR g.fecha_programada < CURRENT_TIMESTAMP)
           AND (v_patron IS NULL OR (
                  lower(COALESCE(g.asunto, ''))                 LIKE v_patron
               OR lower(COALESCE(g.nota, ''))                   LIKE v_patron
               OR lower(COALESCE(c.nombre_completo, ''))        LIKE v_patron
               OR lower(COALESCE(c.numero_identificacion, ''))  LIKE v_patron
               OR lower(COALESCE(g.telefono, ''))               LIKE v_patron
               OR lower(COALESCE(c.celular, ''))                LIKE v_patron
           ))

           -- ---------- Los filtros de la cabecera, uno por columna ----------
           AND (p_filtros->'id' IS NULL OR ventas.fn_filtro_numero(g.id, p_filtros->'id'))

           -- El código y el nombre del catálogo: en la celda pone «Llamada»
           -- pero en la base dice LLAMADA, y el catálogo se puede editar.
           AND (p_filtros->'tipo' IS NULL OR ventas.fn_filtro_texto(
                   COALESCE(g.tipo, '') || ' ' ||
                   COALESCE((SELECT gt.nombre FROM ventas.gestiones_tipos gt WHERE gt.codigo = g.tipo), ''),
                   p_filtros->'tipo'))

           -- La celda enseña «16/10 22:00» y el dato es «2026-10-16 22:00».
           -- Se buscan los dos, así vale lo que se ve y vale escribir el año.
           AND (p_filtros->'fecha_programada' IS NULL OR ventas.fn_filtro_texto(
                   to_char(g.fecha_programada, 'DD/MM HH24:MI') || ' ' ||
                   to_char(g.fecha_programada, 'YYYY-MM-DD HH24:MI'),
                   p_filtros->'fecha_programada'))

           AND (p_filtros->'cliente_nombre' IS NULL OR ventas.fn_filtro_texto(c.nombre_completo, p_filtros->'cliente_nombre'))
           AND (p_filtros->'asunto'         IS NULL OR ventas.fn_filtro_texto(g.asunto,          p_filtros->'asunto'))

           AND (p_filtros->'prioridad' IS NULL OR ventas.fn_filtro_texto(
                   COALESCE(g.prioridad, '') || ' ' || CASE g.prioridad
                       WHEN 'ALTA'  THEN 'Alta'
                       WHEN 'MEDIA' THEN 'Media'
                       WHEN 'BAJA'  THEN 'Baja'
                       ELSE ''
                   END,
                   p_filtros->'prioridad'))

           -- El de la gestión, que es el que enseña la celda
           AND (p_filtros->'telefono' IS NULL OR ventas.fn_filtro_texto(g.telefono, p_filtros->'telefono'))

           -- La columna «Vendedor»: lo mismo que calcula fn_gestiones_json
           AND (p_filtros->'responsable_nombre' IS NULL OR ventas.fn_filtro_texto(
                   COALESCE(ventas.fn_nombre_usuario(g.usuario_id),
                            (SELECT TRIM(COALESCE(e.nombres, '') || ' ' || COALESCE(e.apellidos, ''))
                               FROM rh.empleados e WHERE e.id = g.empleado_id)),
                   p_filtros->'responsable_nombre'))
    ),
    -- Los contadores van sobre TODO lo filtrado, no sobre la página
    cuentas AS (
        SELECT COUNT(*)                                                          AS total,
               COUNT(*) FILTER (WHERE fecha_programada <  CURRENT_TIMESTAMP)     AS vencidas,
               COUNT(*) FILTER (WHERE fecha_programada::date = CURRENT_DATE)     AS hoy,
               GREATEST(CEIL(COUNT(*)::numeric / v_per_page)::integer, 1)        AS ultima
          FROM base
    ),
    -- Con el filtro puesto, la página que se pedía puede ya no existir
    recorte AS (
        SELECT LEAST(v_page, ultima) AS pagina FROM cuentas
    ),
    pagina AS (
        SELECT b.id, ROW_NUMBER() OVER (ORDER BY b.fecha_programada ASC, b.id ASC) AS orden
          FROM base b
         ORDER BY orden
         LIMIT v_per_page OFFSET ((SELECT pagina FROM recorte) - 1) * v_per_page
    )
    SELECT c.total, c.vencidas, c.hoy, c.ultima, (SELECT pagina FROM recorte),
           COALESCE((SELECT jsonb_agg(ventas.fn_gestiones_json(p.id) ORDER BY p.orden) FROM pagina p), '[]'::jsonb)
      INTO v_total, v_vencidas, v_hoy, v_ultima, v_page, v_data
      FROM cuentas c;

    RETURN jsonb_build_object(
        'success', true,
        'message', 'Agenda obtenida exitosamente',
        'data', v_data,
        'meta', jsonb_build_object(
            'total',        v_total,
            'per_page',     v_per_page,
            'current_page', v_page,
            'last_page',    v_ultima,
            'from',         CASE WHEN v_total = 0 THEN 0 ELSE (v_page - 1) * v_per_page + 1 END,
            'to',           LEAST(v_page * v_per_page, v_total),
            'vencidas',     v_vencidas,
            'hoy',          v_hoy,
            'mostradas',    jsonb_array_length(v_data),
            -- Para que la pantalla no ofrezca un botón que no hace nada
            've_de_otros',  v_ve_todo OR COALESCE(array_length(v_ambito, 1), 0) > 1,
            -- Para las pantallas que sólo son de administradores
            'es_admin',     COALESCE(v_ve_todo, false)
        )
    );
EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object('success', false, 'message', 'Error al obtener la agenda: ' || SQLERRM, 'error_code', SQLSTATE);
END;
$function$;
