-- ===========================================================================
-- ACTIVAR / DESACTIVAR SIN ABRIR EL FORMULARIO
-- ===========================================================================
-- Fecha: 2026-10-11
-- Va detrás de 2026-10-11_ventas_clientes_activar.sql, que hizo lo mismo con
-- los clientes. Aquí van las otras siete tablas que tienen la casilla en una
-- rejilla: usuarios, horarios, perfiles, cargos, departamentos, empleados y
-- boletines.
--
-- POR QUÉ UNA FUNCIÓN POR TABLA Y NO UNA GENÉRICA. Una
-- `fn_activar(p_tabla, p_id, …)` tendría que montar la consulta con EXECUTE a
-- partir de un nombre que llega de fuera: eso es exactamente la forma de
-- escribir una inyección de SQL sin darse cuenta. Son siete funciones casi
-- iguales y aburridas, y aburridas es lo que se quiere aquí.
--
-- QUÉ TIENEN EN COMÚN
--
--   · Escriben SÓLO la columna de la casilla. No pasan por fn_*_modificar,
--     que revalida la ficha entera: a un registro cargado antes de que
--     existiera una regla no habría forma de desactivarlo sin arreglarle
--     primero todo lo demás, que es lo contrario de lo que se quiere al dar
--     de baja algo.
--   · Sin `p_activo` ALTERNAN. La pantalla manda el valor que quiere para que
--     dos personas pulsando a la vez no se peleen: quien manda `false` acaba
--     en `false`, no en «lo contrario de lo que había».
--   · Si ya estaba así NO ESCRIBEN y contestan bien. Sin esto, dos
--     pulsaciones seguidas dejarían dos apuntes de auditoría sin ningún
--     cambio detrás.
--   · `updated_by` y `updated_at` los ponen los disparadores de cada tabla
--     (fn_set_audit_users y fn_update_updated_at_column, que las siete
--     llevan). Se leen de vuelta con RETURNING en vez de calcularlos aquí:
--     es la única forma de devolver lo que quedó escrito de verdad.
--   · A la auditoría va SÓLO lo que cambió. Si se dejara al disparador, que
--     cuando no hay contexto guarda row_to_json(OLD) y row_to_json(NEW), el
--     apunte traería las cuarenta columnas y habría que buscar la casilla
--     entre ellas.
--   · NO LEVANTAN EXCEPCIÓN: devuelven `success: false` con un `error_code`,
--     como pide el estándar de la casa («capturar WHEN OTHERS para que un
--     error no llegue al cliente como un 500 pelado»). Así valen igual para
--     los controladores nuevos y para los dos viejos —Horario y Profile—,
--     que no capturan QueryException.
--
-- NO SE TOCA `estado` DONDE EXISTE (rh.empleados): es otra cosa y en el
-- formulario también se guardan por separado. En core.boletines sí cambia,
-- pero porque allí `estado` NO es una columna: lo calcula la base a partir
-- de `activo` y las fechas, así que se devuelve recalculado.
--
-- Idempotente: se puede volver a correr.
-- ===========================================================================


