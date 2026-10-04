-- ============================================================================
-- VENTAS: los responsables pasan de EMPLEADOS a USUARIOS
--
-- El problema, tal cual se encontró: al entrar con un usuario que no registra
-- gestiones, su agenda y sus pendientes salían vacíos. La causa son dos cosas
-- distintas:
--
--   1. Los clientes se asignaban a rh.empleados, que es la ficha laboral y no
--      entra al sistema. Hoy hay 13 usuarios activos y 3 empleados, sin una
--      sola coincidencia por correo ni por nombre: son dos poblaciones
--      distintas. A PASTUDILLO no había forma de asignarle nada.
--
--   2. La agenda no miraba la asignación: filtraba por gestiones.created_by,
--      o sea «lo que yo registré», no «lo que me toca». Aunque se asignara
--      bien, la agenda habría seguido vacía.
--
-- Esta migración arregla las dos. El empleado sigue existiendo para recursos
-- humanos (contrato, cargo, marcaciones); lo que cambia es que el TRABAJO del
-- CRM se asigna a quien puede entrar a hacerlo.
--
-- Las columnas viejas NO se borran: se quedan como histórico y las nuevas
-- nacen vacías, así que al terminar hay que reasignar los clientes desde la
-- pestaña Asignación. Nada se pierde y se puede volver atrás.
--
-- Idempotente: se puede volver a correr.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Las columnas nuevas
-- ---------------------------------------------------------------------------

-- El puente opcional para informes de recursos humanos: un usuario PUEDE ser
-- un empleado, pero no tiene por qué (un consultor externo, el administrador).
ALTER TABLE seguridad.users ADD COLUMN IF NOT EXISTS empleado_id bigint;
COMMENT ON COLUMN seguridad.users.empleado_id IS 'Ficha de recursos humanos de este usuario, si la tiene. Opcional: sirve para cruzar por cargo o departamento, no para asignar trabajo.';

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_users_empleado') THEN
        ALTER TABLE seguridad.users
            ADD CONSTRAINT fk_users_empleado FOREIGN KEY (empleado_id) REFERENCES rh.empleados(id);
    END IF;
END
$$;
CREATE INDEX IF NOT EXISTS ix_users_empleado ON seguridad.users (empleado_id) WHERE empleado_id IS NOT NULL;

-- El vendedor del cliente
ALTER TABLE ventas.clientes ADD COLUMN IF NOT EXISTS vendedor_usuario_id bigint;
COMMENT ON COLUMN ventas.clientes.vendedor_usuario_id IS 'Usuario que atiende al cliente';
COMMENT ON COLUMN ventas.clientes.vendedor_id IS 'HISTÓRICO: el empleado que lo atendía antes de pasar los responsables a usuarios';

-- Los tres papeles
ALTER TABLE ventas.asignaciones_clientes ADD COLUMN IF NOT EXISTS usuario_anterior_id bigint;
ALTER TABLE ventas.asignaciones_clientes ADD COLUMN IF NOT EXISTS usuario_nuevo_id    bigint;
COMMENT ON COLUMN ventas.asignaciones_clientes.empleado_anterior_id IS 'HISTÓRICO: reasignaciones anteriores al cambio a usuarios';
COMMENT ON COLUMN ventas.asignaciones_clientes.empleado_nuevo_id    IS 'HISTÓRICO: reasignaciones anteriores al cambio a usuarios';

-- El responsable de cada gestión
ALTER TABLE ventas.gestiones ADD COLUMN IF NOT EXISTS usuario_id bigint;
COMMENT ON COLUMN ventas.gestiones.usuario_id IS 'Usuario al que le toca esta gestión; es por lo que filtra la agenda';
COMMENT ON COLUMN ventas.gestiones.empleado_id IS 'HISTÓRICO: el empleado responsable antes del cambio a usuarios';

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_clientes_vendedor_usuario') THEN
        ALTER TABLE ventas.clientes ADD CONSTRAINT fk_clientes_vendedor_usuario
            FOREIGN KEY (vendedor_usuario_id) REFERENCES seguridad.users(id);
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_asignaciones_usuario_anterior') THEN
        ALTER TABLE ventas.asignaciones_clientes ADD CONSTRAINT fk_asignaciones_usuario_anterior
            FOREIGN KEY (usuario_anterior_id) REFERENCES seguridad.users(id);
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_asignaciones_usuario_nuevo') THEN
        ALTER TABLE ventas.asignaciones_clientes ADD CONSTRAINT fk_asignaciones_usuario_nuevo
            FOREIGN KEY (usuario_nuevo_id) REFERENCES seguridad.users(id);
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_gestiones_usuario') THEN
        ALTER TABLE ventas.gestiones ADD CONSTRAINT fk_gestiones_usuario
            FOREIGN KEY (usuario_id) REFERENCES seguridad.users(id);
    END IF;
END
$$;

-- La agenda filtra por aquí en cada carga de «Lo que toca hacer»
CREATE INDEX IF NOT EXISTS ix_gestiones_usuario_pendiente
    ON ventas.gestiones (usuario_id, fecha_programada) WHERE estado = 'PENDIENTE';
CREATE INDEX IF NOT EXISTS ix_clientes_vendedor_usuario
    ON ventas.clientes (vendedor_usuario_id) WHERE deleted_at IS NULL;

-- ---------------------------------------------------------------------------
-- 2. El nombre de un usuario, en un solo sitio
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ventas.fn_nombre_usuario(p_id bigint)
RETURNS text
LANGUAGE sql
STABLE
SECURITY DEFINER
AS $function$
    -- Si no tiene nombre y apellido cargados, al menos que se vea el login:
    -- un hueco en blanco en la pantalla no le dice nada a nadie
    SELECT COALESCE(NULLIF(TRIM(COALESCE(u.name, '') || ' ' || COALESCE(u.surname, '')), ''), u.login_user)
      FROM seguridad.users u WHERE u.id = p_id
$function$;

-- ---------------------------------------------------------------------------
-- 3. Fuera las versiones viejas de lo que cambia de firma
--    (renombrar un parámetro no lo permite CREATE OR REPLACE)
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    v_firma text;
BEGIN
    FOR v_firma IN
        SELECT 'ventas.' || p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')'
          FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
         WHERE n.nspname = 'ventas' AND p.prokind = 'f'
           AND p.proname IN ('fn_gestiones_crear', 'fn_gestiones_modificar',
                             'fn_gestiones_agenda', 'fn_gestiones_agenda_paginado',
                             'fn_clientes_reasignar')
    LOOP
        EXECUTE 'DROP FUNCTION IF EXISTS ' || v_firma || ' CASCADE';
        RAISE NOTICE 'Borrada %', v_firma;
    END LOOP;
END
$$;

-- ---------------------------------------------------------------------------
-- 4. Las funciones
-- ---------------------------------------------------------------------------
-- ---- el nombre de quien atiende ----



