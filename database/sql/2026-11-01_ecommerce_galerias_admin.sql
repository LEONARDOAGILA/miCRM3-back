-- ============================================================================
-- ECOMMERCE · ADMINISTRAR LAS GALERÍAS
-- ============================================================================
-- Fecha: 2026-11-01
--
-- Una galería es un SITIO del diseño con su clave fija —`inicio_banner`,
-- `pagos_tarjetas`, `espana_motos_tarjetas`— y lo que se administra son las
-- imágenes que van ahí: cuáles, en qué orden, a dónde llevan y entre qué
-- fechas se ven.
--
-- LAS GALERÍAS NO SE CREAN NI SE BORRAN DESDE EL CRM, igual que las secciones
-- de la portada: cada una existe porque la tienda sabe pintarla, y una clave
-- nueva sin código que la pinte sería un hueco que no aparece en ninguna
-- parte. Lo que se administra es su contenido.
--
-- EL FICHERO NO SE SUBE AQUÍ. Se elige de la biblioteca compartida
-- (ecommerce/imagen), y en la base se guarda SÓLO EL NOMBRE: la dirección la
-- arma el controlador al leer, así que mover el CRM de máquina no obliga a
-- repasar la base. Por eso se comprueba que lo que llega sea un nombre de
-- fichero y no una dirección entera.
--
-- LA PAPELERA ES POR GALERÍA. Borrar una imagen no pierde el fichero —sigue
-- en la biblioteca— pero sí el trabajo que lleva encima: su enlace, sus
-- títulos, su vigencia y su sitio en el orden. Eso es lo que se recupera.
--
-- Idempotente.
-- ============================================================================
\set ON_ERROR_STOP on

BEGIN;

-- ----------------------------------------------------------------------------
-- 1. LO QUE VE LA PANTALLA
-- ----------------------------------------------------------------------------
-- La galería con TODAS sus imágenes, también las apagadas y las que están
-- fuera de fecha: lo que administra marketing es justo eso, y verlas con su
-- estado es lo que distingue «se me olvidó encenderla» de «ya terminó».
CREATE OR REPLACE FUNCTION ecommerce.fn_galerias_json(p_galeria_id bigint)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
AS $function$
    SELECT jsonb_build_object(
        'id',          g.id,
        'clave',       g.clave,
        'nombre',      g.nombre,
        'descripcion', g.descripcion,
        'tipo',        g.tipo,
        -- Cuántas enseña la tienda de las que hay; null = todas
        'mostrar',     g.mostrar,
        'maximo',      g.maximo,
        'en_papelera', (SELECT count(*) FROM ecommerce.galerias_imagenes b
                         WHERE b.galeria_id = g.id AND b.deleted_at IS NOT NULL),
        'imagenes', COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
                       'id',            i.id,
                       'imagen',        i.imagen,
                       'imagen_movil',  i.imagen_movil,
                       'nombre',        i.nombre,
                       'enlace',        i.enlace,
                       'nueva_pestana', i.nueva_pestana,
                       'mostrar_en',    i.mostrar_en,
                       'titulo',        i.titulo,
                       'subtitulo',     i.subtitulo,
                       'color',         i.color,
                       'boton',         i.boton,
                       'desde',         to_char(i.desde, 'YYYY-MM-DD"T"HH24:MI'),
                       'hasta',         to_char(i.hasta, 'YYYY-MM-DD"T"HH24:MI'),
                       'orden',         i.orden,
                       'activo',        i.activo,
                       'estado',        CASE
                           WHEN NOT i.activo THEN 'oculta'
                           WHEN i.desde IS NOT NULL AND CURRENT_TIMESTAMP < i.desde THEN 'programada'
                           WHEN i.hasta IS NOT NULL AND CURRENT_TIMESTAMP > i.hasta THEN 'terminada'
                           ELSE 'visible' END)
                   ORDER BY i.orden, i.id)
              FROM ecommerce.galerias_imagenes i
             WHERE i.galeria_id = g.id AND i.deleted_at IS NULL), '[]'::jsonb))
      FROM ecommerce.galerias g
     WHERE g.id = p_galeria_id;
$function$;