-- ---------------------------------------------------------------------------
-- USUARIOS (seguridad.users.isactive)
--
-- La única de las siete que necesita un cerrojo: el middleware
-- VerificarUsuarioActivo contesta 401 a TODA ruta cuando isactive es false,
-- así que quien se desactive a sí mismo se queda fuera del CRM y ya no puede
-- volver a entrar para deshacerlo. Tiene que desactivarlo otro.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION seguridad.fn_usuarios_activar(
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
SET search_path TO 'pg_catalog', 'seguridad', 'auditoria'
AS $function$
DECLARE
    v_antes      boolean;
    v_nuevo      boolean;
    v_borrado    timestamptz;
    v_updated_by varchar;
    v_updated_at text;
BEGIN
    PERFORM seguridad.fn_usuarios_contexto_auditoria(
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    SELECT isactive, deleted_at INTO v_antes, v_borrado
      FROM seguridad.users WHERE id = p_id;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'error_code', 'NO_EXISTE',
                                  'message', 'El usuario no existe');
    END IF;

    IF v_borrado IS NOT NULL THEN
        RETURN jsonb_build_object('success', false, 'error_code', 'EN_PAPELERA',
                                  'message', 'Ese usuario está en la papelera: hay que restaurarlo primero');
    END IF;

    v_nuevo := COALESCE(p_activo, NOT COALESCE(v_antes, true));

    IF NOT v_nuevo AND p_usuario_id IS NOT NULL AND p_usuario_id = p_id THEN
        RETURN jsonb_build_object('success', false, 'error_code', 'YO_MISMO',
                                  'message', 'No puedes desactivar tu propio usuario: te quedarías sin poder entrar. Que lo haga otro.');
    END IF;

    IF v_nuevo IS NOT DISTINCT FROM v_antes THEN
        SELECT updated_by, to_char(updated_at, 'YYYY-MM-DD HH24:MI:SS')
          INTO v_updated_by, v_updated_at FROM seguridad.users WHERE id = p_id;
        RETURN jsonb_build_object('success', true,
            'message', CASE WHEN v_nuevo THEN 'El usuario ya estaba activo' ELSE 'El usuario ya estaba inactivo' END,
            'data', jsonb_build_object('id', p_id, 'isactive', v_nuevo,
                                       'updated_by', v_updated_by, 'updated_at', v_updated_at));
    END IF;

    PERFORM set_config('app.datos_anteriores', jsonb_build_object('id', p_id, 'isactive', v_antes)::text, true);
    PERFORM set_config('app.datos_nuevos',     jsonb_build_object('id', p_id, 'isactive', v_nuevo)::text, true);

    UPDATE seguridad.users SET isactive = v_nuevo WHERE id = p_id
    RETURNING isactive, updated_by, to_char(updated_at, 'YYYY-MM-DD HH24:MI:SS')
         INTO v_nuevo, v_updated_by, v_updated_at;

    PERFORM set_config('app.datos_anteriores', '', true);
    PERFORM set_config('app.datos_nuevos', '', true);

    RETURN jsonb_build_object('success', true,
        'message', CASE WHEN v_nuevo THEN 'Usuario activado' ELSE 'Usuario desactivado' END,
        'data', jsonb_build_object('id', p_id, 'isactive', v_nuevo,
                                   'updated_by', v_updated_by, 'updated_at', v_updated_at));

EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false, 'error_code', 'ERROR',
                              'message', 'No se pudo cambiar el estado del usuario: ' || SQLERRM);
END;
$function$;

ALTER FUNCTION seguridad.fn_usuarios_activar(bigint, boolean, bigint, varchar, varchar, inet, text, uuid) OWNER TO postgres;
COMMENT ON FUNCTION seguridad.fn_usuarios_activar(bigint, boolean, bigint, varchar, varchar, inet, text, uuid)
    IS 'Pone seguridad.users.isactive sin pasar por el formulario. Sin p_activo, alterna. No deja que nadie se desactive a si mismo.';


