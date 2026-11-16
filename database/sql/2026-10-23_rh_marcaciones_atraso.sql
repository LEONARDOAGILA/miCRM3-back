-- ===========================================================================
-- EL ATRASO EN EL LISTADO DE MARCACIONES
-- ===========================================================================
-- Cada marcación de ENTRADA se compara con el horario del empleado y dice de
-- cuántos minutos fue el atraso. Lo calcula rh.fn_horarios_empleados_evaluar,
-- que ya sabe de jornadas, tolerancia y turnos que cruzan la medianoche; aquí
-- sólo se le pregunta y se aplana el resultado para la rejilla.
--
-- TRES CASOS QUE NO SON UN ATRASO Y NO HAY QUE CONFUNDIR:
--
--   · LA SALIDA. Salir a las 18:05 no es llegar tarde. En las marcaciones de
--     SALIDA el atraso queda en NULL y la columna sale vacía.
--   · SIN HORARIO. Quien no tiene horario asignado marca igual, pero no hay
--     con qué compararlo: sale «SIN HORARIO», no «a tiempo».
--   · SIN JORNADA. Tiene horario, pero ese día no trabaja (un domingo, por
--     ejemplo). Marcó, y es un dato, pero no se le cuenta atraso.
--
-- Se toca sólo fn_marcaciones_json, que es por donde pasan el listado, la
-- ficha y el modal: con eso los tres enseñan lo mismo.
\set ON_ERROR_STOP on

BEGIN;

CREATE OR REPLACE FUNCTION rh.fn_marcaciones_json(p_id bigint)
RETURNS jsonb
LANGUAGE sql
STABLE
AS $function$
    SELECT jsonb_build_object(
        'id',                   m.id,
        'empleado_id',          m.empleado_id,
        'empleado',             TRIM(CONCAT_WS(' ', e.nombres, e.apellidos)),
        'identificacion',       e.numero_identificacion,
        'cargo',                c.nombre,
        'departamento',         d.nombre,
        'empleado_foto',        e.foto,
        'tipo',                 m.tipo,
        'fecha_hora',           to_char(m.fecha_hora, 'YYYY-MM-DD HH24:MI:SS'),
        'fecha',                to_char(m.fecha, 'YYYY-MM-DD'),
        'hora',                 to_char(m.fecha_hora, 'HH24:MI:SS'),
        'origen',               m.origen,
        'similitud',            m.similitud,
        'dispositivo',          m.dispositivo,
        'latitud',              m.latitud,
        'longitud',             m.longitud,
        -- Dónde fue: el enlace para abrirlo en el mapa y con cuánto error
        'link_ubicacion',       m.link_ubicacion,
        'precision_m',          m.precision_m,
        'coordenadas',          CASE WHEN m.latitud IS NULL OR m.longitud IS NULL THEN NULL
                                     ELSE to_char(m.latitud, 'FM999990.000000') || ', ' ||
                                          to_char(m.longitud, 'FM999990.000000') END,
        'foto',                 m.foto,
        'observacion',          m.observacion,

        -- ---------- EL HORARIO Y EL ATRASO ----------
        'horario_id',           e.horario_id,
        'horario_nombre',       ho.nombre,
        'tolerancia_min',       ho.tolerancia_min,
        -- Qué jornada le tocaba y a qué hora empezaba
        'jornada',              (ev.v->>'jornada')::integer,
        'hora_esperada',        ev.v->>'hora_inicio',
        -- Los minutos que se pasó, ya descontada la tolerancia
        'atraso_min',           (ev.v->>'atraso_min')::integer,
        -- Y los que se pasó sin descontar nada, para quien quiera el dato crudo
        'diferencia_min',       (ev.v->>'diferencia_min')::integer,
        'atraso_estado',        CASE
                                    -- Salir tarde no es llegar tarde
                                    WHEN m.tipo <> 'ENTRADA'     THEN NULL
                                    WHEN e.horario_id IS NULL    THEN 'SIN HORARIO'
                                    ELSE ev.v->>'estado'
                                END,

        'created_by',           m.created_by,
        'updated_by',           m.updated_by,
        'created_at',           to_char(m.created_at, 'YYYY-MM-DD HH24:MI:SS'),
        'updated_at',           to_char(m.updated_at, 'YYYY-MM-DD HH24:MI:SS')
    )
    FROM rh.marcaciones m
    JOIN rh.empleados e      ON e.id = m.empleado_id
    LEFT JOIN rh.cargos c    ON c.id = e.cargo_id
    LEFT JOIN rh.departamentos d ON d.id = e.departamento_id
    LEFT JOIN rh.horarios_empleados ho ON ho.id = e.horario_id
    -- LATERAL y no un subselect por campo: así se evalúa UNA vez por fila en
    -- lugar de cuatro. El WHERE de dentro es el que deja fuera las salidas y
    -- a quien no tiene horario, y entonces `v` llega como NULL.
    LEFT JOIN LATERAL (
        SELECT rh.fn_horarios_empleados_evaluar(e.horario_id, m.fecha_hora)->'data' AS v
         WHERE m.tipo = 'ENTRADA' AND e.horario_id IS NOT NULL
    ) ev ON true
    WHERE m.id = p_id;
$function$;

COMMIT;
