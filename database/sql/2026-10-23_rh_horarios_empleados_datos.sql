-- ===========================================================================
-- HORARIOS DE EMPLEADOS: DATOS DE PRUEBA
-- ===========================================================================
-- Seis horarios con los casos que se dan de verdad, para tener con qué probar
-- la pantalla y los atrasos sin inventárselos uno a uno:
--
--   1. Administrativo 8-5        partido, lunes a viernes, 5 min de tolerancia
--   2. Jornada corrida 8-4       una sola franja, lunes a viernes
--   3. Comercial lunes a sábado  partido, con el sábado sólo por la mañana
--   4. Rotativo mañana           06:00-14:00 de lunes a sábado, sin tolerancia
--   5. Guardia nocturna          22:00-06:00, CRUZA LA MEDIANOCHE
--   6. Medio tiempo tarde        14:00-18:00, lunes a viernes
--
-- Se insertan sólo si no están: el fichero se puede volver a pasar sin que
-- salgan repetidos. Para quitarlos, al final del fichero está el DELETE.
\set ON_ERROR_STOP on
\pset tuples_only on
\pset format unaligned

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. ADMINISTRATIVO 8-5 (el típico: mañana y tarde con hora de almuerzo)
-- ---------------------------------------------------------------------------
SELECT rh.fn_horarios_empleados_crear(
    'ADMINISTRATIVO 8-5',
    'Lunes a viernes, 08:00-12:00 y 14:00-18:00. Cinco minutos de gracia.',
    5, true,
    (SELECT jsonb_agg(j) FROM (
        SELECT jsonb_build_object('dia', d, 'jornada', 1, 'hora_inicio', '08:00', 'hora_fin', '12:00', 'activo', true) AS j
          FROM generate_series(1, 5) d
        UNION ALL
        SELECT jsonb_build_object('dia', d, 'jornada', 2, 'hora_inicio', '14:00', 'hora_fin', '18:00', 'activo', true)
          FROM generate_series(1, 5) d
    ) t),
    NULL, 'datos-prueba', 'Datos de prueba')
 WHERE NOT EXISTS (SELECT 1 FROM rh.horarios_empleados WHERE UPPER(TRIM(nombre)) = 'ADMINISTRATIVO 8-5');

-- ---------------------------------------------------------------------------
-- 2. JORNADA CORRIDA 8-4 (una sola franja al día)
-- ---------------------------------------------------------------------------
SELECT rh.fn_horarios_empleados_crear(
    'JORNADA CORRIDA 8-4',
    'Lunes a viernes de corrido, 08:00-16:00. Diez minutos de gracia.',
    10, true,
    (SELECT jsonb_agg(jsonb_build_object('dia', d, 'jornada', 1, 'hora_inicio', '08:00', 'hora_fin', '16:00', 'activo', true))
       FROM generate_series(1, 5) d),
    NULL, 'datos-prueba', 'Datos de prueba')
 WHERE NOT EXISTS (SELECT 1 FROM rh.horarios_empleados WHERE UPPER(TRIM(nombre)) = 'JORNADA CORRIDA 8-4');

-- ---------------------------------------------------------------------------
-- 3. COMERCIAL LUNES A SÁBADO (el sábado sólo la mañana)
-- ---------------------------------------------------------------------------
SELECT rh.fn_horarios_empleados_crear(
    'COMERCIAL LUNES A SABADO',
    'Lunes a viernes 09:00-13:00 y 15:00-19:00; sábado sólo 09:00-13:00.',
    5, true,
    (SELECT jsonb_agg(j) FROM (
        SELECT jsonb_build_object('dia', d, 'jornada', 1, 'hora_inicio', '09:00', 'hora_fin', '13:00', 'activo', true) AS j
          FROM generate_series(1, 6) d
        UNION ALL
        SELECT jsonb_build_object('dia', d, 'jornada', 2, 'hora_inicio', '15:00', 'hora_fin', '19:00', 'activo', true)
          FROM generate_series(1, 5) d
    ) t),
    NULL, 'datos-prueba', 'Datos de prueba')
 WHERE NOT EXISTS (SELECT 1 FROM rh.horarios_empleados WHERE UPPER(TRIM(nombre)) = 'COMERCIAL LUNES A SABADO');

