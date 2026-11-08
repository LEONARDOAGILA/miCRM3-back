-- ============================================================================
-- PIE: LAS REDES DEJAN DE SER UNA LISTA CERRADA Y GANAN TÍTULO
-- ============================================================================
-- Fecha: 2026-11-07
--
-- TRES CAMBIOS:
--
--  1. LA SECCIÓN TIENE TÍTULO. `config.titulo_redes`, que la tienda pinta
--     ENCIMA de los iconos, en el sitio donde hasta hoy iba el logotipo.
--
--  2. CADA ENLACE TRAE SU ICONO. Antes la fila era `{tipo, enlace, activo}` y
--     el `tipo` hacía de todo: era la red, era el nombre y era el dibujo. Por
--     eso la lista sólo podía tener las siete que la tienda sabía dibujar.
--     Ahora es `{icono, nombre, enlace, activo}`: se añaden las filas que haga
--     falta —Threads, Telegram, un teléfono— y cada una elige su dibujo de
--     entre los que la tienda tiene.
--
--  3. GUARDAR EL PIE YA NO BORRA LO QUE NO SE MANDÓ. `fn_pie_modificar`
--     escribía `config = validar(lo que llega)`, y como el validador devuelve
--     sólo lo que entiende, guardar las redes se llevaba por delante la
--     suscripción, la barra de abajo y la descripción de la marca. NADIE LO
--     HABÍA NOTADO porque esas tres no se editan todavía desde el CRM, pero
--     el primer «Guardar redes» las habría dejado en nada. Ahora se mezcla
--     con lo que ya hay y sólo se cambia lo que viene.
--
-- MIGRACIÓN DE LO GUARDADO: `tipo` se convierte en `icono` (se llamaban
-- igual: «facebook» era la red Y el dibujo) y el nombre bonito se saca de una
-- tabla de equivalencias. A `titulo_redes` se le pone «Síguenos» para que el
-- pie no se quede con un hueco donde estaba el logotipo; se cambia desde el
-- CRM como cualquier otro texto.
--
-- SE EJECUTA A MANO y se puede repetir: lo ya hecho no vuelve a hacerse.
--
--   psql -U postgres -d crm3 -f 2026-11-07_ecommerce_pie_redes_libres.sql
-- ============================================================================

BEGIN;

