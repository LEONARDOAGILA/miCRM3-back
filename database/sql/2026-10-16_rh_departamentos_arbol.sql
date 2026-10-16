-- ===========================================================================
-- DEPARTAMENTOS JERÁRQUICOS (árbol) + PAPELERA DE RECICLAJE
-- ===========================================================================
-- Fecha: 2026-10-16
-- Se aplica después de 2026-09-18_rh_departamentos_funciones.sql.
--
-- Los departamentos pasan a ser un ÁRBOL, como las categorías de inventario:
-- un departamento puede colgar de otro (Gerencia > Ventas > Postventa), con
-- cuatro niveles como mucho (0..3), y se arrastra para moverlo de rama o
-- cambiarle el orden. Y «eliminar» deja de borrar: manda a la papelera.
--
--   rh.departamentos.padre_id / nivel / orden            columnas nuevas
--   rh.departamentos.deleted_at / deleted_by             la papelera
--   rh.fn_contexto_auditoria(...)                        el mismo ayudante que inventarios
--   rh.fn_departamentos_json(id)                         la ficha, con ruta y contadores
--   rh.fn_departamentos_listar_arbol()                   el árbol entero, ya ordenado
--   rh.fn_departamentos_mover(id, padre, antes_de, ...)  arrastrar y soltar
--   rh.fn_departamentos_papelera_listar()                lo que hay en la papelera
--   rh.fn_departamentos_restaurar(ids, ...)              vuelven al árbol
--   rh.fn_departamentos_eliminar_definitivo(ids, ...)    DELETE real
--   rh.fn_departamentos_papelera_vaciar(...)             DELETE real de todo
--
-- LO QUE CAMBIA DE LO QUE YA HABÍA:
--
--   * `uk_departamentos_nombre` era único EN TODA LA TABLA. En un árbol eso
--     estorba: «Ventas» puede existir bajo Quito y bajo Guayaquil. Pasa a ser
--     único ENTRE HERMANOS, con los dos índices parciales de siempre (uno
--     para las raíces y otro para los hijos). El `codigo` sigue siendo único
--     en toda la tabla: es un código, no un nombre.
--   * fn_departamentos_crear y _modificar reciben `p_padre_id`, así que
--     cambia su firma y hay que soltarlas antes (CREATE OR REPLACE con otros
--     parámetros no reemplaza: crea una segunda con el mismo nombre).
--   * fn_departamentos_eliminar ya no borra: manda a la papelera, y exige que
--     el departamento esté vacío —sin subdepartamentos vigentes, sin
--     empleados y sin historial—, igual que exigía antes para borrar.
--   * Los listados (árbol, combo y el paginado que quedaba) no enseñan lo que
--     está en la papelera.
--
-- LOS 7 DEPARTAMENTOS QUE YA EXISTEN se quedan como están, todos en la raíz
-- (nivel 0) y ordenados por nombre. Nadie pierde nada: el árbol se construye
-- arrastrando desde la pantalla.
--
-- Error de negocio nuevo: P0019 el departamento no está en la papelera.
-- Idempotente: IF NOT EXISTS / CREATE OR REPLACE.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- 1. LAS COLUMNAS DEL ÁRBOL Y DE LA PAPELERA
-- ---------------------------------------------------------------------------
ALTER TABLE rh.departamentos ADD COLUMN IF NOT EXISTS padre_id   bigint;
ALTER TABLE rh.departamentos ADD COLUMN IF NOT EXISTS nivel      smallint NOT NULL DEFAULT 0;
ALTER TABLE rh.departamentos ADD COLUMN IF NOT EXISTS orden      integer  NOT NULL DEFAULT 0;
ALTER TABLE rh.departamentos ADD COLUMN IF NOT EXISTS deleted_at timestamptz;
ALTER TABLE rh.departamentos ADD COLUMN IF NOT EXISTS deleted_by varchar(100);

COMMENT ON COLUMN rh.departamentos.padre_id   IS 'Departamento del que cuelga; NULL en los de primer nivel';
COMMENT ON COLUMN rh.departamentos.nivel      IS 'Profundidad 0..3; la mantiene fn_departamentos_mover';
COMMENT ON COLUMN rh.departamentos.orden      IS 'Posición entre sus hermanos, 1..N sin huecos';
COMMENT ON COLUMN rh.departamentos.deleted_at IS 'Fecha en que se envió a la papelera de reciclaje (NULL = vigente)';
COMMENT ON COLUMN rh.departamentos.deleted_by IS 'Login de quien lo envió a la papelera';

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_departamentos_padre') THEN
        ALTER TABLE rh.departamentos
            ADD CONSTRAINT fk_departamentos_padre FOREIGN KEY (padre_id)
            REFERENCES rh.departamentos(id);
    END IF;
    -- El nivel no se deja a mano: lo calculan crear y mover
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'ck_departamentos_nivel') THEN
        ALTER TABLE rh.departamentos
            ADD CONSTRAINT ck_departamentos_nivel CHECK (nivel BETWEEN 0 AND 3);
    END IF;
END $$;

CREATE INDEX IF NOT EXISTS ix_departamentos_padre      ON rh.departamentos (padre_id);
CREATE INDEX IF NOT EXISTS ix_departamentos_deleted_at ON rh.departamentos (deleted_at) WHERE deleted_at IS NOT NULL;

-- El nombre, único ENTRE HERMANOS en vez de en toda la tabla
ALTER TABLE rh.departamentos DROP CONSTRAINT IF EXISTS uk_departamentos_nombre;
CREATE UNIQUE INDEX IF NOT EXISTS uq_departamentos_nombre_hermano
    ON rh.departamentos (padre_id, UPPER(TRIM(nombre)))
 WHERE padre_id IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS uq_departamentos_nombre_raiz
    ON rh.departamentos (UPPER(TRIM(nombre)))
 WHERE padre_id IS NULL;

-- Los que ya existen: todos a la raíz, ordenados por nombre y sin huecos
DO $$
DECLARE
    v_i    integer := 0;
    v_fila record;
BEGIN
    IF EXISTS (SELECT 1 FROM rh.departamentos WHERE orden = 0) THEN
        FOR v_fila IN SELECT id FROM rh.departamentos WHERE padre_id IS NULL ORDER BY nombre LOOP
            v_i := v_i + 1;
            UPDATE rh.departamentos SET orden = v_i WHERE id = v_fila.id;
        END LOOP;
        RAISE NOTICE 'Departamentos numerados en la raíz: %', v_i;
    END IF;
