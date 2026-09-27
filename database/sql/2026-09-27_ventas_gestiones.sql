-- ============================================================================
-- GESTIÓN DE CLIENTES (esquema ventas): llamadas hechas, llamadas programadas
-- y reasignación de cartera. Es lo que consume la pantalla gestion-clientes.
--
--   ventas.gestiones               cada contacto con el cliente (hecho o por hacer)
--   ventas.asignaciones_clientes   historial de a qué vendedor estuvo asignado
--
--   ventas.fn_gestiones_json(id)                     una gestión
--   ventas.fn_gestiones_obtener(id)
--   ventas.fn_gestiones_listar_paginado(...)         historial del cliente (grilla)
--   ventas.fn_gestiones_crear(...)                   registrar una hecha o programar una
--   ventas.fn_gestiones_modificar(...)
--   ventas.fn_gestiones_cerrar(...)                  marcar realizada (+ crear el seguimiento)
--   ventas.fn_gestiones_eliminar(...)
--   ventas.fn_gestiones_agenda(...)                  lo pendiente de un vendedor (con vencidas)
--   ventas.fn_gestiones_resumen(cliente_id)          contadores, última y próxima
--   ventas.fn_clientes_reasignar(...)                cambia el vendedor y deja historial
--   ventas.fn_asignaciones_listar(cliente_id)
--
-- Mismo esquema que el resto de ventas: la lógica vive aquí, el contexto de
-- auditoría lo leen las tres triggers de siempre, y las reglas se lanzan con
-- RAISE EXCEPTION y SQLSTATE propio:
--   P0001 falta un dato obligatorio      P0013 el cliente o la gestión no existe
--   P0016 el empleado no existe          P0021 la gestión ya está cerrada
--   P0022 la fecha no es coherente
--
-- Una gestión PENDIENTE es una llamada programada (tiene fecha_programada);
-- al cerrarla pasa a REALIZADA con su resultado, y puede dejar creada la
-- siguiente (gestion_origen_id apunta a la que la generó).
-- Idempotente: CREATE TABLE IF NOT EXISTS + CREATE OR REPLACE FUNCTION.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- TABLAS
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS ventas.gestiones (
    id                bigserial     NOT NULL,
    cliente_id        bigint        NOT NULL,
    /** Quién la hace o la tiene pendiente (rh.empleados); normalmente el vendedor del cliente */
    empleado_id       bigint,
    /** Con qué persona del cliente se habló (ventas.contactos_clientes) */
    contacto_id       bigint,

    tipo              varchar(20)   NOT NULL DEFAULT 'LLAMADA',     -- LLAMADA, WHATSAPP, CORREO, VISITA, REUNION, OTRO
    estado            varchar(20)   NOT NULL DEFAULT 'REALIZADA',   -- PENDIENTE, REALIZADA, CANCELADA
    prioridad         varchar(10)   NOT NULL DEFAULT 'MEDIA',       -- ALTA, MEDIA, BAJA

    asunto            varchar(200)  NOT NULL,
    nota              text,
    /** Número al que se llamó / se llamará (puede no ser el de la ficha) */
    telefono          varchar(20),

    fecha_programada  timestamptz,
    fecha_realizada   timestamptz,
    duracion_minutos  integer,
    /** Cómo terminó: sólo cuando está REALIZADA */
    resultado         varchar(30),

    /** La gestión que la generó, cuando es un seguimiento */
    gestion_origen_id bigint,

    created_at        timestamptz            DEFAULT CURRENT_TIMESTAMP,
    updated_at        timestamptz            DEFAULT CURRENT_TIMESTAMP,
    created_by        varchar(100),
    updated_by        varchar(100),

    CONSTRAINT pk_gestiones PRIMARY KEY (id),
    CONSTRAINT ck_gestiones_tipo      CHECK (tipo IN ('LLAMADA', 'WHATSAPP', 'CORREO', 'VISITA', 'REUNION', 'OTRO')),
    CONSTRAINT ck_gestiones_estado    CHECK (estado IN ('PENDIENTE', 'REALIZADA', 'CANCELADA')),
    CONSTRAINT ck_gestiones_prioridad CHECK (prioridad IN ('ALTA', 'MEDIA', 'BAJA')),
    CONSTRAINT ck_gestiones_resultado CHECK (resultado IS NULL OR resultado IN (
        'CONTACTADO', 'NO_CONTESTA', 'BUZON', 'NUMERO_ERRADO', 'VOLVER_A_LLAMAR',
        'INTERESADO', 'NO_INTERESADO', 'COTIZACION', 'VENTA', 'RECLAMO', 'OTRO')),
    CONSTRAINT ck_gestiones_asunto    CHECK (length(TRIM(asunto)) >= 3),
    CONSTRAINT ck_gestiones_duracion  CHECK (duracion_minutos IS NULL OR (duracion_minutos >= 0 AND duracion_minutos <= 1440)),
    -- Lo pendiente lleva fecha; lo realizado lleva la fecha en que se hizo
    CONSTRAINT ck_gestiones_pendiente CHECK (estado <> 'PENDIENTE' OR fecha_programada IS NOT NULL),
    CONSTRAINT ck_gestiones_realizada CHECK (estado <> 'REALIZADA' OR fecha_realizada IS NOT NULL),

    CONSTRAINT fk_gestiones_cliente  FOREIGN KEY (cliente_id)  REFERENCES ventas.clientes (id) ON DELETE CASCADE,
    CONSTRAINT fk_gestiones_empleado FOREIGN KEY (empleado_id) REFERENCES rh.empleados (id),
    CONSTRAINT fk_gestiones_contacto FOREIGN KEY (contacto_id) REFERENCES ventas.contactos_clientes (id) ON DELETE SET NULL,
    CONSTRAINT fk_gestiones_origen   FOREIGN KEY (gestion_origen_id) REFERENCES ventas.gestiones (id) ON DELETE SET NULL
);

