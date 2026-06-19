
-- ============================================
-- CREACIÓN DE ESQUEMA SEGURIDAD
-- ============================================
CREATE SCHEMA seguridad;



-- =========================
-- 1. TABLA MENUS
-- =========================
CREATE TABLE IF NOT EXISTS seguridad.menus (
    id BIGSERIAL NOT NULL,
    padre_id BIGINT NULL,
    orden INTEGER DEFAULT 0,
    nivel INTEGER DEFAULT 0,
    nombre VARCHAR(100) NOT NULL,
    url VARCHAR(255),
    descripcion VARCHAR(255),
    etiqueta VARCHAR(100),
    icono VARCHAR(50),    
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),
    created_by VARCHAR(100),
    updated_by VARCHAR(100),
	CONSTRAINT pk_menus PRIMARY KEY (id),
    CONSTRAINT fk_menus_padre FOREIGN KEY (padre_id) 
        REFERENCES seguridad.menus(id) MATCH SIMPLE
        ON UPDATE NO ACTION
        ON DELETE NO ACTION
);

-- Índices para mejorar rendimiento en consultas recursivas
CREATE INDEX idx_menus_padre_id ON seguridad.menus(padre_id);
CREATE INDEX idx_menus_nombre ON seguridad.menus(nombre);
CREATE INDEX idx_menus_padre_orden ON seguridad.menus(padre_id, orden);

-- Trigger para updated_at
CREATE TRIGGER trigger_menus_updated_at
    BEFORE UPDATE ON seguridad.menus
    FOR EACH ROW
    EXECUTE FUNCTION auditoria.fn_update_updated_at_column();
-- Trigger para created_by y updated_by
CREATE TRIGGER trigger_menus_set_users
    BEFORE INSERT OR UPDATE ON seguridad.menus
    FOR EACH ROW
    EXECUTE FUNCTION auditoria.fn_set_audit_users();
-- Auditoría para menus
CREATE TRIGGER trg_menus_audit
    AFTER INSERT OR UPDATE OR DELETE ON seguridad.menus
    FOR EACH ROW
    EXECUTE FUNCTION auditoria.fn_auditar_cambios();




-- =========================
-- 2. TABLA PERFILES
-- =========================
CREATE TABLE IF NOT EXISTS seguridad.perfiles
(
    id 			BIGSERIAL NOT NULL,
    nombre 		VARCHAR(100) NOT NULL,
    activo 		boolean DEFAULT true,
    inactividad integer DEFAULT 60,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),
    created_by VARCHAR(100),
    updated_by VARCHAR(100),    
    CONSTRAINT 	pk_perfiles PRIMARY KEY (id),
    CONSTRAINT 	uk_nombre_perfiles UNIQUE (nombre)
);
CREATE INDEX idx_perfiles_activo ON seguridad.perfiles(activo);
CREATE INDEX idx_perfiles_inactividad ON seguridad.perfiles(inactividad);

-- Trigger para updated_at
CREATE TRIGGER trigger_perfiles_updated_at
    BEFORE UPDATE ON seguridad.perfiles
    FOR EACH ROW
    EXECUTE FUNCTION auditoria.fn_update_updated_at_column();
-- Trigger para created_by y updated_by
CREATE TRIGGER trigger_perfiles_set_users
    BEFORE INSERT OR UPDATE ON seguridad.perfiles
    FOR EACH ROW
    EXECUTE FUNCTION auditoria.fn_set_audit_users();
-- Auditoría para perfiles
CREATE TRIGGER trg_perfiles_audit
    AFTER INSERT OR UPDATE OR DELETE ON seguridad.perfiles
    FOR EACH ROW
    EXECUTE FUNCTION auditoria.fn_auditar_cambios();








-- =========================
-- 3. TABLA ACCESOS
-- =========================
CREATE TABLE IF NOT EXISTS seguridad.accesos
(
    id 			BIGSERIAL NOT NULL,
    perfil_id 	BIGINT,
    menu_id 	BIGINT,
    ver 		boolean DEFAULT false,
    crear 		boolean DEFAULT false,
    editar 		boolean DEFAULT false,
    eliminar 	boolean DEFAULT false,
    listar 		boolean DEFAULT false,
    reporte 	boolean DEFAULT false,
    auditar 	boolean DEFAULT false,
    ejecutar 	boolean DEFAULT false,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),
    created_by VARCHAR(100),
    updated_by VARCHAR(100),  
    CONSTRAINT pk_accesos PRIMARY KEY (id),
    CONSTRAINT fk_accesos_menus FOREIGN KEY (menu_id)
        REFERENCES seguridad.menus (id) MATCH SIMPLE
        ON UPDATE NO ACTION
        ON DELETE NO ACTION,
    CONSTRAINT fk_accesos_perfiles FOREIGN KEY (perfil_id) 
        REFERENCES seguridad.perfiles (id) MATCH SIMPLE
        ON UPDATE NO ACTION
        ON DELETE NO ACTION,
    CONSTRAINT uk_accesos_perfiles_menus UNIQUE (perfil_id, menu_id)
);
CREATE INDEX idx_accesos_menu_id ON seguridad.accesos(menu_id);
CREATE INDEX idx_accesos_perfil_id ON seguridad.accesos(perfil_id);
CREATE INDEX idx_accesos_perfil_menu ON seguridad.accesos(perfil_id, menu_id);

-- Trigger para updated_at
CREATE TRIGGER trigger_accesos_updated_at
    BEFORE UPDATE ON seguridad.accesos
    FOR EACH ROW
    EXECUTE FUNCTION auditoria.fn_update_updated_at_column();
-- Trigger para created_by y updated_by
CREATE TRIGGER trigger_accesos_set_users
    BEFORE INSERT OR UPDATE ON seguridad.accesos
    FOR EACH ROW
    EXECUTE FUNCTION auditoria.fn_set_audit_users();
-- Auditoría para accesos
CREATE TRIGGER trg_accesos_audit
    AFTER INSERT OR UPDATE OR DELETE ON seguridad.accesos
    FOR EACH ROW
    EXECUTE FUNCTION auditoria.fn_auditar_cambios();






-- =========================
-- 4. TABLA CHORARIOS
-- =========================
CREATE TABLE IF NOT EXISTS seguridad.chorarios
(
    id 			BIGSERIAL NOT NULL,
    nombre 		VARCHAR(100) NOT NULL,
    activo 		boolean DEFAULT true,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),
    created_by VARCHAR(100),
    updated_by VARCHAR(100),  
    CONSTRAINT 	pk_chorarios PRIMARY KEY (id)
);
CREATE INDEX idx_chorarios_activo ON seguridad.chorarios(activo);

-- Trigger para updated_at
CREATE TRIGGER trigger_chorarios_updated_at
    BEFORE UPDATE ON seguridad.chorarios
    FOR EACH ROW
    EXECUTE FUNCTION auditoria.fn_update_updated_at_column();
-- Trigger para created_by y updated_by
CREATE TRIGGER trigger_chorarios_set_users
    BEFORE INSERT OR UPDATE ON seguridad.chorarios
    FOR EACH ROW
    EXECUTE FUNCTION auditoria.fn_set_audit_users();
-- Auditoría para chorarios
CREATE TRIGGER trg_chorarios_audit
    AFTER INSERT OR UPDATE OR DELETE ON seguridad.chorarios
    FOR EACH ROW
    EXECUTE FUNCTION auditoria.fn_auditar_cambios();




-- =========================
-- 5. TABLA DHORARIOS
-- =========================
CREATE TABLE IF NOT EXISTS seguridad.dhorarios
(
    id 			BIGSERIAL NOT NULL,
    chorario_id BIGINT NOT NULL,
    dia 		INTEGER NOT NULL CHECK (dia BETWEEN 1 AND 7),
    hora_inicio interval,
    hora_fin 	interval,
    activo 		BOOLEAN DEFAULT true,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),
    created_by VARCHAR(100),
    updated_by VARCHAR(100),  
    CONSTRAINT 	pk_dhorarios PRIMARY KEY (id),
    CONSTRAINT 	fk_dhorarios_chorarios FOREIGN KEY (chorario_id)
        REFERENCES seguridad.chorarios (id) MATCH SIMPLE
        ON UPDATE NO ACTION
        ON DELETE NO ACTION
);
CREATE INDEX idx_dhorarios_chorario_id ON seguridad.dhorarios(chorario_id);
CREATE INDEX idx_dhorarios_dia ON seguridad.dhorarios(dia);

-- Trigger para updated_at
CREATE TRIGGER trigger_dhorarios_updated_at
    BEFORE UPDATE ON seguridad.dhorarios
    FOR EACH ROW
    EXECUTE FUNCTION auditoria.fn_update_updated_at_column();
-- Trigger para created_by y updated_by
CREATE TRIGGER trigger_dhorarios_set_users
    BEFORE INSERT OR UPDATE ON seguridad.dhorarios
    FOR EACH ROW
    EXECUTE FUNCTION auditoria.fn_set_audit_users();
-- Auditoría para dhorarios
CREATE TRIGGER trg_dhorarios_audit
    AFTER INSERT OR UPDATE OR DELETE ON seguridad.dhorarios
    FOR EACH ROW
    EXECUTE FUNCTION auditoria.fn_auditar_cambios();





