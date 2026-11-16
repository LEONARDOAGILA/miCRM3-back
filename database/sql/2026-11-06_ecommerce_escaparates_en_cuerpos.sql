-- ============================================================================
-- ECOMMERCE · UN ESCAPARATE, EN LAS PÁGINAS QUE QUIERAS
-- ============================================================================
-- Fecha: 2026-11-06
-- Va DESPUÉS de 2026-11-06_ecommerce_secciones_por_cuerpo.sql.
--
-- Las secciones de «Productos por sección» nacen en el cuerpo principal, y
-- hasta aquí no había manera de enseñarlas en otro. La tabla ya lo admite
-- —lo único de cada escaparate es por CUERPO, no en toda la portada—, así
-- que falta la puerta:
--
--     fn_inicio_escaparates_disponibles(p_cuerpo_id)  los que NO están en él
--     fn_inicio_escaparate_poner(p_cuerpo_id, p_seccion_id)   lo añade al final
--     fn_inicio_escaparate_quitar(p_id)               quita esa fila
--
-- QUITARLO DE UNA PÁGINA NO LO BORRA: el escaparate y sus productos siguen en
-- «Productos por sección», y se puede volver a poner. Lo que se va es la fila
-- de esa página, con su rótulo y sus colores, que eran de ahí.
--
-- CADA PÁGINA LE PONE SU RÓTULO Y SUS COLORES: «Los más vendidos» puede
-- llamarse igual en las dos y verse distinto, porque lo que se guarda en la
-- fila es de la fila. Lo que no cambia es QUÉ PRODUCTOS tiene: eso es del
-- escaparate.
--
-- Idempotente.
-- ============================================================================
\set ON_ERROR_STOP on

BEGIN;

-- ----------------------------------------------------------------------------
-- 1. LOS QUE SE PUEDEN AÑADIR
-- ----------------------------------------------------------------------------
-- Los escaparates vivos que ESTE cuerpo todavía no enseña. Con cuántos
-- productos tiene cada uno: uno vacío se puede añadir, pero la tienda se lo
-- salta, y conviene saberlo antes de ponerlo.
CREATE OR REPLACE FUNCTION ecommerce.fn_inicio_escaparates_disponibles(p_cuerpo_id bigint DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
AS $function$
    SELECT jsonb_build_object('success', true, 'message', 'Escaparates que se pueden añadir',
        'data', COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
                       'id', s.id,
                       'nombre', s.nombre,
                       'cuantos', (SELECT count(*)
                                     FROM ecommerce.producto_secciones_items it
                                     JOIN inventarios.productos p ON p.id = it.producto_id
                                    WHERE it.seccion_id = s.id AND p.deleted_at IS NULL),
                       -- En cuántas páginas sale ya, para no repetirlo sin querer
                       'en_paginas', (SELECT count(*) FROM ecommerce.inicio_secciones i
                                       WHERE i.producto_seccion_id = s.id))
                   ORDER BY s.orden, s.id)
              FROM ecommerce.producto_secciones s
             WHERE s.deleted_at IS NULL
               AND NOT EXISTS (
                   SELECT 1 FROM ecommerce.inicio_secciones i
                    WHERE i.producto_seccion_id = s.id
                      AND i.cuerpo_id = COALESCE(p_cuerpo_id, ecommerce.fn_cuerpo_principal_id()))
            ), '[]'::jsonb));
$function$;

