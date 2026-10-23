-- ===========================================================================
-- CARGOS: PAPELERA DE RECICLAJE Y FILTROS DE COLUMNA
-- ===========================================================================
-- Lo mismo que ya tienen marcas, clientes, sucursales y empleados:
--
--   · BORRADO LÓGICO. «Eliminar» deja de ser un DELETE: el cargo va a la
--     papelera (deleted_at / deleted_by), sale del listado y del selector de
--     la ficha del empleado, y desde allí se restaura o se borra de verdad.
--
--   · FILTROS DE COLUMNA en el servidor, con la lista blanca de siempre.
--
-- El índice único del nombre pasa a ser PARCIAL: un cargo en la papelera no
-- puede impedir crear otro que se llame igual.
\set ON_ERROR_STOP on

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. LAS COLUMNAS DEL BORRADO LÓGICO
-- ---------------------------------------------------------------------------
ALTER TABLE rh.cargos
    ADD COLUMN IF NOT EXISTS deleted_at timestamptz,
    ADD COLUMN IF NOT EXISTS deleted_by varchar(50);

COMMENT ON COLUMN rh.cargos.deleted_at IS 'Cuándo se envió a la papelera; NULL = vigente';
COMMENT ON COLUMN rh.cargos.deleted_by IS 'Quién lo envió a la papelera';

CREATE INDEX IF NOT EXISTS ix_cargos_papelera
    ON rh.cargos (deleted_at) WHERE deleted_at IS NOT NULL;

-- Único SÓLO entre los vigentes. Es una restricción, y una restricción no
-- admite WHERE: se tira y se pone un índice único parcial en su lugar.
ALTER TABLE rh.cargos DROP CONSTRAINT IF EXISTS uk_cargos_nombre;
DROP INDEX IF EXISTS rh.uk_cargos_nombre;
CREATE UNIQUE INDEX uk_cargos_nombre ON rh.cargos (nombre) WHERE deleted_at IS NULL;

