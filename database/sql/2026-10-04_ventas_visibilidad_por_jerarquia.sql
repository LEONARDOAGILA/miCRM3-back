-- ============================================================================
-- CLIENTES: la visibilidad sigue la jerarquía de grupos
--
-- La regla, en una línea:
--
--   Ves un cliente si está asignado A TI, o a alguien de un grupo POR DEBAJO
--   del tuyo. Si tu grupo es administrador, ves todo.
--
-- Lo importante es el «por debajo» ESTRICTO: los iguales no se ven entre sí.
-- Si fuera «tu grupo y sus subgrupos», dos vendedores del mismo grupo se verían
-- la cartera mutuamente, que es justo lo que se quería evitar. Por eso cada
-- jefe va en su propio nodo y su gente cuelga debajo:
--
--   ventas              <- gerente de ventas
--   +- Cuenca           <- jefe zonal   (ve a los de abajo)
--      +- Vendedores    <- vendedores   (cada uno ve lo suyo)
--
-- El reparto de cartera entre varias asistentes y cobradores compartidos NO se
-- modela en el árbol —es de muchos a muchos y un árbol no lo admite—: ya está
-- en el cliente, que tiene asignados vendedor, cobrador y asistente por
-- separado. Cada uno ve los clientes en los que aparece.
--
-- No se recorre el árbol por cada cliente: se calcula una vez la lista de
-- usuarios a cargo y después se mira la pertenencia, que con mil clientes es
-- la diferencia entre una consulta y mil.
--
-- Idempotente: se puede volver a correr.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- De quién respondo: yo y todos los que están por debajo de mi grupo
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ventas.fn_usuarios_a_cargo(p_usuario_id bigint)
RETURNS bigint[]
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
AS $function$
DECLARE
    v_grupo bigint;
    v_ids   bigint[];
BEGIN
    IF p_usuario_id IS NULL THEN
        RETURN '{}'::bigint[];
    END IF;

    SELECT u.grupo_id INTO v_grupo FROM seguridad.users u WHERE u.id = p_usuario_id;

    -- Sin grupo, uno responde sólo de lo suyo
    IF v_grupo IS NULL THEN
        RETURN ARRAY[p_usuario_id];
    END IF;

    WITH RECURSIVE bajo AS (
        -- Estrictamente por debajo: se arranca de los HIJOS, no del propio grupo
        SELECT g.id FROM seguridad.grupos g WHERE g.padre_id = v_grupo
        UNION ALL
        SELECT g.id FROM seguridad.grupos g JOIN bajo b ON g.padre_id = b.id
    )
    SELECT ARRAY(
        SELECT u.id FROM seguridad.users u
         WHERE u.deleted_at IS NULL
           AND (u.id = p_usuario_id OR u.grupo_id IN (SELECT id FROM bajo))
    ) INTO v_ids;

    RETURN COALESCE(v_ids, ARRAY[p_usuario_id]);
END;
$function$;

COMMENT ON FUNCTION ventas.fn_usuarios_a_cargo(bigint)
    IS 'El usuario y todos los de grupos por debajo del suyo (los iguales no entran)';

-- ---------------------------------------------------------------------------
-- ¿Alguno de esos tiene asignado este cliente, en cualquiera de los 3 papeles?
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ventas.fn_cliente_es_de_alguno(p_cliente_id bigint, p_usuarios bigint[])
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
AS $function$
    SELECT EXISTS (
        SELECT 1 FROM ventas.clientes c
         WHERE c.id = p_cliente_id AND c.vendedor_usuario_id = ANY(p_usuarios)
    ) OR EXISTS (
        -- El papel VIGENTE de cada tipo, no el histórico: a quien le quitaron
        -- el cliente no tiene por qué seguir viéndolo
        SELECT 1
          FROM (VALUES ('VENDEDOR'), ('COBRADOR'), ('ASISTENTE')) AS r(rol)
          CROSS JOIN LATERAL (
              SELECT a.usuario_nuevo_id
                FROM ventas.asignaciones_clientes a
               WHERE a.cliente_id = p_cliente_id AND a.rol = r.rol
               ORDER BY a.asignado_at DESC, a.id DESC
               LIMIT 1
          ) u
         WHERE u.usuario_nuevo_id = ANY(p_usuarios)
    )
$function$;

-- ---------------------------------------------------------------------------
-- La lista, ahora con la jerarquía
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ventas.fn_clientes_listar_paginado(
    p_page       integer DEFAULT 1,
    p_per_page   integer DEFAULT 15,
    p_search     text    DEFAULT '',
    p_estado     text    DEFAULT NULL,
    p_usuario_id bigint  DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
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
    v_offset := (GREATEST(p_page, 1) - 1) * p_per_page;
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

    SELECT COUNT(*) INTO v_total
      FROM ventas.clientes c
     WHERE c.deleted_at IS NULL
       AND (p_usuario_id IS NULL OR v_ve_todo OR ventas.fn_cliente_es_de_alguno(c.id, v_usuarios))
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
           AND (p_usuario_id IS NULL OR v_ve_todo OR ventas.fn_cliente_es_de_alguno(c.id, v_usuarios))
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

COMMENT ON FUNCTION ventas.fn_clientes_listar_paginado(integer, integer, text, text, bigint)
    IS 'Clientes paginados; con usuario, sólo los suyos y los de quienes tiene por debajo en el árbol de grupos (todo si su grupo es administrador)';