END $$;


-- ---------------------------------------------------------------------------
-- 2. EL CONTEXTO DE AUDITORÍA, COMO EN INVENTARIOS
--
-- Las funciones de rh repetían las siete líneas de set_config una por una.
-- Las nuevas usan este ayudante; las viejas se quedan como están.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION rh.fn_contexto_auditoria(
    p_modulo         text,
    p_usuario_id     bigint  DEFAULT NULL,
    p_usuario_login  varchar DEFAULT NULL,
    p_usuario_nombre varchar DEFAULT NULL,
    p_ip_address     inet    DEFAULT NULL,
    p_user_agent     text    DEFAULT NULL,
    p_request_id     uuid    DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
AS $function$
BEGIN
    PERFORM set_config('app.usuario_id',     COALESCE(p_usuario_id::text, ''), true);
    PERFORM set_config('app.usuario_login',  COALESCE(p_usuario_login, current_user), true);
    PERFORM set_config('app.usuario_nombre', COALESCE(p_usuario_nombre, current_user), true);
    PERFORM set_config('app.ip_address',     COALESCE(p_ip_address::text, ''), true);
    PERFORM set_config('app.user_agent',     COALESCE(p_user_agent, ''), true);
    PERFORM set_config('app.request_id',     COALESCE(p_request_id::text, ''), true);
    PERFORM set_config('app.modulo',         p_modulo, true);
END;
$function$;


-- ---------------------------------------------------------------------------
-- 3. LA FICHA
--
-- `ruta` es el camino completo («Gerencia > Ventas > Postventa»): fuera del
-- árbol, «Postventa» a secas no dice de quién cuelga.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION rh.fn_departamentos_json(p_id bigint)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
AS $function$
    WITH RECURSIVE subida AS (
        SELECT d.id, d.padre_id, d.nombre, 0 AS salto
          FROM rh.departamentos d WHERE d.id = p_id
        UNION ALL
        SELECT p.id, p.padre_id, p.nombre, s.salto + 1
          FROM rh.departamentos p JOIN subida s ON p.id = s.padre_id
    )
    SELECT jsonb_build_object(
        'id',            d.id,
        'padre_id',      d.padre_id,
        'padre_nombre',  (SELECT x.nombre FROM rh.departamentos x WHERE x.id = d.padre_id),
        'orden',         d.orden,
        'nivel',         d.nivel,
        'nombre',        d.nombre,
        'ruta',          (SELECT string_agg(s.nombre, ' > ' ORDER BY s.salto DESC) FROM subida s),
        'codigo',        d.codigo,
        'descripcion',   d.descripcion,
        'empleado_id',   d.empleado_id,
        'responsable',   (SELECT NULLIF(TRIM(CONCAT_WS(' ', e.nombres, e.apellidos)), '')
                            FROM rh.empleados e WHERE e.id = d.empleado_id),
        'activo',        d.activo,
        'num_hijos',     (SELECT COUNT(*) FROM rh.departamentos h WHERE h.padre_id = d.id AND h.deleted_at IS NULL),
        'num_empleados', (SELECT COUNT(*) FROM rh.empleados x WHERE x.departamento_id = d.id),
        -- La papelera: NULL mientras el departamento está vigente
        'deleted_at',    to_char(d.deleted_at, 'YYYY-MM-DD HH24:MI:SS'),
        'deleted_by',    d.deleted_by,

        'created_by',    d.created_by,
        'updated_by',    d.updated_by,
        'created_at',    to_char(d.created_at, 'YYYY-MM-DD HH24:MI:SS'),
        'updated_at',    to_char(d.updated_at, 'YYYY-MM-DD HH24:MI:SS')
    )
      FROM rh.departamentos d
     WHERE d.id = p_id;
$function$;


-- ---------------------------------------------------------------------------
-- 4. EL ÁRBOL ENTERO, YA ORDENADO PARA PINTARLO
--
-- El orden sale de una ruta de ordenamiento («00001.00003.00002») con el
-- `orden` de cada antepasado: así cada rama queda debajo de la suya.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION rh.fn_departamentos_listar_arbol(p_solo_activos boolean DEFAULT false)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'rh'
AS $function$
DECLARE
    v_data jsonb;
BEGIN
    WITH RECURSIVE arbol AS (
        SELECT d.id, d.padre_id, d.orden, d.activo,
               LPAD(d.orden::text, 5, '0') AS ruta_orden
          FROM rh.departamentos d
         WHERE d.padre_id IS NULL
           AND d.deleted_at IS NULL

        UNION ALL

        SELECT h.id, h.padre_id, h.orden, h.activo,
               a.ruta_orden || '.' || LPAD(h.orden::text, 5, '0')
          FROM rh.departamentos h
          JOIN arbol a ON h.padre_id = a.id
         WHERE h.deleted_at IS NULL
    )
    SELECT COALESCE(jsonb_agg(rh.fn_departamentos_json(a.id) ORDER BY a.ruta_orden), '[]'::jsonb)
      INTO v_data
      FROM arbol a
     WHERE NOT p_solo_activos OR a.activo;

    RETURN jsonb_build_object('success', true, 'data', v_data);

EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false, 'message', 'Error al listar el árbol de departamentos: ' || SQLERRM, 'error_code', SQLSTATE);
END;
$function$;


-- ---------------------------------------------------------------------------
-- 5. EL COMBO: con la ruta, y sin lo que está en la papelera
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION rh.fn_departamentos_listar(p_solo_activos boolean DEFAULT true)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
    v_data jsonb;
BEGIN
    SELECT COALESCE(jsonb_agg(
        jsonb_build_object('id', d.id, 'nombre', d.nombre, 'codigo', d.codigo, 'activo', d.activo,
                           'nivel', d.nivel,
                           -- El camino completo: en un combo, «Ventas» a secas
                           -- no distingue la de Quito de la de Guayaquil
                           'ruta', (rh.fn_departamentos_json(d.id))->>'ruta')
        ORDER BY d.nombre
    ), '[]'::jsonb) INTO v_data
    FROM rh.departamentos d
    WHERE d.deleted_at IS NULL
      AND (NOT p_solo_activos OR d.activo);

    RETURN jsonb_build_object('success', true, 'message', 'Departamentos obtenidos exitosamente', 'data', v_data);
EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object('success', false, 'message', 'Error al listar departamentos: ' || SQLERRM, 'error_code', SQLSTATE);
END;
$function$;