-- ---------------------------------------------------------------------------
-- 2. ELIMINAR = A LA PAPELERA
-- ---------------------------------------------------------------------------
-- Las comprobaciones se quedan: un cargo con gente asignada o con historial
-- no debe desaparecer del listado, porque esas fichas se quedarían señalando
-- un cargo que ya no sale. Para eso está desactivarlo.
CREATE OR REPLACE FUNCTION rh.fn_cargos_eliminar(
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
SET search_path TO 'pg_catalog', 'rh', 'auditoria'
AS $function$
DECLARE
    v_actual    rh.cargos%ROWTYPE;
    v_empleados bigint;
    v_historial bigint;
    v_datos     jsonb;
BEGIN
    PERFORM set_config('app.usuario_id',     COALESCE(p_usuario_id::text, ''), true);
    PERFORM set_config('app.usuario_login',  COALESCE(p_usuario_login, current_user), true);
    PERFORM set_config('app.usuario_nombre', COALESCE(p_usuario_nombre, current_user), true);
    PERFORM set_config('app.ip_address',     COALESCE(p_ip_address::text, ''), true);
    PERFORM set_config('app.user_agent',     COALESCE(p_user_agent, ''), true);
    PERFORM set_config('app.request_id',     COALESCE(p_request_id::text, ''), true);
    PERFORM set_config('app.modulo',         'rh.cargos', true);

    SELECT * INTO v_actual FROM rh.cargos WHERE id = p_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'El cargo no existe' USING ERRCODE = 'P0013';
    END IF;
    IF v_actual.deleted_at IS NOT NULL THEN
        RAISE EXCEPTION 'Ese cargo ya está en la papelera' USING ERRCODE = 'P0019';
    END IF;

    SELECT COUNT(*) INTO v_empleados FROM rh.empleados
     WHERE cargo_id = p_id AND deleted_at IS NULL;
    SELECT COUNT(*) INTO v_historial FROM rh.historial_cargos WHERE cargo_id = p_id;

    IF v_empleados > 0 THEN
        RAISE EXCEPTION 'No se puede eliminar: el cargo tiene % empleado(s) asignado(s). Desactívelo en su lugar.', v_empleados
              USING ERRCODE = 'P0014';
    END IF;
    IF v_historial > 0 THEN
        RAISE EXCEPTION 'No se puede eliminar: el cargo aparece en el historial de % empleado(s). Desactívelo en su lugar.', v_historial
              USING ERRCODE = 'P0014';
    END IF;

    v_datos := jsonb_build_object(
        'id', v_actual.id, 'nombre', v_actual.nombre, 'descripcion', v_actual.descripcion,
        'nivel', v_actual.nivel, 'salario_base', v_actual.salario_base, 'activo', v_actual.activo,
        'created_by', v_actual.created_by, 'created_at', to_char(v_actual.created_at, 'YYYY-MM-DD HH24:MI:SS'),
        'updated_by', v_actual.updated_by, 'updated_at', to_char(v_actual.updated_at, 'YYYY-MM-DD HH24:MI:SS')
    );

    UPDATE rh.cargos
       SET deleted_at = CURRENT_TIMESTAMP,
           deleted_by = COALESCE(p_usuario_login, current_user),
           updated_by = COALESCE(p_usuario_login, current_user),
           updated_at = CURRENT_TIMESTAMP
     WHERE id = p_id;

    RETURN jsonb_build_object('success', true,
        'message', format('«%s» fue enviado a la papelera de reciclaje', v_actual.nombre),
        'data', v_datos);
END;
$function$;

-- ---------------------------------------------------------------------------
-- 3. LA PAPELERA
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION rh.fn_cargos_papelera_listar()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'rh'
AS $function$
DECLARE v_data jsonb;
BEGIN
    SELECT COALESCE(jsonb_agg(
        jsonb_build_object(
            'id',            c.id,
            'nombre',        c.nombre,
            'descripcion',   c.descripcion,
            'nivel',         c.nivel,
            'salario_base',  c.salario_base,
            'activo',        c.activo,
            -- Cuántos lo usan HOY: un cargo sólo llega aquí sin gente, así
            -- que normalmente es 0; deja de serlo si alguien restauró a un
            -- empleado que lo tenía.
            'num_empleados', (SELECT COUNT(*) FROM rh.empleados e
                               WHERE e.cargo_id = c.id AND e.deleted_at IS NULL),
            'deleted_at',    to_char(c.deleted_at, 'YYYY-MM-DD HH24:MI:SS'),
            'deleted_by',    c.deleted_by
        ) ORDER BY c.deleted_at DESC
    ), '[]'::jsonb) INTO v_data
      FROM rh.cargos c
     WHERE c.deleted_at IS NOT NULL;

    RETURN jsonb_build_object('success', true, 'message', 'Papelera de cargos', 'data', v_data);
END;
$function$;

CREATE OR REPLACE FUNCTION rh.fn_cargos_restaurar(
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
SET search_path TO 'pg_catalog', 'rh', 'auditoria'
AS $function$
DECLARE
    v_nombres text[];
    v_cuantos integer;
    v_choque  text;
BEGIN
    PERFORM set_config('app.usuario_id',     COALESCE(p_usuario_id::text, ''), true);
    PERFORM set_config('app.usuario_login',  COALESCE(p_usuario_login, current_user), true);
    PERFORM set_config('app.usuario_nombre', COALESCE(p_usuario_nombre, current_user), true);
    PERFORM set_config('app.ip_address',     COALESCE(p_ip_address::text, ''), true);
    PERFORM set_config('app.user_agent',     COALESCE(p_user_agent, ''), true);
    PERFORM set_config('app.request_id',     COALESCE(p_request_id::text, ''), true);
    PERFORM set_config('app.modulo',         'rh.cargos', true);

    -- Mientras estaba en la papelera alguien pudo crear otro con ese nombre:
    -- se avisa con el nombre en vez de soltar el error del índice.
    SELECT string_agg(DISTINCT p.nombre, ', ') INTO v_choque
      FROM rh.cargos p
      JOIN rh.cargos v ON v.deleted_at IS NULL AND UPPER(TRIM(v.nombre)) = UPPER(TRIM(p.nombre))
     WHERE p.id IN (SELECT (jsonb_array_elements_text(p_ids))::bigint)
       AND p.deleted_at IS NOT NULL;

    IF v_choque IS NOT NULL THEN
        RAISE EXCEPTION 'No se puede restaurar: ya hay un cargo vigente que se llama %', v_choque
              USING ERRCODE = 'P0006';
    END IF;

    SELECT array_agg(nombre) INTO v_nombres
      FROM rh.cargos
     WHERE id IN (SELECT (jsonb_array_elements_text(p_ids))::bigint)
       AND deleted_at IS NOT NULL;

    IF v_nombres IS NULL THEN
        RAISE EXCEPTION 'Sólo se puede restaurar lo que está en la papelera' USING ERRCODE = 'P0019';
    END IF;

    UPDATE rh.cargos
       SET deleted_at = NULL,
           deleted_by = NULL,
           updated_by = COALESCE(p_usuario_login, current_user),
           updated_at = CURRENT_TIMESTAMP
     WHERE id IN (SELECT (jsonb_array_elements_text(p_ids))::bigint)
       AND deleted_at IS NOT NULL;

    GET DIAGNOSTICS v_cuantos = ROW_COUNT;

    RETURN jsonb_build_object('success', true,
        'message', v_cuantos || ' cargo(s) restaurado(s)',
        'data', jsonb_build_object('nombres', to_jsonb(v_nombres), 'restaurados', v_cuantos));
END;
$function$;

-- Borrado de verdad. Aquí vuelven a mandar las referencias: lo que se borra
-- no se recupera, y un historial apuntando a un cargo que ya no existe es un
-- agujero en los informes.
CREATE OR REPLACE FUNCTION rh.fn_cargos_eliminar_definitivo(
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
SET search_path TO 'pg_catalog', 'rh', 'auditoria'
AS $function$
DECLARE
    v_nombres text[];
    v_cuantos integer;
    v_n       bigint;
BEGIN
    PERFORM set_config('app.usuario_id',     COALESCE(p_usuario_id::text, ''), true);
    PERFORM set_config('app.usuario_login',  COALESCE(p_usuario_login, current_user), true);
    PERFORM set_config('app.usuario_nombre', COALESCE(p_usuario_nombre, current_user), true);
    PERFORM set_config('app.ip_address',     COALESCE(p_ip_address::text, ''), true);
    PERFORM set_config('app.user_agent',     COALESCE(p_user_agent, ''), true);
    PERFORM set_config('app.request_id',     COALESCE(p_request_id::text, ''), true);
    PERFORM set_config('app.modulo',         'rh.cargos', true);

    SELECT array_agg(nombre) INTO v_nombres
      FROM rh.cargos
     WHERE id IN (SELECT (jsonb_array_elements_text(p_ids))::bigint)
       AND deleted_at IS NOT NULL;

    IF v_nombres IS NULL THEN
        RAISE EXCEPTION 'Sólo se puede eliminar definitivamente lo que está en la papelera' USING ERRCODE = 'P0019';
    END IF;

    SELECT COUNT(*) INTO v_n FROM rh.empleados
     WHERE cargo_id IN (SELECT (jsonb_array_elements_text(p_ids))::bigint);
    IF v_n > 0 THEN
        RAISE EXCEPTION 'No se puede borrar definitivamente: % empleado(s) lo tienen asignado', v_n
              USING ERRCODE = 'P0014';
    END IF;

    SELECT COUNT(*) INTO v_n FROM rh.historial_cargos
     WHERE cargo_id IN (SELECT (jsonb_array_elements_text(p_ids))::bigint);
    IF v_n > 0 THEN
        RAISE EXCEPTION 'No se puede borrar definitivamente: aparece en el historial de % empleado(s)', v_n
              USING ERRCODE = 'P0014';
    END IF;

    DELETE FROM rh.cargos
     WHERE id IN (SELECT (jsonb_array_elements_text(p_ids))::bigint)
       AND deleted_at IS NOT NULL;

    GET DIAGNOSTICS v_cuantos = ROW_COUNT;

    RETURN jsonb_build_object('success', true,
        'message', v_cuantos || ' cargo(s) eliminado(s) definitivamente',
        'data', jsonb_build_object('nombres', to_jsonb(v_nombres), 'eliminados', v_cuantos));
EXCEPTION
    WHEN foreign_key_violation THEN
        RAISE EXCEPTION 'No se puede borrar definitivamente: tiene registros asociados' USING ERRCODE = 'P0014';
END;
$function$;

CREATE OR REPLACE FUNCTION rh.fn_cargos_papelera_vaciar(
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
SET search_path TO 'pg_catalog', 'rh', 'auditoria'
AS $function$
DECLARE v_ids jsonb;
BEGIN
    -- Sólo los que se pueden borrar: el resto se queda, y la función de
    -- arriba explica por qué. Vaciar no puede ser «o todo o nada».
    SELECT COALESCE(jsonb_agg(c.id), '[]'::jsonb) INTO v_ids
      FROM rh.cargos c
     WHERE c.deleted_at IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM rh.empleados e WHERE e.cargo_id = c.id)
       AND NOT EXISTS (SELECT 1 FROM rh.historial_cargos h WHERE h.cargo_id = c.id);

    IF jsonb_array_length(v_ids) = 0 THEN
        RETURN jsonb_build_object('success', true,
            'message', 'No hay cargos que se puedan borrar definitivamente',
            'data', jsonb_build_object('eliminados', 0));
    END IF;

    RETURN rh.fn_cargos_eliminar_definitivo(v_ids, p_usuario_id, p_usuario_login,
                                            p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);
END;
$function$;

COMMIT;
