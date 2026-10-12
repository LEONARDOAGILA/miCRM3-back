-- ===========================================================================
-- NOTAS, ARCHIVOS, CONVERSACIONES Y CONTADORES, FILTRADOS POR VISIBILIDAD
-- ===========================================================================
-- Fecha: 2026-10-08
-- Se aplica después de 2026-10-08_seguridad_puede_ver_y_whatsapp.sql.
--
-- El historial ya pregunta quién mira. Aquí lo hacen las otras cuatro puertas
-- por las que se entra a lo mismo:
--
--   fn_notas_clientes_listar      la pestaña Notas            -> dato NOTA
--   fn_archivos_clientes_listar   la pestaña Archivos         -> dato ARCHIVO
--   fn_gestiones_importadas       la pestaña WhatsApp         -> dato WHATSAPP
--   fn_gestiones_resumen          las cifras de la cabecera   -> GESTION/WHATSAPP
--
-- LOS ADJUNTOS DE UNA GESTIÓN NO SE FILTRAN POR «ARCHIVO», sino por si la
-- gestión se ve. Un adjunto colgado de una gestión es parte de ella, no un
-- documento del cliente: si se ve la gestión se ven sus adjuntos, y si no se
-- ve la gestión no se ve ninguno. Filtrarlos por quién subió el fichero daría
-- el peor resultado posible —el clip visible en una gestión visible abriendo
-- un modal vacío— y además num_adjuntos, que los cuenta todos, diría dos
-- mientras el modal enseña cero.
--
-- EL RESUMEN TAMBIÉN. Son las cifras de la cabecera del cliente y el «última
-- gestión», que trae la gestión entera: nota incluida. Un contador que cuenta
-- lo que no se deja leer es la forma más tonta de contar en voz alta lo que se
-- acaba de tapar; y «última» era, directamente, una fuga del texto.
--
-- SIN USUARIO NO SE VE NADA, igual que en el historial: el parámetro va al
-- final y con default para que nada reviente, pero una llamada que no dice
-- quién pregunta se queda sin filas. Los controladores se actualizan en el
-- mismo paso.
--
-- SOBRECARGA: las tres primeras cambian de firma, así que hay que tirarlas
-- antes. CREATE OR REPLACE con otra firma no reemplaza: añade.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- Fuera las versiones que no reciben p_usuario_id
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    v_nombre text;
    v_firma  text;
BEGIN
    FOREACH v_nombre IN ARRAY ARRAY['fn_notas_clientes_listar',
                                    'fn_archivos_clientes_listar',
                                    'fn_gestiones_importadas',
                                    'fn_gestiones_resumen'] LOOP
        FOR v_firma IN
            SELECT 'ventas.' || p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')'
              FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
             WHERE n.nspname = 'ventas' AND p.proname = v_nombre
        LOOP
            EXECUTE 'DROP FUNCTION IF EXISTS ' || v_firma;
            RAISE NOTICE 'tirada %', v_firma;
        END LOOP;
    END LOOP;
END;
$$;


