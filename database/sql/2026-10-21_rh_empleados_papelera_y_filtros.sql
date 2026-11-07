-- ===========================================================================
-- EMPLEADOS: PAPELERA DE RECICLAJE Y FILTROS DE COLUMNA
-- ===========================================================================
-- La pantalla de empleados se queda con lo que ya tienen clientes, marcas y
-- sucursales:
--
--   · BORRADO LÓGICO. «Eliminar» deja de ser un DELETE: el empleado va a la
--     papelera (deleted_at / deleted_by), sale de los listados y de los
--     selectores, y desde allí se restaura o se borra de verdad.
--
--   · FILTROS DE COLUMNA en el servidor, con la misma lista blanca de
--     siempre: lo que no esté aquí se ignora, aunque la pantalla lo mande.
--
-- Los índices únicos pasan a ser PARCIALES: un empleado en la papelera no
-- puede impedir dar de alta a otro con la misma cédula o el mismo correo.
\set ON_ERROR_STOP on

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. LAS COLUMNAS DEL BORRADO LÓGICO
-- ---------------------------------------------------------------------------
ALTER TABLE rh.empleados
    ADD COLUMN IF NOT EXISTS deleted_at timestamptz,
    ADD COLUMN IF NOT EXISTS deleted_by varchar(50);

COMMENT ON COLUMN rh.empleados.deleted_at IS 'Cuándo se envió a la papelera; NULL = vigente';
COMMENT ON COLUMN rh.empleados.deleted_by IS 'Quién lo envió a la papelera';

CREATE INDEX IF NOT EXISTS ix_empleados_papelera
    ON rh.empleados (deleted_at) WHERE deleted_at IS NOT NULL;

-- Únicos SÓLO entre los vigentes.
-- Son RESTRICCIONES, no índices sueltos, y una restricción no admite un WHERE:
-- hay que tirarla y poner en su lugar un índice único parcial.
ALTER TABLE rh.empleados DROP CONSTRAINT IF EXISTS uk_empleados_email;
DROP INDEX IF EXISTS rh.uk_empleados_email;
CREATE UNIQUE INDEX uk_empleados_email
    ON rh.empleados (email) WHERE deleted_at IS NULL;

ALTER TABLE rh.empleados DROP CONSTRAINT IF EXISTS uk_empleados_numero_identificacion;
DROP INDEX IF EXISTS rh.uk_empleados_numero_identificacion;
CREATE UNIQUE INDEX uk_empleados_numero_identificacion
    ON rh.empleados (numero_identificacion, tipo_identificacion) WHERE deleted_at IS NULL;

ALTER TABLE rh.empleados DROP CONSTRAINT IF EXISTS uk_numero_identificacion;
DROP INDEX IF EXISTS rh.uk_numero_identificacion;
CREATE UNIQUE INDEX uk_numero_identificacion
    ON rh.empleados (numero_identificacion) WHERE deleted_at IS NULL;

