-- ===========================================================================
-- LA FICHA DE UN HORARIO DE ACCESO, CON SUS CUATRO JORNADAS
-- ===========================================================================
-- `fn_horarios_obtener` armaba el detalle a mano y sin `jornada`: ordenaba
-- sólo por día, así que al reabrir un horario con dos franjas el formulario
-- cargaba una. Ahora delega en seguridad.fn_horarios_json, que es la misma que
-- usan el listado y la papelera, y así los tres enseñan lo mismo.
--
-- SE DEVUELVEN LAS DOS CLAVES: `jornadas`, que es como las llama el formulario
-- nuevo, y `dhorario`, que es como las llamaba el de antes y como las sigue
-- mandando al guardar. Mientras las dos existan, nada se queda a medias.
\set ON_ERROR_STOP on

BEGIN;

CREATE OR REPLACE FUNCTION seguridad.fn_horarios_obtener(p_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'seguridad'
AS $function$
DECLARE
    v_data jsonb;
BEGIN
    v_data := seguridad.fn_horarios_json(p_id);

    IF v_data IS NULL THEN
        RETURN jsonb_build_object('success', false, 'message', 'El horario no existe',
                                  'error_code', 'HORARIO_NO_EXISTE', 'data', NULL);
    END IF;

    -- El mismo detalle con el nombre de antes, para lo que todavía lo lea así
    v_data := v_data || jsonb_build_object('dhorario', v_data->'jornadas');

    RETURN jsonb_build_object('success', true, 'message', 'Horario obtenido exitosamente',
                              'data', v_data);
END;
$function$;

COMMIT;