-- =========================
-- 1. TABLA USERS
-- =========================
CREATE TABLE IF NOT EXISTS seguridad.users
(
    id 			BIGSERIAL NOT NULL,
    login_user 	VARCHAR(30) NOT NULL,
    password 	VARCHAR(255) NOT NULL,
    name 		VARCHAR(100) NOT NULL,
    surname 	VARCHAR(100) NOT NULL,
    email 		VARCHAR(100) NOT NULL,
    phone 		VARCHAR(30) NOT NULL,
    avatar 		TEXT,
    type_user 	integer DEFAULT 1,
    isactive	boolean DEFAULT true,
    islogin 	boolean DEFAULT false,
    isreset 	boolean DEFAULT false,
    perfil_id 	BIGINT NOT NULL,
    chorario_id BIGINT NOT NULL,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),
    created_by VARCHAR(100),
    updated_by VARCHAR(100),  
    email_verified_at 	TIMESTAMPTZ DEFAULT NULL,
    user_verified_at 	TIMESTAMPTZ DEFAULT NULL,
    last_login_at TIMESTAMPTZ DEFAULT NULL,
    CONSTRAINT pk_users PRIMARY KEY (id),
    CONSTRAINT uk_users_login_user UNIQUE (login_user),
    CONSTRAINT fk_users_chorarios FOREIGN KEY (chorario_id)
        REFERENCES seguridad.chorarios (id) MATCH SIMPLE
        ON UPDATE NO ACTION
        ON DELETE NO ACTION,
    CONSTRAINT fk_users_perfiles FOREIGN KEY (perfil_id)
        REFERENCES seguridad.perfiles (id) MATCH SIMPLE
        ON UPDATE NO ACTION
        ON DELETE NO ACTION,
    CONSTRAINT uk_users_login_perfil UNIQUE (login_user, perfil_id)
);
CREATE INDEX idx_users_perfil_id ON seguridad.users(perfil_id);
CREATE INDEX idx_users_chorario_id ON seguridad.users(chorario_id);
CREATE INDEX idx_users_isactive ON seguridad.users(isactive) WHERE isactive = true;

-- Trigger para updated_at
CREATE TRIGGER trigger_users_updated_at
    BEFORE UPDATE ON seguridad.users
    FOR EACH ROW
    EXECUTE FUNCTION auditoria.fn_update_updated_at_column();
-- Trigger para created_by y updated_by
CREATE TRIGGER trigger_users_set_users
    BEFORE INSERT OR UPDATE ON seguridad.users
    FOR EACH ROW
    EXECUTE FUNCTION auditoria.fn_set_audit_users();
-- Auditoría para users
CREATE TRIGGER trg_users_audit
    AFTER INSERT OR UPDATE OR DELETE ON seguridad.users
    FOR EACH ROW
    EXECUTE FUNCTION auditoria.fn_auditar_cambios();

COMMENT ON COLUMN seguridad.users.id IS 'Identificador único del usuario (PK)';
COMMENT ON COLUMN seguridad.users.login_user IS 'Nombre de usuario para login (único)';
COMMENT ON COLUMN seguridad.users.password IS 'Contraseña encriptada del usuario';
COMMENT ON COLUMN seguridad.users.name IS 'Nombre propio del usuario';
COMMENT ON COLUMN seguridad.users.surname IS 'Apellido del usuario';
COMMENT ON COLUMN seguridad.users.email IS 'Correo electrónico del usuario';
COMMENT ON COLUMN seguridad.users.phone IS 'Número de teléfono del usuario';
COMMENT ON COLUMN seguridad.users.avatar IS 'URL o ruta de la imagen del avatar';
COMMENT ON COLUMN seguridad.users.type_user IS 'Tipo de usuario: USUARIO, ADMINISTRADOR, SUPERVISOR';
COMMENT ON COLUMN seguridad.users.isactive IS 'Indica si el usuario está activo';
COMMENT ON COLUMN seguridad.users.islogin IS 'Indica si el usuario está actualmente logueado';
COMMENT ON COLUMN seguridad.users.isreset IS 'Indica si el usuario debe resetear su contraseña';
COMMENT ON COLUMN seguridad.users.perfil_id IS 'Referencia al perfil de seguridad del usuario (FK)';
COMMENT ON COLUMN seguridad.users.chorario_id IS 'Referencia al horario asignado al usuario (FK)';
COMMENT ON COLUMN seguridad.users.created_at IS 'Fecha y hora de creación del registro';
COMMENT ON COLUMN seguridad.users.updated_at IS 'Fecha y hora de última actualización del registro';
COMMENT ON COLUMN seguridad.users.created_by IS 'Usuario que creó el registro';
COMMENT ON COLUMN seguridad.users.updated_by IS 'Usuario que actualizó el registro';
COMMENT ON COLUMN seguridad.users.email_verified_at IS 'Fecha de verificación del correo electrónico';
COMMENT ON COLUMN seguridad.users.user_verified_at IS 'Fecha de verificación del usuario';
COMMENT ON COLUMN seguridad.users.last_login_at IS 'Fecha de ultimo inicio de sesion';

ALTER TABLE seguridad.users 
ADD COLUMN IF NOT EXISTS recovery_code VARCHAR(10),
ADD COLUMN IF NOT EXISTS recovery_code_expires_at TIMESTAMP;
CREATE INDEX IF NOT EXISTS idx_users_recovery_code ON seguridad.users(recovery_code, recovery_code_expires_at);





-- Crear tabla de sesiones activas
CREATE TABLE IF NOT EXISTS seguridad.sesiones_activas (
    id BIGSERIAL PRIMARY KEY,
    user_id BIGINT NOT NULL REFERENCES seguridad.users(id) ON DELETE CASCADE,
    token_id VARCHAR(100) NOT NULL, -- jti (JWT ID) del token
    ip_address INET,
    user_agent TEXT,
    navegador VARCHAR(100),
    sistema_operativo VARCHAR(100),
    dispositivo VARCHAR(50),
    last_activity TIMESTAMPTZ DEFAULT NOW(),
    created_at TIMESTAMPTZ DEFAULT NOW(),
    is_active BOOLEAN DEFAULT true,
    CONSTRAINT uk_user_token UNIQUE (user_id, token_id)
);

-- Índices para búsquedas rápidas
CREATE INDEX idx_sesiones_user_id ON seguridad.sesiones_activas(user_id);
CREATE INDEX idx_sesiones_token_id ON seguridad.sesiones_activas(token_id);
CREATE INDEX idx_sesiones_last_activity ON seguridad.sesiones_activas(last_activity);
CREATE INDEX idx_sesiones_is_active ON seguridad.sesiones_activas(is_active);

-- Comentarios
COMMENT ON TABLE seguridad.sesiones_activas IS 'Control de sesiones activas de usuarios';
COMMENT ON COLUMN seguridad.sesiones_activas.token_id IS 'JWT ID (jti) del token';
COMMENT ON COLUMN seguridad.sesiones_activas.last_activity IS 'Última actividad del usuario';









