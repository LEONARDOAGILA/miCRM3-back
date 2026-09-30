-- FUNCTION: seguridad.fn_usuarios_crear(...)
--
-- CAMBIOS RESPECTO A LA VERSIÓN ANTERIOR
--
-- 1. NUEVO PARÁMETRO p_type_user.
--    Antes el INSERT escribía «type_user = 1» a fuego, ignorando lo que
--    eligiera el operador: TODO usuario nacía como SUPER USUARIO. El parámetro
--    va en la misma posición que en fn_usuarios_modificar (tras p_isactive)
--    para que ambas funciones se lean igual.
--    Por defecto 4 (USUARIO WEB), el tipo de menor privilegio: si el llamante
--    no lo indica, la elección segura no es el superusuario.
--
-- 2. SIN «EXCEPTION WHEN OTHERS ... RETURN success:false».
--    Ese bloque devolvía normalmente tras un fallo, así que la transacción del
--    llamante quedaba viva y era committeable: la integridad dependía de que
--    PHP se acordara de mirar 'success'. Ahora todo error se propaga, PostgreSQL
--    aborta la transacción y el rollback está garantizado por la base de datos.
--    Sólo se captura unique_violation, y para RE-LANZARLA con mensaje legible.
--
-- 3. SET search_path.
--    Obligatorio en SECURITY DEFINER con OWNER postgres: sin fijarlo, la función
--    es un vector de escalación de privilegios.
--
-- 4. app.datos_nuevos SE LIMPIA JUSTO TRAS EL INSERT.
--    set_config(..., true) dura toda la transacción y no se limpiaba en el
--    camino feliz, así que la siguiente tabla auditada en la misma transacción
--    heredaba el JSON del usuario. El trigger AFTER ya disparó al terminar el
--    INSERT, de modo que limpiarlo aquí es seguro.
--
-- 5. VALIDACIÓN DE CAMPOS OBLIGATORIOS EN BD.
--    phone y chorario_id son NOT NULL en seguridad.users pero la función los
--    aceptaba NULL: el fallo salía como «null value in column ... violates
--    not-null constraint». Ahora dan un mensaje de negocio.
--
-- CÓDIGOS DE ERROR (SQLSTATE)
--   P0001 nombre obligatorio        P0006 login duplicado
--   P0002 apellido obligatorio      P0007 email duplicado
--   P0003 login obligatorio         P0008 perfil inexistente
--   P0004 email obligatorio         P0009 horario inexistente
--   P0005 contraseña obligatoria    P0010 tipo de usuario inválido
--   P0011 teléfono obligatorio      P0012 horario obligatorio

-- La firma cambia (entra p_type_user), así que hay que soltar la anterior o
-- quedarían dos sobrecargas y las llamadas de 16 argumentos serían ambiguas.
DROP FUNCTION IF EXISTS seguridad.fn_usuarios_crear(
    character varying, character varying, character varying, character varying,
    character varying, character varying, character varying, boolean,
    integer, integer, bigint, character varying, character varying,
    inet, text, uuid);

CREATE OR REPLACE FUNCTION seguridad.fn_usuarios_crear(
	p_name character varying,
	p_surname character varying,
	p_email character varying,
	p_phone character varying DEFAULT NULL::character varying,
	p_login_user character varying DEFAULT NULL::character varying,
	p_password character varying DEFAULT NULL::character varying,
	p_avatar character varying DEFAULT NULL::character varying,
	p_isactive boolean DEFAULT true,
	p_type_user integer DEFAULT 4,
	p_perfil_id integer DEFAULT 1,
	p_chorario_id integer DEFAULT NULL::integer,
	p_usuario_id bigint DEFAULT NULL::bigint,
	p_usuario_login character varying DEFAULT NULL::character varying,
	p_usuario_nombre character varying DEFAULT NULL::character varying,
	p_ip_address inet DEFAULT NULL::inet,
	p_user_agent text DEFAULT NULL::text,
	p_request_id uuid DEFAULT NULL::uuid)
    RETURNS jsonb
    LANGUAGE 'plpgsql'
    COST 100
    VOLATILE SECURITY DEFINER PARALLEL UNSAFE
    SET search_path = pg_catalog, seguridad, auditoria
AS $BODY$
DECLARE
    v_user_id BIGINT;
    v_resultado JSONB;
    v_datos_nuevos JSONB;
    v_fecha_actual TIMESTAMPTZ;
    v_perfil_data RECORD;
    v_chorario_data RECORD;
    v_usuario_creado RECORD;
    v_type_user INTEGER;