-- ---------------------------------------------------------------------------
-- HORARIOS (seguridad.chorarios.activo)
--
-- Con el mismo cerrojo que los usuarios, y por el mismo motivo: el middleware
-- VerificarUsuarioActivo contesta 401 cuando EL HORARIO ASIGNADO al usuario
-- esta inactivo. Quien apague el horario que el mismo tiene puesto se queda
-- fuera del CRM y ya no puede entrar a deshacerlo. Se comprobo en una prueba
-- de verdad: apagar el horario 1 dejo al usuario de pruebas sin poder llamar
-- a ninguna ruta.
--
-- Solo se mira SU horario. Apagar el horario de otros se permite: es trabajo
-- normal de administracion, y a ellos les queda quien se lo vuelva a encender.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION seguridad.fn_horarios_activar(
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
SET search_path TO 'pg_catalog', 'seguridad', 'auditoria'
AS $function$
DECLARE
    v_antes      boolean;
    v_nuevo      boolean;
    v_updated_by varchar;
    v_updated_at text;
BEGIN
    PERFORM set_config('app.usuario_id',     COALESCE(p_usuario_id::text, ''), true);
    PERFORM set_config('app.usuario_login',  COALESCE(p_usuario_login, current_user), true);
    PERFORM set_config('app.usuario_nombre', COALESCE(p_usuario_nombre, current_user), true);
    PERFORM set_config('app.ip_address',     COALESCE(p_ip_address::text, ''), true);
    PERFORM set_config('app.user_agent',     COALESCE(p_user_agent, ''), true);
    PERFORM set_config('app.request_id',     COALESCE(p_request_id::text, ''), true);
    PERFORM set_config('app.modulo',         'seguridad.chorarios', true);

    SELECT activo INTO v_antes FROM seguridad.chorarios WHERE id = p_id;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'error_code', 'NO_EXISTE',
                                  'message', 'El horario no existe');
    END IF;

    v_nuevo := COALESCE(p_activo, NOT COALESCE(v_antes, true));

    IF NOT v_nuevo AND p_usuario_id IS NOT NULL
       AND EXISTS (SELECT 1 FROM seguridad.users u WHERE u.id = p_usuario_id AND u.chorario_id = p_id) THEN
        RETURN jsonb_build_object('success', false, 'error_code', 'MI_HORARIO',
                                  'message', 'Ese es tu propio horario: si lo desactivas te quedas sin poder entrar. Que lo haga otro, o cambia antes el tuyo.');
    END IF;

    IF v_nuevo IS NOT DISTINCT FROM v_antes THEN
        SELECT updated_by, to_char(updated_at, 'YYYY-MM-DD HH24:MI:SS')
          INTO v_updated_by, v_updated_at FROM seguridad.chorarios WHERE id = p_id;
        RETURN jsonb_build_object('success', true,
            'message', CASE WHEN v_nuevo THEN 'El horario ya estaba activo' ELSE 'El horario ya estaba inactivo' END,
            'data', jsonb_build_object('id', p_id, 'activo', v_nuevo,
                                       'updated_by', v_updated_by, 'updated_at', v_updated_at));
    END IF;

    PERFORM set_config('app.datos_anteriores', jsonb_build_object('id', p_id, 'activo', v_antes)::text, true);
    PERFORM set_config('app.datos_nuevos',     jsonb_build_object('id', p_id, 'activo', v_nuevo)::text, true);

    UPDATE seguridad.chorarios SET activo = v_nuevo WHERE id = p_id
    RETURNING activo, updated_by, to_char(updated_at, 'YYYY-MM-DD HH24:MI:SS')
         INTO v_nuevo, v_updated_by, v_updated_at;

    PERFORM set_config('app.datos_anteriores', '', true);
    PERFORM set_config('app.datos_nuevos', '', true);

    RETURN jsonb_build_object('success', true,
        'message', CASE WHEN v_nuevo THEN 'Horario activado' ELSE 'Horario desactivado' END,
        'data', jsonb_build_object('id', p_id, 'activo', v_nuevo,
                                   'updated_by', v_updated_by, 'updated_at', v_updated_at));

EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false, 'error_code', 'ERROR',
                              'message', 'No se pudo cambiar el estado del horario: ' || SQLERRM);
END;
$function$;

ALTER FUNCTION seguridad.fn_horarios_activar(bigint, boolean, bigint, varchar, varchar, inet, text, uuid) OWNER TO postgres;
COMMENT ON FUNCTION seguridad.fn_horarios_activar(bigint, boolean, bigint, varchar, varchar, inet, text, uuid)
    IS 'Pone seguridad.chorarios.activo sin pasar por el formulario. Sin p_activo, alterna. No deja apagar el horario propio.';


