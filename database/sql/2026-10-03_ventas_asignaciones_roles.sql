-- ============================================================================
-- UN CLIENTE, VARIOS RESPONSABLES
--
-- Hasta ahora un cliente tenía un único responsable: el vendedor, guardado en
-- ventas.clientes.vendedor_id, con el historial de traspasos en
-- ventas.asignaciones_clientes.
--
-- En la práctica lo atiende más de una persona: el vendedor, quien le cobra y
-- quien le llama para coordinar. Esto añade el ROL a cada asignación, de modo
-- que el mismo mecanismo de «ahora lo atiende» valga para cada uno.
--
-- Decisiones, por si alguien se pregunta por qué así:
--
--   · NO se añaden columnas por rol a ventas.clientes ni una tabla de
--     titulares. El responsable actual de un rol es, sencillamente, la última
--     asignación de ese rol. Una tabla más habría que mantenerla en sincronía
--     con el historial, y se desincroniza siempre.
--
--   · vendedor_id SE QUEDA como está y manda para el rol VENDEDOR. Media
--     aplicación lo usa —filtros, «mis clientes», el dueño de las gestiones—
--     y moverlo ahora sería un cambio enorme para nada.
--
--   · El rol NO lleva CHECK. Añadir un cuarto responsable mañana no debería
--     pedir una migración; la lista vive en la aplicación.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. El rol en el historial
-- ---------------------------------------------------------------------------
ALTER TABLE ventas.asignaciones_clientes
    ADD COLUMN IF NOT EXISTS rol varchar(20) NOT NULL DEFAULT 'VENDEDOR';

COMMENT ON COLUMN ventas.asignaciones_clientes.rol IS
    'Con qué papel atiende: VENDEDOR, COBRADOR, ASISTENTE… La lista la pone la aplicación, no un CHECK.';

-- Lo de antes era todo del vendedor; el DEFAULT ya lo deja así, pero se deja
-- escrito para que al releer el archivo no quede duda.
UPDATE ventas.asignaciones_clientes SET rol = 'VENDEDOR' WHERE rol IS NULL;

-- Buscar «el último de este rol» es la consulta que más se va a hacer
CREATE INDEX IF NOT EXISTS ix_asignaciones_cliente_rol
    ON ventas.asignaciones_clientes (cliente_id, rol, asignado_at DESC, id DESC);


-- ---------------------------------------------------------------------------
-- 2. Quién atiende ahora, por rol
--
-- Para VENDEDOR manda la columna del cliente; para el resto, la última
-- asignación. Se devuelven siempre los tres, con empleado en null cuando el
-- puesto está vacío: así la pantalla pinta las tres fichas sin adivinar.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ventas.fn_clientes_responsables(p_cliente_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'ventas', 'rh'
AS $function$
DECLARE
    v_data jsonb;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM ventas.clientes WHERE id = p_cliente_id AND deleted_at IS NULL) THEN
        RETURN jsonb_build_object('success', false, 'message', 'El cliente no existe o está en la papelera');
    END IF;

    SELECT jsonb_agg(x.fila ORDER BY x.orden) INTO v_data
    FROM (
        SELECT 1 AS orden, jsonb_build_object(
                   'rol', 'VENDEDOR',
                   'empleado_id', c.vendedor_id,
                   'empleado_nombre', (SELECT TRIM(COALESCE(e.nombres, '') || ' ' || COALESCE(e.apellidos, ''))
                                         FROM rh.empleados e WHERE e.id = c.vendedor_id),
                   'desde', (SELECT to_char(MAX(a.asignado_at), 'YYYY-MM-DD HH24:MI')
                               FROM ventas.asignaciones_clientes a
                              WHERE a.cliente_id = p_cliente_id AND a.rol = 'VENDEDOR'
                                AND a.empleado_nuevo_id IS NOT DISTINCT FROM c.vendedor_id)
               ) AS fila
          FROM ventas.clientes c WHERE c.id = p_cliente_id

        UNION ALL

        SELECT CASE r.rol WHEN 'COBRADOR' THEN 2 ELSE 3 END, jsonb_build_object(
                   'rol', r.rol,
                   'empleado_id', u.empleado_nuevo_id,
                   'empleado_nombre', (SELECT TRIM(COALESCE(e.nombres, '') || ' ' || COALESCE(e.apellidos, ''))
                                         FROM rh.empleados e WHERE e.id = u.empleado_nuevo_id),
                   'desde', to_char(u.asignado_at, 'YYYY-MM-DD HH24:MI')
               )
          FROM (VALUES ('COBRADOR'), ('ASISTENTE')) AS r(rol)
          -- La última de ese rol, si la hay; si no, el puesto sale vacío
          LEFT JOIN LATERAL (
              SELECT a.empleado_nuevo_id, a.asignado_at
                FROM ventas.asignaciones_clientes a
               WHERE a.cliente_id = p_cliente_id AND a.rol = r.rol
               ORDER BY a.asignado_at DESC, a.id DESC
               LIMIT 1
          ) u ON true
    ) x;

    RETURN jsonb_build_object('success', true, 'message', 'Responsables obtenidos exitosamente',
                              'data', COALESCE(v_data, '[]'::jsonb));
EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object('success', false, 'message', 'Error al obtener los responsables: ' || SQLERRM, 'error_code', SQLSTATE);
END;
$function$;


-- ---------------------------------------------------------------------------
-- 3. Reasignar, ahora por rol
--
-- Se sustituye la función: añadir el parámetro al final habría dejado dos
-- versiones conviviendo y las llamadas posicionales podrían caer en cualquiera.
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS ventas.fn_clientes_reasignar(
    p_cliente_id bigint, p_empleado_id bigint, p_motivo text, p_mover_agenda boolean,
    p_usuario_id bigint, p_usuario_login character varying, p_usuario_nombre character varying,
    p_ip_address inet, p_user_agent text, p_request_id uuid);

CREATE OR REPLACE FUNCTION ventas.fn_clientes_reasignar(
    p_cliente_id    bigint,
    p_empleado_id   bigint,
    p_motivo        text DEFAULT NULL,
    p_mover_agenda  boolean DEFAULT true,
    p_rol           varchar DEFAULT 'VENDEDOR',
    p_usuario_id    bigint DEFAULT NULL,
    p_usuario_login character varying DEFAULT NULL,
    p_usuario_nombre character varying DEFAULT NULL,
    p_ip_address    inet DEFAULT NULL,
    p_user_agent    text DEFAULT NULL,
    p_request_id    uuid DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'ventas', 'rh', 'auditoria'
AS $function$
DECLARE
    v_rol       varchar := UPPER(COALESCE(NULLIF(TRIM(p_rol), ''), 'VENDEDOR'));
    v_esVendedor boolean := v_rol = 'VENDEDOR';
    v_anterior  bigint;
    v_nombre    text;
    v_nuevo     text;
    v_fecha     timestamptz := CURRENT_TIMESTAMP;
    v_movidas   integer := 0;
    v_antes     jsonb;
BEGIN
    PERFORM ventas.fn_gestiones_contexto(p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id, 'ventas.clientes');

    SELECT c.nombre_completo INTO v_nombre
      FROM ventas.clientes c WHERE c.id = p_cliente_id AND c.deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'El cliente no existe o está en la papelera' USING ERRCODE = 'P0013';
    END IF;

    -- Quién lo tenía: la columna si es el vendedor, la última asignación si no
    IF v_esVendedor THEN
        SELECT c.vendedor_id INTO v_anterior FROM ventas.clientes c WHERE c.id = p_cliente_id;
    ELSE
        SELECT a.empleado_nuevo_id INTO v_anterior
          FROM ventas.asignaciones_clientes a
         WHERE a.cliente_id = p_cliente_id AND a.rol = v_rol
         ORDER BY a.asignado_at DESC, a.id DESC LIMIT 1;
    END IF;

    IF p_empleado_id IS NOT NULL THEN
        SELECT TRIM(COALESCE(e.nombres, '') || ' ' || COALESCE(e.apellidos, '')) INTO v_nuevo
          FROM rh.empleados e WHERE e.id = p_empleado_id;
        IF v_nuevo IS NULL THEN
            RAISE EXCEPTION 'El empleado indicado no existe' USING ERRCODE = 'P0016';
        END IF;
    END IF;

    IF v_anterior IS NOT DISTINCT FROM p_empleado_id THEN
        RAISE EXCEPTION 'El cliente ya tiene a esa persona en ese papel' USING ERRCODE = 'P0001';
    END IF;

    -- Sólo el vendedor vive en la ficha del cliente
    IF v_esVendedor THEN
        v_antes := (ventas.fn_clientes_obtener(p_cliente_id))->'data';
        PERFORM set_config('app.datos_anteriores', v_antes::text, true);
        PERFORM set_config('app.datos_nuevos', (v_antes || jsonb_build_object('vendedor_id', p_empleado_id, 'vendedor_nombre', v_nuevo))::text, true);

        UPDATE ventas.clientes
           SET vendedor_id = p_empleado_id,
               updated_by  = COALESCE(p_usuario_login, updated_by),
               updated_at  = v_fecha
         WHERE id = p_cliente_id;

        PERFORM set_config('app.datos_anteriores', '', true);
        PERFORM set_config('app.datos_nuevos', '', true);
    END IF;

    INSERT INTO ventas.asignaciones_clientes (cliente_id, rol, empleado_anterior_id, empleado_nuevo_id, motivo, asignado_at, created_by, updated_by)
    VALUES (p_cliente_id, v_rol, v_anterior, p_empleado_id, NULLIF(TRIM(COALESCE(p_motivo, '')), ''), v_fecha, p_usuario_login, p_usuario_login);

    -- La agenda se mueve sólo con el vendedor: las gestiones son suyas, no de
    -- quien cobra ni de quien coordina.
    IF p_mover_agenda AND v_esVendedor THEN
        UPDATE ventas.gestiones
           SET empleado_id = p_empleado_id, updated_by = p_usuario_login, updated_at = v_fecha
         WHERE cliente_id = p_cliente_id AND estado = 'PENDIENTE'
           AND empleado_id IS DISTINCT FROM p_empleado_id;
        GET DIAGNOSTICS v_movidas = ROW_COUNT;
    END IF;

    RETURN jsonb_build_object(
        'success', true,
        'message', CASE
            WHEN p_empleado_id IS NULL THEN 'Se quitó el responsable del cliente'
            ELSE v_nombre || ' ahora lo atiende ' || v_nuevo
        END || CASE WHEN v_movidas > 0 THEN ' (' || v_movidas || ' gestión(es) pendientes se movieron)' ELSE '' END,
        'data', jsonb_build_object(
            'cliente_id', p_cliente_id,
            'rol', v_rol,
            'empleado_id', p_empleado_id,
            'empleado_nombre', v_nuevo,
            'gestiones_movidas', v_movidas
        )
    );
END;
$function$;


-- ---------------------------------------------------------------------------
-- 4. El historial, con el rol
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ventas.fn_asignaciones_listar(p_cliente_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
    v_data jsonb;
BEGIN
    SELECT COALESCE(jsonb_agg(
        jsonb_build_object(
            'id',                   a.id,
            'cliente_id',           a.cliente_id,
            'rol',                  a.rol,
            'empleado_anterior_id', a.empleado_anterior_id,
            'empleado_anterior',    (SELECT TRIM(COALESCE(e.nombres, '') || ' ' || COALESCE(e.apellidos, ''))
                                       FROM rh.empleados e WHERE e.id = a.empleado_anterior_id),
            'empleado_nuevo_id',    a.empleado_nuevo_id,
            'empleado_nuevo',       (SELECT TRIM(COALESCE(e.nombres, '') || ' ' || COALESCE(e.apellidos, ''))
                                       FROM rh.empleados e WHERE e.id = a.empleado_nuevo_id),
            'motivo',               a.motivo,
            'asignado_at',          to_char(a.asignado_at, 'YYYY-MM-DD HH24:MI'),
            'created_by',           a.created_by
        ) ORDER BY a.asignado_at DESC, a.id DESC
    ), '[]'::jsonb) INTO v_data
    FROM ventas.asignaciones_clientes a
    WHERE a.cliente_id = p_cliente_id;

    RETURN jsonb_build_object('success', true, 'message', 'Historial obtenido exitosamente', 'data', v_data);
EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object('success', false, 'message', 'Error al obtener el historial: ' || SQLERRM, 'error_code', SQLSTATE);
END;
$function$;
