-- ===========================================================================
-- HORARIOS DE ACCESO: DATOS DE PRUEBA
-- ===========================================================================
-- Seis horarios con los casos que se dan de verdad, para probar la pantalla y
-- el corte del middleware sin inventárselos uno a uno:
--
--   1. OFICINA PARTIDA         L-V, 08-12 y 14-18. A las 13:00 no entra nadie.
--   2. OFICINA CORRIDA         L-V, 08-18 de un tirón.
--   3. COMERCIAL CON SABADO    L-V partido y el sábado sólo por la mañana.
--   4. TURNO ROTATIVO          L-S de 06:00 a 14:00.
--   5. GUARDIA NOCTURNA        Todos los días 22:00 → 06:00. CRUZA LA MEDIANOCHE.
--   6. SOPORTE 24/7            Los siete días completos, de 00:00 a 23:59.
--
-- NINGUNO SE LE ASIGNA A NADIE: se crean y ya está. Ponerle uno a un usuario
-- es lo que decide a qué horas puede entrar al CRM, y eso se hace a mano en
-- su ficha sabiendo lo que se hace.
--
-- Se insertan sólo si no están: el fichero se puede volver a pasar sin que
-- salgan repetidos. Para quitarlos, al final del fichero está el DELETE.
\set ON_ERROR_STOP on
\pset tuples_only on
\pset format unaligned

BEGIN;

-- Quién los crea, para poder encontrarlos y borrarlos después. El disparador
-- de auditoría pisa `created_by` con esto.
SELECT set_config('app.usuario_login', 'datos-prueba', true);

-- ---------------------------------------------------------------------------
-- 1. OFICINA PARTIDA (el caso que antes no se podía: cerrar el almuerzo)
-- ---------------------------------------------------------------------------
SELECT seguridad.fn_horarios_crear(
    'OFICINA PARTIDA 8-12 / 14-18',
    'Lunes a viernes, mañana y tarde. A la hora del almuerzo el acceso queda cerrado.',
    true,
    (SELECT jsonb_agg(j) FROM (
        SELECT jsonb_build_object('dia', d, 'jornada', 1, 'hora_inicio', '08:00', 'hora_fin', '12:00', 'activo', true) AS j
          FROM generate_series(1, 5) d
        UNION ALL
        SELECT jsonb_build_object('dia', d, 'jornada', 2, 'hora_inicio', '14:00', 'hora_fin', '18:00', 'activo', true)
          FROM generate_series(1, 5) d
    ) t),
    NULL, 'datos-prueba', 'Datos de prueba')
 WHERE NOT EXISTS (SELECT 1 FROM seguridad.chorarios WHERE UPPER(TRIM(nombre)) = 'OFICINA PARTIDA 8-12 / 14-18');

-- ---------------------------------------------------------------------------
-- 2. OFICINA CORRIDA
-- ---------------------------------------------------------------------------
SELECT seguridad.fn_horarios_crear(
    'OFICINA CORRIDA 8-18',
    'Lunes a viernes de un tirón, sin cerrar al mediodía.',
    true,
    (SELECT jsonb_agg(jsonb_build_object('dia', d, 'jornada', 1, 'hora_inicio', '08:00', 'hora_fin', '18:00', 'activo', true))
       FROM generate_series(1, 5) d),
    NULL, 'datos-prueba', 'Datos de prueba')
 WHERE NOT EXISTS (SELECT 1 FROM seguridad.chorarios WHERE UPPER(TRIM(nombre)) = 'OFICINA CORRIDA 8-18');

-- ---------------------------------------------------------------------------
-- 3. COMERCIAL CON SÁBADO
-- ---------------------------------------------------------------------------
SELECT seguridad.fn_horarios_crear(
    'COMERCIAL CON SABADO',
    'Lunes a viernes 09:00-13:00 y 15:00-19:00; el sábado sólo la mañana.',
    true,
    (SELECT jsonb_agg(j) FROM (
        SELECT jsonb_build_object('dia', d, 'jornada', 1, 'hora_inicio', '09:00', 'hora_fin', '13:00', 'activo', true) AS j
          FROM generate_series(1, 6) d
        UNION ALL
        SELECT jsonb_build_object('dia', d, 'jornada', 2, 'hora_inicio', '15:00', 'hora_fin', '19:00', 'activo', true)
          FROM generate_series(1, 5) d
    ) t),
    NULL, 'datos-prueba', 'Datos de prueba')
 WHERE NOT EXISTS (SELECT 1 FROM seguridad.chorarios WHERE UPPER(TRIM(nombre)) = 'COMERCIAL CON SABADO');