-- ---------------------------------------------------------------------------
-- PERFILES (seguridad.perfiles.activo)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION seguridad.fn_perfiles_activar(
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
SET search_path TO 'pg_catalog', 'seguridad', 'auditoria'
AS $function$
DECLARE
    v_antes      boolean;
    v_nuevo      boolean;
    v_updated_by varchar;
    v_updated_at text;
BEGIN
    PERFORM set_config('app.usuario_id',     COALESCE(p_usuario_id::text, ''), true);
    PERFORM set_config('app.usuario_login',  COALESCE(p_usuario_login, current_user), true);
    PERFORM set_config('app.usuario_nombre', COALESCE(p_usuario_nombre, current_user), true);
    PERFORM set_config('app.ip_address',     COALESCE(p_ip_address::text, ''), true);
    PERFORM set_config('app.user_agent',     COALESCE(p_user_agent, ''), true);
    PERFORM set_config('app.request_id',     COALESCE(p_request_id::text, ''), true);
    PERFORM set_config('app.modulo',         'seguridad.perfiles', true);

    SELECT activo INTO v_antes FROM seguridad.perfiles WHERE id = p_id;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'error_code', 'NO_EXISTE',
                                  'message', 'El perfil no existe');
    END IF;

    v_nuevo := COALESCE(p_activo, NOT COALESCE(v_antes, true));

    IF v_nuevo IS NOT DISTINCT FROM v_antes THEN
        SELECT updated_by, to_char(updated_at, 'YYYY-MM-DD HH24:MI:SS')
          INTO v_updated_by, v_updated_at FROM seguridad.perfiles WHERE id = p_id;
        RETURN jsonb_build_object('success', true,
            'message', CASE WHEN v_nuevo THEN 'El perfil ya estaba activo' ELSE 'El perfil ya estaba inactivo' END,
            'data', jsonb_build_object('id', p_id, 'activo', v_nuevo,
                                       'updated_by', v_updated_by, 'updated_at', v_updated_at));
    END IF;

    PERFORM set_config('app.datos_anteriores', jsonb_build_object('id', p_id, 'activo', v_antes)::text, true);
    PERFORM set_config('app.datos_nuevos',     jsonb_build_object('id', p_id, 'activo', v_nuevo)::text, true);

    UPDATE seguridad.perfiles SET activo = v_nuevo WHERE id = p_id
    RETURNING activo, updated_by, to_char(updated_at, 'YYYY-MM-DD HH24:MI:SS')
         INTO v_nuevo, v_updated_by, v_updated_at;

    PERFORM set_config('app.datos_anteriores', '', true);
    PERFORM set_config('app.datos_nuevos', '', true);

    RETURN jsonb_build_object('success', true,
        'message', CASE WHEN v_nuevo THEN 'Perfil activado' ELSE 'Perfil desactivado' END,
        'data', jsonb_build_object('id', p_id, 'activo', v_nuevo,
                                   'updated_by', v_updated_by, 'updated_at', v_updated_at));

EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false, 'error_code', 'ERROR',
                              'message', 'No se pudo cambiar el estado del perfil: ' || SQLERRM);
END;
$function$;

ALTER FUNCTION seguridad.fn_perfiles_activar(bigint, boolean, bigint, varchar, varchar, inet, text, uuid) OWNER TO postgres;
COMMENT ON FUNCTION seguridad.fn_perfiles_activar(bigint, boolean, bigint, varchar, varchar, inet, text, uuid)
    IS 'Pone seguridad.perfiles.activo sin pasar por el formulario. Sin p_activo, alterna.';


