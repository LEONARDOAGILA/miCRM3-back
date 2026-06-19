-- ============================================
-- CREACIÓN DE ESQUEMA RECURSOS HUMANOS
-- ============================================
CREATE SCHEMA IF NOT EXISTS rh;


-- TABLA: rh.cargos
CREATE TABLE IF NOT EXISTS rh.cargos (
    id BIGSERIAL NOT NULL,
    nombre VARCHAR(100) NOT NULL,
    descripcion TEXT,
    nivel VARCHAR(50),
    salario_base DECIMAL(12,2),
    activo BOOLEAN DEFAULT true,
    created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    created_by VARCHAR(100),
    updated_by VARCHAR(100),
    CONSTRAINT pk_cargos PRIMARY KEY (id),
    CONSTRAINT uk_cargos_nombre UNIQUE (nombre),
    CONSTRAINT ck_cargos_nombre_min CHECK (LENGTH(TRIM(nombre)) >= 3),
    CONSTRAINT ck_cargos_salario_base CHECK (salario_base IS NULL OR salario_base >= 0)
);
-- Índices para cargos
CREATE INDEX idx_cargos_activo ON rh.cargos(activo) WHERE activo = true;
CREATE INDEX idx_cargos_nivel ON rh.cargos(nivel);
-- Trigger para updated_at
CREATE TRIGGER trigger_cargos_updated_at
    BEFORE UPDATE ON rh.cargos
    FOR EACH ROW
    EXECUTE FUNCTION auditoria.fn_update_updated_at_column();
-- Trigger para created_by y updated_by
CREATE TRIGGER trigger_cargos_set_users
    BEFORE INSERT OR UPDATE ON rh.cargos
    FOR EACH ROW
    EXECUTE FUNCTION auditoria.fn_set_audit_users();
-- Auditoría para cargos
CREATE TRIGGER trg_cargos_audit
    AFTER INSERT OR UPDATE OR DELETE ON rh.cargos
    FOR EACH ROW
    EXECUTE FUNCTION auditoria.fn_auditar_cambios();



-- TABLA: rh.departamentos
CREATE TABLE IF NOT EXISTS rh.departamentos (
    id BIGSERIAL NOT NULL,
    codigo VARCHAR(20),
    nombre VARCHAR(100) NOT NULL,
    descripcion TEXT,
    empleado_id BIGINT,
    activo BOOLEAN DEFAULT true,
    created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    created_by VARCHAR(100),
    updated_by VARCHAR(100),
    CONSTRAINT pk_departamentos PRIMARY KEY (id),
    CONSTRAINT uk_departamentos_nombre UNIQUE (nombre),
    CONSTRAINT uk_departamentos_codigo UNIQUE (codigo),
    CONSTRAINT ck_departamentos_nombre_min CHECK (LENGTH(TRIM(nombre)) >= 3)
);
-- Índices para departamentos
CREATE INDEX idx_departamentos_activo ON rh.departamentos(activo) WHERE activo = true;
-- Trigger para updated_at
CREATE TRIGGER trigger_departamentos_updated_at
    BEFORE UPDATE ON rh.departamentos
    FOR EACH ROW
    EXECUTE FUNCTION auditoria.fn_update_updated_at_column();
-- Trigger para created_by y updated_by
CREATE TRIGGER trigger_departamentos_set_users
    BEFORE INSERT OR UPDATE ON rh.departamentos
    FOR EACH ROW
    EXECUTE FUNCTION auditoria.fn_set_audit_users();
-- Auditoría para departamentos
CREATE TRIGGER trg_departamentos_audit
    AFTER INSERT OR UPDATE OR DELETE ON rh.departamentos
    FOR EACH ROW
    EXECUTE FUNCTION auditoria.fn_auditar_cambios();



