-- ===========================================================================
-- EL MENSAJE VIVE EN EL ASUNTO (ventas.gestiones_asuntos.mensaje)
-- ===========================================================================
-- Fecha: 2026-10-06
-- Deshace 2026-10-05_ventas_whatsapp_plantillas.sql y lo que vino detrás.
--
-- Las «respuestas de WhatsApp» nacieron en su propia tabla y eso estaba mal
-- pensado: cada plantilla tenía un `asunto` que era, palabra por palabra, el
-- nombre de un asunto del catálogo. Dos sitios manteniendo la misma lista, y
-- unidos por una cadena de texto que nadie garantizaba:
--
--   whatsapp_plantillas.asunto = 'Seguimiento por WhatsApp'
--   gestiones_asuntos.nombre   = 'Seguimiento por WhatsApp'
--
-- Renombrar el asunto en el catálogo rompía la correspondencia en silencio, y
-- de hecho una de las seis plantillas ya apuntaba a un asunto que no existía.
--
-- El mensaje no es otra entidad: es un atributo del asunto. «Seguimiento por
-- WhatsApp» ES el asunto y el texto que se manda es suyo. Así que una columna
-- y fuera la tabla.
--
-- Lo que se gana, además de no duplicar:
--   · sirve para cualquier tipo, no sólo WHATSAPP. Un asunto de CORREO puede
--     llevar su plantilla en HTML, que es para lo que la columna es `text` y
--     no varchar.
--   · el menú de WhatsApp deja de pedir nada al servidor: el catálogo ya se
--     carga y se guarda en memoria para los combos de la gestión.
--   · se mantiene donde se mantiene todo lo demás del asunto, en Catálogo de
--     Gestiones, y desaparece una pantalla entera.
--
-- Los mensajes que había se mueven, no se pierden. Donde la plantilla apuntaba
-- a un asunto que no existía, se crea.
--
-- Idempotente: se puede volver a ejecutar aunque la tabla vieja ya no esté.
-- ===========================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. LA COLUMNA
--
-- text y no varchar: para WhatsApp son tres líneas, pero para un correo cabe
-- HTML pegado del editor, que no tiene un largo razonable que poner.
-- ---------------------------------------------------------------------------
ALTER TABLE ventas.gestiones_asuntos
    ADD COLUMN IF NOT EXISTS mensaje text;

COMMENT ON COLUMN ventas.gestiones_asuntos.mensaje IS
    'Lo que se le manda al cliente con este asunto. Texto para WhatsApp, HTML para correo. Vacío = el asunto no ofrece mensaje.';

-- ---------------------------------------------------------------------------
-- 2. MUDANZA DE LAS PLANTILLAS
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    v_tipo_wa bigint;
    v_p       record;
    v_id      bigint;
BEGIN
    IF to_regclass('ventas.whatsapp_plantillas') IS NULL THEN
        RAISE NOTICE 'No hay whatsapp_plantillas que mudar (ya se hizo)';
        RETURN;
    END IF;

    SELECT id INTO v_tipo_wa FROM ventas.gestiones_tipos WHERE codigo = 'WHATSAPP';
    IF v_tipo_wa IS NULL THEN
        RAISE EXCEPTION 'No existe el tipo de gestión WHATSAPP: sin él no hay dónde poner los mensajes';
    END IF;

    FOR v_p IN SELECT * FROM ventas.whatsapp_plantillas ORDER BY orden, id LOOP
        SELECT a.id INTO v_id
          FROM ventas.gestiones_asuntos a
         WHERE a.tipo_id = v_tipo_wa
           AND lower(trim(a.nombre)) = lower(trim(COALESCE(v_p.asunto, '')));

        IF v_id IS NULL THEN
            -- La plantilla apuntaba a un asunto que no estaba en el catálogo:
            -- se crea con su nombre, que es justo el agujero que esto cierra
            INSERT INTO ventas.gestiones_asuntos (tipo_id, nombre, orden, activo, mensaje, created_by, updated_by)
            VALUES (v_tipo_wa,
                    substr(COALESCE(NULLIF(trim(v_p.asunto), ''), v_p.nombre), 1, 200),
                    COALESCE(v_p.orden, 100), COALESCE(v_p.activo, true), v_p.texto,
                    'LAGILA', 'LAGILA')
            ON CONFLICT (tipo_id, nombre) DO UPDATE SET mensaje = EXCLUDED.mensaje;
            RAISE NOTICE 'Asunto creado para la plantilla «%»', v_p.nombre;
        ELSE
            -- El que ya estaba: se le pone el mensaje, sin pisar uno escrito
            UPDATE ventas.gestiones_asuntos
               SET mensaje = COALESCE(NULLIF(trim(mensaje), ''), v_p.texto),
                   updated_at = CURRENT_TIMESTAMP
             WHERE id = v_id;
        END IF;
    END LOOP;
END $$;

-- ---------------------------------------------------------------------------
-- 3. FUERA LA TABLA Y SUS FUNCIONES
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    v_f record;
BEGIN
    FOR v_f IN
        SELECT p.oid::regprocedure AS firma
          FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
         WHERE n.nspname = 'ventas' AND p.proname LIKE 'fn_whatsapp_plantillas%'
    LOOP
        EXECUTE 'DROP FUNCTION ' || v_f.firma;
    END LOOP;
END $$;

DROP TABLE IF EXISTS ventas.whatsapp_plantillas;

-- ---------------------------------------------------------------------------
-- 4. Y FUERA SU PANTALLA
-- ---------------------------------------------------------------------------
DELETE FROM seguridad.accesos
 WHERE menu_id IN (SELECT id FROM seguridad.menus WHERE url = 'ventas/plantillasWhatsapp');

DELETE FROM seguridad.menus WHERE url = 'ventas/plantillasWhatsapp';

