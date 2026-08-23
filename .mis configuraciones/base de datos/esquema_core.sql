-- ============================================
-- CREACIÓN DE ESQUEMA CORE
-- ============================================
CREATE SCHEMA IF NOT EXISTS core;



-- =========================
-- 1. TABLA UBICACIONES
-- =========================
CREATE TABLE IF NOT EXISTS core.ubicaciones (
    id BIGSERIAL NOT NULL,
    padre_id BIGINT DEFAULT NULL,  -- NULL para raíces (países)
    codigo VARCHAR(20) NOT NULL,    -- Código único (ej: EC, EC-P, EC-P-01)
    tipo VARCHAR(20) NOT NULL,      -- 'PAIS', 'PROVINCIA', 'CANTON', 'PARROQUIA'
    nombre VARCHAR(100) NOT NULL,
    nombre_oficial VARCHAR(200),     -- Nombre oficial completo
    capital BOOLEAN DEFAULT FALSE,   -- Indica si es capital
    latitud DECIMAL(11, 8),
    longitud DECIMAL(11, 8),
    activo BOOLEAN DEFAULT TRUE,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),
    created_by VARCHAR(100),
    updated_by VARCHAR(100),
    
    CONSTRAINT pk_ubicaciones PRIMARY KEY (id),
    CONSTRAINT uk_ubicaciones_codigo UNIQUE (codigo),
    CONSTRAINT fk_ubicaciones_padre FOREIGN KEY (padre_id) 
        REFERENCES core.ubicaciones(id) 
        ON DELETE RESTRICT,
    CONSTRAINT chk_ubicaciones_tipo CHECK (tipo IN ('PAIS', 'PROVINCIA', 'CANTON', 'PARROQUIA'))
);
-- Índices para mejorar rendimiento en consultas recursivas
CREATE INDEX idx_ubicaciones_padre_id ON core.ubicaciones(padre_id);
CREATE INDEX idx_ubicaciones_tipo ON core.ubicaciones(tipo);
CREATE INDEX idx_ubicaciones_codigo ON core.ubicaciones(codigo);
CREATE INDEX idx_ubicaciones_nombre ON core.ubicaciones(nombre);

-- Trigger para updated_at
CREATE TRIGGER trigger_ubicaciones_updated_at
    BEFORE UPDATE ON core.ubicaciones
    FOR EACH ROW
    EXECUTE FUNCTION auditoria.fn_update_updated_at_column();
-- Trigger para created_by y updated_by
CREATE TRIGGER trigger_ubicaciones_set_users
    BEFORE INSERT OR UPDATE ON core.ubicaciones
    FOR EACH ROW
    EXECUTE FUNCTION auditoria.fn_set_audit_users();
-- Auditoría para ubicaciones
CREATE TRIGGER trg_ubicaciones_audit
    AFTER INSERT OR UPDATE OR DELETE ON core.ubicaciones
    FOR EACH ROW
    EXECUTE FUNCTION auditoria.fn_auditar_cambios();














-- =========================
-- 2. TABLA EMPRESA
-- =========================
CREATE TABLE core.empresa (
    id BIGSERIAL NOT NULL,
    ruc VARCHAR(13) UNIQUE NOT NULL,  -- 13 dígitos: 10+1+2 (RUC ecuatoriano)
    razon_social VARCHAR(300) NOT NULL,
    nombre_comercial VARCHAR(200),    
    regimen VARCHAR(50) DEFAULT 'GENERAL' CHECK (regimen IN (
        'GENERAL',           -- Régimen General
        'RIMPE',             -- Régimen RIMPE (Emprendedores)
        'RISE',              -- Régimen RISE (ya no se puede acoger)
        'NEGOCIO_POPULAR'    -- Negocio Popular
    )),    
    es_contribuyente_especial BOOLEAN DEFAULT false,
    resolucion_contribuyente_especial TEXT,    
    email VARCHAR(100),
    telefono VARCHAR(100),
    ubicacion_id BIGINT NOT NULL,
    direccion TEXT,    
    codigo_postal VARCHAR(10),
    representante_legal VARCHAR(200),
    contador VARCHAR(200),
    ambiente VARCHAR(10) DEFAULT 'PRUEBAS' CHECK (ambiente IN ('PRUEBAS', 'PRODUCCION')),
    tipo_emision VARCHAR(10) DEFAULT 'NORMAL' CHECK (tipo_emision IN ('NORMAL', 'CONTINGENCIA')),  
    logo_url TEXT,
    sitio_web VARCHAR(255),
    zona_horaria VARCHAR(50) DEFAULT 'America/Guayaquil',
    formato_fecha VARCHAR(20) DEFAULT 'DD/MM/YYYY',
    moneda VARCHAR(3) DEFAULT 'USD',
    simbolo_moneda VARCHAR(5) DEFAULT '$',    
    activo BOOLEAN DEFAULT true,    
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),
    created_by VARCHAR(100),
    updated_by VARCHAR(100),
    CONSTRAINT pk_empresa PRIMARY KEY (id),
    CONSTRAINT fk_empresa_ubicacion_id FOREIGN KEY (ubicacion_id)
        REFERENCES core.ubicaciones(id) MATCH SIMPLE
        ON UPDATE NO ACTION
        ON DELETE NO ACTION
);
-- Trigger para updated_at
CREATE TRIGGER trigger_empresa_updated_at
    BEFORE UPDATE ON core.empresa
    FOR EACH ROW
    EXECUTE FUNCTION auditoria.fn_update_updated_at_column();
-- Trigger para created_by y updated_by
CREATE TRIGGER trigger_empresa_set_users
    BEFORE INSERT OR UPDATE ON core.empresa
    FOR EACH ROW
    EXECUTE FUNCTION auditoria.fn_set_audit_users();
-- Auditoría para empresa
CREATE TRIGGER trg_empresa_audit
    AFTER INSERT OR UPDATE OR DELETE ON core.empresa
    FOR EACH ROW
    EXECUTE FUNCTION auditoria.fn_auditar_cambios();















-- =========================
-- 3. TABLA IMPUESTOS
-- =========================
CREATE TABLE core.impuestos (
    id BIGSERIAL NOT NULL,
    codigo VARCHAR(15) NOT NULL,
    nombre VARCHAR(100) NOT NULL,
    porcentaje DECIMAL(5,2) NOT NULL,
    tipo VARCHAR(20) NOT NULL CHECK (tipo IN ('IVA', 'ICE', 'IRBPNR', 'RETENCION')),
    activo BOOLEAN DEFAULT true,
    fecha_inicio DATE DEFAULT CURRENT_DATE,
    fecha_fin DATE,    
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),
    created_by VARCHAR(100),
    updated_by VARCHAR(100),
    CONSTRAINT pk_impuestos PRIMARY KEY (id),
    CONSTRAINT uk_impuestos_codigo UNIQUE (codigo)
);
-- Crear índices
CREATE INDEX idx_impuestos_tipo ON core.impuestos(tipo);
CREATE INDEX idx_impuestos_activo ON core.impuestos(activo) WHERE activo = true;

-- Trigger para updated_at
CREATE TRIGGER trigger_impuestos_updated_at
    BEFORE UPDATE ON core.impuestos
    FOR EACH ROW
    EXECUTE FUNCTION auditoria.fn_update_updated_at_column();
-- Trigger para created_by y updated_by
CREATE TRIGGER trigger_impuestos_set_users
    BEFORE INSERT OR UPDATE ON core.impuestos
    FOR EACH ROW
    EXECUTE FUNCTION auditoria.fn_set_audit_users();
-- Auditoría para impuestos
CREATE TRIGGER trg_impuestos_audit
    AFTER INSERT OR UPDATE OR DELETE ON core.impuestos
    FOR EACH ROW
    EXECUTE FUNCTION auditoria.fn_auditar_cambios();



-- Datos iniciales de impuestos Ecuador
INSERT INTO core.impuestos (codigo, nombre, porcentaje, tipo) VALUES
('IVA-0', 'IVA 0%', 0, 'IVA'),
('IVA-12', 'IVA 12%', 12, 'IVA'),
('IVA-15', 'IVA 15% (bebidas azucaradas)', 15, 'IVA'),
('ICE-10', 'ICE 10% (cervezas)', 10, 'ICE'),
('ICE-15', 'ICE 15% (cigarrillos)', 15, 'ICE'),
('ICE-50', 'ICE 50% (vehículos)', 50, 'ICE'),
('RET-IVA-30', 'Retención IVA 30%', 30, 'RETENCION'),
('RET-RENTA-1', 'Retención Renta 1%', 1, 'RETENCION'),
('RET-RENTA-2', 'Retención Renta 2%', 2, 'RETENCION'),
('RET-RENTA-8', 'Retención Renta 8%', 8, 'RETENCION'),
('RET-RENTA-10', 'Retención Renta 10%', 10, 'RETENCION');













-- =========================
-- 4. TABLA sucursales
-- =========================
CREATE TABLE core.sucursales (
    id BIGSERIAL NOT NULL,
    empresa_id BIGINT NOT NULL,
    codigo VARCHAR(3) NOT NULL,
    nombre VARCHAR(100) NOT NULL,
    ubicacion_id BIGINT NOT NULL,
    direccion TEXT,
    telefono VARCHAR(20),
    email VARCHAR(100),
    es_matriz BOOLEAN DEFAULT false,
    activo BOOLEAN DEFAULT true,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),
    created_by VARCHAR(100),
    updated_by VARCHAR(100),

    CONSTRAINT pk_sucursales PRIMARY KEY (id),
    CONSTRAINT fk_empresa_ubicacion_id FOREIGN KEY (ubicacion_id)
    REFERENCES core.ubicaciones(id) MATCH SIMPLE
    ON UPDATE NO ACTION
    ON DELETE NO ACTION,
    CONSTRAINT fk_empresas_empresa_id FOREIGN KEY (empresa_id)
        REFERENCES core.empresa(id) MATCH SIMPLE
        ON UPDATE NO ACTION
        ON DELETE NO ACTION,
    CONSTRAINT uk_sucursales_codigo UNIQUE (codigo)
);
-- Crear índices
CREATE INDEX idx_sucursales_activo ON core.sucursales(activo) WHERE activo = true;

-- Trigger para updated_at
CREATE TRIGGER trigger_sucursales_updated_at
    BEFORE UPDATE ON core.sucursales
    FOR EACH ROW
    EXECUTE FUNCTION auditoria.fn_update_updated_at_column();
-- Trigger para created_by y updated_by
CREATE TRIGGER trigger_sucursales_set_users
    BEFORE INSERT OR UPDATE ON core.sucursales
    FOR EACH ROW
    EXECUTE FUNCTION auditoria.fn_set_audit_users();
-- Auditoría para sucursales
CREATE TRIGGER trg_sucursales_audit
    AFTER INSERT OR UPDATE OR DELETE ON core.sucursales
    FOR EACH ROW
    EXECUTE FUNCTION auditoria.fn_auditar_cambios();













-- =========================
-- 5. TABLA regiones
-- =========================
CREATE TABLE core.regiones (
    id BIGSERIAL NOT NULL,
    codigo VARCHAR(20) NOT NULL,
    nombre VARCHAR(100) NOT NULL,
    activo BOOLEAN DEFAULT true,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),
    created_by VARCHAR(100),
    updated_by VARCHAR(100),

    CONSTRAINT pk_regiones PRIMARY KEY (id),
    CONSTRAINT uk_regiones_codigo UNIQUE (codigo)

);
-- Crear índices
CREATE INDEX idx_regiones_activo ON core.regiones(activo) WHERE activo = true;

-- Trigger para updated_at
CREATE TRIGGER trigger_regiones_updated_at
    BEFORE UPDATE ON core.regiones
    FOR EACH ROW
    EXECUTE FUNCTION auditoria.fn_update_updated_at_column();
-- Trigger para created_by y updated_by
CREATE TRIGGER trigger_regiones_set_users
    BEFORE INSERT OR UPDATE ON core.regiones
    FOR EACH ROW
    EXECUTE FUNCTION auditoria.fn_set_audit_users();
-- Auditoría para regiones
CREATE TRIGGER trg_regiones_audit
    AFTER INSERT OR UPDATE OR DELETE ON core.regiones
    FOR EACH ROW
    EXECUTE FUNCTION auditoria.fn_auditar_cambios();











-- =========================
-- 6. TABLA puntos de venta
-- =========================
CREATE TABLE core.puntos_venta (
    id BIGSERIAL NOT NULL,
    sucursal_id BIGINT NOT NULL,
    region_id BIGINT NOT NULL,
    codigo VARCHAR(20) NOT NULL,
    nombre VARCHAR(100) NOT NULL,
    numero INTEGER NOT NULL,
    activo BOOLEAN DEFAULT true,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),
    created_by VARCHAR(100),
    updated_by VARCHAR(100),

    CONSTRAINT pk_puntos_venta PRIMARY KEY (id),
    CONSTRAINT fk_sucursales_almacen_id FOREIGN KEY (sucursal_id)
        REFERENCES core.sucursales(id) MATCH SIMPLE
        ON UPDATE NO ACTION
        ON DELETE NO ACTION,
    CONSTRAINT fk_regiones_almacen_id FOREIGN KEY (region_id)
        REFERENCES core.regiones(id) MATCH SIMPLE
        ON UPDATE NO ACTION
        ON DELETE NO ACTION,
    CONSTRAINT uk_puntos_venta_codigo UNIQUE (codigo)

);
-- Crear índices
CREATE INDEX idx_puntos_venta_activo ON core.puntos_venta(activo) WHERE activo = true;

-- Trigger para updated_at
CREATE TRIGGER trigger_puntos_venta_updated_at
    BEFORE UPDATE ON core.puntos_venta
    FOR EACH ROW
    EXECUTE FUNCTION auditoria.fn_update_updated_at_column();
-- Trigger para created_by y updated_by
CREATE TRIGGER trigger_puntos_venta_set_users
    BEFORE INSERT OR UPDATE ON core.puntos_venta
    FOR EACH ROW
    EXECUTE FUNCTION auditoria.fn_set_audit_users();
-- Auditoría para puntos_venta
CREATE TRIGGER trg_puntos_venta_audit
    AFTER INSERT OR UPDATE OR DELETE ON core.puntos_venta
    FOR EACH ROW
    EXECUTE FUNCTION auditoria.fn_auditar_cambios();










-- =========================
-- 7. TABLA bodegas
-- =========================
CREATE TABLE core.bodegas (
    id BIGSERIAL NOT NULL,
    sucursal_id BIGINT NOT NULL,
    codigo VARCHAR(20) UNIQUE NOT NULL,
    nombre VARCHAR(100) NOT NULL,
    direccion TEXT,
    activo BOOLEAN DEFAULT true,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),
    created_by VARCHAR(100),
    updated_by VARCHAR(100),
    CONSTRAINT pk_bodegas PRIMARY KEY (id),
    CONSTRAINT fk_sucursales_bodegas_id FOREIGN KEY (sucursal_id)
        REFERENCES core.sucursales(id) MATCH SIMPLE
        ON UPDATE NO ACTION
        ON DELETE NO ACTION,
    CONSTRAINT uk_bodegas_codigo UNIQUE (codigo)
);
-- Crear índices
CREATE INDEX idx_bodegas_activo ON core.bodegas(activo) WHERE activo = true;

-- Trigger para updated_at
CREATE TRIGGER trigger_bodegas_updated_at
    BEFORE UPDATE ON core.bodegas
    FOR EACH ROW
    EXECUTE FUNCTION auditoria.fn_update_updated_at_column();
-- Trigger para created_by y updated_by
CREATE TRIGGER trigger_bodegas_set_users
    BEFORE INSERT OR UPDATE ON core.bodegas
    FOR EACH ROW
    EXECUTE FUNCTION auditoria.fn_set_audit_users();
-- Auditoría para bodegas
CREATE TRIGGER trg_bodegas_audit
    AFTER INSERT OR UPDATE OR DELETE ON core.bodegas
    FOR EACH ROW
    EXECUTE FUNCTION auditoria.fn_auditar_cambios();


































--select * from core.vista_ubicaciones_completas;
-- =====================================================
-- VISTA 1: Ubicaciones con nombre completo jerárquico (CORREGIDA)
-- =====================================================
CREATE OR REPLACE VIEW core.vista_ubicaciones_completas AS
WITH RECURSIVE ubicacion_path AS (
    SELECT 
        id,
        padre_id,
        0 as nivel,		
        codigo,
        tipo,
        nombre,
		nombre::TEXT AS nombre2,
        nombre::text as nombre_completo,
        ARRAY[id]::BIGINT[] as ruta_ids,
        ARRAY[nombre]::TEXT[] as ruta_nombres
    FROM core.ubicaciones
    WHERE padre_id IS NULL
    
    UNION ALL
    
    SELECT 
        u.id,
        u.padre_id,
        up.nivel + 1,
        u.codigo,
        u.tipo,
        u.nombre,		
		(repeat('      ', up.nivel + 1) || u.nombre)::TEXT AS nombre2,
        up.nombre_completo || ' > ' || u.nombre as nombre_completo,
        up.ruta_ids || u.id,
        up.ruta_nombres || u.nombre
    FROM core.ubicaciones u
    INNER JOIN ubicacion_path up ON u.padre_id = up.id
)
SELECT 
    id,
    padre_id,
    nivel,
    codigo,
    tipo,
    nombre,
	nombre2,
    nombre_completo,
    ruta_ids,
    ruta_nombres
FROM ubicacion_path 
ORDER BY nombre_completo;






















-- =====================================================
-- 1. INSERTAR PAÍS
-- =====================================================
INSERT INTO core.ubicaciones (codigo, tipo, nombre, nombre_oficial, capital, latitud, longitud)
VALUES ('EC', 'PAIS', 'Ecuador', 'República del Ecuador', TRUE, -1.831239, -78.183406);

-- =====================================================
-- 2. INSERTAR TODAS LAS PROVINCIAS (24 provincias)
-- =====================================================
DO $$
DECLARE
    ecuador_id BIGINT;
BEGIN
    SELECT id INTO ecuador_id FROM core.ubicaciones WHERE codigo = 'EC';
    
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre, capital) VALUES
    (ecuador_id, 'EC-P-01', 'PROVINCIA', 'Azuay', TRUE),
    (ecuador_id, 'EC-P-02', 'PROVINCIA', 'Bolívar', TRUE),
    (ecuador_id, 'EC-P-03', 'PROVINCIA', 'Cañar', TRUE),
    (ecuador_id, 'EC-P-04', 'PROVINCIA', 'Carchi', TRUE),
    (ecuador_id, 'EC-P-05', 'PROVINCIA', 'Chimborazo', TRUE),
    (ecuador_id, 'EC-P-06', 'PROVINCIA', 'Cotopaxi', TRUE),
    (ecuador_id, 'EC-P-07', 'PROVINCIA', 'El Oro', TRUE),
    (ecuador_id, 'EC-P-08', 'PROVINCIA', 'Esmeraldas', TRUE),
    (ecuador_id, 'EC-P-09', 'PROVINCIA', 'Galápagos', TRUE),
    (ecuador_id, 'EC-P-10', 'PROVINCIA', 'Guayas', TRUE),
    (ecuador_id, 'EC-P-11', 'PROVINCIA', 'Imbabura', TRUE),
    (ecuador_id, 'EC-P-12', 'PROVINCIA', 'Loja', TRUE),
    (ecuador_id, 'EC-P-13', 'PROVINCIA', 'Los Ríos', TRUE),
    (ecuador_id, 'EC-P-14', 'PROVINCIA', 'Manabí', TRUE),
    (ecuador_id, 'EC-P-15', 'PROVINCIA', 'Morona Santiago', TRUE),
    (ecuador_id, 'EC-P-16', 'PROVINCIA', 'Napo', TRUE),
    (ecuador_id, 'EC-P-17', 'PROVINCIA', 'Orellana', TRUE),
    (ecuador_id, 'EC-P-18', 'PROVINCIA', 'Pastaza', TRUE),
    (ecuador_id, 'EC-P-19', 'PROVINCIA', 'Pichincha', TRUE),
    (ecuador_id, 'EC-P-20', 'PROVINCIA', 'Santa Elena', TRUE),
    (ecuador_id, 'EC-P-21', 'PROVINCIA', 'Santo Domingo de los Tsáchilas', TRUE),
    (ecuador_id, 'EC-P-22', 'PROVINCIA', 'Sucumbíos', TRUE),
    (ecuador_id, 'EC-P-23', 'PROVINCIA', 'Tungurahua', TRUE),
    (ecuador_id, 'EC-P-24', 'PROVINCIA', 'Zamora Chinchipe', TRUE);
END $$;

-- =====================================================
-- 3. INSERTAR TODOS LOS CANTONES POR PROVINCIA
-- =====================================================

-- AZUAY (15 cantones) [citation:3][citation:8]
DO $$
DECLARE
    provincia_id BIGINT;
BEGIN
    SELECT id INTO provincia_id FROM core.ubicaciones WHERE codigo = 'EC-P-01';
    
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre, capital) VALUES
    (provincia_id, 'EC-P-01-C-01', 'CANTON', 'Cuenca', TRUE),
    (provincia_id, 'EC-P-01-C-02', 'CANTON', 'Camilo Ponce Enríquez', FALSE),
    (provincia_id, 'EC-P-01-C-03', 'CANTON', 'Chordeleg', FALSE),
    (provincia_id, 'EC-P-01-C-04', 'CANTON', 'El Pan', FALSE),
    (provincia_id, 'EC-P-01-C-05', 'CANTON', 'Girón', FALSE),
    (provincia_id, 'EC-P-01-C-06', 'CANTON', 'Guachapala', FALSE),
    (provincia_id, 'EC-P-01-C-07', 'CANTON', 'Gualaceo', FALSE),
    (provincia_id, 'EC-P-01-C-08', 'CANTON', 'Nabón', FALSE),
    (provincia_id, 'EC-P-01-C-09', 'CANTON', 'Oña', FALSE),
    (provincia_id, 'EC-P-01-C-10', 'CANTON', 'Paute', FALSE),
    (provincia_id, 'EC-P-01-C-11', 'CANTON', 'Pucará', FALSE),
    (provincia_id, 'EC-P-01-C-12', 'CANTON', 'San Fernando', FALSE),
    (provincia_id, 'EC-P-01-C-13', 'CANTON', 'Santa Isabel', FALSE),
    (provincia_id, 'EC-P-01-C-14', 'CANTON', 'Sigsig', FALSE),
    (provincia_id, 'EC-P-01-C-15', 'CANTON', 'Sevilla de Oro', FALSE);
END $$;

-- BOLÍVAR (7 cantones) [citation:3][citation:8]
DO $$
DECLARE
    provincia_id BIGINT;
BEGIN
    SELECT id INTO provincia_id FROM core.ubicaciones WHERE codigo = 'EC-P-02';
    
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre, capital) VALUES
    (provincia_id, 'EC-P-02-C-01', 'CANTON', 'Guaranda', TRUE),
    (provincia_id, 'EC-P-02-C-02', 'CANTON', 'Caluma', FALSE),
    (provincia_id, 'EC-P-02-C-03', 'CANTON', 'Chillanes', FALSE),
    (provincia_id, 'EC-P-02-C-04', 'CANTON', 'Chimbo', FALSE),
    (provincia_id, 'EC-P-02-C-05', 'CANTON', 'Echeandía', FALSE),
    (provincia_id, 'EC-P-02-C-06', 'CANTON', 'Las Naves', FALSE),
    (provincia_id, 'EC-P-02-C-07', 'CANTON', 'San Miguel', FALSE);
