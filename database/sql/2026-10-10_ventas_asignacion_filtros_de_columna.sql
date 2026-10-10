-- ===========================================================================
-- QUE LOS FILTROS DE LA CABECERA DE ag-Grid FILTREN DE VERDAD
-- ===========================================================================
-- Fecha: 2026-10-10
-- Se aplica después de 2026-10-10_ventas_asignacion_cuatro_responsables.sql.
--
-- EL PROBLEMA. La rejilla trae sus propios filtros en la cabecera, pero la
-- pantalla pagina en el servidor: a ag-Grid sólo le damos los 20 de la página,
-- así que esos filtros buscaban dentro de 20 filas y parecían rotos. Escribir
-- «Manta» y que salgan 3 de 1001 es peor que no tener filtro.
--
-- LA SOLUCIÓN. La cabecera deja de filtrar en el navegador y pasa a mandar lo
-- que el usuario pidió al servidor, que filtra sobre los 1001 y devuelve la
-- página que toca. El modelo de filtros de ag-Grid llega en p_filtros:
--
--     {"provincia":      {"op":"contains",  "valor":"manta"},
--      "vendedor_nombre":{"op":"blank"},
--      "pendientes":     {"op":"greaterThan","valor":0}}
--
-- La columna que no esté, no filtra.
--
-- NADA DE SQL DINÁMICO. Las columnas que se pueden filtrar están escritas una
-- a una en el WHERE: armar la condición concatenando el nombre que mande el
-- navegador sería abrir la puerta a que mande cualquier cosa. Si llega una
-- columna que no está en la lista, se ignora y ya.
--
-- Y NO SE PAGA LO QUE NO SE USA: cada condición va detrás de
-- `p_filtros->'columna' IS NULL OR …`, que es constante en toda la consulta y
-- el planificador resuelve una vez. Sin filtros puestos, esto no cuesta nada.
--
-- SIN TILDES Y SIN MAYÚSCULAS, como el buscador del historial: quien escribe
-- «manabi» quiere encontrar «Manabí».
--
-- Idempotente.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- 1. Los dos operadores
-- ---------------------------------------------------------------------------
-- En lenguaje SQL y no plpgsql a propósito: así el planificador puede meterlas
-- dentro de la consulta en vez de llamarlas fila por fila.

-- Texto. Los mismos nombres de operación que usa ag-Grid, para no tener que
-- traducirlos en el camino y que un día se traduzcan mal.
CREATE OR REPLACE FUNCTION ventas.fn_filtro_texto(p_valor text, p_filtro jsonb)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
AS $function$
    SELECT CASE p_filtro->>'op'
        WHEN 'blank'       THEN NULLIF(TRIM(COALESCE(p_valor, '')), '') IS NULL
        WHEN 'notBlank'    THEN NULLIF(TRIM(COALESCE(p_valor, '')), '') IS NOT NULL
        WHEN 'equals'      THEN ventas.fn_sin_tildes(COALESCE(p_valor, ''))  = ventas.fn_sin_tildes(COALESCE(p_filtro->>'valor', ''))
        WHEN 'notEqual'    THEN ventas.fn_sin_tildes(COALESCE(p_valor, '')) <> ventas.fn_sin_tildes(COALESCE(p_filtro->>'valor', ''))
        WHEN 'startsWith'  THEN ventas.fn_sin_tildes(COALESCE(p_valor, ''))     LIKE ventas.fn_sin_tildes(COALESCE(p_filtro->>'valor', '')) || '%'
        WHEN 'endsWith'    THEN ventas.fn_sin_tildes(COALESCE(p_valor, ''))     LIKE '%' || ventas.fn_sin_tildes(COALESCE(p_filtro->>'valor', ''))
        WHEN 'notContains' THEN ventas.fn_sin_tildes(COALESCE(p_valor, '')) NOT LIKE '%' || ventas.fn_sin_tildes(COALESCE(p_filtro->>'valor', '')) || '%'
        -- 'contains' y cualquier cosa que no se reconozca
        ELSE                    ventas.fn_sin_tildes(COALESCE(p_valor, ''))     LIKE '%' || ventas.fn_sin_tildes(COALESCE(p_filtro->>'valor', '')) || '%'
    END;
$function$;

COMMENT ON FUNCTION ventas.fn_filtro_texto(text, jsonb)
    IS 'Aplica un filtro de columna de texto de ag-Grid, sin tildes ni mayúsculas';