CREATE INDEX IF NOT EXISTS idx_gestiones_cliente    ON ventas.gestiones (cliente_id);
CREATE INDEX IF NOT EXISTS idx_gestiones_empleado   ON ventas.gestiones (empleado_id);
CREATE INDEX IF NOT EXISTS idx_gestiones_realizada  ON ventas.gestiones (fecha_realizada DESC);
CREATE INDEX IF NOT EXISTS idx_gestiones_pendientes ON ventas.gestiones (fecha_programada) WHERE estado = 'PENDIENTE';

COMMENT ON TABLE ventas.gestiones IS 'Contactos con el cliente: llamadas, visitas y correos, hechos o programados';

-- Historial de cartera: a qué vendedor estuvo asignado el cliente y por qué cambió
CREATE TABLE IF NOT EXISTS ventas.asignaciones_clientes (
    id                   bigserial   NOT NULL,
    cliente_id           bigint      NOT NULL,
    empleado_anterior_id bigint,
    empleado_nuevo_id    bigint,
    motivo               text,
    asignado_at          timestamptz          DEFAULT CURRENT_TIMESTAMP,
    created_at           timestamptz          DEFAULT CURRENT_TIMESTAMP,
    updated_at           timestamptz          DEFAULT CURRENT_TIMESTAMP,
    created_by           varchar(100),
    updated_by           varchar(100),

    CONSTRAINT pk_asignaciones_clientes PRIMARY KEY (id),
    CONSTRAINT fk_asignaciones_cliente   FOREIGN KEY (cliente_id)           REFERENCES ventas.clientes (id) ON DELETE CASCADE,
    CONSTRAINT fk_asignaciones_anterior  FOREIGN KEY (empleado_anterior_id) REFERENCES rh.empleados (id),
    CONSTRAINT fk_asignaciones_nuevo     FOREIGN KEY (empleado_nuevo_id)    REFERENCES rh.empleados (id)
);

CREATE INDEX IF NOT EXISTS idx_asignaciones_cliente ON ventas.asignaciones_clientes (cliente_id, asignado_at DESC);

COMMENT ON TABLE ventas.asignaciones_clientes IS 'Historial de reasignación de clientes entre vendedores';

-- ---------------------------------------------------------------------------
-- TRIGGERS DE AUDITORÍA (las mismas tres de siempre)
-- ---------------------------------------------------------------------------
DROP TRIGGER IF EXISTS trigger_gestiones_set_users  ON ventas.gestiones;
DROP TRIGGER IF EXISTS trigger_gestiones_updated_at ON ventas.gestiones;
DROP TRIGGER IF EXISTS trg_gestiones_audit          ON ventas.gestiones;

CREATE TRIGGER trigger_gestiones_set_users
    BEFORE INSERT OR UPDATE ON ventas.gestiones
    FOR EACH ROW EXECUTE FUNCTION auditoria.fn_set_audit_users();

CREATE TRIGGER trigger_gestiones_updated_at
    BEFORE UPDATE ON ventas.gestiones
    FOR EACH ROW EXECUTE FUNCTION auditoria.fn_update_updated_at_column();

CREATE TRIGGER trg_gestiones_audit
    AFTER INSERT OR UPDATE OR DELETE ON ventas.gestiones
    FOR EACH ROW EXECUTE FUNCTION auditoria.fn_auditar_cambios();

DROP TRIGGER IF EXISTS trigger_asignaciones_set_users ON ventas.asignaciones_clientes;
DROP TRIGGER IF EXISTS trg_asignaciones_audit         ON ventas.asignaciones_clientes;

