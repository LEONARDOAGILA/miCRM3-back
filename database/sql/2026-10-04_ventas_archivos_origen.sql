-- ===========================================================================
-- DE DÓNDE SALIÓ EL ARCHIVO (ventas.archivos_clientes.origen)
-- ===========================================================================
-- Fecha: 2026-10-04
-- Se aplica después de 2026-10-04_ventas_archivos_clientes.sql.
--
-- Las notas pasan a admitir imágenes. La imagen NO se guarda dentro del HTML
-- en base64: una captura de 2 MB haría esa fila más grande que todas las demás
-- notas juntas, y cada vez que se listan las notas viajaría entera. Se sube al
-- servidor como cualquier otro archivo del cliente y la nota guarda el enlace.
--
-- Pero entonces esas imágenes aparecerían en la pestaña de Archivos mezcladas
-- con los contratos y las fotos del local, y ahí no pintan nada: son parte del
-- texto de una nota, no documentos del cliente. De ahí esta columna:
--
--   'archivo'  lo subió alguien en la pestaña de Archivos
--   'nota'     va incrustado en el texto de una nota
--
-- Guardarlas igual en la tabla —en vez de soltarlas en la carpeta sin más— es
-- lo que evita los huérfanos: hay una fila que se puede listar, contar y
-- borrar, y el borrado ya se lleva el fichero del disco.
--
-- Idempotente: ADD COLUMN IF NOT EXISTS + CREATE OR REPLACE.
-- ===========================================================================

ALTER TABLE ventas.archivos_clientes
    ADD COLUMN IF NOT EXISTS origen varchar(10) NOT NULL DEFAULT 'archivo';

ALTER TABLE ventas.archivos_clientes
    DROP CONSTRAINT IF EXISTS ck_archivos_clientes_origen;

ALTER TABLE ventas.archivos_clientes
    ADD CONSTRAINT ck_archivos_clientes_origen CHECK (origen IN ('archivo', 'nota'));

COMMENT ON COLUMN ventas.archivos_clientes.origen IS
    'archivo = subido en la pestaña de Archivos; nota = incrustado en el texto de una nota. La pestaña de Archivos enseña los primeros salvo que se pidan los dos.';

CREATE INDEX IF NOT EXISTS idx_archivos_clientes_origen
    ON ventas.archivos_clientes (cliente_id, origen);

