-- ============================================================================
-- EL PDF DE UNA PÁGINA: AHORA SE SUBE, Y SE GUARDA CÓMO SE LLAMABA
-- ============================================================================
-- Hasta hoy el PDF de una página informativa venía heredado del CRM viejo y no
-- se podía ni cambiar ni quitar: el editor lo enseñaba y lo devolvía tal cual.
-- Se abre entero (subir, cambiar y quitar), y para eso hace falta una cosa más
-- en el contenido.
--
-- `pdf_nombre`: CÓMO SE LLAMABA EL FICHERO QUE SUBIERON. El nombre con el que
-- se guarda en el disco es inventado —lleva la fecha y unos caracteres al
-- azar, para que dos páginas no pisen el mismo fichero y para que el navegador
-- se entere al cambiarlo—, y enseñar «5IMBacul0ZVcuZaD16xvDAXFvssrRYwLdVCHH9lS.pdf»
-- no le dice nada a nadie. Con esto, el CRM y la tienda pueden enseñar
-- «Terminos de la garantia extendida.pdf», que es lo que el visitante
-- reconoce y lo que se descarga.
--
-- SÓLO TIENE SENTIDO CON PDF: sin fichero se descarta, igual que `imagen_alt`
-- sin imagen. Así no queda el nombre de un documento que ya no está.
--
-- Las páginas que ya tienen PDF se quedan con `pdf_nombre` en null: de ésas no
-- se sabe cómo se llamaban, y quien lo quiera arreglado sólo tiene que volver
-- a subir el fichero. Donde no haya nombre, se enseña «Documento.pdf».
--
-- Es idempotente: sólo reemplaza la función.
-- ============================================================================

BEGIN;

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
    v_pdf_nombre   text;
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
       OR COALESCE(jsonb_typeof(p_contenido -> 'pdf_nombre'), 'null')  NOT IN ('string', 'null')
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

    -- CÓMO SE LLAMABA EL FICHERO. Sin PDF se descarta, como el alt sin imagen.
    -- No se valida con c_pdf: aquí sí entran espacios, tildes y paréntesis,
    -- porque es el nombre que puso una persona, no el del disco.
    v_pdf_nombre := CASE WHEN v_pdf IS NULL THEN NULL
                         ELSE nullif(btrim(COALESCE(p_contenido ->> 'pdf_nombre', '')), '') END;
    IF length(v_pdf_nombre) > 150 THEN
        RAISE EXCEPTION 'El nombre del documento no puede pasar de 150 caracteres' USING ERRCODE = 'P0015';
    END IF;
    -- Se enseña tal cual en la tienda y en el CRM: nada que pueda cerrar una etiqueta
    IF v_pdf_nombre ~ '[<>"]' THEN
        RAISE EXCEPTION 'El nombre del documento no admite < > ni comillas' USING ERRCODE = 'P0015';
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
                              'pdf', v_pdf, 'pdf_nombre', v_pdf_nombre,
                              'desplegables', v_desplegables);
END;
$function$;

-- ---------------------------------------------------------------------------
-- COMPROBACIÓN
-- ---------------------------------------------------------------------------
-- Se prueba la función a pelo: no escribe nada y es lo único que demuestra que
-- las reglas nuevas hacen lo que dicen.
DO $comprobar$
DECLARE
    v jsonb;
    v_error text;
BEGIN
    -- Con PDF, el nombre se guarda
    v := ecommerce.fn_paginas_informativas_contenido_validar(
        '{"texto":"<p>Hola</p>","pdf":"pagina_1.pdf","pdf_nombre":"Términos (2026).pdf"}'::jsonb);
    IF v ->> 'pdf_nombre' IS DISTINCT FROM 'Términos (2026).pdf' THEN
        RAISE EXCEPTION 'El nombre del PDF no se guardó: %', v ->> 'pdf_nombre' USING ERRCODE = 'P0015';
    END IF;

    -- Sin PDF, el nombre se tira
    v := ecommerce.fn_paginas_informativas_contenido_validar(
        '{"texto":"<p>Hola</p>","pdf_nombre":"suelto.pdf"}'::jsonb);
    IF v ->> 'pdf_nombre' IS NOT NULL THEN
        RAISE EXCEPTION 'Un nombre sin PDF debería descartarse, y quedó: %', v ->> 'pdf_nombre' USING ERRCODE = 'P0015';
    END IF;

    -- Lo de siempre sigue funcionando (sin tocar el nombre)
    v := ecommerce.fn_paginas_informativas_contenido_validar('{"texto":"<p>Hola</p>"}'::jsonb);
    IF v ->> 'texto' IS NULL OR v ? 'pdf_nombre' IS NOT TRUE THEN
        RAISE EXCEPTION 'El contenido de siempre dejó de validarse bien: %', v USING ERRCODE = 'P0015';
    END IF;

    -- Y un nombre con una etiqueta dentro no pasa
    BEGIN
        v := ecommerce.fn_paginas_informativas_contenido_validar(
            '{"texto":"<p>Hola</p>","pdf":"pagina_1.pdf","pdf_nombre":"<b>no</b>.pdf"}'::jsonb);
        v_error := 'coló';
    EXCEPTION WHEN sqlstate 'P0015' THEN
        v_error := NULL;
    END;
    IF v_error IS NOT NULL THEN
        RAISE EXCEPTION 'Un nombre con etiquetas no debería pasar' USING ERRCODE = 'P0015';
    END IF;

    RAISE NOTICE 'Comprobado: el contenido guarda «pdf_nombre», lo descarta sin PDF y rechaza etiquetas.';
END;
$comprobar$;

COMMIT;
