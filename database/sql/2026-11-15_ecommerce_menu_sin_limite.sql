-- ============================================================================
-- EL MENÚ DE LA TIENDA SE QUEDA SIN LÍMITE DE NIVELES
-- ============================================================================
-- El menú del encabezado eran DOS niveles: enlaces principales y, colgando de
-- ellos, los de su desplegable. Punto. La tabla siempre pudo con más —`padre_id`
-- apunta a la misma tabla—, pero las funciones lo prohibían:
--
--   · `guardar` exigía que el padre fuese un principal;
--   · `eliminar` sólo se llevaba a los hijos directos;
--   · y el árbol que recibe la tienda estaba escrito a dos niveles.
--
-- Ahora un enlace puede colgar de cualquier otro, tan hondo como haga falta.
--
-- ----------------------------------------------------------------------------
-- QUÉ CAMBIA
-- ----------------------------------------------------------------------------
-- 1. `fn_encabezado_enlaces_json`: el CRM recibe el árbol APLANADO, en orden y
--    con el `nivel` de cada uno, que es lo que come una rejilla (ag-Grid
--    Community no trae árbol: se pinta la sangría y se pliega a mano, igual
--    que en Seguridad → Menús y en las categorías).
-- 2. `fn_encabezado_enlaces_guardar`: el padre puede ser cualquiera, y la
--    dirección pasa a ser opcional en todos los niveles.
-- 3. `fn_encabezado_enlaces_eliminar`: se lleva la RAMA entera.
-- 4. `fn_encabezado_enlaces_mover`, nueva: cambiar de padre y de sitio con un
--    arrastre, sin ciclos y renumerando a los hermanos de los dos lados.
-- 5. `fn_encabezado_menu_publico`, nueva y recursiva: el árbol que viaja a la
--    tienda, con los niveles que tenga.
--
-- LO QUE NO CAMBIA: un enlace con hijos no lleva a ningún sitio —sólo abre su
-- desplegable—, uno sin hijos y sin dirección no se enseña, y el DESTACADO
-- sigue siendo cosa de los principales, que es donde está la barra en la que
-- sale la píldora.
--
-- ----------------------------------------------------------------------------
-- SE EJECUTA A MANO. Para ensayar sin guardar, cambiar el COMMIT del final por
-- ROLLBACK; la comprobación de abajo arma un menú de cuatro niveles y lo
-- deshace, así que tampoco deja rastro al ejecutarla de verdad.
-- ============================================================================

BEGIN;