-- Una galería por su clave. Da P0013 si la clave no existe, que no es lo
-- mismo que una galería que existe y está vacía.
CREATE OR REPLACE FUNCTION ecommerce.fn_galerias_obtener(p_clave text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'ecommerce', 'auditoria'
AS $function$
DECLARE
    v_id bigint;
BEGIN
    SELECT id INTO v_id FROM ecommerce.galerias WHERE clave = btrim(COALESCE(p_clave, ''));
    IF v_id IS NULL THEN
        RAISE EXCEPTION 'La galería «%» no existe', p_clave USING ERRCODE = 'P0013';
    END IF;

    RETURN jsonb_build_object('success', true, 'message', 'Galería',
                              'data', ecommerce.fn_galerias_json(v_id));
END;
$function$;

-- Todas, con su cuenta. Para la pantalla de galerías, cuando la haya.
CREATE OR REPLACE FUNCTION ecommerce.fn_galerias_listar()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
AS $function$
    SELECT jsonb_build_object('success', true, 'message', 'Galerías',
        'data', COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
                       'id', g.id, 'clave', g.clave, 'nombre', g.nombre,
                       'descripcion', g.descripcion, 'tipo', g.tipo,
                       'mostrar', g.mostrar, 'maximo', g.maximo,
                       'cuantas', (SELECT count(*) FROM ecommerce.galerias_imagenes i
                                    WHERE i.galeria_id = g.id AND i.deleted_at IS NULL),
                       'visibles', (SELECT count(*) FROM ecommerce.galerias_imagenes i
                                     WHERE i.galeria_id = g.id AND i.deleted_at IS NULL
                                       AND i.activo AND ecommerce.fn_vigente(i.desde, i.hasta)))
                   ORDER BY g.clave)
              FROM ecommerce.galerias g), '[]'::jsonb));
$function$;

-- ----------------------------------------------------------------------------
-- 2. UN NOMBRE DE FICHERO, NO UNA DIRECCIÓN
-- ----------------------------------------------------------------------------
-- En la base va sólo el nombre. Si entrara una dirección entera, el día que
-- el CRM cambie de máquina las imágenes dejarían de salir y habría que
-- repasar la base fila a fila. Mejor que no entre.
CREATE OR REPLACE FUNCTION ecommerce.fn_validar_fichero_imagen(p_valor text, p_etiqueta text,
                                                               p_obligatorio boolean DEFAULT false)
 RETURNS text
 LANGUAGE plpgsql
 IMMUTABLE
AS $function$
DECLARE
    v text := btrim(COALESCE(p_valor, ''));
BEGIN
    IF v = '' THEN
        IF p_obligatorio THEN
            RAISE EXCEPTION '%: hace falta elegir la imagen', p_etiqueta USING ERRCODE = 'P0001';
        END IF;
        RETURN NULL;
    END IF;

    IF v !~ '^[A-Za-z0-9][A-Za-z0-9._-]{0,196}\.(jpg|jpeg|png|webp|gif)$' THEN
        RAISE EXCEPTION '%: tiene que ser un fichero de la biblioteca (jpg, png, webp o gif)', p_etiqueta
              USING ERRCODE = 'P0015';
    END IF;

    RETURN v;
END;
$function$;

