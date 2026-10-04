-- ===========================================================================
-- NOTAS DEL CLIENTE (ventas.notas_clientes)
-- ===========================================================================
-- Fecha: 2026-10-04
--
-- Lo que hay que saber de un cliente y no es una gestión ni un archivo: cómo
-- le gusta que le llamen, que el gerente de compras sólo atiende los martes,
-- el acuerdo verbal del precio, por qué se le quitó el crédito. Hoy eso vive
-- en la cabeza del vendedor y se pierde entero cuando el cliente cambia de
-- manos.
--
-- Son distintas de la `nota` de una gestión: aquélla cuenta QUÉ PASÓ en una
-- llamada concreta y se queda clavada en su fecha; éstas describen AL CLIENTE
-- y se mantienen al día.
--
-- El contenido se guarda como HTML, que es lo que produce el editor, y además
-- en texto plano aparte:
--
--   · buscar sobre el HTML encuentra basura —escribir «strong» sacaría todo
--     lo que lleve negrita— y no encuentra una frase partida por una etiqueta,
--   · y el texto plano es lo que se enseña como resumen en la lista, donde
--     pintar HTML de verdad descuadraría las tarjetas.
--
-- Lo calcula el back al guardar (strip_tags), no el navegador: es dato
-- derivado y quien manda sobre él tiene que ser uno solo.
--
-- Idempotente: CREATE TABLE IF NOT EXISTS + CREATE OR REPLACE FUNCTION.
-- ===========================================================================