CREATE OR REPLACE FUNCTION seguridad.fn_menus_crear(
	p_nombre character varying,
	p_url character varying DEFAULT NULL::character varying,
	p_descripcion character varying DEFAULT NULL::character varying,
	p_etiqueta character varying DEFAULT NULL::character varying,
	p_icono character varying DEFAULT NULL::character varying,
	p_orden integer DEFAULT 0,
	p_padre_id bigint DEFAULT NULL::bigint,
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
AS $BODY$
DECLARE
    v_menu_id BIGINT;
    v_nivel INTEGER;
    v_resultado JSONB;
BEGIN
    -- 1. Establecer contexto de auditoría
    PERFORM set_config('app.usuario_id', COALESCE(p_usuario_id::TEXT, ''), true);
    PERFORM set_config('app.usuario_login', COALESCE(p_usuario_login, current_user), true);
    PERFORM set_config('app.usuario_nombre', COALESCE(p_usuario_nombre, current_user), true);
    PERFORM set_config('app.ip_address', p_ip_address::TEXT, true);
    PERFORM set_config('app.user_agent', p_user_agent, true);
    PERFORM set_config('app.request_id', p_request_id::TEXT, true);
    PERFORM set_config('app.modulo', 'seguridad.menus', true);
    
    -- 2. Validaciones
    IF p_nombre IS NULL OR TRIM(p_nombre) = '' THEN
        RETURN jsonb_build_object('success', false, 'message', 'El nombre del menú es obligatorio', 'error_code', 'NOMBRE_REQUERIDO');
    END IF;
    
    -- 3. Verificar nombre único
    IF EXISTS (SELECT 1 FROM seguridad.menus WHERE nombre = TRIM(p_nombre)) THEN
        RETURN jsonb_build_object('success', false, 'message', 'Ya existe un menú con ese nombre', 'error_code', 'NOMBRE_DUPLICADO');
    END IF;
    
    -- 4. Verificar que el padre existe (si se proporcionó)
    IF p_padre_id IS NOT NULL THEN
        IF NOT EXISTS (SELECT 1 FROM seguridad.menus WHERE id = p_padre_id) THEN
            RETURN jsonb_build_object('success', false, 'message', 'El menú padre no existe', 'error_code', 'PADRE_NO_EXISTE');
        END IF;
        
        -- Calcular el nivel del menú (nivel del padre + 1)
        SELECT COALESCE(nivel, 0) + 1 INTO v_nivel
        FROM seguridad.menus WHERE id = p_padre_id;
    ELSE
        v_nivel := 0;
    END IF;
    
    -- 5. Insertar el menú
    INSERT INTO seguridad.menus (
        nombre, url, descripcion, etiqueta, icono, 
        orden, padre_id, nivel
    ) VALUES (
        TRIM(p_nombre), 
        p_url, 
        p_descripcion, 
        p_etiqueta, 
        p_icono, 
        COALESCE(p_orden, 0), 
        p_padre_id, 
        v_nivel
    )
    RETURNING id INTO v_menu_id;
    
    -- 6. Obtener el menú recién creado
    SELECT jsonb_build_object(
        'success', true,
        'message', 'Menú creado exitosamente',
        'data', jsonb_build_object(
            'id', m.id,
            'nombre', m.nombre,
            'url', m.url,
            'descripcion', m.descripcion,
            'etiqueta', m.etiqueta,
            'icono', m.icono,
            'orden', m.orden,
            'padre_id', m.padre_id,
            'nivel', m.nivel,
            'created_at', to_char(m.created_at, 'YYYY-MM-DD HH24:MI:SS'),
            'updated_at', to_char(m.updated_at, 'YYYY-MM-DD HH24:MI:SS'),
            'created_by', m.created_by,
            'updated_by', m.updated_by
        )
    ) INTO v_resultado
    FROM seguridad.menus m
    WHERE m.id = v_menu_id;
    
    RETURN v_resultado;
    
EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object(
            'success', false,
            'message', 'Error al crear menú: ' || SQLERRM,
            'error_code', SQLSTATE
        );
END;
$BODY$;

ALTER FUNCTION seguridad.fn_menus_crear(character varying, character varying, character varying, character varying, character varying, integer, bigint, bigint, character varying, character varying, inet, text, uuid)
    OWNER TO postgres;







    CREATE OR REPLACE FUNCTION seguridad.fn_menus_modificar(
	p_id bigint,
	p_nombre character varying,
	p_url character varying DEFAULT NULL::character varying,
	p_descripcion character varying DEFAULT NULL::character varying,
	p_etiqueta character varying DEFAULT NULL::character varying,
	p_icono character varying DEFAULT NULL::character varying,
	p_orden integer DEFAULT NULL::integer,
	p_padre_id bigint DEFAULT NULL::bigint,
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
AS $BODY$
DECLARE
    v_menu_existe BOOLEAN;
    v_padre_existe BOOLEAN;
    v_nivel INTEGER;
    v_padre_nivel INTEGER;
    v_resultado JSONB;
BEGIN
    -- 1. Establecer contexto de auditoría
    PERFORM set_config('app.usuario_id', COALESCE(p_usuario_id::TEXT, ''), true);
    PERFORM set_config('app.usuario_login', COALESCE(p_usuario_login, current_user), true);
    PERFORM set_config('app.usuario_nombre', COALESCE(p_usuario_nombre, current_user), true);
    PERFORM set_config('app.ip_address', p_ip_address::TEXT, true);
    PERFORM set_config('app.user_agent', p_user_agent, true);
    PERFORM set_config('app.request_id', p_request_id::TEXT, true);
    PERFORM set_config('app.modulo', 'seguridad.menus', true);
    
    -- 2. Validar que el menú existe
    SELECT EXISTS(SELECT 1 FROM seguridad.menus WHERE id = p_id) INTO v_menu_existe;
    IF NOT v_menu_existe THEN
        RETURN jsonb_build_object('success', false, 'message', 'El menú no existe', 'error_code', 'MENU_NO_EXISTE');
    END IF;
    
    -- 3. Validaciones básicas
    IF p_nombre IS NULL OR TRIM(p_nombre) = '' THEN
        RETURN jsonb_build_object('success', false, 'message', 'El nombre del menú es obligatorio', 'error_code', 'NOMBRE_REQUERIDO');
    END IF;
    
    -- 4. Verificar nombre único (excluyendo el propio menú)
    IF EXISTS (SELECT 1 FROM seguridad.menus WHERE nombre = TRIM(p_nombre) AND id != p_id) THEN
        RETURN jsonb_build_object('success', false, 'message', 'Ya existe otro menú con ese nombre', 'error_code', 'NOMBRE_DUPLICADO');
    END IF;
    
    -- 5. Validar que el padre existe (si se proporcionó y no es el mismo menú)
    IF p_padre_id IS NOT NULL THEN
        IF p_padre_id = p_id THEN
            RETURN jsonb_build_object('success', false, 'message', 'Un menú no puede ser padre de sí mismo', 'error_code', 'AUTOREFERENCIA');
        END IF;
        
        SELECT EXISTS(SELECT 1 FROM seguridad.menus WHERE id = p_padre_id) INTO v_padre_existe;
        IF NOT v_padre_existe THEN
            RETURN jsonb_build_object('success', false, 'message', 'El menú padre no existe', 'error_code', 'PADRE_NO_EXISTE');
        END IF;
        
        -- Calcular el nivel del padre
        SELECT nivel INTO v_padre_nivel FROM seguridad.menus WHERE id = p_padre_id;
        v_nivel := v_padre_nivel + 1;
    ELSE
        v_nivel := 0;
    END IF;
    
    -- 6. Actualizar el menú
    UPDATE seguridad.menus
    SET 
        nombre = TRIM(p_nombre),
        url = p_url,
        descripcion = p_descripcion,
        etiqueta = p_etiqueta,
        icono = p_icono,
        orden = COALESCE(p_orden, orden),
        padre_id = p_padre_id,
        nivel = v_nivel,
        updated_at = CURRENT_TIMESTAMP
    WHERE id = p_id;
    
    -- 7. Devolver el menú actualizado
    SELECT jsonb_build_object(
        'success', true,
        'message', 'Menú actualizado exitosamente',
        'data', jsonb_build_object(
            'id', m.id,
            'nombre', m.nombre,
            'url', m.url,
            'descripcion', m.descripcion,
            'etiqueta', m.etiqueta,
            'icono', m.icono,
            'orden', m.orden,
            'padre_id', m.padre_id,
            'nivel', m.nivel,
            'created_at', to_char(m.created_at, 'YYYY-MM-DD HH24:MI:SS'),
            'updated_at', to_char(m.updated_at, 'YYYY-MM-DD HH24:MI:SS'),
            'created_by', m.created_by,
            'updated_by', m.updated_by
        )
    ) INTO v_resultado
    FROM seguridad.menus m
    WHERE m.id = p_id;
    
    RETURN v_resultado;
    
EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object(
            'success', false,
            'message', 'Error al actualizar menú: ' || SQLERRM,
            'error_code', SQLSTATE
        );
END;
$BODY$;

ALTER FUNCTION seguridad.fn_menus_modificar(bigint, character varying, character varying, character varying, character varying, character varying, integer, bigint, bigint, character varying, character varying, inet, text, uuid)
    OWNER TO postgres;







CREATE OR REPLACE FUNCTION seguridad.fn_menus_eliminar(
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
AS $BODY$
DECLARE
    v_menu_existe BOOLEAN;
    v_tiene_hijos BOOLEAN;
    v_menu RECORD;
    v_resultado JSONB;
BEGIN
    -- 1. Establecer contexto de auditoría
    PERFORM set_config('app.usuario_id', COALESCE(p_usuario_id::TEXT, ''), true);
    PERFORM set_config('app.usuario_login', COALESCE(p_usuario_login, current_user), true);
    PERFORM set_config('app.usuario_nombre', COALESCE(p_usuario_nombre, current_user), true);
    PERFORM set_config('app.ip_address', p_ip_address::TEXT, true);
    PERFORM set_config('app.user_agent', p_user_agent, true);
    PERFORM set_config('app.request_id', p_request_id::TEXT, true);
    PERFORM set_config('app.modulo', 'seguridad.menus', true);
    
    -- 2. Validar que el menú existe y obtener sus datos
    SELECT id, nombre, padre_id, orden, nivel, url, descripcion, etiqueta, icono INTO v_menu
    FROM seguridad.menus WHERE id = p_id;
    
    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'message', 'El menú no existe', 'error_code', 'MENU_NO_EXISTE');
    END IF;
    
    -- 3. Verificar si el menú tiene hijos
    SELECT EXISTS(SELECT 1 FROM seguridad.menus WHERE padre_id = p_id) INTO v_tiene_hijos;
    IF v_tiene_hijos THEN
        RETURN jsonb_build_object('success', false, 'message', 'No se puede eliminar este menú porque tiene hijos.', 'error_code', 'TIENE_HIJOS');
    END IF;
    
    -- 4. Eliminar accesos asociados al menú
    DELETE FROM seguridad.accesos WHERE menu_id = p_id;
    
    -- 5. Eliminar el menú
    DELETE FROM seguridad.menus WHERE id = p_id;
    
    -- 6. Devolver respuesta exitosa con los datos eliminados
    RETURN jsonb_build_object(
        'success', true,
        'message', 'Menú eliminado exitosamente',
        'data', jsonb_build_object(
            'id', v_menu.id,
            'nombre', v_menu.nombre,
            'url', v_menu.url,
            'descripcion', v_menu.descripcion,
            'etiqueta', v_menu.etiqueta,
            'icono', v_menu.icono,
            'orden', v_menu.orden,
            'padre_id', v_menu.padre_id,
            'nivel', v_menu.nivel
        )
    );
    
EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object(
            'success', false,
            'message', 'Error al eliminar menú: ' || SQLERRM,
            'error_code', SQLSTATE
        );
END;
$BODY$;

ALTER FUNCTION seguridad.fn_menus_eliminar(bigint, bigint, character varying, character varying, inet, text, uuid)
    OWNER TO postgres;











CREATE OR REPLACE FUNCTION seguridad.fn_perfiles_crear(
	p_nombre character varying,
	p_inactividad integer,
	p_activo boolean,
	p_accesos jsonb,
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
AS $BODY$
DECLARE
    v_perfil_id BIGINT;
    v_acceso JSONB;
    v_resultado JSONB;
BEGIN
    -- 1. Establecer contexto de auditoría
    PERFORM set_config('app.usuario_id', COALESCE(p_usuario_id::TEXT, ''), true);
    PERFORM set_config('app.usuario_login', COALESCE(p_usuario_login, current_user), true);
    PERFORM set_config('app.usuario_nombre', COALESCE(p_usuario_nombre, current_user), true);
    PERFORM set_config('app.ip_address', p_ip_address::TEXT, true);
    PERFORM set_config('app.user_agent', p_user_agent, true);
    PERFORM set_config('app.request_id', p_request_id::TEXT, true);
    PERFORM set_config('app.modulo', 'seguridad.perfiles', true);
    
    -- PASAR LOS ACCESOS AL CONTEXTO PARA EL TRIGGER
    PERFORM set_config('app.accesos_nuevos', p_accesos::TEXT, true);
    
    -- 2. Validaciones
    IF p_nombre IS NULL OR TRIM(p_nombre) = '' THEN
        RETURN jsonb_build_object('success', false, 'message', 'El nombre del perfil es obligatorio', 'error_code', 'NOMBRE_REQUERIDO');
    END IF;
    
    IF p_inactividad IS NULL OR p_inactividad < 0 THEN
        RETURN jsonb_build_object('success', false, 'message', 'La inactividad debe ser un número no negativo', 'error_code', 'INACTIVIDAD_INVALIDA');
    END IF;
    
    IF p_accesos IS NULL OR jsonb_array_length(p_accesos) = 0 THEN
        RETURN jsonb_build_object('success', false, 'message', 'Debe especificar al menos un acceso', 'error_code', 'ACCESOS_VACIOS');
    END IF;
    
    -- 3. Verificar nombre único
    IF EXISTS (SELECT 1 FROM seguridad.perfiles WHERE nombre = TRIM(p_nombre)) THEN
        RETURN jsonb_build_object('success', false, 'message', 'Ya existe un perfil con ese nombre.', 'error_code', 'NOMBRE_DUPLICADO');
    END IF;
    
    -- 4. Verificar que todos los menu_id existan
    FOR v_acceso IN SELECT * FROM jsonb_array_elements(p_accesos) LOOP
        IF NOT EXISTS (SELECT 1 FROM seguridad.menus WHERE id = (v_acceso->>'menu_id')::BIGINT) THEN
            RETURN jsonb_build_object('success', false, 'message', 'El menu_id ' || (v_acceso->>'menu_id') || ' no existe', 'error_code', 'MENU_INEXISTENTE');
        END IF;
    END LOOP;
    
    -- 5. Insertar el perfil
    INSERT INTO seguridad.perfiles (nombre, inactividad, activo)
    VALUES (TRIM(p_nombre), p_inactividad, p_activo)
    RETURNING id INTO v_perfil_id;
    
    -- 6. Insertar los accesos (actualizar los perfil_id en los accesos del contexto)
    FOR v_acceso IN SELECT * FROM jsonb_array_elements(p_accesos) LOOP
        INSERT INTO seguridad.accesos (
            perfil_id, menu_id, ver, crear, editar, eliminar, listar, reporte, auditar, ejecutar
        ) VALUES (
            v_perfil_id,
            (v_acceso->>'menu_id')::BIGINT,
            COALESCE((v_acceso->>'ver')::BOOLEAN, false),
            COALESCE((v_acceso->>'crear')::BOOLEAN, false),
            COALESCE((v_acceso->>'editar')::BOOLEAN, false),
            COALESCE((v_acceso->>'eliminar')::BOOLEAN, false),
            COALESCE((v_acceso->>'listar')::BOOLEAN, false),
            COALESCE((v_acceso->>'reporte')::BOOLEAN, false),
            COALESCE((v_acceso->>'auditar')::BOOLEAN, false),
            COALESCE((v_acceso->>'ejecutar')::BOOLEAN, false)
        );
    END LOOP;
    
    -- 9. Devolver el perfil recién creado con sus accesos
    SELECT jsonb_build_object(
        'success', true,
        'message', 'Perfil creado exitosamente',
        'data', jsonb_build_object(
            'id', perf.id,
            'nombre', perf.nombre,
            'inactividad', perf.inactividad,
            'activo', perf.activo,
            'created_by', perf.created_by,
            'updated_by', perf.updated_by, 
            'created_at', to_char(perf.created_at, 'YYYY-MM-DD HH24:MI:SS'),
            'updated_at', to_char(perf.updated_at, 'YYYY-MM-DD HH24:MI:SS'),
            'acceso', COALESCE((
                SELECT jsonb_agg(
                    jsonb_build_object(
                        'id', a.id,
                        'perfil_id', a.perfil_id,
                        'menu_id', a.menu_id,
                        'ver', a.ver,
                        'crear', a.crear,
                        'editar', a.editar,
                        'eliminar', a.eliminar,
                        'listar', a.listar,
                        'reporte', a.reporte,
                        'ejecutar', a.ejecutar,
                        'auditar', a.auditar,
                        'menu', jsonb_build_object(
                            'id', m.id,
                            'padre_id', m.padre_id,
                            'orden', m.orden,
                            'nivel', m.nivel,
                            'nombre', m.nombre,
                            'url', m.url,
                            'descripcion', m.descripcion,
                            'etiqueta', m.etiqueta,
                            'icono', m.icono
                        )
                    )
                    ORDER BY m.orden ASC, m.id ASC
                )
                FROM seguridad.accesos a
                JOIN seguridad.menus m ON a.menu_id = m.id
                WHERE a.perfil_id = perf.id
            ), '[]'::jsonb)
        )
    ) INTO v_resultado
    FROM seguridad.perfiles perf
    WHERE perf.id = v_perfil_id;
    
    RETURN v_resultado;
    
EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object(
            'success', false,
            'message', 'Error al crear perfil: ' || SQLERRM,
            'error_code', SQLSTATE
        );
END;
$BODY$;












CREATE OR REPLACE FUNCTION seguridad.fn_perfiles_modificar(
	p_id bigint,
	p_nombre character varying,
	p_inactividad integer,
	p_activo boolean,
	p_accesos jsonb,
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
AS $BODY$
DECLARE
    v_acceso JSONB;
    v_perfil_existente RECORD;
    v_accesos_viejos JSONB;
BEGIN
    -- 1. Establecer contexto de auditoría
    PERFORM set_config('app.usuario_id', COALESCE(p_usuario_id::TEXT, ''), true);
    PERFORM set_config('app.usuario_login', COALESCE(p_usuario_login, current_user), true);
    PERFORM set_config('app.usuario_nombre', COALESCE(p_usuario_nombre, current_user), true);
    PERFORM set_config('app.ip_address', p_ip_address::TEXT, true);
    PERFORM set_config('app.user_agent', p_user_agent, true);
    PERFORM set_config('app.request_id', p_request_id::TEXT, true);
    PERFORM set_config('app.modulo', 'seguridad.perfiles', true);
    
    -- 2. Obtener los accesos ACTUALES (viejos) antes de modificar
    SELECT COALESCE(
        jsonb_agg(
            jsonb_build_object(
                'id', a.id,
                'menu_id', a.menu_id,
                'perfil_id', a.perfil_id,
                'ver', a.ver,
                'crear', a.crear,
                'editar', a.editar,
                'eliminar', a.eliminar,
                'listar', a.listar,
                'reporte', a.reporte,
                'ejecutar', a.ejecutar,
                'auditar', a.auditar
            )
            ORDER BY a.menu_id ASC
        ),
        '[]'::jsonb
    ) INTO v_accesos_viejos
    FROM seguridad.accesos a
    WHERE a.perfil_id = p_id;
    
    -- 3. Guardar los accesos viejos en el contexto para el trigger
    PERFORM set_config('app.accesos_viejos', v_accesos_viejos::TEXT, true);
    
    -- 4. Guardar los accesos nuevos en el contexto para el trigger
    PERFORM set_config('app.accesos_nuevos', p_accesos::TEXT, true);
    
    -- 5. Validaciones
    IF p_nombre IS NULL OR TRIM(p_nombre) = '' THEN
        RETURN jsonb_build_object('success', false, 'message', 'El nombre del perfil es obligatorio', 'error_code', 'NOMBRE_REQUERIDO');
    END IF;
    
    IF p_inactividad IS NULL OR p_inactividad < 0 THEN
        RETURN jsonb_build_object('success', false, 'message', 'La inactividad debe ser un número no negativo', 'error_code', 'INACTIVIDAD_INVALIDA');
    END IF;
    
    -- 6. Verificar que el perfil existe
    SELECT * INTO v_perfil_existente FROM seguridad.perfiles WHERE id = p_id;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'message', 'El perfil no existe', 'error_code', 'PERFIL_NO_EXISTE');
    END IF;
    
    -- 7. Verificar nombre único (excluyendo el perfil actual)
    IF EXISTS (SELECT 1 FROM seguridad.perfiles WHERE nombre = TRIM(p_nombre) AND id != p_id) THEN
        RETURN jsonb_build_object('success', false, 'message', 'Ya existe otro perfil con ese nombre.', 'error_code', 'NOMBRE_DUPLICADO');
    END IF;
    
    -- 8. Verificar que todos los menu_id existan
    IF p_accesos IS NOT NULL AND jsonb_array_length(p_accesos) > 0 THEN
        FOR v_acceso IN SELECT * FROM jsonb_array_elements(p_accesos) LOOP
            IF NOT EXISTS (SELECT 1 FROM seguridad.menus WHERE id = (v_acceso->>'menu_id')::BIGINT) THEN
                RETURN jsonb_build_object('success', false, 'message', 'El menu_id ' || (v_acceso->>'menu_id') || ' no existe', 'error_code', 'MENU_INEXISTENTE');
            END IF;
        END LOOP;
    END IF;
    
    -- 9. Actualizar el perfil
    UPDATE seguridad.perfiles 
    SET 
        nombre = TRIM(p_nombre),
        inactividad = p_inactividad,
        activo = p_activo,
        updated_at = CURRENT_TIMESTAMP
    WHERE id = p_id;
    
    -- 10. Actualizar accesos (borrar y crear nuevos)
    IF p_accesos IS NOT NULL THEN
        -- Eliminar accesos existentes
        DELETE FROM seguridad.accesos WHERE perfil_id = p_id;
        
        -- Insertar nuevos accesos
        FOR v_acceso IN SELECT * FROM jsonb_array_elements(p_accesos) LOOP
            INSERT INTO seguridad.accesos (
                perfil_id, menu_id, ver, crear, editar, eliminar, listar, reporte, auditar, ejecutar
            ) VALUES (
                p_id,
                (v_acceso->>'menu_id')::BIGINT,
                COALESCE((v_acceso->>'ver')::BOOLEAN, false),
                COALESCE((v_acceso->>'crear')::BOOLEAN, false),
                COALESCE((v_acceso->>'editar')::BOOLEAN, false),
                COALESCE((v_acceso->>'eliminar')::BOOLEAN, false),
                COALESCE((v_acceso->>'listar')::BOOLEAN, false),
                COALESCE((v_acceso->>'reporte')::BOOLEAN, false),
                COALESCE((v_acceso->>'auditar')::BOOLEAN, false),
                COALESCE((v_acceso->>'ejecutar')::BOOLEAN, false)
            );
        END LOOP;
    END IF;
    
    -- 11. Devolver el perfil actualizado
    RETURN jsonb_build_object(
        'success', true,
        'message', 'Perfil actualizado exitosamente',
        'data', jsonb_build_object(
            'id', perf.id,
            'nombre', perf.nombre,
            'inactividad', perf.inactividad,
            'activo', perf.activo,
            'created_by', perf.created_by,
            'updated_by', perf.updated_by, 
            'created_at', to_char(perf.created_at, 'YYYY-MM-DD HH24:MI:SS'),
            'updated_at', to_char(perf.updated_at, 'YYYY-MM-DD HH24:MI:SS'),
            'acceso', COALESCE((
                SELECT jsonb_agg(
                    jsonb_build_object(
                        'id', a.id,
                        'perfil_id', a.perfil_id,
                        'menu_id', a.menu_id,
                        'ver', a.ver,
                        'crear', a.crear,
                        'editar', a.editar,
                        'eliminar', a.eliminar,
                        'listar', a.listar,
                        'reporte', a.reporte,
                        'ejecutar', a.ejecutar,
                        'auditar', a.auditar,
                        'menu', jsonb_build_object(
                            'id', m.id,
                            'padre_id', m.padre_id,
                            'orden', m.orden,
                            'nivel', m.nivel,
                            'nombre', m.nombre,
                            'url', m.url,
                            'descripcion', m.descripcion,
                            'etiqueta', m.etiqueta,
                            'icono', m.icono
                        )
                    )
                    ORDER BY m.orden ASC, m.id ASC
                )
                FROM seguridad.accesos a
                JOIN seguridad.menus m ON a.menu_id = m.id
                WHERE a.perfil_id = perf.id
            ), '[]'::jsonb)
        )
    )
    FROM seguridad.perfiles perf
    WHERE perf.id = p_id;
    
EXCEPTION
    WHEN OTHERS THEN
        -- Limpiar contexto en caso de error
        PERFORM set_config('app.accesos_viejos', '', true);
        PERFORM set_config('app.accesos_nuevos', '', true);
        
        RETURN jsonb_build_object(
            'success', false,
            'message', 'Error al actualizar perfil: ' || SQLERRM,
            'error_code', SQLSTATE
        );
END;
$BODY$;












CREATE OR REPLACE FUNCTION seguridad.fn_perfiles_eliminar(
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
AS $BODY$
DECLARE
    v_datos_anteriores JSONB;
    v_accesos JSONB;
    v_perfil RECORD;
    v_resultado JSONB;
BEGIN
    -- 1. Establecer contexto de auditoría
    PERFORM set_config('app.usuario_id', COALESCE(p_usuario_id::TEXT, ''), true);
    PERFORM set_config('app.usuario_login', COALESCE(p_usuario_login, current_user), true);
    PERFORM set_config('app.usuario_nombre', COALESCE(p_usuario_nombre, current_user), true);
    PERFORM set_config('app.ip_address', p_ip_address::TEXT, true);
    PERFORM set_config('app.user_agent', p_user_agent, true);
    PERFORM set_config('app.request_id', p_request_id::TEXT, true);
    PERFORM set_config('app.modulo', 'seguridad.perfiles', true);
    
    -- 2. Obtener el perfil antes de eliminarlo
    SELECT id, nombre, inactividad, activo INTO v_perfil
    FROM seguridad.perfiles
    WHERE id = p_id;
    
    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'message', 'El perfil no existe', 'error_code', 'PERFIL_NO_EXISTE');
    END IF;
    
    -- 3. Obtener los accesos actuales (para auditoría y para el contexto)
    SELECT COALESCE(
        jsonb_agg(
            jsonb_build_object(
                'menu_id', a.menu_id,
                'ver', a.ver,
                'crear', a.crear,
                'editar', a.editar,
                'eliminar', a.eliminar,
                'listar', a.listar,
                'reporte', a.reporte,
                'ejecutar', a.ejecutar,
                'auditar', a.auditar
            ) ORDER BY a.menu_id
        ),
        '[]'::jsonb
    ) INTO v_accesos
    FROM seguridad.accesos a
    WHERE a.perfil_id = p_id;
    
    -- 4. Guardar los accesos viejos en el contexto para el trigger
    PERFORM set_config('app.accesos_viejos', v_accesos::TEXT, true);
    
    -- 5. Construir JSON de datos anteriores (mismo formato que en crear/modificar)
    v_datos_anteriores := jsonb_build_object(
        'id', v_perfil.id,
        'nombre', v_perfil.nombre,
        'inactividad', v_perfil.inactividad,
        'activo', v_perfil.activo,
        'acceso', v_accesos
    );
    
    -- 6. Eliminar accesos y perfil (todo dentro de la misma transacción)
    DELETE FROM seguridad.accesos WHERE perfil_id = p_id;
    DELETE FROM seguridad.perfiles WHERE id = p_id;
    
    -- 7. Devolver respuesta exitosa con los datos eliminados
    RETURN jsonb_build_object(
        'success', true,
        'message', 'Perfil eliminado exitosamente',
        'data', v_datos_anteriores
    );
    
EXCEPTION
    WHEN OTHERS THEN
        -- Limpiar contexto en caso de error
        PERFORM set_config('app.accesos_viejos', '', true);
        
        RETURN jsonb_build_object(
            'success', false,
            'message', 'Error al eliminar perfil: ' || SQLERRM,
            'error_code', SQLSTATE
        );
END;
$BODY$;












CREATE OR REPLACE FUNCTION seguridad.fn_perfiles_listar_paginado(
    p_page INTEGER DEFAULT 1,
    p_per_page INTEGER DEFAULT 15,
    p_search TEXT DEFAULT ''
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $BODY$
DECLARE
    v_offset INTEGER;
    v_total BIGINT;
    v_data JSONB;
    v_resultado JSONB;
BEGIN
    -- Calcular offset
    v_offset := (p_page - 1) * p_per_page;
    
    -- 1. Contar total con filtro
    IF p_search IS NOT NULL AND p_search != '' THEN
        SELECT COUNT(*) INTO v_total
        FROM seguridad.perfiles
        WHERE nombre ILIKE '%' || p_search || '%' 
           OR id::text ILIKE '%' || p_search || '%';
    ELSE
        SELECT COUNT(*) INTO v_total FROM seguridad.perfiles;
    END IF;
    
    -- 2. Consulta paginada
    IF p_search IS NOT NULL AND p_search != '' THEN
        SELECT COALESCE(
            jsonb_agg(
                jsonb_build_object(
                    'id', id,
                    'nombre', nombre,
                    'inactividad', inactividad,
                    'activo', activo,
                    'created_by', created_by,
                    'updated_by', updated_by,
                    'created_at', to_char(created_at, 'YYYY-MM-DD HH24:MI:SS'),
                    'updated_at', to_char(updated_at, 'YYYY-MM-DD HH24:MI:SS')
                )
                ORDER BY id DESC
            ), '[]'::jsonb
        ) INTO v_data
        FROM (
            SELECT id, nombre, inactividad, activo, created_by, updated_by, created_at, updated_at
            FROM seguridad.perfiles
            WHERE nombre ILIKE '%' || p_search || '%' 
               OR id::text ILIKE '%' || p_search || '%'
            ORDER BY id DESC
            LIMIT p_per_page OFFSET v_offset
        ) AS subquery;
    ELSE
        SELECT COALESCE(
            jsonb_agg(
                jsonb_build_object(
                    'id', id,
                    'nombre', nombre,
                    'inactividad', inactividad,
                    'activo', activo,
                    'created_by', created_by,
                    'updated_by', updated_by,
                    'created_at', to_char(created_at, 'YYYY-MM-DD HH24:MI:SS'),
                    'updated_at', to_char(updated_at, 'YYYY-MM-DD HH24:MI:SS')
                )
                ORDER BY id DESC
            ), '[]'::jsonb
        ) INTO v_data
        FROM (
            SELECT id, nombre, inactividad, activo, created_by, updated_by, created_at, updated_at
            FROM seguridad.perfiles
            ORDER BY id DESC
            LIMIT p_per_page OFFSET v_offset
        ) AS subquery;
    END IF;
    
    -- 3. Construir resultado
    v_resultado := jsonb_build_object(
        'data', v_data,
        'meta', jsonb_build_object(
            'total', v_total,
            'per_page', p_per_page,
            'current_page', p_page,
            'last_page', CASE WHEN v_total = 0 THEN 1 ELSE ceil(v_total::NUMERIC / p_per_page) END
        )
    );
    
    RETURN v_resultado;
    
EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object(
            'success', false,
            'message', 'Error al listar perfiles: ' || SQLERRM,
            'error_code', SQLSTATE
        );
END;
$BODY$;
















--------------------------INSERT--------------------------------------------------------------------------------    

-- =========================
-- 1. MENÚS RAÍZ
-- =========================
INSERT INTO seguridad.menus (padre_id, orden, nivel, nombre, url, descripcion, etiqueta, icono)
VALUES
(NULL,1,0,'Inicio','/home','Inicio - ',NULL,'fa fa-home'),
(NULL,2,0,'Reportes','reportes','Reportes','PowerBI','fa-regular fa-file'),
(NULL,3,0,'Demo','demo/home','demo - ','Novedades','fa-solid fa-wand-magic-sparkles'),
(NULL,10,0,'Configuracion','config/home','Configuracion - Inicio',NULL,'fa fa-cog');


-- =========================
-- 2. HIJOS DE CONFIGURACION
-- =========================
INSERT INTO seguridad.menus (padre_id, orden, nivel, nombre, url, descripcion, icono)
VALUES
((SELECT id FROM seguridad.menus WHERE nombre='Configuracion'),1,1,'🏷️ Menus','config/allMenus','Configuracion - ',NULL),
((SELECT id FROM seguridad.menus WHERE nombre='Configuracion'),2,1,'📍 Perfiles','config/allProfiles','Configuracion - Listado de Perfiles',NULL),
((SELECT id FROM seguridad.menus WHERE nombre='Configuracion'),3,1,'👨‍💼 Usuarios','config/allUsuarios','Configuracion - Listado de Usuarios','fa fa-user'),
((SELECT id FROM seguridad.menus WHERE nombre='Configuracion'),4,1,'🏦 Departamentos','config/allDepartamentos','Configuracion - Listado de departamento',NULL),
((SELECT id FROM seguridad.menus WHERE nombre='Configuracion'),5,1,'📈 Reportes Externos','reportes/allReportesExternos','Reportes Externos','.'),
((SELECT id FROM seguridad.menus WHERE nombre='Configuracion'),6,1,'🗂️ FileManager','config/filemanager','file',NULL),
((SELECT id FROM seguridad.menus WHERE nombre='Configuracion'),7,1,'📆 Horarios','config/allHorarios','Horarios','');


-- =========================
-- 3. HIJOS DE DEMO
-- =========================
INSERT INTO seguridad.menus (padre_id, orden, nivel, nombre, url, descripcion)
VALUES
((SELECT id FROM seguridad.menus WHERE nombre='Demo'),1,1,'📈 Dashboards','demo/home','demo - '),
((SELECT id FROM seguridad.menus WHERE nombre='Demo'),2,1,'⚙️ Forms','.',NULL),
((SELECT id FROM seguridad.menus WHERE nombre='Demo'),3,1,'🟠 Spinner','demo/spinner','demo -'),
((SELECT id FROM seguridad.menus WHERE nombre='Demo'),4,1,'WindowsExplorer','demo/WindowsExplorer','WindowsExplorer'),
((SELECT id FROM seguridad.menus WHERE nombre='Demo'),5,1,'Factura','demo/factura','Factura'),
((SELECT id FROM seguridad.menus WHERE nombre='Demo'),6,1,'UbicacionGps','demo/ubicaciongps','UbicacionGps'),
((SELECT id FROM seguridad.menus WHERE nombre='Demo'),7,1,'Detecta Rostro','demo/detectarostro','Detecta Rostro'),
((SELECT id FROM seguridad.menus WHERE nombre='Demo'),8,1,'Detecta IP','demo/detectaip','Detecta IP'),
((SELECT id FROM seguridad.menus WHERE nombre='Demo'),9,1,'📤 Importar Excel','demo/importarexcel','Importar Excel'),
((SELECT id FROM seguridad.menus WHERE nombre='Demo'),10,1,'websocketsend','demo/websocketsend','websocketsend'),
((SELECT id FROM seguridad.menus WHERE nombre='Demo'),11,1,'websocketrecived','demo/websocketrecived','websocketrecived'),
((SELECT id FROM seguridad.menus WHERE nombre='Demo'),12,1,'qr','demo/qr','qr');
-- =========================
-- 4. NIETOS (Forms)
-- =========================
INSERT INTO seguridad.menus (padre_id, orden, nivel, nombre, url, descripcion)
VALUES
((SELECT id FROM seguridad.menus WHERE nombre='📈 Dashboards'),1,2,'📰 Plantilla','demo/plantilla','demo - plantilla'),
((SELECT id FROM seguridad.menus WHERE nombre='⚙️ Forms'),2,2,'🛡️ Floating Label','demo/FormFloatingLabel','demo - ');
-- =========================
-- 5. NIETOS (Plantilla)
-- =========================
INSERT INTO seguridad.menus (padre_id, orden, nivel, nombre, url, descripcion)
VALUES
((SELECT id FROM seguridad.menus WHERE nombre='📰 Plantilla'),1,3,'📈 Dashboard1','demo/dashboard1','demo - plantilla'),
((SELECT id FROM seguridad.menus WHERE nombre='📰 Plantilla'),2,3,'📉 Dashboard2','demo/dashboard2','demo - plantilla'),
((SELECT id FROM seguridad.menus WHERE nombre='📰 Plantilla'),3,3,'📉 Dashboard3','demo/dashboard3','demo - plantilla');
-- =========================
-- 6. EXTRA CONFIGURACION
-- =========================
INSERT INTO seguridad.menus (padre_id, orden, nivel, nombre, url, descripcion)
VALUES
((SELECT id FROM seguridad.menus WHERE nombre='Configuracion'),8,1,'📈 Listado Reportes Externos','reportes/listUsuariosReportesExternos','Listado Reportes Externos');



-- =========================
-- 7. sql caso de uso
-- =========================
WITH RECURSIVE menu_tree AS (
    -- NODOS RAÍZ
    SELECT 
        id,
        padre_id,
        0 AS nivel,
        orden,
        nombre,
        nombre::TEXT AS nombre2,
        url,
        icono,
        LPAD(orden::text, 5, '0') AS path
    FROM seguridad.menus
    WHERE padre_id IS NULL

    UNION ALL

    -- HIJOS
    SELECT 
        m.id,
        m.padre_id,
        mt.nivel + 1,
        m.orden,
        m.nombre,
        (repeat('      ', mt.nivel + 1) || m.nombre)::TEXT AS nombre2,
        m.url,
        m.icono,
        mt.path || '.' || LPAD(m.orden::text, 5, '0')
    FROM seguridad.menus m
    INNER JOIN menu_tree mt ON m.padre_id = mt.id
)

SELECT *
FROM menu_tree
ORDER BY path;







-- =========================
-- perfiles
-- =========================
INSERT INTO seguridad.perfiles (nombre, activo, inactividad) 
VALUES ('SISTEMAS', true, 0);




-- =========================
-- chorarios
-- =========================
INSERT INTO seguridad.chorarios (nombre, activo) VALUES
('SISTEMAS', true),
('PRUEBA1', true);




-- =========================
-- users
-- =========================
INSERT INTO seguridad.users (login_user,"password","name",surname,email,phone,avatar,type_user,isactive,islogin,perfil_id,created_at,updated_at,email_verified_at,user_verified_at,isreset,chorario_id) VALUES
        ('LAGILA','$2y$12$DxOmV1a6NhNB8xyR8w./9OsOEzNuzbokMfG0haZrKgDigXVlqkG6e','LEONARDO PATRICIOOOOOO','AGILA ASTUDILLOOOOOO','leonardoagila@gmail.com','0987742070','1_userimg.jpg',1,true,true,1,'2025-03-02 10:33:56','2026-03-09 23:23:15',NULL,'2026-03-14 23:46:13',false,1),
        ('LAGILA_CLON','$2y$12$KPvCZ55A3D/ZcVwRa7acOOxIUj03vcl/IxG/LGsLmz.XklW/DNeEO','LEONARDO PATRICIO','AGILA ASTUDILLOPATRICI','leonardo.agila@almespana.com.ec','0987742070','57_userimg.jpg',1,false,false,1,'2025-05-25 20:49:25','2025-10-12 19:59:07',NULL,'2025-08-15 16:36:50',false,1),
        ('LEOLEO','$2y$12$yCg9N8JS1u7Fp1zGCK5qTeJ74PBO6KVAUSRsJE3AeTfvGXtZK8ad.','CC','FF','Cf@hhhh.com','6666','60_userimg.png',1,false,false,1,'2025-08-10 09:44:35','2025-10-10 19:28:59',NULL,NULL,false,1);







-- FUNCTION: seguridad.fn_menus_crear(character varying, character varying, character varying, character varying, character varying, integer, integer, bigint, character varying, character varying, inet, text, uuid)

CREATE OR REPLACE FUNCTION seguridad.fn_menus_crear(
    p_nombre VARCHAR(100),
    p_url VARCHAR(255) DEFAULT NULL,
    p_descripcion VARCHAR(255) DEFAULT NULL,
    p_etiqueta VARCHAR(100) DEFAULT NULL,
    p_icono VARCHAR(50) DEFAULT NULL,
    p_orden INTEGER DEFAULT 0,
    p_padre_id BIGINT DEFAULT NULL,
    p_usuario_id BIGINT DEFAULT NULL,
    p_usuario_login VARCHAR(100) DEFAULT NULL,
    p_usuario_nombre VARCHAR(200) DEFAULT NULL,
    p_ip_address INET DEFAULT NULL,
    p_user_agent TEXT DEFAULT NULL,
    p_request_id UUID DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $BODY$
DECLARE
    v_menu_id BIGINT;
    v_nivel INTEGER;
    v_resultado JSONB;
BEGIN
    -- 1. Establecer contexto de auditoría
    PERFORM set_config('app.usuario_id', COALESCE(p_usuario_id::TEXT, ''), true);
    PERFORM set_config('app.usuario_login', COALESCE(p_usuario_login, current_user), true);
    PERFORM set_config('app.usuario_nombre', COALESCE(p_usuario_nombre, current_user), true);
    PERFORM set_config('app.ip_address', p_ip_address::TEXT, true);
    PERFORM set_config('app.user_agent', p_user_agent, true);
    PERFORM set_config('app.request_id', p_request_id::TEXT, true);
    PERFORM set_config('app.modulo', 'seguridad.menus', true);
    
    -- 2. Validaciones
    IF p_nombre IS NULL OR TRIM(p_nombre) = '' THEN
        RETURN jsonb_build_object('success', false, 'message', 'El nombre del menú es obligatorio', 'error_code', 'NOMBRE_REQUERIDO');
    END IF;
    
    -- 3. Verificar nombre único (opcional, si quieres que el nombre sea único)
    IF EXISTS (SELECT 1 FROM seguridad.menus WHERE nombre = TRIM(p_nombre)) THEN
        RETURN jsonb_build_object('success', false, 'message', 'Ya existe un menú con ese nombre', 'error_code', 'NOMBRE_DUPLICADO');
    END IF;
    
    -- 4. Verificar que el padre existe (si se proporcionó)
    IF p_padre_id IS NOT NULL THEN
        IF NOT EXISTS (SELECT 1 FROM seguridad.menus WHERE id = p_padre_id) THEN
            RETURN jsonb_build_object('success', false, 'message', 'El menú padre no existe', 'error_code', 'PADRE_NO_EXISTE');
        END IF;
        
        -- 5. Calcular el nivel del menú (nivel del padre + 1)
        SELECT COALESCE(nivel, 0) + 1 INTO v_nivel
        FROM seguridad.menus WHERE id = p_padre_id;
    ELSE
        v_nivel := 0;
    END IF;
    
    -- 6. Insertar el menú
    INSERT INTO seguridad.menus (
        nombre, url, descripcion, etiqueta, icono, 
        orden, padre_id, nivel
    ) VALUES (
        TRIM(p_nombre), 
        p_url, 
        p_descripcion, 
        p_etiqueta, 
        p_icono, 
        COALESCE(p_orden, 0), 
        p_padre_id, 
        v_nivel
    )
    RETURNING id INTO v_menu_id;
    
    -- 7. Obtener el menú recién creado con todos sus datos
    SELECT jsonb_build_object(
        'success', true,
        'message', 'Menú creado exitosamente',
        'data', jsonb_build_object(
            'id', m.id,
            'nombre', m.nombre,
            'url', m.url,
            'descripcion', m.descripcion,
            'etiqueta', m.etiqueta,
            'icono', m.icono,
            'orden', m.orden,
            'padre_id', m.padre_id,
            'nivel', m.nivel,
            'created_at', to_char(m.created_at, 'YYYY-MM-DD HH24:MI:SS'),
            'updated_at', to_char(m.updated_at, 'YYYY-MM-DD HH24:MI:SS'),
            'created_by', m.created_by,
            'updated_by', m.updated_by
        )
    ) INTO v_resultado
    FROM seguridad.menus m
    WHERE m.id = v_menu_id;
    
    RETURN v_resultado;
    
EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object(
            'success', false,
            'message', 'Error al crear menú: ' || SQLERRM,
            'error_code', SQLSTATE
        );
END;
$BODY$;

ALTER FUNCTION seguridad.fn_menus_crear(VARCHAR, VARCHAR, VARCHAR, VARCHAR, VARCHAR, INTEGER, BIGINT, BIGINT, VARCHAR, VARCHAR, INET, TEXT, UUID) OWNER TO postgres;






CREATE OR REPLACE FUNCTION seguridad.fn_menus_modificar(
    p_id BIGINT,
    p_nombre VARCHAR(100),
    p_url VARCHAR(255) DEFAULT NULL,
    p_descripcion VARCHAR(255) DEFAULT NULL,
    p_etiqueta VARCHAR(100) DEFAULT NULL,
    p_icono VARCHAR(50) DEFAULT NULL,
    p_orden INTEGER DEFAULT NULL,
    p_padre_id BIGINT DEFAULT NULL,
    p_usuario_id BIGINT DEFAULT NULL,
    p_usuario_login VARCHAR(100) DEFAULT NULL,
    p_usuario_nombre VARCHAR(200) DEFAULT NULL,
    p_ip_address INET DEFAULT NULL,
    p_user_agent TEXT DEFAULT NULL,
    p_request_id UUID DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $BODY$
DECLARE
    v_menu_existe BOOLEAN;
    v_padre_existe BOOLEAN;
    v_nivel INTEGER;
    v_padre_nivel INTEGER;
    v_datos_anteriores JSONB;
    v_datos_nuevos JSONB;
    v_resultado JSONB;
BEGIN
    -- 1. Establecer contexto de auditoría
    PERFORM set_config('app.usuario_id', COALESCE(p_usuario_id::TEXT, ''), true);
    PERFORM set_config('app.usuario_login', COALESCE(p_usuario_login, current_user), true);
    PERFORM set_config('app.usuario_nombre', COALESCE(p_usuario_nombre, current_user), true);
    PERFORM set_config('app.ip_address', p_ip_address::TEXT, true);
    PERFORM set_config('app.user_agent', p_user_agent, true);
    PERFORM set_config('app.request_id', p_request_id::TEXT, true);
    PERFORM set_config('app.modulo', 'seguridad.menus', true);
    
    -- 2. Validar que el menú existe
    SELECT EXISTS(SELECT 1 FROM seguridad.menus WHERE id = p_id) INTO v_menu_existe;
    IF NOT v_menu_existe THEN
        RETURN jsonb_build_object('success', false, 'message', 'El menú no existe', 'error_code', 'MENU_NO_EXISTE');
    END IF;
    
    -- 3. Validaciones básicas
    IF p_nombre IS NULL OR TRIM(p_nombre) = '' THEN
        RETURN jsonb_build_object('success', false, 'message', 'El nombre del menú es obligatorio', 'error_code', 'NOMBRE_REQUERIDO');
    END IF;
    
    -- 4. Verificar nombre único (excluyendo el propio menú)
    IF EXISTS (SELECT 1 FROM seguridad.menus WHERE nombre = TRIM(p_nombre) AND id != p_id) THEN
        RETURN jsonb_build_object('success', false, 'message', 'Ya existe otro menú con ese nombre', 'error_code', 'NOMBRE_DUPLICADO');
    END IF;
    
    -- 5. Obtener datos anteriores para auditoría
    SELECT row_to_json(m) INTO v_datos_anteriores
    FROM (
        SELECT id, padre_id, orden, nivel, nombre, url, descripcion, etiqueta, icono
        FROM seguridad.menus WHERE id = p_id
    ) m;
    
    -- 6. Validar que el padre existe (si se proporcionó y no es el mismo menú)
    IF p_padre_id IS NOT NULL THEN
        IF p_padre_id = p_id THEN
            RETURN jsonb_build_object('success', false, 'message', 'Un menú no puede ser padre de sí mismo', 'error_code', 'AUTOREFERENCIA');
        END IF;
        
        SELECT EXISTS(SELECT 1 FROM seguridad.menus WHERE id = p_padre_id) INTO v_padre_existe;
        IF NOT v_padre_existe THEN
            RETURN jsonb_build_object('success', false, 'message', 'El menú padre no existe', 'error_code', 'PADRE_NO_EXISTE');
        END IF;
        
        -- Calcular el nivel del padre
        SELECT nivel INTO v_padre_nivel FROM seguridad.menus WHERE id = p_padre_id;
        v_nivel := v_padre_nivel + 1;
    ELSE
        v_nivel := 0;
    END IF;
    
    -- 7. Actualizar el menú
    UPDATE seguridad.menus
    SET 
        nombre = TRIM(p_nombre),
        url = p_url,
        descripcion = p_descripcion,
        etiqueta = p_etiqueta,
        icono = p_icono,
        orden = COALESCE(p_orden, orden),
        padre_id = p_padre_id,
        nivel = v_nivel
    WHERE id = p_id;
    
    -- 8. Obtener datos nuevos para auditoría
    SELECT row_to_json(m) INTO v_datos_nuevos
    FROM (
        SELECT id, padre_id, orden, nivel, nombre, url, descripcion, etiqueta, icono
        FROM seguridad.menus WHERE id = p_id
    ) m;
    
    -- 9. Devolver el menú actualizado
    SELECT jsonb_build_object(
        'success', true,
        'message', 'Menú actualizado exitosamente',
        'data', jsonb_build_object(
            'id', m.id,
            'nombre', m.nombre,
            'url', m.url,
            'descripcion', m.descripcion,
            'etiqueta', m.etiqueta,
            'icono', m.icono,
            'orden', m.orden,
            'padre_id', m.padre_id,
            'nivel', m.nivel,
            'created_at', to_char(m.created_at, 'YYYY-MM-DD HH24:MI:SS'),
            'updated_at', to_char(m.updated_at, 'YYYY-MM-DD HH24:MI:SS'),
            'created_by', m.created_by,
            'updated_by', m.updated_by
        )
    ) INTO v_resultado
    FROM seguridad.menus m
    WHERE m.id = p_id;
    
    RETURN v_resultado;
    
EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object(
            'success', false,
            'message', 'Error al actualizar menú: ' || SQLERRM,
            'error_code', SQLSTATE
        );
END;
$BODY$;

ALTER FUNCTION seguridad.fn_menus_modificar(BIGINT, VARCHAR, VARCHAR, VARCHAR, VARCHAR, VARCHAR, INTEGER, BIGINT, BIGINT, VARCHAR, VARCHAR, INET, TEXT, UUID) OWNER TO postgres;



CREATE OR REPLACE FUNCTION seguridad.fn_menus_eliminar(
    p_id BIGINT,
    p_usuario_id BIGINT DEFAULT NULL,
    p_usuario_login VARCHAR(100) DEFAULT NULL,
    p_usuario_nombre VARCHAR(200) DEFAULT NULL,
    p_ip_address INET DEFAULT NULL,
    p_user_agent TEXT DEFAULT NULL,
    p_request_id UUID DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $BODY$
DECLARE
    v_menu_existe BOOLEAN;
    v_tiene_hijos BOOLEAN;
    v_datos_anteriores JSONB;
    v_resultado JSONB;
BEGIN
    -- 1. Establecer contexto de auditoría
    PERFORM set_config('app.usuario_id', COALESCE(p_usuario_id::TEXT, ''), true);
    PERFORM set_config('app.usuario_login', COALESCE(p_usuario_login, current_user), true);
    PERFORM set_config('app.usuario_nombre', COALESCE(p_usuario_nombre, current_user), true);
    PERFORM set_config('app.ip_address', p_ip_address::TEXT, true);
    PERFORM set_config('app.user_agent', p_user_agent, true);
    PERFORM set_config('app.request_id', p_request_id::TEXT, true);
    PERFORM set_config('app.modulo', 'seguridad.menus', true);
    
    -- 2. Validar que el menú existe
    SELECT EXISTS(SELECT 1 FROM seguridad.menus WHERE id = p_id) INTO v_menu_existe;
    IF NOT v_menu_existe THEN
        RETURN jsonb_build_object('success', false, 'message', 'El menú no existe', 'error_code', 'MENU_NO_EXISTE');
    END IF;
    
    -- 3. Verificar si el menú tiene hijos
    SELECT EXISTS(SELECT 1 FROM seguridad.menus WHERE padre_id = p_id) INTO v_tiene_hijos;
    IF v_tiene_hijos THEN
        RETURN jsonb_build_object('success', false, 'message', 'No se puede eliminar este menú porque tiene hijos.', 'error_code', 'TIENE_HIJOS');
    END IF;
    
    -- 4. Obtener datos del menú antes de eliminar (para auditoría)
    SELECT row_to_json(m) INTO v_datos_anteriores
    FROM (
        SELECT id, padre_id, orden, nivel, nombre, url, descripcion, etiqueta, icono,
               created_at, updated_at, created_by, updated_by
        FROM seguridad.menus WHERE id = p_id
    ) m;
    
    -- 5. Eliminar accesos asociados al menú
    DELETE FROM seguridad.accesos WHERE menu_id = p_id;
    
    -- 6. Eliminar el menú
    DELETE FROM seguridad.menus WHERE id = p_id;
    
    -- 7. Devolver respuesta exitosa con los datos eliminados
    RETURN jsonb_build_object(
        'success', true,
        'message', 'Menú eliminado exitosamente',
        'data', v_datos_anteriores
    );
    
EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object(
            'success', false,
            'message', 'Error al eliminar menú: ' || SQLERRM,
            'error_code', SQLSTATE
        );
END;
$BODY$;

ALTER FUNCTION seguridad.fn_menus_eliminar(BIGINT, BIGINT, VARCHAR, VARCHAR, INET, TEXT, UUID) OWNER TO postgres;

CREATE OR REPLACE FUNCTION seguridad.fn_menus_listar()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $BODY$
DECLARE
    v_resultado JSONB;
BEGIN
    WITH RECURSIVE menu_tree AS (
        -- Nodos raíz (padre_id = NULL)
        SELECT 
            m.id,
            m.padre_id,
            m.orden,
            m.nivel,
            m.nombre,
            m.url,
            m.descripcion,
            m.etiqueta,
            m.icono,
            m.created_at,
            m.updated_at,
            m.created_by,
            m.updated_by,
            0 as nivel_hierarchy,
            LPAD(m.orden::text, 5, '0') as path
        FROM seguridad.menus m
        WHERE m.padre_id IS NULL
        
        UNION ALL
        
        -- Hijos recursivos
        SELECT 
            m.id,
            m.padre_id,
            m.orden,
            m.nivel,
            m.nombre,
            m.url,
            m.descripcion,
            m.etiqueta,
            m.icono,
            m.created_at,
            m.updated_at,
            m.created_by,
            m.updated_by,
            mt.nivel_hierarchy + 1,
            mt.path || '.' || LPAD(m.orden::text, 5, '0')
        FROM seguridad.menus m
        INNER JOIN menu_tree mt ON m.padre_id = mt.id
    )
    SELECT jsonb_build_object(
        'success', true,
        'message', 'Menús obtenidos exitosamente',
        'data', COALESCE((
            SELECT jsonb_agg(
                jsonb_build_object(
                    'id', id,
                    'padre_id', padre_id,
                    'orden', orden,
                    'nivel', nivel,
                    'nombre', nombre,
                    'url', url,
                    'descripcion', descripcion,
                    'etiqueta', etiqueta,
                    'icono', icono,
                    'created_at', to_char(created_at, 'YYYY-MM-DD HH24:MI:SS'),
                    'updated_at', to_char(updated_at, 'YYYY-MM-DD HH24:MI:SS'),
                    'created_by', created_by,
                    'updated_by', updated_by,
                    'nivel_hierarchy', nivel_hierarchy
                )
                ORDER BY path
            )
            FROM menu_tree
        ), '[]'::jsonb)
    ) INTO v_resultado;
    
    RETURN v_resultado;
    
EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object(
            'success', false,
            'message', 'Error al listar menús: ' || SQLERRM,
            'error_code', SQLSTATE
        );
END;
$BODY$;

ALTER FUNCTION seguridad.fn_menus_listar() OWNER TO postgres;

