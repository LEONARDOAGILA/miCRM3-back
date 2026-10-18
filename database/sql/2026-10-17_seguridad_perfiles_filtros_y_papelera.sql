-- ===========================================================================
-- PERFILES: FILTROS DE COLUMNA Y PAPELERA DE RECICLAJE
-- ===========================================================================
-- Fecha: 2026-10-17
-- Se aplica después de 2026-10-17_seguridad_horarios_filtros_de_columna.sql.
--
-- Dos cosas:
--
--   1) LOS FILTROS DE LA CABECERA SE APLICAN EN EL SERVIDOR. La pantalla
--      pagina, así que ag-Grid sólo tiene las filas de la página y filtrar
--      ahí buscaría dentro de diez. El modelo llega en p_filtros, ya
--      traducido por el controlador. Se reusan ventas.fn_filtro_texto y
--      ventas.fn_filtro_numero.
--
--   2) PAPELERA DE RECICLAJE. Hasta ahora «eliminar» un perfil lo borraba de
--      verdad, con sus accesos. Eso es mucho perder por un clic: un perfil
--      son sus permisos pantalla por pantalla, y rehacerlos a mano es media
--      tarde. Ahora va a la papelera (deleted_at / deleted_by) CON SUS
--      ACCESOS INTACTOS, y desde allí se restaura tal cual o se borra de
--      verdad.
--
-- LA REGLA QUE MANDA: un perfil que alguien está usando no se va a la
-- papelera. Si lo tienen usuarios o grupos, se rechaza y se dice cuántos;
-- para eso está desactivarlo. Si se fuera igualmente, esos usuarios se
-- quedarían con un perfil que ya no sale en ningún listado pero que les
-- sigue dando accesos: una incoherencia que no se ve hasta que duele.
--
-- Lo que está en la papelera no sale ni en el listado ni en el combo de
-- perfiles (el de la ficha de usuario), así que no se puede volver a asignar
-- sin restaurarlo antes.
--
-- Errores de negocio nuevos:
--   P0021  el perfil está en uso (usuarios o grupos)
--   P0022  el perfil no está en la papelera
--
-- Cambia la firma del listado, así que se suelta la función antes.
-- Idempotente.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- LAS COLUMNAS DE LA PAPELERA
-- ---------------------------------------------------------------------------
ALTER TABLE seguridad.perfiles ADD COLUMN IF NOT EXISTS deleted_at timestamptz;
ALTER TABLE seguridad.perfiles ADD COLUMN IF NOT EXISTS deleted_by varchar(100);
COMMENT ON COLUMN seguridad.perfiles.deleted_at IS 'Fecha en que se envió a la papelera de reciclaje (NULL = vigente)';
COMMENT ON COLUMN seguridad.perfiles.deleted_by IS 'Login de quien lo envió a la papelera';
CREATE INDEX IF NOT EXISTS ix_perfiles_deleted_at ON seguridad.perfiles (deleted_at) WHERE deleted_at IS NOT NULL;


-- ---------------------------------------------------------------------------
-- UNA FILA DE PERFIL, SIEMPRE IGUAL
-- ---------------------------------------------------------------------------
-- Antes cada función se armaba su jsonb a mano, y el listado y la papelera se
-- podían ir separando sin que nadie lo notara.
CREATE OR REPLACE FUNCTION seguridad.fn_perfiles_json(p_id bigint)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
AS $function$
    SELECT jsonb_build_object(
        'id',           p.id,
        'nombre',       p.nombre,
        'inactividad',  p.inactividad,
        'activo',       p.activo,
        -- Cuánta gente depende de él: es lo que decide si se puede borrar
        'num_usuarios', (SELECT COUNT(*) FROM seguridad.users u
                          WHERE u.perfil_id = p.id AND u.deleted_at IS NULL),
        'num_grupos',   (SELECT COUNT(*) FROM seguridad.grupos g WHERE g.perfil_id = p.id),
        'num_accesos',  (SELECT COUNT(*) FROM seguridad.accesos a WHERE a.perfil_id = p.id),
        -- La papelera: NULL mientras el perfil está vigente
        'deleted_at',   to_char(p.deleted_at, 'YYYY-MM-DD HH24:MI:SS'),
        'deleted_by',   p.deleted_by,
        'created_by',   p.created_by,
        'updated_by',   p.updated_by,
        'created_at',   to_char(p.created_at, 'YYYY-MM-DD HH24:MI:SS'),
        'updated_at',   to_char(p.updated_at, 'YYYY-MM-DD HH24:MI:SS')
    )
      FROM seguridad.perfiles p
     WHERE p.id = p_id;
