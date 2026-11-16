-- ===========================================================================
-- DÓNDE MÁS PUEDE MARCAR: rh.empleados_marcacion_sucursal
-- ===========================================================================
-- `rh.empleados.sucursal_id` dice dónde trabaja alguien, y hasta ahora era el
-- único sitio donde se le aceptaba la marcación. Eso vale para quien está
-- siempre en el mismo local, pero no para un cobrador, un jefe de zona o un
-- gerente, que hoy marcan en la matriz y mañana en la sucursal del norte.
--
-- Esta tabla lleva las sucursales ADICIONALES en las que cada uno puede
-- marcar. La principal no se repite aquí: se da por supuesta.
--
-- La regla al marcar pasa a ser: basta con estar dentro del perímetro de UNA
-- de sus sucursales —la principal o cualquiera de éstas—. Si ninguna exige
-- perímetro, puede marcar desde donde sea, como antes.
--
-- Se aplica sobre 2026-10-21_rh_empleados_sucursal_en_la_ficha.sql.
\set ON_ERROR_STOP on

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. LA TABLA
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS rh.empleados_marcacion_sucursal (
    id          bigserial PRIMARY KEY,
    empleado_id bigint NOT NULL,
    sucursal_id bigint NOT NULL,
    -- Para qué se le autorizó: «cobra en esta zona», «cubre los sábados»…
    observacion varchar(250),
    -- Se puede quitar el permiso sin perder el registro de que lo tuvo
    activo      boolean NOT NULL DEFAULT true,

    created_at  timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at  timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    created_by  varchar(50),
    updated_by  varchar(50),

    CONSTRAINT fk_ems_empleado FOREIGN KEY (empleado_id)
        REFERENCES rh.empleados (id) ON DELETE CASCADE,
    CONSTRAINT fk_ems_sucursal FOREIGN KEY (sucursal_id)
        REFERENCES ventas.sucursales (id),
    -- La misma sucursal dos veces para la misma persona no significa nada
    CONSTRAINT uk_ems_empleado_sucursal UNIQUE (empleado_id, sucursal_id)
);

COMMENT ON TABLE rh.empleados_marcacion_sucursal IS
    'Sucursales ADICIONALES donde un empleado puede marcar asistencia; la suya (rh.empleados.sucursal_id) no se repite aquí';

CREATE INDEX IF NOT EXISTS ix_ems_empleado ON rh.empleados_marcacion_sucursal (empleado_id);
CREATE INDEX IF NOT EXISTS ix_ems_sucursal ON rh.empleados_marcacion_sucursal (sucursal_id);

-- Los tres disparadores de siempre: quién tocó, cuándo, y el registro del cambio
DROP TRIGGER IF EXISTS tr_ems_audit_users ON rh.empleados_marcacion_sucursal;
CREATE TRIGGER tr_ems_audit_users
    BEFORE INSERT OR UPDATE ON rh.empleados_marcacion_sucursal
    FOR EACH ROW EXECUTE FUNCTION auditoria.fn_set_audit_users();

DROP TRIGGER IF EXISTS tr_ems_updated_at ON rh.empleados_marcacion_sucursal;
CREATE TRIGGER tr_ems_updated_at
    BEFORE UPDATE ON rh.empleados_marcacion_sucursal
    FOR EACH ROW EXECUTE FUNCTION auditoria.fn_update_updated_at_column();

DROP TRIGGER IF EXISTS tr_ems_auditoria ON rh.empleados_marcacion_sucursal;
CREATE TRIGGER tr_ems_auditoria
    AFTER INSERT OR UPDATE OR DELETE ON rh.empleados_marcacion_sucursal
    FOR EACH ROW EXECUTE FUNCTION auditoria.fn_auditar_cambios();

