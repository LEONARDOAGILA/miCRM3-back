-- ===========================================================================
-- HORARIOS: PAPELERA DE RECICLAJE
-- ===========================================================================
-- Fecha: 2026-10-17
-- Se aplica después de 2026-10-17_accesos_vaciar.sql.
--
-- Hasta ahora «eliminar» un horario lo borraba de verdad, con sus días
-- (seguridad.dhorarios). Un horario son siete franjas con sus horas, y
-- rehacerlas a mano es un rato; además el horario decide a qué hora puede
-- entrar la gente, así que borrarlo por error se nota al día siguiente.
--
-- Ahora va a la papelera (deleted_at / deleted_by) CON SUS DÍAS, y desde allí
-- se restaura tal cual o se borra de verdad.
--
-- LA REGLA QUE MANDA, la que ya tenía: un horario que alguien usa no se
-- elimina. Antes sólo miraba usuarios; ahora mira también los grupos, que
-- tienen su propio chorario_id y heredan el horario a quien entra en ellos.
-- Si lo usa alguien, se dice cuántos y se sugiere desactivarlo.
--
-- Lo que está en la papelera no sale ni en el listado ni en el combo de
-- horarios (la ficha de usuario), así que no se puede volver a asignar sin
-- restaurarlo antes.
--
-- Errores de negocio (los mismos códigos que en perfiles):
--   P0021  el horario está en uso (usuarios o grupos)
--   P0022  el horario no está en la papelera
--
-- Idempotente.
-- ===========================================================================

ALTER TABLE seguridad.chorarios ADD COLUMN IF NOT EXISTS deleted_at timestamptz;
ALTER TABLE seguridad.chorarios ADD COLUMN IF NOT EXISTS deleted_by varchar(100);
COMMENT ON COLUMN seguridad.chorarios.deleted_at IS 'Fecha en que se envió a la papelera de reciclaje (NULL = vigente)';
COMMENT ON COLUMN seguridad.chorarios.deleted_by IS 'Login de quien lo envió a la papelera';
CREATE INDEX IF NOT EXISTS ix_chorarios_deleted_at ON seguridad.chorarios (deleted_at) WHERE deleted_at IS NOT NULL;


-- ---------------------------------------------------------------------------
-- UNA FILA DE HORARIO, SIEMPRE IGUAL
-- ---------------------------------------------------------------------------
-- Antes el listado se armaba su jsonb a mano; con la papelera serían tres
-- sitios distintos construyendo lo mismo, y se van separando sin que se note.
CREATE OR REPLACE FUNCTION seguridad.fn_horarios_json(p_id bigint)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
AS $function$
    SELECT jsonb_build_object(
        'id',           c.id,
        'nombre',       c.nombre,
        'activo',       c.activo,
        -- Quién depende de él: es lo que decide si se puede eliminar
        'num_usuarios', (SELECT COUNT(*) FROM seguridad.users u
                          WHERE u.chorario_id = c.id AND u.deleted_at IS NULL),
        'num_grupos',   (SELECT COUNT(*) FROM seguridad.grupos g WHERE g.chorario_id = c.id),
        -- Los días configurados, que vuelven con él al restaurarlo
        'num_dias',     (SELECT COUNT(*) FROM seguridad.dhorarios d WHERE d.chorario_id = c.id),
        -- La papelera: NULL mientras el horario está vigente
        'deleted_at',   to_char(c.deleted_at, 'YYYY-MM-DD HH24:MI:SS'),
        'deleted_by',   c.deleted_by,
        'created_by',   c.created_by,
        'updated_by',   c.updated_by,
        'created_at',   to_char(c.created_at, 'YYYY-MM-DD HH24:MI:SS'),
        'updated_at',   to_char(c.updated_at, 'YYYY-MM-DD HH24:MI:SS')
    )
      FROM seguridad.chorarios c
     WHERE c.id = p_id;
$function$;


