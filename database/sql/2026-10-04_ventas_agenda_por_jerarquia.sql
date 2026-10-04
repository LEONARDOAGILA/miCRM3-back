-- ============================================================================
-- LA AGENDA TAMBIÉN SE LIMITA POR JERARQUÍA
--
-- EL FALLO: en «Lo que toca hacer» el botón «Sólo lo mío / De todos» no era un
-- filtro, era un interruptor de permisos. Con «mías» el back pasaba el login y
-- la función filtraba por él; sin «mías» pasaba NULL y la función NO filtraba
-- NADA. Cualquier vendedor pulsando «De todos» veía los pendientes de toda la
-- empresa.
--
-- Y por la misma puerta se colaba otra cosa: ?usuario_id llegaba crudo desde la
-- URL, así que bastaba pedir ventas/gestion/agenda?usuario_id=46 para leerse la
-- agenda de otro, sin tocar el botón siquiera.
--
-- LA CAUSA: estas funciones sabían «de quién es la agenda que me piden», que
-- es un parámetro, pero no «quién la está pidiendo», que es una identidad. Sin
-- lo segundo no hay forma de poner un techo. Por eso entra p_solicitante.
--
-- EL ARREGLO, en una línea: nunca se devuelve nada de fuera del ámbito de quien
-- pregunta. El ámbito es el mismo que ya manda en la lista de clientes:
--   · grupo con es_administrador -> lo ve todo;
--   · el resto -> ventas.fn_usuarios_a_cargo(yo), o sea él y los de los grupos
--     POR DEBAJO del suyo (los de su mismo nivel no entran).
--
-- Con eso el botón se comporta como pedía Leonardo sin necesidad de mirar
-- perfiles: a un vendedor de un grupo hoja su ámbito es él solo, así que
-- «De todos» devuelve exactamente lo mismo que «Sólo lo mío». A un jefe zonal
-- le devuelve lo de su zona. Y el filtro ?usuario_id queda cerrado de paso:
-- pedir la agenda de alguien de fuera del ámbito ya no cruza ninguna fila.
--
-- meta.ve_de_otros dice si ese usuario manda sobre alguien más. Lo usa la
-- pantalla para no enseñar un botón que no haría nada. Es una pista para la
-- interfaz, no una defensa: el techo lo pone esta función, siempre.
--
-- OJO con p_solicitante NULL = sin restricción. Es la misma convención que
-- fn_clientes_listar_paginado y se deja para tareas internas, pero el
-- controlador lo manda SIEMPRE: todas las rutas van detrás de auth:api, así
-- que el id del que pregunta no puede faltar.
--
-- Cambia la firma de las dos funciones (un parámetro más), y añadir un
-- parámetro con DEFAULT crea una SOBRECARGA en vez de reemplazar: la llamada
-- de seis argumentos del back se volvería ambigua. Por eso se borran antes
-- todas las versiones.
--
-- Idempotente: se puede volver a correr.
-- ============================================================================


-- ---------------------------------------------------------------------------
-- Fuera las versiones anteriores, con la firma que tengan
-- ---------------------------------------------------------------------------
DO $drop$
DECLARE
    r record;
BEGIN
    FOR r IN
        SELECT p.oid::regprocedure AS firma
          FROM pg_proc p
          JOIN pg_namespace n ON n.oid = p.pronamespace
         WHERE n.nspname = 'ventas'
           AND p.proname IN ('fn_gestiones_agenda', 'fn_gestiones_agenda_paginado')
    LOOP
        EXECUTE 'DROP FUNCTION ' || r.firma;
    END LOOP;
END
$drop$;


