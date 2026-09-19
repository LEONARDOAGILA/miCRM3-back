-- ============================================================================
-- fn_grupos_modificar con «aplicar a los usuarios»: nuevo parámetro
-- p_aplicar_usuarios (tras p_activo). Si es true, tras guardar el grupo se
-- ponen su perfil y horario (los que tenga) y el tipo de usuario
-- (administrador / sistema / web) a todos los usuarios que están
-- directamente en el grupo (no a los de la papelera), auditando cada uno.
-- La firma vieja se elimina para que no haya ambigüedad. Idempotente.
-- ============================================================================
DROP FUNCTION IF EXISTS seguridad.fn_grupos_modificar(bigint, varchar, bigint, text, bigint, bigint, boolean, varchar, boolean, bigint, varchar, varchar, inet, text, uuid);

CREATE OR REPLACE FUNCTION seguridad.fn_grupos_modificar(
    p_id               bigint,
    p_nombre           varchar,
    p_padre_id         bigint  DEFAULT NULL,
    p_descripcion      text    DEFAULT NULL,
    p_perfil_id        bigint  DEFAULT NULL,
    p_chorario_id      bigint  DEFAULT NULL,
    p_es_administrador boolean DEFAULT false,
    p_tipo_acceso      varchar DEFAULT 'SISTEMA',
    p_activo           boolean DEFAULT true,
    p_aplicar_usuarios boolean DEFAULT false,
    p_usuario_id       bigint  DEFAULT NULL,
    p_usuario_login    varchar DEFAULT NULL,
    p_usuario_nombre   varchar DEFAULT NULL,
    p_ip_address       inet    DEFAULT NULL,
    p_user_agent       text    DEFAULT NULL,
    p_request_id       uuid    DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'seguridad', 'auditoria'
AS $function$
DECLARE
    v_actual           record;
    v_orden            integer;
    v_fecha            timestamptz := CURRENT_TIMESTAMP;
    v_datos_anteriores jsonb;
    v_datos_nuevos     jsonb;
    v_u                record;
    v_antes            jsonb;
    v_type_user        integer;
    v_aplicados        integer := 0;
BEGIN
    -- 1. Contexto de auditoría
    PERFORM set_config('app.usuario_id',     COALESCE(p_usuario_id::text, ''), true);
    PERFORM set_config('app.usuario_login',  COALESCE(p_usuario_login, current_user), true);
    PERFORM set_config('app.usuario_nombre', COALESCE(p_usuario_nombre, current_user), true);
    PERFORM set_config('app.ip_address',     COALESCE(p_ip_address::text, ''), true);
    PERFORM set_config('app.user_agent',     COALESCE(p_user_agent, ''), true);
    PERFORM set_config('app.request_id',     COALESCE(p_request_id::text, ''), true);
    PERFORM set_config('app.modulo',         'seguridad.grupos', true);

    -- 2. Datos actuales
    SELECT * INTO v_actual FROM seguridad.grupos WHERE id = p_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'El grupo no existe' USING ERRCODE = 'P0013';
    END IF;

    -- 3. Reglas
    PERFORM seguridad.fn_grupos_validar(p_nombre, p_perfil_id, p_chorario_id, p_tipo_acceso);
    IF p_padre_id IS NOT NULL THEN
        IF p_padre_id = p_id THEN
            RAISE EXCEPTION 'Un grupo no puede estar dentro de sí mismo' USING ERRCODE = 'P0017';
        END IF;
        IF NOT EXISTS (SELECT 1 FROM seguridad.grupos WHERE id = p_padre_id) THEN
            RAISE EXCEPTION 'El grupo padre no existe' USING ERRCODE = 'P0016';
        END IF;
        IF EXISTS (
            WITH RECURSIVE d AS (
                SELECT id FROM seguridad.grupos WHERE padre_id = p_id
                UNION ALL
                SELECT g.id FROM seguridad.grupos g JOIN d ON g.padre_id = d.id
            )
            SELECT 1 FROM d WHERE d.id = p_padre_id
        ) THEN
            RAISE EXCEPTION 'No se puede mover un grupo dentro de uno de sus propios subgrupos' USING ERRCODE = 'P0017';
        END IF;
    END IF;
    IF EXISTS (SELECT 1 FROM seguridad.grupos WHERE padre_id IS NOT DISTINCT FROM p_padre_id AND UPPER(nombre) = UPPER(TRIM(p_nombre)) AND id <> p_id) THEN
        RAISE EXCEPTION 'Ya existe otro grupo con ese nombre en el mismo nivel' USING ERRCODE = 'P0006';
    END IF;

    -- Si cambia de padre va al final del nuevo; si no, conserva su orden
    IF v_actual.padre_id IS DISTINCT FROM p_padre_id THEN
        SELECT COALESCE(MAX(orden), 0) + 1 INTO v_orden FROM seguridad.grupos WHERE padre_id IS NOT DISTINCT FROM p_padre_id;
    ELSE
        v_orden := v_actual.orden;
    END IF;

    -- 4. Auditoría: anteriores y nuevos
    v_datos_anteriores := to_jsonb(v_actual);
    v_datos_nuevos := jsonb_build_object(
        'id',               p_id,
        'nombre',           TRIM(p_nombre),
        'padre_id',         p_padre_id,
        'descripcion',      NULLIF(TRIM(COALESCE(p_descripcion, '')), ''),
        'orden',            v_orden,
        'perfil_id',        p_perfil_id,
        'chorario_id',      p_chorario_id,
        'es_administrador', COALESCE(p_es_administrador, false),
        'tipo_acceso',      COALESCE(p_tipo_acceso, 'SISTEMA'),
        'activo',           COALESCE(p_activo, true),
        'created_by',       v_actual.created_by,
        'created_at',       to_char(v_actual.created_at, 'YYYY-MM-DD HH24:MI:SS'),
        'updated_by',       COALESCE(p_usuario_login, v_actual.updated_by),
        'updated_at',       to_char(v_fecha, 'YYYY-MM-DD HH24:MI:SS')
    );
    PERFORM set_config('app.datos_anteriores', v_datos_anteriores::text, true);
    PERFORM set_config('app.datos_nuevos',     v_datos_nuevos::text, true);

    -- 5. Actualizar
    UPDATE seguridad.grupos
       SET nombre           = TRIM(p_nombre),
           padre_id         = p_padre_id,
           descripcion      = NULLIF(TRIM(COALESCE(p_descripcion, '')), ''),
           orden            = v_orden,
           perfil_id        = p_perfil_id,
           chorario_id      = p_chorario_id,
           es_administrador = COALESCE(p_es_administrador, false),
           tipo_acceso      = COALESCE(p_tipo_acceso, 'SISTEMA'),
           activo           = COALESCE(p_activo, true),
           updated_by       = COALESCE(p_usuario_login, v_actual.updated_by),
           updated_at       = v_fecha
     WHERE id = p_id;

    PERFORM set_config('app.datos_anteriores', '', true);
    PERFORM set_config('app.datos_nuevos', '', true);

    -- 6. Aplicar a sus usuarios (los que están directamente en el grupo, no en
    --    la papelera): perfil y horario del grupo (si los tiene) y el tipo
    --    (administrador / sistema / web). Cada usuario queda auditado.
    IF COALESCE(p_aplicar_usuarios, false) THEN
        v_type_user := CASE WHEN COALESCE(p_es_administrador, false) THEN 2
                            WHEN COALESCE(p_tipo_acceso, 'SISTEMA') = 'WEB' THEN 4 ELSE 3 END;
        PERFORM set_config('app.modulo', 'seguridad.users', true);
        FOR v_u IN
            SELECT u.id FROM seguridad.users u
             WHERE u.grupo_id = p_id AND u.deleted_at IS NULL
               AND (   (p_perfil_id   IS NOT NULL AND u.perfil_id   IS DISTINCT FROM p_perfil_id)
                    OR (p_chorario_id IS NOT NULL AND u.chorario_id IS DISTINCT FROM p_chorario_id)
                    OR u.type_user IS DISTINCT FROM v_type_user)
        LOOP
            v_antes := seguridad.fn_usuarios_json(v_u.id);
            PERFORM set_config('app.datos_anteriores', v_antes::text, true);
            PERFORM set_config('app.datos_nuevos', (v_antes || jsonb_build_object(
                'perfil_id',   COALESCE(p_perfil_id, (v_antes->>'perfil_id')::bigint),
                'chorario_id', COALESCE(p_chorario_id, (v_antes->>'chorario_id')::bigint),
                'type_user',   v_type_user,
                'updated_by',  p_usuario_login,
                'updated_at',  to_char(v_fecha, 'YYYY-MM-DD HH24:MI:SS')
            ))::text, true);

            UPDATE seguridad.users
               SET perfil_id   = COALESCE(p_perfil_id, perfil_id),
                   chorario_id = COALESCE(p_chorario_id, chorario_id),
                   type_user   = v_type_user,
                   updated_by  = COALESCE(p_usuario_login, updated_by),
                   updated_at  = v_fecha
             WHERE id = v_u.id;
            v_aplicados := v_aplicados + 1;
        END LOOP;
        PERFORM set_config('app.datos_anteriores', '', true);
        PERFORM set_config('app.datos_nuevos', '', true);
    END IF;

    RETURN jsonb_build_object(
        'success', true,
        'message', CASE WHEN COALESCE(p_aplicar_usuarios, false)
                        THEN format('Grupo actualizado; perfil, horario y tipo aplicados a %s usuario(s)', v_aplicados)
                        ELSE 'Grupo actualizado exitosamente' END,
        'data', seguridad.fn_grupos_json(p_id) || jsonb_build_object('usuarios_actualizados', v_aplicados)
    );

EXCEPTION
    WHEN unique_violation THEN
        RAISE EXCEPTION 'Ya existe otro grupo con ese nombre en el mismo nivel' USING ERRCODE = 'P0006';
END;
$function$;

-- ---------------------------------------------------------------------------
-- ELIMINAR (sólo si no tiene usuarios ni subgrupos)
-- ---------------------------------------------------------------------------
