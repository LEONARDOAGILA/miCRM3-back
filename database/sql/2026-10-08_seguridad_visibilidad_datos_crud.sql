-- ===========================================================================
-- LEER Y GUARDAR LA VISIBILIDAD DE UN PERFIL (lo que toca la pantalla)
-- ===========================================================================
-- Fecha: 2026-10-08
-- Se aplica después de 2026-10-08_ventas_notas_archivos_resumen_por_visibilidad.sql.
--
-- La tabla seguridad.visibilidad_datos ya está y ya filtra; hasta ahora sólo se
-- podía tocar a mano con un INSERT. Esto es lo que le falta para que un
-- administrador la maneje desde la pantalla del perfil, donde ya configura los
-- permisos por menú.
--
-- NO HAY PANTALLA NUEVA a propósito: una ruta nueva en este CRM necesita su
-- programa y su menú creados, y sin eso cae en el 404 aunque el componente esté
-- bien. Va dentro del perfil, que además es donde tiene sentido buscarlo.
--
-- LOS CUATRO ALCANCES SE GUARDAN SIEMPRE, también los que valen TODO. Guardar
-- sólo lo apretado dejaría la tabla más corta pero la pantalla no podría
-- distinguir «aquí nadie ha decidido nada» de «aquí alguien decidió que se vea
-- todo», y en una tabla de seguridad esa diferencia se acaba necesitando.
--
-- LA AUDITORÍA ES LA DE LA CASA: los tres disparadores de siempre, y el
-- contexto (app.usuario_login, app.datos_anteriores) puesto como lo hace
-- fn_perfiles_modificar. Quién aflojó la visibilidad de un perfil y cuándo es
-- exactamente lo que se va a querer saber algún día.
--
-- Idempotente.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- 1. Los disparadores que llevan las demás tablas de seguridad
-- ---------------------------------------------------------------------------
DROP TRIGGER IF EXISTS trigger_visibilidad_datos_set_users  ON seguridad.visibilidad_datos;
DROP TRIGGER IF EXISTS trigger_visibilidad_datos_updated_at ON seguridad.visibilidad_datos;
DROP TRIGGER IF EXISTS trg_visibilidad_datos_audit          ON seguridad.visibilidad_datos;

CREATE TRIGGER trigger_visibilidad_datos_set_users
    BEFORE INSERT OR UPDATE ON seguridad.visibilidad_datos
    FOR EACH ROW EXECUTE FUNCTION auditoria.fn_set_audit_users();

CREATE TRIGGER trigger_visibilidad_datos_updated_at
    BEFORE UPDATE ON seguridad.visibilidad_datos
    FOR EACH ROW EXECUTE FUNCTION auditoria.fn_update_updated_at_column();

CREATE TRIGGER trg_visibilidad_datos_audit
    AFTER INSERT OR UPDATE OR DELETE ON seguridad.visibilidad_datos
    FOR EACH ROW EXECUTE FUNCTION auditoria.fn_auditar_cambios();


