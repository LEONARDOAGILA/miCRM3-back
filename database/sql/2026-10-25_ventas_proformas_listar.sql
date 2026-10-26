-- ===========================================================================
-- PROFORMAS · LEER
-- ===========================================================================
-- El listado paginado con los filtros por columna, la papelera, el documento
-- suelto y el contador por estado que la pantalla enseña arriba.
--
-- EL ALCANCE: quien no es administrador ve las proformas de los vendedores
-- que tiene a cargo (ventas.fn_usuarios_a_cargo), igual que en clientes. Se
-- mira el VENDEDOR de la proforma, no quién la escribió: si un supervisor
-- hace una proforma para un vendedor de su equipo, es del vendedor.
\set ON_ERROR_STOP on

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. UNA PROFORMA
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ventas.fn_proformas_obtener(p_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'pg_catalog', 'ventas'
AS $fn$
DECLARE
    v_data jsonb;
BEGIN
    v_data := ventas.fn_proformas_json(p_id);

    IF v_data IS NULL THEN
        RETURN jsonb_build_object('success', false, 'message', 'La proforma no existe', 'error_code', 'P0016');
    END IF;

    RETURN jsonb_build_object('success', true, 'data', v_data);
EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object('success', false,
                                  'message', 'Error al obtener la proforma: ' || SQLERRM,
                                  'error_code', SQLSTATE);
END;
$fn$;

-- ---------------------------------------------------------------------------
-- 2. EL LISTADO
-- ---------------------------------------------------------------------------
-- La cuenta y la página salen del MISMO CTE, así no pueden discrepar. El
-- detalle no viene: en la rejilla sólo se ven los totales y cuántas líneas
-- tiene cada una; el documento completo se pide al abrirlo.
CREATE OR REPLACE FUNCTION ventas.fn_proformas_listar_paginado(
    p_page       integer DEFAULT 1,
    p_per_page   integer DEFAULT 15,
    p_search     text    DEFAULT ''::text,
    p_estado     text    DEFAULT NULL::text,
    p_usuario_id bigint  DEFAULT NULL::bigint,
    p_filtros    jsonb   DEFAULT '{}'::jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'pg_catalog', 'ventas', 'seguridad'
AS $fn$
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
        SELECT p.*,
               ventas.fn_nombre_usuario(p.vendedor_usuario_id)   AS vendedor_nombre,
               ventas.fn_proformas_estado_etiqueta(p.estado)     AS estado_etiqueta,
               (SELECT COUNT(*) FROM ventas.proformas_detalle d WHERE d.proforma_id = p.id) AS lineas
          FROM ventas.proformas p
         WHERE p.deleted_at IS NULL
           AND (p_usuario_id IS NULL OR v_ve_todo OR p.vendedor_usuario_id = ANY(v_usuarios))
           AND (v_estado IS NULL OR p.estado = v_estado)
           AND (v_filtro IS NULL
            OR ventas.fn_sin_tildes(p.numero)                 LIKE '%' || ventas.fn_sin_tildes(v_filtro) || '%'
            OR ventas.fn_sin_tildes(p.cliente_nombre)         LIKE '%' || ventas.fn_sin_tildes(v_filtro) || '%'
            OR ventas.fn_sin_tildes(p.cliente_identificacion) LIKE '%' || ventas.fn_sin_tildes(v_filtro) || '%'
            OR ventas.fn_sin_tildes(p.observaciones)          LIKE '%' || ventas.fn_sin_tildes(v_filtro) || '%'
            OR p.id::text                                     LIKE '%' || v_filtro || '%'
            -- También por lo que hay dentro: buscar «laptop» tiene que sacar
            -- las proformas donde se cotizó una laptop
            OR EXISTS (SELECT 1 FROM ventas.proformas_detalle d
                        WHERE d.proforma_id = p.id
                          AND (ventas.fn_sin_tildes(d.descripcion) LIKE '%' || ventas.fn_sin_tildes(v_filtro) || '%'
                            OR ventas.fn_sin_tildes(d.codigo)      LIKE '%' || ventas.fn_sin_tildes(v_filtro) || '%')))
    ),
    filtrados AS (
        SELECT t.* FROM base t
         WHERE (p_filtros->'id'                     IS NULL OR ventas.fn_filtro_numero(t.id,                   p_filtros->'id'))
           AND (p_filtros->'numero'                 IS NULL OR ventas.fn_filtro_texto(t.numero,                p_filtros->'numero'))
           AND (p_filtros->'cliente_nombre'         IS NULL OR ventas.fn_filtro_texto(t.cliente_nombre,        p_filtros->'cliente_nombre'))
           AND (p_filtros->'cliente_identificacion' IS NULL OR ventas.fn_filtro_texto(t.cliente_identificacion,p_filtros->'cliente_identificacion'))
           AND (p_filtros->'vendedor_nombre'        IS NULL OR ventas.fn_filtro_texto(t.vendedor_nombre,       p_filtros->'vendedor_nombre'))
           -- El código y la etiqueta a la vez: en la rejilla pone «Enviada»
           -- pero en la base dice «ENVIADA», y hay que poder escribir las dos
           AND (p_filtros->'estado'                 IS NULL OR ventas.fn_filtro_texto(t.estado || ' ' || t.estado_etiqueta, p_filtros->'estado'))
           AND (p_filtros->'forma_pago'             IS NULL OR ventas.fn_filtro_texto(t.forma_pago,            p_filtros->'forma_pago'))
           AND (p_filtros->'observaciones'          IS NULL OR ventas.fn_filtro_texto(t.observaciones,         p_filtros->'observaciones'))
           AND (p_filtros->'created_by'             IS NULL OR ventas.fn_filtro_texto(t.created_by,            p_filtros->'created_by'))
           AND (p_filtros->'updated_by'             IS NULL OR ventas.fn_filtro_texto(t.updated_by,            p_filtros->'updated_by'))
           AND (p_filtros->'lineas'                 IS NULL OR ventas.fn_filtro_numero(t.lineas,               p_filtros->'lineas'))
           AND (p_filtros->'validez_dias'           IS NULL OR ventas.fn_filtro_numero(t.validez_dias,         p_filtros->'validez_dias'))
           AND (p_filtros->'dias_credito'           IS NULL OR ventas.fn_filtro_numero(t.dias_credito,         p_filtros->'dias_credito'))
           AND (p_filtros->'descuento_porcentaje'   IS NULL OR ventas.fn_filtro_numero(t.descuento_porcentaje, p_filtros->'descuento_porcentaje'))
           AND (p_filtros->'subtotal'               IS NULL OR ventas.fn_filtro_numero(t.subtotal,             p_filtros->'subtotal'))
           AND (p_filtros->'descuento_total'        IS NULL OR ventas.fn_filtro_numero(t.descuento_total,      p_filtros->'descuento_total'))
           AND (p_filtros->'iva_total'              IS NULL OR ventas.fn_filtro_numero(t.iva_total,            p_filtros->'iva_total'))
           AND (p_filtros->'total'                  IS NULL OR ventas.fn_filtro_numero(t.total,                p_filtros->'total'))
           -- Las fechas se filtran como texto sobre lo MISMO que se enseña,
           -- así «2026-10» encuentra el mes y «2026-10-25» el día
           AND (p_filtros->'fecha'                  IS NULL OR ventas.fn_filtro_texto(to_char(t.fecha,       'YYYY-MM-DD'), p_filtros->'fecha'))
           AND (p_filtros->'fecha_vence'            IS NULL OR ventas.fn_filtro_texto(to_char(t.fecha_vence, 'YYYY-MM-DD'), p_filtros->'fecha_vence'))
           AND (p_filtros->'created_at'             IS NULL OR ventas.fn_filtro_texto(to_char(t.created_at, 'YYYY-MM-DD HH24:MI:SS'), p_filtros->'created_at'))
           AND (p_filtros->'updated_at'             IS NULL OR ventas.fn_filtro_texto(to_char(t.updated_at, 'YYYY-MM-DD HH24:MI:SS'), p_filtros->'updated_at'))
    )
    SELECT
        (SELECT COUNT(*) FROM filtrados),
        (SELECT COALESCE(jsonb_agg(
            jsonb_build_object(
                'id',                     t.id,
                'numero',                 t.numero,
                'fecha',                  to_char(t.fecha, 'YYYY-MM-DD'),
                'validez_dias',           t.validez_dias,
                'fecha_vence',            to_char(t.fecha_vence, 'YYYY-MM-DD'),
                'cliente_id',             t.cliente_id,
                'cliente_identificacion', t.cliente_identificacion,
                'cliente_nombre',         t.cliente_nombre,
                'vendedor_usuario_id',    t.vendedor_usuario_id,
                'vendedor_nombre',        t.vendedor_nombre,
                'estado',                 t.estado,
                'estado_etiqueta',        t.estado_etiqueta,
                'vencida',                (t.estado = 'ENVIADA' AND t.fecha_vence < CURRENT_DATE),
                'dias_para_vencer',       (t.fecha_vence - CURRENT_DATE),
                'puede_editarse',         (t.estado IN ('BORRADOR', 'ENVIADA')),
                'forma_pago',             t.forma_pago,
                'dias_credito',           t.dias_credito,
                'descuento_porcentaje',   t.descuento_porcentaje,
                'moneda',                 t.moneda,
                'lineas',                 t.lineas,
                'subtotal',               t.subtotal,
                'descuento_total',        t.descuento_total,
                'iva_total',              t.iva_total,
                'total',                  t.total,
                'observaciones',          t.observaciones,
                'created_by',             t.created_by,
                'updated_by',             t.updated_by,
                'created_at',             to_char(t.created_at, 'YYYY-MM-DD HH24:MI:SS'),
                'updated_at',             to_char(t.updated_at, 'YYYY-MM-DD HH24:MI:SS')
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
                                  'message', 'Error al listar proformas: ' || SQLERRM,
                                  'error_code', SQLSTATE);
END;
$fn$;

-- ---------------------------------------------------------------------------
-- 3. LA PAPELERA
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ventas.fn_proformas_papelera_listar()
RETURNS jsonb
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO 'pg_catalog', 'ventas'
AS $fn$
    SELECT COALESCE(jsonb_agg(
        jsonb_build_object(
            'id',             p.id,
            'numero',         p.numero,
            'fecha',          to_char(p.fecha, 'YYYY-MM-DD'),
            'cliente_nombre', p.cliente_nombre,
            'estado',         p.estado,
            'estado_etiqueta', ventas.fn_proformas_estado_etiqueta(p.estado),
            'total',          p.total,
            'lineas',         (SELECT COUNT(*) FROM ventas.proformas_detalle d WHERE d.proforma_id = p.id),
            'deleted_at',     to_char(p.deleted_at, 'YYYY-MM-DD HH24:MI:SS'),
            'deleted_by',     p.deleted_by
        ) ORDER BY p.deleted_at DESC), '[]'::jsonb)
      FROM ventas.proformas p
     WHERE p.deleted_at IS NOT NULL;
$fn$;

-- ---------------------------------------------------------------------------
-- 4. EL CONTADOR DE ARRIBA
-- ---------------------------------------------------------------------------
-- Cuántas hay en cada estado y cuánto suman, con el mismo alcance que el
-- listado. Es lo que da sentido a la pantalla de un vendedor: lo que tiene
-- pendiente de respuesta y lo que se le está venciendo.
CREATE OR REPLACE FUNCTION ventas.fn_proformas_resumen(p_usuario_id bigint DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'pg_catalog', 'ventas', 'seguridad'
AS $fn$
DECLARE
    v_ve_todo  boolean := false;
    v_usuarios bigint[] := '{}'::bigint[];
    v_data     jsonb;
BEGIN
    IF p_usuario_id IS NOT NULL THEN
        SELECT COALESCE(g.es_administrador, false) INTO v_ve_todo
          FROM seguridad.users u
          LEFT JOIN seguridad.grupos g ON g.id = u.grupo_id
         WHERE u.id = p_usuario_id;

        IF NOT COALESCE(v_ve_todo, false) THEN
            v_usuarios := ventas.fn_usuarios_a_cargo(p_usuario_id);
        END IF;
    END IF;

    WITH mias AS (
        SELECT p.* FROM ventas.proformas p
         WHERE p.deleted_at IS NULL
           AND (p_usuario_id IS NULL OR v_ve_todo OR p.vendedor_usuario_id = ANY(v_usuarios))
    )
    SELECT jsonb_build_object(
        'total',    (SELECT COUNT(*) FROM mias),
        'importe',  (SELECT COALESCE(SUM(total), 0) FROM mias),
        'por_estado', COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
                       'estado',    x.estado,
                       'etiqueta',  ventas.fn_proformas_estado_etiqueta(x.estado),
                       'cuantas',   x.cuantas,
                       'importe',   x.importe
                   ) ORDER BY x.estado)
              FROM (SELECT estado, COUNT(*) AS cuantas, COALESCE(SUM(total), 0) AS importe
                      FROM mias GROUP BY estado) x), '[]'::jsonb),
        -- Enviadas que ya pasaron de fecha: la lista a la que hay que llamar
        'vencidas', (SELECT COUNT(*) FROM mias WHERE estado = 'ENVIADA' AND fecha_vence <  CURRENT_DATE),
        -- Y las que se vencen esta semana, que es cuando todavía sirve llamar
        'por_vencer', (SELECT COUNT(*) FROM mias
                        WHERE estado = 'ENVIADA'
                          AND fecha_vence >= CURRENT_DATE
                          AND fecha_vence <  CURRENT_DATE + 7)
    ) INTO v_data;

    RETURN jsonb_build_object('success', true, 'data', v_data);
END;
$fn$;

COMMIT;
