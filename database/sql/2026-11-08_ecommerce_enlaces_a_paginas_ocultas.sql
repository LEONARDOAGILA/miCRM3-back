-- ============================================================================
-- UN ENLACE A UNA PÁGINA OCULTA NO SALE EN LA TIENDA
-- ============================================================================
-- EL PROBLEMA. Una página informativa se apaga desde su pantalla, pero el
-- enlace del pie que lleva a ella tiene SU PROPIO interruptor y no sabe nada
-- de la página. Apagar la página dejaba el enlace en el pie de la tienda,
-- llevando a una página que ya no se puede ver. Pasaba igual con una página
-- mandada a la papelera, y con el menú del encabezado, que guarda esas mismas
-- claves en sus enlaces.
--
-- CÓMO SE ARREGLA. No cambiando el interruptor del enlace —eso sería tocarle
-- datos a quien administra la tienda, y además se podría volver a encender y
-- el problema volvería—, sino PREGUNTANDO POR LA PÁGINA AL PINTAR:
--
--   el enlace se ve  =  el enlace está activo  Y  su página se puede ver
--
-- Así los dos interruptores siguen significando lo suyo —«quiero este enlace
-- aquí» y «esta página está publicada»— y, sobre todo, es SIMÉTRICO: se
-- vuelve a encender la página y el enlace reaparece solo, sin tener que
-- acordarse de nada.
--
-- SÓLO MIRA LOS ENLACES A PÁGINAS. Un enlace a /shop, a una marca o a un sitio
-- de fuera no se toca: la regla es para `/paginas/{clave}` y nada más.
-- `/documentos` tampoco, que es la lista y ya se filtra sola.
--
-- Y EL CRM LO DICE. El pie, al administrarlo, marca esos enlaces con
-- `pagina_oculta`, para que se vea por qué no sale en la tienda en vez de
-- tener que adivinarlo.
--
-- Es idempotente: sólo reemplaza funciones.
-- ============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. LA PREGUNTA, EN UN SOLO SITIO
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ecommerce.fn_enlace_a_pagina_visible(p_enlace text)
RETURNS boolean
LANGUAGE sql
STABLE
AS $function$
    SELECT CASE
        -- No lleva a una página informativa: no es cosa de esta regla.
        -- También entra por aquí el enlace vacío de un menú con desplegables.
        WHEN COALESCE(btrim(p_enlace), '') !~ '^/paginas/[A-Za-z0-9_-]+/?$' THEN true
        ELSE EXISTS (
            SELECT 1
              FROM ecommerce.paginas_informativas p
             WHERE p.clave = regexp_replace(btrim(p_enlace), '^/paginas/([A-Za-z0-9_-]+)/?$', '\1')
               AND p.activo
               AND p.deleted_at IS NULL)
    END;
$function$;

COMMENT ON FUNCTION ecommerce.fn_enlace_a_pagina_visible(text) IS
    'false sólo si el enlace lleva a una página informativa apagada, en la papelera o inexistente. Todo lo demás, true.';

-- ---------------------------------------------------------------------------
-- 2. LA TIENDA
-- ---------------------------------------------------------------------------
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
                    WHERE h.padre_id = p.id AND h.activo AND h.deleted_at IS NULL
                      -- Un hijo que lleva a una página oculta no se enseña
                      AND ecommerce.fn_enlace_a_pagina_visible(h.enlace)), '[]'::jsonb) AS hijos
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
                 -- Con hijos se queda (su enlace ni se usa); sin hijos, sólo si
                 -- lleva a alguna parte que se pueda ver
                 WHERE m.hijos <> '[]'::jsonb
                    OR (m.enlace IS NOT NULL AND ecommerce.fn_enlace_a_pagina_visible(m.enlace))), '[]'::jsonb),
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
                                WHERE l.columna_id = c.id AND l.activo AND l.deleted_at IS NULL
                                  -- Lo mismo abajo: sin página que enseñar, no hay enlace
                                  AND ecommerce.fn_enlace_a_pagina_visible(l.enlace)), '[]'::jsonb))
                           ORDER BY c.orden, c.id)
                  FROM ecommerce.pie_columnas c
                 WHERE c.activo AND c.deleted_at IS NULL), '[]'::jsonb))
    );
$function$;

-- ---------------------------------------------------------------------------
-- 3. EL CRM: QUE SE VEA POR QUÉ
-- ---------------------------------------------------------------------------
-- `pagina_oculta` es sólo para enseñarlo: el enlace sigue con su `activo` tal
-- como lo dejaron. Lo que decide si se ve en la tienda es la función de arriba.
DO $pie$
DECLARE
    v_def text;
BEGIN
    SELECT pg_get_functiondef(p.oid) INTO v_def
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'ecommerce' AND p.proname = 'fn_pie_obtener';

    IF v_def IS NULL THEN
        RAISE EXCEPTION 'No existe ecommerce.fn_pie_obtener' USING ERRCODE = 'P0015';
    END IF;

    IF v_def LIKE '%pagina_oculta%' THEN
        RAISE NOTICE 'fn_pie_obtener ya avisaba de las páginas ocultas.';
        RETURN;
    END IF;

    v_def := replace(v_def,
'                                          ''orden'', l.orden, ''activo'', l.activo)',
'                                          ''orden'', l.orden, ''activo'', l.activo,
                                          ''pagina_oculta'', NOT ecommerce.fn_enlace_a_pagina_visible(l.enlace))');

    IF v_def NOT LIKE '%pagina_oculta%' THEN
        RAISE EXCEPTION 'La lista de enlaces de fn_pie_obtener no es la esperada: revísala a mano'
            USING ERRCODE = 'P0015';
    END IF;

    EXECUTE v_def;
    RAISE NOTICE 'fn_pie_obtener: los enlaces dicen si su página está oculta.';
