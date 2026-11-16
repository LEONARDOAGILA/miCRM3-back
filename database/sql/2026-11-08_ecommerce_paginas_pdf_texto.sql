-- ============================================================================
-- EL TEXTO QUE ACOMPAÑA AL DOCUMENTO
-- ============================================================================
-- En la tienda, el PDF de una página sale como un botón «DESCARGAR PDF». Falta
-- poder escribir una frase propia —«Para mayor información, ver el PDF»— y que
-- el documento se abra desde un icono al lado de esa frase, en vez del botón.
--
-- `pdf_texto`: esa frase. Vacía, la tienda sigue sacando el botón de siempre,
-- así que las páginas que ya tienen documento no cambian de aspecto.
--
-- SÓLO CON PDF, igual que `pdf_nombre` y que `imagen_alt` con la imagen: sin
-- documento no hay nada que acompañar y se descarta.
--
-- SIN ETIQUETAS. Esto se pinta tal cual en la tienda —con interpolación, no
-- con innerHTML—, así que un `<` ahí no es formato, es alguien colando algo.
-- Se rechaza al guardar y no se intenta limpiar: lo que se guarda es texto.
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
    v_pdf_texto    text;
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
       OR COALESCE(jsonb_typeof(p_contenido -> 'pdf_texto'), 'null')   NOT IN ('string', 'null')
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

    -- LO QUE SE LEE AL LADO DEL ICONO en la tienda («Para mayor información,
    -- ver el PDF»). Sin documento no hay nada que acompañar, así que se tira.
    v_pdf_texto := CASE WHEN v_pdf IS NULL THEN NULL
                        ELSE nullif(btrim(COALESCE(p_contenido ->> 'pdf_texto', '')), '') END;
    IF length(v_pdf_texto) > 150 THEN
        RAISE EXCEPTION 'El texto del documento no puede pasar de 150 caracteres' USING ERRCODE = 'P0015';
    END IF;
    -- Se pinta tal cual, sin pasar por el limpiador del HTML: nada de etiquetas
    IF v_pdf_texto ~ '[<>]' THEN
        RAISE EXCEPTION 'El texto del documento no admite etiquetas' USING ERRCODE = 'P0015';
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
                              'pdf_texto', v_pdf_texto,
                              'desplegables', v_desplegables);
END;
$function$;


-- ---------------------------------------------------------------------------
-- COMPROBACIÓN
-- ---------------------------------------------------------------------------
-- La función a pelo: no escribe nada y es lo único que demuestra que las
-- reglas nuevas hacen lo que dicen.
DO $comprobar$
DECLARE
    v jsonb;
    v_colo boolean;
BEGIN
    -- Con PDF, la frase se guarda
    v := ecommerce.fn_paginas_informativas_contenido_validar(
        '{"texto":"<p>Hola</p>","pdf":"pagina_1.pdf","pdf_texto":"Para mayor información, ver el PDF"}'::jsonb);
    IF v ->> 'pdf_texto' IS DISTINCT FROM 'Para mayor información, ver el PDF' THEN
        RAISE EXCEPTION 'La frase del documento no se guardó: %', v ->> 'pdf_texto' USING ERRCODE = 'P0015';
    END IF;

    -- Sin PDF, se tira
    v := ecommerce.fn_paginas_informativas_contenido_validar(
        '{"texto":"<p>Hola</p>","pdf_texto":"suelta"}'::jsonb);
    IF v ->> 'pdf_texto' IS NOT NULL THEN
        RAISE EXCEPTION 'Una frase sin PDF debería descartarse, y quedó: %', v ->> 'pdf_texto' USING ERRCODE = 'P0015';
    END IF;

    -- Lo de antes sigue entero
    v := ecommerce.fn_paginas_informativas_contenido_validar(
        '{"texto":"<p>Hola</p>","pdf":"pagina_1.pdf","pdf_nombre":"Términos (2026).pdf"}'::jsonb);
    IF v ->> 'pdf_nombre' IS DISTINCT FROM 'Términos (2026).pdf' OR v ->> 'pdf' IS NULL THEN
        RAISE EXCEPTION 'Se rompió lo que ya funcionaba: %', v USING ERRCODE = 'P0015';
    END IF;

    -- Y una etiqueta no pasa. El flag va FUERA del BEGIN: un RAISE a secas
    -- sale como P0001 y se lo tragaría su propio EXCEPTION.
    BEGIN
        v := ecommerce.fn_paginas_informativas_contenido_validar(
            '{"texto":"<p>Hola</p>","pdf":"pagina_1.pdf","pdf_texto":"ver <b>aquí</b>"}'::jsonb);
        v_colo := true;
    EXCEPTION WHEN sqlstate 'P0015' THEN
        v_colo := false;
    END;
    IF v_colo THEN
        RAISE EXCEPTION 'Una frase con etiquetas no debería pasar' USING ERRCODE = 'P0015';
    END IF;

    RAISE NOTICE 'Comprobado: el contenido guarda «pdf_texto», lo descarta sin PDF y rechaza etiquetas.';
END;
$comprobar$;

COMMIT;
