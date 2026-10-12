-- ===========================================================================
-- DOS AYUDAS PARA PREGUNTAR POR UNA SOLA FILA, Y EL WHATSAPP EN EL HISTORIAL
-- ===========================================================================
-- Fecha: 2026-10-08
-- Se aplica después de 2026-10-08_ventas_gestiones_filtradas_por_visibilidad.sql.
--
-- 1. seguridad.fn_puede_ver(usuario, dato, dueño) -> boolean
--    fn_usuarios_visibles sirve para filtrar listas; para una fila sola
--    —abrir una gestión por su id, servir un fichero— obliga a cada quien a
--    repetir el mismo «IS NULL OR = ANY», y es justo donde se olvida.
--
-- 2. ventas.fn_gestion_visible_para(gestion, usuario) -> boolean
--    Encierra una regla que si no se escribe una vez acaba escrita de tres
--    maneras distintas: UNA GESTIÓN IMPORTADA OBEDECE AL DATO «WHATSAPP», no
--    a «GESTION». Son gestiones normales con modo_registro = IMPORTADA, pero
--    lo que llevan dentro es una conversación, y el interruptor que el
--    administrador tocó para las conversaciones es el de WhatsApp.
--
-- 3. Y por eso se vuelve a crear fn_gestiones_listar_paginado: el fichero
--    anterior filtra TODO el historial por el dato GESTION, con lo que tapar
--    la pestaña de WhatsApp no servía de nada —la misma conversación seguía
--    leyéndose en la rejilla del Historial, que es donde está el texto—. Esta
--    versión reemplaza esa: hay que aplicar los dos ficheros y en este orden.
--
-- La firma no cambia, así que aquí no hace falta tirar nada antes.
--
-- Idempotente.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- 1. ¿Puede ver una fila de este dueño?
-- ---------------------------------------------------------------------------
-- Sin dueño (NULL) no la ve nadie que tenga filtro: de una fila de la que no
-- se sabe quién la hizo no se puede decidir si te toca.
CREATE OR REPLACE FUNCTION seguridad.fn_puede_ver(
    p_usuario_id bigint,
    p_dato       character varying,
    p_dueno_id   bigint
)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
AS $function$
DECLARE
    v_usuarios bigint[];
BEGIN
    v_usuarios := seguridad.fn_usuarios_visibles(p_usuario_id, p_dato);

    IF v_usuarios IS NULL THEN
        RETURN true;   -- alcance TODO
    END IF;

    RETURN p_dueno_id IS NOT NULL AND p_dueno_id = ANY(v_usuarios);
END;
$function$;

COMMENT ON FUNCTION seguridad.fn_puede_ver(bigint, character varying, bigint)
    IS 'Para una fila sola: ¿puede p_usuario_id ver un dato de p_dato cuyo dueño es p_dueno_id?';


-- ---------------------------------------------------------------------------
-- 2. ¿Puede ver esta gestión? (con la regla de las importadas)
-- ---------------------------------------------------------------------------
-- FALSE si la gestión no existe: quien pregunta por un id que no está no
-- tiene por qué distinguir «no existe» de «no es para ti».
CREATE OR REPLACE FUNCTION ventas.fn_gestion_visible_para(
    p_gestion_id bigint,
    p_usuario_id bigint
)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
AS $function$
DECLARE
    v_dueno bigint;
    v_modo  character varying;
BEGIN
    SELECT g.usuario_id, g.modo_registro
      INTO v_dueno, v_modo
      FROM ventas.gestiones g
     WHERE g.id = p_gestion_id;

    IF NOT FOUND THEN
        RETURN false;
    END IF;

    RETURN seguridad.fn_puede_ver(
        p_usuario_id,
        CASE WHEN v_modo = 'IMPORTADA' THEN 'WHATSAPP' ELSE 'GESTION' END,
        v_dueno
    );
END;
$function$;

COMMENT ON FUNCTION ventas.fn_gestion_visible_para(bigint, bigint)
    IS 'Si ese usuario puede ver esa gestión. Las importadas obedecen al dato WHATSAPP, el resto a GESTION';


-- ---------------------------------------------------------------------------
-- 3. El historial, con las importadas por su propio interruptor
-- ---------------------------------------------------------------------------
-- Las dos listas de usuarios se piden UNA vez y la elección se hace por fila
-- con un CASE, en vez de llamar a fn_gestion_visible_para en el WHERE: eso
-- sería una llamada por fila también en la consulta del total.
--
-- usuario_id NULL cae fuera en cuanto hay filtro: «= ANY(...)» con NULL da
-- NULL, y NULL no pasa el WHERE. Es lo que se quiere.
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
    v_gestiones     bigint[];
    v_whatsapp      bigint[];
BEGIN
    v_offset := (GREATEST(p_page, 1) - 1) * p_per_page;
    v_filtro := NULLIF(TRIM(COALESCE(p_search, '')), '');

    -- Una vez, no por fila. NULL = sin filtro (alcance TODO)
    v_gestiones := seguridad.fn_usuarios_visibles(p_usuario_id, 'GESTION');
    v_whatsapp  := seguridad.fn_usuarios_visibles(p_usuario_id, 'WHATSAPP');

    SELECT COUNT(*) INTO v_total
      FROM ventas.gestiones g
     WHERE g.cliente_id = p_cliente_id
       AND (CASE WHEN g.modo_registro = 'IMPORTADA'
                 THEN (v_whatsapp  IS NULL OR g.usuario_id = ANY(v_whatsapp))
                 ELSE (v_gestiones IS NULL OR g.usuario_id = ANY(v_gestiones))
            END)
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
           AND (CASE WHEN g.modo_registro = 'IMPORTADA'
                     THEN (v_whatsapp  IS NULL OR g.usuario_id = ANY(v_whatsapp))
                     ELSE (v_gestiones IS NULL OR g.usuario_id = ANY(v_gestiones))
                END)
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
           AND (CASE WHEN g.modo_registro = 'IMPORTADA'
                     THEN (v_whatsapp  IS NULL OR g.usuario_id = ANY(v_whatsapp))
                     ELSE (v_gestiones IS NULL OR g.usuario_id = ANY(v_gestiones))
                END)
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
-- Con la tabla de visibilidad vacía nadie deja de ver nada:
--
--   SELECT seguridad.fn_puede_ver(46, 'GESTION', 999)        AS da_true,
--          ventas.fn_gestion_visible_para(1437, 46)          AS da_true_tambien,
--          ventas.fn_gestion_visible_para(-1, 46)            AS da_false;
