-- ===========================================================================
-- PUNTOS DE VENTA · EL CÓDIGO ES COMPUESTO
-- ===========================================================================
-- EL CÓDIGO DE UNA CAJA SALE DE DOS COSAS: el código de la sucursal y el
-- número de la caja. La caja 501 de la sucursal 01 es «01-501». No se teclea:
-- se compone, y así el código dice de un vistazo dónde está la caja y cuál es
-- sin tener que abrirla.
--
-- Lo que arregla esta migración:
--
--   1. `lpad(numero, 2, '0')` NO RELLENABA, RECORTABA. lpad corta cuando el
--      texto es más largo que el ancho pedido, así que el número 501 salía
--      como «01-50»: un código que no es el de ninguna caja. Los números van
--      del 1 al 999, así que el relleno a dos cifras es un MÍNIMO, no un
--      ancho fijo.
--
--   2. Al chocar el código se movía SÓLO el código y no el número, y la caja
--      acababa llamándose «01-02» llevando el número 1. Ahora lo que avanza
--      es el número, y el código se vuelve a componer con él.
--
--   3. Al crear con número pero sin código se cogía el código de la
--      sugerencia —que es el del SIGUIENTE número libre—, no el del número
--      que se mandó. Ahora el código se compone con el número que de verdad
--      se va a grabar.
--
-- Idempotente: sólo reemplaza funciones.
-- ===========================================================================
\set ON_ERROR_STOP on

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. COMPONER EL CÓDIGO (un solo sitio)
-- ---------------------------------------------------------------------------
-- Está aparte porque lo necesitan tres: la sugerencia, el alta y la
-- modificación. Si cada una lo compusiera a su manera, el día que cambie la
-- forma del código habría tres sitios donde cambiarla y dos se quedarían
-- atrás.
CREATE OR REPLACE FUNCTION core.fn_puntos_venta_codigo_componer(
    p_sucursal_id bigint,
    p_numero      integer
)
RETURNS character varying
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO 'pg_catalog', 'core'
AS $fn$
    SELECT UPPER(COALESCE(NULLIF(TRIM(s.codigo), ''), 'PV'))
           || '-'
           -- Dos cifras como MÍNIMO (la caja 1 es «01-01»), pero sin recortar
           -- las que tengan más: la 501 es «01-501»
           || CASE WHEN p_numero < 10 THEN '0' || p_numero::text ELSE p_numero::text END
      FROM ventas.sucursales s
     WHERE s.id = p_sucursal_id;
$fn$;

COMMENT ON FUNCTION core.fn_puntos_venta_codigo_componer(bigint, integer) IS
'El código de un punto de venta: código de su sucursal + número de la caja (01-501).';

-- ---------------------------------------------------------------------------
-- 2. LA SUGERENCIA
-- ---------------------------------------------------------------------------
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
    v_vueltas integer := 0;
BEGIN
    SELECT COALESCE(MAX(numero), 0) + 1 INTO v_numero
      FROM core.puntos_venta
     WHERE sucursal_id = p_sucursal_id AND deleted_at IS NULL;

    SELECT UPPER(COALESCE(NULLIF(TRIM(s.codigo), ''), 'PV')) INTO v_suc
      FROM ventas.sucursales s WHERE s.id = p_sucursal_id;

    -- El código es único en TODA la empresa y el de la papelera también
    -- cuenta, así que el primer número libre de la sucursal puede dar un
    -- código cogido. Lo que se mueve entonces es EL NÚMERO: el código no se
    -- puede mover solo, porque se compone con él.
    LOOP
        v_codigo := core.fn_puntos_venta_codigo_componer(p_sucursal_id, v_numero);
        EXIT WHEN NOT EXISTS (SELECT 1 FROM core.puntos_venta WHERE UPPER(codigo) = v_codigo);
        v_numero  := v_numero + 1;
        v_vueltas := v_vueltas + 1;
        EXIT WHEN v_vueltas > 999 OR v_numero > 999;
    END LOOP;

    RETURN jsonb_build_object('success', true, 'data', jsonb_build_object(
        'numero',          v_numero,
        'codigo',          v_codigo,
        'nombre',          'Caja ' || v_numero,
        -- Para que la ficha pueda recomponer el código mientras se teclea el
        -- número, sin tener que ir a preguntar por la sucursal
        'sucursal_codigo', v_suc
    ));
END;
$fn$;

-- ---------------------------------------------------------------------------
-- 3. CREAR
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

    -- EL NÚMERO PRIMERO: el código se compone con él, así que mientras no se
    -- sepa el número no se puede saber el código. Lo que no venga, se propone
    -- (dar de alta una caja es escribir su nombre).
    v_sugerencia := (core.fn_puntos_venta_sugerencia(p_sucursal_id))->'data';
    v_numero := COALESCE(p_numero, (v_sugerencia->>'numero')::integer);

    IF v_numero < 1 OR v_numero > 999 THEN
        RAISE EXCEPTION 'El número del punto de venta va del 1 al 999' USING ERRCODE = 'P0001';
    END IF;

    -- Y el código, COMPUESTO CON ESE NÚMERO. Si lo mandan escrito se respeta:
    -- quedan cajas de antes con códigos que no siguen la regla y no se les va
    -- a cambiar el código por abrirles la ficha.
    v_codigo := UPPER(TRIM(COALESCE(
        NULLIF(TRIM(COALESCE(p_codigo, '')), ''),
        core.fn_puntos_venta_codigo_componer(p_sucursal_id, v_numero)
    )));

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

-- ---------------------------------------------------------------------------
-- 4. MODIFICAR
-- ---------------------------------------------------------------------------
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

    -- El número que va a quedar; si no lo mandan, el que ya tenía
    SELECT COALESCE(p_numero, pv.numero) INTO v_numero
      FROM core.puntos_venta pv WHERE pv.id = p_id;

    IF v_numero < 1 OR v_numero > 999 THEN
        RAISE EXCEPTION 'El número del punto de venta va del 1 al 999' USING ERRCODE = 'P0001';
    END IF;

    -- Y el código con él. AQUÍ NO SE CONSERVA EL VIEJO cuando no lo mandan:
    -- el código se compone con el número y con la sucursal, y si cambia
    -- cualquiera de los dos el código de antes ya no es el de esta caja.
    v_codigo := UPPER(TRIM(COALESCE(
        NULLIF(TRIM(COALESCE(p_codigo, '')), ''),
        core.fn_puntos_venta_codigo_componer(p_sucursal_id, v_numero)
    )));

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

COMMIT;
