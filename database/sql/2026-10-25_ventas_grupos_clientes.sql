-- ===========================================================================
-- GRUPOS DE CLIENTES (ventas.grupos_clientes)
-- ===========================================================================
-- El mismo árbol de inventarios.categorias —padre, orden, nivel, papelera,
-- auditoría, cuatro niveles— pero para clientes, y con una diferencia de
-- fondo: AQUÍ EL ÁRBOL CARGA VALORES, no sólo clasifica.
--
-- Forma de pago, cupo, días de crédito y descuento son casi siempre los
-- mismos para todo un grupo de clientes, así que se ponen una vez en el grupo
-- y los de abajo los heredan. Las cuatro columnas son ANULABLES, y un nulo no
-- significa cero: significa «lo que diga el grupo de arriba».
--
--     Mayoristas          8 %, 30 días
--     ├─ Cadenas         12 %, 45 días   ← sólo esto se guarda
--     └─ Distribuidores    (hereda 8 %, 30 días)
--
-- Lo que NO se copia de categorías es la regla de «si admite productos no
-- admite subcategorías». Aquí estorba: es normal un mayorista suelto colgando
-- de «Mayoristas» sin estar en ninguna subrama, y no genera ambigüedad —sus
-- condiciones se resuelven subiendo desde su propio grupo—.
--
-- EL VALOR DEL CLIENTE SIGUE MANDANDO sobre el del grupo. Las columnas de
-- ventas.clientes se quedan como están (NOT NULL con cero por omisión), así
-- que nada de lo que hay hoy cambia de comportamiento: el grupo es el valor
-- por omisión de los clientes que no tengan el suyo.
\set ON_ERROR_STOP on

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. LA TABLA
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS ventas.grupos_clientes (
    id          bigserial    PRIMARY KEY,
    padre_id    bigint,
    orden       integer      NOT NULL DEFAULT 1,
    nivel       integer      NOT NULL DEFAULT 0,

    nombre      varchar(100) NOT NULL,
    descripcion text,
    icono       varchar(50),

    /* ---- LO QUE EL GRUPO APORTA ----
       Anulables a propósito: vacío = lo que diga el grupo de arriba, y al
       final nada. Un cero aquí es un cero de verdad: «sin descuento». */
    forma_pago     varchar(20),
    limite_credito numeric(12,2),
    dias_credito   integer,
    descuento      numeric(5,2),

    activo      boolean      NOT NULL DEFAULT true,

    created_at  timestamptz  NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at  timestamptz  NOT NULL DEFAULT CURRENT_TIMESTAMP,
    created_by  varchar(100),
    updated_by  varchar(100),
    deleted_at  timestamptz,
    deleted_by  varchar(100),

    CONSTRAINT fk_grupos_clientes_padre FOREIGN KEY (padre_id) REFERENCES ventas.grupos_clientes(id),
    CONSTRAINT ck_grupos_clientes_no_padre_si_mismo CHECK (padre_id IS NULL OR padre_id <> id),
    /* Cuatro niveles, igual que el árbol de categorías */
    CONSTRAINT ck_grupos_clientes_nivel  CHECK (nivel >= 0 AND nivel <= 3),
    CONSTRAINT ck_grupos_clientes_nombre CHECK (length(TRIM(nombre)) >= 2),
    /* La misma lista que ventas.clientes.forma_pago */
    CONSTRAINT ck_grupos_clientes_forma_pago CHECK (forma_pago IS NULL OR forma_pago IN
        ('EFECTIVO','TRANSFERENCIA','TARJETA','CHEQUE','CREDITO')),
    CONSTRAINT ck_grupos_clientes_limite    CHECK (limite_credito IS NULL OR limite_credito >= 0),
    CONSTRAINT ck_grupos_clientes_dias      CHECK (dias_credito IS NULL OR dias_credito >= 0),
    CONSTRAINT ck_grupos_clientes_descuento CHECK (descuento IS NULL OR (descuento >= 0 AND descuento <= 100))
);

COMMENT ON TABLE  ventas.grupos_clientes IS 'Árbol de grupos de clientes; carga las condiciones comerciales que heredan los de abajo';
COMMENT ON COLUMN ventas.grupos_clientes.forma_pago IS 'NULL = la del grupo de arriba; no es lo mismo que vacía';
COMMENT ON COLUMN ventas.grupos_clientes.descuento IS 'NULL = el del grupo de arriba. Un 0 aquí sí es «sin descuento»';

-- Los mismos índices del árbol de categorías: el nombre no se repite entre
-- hermanos, y cuentan también a los que están en la papelera para que uno
-- restaurado siempre encuentre libre su nombre.
CREATE UNIQUE INDEX IF NOT EXISTS uq_grupos_clientes_nombre_hermano
    ON ventas.grupos_clientes (padre_id, UPPER(TRIM(nombre))) WHERE padre_id IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS uq_grupos_clientes_nombre_raiz
    ON ventas.grupos_clientes (UPPER(TRIM(nombre))) WHERE padre_id IS NULL;
CREATE INDEX IF NOT EXISTS ix_grupos_clientes_padre ON ventas.grupos_clientes (padre_id, orden);
CREATE INDEX IF NOT EXISTS ix_grupos_clientes_deleted_at
    ON ventas.grupos_clientes (deleted_at) WHERE deleted_at IS NOT NULL;

DROP TRIGGER IF EXISTS trigger_grupos_clientes_set_users  ON ventas.grupos_clientes;
DROP TRIGGER IF EXISTS trigger_grupos_clientes_updated_at ON ventas.grupos_clientes;
DROP TRIGGER IF EXISTS trg_grupos_clientes_audit          ON ventas.grupos_clientes;