-- TABLA: rh.empleados
CREATE TABLE IF NOT EXISTS rh.empleados (
    id BIGSERIAL NOT NULL,
    numero_identificacion VARCHAR(20) NOT NULL,
    tipo_identificacion VARCHAR(10) NOT NULL,
    nombres VARCHAR(100) NOT NULL,
    apellidos VARCHAR(100) NOT NULL,
    email VARCHAR(150) NOT NULL,
    email_personal VARCHAR(150),
    telefono VARCHAR(20),
    celular VARCHAR(20),
    fecha_nacimiento DATE,
    genero CHAR(1),
    direccion TEXT,
    cargo_id BIGINT NOT NULL,
    departamento_id BIGINT NOT NULL,
    jefe_id BIGINT,
    fecha_ingreso DATE NOT NULL,
    fecha_salida DATE,
    estado VARCHAR(20) DEFAULT 'ACTIVO',
    tipo_contrato VARCHAR(20) NOT NULL,
    salario DECIMAL(12,2),
    activo BOOLEAN DEFAULT true,
    created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    created_by VARCHAR(100),
    updated_by VARCHAR(100),
    CONSTRAINT pk_empleados PRIMARY KEY (id),
    CONSTRAINT uk_empleados_numero_identificacion UNIQUE (numero_identificacion, tipo_identificacion),
    CONSTRAINT uk_empleados_email UNIQUE (email),
    CONSTRAINT ck_empleados_nombres_min CHECK (LENGTH(TRIM(nombres)) >= 2),
    CONSTRAINT ck_empleados_apellidos_min CHECK (LENGTH(TRIM(apellidos)) >= 2),
    CONSTRAINT ck_empleados_fechas CHECK (fecha_salida IS NULL OR fecha_salida >= fecha_ingreso),
    CONSTRAINT ck_empleados_genero CHECK (genero IN ('M', 'F', 'O')),
    CONSTRAINT ck_empleados_estado CHECK (estado IN ('ACTIVO', 'INACTIVO', 'VACACIONES', 'LICENCIA', 'SUSPENDIDO')),
    CONSTRAINT ck_empleados_tipo_contrato CHECK (tipo_contrato IN ('INDEFINIDO', 'TEMPORAL', 'PRACTICAS', 'CONSULTORIA')),
    CONSTRAINT fk_empleados_cargo FOREIGN KEY (cargo_id)
        REFERENCES rh.cargos(id)
        ON UPDATE NO ACTION
        ON DELETE NO ACTION,
    CONSTRAINT fk_empleados_departamento FOREIGN KEY (departamento_id)
        REFERENCES rh.departamentos(id)
        ON UPDATE NO ACTION
        ON DELETE NO ACTION
);
-- Índices para empleados
CREATE INDEX idx_empleados_cargo ON rh.empleados(cargo_id);
CREATE INDEX idx_empleados_departamento ON rh.empleados(departamento_id);
CREATE INDEX idx_empleados_jefe ON rh.empleados(jefe_id);
CREATE INDEX idx_empleados_estado ON rh.empleados(estado);
CREATE INDEX idx_empleados_activo ON rh.empleados(activo) WHERE activo = true;
CREATE INDEX idx_empleados_fecha_ingreso ON rh.empleados(fecha_ingreso);
CREATE INDEX idx_empleados_numero_identificacion ON rh.empleados(numero_identificacion);
-- Trigger para updated_at
CREATE TRIGGER trigger_empleados_updated_at
    BEFORE UPDATE ON rh.empleados
    FOR EACH ROW
    EXECUTE FUNCTION auditoria.fn_update_updated_at_column();
-- Trigger para created_by y updated_by
CREATE TRIGGER trigger_empleados_set_users
    BEFORE INSERT OR UPDATE ON rh.empleados
    FOR EACH ROW
    EXECUTE FUNCTION auditoria.fn_set_audit_users();
-- Foreign key jefe_id (después de crear la tabla)
ALTER TABLE rh.empleados
    ADD CONSTRAINT fk_empleados_jefe FOREIGN KEY (jefe_id)
        REFERENCES rh.empleados(id)
        ON UPDATE NO ACTION
        ON DELETE NO ACTION;
-- Auditoría para empleados
CREATE TRIGGER trg_empleados_audit
    AFTER INSERT OR UPDATE OR DELETE ON rh.empleados
    FOR EACH ROW
    EXECUTE FUNCTION auditoria.fn_auditar_cambios();







