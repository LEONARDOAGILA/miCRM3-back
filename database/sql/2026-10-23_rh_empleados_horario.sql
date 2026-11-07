-- ===========================================================================
-- EL HORARIO DE TRABAJO EN LA FICHA DEL EMPLEADO
-- ===========================================================================
-- `rh.empleados.horario_id` apunta al horario con el que se le miden los
-- atrasos. Es el mismo trato que `sucursal_id`:
--
--   · sucursal_id  dice DESDE DÓNDE puede marcar (el perímetro)
--   · horario_id   dice A QUÉ HORA se le espera (las jornadas y su tolerancia)
--
-- Las dos son opcionales y las dos se comportan igual cuando faltan: sin
-- sucursal marca desde cualquier lugar, y sin horario marca sin que nadie le
-- mida el atraso.
--
-- Las funciones de empleados se regeneran A PARTIR DE LA DEFINICIÓN VIVA con
-- el parámetro nuevo metido detrás de `p_sucursal_id`: así no se pierde
-- ninguna regla al reescribirlas.
\set ON_ERROR_STOP on

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. LA COLUMNA
-- ---------------------------------------------------------------------------
ALTER TABLE rh.empleados
    ADD COLUMN IF NOT EXISTS horario_id bigint;

COMMENT ON COLUMN rh.empleados.horario_id IS 'Horario de trabajo con el que se le miden los atrasos (rh.horarios_empleados); NULL = sin control de atrasos';

-- La clave foránea SIN cascada: un horario en uso no se borra de verdad, y si
-- alguien lo intenta es mejor que la base lo pare a que deje empleados
-- apuntando al vacío. En la papelera sigue estando, así que no estorba.
ALTER TABLE rh.empleados DROP CONSTRAINT IF EXISTS fk_empleados_horario;
ALTER TABLE rh.empleados
    ADD CONSTRAINT fk_empleados_horario FOREIGN KEY (horario_id)
        REFERENCES rh.horarios_empleados(id);

CREATE INDEX IF NOT EXISTS ix_empleados_horario ON rh.empleados (horario_id);

-- ---------------------------------------------------------------------------
-- 2. FUERA LAS VERSIONES SIN `p_horario_id`
-- ---------------------------------------------------------------------------
-- Añadir un parámetro con DEFAULT no sustituye la función: crea otra. Las dos
-- quedarían vivas, y una llamada con los argumentos de antes —que es la que
-- hace el controlador hasta que se toque— seguiría entrando por la vieja y
-- tirando el horario sin decir nada. Se tiran a mano.
DROP FUNCTION IF EXISTS rh.fn_empleados_crear(
    character varying, character varying, character varying, character varying, character varying,
    character varying, character varying, character varying, date, character, text,
    bigint, bigint, bigint, date, date, character varying, character varying, numeric, boolean,
    bigint, bigint, character varying, character varying, inet, text, uuid);

DROP FUNCTION IF EXISTS rh.fn_empleados_modificar(
    bigint, character varying, character varying, character varying, character varying, character varying,
    character varying, character varying, character varying, date, character, text,
    bigint, bigint, bigint, date, date, character varying, character varying, numeric, boolean,
    bigint, bigint, character varying, character varying, inet, text, uuid);

