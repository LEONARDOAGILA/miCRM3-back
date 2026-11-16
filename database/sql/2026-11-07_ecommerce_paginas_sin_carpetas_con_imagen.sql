-- ============================================================================
-- PÁGINAS INFORMATIVAS: SE VAN LAS CARPETAS Y LA IMAGEN ELIGE LADO
-- ============================================================================
-- Fecha: 2026-11-07
--
-- DOS CAMBIOS, Y LOS DOS SE PIDIERON JUNTOS:
--
--  1. FUERA LAS CARPETAS. Esto es un CRUD de páginas y nada más. La carpeta
--     obligaba a mantener una pantalla con árbol, arrastre, papelera de dos
--     niveles y ocho funciones aquí dentro para agrupar diez páginas. En la
--     tienda, /documentos pasa a ser una sola lista de tarjetas: la respuesta
--     de `listar_publicas` conserva su forma —un arreglo de secciones— y
--     devuelve UNA sección sin nombre, que es el caso que esa pantalla ya
--     sabía pintar desde el principio.
--
--  2. LA IMAGEN DE LA PÁGINA ELIGE LADO. `contenido` gana `imagen_lado`
--     ('izquierda' o 'derecha'). No es una columna nueva: el contenido ya es
--     jsonb y la imagen ya vivía ahí; lo que hacía falta es que el validador
--     lo deje pasar, porque DEVUELVE EL OBJETO RECONSTRUIDO y lo que no
--     nombra se pierde sin avisar.
--
-- SE EJECUTA A MANO, como el resto de ficheros de esta carpeta, y se puede
-- repetir: lo que ya esté hecho no vuelve a hacerse.
--
--   psql -U postgres -d crm3 -f 2026-11-07_ecommerce_paginas_sin_carpetas_con_imagen.sql
--
-- OJO AL ORDEN: primero las funciones que dejan de mirar la carpeta, después
-- la columna y la tabla. Al revés, PostgreSQL se niega porque las funciones
-- que la nombran todavía existen.
-- ============================================================================

BEGIN;

