-- ===========================================================================
-- HORARIOS DE ACCESO: HASTA CUATRO JORNADAS POR DÍA
-- ===========================================================================
-- El horario de acceso al CRM pasa a admitir varias franjas por día, igual que
-- el de trabajo (rh.horarios_empleados). Son dos cosas distintas y así siguen:
--
--   · seguridad.chorarios      A QUÉ HORAS SE PUEDE ENTRAR AL SISTEMA. Lo
--                              aplica el middleware VerificarUsuarioActivo en
--                              cada petición.
--   · rh.horarios_empleados    A QUÉ HORA SE ESPERA A LA PERSONA en su puesto.
--                              Con él se miden los atrasos de las marcaciones.
--
-- Lo que cambia aquí es sólo la forma: donde había una franja por día ahora
-- caben cuatro, y se puede abrir de 08:00 a 12:00 y de 14:00 a 18:00 sin dejar
-- la hora del almuerzo abierta.
--
-- CUIDADO: de esta tabla depende que la gente pueda entrar. Las filas de hoy
-- se quedan tal cual, como jornada 1 de su día; nadie pierde acceso por esta
-- migración.
\set ON_ERROR_STOP on

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. LA COLUMNA
-- ---------------------------------------------------------------------------
-- Lo que ya hay pasa a ser la jornada 1 de su día: es exactamente lo que era.
ALTER TABLE seguridad.dhorarios
    ADD COLUMN IF NOT EXISTS jornada integer NOT NULL DEFAULT 1;

COMMENT ON COLUMN seguridad.dhorarios.jornada IS '1 a 4 dentro del día, en orden de reloj';
COMMENT ON COLUMN seguridad.dhorarios.hora_fin IS 'Si es menor o igual que hora_inicio, la franja termina al día siguiente';

ALTER TABLE seguridad.dhorarios DROP CONSTRAINT IF EXISTS ck_dhorarios_jornada;
ALTER TABLE seguridad.dhorarios
    ADD CONSTRAINT ck_dhorarios_jornada CHECK (jornada BETWEEN 1 AND 4);

-- Una jornada de cero minutos no es una jornada; al revés sí vale, que es la
-- que cruza la medianoche.
ALTER TABLE seguridad.dhorarios DROP CONSTRAINT IF EXISTS ck_dhorarios_horas;
ALTER TABLE seguridad.dhorarios
    ADD CONSTRAINT ck_dhorarios_horas CHECK (hora_fin IS NULL OR hora_inicio IS NULL OR hora_fin <> hora_inicio);

ALTER TABLE seguridad.dhorarios DROP CONSTRAINT IF EXISTS uk_dhorarios_dia_jornada;
ALTER TABLE seguridad.dhorarios
    ADD CONSTRAINT uk_dhorarios_dia_jornada UNIQUE (chorario_id, dia, jornada);

CREATE INDEX IF NOT EXISTS idx_dhorarios_dia_jornada
    ON seguridad.dhorarios (chorario_id, dia, jornada);

-- ---------------------------------------------------------------------------
-- 2. AYUDANTES (los mismos que en rh, para que las dos pantallas cuenten igual)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION seguridad.fn_horarios_dia_nombre(p_dia integer)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $function$
    SELECT CASE p_dia
        WHEN 1 THEN 'Lunes'   WHEN 2 THEN 'Martes' WHEN 3 THEN 'Miércoles'
        WHEN 4 THEN 'Jueves'  WHEN 5 THEN 'Viernes' WHEN 6 THEN 'Sábado'
        WHEN 7 THEN 'Domingo' ELSE '?' END;
$function$;

-- Cuántos minutos dura una franja, contando que pueda cruzar la medianoche.
CREATE OR REPLACE FUNCTION seguridad.fn_horarios_minutos(p_inicio interval, p_fin interval)
RETURNS integer
LANGUAGE sql
IMMUTABLE
AS $function$
    SELECT CASE
        WHEN p_inicio IS NULL OR p_fin IS NULL THEN 0
        WHEN p_fin > p_inicio THEN EXTRACT(EPOCH FROM (p_fin - p_inicio))::integer / 60
        -- Cruza medianoche: lo que queda de hoy más lo de mañana
        ELSE 1440 - (EXTRACT(EPOCH FROM (p_inicio - p_fin))::integer / 60)
    END;
