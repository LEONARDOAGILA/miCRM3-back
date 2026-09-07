-- FUNCTION: seguridad.fn_usuarios_cambiar_password(...)
--
-- ALINEADA AL ESTÁNDAR DE fn_usuarios_crear
--
-- 1. SIN «EXCEPTION WHEN OTHERS ... RETURN success:false»: el error se propaga
--    y PostgreSQL aborta la transacción. El rollback lo garantiza la base.
-- 2. Reglas de negocio con RAISE EXCEPTION ... USING ERRCODE.
-- 3. SET search_path (obligatorio en SECURITY DEFINER con OWNER postgres).
-- 4. app.datos_* se limpia tras el UPDATE, no solo en la rama de error.
-- 5. La auditoría no guarda password (ya era así) ni recovery_code (nuevo).
--
-- NOTA: p_password llega YA cifrada desde Laravel (bcrypt). Esta función no
-- cifra nada; si alguien la llama a mano debe pasar el hash, no el texto.
--
-- CÓDIGOS DE ERROR
--   P0005 la contraseña es obligatoria
--   P0013 el usuario no existe

CREATE OR REPLACE FUNCTION seguridad.fn_usuarios_cambiar_password(
	p_id bigint,
	p_password character varying,
	p_isreset boolean DEFAULT false,
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
    v_resultado JSONB;
    v_datos_anteriores JSONB;
    v_datos_nuevos JSONB;
    v_usuario_actual RECORD;
    v_fecha_actual TIMESTAMPTZ;
    v_isreset BOOLEAN;
BEGIN
    v_fecha_actual := CURRENT_TIMESTAMP;

    -- 1. Contexto de auditoría
    PERFORM set_config('app.usuario_id', COALESCE(p_usuario_id::TEXT, ''), true);
    PERFORM set_config('app.usuario_login', COALESCE(p_usuario_login, current_user), true);
    PERFORM set_config('app.usuario_nombre', COALESCE(p_usuario_nombre, current_user), true);
    PERFORM set_config('app.ip_address', COALESCE(p_ip_address::TEXT, ''), true);
    PERFORM set_config('app.user_agent', COALESCE(p_user_agent, ''), true);
    PERFORM set_config('app.request_id', COALESCE(p_request_id::TEXT, ''), true);
    PERFORM set_config('app.modulo', 'seguridad.users', true);

    -- 2. Validar contraseña
    IF p_password IS NULL OR TRIM(p_password) = '' THEN
        RAISE EXCEPTION 'La contraseña es obligatoria' USING ERRCODE = 'P0005';
    END IF;

    -- 3. Datos ACTUALES del usuario
    SELECT
        u.id, u.name, u.surname, u.email, u.phone, u.login_user, u.avatar,
        u.isactive, u.islogin, u.isreset, u.type_user, u.perfil_id, u.chorario_id,
        u.created_by, u.updated_by, u.created_at, u.updated_at,
        u.last_login_at, u.user_verified_at, u.email_verified_at,
        p.nombre as perfil_nombre,
        c.nombre as chorario_nombre
    INTO v_usuario_actual
    FROM seguridad.users u
    LEFT JOIN seguridad.perfiles p ON p.id = u.perfil_id
    LEFT JOIN seguridad.chorarios c ON c.id = u.chorario_id
    WHERE u.id = p_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'El usuario no existe' USING ERRCODE = 'P0013';
    END IF;

    v_isreset := COALESCE(p_isreset, v_usuario_actual.isreset);

    -- 4. Datos ANTERIORES para la auditoría (sin password ni recovery_code)
    v_datos_anteriores := jsonb_build_object(
        'id', v_usuario_actual.id,
        'login_user', v_usuario_actual.login_user,
        'name', v_usuario_actual.name,
        'surname', v_usuario_actual.surname,
        'email', v_usuario_actual.email,
        'isactive', v_usuario_actual.isactive,
        'isreset', v_usuario_actual.isreset,
        'perfil', jsonb_build_object('id', v_usuario_actual.perfil_id, 'nombre', v_usuario_actual.perfil_nombre),
        'chorario', jsonb_build_object('id', v_usuario_actual.chorario_id, 'nombre', v_usuario_actual.chorario_nombre),
        'updated_by', v_usuario_actual.updated_by,
        'updated_at', to_char(v_usuario_actual.updated_at, 'YYYY-MM-DD HH24:MI:SS'),
        'password_changed', false
    );
    PERFORM set_config('app.datos_anteriores', v_datos_anteriores::TEXT, true);

    -- 5. Datos NUEVOS. Se registra QUE cambió la contraseña, nunca su valor:
    --    el hash quedaría almacenado en la auditoría y es consultable desde la
    --    aplicación.
    v_datos_nuevos := jsonb_build_object(
        'id', v_usuario_actual.id,
        'login_user', v_usuario_actual.login_user,
        'name', v_usuario_actual.name,
        'surname', v_usuario_actual.surname,
        'email', v_usuario_actual.email,
        'isactive', v_usuario_actual.isactive,
        'isreset', v_isreset,
        'perfil', jsonb_build_object('id', v_usuario_actual.perfil_id, 'nombre', v_usuario_actual.perfil_nombre),
        'chorario', jsonb_build_object('id', v_usuario_actual.chorario_id, 'nombre', v_usuario_actual.chorario_nombre),
        'updated_by', COALESCE(p_usuario_login, v_usuario_actual.login_user),
        'updated_at', to_char(v_fecha_actual, 'YYYY-MM-DD HH24:MI:SS'),
        'password_changed', true
    );
    PERFORM set_config('app.datos_nuevos', v_datos_nuevos::TEXT, true);

    -- 6. Actualizar contraseña e isreset
    UPDATE seguridad.users
    SET
        password = p_password,
        isreset = v_isreset,
        updated_at = v_fecha_actual,
        updated_by = COALESCE(p_usuario_login, v_usuario_actual.login_user)
    WHERE id = p_id;

    -- 7. El trigger ya disparó al cerrar el UPDATE: soltamos el contexto para no
    --    contaminar lo que venga después en esta transacción.
    PERFORM set_config('app.datos_anteriores', '', true);
    PERFORM set_config('app.datos_nuevos', '', true);

    -- 8. Devolver el usuario actualizado (sin password ni recovery_code)
    SELECT jsonb_build_object(
        'success', true,
        'message', 'Contraseña actualizada exitosamente',
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
            'password_changed', true
        )
    ) INTO v_resultado
    FROM seguridad.users u
    LEFT JOIN seguridad.perfiles p ON p.id = u.perfil_id
    LEFT JOIN seguridad.chorarios h ON h.id = u.chorario_id
    WHERE u.id = p_id;

    RETURN v_resultado;
END;
$BODY$;

ALTER FUNCTION seguridad.fn_usuarios_cambiar_password(bigint, character varying, boolean, bigint, character varying, character varying, inet, text, uuid)
    OWNER TO postgres;