-- ---------------------------------------------------------------------------
-- 3..6. LAS FUNCIONES, REGENERADAS DESDE LA DEFINICIÓN VIVA
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION rh.fn_empleados_crear(p_numero_identificacion character varying, p_tipo_identificacion character varying, p_nombres character varying, p_apellidos character varying, p_email character varying, p_email_personal character varying DEFAULT NULL::character varying, p_telefono character varying DEFAULT NULL::character varying, p_celular character varying DEFAULT NULL::character varying, p_fecha_nacimiento date DEFAULT NULL::date, p_genero character DEFAULT NULL::bpchar, p_direccion text DEFAULT NULL::text, p_cargo_id bigint DEFAULT NULL::bigint, p_departamento_id bigint DEFAULT NULL::bigint, p_jefe_id bigint DEFAULT NULL::bigint, p_fecha_ingreso date DEFAULT NULL::date, p_fecha_salida date DEFAULT NULL::date, p_estado character varying DEFAULT 'ACTIVO'::character varying, p_tipo_contrato character varying DEFAULT 'INDEFINIDO'::character varying, p_salario numeric DEFAULT NULL::numeric, p_activo boolean DEFAULT true, p_sucursal_id bigint DEFAULT NULL::bigint, p_horario_id bigint DEFAULT NULL::bigint, p_usuario_id bigint DEFAULT NULL::bigint, p_usuario_login character varying DEFAULT NULL::character varying, p_usuario_nombre character varying DEFAULT NULL::character varying, p_ip_address inet DEFAULT NULL::inet, p_user_agent text DEFAULT NULL::text, p_request_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'rh', 'auditoria'
AS $function$
DECLARE
    v_id           bigint;
    v_fecha        timestamptz := CURRENT_TIMESTAMP;
    v_datos_nuevos jsonb;
BEGIN
    PERFORM set_config('app.usuario_id',     COALESCE(p_usuario_id::text, ''), true);
    PERFORM set_config('app.usuario_login',  COALESCE(p_usuario_login, current_user), true);
    PERFORM set_config('app.usuario_nombre', COALESCE(p_usuario_nombre, current_user), true);
    PERFORM set_config('app.ip_address',     COALESCE(p_ip_address::text, ''), true);
    PERFORM set_config('app.user_agent',     COALESCE(p_user_agent, ''), true);
    PERFORM set_config('app.request_id',     COALESCE(p_request_id::text, ''), true);
    PERFORM set_config('app.modulo',         'rh.empleados', true);

    PERFORM rh.fn_empleados_validar(NULL, p_numero_identificacion, p_tipo_identificacion, p_nombres, p_apellidos, p_email,
                                    p_genero, p_cargo_id, p_departamento_id, p_jefe_id, p_fecha_ingreso, p_fecha_salida,
                                    p_tipo_contrato, p_salario);

    -- LA SUCURSAL: tiene que existir, no estar en la papelera y estar activa.
    -- Es la misma regla que exige rh.fn_empleados_asignar_sucursal, que sigue
    -- estando para cambiarla sola sin abrir la ficha.
    IF p_sucursal_id IS NOT NULL THEN
        IF NOT EXISTS (SELECT 1 FROM ventas.sucursales
                        WHERE id = p_sucursal_id AND deleted_at IS NULL) THEN
            RAISE EXCEPTION 'La sucursal indicada no existe o está en la papelera' USING ERRCODE = 'P0016';
        END IF;
        IF NOT (SELECT activo FROM ventas.sucursales WHERE id = p_sucursal_id) THEN
            RAISE EXCEPTION 'La sucursal indicada está inactiva' USING ERRCODE = 'P0017';
        END IF;
    END IF;

    -- EL HORARIO: tiene que existir, no estar en la papelera y estar activo.
    -- Es la misma regla que la sucursal; sin horario, el empleado marca sin
    -- que nadie le mida el atraso.
    IF p_horario_id IS NOT NULL THEN
        IF NOT EXISTS (SELECT 1 FROM rh.horarios_empleados
                        WHERE id = p_horario_id AND deleted_at IS NULL) THEN
            RAISE EXCEPTION 'El horario indicado no existe o está en la papelera' USING ERRCODE = 'P0016';
        END IF;
        IF NOT (SELECT activo FROM rh.horarios_empleados WHERE id = p_horario_id) THEN
            RAISE EXCEPTION 'El horario indicado está inactivo' USING ERRCODE = 'P0017';
        END IF;
    END IF;

    v_datos_nuevos := jsonb_build_object(
        'numero_identificacion', TRIM(p_numero_identificacion), 'tipo_identificacion', COALESCE(p_tipo_identificacion, 'CC'),
        'nombres', TRIM(p_nombres), 'apellidos', TRIM(p_apellidos), 'email', LOWER(TRIM(p_email)),
        'email_personal', NULLIF(LOWER(TRIM(COALESCE(p_email_personal, ''))), ''),
        'telefono', NULLIF(TRIM(COALESCE(p_telefono, '')), ''), 'celular', NULLIF(TRIM(COALESCE(p_celular, '')), ''),
        'fecha_nacimiento', to_char(p_fecha_nacimiento, 'YYYY-MM-DD'), 'genero', p_genero,
        'direccion', NULLIF(TRIM(COALESCE(p_direccion, '')), ''),
        'cargo', jsonb_build_object('id', p_cargo_id, 'nombre', (SELECT nombre FROM rh.cargos WHERE id = p_cargo_id)),
        'departamento', jsonb_build_object('id', p_departamento_id, 'nombre', (SELECT nombre FROM rh.departamentos WHERE id = p_departamento_id)),
        'jefe_id', p_jefe_id,
        'fecha_ingreso', to_char(p_fecha_ingreso, 'YYYY-MM-DD'), 'fecha_salida', to_char(p_fecha_salida, 'YYYY-MM-DD'),
        'estado', COALESCE(p_estado, 'ACTIVO'), 'tipo_contrato', COALESCE(p_tipo_contrato, 'INDEFINIDO'),
        'salario', p_salario, 'activo', COALESCE(p_activo, true), 'sucursal_id', p_sucursal_id, 'horario_id', p_horario_id,
        'created_by', p_usuario_login, 'created_at', to_char(v_fecha, 'YYYY-MM-DD HH24:MI:SS'),
        'updated_by', p_usuario_login, 'updated_at', to_char(v_fecha, 'YYYY-MM-DD HH24:MI:SS')
    );
    PERFORM set_config('app.datos_nuevos', v_datos_nuevos::text, true);

    INSERT INTO rh.empleados (
        numero_identificacion, tipo_identificacion, nombres, apellidos, email, email_personal, telefono, celular,
        fecha_nacimiento, genero, direccion, cargo_id, departamento_id, jefe_id, fecha_ingreso, fecha_salida,
        estado, tipo_contrato, salario, activo, sucursal_id, horario_id, created_by, updated_by, created_at, updated_at
    ) VALUES (
        TRIM(p_numero_identificacion), COALESCE(p_tipo_identificacion, 'CC'), TRIM(p_nombres), TRIM(p_apellidos),
        LOWER(TRIM(p_email)), NULLIF(LOWER(TRIM(COALESCE(p_email_personal, ''))), ''),
        NULLIF(TRIM(COALESCE(p_telefono, '')), ''), NULLIF(TRIM(COALESCE(p_celular, '')), ''),
        p_fecha_nacimiento, p_genero, NULLIF(TRIM(COALESCE(p_direccion, '')), ''),
        p_cargo_id, p_departamento_id, p_jefe_id, p_fecha_ingreso, p_fecha_salida,
        COALESCE(p_estado, 'ACTIVO'), COALESCE(p_tipo_contrato, 'INDEFINIDO'), p_salario, COALESCE(p_activo, true),
        p_sucursal_id, p_horario_id,
        p_usuario_login, p_usuario_login, v_fecha, v_fecha
    )
    RETURNING id INTO v_id;

    PERFORM set_config('app.datos_nuevos', '', true);

    RETURN jsonb_build_object('success', true, 'message', 'Empleado creado exitosamente',
                              'data', (rh.fn_empleados_obtener(v_id))->'data');
EXCEPTION
    WHEN unique_violation THEN
        RAISE EXCEPTION 'Ya existe un empleado con esa identificación o correo' USING ERRCODE = 'P0006';
END;
$function$;

CREATE OR REPLACE FUNCTION rh.fn_empleados_modificar(p_id bigint, p_numero_identificacion character varying, p_tipo_identificacion character varying, p_nombres character varying, p_apellidos character varying, p_email character varying, p_email_personal character varying DEFAULT NULL::character varying, p_telefono character varying DEFAULT NULL::character varying, p_celular character varying DEFAULT NULL::character varying, p_fecha_nacimiento date DEFAULT NULL::date, p_genero character DEFAULT NULL::bpchar, p_direccion text DEFAULT NULL::text, p_cargo_id bigint DEFAULT NULL::bigint, p_departamento_id bigint DEFAULT NULL::bigint, p_jefe_id bigint DEFAULT NULL::bigint, p_fecha_ingreso date DEFAULT NULL::date, p_fecha_salida date DEFAULT NULL::date, p_estado character varying DEFAULT 'ACTIVO'::character varying, p_tipo_contrato character varying DEFAULT 'INDEFINIDO'::character varying, p_salario numeric DEFAULT NULL::numeric, p_activo boolean DEFAULT true, p_sucursal_id bigint DEFAULT NULL::bigint, p_horario_id bigint DEFAULT NULL::bigint, p_usuario_id bigint DEFAULT NULL::bigint, p_usuario_login character varying DEFAULT NULL::character varying, p_usuario_nombre character varying DEFAULT NULL::character varying, p_ip_address inet DEFAULT NULL::inet, p_user_agent text DEFAULT NULL::text, p_request_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'rh', 'auditoria'
AS $function$
DECLARE
    v_actual           rh.empleados%ROWTYPE;
    v_fecha            timestamptz := CURRENT_TIMESTAMP;
    v_datos_anteriores jsonb;
    v_datos_nuevos     jsonb;
BEGIN
    PERFORM set_config('app.usuario_id',     COALESCE(p_usuario_id::text, ''), true);
    PERFORM set_config('app.usuario_login',  COALESCE(p_usuario_login, current_user), true);
    PERFORM set_config('app.usuario_nombre', COALESCE(p_usuario_nombre, current_user), true);
    PERFORM set_config('app.ip_address',     COALESCE(p_ip_address::text, ''), true);
    PERFORM set_config('app.user_agent',     COALESCE(p_user_agent, ''), true);
    PERFORM set_config('app.request_id',     COALESCE(p_request_id::text, ''), true);
    PERFORM set_config('app.modulo',         'rh.empleados', true);

    SELECT * INTO v_actual FROM rh.empleados WHERE id = p_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'El empleado no existe' USING ERRCODE = 'P0013';
    END IF;

    PERFORM rh.fn_empleados_validar(p_id, p_numero_identificacion, p_tipo_identificacion, p_nombres, p_apellidos, p_email,
                                    p_genero, p_cargo_id, p_departamento_id, p_jefe_id, p_fecha_ingreso, p_fecha_salida,
                                    p_tipo_contrato, p_salario);

    -- LA SUCURSAL: tiene que existir, no estar en la papelera y estar activa.
    -- Es la misma regla que exige rh.fn_empleados_asignar_sucursal, que sigue
    -- estando para cambiarla sola sin abrir la ficha.
    IF p_sucursal_id IS NOT NULL THEN
        IF NOT EXISTS (SELECT 1 FROM ventas.sucursales
                        WHERE id = p_sucursal_id AND deleted_at IS NULL) THEN
            RAISE EXCEPTION 'La sucursal indicada no existe o está en la papelera' USING ERRCODE = 'P0016';
        END IF;
        IF NOT (SELECT activo FROM ventas.sucursales WHERE id = p_sucursal_id) THEN
            RAISE EXCEPTION 'La sucursal indicada está inactiva' USING ERRCODE = 'P0017';
        END IF;
    END IF;

    -- EL HORARIO: tiene que existir, no estar en la papelera y estar activo.
    -- Es la misma regla que la sucursal; sin horario, el empleado marca sin
    -- que nadie le mida el atraso.
    IF p_horario_id IS NOT NULL THEN
        IF NOT EXISTS (SELECT 1 FROM rh.horarios_empleados
                        WHERE id = p_horario_id AND deleted_at IS NULL) THEN
            RAISE EXCEPTION 'El horario indicado no existe o está en la papelera' USING ERRCODE = 'P0016';
        END IF;
        IF NOT (SELECT activo FROM rh.horarios_empleados WHERE id = p_horario_id) THEN
            RAISE EXCEPTION 'El horario indicado está inactivo' USING ERRCODE = 'P0017';
        END IF;
    END IF;

    v_datos_anteriores := (rh.fn_empleados_obtener(p_id))->'data';
    v_datos_nuevos := jsonb_build_object(
        'id', p_id,
        'numero_identificacion', TRIM(p_numero_identificacion), 'tipo_identificacion', COALESCE(p_tipo_identificacion, 'CC'),
        'nombres', TRIM(p_nombres), 'apellidos', TRIM(p_apellidos), 'email', LOWER(TRIM(p_email)),
        'email_personal', NULLIF(LOWER(TRIM(COALESCE(p_email_personal, ''))), ''),
        'telefono', NULLIF(TRIM(COALESCE(p_telefono, '')), ''), 'celular', NULLIF(TRIM(COALESCE(p_celular, '')), ''),
        'fecha_nacimiento', to_char(p_fecha_nacimiento, 'YYYY-MM-DD'), 'genero', p_genero,
        'direccion', NULLIF(TRIM(COALESCE(p_direccion, '')), ''),
        'cargo', jsonb_build_object('id', p_cargo_id, 'nombre', (SELECT nombre FROM rh.cargos WHERE id = p_cargo_id)),
        'departamento', jsonb_build_object('id', p_departamento_id, 'nombre', (SELECT nombre FROM rh.departamentos WHERE id = p_departamento_id)),
        'jefe_id', p_jefe_id,
        'fecha_ingreso', to_char(p_fecha_ingreso, 'YYYY-MM-DD'), 'fecha_salida', to_char(p_fecha_salida, 'YYYY-MM-DD'),
        'estado', COALESCE(p_estado, 'ACTIVO'), 'tipo_contrato', COALESCE(p_tipo_contrato, 'INDEFINIDO'),
        'salario', p_salario, 'foto', v_actual.foto, 'activo', COALESCE(p_activo, true),
        'sucursal_id', p_sucursal_id, 'horario_id', p_horario_id,
        'created_by', v_actual.created_by, 'created_at', to_char(v_actual.created_at, 'YYYY-MM-DD HH24:MI:SS'),
        'updated_by', p_usuario_login, 'updated_at', to_char(v_fecha, 'YYYY-MM-DD HH24:MI:SS')
    );
    PERFORM set_config('app.datos_anteriores', v_datos_anteriores::text, true);
    PERFORM set_config('app.datos_nuevos',     v_datos_nuevos::text, true);

    UPDATE rh.empleados
       SET numero_identificacion = TRIM(p_numero_identificacion),
           tipo_identificacion   = COALESCE(p_tipo_identificacion, 'CC'),
           nombres               = TRIM(p_nombres),
           apellidos             = TRIM(p_apellidos),
           email                 = LOWER(TRIM(p_email)),
           email_personal        = NULLIF(LOWER(TRIM(COALESCE(p_email_personal, ''))), ''),
           telefono              = NULLIF(TRIM(COALESCE(p_telefono, '')), ''),
           celular               = NULLIF(TRIM(COALESCE(p_celular, '')), ''),
           fecha_nacimiento      = p_fecha_nacimiento,
           genero                = p_genero,
           direccion             = NULLIF(TRIM(COALESCE(p_direccion, '')), ''),
           cargo_id              = p_cargo_id,
           departamento_id       = p_departamento_id,
           jefe_id               = p_jefe_id,
           fecha_ingreso         = p_fecha_ingreso,
           fecha_salida          = p_fecha_salida,
           estado                = COALESCE(p_estado, 'ACTIVO'),
           tipo_contrato         = COALESCE(p_tipo_contrato, 'INDEFINIDO'),
           salario               = p_salario,
           activo                = COALESCE(p_activo, true),
           sucursal_id           = p_sucursal_id,
           horario_id            = p_horario_id,
           updated_by            = p_usuario_login,
           updated_at            = v_fecha
     WHERE id = p_id;

    PERFORM set_config('app.datos_anteriores', '', true);
    PERFORM set_config('app.datos_nuevos', '', true);

    RETURN jsonb_build_object('success', true, 'message', 'Empleado actualizado exitosamente',
                              'data', (rh.fn_empleados_obtener(p_id))->'data');
EXCEPTION
    WHEN unique_violation THEN
        RAISE EXCEPTION 'Ya existe otro empleado con esa identificación o correo' USING ERRCODE = 'P0006';
END;
$function$;

CREATE OR REPLACE FUNCTION rh.fn_empleados_obtener(p_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    v_data jsonb;
BEGIN
    SELECT jsonb_build_object(
        'id',                    e.id,
        'numero_identificacion', e.numero_identificacion,
        'tipo_identificacion',   e.tipo_identificacion,
        'nombres',               e.nombres,
        'apellidos',             e.apellidos,
        'nombre_completo',       TRIM(CONCAT_WS(' ', e.nombres, e.apellidos)),
        'email',                 e.email,
        'email_personal',        e.email_personal,
        'telefono',              e.telefono,
        'celular',               e.celular,
        'fecha_nacimiento',      to_char(e.fecha_nacimiento, 'YYYY-MM-DD'),
        'genero',                e.genero,
        'direccion',             e.direccion,
        -- La dirección que vino del mapa
        'provincia',             e.provincia,
        'canton',                e.canton,
        'parroquia',             e.parroquia,
        'calle_principal',       e.calle_principal,
        'calle_secundaria',      e.calle_secundaria,
        'numeracion',            e.numeracion,
        'ubicacion',             e.ubicacion,
        'codigo_postal',         e.codigo_postal,
        'coordenadas',           e.coordenadas,
        'link_coordenadas',      e.link_coordenadas,
        'url_foto_mapa',         e.url_foto_mapa,
        'url_foto_casa',         e.url_foto_casa,
        'cargo_id',              e.cargo_id,
        'cargo_nombre',          c.nombre,
        'sucursal_id',           e.sucursal_id,
        'sucursal_nombre',       s.nombre,
        -- El horario con el que se le miden los atrasos
        'horario_id',            e.horario_id,
        'horario_nombre',        h.nombre,
        'horario_tolerancia_min', h.tolerancia_min,
        'departamento_id',       e.departamento_id,
        'departamento_nombre',   d.nombre,
        'jefe_id',               e.jefe_id,
        'jefe_nombre',           NULLIF(TRIM(CONCAT_WS(' ', j.nombres, j.apellidos)), ''),
        'fecha_ingreso',         to_char(e.fecha_ingreso, 'YYYY-MM-DD'),
        'fecha_salida',          to_char(e.fecha_salida, 'YYYY-MM-DD'),
        'estado',                e.estado,
        'tipo_contrato',         e.tipo_contrato,
        'salario',               e.salario,
        'foto',                  e.foto,
        'activo',                e.activo,
        'created_by',            e.created_by,
        'updated_by',            e.updated_by,
        'created_at',            to_char(e.created_at, 'YYYY-MM-DD HH24:MI:SS'),
        'updated_at',            to_char(e.updated_at, 'YYYY-MM-DD HH24:MI:SS')
    ) INTO v_data
    FROM rh.empleados e
    LEFT JOIN rh.cargos c        ON c.id = e.cargo_id
    LEFT JOIN ventas.sucursales s ON s.id = e.sucursal_id
    LEFT JOIN rh.horarios_empleados h ON h.id = e.horario_id
    LEFT JOIN rh.departamentos d ON d.id = e.departamento_id
    LEFT JOIN rh.empleados j     ON j.id = e.jefe_id
    WHERE e.id = p_id;

    IF v_data IS NULL THEN
        RETURN jsonb_build_object('success', false, 'message', 'Empleado no encontrado', 'error_code', 'EMPLEADO_NOT_FOUND', 'data', null);
    END IF;
    RETURN jsonb_build_object('success', true, 'message', 'Empleado obtenido exitosamente', 'data', v_data);
EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object('success', false, 'message', 'Error al obtener el empleado: ' || SQLERRM, 'error_code', SQLSTATE);
END;
$function$;

CREATE OR REPLACE FUNCTION rh.fn_empleados_listar_paginado(p_page integer DEFAULT 1, p_per_page integer DEFAULT 15, p_search text DEFAULT ''::text, p_filtros jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
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

    WITH filtradas AS (
        SELECT e.*,
               c.nombre AS cargo_nombre,
               d.nombre AS departamento_nombre,
               s.nombre AS sucursal_nombre,
               h.nombre AS horario_nombre,
               NULLIF(TRIM(CONCAT_WS(' ', j.nombres, j.apellidos)), '') AS jefe_nombre
          FROM rh.empleados e
          LEFT JOIN rh.cargos c         ON c.id = e.cargo_id
          LEFT JOIN rh.departamentos d  ON d.id = e.departamento_id
          LEFT JOIN ventas.sucursales s ON s.id = e.sucursal_id
          LEFT JOIN rh.horarios_empleados h ON h.id = e.horario_id
          LEFT JOIN rh.empleados j      ON j.id = e.jefe_id
         WHERE e.deleted_at IS NULL              -- lo de la papelera no sale
           AND (v_filtro IS NULL
                OR CONCAT_WS(' ', e.nombres, e.apellidos) ILIKE '%' || v_filtro || '%'
                OR CONCAT_WS(' ', e.apellidos, e.nombres) ILIKE '%' || v_filtro || '%'
                OR e.numero_identificacion ILIKE '%' || v_filtro || '%'
                OR e.email   ILIKE '%' || v_filtro || '%'
                OR e.celular ILIKE '%' || v_filtro || '%'
                OR c.nombre  ILIKE '%' || v_filtro || '%'
                OR d.nombre  ILIKE '%' || v_filtro || '%'
                OR s.nombre  ILIKE '%' || v_filtro || '%'
                OR e.id::text ILIKE '%' || v_filtro || '%')

           -- ---------- LOS FILTROS DE LA CABECERA ----------
           AND (p_filtros->'id' IS NULL OR ventas.fn_filtro_numero(e.id, p_filtros->'id'))
           AND (p_filtros->'salario' IS NULL OR ventas.fn_filtro_numero(e.salario, p_filtros->'salario'))

           AND (p_filtros->'numero_identificacion' IS NULL OR ventas.fn_filtro_texto(e.numero_identificacion, p_filtros->'numero_identificacion'))
           AND (p_filtros->'tipo_identificacion'   IS NULL OR ventas.fn_filtro_texto(e.tipo_identificacion,   p_filtros->'tipo_identificacion'))
           AND (p_filtros->'nombres'               IS NULL OR ventas.fn_filtro_texto(e.nombres,               p_filtros->'nombres'))
           AND (p_filtros->'apellidos'             IS NULL OR ventas.fn_filtro_texto(e.apellidos,             p_filtros->'apellidos'))
           AND (p_filtros->'nombre_completo'       IS NULL OR ventas.fn_filtro_texto(TRIM(CONCAT_WS(' ', e.nombres, e.apellidos)), p_filtros->'nombre_completo'))
           AND (p_filtros->'email'                 IS NULL OR ventas.fn_filtro_texto(e.email,                 p_filtros->'email'))
           AND (p_filtros->'celular'               IS NULL OR ventas.fn_filtro_texto(e.celular,               p_filtros->'celular'))
           AND (p_filtros->'telefono'              IS NULL OR ventas.fn_filtro_texto(e.telefono,              p_filtros->'telefono'))
           AND (p_filtros->'estado'                IS NULL OR ventas.fn_filtro_texto(e.estado,                p_filtros->'estado'))
           AND (p_filtros->'tipo_contrato'         IS NULL OR ventas.fn_filtro_texto(e.tipo_contrato,         p_filtros->'tipo_contrato'))
           AND (p_filtros->'created_by'            IS NULL OR ventas.fn_filtro_texto(e.created_by,            p_filtros->'created_by'))
           AND (p_filtros->'updated_by'            IS NULL OR ventas.fn_filtro_texto(e.updated_by,            p_filtros->'updated_by'))

           -- Lo de las tablas de al lado, por su NOMBRE: es lo que se ve
           AND (p_filtros->'cargo_nombre'          IS NULL OR ventas.fn_filtro_texto(c.nombre, p_filtros->'cargo_nombre'))
           AND (p_filtros->'departamento_nombre'   IS NULL OR ventas.fn_filtro_texto(d.nombre, p_filtros->'departamento_nombre'))
           AND (p_filtros->'jefe_nombre'           IS NULL OR ventas.fn_filtro_texto(TRIM(CONCAT_WS(' ', j.nombres, j.apellidos)), p_filtros->'jefe_nombre'))
           -- Sin sucursal también se busca: «sin» no encuentra un NULL, así
           -- que la columna se mira con el texto que enseña la rejilla
           AND (p_filtros->'sucursal_nombre'       IS NULL OR ventas.fn_filtro_texto(COALESCE(s.nombre, 'Sin sucursal'), p_filtros->'sucursal_nombre'))
           -- Lo mismo con el horario: «sin» encuentra a quien no tiene
           AND (p_filtros->'horario_nombre'        IS NULL OR ventas.fn_filtro_texto(COALESCE(h.nombre, 'Sin horario'), p_filtros->'horario_nombre'))

           -- Las fechas, como texto sobre lo que se ve
           AND (p_filtros->'fecha_ingreso' IS NULL OR ventas.fn_filtro_texto(to_char(e.fecha_ingreso, 'YYYY-MM-DD'), p_filtros->'fecha_ingreso'))
           AND (p_filtros->'fecha_salida'  IS NULL OR ventas.fn_filtro_texto(to_char(e.fecha_salida,  'YYYY-MM-DD'), p_filtros->'fecha_salida'))
           AND (p_filtros->'created_at'    IS NULL OR ventas.fn_filtro_texto(to_char(e.created_at, 'YYYY-MM-DD HH24:MI:SS'), p_filtros->'created_at'))
           AND (p_filtros->'updated_at'    IS NULL OR ventas.fn_filtro_texto(to_char(e.updated_at, 'YYYY-MM-DD HH24:MI:SS'), p_filtros->'updated_at'))
    )
    SELECT COUNT(*),
           COALESCE((SELECT jsonb_agg(
               jsonb_build_object(
                   'id',                    t.id,
                   'numero_identificacion', t.numero_identificacion,
                   'tipo_identificacion',   t.tipo_identificacion,
                   'nombres',               t.nombres,
                   'apellidos',             t.apellidos,
                   'nombre_completo',       TRIM(CONCAT_WS(' ', t.nombres, t.apellidos)),
                   'email',                 t.email,
                   'email_personal',        t.email_personal,
                   'telefono',              t.telefono,
                   'celular',               t.celular,
                   'fecha_nacimiento',      to_char(t.fecha_nacimiento, 'YYYY-MM-DD'),
                   'genero',                t.genero,
                   'direccion',             t.direccion,
                   'cargo_id',              t.cargo_id,
                   'cargo_nombre',          t.cargo_nombre,
                   'sucursal_id',           t.sucursal_id,
                   'sucursal_nombre',       t.sucursal_nombre,
                   'horario_id',            t.horario_id,
                   'horario_nombre',        t.horario_nombre,
                   'departamento_id',       t.departamento_id,
                   'departamento_nombre',   t.departamento_nombre,
                   'jefe_id',               t.jefe_id,
                   'jefe_nombre',           t.jefe_nombre,
                   'fecha_ingreso',         to_char(t.fecha_ingreso, 'YYYY-MM-DD'),
                   'fecha_salida',          to_char(t.fecha_salida, 'YYYY-MM-DD'),
                   'estado',                t.estado,
                   'tipo_contrato',         t.tipo_contrato,
                   'salario',               t.salario,
                   'foto',                  t.foto,
                   'activo',                t.activo,
                   'created_by',            t.created_by,
                   'updated_by',            t.updated_by,
                   'created_at',            to_char(t.created_at, 'YYYY-MM-DD HH24:MI:SS'),
                   'updated_at',            to_char(t.updated_at, 'YYYY-MM-DD HH24:MI:SS')
               ) ORDER BY t.id DESC
             ) FROM (SELECT * FROM filtradas ORDER BY id DESC
                      LIMIT GREATEST(p_per_page, 1) OFFSET v_offset) t), '[]'::jsonb)
      INTO v_total, v_data
      FROM filtradas;

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
        RETURN jsonb_build_object('success', false,
                                  'message', 'Error al listar empleados: ' || SQLERRM,
                                  'error_code', SQLSTATE);
END;
$function$;

-- ---------------------------------------------------------------------------
-- 7. EL ATRASO DE UN EMPLEADO
-- ---------------------------------------------------------------------------
-- Para lo que existe todo esto: dada una marcación, qué jornada le tocaba a
-- ESE empleado y de cuántos minutos fue el atraso. Resuelve su horario y le
-- pasa el trabajo a rh.fn_horarios_empleados_evaluar.
--
-- Quien no tiene horario no tiene atraso: se contesta «SIN HORARIO» y no se
-- inventa ninguno. No escribe nada.
CREATE OR REPLACE FUNCTION rh.fn_empleados_atraso(
    p_empleado_id bigint,
    p_fecha_hora  timestamptz DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'rh'
AS $function$
DECLARE
    v_horario_id bigint;
    v_nombre     text;
    v_cuando     timestamptz;
    v_eval       jsonb;
BEGIN
    SELECT e.horario_id, TRIM(e.nombres || ' ' || e.apellidos)
      INTO v_horario_id, v_nombre
      FROM rh.empleados e
     WHERE e.id = p_empleado_id AND e.deleted_at IS NULL;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'message', 'El empleado no existe',
                                  'error_code', 'NO_EXISTE');
    END IF;

    IF v_horario_id IS NULL THEN
        RETURN jsonb_build_object('success', true,
            'message', format('%s no tiene horario asignado', v_nombre),
            'data', jsonb_build_object(
                'empleado_id', p_empleado_id, 'empleado', v_nombre,
                'horario_id', NULL, 'estado', 'SIN HORARIO', 'atraso_min', 0));
    END IF;

    v_cuando := COALESCE(p_fecha_hora, CURRENT_TIMESTAMP);
    v_eval   := rh.fn_horarios_empleados_evaluar(v_horario_id, v_cuando);

    IF NOT (v_eval->>'success')::boolean THEN
        RETURN v_eval;
    END IF;

    RETURN jsonb_build_object('success', true, 'message', v_eval->>'message',
        'data', (v_eval->'data')
                || jsonb_build_object('empleado_id', p_empleado_id, 'empleado', v_nombre));
END;
$function$;

COMMIT;