-- ----------------------------------------------------------------------------
-- 1. EL CONTENIDO: LA IMAGEN Y DE QUÉ LADO VA
-- ----------------------------------------------------------------------------
-- Es el validador de siempre con `imagen_lado` añadido. Va entero y no un
-- ALTER: una función se reemplaza completa, y dejarla a medias no existe.
CREATE OR REPLACE FUNCTION ecommerce.fn_paginas_informativas_contenido_validar(p_contenido jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 IMMUTABLE
AS $function$
DECLARE
    v_texto        text;
    v_imagen       text;
    v_alt          text;
    v_lado         text;
    v_pdf          text;
    v_d            jsonb;
    v_titulo_d     text;
    v_texto_d      text;
    v_pdf_d        text;
    v_boton_d      text;
    v_desplegables jsonb := '[]'::jsonb;
    -- Sólo el NOMBRE del fichero: la dirección la arma el controlador
    c_imagen constant text := '^[A-Za-z0-9._-]+\.(jpg|jpeg|png|webp)$';
    c_pdf    constant text := '^[A-Za-z0-9._-]+\.pdf$';
    c_lado   constant text := '^(izquierda|derecha)$';
    c_malo   constant text := '<\s*/?\s*(script|iframe|object|embed|style|link|meta|form|input|button)\M';
BEGIN
    IF p_contenido IS NULL OR jsonb_typeof(p_contenido) <> 'object' THEN
        RAISE EXCEPTION 'El contenido de la página no tiene la forma esperada' USING ERRCODE = 'P0015';
    END IF;

    IF COALESCE(jsonb_typeof(p_contenido -> 'texto'), 'null')        NOT IN ('string', 'null')
       OR COALESCE(jsonb_typeof(p_contenido -> 'imagen'), 'null')      NOT IN ('string', 'null')
       OR COALESCE(jsonb_typeof(p_contenido -> 'imagen_alt'), 'null')  NOT IN ('string', 'null')
       OR COALESCE(jsonb_typeof(p_contenido -> 'imagen_lado'), 'null') NOT IN ('string', 'null')
       OR COALESCE(jsonb_typeof(p_contenido -> 'pdf'), 'null')         NOT IN ('string', 'null')
       OR COALESCE(jsonb_typeof(p_contenido -> 'desplegables'), 'null') NOT IN ('array', 'null') THEN
        RAISE EXCEPTION 'El contenido de la página no tiene la forma esperada' USING ERRCODE = 'P0015';
    END IF;

    v_texto := btrim(COALESCE(p_contenido ->> 'texto', ''));

    -- Vacío es no tener LETRAS: un <p>&nbsp;</p> del editor no es contenido
    IF btrim(replace(regexp_replace(v_texto, '<[^>]*>', '', 'g'), '&nbsp;', ' ')) = '' THEN
        RAISE EXCEPTION 'La página necesita texto' USING ERRCODE = 'P0001';
    END IF;
    IF length(v_texto) > 100000 THEN
        RAISE EXCEPTION 'El texto de la página es demasiado largo (el formato también ocupa)' USING ERRCODE = 'P0015';
    END IF;
    IF v_texto ~* c_malo OR v_texto ~* '<[^>]*\son[a-z]+\s*=' OR v_texto ~* '<[^>]*javascript\s*:' THEN
        RAISE EXCEPTION 'El texto trae etiquetas o atributos que no se permiten' USING ERRCODE = 'P0015';
    END IF;

    v_imagen := nullif(btrim(COALESCE(p_contenido ->> 'imagen', '')), '');
    IF v_imagen IS NOT NULL AND v_imagen !~ c_imagen THEN
        RAISE EXCEPTION 'La imagen debe ser un fichero subido (jpg, png o webp)' USING ERRCODE = 'P0015';
    END IF;

    -- El texto alternativo sólo tiene sentido con imagen
    v_alt := CASE WHEN v_imagen IS NULL THEN NULL
                  ELSE nullif(btrim(COALESCE(p_contenido ->> 'imagen_alt', '')), '') END;
    IF length(v_alt) > 150 THEN
        RAISE EXCEPTION 'El texto alternativo de la imagen no puede pasar de 150 caracteres' USING ERRCODE = 'P0015';
    END IF;

    -- DE QUÉ LADO VA LA IMAGEN. Sin imagen no hay lado que guardar. Con
    -- imagen y sin decir nada, a la derecha: se lee primero el texto, que es
    -- a lo que se entra, y la foto acompaña.
    IF v_imagen IS NULL THEN
        v_lado := NULL;
    ELSE
        v_lado := lower(btrim(COALESCE(p_contenido ->> 'imagen_lado', '')));
        IF v_lado = '' THEN
            v_lado := 'derecha';
        ELSIF v_lado !~ c_lado THEN
            RAISE EXCEPTION 'La imagen sólo puede ir a la izquierda o a la derecha' USING ERRCODE = 'P0015';
        END IF;
    END IF;

    v_pdf := nullif(btrim(COALESCE(p_contenido ->> 'pdf', '')), '');
    IF v_pdf IS NOT NULL AND v_pdf !~ c_pdf THEN
        RAISE EXCEPTION 'El documento debe ser un PDF subido' USING ERRCODE = 'P0015';
    END IF;

    IF jsonb_array_length(COALESCE(p_contenido -> 'desplegables', '[]'::jsonb)) > 6 THEN
        RAISE EXCEPTION 'No caben más de 6 desplegables en una página' USING ERRCODE = 'P0015';
    END IF;

    FOR v_d IN SELECT * FROM jsonb_array_elements(COALESCE(p_contenido -> 'desplegables', '[]'::jsonb)) LOOP
        IF jsonb_typeof(v_d) <> 'object' THEN
            RAISE EXCEPTION 'El contenido de la página no tiene la forma esperada' USING ERRCODE = 'P0015';
        END IF;

        v_titulo_d := btrim(COALESCE(v_d ->> 'titulo', ''));
        v_texto_d  := btrim(COALESCE(v_d ->> 'texto', ''));

        IF v_titulo_d = '' THEN
            RAISE EXCEPTION 'Cada desplegable necesita un título' USING ERRCODE = 'P0001';
        END IF;
        IF length(v_titulo_d) > 100 THEN
            RAISE EXCEPTION 'El título del desplegable no puede pasar de 100 caracteres' USING ERRCODE = 'P0015';
        END IF;
        IF btrim(replace(regexp_replace(v_texto_d, '<[^>]*>', '', 'g'), '&nbsp;', ' ')) = '' THEN
            RAISE EXCEPTION 'El desplegable «%» está sin texto', v_titulo_d USING ERRCODE = 'P0001';
        END IF;
        IF length(v_texto_d) > 20000 THEN
            RAISE EXCEPTION 'El texto del desplegable «%» es demasiado largo', v_titulo_d USING ERRCODE = 'P0015';
        END IF;
        IF v_texto_d ~* c_malo OR v_texto_d ~* '<[^>]*\son[a-z]+\s*=' OR v_texto_d ~* '<[^>]*javascript\s*:' THEN
            RAISE EXCEPTION 'El desplegable «%» trae etiquetas que no se permiten', v_titulo_d USING ERRCODE = 'P0015';
        END IF;

        v_pdf_d := nullif(btrim(COALESCE(v_d ->> 'pdf', '')), '');
        IF v_pdf_d IS NOT NULL AND v_pdf_d !~ c_pdf THEN
            RAISE EXCEPTION 'El documento del desplegable «%» debe ser un PDF subido', v_titulo_d USING ERRCODE = 'P0015';
        END IF;

        -- El texto del botón sólo tiene sentido con PDF; sin PDF se descarta
        v_boton_d := CASE WHEN v_pdf_d IS NULL THEN NULL
                          ELSE nullif(btrim(COALESCE(v_d ->> 'boton', '')), '') END;
        IF length(v_boton_d) > 40 THEN
            RAISE EXCEPTION 'El texto del botón no puede pasar de 40 caracteres' USING ERRCODE = 'P0015';
        END IF;
        IF v_boton_d ~ '[<>]' THEN
            RAISE EXCEPTION 'El texto del botón no admite etiquetas' USING ERRCODE = 'P0015';
        END IF;

        v_desplegables := v_desplegables || jsonb_build_array(jsonb_build_object(
            'titulo', v_titulo_d, 'texto', v_texto_d, 'pdf', v_pdf_d, 'boton', v_boton_d));
    END LOOP;

    RETURN jsonb_build_object('texto', v_texto, 'imagen', v_imagen,
                              'imagen_alt', v_alt, 'imagen_lado', v_lado,
                              'pdf', v_pdf, 'desplegables', v_desplegables);
END;
$function$;

-- Las que ya tenían imagen no eligieron lado nunca: se les pone el de fábrica
-- para que la tienda no tenga que adivinar.
UPDATE ecommerce.paginas_informativas
   SET contenido = contenido || jsonb_build_object('imagen_lado', 'derecha')
 WHERE nullif(btrim(COALESCE(contenido ->> 'imagen', '')), '') IS NOT NULL
   AND contenido -> 'imagen_lado' IS NULL;

-- ----------------------------------------------------------------------------
-- 2. LAS FUNCIONES QUE DEJAN DE MIRAR LA CARPETA
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION ecommerce.fn_paginas_informativas_json(p_id bigint)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
AS $function$
    SELECT jsonb_build_object(
        'id',           p.id,
        'clave',        p.clave,
        'titulo',       p.titulo,
        'contenido',    p.contenido,
        'fija',         p.fija,
        'orden',        p.orden,
        'activo',       p.activo,
        'deleted_at',   to_char(p.deleted_at, 'YYYY-MM-DD HH24:MI:SS'),
        'deleted_by',   p.deleted_by,
        'created_by',   p.created_by,
        'updated_by',   p.updated_by,
        'created_at',   to_char(p.created_at, 'YYYY-MM-DD HH24:MI:SS'),
        'updated_at',   to_char(p.updated_at, 'YYYY-MM-DD HH24:MI:SS')
    )
      FROM ecommerce.paginas_informativas p
     WHERE p.id = p_id;
$function$;

CREATE OR REPLACE FUNCTION ecommerce.fn_paginas_informativas_listar()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
AS $function$
    -- Sin el contenido: la lista enseña título y estado, y el texto de diez
    -- páginas con su HTML son cientos de kilobytes para nada.
    --
    -- DE TODO EL CONTENIDO SE SALVA EL NOMBRE DE LA IMAGEN, que la rejilla
    -- pinta en miniatura. Traerla aparte costaría una consulta por fila, y
    -- traer el contenido entero por una miniatura, todo lo demás.
    SELECT jsonb_build_object('success', true, 'message', 'Páginas informativas',
        'data', COALESCE((
            SELECT jsonb_agg(
                     (ecommerce.fn_paginas_informativas_json(p.id) - 'contenido')
                     || jsonb_build_object('imagen', p.contenido ->> 'imagen')
                     ORDER BY p.fija DESC, p.orden, p.id)
              FROM ecommerce.paginas_informativas p
             WHERE p.deleted_at IS NULL), '[]'::jsonb));
$function$;

-- El índice de /documentos. LA FORMA DE LA RESPUESTA NO CAMBIA —sigue siendo
-- un arreglo de secciones— pero ahora hay UNA sola y sin nombre: la tienda ya
-- sabía pintar ese caso (tarjetas sueltas, sin recuadro). Las fijas no salen
-- aquí: la tienda les tiene su propia ruta en el menú.
CREATE OR REPLACE FUNCTION ecommerce.fn_paginas_informativas_listar_publicas()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
AS $function$
    SELECT CASE WHEN t.paginas = '[]'::jsonb THEN '[]'::jsonb
                ELSE jsonb_build_array(jsonb_build_object(
                         'grupo_id', NULL, 'grupo', NULL, 'orden', 1, 'paginas', t.paginas)) END
      FROM (SELECT COALESCE(jsonb_agg(jsonb_build_object('clave', p.clave, 'titulo', p.titulo)
                                      ORDER BY p.orden, p.id), '[]'::jsonb) AS paginas
              FROM ecommerce.paginas_informativas p
             WHERE p.activo AND NOT p.fija AND p.deleted_at IS NULL) t;
$function$;

-- La validación pierde el parámetro de la carpeta: la de antes se tira, que
-- cambiar los parámetros de una función crea otra y conviven las dos.
DROP FUNCTION IF EXISTS ecommerce.fn_paginas_informativas_validar(bigint, text, character varying, bigint);

CREATE OR REPLACE FUNCTION ecommerce.fn_paginas_informativas_validar(
    p_id bigint, p_clave text, p_titulo character varying)
 RETURNS void
 LANGUAGE plpgsql
 STABLE
AS $function$
BEGIN
    IF p_titulo IS NULL OR length(btrim(p_titulo)) < 2 THEN
        RAISE EXCEPTION 'El título de la página es obligatorio (mínimo 2 caracteres)' USING ERRCODE = 'P0001';
    END IF;
    IF length(btrim(p_titulo)) > 120 THEN
        RAISE EXCEPTION 'El título no puede pasar de 120 caracteres' USING ERRCODE = 'P0015';
    END IF;

    IF p_clave IS NULL OR p_clave !~ '^[a-z0-9_-]+$' THEN
        RAISE EXCEPTION 'La dirección de la página sólo admite letras sin tilde, números, guiones y guiones bajos' USING ERRCODE = 'P0015';
    END IF;

    -- La clave choca aunque la otra esté en la papelera: restaurarla no puede
    -- dejar dos páginas respondiendo a la misma dirección.
    IF EXISTS (SELECT 1 FROM ecommerce.paginas_informativas
                WHERE clave = p_clave AND (p_id IS NULL OR id <> p_id)) THEN
        RAISE EXCEPTION 'Ya hay una página en la dirección «%»', p_clave USING ERRCODE = 'P0006';
    END IF;
END;
$function$;

DROP FUNCTION IF EXISTS ecommerce.fn_paginas_informativas_crear(
    text, character varying, jsonb, bigint, boolean,
    bigint, character varying, character varying, inet, text, uuid);

CREATE OR REPLACE FUNCTION ecommerce.fn_paginas_informativas_crear(
    p_clave text, p_titulo character varying, p_contenido jsonb,
    p_activo boolean DEFAULT true,
    p_usuario_id bigint DEFAULT NULL, p_usuario_login character varying DEFAULT NULL,
    p_usuario_nombre character varying DEFAULT NULL, p_ip_address inet DEFAULT NULL,
    p_user_agent text DEFAULT NULL, p_request_id uuid DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'ecommerce', 'auditoria'
AS $function$
DECLARE
    v_id    bigint;
    v_clave text;
BEGIN
    PERFORM ecommerce.fn_contexto_auditoria('ecommerce.paginas_informativas',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    -- Sin clave, se saca del título: «Política de datos» -> «politica-de-datos»
    v_clave := COALESCE(nullif(btrim(COALESCE(p_clave, '')), ''),
                        ecommerce.fn_paginas_informativas_slug(p_titulo));

    PERFORM ecommerce.fn_paginas_informativas_validar(NULL, v_clave, p_titulo);

    INSERT INTO ecommerce.paginas_informativas (clave, titulo, contenido, fija, orden, activo)
    VALUES (v_clave, btrim(p_titulo),
            ecommerce.fn_paginas_informativas_contenido_validar(p_contenido),
            false,   -- fija se decide en la base, no desde la pantalla
            (SELECT COALESCE(max(orden), 0) + 1 FROM ecommerce.paginas_informativas
              WHERE deleted_at IS NULL),
            COALESCE(p_activo, true))
    RETURNING id INTO v_id;

    RETURN jsonb_build_object('success', true, 'message', 'Página creada',
                              'data', ecommerce.fn_paginas_informativas_json(v_id));
END;
$function$;

DROP FUNCTION IF EXISTS ecommerce.fn_paginas_informativas_modificar(
    bigint, character varying, jsonb, bigint, boolean,
    bigint, character varying, character varying, inet, text, uuid);

CREATE OR REPLACE FUNCTION ecommerce.fn_paginas_informativas_modificar(
    p_id bigint, p_titulo character varying, p_contenido jsonb,
    p_activo boolean DEFAULT true,
    p_usuario_id bigint DEFAULT NULL, p_usuario_login character varying DEFAULT NULL,
    p_usuario_nombre character varying DEFAULT NULL, p_ip_address inet DEFAULT NULL,
    p_user_agent text DEFAULT NULL, p_request_id uuid DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'ecommerce', 'auditoria'
AS $function$
DECLARE
    v_clave text;
    v_antes jsonb;
BEGIN
    PERFORM ecommerce.fn_contexto_auditoria('ecommerce.paginas_informativas',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    SELECT clave INTO v_clave
      FROM ecommerce.paginas_informativas WHERE id = p_id AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'La página no existe' USING ERRCODE = 'P0013';
    END IF;

    -- LA CLAVE NO SE CAMBIA: es la dirección por la que la tienda la pide y
    -- por la que la enlaza el menú. Cambiarla rompería los enlaces de fuera.
    PERFORM ecommerce.fn_paginas_informativas_validar(p_id, v_clave, p_titulo);

    v_antes := ecommerce.fn_paginas_informativas_json(p_id);
    PERFORM set_config('app.datos_anteriores', v_antes::text, true);

    UPDATE ecommerce.paginas_informativas
       SET titulo    = btrim(p_titulo),
           contenido = ecommerce.fn_paginas_informativas_contenido_validar(p_contenido),
           activo    = COALESCE(p_activo, true)
     WHERE id = p_id;

    PERFORM set_config('app.datos_anteriores', '', true);

    RETURN jsonb_build_object('success', true, 'message', 'Página actualizada',
                              'data', ecommerce.fn_paginas_informativas_json(p_id));
END;
$function$;

CREATE OR REPLACE FUNCTION ecommerce.fn_paginas_informativas_restaurar(
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
    v_cuantas integer;
BEGIN
    PERFORM ecommerce.fn_contexto_auditoria('ecommerce.paginas_informativas',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    IF jsonb_typeof(p_ids) <> 'array' OR jsonb_array_length(p_ids) = 0 THEN
        RAISE EXCEPTION 'No se indicó qué restaurar' USING ERRCODE = 'P0015';
    END IF;

    UPDATE ecommerce.paginas_informativas p
       SET deleted_at = NULL, deleted_by = NULL
     WHERE p.deleted_at IS NOT NULL
       AND p.id IN (SELECT valor::bigint FROM jsonb_array_elements_text(p_ids) AS x(valor));
    GET DIAGNOSTICS v_cuantas = ROW_COUNT;

    IF v_cuantas = 0 THEN
        RAISE EXCEPTION 'Ninguna de esas páginas está en la papelera' USING ERRCODE = 'P0019';
    END IF;

    RETURN jsonb_build_object('success', true,
        'message', CASE v_cuantas WHEN 1 THEN 'Página restaurada' ELSE format('%s páginas restauradas', v_cuantas) END, 'data', NULL);
END;
$function$;

-- La papelera es de páginas y nada más: se van `tipo` y `grupo_id`, que
-- existían para distinguir las carpetas de lo que había dentro.
CREATE OR REPLACE FUNCTION ecommerce.fn_paginas_informativas_papelera_listar()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
AS $function$
    SELECT jsonb_build_object('success', true, 'message', 'Papelera de páginas informativas',
        'data', COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
                       'id',         p.id,
                       'texto',      p.titulo,
                       'detalle',    p.clave,
                       'deleted_at', to_char(p.deleted_at, 'YYYY-MM-DD HH24:MI:SS'),
                       'deleted_by', p.deleted_by)
                     ORDER BY p.deleted_at DESC, p.titulo)
              FROM ecommerce.paginas_informativas p
             WHERE p.deleted_at IS NOT NULL), '[]'::jsonb));
$function$;

CREATE OR REPLACE FUNCTION ecommerce.fn_paginas_informativas_papelera_vaciar(
    p_usuario_id bigint DEFAULT NULL, p_usuario_login character varying DEFAULT NULL,
    p_usuario_nombre character varying DEFAULT NULL, p_ip_address inet DEFAULT NULL,
    p_user_agent text DEFAULT NULL, p_request_id uuid DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'ecommerce', 'auditoria'
AS $function$
DECLARE
    v_paginas  integer;
    v_ficheros jsonb;
BEGIN
    PERFORM ecommerce.fn_contexto_auditoria('ecommerce.paginas_informativas',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    -- Los ficheros de lo que se va: el controlador los borra del disco. Van en
    -- la respuesta y no se borran aquí porque la base no toca el disco, y si
    -- la transacción se deshace los ficheros ya no estarían.
    SELECT COALESCE(jsonb_agg(f), '[]'::jsonb) INTO v_ficheros FROM (
        SELECT p.contenido ->> 'imagen' AS f FROM ecommerce.paginas_informativas p
         WHERE p.deleted_at IS NOT NULL AND p.contenido ->> 'imagen' IS NOT NULL
        UNION ALL
        SELECT p.contenido ->> 'pdf' FROM ecommerce.paginas_informativas p
         WHERE p.deleted_at IS NOT NULL AND p.contenido ->> 'pdf' IS NOT NULL
        UNION ALL
        SELECT d ->> 'pdf' FROM ecommerce.paginas_informativas p,
               jsonb_array_elements(COALESCE(p.contenido -> 'desplegables', '[]'::jsonb)) d
         WHERE p.deleted_at IS NOT NULL AND d ->> 'pdf' IS NOT NULL
    ) t;

    DELETE FROM ecommerce.paginas_informativas WHERE deleted_at IS NOT NULL;
    GET DIAGNOSTICS v_paginas = ROW_COUNT;

    RETURN jsonb_build_object('success', true,
        'message', format('Papelera vaciada: %s',
                   CASE v_paginas WHEN 1 THEN '1 página' ELSE v_paginas || ' páginas' END),
        'data', jsonb_build_object('paginas', v_paginas, 'ficheros', v_ficheros));
END;
$function$;

-- ----------------------------------------------------------------------------
-- 3. SE VAN LAS CARPETAS
-- ----------------------------------------------------------------------------
-- Las ocho funciones de carpetas, la columna que las apuntaba y la tabla. Por
-- este orden: la columna no se puede soltar mientras una función la nombre.
DROP FUNCTION IF EXISTS ecommerce.fn_paginas_informativas_grupos_json(bigint);
DROP FUNCTION IF EXISTS ecommerce.fn_paginas_informativas_grupos_listar();
DROP FUNCTION IF EXISTS ecommerce.fn_paginas_informativas_grupos_validar(bigint, character varying);
DROP FUNCTION IF EXISTS ecommerce.fn_paginas_informativas_grupos_crear(
    character varying, bigint, character varying, character varying, inet, text, uuid);
DROP FUNCTION IF EXISTS ecommerce.fn_paginas_informativas_grupos_modificar(
    bigint, character varying, bigint, character varying, character varying, inet, text, uuid);
DROP FUNCTION IF EXISTS ecommerce.fn_paginas_informativas_grupos_ordenar(
    jsonb, bigint, character varying, character varying, inet, text, uuid);
DROP FUNCTION IF EXISTS ecommerce.fn_paginas_informativas_grupos_eliminar(
    bigint, bigint, character varying, character varying, inet, text, uuid);
DROP FUNCTION IF EXISTS ecommerce.fn_paginas_informativas_grupos_restaurar(
    bigint, bigint, character varying, character varying, inet, text, uuid);

-- La regla «una página fija no va en carpeta» se queda sin carpeta de la que
-- hablar, y la llave que apuntaba a la tabla, sin tabla
ALTER TABLE ecommerce.paginas_informativas DROP CONSTRAINT IF EXISTS ck_paginas_informativas_fija;
ALTER TABLE ecommerce.paginas_informativas DROP CONSTRAINT IF EXISTS fk_paginas_informativas_grupo;
DROP INDEX IF EXISTS ecommerce.ix_paginas_informativas_grupo;
ALTER TABLE ecommerce.paginas_informativas DROP COLUMN IF EXISTS grupo_id;

DROP TABLE IF EXISTS ecommerce.paginas_informativas_grupos;

COMMENT ON TABLE ecommerce.paginas_informativas IS
    'Las páginas de texto de la tienda: términos, políticas, garantías y «Conócenos». '
    'Un CRUD plano: no hay carpetas (se quitaron el 07/11/2026). El contenido es jsonb '
    '{texto, imagen, imagen_alt, imagen_lado, pdf, desplegables:[{titulo,texto,pdf,boton}]}.';

-- ----------------------------------------------------------------------------
-- 4. QUE DE VERDAD ESTÉ TODO
-- ----------------------------------------------------------------------------
DO $comprobar$
DECLARE
    v_paginas   integer;
    v_con_lado  integer;
    v_con_img   integer;
    v_publicas  jsonb;
    v_secciones integer;
    v_prueba    jsonb;
BEGIN
    -- Ni columna, ni tabla, ni funciones de carpetas
    IF EXISTS (SELECT 1 FROM information_schema.columns
                WHERE table_schema = 'ecommerce' AND table_name = 'paginas_informativas'
                  AND column_name = 'grupo_id') THEN
        RAISE EXCEPTION 'La columna grupo_id sigue ahí';
    END IF;
    IF to_regclass('ecommerce.paginas_informativas_grupos') IS NOT NULL THEN
        RAISE EXCEPTION 'La tabla de carpetas sigue ahí';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                WHERE n.nspname = 'ecommerce' AND p.proname LIKE 'fn_paginas_informativas_grupos%') THEN
        RAISE EXCEPTION 'Quedan funciones de carpetas';
    END IF;

    SELECT count(*) INTO v_paginas FROM ecommerce.paginas_informativas;
    IF v_paginas = 0 THEN
        RAISE EXCEPTION 'No quedó ninguna página: algo se llevó por delante los datos';
    END IF;

    -- Toda página con imagen tiene lado, y ninguna sin imagen lo tiene
    SELECT count(*) INTO v_con_img FROM ecommerce.paginas_informativas
     WHERE nullif(btrim(COALESCE(contenido ->> 'imagen', '')), '') IS NOT NULL;
    SELECT count(*) INTO v_con_lado FROM ecommerce.paginas_informativas
     WHERE contenido ->> 'imagen_lado' IN ('izquierda', 'derecha');
    IF v_con_lado <> v_con_img THEN
        RAISE EXCEPTION 'Hay % páginas con imagen y % con lado', v_con_img, v_con_lado;
    END IF;

    -- El validador acepta el lado y lo devuelve
    v_prueba := ecommerce.fn_paginas_informativas_contenido_validar(
        '{"texto":"<p>hola</p>","imagen":"x.png","imagen_lado":"izquierda"}'::jsonb);
    IF v_prueba ->> 'imagen_lado' <> 'izquierda' THEN
        RAISE EXCEPTION 'El validador no conserva el lado de la imagen';
    END IF;

    v_prueba := ecommerce.fn_paginas_informativas_contenido_validar(
        '{"texto":"<p>hola</p>","imagen":"x.png"}'::jsonb);
    IF v_prueba ->> 'imagen_lado' <> 'derecha' THEN
        RAISE EXCEPTION 'Sin decir el lado, la imagen debería ir a la derecha';
    END IF;

    v_prueba := ecommerce.fn_paginas_informativas_contenido_validar('{"texto":"<p>hola</p>"}'::jsonb);
    IF v_prueba -> 'imagen_lado' <> 'null'::jsonb THEN
        RAISE EXCEPTION 'Sin imagen no debería haber lado';
    END IF;

    -- El índice público: una sola sección y sin nombre
    v_publicas  := ecommerce.fn_paginas_informativas_listar_publicas();
    v_secciones := jsonb_array_length(v_publicas);
    IF v_secciones > 1 THEN
        RAISE EXCEPTION 'El índice público devolvió % secciones; ahora es una sola', v_secciones;
    END IF;
    IF v_secciones = 1 AND v_publicas -> 0 -> 'grupo' <> 'null'::jsonb THEN
        RAISE EXCEPTION 'La sección del índice público sigue teniendo nombre de carpeta';
    END IF;

    RAISE NOTICE 'Comprobado: % páginas, % con imagen y su lado, % sección(es) en /documentos.',
        v_paginas, v_con_img, v_secciones;
END;
$comprobar$;

COMMIT;