-- ---------- 1. El CRM recibe el árbol aplanado ----------
--
-- APLANADO Y NO ANIDADO porque lo pinta una REJILLA: cada enlace es una fila
-- con su `nivel` para la sangría y su `hijos` para saber si lleva el +/-.
-- Anidado habría que volver a aplanarlo en la pantalla, y ahí es donde se
-- pierde el orden.
--
-- EL ORDEN ES EL DEL ÁRBOL, no el de la tabla: cada rama viaja detrás de su
-- padre. Se consigue con un camino de «orden-id» por nivel, rellenado con
-- ceros para que 10 no vaya antes que 2.
CREATE OR REPLACE FUNCTION ecommerce.fn_encabezado_enlaces_json()
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
AS $function$
    WITH RECURSIVE arbol AS (
        SELECT e.id, e.padre_id, e.texto, e.enlace, e.icono, e.nueva_pestana,
               e.orden, e.activo, e.destacado, 0 AS nivel,
               ARRAY[lpad(e.orden::text, 6, '0') || '-' || lpad(e.id::text, 12, '0')] AS camino
          FROM ecommerce.encabezado_enlaces e
         WHERE e.padre_id IS NULL AND e.deleted_at IS NULL
        UNION ALL
        SELECT h.id, h.padre_id, h.texto, h.enlace, h.icono, h.nueva_pestana,
               h.orden, h.activo, h.destacado, a.nivel + 1,
               a.camino || (lpad(h.orden::text, 6, '0') || '-' || lpad(h.id::text, 12, '0'))
          FROM ecommerce.encabezado_enlaces h
          JOIN arbol a ON h.padre_id = a.id
         WHERE h.deleted_at IS NULL
    )
    -- El árbol completo, apagados incluidos: esto es la pantalla de
    -- administración, no la tienda. Lo de ocultar pasa en fn_secciones_publicas.
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'id',            a.id,
               'padre_id',      a.padre_id,
               -- El texto del padre, para decir de dónde cuelga sin tener que
               -- buscarlo en la pantalla
               'padre',         (SELECT p.texto FROM ecommerce.encabezado_enlaces p WHERE p.id = a.padre_id),
               'texto',         a.texto,
               'enlace',        a.enlace,
               'icono',         a.icono,
               'nueva_pestana', a.nueva_pestana,
               'orden',         a.orden,
               'activo',        a.activo,
               -- Sólo los principales pueden ir destacados: dentro de un
               -- desplegable no hay barra donde poner una píldora
               'destacado',     a.destacado,
               'nivel',         a.nivel,
               -- CUÁNTOS CUELGAN DE ÉL, no quiénes: es lo que necesita la
               -- rejilla para pintar el +/- y para avisar al borrarlo
               'hijos',         (SELECT count(*) FROM ecommerce.encabezado_enlaces c
                                  WHERE c.padre_id = a.id AND c.deleted_at IS NULL))
           ORDER BY a.camino), '[]'::jsonb)
      FROM arbol a;
$function$;

COMMENT ON FUNCTION ecommerce.fn_encabezado_enlaces_json() IS
    'El menú del encabezado aplanado y en orden de árbol, con nivel y número de hijos: lo que come la rejilla del CRM.';

