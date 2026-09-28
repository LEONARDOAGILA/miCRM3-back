-- ============================================================================
-- CONVERSACIONES DE WHATSAPP
--
-- Guarda lo que el vendedor habla por WhatsApp con el cliente, para que la
-- conversación quede en la empresa y no sólo en su teléfono. Los mensajes los
-- manda un servicio aparte (ver miCRM3-wa) que está enlazado a la cuenta de
-- WhatsApp como un dispositivo más y sólo ESCUCHA: no envía nada por su
-- cuenta.
--
--   ventas.mensajes_whatsapp                    la tabla
--   ventas.fn_whatsapp_guardar(jsonb, ...)      alta idempotente por wa_id
--   ventas.fn_whatsapp_conversacion(cliente)    lo hablado con un cliente
--   ventas.fn_whatsapp_sin_asignar()            números que no casan con nadie
--   ventas.fn_whatsapp_asignar(numero, cliente) atar esos mensajes a un cliente
--   ventas.fn_whatsapp_resumen(cliente)         cuántos y cuándo fue el último
--
-- El mensaje se ata al cliente por el número, normalizado a dígitos (Ecuador:
-- 0991234567 y 593991234567 son el mismo). Se busca en el celular y el
-- teléfono del cliente y también en sus personas de contacto. Lo que no casa
-- con nadie se guarda igual, con cliente_id nulo, y queda en una bandeja para
-- asignarlo a mano: perder mensajes sería peor que tenerlos sueltos.
--
-- Idempotente: IF NOT EXISTS / CREATE OR REPLACE.
-- ============================================================================

CREATE TABLE IF NOT EXISTS ventas.mensajes_whatsapp (
    id            bigserial    PRIMARY KEY,

    cliente_id    bigint,
    contacto_id   bigint,

    -- Identificador del mensaje en WhatsApp. Es lo que evita duplicados
    -- cuando el servicio se reconecta y vuelve a leer lo mismo.
    wa_id         varchar(120) NOT NULL,
    -- La conversación: «593991234567@c.us»
    chat_id       varchar(80)  NOT NULL,
    -- Sólo dígitos, como se guarda para comparar
    numero        varchar(30)  NOT NULL,

    -- ENTRANTE (lo escribió el cliente) o SALIENTE (lo escribió el vendedor)
    direccion     varchar(10)  NOT NULL,
    -- TEXTO, IMAGEN, AUDIO, VIDEO, DOCUMENTO, UBICACION, OTRO
    tipo          varchar(20)  NOT NULL DEFAULT 'TEXTO',

    cuerpo        text,
    -- Nombre del fichero guardado en storage, cuando se guardan adjuntos
    archivo       varchar(255),
    -- Cómo se llama quien escribió, según WhatsApp
    autor         varchar(150),
    -- De qué cuenta salió: el login del vendedor o su número
    vendedor      varchar(150),

    enviado_at    timestamptz  NOT NULL,
    created_at    timestamptz  NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT uq_mensajes_whatsapp_wa_id UNIQUE (wa_id),
    CONSTRAINT fk_mensajes_whatsapp_cliente FOREIGN KEY (cliente_id)
        REFERENCES ventas.clientes (id) ON DELETE CASCADE,
    CONSTRAINT ck_mensajes_whatsapp_direccion CHECK (direccion IN ('ENTRANTE', 'SALIENTE'))
);

CREATE INDEX IF NOT EXISTS ix_mensajes_whatsapp_cliente ON ventas.mensajes_whatsapp (cliente_id, enviado_at DESC);
CREATE INDEX IF NOT EXISTS ix_mensajes_whatsapp_numero  ON ventas.mensajes_whatsapp (numero, enviado_at DESC);
CREATE INDEX IF NOT EXISTS ix_mensajes_whatsapp_sin_cliente ON ventas.mensajes_whatsapp (numero) WHERE cliente_id IS NULL;

COMMENT ON TABLE  ventas.mensajes_whatsapp IS 'Conversaciones de WhatsApp entre vendedores y clientes';
COMMENT ON COLUMN ventas.mensajes_whatsapp.wa_id IS 'Id del mensaje en WhatsApp; evita duplicados al reconectar';

-- ---------------------------------------------------------------------------
-- A QUÉ CLIENTE PERTENECE UN NÚMERO
--
-- Compara sólo dígitos y por los últimos 9, que es lo que no cambia entre
-- «0991234567», «593991234567» y «+593 99 123 4567».
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ventas.fn_whatsapp_cliente_de(p_numero varchar)
RETURNS bigint
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'ventas'
AS $function$
DECLARE
    v_cola text := RIGHT(regexp_replace(COALESCE(p_numero, ''), '\D', '', 'g'), 9);
    v_id   bigint;
