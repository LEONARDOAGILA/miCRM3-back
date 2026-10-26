-- ===========================================================================
-- PROFORMAS · LO QUE SE LES HACE
-- ===========================================================================
-- Papelera (mandar, restaurar, borrar de verdad, vaciar), el cambio de estado
-- con sus reglas, renovar una vencida y duplicar.
--
-- EL CICLO DE VIDA, de una vez:
--
--     BORRADOR ──enviar──> ENVIADA ──> APROBADA        (fin)
--         │                   │   └──> RECHAZADA ──> ANULADA
--         │                   │   └──> VENCIDA ──renovar──> ENVIADA
--         │                   └──corregir──> BORRADOR
--         └──────────────anular──────────────> ANULADA  (fin)
--
-- APROBADA y ANULADA no salen de ahí: la primera porque ya es un compromiso
-- y la segunda porque anular es, justamente, cerrar la puerta. Lo que se
-- quiera volver a ofertar se DUPLICA, que deja la anterior como está y crea
-- un documento nuevo con su propio número.
\set ON_ERROR_STOP on

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. A LA PAPELERA
-- ---------------------------------------------------------------------------
-- Una proforma APROBADA no se borra: es lo que el cliente aceptó, y si la
-- operación se cayó eso se dice anulándola, no haciéndola desaparecer.
CREATE OR REPLACE FUNCTION ventas.fn_proformas_eliminar(
    p_id             bigint,
    p_usuario_id     bigint            DEFAULT NULL,
    p_usuario_login  character varying DEFAULT NULL,
    p_usuario_nombre character varying DEFAULT NULL,
    p_ip_address     inet              DEFAULT NULL,
    p_user_agent     text              DEFAULT NULL,
    p_request_id     uuid              DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'ventas', 'auditoria'
AS $fn$
DECLARE
    v_numero varchar(20);
    v_estado varchar(20);
BEGIN
    PERFORM ventas.fn_contexto_auditoria('ventas.proformas',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    SELECT p.numero, p.estado INTO v_numero, v_estado
      FROM ventas.proformas p WHERE p.id = p_id AND p.deleted_at IS NULL;

    IF v_numero IS NULL THEN
        RAISE EXCEPTION 'La proforma no existe o ya está en la papelera' USING ERRCODE = 'P0016';
    END IF;
    IF v_estado = 'APROBADA' THEN
        RAISE EXCEPTION 'La proforma % está aprobada: si la operación no va, anúlela en lugar de borrarla', v_numero
            USING ERRCODE = 'P0007';
    END IF;

    UPDATE ventas.proformas
       SET deleted_at = CURRENT_TIMESTAMP,
           deleted_by = COALESCE(p_usuario_login, current_user)
     WHERE id = p_id;

    RETURN jsonb_build_object('success', true,
                              'message', 'La proforma ' || v_numero || ' se envió a la papelera de reciclaje');
END;
$fn$;

-- ---------------------------------------------------------------------------
-- 2. DEVOLVER DE LA PAPELERA
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ventas.fn_proformas_restaurar(
    p_ids            jsonb,
    p_usuario_id     bigint            DEFAULT NULL,
    p_usuario_login  character varying DEFAULT NULL,
    p_usuario_nombre character varying DEFAULT NULL,
    p_ip_address     inet              DEFAULT NULL,
    p_user_agent     text              DEFAULT NULL,
    p_request_id     uuid              DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'ventas', 'auditoria'
AS $fn$
DECLARE
    v_cuantas integer := 0;
BEGIN
    PERFORM ventas.fn_contexto_auditoria('ventas.proformas',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    IF p_ids IS NULL OR jsonb_typeof(p_ids) <> 'array' OR jsonb_array_length(p_ids) = 0 THEN
        RAISE EXCEPTION 'No se indicó ninguna proforma' USING ERRCODE = 'P0001';
    END IF;

    WITH vuelven AS (
        UPDATE ventas.proformas
           SET deleted_at = NULL, deleted_by = NULL
         WHERE deleted_at IS NOT NULL
           AND id IN (SELECT (value #>> '{}')::bigint FROM jsonb_array_elements(p_ids))
        RETURNING id
    )
    SELECT COUNT(*) INTO v_cuantas FROM vuelven;

    RETURN jsonb_build_object('success', true,
        'message', CASE v_cuantas
                       WHEN 0 THEN 'No había nada que restaurar'
                       WHEN 1 THEN 'Se restauró 1 proforma'
                       ELSE 'Se restauraron ' || v_cuantas || ' proformas'
                   END,
        'data', jsonb_build_object('restauradas', v_cuantas));
END;
$fn$;

-- ---------------------------------------------------------------------------
-- 3. BORRAR DE VERDAD
-- ---------------------------------------------------------------------------
-- Las líneas se van con el documento por la clave ajena (ON DELETE CASCADE),
-- así que aquí no hay que acordarse de borrarlas.
CREATE OR REPLACE FUNCTION ventas.fn_proformas_eliminar_definitivo(
    p_ids            jsonb,
    p_usuario_id     bigint            DEFAULT NULL,
    p_usuario_login  character varying DEFAULT NULL,
    p_usuario_nombre character varying DEFAULT NULL,
    p_ip_address     inet              DEFAULT NULL,
    p_user_agent     text              DEFAULT NULL,
    p_request_id     uuid              DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'ventas', 'auditoria'
AS $fn$
DECLARE
    v_cuantas integer := 0;
BEGIN
    PERFORM ventas.fn_contexto_auditoria('ventas.proformas',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    IF p_ids IS NULL OR jsonb_typeof(p_ids) <> 'array' OR jsonb_array_length(p_ids) = 0 THEN
        RAISE EXCEPTION 'No se indicó ninguna proforma' USING ERRCODE = 'P0001';
    END IF;

    -- SÓLO LO QUE ESTÁ EN LA PAPELERA. Es la red de seguridad de siempre: un
    -- id suelto mal mandado no puede llevarse un documento que está en uso.
    WITH fuera AS (
        DELETE FROM ventas.proformas
         WHERE deleted_at IS NOT NULL
           AND id IN (SELECT (value #>> '{}')::bigint FROM jsonb_array_elements(p_ids))
        RETURNING id
    )
    SELECT COUNT(*) INTO v_cuantas FROM fuera;

    RETURN jsonb_build_object('success', true,
        'message', CASE v_cuantas
                       WHEN 0 THEN 'No había nada que eliminar'
                       WHEN 1 THEN 'Se eliminó 1 proforma definitivamente'
                       ELSE 'Se eliminaron ' || v_cuantas || ' proformas definitivamente'
                   END,
        'data', jsonb_build_object('eliminadas', v_cuantas));
END;
$fn$;

-- ---------------------------------------------------------------------------
-- 4. VACIAR LA PAPELERA
-- ---------------------------------------------------------------------------
-- No lleva ids: vacía lo que haya. Quien tenga el permiso, se lo lleva todo.
CREATE OR REPLACE FUNCTION ventas.fn_proformas_papelera_vaciar(
    p_usuario_id     bigint            DEFAULT NULL,
    p_usuario_login  character varying DEFAULT NULL,
    p_usuario_nombre character varying DEFAULT NULL,
    p_ip_address     inet              DEFAULT NULL,
    p_user_agent     text              DEFAULT NULL,
    p_request_id     uuid              DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'ventas', 'auditoria'
AS $fn$
DECLARE
    v_cuantas integer := 0;
BEGIN
    PERFORM ventas.fn_contexto_auditoria('ventas.proformas',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    WITH fuera AS (
        DELETE FROM ventas.proformas WHERE deleted_at IS NOT NULL RETURNING id
    )
    SELECT COUNT(*) INTO v_cuantas FROM fuera;

    RETURN jsonb_build_object('success', true,
        'message', CASE v_cuantas
                       WHEN 0 THEN 'La papelera ya estaba vacía'
                       WHEN 1 THEN 'Se eliminó 1 proforma'
                       ELSE 'Se eliminaron ' || v_cuantas || ' proformas'
                   END,
        'data', jsonb_build_object('eliminadas', v_cuantas));
END;
$fn$;

-- ---------------------------------------------------------------------------
-- 5. CAMBIAR DE ESTADO
-- ---------------------------------------------------------------------------
-- Las transiciones están escritas arriba, en la cabecera del fichero. Aquí se
-- comprueban: un cambio que no esté en esa lista no se hace, y se dice por
-- qué. Las fechas de envío y de respuesta se ponen solas —son el cuándo de
-- ese cambio— y el motivo es OBLIGATORIO al rechazar: un «no» sin motivo no
-- sirve para nada seis meses después.
CREATE OR REPLACE FUNCTION ventas.fn_proformas_cambiar_estado(
    p_id             bigint,
    p_estado         text,
    p_motivo         text              DEFAULT NULL,
    p_usuario_id     bigint            DEFAULT NULL,
    p_usuario_login  character varying DEFAULT NULL,
    p_usuario_nombre character varying DEFAULT NULL,
    p_ip_address     inet              DEFAULT NULL,
    p_user_agent     text              DEFAULT NULL,
    p_request_id     uuid              DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'ventas', 'auditoria'
AS $fn$
DECLARE
    v_numero  varchar(20);
    v_actual  varchar(20);
    v_nuevo   text;
    v_lineas  integer;
    v_permite text[];
BEGIN
    PERFORM ventas.fn_contexto_auditoria('ventas.proformas',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    v_nuevo := NULLIF(TRIM(UPPER(COALESCE(p_estado, ''))), '');
    IF v_nuevo IS NULL THEN
        RAISE EXCEPTION 'No se dijo a qué estado pasar' USING ERRCODE = 'P0001';
    END IF;

    SELECT p.numero, p.estado,
           (SELECT COUNT(*) FROM ventas.proformas_detalle d WHERE d.proforma_id = p.id)
      INTO v_numero, v_actual, v_lineas
      FROM ventas.proformas p WHERE p.id = p_id AND p.deleted_at IS NULL;

    IF v_numero IS NULL THEN
        RAISE EXCEPTION 'La proforma no existe o está en la papelera' USING ERRCODE = 'P0016';
    END IF;
    IF v_actual = v_nuevo THEN
        RAISE EXCEPTION 'La proforma % ya está %', v_numero, lower(ventas.fn_proformas_estado_etiqueta(v_actual))
            USING ERRCODE = 'P0007';
    END IF;

    v_permite := CASE v_actual
                     WHEN 'BORRADOR'  THEN ARRAY['ENVIADA', 'ANULADA']
                     WHEN 'ENVIADA'   THEN ARRAY['APROBADA', 'RECHAZADA', 'VENCIDA', 'ANULADA', 'BORRADOR']
                     WHEN 'VENCIDA'   THEN ARRAY['ANULADA']
                     WHEN 'RECHAZADA' THEN ARRAY['ANULADA']
                     ELSE ARRAY[]::text[]
                 END;

    IF NOT (v_nuevo = ANY(v_permite)) THEN
        IF v_actual IN ('APROBADA', 'ANULADA') THEN
            RAISE EXCEPTION 'La proforma % está % y ahí se queda: duplíquela si hay que volver a ofertar',
                            v_numero, lower(ventas.fn_proformas_estado_etiqueta(v_actual))
                USING ERRCODE = 'P0007';
        END IF;
        IF v_actual = 'VENCIDA' AND v_nuevo = 'ENVIADA' THEN
            RAISE EXCEPTION 'La proforma % está vencida: renuévela para volver a enviarla con fecha de hoy', v_numero
                USING ERRCODE = 'P0007';
        END IF;
        RAISE EXCEPTION 'Una proforma % no puede pasar a %',
                        lower(ventas.fn_proformas_estado_etiqueta(v_actual)),
                        lower(ventas.fn_proformas_estado_etiqueta(v_nuevo))
            USING ERRCODE = 'P0007';
    END IF;

    -- Enviar un documento sin líneas sería mandarle al cliente una hoja en
    -- blanco con nuestro logo
    IF v_nuevo = 'ENVIADA' AND COALESCE(v_lineas, 0) = 0 THEN
        RAISE EXCEPTION 'La proforma % no tiene líneas: no hay nada que enviar', v_numero USING ERRCODE = 'P0001';
    END IF;

    IF v_nuevo = 'RECHAZADA' AND NULLIF(TRIM(COALESCE(p_motivo, '')), '') IS NULL THEN
        RAISE EXCEPTION 'Para rechazar una proforma hay que decir por qué' USING ERRCODE = 'P0001';
    END IF;

    UPDATE ventas.proformas SET
        estado          = v_nuevo,
        -- Al volver a borrador se limpia el rastro de la vuelta anterior: lo
        -- que quede ahí hablaría de un envío que ya no cuenta
        fecha_envio     = CASE WHEN v_nuevo = 'ENVIADA'  THEN CURRENT_TIMESTAMP
                               WHEN v_nuevo = 'BORRADOR' THEN NULL
                               ELSE fecha_envio END,
        fecha_respuesta = CASE WHEN v_nuevo IN ('APROBADA', 'RECHAZADA') THEN CURRENT_TIMESTAMP
                               WHEN v_nuevo IN ('ENVIADA', 'BORRADOR')   THEN NULL
                               ELSE fecha_respuesta END,
        motivo_rechazo  = CASE WHEN v_nuevo IN ('RECHAZADA', 'ANULADA') THEN NULLIF(TRIM(COALESCE(p_motivo, '')), '')
                               WHEN v_nuevo IN ('ENVIADA', 'BORRADOR')  THEN NULL
                               ELSE motivo_rechazo END
      WHERE id = p_id;

    RETURN jsonb_build_object('success', true,
        'message', 'La proforma ' || v_numero || ' quedó ' || lower(ventas.fn_proformas_estado_etiqueta(v_nuevo)),
        'data', ventas.fn_proformas_json(p_id));
END;
$fn$;

-- ---------------------------------------------------------------------------
-- 6. RENOVAR UNA VENCIDA
-- ---------------------------------------------------------------------------
-- Se le pone fecha de hoy y vuelve a estar enviada, con los mismos precios.
-- Es una acción aparte y no un cambio de estado más porque CAMBIA LA FECHA
-- DEL DOCUMENTO, y eso no puede pasar de tapadillo dentro de un «enviar».
CREATE OR REPLACE FUNCTION ventas.fn_proformas_renovar(
    p_id             bigint,
    p_validez_dias   integer           DEFAULT NULL,
    p_usuario_id     bigint            DEFAULT NULL,
    p_usuario_login  character varying DEFAULT NULL,
    p_usuario_nombre character varying DEFAULT NULL,
    p_ip_address     inet              DEFAULT NULL,
    p_user_agent     text              DEFAULT NULL,
    p_request_id     uuid              DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'ventas', 'auditoria'
AS $fn$
DECLARE
    v_numero varchar(20);
    v_estado varchar(20);
BEGIN
    PERFORM ventas.fn_contexto_auditoria('ventas.proformas',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    SELECT p.numero, p.estado INTO v_numero, v_estado
      FROM ventas.proformas p WHERE p.id = p_id AND p.deleted_at IS NULL;

    IF v_numero IS NULL THEN
        RAISE EXCEPTION 'La proforma no existe o está en la papelera' USING ERRCODE = 'P0016';
    END IF;
    IF v_estado NOT IN ('VENCIDA', 'ENVIADA') THEN
        RAISE EXCEPTION 'Sólo se renueva una proforma enviada o vencida, y ésta está %',
                        lower(ventas.fn_proformas_estado_etiqueta(v_estado))
            USING ERRCODE = 'P0007';
    END IF;
    IF p_validez_dias IS NOT NULL AND (p_validez_dias < 0 OR p_validez_dias > 365) THEN
        RAISE EXCEPTION 'Los días de validez van de 0 a 365' USING ERRCODE = 'P0001';
    END IF;

    UPDATE ventas.proformas SET
        fecha        = CURRENT_DATE,
        validez_dias = COALESCE(p_validez_dias, validez_dias),
        estado       = 'ENVIADA',
        fecha_envio  = CURRENT_TIMESTAMP
      WHERE id = p_id;

    RETURN jsonb_build_object('success', true,
        'message', 'La proforma ' || v_numero || ' se renovó con fecha de hoy',
        'data', ventas.fn_proformas_json(p_id));
END;
$fn$;

-- ---------------------------------------------------------------------------
-- 7. DUPLICAR
-- ---------------------------------------------------------------------------
-- Un documento nuevo, en borrador, con su propio número y las mismas líneas.
-- A PROPÓSITO NO SE REFRESCA NADA: ni los precios del catálogo ni los datos
-- del cliente. Duplicar es «lo mismo otra vez»; si hay que actualizar precios
-- se hace en la copia, que para eso nace en borrador.
CREATE OR REPLACE FUNCTION ventas.fn_proformas_duplicar(
    p_id             bigint,
    p_usuario_id     bigint            DEFAULT NULL,
    p_usuario_login  character varying DEFAULT NULL,
    p_usuario_nombre character varying DEFAULT NULL,
    p_ip_address     inet              DEFAULT NULL,
    p_user_agent     text              DEFAULT NULL,
    p_request_id     uuid              DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'ventas', 'auditoria'
AS $fn$
DECLARE
    v_nueva  bigint;
    v_origen varchar(20);
BEGIN
    PERFORM ventas.fn_contexto_auditoria('ventas.proformas',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    SELECT p.numero INTO v_origen FROM ventas.proformas p WHERE p.id = p_id;
    IF v_origen IS NULL THEN
        RAISE EXCEPTION 'La proforma que se quiere duplicar no existe' USING ERRCODE = 'P0016';
    END IF;

    INSERT INTO ventas.proformas (
        numero, cliente_id, cliente_identificacion, cliente_nombre, cliente_direccion,
        cliente_telefono, cliente_email, grupo_cliente_id,
        vendedor_usuario_id, sucursal_id, bodega_id,
        fecha, validez_dias, forma_pago, dias_credito, descuento_porcentaje, moneda,
        estado, observaciones, condiciones,
        subtotal, descuento_total, subtotal_gravado, subtotal_exento, iva_total, total
    )
    SELECT ventas.fn_proformas_numero_nuevo(),
           p.cliente_id, p.cliente_identificacion, p.cliente_nombre, p.cliente_direccion,
           p.cliente_telefono, p.cliente_email, p.grupo_cliente_id,
           -- El vendedor sigue siendo el mismo: duplicar no es cambiar de
           -- dueño, y quien copia puede ser un supervisor que no vende
           p.vendedor_usuario_id, p.sucursal_id, p.bodega_id,
           CURRENT_DATE, p.validez_dias, p.forma_pago, p.dias_credito, p.descuento_porcentaje, p.moneda,
           'BORRADOR', p.observaciones, p.condiciones,
           p.subtotal, p.descuento_total, p.subtotal_gravado, p.subtotal_exento, p.iva_total, p.total
      FROM ventas.proformas p WHERE p.id = p_id
    RETURNING id INTO v_nueva;

    INSERT INTO ventas.proformas_detalle (
        proforma_id, orden, producto_id, codigo, descripcion, unidad,
        cantidad, precio_unitario, descuento_porcentaje, iva_porcentaje,
        subtotal, descuento_valor, base, iva_valor, total, observacion
    )
    SELECT v_nueva, d.orden, d.producto_id, d.codigo, d.descripcion, d.unidad,
           d.cantidad, d.precio_unitario, d.descuento_porcentaje, d.iva_porcentaje,
           d.subtotal, d.descuento_valor, d.base, d.iva_valor, d.total, d.observacion
      FROM ventas.proformas_detalle d
     WHERE d.proforma_id = p_id
     ORDER BY d.orden, d.id;

    -- Por si la de origen traía totales viejos de antes de algún arreglo
    PERFORM ventas.fn_proformas_recalcular(v_nueva);

    RETURN jsonb_build_object('success', true,
        'message', 'Se copió la proforma ' || v_origen || ' en un borrador nuevo',
        'data', ventas.fn_proformas_json(v_nueva));
END;
$fn$;

-- ---------------------------------------------------------------------------
-- 8. MARCAR LAS VENCIDAS
-- ---------------------------------------------------------------------------
-- La pantalla ya las enseña vencidas por cálculo (fn_proformas_json), así que
-- esto no es imprescindible para verlo: sirve para que el ESTADO guardado se
-- corresponda con la realidad, que es lo que miran los informes. Pensada para
-- llamarla una vez al día desde una tarea.
CREATE OR REPLACE FUNCTION ventas.fn_proformas_vencidas_marcar()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'ventas'
AS $fn$
DECLARE
    v_cuantas integer := 0;
BEGIN
    WITH vencidas AS (
        UPDATE ventas.proformas
           SET estado = 'VENCIDA'
         WHERE deleted_at IS NULL
           AND estado = 'ENVIADA'
           AND fecha_vence < CURRENT_DATE
        RETURNING id
    )
    SELECT COUNT(*) INTO v_cuantas FROM vencidas;

    RETURN jsonb_build_object('success', true,
        'message', CASE v_cuantas
                       WHEN 0 THEN 'No había proformas por vencer'
                       WHEN 1 THEN 'Se marcó 1 proforma como vencida'
                       ELSE 'Se marcaron ' || v_cuantas || ' proformas como vencidas'
                   END,
        'data', jsonb_build_object('vencidas', v_cuantas));
END;
$fn$;

COMMIT;
