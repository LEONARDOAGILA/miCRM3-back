-- ============================================================================
-- CAMBIAR SÓLO EL ALTO DE UNA SECCIÓN
--
-- `fn_inicio_seccion_guardar` guarda la sección ENTERA: lo que no llegue en
-- el jsonb se queda en NULL. Está bien para un formulario, que manda todos
-- sus campos, pero es una trampa para una pantalla que sólo quiere mover una
-- cosa: mandar `{"alto": "amplia"}` borraría el rótulo, su color y su letra
-- sin avisar.
--
-- El modelado de la portada estira una sección con el ratón, así que necesita
-- esa puerta: una decisión sola, como `fn_inicio_seccion_activar`, que es por
-- lo mismo que existe.
--
-- Se puede volver a ejecutar sin romper nada.
-- ============================================================================

BEGIN;

CREATE OR REPLACE FUNCTION ecommerce.fn_inicio_seccion_alto(
    p_clave text, p_alto text,
    p_usuario_id bigint DEFAULT NULL, p_usuario_login character varying DEFAULT NULL,
    p_usuario_nombre character varying DEFAULT NULL, p_ip_address inet DEFAULT NULL,
    p_user_agent text DEFAULT NULL, p_request_id uuid DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'ecommerce', 'auditoria'
AS $function$
DECLARE
    v_nombre text;
    v_alto   text;
BEGIN
    PERFORM ecommerce.fn_contexto_auditoria('ecommerce.inicio_secciones',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    SELECT nombre INTO v_nombre FROM ecommerce.inicio_secciones WHERE clave = btrim(COALESCE(p_clave, ''));
    IF v_nombre IS NULL THEN
        RAISE EXCEPTION 'La sección «%» no existe', p_clave USING ERRCODE = 'P0013';
    END IF;

    -- La misma lista de siempre, comprobada en el mismo sitio
    v_alto := COALESCE(ecommerce.fn_validar_opcion(p_alto,
                  ARRAY['compacta', 'normal', 'amplia', 'extra'], 'El alto de la sección'), 'normal');

    UPDATE ecommerce.inicio_secciones SET alto = v_alto WHERE clave = btrim(p_clave);

    RETURN jsonb_build_object('success', true,
        'message', format('«%s» ahora es %s', v_nombre, v_alto),
        'data', (ecommerce.fn_inicio_listar() -> 'data'));
END;
$function$;

-- ----------------------------------------------------------------------------
-- QUE CAMBIE EL ALTO Y NO SE LLEVE NADA POR DELANTE
-- ----------------------------------------------------------------------------
-- Lo que escribe la prueba va dentro de un bloque con EXCEPTION, que en
-- plpgsql es una subtransacción: al salir con un error se deshacen sus UPDATE
-- y las variables se quedan con lo que leyeron.
DO $comprobar$
DECLARE
    v_clave   text;
    v_titulo  text;
    v_color   text;
    v_alto    text;
    v_despues record;
    v_fallo   text;
BEGIN
    SELECT clave INTO v_clave FROM ecommerce.inicio_secciones ORDER BY orden LIMIT 1;

    BEGIN
        -- Una sección con rótulo y color puestos, para ver si sobreviven
        UPDATE ecommerce.inicio_secciones
           SET titulo = 'ZZ rótulo', rotulo_color = '#123456', alto = 'normal'
         WHERE clave = v_clave;

        PERFORM ecommerce.fn_inicio_seccion_alto(v_clave, 'EXTRA');

        SELECT titulo, rotulo_color, alto INTO v_despues
          FROM ecommerce.inicio_secciones WHERE clave = v_clave;
        v_titulo := v_despues.titulo; v_color := v_despues.rotulo_color; v_alto := v_despues.alto;

        -- Y un alto inventado no entra
        v_fallo := NULL;
        BEGIN
            PERFORM ecommerce.fn_inicio_seccion_alto(v_clave, 'enorme');
        EXCEPTION WHEN SQLSTATE 'P0015' THEN v_fallo := 'bien';
        END;

        RAISE EXCEPTION 'deshacer la prueba' USING ERRCODE = 'P0001';
    EXCEPTION WHEN SQLSTATE 'P0001' THEN
        NULL;
    END;

    IF v_alto IS DISTINCT FROM 'extra' THEN
        RAISE EXCEPTION 'No cambió el alto (quedó «%»)', COALESCE(v_alto, 'nada');
    END IF;
    IF v_titulo IS DISTINCT FROM 'ZZ rótulo' OR v_color IS DISTINCT FROM '#123456' THEN
        RAISE EXCEPTION 'Cambiar el alto se llevó por delante el rótulo («%», «%»)',
              COALESCE(v_titulo, 'nada'), COALESCE(v_color, 'nada');
    END IF;
    IF v_fallo IS NULL THEN
        RAISE EXCEPTION 'Se tragó un alto que no existe';
    END IF;

    RAISE NOTICE 'Comprobado: el alto se cambia solo, sin tocar el rótulo, y lo que no está en la lista no entra.';
END
$comprobar$;

COMMIT;
