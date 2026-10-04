-- ===========================================================================
-- CATÁLOGO DE TIPOS Y ASUNTOS DE GESTIÓN
-- ===========================================================================
-- Fecha: 2026-10-03
--
-- El asunto de una gestión se escribía a mano. Con eso no se puede tabular
-- nada: en los 1396 registros que hay conviven «llamda de seguimento» y
-- «Llamada de seguimiento», y cualquier informe por asunto sale partido en
-- dos. Pasa a elegirse de una lista, y la lista depende del tipo.
--
--   ventas.gestiones_tipos     LLAMADA, WHATSAPP, CORREO, VISITA, REUNION, OTRO
--   ventas.gestiones_asuntos   los asuntos de cada tipo
--   ventas.gestiones.asunto_id a cuál de ellos apunta la gestión
--
-- Por qué el asunto sigue guardándose también como texto en gestiones.asunto:
-- es lo que se vio y se escribió el día que se registró. Si mañana alguien
-- corrige el nombre de un asunto en el catálogo, el historial viejo no debe
-- cambiar de significado; para agrupar está asunto_id, para leer está el texto.
--
-- Por qué el tipo sigue siendo un código (varchar) y no un tipo_id: lo usan
-- la agenda, las estadísticas y los filtros de la pantalla, y hay 1396 filas
-- apuntando a él. El catálogo pasa a mandar sobre qué códigos valen —el CHECK
-- fijo se va—, pero la columna no se toca.
--
-- EL SEMBRADO SE HACE CON LO QUE YA SE USA. Los 123 pares (tipo, asunto) que
-- hay en gestiones entran al catálogo y cada gestión queda enganchada al suyo,
-- así el historial completo es tabulable desde el primer día. Entran también
-- las pruebas y los asuntos mal escritos: eso se limpia desde el CRUD
-- desactivándolos, que es un clic, y desactivar no rompe el historial.
--
-- Idempotente: CREATE TABLE IF NOT EXISTS, sembrado con ON CONFLICT y
-- DROP/CREATE de las funciones.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- 1. LAS TABLAS
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS ventas.gestiones_tipos (
    id         bigserial    NOT NULL,
    /** El que ya está guardado en ventas.gestiones.tipo; no se renombra a la ligera */
    codigo     varchar(20)  NOT NULL,
    nombre     varchar(60)  NOT NULL,
    /** Clase de Font Awesome, la misma que usa la pantalla: fa-phone, fab fa-whatsapp… */
    icono      varchar(40),
    orden      integer      NOT NULL DEFAULT 100,
    activo     boolean      NOT NULL DEFAULT true,

    created_at timestamptz           DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamptz           DEFAULT CURRENT_TIMESTAMP,
    created_by varchar(100),
    updated_by varchar(100),

    CONSTRAINT pk_gestiones_tipos     PRIMARY KEY (id),
    CONSTRAINT uq_gestiones_tipos_cod UNIQUE (codigo),
    CONSTRAINT ck_gestiones_tipos_cod CHECK (codigo = UPPER(TRIM(codigo)) AND length(TRIM(codigo)) >= 3)
);

COMMENT ON TABLE ventas.gestiones_tipos IS 'Tipos de gestión: de aquí sale el combo y qué códigos acepta ventas.gestiones.tipo';

