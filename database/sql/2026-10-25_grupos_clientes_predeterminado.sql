-- ===========================================================================
-- EL GRUPO PREDETERMINADO (ventas.grupos_clientes.predeterminado)
-- ===========================================================================
-- En la ficha del cliente el grupo pasa a ser OBLIGATORIO, y para que nadie
-- tenga que elegirlo cada vez, uno de los grupos es el predeterminado: es el
-- que la ficha trae puesto al crear un cliente.
--
-- SÓLO PUEDE HABER UNO, y eso lo garantiza un índice único parcial, no el
-- código. Dos personas marcándolo a la vez pasarían las dos por cualquier
-- comprobación escrita en plpgsql.
--
-- Mientras lo sea, ese grupo no se puede desactivar ni mandar a la papelera:
-- sería dejar la ficha del cliente apuntando a algo que no se puede elegir.
\set ON_ERROR_STOP on

BEGIN;
-- ---------------------------------------------------------------------------
-- 1. LA COLUMNA
-- ---------------------------------------------------------------------------
ALTER TABLE ventas.grupos_clientes
  ADD COLUMN IF NOT EXISTS predeterminado boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN ventas.grupos_clientes.predeterminado IS
  'El que la ficha de un cliente nuevo trae puesto. Sólo puede haber uno (uq_grupos_clientes_predeterminado)';

-- UNO Y SÓLO UNO. El índice es único sobre una columna que sólo puede valer
-- `true` en las filas que entran, así que dos predeterminados no caben. Se
-- deja fuera la papelera: un grupo borrado no se ofrece a nadie.
--
-- Es un índice y no una comprobación en el código a propósito: si dos
-- personas marcan a la vez, el código las deja pasar a las dos y acabaríamos
-- con dos predeterminados; el índice no.
CREATE UNIQUE INDEX IF NOT EXISTS uq_grupos_clientes_predeterminado
    ON ventas.grupos_clientes (predeterminado)
 WHERE predeterminado AND deleted_at IS NULL;
-- ---------------------------------------------------------------------------
-- 2. LA FICHA DEL GRUPO
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ventas.fn_grupos_clientes_json(p_id bigint)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
AS $function$
    WITH RECURSIVE subida AS (
        SELECT g.id, g.padre_id, g.nombre, 0 AS salto
          FROM ventas.grupos_clientes g WHERE g.id = p_id
        UNION ALL
        SELECT p.id, p.padre_id, p.nombre, s.salto + 1
          FROM ventas.grupos_clientes p JOIN subida s ON p.id = s.padre_id
    )
    SELECT jsonb_build_object(
        'id',           g.id,
        'padre_id',     g.padre_id,
        'padre_nombre', (SELECT x.nombre FROM ventas.grupos_clientes x WHERE x.id = g.padre_id),
        'orden',        g.orden,
        'nivel',        g.nivel,
        'nombre',       g.nombre,
        'ruta',         (SELECT string_agg(s.nombre, ' > ' ORDER BY s.salto DESC) FROM subida s),
        'descripcion',  g.descripcion,
        'icono',        g.icono,
        'activo',       g.activo,
        -- El que la ficha de un cliente nuevo trae puesto; sólo hay uno
        'predeterminado', g.predeterminado,

        -- Lo que tiene puesto ESTE grupo: es lo único editable en su ficha
        'forma_pago',     g.forma_pago,
        'limite_credito', g.limite_credito,
        'dias_credito',   g.dias_credito,
        'descuento',      g.descuento,
        -- Y lo que se usaría de verdad, con su procedencia
        'condiciones',    ventas.fn_grupos_clientes_condiciones(g.id),

        'num_hijos',    (SELECT COUNT(*) FROM ventas.grupos_clientes h
                          WHERE h.padre_id = g.id AND h.deleted_at IS NULL),
        -- Clientes que lo usan: con alguno, el grupo no se borra
        'num_clientes', (SELECT COUNT(*) FROM ventas.clientes c
                          WHERE c.grupo_cliente_id = g.id AND c.deleted_at IS NULL),

        'deleted_at',   to_char(g.deleted_at, 'YYYY-MM-DD HH24:MI:SS'),
        'deleted_by',   g.deleted_by,
        'created_by',   g.created_by,
        'updated_by',   g.updated_by,
        'created_at',   to_char(g.created_at, 'YYYY-MM-DD HH24:MI:SS'),
        'updated_at',   to_char(g.updated_at, 'YYYY-MM-DD HH24:MI:SS')
    )
      FROM ventas.grupos_clientes g
     WHERE g.id = p_id;
