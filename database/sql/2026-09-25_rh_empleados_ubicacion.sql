-- ===========================================================================
-- EMPLEADOS: la dirección se toma de Google Maps
--
-- Hasta ahora «direccion» era un texto suelto que cada quien escribía como
-- quería. Ahora la pantalla abre el mapa, el usuario busca el sitio y de ahí
-- salen la división política, las calles, las coordenadas y dos fotos: la
-- vista del mapa y la de la calle (la fachada).
--
-- «direccion» se queda: es lo que el usuario deja escrito. «ubicacion» es la
-- dirección tal como la devuelve Google, que no siempre coinciden.
--
-- Las funciones de alta y modificación NO se tocan: ya tienen 26 parámetros
-- posicionales y sumarles doce más sería pedir un error. La ubicación se
-- guarda con su propia función, que recibe un jsonb.
--
--   psql -h 192.168.2.173 -U postgres -d crm3 -f 2026-09-25_rh_empleados_ubicacion.sql
-- ===========================================================================

ALTER TABLE rh.empleados
    ADD COLUMN IF NOT EXISTS provincia         varchar(100),
    ADD COLUMN IF NOT EXISTS canton            varchar(100),
    ADD COLUMN IF NOT EXISTS parroquia         varchar(100),
    ADD COLUMN IF NOT EXISTS calle_principal   varchar(200),
    ADD COLUMN IF NOT EXISTS calle_secundaria  varchar(200),
    ADD COLUMN IF NOT EXISTS numeracion        varchar(50),
    ADD COLUMN IF NOT EXISTS ubicacion         text,
    ADD COLUMN IF NOT EXISTS codigo_postal     varchar(20),
    ADD COLUMN IF NOT EXISTS coordenadas       varchar(60),
    ADD COLUMN IF NOT EXISTS link_coordenadas  text,
    ADD COLUMN IF NOT EXISTS url_foto_mapa     varchar(255),
    ADD COLUMN IF NOT EXISTS url_foto_casa     varchar(255);

COMMENT ON COLUMN rh.empleados.ubicacion        IS 'La dirección tal como la devuelve Google; «direccion» es la que escribió el usuario';
COMMENT ON COLUMN rh.empleados.coordenadas      IS 'Latitud,longitud con seis decimales';
COMMENT ON COLUMN rh.empleados.link_coordenadas IS 'Enlace a Google Maps para abrir el punto';
COMMENT ON COLUMN rh.empleados.url_foto_mapa    IS 'Nombre del archivo de la vista de mapa, en storage/app/public/img/empleados';
COMMENT ON COLUMN rh.empleados.url_foto_casa    IS 'Nombre del archivo de la vista de calle (la fachada), en la misma carpeta';