-- ---- gestiones ----

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
        -- A quién le toca. usuario_* es lo vigente; empleado_* se queda por
        -- las gestiones anteriores al cambio de modelo, para que su
        -- RESPONSABLE se siga pudiendo leer. La pantalla usa responsable_nombre,
        -- que sirve para las de antes y las de ahora.
        'usuario_id',        g.usuario_id,
        'usuario_nombre',    ventas.fn_nombre_usuario(g.usuario_id),
        'empleado_id',       g.empleado_id,
        'empleado_nombre',   (SELECT TRIM(COALESCE(e.nombres, '') || ' ' || COALESCE(e.apellidos, ''))
                                FROM rh.empleados e WHERE e.id = g.empleado_id),
        'responsable_nombre', COALESCE(ventas.fn_nombre_usuario(g.usuario_id),
                                       (SELECT TRIM(COALESCE(e.nombres, '') || ' ' || COALESCE(e.apellidos, ''))
                                          FROM rh.empleados e WHERE e.id = g.empleado_id)),
        'contacto_id',       g.contacto_id,
        'contacto_nombre',   (SELECT cc.nombres FROM ventas.contactos_clientes cc WHERE cc.id = g.contacto_id),
        'tipo',              g.tipo,
        'estado',            g.estado,
        'prioridad',         g.prioridad,
        'asunto',            g.asunto,
        -- Para agrupar en informes; el texto de arriba es el que se vio ese día
        'asunto_id',         g.asunto_id,
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


