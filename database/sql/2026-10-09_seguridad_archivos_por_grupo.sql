-- ===========================================================================
-- EL GESTOR DE ARCHIVOS PASA A MANDARSE POR GRUPOS
-- ===========================================================================
-- Fecha: 2026-10-09
--
-- El gestor de archivos nació antes que los grupos, y por eso decidía quién
-- era administrador con users.type_user IN (1, 2). Ahora que el árbol de
-- grupos existe y es lo que usa todo lo demás —la lista de clientes, la
-- agenda, el tablero y la visibilidad de datos de ayer—, esta función pasa a
-- preguntarle a seguridad.grupos.es_administrador, que es la misma señal.
--
-- ASÍ DEJA DE HABER DOS VERDADES. Hoy SISTEMAS-GYE tiene type_user = 3
-- («usuario sistema») y su grupo es administrador: manda clientes y gestiones
-- pero no puede administrar archivos. Con esto, una sola señal.
--
-- NADIE PIERDE NADA. Comprobado antes de escribir esto: los 2 usuarios con
-- type_user 1 están los dos en grupos administradores, y no hay ninguno con
-- type_user 1 o 2 cuyo grupo no lo sea. El único cambio real es que
-- SISTEMAS-GYE gana lo que ya tenía en todo lo demás.
--
-- SIN GRUPO NO ES ADMINISTRADOR (COALESCE a false): grupo_id admite nulos, y
-- un usuario sin grupo no puede heredar un permiso que nadie le dio.
--
-- EL RESTO DE LA FUNCIÓN NO SE TOCA: propietario, permisos directos, los
-- heredados de los ancestros, DENEGADO y público se quedan exactamente igual.
-- Este fichero es su definición de hoy con las dos primeras líneas cambiadas.
--
-- users.type_user se queda donde está: lo sigue guardando y enseñando la
-- pantalla del usuario, y seguridad.fn_usuarios_* lo escriben. Simplemente
-- ya no decide permisos en ningún sitio.
--
-- Idempotente (CREATE OR REPLACE, misma firma).
-- ===========================================================================

CREATE OR REPLACE FUNCTION seguridad.fn_permiso_archivo(p_user_id bigint, p_archivo_id bigint, p_en_papelera boolean DEFAULT false)
 RETURNS TABLE(ver boolean, ejecutar boolean, descargar boolean, crear boolean, editar boolean, eliminar boolean, administrar boolean, restaurar boolean, origen text)
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
    v_admin       boolean;
    v_propietario bigint;
    v_publico     boolean;
    r             record;
BEGIN
    -- Manda el grupo, no users.type_user: es la misma señal con la que se
    -- recortan los clientes, la agenda, el tablero y la visibilidad de datos
    SELECT COALESCE(g.es_administrador, false) INTO v_admin
      FROM seguridad.users u
      LEFT JOIN seguridad.grupos g ON g.id = u.grupo_id
     WHERE u.id = p_user_id;

    IF COALESCE(v_admin, false) THEN
        RETURN QUERY SELECT true, true, true, true, true, true, true, true, 'ADMIN'::text;
        RETURN;
    END IF;

    SELECT a.propietario_id INTO v_propietario FROM core.archivos a
     WHERE a.id = p_archivo_id AND (p_en_papelera OR a.deleted_at IS NULL);
    IF NOT FOUND THEN
        RETURN QUERY SELECT false, false, false, false, false, false, false, false, 'NINGUNO'::text;
        RETURN;
    END IF;
    IF v_propietario = p_user_id THEN
        RETURN QUERY SELECT true, true, true, true, true, true, true, true, 'PROPIETARIO'::text;
        RETURN;
    END IF;

    -- El archivo y todos sus ancestros (profundidad 0 = él mismo); se toma
    -- la fila vigente del usuario más cercana
    WITH RECURSIVE cadena AS (
        SELECT a.id, a.padre, a.publico, 0 AS prof FROM core.archivos a WHERE a.id = p_archivo_id
        UNION ALL
        SELECT a.id, a.padre, a.publico, c.prof + 1 FROM core.archivos a JOIN cadena c ON a.id = c.padre
    )
    SELECT p.ver, p.ejecutar, p.descargar, p.crear, p.editar, p.eliminar, p.administrar, p.restaurar, p.denegar, c.prof
    INTO r
    FROM cadena c
    JOIN seguridad.permisos_archivos p
      ON p.archivo_id = c.id
     AND p.user_id = p_user_id
     AND (c.prof = 0 OR p.hereda)                                     -- los de ancestros sólo si heredan
     AND (p.vigente_hasta IS NULL OR p.vigente_hasta > now())
    ORDER BY c.prof
    LIMIT 1;

    IF FOUND THEN
        IF r.denegar THEN
            RETURN QUERY SELECT false, false, false, false, false, false, false, false, 'DENEGADO'::text;
        ELSE
            RETURN QUERY SELECT r.ver, r.ejecutar, r.descargar, r.crear, r.editar, r.eliminar, r.administrar, r.restaurar,
                                CASE WHEN r.prof = 0 THEN 'DIRECTO' ELSE 'HEREDADO' END::text;
        END IF;
        RETURN;
    END IF;

    -- Sin filas: público si él o algún ancestro lo es
    WITH RECURSIVE cadena AS (
        SELECT a.id, a.padre, a.publico FROM core.archivos a WHERE a.id = p_archivo_id
        UNION ALL
        SELECT a.id, a.padre, a.publico FROM core.archivos a JOIN cadena c ON a.id = c.padre
    )
    SELECT bool_or(c.publico) INTO v_publico FROM cadena c;

    IF COALESCE(v_publico, false) THEN
        RETURN QUERY SELECT true, true, false, false, false, false, false, false, 'PUBLICO'::text;
        RETURN;
    END IF;

    RETURN QUERY SELECT false, false, false, false, false, false, false, false, 'NINGUNO'::text;
END;
$function$

;

-- ---------------------------------------------------------------------------
-- COMPROBACION
-- ---------------------------------------------------------------------------
-- Quien manda archivos despues del cambio, y con que senal:
--
--   SELECT u.login_user, u.type_user, g.nombre AS grupo, g.es_administrador,
--          (SELECT origen FROM seguridad.fn_permiso_archivo(u.id, (SELECT min(id) FROM core.archivos))) AS origen,
--          (SELECT count(*) FROM seguridad.fn_archivos_visibles(u.id))                                  AS ve_archivos
--     FROM seguridad.users u
--     LEFT JOIN seguridad.grupos g ON g.id = u.grupo_id
--    WHERE g.es_administrador OR u.type_user IN (1, 2)
--    ORDER BY 1;
