-- ============================================================================
-- EL MENÚ, DE CADA ENCABEZADO
-- ============================================================================
-- Ayer los encabezados se volvieron varios —uno por campaña, con sus fechas—
-- pero el MENÚ se quedó siendo uno solo para todos: `encabezado_enlaces` no
-- colgaba de nadie. Y eso deja a medias justo lo que se vino a hacer: un
-- encabezado de Navidad con su logo, sus colores y su franja, pero con los
-- mismos enlaces del resto del año. Quien quisiera añadir «REGALOS» tenía que
-- ponerlo en el menú de todos y apagarlo por fechas enlace a enlace.
--
-- Desde aquí CADA ENCABEZADO LLEVA SU MENÚ. La tienda pinta el del encabezado
-- que mande hoy (lo decide fn_encabezado_vigente_id, que no cambia), y la
-- pantalla del CRM enseña el del que se esté editando.
--
-- LO QUE HAY HOY NO SE PIERDE NI CAMBIA DE PINTA: los enlaces que existen
-- pasan a ser del predeterminado, y cada uno de los otros encabezados recibe
-- UNA COPIA de ese mismo menú. Así, el día del cambio, la tienda se ve igual
-- con el encabezado que toque; a partir de ahí, cada uno se toca por su lado.
--
-- La copia se lleva también la pinta de cada enlace —el color, el fondo, el
-- tamaño y la letra que se eligieron ayer—, remapeada a los ids nuevos: esa
-- pinta vive en `config.menu_enlaces` del encabezado, con el id del enlace de
-- clave, así que copiarla tal cual apuntaría a enlaces de otro.
--
-- LA PAPELERA TAMBIÉN ES DE CADA UNO: borrar un enlace del de Navidad no
-- tiene por qué asomar en la papelera del de siempre. Lo que ya estaba
-- borrado se queda en la del predeterminado, que es de donde salió.
--
-- UN HIJO NO PUEDE CRUZAR DE ENCABEZADO, y no se fía de las funciones: la
-- clave ajena del padre pasa a ser (padre_id, encabezado_id), de modo que la
-- base misma impide que un desplegable del de Navidad cuelgue de un principal
-- del de siempre.
--
-- ----------------------------------------------------------------------------
-- SE EJECUTA A MANO. Para ensayar: comentar el COMMIT y poner un ROLLBACK al
-- final del todo (un ROLLBACK en el sitio del COMMIT dejaría la comprobación
-- mirando las funciones viejas).
-- ============================================================================

BEGIN;

-- Las funciones en lenguaje sql miran por dentro a las que llaman en el
-- momento de crearlas, y aquí unas cuantas cambian de firma a la vez
SET LOCAL check_function_bodies = off;


-- ============================================================================
-- 1. LA COLUMNA
-- ============================================================================

ALTER TABLE ecommerce.encabezado_enlaces
      ADD COLUMN IF NOT EXISTS encabezado_id bigint;

-- Lo que ya había es del predeterminado: es el menú que la tienda lleva
-- enseñando, y el predeterminado es el que manda cuando no hay campaña
UPDATE ecommerce.encabezado_enlaces
   SET encabezado_id = COALESCE((SELECT id FROM ecommerce.encabezado WHERE principal),
                                (SELECT min(id) FROM ecommerce.encabezado))
 WHERE encabezado_id IS NULL;

ALTER TABLE ecommerce.encabezado_enlaces ALTER COLUMN encabezado_id SET NOT NULL;

-- Borrar un encabezado se lleva su menú. No hay papelera de encabezados —lo
-- dice fn_encabezados_eliminar— así que dejar sus enlaces sueltos sería dejar
-- basura que nadie puede volver a ver
ALTER TABLE ecommerce.encabezado_enlaces
      DROP CONSTRAINT IF EXISTS fk_encabezado_enlaces_encabezado;
ALTER TABLE ecommerce.encabezado_enlaces
      ADD CONSTRAINT fk_encabezado_enlaces_encabezado
      FOREIGN KEY (encabezado_id) REFERENCES ecommerce.encabezado (id) ON DELETE CASCADE;

-- EL PADRE, DEL MISMO ENCABEZADO QUE EL HIJO, y comprobado por la base: la
-- clave ajena pasa a llevar las dos columnas. Con `padre_id` vacío no se
-- comprueba nada (es un principal), que es justo lo que hace falta.
ALTER TABLE ecommerce.encabezado_enlaces
      DROP CONSTRAINT IF EXISTS uq_encabezado_enlaces_id_encabezado;
ALTER TABLE ecommerce.encabezado_enlaces
      ADD CONSTRAINT uq_encabezado_enlaces_id_encabezado UNIQUE (id, encabezado_id);

ALTER TABLE ecommerce.encabezado_enlaces
      DROP CONSTRAINT IF EXISTS fk_encabezado_enlaces_padre;
ALTER TABLE ecommerce.encabezado_enlaces
      ADD CONSTRAINT fk_encabezado_enlaces_padre
      FOREIGN KEY (padre_id, encabezado_id)
      REFERENCES ecommerce.encabezado_enlaces (id, encabezado_id);

CREATE INDEX IF NOT EXISTS ix_encabezado_enlaces_encabezado
    ON ecommerce.encabezado_enlaces (encabezado_id, padre_id, orden);

COMMENT ON COLUMN ecommerce.encabezado_enlaces.encabezado_id IS
    'De qué encabezado es este enlace. Cada encabezado lleva su menú; la tienda pinta el del que mande hoy.';


-- ============================================================================
-- 2. CADA ENCABEZADO, CON UNA COPIA DEL MENÚ DE HOY
-- ============================================================================
-- Sólo los que se quedaron sin ninguno, que el día del cambio son todos menos
-- el predeterminado. Volver a ejecutar esto no duplica nada.

DO $copia$
DECLARE
    v_prin  bigint := COALESCE((SELECT id FROM ecommerce.encabezado WHERE principal),
                               (SELECT min(id) FROM ecommerce.encabezado));
    v_enc   record;
    v_fila  record;
    v_nuevo bigint;
    v_n     integer := 0;
