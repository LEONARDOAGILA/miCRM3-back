-- ===========================================================================
-- ARCHIVOS ADJUNTOS A UNA GESTIÓN (ventas.archivos_clientes.gestion_id)
-- ===========================================================================
-- Fecha: 2026-10-06
-- Se aplica después de 2026-10-04_ventas_archivos_origen.sql.
--
-- Al registrar una gestión se puede adjuntar lo que se le mandó al cliente: la
-- cotización, la factura, la foto del producto. Hasta ahora eso o no se
-- guardaba, o se subía suelto a la pestaña de Archivos y nadie sabía a qué
-- conversación pertenecía.
--
-- No se crea una tabla nueva. El fichero sigue siendo del cliente —vive en la
-- misma carpeta, se ve con el mismo enlace, se borra con el mismo código— y lo
-- único que cambia es que ahora puede decir a qué gestión pertenece. Una tabla
-- aparte habría obligado a duplicar subida, listado, visor y borrado para
-- guardar exactamente los mismos campos.
--
-- Así queda el origen, que es lo que separa las tres cosas que conviven aquí:
--
--   'archivo'  lo subió alguien en la pestaña de Archivos
--   'nota'     va incrustado en el texto de una nota
--   'gestion'  se adjuntó al registrar una gestión    <-- lo nuevo
--
-- Los de 'gestion' NO salen en la pestaña de Archivos, igual que los de las
-- notas: son parte de una conversación concreta, no documentos del cliente.
-- Se ven desde su gestión.
--
-- ON DELETE CASCADE sobre la gestión: si se borra la gestión se van sus
-- adjuntos. Ojo con lo que el cascade NO hace: borra la fila y deja el fichero
-- en el disco. Por eso GestionController::deleteGestion se apunta los nombres
-- antes de borrar y quita los ficheros después; el cascade es el cinturón,
-- para que no quede una fila apuntando a una gestión que ya no existe.
--
-- SOBRECARGAS: fn_archivos_clientes_listar y _guardar se quedaron con dos
-- versiones cada una al añadirles p_origen (CREATE OR REPLACE con otra firma
-- no reemplaza: añade). Aquí se tiran todas y se dejan las de ahora, que es lo
-- que evita que una llamada caiga en la vieja sin que nadie se entere.
--
-- Idempotente.
-- ===========================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. LA COLUMNA
-- ---------------------------------------------------------------------------
ALTER TABLE ventas.archivos_clientes
    ADD COLUMN IF NOT EXISTS gestion_id bigint NULL;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
         WHERE conname = 'fk_archivos_clientes_gestion'
           AND conrelid = 'ventas.archivos_clientes'::regclass
    ) THEN
        ALTER TABLE ventas.archivos_clientes
            ADD CONSTRAINT fk_archivos_clientes_gestion
            FOREIGN KEY (gestion_id) REFERENCES ventas.gestiones(id) ON DELETE CASCADE;
    END IF;
END $$;

ALTER TABLE ventas.archivos_clientes
    DROP CONSTRAINT IF EXISTS ck_archivos_clientes_origen;

ALTER TABLE ventas.archivos_clientes
    ADD CONSTRAINT ck_archivos_clientes_origen CHECK (origen IN ('archivo', 'nota', 'gestion'));

-- Un adjunto de gestión sin gestión no es un adjunto de gestión: se quedaría
-- invisible para siempre, fuera de la pestaña y fuera de su gestión.
ALTER TABLE ventas.archivos_clientes
    DROP CONSTRAINT IF EXISTS ck_archivos_clientes_gestion;

ALTER TABLE ventas.archivos_clientes
    ADD CONSTRAINT ck_archivos_clientes_gestion
    CHECK ((origen = 'gestion') = (gestion_id IS NOT NULL));

COMMENT ON COLUMN ventas.archivos_clientes.gestion_id IS
    'La gestión a la que se adjuntó. Obligatorio con origen = gestion y vacío en los demás.';

CREATE INDEX IF NOT EXISTS idx_archivos_clientes_gestion
    ON ventas.archivos_clientes (gestion_id) WHERE gestion_id IS NOT NULL;

-- ---------------------------------------------------------------------------
-- 2. FUERA LAS SOBRECARGAS VIEJAS
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    v_f record;
BEGIN
    FOR v_f IN
        SELECT p.oid::regprocedure AS firma
          FROM pg_proc p
          JOIN pg_namespace n ON n.oid = p.pronamespace
         WHERE n.nspname = 'ventas'
           AND p.proname IN ('fn_archivos_clientes_listar', 'fn_archivos_clientes_guardar')
    LOOP
        EXECUTE 'DROP FUNCTION ' || v_f.firma;
    END LOOP;
END $$;

