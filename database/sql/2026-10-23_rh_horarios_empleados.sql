-- ===========================================================================
-- HORARIOS DE EMPLEADOS (rh.horarios_empleados)
-- ===========================================================================
-- El horario de trabajo del personal, para medir los atrasos contra lo que
-- marcan (rh.marcaciones).
--
-- NO ES EL MISMO QUE seguridad.chorarios. Aquél dice a qué horas se puede
-- ENTRAR AL CRM —lo usa el middleware para cerrar la sesión fuera de hora— y
-- tiene una sola franja por día. Éste dice a qué hora se ESPERA AL EMPLEADO
-- en su puesto, admite HASTA CUATRO JORNADAS POR DÍA (partida de mañana y
-- tarde, turnos rotativos, guardias) y lleva la tolerancia con la que se
-- decide si una marcación llegó tarde.
--
-- Dos tablas, como chorarios/dhorarios:
--
--   rh.horarios_empleados           la cabecera: nombre, tolerancia, activo
--   rh.horarios_empleados_jornadas  el detalle: una fila por (día, jornada)
--
-- UNA JORNADA PUEDE CRUZAR LA MEDIANOCHE. Si `hora_fin` es menor o igual que
-- `hora_inicio` se entiende que termina al día siguiente (22:00 → 06:00): sin
-- eso no se puede guardar el turno de noche de un guardia.
\set ON_ERROR_STOP on

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. LA CABECERA
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS rh.horarios_empleados (
    id              bigserial     PRIMARY KEY,
    nombre          varchar(100)  NOT NULL,
    descripcion     varchar(250),
    -- Los minutos de gracia ANTES de contar atraso, los mismos para todas las
    -- jornadas: es como se dice la regla en la empresa («cinco minutos»), no
    -- uno distinto por franja.
    tolerancia_min  integer       NOT NULL DEFAULT 0,
    activo          boolean       NOT NULL DEFAULT true,

    created_at      timestamptz   DEFAULT now(),
    updated_at      timestamptz   DEFAULT now(),
    created_by      varchar(100),
    updated_by      varchar(100),
    -- Papelera de reciclaje, como en el resto de pantallas
    deleted_at      timestamptz,
    deleted_by      varchar(100),

    CONSTRAINT ck_horarios_empleados_nombre     CHECK (length(TRIM(nombre)) >= 3),
    CONSTRAINT ck_horarios_empleados_tolerancia CHECK (tolerancia_min BETWEEN 0 AND 240)
);

COMMENT ON TABLE  rh.horarios_empleados IS 'Horarios de trabajo del personal (hasta 4 jornadas por día); se usan para medir atrasos contra rh.marcaciones';
COMMENT ON COLUMN rh.horarios_empleados.tolerancia_min IS 'Minutos de gracia desde la hora de inicio antes de contar atraso';

-- Único sólo entre los vigentes: uno en la papelera no reserva su nombre
CREATE UNIQUE INDEX IF NOT EXISTS uk_horarios_empleados_nombre
    ON rh.horarios_empleados (UPPER(TRIM(nombre))) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_horarios_empleados_activo
    ON rh.horarios_empleados (activo);
CREATE INDEX IF NOT EXISTS ix_horarios_empleados_papelera
    ON rh.horarios_empleados (deleted_at) WHERE deleted_at IS NOT NULL;

