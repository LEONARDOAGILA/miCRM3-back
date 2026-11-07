-- ============================================================================
-- ECOMMERCE · EL COLOR DE FONDO DE LOS BOTONES DE LA TARJETA
-- ============================================================================
-- Fecha: 2026-11-02
--
-- Las tarjetas de una sección de productos llevan cuatro botones —el corazón,
-- agregar al carrito, WhatsApp y comprar con tarjeta— y hasta hoy su color
-- estaba en la hoja de estilos de la tienda. Ahora se elige por sección, igual
-- que el color del rótulo.
--
-- UNA COLUMNA POR BOTÓN, no un jsonb con cuatro claves. Cada una se valida
-- sola con la misma función que el rótulo (`fn_validar_color`) y la tabla dice
-- qué botones hay; dentro de un jsonb, una clave mal escrita entraría sin que
-- nadie se entere y el botón se quedaría con su color de siempre sin explicar
-- por qué.
--
-- NULL ES «EL DE LA TIENDA», y es el valor por defecto: sin tocar nada, todo
-- se ve exactamente como hoy. Es la misma regla que el color del rótulo, y la
-- que hace que esto se pueda añadir sin repasar ninguna sección.
--
-- SÓLO EL FONDO. El color del texto y del icono lo calcula la tienda a partir
-- del fondo, blanco o negro según cuál se lea encima. Dejar elegir los dos
-- es dejar elegir «amarillo sobre blanco», y eso no hay forma de arreglarlo
-- después desde una pantalla de administración.
--
-- Idempotente.
-- ============================================================================
\set ON_ERROR_STOP on

BEGIN;

-- ----------------------------------------------------------------------------
-- 1. LAS COLUMNAS
-- ----------------------------------------------------------------------------
ALTER TABLE ecommerce.inicio_secciones
    ADD COLUMN IF NOT EXISTS boton_favorito_color varchar(7),
    ADD COLUMN IF NOT EXISTS boton_carrito_color  varchar(7),
    ADD COLUMN IF NOT EXISTS boton_whatsapp_color varchar(7),
    ADD COLUMN IF NOT EXISTS boton_tarjeta_color  varchar(7);

-- La misma regla que el color del rótulo: seis dígitos en minúscula, o nada.
-- Va en la tabla y no sólo en la función: la función se puede cambiar, y lo
-- que no entra en la columna no entra por ninguna puerta.
DO $reglas$
DECLARE
    c text;
BEGIN
    FOREACH c IN ARRAY ARRAY['favorito', 'carrito', 'whatsapp', 'tarjeta'] LOOP
        IF NOT EXISTS (SELECT 1 FROM pg_constraint
                        WHERE conname = 'ck_inicio_secciones_boton_' || c) THEN
            EXECUTE format(
                'ALTER TABLE ecommerce.inicio_secciones ADD CONSTRAINT %I CHECK (%I IS NULL OR %I ~ ''^#[0-9a-f]{6}$'')',
                'ck_inicio_secciones_boton_' || c, 'boton_' || c || '_color', 'boton_' || c || '_color');
        END IF;
    END LOOP;
END
$reglas$;

-- ----------------------------------------------------------------------------
-- 2. LOS CUATRO COLORES, EN UN SITIO
-- ----------------------------------------------------------------------------
-- Como `fn_rotulo_estilo`: el JSON se arma AQUÍ y no en cada consulta, para
-- que la pantalla y la tienda reciban siempre los mismos nombres. Los nulos se
-- quedan nulos a propósito: null es «el de la tienda», y resolverlo aquí
-- obligaría a esta función a conocer la hoja de estilos de la tienda.
CREATE OR REPLACE FUNCTION ecommerce.fn_botones_colores(
    p_favorito text, p_carrito text, p_whatsapp text, p_tarjeta text)
 RETURNS jsonb
 LANGUAGE sql
 IMMUTABLE PARALLEL SAFE
AS $function$
    SELECT jsonb_build_object(
        'favorito', nullif(btrim(COALESCE(p_favorito, '')), ''),
        'carrito',  nullif(btrim(COALESCE(p_carrito,  '')), ''),
        'whatsapp', nullif(btrim(COALESCE(p_whatsapp, '')), ''),
        'tarjeta',  nullif(btrim(COALESCE(p_tarjeta,  '')), ''));
$function$;

