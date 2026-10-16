-- ===========================================================================
-- PAPELERA DE RECICLAJE DE CATEGORÍAS (borrado lógico)
-- ===========================================================================
-- Fecha: 2026-10-15
-- Se aplica después de 2026-10-15_inventarios_productos_papelera.sql.
--
-- La misma papelera que usuarios, clientes y productos: «eliminar» una
-- categoría la manda a la papelera (deleted_at / deleted_by), desde donde se
-- restaura o se borra de verdad.
--
--   inventarios.categorias.deleted_at / deleted_by          columnas nuevas
--   inventarios.fn_categorias_eliminar(...)                 AHORA borrado lógico
--   inventarios.fn_categorias_papelera_listar()             lo que hay en la papelera
--   inventarios.fn_categorias_restaurar(ids, ...)           vuelven al árbol
--   inventarios.fn_categorias_eliminar_definitivo(ids, ...) DELETE real
--   inventarios.fn_categorias_papelera_vaciar(...)          DELETE real de todo
--
-- LO QUE TIENE DE PROPIO, POR SER UN ÁRBOL:
--
--   * Se sigue exigiendo que la categoría esté vacía para eliminarla, pero
--     ahora «vacía» quiere decir sin subcategorías NI productos VIGENTES: lo
--     que ya está en la papelera no estorba.
--   * Al restaurar se mira el padre. Si el padre también está en la papelera
--     la hija NO vuelve: colgaría de algo que no se ve. El mensaje lo dice y
--     se restaura primero el padre.
--   * El borrado definitivo exige que no le quede NADA debajo, ni siquiera en
--     la papelera, porque la clave ajena lo impediría igualmente. Vaciar la
--     papelera va de lo más hondo a lo más alto, así que se vacía entera.
--   * Al eliminar y al restaurar se renumera el `orden` de los hermanos
--     vigentes, para que no queden huecos ni empates.
--
-- EL ÁRBOL NO ENSEÑA LO ELIMINADO: se reescribe fn_categorias_listar (de ahí
-- salen la rejilla y los combos) y `num_hijos` deja de contarlo.
-- fn_categorias_json SÍ lo devuelve —de ahí saca sus datos la papelera— y
-- ahora trae deleted_at / deleted_by.
--
-- EL NOMBRE REPETIDO: los índices únicos de nombre entre hermanas cuentan
-- también a las eliminadas (como en clientes), así que crear y modificar
-- avisan de que el choque puede ser con algo que está en la papelera. Así
-- restaurar nunca falla por el nombre.
--
-- Error de negocio nuevo: P0019 la categoría no está en la papelera.
-- Idempotente: IF NOT EXISTS / CREATE OR REPLACE.
-- ===========================================================================

ALTER TABLE inventarios.categorias ADD COLUMN IF NOT EXISTS deleted_at timestamptz;
ALTER TABLE inventarios.categorias ADD COLUMN IF NOT EXISTS deleted_by varchar(100);
COMMENT ON COLUMN inventarios.categorias.deleted_at IS 'Fecha en que se envió a la papelera de reciclaje (NULL = vigente)';
COMMENT ON COLUMN inventarios.categorias.deleted_by IS 'Login de quien la envió a la papelera';
CREATE INDEX IF NOT EXISTS ix_categorias_deleted_at ON inventarios.categorias (deleted_at) WHERE deleted_at IS NOT NULL;


-- ---------------------------------------------------------------------------
-- LA FICHA, AHORA CON LOS DATOS DE LA PAPELERA
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION inventarios.fn_categorias_json(p_id bigint)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
AS $function$
    WITH RECURSIVE subida AS (
        SELECT c.id, c.padre_id, c.nombre, 0 AS salto
          FROM inventarios.categorias c WHERE c.id = p_id
        UNION ALL
        SELECT p.id, p.padre_id, p.nombre, s.salto + 1
          FROM inventarios.categorias p JOIN subida s ON p.id = s.padre_id
    )
    SELECT jsonb_build_object(
        'id',            c.id,
        'padre_id',      c.padre_id,
        'padre_nombre',  (SELECT x.nombre FROM inventarios.categorias x WHERE x.id = c.padre_id),
        'orden',         c.orden,
        'nivel',         c.nivel,
        'nombre',        c.nombre,
        'ruta',          (SELECT string_agg(s.nombre, ' > ' ORDER BY s.salto DESC) FROM subida s),
        'descripcion',   c.descripcion,
        'icono',         c.icono,
        'activo',        c.activo,
        'num_hijos',     (SELECT COUNT(*) FROM inventarios.categorias h WHERE h.padre_id = c.id AND h.deleted_at IS NULL),
        'num_productos', (SELECT COUNT(*) FROM inventarios.productos p WHERE p.categoria_id = c.id AND p.deleted_at IS NULL),
        -- La papelera: NULL mientras la categoría está vigente
        'deleted_at',    to_char(c.deleted_at, 'YYYY-MM-DD HH24:MI:SS'),
        'deleted_by',    c.deleted_by,

        'created_by',    c.created_by,
        'updated_by',    c.updated_by,
        'created_at',    to_char(c.created_at, 'YYYY-MM-DD HH24:MI:SS'),
        'updated_at',    to_char(c.updated_at, 'YYYY-MM-DD HH24:MI:SS')
    )
      FROM inventarios.categorias c
     WHERE c.id = p_id;
