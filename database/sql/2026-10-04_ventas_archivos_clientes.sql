-- ===========================================================================
-- ARCHIVOS DEL CLIENTE (ventas.archivos_clientes)
-- ===========================================================================
-- Fecha: 2026-10-03
--
-- Lo que se le guarda a un cliente que no cabe en una ficha: fotos del local,
-- el RUC escaneado, el contrato firmado, un video de la visita, la cotización
-- en PDF. Hoy eso vive en el correo de cada vendedor y se pierde cuando el
-- cliente cambia de manos.
--
-- Los ficheros van a storage/app/public/img/clientes, la misma carpeta donde
-- ya están la foto y el mapa del cliente (ClienteController::CARPETA_FOTOS).
-- En la tabla se guarda sólo el NOMBRE del fichero, no la ruta ni la URL:
-- es lo que ya hace ventas.clientes.foto, y así mover el proyecto de servidor
-- o cambiar el dominio no obliga a reescribir ninguna fila.
--
-- El nombre en disco lleva el id del cliente por delante y un sufijo
-- aleatorio: <cliente>_<slug>-<fecha>-<azar>.<ext>. Con el id delante se sabe
-- de quién es un fichero mirando la carpeta, y con el azar dos archivos que se
-- llamen «cedula.jpg» no se pisan.
--
-- Idempotente: CREATE TABLE IF NOT EXISTS + CREATE OR REPLACE FUNCTION.
-- ===========================================================================

CREATE TABLE IF NOT EXISTS ventas.archivos_clientes (
    id          bigserial    NOT NULL,
    cliente_id  bigint       NOT NULL,

    /** Lo que se lee en la lista; por defecto el nombre original sin extensión */
    nombre      varchar(150) NOT NULL,
    /** Para qué es. Es el motivo de que esto exista: un archivo sin contexto no sirve */
    descripcion text,

    /** Nombre del fichero dentro de img/clientes, no la ruta */
    archivo     varchar(200) NOT NULL,
    /** imagen, pdf, video, excel, word, audio, otro: el mismo vocabulario del administrador de archivos */
    tipo        varchar(20)  NOT NULL DEFAULT 'otro',
    extension   varchar(20),
    mime        varchar(120),
    /** Bytes */
    tamano      bigint,

    orden       integer      NOT NULL DEFAULT 100,
    /** Desactivado deja de verse en la pestaña, pero el fichero sigue ahí */
    activo      boolean      NOT NULL DEFAULT true,

    created_at  timestamptz           DEFAULT CURRENT_TIMESTAMP,
    updated_at  timestamptz           DEFAULT CURRENT_TIMESTAMP,
    created_by  varchar(100),
    updated_by  varchar(100),

    CONSTRAINT pk_archivos_clientes      PRIMARY KEY (id),
    CONSTRAINT ck_archivos_clientes_nom  CHECK (length(TRIM(nombre)) >= 1),
    CONSTRAINT ck_archivos_clientes_arch CHECK (length(TRIM(archivo)) >= 5),
    CONSTRAINT fk_archivos_clientes_cli  FOREIGN KEY (cliente_id)
        REFERENCES ventas.clientes (id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_archivos_clientes_cliente ON ventas.archivos_clientes (cliente_id);
CREATE INDEX IF NOT EXISTS idx_archivos_clientes_tipo    ON ventas.archivos_clientes (tipo);

COMMENT ON TABLE ventas.archivos_clientes IS
    'Fotos, videos y documentos del cliente. El fichero vive en storage/app/public/img/clientes; aquí sólo su nombre.';

-- ---------------------------------------------------------------------------
-- UNO EN JSON
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
-- LISTAR los de un cliente
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ventas.fn_archivos_clientes_listar(
    p_cliente_id        bigint,
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
    SELECT COALESCE(jsonb_agg(ventas.fn_archivos_clientes_json(a.id)
                              ORDER BY a.orden, a.id), '[]'::jsonb) INTO v_data
      FROM ventas.archivos_clientes a
     WHERE a.cliente_id = p_cliente_id
       AND (p_incluir_inactivos OR a.activo);

    RETURN jsonb_build_object('success', true, 'message', 'Archivos obtenidos exitosamente', 'data', v_data);
END;
$function$;

-- ---------------------------------------------------------------------------
-- GUARDAR (crea o modifica)
--
-- Al modificar sólo se tocan el nombre, la descripción, el orden y el activo:
-- el fichero no se cambia por otro. Para eso se sube uno nuevo y se borra el
-- viejo, que deja rastro en la auditoría; cambiarlo por debajo haría que la
-- descripción dejara de corresponder con lo que se ve.
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
    v_orden  integer;
    v_fecha  timestamptz := CURRENT_TIMESTAMP;
BEGIN
    PERFORM ventas.fn_gestiones_contexto(p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    IF v_nombre IS NULL THEN
        RAISE EXCEPTION 'El nombre del archivo es obligatorio' USING ERRCODE = 'P0001';
    END IF;

    IF p_id IS NULL THEN
        IF NOT EXISTS (SELECT 1 FROM ventas.clientes WHERE id = p_cliente_id AND deleted_at IS NULL) THEN
            RAISE EXCEPTION 'El cliente no existe o está en la papelera' USING ERRCODE = 'P0013';
        END IF;
        IF length(TRIM(COALESCE(p_archivo, ''))) < 5 THEN
            RAISE EXCEPTION 'Falta el fichero subido' USING ERRCODE = 'P0001';
        END IF;

        -- Detrás de los que ya tiene, para que el orden de la pestaña sea el de subida
        SELECT COALESCE(MAX(orden), 0) + 10 INTO v_orden
          FROM ventas.archivos_clientes WHERE cliente_id = p_cliente_id;

        INSERT INTO ventas.archivos_clientes (
            cliente_id, nombre, descripcion, archivo, tipo, extension, mime, tamano,
            orden, activo, created_by, updated_by
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

-- ---------------------------------------------------------------------------
-- ELIMINAR
--
-- Devuelve el nombre del fichero para que el controlador lo borre del disco
-- después, no antes: si la fila no se llegó a borrar, el fichero tiene que
-- seguir ahí o la pestaña quedaría mostrando un archivo que ya no existe.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ventas.fn_archivos_clientes_eliminar(
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
    v_archivo varchar;
    v_antes   jsonb;
BEGIN
    PERFORM ventas.fn_gestiones_contexto(p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    SELECT archivo INTO v_archivo FROM ventas.archivos_clientes WHERE id = p_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'El archivo no existe' USING ERRCODE = 'P0013';
    END IF;

    v_antes := ventas.fn_archivos_clientes_json(p_id);
    PERFORM set_config('app.datos_anteriores', v_antes::text, true);

    DELETE FROM ventas.archivos_clientes WHERE id = p_id;

    PERFORM set_config('app.datos_anteriores', '', true);

    RETURN jsonb_build_object('success', true, 'message', 'Archivo eliminado exitosamente',
                              'data', jsonb_build_object('id', p_id, 'archivo', v_archivo));
END;
$function$;
