-- ============================================================================
-- UNA PÁGINA NUEVA PUEDE NACER CON SUS PRODUCTOS DENTRO
-- ============================================================================
-- Al crear una página había que acordarse de dos cosas que no se ven en el
-- formulario:
--
--   · si apunta a una categoría o a una marca, encender la casilla del
--     CATÁLOGO —si no, la página de «Línea Blanca» se queda sin un solo
--     producto de línea blanca—;
--   · y si no apunta a ninguna, entrar después en el editor de secciones a
--     añadirle un ESCAPARATE.
--
-- Lo primero se arregla en el CRM: la casilla nace encendida cuando la página
-- apunta a una categoría o a una marca, que es lo que se quiere el 99% de las
-- veces, y se puede apagar.
--
-- LO SEGUNDO ES LO QUE SE AÑADE AQUÍ: `escaparate_id` en los datos de guardar.
-- Al crear —y sólo al crear— la página nace con ese escaparate dentro,
-- encendido y al final, exactamente como si se hubiera añadido después desde
-- el editor, porque es la misma función la que lo hace.
--
-- VA EN LA BASE Y NO EN DOS LLAMADAS DESDE EL CRM para que sea todo o nada: si
-- el escaparate no existe, la página tampoco se crea. Una página que se pidió
-- con productos y nace vacía es peor que un error.
--
-- ----------------------------------------------------------------------------
-- SE EJECUTA A MANO. Para ensayar sin guardar, cambiar el COMMIT del final por
-- ROLLBACK: la comprobación se hace igual y no queda rastro.
-- ============================================================================

BEGIN;