CREATE TRIGGER trigger_grupos_clientes_set_users
    BEFORE INSERT OR UPDATE ON ventas.grupos_clientes
    FOR EACH ROW EXECUTE FUNCTION auditoria.fn_set_audit_users();
CREATE TRIGGER trigger_grupos_clientes_updated_at
    BEFORE UPDATE ON ventas.grupos_clientes
    FOR EACH ROW EXECUTE FUNCTION auditoria.fn_update_updated_at_column();
CREATE TRIGGER trg_grupos_clientes_audit
    AFTER INSERT OR UPDATE OR DELETE ON ventas.grupos_clientes
    FOR EACH ROW EXECUTE FUNCTION auditoria.fn_auditar_cambios();

-- ---------------------------------------------------------------------------
-- 2. EL CLIENTE APUNTA A SU GRUPO
-- ---------------------------------------------------------------------------
-- Anulable: sin grupo, el cliente se comporta exactamente como hoy.
ALTER TABLE ventas.clientes ADD COLUMN IF NOT EXISTS grupo_cliente_id bigint;
ALTER TABLE ventas.clientes DROP CONSTRAINT IF EXISTS fk_clientes_grupo;
ALTER TABLE ventas.clientes ADD CONSTRAINT fk_clientes_grupo
    FOREIGN KEY (grupo_cliente_id) REFERENCES ventas.grupos_clientes(id);
CREATE INDEX IF NOT EXISTS ix_clientes_grupo ON ventas.clientes (grupo_cliente_id)
 WHERE grupo_cliente_id IS NOT NULL;

COMMENT ON COLUMN ventas.clientes.grupo_cliente_id IS 'Grupo comercial; de él salen las condiciones que el cliente no tenga propias';


-- ---------------------------------------------------------------------------
-- LO PROPIO DE LOS GRUPOS DE CLIENTES
-- ---------------------------------------------------------------------------
-- condiciones, json, crear, modificar, eliminar y eliminar definitivo. Lo
-- demás —listar, obtener, activar, mover y la papelera— se convierte desde el
-- árbol de categorías, que es el mismo y ya está probado.

-- ---------------------------------------------------------------------------
-- LAS CONDICIONES QUE LE TOCAN A UN GRUPO
-- ---------------------------------------------------------------------------
-- Para cada una de las cuatro: la que tiene puesta, la que de verdad se usa
-- —que puede venir de un grupo de arriba— y DE DÓNDE SALE, que es lo que hace
-- entendible la pantalla. Un nulo en la columna no es un cero: es «lo que
-- diga el de arriba», y si nadie dijo nada, no hay valor.
CREATE OR REPLACE FUNCTION ventas.fn_grupos_clientes_condiciones(p_id bigint)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
AS $function$
    WITH RECURSIVE sube AS (
        SELECT g.id, g.padre_id, 0 AS salto, g.nombre,
               g.forma_pago, g.limite_credito, g.dias_credito, g.descuento
          FROM ventas.grupos_clientes g WHERE g.id = p_id
        UNION ALL
        SELECT p.id, p.padre_id, s.salto + 1, p.nombre,
               p.forma_pago, p.limite_credito, p.dias_credito, p.descuento
          FROM ventas.grupos_clientes p JOIN sube s ON p.id = s.padre_id
    ),
    -- La primera de cada rama que diga algo, subiendo
    fp  AS (SELECT * FROM sube WHERE forma_pago     IS NOT NULL ORDER BY salto LIMIT 1),
    lim AS (SELECT * FROM sube WHERE limite_credito IS NOT NULL ORDER BY salto LIMIT 1),
    dia AS (SELECT * FROM sube WHERE dias_credito   IS NOT NULL ORDER BY salto LIMIT 1),
    des AS (SELECT * FROM sube WHERE descuento      IS NOT NULL ORDER BY salto LIMIT 1),
    yo  AS (SELECT * FROM sube WHERE salto = 0)
    SELECT jsonb_build_object(
        'forma_pago', jsonb_build_object(
            'propio',          (SELECT forma_pago FROM yo),
            'efectivo',        (SELECT forma_pago FROM fp),
            'origen_id',       (SELECT id FROM fp),
            'origen_etiqueta', (SELECT CASE WHEN salto = 0 THEN 'Propia' ELSE 'Heredada de ' || nombre END FROM fp)),
        'limite_credito', jsonb_build_object(
            'propio',          (SELECT limite_credito FROM yo),
            'efectivo',        (SELECT limite_credito FROM lim),
            'origen_id',       (SELECT id FROM lim),
            'origen_etiqueta', (SELECT CASE WHEN salto = 0 THEN 'Propio' ELSE 'Heredado de ' || nombre END FROM lim)),
        'dias_credito', jsonb_build_object(
            'propio',          (SELECT dias_credito FROM yo),
            'efectivo',        (SELECT dias_credito FROM dia),
            'origen_id',       (SELECT id FROM dia),
            'origen_etiqueta', (SELECT CASE WHEN salto = 0 THEN 'Propios' ELSE 'Heredados de ' || nombre END FROM dia)),
        'descuento', jsonb_build_object(
            'propio',          (SELECT descuento FROM yo),
            'efectivo',        (SELECT descuento FROM des),
            'origen_id',       (SELECT id FROM des),
            'origen_etiqueta', (SELECT CASE WHEN salto = 0 THEN 'Propio' ELSE 'Heredado de ' || nombre END FROM des))
    );
$function$;

-- ---------------------------------------------------------------------------
-- LA FICHA DE UN GRUPO
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
$function$;

-- ---------------------------------------------------------------------------
-- LO QUE SE PUEDE PONER EN LAS CUATRO CONDICIONES
-- ---------------------------------------------------------------------------
-- La tabla ya lo comprueba con sus CHECK, pero ahí el error sale en crudo
-- («viola la restricción ck_grupos_clientes_descuento»). Esto es lo mismo
-- dicho en castellano, y lo usan crear y modificar.
CREATE OR REPLACE FUNCTION ventas.fn_grupos_clientes_revisar_condiciones(
    p_forma_pago     character varying,
    p_limite_credito numeric,
    p_dias_credito   integer,
    p_descuento      numeric)
 RETURNS void
 LANGUAGE plpgsql
 IMMUTABLE