CREATE TABLE IF NOT EXISTS ventas.notas_clientes (
    id              bigserial    NOT NULL,
    cliente_id      bigint       NOT NULL,

    titulo          varchar(150) NOT NULL,
    /** Lo que escribió el editor */
    contenido       text,
    /** Lo mismo sin etiquetas: para buscar y para el resumen de la lista */
    contenido_texto text,

    /** Etiqueta de color, para distinguirlas de un vistazo */
    color           varchar(20)  NOT NULL DEFAULT 'gris',
    /** Las que siempre hay que tener delante van arriba del todo */
    fijada          boolean      NOT NULL DEFAULT false,

    created_at      timestamptz           DEFAULT CURRENT_TIMESTAMP,
    updated_at      timestamptz           DEFAULT CURRENT_TIMESTAMP,
    created_by      varchar(100),
    updated_by      varchar(100),

    CONSTRAINT pk_notas_clientes      PRIMARY KEY (id),
    CONSTRAINT ck_notas_clientes_tit  CHECK (length(TRIM(titulo)) >= 3),
    CONSTRAINT ck_notas_clientes_col  CHECK (color IN ('gris', 'azul', 'verde', 'amarillo', 'rojo', 'morado')),
    CONSTRAINT fk_notas_clientes_cli  FOREIGN KEY (cliente_id)
        REFERENCES ventas.clientes (id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_notas_clientes_cliente ON ventas.notas_clientes (cliente_id);
-- Las fijadas primero y dentro de cada grupo las últimas: es el orden de la
-- lista, así que se indexa igual para no ordenar en memoria
CREATE INDEX IF NOT EXISTS idx_notas_clientes_orden
    ON ventas.notas_clientes (cliente_id, fijada DESC, updated_at DESC);

COMMENT ON TABLE ventas.notas_clientes IS
    'Notas sobre el cliente (no sobre una gestión concreta). contenido es HTML del editor; contenido_texto es lo mismo sin etiquetas, para buscar y resumir.';

-- ---------------------------------------------------------------------------
-- UNA EN JSON
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ventas.fn_notas_clientes_json(p_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'ventas'
AS $function$
DECLARE
    v_data jsonb;
BEGIN
    SELECT jsonb_build_object(
        'id',              n.id,
        'cliente_id',      n.cliente_id,
        'titulo',          n.titulo,
        'contenido',       n.contenido,
        'contenido_texto', n.contenido_texto,
        -- Para la tarjeta de la lista: las primeras líneas, sin cortar a mitad
        -- de palabra y con el aviso de que hay más
        'resumen',         CASE
                               WHEN length(COALESCE(n.contenido_texto, '')) <= 220 THEN n.contenido_texto
                               ELSE left(n.contenido_texto, 220) || '…'
                           END,
        'color',           n.color,
        'fijada',          n.fijada,
        'created_by',      n.created_by,
        'updated_by',      n.updated_by,
        'created_at',      to_char(n.created_at, 'YYYY-MM-DD HH24:MI'),
        'updated_at',      to_char(n.updated_at, 'YYYY-MM-DD HH24:MI'),
        -- La pantalla enseña «editada por…» sólo si de verdad la tocaron después
        'editada',         (n.updated_at > n.created_at + interval '1 minute')
    ) INTO v_data
    FROM ventas.notas_clientes n
    WHERE n.id = p_id;

    RETURN v_data;
END;
$function$;

-- ---------------------------------------------------------------------------
-- LISTAR las de un cliente
--
-- `p_busca` mira en el título y en el texto plano. Si se buscara sobre el HTML,
-- escribir «strong» sacaría todas las notas que lleven algo en negrita.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ventas.fn_notas_clientes_listar(
    p_cliente_id bigint,
    p_busca      varchar DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'ventas'
AS $function$
DECLARE
    v_data   jsonb;
    v_patron text := CASE WHEN NULLIF(TRIM(COALESCE(p_busca, '')), '') IS NULL
                          THEN NULL ELSE '%' || lower(TRIM(p_busca)) || '%' END;
BEGIN
    SELECT COALESCE(jsonb_agg(ventas.fn_notas_clientes_json(n.id)
                              ORDER BY n.fijada DESC, n.updated_at DESC), '[]'::jsonb) INTO v_data
      FROM ventas.notas_clientes n
     WHERE n.cliente_id = p_cliente_id
       AND (v_patron IS NULL
            OR lower(n.titulo) LIKE v_patron
            OR lower(COALESCE(n.contenido_texto, '')) LIKE v_patron);

    RETURN jsonb_build_object('success', true, 'message', 'Notas obtenidas exitosamente', 'data', v_data);
END;
$function$;

-- ---------------------------------------------------------------------------
-- GUARDAR (crea o modifica)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ventas.fn_notas_clientes_guardar(
    p_id              bigint  DEFAULT NULL,
    p_cliente_id      bigint  DEFAULT NULL,
    p_titulo          varchar DEFAULT NULL,
    p_contenido       text    DEFAULT NULL,
    /** El mismo contenido sin etiquetas; lo calcula el controlador */
    p_contenido_texto text    DEFAULT NULL,
    p_color           varchar DEFAULT 'gris',
    p_fijada          boolean DEFAULT false,
    p_usuario_id      bigint  DEFAULT NULL,
    p_usuario_login   varchar DEFAULT NULL,
    p_usuario_nombre  varchar DEFAULT NULL,
    p_ip_address      inet    DEFAULT NULL,
    p_user_agent      text    DEFAULT NULL,
    p_request_id      uuid    DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'ventas', 'auditoria'
AS $function$
DECLARE
    v_id     bigint;
    v_titulo varchar := NULLIF(TRIM(COALESCE(p_titulo, '')), '');
    v_antes  jsonb;
    v_fecha  timestamptz := CURRENT_TIMESTAMP;
BEGIN
    PERFORM ventas.fn_gestiones_contexto(p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    IF v_titulo IS NULL OR length(v_titulo) < 3 THEN
        RAISE EXCEPTION 'El título de la nota es obligatorio (mínimo 3 caracteres)' USING ERRCODE = 'P0001';
    END IF;
    -- Una nota sin cuerpo no dice nada; el título solo no es una nota
    IF length(TRIM(COALESCE(p_contenido_texto, ''))) < 1 THEN
        RAISE EXCEPTION 'La nota está vacía: escriba algo en el contenido' USING ERRCODE = 'P0001';
    END IF;

    IF p_id IS NULL THEN
        IF NOT EXISTS (SELECT 1 FROM ventas.clientes WHERE id = p_cliente_id AND deleted_at IS NULL) THEN
            RAISE EXCEPTION 'El cliente no existe o está en la papelera' USING ERRCODE = 'P0013';
        END IF;

        INSERT INTO ventas.notas_clientes (
            cliente_id, titulo, contenido, contenido_texto, color, fijada, created_by, updated_by
        ) VALUES (
            p_cliente_id,
            substr(v_titulo, 1, 150),
            p_contenido,
            p_contenido_texto,
            COALESCE(NULLIF(TRIM(COALESCE(p_color, '')), ''), 'gris'),
            COALESCE(p_fijada, false),
            p_usuario_login, p_usuario_login
        )
        RETURNING id INTO v_id;
    ELSE
        v_antes := ventas.fn_notas_clientes_json(p_id);
        IF v_antes IS NULL THEN
            RAISE EXCEPTION 'La nota no existe' USING ERRCODE = 'P0013';
        END IF;
        PERFORM set_config('app.datos_anteriores', v_antes::text, true);

        UPDATE ventas.notas_clientes
           SET titulo          = substr(v_titulo, 1, 150),
               contenido       = p_contenido,
               contenido_texto = p_contenido_texto,
               color           = COALESCE(NULLIF(TRIM(COALESCE(p_color, '')), ''), color),
               fijada          = COALESCE(p_fijada, fijada),
               updated_by      = p_usuario_login,
               updated_at      = v_fecha
         WHERE id = p_id;

        PERFORM set_config('app.datos_anteriores', '', true);
        v_id := p_id;
    END IF;

    RETURN jsonb_build_object(
        'success', true,
        'message', CASE WHEN p_id IS NULL THEN 'Nota creada exitosamente' ELSE 'Nota actualizada exitosamente' END,
        'data', ventas.fn_notas_clientes_json(v_id)
    );
END;
$function$;

-- ---------------------------------------------------------------------------
-- FIJAR / DESFIJAR
--
-- Aparte de guardar porque es un clic en la propia tarjeta y no debe tocar el
-- contenido ni mover la nota de sitio por culpa de updated_at: fijar no es
-- editar, y si contara como edición, poner una nota arriba la haría parecer la
-- más reciente.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ventas.fn_notas_clientes_fijar(
    p_id             bigint,
    p_fijada         boolean DEFAULT NULL,
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
    v_nueva boolean;
BEGIN
    PERFORM ventas.fn_gestiones_contexto(p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    SELECT COALESCE(p_fijada, NOT fijada) INTO v_nueva FROM ventas.notas_clientes WHERE id = p_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'La nota no existe' USING ERRCODE = 'P0013';
    END IF;

    UPDATE ventas.notas_clientes
       SET fijada = v_nueva, updated_by = p_usuario_login
     WHERE id = p_id;

    RETURN jsonb_build_object(
        'success', true,
        'message', CASE WHEN v_nueva THEN 'Nota fijada arriba' ELSE 'Nota desfijada' END,
        'data', ventas.fn_notas_clientes_json(p_id)
    );
END;
$function$;

-- ---------------------------------------------------------------------------
-- ELIMINAR
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ventas.fn_notas_clientes_eliminar(
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
    v_antes jsonb;
BEGIN
    PERFORM ventas.fn_gestiones_contexto(p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    v_antes := ventas.fn_notas_clientes_json(p_id);
    IF v_antes IS NULL THEN
        RAISE EXCEPTION 'La nota no existe' USING ERRCODE = 'P0013';
    END IF;

    -- El contenido entero queda en la auditoría: una nota borrada por error es
    -- lo único que no se puede volver a escribir de memoria
    PERFORM set_config('app.datos_anteriores', v_antes::text, true);
    DELETE FROM ventas.notas_clientes WHERE id = p_id;
    PERFORM set_config('app.datos_anteriores', '', true);

    RETURN jsonb_build_object('success', true, 'message', 'Nota eliminada exitosamente',
                              'data', jsonb_build_object('id', p_id));
END;
$function$;