-- TABLA: rh.contactos_emergencia
CREATE TABLE IF NOT EXISTS rh.contactos_emergencia (
    id BIGSERIAL NOT NULL,
    empleado_id BIGINT NOT NULL,
    nombres VARCHAR(100) NOT NULL,
    parentesco VARCHAR(50) NOT NULL,
    telefono VARCHAR(20) NOT NULL,
    telefono_alterno VARCHAR(20),
    email VARCHAR(150),
    prioridad INTEGER DEFAULT 1,
    activo BOOLEAN DEFAULT true,
    created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    created_by VARCHAR(100),
    updated_by VARCHAR(100),
    CONSTRAINT pk_contactos_emergencia PRIMARY KEY (id),
    CONSTRAINT ck_contactos_prioridad CHECK (prioridad > 0),
    CONSTRAINT fk_contactos_empleado FOREIGN KEY (empleado_id)
        REFERENCES rh.empleados(id)
        ON UPDATE NO ACTION
        ON DELETE CASCADE
);
-- Índices para contactos_emergencia
CREATE INDEX idx_contactos_empleado ON rh.contactos_emergencia(empleado_id);
CREATE INDEX idx_contactos_activo ON rh.contactos_emergencia(activo) WHERE activo = true;
-- Trigger para updated_at
CREATE TRIGGER trigger_contactos_emergencia_updated_at
    BEFORE UPDATE ON rh.contactos_emergencia
    FOR EACH ROW
    EXECUTE FUNCTION auditoria.fn_update_updated_at_column();
-- Trigger para created_by y updated_by
CREATE TRIGGER trigger_contactos_set_users
    BEFORE INSERT OR UPDATE ON rh.contactos_emergencia
    FOR EACH ROW
    EXECUTE FUNCTION auditoria.fn_set_audit_users();
-- Auditoría para contactos_emergencia
CREATE TRIGGER trg_contactos_emergencia_audit
    AFTER INSERT OR UPDATE OR DELETE ON rh.contactos_emergencia
    FOR EACH ROW
    EXECUTE FUNCTION auditoria.fn_auditar_cambios();





-- TABLA: rh.historial_cargos
CREATE TABLE IF NOT EXISTS rh.historial_cargos (
    id BIGSERIAL NOT NULL,
    empleado_id BIGINT NOT NULL,
    cargo_id BIGINT NOT NULL,
    departamento_id BIGINT NOT NULL,
    salario DECIMAL(12,2),
    fecha_inicio DATE NOT NULL,
    fecha_fin DATE,
    motivo VARCHAR(100),
    observaciones TEXT,
    created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    created_by VARCHAR(100),
    CONSTRAINT pk_historial_cargos PRIMARY KEY (id),
    CONSTRAINT ck_historial_cargos_fechas CHECK (fecha_fin IS NULL OR fecha_fin >= fecha_inicio),
    CONSTRAINT fk_historial_empleado FOREIGN KEY (empleado_id)
        REFERENCES rh.empleados(id)
        ON UPDATE NO ACTION
        ON DELETE NO ACTION,
    CONSTRAINT fk_historial_cargo FOREIGN KEY (cargo_id)
        REFERENCES rh.cargos(id)
        ON UPDATE NO ACTION
        ON DELETE NO ACTION,
    CONSTRAINT fk_historial_departamento FOREIGN KEY (departamento_id)
        REFERENCES rh.departamentos(id)
        ON UPDATE NO ACTION
        ON DELETE NO ACTION
);
-- Índices para historial_cargos
CREATE INDEX idx_historial_empleado ON rh.historial_cargos(empleado_id);
CREATE INDEX idx_historial_fechas ON rh.historial_cargos(fecha_inicio, fecha_fin);
CREATE INDEX idx_historial_cargo ON rh.historial_cargos(cargo_id);
-- Trigger para created_by (solo INSERT)
CREATE TRIGGER trigger_historial_set_users
    BEFORE INSERT ON rh.historial_cargos
    FOR EACH ROW
    EXECUTE FUNCTION auditoria.fn_set_audit_users();
-- Auditoría para historial_cargos
CREATE TRIGGER trg_historial_cargos_audit
    AFTER INSERT OR UPDATE OR DELETE ON rh.historial_cargos
    FOR EACH ROW
    EXECUTE FUNCTION auditoria.fn_auditar_cambios();