-- ---------------------------------------------------------------------------
-- 5. LISTAR, CON EL MENSAJE
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ventas.fn_gestiones_asuntos_listar(
    p_tipo_id           bigint DEFAULT NULL,
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
               'mensaje',     a.mensaje,
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
-- 6. EL CATÁLOGO, CON EL MENSAJE
--
-- Aquí es donde más se nota el cambio: esto ya lo pide la pantalla de gestión
-- para llenar los combos, así que el menú de WhatsApp no necesita ni una
-- consulta más. Antes era una tabla aparte con su servicio y su caché.
-- ---------------------------------------------------------------------------
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
                       SELECT jsonb_agg(jsonb_build_object(
                                  'id', a.id, 'nombre', a.nombre,
                                  'mensaje', a.mensaje, 'orden', a.orden)
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

-- ---------------------------------------------------------------------------
-- 7. GUARDAR, CON EL MENSAJE
--
-- La firma cambia, así que fuera la anterior: CREATE OR REPLACE con otros
-- parámetros no reemplaza, añade una sobrecarga, y una llamada podría caer en
-- la vieja —la que no guarda el mensaje— sin que nadie se entere.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    v_f record;
BEGIN
    FOR v_f IN
        SELECT p.oid::regprocedure AS firma
          FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
         WHERE n.nspname = 'ventas' AND p.proname = 'fn_gestiones_asuntos_guardar'
    LOOP
        EXECUTE 'DROP FUNCTION ' || v_f.firma;
    END LOOP;
END $$;

CREATE OR REPLACE FUNCTION ventas.fn_gestiones_asuntos_guardar(
    p_id             bigint  DEFAULT NULL,
    p_tipo_id        bigint  DEFAULT NULL,
    p_nombre         varchar DEFAULT NULL,
    p_orden          integer DEFAULT NULL,
    p_activo         boolean DEFAULT true,
    /** NULL al editar = no se toca; '' = se vacía */
    p_mensaje        text    DEFAULT NULL,
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

    IF p_id IS NULL THEN
        IF NOT EXISTS (SELECT 1 FROM ventas.gestiones_tipos WHERE id = p_tipo_id) THEN
            RAISE EXCEPTION 'El tipo de gestión no existe' USING ERRCODE = 'P0013';
        END IF;
        IF EXISTS (SELECT 1 FROM ventas.gestiones_asuntos
                    WHERE tipo_id = p_tipo_id AND lower(trim(nombre)) = lower(v_nombre)) THEN
            RAISE EXCEPTION 'Ese tipo ya tiene un asunto con ese nombre' USING ERRCODE = 'P0020';
        END IF;

        INSERT INTO ventas.gestiones_asuntos (tipo_id, nombre, orden, activo, mensaje, created_by, updated_by)
        VALUES (p_tipo_id, substr(v_nombre, 1, 200), COALESCE(p_orden, 100), COALESCE(p_activo, true),
                NULLIF(p_mensaje, ''), p_usuario_login, p_usuario_login)
        RETURNING id INTO v_id;
    ELSE
        IF EXISTS (SELECT 1 FROM ventas.gestiones_asuntos
                    WHERE tipo_id = COALESCE(p_tipo_id, (SELECT tipo_id FROM ventas.gestiones_asuntos WHERE id = p_id))
                      AND lower(trim(nombre)) = lower(v_nombre)
                      AND id <> p_id) THEN
            RAISE EXCEPTION 'Ese tipo ya tiene un asunto con ese nombre' USING ERRCODE = 'P0020';
        END IF;

        UPDATE ventas.gestiones_asuntos
           SET nombre     = substr(v_nombre, 1, 200),
               orden      = COALESCE(p_orden, orden),
               activo     = COALESCE(p_activo, activo),
               -- NULL deja el mensaje como estaba; '' lo borra. Así la pantalla
               -- que sólo renombra no tiene que reenviar el mensaje entero.
               mensaje    = CASE WHEN p_mensaje IS NULL THEN mensaje ELSE NULLIF(p_mensaje, '') END,
               updated_by = p_usuario_login,
               updated_at = v_fecha
         WHERE id = p_id;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'El asunto no existe' USING ERRCODE = 'P0013';
        END IF;
        v_id := p_id;
    END IF;

    RETURN jsonb_build_object(
        'success', true,
        'message', CASE WHEN p_id IS NULL THEN 'Asunto creado exitosamente' ELSE 'Asunto actualizado exitosamente' END,
        'data', (SELECT jsonb_build_object('id', a.id, 'tipo_id', a.tipo_id, 'nombre', a.nombre,
                                           'mensaje', a.mensaje, 'orden', a.orden, 'activo', a.activo)
                   FROM ventas.gestiones_asuntos a WHERE a.id = v_id)
    );
END;
$function$;

ALTER FUNCTION ventas.fn_gestiones_asuntos_guardar(bigint, bigint, varchar, integer, boolean, text, bigint, varchar, varchar, inet, text, uuid) OWNER TO postgres;

COMMIT;

-- ---------------------------------------------------------------------------
-- Cómo queda
-- ---------------------------------------------------------------------------
SELECT a.id, t.codigo AS tipo, a.nombre, left(COALESCE(a.mensaje, ''), 45) AS mensaje
  FROM ventas.gestiones_asuntos a JOIN ventas.gestiones_tipos t ON t.id = a.tipo_id
 WHERE a.mensaje IS NOT NULL
 ORDER BY t.codigo, a.orden, a.nombre;

SELECT to_regclass('ventas.whatsapp_plantillas') AS tabla_vieja;
SELECT count(*) AS menus_de_la_pantalla_vieja FROM seguridad.menus WHERE url = 'ventas/plantillasWhatsapp';
