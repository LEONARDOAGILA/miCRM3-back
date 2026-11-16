-- ===========================================================================
-- PROFORMAS (ventas.proformas + ventas.proformas_detalle)
-- ===========================================================================
-- La primera tabla del sistema que no es un catálogo sino un DOCUMENTO, y eso
-- cambia tres cosas de fondo respecto a lo que hay hoy:
--
-- 1. LLEVA UNA FOTO DE A QUIÉN SE LE HIZO. El cliente puede cambiarse de
--    nombre, de dirección o de grupo mañana; la proforma que se le entregó
--    hoy no cambia. De ahí las columnas cliente_* repetidas: no son un
--    descuido de normalización, son el documento.
--
-- 2. NO SE ACTIVA NI SE DESACTIVA: tiene ESTADO. Un catálogo está activo o
--    no; una proforma nace BORRADOR, se envía, y acaba APROBADA, RECHAZADA,
--    VENCIDA o ANULADA. Por eso no hay columna «activo» —sería un segundo
--    sitio donde decir lo mismo— y la rejilla enseña el estado.
--
-- 3. LA ARITMÉTICA LA HACE LA BASE. El navegador calcula para que el usuario
--    vea los totales mientras escribe, pero lo que se guarda lo vuelve a
--    calcular fn_proformas_guardar a partir de cantidad, precio, descuento e
--    IVA de cada línea. Lo que mande la pantalla en subtotal o total SE
--    IGNORA: así no hay manera de guardar un documento que no cuadre.
--
-- Lo que sí es igual que en el resto: papelera (deleted_at/deleted_by),
-- auditoría por disparador, listado paginado con los filtros por columna, y
-- el alcance del usuario —quien no es administrador ve las proformas de los
-- vendedores que tiene a cargo, igual que en clientes—.
--
-- Nota sobre bodega_id: la columna queda puesta porque una proforma sale de
-- algún sitio, pero core.bodegas está vacía y no hay módulo de stock, así que
-- hoy no se pide en la pantalla. Cuando haya bodegas, el campo ya está.
\set ON_ERROR_STOP on

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. LA CABECERA
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS ventas.proformas (
    id      bigserial    PRIMARY KEY,
    numero  varchar(20)  NOT NULL,

    -- A quién. El id para poder volver a su ficha; el resto es la FOTO con la
    -- que se imprimió el documento (ver el punto 1 de arriba).
    cliente_id             bigint NOT NULL,
    cliente_identificacion varchar(20),
    cliente_nombre         varchar(255),
    cliente_direccion      text,
    cliente_telefono       varchar(30),
    cliente_email          varchar(100),
    -- De qué grupo salieron las condiciones, para saber por qué este cliente
    -- llevó este descuento cuando alguien lo pregunte dentro de seis meses
    grupo_cliente_id       bigint,

    -- Quién y desde dónde
    vendedor_usuario_id bigint,
    sucursal_id         bigint,
    bodega_id           bigint,

    -- Cuándo, y hasta cuándo vale. La fecha de vencimiento no se escribe: es
    -- la fecha más los días de validez, y la calcula la base.
    fecha        date    NOT NULL DEFAULT CURRENT_DATE,
    validez_dias integer NOT NULL DEFAULT 15,
    fecha_vence  date    GENERATED ALWAYS AS (fecha + validez_dias) STORED,

    -- Las condiciones con las que se ofertó. Vienen del cliente o de su grupo
    -- pero se COPIAN aquí: si mañana le cambian la forma de pago, lo que se
    -- ofreció sigue siendo lo que dice el papel.
    forma_pago           varchar(20),
    dias_credito         integer,
    -- El descuento que se propuso para todas las líneas. Cada línea puede
    -- llevar el suyo; éste es sólo el que se ofreció por omisión.
    descuento_porcentaje numeric(5,2) NOT NULL DEFAULT 0,
    moneda               varchar(3)   NOT NULL DEFAULT 'USD',

    estado          varchar(20) NOT NULL DEFAULT 'BORRADOR',
    motivo_rechazo  text,
    fecha_envio     timestamptz,
    fecha_respuesta timestamptz,

    -- Los totales, calculados por la base a partir del detalle
    subtotal         numeric(14,2) NOT NULL DEFAULT 0,
    descuento_total  numeric(14,2) NOT NULL DEFAULT 0,
    subtotal_gravado numeric(14,2) NOT NULL DEFAULT 0,
    subtotal_exento  numeric(14,2) NOT NULL DEFAULT 0,
    iva_total        numeric(14,2) NOT NULL DEFAULT 0,
    total            numeric(14,2) NOT NULL DEFAULT 0,

    observaciones text,
    condiciones   text,

    created_at timestamptz  NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamptz  NOT NULL DEFAULT CURRENT_TIMESTAMP,
    created_by varchar(100),
    updated_by varchar(100),
    deleted_at timestamptz,
    deleted_by varchar(100),

    CONSTRAINT ck_proformas_estado    CHECK (estado IN ('BORRADOR','ENVIADA','APROBADA','RECHAZADA','VENCIDA','ANULADA')),
    CONSTRAINT ck_proformas_validez   CHECK (validez_dias BETWEEN 0 AND 365),
    CONSTRAINT ck_proformas_descuento CHECK (descuento_porcentaje BETWEEN 0 AND 100),

    CONSTRAINT fk_proformas_cliente  FOREIGN KEY (cliente_id)          REFERENCES ventas.clientes(id),
    CONSTRAINT fk_proformas_grupo    FOREIGN KEY (grupo_cliente_id)    REFERENCES ventas.grupos_clientes(id),
    CONSTRAINT fk_proformas_vendedor FOREIGN KEY (vendedor_usuario_id) REFERENCES seguridad.users(id),
    CONSTRAINT fk_proformas_sucursal FOREIGN KEY (sucursal_id)         REFERENCES ventas.sucursales(id),
    CONSTRAINT fk_proformas_bodega   FOREIGN KEY (bodega_id)           REFERENCES core.bodegas(id)
);