-- TABLA: rh.ausencias
CREATE TABLE IF NOT EXISTS rh.ausencias (
    id BIGSERIAL NOT NULL,
    empleado_id BIGINT NOT NULL,
    tipo_ausencia VARCHAR(30) NOT NULL,
    fecha_inicio DATE NOT NULL,
    fecha_fin DATE NOT NULL,
    dias_totales INTEGER GENERATED ALWAYS AS (fecha_fin - fecha_inicio + 1) STORED,
    motivo TEXT,
    documento_url TEXT,
    aprobado_por BIGINT,
    estado VARCHAR(20) DEFAULT 'PENDIENTE',
    observaciones TEXT,
    created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    created_by VARCHAR(100),
    updated_by VARCHAR(100),
    CONSTRAINT pk_ausencias PRIMARY KEY (id),
    CONSTRAINT ck_ausencias_fechas CHECK (fecha_fin >= fecha_inicio),
    CONSTRAINT ck_ausencias_tipo CHECK (tipo_ausencia IN ('VACACIONES', 'LICENCIA_MEDICA', 'LICENCIA_REMUNERADA', 'LICENCIA_NO_REMUNERADA', 'PERMISO', 'SUSPENSION')),
    CONSTRAINT ck_ausencias_estado CHECK (estado IN ('PENDIENTE', 'APROBADO', 'RECHAZADO', 'CANCELADO')),
    CONSTRAINT fk_ausencias_empleado FOREIGN KEY (empleado_id)
        REFERENCES rh.empleados(id)
        ON UPDATE NO ACTION
        ON DELETE NO ACTION,
    CONSTRAINT fk_ausencias_aprobador FOREIGN KEY (aprobado_por)
        REFERENCES rh.empleados(id)
        ON UPDATE NO ACTION
        ON DELETE NO ACTION
);
-- Índices para ausencias
CREATE INDEX idx_ausencias_empleado ON rh.ausencias(empleado_id);
CREATE INDEX idx_ausencias_fechas ON rh.ausencias(fecha_inicio, fecha_fin);
CREATE INDEX idx_ausencias_estado ON rh.ausencias(estado);
CREATE INDEX idx_ausencias_tipo ON rh.ausencias(tipo_ausencia);
-- Trigger para updated_at
CREATE TRIGGER trigger_ausencias_updated_at
    BEFORE UPDATE ON rh.ausencias
    FOR EACH ROW
    EXECUTE FUNCTION auditoria.fn_update_updated_at_column();
-- Trigger para created_by y updated_by
CREATE TRIGGER trigger_ausencias_set_users
    BEFORE INSERT OR UPDATE ON rh.ausencias
    FOR EACH ROW
    EXECUTE FUNCTION auditoria.fn_set_audit_users();
-- Auditoría para ausencias
CREATE TRIGGER trg_ausencias_audit
    AFTER INSERT OR UPDATE OR DELETE ON rh.ausencias
    FOR EACH ROW
    EXECUTE FUNCTION auditoria.fn_auditar_cambios();






-- Insertar algunos cargos de prueba
INSERT INTO rh.cargos (nombre, descripcion, nivel, salario_base) VALUES
('Gerente General', 'Máxima autoridad ejecutiva', 'Ejecutivo', 5000.00),
('Jefe de TI', 'Responsable del área de tecnología', 'Jefatura', 3500.00),
('Desarrollador Senior', 'Desarrollador con experiencia', 'Senior', 2500.00),
('Desarrollador Junior', 'Desarrollador en formación', 'Junior', 1500.00),
('Analista de RRHH', 'Gestión de talento humano', 'Analista', 1800.00);

-- Insertar algunos departamentos de prueba
INSERT INTO rh.departamentos (nombre, descripcion, codigo) VALUES
('Gerencia', 'Dirección general', 'GER'),
('Tecnología', 'Sistemas y desarrollo', 'TEC'),
('Recursos Humanos', 'Gestión del talento', 'RRHH'),
('Finanzas', 'Gestión financiera', 'FIN'),
('Operaciones', 'Procesos operativos', 'OPE');

-- Insertar algunos empleados de prueba
INSERT INTO rh.empleados (
    numero_identificacion, tipo_identificacion, nombres, apellidos, email, 
    cargo_id, departamento_id, fecha_ingreso, tipo_contrato, salario
) VALUES (
    '12345678', 'CC', 'Juan', 'Pérez', 'juan.perez@empresa.com',
    1, 1, '2020-01-15', 'INDEFINIDO', 5000.00
), (
    '87654321', 'CC', 'María', 'Gómez', 'maria.gomez@empresa.com',
    2, 2, '2021-03-10', 'INDEFINIDO', 3500.00
), (
    '11122233', 'CC', 'Carlos', 'López', 'carlos.lopez@empresa.com',
    3, 2, '2022-06-01', 'INDEFINIDO', 2500.00
);







-- Ver auditoría completa
SELECT * FROM auditoria.logs_cambios 
--WHERE tabla_nombre = 'departamentos' --AND registro_id = 1 
ORDER BY fecha_operacion DESC;