CREATE OR REPLACE FUNCTION ventas.fn_gestiones_crear(p_cliente_id bigint, p_tipo character varying, p_estado character varying, p_asunto character varying, p_asunto_id bigint DEFAULT NULL::bigint, p_nota text DEFAULT NULL::text, p_usuario_responsable_id bigint DEFAULT NULL::bigint, p_contacto_id bigint DEFAULT NULL::bigint, p_telefono character varying DEFAULT NULL::character varying, p_prioridad character varying DEFAULT 'MEDIA'::character varying, p_fecha_programada timestamp with time zone DEFAULT NULL::timestamp with time zone, p_fecha_realizada timestamp with time zone DEFAULT NULL::timestamp with time zone, p_duracion_minutos integer DEFAULT NULL::integer, p_resultado character varying DEFAULT NULL::character varying, p_modo_registro character varying DEFAULT NULL::character varying, p_gestion_origen_id bigint DEFAULT NULL::bigint, p_usuario_id bigint DEFAULT NULL::bigint, p_usuario_login character varying DEFAULT NULL::character varying, p_usuario_nombre character varying DEFAULT NULL::character varying, p_ip_address inet DEFAULT NULL::inet, p_user_agent text DEFAULT NULL::text, p_request_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'ventas', 'rh', 'auditoria'
AS $function$
DECLARE
    v_id       bigint;
    v_estado   varchar := COALESCE(NULLIF(TRIM(COALESCE(p_estado, '')), ''), 'REALIZADA');
    v_tipo     varchar := UPPER(COALESCE(NULLIF(TRIM(COALESCE(p_tipo, '')), ''), 'LLAMADA'));
    v_fecha    timestamptz := CURRENT_TIMESTAMP;
    v_modo     varchar;
    v_asunto   varchar := TRIM(COALESCE(p_asunto, ''));
    v_tipo_cat varchar;
BEGIN
    PERFORM ventas.fn_gestiones_contexto(p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    IF NOT EXISTS (SELECT 1 FROM ventas.clientes WHERE id = p_cliente_id AND deleted_at IS NULL) THEN
        RAISE EXCEPTION 'El cliente no existe o está en la papelera' USING ERRCODE = 'P0013';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM ventas.gestiones_tipos WHERE codigo = v_tipo) THEN
        RAISE EXCEPTION 'El tipo de gestión % no está en el catálogo', v_tipo USING ERRCODE = 'P0013';
    END IF;

    -- El asunto del catálogo manda sobre el texto que venga
    IF p_asunto_id IS NOT NULL THEN
        SELECT a.nombre, t.codigo INTO v_asunto, v_tipo_cat
          FROM ventas.gestiones_asuntos a
          JOIN ventas.gestiones_tipos t ON t.id = a.tipo_id
         WHERE a.id = p_asunto_id;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'El asunto indicado no existe' USING ERRCODE = 'P0013';
        END IF;
        IF v_tipo_cat <> v_tipo THEN
            RAISE EXCEPTION 'Ese asunto es del tipo %, no de %', v_tipo_cat, v_tipo USING ERRCODE = 'P0022';
        END IF;
    END IF;

    IF length(v_asunto) < 3 THEN
        RAISE EXCEPTION 'El asunto es obligatorio (mínimo 3 caracteres)' USING ERRCODE = 'P0001';
    END IF;
    -- El responsable es un USUARIO: es quien entra al sistema y a quien le
    -- aparece en su agenda. El empleado es la ficha de recursos humanos y no
    -- tiene por qué existir (ni al revés).
    IF p_usuario_responsable_id IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM seguridad.users WHERE id = p_usuario_responsable_id AND deleted_at IS NULL) THEN
        RAISE EXCEPTION 'El usuario responsable indicado no existe' USING ERRCODE = 'P0016';
    END IF;
    IF v_estado = 'PENDIENTE' AND p_fecha_programada IS NULL THEN
        RAISE EXCEPTION 'Una gestión programada necesita fecha y hora' USING ERRCODE = 'P0022';
    END IF;
    IF v_estado = 'REALIZADA' AND COALESCE(p_fecha_realizada, v_fecha) > v_fecha + interval '1 minute' THEN
        RAISE EXCEPTION 'Una gestión realizada no puede tener fecha futura' USING ERRCODE = 'P0022';
    END IF;

    -- El modo lo manda la pantalla. Quien no lo mande (un seguimiento creado
    -- por el cierre, una integración) deja que se deduzca del estado.
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
        cliente_id, usuario_id, contacto_id, tipo, estado, prioridad, asunto, asunto_id, nota, telefono,
        fecha_programada, fecha_realizada, duracion_minutos, resultado, modo_registro, gestion_origen_id,
        created_by, updated_by, created_at, updated_at
    ) VALUES (
        p_cliente_id,
        p_usuario_responsable_id,
        p_contacto_id,
        v_tipo,
        v_estado,
        COALESCE(NULLIF(TRIM(COALESCE(p_prioridad, '')), ''), 'MEDIA'),
        v_asunto,
        p_asunto_id,
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


CREATE OR REPLACE FUNCTION ventas.fn_gestiones_modificar(p_id bigint, p_tipo character varying, p_estado character varying, p_asunto character varying, p_asunto_id bigint DEFAULT NULL::bigint, p_nota text DEFAULT NULL::text, p_usuario_responsable_id bigint DEFAULT NULL::bigint, p_contacto_id bigint DEFAULT NULL::bigint, p_telefono character varying DEFAULT NULL::character varying, p_prioridad character varying DEFAULT 'MEDIA'::character varying, p_fecha_programada timestamp with time zone DEFAULT NULL::timestamp with time zone, p_fecha_realizada timestamp with time zone DEFAULT NULL::timestamp with time zone, p_duracion_minutos integer DEFAULT NULL::integer, p_resultado character varying DEFAULT NULL::character varying, p_modo_registro character varying DEFAULT NULL::character varying, p_usuario_id bigint DEFAULT NULL::bigint, p_usuario_login character varying DEFAULT NULL::character varying, p_usuario_nombre character varying DEFAULT NULL::character varying, p_ip_address inet DEFAULT NULL::inet, p_user_agent text DEFAULT NULL::text, p_request_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'ventas', 'rh', 'auditoria'
AS $function$
DECLARE
    v_actual   ventas.gestiones%ROWTYPE;
    v_estado   varchar;
    v_tipo     varchar;
    v_fecha    timestamptz := CURRENT_TIMESTAMP;
    v_antes    jsonb;
    v_modo     varchar;
    v_asunto   varchar;
    v_tipo_cat varchar;
BEGIN
    PERFORM ventas.fn_gestiones_contexto(p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    SELECT * INTO v_actual FROM ventas.gestiones WHERE id = p_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'La gestión no existe' USING ERRCODE = 'P0013';
    END IF;

    v_estado := COALESCE(NULLIF(TRIM(COALESCE(p_estado, '')), ''), v_actual.estado);
    v_tipo   := UPPER(COALESCE(NULLIF(TRIM(COALESCE(p_tipo, '')), ''), v_actual.tipo));
    v_asunto := TRIM(COALESCE(p_asunto, ''));

    IF NOT EXISTS (SELECT 1 FROM ventas.gestiones_tipos WHERE codigo = v_tipo) THEN
        RAISE EXCEPTION 'El tipo de gestión % no está en el catálogo', v_tipo USING ERRCODE = 'P0013';
    END IF;

    IF p_asunto_id IS NOT NULL THEN
        SELECT a.nombre, t.codigo INTO v_asunto, v_tipo_cat
          FROM ventas.gestiones_asuntos a
          JOIN ventas.gestiones_tipos t ON t.id = a.tipo_id
         WHERE a.id = p_asunto_id;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'El asunto indicado no existe' USING ERRCODE = 'P0013';
        END IF;
        IF v_tipo_cat <> v_tipo THEN
            RAISE EXCEPTION 'Ese asunto es del tipo %, no de %', v_tipo_cat, v_tipo USING ERRCODE = 'P0022';
        END IF;
    END IF;

    IF length(v_asunto) < 3 THEN
        RAISE EXCEPTION 'El asunto es obligatorio (mínimo 3 caracteres)' USING ERRCODE = 'P0001';
    END IF;
    IF p_usuario_responsable_id IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM seguridad.users WHERE id = p_usuario_responsable_id AND deleted_at IS NULL) THEN
        RAISE EXCEPTION 'El usuario responsable indicado no existe' USING ERRCODE = 'P0016';
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
       SET tipo             = v_tipo,
           estado           = v_estado,
           prioridad        = COALESCE(NULLIF(TRIM(COALESCE(p_prioridad, '')), ''), prioridad),
           asunto           = v_asunto,
           asunto_id        = COALESCE(p_asunto_id, asunto_id),
           nota             = NULLIF(TRIM(COALESCE(p_nota, '')), ''),
           telefono         = NULLIF(TRIM(COALESCE(p_telefono, '')), ''),
           usuario_id       = p_usuario_responsable_id,
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


CREATE OR REPLACE FUNCTION ventas.fn_gestiones_cerrar(p_id bigint, p_resultado character varying, p_nota text DEFAULT NULL::text, p_duracion_minutos integer DEFAULT NULL::integer, p_fecha_realizada timestamp with time zone DEFAULT NULL::timestamp with time zone, p_siguiente jsonb DEFAULT NULL::jsonb, p_usuario_id bigint DEFAULT NULL::bigint, p_usuario_login character varying DEFAULT NULL::character varying, p_usuario_nombre character varying DEFAULT NULL::character varying, p_ip_address inet DEFAULT NULL::inet, p_user_agent text DEFAULT NULL::text, p_request_id uuid DEFAULT NULL::uuid)
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
    v_asunto_id bigint;
    v_tipo_sig  varchar;
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
        v_tipo_sig  := UPPER(COALESCE(NULLIF(p_siguiente->>'tipo', ''), v_actual.tipo));
        v_asunto_id := COALESCE(NULLIF(p_siguiente->>'asunto_id', '')::bigint, v_actual.asunto_id);

        -- Si el seguimiento cambia de tipo, el asunto heredado ya no vale: es
        -- de otro tipo y la función lo rechazaría. Se va con texto generado.
        IF v_asunto_id IS NOT NULL AND NOT EXISTS (
            SELECT 1 FROM ventas.gestiones_asuntos a
              JOIN ventas.gestiones_tipos t ON t.id = a.tipo_id
             WHERE a.id = v_asunto_id AND t.codigo = v_tipo_sig
        ) THEN
            v_asunto_id := NULL;
        END IF;

        v_nueva := ventas.fn_gestiones_crear(
            v_actual.cliente_id,
            v_tipo_sig,
            'PENDIENTE',
            COALESCE(NULLIF(p_siguiente->>'asunto', ''), 'Seguimiento: ' || v_actual.asunto),
            v_asunto_id,
            NULLIF(p_siguiente->>'nota', ''),
            v_actual.usuario_id,
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


CREATE OR REPLACE FUNCTION ventas.fn_gestiones_agenda(p_usuario_id bigint DEFAULT NULL::bigint, p_usuario_login character varying DEFAULT NULL::character varying, p_desde date DEFAULT NULL::date, p_hasta date DEFAULT NULL::date, p_solo_vencidas boolean DEFAULT false, p_limite integer DEFAULT 200)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    v_data     jsonb;
    v_total    bigint;
    v_vencidas bigint;
    v_hoy      bigint;
BEGIN
    -- 1. Los contadores salen del mismo filtro, sin el límite
    SELECT COUNT(*),
           COUNT(*) FILTER (WHERE g.fecha_programada < CURRENT_TIMESTAMP),
           COUNT(*) FILTER (WHERE g.fecha_programada::date = CURRENT_DATE)
      INTO v_total, v_vencidas, v_hoy
      FROM ventas.gestiones g
      JOIN ventas.clientes c ON c.id = g.cliente_id AND c.deleted_at IS NULL
     WHERE g.estado = 'PENDIENTE'
       AND (p_usuario_id    IS NULL OR g.usuario_id = p_usuario_id)
       -- Lo que ME TOCA, no lo que yo registré: antes comparaba con created_by
       -- y por eso quien no registraba gestiones veía la agenda vacía aunque
       -- tuviera clientes asignados.
       AND (p_usuario_login IS NULL OR g.usuario_id = (
            SELECT u.id FROM seguridad.users u
             WHERE UPPER(u.login_user) = UPPER(p_usuario_login) AND u.deleted_at IS NULL))
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
           AND (p_usuario_id    IS NULL OR g.usuario_id = p_usuario_id)
           AND (p_usuario_login IS NULL OR g.usuario_id = (
                SELECT u.id FROM seguridad.users u
                 WHERE UPPER(u.login_user) = UPPER(p_usuario_login) AND u.deleted_at IS NULL))
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
            'mostradas', jsonb_array_length(v_data)
        )
    );
EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object('success', false, 'message', 'Error al obtener la agenda: ' || SQLERRM, 'error_code', SQLSTATE);
END;
$function$;


CREATE OR REPLACE FUNCTION ventas.fn_gestiones_agenda_paginado(p_usuario_id bigint DEFAULT NULL::bigint, p_usuario_login character varying DEFAULT NULL::character varying, p_desde date DEFAULT NULL::date, p_hasta date DEFAULT NULL::date, p_solo_vencidas boolean DEFAULT false, p_search text DEFAULT ''::text, p_page integer DEFAULT 1, p_per_page integer DEFAULT 15)
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
BEGIN
    v_patron := CASE WHEN v_busca IS NULL THEN NULL ELSE '%' || lower(v_busca) || '%' END;

    -- 1. Los contadores, sobre todo el filtro (no sobre la página)
    SELECT COUNT(*),
           COUNT(*) FILTER (WHERE g.fecha_programada < CURRENT_TIMESTAMP),
           COUNT(*) FILTER (WHERE g.fecha_programada::date = CURRENT_DATE)
      INTO v_total, v_vencidas, v_hoy
      FROM ventas.gestiones g
      JOIN ventas.clientes c ON c.id = g.cliente_id AND c.deleted_at IS NULL
     WHERE g.estado = 'PENDIENTE'
       AND (p_usuario_id    IS NULL OR g.usuario_id = p_usuario_id)
       -- Lo que ME TOCA, no lo que yo registré: antes comparaba con created_by
       -- y por eso quien no registraba gestiones veía la agenda vacía aunque
       -- tuviera clientes asignados.
       AND (p_usuario_login IS NULL OR g.usuario_id = (
            SELECT u.id FROM seguridad.users u
             WHERE UPPER(u.login_user) = UPPER(p_usuario_login) AND u.deleted_at IS NULL))
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
           AND (p_usuario_id    IS NULL OR g.usuario_id = p_usuario_id)
           AND (p_usuario_login IS NULL OR g.usuario_id = (
                SELECT u.id FROM seguridad.users u
                 WHERE UPPER(u.login_user) = UPPER(p_usuario_login) AND u.deleted_at IS NULL))
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
            'mostradas',    jsonb_array_length(v_data)
        )
    );
EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object('success', false, 'message', 'Error al obtener la agenda: ' || SQLERRM, 'error_code', SQLSTATE);
END;
$function$;


-- ---- clientes y asignaciones ----

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
                   'usuario_id', c.vendedor_usuario_id,
                   'usuario_nombre', ventas.fn_nombre_usuario(c.vendedor_usuario_id),
                   'desde', (SELECT to_char(MAX(a.asignado_at), 'YYYY-MM-DD HH24:MI')
                               FROM ventas.asignaciones_clientes a
                              WHERE a.cliente_id = p_cliente_id AND a.rol = 'VENDEDOR'
                                AND a.usuario_nuevo_id IS NOT DISTINCT FROM c.vendedor_usuario_id)
               ) AS fila
          FROM ventas.clientes c WHERE c.id = p_cliente_id

        UNION ALL

        SELECT CASE r.rol WHEN 'COBRADOR' THEN 2 ELSE 3 END, jsonb_build_object(
                   'rol', r.rol,
                   'usuario_id', u.usuario_nuevo_id,
                   'usuario_nombre', ventas.fn_nombre_usuario(u.usuario_nuevo_id),
                   'desde', to_char(u.asignado_at, 'YYYY-MM-DD HH24:MI')
               )
          FROM (VALUES ('COBRADOR'), ('ASISTENTE')) AS r(rol)
          -- La última de ese rol, si la hay; si no, el puesto sale vacío
          LEFT JOIN LATERAL (
              SELECT a.usuario_nuevo_id, a.asignado_at
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
            -- El historial mezcla reasignaciones de antes (empleados) y de
            -- ahora (usuarios): el nombre sale de donde haya, para que una
            -- fila vieja se siga leyendo.
            'usuario_anterior_id',  a.usuario_anterior_id,
            'usuario_nuevo_id',     a.usuario_nuevo_id,
            'empleado_anterior_id', a.empleado_anterior_id,
            'empleado_nuevo_id',    a.empleado_nuevo_id,
            'anterior',             COALESCE(ventas.fn_nombre_usuario(a.usuario_anterior_id),
                                       (SELECT TRIM(COALESCE(e.nombres, '') || ' ' || COALESCE(e.apellidos, ''))
                                          FROM rh.empleados e WHERE e.id = a.empleado_anterior_id)),
            'nuevo',                COALESCE(ventas.fn_nombre_usuario(a.usuario_nuevo_id),
                                       (SELECT TRIM(COALESCE(e.nombres, '') || ' ' || COALESCE(e.apellidos, ''))
                                          FROM rh.empleados e WHERE e.id = a.empleado_nuevo_id)),
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


CREATE OR REPLACE FUNCTION ventas.fn_clientes_reasignar(p_cliente_id bigint, p_responsable_id bigint, p_motivo text DEFAULT NULL::text, p_mover_agenda boolean DEFAULT true, p_rol character varying DEFAULT 'VENDEDOR'::character varying, p_usuario_id bigint DEFAULT NULL::bigint, p_usuario_login character varying DEFAULT NULL::character varying, p_usuario_nombre character varying DEFAULT NULL::character varying, p_ip_address inet DEFAULT NULL::inet, p_user_agent text DEFAULT NULL::text, p_request_id uuid DEFAULT NULL::uuid)
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
        SELECT c.vendedor_usuario_id INTO v_anterior FROM ventas.clientes c WHERE c.id = p_cliente_id;
    ELSE
        SELECT a.usuario_nuevo_id INTO v_anterior
          FROM ventas.asignaciones_clientes a
         WHERE a.cliente_id = p_cliente_id AND a.rol = v_rol
         ORDER BY a.asignado_at DESC, a.id DESC LIMIT 1;
    END IF;

    -- Se asigna a un USUARIO, que es quien entra al sistema y a quien le va a
    -- aparecer el cliente en su agenda
    IF p_responsable_id IS NOT NULL THEN
        v_nuevo := ventas.fn_nombre_usuario(p_responsable_id);
        IF v_nuevo IS NULL THEN
            RAISE EXCEPTION 'El usuario indicado no existe' USING ERRCODE = 'P0016';
        END IF;
    END IF;

    IF v_anterior IS NOT DISTINCT FROM p_responsable_id THEN
        RAISE EXCEPTION 'El cliente ya tiene a esa persona en ese papel' USING ERRCODE = 'P0001';
    END IF;

    -- Sólo el vendedor vive en la ficha del cliente
    IF v_esVendedor THEN
        v_antes := (ventas.fn_clientes_obtener(p_cliente_id))->'data';
        PERFORM set_config('app.datos_anteriores', v_antes::text, true);
        PERFORM set_config('app.datos_nuevos', (v_antes || jsonb_build_object('vendedor_usuario_id', p_responsable_id, 'vendedor_nombre', v_nuevo))::text, true);

        UPDATE ventas.clientes
           SET vendedor_usuario_id = p_responsable_id,
               updated_by  = COALESCE(p_usuario_login, updated_by),
               updated_at  = v_fecha
         WHERE id = p_cliente_id;

        PERFORM set_config('app.datos_anteriores', '', true);
        PERFORM set_config('app.datos_nuevos', '', true);
    END IF;

    INSERT INTO ventas.asignaciones_clientes (cliente_id, rol, usuario_anterior_id, usuario_nuevo_id, motivo, asignado_at, created_by, updated_by)
    VALUES (p_cliente_id, v_rol, v_anterior, p_responsable_id, NULLIF(TRIM(COALESCE(p_motivo, '')), ''), v_fecha, p_usuario_login, p_usuario_login);

    -- La agenda se mueve sólo con el vendedor: las gestiones son suyas, no de
    -- quien cobra ni de quien coordina.
    IF p_mover_agenda AND v_esVendedor THEN
        UPDATE ventas.gestiones
           SET usuario_id = p_responsable_id, updated_by = p_usuario_login, updated_at = v_fecha
         WHERE cliente_id = p_cliente_id AND estado = 'PENDIENTE'
           AND usuario_id IS DISTINCT FROM p_responsable_id;
        GET DIAGNOSTICS v_movidas = ROW_COUNT;
    END IF;

    RETURN jsonb_build_object(
        'success', true,
        'message', CASE
            WHEN p_responsable_id IS NULL THEN 'Se quitó el responsable del cliente'
            ELSE v_nombre || ' ahora lo atiende ' || v_nuevo
        END || CASE WHEN v_movidas > 0 THEN ' (' || v_movidas || ' gestión(es) pendientes se movieron)' ELSE '' END,
        'data', jsonb_build_object(
            'cliente_id', p_cliente_id,
            'rol', v_rol,
            'usuario_id', p_responsable_id,
            'usuario_nombre', v_nuevo,
            'gestiones_movidas', v_movidas
        )
    );
END;
$function$;


-- ---- el vendedor del cliente ----

CREATE OR REPLACE FUNCTION ventas.fn_clientes_validar(p_id bigint, p_tipo_cliente character varying, p_numero_identificacion character varying, p_razon_social character varying, p_nombres character varying, p_apellidos character varying, p_email character varying, p_email_alterno character varying, p_vendedor_id bigint, p_limite_credito numeric, p_dias_credito integer, p_descuento numeric)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    v_en_papelera boolean;
BEGIN
    IF COALESCE(p_tipo_cliente, '') NOT IN ('PERSONA', 'EMPRESA') THEN
        RAISE EXCEPTION 'El tipo de cliente debe ser PERSONA o EMPRESA' USING ERRCODE = 'P0001';
    END IF;

    IF NULLIF(TRIM(COALESCE(p_numero_identificacion, '')), '') IS NULL THEN
        RAISE EXCEPTION 'El número de identificación es obligatorio' USING ERRCODE = 'P0001';
    END IF;

    IF p_tipo_cliente = 'EMPRESA' THEN
        IF length(TRIM(COALESCE(p_razon_social, ''))) < 2 THEN
            RAISE EXCEPTION 'La razón social es obligatoria (mínimo 2 caracteres)' USING ERRCODE = 'P0001';
        END IF;
    ELSE
        IF length(TRIM(COALESCE(p_nombres, ''))) < 2 THEN
            RAISE EXCEPTION 'Los nombres son obligatorios (mínimo 2 caracteres)' USING ERRCODE = 'P0001';
        END IF;
        IF length(TRIM(COALESCE(p_apellidos, ''))) < 2 THEN
            RAISE EXCEPTION 'Los apellidos son obligatorios (mínimo 2 caracteres)' USING ERRCODE = 'P0001';
        END IF;
    END IF;

    IF NULLIF(TRIM(COALESCE(p_email, '')), '') IS NOT NULL
       AND TRIM(p_email) !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' THEN
        RAISE EXCEPTION 'El correo electrónico no es válido' USING ERRCODE = 'P0003';
    END IF;

    IF NULLIF(TRIM(COALESCE(p_email_alterno, '')), '') IS NOT NULL
       AND TRIM(p_email_alterno) !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' THEN
        RAISE EXCEPTION 'El correo alterno no es válido' USING ERRCODE = 'P0003';
    END IF;

    -- El índice único cuenta también a los de la papelera, así que se distingue
    SELECT (deleted_at IS NOT NULL) INTO v_en_papelera
      FROM ventas.clientes
     WHERE UPPER(numero_identificacion) = UPPER(TRIM(p_numero_identificacion))
       AND (p_id IS NULL OR id <> p_id)
     LIMIT 1;

    IF FOUND THEN
        IF v_en_papelera THEN
            RAISE EXCEPTION 'Ya existe un cliente con esa identificación en la papelera de reciclaje. Restáurelo o elimínelo definitivamente.' USING ERRCODE = 'P0006';
        ELSE
            RAISE EXCEPTION 'Ya existe un cliente con esa identificación' USING ERRCODE = 'P0006';
        END IF;
    END IF;

    -- El vendedor es un usuario del sistema, no una ficha de recursos humanos
    IF p_vendedor_id IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM seguridad.users WHERE id = p_vendedor_id AND deleted_at IS NULL) THEN
        RAISE EXCEPTION 'El vendedor asignado no existe' USING ERRCODE = 'P0016';
    END IF;

    IF COALESCE(p_limite_credito, 0) < 0 THEN
        RAISE EXCEPTION 'El límite de crédito no puede ser negativo' USING ERRCODE = 'P0015';
    END IF;
    IF COALESCE(p_dias_credito, 0) < 0 THEN
        RAISE EXCEPTION 'Los días de crédito no pueden ser negativos' USING ERRCODE = 'P0015';
    END IF;
    IF COALESCE(p_descuento, 0) < 0 OR COALESCE(p_descuento, 0) > 100 THEN
        RAISE EXCEPTION 'El descuento debe estar entre 0 y 100' USING ERRCODE = 'P0015';
    END IF;