-- El número es único PARA SIEMPRE, también contra lo borrado: un número de
-- documento que se reutiliza es un número que no identifica nada.
CREATE UNIQUE INDEX IF NOT EXISTS uq_proformas_numero ON ventas.proformas (numero);

CREATE INDEX IF NOT EXISTS idx_proformas_cliente  ON ventas.proformas (cliente_id)          WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_proformas_vendedor ON ventas.proformas (vendedor_usuario_id) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_proformas_estado   ON ventas.proformas (estado)              WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_proformas_fecha    ON ventas.proformas (fecha DESC)          WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_proformas_papelera ON ventas.proformas (deleted_at)          WHERE deleted_at IS NOT NULL;

-- ---------------------------------------------------------------------------
-- 2. EL DETALLE
-- ---------------------------------------------------------------------------
-- Las líneas viven y mueren con su documento (ON DELETE CASCADE) y no tienen
-- papelera propia: media proforma en la papelera no es nada.
--
-- Guardan también una foto del producto —código, descripción, unidad—: lo que
-- se cotizó es lo que decía el catálogo ese día. producto_id es ANULABLE a
-- propósito, para poder cotizar algo que todavía no está dado de alta.
CREATE TABLE IF NOT EXISTS ventas.proformas_detalle (
    id          bigserial PRIMARY KEY,
    proforma_id bigint    NOT NULL,
    orden       integer   NOT NULL DEFAULT 1,

    producto_id bigint,
    codigo      varchar(50),
    descripcion varchar(500) NOT NULL,
    unidad      varchar(20),

    -- Lo que se escribe
    cantidad             numeric(14,4) NOT NULL DEFAULT 1,
    precio_unitario      numeric(14,4) NOT NULL DEFAULT 0,
    descuento_porcentaje numeric(5,2)  NOT NULL DEFAULT 0,
    iva_porcentaje       numeric(5,2)  NOT NULL DEFAULT 0,

    -- Lo que se calcula (lo hace fn_proformas_guardar, no la pantalla)
    subtotal        numeric(14,2) NOT NULL DEFAULT 0,
    descuento_valor numeric(14,2) NOT NULL DEFAULT 0,
    base            numeric(14,2) NOT NULL DEFAULT 0,
    iva_valor       numeric(14,2) NOT NULL DEFAULT 0,
    total           numeric(14,2) NOT NULL DEFAULT 0,

    observacion varchar(255),

    created_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    created_by varchar(100),

    CONSTRAINT ck_proformas_detalle_cantidad  CHECK (cantidad > 0),
    CONSTRAINT ck_proformas_detalle_precio    CHECK (precio_unitario >= 0),
    CONSTRAINT ck_proformas_detalle_descuento CHECK (descuento_porcentaje BETWEEN 0 AND 100),
    CONSTRAINT ck_proformas_detalle_iva       CHECK (iva_porcentaje BETWEEN 0 AND 100),

    CONSTRAINT fk_proformas_detalle_proforma FOREIGN KEY (proforma_id) REFERENCES ventas.proformas(id) ON DELETE CASCADE,
    CONSTRAINT fk_proformas_detalle_producto FOREIGN KEY (producto_id) REFERENCES inventarios.productos(id)
);