AS $function$
BEGIN
    IF NULLIF(TRIM(COALESCE(p_forma_pago, '')), '') IS NOT NULL
       AND UPPER(TRIM(p_forma_pago)) NOT IN ('EFECTIVO','TRANSFERENCIA','TARJETA','CHEQUE','CREDITO') THEN
        RAISE EXCEPTION 'La forma de pago «%» no existe. Use EFECTIVO, TRANSFERENCIA, TARJETA, CHEQUE o CREDITO', TRIM(p_forma_pago)
            USING ERRCODE = 'P0001';
    END IF;

    IF p_limite_credito IS NOT NULL AND p_limite_credito < 0 THEN
        RAISE EXCEPTION 'El cupo de crédito no puede ser negativo' USING ERRCODE = 'P0001';
    END IF;

    IF p_dias_credito IS NOT NULL AND p_dias_credito < 0 THEN
        RAISE EXCEPTION 'Los días de crédito no pueden ser negativos' USING ERRCODE = 'P0001';
    END IF;

    IF p_descuento IS NOT NULL AND (p_descuento < 0 OR p_descuento > 100) THEN
        RAISE EXCEPTION 'El descuento va de 0 a 100 y llegó %', p_descuento USING ERRCODE = 'P0001';
    END IF;
END;
$function$;