$function$;

-- ---------------------------------------------------------------------------
-- EL ÁRBOL: fuera lo que está en la papelera
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION inventarios.fn_categorias_listar(p_solo_activos boolean DEFAULT false)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'inventarios'
AS $function$
DECLARE
    v_data jsonb;
BEGIN
    WITH RECURSIVE arbol AS (
        SELECT c.id, c.padre_id, c.orden, c.activo,
               LPAD(c.orden::text, 5, '0') AS ruta_orden
          FROM inventarios.categorias c
         WHERE c.padre_id IS NULL
           AND c.deleted_at IS NULL

        UNION ALL

        SELECT h.id, h.padre_id, h.orden, h.activo,
               a.ruta_orden || '.' || LPAD(h.orden::text, 5, '0')
          FROM inventarios.categorias h
          JOIN arbol a ON h.padre_id = a.id
         WHERE h.deleted_at IS NULL
    )
    SELECT COALESCE(jsonb_agg(inventarios.fn_categorias_json(a.id) ORDER BY a.ruta_orden), '[]'::jsonb)
      INTO v_data
      FROM arbol a
     WHERE NOT p_solo_activos OR a.activo;

    RETURN jsonb_build_object('success', true, 'data', v_data);

EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false, 'message', 'Error al listar categorías: ' || SQLERRM, 'error_code', SQLSTATE);
END;
$function$;

