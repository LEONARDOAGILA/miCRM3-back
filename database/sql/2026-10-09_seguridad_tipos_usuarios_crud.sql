-- ===========================================================================
-- CRUD DE LOS TIPOS DE USUARIO, Y SU VIGENCIA
-- ===========================================================================
-- Fecha: 2026-10-09
-- Se aplica después de 2026-10-09_seguridad_tipos_usuarios.sql.
--
-- Dos cosas:
--
-- 1. El CRUD completo del catálogo, con la forma de la casa: listar paginado,
--    obtener, crear, modificar y eliminar; contexto de auditoría con
--    set_config, validaciones que devuelven {success:false, message,
--    error_code} y jsonb {success, message, data}. Igual que
--    seguridad.fn_horarios_*.
--
-- 2. FECHA DE INICIO Y FECHA DE FIN, para que un tipo tenga vigencia y los
--    usuarios de ese tipo sólo puedan entrar mientras lo esté. Es lo que hacía
--    falta para los temporales: se da de alta el tipo con su rango y el acceso
--    se corta solo.
--
-- LA VIGENCIA ES DEL TIPO, NO DE LA PERSONA. Es lo pedido, y conviene saber lo
-- que implica: si «Temporal» caduca el 31 de diciembre, ese día pierden el
-- acceso TODOS los temporales a la vez. Para cortar a una persona en su propia
-- fecha harían falta columnas en seguridad.users, que es otra conversación.
--
-- NULL ES «SIN LÍMITE» por los dos lados: sin fecha de inicio vale desde
-- siempre, y sin fecha de fin no caduca. Así los tipos de siempre —del sistema,
-- web— se quedan como están sin tener que inventarles fechas.
--
-- VIGENTE NO ES LO MISMO QUE ACTIVO. `activo` lo apaga un administrador a mano
-- y es para dejar de asignarlo; la vigencia la decide el calendario. Un tipo
-- inactivo no está vigente, pero uno activo puede no estarlo todavía (empieza
-- mañana) o haber caducado.
--
-- EL DÍA DE FIN CUENTA ENTERO: la comparación es `fecha_fin >= CURRENT_DATE`,
-- así que quien tenga el 31 de diciembre entra ese 31 y deja de entrar el 1.
--
-- Idempotente.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- 1. Las dos fechas
-- ---------------------------------------------------------------------------
ALTER TABLE seguridad.tipos_usuarios
    ADD COLUMN IF NOT EXISTS fecha_inicio date,
    ADD COLUMN IF NOT EXISTS fecha_fin    date;

COMMENT ON COLUMN seguridad.tipos_usuarios.fecha_inicio
    IS 'Desde cuándo vale el tipo. NULL = desde siempre';
COMMENT ON COLUMN seguridad.tipos_usuarios.fecha_fin
    IS 'Hasta cuándo vale, ese día incluido. NULL = no caduca';

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'ck_tipos_usuarios_vigencia') THEN
        ALTER TABLE seguridad.tipos_usuarios
            ADD CONSTRAINT ck_tipos_usuarios_vigencia
            CHECK (fecha_inicio IS NULL OR fecha_fin IS NULL OR fecha_fin >= fecha_inicio);
    END IF;
END;
$$;


-- ---------------------------------------------------------------------------
-- 2. ¿Está vigente?
-- ---------------------------------------------------------------------------
-- Una función y no una expresión repetida: lo preguntan el middleware que
-- vigila cada petición, el listado y la ficha. Si algún día la regla cambia
-- —avisar unos días antes, por ejemplo— se cambia aquí y en un sitio.
--
-- Un usuario SIN TIPO (type_user NULL) se considera vigente: la vigencia es
-- una restricción del tipo, y no tenerlo no puede dejar a nadie fuera.
CREATE OR REPLACE FUNCTION seguridad.fn_tipo_usuario_vigente(p_id integer)
RETURNS boolean
LANGUAGE sql
STABLE
AS $function$
    SELECT CASE
             WHEN p_id IS NULL THEN true
             ELSE COALESCE((SELECT t.activo
                                   AND (t.fecha_inicio IS NULL OR t.fecha_inicio <= CURRENT_DATE)
                                   AND (t.fecha_fin    IS NULL OR t.fecha_fin    >= CURRENT_DATE)
                              FROM seguridad.tipos_usuarios t
                             WHERE t.id = p_id), false)
           END;
