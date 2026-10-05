-- ============================================================================
-- CLIENTES: ver sólo los que tengo asignados
--
-- En la pantalla de gestión, cada usuario debe ver únicamente su cartera. La
-- lista está paginada EN EL SERVIDOR (mil y pico clientes), así que el filtro
-- tiene que llegar hasta aquí: filtrarlo en el navegador sólo recortaría las
-- quince filas de la página que se está viendo.
--
-- El filtro es OPCIONAL y por llamada, no global: esta pantalla lo pide, pero
-- la de Ventas > Clientes no, que es donde se reparten los clientes que aún no
-- tienen dueño. Si fuera global no habría forma de asignar a nadie.
--
-- «Mío» es cualquiera de los tres papeles —vendedor, cobrador o asistente—,
-- porque a los tres se les asigna para que trabajen ese cliente.
--
-- Idempotente: se puede volver a correr.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- ¿Este cliente es de este usuario?
--
-- Se mira el papel VIGENTE, no el histórico: a quien le quitaron el cliente el
-- mes pasado no tiene por qué seguir viéndolo. Por eso la asignación tiene que
-- ser la última de su papel.
--
-- SQL plano y STABLE para que el planificador la pueda meter dentro de la
-- consulta en vez de llamarla fila por fila.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ventas.fn_cliente_es_de(p_cliente_id bigint, p_usuario_id bigint)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
AS $function$
    SELECT EXISTS (
        SELECT 1 FROM ventas.clientes c
         WHERE c.id = p_cliente_id AND c.vendedor_usuario_id = p_usuario_id
    ) OR EXISTS (
        SELECT 1
          FROM (VALUES ('VENDEDOR'), ('COBRADOR'), ('ASISTENTE')) AS r(rol)
          CROSS JOIN LATERAL (
              SELECT a.usuario_nuevo_id
                FROM ventas.asignaciones_clientes a
               WHERE a.cliente_id = p_cliente_id AND a.rol = r.rol
               ORDER BY a.asignado_at DESC, a.id DESC
               LIMIT 1
          ) u
         WHERE u.usuario_nuevo_id = p_usuario_id
    )
$function$;

COMMENT ON FUNCTION ventas.fn_cliente_es_de(bigint, bigint)
    IS 'true si el usuario ocupa ahora mismo alguno de los tres papeles del cliente';

-- ---------------------------------------------------------------------------
-- La lista paginada gana el filtro
--
-- Añadir un parámetro con DEFAULT crea una SOBRECARGA, no un reemplazo, y
-- entonces la llamada de cuatro argumentos del back se vuelve ambigua
-- («function is not unique»). Se borran primero todas las versiones.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    v_firma text;
BEGIN
    FOR v_firma IN
        SELECT 'ventas.fn_clientes_listar_paginado(' || pg_get_function_identity_arguments(p.oid) || ')'
          FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
         WHERE n.nspname = 'ventas' AND p.proname = 'fn_clientes_listar_paginado' AND p.prokind = 'f'
    LOOP
        EXECUTE 'DROP FUNCTION IF EXISTS ' || v_firma;
        RAISE NOTICE 'Borrada %', v_firma;
    END LOOP;
END
$$;

CREATE FUNCTION ventas.fn_clientes_listar_paginado(
    p_page       integer DEFAULT 1,
    p_per_page   integer DEFAULT 15,
    p_search     text    DEFAULT '',
    p_estado     text    DEFAULT NULL,
    -- NULL = todos los clientes (la pantalla de Clientes). Con un usuario, sólo
    -- los que tiene asignados en alguno de los tres papeles.
    p_usuario_id bigint  DEFAULT NULL
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
       AND (p_usuario_id IS NULL OR ventas.fn_cliente_es_de(c.id, p_usuario_id))
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
            'vendedor_id',           t.vendedor_usuario_id,
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
               ventas.fn_nombre_usuario(c.vendedor_usuario_id) AS vendedor_nombre
          FROM ventas.clientes c
         WHERE c.deleted_at IS NULL
           AND (p_usuario_id IS NULL OR ventas.fn_cliente_es_de(c.id, p_usuario_id))
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

ALTER FUNCTION ventas.fn_clientes_listar_paginado(integer, integer, text, text, bigint) OWNER TO postgres;
COMMENT ON FUNCTION ventas.fn_clientes_listar_paginado(integer, integer, text, text, bigint)
    IS 'Clientes paginados, con búsqueda libre, filtro por estado y, si se indica usuario, sólo los que tiene asignados';

-- Para resolver rápido «¿quién tiene ahora este papel en este cliente?»
CREATE INDEX IF NOT EXISTS ix_asignaciones_usuario_nuevo
    ON ventas.asignaciones_clientes (usuario_nuevo_id) WHERE usuario_nuevo_id IS NOT NULL;