-- ---------------------------------------------------------------------------
-- QUE SALGA EN EL JSON
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ventas.fn_archivos_clientes_json(p_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'ventas'
AS $function$
DECLARE
    v_data jsonb;
BEGIN
    SELECT jsonb_build_object(
        'id',          a.id,
        'cliente_id',  a.cliente_id,
        'nombre',      a.nombre,
        'descripcion', a.descripcion,
        'archivo',     a.archivo,
        'tipo',        a.tipo,
        'extension',   a.extension,
        'mime',        a.mime,
        'tamano',      a.tamano,
        'orden',       a.orden,
        'activo',      a.activo,
        -- De dónde salió: la pestaña de Archivos o el texto de una nota
        'origen',      a.origen,
        'created_by',  a.created_by,
        'updated_by',  a.updated_by,
        'created_at',  to_char(a.created_at, 'YYYY-MM-DD HH24:MI'),
        'updated_at',  to_char(a.updated_at, 'YYYY-MM-DD HH24:MI')
    ) INTO v_data
    FROM ventas.archivos_clientes a
    WHERE a.id = p_id;

    RETURN v_data;
END;
$function$;

-- ---------------------------------------------------------------------------
-- LISTAR, pudiendo pedir sólo los de un origen
--
-- Por defecto 'archivo': es lo que enseña la pestaña, y si no filtrara, pegar
-- cinco capturas en una nota llenaría la pestaña de recortes.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ventas.fn_archivos_clientes_listar(
    p_cliente_id        bigint,
    p_incluir_inactivos boolean DEFAULT true,
    /** 'archivo', 'nota' o NULL para todos */
    p_origen            varchar DEFAULT 'archivo'
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'ventas'
AS $function$
DECLARE
    v_data   jsonb;
    v_origen varchar := NULLIF(TRIM(COALESCE(p_origen, '')), '');
BEGIN
    SELECT COALESCE(jsonb_agg(ventas.fn_archivos_clientes_json(a.id)
                              ORDER BY a.orden, a.id), '[]'::jsonb) INTO v_data
      FROM ventas.archivos_clientes a
     WHERE a.cliente_id = p_cliente_id
       AND (p_incluir_inactivos OR a.activo)
       AND (v_origen IS NULL OR a.origen = v_origen);

    RETURN jsonb_build_object('success', true, 'message', 'Archivos obtenidos exitosamente', 'data', v_data);
END;
$function$;

-- ---------------------------------------------------------------------------
-- GUARDAR, con el origen
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ventas.fn_archivos_clientes_guardar(
    p_id             bigint  DEFAULT NULL,
    p_cliente_id     bigint  DEFAULT NULL,
    p_nombre         varchar DEFAULT NULL,
    p_descripcion    text    DEFAULT NULL,
    p_archivo        varchar DEFAULT NULL,
    p_tipo           varchar DEFAULT 'otro',
    p_extension      varchar DEFAULT NULL,
    p_mime           varchar DEFAULT NULL,
    p_tamano         bigint  DEFAULT NULL,
    p_orden          integer DEFAULT NULL,
    p_activo         boolean DEFAULT true,
    p_origen         varchar DEFAULT 'archivo',
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
    v_origen varchar := COALESCE(NULLIF(TRIM(COALESCE(p_origen, '')), ''), 'archivo');
    v_orden  integer;
    v_fecha  timestamptz := CURRENT_TIMESTAMP;
BEGIN
    PERFORM ventas.fn_gestiones_contexto(p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    IF v_nombre IS NULL THEN
        RAISE EXCEPTION 'El nombre del archivo es obligatorio' USING ERRCODE = 'P0001';
    END IF;
    IF v_origen NOT IN ('archivo', 'nota') THEN
        RAISE EXCEPTION 'El origen del archivo no es válido' USING ERRCODE = 'P0022';
    END IF;

    IF p_id IS NULL THEN
        IF NOT EXISTS (SELECT 1 FROM ventas.clientes WHERE id = p_cliente_id AND deleted_at IS NULL) THEN
            RAISE EXCEPTION 'El cliente no existe o está en la papelera' USING ERRCODE = 'P0013';
        END IF;
        IF length(TRIM(COALESCE(p_archivo, ''))) < 5 THEN
            RAISE EXCEPTION 'Falta el fichero subido' USING ERRCODE = 'P0001';
        END IF;

        -- El orden se cuenta dentro de su origen: las imágenes de las notas no
        -- deben empujar la numeración de los documentos del cliente
        SELECT COALESCE(MAX(orden), 0) + 10 INTO v_orden
          FROM ventas.archivos_clientes WHERE cliente_id = p_cliente_id AND origen = v_origen;

        INSERT INTO ventas.archivos_clientes (
            cliente_id, nombre, descripcion, archivo, tipo, extension, mime, tamano,
            orden, activo, origen, created_by, updated_by
        ) VALUES (
            p_cliente_id,
            substr(v_nombre, 1, 150),
            NULLIF(TRIM(COALESCE(p_descripcion, '')), ''),
            TRIM(p_archivo),
            COALESCE(NULLIF(TRIM(COALESCE(p_tipo, '')), ''), 'otro'),
            NULLIF(LOWER(TRIM(COALESCE(p_extension, ''))), ''),
            NULLIF(TRIM(COALESCE(p_mime, '')), ''),
            p_tamano,
            COALESCE(p_orden, v_orden),
            COALESCE(p_activo, true),
            v_origen,
            p_usuario_login, p_usuario_login
        )
        RETURNING id INTO v_id;
    ELSE
        UPDATE ventas.archivos_clientes
           SET nombre      = substr(v_nombre, 1, 150),
               descripcion = NULLIF(TRIM(COALESCE(p_descripcion, '')), ''),
               orden       = COALESCE(p_orden, orden),
               activo      = COALESCE(p_activo, activo),
               updated_by  = p_usuario_login,
               updated_at  = v_fecha
         WHERE id = p_id;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'El archivo no existe' USING ERRCODE = 'P0013';
        END IF;
        v_id := p_id;
    END IF;

    RETURN jsonb_build_object(
        'success', true,
        'message', CASE WHEN p_id IS NULL THEN 'Archivo guardado exitosamente' ELSE 'Archivo actualizado exitosamente' END,
        'data', ventas.fn_archivos_clientes_json(v_id)
    );
END;
$function$;