BEGIN
    CREATE TEMP TABLE IF NOT EXISTS tmp_mapa_menu (viejo bigint, nuevo bigint) ON COMMIT DROP;

    FOR v_enc IN
        SELECT e.id, e.nombre FROM ecommerce.encabezado e
         WHERE e.id <> v_prin
           AND NOT EXISTS (SELECT 1 FROM ecommerce.encabezado_enlaces x
                            WHERE x.encabezado_id = e.id)
         ORDER BY e.id
    LOOP
        DELETE FROM tmp_mapa_menu;

        -- DE ARRIBA ABAJO: cuando toca un hijo, su padre ya está copiado y
        -- su id nuevo está en el mapa
        FOR v_fila IN
            WITH RECURSIVE rama AS (
                SELECT e.*, 0 AS nivel
                  FROM ecommerce.encabezado_enlaces e
                 WHERE e.encabezado_id = v_prin AND e.padre_id IS NULL AND e.deleted_at IS NULL
                UNION ALL
                SELECT h.*, r.nivel + 1
                  FROM ecommerce.encabezado_enlaces h
                  JOIN rama r ON h.padre_id = r.id
                 WHERE h.deleted_at IS NULL
            )
            SELECT * FROM rama ORDER BY nivel, orden, id
        LOOP
            INSERT INTO ecommerce.encabezado_enlaces
                   (encabezado_id, padre_id, texto, enlace, icono, nueva_pestana,
                    orden, activo, destacado, desde, hasta)
            VALUES (v_enc.id,
                    (SELECT m.nuevo FROM tmp_mapa_menu m WHERE m.viejo = v_fila.padre_id),
                    v_fila.texto, v_fila.enlace, v_fila.icono, v_fila.nueva_pestana,
                    v_fila.orden, v_fila.activo, v_fila.destacado, v_fila.desde, v_fila.hasta)
            RETURNING id INTO v_nuevo;

            INSERT INTO tmp_mapa_menu (viejo, nuevo) VALUES (v_fila.id, v_nuevo);
            v_n := v_n + 1;
        END LOOP;

        -- Y la pinta de cada enlace, apuntando a los ids nuevos
        UPDATE ecommerce.encabezado e
           SET config = jsonb_set(e.config, '{menu_enlaces}', COALESCE(
                   (SELECT jsonb_object_agg(m.nuevo::text, x.value)
                      FROM jsonb_each(e.config -> 'menu_enlaces') x
                      JOIN tmp_mapa_menu m ON m.viejo::text = x.key), '{}'::jsonb))
         WHERE e.id = v_enc.id
           AND jsonb_typeof(e.config -> 'menu_enlaces') = 'object';
    END LOOP;

    RAISE NOTICE 'Menú copiado a los demás encabezados: % enlaces', v_n;
END;
$copia$;


-- ============================================================================
-- 3. CUÁL SE ESTÁ MIRANDO
-- ============================================================================
-- El id que se diga y, si no se dice ninguno, el predeterminado. Lo usan
-- todas las de abajo, y escribirlo una vez evita que un día una de ellas
-- entienda «ninguno» de otra manera.

CREATE OR REPLACE FUNCTION ecommerce.fn_encabezado_cual(p_id bigint DEFAULT NULL)
RETURNS bigint
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO 'pg_catalog', 'ecommerce'
AS $function$
    SELECT COALESCE(p_id,
                    (SELECT e.id FROM ecommerce.encabezado e WHERE e.principal),
                    (SELECT min(e.id) FROM ecommerce.encabezado e));
$function$;


-- ============================================================================
-- 4. EL MENÚ DE UNO, PARA LA PANTALLA
-- ============================================================================

DROP FUNCTION IF EXISTS ecommerce.fn_encabezado_enlaces_json();