-- ---------------------------------------------------------------------------
-- 6. UNO SOLO (la ficha completa, con lo del árbol)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION rh.fn_departamentos_obtener(p_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
    v_data jsonb;
BEGIN
    v_data := rh.fn_departamentos_json(p_id);

    IF v_data IS NULL THEN
        RETURN jsonb_build_object('success', false, 'message', 'Departamento no encontrado',
                                  'error_code', 'DEPARTAMENTO_NOT_FOUND', 'data', null);
    END IF;
    RETURN jsonb_build_object('success', true, 'message', 'Departamento obtenido exitosamente', 'data', v_data);
EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object('success', false, 'message', 'Error al obtener el departamento: ' || SQLERRM, 'error_code', SQLSTATE);
END;
$function$;


-- ---------------------------------------------------------------------------
-- 7. ALTA (ahora con padre)
--
-- Cambia la firma, así que se suelta la función antes.
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS rh.fn_departamentos_crear(varchar, varchar, text, bigint, boolean, bigint, varchar, varchar, inet, text, uuid);

CREATE OR REPLACE FUNCTION rh.fn_departamentos_crear(
    p_nombre         varchar,
    p_codigo         varchar DEFAULT NULL,
    p_descripcion    text    DEFAULT NULL,
    p_empleado_id    bigint  DEFAULT NULL,
    p_activo         boolean DEFAULT true,
    p_padre_id       bigint  DEFAULT NULL,
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
    v_id           bigint;
    v_codigo       varchar;
    v_nivel        integer := 0;
    v_orden        integer;
    v_fecha        timestamptz := CURRENT_TIMESTAMP;
    v_datos_nuevos jsonb;
BEGIN
    PERFORM rh.fn_contexto_auditoria('rh.departamentos',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    v_codigo := NULLIF(UPPER(TRIM(COALESCE(p_codigo, ''))), '');

    IF p_nombre IS NULL OR length(TRIM(p_nombre)) < 3 THEN
        RAISE EXCEPTION 'El nombre del departamento es obligatorio (mínimo 3 caracteres)' USING ERRCODE = 'P0001';
    END IF;

    -- El padre tiene que existir y estar vigente; de él sale el nivel
    IF p_padre_id IS NOT NULL THEN
        SELECT nivel + 1 INTO v_nivel
          FROM rh.departamentos WHERE id = p_padre_id AND deleted_at IS NULL;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'El departamento padre no existe' USING ERRCODE = 'P0016';
        END IF;
        IF v_nivel > 3 THEN
            RAISE EXCEPTION 'El árbol de departamentos admite hasta cuatro niveles' USING ERRCODE = 'P0015';
        END IF;
    END IF;

    -- Entre hermanos el nombre no se repite; en otra rama sí puede
    IF EXISTS (SELECT 1 FROM rh.departamentos
                WHERE padre_id IS NOT DISTINCT FROM p_padre_id
                  AND UPPER(TRIM(nombre)) = UPPER(TRIM(p_nombre))) THEN
        -- Puede estar en la papelera: los índices únicos cuentan también a
        -- los eliminados, y sin decirlo el mensaje desconcierta porque ese
        -- nombre no aparece en el árbol.
        IF EXISTS (SELECT 1 FROM rh.departamentos
                    WHERE padre_id IS NOT DISTINCT FROM p_padre_id
                      AND UPPER(TRIM(nombre)) = UPPER(TRIM(p_nombre))
                      AND deleted_at IS NOT NULL) THEN
            RAISE EXCEPTION 'Ya existe un departamento con ese nombre en el mismo nivel, y está en la papelera de reciclaje' USING ERRCODE = 'P0006';
        END IF;
        RAISE EXCEPTION 'Ya existe un departamento con ese nombre en el mismo nivel' USING ERRCODE = 'P0006';
    END IF;

    IF v_codigo IS NOT NULL AND EXISTS (SELECT 1 FROM rh.departamentos WHERE codigo = v_codigo) THEN
        RAISE EXCEPTION 'Ya existe un departamento con el código %', v_codigo USING ERRCODE = 'P0016';
    END IF;
    IF p_empleado_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM rh.empleados WHERE id = p_empleado_id AND activo) THEN
        RAISE EXCEPTION 'El responsable seleccionado no existe o no está activo' USING ERRCODE = 'P0017';
    END IF;

    -- Al final de sus hermanos, sin pisar el orden de los que ya están
    SELECT COALESCE(MAX(orden), 0) + 1 INTO v_orden
      FROM rh.departamentos WHERE padre_id IS NOT DISTINCT FROM p_padre_id;

    v_datos_nuevos := jsonb_build_object(
        'nombre',      TRIM(p_nombre),
        'codigo',      v_codigo,
        'descripcion', NULLIF(TRIM(COALESCE(p_descripcion, '')), ''),
        'empleado_id', p_empleado_id,
        'padre_id',    p_padre_id,
        'nivel',       v_nivel,
        'orden',       v_orden,
        'activo',      COALESCE(p_activo, true),
        'created_by',  p_usuario_login, 'created_at', to_char(v_fecha, 'YYYY-MM-DD HH24:MI:SS'),
        'updated_by',  p_usuario_login, 'updated_at', to_char(v_fecha, 'YYYY-MM-DD HH24:MI:SS')
    );
    PERFORM set_config('app.datos_nuevos', v_datos_nuevos::text, true);

    INSERT INTO rh.departamentos (nombre, codigo, descripcion, empleado_id, padre_id, nivel, orden,
                                  activo, created_by, updated_by, created_at, updated_at)
    VALUES (TRIM(p_nombre), v_codigo, NULLIF(TRIM(COALESCE(p_descripcion, '')), ''), p_empleado_id,
            p_padre_id, v_nivel, v_orden, COALESCE(p_activo, true),
            p_usuario_login, p_usuario_login, v_fecha, v_fecha)
    RETURNING id INTO v_id;

    PERFORM set_config('app.datos_nuevos', '', true);

    RETURN jsonb_build_object('success', true, 'message', 'Departamento creado exitosamente',
                              'data', rh.fn_departamentos_json(v_id));
EXCEPTION
    WHEN unique_violation THEN
        RAISE EXCEPTION 'Ya existe un departamento con ese nombre en el mismo nivel o con ese código (puede estar en la papelera)' USING ERRCODE = 'P0006';
END;
$function$;


-- ---------------------------------------------------------------------------
-- 8. MODIFICAR (el padre se cambia arrastrando, no aquí)
--
-- Se admite `p_padre_id` para no perderlo si la pantalla lo manda, pero mover
-- de rama tiene su propia función: ahí es donde se recalculan niveles y
-- órdenes de toda la rama.
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS rh.fn_departamentos_modificar(bigint, varchar, varchar, text, bigint, boolean, bigint, varchar, varchar, inet, text, uuid);

CREATE OR REPLACE FUNCTION rh.fn_departamentos_modificar(
    p_id             bigint,
    p_nombre         varchar,
    p_codigo         varchar DEFAULT NULL,
    p_descripcion    text    DEFAULT NULL,
    p_empleado_id    bigint  DEFAULT NULL,
    p_activo         boolean DEFAULT NULL,
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
    v_actual record;
    v_codigo varchar;
    v_antes  jsonb;
    v_fecha  timestamptz := CURRENT_TIMESTAMP;
BEGIN
    PERFORM rh.fn_contexto_auditoria('rh.departamentos',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    SELECT * INTO v_actual FROM rh.departamentos WHERE id = p_id;
    IF NOT FOUND OR v_actual.deleted_at IS NOT NULL THEN
        RAISE EXCEPTION 'El departamento no existe' USING ERRCODE = 'P0013';
    END IF;

    v_codigo := NULLIF(UPPER(TRIM(COALESCE(p_codigo, ''))), '');

    IF p_nombre IS NULL OR length(TRIM(p_nombre)) < 3 THEN
        RAISE EXCEPTION 'El nombre del departamento es obligatorio (mínimo 3 caracteres)' USING ERRCODE = 'P0001';
    END IF;
    IF EXISTS (SELECT 1 FROM rh.departamentos
                WHERE padre_id IS NOT DISTINCT FROM v_actual.padre_id
                  AND id <> p_id
                  AND UPPER(TRIM(nombre)) = UPPER(TRIM(p_nombre))) THEN
        RAISE EXCEPTION 'Ya existe otro departamento con ese nombre en el mismo nivel' USING ERRCODE = 'P0006';
    END IF;
    IF v_codigo IS NOT NULL AND EXISTS (SELECT 1 FROM rh.departamentos WHERE codigo = v_codigo AND id <> p_id) THEN
        RAISE EXCEPTION 'Ya existe un departamento con el código %', v_codigo USING ERRCODE = 'P0016';
    END IF;
    IF p_empleado_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM rh.empleados WHERE id = p_empleado_id AND activo) THEN
        RAISE EXCEPTION 'El responsable seleccionado no existe o no está activo' USING ERRCODE = 'P0017';
    END IF;

    v_antes := rh.fn_departamentos_json(p_id);
    PERFORM set_config('app.datos_anteriores', v_antes::text, true);
    PERFORM set_config('app.datos_nuevos', (v_antes || jsonb_build_object(
        'nombre',      TRIM(p_nombre),
        'codigo',      v_codigo,
        'descripcion', NULLIF(TRIM(COALESCE(p_descripcion, '')), ''),
        'empleado_id', p_empleado_id,
        'activo',      COALESCE(p_activo, v_actual.activo),
        'updated_by',  p_usuario_login,
        'updated_at',  to_char(v_fecha, 'YYYY-MM-DD HH24:MI:SS')
    ))::text, true);

    UPDATE rh.departamentos
       SET nombre      = TRIM(p_nombre),
           codigo      = v_codigo,
           descripcion = NULLIF(TRIM(COALESCE(p_descripcion, '')), ''),
           empleado_id = p_empleado_id,
           activo      = COALESCE(p_activo, activo),
           updated_by  = p_usuario_login,
           updated_at  = v_fecha
     WHERE id = p_id;

    PERFORM set_config('app.datos_anteriores', '', true);
    PERFORM set_config('app.datos_nuevos', '', true);

    RETURN jsonb_build_object('success', true, 'message', 'Departamento modificado exitosamente',
                              'data', rh.fn_departamentos_json(p_id));
EXCEPTION
    WHEN unique_violation THEN
        RAISE EXCEPTION 'Ya existe otro departamento con ese nombre en el mismo nivel o con ese código (puede estar en la papelera)' USING ERRCODE = 'P0006';
END;
$function$;


-- ---------------------------------------------------------------------------
-- 9. ELIMINAR = MANDAR A LA PAPELERA
--
-- Se mantienen las condiciones de antes (sin empleados y sin historial) y se
-- añade la del árbol: sin subdepartamentos vigentes. Lo que ya está en la
-- papelera no cuenta: no se ve en ningún sitio.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION rh.fn_departamentos_eliminar(
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
    v_actual    record;
    v_antes     jsonb;
    v_hijos     bigint;
    v_empleados bigint;
    v_historial bigint;
    v_fecha     timestamptz := CURRENT_TIMESTAMP;
    v_i         integer := 0;
    v_fila      record;
BEGIN
    PERFORM rh.fn_contexto_auditoria('rh.departamentos',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    SELECT id, nombre, padre_id, deleted_at INTO v_actual
      FROM rh.departamentos WHERE id = p_id;

    IF NOT FOUND OR v_actual.deleted_at IS NOT NULL THEN
        RAISE EXCEPTION 'El departamento no existe' USING ERRCODE = 'P0013';
    END IF;

    SELECT COUNT(*) INTO v_hijos
      FROM rh.departamentos WHERE padre_id = p_id AND deleted_at IS NULL;
    IF v_hijos > 0 THEN
        RAISE EXCEPTION 'No se puede eliminar: el departamento tiene % subdepartamento(s). Muévalos o bórrelos primero.', v_hijos
            USING ERRCODE = 'P0014';
    END IF;

    SELECT COUNT(*) INTO v_empleados FROM rh.empleados WHERE departamento_id = p_id;
    IF v_empleados > 0 THEN
        RAISE EXCEPTION 'No se puede eliminar: el departamento tiene % empleado(s). Muévalos a otro o desactívelo.', v_empleados
            USING ERRCODE = 'P0014';
    END IF;

    SELECT COUNT(*) INTO v_historial FROM rh.historial_cargos WHERE departamento_id = p_id;
    IF v_historial > 0 THEN
        RAISE EXCEPTION 'No se puede eliminar: el departamento tiene % registro(s) en el historial de cargos. Desactívelo en lugar de borrarlo.', v_historial
            USING ERRCODE = 'P0014';
    END IF;

    v_antes := rh.fn_departamentos_json(p_id);
    PERFORM set_config('app.datos_anteriores', v_antes::text, true);
    PERFORM set_config('app.datos_nuevos', (v_antes || jsonb_build_object(
        'deleted_at', to_char(v_fecha, 'YYYY-MM-DD HH24:MI:SS'), 'deleted_by', p_usuario_login
    ))::text, true);

    UPDATE rh.departamentos
       SET deleted_at = v_fecha,
           deleted_by = p_usuario_login,
           updated_by = COALESCE(p_usuario_login, updated_by),
           updated_at = v_fecha
     WHERE id = p_id;

    PERFORM set_config('app.datos_anteriores', '', true);
    PERFORM set_config('app.datos_nuevos', '', true);

    -- Los hermanos que quedan se renumeran sin huecos
    FOR v_fila IN
        SELECT id FROM rh.departamentos
         WHERE padre_id IS NOT DISTINCT FROM v_actual.padre_id
           AND deleted_at IS NULL
         ORDER BY orden, nombre
    LOOP
        v_i := v_i + 1;
        UPDATE rh.departamentos SET orden = v_i WHERE id = v_fila.id AND orden IS DISTINCT FROM v_i;
    END LOOP;

    RETURN jsonb_build_object(
        'success', true,
        'message', format('Departamento «%s» enviado a la papelera de reciclaje', v_actual.nombre),
        'data', rh.fn_departamentos_json(p_id)
    );
END;
$function$;


-- ---------------------------------------------------------------------------
-- 10. MOVER DE RAMA / CAMBIAR EL ORDEN (arrastrar y soltar)
--
-- Mismo algoritmo que inventarios.fn_categorias_mover: valida ciclos y nivel
-- máximo, recoloca al movido entre los hermanos del destino y renumera tanto
-- la rama nueva como la que deja atrás. Lo de la papelera no cuenta como
-- hermano: no se ve, y guardarle sitio dejaría huecos.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION rh.fn_departamentos_mover(
    p_id             bigint,
    p_padre_id       bigint  DEFAULT NULL,
    p_antes_de       bigint  DEFAULT NULL,
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
    v_padre_actual bigint;
    v_nivel_nuevo  integer;
    v_profundidad  integer;
    v_max_nivel    constant integer := 3;
    v_pos          integer;
    v_i            integer;
    v_fila         record;
BEGIN
    PERFORM rh.fn_contexto_auditoria('rh.departamentos',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    SELECT padre_id INTO v_padre_actual
      FROM rh.departamentos WHERE id = p_id AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'error_code', 'NO_EXISTE', 'message', 'El departamento no existe');
    END IF;

    IF p_padre_id IS NOT NULL THEN
        IF p_padre_id = p_id THEN
            RETURN jsonb_build_object('success', false, 'error_code', 'AUTOREFERENCIA',
                                      'message', 'Un departamento no puede estar dentro de sí mismo');
        END IF;
        -- Uno de la papelera no es un destino: no se ve en el árbol, y lo que
        -- colgara de él desaparecería con él.
        IF NOT EXISTS (SELECT 1 FROM rh.departamentos WHERE id = p_padre_id AND deleted_at IS NULL) THEN
            RETURN jsonb_build_object('success', false, 'error_code', 'PADRE_NO_EXISTE',
                                      'message', 'El departamento destino no existe');
        END IF;
        -- El destino no puede colgar del que se mueve (ciclo)
        IF EXISTS (
            WITH RECURSIVE d AS (
                SELECT id FROM rh.departamentos WHERE padre_id = p_id
                UNION ALL
                SELECT c.id FROM rh.departamentos c JOIN d ON c.padre_id = d.id
            )
            SELECT 1 FROM d WHERE d.id = p_padre_id
        ) THEN
            RETURN jsonb_build_object('success', false, 'error_code', 'CICLO',
                                      'message', 'No se puede mover un departamento dentro de uno de sus propios subdepartamentos');
        END IF;
        SELECT nivel + 1 INTO v_nivel_nuevo FROM rh.departamentos WHERE id = p_padre_id;
    ELSE
        v_nivel_nuevo := 0;
    END IF;

    -- Lo hondo que es la rama que se mueve (0 = sin hijos)
    WITH RECURSIVE d AS (
        SELECT id, 1 AS prof FROM rh.departamentos WHERE padre_id = p_id
        UNION ALL
        SELECT c.id, d.prof + 1 FROM rh.departamentos c JOIN d ON c.padre_id = d.id
    )
    SELECT COALESCE(MAX(prof), 0) INTO v_profundidad FROM d;

    IF v_nivel_nuevo + v_profundidad > v_max_nivel THEN
        RETURN jsonb_build_object('success', false, 'error_code', 'NIVEL_MAXIMO',
            'message', format('Ahí quedaría en el nivel %s y el árbol admite hasta el %s (lo que mueves tiene %s nivel(es) por debajo)',
                              v_nivel_nuevo + v_profundidad, v_max_nivel, v_profundidad));
    END IF;

    -- El nombre tampoco se puede repetir entre los hermanos NUEVOS
    IF EXISTS (SELECT 1 FROM rh.departamentos
                WHERE padre_id IS NOT DISTINCT FROM p_padre_id
                  AND id <> p_id
                  AND UPPER(TRIM(nombre)) = (SELECT UPPER(TRIM(nombre)) FROM rh.departamentos WHERE id = p_id)) THEN
        RETURN jsonb_build_object('success', false, 'error_code', 'NOMBRE_DUPLICADO',
                                  'message', 'Ahí ya hay un departamento con ese nombre');
    END IF;

    -- Padre y nivel; y el nivel de los descendientes, en cascada
    UPDATE rh.departamentos
       SET padre_id = p_padre_id, nivel = v_nivel_nuevo
     WHERE id = p_id
       AND (padre_id IS DISTINCT FROM p_padre_id OR nivel IS DISTINCT FROM v_nivel_nuevo);

    FOR v_fila IN
        WITH RECURSIVE d AS (
            SELECT id, v_nivel_nuevo + 1 AS nivel_ok FROM rh.departamentos WHERE padre_id = p_id
            UNION ALL
            SELECT c.id, d.nivel_ok + 1 FROM rh.departamentos c JOIN d ON c.padre_id = d.id
        )
        SELECT d.id, d.nivel_ok FROM d JOIN rh.departamentos c ON c.id = d.id
         WHERE c.nivel IS DISTINCT FROM d.nivel_ok
    LOOP
        UPDATE rh.departamentos SET nivel = v_fila.nivel_ok WHERE id = v_fila.id;
    END LOOP;

    -- Sitio entre los hermanos del destino: se saca el movido, se mete
    -- delante de p_antes_de (o al final) y se renumera 1..N
    CREATE TEMP TABLE IF NOT EXISTS tmp_dep_hermanos (id bigint, pos integer) ON COMMIT DROP;
    DELETE FROM tmp_dep_hermanos;

    INSERT INTO tmp_dep_hermanos (id, pos)
    SELECT id, ROW_NUMBER() OVER (ORDER BY orden, nombre)
      FROM rh.departamentos
     WHERE padre_id IS NOT DISTINCT FROM p_padre_id
       AND id <> p_id
       AND deleted_at IS NULL;

    IF p_antes_de IS NOT NULL AND p_antes_de <> p_id THEN
        SELECT pos INTO v_pos FROM tmp_dep_hermanos WHERE id = p_antes_de;
    END IF;
    IF v_pos IS NULL THEN
        SELECT COALESCE(MAX(pos), 0) + 1 INTO v_pos FROM tmp_dep_hermanos;
    END IF;

    UPDATE tmp_dep_hermanos SET pos = pos + 1 WHERE pos >= v_pos;
    INSERT INTO tmp_dep_hermanos (id, pos) VALUES (p_id, v_pos);

    v_i := 0;
    FOR v_fila IN SELECT id FROM tmp_dep_hermanos ORDER BY pos LOOP
        v_i := v_i + 1;
        UPDATE rh.departamentos SET orden = v_i WHERE id = v_fila.id AND orden IS DISTINCT FROM v_i;
    END LOOP;

    -- Y los hermanos que dejó atrás, sin huecos
    IF v_padre_actual IS DISTINCT FROM p_padre_id THEN
        v_i := 0;
        FOR v_fila IN
            SELECT id FROM rh.departamentos
             WHERE padre_id IS NOT DISTINCT FROM v_padre_actual
               AND deleted_at IS NULL
             ORDER BY orden, nombre
        LOOP
            v_i := v_i + 1;
            UPDATE rh.departamentos SET orden = v_i WHERE id = v_fila.id AND orden IS DISTINCT FROM v_i;
        END LOOP;
    END IF;

    RETURN jsonb_build_object(
        'success', true,
        'message', CASE WHEN v_padre_actual IS DISTINCT FROM p_padre_id THEN 'Departamento movido' ELSE 'Orden actualizado' END,
        'data', rh.fn_departamentos_json(p_id)
    );

EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false, 'error_code', SQLSTATE,
                              'message', 'Error al mover el departamento: ' || SQLERRM);
END;
$function$;


-- ---------------------------------------------------------------------------
-- 11. LA PAPELERA
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION rh.fn_departamentos_papelera_listar()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
AS $function$
DECLARE
    v_data jsonb;
BEGIN
    SELECT COALESCE(jsonb_agg(
               rh.fn_departamentos_json(d.id)
               -- `padre_en_papelera` evita que haya que adivinar por qué uno
               -- no se deja restaurar: la pantalla ya lo sabe.
               || jsonb_build_object('padre_en_papelera',
                      EXISTS (SELECT 1 FROM rh.departamentos p
                               WHERE p.id = d.padre_id AND p.deleted_at IS NOT NULL))
               ORDER BY d.deleted_at DESC, d.id DESC), '[]'::jsonb)
      INTO v_data
      FROM rh.departamentos d
     WHERE d.deleted_at IS NOT NULL;

    RETURN jsonb_build_object('success', true, 'data', v_data, 'total', jsonb_array_length(v_data));
EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object('success', false, 'message', 'Error al listar la papelera: ' || SQLERRM, 'error_code', SQLSTATE);
END;
$function$;


CREATE OR REPLACE FUNCTION rh.fn_departamentos_restaurar(
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
    v_d        record;
    v_antes    jsonb;
    v_n        integer := 0;
    v_colgados integer := 0;
    v_fecha    timestamptz := CURRENT_TIMESTAMP;
    v_nombres  text[] := '{}';
    v_padres   bigint[] := '{}';
    v_padre    bigint;
    v_i        integer;
    v_fila     record;
BEGIN
    PERFORM rh.fn_contexto_auditoria('rh.departamentos',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    IF p_ids IS NULL OR jsonb_typeof(p_ids) <> 'array' OR jsonb_array_length(p_ids) = 0 THEN
        RAISE EXCEPTION 'No se indicó ningún departamento' USING ERRCODE = 'P0001';
    END IF;

    -- De arriba abajo: si se restauran padre e hijo a la vez, el padre va
    -- primero y el hijo ya se encuentra con el sitio hecho
    FOR v_d IN
        SELECT d.id, d.nombre, d.padre_id, d.nivel
          FROM rh.departamentos d
         WHERE d.id IN (SELECT (x)::bigint FROM jsonb_array_elements_text(p_ids) x)
           AND d.deleted_at IS NOT NULL
         ORDER BY d.nivel, d.id
    LOOP
        IF v_d.padre_id IS NOT NULL
           AND EXISTS (SELECT 1 FROM rh.departamentos p
                        WHERE p.id = v_d.padre_id AND p.deleted_at IS NOT NULL) THEN
            v_colgados := v_colgados + 1;
            CONTINUE;
        END IF;

        v_antes := rh.fn_departamentos_json(v_d.id);
        PERFORM set_config('app.datos_anteriores', v_antes::text, true);
        PERFORM set_config('app.datos_nuevos', (v_antes || jsonb_build_object('deleted_at', NULL, 'deleted_by', NULL))::text, true);

        UPDATE rh.departamentos
           SET deleted_at = NULL, deleted_by = NULL,
               updated_by = COALESCE(p_usuario_login, updated_by), updated_at = v_fecha
         WHERE id = v_d.id;

        v_n := v_n + 1;
        v_nombres := v_nombres || v_d.nombre::text;
        -- Las raíces tienen `padre_id` NULL y un array no sabe compararlo:
        -- se guarda -1 en su lugar y se deshace el truco al renumerar.
        IF NOT (COALESCE(v_d.padre_id, -1) = ANY(v_padres)) THEN
            v_padres := v_padres || COALESCE(v_d.padre_id, -1);
        END IF;
    END LOOP;

    PERFORM set_config('app.datos_anteriores', '', true);
    PERFORM set_config('app.datos_nuevos', '', true);

    IF v_n = 0 THEN
        IF v_colgados > 0 THEN
            RAISE EXCEPTION 'No se puede restaurar: su departamento padre también está en la papelera. Restaure primero el de arriba.'
                USING ERRCODE = 'P0014';
        END IF;
        RAISE EXCEPTION 'Ninguno de esos departamentos está en la papelera' USING ERRCODE = 'P0019';
    END IF;

    -- Renumerar a los hermanos de cada rama tocada
    FOREACH v_padre IN ARRAY v_padres LOOP
        v_i := 0;
        FOR v_fila IN
            SELECT id FROM rh.departamentos
             WHERE padre_id IS NOT DISTINCT FROM NULLIF(v_padre, -1)
               AND deleted_at IS NULL
             ORDER BY orden, nombre
        LOOP
            v_i := v_i + 1;
            UPDATE rh.departamentos SET orden = v_i WHERE id = v_fila.id AND orden IS DISTINCT FROM v_i;
        END LOOP;
    END LOOP;

    RETURN jsonb_build_object(
        'success', true,
        'message', CASE WHEN v_n = 1 THEN format('Departamento «%s» restaurado', v_nombres[1])
                        ELSE format('%s departamentos restaurados', v_n) END
                 || CASE WHEN v_colgados > 0
                         THEN format('. %s se quedaron: su departamento padre sigue en la papelera', v_colgados)
                         ELSE '' END,
        'data', jsonb_build_object('restaurados', v_n, 'sin_padre', v_colgados, 'nombres', to_jsonb(v_nombres))
    );
END;
$function$;


CREATE OR REPLACE FUNCTION rh.fn_departamentos_eliminar_definitivo(
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
    v_d         record;
    v_n         integer := 0;
    v_hijos     bigint;
    v_empleados bigint;
    v_historial bigint;
    v_nombres   text[] := '{}';
BEGIN
    PERFORM rh.fn_contexto_auditoria('rh.departamentos',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    IF p_ids IS NULL OR jsonb_typeof(p_ids) <> 'array' OR jsonb_array_length(p_ids) = 0 THEN
        RAISE EXCEPTION 'No se indicó ningún departamento' USING ERRCODE = 'P0001';
    END IF;

    -- De lo más hondo a lo más alto: así, al vaciar la papelera entera, los
    -- hijos se van antes que sus padres y no choca la clave ajena
    FOR v_d IN
        SELECT d.id, d.nombre
          FROM rh.departamentos d
         WHERE d.id IN (SELECT (x)::bigint FROM jsonb_array_elements_text(p_ids) x)
           AND d.deleted_at IS NOT NULL
         ORDER BY d.nivel DESC, d.id DESC
    LOOP
        SELECT COUNT(*) INTO v_hijos FROM rh.departamentos WHERE padre_id = v_d.id;
        IF v_hijos > 0 THEN
            RAISE EXCEPTION 'No se puede eliminar «%» definitivamente: todavía tiene % subdepartamento(s), aunque estén en la papelera. Bórrelos primero.', v_d.nombre, v_hijos
                USING ERRCODE = 'P0014';
        END IF;

        SELECT COUNT(*) INTO v_empleados FROM rh.empleados WHERE departamento_id = v_d.id;
        IF v_empleados > 0 THEN
            RAISE EXCEPTION 'No se puede eliminar «%» definitivamente: tiene % empleado(s).', v_d.nombre, v_empleados
                USING ERRCODE = 'P0014';
        END IF;

        SELECT COUNT(*) INTO v_historial FROM rh.historial_cargos WHERE departamento_id = v_d.id;
        IF v_historial > 0 THEN
            RAISE EXCEPTION 'No se puede eliminar «%» definitivamente: tiene % registro(s) en el historial de cargos.', v_d.nombre, v_historial
                USING ERRCODE = 'P0014';
        END IF;

        -- La ficha entera a la auditoría: es lo único que no se puede volver
        -- a escribir de memoria si se borró por error
        PERFORM set_config('app.datos_anteriores', (rh.fn_departamentos_json(v_d.id))::text, true);
        DELETE FROM rh.departamentos WHERE id = v_d.id;

        v_n := v_n + 1;
        v_nombres := v_nombres || v_d.nombre::text;
    END LOOP;

    PERFORM set_config('app.datos_anteriores', '', true);

    IF v_n = 0 THEN
        RAISE EXCEPTION 'Ninguno de esos departamentos está en la papelera' USING ERRCODE = 'P0019';
    END IF;

    RETURN jsonb_build_object(
        'success', true,
        'message', CASE WHEN v_n = 1 THEN format('Departamento «%s» eliminado definitivamente', v_nombres[1])
                        ELSE format('%s departamentos eliminados definitivamente', v_n) END,
        'data', jsonb_build_object('borrados', v_n, 'nombres', to_jsonb(v_nombres))
    );

EXCEPTION
    WHEN foreign_key_violation THEN
        RAISE EXCEPTION 'No se puede eliminar definitivamente: algo sigue apuntando a ese departamento' USING ERRCODE = 'P0014';
END;
$function$;


CREATE OR REPLACE FUNCTION rh.fn_departamentos_papelera_vaciar(
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
    SELECT COALESCE(jsonb_agg(d.id), '[]'::jsonb) INTO v_ids
      FROM rh.departamentos d WHERE d.deleted_at IS NOT NULL;

    IF jsonb_array_length(v_ids) = 0 THEN
        RETURN jsonb_build_object('success', true, 'message', 'La papelera ya estaba vacía',
                                  'data', jsonb_build_object('borrados', 0, 'nombres', '[]'::jsonb));
    END IF;

    -- Se delega en eliminar_definitivo, que ya va de lo más hondo a lo más
    -- alto: dos sitios donde se borra de verdad acabarían divergiendo.
    RETURN rh.fn_departamentos_eliminar_definitivo(v_ids,
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);
END;
$function$;


-- ---------------------------------------------------------------------------
-- 12. PERMISOS Y COMENTARIOS
-- ---------------------------------------------------------------------------
ALTER FUNCTION rh.fn_contexto_auditoria(text, bigint, varchar, varchar, inet, text, uuid) OWNER TO postgres;
ALTER FUNCTION rh.fn_departamentos_json(bigint) OWNER TO postgres;
ALTER FUNCTION rh.fn_departamentos_listar_arbol(boolean) OWNER TO postgres;
ALTER FUNCTION rh.fn_departamentos_crear(varchar, varchar, text, bigint, boolean, bigint, bigint, varchar, varchar, inet, text, uuid) OWNER TO postgres;
ALTER FUNCTION rh.fn_departamentos_modificar(bigint, varchar, varchar, text, bigint, boolean, bigint, varchar, varchar, inet, text, uuid) OWNER TO postgres;
ALTER FUNCTION rh.fn_departamentos_mover(bigint, bigint, bigint, bigint, varchar, varchar, inet, text, uuid) OWNER TO postgres;
ALTER FUNCTION rh.fn_departamentos_papelera_listar() OWNER TO postgres;
ALTER FUNCTION rh.fn_departamentos_restaurar(jsonb, bigint, varchar, varchar, inet, text, uuid) OWNER TO postgres;
ALTER FUNCTION rh.fn_departamentos_eliminar_definitivo(jsonb, bigint, varchar, varchar, inet, text, uuid) OWNER TO postgres;
ALTER FUNCTION rh.fn_departamentos_papelera_vaciar(bigint, varchar, varchar, inet, text, uuid) OWNER TO postgres;

COMMENT ON FUNCTION rh.fn_departamentos_json(bigint) IS 'La ficha de un departamento: ruta completa, nivel, subdepartamentos y empleados';
COMMENT ON FUNCTION rh.fn_departamentos_listar_arbol(boolean) IS 'El árbol entero de departamentos, ordenado para pintarlo (rejilla allDepartamentos)';
COMMENT ON FUNCTION rh.fn_departamentos_mover(bigint, bigint, bigint, bigint, varchar, varchar, inet, text, uuid) IS 'Mueve un departamento de rama o cambia su orden (arrastrar y soltar)';
COMMENT ON FUNCTION rh.fn_departamentos_eliminar(bigint, bigint, varchar, varchar, inet, text, uuid) IS 'Envía el departamento a la papelera de reciclaje (borrado lógico)';
COMMENT ON FUNCTION rh.fn_departamentos_papelera_listar() IS 'Departamentos que están en la papelera; `padre_en_papelera` dice cuáles no se pueden restaurar todavía';
COMMENT ON FUNCTION rh.fn_departamentos_restaurar(jsonb, bigint, varchar, varchar, inet, text, uuid) IS 'Saca de la papelera uno o varios departamentos';
COMMENT ON FUNCTION rh.fn_departamentos_eliminar_definitivo(jsonb, bigint, varchar, varchar, inet, text, uuid) IS 'Borrado real de departamentos de la papelera, de lo más hondo a lo más alto';
COMMENT ON FUNCTION rh.fn_departamentos_papelera_vaciar(bigint, varchar, varchar, inet, text, uuid) IS 'Borrado real de todo lo que hay en la papelera de departamentos';


-- ---------------------------------------------------------------------------
-- 13. EL LISTADO PAGINADO QUE YA HABÍA: tampoco enseña la papelera
--
-- La pantalla pasa a usar el árbol, pero esta función sigue publicada y
-- devolvía también lo eliminado.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION rh.fn_departamentos_listar_paginado(
    p_page     integer DEFAULT 1,
    p_per_page integer DEFAULT 15,
    p_search   text    DEFAULT ''
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
    v_offset integer;
    v_total  bigint;
    v_data   jsonb;
    v_filtro text;
BEGIN
    v_offset := (GREATEST(p_page, 1) - 1) * p_per_page;
    v_filtro := NULLIF(TRIM(COALESCE(p_search, '')), '');

    SELECT COUNT(*) INTO v_total
      FROM rh.departamentos d
      LEFT JOIN rh.empleados e ON e.id = d.empleado_id
     WHERE d.deleted_at IS NULL      -- lo de la papelera no sale
       AND (v_filtro IS NULL
        OR d.nombre      ILIKE '%' || v_filtro || '%'
        OR d.codigo      ILIKE '%' || v_filtro || '%'
        OR d.descripcion ILIKE '%' || v_filtro || '%'
        OR CONCAT_WS(' ', e.nombres, e.apellidos) ILIKE '%' || v_filtro || '%'
        OR d.id::text    ILIKE '%' || v_filtro || '%');

    SELECT COALESCE(jsonb_agg(
        jsonb_build_object(
            'id',              t.id,
            'nombre',          t.nombre,
            'codigo',          t.codigo,
            'descripcion',     t.descripcion,
            'empleado_id',     t.empleado_id,
            'responsable',     t.responsable,
            'activo',          t.activo,
            'num_empleados',   t.num_empleados,
            'created_by',      t.created_by,
            'updated_by',      t.updated_by,
            'created_at',      to_char(t.created_at, 'YYYY-MM-DD HH24:MI:SS'),
            'updated_at',      to_char(t.updated_at, 'YYYY-MM-DD HH24:MI:SS')
        ) ORDER BY t.id DESC
    ), '[]'::jsonb) INTO v_data
    FROM (
        SELECT d.*,
               NULLIF(TRIM(CONCAT_WS(' ', e.nombres, e.apellidos)), '') AS responsable,
               (SELECT COUNT(*) FROM rh.empleados x WHERE x.departamento_id = d.id) AS num_empleados
          FROM rh.departamentos d
          LEFT JOIN rh.empleados e ON e.id = d.empleado_id
         WHERE d.deleted_at IS NULL
           AND (v_filtro IS NULL
            OR d.nombre      ILIKE '%' || v_filtro || '%'
            OR d.codigo      ILIKE '%' || v_filtro || '%'
            OR d.descripcion ILIKE '%' || v_filtro || '%'
            OR CONCAT_WS(' ', e.nombres, e.apellidos) ILIKE '%' || v_filtro || '%'
            OR d.id::text    ILIKE '%' || v_filtro || '%')
         ORDER BY d.id DESC
         LIMIT p_per_page OFFSET v_offset
    ) t;

    RETURN jsonb_build_object(
        'data', v_data,
        'meta', jsonb_build_object(
            'total',        v_total,
            'per_page',     p_per_page,
            'current_page', GREATEST(p_page, 1),
            'last_page',    CASE WHEN v_total = 0 THEN 1 ELSE ceil(v_total::numeric / p_per_page) END
        )
    );
EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object('success', false, 'message', 'Error al listar departamentos: ' || SQLERRM, 'error_code', SQLSTATE);
END;
$function$;
