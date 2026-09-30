-- FUNCTION: seguridad.fn_usuarios_eliminar(...)
--
-- ALINEADA AL ESTÁNDAR DE fn_usuarios_crear
--
-- 1. SIN «EXCEPTION WHEN OTHERS ... RETURN success:false».
--    Ese bloque retornaba normalmente tras un fallo, así que la transacción del
--    llamante seguía viva y era committeable: la integridad dependía de que PHP
--    mirase 'success'. Ahora todo error se propaga y PostgreSQL aborta.
--    Solo se captura foreign_key_violation, y para RE-LANZARLA con un mensaje
--    legible cuando otro módulo referencie al usuario.
-- 2. Reglas de negocio con RAISE EXCEPTION ... USING ERRCODE.
-- 3. SET search_path (obligatorio en SECURITY DEFINER con OWNER postgres).
-- 4. app.datos_anteriores se limpia tras el DELETE: set_config(..., true) dura
--    toda la transacción y no se limpiaba en el camino feliz, así que la
--    siguiente tabla auditada heredaba el JSON del usuario.
-- 5. La auditoría ya no guarda recovery_code.
--
-- CÓDIGOS DE ERROR
--   P0013 el usuario no existe
--   P0014 no se puede eliminar: tiene registros asociados

CREATE OR REPLACE FUNCTION seguridad.fn_usuarios_eliminar(
	p_id bigint,
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
    v_datos_anteriores JSONB;
    v_usuario_data RECORD;
BEGIN
    -- 1. Contexto de auditoría (lo leen los triggers de seguridad.users)
    PERFORM set_config('app.usuario_id', COALESCE(p_usuario_id::TEXT, ''), true);
    PERFORM set_config('app.usuario_login', COALESCE(p_usuario_login, current_user), true);
    PERFORM set_config('app.usuario_nombre', COALESCE(p_usuario_nombre, current_user), true);
    PERFORM set_config('app.ip_address', COALESCE(p_ip_address::TEXT, ''), true);
    PERFORM set_config('app.user_agent', COALESCE(p_user_agent, ''), true);
    PERFORM set_config('app.request_id', COALESCE(p_request_id::TEXT, ''), true);
    PERFORM set_config('app.modulo', 'seguridad.users', true);

    -- 2. Datos del usuario antes de eliminar (con perfil y horario)
    SELECT
        u.id, u.name, u.surname, u.email, u.phone, u.login_user, u.avatar,
        u.isactive, u.islogin, u.isreset, u.type_user, u.perfil_id, u.chorario_id,
        u.created_by, u.updated_by, u.created_at, u.updated_at,
        u.last_login_at, u.user_verified_at, u.email_verified_at,
        p.nombre as perfil_nombre,
        c.nombre as chorario_nombre
    INTO v_usuario_data
    FROM seguridad.users u
    LEFT JOIN seguridad.perfiles p ON p.id = u.perfil_id
    LEFT JOIN seguridad.chorarios c ON c.id = u.chorario_id
    WHERE u.id = p_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'El usuario no existe' USING ERRCODE = 'P0013';
    END IF;

    -- 3. Datos ANTERIORES para la auditoría.
    --    Deliberadamente sin password ni recovery_code.
    v_datos_anteriores := jsonb_build_object(
        'id', v_usuario_data.id,
        'name', v_usuario_data.name,
        'surname', v_usuario_data.surname,
        'email', v_usuario_data.email,
        'phone', v_usuario_data.phone,
        'login_user', v_usuario_data.login_user,
        'avatar', v_usuario_data.avatar,
        'type_user', v_usuario_data.type_user,
        'isactive', v_usuario_data.isactive,
        'islogin', v_usuario_data.islogin,
        'isreset', v_usuario_data.isreset,
        'perfil', jsonb_build_object('id', v_usuario_data.perfil_id, 'nombre', v_usuario_data.perfil_nombre),
        'chorario', jsonb_build_object('id', v_usuario_data.chorario_id, 'nombre', v_usuario_data.chorario_nombre),
        'created_by', v_usuario_data.created_by,
        'created_at', to_char(v_usuario_data.created_at, 'YYYY-MM-DD HH24:MI:SS'),
        'updated_by', v_usuario_data.updated_by,
        'updated_at', to_char(v_usuario_data.updated_at, 'YYYY-MM-DD HH24:MI:SS'),
        'last_login_at', to_char(v_usuario_data.last_login_at, 'YYYY-MM-DD HH24:MI:SS'),
        'user_verified_at', to_char(v_usuario_data.user_verified_at, 'YYYY-MM-DD HH24:MI:SS'),
        'email_verified_at', to_char(v_usuario_data.email_verified_at, 'YYYY-MM-DD HH24:MI:SS')
    );
    PERFORM set_config('app.datos_anteriores', v_datos_anteriores::TEXT, true);

    -- 4. Eliminar (seguridad.sesiones_activas cae por ON DELETE CASCADE)
    DELETE FROM seguridad.users WHERE id = p_id;

    -- 5. El trigger de auditoría ya disparó al cerrar el DELETE: soltamos el
    --    contexto para no contaminar lo que venga después en esta transacción.
    PERFORM set_config('app.datos_anteriores', '', true);

    RETURN jsonb_build_object(
        'success', true,
        'message', 'Usuario eliminado exitosamente',
        'data', v_datos_anteriores
    );

EXCEPTION
    -- Único caso capturado, y se RE-LANZA. Hoy la única FK hacia users es
    -- sesiones_activas (ON DELETE CASCADE), pero en cuanto otro esquema
    -- referencie al usuario conviene un mensaje de negocio en lugar del texto
    -- crudo del constraint. Nunca un «WHEN OTHERS».
    WHEN foreign_key_violation THEN
        RAISE EXCEPTION 'No se puede eliminar el usuario porque tiene registros asociados'
            USING ERRCODE = 'P0014';
END;
$BODY$;

ALTER FUNCTION seguridad.fn_usuarios_eliminar(bigint, bigint, character varying, character varying, inet, text, uuid)
    OWNER TO postgres;
