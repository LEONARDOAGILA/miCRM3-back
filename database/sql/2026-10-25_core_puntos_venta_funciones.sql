-- ===========================================================================
-- PUNTOS DE VENTA · LAS FUNCIONES
-- ===========================================================================
-- Mismas costumbres que el resto: todo entra por funciones SECURITY DEFINER
-- que reciben el contexto de auditoría y devuelven jsonb con `success`,
-- `message` y `data`.
--
-- Sin paginar a propósito: una empresa tiene decenas de cajas, no miles, y
-- la pantalla las agrupa por sucursal, que es como se miran.
--
-- LO QUE TIENE DE PROPIO: cada fila trae CUÁNTAS CUENTAS LE FALTAN. Un punto
-- de venta al que no se le ha resuelto la caja no puede asentar nada, y eso
-- no se puede descubrir el día del cierre: se ve en el listado.
\set ON_ERROR_STOP on

BEGIN;

-- ---------------------------------------------------------------------------
-- 0. EL CONTEXTO DE AUDITORÍA (la costumbre de este esquema)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION core.fn_puntos_venta_contexto_auditoria(
    p_usuario_id     bigint            DEFAULT NULL,
    p_usuario_login  character varying DEFAULT NULL,
    p_usuario_nombre character varying DEFAULT NULL,
    p_ip_address     inet              DEFAULT NULL,
    p_user_agent     text              DEFAULT NULL,
    p_request_id     uuid              DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
AS $fn$
BEGIN
    PERFORM set_config('app.usuario_id',     COALESCE(p_usuario_id::text, ''), true);
    PERFORM set_config('app.usuario_login',  COALESCE(p_usuario_login, current_user), true);
    PERFORM set_config('app.usuario_nombre', COALESCE(p_usuario_nombre, current_user), true);
    PERFORM set_config('app.ip_address',     COALESCE(p_ip_address::text, ''), true);
    PERFORM set_config('app.user_agent',     COALESCE(p_user_agent, ''), true);
    PERFORM set_config('app.request_id',     COALESCE(p_request_id::text, ''), true);
    PERFORM set_config('app.modulo',         'core.puntos_venta', true);
END;
$fn$;

-- ---------------------------------------------------------------------------
-- 1. CÓMO ESTÁN SUS CUENTAS
-- ---------------------------------------------------------------------------
-- Tres números que contestan la única pregunta que importa antes de usar una
-- caja: ¿puede asentar? `sin_resolver` son los conceptos que no tienen cuenta
-- NI están marcados como «no aplica», ni propios ni heredados: ahí el asiento
-- no se podría hacer.
CREATE OR REPLACE FUNCTION core.fn_puntos_venta_cuentas_resumen(p_id bigint)
RETURNS jsonb
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO 'pg_catalog', 'core', 'contabilidad'
AS $fn$
    WITH conceptos AS (
        SELECT c.codigo,
               contabilidad.fn_cuenta_de_detalle(c.codigo, 'PUNTO_VENTA', p_id) AS resuelta
          FROM contabilidad.conceptos_contables c
         WHERE c.activo AND c.ambito_natural = 'PUNTO_VENTA'
    )
    SELECT jsonb_build_object(
        'total',        (SELECT COUNT(*) FROM conceptos),
        'propias',      (SELECT COUNT(*) FROM contabilidad.cuentas_config
                          WHERE ambito = 'PUNTO_VENTA' AND ambito_id = p_id),
        'sin_resolver', (SELECT COUNT(*) FROM conceptos
                          WHERE (resuelta->>'cuenta_id') IS NULL
                            AND COALESCE((resuelta->>'no_aplica')::boolean, false) = false)
    );
$fn$;

-- ---------------------------------------------------------------------------
-- 2. UN PUNTO DE VENTA
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION core.fn_puntos_venta_json(p_id bigint)
RETURNS jsonb
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO 'pg_catalog', 'core'
AS $fn$
    SELECT jsonb_build_object(
        'id',              pv.id,
        'sucursal_id',     pv.sucursal_id,
        'sucursal_nombre', s.nombre,
        'sucursal_codigo', s.codigo,
        'codigo',          pv.codigo,
        'nombre',          pv.nombre,
        'numero',          pv.numero,
        'descripcion',     pv.descripcion,
        'activo',          pv.activo,
        'en_papelera',     (pv.deleted_at IS NOT NULL),
        'cuentas',         core.fn_puntos_venta_cuentas_resumen(pv.id),
        'created_by',      pv.created_by,
        'updated_by',      pv.updated_by,
        'created_at',      to_char(pv.created_at, 'YYYY-MM-DD HH24:MI:SS'),
        'updated_at',      to_char(pv.updated_at, 'YYYY-MM-DD HH24:MI:SS'),
        'deleted_at',      to_char(pv.deleted_at, 'YYYY-MM-DD HH24:MI:SS'),
        'deleted_by',      pv.deleted_by
    )
      FROM core.puntos_venta pv
      LEFT JOIN ventas.sucursales s ON s.id = pv.sucursal_id
     WHERE pv.id = p_id;
$fn$;

CREATE OR REPLACE FUNCTION core.fn_puntos_venta_obtener(p_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'pg_catalog', 'core'
AS $fn$
DECLARE
    v jsonb;
BEGIN
    v := core.fn_puntos_venta_json(p_id);
    IF v IS NULL THEN
        RETURN jsonb_build_object('success', false, 'message', 'El punto de venta no existe',
                                  'error_code', 'P0016');
    END IF;
    RETURN jsonb_build_object('success', true, 'message', 'Punto de venta', 'data', v);
END;
$fn$;

-- ---------------------------------------------------------------------------
-- 3. EL LISTADO
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION core.fn_puntos_venta_listar(
    p_solo_activos boolean DEFAULT false,
    p_sucursal_id  bigint  DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'pg_catalog', 'core'
AS $fn$
DECLARE
    v_data jsonb;
BEGIN
    SELECT COALESCE(jsonb_agg(core.fn_puntos_venta_json(x.id) ORDER BY x.sucursal, x.numero), '[]'::jsonb)
      INTO v_data
      FROM (SELECT pv.id, pv.numero, s.nombre AS sucursal
              FROM core.puntos_venta pv
              LEFT JOIN ventas.sucursales s ON s.id = pv.sucursal_id
             WHERE pv.deleted_at IS NULL
               AND (NOT p_solo_activos OR pv.activo)
               AND (p_sucursal_id IS NULL OR pv.sucursal_id = p_sucursal_id)) x;

    RETURN jsonb_build_object('success', true, 'message', 'Puntos de venta', 'data', v_data);
END;
$fn$;

-- ---------------------------------------------------------------------------
-- 4. QUÉ CÓDIGO Y QUÉ NÚMERO LE TOCAN
-- ---------------------------------------------------------------------------
-- Para que dar de alta una caja sea escribir un nombre. El número es el
-- siguiente libre de esa sucursal y el código se arma con el de la sucursal,
-- que es como se leen: LUISC-02.
CREATE OR REPLACE FUNCTION core.fn_puntos_venta_sugerencia(p_sucursal_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'pg_catalog', 'core'
AS $fn$
DECLARE
    v_numero  integer;
    v_suc     varchar;
    v_codigo  varchar;
    v_intento integer := 0;
BEGIN
    SELECT COALESCE(MAX(numero), 0) + 1 INTO v_numero
      FROM core.puntos_venta
     WHERE sucursal_id = p_sucursal_id AND deleted_at IS NULL;

    SELECT UPPER(COALESCE(NULLIF(TRIM(s.codigo), ''), 'PV')) INTO v_suc
      FROM ventas.sucursales s WHERE s.id = p_sucursal_id;

    -- El código es único en toda la empresa, así que puede chocar con el de
    -- otra sucursal o con uno que esté en la papelera: se prueba el
    -- siguiente hasta encontrar uno libre, en vez de proponer uno que va a
    -- fallar al guardar.
    LOOP
        v_codigo := COALESCE(v_suc, 'PV') || '-' || lpad((v_numero + v_intento)::text, 2, '0');
        EXIT WHEN NOT EXISTS (SELECT 1 FROM core.puntos_venta WHERE UPPER(codigo) = v_codigo);
        v_intento := v_intento + 1;
        EXIT WHEN v_intento > 99;
    END LOOP;

    RETURN jsonb_build_object('success', true, 'data', jsonb_build_object(
        'numero', v_numero,
        'codigo', v_codigo,
        'nombre', 'Caja ' || v_numero
    ));
END;
$fn$;

-- ---------------------------------------------------------------------------
-- 5. CREAR Y MODIFICAR
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION core.fn_puntos_venta_crear(
    p_sucursal_id    bigint,
    p_nombre         character varying,
    p_codigo         character varying DEFAULT NULL,
    p_numero         integer           DEFAULT NULL,
    p_descripcion    text              DEFAULT NULL,
    p_activo         boolean           DEFAULT true,
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
SET search_path TO 'pg_catalog', 'core', 'auditoria'
AS $fn$
DECLARE
    v_id         bigint;
    v_sugerencia jsonb;
    v_codigo     varchar(20);
    v_numero     integer;
BEGIN
    PERFORM core.fn_puntos_venta_contexto_auditoria(
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    IF p_sucursal_id IS NULL THEN
        RAISE EXCEPTION 'Hay que decir de qué sucursal es el punto de venta' USING ERRCODE = 'P0001';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM ventas.sucursales WHERE id = p_sucursal_id AND deleted_at IS NULL) THEN
        RAISE EXCEPTION 'Esa sucursal no existe o está en la papelera' USING ERRCODE = 'P0016';
    END IF;

    IF p_nombre IS NULL OR length(TRIM(p_nombre)) < 2 THEN
        RAISE EXCEPTION 'El nombre del punto de venta es obligatorio (mínimo 2 caracteres)' USING ERRCODE = 'P0001';
    END IF;

    -- Lo que no venga, se propone: dar de alta una caja es escribir su nombre
    v_sugerencia := (core.fn_puntos_venta_sugerencia(p_sucursal_id))->'data';
    v_codigo := UPPER(TRIM(COALESCE(NULLIF(TRIM(COALESCE(p_codigo, '')), ''), v_sugerencia->>'codigo')));
    v_numero := COALESCE(p_numero, (v_sugerencia->>'numero')::integer);

    IF v_numero < 1 OR v_numero > 999 THEN
        RAISE EXCEPTION 'El número del punto de venta va del 1 al 999' USING ERRCODE = 'P0001';
    END IF;

    IF EXISTS (SELECT 1 FROM core.puntos_venta WHERE UPPER(codigo) = v_codigo) THEN
        IF EXISTS (SELECT 1 FROM core.puntos_venta WHERE UPPER(codigo) = v_codigo AND deleted_at IS NOT NULL) THEN
            RAISE EXCEPTION 'Ya hay un punto de venta con el código %, y está en la papelera de reciclaje', v_codigo
                USING ERRCODE = 'P0006';
        END IF;
        RAISE EXCEPTION 'Ya hay un punto de venta con el código %', v_codigo USING ERRCODE = 'P0006';
    END IF;

    IF EXISTS (SELECT 1 FROM core.puntos_venta
                WHERE sucursal_id = p_sucursal_id AND numero = v_numero AND deleted_at IS NULL) THEN
        RAISE EXCEPTION 'Esa sucursal ya tiene un punto de venta con el número %', v_numero
            USING ERRCODE = 'P0006';
    END IF;

    INSERT INTO core.puntos_venta (sucursal_id, codigo, nombre, numero, descripcion, activo)
    VALUES (p_sucursal_id, v_codigo, TRIM(p_nombre), v_numero,
            NULLIF(TRIM(COALESCE(p_descripcion, '')), ''), COALESCE(p_activo, true))
    RETURNING id INTO v_id;

    RETURN jsonb_build_object('success', true, 'message', 'Punto de venta creado exitosamente',
                              'data', core.fn_puntos_venta_json(v_id));
END;
$fn$;

CREATE OR REPLACE FUNCTION core.fn_puntos_venta_modificar(
    p_id             bigint,
    p_sucursal_id    bigint,
    p_nombre         character varying,
    p_codigo         character varying DEFAULT NULL,
    p_numero         integer           DEFAULT NULL,
    p_descripcion    text              DEFAULT NULL,
    p_activo         boolean           DEFAULT true,
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
SET search_path TO 'pg_catalog', 'core', 'auditoria'
AS $fn$
DECLARE
    v_codigo varchar(20);
    v_numero integer;
BEGIN
    PERFORM core.fn_puntos_venta_contexto_auditoria(
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    IF NOT EXISTS (SELECT 1 FROM core.puntos_venta WHERE id = p_id AND deleted_at IS NULL) THEN
        RAISE EXCEPTION 'El punto de venta no existe o está en la papelera' USING ERRCODE = 'P0016';
    END IF;

    IF p_sucursal_id IS NULL THEN
        RAISE EXCEPTION 'Hay que decir de qué sucursal es el punto de venta' USING ERRCODE = 'P0001';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM ventas.sucursales WHERE id = p_sucursal_id AND deleted_at IS NULL) THEN
        RAISE EXCEPTION 'Esa sucursal no existe o está en la papelera' USING ERRCODE = 'P0016';
    END IF;

    IF p_nombre IS NULL OR length(TRIM(p_nombre)) < 2 THEN
        RAISE EXCEPTION 'El nombre del punto de venta es obligatorio (mínimo 2 caracteres)' USING ERRCODE = 'P0001';
    END IF;

    SELECT UPPER(TRIM(COALESCE(NULLIF(TRIM(COALESCE(p_codigo, '')), ''), pv.codigo))),
           COALESCE(p_numero, pv.numero)
      INTO v_codigo, v_numero
      FROM core.puntos_venta pv WHERE pv.id = p_id;

    IF v_numero < 1 OR v_numero > 999 THEN
        RAISE EXCEPTION 'El número del punto de venta va del 1 al 999' USING ERRCODE = 'P0001';
    END IF;

    IF EXISTS (SELECT 1 FROM core.puntos_venta WHERE UPPER(codigo) = v_codigo AND id <> p_id) THEN
        RAISE EXCEPTION 'Ya hay otro punto de venta con el código %', v_codigo USING ERRCODE = 'P0006';
    END IF;

    IF EXISTS (SELECT 1 FROM core.puntos_venta
                WHERE sucursal_id = p_sucursal_id AND numero = v_numero
                  AND id <> p_id AND deleted_at IS NULL) THEN
        RAISE EXCEPTION 'Esa sucursal ya tiene un punto de venta con el número %', v_numero
            USING ERRCODE = 'P0006';
    END IF;

    UPDATE core.puntos_venta SET
        sucursal_id = p_sucursal_id,
        codigo      = v_codigo,
        nombre      = TRIM(p_nombre),
        numero      = v_numero,
        descripcion = NULLIF(TRIM(COALESCE(p_descripcion, '')), ''),
        activo      = COALESCE(p_activo, true)
      WHERE id = p_id;

    RETURN jsonb_build_object('success', true, 'message', 'Punto de venta actualizado exitosamente',
                              'data', core.fn_puntos_venta_json(p_id));
END;
$fn$;

-- ---------------------------------------------------------------------------
-- 6. ACTIVAR / DESACTIVAR (sólo esa columna)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION core.fn_puntos_venta_activar(
    p_id             bigint,
    p_activo         boolean           DEFAULT NULL,
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
SET search_path TO 'pg_catalog', 'core', 'auditoria'
AS $fn$
DECLARE
    v_activo boolean;
BEGIN
    PERFORM core.fn_puntos_venta_contexto_auditoria(
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    SELECT pv.activo INTO v_activo FROM core.puntos_venta pv WHERE pv.id = p_id AND pv.deleted_at IS NULL;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'message', 'El punto de venta no existe',
                                  'error_code', 'NO_EXISTE');
    END IF;

    -- Sin valor, alterna; con valor, manda el valor (dos personas pulsando a
    -- la vez acaban donde querían)
    UPDATE core.puntos_venta SET activo = COALESCE(p_activo, NOT v_activo) WHERE id = p_id;

    RETURN jsonb_build_object('success', true,
        'message', CASE WHEN COALESCE(p_activo, NOT v_activo)
                        THEN 'Punto de venta activado' ELSE 'Punto de venta desactivado' END,
        'data', core.fn_puntos_venta_json(p_id));
END;
$fn$;

COMMIT;