END $$;

-- CAÑAR (7 cantones) [citation:3][citation:8]
DO $$
DECLARE
    provincia_id BIGINT;
BEGIN
    SELECT id INTO provincia_id FROM core.ubicaciones WHERE codigo = 'EC-P-03';
    
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre, capital) VALUES
    (provincia_id, 'EC-P-03-C-01', 'CANTON', 'Azogues', TRUE),
    (provincia_id, 'EC-P-03-C-02', 'CANTON', 'Biblián', FALSE),
    (provincia_id, 'EC-P-03-C-03', 'CANTON', 'Cañar', FALSE),
    (provincia_id, 'EC-P-03-C-04', 'CANTON', 'Déleg', FALSE),
    (provincia_id, 'EC-P-03-C-05', 'CANTON', 'El Tambo', FALSE),
    (provincia_id, 'EC-P-03-C-06', 'CANTON', 'La Troncal', FALSE),
    (provincia_id, 'EC-P-03-C-07', 'CANTON', 'Suscal', FALSE);
END $$;

-- CARCHI (6 cantones) [citation:3][citation:8]
DO $$
DECLARE
    provincia_id BIGINT;
BEGIN
    SELECT id INTO provincia_id FROM core.ubicaciones WHERE codigo = 'EC-P-04';
    
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre, capital) VALUES
    (provincia_id, 'EC-P-04-C-01', 'CANTON', 'Tulcán', TRUE),
    (provincia_id, 'EC-P-04-C-02', 'CANTON', 'Bolívar', FALSE),
    (provincia_id, 'EC-P-04-C-03', 'CANTON', 'Espejo', FALSE),
    (provincia_id, 'EC-P-04-C-04', 'CANTON', 'Mira', FALSE),
    (provincia_id, 'EC-P-04-C-05', 'CANTON', 'Montúfar', FALSE),
    (provincia_id, 'EC-P-04-C-06', 'CANTON', 'San Pedro de Huaca', FALSE);
END $$;

-- CHIMBORAZO (10 cantones) [citation:3][citation:8]
DO $$
DECLARE
    provincia_id BIGINT;
BEGIN
    SELECT id INTO provincia_id FROM core.ubicaciones WHERE codigo = 'EC-P-05';
    
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre, capital) VALUES
    (provincia_id, 'EC-P-05-C-01', 'CANTON', 'Riobamba', TRUE),
    (provincia_id, 'EC-P-05-C-02', 'CANTON', 'Alausí', FALSE),
    (provincia_id, 'EC-P-05-C-03', 'CANTON', 'Chambo', FALSE),
    (provincia_id, 'EC-P-05-C-04', 'CANTON', 'Chunchi', FALSE),
    (provincia_id, 'EC-P-05-C-05', 'CANTON', 'Colta', FALSE),
    (provincia_id, 'EC-P-05-C-06', 'CANTON', 'Cumandá', FALSE),
    (provincia_id, 'EC-P-05-C-07', 'CANTON', 'Guamote', FALSE),
    (provincia_id, 'EC-P-05-C-08', 'CANTON', 'Guano', FALSE),
    (provincia_id, 'EC-P-05-C-09', 'CANTON', 'Pallatanga', FALSE),
    (provincia_id, 'EC-P-05-C-10', 'CANTON', 'Penipe', FALSE);
END $$;

-- COTOPAXI (7 cantones) [citation:3][citation:8]
DO $$
DECLARE
    provincia_id BIGINT;
BEGIN
    SELECT id INTO provincia_id FROM core.ubicaciones WHERE codigo = 'EC-P-06';
    
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre, capital) VALUES
    (provincia_id, 'EC-P-06-C-01', 'CANTON', 'Latacunga', TRUE),
    (provincia_id, 'EC-P-06-C-02', 'CANTON', 'La Maná', FALSE),
    (provincia_id, 'EC-P-06-C-03', 'CANTON', 'Pangua', FALSE),
    (provincia_id, 'EC-P-06-C-04', 'CANTON', 'Pujilí', FALSE),
    (provincia_id, 'EC-P-06-C-05', 'CANTON', 'Salcedo', FALSE),
    (provincia_id, 'EC-P-06-C-06', 'CANTON', 'Saquisilí', FALSE),
    (provincia_id, 'EC-P-06-C-07', 'CANTON', 'Sigchos', FALSE);
END $$;

-- EL ORO (14 cantones) [citation:3][citation:8]
DO $$
DECLARE
    provincia_id BIGINT;
BEGIN
    SELECT id INTO provincia_id FROM core.ubicaciones WHERE codigo = 'EC-P-07';
    
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre, capital) VALUES
    (provincia_id, 'EC-P-07-C-01', 'CANTON', 'Machala', TRUE),
    (provincia_id, 'EC-P-07-C-02', 'CANTON', 'Arenillas', FALSE),
    (provincia_id, 'EC-P-07-C-03', 'CANTON', 'Atahualpa', FALSE),
    (provincia_id, 'EC-P-07-C-04', 'CANTON', 'Balsas', FALSE),
    (provincia_id, 'EC-P-07-C-05', 'CANTON', 'Chilla', FALSE),
    (provincia_id, 'EC-P-07-C-06', 'CANTON', 'El Guabo', FALSE),
    (provincia_id, 'EC-P-07-C-07', 'CANTON', 'Huaquillas', FALSE),
    (provincia_id, 'EC-P-07-C-08', 'CANTON', 'Las Lajas', FALSE),
    (provincia_id, 'EC-P-07-C-09', 'CANTON', 'Marcabelí', FALSE),
    (provincia_id, 'EC-P-07-C-10', 'CANTON', 'Pasaje', FALSE),
    (provincia_id, 'EC-P-07-C-11', 'CANTON', 'Piñas', FALSE),
    (provincia_id, 'EC-P-07-C-12', 'CANTON', 'Portovelo', FALSE),
    (provincia_id, 'EC-P-07-C-13', 'CANTON', 'Santa Rosa', FALSE),
    (provincia_id, 'EC-P-07-C-14', 'CANTON', 'Zaruma', FALSE);
END $$;

-- ESMERALDAS (7 cantones) [citation:1][citation:3]
DO $$
DECLARE
    provincia_id BIGINT;
BEGIN
    SELECT id INTO provincia_id FROM core.ubicaciones WHERE codigo = 'EC-P-08';
    
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre, capital) VALUES
    (provincia_id, 'EC-P-08-C-01', 'CANTON', 'Esmeraldas', TRUE),
    (provincia_id, 'EC-P-08-C-02', 'CANTON', 'Atacames', FALSE),
    (provincia_id, 'EC-P-08-C-03', 'CANTON', 'Eloy Alfaro', FALSE),
    (provincia_id, 'EC-P-08-C-04', 'CANTON', 'Muisne', FALSE),
    (provincia_id, 'EC-P-08-C-05', 'CANTON', 'Quinindé', FALSE),
    (provincia_id, 'EC-P-08-C-06', 'CANTON', 'Rioverde', FALSE),
    (provincia_id, 'EC-P-08-C-07', 'CANTON', 'San Lorenzo', FALSE);
END $$;

-- GALÁPAGOS (3 cantones) [citation:3][citation:8]
DO $$
DECLARE
    provincia_id BIGINT;
BEGIN
    SELECT id INTO provincia_id FROM core.ubicaciones WHERE codigo = 'EC-P-09';
    
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre, capital) VALUES
    (provincia_id, 'EC-P-09-C-01', 'CANTON', 'Puerto Baquerizo Moreno', TRUE),
    (provincia_id, 'EC-P-09-C-02', 'CANTON', 'Isabela', FALSE),
    (provincia_id, 'EC-P-09-C-03', 'CANTON', 'Santa Cruz', FALSE);
END $$;

-- GUAYAS (25 cantones) [citation:3][citation:8]
DO $$
DECLARE
    provincia_id BIGINT;
BEGIN
    SELECT id INTO provincia_id FROM core.ubicaciones WHERE codigo = 'EC-P-10';
    
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre, capital) VALUES
    (provincia_id, 'EC-P-10-C-01', 'CANTON', 'Guayaquil', TRUE),
    (provincia_id, 'EC-P-10-C-02', 'CANTON', 'Alfredo Baquerizo Moreno', FALSE),
    (provincia_id, 'EC-P-10-C-03', 'CANTON', 'Balao', FALSE),
    (provincia_id, 'EC-P-10-C-04', 'CANTON', 'Balzar', FALSE),
    (provincia_id, 'EC-P-10-C-05', 'CANTON', 'Colimes', FALSE),
    (provincia_id, 'EC-P-10-C-06', 'CANTON', 'Coronel Marcelino Maridueña', FALSE),
    (provincia_id, 'EC-P-10-C-07', 'CANTON', 'Daule', FALSE),
    (provincia_id, 'EC-P-10-C-08', 'CANTON', 'Durán', FALSE),
    (provincia_id, 'EC-P-10-C-09', 'CANTON', 'El Empalme', FALSE),
    (provincia_id, 'EC-P-10-C-10', 'CANTON', 'El Triunfo', FALSE),
    (provincia_id, 'EC-P-10-C-11', 'CANTON', 'General Antonio Elizalde', FALSE),
    (provincia_id, 'EC-P-10-C-12', 'CANTON', 'Isidro Ayora', FALSE),
    (provincia_id, 'EC-P-10-C-13', 'CANTON', 'Lomas de Sargentillo', FALSE),
    (provincia_id, 'EC-P-10-C-14', 'CANTON', 'Milagro', FALSE),
    (provincia_id, 'EC-P-10-C-15', 'CANTON', 'Naranjal', FALSE),
    (provincia_id, 'EC-P-10-C-16', 'CANTON', 'Naranjito', FALSE),
    (provincia_id, 'EC-P-10-C-17', 'CANTON', 'Palestina', FALSE),
    (provincia_id, 'EC-P-10-C-18', 'CANTON', 'Pedro Carbo', FALSE),
    (provincia_id, 'EC-P-10-C-19', 'CANTON', 'Playas', FALSE),
    (provincia_id, 'EC-P-10-C-20', 'CANTON', 'Salitre', FALSE),
    (provincia_id, 'EC-P-10-C-21', 'CANTON', 'Samborondón', FALSE),
    (provincia_id, 'EC-P-10-C-22', 'CANTON', 'Santa Lucía', FALSE),
    (provincia_id, 'EC-P-10-C-23', 'CANTON', 'Simón Bolívar', FALSE),
    (provincia_id, 'EC-P-10-C-24', 'CANTON', 'Yaguachi', FALSE),
    (provincia_id, 'EC-P-10-C-25', 'CANTON', 'Jujan', FALSE);
END $$;

-- IMBABURA (6 cantones) [citation:3][citation:8]
DO $$
DECLARE
    provincia_id BIGINT;
BEGIN
    SELECT id INTO provincia_id FROM core.ubicaciones WHERE codigo = 'EC-P-11';
    
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre, capital) VALUES
    (provincia_id, 'EC-P-11-C-01', 'CANTON', 'Ibarra', TRUE),
    (provincia_id, 'EC-P-11-C-02', 'CANTON', 'Antonio Ante', FALSE),
    (provincia_id, 'EC-P-11-C-03', 'CANTON', 'Cotacachi', FALSE),
    (provincia_id, 'EC-P-11-C-04', 'CANTON', 'Otavalo', FALSE),
    (provincia_id, 'EC-P-11-C-05', 'CANTON', 'Pimampiro', FALSE),
    (provincia_id, 'EC-P-11-C-06', 'CANTON', 'San Miguel de Urcuquí', FALSE);
END $$;

-- LOJA (16 cantones) [citation:3][citation:8]
DO $$
DECLARE
    provincia_id BIGINT;
BEGIN
    SELECT id INTO provincia_id FROM core.ubicaciones WHERE codigo = 'EC-P-12';
    
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre, capital) VALUES
    (provincia_id, 'EC-P-12-C-01', 'CANTON', 'Loja', TRUE),
    (provincia_id, 'EC-P-12-C-02', 'CANTON', 'Calvas', FALSE),
    (provincia_id, 'EC-P-12-C-03', 'CANTON', 'Catamayo', FALSE),
    (provincia_id, 'EC-P-12-C-04', 'CANTON', 'Celica', FALSE),
    (provincia_id, 'EC-P-12-C-05', 'CANTON', 'Chaguarpamba', FALSE),
    (provincia_id, 'EC-P-12-C-06', 'CANTON', 'Espíndola', FALSE),
    (provincia_id, 'EC-P-12-C-07', 'CANTON', 'Gonzanamá', FALSE),
    (provincia_id, 'EC-P-12-C-08', 'CANTON', 'Macará', FALSE),
    (provincia_id, 'EC-P-12-C-09', 'CANTON', 'Olmedo', FALSE),
    (provincia_id, 'EC-P-12-C-10', 'CANTON', 'Paltas', FALSE),
    (provincia_id, 'EC-P-12-C-11', 'CANTON', 'Pindal', FALSE),
    (provincia_id, 'EC-P-12-C-12', 'CANTON', 'Puyango', FALSE),
    (provincia_id, 'EC-P-12-C-13', 'CANTON', 'Quilanga', FALSE),
    (provincia_id, 'EC-P-12-C-14', 'CANTON', 'Saraguro', FALSE),
    (provincia_id, 'EC-P-12-C-15', 'CANTON', 'Sozoranga', FALSE),
    (provincia_id, 'EC-P-12-C-16', 'CANTON', 'Zapotillo', FALSE);
END $$;

-- LOS RÍOS (13 cantones) [citation:3][citation:8]
DO $$
DECLARE
    provincia_id BIGINT;
BEGIN
    SELECT id INTO provincia_id FROM core.ubicaciones WHERE codigo = 'EC-P-13';
    
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre, capital) VALUES
    (provincia_id, 'EC-P-13-C-01', 'CANTON', 'Babahoyo', TRUE),
    (provincia_id, 'EC-P-13-C-02', 'CANTON', 'Baba', FALSE),
    (provincia_id, 'EC-P-13-C-03', 'CANTON', 'Buena Fe', FALSE),
    (provincia_id, 'EC-P-13-C-04', 'CANTON', 'Mocache', FALSE),
    (provincia_id, 'EC-P-13-C-05', 'CANTON', 'Montalvo', FALSE),
    (provincia_id, 'EC-P-13-C-06', 'CANTON', 'Palenque', FALSE),
    (provincia_id, 'EC-P-13-C-07', 'CANTON', 'Puebloviejo', FALSE),
    (provincia_id, 'EC-P-13-C-08', 'CANTON', 'Quevedo', FALSE),
    (provincia_id, 'EC-P-13-C-09', 'CANTON', 'Quinsaloma', FALSE),
    (provincia_id, 'EC-P-13-C-10', 'CANTON', 'Urdaneta', FALSE),
    (provincia_id, 'EC-P-13-C-11', 'CANTON', 'Valencia', FALSE),
    (provincia_id, 'EC-P-13-C-12', 'CANTON', 'Ventanas', FALSE),
    (provincia_id, 'EC-P-13-C-13', 'CANTON', 'Vinces', FALSE);
END $$;

-- MANABÍ (22 cantones) [citation:3][citation:8]
DO $$
DECLARE
    provincia_id BIGINT;
BEGIN
    SELECT id INTO provincia_id FROM core.ubicaciones WHERE codigo = 'EC-P-14';
    
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre, capital) VALUES
    (provincia_id, 'EC-P-14-C-01', 'CANTON', 'Portoviejo', TRUE),
    (provincia_id, 'EC-P-14-C-02', 'CANTON', 'Bolívar', FALSE),
    (provincia_id, 'EC-P-14-C-03', 'CANTON', 'Chone', FALSE),
    (provincia_id, 'EC-P-14-C-04', 'CANTON', 'El Carmen', FALSE),
    (provincia_id, 'EC-P-14-C-05', 'CANTON', 'Flavio Alfaro', FALSE),
    (provincia_id, 'EC-P-14-C-06', 'CANTON', 'Jama', FALSE),
    (provincia_id, 'EC-P-14-C-07', 'CANTON', 'Jaramijó', FALSE),
    (provincia_id, 'EC-P-14-C-08', 'CANTON', 'Jipijapa', FALSE),
    (provincia_id, 'EC-P-14-C-09', 'CANTON', 'Junín', FALSE),
    (provincia_id, 'EC-P-14-C-10', 'CANTON', 'Manta', FALSE),
    (provincia_id, 'EC-P-14-C-11', 'CANTON', 'Montecristi', FALSE),
    (provincia_id, 'EC-P-14-C-12', 'CANTON', 'Olmedo', FALSE),
    (provincia_id, 'EC-P-14-C-13', 'CANTON', 'Paján', FALSE),
    (provincia_id, 'EC-P-14-C-14', 'CANTON', 'Pedernales', FALSE),
    (provincia_id, 'EC-P-14-C-15', 'CANTON', 'Pichincha', FALSE),
    (provincia_id, 'EC-P-14-C-16', 'CANTON', 'Puerto López', FALSE),
    (provincia_id, 'EC-P-14-C-17', 'CANTON', 'Rocafuerte', FALSE),
    (provincia_id, 'EC-P-14-C-18', 'CANTON', 'San Vicente', FALSE),
    (provincia_id, 'EC-P-14-C-19', 'CANTON', 'Santa Ana', FALSE),
    (provincia_id, 'EC-P-14-C-20', 'CANTON', 'Sucre', FALSE),
    (provincia_id, 'EC-P-14-C-21', 'CANTON', 'Tosagua', FALSE),
    (provincia_id, 'EC-P-14-C-22', 'CANTON', 'Veinticuatro de Mayo', FALSE);
END $$;

-- MORONA SANTIAGO (13 cantones) [citation:3][citation:8]
DO $$
DECLARE
    provincia_id BIGINT;
BEGIN
    SELECT id INTO provincia_id FROM core.ubicaciones WHERE codigo = 'EC-P-15';
    
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre, capital) VALUES
    (provincia_id, 'EC-P-15-C-01', 'CANTON', 'Macas', TRUE),
    (provincia_id, 'EC-P-15-C-02', 'CANTON', 'Gualaquiza', FALSE),
    (provincia_id, 'EC-P-15-C-03', 'CANTON', 'Huamboya', FALSE),
    (provincia_id, 'EC-P-15-C-04', 'CANTON', 'Limón Indanza', FALSE),
    (provincia_id, 'EC-P-15-C-05', 'CANTON', 'Logroño', FALSE),
    (provincia_id, 'EC-P-15-C-06', 'CANTON', 'Morona', FALSE),
    (provincia_id, 'EC-P-15-C-07', 'CANTON', 'Pablo Sexto', FALSE),
    (provincia_id, 'EC-P-15-C-08', 'CANTON', 'Palora', FALSE),
    (provincia_id, 'EC-P-15-C-09', 'CANTON', 'San Juan Bosco', FALSE),
    (provincia_id, 'EC-P-15-C-10', 'CANTON', 'Santiago de Méndez', FALSE),
    (provincia_id, 'EC-P-15-C-11', 'CANTON', 'Sucúa', FALSE),
    (provincia_id, 'EC-P-15-C-12', 'CANTON', 'Taisha', FALSE),
    (provincia_id, 'EC-P-15-C-13', 'CANTON', 'Tiwintza', FALSE);
END $$;

-- NAPO (5 cantones) [citation:3][citation:8]
DO $$
DECLARE
    provincia_id BIGINT;
BEGIN
    SELECT id INTO provincia_id FROM core.ubicaciones WHERE codigo = 'EC-P-16';
    
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre, capital) VALUES
    (provincia_id, 'EC-P-16-C-01', 'CANTON', 'Tena', TRUE),
    (provincia_id, 'EC-P-16-C-02', 'CANTON', 'Archidona', FALSE),
    (provincia_id, 'EC-P-16-C-03', 'CANTON', 'Carlos Julio Arosemena Tola', FALSE),
    (provincia_id, 'EC-P-16-C-04', 'CANTON', 'El Chaco', FALSE),
    (provincia_id, 'EC-P-16-C-05', 'CANTON', 'Quijos', FALSE);
END $$;

-- ORELLANA (4 cantones) [citation:3][citation:8]
DO $$
DECLARE
    provincia_id BIGINT;
BEGIN
    SELECT id INTO provincia_id FROM core.ubicaciones WHERE codigo = 'EC-P-17';
    
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre, capital) VALUES
    (provincia_id, 'EC-P-17-C-01', 'CANTON', 'Francisco de Orellana', TRUE),
    (provincia_id, 'EC-P-17-C-02', 'CANTON', 'Aguarico', FALSE),
    (provincia_id, 'EC-P-17-C-03', 'CANTON', 'La Joya de los Sachas', FALSE),
    (provincia_id, 'EC-P-17-C-04', 'CANTON', 'Loreto', FALSE);
END $$;

-- PASTAZA (4 cantones) [citation:3][citation:8]
DO $$
DECLARE
    provincia_id BIGINT;
BEGIN
    SELECT id INTO provincia_id FROM core.ubicaciones WHERE codigo = 'EC-P-18';
    
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre, capital) VALUES
    (provincia_id, 'EC-P-18-C-01', 'CANTON', 'Puyo', TRUE),
    (provincia_id, 'EC-P-18-C-02', 'CANTON', 'Arajuno', FALSE),
    (provincia_id, 'EC-P-18-C-03', 'CANTON', 'Mera', FALSE),
    (provincia_id, 'EC-P-18-C-04', 'CANTON', 'Santa Clara', FALSE);
END $$;

-- PICHINCHA (8 cantones) [citation:3][citation:8]
DO $$
DECLARE
    provincia_id BIGINT;
BEGIN
    SELECT id INTO provincia_id FROM core.ubicaciones WHERE codigo = 'EC-P-19';
    
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre, capital) VALUES
    (provincia_id, 'EC-P-19-C-01', 'CANTON', 'Quito', TRUE),
    (provincia_id, 'EC-P-19-C-02', 'CANTON', 'Cayambe', FALSE),
    (provincia_id, 'EC-P-19-C-03', 'CANTON', 'Mejía', FALSE),
    (provincia_id, 'EC-P-19-C-04', 'CANTON', 'Pedro Moncayo', FALSE),
    (provincia_id, 'EC-P-19-C-05', 'CANTON', 'Rumiñahui', FALSE),
    (provincia_id, 'EC-P-19-C-06', 'CANTON', 'San Miguel de los Bancos', FALSE),
    (provincia_id, 'EC-P-19-C-07', 'CANTON', 'Pedro Vicente Maldonado', FALSE),
    (provincia_id, 'EC-P-19-C-08', 'CANTON', 'Puerto Quito', FALSE);
END $$;

-- SANTA ELENA (3 cantones) [citation:3][citation:8]
DO $$
DECLARE
    provincia_id BIGINT;
BEGIN
    SELECT id INTO provincia_id FROM core.ubicaciones WHERE codigo = 'EC-P-20';
    
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre, capital) VALUES
    (provincia_id, 'EC-P-20-C-01', 'CANTON', 'Santa Elena', TRUE),
    (provincia_id, 'EC-P-20-C-02', 'CANTON', 'La Libertad', FALSE),
    (provincia_id, 'EC-P-20-C-03', 'CANTON', 'Salinas', FALSE);