-- Números. inRange incluye los dos extremos, que es como lo pinta ag-Grid.
CREATE OR REPLACE FUNCTION ventas.fn_filtro_numero(p_valor numeric, p_filtro jsonb)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
AS $function$
    SELECT CASE p_filtro->>'op'
        WHEN 'blank'                 THEN p_valor IS NULL
        WHEN 'notBlank'              THEN p_valor IS NOT NULL
        WHEN 'notEqual'              THEN p_valor IS DISTINCT FROM (p_filtro->>'valor')::numeric
        WHEN 'lessThan'              THEN p_valor <  (p_filtro->>'valor')::numeric
        WHEN 'lessThanOrEqual'       THEN p_valor <= (p_filtro->>'valor')::numeric
        WHEN 'greaterThan'           THEN p_valor >  (p_filtro->>'valor')::numeric
        WHEN 'greaterThanOrEqual'    THEN p_valor >= (p_filtro->>'valor')::numeric
        WHEN 'inRange'               THEN p_valor BETWEEN (p_filtro->>'valor')::numeric AND (p_filtro->>'valor2')::numeric
        -- 'equals' y cualquier cosa que no se reconozca
        ELSE                              p_valor =  (p_filtro->>'valor')::numeric
    END;
$function$;

COMMENT ON FUNCTION ventas.fn_filtro_numero(numeric, jsonb)
    IS 'Aplica un filtro de columna numérico de ag-Grid; inRange incluye los extremos';


-- ---------------------------------------------------------------------------
-- 2. El listado, ahora con los filtros de columna
-- ---------------------------------------------------------------------------
-- Cambia la firma, así que se suelta antes: CREATE OR REPLACE con otros
-- parámetros no reemplaza, crea una segunda función con el mismo nombre.
DROP FUNCTION IF EXISTS ventas.fn_clientes_asignacion_listar(integer, integer, text, text, jsonb, text, text, text, boolean, bigint);

