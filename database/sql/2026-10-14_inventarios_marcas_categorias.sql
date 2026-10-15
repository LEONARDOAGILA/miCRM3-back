-- ============================================================================
-- INVENTARIOS — FUNCIONES DE MARCAS Y CATEGORÍAS
-- ============================================================================
-- Fecha: 2026-10-14
-- Se aplica después de 2026-10-14_inventarios_tablas.sql.
--
-- Mismo esquema que rh.fn_cargos_* y seguridad.fn_menus_*: el controlador
-- valida la entrada y llama; aquí viven las reglas, la auditoría y la
-- transacción.
--
-- Las reglas se lanzan con RAISE EXCEPTION y un SQLSTATE propio para que la
-- transacción aborte sola y el back lo traduzca a 4xx:
--   P0001 falta un dato obligatorio    P0006 duplicado
--   P0013 no existe                    P0014 tiene dependencias
--   P0015 valor inválido               P0016 la referencia no existe
--
-- Las de ÁRBOL (mover) no levantan excepción: devuelven success=false con un
-- error_code, como fn_menus_mover, porque ahí los motivos son muchos (ciclo,
-- nivel máximo, destino inexistente) y el front los muestra tal cual.
--
-- Idempotente: CREATE OR REPLACE.
-- ============================================================================