END $$;

-- SANTO DOMINGO DE LOS TSÁCHILAS (2 cantones) [citation:3][citation:8]
DO $$
DECLARE
    provincia_id BIGINT;
BEGIN
    SELECT id INTO provincia_id FROM core.ubicaciones WHERE codigo = 'EC-P-21';
    
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre, capital) VALUES
    (provincia_id, 'EC-P-21-C-01', 'CANTON', 'Santo Domingo', TRUE),
    (provincia_id, 'EC-P-21-C-02', 'CANTON', 'La Concordia', FALSE);
END $$;

-- SUCUMBÍOS (7 cantones) [citation:1][citation:3]
DO $$
DECLARE
    provincia_id BIGINT;
BEGIN
    SELECT id INTO provincia_id FROM core.ubicaciones WHERE codigo = 'EC-P-22';
    
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre, capital) VALUES
    (provincia_id, 'EC-P-22-C-01', 'CANTON', 'Nueva Loja', TRUE),
    (provincia_id, 'EC-P-22-C-02', 'CANTON', 'Cascales', FALSE),
    (provincia_id, 'EC-P-22-C-03', 'CANTON', 'Cuyabeno', FALSE),
    (provincia_id, 'EC-P-22-C-04', 'CANTON', 'Gonzalo Pizarro', FALSE),
    (provincia_id, 'EC-P-22-C-05', 'CANTON', 'Lago Agrio', FALSE),
    (provincia_id, 'EC-P-22-C-06', 'CANTON', 'Putumayo', FALSE),
    (provincia_id, 'EC-P-22-C-07', 'CANTON', 'Shushufindi', FALSE);
END $$;

-- TUNGURAHUA (9 cantones) [citation:3][citation:8]
DO $$
DECLARE
    provincia_id BIGINT;
BEGIN
    SELECT id INTO provincia_id FROM core.ubicaciones WHERE codigo = 'EC-P-23';
    
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre, capital) VALUES
    (provincia_id, 'EC-P-23-C-01', 'CANTON', 'Ambato', TRUE),
    (provincia_id, 'EC-P-23-C-02', 'CANTON', 'Baños de Agua Santa', FALSE),
    (provincia_id, 'EC-P-23-C-03', 'CANTON', 'Cevallos', FALSE),
    (provincia_id, 'EC-P-23-C-04', 'CANTON', 'Mocha', FALSE),
    (provincia_id, 'EC-P-23-C-05', 'CANTON', 'Patate', FALSE),
    (provincia_id, 'EC-P-23-C-06', 'CANTON', 'Pelileo', FALSE),
    (provincia_id, 'EC-P-23-C-07', 'CANTON', 'Píllaro', FALSE),
    (provincia_id, 'EC-P-23-C-08', 'CANTON', 'Quero', FALSE),
    (provincia_id, 'EC-P-23-C-09', 'CANTON', 'Tisaleo', FALSE);
END $$;

-- ZAMORA CHINCHIPE (9 cantones) [citation:3][citation:8]
DO $$
DECLARE
    provincia_id BIGINT;
BEGIN
    SELECT id INTO provincia_id FROM core.ubicaciones WHERE codigo = 'EC-P-24';
    
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre, capital) VALUES
    (provincia_id, 'EC-P-24-C-01', 'CANTON', 'Zamora', TRUE),
    (provincia_id, 'EC-P-24-C-02', 'CANTON', 'Centinela del Cóndor', FALSE),
    (provincia_id, 'EC-P-24-C-03', 'CANTON', 'Chinchipe', FALSE),
    (provincia_id, 'EC-P-24-C-04', 'CANTON', 'El Pangui', FALSE),
    (provincia_id, 'EC-P-24-C-05', 'CANTON', 'Nangaritza', FALSE),
    (provincia_id, 'EC-P-24-C-06', 'CANTON', 'Palanda', FALSE),
    (provincia_id, 'EC-P-24-C-07', 'CANTON', 'Paquisha', FALSE),
    (provincia_id, 'EC-P-24-C-08', 'CANTON', 'Yacuambi', FALSE),
    (provincia_id, 'EC-P-24-C-09', 'CANTON', 'Yanzatza', FALSE);
END $$;



-- =====================================================
-- SCRIPT COMPLETO: PARROQUIAS DE TODOS LOS CANTONES DE ECUADOR
-- =====================================================

DO $$
DECLARE
    v_canton_id BIGINT;