END;
$function$;


CREATE OR REPLACE FUNCTION ventas.fn_clientes_obtener(p_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    v_data jsonb;
BEGIN
    SELECT jsonb_build_object(
        'id',                    c.id,
        'tipo_cliente',          c.tipo_cliente,
        'numero_identificacion', c.numero_identificacion,
        'tipo_identificacion',   c.tipo_identificacion,
        'razon_social',          c.razon_social,
        'nombre_comercial',      c.nombre_comercial,
        'nombres',               c.nombres,
        'apellidos',             c.apellidos,
        'nombre_completo',       c.nombre_completo,
        'email',                 c.email,
        'email_alterno',         c.email_alterno,
        'telefono',              c.telefono,
        'celular',               c.celular,
        'sitio_web',             c.sitio_web,
        'fecha_nacimiento',      to_char(c.fecha_nacimiento, 'YYYY-MM-DD'),
        'genero',                c.genero,
        'direccion',             c.direccion,
        'provincia',             c.provincia,
        'canton',                c.canton,
        'parroquia',             c.parroquia,
        'calle_principal',       c.calle_principal,
        'calle_secundaria',      c.calle_secundaria,
        'numeracion',            c.numeracion,
        'ubicacion',             c.ubicacion,
        'codigo_postal',         c.codigo_postal,
        'coordenadas',           c.coordenadas,
        'link_coordenadas',      c.link_coordenadas,
        'url_foto_mapa',         c.url_foto_mapa,
        'url_foto_casa',         c.url_foto_casa,
        -- El vendedor pasó a ser un USUARIO. La clave del json se mantiene
        -- para no tener que tocar las pantallas; lo que lleva dentro es el id
        -- del usuario. El empleado de antes se devuelve aparte por si hiciera
        -- falta rastrearlo.
        'vendedor_id',           c.vendedor_usuario_id,
        'vendedor_nombre',       ventas.fn_nombre_usuario(c.vendedor_usuario_id),
        'vendedor_empleado_id',  c.vendedor_id,
        'forma_pago',            c.forma_pago,
        'limite_credito',        c.limite_credito,
        'dias_credito',          c.dias_credito,
        'descuento',             c.descuento,
        'estado',                c.estado,
        'observaciones',         c.observaciones,
        'foto',                  c.foto,
        'activo',                c.activo,
        'num_contactos',         (SELECT COUNT(*) FROM ventas.contactos_clientes cc WHERE cc.cliente_id = c.id),
        'deleted_at',            to_char(c.deleted_at, 'YYYY-MM-DD HH24:MI:SS'),
        'deleted_by',            c.deleted_by,
        'created_by',            c.created_by,
        'updated_by',            c.updated_by,
        'created_at',            to_char(c.created_at, 'YYYY-MM-DD HH24:MI:SS'),
        'updated_at',            to_char(c.updated_at, 'YYYY-MM-DD HH24:MI:SS')
    ) INTO v_data
    FROM ventas.clientes c
    WHERE c.id = p_id;

    IF v_data IS NULL THEN
        RETURN jsonb_build_object('success', false, 'message', 'Cliente no encontrado', 'error_code', 'CLIENTE_NOT_FOUND', 'data', null);
    END IF;

    RETURN jsonb_build_object('success', true, 'message', 'Cliente obtenido exitosamente', 'data', v_data);
EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object('success', false, 'message', 'Error al obtener el cliente: ' || SQLERRM, 'error_code', SQLSTATE);
END;
$function$;


CREATE OR REPLACE FUNCTION ventas.fn_clientes_listar_paginado(p_page integer DEFAULT 1, p_per_page integer DEFAULT 15, p_search text DEFAULT ''::text, p_estado text DEFAULT NULL::text)
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


CREATE OR REPLACE FUNCTION ventas.fn_clientes_crear(p_tipo_cliente character varying, p_numero_identificacion character varying, p_tipo_identificacion character varying DEFAULT 'CC'::character varying, p_razon_social character varying DEFAULT NULL::character varying, p_nombre_comercial character varying DEFAULT NULL::character varying, p_nombres character varying DEFAULT NULL::character varying, p_apellidos character varying DEFAULT NULL::character varying, p_email character varying DEFAULT NULL::character varying, p_email_alterno character varying DEFAULT NULL::character varying, p_telefono character varying DEFAULT NULL::character varying, p_celular character varying DEFAULT NULL::character varying, p_sitio_web character varying DEFAULT NULL::character varying, p_fecha_nacimiento date DEFAULT NULL::date, p_genero character DEFAULT NULL::bpchar, p_direccion text DEFAULT NULL::text, p_vendedor_id bigint DEFAULT NULL::bigint, p_forma_pago character varying DEFAULT 'EFECTIVO'::character varying, p_limite_credito numeric DEFAULT 0, p_dias_credito integer DEFAULT 0, p_descuento numeric DEFAULT 0, p_estado character varying DEFAULT 'ACTIVO'::character varying, p_observaciones text DEFAULT NULL::text, p_activo boolean DEFAULT true, p_usuario_id bigint DEFAULT NULL::bigint, p_usuario_login character varying DEFAULT NULL::character varying, p_usuario_nombre character varying DEFAULT NULL::character varying, p_ip_address inet DEFAULT NULL::inet, p_user_agent text DEFAULT NULL::text, p_request_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'ventas', 'rh', 'auditoria'
AS $function$
DECLARE
    v_id           bigint;
    v_fecha        timestamptz := CURRENT_TIMESTAMP;
    v_datos_nuevos jsonb;
BEGIN
    -- 1. Contexto de auditoría (lo leen los triggers de ventas.clientes)
    PERFORM set_config('app.usuario_id',     COALESCE(p_usuario_id::text, ''), true);
    PERFORM set_config('app.usuario_login',  COALESCE(p_usuario_login, current_user), true);
    PERFORM set_config('app.usuario_nombre', COALESCE(p_usuario_nombre, current_user), true);
    PERFORM set_config('app.ip_address',     COALESCE(p_ip_address::text, ''), true);
    PERFORM set_config('app.user_agent',     COALESCE(p_user_agent, ''), true);
    PERFORM set_config('app.request_id',     COALESCE(p_request_id::text, ''), true);
    PERFORM set_config('app.modulo',         'ventas.clientes', true);

    -- 2. Reglas
    PERFORM ventas.fn_clientes_validar(
        NULL, p_tipo_cliente, p_numero_identificacion, p_razon_social, p_nombres, p_apellidos,
        p_email, p_email_alterno, p_vendedor_id, p_limite_credito, p_dias_credito, p_descuento
    );

    -- 3. Datos NUEVOS para la auditoría
    v_datos_nuevos := jsonb_build_object(
        'tipo_cliente',          p_tipo_cliente,
        'numero_identificacion', UPPER(TRIM(p_numero_identificacion)),
        'tipo_identificacion',   COALESCE(p_tipo_identificacion, 'CC'),
        'razon_social',          NULLIF(TRIM(COALESCE(p_razon_social, '')), ''),
        'nombre_comercial',      NULLIF(TRIM(COALESCE(p_nombre_comercial, '')), ''),
        'nombres',               NULLIF(TRIM(COALESCE(p_nombres, '')), ''),
        'apellidos',             NULLIF(TRIM(COALESCE(p_apellidos, '')), ''),
        'email',                 NULLIF(LOWER(TRIM(COALESCE(p_email, ''))), ''),
        'vendedor_id',           p_vendedor_id,
        'forma_pago',            COALESCE(p_forma_pago, 'EFECTIVO'),
        'limite_credito',        COALESCE(p_limite_credito, 0),
        'dias_credito',          COALESCE(p_dias_credito, 0),
        'descuento',             COALESCE(p_descuento, 0),
        'estado',                COALESCE(p_estado, 'ACTIVO'),
        'activo',                COALESCE(p_activo, true),
        'created_by',            p_usuario_login,
        'created_at',            to_char(v_fecha, 'YYYY-MM-DD HH24:MI:SS')
    );
    PERFORM set_config('app.datos_nuevos', v_datos_nuevos::text, true);

    -- 4. Insertar
    INSERT INTO ventas.clientes (
        tipo_cliente, numero_identificacion, tipo_identificacion,
        razon_social, nombre_comercial, nombres, apellidos,
        email, email_alterno, telefono, celular, sitio_web,
        fecha_nacimiento, genero, direccion,
        vendedor_usuario_id, forma_pago, limite_credito, dias_credito, descuento,
        estado, observaciones, activo,
        created_by, updated_by, created_at, updated_at
    ) VALUES (
        p_tipo_cliente,
        UPPER(TRIM(p_numero_identificacion)),
        COALESCE(NULLIF(TRIM(COALESCE(p_tipo_identificacion, '')), ''), 'CC'),
        NULLIF(TRIM(COALESCE(p_razon_social, '')), ''),
        NULLIF(TRIM(COALESCE(p_nombre_comercial, '')), ''),
        NULLIF(TRIM(COALESCE(p_nombres, '')), ''),
        NULLIF(TRIM(COALESCE(p_apellidos, '')), ''),
        NULLIF(LOWER(TRIM(COALESCE(p_email, ''))), ''),
        NULLIF(LOWER(TRIM(COALESCE(p_email_alterno, ''))), ''),
        NULLIF(TRIM(COALESCE(p_telefono, '')), ''),
        NULLIF(TRIM(COALESCE(p_celular, '')), ''),
        NULLIF(TRIM(COALESCE(p_sitio_web, '')), ''),
        p_fecha_nacimiento,
        NULLIF(TRIM(COALESCE(p_genero, '')), ''),
        NULLIF(TRIM(COALESCE(p_direccion, '')), ''),
        p_vendedor_id,
        COALESCE(NULLIF(TRIM(COALESCE(p_forma_pago, '')), ''), 'EFECTIVO'),
        COALESCE(p_limite_credito, 0),
        COALESCE(p_dias_credito, 0),
        COALESCE(p_descuento, 0),
        COALESCE(NULLIF(TRIM(COALESCE(p_estado, '')), ''), 'ACTIVO'),
        NULLIF(TRIM(COALESCE(p_observaciones, '')), ''),
        COALESCE(p_activo, true),
        p_usuario_login, p_usuario_login, v_fecha, v_fecha
    )
    RETURNING id INTO v_id;

    PERFORM set_config('app.datos_nuevos', '', true);

    RETURN jsonb_build_object(
        'success', true,
        'message', 'Cliente creado exitosamente',
        'data', (ventas.fn_clientes_obtener(v_id))->'data'
    );

EXCEPTION
    -- Único caso capturado, y se RE-LANZA: manda el índice único
    WHEN unique_violation THEN
        RAISE EXCEPTION 'Ya existe un cliente con esa identificación' USING ERRCODE = 'P0006';
END;
$function$;


CREATE OR REPLACE FUNCTION ventas.fn_clientes_modificar(p_id bigint, p_tipo_cliente character varying, p_numero_identificacion character varying, p_tipo_identificacion character varying DEFAULT 'CC'::character varying, p_razon_social character varying DEFAULT NULL::character varying, p_nombre_comercial character varying DEFAULT NULL::character varying, p_nombres character varying DEFAULT NULL::character varying, p_apellidos character varying DEFAULT NULL::character varying, p_email character varying DEFAULT NULL::character varying, p_email_alterno character varying DEFAULT NULL::character varying, p_telefono character varying DEFAULT NULL::character varying, p_celular character varying DEFAULT NULL::character varying, p_sitio_web character varying DEFAULT NULL::character varying, p_fecha_nacimiento date DEFAULT NULL::date, p_genero character DEFAULT NULL::bpchar, p_direccion text DEFAULT NULL::text, p_vendedor_id bigint DEFAULT NULL::bigint, p_forma_pago character varying DEFAULT 'EFECTIVO'::character varying, p_limite_credito numeric DEFAULT 0, p_dias_credito integer DEFAULT 0, p_descuento numeric DEFAULT 0, p_estado character varying DEFAULT 'ACTIVO'::character varying, p_observaciones text DEFAULT NULL::text, p_activo boolean DEFAULT true, p_usuario_id bigint DEFAULT NULL::bigint, p_usuario_login character varying DEFAULT NULL::character varying, p_usuario_nombre character varying DEFAULT NULL::character varying, p_ip_address inet DEFAULT NULL::inet, p_user_agent text DEFAULT NULL::text, p_request_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'ventas', 'rh', 'auditoria'
AS $function$
DECLARE
    v_actual           ventas.clientes%ROWTYPE;
    v_fecha            timestamptz := CURRENT_TIMESTAMP;
    v_datos_anteriores jsonb;
    v_datos_nuevos     jsonb;
BEGIN
    -- 1. Contexto de auditoría
    PERFORM set_config('app.usuario_id',     COALESCE(p_usuario_id::text, ''), true);
    PERFORM set_config('app.usuario_login',  COALESCE(p_usuario_login, current_user), true);
    PERFORM set_config('app.usuario_nombre', COALESCE(p_usuario_nombre, current_user), true);
    PERFORM set_config('app.ip_address',     COALESCE(p_ip_address::text, ''), true);
    PERFORM set_config('app.user_agent',     COALESCE(p_user_agent, ''), true);
    PERFORM set_config('app.request_id',     COALESCE(p_request_id::text, ''), true);
    PERFORM set_config('app.modulo',         'ventas.clientes', true);

    -- 2. Datos actuales
    SELECT * INTO v_actual FROM ventas.clientes WHERE id = p_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'El cliente no existe' USING ERRCODE = 'P0013';
    END IF;

    -- 3. Reglas
    PERFORM ventas.fn_clientes_validar(
        p_id, p_tipo_cliente, p_numero_identificacion, p_razon_social, p_nombres, p_apellidos,
        p_email, p_email_alterno, p_vendedor_id, p_limite_credito, p_dias_credito, p_descuento
    );

    -- 4. Antes / después para la auditoría
    v_datos_anteriores := jsonb_build_object(
        'id', v_actual.id,
        'tipo_cliente', v_actual.tipo_cliente,
        'numero_identificacion', v_actual.numero_identificacion,
        'tipo_identificacion', v_actual.tipo_identificacion,
        'razon_social', v_actual.razon_social,
        'nombre_comercial', v_actual.nombre_comercial,
        'nombres', v_actual.nombres,
        'apellidos', v_actual.apellidos,
        'email', v_actual.email,
        'email_alterno', v_actual.email_alterno,
        'telefono', v_actual.telefono,
        'celular', v_actual.celular,
        'sitio_web', v_actual.sitio_web,
        'fecha_nacimiento', to_char(v_actual.fecha_nacimiento, 'YYYY-MM-DD'),
        'genero', v_actual.genero,
        'direccion', v_actual.direccion,
        'vendedor_id', v_actual.vendedor_usuario_id,
        'forma_pago', v_actual.forma_pago,
        'limite_credito', v_actual.limite_credito,
        'dias_credito', v_actual.dias_credito,
        'descuento', v_actual.descuento,
        'estado', v_actual.estado,
        'observaciones', v_actual.observaciones,
        'activo', v_actual.activo,
        'updated_by', v_actual.updated_by,
        'updated_at', to_char(v_actual.updated_at, 'YYYY-MM-DD HH24:MI:SS')
    );
    v_datos_nuevos := jsonb_build_object(
        'id', v_actual.id,
        'tipo_cliente', p_tipo_cliente,
        'numero_identificacion', UPPER(TRIM(p_numero_identificacion)),
        'tipo_identificacion', COALESCE(p_tipo_identificacion, 'CC'),
        'razon_social', NULLIF(TRIM(COALESCE(p_razon_social, '')), ''),
        'nombre_comercial', NULLIF(TRIM(COALESCE(p_nombre_comercial, '')), ''),
        'nombres', NULLIF(TRIM(COALESCE(p_nombres, '')), ''),
        'apellidos', NULLIF(TRIM(COALESCE(p_apellidos, '')), ''),
        'email', NULLIF(LOWER(TRIM(COALESCE(p_email, ''))), ''),
        'email_alterno', NULLIF(LOWER(TRIM(COALESCE(p_email_alterno, ''))), ''),
        'telefono', NULLIF(TRIM(COALESCE(p_telefono, '')), ''),
        'celular', NULLIF(TRIM(COALESCE(p_celular, '')), ''),
        'sitio_web', NULLIF(TRIM(COALESCE(p_sitio_web, '')), ''),
        'fecha_nacimiento', to_char(p_fecha_nacimiento, 'YYYY-MM-DD'),
        'genero', NULLIF(TRIM(COALESCE(p_genero, '')), ''),
        'direccion', NULLIF(TRIM(COALESCE(p_direccion, '')), ''),
        'vendedor_id', p_vendedor_id,
        'forma_pago', COALESCE(p_forma_pago, 'EFECTIVO'),
        'limite_credito', COALESCE(p_limite_credito, 0),
        'dias_credito', COALESCE(p_dias_credito, 0),
        'descuento', COALESCE(p_descuento, 0),
        'estado', COALESCE(p_estado, 'ACTIVO'),
        'observaciones', NULLIF(TRIM(COALESCE(p_observaciones, '')), ''),
        'activo', COALESCE(p_activo, true),
        'updated_by', p_usuario_login,
        'updated_at', to_char(v_fecha, 'YYYY-MM-DD HH24:MI:SS')
    );
    PERFORM set_config('app.datos_anteriores', v_datos_anteriores::text, true);
    PERFORM set_config('app.datos_nuevos',     v_datos_nuevos::text, true);

    -- 5. Actualizar (la dirección del mapa y la foto van por sus propias funciones)
    UPDATE ventas.clientes
       SET tipo_cliente          = p_tipo_cliente,
           numero_identificacion = UPPER(TRIM(p_numero_identificacion)),
           tipo_identificacion   = COALESCE(NULLIF(TRIM(COALESCE(p_tipo_identificacion, '')), ''), 'CC'),
           razon_social          = NULLIF(TRIM(COALESCE(p_razon_social, '')), ''),
           nombre_comercial      = NULLIF(TRIM(COALESCE(p_nombre_comercial, '')), ''),
           nombres               = NULLIF(TRIM(COALESCE(p_nombres, '')), ''),
           apellidos             = NULLIF(TRIM(COALESCE(p_apellidos, '')), ''),
           email                 = NULLIF(LOWER(TRIM(COALESCE(p_email, ''))), ''),
           email_alterno         = NULLIF(LOWER(TRIM(COALESCE(p_email_alterno, ''))), ''),
           telefono              = NULLIF(TRIM(COALESCE(p_telefono, '')), ''),
           celular               = NULLIF(TRIM(COALESCE(p_celular, '')), ''),
           sitio_web             = NULLIF(TRIM(COALESCE(p_sitio_web, '')), ''),
           fecha_nacimiento      = p_fecha_nacimiento,
           genero                = NULLIF(TRIM(COALESCE(p_genero, '')), ''),
           direccion             = NULLIF(TRIM(COALESCE(p_direccion, '')), ''),
           vendedor_usuario_id   = p_vendedor_id,
           forma_pago            = COALESCE(NULLIF(TRIM(COALESCE(p_forma_pago, '')), ''), 'EFECTIVO'),
           limite_credito        = COALESCE(p_limite_credito, 0),
           dias_credito          = COALESCE(p_dias_credito, 0),
           descuento             = COALESCE(p_descuento, 0),
           estado                = COALESCE(NULLIF(TRIM(COALESCE(p_estado, '')), ''), 'ACTIVO'),
           observaciones         = NULLIF(TRIM(COALESCE(p_observaciones, '')), ''),
           activo                = COALESCE(p_activo, true),
           updated_by            = p_usuario_login,
           updated_at            = v_fecha
     WHERE id = p_id;

    PERFORM set_config('app.datos_anteriores', '', true);
    PERFORM set_config('app.datos_nuevos', '', true);

    RETURN jsonb_build_object(
        'success', true,
        'message', 'Cliente actualizado exitosamente',
        'data', (ventas.fn_clientes_obtener(p_id))->'data'
    );

EXCEPTION
    WHEN unique_violation THEN
        RAISE EXCEPTION 'Ya existe otro cliente con esa identificación' USING ERRCODE = 'P0006';
END;
$function$;

