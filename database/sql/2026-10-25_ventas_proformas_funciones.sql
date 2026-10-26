-- ===========================================================================
-- PROFORMAS · LAS FUNCIONES
-- ===========================================================================
-- Mismas costumbres que el resto del sistema: todo entra por funciones
-- SECURITY DEFINER, cada una recibe el contexto de auditoría y devuelve
-- jsonb con `success`, `message` y `data`, y el controlador no escribe una
-- sola sentencia contra las tablas.
--
-- La diferencia con un catálogo es que aquí se guarda un DOCUMENTO COMPLETO
-- de una vez —cabecera y líneas—, así que no hay un «crear» y un «modificar»
-- con treinta parámetros sueltos sino un fn_proformas_guardar que recibe dos
-- jsonb. Dentro, las líneas se borran y se vuelven a escribir: son parte del
-- documento, no registros con vida propia, y nadie las referencia por id.
\set ON_ERROR_STOP on

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. LA ARITMÉTICA DE UNA LÍNEA, EN UN SOLO SITIO
-- ---------------------------------------------------------------------------
-- El orden del redondeo importa y tiene que ser SIEMPRE el mismo: primero el
-- subtotal a dos decimales, sobre él el descuento, y el IVA sobre lo que
-- queda. Hacerlo en otro orden —o redondear sólo al final— da diferencias de
-- un centavo que el cliente ve y nosotros no sabemos explicar.
--
-- El navegador repite este mismo cálculo para enseñar los totales mientras se
-- escribe; esta función es la que manda, y al guardar se recalcula todo.
CREATE OR REPLACE FUNCTION ventas.fn_proformas_linea_calcular(
    p_cantidad  numeric,
    p_precio    numeric,
    p_descuento numeric,
    p_iva       numeric
)
RETURNS jsonb
LANGUAGE sql
IMMUTABLE
AS $fn$
    WITH a AS (
        SELECT round(COALESCE(p_cantidad, 0) * COALESCE(p_precio, 0), 2) AS subtotal
    ), b AS (
        SELECT subtotal,
               round(subtotal * COALESCE(p_descuento, 0) / 100.0, 2) AS descuento_valor
          FROM a
    ), c AS (
        SELECT subtotal, descuento_valor,
               subtotal - descuento_valor AS base
          FROM b
    ), d AS (
        SELECT subtotal, descuento_valor, base,
               round(base * COALESCE(p_iva, 0) / 100.0, 2) AS iva_valor
          FROM c
    )
    SELECT jsonb_build_object(
        'subtotal',        subtotal,
        'descuento_valor', descuento_valor,
        'base',            base,
        'iva_valor',       iva_valor,
        'total',           base + iva_valor
    ) FROM d;
$fn$;

COMMENT ON FUNCTION ventas.fn_proformas_linea_calcular(numeric,numeric,numeric,numeric) IS
'Subtotal, descuento, base, IVA y total de una línea. El orden del redondeo es parte del contrato: el navegador lo repite igual.';

-- ---------------------------------------------------------------------------
-- 2. LOS TOTALES DE LA CABECERA, DESDE EL DETALLE
-- ---------------------------------------------------------------------------
-- Nunca se confía en lo que manda la pantalla: se suma lo que hay guardado.
-- Gravado y exento se separan porque es lo que pide el papel —y lo que pedirá
-- la factura electrónica el día que esto se convierta en factura—.
CREATE OR REPLACE FUNCTION ventas.fn_proformas_recalcular(p_id bigint)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'ventas'
AS $fn$
BEGIN
    UPDATE ventas.proformas p
       SET subtotal         = COALESCE(t.subtotal, 0),
           descuento_total  = COALESCE(t.descuento, 0),
           subtotal_gravado = COALESCE(t.gravado, 0),
           subtotal_exento  = COALESCE(t.exento, 0),
           iva_total        = COALESCE(t.iva, 0),
           total            = COALESCE(t.base, 0) + COALESCE(t.iva, 0)
      FROM (SELECT SUM(d.subtotal)        AS subtotal,
                   SUM(d.descuento_valor) AS descuento,
                   SUM(d.base)            AS base,
                   SUM(d.iva_valor)       AS iva,
                   SUM(CASE WHEN d.iva_porcentaje > 0 THEN d.base ELSE 0 END) AS gravado,
                   SUM(CASE WHEN d.iva_porcentaje = 0 THEN d.base ELSE 0 END) AS exento
              FROM ventas.proformas_detalle d
             WHERE d.proforma_id = p_id) t
     WHERE p.id = p_id;
END;
$fn$;

-- ---------------------------------------------------------------------------
-- 3. LAS ETIQUETAS DEL ESTADO
-- ---------------------------------------------------------------------------
-- En la base y no en la pantalla, porque los filtros de la rejilla buscan
-- sobre lo que se VE («Enviada») y no sobre el código que hay debajo.
CREATE OR REPLACE FUNCTION ventas.fn_proformas_estado_etiqueta(p_estado text)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $fn$
    SELECT CASE p_estado
               WHEN 'BORRADOR'  THEN 'Borrador'
               WHEN 'ENVIADA'   THEN 'Enviada'
               WHEN 'APROBADA'  THEN 'Aprobada'
               WHEN 'RECHAZADA' THEN 'Rechazada'
               WHEN 'VENCIDA'   THEN 'Vencida'
               WHEN 'ANULADA'   THEN 'Anulada'
               ELSE COALESCE(p_estado, '')
           END;
