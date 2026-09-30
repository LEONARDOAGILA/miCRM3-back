-- ============================================================================
-- WHATSAPP: LA ASIGNACIÓN SE QUEDA PEGADA AL CHAT
--
-- Con los identificadores ocultos (LID) no hay teléfono con el que buscar al
-- cliente, así que cada mensaje nuevo volvía a quedar suelto AUNQUE esa
-- conversación ya se hubiera asignado a mano. Había que asignarla una y otra
-- vez, lo cual no sirve para nada.
--
-- Ahora, si no se puede emparejar por teléfono, se mira si ese mismo chat ya
-- tiene dueño y se hereda. Asignar una vez basta.
-- ============================================================================

CREATE OR REPLACE FUNCTION ventas.fn_whatsapp_guardar(p_datos jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'ventas'
AS $function$
DECLARE
    v_numero   varchar := regexp_replace(COALESCE(p_datos->>'numero', ''), '\D', '', 'g');
    v_wa_id    varchar := NULLIF(TRIM(COALESCE(p_datos->>'wa_id', '')), '');
    v_chat     varchar := COALESCE(NULLIF(p_datos->>'chat_id', ''), v_numero || '@c.us');
    v_es_lid   boolean := COALESCE((p_datos->>'es_lid')::boolean, v_chat LIKE '%@lid', false);
    v_cliente  bigint;
    v_heredado boolean := false;
    v_id       bigint;
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

    -- 1. Por teléfono, cuando lo hay
    IF NOT v_es_lid THEN
        v_cliente := ventas.fn_whatsapp_cliente_de(v_numero);
    END IF;

    -- 2. Si no, de quien ya tenga ese mismo chat: asignar una vez basta,
    --    aunque WhatsApp siga sin dar el teléfono
    IF v_cliente IS NULL THEN
        SELECT cliente_id INTO v_cliente
          FROM ventas.mensajes_whatsapp
         WHERE numero = v_numero AND cliente_id IS NOT NULL
         ORDER BY id DESC
         LIMIT 1;
        v_heredado := v_cliente IS NOT NULL;
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
            WHEN v_heredado        THEN 'Mensaje guardado en el cliente de esa conversación'
            WHEN v_cliente IS NULL AND v_es_lid THEN 'Mensaje guardado (WhatsApp no dio el teléfono)'
            WHEN v_cliente IS NULL THEN 'Mensaje guardado sin cliente asignado'
            ELSE 'Mensaje guardado'
        END,
        'data', jsonb_build_object('id', v_id, 'cliente_id', v_cliente, 'es_lid', v_es_lid,
                                   'heredado', v_heredado, 'nuevo', true)
    );
EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object('success', false, 'message', 'Error al guardar el mensaje: ' || SQLERRM, 'error_code', SQLSTATE);
END;
$function$;