CREATE TABLE IF NOT EXISTS ventas.gestiones_asuntos (
    id         bigserial    NOT NULL,
    tipo_id    bigint       NOT NULL,
    nombre     varchar(200) NOT NULL,
    orden      integer      NOT NULL DEFAULT 100,
    activo     boolean      NOT NULL DEFAULT true,

    created_at timestamptz           DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamptz           DEFAULT CURRENT_TIMESTAMP,
    created_by varchar(100),
    updated_by varchar(100),

    CONSTRAINT pk_gestiones_asuntos     PRIMARY KEY (id),
    -- Dos asuntos iguales en el mismo tipo son el mismo asunto: es justo lo que
    -- se quiere evitar, porque parte el informe en dos
    CONSTRAINT uq_gestiones_asuntos     UNIQUE (tipo_id, nombre),
    CONSTRAINT ck_gestiones_asuntos_nom CHECK (length(TRIM(nombre)) >= 3),
    CONSTRAINT fk_gestiones_asuntos_tipo FOREIGN KEY (tipo_id)
        REFERENCES ventas.gestiones_tipos (id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_gestiones_asuntos_tipo ON ventas.gestiones_asuntos (tipo_id);

COMMENT ON TABLE ventas.gestiones_asuntos IS 'Asuntos que se ofrecen para cada tipo de gestión; el usuario elige, no escribe';

-- La gestión apunta al asunto del catálogo. Se deja que sea NULL: hay gestiones
-- anteriores al catálogo y seguimientos cuyo asunto lo genera el sistema.
ALTER TABLE ventas.gestiones
    ADD COLUMN IF NOT EXISTS asunto_id bigint;

ALTER TABLE ventas.gestiones
    DROP CONSTRAINT IF EXISTS fk_gestiones_asunto;

ALTER TABLE ventas.gestiones
    ADD CONSTRAINT fk_gestiones_asunto FOREIGN KEY (asunto_id)
        REFERENCES ventas.gestiones_asuntos (id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS idx_gestiones_asunto_id ON ventas.gestiones (asunto_id);

COMMENT ON COLUMN ventas.gestiones.asunto_id IS
    'Asunto del catálogo. Para agrupar en informes se usa esto; la columna asunto guarda el texto tal como se vio el día que se registró.';

-- El tipo ya no lo manda un CHECK fijo sino el catálogo: si no, dar de alta un
-- tipo nuevo desde el CRUD reventaría al guardar la primera gestión.
ALTER TABLE ventas.gestiones
    DROP CONSTRAINT IF EXISTS ck_gestiones_tipo;

-- ---------------------------------------------------------------------------
-- 2. SEMBRADO
-- ---------------------------------------------------------------------------
-- Los tipos: los seis que ya se usan, con el nombre y el icono que ya pinta la
-- pantalla, para que nada cambie de aspecto al pasar al catálogo.
INSERT INTO ventas.gestiones_tipos (codigo, nombre, icono, orden, created_by, updated_by)
VALUES ('LLAMADA',  'Llamada',  'fa-phone',          10, 'migracion', 'migracion'),
       ('WHATSAPP', 'WhatsApp', 'fab fa-whatsapp',   20, 'migracion', 'migracion'),
       ('CORREO',   'Correo',   'fa-envelope',       30, 'migracion', 'migracion'),
       ('VISITA',   'Visita',   'fa-person-walking', 40, 'migracion', 'migracion'),
       ('REUNION',  'Reunión',  'fa-handshake',      50, 'migracion', 'migracion'),
       ('OTRO',     'Otro',     'fa-comment-dots',   60, 'migracion', 'migracion')
ON CONFLICT (codigo) DO NOTHING;

-- Cualquier otro código que estuviera guardado en gestiones y no esté arriba
INSERT INTO ventas.gestiones_tipos (codigo, nombre, icono, orden, created_by, updated_by)
SELECT DISTINCT UPPER(TRIM(g.tipo)), INITCAP(TRIM(g.tipo)), 'fa-comment-dots', 90, 'migracion', 'migracion'
  FROM ventas.gestiones g
 WHERE NULLIF(TRIM(COALESCE(g.tipo, '')), '') IS NOT NULL
ON CONFLICT (codigo) DO NOTHING;

-- Los asuntos: los que ya se han escrito, cada uno bajo su tipo. El orden sale
-- de lo usado que está, para que lo de todos los días quede arriba del combo.
INSERT INTO ventas.gestiones_asuntos (tipo_id, nombre, orden, created_by, updated_by)
SELECT t.id,
       u.asunto,
       ROW_NUMBER() OVER (PARTITION BY t.id ORDER BY u.veces DESC, u.asunto)::integer * 10,
       'migracion', 'migracion'
  FROM (SELECT UPPER(TRIM(g.tipo)) AS codigo, TRIM(g.asunto) AS asunto, COUNT(*) AS veces
          FROM ventas.gestiones g
         WHERE length(TRIM(COALESCE(g.asunto, ''))) >= 3
         GROUP BY 1, 2) u
  JOIN ventas.gestiones_tipos t ON t.codigo = u.codigo
ON CONFLICT (tipo_id, nombre) DO NOTHING;

-- Y cada gestión queda enganchada al suyo
UPDATE ventas.gestiones g
   SET asunto_id = a.id
  FROM ventas.gestiones_asuntos a
  JOIN ventas.gestiones_tipos t ON t.id = a.tipo_id
 WHERE g.asunto_id IS NULL
   AND t.codigo = UPPER(TRIM(g.tipo))
   AND a.nombre = TRIM(g.asunto);

-- ---------------------------------------------------------------------------
-- 3. LO QUE LEE LA PANTALLA
-- ---------------------------------------------------------------------------
-- Para el formulario: los tipos activos con sus asuntos activos, en una sola
-- petición. Se pide al abrir el modal, así que no vale hacer dos viajes.
CREATE OR REPLACE FUNCTION ventas.fn_gestiones_catalogo()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'ventas'
AS $function$
DECLARE
    v_data jsonb;
BEGIN
    SELECT COALESCE(jsonb_agg(x ORDER BY x->>'orden', x->>'nombre'), '[]'::jsonb) INTO v_data
      FROM (
        SELECT jsonb_build_object(
                   'id',      t.id,
                   'codigo',  t.codigo,
                   'nombre',  t.nombre,
                   'icono',   t.icono,
                   'orden',   t.orden,
                   'asuntos', COALESCE((
                       SELECT jsonb_agg(jsonb_build_object('id', a.id, 'nombre', a.nombre, 'orden', a.orden)
                                        ORDER BY a.orden, a.nombre)
                         FROM ventas.gestiones_asuntos a
                        WHERE a.tipo_id = t.id AND a.activo
                   ), '[]'::jsonb)
               ) AS x
          FROM ventas.gestiones_tipos t
         WHERE t.activo
      ) s;

    RETURN jsonb_build_object('success', true, 'message', 'Catálogo obtenido exitosamente', 'data', v_data);
END;
$function$;

-- Para el CRUD: todos los tipos, activos o no, con cuántos asuntos tienen y
-- cuántas gestiones los usan (que es lo que decide si se puede borrar).
CREATE OR REPLACE FUNCTION ventas.fn_gestiones_tipos_listar(p_incluir_inactivos boolean DEFAULT true)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'ventas'
AS $function$
DECLARE
    v_data jsonb;
BEGIN
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'id',        t.id,
               'codigo',    t.codigo,
               'nombre',    t.nombre,
               'icono',     t.icono,
               'orden',     t.orden,
               'activo',    t.activo,
               'asuntos',   (SELECT COUNT(*) FROM ventas.gestiones_asuntos a WHERE a.tipo_id = t.id),
               'en_uso',    (SELECT COUNT(*) FROM ventas.gestiones g WHERE UPPER(TRIM(g.tipo)) = t.codigo),
               'created_by', t.created_by,
               'updated_by', t.updated_by
           ) ORDER BY t.orden, t.nombre), '[]'::jsonb) INTO v_data
      FROM ventas.gestiones_tipos t
     WHERE (p_incluir_inactivos OR t.activo);

    RETURN jsonb_build_object('success', true, 'message', 'Tipos obtenidos exitosamente', 'data', v_data);
