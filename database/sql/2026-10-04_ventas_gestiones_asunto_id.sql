-- ===========================================================================
-- LA GESTIÓN GUARDA A QUÉ ASUNTO DEL CATÁLOGO APUNTA
-- ===========================================================================
-- Fecha: 2026-10-03
-- Se aplica DESPUÉS de 2026-10-03_ventas_catalogo_gestiones.sql, que es el que
-- crea las tablas y la columna asunto_id.
--
-- A crear y modificar les entra p_asunto_id. Cuando viene:
--   · se comprueba que el asunto existe y que es de ese tipo —elegir
--     «Cobranza» de LLAMADA y guardar la gestión como VISITA dejaría el
--     informe mintiendo—,
--   · y el texto de la gestión lo pone el catálogo, no quien llama. Así nadie
--     puede mandar un asunto_id y un texto que digan cosas distintas.
--
-- Se deja que NO venga, a propósito: el seguimiento que crea
-- fn_gestiones_cerrar se titula «Seguimiento: …» y ése lo genera el sistema,
-- no lo teclea nadie. Quien sí lo exige siempre es el controlador, que es por
-- donde entra el formulario. Ahí está la regla de «el usuario no escribe el
-- asunto»; aquí abajo está la de «lo que se guarde tiene que ser coherente».
--
-- El tipo también pasa a validarse contra el catálogo, ahora que el CHECK fijo
-- ya no está.
--
-- Idempotente: DROP/CREATE de las funciones.
-- ===========================================================================

-- A crear y modificar les cambia la firma: se borran con todas sus sobrecargas
-- antes de volver a crearlas, o CREATE OR REPLACE dejaría la vieja al lado y
-- una llamada posicional podría caer en ella sin avisar.
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
-- CREAR
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ventas.fn_gestiones_crear(
    p_cliente_id       bigint,
    p_tipo             varchar,
    p_estado           varchar,
    p_asunto           varchar,
    /** Del catálogo (ventas.gestiones_asuntos). Si viene, manda él */
    p_asunto_id        bigint      DEFAULT NULL,
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
        cliente_id, empleado_id, contacto_id, tipo, estado, prioridad, asunto, asunto_id, nota, telefono,
        fecha_programada, fecha_realizada, duracion_minutos, resultado, modo_registro, gestion_origen_id,
        created_by, updated_by, created_at, updated_at
    ) VALUES (
        p_cliente_id,
        p_empleado_id,
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

-- ---------------------------------------------------------------------------
-- MODIFICAR
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ventas.fn_gestiones_modificar(
    p_id               bigint,
    p_tipo             varchar,
    p_estado           varchar,
    p_asunto           varchar,
    p_asunto_id        bigint      DEFAULT NULL,
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
       SET tipo             = v_tipo,
           estado           = v_estado,
           prioridad        = COALESCE(NULLIF(TRIM(COALESCE(p_prioridad, '')), ''), prioridad),
           asunto           = v_asunto,
           asunto_id        = COALESCE(p_asunto_id, asunto_id),
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
-- CERRAR
--
-- El seguimiento hereda el asunto_id de la gestión que se cierra: es el mismo
-- tema, y así «Seguimiento: Cobranza» cuenta en los informes bajo Cobranza en
-- vez de quedarse fuera por no tener asunto del catálogo.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ventas.fn_gestiones_cerrar(
    p_id                bigint,
    p_resultado         varchar,
    p_nota              text        DEFAULT NULL,
    p_duracion_minutos  integer     DEFAULT NULL,
    p_fecha_realizada   timestamptz DEFAULT NULL,
    /** { "fecha": "...", "asunto": "...", "asunto_id": 12, "tipo": "...", "prioridad": "...", "nota": "..." } o null */
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
-- QUE SALGA EN EL JSON
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

-- ===========================================================================
-- PARA LOS INFORMES
-- ===========================================================================
--   SELECT t.nombre AS tipo, a.nombre AS asunto, COUNT(*) AS veces
--     FROM ventas.gestiones g
--     JOIN ventas.gestiones_asuntos a ON a.id = g.asunto_id
--     JOIN ventas.gestiones_tipos   t ON t.id = a.tipo_id
--    WHERE g.created_at >= date_trunc('month', CURRENT_DATE)
--    GROUP BY 1, 2 ORDER BY 3 DESC;
-- ===========================================================================