-- ---------- 2. Guardar, sin el límite de dos niveles ----------
CREATE OR REPLACE FUNCTION ecommerce.fn_encabezado_enlaces_guardar(p_id bigint, p_padre_id bigint, p_texto character varying, p_enlace character varying, p_icono character varying, p_activo boolean, p_nueva_pestana boolean, p_destacado boolean, p_usuario_id bigint DEFAULT NULL::bigint, p_usuario_login character varying DEFAULT NULL::character varying, p_usuario_nombre character varying DEFAULT NULL::character varying, p_ip_address inet DEFAULT NULL::inet, p_user_agent text DEFAULT NULL::text, p_request_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'ecommerce', 'auditoria'
AS $function$
DECLARE
    v_id     bigint := p_id;
    v_texto  text;
    v_enlace text;
    v_icono  text;
    v_padre  bigint := p_padre_id;
    v_nuevo  boolean := p_id IS NULL;
    v_destacado boolean;
BEGIN
    PERFORM ecommerce.fn_contexto_auditoria('ecommerce.encabezado_enlaces',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    v_texto  := ecommerce.fn_validar_texto(p_texto, 'El texto del enlace', 60, true);
    v_enlace := ecommerce.fn_validar_enlace(p_enlace, 'El enlace');
    v_icono  := ecommerce.fn_validar_texto(p_icono, 'El icono', 40);

    IF v_icono IS NOT NULL AND v_icono !~ '^[a-z0-9-]+$' THEN
        RAISE EXCEPTION 'El icono sólo admite letras minúsculas, números y guiones' USING ERRCODE = 'P0015';
    END IF;

    IF NOT v_nuevo THEN
        -- El padre no se cambia al modificar: mover un enlace de sitio es
        -- arrastrarlo, y mezclarlo aquí dejaría dos caminos para lo mismo.
        SELECT padre_id INTO v_padre FROM ecommerce.encabezado_enlaces
         WHERE id = p_id AND deleted_at IS NULL;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'El enlace no existe' USING ERRCODE = 'P0013';
        END IF;
    END IF;

    -- DESTACADO ES SÓLO DE LOS PRINCIPALES: es una píldora al final de la
    -- barra roja, y dentro de un desplegable no hay barra donde ponerla.
    v_destacado := COALESCE(p_destacado, false) AND v_padre IS NULL;

    -- EL ÁRBOL YA NO TIENE DOS NIVELES: un enlace puede colgar de cualquier
    -- otro, al fondo que haga falta. Lo único que se mira es que el padre
    -- exista; que no se meta dentro de sí mismo lo mira `mover`, que es por
    -- donde se cambia de padre.
    IF v_padre IS NOT NULL THEN
        IF NOT EXISTS (SELECT 1 FROM ecommerce.encabezado_enlaces
                        WHERE id = v_padre AND deleted_at IS NULL) THEN
            RAISE EXCEPTION 'El enlace del que debería colgar no existe' USING ERRCODE = 'P0016';
        END IF;
    END IF;

    -- LA DIRECCIÓN ES OPCIONAL EN TODOS LOS NIVELES, y antes sólo lo era en
    -- los principales. Con el árbol sin límite hace falta: «MARCAS → Motos →
    -- Honda» se arma de arriba abajo, y «Motos» nace sin hijos todavía, así
    -- que exigirle dirección era impedir construirlo. Un enlace sin hijos y
    -- sin dirección no se enseña en la tienda, y la rejilla del CRM lo dice
    -- en su fila.

    IF v_nuevo THEN
        INSERT INTO ecommerce.encabezado_enlaces
               (padre_id, texto, enlace, icono, activo, nueva_pestana, destacado, orden)
        VALUES (v_padre, v_texto, v_enlace, v_icono,
                COALESCE(p_activo, true),
                ecommerce.fn_nueva_pestana(v_enlace, p_nueva_pestana),
                v_destacado,
                (SELECT COALESCE(max(orden), 0) + 1 FROM ecommerce.encabezado_enlaces
                  WHERE padre_id IS NOT DISTINCT FROM v_padre AND deleted_at IS NULL))
        RETURNING id INTO v_id;
    ELSE
        UPDATE ecommerce.encabezado_enlaces
           SET texto = v_texto, enlace = v_enlace, icono = v_icono,
               activo = COALESCE(p_activo, true),
               nueva_pestana = ecommerce.fn_nueva_pestana(v_enlace, p_nueva_pestana),
               destacado = v_destacado
         WHERE id = v_id;
    END IF;

    RETURN jsonb_build_object('success', true,
        'message', CASE WHEN v_nuevo THEN 'Enlace creado' ELSE 'Enlace actualizado' END,
        'data', (ecommerce.fn_encabezado_obtener() -> 'data'));
END;
$function$;

-- ---------- 3. Borrar se lleva la rama entera ----------
CREATE OR REPLACE FUNCTION ecommerce.fn_encabezado_enlaces_eliminar(p_id bigint, p_usuario_id bigint DEFAULT NULL::bigint, p_usuario_login character varying DEFAULT NULL::character varying, p_usuario_nombre character varying DEFAULT NULL::character varying, p_ip_address inet DEFAULT NULL::inet, p_user_agent text DEFAULT NULL::text, p_request_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'ecommerce', 'auditoria'
AS $function$
DECLARE
    v_texto text;
    v_fecha timestamptz := CURRENT_TIMESTAMP;
    v_hijos integer;
BEGIN
    PERFORM ecommerce.fn_contexto_auditoria('ecommerce.encabezado_enlaces',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    SELECT texto INTO v_texto FROM ecommerce.encabezado_enlaces
     WHERE id = p_id AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'El enlace no existe' USING ERRCODE = 'P0013';
    END IF;

    -- LA RAMA ENTERA se va con él, a cualquier profundidad: dejar a los
    -- nietos colgando de un padre que ya no está los haría invisibles sin
    -- estar borrados. Antes sólo se llevaba a los hijos directos porque el
    -- árbol era de dos niveles y no había nietos.
    WITH RECURSIVE rama AS (
        SELECT id FROM ecommerce.encabezado_enlaces
         WHERE padre_id = p_id AND deleted_at IS NULL
        UNION ALL
        SELECT h.id FROM ecommerce.encabezado_enlaces h
          JOIN rama r ON h.padre_id = r.id
         WHERE h.deleted_at IS NULL
    )
    UPDATE ecommerce.encabezado_enlaces e
       SET deleted_at = v_fecha, deleted_by = p_usuario_login
      FROM rama
     WHERE e.id = rama.id;
    GET DIAGNOSTICS v_hijos = ROW_COUNT;

    UPDATE ecommerce.encabezado_enlaces
       SET deleted_at = v_fecha, deleted_by = p_usuario_login WHERE id = p_id;

    RETURN jsonb_build_object('success', true,
        'message', CASE v_hijos
                       WHEN 0 THEN format('«%s» va a la papelera', v_texto)
                       WHEN 1 THEN format('«%s» va a la papelera con el enlace que colgaba de él', v_texto)
                       ELSE format('«%s» va a la papelera con los %s enlaces que colgaban de él', v_texto, v_hijos) END,
        'data', (ecommerce.fn_encabezado_obtener() -> 'data'));
END;
$function$;

-- ---------- 4. Mover: de padre y de sitio, con un arrastre ----------
--
-- MISMO TRATO QUE EN SEGURIDAD → MENÚS (seguridad.fn_menus_mover), del que
-- está copiado, menos una cosa: AQUÍ NO HAY NIVEL MÁXIMO. Allí el menú del
-- CRM se pinta en una barra lateral de tres niveles; éste es el de la tienda
-- y se despliega hacia un lado, así que lo que pueda con él es cosa del
-- diseño, no de la base.
--
-- `p_antes_de` es el hermano DELANTE del cual se coloca; NULL lo deja al final.
CREATE OR REPLACE FUNCTION ecommerce.fn_encabezado_enlaces_mover(
    p_id             bigint,
    p_padre_id       bigint      DEFAULT NULL,
    p_antes_de       bigint      DEFAULT NULL,
    p_usuario_id     bigint      DEFAULT NULL,
    p_usuario_login  character varying DEFAULT NULL,
    p_usuario_nombre character varying DEFAULT NULL,
    p_ip_address     inet        DEFAULT NULL,
    p_user_agent     text        DEFAULT NULL,
    p_request_id     uuid        DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'ecommerce', 'auditoria'
AS $function$
DECLARE
    v_padre_actual bigint;
    v_texto        text;
    v_pos          integer;
    v_i            integer := 0;
    v_fila         record;
BEGIN
    PERFORM ecommerce.fn_contexto_auditoria('ecommerce.encabezado_enlaces',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    SELECT padre_id, texto INTO v_padre_actual, v_texto
      FROM ecommerce.encabezado_enlaces WHERE id = p_id AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'El enlace no existe' USING ERRCODE = 'P0013';
    END IF;

    IF p_padre_id IS NOT NULL THEN
        IF p_padre_id = p_id THEN
            RAISE EXCEPTION 'Un enlace no puede colgar de sí mismo' USING ERRCODE = 'P0015';
        END IF;
        IF NOT EXISTS (SELECT 1 FROM ecommerce.encabezado_enlaces
                        WHERE id = p_padre_id AND deleted_at IS NULL) THEN
            RAISE EXCEPTION 'El enlace del que debería colgar no existe' USING ERRCODE = 'P0016';
        END IF;
        -- EL DESTINO NO PUEDE COLGAR DEL QUE SE MUEVE: sería una rama suelta,
        -- fuera del menú y sin manera de volver a sacarla
        IF EXISTS (
            WITH RECURSIVE rama AS (
                SELECT id FROM ecommerce.encabezado_enlaces
                 WHERE padre_id = p_id AND deleted_at IS NULL
                UNION ALL
                SELECT h.id FROM ecommerce.encabezado_enlaces h
                  JOIN rama r ON h.padre_id = r.id
                 WHERE h.deleted_at IS NULL
            )
            SELECT 1 FROM rama WHERE rama.id = p_padre_id
        ) THEN
            RAISE EXCEPTION 'No se puede meter «%» dentro de algo que cuelga de él', v_texto
                  USING ERRCODE = 'P0015';
        END IF;
    END IF;

    -- Dentro de un desplegable no hay barra donde poner la píldora: lo que
    -- deja de ser principal deja de estar destacado
    UPDATE ecommerce.encabezado_enlaces
       SET padre_id = p_padre_id,
           destacado = destacado AND p_padre_id IS NULL
     WHERE id = p_id;

    -- Los hermanos de donde cae: se le hace sitio delante de `p_antes_de` y se
    -- renumeran todos del 1 al N, sin huecos
    CREATE TEMP TABLE IF NOT EXISTS tmp_hermanos_enc (id bigint, pos integer) ON COMMIT DROP;
    DELETE FROM tmp_hermanos_enc;

    INSERT INTO tmp_hermanos_enc (id, pos)
    SELECT id, row_number() OVER (ORDER BY orden, id)
      FROM ecommerce.encabezado_enlaces
     WHERE padre_id IS NOT DISTINCT FROM p_padre_id
       AND deleted_at IS NULL AND id <> p_id;

    IF p_antes_de IS NOT NULL AND p_antes_de <> p_id THEN
        SELECT pos INTO v_pos FROM tmp_hermanos_enc WHERE id = p_antes_de;
    END IF;
    IF v_pos IS NULL THEN
        SELECT COALESCE(max(pos), 0) + 1 INTO v_pos FROM tmp_hermanos_enc;
    END IF;

    UPDATE tmp_hermanos_enc SET pos = pos + 1 WHERE pos >= v_pos;
    INSERT INTO tmp_hermanos_enc (id, pos) VALUES (p_id, v_pos);

    FOR v_fila IN SELECT id FROM tmp_hermanos_enc ORDER BY pos LOOP
        v_i := v_i + 1;
        UPDATE ecommerce.encabezado_enlaces SET orden = v_i
         WHERE id = v_fila.id AND orden IS DISTINCT FROM v_i;
    END LOOP;

    -- Y los que deja atrás, también sin huecos
    IF v_padre_actual IS DISTINCT FROM p_padre_id THEN
        v_i := 0;
        FOR v_fila IN
            SELECT id FROM ecommerce.encabezado_enlaces
             WHERE padre_id IS NOT DISTINCT FROM v_padre_actual AND deleted_at IS NULL
             ORDER BY orden, id
        LOOP
            v_i := v_i + 1;
            UPDATE ecommerce.encabezado_enlaces SET orden = v_i
             WHERE id = v_fila.id AND orden IS DISTINCT FROM v_i;
        END LOOP;
    END IF;

    RETURN jsonb_build_object('success', true,
        'message', CASE WHEN v_padre_actual IS DISTINCT FROM p_padre_id
                        THEN format('«%s» movido', v_texto)
                        ELSE format('«%s» cambió de sitio', v_texto) END,
        'data', (ecommerce.fn_encabezado_obtener() -> 'data'));
END;
$function$;

COMMENT ON FUNCTION ecommerce.fn_encabezado_enlaces_mover(bigint, bigint, bigint, bigint, character varying, character varying, inet, text, uuid) IS
    'Cambia de padre y de sitio un enlace del menú (el arrastre de la rejilla). Sin límite de niveles; no admite ciclos.';

-- ---------- 5. El árbol que ve la tienda ----------
--
-- SE LLAMA A SÍ MISMA porque ya no se sabe cuántos niveles hay. Es plpgsql y
-- no SQL justamente por eso: en una función SQL el cuerpo se comprueba al
-- crearla y no podría nombrarse a sí misma.
--
-- Las reglas son las de siempre, ahora en todos los niveles:
--   · con hijos, el enlace sólo ABRE: no lleva a ningún sitio;
--   · sin hijos, se enseña sólo si lleva a algo que se pueda ver;
--   · y el destacado —la píldora del final de la barra— es de los principales.
CREATE OR REPLACE FUNCTION ecommerce.fn_encabezado_menu_publico(p_padre bigint DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'ecommerce'
AS $function$
DECLARE
    v_salida jsonb := '[]'::jsonb;
    v_hijos  jsonb;
    v_fila   record;
BEGIN
    FOR v_fila IN
        SELECT e.id, e.texto, e.enlace, e.icono, e.nueva_pestana, e.destacado
          FROM ecommerce.encabezado_enlaces e
         WHERE e.padre_id IS NOT DISTINCT FROM p_padre
           AND e.activo AND e.deleted_at IS NULL
         ORDER BY e.orden, e.id
    LOOP
        v_hijos := ecommerce.fn_encabezado_menu_publico(v_fila.id);

        IF v_hijos <> '[]'::jsonb THEN
            v_salida := v_salida || jsonb_build_object(
                'texto',         v_fila.texto,
                'enlace',        NULL,
                'icono',         v_fila.icono,
                'nueva_pestana', false,
                'destacado',     false,
                'hijos',         v_hijos);

        ELSIF v_fila.enlace IS NOT NULL
              AND ecommerce.fn_enlace_a_pagina_visible(v_fila.enlace) THEN
            v_salida := v_salida || jsonb_build_object(
                'texto',         v_fila.texto,
                'enlace',        v_fila.enlace,
                'icono',         v_fila.icono,
                'nueva_pestana', v_fila.nueva_pestana,
                'destacado',     v_fila.destacado AND p_padre IS NULL,
                'hijos',         '[]'::jsonb);
        END IF;
    END LOOP;

    RETURN v_salida;
END;
$function$;

COMMENT ON FUNCTION ecommerce.fn_encabezado_menu_publico(bigint) IS
    'El menú del encabezado para la tienda, con los niveles que tenga. Se llama a sí misma.';

-- ---------- 6. Y la tienda lo recibe ----------
CREATE OR REPLACE FUNCTION ecommerce.fn_secciones_publicas()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
AS $function$
    -- Una columna del pie, montada una sola vez y usada por las dos franjas
    WITH columnas AS (
        SELECT c.zona, c.orden, c.id,
               jsonb_build_object(
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
                          AND ecommerce.fn_enlace_a_pagina_visible(l.enlace)), '[]'::jsonb)) AS grupo
          FROM ecommerce.pie_columnas c
         WHERE c.activo AND c.deleted_at IS NULL
    )
    SELECT jsonb_build_array(
        jsonb_build_object(
            'clave', 'header', 'tipo', 'header', 'ubicacion', 'arriba', 'orden', 1, 'titulo', 'Header',
            'config', (SELECT config FROM ecommerce.encabezado WHERE id = 1),
            -- El logo que se subió en el CRM; sin él, la tienda pinta el suyo
            'logo', (SELECT logo FROM ecommerce.encabezado WHERE id = 1),
            -- EL MENÚ ENTERO, con los niveles que tenga: lo arma una función
            -- que se llama a sí misma, porque aquí ya no se sabe cuántos hay
            'menu', ecommerce.fn_encabezado_menu_publico(NULL),
            'grupos', '[]'::jsonb),
        jsonb_build_object(
            'clave', 'footer', 'tipo', 'footer', 'ubicacion', 'abajo', 'orden', 1, 'titulo', 'Footer',
            'config', jsonb_build_object(
                'titulo_redes', (SELECT config ->> 'titulo_redes' FROM ecommerce.pie WHERE id = 1),
                'titulo_redes_estilo', (SELECT COALESCE(config -> 'titulo_redes_estilo', '{}'::jsonb)
                                          FROM ecommerce.pie WHERE id = 1),
                -- Los derechos reservados, de la configuración del pie
                'barra_inferior', (SELECT COALESCE(config -> 'barra_inferior', '{}'::jsonb)
                                     FROM ecommerce.pie WHERE id = 1),
                'redes', COALESCE((
                    SELECT jsonb_agg(jsonb_build_object(
                               'icono',  r ->> 'icono',
                               'nombre', r ->> 'nombre',
                               'enlace', r ->> 'enlace'))
                      FROM ecommerce.pie p, jsonb_array_elements(COALESCE(p.config -> 'redes', '[]'::jsonb)) r
                     WHERE p.id = 1 AND (r -> 'activo') = 'true'::jsonb), '[]'::jsonb)),
            'menu', '[]'::jsonb,
            'grupos', COALESCE((SELECT jsonb_agg(c.grupo ORDER BY c.orden, c.id)
                                  FROM columnas c WHERE c.zona = 'arriba'), '[]'::jsonb),
            'grupos_abajo', COALESCE((SELECT jsonb_agg(c.grupo ORDER BY c.orden, c.id)
                                        FROM columnas c WHERE c.zona = 'abajo'), '[]'::jsonb))
    );
$function$;

COMMIT;


-- ============================================================================
-- COMPROBACIÓN — arma un menú de cuatro niveles y lo deshace
-- ============================================================================
DO $comprobar$
DECLARE
    v_falta  text[] := '{}';
    v_a      bigint;
    v_b      bigint;
    v_c      bigint;
    v_d      bigint;
    v_json   jsonb;
    v_menu   jsonb;
    v_fila   jsonb;
    v_res    jsonb;
BEGIN
    -- ---------- Lo que ya hay sigue en pie ----------
    v_json := ecommerce.fn_encabezado_enlaces_json();
    IF jsonb_typeof(v_json) <> 'array' THEN
        v_falta := array_append(v_falta, 'el CRM ya no recibe una lista');
    END IF;
    IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_json) x WHERE NOT (x ? 'nivel' AND x ? 'hijos' AND x ? 'padre_id')) THEN
        v_falta := array_append(v_falta, 'a las filas les falta nivel, hijos o padre_id');
    END IF;

    BEGIN
        -- ---------- Cuatro niveles ----------
        -- El id del recién creado se busca por su texto: la lista vuelve en
        -- orden de árbol y el último no tiene por qué ser él
        PERFORM ecommerce.fn_encabezado_enlaces_guardar(NULL, NULL, 'ZZ nivel 1', NULL, NULL, true, false, false);
        SELECT id INTO v_a FROM ecommerce.encabezado_enlaces WHERE texto = 'ZZ nivel 1' AND deleted_at IS NULL;

        PERFORM ecommerce.fn_encabezado_enlaces_guardar(NULL, v_a, 'ZZ nivel 2', NULL, NULL, true, false, false);
        SELECT id INTO v_b FROM ecommerce.encabezado_enlaces WHERE texto = 'ZZ nivel 2' AND deleted_at IS NULL;

        PERFORM ecommerce.fn_encabezado_enlaces_guardar(NULL, v_b, 'ZZ nivel 3', NULL, NULL, true, false, false);
        SELECT id INTO v_c FROM ecommerce.encabezado_enlaces WHERE texto = 'ZZ nivel 3' AND deleted_at IS NULL;

        -- El cuarto SÍ lleva dirección: es la hoja, y sin ella la tienda no la enseña
        PERFORM ecommerce.fn_encabezado_enlaces_guardar(NULL, v_c, 'ZZ nivel 4', '/shop', NULL, true, false, false);
        SELECT id INTO v_d FROM ecommerce.encabezado_enlaces WHERE texto = 'ZZ nivel 4' AND deleted_at IS NULL;

        IF v_d IS NULL THEN
            v_falta := array_append(v_falta, 'no se pudo crear un enlace de cuarto nivel');
        END IF;

        -- ---------- El CRM los ve con su nivel ----------
        v_json := ecommerce.fn_encabezado_enlaces_json();
        SELECT x INTO v_fila FROM jsonb_array_elements(v_json) x WHERE (x ->> 'id')::bigint = v_d;
        IF (v_fila ->> 'nivel')::int <> 3 THEN
            v_falta := array_append(v_falta, 'el de cuarto nivel no viaja con nivel 3: ' || COALESCE(v_fila ->> 'nivel', '(nada)'));
        END IF;
        SELECT x INTO v_fila FROM jsonb_array_elements(v_json) x WHERE (x ->> 'id')::bigint = v_a;
        IF (v_fila ->> 'hijos')::int <> 1 THEN
            v_falta := array_append(v_falta, 'el principal no dice que tiene un hijo');
        END IF;

        -- ---------- Y la tienda, anidados ----------
        v_menu := ecommerce.fn_encabezado_menu_publico(NULL);
        SELECT x INTO v_fila FROM jsonb_array_elements(v_menu) x WHERE x ->> 'texto' = 'ZZ nivel 1';
        IF v_fila IS NULL THEN
            v_falta := array_append(v_falta, 'la tienda no recibe el menú nuevo');
        ELSIF (v_fila -> 'hijos' -> 0 -> 'hijos' -> 0 -> 'hijos' -> 0 ->> 'texto') IS DISTINCT FROM 'ZZ nivel 4' THEN
            v_falta := array_append(v_falta, 'la tienda no recibe los cuatro niveles anidados');
        ELSIF (v_fila -> 'hijos' -> 0 -> 'hijos' -> 0 -> 'hijos' -> 0 ->> 'enlace') IS DISTINCT FROM '/shop' THEN
            v_falta := array_append(v_falta, 'la hoja del cuarto nivel viaja sin su dirección');
        END IF;

        -- ---------- Mover: no se deja meter dentro de su propio nieto ----------
        BEGIN
            PERFORM ecommerce.fn_encabezado_enlaces_mover(v_a, v_c);
            v_falta := array_append(v_falta, 'dejó meter un enlace dentro de su propia rama');
        EXCEPTION WHEN others THEN
            NULL;   -- tenía que reventar
        END;

        -- ---------- Mover de verdad: el nieto pasa a principal ----------
        v_res := ecommerce.fn_encabezado_enlaces_mover(v_c, NULL, NULL);
        IF (SELECT padre_id FROM ecommerce.encabezado_enlaces WHERE id = v_c) IS NOT NULL THEN
            v_falta := array_append(v_falta, 'no se pudo sacar una rama a principal');
        END IF;
        IF (SELECT count(*) FROM ecommerce.encabezado_enlaces WHERE padre_id = v_c AND deleted_at IS NULL) <> 1 THEN
            v_falta := array_append(v_falta, 'al mover la rama se quedó sin su hijo');
        END IF;

        -- ---------- Borrar se lleva la rama entera ----------
        PERFORM ecommerce.fn_encabezado_enlaces_eliminar(v_a);
        IF (SELECT deleted_at FROM ecommerce.encabezado_enlaces WHERE id = v_b) IS NULL THEN
            v_falta := array_append(v_falta, 'borrar no se llevó al hijo');
        END IF;

        -- Y se deshace: la prueba no deja enlaces
        RAISE EXCEPTION 'deshacer la prueba';
    EXCEPTION WHEN others THEN
        IF SQLERRM <> 'deshacer la prueba' THEN
            RAISE;
        END IF;
    END;

    IF EXISTS (SELECT 1 FROM ecommerce.encabezado_enlaces WHERE texto LIKE 'ZZ nivel%') THEN
        v_falta := array_append(v_falta, 'los enlaces de prueba se quedaron en la base');
    END IF;

    IF array_length(v_falta, 1) > 0 THEN
        RAISE EXCEPTION 'El menú sin límite no quedó bien: %', array_to_string(v_falta, '; ');
    END IF;

    RAISE NOTICE 'El menú del encabezado admite los niveles que haga falta.';
END;
$comprobar$;
