-- ===========================================================================
-- PLAN DE CUENTAS (contabilidad.plan_cuentas)
-- ===========================================================================
-- El árbol de cuentas contables. Es el mismo árbol de inventarios.categorias
-- —padre, orden, nivel, papelera, auditoría— con dos diferencias:
--
--   · NO TIENE TOPE DE NIVELES. Aquél admite cuatro (0 a 3); aquí no hay
--     ninguno. Una empresa que necesite 1.1.01.001.0001 lo necesita de verdad,
--     y poner un techo sólo obliga a inventarse códigos.
--
--   · LLEVA LO QUE UNA CUENTA ES. El código, el tipo y la naturaleza no son
--     adornos: de ellos salen el balance, el estado de resultados y de qué
--     lado suma cada asiento.
--
-- LAS COLUMNAS, Y POR QUÉ
--
--   codigo         La espina dorsal del plan: «1.1.01.001». Es por donde se
--                  busca, por donde se ordena y lo que se teclea en un
--                  asiento. Único en todo el plan.
--   nombre         Cómo se lee la cuenta.
--   tipo           ACTIVO, PASIVO, PATRIMONIO, INGRESO, COSTO, GASTO, ORDEN.
--                  Es lo que decide en qué informe sale.
--   naturaleza     DEUDORA o ACREEDORA: de qué lado aumenta. No se deduce del
--                  tipo porque las de valuación van al revés —«depreciación
--                  acumulada» es de activo y acreedora—, así que se guarda.
--   es_movimiento  Si admite asientos. Sólo las hojas; las de arriba agrupan.
--                  Es el `es_transaccion` de categorías con otro nombre.
--   descripcion    Para qué se usa, que en un plan heredado no es evidente.
--
-- No lleva `icono`, que sí tiene categorías: en una cuenta el código y el tipo
-- ya dicen lo que es, y un icono por cuenta sería ruido en un árbol de cientos.
\set ON_ERROR_STOP on

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. LA TABLA
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS contabilidad.plan_cuentas (
    id            bigserial     PRIMARY KEY,
    padre_id      bigint,
    orden         integer       NOT NULL DEFAULT 1,
    -- Sin CHECK de tope: el árbol crece lo que haga falta
    nivel         integer       NOT NULL DEFAULT 0,

    codigo        varchar(30)   NOT NULL,
    nombre        varchar(150)  NOT NULL,
    descripcion   text,

    tipo          varchar(15)   NOT NULL,
    naturaleza    varchar(10)   NOT NULL,
    es_movimiento boolean       NOT NULL DEFAULT false,

    activo        boolean       NOT NULL DEFAULT true,

    created_at    timestamptz   NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at    timestamptz   NOT NULL DEFAULT CURRENT_TIMESTAMP,
    created_by    varchar(100),
    updated_by    varchar(100),
    deleted_at    timestamptz,
    deleted_by    varchar(100),

    CONSTRAINT fk_plan_cuentas_padre FOREIGN KEY (padre_id)
        REFERENCES contabilidad.plan_cuentas(id),
    CONSTRAINT ck_plan_cuentas_no_padre_si_misma CHECK (padre_id IS NULL OR padre_id <> id),
    CONSTRAINT ck_plan_cuentas_nivel      CHECK (nivel >= 0),
    CONSTRAINT ck_plan_cuentas_codigo     CHECK (length(TRIM(codigo)) >= 1),
    CONSTRAINT ck_plan_cuentas_nombre     CHECK (length(TRIM(nombre)) >= 2),
    CONSTRAINT ck_plan_cuentas_tipo       CHECK (tipo IN ('ACTIVO','PASIVO','PATRIMONIO','INGRESO','COSTO','GASTO','ORDEN')),
    CONSTRAINT ck_plan_cuentas_naturaleza CHECK (naturaleza IN ('DEUDORA','ACREEDORA'))
);

COMMENT ON TABLE  contabilidad.plan_cuentas IS 'Árbol de cuentas contables, sin tope de niveles';
COMMENT ON COLUMN contabilidad.plan_cuentas.codigo IS 'El código de la cuenta: 1.1.01.001. Único en todo el plan, papelera incluida';
COMMENT ON COLUMN contabilidad.plan_cuentas.naturaleza IS 'De qué lado aumenta; no se deduce del tipo por las cuentas de valuación';
COMMENT ON COLUMN contabilidad.plan_cuentas.es_movimiento IS 'true = admite asientos. Sólo las hojas; las de arriba agrupan';

-- El código, único en todo el plan; y el nombre, único entre hermanas. Los
-- tres cuentan TAMBIÉN a las que están en la papelera, igual que en
-- inventarios.categorias: así una cuenta que se restaura siempre encuentra
-- libres su código y su nombre, que es lo que no puede fallar. El precio es
-- que un código borrado sigue ocupado, y por eso los mensajes de error lo
-- dicen en lugar de dejar al usuario mirando un árbol donde ese código no
-- aparece.
CREATE UNIQUE INDEX IF NOT EXISTS uq_plan_cuentas_codigo
    ON contabilidad.plan_cuentas (UPPER(TRIM(codigo)));
CREATE UNIQUE INDEX IF NOT EXISTS uq_plan_cuentas_nombre_hermana
    ON contabilidad.plan_cuentas (padre_id, UPPER(TRIM(nombre))) WHERE padre_id IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS uq_plan_cuentas_nombre_raiz
    ON contabilidad.plan_cuentas (UPPER(TRIM(nombre))) WHERE padre_id IS NULL;

CREATE INDEX IF NOT EXISTS ix_plan_cuentas_padre ON contabilidad.plan_cuentas (padre_id, orden);
CREATE INDEX IF NOT EXISTS ix_plan_cuentas_tipo  ON contabilidad.plan_cuentas (tipo);
CREATE INDEX IF NOT EXISTS ix_plan_cuentas_papelera
    ON contabilidad.plan_cuentas (deleted_at) WHERE deleted_at IS NOT NULL;

-- ---------------------------------------------------------------------------
-- 2. AUDITORÍA (los tres disparadores de siempre)
-- ---------------------------------------------------------------------------
DROP TRIGGER IF EXISTS trigger_plan_cuentas_set_users  ON contabilidad.plan_cuentas;
DROP TRIGGER IF EXISTS trigger_plan_cuentas_updated_at ON contabilidad.plan_cuentas;
DROP TRIGGER IF EXISTS trg_plan_cuentas_audit          ON contabilidad.plan_cuentas;

CREATE TRIGGER trigger_plan_cuentas_set_users
    BEFORE INSERT OR UPDATE ON contabilidad.plan_cuentas
    FOR EACH ROW EXECUTE FUNCTION auditoria.fn_set_audit_users();
CREATE TRIGGER trigger_plan_cuentas_updated_at
    BEFORE UPDATE ON contabilidad.plan_cuentas
    FOR EACH ROW EXECUTE FUNCTION auditoria.fn_update_updated_at_column();
CREATE TRIGGER trg_plan_cuentas_audit
    AFTER INSERT OR UPDATE OR DELETE ON contabilidad.plan_cuentas
    FOR EACH ROW EXECUTE FUNCTION auditoria.fn_auditar_cambios();

