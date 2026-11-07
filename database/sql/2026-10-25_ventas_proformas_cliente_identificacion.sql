-- ===========================================================================
-- PROFORMAS · EL CLIENTE POR SU IDENTIFICACIÓN
-- ===========================================================================
-- El selector de cliente de la proforma sigue el mismo patrón que el del
-- cargo en la ficha del empleado —un campo que se escribe, el nombre al lado
-- bloqueado, y una lupa— pero con una diferencia: ahí se teclea el ID y aquí
-- se teclea la CÉDULA O EL RUC.
--
-- Es lo que tiene sentido en un documento de venta: el vendedor tiene delante
-- la cédula del cliente, no el número con el que el sistema lo guarda. El id
-- sigue siendo lo que se guarda en la proforma; sólo cambia por dónde se
-- busca.
--
-- Devuelve EXACTAMENTE lo mismo que fn_proformas_cliente_condiciones —la foto
-- del cliente, sus condiciones y los avisos—, así que la pantalla trata igual
-- lo que venga de la lupa y lo que venga de teclear la cédula.
\set ON_ERROR_STOP on

BEGIN;

CREATE OR REPLACE FUNCTION ventas.fn_proformas_cliente_por_identificacion(p_identificacion text)
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'pg_catalog', 'ventas'
AS $fn$
DECLARE
    v_tal_cual text;
    v_limpia   text;
    v_id       bigint;
BEGIN
    v_tal_cual := NULLIF(TRIM(COALESCE(p_identificacion, '')), '');
    IF v_tal_cual IS NULL THEN
        RETURN jsonb_build_object('success', false,
                                  'message', 'No se escribió ninguna identificación',
                                  'error_code', 'P0001');
    END IF;

    -- Primero tal cual, que es lo que usa el índice único
    SELECT c.id INTO v_id
      FROM ventas.clientes c
     WHERE c.numero_identificacion = v_tal_cual
       AND c.deleted_at IS NULL;

    -- Y si no, sin guiones ni espacios: un RUC se dicta de muchas maneras
    -- («1792146739-001») y el que lo teclea no tiene por qué saber cómo se
    -- guardó. Son mil clientes: recorrerlos no cuesta nada, y sólo pasa
    -- cuando el camino rápido no encontró nada.
    IF v_id IS NULL THEN
        v_limpia := regexp_replace(UPPER(v_tal_cual), '[^A-Z0-9]', '', 'g');

        SELECT c.id INTO v_id
          FROM ventas.clientes c
         WHERE c.deleted_at IS NULL
           AND regexp_replace(UPPER(COALESCE(c.numero_identificacion, '')), '[^A-Z0-9]', '', 'g') = v_limpia
         ORDER BY c.id
         LIMIT 1;
    END IF;

    IF v_id IS NULL THEN
        RETURN jsonb_build_object('success', false,
                                  'message', 'No hay ningún cliente con la identificación ' || v_tal_cual,
                                  'error_code', 'P0016');
    END IF;

    RETURN ventas.fn_proformas_cliente_condiciones(v_id);
END;
$fn$;

COMMENT ON FUNCTION ventas.fn_proformas_cliente_por_identificacion(text) IS
'El cliente y sus condiciones a partir de la cédula o el RUC. Devuelve lo mismo que fn_proformas_cliente_condiciones.';

COMMIT;
