-- ============================================================================
-- CLIENTES: filtrar la lista por estado
--
-- La pantalla de gestión de clientes tiene el buscador a la izquierda sobre una
-- lista de mil y pico clientes paginada EN EL SERVIDOR. Filtrar por estado en el
-- navegador sólo filtraría la página que se está viendo —quince filas de mil—,
-- así que el filtro tiene que llegar hasta aquí.
--
-- fn_clientes_listar_paginado gana un cuarto parámetro, p_estado.
--
-- OJO con el CREATE OR REPLACE: cambiar la firma NO reemplaza la función, crea
-- una SOBRECARGA. Con las dos vivas, la llamada de tres argumentos que hace hoy
-- el back se volvería ambigua («function is not unique») y la lista de clientes
-- dejaría de cargar en toda la aplicación. Por eso se borran primero todas las
-- versiones por pg_proc, que es la única forma de no dejarse una.
--
-- Idempotente: se puede volver a correr.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- Fuera todas las versiones anteriores, tengan la firma que tengan
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    v_firma text;
BEGIN
    FOR v_firma IN
        SELECT 'ventas.fn_clientes_listar_paginado(' || pg_get_function_identity_arguments(p.oid) || ')'
          FROM pg_proc p
          JOIN pg_namespace n ON n.oid = p.pronamespace
         WHERE n.nspname = 'ventas'
           AND p.proname = 'fn_clientes_listar_paginado'
    LOOP
        EXECUTE 'DROP FUNCTION IF EXISTS ' || v_firma;
        RAISE NOTICE 'Borrada %', v_firma;
    END LOOP;
END
$$;

-- ---------------------------------------------------------------------------
-- La lista paginada, ahora con estado
-- ---------------------------------------------------------------------------
CREATE FUNCTION ventas.fn_clientes_listar_paginado(
    p_page     integer DEFAULT 1,
    p_per_page integer DEFAULT 15,
    p_search   text    DEFAULT '',
    -- NULL o vacío = todos. No se valida contra la lista de estados a
    -- propósito: si llega algo que no existe, lo que corresponde es devolver
    -- cero clientes, no reventar la pantalla. El back ya lo valida antes.
    p_estado   text    DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
    v_offset integer;
    v_total  bigint;
    v_data   jsonb;
    v_filtro text;
    v_estado text;
BEGIN
    v_offset := (GREATEST(p_page, 1) - 1) * p_per_page;
    v_filtro := NULLIF(TRIM(COALESCE(p_search, '')), '');
    -- En mayúsculas porque así están en la tabla (ver ck_clientes_estado)
    v_estado := NULLIF(TRIM(UPPER(COALESCE(p_estado, ''))), '');

    SELECT COUNT(*) INTO v_total
      FROM ventas.clientes c
     WHERE c.deleted_at IS NULL
       AND (v_estado IS NULL OR c.estado = v_estado)
       AND (v_filtro IS NULL
        OR c.nombre_completo       ILIKE '%' || v_filtro || '%'
        OR c.razon_social          ILIKE '%' || v_filtro || '%'
        OR c.nombre_comercial      ILIKE '%' || v_filtro || '%'
        OR c.numero_identificacion ILIKE '%' || v_filtro || '%'
        OR c.email                 ILIKE '%' || v_filtro || '%'
        OR c.celular               ILIKE '%' || v_filtro || '%'
        OR c.telefono              ILIKE '%' || v_filtro || '%'
        OR c.id::text              ILIKE '%' || v_filtro || '%');

    SELECT COALESCE(jsonb_agg(
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
            'vendedor_id',           t.vendedor_id,
            'vendedor_nombre',       t.vendedor_nombre,
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
        ) ORDER BY t.id DESC
    ), '[]'::jsonb) INTO v_data
    FROM (
        SELECT c.*,
               (SELECT TRIM(COALESCE(e.nombres, '') || ' ' || COALESCE(e.apellidos, ''))
                  FROM rh.empleados e WHERE e.id = c.vendedor_id) AS vendedor_nombre
          FROM ventas.clientes c
         WHERE c.deleted_at IS NULL
           AND (v_estado IS NULL OR c.estado = v_estado)
           AND (v_filtro IS NULL
            OR c.nombre_completo       ILIKE '%' || v_filtro || '%'
            OR c.razon_social          ILIKE '%' || v_filtro || '%'
            OR c.nombre_comercial      ILIKE '%' || v_filtro || '%'
            OR c.numero_identificacion ILIKE '%' || v_filtro || '%'
            OR c.email                 ILIKE '%' || v_filtro || '%'
            OR c.celular               ILIKE '%' || v_filtro || '%'
            OR c.telefono              ILIKE '%' || v_filtro || '%'
            OR c.id::text              ILIKE '%' || v_filtro || '%')
         ORDER BY c.id DESC
         LIMIT p_per_page OFFSET v_offset
    ) t;

    RETURN jsonb_build_object(
        'data', v_data,
        'meta', jsonb_build_object(
            'total',        v_total,
            'per_page',     p_per_page,
            'current_page', GREATEST(p_page, 1),
            'last_page',    CASE WHEN v_total = 0 THEN 1 ELSE ceil(v_total::numeric / p_per_page) END
        )
    );
EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object('success', false, 'message', 'Error al listar clientes: ' || SQLERRM, 'error_code', SQLSTATE);
END;
$function$;

ALTER FUNCTION ventas.fn_clientes_listar_paginado(integer, integer, text, text) OWNER TO postgres;
COMMENT ON FUNCTION ventas.fn_clientes_listar_paginado(integer, integer, text, text)
    IS 'Clientes paginados, con búsqueda libre y filtro opcional por estado (NULL = todos)';

-- El índice es parcial porque la lista nunca mira a los de la papelera: así es
-- más pequeño y sirve exactamente para la consulta que se hace
CREATE INDEX IF NOT EXISTS ix_clientes_estado
    ON ventas.clientes (estado) WHERE deleted_at IS NULL;
