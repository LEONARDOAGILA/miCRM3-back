-- ============================================================================
-- EL TABLERO, TAMBIÉN POR JERARQUÍA
--
-- Mismo fallo que tenía la agenda y mismo arreglo. El tablero que se ve en
-- «Gestión de clientes» mientras no hay un cliente elegido enseñaba las cifras
-- de TODA la empresa a cualquiera: a un vendedor de Cuenca le decía 1001
-- clientes, 478 pendientes y 272 vencidas. Ocho bloques, los ocho sin filtrar.
--
-- Ahora cada uno se recorta al ámbito de quien pregunta, que es el de siempre:
-- grupo con es_administrador lo ve todo; el resto, ventas.fn_usuarios_a_cargo
-- (él y los grupos por debajo del suyo). Un vendedor de grupo hoja ve sólo lo
-- suyo; un jefe zonal, lo de su zona.
--
-- QUÉ DECIDE SI UNA CIFRA ENTRA: el CLIENTE, no la gestión. Es decir «mi
-- cartera y lo que pasa en ella», no «las tareas que tengo asignadas» —eso es
-- la agenda, que es otra pantalla y usa gestiones.usuario_id—. Dos razones:
--
--   · Los ocho bloques quedan bajo una sola regla, y una cifra del tablero se
--     puede explicar sin saber cuál de los dos criterios le tocaba.
--   · Una gestión vieja sin usuario asignado sigue contando para el dueño de
--     su cliente. Con el otro criterio, hoy mismo (475 de 478 pendientes no
--     tienen usuario) el tablero de un jefe saldría en blanco.
--
-- El bloque «mías» sigue siendo personal y NO se toca el ámbito: es lo que le
-- toca a uno. Pero se le arregla de paso un error aparte: contaba por
-- created_by —quien REGISTRÓ la gestión— en vez de por usuario_id —a quien le
-- TOCA—, que es lo que se cambió el 04/10 al pasar los responsables a
-- usuarios. Por eso a PASTUDILLO le ponía 0 pendientes teniendo 2. Igual sus
-- clientes: eran los que había creado, no los que tiene asignados.
--
-- Con esto las tres pantallas dicen por fin lo mismo:
--   · lista de clientes «sólo los míos»  <->  mias.clientes
--   · agenda «sólo lo mío»               <->  mias.pendientes / vencidas / hoy
--   · los totales de arriba              <->  lo del equipo
--
-- RENDIMIENTO: el ámbito se traduce UNA vez a la lista de ids de clientes
-- visibles, y los ocho bloques preguntan contra ese array. Resolverlo cliente
-- a cliente dentro de cada bloque habría salido carísimo en la serie por días,
-- que recorre las gestiones una vez por cada día del gráfico.
--
-- p_solicitante NULL = sin restricción, como en las demás. El controlador lo
-- manda siempre: la ruta va detrás de auth:api.
--
-- Cambia la firma (un parámetro más), así que se borra antes la versión vieja:
-- con DEFAULT no reemplazaría, crearía una sobrecarga.
--
-- Idempotente: se puede volver a correr.
-- ============================================================================

DO $drop$
DECLARE
    r record;
BEGIN
    FOR r IN
        SELECT p.oid::regprocedure AS firma
          FROM pg_proc p
          JOIN pg_namespace n ON n.oid = p.pronamespace
         WHERE n.nspname = 'ventas' AND p.proname = 'fn_estadisticas_generales'
    LOOP
        EXECUTE 'DROP FUNCTION ' || r.firma;
    END LOOP;
END
$drop$;