-- ---------------------------------------------------------------------------
-- 2. EL DETALLE: HASTA CUATRO JORNADAS POR DÍA
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS rh.horarios_empleados_jornadas (
    id           bigserial   PRIMARY KEY,
    horario_id   bigint      NOT NULL,
    -- 1 = lunes … 7 = domingo (ISO, el mismo criterio que seguridad.dhorarios)
    dia          integer     NOT NULL,
    -- 1 a 4 dentro del día, en orden de reloj
    jornada      integer     NOT NULL,
    hora_inicio  time        NOT NULL,
    hora_fin     time        NOT NULL,
    activo       boolean     NOT NULL DEFAULT true,

    created_at   timestamptz DEFAULT now(),
    updated_at   timestamptz DEFAULT now(),
    created_by   varchar(100),
    updated_by   varchar(100),

    CONSTRAINT fk_hej_horario FOREIGN KEY (horario_id)
        REFERENCES rh.horarios_empleados(id) ON DELETE CASCADE,
    CONSTRAINT ck_hej_dia     CHECK (dia BETWEEN 1 AND 7),
    CONSTRAINT ck_hej_jornada CHECK (jornada BETWEEN 1 AND 4),
    -- Una jornada de cero minutos no es una jornada; al revés sí vale, que es
    -- la que cruza la medianoche.
    CONSTRAINT ck_hej_horas   CHECK (hora_fin <> hora_inicio),
    CONSTRAINT uk_hej_dia_jornada UNIQUE (horario_id, dia, jornada)
);

COMMENT ON TABLE  rh.horarios_empleados_jornadas IS 'Franjas de trabajo de un horario: hasta 4 por día';
COMMENT ON COLUMN rh.horarios_empleados_jornadas.hora_fin IS 'Si es menor que hora_inicio, la jornada termina al día siguiente';

CREATE INDEX IF NOT EXISTS ix_hej_horario ON rh.horarios_empleados_jornadas (horario_id);
CREATE INDEX IF NOT EXISTS ix_hej_dia     ON rh.horarios_empleados_jornadas (horario_id, dia, jornada);

-- ---------------------------------------------------------------------------
-- 3. AUDITORÍA (los tres disparadores de siempre)
-- ---------------------------------------------------------------------------
DROP TRIGGER IF EXISTS trigger_horarios_empleados_set_users  ON rh.horarios_empleados;
DROP TRIGGER IF EXISTS trigger_horarios_empleados_updated_at ON rh.horarios_empleados;
DROP TRIGGER IF EXISTS trg_horarios_empleados_audit          ON rh.horarios_empleados;

CREATE TRIGGER trigger_horarios_empleados_set_users
    BEFORE INSERT OR UPDATE ON rh.horarios_empleados
    FOR EACH ROW EXECUTE FUNCTION auditoria.fn_set_audit_users();
CREATE TRIGGER trigger_horarios_empleados_updated_at
    BEFORE UPDATE ON rh.horarios_empleados
    FOR EACH ROW EXECUTE FUNCTION auditoria.fn_update_updated_at_column();
CREATE TRIGGER trg_horarios_empleados_audit
    AFTER INSERT OR UPDATE OR DELETE ON rh.horarios_empleados
    FOR EACH ROW EXECUTE FUNCTION auditoria.fn_auditar_cambios();

DROP TRIGGER IF EXISTS trigger_hej_set_users  ON rh.horarios_empleados_jornadas;
DROP TRIGGER IF EXISTS trigger_hej_updated_at ON rh.horarios_empleados_jornadas;
DROP TRIGGER IF EXISTS trg_hej_audit          ON rh.horarios_empleados_jornadas;

CREATE TRIGGER trigger_hej_set_users
    BEFORE INSERT OR UPDATE ON rh.horarios_empleados_jornadas
    FOR EACH ROW EXECUTE FUNCTION auditoria.fn_set_audit_users();
CREATE TRIGGER trigger_hej_updated_at
    BEFORE UPDATE ON rh.horarios_empleados_jornadas
    FOR EACH ROW EXECUTE FUNCTION auditoria.fn_update_updated_at_column();
CREATE TRIGGER trg_hej_audit
    AFTER INSERT OR UPDATE OR DELETE ON rh.horarios_empleados_jornadas
    FOR EACH ROW EXECUTE FUNCTION auditoria.fn_auditar_cambios();

-- ---------------------------------------------------------------------------
-- 4. AYUDANTES
-- ---------------------------------------------------------------------------