-- ----------------------------------------------------------------------------
-- 2. PONERLO
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ecommerce.fn_inicio_escaparate_poner(
    p_cuerpo_id      bigint,
    p_seccion_id     bigint,
    p_usuario_id     bigint  DEFAULT NULL,
    p_usuario_login  varchar DEFAULT NULL,
    p_usuario_nombre varchar DEFAULT NULL,
    p_ip_address     inet    DEFAULT NULL,
    p_user_agent     text    DEFAULT NULL,
    p_request_id     uuid    DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'ecommerce', 'auditoria'
AS $function$
DECLARE
    v_cuerpo  bigint := COALESCE(p_cuerpo_id, ecommerce.fn_cuerpo_principal_id());
    v_nombre  text;
    v_pagina  text;
    v_orden   integer;
BEGIN
    PERFORM ecommerce.fn_contexto_auditoria('ecommerce.inicio_secciones',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    SELECT nombre INTO v_pagina FROM ecommerce.cuerpos
     WHERE id = v_cuerpo AND deleted_at IS NULL;
    IF v_pagina IS NULL THEN
        RAISE EXCEPTION 'Ese cuerpo no existe' USING ERRCODE = 'P0013';
    END IF;

    SELECT nombre INTO v_nombre FROM ecommerce.producto_secciones
     WHERE id = p_seccion_id AND deleted_at IS NULL;
    IF v_nombre IS NULL THEN
        RAISE EXCEPTION 'Esa sección de productos no existe o está en la papelera' USING ERRCODE = 'P0013';
    END IF;

    IF EXISTS (SELECT 1 FROM ecommerce.inicio_secciones
                WHERE cuerpo_id = v_cuerpo AND producto_seccion_id = p_seccion_id) THEN
        RAISE EXCEPTION '«%» ya está en «%»', v_nombre, v_pagina USING ERRCODE = 'P0015';
    END IF;

    SELECT COALESCE(max(orden), 0) + 1 INTO v_orden
      FROM ecommerce.inicio_secciones WHERE cuerpo_id = v_cuerpo;

    -- Nace ENCENDIDA y al final, como cuando se crea el escaparate: lo que se
    -- acaba de añadir se quiere ver.
    INSERT INTO ecommerce.inicio_secciones (cuerpo_id, clave, nombre, orden, activo, producto_seccion_id)
    VALUES (v_cuerpo, 'seccion_' || p_seccion_id, v_nombre, v_orden, true, p_seccion_id);

    RETURN jsonb_build_object('success', true,
        'message', format('«%s» añadida a «%s»', v_nombre, v_pagina),
        'data', (ecommerce.fn_inicio_listar(v_cuerpo) -> 'data'));
END;
$function$;

-- ----------------------------------------------------------------------------
-- 3. QUITARLO
-- ----------------------------------------------------------------------------
-- Se va la FILA de esa página, no el escaparate: sus productos siguen donde
-- estaban y se puede volver a poner.
CREATE OR REPLACE FUNCTION ecommerce.fn_inicio_escaparate_quitar(
    p_id             bigint,
    p_usuario_id     bigint  DEFAULT NULL,
    p_usuario_login  varchar DEFAULT NULL,
    p_usuario_nombre varchar DEFAULT NULL,
    p_ip_address     inet    DEFAULT NULL,
    p_user_agent     text    DEFAULT NULL,
    p_request_id     uuid    DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'ecommerce', 'auditoria'
AS $function$
DECLARE
    v_cuerpo   bigint;
    v_nombre   text;
    v_pagina   text;
    v_apunta   bigint;
BEGIN
    PERFORM ecommerce.fn_contexto_auditoria('ecommerce.inicio_secciones',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    SELECT cuerpo_id, nombre, producto_seccion_id
      INTO v_cuerpo, v_nombre, v_apunta
      FROM ecommerce.inicio_secciones WHERE id = p_id;
    IF v_nombre IS NULL THEN
        RAISE EXCEPTION 'Esa sección no existe' USING ERRCODE = 'P0013';
    END IF;
    IF v_apunta IS NULL THEN
        RAISE EXCEPTION 'Esa sección no es un escaparate de productos: no se quita desde aquí'
              USING ERRCODE = 'P0015';
    END IF;

    SELECT nombre INTO v_pagina FROM ecommerce.cuerpos WHERE id = v_cuerpo;

    DELETE FROM ecommerce.inicio_secciones WHERE id = p_id;

    -- El orden se compacta para que no queden huecos, sólo en su cuerpo
    WITH nuevo AS (
        SELECT id, row_number() OVER (ORDER BY orden, id) AS n
          FROM ecommerce.inicio_secciones WHERE cuerpo_id = v_cuerpo
    )
    UPDATE ecommerce.inicio_secciones s
       SET orden = nuevo.n
      FROM nuevo
     WHERE nuevo.id = s.id AND s.orden <> nuevo.n;

    RETURN jsonb_build_object('success', true,
        'message', format('«%s» ya no sale en «%s». Sus productos siguen en «Productos por sección»',
                          v_nombre, v_pagina),
        'data', (ecommerce.fn_inicio_listar(v_cuerpo) -> 'data'));
END;
$function$;

-- ----------------------------------------------------------------------------
-- 4. COMPROBACIÓN
-- ----------------------------------------------------------------------------
DO $comprobar$
DECLARE
    v_principal bigint;
    v_nuevo     bigint;
    v_escaparate bigint;
    v_fila      bigint;
    v_antes     integer;
    v_en_principal integer;
    v_malo      text;
BEGIN
    v_principal := ecommerce.fn_cuerpo_principal_id();

    SELECT id INTO v_escaparate FROM ecommerce.producto_secciones
     WHERE deleted_at IS NULL ORDER BY id LIMIT 1;
    IF v_escaparate IS NULL THEN
        RAISE NOTICE 'No hay escaparates: me salto la comprobación.';
        RETURN;
    END IF;

    SELECT count(*) INTO v_en_principal FROM ecommerce.inicio_secciones
     WHERE cuerpo_id = v_principal AND producto_seccion_id = v_escaparate;

    BEGIN
        v_nuevo := (ecommerce.fn_cuerpos_guardar(NULL, jsonb_build_object(
                        'nombre', 'ZZ escaparate claude', 'ruta', 'zz-escaparate-claude'))
                    -> 'data' ->> 'id')::bigint;

        -- Está disponible para el cuerpo nuevo, y no para el principal (que ya lo tiene)
        IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(
                         ecommerce.fn_inicio_escaparates_disponibles(v_nuevo) -> 'data') e
                        WHERE (e ->> 'id')::bigint = v_escaparate) THEN
            RAISE EXCEPTION 'El escaparate no sale como disponible para el cuerpo nuevo';
        END IF;

        v_antes := jsonb_array_length(ecommerce.fn_inicio_listar(v_nuevo) -> 'data');
        PERFORM ecommerce.fn_inicio_escaparate_poner(v_nuevo, v_escaparate);

        IF jsonb_array_length(ecommerce.fn_inicio_listar(v_nuevo) -> 'data') <> v_antes + 1 THEN
            RAISE EXCEPTION 'No se añadió la fila del escaparate';
        END IF;
        -- Y en el principal se queda como estaba: ponerlo aquí no lo mueve de
        -- allá. Se compara contra lo que había ANTES y no contra «tiene que
        -- estar», porque desde 2026-11-07 un escaparate nuevo no nace en
        -- ninguna página: puede no estar en la principal y eso es correcto.
        IF (SELECT count(*) FROM ecommerce.inicio_secciones
             WHERE cuerpo_id = v_principal AND producto_seccion_id = v_escaparate) <> v_en_principal THEN
            RAISE EXCEPTION 'Ponerlo en otra página cambió lo que hay en la principal';
        END IF;

        -- Dos veces en la misma página, no
        BEGIN
            PERFORM ecommerce.fn_inicio_escaparate_poner(v_nuevo, v_escaparate);
            v_malo := 'se pudo poner el mismo escaparate dos veces en la misma página';
        EXCEPTION WHEN SQLSTATE 'P0015' THEN NULL;
        END;

        -- Quitarlo se lleva la fila y NO el escaparate
        SELECT id INTO v_fila FROM ecommerce.inicio_secciones
         WHERE cuerpo_id = v_nuevo AND producto_seccion_id = v_escaparate;
        PERFORM ecommerce.fn_inicio_escaparate_quitar(v_fila);

        IF EXISTS (SELECT 1 FROM ecommerce.inicio_secciones WHERE id = v_fila) THEN
            RAISE EXCEPTION 'La fila no se quitó';
        END IF;
        IF NOT EXISTS (SELECT 1 FROM ecommerce.producto_secciones
                        WHERE id = v_escaparate AND deleted_at IS NULL) THEN
            RAISE EXCEPTION 'Quitarlo de una página se llevó el escaparate entero';
        END IF;

        -- Y una sección de fábrica no se quita por esta puerta
        BEGIN
            PERFORM ecommerce.fn_inicio_escaparate_quitar(
                (SELECT id FROM ecommerce.inicio_secciones
                  WHERE cuerpo_id = v_nuevo AND producto_seccion_id IS NULL LIMIT 1));
            v_malo := COALESCE(v_malo, 'se pudo quitar una sección que no es un escaparate');
        EXCEPTION WHEN SQLSTATE 'P0015' THEN NULL;
        END;

        RAISE EXCEPTION 'deshacer' USING ERRCODE = 'P0099';
    EXCEPTION WHEN SQLSTATE 'P0099' THEN
        NULL;
    END;

    IF v_malo IS NOT NULL THEN
        RAISE EXCEPTION '%', v_malo;
    END IF;
    IF EXISTS (SELECT 1 FROM ecommerce.cuerpos WHERE nombre LIKE 'ZZ %claude') THEN
        RAISE EXCEPTION 'El cuerpo de prueba se quedó en la base';
    END IF;

    RAISE NOTICE 'Comprobado: un escaparate se puede enseñar en varias páginas, no se repite en la misma, quitarlo de una no lo borra y por esa puerta sólo salen escaparates. No quedó nada.';
END
$comprobar$;

COMMIT;