-- ---------------------------------------------------------------------------
-- 2. LISTAR LAS DE UN EMPLEADO
-- ---------------------------------------------------------------------------
-- Devuelve lo que la pantalla necesita enseñar en la rejilla sin tener que
-- preguntar por cada sucursal: su código, su nombre y, sobre todo, si tiene
-- perímetro, que es lo que decide si allí se controla la ubicación.
CREATE OR REPLACE FUNCTION rh.fn_empleados_sucursales_listar(p_empleado_id bigint)
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
            'id',              e.id,
            'empleado_id',     e.empleado_id,
            'sucursal_id',     e.sucursal_id,
            'codigo',          s.codigo,
            'nombre',          s.nombre,
            'direccion',       s.direccion,
            'tipo',            s.tipo,
            'radio_metros',    s.radio_metros,
            'num_vertices',    CASE WHEN s.vertices IS NULL THEN 0 ELSE jsonb_array_length(s.vertices) END,
            'tiene_perimetro', (s.tipo = 'POLIGONO' AND s.vertices IS NOT NULL AND jsonb_array_length(s.vertices) >= 3)
                               OR (s.tipo = 'CIRCULO' AND s.centro_lat IS NOT NULL AND s.radio_metros IS NOT NULL),
            'sucursal_activa', s.activo AND s.deleted_at IS NULL,
            'observacion',     e.observacion,
            'activo',          e.activo,
            'created_by',      e.created_by,
            'updated_by',      e.updated_by,
            'created_at',      to_char(e.created_at, 'YYYY-MM-DD HH24:MI:SS'),
            'updated_at',      to_char(e.updated_at, 'YYYY-MM-DD HH24:MI:SS')
        ) ORDER BY s.nombre
    ), '[]'::jsonb) INTO v_data
    FROM rh.empleados_marcacion_sucursal e
    JOIN ventas.sucursales s ON s.id = e.sucursal_id
    WHERE e.empleado_id = p_empleado_id;

    RETURN jsonb_build_object('success', true,
                              'message', 'Sucursales de marcación obtenidas exitosamente',
                              'data', v_data);
END;
$function$;