-- ---------------------------------------------------------------------------
-- Guardar el bloque de ubicación
--
-- Todo en un jsonb: así la firma no crece cada vez que Google devuelva un
-- dato más. Lo que no venga en el objeto se deja como estaba, y una cadena
-- vacía sí borra el campo (es como se quita un dato desde la pantalla).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION rh.fn_empleados_ubicacion(
    p_id bigint,
    p_datos jsonb,
    p_usuario_id bigint DEFAULT NULL::bigint,
    p_usuario_login character varying DEFAULT NULL::character varying,
    p_usuario_nombre character varying DEFAULT NULL::character varying,
    p_ip_address inet DEFAULT NULL::inet,
    p_user_agent text DEFAULT NULL::text,
    p_request_id uuid DEFAULT NULL::uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'rh', 'auditoria'
AS $function$
DECLARE
    v_existe boolean;
BEGIN
    PERFORM set_config('app.usuario_id',     COALESCE(p_usuario_id::text, ''), true);
    PERFORM set_config('app.usuario_login',  COALESCE(p_usuario_login, current_user), true);
    PERFORM set_config('app.usuario_nombre', COALESCE(p_usuario_nombre, current_user), true);
    PERFORM set_config('app.ip_address',     COALESCE(p_ip_address::text, ''), true);
    PERFORM set_config('app.user_agent',     COALESCE(p_user_agent, ''), true);
    PERFORM set_config('app.request_id',     COALESCE(p_request_id::text, ''), true);
    PERFORM set_config('app.modulo',         'rh.empleados', true);

    SELECT true INTO v_existe FROM rh.empleados WHERE id = p_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'El empleado no existe' USING ERRCODE = 'P0013';
    END IF;

    UPDATE rh.empleados SET
        provincia        = COALESCE(NULLIF(TRIM(p_datos->>'provincia'), ''),        CASE WHEN p_datos ? 'provincia'        THEN NULL ELSE provincia        END),
        canton           = COALESCE(NULLIF(TRIM(p_datos->>'canton'), ''),           CASE WHEN p_datos ? 'canton'           THEN NULL ELSE canton           END),
        parroquia        = COALESCE(NULLIF(TRIM(p_datos->>'parroquia'), ''),        CASE WHEN p_datos ? 'parroquia'        THEN NULL ELSE parroquia        END),
        calle_principal  = COALESCE(NULLIF(TRIM(p_datos->>'calle_principal'), ''),  CASE WHEN p_datos ? 'calle_principal'  THEN NULL ELSE calle_principal  END),
        calle_secundaria = COALESCE(NULLIF(TRIM(p_datos->>'calle_secundaria'), ''), CASE WHEN p_datos ? 'calle_secundaria' THEN NULL ELSE calle_secundaria END),
        numeracion       = COALESCE(NULLIF(TRIM(p_datos->>'numeracion'), ''),       CASE WHEN p_datos ? 'numeracion'       THEN NULL ELSE numeracion       END),
        ubicacion        = COALESCE(NULLIF(TRIM(p_datos->>'ubicacion'), ''),        CASE WHEN p_datos ? 'ubicacion'        THEN NULL ELSE ubicacion        END),
        codigo_postal    = COALESCE(NULLIF(TRIM(p_datos->>'codigo_postal'), ''),    CASE WHEN p_datos ? 'codigo_postal'    THEN NULL ELSE codigo_postal    END),
        coordenadas      = COALESCE(NULLIF(TRIM(p_datos->>'coordenadas'), ''),      CASE WHEN p_datos ? 'coordenadas'      THEN NULL ELSE coordenadas      END),
        link_coordenadas = COALESCE(NULLIF(TRIM(p_datos->>'link_coordenadas'), ''), CASE WHEN p_datos ? 'link_coordenadas' THEN NULL ELSE link_coordenadas END),
        updated_by       = COALESCE(p_usuario_login, updated_by),
        updated_at       = CURRENT_TIMESTAMP
    WHERE id = p_id;

    RETURN jsonb_build_object('success', true, 'message', 'Ubicación guardada',
                              'data', (rh.fn_empleados_obtener(p_id))->'data');
END;
$function$;


-- ---------------------------------------------------------------------------
-- Registrar una de las dos fotos del mapa
--
-- El archivo lo deja el controlador en disco; aquí sólo se apunta su nombre.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION rh.fn_empleados_foto_ubicacion(
    p_id bigint,
    p_campo text,
    p_archivo character varying,
    p_usuario_id bigint DEFAULT NULL::bigint,
    p_usuario_login character varying DEFAULT NULL::character varying,
    p_usuario_nombre character varying DEFAULT NULL::character varying,
    p_ip_address inet DEFAULT NULL::inet,
    p_user_agent text DEFAULT NULL::text,
    p_request_id uuid DEFAULT NULL::uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'rh', 'auditoria'
AS $function$
BEGIN
    PERFORM set_config('app.usuario_id',     COALESCE(p_usuario_id::text, ''), true);
    PERFORM set_config('app.usuario_login',  COALESCE(p_usuario_login, current_user), true);
    PERFORM set_config('app.usuario_nombre', COALESCE(p_usuario_nombre, current_user), true);
    PERFORM set_config('app.ip_address',     COALESCE(p_ip_address::text, ''), true);
    PERFORM set_config('app.user_agent',     COALESCE(p_user_agent, ''), true);
    PERFORM set_config('app.request_id',     COALESCE(p_request_id::text, ''), true);
    PERFORM set_config('app.modulo',         'rh.empleados', true);

    IF p_campo NOT IN ('mapa', 'casa') THEN
        RAISE EXCEPTION 'La foto debe ser «mapa» o «casa»' USING ERRCODE = 'P0010';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM rh.empleados WHERE id = p_id) THEN
        RAISE EXCEPTION 'El empleado no existe' USING ERRCODE = 'P0013';
    END IF;

    IF p_campo = 'mapa' THEN
        UPDATE rh.empleados
           SET url_foto_mapa = NULLIF(TRIM(COALESCE(p_archivo, '')), ''),
               updated_by = COALESCE(p_usuario_login, updated_by), updated_at = CURRENT_TIMESTAMP
         WHERE id = p_id;
    ELSE
        UPDATE rh.empleados
           SET url_foto_casa = NULLIF(TRIM(COALESCE(p_archivo, '')), ''),
               updated_by = COALESCE(p_usuario_login, updated_by), updated_at = CURRENT_TIMESTAMP
         WHERE id = p_id;
    END IF;

    RETURN jsonb_build_object('success', true, 'message', 'Foto guardada',
                              'data', (rh.fn_empleados_obtener(p_id))->'data');
END;
$function$;


-- ---------------------------------------------------------------------------
-- El empleado, ahora con su ubicación
-- ---------------------------------------------------------------------------
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
