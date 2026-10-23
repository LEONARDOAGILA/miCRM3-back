-- ===========================================================================
-- HORARIOS DE EMPLEADOS: PAPELERA DE RECICLAJE Y CÁLCULO DEL ATRASO
-- ===========================================================================
-- La papelera es la misma de marcas, cargos y horarios de seguridad: eliminar
-- es un borrado lógico (deleted_at / deleted_by), el horario sale del listado
-- y del selector PERO CONSERVA SUS JORNADAS, y desde la papelera se restaura
-- tal cual o se borra de verdad.
--
-- Al final va `fn_horarios_empleados_evaluar`, que es para lo que existe todo
-- esto: dada una marcación, dice en qué jornada cae y de cuántos minutos es
-- el atraso.
\set ON_ERROR_STOP on

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. A LA PAPELERA
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION rh.fn_horarios_empleados_eliminar(
    p_id             bigint,
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
    v_actual rh.horarios_empleados%ROWTYPE;
    v_datos  jsonb;
BEGIN
    PERFORM rh.fn_contexto_auditoria('rh.horarios_empleados', p_usuario_id, p_usuario_login,
                                     p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    SELECT * INTO v_actual FROM rh.horarios_empleados WHERE id = p_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'El horario no existe' USING ERRCODE = 'P0013';
    END IF;
    IF v_actual.deleted_at IS NOT NULL THEN
        RAISE EXCEPTION 'Ese horario ya está en la papelera' USING ERRCODE = 'P0019';
    END IF;

    v_datos := rh.fn_horarios_empleados_json(p_id);

    UPDATE rh.horarios_empleados
       SET deleted_at = CURRENT_TIMESTAMP,
           deleted_by = COALESCE(p_usuario_login, current_user),
           updated_by = COALESCE(p_usuario_login, current_user),
           updated_at = CURRENT_TIMESTAMP
     WHERE id = p_id;

    RETURN jsonb_build_object('success', true,
        'message', format('«%s» fue enviado a la papelera de reciclaje', v_actual.nombre),
        'data', v_datos);
END;
$function$;

-- ---------------------------------------------------------------------------
-- 2. LA PAPELERA
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION rh.fn_horarios_empleados_papelera_listar()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'rh'
AS $function$
DECLARE v_data jsonb;
BEGIN
    SELECT COALESCE(jsonb_agg(rh.fn_horarios_empleados_json(h.id) ORDER BY h.deleted_at DESC), '[]'::jsonb)
      INTO v_data
      FROM rh.horarios_empleados h
     WHERE h.deleted_at IS NOT NULL;

    RETURN jsonb_build_object('success', true, 'message', 'Papelera de horarios', 'data', v_data);
END;
$function$;

CREATE OR REPLACE FUNCTION rh.fn_horarios_empleados_restaurar(
    p_ids            jsonb,
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
    v_nombres text[];
    v_cuantos integer;
    v_choque  text;
BEGIN
    PERFORM rh.fn_contexto_auditoria('rh.horarios_empleados', p_usuario_id, p_usuario_login,
                                     p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    -- Mientras estaba dentro alguien pudo crear otro con ese nombre: se avisa
    -- con el nombre en vez de soltar el error del índice.
    SELECT string_agg(DISTINCT p.nombre, ', ') INTO v_choque
      FROM rh.horarios_empleados p
      JOIN rh.horarios_empleados v
        ON v.deleted_at IS NULL AND UPPER(TRIM(v.nombre)) = UPPER(TRIM(p.nombre))
     WHERE p.id IN (SELECT (jsonb_array_elements_text(p_ids))::bigint)
       AND p.deleted_at IS NOT NULL;

    IF v_choque IS NOT NULL THEN
        RAISE EXCEPTION 'No se puede restaurar: ya hay un horario vigente que se llama %', v_choque
              USING ERRCODE = 'P0006';
    END IF;

    SELECT array_agg(nombre) INTO v_nombres
      FROM rh.horarios_empleados
     WHERE id IN (SELECT (jsonb_array_elements_text(p_ids))::bigint)
       AND deleted_at IS NOT NULL;

    IF v_nombres IS NULL THEN
        RAISE EXCEPTION 'Sólo se puede restaurar lo que está en la papelera' USING ERRCODE = 'P0019';
    END IF;

    UPDATE rh.horarios_empleados
       SET deleted_at = NULL,
           deleted_by = NULL,
           updated_by = COALESCE(p_usuario_login, current_user),
           updated_at = CURRENT_TIMESTAMP
     WHERE id IN (SELECT (jsonb_array_elements_text(p_ids))::bigint)
       AND deleted_at IS NOT NULL;

    GET DIAGNOSTICS v_cuantos = ROW_COUNT;

    RETURN jsonb_build_object('success', true,
        'message', v_cuantos || ' horario(s) restaurado(s) con sus jornadas',
        'data', jsonb_build_object('nombres', to_jsonb(v_nombres), 'restaurados', v_cuantos));
END;
$function$;

CREATE OR REPLACE FUNCTION rh.fn_horarios_empleados_eliminar_definitivo(
    p_ids            jsonb,
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
    v_nombres text[];
    v_cuantos integer;
BEGIN
    PERFORM rh.fn_contexto_auditoria('rh.horarios_empleados', p_usuario_id, p_usuario_login,
                                     p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    SELECT array_agg(nombre) INTO v_nombres
      FROM rh.horarios_empleados
     WHERE id IN (SELECT (jsonb_array_elements_text(p_ids))::bigint)
       AND deleted_at IS NOT NULL;

    IF v_nombres IS NULL THEN
        RAISE EXCEPTION 'Sólo se puede eliminar definitivamente lo que está en la papelera' USING ERRCODE = 'P0019';
    END IF;

    -- Las jornadas se van con él: la clave foránea es ON DELETE CASCADE
    DELETE FROM rh.horarios_empleados
     WHERE id IN (SELECT (jsonb_array_elements_text(p_ids))::bigint)
       AND deleted_at IS NOT NULL;

    GET DIAGNOSTICS v_cuantos = ROW_COUNT;

    RETURN jsonb_build_object('success', true,
        'message', v_cuantos || ' horario(s) eliminado(s) definitivamente',
        'data', jsonb_build_object('nombres', to_jsonb(v_nombres), 'eliminados', v_cuantos));
EXCEPTION
    WHEN foreign_key_violation THEN
        RAISE EXCEPTION 'No se puede borrar definitivamente: tiene registros asociados' USING ERRCODE = 'P0014';
END;
$function$;

CREATE OR REPLACE FUNCTION rh.fn_horarios_empleados_papelera_vaciar(
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
DECLARE v_ids jsonb;
BEGIN
    SELECT COALESCE(jsonb_agg(h.id), '[]'::jsonb) INTO v_ids
      FROM rh.horarios_empleados h
     WHERE h.deleted_at IS NOT NULL;

    IF jsonb_array_length(v_ids) = 0 THEN
        RETURN jsonb_build_object('success', true,
            'message', 'No hay horarios que se puedan borrar definitivamente',
            'data', jsonb_build_object('eliminados', 0));
    END IF;

    RETURN rh.fn_horarios_empleados_eliminar_definitivo(v_ids, p_usuario_id, p_usuario_login,
                                                        p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);
END;
$function$;

-- ---------------------------------------------------------------------------
-- 3. PARA LO QUE EXISTE TODO ESTO: EL ATRASO
-- ---------------------------------------------------------------------------
-- Dado un horario y el momento de una marcación, dice a qué jornada
-- corresponde y de cuántos minutos es el atraso.
--
-- CÓMO ELIGE LA JORNADA: la del mismo día cuyo inicio esté más cerca de la
-- hora marcada, mirando también las que empezaron el día anterior y cruzaron
-- la medianoche. Quien llega ANTES de su hora no tiene atraso (sale 0), y la
-- tolerancia de la cabecera se descuenta del atraso: con cinco minutos de
-- gracia, llegar 08:04 a una jornada de 08:00 es llegar a tiempo.
--
-- No escribe nada: la usará el informe de atrasos y, si se quiere, la
-- marcación para avisar en el momento.
CREATE OR REPLACE FUNCTION rh.fn_horarios_empleados_evaluar(
    p_horario_id bigint,
    p_fecha_hora timestamptz
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'rh'
AS $function$
DECLARE
    v_h        rh.horarios_empleados%ROWTYPE;
    v_momento  timestamp;      -- sin zona: se compara contra horas de pared
    v_dia      integer;
    v_mejor    record;
BEGIN
    SELECT * INTO v_h FROM rh.horarios_empleados WHERE id = p_horario_id AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'message', 'El horario no existe', 'error_code', 'NO_EXISTE');
    END IF;

    v_momento := p_fecha_hora::timestamp;
    v_dia     := EXTRACT(ISODOW FROM v_momento)::integer;

    -- Las candidatas: las jornadas de hoy y las de ayer que cruzaron la
    -- medianoche, cada una con su inicio puesto en la fecha que le toca.
    SELECT * INTO v_mejor FROM (
        SELECT j.id, j.dia, j.jornada, j.hora_inicio, j.hora_fin,
               date_trunc('day', v_momento) + j.hora_inicio AS inicio_real
          FROM rh.horarios_empleados_jornadas j
         WHERE j.horario_id = p_horario_id AND j.activo AND j.dia = v_dia
        UNION ALL
        SELECT j.id, j.dia, j.jornada, j.hora_inicio, j.hora_fin,
               date_trunc('day', v_momento) - interval '1 day' + j.hora_inicio
          FROM rh.horarios_empleados_jornadas j
         WHERE j.horario_id = p_horario_id AND j.activo
           AND j.dia = CASE WHEN v_dia = 1 THEN 7 ELSE v_dia - 1 END
           AND j.hora_fin <= j.hora_inicio          -- sólo las que cruzan medianoche
    ) c
    -- La más cercana en el tiempo, antes o después
    ORDER BY abs(EXTRACT(EPOCH FROM (v_momento - c.inicio_real)))
    LIMIT 1;

    IF v_mejor IS NULL THEN
        RETURN jsonb_build_object('success', true,
            'message', 'El horario no tiene jornadas ese día',
            'data', jsonb_build_object(
                'dia', v_dia, 'dia_nombre', rh.fn_horarios_empleados_dia_nombre(v_dia),
                'jornada', NULL, 'estado', 'SIN JORNADA', 'atraso_min', 0));
    END IF;

    RETURN jsonb_build_object('success', true, 'message', 'Evaluado',
        'data', jsonb_build_object(
            'horario_id',     p_horario_id,
            'dia',            v_mejor.dia,
            'dia_nombre',     rh.fn_horarios_empleados_dia_nombre(v_mejor.dia),
            'jornada',        v_mejor.jornada,
            'hora_inicio',    to_char(v_mejor.hora_inicio, 'HH24:MI'),
            'hora_fin',       to_char(v_mejor.hora_fin, 'HH24:MI'),
            'hora_marcada',   to_char(v_momento, 'HH24:MI'),
            'tolerancia_min', v_h.tolerancia_min,
            -- Lo que se pasó de la hora, ya descontada la tolerancia; nunca negativo
            'atraso_min',     GREATEST(0,
                                 (EXTRACT(EPOCH FROM (v_momento - v_mejor.inicio_real))::integer / 60)
                                 - v_h.tolerancia_min),
            -- Lo que se pasó sin descontar nada, para el informe
            'diferencia_min', (EXTRACT(EPOCH FROM (v_momento - v_mejor.inicio_real))::integer / 60),
            'estado', CASE
                WHEN (EXTRACT(EPOCH FROM (v_momento - v_mejor.inicio_real))::integer / 60) <= 0
                    THEN 'A TIEMPO'
                WHEN (EXTRACT(EPOCH FROM (v_momento - v_mejor.inicio_real))::integer / 60) <= v_h.tolerancia_min
                    THEN 'EN TOLERANCIA'
                ELSE 'ATRASO' END));
END;
$function$;

COMMIT;