CREATE OR REPLACE FUNCTION ecommerce.fn_cuerpos_guardar(p_id bigint, p_datos jsonb, p_usuario_id bigint DEFAULT NULL::bigint, p_usuario_login character varying DEFAULT NULL::character varying, p_usuario_nombre character varying DEFAULT NULL::character varying, p_ip_address inet DEFAULT NULL::inet, p_user_agent text DEFAULT NULL::text, p_request_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'ecommerce', 'auditoria'
AS $function$
DECLARE
    v_id        bigint := p_id;
    v_nombre    text;
    v_ruta      text;
    v_categoria bigint;
    v_marca     bigint;
    v_principal boolean := false;
    v_fijo      boolean := false;
    v_ruta_vieja text;
    v_sembradas integer := 0;
    v_escaparate bigint;
    v_escaparate_nombre text;
BEGIN
    PERFORM ecommerce.fn_contexto_auditoria('ecommerce.cuerpos',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    IF p_id IS NOT NULL THEN
        SELECT principal, fijo, ruta INTO v_principal, v_fijo, v_ruta_vieja
          FROM ecommerce.cuerpos
         WHERE id = p_id AND deleted_at IS NULL;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'Ese cuerpo no existe' USING ERRCODE = 'P0013';
        END IF;
    END IF;

    v_nombre    := btrim(COALESCE(p_datos ->> 'nombre', ''));
    v_ruta      := lower(btrim(COALESCE(p_datos ->> 'ruta', '')));
    v_categoria := nullif(btrim(COALESCE(p_datos ->> 'categoria_id', '')), '')::bigint;
    v_marca     := nullif(btrim(COALESCE(p_datos ->> 'marca_id', '')), '')::bigint;

    -- EL ESCAPARATE CON EL QUE NACE LA PÁGINA, si eligieron uno al crearla.
    -- Es un atajo, igual que la casilla del catálogo: lo mismo se puede hacer
    -- después en el editor de secciones, pero una página recién creada está
    -- vacía y es justo el momento en que se le quiere meter algo.
    v_escaparate := nullif(btrim(COALESCE(p_datos ->> 'escaparate_id', '')), '')::bigint;

    -- El principal no apunta a nada, y se dice aquí para que el mensaje
    -- explique qué hacer; la tabla lo prohíbe igual por si entra por otro lado
    IF v_principal AND (v_categoria IS NOT NULL OR v_marca IS NOT NULL) THEN
        RAISE EXCEPTION 'El cuerpo principal es la entrada de la tienda: no puede ser además la página de una categoría o de una marca'
              USING ERRCODE = 'P0015';
    END IF;

    -- Una página fija no se muda: /shop es a donde apuntan el menú, el
    -- buscador y cada filtro, y moverla los rompería todos de golpe. Lo
    -- demás —nombre, título, fondo, secciones— se cambia con libertad.
    IF v_fijo AND v_ruta IS DISTINCT FROM v_ruta_vieja THEN
        RAISE EXCEPTION '«%» es una página que la tienda necesita: su dirección «/%» no se puede cambiar',
              v_nombre, v_ruta_vieja USING ERRCODE = 'P0015';
    END IF;

    PERFORM ecommerce.fn_cuerpos_validar(p_id, v_nombre, v_ruta, v_categoria, v_marca);

    IF p_id IS NULL THEN
        INSERT INTO ecommerce.cuerpos (nombre, ruta, categoria_id, marca_id, titulo, descripcion, fondo,
                                       catalogo, activo)
        VALUES (v_nombre, v_ruta, v_categoria, v_marca,
                ecommerce.fn_validar_texto(p_datos ->> 'titulo', 'El título de la página', 120),
                nullif(btrim(COALESCE(p_datos ->> 'descripcion', '')), ''),
                ecommerce.fn_validar_color(p_datos ->> 'fondo', 'El fondo de la página'),
                COALESCE((p_datos ->> 'catalogo')::boolean, false),
                COALESCE((p_datos ->> 'activo')::boolean, true))
        RETURNING id INTO v_id;

        -- Con las secciones que la tienda sabe pintar, apagadas: así se
        -- enciende lo que haga falta en vez de empezar con un hueco
        v_sembradas := ecommerce.fn_cuerpo_sembrar(v_id);

        -- SÓLO AL CREAR. En una página que ya existe esto sería un segundo
        -- sitio donde decir lo que dice el editor de secciones, y el mismo
        -- escaparate dos veces en la misma página lo rechaza la base.
        --
        -- Y SI EL ESCAPARATE NO EXISTE, LA PÁGINA NO SE CREA: `poner` revienta
        -- y se va todo. Es lo que se quiere: una página que se pidió con
        -- productos y nace vacía es peor que un error.
        IF v_escaparate IS NOT NULL THEN
            PERFORM ecommerce.fn_inicio_escaparate_poner(v_id, v_escaparate,
                p_usuario_id, p_usuario_login, p_usuario_nombre,
                p_ip_address, p_user_agent, p_request_id);

            SELECT nombre INTO v_escaparate_nombre
              FROM ecommerce.producto_secciones WHERE id = v_escaparate;
        END IF;
    ELSE
        UPDATE ecommerce.cuerpos
           SET nombre       = v_nombre,
               ruta         = v_ruta,
               categoria_id = v_categoria,
               marca_id     = v_marca,
               titulo       = ecommerce.fn_validar_texto(p_datos ->> 'titulo', 'El título de la página', 120),
               descripcion  = nullif(btrim(COALESCE(p_datos ->> 'descripcion', '')), ''),
               -- El fondo de ESTA página; vacío, blanco
               fondo        = ecommerce.fn_validar_color(p_datos ->> 'fondo', 'El fondo de la página'),
               catalogo     = COALESCE((p_datos ->> 'catalogo')::boolean, false),
               -- El principal no se puede apagar: la tienda se quedaría sin
               -- página de entrada
               activo       = CASE WHEN principal THEN true
                                   ELSE COALESCE((p_datos ->> 'activo')::boolean, true) END
         WHERE id = p_id;
    END IF;

    -- El catálogo es una SECCIÓN; la casilla sólo la crea o la apaga
    PERFORM ecommerce.fn_cuerpo_catalogo_sincronizar(
        v_id, COALESCE((p_datos ->> 'catalogo')::boolean, false));

    RETURN jsonb_build_object('success', true,
        'message', CASE
            WHEN p_id IS NOT NULL THEN format('Cuerpo «%s» guardado', v_nombre)
            WHEN v_escaparate_nombre IS NOT NULL
                THEN format('Cuerpo «%s» creado con «%s» dentro', v_nombre, v_escaparate_nombre)
            WHEN v_sembradas = 0   THEN format('Cuerpo «%s» creado', v_nombre)
            ELSE format('Cuerpo «%s» creado con sus %s secciones apagadas', v_nombre, v_sembradas) END,
        'data', ecommerce.fn_cuerpos_json(v_id));
END;
$function$;

COMMIT;


-- ============================================================================
-- COMPROBACIÓN — crea una página de prueba y la deshace
-- ============================================================================
-- Se crea de verdad dentro de un bloque con EXCEPTION —que es una
-- subtransacción— y se revienta a propósito al final: así se comprueba lo que
-- de verdad pasa y no queda ni la página ni su sección.
DO $comprobar$
DECLARE
    v_falta   text[] := '{}';
    v_esc     bigint;
    v_res     jsonb;
    v_id      bigint;
    v_puesta  integer;
    v_ruta    text := 'prueba-escaparate-' || to_char(clock_timestamp(), 'HH24MISSUS');
BEGIN
    -- El texto nuevo tiene que estar en la función
    IF NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                    WHERE n.nspname = 'ecommerce' AND p.proname = 'fn_cuerpos_guardar'
                      AND pg_get_functiondef(p.oid) LIKE '%escaparate_id%') THEN
        v_falta := array_append(v_falta, 'la función no sabe de escaparate_id');
    END IF;

    SELECT id INTO v_esc FROM ecommerce.producto_secciones
     WHERE deleted_at IS NULL ORDER BY id LIMIT 1;

    IF v_esc IS NULL THEN
        RAISE NOTICE 'No hay ningún escaparate: la prueba de verdad se salta.';
    ELSE
        BEGIN
            v_res := ecommerce.fn_cuerpos_guardar(NULL, jsonb_build_object(
                'nombre', 'Prueba de escaparate', 'ruta', v_ruta,
                'escaparate_id', v_esc));

            v_id := (v_res -> 'data' ->> 'id')::bigint;

            SELECT count(*) INTO v_puesta FROM ecommerce.inicio_secciones
             WHERE cuerpo_id = v_id AND producto_seccion_id = v_esc AND activo;

            IF v_puesta <> 1 THEN
                v_falta := array_append(v_falta, 'la página nació sin su escaparate');
            END IF;
            IF (v_res ->> 'message') NOT LIKE '%dentro%' THEN
                v_falta := array_append(v_falta, 'el mensaje no dice qué lleva dentro: ' || (v_res ->> 'message'));
            END IF;

            -- Y se deshace: la prueba no deja página
            RAISE EXCEPTION 'deshacer la prueba';
        EXCEPTION WHEN others THEN
            IF SQLERRM <> 'deshacer la prueba' THEN
                RAISE;
            END IF;
        END;

        IF EXISTS (SELECT 1 FROM ecommerce.cuerpos WHERE ruta = v_ruta) THEN
            v_falta := array_append(v_falta, 'la página de prueba se quedó en la base');
        END IF;
    END IF;

    -- Sin escaparate, todo sigue igual que siempre
    BEGIN
        v_res := ecommerce.fn_cuerpos_guardar(NULL, jsonb_build_object(
            'nombre', 'Prueba sin escaparate', 'ruta', v_ruta || '-b'));
        IF (v_res ->> 'message') LIKE '%dentro%' THEN
            v_falta := array_append(v_falta, 'una página sin escaparate dice que lleva algo dentro');
        END IF;
        RAISE EXCEPTION 'deshacer la prueba';
    EXCEPTION WHEN others THEN
        IF SQLERRM <> 'deshacer la prueba' THEN
            RAISE;
        END IF;
    END;

    IF array_length(v_falta, 1) > 0 THEN
        RAISE EXCEPTION 'El escaparate al crear no quedó bien: %', array_to_string(v_falta, '; ');
    END IF;

    RAISE NOTICE 'Una página nueva puede nacer con su escaparate dentro.';
END;
$comprobar$;
