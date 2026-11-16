-- ===========================================================================
-- MARCACIONES DE PRUEBA, PARA VER CÓMO SALEN LOS ATRASOS
-- ===========================================================================
-- Cuatro empleados de prueba, cada uno con un horario distinto, y cuatro días
-- de marcaciones con los casos que interesan: a tiempo, dentro de la
-- tolerancia, tarde, muy tarde, un día que no trabaja y un turno de noche.
--
-- NO SE TOCA A NADIE REAL. Los cuatro se llaman «PRUEBA ATRASOS», llevan
-- `created_by = 'datos-prueba'` y sus cédulas empiezan por 9999, así que se
-- borran de una vez con el DELETE del final.
--
-- LAS FECHAS SON HOY Y LOS TRES DÍAS ANTERIORES. El listado de Marcaciones
-- abre filtrado por el día de hoy, así que si se sembraran en fechas fijas no
-- se vería nada al entrar. Los días que caigan en fin de semana saldrán como
-- «No trabaja» para quien no tenga jornada ese día, que también es un caso
-- que conviene ver.
\set ON_ERROR_STOP on
\pset tuples_only on
\pset format unaligned

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. LOS CUATRO EMPLEADOS, CADA UNO CON SU HORARIO
-- ---------------------------------------------------------------------------
-- Se crean con la función de siempre, así que pasan por todas sus reglas.
DO $$
DECLARE
    v_cargo        bigint;
    v_departamento bigint;
    v_gente        text[][] := ARRAY[
        ['9999000001', 'ANA',   'PRUEBA ATRASOS', 'ADMINISTRATIVO 8-5'],
        ['9999000002', 'BRUNO', 'PRUEBA ATRASOS', 'JORNADA CORRIDA 8-4'],
        ['9999000003', 'CARLA', 'PRUEBA ATRASOS', 'ROTATIVO MANANA 6-2'],
        ['9999000004', 'DIEGO', 'PRUEBA ATRASOS', 'GUARDIA NOCTURNA 10PM-6AM']
    ];
    v_fila    text[];
    v_horario bigint;
BEGIN
    SELECT id INTO v_cargo        FROM rh.cargos        WHERE deleted_at IS NULL ORDER BY id LIMIT 1;
    SELECT id INTO v_departamento FROM rh.departamentos WHERE deleted_at IS NULL ORDER BY id LIMIT 1;

    FOREACH v_fila SLICE 1 IN ARRAY v_gente LOOP
        CONTINUE WHEN EXISTS (SELECT 1 FROM rh.empleados WHERE numero_identificacion = v_fila[1]);

        SELECT id INTO v_horario FROM rh.horarios_empleados
         WHERE nombre = v_fila[4] AND deleted_at IS NULL;

        PERFORM rh.fn_empleados_crear(
            v_fila[1], 'CC', v_fila[2], v_fila[3],
            LOWER(v_fila[2]) || '.atrasos@empresa.com',
            NULL, NULL, NULL, NULL, NULL, NULL,
            v_cargo, v_departamento, NULL,
            CURRENT_DATE - 365, NULL, 'ACTIVO', 'INDEFINIDO', NULL, true,
            NULL,          -- sin sucursal: aquí lo que se prueba es la hora
            v_horario,
            NULL, 'datos-prueba', 'Datos de prueba');
    END LOOP;
END $$;

-- ---------------------------------------------------------------------------
-- 2. LOS CUATRO DÍAS DE MARCACIONES
-- ---------------------------------------------------------------------------
-- Se insertan directo en la tabla y no por fn_marcaciones_registrar: aquélla
-- comprueba el perímetro de la sucursal y exige esperar entre una marcación y
-- la siguiente, que es lo correcto en producción pero impide sembrar varios
-- días de golpe.
DO $$
DECLARE
    v_dia      date;
    v_i        integer;
    v_emp      record;
    -- Minutos de diferencia con la hora de entrada, un patrón por día.
    -- Negativo = llegó antes. Así cada empleado enseña los cuatro estados.
    v_desfases integer[][] := ARRAY[
        ARRAY[  4,  20,  -4,  75],   -- ANA   (tolerancia del horario: 5)
        ARRAY[  9,  11, -15,   2],   -- BRUNO (10)
        ARRAY[  0,   1,  35,  -5],   -- CARLA (0, no perdona nada)
        ARRAY[ -5,  40,   2, -10]    -- DIEGO (15, turno de noche)
    ];
    v_fila     integer;
    v_entrada  time;
    v_salida   time;
    v_cuantas  integer := 0;