$function$;

COMMENT ON FUNCTION seguridad.fn_tipo_usuario_vigente(integer)
    IS 'Si ese tipo de usuario está vigente hoy (activo y dentro de su rango de fechas)';


-- Y el porqué, para poder decírselo al usuario en vez de un «acceso denegado»
CREATE OR REPLACE FUNCTION seguridad.fn_tipo_usuario_motivo(p_id integer)
RETURNS text
LANGUAGE plpgsql
STABLE
AS $function$
DECLARE
    t record;
BEGIN
    IF p_id IS NULL THEN
        RETURN NULL;   -- sin tipo no hay nada que impida entrar
    END IF;

    SELECT * INTO t FROM seguridad.tipos_usuarios WHERE id = p_id;

    IF NOT FOUND THEN
        RETURN 'Su tipo de usuario no existe. Avise a Sistemas.';
    END IF;

    IF NOT t.activo THEN
        RETURN 'El tipo de usuario «' || t.nombre || '» está dado de baja. Avise a Sistemas.';
    END IF;

    IF t.fecha_inicio IS NOT NULL AND t.fecha_inicio > CURRENT_DATE THEN
        RETURN 'El acceso para «' || t.nombre || '» empieza el ' || to_char(t.fecha_inicio, 'DD/MM/YYYY') || '.';
    END IF;

    IF t.fecha_fin IS NOT NULL AND t.fecha_fin < CURRENT_DATE THEN
        RETURN 'El acceso para «' || t.nombre || '» terminó el ' || to_char(t.fecha_fin, 'DD/MM/YYYY') || '.';
    END IF;

    RETURN NULL;   -- vigente
END;
$function$;

COMMENT ON FUNCTION seguridad.fn_tipo_usuario_motivo(integer)
    IS 'Por qué no está vigente ese tipo, en texto para el usuario. NULL si sí lo está';


-- ---------------------------------------------------------------------------
-- 3. El tipo que viaja con cada usuario, ahora con su vigencia
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION seguridad.fn_tipo_usuario_json(p_id integer)
RETURNS jsonb
LANGUAGE sql
STABLE
AS $function$
    SELECT jsonb_build_object(
               'codigo',       t.codigo,
               'nombre',       t.nombre,
               'icono',        t.icono,
               'color',        t.color,
               'activo',       t.activo,
               'fecha_inicio', to_char(t.fecha_inicio, 'YYYY-MM-DD'),
               'fecha_fin',    to_char(t.fecha_fin, 'YYYY-MM-DD'),
               'vigente',      seguridad.fn_tipo_usuario_vigente(t.id)
           )
      FROM seguridad.tipos_usuarios t WHERE t.id = p_id;
$function$;


-- ---------------------------------------------------------------------------
-- 4. El catálogo para los desplegables
-- ---------------------------------------------------------------------------
-- p_solo_vigentes sirve para el alta de un usuario: no tiene sentido ofrecer un
-- tipo que caducó el mes pasado.
CREATE OR REPLACE FUNCTION seguridad.fn_tipos_usuarios_listar(
    p_incluir_inactivos boolean DEFAULT false,
    p_solo_vigentes     boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
AS $function$
DECLARE
    v_data jsonb;
BEGIN
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'id',           t.id,
               'codigo',       t.codigo,
               'nombre',       t.nombre,
               'descripcion',  t.descripcion,
               'icono',        t.icono,
               'color',        t.color,
               'orden',        t.orden,
               'activo',       t.activo,
               'fecha_inicio', to_char(t.fecha_inicio, 'YYYY-MM-DD'),
               'fecha_fin',    to_char(t.fecha_fin, 'YYYY-MM-DD'),
               'vigente',      seguridad.fn_tipo_usuario_vigente(t.id),
               'en_uso',       (SELECT COUNT(*) FROM seguridad.users u
                                 WHERE u.type_user = t.id AND u.deleted_at IS NULL)
           ) ORDER BY t.orden, t.nombre), '[]'::jsonb) INTO v_data
      FROM seguridad.tipos_usuarios t
     WHERE (p_incluir_inactivos OR t.activo)
       AND (NOT p_solo_vigentes OR seguridad.fn_tipo_usuario_vigente(t.id));

    RETURN jsonb_build_object('success', true, 'message', 'Tipos de usuario obtenidos exitosamente', 'data', v_data);
EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object('success', false,
                                  'message', 'Error al obtener los tipos de usuario: ' || SQLERRM,
                                  'error_code', SQLSTATE);
END;
$function$;


-- ---------------------------------------------------------------------------
-- 5. El listado paginado de la pantalla
-- ---------------------------------------------------------------------------
-- Misma respuesta que fn_horarios_listar_paginado: { data, meta }, que es lo
-- que espera la paginación del front. El filtro va una sola vez en un WHERE
-- con v_busca, en vez de repetir la consulta entera para el caso con búsqueda.
CREATE OR REPLACE FUNCTION seguridad.fn_tipos_usuarios_listar_paginado(
    p_page     integer DEFAULT 1,
    p_per_page integer DEFAULT 15,
    p_search   text    DEFAULT ''::text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
    v_offset integer;
    v_total  bigint;
    v_data   jsonb;
    v_busca  text := NULLIF(TRIM(COALESCE(p_search, '')), '');
BEGIN
    v_offset := (GREATEST(p_page, 1) - 1) * p_per_page;

    SELECT COUNT(*) INTO v_total
      FROM seguridad.tipos_usuarios t
     WHERE (v_busca IS NULL
            OR t.codigo      ILIKE '%' || v_busca || '%'
            OR t.nombre      ILIKE '%' || v_busca || '%'
            OR COALESCE(t.descripcion, '') ILIKE '%' || v_busca || '%'
            OR t.id::text    ILIKE '%' || v_busca || '%');

    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'id',           x.id,
               'codigo',       x.codigo,
               'nombre',       x.nombre,
               'descripcion',  x.descripcion,
               'icono',        x.icono,
               'color',        x.color,
               'orden',        x.orden,
               'activo',       x.activo,
               'fecha_inicio', to_char(x.fecha_inicio, 'YYYY-MM-DD'),
               'fecha_fin',    to_char(x.fecha_fin, 'YYYY-MM-DD'),
               'vigente',      seguridad.fn_tipo_usuario_vigente(x.id),
               'en_uso',       (SELECT COUNT(*) FROM seguridad.users u
                                 WHERE u.type_user = x.id AND u.deleted_at IS NULL),
               'created_at',   to_char(x.created_at, 'YYYY-MM-DD HH24:MI:SS'),
               'updated_at',   to_char(x.updated_at, 'YYYY-MM-DD HH24:MI:SS'),
               'created_by',   x.created_by,
               'updated_by',   x.updated_by
           ) ORDER BY x.orden, x.nombre), '[]'::jsonb) INTO v_data
      FROM (
        SELECT t.*
          FROM seguridad.tipos_usuarios t
         WHERE (v_busca IS NULL
                OR t.codigo      ILIKE '%' || v_busca || '%'
                OR t.nombre      ILIKE '%' || v_busca || '%'
                OR COALESCE(t.descripcion, '') ILIKE '%' || v_busca || '%'
                OR t.id::text    ILIKE '%' || v_busca || '%')
         ORDER BY t.orden, t.nombre
         LIMIT p_per_page OFFSET v_offset
      ) x;

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
        RETURN jsonb_build_object('success', false,
                                  'message', 'Error al listar los tipos de usuario: ' || SQLERRM,
                                  'error_code', SQLSTATE);
END;
$function$;


-- ---------------------------------------------------------------------------
-- 6. Obtener uno
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION seguridad.fn_tipos_usuarios_obtener(p_id integer)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
AS $function$
DECLARE
    v_data jsonb;
