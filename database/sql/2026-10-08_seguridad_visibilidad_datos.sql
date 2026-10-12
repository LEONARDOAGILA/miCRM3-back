-- ===========================================================================
-- QUÉ PUEDE VER CADA PERFIL DENTRO DE UN CLIENTE
-- ===========================================================================
-- Fecha: 2026-10-08
-- Se aplica después de 2026-10-08_ventas_dueno_de_notas_y_archivos.sql.
--
-- Hasta ahora la seguridad contestaba a UNA pregunta: «¿puedo entrar a este
-- cliente?» (la jerarquía de grupos, ver fn_usuarios_a_cargo). Dentro del
-- cliente no había nada: el que entraba lo veía todo. Esto añade la segunda
-- pregunta: «de lo que hay dentro, ¿qué me toca ver?».
--
-- LA REGLA ES POR PERFIL Y POR TIPO DE DATO, con cuatro alcances:
--
--   PROPIO     sólo lo que creó uno mismo
--   MI_PERFIL  lo de quienes tienen su mismo perfil, y lo suyo
--   A_CARGO    lo suyo y lo de los grupos por debajo del suyo
--   TODO       todo lo del cliente
--
-- MI_PERFIL Y NO «MI ROL EN EL CLIENTE», que era la idea inicial. El rol
-- (VENDEDOR, COBRADOR, ASISTENTE) vive en la asignación del cliente, no en la
-- fila: para saber con qué rol se escribió una gestión de hace un año habría
-- que reconstruir quién era qué ese día, y en cuanto el cliente se reasigna el
-- vendedor nuevo pierde de vista todo el historial del anterior. El perfil vive
-- en el usuario, no cambia al mover la cartera, y responde igual a lo que se
-- quería: «los vendedores no ven lo de los cobradores» es, en la práctica, dos
-- perfiles distintos.
--
-- SE INSTALA SIN CAMBIAR NADA. El alcance por defecto —cuando un perfil no
-- tiene fila para un dato— es TODO, que es lo que pasa hoy. Nadie deja de ver
-- nada hasta que alguien aprieta un perfil a mano. Apagar visibilidad de golpe
-- a sesenta personas es la forma más rápida de que te pidan desactivarlo todo.
--
-- LOS ADMINISTRADORES VEN TODO, sin mirar la tabla: su grupo ya lo dice
-- (seguridad.grupos.es_administrador) y es la misma puerta por la que ya ven
-- todos los clientes.
--
-- Idempotente.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- 1. La tabla
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS seguridad.visibilidad_datos (
    id         bigserial    NOT NULL,
    perfil_id  bigint       NOT NULL,

    /** GESTION, NOTA, ARCHIVO, WHATSAPP */
    dato       varchar(20)  NOT NULL,
    /** PROPIO, MI_PERFIL, A_CARGO, TODO */
    alcance    varchar(20)  NOT NULL DEFAULT 'TODO',

    created_at timestamptz           DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamptz           DEFAULT CURRENT_TIMESTAMP,
    created_by varchar(100),
    updated_by varchar(100),

    CONSTRAINT pk_visibilidad_datos      PRIMARY KEY (id),
    CONSTRAINT uq_visibilidad_datos      UNIQUE (perfil_id, dato),
    CONSTRAINT fk_visibilidad_datos_perf FOREIGN KEY (perfil_id)
        REFERENCES seguridad.perfiles(id) ON DELETE CASCADE,
    CONSTRAINT ck_visibilidad_datos_dato
        CHECK (dato IN ('GESTION', 'NOTA', 'ARCHIVO', 'WHATSAPP')),
    CONSTRAINT ck_visibilidad_datos_alc
        CHECK (alcance IN ('PROPIO', 'MI_PERFIL', 'A_CARGO', 'TODO'))
);

COMMENT ON TABLE seguridad.visibilidad_datos
    IS 'Qué alcance tiene cada perfil sobre cada tipo de dato dentro de un cliente. Sin fila: TODO';