CREATE TRIGGER trigger_asignaciones_set_users
    BEFORE INSERT OR UPDATE ON ventas.asignaciones_clientes
    FOR EACH ROW EXECUTE FUNCTION auditoria.fn_set_audit_users();

CREATE TRIGGER trg_asignaciones_audit
    AFTER INSERT OR UPDATE OR DELETE ON ventas.asignaciones_clientes
    FOR EACH ROW EXECUTE FUNCTION auditoria.fn_auditar_cambios();

-- ---------------------------------------------------------------------------
-- CONTEXTO DE AUDITORÍA (lo mismo en todas las funciones de gestiones)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ventas.fn_gestiones_contexto(
    p_usuario_id     bigint,
    p_usuario_login  varchar,
    p_usuario_nombre varchar,
    p_ip_address     inet,
    p_user_agent     text,
    p_request_id     uuid,
    p_modulo         text DEFAULT 'ventas.gestiones'
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
BEGIN
    PERFORM set_config('app.usuario_id',     COALESCE(p_usuario_id::text, ''), true);
    PERFORM set_config('app.usuario_login',  COALESCE(p_usuario_login, current_user), true);
    PERFORM set_config('app.usuario_nombre', COALESCE(p_usuario_nombre, current_user), true);
    PERFORM set_config('app.ip_address',     COALESCE(p_ip_address::text, ''), true);
    PERFORM set_config('app.user_agent',     COALESCE(p_user_agent, ''), true);
    PERFORM set_config('app.request_id',     COALESCE(p_request_id::text, ''), true);
    PERFORM set_config('app.modulo',         p_modulo, true);
END;
$function$;

-- ---------------------------------------------------------------------------
-- UNA GESTIÓN
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ventas.fn_gestiones_json(p_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
    v_data jsonb;
BEGIN
    SELECT jsonb_build_object(
        'id',                g.id,
        'cliente_id',        g.cliente_id,
        'cliente_nombre',    c.nombre_completo,
        'empleado_id',       g.empleado_id,
        'empleado_nombre',   (SELECT TRIM(COALESCE(e.nombres, '') || ' ' || COALESCE(e.apellidos, ''))
                                FROM rh.empleados e WHERE e.id = g.empleado_id),
        'contacto_id',       g.contacto_id,
        'contacto_nombre',   (SELECT cc.nombres FROM ventas.contactos_clientes cc WHERE cc.id = g.contacto_id),
        'tipo',              g.tipo,
        'estado',            g.estado,
        'prioridad',         g.prioridad,
        'asunto',            g.asunto,
        'nota',              g.nota,
        'telefono',          g.telefono,
        'fecha_programada',  to_char(g.fecha_programada, 'YYYY-MM-DD HH24:MI'),
        'fecha_realizada',   to_char(g.fecha_realizada,  'YYYY-MM-DD HH24:MI'),
        'duracion_minutos',  g.duracion_minutos,
        'resultado',         g.resultado,
        'gestion_origen_id', g.gestion_origen_id,
        -- Pendiente cuya hora ya pasó: la pantalla la pinta en rojo
        'vencida',           (g.estado = 'PENDIENTE' AND g.fecha_programada < CURRENT_TIMESTAMP),
        'created_by',        g.created_by,
        'updated_by',        g.updated_by,
        'created_at',        to_char(g.created_at, 'YYYY-MM-DD HH24:MI:SS'),
        'updated_at',        to_char(g.updated_at, 'YYYY-MM-DD HH24:MI:SS')
    ) INTO v_data
    FROM ventas.gestiones g
    JOIN ventas.clientes c ON c.id = g.cliente_id
    WHERE g.id = p_id;

    RETURN v_data;
END;
$function$;

CREATE OR REPLACE FUNCTION ventas.fn_gestiones_obtener(p_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
    v_data jsonb;
BEGIN
    v_data := ventas.fn_gestiones_json(p_id);
    IF v_data IS NULL THEN
        RETURN jsonb_build_object('success', false, 'message', 'La gestión no existe', 'error_code', 'GESTION_NOT_FOUND', 'data', null);
    END IF;
    RETURN jsonb_build_object('success', true, 'message', 'Gestión obtenida exitosamente', 'data', v_data);
END;
$function$;

-- ---------------------------------------------------------------------------
-- HISTORIAL DEL CLIENTE (grilla de la pestaña «Gestiones»)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ventas.fn_gestiones_listar_paginado(
    p_cliente_id bigint,
    p_page       integer DEFAULT 1,
    p_per_page   integer DEFAULT 15,
    p_search     text    DEFAULT '',
    p_tipo       varchar DEFAULT NULL,
    p_estado     varchar DEFAULT NULL,
    p_desde      date    DEFAULT NULL,
    p_hasta      date    DEFAULT NULL
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
BEGIN
    v_offset := (GREATEST(p_page, 1) - 1) * p_per_page;
    v_filtro := NULLIF(TRIM(COALESCE(p_search, '')), '');

    SELECT COUNT(*) INTO v_total
      FROM ventas.gestiones g
     WHERE (p_cliente_id IS NULL OR g.cliente_id = p_cliente_id)
       AND (p_tipo   IS NULL OR g.tipo   = p_tipo)
       AND (p_estado IS NULL OR g.estado = p_estado)
       AND (p_desde  IS NULL OR COALESCE(g.fecha_realizada, g.fecha_programada) >= p_desde::timestamptz)
       AND (p_hasta  IS NULL OR COALESCE(g.fecha_realizada, g.fecha_programada) < (p_hasta + 1)::timestamptz)
       AND (v_filtro IS NULL
            OR g.asunto    ILIKE '%' || v_filtro || '%'
            OR g.nota      ILIKE '%' || v_filtro || '%'
            OR g.telefono  ILIKE '%' || v_filtro || '%'
            OR g.resultado ILIKE '%' || v_filtro || '%');

    -- Lo pendiente primero y, dentro de cada grupo, lo más reciente arriba
    SELECT COALESCE(jsonb_agg(ventas.fn_gestiones_json(t.id) ORDER BY t.orden), '[]'::jsonb) INTO v_data
      FROM (
        SELECT g.id,
               ROW_NUMBER() OVER (ORDER BY (g.estado = 'PENDIENTE') DESC,
                                           COALESCE(g.fecha_realizada, g.fecha_programada) DESC,
                                           g.id DESC) AS orden
          FROM ventas.gestiones g
         WHERE (p_cliente_id IS NULL OR g.cliente_id = p_cliente_id)
           AND (p_tipo   IS NULL OR g.tipo   = p_tipo)
           AND (p_estado IS NULL OR g.estado = p_estado)
           AND (p_desde  IS NULL OR COALESCE(g.fecha_realizada, g.fecha_programada) >= p_desde::timestamptz)
           AND (p_hasta  IS NULL OR COALESCE(g.fecha_realizada, g.fecha_programada) < (p_hasta + 1)::timestamptz)
           AND (v_filtro IS NULL
                OR g.asunto    ILIKE '%' || v_filtro || '%'
                OR g.nota      ILIKE '%' || v_filtro || '%'
                OR g.telefono  ILIKE '%' || v_filtro || '%'
                OR g.resultado ILIKE '%' || v_filtro || '%')
         ORDER BY (g.estado = 'PENDIENTE') DESC,
                  COALESCE(g.fecha_realizada, g.fecha_programada) DESC,
                  g.id DESC
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
        RETURN jsonb_build_object('success', false, 'message', 'Error al listar las gestiones: ' || SQLERRM, 'error_code', SQLSTATE);
END;
$function$;

-- ---------------------------------------------------------------------------
-- RESUMEN DEL CLIENTE (las tarjetas de arriba)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ventas.fn_gestiones_resumen(p_cliente_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
    v_data jsonb;
BEGIN
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
                           ORDER BY u.fecha_realizada DESC NULLS LAST, u.id DESC LIMIT 1),
        'proxima',       (SELECT ventas.fn_gestiones_json(n.id) FROM ventas.gestiones n
                           WHERE n.cliente_id = p_cliente_id AND n.estado = 'PENDIENTE'
                           ORDER BY n.fecha_programada ASC, n.id ASC LIMIT 1)
    ) INTO v_data
    FROM ventas.gestiones g
    WHERE g.cliente_id = p_cliente_id;

    RETURN jsonb_build_object('success', true, 'message', 'Resumen obtenido exitosamente', 'data', v_data);
EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object('success', false, 'message', 'Error al obtener el resumen: ' || SQLERRM, 'error_code', SQLSTATE);
END;
$function$;

-- ---------------------------------------------------------------------------
-- CREAR (registrar una hecha, o programar una)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ventas.fn_gestiones_crear(
    p_cliente_id       bigint,
    p_tipo             varchar,
    p_estado           varchar,
    p_asunto           varchar,
    p_nota             text        DEFAULT NULL,
    p_empleado_id      bigint      DEFAULT NULL,
    p_contacto_id      bigint      DEFAULT NULL,
    p_telefono         varchar     DEFAULT NULL,
    p_prioridad        varchar     DEFAULT 'MEDIA',
    p_fecha_programada timestamptz DEFAULT NULL,
    p_fecha_realizada  timestamptz DEFAULT NULL,
    p_duracion_minutos integer     DEFAULT NULL,
    p_resultado        varchar     DEFAULT NULL,
    p_gestion_origen_id bigint     DEFAULT NULL,
    p_usuario_id       bigint      DEFAULT NULL,
    p_usuario_login    varchar     DEFAULT NULL,
    p_usuario_nombre   varchar     DEFAULT NULL,
    p_ip_address       inet        DEFAULT NULL,
    p_user_agent       text        DEFAULT NULL,
    p_request_id       uuid        DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'ventas', 'rh', 'auditoria'
AS $function$
DECLARE
    v_id     bigint;
    v_estado varchar := COALESCE(NULLIF(TRIM(COALESCE(p_estado, '')), ''), 'REALIZADA');
    v_fecha  timestamptz := CURRENT_TIMESTAMP;
BEGIN
    PERFORM ventas.fn_gestiones_contexto(p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    IF NOT EXISTS (SELECT 1 FROM ventas.clientes WHERE id = p_cliente_id AND deleted_at IS NULL) THEN
        RAISE EXCEPTION 'El cliente no existe o está en la papelera' USING ERRCODE = 'P0013';
    END IF;
    IF length(TRIM(COALESCE(p_asunto, ''))) < 3 THEN
        RAISE EXCEPTION 'El asunto es obligatorio (mínimo 3 caracteres)' USING ERRCODE = 'P0001';
    END IF;
    IF p_empleado_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM rh.empleados WHERE id = p_empleado_id) THEN
        RAISE EXCEPTION 'El empleado indicado no existe' USING ERRCODE = 'P0016';
    END IF;
    IF v_estado = 'PENDIENTE' AND p_fecha_programada IS NULL THEN
        RAISE EXCEPTION 'Una gestión programada necesita fecha y hora' USING ERRCODE = 'P0022';
    END IF;
    IF v_estado = 'REALIZADA' AND COALESCE(p_fecha_realizada, v_fecha) > v_fecha + interval '1 minute' THEN
        RAISE EXCEPTION 'Una gestión realizada no puede tener fecha futura' USING ERRCODE = 'P0022';
    END IF;

    INSERT INTO ventas.gestiones (
        cliente_id, empleado_id, contacto_id, tipo, estado, prioridad, asunto, nota, telefono,
        fecha_programada, fecha_realizada, duracion_minutos, resultado, gestion_origen_id,
        created_by, updated_by, created_at, updated_at
    ) VALUES (
        p_cliente_id,
        p_empleado_id,
        p_contacto_id,
        COALESCE(NULLIF(TRIM(COALESCE(p_tipo, '')), ''), 'LLAMADA'),
        v_estado,
        COALESCE(NULLIF(TRIM(COALESCE(p_prioridad, '')), ''), 'MEDIA'),
        TRIM(p_asunto),
        NULLIF(TRIM(COALESCE(p_nota, '')), ''),
        NULLIF(TRIM(COALESCE(p_telefono, '')), ''),
        CASE WHEN v_estado = 'PENDIENTE' THEN p_fecha_programada ELSE p_fecha_programada END,
        CASE WHEN v_estado = 'REALIZADA' THEN COALESCE(p_fecha_realizada, v_fecha) ELSE p_fecha_realizada END,
        p_duracion_minutos,
        CASE WHEN v_estado = 'REALIZADA' THEN p_resultado ELSE NULL END,
        p_gestion_origen_id,
        p_usuario_login, p_usuario_login, v_fecha, v_fecha
    )
    RETURNING id INTO v_id;

    RETURN jsonb_build_object(
        'success', true,
        'message', CASE WHEN v_estado = 'PENDIENTE' THEN 'Gestión programada exitosamente' ELSE 'Gestión registrada exitosamente' END,
        'data', ventas.fn_gestiones_json(v_id)
    );
END;
$function$;

-- ---------------------------------------------------------------------------
-- MODIFICAR
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ventas.fn_gestiones_modificar(
    p_id               bigint,
    p_tipo             varchar,
    p_estado           varchar,
    p_asunto           varchar,
    p_nota             text        DEFAULT NULL,
    p_empleado_id      bigint      DEFAULT NULL,
    p_contacto_id      bigint      DEFAULT NULL,
    p_telefono         varchar     DEFAULT NULL,
    p_prioridad        varchar     DEFAULT 'MEDIA',
    p_fecha_programada timestamptz DEFAULT NULL,
    p_fecha_realizada  timestamptz DEFAULT NULL,
    p_duracion_minutos integer     DEFAULT NULL,
    p_resultado        varchar     DEFAULT NULL,
    p_usuario_id       bigint      DEFAULT NULL,
    p_usuario_login    varchar     DEFAULT NULL,
    p_usuario_nombre   varchar     DEFAULT NULL,
    p_ip_address       inet        DEFAULT NULL,
    p_user_agent       text        DEFAULT NULL,
    p_request_id       uuid        DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'ventas', 'rh', 'auditoria'
AS $function$
DECLARE
    v_actual ventas.gestiones%ROWTYPE;
    v_estado varchar;
    v_fecha  timestamptz := CURRENT_TIMESTAMP;
    v_antes  jsonb;
BEGIN
    PERFORM ventas.fn_gestiones_contexto(p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    SELECT * INTO v_actual FROM ventas.gestiones WHERE id = p_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'La gestión no existe' USING ERRCODE = 'P0013';
    END IF;

    v_estado := COALESCE(NULLIF(TRIM(COALESCE(p_estado, '')), ''), v_actual.estado);

    IF length(TRIM(COALESCE(p_asunto, ''))) < 3 THEN
        RAISE EXCEPTION 'El asunto es obligatorio (mínimo 3 caracteres)' USING ERRCODE = 'P0001';
    END IF;
    IF p_empleado_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM rh.empleados WHERE id = p_empleado_id) THEN
        RAISE EXCEPTION 'El empleado indicado no existe' USING ERRCODE = 'P0016';
    END IF;
    IF v_estado = 'PENDIENTE' AND p_fecha_programada IS NULL THEN
        RAISE EXCEPTION 'Una gestión programada necesita fecha y hora' USING ERRCODE = 'P0022';
    END IF;

    v_antes := ventas.fn_gestiones_json(p_id);
    PERFORM set_config('app.datos_anteriores', v_antes::text, true);

    UPDATE ventas.gestiones
       SET tipo             = COALESCE(NULLIF(TRIM(COALESCE(p_tipo, '')), ''), tipo),
           estado           = v_estado,
           prioridad        = COALESCE(NULLIF(TRIM(COALESCE(p_prioridad, '')), ''), prioridad),
           asunto           = TRIM(p_asunto),
           nota             = NULLIF(TRIM(COALESCE(p_nota, '')), ''),
           telefono         = NULLIF(TRIM(COALESCE(p_telefono, '')), ''),
           empleado_id      = p_empleado_id,
           contacto_id      = p_contacto_id,
           fecha_programada = p_fecha_programada,
           fecha_realizada  = CASE WHEN v_estado = 'REALIZADA' THEN COALESCE(p_fecha_realizada, fecha_realizada, v_fecha) ELSE p_fecha_realizada END,
           duracion_minutos = p_duracion_minutos,
           resultado        = CASE WHEN v_estado = 'REALIZADA' THEN p_resultado ELSE NULL END,
           updated_by       = p_usuario_login,
           updated_at       = v_fecha
     WHERE id = p_id;

    PERFORM set_config('app.datos_anteriores', '', true);

    RETURN jsonb_build_object('success', true, 'message', 'Gestión actualizada exitosamente', 'data', ventas.fn_gestiones_json(p_id));
END;
$function$;

-- ---------------------------------------------------------------------------
-- CERRAR una pendiente: queda REALIZADA y, si se pide, deja creado el
-- seguimiento (la llamada siguiente) apuntando a ésta.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ventas.fn_gestiones_cerrar(
    p_id                bigint,
    p_resultado         varchar,
    p_nota              text        DEFAULT NULL,
    p_duracion_minutos  integer     DEFAULT NULL,
    p_fecha_realizada   timestamptz DEFAULT NULL,
    /** { "fecha": "...", "asunto": "...", "tipo": "...", "prioridad": "...", "nota": "..." } o null */
    p_siguiente         jsonb       DEFAULT NULL,
    p_usuario_id        bigint      DEFAULT NULL,
    p_usuario_login     varchar     DEFAULT NULL,
    p_usuario_nombre    varchar     DEFAULT NULL,
    p_ip_address        inet        DEFAULT NULL,
    p_user_agent        text        DEFAULT NULL,
    p_request_id        uuid        DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'ventas', 'rh', 'auditoria'
AS $function$
DECLARE
    v_actual    ventas.gestiones%ROWTYPE;
    v_fecha     timestamptz := CURRENT_TIMESTAMP;
    v_antes     jsonb;
    v_siguiente jsonb := NULL;
    v_nueva     jsonb;
BEGIN
    PERFORM ventas.fn_gestiones_contexto(p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    SELECT * INTO v_actual FROM ventas.gestiones WHERE id = p_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'La gestión no existe' USING ERRCODE = 'P0013';
    END IF;
    IF v_actual.estado <> 'PENDIENTE' THEN
        RAISE EXCEPTION 'Esa gestión ya no está pendiente' USING ERRCODE = 'P0021';
    END IF;

    v_antes := ventas.fn_gestiones_json(p_id);
    PERFORM set_config('app.datos_anteriores', v_antes::text, true);

    UPDATE ventas.gestiones
       SET estado           = 'REALIZADA',
           resultado        = NULLIF(TRIM(COALESCE(p_resultado, '')), ''),
           nota             = COALESCE(NULLIF(TRIM(COALESCE(p_nota, '')), ''), nota),
           duracion_minutos = COALESCE(p_duracion_minutos, duracion_minutos),
           fecha_realizada  = COALESCE(p_fecha_realizada, v_fecha),
           updated_by       = p_usuario_login,
           updated_at       = v_fecha
     WHERE id = p_id;

    PERFORM set_config('app.datos_anteriores', '', true);

    -- El seguimiento: otra gestión pendiente enganchada a ésta
    IF p_siguiente IS NOT NULL AND NULLIF(p_siguiente->>'fecha', '') IS NOT NULL THEN
        v_nueva := ventas.fn_gestiones_crear(
            v_actual.cliente_id,
            COALESCE(NULLIF(p_siguiente->>'tipo', ''), v_actual.tipo),
            'PENDIENTE',
            COALESCE(NULLIF(p_siguiente->>'asunto', ''), 'Seguimiento: ' || v_actual.asunto),
            NULLIF(p_siguiente->>'nota', ''),
            v_actual.empleado_id,
            v_actual.contacto_id,
            v_actual.telefono,
            COALESCE(NULLIF(p_siguiente->>'prioridad', ''), v_actual.prioridad),
            (p_siguiente->>'fecha')::timestamptz,
            NULL, NULL, NULL,
            p_id,
            p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id
        );
        v_siguiente := v_nueva->'data';
    END IF;

    RETURN jsonb_build_object(
        'success', true,
        'message', CASE WHEN v_siguiente IS NULL THEN 'Gestión cerrada exitosamente'
                        ELSE 'Gestión cerrada y seguimiento programado' END,
        'data', jsonb_build_object('gestion', ventas.fn_gestiones_json(p_id), 'siguiente', v_siguiente)
    );
END;
$function$;

-- ---------------------------------------------------------------------------
-- ELIMINAR (borrado real: el historial queda en auditoría)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ventas.fn_gestiones_eliminar(
    p_id             bigint,
    p_usuario_id     bigint  DEFAULT NULL,
    p_usuario_login  varchar DEFAULT NULL,
    p_usuario_nombre varchar DEFAULT NULL,
    p_ip_address     inet    DEFAULT NULL,
    p_user_agent     text    DEFAULT NULL,
    p_request_id     uuid    DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'ventas', 'rh', 'auditoria'
AS $function$
DECLARE
    v_antes jsonb;
BEGIN
    PERFORM ventas.fn_gestiones_contexto(p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    v_antes := ventas.fn_gestiones_json(p_id);
    IF v_antes IS NULL THEN
        RAISE EXCEPTION 'La gestión no existe' USING ERRCODE = 'P0013';
    END IF;

    PERFORM set_config('app.datos_anteriores', v_antes::text, true);
    DELETE FROM ventas.gestiones WHERE id = p_id;
    PERFORM set_config('app.datos_anteriores', '', true);

    RETURN jsonb_build_object('success', true, 'message', 'Gestión eliminada exitosamente', 'data', v_antes);
END;
$function$;

-- ---------------------------------------------------------------------------
-- AGENDA: lo pendiente, con las vencidas primero
-- Sin empleado devuelve la de todos (la usa el jefe de ventas).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ventas.fn_gestiones_agenda(
    p_empleado_id bigint  DEFAULT NULL,
    p_desde       date    DEFAULT NULL,
    p_hasta       date    DEFAULT NULL,
    p_limite      integer DEFAULT 100
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
    v_data jsonb;
BEGIN
    SELECT COALESCE(jsonb_agg(ventas.fn_gestiones_json(t.id) ORDER BY t.orden), '[]'::jsonb) INTO v_data
      FROM (
        SELECT g.id, ROW_NUMBER() OVER (ORDER BY g.fecha_programada ASC, g.id ASC) AS orden
          FROM ventas.gestiones g
          JOIN ventas.clientes c ON c.id = g.cliente_id AND c.deleted_at IS NULL
         WHERE g.estado = 'PENDIENTE'
           AND (p_empleado_id IS NULL OR g.empleado_id = p_empleado_id)
           AND (p_desde IS NULL OR g.fecha_programada >= p_desde::timestamptz)
           AND (p_hasta IS NULL OR g.fecha_programada < (p_hasta + 1)::timestamptz)
         ORDER BY g.fecha_programada ASC, g.id ASC
         LIMIT GREATEST(p_limite, 1)
      ) t;

    RETURN jsonb_build_object(
        'success', true,
        'message', 'Agenda obtenida exitosamente',
        'data', v_data,
        'total', jsonb_array_length(v_data)
    );
EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object('success', false, 'message', 'Error al obtener la agenda: ' || SQLERRM, 'error_code', SQLSTATE);
END;
$function$;

-- ---------------------------------------------------------------------------
-- REASIGNAR EL CLIENTE A OTRO VENDEDOR (deja historial)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ventas.fn_clientes_reasignar(
    p_cliente_id     bigint,
    p_empleado_id    bigint,
    p_motivo         text    DEFAULT NULL,
    /** true: las gestiones pendientes pasan también al nuevo vendedor */
    p_mover_agenda   boolean DEFAULT true,
    p_usuario_id     bigint  DEFAULT NULL,
    p_usuario_login  varchar DEFAULT NULL,
    p_usuario_nombre varchar DEFAULT NULL,
    p_ip_address     inet    DEFAULT NULL,
    p_user_agent     text    DEFAULT NULL,
    p_request_id     uuid    DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'ventas', 'rh', 'auditoria'
AS $function$
DECLARE
    v_anterior  bigint;
    v_nombre    text;
    v_nuevo     text;
    v_fecha     timestamptz := CURRENT_TIMESTAMP;
    v_movidas   integer := 0;
    v_antes     jsonb;
BEGIN
    PERFORM ventas.fn_gestiones_contexto(p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id, 'ventas.clientes');

    SELECT c.vendedor_id, c.nombre_completo INTO v_anterior, v_nombre
      FROM ventas.clientes c WHERE c.id = p_cliente_id AND c.deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'El cliente no existe o está en la papelera' USING ERRCODE = 'P0013';
    END IF;

    IF p_empleado_id IS NOT NULL THEN
        SELECT TRIM(COALESCE(e.nombres, '') || ' ' || COALESCE(e.apellidos, '')) INTO v_nuevo
          FROM rh.empleados e WHERE e.id = p_empleado_id;
        IF v_nuevo IS NULL THEN
            RAISE EXCEPTION 'El vendedor indicado no existe' USING ERRCODE = 'P0016';
        END IF;
    END IF;

    IF v_anterior IS NOT DISTINCT FROM p_empleado_id THEN
        RAISE EXCEPTION 'El cliente ya está asignado a ese vendedor' USING ERRCODE = 'P0001';
    END IF;

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

    INSERT INTO ventas.asignaciones_clientes (cliente_id, empleado_anterior_id, empleado_nuevo_id, motivo, asignado_at, created_by, updated_by)
    VALUES (p_cliente_id, v_anterior, p_empleado_id, NULLIF(TRIM(COALESCE(p_motivo, '')), ''), v_fecha, p_usuario_login, p_usuario_login);

    -- Lo que quedaba por hacer se va con el cliente
    IF p_mover_agenda THEN
        UPDATE ventas.gestiones
           SET empleado_id = p_empleado_id, updated_by = p_usuario_login, updated_at = v_fecha
         WHERE cliente_id = p_cliente_id AND estado = 'PENDIENTE'
           AND empleado_id IS DISTINCT FROM p_empleado_id;
        GET DIAGNOSTICS v_movidas = ROW_COUNT;
    END IF;

    RETURN jsonb_build_object(
        'success', true,
        'message', CASE
            WHEN p_empleado_id IS NULL THEN format('«%s» quedó sin vendedor asignado', v_nombre)
            ELSE format('«%s» reasignado a %s', v_nombre, v_nuevo)
        END || CASE WHEN v_movidas > 0 THEN format(' (%s pendiente(s) movidas)', v_movidas) ELSE '' END,
        'data', jsonb_build_object(
            'cliente', (ventas.fn_clientes_obtener(p_cliente_id))->'data',
            'gestiones_movidas', v_movidas
        )
    );
END;
$function$;

-- ---------------------------------------------------------------------------
-- HISTORIAL DE ASIGNACIONES DEL CLIENTE
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

-- ---------------------------------------------------------------------------
-- PROPIETARIO
-- ---------------------------------------------------------------------------
ALTER TABLE ventas.gestiones             OWNER TO postgres;
ALTER TABLE ventas.asignaciones_clientes OWNER TO postgres;

ALTER FUNCTION ventas.fn_gestiones_contexto(bigint, varchar, varchar, inet, text, uuid, text) OWNER TO postgres;
ALTER FUNCTION ventas.fn_gestiones_json(bigint) OWNER TO postgres;
ALTER FUNCTION ventas.fn_gestiones_obtener(bigint) OWNER TO postgres;
ALTER FUNCTION ventas.fn_gestiones_listar_paginado(bigint, integer, integer, text, varchar, varchar, date, date) OWNER TO postgres;
ALTER FUNCTION ventas.fn_gestiones_resumen(bigint) OWNER TO postgres;
ALTER FUNCTION ventas.fn_gestiones_eliminar(bigint, bigint, varchar, varchar, inet, text, uuid) OWNER TO postgres;
ALTER FUNCTION ventas.fn_gestiones_agenda(bigint, date, date, integer) OWNER TO postgres;
ALTER FUNCTION ventas.fn_asignaciones_listar(bigint) OWNER TO postgres;