-- ----------------------------------------------------------------------------
-- 1. EL VALIDADOR
-- ----------------------------------------------------------------------------
-- DEVUELVE SÓLO LAS CLAVES QUE LE LLEGAN, no todas las que conoce: así quien
-- manda nada más las redes no toca el resto de la configuración. Lo que no
-- entiende lo ignora; mezclarlo es cosa de fn_pie_modificar.
CREATE OR REPLACE FUNCTION ecommerce.fn_pie_validar_config(p_config jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 IMMUTABLE
AS $function$
DECLARE
    v_salida jsonb := '{}'::jsonb;
    v_redes  jsonb;
    v_lista  jsonb := '[]'::jsonb;
    v_red    jsonb;
    v_activo boolean;
    v_icono  text;
    v_nombre text;
    v_enlace text;
BEGIN
    IF p_config IS NULL OR jsonb_typeof(p_config) <> 'object' THEN
        RAISE EXCEPTION 'La configuración del pie no tiene la forma esperada' USING ERRCODE = 'P0015';
    END IF;

    -- ---------- El título de la sección de redes ----------
    IF p_config ? 'titulo_redes' THEN
        v_salida := v_salida || jsonb_build_object('titulo_redes',
            ecommerce.fn_validar_texto(p_config ->> 'titulo_redes', 'El título de las redes', 60, false));
    END IF;

    -- ---------- Las redes ----------
    IF p_config ? 'redes' THEN
        v_redes := COALESCE(p_config -> 'redes', '[]'::jsonb);
        IF jsonb_typeof(v_redes) <> 'array' THEN
            RAISE EXCEPTION 'Las redes sociales deben venir en una lista' USING ERRCODE = 'P0015';
        END IF;

        FOR v_red IN SELECT * FROM jsonb_array_elements(v_redes) LOOP
            -- UNA FILA APAGADA PUEDE ESTAR A MEDIAS: se guarda lo escrito y se
            -- termina otro día. Encendida, se le exige todo, porque va a salir.
            v_activo := COALESCE((v_red -> 'activo') = 'true'::jsonb, false);

            v_icono := ecommerce.fn_validar_texto(v_red ->> 'icono', 'El icono del enlace', 30, v_activo);
            IF v_icono IS NOT NULL AND v_icono !~ '^[a-z0-9_-]+$' THEN
                RAISE EXCEPTION 'El icono «%» sólo admite letras minúsculas, números y guiones', v_icono
                      USING ERRCODE = 'P0015';
            END IF;

            -- El nombre no es decoración: es lo que se lee en voz alta sobre
            -- un enlace que por pantalla es sólo un dibujo.
            v_nombre := ecommerce.fn_validar_texto(v_red ->> 'nombre', 'El nombre del enlace', 40, v_activo);

            v_enlace := ecommerce.fn_validar_enlace(v_red ->> 'enlace',
                            format('El enlace «%s»', COALESCE(v_nombre, v_icono, 'sin nombre')), v_activo);

            v_lista := v_lista || jsonb_build_array(jsonb_build_object(
                'icono',  v_icono,
                'nombre', v_nombre,
                'enlace', v_enlace,
                'activo', v_activo));
        END LOOP;

        v_salida := v_salida || jsonb_build_object('redes', v_lista);
    END IF;

    RETURN v_salida;
END;
$function$;

-- ----------------------------------------------------------------------------
-- 2. GUARDAR MEZCLA, NO REEMPLAZA
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ecommerce.fn_pie_modificar(
    p_config jsonb,
    p_usuario_id bigint DEFAULT NULL::bigint,
    p_usuario_login character varying DEFAULT NULL::character varying,
    p_usuario_nombre character varying DEFAULT NULL::character varying,
    p_ip_address inet DEFAULT NULL::inet,
    p_user_agent text DEFAULT NULL::text,
    p_request_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'ecommerce', 'auditoria'
AS $function$
BEGIN
    PERFORM ecommerce.fn_contexto_auditoria('ecommerce.pie',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    -- `||` a nivel de clave: lo que viene manda, lo que no viene se queda.
    -- La pantalla edita las redes por un lado y mañana la suscripción por
    -- otro, y ninguna de las dos tiene por qué saber de la otra.
    UPDATE ecommerce.pie
       SET config = config || ecommerce.fn_pie_validar_config(p_config)
     WHERE id = 1;

    RETURN jsonb_build_object('success', true, 'message', 'Pie de página actualizado',
                              'data', (ecommerce.fn_pie_obtener() -> 'data'));
END;
$function$;

-- ----------------------------------------------------------------------------
-- 3. LO QUE YA ESTABA GUARDADO
-- ----------------------------------------------------------------------------
-- `tipo` -> `icono` + `nombre`. Sólo entra si todavía hay alguna fila con
-- `tipo`: a la segunda pasada no queda ninguna y no se toca nada.
DO $migrar$
DECLARE
    v_nombres jsonb := jsonb_build_object(
        'facebook', 'Facebook', 'x', 'X', 'instagram', 'Instagram',
        'linkedin', 'LinkedIn', 'tiktok', 'TikTok', 'youtube', 'YouTube',
        'whatsapp', 'WhatsApp');
    v_nuevas  jsonb;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM ecommerce.pie p,
                        jsonb_array_elements(COALESCE(p.config -> 'redes', '[]'::jsonb)) r
                    WHERE p.id = 1 AND r ? 'tipo') THEN
        RAISE NOTICE 'Las redes ya estaban en el formato nuevo.';
    ELSE
        SELECT COALESCE(jsonb_agg(jsonb_build_object(
                   'icono',  r ->> 'tipo',
                   'nombre', COALESCE(v_nombres ->> (r ->> 'tipo'), initcap(r ->> 'tipo')),
                   'enlace', r ->> 'enlace',
                   'activo', COALESCE((r -> 'activo') = 'true'::jsonb, false)) ORDER BY i), '[]'::jsonb)
          INTO v_nuevas
          FROM ecommerce.pie p,
               jsonb_array_elements(COALESCE(p.config -> 'redes', '[]'::jsonb)) WITH ORDINALITY AS t(r, i)
         WHERE p.id = 1;

        UPDATE ecommerce.pie SET config = config || jsonb_build_object('redes', v_nuevas) WHERE id = 1;
        RAISE NOTICE 'Redes pasadas al formato nuevo: %', jsonb_array_length(v_nuevas);
    END IF;
END;
$migrar$;

-- El título, sólo si no hay ninguno: la tienda se queda sin logotipo y con un
-- hueco en su sitio sería peor que un texto de arranque.
UPDATE ecommerce.pie
   SET config = config || jsonb_build_object('titulo_redes', 'Síguenos')
 WHERE id = 1
   AND nullif(btrim(COALESCE(config ->> 'titulo_redes', '')), '') IS NULL;

-- ----------------------------------------------------------------------------
-- 4. LO QUE VE LA TIENDA
-- ----------------------------------------------------------------------------
-- Del pie salen el título y las redes ENCENDIDAS, cada una con su dibujo y su
-- nombre. El «activo» no se manda: a la tienda no le dice nada.
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
            'config', jsonb_build_object(
                'titulo_redes', (SELECT config ->> 'titulo_redes' FROM ecommerce.pie WHERE id = 1),
                'redes', COALESCE((
                    SELECT jsonb_agg(jsonb_build_object(
                               'icono',  r ->> 'icono',
                               'nombre', r ->> 'nombre',
                               'enlace', r ->> 'enlace'))
                      FROM ecommerce.pie p, jsonb_array_elements(COALESCE(p.config -> 'redes', '[]'::jsonb)) r
                     WHERE p.id = 1 AND (r -> 'activo') = 'true'::jsonb), '[]'::jsonb)),
            'menu', '[]'::jsonb,
            'grupos', COALESCE((
                SELECT jsonb_agg(jsonb_build_object(
                           'titulo', c.titulo,
                           'imagen', CASE WHEN nullif(btrim(COALESCE(c.imagen, '')), '') IS NOT NULL
                                          THEN jsonb_build_object(
                                              'archivo',       c.imagen,
                                              'alt',           c.imagen_alt,
                                              'enlace',        c.imagen_enlace,
                                              'nueva_pestana', c.imagen_nueva_pestana)
                                     END,
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
-- COMPROBACIÓN (no cambia nada; si algo no cuadra, el COMMIT no llega)
-- ----------------------------------------------------------------------------
DO $comprobar$
DECLARE
    v_config  jsonb;
    v_publico jsonb;
    v_pie     jsonb;
    v_antes   jsonb;
    v_coló    boolean := false;
BEGIN
    SELECT config INTO v_config FROM ecommerce.pie WHERE id = 1;

    IF EXISTS (SELECT 1 FROM jsonb_array_elements(COALESCE(v_config -> 'redes', '[]'::jsonb)) r
                WHERE r ? 'tipo' OR NOT (r ? 'icono') OR NOT (r ? 'nombre')) THEN
        RAISE EXCEPTION 'Alguna red se quedó en el formato viejo';
    END IF;

    IF nullif(btrim(COALESCE(v_config ->> 'titulo_redes', '')), '') IS NULL THEN
        RAISE EXCEPTION 'El pie se quedó sin título de redes';
    END IF;

    -- Guardar SÓLO el título no puede llevarse las redes por delante
    v_antes  := ecommerce.fn_pie_validar_config(jsonb_build_object('titulo_redes', 'Prueba'));
    IF v_antes ? 'redes' THEN
        RAISE EXCEPTION 'El validador inventa redes que no le mandaron';
    END IF;

    -- Una fila apagada se guarda a medias; una encendida sin enlace, no
    v_antes := ecommerce.fn_pie_validar_config(
        '{"redes":[{"icono":"telefono","nombre":"","enlace":null,"activo":false}]}'::jsonb);
    IF jsonb_array_length(v_antes -> 'redes') <> 1 THEN
        RAISE EXCEPTION 'Una fila apagada y a medias debería poder guardarse';
    END IF;

    -- El aviso NO puede ir dentro del BEGIN: su propio error caería en el
    -- mismo EXCEPTION y la comprobación se daría por buena.
    BEGIN
        v_antes := ecommerce.fn_pie_validar_config(
            '{"redes":[{"icono":"telefono","nombre":"Llámanos","enlace":null,"activo":true}]}'::jsonb);
        v_coló := true;
    EXCEPTION WHEN sqlstate 'P0015' OR sqlstate 'P0001' THEN
        NULL;   -- es lo que tenía que pasar
    END;
    IF v_coló THEN
        RAISE EXCEPTION 'Una fila encendida sin enlace no debería pasar';
    END IF;

    -- Y la tienda recibe el título y los dibujos
    v_publico := ecommerce.fn_secciones_publicas();
    SELECT s INTO v_pie FROM jsonb_array_elements(v_publico) s WHERE s ->> 'clave' = 'footer';
    IF v_pie -> 'config' ->> 'titulo_redes' IS NULL THEN
        RAISE EXCEPTION 'La tienda no recibe el título de las redes';
    END IF;
    IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_pie -> 'config' -> 'redes') r
                WHERE NOT (r ? 'icono') OR NOT (r ? 'nombre')) THEN
        RAISE EXCEPTION 'A la tienda le llega alguna red sin dibujo o sin nombre';
    END IF;

    RAISE NOTICE 'Comprobado: «%», % red(es) guardadas y % encendidas en la tienda.',
        v_config ->> 'titulo_redes',
        jsonb_array_length(COALESCE(v_config -> 'redes', '[]'::jsonb)),
        jsonb_array_length(v_pie -> 'config' -> 'redes');
END;
$comprobar$;

COMMIT;