END;
$pie$;

-- ---------------------------------------------------------------------------
-- COMPROBACIÓN
-- ---------------------------------------------------------------------------
-- Se apaga una página DE VERDAD y se mira la tienda, todo dentro de esta misma
-- transacción: al terminar queda como estaba, porque lo único que se guarda
-- son las funciones.
DO $comprobar$
DECLARE
    v_clave text;
    v_id    bigint;
    v_antes integer;
    v_despues integer;
    v_crm   integer;
BEGIN
    -- La regla, en seco
    IF NOT ecommerce.fn_enlace_a_pagina_visible('/shop') THEN
        RAISE EXCEPTION 'Un enlace que no es a una página debería pasar siempre' USING ERRCODE = 'P0015';
    END IF;
    IF NOT ecommerce.fn_enlace_a_pagina_visible(NULL) THEN
        RAISE EXCEPTION 'Un enlace vacío (menú con desplegables) debería pasar' USING ERRCODE = 'P0015';
    END IF;
    IF ecommerce.fn_enlace_a_pagina_visible('/paginas/no_existe_esta') THEN
        RAISE EXCEPTION 'Un enlace a una página inexistente no debería pasar' USING ERRCODE = 'P0015';
    END IF;

    -- Una página CUALQUIERA que tenga enlaces encendidos en el pie. Da igual
    -- cómo esté ella: se prueban los dos estados y se deshacen los dos.
    SELECT p.clave, p.id INTO v_clave, v_id
      FROM ecommerce.paginas_informativas p
     WHERE p.deleted_at IS NULL
       AND EXISTS (SELECT 1 FROM ecommerce.pie_enlaces l
                    WHERE l.deleted_at IS NULL AND l.activo
                      AND l.enlace = '/paginas/' || p.clave)
     ORDER BY p.id
     LIMIT 1;

    IF v_clave IS NULL THEN
        RAISE NOTICE 'Comprobado: la regla funciona en seco. (Ahora mismo ninguna página tiene enlaces en el pie, así que la prueba de encender y apagar se salta.)';
        RETURN;
    END IF;

    -- SE TOCA Y SE DESHACE EN EL SITIO. El bloque entero se cancela con un
    -- error propio, y con él se van los UPDATE: la página se queda como
    -- estaba, sin tocarle el `updated_at` ni dejar rastro en la auditoría. Lo
    -- que se contó dentro SÍ se conserva: una variable de plpgsql no se
    -- deshace con la transacción.
    BEGIN
        -- Encendida: sus enlaces TIENEN que salir
        UPDATE ecommerce.paginas_informativas SET activo = true WHERE id = v_id;
        SELECT count(*) INTO v_antes
          FROM jsonb_array_elements(ecommerce.fn_secciones_publicas()) s,
               jsonb_array_elements(COALESCE(s -> 'grupos', '[]'::jsonb)) g,
               jsonb_array_elements(COALESCE(g -> 'items', '[]'::jsonb)) i
         WHERE i ->> 'enlace' = '/paginas/' || v_clave;

        -- Apagada: no tiene que salir ninguno
        UPDATE ecommerce.paginas_informativas SET activo = false WHERE id = v_id;
        SELECT count(*) INTO v_despues
          FROM jsonb_array_elements(ecommerce.fn_secciones_publicas()) s,
               jsonb_array_elements(COALESCE(s -> 'grupos', '[]'::jsonb)) g,
               jsonb_array_elements(COALESCE(g -> 'items', '[]'::jsonb)) i
         WHERE i ->> 'enlace' = '/paginas/' || v_clave;

        -- Y el CRM tiene que decir por qué
        SELECT count(*) INTO v_crm
          FROM jsonb_array_elements(ecommerce.fn_pie_obtener() -> 'data' -> 'columnas') c,
               jsonb_array_elements(COALESCE(c -> 'enlaces', '[]'::jsonb)) l
         WHERE l ->> 'enlace' = '/paginas/' || v_clave AND (l -> 'pagina_oculta') = 'true'::jsonb;

        RAISE EXCEPTION 'deshacer la prueba' USING ERRCODE = 'P0100';
    EXCEPTION WHEN sqlstate 'P0100' THEN
        NULL;   -- justo lo que se quería: los UPDATE quedan deshechos
    END;

    IF v_antes = 0 THEN
        RAISE EXCEPTION 'Encendida, la página «%» no sacaba ningún enlace en el pie: la prueba no vale', v_clave
            USING ERRCODE = 'P0015';
    END IF;
    IF v_despues <> 0 THEN
        RAISE EXCEPTION 'Apagada la página «%», sus % enlace(s) siguen saliendo en el pie', v_clave, v_despues
            USING ERRCODE = 'P0015';
    END IF;
    IF v_crm = 0 THEN
        RAISE EXCEPTION 'El CRM no está avisando de que la página «%» está oculta', v_clave
            USING ERRCODE = 'P0015';
    END IF;

    RAISE NOTICE 'Comprobado con «%»: encendida salen % enlace(s) en el pie; apagada, ninguno, y el CRM lo avisa en % de ellos.',
                 v_clave, v_antes, v_crm;
END;
$comprobar$;

COMMIT;