-- ---------------------------------------------------------------------------
-- 2. El alcance de un usuario para un dato
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION seguridad.fn_alcance(p_usuario_id bigint, p_dato varchar)
RETURNS varchar
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
AS $function$
DECLARE
    v_admin   boolean := false;
    v_perfil  bigint;
    v_alcance varchar;
BEGIN
    IF p_usuario_id IS NULL THEN
        RETURN 'PROPIO';   -- sin sesión no se ve nada de nadie
    END IF;

    SELECT COALESCE(g.es_administrador, false), u.perfil_id
      INTO v_admin, v_perfil
      FROM seguridad.users u
      LEFT JOIN seguridad.grupos g ON g.id = u.grupo_id
     WHERE u.id = p_usuario_id;

    IF v_admin THEN
        RETURN 'TODO';
    END IF;

    SELECT v.alcance INTO v_alcance
      FROM seguridad.visibilidad_datos v
     WHERE v.perfil_id = v_perfil
       AND v.dato = UPPER(p_dato);

    -- Sin fila, como hoy
    RETURN COALESCE(v_alcance, 'TODO');
END;
$function$;

COMMENT ON FUNCTION seguridad.fn_alcance(bigint, varchar)
    IS 'PROPIO | MI_PERFIL | A_CARGO | TODO para ese usuario y ese tipo de dato';


-- ---------------------------------------------------------------------------
-- 3. De qué usuarios puede ver las filas
-- ---------------------------------------------------------------------------
-- Devuelve NULL cuando el alcance es TODO. NULL significa «sin filtro», y es a
-- propósito: así quien consulta escribe
--
--     WHERE v_usuarios IS NULL OR x.usuario_id = ANY(v_usuarios)
--
-- y no tiene que armar una lista con los sesenta usuarios de la empresa cada
-- vez que alguien abre una ficha.
CREATE OR REPLACE FUNCTION seguridad.fn_usuarios_visibles(p_usuario_id bigint, p_dato varchar)
RETURNS bigint[]
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
AS $function$
DECLARE
    v_alcance varchar;
    v_perfil  bigint;
BEGIN
    v_alcance := seguridad.fn_alcance(p_usuario_id, p_dato);

    IF v_alcance = 'TODO' THEN
        RETURN NULL;
    END IF;

    IF p_usuario_id IS NULL THEN
        RETURN '{}'::bigint[];
    END IF;

    IF v_alcance = 'PROPIO' THEN
        RETURN ARRAY[p_usuario_id];
    END IF;

    IF v_alcance = 'A_CARGO' THEN
        RETURN ventas.fn_usuarios_a_cargo(p_usuario_id);
    END IF;

    -- MI_PERFIL: los de su mismo perfil, y él (por si se quedó sin perfil)
    SELECT u.perfil_id INTO v_perfil FROM seguridad.users u WHERE u.id = p_usuario_id;

    RETURN ARRAY(
        SELECT u.id FROM seguridad.users u
         WHERE u.deleted_at IS NULL
           AND (u.id = p_usuario_id OR (v_perfil IS NOT NULL AND u.perfil_id = v_perfil))
    );
END;
$function$;

COMMENT ON FUNCTION seguridad.fn_usuarios_visibles(bigint, varchar)
    IS 'De qué usuarios puede ver las filas de ese dato. NULL = sin filtro (TODO)';


-- ---------------------------------------------------------------------------
-- COMPROBACIÓN
-- ---------------------------------------------------------------------------
-- Con la tabla vacía, todo el mundo sigue viéndolo todo:
--
--   SELECT u.login_user,
--          seguridad.fn_alcance(u.id, 'GESTION')          AS alcance,
--          seguridad.fn_usuarios_visibles(u.id, 'GESTION') AS usuarios
--     FROM seguridad.users u WHERE u.login_user IN ('LAGILA', 'VCUENCA1');