-- ---------------------------------------------------------------------------
-- 2. Leer la de un perfil
-- ---------------------------------------------------------------------------
-- Devuelve SIEMPRE los cuatro datos, con TODO en los que no tienen fila, para
-- que la pantalla no tenga que saber nada de filas que faltan.
CREATE OR REPLACE FUNCTION seguridad.fn_visibilidad_datos_obtener(p_perfil_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
AS $function$
DECLARE
    v_data jsonb;
BEGIN
    SELECT jsonb_object_agg(d.dato, COALESCE(v.alcance, 'TODO'))
      INTO v_data
      FROM (VALUES ('GESTION'), ('NOTA'), ('ARCHIVO'), ('WHATSAPP')) AS d(dato)
      LEFT JOIN seguridad.visibilidad_datos v
             ON v.perfil_id = p_perfil_id AND v.dato = d.dato;

    RETURN jsonb_build_object('success', true,
                              'message', 'Visibilidad obtenida exitosamente',
                              'data', COALESCE(v_data, '{}'::jsonb));
EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object('success', false,
                                  'message', 'Error al obtener la visibilidad: ' || SQLERRM,
                                  'error_code', SQLSTATE);
END;
$function$;

COMMENT ON FUNCTION seguridad.fn_visibilidad_datos_obtener(bigint)
    IS 'Los cuatro alcances de un perfil, con TODO donde no hay fila';


-- ---------------------------------------------------------------------------
-- 3. Guardarla
-- ---------------------------------------------------------------------------
-- p_visibilidad es un objeto {"GESTION":"PROPIO","NOTA":"TODO",...}. Lo que no
-- venga se deja como está: así la pantalla puede mandar sólo lo que cambió sin
-- aflojar sin querer el resto.
--
-- UN DATO O UN ALCANCE QUE NO EXISTE REVIENTA, no se ignora: en seguridad,
-- tragarse en silencio un «PROPIOO» mal escrito significa dejar el alcance en
-- TODO y que nadie se entere.
CREATE OR REPLACE FUNCTION seguridad.fn_visibilidad_datos_guardar(
    p_perfil_id      bigint,
    p_visibilidad    jsonb,
    p_usuario_id     bigint,
    p_usuario_login  character varying,
    p_usuario_nombre character varying,
    p_ip_address     inet,
    p_user_agent     text,
    p_request_id     uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
    v_dato       text;
    v_alcance    text;
    v_anteriores jsonb;
    v_tocados    int := 0;
BEGIN
    IF p_perfil_id IS NULL OR NOT EXISTS (SELECT 1 FROM seguridad.perfiles WHERE id = p_perfil_id) THEN
        RETURN jsonb_build_object('success', false, 'message', 'El perfil no existe');
    END IF;

    IF p_visibilidad IS NULL OR jsonb_typeof(p_visibilidad) <> 'object' THEN
        RETURN jsonb_build_object('success', false, 'message', 'No se recibió la visibilidad a guardar');
    END IF;

    -- Contexto de auditoría, igual que fn_perfiles_modificar
    PERFORM set_config('app.usuario_id',     COALESCE(p_usuario_id::text, ''), true);
    PERFORM set_config('app.usuario_login',  COALESCE(p_usuario_login, current_user), true);
    PERFORM set_config('app.usuario_nombre', COALESCE(p_usuario_nombre, current_user), true);
    PERFORM set_config('app.ip_address',     COALESCE(p_ip_address::text, ''), true);
    PERFORM set_config('app.user_agent',     COALESCE(p_user_agent, ''), true);
    PERFORM set_config('app.request_id',     COALESCE(p_request_id::text, ''), true);
    PERFORM set_config('app.modulo',         'seguridad.visibilidad_datos', true);

    -- Cómo estaba antes, para el registro
    v_anteriores := (seguridad.fn_visibilidad_datos_obtener(p_perfil_id)) -> 'data';
    PERFORM set_config('app.datos_anteriores',
                       jsonb_build_object('perfil_id', p_perfil_id,
                                          'visibilidad', v_anteriores)::text, true);

    FOR v_dato, v_alcance IN SELECT key, value FROM jsonb_each_text(p_visibilidad) LOOP
        v_dato    := UPPER(TRIM(v_dato));
        v_alcance := UPPER(TRIM(COALESCE(v_alcance, '')));

        IF v_dato NOT IN ('GESTION', 'NOTA', 'ARCHIVO', 'WHATSAPP') THEN
            RAISE EXCEPTION 'No existe el dato %', v_dato USING ERRCODE = 'P0002';
        END IF;

        IF v_alcance NOT IN ('PROPIO', 'MI_PERFIL', 'A_CARGO', 'TODO') THEN
            RAISE EXCEPTION 'No existe el alcance % para %', v_alcance, v_dato USING ERRCODE = 'P0002';
        END IF;

        INSERT INTO seguridad.visibilidad_datos (perfil_id, dato, alcance)
             VALUES (p_perfil_id, v_dato, v_alcance)
        ON CONFLICT (perfil_id, dato)
        DO UPDATE SET alcance = EXCLUDED.alcance;

        v_tocados := v_tocados + 1;
    END LOOP;

    RETURN jsonb_build_object(
        'success', true,
        'message', 'Visibilidad guardada exitosamente',
        'data', jsonb_build_object(
            'perfil_id',   p_perfil_id,
            'guardados',   v_tocados,
            'visibilidad', (seguridad.fn_visibilidad_datos_obtener(p_perfil_id)) -> 'data'
        )
    );
EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object('success', false,
                                  'message', 'Error al guardar la visibilidad: ' || SQLERRM,
                                  'error_code', SQLSTATE);
END;
$function$;

COMMENT ON FUNCTION seguridad.fn_visibilidad_datos_guardar(bigint, jsonb, bigint, character varying, character varying, inet, text, uuid)
    IS 'Guarda los alcances de un perfil. Lo que no venga en el jsonb se deja como estaba';


-- ---------------------------------------------------------------------------
-- COMPROBACIÓN
-- ---------------------------------------------------------------------------
--   SELECT seguridad.fn_visibilidad_datos_obtener(1);
--   -- y un guardado de prueba, dentro de una transacción que se deshaga:
--   BEGIN;
--     SELECT seguridad.fn_visibilidad_datos_guardar(1, '{"GESTION":"A_CARGO"}'::jsonb,
--            NULL, 'PRUEBA', 'PRUEBA', NULL, NULL, NULL);
--   ROLLBACK;
