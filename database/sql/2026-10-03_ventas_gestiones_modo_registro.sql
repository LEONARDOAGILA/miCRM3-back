-- ===========================================================================
-- CÓMO SE REGISTRÓ LA GESTIÓN (ventas.gestiones.modo_registro)
-- ===========================================================================
-- Fecha: 2026-10-03
--
-- El formulario de gestión pregunta de tres maneras:
--
--     «En este momento»  se está hablando con el cliente ahora mismo, y la
--                        hora que se guarda es la de pulsar Guardar
--     «Ya la hice»       se anota después, con la hora que el vendedor diga
--     «Programarla»      queda pendiente para una fecha futura
--
-- Hasta ahora esa elección sólo decidía qué campos se veían y se perdía al
-- guardar: en la base las dos primeras acaban igual (REALIZADA con su
-- fecha_realizada) y no había forma de distinguirlas después. Para poder sacar
-- reportes —cuánto se registra en caliente frente a cuánto se anota de memoria
-- al final del día, qué parte del trabajo viene de la agenda— hace falta
-- guardarlo, y es lo que añade esta columna.
--
-- Valores: AHORA, YA_HECHA, PROGRAMADA. NULL en lo registrado antes de esto:
-- no se rellena a posteriori porque sería inventarse el dato (una REALIZADA
-- vieja pudo anotarse de cualquiera de las dos formas).
--
-- Importante para quien lea los reportes: el modo dice cómo NACIÓ la gestión,
-- no en qué estado está ahora. Una PROGRAMADA que luego se cierra sigue siendo
-- PROGRAMADA —así se puede medir qué parte del trabajo sale de la agenda—, y
-- por eso modificar una gestión no cambia su modo.
--
-- Idempotente: ADD COLUMN IF NOT EXISTS + DROP/CREATE de las funciones.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- 1. LA COLUMNA
-- ---------------------------------------------------------------------------
ALTER TABLE ventas.gestiones
    ADD COLUMN IF NOT EXISTS modo_registro varchar(20);

ALTER TABLE ventas.gestiones
    DROP CONSTRAINT IF EXISTS ck_gestiones_modo_registro;

ALTER TABLE ventas.gestiones
    ADD CONSTRAINT ck_gestiones_modo_registro
    CHECK (modo_registro IS NULL OR modo_registro IN ('AHORA', 'YA_HECHA', 'PROGRAMADA'));

COMMENT ON COLUMN ventas.gestiones.modo_registro IS
    'Cómo se registró: AHORA (en caliente, la hora la pone el guardado), YA_HECHA (anotada después) o PROGRAMADA. NULL en lo anterior a 2026-10-03. No cambia al modificar la gestión.';

-- Para agrupar por modo sin recorrer la tabla entera
CREATE INDEX IF NOT EXISTS idx_gestiones_modo_registro
    ON ventas.gestiones (modo_registro)
    WHERE modo_registro IS NOT NULL;

-- ---------------------------------------------------------------------------
-- 2. FUERA LAS FIRMAS VIEJAS
--
-- Al crear y al modificar les entra un parámetro nuevo. CREATE OR REPLACE con
-- otra firma no reemplaza: deja una sobrecarga, y entonces una llamada
-- posicional puede caer en la función vieja sin avisar. Se borran por nombre,
-- con todas sus sobrecargas si las hubiera.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    r record;
BEGIN
    FOR r IN
        SELECT p.oid::regprocedure AS firma
          FROM pg_proc p
          JOIN pg_namespace n ON n.oid = p.pronamespace
         WHERE n.nspname = 'ventas'
           AND p.proname IN ('fn_gestiones_crear', 'fn_gestiones_modificar')
    LOOP
        EXECUTE 'DROP FUNCTION ' || r.firma;
    END LOOP;
END
$$;

