-- ===========================================================================
-- MÁS MÉTRICAS EN EL TABLERO DE VENTAS
-- ===========================================================================
-- Fecha: 2026-10-10
-- Se aplica después de 2026-10-10_ventas_clientes_filtros_de_columna.sql.
--
-- El tablero contaba bien el INVENTARIO —cuántos clientes, cuántas gestiones,
-- de qué tipo, en qué ciudad— pero no contestaba las preguntas que de verdad
-- se hacen al mirarlo:
--
--   ¿a quién no estamos llamando?        -> cobertura
--   ¿sirve de algo llamar?               -> efectividad
--   ¿quién está trabajando?              -> usuarios
--   ¿qué falta por repartir?             -> papeles
--
-- CUATRO BLOQUES NUEVOS, ninguno quita nada de lo que ya había:
--
--   cobertura    clientes sin gestión nunca, dormidos (sin contacto en 30
--                días) y sin próximo paso. Es la lista de los que se caen
--                del radar, que es lo que más dinero cuesta.
--
--   efectividad  de lo realizado en el periodo, en cuántas se habló de
--                verdad con alguien. Separa el «no contesta» del «no
--                interesa»: la primera es un problema de horario, la
--                segunda de producto.
--
--   usuarios     quién hizo cuántas en el periodo y qué le queda pendiente
--                y vencido. El bloque `vendedores` que ya había mide
--                CARTERA, no trabajo.
--
--   papeles      cuántos clientes no tienen cobrador, asistente o
--                postventa, ahora que se reparten los cuatro.
--
-- SE RESPETA EL ÁMBITO IGUAL QUE EL RESTO: cada bloque filtra por v_ids
-- —los clientes que puede ver quien pregunta— y por v_visibles —de qué
-- usuarios puede ver gestiones—. Un jefe ve lo suyo y lo de su equipo; un
-- vendedor, lo suyo.
--
-- LOS «DORMIDOS» SE MIDEN SOBRE CLIENTES ACTIVOS. Un cliente inactivo o en
-- papelera que lleva meses sin contacto no es un descuido, es lo normal:
-- meterlo en la cuenta haría que el número no sirviera para nada.
--
-- Idempotente.
-- ===========================================================================