-- ---------------------------------------------------------------------------
-- CONTEXTO DE AUDITORÍA (uno para todo el esquema)
--
-- Lo mismo que rh.fn_contexto_auditoria: evita repetir siete set_config en
-- cada una de las veinte funciones del módulo.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION inventarios.fn_contexto_auditoria(
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


-- ===========================================================================
--                                 M A R C A S
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- UNA MARCA, EN LA FORMA EN QUE LA PINTA LA REJILLA
--
-- Una sola función que arma el jsonb, y todas las demás la usan: así el
-- listado, el alta y la modificación devuelven exactamente la misma forma y
-- la pantalla no tiene que tratar tres casos.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION inventarios.fn_marcas_json(p_id bigint)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
AS $function$
    SELECT jsonb_build_object(
        'id',            m.id,
        'nombre',        m.nombre,
        'descripcion',   m.descripcion,
        'pais_origen',   m.pais_origen,
        'sitio_web',     m.sitio_web,
        'logo',          m.logo,
        'activo',        m.activo,
        'num_productos', (SELECT COUNT(*) FROM inventarios.productos p WHERE p.marca_id = m.id),
        'created_by',    m.created_by,
        'updated_by',    m.updated_by,
        'created_at',    to_char(m.created_at, 'YYYY-MM-DD HH24:MI:SS'),
        'updated_at',    to_char(m.updated_at, 'YYYY-MM-DD HH24:MI:SS')
    )
      FROM inventarios.marcas m
     WHERE m.id = p_id;
$function$;


-- ---------------------------------------------------------------------------
-- LISTADO PAGINADO (rejilla)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION inventarios.fn_marcas_listar_paginado(
    p_page     integer DEFAULT 1,
    p_per_page integer DEFAULT 15,
    p_search   text    DEFAULT ''
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'inventarios'
AS $function$
DECLARE
    v_offset integer;
    v_total  bigint;
    v_data   jsonb;
    v_filtro text;
BEGIN
    v_offset := (GREATEST(p_page, 1) - 1) * GREATEST(p_per_page, 1);
    v_filtro := NULLIF(TRIM(COALESCE(p_search, '')), '');

    SELECT COUNT(*) INTO v_total
      FROM inventarios.marcas m
     WHERE v_filtro IS NULL
        OR m.nombre      ILIKE '%' || v_filtro || '%'
        OR m.descripcion ILIKE '%' || v_filtro || '%'
        OR m.pais_origen ILIKE '%' || v_filtro || '%'
        OR m.id::text    ILIKE '%' || v_filtro || '%';

    SELECT COALESCE(jsonb_agg(inventarios.fn_marcas_json(t.id) ORDER BY t.id DESC), '[]'::jsonb)
      INTO v_data
      FROM (
        SELECT m.id
          FROM inventarios.marcas m
         WHERE v_filtro IS NULL
            OR m.nombre      ILIKE '%' || v_filtro || '%'
            OR m.descripcion ILIKE '%' || v_filtro || '%'
            OR m.pais_origen ILIKE '%' || v_filtro || '%'
            OR m.id::text    ILIKE '%' || v_filtro || '%'
         ORDER BY m.id DESC
         LIMIT GREATEST(p_per_page, 1) OFFSET v_offset
      ) t;

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

EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false, 'message', 'Error al listar marcas: ' || SQLERRM, 'error_code', SQLSTATE);
END;
$function$;


-- ---------------------------------------------------------------------------
-- LISTA SIMPLE (combos)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION inventarios.fn_marcas_listar(p_solo_activos boolean DEFAULT true)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
AS $function$
    SELECT jsonb_build_object(
        'success', true,
        'data', COALESCE(jsonb_agg(
            jsonb_build_object('id', m.id, 'nombre', m.nombre, 'logo', m.logo, 'activo', m.activo)
            ORDER BY m.nombre
        ), '[]'::jsonb)
    )
      FROM inventarios.marcas m
     WHERE NOT p_solo_activos OR m.activo;
$function$;


-- ---------------------------------------------------------------------------
-- UNA SOLA
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION inventarios.fn_marcas_obtener(p_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
AS $function$
DECLARE
    v_data jsonb;
BEGIN
    v_data := inventarios.fn_marcas_json(p_id);
    IF v_data IS NULL THEN
        RAISE EXCEPTION 'La marca no existe' USING ERRCODE = 'P0013';
    END IF;
    RETURN jsonb_build_object('success', true, 'message', 'Marca encontrada', 'data', v_data);
END;
$function$;


-- ---------------------------------------------------------------------------
-- ALTA
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION inventarios.fn_marcas_crear(
    p_nombre         varchar,
    p_descripcion    text    DEFAULT NULL,
    p_pais_origen    varchar DEFAULT NULL,
    p_sitio_web      varchar DEFAULT NULL,
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
    v_nuevo jsonb;
BEGIN
    PERFORM inventarios.fn_contexto_auditoria('inventarios.marcas',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    IF p_nombre IS NULL OR length(TRIM(p_nombre)) < 2 THEN
        RAISE EXCEPTION 'El nombre de la marca es obligatorio (mínimo 2 caracteres)' USING ERRCODE = 'P0001';
    END IF;
    -- Mensaje claro antes de que salte el índice único (que también lo cubre)
    IF EXISTS (SELECT 1 FROM inventarios.marcas WHERE UPPER(TRIM(nombre)) = UPPER(TRIM(p_nombre))) THEN
        RAISE EXCEPTION 'Ya existe una marca con ese nombre' USING ERRCODE = 'P0006';
    END IF;

    v_nuevo := jsonb_build_object(
        'nombre',      TRIM(p_nombre),
        'descripcion', NULLIF(TRIM(COALESCE(p_descripcion, '')), ''),
        'pais_origen', NULLIF(TRIM(COALESCE(p_pais_origen, '')), ''),
        'sitio_web',   NULLIF(TRIM(COALESCE(p_sitio_web, '')), ''),
        'activo',      COALESCE(p_activo, true)
    );
    PERFORM set_config('app.datos_nuevos', v_nuevo::text, true);

    INSERT INTO inventarios.marcas (nombre, descripcion, pais_origen, sitio_web, activo)
    VALUES (
        TRIM(p_nombre),
        NULLIF(TRIM(COALESCE(p_descripcion, '')), ''),
        NULLIF(TRIM(COALESCE(p_pais_origen, '')), ''),
        NULLIF(TRIM(COALESCE(p_sitio_web, '')), ''),
        COALESCE(p_activo, true)
    )
    RETURNING id INTO v_id;

    PERFORM set_config('app.datos_nuevos', '', true);

    RETURN jsonb_build_object('success', true, 'message', 'Marca creada exitosamente',
                              'data', inventarios.fn_marcas_json(v_id));

EXCEPTION
    -- Se re-lanza: manda el índice único, no la comprobación de arriba
    WHEN unique_violation THEN
        RAISE EXCEPTION 'Ya existe una marca con ese nombre' USING ERRCODE = 'P0006';
END;
$function$;


-- ---------------------------------------------------------------------------
-- MODIFICACIÓN
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION inventarios.fn_marcas_modificar(
    p_id             bigint,
    p_nombre         varchar,
    p_descripcion    text    DEFAULT NULL,
    p_pais_origen    varchar DEFAULT NULL,
    p_sitio_web      varchar DEFAULT NULL,
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
    v_antes jsonb;
    v_nuevo jsonb;
BEGIN
    PERFORM inventarios.fn_contexto_auditoria('inventarios.marcas',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    v_antes := inventarios.fn_marcas_json(p_id);
    IF v_antes IS NULL THEN
        RAISE EXCEPTION 'La marca no existe' USING ERRCODE = 'P0013';
    END IF;

    IF p_nombre IS NULL OR length(TRIM(p_nombre)) < 2 THEN
        RAISE EXCEPTION 'El nombre de la marca es obligatorio (mínimo 2 caracteres)' USING ERRCODE = 'P0001';
    END IF;
    IF EXISTS (SELECT 1 FROM inventarios.marcas
                WHERE UPPER(TRIM(nombre)) = UPPER(TRIM(p_nombre)) AND id <> p_id) THEN
        RAISE EXCEPTION 'Ya existe otra marca con ese nombre' USING ERRCODE = 'P0006';
    END IF;

    v_nuevo := jsonb_build_object(
        'nombre',      TRIM(p_nombre),
        'descripcion', NULLIF(TRIM(COALESCE(p_descripcion, '')), ''),
        'pais_origen', NULLIF(TRIM(COALESCE(p_pais_origen, '')), ''),
        'sitio_web',   NULLIF(TRIM(COALESCE(p_sitio_web, '')), ''),
        'activo',      COALESCE(p_activo, true)
    );
    PERFORM set_config('app.datos_anteriores',
        (v_antes - 'num_productos' - 'created_at' - 'created_by' - 'updated_at' - 'updated_by' - 'id' - 'logo')::text, true);
    PERFORM set_config('app.datos_nuevos', v_nuevo::text, true);

    UPDATE inventarios.marcas
       SET nombre      = TRIM(p_nombre),
           descripcion = NULLIF(TRIM(COALESCE(p_descripcion, '')), ''),
           pais_origen = NULLIF(TRIM(COALESCE(p_pais_origen, '')), ''),
           sitio_web   = NULLIF(TRIM(COALESCE(p_sitio_web, '')), ''),
           activo      = COALESCE(p_activo, true)
     WHERE id = p_id;

    PERFORM set_config('app.datos_anteriores', '', true);
    PERFORM set_config('app.datos_nuevos', '', true);

    RETURN jsonb_build_object('success', true, 'message', 'Marca actualizada exitosamente',
                              'data', inventarios.fn_marcas_json(p_id));

EXCEPTION
    WHEN unique_violation THEN
        RAISE EXCEPTION 'Ya existe otra marca con ese nombre' USING ERRCODE = 'P0006';
END;
$function$;


-- ---------------------------------------------------------------------------
-- BAJA
--
-- Con productos NO se borra. Es una baja de verdad (no lógica): para «quitar
-- de en medio» sin perder el histórico está la casilla Activo.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION inventarios.fn_marcas_eliminar(
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
    v_antes     jsonb;
    v_productos bigint;
    v_logo      varchar;
BEGIN
    PERFORM inventarios.fn_contexto_auditoria('inventarios.marcas',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    v_antes := inventarios.fn_marcas_json(p_id);
    IF v_antes IS NULL THEN
        RAISE EXCEPTION 'La marca no existe' USING ERRCODE = 'P0013';
    END IF;

    SELECT COUNT(*) INTO v_productos FROM inventarios.productos WHERE marca_id = p_id;
    IF v_productos > 0 THEN
        RAISE EXCEPTION 'No se puede eliminar: la marca tiene % producto(s). Desactívela en lugar de borrarla.', v_productos
            USING ERRCODE = 'P0014';
    END IF;

    SELECT logo INTO v_logo FROM inventarios.marcas WHERE id = p_id;

    -- La marca entera queda en la auditoría: es lo único que no se puede
    -- volver a escribir de memoria si se borró por error
    PERFORM set_config('app.datos_anteriores', v_antes::text, true);
    DELETE FROM inventarios.marcas WHERE id = p_id;
    PERFORM set_config('app.datos_anteriores', '', true);

    -- El fichero del logo lo borra el controlador, que es quien sabe de disco
    RETURN jsonb_build_object('success', true, 'message', 'Marca eliminada exitosamente',
                              'data', jsonb_build_object('id', p_id, 'logo', v_logo));
END;
$function$;


-- ---------------------------------------------------------------------------
-- ACTIVAR / DESACTIVAR (sólo esa columna)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION inventarios.fn_marcas_activar(
    p_id             bigint,
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
SET search_path TO 'pg_catalog', 'inventarios', 'auditoria'
AS $function$
DECLARE
    v_antes      boolean;
    v_nuevo      boolean;
    v_updated_by varchar;
    v_updated_at text;
BEGIN
    PERFORM inventarios.fn_contexto_auditoria('inventarios.marcas',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    SELECT activo INTO v_antes FROM inventarios.marcas WHERE id = p_id;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'error_code', 'NO_EXISTE', 'message', 'La marca no existe');
    END IF;

    v_nuevo := COALESCE(p_activo, NOT v_antes);

    IF v_nuevo IS NOT DISTINCT FROM v_antes THEN
        SELECT updated_by, to_char(updated_at, 'YYYY-MM-DD HH24:MI:SS')
          INTO v_updated_by, v_updated_at FROM inventarios.marcas WHERE id = p_id;
        RETURN jsonb_build_object('success', true,
            'message', CASE WHEN v_nuevo THEN 'La marca ya estaba activa' ELSE 'La marca ya estaba inactiva' END,
            'data', jsonb_build_object('id', p_id, 'activo', v_nuevo,
                                       'updated_by', v_updated_by, 'updated_at', v_updated_at));
    END IF;

    PERFORM set_config('app.datos_anteriores', jsonb_build_object('id', p_id, 'activo', v_antes)::text, true);
    PERFORM set_config('app.datos_nuevos',     jsonb_build_object('id', p_id, 'activo', v_nuevo)::text, true);

    UPDATE inventarios.marcas SET activo = v_nuevo WHERE id = p_id
    RETURNING activo, updated_by, to_char(updated_at, 'YYYY-MM-DD HH24:MI:SS')
         INTO v_nuevo, v_updated_by, v_updated_at;

    PERFORM set_config('app.datos_anteriores', '', true);
    PERFORM set_config('app.datos_nuevos', '', true);

    RETURN jsonb_build_object('success', true,
        'message', CASE WHEN v_nuevo THEN 'Marca activada' ELSE 'Marca desactivada' END,
        'data', jsonb_build_object('id', p_id, 'activo', v_nuevo,
                                   'updated_by', v_updated_by, 'updated_at', v_updated_at));

EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false, 'error_code', 'ERROR',
                              'message', 'No se pudo cambiar el estado de la marca: ' || SQLERRM);
END;
$function$;


-- ---------------------------------------------------------------------------
-- EL LOGO (sólo apunta el nombre del fichero; subirlo es cosa del back)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION inventarios.fn_marcas_logo(
    p_id             bigint,
    p_logo           varchar,
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
    v_antes varchar;
BEGIN
    PERFORM inventarios.fn_contexto_auditoria('inventarios.marcas',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    SELECT logo INTO v_antes FROM inventarios.marcas WHERE id = p_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'La marca no existe' USING ERRCODE = 'P0013';
    END IF;

    PERFORM set_config('app.datos_anteriores', jsonb_build_object('id', p_id, 'logo', v_antes)::text, true);
    PERFORM set_config('app.datos_nuevos',     jsonb_build_object('id', p_id, 'logo', p_logo)::text, true);

    UPDATE inventarios.marcas SET logo = p_logo WHERE id = p_id;

    PERFORM set_config('app.datos_anteriores', '', true);
    PERFORM set_config('app.datos_nuevos', '', true);

    RETURN jsonb_build_object('success', true, 'message', 'Logo actualizado',
                              'data', jsonb_build_object('id', p_id, 'logo', p_logo, 'logo_anterior', v_antes));
END;
$function$;


-- ===========================================================================
--                            C A T E G O R Í A S
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- UNA CATEGORÍA, EN LA FORMA EN QUE LA PINTA LA REJILLA
--
-- `ruta` es el camino completo («Línea Blanca > Refrigeración») y es lo que
-- se enseña en los combos de producto: fuera del árbol, «Accesorios» a secas
-- no dice de qué.
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
        'num_hijos',     (SELECT COUNT(*) FROM inventarios.categorias h WHERE h.padre_id = c.id),
        'num_productos', (SELECT COUNT(*) FROM inventarios.productos p WHERE p.categoria_id = c.id),
        'created_by',    c.created_by,
        'updated_by',    c.updated_by,
        'created_at',    to_char(c.created_at, 'YYYY-MM-DD HH24:MI:SS'),
        'updated_at',    to_char(c.updated_at, 'YYYY-MM-DD HH24:MI:SS')
    )
      FROM inventarios.categorias c
     WHERE c.id = p_id;
$function$;


-- ---------------------------------------------------------------------------
-- EL ÁRBOL ENTERO, YA ORDENADO
--
-- SIN PAGINAR, igual que seguridad.fn_menus_listar: un árbol partido en
-- páginas no es un árbol —la mitad de los padres se quedarían en la página
-- anterior—. Son decenas de filas, no miles.
--
-- El orden sale de una ruta de ordenamiento («00001.00003.00002») con el
-- `orden` de cada antepasado rellenado a cinco cifras: así el hijo cae justo
-- debajo de su padre y los hermanos salen en su orden, con una sola consulta.
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

        UNION ALL

        SELECT h.id, h.padre_id, h.orden, h.activo,
               a.ruta_orden || '.' || LPAD(h.orden::text, 5, '0')
          FROM inventarios.categorias h
          JOIN arbol a ON h.padre_id = a.id
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
-- UNA SOLA
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION inventarios.fn_categorias_obtener(p_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
AS $function$
DECLARE
    v_data jsonb;
BEGIN
    v_data := inventarios.fn_categorias_json(p_id);
    IF v_data IS NULL THEN
        RAISE EXCEPTION 'La categoría no existe' USING ERRCODE = 'P0013';
    END IF;
    RETURN jsonb_build_object('success', true, 'message', 'Categoría encontrada', 'data', v_data);
END;
$function$;


-- ---------------------------------------------------------------------------
-- ALTA
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


-- ---------------------------------------------------------------------------
-- MODIFICACIÓN
--
-- NO CAMBIA DE PADRE. Mover es otra cosa —hay que mirar ciclos, el nivel de
-- todo lo que cuelga y renumerar hermanos— y vive en fn_categorias_mover,
-- que es lo que usa el arrastre de la rejilla. Aquí se cambia lo que se ve
-- en el formulario.
-- ---------------------------------------------------------------------------
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
        RAISE EXCEPTION 'Ya existe otra categoría con ese nombre en el mismo nivel' USING ERRCODE = 'P0006';
END;
$function$;


-- ---------------------------------------------------------------------------
-- BAJA
--
-- Ni con hijos ni con productos. Borrar un nodo del árbol con hijos dejaría
-- huérfanos apuntando a un padre que ya no está.
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
    v_antes     jsonb;
    v_padre     bigint;
    v_hijos     bigint;
    v_productos bigint;
    v_i         integer := 0;
    v_fila      record;
BEGIN
    PERFORM inventarios.fn_contexto_auditoria('inventarios.categorias',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    v_antes := inventarios.fn_categorias_json(p_id);
    IF v_antes IS NULL THEN
        RAISE EXCEPTION 'La categoría no existe' USING ERRCODE = 'P0013';
    END IF;
    SELECT padre_id INTO v_padre FROM inventarios.categorias WHERE id = p_id;

    SELECT COUNT(*) INTO v_hijos FROM inventarios.categorias WHERE padre_id = p_id;
    IF v_hijos > 0 THEN
        RAISE EXCEPTION 'No se puede eliminar: la categoría tiene % subcategoría(s). Muévalas o bórrelas primero.', v_hijos
            USING ERRCODE = 'P0014';
    END IF;

    SELECT COUNT(*) INTO v_productos FROM inventarios.productos WHERE categoria_id = p_id;
    IF v_productos > 0 THEN
        RAISE EXCEPTION 'No se puede eliminar: la categoría tiene % producto(s). Desactívela en lugar de borrarla.', v_productos
            USING ERRCODE = 'P0014';
    END IF;

    PERFORM set_config('app.datos_anteriores', v_antes::text, true);
    DELETE FROM inventarios.categorias WHERE id = p_id;
    PERFORM set_config('app.datos_anteriores', '', true);

    -- Los hermanos que quedan se renumeran sin huecos: si no, el siguiente
    -- alta cogería un `orden` repetido y dos categorías empatarían
    FOR v_fila IN
        SELECT id FROM inventarios.categorias
         WHERE padre_id IS NOT DISTINCT FROM v_padre
         ORDER BY orden, nombre
    LOOP
        v_i := v_i + 1;
        UPDATE inventarios.categorias SET orden = v_i WHERE id = v_fila.id AND orden IS DISTINCT FROM v_i;
    END LOOP;

    RETURN jsonb_build_object('success', true, 'message', 'Categoría eliminada exitosamente',
                              'data', jsonb_build_object('id', p_id));
END;
$function$;


-- ---------------------------------------------------------------------------
-- ACTIVAR / DESACTIVAR
--
-- Desactivar un padre NO desactiva a sus hijos: son decisiones distintas y
-- cascadear apagaría media rama de un clic sin que se vea venir. Lo que sí
-- se hace es decir cuántos descendientes activos quedan colgando.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION inventarios.fn_categorias_activar(
    p_id             bigint,
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
SET search_path TO 'pg_catalog', 'inventarios', 'auditoria'
AS $function$
DECLARE
    v_antes      boolean;
    v_nuevo      boolean;
    v_updated_by varchar;
    v_updated_at text;
BEGIN
    PERFORM inventarios.fn_contexto_auditoria('inventarios.categorias',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    SELECT activo INTO v_antes FROM inventarios.categorias WHERE id = p_id;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'error_code', 'NO_EXISTE', 'message', 'La categoría no existe');
    END IF;

    v_nuevo := COALESCE(p_activo, NOT v_antes);

    IF v_nuevo IS NOT DISTINCT FROM v_antes THEN
        SELECT updated_by, to_char(updated_at, 'YYYY-MM-DD HH24:MI:SS')
          INTO v_updated_by, v_updated_at FROM inventarios.categorias WHERE id = p_id;
        RETURN jsonb_build_object('success', true,
            'message', CASE WHEN v_nuevo THEN 'La categoría ya estaba activa' ELSE 'La categoría ya estaba inactiva' END,
            'data', jsonb_build_object('id', p_id, 'activo', v_nuevo,
                                       'updated_by', v_updated_by, 'updated_at', v_updated_at));
    END IF;

    PERFORM set_config('app.datos_anteriores', jsonb_build_object('id', p_id, 'activo', v_antes)::text, true);
    PERFORM set_config('app.datos_nuevos',     jsonb_build_object('id', p_id, 'activo', v_nuevo)::text, true);

    UPDATE inventarios.categorias SET activo = v_nuevo WHERE id = p_id
    RETURNING activo, updated_by, to_char(updated_at, 'YYYY-MM-DD HH24:MI:SS')
         INTO v_nuevo, v_updated_by, v_updated_at;

    PERFORM set_config('app.datos_anteriores', '', true);
    PERFORM set_config('app.datos_nuevos', '', true);

    RETURN jsonb_build_object('success', true,
        'message', CASE WHEN v_nuevo THEN 'Categoría activada' ELSE 'Categoría desactivada' END,
        'data', jsonb_build_object('id', p_id, 'activo', v_nuevo,
                                   'updated_by', v_updated_by, 'updated_at', v_updated_at));

EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false, 'error_code', 'ERROR',
                              'message', 'No se pudo cambiar el estado de la categoría: ' || SQLERRM);
END;
$function$;


-- ---------------------------------------------------------------------------
-- MOVER (arrastrar en la rejilla)
--
-- Copia fiel de seguridad.fn_menus_mover, que es donde está resuelto este
-- problema en la casa: cambia de padre, recalcula el nivel de TODO lo que
-- cuelga y renumera los hermanos de origen y de destino.
--
-- No levanta excepción: devuelve success=false con un error_code, porque los
-- motivos son varios y cada uno quiere su mensaje en pantalla.
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
        IF NOT EXISTS (SELECT 1 FROM inventarios.categorias WHERE id = p_padre_id) THEN
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
-- PROPIEDAD
-- ---------------------------------------------------------------------------
DO $$
DECLARE r record;
BEGIN
    FOR r IN SELECT p.oid::regprocedure AS firma
               FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
              WHERE n.nspname = 'inventarios'
    LOOP
        EXECUTE format('ALTER FUNCTION %s OWNER TO postgres', r.firma);
    END LOOP;
END $$;


-- ---------------------------------------------------------------------------
-- COMPROBACIÓN
-- ---------------------------------------------------------------------------
SELECT p.proname, pg_get_function_identity_arguments(p.oid) AS argumentos
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname = 'inventarios'
 ORDER BY 1;