-- ---------------------------------------------------------------------------
-- 4. ROTATIVO MAÑANA (turno de planta, sin tolerancia)
-- ---------------------------------------------------------------------------
SELECT rh.fn_horarios_empleados_crear(
    'ROTATIVO MANANA 6-2',
    'Lunes a sábado de 06:00 a 14:00. Sin tolerancia: a las 06:01 ya es atraso.',
    0, true,
    (SELECT jsonb_agg(jsonb_build_object('dia', d, 'jornada', 1, 'hora_inicio', '06:00', 'hora_fin', '14:00', 'activo', true))
       FROM generate_series(1, 6) d),
    NULL, 'datos-prueba', 'Datos de prueba')
 WHERE NOT EXISTS (SELECT 1 FROM rh.horarios_empleados WHERE UPPER(TRIM(nombre)) = 'ROTATIVO MANANA 6-2');

-- ---------------------------------------------------------------------------
-- 5. GUARDIA NOCTURNA (la jornada CRUZA LA MEDIANOCHE)
-- ---------------------------------------------------------------------------
SELECT rh.fn_horarios_empleados_crear(
    'GUARDIA NOCTURNA 10PM-6AM',
    'Todos los días de 22:00 a 06:00 del día siguiente. Quince minutos de gracia.',
    15, true,
    (SELECT jsonb_agg(jsonb_build_object('dia', d, 'jornada', 1, 'hora_inicio', '22:00', 'hora_fin', '06:00', 'activo', true))
       FROM generate_series(1, 7) d),
    NULL, 'datos-prueba', 'Datos de prueba')
 WHERE NOT EXISTS (SELECT 1 FROM rh.horarios_empleados WHERE UPPER(TRIM(nombre)) = 'GUARDIA NOCTURNA 10PM-6AM');

-- ---------------------------------------------------------------------------
-- 6. MEDIO TIEMPO TARDE
-- ---------------------------------------------------------------------------
SELECT rh.fn_horarios_empleados_crear(
    'MEDIO TIEMPO TARDE',
    'Lunes a viernes de 14:00 a 18:00.',
    5, true,
    (SELECT jsonb_agg(jsonb_build_object('dia', d, 'jornada', 1, 'hora_inicio', '14:00', 'hora_fin', '18:00', 'activo', true))
       FROM generate_series(1, 5) d),
    NULL, 'datos-prueba', 'Datos de prueba')
 WHERE NOT EXISTS (SELECT 1 FROM rh.horarios_empleados WHERE UPPER(TRIM(nombre)) = 'MEDIO TIEMPO TARDE');

SELECT 'horario ' || id || ': ' || nombre
    || ' · ' || (rh.fn_horarios_empleados_json(id)->>'num_dias') || ' días'
    || ' · ' || (rh.fn_horarios_empleados_json(id)->>'num_jornadas') || ' jornadas'
    || ' · ' || (rh.fn_horarios_empleados_json(id)->>'horas_semana') || ' h/semana'
    || ' · tolerancia ' || tolerancia_min || ' min'
  FROM rh.horarios_empleados
 WHERE created_by = 'datos-prueba' AND deleted_at IS NULL
 ORDER BY id;

COMMIT;

-- ===========================================================================
-- PARA QUITARLOS
-- ===========================================================================
-- Borra los seis y sus jornadas (la clave foránea es ON DELETE CASCADE). Si
-- alguno está asignado a un empleado, la base lo impedirá: quítaselo antes
-- desde su ficha.
--
--   DELETE FROM rh.horarios_empleados WHERE created_by = 'datos-prueba';
-- ===========================================================================
