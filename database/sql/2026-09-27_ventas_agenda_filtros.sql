-- ============================================================================
-- LA AGENDA («Lo que toca hacer») CON FILTROS
--
-- Pasa a ser una pestaña propia de gestion-clientes: todo lo pendiente del
-- usuario, de TODOS sus clientes, con rango de fechas. Por eso la función
-- gana dos cosas:
--   p_usuario_login  sólo lo que programó ese usuario (lo suyo)
--   p_solo_vencidas  únicamente lo que ya se pasó de hora
-- y devuelve, además de la lista, los contadores que pinta la pantalla
-- (total, vencidas, hoy) para no tener que contarlos en el navegador.
--
-- Cambia la lista de parámetros, así que hay que soltar la anterior: con
-- CREATE OR REPLACE quedarían dos funciones con el mismo nombre y las
-- llamadas con parámetros por defecto serían ambiguas.
-- ============================================================================

DROP FUNCTION IF EXISTS ventas.fn_gestiones_agenda(bigint, date, date, integer);

CREATE OR REPLACE FUNCTION ventas.fn_gestiones_agenda(
    p_empleado_id   bigint  DEFAULT NULL,   -- la agenda de un vendedor
    p_usuario_login varchar DEFAULT NULL,   -- lo que programó este usuario
    p_desde         date    DEFAULT NULL,
    p_hasta         date    DEFAULT NULL,
    p_solo_vencidas boolean DEFAULT false,
    p_limite        integer DEFAULT 200
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
    v_data     jsonb;
    v_total    bigint;
    v_vencidas bigint;
    v_hoy      bigint;
BEGIN
    -- 1. Los contadores salen del mismo filtro, sin el límite
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
       AND (NOT p_solo_vencidas OR g.fecha_programada < CURRENT_TIMESTAMP);

    -- 2. La lista, lo más urgente primero
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
         ORDER BY g.fecha_programada ASC, g.id ASC
         LIMIT GREATEST(p_limite, 1)
      ) t;

    RETURN jsonb_build_object(
        'success', true,
        'message', 'Agenda obtenida exitosamente',
        'data', v_data,
        'total', v_total,
        'meta', jsonb_build_object(
            'total',    v_total,
            'vencidas', v_vencidas,
            'hoy',      v_hoy,
            'mostradas', jsonb_array_length(v_data)
        )
    );
EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object('success', false, 'message', 'Error al obtener la agenda: ' || SQLERRM, 'error_code', SQLSTATE);
END;
$function$;

ALTER FUNCTION ventas.fn_gestiones_agenda(bigint, varchar, date, date, boolean, integer) OWNER TO postgres;
COMMENT ON FUNCTION ventas.fn_gestiones_agenda(bigint, varchar, date, date, boolean, integer)
    IS 'Lo pendiente de un vendedor o de un usuario, con rango de fechas y contadores';