-- ----------------------------------------------------------------------------
-- 3. GUARDAR
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ecommerce.fn_inicio_seccion_guardar(
    p_clave text, p_datos jsonb,
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
    v_desde  timestamptz;
    v_hasta  timestamptz;
BEGIN
    PERFORM ecommerce.fn_contexto_auditoria('ecommerce.inicio_secciones',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    SELECT nombre INTO v_nombre FROM ecommerce.inicio_secciones WHERE clave = btrim(COALESCE(p_clave, ''));
    IF v_nombre IS NULL THEN
        RAISE EXCEPTION 'La sección «%» no existe', p_clave USING ERRCODE = 'P0013';
    END IF;

    v_desde := nullif(btrim(COALESCE(p_datos ->> 'desde', '')), '')::timestamptz;
    v_hasta := nullif(btrim(COALESCE(p_datos ->> 'hasta', '')), '')::timestamptz;
    IF v_desde IS NOT NULL AND v_hasta IS NOT NULL AND v_hasta < v_desde THEN
        RAISE EXCEPTION 'Las fechas van al revés: «hasta» es anterior a «desde»' USING ERRCODE = 'P0015';
    END IF;

    UPDATE ecommerce.inicio_secciones
       SET titulo        = ecommerce.fn_validar_texto(p_datos ->> 'titulo', 'El título', 80),
           subtitulo     = ecommerce.fn_validar_texto(p_datos ->> 'subtitulo', 'El subtítulo', 80),
           rotulo_tamano = ecommerce.fn_validar_opcion(p_datos ->> 'rotulo_tamano',
                               ARRAY['pequeno', 'normal', 'grande', 'enorme'], 'El tamaño del rótulo'),
           rotulo_color  = ecommerce.fn_validar_color(p_datos ->> 'rotulo_color', 'El color del rótulo'),
           rotulo_fuente = ecommerce.fn_validar_opcion(p_datos ->> 'rotulo_fuente',
                               ARRAY['titulos', 'texto', 'deportiva', 'serif'], 'La letra del rótulo'),
           alto          = ecommerce.fn_validar_opcion(p_datos ->> 'alto',
                               ARRAY['compacta', 'normal', 'amplia', 'extra'], 'El alto de la sección'),
           -- El fondo de los cuatro botones de la tarjeta. Mismo validador que
           -- el del rótulo: con o sin almohadilla, y a minúsculas.
           boton_favorito_color = ecommerce.fn_validar_color(p_datos ->> 'boton_favorito_color',
                                      'El color del botón de favorito'),
           boton_carrito_color  = ecommerce.fn_validar_color(p_datos ->> 'boton_carrito_color',
                                      'El color del botón de agregar'),
           boton_whatsapp_color = ecommerce.fn_validar_color(p_datos ->> 'boton_whatsapp_color',
                                      'El color del botón de WhatsApp'),
           boton_tarjeta_color  = ecommerce.fn_validar_color(p_datos ->> 'boton_tarjeta_color',
                                      'El color del botón de comprar con tarjeta'),
           activo        = COALESCE((p_datos ->> 'activo')::boolean, true),
           desde         = v_desde,
           hasta         = v_hasta
     WHERE clave = btrim(p_clave);

    RETURN jsonb_build_object('success', true,
        'message', format('«%s» guardada', v_nombre),
        'data', (ecommerce.fn_inicio_listar() -> 'data'));
END;
$function$;

-- ----------------------------------------------------------------------------
-- 4. EL LISTADO DEL CRM
-- ----------------------------------------------------------------------------
-- Se le engancha `botones` al JSON de cada sección. Cirugía y no reescribirla:
-- ese listado lo han ido ampliando el rótulo, el alto y las secciones de
-- productos, y copiarlo entero aquí es la forma de perder algo por el camino.
DO $listar$
DECLARE
    def   text;
    ancla text := E'                       ''fija'',       s.producto_seccion_id IS NULL,';
BEGIN
    SELECT pg_get_functiondef(p.oid) INTO def
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'ecommerce' AND p.proname = 'fn_inicio_listar';

    IF def IS NULL THEN
        RAISE EXCEPTION 'No está ecommerce.fn_inicio_listar';
    END IF;

    IF strpos(def, 'fn_botones_colores') > 0 THEN
        RAISE NOTICE 'El listado ya traía los colores de los botones: no lo toco.';
        RETURN;
    END IF;

    IF strpos(def, ancla) = 0 THEN
        RAISE EXCEPTION 'No encontré dónde enganchar los colores: ¿cambió fn_inicio_listar?';
    END IF;

    def := replace(def, ancla,
        ancla || E'\n                       ''botones'',    ecommerce.fn_botones_colores('
              || E'\n                                           s.boton_favorito_color, s.boton_carrito_color,'
              || E'\n                                           s.boton_whatsapp_color, s.boton_tarjeta_color),');

    EXECUTE def;
    RAISE NOTICE 'El listado del CRM ya trae los colores de los botones.';
END
$listar$;

-- ----------------------------------------------------------------------------
-- 5. LA PORTADA PÚBLICA
-- ----------------------------------------------------------------------------
-- `botones` va DENTRO de la rama de productos, no al lado del rótulo: el
-- rótulo y el alto los lleva cualquier sección, y unos botones de compra sólo
-- las de productos. Mandárselos a un banner sería ruido que alguien acabaría
-- intentando usar.
CREATE OR REPLACE FUNCTION ecommerce.fn_inicio_publico()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
AS $function$
    WITH visibles AS (
        SELECT s.clave, s.hasta, s.orden, s.producto_seccion_id,
               nullif(btrim(COALESCE(s.titulo, '')), '')    AS titulo,
               nullif(btrim(COALESCE(s.subtitulo, '')), '') AS subtitulo,
               ecommerce.fn_rotulo_estilo(s.rotulo_tamano, s.rotulo_color, s.rotulo_fuente) AS estilo,
               ecommerce.fn_botones_colores(s.boton_favorito_color, s.boton_carrito_color,
                                            s.boton_whatsapp_color, s.boton_tarjeta_color) AS botones,
               COALESCE(nullif(btrim(COALESCE(s.alto, '')), ''), 'normal') AS alto
          FROM ecommerce.inicio_secciones s
         WHERE s.activo AND ecommerce.fn_vigente(s.desde, s.hasta)
           AND ecommerce.fn_inicio_seccion_viva(s.producto_seccion_id)
    ),
    armadas AS (
        SELECT v.orden, v.titulo, v.subtitulo, v.estilo, v.alto,
               CASE
                   -- Las de productos van primero y se reconocen por a quién
                   -- apuntan: su clave (`seccion_7`) la fabrica el servidor y
                   -- no hay lista donde buscarla.
                   WHEN v.producto_seccion_id IS NOT NULL THEN
                        jsonb_build_object('clave', 'productos',
                            'id', v.producto_seccion_id,
                            'botones', v.botones,
                            'productos', ecommerce.fn_producto_seccion_publica(v.producto_seccion_id))
                   WHEN v.clave = 'banner_principal' THEN
                        jsonb_build_object('clave', v.clave,
                            'imagenes', COALESCE(ecommerce.fn_galerias_publica('inicio_banner') -> 'imagenes', '[]'::jsonb))
                   WHEN v.clave = 'banner_simple' THEN
                        jsonb_build_object('clave', v.clave,
                            'imagenes', COALESCE(ecommerce.fn_galerias_publica('inicio_banner_simple') -> 'imagenes', '[]'::jsonb))
                   WHEN v.clave = 'mosaico' THEN
                        jsonb_build_object('clave', v.clave,
                            'categorias', ecommerce.fn_categorias_promocion_publicas())
                   WHEN v.clave = 'categorias_destacadas' THEN
                        jsonb_build_object('clave', v.clave,
                            'categorias', ecommerce.fn_categorias_destacadas_publicas())
                   WHEN v.clave = 'marcas' THEN
                        jsonb_build_object('clave', v.clave,
                            'marcas', ecommerce.fn_marcas_publicas())
                   -- Las demás todavía no tienen de dónde sacar datos. Se
                   -- devuelven NULL y se caen en el filtro de abajo; la tienda
                   -- ni se entera.
                   ELSE NULL
               END AS seccion
          FROM visibles v
    )
    SELECT jsonb_build_object('secciones', COALESCE(jsonb_agg(
               -- El rótulo, su pinta y el alto se añaden aquí y no en cada
               -- rama: son de la sección, no de lo que la llena, y así no se
               -- olvidan en la siguiente que se traslade
               a.seccion || jsonb_build_object('titulo', a.titulo, 'subtitulo', a.subtitulo,
                                               'estilo', a.estilo, 'alto', a.alto)
               ORDER BY a.orden), '[]'::jsonb))
      FROM armadas a
     WHERE a.seccion IS NOT NULL
       AND (a.seccion -> 'imagenes'   IS NULL OR jsonb_array_length(a.seccion -> 'imagenes') > 0)
       AND (a.seccion -> 'categorias' IS NULL OR jsonb_array_length(a.seccion -> 'categorias') > 0)
       AND (a.seccion -> 'marcas'     IS NULL OR jsonb_array_length(a.seccion -> 'marcas') > 0)
       -- Una sección de productos vacía no se manda: dejaría su título y nada
       -- debajo, que es peor que no estar.
       AND (a.seccion -> 'productos'  IS NULL OR jsonb_array_length(a.seccion -> 'productos') > 0);
$function$;

-- ----------------------------------------------------------------------------
-- 6. COMPROBACIÓN
-- ----------------------------------------------------------------------------
DO $comprobar$
DECLARE
    v_id      bigint;
    v_clave   text;
    v_p       bigint;
    v_fila    jsonb;
    v_publica jsonb;
    v_vacios  jsonb;
    v_error   text := '(no falló)';
BEGIN
    SELECT p.id INTO v_p FROM inventarios.productos p
     WHERE p.deleted_at IS NULL AND p.activo ORDER BY p.id LIMIT 1;
    IF v_p IS NULL THEN
        RAISE NOTICE 'No hay productos activos con los que comprobar; las columnas están.';
        RETURN;
    END IF;

    BEGIN
        v_id    := (ecommerce.fn_producto_secciones_crear('ZZ colores ' || clock_timestamp())
                    -> 'data' ->> 'id')::bigint;
        v_clave := 'seccion_' || v_id;
        PERFORM ecommerce.fn_producto_seccion_agregar(v_id, jsonb_build_array(v_p));

        -- Recién creada: los cuatro en nulo, o sea «el de la tienda»
        SELECT x -> 'botones' INTO v_vacios
          FROM jsonb_array_elements(ecommerce.fn_inicio_listar() -> 'data') x
         WHERE x ->> 'clave' = v_clave;

        -- Se guardan los cuatro, uno de ellos SIN almohadilla y en mayúsculas
        PERFORM ecommerce.fn_inicio_seccion_guardar(v_clave, jsonb_build_object(
            'boton_favorito_color', '#112233',
            'boton_carrito_color',  'AABBCC',
            'boton_whatsapp_color', '#445566',
            'boton_tarjeta_color',  '#778899'));

        SELECT x -> 'botones' INTO v_fila
          FROM jsonb_array_elements(ecommerce.fn_inicio_listar() -> 'data') x
         WHERE x ->> 'clave' = v_clave;

        SELECT x -> 'botones' INTO v_publica
          FROM jsonb_array_elements(ecommerce.fn_inicio_publico() -> 'secciones') x
         WHERE (x ->> 'id')::bigint = v_id;

        -- Y que un color inventado NO entre
        BEGIN
            PERFORM ecommerce.fn_inicio_seccion_guardar(v_clave,
                        jsonb_build_object('boton_carrito_color', 'rojo oscuro'));
            v_error := '(entró un color que no es un color)';
        EXCEPTION WHEN SQLSTATE 'P0015' THEN
            v_error := SQLERRM;
        END;

        RAISE EXCEPTION 'deshacer' USING ERRCODE = 'P0099';
    EXCEPTION WHEN SQLSTATE 'P0099' THEN
        NULL;
    END;

    IF v_vacios IS NULL OR v_vacios <> '{"favorito": null, "carrito": null, "whatsapp": null, "tarjeta": null}'::jsonb THEN
        RAISE EXCEPTION 'Recién creada, los cuatro botones tendrían que estar sin color y están: %', v_vacios;
    END IF;
    IF v_fila IS NULL OR v_fila ->> 'favorito' <> '#112233' OR v_fila ->> 'whatsapp' <> '#445566'
       OR v_fila ->> 'tarjeta' <> '#778899' THEN
        RAISE EXCEPTION 'Los colores no se guardaron: %', v_fila;
    END IF;
    -- El que iba sin almohadilla y en mayúsculas sale normalizado
    IF v_fila ->> 'carrito' <> '#aabbcc' THEN
        RAISE EXCEPTION 'El color sin almohadilla tendría que quedar como #aabbcc y quedó: %',
              v_fila ->> 'carrito';
    END IF;
    IF v_publica IS DISTINCT FROM v_fila THEN
        RAISE EXCEPTION 'La tienda recibe otros colores que el CRM: % vs %', v_publica, v_fila;
    END IF;
    IF v_error = '(no falló)' OR v_error = '(entró un color que no es un color)' THEN
        RAISE EXCEPTION 'Un color inventado tendría que rebotar: %', v_error;
    END IF;
    IF EXISTS (SELECT 1 FROM ecommerce.inicio_secciones WHERE clave = v_clave) THEN
        RAISE EXCEPTION 'La sección de prueba se quedó en la portada';
    END IF;

    RAISE NOTICE 'Comprobado: los cuatro colores nacen vacíos, se guardan normalizados (AABBCC -> #aabbcc), llegan iguales a la tienda, y «%» rebota. No quedó nada.', v_error;
END
$comprobar$;

COMMIT;