CREATE OR REPLACE FUNCTION ventas.fn_clientes_asignacion_listar(
    p_page       integer DEFAULT 1,
    p_per_page   integer DEFAULT 20,
    -- El buscador de arriba: mira además en correo, teléfono, dirección y
    -- razón social, que no son columnas de la rejilla
    p_search     text    DEFAULT ''::text,
    -- Los filtros de la cabecera de ag-Grid, columna por columna
    p_filtros    jsonb   DEFAULT '{}'::jsonb,
    p_usuario_id bigint  DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'ventas', 'seguridad'
AS $function$
DECLARE
    c_tope_ids constant integer := 5000;

    v_offset    integer;
    v_filtro    text;
    v_ve_todo   boolean := false;
    v_usuarios  bigint[] := '{}'::bigint[];
    v_total     bigint;
    v_data      jsonb;
    v_ids       jsonb;
    v_truncados boolean := false;
BEGIN
    v_offset := (GREATEST(p_page, 1) - 1) * GREATEST(p_per_page, 1);
    v_filtro := NULLIF(TRIM(COALESCE(p_search, '')), '');

    -- El mismo alcance que el listado normal de clientes, resuelto una vez.
    -- Repartir es cosa de administradores y para ellos esto no filtra nada,
    -- pero si mañana se abre a más gente no se enseñan carteras ajenas.
    IF p_usuario_id IS NOT NULL THEN
        SELECT COALESCE(g.es_administrador, false) INTO v_ve_todo
          FROM seguridad.users u
          LEFT JOIN seguridad.grupos g ON g.id = u.grupo_id
         WHERE u.id = p_usuario_id;

        IF NOT COALESCE(v_ve_todo, false) THEN
            v_usuarios := ventas.fn_usuarios_a_cargo(p_usuario_id);
        END IF;
    END IF;

    WITH base AS (
        SELECT c.id, c.nombre_completo, c.numero_identificacion, c.tipo_cliente,
               c.celular, c.estado, c.provincia, c.canton, c.parroquia,
               c.coordenadas, c.link_coordenadas,
               -- Los cuatro responsables. El vendedor vive en la ficha y los
               -- otros tres en la última asignación de su papel; esa
               -- diferencia la esconde fn_cliente_responsable_actual.
               ventas.fn_cliente_responsable_actual(c.id, 'VENDEDOR')  AS vendedor_id,
               ventas.fn_cliente_responsable_actual(c.id, 'COBRADOR')  AS cobrador_id,
               ventas.fn_cliente_responsable_actual(c.id, 'ASISTENTE') AS asistente_id,
               ventas.fn_cliente_responsable_actual(c.id, 'POSTVENTA') AS postventa_id
          FROM ventas.clientes c
         WHERE c.deleted_at IS NULL
           AND (p_usuario_id IS NULL OR v_ve_todo OR ventas.fn_cliente_es_de_alguno(c.id, v_usuarios))
           -- Sin tildes, igual que los filtros de columna. Con ILIKE a secas
           -- esta pantalla tenía dos comportamientos distintos: «agricola» no
           -- encontraba «AGRÍCOLA» aquí arriba y sí en la cabecera.
           AND (v_filtro IS NULL
            OR ventas.fn_sin_tildes(c.nombre_completo)       LIKE '%' || ventas.fn_sin_tildes(v_filtro) || '%'
            OR ventas.fn_sin_tildes(c.razon_social)          LIKE '%' || ventas.fn_sin_tildes(v_filtro) || '%'
            OR ventas.fn_sin_tildes(c.nombre_comercial)      LIKE '%' || ventas.fn_sin_tildes(v_filtro) || '%'
            OR ventas.fn_sin_tildes(c.numero_identificacion) LIKE '%' || ventas.fn_sin_tildes(v_filtro) || '%'
            OR ventas.fn_sin_tildes(c.email)                 LIKE '%' || ventas.fn_sin_tildes(v_filtro) || '%'
            OR ventas.fn_sin_tildes(c.celular)               LIKE '%' || ventas.fn_sin_tildes(v_filtro) || '%'
            OR ventas.fn_sin_tildes(c.telefono)              LIKE '%' || ventas.fn_sin_tildes(v_filtro) || '%'
            OR ventas.fn_sin_tildes(c.direccion)             LIKE '%' || ventas.fn_sin_tildes(v_filtro) || '%'
            OR c.id::text                                    LIKE '%' || v_filtro || '%')
    ),
    -- Los filtros de la cabecera, uno por columna y escritos a mano.
    --
    -- El `IS NULL OR` de delante no es sólo claridad: es constante en toda la
    -- consulta, el planificador lo resuelve una vez y, si esa columna no trae
    -- filtro, lo de la derecha NO SE EJECUTA NI UNA VEZ. Por eso el nombre
    -- del responsable y la cuenta de pendientes se piden aquí dentro y no en
    -- un paso anterior: calcularlos para los 1001 cuando nadie filtra por
    -- ellos costaba 127 ms de los que 70 sobraban.
    filtrados AS (
        SELECT t.* FROM base t
         WHERE (p_filtros->'id'                    IS NULL OR ventas.fn_filtro_numero(t.id,                   p_filtros->'id'))
           AND (p_filtros->'nombre_completo'       IS NULL OR ventas.fn_filtro_texto(t.nombre_completo,       p_filtros->'nombre_completo'))
           AND (p_filtros->'numero_identificacion' IS NULL OR ventas.fn_filtro_texto(t.numero_identificacion, p_filtros->'numero_identificacion'))
           AND (p_filtros->'provincia'             IS NULL OR ventas.fn_filtro_texto(t.provincia,             p_filtros->'provincia'))
           AND (p_filtros->'canton'                IS NULL OR ventas.fn_filtro_texto(t.canton,                p_filtros->'canton'))
           AND (p_filtros->'parroquia'             IS NULL OR ventas.fn_filtro_texto(t.parroquia,             p_filtros->'parroquia'))
           AND (p_filtros->'coordenadas'           IS NULL OR ventas.fn_filtro_texto(t.coordenadas,           p_filtros->'coordenadas'))
           AND (p_filtros->'estado'                IS NULL OR ventas.fn_filtro_texto(t.estado,                p_filtros->'estado'))
           AND (p_filtros->'vendedor_nombre'       IS NULL OR ventas.fn_filtro_texto(ventas.fn_nombre_usuario(t.vendedor_id),  p_filtros->'vendedor_nombre'))
           AND (p_filtros->'cobrador_nombre'       IS NULL OR ventas.fn_filtro_texto(ventas.fn_nombre_usuario(t.cobrador_id),  p_filtros->'cobrador_nombre'))
           AND (p_filtros->'asistente_nombre'      IS NULL OR ventas.fn_filtro_texto(ventas.fn_nombre_usuario(t.asistente_id), p_filtros->'asistente_nombre'))
           AND (p_filtros->'postventa_nombre'      IS NULL OR ventas.fn_filtro_texto(ventas.fn_nombre_usuario(t.postventa_id), p_filtros->'postventa_nombre'))
           AND (p_filtros->'pendientes'            IS NULL OR ventas.fn_filtro_numero(
                   (SELECT COUNT(*) FROM ventas.gestiones g WHERE g.cliente_id = t.id AND g.estado = 'PENDIENTE'),
                   p_filtros->'pendientes'))
    ),
    -- Y los nombres y los pendientes, sólo para las 20 filas que se enseñan
    pagina AS (
        SELECT f.*,
               ventas.fn_nombre_usuario(f.vendedor_id)  AS vendedor_nombre,
               ventas.fn_nombre_usuario(f.cobrador_id)  AS cobrador_nombre,
               ventas.fn_nombre_usuario(f.asistente_id) AS asistente_nombre,
               ventas.fn_nombre_usuario(f.postventa_id) AS postventa_nombre,
               (SELECT COUNT(*) FROM ventas.gestiones g
                 WHERE g.cliente_id = f.id AND g.estado = 'PENDIENTE') AS pendientes
          FROM filtrados f
         ORDER BY f.id DESC
         LIMIT GREATEST(p_per_page, 1) OFFSET v_offset
    )
    SELECT
        (SELECT COUNT(*) FROM filtrados),

        (SELECT COALESCE(jsonb_agg(
            jsonb_build_object(
                'id',                    t.id,
                'nombre_completo',       t.nombre_completo,
                'numero_identificacion', t.numero_identificacion,
                'tipo_cliente',          t.tipo_cliente,
                'celular',               t.celular,
                'estado',                t.estado,
                'provincia',             t.provincia,
                'canton',                t.canton,
                'parroquia',             t.parroquia,
                'coordenadas',           t.coordenadas,
                'link_coordenadas',      t.link_coordenadas,
                'vendedor_id',           t.vendedor_id,
                'vendedor_nombre',       t.vendedor_nombre,
                'cobrador_id',           t.cobrador_id,
                'cobrador_nombre',       t.cobrador_nombre,
                'asistente_id',          t.asistente_id,
                'asistente_nombre',      t.asistente_nombre,
                'postventa_id',          t.postventa_id,
                'postventa_nombre',      t.postventa_nombre,
                'pendientes',            t.pendientes
            ) ORDER BY t.id DESC), '[]'::jsonb)
           FROM pagina t),

        (SELECT COALESCE(jsonb_agg(z.id ORDER BY z.id DESC), '[]'::jsonb)
           FROM (SELECT f.id FROM filtrados f ORDER BY f.id DESC LIMIT c_tope_ids) z)

      INTO v_total, v_data, v_ids;

    v_truncados := v_total > c_tope_ids;

    RETURN jsonb_build_object(
        'success', true,
        'message', 'Clientes obtenidos exitosamente',
        'data', jsonb_build_object(
            'data', v_data,
            'meta', jsonb_build_object(
                'total',         v_total,
                'per_page',      GREATEST(p_per_page, 1),
                'current_page',  GREATEST(p_page, 1),
                'last_page',     CASE WHEN v_total = 0 THEN 1 ELSE ceil(v_total::numeric / GREATEST(p_per_page, 1)) END,
                'ids',           v_ids,
                'ids_truncados', v_truncados
            )
        )
    );
EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object('success', false,
                                  'message', 'Error al listar los clientes a repartir: ' || SQLERRM,
                                  'error_code', SQLSTATE);
END;
$function$;

COMMENT ON FUNCTION ventas.fn_clientes_asignacion_listar(integer, integer, text, jsonb, bigint)
    IS 'Clientes para el reparto, filtrados en el SERVIDOR con el modelo de filtros de columna de ag-Grid';


-- ---------------------------------------------------------------------------
-- COMPROBACIÓN
-- ---------------------------------------------------------------------------
SELECT COUNT(*) AS versiones_de_la_funcion
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname = 'ventas' AND p.proname = 'fn_clientes_asignacion_listar';

-- Lo que antes necesitaba cuatro controles distintos, ahora en un solo modelo:
-- de Manta («manta» sin tilde ni mayúscula), sin vendedor y con algo pendiente
SELECT (ventas.fn_clientes_asignacion_listar(
            1, 1, '',
            '{"canton":          {"op":"contains",   "valor":"manta"},
              "vendedor_nombre": {"op":"blank"},
              "pendientes":      {"op":"greaterThan","valor":0}}'::jsonb,
            (SELECT id FROM seguridad.users WHERE login_user = 'LAGILA')
        ) -> 'data' -> 'meta' ->> 'total') AS manta_sin_vendedor_con_pendientes;
