-- ============================================================================
-- LA AGENDA, PAGINADA
--
-- «Lo que toca hacer» pasa de tarjetas por días a una grilla con paginación,
-- así que necesita lo mismo que el resto de listados del sistema: una página
-- de filas y un meta con total / per_page / current_page / last_page.
--
--   ventas.fn_gestiones_agenda_paginado(empleado, login, desde, hasta,
--                                       solo_vencidas, search, page, per_page)
--
-- Los contadores (total, vencidas, hoy) se siguen calculando sobre TODO el
-- filtro, no sobre la página: son los que se ven en los chips de arriba.
--
-- Se añade buscador: con quinientos pendientes, encontrar «el que era de
-- cobranza» pasando páginas no es manera. Busca por asunto, nota, cliente,
-- identificación y teléfono.
--
-- La fn_gestiones_agenda de antes se queda como está: la usa el servicio del
-- recordatorio, que no pagina ni busca.
--
-- Idempotente: CREATE OR REPLACE.
-- ============================================================================

CREATE OR REPLACE FUNCTION ventas.fn_gestiones_agenda_paginado(
    p_empleado_id   bigint  DEFAULT NULL,   -- la agenda de un vendedor
    p_usuario_login varchar DEFAULT NULL,   -- lo que programó este usuario
    p_desde         date    DEFAULT NULL,
    p_hasta         date    DEFAULT NULL,
    p_solo_vencidas boolean DEFAULT false,
    p_search        text    DEFAULT '',
    p_page          integer DEFAULT 1,
    p_per_page      integer DEFAULT 15
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
BEGIN
    v_patron := CASE WHEN v_busca IS NULL THEN NULL ELSE '%' || lower(v_busca) || '%' END;

    -- 1. Los contadores, sobre todo el filtro (no sobre la página)
    SELECT COUNT(*),
           COUNT(*) FILTER (WHERE g.fecha_programada < CURRENT_TIMESTAMP),
           COUNT(*) FILTER (WHERE g.fecha_programada::date = CURRENT_DATE)
      INTO v_total, v_vencidas, v_hoy
      FROM ventas.gestiones g
      JOIN ventas.clientes c ON c.id = g.cliente_id AND c.deleted_at IS NULL
     WHERE g.estado = 'PENDIENTE'
       AND (p_empleado_id   IS NULL OR g.empleado_id = p_empleado_id)
       AND (p_usuario_login IS NULL OR UPPER(g.created_by) = UPPER(p_usuario_login))
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
       ));

    v_ultima := GREATEST(CEIL(v_total::numeric / v_per_page)::integer, 1);
    IF v_page > v_ultima THEN v_page := v_ultima; END IF;

    -- 2. La página, lo más urgente primero
    SELECT COALESCE(jsonb_agg(ventas.fn_gestiones_json(t.id) ORDER BY t.orden), '[]'::jsonb) INTO v_data
      FROM (
        SELECT g.id, ROW_NUMBER() OVER (ORDER BY g.fecha_programada ASC, g.id ASC) AS orden
          FROM ventas.gestiones g
          JOIN ventas.clientes c ON c.id = g.cliente_id AND c.deleted_at IS NULL
         WHERE g.estado = 'PENDIENTE'
           AND (p_empleado_id   IS NULL OR g.empleado_id = p_empleado_id)
           AND (p_usuario_login IS NULL OR UPPER(g.created_by) = UPPER(p_usuario_login))
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
         ORDER BY g.fecha_programada ASC, g.id ASC
         LIMIT v_per_page OFFSET (v_page - 1) * v_per_page
      ) t;

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
            'mostradas',    jsonb_array_length(v_data)
        )
    );
EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object('success', false, 'message', 'Error al obtener la agenda: ' || SQLERRM, 'error_code', SQLSTATE);
END;
$function$;

ALTER FUNCTION ventas.fn_gestiones_agenda_paginado(bigint, varchar, date, date, boolean, text, integer, integer) OWNER TO postgres;
COMMENT ON FUNCTION ventas.fn_gestiones_agenda_paginado(bigint, varchar, date, date, boolean, text, integer, integer)
    IS 'Lo pendiente, paginado y con buscador, para la grilla de «Lo que toca hacer»';

-- ---------------------------------------------------------------------------
-- El teléfono del cliente en cada gestión
--
-- La grilla de «Lo que toca hacer» es una lista de llamadas: hace falta el
-- número a la vista. `telefono` es el que se anotó en la gestión (muchas
-- veces va vacío), así que se añade `cliente_telefono` con el celular del
-- cliente y, si no tiene, su teléfono fijo. Campo nuevo: lo que ya leía esta
-- función sigue igual.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ventas.fn_gestiones_json(p_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
    v_data jsonb;
BEGIN
    SELECT jsonb_build_object(
        'id',                g.id,
        'cliente_id',        g.cliente_id,
        'cliente_nombre',    c.nombre_completo,
        'cliente_telefono',  COALESCE(NULLIF(TRIM(c.celular), ''), NULLIF(TRIM(c.telefono), '')),
        'empleado_id',       g.empleado_id,
        'empleado_nombre',   (SELECT TRIM(COALESCE(e.nombres, '') || ' ' || COALESCE(e.apellidos, ''))
                                FROM rh.empleados e WHERE e.id = g.empleado_id),
        'contacto_id',       g.contacto_id,
        'contacto_nombre',   (SELECT cc.nombres FROM ventas.contactos_clientes cc WHERE cc.id = g.contacto_id),
        'tipo',              g.tipo,
        'estado',            g.estado,
        'prioridad',         g.prioridad,
        'asunto',            g.asunto,
        'nota',              g.nota,
        'telefono',          g.telefono,
        'fecha_programada',  to_char(g.fecha_programada, 'YYYY-MM-DD HH24:MI'),
        'fecha_realizada',   to_char(g.fecha_realizada,  'YYYY-MM-DD HH24:MI'),
        'duracion_minutos',  g.duracion_minutos,
        'resultado',         g.resultado,
        'gestion_origen_id', g.gestion_origen_id,
        -- Pendiente cuya hora ya pasó: la pantalla la pinta en rojo
        'vencida',           (g.estado = 'PENDIENTE' AND g.fecha_programada < CURRENT_TIMESTAMP),
        'created_by',        g.created_by,
        'updated_by',        g.updated_by,
        'created_at',        to_char(g.created_at, 'YYYY-MM-DD HH24:MI:SS'),
        'updated_at',        to_char(g.updated_at, 'YYYY-MM-DD HH24:MI:SS')
    ) INTO v_data
    FROM ventas.gestiones g
    JOIN ventas.clientes c ON c.id = g.cliente_id
    WHERE g.id = p_id;

    RETURN v_data;
END;
$function$;

ALTER FUNCTION ventas.fn_gestiones_json(bigint) OWNER TO postgres;