CREATE INDEX IF NOT EXISTS idx_proformas_detalle_proforma ON ventas.proformas_detalle (proforma_id, orden);
CREATE INDEX IF NOT EXISTS idx_proformas_detalle_producto ON ventas.proformas_detalle (producto_id);

-- ---------------------------------------------------------------------------
-- 3. AUDITORÍA
-- ---------------------------------------------------------------------------
-- A PROPÓSITO SÓLO EN LA CABECERA. Si se auditara línea a línea, corregir el
-- precio de una proforma de veinte renglones dejaría cuarenta asientos en el
-- registro y no se podría leer nada. El documento es la unidad.
DROP TRIGGER IF EXISTS trigger_proformas_set_users ON ventas.proformas;
CREATE TRIGGER trigger_proformas_set_users
    BEFORE INSERT OR UPDATE ON ventas.proformas
    FOR EACH ROW EXECUTE FUNCTION auditoria.fn_set_audit_users();

DROP TRIGGER IF EXISTS trigger_proformas_updated_at ON ventas.proformas;
CREATE TRIGGER trigger_proformas_updated_at
    BEFORE UPDATE ON ventas.proformas
    FOR EACH ROW EXECUTE FUNCTION auditoria.fn_update_updated_at_column();

DROP TRIGGER IF EXISTS trg_proformas_audit ON ventas.proformas;
CREATE TRIGGER trg_proformas_audit
    AFTER INSERT OR UPDATE OR DELETE ON ventas.proformas
    FOR EACH ROW EXECUTE FUNCTION auditoria.fn_auditar_cambios();

-- En el detalle, sólo el «lo puso quien lo puso»
DROP TRIGGER IF EXISTS trigger_proformas_detalle_set_users ON ventas.proformas_detalle;
CREATE TRIGGER trigger_proformas_detalle_set_users
    BEFORE INSERT ON ventas.proformas_detalle
    FOR EACH ROW EXECUTE FUNCTION auditoria.fn_set_audit_users();

-- ---------------------------------------------------------------------------
-- 4. EL NÚMERO
-- ---------------------------------------------------------------------------
-- Una secuencia, no un MAX(numero)+1: con dos vendedores guardando a la vez,
-- el MAX le da el mismo número a los dos. La secuencia no se repite nunca, y
-- si una transacción se deshace deja un hueco —un hueco es barato; un número
-- duplicado, no—.
CREATE SEQUENCE IF NOT EXISTS ventas.proformas_numero_seq AS bigint START 1;

CREATE OR REPLACE FUNCTION ventas.fn_proformas_numero_nuevo()
RETURNS varchar
LANGUAGE sql
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'ventas'
AS $fn$
    SELECT 'PRO-' || lpad(nextval('ventas.proformas_numero_seq')::text, 6, '0');
$fn$;

COMMENT ON FUNCTION ventas.fn_proformas_numero_nuevo() IS
'El siguiente número de proforma. CONSUME la secuencia: sólo se llama al guardar, nunca para enseñar un número por adelantado.';

COMMIT;
