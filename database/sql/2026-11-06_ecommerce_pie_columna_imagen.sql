-- ============================================================================
-- ECOMMERCE · UNA COLUMNA DEL PIE CON IMAGEN EN VEZ DE ENLACES
-- ============================================================================
-- Fecha: 2026-11-06
--
-- Una columna del pie es un título y una lista de enlaces. Ahora puede ser un
-- título y UNA IMAGEN: la de los medios de pago, la del sello de garantía, la
-- de las aplicaciones móviles… cosas que hoy había que escribir línea a línea
-- y que en realidad son un dibujo.
--
-- LA IMAGEN SUSTITUYE A LOS ENLACES, no se suma. Es lo que se pidió —«poner en
-- la columna una imagen en vez de escribir varias líneas»— y es lo que hace
-- que la columna se lea de un vistazo. Los enlaces NO SE BORRAN: quitar la
-- imagen los devuelve tal cual, así que probar no cuesta nada.
--
-- EL FICHERO VA POR SU PROPIA PUERTA (`fn_pie_columna_imagen`), como la imagen
-- de una sección del inicio: `fn_pie_columnas_guardar` escribe todos los
-- campos que recibe, así que renombrar la columna borraría la imagen.
--
-- EN LA BASE VA SÓLO EL NOMBRE DEL FICHERO, como en todo el ecommerce: la
-- dirección la arma PHP al leer (ImagenesDelEcommerce).
--
-- Idempotente.
-- ============================================================================
\set ON_ERROR_STOP on

BEGIN;

-- ----------------------------------------------------------------------------
-- 1. LAS COLUMNAS
-- ----------------------------------------------------------------------------
ALTER TABLE ecommerce.pie_columnas
    ADD COLUMN IF NOT EXISTS imagen               varchar(255),
    ADD COLUMN IF NOT EXISTS imagen_alt           varchar(120),
    ADD COLUMN IF NOT EXISTS imagen_enlace        varchar(250),
    ADD COLUMN IF NOT EXISTS imagen_nueva_pestana boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN ecommerce.pie_columnas.imagen IS
    'Nombre del fichero. Con imagen, la columna enseña la imagen en vez de sus enlaces (que se conservan).';

-- ----------------------------------------------------------------------------
-- 2. GUARDAR LA COLUMNA (sin el fichero)
-- ----------------------------------------------------------------------------
-- Cambia la lista de parámetros, así que hay que tirarla y volver a crearla:
-- CREATE OR REPLACE con otros argumentos deja DOS funciones y la llamada se
-- vuelve ambigua.
DROP FUNCTION IF EXISTS ecommerce.fn_pie_columnas_guardar(
    bigint, character varying, boolean, bigint, character varying, character varying, inet, text, uuid);