END;
$function$;

CREATE OR REPLACE FUNCTION ventas.fn_gestiones_asuntos_listar(
    p_tipo_id           bigint  DEFAULT NULL,
    p_incluir_inactivos boolean DEFAULT true
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'ventas'
AS $function$
DECLARE
    v_data jsonb;
BEGIN
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'id',          a.id,
               'tipo_id',     a.tipo_id,
               'tipo_nombre', t.nombre,
               'nombre',      a.nombre,
               'orden',       a.orden,
               'activo',      a.activo,
               'en_uso',      (SELECT COUNT(*) FROM ventas.gestiones g WHERE g.asunto_id = a.id)
           ) ORDER BY a.orden, a.nombre), '[]'::jsonb) INTO v_data
      FROM ventas.gestiones_asuntos a
      JOIN ventas.gestiones_tipos t ON t.id = a.tipo_id
     WHERE (p_tipo_id IS NULL OR a.tipo_id = p_tipo_id)
       AND (p_incluir_inactivos OR a.activo);

    RETURN jsonb_build_object('success', true, 'message', 'Asuntos obtenidos exitosamente', 'data', v_data);
END;
$function$;

-- ---------------------------------------------------------------------------
-- 4. GUARDAR Y BORRAR TIPOS
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ventas.fn_gestiones_tipos_guardar(
    p_id             bigint  DEFAULT NULL,
    p_codigo         varchar DEFAULT NULL,
    p_nombre         varchar DEFAULT NULL,
    p_icono          varchar DEFAULT NULL,
    p_orden          integer DEFAULT 100,
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
SET search_path TO 'pg_catalog', 'ventas', 'auditoria'
AS $function$
DECLARE
    v_id     bigint;
    v_codigo varchar := UPPER(NULLIF(TRIM(COALESCE(p_codigo, '')), ''));
    v_viejo  varchar;
    v_fecha  timestamptz := CURRENT_TIMESTAMP;
BEGIN
    PERFORM ventas.fn_gestiones_contexto(p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    IF v_codigo IS NULL OR length(v_codigo) < 3 THEN
        RAISE EXCEPTION 'El código del tipo es obligatorio (mínimo 3 caracteres)' USING ERRCODE = 'P0001';
    END IF;
    IF length(TRIM(COALESCE(p_nombre, ''))) < 3 THEN
        RAISE EXCEPTION 'El nombre del tipo es obligatorio (mínimo 3 caracteres)' USING ERRCODE = 'P0001';
    END IF;
    IF EXISTS (SELECT 1 FROM ventas.gestiones_tipos WHERE codigo = v_codigo AND id IS DISTINCT FROM p_id) THEN
        RAISE EXCEPTION 'Ya existe un tipo con el código %', v_codigo USING ERRCODE = 'P0020';
    END IF;

    IF p_id IS NULL THEN
        INSERT INTO ventas.gestiones_tipos (codigo, nombre, icono, orden, activo, created_by, updated_by)
        VALUES (v_codigo, TRIM(p_nombre), NULLIF(TRIM(COALESCE(p_icono, '')), ''),
                COALESCE(p_orden, 100), COALESCE(p_activo, true), p_usuario_login, p_usuario_login)
        RETURNING id INTO v_id;
    ELSE
        SELECT codigo INTO v_viejo FROM ventas.gestiones_tipos WHERE id = p_id;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'El tipo no existe' USING ERRCODE = 'P0013';
        END IF;

        UPDATE ventas.gestiones_tipos
           SET codigo = v_codigo, nombre = TRIM(p_nombre),
               icono = NULLIF(TRIM(COALESCE(p_icono, '')), ''),
               orden = COALESCE(p_orden, orden), activo = COALESCE(p_activo, activo),
               updated_by = p_usuario_login, updated_at = v_fecha
         WHERE id = p_id;

        -- Las gestiones guardan el código, no el id: si se renombra hay que
        -- arrastrarlas, o el historial se queda apuntando a un tipo que ya no
        -- existe y desaparece de la pantalla sin que nadie lo haya borrado.
        IF v_viejo IS DISTINCT FROM v_codigo THEN
            UPDATE ventas.gestiones SET tipo = v_codigo WHERE UPPER(TRIM(tipo)) = v_viejo;
        END IF;

        v_id := p_id;
    END IF;

    RETURN jsonb_build_object(
        'success', true,
        'message', CASE WHEN p_id IS NULL THEN 'Tipo creado exitosamente' ELSE 'Tipo actualizado exitosamente' END,
        'data', (SELECT jsonb_build_object('id', id, 'codigo', codigo, 'nombre', nombre, 'icono', icono,
                                           'orden', orden, 'activo', activo)
                   FROM ventas.gestiones_tipos WHERE id = v_id)
    );
END;
$function$;

-- Borrar sólo si no lo usa ninguna gestión. Si lo usa, se desactiva: el
-- historial tiene que poder seguir diciendo de qué tipo fue cada cosa.
CREATE OR REPLACE FUNCTION ventas.fn_gestiones_tipos_eliminar(
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
SET search_path TO 'pg_catalog', 'ventas', 'auditoria'
AS $function$
DECLARE
    v_codigo varchar;
    v_uso    bigint;
BEGIN
    PERFORM ventas.fn_gestiones_contexto(p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    SELECT codigo INTO v_codigo FROM ventas.gestiones_tipos WHERE id = p_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'El tipo no existe' USING ERRCODE = 'P0013';
    END IF;

    SELECT COUNT(*) INTO v_uso FROM ventas.gestiones WHERE UPPER(TRIM(tipo)) = v_codigo;

    IF v_uso > 0 THEN
        UPDATE ventas.gestiones_tipos
           SET activo = false, updated_by = p_usuario_login, updated_at = CURRENT_TIMESTAMP
         WHERE id = p_id;
        RETURN jsonb_build_object('success', true,
            'message', format('El tipo se usa en %s gestión(es), así que se desactivó en vez de borrarlo: deja de ofrecerse y el historial se conserva.', v_uso),
            'data', jsonb_build_object('id', p_id, 'desactivado', true));
    END IF;

    DELETE FROM ventas.gestiones_tipos WHERE id = p_id;
    RETURN jsonb_build_object('success', true, 'message', 'Tipo eliminado exitosamente',
                              'data', jsonb_build_object('id', p_id, 'desactivado', false));
END;
$function$;

-- ---------------------------------------------------------------------------
-- 5. GUARDAR Y BORRAR ASUNTOS
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ventas.fn_gestiones_asuntos_guardar(
    p_id             bigint  DEFAULT NULL,
    p_tipo_id        bigint  DEFAULT NULL,
    p_nombre         varchar DEFAULT NULL,
    p_orden          integer DEFAULT 100,
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
SET search_path TO 'pg_catalog', 'ventas', 'auditoria'
AS $function$
DECLARE
    v_id     bigint;
    v_nombre varchar := NULLIF(TRIM(COALESCE(p_nombre, '')), '');
    v_fecha  timestamptz := CURRENT_TIMESTAMP;
BEGIN
    PERFORM ventas.fn_gestiones_contexto(p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    IF v_nombre IS NULL OR length(v_nombre) < 3 THEN
        RAISE EXCEPTION 'El asunto es obligatorio (mínimo 3 caracteres)' USING ERRCODE = 'P0001';
    END IF;
    IF p_tipo_id IS NULL OR NOT EXISTS (SELECT 1 FROM ventas.gestiones_tipos WHERE id = p_tipo_id) THEN
        RAISE EXCEPTION 'El tipo indicado no existe' USING ERRCODE = 'P0013';
    END IF;
    IF EXISTS (SELECT 1 FROM ventas.gestiones_asuntos
                WHERE tipo_id = p_tipo_id AND nombre = v_nombre AND id IS DISTINCT FROM p_id) THEN
        RAISE EXCEPTION 'Ese tipo ya tiene un asunto con ese nombre' USING ERRCODE = 'P0020';
    END IF;

    IF p_id IS NULL THEN
        INSERT INTO ventas.gestiones_asuntos (tipo_id, nombre, orden, activo, created_by, updated_by)
        VALUES (p_tipo_id, v_nombre, COALESCE(p_orden, 100), COALESCE(p_activo, true), p_usuario_login, p_usuario_login)
        RETURNING id INTO v_id;
    ELSE
        UPDATE ventas.gestiones_asuntos
           SET tipo_id = p_tipo_id, nombre = v_nombre,
               orden = COALESCE(p_orden, orden), activo = COALESCE(p_activo, activo),
               updated_by = p_usuario_login, updated_at = v_fecha
         WHERE id = p_id;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'El asunto no existe' USING ERRCODE = 'P0013';
        END IF;

        -- El texto de las gestiones NO se toca: cada una guarda el asunto tal
        -- como se vio el día que se registró. Corregir el catálogo cambia lo
        -- que se ofrece de aquí en adelante, no lo que ya pasó.
        v_id := p_id;
    END IF;

    RETURN jsonb_build_object(
        'success', true,
        'message', CASE WHEN p_id IS NULL THEN 'Asunto creado exitosamente' ELSE 'Asunto actualizado exitosamente' END,
        'data', (SELECT jsonb_build_object('id', id, 'tipo_id', tipo_id, 'nombre', nombre, 'orden', orden, 'activo', activo)
                   FROM ventas.gestiones_asuntos WHERE id = v_id)
    );
END;
$function$;

CREATE OR REPLACE FUNCTION ventas.fn_gestiones_asuntos_eliminar(
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
SET search_path TO 'pg_catalog', 'ventas', 'auditoria'
AS $function$
DECLARE
    v_uso bigint;
BEGIN
    PERFORM ventas.fn_gestiones_contexto(p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    IF NOT EXISTS (SELECT 1 FROM ventas.gestiones_asuntos WHERE id = p_id) THEN
        RAISE EXCEPTION 'El asunto no existe' USING ERRCODE = 'P0013';
    END IF;

    SELECT COUNT(*) INTO v_uso FROM ventas.gestiones WHERE asunto_id = p_id;

    IF v_uso > 0 THEN
        UPDATE ventas.gestiones_asuntos
           SET activo = false, updated_by = p_usuario_login, updated_at = CURRENT_TIMESTAMP
         WHERE id = p_id;
        RETURN jsonb_build_object('success', true,
            'message', format('El asunto se usa en %s gestión(es), así que se desactivó en vez de borrarlo: deja de ofrecerse y los informes siguen cuadrando.', v_uso),
            'data', jsonb_build_object('id', p_id, 'desactivado', true));
    END IF;

    DELETE FROM ventas.gestiones_asuntos WHERE id = p_id;
    RETURN jsonb_build_object('success', true, 'message', 'Asunto eliminado exitosamente',
                              'data', jsonb_build_object('id', p_id, 'desactivado', false));
END;
$function$;
