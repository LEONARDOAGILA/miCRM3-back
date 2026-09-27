-- ============================================================================
-- ESTADÍSTICAS GENERALES DE VENTAS
--
-- Una sola función para el tablero que se ve en «Gestión de clientes» cuando
-- todavía no hay ningún cliente elegido: en vez de una pantalla vacía, cómo
-- va la cartera y cómo va el día.
--
--   ventas.fn_estadisticas_generales(p_usuario_login, p_dias)
--
-- Todo en una llamada y en un jsonb, como el resto del módulo: son ocho
-- consultas pequeñas sobre índices y sale más barato traerlas juntas que
-- pedirle ocho veces al servidor (cada petición HTTP cuesta más que todas
-- estas consultas sumadas).
--
-- p_usuario_login sirve para separar «lo mío» de lo de toda la empresa: las
-- gestiones se relacionan con la persona por created_by, que es lo único que
-- hoy las ata a un usuario (seguridad.users todavía no guarda su empleado).
--
-- Sólo lee: no toca auditoría ni necesita los parámetros de contexto.
-- Idempotente: CREATE OR REPLACE.
-- ============================================================================

CREATE OR REPLACE FUNCTION ventas.fn_estadisticas_generales(
    p_usuario_login varchar DEFAULT NULL,
    p_dias          integer DEFAULT 14
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'ventas', 'rh'
AS $function$
DECLARE
    v_dias   integer := LEAST(GREATEST(COALESCE(p_dias, 14), 7), 90);
    v_login  varchar := NULLIF(TRIM(COALESCE(p_usuario_login, '')), '');
    v_desde  date    := CURRENT_DATE - (v_dias - 1);

    v_clientes   jsonb;
    v_gestiones  jsonb;
    v_mias       jsonb;
    v_por_dia    jsonb;
    v_por_tipo   jsonb;
    v_resultados jsonb;
    v_vendedores jsonb;
    v_ciudades   jsonb;
BEGIN
    -- ---------------------------------------------------------------- cartera
    SELECT jsonb_build_object(
        'total',         COUNT(*) FILTER (WHERE deleted_at IS NULL),
        'activos',       COUNT(*) FILTER (WHERE deleted_at IS NULL AND estado = 'ACTIVO'),
        'inactivos',     COUNT(*) FILTER (WHERE deleted_at IS NULL AND estado = 'INACTIVO'),
        'morosos',       COUNT(*) FILTER (WHERE deleted_at IS NULL AND estado = 'MOROSO'),
        'suspendidos',   COUNT(*) FILTER (WHERE deleted_at IS NULL AND estado = 'SUSPENDIDO'),
        'empresas',      COUNT(*) FILTER (WHERE deleted_at IS NULL AND tipo_cliente = 'EMPRESA'),
        'personas',      COUNT(*) FILTER (WHERE deleted_at IS NULL AND tipo_cliente = 'PERSONA'),
        'sin_vendedor',  COUNT(*) FILTER (WHERE deleted_at IS NULL AND vendedor_id IS NULL),
        'nuevos_mes',    COUNT(*) FILTER (WHERE deleted_at IS NULL AND created_at >= date_trunc('month', CURRENT_DATE)),
        'en_papelera',   COUNT(*) FILTER (WHERE deleted_at IS NOT NULL)
    ) INTO v_clientes
    FROM ventas.clientes;

    -- ------------------------------------------------------------- gestiones
    SELECT jsonb_build_object(
        'total',            COUNT(*),
        'realizadas',       COUNT(*) FILTER (WHERE estado = 'REALIZADA'),
        'pendientes',       COUNT(*) FILTER (WHERE estado = 'PENDIENTE'),
        'canceladas',       COUNT(*) FILTER (WHERE estado = 'CANCELADA'),
        'vencidas',         COUNT(*) FILTER (WHERE estado = 'PENDIENTE' AND fecha_programada < CURRENT_TIMESTAMP),
        'hoy',              COUNT(*) FILTER (WHERE estado = 'PENDIENTE' AND fecha_programada::date = CURRENT_DATE),
        'realizadas_hoy',   COUNT(*) FILTER (WHERE estado = 'REALIZADA' AND fecha_realizada::date = CURRENT_DATE),
        'realizadas_mes',   COUNT(*) FILTER (WHERE estado = 'REALIZADA' AND fecha_realizada >= date_trunc('month', CURRENT_DATE)),
        'minutos_mes',      COALESCE(SUM(duracion_minutos) FILTER (WHERE estado = 'REALIZADA' AND fecha_realizada >= date_trunc('month', CURRENT_DATE)), 0),
        'clientes_tocados', COUNT(DISTINCT cliente_id) FILTER (WHERE estado = 'REALIZADA' AND fecha_realizada >= date_trunc('month', CURRENT_DATE))
    ) INTO v_gestiones
    FROM ventas.gestiones;

    -- ------------------------------------------------------------- lo mío
    SELECT jsonb_build_object(
        'login',          v_login,
        'pendientes',     COUNT(*) FILTER (WHERE estado = 'PENDIENTE'),
        'vencidas',       COUNT(*) FILTER (WHERE estado = 'PENDIENTE' AND fecha_programada < CURRENT_TIMESTAMP),
        'hoy',            COUNT(*) FILTER (WHERE estado = 'PENDIENTE' AND fecha_programada::date = CURRENT_DATE),
        'realizadas_hoy', COUNT(*) FILTER (WHERE estado = 'REALIZADA' AND fecha_realizada::date = CURRENT_DATE),
        'clientes',       (SELECT COUNT(*) FROM ventas.clientes c
                            WHERE c.deleted_at IS NULL AND v_login IS NOT NULL AND upper(c.created_by) = upper(v_login))
    ) INTO v_mias
    FROM ventas.gestiones g
    WHERE v_login IS NOT NULL AND upper(g.created_by) = upper(v_login);

    -- ----------------------------------------------- movimiento por día
    -- La serie de días se genera aparte para que los días sin gestiones
    -- salgan en cero y la línea del gráfico no dé saltos.
    SELECT COALESCE(jsonb_agg(x ORDER BY x->>'dia'), '[]'::jsonb) INTO v_por_dia
    FROM (
        SELECT jsonb_build_object(
            'dia',         d::date,
            'realizadas',  (SELECT COUNT(*) FROM ventas.gestiones g
                             WHERE g.estado = 'REALIZADA' AND g.fecha_realizada::date = d::date),
            'programadas', (SELECT COUNT(*) FROM ventas.gestiones g
                             WHERE g.fecha_programada::date = d::date)
        ) AS x
        FROM generate_series(v_desde, CURRENT_DATE, interval '1 day') d
    ) s;

    -- --------------------------------------------------------- por tipo
    SELECT COALESCE(jsonb_agg(jsonb_build_object('tipo', tipo, 'cuantas', n) ORDER BY n DESC), '[]'::jsonb)
      INTO v_por_tipo
    FROM (SELECT tipo, COUNT(*) AS n FROM ventas.gestiones GROUP BY tipo) t;

    -- ----------------------------------------------------- por resultado
    SELECT COALESCE(jsonb_agg(jsonb_build_object('resultado', resultado, 'cuantas', n) ORDER BY n DESC), '[]'::jsonb)
      INTO v_resultados
    FROM (
        SELECT resultado, COUNT(*) AS n
          FROM ventas.gestiones
         WHERE estado = 'REALIZADA' AND resultado IS NOT NULL
         GROUP BY resultado
         ORDER BY COUNT(*) DESC
         LIMIT 8
    ) r;

    -- ------------------------------------------------------ por vendedor
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'vendedor',   nombre,
               'clientes',   clientes,
               'pendientes', pendientes
           ) ORDER BY clientes DESC), '[]'::jsonb)
      INTO v_vendedores
    FROM (
        SELECT COALESCE(TRIM(e.nombres || ' ' || e.apellidos), 'Sin vendedor') AS nombre,
               COUNT(*) AS clientes,
               (SELECT COUNT(*) FROM ventas.gestiones g
                  JOIN ventas.clientes c2 ON c2.id = g.cliente_id
                 WHERE g.estado = 'PENDIENTE'
                   AND c2.deleted_at IS NULL
                   AND c2.vendedor_id IS NOT DISTINCT FROM c.vendedor_id) AS pendientes
          FROM ventas.clientes c
          LEFT JOIN rh.empleados e ON e.id = c.vendedor_id
         WHERE c.deleted_at IS NULL
         GROUP BY c.vendedor_id, e.nombres, e.apellidos
         ORDER BY COUNT(*) DESC
         LIMIT 6
    ) v;

    -- -------------------------------------------------------- por ciudad
    SELECT COALESCE(jsonb_agg(jsonb_build_object('ciudad', ciudad, 'clientes', n) ORDER BY n DESC), '[]'::jsonb)
      INTO v_ciudades
    FROM (
        SELECT COALESCE(NULLIF(TRIM(canton), ''), 'Sin ciudad') AS ciudad, COUNT(*) AS n
          FROM ventas.clientes
         WHERE deleted_at IS NULL
         GROUP BY 1
         ORDER BY COUNT(*) DESC
         LIMIT 6
    ) c;

    RETURN jsonb_build_object(
        'success', true,
        'message', 'Estadísticas obtenidas exitosamente',
        'data', jsonb_build_object(
            'generado',    CURRENT_TIMESTAMP,
            'dias',        v_dias,
            'clientes',    v_clientes,
            'gestiones',   v_gestiones,
            'mias',        v_mias,
            'por_dia',     v_por_dia,
            'por_tipo',    v_por_tipo,
            'resultados',  v_resultados,
            'vendedores',  v_vendedores,
            'ciudades',    v_ciudades
        )
    );
EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object('success', false, 'message', 'Error al obtener las estadísticas: ' || SQLERRM, 'error_code', SQLSTATE);
END;
$function$;

COMMENT ON FUNCTION ventas.fn_estadisticas_generales(varchar, integer)
    IS 'Tablero de ventas: cartera, gestiones, lo del usuario y las series de los últimos días';