CREATE OR REPLACE FUNCTION ecommerce.fn_pie_columnas_guardar(
    p_id                   bigint,
    p_titulo               character varying,
    p_activo               boolean,
    p_imagen_alt           character varying DEFAULT NULL,
    p_imagen_enlace        character varying DEFAULT NULL,
    p_imagen_nueva_pestana boolean           DEFAULT NULL,
    p_usuario_id           bigint            DEFAULT NULL,
    p_usuario_login        character varying DEFAULT NULL,
    p_usuario_nombre       character varying DEFAULT NULL,
    p_ip_address           inet              DEFAULT NULL,
    p_user_agent           text              DEFAULT NULL,
    p_request_id           uuid              DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'ecommerce', 'auditoria'
AS $function$
DECLARE
    v_id     bigint := p_id;
    v_titulo text;
    v_alt    text;
    v_enlace text;
BEGIN
    PERFORM ecommerce.fn_contexto_auditoria('ecommerce.pie_columnas',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    v_titulo := ecommerce.fn_validar_texto(p_titulo, 'El título de la columna', 60, true);
    v_alt    := ecommerce.fn_validar_texto(p_imagen_alt, 'El texto de la imagen', 120);
    -- El mismo portero que en el encabezado y el inicio: ni «javascript:» ni
    -- direcciones inventadas
    v_enlace := ecommerce.fn_validar_enlace(p_imagen_enlace, 'El enlace de la imagen');

    IF p_id IS NULL THEN
        INSERT INTO ecommerce.pie_columnas (titulo, activo, orden,
                    imagen_alt, imagen_enlace, imagen_nueva_pestana)
        VALUES (v_titulo, COALESCE(p_activo, true),
                (SELECT COALESCE(max(orden), 0) + 1 FROM ecommerce.pie_columnas WHERE deleted_at IS NULL),
                v_alt, v_enlace, ecommerce.fn_nueva_pestana(v_enlace, p_imagen_nueva_pestana))
        RETURNING id INTO v_id;
    ELSE
        -- `imagen` NO está aquí a propósito: la pone fn_pie_columna_imagen
        UPDATE ecommerce.pie_columnas
           SET titulo = v_titulo,
               activo = COALESCE(p_activo, true),
               imagen_alt = v_alt,
               imagen_enlace = v_enlace,
               imagen_nueva_pestana = ecommerce.fn_nueva_pestana(v_enlace, p_imagen_nueva_pestana)
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

-- ----------------------------------------------------------------------------
-- 3. EL FICHERO, POR SU PROPIA PUERTA
-- ----------------------------------------------------------------------------
-- Devuelve el fichero ANTERIOR para que PHP sepa cuál borrar del disco, igual
-- que la imagen de una sección del inicio.
CREATE OR REPLACE FUNCTION ecommerce.fn_pie_columna_imagen(
    p_id             bigint,
    p_archivo        character varying,
    p_usuario_id     bigint            DEFAULT NULL,
    p_usuario_login  character varying DEFAULT NULL,
    p_usuario_nombre character varying DEFAULT NULL,
    p_ip_address     inet              DEFAULT NULL,
    p_user_agent     text              DEFAULT NULL,
    p_request_id     uuid              DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'ecommerce', 'auditoria'
AS $function$
DECLARE
    v_anterior text;
    v_nuevo    text;
BEGIN
    PERFORM ecommerce.fn_contexto_auditoria('ecommerce.pie_columnas',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    v_nuevo := ecommerce.fn_validar_fichero_imagen(p_archivo, 'La imagen de la columna', false);

    SELECT imagen INTO v_anterior
      FROM ecommerce.pie_columnas WHERE id = p_id AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'La columna no existe' USING ERRCODE = 'P0013';
    END IF;

    UPDATE ecommerce.pie_columnas SET imagen = v_nuevo WHERE id = p_id;

    RETURN jsonb_build_object('success', true,
        'message', CASE WHEN v_nuevo IS NULL THEN 'Imagen quitada' ELSE 'Imagen guardada' END,
        'data', (ecommerce.fn_pie_obtener() -> 'data') || jsonb_build_object('anterior', v_anterior));
END;
$function$;

-- ----------------------------------------------------------------------------
-- 4. LEER: EL CRM
-- ----------------------------------------------------------------------------
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
                           -- La imagen de la columna. Llega siempre, también vacía: la
                           -- pantalla necesita ver el texto y el enlace aunque todavía
                           -- no se haya subido el fichero
                           'imagen', jsonb_build_object(
                               'archivo',       c.imagen,
                               'alt',           c.imagen_alt,
                               'enlace',        c.imagen_enlace,
                               'nueva_pestana', c.imagen_nueva_pestana),
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

-- ----------------------------------------------------------------------------
-- 5. LEER: LA TIENDA
-- ----------------------------------------------------------------------------
-- Cirugía sobre el grupo del pie: lo demás de fn_secciones_publicas no cambia.
DO $publico$
DECLARE
    def   text;
    ancla text := E'                SELECT jsonb_agg(jsonb_build_object(\n                           ''titulo'', c.titulo,';
BEGIN
    SELECT pg_get_functiondef(p.oid) INTO def
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'ecommerce' AND p.proname = 'fn_secciones_publicas';

    IF def IS NULL THEN
        RAISE EXCEPTION 'No está ecommerce.fn_secciones_publicas';
    END IF;

    IF strpos(def, 'c.imagen') > 0 THEN
        RAISE NOTICE 'La tienda ya recibía la imagen de las columnas: no la toco.';
        RETURN;
    END IF;

    IF strpos(def, ancla) = 0 THEN
        RAISE EXCEPTION 'No encontré las columnas del pie: ¿cambió fn_secciones_publicas?';
    END IF;

    -- SIN FICHERO NO HAY IMAGEN: así la tienda no tiene que mirar dos cosas
    -- para saber si pinta la lista de enlaces o el dibujo
    def := replace(def, ancla, ancla
        || E'\n                           ''imagen'', CASE WHEN nullif(btrim(COALESCE(c.imagen, '''')), '''') IS NOT NULL'
        || E'\n                                          THEN jsonb_build_object('
        || E'\n                                              ''archivo'',       c.imagen,'
        || E'\n                                              ''alt'',           c.imagen_alt,'
        || E'\n                                              ''enlace'',        c.imagen_enlace,'
        || E'\n                                              ''nueva_pestana'', c.imagen_nueva_pestana)'
        || E'\n                                     END,');

    EXECUTE def;
    RAISE NOTICE 'La tienda ya recibe la imagen de las columnas del pie.';
END
$publico$;

-- ----------------------------------------------------------------------------
-- 6. COMPROBACIÓN
-- ----------------------------------------------------------------------------
DO $comprobar$
DECLARE
    v_id      bigint;
    v_crm     jsonb;
    v_tienda  jsonb;
    v_sin     jsonb;
    v_quitada jsonb;
    v_malo    text := NULL;
BEGIN
    BEGIN
        v_id := (ecommerce.fn_pie_columnas_guardar(NULL, 'ZZ prueba', true,
                    'Medios de pago', 'https://almacenesespana.com.ec/pagos', true)
                 -> 'data' -> 'columnas' -> -1 ->> 'id')::bigint;

        -- Sin fichero todavía: el texto y el enlace sí se guardan
        SELECT x INTO v_sin
          FROM jsonb_array_elements(ecommerce.fn_pie_obtener() -> 'data' -> 'columnas') x
         WHERE (x ->> 'id')::bigint = v_id;

        PERFORM ecommerce.fn_pie_columna_imagen(v_id, 'zzpruebaclaude.png');

        SELECT x INTO v_crm
          FROM jsonb_array_elements(ecommerce.fn_pie_obtener() -> 'data' -> 'columnas') x
         WHERE (x ->> 'id')::bigint = v_id;

        SELECT g INTO v_tienda
          FROM jsonb_array_elements(ecommerce.fn_secciones_publicas()) s,
               jsonb_array_elements(s -> 'grupos') g
         WHERE s ->> 'clave' = 'footer' AND g ->> 'titulo' = 'ZZ prueba';

        -- Quitarla dice qué fichero hay que borrar del disco
        v_quitada := ecommerce.fn_pie_columna_imagen(v_id, NULL);

        -- Un «javascript:» no entra como enlace de la imagen
        BEGIN
            PERFORM ecommerce.fn_pie_columnas_guardar(v_id, 'ZZ prueba', true, NULL, 'javascript:alert(1)', NULL);
            v_malo := 'entró un javascript: como enlace de la imagen';
        EXCEPTION WHEN SQLSTATE 'P0015' THEN
            NULL;
        END;

        RAISE EXCEPTION 'deshacer' USING ERRCODE = 'P0099';
    EXCEPTION WHEN SQLSTATE 'P0099' THEN
        NULL;
    END;

    IF v_sin -> 'imagen' ->> 'archivo' IS NOT NULL THEN
        RAISE EXCEPTION 'Recién creada no puede tener fichero: %', v_sin -> 'imagen';
    END IF;
    IF v_sin -> 'imagen' ->> 'alt' <> 'Medios de pago' THEN
        RAISE EXCEPTION 'El texto de la imagen se guarda aunque no haya fichero: %', v_sin -> 'imagen';
    END IF;
    IF v_crm -> 'imagen' ->> 'archivo' <> 'zzpruebaclaude.png' THEN
        RAISE EXCEPTION 'El fichero no se guardó: %', v_crm -> 'imagen';
    END IF;
    IF (v_crm -> 'imagen' ->> 'nueva_pestana')::boolean IS NOT TRUE THEN
        RAISE EXCEPTION 'Un enlace de fuera tendría que abrir pestaña: %', v_crm -> 'imagen';
    END IF;
    IF v_tienda IS NULL OR v_tienda -> 'imagen' ->> 'archivo' <> 'zzpruebaclaude.png' THEN
        RAISE EXCEPTION 'La tienda no recibe la imagen: %', v_tienda;
    END IF;
    IF v_quitada -> 'data' ->> 'anterior' <> 'zzpruebaclaude.png' THEN
        RAISE EXCEPTION 'Al quitarla hay que saber qué fichero borrar: %', v_quitada -> 'data' -> 'anterior';
    END IF;
    IF v_malo IS NOT NULL THEN
        RAISE EXCEPTION '%', v_malo;
    END IF;
    IF EXISTS (SELECT 1 FROM ecommerce.pie_columnas WHERE titulo = 'ZZ prueba') THEN
        RAISE EXCEPTION 'La columna de prueba se quedó en el pie';
    END IF;

    RAISE NOTICE 'Comprobado: la columna guarda el texto y el enlace de su imagen sin fichero, el fichero entra por su puerta, la tienda lo recibe, al quitarlo se sabe qué borrar y un «javascript:» no entra. No quedó nada.';
END
$comprobar$;

COMMIT;