-- ---------------------------------------------------------------------------
-- CARGOS (rh.cargos.activo)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION rh.fn_cargos_activar(
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
    PERFORM rh.fn_contexto_auditoria('rh.cargos', p_usuario_id, p_usuario_login,
                                     p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    SELECT activo INTO v_antes FROM rh.cargos WHERE id = p_id;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'error_code', 'NO_EXISTE',
                                  'message', 'El cargo no existe');
    END IF;

    v_nuevo := COALESCE(p_activo, NOT COALESCE(v_antes, true));

    IF v_nuevo IS NOT DISTINCT FROM v_antes THEN
        SELECT updated_by, to_char(updated_at, 'YYYY-MM-DD HH24:MI:SS')
          INTO v_updated_by, v_updated_at FROM rh.cargos WHERE id = p_id;
        RETURN jsonb_build_object('success', true,
            'message', CASE WHEN v_nuevo THEN 'El cargo ya estaba activo' ELSE 'El cargo ya estaba inactivo' END,
            'data', jsonb_build_object('id', p_id, 'activo', v_nuevo,
                                       'updated_by', v_updated_by, 'updated_at', v_updated_at));
    END IF;

    PERFORM set_config('app.datos_anteriores', jsonb_build_object('id', p_id, 'activo', v_antes)::text, true);
    PERFORM set_config('app.datos_nuevos',     jsonb_build_object('id', p_id, 'activo', v_nuevo)::text, true);

    UPDATE rh.cargos SET activo = v_nuevo WHERE id = p_id
    RETURNING activo, updated_by, to_char(updated_at, 'YYYY-MM-DD HH24:MI:SS')
         INTO v_nuevo, v_updated_by, v_updated_at;

    PERFORM set_config('app.datos_anteriores', '', true);
    PERFORM set_config('app.datos_nuevos', '', true);

    RETURN jsonb_build_object('success', true,
        'message', CASE WHEN v_nuevo THEN 'Cargo activado' ELSE 'Cargo desactivado' END,
        'data', jsonb_build_object('id', p_id, 'activo', v_nuevo,
                                   'updated_by', v_updated_by, 'updated_at', v_updated_at));

EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false, 'error_code', 'ERROR',
                              'message', 'No se pudo cambiar el estado del cargo: ' || SQLERRM);
END;
$function$;

ALTER FUNCTION rh.fn_cargos_activar(bigint, boolean, bigint, varchar, varchar, inet, text, uuid) OWNER TO postgres;
COMMENT ON FUNCTION rh.fn_cargos_activar(bigint, boolean, bigint, varchar, varchar, inet, text, uuid)
    IS 'Pone rh.cargos.activo sin pasar por el formulario. Sin p_activo, alterna.';


-- ---------------------------------------------------------------------------
-- DEPARTAMENTOS (rh.departamentos.activo)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION rh.fn_departamentos_activar(
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
    PERFORM rh.fn_contexto_auditoria('rh.departamentos', p_usuario_id, p_usuario_login,
                                     p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    SELECT activo INTO v_antes FROM rh.departamentos WHERE id = p_id;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'error_code', 'NO_EXISTE',
                                  'message', 'El departamento no existe');
    END IF;

    v_nuevo := COALESCE(p_activo, NOT COALESCE(v_antes, true));

    IF v_nuevo IS NOT DISTINCT FROM v_antes THEN
        SELECT updated_by, to_char(updated_at, 'YYYY-MM-DD HH24:MI:SS')
          INTO v_updated_by, v_updated_at FROM rh.departamentos WHERE id = p_id;
        RETURN jsonb_build_object('success', true,
            'message', CASE WHEN v_nuevo THEN 'El departamento ya estaba activo' ELSE 'El departamento ya estaba inactivo' END,
            'data', jsonb_build_object('id', p_id, 'activo', v_nuevo,
                                       'updated_by', v_updated_by, 'updated_at', v_updated_at));
    END IF;

    PERFORM set_config('app.datos_anteriores', jsonb_build_object('id', p_id, 'activo', v_antes)::text, true);
    PERFORM set_config('app.datos_nuevos',     jsonb_build_object('id', p_id, 'activo', v_nuevo)::text, true);

    UPDATE rh.departamentos SET activo = v_nuevo WHERE id = p_id
    RETURNING activo, updated_by, to_char(updated_at, 'YYYY-MM-DD HH24:MI:SS')
         INTO v_nuevo, v_updated_by, v_updated_at;

    PERFORM set_config('app.datos_anteriores', '', true);
    PERFORM set_config('app.datos_nuevos', '', true);

    RETURN jsonb_build_object('success', true,
        'message', CASE WHEN v_nuevo THEN 'Departamento activado' ELSE 'Departamento desactivado' END,
        'data', jsonb_build_object('id', p_id, 'activo', v_nuevo,
                                   'updated_by', v_updated_by, 'updated_at', v_updated_at));

EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false, 'error_code', 'ERROR',
                              'message', 'No se pudo cambiar el estado del departamento: ' || SQLERRM);