CREATE OR REPLACE FUNCTION ventas.fn_estadisticas_generales(
    p_usuario_login varchar DEFAULT NULL,
    p_dias          integer DEFAULT 14,
    p_solicitante   bigint  DEFAULT NULL
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

    -- El ámbito, resuelto una sola vez
    v_ve_todo boolean  := false;
    v_todo    boolean;
    v_ambito  bigint[] := '{}'::bigint[];
    v_ids     bigint[] := '{}'::bigint[];
    v_alcance text;

    v_clientes   jsonb;
    v_gestiones  jsonb;
    v_mias       jsonb;
    v_por_dia    jsonb;
    v_por_tipo   jsonb;
    v_resultados jsonb;
    v_vendedores jsonb;
    v_ciudades   jsonb;
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
        'clientes_tocados', COUNT(DISTINCT cliente_id) FILTER (WHERE estado = 'REALIZADA' AND fecha_realizada >= date_trunc('month', CURRENT_DATE))
    ) INTO v_gestiones
    FROM ventas.gestiones
    WHERE v_todo OR cliente_id = ANY(v_ids);

    -- ------------------------------------------------------------- lo mío
    -- Aquí NO entra el ámbito: «mío» es mío aunque mande sobre media empresa.
    -- Por usuario_id y no por created_by: lo que me TOCA, no lo que registré.
    SELECT jsonb_build_object(
        'login',          v_login,
        'pendientes',     COUNT(*) FILTER (WHERE estado = 'PENDIENTE'),
        'vencidas',       COUNT(*) FILTER (WHERE estado = 'PENDIENTE' AND fecha_programada < CURRENT_TIMESTAMP),
        'hoy',            COUNT(*) FILTER (WHERE estado = 'PENDIENTE' AND fecha_programada::date = CURRENT_DATE),
        'realizadas_hoy', COUNT(*) FILTER (WHERE estado = 'REALIZADA' AND fecha_realizada::date = CURRENT_DATE),
        -- Los que tengo asignados, en cualquiera de los papeles; es la misma
        -- cuenta que da la lista de clientes con «sólo los míos»
        'clientes',       (SELECT COUNT(*) FROM ventas.clientes c
                            WHERE c.deleted_at IS NULL
                              AND p_solicitante IS NOT NULL
                              AND ventas.fn_cliente_es_de(c.id, p_solicitante))
    ) INTO v_mias
    FROM ventas.gestiones g
    WHERE p_solicitante IS NOT NULL AND g.usuario_id = p_solicitante;

    -- ----------------------------------------------- movimiento por día
    -- La serie de días se genera aparte para que los días sin gestiones
    -- salgan en cero y la línea del gráfico no dé saltos.
    SELECT COALESCE(jsonb_agg(x ORDER BY x->>'dia'), '[]'::jsonb) INTO v_por_dia
    FROM (
        SELECT jsonb_build_object(
            'dia',         d::date,
            'realizadas',  (SELECT COUNT(*) FROM ventas.gestiones g
                             WHERE g.estado = 'REALIZADA' AND g.fecha_realizada::date = d::date
                               AND (v_todo OR g.cliente_id = ANY(v_ids))),
            'programadas', (SELECT COUNT(*) FROM ventas.gestiones g
                             WHERE g.fecha_programada::date = d::date
                               AND (v_todo OR g.cliente_id = ANY(v_ids)))
        ) AS x
        FROM generate_series(v_desde, CURRENT_DATE, interval '1 day') d
    ) s;

    -- --------------------------------------------------------- por tipo
    SELECT COALESCE(jsonb_agg(jsonb_build_object('tipo', tipo, 'cuantas', n) ORDER BY n DESC), '[]'::jsonb)
      INTO v_por_tipo
    FROM (
        SELECT tipo, COUNT(*) AS n
          FROM ventas.gestiones
         WHERE v_todo OR cliente_id = ANY(v_ids)
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
        -- El vendedor es un usuario desde el cambio de responsables; el
        -- empleado se quedó en recursos humanos
        SELECT COALESCE(ventas.fn_nombre_usuario(c.vendedor_usuario_id), 'Sin vendedor') AS nombre,
               COUNT(*) AS clientes,
               (SELECT COUNT(*) FROM ventas.gestiones g
                  JOIN ventas.clientes c2 ON c2.id = g.cliente_id
                 WHERE g.estado = 'PENDIENTE'
                   AND c2.deleted_at IS NULL
                   AND c2.vendedor_usuario_id IS NOT DISTINCT FROM c.vendedor_usuario_id
                   AND (v_todo OR c2.id = ANY(v_ids))) AS pendientes
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
            -- Hasta dónde llega lo que se está contando, para que la pantalla
            -- lo pueda decir en vez de dejar al que mira adivinando
            'alcance',     v_alcance,
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

COMMENT ON FUNCTION ventas.fn_estadisticas_generales(varchar, integer, bigint)
    IS 'El tablero de ventas, recortado al ámbito de p_solicitante. El bloque «mias» es siempre personal.';
