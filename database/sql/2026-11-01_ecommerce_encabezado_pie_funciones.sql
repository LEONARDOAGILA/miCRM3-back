-- ============================================================================
-- ECOMMERCE · ENCABEZADO Y PIE: LAS FUNCIONES
-- ============================================================================
-- Fecha: 2026-11-01
-- Va detrás de 2026-11-01_ecommerce_encabezado_pie.sql, que creó las tablas.
--
-- Mismo contrato que el resto del CRM nuevo: las de escritura devuelven
-- {success, message, data} y levantan SQLSTATE para que el controlador lo
-- traduzca a un 4xx con el mensaje ya en español.
--
-- UNA SOLA FUNCIÓN PÚBLICA, `fn_secciones_publicas()`, que arma el JSON
-- entero que lee la tienda. El CRM viejo lo montaba en PHP recorriendo filas;
-- aquí se hace en la base. No es capricho: el menú es un árbol y las reglas
-- de qué sale y qué no —un principal sin hijos y sin enlace no se enseña, un
-- hijo de un principal oculto tampoco— se aplican sobre el mismo SELECT en
-- vez de en dos bucles anidados.
--
-- Idempotente.
-- ============================================================================
\set ON_ERROR_STOP on

BEGIN;

-- ----------------------------------------------------------------------------
-- 1. LA CONFIGURACIÓN DEL ENCABEZADO
-- ----------------------------------------------------------------------------
-- Sólo se guardan estos campos: lo que llegue de más se descarta, que es lo
-- que acaba quedándose para siempre en un jsonb si no se filtra.
CREATE OR REPLACE FUNCTION ecommerce.fn_encabezado_validar_config(p_config jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 IMMUTABLE
AS $function$
DECLARE
    v_barra   jsonb := COALESCE(p_config -> 'barra_superior', '{}'::jsonb);
    v_credito jsonb := COALESCE(p_config -> 'credito', '{}'::jsonb);
    v_frases  jsonb := p_config -> 'buscador_frases';
    v_barra_on   boolean;
    v_credito_on boolean;
    v_frase   text;
    v_enlace_barra   text;
    v_enlace_credito text;
BEGIN
    IF p_config IS NULL OR jsonb_typeof(p_config) <> 'object' THEN
        RAISE EXCEPTION 'La configuración del encabezado no tiene la forma esperada' USING ERRCODE = 'P0015';
    END IF;
    IF jsonb_typeof(v_barra) <> 'object' OR jsonb_typeof(v_credito) <> 'object' THEN
        RAISE EXCEPTION 'La configuración del encabezado no tiene la forma esperada' USING ERRCODE = 'P0015';
    END IF;

    v_barra_on   := COALESCE((v_barra   -> 'activo') = 'true'::jsonb, false);
    v_credito_on := COALESCE((v_credito -> 'activo') = 'true'::jsonb, false);

    -- El texto sólo es obligatorio si la franja se va a ver: apagada, da igual
    -- lo que ponga, y exigirlo impediría apagarla para arreglarla luego.
    v_enlace_barra := ecommerce.fn_validar_enlace(v_barra ->> 'boton_enlace', 'La barra superior');

    -- Entre una y cinco frases: con ninguna el buscador se queda sin texto, y
    -- más de cinco no llegan a verse porque van rotando.
    IF v_frases IS NULL OR jsonb_typeof(v_frases) <> 'array'
       OR jsonb_array_length(v_frases) NOT BETWEEN 1 AND 5 THEN
        RAISE EXCEPTION 'El buscador necesita entre 1 y 5 frases' USING ERRCODE = 'P0015';
    END IF;

    FOR v_frase IN SELECT jsonb_array_elements_text(v_frases) LOOP
        PERFORM ecommerce.fn_validar_texto(v_frase, 'Cada frase del buscador', 60, true);
    END LOOP;

    v_enlace_credito := ecommerce.fn_validar_enlace(v_credito ->> 'boton_enlace', 'El aviso de crédito', v_credito_on);

    RETURN jsonb_build_object(
        'barra_superior', jsonb_build_object(
            'activo',              v_barra_on,
            'texto',               ecommerce.fn_validar_texto(v_barra ->> 'texto', 'El texto de la barra superior', 80, v_barra_on),
            'destacado',           ecommerce.fn_validar_texto(v_barra ->> 'destacado', 'El destacado de la barra superior', 60),
            'boton_texto',         ecommerce.fn_validar_texto(v_barra ->> 'boton_texto', 'El botón de la barra superior', 40),
            'boton_enlace',        v_enlace_barra,
            'boton_nueva_pestana', ecommerce.fn_nueva_pestana(v_enlace_barra, (v_barra ->> 'boton_nueva_pestana')::boolean)),
        'buscador_frases', (SELECT jsonb_agg(btrim(f)) FROM jsonb_array_elements_text(v_frases) AS f),
        'credito', jsonb_build_object(
            'activo',              v_credito_on,
            'texto',               ecommerce.fn_validar_texto(v_credito ->> 'texto', 'El texto del crédito', 60, v_credito_on),
            'boton_texto',         ecommerce.fn_validar_texto(v_credito ->> 'boton_texto', 'El botón del crédito', 30, v_credito_on),
            'boton_enlace',        v_enlace_credito,
            'boton_nueva_pestana', ecommerce.fn_nueva_pestana(v_enlace_credito, (v_credito ->> 'boton_nueva_pestana')::boolean))
    );
END;
$function$;

-- ----------------------------------------------------------------------------
-- 2. EL ENCABEZADO ENTERO, COMO LO VE LA PANTALLA
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ecommerce.fn_encabezado_enlaces_json()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
AS $function$
    -- El árbol completo, apagados incluidos: esto es la pantalla de
    -- administración, no la tienda. Lo de ocultar pasa en fn_secciones_publicas.
    SELECT COALESCE(jsonb_agg(x ORDER BY (x ->> 'orden')::int, (x ->> 'id')::bigint), '[]'::jsonb)
      FROM (
        SELECT jsonb_build_object(
                   'id',            p.id,
                   'texto',         p.texto,
                   'enlace',        p.enlace,
                   'icono',         p.icono,
                   'nueva_pestana', p.nueva_pestana,
                   'orden',         p.orden,
                   'activo',        p.activo,
                   'hijos', COALESCE((
                       SELECT jsonb_agg(jsonb_build_object(
                                  'id',            h.id,
                                  'texto',         h.texto,
                                  'enlace',        h.enlace,
                                  'icono',         h.icono,
                                  'nueva_pestana', h.nueva_pestana,
                                  'orden',         h.orden,
                                  'activo',        h.activo)
                              ORDER BY h.orden, h.id)
                         FROM ecommerce.encabezado_enlaces h
                        WHERE h.padre_id = p.id AND h.deleted_at IS NULL), '[]'::jsonb)
               ) AS x
          FROM ecommerce.encabezado_enlaces p
         WHERE p.padre_id IS NULL AND p.deleted_at IS NULL
      ) t;
$function$;

CREATE OR REPLACE FUNCTION ecommerce.fn_encabezado_obtener()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
AS $function$
    SELECT jsonb_build_object('success', true, 'message', 'Encabezado',
        'data', jsonb_build_object(
            'config',  e.config,
            'enlaces', ecommerce.fn_encabezado_enlaces_json(),
            'updated_at', to_char(e.updated_at, 'YYYY-MM-DD HH24:MI:SS'),
            'updated_by', e.updated_by))
      FROM ecommerce.encabezado e WHERE e.id = 1;
$function$;

CREATE OR REPLACE FUNCTION ecommerce.fn_encabezado_modificar(
    p_config jsonb,
    p_usuario_id bigint DEFAULT NULL, p_usuario_login character varying DEFAULT NULL,
    p_usuario_nombre character varying DEFAULT NULL, p_ip_address inet DEFAULT NULL,
    p_user_agent text DEFAULT NULL, p_request_id uuid DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'ecommerce', 'auditoria'
AS $function$
BEGIN
    PERFORM ecommerce.fn_contexto_auditoria('ecommerce.encabezado',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    UPDATE ecommerce.encabezado
       SET config = ecommerce.fn_encabezado_validar_config(p_config)
     WHERE id = 1;

    RETURN jsonb_build_object('success', true, 'message', 'Encabezado actualizado',
                              'data', (ecommerce.fn_encabezado_obtener() -> 'data'));
END;
$function$;

-- ----------------------------------------------------------------------------
-- 3. LOS ENLACES DEL MENÚ
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ecommerce.fn_encabezado_enlaces_guardar(
    p_id bigint, p_padre_id bigint, p_texto character varying, p_enlace character varying,
    p_icono character varying, p_activo boolean, p_nueva_pestana boolean,
    p_usuario_id bigint DEFAULT NULL, p_usuario_login character varying DEFAULT NULL,
    p_usuario_nombre character varying DEFAULT NULL, p_ip_address inet DEFAULT NULL,
    p_user_agent text DEFAULT NULL, p_request_id uuid DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'ecommerce', 'auditoria'
AS $function$
DECLARE
    v_id     bigint := p_id;
    v_texto  text;
    v_enlace text;
    v_icono  text;
    v_padre  bigint := p_padre_id;
    v_nuevo  boolean := p_id IS NULL;
BEGIN
    PERFORM ecommerce.fn_contexto_auditoria('ecommerce.encabezado_enlaces',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    v_texto  := ecommerce.fn_validar_texto(p_texto, 'El texto del enlace', 60, true);
    v_enlace := ecommerce.fn_validar_enlace(p_enlace, 'El enlace');
    v_icono  := ecommerce.fn_validar_texto(p_icono, 'El icono', 40);

    IF v_icono IS NOT NULL AND v_icono !~ '^[a-z0-9-]+$' THEN
        RAISE EXCEPTION 'El icono sólo admite letras minúsculas, números y guiones' USING ERRCODE = 'P0015';
    END IF;

    IF NOT v_nuevo THEN
        -- El padre no se cambia al modificar: mover un enlace de sitio es
        -- arrastrarlo, y mezclarlo aquí dejaría dos caminos para lo mismo.
        SELECT padre_id INTO v_padre FROM ecommerce.encabezado_enlaces
         WHERE id = p_id AND deleted_at IS NULL;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'El enlace no existe' USING ERRCODE = 'P0013';
        END IF;
    END IF;

    IF v_padre IS NOT NULL THEN
        -- Dos niveles como mucho: el padre tiene que ser un principal
        IF NOT EXISTS (SELECT 1 FROM ecommerce.encabezado_enlaces
                        WHERE id = v_padre AND padre_id IS NULL AND deleted_at IS NULL) THEN
            RAISE EXCEPTION 'El enlace del que debería colgar no existe o ya es un desplegable' USING ERRCODE = 'P0016';
        END IF;
        -- Un hijo SIN dirección no lleva a ninguna parte: el principal puede
        -- no tenerla (sólo despliega), el hijo no.
        IF v_enlace IS NULL THEN
            RAISE EXCEPTION 'Un enlace del desplegable necesita su dirección' USING ERRCODE = 'P0001';
        END IF;
    END IF;

    IF v_nuevo THEN
        INSERT INTO ecommerce.encabezado_enlaces
               (padre_id, texto, enlace, icono, activo, nueva_pestana, orden)
        VALUES (v_padre, v_texto, v_enlace, v_icono,
                COALESCE(p_activo, true),
                ecommerce.fn_nueva_pestana(v_enlace, p_nueva_pestana),
                (SELECT COALESCE(max(orden), 0) + 1 FROM ecommerce.encabezado_enlaces
                  WHERE padre_id IS NOT DISTINCT FROM v_padre AND deleted_at IS NULL))
        RETURNING id INTO v_id;
    ELSE
        UPDATE ecommerce.encabezado_enlaces
           SET texto = v_texto, enlace = v_enlace, icono = v_icono,
               activo = COALESCE(p_activo, true),
               nueva_pestana = ecommerce.fn_nueva_pestana(v_enlace, p_nueva_pestana)
         WHERE id = v_id;
    END IF;

    RETURN jsonb_build_object('success', true,
        'message', CASE WHEN v_nuevo THEN 'Enlace creado' ELSE 'Enlace actualizado' END,
        'data', (ecommerce.fn_encabezado_obtener() -> 'data'));
END;
$function$;

CREATE OR REPLACE FUNCTION ecommerce.fn_encabezado_enlaces_activar(
    p_id bigint, p_activo boolean DEFAULT NULL,
    p_usuario_id bigint DEFAULT NULL, p_usuario_login character varying DEFAULT NULL,
    p_usuario_nombre character varying DEFAULT NULL, p_ip_address inet DEFAULT NULL,
    p_user_agent text DEFAULT NULL, p_request_id uuid DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'ecommerce', 'auditoria'
AS $function$
DECLARE
    v_actual boolean;
    v_texto  text;
    v_nuevo  boolean;
BEGIN
    PERFORM ecommerce.fn_contexto_auditoria('ecommerce.encabezado_enlaces',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    SELECT activo, texto INTO v_actual, v_texto
      FROM ecommerce.encabezado_enlaces WHERE id = p_id AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'El enlace no existe' USING ERRCODE = 'P0013';
    END IF;

    v_nuevo := COALESCE(p_activo, NOT v_actual);
    UPDATE ecommerce.encabezado_enlaces SET activo = v_nuevo WHERE id = p_id;

    RETURN jsonb_build_object('success', true,
        'message', format('«%s» %s', v_texto, CASE WHEN v_nuevo THEN 'se ve en el menú' ELSE 'oculto en el menú' END),
        'data', (ecommerce.fn_encabezado_obtener() -> 'data'));
END;
$function$;

CREATE OR REPLACE FUNCTION ecommerce.fn_encabezado_enlaces_ordenar(
    p_ids jsonb,
    p_usuario_id bigint DEFAULT NULL, p_usuario_login character varying DEFAULT NULL,
    p_usuario_nombre character varying DEFAULT NULL, p_ip_address inet DEFAULT NULL,
    p_user_agent text DEFAULT NULL, p_request_id uuid DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'ecommerce', 'auditoria'
AS $function$
DECLARE
    v integer;
BEGIN
    PERFORM ecommerce.fn_contexto_auditoria('ecommerce.encabezado_enlaces',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    IF jsonb_typeof(p_ids) <> 'array' THEN
        RAISE EXCEPTION 'Se esperaba la lista de enlaces en el orden nuevo' USING ERRCODE = 'P0015';
    END IF;

    UPDATE ecommerce.encabezado_enlaces e
       SET orden = t.posicion
      FROM (SELECT valor::bigint AS id, ordinalidad::integer AS posicion
              FROM jsonb_array_elements_text(p_ids) WITH ORDINALITY AS x(valor, ordinalidad)) t
     WHERE e.id = t.id AND e.deleted_at IS NULL;
    GET DIAGNOSTICS v = ROW_COUNT;

    RETURN jsonb_build_object('success', true,
        'message', CASE v WHEN 1 THEN 'Enlace movido' ELSE format('%s enlaces reordenados', v) END,
        'data', (ecommerce.fn_encabezado_obtener() -> 'data'));
END;
$function$;

CREATE OR REPLACE FUNCTION ecommerce.fn_encabezado_enlaces_eliminar(
    p_id bigint,
    p_usuario_id bigint DEFAULT NULL, p_usuario_login character varying DEFAULT NULL,
    p_usuario_nombre character varying DEFAULT NULL, p_ip_address inet DEFAULT NULL,
    p_user_agent text DEFAULT NULL, p_request_id uuid DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'ecommerce', 'auditoria'
AS $function$
DECLARE
    v_texto text;
    v_fecha timestamptz := CURRENT_TIMESTAMP;
    v_hijos integer;
BEGIN
    PERFORM ecommerce.fn_contexto_auditoria('ecommerce.encabezado_enlaces',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    SELECT texto INTO v_texto FROM ecommerce.encabezado_enlaces
     WHERE id = p_id AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'El enlace no existe' USING ERRCODE = 'P0013';
    END IF;

    -- Los desplegables se van CON su principal: dejarlos colgando de un padre
    -- que ya no está los haría invisibles sin estar borrados.
    UPDATE ecommerce.encabezado_enlaces
       SET deleted_at = v_fecha, deleted_by = p_usuario_login
     WHERE padre_id = p_id AND deleted_at IS NULL;
    GET DIAGNOSTICS v_hijos = ROW_COUNT;

    UPDATE ecommerce.encabezado_enlaces
       SET deleted_at = v_fecha, deleted_by = p_usuario_login WHERE id = p_id;

    RETURN jsonb_build_object('success', true,
        'message', CASE v_hijos
                       WHEN 0 THEN format('«%s» va a la papelera', v_texto)
                       WHEN 1 THEN format('«%s» va a la papelera con su desplegable', v_texto)
                       ELSE format('«%s» va a la papelera con sus %s desplegables', v_texto, v_hijos) END,
        'data', (ecommerce.fn_encabezado_obtener() -> 'data'));
END;
$function$;

CREATE OR REPLACE FUNCTION ecommerce.fn_encabezado_enlaces_restaurar(
    p_ids jsonb,
    p_usuario_id bigint DEFAULT NULL, p_usuario_login character varying DEFAULT NULL,
    p_usuario_nombre character varying DEFAULT NULL, p_ip_address inet DEFAULT NULL,
    p_user_agent text DEFAULT NULL, p_request_id uuid DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'ecommerce', 'auditoria'
AS $function$
DECLARE
    v integer;
BEGIN
    PERFORM ecommerce.fn_contexto_auditoria('ecommerce.encabezado_enlaces',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    IF jsonb_typeof(p_ids) <> 'array' OR jsonb_array_length(p_ids) = 0 THEN
        RAISE EXCEPTION 'No se indicó qué restaurar' USING ERRCODE = 'P0015';
    END IF;

    -- Un desplegable cuyo principal sigue en la papelera vuelve como
    -- PRINCIPAL: restaurarlo bajo un padre que no se ve sería restaurarlo a
    -- ninguna parte. Y si no tiene dirección propia, no se puede: se dice.
    UPDATE ecommerce.encabezado_enlaces h
       SET deleted_at = NULL, deleted_by = NULL,
           padre_id = CASE WHEN EXISTS (SELECT 1 FROM ecommerce.encabezado_enlaces p
                                         WHERE p.id = h.padre_id AND p.deleted_at IS NULL)
                           THEN h.padre_id END
     WHERE h.deleted_at IS NOT NULL
       AND h.id IN (SELECT valor::bigint FROM jsonb_array_elements_text(p_ids) AS x(valor));
    GET DIAGNOSTICS v = ROW_COUNT;

    IF v = 0 THEN
        RAISE EXCEPTION 'Ninguno de esos enlaces está en la papelera' USING ERRCODE = 'P0019';
    END IF;

    RETURN jsonb_build_object('success', true,
        'message', CASE v WHEN 1 THEN 'Enlace restaurado' ELSE format('%s enlaces restaurados', v) END,
        'data', (ecommerce.fn_encabezado_obtener() -> 'data'));
END;
$function$;

CREATE OR REPLACE FUNCTION ecommerce.fn_encabezado_enlaces_papelera_listar()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
AS $function$
    SELECT jsonb_build_object('success', true, 'message', 'Papelera del encabezado',
        'data', COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
                       'id', e.id, 'texto', e.texto, 'detalle', e.enlace,
                       'padre_id', e.padre_id,
                       'deleted_at', to_char(e.deleted_at, 'YYYY-MM-DD HH24:MI:SS'),
                       'deleted_by', e.deleted_by)
                   ORDER BY e.deleted_at DESC, e.texto)
              FROM ecommerce.encabezado_enlaces e WHERE e.deleted_at IS NOT NULL), '[]'::jsonb));
$function$;

CREATE OR REPLACE FUNCTION ecommerce.fn_encabezado_enlaces_papelera_vaciar(
    p_usuario_id bigint DEFAULT NULL, p_usuario_login character varying DEFAULT NULL,
    p_usuario_nombre character varying DEFAULT NULL, p_ip_address inet DEFAULT NULL,
    p_user_agent text DEFAULT NULL, p_request_id uuid DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'ecommerce', 'auditoria'
AS $function$
DECLARE
    v integer;
BEGIN
    PERFORM ecommerce.fn_contexto_auditoria('ecommerce.encabezado_enlaces',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    -- Los hijos primero: la clave ajena apunta a esta misma tabla
    DELETE FROM ecommerce.encabezado_enlaces WHERE deleted_at IS NOT NULL AND padre_id IS NOT NULL;
    DELETE FROM ecommerce.encabezado_enlaces WHERE deleted_at IS NOT NULL;
    GET DIAGNOSTICS v = ROW_COUNT;

    RETURN jsonb_build_object('success', true, 'message', 'Papelera del encabezado vaciada',
                              'data', jsonb_build_object('enlaces', v));
END;
$function$;

-- ----------------------------------------------------------------------------
-- 4. EL PIE
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ecommerce.fn_pie_validar_config(p_config jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 IMMUTABLE
AS $function$
DECLARE
    v_redes  jsonb := COALESCE(p_config -> 'redes', '[]'::jsonb);
    v_red    jsonb;
    v_salida jsonb := '[]'::jsonb;
    v_tipo   text;
    v_enlace text;
BEGIN
    IF p_config IS NULL OR jsonb_typeof(p_config) <> 'object' THEN
        RAISE EXCEPTION 'La configuración del pie no tiene la forma esperada' USING ERRCODE = 'P0015';
    END IF;
    IF jsonb_typeof(v_redes) <> 'array' THEN
        RAISE EXCEPTION 'Las redes sociales deben venir en una lista' USING ERRCODE = 'P0015';
    END IF;

    FOR v_red IN SELECT * FROM jsonb_array_elements(v_redes) LOOP
        v_tipo := ecommerce.fn_validar_texto(v_red ->> 'tipo', 'El tipo de red social', 20, true);
        IF v_tipo !~ '^[a-z0-9_-]+$' THEN
            RAISE EXCEPTION 'El tipo de red «%» sólo admite letras minúsculas, números y guiones', v_tipo
                  USING ERRCODE = 'P0015';
        END IF;

        -- Una red APAGADA puede quedarse sin dirección: así se guarda a
        -- medias y se termina otro día sin perder lo escrito.
        v_enlace := ecommerce.fn_validar_enlace(v_red ->> 'enlace', format('La red «%s»', v_tipo),
                                                COALESCE((v_red -> 'activo') = 'true'::jsonb, false));

        v_salida := v_salida || jsonb_build_array(jsonb_build_object(
            'tipo',   v_tipo,
            'enlace', v_enlace,
            'activo', COALESCE((v_red -> 'activo') = 'true'::jsonb, false)));
    END LOOP;

    RETURN jsonb_build_object('redes', v_salida);
END;
$function$;

CREATE OR REPLACE FUNCTION ecommerce.fn_pie_obtener()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
AS $function$
    SELECT jsonb_build_object('success', true, 'message', 'Pie de página',
        'data', jsonb_build_object(
            'config', p.config,
            'columnas', COALESCE((
                SELECT jsonb_agg(jsonb_build_object(
                           'id', c.id, 'titulo', c.titulo, 'orden', c.orden, 'activo', c.activo,
                           'enlaces', COALESCE((
                               SELECT jsonb_agg(jsonb_build_object(
                                          'id', l.id, 'texto', l.texto, 'enlace', l.enlace,
                                          'icono', l.icono, 'nueva_pestana', l.nueva_pestana,
                                          'orden', l.orden, 'activo', l.activo)
                                      ORDER BY l.orden, l.id)
                                 FROM ecommerce.pie_enlaces l
                                WHERE l.columna_id = c.id AND l.deleted_at IS NULL), '[]'::jsonb))
                       ORDER BY c.orden, c.id)
                  FROM ecommerce.pie_columnas c WHERE c.deleted_at IS NULL), '[]'::jsonb),
            'updated_at', to_char(p.updated_at, 'YYYY-MM-DD HH24:MI:SS'),
            'updated_by', p.updated_by))
      FROM ecommerce.pie p WHERE p.id = 1;
$function$;

CREATE OR REPLACE FUNCTION ecommerce.fn_pie_modificar(
    p_config jsonb,
    p_usuario_id bigint DEFAULT NULL, p_usuario_login character varying DEFAULT NULL,
    p_usuario_nombre character varying DEFAULT NULL, p_ip_address inet DEFAULT NULL,
    p_user_agent text DEFAULT NULL, p_request_id uuid DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'ecommerce', 'auditoria'
AS $function$
BEGIN
    PERFORM ecommerce.fn_contexto_auditoria('ecommerce.pie',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    UPDATE ecommerce.pie SET config = ecommerce.fn_pie_validar_config(p_config) WHERE id = 1;

    RETURN jsonb_build_object('success', true, 'message', 'Pie de página actualizado',
                              'data', (ecommerce.fn_pie_obtener() -> 'data'));
END;
$function$;

CREATE OR REPLACE FUNCTION ecommerce.fn_pie_columnas_guardar(
    p_id bigint, p_titulo character varying, p_activo boolean,
    p_usuario_id bigint DEFAULT NULL, p_usuario_login character varying DEFAULT NULL,
    p_usuario_nombre character varying DEFAULT NULL, p_ip_address inet DEFAULT NULL,
    p_user_agent text DEFAULT NULL, p_request_id uuid DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'ecommerce', 'auditoria'
AS $function$
DECLARE
    v_id     bigint := p_id;
    v_titulo text;
BEGIN
    PERFORM ecommerce.fn_contexto_auditoria('ecommerce.pie_columnas',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    v_titulo := ecommerce.fn_validar_texto(p_titulo, 'El título de la columna', 60, true);

    IF p_id IS NULL THEN
        INSERT INTO ecommerce.pie_columnas (titulo, activo, orden)
        VALUES (v_titulo, COALESCE(p_activo, true),
                (SELECT COALESCE(max(orden), 0) + 1 FROM ecommerce.pie_columnas WHERE deleted_at IS NULL))
        RETURNING id INTO v_id;
    ELSE
        UPDATE ecommerce.pie_columnas
           SET titulo = v_titulo, activo = COALESCE(p_activo, true)
         WHERE id = p_id AND deleted_at IS NULL;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'La columna no existe' USING ERRCODE = 'P0013';
        END IF;
    END IF;

    RETURN jsonb_build_object('success', true,
        'message', CASE WHEN p_id IS NULL THEN 'Columna creada' ELSE 'Columna actualizada' END,
        'data', (ecommerce.fn_pie_obtener() -> 'data'));
END;
$function$;

CREATE OR REPLACE FUNCTION ecommerce.fn_pie_columnas_eliminar(
    p_id bigint,
    p_usuario_id bigint DEFAULT NULL, p_usuario_login character varying DEFAULT NULL,
    p_usuario_nombre character varying DEFAULT NULL, p_ip_address inet DEFAULT NULL,
    p_user_agent text DEFAULT NULL, p_request_id uuid DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'ecommerce', 'auditoria'
AS $function$
DECLARE
    v_titulo text;
    v_fecha  timestamptz := CURRENT_TIMESTAMP;
    v_hijos  integer;
BEGIN
    PERFORM ecommerce.fn_contexto_auditoria('ecommerce.pie_columnas',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    SELECT titulo INTO v_titulo FROM ecommerce.pie_columnas WHERE id = p_id AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'La columna no existe' USING ERRCODE = 'P0013';
    END IF;

    -- Igual que en el encabezado: los enlaces se van con su columna, y
    -- restaurarla los devuelve por la marca de tiempo.
    UPDATE ecommerce.pie_enlaces
       SET deleted_at = v_fecha, deleted_by = p_usuario_login
     WHERE columna_id = p_id AND deleted_at IS NULL;
    GET DIAGNOSTICS v_hijos = ROW_COUNT;

    UPDATE ecommerce.pie_columnas
       SET deleted_at = v_fecha, deleted_by = p_usuario_login WHERE id = p_id;

    RETURN jsonb_build_object('success', true,
        'message', CASE v_hijos
                       WHEN 0 THEN format('Columna «%s» a la papelera', v_titulo)
                       WHEN 1 THEN format('Columna «%s» a la papelera con su enlace', v_titulo)
                       ELSE format('Columna «%s» a la papelera con sus %s enlaces', v_titulo, v_hijos) END,
        'data', (ecommerce.fn_pie_obtener() -> 'data'));
END;
$function$;

CREATE OR REPLACE FUNCTION ecommerce.fn_pie_enlaces_guardar(
    p_id bigint, p_columna_id bigint, p_texto character varying, p_enlace character varying,
    p_icono character varying, p_activo boolean, p_nueva_pestana boolean,
    p_usuario_id bigint DEFAULT NULL, p_usuario_login character varying DEFAULT NULL,
    p_usuario_nombre character varying DEFAULT NULL, p_ip_address inet DEFAULT NULL,
    p_user_agent text DEFAULT NULL, p_request_id uuid DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'ecommerce', 'auditoria'
AS $function$
DECLARE
    v_id      bigint := p_id;
    v_texto   text;
    v_enlace  text;
    v_icono   text;
    v_columna bigint := p_columna_id;
BEGIN
    PERFORM ecommerce.fn_contexto_auditoria('ecommerce.pie_enlaces',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    v_texto  := ecommerce.fn_validar_texto(p_texto, 'El texto del enlace', 60, true);
    -- En el pie SÍ es obligatorio: aquí no hay desplegables, un enlace sin
    -- dirección sería una línea de texto suelta que parece pinchable.
    v_enlace := ecommerce.fn_validar_enlace(p_enlace, 'El enlace', true);
    v_icono  := ecommerce.fn_validar_texto(p_icono, 'El icono', 40);

    IF p_id IS NOT NULL THEN
        SELECT columna_id INTO v_columna FROM ecommerce.pie_enlaces
         WHERE id = p_id AND deleted_at IS NULL;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'El enlace no existe' USING ERRCODE = 'P0013';
        END IF;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM ecommerce.pie_columnas WHERE id = v_columna AND deleted_at IS NULL) THEN
        RAISE EXCEPTION 'La columna indicada no existe' USING ERRCODE = 'P0016';
    END IF;

    IF p_id IS NULL THEN
        INSERT INTO ecommerce.pie_enlaces (columna_id, texto, enlace, icono, activo, nueva_pestana, orden)
        VALUES (v_columna, v_texto, v_enlace, v_icono, COALESCE(p_activo, true),
                ecommerce.fn_nueva_pestana(v_enlace, p_nueva_pestana),
                (SELECT COALESCE(max(orden), 0) + 1 FROM ecommerce.pie_enlaces
                  WHERE columna_id = v_columna AND deleted_at IS NULL))
        RETURNING id INTO v_id;
    ELSE
        UPDATE ecommerce.pie_enlaces
           SET texto = v_texto, enlace = v_enlace, icono = v_icono,
               activo = COALESCE(p_activo, true),
               nueva_pestana = ecommerce.fn_nueva_pestana(v_enlace, p_nueva_pestana)
         WHERE id = v_id;
    END IF;

    RETURN jsonb_build_object('success', true,
        'message', CASE WHEN p_id IS NULL THEN 'Enlace creado' ELSE 'Enlace actualizado' END,
        'data', (ecommerce.fn_pie_obtener() -> 'data'));
END;
$function$;

CREATE OR REPLACE FUNCTION ecommerce.fn_pie_enlaces_eliminar(
    p_id bigint,
    p_usuario_id bigint DEFAULT NULL, p_usuario_login character varying DEFAULT NULL,
    p_usuario_nombre character varying DEFAULT NULL, p_ip_address inet DEFAULT NULL,
    p_user_agent text DEFAULT NULL, p_request_id uuid DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'ecommerce', 'auditoria'
AS $function$
DECLARE
    v_texto text;
BEGIN
    PERFORM ecommerce.fn_contexto_auditoria('ecommerce.pie_enlaces',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    SELECT texto INTO v_texto FROM ecommerce.pie_enlaces WHERE id = p_id AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'El enlace no existe' USING ERRCODE = 'P0013';
    END IF;

    UPDATE ecommerce.pie_enlaces
       SET deleted_at = CURRENT_TIMESTAMP, deleted_by = p_usuario_login WHERE id = p_id;

    RETURN jsonb_build_object('success', true, 'message', format('«%s» va a la papelera', v_texto),
                              'data', (ecommerce.fn_pie_obtener() -> 'data'));
END;
$function$;

-- Ordenar vale para columnas y para enlaces: cambia la tabla, no la idea.
CREATE OR REPLACE FUNCTION ecommerce.fn_pie_ordenar(
    p_que text, p_ids jsonb,
    p_usuario_id bigint DEFAULT NULL, p_usuario_login character varying DEFAULT NULL,
    p_usuario_nombre character varying DEFAULT NULL, p_ip_address inet DEFAULT NULL,
    p_user_agent text DEFAULT NULL, p_request_id uuid DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'ecommerce', 'auditoria'
AS $function$
DECLARE
    v integer;
BEGIN
    IF p_que NOT IN ('columnas', 'enlaces') THEN
        RAISE EXCEPTION 'Sólo se pueden ordenar columnas o enlaces' USING ERRCODE = 'P0015';
    END IF;
    IF jsonb_typeof(p_ids) <> 'array' THEN
        RAISE EXCEPTION 'Se esperaba la lista en el orden nuevo' USING ERRCODE = 'P0015';
    END IF;

    PERFORM ecommerce.fn_contexto_auditoria('ecommerce.pie_' || p_que,
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    IF p_que = 'columnas' THEN
        UPDATE ecommerce.pie_columnas c SET orden = t.posicion
          FROM (SELECT valor::bigint AS id, ordinalidad::integer AS posicion
                  FROM jsonb_array_elements_text(p_ids) WITH ORDINALITY AS x(valor, ordinalidad)) t
         WHERE c.id = t.id AND c.deleted_at IS NULL;
    ELSE
        UPDATE ecommerce.pie_enlaces e SET orden = t.posicion
          FROM (SELECT valor::bigint AS id, ordinalidad::integer AS posicion
                  FROM jsonb_array_elements_text(p_ids) WITH ORDINALITY AS x(valor, ordinalidad)) t
         WHERE e.id = t.id AND e.deleted_at IS NULL;
    END IF;
    GET DIAGNOSTICS v = ROW_COUNT;

    RETURN jsonb_build_object('success', true,
        'message', CASE v WHEN 1 THEN 'Movido' ELSE format('%s elementos reordenados', v) END,
        'data', (ecommerce.fn_pie_obtener() -> 'data'));
END;
$function$;

-- ----------------------------------------------------------------------------
-- 5. LO QUE LEE LA TIENDA
-- ----------------------------------------------------------------------------
-- El JSON entero, con las reglas de visibilidad aplicadas:
--
--   · sólo lo activo;
--   · un principal CON desplegables visibles no lleva dirección propia: en la
--     tienda sólo despliega, y darle enlace además haría que un clic hiciera
--     dos cosas distintas según dónde cayera;
--   · un principal SIN desplegables y SIN dirección no se enseña, porque no
--     llevaría a ninguna parte;
--   · los desplegables de un principal oculto tampoco salen.
CREATE OR REPLACE FUNCTION ecommerce.fn_secciones_publicas()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
AS $function$
    WITH menu AS (
        SELECT p.id, p.texto, p.enlace, p.icono, p.nueva_pestana, p.orden,
               COALESCE((
                   SELECT jsonb_agg(jsonb_build_object(
                              'texto', h.texto, 'enlace', h.enlace, 'icono', h.icono,
                              'nueva_pestana', h.nueva_pestana)
                          ORDER BY h.orden, h.id)
                     FROM ecommerce.encabezado_enlaces h
                    WHERE h.padre_id = p.id AND h.activo AND h.deleted_at IS NULL), '[]'::jsonb) AS hijos
          FROM ecommerce.encabezado_enlaces p
         WHERE p.padre_id IS NULL AND p.activo AND p.deleted_at IS NULL
    )
    SELECT jsonb_build_array(
        jsonb_build_object(
            'clave', 'header', 'tipo', 'header', 'ubicacion', 'arriba', 'orden', 1, 'titulo', 'Header',
            'config', (SELECT config FROM ecommerce.encabezado WHERE id = 1),
            'menu', COALESCE((
                SELECT jsonb_agg(jsonb_build_object(
                           'texto', m.texto,
                           -- Con desplegables, el principal no lleva enlace
                           'enlace', CASE WHEN m.hijos = '[]'::jsonb THEN m.enlace END,
                           'icono', m.icono,
                           'nueva_pestana', CASE WHEN m.hijos = '[]'::jsonb THEN m.nueva_pestana ELSE false END,
                           'hijos', m.hijos)
                       ORDER BY m.orden, m.id)
                  FROM menu m
                 WHERE m.hijos <> '[]'::jsonb OR m.enlace IS NOT NULL), '[]'::jsonb),
            'grupos', '[]'::jsonb),
        jsonb_build_object(
            'clave', 'footer', 'tipo', 'footer', 'ubicacion', 'abajo', 'orden', 1, 'titulo', 'Footer',
            -- De las redes sólo salen las encendidas, y sin el «activo», que
            -- a la tienda no le dice nada
            'config', jsonb_build_object('redes', COALESCE((
                SELECT jsonb_agg(jsonb_build_object('tipo', r ->> 'tipo', 'enlace', r ->> 'enlace'))
                  FROM ecommerce.pie p, jsonb_array_elements(COALESCE(p.config -> 'redes', '[]'::jsonb)) r
                 WHERE p.id = 1 AND (r -> 'activo') = 'true'::jsonb), '[]'::jsonb)),
            'menu', '[]'::jsonb,
            'grupos', COALESCE((
                SELECT jsonb_agg(jsonb_build_object(
                           'titulo', c.titulo,
                           'items', COALESCE((
                               SELECT jsonb_agg(jsonb_build_object(
                                          'texto', l.texto, 'enlace', l.enlace,
                                          'icono', l.icono, 'nueva_pestana', l.nueva_pestana)
                                      ORDER BY l.orden, l.id)
                                 FROM ecommerce.pie_enlaces l
                                WHERE l.columna_id = c.id AND l.activo AND l.deleted_at IS NULL), '[]'::jsonb))
                       ORDER BY c.orden, c.id)
                  FROM ecommerce.pie_columnas c
                 WHERE c.activo AND c.deleted_at IS NULL), '[]'::jsonb))
    );
$function$;

-- ----------------------------------------------------------------------------
-- 6. QUE DE VERDAD FUNCIONE
-- ----------------------------------------------------------------------------
DO $comprobar$
DECLARE
    v_sec    jsonb;
    v_header jsonb;
    v_footer jsonb;
    v_menu   jsonb;
BEGIN
    v_sec := ecommerce.fn_secciones_publicas();
    IF jsonb_array_length(v_sec) <> 2 THEN
        RAISE EXCEPTION 'Se esperaban dos secciones y vinieron %', jsonb_array_length(v_sec);
    END IF;

    v_header := v_sec -> 0;
    v_footer := v_sec -> 1;

    IF v_header ->> 'clave' <> 'header' OR v_footer ->> 'clave' <> 'footer' THEN
        RAISE EXCEPTION 'Las secciones no vienen en el orden esperado';
    END IF;

    IF v_header -> 'config' -> 'buscador_frases' IS NULL THEN
        RAISE EXCEPTION 'El encabezado viene sin las frases del buscador';
    END IF;

    v_menu := v_header -> 'menu';
    IF jsonb_array_length(v_menu) = 0 THEN
        RAISE EXCEPTION 'El menú del encabezado salió vacío';
    END IF;

    -- El que tiene desplegables no puede llevar enlace propio
    IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_menu) m
                WHERE jsonb_array_length(m -> 'hijos') > 0 AND m -> 'enlace' <> 'null'::jsonb) THEN
        RAISE EXCEPTION 'Un enlace con desplegables se quedó con dirección propia';
    END IF;

    IF jsonb_array_length(v_footer -> 'grupos') = 0 THEN
        RAISE EXCEPTION 'El pie salió sin columnas';
    END IF;

    IF ecommerce.fn_encabezado_obtener() -> 'data' -> 'enlaces' = '[]'::jsonb THEN
        RAISE EXCEPTION 'La pantalla de administración no ve ningún enlace';
    END IF;

    IF ecommerce.fn_pie_obtener() -> 'data' -> 'columnas' = '[]'::jsonb THEN
        RAISE EXCEPTION 'La pantalla del pie no ve ninguna columna';
    END IF;

    RAISE NOTICE 'Comprobado: % enlaces en el menú y % columnas en el pie.',
          jsonb_array_length(v_menu), jsonb_array_length(v_footer -> 'grupos');
END
$comprobar$;

-- ----------------------------------------------------------------------------
-- 7. FUERA LO VIEJO
-- ----------------------------------------------------------------------------
DO $limpiar$
DECLARE
    r record;
BEGIN
    FOR r IN SELECT p.oid::regprocedure::text AS firma
               FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
              WHERE n.nspname = 'ecommerce' AND p.prokind = 'f'
                AND (p.proname LIKE 'fn\_encabezado\_enlace\_%'
                  OR p.proname IN ('fn_encabezado_buscar', 'fn_encabezado_validaciones')
                  OR p.proname LIKE 'fn\_pie\_pagina\_%'
                  OR p.proname LIKE 'fn\_pie\_columna\_%'
                  OR p.proname LIKE 'fn\_pie\_enlace\_%'
                  OR p.proname IN ('fn_pie_papelera', 'fn_pie_vaciar')) LOOP
        EXECUTE 'DROP FUNCTION IF EXISTS ' || r.firma;
    END LOOP;

    DROP TABLE IF EXISTS ecommerce.pie_enlace;
    DROP TABLE IF EXISTS ecommerce.pie_columna;
    DROP TABLE IF EXISTS ecommerce.pie_pagina;
    DROP TABLE IF EXISTS ecommerce.encabezado_enlace;
    DROP TABLE IF EXISTS ecommerce.encabezado_legado;
    RAISE NOTICE 'Borradas las tablas y funciones viejas del encabezado y del pie.';
END
$limpiar$;

COMMIT;
