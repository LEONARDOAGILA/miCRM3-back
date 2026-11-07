-- ============================================================================
-- ECOMMERCE · EL COLOR DE LA TIENDA
-- ============================================================================
-- Fecha: 2026-11-05
--
-- El rojo de Almacenes España estaba escrito en la hoja de estilos de la
-- tienda (`--ae-rojo`, #DF1122). Ahora se elige desde «Encabezado» y vale para
-- TODA la tienda: la barra de categorías, los botones, los carteles de
-- descuento, los círculos de las categorías, las flechas y el pie leen esa
-- misma variable, así que con un color se cambia todo a la vez y nada se
-- queda de un tono distinto.
--
-- VA EN LA CONFIGURACIÓN DEL ENCABEZADO y no en una tabla nueva porque la
-- tienda ya pide el encabezado y el pie en su PRIMERA llamada, antes de pintar
-- nada: metido ahí, el color llega con lo que ya se pedía y no hace falta una
-- petición más —ni esperarla— para saber de qué color es la tienda.
--
-- NULL ES EL ROJO DE SIEMPRE. Sin elegir nada la tienda usa el suyo, que es lo
-- que hace hoy; y el día que cambie el de fábrica lo heredan todas las tiendas
-- que no hayan elegido uno propio.
--
-- LOS TONOS DERIVADOS NO SE GUARDAN: el del hover (más oscuro) y el de los
-- fondos suaves (más claro) los calcula la tienda a partir del principal. Si
-- se guardaran, habría que acertar tres colores que van juntos, y es donde se
-- acaba viendo un hover que no pega con su botón.
--
-- Idempotente: la función se reescribe entera.
-- ============================================================================
\set ON_ERROR_STOP on

BEGIN;

-- ----------------------------------------------------------------------------
-- 1. LA CONFIGURACIÓN DEL ENCABEZADO, CON EL COLOR
-- ----------------------------------------------------------------------------
-- Es la misma de antes con una clave más. Se reescribe entera y no con una
-- cirugía porque es corta y aquí se lee de un vistazo qué guarda el encabezado.
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
        -- EL COLOR DE TODA LA TIENDA. NULL = el rojo de siempre. Los tonos de
        -- hover y de fondo suave los calcula la tienda a partir de éste.
        'color_principal', ecommerce.fn_validar_color(p_config ->> 'color_principal', 'El color de la tienda'),
        'credito', jsonb_build_object(
            'activo',              v_credito_on,
            'texto',               ecommerce.fn_validar_texto(v_credito ->> 'texto', 'El texto del crédito', 60, v_credito_on),
            'boton_texto',         ecommerce.fn_validar_texto(v_credito ->> 'boton_texto', 'El botón del crédito', 30, v_credito_on),
            'boton_enlace',        v_enlace_credito,
            'boton_nueva_pestana', ecommerce.fn_nueva_pestana(v_enlace_credito, (v_credito ->> 'boton_nueva_pestana')::boolean))
    );
END;
$function$;

COMMENT ON FUNCTION ecommerce.fn_encabezado_validar_config(jsonb) IS
    'Revisa y normaliza la configuración del encabezado. `color_principal` es el color de TODA la tienda; NULL = el rojo de siempre.';

-- ----------------------------------------------------------------------------
-- 2. COMPROBACIÓN
-- ----------------------------------------------------------------------------
-- Sobre el encabezado de verdad, y se deshace: sólo hay uno.
DO $comprobar$
DECLARE
    v_antes   jsonb;
    v_guardado jsonb;
    v_tienda  jsonb;
    v_sin     jsonb;
    v_malo    text := NULL;
BEGIN
    SELECT config INTO v_antes FROM ecommerce.encabezado WHERE id = 1;
    IF v_antes IS NULL THEN
        RAISE NOTICE 'No hay encabezado con el que comprobar; la función está.';
        RETURN;
    END IF;

    BEGIN
        -- Se guarda como lo hace el CRM —pasando por el validador—, pero sin la
        -- auditoría: lo que cambia aquí es el validador, no quién lo guardó
        UPDATE ecommerce.encabezado
           SET config = ecommerce.fn_encabezado_validar_config(
                            v_antes || jsonb_build_object('color_principal', '#0A58CA'))
         WHERE id = 1;

        SELECT config INTO v_guardado FROM ecommerce.encabezado WHERE id = 1;

        SELECT x -> 'config' INTO v_tienda
          FROM jsonb_array_elements(ecommerce.fn_secciones_publicas()) x
         WHERE x ->> 'clave' = 'header';

        -- Sin la clave, el color se vacía: vuelve el de siempre
        UPDATE ecommerce.encabezado
           SET config = ecommerce.fn_encabezado_validar_config(v_antes - 'color_principal')
         WHERE id = 1;
        SELECT config INTO v_sin FROM ecommerce.encabezado WHERE id = 1;

        -- «azul» no es un color
        BEGIN
            PERFORM ecommerce.fn_encabezado_validar_config(
                    v_antes || jsonb_build_object('color_principal', 'azul'));
            v_malo := 'entró «azul» como color';
        EXCEPTION WHEN SQLSTATE 'P0015' THEN
            NULL;
        END;

        RAISE EXCEPTION 'deshacer' USING ERRCODE = 'P0099';
    EXCEPTION WHEN SQLSTATE 'P0099' THEN
        NULL;
    END;

    IF v_guardado ->> 'color_principal' <> '#0a58ca' AND v_guardado ->> 'color_principal' <> '#0A58CA' THEN
        RAISE EXCEPTION 'El color no se guardó: %', v_guardado -> 'color_principal';
    END IF;
    IF lower(v_tienda ->> 'color_principal') <> '#0a58ca' THEN
        RAISE EXCEPTION 'La tienda no lo recibe: %', v_tienda -> 'color_principal';
    END IF;
    IF v_sin -> 'color_principal' <> 'null'::jsonb THEN
        RAISE EXCEPTION 'Sin elegir ninguno tendría que quedarse en null, y salió %', v_sin -> 'color_principal';
    END IF;
    -- Lo demás del encabezado no se toca. Se compara contra lo que devuelve el
    -- propio validador: el guardado de antes pudo quedar con claves que ya no
    -- se escriben, y eso no es cosa de este fichero
    IF (v_guardado - 'color_principal')
       IS DISTINCT FROM (ecommerce.fn_encabezado_validar_config(v_antes) - 'color_principal') THEN
        RAISE EXCEPTION 'Se cambió algo más del encabezado: % vs %', v_guardado, v_antes;
    END IF;
    IF v_malo IS NOT NULL THEN
        RAISE EXCEPTION '%', v_malo;
    END IF;
    IF (SELECT config FROM ecommerce.encabezado WHERE id = 1) IS DISTINCT FROM v_antes THEN
        RAISE EXCEPTION 'El encabezado se quedó cambiado';
    END IF;

    RAISE NOTICE 'Comprobado: el color se guarda, llega a la tienda, vaciarlo devuelve el de siempre, «azul» no entra y no se tocó nada más del encabezado. Quedó como estaba.';
END
$comprobar$;

COMMIT;