CREATE OR REPLACE FUNCTION ecommerce.fn_encabezado_enlaces_json(p_encabezado_id bigint DEFAULT NULL)
RETURNS jsonb
LANGUAGE sql
STABLE SECURITY DEFINER
AS $function$
    WITH RECURSIVE arbol AS (
        SELECT e.id, e.padre_id, e.texto, e.enlace, e.icono, e.nueva_pestana,
               e.orden, e.activo, e.destacado, e.desde, e.hasta, 0 AS nivel,
               ARRAY[lpad(e.orden::text, 6, '0') || '-' || lpad(e.id::text, 12, '0')] AS camino
          FROM ecommerce.encabezado_enlaces e
         -- SÓLO LOS DE ESTE ENCABEZADO. Basta con filtrar los principales:
         -- un hijo no puede cruzar de encabezado (lo impide la clave ajena)
         WHERE e.encabezado_id = ecommerce.fn_encabezado_cual(p_encabezado_id)
           AND e.padre_id IS NULL AND e.deleted_at IS NULL
        UNION ALL
        SELECT h.id, h.padre_id, h.texto, h.enlace, h.icono, h.nueva_pestana,
               h.orden, h.activo, h.destacado, h.desde, h.hasta, a.nivel + 1,
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
               -- ENTRE QUÉ FECHAS SE VE, como en las secciones de la portada:
               -- un enlace de campaña se enciende y se apaga solo. Vacías, se
               -- ve siempre, que es como ha ido el menú hasta hoy
               'desde',         to_char(a.desde, 'YYYY-MM-DD"T"HH24:MI'),
               'hasta',         to_char(a.hasta, 'YYYY-MM-DD"T"HH24:MI'),
               -- Y en qué estado está, resuelto aquí: que la pantalla tenga que
               -- comparar fechas con el reloj del navegador es la manera de que
               -- diga «se ve» cuando el servidor cree que no
               'estado',        CASE
                   WHEN NOT a.activo THEN 'oculto'
                   WHEN a.desde IS NOT NULL AND CURRENT_TIMESTAMP < a.desde THEN 'programado'
                   WHEN a.hasta IS NOT NULL AND CURRENT_TIMESTAMP > a.hasta THEN 'terminado'
                   ELSE 'visible' END,
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


-- ============================================================================
-- 5. EL MENÚ DE UNO, PARA LA TIENDA
-- ============================================================================
-- Ahora hay que decirle DE CUÁL. Se lo pasa quien la llama y se arrastra en
-- la recursión: preguntar por el vigente en cada nivel sería preguntarlo
-- quince veces y, con una campaña entrando en fecha a mitad de la llamada,
-- armar un menú con ramas de dos encabezados distintos.

DROP FUNCTION IF EXISTS ecommerce.fn_encabezado_menu_publico(bigint);

CREATE OR REPLACE FUNCTION ecommerce.fn_encabezado_menu_publico(
    p_encabezado_id bigint,
    p_padre         bigint DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'pg_catalog', 'ecommerce'
AS $function$
DECLARE
    v_salida jsonb := '[]'::jsonb;
    v_hijos  jsonb;
    v_fila   record;
    v_enc    bigint := ecommerce.fn_encabezado_cual(p_encabezado_id);
    -- La pinta de cada enlace, la del encabezado que se está pintando. Sólo
    -- en la barra: dentro de un desplegable no se pinta, así que ni se busca.
    v_estilos jsonb := CASE WHEN p_padre IS NULL THEN COALESCE(
        (SELECT e.config -> 'menu_enlaces' FROM ecommerce.encabezado e
          WHERE e.id = ecommerce.fn_encabezado_cual(p_encabezado_id)), '{}'::jsonb)
        ELSE '{}'::jsonb END;
BEGIN
    FOR v_fila IN
        SELECT e.id, e.texto, e.enlace, e.icono, e.nueva_pestana, e.destacado
          FROM ecommerce.encabezado_enlaces e
         WHERE e.encabezado_id = v_enc
           AND e.padre_id IS NOT DISTINCT FROM p_padre
           AND e.activo AND e.deleted_at IS NULL
           -- Y DENTRO DE SUS FECHAS: un enlace de campaña se apaga solo. Sin
           -- fechas, fn_vigente dice que sí siempre
           AND ecommerce.fn_vigente(e.desde, e.hasta)
         ORDER BY e.orden, e.id
    LOOP
        v_hijos := ecommerce.fn_encabezado_menu_publico(v_enc, v_fila.id);

        IF v_hijos <> '[]'::jsonb THEN
            v_salida := v_salida || jsonb_build_object(
                'texto',         v_fila.texto,
                'enlace',        NULL,
                'icono',         v_fila.icono,
                'nueva_pestana', false,
                'destacado',     false,
                -- NULL si no se le eligió nada, que es lo normal: entonces
                -- manda la letra del menú entero
                'estilo',        v_estilos -> v_fila.id::text,
                'hijos',         v_hijos);

        ELSIF v_fila.enlace IS NOT NULL
              AND ecommerce.fn_enlace_a_pagina_visible(v_fila.enlace) THEN
            v_salida := v_salida || jsonb_build_object(
                'texto',         v_fila.texto,
                'enlace',        v_fila.enlace,
                'icono',         v_fila.icono,
                'nueva_pestana', v_fila.nueva_pestana,
                'destacado',     v_fila.destacado AND p_padre IS NULL,
                'estilo',        v_estilos -> v_fila.id::text,
                'hijos',         '[]'::jsonb);
        END IF;
    END LOOP;

    RETURN v_salida;
END;
$function$;


-- ============================================================================
-- 6. LA PANTALLA: EL ENCABEZADO CON SU MENÚ
-- ============================================================================

CREATE OR REPLACE FUNCTION ecommerce.fn_encabezado_obtener(p_id bigint DEFAULT NULL)
RETURNS jsonb
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO 'pg_catalog', 'ecommerce'
AS $function$
    -- Sin id, el predeterminado: es el que se abre al entrar a la pantalla
    SELECT jsonb_build_object('success', true, 'message', 'Encabezado',
        'data', jsonb_build_object(
            'id',      e.id,
            'nombre',  e.nombre,
            'desde',   to_char(e.desde, 'YYYY-MM-DD"T"HH24:MI'),
            'hasta',   to_char(e.hasta, 'YYYY-MM-DD"T"HH24:MI'),
            'activo',  e.activo,
            'principal', e.principal,
            'manda',   e.id = ecommerce.fn_encabezado_vigente_id(),
            'config',  e.config,
            -- El fichero del logo, o NULL para el de la casa. La dirección la
            -- arma el controlador, como con el resto de imágenes del ecommerce
            'logo',    e.logo,
            -- TODOS, para poder cambiar de uno a otro sin otra llamada
            'encabezados', ecommerce.fn_encabezados_listar(),
            -- SU MENÚ: cada encabezado lleva el suyo
            'enlaces', ecommerce.fn_encabezado_enlaces_json(e.id),
            'updated_at', to_char(e.updated_at, 'YYYY-MM-DD HH24:MI:SS'),
            'updated_by', e.updated_by))
      FROM ecommerce.encabezado e
     WHERE e.id = COALESCE(p_id, (SELECT x.id FROM ecommerce.encabezado x WHERE x.principal),
                                 (SELECT min(x.id) FROM ecommerce.encabezado x));
$function$;


-- ============================================================================
-- 7. CREAR Y MODIFICAR UN ENLACE
-- ============================================================================

DROP FUNCTION IF EXISTS ecommerce.fn_encabezado_enlaces_guardar(
    bigint, bigint, character varying, character varying, character varying,
    boolean, boolean, boolean, timestamp with time zone, timestamp with time zone,
    bigint, character varying, character varying, inet, text, uuid);

CREATE OR REPLACE FUNCTION ecommerce.fn_encabezado_enlaces_guardar(
    p_id             bigint,
    p_encabezado_id  bigint,
    p_padre_id       bigint,
    p_texto          character varying,
    p_enlace         character varying,
    p_icono          character varying,
    p_activo         boolean,
    p_nueva_pestana  boolean,
    p_destacado      boolean,
    p_desde          timestamp with time zone,
    p_hasta          timestamp with time zone,
    p_usuario_id     bigint DEFAULT NULL,
    p_usuario_login  character varying DEFAULT NULL,
    p_usuario_nombre character varying DEFAULT NULL,
    p_ip_address     inet DEFAULT NULL,
    p_user_agent     text DEFAULT NULL,
    p_request_id     uuid DEFAULT NULL)
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
    v_enc    bigint;
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

    IF v_nuevo THEN
        -- DE QUÉ ENCABEZADO ES. Si cuelga de otro enlace, del mismo que su
        -- padre y punto: un desplegable del de Navidad no puede colgar de un
        -- principal del de siempre, y la clave ajena tampoco lo dejaría.
        IF v_padre IS NOT NULL THEN
            SELECT encabezado_id INTO v_enc FROM ecommerce.encabezado_enlaces
             WHERE id = v_padre AND deleted_at IS NULL;
            IF NOT FOUND THEN
                RAISE EXCEPTION 'El enlace del que debería colgar no existe' USING ERRCODE = 'P0016';
            END IF;
            IF p_encabezado_id IS NOT NULL AND p_encabezado_id <> v_enc THEN
                RAISE EXCEPTION 'Ese enlace es de otro encabezado' USING ERRCODE = 'P0016';
            END IF;
        ELSE
            v_enc := ecommerce.fn_encabezado_cual(p_encabezado_id);
            IF NOT EXISTS (SELECT 1 FROM ecommerce.encabezado WHERE id = v_enc) THEN
                RAISE EXCEPTION 'Ese encabezado no existe' USING ERRCODE = 'P0013';
            END IF;
        END IF;
    ELSE
        -- El padre no se cambia al modificar: mover un enlace de sitio es
        -- arrastrarlo, y mezclarlo aquí dejaría dos caminos para lo mismo. El
        -- encabezado tampoco: un enlace nace en uno y se queda en él.
        SELECT padre_id, encabezado_id INTO v_padre, v_enc
          FROM ecommerce.encabezado_enlaces
         WHERE id = p_id AND deleted_at IS NULL;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'El enlace no existe' USING ERRCODE = 'P0013';
        END IF;
    END IF;

    -- LAS FECHAS, AL DERECHO: con «hasta» antes que «desde» el enlace no se
    -- vería nunca, y nadie entendería por qué
    IF p_desde IS NOT NULL AND p_hasta IS NOT NULL AND p_hasta < p_desde THEN
        RAISE EXCEPTION 'Las fechas van al revés: «hasta» es anterior a «desde»' USING ERRCODE = 'P0015';
    END IF;

    -- DESTACADO ES SÓLO DE LOS PRINCIPALES: es una píldora al final de la
    -- barra roja, y dentro de un desplegable no hay barra donde ponerla.
    v_destacado := COALESCE(p_destacado, false) AND v_padre IS NULL;

    -- LA DIRECCIÓN ES OPCIONAL EN TODOS LOS NIVELES: «MARCAS → Motos →
    -- Honda» se arma de arriba abajo, y «Motos» nace sin hijos todavía, así
    -- que exigirle dirección era impedir construirlo. Un enlace sin hijos y
    -- sin dirección no se enseña en la tienda, y la rejilla del CRM lo dice
    -- en su fila.

    IF v_nuevo THEN
        INSERT INTO ecommerce.encabezado_enlaces
               (encabezado_id, padre_id, texto, enlace, icono, activo, nueva_pestana,
                destacado, desde, hasta, orden)
        VALUES (v_enc, v_padre, v_texto, v_enlace, v_icono,
                COALESCE(p_activo, true),
                ecommerce.fn_nueva_pestana(v_enlace, p_nueva_pestana),
                v_destacado, p_desde, p_hasta,
                (SELECT COALESCE(max(orden), 0) + 1 FROM ecommerce.encabezado_enlaces
                  WHERE encabezado_id = v_enc
                    AND padre_id IS NOT DISTINCT FROM v_padre AND deleted_at IS NULL))
        RETURNING id INTO v_id;
    ELSE
        UPDATE ecommerce.encabezado_enlaces
           SET texto = v_texto, enlace = v_enlace, icono = v_icono,
               activo = COALESCE(p_activo, true),
               nueva_pestana = ecommerce.fn_nueva_pestana(v_enlace, p_nueva_pestana),
               destacado = v_destacado,
               desde = p_desde, hasta = p_hasta
         WHERE id = v_id;
    END IF;

    RETURN jsonb_build_object('success', true,
        'message', CASE WHEN v_nuevo THEN 'Enlace creado' ELSE 'Enlace actualizado' END,
        -- SÓLO EL MENÚ, que es lo único que cambia aquí: devolver «el
        -- encabezado» entero le repintaría los colores a quien edita, y lo
        -- que acaba de tocar es un enlace
        'data', jsonb_build_object('enlaces', ecommerce.fn_encabezado_enlaces_json(v_enc)));
END;
$function$;


-- ============================================================================
-- 8. ENCENDER Y APAGAR UNO
-- ============================================================================

CREATE OR REPLACE FUNCTION ecommerce.fn_encabezado_enlaces_activar(
    p_id bigint,
    p_activo boolean DEFAULT NULL,
    p_usuario_id bigint DEFAULT NULL,
    p_usuario_login character varying DEFAULT NULL,
    p_usuario_nombre character varying DEFAULT NULL,
    p_ip_address inet DEFAULT NULL,
    p_user_agent text DEFAULT NULL,
    p_request_id uuid DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'ecommerce', 'auditoria'
AS $function$
DECLARE
    v_actual boolean;
    v_texto  text;
    v_enc    bigint;
    v_nuevo  boolean;
BEGIN
    PERFORM ecommerce.fn_contexto_auditoria('ecommerce.encabezado_enlaces',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    -- DE QUÉ ENCABEZADO ES no se pregunta: lo dice la fila. Sólo hace falta
    -- para devolver su menú y no el de otro
    SELECT activo, texto, encabezado_id INTO v_actual, v_texto, v_enc
      FROM ecommerce.encabezado_enlaces WHERE id = p_id AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'El enlace no existe' USING ERRCODE = 'P0013';
    END IF;

    v_nuevo := COALESCE(p_activo, NOT v_actual);
    UPDATE ecommerce.encabezado_enlaces SET activo = v_nuevo WHERE id = p_id;

    RETURN jsonb_build_object('success', true,
        'message', format('«%s» %s', v_texto, CASE WHEN v_nuevo THEN 'se ve en el menú' ELSE 'oculto en el menú' END),
        'data', jsonb_build_object('enlaces', ecommerce.fn_encabezado_enlaces_json(v_enc)));
END;
$function$;


-- ============================================================================
-- 9. A LA PAPELERA
-- ============================================================================

CREATE OR REPLACE FUNCTION ecommerce.fn_encabezado_enlaces_eliminar(
    p_id bigint,
    p_usuario_id bigint DEFAULT NULL,
    p_usuario_login character varying DEFAULT NULL,
    p_usuario_nombre character varying DEFAULT NULL,
    p_ip_address inet DEFAULT NULL,
    p_user_agent text DEFAULT NULL,
    p_request_id uuid DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'ecommerce', 'auditoria'
AS $function$
DECLARE
    v_texto text;
    v_enc   bigint;
    v_fecha timestamptz := CURRENT_TIMESTAMP;
    v_hijos integer;
BEGIN
    PERFORM ecommerce.fn_contexto_auditoria('ecommerce.encabezado_enlaces',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    SELECT texto, encabezado_id INTO v_texto, v_enc FROM ecommerce.encabezado_enlaces
     WHERE id = p_id AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'El enlace no existe' USING ERRCODE = 'P0013';
    END IF;

    -- LA RAMA ENTERA se va con él, a cualquier profundidad: dejar a los
    -- nietos colgando de un padre que ya no está los haría invisibles sin
    -- estar borrados.
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
        'data', jsonb_build_object('enlaces', ecommerce.fn_encabezado_enlaces_json(v_enc)));
END;
$function$;


-- ============================================================================
-- 10. REORDENAR UNA RAMA
-- ============================================================================
-- Con el encabezado por delante: la lista de ids llega del navegador, y sin
-- él un id de otro encabezado colado en la lista le renumeraría el menú a
-- quien no estaba mirando.

DROP FUNCTION IF EXISTS ecommerce.fn_encabezado_enlaces_ordenar(
    jsonb, bigint, character varying, character varying, inet, text, uuid);

CREATE OR REPLACE FUNCTION ecommerce.fn_encabezado_enlaces_ordenar(
    p_encabezado_id bigint,
    p_ids jsonb,
    p_usuario_id bigint DEFAULT NULL,
    p_usuario_login character varying DEFAULT NULL,
    p_usuario_nombre character varying DEFAULT NULL,
    p_ip_address inet DEFAULT NULL,
    p_user_agent text DEFAULT NULL,
    p_request_id uuid DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'ecommerce', 'auditoria'
AS $function$
DECLARE
    v     integer;
    v_enc bigint := ecommerce.fn_encabezado_cual(p_encabezado_id);
BEGIN
    PERFORM ecommerce.fn_contexto_auditoria('ecommerce.encabezado_enlaces',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    IF jsonb_typeof(p_ids) <> 'array' THEN
        RAISE EXCEPTION 'Se esperaba la lista de enlaces en el orden nuevo' USING ERRCODE = 'P0015';
    END IF;

    UPDATE ecommerce.encabezado_enlaces e
       SET orden = t.posicion
      FROM (SELECT valor::bigint AS id, ordinalidad::integer AS posicion
              FROM jsonb_array_elements_text(p_ids) WITH ORDINALITY AS x(valor, ordinalidad)) t
     WHERE e.id = t.id AND e.deleted_at IS NULL AND e.encabezado_id = v_enc;
    GET DIAGNOSTICS v = ROW_COUNT;

    RETURN jsonb_build_object('success', true,
        'message', CASE v WHEN 1 THEN 'Enlace movido' ELSE format('%s enlaces reordenados', v) END,
        'data', jsonb_build_object('enlaces', ecommerce.fn_encabezado_enlaces_json(v_enc)));
END;
$function$;


-- ============================================================================
-- 11. ARRASTRAR UNO: DE QUIÉN CUELGA Y EN QUÉ SITIO
-- ============================================================================

CREATE OR REPLACE FUNCTION ecommerce.fn_encabezado_enlaces_mover(
    p_id bigint,
    p_padre_id bigint DEFAULT NULL,
    p_antes_de bigint DEFAULT NULL,
    p_usuario_id bigint DEFAULT NULL,
    p_usuario_login character varying DEFAULT NULL,
    p_usuario_nombre character varying DEFAULT NULL,
    p_ip_address inet DEFAULT NULL,
    p_user_agent text DEFAULT NULL,
    p_request_id uuid DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'ecommerce', 'auditoria'
AS $function$
DECLARE
    v_padre_actual bigint;
    v_texto        text;
    v_enc          bigint;
    v_enc_padre    bigint;
    v_pos          integer;
    v_i            integer := 0;
    v_fila         record;
BEGIN
    PERFORM ecommerce.fn_contexto_auditoria('ecommerce.encabezado_enlaces',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    SELECT padre_id, texto, encabezado_id INTO v_padre_actual, v_texto, v_enc
      FROM ecommerce.encabezado_enlaces WHERE id = p_id AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'El enlace no existe' USING ERRCODE = 'P0013';
    END IF;

    IF p_padre_id IS NOT NULL THEN
        IF p_padre_id = p_id THEN
            RAISE EXCEPTION 'Un enlace no puede colgar de sí mismo' USING ERRCODE = 'P0015';
        END IF;
        SELECT encabezado_id INTO v_enc_padre FROM ecommerce.encabezado_enlaces
         WHERE id = p_padre_id AND deleted_at IS NULL;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'El enlace del que debería colgar no existe' USING ERRCODE = 'P0016';
        END IF;
        -- NI DE UN ENCABEZADO A OTRO: son dos menús distintos, y arrastrarlo
        -- de uno al de al lado sería sacarlo del que se está editando
        IF v_enc_padre <> v_enc THEN
            RAISE EXCEPTION 'Un enlace no se puede mover al menú de otro encabezado' USING ERRCODE = 'P0016';
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
     WHERE encabezado_id = v_enc
       AND padre_id IS NOT DISTINCT FROM p_padre_id
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
             WHERE encabezado_id = v_enc
               AND padre_id IS NOT DISTINCT FROM v_padre_actual AND deleted_at IS NULL
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
        'data', jsonb_build_object('enlaces', ecommerce.fn_encabezado_enlaces_json(v_enc)));
END;
$function$;


-- ============================================================================
-- 12. LA PAPELERA, LA DE CADA ENCABEZADO
-- ============================================================================
-- Borrar un enlace del de Navidad no tiene por qué asomar en la papelera del
-- de siempre: son dos menús, y la pantalla enseña la del que se está
-- editando. Lo que ya estaba borrado antes de este cambio se quedó en la del
-- predeterminado, que es de donde salió.

DROP FUNCTION IF EXISTS ecommerce.fn_encabezado_enlaces_papelera_listar();

CREATE OR REPLACE FUNCTION ecommerce.fn_encabezado_enlaces_papelera_listar(
    p_encabezado_id bigint DEFAULT NULL)
RETURNS jsonb
LANGUAGE sql
STABLE SECURITY DEFINER
AS $function$
    SELECT jsonb_build_object('success', true, 'message', 'Papelera del encabezado',
        'data', COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
                       'id', e.id, 'texto', e.texto, 'detalle', e.enlace,
                       'padre_id', e.padre_id,
                       'deleted_at', to_char(e.deleted_at, 'YYYY-MM-DD HH24:MI:SS'),
                       'deleted_by', e.deleted_by)
                   ORDER BY e.deleted_at DESC, e.texto)
              FROM ecommerce.encabezado_enlaces e
             WHERE e.deleted_at IS NOT NULL
               AND e.encabezado_id = ecommerce.fn_encabezado_cual(p_encabezado_id)), '[]'::jsonb));
$function$;


DROP FUNCTION IF EXISTS ecommerce.fn_encabezado_enlaces_papelera_vaciar(
    bigint, character varying, character varying, inet, text, uuid);

CREATE OR REPLACE FUNCTION ecommerce.fn_encabezado_enlaces_papelera_vaciar(
    p_encabezado_id bigint,
    p_usuario_id bigint DEFAULT NULL,
    p_usuario_login character varying DEFAULT NULL,
    p_usuario_nombre character varying DEFAULT NULL,
    p_ip_address inet DEFAULT NULL,
    p_user_agent text DEFAULT NULL,
    p_request_id uuid DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'ecommerce', 'auditoria'
AS $function$
DECLARE
    v     integer;
    v_mas integer;
    v_enc bigint := ecommerce.fn_encabezado_cual(p_encabezado_id);
BEGIN
    PERFORM ecommerce.fn_contexto_auditoria('ecommerce.encabezado_enlaces',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    -- Los hijos primero: la clave ajena apunta a esta misma tabla
    DELETE FROM ecommerce.encabezado_enlaces
     WHERE deleted_at IS NOT NULL AND encabezado_id = v_enc AND padre_id IS NOT NULL;
    GET DIAGNOSTICS v = ROW_COUNT;
    DELETE FROM ecommerce.encabezado_enlaces
     WHERE deleted_at IS NOT NULL AND encabezado_id = v_enc;
    GET DIAGNOSTICS v_mas = ROW_COUNT;
    v := v + v_mas;

    RETURN jsonb_build_object('success', true, 'message', 'Papelera del encabezado vaciada',
                              'data', jsonb_build_object('enlaces', v));
END;
$function$;


DROP FUNCTION IF EXISTS ecommerce.fn_encabezado_enlaces_restaurar(
    jsonb, bigint, character varying, character varying, inet, text, uuid);

CREATE OR REPLACE FUNCTION ecommerce.fn_encabezado_enlaces_restaurar(
    p_encabezado_id bigint,
    p_ids jsonb,
    p_usuario_id bigint DEFAULT NULL,
    p_usuario_login character varying DEFAULT NULL,
    p_usuario_nombre character varying DEFAULT NULL,
    p_ip_address inet DEFAULT NULL,
    p_user_agent text DEFAULT NULL,
    p_request_id uuid DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'ecommerce', 'auditoria'
AS $function$
DECLARE
    v     integer;
    v_enc bigint := ecommerce.fn_encabezado_cual(p_encabezado_id);
BEGIN
    PERFORM ecommerce.fn_contexto_auditoria('ecommerce.encabezado_enlaces',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    IF jsonb_typeof(p_ids) <> 'array' OR jsonb_array_length(p_ids) = 0 THEN
        RAISE EXCEPTION 'No se indicó qué restaurar' USING ERRCODE = 'P0015';
    END IF;

    -- Un desplegable cuyo principal sigue en la papelera vuelve como
    -- PRINCIPAL: restaurarlo bajo un padre que no se ve sería restaurarlo a
    -- ninguna parte. Y si no tiene dirección propia, no se puede: se dice.
    UPDATE ecommerce.encabezado_enlaces h
       SET deleted_at = NULL, deleted_by = NULL,
           padre_id = CASE WHEN EXISTS (SELECT 1 FROM ecommerce.encabezado_enlaces p
                                         WHERE p.id = h.padre_id AND p.deleted_at IS NULL)
                           THEN h.padre_id END
     WHERE h.deleted_at IS NOT NULL
       AND h.encabezado_id = v_enc
       AND h.id IN (SELECT valor::bigint FROM jsonb_array_elements_text(p_ids) AS x(valor));
    GET DIAGNOSTICS v = ROW_COUNT;

    IF v = 0 THEN
        RAISE EXCEPTION 'Ninguno de esos enlaces está en la papelera de este encabezado'
              USING ERRCODE = 'P0019';
    END IF;

    RETURN jsonb_build_object('success', true,
        'message', CASE v WHEN 1 THEN 'Enlace restaurado' ELSE format('%s enlaces restaurados', v) END,
        'data', jsonb_build_object('enlaces', ecommerce.fn_encabezado_enlaces_json(v_enc)));
END;
$function$;


-- ============================================================================
-- 13. UN ENCABEZADO NUEVO SE LLEVA TAMBIÉN EL MENÚ
-- ============================================================================
-- Nacía copiando los colores y el logo. Ahora copia el menú entero, porque
-- un encabezado sin menú es una tienda sin barra: lo primero que habría que
-- hacer es volver a escribir los seis enlaces a mano.
--
-- Y SE COPIA LA PINTA DE CADA ENLACE, remapeada: vive en
-- `config.menu_enlaces` con el id del enlace de clave, así que copiar el
-- config tal cual dejaría los colores apuntando a los enlaces del otro.

CREATE OR REPLACE FUNCTION ecommerce.fn_encabezados_crear(
    p_nombre text,
    p_copiar_de bigint DEFAULT NULL,
    p_usuario_id bigint DEFAULT NULL,
    p_usuario_login character varying DEFAULT NULL,
    p_usuario_nombre character varying DEFAULT NULL,
    p_ip_address inet DEFAULT NULL,
    p_user_agent text DEFAULT NULL,
    p_request_id uuid DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'ecommerce', 'auditoria'
AS $function$
DECLARE
    v_nombre text;
    v_de     bigint;
    v_id     bigint;
    v_fila   record;
    v_nuevo  bigint;
    v_n      integer := 0;
BEGIN
    PERFORM ecommerce.fn_contexto_auditoria('ecommerce.encabezado',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    v_nombre := ecommerce.fn_validar_texto(p_nombre, 'El nombre del encabezado', 60, true);

    -- NACE COPIANDO a otro, el predeterminado mientras no se diga: un
    -- encabezado en blanco sale con la tienda sin colores, sin logo y sin
    -- menú, y lo primero que habría que hacer es volver a escribirlo todo.
    v_de := COALESCE(p_copiar_de, (SELECT id FROM ecommerce.encabezado WHERE principal));

    IF NOT EXISTS (SELECT 1 FROM ecommerce.encabezado WHERE id = v_de) THEN
        RAISE EXCEPTION 'El encabezado del que se quiere copiar no existe' USING ERRCODE = 'P0013';
    END IF;

    INSERT INTO ecommerce.encabezado (nombre, config, logo, activo, principal)
    SELECT v_nombre, e.config, e.logo, true, false
      FROM ecommerce.encabezado e WHERE e.id = v_de
    RETURNING id INTO v_id;

    -- EL MENÚ, de arriba abajo: cuando toca un hijo, su padre ya está
    -- copiado y su id nuevo está en el mapa
    CREATE TEMP TABLE IF NOT EXISTS tmp_mapa_menu (viejo bigint, nuevo bigint) ON COMMIT DROP;
    DELETE FROM tmp_mapa_menu;

    FOR v_fila IN
        WITH RECURSIVE rama AS (
            SELECT e.*, 0 AS nivel
              FROM ecommerce.encabezado_enlaces e
             WHERE e.encabezado_id = v_de AND e.padre_id IS NULL AND e.deleted_at IS NULL
            UNION ALL
            SELECT h.*, r.nivel + 1
              FROM ecommerce.encabezado_enlaces h
              JOIN rama r ON h.padre_id = r.id
             WHERE h.deleted_at IS NULL
        )
        SELECT * FROM rama ORDER BY nivel, orden, id
    LOOP
        INSERT INTO ecommerce.encabezado_enlaces
               (encabezado_id, padre_id, texto, enlace, icono, nueva_pestana,
                orden, activo, destacado, desde, hasta)
        VALUES (v_id,
                (SELECT m.nuevo FROM tmp_mapa_menu m WHERE m.viejo = v_fila.padre_id),
                v_fila.texto, v_fila.enlace, v_fila.icono, v_fila.nueva_pestana,
                v_fila.orden, v_fila.activo, v_fila.destacado, v_fila.desde, v_fila.hasta)
        RETURNING id INTO v_nuevo;

        INSERT INTO tmp_mapa_menu (viejo, nuevo) VALUES (v_fila.id, v_nuevo);
        v_n := v_n + 1;
    END LOOP;

    -- La pinta de cada enlace, apuntando a los ids nuevos. La que apuntaba a
    -- un enlace que no se copió —uno de la papelera— se cae sola.
    UPDATE ecommerce.encabezado e
       SET config = jsonb_set(e.config, '{menu_enlaces}', COALESCE(
               (SELECT jsonb_object_agg(m.nuevo::text, x.value)
                  FROM jsonb_each(e.config -> 'menu_enlaces') x
                  JOIN tmp_mapa_menu m ON m.viejo::text = x.key), '{}'::jsonb))
     WHERE e.id = v_id
       AND jsonb_typeof(e.config -> 'menu_enlaces') = 'object';

    RETURN jsonb_build_object('success', true,
        'message', format('«%s» creado, copiando el de «%s» con sus %s enlaces. Ponle sus fechas',
                          v_nombre,
                          (SELECT nombre FROM ecommerce.encabezado WHERE id = v_de),
                          v_n),
        'id', v_id,
        'data', (ecommerce.fn_encabezado_obtener(v_id) -> 'data'));
END;
$function$;


-- ============================================================================
-- 14. Y BORRARLO SE LLEVA SU MENÚ
-- ============================================================================

CREATE OR REPLACE FUNCTION ecommerce.fn_encabezados_eliminar(
    p_id bigint,
    p_usuario_id bigint DEFAULT NULL,
    p_usuario_login character varying DEFAULT NULL,
    p_usuario_nombre character varying DEFAULT NULL,
    p_ip_address inet DEFAULT NULL,
    p_user_agent text DEFAULT NULL,
    p_request_id uuid DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'ecommerce', 'auditoria'
AS $function$
DECLARE
    v_fila    record;
    v_enlaces integer;
    v_mas     integer;
BEGIN
    PERFORM ecommerce.fn_contexto_auditoria('ecommerce.encabezado',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    SELECT * INTO v_fila FROM ecommerce.encabezado WHERE id = p_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Ese encabezado no existe' USING ERRCODE = 'P0013';
    END IF;

    IF v_fila.principal THEN
        RAISE EXCEPTION 'El predeterminado no se borra: nombra predeterminado a otro primero'
            USING ERRCODE = 'P0016';
    END IF;

    -- SU MENÚ SE VA CON ÉL, y a mano aunque la clave ajena lo haría sola:
    -- así se puede decir cuántos enlaces se perdieron, que es lo que hay que
    -- pensarse antes de borrar. Los hijos primero, que la clave ajena del
    -- padre apunta a esta misma tabla.
    DELETE FROM ecommerce.encabezado_enlaces WHERE encabezado_id = p_id AND padre_id IS NOT NULL;
    GET DIAGNOSTICS v_enlaces = ROW_COUNT;
    DELETE FROM ecommerce.encabezado_enlaces WHERE encabezado_id = p_id;
    GET DIAGNOSTICS v_mas = ROW_COUNT;
    v_enlaces := v_enlaces + v_mas;

    -- NO HAY PAPELERA, y es a propósito: un encabezado es un puñado de colores
    -- y un logo, y el logo sigue en la biblioteca de imágenes. Lo que se pierde
    -- se vuelve a elegir en un minuto.
    DELETE FROM ecommerce.encabezado WHERE id = p_id;

    RETURN jsonb_build_object('success', true,
        'message', format('«%s» borrado%s', v_fila.nombre,
                          CASE WHEN v_enlaces > 0 THEN format(', con su menú de %s enlaces', v_enlaces)
                               ELSE '' END),
        'data', (ecommerce.fn_encabezado_obtener(NULL) -> 'data'));
END;
$function$;


-- ============================================================================
-- 15. LO QUE PIDE LA TIENDA
-- ============================================================================
-- El menú del encabezado que mande hoy, que ahora hay que nombrar: antes la
-- función del menú no preguntaba de cuál porque sólo había uno.

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
            -- EL ENCABEZADO QUE TOQUE HOY, no el único que había: manda el
            -- que esté en fecha y, si no hay ninguno de campaña, el
            -- predeterminado. Lo decide fn_encabezado_vigente_id
            'config', (SELECT config FROM ecommerce.encabezado WHERE id = ecommerce.fn_encabezado_vigente_id()),
            -- El logo que se subió en el CRM; sin él, la tienda pinta el suyo
            'logo', (SELECT logo FROM ecommerce.encabezado WHERE id = ecommerce.fn_encabezado_vigente_id()),
            -- EL MENÚ ENTERO, con los niveles que tenga: lo arma una función
            -- que se llama a sí misma, porque aquí ya no se sabe cuántos hay
            'menu', ecommerce.fn_encabezado_menu_publico(ecommerce.fn_encabezado_vigente_id(), NULL),
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


-- ============================================================================
-- 16. LA CUENTA DE LA PORTADA DEL MÓDULO
-- ============================================================================
-- «6 enlaces, 1 oculto» en la tarjeta del encabezado: los del que se está
-- viendo en la tienda. Sumar los de todos los encabezados daría la cuenta de
-- un menú que no existe.

CREATE OR REPLACE FUNCTION ecommerce.fn_resumen()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
AS $function$
DECLARE
    v jsonb := '{}'::jsonb;
    n bigint;
    m bigint;
BEGIN
    -- ---------- Lo ya migrado ----------
    SELECT count(*) FILTER (WHERE deleted_at IS NULL),
           count(*) FILTER (WHERE deleted_at IS NULL AND NOT activo)
      INTO n, m FROM ecommerce.paginas_informativas;
    v := v || jsonb_build_object('paginas', jsonb_build_object('total', n, 'ocultas', m));

    SELECT count(*) FILTER (WHERE deleted_at IS NULL),
           count(*) FILTER (WHERE deleted_at IS NULL AND NOT activo)
      INTO n, m FROM ecommerce.encabezado_enlaces
     WHERE encabezado_id = ecommerce.fn_encabezado_vigente_id();
    v := v || jsonb_build_object('encabezado', jsonb_build_object('enlaces', n, 'ocultos', m));

    SELECT count(*) FILTER (WHERE deleted_at IS NULL) INTO n FROM ecommerce.pie_columnas;
    SELECT count(*) FILTER (WHERE deleted_at IS NULL) INTO m FROM ecommerce.pie_enlaces;
    v := v || jsonb_build_object('pie', jsonb_build_object('columnas', n, 'enlaces', m));

    SELECT count(*) FILTER (WHERE estado = 'visible'), count(*)
      INTO n, m FROM ecommerce.fn_categorias_web_estado();
    v := v || jsonb_build_object('categorias', jsonb_build_object('visibles', n, 'total', m));

    SELECT count(*) INTO n FROM ecommerce.galerias;
    SELECT count(*) FILTER (WHERE deleted_at IS NULL) INTO m FROM ecommerce.galerias_imagenes;
    v := v || jsonb_build_object('galerias', jsonb_build_object('galerias', n, 'imagenes', m));

    SELECT count(*) FILTER (WHERE activo), count(*)
      INTO n, m FROM ecommerce.inicio_secciones
     WHERE ecommerce.fn_inicio_seccion_viva(grupo_productos_id);
    v := v || jsonb_build_object('inicio', jsonb_build_object('visibles', n, 'total', m));

    -- ---------- Lo que todavía lee de las tablas viejas ----------
    -- Cuando se migre cada una, esta parte se cambia por la nueva. Mientras
    -- tanto, `to_regclass` evita que la portada entera reviente.
    IF to_regclass('ecommerce.sucursal') IS NOT NULL THEN
        EXECUTE 'SELECT count(*) FILTER (WHERE suc_eliminado_en IS NULL) FROM ecommerce.sucursal' INTO n;
        EXECUTE 'SELECT count(*) FILTER (WHERE sci_eliminado_en IS NULL) FROM ecommerce.sucursal_ciudad' INTO m;
        v := v || jsonb_build_object('sucursales', jsonb_build_object('tiendas', n, 'ciudades', m));
    END IF;

    IF to_regclass('ecommerce.pagina_marca') IS NOT NULL THEN
        EXECUTE 'SELECT count(*) FILTER (WHERE pma_eliminado_en IS NULL) FROM ecommerce.pagina_marca' INTO n;
        v := v || jsonb_build_object('paginas_marca', jsonb_build_object('paginas', n));
    END IF;

    IF to_regclass('ecommerce.franjas_detalle') IS NOT NULL THEN
        EXECUTE 'SELECT count(*) FILTER (WHERE fde_eliminado_en IS NULL) FROM ecommerce.franjas_detalle' INTO n;
        v := v || jsonb_build_object('franjas', jsonb_build_object('franjas', n));
    END IF;

    IF to_regclass('ecommerce.bloque_producto') IS NOT NULL THEN
        EXECUTE 'SELECT count(*) FILTER (WHERE bpr_eliminado_en IS NULL) FROM ecommerce.bloque_producto' INTO n;
        v := v || jsonb_build_object('bloques', jsonb_build_object('bloques', n));
    END IF;

    -- El catálogo sale de inventarios, que es de otro módulo
    SELECT count(*) FILTER (WHERE deleted_at IS NULL) INTO n FROM inventarios.productos;
    SELECT count(*) FILTER (WHERE deleted_at IS NULL) INTO m FROM inventarios.marcas;
    v := v || jsonb_build_object('productos', jsonb_build_object('productos', n),
                                 'marcas_tienda', jsonb_build_object('marcas', m));

    v := v || jsonb_build_object('grupos_productos', jsonb_build_object(
            'grupos', (SELECT count(*) FROM ecommerce.grupos_productos
                             WHERE deleted_at IS NULL),
            'productos',  (SELECT count(*) FROM ecommerce.grupos_productos_items i
                             JOIN ecommerce.grupos_productos s ON s.id = i.grupo_id
                             JOIN inventarios.productos p ON p.id = i.producto_id
                            WHERE s.deleted_at IS NULL AND p.deleted_at IS NULL)));
    RETURN jsonb_build_object('success', true, 'message', 'Resumen de la página web', 'data', v);
END;
$function$;


COMMIT;


-- ============================================================================
-- COMPROBACIÓN — no deja nada escrito
-- ============================================================================
-- La única que escribe es la de la clave ajena, y lo hace dentro de un bloque
-- con EXCEPTION: eso es una subtransacción, así que la fila de prueba se
-- deshace salga como salga.

DO $comprobar$
DECLARE
    v_falta  text[] := '{}';
    v_n      integer;
    v_enc1   bigint;
    v_enc2   bigint;
    v_padre  bigint;
    v_menu   jsonb;
    v_paso   boolean := false;
BEGIN
    -- ---------- La columna ----------
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                    WHERE table_schema = 'ecommerce' AND table_name = 'encabezado_enlaces'
                      AND column_name = 'encabezado_id' AND is_nullable = 'NO') THEN
        v_falta := array_append(v_falta, 'no está la columna encabezado_id, o admite vacíos');
    END IF;

    -- ---------- La clave ajena del padre, con las dos columnas ----------
    IF NOT EXISTS (SELECT 1 FROM pg_constraint c
                    WHERE c.conname = 'fk_encabezado_enlaces_padre'
                      AND array_length(c.conkey, 1) = 2) THEN
        v_falta := array_append(v_falta, 'la clave ajena del padre no lleva el encabezado');
    END IF;

    -- ---------- Y borrar un encabezado se lleva su menú ----------
    IF NOT EXISTS (SELECT 1 FROM pg_constraint c
                    WHERE c.conname = 'fk_encabezado_enlaces_encabezado' AND c.confdeltype = 'c') THEN
        v_falta := array_append(v_falta, 'el menú no se va con su encabezado al borrarlo');
    END IF;

    -- ---------- Ninguno se quedó sin menú ----------
    SELECT count(*) INTO v_n FROM ecommerce.encabezado e
     WHERE NOT EXISTS (SELECT 1 FROM ecommerce.encabezado_enlaces x
                        WHERE x.encabezado_id = e.id AND x.deleted_at IS NULL);
    IF v_n > 0 THEN
        v_falta := array_append(v_falta, v_n || ' encabezados se quedaron sin menú');
    END IF;

    -- ---------- Ninguno cruzado ----------
    SELECT count(*) INTO v_n
      FROM ecommerce.encabezado_enlaces h
      JOIN ecommerce.encabezado_enlaces p ON p.id = h.padre_id
     WHERE p.encabezado_id <> h.encabezado_id;
    IF v_n > 0 THEN
        v_falta := array_append(v_falta, v_n || ' enlaces cuelgan de un enlace de otro encabezado');
    END IF;

    -- ---------- Las firmas viejas ya no están ----------
    IF EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                WHERE n.nspname = 'ecommerce' AND p.proname = 'fn_encabezado_enlaces_json'
                  AND p.pronargs = 0) THEN
        v_falta := array_append(v_falta, 'sigue estando fn_encabezado_enlaces_json() sin encabezado');
    END IF;
    IF EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                WHERE n.nspname = 'ecommerce' AND p.proname = 'fn_encabezado_menu_publico'
                  AND p.pronargs = 1) THEN
        v_falta := array_append(v_falta, 'sigue estando fn_encabezado_menu_publico(padre) sin encabezado');
    END IF;

    -- ---------- Cada menú, sólo el suyo ----------
    SELECT id INTO v_enc1 FROM ecommerce.encabezado WHERE principal;
    SELECT id INTO v_enc2 FROM ecommerce.encabezado WHERE NOT principal ORDER BY id LIMIT 1;

    IF v_enc2 IS NOT NULL THEN
        SELECT count(*) INTO v_n
          FROM jsonb_array_elements(ecommerce.fn_encabezado_enlaces_json(v_enc2)) x
         WHERE (x ->> 'id')::bigint IN (SELECT id FROM ecommerce.encabezado_enlaces
                                         WHERE encabezado_id = v_enc1);
        IF v_n > 0 THEN
            v_falta := array_append(v_falta, 'el menú de un encabezado trae ' || v_n || ' enlaces de otro');
        END IF;

        -- ---------- Y la base no deja cruzarlos ----------
        SELECT id INTO v_padre FROM ecommerce.encabezado_enlaces
         WHERE encabezado_id = v_enc1 AND padre_id IS NULL AND deleted_at IS NULL
         ORDER BY id LIMIT 1;

        IF v_padre IS NOT NULL THEN
            BEGIN
                INSERT INTO ecommerce.encabezado_enlaces (encabezado_id, padre_id, texto)
                VALUES (v_enc2, v_padre, 'ZZ prueba de la clave ajena');
                -- Si llegó aquí, coló: se levanta para que la subtransacción
                -- se deshaga y la fila no quede
                RAISE EXCEPTION 'se pudo' USING ERRCODE = 'P0001';
            EXCEPTION
                WHEN foreign_key_violation THEN NULL;       -- lo esperado
                WHEN raise_exception THEN v_paso := true;
            END;
            IF v_paso THEN
                v_falta := array_append(v_falta,
                    'la base deja colgar un enlace de un principal de otro encabezado');
            END IF;
        END IF;
    END IF;

    -- ---------- Y la tienda sigue recibiendo un menú ----------
    v_menu := ecommerce.fn_encabezado_menu_publico(ecommerce.fn_encabezado_vigente_id(), NULL);
    IF jsonb_typeof(v_menu) <> 'array' THEN
        v_falta := array_append(v_falta, 'el menú público no es una lista');
    END IF;

    IF array_length(v_falta, 1) > 0 THEN
        RAISE EXCEPTION 'El menú por encabezado no quedó bien: %', array_to_string(v_falta, '; ');
    END IF;

    RAISE NOTICE 'Comprobado: cada encabezado lleva su menú, ninguno se quedó vacío, ninguno cruza de encabezado y la tienda recibe el del que manda (% de primer nivel). No quedó nada.',
                 jsonb_array_length(v_menu);
END;
$comprobar$;