BEGIN
    IF EXISTS (SELECT 1 FROM rh.marcaciones WHERE created_by = 'datos-prueba') THEN
        RAISE NOTICE 'Las marcaciones de prueba ya estaban: no se vuelven a crear';
        RETURN;
    END IF;

    -- QUIÉN LAS CREA. El disparador de auditoría pisa `created_by` con lo que
    -- diga `app.usuario_login`, y si no hay nada pone el usuario de la base.
    -- Sin esta línea las marcaciones quedan como 'postgres' y el DELETE del
    -- final no las encuentra.
    PERFORM set_config('app.usuario_login', 'datos-prueba', true);

    v_fila := 0;
    FOR v_emp IN
        SELECT e.id, e.nombres, e.numero_identificacion,
               -- La primera jornada del horario: la hora a la que se le espera
               (SELECT MIN(j.hora_inicio) FROM rh.horarios_empleados_jornadas j
                 WHERE j.horario_id = e.horario_id AND j.activo) AS entra,
               (SELECT MAX(j.hora_fin) FROM rh.horarios_empleados_jornadas j
                 WHERE j.horario_id = e.horario_id AND j.activo) AS sale
          FROM rh.empleados e
         WHERE e.numero_identificacion LIKE '9999%'
         ORDER BY e.numero_identificacion
    LOOP
        v_fila := v_fila + 1;

        FOR v_i IN 0..3 LOOP
            v_dia := CURRENT_DATE - v_i;

            -- La entrada, movida los minutos del patrón
            v_entrada := v_emp.entra + (v_desfases[v_fila][v_i + 1] || ' minutes')::interval;
            -- Y una salida un poco después de la hora de fin
            v_salida  := v_emp.sale + interval '3 minutes';

            INSERT INTO rh.marcaciones (empleado_id, tipo, fecha_hora, fecha, origen, dispositivo, observacion, created_by, updated_by)
            VALUES (v_emp.id, 'ENTRADA', v_dia + v_entrada, v_dia,
                    CASE WHEN v_i = 1 THEN 'MOVIL' WHEN v_i = 3 THEN 'WEB' ELSE 'FACIAL' END,
                    CASE WHEN v_i = 1 THEN 'Android · Chrome' WHEN v_i = 3 THEN 'Escritorio' ELSE 'Kiosco recepción' END,
                    'Datos de prueba', 'datos-prueba', 'datos-prueba');

            -- El turno de noche sale al día siguiente; el resto, el mismo día
            INSERT INTO rh.marcaciones (empleado_id, tipo, fecha_hora, fecha, origen, dispositivo, observacion, created_by, updated_by)
            VALUES (v_emp.id, 'SALIDA',
                    CASE WHEN v_emp.sale <= v_emp.entra THEN v_dia + 1 + v_salida ELSE v_dia + v_salida END,
                    CASE WHEN v_emp.sale <= v_emp.entra THEN v_dia + 1 ELSE v_dia END,
                    'FACIAL', 'Kiosco recepción', 'Datos de prueba', 'datos-prueba', 'datos-prueba');

            v_cuantas := v_cuantas + 2;
        END LOOP;
    END LOOP;

    -- Y una el domingo pasado: ese día ninguno de los de jornada de semana
    -- tiene nada, así que sale «No trabaja» en lugar de un atraso.
    INSERT INTO rh.marcaciones (empleado_id, tipo, fecha_hora, fecha, origen, dispositivo, observacion, created_by, updated_by)
    SELECT e.id, 'ENTRADA',
           (CURRENT_DATE - EXTRACT(ISODOW FROM CURRENT_DATE)::integer) + time '09:30',
           (CURRENT_DATE - EXTRACT(ISODOW FROM CURRENT_DATE)::integer),
           'MOVIL', 'Android · Chrome', 'Vino un domingo', 'datos-prueba', 'datos-prueba'
      FROM rh.empleados e
     WHERE e.numero_identificacion = '9999000001';

    RAISE NOTICE 'Sembradas % marcaciones de prueba', v_cuantas + 1;
END $$;

-- ---------------------------------------------------------------------------
-- 3. CÓMO QUEDARON
-- ---------------------------------------------------------------------------
SELECT to_char(m.fecha_hora, 'YYYY-MM-DD HH24:MI') || '  '
    || rpad(TRIM(e.nombres), 6) || ' '
    || rpad(m.tipo, 8) || ' '
    || rpad(COALESCE(rh.fn_marcaciones_json(m.id)->>'atraso_estado', '—'), 14)
    || COALESCE('esperada ' || (rh.fn_marcaciones_json(m.id)->>'hora_esperada'), '')
    || COALESCE('  atraso ' || (rh.fn_marcaciones_json(m.id)->>'atraso_min') || ' min', '')
  FROM rh.marcaciones m
  JOIN rh.empleados e ON e.id = m.empleado_id
 WHERE m.created_by = 'datos-prueba'
 ORDER BY m.fecha_hora;

COMMIT;

-- ===========================================================================
-- PARA QUITARLOS
-- ===========================================================================
--   DELETE FROM rh.marcaciones WHERE created_by = 'datos-prueba';
--   DELETE FROM rh.empleados   WHERE numero_identificacion LIKE '9999%';
--
-- En ese orden: las marcaciones cuelgan del empleado.
-- ===========================================================================
