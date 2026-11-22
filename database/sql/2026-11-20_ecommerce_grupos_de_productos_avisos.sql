-- ============================================================================
-- LOS AVISOS DE LOS GRUPOS DE PRODUCTOS
-- ============================================================================
-- El cambio de nombre de esta misma tarde se llevó los nombres de las tablas y
-- de las funciones, pero dejó ocho frases hablando de secciones: las que lee
-- quien administra al crear, guardar, mover, apagar, borrar o restaurar uno.
-- «Sección creada» en una pantalla que se llama «Grupos de productos» es
-- justo la confusión que se vino a quitar.
--
-- Y de paso el género: un grupo se crea creado, se envía enviado y se
-- enciende encendido.
--
-- ----------------------------------------------------------------------------
-- SE EJECUTA A MANO. Para ensayar: comentar el COMMIT y poner un ROLLBACK al
-- final del todo.
-- ============================================================================

BEGIN;
-- fn_grupos_productos_activar
CREATE OR REPLACE FUNCTION ecommerce.fn_grupos_productos_activar(p_id bigint, p_activo boolean DEFAULT NULL::boolean, p_usuario_id bigint DEFAULT NULL::bigint, p_usuario_login character varying DEFAULT NULL::character varying, p_usuario_nombre character varying DEFAULT NULL::character varying, p_ip_address inet DEFAULT NULL::inet, p_user_agent text DEFAULT NULL::text, p_request_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'ecommerce', 'auditoria'
AS $function$
DECLARE
    v_antes  boolean;
    v_nombre text;
BEGIN
    PERFORM ecommerce.fn_contexto_auditoria('ecommerce.grupos_productos',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    SELECT activo, nombre INTO v_antes, v_nombre
      FROM ecommerce.grupos_productos WHERE id = p_id AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'El grupo no existe' USING ERRCODE = 'P0013';
    END IF;

    UPDATE ecommerce.grupos_productos
       SET activo = COALESCE(p_activo, NOT v_antes) WHERE id = p_id;

    RETURN jsonb_build_object('success', true,
        'message', format('Grupo «%s» %s', v_nombre,
            CASE WHEN COALESCE(p_activo, NOT v_antes) THEN 'encendido' ELSE 'apagado' END),
        'data', ecommerce.fn_grupos_productos_json(p_id));
END;
$function$;

-- fn_grupos_productos_crear
CREATE OR REPLACE FUNCTION ecommerce.fn_grupos_productos_crear(p_nombre character varying, p_desde timestamp with time zone DEFAULT NULL::timestamp with time zone, p_hasta timestamp with time zone DEFAULT NULL::timestamp with time zone, p_usuario_id bigint DEFAULT NULL::bigint, p_usuario_login character varying DEFAULT NULL::character varying, p_usuario_nombre character varying DEFAULT NULL::character varying, p_ip_address inet DEFAULT NULL::inet, p_user_agent text DEFAULT NULL::text, p_request_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'ecommerce', 'auditoria'
AS $function$
DECLARE
    v_id bigint;
BEGIN
    PERFORM ecommerce.fn_contexto_auditoria('ecommerce.grupos_productos',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    PERFORM ecommerce.fn_grupos_productos_validar(NULL, p_nombre, p_desde, p_hasta);

    INSERT INTO ecommerce.grupos_productos (nombre, desde, hasta, orden)
    VALUES (btrim(p_nombre), p_desde, p_hasta,
            (SELECT COALESCE(max(orden), 0) + 1 FROM ecommerce.grupos_productos
              WHERE deleted_at IS NULL))
    RETURNING id INTO v_id;

    -- AQUÍ NO SE LE DA SITIO EN NINGUNA PÁGINA, y es lo que cambió: el
    -- escaparate se arma aquí y se añade donde se quiera con «Escaparate»
    -- (fn_inicio_escaparate_poner), en la principal igual que en las demás.
    RETURN jsonb_build_object('success', true,
        'message', format('Grupo «%s» creado. Añádelo a las páginas donde quieras que salga', btrim(p_nombre)),
        'data', ecommerce.fn_grupos_productos_json(v_id));
END;
$function$;

-- fn_grupos_productos_eliminar
CREATE OR REPLACE FUNCTION ecommerce.fn_grupos_productos_eliminar(p_id bigint, p_usuario_id bigint DEFAULT NULL::bigint, p_usuario_login character varying DEFAULT NULL::character varying, p_usuario_nombre character varying DEFAULT NULL::character varying, p_ip_address inet DEFAULT NULL::inet, p_user_agent text DEFAULT NULL::text, p_request_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'ecommerce', 'auditoria'
AS $function$
DECLARE
    v_nombre text;
    v_items  integer;
BEGIN
    PERFORM ecommerce.fn_contexto_auditoria('ecommerce.grupos_productos',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    SELECT nombre INTO v_nombre FROM ecommerce.grupos_productos
     WHERE id = p_id AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'El grupo no existe' USING ERRCODE = 'P0013';
    END IF;

    SELECT count(*) INTO v_items FROM ecommerce.grupos_productos_items WHERE grupo_id = p_id;

    UPDATE ecommerce.grupos_productos
       SET deleted_at = CURRENT_TIMESTAMP, deleted_by = p_usuario_login
     WHERE id = p_id;

    RETURN jsonb_build_object('success', true,
        'message', CASE v_items
            WHEN 0 THEN format('Grupo «%s» enviado a la papelera', v_nombre)
            WHEN 1 THEN format('Grupo «%s» enviado a la papelera con su producto', v_nombre)
            ELSE format('Grupo «%s» enviado a la papelera con sus %s productos', v_nombre, v_items) END,
        'data', ecommerce.fn_grupos_productos_json(p_id));
END;
$function$;

-- fn_grupos_productos_modificar
CREATE OR REPLACE FUNCTION ecommerce.fn_grupos_productos_modificar(p_id bigint, p_nombre character varying, p_desde timestamp with time zone DEFAULT NULL::timestamp with time zone, p_hasta timestamp with time zone DEFAULT NULL::timestamp with time zone, p_usuario_id bigint DEFAULT NULL::bigint, p_usuario_login character varying DEFAULT NULL::character varying, p_usuario_nombre character varying DEFAULT NULL::character varying, p_ip_address inet DEFAULT NULL::inet, p_user_agent text DEFAULT NULL::text, p_request_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'ecommerce', 'auditoria'
AS $function$
BEGIN
    PERFORM ecommerce.fn_contexto_auditoria('ecommerce.grupos_productos',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    IF NOT EXISTS (SELECT 1 FROM ecommerce.grupos_productos
                    WHERE id = p_id AND deleted_at IS NULL) THEN
        RAISE EXCEPTION 'El grupo no existe' USING ERRCODE = 'P0013';
    END IF;

    PERFORM ecommerce.fn_grupos_productos_validar(p_id, p_nombre, p_desde, p_hasta);

    UPDATE ecommerce.grupos_productos
       SET nombre = btrim(p_nombre), desde = p_desde, hasta = p_hasta
     WHERE id = p_id;

    UPDATE ecommerce.inicio_secciones
       SET nombre = btrim(p_nombre)
     WHERE grupo_productos_id = p_id AND nombre IS DISTINCT FROM btrim(p_nombre);

    RETURN jsonb_build_object('success', true, 'message', 'Grupo actualizado',
        'data', ecommerce.fn_grupos_productos_json(p_id));
END;
$function$;

-- fn_grupos_productos_ordenar
CREATE OR REPLACE FUNCTION ecommerce.fn_grupos_productos_ordenar(p_ids jsonb, p_usuario_id bigint DEFAULT NULL::bigint, p_usuario_login character varying DEFAULT NULL::character varying, p_usuario_nombre character varying DEFAULT NULL::character varying, p_ip_address inet DEFAULT NULL::inet, p_user_agent text DEFAULT NULL::text, p_request_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'ecommerce', 'auditoria'
AS $function$
DECLARE
    v_cuantas integer;
BEGIN
    PERFORM ecommerce.fn_contexto_auditoria('ecommerce.grupos_productos',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    IF jsonb_typeof(p_ids) <> 'array' THEN
        RAISE EXCEPTION 'Se esperaba la lista de grupos en el orden nuevo' USING ERRCODE = 'P0015';
    END IF;

    -- El orden es la POSICIÓN en la lista que llega, no un número del cliente:
    -- así no hay huecos ni empates aunque se arrastre varias veces.
    UPDATE ecommerce.grupos_productos s
       SET orden = t.posicion
      FROM (SELECT valor::bigint AS id, ordinalidad::integer AS posicion
              FROM jsonb_array_elements_text(p_ids) WITH ORDINALITY AS x(valor, ordinalidad)) t
     WHERE s.id = t.id AND s.deleted_at IS NULL;
    GET DIAGNOSTICS v_cuantas = ROW_COUNT;

    RETURN jsonb_build_object('success', true,
        'message', CASE v_cuantas WHEN 1 THEN 'Grupo movido'
                                  ELSE format('%s grupos reordenados', v_cuantas) END,
        'data', (ecommerce.fn_grupos_productos_listar() -> 'data'));
END;
$function$;

-- fn_grupos_productos_restaurar
CREATE OR REPLACE FUNCTION ecommerce.fn_grupos_productos_restaurar(p_id bigint, p_usuario_id bigint DEFAULT NULL::bigint, p_usuario_login character varying DEFAULT NULL::character varying, p_usuario_nombre character varying DEFAULT NULL::character varying, p_ip_address inet DEFAULT NULL::inet, p_user_agent text DEFAULT NULL::text, p_request_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'ecommerce', 'auditoria'
AS $function$
DECLARE
    v_nombre text;
    v_fecha  timestamptz;
BEGIN
    PERFORM ecommerce.fn_contexto_auditoria('ecommerce.grupos_productos',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    SELECT nombre, deleted_at INTO v_nombre, v_fecha
      FROM ecommerce.grupos_productos WHERE id = p_id;
    IF NOT FOUND OR v_fecha IS NULL THEN
        RAISE EXCEPTION 'Ese grupo no está en la papelera' USING ERRCODE = 'P0019';
    END IF;

    -- Mientras estaba en la papelera pudieron crear otra con el mismo nombre
    PERFORM ecommerce.fn_grupos_productos_validar(p_id, v_nombre);

    UPDATE ecommerce.grupos_productos
       SET deleted_at = NULL, deleted_by = NULL WHERE id = p_id;

    RETURN jsonb_build_object('success', true,
        'message', format('Grupo «%s» restaurado', v_nombre),
        'data', ecommerce.fn_grupos_productos_json(p_id));
END;
$function$;
COMMIT;


-- ============================================================================
-- COMPROBACIÓN — no escribe nada
-- ============================================================================
DO $comprobar$
DECLARE
    v_falta text[] := '{}';
    v_n     integer;
BEGIN
    SELECT count(*) INTO v_n FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'ecommerce' AND p.proname LIKE '%grupos_productos%'
       -- Sin contar la tabla de las secciones de un cuerpo, que una de
       -- ellas sí toca: al renombrar un grupo le cambia el nombre a su
       -- escaparate
       AND replace(p.prosrc, 'inicio_secciones', '') ILIKE '%Secci%';
    IF v_n > 0 THEN
        v_falta := array_append(v_falta, 'quedan ' || v_n || ' funciones avisando de secciones');
    END IF;

    IF array_length(v_falta, 1) > 0 THEN
        RAISE EXCEPTION 'Los avisos no quedaron bien: %', array_to_string(v_falta, '; ');
    END IF;

    RAISE NOTICE 'Los avisos de los grupos ya hablan de grupos';
END;
$comprobar$;
