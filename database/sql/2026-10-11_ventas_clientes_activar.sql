-- ===========================================================================
-- ACTIVAR / DESACTIVAR UN CLIENTE SIN ABRIR EL FORMULARIO
-- ===========================================================================
-- Fecha: 2026-10-11
--
-- Dar de baja a un cliente obligaba a entrar en el formulario entero, cambiar
-- una casilla y guardar: eso vuelve a pasar por fn_clientes_modificar, que
-- revalida identificación, correos, cupo y descuento y reescribe veinticuatro
-- columnas. Para bajar una casilla es mucho, y tiene un efecto que no se ve
-- venir: si cualquiera de esas reglas ya no se cumple —un correo repetido que
-- entró antes de que existiera la regla— no se puede desactivar al cliente
-- hasta arreglar el resto de la ficha.
--
-- Esta función hace sólo eso: pone `activo`. No toca `estado`, que es otra
-- cosa —ACTIVO / INACTIVO / SUSPENDIDO / MOROSO describe la relación
-- comercial, y `activo` dice si el registro está en juego—; en el formulario
-- también se guardan por separado y no hay razón para acoplarlos aquí.
--
-- SIN p_activo ALTERNA, igual que fn_notas_clientes_fijar. La pantalla manda
-- el valor que quiere para que dos personas pulsando a la vez no se peleen:
-- quien manda `false` acaba en `false`, no en «lo contrario de lo que había».
--
-- NO SE REPITE LA COMPROBACIÓN DE PERMISOS: estas rutas la resuelven el
-- middleware y el perfil, exactamente igual que editCliente, que es la que
-- esta función releva. El alcance «sólo mis clientes» tampoco se aplica,
-- porque la pantalla donde está la casilla es Ventas > Clientes, que a
-- propósito ve todos (es donde se reparten los que no tienen dueño).
--
-- Idempotente: se puede volver a correr.
-- ===========================================================================

CREATE OR REPLACE FUNCTION ventas.fn_clientes_activar(
    p_id             bigint,
    p_activo         boolean DEFAULT NULL,   -- NULL: alternar lo que haya
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
    v_antes      boolean;
    v_nuevo      boolean;
    v_borrado    timestamptz;
    v_updated_by varchar;
    v_updated_at text;
BEGIN
    PERFORM ventas.fn_gestiones_contexto(
        p_usuario_id, p_usuario_login, p_usuario_nombre,
        p_ip_address, p_user_agent, p_request_id, 'ventas.clientes'
    );

    SELECT activo, deleted_at INTO v_antes, v_borrado
      FROM ventas.clientes WHERE id = p_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'El cliente no existe' USING ERRCODE = 'P0013';
    END IF;

    -- En la papelera no se toca nada: restaurarlo es lo que toca, y dejar
    -- activar lo que está borrado haría que la papelera mintiera
    IF v_borrado IS NOT NULL THEN
        RAISE EXCEPTION 'Ese cliente está en la papelera: hay que restaurarlo primero'
            USING ERRCODE = 'P0014';
    END IF;

    -- COALESCE sobre v_antes porque la columna admite NULL: un cliente antiguo
    -- sin valor cuenta como activo, que es lo que enseña la pantalla
    v_nuevo := COALESCE(p_activo, NOT COALESCE(v_antes, true));

    -- Ya estaba así. Se contesta bien y no se escribe: si no, dos pulsaciones
    -- seguidas dejarían dos apuntes de auditoría sin ningún cambio detrás
    IF v_nuevo IS NOT DISTINCT FROM v_antes THEN
        SELECT updated_by, to_char(updated_at, 'YYYY-MM-DD HH24:MI:SS')
          INTO v_updated_by, v_updated_at
          FROM ventas.clientes WHERE id = p_id;

        RETURN jsonb_build_object(
            'success', true,
            'message', CASE WHEN v_nuevo THEN 'El cliente ya estaba activo'
                                         ELSE 'El cliente ya estaba inactivo' END,
            'data', jsonb_build_object('id', p_id, 'activo', v_nuevo,
                                       'updated_by', v_updated_by,
                                       'updated_at', v_updated_at)
        );
    END IF;

    -- A la auditoría va SÓLO lo que cambió. Si se dejara al disparador, que
    -- cuando no hay contexto guarda row_to_json(OLD) y row_to_json(NEW), el
    -- apunte traería las cuarenta columnas del cliente y habría que buscar
    -- la casilla entre ellas.
    PERFORM set_config('app.datos_anteriores',
        jsonb_build_object('id', p_id, 'activo', v_antes)::text, true);
    PERFORM set_config('app.datos_nuevos',
        jsonb_build_object('id', p_id, 'activo', v_nuevo)::text, true);

    -- updated_by y updated_at los ponen los disparadores de la tabla
    -- (fn_set_audit_users y fn_update_updated_at_column); se leen de vuelta
    -- con RETURNING en vez de calcularlos aquí, que es la única forma de
    -- devolver lo que quedó escrito de verdad
    UPDATE ventas.clientes
       SET activo = v_nuevo
     WHERE id = p_id
    RETURNING activo, updated_by, to_char(updated_at, 'YYYY-MM-DD HH24:MI:SS')
         INTO v_nuevo, v_updated_by, v_updated_at;

    PERFORM set_config('app.datos_anteriores', '', true);
    PERFORM set_config('app.datos_nuevos', '', true);

    RETURN jsonb_build_object(
        'success', true,
        'message', CASE WHEN v_nuevo THEN 'Cliente activado' ELSE 'Cliente desactivado' END,
        'data', jsonb_build_object('id', p_id, 'activo', v_nuevo,
                                   'updated_by', v_updated_by,
                                   'updated_at', v_updated_at)
    );
END;
$function$;

ALTER FUNCTION ventas.fn_clientes_activar(bigint, boolean, bigint, varchar, varchar, inet, text, uuid)
    OWNER TO postgres;

COMMENT ON FUNCTION ventas.fn_clientes_activar(bigint, boolean, bigint, varchar, varchar, inet, text, uuid)
    IS 'Pone ventas.clientes.activo sin pasar por el formulario. Sin p_activo, alterna. No toca estado.';