$fn$;

-- ---------------------------------------------------------------------------
-- 4. EL DOCUMENTO, COMO LO VE LA PANTALLA
-- ---------------------------------------------------------------------------
-- Se parte en dos objetos y se unen con `||` a propósito: jsonb_build_object
-- no admite más de cien argumentos y una cabecera de proforma se acerca.
CREATE OR REPLACE FUNCTION ventas.fn_proformas_json(p_id bigint)
RETURNS jsonb
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO 'pg_catalog', 'ventas', 'seguridad'
AS $fn$
    SELECT jsonb_build_object(
        'id',                     p.id,
        'numero',                 p.numero,
        'cliente_id',             p.cliente_id,
        'cliente_identificacion', p.cliente_identificacion,
        'cliente_nombre',         p.cliente_nombre,
        'cliente_direccion',      p.cliente_direccion,
        'cliente_telefono',       p.cliente_telefono,
        'cliente_email',          p.cliente_email,
        'grupo_cliente_id',       p.grupo_cliente_id,
        'grupo_nombre',           (SELECT g.nombre FROM ventas.grupos_clientes g WHERE g.id = p.grupo_cliente_id),
        'vendedor_usuario_id',    p.vendedor_usuario_id,
        'vendedor_nombre',        ventas.fn_nombre_usuario(p.vendedor_usuario_id),
        'sucursal_id',            p.sucursal_id,
        'sucursal_nombre',        (SELECT s.nombre FROM ventas.sucursales s WHERE s.id = p.sucursal_id),
        'bodega_id',              p.bodega_id,
        'fecha',                  to_char(p.fecha, 'YYYY-MM-DD'),
        'validez_dias',           p.validez_dias,
        'fecha_vence',            to_char(p.fecha_vence, 'YYYY-MM-DD'),
        'forma_pago',             p.forma_pago,
        'dias_credito',           p.dias_credito,
        'descuento_porcentaje',   p.descuento_porcentaje,
        'moneda',                 p.moneda,
        'estado',                 p.estado,
        'estado_etiqueta',        ventas.fn_proformas_estado_etiqueta(p.estado)
    ) || jsonb_build_object(
        'motivo_rechazo',   p.motivo_rechazo,
        'fecha_envio',      to_char(p.fecha_envio,     'YYYY-MM-DD HH24:MI:SS'),
        'fecha_respuesta',  to_char(p.fecha_respuesta, 'YYYY-MM-DD HH24:MI:SS'),
        'subtotal',         p.subtotal,
        'descuento_total',  p.descuento_total,
        'subtotal_gravado', p.subtotal_gravado,
        'subtotal_exento',  p.subtotal_exento,
        'iva_total',        p.iva_total,
        'total',            p.total,
        'observaciones',    p.observaciones,
        'condiciones',      p.condiciones,
        -- Vencida es un CÁLCULO, no un estado guardado: una proforma enviada
        -- el día 1 con quince días de validez está vencida el día 17 aunque
        -- nadie haya pasado a marcarla. El estado VENCIDA existe para cuando
        -- alguien lo haga (ver fn_proformas_vencidas_marcar).
        'vencida',          (p.estado = 'ENVIADA' AND p.fecha_vence < CURRENT_DATE),
        'dias_para_vencer', (p.fecha_vence - CURRENT_DATE),
        'puede_editarse',   (p.estado IN ('BORRADOR', 'ENVIADA') AND p.deleted_at IS NULL),
        'en_papelera',      (p.deleted_at IS NOT NULL),
        'created_by',       p.created_by,
        'updated_by',       p.updated_by,
        'created_at',       to_char(p.created_at, 'YYYY-MM-DD HH24:MI:SS'),
        'updated_at',       to_char(p.updated_at, 'YYYY-MM-DD HH24:MI:SS'),
        'detalle', COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
                       'id',                   d.id,
                       'orden',                d.orden,
                       'producto_id',          d.producto_id,
                       'codigo',               d.codigo,
                       'descripcion',          d.descripcion,
                       'unidad',               d.unidad,
                       'cantidad',             d.cantidad,
                       'precio_unitario',      d.precio_unitario,
                       'descuento_porcentaje', d.descuento_porcentaje,
                       'iva_porcentaje',       d.iva_porcentaje,
                       'subtotal',             d.subtotal,
                       'descuento_valor',      d.descuento_valor,
                       'base',                 d.base,
                       'iva_valor',            d.iva_valor,
                       'total',                d.total,
                       'observacion',          d.observacion
                   ) ORDER BY d.orden, d.id)
              FROM ventas.proformas_detalle d
             WHERE d.proforma_id = p.id), '[]'::jsonb),
        -- El IVA desglosado por tarifa: es lo que se imprime al pie
        'iva_desglose', COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
                       'porcentaje', x.iva_porcentaje,
                       'base',       x.base,
                       'valor',      x.valor
                   ) ORDER BY x.iva_porcentaje)
              FROM (SELECT d.iva_porcentaje,
                           SUM(d.base)      AS base,
                           SUM(d.iva_valor) AS valor
                      FROM ventas.proformas_detalle d
                     WHERE d.proforma_id = p.id
                     GROUP BY d.iva_porcentaje) x), '[]'::jsonb)
    )
      FROM ventas.proformas p
     WHERE p.id = p_id;
$fn$;

COMMIT;