END;
$function$;

ALTER FUNCTION rh.fn_departamentos_activar(bigint, boolean, bigint, varchar, varchar, inet, text, uuid) OWNER TO postgres;
COMMENT ON FUNCTION rh.fn_departamentos_activar(bigint, boolean, bigint, varchar, varchar, inet, text, uuid)
    IS 'Pone rh.departamentos.activo sin pasar por el formulario. Sin p_activo, alterna.';


-- ---------------------------------------------------------------------------
-- EMPLEADOS (rh.empleados.activo)
--
-- `estado` (ACTIVO / VACACIONES / LIQUIDADO…) NO se toca: cuenta la situación
-- laboral, y `activo` dice si la ficha está en juego. En el formulario también
-- se guardan por separado.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION rh.fn_empleados_activar(
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
    PERFORM rh.fn_contexto_auditoria('rh.empleados', p_usuario_id, p_usuario_login,
                                     p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    SELECT activo INTO v_antes FROM rh.empleados WHERE id = p_id;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'error_code', 'NO_EXISTE',
                                  'message', 'El empleado no existe');
    END IF;

    v_nuevo := COALESCE(p_activo, NOT COALESCE(v_antes, true));

    IF v_nuevo IS NOT DISTINCT FROM v_antes THEN
        SELECT updated_by, to_char(updated_at, 'YYYY-MM-DD HH24:MI:SS')
          INTO v_updated_by, v_updated_at FROM rh.empleados WHERE id = p_id;
        RETURN jsonb_build_object('success', true,
            'message', CASE WHEN v_nuevo THEN 'El empleado ya estaba activo' ELSE 'El empleado ya estaba inactivo' END,
            'data', jsonb_build_object('id', p_id, 'activo', v_nuevo,
                                       'updated_by', v_updated_by, 'updated_at', v_updated_at));
    END IF;

    PERFORM set_config('app.datos_anteriores', jsonb_build_object('id', p_id, 'activo', v_antes)::text, true);
    PERFORM set_config('app.datos_nuevos',     jsonb_build_object('id', p_id, 'activo', v_nuevo)::text, true);

    UPDATE rh.empleados SET activo = v_nuevo WHERE id = p_id
    RETURNING activo, updated_by, to_char(updated_at, 'YYYY-MM-DD HH24:MI:SS')
         INTO v_nuevo, v_updated_by, v_updated_at;

    PERFORM set_config('app.datos_anteriores', '', true);
    PERFORM set_config('app.datos_nuevos', '', true);

    RETURN jsonb_build_object('success', true,
        'message', CASE WHEN v_nuevo THEN 'Empleado activado' ELSE 'Empleado desactivado' END,
        'data', jsonb_build_object('id', p_id, 'activo', v_nuevo,
                                   'updated_by', v_updated_by, 'updated_at', v_updated_at));

EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false, 'error_code', 'ERROR',
                              'message', 'No se pudo cambiar el estado del empleado: ' || SQLERRM);
END;
$function$;

ALTER FUNCTION rh.fn_empleados_activar(bigint, boolean, bigint, varchar, varchar, inet, text, uuid) OWNER TO postgres;
COMMENT ON FUNCTION rh.fn_empleados_activar(bigint, boolean, bigint, varchar, varchar, inet, text, uuid)
    IS 'Pone rh.empleados.activo sin pasar por el formulario. Sin p_activo, alterna. No toca estado.';