BEGIN
    SELECT jsonb_build_object(
               'id',           t.id,
               'codigo',       t.codigo,
               'nombre',       t.nombre,
               'descripcion',  t.descripcion,
               'icono',        t.icono,
               'color',        t.color,
               'orden',        t.orden,
               'activo',       t.activo,
               'fecha_inicio', to_char(t.fecha_inicio, 'YYYY-MM-DD'),
               'fecha_fin',    to_char(t.fecha_fin, 'YYYY-MM-DD'),
               'vigente',      seguridad.fn_tipo_usuario_vigente(t.id),
               'en_uso',       (SELECT COUNT(*) FROM seguridad.users u
                                 WHERE u.type_user = t.id AND u.deleted_at IS NULL),
               'created_at',   to_char(t.created_at, 'YYYY-MM-DD HH24:MI:SS'),
               'updated_at',   to_char(t.updated_at, 'YYYY-MM-DD HH24:MI:SS'),
               'created_by',   t.created_by,
               'updated_by',   t.updated_by
           ) INTO v_data
      FROM seguridad.tipos_usuarios t
     WHERE t.id = p_id;

    IF v_data IS NULL THEN
        RETURN jsonb_build_object('success', false, 'message', 'El tipo de usuario no existe',
                                  'error_code', 'TIPO_NO_EXISTE');
    END IF;

    RETURN jsonb_build_object('success', true, 'message', 'Tipo de usuario obtenido exitosamente', 'data', v_data);
EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object('success', false,
                                  'message', 'Error al obtener el tipo de usuario: ' || SQLERRM,
                                  'error_code', SQLSTATE);
END;
$function$;