-- ---------------------------------------------------------------------------
-- CREAR Y MODIFICAR: el nombre repetido puede estar en la papelera
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION inventarios.fn_categorias_crear(
    p_nombre         varchar,
    p_padre_id       bigint  DEFAULT NULL,
    p_descripcion    text    DEFAULT NULL,
    p_icono          varchar DEFAULT NULL,
    p_activo         boolean DEFAULT true,
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
SET search_path TO 'pg_catalog', 'inventarios', 'auditoria'
AS $function$
DECLARE
    v_id    bigint;
    v_nivel integer := 0;
    v_orden integer;
    v_nuevo jsonb;
BEGIN
    PERFORM inventarios.fn_contexto_auditoria('inventarios.categorias',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    IF p_nombre IS NULL OR length(TRIM(p_nombre)) < 2 THEN
        RAISE EXCEPTION 'El nombre de la categoría es obligatorio (mínimo 2 caracteres)' USING ERRCODE = 'P0001';
    END IF;

    IF p_padre_id IS NOT NULL THEN
        SELECT nivel + 1 INTO v_nivel FROM inventarios.categorias WHERE id = p_padre_id;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'La categoría padre no existe' USING ERRCODE = 'P0016';
        END IF;
        IF v_nivel > 3 THEN
            RAISE EXCEPTION 'El árbol admite hasta cuatro niveles (0 a 3) y ahí quedaría en el %', v_nivel
                USING ERRCODE = 'P0015';
        END IF;
    END IF;

    -- Entre hermanos el nombre no se repite; en otra rama sí puede
    IF EXISTS (SELECT 1 FROM inventarios.categorias
                WHERE padre_id IS NOT DISTINCT FROM p_padre_id
                  AND UPPER(TRIM(nombre)) = UPPER(TRIM(p_nombre))) THEN
        -- Puede estar en la papelera: el índice único también cuenta a las
        -- eliminadas, y sin decirlo el mensaje desconcierta porque ese
        -- nombre no aparece en el árbol.
        IF EXISTS (SELECT 1 FROM inventarios.categorias
                    WHERE padre_id IS NOT DISTINCT FROM p_padre_id
                      AND UPPER(TRIM(nombre)) = UPPER(TRIM(p_nombre))
                      AND deleted_at IS NOT NULL) THEN
            RAISE EXCEPTION 'Ya existe una categoría con ese nombre en el mismo nivel, y está en la papelera de reciclaje' USING ERRCODE = 'P0006';
        END IF;
        RAISE EXCEPTION 'Ya existe una categoría con ese nombre en el mismo nivel' USING ERRCODE = 'P0006';
    END IF;

    -- Al final de sus hermanos, sin pisar el orden de los que ya están
    SELECT COALESCE(MAX(orden), 0) + 1 INTO v_orden
      FROM inventarios.categorias WHERE padre_id IS NOT DISTINCT FROM p_padre_id;

    v_nuevo := jsonb_build_object(
        'padre_id',    p_padre_id,
        'nivel',       v_nivel,
        'orden',       v_orden,
        'nombre',      TRIM(p_nombre),
        'descripcion', NULLIF(TRIM(COALESCE(p_descripcion, '')), ''),
        'icono',       NULLIF(TRIM(COALESCE(p_icono, '')), ''),
        'activo',      COALESCE(p_activo, true)
    );
    PERFORM set_config('app.datos_nuevos', v_nuevo::text, true);

    INSERT INTO inventarios.categorias (padre_id, orden, nivel, nombre, descripcion, icono, activo)
    VALUES (
        p_padre_id, v_orden, v_nivel,
        TRIM(p_nombre),
        NULLIF(TRIM(COALESCE(p_descripcion, '')), ''),
        NULLIF(TRIM(COALESCE(p_icono, '')), ''),
        COALESCE(p_activo, true)
    )
    RETURNING id INTO v_id;

    PERFORM set_config('app.datos_nuevos', '', true);

    RETURN jsonb_build_object('success', true, 'message', 'Categoría creada exitosamente',
                              'data', inventarios.fn_categorias_json(v_id));

EXCEPTION
    WHEN unique_violation THEN
        RAISE EXCEPTION 'Ya existe una categoría con ese nombre en el mismo nivel' USING ERRCODE = 'P0006';
END;
$function$;

CREATE OR REPLACE FUNCTION inventarios.fn_categorias_modificar(
    p_id             bigint,
    p_nombre         varchar,
    p_descripcion    text    DEFAULT NULL,
    p_icono          varchar DEFAULT NULL,
    p_activo         boolean DEFAULT true,
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
SET search_path TO 'pg_catalog', 'inventarios', 'auditoria'
AS $function$
DECLARE
    v_antes  jsonb;
    v_padre  bigint;
    v_nuevo  jsonb;
BEGIN
    PERFORM inventarios.fn_contexto_auditoria('inventarios.categorias',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    SELECT padre_id INTO v_padre FROM inventarios.categorias WHERE id = p_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'La categoría no existe' USING ERRCODE = 'P0013';
    END IF;
    v_antes := inventarios.fn_categorias_json(p_id);

    IF p_nombre IS NULL OR length(TRIM(p_nombre)) < 2 THEN
        RAISE EXCEPTION 'El nombre de la categoría es obligatorio (mínimo 2 caracteres)' USING ERRCODE = 'P0001';
    END IF;
    IF EXISTS (SELECT 1 FROM inventarios.categorias
                WHERE padre_id IS NOT DISTINCT FROM v_padre
                  AND UPPER(TRIM(nombre)) = UPPER(TRIM(p_nombre))
                  AND id <> p_id) THEN
        RAISE EXCEPTION 'Ya existe otra categoría con ese nombre en el mismo nivel' USING ERRCODE = 'P0006';
    END IF;

    v_nuevo := jsonb_build_object(
        'nombre',      TRIM(p_nombre),
        'descripcion', NULLIF(TRIM(COALESCE(p_descripcion, '')), ''),
        'icono',       NULLIF(TRIM(COALESCE(p_icono, '')), ''),
        'activo',      COALESCE(p_activo, true)
    );
    PERFORM set_config('app.datos_anteriores',
        jsonb_build_object('nombre',      v_antes->>'nombre',
                           'descripcion', v_antes->>'descripcion',
                           'icono',       v_antes->>'icono',
                           'activo',      (v_antes->>'activo')::boolean)::text, true);
    PERFORM set_config('app.datos_nuevos', v_nuevo::text, true);

    UPDATE inventarios.categorias
       SET nombre      = TRIM(p_nombre),
           descripcion = NULLIF(TRIM(COALESCE(p_descripcion, '')), ''),
           icono       = NULLIF(TRIM(COALESCE(p_icono, '')), ''),
           activo      = COALESCE(p_activo, true)
     WHERE id = p_id;

    PERFORM set_config('app.datos_anteriores', '', true);
    PERFORM set_config('app.datos_nuevos', '', true);

    RETURN jsonb_build_object('success', true, 'message', 'Categoría actualizada exitosamente',
                              'data', inventarios.fn_categorias_json(p_id));

EXCEPTION
    WHEN unique_violation THEN
        -- El índice único cuenta también a las que están en la papelera
        RAISE EXCEPTION 'Ya existe otra categoría con ese nombre en el mismo nivel (puede estar en la papelera de reciclaje)' USING ERRCODE = 'P0006';
END;
$function$;

-- ---------------------------------------------------------------------------
-- MOVER: ni desde ni hacia la papelera
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION inventarios.fn_categorias_mover(
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
SET search_path TO 'pg_catalog', 'inventarios', 'auditoria'
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
    PERFORM inventarios.fn_contexto_auditoria('inventarios.categorias',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    SELECT padre_id INTO v_padre_actual FROM inventarios.categorias WHERE id = p_id;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'error_code', 'NO_EXISTE', 'message', 'La categoría no existe');
    END IF;

    IF p_padre_id IS NOT NULL THEN
        IF p_padre_id = p_id THEN
            RETURN jsonb_build_object('success', false, 'error_code', 'AUTOREFERENCIA',
                                      'message', 'Una categoría no puede estar dentro de sí misma');
        END IF;
        -- Una categoría de la papelera no es un destino: no se ve en el
        -- árbol, y lo que colgara de ella desaparecería con ella.
        IF NOT EXISTS (SELECT 1 FROM inventarios.categorias WHERE id = p_padre_id AND deleted_at IS NULL) THEN
            RETURN jsonb_build_object('success', false, 'error_code', 'PADRE_NO_EXISTE',
                                      'message', 'La categoría destino no existe');
        END IF;
        -- El destino no puede colgar de la que se mueve (ciclo)
        IF EXISTS (
            WITH RECURSIVE d AS (
                SELECT id FROM inventarios.categorias WHERE padre_id = p_id
                UNION ALL
                SELECT c.id FROM inventarios.categorias c JOIN d ON c.padre_id = d.id
            )
            SELECT 1 FROM d WHERE d.id = p_padre_id
        ) THEN
            RETURN jsonb_build_object('success', false, 'error_code', 'CICLO',
                                      'message', 'No se puede mover una categoría dentro de una de sus propias subcategorías');
        END IF;
        SELECT nivel + 1 INTO v_nivel_nuevo FROM inventarios.categorias WHERE id = p_padre_id;
    ELSE
        v_nivel_nuevo := 0;
    END IF;

    -- Lo hondo que es la rama que se mueve (0 = sin hijos)
    WITH RECURSIVE d AS (
        SELECT id, 1 AS prof FROM inventarios.categorias WHERE padre_id = p_id
        UNION ALL
        SELECT c.id, d.prof + 1 FROM inventarios.categorias c JOIN d ON c.padre_id = d.id
    )
    SELECT COALESCE(MAX(prof), 0) INTO v_profundidad FROM d;

    IF v_nivel_nuevo + v_profundidad > v_max_nivel THEN
        RETURN jsonb_build_object('success', false, 'error_code', 'NIVEL_MAXIMO',
            'message', format('Ahí quedaría en el nivel %s y el árbol admite hasta el %s (lo que mueves tiene %s nivel(es) por debajo)',
                              v_nivel_nuevo + v_profundidad, v_max_nivel, v_profundidad));
    END IF;

    -- El nombre tampoco se puede repetir entre los hermanos NUEVOS
    IF EXISTS (SELECT 1 FROM inventarios.categorias
                WHERE padre_id IS NOT DISTINCT FROM p_padre_id
                  AND id <> p_id
                  AND UPPER(TRIM(nombre)) = (SELECT UPPER(TRIM(nombre)) FROM inventarios.categorias WHERE id = p_id)) THEN
        RETURN jsonb_build_object('success', false, 'error_code', 'NOMBRE_DUPLICADO',
                                  'message', 'Ahí ya hay una categoría con ese nombre');
    END IF;

    -- Padre y nivel; y el nivel de los descendientes, en cascada
    UPDATE inventarios.categorias
       SET padre_id = p_padre_id, nivel = v_nivel_nuevo
     WHERE id = p_id
       AND (padre_id IS DISTINCT FROM p_padre_id OR nivel IS DISTINCT FROM v_nivel_nuevo);

    FOR v_fila IN
        WITH RECURSIVE d AS (
            SELECT id, v_nivel_nuevo + 1 AS nivel_ok FROM inventarios.categorias WHERE padre_id = p_id
            UNION ALL
            SELECT c.id, d.nivel_ok + 1 FROM inventarios.categorias c JOIN d ON c.padre_id = d.id
        )
        SELECT d.id, d.nivel_ok FROM d JOIN inventarios.categorias c ON c.id = d.id
         WHERE c.nivel IS DISTINCT FROM d.nivel_ok
    LOOP
        UPDATE inventarios.categorias SET nivel = v_fila.nivel_ok WHERE id = v_fila.id;
    END LOOP;

    -- Sitio entre los hermanos del destino: se saca el movido, se mete
    -- delante de p_antes_de (o al final) y se renumera 1..N
    CREATE TEMP TABLE IF NOT EXISTS tmp_cat_hermanos (id bigint, pos integer) ON COMMIT DROP;
    DELETE FROM tmp_cat_hermanos;

    INSERT INTO tmp_cat_hermanos (id, pos)
    SELECT id, ROW_NUMBER() OVER (ORDER BY orden, nombre)
      FROM inventarios.categorias
     WHERE padre_id IS NOT DISTINCT FROM p_padre_id AND id <> p_id;

    IF p_antes_de IS NOT NULL AND p_antes_de <> p_id THEN
        SELECT pos INTO v_pos FROM tmp_cat_hermanos WHERE id = p_antes_de;
    END IF;
    IF v_pos IS NULL THEN
        SELECT COALESCE(MAX(pos), 0) + 1 INTO v_pos FROM tmp_cat_hermanos;
    END IF;

    UPDATE tmp_cat_hermanos SET pos = pos + 1 WHERE pos >= v_pos;
    INSERT INTO tmp_cat_hermanos (id, pos) VALUES (p_id, v_pos);

    v_i := 0;
    FOR v_fila IN SELECT id FROM tmp_cat_hermanos ORDER BY pos LOOP
        v_i := v_i + 1;
        UPDATE inventarios.categorias SET orden = v_i WHERE id = v_fila.id AND orden IS DISTINCT FROM v_i;
    END LOOP;

    -- Y los hermanos que dejó atrás, sin huecos
    IF v_padre_actual IS DISTINCT FROM p_padre_id THEN
        v_i := 0;
        FOR v_fila IN
            SELECT id FROM inventarios.categorias
             WHERE padre_id IS NOT DISTINCT FROM v_padre_actual
             ORDER BY orden, nombre
        LOOP
            v_i := v_i + 1;
            UPDATE inventarios.categorias SET orden = v_i WHERE id = v_fila.id AND orden IS DISTINCT FROM v_i;
        END LOOP;
    END IF;

    RETURN jsonb_build_object(
        'success', true,
        'message', CASE WHEN v_padre_actual IS DISTINCT FROM p_padre_id THEN 'Categoría movida' ELSE 'Orden actualizado' END,
        'data', inventarios.fn_categorias_json(p_id)
    );

EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false, 'error_code', SQLSTATE,
                              'message', 'Error al mover la categoría: ' || SQLERRM);
END;
$function$;

-- ---------------------------------------------------------------------------
-- ELIMINAR = MANDAR A LA PAPELERA
--
-- Se mantienen las dos condiciones de siempre (sin subcategorías y sin
-- productos), pero contando sólo lo VIGENTE: lo que ya está en la papelera
-- no puede impedir nada, porque no se ve en ningún sitio.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION inventarios.fn_categorias_eliminar(
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
SET search_path TO 'pg_catalog', 'inventarios', 'auditoria'
AS $function$
DECLARE
    v_actual    record;
    v_antes     jsonb;
    v_hijos     bigint;
    v_productos bigint;
    v_fecha     timestamptz := CURRENT_TIMESTAMP;
    v_i         integer := 0;
    v_fila      record;
BEGIN
    PERFORM inventarios.fn_contexto_auditoria('inventarios.categorias',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    SELECT id, nombre, padre_id, deleted_at INTO v_actual
      FROM inventarios.categorias WHERE id = p_id;

    -- Una que ya está en la papelera se trata como si no existiera
    IF NOT FOUND OR v_actual.deleted_at IS NOT NULL THEN
        RAISE EXCEPTION 'La categoría no existe' USING ERRCODE = 'P0013';
    END IF;

    SELECT COUNT(*) INTO v_hijos
      FROM inventarios.categorias WHERE padre_id = p_id AND deleted_at IS NULL;
    IF v_hijos > 0 THEN
        RAISE EXCEPTION 'No se puede eliminar: la categoría tiene % subcategoría(s). Muévalas o bórrelas primero.', v_hijos
            USING ERRCODE = 'P0014';
    END IF;

    SELECT COUNT(*) INTO v_productos
      FROM inventarios.productos WHERE categoria_id = p_id AND deleted_at IS NULL;
    IF v_productos > 0 THEN
        RAISE EXCEPTION 'No se puede eliminar: la categoría tiene % producto(s). Desactívela en lugar de borrarla.', v_productos
            USING ERRCODE = 'P0014';
    END IF;

    v_antes := inventarios.fn_categorias_json(p_id);
    PERFORM set_config('app.datos_anteriores', v_antes::text, true);
    PERFORM set_config('app.datos_nuevos', (v_antes || jsonb_build_object(
        'deleted_at', to_char(v_fecha, 'YYYY-MM-DD HH24:MI:SS'), 'deleted_by', p_usuario_login
    ))::text, true);

    UPDATE inventarios.categorias
       SET deleted_at = v_fecha,
           deleted_by = p_usuario_login,
           updated_by = COALESCE(p_usuario_login, updated_by),
           updated_at = v_fecha
     WHERE id = p_id;

    PERFORM set_config('app.datos_anteriores', '', true);
    PERFORM set_config('app.datos_nuevos', '', true);

    -- Las hermanas que quedan se renumeran sin huecos; la que se fue a la
    -- papelera conserva su `orden` y se le vuelve a dar sitio al restaurarla
    FOR v_fila IN
        SELECT id FROM inventarios.categorias
         WHERE padre_id IS NOT DISTINCT FROM v_actual.padre_id
           AND deleted_at IS NULL
         ORDER BY orden, nombre
    LOOP
        v_i := v_i + 1;
        UPDATE inventarios.categorias SET orden = v_i WHERE id = v_fila.id AND orden IS DISTINCT FROM v_i;
    END LOOP;

    RETURN jsonb_build_object(
        'success', true,
        'message', format('Categoría «%s» enviada a la papelera de reciclaje', v_actual.nombre),
        'data', inventarios.fn_categorias_json(p_id)
    );
END;
$function$;


-- ---------------------------------------------------------------------------
-- LO QUE HAY EN LA PAPELERA (más reciente primero)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION inventarios.fn_categorias_papelera_listar()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
AS $function$
DECLARE
    v_data jsonb;
BEGIN
    SELECT COALESCE(jsonb_agg(
               inventarios.fn_categorias_json(c.id)
               -- `padre_en_papelera` evita que haya que adivinar por qué una
               -- hija no se deja restaurar: la pantalla ya lo sabe.
               || jsonb_build_object('padre_en_papelera',
                      EXISTS (SELECT 1 FROM inventarios.categorias p
                               WHERE p.id = c.padre_id AND p.deleted_at IS NOT NULL))
               ORDER BY c.deleted_at DESC, c.id DESC), '[]'::jsonb)
      INTO v_data
      FROM inventarios.categorias c
     WHERE c.deleted_at IS NOT NULL;

    RETURN jsonb_build_object('success', true, 'data', v_data, 'total', jsonb_array_length(v_data));
EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object('success', false, 'message', 'Error al listar la papelera: ' || SQLERRM, 'error_code', SQLSTATE);
END;
$function$;


-- ---------------------------------------------------------------------------
-- RESTAURAR (una o varias)
--
-- Si el padre también está en la papelera, la hija no vuelve: colgaría de
-- algo que no se ve en el árbol. Se dice cuántas se quedaron por eso.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION inventarios.fn_categorias_restaurar(
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
SET search_path TO 'pg_catalog', 'inventarios', 'auditoria'
AS $function$
DECLARE
    v_c        record;
    v_antes    jsonb;
    v_n        integer := 0;
    v_colgadas integer := 0;
    v_fecha    timestamptz := CURRENT_TIMESTAMP;
    v_nombres  text[] := '{}';
    v_padres   bigint[] := '{}';
    v_padre    bigint;
    v_i        integer;
    v_fila     record;
BEGIN
    PERFORM inventarios.fn_contexto_auditoria('inventarios.categorias',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    IF p_ids IS NULL OR jsonb_typeof(p_ids) <> 'array' OR jsonb_array_length(p_ids) = 0 THEN
        RAISE EXCEPTION 'No se indicó ninguna categoría' USING ERRCODE = 'P0001';
    END IF;

    -- De arriba abajo: si se restauran madre e hija a la vez, la madre va
    -- primero y la hija ya se encuentra con el sitio hecho
    FOR v_c IN
        SELECT c.id, c.nombre, c.padre_id, c.nivel
          FROM inventarios.categorias c
         WHERE c.id IN (SELECT (x)::bigint FROM jsonb_array_elements_text(p_ids) x)
           AND c.deleted_at IS NOT NULL
         ORDER BY c.nivel, c.id
    LOOP
        IF v_c.padre_id IS NOT NULL
           AND EXISTS (SELECT 1 FROM inventarios.categorias p
                        WHERE p.id = v_c.padre_id AND p.deleted_at IS NOT NULL) THEN
            v_colgadas := v_colgadas + 1;
            CONTINUE;
        END IF;

        v_antes := inventarios.fn_categorias_json(v_c.id);
        PERFORM set_config('app.datos_anteriores', v_antes::text, true);
        PERFORM set_config('app.datos_nuevos', (v_antes || jsonb_build_object('deleted_at', NULL, 'deleted_by', NULL))::text, true);

        UPDATE inventarios.categorias
           SET deleted_at = NULL, deleted_by = NULL,
               updated_by = COALESCE(p_usuario_login, updated_by), updated_at = v_fecha
         WHERE id = v_c.id;

        v_n := v_n + 1;
        v_nombres := v_nombres || v_c.nombre::text;
        -- Las raíces tienen `padre_id` NULL y un array no sabe compararlo
        -- (`IS NOT DISTINCT FROM ANY` no existe): se guarda -1 en su lugar
        -- y se deshace el truco al renumerar.
        IF NOT (COALESCE(v_c.padre_id, -1) = ANY(v_padres)) THEN
            v_padres := v_padres || COALESCE(v_c.padre_id, -1);
        END IF;
    END LOOP;

    PERFORM set_config('app.datos_anteriores', '', true);
    PERFORM set_config('app.datos_nuevos', '', true);

    IF v_n = 0 THEN
        IF v_colgadas > 0 THEN
            RAISE EXCEPTION 'No se puede restaurar: su categoría padre también está en la papelera. Restaure primero la de arriba.'
                USING ERRCODE = 'P0014';
        END IF;
        RAISE EXCEPTION 'Ninguna de esas categorías está en la papelera' USING ERRCODE = 'P0019';
    END IF;

    -- Renumerar a las hermanas de cada rama tocada: la restaurada vuelve con
    -- un `orden` que puede empatar con el de otra
    FOREACH v_padre IN ARRAY v_padres LOOP
        v_i := 0;
        FOR v_fila IN
            SELECT id FROM inventarios.categorias
             WHERE padre_id IS NOT DISTINCT FROM NULLIF(v_padre, -1)
               AND deleted_at IS NULL
             ORDER BY orden, nombre
        LOOP
            v_i := v_i + 1;
            UPDATE inventarios.categorias SET orden = v_i WHERE id = v_fila.id AND orden IS DISTINCT FROM v_i;
        END LOOP;
    END LOOP;

    RETURN jsonb_build_object(
        'success', true,
        'message', CASE WHEN v_n = 1 THEN format('Categoría «%s» restaurada', v_nombres[1])
                        ELSE format('%s categorías restauradas', v_n) END
                 || CASE WHEN v_colgadas > 0
                         THEN format('. %s se quedaron: su categoría padre sigue en la papelera', v_colgadas)
                         ELSE '' END,
        'data', jsonb_build_object('restauradas', v_n, 'sin_padre', v_colgadas, 'nombres', to_jsonb(v_nombres))
    );
END;
$function$;


-- ---------------------------------------------------------------------------
-- BORRADO REAL (sólo de lo que está en la papelera)
--
-- Se exige que no le quede NADA debajo, ni siquiera en la papelera: la clave
-- ajena de `padre_id` lo impediría de todos modos, y es mejor un mensaje que
-- un error de integridad.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION inventarios.fn_categorias_eliminar_definitivo(
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
SET search_path TO 'pg_catalog', 'inventarios', 'auditoria'
AS $function$
DECLARE
    v_c         record;
    v_n         integer := 0;
    v_hijos     bigint;
    v_productos bigint;
    v_nombres   text[] := '{}';
BEGIN
    PERFORM inventarios.fn_contexto_auditoria('inventarios.categorias',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    IF p_ids IS NULL OR jsonb_typeof(p_ids) <> 'array' OR jsonb_array_length(p_ids) = 0 THEN
        RAISE EXCEPTION 'No se indicó ninguna categoría' USING ERRCODE = 'P0001';
    END IF;

    -- De lo más hondo a lo más alto: así, al vaciar la papelera entera, las
    -- hijas se van antes que sus madres y no choca la clave ajena
    FOR v_c IN
        SELECT c.id, c.nombre
          FROM inventarios.categorias c
         WHERE c.id IN (SELECT (x)::bigint FROM jsonb_array_elements_text(p_ids) x)
           AND c.deleted_at IS NOT NULL
         ORDER BY c.nivel DESC, c.id DESC
    LOOP
        SELECT COUNT(*) INTO v_hijos FROM inventarios.categorias WHERE padre_id = v_c.id;
        IF v_hijos > 0 THEN
            RAISE EXCEPTION 'No se puede eliminar «%» definitivamente: todavía tiene % subcategoría(s), aunque estén en la papelera. Bórrelas primero.', v_c.nombre, v_hijos
                USING ERRCODE = 'P0014';
        END IF;

        SELECT COUNT(*) INTO v_productos FROM inventarios.productos WHERE categoria_id = v_c.id;
        IF v_productos > 0 THEN
            RAISE EXCEPTION 'No se puede eliminar «%» definitivamente: todavía tiene % producto(s), aunque estén en la papelera.', v_c.nombre, v_productos
                USING ERRCODE = 'P0014';
        END IF;

        -- La ficha entera a la auditoría: es lo único que no se puede volver
        -- a escribir de memoria si se borró por error
        PERFORM set_config('app.datos_anteriores', (inventarios.fn_categorias_json(v_c.id))::text, true);
        DELETE FROM inventarios.categorias WHERE id = v_c.id;

        v_n := v_n + 1;
        v_nombres := v_nombres || v_c.nombre::text;
    END LOOP;

    PERFORM set_config('app.datos_anteriores', '', true);

    IF v_n = 0 THEN
        RAISE EXCEPTION 'Ninguna de esas categorías está en la papelera' USING ERRCODE = 'P0019';
    END IF;

    RETURN jsonb_build_object(
        'success', true,
        'message', CASE WHEN v_n = 1 THEN format('Categoría «%s» eliminada definitivamente', v_nombres[1])
                        ELSE format('%s categorías eliminadas definitivamente', v_n) END,
        'data', jsonb_build_object('borradas', v_n, 'nombres', to_jsonb(v_nombres))
    );

EXCEPTION
    WHEN foreign_key_violation THEN
        RAISE EXCEPTION 'No se puede eliminar definitivamente: algo sigue apuntando a esa categoría' USING ERRCODE = 'P0014';
END;
$function$;


-- ---------------------------------------------------------------------------
-- VACIAR LA PAPELERA
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION inventarios.fn_categorias_papelera_vaciar(
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
SET search_path TO 'pg_catalog', 'inventarios', 'auditoria'
AS $function$
DECLARE
    v_ids jsonb;
BEGIN
    SELECT COALESCE(jsonb_agg(c.id), '[]'::jsonb) INTO v_ids
      FROM inventarios.categorias c WHERE c.deleted_at IS NOT NULL;

    IF jsonb_array_length(v_ids) = 0 THEN
        RETURN jsonb_build_object('success', true, 'message', 'La papelera ya estaba vacía',
                                  'data', jsonb_build_object('borradas', 0, 'nombres', '[]'::jsonb));
    END IF;

    -- Se delega en eliminar_definitivo, que ya va de lo más hondo a lo más
    -- alto: dos sitios donde se borra de verdad acabarían divergiendo.
    RETURN inventarios.fn_categorias_eliminar_definitivo(v_ids,
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);
END;
$function$;


-- ---------------------------------------------------------------------------
-- PERMISOS Y COMENTARIOS
-- ---------------------------------------------------------------------------
ALTER FUNCTION inventarios.fn_categorias_papelera_listar() OWNER TO postgres;
ALTER FUNCTION inventarios.fn_categorias_restaurar(jsonb, bigint, varchar, varchar, inet, text, uuid) OWNER TO postgres;
ALTER FUNCTION inventarios.fn_categorias_eliminar_definitivo(jsonb, bigint, varchar, varchar, inet, text, uuid) OWNER TO postgres;
ALTER FUNCTION inventarios.fn_categorias_papelera_vaciar(bigint, varchar, varchar, inet, text, uuid) OWNER TO postgres;

COMMENT ON FUNCTION inventarios.fn_categorias_eliminar(bigint, bigint, varchar, varchar, inet, text, uuid) IS 'Envía la categoría a la papelera de reciclaje (borrado lógico); exige que no tenga subcategorías ni productos vigentes';
COMMENT ON FUNCTION inventarios.fn_categorias_papelera_listar() IS 'Categorías que están en la papelera; `padre_en_papelera` dice cuáles no se pueden restaurar todavía';
COMMENT ON FUNCTION inventarios.fn_categorias_restaurar(jsonb, bigint, varchar, varchar, inet, text, uuid) IS 'Saca de la papelera una o varias categorías; las que cuelgan de otra que sigue en la papelera no vuelven';
COMMENT ON FUNCTION inventarios.fn_categorias_eliminar_definitivo(jsonb, bigint, varchar, varchar, inet, text, uuid) IS 'Borrado real de categorías de la papelera, de lo más hondo a lo más alto';
COMMENT ON FUNCTION inventarios.fn_categorias_papelera_vaciar(bigint, varchar, varchar, inet, text, uuid) IS 'Borrado real de todo lo que hay en la papelera de categorías';