$function$;

-- ---------------------------------------------------------------------------
-- 3. LA FICHA, CON SUS JORNADAS
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION seguridad.fn_horarios_json(p_id bigint)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'seguridad'
AS $function$
    SELECT jsonb_build_object(
        'id',           c.id,
        'nombre',       c.nombre,
        'activo',       c.activo,
        -- Quién depende de él: es lo que decide si se puede eliminar
        'num_usuarios', (SELECT COUNT(*) FROM seguridad.users u
                          WHERE u.chorario_id = c.id AND u.deleted_at IS NULL),
        'num_grupos',   (SELECT COUNT(*) FROM seguridad.grupos g WHERE g.chorario_id = c.id),
        -- Lo que se ve de un vistazo en la rejilla, sin abrir la ficha
        'num_dias',     (SELECT COUNT(DISTINCT d.dia) FROM seguridad.dhorarios d
                          WHERE d.chorario_id = c.id AND d.activo),
        'num_jornadas', (SELECT COUNT(*) FROM seguridad.dhorarios d
                          WHERE d.chorario_id = c.id AND d.activo),
        'horas_semana', COALESCE((SELECT ROUND(SUM(seguridad.fn_horarios_minutos(d.hora_inicio, d.hora_fin))::numeric / 60, 2)
                                    FROM seguridad.dhorarios d
                                   WHERE d.chorario_id = c.id AND d.activo), 0),
        'jornadas', COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
                       'id',          d.id,
                       'chorario_id', d.chorario_id,
                       'dia',         d.dia,
                       'dia_nombre',  seguridad.fn_horarios_dia_nombre(d.dia),
                       'jornada',     d.jornada,
                       'hora_inicio', to_char(DATE '2000-01-01' + d.hora_inicio, 'HH24:MI'),
                       'hora_fin',    to_char(DATE '2000-01-01' + d.hora_fin, 'HH24:MI'),
                       'minutos',     seguridad.fn_horarios_minutos(d.hora_inicio, d.hora_fin),
                       'cruza_medianoche', d.hora_fin <= d.hora_inicio,
                       'activo',      d.activo)
                   ORDER BY d.dia, d.jornada)
              FROM seguridad.dhorarios d
             WHERE d.chorario_id = c.id), '[]'::jsonb),
        -- La papelera: NULL mientras el horario está vigente
        'deleted_at',   to_char(c.deleted_at, 'YYYY-MM-DD HH24:MI:SS'),
        'deleted_by',   c.deleted_by,
        'created_by',   c.created_by,
        'updated_by',   c.updated_by,
        'created_at',   to_char(c.created_at, 'YYYY-MM-DD HH24:MI:SS'),
        'updated_at',   to_char(c.updated_at, 'YYYY-MM-DD HH24:MI:SS')
    )
      FROM seguridad.chorarios c
     WHERE c.id = p_id;
$function$;