-- ---------------------------------------------------------------------------
-- 3. EL CONTEXTO DE AUDITORÍA DEL ESQUEMA
-- ---------------------------------------------------------------------------
-- La misma de rh, ventas e inventarios: deja en la sesión quién hace el
-- cambio para que lo recojan los disparadores.
CREATE OR REPLACE FUNCTION contabilidad.fn_contexto_auditoria(
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
-- LO PROPIO DEL PLAN DE CUENTAS
-- ---------------------------------------------------------------------------
-- json, crear, modificar, eliminar, eliminar_definitivo y el código sugerido.
-- Estas no son un renombrado de las de categorías: aquí entran el código, el
-- tipo y la naturaleza, y las reglas del árbol contable —el tipo se hereda y
-- sólo las hojas reciben asientos— que en categorías no existen.

-- ---------------------------------------------------------------------------
-- La ficha de una cuenta
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION contabilidad.fn_plan_cuentas_json(p_id bigint)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
AS $function$
    WITH RECURSIVE subida AS (
        SELECT c.id, c.padre_id, c.codigo, c.nombre, 0 AS salto
          FROM contabilidad.plan_cuentas c WHERE c.id = p_id
        UNION ALL
        SELECT p.id, p.padre_id, p.codigo, p.nombre, s.salto + 1
          FROM contabilidad.plan_cuentas p JOIN subida s ON p.id = s.padre_id
    )
    SELECT jsonb_build_object(
        'id',            c.id,
        'padre_id',      c.padre_id,
        'padre_codigo',  (SELECT x.codigo FROM contabilidad.plan_cuentas x WHERE x.id = c.padre_id),
        'padre_nombre',  (SELECT x.nombre FROM contabilidad.plan_cuentas x WHERE x.id = c.padre_id),
        'orden',         c.orden,
        'nivel',         c.nivel,
        'codigo',        c.codigo,
        'nombre',        c.nombre,
        -- Dos rutas desde la raíz: la de nombres es la que se lee, y la de
        -- códigos la que identifica sin ambigüedad en la papelera
        'ruta',          (SELECT string_agg(s.nombre, ' > ' ORDER BY s.salto DESC) FROM subida s),
        'ruta_codigo',   (SELECT string_agg(s.codigo, ' > ' ORDER BY s.salto DESC) FROM subida s),
        'descripcion',   c.descripcion,
        'tipo',          c.tipo,
        'naturaleza',    c.naturaleza,
        -- true = recibe asientos. Las de arriba del árbol agrupan y no deben
        -- salir en el selector de cuentas de un asiento.
        'es_movimiento', c.es_movimiento,
        'activo',        c.activo,
        'num_hijos',     (SELECT COUNT(*) FROM contabilidad.plan_cuentas h WHERE h.padre_id = c.id AND h.deleted_at IS NULL),
        -- La papelera: NULL mientras la cuenta está vigente
        'deleted_at',    to_char(c.deleted_at, 'YYYY-MM-DD HH24:MI:SS'),
        'deleted_by',    c.deleted_by,

        'created_by',    c.created_by,
        'updated_by',    c.updated_by,
        'created_at',    to_char(c.created_at, 'YYYY-MM-DD HH24:MI:SS'),
        'updated_at',    to_char(c.updated_at, 'YYYY-MM-DD HH24:MI:SS')
    )
      FROM contabilidad.plan_cuentas c
     WHERE c.id = p_id;
$function$;

-- ---------------------------------------------------------------------------
-- El siguiente código libre bajo una cuenta
-- ---------------------------------------------------------------------------
-- En un plan de cuentas el código no se inventa: sigue al del padre y al de
-- la última hermana. De aquí salen dos cosas: el código con el que se abre la
-- ficha de una cuenta nueva, y el que se le pone a una cuenta cuando se la
-- mueve a otra rama (ver fn_plan_cuentas_mover).
--
-- `p_excluir` es la cuenta que se está moviendo: al calcular su nuevo código
-- no debe contarse a sí misma entre las hermanas, porque todavía lleva el de
-- la rama de la que viene.
CREATE OR REPLACE FUNCTION contabilidad.fn_plan_cuentas_codigo_libre(
    p_padre_id bigint DEFAULT NULL::bigint,
    p_excluir bigint DEFAULT NULL::bigint)
 RETURNS character varying
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'contabilidad'
AS $function$
DECLARE
    v_padre   varchar;
    v_ultimo  varchar;
    v_cola    varchar;
    v_ancho   integer;
    v_sig     varchar;
    v_i       integer := 0;
BEGIN
    IF p_padre_id IS NOT NULL THEN
        SELECT codigo INTO v_padre FROM contabilidad.plan_cuentas WHERE id = p_padre_id;
        IF v_padre IS NULL THEN RETURN NULL; END IF;
    END IF;

    -- La hermana de código más alto, comparando por el último tramo como
    -- número: en texto, '10' iría antes de '9'
    SELECT codigo INTO v_ultimo
      FROM contabilidad.plan_cuentas
     WHERE padre_id IS NOT DISTINCT FROM p_padre_id
       AND (p_excluir IS NULL OR id <> p_excluir)
       AND codigo ~ '[0-9]+$'
     ORDER BY (regexp_replace(codigo, '^.*[^0-9]', ''))::numeric DESC, codigo DESC
     LIMIT 1;

    IF v_ultimo IS NULL THEN
        -- Primera hija: se arranca en 1 con el ancho de los tramos del padre
        -- (1.1 -> 1.1.1; 1.1.01 -> 1.1.01.01)
        v_ancho := COALESCE(NULLIF(length(regexp_replace(COALESCE(v_padre, ''), '^.*[^0-9]', '')), 0), 1);
        v_cola  := LPAD('1', v_ancho, '0');
    ELSE
        -- Uno más que la última, conservando el ancho
        v_cola  := regexp_replace(v_ultimo, '^.*[^0-9]', '');
        v_ancho := GREATEST(length(v_cola), 1);
        v_cola  := LPAD((v_cola::numeric + 1)::text, v_ancho, '0');
    END IF;

    v_sig := CASE WHEN v_padre IS NULL THEN v_cola ELSE v_padre || '.' || v_cola END;

    -- Y si ese código ya está cogido —por una cuenta de otra rama, o por una
    -- que está en la papelera, que también lo reserva— se sigue subiendo. El
    -- tope de 500 es para que un plan raro no deje esto dando vueltas.
    WHILE v_i < 500
          AND EXISTS (SELECT 1 FROM contabilidad.plan_cuentas
                       WHERE UPPER(TRIM(codigo)) = UPPER(v_sig)
                         AND (p_excluir IS NULL OR id <> p_excluir)) LOOP
        v_i    := v_i + 1;
        v_cola := LPAD((v_cola::numeric + 1)::text, v_ancho, '0');
        v_sig  := CASE WHEN v_padre IS NULL THEN v_cola ELSE v_padre || '.' || v_cola END;
    END LOOP;

    RETURN v_sig;
END;
$function$;

-- Lo mismo, envuelto para la pantalla
CREATE OR REPLACE FUNCTION contabilidad.fn_plan_cuentas_codigo_sugerido(p_padre_id bigint DEFAULT NULL::bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'contabilidad'
AS $function$
DECLARE
    v_codigo varchar;
BEGIN
    IF p_padre_id IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM contabilidad.plan_cuentas WHERE id = p_padre_id) THEN
        RETURN jsonb_build_object('success', false, 'message', 'La cuenta padre no existe');
    END IF;

    v_codigo := contabilidad.fn_plan_cuentas_codigo_libre(p_padre_id, NULL);

    RETURN jsonb_build_object('success', true,
        'data', jsonb_build_object('codigo', v_codigo));
END;
$function$;

-- ---------------------------------------------------------------------------
-- Crear
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION contabilidad.fn_plan_cuentas_crear(
    p_codigo character varying,
    p_nombre character varying,
    p_tipo character varying DEFAULT NULL::character varying,
    p_naturaleza character varying DEFAULT NULL::character varying,
    p_padre_id bigint DEFAULT NULL::bigint,
    p_descripcion text DEFAULT NULL::text,
    p_activo boolean DEFAULT true,
    p_es_movimiento boolean DEFAULT true,
    p_usuario_id bigint DEFAULT NULL::bigint,
    p_usuario_login character varying DEFAULT NULL::character varying,
    p_usuario_nombre character varying DEFAULT NULL::character varying,
    p_ip_address inet DEFAULT NULL::inet,
    p_user_agent text DEFAULT NULL::text,
    p_request_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'contabilidad', 'auditoria'
AS $function$
DECLARE
    v_id         bigint;
    v_nivel      integer := 0;
    v_orden      integer;
    -- El padre, en variables sueltas y no en un `record`: en una cuenta raíz
    -- no hay padre, y un record sin asignar revienta en cuanto una expresión
    -- lo menciona, aunque sea detrás de un AND que debería cortar antes.
    v_padre_nivel  integer;
    v_padre_codigo varchar;
    v_padre_nombre varchar;
    v_padre_tipo   varchar;
    v_padre_mov    boolean;
    v_tipo       varchar;
    v_naturaleza varchar;
    v_nuevo      jsonb;
BEGIN
    PERFORM contabilidad.fn_contexto_auditoria('contabilidad.plan_cuentas',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    IF p_codigo IS NULL OR length(TRIM(p_codigo)) < 1 THEN
        RAISE EXCEPTION 'El código de la cuenta es obligatorio' USING ERRCODE = 'P0001';
    END IF;
    IF TRIM(p_codigo) !~ '^[0-9A-Za-z]([0-9A-Za-z._-]*[0-9A-Za-z])?$' THEN
        RAISE EXCEPTION 'El código sólo admite letras, números, puntos, guiones y rayas bajas, y no puede empezar ni acabar en separador'
            USING ERRCODE = 'P0001';
    END IF;
    IF p_nombre IS NULL OR length(TRIM(p_nombre)) < 2 THEN
        RAISE EXCEPTION 'El nombre de la cuenta es obligatorio (mínimo 2 caracteres)' USING ERRCODE = 'P0001';
    END IF;

    -- El tipo y la naturaleza se heredan del padre si no vienen: una subcuenta
    -- de ACTIVO es de ACTIVO, y así la ficha de una hija no obliga a repetirlo
    IF p_padre_id IS NOT NULL THEN
        SELECT nivel, codigo, nombre, tipo, es_movimiento
          INTO v_padre_nivel, v_padre_codigo, v_padre_nombre, v_padre_tipo, v_padre_mov
          FROM contabilidad.plan_cuentas WHERE id = p_padre_id;
        IF v_padre_nivel IS NULL THEN
            RAISE EXCEPTION 'La cuenta padre no existe' USING ERRCODE = 'P0016';
        END IF;
        -- Sin tope de niveles a propósito: el plan de cuentas crece lo que la
        -- empresa necesite
        v_nivel      := v_padre_nivel + 1;
        v_tipo       := COALESCE(NULLIF(TRIM(COALESCE(p_tipo, '')), ''), v_padre_tipo);
        v_naturaleza := NULLIF(TRIM(COALESCE(p_naturaleza, '')), '');

        -- El tipo manda en qué informe sale la cuenta: un GASTO colgado de
        -- ACTIVO descuadraría el balance y el estado de resultados a la vez
        IF v_tipo <> v_padre_tipo THEN
            RAISE EXCEPTION 'La cuenta «%» es de tipo % y una subcuenta suya no puede ser de tipo %',
                  v_padre_codigo || ' ' || v_padre_nombre, v_padre_tipo, v_tipo
                USING ERRCODE = 'P0022';
        END IF;

        -- UNA CUENTA DE MOVIMIENTO NO ADMITE SUBCUENTAS. Recibe asientos, así
        -- que tiene saldo propio; colgarle algo debajo obligaría a decidir qué
        -- pasa con ese saldo —se queda, se reparte, se traslada—, y eso no se
        -- resuelve solo. Primero se le quita «recibe asientos» en su ficha, que
        -- es una decisión consciente, y después se le cuelgan subcuentas.
        IF COALESCE(v_padre_mov, false) THEN
            RAISE EXCEPTION 'La cuenta «%» recibe asientos y por eso no admite subcuentas. Quítele «recibe asientos» en su ficha y vuelva a intentarlo.',
                  v_padre_codigo || ' ' || v_padre_nombre
                USING ERRCODE = 'P0021';
        END IF;
    ELSE
        v_tipo       := NULLIF(TRIM(COALESCE(p_tipo, '')), '');
        v_naturaleza := NULLIF(TRIM(COALESCE(p_naturaleza, '')), '');
        IF v_tipo IS NULL THEN
            RAISE EXCEPTION 'El tipo de la cuenta es obligatorio' USING ERRCODE = 'P0001';
        END IF;
    END IF;

    -- La naturaleza no se deduce del tipo: las de valuación van al revés
    -- —«(-) Depreciación acumulada» es de ACTIVO y ACREEDORA—, así que si no
    -- viene se toma la del tipo como punto de partida y se puede cambiar.
    IF v_naturaleza IS NULL THEN
        v_naturaleza := CASE WHEN v_tipo IN ('ACTIVO', 'COSTO', 'GASTO') THEN 'DEUDORA' ELSE 'ACREEDORA' END;
    END IF;
    IF v_tipo NOT IN ('ACTIVO','PASIVO','PATRIMONIO','INGRESO','COSTO','GASTO','ORDEN') THEN
        RAISE EXCEPTION 'Tipo de cuenta no válido: %', v_tipo USING ERRCODE = 'P0001';
    END IF;
    IF v_naturaleza NOT IN ('DEUDORA','ACREEDORA') THEN
        RAISE EXCEPTION 'Naturaleza no válida: %', v_naturaleza USING ERRCODE = 'P0001';
    END IF;

    -- El código no se repite en TODO el plan
    IF EXISTS (SELECT 1 FROM contabilidad.plan_cuentas
                WHERE UPPER(TRIM(codigo)) = UPPER(TRIM(p_codigo))) THEN
        -- Puede estar en la papelera: el índice único también cuenta a las
        -- eliminadas, y sin decirlo el mensaje desconcierta porque ese código
        -- no aparece en el árbol.
        IF EXISTS (SELECT 1 FROM contabilidad.plan_cuentas
                    WHERE UPPER(TRIM(codigo)) = UPPER(TRIM(p_codigo)) AND deleted_at IS NOT NULL) THEN
            RAISE EXCEPTION 'Ya existe una cuenta con el código «%», y está en la papelera de reciclaje', TRIM(p_codigo)
                USING ERRCODE = 'P0006';
        END IF;
        RAISE EXCEPTION 'Ya existe una cuenta con el código «%»', TRIM(p_codigo) USING ERRCODE = 'P0006';
    END IF;

    -- Entre hermanas el nombre no se repite; en otra rama sí puede
    IF EXISTS (SELECT 1 FROM contabilidad.plan_cuentas
                WHERE padre_id IS NOT DISTINCT FROM p_padre_id
                  AND UPPER(TRIM(nombre)) = UPPER(TRIM(p_nombre))) THEN
        IF EXISTS (SELECT 1 FROM contabilidad.plan_cuentas
                    WHERE padre_id IS NOT DISTINCT FROM p_padre_id
                      AND UPPER(TRIM(nombre)) = UPPER(TRIM(p_nombre))
                      AND deleted_at IS NOT NULL) THEN
            RAISE EXCEPTION 'Ya existe una cuenta con ese nombre en el mismo nivel, y está en la papelera de reciclaje' USING ERRCODE = 'P0006';
        END IF;
        RAISE EXCEPTION 'Ya existe una cuenta con ese nombre en el mismo nivel' USING ERRCODE = 'P0006';
    END IF;

    -- Al final de sus hermanas, sin pisar el orden de las que ya están
    SELECT COALESCE(MAX(orden), 0) + 1 INTO v_orden
      FROM contabilidad.plan_cuentas WHERE padre_id IS NOT DISTINCT FROM p_padre_id;

    v_nuevo := jsonb_build_object(
        'padre_id',      p_padre_id,
        'nivel',         v_nivel,
        'orden',         v_orden,
        'codigo',        TRIM(p_codigo),
        'nombre',        TRIM(p_nombre),
        'descripcion',   NULLIF(TRIM(COALESCE(p_descripcion, '')), ''),
        'tipo',          v_tipo,
        'naturaleza',    v_naturaleza,
        'activo',        COALESCE(p_activo, true),
        'es_movimiento', COALESCE(p_es_movimiento, true)
    );
    PERFORM set_config('app.datos_nuevos', v_nuevo::text, true);

    INSERT INTO contabilidad.plan_cuentas
        (padre_id, orden, nivel, codigo, nombre, descripcion, tipo, naturaleza, activo, es_movimiento)
    VALUES (
        p_padre_id, v_orden, v_nivel,
        TRIM(p_codigo),
        TRIM(p_nombre),
        NULLIF(TRIM(COALESCE(p_descripcion, '')), ''),
        v_tipo, v_naturaleza,
        COALESCE(p_activo, true),
        COALESCE(p_es_movimiento, true)
    )
    RETURNING id INTO v_id;

    PERFORM set_config('app.datos_nuevos', '', true);

    RETURN jsonb_build_object('success', true,
        'message', 'Cuenta creada exitosamente',
        'data', contabilidad.fn_plan_cuentas_json(v_id));

EXCEPTION
    WHEN unique_violation THEN
        RAISE EXCEPTION 'Ya existe una cuenta con ese código o con ese nombre en el mismo nivel (puede estar en la papelera de reciclaje)' USING ERRCODE = 'P0006';
END;
$function$;

-- ---------------------------------------------------------------------------
-- Modificar
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION contabilidad.fn_plan_cuentas_modificar(
    p_id bigint,
    p_codigo character varying,
    p_nombre character varying,
    p_tipo character varying DEFAULT NULL::character varying,
    p_naturaleza character varying DEFAULT NULL::character varying,
    p_descripcion text DEFAULT NULL::text,
    p_activo boolean DEFAULT true,
    p_es_movimiento boolean DEFAULT true,
    p_usuario_id bigint DEFAULT NULL::bigint,
    p_usuario_login character varying DEFAULT NULL::character varying,
    p_usuario_nombre character varying DEFAULT NULL::character varying,
    p_ip_address inet DEFAULT NULL::inet,
    p_user_agent text DEFAULT NULL::text,
    p_request_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'contabilidad', 'auditoria'
AS $function$
DECLARE
    v_actual     record;
    v_antes      jsonb;
    v_tipo       varchar;
    v_naturaleza varchar;
    v_hijos      bigint;
    v_usos       bigint;
    v_donde      text;
    v_cascada    integer := 0;
    v_nuevo      jsonb;
BEGIN
    PERFORM contabilidad.fn_contexto_auditoria('contabilidad.plan_cuentas',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    SELECT id, padre_id, tipo, nombre INTO v_actual
      FROM contabilidad.plan_cuentas WHERE id = p_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'La cuenta no existe' USING ERRCODE = 'P0013';
    END IF;
    v_antes := contabilidad.fn_plan_cuentas_json(p_id);

    IF p_codigo IS NULL OR length(TRIM(p_codigo)) < 1 THEN
        RAISE EXCEPTION 'El código de la cuenta es obligatorio' USING ERRCODE = 'P0001';
    END IF;
    IF TRIM(p_codigo) !~ '^[0-9A-Za-z]([0-9A-Za-z._-]*[0-9A-Za-z])?$' THEN
        RAISE EXCEPTION 'El código sólo admite letras, números, puntos, guiones y rayas bajas, y no puede empezar ni acabar en separador'
            USING ERRCODE = 'P0001';
    END IF;
    IF p_nombre IS NULL OR length(TRIM(p_nombre)) < 2 THEN
        RAISE EXCEPTION 'El nombre de la cuenta es obligatorio (mínimo 2 caracteres)' USING ERRCODE = 'P0001';
    END IF;

    v_tipo       := COALESCE(NULLIF(TRIM(COALESCE(p_tipo, '')), ''), v_actual.tipo);
    v_naturaleza := COALESCE(NULLIF(TRIM(COALESCE(p_naturaleza, '')), ''), v_antes->>'naturaleza');
    IF v_tipo NOT IN ('ACTIVO','PASIVO','PATRIMONIO','INGRESO','COSTO','GASTO','ORDEN') THEN
        RAISE EXCEPTION 'Tipo de cuenta no válido: %', v_tipo USING ERRCODE = 'P0001';
    END IF;
    IF v_naturaleza NOT IN ('DEUDORA','ACREEDORA') THEN
        RAISE EXCEPTION 'Naturaleza no válida: %', v_naturaleza USING ERRCODE = 'P0001';
    END IF;

    -- Una subcuenta no puede cambiar de tipo por su cuenta: el tipo es el del
    -- padre y se cambia arriba, de donde baja en cascada
    IF v_actual.padre_id IS NOT NULL AND v_tipo <> v_actual.tipo THEN
        RAISE EXCEPTION 'El tipo de una subcuenta es el de su cuenta padre («%»). Cámbielo en la cuenta de arriba y bajará a toda la rama.',
              (SELECT codigo || ' ' || nombre FROM contabilidad.plan_cuentas WHERE id = v_actual.padre_id)
            USING ERRCODE = 'P0022';
    END IF;

    IF EXISTS (SELECT 1 FROM contabilidad.plan_cuentas
                WHERE UPPER(TRIM(codigo)) = UPPER(TRIM(p_codigo)) AND id <> p_id) THEN
        RAISE EXCEPTION 'Ya existe otra cuenta con el código «%» (puede estar en la papelera de reciclaje)', TRIM(p_codigo)
            USING ERRCODE = 'P0006';
    END IF;
    IF EXISTS (SELECT 1 FROM contabilidad.plan_cuentas
                WHERE padre_id IS NOT DISTINCT FROM v_actual.padre_id
                  AND UPPER(TRIM(nombre)) = UPPER(TRIM(p_nombre))
                  AND id <> p_id) THEN
        RAISE EXCEPTION 'Ya existe otra cuenta con ese nombre en el mismo nivel' USING ERRCODE = 'P0006';
    END IF;

    -- Una cuenta con subcuentas agrupa y no recibe asientos: marcarla de
    -- movimiento dejaría el saldo contado dos veces, en ella y en sus hijas
    SELECT COUNT(*) INTO v_hijos
      FROM contabilidad.plan_cuentas WHERE padre_id = p_id AND deleted_at IS NULL;
    IF COALESCE(p_es_movimiento, true) AND v_hijos > 0 THEN
        RAISE EXCEPTION 'No se puede marcar «es de movimiento»: la cuenta tiene % subcuenta(s) y los asientos van en ellas.', v_hijos
            USING ERRCODE = 'P0021';
    END IF;

    -- Y al revés: si está configurada en algún sitio —el ingreso de una
    -- categoría, el inventario de otra— no puede dejar de recibir asientos,
    -- porque esa configuración se quedaría apuntando a una cuenta de grupo.
    SELECT COUNT(*), string_agg(DISTINCT co.nombre, ', ' ORDER BY co.nombre)
      INTO v_usos, v_donde
      FROM contabilidad.cuentas_config cc
      JOIN contabilidad.conceptos_contables co ON co.codigo = cc.concepto
     WHERE cc.cuenta_id = p_id;
    IF NOT COALESCE(p_es_movimiento, true) AND (v_antes->>'es_movimiento')::boolean AND v_usos > 0 THEN
        RAISE EXCEPTION 'No se puede quitar «recibe asientos»: la cuenta está puesta en la configuración contable (%). Cámbiela allí primero.', v_donde
            USING ERRCODE = 'P0021';
    END IF;

    v_nuevo := jsonb_build_object(
        'codigo',        TRIM(p_codigo),
        'nombre',        TRIM(p_nombre),
        'descripcion',   NULLIF(TRIM(COALESCE(p_descripcion, '')), ''),
        'tipo',          v_tipo,
        'naturaleza',    v_naturaleza,
        'activo',        COALESCE(p_activo, true),
        'es_movimiento', COALESCE(p_es_movimiento, true) AND v_hijos = 0
    );
    PERFORM set_config('app.datos_anteriores',
        jsonb_build_object('codigo',        v_antes->>'codigo',
                           'nombre',        v_antes->>'nombre',
                           'descripcion',   v_antes->>'descripcion',
                           'tipo',          v_antes->>'tipo',
                           'naturaleza',    v_antes->>'naturaleza',
                           'activo',        (v_antes->>'activo')::boolean,
                           'es_movimiento', (v_antes->>'es_movimiento')::boolean)::text, true);
    PERFORM set_config('app.datos_nuevos', v_nuevo::text, true);

    UPDATE contabilidad.plan_cuentas
       SET codigo        = TRIM(p_codigo),
           nombre        = TRIM(p_nombre),
           descripcion   = NULLIF(TRIM(COALESCE(p_descripcion, '')), ''),
           tipo          = v_tipo,
           naturaleza    = v_naturaleza,
           activo        = COALESCE(p_activo, true),
           es_movimiento = COALESCE(p_es_movimiento, true) AND v_hijos = 0
     WHERE id = p_id;

    PERFORM set_config('app.datos_anteriores', '', true);
    PERFORM set_config('app.datos_nuevos', '', true);

    -- El tipo baja a toda la rama: si no, media rama saldría en el balance y
    -- la otra media en el estado de resultados
    IF v_tipo <> v_actual.tipo THEN
        WITH RECURSIVE d AS (
            SELECT id FROM contabilidad.plan_cuentas WHERE padre_id = p_id
            UNION ALL
            SELECT c.id FROM contabilidad.plan_cuentas c JOIN d ON c.padre_id = d.id
        )
        UPDATE contabilidad.plan_cuentas c
           SET tipo = v_tipo
         WHERE c.id IN (SELECT id FROM d) AND c.tipo <> v_tipo;
        GET DIAGNOSTICS v_cascada = ROW_COUNT;
    END IF;

    RETURN jsonb_build_object('success', true,
        'message', 'Cuenta actualizada exitosamente'
                || CASE WHEN v_cascada > 0
                        THEN format('. El tipo %s bajó también a sus %s subcuenta(s)', v_tipo, v_cascada)
                        ELSE '' END,
        'data', contabilidad.fn_plan_cuentas_json(p_id));

EXCEPTION
    WHEN unique_violation THEN
        -- El índice único cuenta también a las que están en la papelera
        RAISE EXCEPTION 'Ya existe otra cuenta con ese código o con ese nombre en el mismo nivel (puede estar en la papelera de reciclaje)' USING ERRCODE = 'P0006';
END;
$function$;

-- ---------------------------------------------------------------------------
-- A la papelera
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION contabilidad.fn_plan_cuentas_eliminar(
    p_id bigint,
    p_usuario_id bigint DEFAULT NULL::bigint,
    p_usuario_login character varying DEFAULT NULL::character varying,
    p_usuario_nombre character varying DEFAULT NULL::character varying,
    p_ip_address inet DEFAULT NULL::inet,
    p_user_agent text DEFAULT NULL::text,
    p_request_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'contabilidad', 'auditoria'
AS $function$
DECLARE
    v_actual record;
    v_existe boolean;
    v_antes  jsonb;
    v_hijos  bigint;
    v_usos   bigint;
    v_donde  text;
    v_fecha  timestamptz := CURRENT_TIMESTAMP;
    v_i      integer := 0;
    v_fila   record;
BEGIN
    PERFORM contabilidad.fn_contexto_auditoria('contabilidad.plan_cuentas',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    SELECT id, codigo, nombre, padre_id, deleted_at INTO v_actual
      FROM contabilidad.plan_cuentas WHERE id = p_id;
    -- En dos pasos a propósito: si no hay fila, `v_actual` es un record sin
    -- asignar y mencionarlo en la misma condición lo haría estallar con un
    -- 55000 en lugar de dar el «no existe» que espera la pantalla.
    v_existe := FOUND;

    IF NOT v_existe THEN
        RAISE EXCEPTION 'La cuenta no existe' USING ERRCODE = 'P0013';
    END IF;
    -- Una que ya está en la papelera se trata como si no existiera
    IF v_actual.deleted_at IS NOT NULL THEN
        RAISE EXCEPTION 'La cuenta no existe' USING ERRCODE = 'P0013';
    END IF;

    SELECT COUNT(*) INTO v_hijos
      FROM contabilidad.plan_cuentas WHERE padre_id = p_id AND deleted_at IS NULL;
    IF v_hijos > 0 THEN
        RAISE EXCEPTION 'No se puede eliminar: la cuenta tiene % subcuenta(s). Muévalas o bórrelas primero.', v_hijos
            USING ERRCODE = 'P0014';
    END IF;

    -- Si está configurada en algún sitio, no se va: la categoría que la
    -- tenía puesta se quedaría sin dónde asentar y nadie se enteraría hasta
    -- que fallara una factura.
    SELECT COUNT(*), string_agg(DISTINCT co.nombre, ', ' ORDER BY co.nombre)
      INTO v_usos, v_donde
      FROM contabilidad.cuentas_config cc
      JOIN contabilidad.conceptos_contables co ON co.codigo = cc.concepto
     WHERE cc.cuenta_id = p_id;
    IF v_usos > 0 THEN
        RAISE EXCEPTION 'No se puede eliminar: la cuenta está puesta en la configuración contable (%). Cámbiela allí primero.', v_donde
            USING ERRCODE = 'P0014';
    END IF;

    -- Aquí irá la comprobación de los asientos, en cuanto exista el libro
    -- diario: una cuenta con movimientos no se borra ni a la papelera, se
    -- desactiva, porque el mayor de los ejercicios anteriores la necesita.

    v_antes := contabilidad.fn_plan_cuentas_json(p_id);
    PERFORM set_config('app.datos_anteriores', v_antes::text, true);
    PERFORM set_config('app.datos_nuevos', (v_antes || jsonb_build_object(
        'deleted_at', to_char(v_fecha, 'YYYY-MM-DD HH24:MI:SS'), 'deleted_by', p_usuario_login
    ))::text, true);

    UPDATE contabilidad.plan_cuentas
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
        SELECT id FROM contabilidad.plan_cuentas
         WHERE padre_id IS NOT DISTINCT FROM v_actual.padre_id
           AND deleted_at IS NULL
         ORDER BY orden, codigo
    LOOP
        v_i := v_i + 1;
        UPDATE contabilidad.plan_cuentas SET orden = v_i WHERE id = v_fila.id AND orden IS DISTINCT FROM v_i;
    END LOOP;

    RETURN jsonb_build_object(
        'success', true,
        'message', format('Cuenta «%s %s» enviada a la papelera de reciclaje', v_actual.codigo, v_actual.nombre),
        'data', contabilidad.fn_plan_cuentas_json(p_id)
    );
END;
$function$;

-- ---------------------------------------------------------------------------
-- Borrar de verdad
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION contabilidad.fn_plan_cuentas_eliminar_definitivo(
    p_ids jsonb,
    p_usuario_id bigint DEFAULT NULL::bigint,
    p_usuario_login character varying DEFAULT NULL::character varying,
    p_usuario_nombre character varying DEFAULT NULL::character varying,
    p_ip_address inet DEFAULT NULL::inet,
    p_user_agent text DEFAULT NULL::text,
    p_request_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'contabilidad', 'auditoria'
AS $function$
DECLARE
    v_c       record;
    v_n       integer := 0;
    v_hijos   bigint;
    v_nombres text[] := '{}';
BEGIN
    PERFORM contabilidad.fn_contexto_auditoria('contabilidad.plan_cuentas',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    IF p_ids IS NULL OR jsonb_typeof(p_ids) <> 'array' OR jsonb_array_length(p_ids) = 0 THEN
        RAISE EXCEPTION 'No se indicó ninguna cuenta' USING ERRCODE = 'P0001';
    END IF;

    -- De lo más hondo a lo más alto: así, al vaciar la papelera entera, las
    -- hijas se van antes que sus madres y no choca la clave ajena
    FOR v_c IN
        SELECT c.id, c.codigo, c.nombre
          FROM contabilidad.plan_cuentas c
         WHERE c.id IN (SELECT (x)::bigint FROM jsonb_array_elements_text(p_ids) x)
           AND c.deleted_at IS NOT NULL
         ORDER BY c.nivel DESC, c.id DESC
    LOOP
        SELECT COUNT(*) INTO v_hijos FROM contabilidad.plan_cuentas WHERE padre_id = v_c.id;
        IF v_hijos > 0 THEN
            RAISE EXCEPTION 'No se puede eliminar «%» definitivamente: todavía tiene % subcuenta(s), aunque estén en la papelera. Bórrelas primero.', v_c.codigo || ' ' || v_c.nombre, v_hijos
                USING ERRCODE = 'P0014';
        END IF;

        -- La ficha entera a la auditoría: es lo único que no se puede volver
        -- a escribir de memoria si se borró por error
        PERFORM set_config('app.datos_anteriores', (contabilidad.fn_plan_cuentas_json(v_c.id))::text, true);
        DELETE FROM contabilidad.plan_cuentas WHERE id = v_c.id;

        v_n := v_n + 1;
        v_nombres := v_nombres || (v_c.codigo || ' ' || v_c.nombre)::text;
    END LOOP;

    PERFORM set_config('app.datos_anteriores', '', true);

    IF v_n = 0 THEN
        RAISE EXCEPTION 'Ninguna de esas cuentas está en la papelera' USING ERRCODE = 'P0019';
    END IF;

    RETURN jsonb_build_object(
        'success', true,
        'message', CASE WHEN v_n = 1 THEN format('Cuenta «%s» eliminada definitivamente', v_nombres[1])
                        ELSE format('%s cuentas eliminadas definitivamente', v_n) END,
        'data', jsonb_build_object('borradas', v_n, 'nombres', to_jsonb(v_nombres))
    );

EXCEPTION
    WHEN foreign_key_violation THEN
        RAISE EXCEPTION 'No se puede eliminar definitivamente: algo sigue apuntando a esa cuenta' USING ERRCODE = 'P0014';
END;
$function$;

-- ---------------------------------------------------------------------------
-- LAS DEL ÁRBOL: listar, obtener, activar, mover y la papelera
-- ---------------------------------------------------------------------------
-- Convertidas desde inventarios.fn_categorias_*, que es el mismo árbol y ya
-- está probado. Las diferencias de fondo están en `mover`: allí hay un tope
-- de cuatro niveles y aquí no hay ninguno, y aquí el tipo de cuenta no se
-- cambia arrastrando.

CREATE OR REPLACE FUNCTION contabilidad.fn_plan_cuentas_listar(p_solo_activos boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'contabilidad'
AS $function$
DECLARE
    v_data jsonb;
BEGIN
    WITH RECURSIVE arbol AS (
        SELECT c.id, c.padre_id, c.orden, c.activo,
               LPAD(c.orden::text, 5, '0') AS ruta_orden
          FROM contabilidad.plan_cuentas c
         WHERE c.padre_id IS NULL
           AND c.deleted_at IS NULL

        UNION ALL

        SELECT h.id, h.padre_id, h.orden, h.activo,
               a.ruta_orden || '.' || LPAD(h.orden::text, 5, '0')
          FROM contabilidad.plan_cuentas h
          JOIN arbol a ON h.padre_id = a.id
         WHERE h.deleted_at IS NULL
    )
    SELECT COALESCE(jsonb_agg(contabilidad.fn_plan_cuentas_json(a.id) ORDER BY a.ruta_orden), '[]'::jsonb)
      INTO v_data
      FROM arbol a
     WHERE NOT p_solo_activos OR a.activo;

    RETURN jsonb_build_object('success', true, 'data', v_data);

EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false, 'message', 'Error al listar cuentas: ' || SQLERRM, 'error_code', SQLSTATE);
END;
$function$;

CREATE OR REPLACE FUNCTION contabilidad.fn_plan_cuentas_obtener(p_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
AS $function$
DECLARE
    v_data jsonb;
BEGIN
    v_data := contabilidad.fn_plan_cuentas_json(p_id);
    IF v_data IS NULL THEN
        RAISE EXCEPTION 'La cuenta no existe' USING ERRCODE = 'P0013';
    END IF;
    RETURN jsonb_build_object('success', true, 'message', 'Cuenta encontrada', 'data', v_data);
END;
$function$;

CREATE OR REPLACE FUNCTION contabilidad.fn_plan_cuentas_activar(p_id bigint, p_activo boolean DEFAULT NULL::boolean, p_usuario_id bigint DEFAULT NULL::bigint, p_usuario_login character varying DEFAULT NULL::character varying, p_usuario_nombre character varying DEFAULT NULL::character varying, p_ip_address inet DEFAULT NULL::inet, p_user_agent text DEFAULT NULL::text, p_request_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'contabilidad', 'auditoria'
AS $function$
DECLARE
    v_antes      boolean;
    v_nuevo      boolean;
    v_updated_by varchar;
    v_updated_at text;
BEGIN
    PERFORM contabilidad.fn_contexto_auditoria('contabilidad.plan_cuentas',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    SELECT activo INTO v_antes FROM contabilidad.plan_cuentas WHERE id = p_id;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'error_code', 'NO_EXISTE', 'message', 'La cuenta no existe');
    END IF;

    v_nuevo := COALESCE(p_activo, NOT v_antes);

    IF v_nuevo IS NOT DISTINCT FROM v_antes THEN
        SELECT updated_by, to_char(updated_at, 'YYYY-MM-DD HH24:MI:SS')
          INTO v_updated_by, v_updated_at FROM contabilidad.plan_cuentas WHERE id = p_id;
        RETURN jsonb_build_object('success', true,
            'message', CASE WHEN v_nuevo THEN 'La cuenta ya estaba activa' ELSE 'La cuenta ya estaba inactiva' END,
            'data', jsonb_build_object('id', p_id, 'activo', v_nuevo,
                                       'updated_by', v_updated_by, 'updated_at', v_updated_at));
    END IF;

    PERFORM set_config('app.datos_anteriores', jsonb_build_object('id', p_id, 'activo', v_antes)::text, true);
    PERFORM set_config('app.datos_nuevos',     jsonb_build_object('id', p_id, 'activo', v_nuevo)::text, true);

    UPDATE contabilidad.plan_cuentas SET activo = v_nuevo WHERE id = p_id
    RETURNING activo, updated_by, to_char(updated_at, 'YYYY-MM-DD HH24:MI:SS')
         INTO v_nuevo, v_updated_by, v_updated_at;

    PERFORM set_config('app.datos_anteriores', '', true);
    PERFORM set_config('app.datos_nuevos', '', true);

    RETURN jsonb_build_object('success', true,
        'message', CASE WHEN v_nuevo THEN 'Cuenta activada' ELSE 'Cuenta desactivada' END,
        'data', jsonb_build_object('id', p_id, 'activo', v_nuevo,
                                   'updated_by', v_updated_by, 'updated_at', v_updated_at));

EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false, 'error_code', 'ERROR',
                              'message', 'No se pudo cambiar el estado de la cuenta: ' || SQLERRM);
END;
$function$;

CREATE OR REPLACE FUNCTION contabilidad.fn_plan_cuentas_mover(p_id bigint, p_padre_id bigint DEFAULT NULL::bigint, p_antes_de bigint DEFAULT NULL::bigint, p_usuario_id bigint DEFAULT NULL::bigint, p_usuario_login character varying DEFAULT NULL::character varying, p_usuario_nombre character varying DEFAULT NULL::character varying, p_ip_address inet DEFAULT NULL::inet, p_user_agent text DEFAULT NULL::text, p_request_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'contabilidad', 'auditoria'
AS $function$
DECLARE
    v_padre_actual bigint;
    v_nivel_nuevo  integer;
    -- Ni tope de niveles ni profundidad que comprobar: el plan de cuentas
    -- NO tiene fondo. Una empresa que necesite 1.1.01.001.0001 lo necesita
    -- de verdad, y poner un techo sólo obliga a inventarse códigos.
    v_pos          integer;
    v_i            integer;
    v_j            integer;
    v_fila         record;
    v_cod_viejo    varchar;
    v_cod_nuevo    varchar;
    v_cod_padre    varchar;
    v_cola         varchar;
    v_intento      varchar;
    v_renumeradas  integer := 0;
BEGIN
    PERFORM contabilidad.fn_contexto_auditoria('contabilidad.plan_cuentas',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    SELECT padre_id INTO v_padre_actual FROM contabilidad.plan_cuentas WHERE id = p_id;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'error_code', 'NO_EXISTE', 'message', 'La cuenta no existe');
    END IF;

    IF p_padre_id IS NOT NULL THEN
        IF p_padre_id = p_id THEN
            RETURN jsonb_build_object('success', false, 'error_code', 'AUTOREFERENCIA',
                                      'message', 'Una cuenta no puede estar dentro de sí misma');
        END IF;
        -- Una cuenta de la papelera no es un destino: no se ve en el
        -- árbol, y lo que colgara de ella desaparecería con ella.
        IF NOT EXISTS (SELECT 1 FROM contabilidad.plan_cuentas WHERE id = p_padre_id AND deleted_at IS NULL) THEN
            RETURN jsonb_build_object('success', false, 'error_code', 'PADRE_NO_EXISTE',
                                      'message', 'La cuenta destino no existe');
        END IF;
        -- El destino no puede colgar de la que se mueve (ciclo)
        IF EXISTS (
            WITH RECURSIVE d AS (
                SELECT id FROM contabilidad.plan_cuentas WHERE padre_id = p_id
                UNION ALL
                SELECT c.id FROM contabilidad.plan_cuentas c JOIN d ON c.padre_id = d.id
            )
            SELECT 1 FROM d WHERE d.id = p_padre_id
        ) THEN
            RETURN jsonb_build_object('success', false, 'error_code', 'CICLO',
                                      'message', 'No se puede mover una cuenta dentro de una de sus propias subcuentas');
        END IF;
        SELECT nivel + 1 INTO v_nivel_nuevo FROM contabilidad.plan_cuentas WHERE id = p_padre_id;

        -- El tipo manda en qué informe sale la cuenta: una rama de ACTIVO
        -- colgada de GASTO descuadraría el balance y el estado de resultados
        -- a la vez. El tipo se cambia en la ficha, que lo baja a toda la
        -- rama; arrastrando, no.
        IF (SELECT tipo FROM contabilidad.plan_cuentas WHERE id = p_padre_id)
           IS DISTINCT FROM (SELECT tipo FROM contabilidad.plan_cuentas WHERE id = p_id) THEN
            RETURN jsonb_build_object('success', false, 'error_code', 'TIPO_DISTINTO',
                'message', format('No se puede mover una cuenta de tipo %s dentro de una de tipo %s',
                                  (SELECT tipo FROM contabilidad.plan_cuentas WHERE id = p_id),
                                  (SELECT tipo FROM contabilidad.plan_cuentas WHERE id = p_padre_id)));
        END IF;

        -- UNA CUENTA DE MOVIMIENTO NO ADMITE SUBCUENTAS: recibe asientos,
        -- así que tiene saldo propio, y colgarle algo debajo obligaría a
        -- decidir qué pasa con ese saldo. Primero se le quita «recibe
        -- asientos» en su ficha, que es lo mismo que exige crear.
        IF (SELECT es_movimiento FROM contabilidad.plan_cuentas WHERE id = p_padre_id) THEN
            RETURN jsonb_build_object('success', false, 'error_code', 'PADRE_DE_MOVIMIENTO',
                'message', format('«%s» recibe asientos y por eso no admite subcuentas. Quítale «recibe asientos» en su ficha y vuelve a intentarlo.',
                                  (SELECT codigo || ' ' || nombre FROM contabilidad.plan_cuentas WHERE id = p_padre_id)));
        END IF;
    ELSE
        v_nivel_nuevo := 0;
    END IF;

    -- El nombre tampoco se puede repetir entre los hermanos NUEVOS
    IF EXISTS (SELECT 1 FROM contabilidad.plan_cuentas
                WHERE padre_id IS NOT DISTINCT FROM p_padre_id
                  AND id <> p_id
                  AND UPPER(TRIM(nombre)) = (SELECT UPPER(TRIM(nombre)) FROM contabilidad.plan_cuentas WHERE id = p_id)) THEN
        RETURN jsonb_build_object('success', false, 'error_code', 'NOMBRE_DUPLICADO',
                                  'message', 'Ahí ya hay una cuenta con ese nombre');
    END IF;

    -- EL CÓDIGO DE UNA CUENTA DICE DE DÓNDE CUELGA. Si cambia de rama, el
    -- que tiene deja de ser cierto: una cuenta bajo «1.1.01.01 Caja» con el
    -- código 1.1.01.02.03 dice que es de Bancos, y así no la encuentra nadie
    -- ni cuadra un mayor. Se le da el siguiente libre de su nueva rama, y lo
    -- mismo a todo lo que cuelgue de ella.
    --
    -- El nuevo código se calcula ANTES de moverla: después ya sería hermana
    -- de las de destino y se contaría a sí misma.
    IF v_padre_actual IS DISTINCT FROM p_padre_id THEN
        SELECT codigo INTO v_cod_viejo FROM contabilidad.plan_cuentas WHERE id = p_id;
        v_cod_nuevo := contabilidad.fn_plan_cuentas_codigo_libre(p_padre_id, p_id);
    END IF;

    -- Padre y nivel; y el nivel de los descendientes, en cascada
    UPDATE contabilidad.plan_cuentas
       SET padre_id = p_padre_id, nivel = v_nivel_nuevo
     WHERE id = p_id
       AND (padre_id IS DISTINCT FROM p_padre_id OR nivel IS DISTINCT FROM v_nivel_nuevo);

    FOR v_fila IN
        WITH RECURSIVE d AS (
            SELECT id, v_nivel_nuevo + 1 AS nivel_ok FROM contabilidad.plan_cuentas WHERE padre_id = p_id
            UNION ALL
            SELECT c.id, d.nivel_ok + 1 FROM contabilidad.plan_cuentas c JOIN d ON c.padre_id = d.id
        )
        SELECT d.id, d.nivel_ok FROM d JOIN contabilidad.plan_cuentas c ON c.id = d.id
         WHERE c.nivel IS DISTINCT FROM d.nivel_ok
    LOOP
        UPDATE contabilidad.plan_cuentas SET nivel = v_fila.nivel_ok WHERE id = v_fila.id;
    END LOOP;

    -- Y ahora los códigos: primero el de la cuenta movida y después, de
    -- arriba abajo, los de sus descendientes, cada uno conservando su último
    -- tramo —1.1.01.02.03.01 debajo de la nueva 1.1.01.01.03 pasa a ser
    -- 1.1.01.01.03.01—, que es lo que mantiene la rama reconocible.
    IF v_cod_nuevo IS NOT NULL AND v_cod_nuevo IS DISTINCT FROM v_cod_viejo THEN
        UPDATE contabilidad.plan_cuentas SET codigo = v_cod_nuevo WHERE id = p_id;
        v_renumeradas := 1;

        FOR v_fila IN
            WITH RECURSIVE d AS (
                SELECT id, 1 AS prof FROM contabilidad.plan_cuentas WHERE padre_id = p_id
                UNION ALL
                SELECT c.id, d.prof + 1 FROM contabilidad.plan_cuentas c JOIN d ON c.padre_id = d.id
            )
            SELECT c.id, c.codigo, c.padre_id FROM d JOIN contabilidad.plan_cuentas c ON c.id = d.id
             ORDER BY d.prof
        LOOP
            -- El padre ya está renumerado: vamos de arriba abajo
            SELECT codigo INTO v_cod_padre FROM contabilidad.plan_cuentas WHERE id = v_fila.padre_id;
            v_cola := CASE WHEN position('.' IN v_fila.codigo) > 0
                           THEN regexp_replace(v_fila.codigo, '^.*\.', '')
                           ELSE v_fila.codigo END;
            v_intento := v_cod_padre || '.' || v_cola;

            -- Si ese código estuviera cogido fuera de la rama, se sube
            v_j := 0;
            WHILE v_j < 500
                  AND EXISTS (SELECT 1 FROM contabilidad.plan_cuentas
                               WHERE UPPER(TRIM(codigo)) = UPPER(v_intento) AND id <> v_fila.id) LOOP
                v_j := v_j + 1;
                v_cola := CASE WHEN v_cola ~ '^[0-9]+$'
                               THEN LPAD((v_cola::numeric + 1)::text, length(v_cola), '0')
                               ELSE v_cola || '-' || v_j::text END;
                v_intento := v_cod_padre || '.' || v_cola;
            END LOOP;

            UPDATE contabilidad.plan_cuentas SET codigo = v_intento
             WHERE id = v_fila.id AND codigo IS DISTINCT FROM v_intento;
            IF FOUND THEN v_renumeradas := v_renumeradas + 1; END IF;
        END LOOP;
    END IF;

    -- Sitio entre los hermanos del destino: se saca el movido, se mete
    -- delante de p_antes_de (o al final) y se renumera 1..N
    CREATE TEMP TABLE IF NOT EXISTS tmp_cuentas_hermanas (id bigint, pos integer) ON COMMIT DROP;
    DELETE FROM tmp_cuentas_hermanas;

    INSERT INTO tmp_cuentas_hermanas (id, pos)
    SELECT id, ROW_NUMBER() OVER (ORDER BY orden, nombre)
      FROM contabilidad.plan_cuentas
     WHERE padre_id IS NOT DISTINCT FROM p_padre_id AND id <> p_id;

    IF p_antes_de IS NOT NULL AND p_antes_de <> p_id THEN
        SELECT pos INTO v_pos FROM tmp_cuentas_hermanas WHERE id = p_antes_de;
    END IF;
    IF v_pos IS NULL THEN
        SELECT COALESCE(MAX(pos), 0) + 1 INTO v_pos FROM tmp_cuentas_hermanas;
    END IF;

    UPDATE tmp_cuentas_hermanas SET pos = pos + 1 WHERE pos >= v_pos;
    INSERT INTO tmp_cuentas_hermanas (id, pos) VALUES (p_id, v_pos);

    v_i := 0;
    FOR v_fila IN SELECT id FROM tmp_cuentas_hermanas ORDER BY pos LOOP
        v_i := v_i + 1;
        UPDATE contabilidad.plan_cuentas SET orden = v_i WHERE id = v_fila.id AND orden IS DISTINCT FROM v_i;
    END LOOP;

    -- Y los hermanos que dejó atrás, sin huecos
    IF v_padre_actual IS DISTINCT FROM p_padre_id THEN
        v_i := 0;
        FOR v_fila IN
            SELECT id FROM contabilidad.plan_cuentas
             WHERE padre_id IS NOT DISTINCT FROM v_padre_actual
             ORDER BY orden, nombre
        LOOP
            v_i := v_i + 1;
            UPDATE contabilidad.plan_cuentas SET orden = v_i WHERE id = v_fila.id AND orden IS DISTINCT FROM v_i;
        END LOOP;
    END IF;

    RETURN jsonb_build_object(
        'success', true,
        'message', CASE
            WHEN v_cod_nuevo IS NOT NULL AND v_cod_nuevo IS DISTINCT FROM v_cod_viejo
                THEN format('Cuenta movida: su código pasa de %s a %s', v_cod_viejo, v_cod_nuevo)
                  || CASE WHEN v_renumeradas > 1
                          THEN format(' (y %s subcuentas renumeradas)', v_renumeradas - 1)
                          ELSE '' END
            WHEN v_padre_actual IS DISTINCT FROM p_padre_id THEN 'Cuenta movida'
            ELSE 'Orden actualizado' END,
        'data', contabilidad.fn_plan_cuentas_json(p_id)
    );

EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false, 'error_code', SQLSTATE,
                              'message', 'Error al mover la cuenta: ' || SQLERRM);
END;
$function$;

CREATE OR REPLACE FUNCTION contabilidad.fn_plan_cuentas_papelera_listar()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
AS $function$
DECLARE
    v_data jsonb;
BEGIN
    SELECT COALESCE(jsonb_agg(
               contabilidad.fn_plan_cuentas_json(c.id)
               -- `padre_en_papelera` evita que haya que adivinar por qué una
               -- hija no se deja restaurar: la pantalla ya lo sabe.
               || jsonb_build_object('padre_en_papelera',
                      EXISTS (SELECT 1 FROM contabilidad.plan_cuentas p
                               WHERE p.id = c.padre_id AND p.deleted_at IS NOT NULL))
               ORDER BY c.deleted_at DESC, c.id DESC), '[]'::jsonb)
      INTO v_data
      FROM contabilidad.plan_cuentas c
     WHERE c.deleted_at IS NOT NULL;

    RETURN jsonb_build_object('success', true, 'data', v_data, 'total', jsonb_array_length(v_data));
EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object('success', false, 'message', 'Error al listar la papelera: ' || SQLERRM, 'error_code', SQLSTATE);
END;
$function$;

CREATE OR REPLACE FUNCTION contabilidad.fn_plan_cuentas_restaurar(p_ids jsonb, p_usuario_id bigint DEFAULT NULL::bigint, p_usuario_login character varying DEFAULT NULL::character varying, p_usuario_nombre character varying DEFAULT NULL::character varying, p_ip_address inet DEFAULT NULL::inet, p_user_agent text DEFAULT NULL::text, p_request_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'contabilidad', 'auditoria'
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
    PERFORM contabilidad.fn_contexto_auditoria('contabilidad.plan_cuentas',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    IF p_ids IS NULL OR jsonb_typeof(p_ids) <> 'array' OR jsonb_array_length(p_ids) = 0 THEN
        RAISE EXCEPTION 'No se indicó ninguna cuenta' USING ERRCODE = 'P0001';
    END IF;

    -- De arriba abajo: si se restauran madre e hija a la vez, la madre va
    -- primero y la hija ya se encuentra con el sitio hecho
    FOR v_c IN
        SELECT c.id, c.nombre, c.padre_id, c.nivel
          FROM contabilidad.plan_cuentas c
         WHERE c.id IN (SELECT (x)::bigint FROM jsonb_array_elements_text(p_ids) x)
           AND c.deleted_at IS NOT NULL
         ORDER BY c.nivel, c.id
    LOOP
        IF v_c.padre_id IS NOT NULL
           AND EXISTS (SELECT 1 FROM contabilidad.plan_cuentas p
                        WHERE p.id = v_c.padre_id AND p.deleted_at IS NOT NULL) THEN
            v_colgadas := v_colgadas + 1;
            CONTINUE;
        END IF;

        v_antes := contabilidad.fn_plan_cuentas_json(v_c.id);
        PERFORM set_config('app.datos_anteriores', v_antes::text, true);
        PERFORM set_config('app.datos_nuevos', (v_antes || jsonb_build_object('deleted_at', NULL, 'deleted_by', NULL))::text, true);

        UPDATE contabilidad.plan_cuentas
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
            RAISE EXCEPTION 'No se puede restaurar: su cuenta padre también está en la papelera. Restaure primero la de arriba.'
                USING ERRCODE = 'P0014';
        END IF;
        RAISE EXCEPTION 'Ninguna de esas cuentas está en la papelera' USING ERRCODE = 'P0019';
    END IF;

    -- Renumerar a las hermanas de cada rama tocada: la restaurada vuelve con
    -- un `orden` que puede empatar con el de otra
    FOREACH v_padre IN ARRAY v_padres LOOP
        v_i := 0;
        FOR v_fila IN
            SELECT id FROM contabilidad.plan_cuentas
             WHERE padre_id IS NOT DISTINCT FROM NULLIF(v_padre, -1)
               AND deleted_at IS NULL
             ORDER BY orden, nombre
        LOOP
            v_i := v_i + 1;
            UPDATE contabilidad.plan_cuentas SET orden = v_i WHERE id = v_fila.id AND orden IS DISTINCT FROM v_i;
        END LOOP;
    END LOOP;

    RETURN jsonb_build_object(
        'success', true,
        'message', CASE WHEN v_n = 1 THEN format('Cuenta «%s» restaurada', v_nombres[1])
                        ELSE format('%s cuentas restauradas', v_n) END
                 || CASE WHEN v_colgadas > 0
                         THEN format('. %s se quedaron: su cuenta padre sigue en la papelera', v_colgadas)
                         ELSE '' END,
        'data', jsonb_build_object('restauradas', v_n, 'sin_padre', v_colgadas, 'nombres', to_jsonb(v_nombres))
    );
END;
$function$;

CREATE OR REPLACE FUNCTION contabilidad.fn_plan_cuentas_papelera_vaciar(p_usuario_id bigint DEFAULT NULL::bigint, p_usuario_login character varying DEFAULT NULL::character varying, p_usuario_nombre character varying DEFAULT NULL::character varying, p_ip_address inet DEFAULT NULL::inet, p_user_agent text DEFAULT NULL::text, p_request_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'contabilidad', 'auditoria'
AS $function$
DECLARE
    v_ids jsonb;
BEGIN
    SELECT COALESCE(jsonb_agg(c.id), '[]'::jsonb) INTO v_ids
      FROM contabilidad.plan_cuentas c WHERE c.deleted_at IS NOT NULL;

    IF jsonb_array_length(v_ids) = 0 THEN
        RETURN jsonb_build_object('success', true, 'message', 'La papelera ya estaba vacía',
                                  'data', jsonb_build_object('borradas', 0, 'nombres', '[]'::jsonb));
    END IF;

    -- Se delega en eliminar_definitivo, que ya va de lo más hondo a lo más
    -- alto: dos sitios donde se borra de verdad acabarían divergiendo.
    RETURN contabilidad.fn_plan_cuentas_eliminar_definitivo(v_ids,
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);
END;
$function$;

-- ---------------------------------------------------------------------------
-- EL PLAN DE CUENTAS BASE
-- ---------------------------------------------------------------------------
-- Un plan de cuentas con la estructura de la Superintendencia de Compañías
-- (NIIF para pymes), que es la que se usa aquí: cinco grupos —activo, pasivo,
-- patrimonio, ingresos, costos y gastos— más las cuentas de orden, y dentro de
-- cada uno los niveles que hagan falta. Llega hasta 1.1.01.01.01, cinco
-- niveles, que es justo lo que el árbol de categorías no admitía.
--
-- Del listado sólo se escribe lo que no se puede deducir:
--   · el TIPO va sólo en las cuentas raíz y baja a toda su rama, que es la
--     regla que luego hacen cumplir crear, modificar y mover;
--   · la NATURALEZA se deja en blanco cuando es la del tipo y se escribe
--     únicamente en las cuentas de valuación, que van al revés —«(-)
--     Depreciación acumulada» es de activo y acreedora—, de modo que las
--     excepciones se ven de un vistazo;
--   · «es de movimiento» no se escribe: lo es exactamente la cuenta que no
--     tiene ninguna otra colgando. Así la lista no puede contradecirse.
DO $$
DECLARE
    v_fila   record;
    v_cod_padre   varchar;
    v_padre_id    bigint;
    v_padre_nivel integer;
    v_padre_tipo  varchar;
    v_orden  integer;
    v_hoja   boolean;
    v_n      integer := 0;
BEGIN
    -- Esto es la carga inicial: si ya hay cuentas, el plan es el del usuario
    IF EXISTS (SELECT 1 FROM contabilidad.plan_cuentas) THEN
        RAISE NOTICE 'El plan de cuentas ya tiene cuentas: no se toca';
        RETURN;
    END IF;

    -- Para que la auditoría no apunte a «postgres»
    PERFORM set_config('app.usuario_login',  'plan-cuentas-base', true);
    PERFORM set_config('app.usuario_nombre', 'Plan de cuentas base', true);

    FOR v_fila IN
        WITH plan(codigo, nombre, tipo, naturaleza, descripcion) AS (VALUES
            -- ======================= 1. ACTIVO =============================
            ('1',             'ACTIVO',                                          'ACTIVO'::varchar, NULL::varchar, 'Lo que la empresa tiene y lo que le deben'::text),
            ('1.1',           'ACTIVO CORRIENTE',                                 NULL, NULL, 'Lo que se vuelve efectivo dentro del ejercicio'),
            ('1.1.01',        'EFECTIVO Y EQUIVALENTES AL EFECTIVO',              NULL, NULL, NULL),
            ('1.1.01.01',     'Caja',                                             NULL, NULL, NULL),
            ('1.1.01.01.01',  'Caja general',                                     NULL, NULL, 'Recaudación del día antes de depositarla'),
            ('1.1.01.01.02',  'Caja chica',                                       NULL, NULL, 'Fondo fijo para gastos menores'),
            ('1.1.01.02',     'Bancos',                                           NULL, NULL, NULL),
            ('1.1.01.02.01',  'Banco Pichincha cuenta corriente',                 NULL, NULL, NULL),
            ('1.1.01.02.02',  'Banco Guayaquil cuenta de ahorros',                NULL, NULL, NULL),
            ('1.1.02',        'ACTIVOS FINANCIEROS',                              NULL, NULL, NULL),
            ('1.1.02.01',     'Cuentas por cobrar clientes',                      NULL, NULL, NULL),
            ('1.1.02.01.01',  'Clientes nacionales',                              NULL, NULL, NULL),
            ('1.1.02.01.02',  'Clientes relacionados',                            NULL, NULL, NULL),
            ('1.1.02.02',     'Otras cuentas por cobrar',                         NULL, NULL, NULL),
            ('1.1.02.02.01',  'Anticipos de sueldo a empleados',                  NULL, NULL, NULL),
            ('1.1.02.02.02',  'Préstamos a empleados',                            NULL, NULL, NULL),
            ('1.1.02.03',     '(-) Provisión cuentas incobrables',                NULL, 'ACREEDORA', 'Cuenta de valuación: resta del activo, así que es acreedora'),
            ('1.1.03',        'INVENTARIOS',                                      NULL, NULL, NULL),
            ('1.1.03.01',     'Inventario de mercaderías',                        NULL, NULL, NULL),
            ('1.1.03.02',     'Mercadería en tránsito',                           NULL, NULL, NULL),
            ('1.1.03.03',     '(-) Provisión por deterioro de inventario',        NULL, 'ACREEDORA', 'Cuenta de valuación: resta del inventario'),
            ('1.1.04',        'SERVICIOS Y OTROS PAGOS ANTICIPADOS',              NULL, NULL, NULL),
            ('1.1.04.01',     'Anticipos a proveedores',                          NULL, NULL, NULL),
            ('1.1.04.02',     'Arriendos pagados por anticipado',                 NULL, NULL, NULL),
            ('1.1.04.03',     'Seguros pagados por anticipado',                   NULL, NULL, NULL),
            ('1.1.05',        'ACTIVOS POR IMPUESTOS CORRIENTES',                 NULL, NULL, NULL),
            ('1.1.05.01',     'Crédito tributario a favor por IVA',               NULL, NULL, NULL),
            ('1.1.05.02',     'Crédito tributario a favor por Impuesto a la Renta', NULL, NULL, NULL),
            ('1.1.05.03',     'Anticipo de Impuesto a la Renta',                  NULL, NULL, NULL),
            ('1.2',           'ACTIVO NO CORRIENTE',                              NULL, NULL, 'Lo que se queda en la empresa más de un ejercicio'),
            ('1.2.01',        'PROPIEDADES, PLANTA Y EQUIPO',                     NULL, NULL, NULL),
            ('1.2.01.01',     'Terrenos',                                         NULL, NULL, NULL),
            ('1.2.01.02',     'Edificios',                                        NULL, NULL, NULL),
            ('1.2.01.03',     'Muebles y enseres',                                NULL, NULL, NULL),
            ('1.2.01.04',     'Equipo de computación',                            NULL, NULL, NULL),
            ('1.2.01.05',     'Vehículos',                                        NULL, NULL, NULL),
            ('1.2.01.06',     'Maquinaria y equipo',                              NULL, NULL, NULL),
            ('1.2.01.07',     '(-) Depreciación acumulada propiedades, planta y equipo', NULL, 'ACREEDORA', 'Cuenta de valuación: resta del activo fijo'),
            ('1.2.02',        'ACTIVO INTANGIBLE',                                NULL, NULL, NULL),
            ('1.2.02.01',     'Programas de computación',                         NULL, NULL, NULL),
            ('1.2.02.02',     'Marcas y patentes',                                NULL, NULL, NULL),
            ('1.2.02.03',     '(-) Amortización acumulada de intangibles',        NULL, 'ACREEDORA', 'Cuenta de valuación: resta del intangible'),

            -- ======================= 2. PASIVO =============================
            ('2',             'PASIVO',                                           'PASIVO', NULL, 'Lo que la empresa debe'),
            ('2.1',           'PASIVO CORRIENTE',                                 NULL, NULL, 'Lo que se paga dentro del ejercicio'),
            ('2.1.01',        'CUENTAS Y DOCUMENTOS POR PAGAR',                   NULL, NULL, NULL),
            ('2.1.01.01',     'Proveedores nacionales',                           NULL, NULL, NULL),
            ('2.1.01.02',     'Proveedores del exterior',                         NULL, NULL, NULL),
            ('2.1.02',        'OBLIGACIONES CON INSTITUCIONES FINANCIERAS',       NULL, NULL, NULL),
            ('2.1.02.01',     'Préstamos bancarios por pagar corto plazo',        NULL, NULL, NULL),
            ('2.1.02.02',     'Sobregiros bancarios',                             NULL, NULL, NULL),
            ('2.1.03',        'OTRAS OBLIGACIONES CORRIENTES',                    NULL, NULL, NULL),
            ('2.1.03.01',     'Con la administración tributaria',                  NULL, NULL, NULL),
            ('2.1.03.01.01',  'IVA cobrado en ventas',                            NULL, NULL, NULL),
            ('2.1.03.01.02',  'Retenciones en la fuente por pagar',               NULL, NULL, NULL),
            ('2.1.03.01.03',  'Retenciones de IVA por pagar',                     NULL, NULL, NULL),
            ('2.1.03.02',     'Con el IESS',                                      NULL, NULL, NULL),
            ('2.1.03.02.01',  'Aporte personal IESS por pagar',                   NULL, NULL, NULL),
            ('2.1.03.02.02',  'Aporte patronal IESS por pagar',                   NULL, NULL, NULL),
            ('2.1.03.02.03',  'Préstamos IESS por pagar',                         NULL, NULL, NULL),
            ('2.1.03.03',     'Por beneficios de ley a empleados',                NULL, NULL, NULL),
            ('2.1.03.03.01',  'Sueldos y salarios por pagar',                     NULL, NULL, NULL),
            ('2.1.03.03.02',  'Décimo tercer sueldo por pagar',                   NULL, NULL, NULL),
            ('2.1.03.03.03',  'Décimo cuarto sueldo por pagar',                   NULL, NULL, NULL),
            ('2.1.03.03.04',  'Vacaciones por pagar',                             NULL, NULL, NULL),
            ('2.1.03.03.05',  'Fondos de reserva por pagar',                      NULL, NULL, NULL),
            ('2.1.03.04',     'Participación trabajadores por pagar del ejercicio', NULL, NULL, 'El 15 % de la utilidad'),
            ('2.1.03.05',     'Impuesto a la renta por pagar del ejercicio',      NULL, NULL, NULL),
            ('2.1.04',        'ANTICIPOS DE CLIENTES',                            NULL, NULL, NULL),
            ('2.1.04.01',     'Anticipos recibidos de clientes',                  NULL, NULL, NULL),
            ('2.2',           'PASIVO NO CORRIENTE',                              NULL, NULL, 'Lo que se paga más allá del ejercicio'),
            ('2.2.01',        'OBLIGACIONES A LARGO PLAZO',                       NULL, NULL, NULL),
            ('2.2.01.01',     'Préstamos bancarios por pagar largo plazo',        NULL, NULL, NULL),
            ('2.2.02',        'PROVISIONES POR BENEFICIOS A EMPLEADOS',           NULL, NULL, NULL),
            ('2.2.02.01',     'Provisión por jubilación patronal',                NULL, NULL, NULL),
            ('2.2.02.02',     'Provisión por desahucio',                          NULL, NULL, NULL),

            -- ===================== 3. PATRIMONIO ===========================
            ('3',             'PATRIMONIO NETO',                                  'PATRIMONIO', NULL, 'Lo que queda de los socios: activo menos pasivo'),
            ('3.1',           'CAPITAL',                                          NULL, NULL, NULL),
            ('3.1.01',        'Capital suscrito o asignado',                      NULL, NULL, NULL),
            ('3.1.02',        'Aportes de socios para futuras capitalizaciones',  NULL, NULL, NULL),
            ('3.2',           'RESERVAS',                                         NULL, NULL, NULL),
            ('3.2.01',        'Reserva legal',                                    NULL, NULL, NULL),
            ('3.2.02',        'Reserva facultativa',                              NULL, NULL, NULL),
            ('3.3',           'RESULTADOS ACUMULADOS',                            NULL, NULL, NULL),
            ('3.3.01',        'Ganancias acumuladas',                             NULL, NULL, NULL),
            ('3.3.02',        '(-) Pérdidas acumuladas',                          NULL, 'DEUDORA', 'Resta del patrimonio, así que es deudora'),
            ('3.4',           'RESULTADOS DEL EJERCICIO',                         NULL, NULL, NULL),
            ('3.4.01',        'Ganancia neta del periodo',                        NULL, NULL, NULL),
            ('3.4.02',        '(-) Pérdida neta del periodo',                     NULL, 'DEUDORA', 'Resta del patrimonio, así que es deudora'),

            -- ====================== 4. INGRESOS ============================
            ('4',             'INGRESOS',                                         'INGRESO', NULL, 'Lo que la empresa gana'),
            ('4.1',           'INGRESOS DE ACTIVIDADES ORDINARIAS',               NULL, NULL, 'Lo que se gana con el negocio de siempre'),
            ('4.1.01',        'Venta de bienes',                                  NULL, NULL, NULL),
            ('4.1.02',        'Prestación de servicios',                          NULL, NULL, NULL),
            ('4.1.03',        '(-) Descuento en ventas',                          NULL, 'DEUDORA', 'Resta de las ventas, así que es deudora'),
            ('4.1.04',        '(-) Devoluciones en ventas',                       NULL, 'DEUDORA', 'Resta de las ventas, así que es deudora'),
            ('4.2',           'OTROS INGRESOS',                                   NULL, NULL, NULL),
            ('4.2.01',        'Intereses financieros ganados',                    NULL, NULL, NULL),
            ('4.2.02',        'Utilidad en venta de activos fijos',               NULL, NULL, NULL),
            ('4.2.03',        'Otras rentas',                                     NULL, NULL, NULL),

            -- ======================= 5. COSTOS =============================
            ('5',             'COSTOS',                                           'COSTO', NULL, 'Lo que cuesta lo que se vende'),
            ('5.1',           'COSTO DE VENTAS',                                  NULL, NULL, NULL),
            ('5.1.01',        'Costo de ventas de mercaderías',                   NULL, NULL, NULL),
            ('5.2',           'COMPRAS Y GASTOS RELACIONADOS',                    NULL, NULL, NULL),
            ('5.2.01',        'Compras de mercaderías',                           NULL, NULL, NULL),
            ('5.2.02',        '(-) Descuento en compras',                         NULL, 'ACREEDORA', 'Resta de las compras, así que es acreedora'),
            ('5.2.03',        'Transporte en compras',                            NULL, NULL, NULL),
            ('5.2.04',        'Importaciones y aranceles',                        NULL, NULL, NULL),

            -- ======================= 6. GASTOS =============================
            ('6',             'GASTOS',                                           'GASTO', NULL, 'Lo que cuesta hacer funcionar la empresa'),
            ('6.1',           'GASTOS DE VENTA',                                  NULL, NULL, NULL),
            ('6.1.01',        'Sueldos y beneficios sociales de ventas',          NULL, NULL, NULL),
            ('6.1.02',        'Comisiones a vendedores',                          NULL, NULL, NULL),
            ('6.1.03',        'Publicidad y propaganda',                          NULL, NULL, NULL),
            ('6.1.04',        'Combustibles y lubricantes',                       NULL, NULL, NULL),
            ('6.1.05',        'Transporte y fletes en ventas',                    NULL, NULL, NULL),
            ('6.2',           'GASTOS DE ADMINISTRACIÓN',                         NULL, NULL, NULL),
            ('6.2.01',        'Sueldos, salarios y demás remuneraciones',         NULL, NULL, NULL),
            ('6.2.02',        'Aportes a la seguridad social',                    NULL, NULL, NULL),
            ('6.2.03',        'Beneficios sociales e indemnizaciones',            NULL, NULL, NULL),
            ('6.2.04',        'Honorarios profesionales',                         NULL, NULL, NULL),
            ('6.2.05',        'Arrendamientos',                                   NULL, NULL, NULL),
            ('6.2.06',        'Servicios básicos',                                NULL, NULL, 'Luz, agua, teléfono e internet'),
            ('6.2.07',        'Suministros y materiales de oficina',              NULL, NULL, NULL),
            ('6.2.08',        'Mantenimiento y reparaciones',                     NULL, NULL, NULL),
            ('6.2.09',        'Depreciación de propiedades, planta y equipo',     NULL, NULL, NULL),
            ('6.2.10',        'Amortización de intangibles',                      NULL, NULL, NULL),
            ('6.2.11',        'Impuestos, contribuciones y otros',                NULL, NULL, NULL),
            ('6.2.12',        'Provisión de cuentas incobrables',                 NULL, NULL, NULL),
            ('6.2.13',        'Seguros y reaseguros',                             NULL, NULL, NULL),
            ('6.3',           'GASTOS FINANCIEROS',                               NULL, NULL, NULL),
            ('6.3.01',        'Intereses bancarios',                              NULL, NULL, NULL),
            ('6.3.02',        'Comisiones y servicios bancarios',                 NULL, NULL, NULL),
            ('6.4',           'OTROS GASTOS',                                     NULL, NULL, NULL),
            ('6.4.01',        'Pérdida en venta de activos fijos',                NULL, NULL, NULL),
            ('6.4.02',        'Gastos no deducibles',                             NULL, NULL, NULL),

            -- =================== 7. CUENTAS DE ORDEN =======================
            ('7',             'CUENTAS DE ORDEN',                                 'ORDEN', 'DEUDORA', 'Lo que no es de la empresa pero responde por ello'),
            ('7.1',           'CUENTAS DE ORDEN DEUDORAS',                        NULL, 'DEUDORA', NULL),
            ('7.1.01',        'Garantías y valores recibidos',                    NULL, 'DEUDORA', NULL),
            ('7.1.02',        'Mercadería recibida en consignación',              NULL, 'DEUDORA', NULL),
            ('7.2',           'CUENTAS DE ORDEN ACREEDORAS',                      NULL, 'ACREEDORA', NULL),
            ('7.2.01',        'Garantías y valores otorgados',                    NULL, 'ACREEDORA', NULL),
            ('7.2.02',        'Mercadería entregada en consignación',             NULL, 'ACREEDORA', NULL)
        )
        SELECT p.codigo, p.nombre, p.tipo, p.naturaleza, p.descripcion,
               -- Es de movimiento la que no tiene ninguna otra colgando: así
               -- la lista no se puede contradecir a sí misma
               NOT EXISTS (SELECT 1 FROM plan h WHERE h.codigo LIKE p.codigo || '.%') AS es_hoja
          FROM plan p
         -- El padre siempre tiene el código más corto, así que por longitud
         -- las madres entran antes que las hijas
         ORDER BY length(p.codigo), p.codigo
    LOOP
        v_cod_padre := CASE WHEN position('.' IN v_fila.codigo) > 0
                            THEN regexp_replace(v_fila.codigo, '\.[^.]+$', '') END;

        v_padre_id := NULL; v_padre_nivel := NULL; v_padre_tipo := NULL;
        IF v_cod_padre IS NOT NULL THEN
            SELECT id, nivel, tipo INTO v_padre_id, v_padre_nivel, v_padre_tipo
              FROM contabilidad.plan_cuentas WHERE codigo = v_cod_padre;
            IF v_padre_id IS NULL THEN
                RAISE EXCEPTION 'La cuenta % no tiene de dónde colgar: falta la %', v_fila.codigo, v_cod_padre;
            END IF;
        END IF;

        SELECT COALESCE(MAX(orden), 0) + 1 INTO v_orden
          FROM contabilidad.plan_cuentas
         WHERE padre_id IS NOT DISTINCT FROM v_padre_id;

        INSERT INTO contabilidad.plan_cuentas
            (padre_id, orden, nivel, codigo, nombre, descripcion, tipo, naturaleza, es_movimiento, activo)
        VALUES (
            v_padre_id,
            v_orden,
            COALESCE(v_padre_nivel + 1, 0),
            v_fila.codigo,
            v_fila.nombre,
            v_fila.descripcion,
            -- El tipo se escribe sólo en la raíz y baja a toda la rama
            COALESCE(v_fila.tipo, v_padre_tipo),
            COALESCE(v_fila.naturaleza,
                     CASE WHEN COALESCE(v_fila.tipo, v_padre_tipo) IN ('ACTIVO','COSTO','GASTO')
                          THEN 'DEUDORA' ELSE 'ACREEDORA' END),
            v_fila.es_hoja,
            true
        );
        v_n := v_n + 1;
    END LOOP;

    RAISE NOTICE 'Plan de cuentas base: % cuentas, % niveles',
        v_n, (SELECT MAX(nivel) + 1 FROM contabilidad.plan_cuentas);
END
$$;

COMMIT;