-- ---------------------------------------------------------------------------
-- BOLETINES (core.boletines.activo)
--
-- Aquí `estado` SÍ cambia, y no es una contradicción con lo de arriba: en
-- boletines `estado` no existe como columna. Lo calcula fn_boletines_json a
-- partir de `activo` y de las fechas (INACTIVO / PROGRAMADO / CADUCADO /
-- VIGENTE), así que se devuelve recalculado para que la rejilla no se quede
-- diciendo «Vigente» en un boletín que acaba de apagarse.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION core.fn_boletines_activar(
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
SET search_path TO 'pg_catalog', 'core', 'auditoria'
AS $function$
DECLARE
    v_antes      boolean;
    v_nuevo      boolean;
    v_borrado    timestamptz;
    v_updated_by varchar;
    v_updated_at text;
    v_estado     text;
    v_vigente    boolean;
BEGIN
    PERFORM core.fn_boletines_contexto_auditoria(
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    SELECT activo, deleted_at INTO v_antes, v_borrado
      FROM core.boletines WHERE id = p_id;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'error_code', 'NO_EXISTE',
                                  'message', 'El boletín no existe');
    END IF;

    IF v_borrado IS NOT NULL THEN
        RETURN jsonb_build_object('success', false, 'error_code', 'EN_PAPELERA',
                                  'message', 'Ese boletín está en la papelera: hay que restaurarlo primero');
    END IF;

    v_nuevo := COALESCE(p_activo, NOT v_antes);

    IF v_nuevo IS NOT DISTINCT FROM v_antes THEN
        SELECT updated_by, to_char(updated_at, 'YYYY-MM-DD HH24:MI:SS'),
               CASE WHEN NOT activo                      THEN 'INACTIVO'
                    WHEN CURRENT_DATE < desde            THEN 'PROGRAMADO'
                    WHEN CURRENT_DATE > hasta            THEN 'CADUCADO'
                    ELSE 'VIGENTE' END,
               (activo AND CURRENT_DATE BETWEEN desde AND hasta)
          INTO v_updated_by, v_updated_at, v_estado, v_vigente
          FROM core.boletines WHERE id = p_id;
        RETURN jsonb_build_object('success', true,
            'message', CASE WHEN v_nuevo THEN 'El boletín ya estaba activo' ELSE 'El boletín ya estaba inactivo' END,
            'data', jsonb_build_object('id', p_id, 'activo', v_nuevo, 'estado', v_estado, 'vigente', v_vigente,
                                       'updated_by', v_updated_by, 'updated_at', v_updated_at));
    END IF;

    PERFORM set_config('app.datos_anteriores', jsonb_build_object('id', p_id, 'activo', v_antes)::text, true);
    PERFORM set_config('app.datos_nuevos',     jsonb_build_object('id', p_id, 'activo', v_nuevo)::text, true);

    UPDATE core.boletines SET activo = v_nuevo WHERE id = p_id
    RETURNING activo, updated_by, to_char(updated_at, 'YYYY-MM-DD HH24:MI:SS'),
              CASE WHEN NOT activo                 THEN 'INACTIVO'
                   WHEN CURRENT_DATE < desde       THEN 'PROGRAMADO'
                   WHEN CURRENT_DATE > hasta       THEN 'CADUCADO'
                   ELSE 'VIGENTE' END,
              (activo AND CURRENT_DATE BETWEEN desde AND hasta)
         INTO v_nuevo, v_updated_by, v_updated_at, v_estado, v_vigente;

    PERFORM set_config('app.datos_anteriores', '', true);
    PERFORM set_config('app.datos_nuevos', '', true);

    RETURN jsonb_build_object('success', true,
        'message', CASE WHEN v_nuevo THEN 'Boletín activado' ELSE 'Boletín desactivado' END,
        'data', jsonb_build_object('id', p_id, 'activo', v_nuevo, 'estado', v_estado, 'vigente', v_vigente,
                                   'updated_by', v_updated_by, 'updated_at', v_updated_at));

EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false, 'error_code', 'ERROR',
                              'message', 'No se pudo cambiar el estado del boletín: ' || SQLERRM);
END;
$function$;

ALTER FUNCTION core.fn_boletines_activar(bigint, boolean, bigint, varchar, varchar, inet, text, uuid) OWNER TO postgres;
COMMENT ON FUNCTION core.fn_boletines_activar(bigint, boolean, bigint, varchar, varchar, inet, text, uuid)
    IS 'Pone core.boletines.activo sin pasar por el formulario. Sin p_activo, alterna. Devuelve el estado recalculado.';
