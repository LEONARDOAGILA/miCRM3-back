-- ============================================================================
-- GESTIONES: filtrar el historial por resultado y por quién la registró
--
-- La pestaña Historial tenía dos filtros (tipo y estado) y el historial de un
-- cliente trabajado llega a varias páginas. Se añaden dos más, que son por los
-- que se busca de verdad: cómo terminó la gestión y quién la registró.
--
-- fn_gestiones_listar_paginado gana p_resultado y p_creado_por, y devuelve
-- además la lista de quienes han registrado gestiones de ese cliente: el
-- desplegable de «Registrado por» se llena con eso y no con una tabla de
-- usuarios, porque lo que hace falta ofrecer son los que de verdad aparecen en
-- ese historial, no los trescientos del sistema.
--
-- Esa lista se calcula SIN los demás filtros a propósito: si se filtrara
-- también por tipo o por estado, al elegir un responsable desaparecerían los
-- demás del desplegable y no habría forma de cambiar de opinión.
--
-- OJO con el CREATE OR REPLACE: cambiar la firma crea una SOBRECARGA, no un
-- reemplazo, y entonces la llamada de ocho argumentos del back se vuelve
-- ambigua («function is not unique»). Se borran primero todas las versiones.
--
-- Idempotente: se puede volver a correr.
-- ============================================================================

DO $$
DECLARE
    v_firma text;
BEGIN
    FOR v_firma IN
        SELECT 'ventas.fn_gestiones_listar_paginado(' || pg_get_function_identity_arguments(p.oid) || ')'
          FROM pg_proc p
          JOIN pg_namespace n ON n.oid = p.pronamespace
         WHERE n.nspname = 'ventas'
           AND p.proname = 'fn_gestiones_listar_paginado'
    LOOP
        EXECUTE 'DROP FUNCTION IF EXISTS ' || v_firma;
        RAISE NOTICE 'Borrada %', v_firma;
    END LOOP;
END
$$;

CREATE FUNCTION ventas.fn_gestiones_listar_paginado(
    p_cliente_id bigint,
    p_page       integer   DEFAULT 1,
    p_per_page   integer   DEFAULT 15,
    p_search     text      DEFAULT ''::text,
    p_tipo       varchar   DEFAULT NULL,
    p_estado     varchar   DEFAULT NULL,
    p_desde      date      DEFAULT NULL,
    p_hasta      date      DEFAULT NULL,
    -- Cómo terminó (ck_gestiones_resultado). NULL = todos
    p_resultado  varchar   DEFAULT NULL,
    -- El login de quien la registró (gestiones.created_by). NULL = todos
    p_creado_por varchar   DEFAULT NULL
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
BEGIN
    v_offset := (GREATEST(p_page, 1) - 1) * p_per_page;
    v_filtro := NULLIF(TRIM(COALESCE(p_search, '')), '');

    SELECT COUNT(*) INTO v_total
      FROM ventas.gestiones g
     WHERE (p_cliente_id IS NULL OR g.cliente_id = p_cliente_id)
       AND (p_tipo       IS NULL OR g.tipo       = p_tipo)
       AND (p_estado     IS NULL OR g.estado     = p_estado)
       AND (p_resultado  IS NULL OR g.resultado  = p_resultado)
       AND (p_creado_por IS NULL OR g.created_by = p_creado_por)
       AND (p_desde  IS NULL OR COALESCE(g.fecha_realizada, g.fecha_programada) >= p_desde::timestamptz)
       AND (p_hasta  IS NULL OR COALESCE(g.fecha_realizada, g.fecha_programada) < (p_hasta + 1)::timestamptz)
       AND (v_filtro IS NULL
            OR g.asunto    ILIKE '%' || v_filtro || '%'
            OR g.nota      ILIKE '%' || v_filtro || '%'
            OR g.telefono  ILIKE '%' || v_filtro || '%'
            OR g.resultado ILIKE '%' || v_filtro || '%');

    -- Lo pendiente primero y, dentro de cada grupo, lo más reciente arriba
    SELECT COALESCE(jsonb_agg(ventas.fn_gestiones_json(t.id) ORDER BY t.orden), '[]'::jsonb) INTO v_data
      FROM (
        SELECT g.id,
               ROW_NUMBER() OVER (ORDER BY (g.estado = 'PENDIENTE') DESC,
                                           COALESCE(g.fecha_realizada, g.fecha_programada) DESC,
                                           g.id DESC) AS orden
          FROM ventas.gestiones g
         WHERE (p_cliente_id IS NULL OR g.cliente_id = p_cliente_id)
           AND (p_tipo       IS NULL OR g.tipo       = p_tipo)
           AND (p_estado     IS NULL OR g.estado     = p_estado)
           AND (p_resultado  IS NULL OR g.resultado  = p_resultado)
           AND (p_creado_por IS NULL OR g.created_by = p_creado_por)
           AND (p_desde  IS NULL OR COALESCE(g.fecha_realizada, g.fecha_programada) >= p_desde::timestamptz)
           AND (p_hasta  IS NULL OR COALESCE(g.fecha_realizada, g.fecha_programada) < (p_hasta + 1)::timestamptz)
           AND (v_filtro IS NULL
                OR g.asunto    ILIKE '%' || v_filtro || '%'
                OR g.nota      ILIKE '%' || v_filtro || '%'
                OR g.telefono  ILIKE '%' || v_filtro || '%'
                OR g.resultado ILIKE '%' || v_filtro || '%')
         ORDER BY (g.estado = 'PENDIENTE') DESC,
                  COALESCE(g.fecha_realizada, g.fecha_programada) DESC,
                  g.id DESC
         LIMIT p_per_page OFFSET v_offset
      ) t;

    -- Quiénes han registrado gestiones de este cliente, para el desplegable
    SELECT COALESCE(jsonb_agg(x.quien ORDER BY x.quien), '[]'::jsonb) INTO v_registradores
      FROM (
        SELECT DISTINCT g.created_by AS quien
          FROM ventas.gestiones g
         WHERE (p_cliente_id IS NULL OR g.cliente_id = p_cliente_id)
           AND NULLIF(TRIM(COALESCE(g.created_by, '')), '') IS NOT NULL
      ) x;

    RETURN jsonb_build_object(
        'data', v_data,
        'meta', jsonb_build_object(
            'total',        v_total,
            'per_page',     p_per_page,
            'current_page', GREATEST(p_page, 1),
            'last_page',    CASE WHEN v_total = 0 THEN 1 ELSE ceil(v_total::numeric / p_per_page) END
        ),
        'filtros', jsonb_build_object('registradores', v_registradores)
    );
EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object('success', false, 'message', 'Error al listar las gestiones: ' || SQLERRM, 'error_code', SQLSTATE);
END;
$function$;

ALTER FUNCTION ventas.fn_gestiones_listar_paginado(bigint, integer, integer, text, varchar, varchar, date, date, varchar, varchar) OWNER TO postgres;
COMMENT ON FUNCTION ventas.fn_gestiones_listar_paginado(bigint, integer, integer, text, varchar, varchar, date, date, varchar, varchar)
    IS 'Gestiones paginadas de un cliente, con filtros de tipo, estado, resultado, quién la registró y rango de fechas';

-- Índices para los dos filtros nuevos. Parciales no: aquí se filtra siempre
-- junto al cliente, así que el índice compuesto es el que se usa.
CREATE INDEX IF NOT EXISTS ix_gestiones_cliente_resultado
    ON ventas.gestiones (cliente_id, resultado);
CREATE INDEX IF NOT EXISTS ix_gestiones_cliente_created_by
    ON ventas.gestiones (cliente_id, created_by);