$function$
;

-- ---------------------------------------------------------------------------
-- 3. MARCAR EL PREDETERMINADO
-- ---------------------------------------------------------------------------
-- Como `activar`: se manda el valor que se quiere y no «lo contrario de lo
-- que hay», para que dos personas pulsando a la vez acaben donde querían.
--
-- Poner uno QUITA EL ANTERIOR, en dos pasos: el índice único comprueba fila a
-- fila, así que primero se baja el que estaba y luego se sube el nuevo.
CREATE OR REPLACE FUNCTION ventas.fn_grupos_clientes_predeterminar(
    p_id bigint,
    p_valor boolean DEFAULT NULL::boolean,
    p_usuario_id bigint DEFAULT NULL::bigint,
    p_usuario_login character varying DEFAULT NULL::character varying,
    p_usuario_nombre character varying DEFAULT NULL::character varying,
    p_ip_address inet DEFAULT NULL::inet,
    p_user_agent text DEFAULT NULL::text,
    p_request_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'ventas', 'auditoria'
AS $function$
DECLARE
    v_antes    boolean;
    v_activo   boolean;
    v_borrado  timestamptz;
    v_nombre   varchar;
    v_nuevo    boolean;
    v_anterior varchar;
BEGIN
    PERFORM ventas.fn_contexto_auditoria('ventas.grupos_clientes',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    SELECT predeterminado, activo, deleted_at, nombre
      INTO v_antes, v_activo, v_borrado, v_nombre
      FROM ventas.grupos_clientes WHERE id = p_id;
    IF v_nombre IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error_code', 'NO_EXISTE', 'message', 'El grupo no existe');
    END IF;
    IF v_borrado IS NOT NULL THEN
        RETURN jsonb_build_object('success', false, 'error_code', 'EN_PAPELERA',
                                  'message', 'Ese grupo está en la papelera de reciclaje');
    END IF;

    v_nuevo := COALESCE(p_valor, NOT v_antes);

    -- Uno inactivo no se ofrece en ninguna parte: de predeterminado no
    -- serviría más que para que la ficha del cliente saliera con un grupo que
    -- no se puede elegir.
    IF v_nuevo AND NOT v_activo THEN
        RETURN jsonb_build_object('success', false, 'error_code', 'INACTIVO',
                                  'message', format('«%s» está inactivo: actívelo antes de dejarlo como predeterminado', v_nombre));
    END IF;

    IF v_nuevo IS NOT DISTINCT FROM v_antes THEN
        RETURN jsonb_build_object('success', true,
            'message', CASE WHEN v_nuevo THEN format('«%s» ya era el predeterminado', v_nombre)
                            ELSE format('«%s» no era el predeterminado', v_nombre) END,
            'data', ventas.fn_grupos_clientes_json(p_id));
    END IF;

    IF v_nuevo THEN
        -- Primero baja el que estuviera, que para eso sólo puede haber uno
        SELECT nombre INTO v_anterior
          FROM ventas.grupos_clientes WHERE predeterminado AND deleted_at IS NULL AND id <> p_id;
        UPDATE ventas.grupos_clientes SET predeterminado = false
         WHERE predeterminado AND id <> p_id;
    END IF;

    PERFORM set_config('app.datos_anteriores', jsonb_build_object('id', p_id, 'predeterminado', v_antes)::text, true);
    PERFORM set_config('app.datos_nuevos',     jsonb_build_object('id', p_id, 'predeterminado', v_nuevo)::text, true);

    UPDATE ventas.grupos_clientes SET predeterminado = v_nuevo WHERE id = p_id;

    PERFORM set_config('app.datos_anteriores', '', true);
    PERFORM set_config('app.datos_nuevos', '', true);

    RETURN jsonb_build_object('success', true,
        'message', CASE
            WHEN v_nuevo AND v_anterior IS NOT NULL
                 THEN format('«%s» es ahora el predeterminado, en lugar de «%s»', v_nombre, v_anterior)
            WHEN v_nuevo THEN format('«%s» es ahora el grupo predeterminado', v_nombre)
            ELSE format('«%s» ya no es el predeterminado: los clientes nuevos saldrán sin grupo', v_nombre) END,
        'data', ventas.fn_grupos_clientes_json(p_id));

EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false, 'error_code', 'ERROR',
                              'message', 'No se pudo marcar el predeterminado: ' || SQLERRM);
END;
$function$;
-- ---------------------------------------------------------------------------
-- 4. NI SE DESACTIVA NI SE BORRA MIENTRAS LO SEA
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ventas.fn_grupos_clientes_activar(p_id bigint, p_activo boolean DEFAULT NULL::boolean, p_usuario_id bigint DEFAULT NULL::bigint, p_usuario_login character varying DEFAULT NULL::character varying, p_usuario_nombre character varying DEFAULT NULL::character varying, p_ip_address inet DEFAULT NULL::inet, p_user_agent text DEFAULT NULL::text, p_request_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'ventas', 'auditoria'
AS $function$
DECLARE
    v_antes      boolean;
    v_nuevo      boolean;
    v_updated_by varchar;
    v_updated_at text;
BEGIN
    PERFORM ventas.fn_contexto_auditoria('ventas.grupos_clientes',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    SELECT activo INTO v_antes FROM ventas.grupos_clientes WHERE id = p_id;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'error_code', 'NO_EXISTE', 'message', 'El grupo no existe');
    END IF;

    v_nuevo := COALESCE(p_activo, NOT v_antes);

    -- EL PREDETERMINADO NO SE DESACTIVA. Es el que la ficha de un cliente
    -- nuevo trae puesto: dejarlo inactivo sería ofrecer un grupo que después
    -- no se puede elegir. Primero se marca otro.
    IF NOT v_nuevo AND (SELECT predeterminado FROM ventas.grupos_clientes WHERE id = p_id) THEN
        RETURN jsonb_build_object('success', false, 'error_code', 'PREDETERMINADO',
            'message', 'Es el grupo predeterminado: marque otro como predeterminado antes de desactivarlo');
    END IF;

    IF v_nuevo IS NOT DISTINCT FROM v_antes THEN
        SELECT updated_by, to_char(updated_at, 'YYYY-MM-DD HH24:MI:SS')
          INTO v_updated_by, v_updated_at FROM ventas.grupos_clientes WHERE id = p_id;
        RETURN jsonb_build_object('success', true,
            'message', CASE WHEN v_nuevo THEN 'El grupo ya estaba activo' ELSE 'El grupo ya estaba inactivo' END,
            'data', jsonb_build_object('id', p_id, 'activo', v_nuevo,
                                       'updated_by', v_updated_by, 'updated_at', v_updated_at));
    END IF;

    PERFORM set_config('app.datos_anteriores', jsonb_build_object('id', p_id, 'activo', v_antes)::text, true);
    PERFORM set_config('app.datos_nuevos',     jsonb_build_object('id', p_id, 'activo', v_nuevo)::text, true);

    UPDATE ventas.grupos_clientes SET activo = v_nuevo WHERE id = p_id
    RETURNING activo, updated_by, to_char(updated_at, 'YYYY-MM-DD HH24:MI:SS')
         INTO v_nuevo, v_updated_by, v_updated_at;

    PERFORM set_config('app.datos_anteriores', '', true);
    PERFORM set_config('app.datos_nuevos', '', true);

    RETURN jsonb_build_object('success', true,
        'message', CASE WHEN v_nuevo THEN 'Grupo activado' ELSE 'Grupo desactivado' END,
        'data', jsonb_build_object('id', p_id, 'activo', v_nuevo,
                                   'updated_by', v_updated_by, 'updated_at', v_updated_at));

EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false, 'error_code', 'ERROR',
                              'message', 'No se pudo cambiar el estado del grupo: ' || SQLERRM);
END;
$function$
;

CREATE OR REPLACE FUNCTION ventas.fn_grupos_clientes_eliminar(p_id bigint, p_usuario_id bigint DEFAULT NULL::bigint, p_usuario_login character varying DEFAULT NULL::character varying, p_usuario_nombre character varying DEFAULT NULL::character varying, p_ip_address inet DEFAULT NULL::inet, p_user_agent text DEFAULT NULL::text, p_request_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'ventas', 'auditoria'
AS $function$
DECLARE
    v_actual   record;
    v_existe   boolean;
    v_antes    jsonb;
    v_hijos    bigint;
    v_clientes bigint;
    v_fecha    timestamptz := CURRENT_TIMESTAMP;
    v_i        integer := 0;
    v_fila     record;
BEGIN
    PERFORM ventas.fn_contexto_auditoria('ventas.grupos_clientes',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    SELECT id, nombre, padre_id, deleted_at INTO v_actual
      FROM ventas.grupos_clientes WHERE id = p_id;
    -- En dos pasos: si no hay fila, `v_actual` es un record sin asignar y
    -- mencionarlo en la misma condición lo haría estallar con un 55000
    v_existe := FOUND;

    IF NOT v_existe THEN
        RAISE EXCEPTION 'El grupo no existe' USING ERRCODE = 'P0013';
    END IF;
    IF v_actual.deleted_at IS NOT NULL THEN
        RAISE EXCEPTION 'El grupo no existe' USING ERRCODE = 'P0013';
    END IF;

    SELECT COUNT(*) INTO v_hijos
      FROM ventas.grupos_clientes WHERE padre_id = p_id AND deleted_at IS NULL;
    IF v_hijos > 0 THEN
        RAISE EXCEPTION 'No se puede eliminar: el grupo tiene % subgrupo(s). Muévalos o bórrelos primero.', v_hijos
            USING ERRCODE = 'P0014';
    END IF;

    -- Y con clientes dentro tampoco: se quedarían sin sus condiciones
    SELECT COUNT(*) INTO v_clientes
      FROM ventas.clientes WHERE grupo_cliente_id = p_id AND deleted_at IS NULL;
    IF v_clientes > 0 THEN
        RAISE EXCEPTION 'No se puede eliminar: el grupo tiene % cliente(s). Cámbielos de grupo primero.', v_clientes
            USING ERRCODE = 'P0014';
    END IF;

    -- Y el predeterminado tampoco se va a la papelera: es el que la ficha de
    -- un cliente nuevo trae puesto.
    IF (SELECT predeterminado FROM ventas.grupos_clientes WHERE id = p_id) THEN
        RAISE EXCEPTION 'No se puede eliminar: es el grupo predeterminado. Marque otro como predeterminado primero.'
            USING ERRCODE = 'P0014';
    END IF;

    v_antes := ventas.fn_grupos_clientes_json(p_id);
    PERFORM set_config('app.datos_anteriores', v_antes::text, true);
    PERFORM set_config('app.datos_nuevos', (v_antes || jsonb_build_object(
        'deleted_at', to_char(v_fecha, 'YYYY-MM-DD HH24:MI:SS'), 'deleted_by', p_usuario_login
    ))::text, true);

    UPDATE ventas.grupos_clientes
       SET deleted_at = v_fecha,
           deleted_by = p_usuario_login,
           updated_by = COALESCE(p_usuario_login, updated_by),
           updated_at = v_fecha
     WHERE id = p_id;

    PERFORM set_config('app.datos_anteriores', '', true);
    PERFORM set_config('app.datos_nuevos', '', true);

    -- Los hermanos que quedan se renumeran sin huecos
    FOR v_fila IN
        SELECT id FROM ventas.grupos_clientes
         WHERE padre_id IS NOT DISTINCT FROM v_actual.padre_id
           AND deleted_at IS NULL
         ORDER BY orden, nombre
    LOOP
        v_i := v_i + 1;
        UPDATE ventas.grupos_clientes SET orden = v_i WHERE id = v_fila.id AND orden IS DISTINCT FROM v_i;
    END LOOP;

    RETURN jsonb_build_object(
        'success', true,
        'message', format('Grupo «%s» enviado a la papelera de reciclaje', v_actual.nombre),
        'data', ventas.fn_grupos_clientes_json(p_id)
    );
END;
$function$
;

-- ---------------------------------------------------------------------------
-- 5. EL PRIMER PREDETERMINADO
-- ---------------------------------------------------------------------------
-- «Minoristas»: efectivo, sin cupo, sin plazo y sin descuento, que es
-- exactamente lo que trae hoy la ficha de un cliente nuevo. Así, poner el
-- predeterminado no cambia lo que se venía guardando. Se cambia con un clic
-- en la pantalla de grupos.
UPDATE ventas.grupos_clientes SET predeterminado = true
 WHERE nombre = 'Minoristas' AND deleted_at IS NULL AND activo
   AND NOT EXISTS (SELECT 1 FROM ventas.grupos_clientes WHERE predeterminado AND deleted_at IS NULL);
COMMIT;