-- ---------------------------------------------------------------------------
-- 1. La agenda completa (la que usa el recordatorio)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ventas.fn_gestiones_agenda(
    p_usuario_id     bigint  DEFAULT NULL,
    p_usuario_login  varchar DEFAULT NULL,
    p_desde          date    DEFAULT NULL,
    p_hasta          date    DEFAULT NULL,
    p_solo_vencidas  boolean DEFAULT false,
    p_limite         integer DEFAULT 200,
    p_solicitante    bigint  DEFAULT NULL
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

    v_ve_todo  boolean := false;
    v_ambito   bigint[] := '{}'::bigint[];
    v_yo       bigint;
BEGIN
    -- El techo se resuelve UNA vez, no por cada gestión
    IF p_solicitante IS NOT NULL THEN
        SELECT COALESCE(g.es_administrador, false) INTO v_ve_todo
          FROM seguridad.users u
          LEFT JOIN seguridad.grupos g ON g.id = u.grupo_id
         WHERE u.id = p_solicitante;

        IF NOT COALESCE(v_ve_todo, false) THEN
            v_ambito := ventas.fn_usuarios_a_cargo(p_solicitante);
        END IF;
    END IF;

    -- A quién corresponde «lo mío»; si el login no existe no cuadra con nadie
    -- y la agenda sale vacía, que es por donde hay que fallar
    IF p_usuario_login IS NOT NULL THEN
        SELECT u.id INTO v_yo
          FROM seguridad.users u
         WHERE UPPER(u.login_user) = UPPER(p_usuario_login) AND u.deleted_at IS NULL;
    END IF;

    -- 1. Los contadores salen del mismo filtro, sin el límite
    SELECT COUNT(*),
           COUNT(*) FILTER (WHERE g.fecha_programada < CURRENT_TIMESTAMP),
           COUNT(*) FILTER (WHERE g.fecha_programada::date = CURRENT_DATE)
      INTO v_total, v_vencidas, v_hoy
      FROM ventas.gestiones g
      JOIN ventas.clientes c ON c.id = g.cliente_id AND c.deleted_at IS NULL
     WHERE g.estado = 'PENDIENTE'
       -- El techo: nada de fuera del ámbito de quien pregunta
       AND (p_solicitante IS NULL OR v_ve_todo OR g.usuario_id = ANY(v_ambito))
       AND (p_usuario_id    IS NULL OR g.usuario_id = p_usuario_id)
       -- Lo que ME TOCA, no lo que yo registré: antes comparaba con created_by
       -- y por eso quien no registraba gestiones veía la agenda vacía aunque
       -- tuviera clientes asignados.
       AND (p_usuario_login IS NULL OR g.usuario_id = v_yo)
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
           AND (p_solicitante IS NULL OR v_ve_todo OR g.usuario_id = ANY(v_ambito))
           AND (p_usuario_id    IS NULL OR g.usuario_id = p_usuario_id)
           AND (p_usuario_login IS NULL OR g.usuario_id = v_yo)
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
            'mostradas', jsonb_array_length(v_data),
            -- Para que la pantalla no ofrezca un botón que no hace nada
            've_de_otros', v_ve_todo OR COALESCE(array_length(v_ambito, 1), 0) > 1
        )
    );
EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object('success', false, 'message', 'Error al obtener la agenda: ' || SQLERRM, 'error_code', SQLSTATE);
END;
$function$;

COMMENT ON FUNCTION ventas.fn_gestiones_agenda(bigint, varchar, date, date, boolean, integer, bigint)
    IS 'Lo pendiente. p_solicitante pone el techo: nunca devuelve nada de fuera de su jerarquía.';


-- ---------------------------------------------------------------------------
-- 2. La agenda en grilla, paginada y con buscador
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ventas.fn_gestiones_agenda_paginado(
    p_usuario_id     bigint  DEFAULT NULL,
    p_usuario_login  varchar DEFAULT NULL,
    p_desde          date    DEFAULT NULL,
    p_hasta          date    DEFAULT NULL,
    p_solo_vencidas  boolean DEFAULT false,
    p_search         text    DEFAULT ''::text,
    p_page           integer DEFAULT 1,
    p_per_page       integer DEFAULT 15,
    p_solicitante    bigint  DEFAULT NULL
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
    END IF;

    IF p_usuario_login IS NOT NULL THEN
        SELECT u.id INTO v_yo
          FROM seguridad.users u
         WHERE UPPER(u.login_user) = UPPER(p_usuario_login) AND u.deleted_at IS NULL;
    END IF;

    -- 1. Los contadores, sobre todo el filtro (no sobre la página)
    SELECT COUNT(*),
           COUNT(*) FILTER (WHERE g.fecha_programada < CURRENT_TIMESTAMP),
           COUNT(*) FILTER (WHERE g.fecha_programada::date = CURRENT_DATE)
      INTO v_total, v_vencidas, v_hoy
      FROM ventas.gestiones g
      JOIN ventas.clientes c ON c.id = g.cliente_id AND c.deleted_at IS NULL
     WHERE g.estado = 'PENDIENTE'
       -- El techo: nada de fuera del ámbito de quien pregunta
       AND (p_solicitante IS NULL OR v_ve_todo OR g.usuario_id = ANY(v_ambito))
       AND (p_usuario_id    IS NULL OR g.usuario_id = p_usuario_id)
       -- Lo que ME TOCA, no lo que yo registré: antes comparaba con created_by
       -- y por eso quien no registraba gestiones veía la agenda vacía aunque
       -- tuviera clientes asignados.
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
           AND (p_solicitante IS NULL OR v_ve_todo OR g.usuario_id = ANY(v_ambito))
           AND (p_usuario_id    IS NULL OR g.usuario_id = p_usuario_id)
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
            'mostradas',    jsonb_array_length(v_data),
            -- Para que la pantalla no ofrezca un botón que no hace nada
            've_de_otros',  v_ve_todo OR COALESCE(array_length(v_ambito, 1), 0) > 1
        )
    );
EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object('success', false, 'message', 'Error al obtener la agenda: ' || SQLERRM, 'error_code', SQLSTATE);
END;
$function$;

COMMENT ON FUNCTION ventas.fn_gestiones_agenda_paginado(bigint, varchar, date, date, boolean, text, integer, integer, bigint)
    IS 'Una página de lo pendiente. p_solicitante pone el techo: nunca devuelve nada de fuera de su jerarquía.';
