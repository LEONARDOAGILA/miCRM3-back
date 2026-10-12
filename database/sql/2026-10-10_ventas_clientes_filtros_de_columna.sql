-- ===========================================================================
-- LOS FILTROS DE COLUMNA DE ag-Grid, TAMBIÉN EN LISTAR CLIENTES
-- ===========================================================================
-- Fecha: 2026-10-10
-- Se aplica después de 2026-10-10_seguridad_quien_puede_repartir.sql.
--
-- El mismo arreglo que ya tiene la pantalla de reparto: la rejilla de
-- Ventas > Clientes también pagina en el servidor, así que a ag-Grid sólo le
-- llegan las quince filas de la página y sus filtros de cabecera buscaban
-- dentro de quince. Escribir «Manta» y que salgan dos de mil es peor que no
-- tener filtro.
--
-- Ahora la cabecera sólo recoge lo que el usuario pidió y el filtrado se hace
-- aquí, sobre todos los clientes. El modelo llega en p_filtros:
--
--     {"canton":    {"op":"contains","valor":"manta"},
--      "estado":    {"op":"equals","valor":"activo"},
--      "descuento": {"op":"greaterThan","valor":0}}
--
-- La columna que no esté, no filtra.
--
-- SE REUSAN fn_filtro_texto y fn_filtro_numero, que ya existen desde el
-- arreglo de la pantalla de reparto. Los operadores se llaman igual que en
-- ag-Grid, no hay traducción por el camino, y van sin tildes ni mayúsculas.
--
-- NADA DE SQL DINÁMICO: las columnas filtrables están escritas una a una en
-- el WHERE. Y no se paga lo que no se usa, porque cada condición va detrás de
-- `p_filtros->'columna' IS NULL OR …`, que es constante en toda la consulta.
--
-- Cambia la firma, así que se suelta la función antes: CREATE OR REPLACE con
-- otros parámetros no reemplaza, crea una segunda con el mismo nombre.
--
-- Idempotente.
-- ===========================================================================

DROP FUNCTION IF EXISTS ventas.fn_clientes_listar_paginado(integer, integer, text, text, bigint);

