-- ===========================================================================
-- UN HORARIO EN USO NO SE VA A LA PAPELERA
-- ===========================================================================
-- Al enlazar el horario con la ficha del empleado quedó un hueco: se podía
-- mandar a la papelera un horario que diez personas tenían puesto. Esas
-- fichas se quedaban señalando algo que ya no sale en ninguna parte, y a la
-- hora de medir el atraso no había con qué compararlas.
--
-- Es la misma regla que ya tienen marcas (con productos) y cargos (con
-- empleados): si está en uso no se borra, se DESACTIVA. Un horario inactivo
-- no se puede asignar a nadie nuevo, pero a quien ya lo tiene se le sigue
-- midiendo igual.
--
-- De paso, la ficha del horario pasa a decir cuánta gente lo usa, que es lo
-- que hace falta para avisar ANTES de intentar borrarlo.
\set ON_ERROR_STOP on

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. LA FICHA DICE CUÁNTA GENTE LO USA
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION rh.fn_horarios_empleados_json(p_id bigint)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'rh'
AS $function$
    SELECT jsonb_build_object(
        'id',             h.id,
        'nombre',         h.nombre,
        'descripcion',    h.descripcion,
        'tolerancia_min', h.tolerancia_min,
        'activo',         h.activo,
        -- Lo que se ve de un vistazo en la rejilla, sin abrir la ficha
        'num_dias',     (SELECT COUNT(DISTINCT j.dia) FROM rh.horarios_empleados_jornadas j
                          WHERE j.horario_id = h.id AND j.activo),
        'num_jornadas', (SELECT COUNT(*) FROM rh.horarios_empleados_jornadas j
                          WHERE j.horario_id = h.id AND j.activo),
        -- Quién depende de él: es lo que decide si se puede eliminar
        'num_empleados', (SELECT COUNT(*) FROM rh.empleados e
                           WHERE e.horario_id = h.id AND e.deleted_at IS NULL),
        'horas_semana', COALESCE((SELECT ROUND(SUM(rh.fn_horarios_empleados_minutos(j.hora_inicio, j.hora_fin))::numeric / 60, 2)
                                    FROM rh.horarios_empleados_jornadas j
                                   WHERE j.horario_id = h.id AND j.activo), 0),
        'jornadas', COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
                       'id',          j.id,
                       'horario_id',  j.horario_id,
                       'dia',         j.dia,
                       'dia_nombre',  rh.fn_horarios_empleados_dia_nombre(j.dia),
                       'jornada',     j.jornada,
                       'hora_inicio', to_char(j.hora_inicio, 'HH24:MI'),
                       'hora_fin',    to_char(j.hora_fin, 'HH24:MI'),
                       'minutos',     rh.fn_horarios_empleados_minutos(j.hora_inicio, j.hora_fin),
                       'cruza_medianoche', j.hora_fin <= j.hora_inicio,
                       'activo',      j.activo)
                   ORDER BY j.dia, j.jornada)
              FROM rh.horarios_empleados_jornadas j
             WHERE j.horario_id = h.id), '[]'::jsonb),
        -- La papelera: NULL mientras el horario está vigente
        'deleted_at', to_char(h.deleted_at, 'YYYY-MM-DD HH24:MI:SS'),
        'deleted_by', h.deleted_by,
        'created_by', h.created_by,
        'updated_by', h.updated_by,
        'created_at', to_char(h.created_at, 'YYYY-MM-DD HH24:MI:SS'),
        'updated_at', to_char(h.updated_at, 'YYYY-MM-DD HH24:MI:SS')
    )
      FROM rh.horarios_empleados h
     WHERE h.id = p_id;
$function$;

-- ---------------------------------------------------------------------------
-- 2. CON GENTE ASIGNADA, NO SE VA A LA PAPELERA
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
    v_actual    rh.horarios_empleados%ROWTYPE;
    v_empleados bigint;
    v_datos     jsonb;
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

    -- EN USO: la ficha de esa gente se quedaría señalando algo que no sale en
    -- ninguna parte, y sin con qué medirles el atraso.
    SELECT COUNT(*) INTO v_empleados
      FROM rh.empleados e
     WHERE e.horario_id = p_id AND e.deleted_at IS NULL;

    IF v_empleados > 0 THEN
        RAISE EXCEPTION 'No se puede eliminar: % empleado(s) tienen este horario. Desactívelo en su lugar.', v_empleados
              USING ERRCODE = 'P0014';
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
-- 3. Y TAMPOCO SE BORRA DE VERDAD
-- ---------------------------------------------------------------------------
-- La clave foránea ya lo impedía, pero con el error en crudo de PostgreSQL.
-- Así se dice cuántos son, igual que arriba.
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
    v_nombres   text[];
    v_cuantos   integer;
    v_empleados bigint;
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

    -- Aquí se cuenta a TODOS, incluidos los que están en la papelera: la
    -- clave foránea tampoco distingue, y restaurar a alguien no puede fallar
    -- porque su horario ya no exista.
    SELECT COUNT(*) INTO v_empleados
      FROM rh.empleados e
     WHERE e.horario_id IN (SELECT (jsonb_array_elements_text(p_ids))::bigint);

    IF v_empleados > 0 THEN
        RAISE EXCEPTION 'No se puede borrar definitivamente: % empleado(s) lo tienen asignado', v_empleados
              USING ERRCODE = 'P0014';
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

-- ---------------------------------------------------------------------------
-- 4. VACIAR SALTA LOS QUE ESTÁN EN USO
-- ---------------------------------------------------------------------------
-- Vaciar no puede ser «o todo o nada»: se borra lo que se puede y el resto se
-- queda, igual que en la papelera de cargos.
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
     WHERE h.deleted_at IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM rh.empleados e WHERE e.horario_id = h.id);

    IF jsonb_array_length(v_ids) = 0 THEN
        RETURN jsonb_build_object('success', true,
            'message', 'No hay horarios que se puedan borrar definitivamente',
            'data', jsonb_build_object('eliminados', 0));
    END IF;

    RETURN rh.fn_horarios_empleados_eliminar_definitivo(v_ids, p_usuario_id, p_usuario_login,
                                                        p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);
END;
$function$;

COMMIT;