-- ---------------------------------------------------------------------------
-- CREAR
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ventas.fn_grupos_clientes_crear(
    p_nombre character varying,
    p_padre_id bigint DEFAULT NULL::bigint,
    p_descripcion text DEFAULT NULL::text,
    p_icono character varying DEFAULT NULL::character varying,
    p_activo boolean DEFAULT true,
    p_forma_pago character varying DEFAULT NULL::character varying,
    p_limite_credito numeric DEFAULT NULL::numeric,
    p_dias_credito integer DEFAULT NULL::integer,
    p_descuento numeric DEFAULT NULL::numeric,
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
    v_id    bigint;
    v_nivel integer := 0;
    v_orden integer;
    v_nuevo jsonb;
BEGIN
    PERFORM ventas.fn_contexto_auditoria('ventas.grupos_clientes',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    IF p_nombre IS NULL OR length(TRIM(p_nombre)) < 2 THEN
        RAISE EXCEPTION 'El nombre del grupo es obligatorio (mínimo 2 caracteres)' USING ERRCODE = 'P0001';
    END IF;

    PERFORM ventas.fn_grupos_clientes_revisar_condiciones(
        p_forma_pago, p_limite_credito, p_dias_credito, p_descuento);

    IF p_padre_id IS NOT NULL THEN
        SELECT nivel + 1 INTO v_nivel FROM ventas.grupos_clientes WHERE id = p_padre_id;
        IF v_nivel IS NULL THEN
            RAISE EXCEPTION 'El grupo padre no existe' USING ERRCODE = 'P0016';
        END IF;
        IF v_nivel > 3 THEN
            RAISE EXCEPTION 'El árbol admite hasta cuatro niveles (0 a 3) y ahí quedaría en el %', v_nivel
                USING ERRCODE = 'P0015';
        END IF;
        -- A propósito NO se comprueba si el padre tiene clientes: a diferencia
        -- de las categorías, aquí es normal que un cliente cuelgue de un nodo
        -- intermedio y eso no crea ninguna ambigüedad.
    END IF;

    -- Entre hermanos el nombre no se repite; en otra rama sí puede
    IF EXISTS (SELECT 1 FROM ventas.grupos_clientes
                WHERE padre_id IS NOT DISTINCT FROM p_padre_id
                  AND UPPER(TRIM(nombre)) = UPPER(TRIM(p_nombre))) THEN
        IF EXISTS (SELECT 1 FROM ventas.grupos_clientes
                    WHERE padre_id IS NOT DISTINCT FROM p_padre_id
                      AND UPPER(TRIM(nombre)) = UPPER(TRIM(p_nombre))
                      AND deleted_at IS NOT NULL) THEN
            RAISE EXCEPTION 'Ya existe un grupo con ese nombre en el mismo nivel, y está en la papelera de reciclaje' USING ERRCODE = 'P0006';
        END IF;
        RAISE EXCEPTION 'Ya existe un grupo con ese nombre en el mismo nivel' USING ERRCODE = 'P0006';
    END IF;

    SELECT COALESCE(MAX(orden), 0) + 1 INTO v_orden
      FROM ventas.grupos_clientes WHERE padre_id IS NOT DISTINCT FROM p_padre_id;

    v_nuevo := jsonb_build_object(
        'padre_id',       p_padre_id,
        'nivel',          v_nivel,
        'orden',          v_orden,
        'nombre',         TRIM(p_nombre),
        'descripcion',    NULLIF(TRIM(COALESCE(p_descripcion, '')), ''),
        'icono',          NULLIF(TRIM(COALESCE(p_icono, '')), ''),
        'activo',         COALESCE(p_activo, true),
        'forma_pago',     NULLIF(UPPER(TRIM(COALESCE(p_forma_pago, ''))), ''),
        'limite_credito', p_limite_credito,
        'dias_credito',   p_dias_credito,
        'descuento',      p_descuento
    );
    PERFORM set_config('app.datos_nuevos', v_nuevo::text, true);

    INSERT INTO ventas.grupos_clientes
        (padre_id, orden, nivel, nombre, descripcion, icono, activo,
         forma_pago, limite_credito, dias_credito, descuento)
    VALUES (
        p_padre_id, v_orden, v_nivel,
        TRIM(p_nombre),
        NULLIF(TRIM(COALESCE(p_descripcion, '')), ''),
        NULLIF(TRIM(COALESCE(p_icono, '')), ''),
        COALESCE(p_activo, true),
        NULLIF(UPPER(TRIM(COALESCE(p_forma_pago, ''))), ''),
        p_limite_credito, p_dias_credito, p_descuento
    )
    RETURNING id INTO v_id;

    PERFORM set_config('app.datos_nuevos', '', true);

    RETURN jsonb_build_object('success', true, 'message', 'Grupo creado exitosamente',
                              'data', ventas.fn_grupos_clientes_json(v_id));

EXCEPTION
    WHEN unique_violation THEN
        RAISE EXCEPTION 'Ya existe un grupo con ese nombre en el mismo nivel' USING ERRCODE = 'P0006';
END;
$function$;

-- ---------------------------------------------------------------------------
-- MODIFICAR
-- ---------------------------------------------------------------------------
-- NO CAMBIA DE PADRE: mover es otra cosa y tiene su propia función.
CREATE OR REPLACE FUNCTION ventas.fn_grupos_clientes_modificar(
    p_id bigint,
    p_nombre character varying,
    p_descripcion text DEFAULT NULL::text,
    p_icono character varying DEFAULT NULL::character varying,
    p_activo boolean DEFAULT true,
    p_forma_pago character varying DEFAULT NULL::character varying,
    p_limite_credito numeric DEFAULT NULL::numeric,
    p_dias_credito integer DEFAULT NULL::integer,
    p_descuento numeric DEFAULT NULL::numeric,
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
    v_antes jsonb;
    v_padre bigint;
    v_hay   boolean;
    v_nuevo jsonb;
BEGIN
    PERFORM ventas.fn_contexto_auditoria('ventas.grupos_clientes',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    SELECT padre_id INTO v_padre FROM ventas.grupos_clientes WHERE id = p_id;
    v_hay := FOUND;
    IF NOT v_hay THEN
        RAISE EXCEPTION 'El grupo no existe' USING ERRCODE = 'P0013';
    END IF;
    v_antes := ventas.fn_grupos_clientes_json(p_id);

    IF p_nombre IS NULL OR length(TRIM(p_nombre)) < 2 THEN
        RAISE EXCEPTION 'El nombre del grupo es obligatorio (mínimo 2 caracteres)' USING ERRCODE = 'P0001';
    END IF;

    PERFORM ventas.fn_grupos_clientes_revisar_condiciones(
        p_forma_pago, p_limite_credito, p_dias_credito, p_descuento);

    IF EXISTS (SELECT 1 FROM ventas.grupos_clientes
                WHERE padre_id IS NOT DISTINCT FROM v_padre
                  AND UPPER(TRIM(nombre)) = UPPER(TRIM(p_nombre))
                  AND id <> p_id) THEN
        RAISE EXCEPTION 'Ya existe otro grupo con ese nombre en el mismo nivel' USING ERRCODE = 'P0006';
    END IF;

    v_nuevo := jsonb_build_object(
        'nombre',         TRIM(p_nombre),
        'descripcion',    NULLIF(TRIM(COALESCE(p_descripcion, '')), ''),
        'icono',          NULLIF(TRIM(COALESCE(p_icono, '')), ''),
        'activo',         COALESCE(p_activo, true),
        'forma_pago',     NULLIF(UPPER(TRIM(COALESCE(p_forma_pago, ''))), ''),
        'limite_credito', p_limite_credito,
        'dias_credito',   p_dias_credito,
        'descuento',      p_descuento
    );
    PERFORM set_config('app.datos_anteriores',
        jsonb_build_object('nombre',         v_antes->>'nombre',
                           'descripcion',    v_antes->>'descripcion',
                           'icono',          v_antes->>'icono',
                           'activo',         (v_antes->>'activo')::boolean,
                           'forma_pago',     v_antes->>'forma_pago',
                           'limite_credito', v_antes->>'limite_credito',
                           'dias_credito',   v_antes->>'dias_credito',
                           'descuento',      v_antes->>'descuento')::text, true);
    PERFORM set_config('app.datos_nuevos', v_nuevo::text, true);

    -- Las cuatro condiciones se guardan TAL CUAL, nulos incluidos: un nulo es
    -- «lo que diga el de arriba» y es la forma de volver a heredar.
    UPDATE ventas.grupos_clientes
       SET nombre         = TRIM(p_nombre),
           descripcion    = NULLIF(TRIM(COALESCE(p_descripcion, '')), ''),
           icono          = NULLIF(TRIM(COALESCE(p_icono, '')), ''),
           activo         = COALESCE(p_activo, true),
           forma_pago     = NULLIF(UPPER(TRIM(COALESCE(p_forma_pago, ''))), ''),
           limite_credito = p_limite_credito,
           dias_credito   = p_dias_credito,
           descuento      = p_descuento
     WHERE id = p_id;

    PERFORM set_config('app.datos_anteriores', '', true);
    PERFORM set_config('app.datos_nuevos', '', true);

    RETURN jsonb_build_object('success', true, 'message', 'Grupo actualizado exitosamente',
                              'data', ventas.fn_grupos_clientes_json(p_id));

EXCEPTION
    WHEN unique_violation THEN
        RAISE EXCEPTION 'Ya existe otro grupo con ese nombre en el mismo nivel (puede estar en la papelera de reciclaje)' USING ERRCODE = 'P0006';
END;
$function$;

-- ---------------------------------------------------------------------------
-- A LA PAPELERA
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ventas.fn_grupos_clientes_eliminar(
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
$function$;

-- ---------------------------------------------------------------------------
-- BORRAR DE VERDAD
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ventas.fn_grupos_clientes_eliminar_definitivo(
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
 SET search_path TO 'pg_catalog', 'ventas', 'auditoria'
AS $function$
DECLARE
    v_g        record;
    v_n        integer := 0;
    v_hijos    bigint;
    v_clientes bigint;
    v_nombres  text[] := '{}';
BEGIN
    PERFORM ventas.fn_contexto_auditoria('ventas.grupos_clientes',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    IF p_ids IS NULL OR jsonb_typeof(p_ids) <> 'array' OR jsonb_array_length(p_ids) = 0 THEN
        RAISE EXCEPTION 'No se indicó ningún grupo' USING ERRCODE = 'P0001';
    END IF;

    -- De lo más hondo a lo más alto: al vaciar la papelera entera, los hijos
    -- se van antes que sus padres y no choca la clave ajena
    FOR v_g IN
        SELECT g.id, g.nombre
          FROM ventas.grupos_clientes g
         WHERE g.id IN (SELECT (x)::bigint FROM jsonb_array_elements_text(p_ids) x)
           AND g.deleted_at IS NOT NULL
         ORDER BY g.nivel DESC, g.id DESC
    LOOP
        SELECT COUNT(*) INTO v_hijos FROM ventas.grupos_clientes WHERE padre_id = v_g.id;
        IF v_hijos > 0 THEN
            RAISE EXCEPTION 'No se puede eliminar «%» definitivamente: todavía tiene % subgrupo(s), aunque estén en la papelera. Bórrelos primero.', v_g.nombre, v_hijos
                USING ERRCODE = 'P0014';
        END IF;

        SELECT COUNT(*) INTO v_clientes FROM ventas.clientes WHERE grupo_cliente_id = v_g.id;
        IF v_clientes > 0 THEN
            RAISE EXCEPTION 'No se puede eliminar «%» definitivamente: todavía lo usan % cliente(s), aunque estén en la papelera.', v_g.nombre, v_clientes
                USING ERRCODE = 'P0014';
        END IF;

        PERFORM set_config('app.datos_anteriores', (ventas.fn_grupos_clientes_json(v_g.id))::text, true);
        DELETE FROM ventas.grupos_clientes WHERE id = v_g.id;

        v_n := v_n + 1;
        v_nombres := v_nombres || v_g.nombre::text;
    END LOOP;

    PERFORM set_config('app.datos_anteriores', '', true);

    IF v_n = 0 THEN
        RAISE EXCEPTION 'Ninguno de esos grupos está en la papelera' USING ERRCODE = 'P0019';
    END IF;

    RETURN jsonb_build_object(
        'success', true,
        'message', CASE WHEN v_n = 1 THEN format('Grupo «%s» eliminado definitivamente', v_nombres[1])
                        ELSE format('%s grupos eliminados definitivamente', v_n) END,
        'data', jsonb_build_object('borradas', v_n, 'nombres', to_jsonb(v_nombres))
    );

EXCEPTION
    WHEN foreign_key_violation THEN
        RAISE EXCEPTION 'No se puede eliminar definitivamente: algo sigue apuntando a ese grupo' USING ERRCODE = 'P0014';
END;
$function$;

-- ---------------------------------------------------------------------------
-- LAS DEL ÁRBOL: listar, obtener, activar, mover y la papelera
-- ---------------------------------------------------------------------------
-- Convertidas desde inventarios.fn_categorias_*, que es el mismo árbol y ya
-- está probado. La única diferencia está en `mover`: allí no se puede soltar
-- nada dentro de una categoría que admite productos, y aquí sí, porque un
-- cliente colgando de un nodo intermedio no crea ninguna ambigüedad.

CREATE OR REPLACE FUNCTION ventas.fn_grupos_clientes_listar(p_solo_activos boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'ventas'
AS $function$
DECLARE
    v_data jsonb;
BEGIN
    WITH RECURSIVE arbol AS (
        SELECT c.id, c.padre_id, c.orden, c.activo,
               LPAD(c.orden::text, 5, '0') AS ruta_orden
          FROM ventas.grupos_clientes c
         WHERE c.padre_id IS NULL
           AND c.deleted_at IS NULL

        UNION ALL

        SELECT h.id, h.padre_id, h.orden, h.activo,
               a.ruta_orden || '.' || LPAD(h.orden::text, 5, '0')
          FROM ventas.grupos_clientes h
          JOIN arbol a ON h.padre_id = a.id
         WHERE h.deleted_at IS NULL
    )
    SELECT COALESCE(jsonb_agg(ventas.fn_grupos_clientes_json(a.id) ORDER BY a.ruta_orden), '[]'::jsonb)
      INTO v_data
      FROM arbol a
     WHERE NOT p_solo_activos OR a.activo;

    RETURN jsonb_build_object('success', true, 'data', v_data);

EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false, 'message', 'Error al listar grupos: ' || SQLERRM, 'error_code', SQLSTATE);
END;
$function$;

CREATE OR REPLACE FUNCTION ventas.fn_grupos_clientes_obtener(p_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
AS $function$
DECLARE
    v_data jsonb;
BEGIN
    v_data := ventas.fn_grupos_clientes_json(p_id);
    IF v_data IS NULL THEN
        RAISE EXCEPTION 'El grupo no existe' USING ERRCODE = 'P0013';
    END IF;
    RETURN jsonb_build_object('success', true, 'message', 'Grupo encontrado', 'data', v_data);
END;
$function$;

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
$function$;

CREATE OR REPLACE FUNCTION ventas.fn_grupos_clientes_mover(p_id bigint, p_padre_id bigint DEFAULT NULL::bigint, p_antes_de bigint DEFAULT NULL::bigint, p_usuario_id bigint DEFAULT NULL::bigint, p_usuario_login character varying DEFAULT NULL::character varying, p_usuario_nombre character varying DEFAULT NULL::character varying, p_ip_address inet DEFAULT NULL::inet, p_user_agent text DEFAULT NULL::text, p_request_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'ventas', 'auditoria'
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
    PERFORM ventas.fn_contexto_auditoria('ventas.grupos_clientes',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    SELECT padre_id INTO v_padre_actual FROM ventas.grupos_clientes WHERE id = p_id;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'error_code', 'NO_EXISTE', 'message', 'El grupo no existe');
    END IF;

    IF p_padre_id IS NOT NULL THEN
        IF p_padre_id = p_id THEN
            RETURN jsonb_build_object('success', false, 'error_code', 'AUTOREFERENCIA',
                                      'message', 'Un grupo no puede estar dentro de sí mismo');
        END IF;
        -- Un grupo de la papelera no es un destino: no se ve en el
        -- árbol, y lo que colgara de ella desaparecería con ella.
        IF NOT EXISTS (SELECT 1 FROM ventas.grupos_clientes WHERE id = p_padre_id AND deleted_at IS NULL) THEN
            RETURN jsonb_build_object('success', false, 'error_code', 'PADRE_NO_EXISTE',
                                      'message', 'El grupo destino no existe');
        END IF;
        -- El destino no puede colgar de la que se mueve (ciclo)
        IF EXISTS (
            WITH RECURSIVE d AS (
                SELECT id FROM ventas.grupos_clientes WHERE padre_id = p_id
                UNION ALL
                SELECT c.id FROM ventas.grupos_clientes c JOIN d ON c.padre_id = d.id
            )
            SELECT 1 FROM d WHERE d.id = p_padre_id
        ) THEN
            RETURN jsonb_build_object('success', false, 'error_code', 'CICLO',
                                      'message', 'No se puede mover un grupo dentro de uno de sus propios subgrupos');
        END IF;
        -- Aquí NO se comprueba si el destino tiene clientes: a diferencia de
        -- las categorías, un cliente colgando de un nodo intermedio es normal
        -- y sus condiciones se resuelven subiendo desde su propio grupo.

        SELECT nivel + 1 INTO v_nivel_nuevo FROM ventas.grupos_clientes WHERE id = p_padre_id;
    ELSE
        v_nivel_nuevo := 0;
    END IF;

    -- Lo hondo que es la rama que se mueve (0 = sin hijos)
    WITH RECURSIVE d AS (
        SELECT id, 1 AS prof FROM ventas.grupos_clientes WHERE padre_id = p_id
        UNION ALL
        SELECT c.id, d.prof + 1 FROM ventas.grupos_clientes c JOIN d ON c.padre_id = d.id
    )
    SELECT COALESCE(MAX(prof), 0) INTO v_profundidad FROM d;

    IF v_nivel_nuevo + v_profundidad > v_max_nivel THEN
        RETURN jsonb_build_object('success', false, 'error_code', 'NIVEL_MAXIMO',
            'message', format('Ahí quedaría en el nivel %s y el árbol admite hasta el %s (lo que mueves tiene %s nivel(es) por debajo)',
                              v_nivel_nuevo + v_profundidad, v_max_nivel, v_profundidad));
    END IF;

    -- El nombre tampoco se puede repetir entre los hermanos NUEVOS
    IF EXISTS (SELECT 1 FROM ventas.grupos_clientes
                WHERE padre_id IS NOT DISTINCT FROM p_padre_id
                  AND id <> p_id
                  AND UPPER(TRIM(nombre)) = (SELECT UPPER(TRIM(nombre)) FROM ventas.grupos_clientes WHERE id = p_id)) THEN
        RETURN jsonb_build_object('success', false, 'error_code', 'NOMBRE_DUPLICADO',
                                  'message', 'Ahí ya hay un grupo con ese nombre');
    END IF;

    -- Padre y nivel; y el nivel de los descendientes, en cascada
    UPDATE ventas.grupos_clientes
       SET padre_id = p_padre_id, nivel = v_nivel_nuevo
     WHERE id = p_id
       AND (padre_id IS DISTINCT FROM p_padre_id OR nivel IS DISTINCT FROM v_nivel_nuevo);

    FOR v_fila IN
        WITH RECURSIVE d AS (
            SELECT id, v_nivel_nuevo + 1 AS nivel_ok FROM ventas.grupos_clientes WHERE padre_id = p_id
            UNION ALL
            SELECT c.id, d.nivel_ok + 1 FROM ventas.grupos_clientes c JOIN d ON c.padre_id = d.id
        )
        SELECT d.id, d.nivel_ok FROM d JOIN ventas.grupos_clientes c ON c.id = d.id
         WHERE c.nivel IS DISTINCT FROM d.nivel_ok
    LOOP
        UPDATE ventas.grupos_clientes SET nivel = v_fila.nivel_ok WHERE id = v_fila.id;
    END LOOP;

    -- Sitio entre los hermanos del destino: se saca el movido, se mete
    -- delante de p_antes_de (o al final) y se renumera 1..N
    CREATE TEMP TABLE IF NOT EXISTS tmp_grupos_hermanos (id bigint, pos integer) ON COMMIT DROP;
    DELETE FROM tmp_grupos_hermanos;

    INSERT INTO tmp_grupos_hermanos (id, pos)
    SELECT id, ROW_NUMBER() OVER (ORDER BY orden, nombre)
      FROM ventas.grupos_clientes
     WHERE padre_id IS NOT DISTINCT FROM p_padre_id AND id <> p_id;

    IF p_antes_de IS NOT NULL AND p_antes_de <> p_id THEN
        SELECT pos INTO v_pos FROM tmp_grupos_hermanos WHERE id = p_antes_de;
    END IF;
    IF v_pos IS NULL THEN
        SELECT COALESCE(MAX(pos), 0) + 1 INTO v_pos FROM tmp_grupos_hermanos;
    END IF;

    UPDATE tmp_grupos_hermanos SET pos = pos + 1 WHERE pos >= v_pos;
    INSERT INTO tmp_grupos_hermanos (id, pos) VALUES (p_id, v_pos);

    v_i := 0;
    FOR v_fila IN SELECT id FROM tmp_grupos_hermanos ORDER BY pos LOOP
        v_i := v_i + 1;
        UPDATE ventas.grupos_clientes SET orden = v_i WHERE id = v_fila.id AND orden IS DISTINCT FROM v_i;
    END LOOP;

    -- Y los hermanos que dejó atrás, sin huecos
    IF v_padre_actual IS DISTINCT FROM p_padre_id THEN
        v_i := 0;
        FOR v_fila IN
            SELECT id FROM ventas.grupos_clientes
             WHERE padre_id IS NOT DISTINCT FROM v_padre_actual
             ORDER BY orden, nombre
        LOOP
            v_i := v_i + 1;
            UPDATE ventas.grupos_clientes SET orden = v_i WHERE id = v_fila.id AND orden IS DISTINCT FROM v_i;
        END LOOP;
    END IF;

    RETURN jsonb_build_object(
        'success', true,
        'message', CASE WHEN v_padre_actual IS DISTINCT FROM p_padre_id THEN 'Grupo movido' ELSE 'Orden actualizado' END,
        'data', ventas.fn_grupos_clientes_json(p_id)
    );

EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false, 'error_code', SQLSTATE,
                              'message', 'Error al mover el grupo: ' || SQLERRM);
END;
$function$;

CREATE OR REPLACE FUNCTION ventas.fn_grupos_clientes_papelera_listar()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
AS $function$
DECLARE
    v_data jsonb;
BEGIN
    SELECT COALESCE(jsonb_agg(
               ventas.fn_grupos_clientes_json(c.id)
               -- `padre_en_papelera` evita que haya que adivinar por qué una
               -- hija no se deja restaurar: la pantalla ya lo sabe.
               || jsonb_build_object('padre_en_papelera',
                      EXISTS (SELECT 1 FROM ventas.grupos_clientes p
                               WHERE p.id = c.padre_id AND p.deleted_at IS NOT NULL))
               ORDER BY c.deleted_at DESC, c.id DESC), '[]'::jsonb)
      INTO v_data
      FROM ventas.grupos_clientes c
     WHERE c.deleted_at IS NOT NULL;

    RETURN jsonb_build_object('success', true, 'data', v_data, 'total', jsonb_array_length(v_data));
EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object('success', false, 'message', 'Error al listar la papelera: ' || SQLERRM, 'error_code', SQLSTATE);
END;
$function$;

CREATE OR REPLACE FUNCTION ventas.fn_grupos_clientes_restaurar(p_ids jsonb, p_usuario_id bigint DEFAULT NULL::bigint, p_usuario_login character varying DEFAULT NULL::character varying, p_usuario_nombre character varying DEFAULT NULL::character varying, p_ip_address inet DEFAULT NULL::inet, p_user_agent text DEFAULT NULL::text, p_request_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'ventas', 'auditoria'
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
    PERFORM ventas.fn_contexto_auditoria('ventas.grupos_clientes',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    IF p_ids IS NULL OR jsonb_typeof(p_ids) <> 'array' OR jsonb_array_length(p_ids) = 0 THEN
        RAISE EXCEPTION 'No se indicó ningún grupo' USING ERRCODE = 'P0001';
    END IF;

    -- De arriba abajo: si se restauran madre e hija a la vez, la madre va
    -- primero y la hija ya se encuentra con el sitio hecho
    FOR v_c IN
        SELECT c.id, c.nombre, c.padre_id, c.nivel
          FROM ventas.grupos_clientes c
         WHERE c.id IN (SELECT (x)::bigint FROM jsonb_array_elements_text(p_ids) x)
           AND c.deleted_at IS NOT NULL
         ORDER BY c.nivel, c.id
    LOOP
        IF v_c.padre_id IS NOT NULL
           AND EXISTS (SELECT 1 FROM ventas.grupos_clientes p
                        WHERE p.id = v_c.padre_id AND p.deleted_at IS NOT NULL) THEN
            v_colgadas := v_colgadas + 1;
            CONTINUE;
        END IF;

        v_antes := ventas.fn_grupos_clientes_json(v_c.id);
        PERFORM set_config('app.datos_anteriores', v_antes::text, true);
        PERFORM set_config('app.datos_nuevos', (v_antes || jsonb_build_object('deleted_at', NULL, 'deleted_by', NULL))::text, true);

        UPDATE ventas.grupos_clientes
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
            RAISE EXCEPTION 'No se puede restaurar: su grupo padre también está en la papelera. Restaure primero el de arriba.'
                USING ERRCODE = 'P0014';
        END IF;
        RAISE EXCEPTION 'Ninguno de esos grupos está en la papelera' USING ERRCODE = 'P0019';
    END IF;

    -- Renumerar a las hermanas de cada rama tocada: la restaurado vuelve con
    -- un `orden` que puede empatar con el de otra
    FOREACH v_padre IN ARRAY v_padres LOOP
        v_i := 0;
        FOR v_fila IN
            SELECT id FROM ventas.grupos_clientes
             WHERE padre_id IS NOT DISTINCT FROM NULLIF(v_padre, -1)
               AND deleted_at IS NULL
             ORDER BY orden, nombre
        LOOP
            v_i := v_i + 1;
            UPDATE ventas.grupos_clientes SET orden = v_i WHERE id = v_fila.id AND orden IS DISTINCT FROM v_i;
        END LOOP;
    END LOOP;

    RETURN jsonb_build_object(
        'success', true,
        'message', CASE WHEN v_n = 1 THEN format('Grupo «%s» restaurado', v_nombres[1])
                        ELSE format('%s grupos restaurados', v_n) END
                 || CASE WHEN v_colgadas > 0
                         THEN format('. %s se quedaron: su grupo padre sigue en la papelera', v_colgadas)
                         ELSE '' END,
        'data', jsonb_build_object('restaurados', v_n, 'sin_padre', v_colgadas, 'nombres', to_jsonb(v_nombres))
    );
END;
$function$;

CREATE OR REPLACE FUNCTION ventas.fn_grupos_clientes_papelera_vaciar(p_usuario_id bigint DEFAULT NULL::bigint, p_usuario_login character varying DEFAULT NULL::character varying, p_usuario_nombre character varying DEFAULT NULL::character varying, p_ip_address inet DEFAULT NULL::inet, p_user_agent text DEFAULT NULL::text, p_request_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'ventas', 'auditoria'
AS $function$
DECLARE
    v_ids jsonb;
BEGIN
    SELECT COALESCE(jsonb_agg(c.id), '[]'::jsonb) INTO v_ids
      FROM ventas.grupos_clientes c WHERE c.deleted_at IS NOT NULL;

    IF jsonb_array_length(v_ids) = 0 THEN
        RETURN jsonb_build_object('success', true, 'message', 'La papelera ya estaba vacía',
                                  'data', jsonb_build_object('borradas', 0, 'nombres', '[]'::jsonb));
    END IF;

    -- Se delega en eliminar_definitivo, que ya va de lo más hondo a lo más
    -- alto: dos sitios donde se borra de verdad acabarían divergiendo.
    RETURN ventas.fn_grupos_clientes_eliminar_definitivo(v_ids,
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);
END;
$function$;

-- ---------------------------------------------------------------------------
-- UN ÁRBOL DE GRUPOS PARA EMPEZAR
-- ---------------------------------------------------------------------------
-- Está pensado para que se vea la herencia funcionando: los de arriba ponen
-- las condiciones y los de abajo sólo guardan lo que tienen DISTINTO. Fíjate
-- en «Distribuidores», que no guarda nada —lo hereda todo de Mayoristas— y en
-- «Tienda en línea», que sólo cambia la forma de pago.
--
-- Los nulos son a propósito: un nulo es «lo que diga el de arriba», y un cero
-- es un cero de verdad.
--
-- No se asigna ningún cliente: la columna es nueva y se deja en nulo, así que
-- los 1.000 clientes de hoy siguen comportándose exactamente igual. Se
-- asignan desde la ficha del cliente.
DO $$
DECLARE
    v_fila   record;
    v_padre  bigint;
    v_id     bigint;
    v_n      integer := 0;
BEGIN
    IF EXISTS (SELECT 1 FROM ventas.grupos_clientes) THEN
        RAISE NOTICE 'Ya hay grupos de clientes: no se toca';
        RETURN;
    END IF;

    PERFORM set_config('app.usuario_login',  'datos-grupos', true);
    PERFORM set_config('app.usuario_nombre', 'Grupos de clientes base', true);

    FOR v_fila IN
        SELECT * FROM (VALUES
            -- padre          nombre                icono                     f.pago          cupo      días  desc.  descripción
            (NULL,            'Mayoristas',         'fa-warehouse',           'CREDITO',       5000.00,    30,  8.00, 'Compran volumen y trabajan a crédito'),
            ('Mayoristas',    'Cadenas',            'fa-store',                NULL,          20000.00,    45, 12.00, 'Cadenas con varios locales: más plazo y mejor descuento'),
            ('Mayoristas',    'Distribuidores',     'fa-truck',                NULL,              NULL,  NULL,  NULL, 'Lo heredan todo de Mayoristas'),
            ('Mayoristas',    'Institucionales',    'fa-building-columns',     NULL,          15000.00,    60,  NULL, 'Compras públicas y empresas grandes: pagan tarde'),

            (NULL,            'Minoristas',         'fa-basket-shopping',     'EFECTIVO',         0.00,     0,  0.00, 'Consumidor final; se cobra al entregar'),
            ('Minoristas',    'Mostrador',          'fa-cash-register',        NULL,              NULL,  NULL,  NULL, 'El que entra por la puerta'),
            ('Minoristas',    'Tienda en línea',    'fa-globe',               'TARJETA',          NULL,  NULL,  5.00, 'Sólo cambia la forma de pago y lleva su descuento'),

            (NULL,            'Corporativos',       'fa-briefcase',           'TRANSFERENCIA', 30000.00,    45, 10.00, 'Empresas con convenio'),
            (NULL,            'Empleados',          'fa-id-badge',            'CREDITO',        1000.00,    30, 20.00, 'Venta a empleados con descuento'),
            (NULL,            'Relacionados',       'fa-handshake',           'CREDITO',      100000.00,    90, 15.00, 'Empresas del grupo')
        ) AS g(padre, nombre, icono, forma_pago, limite_credito, dias_credito, descuento, descripcion)
    LOOP
        v_padre := NULL;
        IF v_fila.padre IS NOT NULL THEN
            SELECT id INTO v_padre FROM ventas.grupos_clientes
             WHERE UPPER(TRIM(nombre)) = UPPER(v_fila.padre) AND deleted_at IS NULL;
        END IF;

        v_id := ((ventas.fn_grupos_clientes_crear(
            v_fila.nombre, v_padre, v_fila.descripcion, v_fila.icono, true,
            v_fila.forma_pago, v_fila.limite_credito, v_fila.dias_credito, v_fila.descuento,
            NULL, 'datos-grupos'))->'data'->>'id')::bigint;
        v_n := v_n + 1;
    END LOOP;

    RAISE NOTICE 'Grupos de clientes: % creados', v_n;
END
$$;

COMMIT;