-- ---------------------------------------------------------------------------
-- 3. CREAR
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
    /** AHORA / YA_HECHA / PROGRAMADA; si no viene se deduce del estado */
    p_modo_registro    varchar     DEFAULT NULL,
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
    v_modo   varchar;
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

    -- El modo lo manda la pantalla. Quien no lo mande (un seguimiento creado
    -- por el cierre, una integración) deja que se deduzca del estado, que es
    -- lo único que se sabe con certeza.
    v_modo := UPPER(NULLIF(TRIM(COALESCE(p_modo_registro, '')), ''));
    IF v_modo IS NULL THEN
        v_modo := CASE WHEN v_estado = 'PENDIENTE' THEN 'PROGRAMADA'
                       WHEN v_estado = 'REALIZADA' THEN 'YA_HECHA'
                       ELSE NULL END;
    END IF;
    IF v_modo IS NOT NULL AND v_modo NOT IN ('AHORA', 'YA_HECHA', 'PROGRAMADA') THEN
        RAISE EXCEPTION 'El modo de registro no es válido' USING ERRCODE = 'P0022';
    END IF;

    INSERT INTO ventas.gestiones (
        cliente_id, empleado_id, contacto_id, tipo, estado, prioridad, asunto, nota, telefono,
        fecha_programada, fecha_realizada, duracion_minutos, resultado, modo_registro, gestion_origen_id,
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
        p_fecha_programada,
        CASE WHEN v_estado = 'REALIZADA' THEN COALESCE(p_fecha_realizada, v_fecha) ELSE p_fecha_realizada END,
        p_duracion_minutos,
        CASE WHEN v_estado = 'REALIZADA' THEN p_resultado ELSE NULL END,
        v_modo,
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
-- 4. MODIFICAR
--
-- El modo no se toca: dice cómo nació la gestión, y corregir el asunto tres
-- días después no cambia eso. Sólo se rellena si está vacío, que es el caso de
-- lo registrado antes de que existiera la columna.
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
    p_modo_registro    varchar     DEFAULT NULL,
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
    v_modo   varchar;
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

    v_modo := UPPER(NULLIF(TRIM(COALESCE(p_modo_registro, '')), ''));
    IF v_modo IS NOT NULL AND v_modo NOT IN ('AHORA', 'YA_HECHA', 'PROGRAMADA') THEN
        RAISE EXCEPTION 'El modo de registro no es válido' USING ERRCODE = 'P0022';
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
           -- Primero lo que ya tenía: el modo es de cuando nació
           modo_registro    = COALESCE(modo_registro, v_modo),
           updated_by       = p_usuario_login,
           updated_at       = v_fecha
     WHERE id = p_id;

    PERFORM set_config('app.datos_anteriores', '', true);

    RETURN jsonb_build_object('success', true, 'message', 'Gestión actualizada exitosamente', 'data', ventas.fn_gestiones_json(p_id));
END;
$function$;

-- ---------------------------------------------------------------------------
-- 5. CERRAR
--
-- Igual que antes, pero el seguimiento que deja programado nace PROGRAMADA y
-- ahora lo dice. Se vuelve a crear entera porque llama a fn_gestiones_crear de
-- forma posicional y a ésa le entró un parámetro.
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
            'PROGRAMADA',
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
-- 6. QUE SALGA EN EL JSON
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
        -- Cómo nació: AHORA, YA_HECHA o PROGRAMADA (NULL en lo anterior)
        'modo_registro',     g.modo_registro,
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

-- ===========================================================================
-- PARA LOS REPORTES DE MÁS ADELANTE
-- ===========================================================================
--   SELECT modo_registro, COUNT(*)
--     FROM ventas.gestiones
--    WHERE created_at >= date_trunc('month', CURRENT_DATE)
--    GROUP BY 1;
--
-- Y para ver quién anota en caliente y quién de memoria al final del día:
--
--   SELECT g.created_by,
--          COUNT(*) FILTER (WHERE g.modo_registro = 'AHORA')      AS en_caliente,
--          COUNT(*) FILTER (WHERE g.modo_registro = 'YA_HECHA')   AS anotadas_despues,
--          COUNT(*) FILTER (WHERE g.modo_registro = 'PROGRAMADA') AS desde_la_agenda
--     FROM ventas.gestiones g
--    WHERE g.modo_registro IS NOT NULL
--    GROUP BY 1 ORDER BY 2 DESC;
-- ===========================================================================