BEGIN
    IF length(v_cola) < 7 THEN RETURN NULL; END IF;

    -- Primero el cliente por su celular o teléfono
    SELECT c.id INTO v_id
      FROM ventas.clientes c
     WHERE c.deleted_at IS NULL
       AND (RIGHT(regexp_replace(COALESCE(c.celular, ''),  '\D', '', 'g'), 9) = v_cola
        OR  RIGHT(regexp_replace(COALESCE(c.telefono, ''), '\D', '', 'g'), 9) = v_cola)
     ORDER BY c.id
     LIMIT 1;

    IF v_id IS NOT NULL THEN RETURN v_id; END IF;

    -- Si no, alguna de sus personas de contacto
    SELECT cc.cliente_id INTO v_id
      FROM ventas.contactos_clientes cc
      JOIN ventas.clientes c ON c.id = cc.cliente_id AND c.deleted_at IS NULL
     WHERE RIGHT(regexp_replace(COALESCE(cc.telefono, ''), '\D', '', 'g'), 9) = v_cola
     ORDER BY cc.cliente_id
     LIMIT 1;

    RETURN v_id;
END;
$function$;

-- ---------------------------------------------------------------------------
-- GUARDAR UN MENSAJE
--
-- Idempotente por wa_id: si el servicio reenvía lo mismo, no se duplica.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ventas.fn_whatsapp_guardar(p_datos jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'ventas'
AS $function$
DECLARE
    v_numero  varchar := regexp_replace(COALESCE(p_datos->>'numero', ''), '\D', '', 'g');
    v_wa_id   varchar := NULLIF(TRIM(COALESCE(p_datos->>'wa_id', '')), '');
    v_cliente bigint;
    v_id      bigint;
    v_nuevo   boolean := true;
BEGIN
    IF v_wa_id IS NULL THEN
        RAISE EXCEPTION 'El mensaje no trae identificador de WhatsApp' USING ERRCODE = 'P0001';
    END IF;
    IF v_numero = '' THEN
        RAISE EXCEPTION 'El mensaje no trae número' USING ERRCODE = 'P0001';
    END IF;

    SELECT id INTO v_id FROM ventas.mensajes_whatsapp WHERE wa_id = v_wa_id;
    IF v_id IS NOT NULL THEN
        RETURN jsonb_build_object('success', true, 'message', 'El mensaje ya estaba guardado',
                                  'data', jsonb_build_object('id', v_id, 'nuevo', false));
    END IF;

    v_cliente := ventas.fn_whatsapp_cliente_de(v_numero);

    INSERT INTO ventas.mensajes_whatsapp (
        cliente_id, wa_id, chat_id, numero, direccion, tipo,
        cuerpo, archivo, autor, vendedor, enviado_at
    ) VALUES (
        v_cliente,
        v_wa_id,
        COALESCE(NULLIF(p_datos->>'chat_id', ''), v_numero || '@c.us'),
        v_numero,
        CASE WHEN UPPER(COALESCE(p_datos->>'direccion', '')) = 'SALIENTE' THEN 'SALIENTE' ELSE 'ENTRANTE' END,
        UPPER(COALESCE(NULLIF(p_datos->>'tipo', ''), 'TEXTO')),
        NULLIF(p_datos->>'cuerpo', ''),
        NULLIF(p_datos->>'archivo', ''),
        NULLIF(p_datos->>'autor', ''),
        NULLIF(p_datos->>'vendedor', ''),
        COALESCE((p_datos->>'enviado_at')::timestamptz, CURRENT_TIMESTAMP)
    )
    RETURNING id INTO v_id;

    RETURN jsonb_build_object(
        'success', true,
        'message', CASE WHEN v_cliente IS NULL THEN 'Mensaje guardado sin cliente asignado' ELSE 'Mensaje guardado' END,
        'data', jsonb_build_object('id', v_id, 'cliente_id', v_cliente, 'nuevo', v_nuevo)
    );
EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object('success', false, 'message', 'Error al guardar el mensaje: ' || SQLERRM, 'error_code', SQLSTATE);
END;
$function$;

-- ---------------------------------------------------------------------------
-- LA CONVERSACIÓN DE UN CLIENTE
-- Del más viejo al más nuevo, que es como se lee un chat.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ventas.fn_whatsapp_conversacion(p_cliente_id bigint, p_limite integer DEFAULT 200)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'ventas'
AS $function$
DECLARE
    v_data jsonb;
BEGIN
    SELECT COALESCE(jsonb_agg(m ORDER BY (m->>'enviado_at')), '[]'::jsonb) INTO v_data
      FROM (
        SELECT jsonb_build_object(
                 'id',         x.id,
                 'direccion',  x.direccion,
                 'tipo',       x.tipo,
                 'cuerpo',     x.cuerpo,
                 'archivo',    x.archivo,
                 'autor',      x.autor,
                 'vendedor',   x.vendedor,
                 'numero',     x.numero,
                 'enviado_at', to_char(x.enviado_at, 'YYYY-MM-DD HH24:MI')
               ) AS m
          FROM (
            SELECT * FROM ventas.mensajes_whatsapp
             WHERE cliente_id = p_cliente_id
             ORDER BY enviado_at DESC, id DESC
             LIMIT GREATEST(COALESCE(p_limite, 200), 1)
          ) x
      ) s;

    RETURN jsonb_build_object('success', true, 'message', 'Conversación obtenida exitosamente', 'data', v_data);
EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object('success', false, 'message', 'Error al obtener la conversación: ' || SQLERRM, 'error_code', SQLSTATE);
END;
$function$;

-- ---------------------------------------------------------------------------
-- RESUMEN: para la pestaña (cuántos hay y cuándo fue el último)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ventas.fn_whatsapp_resumen(p_cliente_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'ventas'
AS $function$
DECLARE
    v jsonb;
BEGIN
    SELECT jsonb_build_object(
        'total',      COUNT(*),
        'entrantes',  COUNT(*) FILTER (WHERE direccion = 'ENTRANTE'),
        'salientes',  COUNT(*) FILTER (WHERE direccion = 'SALIENTE'),
        'ultimo_at',  to_char(MAX(enviado_at), 'YYYY-MM-DD HH24:MI'),
        'sin_responder', (
            SELECT COUNT(*) FROM ventas.mensajes_whatsapp u
             WHERE u.cliente_id = p_cliente_id
               AND u.direccion = 'ENTRANTE'
               AND u.enviado_at > COALESCE((SELECT MAX(s.enviado_at) FROM ventas.mensajes_whatsapp s
                                             WHERE s.cliente_id = p_cliente_id AND s.direccion = 'SALIENTE'),
                                           '-infinity'::timestamptz))
    ) INTO v
    FROM ventas.mensajes_whatsapp
    WHERE cliente_id = p_cliente_id;

    RETURN jsonb_build_object('success', true, 'message', 'Resumen obtenido exitosamente', 'data', v);
EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object('success', false, 'message', 'Error al obtener el resumen: ' || SQLERRM, 'error_code', SQLSTATE);
END;
$function$;

-- ---------------------------------------------------------------------------
-- LOS QUE NO CASAN CON NINGÚN CLIENTE
-- Agrupados por número, para poder asignarlos de una vez.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ventas.fn_whatsapp_sin_asignar(p_limite integer DEFAULT 50)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'ventas'
AS $function$
DECLARE
    v jsonb;
BEGIN
    SELECT COALESCE(jsonb_agg(x ORDER BY x->>'ultimo_at' DESC), '[]'::jsonb) INTO v
      FROM (
        SELECT jsonb_build_object(
                 'numero',    numero,
                 'autor',     MAX(autor),
                 'mensajes',  COUNT(*),
                 'ultimo_at', to_char(MAX(enviado_at), 'YYYY-MM-DD HH24:MI'),
                 'ultimo',    (SELECT u.cuerpo FROM ventas.mensajes_whatsapp u
                                WHERE u.numero = m.numero AND u.cliente_id IS NULL
                                ORDER BY u.enviado_at DESC LIMIT 1)
               ) AS x
          FROM ventas.mensajes_whatsapp m
         WHERE cliente_id IS NULL
         GROUP BY numero
         ORDER BY MAX(enviado_at) DESC
         LIMIT GREATEST(COALESCE(p_limite, 50), 1)
      ) s;

    RETURN jsonb_build_object('success', true, 'message', 'Pendientes obtenidos exitosamente', 'data', v);
EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object('success', false, 'message', 'Error: ' || SQLERRM, 'error_code', SQLSTATE);
END;
$function$;

-- ---------------------------------------------------------------------------
-- ASIGNAR A MANO LOS MENSAJES DE UN NÚMERO
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ventas.fn_whatsapp_asignar(p_numero varchar, p_cliente_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'ventas'
AS $function$
DECLARE
    v_numero varchar := regexp_replace(COALESCE(p_numero, ''), '\D', '', 'g');
    v_n      integer;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM ventas.clientes WHERE id = p_cliente_id AND deleted_at IS NULL) THEN
        RAISE EXCEPTION 'El cliente no existe o está en la papelera' USING ERRCODE = 'P0013';
    END IF;

    UPDATE ventas.mensajes_whatsapp
       SET cliente_id = p_cliente_id
     WHERE cliente_id IS NULL
       AND RIGHT(numero, 9) = RIGHT(v_numero, 9);
    GET DIAGNOSTICS v_n = ROW_COUNT;

    RETURN jsonb_build_object('success', true,
        'message', v_n || ' mensaje(s) asignados al cliente',
        'data', jsonb_build_object('mensajes', v_n));
EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object('success', false, 'message', 'Error al asignar: ' || SQLERRM, 'error_code', SQLSTATE);
END;
$function$;

ALTER TABLE ventas.mensajes_whatsapp OWNER TO postgres;
