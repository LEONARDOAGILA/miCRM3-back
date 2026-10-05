-- ===========================================================================
-- UNA NOTA QUE ES SÓLO UNA CAPTURA TAMBIÉN ES UNA NOTA
-- ===========================================================================
-- Fecha: 2026-10-04
-- Se aplica después de 2026-10-04_ventas_notas_clientes.sql.
--
-- La comprobación de «nota vacía» miraba sólo el texto plano, y una nota que es
-- una captura de la transferencia y nada más no tiene ni una letra: se
-- rechazaba con «La nota está vacía» justo después de haber subido la imagen.
--
-- Ahora vale cualquiera de las dos cosas: que haya texto, o que haya una
-- imagen. Lo que sigue sin pasar es el título solo.
-- ===========================================================================

CREATE OR REPLACE FUNCTION ventas.fn_notas_clientes_guardar(
    p_id              bigint  DEFAULT NULL,
    p_cliente_id      bigint  DEFAULT NULL,
    p_titulo          varchar DEFAULT NULL,
    p_contenido       text    DEFAULT NULL,
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

    -- Vacía es no tener NI texto NI imagen. Una captura de la transferencia sin
    -- una sola letra es una nota perfectamente válida.
    IF length(TRIM(COALESCE(p_contenido_texto, ''))) < 1
       AND COALESCE(p_contenido, '') !~* '<img' THEN
        RAISE EXCEPTION 'La nota está vacía: escriba algo o inserte una imagen' USING ERRCODE = 'P0001';
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

-- El resumen de la lista: una nota que es sólo una imagen no tiene texto que
-- resumir, y la tarjeta quedaría con el título y un hueco. Se dice qué hay.
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
        'resumen',         CASE
                               WHEN length(COALESCE(n.contenido_texto, '')) = 0
                                    AND COALESCE(n.contenido, '') ~* '<img' THEN '(imagen)'
                               WHEN length(COALESCE(n.contenido_texto, '')) <= 220 THEN n.contenido_texto
                               ELSE left(n.contenido_texto, 220) || '…'
                           END,
        'color',           n.color,
        'fijada',          n.fijada,
        -- Para que la lista pueda avisar de que la nota lleva una captura
        'tiene_imagen',    (COALESCE(n.contenido, '') ~* '<img'),
        'created_by',      n.created_by,
        'updated_by',      n.updated_by,
        'created_at',      to_char(n.created_at, 'YYYY-MM-DD HH24:MI'),
        'updated_at',      to_char(n.updated_at, 'YYYY-MM-DD HH24:MI'),
        'editada',         (n.updated_at > n.created_at + interval '1 minute')
    ) INTO v_data
    FROM ventas.notas_clientes n
    WHERE n.id = p_id;

    RETURN v_data;
END;
$function$;