-- ---------------------------------------------------------------------------
-- 7. Crear
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION seguridad.fn_tipos_usuarios_crear(
    p_codigo         character varying,
    p_nombre         character varying,
    p_descripcion    text              DEFAULT NULL,
    p_icono          character varying DEFAULT NULL,
    p_color          character varying DEFAULT NULL,
    p_orden          integer           DEFAULT 100,
    p_activo         boolean           DEFAULT true,
    p_fecha_inicio   date              DEFAULT NULL,
    p_fecha_fin      date              DEFAULT NULL,
    p_usuario_id     bigint            DEFAULT NULL,
    p_usuario_login  character varying DEFAULT NULL,
    p_usuario_nombre character varying DEFAULT NULL,
    p_ip_address     inet              DEFAULT NULL,
    p_user_agent     text              DEFAULT NULL,
    p_request_id     uuid              DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
    v_codigo varchar;
    v_id     integer;
BEGIN
    -- Contexto de auditoría
    PERFORM set_config('app.usuario_id',     COALESCE(p_usuario_id::text, ''), true);
    PERFORM set_config('app.usuario_login',  COALESCE(p_usuario_login, current_user), true);
    PERFORM set_config('app.usuario_nombre', COALESCE(p_usuario_nombre, current_user), true);
    PERFORM set_config('app.ip_address',     COALESCE(p_ip_address::text, ''), true);
    PERFORM set_config('app.user_agent',     COALESCE(p_user_agent, ''), true);
    PERFORM set_config('app.request_id',     COALESCE(p_request_id::text, ''), true);
    PERFORM set_config('app.modulo',         'seguridad.tipos_usuarios', true);

    v_codigo := UPPER(TRIM(COALESCE(p_codigo, '')));

    -- Validaciones
    IF v_codigo = '' THEN
        RETURN jsonb_build_object('success', false, 'message', 'El código es obligatorio', 'error_code', 'CODIGO_REQUERIDO');
    END IF;

    IF length(v_codigo) < 3 THEN
        RETURN jsonb_build_object('success', false, 'message', 'El código necesita al menos 3 letras', 'error_code', 'CODIGO_CORTO');
    END IF;

    IF p_nombre IS NULL OR TRIM(p_nombre) = '' THEN
        RETURN jsonb_build_object('success', false, 'message', 'El nombre es obligatorio', 'error_code', 'NOMBRE_REQUERIDO');
    END IF;

    IF EXISTS (SELECT 1 FROM seguridad.tipos_usuarios WHERE codigo = v_codigo) THEN
        RETURN jsonb_build_object('success', false, 'message', 'Ya existe un tipo de usuario con ese código', 'error_code', 'CODIGO_DUPLICADO');
    END IF;

    IF p_fecha_inicio IS NOT NULL AND p_fecha_fin IS NOT NULL AND p_fecha_fin < p_fecha_inicio THEN
        RETURN jsonb_build_object('success', false, 'message', 'La fecha de fin no puede ser anterior a la de inicio', 'error_code', 'VIGENCIA_INVALIDA');
    END IF;

    INSERT INTO seguridad.tipos_usuarios
        (codigo, nombre, descripcion, icono, color, orden, activo, fecha_inicio, fecha_fin)
    VALUES
        (v_codigo, TRIM(p_nombre), NULLIF(TRIM(COALESCE(p_descripcion, '')), ''),
         NULLIF(TRIM(COALESCE(p_icono, '')), ''), NULLIF(TRIM(COALESCE(p_color, '')), ''),
         COALESCE(p_orden, 100), COALESCE(p_activo, true), p_fecha_inicio, p_fecha_fin)
    RETURNING id INTO v_id;

    RETURN seguridad.fn_tipos_usuarios_obtener(v_id)
           || jsonb_build_object('message', 'Tipo de usuario creado exitosamente');
EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object('success', false,
                                  'message', 'Error al crear el tipo de usuario: ' || SQLERRM,
                                  'error_code', SQLSTATE);
END;
$function$;


-- ---------------------------------------------------------------------------
-- 8. Modificar
-- ---------------------------------------------------------------------------
-- Lo que llega NULL se deja como estaba (COALESCE), menos las fechas y la
-- descripción: ahí NULL significa «quitarlo», que es lo que se espera al
-- vaciar el campo en la pantalla. Para distinguirlo se usan dos banderas.
CREATE OR REPLACE FUNCTION seguridad.fn_tipos_usuarios_modificar(
    p_id             integer,
    p_codigo         character varying,
    p_nombre         character varying,
    p_descripcion    text              DEFAULT NULL,
    p_icono          character varying DEFAULT NULL,
    p_color          character varying DEFAULT NULL,
    p_orden          integer           DEFAULT NULL,
    p_activo         boolean           DEFAULT NULL,
    p_fecha_inicio   date              DEFAULT NULL,
    p_fecha_fin      date              DEFAULT NULL,
    p_usuario_id     bigint            DEFAULT NULL,
    p_usuario_login  character varying DEFAULT NULL,
    p_usuario_nombre character varying DEFAULT NULL,
    p_ip_address     inet              DEFAULT NULL,
    p_user_agent     text              DEFAULT NULL,
    p_request_id     uuid              DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
    v_actual record;
    v_codigo varchar;
BEGIN
    PERFORM set_config('app.usuario_id',     COALESCE(p_usuario_id::text, ''), true);
    PERFORM set_config('app.usuario_login',  COALESCE(p_usuario_login, current_user), true);
    PERFORM set_config('app.usuario_nombre', COALESCE(p_usuario_nombre, current_user), true);
    PERFORM set_config('app.ip_address',     COALESCE(p_ip_address::text, ''), true);
    PERFORM set_config('app.user_agent',     COALESCE(p_user_agent, ''), true);
    PERFORM set_config('app.request_id',     COALESCE(p_request_id::text, ''), true);
    PERFORM set_config('app.modulo',         'seguridad.tipos_usuarios', true);

    SELECT * INTO v_actual FROM seguridad.tipos_usuarios WHERE id = p_id;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'message', 'El tipo de usuario no existe', 'error_code', 'TIPO_NO_EXISTE');
    END IF;

    -- Cómo estaba, para el registro de auditoría
    PERFORM set_config('app.datos_anteriores',
                       (seguridad.fn_tipos_usuarios_obtener(p_id) -> 'data')::text, true);

    v_codigo := UPPER(TRIM(COALESCE(p_codigo, v_actual.codigo)));

    IF v_codigo = '' OR length(v_codigo) < 3 THEN
        RETURN jsonb_build_object('success', false, 'message', 'El código necesita al menos 3 letras', 'error_code', 'CODIGO_CORTO');
    END IF;

    IF p_nombre IS NULL OR TRIM(p_nombre) = '' THEN
        RETURN jsonb_build_object('success', false, 'message', 'El nombre es obligatorio', 'error_code', 'NOMBRE_REQUERIDO');
    END IF;

    IF EXISTS (SELECT 1 FROM seguridad.tipos_usuarios WHERE codigo = v_codigo AND id <> p_id) THEN
        RETURN jsonb_build_object('success', false, 'message', 'Ya existe otro tipo de usuario con ese código', 'error_code', 'CODIGO_DUPLICADO');
    END IF;

    IF p_fecha_inicio IS NOT NULL AND p_fecha_fin IS NOT NULL AND p_fecha_fin < p_fecha_inicio THEN
        RETURN jsonb_build_object('success', false, 'message', 'La fecha de fin no puede ser anterior a la de inicio', 'error_code', 'VIGENCIA_INVALIDA');
    END IF;

    UPDATE seguridad.tipos_usuarios
       SET codigo       = v_codigo,
           nombre       = TRIM(p_nombre),
           descripcion  = NULLIF(TRIM(COALESCE(p_descripcion, '')), ''),
           icono        = COALESCE(NULLIF(TRIM(COALESCE(p_icono, '')), ''), icono),
           color        = COALESCE(NULLIF(TRIM(COALESCE(p_color, '')), ''), color),
           orden        = COALESCE(p_orden, orden),
           activo       = COALESCE(p_activo, activo),
           fecha_inicio = p_fecha_inicio,
           fecha_fin    = p_fecha_fin
     WHERE id = p_id;

    RETURN seguridad.fn_tipos_usuarios_obtener(p_id)
           || jsonb_build_object('message', 'Tipo de usuario actualizado exitosamente');
EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object('success', false,
                                  'message', 'Error al modificar el tipo de usuario: ' || SQLERRM,
                                  'error_code', SQLSTATE);
END;
$function$;


-- ---------------------------------------------------------------------------
-- 9. Eliminar
-- ---------------------------------------------------------------------------
-- No se borra un tipo que esté en uso, igual que fn_horarios_eliminar no borra
-- un horario con usuarios: la clave ajena lo impediría de todos modos, pero
-- así el mensaje dice qué pasa y cuántos son. Para retirar uno que se usa está
-- `activo`.
CREATE OR REPLACE FUNCTION seguridad.fn_tipos_usuarios_eliminar(
    p_id             integer,
    p_usuario_id     bigint            DEFAULT NULL,
    p_usuario_login  character varying DEFAULT NULL,
    p_usuario_nombre character varying DEFAULT NULL,
    p_ip_address     inet              DEFAULT NULL,
    p_user_agent     text              DEFAULT NULL,
    p_request_id     uuid              DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
    v_datos   jsonb;
    v_cuantos integer;
BEGIN
    PERFORM set_config('app.usuario_id',     COALESCE(p_usuario_id::text, ''), true);
    PERFORM set_config('app.usuario_login',  COALESCE(p_usuario_login, current_user), true);
    PERFORM set_config('app.usuario_nombre', COALESCE(p_usuario_nombre, current_user), true);
    PERFORM set_config('app.ip_address',     COALESCE(p_ip_address::text, ''), true);
    PERFORM set_config('app.user_agent',     COALESCE(p_user_agent, ''), true);
    PERFORM set_config('app.request_id',     COALESCE(p_request_id::text, ''), true);
    PERFORM set_config('app.modulo',         'seguridad.tipos_usuarios', true);

    IF NOT EXISTS (SELECT 1 FROM seguridad.tipos_usuarios WHERE id = p_id) THEN
        RETURN jsonb_build_object('success', false, 'message', 'El tipo de usuario no existe', 'error_code', 'TIPO_NO_EXISTE');
    END IF;

    SELECT COUNT(*) INTO v_cuantos FROM seguridad.users WHERE type_user = p_id;
    IF v_cuantos > 0 THEN
        RETURN jsonb_build_object('success', false,
            'message', 'No se puede eliminar: ' || v_cuantos || ' usuario(s) tienen este tipo. Desactívelo en vez de borrarlo.',
            'error_code', 'TIENE_USUARIOS');
    END IF;

    v_datos := seguridad.fn_tipos_usuarios_obtener(p_id) -> 'data';
    PERFORM set_config('app.datos_anteriores', v_datos::text, true);

    DELETE FROM seguridad.tipos_usuarios WHERE id = p_id;

    RETURN jsonb_build_object('success', true, 'message', 'Tipo de usuario eliminado exitosamente', 'data', v_datos);
EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object('success', false,
                                  'message', 'Error al eliminar el tipo de usuario: ' || SQLERRM,
                                  'error_code', SQLSTATE);
END;
$function$;


-- ---------------------------------------------------------------------------
-- COMPROBACIÓN
-- ---------------------------------------------------------------------------
SELECT t.id, t.codigo, t.nombre, t.activo, t.fecha_inicio, t.fecha_fin,
       seguridad.fn_tipo_usuario_vigente(t.id) AS vigente,
       seguridad.fn_tipo_usuario_motivo(t.id)  AS motivo
  FROM seguridad.tipos_usuarios t ORDER BY t.orden, t.id;