BEGIN
    -- 1. Fecha única para todo el registro
    v_fecha_actual := CURRENT_TIMESTAMP;

    -- 2. Contexto de auditoría (lo leen los triggers de seguridad.users)
    PERFORM set_config('app.usuario_id', COALESCE(p_usuario_id::TEXT, ''), true);
    PERFORM set_config('app.usuario_login', COALESCE(p_usuario_login, current_user), true);
    PERFORM set_config('app.usuario_nombre', COALESCE(p_usuario_nombre, current_user), true);
    PERFORM set_config('app.ip_address', COALESCE(p_ip_address::TEXT, ''), true);
    PERFORM set_config('app.user_agent', COALESCE(p_user_agent, ''), true);
    PERFORM set_config('app.request_id', COALESCE(p_request_id::TEXT, ''), true);
    PERFORM set_config('app.modulo', 'seguridad.users', true);

    -- 3. Campos obligatorios
    IF p_name IS NULL OR TRIM(p_name) = '' THEN
        RAISE EXCEPTION 'El nombre es obligatorio' USING ERRCODE = 'P0001';
    END IF;

    IF p_surname IS NULL OR TRIM(p_surname) = '' THEN
        RAISE EXCEPTION 'El apellido es obligatorio' USING ERRCODE = 'P0002';
    END IF;

    IF p_login_user IS NULL OR TRIM(p_login_user) = '' THEN
        RAISE EXCEPTION 'El login de usuario es obligatorio' USING ERRCODE = 'P0003';
    END IF;

    IF p_email IS NULL OR TRIM(p_email) = '' THEN
        RAISE EXCEPTION 'El email es obligatorio' USING ERRCODE = 'P0004';
    END IF;

    IF p_password IS NULL OR TRIM(p_password) = '' THEN
        RAISE EXCEPTION 'La contraseña es obligatoria' USING ERRCODE = 'P0005';
    END IF;

    -- phone es NOT NULL en la tabla: mejor un mensaje de negocio que el del constraint
    IF p_phone IS NULL OR TRIM(p_phone) = '' THEN
        RAISE EXCEPTION 'El teléfono es obligatorio' USING ERRCODE = 'P0011';
    END IF;

    -- chorario_id también es NOT NULL, y sin horario el middleware deniega el acceso
    IF p_chorario_id IS NULL THEN
        RAISE EXCEPTION 'Debe asignar un horario al usuario' USING ERRCODE = 'P0012';
    END IF;

    -- 4. Tipo de usuario: 1 SUPER USUARIO, 2 ADMINISTRADOR, 3 USUARIO SISTEMA, 4 USUARIO WEB
    v_type_user := COALESCE(p_type_user, 4);
    IF v_type_user NOT IN (1, 2, 3, 4) THEN
        RAISE EXCEPTION 'El tipo de usuario % no es válido', v_type_user USING ERRCODE = 'P0010';
    END IF;

    -- 5. Login único.
    --    Esta comprobación es sólo para dar un mensaje claro; quien garantiza la
    --    unicidad es el índice, y por eso unique_violation se maneja más abajo.
    IF EXISTS (SELECT 1 FROM seguridad.users WHERE login_user = TRIM(p_login_user)) THEN
        RAISE EXCEPTION 'Ya existe un usuario con ese login' USING ERRCODE = 'P0006';
    END IF;

    -- 6. Email único
    IF EXISTS (SELECT 1 FROM seguridad.users WHERE email = TRIM(p_email)) THEN
        RAISE EXCEPTION 'Ya existe un usuario con ese email' USING ERRCODE = 'P0007';
    END IF;

    -- 7. El perfil debe existir (también cuando se usa el valor por defecto)
    SELECT id, nombre INTO v_perfil_data
    FROM seguridad.perfiles
    WHERE id = COALESCE(p_perfil_id, 1);

    IF NOT FOUND THEN
        RAISE EXCEPTION 'El perfil % no existe', COALESCE(p_perfil_id, 1) USING ERRCODE = 'P0008';
    END IF;

    -- 8. El horario debe existir
    SELECT id, nombre INTO v_chorario_data
    FROM seguridad.chorarios
    WHERE id = p_chorario_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'El horario % no existe', p_chorario_id USING ERRCODE = 'P0009';
    END IF;

    -- 9. Datos NUEVOS para la auditoría.
    --    Se construye ANTES del INSERT porque el trigger AFTER lo lee del
    --    contexto. Deliberadamente NO incluye password ni recovery_code.
    v_datos_nuevos := jsonb_build_object(
        'name', TRIM(p_name),
        'surname', TRIM(p_surname),
        'email', TRIM(p_email),
        'phone', TRIM(p_phone),
        'login_user', TRIM(p_login_user),
        'avatar', p_avatar,
        'type_user', v_type_user,
        'isactive', COALESCE(p_isactive, true),
        'islogin', false,
        'isreset', false,
        'perfil', jsonb_build_object('id', v_perfil_data.id, 'nombre', v_perfil_data.nombre),
        'chorario', jsonb_build_object('id', v_chorario_data.id, 'nombre', v_chorario_data.nombre),
        'created_by', p_usuario_login,
        'created_at', to_char(v_fecha_actual, 'YYYY-MM-DD HH24:MI:SS'),
        'updated_by', p_usuario_login,
        'updated_at', to_char(v_fecha_actual, 'YYYY-MM-DD HH24:MI:SS')
    );
    PERFORM set_config('app.datos_nuevos', v_datos_nuevos::TEXT, true);

    -- 10. Insertar usuario
    INSERT INTO seguridad.users (
        name, surname, email, phone, login_user, password, avatar,
        type_user, isactive, islogin, perfil_id, chorario_id,
        created_by, updated_by, created_at, updated_at
    ) VALUES (
        TRIM(p_name),
        TRIM(p_surname),
        TRIM(p_email),
        TRIM(p_phone),
        TRIM(p_login_user),
        p_password,
        p_avatar,
        v_type_user,
        COALESCE(p_isactive, true),
        false,
        v_perfil_data.id,
        v_chorario_data.id,
        p_usuario_login,
        p_usuario_login,
        v_fecha_actual,
        v_fecha_actual
    )
    RETURNING id INTO v_user_id;

    -- 11. El trigger de auditoría ya disparó al cerrar el INSERT: soltamos el
    --     contexto para no contaminar lo que venga después en esta transacción.
    PERFORM set_config('app.datos_nuevos', '', true);

    -- 12. Devolver el usuario recién creado (sin password ni recovery_code)
    SELECT jsonb_build_object(
        'success', true,
        'message', 'Usuario creado exitosamente',
        'data', jsonb_build_object(
            'id', u.id,
            'name', u.name,
            'surname', u.surname,
            'email', u.email,
            'phone', u.phone,
            'login_user', u.login_user,
            'avatar', u.avatar,
            'type_user', u.type_user,
            'isactive', u.isactive,
            'islogin', u.islogin,
            'isreset', u.isreset,
            'perfil_id', u.perfil_id,
            'perfil_nombre', p.nombre,
            'chorario_id', u.chorario_id,
            'chorario_nombre', h.nombre,
            'perfil', jsonb_build_object('id', p.id, 'nombre', p.nombre),
            'chorario', jsonb_build_object('id', h.id, 'nombre', h.nombre),
            'created_by', u.created_by,
            'created_at', to_char(u.created_at, 'YYYY-MM-DD HH24:MI:SS'),
            'updated_by', u.updated_by,
            'updated_at', to_char(u.updated_at, 'YYYY-MM-DD HH24:MI:SS'),
            'last_login_at', to_char(u.last_login_at, 'YYYY-MM-DD HH24:MI:SS'),
            'user_verified_at', to_char(u.user_verified_at, 'YYYY-MM-DD HH24:MI:SS'),
            'email_verified_at', to_char(u.email_verified_at, 'YYYY-MM-DD HH24:MI:SS')
        )
    ) INTO v_resultado
    FROM seguridad.users u
    LEFT JOIN seguridad.perfiles p ON p.id = u.perfil_id
    LEFT JOIN seguridad.chorarios h ON h.id = u.chorario_id
    WHERE u.id = v_user_id;

    RETURN v_resultado;

EXCEPTION
    -- Único caso capturado, y se RE-LANZA: las comprobaciones EXISTS de arriba
    -- pueden perder la carrera contra otra petición simultánea. Aquí manda el
    -- índice único; lo único que hacemos es traducir el mensaje.
    -- Nunca un «WHEN OTHERS»: cualquier otro error debe abortar la transacción.
    WHEN unique_violation THEN
        RAISE EXCEPTION 'Ya existe un usuario con ese login o email'
            USING ERRCODE = 'P0006';
END;
$BODY$;

ALTER FUNCTION seguridad.fn_usuarios_crear(
    character varying, character varying, character varying, character varying,
    character varying, character varying, character varying, boolean,
    integer, integer, integer, bigint, character varying, character varying,
    inet, text, uuid)
    OWNER TO postgres;
