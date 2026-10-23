-- ===========================================================================
-- CARGOS: FILTROS DE COLUMNA EN EL SERVIDOR
-- ===========================================================================
-- La rejilla de cargos pagina, así que ag-Grid sólo tiene las filas de la
-- página: filtrar en el navegador buscaría dentro de quince. El filtro de
-- cada cabecera llega aquí en `p_filtros` y se aplica sobre la tabla entera,
-- igual que en marcas, clientes y empleados.
--
-- `p_filtros` es {columna: {op, valor}} YA NORMALIZADO por el trait
-- FiltrosDeColumna de PHP, que además tira todo lo que no esté en su lista
-- blanca. Las tres listas —pantalla, controlador y este fichero— tienen que
-- decir lo mismo: una columna que sólo esté en la pantalla pinta un filtro
-- que no filtra.
--
-- De paso, lo que está en la papelera desaparece del listado y de los combos.
\set ON_ERROR_STOP on

BEGIN;

-- El tercer parámetro deja de ser el último: hay que tirar la versión de tres
-- para que no queden las dos y la llamada salga ambigua.
DROP FUNCTION IF EXISTS rh.fn_cargos_listar_paginado(integer, integer, text);

CREATE OR REPLACE FUNCTION rh.fn_cargos_listar_paginado(
    p_page     integer DEFAULT 1,
    p_per_page integer DEFAULT 15,
    p_search   text    DEFAULT ''::text,
    p_filtros  jsonb   DEFAULT '{}'::jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'rh', 'ventas'
AS $function$
DECLARE
    v_offset integer;
    v_total  bigint;
    v_data   jsonb;
    v_filtro text;
BEGIN
    v_offset := (GREATEST(p_page, 1) - 1) * GREATEST(p_per_page, 1);
    v_filtro := NULLIF(TRIM(COALESCE(p_search, '')), '');

    WITH filtrados AS (
        SELECT c.id,
               -- Los empleados VIGENTES que lo usan: es el número que pinta la
               -- columna y el que decide si se puede enviar a la papelera, así
               -- que uno en la papelera no debe hacerlo parecer ocupado.
               (SELECT COUNT(*) FROM rh.empleados e
                 WHERE e.cargo_id = c.id AND e.deleted_at IS NULL) AS num_empleados
          FROM rh.cargos c
         WHERE c.deleted_at IS NULL          -- lo de la papelera no sale
           AND (v_filtro IS NULL
                OR c.nombre      ILIKE '%' || v_filtro || '%'
                OR c.descripcion ILIKE '%' || v_filtro || '%'
                OR c.nivel       ILIKE '%' || v_filtro || '%'
                OR c.id::text    ILIKE '%' || v_filtro || '%')

           -- ---------- LOS FILTROS DE LA CABECERA ----------
           AND (p_filtros->'id'           IS NULL OR ventas.fn_filtro_numero(c.id,           p_filtros->'id'))
           AND (p_filtros->'nombre'       IS NULL OR ventas.fn_filtro_texto(c.nombre,        p_filtros->'nombre'))
           AND (p_filtros->'nivel'        IS NULL OR ventas.fn_filtro_texto(c.nivel,         p_filtros->'nivel'))
           AND (p_filtros->'descripcion'  IS NULL OR ventas.fn_filtro_texto(c.descripcion,   p_filtros->'descripcion'))
           AND (p_filtros->'salario_base' IS NULL OR ventas.fn_filtro_numero(c.salario_base, p_filtros->'salario_base'))
           -- El contador: el mismo subselect que pinta la columna
           AND (p_filtros->'num_empleados' IS NULL OR ventas.fn_filtro_numero(
                   (SELECT COUNT(*) FROM rh.empleados e
                     WHERE e.cargo_id = c.id AND e.deleted_at IS NULL),
                   p_filtros->'num_empleados'))
           AND (p_filtros->'created_by'   IS NULL OR ventas.fn_filtro_texto(c.created_by,    p_filtros->'created_by'))
           AND (p_filtros->'updated_by'   IS NULL OR ventas.fn_filtro_texto(c.updated_by,    p_filtros->'updated_by'))
           -- Las fechas, como texto sobre lo que se ve: «2026-10» busca el mes
           AND (p_filtros->'created_at'   IS NULL OR ventas.fn_filtro_texto(
                   to_char(c.created_at, 'YYYY-MM-DD HH24:MI:SS'), p_filtros->'created_at'))
           AND (p_filtros->'updated_at'   IS NULL OR ventas.fn_filtro_texto(
                   to_char(c.updated_at, 'YYYY-MM-DD HH24:MI:SS'), p_filtros->'updated_at'))
    )
    SELECT COUNT(*),
           COALESCE((SELECT jsonb_agg(
               jsonb_build_object(
                   'id',            c.id,
                   'nombre',        c.nombre,
                   'descripcion',   c.descripcion,
                   'nivel',         c.nivel,
                   'salario_base',  c.salario_base,
                   'activo',        c.activo,
                   'num_empleados', t.num_empleados,
                   'created_by',    c.created_by,
                   'updated_by',    c.updated_by,
                   'created_at',    to_char(c.created_at, 'YYYY-MM-DD HH24:MI:SS'),
                   'updated_at',    to_char(c.updated_at, 'YYYY-MM-DD HH24:MI:SS')
               ) ORDER BY c.id DESC)
                       FROM (SELECT f.id, f.num_empleados FROM filtrados f
                              ORDER BY f.id DESC
                              LIMIT GREATEST(p_per_page, 1) OFFSET v_offset) t
                       JOIN rh.cargos c ON c.id = t.id), '[]'::jsonb)
      INTO v_total, v_data
      FROM filtrados;

    RETURN jsonb_build_object(
        'data', v_data,
        'meta', jsonb_build_object(
            'total',        v_total,
            'per_page',     GREATEST(p_per_page, 1),
            'current_page', GREATEST(p_page, 1),
            'last_page',    CASE WHEN v_total = 0 THEN 1
                                 ELSE ceil(v_total::numeric / GREATEST(p_per_page, 1)) END
        )
    );

EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object('success', false, 'message', 'Error al listar cargos: ' || SQLERRM, 'error_code', SQLSTATE);
END;
$function$;

CREATE OR REPLACE FUNCTION rh.fn_cargos_listar(p_solo_activos boolean DEFAULT true)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    v_data jsonb;
BEGIN
    SELECT COALESCE(jsonb_agg(
        jsonb_build_object(
            'id', c.id, 'nombre', c.nombre, 'nivel', c.nivel,
            'salario_base', c.salario_base, 'activo', c.activo
        ) ORDER BY c.nombre
    ), '[]'::jsonb) INTO v_data
    FROM rh.cargos c
    WHERE c.deleted_at IS NULL                    -- lo de la papelera no se puede elegir
      AND (NOT p_solo_activos OR c.activo);

    RETURN jsonb_build_object('success', true, 'message', 'Cargos obtenidos exitosamente', 'data', v_data);
EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object('success', false, 'message', 'Error al listar cargos: ' || SQLERRM, 'error_code', SQLSTATE);
END;
$function$

;

CREATE OR REPLACE FUNCTION rh.fn_cargos_crear(p_nombre character varying, p_descripcion text DEFAULT NULL::text, p_nivel character varying DEFAULT NULL::character varying, p_salario_base numeric DEFAULT NULL::numeric, p_activo boolean DEFAULT true, p_usuario_id bigint DEFAULT NULL::bigint, p_usuario_login character varying DEFAULT NULL::character varying, p_usuario_nombre character varying DEFAULT NULL::character varying, p_ip_address inet DEFAULT NULL::inet, p_user_agent text DEFAULT NULL::text, p_request_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'rh', 'auditoria'
AS $function$
DECLARE
    v_id           bigint;
    v_fecha        timestamptz := CURRENT_TIMESTAMP;
    v_datos_nuevos jsonb;
    v_resultado    jsonb;
BEGIN
    -- 1. Contexto de auditoría (lo leen los triggers de rh.cargos)
    PERFORM set_config('app.usuario_id',     COALESCE(p_usuario_id::text, ''), true);
    PERFORM set_config('app.usuario_login',  COALESCE(p_usuario_login, current_user), true);
    PERFORM set_config('app.usuario_nombre', COALESCE(p_usuario_nombre, current_user), true);
    PERFORM set_config('app.ip_address',     COALESCE(p_ip_address::text, ''), true);
    PERFORM set_config('app.user_agent',     COALESCE(p_user_agent, ''), true);
    PERFORM set_config('app.request_id',     COALESCE(p_request_id::text, ''), true);
    PERFORM set_config('app.modulo',         'rh.cargos', true);

    -- 2. Reglas
    IF p_nombre IS NULL OR length(TRIM(p_nombre)) < 3 THEN
        RAISE EXCEPTION 'El nombre del cargo es obligatorio (mínimo 3 caracteres)' USING ERRCODE = 'P0001';
    END IF;
    IF p_salario_base IS NOT NULL AND p_salario_base < 0 THEN
        RAISE EXCEPTION 'El salario base no puede ser negativo' USING ERRCODE = 'P0015';
    END IF;
    -- Mensaje claro; la unicidad la garantiza uk_cargos_nombre (unique_violation más abajo)
    -- `deleted_at IS NULL`: un cargo en la papelera NO reserva su nombre.
    -- Si no, borrarlo dejaría el nombre inservible sin entrar a la papelera,
    -- y el índice único ya es parcial.
    IF EXISTS (SELECT 1 FROM rh.cargos WHERE UPPER(nombre) = UPPER(TRIM(p_nombre)) AND deleted_at IS NULL) THEN
        RAISE EXCEPTION 'Ya existe un cargo con ese nombre' USING ERRCODE = 'P0006';
    END IF;

    -- 3. Datos NUEVOS para la auditoría (antes del INSERT: el trigger AFTER los lee del contexto)
    v_datos_nuevos := jsonb_build_object(
        'nombre',       TRIM(p_nombre),
        'descripcion',  NULLIF(TRIM(COALESCE(p_descripcion, '')), ''),
        'nivel',        NULLIF(TRIM(COALESCE(p_nivel, '')), ''),
        'salario_base', p_salario_base,
        'activo',       COALESCE(p_activo, true),
        'created_by',   p_usuario_login,
        'created_at',   to_char(v_fecha, 'YYYY-MM-DD HH24:MI:SS'),
        'updated_by',   p_usuario_login,
        'updated_at',   to_char(v_fecha, 'YYYY-MM-DD HH24:MI:SS')
    );
    PERFORM set_config('app.datos_nuevos', v_datos_nuevos::text, true);

    -- 4. Insertar
    INSERT INTO rh.cargos (nombre, descripcion, nivel, salario_base, activo, created_by, updated_by, created_at, updated_at)
    VALUES (
        TRIM(p_nombre),
        NULLIF(TRIM(COALESCE(p_descripcion, '')), ''),
        NULLIF(TRIM(COALESCE(p_nivel, '')), ''),
        p_salario_base,
        COALESCE(p_activo, true),
        p_usuario_login, p_usuario_login, v_fecha, v_fecha
    )
    RETURNING id INTO v_id;

    PERFORM set_config('app.datos_nuevos', '', true);

    -- 5. Devolver el cargo creado
    SELECT jsonb_build_object(
        'success', true,
        'message', 'Cargo creado exitosamente',
        'data', (rh.fn_cargos_obtener(v_id))->'data'
    ) INTO v_resultado;

    RETURN v_resultado;

EXCEPTION
    -- Único caso capturado, y se RE-LANZA: manda el índice único. Nunca un «WHEN OTHERS».
    WHEN unique_violation THEN
        RAISE EXCEPTION 'Ya existe un cargo con ese nombre' USING ERRCODE = 'P0006';
END;
$function$

;

CREATE OR REPLACE FUNCTION rh.fn_cargos_modificar(p_id bigint, p_nombre character varying, p_descripcion text DEFAULT NULL::text, p_nivel character varying DEFAULT NULL::character varying, p_salario_base numeric DEFAULT NULL::numeric, p_activo boolean DEFAULT true, p_usuario_id bigint DEFAULT NULL::bigint, p_usuario_login character varying DEFAULT NULL::character varying, p_usuario_nombre character varying DEFAULT NULL::character varying, p_ip_address inet DEFAULT NULL::inet, p_user_agent text DEFAULT NULL::text, p_request_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'rh', 'auditoria'
AS $function$
DECLARE
    v_actual           rh.cargos%ROWTYPE;
    v_fecha            timestamptz := CURRENT_TIMESTAMP;
    v_datos_anteriores jsonb;
    v_datos_nuevos     jsonb;
BEGIN
    -- 1. Contexto de auditoría
    PERFORM set_config('app.usuario_id',     COALESCE(p_usuario_id::text, ''), true);
    PERFORM set_config('app.usuario_login',  COALESCE(p_usuario_login, current_user), true);
    PERFORM set_config('app.usuario_nombre', COALESCE(p_usuario_nombre, current_user), true);
    PERFORM set_config('app.ip_address',     COALESCE(p_ip_address::text, ''), true);
    PERFORM set_config('app.user_agent',     COALESCE(p_user_agent, ''), true);
    PERFORM set_config('app.request_id',     COALESCE(p_request_id::text, ''), true);
    PERFORM set_config('app.modulo',         'rh.cargos', true);

    -- 2. Datos actuales
    SELECT * INTO v_actual FROM rh.cargos WHERE id = p_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'El cargo no existe' USING ERRCODE = 'P0013';
    END IF;
    -- Lo que está en la papelera no se edita: se restaura primero
    IF v_actual.deleted_at IS NOT NULL THEN
        RAISE EXCEPTION 'Ese cargo está en la papelera de reciclaje: restáurelo antes de modificarlo' USING ERRCODE = 'P0019';
    END IF;

    -- 3. Reglas
    IF p_nombre IS NULL OR length(TRIM(p_nombre)) < 3 THEN
        RAISE EXCEPTION 'El nombre del cargo es obligatorio (mínimo 3 caracteres)' USING ERRCODE = 'P0001';
    END IF;
    IF p_salario_base IS NOT NULL AND p_salario_base < 0 THEN
        RAISE EXCEPTION 'El salario base no puede ser negativo' USING ERRCODE = 'P0015';
    END IF;
    IF EXISTS (SELECT 1 FROM rh.cargos WHERE UPPER(nombre) = UPPER(TRIM(p_nombre)) AND id <> p_id AND deleted_at IS NULL) THEN
        RAISE EXCEPTION 'Ya existe otro cargo con ese nombre' USING ERRCODE = 'P0006';
    END IF;

    -- 4. Antes / después para la auditoría
    v_datos_anteriores := jsonb_build_object(
        'id', v_actual.id, 'nombre', v_actual.nombre, 'descripcion', v_actual.descripcion,
        'nivel', v_actual.nivel, 'salario_base', v_actual.salario_base, 'activo', v_actual.activo,
        'created_by', v_actual.created_by, 'created_at', to_char(v_actual.created_at, 'YYYY-MM-DD HH24:MI:SS'),
        'updated_by', v_actual.updated_by, 'updated_at', to_char(v_actual.updated_at, 'YYYY-MM-DD HH24:MI:SS')
    );
    v_datos_nuevos := jsonb_build_object(
        'id', v_actual.id,
        'nombre',       TRIM(p_nombre),
        'descripcion',  NULLIF(TRIM(COALESCE(p_descripcion, '')), ''),
        'nivel',        NULLIF(TRIM(COALESCE(p_nivel, '')), ''),
        'salario_base', p_salario_base,
        'activo',       COALESCE(p_activo, true),
        'created_by', v_actual.created_by, 'created_at', to_char(v_actual.created_at, 'YYYY-MM-DD HH24:MI:SS'),
        'updated_by', p_usuario_login, 'updated_at', to_char(v_fecha, 'YYYY-MM-DD HH24:MI:SS')
    );
    PERFORM set_config('app.datos_anteriores', v_datos_anteriores::text, true);
    PERFORM set_config('app.datos_nuevos',     v_datos_nuevos::text, true);

    -- 5. Actualizar
    UPDATE rh.cargos
       SET nombre       = TRIM(p_nombre),
           descripcion  = NULLIF(TRIM(COALESCE(p_descripcion, '')), ''),
           nivel        = NULLIF(TRIM(COALESCE(p_nivel, '')), ''),
           salario_base = p_salario_base,
           activo       = COALESCE(p_activo, true),
           updated_by   = p_usuario_login,
           updated_at   = v_fecha
     WHERE id = p_id;

    PERFORM set_config('app.datos_anteriores', '', true);
    PERFORM set_config('app.datos_nuevos', '', true);

    RETURN jsonb_build_object(
        'success', true,
        'message', 'Cargo actualizado exitosamente',
        'data', (rh.fn_cargos_obtener(p_id))->'data'
    );

EXCEPTION
    WHEN unique_violation THEN
        RAISE EXCEPTION 'Ya existe otro cargo con ese nombre' USING ERRCODE = 'P0006';
END;
$function$

;

CREATE OR REPLACE FUNCTION rh.fn_cargos_activar(p_id bigint, p_activo boolean DEFAULT NULL::boolean, p_usuario_id bigint DEFAULT NULL::bigint, p_usuario_login character varying DEFAULT NULL::character varying, p_usuario_nombre character varying DEFAULT NULL::character varying, p_ip_address inet DEFAULT NULL::inet, p_user_agent text DEFAULT NULL::text, p_request_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'rh', 'auditoria'
AS $function$
DECLARE
    v_antes      boolean;
    v_nuevo      boolean;
    v_updated_by varchar;
    v_updated_at text;
BEGIN
    PERFORM rh.fn_contexto_auditoria('rh.cargos', p_usuario_id, p_usuario_login,
                                     p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    -- `deleted_at IS NULL`: para la casilla, un cargo en la papelera no existe
    SELECT activo INTO v_antes FROM rh.cargos WHERE id = p_id AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'error_code', 'NO_EXISTE',
                                  'message', 'El cargo no existe');
    END IF;

    v_nuevo := COALESCE(p_activo, NOT COALESCE(v_antes, true));

    IF v_nuevo IS NOT DISTINCT FROM v_antes THEN
        SELECT updated_by, to_char(updated_at, 'YYYY-MM-DD HH24:MI:SS')
          INTO v_updated_by, v_updated_at FROM rh.cargos WHERE id = p_id;
        RETURN jsonb_build_object('success', true,
            'message', CASE WHEN v_nuevo THEN 'El cargo ya estaba activo' ELSE 'El cargo ya estaba inactivo' END,
            'data', jsonb_build_object('id', p_id, 'activo', v_nuevo,
                                       'updated_by', v_updated_by, 'updated_at', v_updated_at));
    END IF;

    PERFORM set_config('app.datos_anteriores', jsonb_build_object('id', p_id, 'activo', v_antes)::text, true);
    PERFORM set_config('app.datos_nuevos',     jsonb_build_object('id', p_id, 'activo', v_nuevo)::text, true);

    UPDATE rh.cargos SET activo = v_nuevo WHERE id = p_id
    RETURNING activo, updated_by, to_char(updated_at, 'YYYY-MM-DD HH24:MI:SS')
         INTO v_nuevo, v_updated_by, v_updated_at;

    PERFORM set_config('app.datos_anteriores', '', true);
    PERFORM set_config('app.datos_nuevos', '', true);

    RETURN jsonb_build_object('success', true,
        'message', CASE WHEN v_nuevo THEN 'Cargo activado' ELSE 'Cargo desactivado' END,
        'data', jsonb_build_object('id', p_id, 'activo', v_nuevo,
                                   'updated_by', v_updated_by, 'updated_at', v_updated_at));

EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false, 'error_code', 'ERROR',
                              'message', 'No se pudo cambiar el estado del cargo: ' || SQLERRM);
END;
$function$

;

COMMIT;