-- ---------------------------------------------------------------------------
-- 1. Las notas del cliente
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ventas.fn_notas_clientes_listar(
    p_cliente_id bigint,
    p_busca      character varying DEFAULT NULL::character varying,
    p_usuario_id bigint DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'ventas'
AS $function$
DECLARE
    v_data     jsonb;
    v_usuarios bigint[];
    v_patron   text := CASE WHEN NULLIF(TRIM(COALESCE(p_busca, '')), '') IS NULL
                            THEN NULL ELSE '%' || lower(TRIM(p_busca)) || '%' END;
BEGIN
    v_usuarios := seguridad.fn_usuarios_visibles(p_usuario_id, 'NOTA');

    SELECT COALESCE(jsonb_agg(ventas.fn_notas_clientes_json(n.id)
                              ORDER BY n.fijada DESC, n.updated_at DESC), '[]'::jsonb) INTO v_data
      FROM ventas.notas_clientes n
     WHERE n.cliente_id = p_cliente_id
       AND (v_usuarios IS NULL OR n.usuario_id = ANY(v_usuarios))
       AND (v_patron IS NULL
            OR lower(n.titulo) LIKE v_patron
            OR lower(COALESCE(n.contenido_texto, '')) LIKE v_patron);

    RETURN jsonb_build_object('success', true, 'message', 'Notas obtenidas exitosamente', 'data', v_data);
END;
$function$;


-- ---------------------------------------------------------------------------
-- 2. Los archivos del cliente, y los adjuntos de una gestión
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ventas.fn_archivos_clientes_listar(
    p_cliente_id        bigint,
    p_incluir_inactivos boolean           DEFAULT true,
    p_origen            character varying DEFAULT 'archivo'::character varying,
    p_gestion_id        bigint            DEFAULT NULL::bigint,
    p_usuario_id        bigint            DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'ventas'
AS $function$
DECLARE
    v_data     jsonb;
    v_usuarios bigint[];
    v_origen   varchar := NULLIF(TRIM(COALESCE(p_origen, '')), '');
BEGIN
    IF p_gestion_id IS NOT NULL THEN
        -- Manda la gestión, no quién subió el fichero
        IF NOT ventas.fn_gestion_visible_para(p_gestion_id, p_usuario_id) THEN
            RETURN jsonb_build_object('success', true,
                                      'message', 'Archivos obtenidos exitosamente',
                                      'data', '[]'::jsonb);
        END IF;

        SELECT COALESCE(jsonb_agg(ventas.fn_archivos_clientes_json(a.id)
                                  ORDER BY a.orden, a.id), '[]'::jsonb) INTO v_data
          FROM ventas.archivos_clientes a
         WHERE a.gestion_id = p_gestion_id
           AND (p_incluir_inactivos OR a.activo);
    ELSE
        v_usuarios := seguridad.fn_usuarios_visibles(p_usuario_id, 'ARCHIVO');

        SELECT COALESCE(jsonb_agg(ventas.fn_archivos_clientes_json(a.id)
                                  ORDER BY a.orden, a.id), '[]'::jsonb) INTO v_data
          FROM ventas.archivos_clientes a
         WHERE a.cliente_id = p_cliente_id
           AND (v_usuarios IS NULL OR a.usuario_id = ANY(v_usuarios))
           AND (p_incluir_inactivos OR a.activo)
           AND (v_origen IS NULL OR a.origen = v_origen);
    END IF;

    RETURN jsonb_build_object('success', true, 'message', 'Archivos obtenidos exitosamente', 'data', v_data);
END;
$function$;


-- ---------------------------------------------------------------------------
-- 3. Las conversaciones importadas
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ventas.fn_gestiones_importadas(
    p_cliente_id bigint,
    p_usuario_id bigint DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
    v_data     jsonb;
    v_usuarios bigint[];
BEGIN
    v_usuarios := seguridad.fn_usuarios_visibles(p_usuario_id, 'WHATSAPP');

    SELECT COALESCE(jsonb_agg(ventas.fn_gestiones_json(t.id) ORDER BY t.orden), '[]'::jsonb)
      INTO v_data
      FROM (
        SELECT g.id,
               ROW_NUMBER() OVER (ORDER BY COALESCE(g.fecha_realizada, g.created_at) DESC,
                                           g.id DESC) AS orden
          FROM ventas.gestiones g
         WHERE g.cliente_id    = p_cliente_id
           AND g.modo_registro = 'IMPORTADA'
           AND (v_usuarios IS NULL OR g.usuario_id = ANY(v_usuarios))
      ) t;

    RETURN jsonb_build_object('success', true,
                              'message', 'Conversaciones importadas obtenidas exitosamente',
                              'data', v_data);
EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object('success', false,
                                  'message', 'Error al obtener las conversaciones importadas: ' || SQLERRM,
                                  'error_code', SQLSTATE);
END;
$function$;


-- ---------------------------------------------------------------------------
-- 4. Las cifras de la cabecera
-- ---------------------------------------------------------------------------
-- El filtro se repite cuatro veces —el bloque de contadores y las dos
-- subconsultas— porque son cuatro consultas distintas sobre la misma tabla.
CREATE OR REPLACE FUNCTION ventas.fn_gestiones_resumen(
    p_cliente_id bigint,
    p_usuario_id bigint DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
    v_data      jsonb;
    v_gestiones bigint[];
    v_whatsapp  bigint[];
BEGIN
    v_gestiones := seguridad.fn_usuarios_visibles(p_usuario_id, 'GESTION');
    v_whatsapp  := seguridad.fn_usuarios_visibles(p_usuario_id, 'WHATSAPP');

    SELECT jsonb_build_object(
        'cliente_id',    p_cliente_id,
        'total',         COUNT(*),
        'realizadas',    COUNT(*) FILTER (WHERE g.estado = 'REALIZADA'),
        'pendientes',    COUNT(*) FILTER (WHERE g.estado = 'PENDIENTE'),
        'vencidas',      COUNT(*) FILTER (WHERE g.estado = 'PENDIENTE' AND g.fecha_programada < CURRENT_TIMESTAMP),
        'canceladas',    COUNT(*) FILTER (WHERE g.estado = 'CANCELADA'),
        'llamadas',      COUNT(*) FILTER (WHERE g.tipo = 'LLAMADA' AND g.estado = 'REALIZADA'),
        'minutos',       COALESCE(SUM(g.duracion_minutos) FILTER (WHERE g.estado = 'REALIZADA'), 0),
        'ultima',        (SELECT ventas.fn_gestiones_json(u.id) FROM ventas.gestiones u
                           WHERE u.cliente_id = p_cliente_id AND u.estado = 'REALIZADA'
                             AND (CASE WHEN u.modo_registro = 'IMPORTADA'
                                       THEN (v_whatsapp  IS NULL OR u.usuario_id = ANY(v_whatsapp))
                                       ELSE (v_gestiones IS NULL OR u.usuario_id = ANY(v_gestiones))
                                  END)
                           ORDER BY u.fecha_realizada DESC NULLS LAST, u.id DESC LIMIT 1),
        'proxima',       (SELECT ventas.fn_gestiones_json(n.id) FROM ventas.gestiones n
                           WHERE n.cliente_id = p_cliente_id AND n.estado = 'PENDIENTE'
                             AND (CASE WHEN n.modo_registro = 'IMPORTADA'
                                       THEN (v_whatsapp  IS NULL OR n.usuario_id = ANY(v_whatsapp))
                                       ELSE (v_gestiones IS NULL OR n.usuario_id = ANY(v_gestiones))
                                  END)
                           ORDER BY n.fecha_programada ASC, n.id ASC LIMIT 1)
    ) INTO v_data
    FROM ventas.gestiones g
    WHERE g.cliente_id = p_cliente_id
      AND (CASE WHEN g.modo_registro = 'IMPORTADA'
                THEN (v_whatsapp  IS NULL OR g.usuario_id = ANY(v_whatsapp))
                ELSE (v_gestiones IS NULL OR g.usuario_id = ANY(v_gestiones))
           END);

    RETURN jsonb_build_object('success', true, 'message', 'Resumen obtenido exitosamente', 'data', v_data);
EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object('success', false, 'message', 'Error al obtener el resumen: ' || SQLERRM, 'error_code', SQLSTATE);
END;
$function$;


-- ---------------------------------------------------------------------------
-- COMPROBACIÓN
-- ---------------------------------------------------------------------------
-- Con la tabla de visibilidad vacía, lo de siempre:
--
--   SELECT jsonb_array_length(ventas.fn_notas_clientes_listar(1055, NULL, 46) -> 'data')   AS notas,
--          jsonb_array_length(ventas.fn_archivos_clientes_listar(1055, true, 'archivo', NULL, 46) -> 'data') AS archivos,
--          (ventas.fn_gestiones_resumen(1055, 46) -> 'data' ->> 'total')::int              AS total;
