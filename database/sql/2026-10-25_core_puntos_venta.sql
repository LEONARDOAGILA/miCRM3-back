-- ===========================================================================
-- PUNTOS DE VENTA (core.puntos_venta)
-- ===========================================================================
-- La tabla YA EXISTÍA, vacía y colgando de dos tablas que no usa nadie:
-- core.sucursales (0 filas) y core.regiones (0 filas). Las sucursales de
-- verdad —las que mantiene la pantalla de Ventas y las que tienen clientes
-- asignados— están en ventas.sucursales.
--
-- Esto la pone en servicio:
--
--   · la cuelga de ventas.sucursales, que es donde están las de verdad;
--   · le quita region_id, que apuntaba a una tabla vacía y obligaba a
--     inventarse una región para poder dar de alta un punto (la sucursal ya
--     dice dónde está el punto);
--   · le añade la papelera y la auditoría que tiene el resto del sistema.
--
-- Se puede hacer sin miedo porque la tabla está VACÍA y no la referencia
-- nadie (comprobado contra pg_constraint).
--
-- QUÉ ES UN PUNTO DE VENTA AQUÍ: una caja. Una sucursal tiene varias, cada
-- una con su número —el 1, el 2…—, y lo que las distingue de verdad es que
-- CADA UNA CUADRA SU PROPIO DINERO. De ahí que lo siguiente que necesite un
-- punto de venta sean sus cuentas contables (ver el fichero de al lado).
\set ON_ERROR_STOP on

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. DE QUÉ SUCURSAL CUELGA
-- ---------------------------------------------------------------------------
ALTER TABLE core.puntos_venta DROP CONSTRAINT IF EXISTS fk_sucursales_almacen_id;
ALTER TABLE core.puntos_venta DROP CONSTRAINT IF EXISTS fk_regiones_almacen_id;

ALTER TABLE core.puntos_venta
    ADD CONSTRAINT fk_puntos_venta_sucursal
    FOREIGN KEY (sucursal_id) REFERENCES ventas.sucursales(id);

-- La región sobraba: la sucursal ya dice dónde está el punto, y la tabla a
-- la que apuntaba está vacía (habría que inventarse una región para poder
-- crear una caja).
ALTER TABLE core.puntos_venta DROP COLUMN IF EXISTS region_id;

-- ---------------------------------------------------------------------------
-- 2. LO QUE LE FALTABA
-- ---------------------------------------------------------------------------
ALTER TABLE core.puntos_venta ADD COLUMN IF NOT EXISTS descripcion text;
ALTER TABLE core.puntos_venta ADD COLUMN IF NOT EXISTS deleted_at timestamptz;
ALTER TABLE core.puntos_venta ADD COLUMN IF NOT EXISTS deleted_by varchar(100);

ALTER TABLE core.puntos_venta ALTER COLUMN activo SET DEFAULT true;
UPDATE core.puntos_venta SET activo = true WHERE activo IS NULL;
ALTER TABLE core.puntos_venta ALTER COLUMN activo SET NOT NULL;

ALTER TABLE core.puntos_venta ALTER COLUMN created_at SET DEFAULT CURRENT_TIMESTAMP;
ALTER TABLE core.puntos_venta ALTER COLUMN updated_at SET DEFAULT CURRENT_TIMESTAMP;

-- El número es el de la caja dentro de su sucursal: «Caja 1», «Caja 2». Tres
-- dígitos porque es lo que admite el punto de emisión del SRI el día que esto
-- emita documentos; hoy sólo sirve para nombrarlas y ordenarlas.
ALTER TABLE core.puntos_venta DROP CONSTRAINT IF EXISTS ck_puntos_venta_numero;
ALTER TABLE core.puntos_venta
    ADD CONSTRAINT ck_puntos_venta_numero CHECK (numero BETWEEN 1 AND 999);

ALTER TABLE core.puntos_venta DROP CONSTRAINT IF EXISTS ck_puntos_venta_nombre;
ALTER TABLE core.puntos_venta
    ADD CONSTRAINT ck_puntos_venta_nombre CHECK (length(TRIM(nombre)) >= 2);

-- ---------------------------------------------------------------------------
-- 3. LO QUE NO SE PUEDE REPETIR
-- ---------------------------------------------------------------------------
-- El código es único en toda la empresa (ya lo era). El número, dentro de su
-- sucursal: dos «Caja 1» en la misma tienda no se distinguen al cuadrar.
--
-- Los dos índices CUENTAN TAMBIÉN LO BORRADO en el caso del código —un
-- código que vuelve de la papelera no puede chocar con otro— pero no en el
-- del número, que sí se puede reutilizar cuando la caja anterior se eliminó.
CREATE UNIQUE INDEX IF NOT EXISTS uq_puntos_venta_sucursal_numero
    ON core.puntos_venta (sucursal_id, numero)
    WHERE deleted_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_puntos_venta_sucursal
    ON core.puntos_venta (sucursal_id) WHERE deleted_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_puntos_venta_papelera
    ON core.puntos_venta (deleted_at) WHERE deleted_at IS NOT NULL;

-- ---------------------------------------------------------------------------
-- 4. AUDITORÍA
-- ---------------------------------------------------------------------------
DROP TRIGGER IF EXISTS trigger_puntos_venta_set_users ON core.puntos_venta;
CREATE TRIGGER trigger_puntos_venta_set_users
    BEFORE INSERT OR UPDATE ON core.puntos_venta
    FOR EACH ROW EXECUTE FUNCTION auditoria.fn_set_audit_users();

DROP TRIGGER IF EXISTS trigger_puntos_venta_updated_at ON core.puntos_venta;
CREATE TRIGGER trigger_puntos_venta_updated_at
    BEFORE UPDATE ON core.puntos_venta
    FOR EACH ROW EXECUTE FUNCTION auditoria.fn_update_updated_at_column();

DROP TRIGGER IF EXISTS trg_puntos_venta_audit ON core.puntos_venta;
CREATE TRIGGER trg_puntos_venta_audit
    AFTER INSERT OR UPDATE OR DELETE ON core.puntos_venta
    FOR EACH ROW EXECUTE FUNCTION auditoria.fn_auditar_cambios();

COMMENT ON TABLE core.puntos_venta IS
'Las cajas de cada sucursal. Cada una cuadra su propio dinero, y por eso tiene sus propias cuentas contables (contabilidad.cuentas_config, ámbito PUNTO_VENTA).';

COMMIT;
