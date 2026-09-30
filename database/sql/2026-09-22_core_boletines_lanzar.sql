-- ===========================================================================
-- BOLETINES: lanzar a mano uno que no está vigente
--
-- El administrador puede lanzar cualquier boletín activo, esté programado o
-- caducado. Para que al destinatario le llegue algo que mostrar hace falta
-- una consulta que no mire la vigencia: esa es fn_boletines_mio.
--
--   psql -h 192.168.2.173 -U postgres -d crm3 -f 2026-09-22_core_boletines_lanzar.sql
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- Un boletín concreto, para quien lo va a ver
--
-- Es el hermano de fn_boletines_mios, con dos diferencias: va por id y NO
-- mira la vigencia. Se usa cuando el administrador lanza un boletín a mano:
-- si decide lanzar uno programado o ya caducado, manda su decisión. Lo que
-- no se salta es el resto: tiene que estar activo, con contenido, y quien
-- pregunta tiene que ser destinatario y no haber dicho «no volver a mostrar».
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION core.fn_boletines_mio(p_id bigint, p_user_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
AS $function$
DECLARE v_data jsonb;
BEGIN
    SELECT core.fn_boletines_json(b.id) INTO v_data
      FROM core.boletines b
     WHERE b.id = p_id
       AND b.deleted_at IS NULL
       AND b.activo
       AND EXISTS (SELECT 1 FROM core.boletines_imagenes i WHERE i.boletin_id = b.id)
       AND (
            EXISTS (SELECT 1 FROM core.boletines_usuarios bu
                     WHERE bu.boletin_id = b.id AND bu.user_id = p_user_id)
         OR EXISTS (SELECT 1 FROM core.boletines_grupos bg
                      CROSS JOIN LATERAL core.fn_boletines_usuarios_de_grupo(bg.grupo_id, bg.incluir_subgrupos) g
                     WHERE bg.boletin_id = b.id AND g.user_id = p_user_id)
           )
       AND NOT EXISTS (SELECT 1 FROM core.boletines_vistos v
                        WHERE v.boletin_id = b.id AND v.user_id = p_user_id AND v.no_mostrar);

    RETURN jsonb_build_object('success', true, 'message', 'La solicitud ha tenido éxito', 'data', v_data);
END;
$function$;