-- ---------------------------------------------------------------------------
-- 4. GUARDAR LAS JORNADAS (lo común de crear y modificar)
-- ---------------------------------------------------------------------------
-- Reemplaza TODAS las franjas del horario por las que lleguen: lo que se ve en
-- la tabla del formulario es lo que queda guardado.
CREATE OR REPLACE FUNCTION seguridad.fn_horarios_guardar_jornadas(
    p_chorario_id bigint,
    p_jornadas    jsonb
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'seguridad'
AS $function$
DECLARE
    v_item    jsonb;
    v_dia     integer;
    v_jornada integer;
    v_ini     interval;
    v_fin     interval;
    v_cuantas integer := 0;
    v_choque  record;
BEGIN
    DELETE FROM seguridad.dhorarios WHERE chorario_id = p_chorario_id;

    IF p_jornadas IS NULL OR jsonb_typeof(p_jornadas) <> 'array' OR jsonb_array_length(p_jornadas) = 0 THEN
        RAISE EXCEPTION 'El horario necesita al menos una jornada' USING ERRCODE = 'P0001';
    END IF;

    FOR v_item IN SELECT * FROM jsonb_array_elements(p_jornadas) LOOP
        v_dia     := NULLIF(v_item->>'dia', '')::integer;
        v_jornada := COALESCE(NULLIF(v_item->>'jornada', '')::integer, 1);
        v_ini     := NULLIF(v_item->>'hora_inicio', '')::interval;
        v_fin     := NULLIF(v_item->>'hora_fin', '')::interval;

        IF v_dia IS NULL OR v_dia < 1 OR v_dia > 7 THEN
            RAISE EXCEPTION 'Hay una jornada sin día válido' USING ERRCODE = 'P0015';
        END IF;
        IF v_jornada < 1 OR v_jornada > 4 THEN
            RAISE EXCEPTION 'El % sólo admite hasta 4 jornadas', seguridad.fn_horarios_dia_nombre(v_dia)
                  USING ERRCODE = 'P0015';
        END IF;
        IF v_ini IS NULL OR v_fin IS NULL THEN
            RAISE EXCEPTION 'Falta la hora de inicio o de fin en la jornada % del %',
                  v_jornada, seguridad.fn_horarios_dia_nombre(v_dia) USING ERRCODE = 'P0001';
        END IF;
        IF v_ini = v_fin THEN
            RAISE EXCEPTION 'La jornada % del % empieza y termina a la misma hora',
                  v_jornada, seguridad.fn_horarios_dia_nombre(v_dia) USING ERRCODE = 'P0015';
        END IF;

        INSERT INTO seguridad.dhorarios (chorario_id, dia, jornada, hora_inicio, hora_fin, activo)
        VALUES (p_chorario_id, v_dia, v_jornada, v_ini, v_fin,
                COALESCE((v_item->>'activo')::boolean, true));

        v_cuantas := v_cuantas + 1;
    END LOOP;

    -- Las jornadas de un mismo día no se pueden pisar. Se comprueba al final y
    -- sobre lo ya guardado: hacerlo según van llegando dependería del orden en
    -- que las mande el formulario.
    SELECT a.dia, a.jornada AS ja, b.jornada AS jb INTO v_choque
      FROM seguridad.dhorarios a
      JOIN seguridad.dhorarios b
        ON b.chorario_id = a.chorario_id AND b.dia = a.dia AND b.jornada > a.jornada
     WHERE a.chorario_id = p_chorario_id
       AND a.activo AND b.activo
       AND tsrange(
               '2000-01-01'::timestamp + a.hora_inicio,
               '2000-01-01'::timestamp + a.hora_inicio
                 + (seguridad.fn_horarios_minutos(a.hora_inicio, a.hora_fin) || ' minutes')::interval)
           && tsrange(
               '2000-01-01'::timestamp + b.hora_inicio,
               '2000-01-01'::timestamp + b.hora_inicio
                 + (seguridad.fn_horarios_minutos(b.hora_inicio, b.hora_fin) || ' minutes')::interval)
     LIMIT 1;

    IF FOUND THEN
        RAISE EXCEPTION 'Las jornadas % y % del % se pisan',
              v_choque.ja, v_choque.jb, seguridad.fn_horarios_dia_nombre(v_choque.dia)
              USING ERRCODE = 'P0015';
    END IF;

    RETURN v_cuantas;
END;
$function$;

-- ---------------------------------------------------------------------------
-- 5. ¿PUEDE ENTRAR AHORA?
-- ---------------------------------------------------------------------------
-- La decisión del middleware, aquí dentro: se contesta con la jornada que
-- abre la puerta o con el motivo por el que no se abre.
--
-- ENTRA SI LA HORA CAE EN CUALQUIERA DE LAS JORNADAS DEL DÍA, y también si cae
-- en una de AYER que cruzaba la medianoche: quien tiene permitido de 22:00 a
-- 06:00 del lunes sigue dentro a la 01:00 del martes.
CREATE OR REPLACE FUNCTION seguridad.fn_horarios_puede_entrar(
    p_chorario_id bigint,
    p_momento     timestamptz DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'seguridad'
AS $function$
DECLARE
    v_horario seguridad.chorarios%ROWTYPE;
    v_cuando  timestamp;
    v_dia     integer;
    v_hora    interval;
    v_ayer    integer;
    v_abre    record;
    v_franjas text;
BEGIN
    IF p_chorario_id IS NULL THEN
        RETURN jsonb_build_object('permitido', false, 'motivo', 'SIN_HORARIO',
                                  'mensaje', 'Este usuario no tiene un horario asignado.');
    END IF;

    SELECT * INTO v_horario FROM seguridad.chorarios
     WHERE id = p_chorario_id AND deleted_at IS NULL;

    IF NOT FOUND OR NOT v_horario.activo THEN
        RETURN jsonb_build_object('permitido', false, 'motivo', 'HORARIO_INACTIVO',
                                  'mensaje', 'El horario asignado está inactivo.');
    END IF;

    v_cuando := COALESCE(p_momento, CURRENT_TIMESTAMP)::timestamp;
    v_dia    := EXTRACT(ISODOW FROM v_cuando)::integer;
    v_hora   := v_cuando - date_trunc('day', v_cuando);
    v_ayer   := CASE WHEN v_dia = 1 THEN 7 ELSE v_dia - 1 END;

    -- La jornada que deja entrar: la de hoy que contiene la hora, o la de
    -- ayer que cruzó la medianoche y todavía no ha terminado.
    SELECT d.dia, d.jornada, d.hora_inicio, d.hora_fin INTO v_abre
      FROM seguridad.dhorarios d
     WHERE d.chorario_id = p_chorario_id
       AND d.activo
       AND (
            -- De hoy, sin cruzar: [inicio, fin]
            (d.dia = v_dia AND d.hora_fin > d.hora_inicio
             AND v_hora >= d.hora_inicio AND v_hora <= d.hora_fin)
            -- De hoy, cruzando la medianoche: desde el inicio hasta las 24:00
         OR (d.dia = v_dia AND d.hora_fin <= d.hora_inicio AND v_hora >= d.hora_inicio)
            -- De ayer, cruzando: desde las 00:00 hasta su fin
         OR (d.dia = v_ayer AND d.hora_fin <= d.hora_inicio AND v_hora <= d.hora_fin)
       )
     ORDER BY d.dia = v_dia DESC, d.jornada
     LIMIT 1;

    IF FOUND THEN
        RETURN jsonb_build_object(
            'permitido', true, 'motivo', 'OK',
            'horario',   v_horario.nombre,
            'dia',       v_abre.dia,
            'jornada',   v_abre.jornada,
            'desde',     to_char(DATE '2000-01-01' + v_abre.hora_inicio, 'HH24:MI'),
            'hasta',     to_char(DATE '2000-01-01' + v_abre.hora_fin, 'HH24:MI'));
    END IF;

    -- No entra. Se dice qué franjas tenía hoy, que es lo que el usuario
    -- necesita saber: «hoy no te toca» o «vuelve a las 14:00».
    SELECT string_agg(to_char(DATE '2000-01-01' + d.hora_inicio, 'HH24:MI') || ' a ' ||
                      to_char(DATE '2000-01-01' + d.hora_fin, 'HH24:MI'), ', ' ORDER BY d.jornada)
      INTO v_franjas
      FROM seguridad.dhorarios d
     WHERE d.chorario_id = p_chorario_id AND d.dia = v_dia AND d.activo;

    IF v_franjas IS NULL THEN
        RETURN jsonb_build_object('permitido', false, 'motivo', 'DIA_SIN_ACCESO',
            'dia', v_dia,
            'mensaje', format('No tiene acceso permitido hoy (%s).', seguridad.fn_horarios_dia_nombre(v_dia)));
    END IF;

    RETURN jsonb_build_object('permitido', false, 'motivo', 'FUERA_DE_HORA',
        'dia', v_dia, 'franjas', v_franjas,
        'mensaje', format('Horario permitido hoy: %s.', v_franjas));
END;
$function$;

COMMIT;