$function$;


-- ---------------------------------------------------------------------------
-- EL LISTADO: filtros de columna, y sin lo que está en la papelera
-- ---------------------------------------------------------------------------
-- De paso se quita la duplicación que tenía: la consulta estaba escrita dos
-- veces, una con búsqueda y otra sin ella.
DROP FUNCTION IF EXISTS seguridad.fn_perfiles_listar_paginado(integer, integer, text);

CREATE OR REPLACE FUNCTION seguridad.fn_perfiles_listar_paginado(
    p_page     integer DEFAULT 1,
    p_per_page integer DEFAULT 15,
    p_search   text    DEFAULT '',
    -- Los filtros de la cabecera de ag-Grid, columna por columna
    p_filtros  jsonb   DEFAULT '{}'::jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'seguridad', 'ventas'
AS $function$
DECLARE
    v_offset integer;
    v_total  bigint;
    v_filtro text;
    v_data   jsonb;
BEGIN
    v_offset := (GREATEST(COALESCE(p_page, 1), 1) - 1) * GREATEST(COALESCE(p_per_page, 15), 1);
    v_filtro := NULLIF(TRIM(COALESCE(p_search, '')), '');

    WITH filtrados AS (
        SELECT p.id
          FROM seguridad.perfiles p
         WHERE p.deleted_at IS NULL            -- lo de la papelera no sale
           AND (v_filtro IS NULL
                OR p.nombre   ILIKE '%' || v_filtro || '%'
                OR p.id::text ILIKE '%' || v_filtro || '%')

           -- ---------- LOS FILTROS DE LA CABECERA ----------
           AND (p_filtros->'id'          IS NULL OR ventas.fn_filtro_numero(p.id,          p_filtros->'id'))
           AND (p_filtros->'inactividad' IS NULL OR ventas.fn_filtro_numero(p.inactividad, p_filtros->'inactividad'))
           AND (p_filtros->'nombre'      IS NULL OR ventas.fn_filtro_texto(p.nombre,       p_filtros->'nombre'))
           AND (p_filtros->'created_by'  IS NULL OR ventas.fn_filtro_texto(p.created_by,   p_filtros->'created_by'))
           AND (p_filtros->'updated_by'  IS NULL OR ventas.fn_filtro_texto(p.updated_by,   p_filtros->'updated_by'))
           -- Las fechas, como texto sobre lo que se ve: «2026-10» busca el mes
           AND (p_filtros->'created_at'  IS NULL OR ventas.fn_filtro_texto(
                   to_char(p.created_at, 'YYYY-MM-DD HH24:MI:SS'), p_filtros->'created_at'))
           AND (p_filtros->'updated_at'  IS NULL OR ventas.fn_filtro_texto(
                   to_char(p.updated_at, 'YYYY-MM-DD HH24:MI:SS'), p_filtros->'updated_at'))
    )
    SELECT COUNT(*),
           COALESCE((SELECT jsonb_agg(seguridad.fn_perfiles_json(t.id) ORDER BY t.id DESC)
                       FROM (SELECT f.id FROM filtrados f
                              ORDER BY f.id DESC
                              LIMIT GREATEST(COALESCE(p_per_page, 15), 1) OFFSET v_offset) t), '[]'::jsonb)
      INTO v_total, v_data
      FROM filtrados;

    RETURN jsonb_build_object(
        'data', v_data,
        'meta', jsonb_build_object(
            'total',        v_total,
            'per_page',     GREATEST(COALESCE(p_per_page, 15), 1),
            'current_page', GREATEST(COALESCE(p_page, 1), 1),
            'last_page',    CASE WHEN v_total = 0 THEN 1
                                 ELSE ceil(v_total::numeric / GREATEST(COALESCE(p_per_page, 15), 1)) END
        )
    );

EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object('success', false,
                                  'message', 'Error al listar perfiles: ' || SQLERRM,
                                  'error_code', SQLSTATE);
END;
$function$;


-- ---------------------------------------------------------------------------
-- EL COMBO (la ficha de usuario): tampoco enseña lo de la papelera
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION seguridad.fn_perfiles_listar_paginado_activos(
    p_page     integer DEFAULT 1,
    p_per_page integer DEFAULT 15,
    p_search   text    DEFAULT ''
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'seguridad'
AS $function$
DECLARE
    v_offset integer;
    v_total  bigint;
    v_filtro text;
    v_data   jsonb;
BEGIN
    v_offset := (GREATEST(COALESCE(p_page, 1), 1) - 1) * GREATEST(COALESCE(p_per_page, 15), 1);
    v_filtro := NULLIF(TRIM(COALESCE(p_search, '')), '');

    WITH filtrados AS (
        SELECT p.id
          FROM seguridad.perfiles p
         WHERE p.activo
           AND p.deleted_at IS NULL          -- en la papelera no se puede elegir
           AND (v_filtro IS NULL
                OR p.nombre   ILIKE '%' || v_filtro || '%'
                OR p.id::text ILIKE '%' || v_filtro || '%')
    )
    SELECT COUNT(*),
           COALESCE((SELECT jsonb_agg(seguridad.fn_perfiles_json(t.id) ORDER BY t.id DESC)
                       FROM (SELECT f.id FROM filtrados f
                              ORDER BY f.id DESC
                              LIMIT GREATEST(COALESCE(p_per_page, 15), 1) OFFSET v_offset) t), '[]'::jsonb)
      INTO v_total, v_data
      FROM filtrados;

    RETURN jsonb_build_object(
        'data', v_data,
        'meta', jsonb_build_object(
            'total',        v_total,
            'per_page',     GREATEST(COALESCE(p_per_page, 15), 1),
            'current_page', GREATEST(COALESCE(p_page, 1), 1),
            'last_page',    CASE WHEN v_total = 0 THEN 1
                                 ELSE ceil(v_total::numeric / GREATEST(COALESCE(p_per_page, 15), 1)) END
        )
    );

EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object('success', false,
                                  'message', 'Error al listar perfiles activos: ' || SQLERRM,
                                  'error_code', SQLSTATE);
END;
$function$;


-- ---------------------------------------------------------------------------
-- ELIMINAR = ENVIAR A LA PAPELERA (antes borraba el perfil y sus accesos)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION seguridad.fn_perfiles_eliminar(
    p_id             bigint,
    p_usuario_id     bigint  DEFAULT NULL,
    p_usuario_login  varchar DEFAULT NULL,
    p_usuario_nombre varchar DEFAULT NULL,
    p_ip_address     inet    DEFAULT NULL,
    p_user_agent     text    DEFAULT NULL,
    p_request_id     uuid    DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'seguridad', 'auditoria'
AS $function$
DECLARE
    v_p         record;
    v_usuarios  integer;
    v_grupos    integer;
    v_antes     jsonb;
BEGIN
    PERFORM set_config('app.usuario_id',     COALESCE(p_usuario_id::text, ''), true);
    PERFORM set_config('app.usuario_login',  COALESCE(p_usuario_login, current_user), true);
    PERFORM set_config('app.usuario_nombre', COALESCE(p_usuario_nombre, current_user), true);
    PERFORM set_config('app.ip_address',     COALESCE(p_ip_address::text, ''), true);
    PERFORM set_config('app.user_agent',     COALESCE(p_user_agent, ''), true);
    PERFORM set_config('app.request_id',     COALESCE(p_request_id::text, ''), true);
    PERFORM set_config('app.modulo',         'seguridad.perfiles', true);

    SELECT * INTO v_p FROM seguridad.perfiles WHERE id = p_id;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'message', 'El perfil no existe', 'error_code', 'PERFIL_NO_EXISTE');
    END IF;

    IF v_p.deleted_at IS NOT NULL THEN
        RETURN jsonb_build_object('success', false, 'message', 'El perfil ya está en la papelera',
                                  'error_code', 'P0022');
    END IF;

    -- LA REGLA: un perfil en uso no se va a la papelera
    SELECT COUNT(*) INTO v_usuarios FROM seguridad.users u
     WHERE u.perfil_id = p_id AND u.deleted_at IS NULL;
    SELECT COUNT(*) INTO v_grupos FROM seguridad.grupos g WHERE g.perfil_id = p_id;

    IF v_usuarios > 0 OR v_grupos > 0 THEN
        RETURN jsonb_build_object(
            'success', false,
            'error_code', 'P0021',
            'message', 'El perfil «' || v_p.nombre || '» está en uso ('
                       || v_usuarios || ' ' || CASE WHEN v_usuarios = 1 THEN 'usuario' ELSE 'usuarios' END
                       || ', ' || v_grupos || ' ' || CASE WHEN v_grupos = 1 THEN 'grupo' ELSE 'grupos' END
                       || '). Desactívelo en lugar de eliminarlo.');
    END IF;

    v_antes := seguridad.fn_perfiles_json(p_id);
    PERFORM set_config('app.datos_anteriores', v_antes::text, true);

    -- SUS ACCESOS SE QUEDAN: el perfil vuelve de la papelera tal como estaba.
    -- Rehacer a mano los permisos pantalla por pantalla es media tarde.
    UPDATE seguridad.perfiles
       SET deleted_at = CURRENT_TIMESTAMP,
           deleted_by = COALESCE(p_usuario_login, current_user)
     WHERE id = p_id;

    RETURN jsonb_build_object(
        'success', true,
        'message', 'Perfil «' || v_p.nombre || '» enviado a la papelera de reciclaje',
        'data', seguridad.fn_perfiles_json(p_id)
    );

EXCEPTION
    WHEN OTHERS THEN
        PERFORM set_config('app.datos_anteriores', '', true);
        RETURN jsonb_build_object('success', false,
                                  'message', 'Error al eliminar perfil: ' || SQLERRM,
                                  'error_code', SQLSTATE);
END;
$function$;


-- ---------------------------------------------------------------------------
-- LO QUE HAY EN LA PAPELERA
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION seguridad.fn_perfiles_papelera_listar()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'seguridad'
AS $function$
DECLARE
    v_data jsonb;
BEGIN
    SELECT COALESCE(jsonb_agg(seguridad.fn_perfiles_json(p.id)
                              ORDER BY p.deleted_at DESC, p.id DESC), '[]'::jsonb)
      INTO v_data
      FROM seguridad.perfiles p
     WHERE p.deleted_at IS NOT NULL;

    RETURN jsonb_build_object('success', true, 'data', v_data, 'total', jsonb_array_length(v_data));
EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object('success', false,
                                  'message', 'Error al listar la papelera: ' || SQLERRM,
                                  'error_code', SQLSTATE);
END;
$function$;


-- ---------------------------------------------------------------------------
-- RESTAURAR (uno o varios)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION seguridad.fn_perfiles_restaurar(
    p_ids            jsonb,
    p_usuario_id     bigint  DEFAULT NULL,
    p_usuario_login  varchar DEFAULT NULL,
    p_usuario_nombre varchar DEFAULT NULL,
    p_ip_address     inet    DEFAULT NULL,
    p_user_agent     text    DEFAULT NULL,
    p_request_id     uuid    DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'seguridad', 'auditoria'
AS $function$
DECLARE
    v_p       record;
    v_n       integer := 0;
    v_nombres text[] := '{}';
BEGIN
    PERFORM set_config('app.usuario_id',     COALESCE(p_usuario_id::text, ''), true);
    PERFORM set_config('app.usuario_login',  COALESCE(p_usuario_login, current_user), true);
    PERFORM set_config('app.usuario_nombre', COALESCE(p_usuario_nombre, current_user), true);
    PERFORM set_config('app.ip_address',     COALESCE(p_ip_address::text, ''), true);
    PERFORM set_config('app.user_agent',     COALESCE(p_user_agent, ''), true);
    PERFORM set_config('app.request_id',     COALESCE(p_request_id::text, ''), true);
    PERFORM set_config('app.modulo',         'seguridad.perfiles', true);

    FOR v_p IN
        SELECT p.* FROM seguridad.perfiles p
         WHERE p.deleted_at IS NOT NULL
           AND p.id IN (SELECT (jsonb_array_elements_text(COALESCE(p_ids, '[]'::jsonb)))::bigint)
         ORDER BY p.id
    LOOP
        PERFORM set_config('app.datos_anteriores', seguridad.fn_perfiles_json(v_p.id)::text, true);

        UPDATE seguridad.perfiles
           SET deleted_at = NULL,
               deleted_by = NULL
         WHERE id = v_p.id;

        v_n := v_n + 1;
        v_nombres := v_nombres || v_p.nombre;
    END LOOP;

    IF v_n = 0 THEN
        RAISE EXCEPTION 'Ninguno de esos perfiles está en la papelera' USING ERRCODE = 'P0022';
    END IF;

    RETURN jsonb_build_object(
        'success', true,
        'message', CASE WHEN v_n = 1 THEN 'Perfil «' || v_nombres[1] || '» restaurado'
                        ELSE v_n || ' perfiles restaurados' END,
        'data', jsonb_build_object('restaurados', v_n, 'nombres', to_jsonb(v_nombres))
    );
END;
$function$;


-- ---------------------------------------------------------------------------
-- BORRADO REAL (sólo desde la papelera)
-- ---------------------------------------------------------------------------
-- Aquí sí se van los accesos: es el borrado de siempre, pero hay que haber
-- pasado por la papelera antes. La visibilidad de datos del perfil cae sola
-- (su clave ajena es ON DELETE CASCADE).
CREATE OR REPLACE FUNCTION seguridad.fn_perfiles_eliminar_definitivo(
    p_ids            jsonb,
    p_usuario_id     bigint  DEFAULT NULL,
    p_usuario_login  varchar DEFAULT NULL,
    p_usuario_nombre varchar DEFAULT NULL,
    p_ip_address     inet    DEFAULT NULL,
    p_user_agent     text    DEFAULT NULL,
    p_request_id     uuid    DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'seguridad', 'auditoria'
AS $function$
DECLARE
    v_p        record;
    v_usuarios integer;
    v_grupos   integer;
    v_n        integer := 0;
    v_nombres  text[] := '{}';
BEGIN
    PERFORM set_config('app.usuario_id',     COALESCE(p_usuario_id::text, ''), true);
    PERFORM set_config('app.usuario_login',  COALESCE(p_usuario_login, current_user), true);
    PERFORM set_config('app.usuario_nombre', COALESCE(p_usuario_nombre, current_user), true);
    PERFORM set_config('app.ip_address',     COALESCE(p_ip_address::text, ''), true);
    PERFORM set_config('app.user_agent',     COALESCE(p_user_agent, ''), true);
    PERFORM set_config('app.request_id',     COALESCE(p_request_id::text, ''), true);
    PERFORM set_config('app.modulo',         'seguridad.perfiles', true);

    FOR v_p IN
        SELECT p.* FROM seguridad.perfiles p
         WHERE p.deleted_at IS NOT NULL
           AND p.id IN (SELECT (jsonb_array_elements_text(COALESCE(p_ids, '[]'::jsonb)))::bigint)
         ORDER BY p.id
    LOOP
        -- Alguien pudo asignarlo mientras estaba en la papelera? No debería
        -- —ni el listado ni el combo lo enseñan—, pero se mira igual: esto no
        -- tiene vuelta atrás.
        SELECT COUNT(*) INTO v_usuarios FROM seguridad.users u
         WHERE u.perfil_id = v_p.id AND u.deleted_at IS NULL;
        SELECT COUNT(*) INTO v_grupos FROM seguridad.grupos g WHERE g.perfil_id = v_p.id;

        IF v_usuarios > 0 OR v_grupos > 0 THEN
            RAISE EXCEPTION 'El perfil «%» está en uso (% usuarios, % grupos) y no se puede borrar',
                            v_p.nombre, v_usuarios, v_grupos USING ERRCODE = 'P0021';
        END IF;

        PERFORM set_config('app.datos_anteriores', seguridad.fn_perfiles_json(v_p.id)::text, true);

        DELETE FROM seguridad.accesos  WHERE perfil_id = v_p.id;
        DELETE FROM seguridad.perfiles WHERE id = v_p.id;

        v_n := v_n + 1;
        v_nombres := v_nombres || v_p.nombre;
    END LOOP;

    IF v_n = 0 THEN
        RAISE EXCEPTION 'Ninguno de esos perfiles está en la papelera' USING ERRCODE = 'P0022';
    END IF;

    RETURN jsonb_build_object(
        'success', true,
        'message', CASE WHEN v_n = 1 THEN 'Perfil «' || v_nombres[1] || '» eliminado definitivamente'
                        ELSE v_n || ' perfiles eliminados definitivamente' END,
        'data', jsonb_build_object('eliminados', v_n, 'nombres', to_jsonb(v_nombres))
    );
END;
$function$;


-- ---------------------------------------------------------------------------
-- VACIAR LA PAPELERA
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION seguridad.fn_perfiles_papelera_vaciar(
    p_usuario_id     bigint  DEFAULT NULL,
    p_usuario_login  varchar DEFAULT NULL,
    p_usuario_nombre varchar DEFAULT NULL,
    p_ip_address     inet    DEFAULT NULL,
    p_user_agent     text    DEFAULT NULL,
    p_request_id     uuid    DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'seguridad', 'auditoria'
AS $function$
DECLARE
    v_ids jsonb;
BEGIN
    SELECT COALESCE(jsonb_agg(p.id), '[]'::jsonb) INTO v_ids
      FROM seguridad.perfiles p WHERE p.deleted_at IS NOT NULL;

    IF jsonb_array_length(v_ids) = 0 THEN
        RETURN jsonb_build_object('success', true, 'message', 'La papelera ya estaba vacía',
                                  'data', jsonb_build_object('eliminados', 0));
    END IF;

    RETURN seguridad.fn_perfiles_eliminar_definitivo(v_ids, p_usuario_id, p_usuario_login,
                                                     p_usuario_nombre, p_ip_address,
                                                     p_user_agent, p_request_id);
END;
$function$;


ALTER FUNCTION seguridad.fn_perfiles_json(bigint) OWNER TO postgres;
ALTER FUNCTION seguridad.fn_perfiles_listar_paginado(integer, integer, text, jsonb) OWNER TO postgres;
ALTER FUNCTION seguridad.fn_perfiles_listar_paginado_activos(integer, integer, text) OWNER TO postgres;
ALTER FUNCTION seguridad.fn_perfiles_eliminar(bigint, bigint, varchar, varchar, inet, text, uuid) OWNER TO postgres;
ALTER FUNCTION seguridad.fn_perfiles_papelera_listar() OWNER TO postgres;
ALTER FUNCTION seguridad.fn_perfiles_restaurar(jsonb, bigint, varchar, varchar, inet, text, uuid) OWNER TO postgres;
ALTER FUNCTION seguridad.fn_perfiles_eliminar_definitivo(jsonb, bigint, varchar, varchar, inet, text, uuid) OWNER TO postgres;
ALTER FUNCTION seguridad.fn_perfiles_papelera_vaciar(bigint, varchar, varchar, inet, text, uuid) OWNER TO postgres;

COMMENT ON FUNCTION seguridad.fn_perfiles_listar_paginado(integer, integer, text, jsonb) IS
'Listado paginado de perfiles; p_filtros trae los filtros de columna de ag-Grid y se aplican sobre todos, no sobre la página';
COMMENT ON FUNCTION seguridad.fn_perfiles_eliminar(bigint, bigint, varchar, varchar, inet, text, uuid) IS
'Envía el perfil a la papelera de reciclaje (borrado lógico); se niega si lo usan usuarios o grupos';
COMMENT ON FUNCTION seguridad.fn_perfiles_papelera_listar() IS 'Perfiles que están en la papelera de reciclaje';
COMMENT ON FUNCTION seguridad.fn_perfiles_restaurar(jsonb, bigint, varchar, varchar, inet, text, uuid) IS 'Saca de la papelera uno o varios perfiles, con sus accesos';
COMMENT ON FUNCTION seguridad.fn_perfiles_eliminar_definitivo(jsonb, bigint, varchar, varchar, inet, text, uuid) IS 'Borrado real de perfiles de la papelera, con sus accesos';
COMMENT ON FUNCTION seguridad.fn_perfiles_papelera_vaciar(bigint, varchar, varchar, inet, text, uuid) IS 'Borrado real de todo lo que hay en la papelera de perfiles';
