-- ============================================================================
-- CONTACTOS DE EMERGENCIA de un empleado (rh.contactos_emergencia)
--   rh.fn_contactos_listar(empleado_id)             lista del empleado
--   rh.fn_contactos_guardar(empleado_id, jsonb, …)  sincroniza la lista completa
--
-- La grilla del formulario de empleado manda TODOS los contactos al guardar:
-- los que traen id se actualizan, los que no lo traen se insertan y los que
-- ya no vienen se eliminan. Mismo contexto de auditoría que el resto de rh.
-- Reglas: nombres, parentesco y teléfono obligatorios (P0001), prioridad > 0
-- (P0002), el empleado debe existir (P0013).
-- ============================================================================

CREATE OR REPLACE FUNCTION rh.fn_contactos_listar(p_empleado_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
    v_data jsonb;
BEGIN
    SELECT COALESCE(jsonb_agg(
        jsonb_build_object(
            'id',               c.id,
            'empleado_id',      c.empleado_id,
            'nombres',          c.nombres,
            'parentesco',       c.parentesco,
            'telefono',         c.telefono,
            'telefono_alterno', c.telefono_alterno,
            'email',            c.email,
            'prioridad',        c.prioridad,
            'activo',           c.activo,
            'created_by',       c.created_by,
            'updated_by',       c.updated_by,
            'created_at',       to_char(c.created_at, 'YYYY-MM-DD HH24:MI:SS'),
            'updated_at',       to_char(c.updated_at, 'YYYY-MM-DD HH24:MI:SS')
        ) ORDER BY c.prioridad, c.id
    ), '[]'::jsonb) INTO v_data
    FROM rh.contactos_emergencia c
    WHERE c.empleado_id = p_empleado_id;

    RETURN jsonb_build_object('success', true, 'message', 'Contactos obtenidos exitosamente', 'data', v_data);
EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object('success', false, 'message', 'Error al listar contactos: ' || SQLERRM, 'error_code', SQLSTATE);
END;
$function$;

CREATE OR REPLACE FUNCTION rh.fn_contactos_guardar(
    p_empleado_id    bigint,
    p_contactos      jsonb,               -- [{id?, nombres, parentesco, telefono, telefono_alterno?, email?, prioridad?, activo?}, …]
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
SET search_path TO 'pg_catalog', 'rh', 'auditoria'
AS $function$
DECLARE
    v_c          jsonb;
    v_id         bigint;
    v_ids        bigint[] := ARRAY[]::bigint[];
    v_fecha      timestamptz := CURRENT_TIMESTAMP;
    v_insertados integer := 0;
    v_editados   integer := 0;
    v_borrados   integer := 0;
    v_prioridad  integer;
BEGIN
    PERFORM set_config('app.usuario_id',     COALESCE(p_usuario_id::text, ''), true);
    PERFORM set_config('app.usuario_login',  COALESCE(p_usuario_login, current_user), true);
    PERFORM set_config('app.usuario_nombre', COALESCE(p_usuario_nombre, current_user), true);
    PERFORM set_config('app.ip_address',     COALESCE(p_ip_address::text, ''), true);
    PERFORM set_config('app.user_agent',     COALESCE(p_user_agent, ''), true);
    PERFORM set_config('app.request_id',     COALESCE(p_request_id::text, ''), true);
    PERFORM set_config('app.modulo',         'rh.contactos_emergencia', true);

    IF NOT EXISTS (SELECT 1 FROM rh.empleados WHERE id = p_empleado_id) THEN
        RAISE EXCEPTION 'El empleado no existe' USING ERRCODE = 'P0013';
    END IF;

    FOR v_c IN SELECT * FROM jsonb_array_elements(COALESCE(p_contactos, '[]'::jsonb)) LOOP
        IF NULLIF(TRIM(COALESCE(v_c->>'nombres', '')), '') IS NULL
           OR NULLIF(TRIM(COALESCE(v_c->>'parentesco', '')), '') IS NULL
           OR NULLIF(TRIM(COALESCE(v_c->>'telefono', '')), '') IS NULL THEN
            RAISE EXCEPTION 'Cada contacto necesita nombres, parentesco y teléfono' USING ERRCODE = 'P0001';
        END IF;
        v_prioridad := COALESCE(NULLIF(v_c->>'prioridad', '')::integer, 1);
        IF v_prioridad < 1 THEN
            RAISE EXCEPTION 'La prioridad debe ser 1 o mayor' USING ERRCODE = 'P0002';
        END IF;

        v_id := NULLIF(v_c->>'id', '')::bigint;

        IF v_id IS NOT NULL AND EXISTS (SELECT 1 FROM rh.contactos_emergencia WHERE id = v_id AND empleado_id = p_empleado_id) THEN
            UPDATE rh.contactos_emergencia
               SET nombres          = TRIM(v_c->>'nombres'),
                   parentesco       = TRIM(v_c->>'parentesco'),
                   telefono         = TRIM(v_c->>'telefono'),
                   telefono_alterno = NULLIF(TRIM(COALESCE(v_c->>'telefono_alterno', '')), ''),
                   email            = NULLIF(LOWER(TRIM(COALESCE(v_c->>'email', ''))), ''),
                   prioridad        = v_prioridad,
                   activo           = COALESCE((v_c->>'activo')::boolean, true),
                   updated_by       = p_usuario_login,
                   updated_at       = v_fecha
             WHERE id = v_id
               AND (nombres, parentesco, telefono, COALESCE(telefono_alterno, ''), COALESCE(email, ''), prioridad, activo)
                   IS DISTINCT FROM
                   (TRIM(v_c->>'nombres'), TRIM(v_c->>'parentesco'), TRIM(v_c->>'telefono'),
                    COALESCE(NULLIF(TRIM(COALESCE(v_c->>'telefono_alterno', '')), ''), ''),
                    COALESCE(NULLIF(LOWER(TRIM(COALESCE(v_c->>'email', ''))), ''), ''),
                    v_prioridad, COALESCE((v_c->>'activo')::boolean, true));
            IF FOUND THEN v_editados := v_editados + 1; END IF;
        ELSE
            INSERT INTO rh.contactos_emergencia (empleado_id, nombres, parentesco, telefono, telefono_alterno, email, prioridad, activo,
                                                 created_by, updated_by, created_at, updated_at)
            VALUES (p_empleado_id, TRIM(v_c->>'nombres'), TRIM(v_c->>'parentesco'), TRIM(v_c->>'telefono'),
                    NULLIF(TRIM(COALESCE(v_c->>'telefono_alterno', '')), ''),
                    NULLIF(LOWER(TRIM(COALESCE(v_c->>'email', ''))), ''),
                    v_prioridad, COALESCE((v_c->>'activo')::boolean, true),
                    p_usuario_login, p_usuario_login, v_fecha, v_fecha)
            RETURNING id INTO v_id;
            v_insertados := v_insertados + 1;
        END IF;
        v_ids := array_append(v_ids, v_id);
    END LOOP;

    -- Los que ya no vienen en la lista
    DELETE FROM rh.contactos_emergencia
     WHERE empleado_id = p_empleado_id
       AND NOT (id = ANY (v_ids));
    GET DIAGNOSTICS v_borrados = ROW_COUNT;

    RETURN jsonb_build_object(
        'success', true,
        'message', format('Contactos guardados: %s nuevo(s), %s modificado(s), %s eliminado(s)', v_insertados, v_editados, v_borrados),
        'data', (rh.fn_contactos_listar(p_empleado_id))->'data'
    );
END;
$function$;

ALTER FUNCTION rh.fn_contactos_listar(bigint) OWNER TO postgres;
ALTER FUNCTION rh.fn_contactos_guardar(bigint, jsonb, bigint, varchar, varchar, inet, text, uuid) OWNER TO postgres;
COMMENT ON FUNCTION rh.fn_contactos_listar(bigint) IS 'Contactos de emergencia de un empleado';
COMMENT ON FUNCTION rh.fn_contactos_guardar(bigint, jsonb, bigint, varchar, varchar, inet, text, uuid) IS 'Sincroniza la lista de contactos de emergencia de un empleado (inserta, actualiza y elimina)';