-- ---------------------------------------------------------------------------
-- 2. ELIMINAR = A LA PAPELERA
-- ---------------------------------------------------------------------------
-- Las comprobaciones de siempre se quedan: no tiene sentido mandar a la
-- papelera a quien es jefe de alguien o responsable de un departamento,
-- porque esas fichas quedarían apuntando a un nombre que ya no sale.
--
-- El historial de cargos y las ausencias YA NO LO IMPIDEN: con borrado lógico
-- no se pierde nada, el empleado sigue ahí y su historial también. Antes eran
-- un muro porque aquello era un DELETE de verdad.
CREATE OR REPLACE FUNCTION rh.fn_empleados_eliminar(
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
    v_datos jsonb;
    v_n     bigint;
BEGIN
    PERFORM set_config('app.usuario_id',     COALESCE(p_usuario_id::text, ''), true);
    PERFORM set_config('app.usuario_login',  COALESCE(p_usuario_login, current_user), true);
    PERFORM set_config('app.usuario_nombre', COALESCE(p_usuario_nombre, current_user), true);
    PERFORM set_config('app.ip_address',     COALESCE(p_ip_address::text, ''), true);
    PERFORM set_config('app.user_agent',     COALESCE(p_user_agent, ''), true);
    PERFORM set_config('app.request_id',     COALESCE(p_request_id::text, ''), true);
    PERFORM set_config('app.modulo',         'rh.empleados', true);

    v_datos := (rh.fn_empleados_obtener(p_id))->'data';
    IF v_datos IS NULL THEN
        RAISE EXCEPTION 'El empleado no existe' USING ERRCODE = 'P0013';
    END IF;

    IF (SELECT deleted_at FROM rh.empleados WHERE id = p_id) IS NOT NULL THEN
        RAISE EXCEPTION 'Ese empleado ya está en la papelera' USING ERRCODE = 'P0019';
    END IF;

    SELECT COUNT(*) INTO v_n FROM rh.empleados WHERE jefe_id = p_id AND deleted_at IS NULL;
    IF v_n > 0 THEN
        RAISE EXCEPTION 'No se puede eliminar: es jefe de % empleado(s). Reasígnelos o desactívelo.', v_n
              USING ERRCODE = 'P0014';
    END IF;

    SELECT COUNT(*) INTO v_n FROM rh.departamentos WHERE empleado_id = p_id;
    IF v_n > 0 THEN
        RAISE EXCEPTION 'No se puede eliminar: es responsable de % departamento(s). Cambie el responsable o desactívelo.', v_n
              USING ERRCODE = 'P0014';
    END IF;

    UPDATE rh.empleados
       SET deleted_at = CURRENT_TIMESTAMP,
           deleted_by = COALESCE(p_usuario_login, current_user),
           updated_by = COALESCE(p_usuario_login, current_user),
           updated_at = CURRENT_TIMESTAMP
     WHERE id = p_id;

    RETURN jsonb_build_object('success', true,
        'message', format('«%s» fue enviado a la papelera de reciclaje',
                          TRIM(CONCAT_WS(' ', v_datos->>'nombres', v_datos->>'apellidos'))),
        'data', v_datos);
END;
$function$;

-- ---------------------------------------------------------------------------
-- 3. LA PAPELERA
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION rh.fn_empleados_papelera_listar()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'rh', 'ventas'
AS $function$
DECLARE v_data jsonb;
BEGIN
    SELECT COALESCE(jsonb_agg(
        jsonb_build_object(
            'id',                    e.id,
            'numero_identificacion', e.numero_identificacion,
            'nombres',               e.nombres,
            'apellidos',             e.apellidos,
            'nombre_completo',       TRIM(CONCAT_WS(' ', e.nombres, e.apellidos)),
            'email',                 e.email,
            'celular',               e.celular,
            'foto',                  e.foto,
            'cargo_nombre',          c.nombre,
            'departamento_nombre',   d.nombre,
            'sucursal_nombre',       s.nombre,
            'estado',                e.estado,
            'activo',                e.activo,
            'deleted_at',            to_char(e.deleted_at, 'YYYY-MM-DD HH24:MI:SS'),
            'deleted_by',            e.deleted_by
        ) ORDER BY e.deleted_at DESC
    ), '[]'::jsonb) INTO v_data
      FROM rh.empleados e
      LEFT JOIN rh.cargos c         ON c.id = e.cargo_id
      LEFT JOIN rh.departamentos d  ON d.id = e.departamento_id
      LEFT JOIN ventas.sucursales s ON s.id = e.sucursal_id
     WHERE e.deleted_at IS NOT NULL;

    RETURN jsonb_build_object('success', true, 'message', 'Papelera de empleados', 'data', v_data);
END;
$function$;

CREATE OR REPLACE FUNCTION rh.fn_empleados_restaurar(
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
    PERFORM set_config('app.modulo',         'rh.empleados', true);

    -- Mientras estaba en la papelera alguien pudo dar de alta su cédula o su
    -- correo: se avisa con nombre y apellido en vez de soltar el error del índice.
    SELECT string_agg(DISTINCT p.numero_identificacion, ', ') INTO v_choque
      FROM rh.empleados p
      JOIN rh.empleados v
        ON v.deleted_at IS NULL
       AND (v.numero_identificacion = p.numero_identificacion OR LOWER(v.email) = LOWER(p.email))
     WHERE p.id IN (SELECT (jsonb_array_elements_text(p_ids))::bigint)
       AND p.deleted_at IS NOT NULL;

    IF v_choque IS NOT NULL THEN
        RAISE EXCEPTION 'No se puede restaurar: ya hay un empleado vigente con la identificación o el correo de %', v_choque
              USING ERRCODE = 'P0006';
    END IF;

    SELECT array_agg(TRIM(CONCAT_WS(' ', nombres, apellidos))) INTO v_nombres
      FROM rh.empleados
     WHERE id IN (SELECT (jsonb_array_elements_text(p_ids))::bigint)
       AND deleted_at IS NOT NULL;

    IF v_nombres IS NULL THEN
        RAISE EXCEPTION 'Sólo se puede restaurar lo que está en la papelera' USING ERRCODE = 'P0019';
    END IF;

    UPDATE rh.empleados
       SET deleted_at = NULL,
           deleted_by = NULL,
           updated_by = COALESCE(p_usuario_login, current_user),
           updated_at = CURRENT_TIMESTAMP
     WHERE id IN (SELECT (jsonb_array_elements_text(p_ids))::bigint)
       AND deleted_at IS NOT NULL;

    GET DIAGNOSTICS v_cuantos = ROW_COUNT;

    RETURN jsonb_build_object('success', true,
        'message', v_cuantos || ' empleado(s) restaurado(s)',
        'data', jsonb_build_object('nombres', to_jsonb(v_nombres), 'restaurados', v_cuantos));
END;
$function$;

-- Borrado de verdad. Aquí SÍ vuelven a mandar las referencias: lo que se
-- borra no se recupera, y un historial de cargos apuntando a nadie es un
-- agujero en los informes.
CREATE OR REPLACE FUNCTION rh.fn_empleados_eliminar_definitivo(
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
    v_nombres  text[];
    v_ficheros text[];
    v_cuantos  integer;
    v_n        bigint;
BEGIN
    PERFORM set_config('app.usuario_id',     COALESCE(p_usuario_id::text, ''), true);
    PERFORM set_config('app.usuario_login',  COALESCE(p_usuario_login, current_user), true);
    PERFORM set_config('app.usuario_nombre', COALESCE(p_usuario_nombre, current_user), true);
    PERFORM set_config('app.ip_address',     COALESCE(p_ip_address::text, ''), true);
    PERFORM set_config('app.user_agent',     COALESCE(p_user_agent, ''), true);
    PERFORM set_config('app.request_id',     COALESCE(p_request_id::text, ''), true);
    PERFORM set_config('app.modulo',         'rh.empleados', true);

    SELECT array_agg(TRIM(CONCAT_WS(' ', nombres, apellidos))),
           array_remove(array_agg(foto) || array_agg(url_foto_mapa) || array_agg(url_foto_casa), NULL)
      INTO v_nombres, v_ficheros
      FROM rh.empleados
     WHERE id IN (SELECT (jsonb_array_elements_text(p_ids))::bigint)
       AND deleted_at IS NOT NULL;

    IF v_nombres IS NULL THEN
        RAISE EXCEPTION 'Sólo se puede eliminar definitivamente lo que está en la papelera' USING ERRCODE = 'P0019';
    END IF;

    SELECT COUNT(*) INTO v_n FROM rh.historial_cargos
     WHERE empleado_id IN (SELECT (jsonb_array_elements_text(p_ids))::bigint);
    IF v_n > 0 THEN
        RAISE EXCEPTION 'No se puede borrar definitivamente: hay % registro(s) en el historial de cargos', v_n
              USING ERRCODE = 'P0014';
    END IF;

    SELECT COUNT(*) INTO v_n FROM rh.ausencias
     WHERE empleado_id IN (SELECT (jsonb_array_elements_text(p_ids))::bigint)
        OR aprobado_por IN (SELECT (jsonb_array_elements_text(p_ids))::bigint);
    IF v_n > 0 THEN
        RAISE EXCEPTION 'No se puede borrar definitivamente: hay % ausencia(s) registrada(s)', v_n
              USING ERRCODE = 'P0014';
    END IF;

    SELECT COUNT(*) INTO v_n FROM rh.marcaciones
     WHERE empleado_id IN (SELECT (jsonb_array_elements_text(p_ids))::bigint);
    IF v_n > 0 THEN
        RAISE EXCEPTION 'No se puede borrar definitivamente: hay % marcación(es) registrada(s)', v_n
              USING ERRCODE = 'P0014';
    END IF;

    DELETE FROM rh.empleados
     WHERE id IN (SELECT (jsonb_array_elements_text(p_ids))::bigint)
       AND deleted_at IS NOT NULL;

    GET DIAGNOSTICS v_cuantos = ROW_COUNT;

    RETURN jsonb_build_object('success', true,
        'message', v_cuantos || ' empleado(s) eliminado(s) definitivamente',
        'data', jsonb_build_object('nombres', to_jsonb(v_nombres),
                                   'ficheros', to_jsonb(COALESCE(v_ficheros, ARRAY[]::text[])),
                                   'eliminados', v_cuantos));
EXCEPTION
    WHEN foreign_key_violation THEN
        RAISE EXCEPTION 'No se puede borrar definitivamente: tiene registros asociados' USING ERRCODE = 'P0014';
END;
$function$;

CREATE OR REPLACE FUNCTION rh.fn_empleados_papelera_vaciar(
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
    v_ids jsonb;
BEGIN
    -- Los que se pueden borrar: el resto se queda, y la función de arriba es
    -- la que explica por qué. Vaciar no puede ser «o todo o nada».
    SELECT COALESCE(jsonb_agg(e.id), '[]'::jsonb) INTO v_ids
      FROM rh.empleados e
     WHERE e.deleted_at IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM rh.historial_cargos h WHERE h.empleado_id = e.id)
       AND NOT EXISTS (SELECT 1 FROM rh.ausencias a WHERE a.empleado_id = e.id OR a.aprobado_por = e.id)
       AND NOT EXISTS (SELECT 1 FROM rh.marcaciones m WHERE m.empleado_id = e.id);

    IF jsonb_array_length(v_ids) = 0 THEN
        RETURN jsonb_build_object('success', true,
            'message', 'No hay empleados que se puedan borrar definitivamente',
            'data', jsonb_build_object('eliminados', 0, 'ficheros', '[]'::jsonb));
    END IF;

    RETURN rh.fn_empleados_eliminar_definitivo(v_ids, p_usuario_id, p_usuario_login,
                                               p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);
END;
$function$;

COMMIT;
