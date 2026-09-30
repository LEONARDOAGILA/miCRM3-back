-- ===========================================================================
-- BOLETINES: volver a mostrárselo a quien lo ocultó
--
-- Al lanzar a mano se puede marcar «ignorar el no volver a mostrar»: esta
-- función retira esa marca para ese boletín, de modo que llegue a todos sus
-- destinatarios.
--
--   psql -h 192.168.2.173 -U postgres -d crm3 -f 2026-09-22_core_boletines_ignorar_no_mostrar.sql
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- Quitar el «no volver a mostrar» de un boletín
--
-- Lo usa el lanzamiento a mano cuando el administrador marca «ignorar el
-- no volver a mostrar»: el boletín vuelve a salirle a quien lo había
-- ocultado, ahora y la próxima vez que entre. Es la única forma de
-- revertir esa marca, que el usuario sólo puede poner.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION core.fn_boletines_ignorar_no_mostrar(p_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
AS $function$
DECLARE v_cuantos integer;
BEGIN
    UPDATE core.boletines_vistos
       SET no_mostrar = false
     WHERE boletin_id = p_id
       AND no_mostrar;

    GET DIAGNOSTICS v_cuantos = ROW_COUNT;

    RETURN jsonb_build_object('success', true,
                              'message', 'Marca de «no volver a mostrar» retirada',
                              'data', jsonb_build_object('reactivados', v_cuantos));
END;
$function$;
