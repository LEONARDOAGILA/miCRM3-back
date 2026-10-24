-- ===========================================================================
-- LA DESCRIPCIÓN EN EL HORARIO DE ACCESO
-- ===========================================================================
-- Lo que ya tiene el horario de trabajo: un texto libre para decir para qué
-- sirve el horario y a quién se le pone. Con el nombre solo —«OFICINA 2»— no
-- hay forma de saberlo sin abrir la ficha y leer las franjas.
--
-- `p_descripcion` entra DETRÁS DE `p_nombre`, en el mismo sitio que en la
-- función de rh, para que las dos se llamen igual. Eso cambia la firma, así
-- que hay que tirar la de antes: añadir un parámetro no sustituye la función,
-- crea otra, y la llamada posicional del controlador seguiría entrando por la
-- vieja y tirando la descripción sin decir nada.
\set ON_ERROR_STOP on

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. LA COLUMNA
-- ---------------------------------------------------------------------------
ALTER TABLE seguridad.chorarios
    ADD COLUMN IF NOT EXISTS descripcion varchar(250);

COMMENT ON COLUMN seguridad.chorarios.descripcion IS 'Para qué sirve este horario y a quién se le pone';

-- ---------------------------------------------------------------------------
-- 2. LA FICHA LA DEVUELVE
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
        'descripcion',  c.descripcion,
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
-- 3. FUERA LAS VERSIONES SIN `p_descripcion`
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS seguridad.fn_horarios_crear(
    character varying, boolean, jsonb, bigint, character varying, character varying, inet, text, uuid);

DROP FUNCTION IF EXISTS seguridad.fn_horarios_modificar(
    bigint, character varying, boolean, jsonb, bigint, character varying, character varying, inet, text, uuid);

-- ---------------------------------------------------------------------------
-- 4. CREAR Y MODIFICAR, CON LA DESCRIPCIÓN
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION seguridad.fn_horarios_crear(
    p_nombre         character varying,
    p_descripcion    character varying DEFAULT NULL,
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

    IF p_dhorario IS NOT NULL THEN
        PERFORM set_config('app.dhorario_nuevos', p_dhorario::TEXT, true);
    END IF;

    IF p_nombre IS NULL OR TRIM(p_nombre) = '' THEN
        RETURN jsonb_build_object('success', false, 'message', 'El nombre del horario es obligatorio',
                                  'error_code', 'NOMBRE_REQUERIDO');
    END IF;

    IF EXISTS (SELECT 1 FROM seguridad.chorarios
                WHERE UPPER(TRIM(nombre)) = UPPER(TRIM(p_nombre)) AND deleted_at IS NULL) THEN
        RETURN jsonb_build_object('success', false, 'message', 'Ya existe un horario con ese nombre',
                                  'error_code', 'NOMBRE_DUPLICADO');
    END IF;

    INSERT INTO seguridad.chorarios (nombre, descripcion, activo)
    VALUES (TRIM(p_nombre),
            NULLIF(TRIM(COALESCE(p_descripcion, '')), ''),
            COALESCE(p_activo, true))
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
    p_descripcion    character varying DEFAULT NULL,
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
    v_actual seguridad.chorarios%ROWTYPE;
    v_viejos jsonb;
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
       SET nombre      = TRIM(p_nombre),
           descripcion = NULLIF(TRIM(COALESCE(p_descripcion, '')), ''),
           activo      = COALESCE(p_activo, activo)
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