-- El nombre del día, en un solo sitio.
CREATE OR REPLACE FUNCTION rh.fn_horarios_empleados_dia_nombre(p_dia integer)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $function$
    SELECT CASE p_dia
        WHEN 1 THEN 'Lunes'   WHEN 2 THEN 'Martes' WHEN 3 THEN 'Miércoles'
        WHEN 4 THEN 'Jueves'  WHEN 5 THEN 'Viernes' WHEN 6 THEN 'Sábado'
        WHEN 7 THEN 'Domingo' ELSE '?' END;
$function$;

-- Cuántos minutos dura una jornada, contando que pueda cruzar la medianoche.
CREATE OR REPLACE FUNCTION rh.fn_horarios_empleados_minutos(p_inicio time, p_fin time)
RETURNS integer
LANGUAGE sql
IMMUTABLE
AS $function$
    SELECT CASE WHEN p_fin > p_inicio
                THEN EXTRACT(EPOCH FROM (p_fin - p_inicio))::integer / 60
                -- Cruza medianoche: lo que queda de hoy más lo de mañana
                ELSE 1440 - (EXTRACT(EPOCH FROM (p_inicio - p_fin))::integer / 60)
           END;
$function$;

-- La ficha completa: la cabecera con sus jornadas, en el orden del reloj.
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
-- 5. GUARDAR LAS JORNADAS (lo común de crear y modificar)
-- ---------------------------------------------------------------------------
-- Reemplaza TODAS las jornadas del horario por las que lleguen. Es lo que
-- espera el formulario: lo que se ve en la tabla es lo que queda guardado,
-- sin tener que mandar aparte lo que se quitó.
CREATE OR REPLACE FUNCTION rh.fn_horarios_empleados_guardar_jornadas(
    p_horario_id bigint,
    p_jornadas   jsonb
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'rh'
AS $function$
DECLARE
    v_item    jsonb;
    v_dia     integer;
    v_jornada integer;
    v_ini     time;
    v_fin     time;
    v_cuantas integer := 0;
    v_choque  record;
BEGIN
    DELETE FROM rh.horarios_empleados_jornadas WHERE horario_id = p_horario_id;

    IF p_jornadas IS NULL OR jsonb_typeof(p_jornadas) <> 'array' OR jsonb_array_length(p_jornadas) = 0 THEN
        RAISE EXCEPTION 'El horario necesita al menos una jornada' USING ERRCODE = 'P0001';
    END IF;

    FOR v_item IN SELECT * FROM jsonb_array_elements(p_jornadas) LOOP
        v_dia     := NULLIF(v_item->>'dia', '')::integer;
        v_jornada := COALESCE(NULLIF(v_item->>'jornada', '')::integer, 1);
        v_ini     := NULLIF(v_item->>'hora_inicio', '')::time;
        v_fin     := NULLIF(v_item->>'hora_fin', '')::time;

        IF v_dia IS NULL OR v_dia < 1 OR v_dia > 7 THEN
            RAISE EXCEPTION 'Hay una jornada sin día válido' USING ERRCODE = 'P0015';
        END IF;
        IF v_jornada < 1 OR v_jornada > 4 THEN
            RAISE EXCEPTION 'El % sólo admite hasta 4 jornadas', rh.fn_horarios_empleados_dia_nombre(v_dia)
                  USING ERRCODE = 'P0015';
        END IF;
        IF v_ini IS NULL OR v_fin IS NULL THEN
            RAISE EXCEPTION 'Falta la hora de inicio o de fin en la jornada % del %',
                  v_jornada, rh.fn_horarios_empleados_dia_nombre(v_dia) USING ERRCODE = 'P0001';
        END IF;
        IF v_ini = v_fin THEN
            RAISE EXCEPTION 'La jornada % del % empieza y termina a la misma hora',
                  v_jornada, rh.fn_horarios_empleados_dia_nombre(v_dia) USING ERRCODE = 'P0015';
        END IF;

        INSERT INTO rh.horarios_empleados_jornadas (horario_id, dia, jornada, hora_inicio, hora_fin, activo)
        VALUES (p_horario_id, v_dia, v_jornada, v_ini, v_fin,
                COALESCE((v_item->>'activo')::boolean, true));

        v_cuantas := v_cuantas + 1;
    END LOOP;

    -- Las jornadas de un mismo día no se pueden pisar. Se comprueba al final
    -- y sobre lo ya guardado: hacerlo según van llegando dependería del orden
    -- en que las mande el formulario.
    SELECT a.dia, a.jornada AS ja, b.jornada AS jb INTO v_choque
      FROM rh.horarios_empleados_jornadas a
      JOIN rh.horarios_empleados_jornadas b
        ON b.horario_id = a.horario_id AND b.dia = a.dia AND b.jornada > a.jornada
     WHERE a.horario_id = p_horario_id
       AND a.activo AND b.activo
       -- Cada jornada como [inicio, inicio + duración) en minutos desde las 00:00
       AND tsrange(
               '2000-01-01'::timestamp + a.hora_inicio,
               '2000-01-01'::timestamp + a.hora_inicio
                 + (rh.fn_horarios_empleados_minutos(a.hora_inicio, a.hora_fin) || ' minutes')::interval)
           && tsrange(
               '2000-01-01'::timestamp + b.hora_inicio,
               '2000-01-01'::timestamp + b.hora_inicio
                 + (rh.fn_horarios_empleados_minutos(b.hora_inicio, b.hora_fin) || ' minutes')::interval)
     LIMIT 1;

    IF FOUND THEN
        RAISE EXCEPTION 'Las jornadas % y % del % se pisan',
              v_choque.ja, v_choque.jb, rh.fn_horarios_empleados_dia_nombre(v_choque.dia)
              USING ERRCODE = 'P0015';
    END IF;

    RETURN v_cuantas;
END;
$function$;

-- ---------------------------------------------------------------------------
-- 6. CREAR / MODIFICAR / ACTIVAR
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION rh.fn_horarios_empleados_crear(
    p_nombre         varchar,
    p_descripcion    varchar DEFAULT NULL,
    p_tolerancia_min integer DEFAULT 0,
    p_activo         boolean DEFAULT true,
    p_jornadas       jsonb   DEFAULT NULL,
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
    v_id bigint;
BEGIN
    PERFORM rh.fn_contexto_auditoria('rh.horarios_empleados', p_usuario_id, p_usuario_login,
                                     p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    IF p_nombre IS NULL OR length(TRIM(p_nombre)) < 3 THEN
        RAISE EXCEPTION 'El nombre del horario es obligatorio (mínimo 3 caracteres)' USING ERRCODE = 'P0001';
    END IF;
    IF COALESCE(p_tolerancia_min, 0) < 0 OR COALESCE(p_tolerancia_min, 0) > 240 THEN
        RAISE EXCEPTION 'La tolerancia debe estar entre 0 y 240 minutos' USING ERRCODE = 'P0015';
    END IF;
    -- `deleted_at IS NULL`: uno en la papelera no reserva su nombre
    IF EXISTS (SELECT 1 FROM rh.horarios_empleados
                WHERE UPPER(TRIM(nombre)) = UPPER(TRIM(p_nombre)) AND deleted_at IS NULL) THEN
        RAISE EXCEPTION 'Ya existe un horario con ese nombre' USING ERRCODE = 'P0006';
    END IF;

    INSERT INTO rh.horarios_empleados (nombre, descripcion, tolerancia_min, activo)
    VALUES (TRIM(p_nombre),
            NULLIF(TRIM(COALESCE(p_descripcion, '')), ''),
            COALESCE(p_tolerancia_min, 0),
            COALESCE(p_activo, true))
    RETURNING id INTO v_id;

    PERFORM rh.fn_horarios_empleados_guardar_jornadas(v_id, p_jornadas);

    RETURN jsonb_build_object('success', true,
        'message', 'Horario creado exitosamente',
        'data', rh.fn_horarios_empleados_json(v_id));
EXCEPTION
    -- Único caso capturado, y se RE-LANZA: manda el índice único. Nunca un «WHEN OTHERS».
    WHEN unique_violation THEN
        RAISE EXCEPTION 'Ya existe un horario con ese nombre' USING ERRCODE = 'P0006';
END;
$function$;

CREATE OR REPLACE FUNCTION rh.fn_horarios_empleados_modificar(
    p_id             bigint,
    p_nombre         varchar,
    p_descripcion    varchar DEFAULT NULL,
    p_tolerancia_min integer DEFAULT 0,
    p_activo         boolean DEFAULT true,
    p_jornadas       jsonb   DEFAULT NULL,
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
BEGIN
    PERFORM rh.fn_contexto_auditoria('rh.horarios_empleados', p_usuario_id, p_usuario_login,
                                     p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    SELECT * INTO v_actual FROM rh.horarios_empleados WHERE id = p_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'El horario no existe' USING ERRCODE = 'P0013';
    END IF;
    IF v_actual.deleted_at IS NOT NULL THEN
        RAISE EXCEPTION 'Ese horario está en la papelera de reciclaje: restáurelo antes de modificarlo'
              USING ERRCODE = 'P0019';
    END IF;

    IF p_nombre IS NULL OR length(TRIM(p_nombre)) < 3 THEN
        RAISE EXCEPTION 'El nombre del horario es obligatorio (mínimo 3 caracteres)' USING ERRCODE = 'P0001';
    END IF;
    IF COALESCE(p_tolerancia_min, 0) < 0 OR COALESCE(p_tolerancia_min, 0) > 240 THEN
        RAISE EXCEPTION 'La tolerancia debe estar entre 0 y 240 minutos' USING ERRCODE = 'P0015';
    END IF;
    IF EXISTS (SELECT 1 FROM rh.horarios_empleados
                WHERE UPPER(TRIM(nombre)) = UPPER(TRIM(p_nombre))
                  AND id <> p_id AND deleted_at IS NULL) THEN
        RAISE EXCEPTION 'Ya existe otro horario con ese nombre' USING ERRCODE = 'P0006';
    END IF;

    UPDATE rh.horarios_empleados
       SET nombre         = TRIM(p_nombre),
           descripcion    = NULLIF(TRIM(COALESCE(p_descripcion, '')), ''),
           tolerancia_min = COALESCE(p_tolerancia_min, 0),
           activo         = COALESCE(p_activo, true)
     WHERE id = p_id;

    PERFORM rh.fn_horarios_empleados_guardar_jornadas(p_id, p_jornadas);

    RETURN jsonb_build_object('success', true,
        'message', 'Horario actualizado exitosamente',
        'data', rh.fn_horarios_empleados_json(p_id));
EXCEPTION
    WHEN unique_violation THEN
        RAISE EXCEPTION 'Ya existe otro horario con ese nombre' USING ERRCODE = 'P0006';
END;
$function$;

-- Pone `activo` y nada más. Existe aparte de modificar porque aquélla
-- REESCRIBE LAS JORNADAS, y para bajar una casilla desde la rejilla eso es
-- mucho ruido y mucho riesgo.
CREATE OR REPLACE FUNCTION rh.fn_horarios_empleados_activar(
    p_id             bigint,
    p_activo         boolean DEFAULT NULL,
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
    v_antes      boolean;
    v_nuevo      boolean;
    v_updated_by varchar;
    v_updated_at text;
BEGIN
    PERFORM rh.fn_contexto_auditoria('rh.horarios_empleados', p_usuario_id, p_usuario_login,
                                     p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    -- `deleted_at IS NULL`: para la casilla, uno en la papelera no existe
    SELECT activo INTO v_antes FROM rh.horarios_empleados WHERE id = p_id AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'error_code', 'NO_EXISTE',
                                  'message', 'El horario no existe');
    END IF;

    v_nuevo := COALESCE(p_activo, NOT COALESCE(v_antes, true));

    IF v_nuevo IS NOT DISTINCT FROM v_antes THEN
        SELECT updated_by, to_char(updated_at, 'YYYY-MM-DD HH24:MI:SS')
          INTO v_updated_by, v_updated_at FROM rh.horarios_empleados WHERE id = p_id;
        RETURN jsonb_build_object('success', true,
            'message', CASE WHEN v_nuevo THEN 'El horario ya estaba activo' ELSE 'El horario ya estaba inactivo' END,
            'data', jsonb_build_object('id', p_id, 'activo', v_nuevo,
                                       'updated_by', v_updated_by, 'updated_at', v_updated_at));
    END IF;

    UPDATE rh.horarios_empleados SET activo = v_nuevo WHERE id = p_id
    RETURNING activo, updated_by, to_char(updated_at, 'YYYY-MM-DD HH24:MI:SS')
         INTO v_nuevo, v_updated_by, v_updated_at;

    RETURN jsonb_build_object('success', true,
        'message', CASE WHEN v_nuevo THEN 'Horario activado' ELSE 'Horario desactivado' END,
        'data', jsonb_build_object('id', p_id, 'activo', v_nuevo,
                                   'updated_by', v_updated_by, 'updated_at', v_updated_at));
END;
$function$;

-- ---------------------------------------------------------------------------
-- 7. LEER
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION rh.fn_horarios_empleados_obtener(p_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'rh'
AS $function$
DECLARE v_data jsonb;
BEGIN
    v_data := rh.fn_horarios_empleados_json(p_id);
    IF v_data IS NULL THEN
        RETURN jsonb_build_object('success', false, 'message', 'El horario no existe',
                                  'error_code', 'NO_EXISTE', 'data', NULL);
    END IF;
    RETURN jsonb_build_object('success', true, 'message', 'Horario obtenido exitosamente', 'data', v_data);
END;
$function$;

CREATE OR REPLACE FUNCTION rh.fn_horarios_empleados_listar_paginado(
    p_page     integer DEFAULT 1,
    p_per_page integer DEFAULT 15,
    p_search   text    DEFAULT ''::text,
    p_filtros  jsonb   DEFAULT '{}'::jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'rh', 'ventas'
AS $function$
DECLARE
    v_offset integer;
    v_total  bigint;
    v_data   jsonb;
    v_filtro text;
BEGIN
    v_offset := (GREATEST(p_page, 1) - 1) * GREATEST(p_per_page, 1);
    v_filtro := NULLIF(TRIM(COALESCE(p_search, '')), '');

    WITH filtrados AS (
        SELECT h.id
          FROM rh.horarios_empleados h
         WHERE h.deleted_at IS NULL          -- lo de la papelera no sale
           AND (v_filtro IS NULL
                OR h.nombre      ILIKE '%' || v_filtro || '%'
                OR h.descripcion ILIKE '%' || v_filtro || '%'
                OR h.id::text    ILIKE '%' || v_filtro || '%')

           -- ---------- LOS FILTROS DE LA CABECERA ----------
           AND (p_filtros->'id'             IS NULL OR ventas.fn_filtro_numero(h.id,             p_filtros->'id'))
           AND (p_filtros->'nombre'         IS NULL OR ventas.fn_filtro_texto(h.nombre,          p_filtros->'nombre'))
           AND (p_filtros->'descripcion'    IS NULL OR ventas.fn_filtro_texto(h.descripcion,     p_filtros->'descripcion'))
           AND (p_filtros->'tolerancia_min' IS NULL OR ventas.fn_filtro_numero(h.tolerancia_min, p_filtros->'tolerancia_min'))
           -- Los contadores: los mismos subselects que pintan las columnas
           AND (p_filtros->'num_dias'     IS NULL OR ventas.fn_filtro_numero(
                   (SELECT COUNT(DISTINCT j.dia) FROM rh.horarios_empleados_jornadas j
                     WHERE j.horario_id = h.id AND j.activo), p_filtros->'num_dias'))
           AND (p_filtros->'num_jornadas' IS NULL OR ventas.fn_filtro_numero(
                   (SELECT COUNT(*) FROM rh.horarios_empleados_jornadas j
                     WHERE j.horario_id = h.id AND j.activo), p_filtros->'num_jornadas'))
           AND (p_filtros->'created_by'   IS NULL OR ventas.fn_filtro_texto(h.created_by, p_filtros->'created_by'))
           AND (p_filtros->'updated_by'   IS NULL OR ventas.fn_filtro_texto(h.updated_by, p_filtros->'updated_by'))
           -- Las fechas, como texto sobre lo que se ve: «2026-10» busca el mes
           AND (p_filtros->'created_at'   IS NULL OR ventas.fn_filtro_texto(
                   to_char(h.created_at, 'YYYY-MM-DD HH24:MI:SS'), p_filtros->'created_at'))
           AND (p_filtros->'updated_at'   IS NULL OR ventas.fn_filtro_texto(
                   to_char(h.updated_at, 'YYYY-MM-DD HH24:MI:SS'), p_filtros->'updated_at'))
    )
    SELECT COUNT(*),
           COALESCE((SELECT jsonb_agg(rh.fn_horarios_empleados_json(t.id) ORDER BY t.id DESC)
                       FROM (SELECT f.id FROM filtrados f
                              ORDER BY f.id DESC
                              LIMIT GREATEST(p_per_page, 1) OFFSET v_offset) t), '[]'::jsonb)
      INTO v_total, v_data
      FROM filtrados;

    RETURN jsonb_build_object(
        'data', v_data,
        'meta', jsonb_build_object(
            'total',        v_total,
            'per_page',     GREATEST(p_per_page, 1),
            'current_page', GREATEST(p_page, 1),
            'last_page',    CASE WHEN v_total = 0 THEN 1
                                 ELSE ceil(v_total::numeric / GREATEST(p_per_page, 1)) END
        )
    );

EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object('success', false, 'message', 'Error al listar horarios: ' || SQLERRM, 'error_code', SQLSTATE);
END;
$function$;

-- La misma lista, pero sólo los que se pueden elegir: el selector de la ficha
-- del empleado no debe ofrecer un horario apagado.
CREATE OR REPLACE FUNCTION rh.fn_horarios_empleados_listar_paginado_activos(
    p_page     integer DEFAULT 1,
    p_per_page integer DEFAULT 15,
    p_search   text    DEFAULT ''::text
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'rh'
AS $function$
DECLARE
    v_offset integer;
    v_total  bigint;
    v_data   jsonb;
    v_filtro text;
BEGIN
    v_offset := (GREATEST(p_page, 1) - 1) * GREATEST(p_per_page, 1);
    v_filtro := NULLIF(TRIM(COALESCE(p_search, '')), '');

    WITH filtrados AS (
        SELECT h.id
          FROM rh.horarios_empleados h
         WHERE h.deleted_at IS NULL
           AND h.activo
           AND (v_filtro IS NULL
                OR h.nombre      ILIKE '%' || v_filtro || '%'
                OR h.descripcion ILIKE '%' || v_filtro || '%'
                OR h.id::text    ILIKE '%' || v_filtro || '%')
    )
    SELECT COUNT(*),
           COALESCE((SELECT jsonb_agg(rh.fn_horarios_empleados_json(t.id) ORDER BY t.id)
                       FROM (SELECT f.id FROM filtrados f
                              ORDER BY f.id
                              LIMIT GREATEST(p_per_page, 1) OFFSET v_offset) t), '[]'::jsonb)
      INTO v_total, v_data
      FROM filtrados;

    RETURN jsonb_build_object(
        'data', v_data,
        'meta', jsonb_build_object(
            'total',        v_total,
            'per_page',     GREATEST(p_per_page, 1),
            'current_page', GREATEST(p_page, 1),
            'last_page',    CASE WHEN v_total = 0 THEN 1
                                 ELSE ceil(v_total::numeric / GREATEST(p_per_page, 1)) END
        )
    );
END;
$function$;

COMMIT;