-- ---------------------------------------------------------------------------
-- 3. QUE LA GESTIÓN SALGA EN EL JSON
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
        'gestion_id',  a.gestion_id,
        'nombre',      a.nombre,
        'descripcion', a.descripcion,
        'archivo',     a.archivo,
        'tipo',        a.tipo,
        'extension',   a.extension,
        'mime',        a.mime,
        'tamano',      a.tamano,
        'orden',       a.orden,
        'activo',      a.activo,
        -- De dónde salió: la pestaña de Archivos, el texto de una nota o el
        -- formulario de una gestión
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
-- 4. LISTAR
--
-- Con p_gestion_id se piden los de esa gestión y el origen deja de mandar: son
-- los adjuntos de una conversación, no hay otra cosa que puedan ser.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ventas.fn_archivos_clientes_listar(
    p_cliente_id        bigint,
    p_incluir_inactivos boolean DEFAULT true,
    /** 'archivo', 'nota', 'gestion' o NULL para todos */
    p_origen            varchar DEFAULT 'archivo',
    /** Los adjuntos de una gestión concreta */
    p_gestion_id        bigint  DEFAULT NULL
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
    IF p_gestion_id IS NOT NULL THEN
        SELECT COALESCE(jsonb_agg(ventas.fn_archivos_clientes_json(a.id)
                                  ORDER BY a.orden, a.id), '[]'::jsonb) INTO v_data
          FROM ventas.archivos_clientes a
         WHERE a.gestion_id = p_gestion_id
           AND (p_incluir_inactivos OR a.activo);
    ELSE
        SELECT COALESCE(jsonb_agg(ventas.fn_archivos_clientes_json(a.id)
                                  ORDER BY a.orden, a.id), '[]'::jsonb) INTO v_data
          FROM ventas.archivos_clientes a
         WHERE a.cliente_id = p_cliente_id
           AND (p_incluir_inactivos OR a.activo)
           AND (v_origen IS NULL OR a.origen = v_origen);
    END IF;

    RETURN jsonb_build_object('success', true, 'message', 'Archivos obtenidos exitosamente', 'data', v_data);
END;
$function$;

-- ---------------------------------------------------------------------------
-- 5. GUARDAR
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
    p_gestion_id     bigint  DEFAULT NULL,
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
    IF v_origen NOT IN ('archivo', 'nota', 'gestion') THEN
        RAISE EXCEPTION 'El origen del archivo no es válido' USING ERRCODE = 'P0022';
    END IF;
    IF v_origen = 'gestion' AND p_gestion_id IS NULL THEN
        RAISE EXCEPTION 'Falta la gestión a la que se adjunta el archivo' USING ERRCODE = 'P0001';
    END IF;

    IF p_id IS NULL THEN
        IF NOT EXISTS (SELECT 1 FROM ventas.clientes WHERE id = p_cliente_id AND deleted_at IS NULL) THEN
            RAISE EXCEPTION 'El cliente no existe o está en la papelera' USING ERRCODE = 'P0013';
        END IF;
        IF length(TRIM(COALESCE(p_archivo, ''))) < 5 THEN
            RAISE EXCEPTION 'Falta el fichero subido' USING ERRCODE = 'P0001';
        END IF;

        -- La gestión tiene que ser de ESE cliente: si no, un adjunto acabaría
        -- colgando de la conversación de otro
        IF p_gestion_id IS NOT NULL
           AND NOT EXISTS (SELECT 1 FROM ventas.gestiones
                            WHERE id = p_gestion_id AND cliente_id = p_cliente_id) THEN
            RAISE EXCEPTION 'La gestión no existe o no es de ese cliente' USING ERRCODE = 'P0013';
        END IF;

        -- El orden se cuenta dentro de su origen: las imágenes de las notas no
        -- deben empujar la numeración de los documentos del cliente
        SELECT COALESCE(MAX(orden), 0) + 10 INTO v_orden
          FROM ventas.archivos_clientes
         WHERE cliente_id = p_cliente_id
           AND origen = v_origen
           AND gestion_id IS NOT DISTINCT FROM p_gestion_id;

        INSERT INTO ventas.archivos_clientes (
            cliente_id, gestion_id, nombre, descripcion, archivo, tipo, extension, mime, tamano,
            orden, activo, origen, created_by, updated_by
        ) VALUES (
            p_cliente_id,
            CASE WHEN v_origen = 'gestion' THEN p_gestion_id ELSE NULL END,
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

ALTER FUNCTION ventas.fn_archivos_clientes_listar(bigint, boolean, varchar, bigint) OWNER TO postgres;
ALTER FUNCTION ventas.fn_archivos_clientes_guardar(bigint, bigint, varchar, text, varchar, varchar, varchar, varchar, bigint, integer, boolean, varchar, bigint, bigint, varchar, varchar, inet, text, uuid) OWNER TO postgres;

COMMIT;

-- ---------------------------------------------------------------------------
-- Cómo queda
-- ---------------------------------------------------------------------------
SELECT p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')' AS funcion
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname = 'ventas' AND p.proname LIKE 'fn_archivos_clientes%'
 ORDER BY 1;

SELECT origen, count(*) FROM ventas.archivos_clientes GROUP BY origen ORDER BY 1;
