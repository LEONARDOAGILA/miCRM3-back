-- ============================================================================
-- PIE: EL TÍTULO DE LAS REDES ELIGE TAMAÑO, COLOR Y LETRA
-- ============================================================================
-- Fecha: 2026-11-07
--
-- El título que hoy ocupa el sitio del logotipo (2026-11-07_ecommerce_pie_
-- redes_libres.sql) se pinta con el mismo aspecto que los títulos de las demás
-- columnas. Ahora se le puede cambiar: `config.titulo_redes_estilo`, con
--
--     { "tamano": 16, "color": "#ffffff", "fuente": "titulos" }
--
-- LOS TRES PUEDEN IR EN NULO, y eso NO es «no tiene estilo»: es «el que la
-- tienda le dé». Así el que no se toca sigue acompañando al diseño cuando el
-- diseño cambie, en vez de quedarse clavado en el valor de hoy.
--
-- LA LETRA NO ES UN NOMBRE SINO UNA DE LAS TRES DE LA TIENDA: «titulos»
-- (Poppins), «texto» (Inter) o «deportiva» (Barlow Condensed). Guardar aquí
-- «Georgia» sería pedirle al navegador del cliente una letra que nadie le ha
-- mandado: saldría la que tuviera a mano, que no es ninguna de las tres.
--
-- SE EJECUTA A MANO y se puede repetir.
--
--   psql -U postgres -d crm3 -f 2026-11-07_ecommerce_pie_titulo_redes_estilo.sql
-- ============================================================================

BEGIN;

-- ----------------------------------------------------------------------------
-- 1. EL VALIDADOR
-- ----------------------------------------------------------------------------
-- El de redes-libres con el bloque del estilo añadido. Sigue devolviendo SÓLO
-- las claves que le llegan.
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
    v_estilo jsonb;
BEGIN
    IF p_config IS NULL OR jsonb_typeof(p_config) <> 'object' THEN
        RAISE EXCEPTION 'La configuración del pie no tiene la forma esperada' USING ERRCODE = 'P0015';
    END IF;

    -- ---------- El título de la sección de redes ----------
    IF p_config ? 'titulo_redes' THEN
        v_salida := v_salida || jsonb_build_object('titulo_redes',
            ecommerce.fn_validar_texto(p_config ->> 'titulo_redes', 'El título de las redes', 60, false));
    END IF;

    -- ---------- Cómo se pinta ese título ----------
    -- Los tres en nulo valen: «el que la tienda le dé».
    IF p_config ? 'titulo_redes_estilo' THEN
        v_estilo := COALESCE(p_config -> 'titulo_redes_estilo', '{}'::jsonb);
        IF jsonb_typeof(v_estilo) <> 'object' THEN
            RAISE EXCEPTION 'El estilo del título no tiene la forma esperada' USING ERRCODE = 'P0015';
        END IF;

        v_salida := v_salida || jsonb_build_object('titulo_redes_estilo', jsonb_build_object(
            -- Por debajo de 10 no se lee y por encima de 60 no es un título de
            -- columna, es un cartel: el pie se descuadra entero.
            'tamano', ecommerce.fn_validar_entero(v_estilo ->> 'tamano', 'El tamaño del título', 10, 60),
            'color',  ecommerce.fn_validar_color(v_estilo ->> 'color', 'El color del título'),
            -- Las tres letras que la tienda carga. Ver la cabecera.
            'fuente', ecommerce.fn_validar_opcion(v_estilo ->> 'fuente',
                          ARRAY['titulos', 'texto', 'deportiva'], 'La letra del título')));
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
-- 2. LO QUE VE LA TIENDA
-- ----------------------------------------------------------------------------
-- El bloque del pie gana el estilo. El resto queda igual que en
-- 2026-11-07_ecommerce_pie_redes_libres.sql.
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
                'titulo_redes_estilo', (SELECT COALESCE(config -> 'titulo_redes_estilo', '{}'::jsonb)
                                          FROM ecommerce.pie WHERE id = 1),
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
-- 3. EL ESTILO DE ARRANQUE
-- ----------------------------------------------------------------------------
-- Los tres en nulo: el título sigue viéndose exactamente igual que hasta
-- ahora. Se crea la clave para que la pantalla no tenga que inventársela.
UPDATE ecommerce.pie
   SET config = config || jsonb_build_object('titulo_redes_estilo',
                   jsonb_build_object('tamano', NULL, 'color', NULL, 'fuente', NULL))
 WHERE id = 1
   AND NOT (config ? 'titulo_redes_estilo');

-- ----------------------------------------------------------------------------
-- COMPROBACIÓN (no cambia nada; si algo no cuadra, el COMMIT no llega)
-- ----------------------------------------------------------------------------
DO $comprobar$
DECLARE
    v_config jsonb;
    v_pie    jsonb;
    v_prueba jsonb;
    v_coló   boolean := false;
BEGIN
    SELECT config INTO v_config FROM ecommerce.pie WHERE id = 1;
    IF NOT (v_config ? 'titulo_redes_estilo') THEN
        RAISE EXCEPTION 'El pie se quedó sin la clave del estilo';
    END IF;

    -- Los tres valores, de ida y vuelta
    v_prueba := ecommerce.fn_pie_validar_config(
        '{"titulo_redes_estilo":{"tamano":"24","color":"FFEE00","fuente":"deportiva"}}'::jsonb);
    IF (v_prueba -> 'titulo_redes_estilo' ->> 'tamano') <> '24'
       OR (v_prueba -> 'titulo_redes_estilo' ->> 'color') <> '#ffee00'
       OR (v_prueba -> 'titulo_redes_estilo' ->> 'fuente') <> 'deportiva' THEN
        RAISE EXCEPTION 'El estilo no vuelve como se mandó: %', v_prueba;
    END IF;

    -- Y guardar el estilo no se lleva las redes por delante
    IF v_prueba ? 'redes' THEN
        RAISE EXCEPTION 'El validador inventa redes que no le mandaron';
    END IF;

    -- Una letra que la tienda no carga no pasa
    BEGIN
        v_prueba := ecommerce.fn_pie_validar_config(
            '{"titulo_redes_estilo":{"fuente":"georgia"}}'::jsonb);
        v_coló := true;
    EXCEPTION WHEN sqlstate 'P0015' THEN
        NULL;   -- es lo que tenía que pasar
    END;
    IF v_coló THEN
        RAISE EXCEPTION 'Aceptó una letra que la tienda no tiene';
    END IF;

    -- Y a la tienda le llega
    SELECT s INTO v_pie FROM jsonb_array_elements(ecommerce.fn_secciones_publicas()) s
     WHERE s ->> 'clave' = 'footer';
    IF NOT (v_pie -> 'config' ? 'titulo_redes_estilo') THEN
        RAISE EXCEPTION 'La tienda no recibe el estilo del título';
    END IF;

    RAISE NOTICE 'Comprobado: «%» con estilo %.',
        v_config ->> 'titulo_redes', v_config -> 'titulo_redes_estilo';
END;
$comprobar$;

COMMIT;
