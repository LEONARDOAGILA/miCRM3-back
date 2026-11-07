-- ===========================================================================
-- PUNTOS DE VENTA · LA PAPELERA
-- ===========================================================================
-- Lo de siempre: eliminar es un borrado lógico y desde la papelera se
-- restaura o se borra de verdad.
--
-- LO QUE HAY QUE ACORDARSE AQUÍ son las cuentas. contabilidad.cuentas_config
-- apunta a la caja por (ambito, ambito_id) y eso NO es una clave ajena —el
-- ámbito es polimórfico: la misma columna guarda ids de categorías, de
-- grupos y de cajas—, así que la base no limpia nada sola. Si se borra una
-- caja de verdad y nadie quita sus filas, quedan configuraciones apuntando a
-- un punto de venta que ya no existe, y el día que se cree otro con el mismo
-- id las heredaría sin que nadie entienda de dónde salieron.
\set ON_ERROR_STOP on

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. A LA PAPELERA
-- ---------------------------------------------------------------------------
-- Las cuentas NO se tocan: una caja que vuelve de la papelera tiene que
-- volver con lo suyo puesto.
CREATE OR REPLACE FUNCTION core.fn_puntos_venta_eliminar(
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
SET search_path TO 'pg_catalog', 'core', 'auditoria'
AS $fn$
DECLARE
    v_nombre varchar(100);
BEGIN
    PERFORM core.fn_puntos_venta_contexto_auditoria(
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    SELECT pv.nombre INTO v_nombre
      FROM core.puntos_venta pv WHERE pv.id = p_id AND pv.deleted_at IS NULL;
    IF v_nombre IS NULL THEN
        RAISE EXCEPTION 'El punto de venta no existe o ya está en la papelera' USING ERRCODE = 'P0016';
    END IF;

    UPDATE core.puntos_venta
       SET deleted_at = CURRENT_TIMESTAMP,
           deleted_by = COALESCE(p_usuario_login, current_user)
     WHERE id = p_id;

    RETURN jsonb_build_object('success', true,
                              'message', 'El punto de venta «' || v_nombre || '» se envió a la papelera de reciclaje');
END;
$fn$;

-- ---------------------------------------------------------------------------
-- 2. LO QUE HAY EN LA PAPELERA
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION core.fn_puntos_venta_papelera_listar()
RETURNS jsonb
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO 'pg_catalog', 'core'
AS $fn$
    SELECT COALESCE(jsonb_agg(
        jsonb_build_object(
            'id',              pv.id,
            'codigo',          pv.codigo,
            'nombre',          pv.nombre,
            'numero',          pv.numero,
            'sucursal_id',     pv.sucursal_id,
            'sucursal_nombre', s.nombre,
            'activo',          pv.activo,
            -- Cuántas cuentas propias se van con ella si se borra de verdad
            'cuentas_propias', (SELECT COUNT(*) FROM contabilidad.cuentas_config
                                 WHERE ambito = 'PUNTO_VENTA' AND ambito_id = pv.id),
            'deleted_at',      to_char(pv.deleted_at, 'YYYY-MM-DD HH24:MI:SS'),
            'deleted_by',      pv.deleted_by
        ) ORDER BY pv.deleted_at DESC), '[]'::jsonb)
      FROM core.puntos_venta pv
      LEFT JOIN ventas.sucursales s ON s.id = pv.sucursal_id
     WHERE pv.deleted_at IS NOT NULL;
$fn$;

-- ---------------------------------------------------------------------------
-- 3. RESTAURAR
-- ---------------------------------------------------------------------------
-- Puede chocar: mientras estaba en la papelera, otra caja pudo quedarse con
-- su número dentro de la sucursal. Se dice cuál y no se restaura a medias.
CREATE OR REPLACE FUNCTION core.fn_puntos_venta_restaurar(
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
SET search_path TO 'pg_catalog', 'core', 'auditoria'
AS $fn$
DECLARE
    v_choque  record;
    v_cuantas integer := 0;
BEGIN
    PERFORM core.fn_puntos_venta_contexto_auditoria(
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    IF p_ids IS NULL OR jsonb_typeof(p_ids) <> 'array' OR jsonb_array_length(p_ids) = 0 THEN
        RAISE EXCEPTION 'No se indicó ningún punto de venta' USING ERRCODE = 'P0001';
    END IF;

    SELECT pv.nombre, pv.numero, s.nombre AS sucursal INTO v_choque
      FROM core.puntos_venta pv
      LEFT JOIN ventas.sucursales s ON s.id = pv.sucursal_id
     WHERE pv.deleted_at IS NOT NULL
       AND pv.id IN (SELECT (value #>> '{}')::bigint FROM jsonb_array_elements(p_ids))
       AND EXISTS (SELECT 1 FROM core.puntos_venta otro
                    WHERE otro.sucursal_id = pv.sucursal_id
                      AND otro.numero = pv.numero
                      AND otro.deleted_at IS NULL)
     LIMIT 1;

    IF v_choque.nombre IS NOT NULL THEN
        RAISE EXCEPTION 'No se puede restaurar «%»: la sucursal % ya tiene otro punto de venta con el número %',
                        v_choque.nombre, v_choque.sucursal, v_choque.numero
            USING ERRCODE = 'P0006';
    END IF;

    WITH vuelven AS (
        UPDATE core.puntos_venta
           SET deleted_at = NULL, deleted_by = NULL
         WHERE deleted_at IS NOT NULL
           AND id IN (SELECT (value #>> '{}')::bigint FROM jsonb_array_elements(p_ids))
        RETURNING id
    )
    SELECT COUNT(*) INTO v_cuantas FROM vuelven;

    RETURN jsonb_build_object('success', true,
        'message', CASE v_cuantas
                       WHEN 0 THEN 'No había nada que restaurar'
                       WHEN 1 THEN 'Se restauró 1 punto de venta'
                       ELSE 'Se restauraron ' || v_cuantas || ' puntos de venta'
                   END,
        'data', jsonb_build_object('restaurados', v_cuantas));
END;
$fn$;

-- ---------------------------------------------------------------------------
-- 4. BORRAR DE VERDAD
-- ---------------------------------------------------------------------------
-- Aquí es donde hay que acordarse de las cuentas: se borran a mano porque
-- cuentas_config apunta al punto de venta por (ambito, ambito_id) y eso no
-- es una clave ajena.
CREATE OR REPLACE FUNCTION core.fn_puntos_venta_eliminar_definitivo(
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
SET search_path TO 'pg_catalog', 'core', 'auditoria'
AS $fn$
DECLARE
    v_cuantas integer := 0;
    v_cuentas integer := 0;
BEGIN
    PERFORM core.fn_puntos_venta_contexto_auditoria(
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    IF p_ids IS NULL OR jsonb_typeof(p_ids) <> 'array' OR jsonb_array_length(p_ids) = 0 THEN
        RAISE EXCEPTION 'No se indicó ningún punto de venta' USING ERRCODE = 'P0001';
    END IF;

    -- SÓLO LO QUE ESTÁ EN LA PAPELERA, aquí y en el borrado de las cuentas:
    -- un id suelto mal mandado no puede llevarse la configuración de una caja
    -- que está en uso.
    WITH fuera AS (
        DELETE FROM contabilidad.cuentas_config
         WHERE ambito = 'PUNTO_VENTA'
           AND ambito_id IN (SELECT pv.id FROM core.puntos_venta pv
                              WHERE pv.deleted_at IS NOT NULL
                                AND pv.id IN (SELECT (value #>> '{}')::bigint FROM jsonb_array_elements(p_ids)))
        RETURNING id
    )
    SELECT COUNT(*) INTO v_cuentas FROM fuera;

    WITH fuera AS (
        DELETE FROM core.puntos_venta
         WHERE deleted_at IS NOT NULL
           AND id IN (SELECT (value #>> '{}')::bigint FROM jsonb_array_elements(p_ids))
        RETURNING id
    )
    SELECT COUNT(*) INTO v_cuantas FROM fuera;

    RETURN jsonb_build_object('success', true,
        'message', CASE v_cuantas
                       WHEN 0 THEN 'No había nada que eliminar'
                       WHEN 1 THEN 'Se eliminó 1 punto de venta definitivamente'
                       ELSE 'Se eliminaron ' || v_cuantas || ' puntos de venta definitivamente'
                   END
                   || CASE WHEN v_cuentas > 0
                           THEN ', con ' || v_cuentas || ' ' ||
                                CASE WHEN v_cuentas = 1 THEN 'cuenta configurada' ELSE 'cuentas configuradas' END
                           ELSE '' END,
        'data', jsonb_build_object('eliminados', v_cuantas, 'cuentas_eliminadas', v_cuentas));
END;
$fn$;

-- ---------------------------------------------------------------------------
-- 5. VACIAR
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION core.fn_puntos_venta_papelera_vaciar(
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
    v_cuantas integer := 0;
BEGIN
    PERFORM core.fn_puntos_venta_contexto_auditoria(
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    DELETE FROM contabilidad.cuentas_config
     WHERE ambito = 'PUNTO_VENTA'
       AND ambito_id IN (SELECT id FROM core.puntos_venta WHERE deleted_at IS NOT NULL);

    WITH fuera AS (
        DELETE FROM core.puntos_venta WHERE deleted_at IS NOT NULL RETURNING id
    )
    SELECT COUNT(*) INTO v_cuantas FROM fuera;

    RETURN jsonb_build_object('success', true,
        'message', CASE v_cuantas
                       WHEN 0 THEN 'La papelera ya estaba vacía'
                       WHEN 1 THEN 'Se eliminó 1 punto de venta'
                       ELSE 'Se eliminaron ' || v_cuantas || ' puntos de venta'
                   END,
        'data', jsonb_build_object('eliminados', v_cuantas));
END;
$fn$;

COMMIT;
