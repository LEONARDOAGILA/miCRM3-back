-- ===========================================================================
-- EL HISTORIAL, FILTRADO POR LA VISIBILIDAD DEL QUE MIRA
-- ===========================================================================
-- Fecha: 2026-10-08
-- Se aplica después de 2026-10-08_seguridad_visibilidad_datos.sql.
--
-- fn_gestiones_listar_paginado no sabía QUIÉN estaba preguntando: devolvía
-- todas las gestiones del cliente a quien fuera. Aquí se le añade p_usuario_id
-- y el filtro que sale de seguridad.fn_usuarios_visibles.
--
-- EL FILTRO VA EN LAS DOS CONSULTAS —la del total y la de la página—, y no es
-- un detalle: si sólo se filtrara la página, el contador seguiría diciendo «48
-- gestiones» mientras se ven doce, que es contar en voz alta lo que no se deja
-- ver.
--
-- NULL = sin filtro. Lo devuelve fn_usuarios_visibles cuando el alcance es
-- TODO, que hoy es el de todo el mundo: con la tabla de visibilidad vacía esta
-- función se comporta exactamente como antes.
--
-- LAS GESTIONES SIN DUEÑO (usuario_id NULL, las anteriores al cambio de
-- responsables) las ve sólo quien no tiene filtro. Es lo prudente: de una fila
-- de la que no se sabe quién la hizo no se puede decidir si te toca.
--
-- SIN USUARIO NO SE VE NADA. El parámetro va al final y con default para que
-- una llamada antigua no reviente, pero devuelve CERO filas, no todas: una
-- consulta que no dice quién pregunta es una consulta sin permiso. Falla
-- cerrado a propósito, así que el controlador se actualiza en el mismo paso o
-- el historial se queda vacío para todos.
--
-- SOBRECARGA: CREATE OR REPLACE con otra firma NO reemplaza, añade. Por eso se
-- tira primero la de diez parámetros.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- Fuera la versión sin p_usuario_id, o quedarían las dos
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    v_firma text;
BEGIN
    FOR v_firma IN
        SELECT 'ventas.fn_gestiones_listar_paginado(' || pg_get_function_identity_arguments(p.oid) || ')'
          FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
         WHERE n.nspname = 'ventas' AND p.proname = 'fn_gestiones_listar_paginado'
    LOOP
        EXECUTE 'DROP FUNCTION IF EXISTS ' || v_firma;
        RAISE NOTICE 'tirada %', v_firma;
    END LOOP;
END;
$$;


CREATE OR REPLACE FUNCTION ventas.fn_gestiones_listar_paginado(
    p_cliente_id bigint,
    p_page       integer,
    p_per_page   integer,
    p_search     text,
    p_tipo       character varying,
    p_estado     character varying,
    p_desde      date,
    p_hasta      date,
    p_resultado  character varying,
    p_creado_por character varying,
    p_usuario_id bigint DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
    v_offset        integer;
    v_total         bigint;
    v_data          jsonb;
    v_filtro        text;
    v_registradores jsonb;
    v_usuarios      bigint[];
BEGIN
    v_offset := (GREATEST(p_page, 1) - 1) * p_per_page;
    v_filtro := NULLIF(TRIM(COALESCE(p_search, '')), '');

    -- Una vez, no por fila. NULL = sin filtro (alcance TODO)
    v_usuarios := seguridad.fn_usuarios_visibles(p_usuario_id, 'GESTION');

    SELECT COUNT(*) INTO v_total
      FROM ventas.gestiones g
     WHERE g.cliente_id = p_cliente_id
       AND (v_usuarios IS NULL OR g.usuario_id = ANY(v_usuarios))
       AND (p_tipo       IS NULL OR g.tipo       = p_tipo)
       AND (p_estado     IS NULL OR g.estado     = p_estado)
       AND (p_resultado  IS NULL OR g.resultado  = p_resultado)
       AND (p_creado_por IS NULL OR g.created_by = p_creado_por)
       AND (p_desde  IS NULL OR COALESCE(g.fecha_realizada, g.fecha_programada) >= p_desde::timestamptz)
       AND (p_hasta  IS NULL OR COALESCE(g.fecha_realizada, g.fecha_programada) < (p_hasta + 1)::timestamptz)
       AND (v_filtro IS NULL
            OR g.asunto ILIKE '%' || v_filtro || '%'
            OR g.nota   ILIKE '%' || v_filtro || '%');

    SELECT COALESCE(jsonb_agg(ventas.fn_gestiones_json(t.id) ORDER BY t.orden), '[]'::jsonb) INTO v_data
      FROM (
        SELECT g.id,
               ROW_NUMBER() OVER (ORDER BY COALESCE(g.fecha_realizada, g.fecha_programada) DESC NULLS LAST,
                                           g.id DESC) AS orden
          FROM ventas.gestiones g
         WHERE g.cliente_id = p_cliente_id
           AND (v_usuarios IS NULL OR g.usuario_id = ANY(v_usuarios))
           AND (p_tipo       IS NULL OR g.tipo       = p_tipo)
           AND (p_estado     IS NULL OR g.estado     = p_estado)
           AND (p_resultado  IS NULL OR g.resultado  = p_resultado)
           AND (p_creado_por IS NULL OR g.created_by = p_creado_por)
           AND (p_desde  IS NULL OR COALESCE(g.fecha_realizada, g.fecha_programada) >= p_desde::timestamptz)
           AND (p_hasta  IS NULL OR COALESCE(g.fecha_realizada, g.fecha_programada) < (p_hasta + 1)::timestamptz)
           AND (v_filtro IS NULL
                OR g.asunto ILIKE '%' || v_filtro || '%'
                OR g.nota   ILIKE '%' || v_filtro || '%')
         ORDER BY orden
         LIMIT p_per_page OFFSET v_offset
      ) t;

    -- El desplegable «Registrado por»: también filtrado, o el menú delataría
    -- los nombres de quienes escribieron lo que no se puede ver
    SELECT COALESCE(jsonb_agg(x.quien ORDER BY x.quien), '[]'::jsonb) INTO v_registradores
      FROM (
        SELECT DISTINCT g.created_by AS quien
          FROM ventas.gestiones g
         WHERE g.cliente_id = p_cliente_id
           AND g.created_by IS NOT NULL
           AND (v_usuarios IS NULL OR g.usuario_id = ANY(v_usuarios))
      ) x;

    RETURN jsonb_build_object(
        'success', true,
        'message', 'Gestiones obtenidas exitosamente',
        'data', v_data,
        'meta', jsonb_build_object(
            'total',        v_total,
            'per_page',     p_per_page,
            'current_page', GREATEST(p_page, 1),
            'last_page',    GREATEST(CEIL(v_total::numeric / NULLIF(p_per_page, 0))::integer, 1)
        ),
        'filtros', jsonb_build_object('registradores', v_registradores)
    );
EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object('success', false, 'message', 'Error al listar las gestiones: ' || SQLERRM, 'error_code', SQLSTATE);
END;
$function$;


-- ---------------------------------------------------------------------------
-- COMPROBACIÓN
-- ---------------------------------------------------------------------------
-- Con la tabla de visibilidad vacía, los dos totales tienen que ser iguales:
--
--   SELECT (ventas.fn_gestiones_listar_paginado(1055,1,10,NULL,NULL,NULL,NULL,NULL,NULL,NULL) -> 'meta' ->> 'total') AS sin_usuario,
--          (ventas.fn_gestiones_listar_paginado(1055,1,10,NULL,NULL,NULL,NULL,NULL,NULL,NULL,46) -> 'meta' ->> 'total') AS con_vcuenca1;
