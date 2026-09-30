-- ===========================================================================
-- PRESENCIA: «En línea / Fuera de línea», de verdad
--
-- El menú de la cabecera tenía ese interruptor pero no guardaba nada: llamaba
-- a editUser con un campo que no existe y respondía 400. Aquí se le da un
-- sitio propio.
--
-- Son DOS cosas distintas y por eso hay dos campos:
--   · estado  → lo que el usuario ELIGE publicar (disponible, ocupado…)
--   · latido  → si de verdad tiene el CRM abierto AHORA
-- El «estado efectivo» sale de cruzar las dos: de nada sirve decir que estás
-- disponible si cerraste el navegador hace dos horas.
--
-- Tabla aparte y NO auditada a propósito: el latido escribe cada pocos
-- minutos por usuario, y en seguridad.users (que sí tiene trg_users_audit)
-- habría llenado auditoria.logs_cambios de ruido.
--
--   psql -h 192.168.2.173 -U postgres -d crm3 -f 2026-09-24_seguridad_presencia.sql
-- ===========================================================================

CREATE TABLE IF NOT EXISTS seguridad.presencia (
    user_id          bigint PRIMARY KEY REFERENCES seguridad.users(id) ON DELETE CASCADE,
    -- Lo que el usuario elige mostrar
    estado           varchar(20) NOT NULL DEFAULT 'DISPONIBLE'
                     CHECK (estado IN ('DISPONIBLE', 'OCUPADO', 'NO_MOLESTAR', 'INVISIBLE')),
    -- Una nota corta opcional: «En reunión hasta las 16:00»
    mensaje          varchar(80),
    -- La última señal de vida del navegador; NULL = cerró sesión
    ultimo_latido_at timestamptz,
    cambiado_at      timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE  seguridad.presencia              IS 'Estado que cada usuario publica y su última señal de vida. Sin auditoría: el latido escribe muy seguido';
COMMENT ON COLUMN seguridad.presencia.estado       IS 'Lo que el usuario ELIGE: DISPONIBLE, OCUPADO, NO_MOLESTAR o INVISIBLE';
COMMENT ON COLUMN seguridad.presencia.ultimo_latido_at IS 'Última señal del navegador. NULL o vieja = no está';

-- Para la lista de «quién está conectado»
CREATE INDEX IF NOT EXISTS ix_presencia_latido ON seguridad.presencia (ultimo_latido_at DESC);


-- ---------------------------------------------------------------------------
-- Los dos umbrales, en un solo sitio
--
--   hasta  5 min sin latir → sigue ahí, vale el estado que eligió
--   de 5 a 20 min          → AUSENTE (se levantó de la silla)
--   más de 20 min, o nunca → DESCONECTADO
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION seguridad.fn_presencia_efectivo(
    p_estado text,
    p_ultimo_latido timestamptz,
    p_para_mi boolean DEFAULT false
)
RETURNS text
LANGUAGE sql
-- STABLE, no IMMUTABLE: depende de now(), y marcarla inmutable dejaría que el
-- planificador se quedara con un resultado viejo dentro de la misma consulta
STABLE
AS $function$
    SELECT CASE
        -- A uno mismo siempre se le dice la verdad de lo que eligió
        WHEN p_para_mi THEN COALESCE(p_estado, 'DISPONIBLE')
        WHEN p_ultimo_latido IS NULL                     THEN 'DESCONECTADO'
        WHEN p_ultimo_latido < now() - interval '20 min'  THEN 'DESCONECTADO'
        -- Quien se pone invisible aparece como desconectado para los demás
        WHEN p_estado = 'INVISIBLE'                       THEN 'DESCONECTADO'
        WHEN p_ultimo_latido < now() - interval '5 min'   THEN 'AUSENTE'
        ELSE COALESCE(p_estado, 'DISPONIBLE')
    END;
$function$;


-- ---------------------------------------------------------------------------
-- El JSON de un usuario
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION seguridad.fn_presencia_json(p_user_id bigint, p_para_mi boolean DEFAULT false)
RETURNS jsonb
LANGUAGE sql
STABLE
AS $function$
    SELECT jsonb_build_object(
        'user_id',    u.id,
        'login_user', u.login_user,
        'nombre',     TRIM(COALESCE(u.name, '') || ' ' || COALESCE(u.surname, '')),
        'estado',     COALESCE(p.estado, 'DISPONIBLE'),
        'efectivo',   seguridad.fn_presencia_efectivo(p.estado, p.ultimo_latido_at, p_para_mi),
        'mensaje',    p.mensaje,
        'visto_hace_min', CASE WHEN p.ultimo_latido_at IS NULL THEN NULL
                               ELSE FLOOR(EXTRACT(EPOCH FROM (now() - p.ultimo_latido_at)) / 60)::int END,
        'ultimo_latido_at', to_char(p.ultimo_latido_at, 'YYYY-MM-DD HH24:MI:SS')
    )
    FROM seguridad.users u
    LEFT JOIN seguridad.presencia p ON p.user_id = u.id
    WHERE u.id = p_user_id AND u.deleted_at IS NULL;
$function$;


-- ---------------------------------------------------------------------------
-- La mía
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION seguridad.fn_presencia_mia(p_user_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
AS $function$
DECLARE v_data jsonb;
BEGIN
    v_data := seguridad.fn_presencia_json(p_user_id, true);
    IF v_data IS NULL THEN
        RETURN jsonb_build_object('success', false, 'message', 'El usuario no existe', 'data', NULL);
    END IF;
    RETURN jsonb_build_object('success', true, 'message', 'La solicitud ha tenido éxito', 'data', v_data);
END;
$function$;


-- ---------------------------------------------------------------------------
-- Cambiar el estado (y, de paso, contar como señal de vida)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION seguridad.fn_presencia_cambiar(
    p_user_id bigint,
    p_estado text,
    p_mensaje text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
AS $function$
DECLARE
    v_estado  text;
    v_mensaje text;
BEGIN
    IF p_user_id IS NULL THEN
        RAISE EXCEPTION 'Falta el usuario' USING ERRCODE = 'P0001';
    END IF;

    v_estado := UPPER(TRIM(COALESCE(p_estado, '')));
    IF v_estado NOT IN ('DISPONIBLE', 'OCUPADO', 'NO_MOLESTAR', 'INVISIBLE') THEN
        RAISE EXCEPTION 'El estado debe ser DISPONIBLE, OCUPADO, NO_MOLESTAR o INVISIBLE' USING ERRCODE = 'P0010';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM seguridad.users WHERE id = p_user_id AND deleted_at IS NULL) THEN
        RAISE EXCEPTION 'El usuario no existe' USING ERRCODE = 'P0013';
    END IF;

    v_mensaje := NULLIF(TRIM(COALESCE(p_mensaje, '')), '');

    INSERT INTO seguridad.presencia (user_id, estado, mensaje, ultimo_latido_at, cambiado_at)
    VALUES (p_user_id, v_estado, v_mensaje, now(), now())
    ON CONFLICT (user_id) DO UPDATE
       SET estado           = EXCLUDED.estado,
           mensaje          = EXCLUDED.mensaje,
           ultimo_latido_at = now(),
           cambiado_at      = now();

    RETURN jsonb_build_object(
        'success', true,
        'message', 'Estado actualizado',
        'data', seguridad.fn_presencia_json(p_user_id, true)
    );
END;
$function$;


-- ---------------------------------------------------------------------------
-- Latido: «sigo aquí». Lo llama el navegador cada pocos minutos.
--
-- No toca el estado elegido: sólo la hora. Si el usuario estaba AUSENTE por
-- llevar un rato quieto, vuelve solo a lo que había elegido.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION seguridad.fn_presencia_latido(p_user_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
AS $function$
BEGIN
    IF p_user_id IS NULL THEN
        RAISE EXCEPTION 'Falta el usuario' USING ERRCODE = 'P0001';
    END IF;

    INSERT INTO seguridad.presencia (user_id, ultimo_latido_at)
    VALUES (p_user_id, now())
    ON CONFLICT (user_id) DO UPDATE SET ultimo_latido_at = now();

    RETURN jsonb_build_object(
        'success', true,
        'message', 'Sigue conectado',
        'data', seguridad.fn_presencia_json(p_user_id, true)
    );
END;
$function$;


-- ---------------------------------------------------------------------------
-- Desconectar: al cerrar sesión, para no quedarse «en línea» una hora
--
-- El estado elegido se conserva: la próxima vez que entre vuelve a estar
-- como lo dejó.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION seguridad.fn_presencia_desconectar(p_user_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
AS $function$
BEGIN
    UPDATE seguridad.presencia SET ultimo_latido_at = NULL WHERE user_id = p_user_id;
    RETURN jsonb_build_object('success', true, 'message', 'Sesión marcada como cerrada', 'data', NULL);
END;
$function$;


-- ---------------------------------------------------------------------------
-- Quién está ahora
--
-- Para la futura pantalla de «conectados» y para pintar el punto al lado de
-- cada usuario. Los invisibles salen como desconectados, igual que los demás.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION seguridad.fn_presencia_conectados(p_solo_presentes boolean DEFAULT true)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
AS $function$
DECLARE v_data jsonb;
BEGIN
    SELECT COALESCE(jsonb_agg(t.j ORDER BY t.orden, t.login_user), '[]'::jsonb) INTO v_data
      FROM (
        SELECT seguridad.fn_presencia_json(u.id) AS j,
               u.login_user,
               CASE seguridad.fn_presencia_efectivo(p.estado, p.ultimo_latido_at)
                    WHEN 'DISPONIBLE'   THEN 1
                    WHEN 'OCUPADO'      THEN 2
                    WHEN 'NO_MOLESTAR'  THEN 3
                    WHEN 'AUSENTE'      THEN 4
                    ELSE 5 END AS orden
          FROM seguridad.users u
          LEFT JOIN seguridad.presencia p ON p.user_id = u.id
         WHERE u.deleted_at IS NULL
           AND u.isactive
           AND (NOT p_solo_presentes
                OR seguridad.fn_presencia_efectivo(p.estado, p.ultimo_latido_at) <> 'DESCONECTADO')
      ) t;

    RETURN jsonb_build_object('success', true, 'message', 'La solicitud ha tenido éxito', 'data', v_data);
END;
$function$;