-- ---------------------------------------------------------------------------
-- 4. TURNO ROTATIVO DE MAÑANA
-- ---------------------------------------------------------------------------
SELECT seguridad.fn_horarios_crear(
    'TURNO ROTATIVO 6-2',
    'Lunes a sábado de 06:00 a 14:00, para el turno de la mañana.',
    true,
    (SELECT jsonb_agg(jsonb_build_object('dia', d, 'jornada', 1, 'hora_inicio', '06:00', 'hora_fin', '14:00', 'activo', true))
       FROM generate_series(1, 6) d),
    NULL, 'datos-prueba', 'Datos de prueba')
 WHERE NOT EXISTS (SELECT 1 FROM seguridad.chorarios WHERE UPPER(TRIM(nombre)) = 'TURNO ROTATIVO 6-2');

-- ---------------------------------------------------------------------------
-- 5. GUARDIA NOCTURNA (la franja CRUZA LA MEDIANOCHE)
-- ---------------------------------------------------------------------------
SELECT seguridad.fn_horarios_crear(
    'GUARDIA NOCTURNA 10PM-6AM',
    'Todos los días de 22:00 a 06:00 del día siguiente. Quien entre a la 01:00 sigue dentro de la franja que empezó ayer.',
    true,
    (SELECT jsonb_agg(jsonb_build_object('dia', d, 'jornada', 1, 'hora_inicio', '22:00', 'hora_fin', '06:00', 'activo', true))
       FROM generate_series(1, 7) d),
    NULL, 'datos-prueba', 'Datos de prueba')
 WHERE NOT EXISTS (SELECT 1 FROM seguridad.chorarios WHERE UPPER(TRIM(nombre)) = 'GUARDIA NOCTURNA 10PM-6AM');

-- ---------------------------------------------------------------------------
-- 6. SOPORTE 24/7
-- ---------------------------------------------------------------------------
SELECT seguridad.fn_horarios_crear(
    'SOPORTE 24/7',
    'Los siete días completos. Para quien no debe quedarse fuera nunca.',
    true,
    (SELECT jsonb_agg(jsonb_build_object('dia', d, 'jornada', 1, 'hora_inicio', '00:00', 'hora_fin', '23:59', 'activo', true))
       FROM generate_series(1, 7) d),
    NULL, 'datos-prueba', 'Datos de prueba')
 WHERE NOT EXISTS (SELECT 1 FROM seguridad.chorarios WHERE UPPER(TRIM(nombre)) = 'SOPORTE 24/7');

-- ---------------------------------------------------------------------------
-- 7. CÓMO QUEDARON, Y SI DEJAN ENTRAR AHORA MISMO
-- ---------------------------------------------------------------------------
SELECT 'horario ' || c.id || ': ' || rpad(c.nombre, 30)
    || ' · ' || (seguridad.fn_horarios_json(c.id)->>'num_dias') || ' dias'
    || ' · ' || (seguridad.fn_horarios_json(c.id)->>'num_jornadas') || ' franjas'
    || ' · ' || lpad((seguridad.fn_horarios_json(c.id)->>'horas_semana'), 6) || ' h/semana'
    || ' · ahora ' || CASE WHEN (seguridad.fn_horarios_puede_entrar(c.id)->>'permitido')::boolean
                           THEN 'ENTRA' ELSE 'no entra' END
  FROM seguridad.chorarios c
 WHERE c.created_by = 'datos-prueba' AND c.deleted_at IS NULL
 ORDER BY c.id;

COMMIT;

-- ===========================================================================
-- PARA QUITARLOS
-- ===========================================================================
-- Primero las franjas y después la cabecera. Si alguno está asignado a un
-- usuario o a un grupo, la clave foránea lo impedirá: cámbiaselo antes.
--
--   DELETE FROM seguridad.dhorarios
--    WHERE chorario_id IN (SELECT id FROM seguridad.chorarios WHERE created_by = 'datos-prueba');
--   DELETE FROM seguridad.chorarios WHERE created_by = 'datos-prueba';
-- ===========================================================================