-- ---------------------------------------------------------------------------
-- EL LISTADO: lo de la papelera no sale (los filtros de columna se quedan)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION seguridad.fn_horarios_listar_paginado(
    p_page     integer DEFAULT 1,
    p_per_page integer DEFAULT 15,
    p_search   text    DEFAULT '',
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
        SELECT c.id
          FROM seguridad.chorarios c
         WHERE c.deleted_at IS NULL            -- lo de la papelera no sale
           AND (v_filtro IS NULL
                OR c.nombre   ILIKE '%' || v_filtro || '%'
                OR c.id::text ILIKE '%' || v_filtro || '%')

           -- ---------- LOS FILTROS DE LA CABECERA ----------
           AND (p_filtros->'id'     IS NULL OR ventas.fn_filtro_numero(c.id,     p_filtros->'id'))
           AND (p_filtros->'nombre' IS NULL OR ventas.fn_filtro_texto(c.nombre,  p_filtros->'nombre'))
           -- Las fechas, como texto sobre lo que se ve: «2026-10» busca el mes
           AND (p_filtros->'created_at' IS NULL OR ventas.fn_filtro_texto(
                   to_char(c.created_at, 'YYYY-MM-DD HH24:MI:SS'), p_filtros->'created_at'))
           AND (p_filtros->'updated_at' IS NULL OR ventas.fn_filtro_texto(
                   to_char(c.updated_at, 'YYYY-MM-DD HH24:MI:SS'), p_filtros->'updated_at'))
    )
    SELECT COUNT(*),
           COALESCE((SELECT jsonb_agg(seguridad.fn_horarios_json(t.id) ORDER BY t.id DESC)
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
                                  'message', 'Error al listar horarios: ' || SQLERRM,
                                  'error_code', SQLSTATE);
END;
$function$;


-- ---------------------------------------------------------------------------
-- EL COMBO (la ficha de usuario): tampoco enseña lo de la papelera
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION seguridad.fn_horarios_listar_paginado_activos(
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
        SELECT c.id
          FROM seguridad.chorarios c
         WHERE c.activo
           AND c.deleted_at IS NULL          -- en la papelera no se puede elegir
           AND (v_filtro IS NULL
                OR c.nombre   ILIKE '%' || v_filtro || '%'
                OR c.id::text ILIKE '%' || v_filtro || '%')
    )
    SELECT COUNT(*),
           COALESCE((SELECT jsonb_agg(seguridad.fn_horarios_json(t.id) ORDER BY t.id DESC)
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
                                  'message', 'Error al listar horarios activos: ' || SQLERRM,
                                  'error_code', SQLSTATE);
END;
$function$;


-- ---------------------------------------------------------------------------
-- ELIMINAR = ENVIAR A LA PAPELERA (antes borraba el horario y sus días)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION seguridad.fn_horarios_eliminar(
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
    v_c        record;
    v_usuarios integer;
    v_grupos   integer;
BEGIN
    PERFORM set_config('app.usuario_id',     COALESCE(p_usuario_id::text, ''), true);
    PERFORM set_config('app.usuario_login',  COALESCE(p_usuario_login, current_user), true);
    PERFORM set_config('app.usuario_nombre', COALESCE(p_usuario_nombre, current_user), true);
    PERFORM set_config('app.ip_address',     COALESCE(p_ip_address::text, ''), true);
    PERFORM set_config('app.user_agent',     COALESCE(p_user_agent, ''), true);
    PERFORM set_config('app.request_id',     COALESCE(p_request_id::text, ''), true);
    PERFORM set_config('app.modulo',         'seguridad.chorarios', true);

    SELECT * INTO v_c FROM seguridad.chorarios WHERE id = p_id;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'message', 'El horario no existe',
                                  'error_code', 'HORARIO_NO_EXISTE');
    END IF;

    IF v_c.deleted_at IS NOT NULL THEN
        RETURN jsonb_build_object('success', false, 'message', 'El horario ya está en la papelera',
                                  'error_code', 'P0022');
    END IF;

    -- LA REGLA DE SIEMPRE, ahora mirando también los grupos: el horario dice
    -- a qué hora puede entrar la gente, y dejar a alguien apuntando a uno que
    -- ya no sale en ningún listado es dejarle un portazo sin explicación.
    SELECT COUNT(*) INTO v_usuarios FROM seguridad.users u
     WHERE u.chorario_id = p_id AND u.deleted_at IS NULL;
    SELECT COUNT(*) INTO v_grupos FROM seguridad.grupos g WHERE g.chorario_id = p_id;

    IF v_usuarios > 0 OR v_grupos > 0 THEN
        RETURN jsonb_build_object(
            'success', false,
            'error_code', 'P0021',
            'message', 'El horario «' || v_c.nombre || '» está en uso ('
                       || v_usuarios || ' ' || CASE WHEN v_usuarios = 1 THEN 'usuario' ELSE 'usuarios' END
                       || ', ' || v_grupos || ' ' || CASE WHEN v_grupos = 1 THEN 'grupo' ELSE 'grupos' END
                       || '). Desactívelo en lugar de eliminarlo.');
    END IF;

    PERFORM set_config('app.datos_anteriores', seguridad.fn_horarios_json(p_id)::text, true);

    -- SUS DÍAS SE QUEDAN: el horario vuelve de la papelera con sus franjas.
    UPDATE seguridad.chorarios
       SET deleted_at = CURRENT_TIMESTAMP,
           deleted_by = COALESCE(p_usuario_login, current_user)
     WHERE id = p_id;

    RETURN jsonb_build_object(
        'success', true,
        'message', 'Horario «' || v_c.nombre || '» enviado a la papelera de reciclaje',
        'data', seguridad.fn_horarios_json(p_id)
    );

EXCEPTION
    WHEN OTHERS THEN
        PERFORM set_config('app.datos_anteriores', '', true);
        RETURN jsonb_build_object('success', false,
                                  'message', 'Error al eliminar horario: ' || SQLERRM,
                                  'error_code', SQLSTATE);
END;
$function$;


-- ---------------------------------------------------------------------------
-- LO QUE HAY EN LA PAPELERA
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION seguridad.fn_horarios_papelera_listar()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'seguridad'
AS $function$
DECLARE
    v_data jsonb;
BEGIN
    SELECT COALESCE(jsonb_agg(seguridad.fn_horarios_json(c.id)
                              ORDER BY c.deleted_at DESC, c.id DESC), '[]'::jsonb)
      INTO v_data
      FROM seguridad.chorarios c
     WHERE c.deleted_at IS NOT NULL;

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
CREATE OR REPLACE FUNCTION seguridad.fn_horarios_restaurar(
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
    v_c       record;
    v_n       integer := 0;
    v_nombres text[] := '{}';
BEGIN
    PERFORM set_config('app.usuario_id',     COALESCE(p_usuario_id::text, ''), true);
    PERFORM set_config('app.usuario_login',  COALESCE(p_usuario_login, current_user), true);
    PERFORM set_config('app.usuario_nombre', COALESCE(p_usuario_nombre, current_user), true);
    PERFORM set_config('app.ip_address',     COALESCE(p_ip_address::text, ''), true);
    PERFORM set_config('app.user_agent',     COALESCE(p_user_agent, ''), true);
    PERFORM set_config('app.request_id',     COALESCE(p_request_id::text, ''), true);
    PERFORM set_config('app.modulo',         'seguridad.chorarios', true);

    FOR v_c IN
        SELECT c.* FROM seguridad.chorarios c
         WHERE c.deleted_at IS NOT NULL
           AND c.id IN (SELECT (jsonb_array_elements_text(COALESCE(p_ids, '[]'::jsonb)))::bigint)
         ORDER BY c.id
    LOOP
        PERFORM set_config('app.datos_anteriores', seguridad.fn_horarios_json(v_c.id)::text, true);

        UPDATE seguridad.chorarios
           SET deleted_at = NULL,
               deleted_by = NULL
         WHERE id = v_c.id;

        v_n := v_n + 1;
        v_nombres := v_nombres || v_c.nombre;
    END LOOP;

    IF v_n = 0 THEN
        RAISE EXCEPTION 'Ninguno de esos horarios está en la papelera' USING ERRCODE = 'P0022';
    END IF;

    RETURN jsonb_build_object(
        'success', true,
        'message', CASE WHEN v_n = 1 THEN 'Horario «' || v_nombres[1] || '» restaurado'
                        ELSE v_n || ' horarios restaurados' END,
        'data', jsonb_build_object('restaurados', v_n, 'nombres', to_jsonb(v_nombres))
    );
END;
$function$;


-- ---------------------------------------------------------------------------
-- BORRADO REAL (sólo desde la papelera)
-- ---------------------------------------------------------------------------
-- Aquí sí se van los días: es el borrado de siempre, pero hay que haber
-- pasado por la papelera antes.
CREATE OR REPLACE FUNCTION seguridad.fn_horarios_eliminar_definitivo(
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
    v_c        record;
    v_usuarios integer;
    v_grupos   integer;
    v_dias     jsonb;
    v_n        integer := 0;
    v_nombres  text[] := '{}';
BEGIN
    PERFORM set_config('app.usuario_id',     COALESCE(p_usuario_id::text, ''), true);
    PERFORM set_config('app.usuario_login',  COALESCE(p_usuario_login, current_user), true);
    PERFORM set_config('app.usuario_nombre', COALESCE(p_usuario_nombre, current_user), true);
    PERFORM set_config('app.ip_address',     COALESCE(p_ip_address::text, ''), true);
    PERFORM set_config('app.user_agent',     COALESCE(p_user_agent, ''), true);
    PERFORM set_config('app.request_id',     COALESCE(p_request_id::text, ''), true);
    PERFORM set_config('app.modulo',         'seguridad.chorarios', true);

    FOR v_c IN
        SELECT c.* FROM seguridad.chorarios c
         WHERE c.deleted_at IS NOT NULL
           AND c.id IN (SELECT (jsonb_array_elements_text(COALESCE(p_ids, '[]'::jsonb)))::bigint)
         ORDER BY c.id
    LOOP
        -- ¿Se lo asignaron mientras estaba en la papelera? No debería —ni el
        -- listado ni el combo lo enseñan—, pero esto no tiene vuelta atrás.
        SELECT COUNT(*) INTO v_usuarios FROM seguridad.users u
         WHERE u.chorario_id = v_c.id AND u.deleted_at IS NULL;
        SELECT COUNT(*) INTO v_grupos FROM seguridad.grupos g WHERE g.chorario_id = v_c.id;

        IF v_usuarios > 0 OR v_grupos > 0 THEN
            RAISE EXCEPTION 'El horario «%» está en uso (% usuarios, % grupos) y no se puede borrar',
                            v_c.nombre, v_usuarios, v_grupos USING ERRCODE = 'P0021';
        END IF;

        -- Los días, al contexto para el rastro de auditoría (el disparador de
        -- esta tabla los espera ahí, igual que en el borrado de siempre)
        SELECT COALESCE(jsonb_agg(jsonb_build_object(
                   'id', d.id, 'dia', d.dia, 'hora_inicio', d.hora_inicio,
                   'hora_fin', d.hora_fin, 'activo', d.activo) ORDER BY d.dia), '[]'::jsonb)
          INTO v_dias
          FROM seguridad.dhorarios d WHERE d.chorario_id = v_c.id;
        PERFORM set_config('app.dhorario_viejos', v_dias::text, true);
        PERFORM set_config('app.datos_anteriores', seguridad.fn_horarios_json(v_c.id)::text, true);

        DELETE FROM seguridad.dhorarios WHERE chorario_id = v_c.id;
        DELETE FROM seguridad.chorarios WHERE id = v_c.id;

        v_n := v_n + 1;
        v_nombres := v_nombres || v_c.nombre;
    END LOOP;

    IF v_n = 0 THEN
        RAISE EXCEPTION 'Ninguno de esos horarios está en la papelera' USING ERRCODE = 'P0022';
    END IF;

    RETURN jsonb_build_object(
        'success', true,
        'message', CASE WHEN v_n = 1 THEN 'Horario «' || v_nombres[1] || '» eliminado definitivamente'
                        ELSE v_n || ' horarios eliminados definitivamente' END,
        'data', jsonb_build_object('eliminados', v_n, 'nombres', to_jsonb(v_nombres))
    );
END;
$function$;


-- ---------------------------------------------------------------------------
-- VACIAR LA PAPELERA
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION seguridad.fn_horarios_papelera_vaciar(
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
    SELECT COALESCE(jsonb_agg(c.id), '[]'::jsonb) INTO v_ids
      FROM seguridad.chorarios c WHERE c.deleted_at IS NOT NULL;

    IF jsonb_array_length(v_ids) = 0 THEN
        RETURN jsonb_build_object('success', true, 'message', 'La papelera ya estaba vacía',
                                  'data', jsonb_build_object('eliminados', 0));
    END IF;

    RETURN seguridad.fn_horarios_eliminar_definitivo(v_ids, p_usuario_id, p_usuario_login,
                                                     p_usuario_nombre, p_ip_address,
                                                     p_user_agent, p_request_id);
END;
$function$;


ALTER FUNCTION seguridad.fn_horarios_json(bigint) OWNER TO postgres;
ALTER FUNCTION seguridad.fn_horarios_listar_paginado(integer, integer, text, jsonb) OWNER TO postgres;
ALTER FUNCTION seguridad.fn_horarios_listar_paginado_activos(integer, integer, text) OWNER TO postgres;
ALTER FUNCTION seguridad.fn_horarios_eliminar(bigint, bigint, varchar, varchar, inet, text, uuid) OWNER TO postgres;
ALTER FUNCTION seguridad.fn_horarios_papelera_listar() OWNER TO postgres;
ALTER FUNCTION seguridad.fn_horarios_restaurar(jsonb, bigint, varchar, varchar, inet, text, uuid) OWNER TO postgres;
ALTER FUNCTION seguridad.fn_horarios_eliminar_definitivo(jsonb, bigint, varchar, varchar, inet, text, uuid) OWNER TO postgres;
ALTER FUNCTION seguridad.fn_horarios_papelera_vaciar(bigint, varchar, varchar, inet, text, uuid) OWNER TO postgres;

COMMENT ON FUNCTION seguridad.fn_horarios_eliminar(bigint, bigint, varchar, varchar, inet, text, uuid) IS
'Envía el horario a la papelera de reciclaje (borrado lógico); se niega si lo usan usuarios o grupos';
COMMENT ON FUNCTION seguridad.fn_horarios_papelera_listar() IS 'Horarios que están en la papelera de reciclaje';
COMMENT ON FUNCTION seguridad.fn_horarios_restaurar(jsonb, bigint, varchar, varchar, inet, text, uuid) IS 'Saca de la papelera uno o varios horarios, con sus días';
COMMENT ON FUNCTION seguridad.fn_horarios_eliminar_definitivo(jsonb, bigint, varchar, varchar, inet, text, uuid) IS 'Borrado real de horarios de la papelera, con sus días';
COMMENT ON FUNCTION seguridad.fn_horarios_papelera_vaciar(bigint, varchar, varchar, inet, text, uuid) IS 'Borrado real de todo lo que hay en la papelera de horarios';