CREATE OR REPLACE FUNCTION ventas.fn_estadisticas_generales(
    p_usuario_login character varying DEFAULT NULL::character varying,
    p_dias          integer           DEFAULT 14,
    p_solicitante   bigint            DEFAULT NULL::bigint
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'ventas', 'rh'
AS $function$
DECLARE
    -- Cuántos días sin contacto para considerar a un cliente «dormido».
    -- Un mes es el plazo con el que se trabaja aquí; si cambia, cambia en un
    -- sitio y el rótulo de la pantalla lo lee de la respuesta.
    c_dias_dormido constant integer := 30;

    v_dias   integer := LEAST(GREATEST(COALESCE(p_dias, 14), 7), 90);
    v_login  varchar := NULLIF(TRIM(COALESCE(p_usuario_login, '')), '');
    v_desde  date    := CURRENT_DATE - (v_dias - 1);

    -- El ámbito, resuelto una sola vez
    v_ve_todo boolean  := false;
    v_todo    boolean;
    v_ambito  bigint[] := '{}'::bigint[];
    v_ids     bigint[] := '{}'::bigint[];
    v_visibles bigint[];
    v_alcance text;

    v_clientes    jsonb;
    v_gestiones   jsonb;
    v_mias        jsonb;
    v_por_dia     jsonb;
    v_por_tipo    jsonb;
    v_resultados  jsonb;
    v_vendedores  jsonb;
    v_ciudades    jsonb;
    v_cobertura   jsonb;
    v_efectividad jsonb;
    v_usuarios    jsonb;
    v_papeles     jsonb;
BEGIN
    -- ------------------------------------------------------------- el ámbito
    IF p_solicitante IS NOT NULL THEN
        SELECT COALESCE(g.es_administrador, false) INTO v_ve_todo
          FROM seguridad.users u
          LEFT JOIN seguridad.grupos g ON g.id = u.grupo_id
         WHERE u.id = p_solicitante;
    END IF;
    v_todo := (p_solicitante IS NULL OR COALESCE(v_ve_todo, false));

    IF NOT v_todo THEN
        v_ambito := ventas.fn_usuarios_a_cargo(p_solicitante);
        -- Los clientes del ámbito, de una vez: los bloques de abajo preguntan
        -- contra este array en vez de resolver la jerarquía fila por fila.
        -- Los de la papelera entran a propósito, que 'en_papelera' los cuenta.
        SELECT ARRAY(
            SELECT c.id FROM ventas.clientes c
             WHERE ventas.fn_cliente_es_de_alguno(c.id, v_ambito)
        ) INTO v_ids;
    END IF;

    -- El segundo techo: qué gestiones puede ver, además de de qué clientes.
    -- NULL es «sin filtro» (alcance TODO) y entonces nada de abajo cambia.
    v_visibles := seguridad.fn_usuarios_visibles(p_solicitante, 'GESTION');

    v_alcance := CASE
        WHEN v_todo THEN 'TODO'
        WHEN COALESCE(array_length(v_ambito, 1), 0) > 1 THEN 'EQUIPO'
        ELSE 'PROPIO'
    END;

    -- ---------------------------------------------------------------- cartera
    SELECT jsonb_build_object(
        'total',         COUNT(*) FILTER (WHERE deleted_at IS NULL),
        'activos',       COUNT(*) FILTER (WHERE deleted_at IS NULL AND estado = 'ACTIVO'),
        'inactivos',     COUNT(*) FILTER (WHERE deleted_at IS NULL AND estado = 'INACTIVO'),
        'morosos',       COUNT(*) FILTER (WHERE deleted_at IS NULL AND estado = 'MOROSO'),
        'suspendidos',   COUNT(*) FILTER (WHERE deleted_at IS NULL AND estado = 'SUSPENDIDO'),
        'empresas',      COUNT(*) FILTER (WHERE deleted_at IS NULL AND tipo_cliente = 'EMPRESA'),
        'personas',      COUNT(*) FILTER (WHERE deleted_at IS NULL AND tipo_cliente = 'PERSONA'),
        'sin_vendedor',  COUNT(*) FILTER (WHERE deleted_at IS NULL AND vendedor_usuario_id IS NULL),
        'nuevos_mes',    COUNT(*) FILTER (WHERE deleted_at IS NULL AND created_at >= date_trunc('month', CURRENT_DATE)),
        'en_papelera',   COUNT(*) FILTER (WHERE deleted_at IS NOT NULL)
    ) INTO v_clientes
    FROM ventas.clientes
    WHERE v_todo OR id = ANY(v_ids);

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
        'clientes_tocados', COUNT(DISTINCT cliente_id) FILTER (WHERE estado = 'REALIZADA' AND fecha_realizada >= date_trunc('month', CURRENT_DATE)),
        -- Lo que viene: lo pendiente de los próximos siete días, sin contar
        -- lo ya vencido. Es lo que hay que poder atender esta semana.
        'proximos_7',       COUNT(*) FILTER (WHERE estado = 'PENDIENTE'
                                               AND fecha_programada >= CURRENT_TIMESTAMP
                                               AND fecha_programada < CURRENT_DATE + 8),
        -- Cuánto dura de media una gestión del periodo; en minutos y sin
        -- decimales, que es como se habla de esto
        'duracion_media',   COALESCE(ROUND(AVG(duracion_minutos) FILTER (
                                WHERE estado = 'REALIZADA'
                                  AND fecha_realizada::date >= v_desde
                                  AND duracion_minutos > 0)), 0)
    ) INTO v_gestiones
    FROM ventas.gestiones
    WHERE (v_todo OR cliente_id = ANY(v_ids))
      AND (v_visibles IS NULL OR usuario_id = ANY(v_visibles));

    -- ------------------------------------------------------------- lo mío
    -- Aquí NO entra el ámbito: «mío» es mío aunque mande sobre media empresa.
    -- Por usuario_id y no por created_by: lo que me TOCA, no lo que registré.
    SELECT jsonb_build_object(
        'login',          v_login,
        'pendientes',     COUNT(*) FILTER (WHERE estado = 'PENDIENTE'),
        'vencidas',       COUNT(*) FILTER (WHERE estado = 'PENDIENTE' AND fecha_programada < CURRENT_TIMESTAMP),
        'hoy',            COUNT(*) FILTER (WHERE estado = 'PENDIENTE' AND fecha_programada::date = CURRENT_DATE),
        'realizadas_hoy', COUNT(*) FILTER (WHERE estado = 'REALIZADA' AND fecha_realizada::date = CURRENT_DATE),
        'clientes',       (SELECT COUNT(*) FROM ventas.clientes c
                            WHERE c.deleted_at IS NULL
                              AND p_solicitante IS NOT NULL
                              AND ventas.fn_cliente_es_de(c.id, p_solicitante))
    ) INTO v_mias
    FROM ventas.gestiones g
    WHERE p_solicitante IS NOT NULL AND g.usuario_id = p_solicitante;

    -- ------------------------------------------------------- NUEVO: cobertura
    -- A quién no estamos llamando. Sólo clientes ACTIVOS: que un inactivo
    -- lleve meses sin contacto no es un descuido.
    SELECT jsonb_build_object(
        'dias_dormido', c_dias_dormido,
        'activos',      COUNT(*),
        -- Nunca se le hizo una gestión
        'sin_gestion',  COUNT(*) FILTER (WHERE ultima IS NULL),
        -- Ni hoy ni en el último mes; los que nunca entran aquí también
        'dormidos',     COUNT(*) FILTER (WHERE ultima IS NULL OR ultima < CURRENT_DATE - c_dias_dormido),
        -- Sin ningún próximo paso agendado: los que se caen del radar
        'sin_proxima',  COUNT(*) FILTER (WHERE NOT tiene_pendiente),
        'con_proxima',  COUNT(*) FILTER (WHERE tiene_pendiente)
    ) INTO v_cobertura
    FROM (
        -- Las gestiones se resumen UNA vez por cliente y se cruzan; con dos
        -- subconsultas por cliente esto costaba 330 ms en una pestaña que se
        -- abre a cada rato.
        SELECT c.id, r.ultima, COALESCE(r.tiene_pendiente, false) AS tiene_pendiente
          FROM ventas.clientes c
          LEFT JOIN (
                SELECT g.cliente_id,
                       MAX(g.fecha_realizada::date) FILTER (WHERE g.estado = 'REALIZADA') AS ultima,
                       COUNT(*) FILTER (WHERE g.estado = 'PENDIENTE') > 0               AS tiene_pendiente
                  FROM ventas.gestiones g
                 WHERE (v_visibles IS NULL OR g.usuario_id = ANY(v_visibles))
                 GROUP BY g.cliente_id
          ) r ON r.cliente_id = c.id
         WHERE c.deleted_at IS NULL AND c.estado = 'ACTIVO'
           AND (v_todo OR c.id = ANY(v_ids))
    ) x;

    -- ----------------------------------------------------- NUEVO: efectividad
    -- De lo realizado en el periodo, en cuántas se habló con alguien.
    -- «No contesta» y «buzón» se separan de «no interesado» a propósito: la
    -- primera es un problema de horario, la segunda de producto.
    SELECT jsonb_build_object(
        'dias',          v_dias,
        'realizadas',    COUNT(*),
        'con_resultado', COUNT(*) FILTER (WHERE resultado IS NOT NULL),
        'contacto',      COUNT(*) FILTER (WHERE resultado IN ('CONTACTADO','INTERESADO','COTIZACION','VENTA','NO_INTERESADO','RECLAMO','VOLVER_A_LLAMAR')),
        'sin_contacto',  COUNT(*) FILTER (WHERE resultado IN ('NO_CONTESTA','BUZON','NUMERO_ERRADO')),
        'interesados',   COUNT(*) FILTER (WHERE resultado IN ('INTERESADO','COTIZACION','VENTA')),
        'ventas',        COUNT(*) FILTER (WHERE resultado = 'VENTA'),
        'cotizaciones',  COUNT(*) FILTER (WHERE resultado = 'COTIZACION'),
        'reclamos',      COUNT(*) FILTER (WHERE resultado = 'RECLAMO'),
        -- Porcentaje de las que tienen resultado, no del total: una gestión
        -- sin resultado no es un fracaso, es que no se anotó
        'tasa_contacto', CASE WHEN COUNT(*) FILTER (WHERE resultado IS NOT NULL) = 0 THEN 0
                              ELSE ROUND(100.0 * COUNT(*) FILTER (WHERE resultado IN ('CONTACTADO','INTERESADO','COTIZACION','VENTA','NO_INTERESADO','RECLAMO','VOLVER_A_LLAMAR'))
                                       / COUNT(*) FILTER (WHERE resultado IS NOT NULL))
                         END
    ) INTO v_efectividad
    FROM ventas.gestiones
    WHERE estado = 'REALIZADA'
      AND fecha_realizada::date >= v_desde
      AND (v_todo OR cliente_id = ANY(v_ids))
      AND (v_visibles IS NULL OR usuario_id = ANY(v_visibles));

    -- -------------------------------------------------------- NUEVO: usuarios
    -- Quién está trabajando. El bloque `vendedores` mide CARTERA —cuántos
    -- clientes tiene cada uno—; esto mide TRABAJO.
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'usuario',    nombre,
               'realizadas', realizadas,
               'pendientes', pendientes,
               'vencidas',   vencidas,
               'minutos',    minutos
           ) ORDER BY realizadas DESC, pendientes DESC), '[]'::jsonb)
      INTO v_usuarios
    FROM (
        SELECT COALESCE(ventas.fn_nombre_usuario(g.usuario_id), 'Sin responsable') AS nombre,
               COUNT(*) FILTER (WHERE g.estado = 'REALIZADA' AND g.fecha_realizada::date >= v_desde) AS realizadas,
               COUNT(*) FILTER (WHERE g.estado = 'PENDIENTE') AS pendientes,
               COUNT(*) FILTER (WHERE g.estado = 'PENDIENTE' AND g.fecha_programada < CURRENT_TIMESTAMP) AS vencidas,
               COALESCE(SUM(g.duracion_minutos) FILTER (WHERE g.estado = 'REALIZADA' AND g.fecha_realizada::date >= v_desde), 0) AS minutos
          FROM ventas.gestiones g
         WHERE (v_todo OR g.cliente_id = ANY(v_ids))
           AND (v_visibles IS NULL OR g.usuario_id = ANY(v_visibles))
         GROUP BY g.usuario_id
        HAVING COUNT(*) FILTER (WHERE g.estado = 'REALIZADA' AND g.fecha_realizada::date >= v_desde) > 0
            OR COUNT(*) FILTER (WHERE g.estado = 'PENDIENTE') > 0
         ORDER BY 2 DESC
         LIMIT 8
    ) u;

    -- --------------------------------------------------------- NUEVO: papeles
    -- Qué falta por repartir, ahora que son cuatro papeles y no uno
    -- La última asignación de cada papel, de una pasada. Llamar a
    -- fn_cliente_responsable_actual cuatro veces por cliente son cuatro mil
    -- consultas para una cifra que se enseña en una tarjeta.
    --
    -- Mismo criterio que esa función: el vendedor vive en la ficha y los
    -- otros tres en la última asignación de su papel; si esa última dejó el
    -- hueco vacío (usuario_nuevo_id nulo), el cliente cuenta como «sin».
    WITH ultima AS (
        SELECT DISTINCT ON (a.cliente_id, a.rol)
               a.cliente_id, a.rol, a.usuario_nuevo_id
          FROM ventas.asignaciones_clientes a
         ORDER BY a.cliente_id, a.rol, a.asignado_at DESC, a.id DESC
    )
    SELECT jsonb_build_object(
        'activos',        COUNT(*),
        'sin_vendedor',   COUNT(*) FILTER (WHERE c.vendedor_usuario_id IS NULL),
        'sin_cobrador',   COUNT(*) FILTER (WHERE cob.usuario_nuevo_id IS NULL),
        'sin_asistente',  COUNT(*) FILTER (WHERE asi.usuario_nuevo_id IS NULL),
        'sin_postventa',  COUNT(*) FILTER (WHERE pos.usuario_nuevo_id IS NULL)
    ) INTO v_papeles
    FROM ventas.clientes c
    LEFT JOIN ultima cob ON cob.cliente_id = c.id AND cob.rol = 'COBRADOR'
    LEFT JOIN ultima asi ON asi.cliente_id = c.id AND asi.rol = 'ASISTENTE'
    LEFT JOIN ultima pos ON pos.cliente_id = c.id AND pos.rol = 'POSTVENTA'
    WHERE c.deleted_at IS NULL
      AND (v_todo OR c.id = ANY(v_ids));

    -- ----------------------------------------------- movimiento por día
    SELECT COALESCE(jsonb_agg(x ORDER BY x->>'dia'), '[]'::jsonb) INTO v_por_dia
    FROM (
        SELECT jsonb_build_object(
            'dia',         d::date,
            'realizadas',  (SELECT COUNT(*) FROM ventas.gestiones g
                             WHERE g.estado = 'REALIZADA' AND g.fecha_realizada::date = d::date
                               AND (v_todo OR g.cliente_id = ANY(v_ids))
                               AND (v_visibles IS NULL OR g.usuario_id = ANY(v_visibles))),
            'programadas', (SELECT COUNT(*) FROM ventas.gestiones g
                             WHERE g.fecha_programada::date = d::date
                               AND (v_todo OR g.cliente_id = ANY(v_ids))
                               AND (v_visibles IS NULL OR g.usuario_id = ANY(v_visibles)))
        ) AS x
        FROM generate_series(v_desde, CURRENT_DATE, interval '1 day') d
    ) s;

    -- --------------------------------------------------------- por tipo
    SELECT COALESCE(jsonb_agg(jsonb_build_object('tipo', tipo, 'cuantas', n) ORDER BY n DESC), '[]'::jsonb)
      INTO v_por_tipo
    FROM (
        SELECT tipo, COUNT(*) AS n
          FROM ventas.gestiones
         WHERE (v_todo OR cliente_id = ANY(v_ids))
           AND (v_visibles IS NULL OR usuario_id = ANY(v_visibles))
         GROUP BY tipo
    ) t;

    -- ----------------------------------------------------- por resultado
    SELECT COALESCE(jsonb_agg(jsonb_build_object('resultado', resultado, 'cuantas', n) ORDER BY n DESC), '[]'::jsonb)
      INTO v_resultados
    FROM (
        SELECT resultado, COUNT(*) AS n
          FROM ventas.gestiones
         WHERE estado = 'REALIZADA' AND resultado IS NOT NULL
           AND (v_todo OR cliente_id = ANY(v_ids))
           AND (v_visibles IS NULL OR usuario_id = ANY(v_visibles))
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
        SELECT COALESCE(ventas.fn_nombre_usuario(c.vendedor_usuario_id), 'Sin vendedor') AS nombre,
               COUNT(*) AS clientes,
               (SELECT COUNT(*) FROM ventas.gestiones g
                  JOIN ventas.clientes c2 ON c2.id = g.cliente_id
                 WHERE g.estado = 'PENDIENTE'
                   AND c2.deleted_at IS NULL
                   AND c2.vendedor_usuario_id IS NOT DISTINCT FROM c.vendedor_usuario_id
                   AND (v_todo OR c2.id = ANY(v_ids))
                   AND (v_visibles IS NULL OR g.usuario_id = ANY(v_visibles))) AS pendientes
          FROM ventas.clientes c
         WHERE c.deleted_at IS NULL
           AND (v_todo OR c.id = ANY(v_ids))
         GROUP BY c.vendedor_usuario_id
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
           AND (v_todo OR id = ANY(v_ids))
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
            'alcance',     v_alcance,
            'clientes',    v_clientes,
            'gestiones',   v_gestiones,
            'mias',        v_mias,
            'cobertura',   v_cobertura,
            'efectividad', v_efectividad,
            'usuarios',    v_usuarios,
            'papeles',     v_papeles,
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


-- ---------------------------------------------------------------------------
-- COMPROBACIÓN
-- ---------------------------------------------------------------------------
SELECT (ventas.fn_estadisticas_generales('LAGILA', 14, 4) -> 'data' -> 'cobertura')   AS cobertura,
       (ventas.fn_estadisticas_generales('LAGILA', 14, 4) -> 'data' -> 'efectividad') AS efectividad,
       (ventas.fn_estadisticas_generales('LAGILA', 14, 4) -> 'data' -> 'papeles')     AS papeles;
