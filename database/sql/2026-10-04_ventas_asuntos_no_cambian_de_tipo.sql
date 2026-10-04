-- ===========================================================================
-- UN ASUNTO EN USO NO SE MUEVE DE TIPO
-- ===========================================================================
-- Fecha: 2026-10-03
-- Se aplica después de 2026-10-04_ventas_gestiones_asunto_id.sql.
--
-- Por qué, y es la razón por la que ventas.gestiones.tipo se queda donde está:
--
-- La gestión guarda su tipo (LLAMADA, VISITA…) y además el asunto del
-- catálogo, y el tipo se puede deducir del asunto. Parece repetido, pero no lo
-- es: el tipo guardado es LO QUE SE ELIGIÓ ESE DÍA, igual que el texto del
-- asunto. Si el catálogo cambia, el historial no debe cambiar con él.
--
-- El único camino por el que los dos podían acabar diciendo cosas distintas
-- era éste: mover «Cobranza» de LLAMADA a VISITA desde el mantenimiento.
-- Las 37 gestiones viejas seguirían diciendo LLAMADA —correcto, es lo que
-- fueron— mientras su asunto ya diría VISITA, y cualquier informe que cruzara
-- las dos cosas saldría raro sin que nadie hubiera tocado una gestión.
--
-- Así que el movimiento se prohíbe en cuanto el asunto está en uso. Para un
-- asunto que todavía no ha usado nadie sigue permitido, que es cuando de
-- verdad hace falta (se dio de alta bajo el tipo equivocado y se corrige).
--
-- Con esto, tipo y el tipo del asunto no pueden separarse nunca, y la columna
-- tipo pasa a ser lo que parece: la copia rápida que leen la agenda, las
-- estadísticas y los filtros sin tener que pasar por dos JOIN.
-- ===========================================================================

CREATE OR REPLACE FUNCTION ventas.fn_gestiones_asuntos_guardar(
    p_id             bigint  DEFAULT NULL,
    p_tipo_id        bigint  DEFAULT NULL,
    p_nombre         varchar DEFAULT NULL,
    p_orden          integer DEFAULT 100,
    p_activo         boolean DEFAULT true,
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
SET search_path TO 'pg_catalog', 'ventas', 'auditoria'
AS $function$
DECLARE
    v_id       bigint;
    v_nombre   varchar := NULLIF(TRIM(COALESCE(p_nombre, '')), '');
    v_fecha    timestamptz := CURRENT_TIMESTAMP;
    v_tipo_old bigint;
    v_uso      bigint;
BEGIN
    PERFORM ventas.fn_gestiones_contexto(p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    IF v_nombre IS NULL OR length(v_nombre) < 3 THEN
        RAISE EXCEPTION 'El asunto es obligatorio (mínimo 3 caracteres)' USING ERRCODE = 'P0001';
    END IF;
    IF p_tipo_id IS NULL OR NOT EXISTS (SELECT 1 FROM ventas.gestiones_tipos WHERE id = p_tipo_id) THEN
        RAISE EXCEPTION 'El tipo indicado no existe' USING ERRCODE = 'P0013';
    END IF;
    IF EXISTS (SELECT 1 FROM ventas.gestiones_asuntos
                WHERE tipo_id = p_tipo_id AND nombre = v_nombre AND id IS DISTINCT FROM p_id) THEN
        RAISE EXCEPTION 'Ese tipo ya tiene un asunto con ese nombre' USING ERRCODE = 'P0020';
    END IF;

    IF p_id IS NULL THEN
        INSERT INTO ventas.gestiones_asuntos (tipo_id, nombre, orden, activo, created_by, updated_by)
        VALUES (p_tipo_id, v_nombre, COALESCE(p_orden, 100), COALESCE(p_activo, true), p_usuario_login, p_usuario_login)
        RETURNING id INTO v_id;
    ELSE
        SELECT tipo_id INTO v_tipo_old FROM ventas.gestiones_asuntos WHERE id = p_id;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'El asunto no existe' USING ERRCODE = 'P0013';
        END IF;

        -- Cambiar de tipo sólo mientras no lo haya usado nadie
        IF v_tipo_old IS DISTINCT FROM p_tipo_id THEN
            SELECT COUNT(*) INTO v_uso FROM ventas.gestiones WHERE asunto_id = p_id;
            IF v_uso > 0 THEN
                RAISE EXCEPTION
                    'Ese asunto ya se usó en % gestión(es), así que no puede cambiar de tipo: el historial dejaría de cuadrar. Créalo en el otro tipo y desactiva éste.', v_uso
                    USING ERRCODE = 'P0021';
            END IF;
        END IF;

        UPDATE ventas.gestiones_asuntos
           SET tipo_id = p_tipo_id, nombre = v_nombre,
               orden = COALESCE(p_orden, orden), activo = COALESCE(p_activo, activo),
               updated_by = p_usuario_login, updated_at = v_fecha
         WHERE id = p_id;

        -- El texto de las gestiones NO se toca: cada una guarda el asunto tal
        -- como se vio el día que se registró. Corregir el catálogo cambia lo
        -- que se ofrece de aquí en adelante, no lo que ya pasó.
        v_id := p_id;
    END IF;

    RETURN jsonb_build_object(
        'success', true,
        'message', CASE WHEN p_id IS NULL THEN 'Asunto creado exitosamente' ELSE 'Asunto actualizado exitosamente' END,
        'data', (SELECT jsonb_build_object('id', id, 'tipo_id', tipo_id, 'nombre', nombre, 'orden', orden, 'activo', activo)
                   FROM ventas.gestiones_asuntos WHERE id = v_id)
    );
END;
$function$;

-- Que la columna diga por qué sigue ahí, para el siguiente que se lo pregunte
COMMENT ON COLUMN ventas.gestiones.tipo IS
    'El tipo que se eligió ese día (ventas.gestiones_tipos.codigo). Se puede deducir del asunto, pero se guarda a propósito: es el registro histórico, y lo leen la agenda, las estadísticas y los filtros sin pasar por dos JOIN. Un asunto en uso no puede cambiar de tipo, así que los dos nunca se separan.';