CREATE OR REPLACE FUNCTION ventas.fn_clientes_listar_paginado(
    p_page       integer DEFAULT 1,
    p_per_page   integer DEFAULT 15,
    p_search     text    DEFAULT ''::text,
    p_estado     text    DEFAULT NULL,
    p_usuario_id bigint  DEFAULT NULL,
    -- Los filtros de la cabecera de ag-Grid, columna por columna
    p_filtros    jsonb   DEFAULT '{}'::jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'ventas', 'seguridad'
AS $function$
DECLARE
    v_offset   integer;
    v_total    bigint;
    v_data     jsonb;
    v_filtro   text;
    v_estado   text;
    v_ve_todo  boolean := false;
    v_usuarios bigint[] := '{}'::bigint[];
BEGIN
    v_offset := (GREATEST(p_page, 1) - 1) * GREATEST(p_per_page, 1);
    v_filtro := NULLIF(TRIM(COALESCE(p_search, '')), '');
    v_estado := NULLIF(TRIM(UPPER(COALESCE(p_estado, ''))), '');

    -- Se resuelve UNA vez, no por cada cliente
    IF p_usuario_id IS NOT NULL THEN
        SELECT COALESCE(g.es_administrador, false) INTO v_ve_todo
          FROM seguridad.users u
          LEFT JOIN seguridad.grupos g ON g.id = u.grupo_id
         WHERE u.id = p_usuario_id;

        IF NOT COALESCE(v_ve_todo, false) THEN
            v_usuarios := ventas.fn_usuarios_a_cargo(p_usuario_id);
        END IF;
    END IF;

    -- UNA sola sentencia: la cuenta y la página salen del mismo CTE, así no
    -- pueden discrepar. El nombre del vendedor se resuelve en la página —son
    -- quince filas—, salvo que se esté filtrando por él, que entonces hay que
    -- mirarlos todos; de eso se encarga el `IS NULL OR` de su condición.
    WITH base AS (
        SELECT c.*
          FROM ventas.clientes c
         WHERE c.deleted_at IS NULL
           AND (p_usuario_id IS NULL OR v_ve_todo OR ventas.fn_cliente_es_de_alguno(c.id, v_usuarios))
           AND (v_estado IS NULL OR c.estado = v_estado)
           AND (v_filtro IS NULL
            OR ventas.fn_sin_tildes(c.nombre_completo)       LIKE '%' || ventas.fn_sin_tildes(v_filtro) || '%'
            OR ventas.fn_sin_tildes(c.razon_social)          LIKE '%' || ventas.fn_sin_tildes(v_filtro) || '%'
            OR ventas.fn_sin_tildes(c.nombre_comercial)      LIKE '%' || ventas.fn_sin_tildes(v_filtro) || '%'
            OR ventas.fn_sin_tildes(c.numero_identificacion) LIKE '%' || ventas.fn_sin_tildes(v_filtro) || '%'
            OR ventas.fn_sin_tildes(c.email)                 LIKE '%' || ventas.fn_sin_tildes(v_filtro) || '%'
            OR ventas.fn_sin_tildes(c.celular)               LIKE '%' || ventas.fn_sin_tildes(v_filtro) || '%'
            OR ventas.fn_sin_tildes(c.telefono)              LIKE '%' || ventas.fn_sin_tildes(v_filtro) || '%'
            OR c.id::text                                    LIKE '%' || v_filtro || '%')
    ),
    -- Los filtros de la cabecera, uno por columna y escritos a mano
    filtrados AS (
        SELECT t.* FROM base t
         WHERE (p_filtros->'id'                    IS NULL OR ventas.fn_filtro_numero(t.id,                    p_filtros->'id'))
           AND (p_filtros->'limite_credito'        IS NULL OR ventas.fn_filtro_numero(t.limite_credito,        p_filtros->'limite_credito'))
           AND (p_filtros->'dias_credito'          IS NULL OR ventas.fn_filtro_numero(t.dias_credito,          p_filtros->'dias_credito'))
           AND (p_filtros->'descuento'             IS NULL OR ventas.fn_filtro_numero(t.descuento,             p_filtros->'descuento'))
           AND (p_filtros->'tipo_cliente'          IS NULL OR ventas.fn_filtro_texto(t.tipo_cliente,           p_filtros->'tipo_cliente'))
           -- El código Y el nombre: en la rejilla pone «Cédula» pero en la
           -- base dice «CC». Filtrando sólo por el código, escribir lo que se
           -- ve no encontraría nada; filtrando sólo por el nombre, no valdría
           -- escribir «CC». Se buscan los dos.
           AND (p_filtros->'tipo_identificacion'   IS NULL OR ventas.fn_filtro_texto(
                   t.tipo_identificacion || ' ' || CASE t.tipo_identificacion
                       WHEN 'CC'  THEN 'Cédula'
                       WHEN 'RUC' THEN 'RUC'
                       WHEN 'PAS' THEN 'Pasaporte'
                       ELSE ''
                   END,
                   p_filtros->'tipo_identificacion'))
           AND (p_filtros->'numero_identificacion' IS NULL OR ventas.fn_filtro_texto(t.numero_identificacion,  p_filtros->'numero_identificacion'))
           AND (p_filtros->'nombre_completo'       IS NULL OR ventas.fn_filtro_texto(t.nombre_completo,        p_filtros->'nombre_completo'))
           AND (p_filtros->'nombre_comercial'      IS NULL OR ventas.fn_filtro_texto(t.nombre_comercial,       p_filtros->'nombre_comercial'))
           AND (p_filtros->'email'                 IS NULL OR ventas.fn_filtro_texto(t.email,                  p_filtros->'email'))
           AND (p_filtros->'celular'               IS NULL OR ventas.fn_filtro_texto(t.celular,                p_filtros->'celular'))
           AND (p_filtros->'telefono'              IS NULL OR ventas.fn_filtro_texto(t.telefono,               p_filtros->'telefono'))
           AND (p_filtros->'direccion'             IS NULL OR ventas.fn_filtro_texto(t.direccion,              p_filtros->'direccion'))
           AND (p_filtros->'provincia'             IS NULL OR ventas.fn_filtro_texto(t.provincia,              p_filtros->'provincia'))
           AND (p_filtros->'canton'                IS NULL OR ventas.fn_filtro_texto(t.canton,                 p_filtros->'canton'))
           AND (p_filtros->'parroquia'             IS NULL OR ventas.fn_filtro_texto(t.parroquia,              p_filtros->'parroquia'))
           AND (p_filtros->'forma_pago'            IS NULL OR ventas.fn_filtro_texto(t.forma_pago,             p_filtros->'forma_pago'))
           AND (p_filtros->'estado'                IS NULL OR ventas.fn_filtro_texto(t.estado,                 p_filtros->'estado'))
           AND (p_filtros->'created_by'            IS NULL OR ventas.fn_filtro_texto(t.created_by,             p_filtros->'created_by'))
           AND (p_filtros->'updated_by'            IS NULL OR ventas.fn_filtro_texto(t.updated_by,             p_filtros->'updated_by'))
           AND (p_filtros->'vendedor_nombre'       IS NULL OR ventas.fn_filtro_texto(ventas.fn_nombre_usuario(t.vendedor_usuario_id), p_filtros->'vendedor_nombre'))
           -- Las fechas se filtran como texto sobre lo MISMO que se enseña en
           -- la rejilla, así buscar «2026-10» encuentra el mes y «2026-10-09»
           -- el día. Un filtro de fecha de verdad pediría otro control.
           AND (p_filtros->'created_at'            IS NULL OR ventas.fn_filtro_texto(to_char(t.created_at, 'YYYY-MM-DD HH24:MI:SS'), p_filtros->'created_at'))
           AND (p_filtros->'updated_at'            IS NULL OR ventas.fn_filtro_texto(to_char(t.updated_at, 'YYYY-MM-DD HH24:MI:SS'), p_filtros->'updated_at'))
    )
    SELECT
        (SELECT COUNT(*) FROM filtrados),
        (SELECT COALESCE(jsonb_agg(
            jsonb_build_object(
                'id',                    t.id,
                'tipo_cliente',          t.tipo_cliente,
                'numero_identificacion', t.numero_identificacion,
                'tipo_identificacion',   t.tipo_identificacion,
                'razon_social',          t.razon_social,
                'nombre_comercial',      t.nombre_comercial,
                'nombres',               t.nombres,
                'apellidos',             t.apellidos,
                'nombre_completo',       t.nombre_completo,
                'email',                 t.email,
                'telefono',              t.telefono,
                'celular',               t.celular,
                'direccion',             t.direccion,
                'provincia',             t.provincia,
                'canton',                t.canton,
                'parroquia',             t.parroquia,
                'vendedor_id',           t.vendedor_usuario_id,
                'vendedor_nombre',       ventas.fn_nombre_usuario(t.vendedor_usuario_id),
                'forma_pago',            t.forma_pago,
                'limite_credito',        t.limite_credito,
                'dias_credito',          t.dias_credito,
                'descuento',             t.descuento,
                'estado',                t.estado,
                'foto',                  t.foto,
                'activo',                t.activo,
                'created_by',            t.created_by,
                'updated_by',            t.updated_by,
                'created_at',            to_char(t.created_at, 'YYYY-MM-DD HH24:MI:SS'),
                'updated_at',            to_char(t.updated_at, 'YYYY-MM-DD HH24:MI:SS')
            ) ORDER BY t.id DESC), '[]'::jsonb)
           FROM (SELECT f.* FROM filtrados f ORDER BY f.id DESC
                  LIMIT GREATEST(p_per_page, 1) OFFSET v_offset) t)
      INTO v_total, v_data;

    RETURN jsonb_build_object(
        'data', v_data,
        'meta', jsonb_build_object(
            'total',        v_total,
            'per_page',     GREATEST(p_per_page, 1),
            'current_page', GREATEST(p_page, 1),
            'last_page',    CASE WHEN v_total = 0 THEN 1 ELSE ceil(v_total::numeric / GREATEST(p_per_page, 1)) END
        )
    );
EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object('success', false,
                                  'message', 'Error al listar clientes: ' || SQLERRM,
                                  'error_code', SQLSTATE);
END;
$function$;

COMMENT ON FUNCTION ventas.fn_clientes_listar_paginado(integer, integer, text, text, bigint, jsonb)
    IS 'Clientes paginados, con los filtros de columna de ag-Grid aplicados en el SERVIDOR';


-- ---------------------------------------------------------------------------
-- COMPROBACIÓN
-- ---------------------------------------------------------------------------
SELECT COUNT(*) AS versiones_de_la_funcion
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname = 'ventas' AND p.proname = 'fn_clientes_listar_paginado';

-- Sin filtros, y con uno de cabecera: «manta» sin tilde ni mayúscula
SELECT (ventas.fn_clientes_listar_paginado(1, 1, '', NULL, NULL, '{}'::jsonb) -> 'meta' ->> 'total') AS todos,
       (ventas.fn_clientes_listar_paginado(1, 1, '', NULL, NULL,
            '{"canton":{"op":"contains","valor":"manta"}}'::jsonb) -> 'meta' ->> 'total') AS de_manta,
       (ventas.fn_clientes_listar_paginado(1, 1, '', NULL, NULL,
            '{"vendedor_nombre":{"op":"blank"}}'::jsonb) -> 'meta' ->> 'total') AS sin_vendedor;
