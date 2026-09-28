-- ============================================================================
-- WHATSAPP: IDENTIFICADORES «LID»
--
-- WhatsApp ya no siempre entrega el teléfono: en muchos chats manda un LID
-- («122050270216225@lid»), un identificador que oculta el número real. Eso
-- rompía dos cosas:
--
--   1. esos mensajes no casaban con ningún cliente (no hay número que buscar);
--   2. peor todavía, el emparejamiento comparaba los últimos 9 dígitos, así
--      que un LID podía acabar colgado del cliente equivocado.
--
-- Se marca de dónde viene cada mensaje y sólo se empareja lo que de verdad es
-- un teléfono.
-- ============================================================================

ALTER TABLE ventas.mensajes_whatsapp ADD COLUMN IF NOT EXISTS es_lid boolean NOT NULL DEFAULT false;
COMMENT ON COLUMN ventas.mensajes_whatsapp.es_lid IS 'true si «numero» es un LID de WhatsApp y no un teléfono';

-- Lo que ya está guardado: un número de más de 13 dígitos no es un teléfono
UPDATE ventas.mensajes_whatsapp
   SET es_lid = true, cliente_id = NULL
 WHERE length(numero) > 13 AND es_lid = false;

-- ---------------------------------------------------------------------------
-- El emparejador sólo trabaja con teléfonos de verdad
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ventas.fn_whatsapp_cliente_de(p_numero varchar)
RETURNS bigint
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'ventas'
AS $function$
DECLARE
    v_limpio text := regexp_replace(COALESCE(p_numero, ''), '\D', '', 'g');
    v_cola   text := RIGHT(v_limpio, 9);
    v_id     bigint;
BEGIN
    -- Un teléfono tiene entre 7 y 13 dígitos; lo que pase de ahí es un LID
    IF length(v_limpio) < 7 OR length(v_limpio) > 13 THEN RETURN NULL; END IF;

    SELECT c.id INTO v_id
      FROM ventas.clientes c
     WHERE c.deleted_at IS NULL
       AND (RIGHT(regexp_replace(COALESCE(c.celular, ''),  '\D', '', 'g'), 9) = v_cola
        OR  RIGHT(regexp_replace(COALESCE(c.telefono, ''), '\D', '', 'g'), 9) = v_cola)
     ORDER BY c.id
     LIMIT 1;

    IF v_id IS NOT NULL THEN RETURN v_id; END IF;

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
-- Al guardar se anota si es LID y no se intenta emparejar en ese caso
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
    v_chat    varchar := COALESCE(NULLIF(p_datos->>'chat_id', ''), v_numero || '@c.us');
    v_es_lid  boolean := COALESCE((p_datos->>'es_lid')::boolean, v_chat LIKE '%@lid', false);
    v_cliente bigint;
    v_id      bigint;
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

    -- Sólo se empareja cuando hay un teléfono de verdad
    IF NOT v_es_lid THEN
        v_cliente := ventas.fn_whatsapp_cliente_de(v_numero);
    END IF;

    INSERT INTO ventas.mensajes_whatsapp (
        cliente_id, wa_id, chat_id, numero, es_lid, direccion, tipo,
        cuerpo, archivo, autor, vendedor, enviado_at
    ) VALUES (
        v_cliente, v_wa_id, v_chat, v_numero, v_es_lid,
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
        'message', CASE
            WHEN v_es_lid        THEN 'Mensaje guardado (WhatsApp no dio el teléfono)'
            WHEN v_cliente IS NULL THEN 'Mensaje guardado sin cliente asignado'
            ELSE 'Mensaje guardado'
        END,
        'data', jsonb_build_object('id', v_id, 'cliente_id', v_cliente, 'es_lid', v_es_lid, 'nuevo', true)
    );
EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object('success', false, 'message', 'Error al guardar el mensaje: ' || SQLERRM, 'error_code', SQLSTATE);
END;
$function$;

-- ---------------------------------------------------------------------------
-- Reintentar el emparejamiento (tras crear clientes o corregir teléfonos)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ventas.fn_whatsapp_reemparejar()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'ventas'
AS $function$
DECLARE
    v_n integer := 0;
BEGIN
    UPDATE ventas.mensajes_whatsapp m
       SET cliente_id = ventas.fn_whatsapp_cliente_de(m.numero)
     WHERE m.cliente_id IS NULL
       AND NOT m.es_lid
       AND ventas.fn_whatsapp_cliente_de(m.numero) IS NOT NULL;
    GET DIAGNOSTICS v_n = ROW_COUNT;

    RETURN jsonb_build_object('success', true, 'message', v_n || ' mensaje(s) emparejados',
                              'data', jsonb_build_object('mensajes', v_n));
END;
$function$;