-- ----------------------------------------------------------------------------
-- 3. GUARDAR UNA IMAGEN
-- ----------------------------------------------------------------------------
-- Sin id crea, con id modifica. Devuelve la galería entera, como el resto del
-- módulo: crear una cambia el orden de las demás, y recomponerlo en la
-- pantalla acabaría enseñando algo distinto de lo que ve la tienda.
CREATE OR REPLACE FUNCTION ecommerce.fn_galerias_imagenes_guardar(
    p_id bigint, p_clave text, p_datos jsonb,
    p_usuario_id bigint DEFAULT NULL, p_usuario_login character varying DEFAULT NULL,
    p_usuario_nombre character varying DEFAULT NULL, p_ip_address inet DEFAULT NULL,
    p_user_agent text DEFAULT NULL, p_request_id uuid DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'ecommerce', 'auditoria'
AS $function$
DECLARE
    v_galeria   record;
    v_imagen    text;
    v_movil     text;
    v_enlace    text;
    v_mostrar   text;
    v_color     text;
    v_desde     timestamptz;
    v_hasta     timestamptz;
    v_cuantas   integer;
    v_orden     integer;
    v_nuevo     boolean := p_id IS NULL;
BEGIN
    PERFORM ecommerce.fn_contexto_auditoria('ecommerce.galerias_imagenes',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    SELECT * INTO v_galeria FROM ecommerce.galerias WHERE clave = btrim(COALESCE(p_clave, ''));
    IF NOT FOUND THEN
        RAISE EXCEPTION 'La galería «%» no existe', p_clave USING ERRCODE = 'P0013';
    END IF;

    IF NOT v_nuevo AND NOT EXISTS (SELECT 1 FROM ecommerce.galerias_imagenes
                                    WHERE id = p_id AND galeria_id = v_galeria.id
                                      AND deleted_at IS NULL) THEN
        RAISE EXCEPTION 'La imagen no existe en esta galería' USING ERRCODE = 'P0013';
    END IF;

    v_imagen := ecommerce.fn_validar_fichero_imagen(p_datos ->> 'imagen', 'La imagen', true);
    v_movil  := ecommerce.fn_validar_fichero_imagen(p_datos ->> 'imagen_movil', 'La imagen para el celular');
    v_enlace := ecommerce.fn_validar_enlace(p_datos ->> 'enlace', 'El enlace');

    -- `mostrar_en` dice en qué pantalla sale. Un valor que la tienda no
    -- conoce la dejaría sin pintar y sin decir por qué.
    v_mostrar := lower(btrim(COALESCE(p_datos ->> 'mostrar_en', 'todos')));
    IF v_mostrar NOT IN ('todos', 'computadora', 'celular') THEN
        RAISE EXCEPTION 'Dónde se ve: sólo vale «todos», «computadora» o «celular»' USING ERRCODE = 'P0015';
    END IF;

    v_color := nullif(btrim(COALESCE(p_datos ->> 'color', '')), '');
    IF v_color IS NOT NULL AND v_color !~ '^#[0-9A-Fa-f]{6}$' THEN
        RAISE EXCEPTION 'El color tiene que ser un código como #1a73e8' USING ERRCODE = 'P0015';
    END IF;

    v_desde := nullif(btrim(COALESCE(p_datos ->> 'desde', '')), '')::timestamptz;
    v_hasta := nullif(btrim(COALESCE(p_datos ->> 'hasta', '')), '')::timestamptz;
    IF v_desde IS NOT NULL AND v_hasta IS NOT NULL AND v_hasta < v_desde THEN
        RAISE EXCEPTION 'Las fechas van al revés: «hasta» es anterior a «desde»' USING ERRCODE = 'P0015';
    END IF;

    IF v_nuevo THEN
        -- El tope es del diseño: la tienda enseña ese sitio con un número de
        -- huecos, y pasarse no añade nada, sólo deja imágenes que no salen.
        SELECT count(*) INTO v_cuantas FROM ecommerce.galerias_imagenes
         WHERE galeria_id = v_galeria.id AND deleted_at IS NULL;

        IF v_galeria.maximo IS NOT NULL AND v_cuantas >= v_galeria.maximo THEN
            RAISE EXCEPTION '«%» admite % imágenes y ya están puestas: quita una antes de añadir otra',
                  v_galeria.nombre, v_galeria.maximo USING ERRCODE = 'P0021';
        END IF;

        SELECT COALESCE(max(orden), 0) + 1 INTO v_orden FROM ecommerce.galerias_imagenes
         WHERE galeria_id = v_galeria.id AND deleted_at IS NULL;

        INSERT INTO ecommerce.galerias_imagenes (
            galeria_id, imagen, imagen_movil, nombre, enlace, nueva_pestana, mostrar_en,
            titulo, subtitulo, color, boton, desde, hasta, orden, activo)
        VALUES (
            v_galeria.id, v_imagen, v_movil,
            ecommerce.fn_validar_texto(p_datos ->> 'nombre', 'El nombre', 100),
            v_enlace,
            ecommerce.fn_nueva_pestana(v_enlace, (p_datos ->> 'nueva_pestana')::boolean),
            v_mostrar,
            ecommerce.fn_validar_texto(p_datos ->> 'titulo', 'El título', 40),
            ecommerce.fn_validar_texto(p_datos ->> 'subtitulo', 'El subtítulo', 80),
            v_color,
            ecommerce.fn_validar_texto(p_datos ->> 'boton', 'El texto del botón', 20),
            v_desde, v_hasta, v_orden,
            COALESCE((p_datos ->> 'activo')::boolean, true))
        RETURNING id INTO p_id;
    ELSE
        UPDATE ecommerce.galerias_imagenes
           SET imagen        = v_imagen,
               imagen_movil  = v_movil,
               nombre        = ecommerce.fn_validar_texto(p_datos ->> 'nombre', 'El nombre', 100),
               enlace        = v_enlace,
               nueva_pestana = ecommerce.fn_nueva_pestana(v_enlace, (p_datos ->> 'nueva_pestana')::boolean),
               mostrar_en    = v_mostrar,
               titulo        = ecommerce.fn_validar_texto(p_datos ->> 'titulo', 'El título', 40),
               subtitulo     = ecommerce.fn_validar_texto(p_datos ->> 'subtitulo', 'El subtítulo', 80),
               color         = v_color,
               boton         = ecommerce.fn_validar_texto(p_datos ->> 'boton', 'El texto del botón', 20),
               desde         = v_desde,
               hasta         = v_hasta,
               activo        = COALESCE((p_datos ->> 'activo')::boolean, true)
         WHERE id = p_id;
    END IF;

    RETURN jsonb_build_object('success', true,
        'message', CASE WHEN v_nuevo THEN 'Imagen añadida' ELSE 'Imagen guardada' END,
        'data', ecommerce.fn_galerias_json(v_galeria.id));
END;
$function$;

-- ----------------------------------------------------------------------------
-- 4. ENCENDERLA, APAGARLA, ORDENARLAS, BORRARLA
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ecommerce.fn_galerias_imagenes_activar(
    p_id bigint, p_activo boolean,
    p_usuario_id bigint DEFAULT NULL, p_usuario_login character varying DEFAULT NULL,
    p_usuario_nombre character varying DEFAULT NULL, p_ip_address inet DEFAULT NULL,
    p_user_agent text DEFAULT NULL, p_request_id uuid DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'ecommerce', 'auditoria'
AS $function$
DECLARE
    v_galeria bigint;
    v_nuevo   boolean;
BEGIN
    PERFORM ecommerce.fn_contexto_auditoria('ecommerce.galerias_imagenes',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    SELECT galeria_id, COALESCE(p_activo, NOT activo) INTO v_galeria, v_nuevo
      FROM ecommerce.galerias_imagenes WHERE id = p_id AND deleted_at IS NULL;
    IF v_galeria IS NULL THEN
        RAISE EXCEPTION 'La imagen no existe' USING ERRCODE = 'P0013';
    END IF;

    UPDATE ecommerce.galerias_imagenes SET activo = v_nuevo WHERE id = p_id;

    RETURN jsonb_build_object('success', true,
        'message', CASE WHEN v_nuevo THEN 'Imagen encendida' ELSE 'Imagen apagada' END,
        'data', ecommerce.fn_galerias_json(v_galeria));
END;
$function$;

-- El orden llega entero, como se ve en la pantalla: mandar «la 3 ahora es la
-- 1» obligaría a recalcular aquí lo que allí ya está resuelto.
CREATE OR REPLACE FUNCTION ecommerce.fn_galerias_imagenes_ordenar(
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
    v_galeria  bigint;
    v_cuantas  integer;
    v_recibido integer;
BEGIN
    PERFORM ecommerce.fn_contexto_auditoria('ecommerce.galerias_imagenes',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    IF p_ids IS NULL OR jsonb_typeof(p_ids) <> 'array' OR jsonb_array_length(p_ids) = 0 THEN
        RAISE EXCEPTION 'Hace falta el orden de las imágenes' USING ERRCODE = 'P0001';
    END IF;

    SELECT count(DISTINCT i.galeria_id), count(*) INTO v_cuantas, v_recibido
      FROM ecommerce.galerias_imagenes i
     WHERE i.id IN (SELECT (x)::bigint FROM jsonb_array_elements_text(p_ids) x)
       AND i.deleted_at IS NULL;

    -- Todas tienen que ser de la MISMA galería: un orden que mezcle dos
    -- galerías dejaría las dos con huecos y repetidos
    IF v_cuantas <> 1 OR v_recibido <> jsonb_array_length(p_ids) THEN
        RAISE EXCEPTION 'El orden no corresponde a una sola galería' USING ERRCODE = 'P0016';
    END IF;

    SELECT DISTINCT galeria_id INTO v_galeria FROM ecommerce.galerias_imagenes
     WHERE id IN (SELECT (x)::bigint FROM jsonb_array_elements_text(p_ids) x);

    UPDATE ecommerce.galerias_imagenes i
       SET orden = n.pos
      FROM (SELECT (x.valor)::bigint AS id, x.pos
              FROM jsonb_array_elements_text(p_ids) WITH ORDINALITY AS x(valor, pos)) n
     WHERE i.id = n.id;

    RETURN jsonb_build_object('success', true, 'message', 'Orden guardado',
                              'data', ecommerce.fn_galerias_json(v_galeria));
END;
$function$;

-- A la papelera. El fichero NO se toca: sigue en la biblioteca, y lo que se
-- recupera al restaurarla es su enlace, sus títulos y su vigencia.
CREATE OR REPLACE FUNCTION ecommerce.fn_galerias_imagenes_eliminar(
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
    v_galeria bigint;
BEGIN
    PERFORM ecommerce.fn_contexto_auditoria('ecommerce.galerias_imagenes',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    SELECT galeria_id INTO v_galeria FROM ecommerce.galerias_imagenes
     WHERE id = p_id AND deleted_at IS NULL;
    IF v_galeria IS NULL THEN
        RAISE EXCEPTION 'La imagen no existe' USING ERRCODE = 'P0013';
    END IF;

    UPDATE ecommerce.galerias_imagenes
       SET deleted_at = CURRENT_TIMESTAMP,
           deleted_by = COALESCE(current_setting('app.usuario_login', true), current_user)
     WHERE id = p_id;

    RETURN jsonb_build_object('success', true, 'message', 'Imagen quitada de la galería',
                              'data', ecommerce.fn_galerias_json(v_galeria));
END;
$function$;

-- ----------------------------------------------------------------------------
-- 5. LA PAPELERA, POR GALERÍA
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ecommerce.fn_galerias_papelera_listar(p_clave text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'ecommerce', 'auditoria'
AS $function$
DECLARE
    v_id bigint;
BEGIN
    SELECT id INTO v_id FROM ecommerce.galerias WHERE clave = btrim(COALESCE(p_clave, ''));
    IF v_id IS NULL THEN
        RAISE EXCEPTION 'La galería «%» no existe', p_clave USING ERRCODE = 'P0013';
    END IF;

    RETURN jsonb_build_object('success', true, 'message', 'Papelera de la galería',
        'data', COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
                       'id', i.id, 'imagen', i.imagen, 'nombre', i.nombre,
                       'titulo', i.titulo, 'enlace', i.enlace,
                       'deleted_at', to_char(i.deleted_at, 'YYYY-MM-DD HH24:MI'),
                       'deleted_by', i.deleted_by)
                   ORDER BY i.deleted_at DESC)
              FROM ecommerce.galerias_imagenes i
             WHERE i.galeria_id = v_id AND i.deleted_at IS NOT NULL), '[]'::jsonb));
END;
$function$;

CREATE OR REPLACE FUNCTION ecommerce.fn_galerias_papelera_restaurar(
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
    v_galeria bigint;
    v_cuantas integer;
    v_tope    integer;
    v_vivas   integer;
    v_pedidas integer;
BEGIN
    PERFORM ecommerce.fn_contexto_auditoria('ecommerce.galerias_imagenes',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    IF p_ids IS NULL OR jsonb_typeof(p_ids) <> 'array' OR jsonb_array_length(p_ids) = 0 THEN
        RAISE EXCEPTION 'Hace falta decir qué imágenes restaurar' USING ERRCODE = 'P0001';
    END IF;
    v_pedidas := jsonb_array_length(p_ids);

    SELECT count(DISTINCT i.galeria_id), count(*) INTO v_cuantas, v_vivas
      FROM ecommerce.galerias_imagenes i
     WHERE i.id IN (SELECT (x)::bigint FROM jsonb_array_elements_text(p_ids) x)
       AND i.deleted_at IS NOT NULL;

    IF v_vivas <> v_pedidas THEN
        RAISE EXCEPTION 'Alguna de esas imágenes no está en la papelera' USING ERRCODE = 'P0019';
    END IF;
    IF v_cuantas <> 1 THEN
        RAISE EXCEPTION 'Las imágenes tienen que ser de una sola galería' USING ERRCODE = 'P0016';
    END IF;

    SELECT DISTINCT galeria_id INTO v_galeria FROM ecommerce.galerias_imagenes
     WHERE id IN (SELECT (x)::bigint FROM jsonb_array_elements_text(p_ids) x);

    -- Restaurar también cuenta para el tope: si no, se saltaría por la puerta
    -- de atrás lo que la de delante no deja
    SELECT g.maximo INTO v_tope FROM ecommerce.galerias g WHERE g.id = v_galeria;
    SELECT count(*) INTO v_vivas FROM ecommerce.galerias_imagenes
     WHERE galeria_id = v_galeria AND deleted_at IS NULL;

    IF v_tope IS NOT NULL AND v_vivas + v_pedidas > v_tope THEN
        RAISE EXCEPTION 'No caben: la galería admite % imágenes y ya hay %', v_tope, v_vivas
              USING ERRCODE = 'P0021';
    END IF;

    UPDATE ecommerce.galerias_imagenes
       SET deleted_at = NULL, deleted_by = NULL,
           -- Vuelve al final: su sitio de antes ya lo ocupa otra
           orden = (SELECT COALESCE(max(x.orden), 0) FROM ecommerce.galerias_imagenes x
                     WHERE x.galeria_id = v_galeria AND x.deleted_at IS NULL) + 1
     WHERE id IN (SELECT (x)::bigint FROM jsonb_array_elements_text(p_ids) x);

    RETURN jsonb_build_object('success', true,
        'message', format('%s imagen(es) restaurada(s)', v_pedidas),
        'data', ecommerce.fn_galerias_json(v_galeria));
END;
$function$;

CREATE OR REPLACE FUNCTION ecommerce.fn_galerias_papelera_vaciar(
    p_clave text,
    p_usuario_id bigint DEFAULT NULL, p_usuario_login character varying DEFAULT NULL,
    p_usuario_nombre character varying DEFAULT NULL, p_ip_address inet DEFAULT NULL,
    p_user_agent text DEFAULT NULL, p_request_id uuid DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'ecommerce', 'auditoria'
AS $function$
DECLARE
    v_id      bigint;
    v_cuantas integer;
BEGIN
    PERFORM ecommerce.fn_contexto_auditoria('ecommerce.galerias_imagenes',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    SELECT id INTO v_id FROM ecommerce.galerias WHERE clave = btrim(COALESCE(p_clave, ''));
    IF v_id IS NULL THEN
        RAISE EXCEPTION 'La galería «%» no existe', p_clave USING ERRCODE = 'P0013';
    END IF;

    -- VACÍA LA DE ESTA GALERÍA Y NADA MÁS. El fichero no se toca: sigue en la
    -- biblioteca, lo que se pierde es su configuración.
    DELETE FROM ecommerce.galerias_imagenes
     WHERE galeria_id = v_id AND deleted_at IS NOT NULL;
    GET DIAGNOSTICS v_cuantas = ROW_COUNT;

    RETURN jsonb_build_object('success', true,
        'message', format('Papelera vaciada: %s imagen(es)', v_cuantas),
        'data', ecommerce.fn_galerias_json(v_id));
END;
$function$;

-- ----------------------------------------------------------------------------
-- 6. QUE HAGA LO QUE DICE
-- ----------------------------------------------------------------------------
-- Se monta una imagen de prueba en una galería de verdad y se deshace. Todo
-- se cuenta sin condiciones, para que un NULL no deje pasar la prueba en
-- verde.
DO $comprobar$
DECLARE
    v_clave    text := 'inicio_banner';
    v_fichero  text;
    v_datos    jsonb;
    v_id       bigint;
    v_antes    integer;
    v_despues  integer;
    v_estado   text;
    v_fallo    text;
BEGIN
    SELECT count(*) INTO v_antes FROM ecommerce.galerias_imagenes i
      JOIN ecommerce.galerias g ON g.id = i.galeria_id
     WHERE g.clave = v_clave AND i.deleted_at IS NULL;

    SELECT i.imagen INTO v_fichero FROM ecommerce.galerias_imagenes i
      JOIN ecommerce.galerias g ON g.id = i.galeria_id
     WHERE g.clave = v_clave AND i.deleted_at IS NULL LIMIT 1;

    IF v_fichero IS NULL THEN
        RAISE EXCEPTION 'No hay ninguna imagen de la que copiar el fichero para la prueba';
    END IF;

    -- Una dirección entera no entra
    v_fallo := NULL;
    BEGIN
        PERFORM ecommerce.fn_galerias_imagenes_guardar(NULL, v_clave,
            jsonb_build_object('imagen', 'http://192.168.2.173:8009/ecommerce/publico/imagenes/x.png'));
    EXCEPTION WHEN SQLSTATE 'P0015' THEN v_fallo := 'bien';
    END;
    IF v_fallo IS NULL THEN
        RAISE EXCEPTION 'Se tragó una dirección entera donde va el nombre del fichero';
    END IF;

    -- Un enlace inventado tampoco
    v_fallo := NULL;
    BEGIN
        PERFORM ecommerce.fn_galerias_imagenes_guardar(NULL, v_clave,
            jsonb_build_object('imagen', v_fichero, 'enlace', 'vete a saber'));
    EXCEPTION WHEN SQLSTATE 'P0015' THEN v_fallo := 'bien';
    END;
    IF v_fallo IS NULL THEN
        RAISE EXCEPTION 'Se tragó un enlace que no vale';
    END IF;

    -- Y una de verdad sí
    v_datos := ecommerce.fn_galerias_imagenes_guardar(NULL, v_clave,
        jsonb_build_object('imagen', v_fichero, 'nombre', 'ZZ prueba',
                           'enlace', '/shop', 'nueva_pestana', true,
                           'desde', to_char(CURRENT_TIMESTAMP + interval '2 days', 'YYYY-MM-DD HH24:MI'))) -> 'data';

    SELECT (i ->> 'id')::bigint, i ->> 'estado' INTO v_id, v_estado
      FROM jsonb_array_elements(v_datos -> 'imagenes') i
     WHERE i ->> 'nombre' = 'ZZ prueba';

    IF v_id IS NULL THEN
        RAISE EXCEPTION 'No se creó la imagen';
    END IF;
    IF v_estado IS DISTINCT FROM 'programada' THEN
        RAISE EXCEPTION 'Una imagen con fecha futura debería salir «programada», no «%»', COALESCE(v_estado, 'nada');
    END IF;

    -- `nueva_pestana` sólo vale para enlaces de fuera: a /shop se va en la misma
    IF (SELECT nueva_pestana FROM ecommerce.galerias_imagenes WHERE id = v_id) THEN
        RAISE EXCEPTION 'Una ruta propia no debería abrirse en otra pestaña';
    END IF;

    -- A la papelera y de vuelta
    PERFORM ecommerce.fn_galerias_imagenes_eliminar(v_id);
    IF EXISTS (SELECT 1 FROM jsonb_array_elements(ecommerce.fn_galerias_obtener(v_clave) -> 'data' -> 'imagenes') i
                WHERE (i ->> 'id')::bigint = v_id) THEN
        RAISE EXCEPTION 'La imagen borrada sigue saliendo en la galería';
    END IF;

    PERFORM ecommerce.fn_galerias_papelera_restaurar(jsonb_build_array(v_id));
    IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(ecommerce.fn_galerias_obtener(v_clave) -> 'data' -> 'imagenes') i
                    WHERE (i ->> 'id')::bigint = v_id) THEN
        RAISE EXCEPTION 'La imagen restaurada no volvió';
    END IF;

    -- Y fuera del todo, que la galería quede como estaba
    PERFORM ecommerce.fn_galerias_imagenes_eliminar(v_id);
    DELETE FROM ecommerce.galerias_imagenes WHERE id = v_id;

    SELECT count(*) INTO v_despues FROM ecommerce.galerias_imagenes i
      JOIN ecommerce.galerias g ON g.id = i.galeria_id
     WHERE g.clave = v_clave AND i.deleted_at IS NULL;

    IF v_despues IS DISTINCT FROM v_antes THEN
        RAISE EXCEPTION 'La prueba dejó la galería con % imágenes y tenía %', v_despues, v_antes;
    END IF;

    RAISE NOTICE 'Comprobado: valida el fichero y el enlace, programa, borra, restaura, y deja % imágenes.', v_despues;
END
$comprobar$;

COMMIT;
