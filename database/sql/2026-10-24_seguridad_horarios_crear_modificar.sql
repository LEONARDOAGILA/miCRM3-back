-- ===========================================================================
-- CREAR Y MODIFICAR UN HORARIO DE ACCESO, CON SUS CUATRO JORNADAS
-- ===========================================================================
-- Las dos funciones insertaban las franjas a mano, sin `jornada`: con la
-- columna nueva todas caían en la 1 y la segunda franja del mismo día chocaba
-- contra el índice único. Ahora delegan en seguridad.fn_horarios_guardar_
-- jornadas, que es la que sabe del tope de cuatro, de las horas que se pisan y
-- de las que cruzan la medianoche.
--
-- SE MANTIENE EL CONTRATO DE ANTES: estas dos no lanzan excepción, contestan
-- {success:false, message, error_code}, que es lo que espera HorarioController.
-- Lo que sí lanza es la función de las jornadas, así que se captura y se
-- traduce a esa misma forma.
--
-- `p_dhorario` sigue llamándose así —es lo que manda el formulario— pero cada
-- elemento admite ahora `jornada`; sin ella se entiende que es la 1, que es lo
-- que había.
\set ON_ERROR_STOP on

BEGIN;

CREATE OR REPLACE FUNCTION seguridad.fn_horarios_crear(
    p_nombre         character varying,
    p_activo         boolean DEFAULT true,
    p_dhorario       jsonb   DEFAULT NULL::jsonb,
    p_usuario_id     bigint  DEFAULT NULL::bigint,
    p_usuario_login  character varying DEFAULT NULL::character varying,
    p_usuario_nombre character varying DEFAULT NULL::character varying,
    p_ip_address     inet    DEFAULT NULL::inet,
    p_user_agent     text    DEFAULT NULL::text,
    p_request_id     uuid    DEFAULT NULL::uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'seguridad', 'auditoria'
AS $function$
DECLARE
    v_id bigint;
BEGIN
    PERFORM set_config('app.usuario_id',     COALESCE(p_usuario_id::TEXT, ''), true);
    PERFORM set_config('app.usuario_login',  COALESCE(p_usuario_login, current_user), true);
    PERFORM set_config('app.usuario_nombre', COALESCE(p_usuario_nombre, current_user), true);
    PERFORM set_config('app.ip_address',     p_ip_address::TEXT, true);
    PERFORM set_config('app.user_agent',     p_user_agent, true);
    PERFORM set_config('app.request_id',     p_request_id::TEXT, true);
    PERFORM set_config('app.modulo',         'seguridad.chorarios', true);

    -- Lo que mira el disparador de auditoría para registrar las franjas
    IF p_dhorario IS NOT NULL THEN
        PERFORM set_config('app.dhorario_nuevos', p_dhorario::TEXT, true);
    END IF;

    IF p_nombre IS NULL OR TRIM(p_nombre) = '' THEN
        RETURN jsonb_build_object('success', false, 'message', 'El nombre del horario es obligatorio',
                                  'error_code', 'NOMBRE_REQUERIDO');
    END IF;

    -- `deleted_at IS NULL`: uno en la papelera no reserva su nombre
    IF EXISTS (SELECT 1 FROM seguridad.chorarios
                WHERE UPPER(TRIM(nombre)) = UPPER(TRIM(p_nombre)) AND deleted_at IS NULL) THEN
        RETURN jsonb_build_object('success', false, 'message', 'Ya existe un horario con ese nombre',
                                  'error_code', 'NOMBRE_DUPLICADO');
    END IF;

    INSERT INTO seguridad.chorarios (nombre, activo)
    VALUES (TRIM(p_nombre), COALESCE(p_activo, true))
    RETURNING id INTO v_id;

    PERFORM seguridad.fn_horarios_guardar_jornadas(v_id, p_dhorario);

    RETURN jsonb_build_object('success', true, 'message', 'Horario creado exitosamente',
                              'data', seguridad.fn_horarios_json(v_id));
EXCEPTION
    -- Las jornadas sí lanzan; aquí se traduce a la forma que espera el
    -- controlador, con su mensaje tal cual para que el usuario lo lea.
    WHEN OTHERS THEN
        RETURN jsonb_build_object('success', false, 'message', SQLERRM, 'error_code', SQLSTATE);
END;
$function$;

CREATE OR REPLACE FUNCTION seguridad.fn_horarios_modificar(
    p_id             bigint,
    p_nombre         character varying,
    p_activo         boolean DEFAULT true,
    p_dhorario       jsonb   DEFAULT NULL::jsonb,
    p_usuario_id     bigint  DEFAULT NULL::bigint,
    p_usuario_login  character varying DEFAULT NULL::character varying,
    p_usuario_nombre character varying DEFAULT NULL::character varying,
    p_ip_address     inet    DEFAULT NULL::inet,
    p_user_agent     text    DEFAULT NULL::text,
    p_request_id     uuid    DEFAULT NULL::uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'seguridad', 'auditoria'
AS $function$
DECLARE
    v_actual  seguridad.chorarios%ROWTYPE;
    v_viejos  jsonb;
BEGIN
    PERFORM set_config('app.usuario_id',     COALESCE(p_usuario_id::TEXT, ''), true);
    PERFORM set_config('app.usuario_login',  COALESCE(p_usuario_login, current_user), true);
    PERFORM set_config('app.usuario_nombre', COALESCE(p_usuario_nombre, current_user), true);
    PERFORM set_config('app.ip_address',     p_ip_address::TEXT, true);
    PERFORM set_config('app.user_agent',     p_user_agent, true);
    PERFORM set_config('app.request_id',     p_request_id::TEXT, true);
    PERFORM set_config('app.modulo',         'seguridad.chorarios', true);

    SELECT * INTO v_actual FROM seguridad.chorarios WHERE id = p_id;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'message', 'El horario no existe',
                                  'error_code', 'HORARIO_NO_EXISTE');
    END IF;
    IF v_actual.deleted_at IS NOT NULL THEN
        RETURN jsonb_build_object('success', false,
                                  'message', 'Ese horario está en la papelera de reciclaje: restáurelo antes de modificarlo',
                                  'error_code', 'EN_PAPELERA');
    END IF;

    IF p_nombre IS NULL OR TRIM(p_nombre) = '' THEN
        RETURN jsonb_build_object('success', false, 'message', 'El nombre del horario es obligatorio',
                                  'error_code', 'NOMBRE_REQUERIDO');
    END IF;

    IF EXISTS (SELECT 1 FROM seguridad.chorarios
                WHERE UPPER(TRIM(nombre)) = UPPER(TRIM(p_nombre))
                  AND id <> p_id AND deleted_at IS NULL) THEN
        RETURN jsonb_build_object('success', false, 'message', 'Ya existe otro horario con ese nombre',
                                  'error_code', 'NOMBRE_DUPLICADO');
    END IF;

    -- Las franjas de antes, para que la auditoría pueda comparar
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'id', d.id, 'dia', d.dia, 'jornada', d.jornada,
               'hora_inicio', d.hora_inicio, 'hora_fin', d.hora_fin, 'activo', d.activo)
               ORDER BY d.dia, d.jornada), '[]'::jsonb)
      INTO v_viejos
      FROM seguridad.dhorarios d WHERE d.chorario_id = p_id;

    PERFORM set_config('app.dhorario_viejos', v_viejos::TEXT, true);
    IF p_dhorario IS NOT NULL THEN
        PERFORM set_config('app.dhorario_nuevos', p_dhorario::TEXT, true);
    END IF;

    UPDATE seguridad.chorarios
       SET nombre = TRIM(p_nombre),
           activo = COALESCE(p_activo, activo)
     WHERE id = p_id;

    PERFORM seguridad.fn_horarios_guardar_jornadas(p_id, p_dhorario);

    RETURN jsonb_build_object('success', true, 'message', 'Horario actualizado exitosamente',
                              'data', seguridad.fn_horarios_json(p_id));
EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object('success', false, 'message', SQLERRM, 'error_code', SQLSTATE);
END;
$function$;

COMMIT;