BEGIN

    -- =====================================================
    -- 1. AZUY - 15 CANTONES
    -- =====================================================
    
    -- Cantón: CUENCA
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-01-C-01';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-01-C-01-P-01', 'PARROQUIA', 'Bellavista'),
    (v_canton_id, 'EC-P-01-C-01-P-02', 'PARROQUIA', 'Cañaribamba'),
    (v_canton_id, 'EC-P-01-C-01-P-03', 'PARROQUIA', 'El Batán'),
    (v_canton_id, 'EC-P-01-C-01-P-04', 'PARROQUIA', 'El Sagrario'),
    (v_canton_id, 'EC-P-01-C-01-P-05', 'PARROQUIA', 'El Vecino'),
    (v_canton_id, 'EC-P-01-C-01-P-06', 'PARROQUIA', 'Gil Ramírez Dávalos'),
    (v_canton_id, 'EC-P-01-C-01-P-07', 'PARROQUIA', 'Hermano Miguel'),
    (v_canton_id, 'EC-P-01-C-01-P-08', 'PARROQUIA', 'Huayna Cápac'),
    (v_canton_id, 'EC-P-01-C-01-P-09', 'PARROQUIA', 'Machángara'),
    (v_canton_id, 'EC-P-01-C-01-P-10', 'PARROQUIA', 'Monay'),
    (v_canton_id, 'EC-P-01-C-01-P-11', 'PARROQUIA', 'San Blas'),
    (v_canton_id, 'EC-P-01-C-01-P-12', 'PARROQUIA', 'San Sebastián'),
    (v_canton_id, 'EC-P-01-C-01-P-13', 'PARROQUIA', 'Sucre'),
    (v_canton_id, 'EC-P-01-C-01-P-14', 'PARROQUIA', 'Totoracocha'),
    (v_canton_id, 'EC-P-01-C-01-P-15', 'PARROQUIA', 'Yanuncay'),
    (v_canton_id, 'EC-P-01-C-01-P-16', 'PARROQUIA', 'Baños'),
    (v_canton_id, 'EC-P-01-C-01-P-17', 'PARROQUIA', 'Cumbe'),
    (v_canton_id, 'EC-P-01-C-01-P-18', 'PARROQUIA', 'Chaucha'),
    (v_canton_id, 'EC-P-01-C-01-P-19', 'PARROQUIA', 'Checa'),
    (v_canton_id, 'EC-P-01-C-01-P-20', 'PARROQUIA', 'Chiquintad'),
    (v_canton_id, 'EC-P-01-C-01-P-21', 'PARROQUIA', 'Llacao'),
    (v_canton_id, 'EC-P-01-C-01-P-22', 'PARROQUIA', 'Molleturo'),
    (v_canton_id, 'EC-P-01-C-01-P-23', 'PARROQUIA', 'Nulti'),
    (v_canton_id, 'EC-P-01-C-01-P-24', 'PARROQUIA', 'Octavio Cordero'),
    (v_canton_id, 'EC-P-01-C-01-P-25', 'PARROQUIA', 'Paccha'),
    (v_canton_id, 'EC-P-01-C-01-P-26', 'PARROQUIA', 'Quingeo'),
    (v_canton_id, 'EC-P-01-C-01-P-27', 'PARROQUIA', 'Ricaurte'),
    (v_canton_id, 'EC-P-01-C-01-P-28', 'PARROQUIA', 'San Joaquín'),
    (v_canton_id, 'EC-P-01-C-01-P-29', 'PARROQUIA', 'Santa Ana'),
    (v_canton_id, 'EC-P-01-C-01-P-30', 'PARROQUIA', 'Sayausí'),
    (v_canton_id, 'EC-P-01-C-01-P-31', 'PARROQUIA', 'Sidcay'),
    (v_canton_id, 'EC-P-01-C-01-P-32', 'PARROQUIA', 'Sinincay'),
    (v_canton_id, 'EC-P-01-C-01-P-33', 'PARROQUIA', 'Tarqui'),
    (v_canton_id, 'EC-P-01-C-01-P-34', 'PARROQUIA', 'Turi'),
    (v_canton_id, 'EC-P-01-C-01-P-35', 'PARROQUIA', 'Valle'),
    (v_canton_id, 'EC-P-01-C-01-P-36', 'PARROQUIA', 'Victoria del Portete');
    
    -- Cantón: GIRÓN
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-01-C-05';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-01-C-05-P-01', 'PARROQUIA', 'Girón'),
    (v_canton_id, 'EC-P-01-C-05-P-02', 'PARROQUIA', 'Asunción'),
    (v_canton_id, 'EC-P-01-C-05-P-03', 'PARROQUIA', 'San Gerardo');
    
    -- Cantón: GUALACEO
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-01-C-07';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-01-C-07-P-01', 'PARROQUIA', 'Gualaceo'),
    (v_canton_id, 'EC-P-01-C-07-P-02', 'PARROQUIA', 'Daniel Córdova'),
    (v_canton_id, 'EC-P-01-C-07-P-03', 'PARROQUIA', 'Jadán'),
    (v_canton_id, 'EC-P-01-C-07-P-04', 'PARROQUIA', 'Mariano Moreno'),
    (v_canton_id, 'EC-P-01-C-07-P-05', 'PARROQUIA', 'Remigio Crespo'),
    (v_canton_id, 'EC-P-01-C-07-P-06', 'PARROQUIA', 'San Juan'),
    (v_canton_id, 'EC-P-01-C-07-P-07', 'PARROQUIA', 'Zhín');
    
    -- Cantón: PAUTE
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-01-C-10';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-01-C-10-P-01', 'PARROQUIA', 'Paute'),
    (v_canton_id, 'EC-P-01-C-10-P-02', 'PARROQUIA', 'Bulán'),
    (v_canton_id, 'EC-P-01-C-10-P-03', 'PARROQUIA', 'Chicán'),
    (v_canton_id, 'EC-P-01-C-10-P-04', 'PARROQUIA', 'Dug Dug'),
    (v_canton_id, 'EC-P-01-C-10-P-05', 'PARROQUIA', 'Guachapala'),
    (v_canton_id, 'EC-P-01-C-10-P-06', 'PARROQUIA', 'San Cristóbal'),
    (v_canton_id, 'EC-P-01-C-10-P-07', 'PARROQUIA', 'Tomebamba');
    
    -- Cantón: SIGSIG
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-01-C-14';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-01-C-14-P-01', 'PARROQUIA', 'Sigsig'),
    (v_canton_id, 'EC-P-01-C-14-P-02', 'PARROQUIA', 'Cuchil'),
    (v_canton_id, 'EC-P-01-C-14-P-03', 'PARROQUIA', 'Jima'),
    (v_canton_id, 'EC-P-01-C-14-P-04', 'PARROQUIA', 'Ludo'),
    (v_canton_id, 'EC-P-01-C-14-P-05', 'PARROQUIA', 'San Bartolomé'),
    (v_canton_id, 'EC-P-01-C-14-P-06', 'PARROQUIA', 'San José de Raranga');
    
    -- Cantón: SANTA ISABEL
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-01-C-13';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-01-C-13-P-01', 'PARROQUIA', 'Santa Isabel'),
    (v_canton_id, 'EC-P-01-C-13-P-02', 'PARROQUIA', 'Abdón Calderón'),
    (v_canton_id, 'EC-P-01-C-13-P-03', 'PARROQUIA', 'El Carmen de Pijilí'),
    (v_canton_id, 'EC-P-01-C-13-P-04', 'PARROQUIA', 'La Unión'),
    (v_canton_id, 'EC-P-01-C-13-P-05', 'PARROQUIA', 'Zhaglli');
    
    -- Cantón: CHORDELEG
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-01-C-03';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-01-C-03-P-01', 'PARROQUIA', 'Chordeleg'),
    (v_canton_id, 'EC-P-01-C-03-P-02', 'PARROQUIA', 'La Unión'),
    (v_canton_id, 'EC-P-01-C-03-P-03', 'PARROQUIA', 'Principal'),
    (v_canton_id, 'EC-P-01-C-03-P-04', 'PARROQUIA', 'San Martín de Puzhio');
    
    -- Cantón: EL PAN
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-01-C-04';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-01-C-04-P-01', 'PARROQUIA', 'El Pan'),
    (v_canton_id, 'EC-P-01-C-04-P-02', 'PARROQUIA', 'San Vicente');
    
    -- Cantón: GUACHAPALA
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-01-C-06';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-01-C-06-P-01', 'PARROQUIA', 'Guachapala');
    
    -- Cantón: NABÓN
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-01-C-08';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-01-C-08-P-01', 'PARROQUIA', 'Nabón'),
    (v_canton_id, 'EC-P-01-C-08-P-02', 'PARROQUIA', 'Cochapata'),
    (v_canton_id, 'EC-P-01-C-08-P-03', 'PARROQUIA', 'El Progreso'),
    (v_canton_id, 'EC-P-01-C-08-P-04', 'PARROQUIA', 'Las Nieves');
    
    -- Cantón: OÑA
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-01-C-09';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-01-C-09-P-01', 'PARROQUIA', 'Oña'),
    (v_canton_id, 'EC-P-01-C-09-P-02', 'PARROQUIA', 'Susudel');
    
    -- Cantón: PUCARÁ
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-01-C-11';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-01-C-11-P-01', 'PARROQUIA', 'Pucará'),
    (v_canton_id, 'EC-P-01-C-11-P-02', 'PARROQUIA', 'San Rafael de Sharug');
    
    -- Cantón: SAN FERNANDO
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-01-C-12';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-01-C-12-P-01', 'PARROQUIA', 'San Fernando'),
    (v_canton_id, 'EC-P-01-C-12-P-02', 'PARROQUIA', 'Chumblín');
    
    -- Cantón: SEVILLA DE ORO
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-01-C-15';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-01-C-15-P-01', 'PARROQUIA', 'Sevilla de Oro'),
    (v_canton_id, 'EC-P-01-C-15-P-02', 'PARROQUIA', 'Palmas');
    
    -- Cantón: CAMILO PONCE ENRÍQUEZ
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-01-C-02';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-01-C-02-P-01', 'PARROQUIA', 'Camilo Ponce Enríquez'),
    (v_canton_id, 'EC-P-01-C-02-P-02', 'PARROQUIA', 'El Carmen de Pijilí');

    -- =====================================================
    -- 2. BOLÍVAR - 7 CANTONES
    -- =====================================================
    
    -- Cantón: GUARANDA
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-02-C-01';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-02-C-01-P-01', 'PARROQUIA', 'Guaranda'),
    (v_canton_id, 'EC-P-02-C-01-P-02', 'PARROQUIA', 'Ángel Polibio Chaves'),
    (v_canton_id, 'EC-P-02-C-01-P-03', 'PARROQUIA', 'Gabriel Ignacio Veintimilla'),
    (v_canton_id, 'EC-P-02-C-01-P-04', 'PARROQUIA', 'Guanujo'),
    (v_canton_id, 'EC-P-02-C-01-P-05', 'PARROQUIA', 'Julio E. Moreno'),
    (v_canton_id, 'EC-P-02-C-01-P-06', 'PARROQUIA', 'Las Naves'),
    (v_canton_id, 'EC-P-02-C-01-P-07', 'PARROQUIA', 'Salinas'),
    (v_canton_id, 'EC-P-02-C-01-P-08', 'PARROQUIA', 'San Lorenzo'),
    (v_canton_id, 'EC-P-02-C-01-P-09', 'PARROQUIA', 'San Simón'),
    (v_canton_id, 'EC-P-02-C-01-P-10', 'PARROQUIA', 'Santa Fé');
    
    -- Cantón: CALUMA
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-02-C-02';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-02-C-02-P-01', 'PARROQUIA', 'Caluma'),
    (v_canton_id, 'EC-P-02-C-02-P-02', 'PARROQUIA', 'El Vergel');
    
    -- Cantón: CHILLANES
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-02-C-03';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-02-C-03-P-01', 'PARROQUIA', 'Chillanes'),
    (v_canton_id, 'EC-P-02-C-03-P-02', 'PARROQUIA', 'San José del Tambo');
    
    -- Cantón: CHIMBO
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-02-C-04';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-02-C-04-P-01', 'PARROQUIA', 'Chimbo'),
    (v_canton_id, 'EC-P-02-C-04-P-02', 'PARROQUIA', 'Asunción'),
    (v_canton_id, 'EC-P-02-C-04-P-03', 'PARROQUIA', 'Cochapamba'),
    (v_canton_id, 'EC-P-02-C-04-P-04', 'PARROQUIA', 'Magdalena'),
    (v_canton_id, 'EC-P-02-C-04-P-05', 'PARROQUIA', 'San Sebastián');
    
    -- Cantón: ECHEANDÍA
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-02-C-05';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-02-C-05-P-01', 'PARROQUIA', 'Echeandía'),
    (v_canton_id, 'EC-P-02-C-05-P-02', 'PARROQUIA', 'San Miguel de Echeandía');
    
    -- Cantón: LAS NAVES
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-02-C-06';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-02-C-06-P-01', 'PARROQUIA', 'Las Naves'),
    (v_canton_id, 'EC-P-02-C-06-P-02', 'PARROQUIA', 'Las Mercedes');
    
    -- Cantón: SAN MIGUEL
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-02-C-07';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-02-C-07-P-01', 'PARROQUIA', 'San Miguel'),
    (v_canton_id, 'EC-P-02-C-07-P-02', 'PARROQUIA', 'Balsapamba'),
    (v_canton_id, 'EC-P-02-C-07-P-03', 'PARROQUIA', 'Bilován'),
    (v_canton_id, 'EC-P-02-C-07-P-04', 'PARROQUIA', 'Regulo de Mora'),
    (v_canton_id, 'EC-P-02-C-07-P-05', 'PARROQUIA', 'San Pablo de Atenas'),
    (v_canton_id, 'EC-P-02-C-07-P-06', 'PARROQUIA', 'Santiago de Quito');

    -- =====================================================
    -- 3. CAÑAR - 7 CANTONES
    -- =====================================================
    
    -- Cantón: AZOGUES
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-03-C-01';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-03-C-01-P-01', 'PARROQUIA', 'Azogues'),
    (v_canton_id, 'EC-P-03-C-01-P-02', 'PARROQUIA', 'Bayas'),
    (v_canton_id, 'EC-P-03-C-01-P-03', 'PARROQUIA', 'Cojitambo'),
    (v_canton_id, 'EC-P-03-C-01-P-04', 'PARROQUIA', 'Guapán'),
    (v_canton_id, 'EC-P-03-C-01-P-05', 'PARROQUIA', 'San Francisco'),
    (v_canton_id, 'EC-P-03-C-01-P-06', 'PARROQUIA', 'Solano'),
    (v_canton_id, 'EC-P-03-C-01-P-07', 'PARROQUIA', 'Taday');
    
    -- Cantón: BIBLIÁN
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-03-C-02';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-03-C-02-P-01', 'PARROQUIA', 'Biblián'),
    (v_canton_id, 'EC-P-03-C-02-P-02', 'PARROQUIA', 'Jerusalén'),
    (v_canton_id, 'EC-P-03-C-02-P-03', 'PARROQUIA', 'Nazón'),
    (v_canton_id, 'EC-P-03-C-02-P-04', 'PARROQUIA', 'San José de Tambo');
    
    -- Cantón: CAÑAR
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-03-C-03';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-03-C-03-P-01', 'PARROQUIA', 'Cañar'),
    (v_canton_id, 'EC-P-03-C-03-P-02', 'PARROQUIA', 'Chontamarca'),
    (v_canton_id, 'EC-P-03-C-03-P-03', 'PARROQUIA', 'Chorocopte'),
    (v_canton_id, 'EC-P-03-C-03-P-04', 'PARROQUIA', 'Duraznos'),
    (v_canton_id, 'EC-P-03-C-03-P-05', 'PARROQUIA', 'General Morales'),
    (v_canton_id, 'EC-P-03-C-03-P-06', 'PARROQUIA', 'Gualleturo'),
    (v_canton_id, 'EC-P-03-C-03-P-07', 'PARROQUIA', 'Honorato Vásquez'),
    (v_canton_id, 'EC-P-03-C-03-P-08', 'PARROQUIA', 'Ingapirca'),
    (v_canton_id, 'EC-P-03-C-03-P-09', 'PARROQUIA', 'Juncal'),
    (v_canton_id, 'EC-P-03-C-03-P-10', 'PARROQUIA', 'San Antonio'),
    (v_canton_id, 'EC-P-03-C-03-P-11', 'PARROQUIA', 'Ventanas');
    
    -- Cantón: DÉLEG
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-03-C-04';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-03-C-04-P-01', 'PARROQUIA', 'Déleg'),
    (v_canton_id, 'EC-P-03-C-04-P-02', 'PARROQUIA', 'Solano');
    
    -- Cantón: EL TAMBO
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-03-C-05';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-03-C-05-P-01', 'PARROQUIA', 'El Tambo'),
    (v_canton_id, 'EC-P-03-C-05-P-02', 'PARROQUIA', 'Zhud');
    
    -- Cantón: LA TRONCAL
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-03-C-06';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-03-C-06-P-01', 'PARROQUIA', 'La Troncal'),
    (v_canton_id, 'EC-P-03-C-06-P-02', 'PARROQUIA', 'Manuel J. Calle');
    
    -- Cantón: SUSCAL
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-03-C-07';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-03-C-07-P-01', 'PARROQUIA', 'Suscal'),
    (v_canton_id, 'EC-P-03-C-07-P-02', 'PARROQUIA', 'Carlos Ordóñez');

    -- =====================================================
    -- 4. CARCHI - 6 CANTONES
    -- =====================================================
    
    -- Cantón: TULCÁN
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-04-C-01';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-04-C-01-P-01', 'PARROQUIA', 'Tulcán'),
    (v_canton_id, 'EC-P-04-C-01-P-02', 'PARROQUIA', 'El Carmelo'),
    (v_canton_id, 'EC-P-04-C-01-P-03', 'PARROQUIA', 'Julio Andrade'),
    (v_canton_id, 'EC-P-04-C-01-P-04', 'PARROQUIA', 'Maldonado'),
    (v_canton_id, 'EC-P-04-C-01-P-05', 'PARROQUIA', 'Pioter'),
    (v_canton_id, 'EC-P-04-C-01-P-06', 'PARROQUIA', 'Santa Martha de Cuba'),
    (v_canton_id, 'EC-P-04-C-01-P-07', 'PARROQUIA', 'Tobar Donoso'),
    (v_canton_id, 'EC-P-04-C-01-P-08', 'PARROQUIA', 'Tufiño'),
    (v_canton_id, 'EC-P-04-C-01-P-09', 'PARROQUIA', 'Urbina');
    
    -- Cantón: BOLÍVAR
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-04-C-02';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-04-C-02-P-01', 'PARROQUIA', 'Bolívar'),
    (v_canton_id, 'EC-P-04-C-02-P-02', 'PARROQUIA', 'García Moreno'),
    (v_canton_id, 'EC-P-04-C-02-P-03', 'PARROQUIA', 'Los Andes');
    
    -- Cantón: ESPEJO
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-04-C-03';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-04-C-03-P-01', 'PARROQUIA', 'El Ángel'),
    (v_canton_id, 'EC-P-04-C-03-P-02', 'PARROQUIA', 'El Goaltal'),
    (v_canton_id, 'EC-P-04-C-03-P-03', 'PARROQUIA', 'La Libertad'),
    (v_canton_id, 'EC-P-04-C-03-P-04', 'PARROQUIA', 'San Isidro');
    
    -- Cantón: MIRA
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-04-C-04';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-04-C-04-P-01', 'PARROQUIA', 'Mira'),
    (v_canton_id, 'EC-P-04-C-04-P-02', 'PARROQUIA', 'Concepción'),
    (v_canton_id, 'EC-P-04-C-04-P-03', 'PARROQUIA', 'Jijón y Caamaño'),
    (v_canton_id, 'EC-P-04-C-04-P-04', 'PARROQUIA', 'Juan Montalvo');
    
    -- Cantón: MONTÚFAR
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-04-C-05';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-04-C-05-P-01', 'PARROQUIA', 'San Gabriel'),
    (v_canton_id, 'EC-P-04-C-05-P-02', 'PARROQUIA', 'Cristóbal Colón'),
    (v_canton_id, 'EC-P-04-C-05-P-03', 'PARROQUIA', 'Chitán de Navarretes'),
    (v_canton_id, 'EC-P-04-C-05-P-04', 'PARROQUIA', 'Fernández Salvador'),
    (v_canton_id, 'EC-P-04-C-05-P-05', 'PARROQUIA', 'La Paz'),
    (v_canton_id, 'EC-P-04-C-05-P-06', 'PARROQUIA', 'Piartal');
    
    -- Cantón: SAN PEDRO DE HUACA
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-04-C-06';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-04-C-06-P-01', 'PARROQUIA', 'Huaca'),
    (v_canton_id, 'EC-P-04-C-06-P-02', 'PARROQUIA', 'Mariscal Sucre');

    -- =====================================================
    -- 5. CHIMBORAZO - 10 CANTONES
    -- =====================================================
    
    -- Cantón: RIOBAMBA
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-05-C-01';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-05-C-01-P-01', 'PARROQUIA', 'Riobamba'),
    (v_canton_id, 'EC-P-05-C-01-P-02', 'PARROQUIA', 'Cacha'),
    (v_canton_id, 'EC-P-05-C-01-P-03', 'PARROQUIA', 'Calpi'),
    (v_canton_id, 'EC-P-05-C-01-P-04', 'PARROQUIA', 'Cubijíes'),
    (v_canton_id, 'EC-P-05-C-01-P-05', 'PARROQUIA', 'Flores'),
    (v_canton_id, 'EC-P-05-C-01-P-06', 'PARROQUIA', 'Licán'),
    (v_canton_id, 'EC-P-05-C-01-P-07', 'PARROQUIA', 'Licto'),
    (v_canton_id, 'EC-P-05-C-01-P-08', 'PARROQUIA', 'Pungalá'),
    (v_canton_id, 'EC-P-05-C-01-P-09', 'PARROQUIA', 'Punín'),
    (v_canton_id, 'EC-P-05-C-01-P-10', 'PARROQUIA', 'Quimiag'),
    (v_canton_id, 'EC-P-05-C-01-P-11', 'PARROQUIA', 'San Juan'),
    (v_canton_id, 'EC-P-05-C-01-P-12', 'PARROQUIA', 'San Luis');
    
    -- Cantón: ALAUSÍ
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-05-C-02';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-05-C-02-P-01', 'PARROQUIA', 'Alausí'),
    (v_canton_id, 'EC-P-05-C-02-P-02', 'PARROQUIA', 'Achupallas'),
    (v_canton_id, 'EC-P-05-C-02-P-03', 'PARROQUIA', 'Guasuntos'),
    (v_canton_id, 'EC-P-05-C-02-P-04', 'PARROQUIA', 'Huigra'),
    (v_canton_id, 'EC-P-05-C-02-P-05', 'PARROQUIA', 'Multitud'),
    (v_canton_id, 'EC-P-05-C-02-P-06', 'PARROQUIA', 'Pistishi'),
    (v_canton_id, 'EC-P-05-C-02-P-07', 'PARROQUIA', 'Pumallacta'),
    (v_canton_id, 'EC-P-05-C-02-P-08', 'PARROQUIA', 'Sevilla'),
    (v_canton_id, 'EC-P-05-C-02-P-09', 'PARROQUIA', 'Tixán');
    
    -- Cantón: CHAMBO
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-05-C-03';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-05-C-03-P-01', 'PARROQUIA', 'Chambo');
    
    -- Cantón: CHUNCHI
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-05-C-04';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-05-C-04-P-01', 'PARROQUIA', 'Chunchi'),
    (v_canton_id, 'EC-P-05-C-04-P-02', 'PARROQUIA', 'Capzol'),
    (v_canton_id, 'EC-P-05-C-04-P-03', 'PARROQUIA', 'Compud'),
    (v_canton_id, 'EC-P-05-C-04-P-04', 'PARROQUIA', 'Gonzol'),
    (v_canton_id, 'EC-P-05-C-04-P-05', 'PARROQUIA', 'Llull');
    
    -- Cantón: COLTA
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-05-C-05';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-05-C-05-P-01', 'PARROQUIA', 'Cajabamba'),
    (v_canton_id, 'EC-P-05-C-05-P-02', 'PARROQUIA', 'Sicalpa'),
    (v_canton_id, 'EC-P-05-C-05-P-03', 'PARROQUIA', 'Cañi'),
    (v_canton_id, 'EC-P-05-C-05-P-04', 'PARROQUIA', 'Columbe'),
    (v_canton_id, 'EC-P-05-C-05-P-05', 'PARROQUIA', 'Juan de Velasco'),
    (v_canton_id, 'EC-P-05-C-05-P-06', 'PARROQUIA', 'Santiago de Quito');
    
    -- Cantón: CUMANDÁ
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-05-C-06';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-05-C-06-P-01', 'PARROQUIA', 'Cumandá');
    
    -- Cantón: GUAMOTE
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-05-C-07';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-05-C-07-P-01', 'PARROQUIA', 'Guamote'),
    (v_canton_id, 'EC-P-05-C-07-P-02', 'PARROQUIA', 'Cebadas'),
    (v_canton_id, 'EC-P-05-C-07-P-03', 'PARROQUIA', 'Palmira');
    
    -- Cantón: GUANO
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-05-C-08';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-05-C-08-P-01', 'PARROQUIA', 'Guano'),
    (v_canton_id, 'EC-P-05-C-08-P-02', 'PARROQUIA', 'El Rosario'),
    (v_canton_id, 'EC-P-05-C-08-P-03', 'PARROQUIA', 'La Matriz'),
    (v_canton_id, 'EC-P-05-C-08-P-04', 'PARROQUIA', 'San Andrés'),
    (v_canton_id, 'EC-P-05-C-08-P-05', 'PARROQUIA', 'San Isidro de Patulú'),
    (v_canton_id, 'EC-P-05-C-08-P-06', 'PARROQUIA', 'San José del Chazo'),
    (v_canton_id, 'EC-P-05-C-08-P-07', 'PARROQUIA', 'San Rafael de la Laguna'),
    (v_canton_id, 'EC-P-05-C-08-P-08', 'PARROQUIA', 'Santa Fé de Galán'),
    (v_canton_id, 'EC-P-05-C-08-P-09', 'PARROQUIA', 'Valparaíso');
    
    -- Cantón: PALLATANGA
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-05-C-09';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-05-C-09-P-01', 'PARROQUIA', 'Pallatanga');
    
    -- Cantón: PENIPE
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-05-C-10';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-05-C-10-P-01', 'PARROQUIA', 'Penipe'),
    (v_canton_id, 'EC-P-05-C-10-P-02', 'PARROQUIA', 'Bilbao'),
    (v_canton_id, 'EC-P-05-C-10-P-03', 'PARROQUIA', 'El Altar'),
    (v_canton_id, 'EC-P-05-C-10-P-04', 'PARROQUIA', 'Matus'),
    (v_canton_id, 'EC-P-05-C-10-P-05', 'PARROQUIA', 'Puela'),
    (v_canton_id, 'EC-P-05-C-10-P-06', 'PARROQUIA', 'San Antonio de Bayushig');

    -- =====================================================
    -- 6. COTOPAXI - 7 CANTONES
    -- =====================================================
    
    -- Cantón: LATACUNGA
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-06-C-01';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-06-C-01-P-01', 'PARROQUIA', 'Latacunga'),
    (v_canton_id, 'EC-P-06-C-01-P-02', 'PARROQUIA', 'Alaques'),
    (v_canton_id, 'EC-P-06-C-01-P-03', 'PARROQUIA', 'Belisario Quevedo'),
    (v_canton_id, 'EC-P-06-C-01-P-04', 'PARROQUIA', 'Eloy Alfaro'),
    (v_canton_id, 'EC-P-06-C-01-P-05', 'PARROQUIA', 'Guaytacama'),
    (v_canton_id, 'EC-P-06-C-01-P-06', 'PARROQUIA', 'Ignacio Flores'),
    (v_canton_id, 'EC-P-06-C-01-P-07', 'PARROQUIA', 'José Guango'),
    (v_canton_id, 'EC-P-06-C-01-P-08', 'PARROQUIA', 'Juan Montalvo'),
    (v_canton_id, 'EC-P-06-C-01-P-09', 'PARROQUIA', 'Mulaló'),
    (v_canton_id, 'EC-P-06-C-01-P-10', 'PARROQUIA', 'Pastocalle'),
    (v_canton_id, 'EC-P-06-C-01-P-11', 'PARROQUIA', 'Poaló'),
    (v_canton_id, 'EC-P-06-C-01-P-12', 'PARROQUIA', 'San Juan de Pastocalle'),
    (v_canton_id, 'EC-P-06-C-01-P-13', 'PARROQUIA', 'Tanicuchí'),
    (v_canton_id, 'EC-P-06-C-01-P-14', 'PARROQUIA', 'Toacaso');
    
    -- Cantón: LA MANÁ
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-06-C-02';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-06-C-02-P-01', 'PARROQUIA', 'La Maná'),
    (v_canton_id, 'EC-P-06-C-02-P-02', 'PARROQUIA', 'El Carmen'),
    (v_canton_id, 'EC-P-06-C-02-P-03', 'PARROQUIA', 'El Triunfo');
    
    -- Cantón: PANGUA
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-06-C-03';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-06-C-03-P-01', 'PARROQUIA', 'El Corazón'),
    (v_canton_id, 'EC-P-06-C-03-P-02', 'PARROQUIA', 'Moraspungo'),
    (v_canton_id, 'EC-P-06-C-03-P-03', 'PARROQUIA', 'Pinllopata'),
    (v_canton_id, 'EC-P-06-C-03-P-04', 'PARROQUIA', 'Ramón Campaña');
    
    -- Cantón: PUJILÍ
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-06-C-04';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-06-C-04-P-01', 'PARROQUIA', 'Pujilí'),
    (v_canton_id, 'EC-P-06-C-04-P-02', 'PARROQUIA', 'Angamarca'),
    (v_canton_id, 'EC-P-06-C-04-P-03', 'PARROQUIA', 'Chucchilán'),
    (v_canton_id, 'EC-P-06-C-04-P-04', 'PARROQUIA', 'El Tingo'),
    (v_canton_id, 'EC-P-06-C-04-P-05', 'PARROQUIA', 'La Victoria'),
    (v_canton_id, 'EC-P-06-C-04-P-06', 'PARROQUIA', 'Pilaló'),
    (v_canton_id, 'EC-P-06-C-04-P-07', 'PARROQUIA', 'Zumbahua');
    
    -- Cantón: SALCEDO
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-06-C-05';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-06-C-05-P-01', 'PARROQUIA', 'Salcedo'),
    (v_canton_id, 'EC-P-06-C-05-P-02', 'PARROQUIA', 'Antonio José Holguín'),
    (v_canton_id, 'EC-P-06-C-05-P-03', 'PARROQUIA', 'Cusubamba'),
    (v_canton_id, 'EC-P-06-C-05-P-04', 'PARROQUIA', 'Mulalillo'),
    (v_canton_id, 'EC-P-06-C-05-P-05', 'PARROQUIA', 'Mulliquindil'),
    (v_canton_id, 'EC-P-06-C-05-P-06', 'PARROQUIA', 'Pansaleo');
    
    -- Cantón: SAQUISILÍ
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-06-C-06';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-06-C-06-P-01', 'PARROQUIA', 'Saquisilí'),
    (v_canton_id, 'EC-P-06-C-06-P-02', 'PARROQUIA', 'Canchagua'),
    (v_canton_id, 'EC-P-06-C-06-P-03', 'PARROQUIA', 'Chantilín'),
    (v_canton_id, 'EC-P-06-C-06-P-04', 'PARROQUIA', 'Cochapamba');
    
    -- Cantón: SIGCHOS
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-06-C-07';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-06-C-07-P-01', 'PARROQUIA', 'Sigchos'),
    (v_canton_id, 'EC-P-06-C-07-P-02', 'PARROQUIA', 'Chugchilán'),
    (v_canton_id, 'EC-P-06-C-07-P-03', 'PARROQUIA', 'Isinliví'),
    (v_canton_id, 'EC-P-06-C-07-P-04', 'PARROQUIA', 'Las Pampas'),
    (v_canton_id, 'EC-P-06-C-07-P-05', 'PARROQUIA', 'Palo Quemado');

    -- =====================================================
    -- 7. EL ORO - 14 CANTONES
    -- =====================================================
    
    -- Cantón: MACHALA
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-07-C-01';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-07-C-01-P-01', 'PARROQUIA', 'Machala'),
    (v_canton_id, 'EC-P-07-C-01-P-02', 'PARROQUIA', 'El Cambio'),
    (v_canton_id, 'EC-P-07-C-01-P-03', 'PARROQUIA', 'La Providencia'),
    (v_canton_id, 'EC-P-07-C-01-P-04', 'PARROQUIA', 'La Unión'),
    (v_canton_id, 'EC-P-07-C-01-P-05', 'PARROQUIA', 'Puerto Bolívar');
    
    -- Cantón: ARENILLAS
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-07-C-02';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-07-C-02-P-01', 'PARROQUIA', 'Arenillas'),
    (v_canton_id, 'EC-P-07-C-02-P-02', 'PARROQUIA', 'Chacras'),
    (v_canton_id, 'EC-P-07-C-02-P-03', 'PARROQUIA', 'Palmales'),
    (v_canton_id, 'EC-P-07-C-02-P-04', 'PARROQUIA', 'Carcabón');
    
    -- Cantón: ATAHUALPA
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-07-C-03';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-07-C-03-P-01', 'PARROQUIA', 'Paccha'),
    (v_canton_id, 'EC-P-07-C-03-P-02', 'PARROQUIA', 'Ayapamba'),
    (v_canton_id, 'EC-P-07-C-03-P-03', 'PARROQUIA', 'Cordoncillo'),
    (v_canton_id, 'EC-P-07-C-03-P-04', 'PARROQUIA', 'Milagro'),
    (v_canton_id, 'EC-P-07-C-03-P-05', 'PARROQUIA', 'San José'),
    (v_canton_id, 'EC-P-07-C-03-P-06', 'PARROQUIA', 'San Juan de Cerro Azul');
    
    -- Cantón: BALSAS
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-07-C-04';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-07-C-04-P-01', 'PARROQUIA', 'Balsas'),
    (v_canton_id, 'EC-P-07-C-04-P-02', 'PARROQUIA', 'Bellamaría');
    
    -- Cantón: CHILLA
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-07-C-05';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-07-C-05-P-01', 'PARROQUIA', 'Chilla');
    
    -- Cantón: EL GUABO
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-07-C-06';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-07-C-06-P-01', 'PARROQUIA', 'El Guabo'),
    (v_canton_id, 'EC-P-07-C-06-P-02', 'PARROQUIA', 'Barbones'),
    (v_canton_id, 'EC-P-07-C-06-P-03', 'PARROQUIA', 'La Iberia'),
    (v_canton_id, 'EC-P-07-C-06-P-04', 'PARROQUIA', 'Tendales'),
    (v_canton_id, 'EC-P-07-C-06-P-05', 'PARROQUIA', 'Río Bonito');
    
    -- Cantón: HUAQUILLAS
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-07-C-07';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-07-C-07-P-01', 'PARROQUIA', 'Huaquillas'),
    (v_canton_id, 'EC-P-07-C-07-P-02', 'PARROQUIA', 'Ecuador');
    
    -- Cantón: LAS LAJAS
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-07-C-08';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-07-C-08-P-01', 'PARROQUIA', 'La Victoria'),
    (v_canton_id, 'EC-P-07-C-08-P-02', 'PARROQUIA', 'El Paraíso'),
    (v_canton_id, 'EC-P-07-C-08-P-03', 'PARROQUIA', 'La Libertad'),
    (v_canton_id, 'EC-P-07-C-08-P-04', 'PARROQUIA', 'San Isidro');
    
    -- Cantón: MARCABELÍ
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-07-C-09';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-07-C-09-P-01', 'PARROQUIA', 'Marcabelí'),
    (v_canton_id, 'EC-P-07-C-09-P-02', 'PARROQUIA', 'El Ingenio');
    
    -- Cantón: PASAJE
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-07-C-10';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-07-C-10-P-01', 'PARROQUIA', 'Pasaje'),
    (v_canton_id, 'EC-P-07-C-10-P-02', 'PARROQUIA', 'Buenavista'),
    (v_canton_id, 'EC-P-07-C-10-P-03', 'PARROQUIA', 'Casacay'),
    (v_canton_id, 'EC-P-07-C-10-P-04', 'PARROQUIA', 'La Peaña'),
    (v_canton_id, 'EC-P-07-C-10-P-05', 'PARROQUIA', 'Uzhcurrumi');
    
    -- Cantón: PIÑAS
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-07-C-11';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-07-C-11-P-01', 'PARROQUIA', 'Piñas'),
    (v_canton_id, 'EC-P-07-C-11-P-02', 'PARROQUIA', 'Capiro'),
    (v_canton_id, 'EC-P-07-C-11-P-03', 'PARROQUIA', 'La Bocana'),
    (v_canton_id, 'EC-P-07-C-11-P-04', 'PARROQUIA', 'Moromoro'),
    (v_canton_id, 'EC-P-07-C-11-P-05', 'PARROQUIA', 'Piedras'),
    (v_canton_id, 'EC-P-07-C-11-P-06', 'PARROQUIA', 'San Roque'),
    (v_canton_id, 'EC-P-07-C-11-P-07', 'PARROQUIA', 'Saracay');
    
    -- Cantón: PORTOVELO
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-07-C-12';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-07-C-12-P-01', 'PARROQUIA', 'Portovelo'),
    (v_canton_id, 'EC-P-07-C-12-P-02', 'PARROQUIA', 'Curtincápac'),
    (v_canton_id, 'EC-P-07-C-12-P-03', 'PARROQUIA', 'Moralito'),
    (v_canton_id, 'EC-P-07-C-12-P-04', 'PARROQUIA', 'Salvias');
    
    -- Cantón: SANTA ROSA
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-07-C-13';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-07-C-13-P-01', 'PARROQUIA', 'Santa Rosa'),
    (v_canton_id, 'EC-P-07-C-13-P-02', 'PARROQUIA', 'Bellavista'),
    (v_canton_id, 'EC-P-07-C-13-P-03', 'PARROQUIA', 'Jambelí'),
    (v_canton_id, 'EC-P-07-C-13-P-04', 'PARROQUIA', 'La Avanzada'),
    (v_canton_id, 'EC-P-07-C-13-P-05', 'PARROQUIA', 'San Antonio'),
    (v_canton_id, 'EC-P-07-C-13-P-06', 'PARROQUIA', 'Torata'),
    (v_canton_id, 'EC-P-07-C-13-P-07', 'PARROQUIA', 'Victoria');
    
    -- Cantón: ZARUMA
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-07-C-14';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-07-C-14-P-01', 'PARROQUIA', 'Zaruma'),
    (v_canton_id, 'EC-P-07-C-14-P-02', 'PARROQUIA', 'Abañín'),
    (v_canton_id, 'EC-P-07-C-14-P-03', 'PARROQUIA', 'Arcapamba'),
    (v_canton_id, 'EC-P-07-C-14-P-04', 'PARROQUIA', 'Guanazán'),
    (v_canton_id, 'EC-P-07-C-14-P-05', 'PARROQUIA', 'Guizhaguiña'),
    (v_canton_id, 'EC-P-07-C-14-P-06', 'PARROQUIA', 'Huertas'),
    (v_canton_id, 'EC-P-07-C-14-P-07', 'PARROQUIA', 'Malvas'),
    (v_canton_id, 'EC-P-07-C-14-P-08', 'PARROQUIA', 'Muluncay'),
    (v_canton_id, 'EC-P-07-C-14-P-09', 'PARROQUIA', 'Salvias'),
    (v_canton_id, 'EC-P-07-C-14-P-10', 'PARROQUIA', 'Sinsao');

    RAISE NOTICE 'Parroquias insertadas para AZUAY, BOLÍVAR, CAÑAR, CARCHI, CHIMBORAZO, COTOPAXI y EL ORO';

    RAISE NOTICE 'Continuar con el resto de provincias: ESMERALDAS, GALÁPAGOS, GUAYAS, IMBABURA, LOJA, LOS RÍOS, MANABÍ, MORONA SANTIAGO, NAPO, ORELLANA, PASTAZA, PICHINCHA, SANTA ELENA, SANTO DOMINGO, SUCUMBÍOS, TUNGURAHUA, ZAMORA CHINCHIPE';


    -- =====================================================
    -- 8. ESMERALDAS - 7 CANTONES
    -- =====================================================
    
    -- Cantón: ESMERALDAS
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-08-C-01';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-08-C-01-P-01', 'PARROQUIA', 'Esmeraldas'),
    (v_canton_id, 'EC-P-08-C-01-P-02', 'PARROQUIA', 'Bartolomé de las Casas'),
    (v_canton_id, 'EC-P-08-C-01-P-03', 'PARROQUIA', 'Carlos Concha'),
    (v_canton_id, 'EC-P-08-C-01-P-04', 'PARROQUIA', 'Chinca'),
    (v_canton_id, 'EC-P-08-C-01-P-05', 'PARROQUIA', 'Chontaduro'),
    (v_canton_id, 'EC-P-08-C-01-P-06', 'PARROQUIA', 'Cinco de Junio'),
    (v_canton_id, 'EC-P-08-C-01-P-07', 'PARROQUIA', 'Luis Tello'),
    (v_canton_id, 'EC-P-08-C-01-P-08', 'PARROQUIA', 'Maldonado'),
    (v_canton_id, 'EC-P-08-C-01-P-09', 'PARROQUIA', 'San Mateo'),
    (v_canton_id, 'EC-P-08-C-01-P-10', 'PARROQUIA', 'Súa'),
    (v_canton_id, 'EC-P-08-C-01-P-11', 'PARROQUIA', 'Tabiazo'),
    (v_canton_id, 'EC-P-08-C-01-P-12', 'PARROQUIA', 'Tachina'),
    (v_canton_id, 'EC-P-08-C-01-P-13', 'PARROQUIA', 'Telembí'),
    (v_canton_id, 'EC-P-08-C-01-P-14', 'PARROQUIA', 'Timbre'),
    (v_canton_id, 'EC-P-08-C-01-P-15', 'PARROQUIA', 'Vuelta Larga');
    
    -- Cantón: ATACAMES
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-08-C-02';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-08-C-02-P-01', 'PARROQUIA', 'Atacames'),
    (v_canton_id, 'EC-P-08-C-02-P-02', 'PARROQUIA', 'Colón'),
    (v_canton_id, 'EC-P-08-C-02-P-03', 'PARROQUIA', 'La Unión'),
    (v_canton_id, 'EC-P-08-C-02-P-04', 'PARROQUIA', 'Súa');
    
    -- Cantón: ELOY ALFARO
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-08-C-03';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-08-C-03-P-01', 'PARROQUIA', 'Valdez'),
    (v_canton_id, 'EC-P-08-C-03-P-02', 'PARROQUIA', 'Ancón'),
    (v_canton_id, 'EC-P-08-C-03-P-03', 'PARROQUIA', 'Atahualpa'),
    (v_canton_id, 'EC-P-08-C-03-P-04', 'PARROQUIA', 'Borbón'),
    (v_canton_id, 'EC-P-08-C-03-P-05', 'PARROQUIA', 'La Tola'),
    (v_canton_id, 'EC-P-08-C-03-P-06', 'PARROQUIA', 'Luis Vargas Torres'),
    (v_canton_id, 'EC-P-08-C-03-P-07', 'PARROQUIA', 'Maldonado'),
    (v_canton_id, 'EC-P-08-C-03-P-08', 'PARROQUIA', 'Pampanal de Bolívar'),
    (v_canton_id, 'EC-P-08-C-03-P-09', 'PARROQUIA', 'San Francisco de Onzole'),
    (v_canton_id, 'EC-P-08-C-03-P-10', 'PARROQUIA', 'Santo Domingo de Onzole'),
    (v_canton_id, 'EC-P-08-C-03-P-11', 'PARROQUIA', 'Selva Alegre'),
    (v_canton_id, 'EC-P-08-C-03-P-12', 'PARROQUIA', 'Telembí');
    
    -- Cantón: MUISNE
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-08-C-04';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-08-C-04-P-01', 'PARROQUIA', 'Muisne'),
    (v_canton_id, 'EC-P-08-C-04-P-02', 'PARROQUIA', 'Bolívar'),
    (v_canton_id, 'EC-P-08-C-04-P-03', 'PARROQUIA', 'Daule'),
    (v_canton_id, 'EC-P-08-C-04-P-04', 'PARROQUIA', 'Galera'),
    (v_canton_id, 'EC-P-08-C-04-P-05', 'PARROQUIA', 'Quingue'),
    (v_canton_id, 'EC-P-08-C-04-P-06', 'PARROQUIA', 'Salima'),
    (v_canton_id, 'EC-P-08-C-04-P-07', 'PARROQUIA', 'San Francisco'),
    (v_canton_id, 'EC-P-08-C-04-P-08', 'PARROQUIA', 'San José de Chamanga');
    
    -- Cantón: QUININDÉ
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-08-C-05';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-08-C-05-P-01', 'PARROQUIA', 'Quinindé'),
    (v_canton_id, 'EC-P-08-C-05-P-02', 'PARROQUIA', 'Chura'),
    (v_canton_id, 'EC-P-08-C-05-P-03', 'PARROQUIA', 'Cube'),
    (v_canton_id, 'EC-P-08-C-05-P-04', 'PARROQUIA', 'La Unión'),
    (v_canton_id, 'EC-P-08-C-05-P-05', 'PARROQUIA', 'Malimpia'),
    (v_canton_id, 'EC-P-08-C-05-P-06', 'PARROQUIA', 'Rosa Zarate'),
    (v_canton_id, 'EC-P-08-C-05-P-07', 'PARROQUIA', 'Viche');
    
    -- Cantón: RIOVERDE
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-08-C-06';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-08-C-06-P-01', 'PARROQUIA', 'Rioverde'),
    (v_canton_id, 'EC-P-08-C-06-P-02', 'PARROQUIA', 'Chumundé'),
    (v_canton_id, 'EC-P-08-C-06-P-03', 'PARROQUIA', 'Laguna');
    
    -- Cantón: SAN LORENZO
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-08-C-07';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-08-C-07-P-01', 'PARROQUIA', 'San Lorenzo'),
    (v_canton_id, 'EC-P-08-C-07-P-02', 'PARROQUIA', 'Alto Tambo'),
    (v_canton_id, 'EC-P-08-C-07-P-03', 'PARROQUIA', 'Ancón'),
    (v_canton_id, 'EC-P-08-C-07-P-04', 'PARROQUIA', 'Calderón'),
    (v_canton_id, 'EC-P-08-C-07-P-05', 'PARROQUIA', 'Carondelet'),
    (v_canton_id, 'EC-P-08-C-07-P-06', 'PARROQUIA', 'Mataje'),
    (v_canton_id, 'EC-P-08-C-07-P-07', 'PARROQUIA', '5 de Junio'),
    (v_canton_id, 'EC-P-08-C-07-P-08', 'PARROQUIA', 'Santa Rita'),
    (v_canton_id, 'EC-P-08-C-07-P-09', 'PARROQUIA', 'Tululbí');

    -- =====================================================
    -- 9. GALÁPAGOS - 3 CANTONES
    -- =====================================================
    
    -- Cantón: SAN CRISTÓBAL
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-09-C-01';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-09-C-01-P-01', 'PARROQUIA', 'Puerto Baquerizo Moreno'),
    (v_canton_id, 'EC-P-09-C-01-P-02', 'PARROQUIA', 'El Progreso'),
    (v_canton_id, 'EC-P-09-C-01-P-03', 'PARROQUIA', 'Isla Santa María');
    
    -- Cantón: ISABELA
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-09-C-02';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-09-C-02-P-01', 'PARROQUIA', 'Puerto Villamil'),
    (v_canton_id, 'EC-P-09-C-02-P-02', 'PARROQUIA', 'Tomás de Berlanga');
    
    -- Cantón: SANTA CRUZ
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-09-C-03';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-09-C-03-P-01', 'PARROQUIA', 'Puerto Ayora'),
    (v_canton_id, 'EC-P-09-C-03-P-02', 'PARROQUIA', 'Bellavista'),
    (v_canton_id, 'EC-P-09-C-03-P-03', 'PARROQUIA', 'Santa Rosa');

    -- =====================================================
    -- 10. GUAYAS - 25 CANTONES
    -- =====================================================
    
    -- Cantón: GUAYAQUIL
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-10-C-01';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-10-C-01-P-01', 'PARROQUIA', 'Ayacucho'),
    (v_canton_id, 'EC-P-10-C-01-P-02', 'PARROQUIA', 'Bolívar'),
    (v_canton_id, 'EC-P-10-C-01-P-03', 'PARROQUIA', 'Carbo'),
    (v_canton_id, 'EC-P-10-C-01-P-04', 'PARROQUIA', 'Febres Cordero'),
    (v_canton_id, 'EC-P-10-C-01-P-05', 'PARROQUIA', 'García Moreno'),
    (v_canton_id, 'EC-P-10-C-01-P-06', 'PARROQUIA', 'Letamendi'),
    (v_canton_id, 'EC-P-10-C-01-P-07', 'PARROQUIA', 'Nueve de Octubre'),
    (v_canton_id, 'EC-P-10-C-01-P-08', 'PARROQUIA', 'Olmedo'),
    (v_canton_id, 'EC-P-10-C-01-P-09', 'PARROQUIA', 'Roca'),
    (v_canton_id, 'EC-P-10-C-01-P-10', 'PARROQUIA', 'Rocafuerte'),
    (v_canton_id, 'EC-P-10-C-01-P-11', 'PARROQUIA', 'Sucre'),
    (v_canton_id, 'EC-P-10-C-01-P-12', 'PARROQUIA', 'Tarqui'),
    (v_canton_id, 'EC-P-10-C-01-P-13', 'PARROQUIA', 'Urdaneta'),
    (v_canton_id, 'EC-P-10-C-01-P-14', 'PARROQUIA', 'Ximena'),
    (v_canton_id, 'EC-P-10-C-01-P-15', 'PARROQUIA', 'Chongón'),
    (v_canton_id, 'EC-P-10-C-01-P-16', 'PARROQUIA', 'Pascuales'),
    (v_canton_id, 'EC-P-10-C-01-P-17', 'PARROQUIA', 'Juan Gómez Rendón'),
    (v_canton_id, 'EC-P-10-C-01-P-18', 'PARROQUIA', 'Morro'),
    (v_canton_id, 'EC-P-10-C-01-P-19', 'PARROQUIA', 'Posorja'),
    (v_canton_id, 'EC-P-10-C-01-P-20', 'PARROQUIA', 'Puna'),
    (v_canton_id, 'EC-P-10-C-01-P-21', 'PARROQUIA', 'Tenguel');
    
    -- Cantón: ALFREDO BAQUERIZO MORENO (Jujan)
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-10-C-02';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-10-C-02-P-01', 'PARROQUIA', 'Alfredo Baquerizo Moreno'),
    (v_canton_id, 'EC-P-10-C-02-P-02', 'PARROQUIA', 'José Luis Tamayo');
    
    -- Cantón: BALAO
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-10-C-03';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-10-C-03-P-01', 'PARROQUIA', 'Balao'),
    (v_canton_id, 'EC-P-10-C-03-P-02', 'PARROQUIA', 'La Esperanza');
    
    -- Cantón: BALZAR
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-10-C-04';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-10-C-04-P-01', 'PARROQUIA', 'Balzar');
    
    -- Cantón: COLIMES
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-10-C-05';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-10-C-05-P-01', 'PARROQUIA', 'Colimes'),
    (v_canton_id, 'EC-P-10-C-05-P-02', 'PARROQUIA', 'San Jacinto');
    
    -- Cantón: CORONEL MARCELINO MARIDUEÑA
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-10-C-06';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-10-C-06-P-01', 'PARROQUIA', 'Coronel Marcelino Maridueña');
    
    -- Cantón: DAULE
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-10-C-07';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-10-C-07-P-01', 'PARROQUIA', 'Daule'),
    (v_canton_id, 'EC-P-10-C-07-P-02', 'PARROQUIA', 'La Aurora'),
    (v_canton_id, 'EC-P-10-C-07-P-03', 'PARROQUIA', 'Banife'),
    (v_canton_id, 'EC-P-10-C-07-P-04', 'PARROQUIA', 'Emilio Valverde'),
    (v_canton_id, 'EC-P-10-C-07-P-05', 'PARROQUIA', 'El Recreo'),
    (v_canton_id, 'EC-P-10-C-07-P-06', 'PARROQUIA', 'Isla de Puná'),
    (v_canton_id, 'EC-P-10-C-07-P-07', 'PARROQUIA', 'Juan Bautista Aguirre'),
    (v_canton_id, 'EC-P-10-C-07-P-08', 'PARROQUIA', 'La Victoria'),
    (v_canton_id, 'EC-P-10-C-07-P-09', 'PARROQUIA', 'Lomas de Sargentillo'),
    (v_canton_id, 'EC-P-10-C-07-P-10', 'PARROQUIA', 'Los Loros'),
    (v_canton_id, 'EC-P-10-C-07-P-11', 'PARROQUIA', 'Narcisa de Jesús'),
    (v_canton_id, 'EC-P-10-C-07-P-12', 'PARROQUIA', 'Pedro Pablo Gómez');
    
    -- Cantón: DURÁN
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-10-C-08';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-10-C-08-P-01', 'PARROQUIA', 'Durán'),
    (v_canton_id, 'EC-P-10-C-08-P-02', 'PARROQUIA', 'El Recreo');
    
    -- Cantón: EL EMPALME
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-10-C-09';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-10-C-09-P-01', 'PARROQUIA', 'El Empalme'),
    (v_canton_id, 'EC-P-10-C-09-P-02', 'PARROQUIA', 'Velasco Ibarra');
    
    -- Cantón: EL TRIUNFO
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-10-C-10';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-10-C-10-P-01', 'PARROQUIA', 'El Triunfo');
    
    -- Cantón: GENERAL ANTONIO ELIZALDE
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-10-C-11';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-10-C-11-P-01', 'PARROQUIA', 'General Antonio Elizalde');
    
    -- Cantón: ISIDRO AYORA
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-10-C-12';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-10-C-12-P-01', 'PARROQUIA', 'Isidro Ayora');
    
    -- Cantón: LOMAS DE SARGENTILLO
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-10-C-13';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-10-C-13-P-01', 'PARROQUIA', 'Lomas de Sargentillo');
    
    -- Cantón: MILAGRO
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-10-C-14';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-10-C-14-P-01', 'PARROQUIA', 'Milagro'),
    (v_canton_id, 'EC-P-10-C-14-P-02', 'PARROQUIA', 'Chobo'),
    (v_canton_id, 'EC-P-10-C-14-P-03', 'PARROQUIA', 'Roberto Astudillo'),
    (v_canton_id, 'EC-P-10-C-14-P-04', 'PARROQUIA', 'Mariscal Sucre');
    
    -- Cantón: NARANJAL
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-10-C-15';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-10-C-15-P-01', 'PARROQUIA', 'Naranjal'),
    (v_canton_id, 'EC-P-10-C-15-P-02', 'PARROQUIA', 'Jesús María'),
    (v_canton_id, 'EC-P-10-C-15-P-03', 'PARROQUIA', 'San Carlos');
    
    -- Cantón: NARANJITO
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-10-C-16';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-10-C-16-P-01', 'PARROQUIA', 'Naranjito');
    
    -- Cantón: PALESTINA
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-10-C-17';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-10-C-17-P-01', 'PARROQUIA', 'Palestina');
    
    -- Cantón: PEDRO CARBO
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-10-C-18';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-10-C-18-P-01', 'PARROQUIA', 'Pedro Carbo'),
    (v_canton_id, 'EC-P-10-C-18-P-02', 'PARROQUIA', 'Sabanilla'),
    (v_canton_id, 'EC-P-10-C-18-P-03', 'PARROQUIA', 'Valle de la Virgen');
    
    -- Cantón: PLAYAS
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-10-C-19';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-10-C-19-P-01', 'PARROQUIA', 'Playas'),
    (v_canton_id, 'EC-P-10-C-19-P-02', 'PARROQUIA', 'El Morro');
    
    -- Cantón: SALITRE
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-10-C-20';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-10-C-20-P-01', 'PARROQUIA', 'Salitre'),
    (v_canton_id, 'EC-P-10-C-20-P-02', 'PARROQUIA', 'General Vernaza'),
    (v_canton_id, 'EC-P-10-C-20-P-03', 'PARROQUIA', 'La Gonga'),
    (v_canton_id, 'EC-P-10-C-20-P-04', 'PARROQUIA', 'San Juan');
    
    -- Cantón: SAMBORONDÓN
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-10-C-21';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-10-C-21-P-01', 'PARROQUIA', 'Samborondón'),
    (v_canton_id, 'EC-P-10-C-21-P-02', 'PARROQUIA', 'La Puntilla'),
    (v_canton_id, 'EC-P-10-C-21-P-03', 'PARROQUIA', 'Tarifa');
    
    -- Cantón: SANTA LUCÍA
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-10-C-22';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-10-C-22-P-01', 'PARROQUIA', 'Santa Lucía');
    
    -- Cantón: SIMÓN BOLÍVAR
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-10-C-23';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-10-C-23-P-01', 'PARROQUIA', 'Simón Bolívar');
    
    -- Cantón: YAGUACHI
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-10-C-24';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-10-C-24-P-01', 'PARROQUIA', 'Yaguachi'),
    (v_canton_id, 'EC-P-10-C-24-P-02', 'PARROQUIA', 'Nueva Prosperina'),
    (v_canton_id, 'EC-P-10-C-24-P-03', 'PARROQUIA', 'Pedro J. Montero');
    
    -- Cantón: JUJÁN (ya insertado como Alfredo Baquerizo Moreno)
    
    -- =====================================================
    -- 11. IMBABURA - 6 CANTONES
    -- =====================================================
    
    -- Cantón: IBARRA
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-11-C-01';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-11-C-01-P-01', 'PARROQUIA', 'Ibarra'),
    (v_canton_id, 'EC-P-11-C-01-P-02', 'PARROQUIA', 'Alpachaca'),
    (v_canton_id, 'EC-P-11-C-01-P-03', 'PARROQUIA', 'Ambuquí'),
    (v_canton_id, 'EC-P-11-C-01-P-04', 'PARROQUIA', 'Angochagua'),
    (v_canton_id, 'EC-P-11-C-01-P-05', 'PARROQUIA', 'Carolina'),
    (v_canton_id, 'EC-P-11-C-01-P-06', 'PARROQUIA', 'La Esperanza'),
    (v_canton_id, 'EC-P-11-C-01-P-07', 'PARROQUIA', 'Lita'),
    (v_canton_id, 'EC-P-11-C-01-P-08', 'PARROQUIA', 'Salinas'),
    (v_canton_id, 'EC-P-11-C-01-P-09', 'PARROQUIA', 'San Antonio');
    
    -- Cantón: ANTONIO ANTE
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-11-C-02';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-11-C-02-P-01', 'PARROQUIA', 'Atuntaqui'),
    (v_canton_id, 'EC-P-11-C-02-P-02', 'PARROQUIA', 'Andrade Marín'),
    (v_canton_id, 'EC-P-11-C-02-P-03', 'PARROQUIA', 'Chaltura'),
    (v_canton_id, 'EC-P-11-C-02-P-04', 'PARROQUIA', 'Imbaya'),
    (v_canton_id, 'EC-P-11-C-02-P-05', 'PARROQUIA', 'Natabuela'),
    (v_canton_id, 'EC-P-11-C-02-P-06', 'PARROQUIA', 'San Francisco de Natabuela');
    
    -- Cantón: COTACACHI
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-11-C-03';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-11-C-03-P-01', 'PARROQUIA', 'Cotacachi'),
    (v_canton_id, 'EC-P-11-C-03-P-02', 'PARROQUIA', 'Apuela'),
    (v_canton_id, 'EC-P-11-C-03-P-03', 'PARROQUIA', 'García Moreno'),
    (v_canton_id, 'EC-P-11-C-03-P-04', 'PARROQUIA', 'Imantag'),
    (v_canton_id, 'EC-P-11-C-03-P-05', 'PARROQUIA', 'Peñaherrera'),
    (v_canton_id, 'EC-P-11-C-03-P-06', 'PARROQUIA', 'Plaza Gutiérrez'),
    (v_canton_id, 'EC-P-11-C-03-P-07', 'PARROQUIA', 'Quiroga'),
    (v_canton_id, 'EC-P-11-C-03-P-08', 'PARROQUIA', '6 de Julio de Cuellaje');
    
    -- Cantón: OTAVALO
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-11-C-04';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-11-C-04-P-01', 'PARROQUIA', 'Otavalo'),
    (v_canton_id, 'EC-P-11-C-04-P-02', 'PARROQUIA', 'Carabuela'),
    (v_canton_id, 'EC-P-11-C-04-P-03', 'PARROQUIA', 'Eugenio Espejo'),
    (v_canton_id, 'EC-P-11-C-04-P-04', 'PARROQUIA', 'González Suárez'),
    (v_canton_id, 'EC-P-11-C-04-P-05', 'PARROQUIA', 'Peguche'),
    (v_canton_id, 'EC-P-11-C-04-P-06', 'PARROQUIA', 'San José de Quichinche'),
    (v_canton_id, 'EC-P-11-C-04-P-07', 'PARROQUIA', 'San Luis'),
    (v_canton_id, 'EC-P-11-C-04-P-08', 'PARROQUIA', 'San Pablo del Lago'),
    (v_canton_id, 'EC-P-11-C-04-P-09', 'PARROQUIA', 'San Rafael de la Laguna'),
    (v_canton_id, 'EC-P-11-C-04-P-10', 'PARROQUIA', 'San Roque'),
    (v_canton_id, 'EC-P-11-C-04-P-11', 'PARROQUIA', 'Selva Alegre');
    
    -- Cantón: PIMAMPIRO
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-11-C-05';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-11-C-05-P-01', 'PARROQUIA', 'Pimampiro'),
    (v_canton_id, 'EC-P-11-C-05-P-02', 'PARROQUIA', 'Chugá'),
    (v_canton_id, 'EC-P-11-C-05-P-03', 'PARROQUIA', 'Mariano Acosta'),
    (v_canton_id, 'EC-P-11-C-05-P-04', 'PARROQUIA', 'San Francisco de Sigsipamba');
    
    -- Cantón: SAN MIGUEL DE URCUQUÍ
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-11-C-06';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-11-C-06-P-01', 'PARROQUIA', 'Urcuquí'),
    (v_canton_id, 'EC-P-11-C-06-P-02', 'PARROQUIA', 'Cahuasquí'),
    (v_canton_id, 'EC-P-11-C-06-P-03', 'PARROQUIA', 'La Merced de Buenos Aires'),
    (v_canton_id, 'EC-P-11-C-06-P-04', 'PARROQUIA', 'Pablo Arenas'),
    (v_canton_id, 'EC-P-11-C-06-P-05', 'PARROQUIA', 'San Blas'),
    (v_canton_id, 'EC-P-11-C-06-P-06', 'PARROQUIA', 'Tumbabiro');

    -- =====================================================
    -- 12. LOJA - 16 CANTONES
    -- =====================================================
    
    -- Cantón: LOJA
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-12-C-01';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-12-C-01-P-01', 'PARROQUIA', 'Loja'),
    (v_canton_id, 'EC-P-12-C-01-P-02', 'PARROQUIA', 'Carigán'),
    (v_canton_id, 'EC-P-12-C-01-P-03', 'PARROQUIA', 'Chantaco'),
    (v_canton_id, 'EC-P-12-C-01-P-04', 'PARROQUIA', 'Chuquiribamba'),
    (v_canton_id, 'EC-P-12-C-01-P-05', 'PARROQUIA', 'El Cisne'),
    (v_canton_id, 'EC-P-12-C-01-P-06', 'PARROQUIA', 'El Sagrario'),
    (v_canton_id, 'EC-P-12-C-01-P-07', 'PARROQUIA', 'El Valle'),
    (v_canton_id, 'EC-P-12-C-01-P-08', 'PARROQUIA', 'Jimbilla'),
    (v_canton_id, 'EC-P-12-C-01-P-09', 'PARROQUIA', 'Malacatos'),
    (v_canton_id, 'EC-P-12-C-01-P-10', 'PARROQUIA', 'Punzara'),
    (v_canton_id, 'EC-P-12-C-01-P-11', 'PARROQUIA', 'Quinara'),
    (v_canton_id, 'EC-P-12-C-01-P-12', 'PARROQUIA', 'San Lucas'),
    (v_canton_id, 'EC-P-12-C-01-P-13', 'PARROQUIA', 'San Pedro de Vilcabamba'),
    (v_canton_id, 'EC-P-12-C-01-P-14', 'PARROQUIA', 'San Sebastián'),
    (v_canton_id, 'EC-P-12-C-01-P-15', 'PARROQUIA', 'Santiago'),
    (v_canton_id, 'EC-P-12-C-01-P-16', 'PARROQUIA', 'Sucre'),
    (v_canton_id, 'EC-P-12-C-01-P-17', 'PARROQUIA', 'Taquil'),
    (v_canton_id, 'EC-P-12-C-01-P-18', 'PARROQUIA', 'Vilcabamba'),
    (v_canton_id, 'EC-P-12-C-01-P-19', 'PARROQUIA', 'Yangana');
    
    -- Cantón: CALVAS
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-12-C-02';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-12-C-02-P-01', 'PARROQUIA', 'Cariamanga'),
    (v_canton_id, 'EC-P-12-C-02-P-02', 'PARROQUIA', 'Chile'),
    (v_canton_id, 'EC-P-12-C-02-P-03', 'PARROQUIA', 'Colaisaca'),
    (v_canton_id, 'EC-P-12-C-02-P-04', 'PARROQUIA', 'El Lucero'),
    (v_canton_id, 'EC-P-12-C-02-P-05', 'PARROQUIA', 'Sanguillín'),
    (v_canton_id, 'EC-P-12-C-02-P-06', 'PARROQUIA', 'Utuana');
    
    -- Cantón: CATAMAYO
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-12-C-03';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-12-C-03-P-01', 'PARROQUIA', 'Catamayo'),
    (v_canton_id, 'EC-P-12-C-03-P-02', 'PARROQUIA', 'El Tambo'),
    (v_canton_id, 'EC-P-12-C-03-P-03', 'PARROQUIA', 'Guayquichuma'),
    (v_canton_id, 'EC-P-12-C-03-P-04', 'PARROQUIA', 'San José'),
    (v_canton_id, 'EC-P-12-C-03-P-05', 'PARROQUIA', 'Zambibi');
    
    -- Cantón: CELICA
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-12-C-04';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-12-C-04-P-01', 'PARROQUIA', 'Celica'),
    (v_canton_id, 'EC-P-12-C-04-P-02', 'PARROQUIA', 'Cruzpamba'),
    (v_canton_id, 'EC-P-12-C-04-P-03', 'PARROQUIA', 'Pozul'),
    (v_canton_id, 'EC-P-12-C-04-P-04', 'PARROQUIA', 'Sabanilla'),
    (v_canton_id, 'EC-P-12-C-04-P-05', 'PARROQUIA', 'Tnte. Maximiliano Rodríguez');
    
    -- Cantón: CHAGUARPAMBA
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-12-C-05';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-12-C-05-P-01', 'PARROQUIA', 'Chaguarpamba'),
    (v_canton_id, 'EC-P-12-C-05-P-02', 'PARROQUIA', 'Amarillos'),
    (v_canton_id, 'EC-P-12-C-05-P-03', 'PARROQUIA', 'Buenavista'),
    (v_canton_id, 'EC-P-12-C-05-P-04', 'PARROQUIA', 'El Rosario'),
    (v_canton_id, 'EC-P-12-C-05-P-05', 'PARROQUIA', 'Santa Rufina');
    
    -- Cantón: ESPÍNDOLA
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-12-C-06';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-12-C-06-P-01', 'PARROQUIA', 'Amaluza'),
    (v_canton_id, 'EC-P-12-C-06-P-02', 'PARROQUIA', 'Bellavista'),
    (v_canton_id, 'EC-P-12-C-06-P-03', 'PARROQUIA', 'El Airo'),
    (v_canton_id, 'EC-P-12-C-06-P-04', 'PARROQUIA', 'El Ingenio'),
    (v_canton_id, 'EC-P-12-C-06-P-05', 'PARROQUIA', 'Jimbura'),
    (v_canton_id, 'EC-P-12-C-06-P-06', 'PARROQUIA', 'Santa Teresita');
    
    -- Cantón: GONZANAMÁ
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-12-C-07';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-12-C-07-P-01', 'PARROQUIA', 'Gonzanamá'),
    (v_canton_id, 'EC-P-12-C-07-P-02', 'PARROQUIA', 'Chanchay'),
    (v_canton_id, 'EC-P-12-C-07-P-03', 'PARROQUIA', 'Nambacola'),
    (v_canton_id, 'EC-P-12-C-07-P-04', 'PARROQUIA', 'Purunuma'),
    (v_canton_id, 'EC-P-12-C-07-P-05', 'PARROQUIA', 'Quilanga');
    
    -- Cantón: MACARÁ
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-12-C-08';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-12-C-08-P-01', 'PARROQUIA', 'Macará'),
    (v_canton_id, 'EC-P-12-C-08-P-02', 'PARROQUIA', 'La Victoria'),
    (v_canton_id, 'EC-P-12-C-08-P-03', 'PARROQUIA', 'Larama'),
    (v_canton_id, 'EC-P-12-C-08-P-04', 'PARROQUIA', 'Sabiangos');
    
    -- Cantón: OLMEDO
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-12-C-09';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-12-C-09-P-01', 'PARROQUIA', 'Olmedo'),
    (v_canton_id, 'EC-P-12-C-09-P-02', 'PARROQUIA', 'La Toma');
    
    -- Cantón: PALTAS
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-12-C-10';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-12-C-10-P-01', 'PARROQUIA', 'Catacocha'),
    (v_canton_id, 'EC-P-12-C-10-P-02', 'PARROQUIA', 'Cangonamá'),
    (v_canton_id, 'EC-P-12-C-10-P-03', 'PARROQUIA', 'Guachanamá'),
    (v_canton_id, 'EC-P-12-C-10-P-04', 'PARROQUIA', 'Lauche'),
    (v_canton_id, 'EC-P-12-C-10-P-05', 'PARROQUIA', 'Lourdes'),
    (v_canton_id, 'EC-P-12-C-10-P-06', 'PARROQUIA', 'Orianga'),
    (v_canton_id, 'EC-P-12-C-10-P-07', 'PARROQUIA', 'San Antonio'),
    (v_canton_id, 'EC-P-12-C-10-P-08', 'PARROQUIA', 'Yamana');
    
    -- Cantón: PINDAL
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-12-C-11';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-12-C-11-P-01', 'PARROQUIA', 'Pindal'),
    (v_canton_id, 'EC-P-12-C-11-P-02', 'PARROQUIA', 'Milagros');
    
    -- Cantón: PUYANGO
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-12-C-12';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-12-C-12-P-01', 'PARROQUIA', 'Alamor'),
    (v_canton_id, 'EC-P-12-C-12-P-02', 'PARROQUIA', 'Ciano'),
    (v_canton_id, 'EC-P-12-C-12-P-03', 'PARROQUIA', 'El Arenal'),
    (v_canton_id, 'EC-P-12-C-12-P-04', 'PARROQUIA', 'El Limo'),
    (v_canton_id, 'EC-P-12-C-12-P-05', 'PARROQUIA', 'Mercedes'),
    (v_canton_id, 'EC-P-12-C-12-P-06', 'PARROQUIA', 'Vicente de La Vega');
    
    -- Cantón: QUILANGA
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-12-C-13';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-12-C-13-P-01', 'PARROQUIA', 'Quilanga'),
    (v_canton_id, 'EC-P-12-C-13-P-02', 'PARROQUIA', 'Fundochamba'),
    (v_canton_id, 'EC-P-12-C-13-P-03', 'PARROQUIA', 'San Antonio de las Aradas');
    
    -- Cantón: SARAGURO
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-12-C-14';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-12-C-14-P-01', 'PARROQUIA', 'Saraguro'),
    (v_canton_id, 'EC-P-12-C-14-P-02', 'PARROQUIA', 'El Paraíso'),
    (v_canton_id, 'EC-P-12-C-14-P-03', 'PARROQUIA', 'Lluzhapa'),
    (v_canton_id, 'EC-P-12-C-14-P-04', 'PARROQUIA', 'Manú'),
    (v_canton_id, 'EC-P-12-C-14-P-05', 'PARROQUIA', 'San Pablo de Tenta'),
    (v_canton_id, 'EC-P-12-C-14-P-06', 'PARROQUIA', 'Selva Alegre'),
    (v_canton_id, 'EC-P-12-C-14-P-07', 'PARROQUIA', 'Sumaypamba'),
    (v_canton_id, 'EC-P-12-C-14-P-08', 'PARROQUIA', 'Urdaneta');
    
    -- Cantón: SOZORANGA
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-12-C-15';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-12-C-15-P-01', 'PARROQUIA', 'Sozoranga'),
    (v_canton_id, 'EC-P-12-C-15-P-02', 'PARROQUIA', 'Nueva Fátima'),
    (v_canton_id, 'EC-P-12-C-15-P-03', 'PARROQUIA', 'Tacamoros');
    
    -- Cantón: ZAPOTILLO
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-12-C-16';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-12-C-16-P-01', 'PARROQUIA', 'Zapotillo'),
    (v_canton_id, 'EC-P-12-C-16-P-02', 'PARROQUIA', 'Cazaderos'),
    (v_canton_id, 'EC-P-12-C-16-P-03', 'PARROQUIA', 'Gararema'),
    (v_canton_id, 'EC-P-12-C-16-P-04', 'PARROQUIA', 'Mangahurco'),
    (v_canton_id, 'EC-P-12-C-16-P-05', 'PARROQUIA', 'Palo Santo');

    RAISE NOTICE 'Parroquias insertadas para ESMERALDAS, GALÁPAGOS, GUAYAS, IMBABURA y LOJA';



    -- =====================================================
    -- 13. LOS RÍOS - 13 CANTONES
    -- =====================================================
    
    -- Cantón: BABA
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-13-C-02';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-13-C-02-P-01', 'PARROQUIA', 'Baba'),
    (v_canton_id, 'EC-P-13-C-02-P-02', 'PARROQUIA', 'El Guayabo'),
    (v_canton_id, 'EC-P-13-C-02-P-03', 'PARROQUIA', 'Isla de Bejucal');
    
    -- Cantón: BABAHOYO
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-13-C-01';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-13-C-01-P-01', 'PARROQUIA', 'Babahoyo'),
    (v_canton_id, 'EC-P-13-C-01-P-02', 'PARROQUIA', 'Barreiro'),
    (v_canton_id, 'EC-P-13-C-01-P-03', 'PARROQUIA', 'Caracol'),
    (v_canton_id, 'EC-P-13-C-01-P-04', 'PARROQUIA', 'El Salto'),
    (v_canton_id, 'EC-P-13-C-01-P-05', 'PARROQUIA', 'La Unión'),
    (v_canton_id, 'EC-P-13-C-01-P-06', 'PARROQUIA', 'Pimocha');
    
    -- Cantón: BUENA FE
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-13-C-03';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-13-C-03-P-01', 'PARROQUIA', 'Buena Fe'),
    (v_canton_id, 'EC-P-13-C-03-P-02', 'PARROQUIA', 'Mocache'),
    (v_canton_id, 'EC-P-13-C-03-P-03', 'PARROQUIA', 'Patricia Pilar'),
    (v_canton_id, 'EC-P-13-C-03-P-04', 'PARROQUIA', 'San Jacinto de Buena Fe');
    
    -- Cantón: MOCACHE
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-13-C-04';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-13-C-04-P-01', 'PARROQUIA', 'Mocache'),
    (v_canton_id, 'EC-P-13-C-04-P-02', 'PARROQUIA', 'La Esperanza');
    
    -- Cantón: MONTALVO
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-13-C-05';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-13-C-05-P-01', 'PARROQUIA', 'Montalvo');
    
    -- Cantón: PALENQUE
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-13-C-06';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-13-C-06-P-01', 'PARROQUIA', 'Palenque'),
    (v_canton_id, 'EC-P-13-C-06-P-02', 'PARROQUIA', 'Way');
    
    -- Cantón: PUEBLOVIEJO
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-13-C-07';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-13-C-07-P-01', 'PARROQUIA', 'Puebloviejo'),
    (v_canton_id, 'EC-P-13-C-07-P-02', 'PARROQUIA', 'Puerto Pechiche'),
    (v_canton_id, 'EC-P-13-C-07-P-03', 'PARROQUIA', 'San Juan');
    
    -- Cantón: QUEVEDO
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-13-C-08';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-13-C-08-P-01', 'PARROQUIA', 'Quevedo'),
    (v_canton_id, 'EC-P-13-C-08-P-02', 'PARROQUIA', 'El Carmen'),
    (v_canton_id, 'EC-P-13-C-08-P-03', 'PARROQUIA', 'La Esperanza'),
    (v_canton_id, 'EC-P-13-C-08-P-04', 'PARROQUIA', 'Nicolás Infante'),
    (v_canton_id, 'EC-P-13-C-08-P-05', 'PARROQUIA', 'San Carlos'),
    (v_canton_id, 'EC-P-13-C-08-P-06', 'PARROQUIA', 'Venus del Río');
    
    -- Cantón: QUINSALOMA
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-13-C-09';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-13-C-09-P-01', 'PARROQUIA', 'Quinsaloma');
    
    -- Cantón: URDANETA
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-13-C-10';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-13-C-10-P-01', 'PARROQUIA', 'Catarama'),
    (v_canton_id, 'EC-P-13-C-10-P-02', 'PARROQUIA', 'Ricaurte'),
    (v_canton_id, 'EC-P-13-C-10-P-03', 'PARROQUIA', 'Valencia');
    
    -- Cantón: VALENCIA
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-13-C-11';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-13-C-11-P-01', 'PARROQUIA', 'Valencia');
    
    -- Cantón: VENTANAS
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-13-C-12';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-13-C-12-P-01', 'PARROQUIA', 'Ventanas'),
    (v_canton_id, 'EC-P-13-C-12-P-02', 'PARROQUIA', 'Chacarita'),
    (v_canton_id, 'EC-P-13-C-12-P-03', 'PARROQUIA', 'La Unión'),
    (v_canton_id, 'EC-P-13-C-12-P-04', 'PARROQUIA', 'Quiñonez'),
    (v_canton_id, 'EC-P-13-C-12-P-05', 'PARROQUIA', 'Zapotal');
    
    -- Cantón: VINCES
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-13-C-13';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-13-C-13-P-01', 'PARROQUIA', 'Vinces'),
    (v_canton_id, 'EC-P-13-C-13-P-02', 'PARROQUIA', 'Antonio Sotomayor'),
    (v_canton_id, 'EC-P-13-C-13-P-03', 'PARROQUIA', 'La Maná'),
    (v_canton_id, 'EC-P-13-C-13-P-04', 'PARROQUIA', 'Palestina');

    -- =====================================================
    -- 14. MANABÍ - 22 CANTONES
    -- =====================================================
    
    -- Cantón: PORTOVIEJO
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-14-C-01';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-14-C-01-P-01', 'PARROQUIA', 'Portoviejo'),
    (v_canton_id, 'EC-P-14-C-01-P-02', 'PARROQUIA', 'Andrés de Vera'),
    (v_canton_id, 'EC-P-14-C-01-P-03', 'PARROQUIA', 'Colón'),
    (v_canton_id, 'EC-P-14-C-01-P-04', 'PARROQUIA', 'Picoazá'),
    (v_canton_id, 'EC-P-14-C-01-P-05', 'PARROQUIA', 'Francia'),
    (v_canton_id, 'EC-P-14-C-01-P-06', 'PARROQUIA', 'San Pablo'),
    (v_canton_id, 'EC-P-14-C-01-P-07', 'PARROQUIA', 'Simón Bolívar'),
    (v_canton_id, 'EC-P-14-C-01-P-08', 'PARROQUIA', '12 de Marzo'),
    (v_canton_id, 'EC-P-14-C-01-P-09', 'PARROQUIA', '18 de Octubre'),
    (v_canton_id, 'EC-P-14-C-01-P-10', 'PARROQUIA', '22 de Octubre'),
    (v_canton_id, 'EC-P-14-C-01-P-11', 'PARROQUIA', 'Alajuela'),
    (v_canton_id, 'EC-P-14-C-01-P-12', 'PARROQUIA', 'Chirijos'),
    (v_canton_id, 'EC-P-14-C-01-P-13', 'PARROQUIA', 'Picoazá'),
    (v_canton_id, 'EC-P-14-C-01-P-14', 'PARROQUIA', 'Río Chico');
    
    -- Cantón: BOLÍVAR
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-14-C-02';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-14-C-02-P-01', 'PARROQUIA', 'Calceta'),
    (v_canton_id, 'EC-P-14-C-02-P-02', 'PARROQUIA', 'Membrillo'),
    (v_canton_id, 'EC-P-14-C-02-P-03', 'PARROQUIA', 'Quiroga');
    
    -- Cantón: CHONE
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-14-C-03';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-14-C-03-P-01', 'PARROQUIA', 'Chone'),
    (v_canton_id, 'EC-P-14-C-03-P-02', 'PARROQUIA', 'Boyacá'),
    (v_canton_id, 'EC-P-14-C-03-P-03', 'PARROQUIA', 'Canuto'),
    (v_canton_id, 'EC-P-14-C-03-P-04', 'PARROQUIA', 'Convento'),
    (v_canton_id, 'EC-P-14-C-03-P-05', 'PARROQUIA', 'El Carmen'),
    (v_canton_id, 'EC-P-14-C-03-P-06', 'PARROQUIA', 'Ricaurte'),
    (v_canton_id, 'EC-P-14-C-03-P-07', 'PARROQUIA', 'San Antonio');
    
    -- Cantón: EL CARMEN
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-14-C-04';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-14-C-04-P-01', 'PARROQUIA', 'El Carmen'),
    (v_canton_id, 'EC-P-14-C-04-P-02', 'PARROQUIA', 'Wilfrido Loor'),
    (v_canton_id, 'EC-P-14-C-04-P-03', 'PARROQUIA', '4 de Diciembre');
    
    -- Cantón: FLAVIO ALFARO
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-14-C-05';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-14-C-05-P-01', 'PARROQUIA', 'Flavio Alfaro'),
    (v_canton_id, 'EC-P-14-C-05-P-02', 'PARROQUIA', 'San Francisco de Novillo');
    
    -- Cantón: JAMA
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-14-C-06';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-14-C-06-P-01', 'PARROQUIA', 'Jama');
    
    -- Cantón: JARAMIJÓ
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-14-C-07';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-14-C-07-P-01', 'PARROQUIA', 'Jaramijó');
    
    -- Cantón: JIPIJAPA
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-14-C-08';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-14-C-08-P-01', 'PARROQUIA', 'Jipijapa'),
    (v_canton_id, 'EC-P-14-C-08-P-02', 'PARROQUIA', 'América'),
    (v_canton_id, 'EC-P-14-C-08-P-03', 'PARROQUIA', 'El Anegado'),
    (v_canton_id, 'EC-P-14-C-08-P-04', 'PARROQUIA', 'Julcuy'),
    (v_canton_id, 'EC-P-14-C-08-P-05', 'PARROQUIA', 'La Unión'),
    (v_canton_id, 'EC-P-14-C-08-P-06', 'PARROQUIA', 'Manuel Inocencio Parrales'),
    (v_canton_id, 'EC-P-14-C-08-P-07', 'PARROQUIA', 'Pedregal');
    
    -- Cantón: JUNÍN
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-14-C-09';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-14-C-09-P-01', 'PARROQUIA', 'Junín');
    
    -- Cantón: MANTA
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-14-C-10';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-14-C-10-P-01', 'PARROQUIA', 'Manta'),
    (v_canton_id, 'EC-P-14-C-10-P-02', 'PARROQUIA', 'Eloy Alfaro'),
    (v_canton_id, 'EC-P-14-C-10-P-03', 'PARROQUIA', 'Los Esteros'),
    (v_canton_id, 'EC-P-14-C-10-P-04', 'PARROQUIA', 'San Lorenzo'),
    (v_canton_id, 'EC-P-14-C-10-P-05', 'PARROQUIA', 'Santa Marianita'),
    (v_canton_id, 'EC-P-14-C-10-P-06', 'PARROQUIA', 'Tarqui');
    
    -- Cantón: MONTECRISTI
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-14-C-11';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-14-C-11-P-01', 'PARROQUIA', 'Montecristi'),
    (v_canton_id, 'EC-P-14-C-11-P-02', 'PARROQUIA', 'Anibal San Andrés'),
    (v_canton_id, 'EC-P-14-C-11-P-03', 'PARROQUIA', 'Colorado'),
    (v_canton_id, 'EC-P-14-C-11-P-04', 'PARROQUIA', 'El Chilcal'),
    (v_canton_id, 'EC-P-14-C-11-P-05', 'PARROQUIA', 'La Pila'),
    (v_canton_id, 'EC-P-14-C-11-P-06', 'PARROQUIA', 'Leopoldo Freire');
    
    -- Cantón: OLMEDO
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-14-C-12';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-14-C-12-P-01', 'PARROQUIA', 'Olmedo');
    
    -- Cantón: PAJÁN
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-14-C-13';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-14-C-13-P-01', 'PARROQUIA', 'Paján'),
    (v_canton_id, 'EC-P-14-C-13-P-02', 'PARROQUIA', 'Campozano'),
    (v_canton_id, 'EC-P-14-C-13-P-03', 'PARROQUIA', 'Guale'),
    (v_canton_id, 'EC-P-14-C-13-P-04', 'PARROQUIA', 'Lascano');
    
    -- Cantón: PEDERNALES
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-14-C-14';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-14-C-14-P-01', 'PARROQUIA', 'Pedernales'),
    (v_canton_id, 'EC-P-14-C-14-P-02', 'PARROQUIA', 'Atahualpa'),
    (v_canton_id, 'EC-P-14-C-14-P-03', 'PARROQUIA', 'Coaque');
    
    -- Cantón: PICHINCHA
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-14-C-15';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-14-C-15-P-01', 'PARROQUIA', 'Pichincha'),
    (v_canton_id, 'EC-P-14-C-15-P-02', 'PARROQUIA', 'Bajo de Afuera'),
    (v_canton_id, 'EC-P-14-C-15-P-03', 'PARROQUIA', 'El Anegado');
    
    -- Cantón: PUERTO LÓPEZ
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-14-C-16';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-14-C-16-P-01', 'PARROQUIA', 'Puerto López'),
    (v_canton_id, 'EC-P-14-C-16-P-02', 'PARROQUIA', 'Machalilla'),
    (v_canton_id, 'EC-P-14-C-16-P-03', 'PARROQUIA', 'Salango');
    
    -- Cantón: ROCAFUERTE
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-14-C-17';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-14-C-17-P-01', 'PARROQUIA', 'Rocafuerte'),
    (v_canton_id, 'EC-P-14-C-17-P-02', 'PARROQUIA', 'Bachillero'),
    (v_canton_id, 'EC-P-14-C-17-P-03', 'PARROQUIA', 'La Esperanza'),
    (v_canton_id, 'EC-P-14-C-17-P-04', 'PARROQUIA', 'Membrillal'),
    (v_canton_id, 'EC-P-14-C-17-P-05', 'PARROQUIA', 'Paraíso');
    
    -- Cantón: SAN VICENTE
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-14-C-18';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-14-C-18-P-01', 'PARROQUIA', 'San Vicente'),
    (v_canton_id, 'EC-P-14-C-18-P-02', 'PARROQUIA', 'Canoa');
    
    -- Cantón: SANTA ANA
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-14-C-19';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-14-C-19-P-01', 'PARROQUIA', 'Santa Ana'),
    (v_canton_id, 'EC-P-14-C-19-P-02', 'PARROQUIA', 'Ayacucho'),
    (v_canton_id, 'EC-P-14-C-19-P-03', 'PARROQUIA', 'Honorato Vásquez'),
    (v_canton_id, 'EC-P-14-C-19-P-04', 'PARROQUIA', 'La Unión'),
    (v_canton_id, 'EC-P-14-C-19-P-05', 'PARROQUIA', 'Lodana'),
    (v_canton_id, 'EC-P-14-C-19-P-06', 'PARROQUIA', 'San Pablo');
    
    -- Cantón: SUCRE
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-14-C-20';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-14-C-20-P-01', 'PARROQUIA', 'Bahía de Caráquez'),
    (v_canton_id, 'EC-P-14-C-20-P-02', 'PARROQUIA', 'Charapotó'),
    (v_canton_id, 'EC-P-14-C-20-P-03', 'PARROQUIA', 'La Divina Misericordia'),
    (v_canton_id, 'EC-P-14-C-20-P-04', 'PARROQUIA', 'Leónidas Plaza'),
    (v_canton_id, 'EC-P-14-C-20-P-05', 'PARROQUIA', 'San Isidro'),
    (v_canton_id, 'EC-P-14-C-20-P-06', 'PARROQUIA', 'San Jacinto');
    
    -- Cantón: TOSAGUA
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-14-C-21';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-14-C-21-P-01', 'PARROQUIA', 'Tosagua'),
    (v_canton_id, 'EC-P-14-C-21-P-02', 'PARROQUIA', 'Bachillero'),
    (v_canton_id, 'EC-P-14-C-21-P-03', 'PARROQUIA', 'Angela Casanova');
    
    -- Cantón: VEINTICUATRO DE MAYO
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-14-C-22';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-14-C-22-P-01', 'PARROQUIA', 'Sucre'),
    (v_canton_id, 'EC-P-14-C-22-P-02', 'PARROQUIA', 'Bellavista'),
    (v_canton_id, 'EC-P-14-C-22-P-03', 'PARROQUIA', 'El Carmen'),
    (v_canton_id, 'EC-P-14-C-22-P-04', 'PARROQUIA', 'Noboa');

    -- =====================================================
    -- 15. MORONA SANTIAGO - 13 CANTONES
    -- =====================================================
    
    -- Cantón: MACAS
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-15-C-01';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-15-C-01-P-01', 'PARROQUIA', 'Macas'),
    (v_canton_id, 'EC-P-15-C-01-P-02', 'PARROQUIA', 'Alshi'),
    (v_canton_id, 'EC-P-15-C-01-P-03', 'PARROQUIA', 'Chiguaza'),
    (v_canton_id, 'EC-P-15-C-01-P-04', 'PARROQUIA', 'Cuchaentza'),
    (v_canton_id, 'EC-P-15-C-01-P-05', 'PARROQUIA', 'Río Blanco'),
    (v_canton_id, 'EC-P-15-C-01-P-06', 'PARROQUIA', 'San Isidro'),
    (v_canton_id, 'EC-P-15-C-01-P-07', 'PARROQUIA', 'Sevilla Don Bosco'),
    (v_canton_id, 'EC-P-15-C-01-P-08', 'PARROQUIA', 'Sinai'),
    (v_canton_id, 'EC-P-15-C-01-P-09', 'PARROQUIA', 'Taisha'),
    (v_canton_id, 'EC-P-15-C-01-P-10', 'PARROQUIA', 'Tutinentza');
    
    -- Cantón: GUALAQUIZA
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-15-C-02';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-15-C-02-P-01', 'PARROQUIA', 'Gualaquiza'),
    (v_canton_id, 'EC-P-15-C-02-P-02', 'PARROQUIA', 'Bomboiza'),
    (v_canton_id, 'EC-P-15-C-02-P-03', 'PARROQUIA', 'Chanchaza'),
    (v_canton_id, 'EC-P-15-C-02-P-04', 'PARROQUIA', 'El ideal'),
    (v_canton_id, 'EC-P-15-C-02-P-05', 'PARROQUIA', 'Mercedes Molina'),
    (v_canton_id, 'EC-P-15-C-02-P-06', 'PARROQUIA', 'San Miguel de Cuyes');
    
    -- Cantón: HUAMBOYA
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-15-C-03';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-15-C-03-P-01', 'PARROQUIA', 'Huamboya'),
    (v_canton_id, 'EC-P-15-C-03-P-02', 'PARROQUIA', 'Chiguaza'),
    (v_canton_id, 'EC-P-15-C-03-P-03', 'PARROQUIA', 'San José de Morona');
    
    -- Cantón: LIMÓN INDANZA
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-15-C-04';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-15-C-04-P-01', 'PARROQUIA', 'General Leonidas Plaza'),
    (v_canton_id, 'EC-P-15-C-04-P-02', 'PARROQUIA', 'Indanza'),
    (v_canton_id, 'EC-P-15-C-04-P-03', 'PARROQUIA', 'San Antonio'),
    (v_canton_id, 'EC-P-15-C-04-P-04', 'PARROQUIA', 'San Miguel de Conchay'),
    (v_canton_id, 'EC-P-15-C-04-P-05', 'PARROQUIA', 'Santa Susana de Chiviaza');
    
    -- Cantón: LOGROÑO
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-15-C-05';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-15-C-05-P-01', 'PARROQUIA', 'Logroño'),
    (v_canton_id, 'EC-P-15-C-05-P-02', 'PARROQUIA', 'Shimpis'),
    (v_canton_id, 'EC-P-15-C-05-P-03', 'PARROQUIA', 'Yaupi');
    
    -- Cantón: MORONA
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-15-C-06';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-15-C-06-P-01', 'PARROQUIA', 'Morona'),
    (v_canton_id, 'EC-P-15-C-06-P-02', 'PARROQUIA', 'Cusanga'),
    (v_canton_id, 'EC-P-15-C-06-P-03', 'PARROQUIA', 'Palacios'),
    (v_canton_id, 'EC-P-15-C-06-P-04', 'PARROQUIA', 'San Francisco de Borja'),
    (v_canton_id, 'EC-P-15-C-06-P-05', 'PARROQUIA', 'San José de Rutun');
    
    -- Cantón: PABLO SEXTO
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-15-C-07';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-15-C-07-P-01', 'PARROQUIA', 'Pablo Sexto');
    
    -- Cantón: PALORA
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-15-C-08';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-15-C-08-P-01', 'PARROQUIA', 'Palora'),
    (v_canton_id, 'EC-P-15-C-08-P-02', 'PARROQUIA', 'Arapicos'),
    (v_canton_id, 'EC-P-15-C-08-P-03', 'PARROQUIA', 'Sangay');
    
    -- Cantón: SAN JUAN BOSCO
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-15-C-09';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-15-C-09-P-01', 'PARROQUIA', 'San Juan Bosco'),
    (v_canton_id, 'EC-P-15-C-09-P-02', 'PARROQUIA', 'Pan de Azúcar'),
    (v_canton_id, 'EC-P-15-C-09-P-03', 'PARROQUIA', 'San Carlos de Limón'),
    (v_canton_id, 'EC-P-15-C-09-P-04', 'PARROQUIA', 'San Jacinto de Wakambeis');
    
    -- Cantón: SANTIAGO DE MÉNDEZ
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-15-C-10';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-15-C-10-P-01', 'PARROQUIA', 'Santiago'),
    (v_canton_id, 'EC-P-15-C-10-P-02', 'PARROQUIA', 'Copal'),
    (v_canton_id, 'EC-P-15-C-10-P-03', 'PARROQUIA', 'Chupianza'),
    (v_canton_id, 'EC-P-15-C-10-P-04', 'PARROQUIA', 'Patuca'),
    (v_canton_id, 'EC-P-15-C-10-P-05', 'PARROQUIA', 'San Luis del Acho');
    
    -- Cantón: SUCÚA
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-15-C-11';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-15-C-11-P-01', 'PARROQUIA', 'Sucúa'),
    (v_canton_id, 'EC-P-15-C-11-P-02', 'PARROQUIA', 'Asunción'),
    (v_canton_id, 'EC-P-15-C-11-P-03', 'PARROQUIA', 'Huambi'),
    (v_canton_id, 'EC-P-15-C-11-P-04', 'PARROQUIA', 'Santa Marianita'),
    (v_canton_id, 'EC-P-15-C-11-P-05', 'PARROQUIA', 'San Francisco de Chinimbimi');
    
    -- Cantón: TAISHA
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-15-C-12';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-15-C-12-P-01', 'PARROQUIA', 'Taisha'),
    (v_canton_id, 'EC-P-15-C-12-P-02', 'PARROQUIA', 'Huasaga'),
    (v_canton_id, 'EC-P-15-C-12-P-03', 'PARROQUIA', 'Macuma'),
    (v_canton_id, 'EC-P-15-C-12-P-04', 'PARROQUIA', 'Pumpuentsa'),
    (v_canton_id, 'EC-P-15-C-12-P-05', 'PARROQUIA', 'Tuutinentza');
    
    -- Cantón: TIWINTZA
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-15-C-13';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-15-C-13-P-01', 'PARROQUIA', 'Santiago de Tiwintza'),
    (v_canton_id, 'EC-P-15-C-13-P-02', 'PARROQUIA', 'Chankin'),
    (v_canton_id, 'EC-P-15-C-13-P-03', 'PARROQUIA', 'Numpatkaime');

    -- =====================================================
    -- 16. NAPO - 5 CANTONES
    -- =====================================================
    
    -- Cantón: TENA
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-16-C-01';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-16-C-01-P-01', 'PARROQUIA', 'Tena'),
    (v_canton_id, 'EC-P-16-C-01-P-02', 'PARROQUIA', 'Ahuano'),
    (v_canton_id, 'EC-P-16-C-01-P-03', 'PARROQUIA', 'Chontapunta'),
    (v_canton_id, 'EC-P-16-C-01-P-04', 'PARROQUIA', 'Muyuna'),
    (v_canton_id, 'EC-P-16-C-01-P-05', 'PARROQUIA', 'Pano'),
    (v_canton_id, 'EC-P-16-C-01-P-06', 'PARROQUIA', 'Puerto Misahuallí'),
    (v_canton_id, 'EC-P-16-C-01-P-07', 'PARROQUIA', 'Puerto Napo'),
    (v_canton_id, 'EC-P-16-C-01-P-08', 'PARROQUIA', 'Talag');
    
    -- Cantón: ARCHIDONA
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-16-C-02';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-16-C-02-P-01', 'PARROQUIA', 'Archidona'),
    (v_canton_id, 'EC-P-16-C-02-P-02', 'PARROQUIA', 'Cotundo'),
    (v_canton_id, 'EC-P-16-C-02-P-03', 'PARROQUIA', 'San Pablo de Ushpayacu');
    
    -- Cantón: CARLOS JULIO AROSEMENA TOLA
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-16-C-03';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-16-C-03-P-01', 'PARROQUIA', 'Carlos Julio Arosemena Tola');
    
    -- Cantón: EL CHACO
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-16-C-04';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-16-C-04-P-01', 'PARROQUIA', 'El Chaco'),
    (v_canton_id, 'EC-P-16-C-04-P-02', 'PARROQUIA', 'Gonzalo Díaz de Pineda'),
    (v_canton_id, 'EC-P-16-C-04-P-03', 'PARROQUIA', 'Linares'),
    (v_canton_id, 'EC-P-16-C-04-P-04', 'PARROQUIA', 'Oyacachi'),
    (v_canton_id, 'EC-P-16-C-04-P-05', 'PARROQUIA', 'Santa Rosa');
    
    -- Cantón: QUIJOS
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-16-C-05';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-16-C-05-P-01', 'PARROQUIA', 'Baeza'),
    (v_canton_id, 'EC-P-16-C-05-P-02', 'PARROQUIA', 'Cuyuja'),
    (v_canton_id, 'EC-P-16-C-05-P-03', 'PARROQUIA', 'Papallacta'),
    (v_canton_id, 'EC-P-16-C-05-P-04', 'PARROQUIA', 'San Francisco de Borja'),
    (v_canton_id, 'EC-P-16-C-05-P-05', 'PARROQUIA', 'Cosanga'),
    (v_canton_id, 'EC-P-16-C-05-P-06', 'PARROQUIA', 'San Francisco de las Chontas');

    -- =====================================================
    -- 17. ORELLANA - 4 CANTONES
    -- =====================================================
    
    -- Cantón: FRANCISCO DE ORELLANA
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-17-C-01';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-17-C-01-P-01', 'PARROQUIA', 'Puerto Francisco de Orellana'),
    (v_canton_id, 'EC-P-17-C-01-P-02', 'PARROQUIA', 'Dayuma'),
    (v_canton_id, 'EC-P-17-C-01-P-03', 'PARROQUIA', 'El Dorado'),
    (v_canton_id, 'EC-P-17-C-01-P-04', 'PARROQUIA', 'García Moreno'),
    (v_canton_id, 'EC-P-17-C-01-P-05', 'PARROQUIA', 'Inés Arango'),
    (v_canton_id, 'EC-P-17-C-01-P-06', 'PARROQUIA', 'La Belleza'),
    (v_canton_id, 'EC-P-17-C-01-P-07', 'PARROQUIA', 'Nueva Esperanza'),
    (v_canton_id, 'EC-P-17-C-01-P-08', 'PARROQUIA', 'San José de Guayusa'),
    (v_canton_id, 'EC-P-17-C-01-P-09', 'PARROQUIA', 'San Luis de Armenia');
    
    -- Cantón: AGUARICO
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-17-C-02';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-17-C-02-P-01', 'PARROQUIA', 'Nueva Rocafuerte'),
    (v_canton_id, 'EC-P-17-C-02-P-02', 'PARROQUIA', 'Capitán Augusto Rivadeneira'),
    (v_canton_id, 'EC-P-17-C-02-P-03', 'PARROQUIA', 'Cononaco'),
    (v_canton_id, 'EC-P-17-C-02-P-04', 'PARROQUIA', 'Santa María de Huiririma'),
    (v_canton_id, 'EC-P-17-C-02-P-05', 'PARROQUIA', 'Tiputini');
    
    -- Cantón: LA JOYA DE LOS SACHAS
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-17-C-03';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-17-C-03-P-01', 'PARROQUIA', 'La Joya de los Sachas'),
    (v_canton_id, 'EC-P-17-C-03-P-02', 'PARROQUIA', 'Enokanqui'),
    (v_canton_id, 'EC-P-17-C-03-P-03', 'PARROQUIA', 'San Carlos'),
    (v_canton_id, 'EC-P-17-C-03-P-04', 'PARROQUIA', 'San Sebastián del Coca'),
    (v_canton_id, 'EC-P-17-C-03-P-05', 'PARROQUIA', 'Lago San Pedro');
    
    -- Cantón: LORETO
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-17-C-04';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-17-C-04-P-01', 'PARROQUIA', 'Loreto'),
    (v_canton_id, 'EC-P-17-C-04-P-02', 'PARROQUIA', 'Ávila Viejo'),
    (v_canton_id, 'EC-P-17-C-04-P-03', 'PARROQUIA', 'Puerto Murialdo'),
    (v_canton_id, 'EC-P-17-C-04-P-04', 'PARROQUIA', 'San José de Dahuano'),
    (v_canton_id, 'EC-P-17-C-04-P-05', 'PARROQUIA', 'San Vicente de Huaticocha');

    -- =====================================================
    -- 18. PASTAZA - 4 CANTONES
    -- =====================================================
    
    -- Cantón: PUYO
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-18-C-01';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-18-C-01-P-01', 'PARROQUIA', 'Puyo'),
    (v_canton_id, 'EC-P-18-C-01-P-02', 'PARROQUIA', 'Canelos'),
    (v_canton_id, 'EC-P-18-C-01-P-03', 'PARROQUIA', 'Diez de Agosto'),
    (v_canton_id, 'EC-P-18-C-01-P-04', 'PARROQUIA', 'Fátima'),
    (v_canton_id, 'EC-P-18-C-01-P-05', 'PARROQUIA', 'Montalvo'),
    (v_canton_id, 'EC-P-18-C-01-P-06', 'PARROQUIA', 'Pomona'),
    (v_canton_id, 'EC-P-18-C-01-P-07', 'PARROQUIA', 'Río Corrientes'),
    (v_canton_id, 'EC-P-18-C-01-P-08', 'PARROQUIA', 'Río Tigre'),
    (v_canton_id, 'EC-P-18-C-01-P-09', 'PARROQUIA', 'Sarayacu'),
    (v_canton_id, 'EC-P-18-C-01-P-10', 'PARROQUIA', 'Simón Bolívar'),
    (v_canton_id, 'EC-P-18-C-01-P-11', 'PARROQUIA', 'Tarqui'),
    (v_canton_id, 'EC-P-18-C-01-P-12', 'PARROQUIA', 'Teniente Hugo Ortiz'),
    (v_canton_id, 'EC-P-18-C-01-P-13', 'PARROQUIA', 'Veracruz');
    
    -- Cantón: ARAJUNO
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-18-C-02';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-18-C-02-P-01', 'PARROQUIA', 'Arajuno'),
    (v_canton_id, 'EC-P-18-C-02-P-02', 'PARROQUIA', 'Curaray');
    
    -- Cantón: MERA
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-18-C-03';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-18-C-03-P-01', 'PARROQUIA', 'Mera'),
    (v_canton_id, 'EC-P-18-C-03-P-02', 'PARROQUIA', 'Shell');
    
    -- Cantón: SANTA CLARA
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-18-C-04';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-18-C-04-P-01', 'PARROQUIA', 'Santa Clara');

    RAISE NOTICE 'Parroquias insertadas para LOS RÍOS, MANABÍ, MORONA SANTIAGO, NAPO, ORELLANA y PASTAZA';



    -- =====================================================
    -- 19. PICHINCHA - 8 CANTONES
    -- =====================================================
    
    -- Cantón: QUITO
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-19-C-01';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-19-C-01-P-01', 'PARROQUIA', 'Belisario Quevedo'),
    (v_canton_id, 'EC-P-19-C-01-P-02', 'PARROQUIA', 'Carcelén'),
    (v_canton_id, 'EC-P-19-C-01-P-03', 'PARROQUIA', 'Centro Histórico'),
    (v_canton_id, 'EC-P-19-C-01-P-04', 'PARROQUIA', 'Chilibulo'),
    (v_canton_id, 'EC-P-19-C-01-P-05', 'PARROQUIA', 'Chillogallo'),
    (v_canton_id, 'EC-P-19-C-01-P-06', 'PARROQUIA', 'Chimbacalle'),
    (v_canton_id, 'EC-P-19-C-01-P-07', 'PARROQUIA', 'Cochapamba'),
    (v_canton_id, 'EC-P-19-C-01-P-08', 'PARROQUIA', 'Comité del Pueblo'),
    (v_canton_id, 'EC-P-19-C-01-P-09', 'PARROQUIA', 'Concepción'),
    (v_canton_id, 'EC-P-19-C-01-P-10', 'PARROQUIA', 'Condado'),
    (v_canton_id, 'EC-P-19-C-01-P-11', 'PARROQUIA', 'Cotocollao'),
    (v_canton_id, 'EC-P-19-C-01-P-12', 'PARROQUIA', 'Ecuador'),
    (v_canton_id, 'EC-P-19-C-01-P-13', 'PARROQUIA', 'El Batán'),
    (v_canton_id, 'EC-P-19-C-01-P-14', 'PARROQUIA', 'El Inca'),
    (v_canton_id, 'EC-P-19-C-01-P-15', 'PARROQUIA', 'El Salvador'),
    (v_canton_id, 'EC-P-19-C-01-P-16', 'PARROQUIA', 'Guamaní'),
    (v_canton_id, 'EC-P-19-C-01-P-17', 'PARROQUIA', 'Iñaquito'),
    (v_canton_id, 'EC-P-19-C-01-P-18', 'PARROQUIA', 'Itchimbía'),
    (v_canton_id, 'EC-P-19-C-01-P-19', 'PARROQUIA', 'Jipijapa'),
    (v_canton_id, 'EC-P-19-C-01-P-20', 'PARROQUIA', 'Kennedy'),
    (v_canton_id, 'EC-P-19-C-01-P-21', 'PARROQUIA', 'La Argelia'),
    (v_canton_id, 'EC-P-19-C-01-P-22', 'PARROQUIA', 'La Ecuatoriana'),
    (v_canton_id, 'EC-P-19-C-01-P-23', 'PARROQUIA', 'La Ferroviaria'),
    (v_canton_id, 'EC-P-19-C-01-P-24', 'PARROQUIA', 'La Floresta'),
    (v_canton_id, 'EC-P-19-C-01-P-25', 'PARROQUIA', 'La Libertad'),
    (v_canton_id, 'EC-P-19-C-01-P-26', 'PARROQUIA', 'La Magdalena'),
    (v_canton_id, 'EC-P-19-C-01-P-27', 'PARROQUIA', 'La Mena'),
    (v_canton_id, 'EC-P-19-C-01-P-28', 'PARROQUIA', 'La Vicentina'),
    (v_canton_id, 'EC-P-19-C-01-P-29', 'PARROQUIA', 'Ponceano'),
    (v_canton_id, 'EC-P-19-C-01-P-30', 'PARROQUIA', 'Puengasí'),
    (v_canton_id, 'EC-P-19-C-01-P-31', 'PARROQUIA', 'Quitumbe'),
    (v_canton_id, 'EC-P-19-C-01-P-32', 'PARROQUIA', 'Rumipamba'),
    (v_canton_id, 'EC-P-19-C-01-P-33', 'PARROQUIA', 'San Antonio'),
    (v_canton_id, 'EC-P-19-C-01-P-34', 'PARROQUIA', 'San Blas'),
    (v_canton_id, 'EC-P-19-C-01-P-35', 'PARROQUIA', 'San Juan'),
    (v_canton_id, 'EC-P-19-C-01-P-36', 'PARROQUIA', 'Solanda'),
    (v_canton_id, 'EC-P-19-C-01-P-37', 'PARROQUIA', 'Turubamba'),
    (v_canton_id, 'EC-P-19-C-01-P-38', 'PARROQUIA', 'Alangasí'),
    (v_canton_id, 'EC-P-19-C-01-P-39', 'PARROQUIA', 'Amaguaña'),
    (v_canton_id, 'EC-P-19-C-01-P-40', 'PARROQUIA', 'Atahualpa'),
    (v_canton_id, 'EC-P-19-C-01-P-41', 'PARROQUIA', 'Calacalí'),
    (v_canton_id, 'EC-P-19-C-01-P-42', 'PARROQUIA', 'Calderón'),
    (v_canton_id, 'EC-P-19-C-01-P-43', 'PARROQUIA', 'Conocoto'),
    (v_canton_id, 'EC-P-19-C-01-P-44', 'PARROQUIA', 'Cumbayá'),
    (v_canton_id, 'EC-P-19-C-01-P-45', 'PARROQUIA', 'El Quinche'),
    (v_canton_id, 'EC-P-19-C-01-P-46', 'PARROQUIA', 'Guayllabamba'),
    (v_canton_id, 'EC-P-19-C-01-P-47', 'PARROQUIA', 'La Merced'),
    (v_canton_id, 'EC-P-19-C-01-P-48', 'PARROQUIA', 'Llano Chico'),
    (v_canton_id, 'EC-P-19-C-01-P-49', 'PARROQUIA', 'Nayón'),
    (v_canton_id, 'EC-P-19-C-01-P-50', 'PARROQUIA', 'Nono'),
    (v_canton_id, 'EC-P-19-C-01-P-51', 'PARROQUIA', 'Pifo'),
    (v_canton_id, 'EC-P-19-C-01-P-52', 'PARROQUIA', 'Pintag'),
    (v_canton_id, 'EC-P-19-C-01-P-53', 'PARROQUIA', 'Pomasqui'),
    (v_canton_id, 'EC-P-19-C-01-P-54', 'PARROQUIA', 'Puéllaro'),
    (v_canton_id, 'EC-P-19-C-01-P-55', 'PARROQUIA', 'Puembo'),
    (v_canton_id, 'EC-P-19-C-01-P-56', 'PARROQUIA', 'San Antonio de Pichincha'),
    (v_canton_id, 'EC-P-19-C-01-P-57', 'PARROQUIA', 'San José de Minas'),
    (v_canton_id, 'EC-P-19-C-01-P-58', 'PARROQUIA', 'Tababela'),
    (v_canton_id, 'EC-P-19-C-01-P-59', 'PARROQUIA', 'Tumbaco'),
    (v_canton_id, 'EC-P-19-C-01-P-60', 'PARROQUIA', 'Yaruquí'),
    (v_canton_id, 'EC-P-19-C-01-P-61', 'PARROQUIA', 'Zámbiza');
    
    -- Cantón: CAYAMBE
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-19-C-02';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-19-C-02-P-01', 'PARROQUIA', 'Cayambe'),
    (v_canton_id, 'EC-P-19-C-02-P-02', 'PARROQUIA', 'Ascázubi'),
    (v_canton_id, 'EC-P-19-C-02-P-03', 'PARROQUIA', 'Cangahua'),
    (v_canton_id, 'EC-P-19-C-02-P-04', 'PARROQUIA', 'Olmedo'),
    (v_canton_id, 'EC-P-19-C-02-P-05', 'PARROQUIA', 'Otón'),
    (v_canton_id, 'EC-P-19-C-02-P-06', 'PARROQUIA', 'Santa Rosa de Cuzubamba');
    
    -- Cantón: MEJÍA
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-19-C-03';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-19-C-03-P-01', 'PARROQUIA', 'Machachi'),
    (v_canton_id, 'EC-P-19-C-03-P-02', 'PARROQUIA', 'Aloag'),
    (v_canton_id, 'EC-P-19-C-03-P-03', 'PARROQUIA', 'Aloasí'),
    (v_canton_id, 'EC-P-19-C-03-P-04', 'PARROQUIA', 'Cutuglagua'),
    (v_canton_id, 'EC-P-19-C-03-P-05', 'PARROQUIA', 'El Chaupi'),
    (v_canton_id, 'EC-P-19-C-03-P-06', 'PARROQUIA', 'Manuel Cornejo'),
    (v_canton_id, 'EC-P-19-C-03-P-07', 'PARROQUIA', 'Tandapi'),
    (v_canton_id, 'EC-P-19-C-03-P-08', 'PARROQUIA', 'Uyumbicho');
    
    -- Cantón: PEDRO MONCAYO
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-19-C-04';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-19-C-04-P-01', 'PARROQUIA', 'Tabacundo'),
    (v_canton_id, 'EC-P-19-C-04-P-02', 'PARROQUIA', 'La Esperanza'),
    (v_canton_id, 'EC-P-19-C-04-P-03', 'PARROQUIA', 'Malchinguí'),
    (v_canton_id, 'EC-P-19-C-04-P-04', 'PARROQUIA', 'Tocachi');
    
    -- Cantón: RUMIÑAHUI
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-19-C-05';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-19-C-05-P-01', 'PARROQUIA', 'Sangolquí'),
    (v_canton_id, 'EC-P-19-C-05-P-02', 'PARROQUIA', 'Cotogchoa'),
    (v_canton_id, 'EC-P-19-C-05-P-03', 'PARROQUIA', 'Rumipamba'),
    (v_canton_id, 'EC-P-19-C-05-P-04', 'PARROQUIA', 'San Pedro de Taboada'),
    (v_canton_id, 'EC-P-19-C-05-P-05', 'PARROQUIA', 'San Rafael');
    
    -- Cantón: SAN MIGUEL DE LOS BANCOS
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-19-C-06';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-19-C-06-P-01', 'PARROQUIA', 'San Miguel de los Bancos'),
    (v_canton_id, 'EC-P-19-C-06-P-02', 'PARROQUIA', 'Mindo');
    
    -- Cantón: PEDRO VICENTE MALDONADO
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-19-C-07';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-19-C-07-P-01', 'PARROQUIA', 'Pedro Vicente Maldonado');
    
    -- Cantón: PUERTO QUITO
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-19-C-08';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-19-C-08-P-01', 'PARROQUIA', 'Puerto Quito');

    -- =====================================================
    -- 20. SANTA ELENA - 3 CANTONES
    -- =====================================================
    
    -- Cantón: SANTA ELENA
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-20-C-01';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-20-C-01-P-01', 'PARROQUIA', 'Santa Elena'),
    (v_canton_id, 'EC-P-20-C-01-P-02', 'PARROQUIA', 'Atahualpa'),
    (v_canton_id, 'EC-P-20-C-01-P-03', 'PARROQUIA', 'Colonche'),
    (v_canton_id, 'EC-P-20-C-01-P-04', 'PARROQUIA', 'Chanduy'),
    (v_canton_id, 'EC-P-20-C-01-P-05', 'PARROQUIA', 'El Tambo'),
    (v_canton_id, 'EC-P-20-C-01-P-06', 'PARROQUIA', 'Manglaralto'),
    (v_canton_id, 'EC-P-20-C-01-P-07', 'PARROQUIA', 'Montañita'),
    (v_canton_id, 'EC-P-20-C-01-P-08', 'PARROQUIA', 'San José de Ancón'),
    (v_canton_id, 'EC-P-20-C-01-P-09', 'PARROQUIA', 'Simón Bolívar');
    
    -- Cantón: LA LIBERTAD
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-20-C-02';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-20-C-02-P-01', 'PARROQUIA', 'La Libertad');
    
    -- Cantón: SALINAS
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-20-C-03';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-20-C-03-P-01', 'PARROQUIA', 'Salinas'),
    (v_canton_id, 'EC-P-20-C-03-P-02', 'PARROQUIA', 'Anconcito'),
    (v_canton_id, 'EC-P-20-C-03-P-03', 'PARROQUIA', 'José Luis Tamayo'),
    (v_canton_id, 'EC-P-20-C-03-P-04', 'PARROQUIA', 'Santa Rosa');

    -- =====================================================
    -- 21. SANTO DOMINGO DE LOS TSÁCHILAS - 2 CANTONES
    -- =====================================================
    
    -- Cantón: SANTO DOMINGO
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-21-C-01';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-21-C-01-P-01', 'PARROQUIA', 'Santo Domingo de los Colorados'),
    (v_canton_id, 'EC-P-21-C-01-P-02', 'PARROQUIA', 'Abraham Calazacón'),
    (v_canton_id, 'EC-P-21-C-01-P-03', 'PARROQUIA', 'Alluriquín'),
    (v_canton_id, 'EC-P-21-C-01-P-04', 'PARROQUIA', 'El Esfuerzo'),
    (v_canton_id, 'EC-P-21-C-01-P-05', 'PARROQUIA', 'El Rosario'),
    (v_canton_id, 'EC-P-21-C-01-P-06', 'PARROQUIA', 'Puerto Limón'),
    (v_canton_id, 'EC-P-21-C-01-P-07', 'PARROQUIA', 'Santa María del Toachi'),
    (v_canton_id, 'EC-P-21-C-01-P-08', 'PARROQUIA', 'Valle Hermoso');
    
    -- Cantón: LA CONCORDIA
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-21-C-02';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-21-C-02-P-01', 'PARROQUIA', 'La Concordia'),
    (v_canton_id, 'EC-P-21-C-02-P-02', 'PARROQUIA', 'La Vilma'),
    (v_canton_id, 'EC-P-21-C-02-P-03', 'PARROQUIA', 'Monterrey'),
    (v_canton_id, 'EC-P-21-C-02-P-04', 'PARROQUIA', 'Plan Piloto');

    -- =====================================================
    -- 22. SUCUMBÍOS - 7 CANTONES
    -- =====================================================
    
    -- Cantón: LAGO AGRIO (Nueva Loja)
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-22-C-05';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-22-C-05-P-01', 'PARROQUIA', 'Nueva Loja'),
    (v_canton_id, 'EC-P-22-C-05-P-02', 'PARROQUIA', 'Cuyabeno'),
    (v_canton_id, 'EC-P-22-C-05-P-03', 'PARROQUIA', 'Dureno'),
    (v_canton_id, 'EC-P-22-C-05-P-04', 'PARROQUIA', 'El Eno'),
    (v_canton_id, 'EC-P-22-C-05-P-05', 'PARROQUIA', 'Jambelí'),
    (v_canton_id, 'EC-P-22-C-05-P-06', 'PARROQUIA', 'Santa Cecilia'),
    (v_canton_id, 'EC-P-22-C-05-P-07', 'PARROQUIA', 'General Farfán');
    
    -- Cantón: CASCALES
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-22-C-02';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-22-C-02-P-01', 'PARROQUIA', 'Cascales'),
    (v_canton_id, 'EC-P-22-C-02-P-02', 'PARROQUIA', 'El Dorado de Cascales');
    
    -- Cantón: CUYABENO
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-22-C-03';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-22-C-03-P-01', 'PARROQUIA', 'Tarapoa'),
    (v_canton_id, 'EC-P-22-C-03-P-02', 'PARROQUIA', 'Cuyabeno'),
    (v_canton_id, 'EC-P-22-C-03-P-03', 'PARROQUIA', 'Aguas Negras');
    
    -- Cantón: GONZALO PIZARRO
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-22-C-04';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-22-C-04-P-01', 'PARROQUIA', 'Lumbaqui'),
    (v_canton_id, 'EC-P-22-C-04-P-02', 'PARROQUIA', 'El Reventador'),
    (v_canton_id, 'EC-P-22-C-04-P-03', 'PARROQUIA', 'Gonzalo Pizarro');
    
    -- Cantón: PUTUMAYO
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-22-C-06';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-22-C-06-P-01', 'PARROQUIA', 'Puerto El Carmen de Putumayo'),
    (v_canton_id, 'EC-P-22-C-06-P-02', 'PARROQUIA', 'Palma Roja'),
    (v_canton_id, 'EC-P-22-C-06-P-03', 'PARROQUIA', 'Puerto Rodríguez');
    
    -- Cantón: SHUSHUFINDI
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-22-C-07';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-22-C-07-P-01', 'PARROQUIA', 'Shushufindi'),
    (v_canton_id, 'EC-P-22-C-07-P-02', 'PARROQUIA', 'Limoncocha'),
    (v_canton_id, 'EC-P-22-C-07-P-03', 'PARROQUIA', 'Pañacocha'),
    (v_canton_id, 'EC-P-22-C-07-P-04', 'PARROQUIA', 'San Pedro de los Cofanes'),
    (v_canton_id, 'EC-P-22-C-07-P-05', 'PARROQUIA', 'Siete de Julio');
    
    -- Cantón: SUCUMBÍOS
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-22-C-01';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-22-C-01-P-01', 'PARROQUIA', 'La Bonita'),
    (v_canton_id, 'EC-P-22-C-01-P-02', 'PARROQUIA', 'El Playón de San Francisco'),
    (v_canton_id, 'EC-P-22-C-01-P-03', 'PARROQUIA', 'La Sofía'),
    (v_canton_id, 'EC-P-22-C-01-P-04', 'PARROQUIA', 'Rosa Florida');

    -- =====================================================
    -- 23. TUNGURAHUA - 9 CANTONES
    -- =====================================================
    
    -- Cantón: AMBATO
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-23-C-01';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-23-C-01-P-01', 'PARROQUIA', 'Ambato'),
    (v_canton_id, 'EC-P-23-C-01-P-02', 'PARROQUIA', 'Atocha'),
    (v_canton_id, 'EC-P-23-C-01-P-03', 'PARROQUIA', 'Celiano Monge'),
    (v_canton_id, 'EC-P-23-C-01-P-04', 'PARROQUIA', 'Huachi Chico'),
    (v_canton_id, 'EC-P-23-C-01-P-05', 'PARROQUIA', 'Huachi Grande'),
    (v_canton_id, 'EC-P-23-C-01-P-06', 'PARROQUIA', 'La Matriz'),
    (v_canton_id, 'EC-P-23-C-01-P-07', 'PARROQUIA', 'La Merced'),
    (v_canton_id, 'EC-P-23-C-01-P-08', 'PARROQUIA', 'Miraflores'),
    (v_canton_id, 'EC-P-23-C-01-P-09', 'PARROQUIA', 'Pishilata'),
    (v_canton_id, 'EC-P-23-C-01-P-10', 'PARROQUIA', 'San Francisco'),
    (v_canton_id, 'EC-P-23-C-01-P-11', 'PARROQUIA', 'Ambato'),
    (v_canton_id, 'EC-P-23-C-01-P-12', 'PARROQUIA', 'Augusto N. Martínez'),
    (v_canton_id, 'EC-P-23-C-01-P-13', 'PARROQUIA', 'Constantino Fernández'),
    (v_canton_id, 'EC-P-23-C-01-P-14', 'PARROQUIA', 'Izamba'),
    (v_canton_id, 'EC-P-23-C-01-P-15', 'PARROQUIA', 'Juan Benigno Vela'),
    (v_canton_id, 'EC-P-23-C-01-P-16', 'PARROQUIA', 'Pasa'),
    (v_canton_id, 'EC-P-23-C-01-P-17', 'PARROQUIA', 'Picaihua'),
    (v_canton_id, 'EC-P-23-C-01-P-18', 'PARROQUIA', 'Quisapincha'),
    (v_canton_id, 'EC-P-23-C-01-P-19', 'PARROQUIA', 'San Bartolomé de Pinllo'),
    (v_canton_id, 'EC-P-23-C-01-P-20', 'PARROQUIA', 'Santa Rosa'),
    (v_canton_id, 'EC-P-23-C-01-P-21', 'PARROQUIA', 'Totoras'),
    (v_canton_id, 'EC-P-23-C-01-P-22', 'PARROQUIA', 'Unamuncho');
    
    -- Cantón: BAÑOS DE AGUA SANTA
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-23-C-02';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-23-C-02-P-01', 'PARROQUIA', 'Baños de Agua Santa'),
    (v_canton_id, 'EC-P-23-C-02-P-02', 'PARROQUIA', 'Lligua'),
    (v_canton_id, 'EC-P-23-C-02-P-03', 'PARROQUIA', 'Río Negro'),
    (v_canton_id, 'EC-P-23-C-02-P-04', 'PARROQUIA', 'Ulba');
    
    -- Cantón: CEVALLOS
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-23-C-03';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-23-C-03-P-01', 'PARROQUIA', 'Cevallos');
    
    -- Cantón: MOCHA
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-23-C-04';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-23-C-04-P-01', 'PARROQUIA', 'Mocha');
    
    -- Cantón: PATATE
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-23-C-05';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-23-C-05-P-01', 'PARROQUIA', 'Patate'),
    (v_canton_id, 'EC-P-23-C-05-P-02', 'PARROQUIA', 'El Triunfo'),
    (v_canton_id, 'EC-P-23-C-05-P-03', 'PARROQUIA', 'Los Andes'),
    (v_canton_id, 'EC-P-23-C-05-P-04', 'PARROQUIA', 'Sucre');
    
    -- Cantón: PELILEO
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-23-C-06';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-23-C-06-P-01', 'PARROQUIA', 'Pelileo'),
    (v_canton_id, 'EC-P-23-C-06-P-02', 'PARROQUIA', 'Benigno Vela'),
    (v_canton_id, 'EC-P-23-C-06-P-03', 'PARROQUIA', 'Bolívar'),
    (v_canton_id, 'EC-P-23-C-06-P-04', 'PARROQUIA', 'Cotaló'),
    (v_canton_id, 'EC-P-23-C-06-P-05', 'PARROQUIA', 'El Rosario'),
    (v_canton_id, 'EC-P-23-C-06-P-06', 'PARROQUIA', 'García Moreno'),
    (v_canton_id, 'EC-P-23-C-06-P-07', 'PARROQUIA', 'Salasaca'),
    (v_canton_id, 'EC-P-23-C-06-P-08', 'PARROQUIA', 'Sucre');
    
    -- Cantón: PÍLLARO
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-23-C-07';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-23-C-07-P-01', 'PARROQUIA', 'Píllaro'),
    (v_canton_id, 'EC-P-23-C-07-P-02', 'PARROQUIA', 'Baquerizo Moreno'),
    (v_canton_id, 'EC-P-23-C-07-P-03', 'PARROQUIA', 'Emilio María Terán'),
    (v_canton_id, 'EC-P-23-C-07-P-04', 'PARROQUIA', 'Marcos Espinel'),
    (v_canton_id, 'EC-P-23-C-07-P-05', 'PARROQUIA', 'Presidente Urbina'),
    (v_canton_id, 'EC-P-23-C-07-P-06', 'PARROQUIA', 'San Andrés'),
    (v_canton_id, 'EC-P-23-C-07-P-07', 'PARROQUIA', 'San José de Poaló');
    
    -- Cantón: QUERO
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-23-C-08';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-23-C-08-P-01', 'PARROQUIA', 'Quero'),
    (v_canton_id, 'EC-P-23-C-08-P-02', 'PARROQUIA', 'Rumipamba'),
    (v_canton_id, 'EC-P-23-C-08-P-03', 'PARROQUIA', 'Yanayacu');
    
    -- Cantón: TISALEO
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-23-C-09';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-23-C-09-P-01', 'PARROQUIA', 'Tisaleo');

    -- =====================================================
    -- 24. ZAMORA CHINCHIPE - 9 CANTONES
    -- =====================================================
    
    -- Cantón: ZAMORA
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-24-C-01';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-24-C-01-P-01', 'PARROQUIA', 'Zamora'),
    (v_canton_id, 'EC-P-24-C-01-P-02', 'PARROQUIA', 'Cumbaratza'),
    (v_canton_id, 'EC-P-24-C-01-P-03', 'PARROQUIA', 'Guadalupe'),
    (v_canton_id, 'EC-P-24-C-01-P-04', 'PARROQUIA', 'Imbana'),
    (v_canton_id, 'EC-P-24-C-01-P-05', 'PARROQUIA', 'Sabanilla'),
    (v_canton_id, 'EC-P-24-C-01-P-06', 'PARROQUIA', 'Timbara'),
    (v_canton_id, 'EC-P-24-C-01-P-07', 'PARROQUIA', 'San Carlos de las Minas'),
    (v_canton_id, 'EC-P-24-C-01-P-08', 'PARROQUIA', 'Zumbi');
    
    -- Cantón: CENTINELA DEL CÓNDOR
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-24-C-02';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-24-C-02-P-01', 'PARROQUIA', 'Zumbi'),
    (v_canton_id, 'EC-P-24-C-02-P-02', 'PARROQUIA', 'Panguintza'),
    (v_canton_id, 'EC-P-24-C-02-P-03', 'PARROQUIA', 'San José de Morona');
    
    -- Cantón: CHINCHIPE
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-24-C-03';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-24-C-03-P-01', 'PARROQUIA', 'Zumba'),
    (v_canton_id, 'EC-P-24-C-03-P-02', 'PARROQUIA', 'Chito'),
    (v_canton_id, 'EC-P-24-C-03-P-03', 'PARROQUIA', 'El Chorro'),
    (v_canton_id, 'EC-P-24-C-03-P-04', 'PARROQUIA', 'El Porvenir'),
    (v_canton_id, 'EC-P-24-C-03-P-05', 'PARROQUIA', 'La Chonta'),
    (v_canton_id, 'EC-P-24-C-03-P-06', 'PARROQUIA', 'Pucapamba'),
    (v_canton_id, 'EC-P-24-C-03-P-07', 'PARROQUIA', 'San Francisco del Vergel'),
    (v_canton_id, 'EC-P-24-C-03-P-08', 'PARROQUIA', 'San Pedro de la Bendita'),
    (v_canton_id, 'EC-P-24-C-03-P-09', 'PARROQUIA', 'Valladolid');
    
    -- Cantón: EL PANGUI
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-24-C-04';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-24-C-04-P-01', 'PARROQUIA', 'El Pangui'),
    (v_canton_id, 'EC-P-24-C-04-P-02', 'PARROQUIA', 'Tundayme');
    
    -- Cantón: NANGARITZA
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-24-C-05';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-24-C-05-P-01', 'PARROQUIA', 'Nangaritza'),
    (v_canton_id, 'EC-P-24-C-05-P-02', 'PARROQUIA', 'Guayzimi'),
    (v_canton_id, 'EC-P-24-C-05-P-03', 'PARROQUIA', 'Zurmi');
    
    -- Cantón: PALANDA
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-24-C-06';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-24-C-06-P-01', 'PARROQUIA', 'Palanda'),
    (v_canton_id, 'EC-P-24-C-06-P-02', 'PARROQUIA', 'El Porvenir'),
    (v_canton_id, 'EC-P-24-C-06-P-03', 'PARROQUIA', 'Valladolid');
    
    -- Cantón: PAQUISHA
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-24-C-07';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-24-C-07-P-01', 'PARROQUIA', 'Paquisha'),
    (v_canton_id, 'EC-P-24-C-07-P-02', 'PARROQUIA', 'Nuevo Quito');
    
    -- Cantón: YACUAMBI
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-24-C-08';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-24-C-08-P-01', 'PARROQUIA', 'Yacuambi'),
    (v_canton_id, 'EC-P-24-C-08-P-02', 'PARROQUIA', 'La Paz'),
    (v_canton_id, 'EC-P-24-C-08-P-03', 'PARROQUIA', 'Tutupali');
    
    -- Cantón: YANTZAZA
    SELECT id INTO v_canton_id FROM core.ubicaciones WHERE codigo = 'EC-P-24-C-09';
    INSERT INTO core.ubicaciones (padre_id, codigo, tipo, nombre) VALUES
    (v_canton_id, 'EC-P-24-C-09-P-01', 'PARROQUIA', 'Yantzaza'),
    (v_canton_id, 'EC-P-24-C-09-P-02', 'PARROQUIA', 'Chicaña'),
    (v_canton_id, 'EC-P-24-C-09-P-03', 'PARROQUIA', 'El Pangui'),
    (v_canton_id, 'EC-P-24-C-09-P-04', 'PARROQUIA', 'Los Encuentros');

    RAISE NOTICE 'Todas las parroquias de Ecuador han sido insertadas exitosamente';
    RAISE NOTICE 'Total de parroquias insertadas: aproximadamente 1,500 parroquias en 24 provincias y 221 cantones';
    
	
    
END $$;