-- ---------------------------------------------------------------------------
-- 3. GUARDARLAS (la lista entera, como los contactos de emergencia)
-- ---------------------------------------------------------------------------
-- Llega la lista COMPLETA: lo que no viene, se borra. Es el mismo trato que
-- rh.fn_contactos_guardar, y evita tener que mandar altas y bajas por
-- separado desde una rejilla donde se añade y se quita a mano.
CREATE OR REPLACE FUNCTION rh.fn_empleados_sucursales_guardar(
    p_empleado_id    bigint,
    p_sucursales     jsonb,
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
SET search_path TO 'pg_catalog', 'rh', 'ventas', 'auditoria'
AS $function$
DECLARE
    v_s           jsonb;
    v_id          bigint;
    v_sucursal    bigint;
    v_ids         bigint[] := ARRAY[]::bigint[];
    v_fecha       timestamptz := CURRENT_TIMESTAMP;
    v_insertados  integer := 0;
    v_editados    integer := 0;
    v_borrados    integer := 0;
    v_principal   bigint;
    v_suc         record;
BEGIN
    PERFORM set_config('app.usuario_id',     COALESCE(p_usuario_id::text, ''), true);
    PERFORM set_config('app.usuario_login',  COALESCE(p_usuario_login, current_user), true);
    PERFORM set_config('app.usuario_nombre', COALESCE(p_usuario_nombre, current_user), true);
    PERFORM set_config('app.ip_address',     COALESCE(p_ip_address::text, ''), true);
    PERFORM set_config('app.user_agent',     COALESCE(p_user_agent, ''), true);
    PERFORM set_config('app.request_id',     COALESCE(p_request_id::text, ''), true);
    PERFORM set_config('app.modulo',         'rh.empleados_marcacion_sucursal', true);

    SELECT sucursal_id INTO v_principal FROM rh.empleados WHERE id = p_empleado_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'El empleado no existe' USING ERRCODE = 'P0013';
    END IF;

    FOR v_s IN SELECT * FROM jsonb_array_elements(COALESCE(p_sucursales, '[]'::jsonb)) LOOP
        v_sucursal := NULLIF(v_s->>'sucursal_id', '')::bigint;
        IF v_sucursal IS NULL THEN
            RAISE EXCEPTION 'Cada línea necesita una sucursal' USING ERRCODE = 'P0001';
        END IF;

        -- La suya no se repite aquí: ya puede marcar en ella
        IF v_sucursal = v_principal THEN
            CONTINUE;
        END IF;

        SELECT id, nombre, activo, deleted_at INTO v_suc
          FROM ventas.sucursales WHERE id = v_sucursal;
        IF NOT FOUND OR v_suc.deleted_at IS NOT NULL THEN
            RAISE EXCEPTION 'La sucursal indicada no existe o está en la papelera' USING ERRCODE = 'P0016';
        END IF;
        IF NOT v_suc.activo THEN
            RAISE EXCEPTION 'La sucursal «%» está inactiva', v_suc.nombre USING ERRCODE = 'P0017';
        END IF;

        v_id := NULLIF(v_s->>'id', '')::bigint;

        IF v_id IS NOT NULL AND EXISTS (SELECT 1 FROM rh.empleados_marcacion_sucursal
                                         WHERE id = v_id AND empleado_id = p_empleado_id) THEN
            UPDATE rh.empleados_marcacion_sucursal
               SET sucursal_id = v_sucursal,
                   observacion = NULLIF(TRIM(COALESCE(v_s->>'observacion', '')), ''),
                   activo      = COALESCE((v_s->>'activo')::boolean, true),
                   updated_by  = p_usuario_login,
                   updated_at  = v_fecha
             WHERE id = v_id
               AND (sucursal_id, COALESCE(observacion, ''), activo)
                   IS DISTINCT FROM
                   (v_sucursal,
                    COALESCE(NULLIF(TRIM(COALESCE(v_s->>'observacion', '')), ''), ''),
                    COALESCE((v_s->>'activo')::boolean, true));
            IF FOUND THEN v_editados := v_editados + 1; END IF;
        ELSE
            -- Si ya la tenía autorizada, se actualiza en vez de reventar
            -- contra la clave única: dos veces la misma no significa nada.
            INSERT INTO rh.empleados_marcacion_sucursal
                   (empleado_id, sucursal_id, observacion, activo, created_by, updated_by, created_at, updated_at)
            VALUES (p_empleado_id, v_sucursal,
                    NULLIF(TRIM(COALESCE(v_s->>'observacion', '')), ''),
                    COALESCE((v_s->>'activo')::boolean, true),
                    p_usuario_login, p_usuario_login, v_fecha, v_fecha)
            ON CONFLICT (empleado_id, sucursal_id) DO UPDATE
               SET observacion = EXCLUDED.observacion,
                   activo      = EXCLUDED.activo,
                   updated_by  = EXCLUDED.updated_by,
                   updated_at  = EXCLUDED.updated_at
            RETURNING id INTO v_id;
            v_insertados := v_insertados + 1;
        END IF;

        v_ids := array_append(v_ids, v_id);
    END LOOP;

    -- Las que ya no vienen en la lista
    DELETE FROM rh.empleados_marcacion_sucursal
     WHERE empleado_id = p_empleado_id
       AND NOT (id = ANY (v_ids));
    GET DIAGNOSTICS v_borrados = ROW_COUNT;

    RETURN jsonb_build_object(
        'success', true,
        'message', format('Sucursales de marcación guardadas: %s nueva(s), %s modificada(s), %s quitada(s)',
                          v_insertados, v_editados, v_borrados),
        'data', (rh.fn_empleados_sucursales_listar(p_empleado_id))->'data'
    );
END;
$function$;

COMMIT;
