-- ===========================================================================
-- EL CÓDIGO DE UNA PLANTILLA NO CAMBIA AL EDITARLA
-- ===========================================================================
-- Fecha: 2026-10-05
--
-- Tal como quedó fn_whatsapp_plantillas_guardar, al modificar una plantilla
-- sin mandar código se inventaba uno nuevo a partir del nombre y el UPDATE lo
-- pisaba. Se vio en vivo: «Presentación» nació con codigo = 'saludo' y tras la
-- primera edición pasó a 'presentaci_n'.
--
-- Está mal por dos razones:
--   · el código es la identidad de la fila y el nombre es sólo la etiqueta;
--     si cambia al renombrar, deja de servir para lo único que sirve;
--   · dos nombres distintos pueden dar el mismo código («Pago 30» y
--     «Pago-30» → pago_30), así que renombrar podía reventar contra el
--     índice único de un código que ni se pidió.
--
-- Queda así: al crear se inventa, al editar se respeta el que ya tiene (salvo
-- que se mande uno a propósito, que la pantalla no hace).
--
-- De paso, el generador quita las tildes antes de cortar por caracteres raros.
-- Sin eso «Presentación» daba 'presentaci_n', con un hueco donde iba la ó.
-- No se usa unaccent() porque es una extensión y no está instalada; para las
-- letras del español basta translate().
--
-- Y se devuelve a la fila 1 su código original, que es el que perdió por esto.
-- ===========================================================================

CREATE OR REPLACE FUNCTION ventas.fn_whatsapp_plantillas_guardar(
    p_id             bigint  DEFAULT NULL,
    p_codigo         varchar DEFAULT NULL,
    p_nombre         varchar DEFAULT NULL,
    p_icono          varchar DEFAULT NULL,
    p_asunto         varchar DEFAULT NULL,
    p_texto          text    DEFAULT NULL,
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
    v_codigo varchar := LOWER(NULLIF(TRIM(COALESCE(p_codigo, '')), ''));
    v_fecha  timestamptz := CURRENT_TIMESTAMP;
BEGIN
    PERFORM ventas.fn_gestiones_contexto(p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    -- Al editar sin código, el que ya tiene: renombrar una plantilla no es
    -- cambiarla de identidad.
    IF v_codigo IS NULL AND p_id IS NOT NULL THEN
        SELECT codigo INTO v_codigo FROM ventas.whatsapp_plantillas WHERE id = p_id;
    END IF;

    -- Sin código se inventa uno a partir del nombre: quien crea una plantilla
    -- está pensando en el mensaje, no en darle un nombre interno
    IF v_codigo IS NULL THEN
        v_codigo := TRANSLATE(TRIM(COALESCE(p_nombre, '')),
                              'áéíóúÁÉÍÓÚàèìòùÀÈÌÒÙäëïöüÄËÏÖÜâêîôûÂÊÎÔÛñÑçÇ',
                              'aeiouAEIOUaeiouAEIOUaeiouAEIOUaeiouAEIOUnNcC');
        v_codigo := LOWER(REGEXP_REPLACE(v_codigo, '[^a-zA-Z0-9]+', '_', 'g'));
        v_codigo := TRIM(BOTH '_' FROM v_codigo);
        v_codigo := NULLIF(v_codigo, '');
        v_codigo := LEFT(v_codigo, 30);
    END IF;

    IF v_codigo IS NULL OR length(v_codigo) < 3 THEN
        RAISE EXCEPTION 'El código es obligatorio (mínimo 3 caracteres)' USING ERRCODE = 'P0001';
    END IF;
    IF length(TRIM(COALESCE(p_nombre, ''))) < 3 THEN
        RAISE EXCEPTION 'El nombre es obligatorio (mínimo 3 caracteres)' USING ERRCODE = 'P0001';
    END IF;
    IF length(TRIM(COALESCE(p_asunto, ''))) < 3 THEN
        RAISE EXCEPTION 'El asunto es obligatorio (mínimo 3 caracteres)' USING ERRCODE = 'P0001';
    END IF;
    IF length(TRIM(COALESCE(p_texto, ''))) < 10 THEN
        RAISE EXCEPTION 'El mensaje es obligatorio (mínimo 10 caracteres)' USING ERRCODE = 'P0001';
    END IF;
    IF EXISTS (SELECT 1 FROM ventas.whatsapp_plantillas WHERE codigo = v_codigo AND id IS DISTINCT FROM p_id) THEN
        RAISE EXCEPTION 'Ya existe una plantilla con el código %', v_codigo USING ERRCODE = 'P0020';
    END IF;

    IF p_id IS NULL THEN
        INSERT INTO ventas.whatsapp_plantillas (codigo, nombre, icono, asunto, texto, orden, activo, created_by, updated_by)
        VALUES (v_codigo, TRIM(p_nombre), NULLIF(TRIM(COALESCE(p_icono, '')), ''),
                TRIM(p_asunto), TRIM(p_texto),
                COALESCE(p_orden, 100), COALESCE(p_activo, true), p_usuario_login, p_usuario_login)
        RETURNING id INTO v_id;
    ELSE
        IF NOT EXISTS (SELECT 1 FROM ventas.whatsapp_plantillas WHERE id = p_id) THEN
            RAISE EXCEPTION 'La plantilla no existe' USING ERRCODE = 'P0013';
        END IF;

        UPDATE ventas.whatsapp_plantillas
           SET codigo = v_codigo,
               nombre = TRIM(p_nombre),
               icono  = NULLIF(TRIM(COALESCE(p_icono, '')), ''),
               asunto = TRIM(p_asunto),
               texto  = TRIM(p_texto),
               orden  = COALESCE(p_orden, 100),
               activo = COALESCE(p_activo, true),
               updated_at = v_fecha,
               updated_by = p_usuario_login
         WHERE id = p_id;

        v_id := p_id;
    END IF;

    RETURN jsonb_build_object(
        'status',  'success',
        'message', CASE WHEN p_id IS NULL THEN 'Plantilla creada exitosamente'
                                          ELSE 'Plantilla actualizada exitosamente' END,
        'data',    (SELECT to_jsonb(p) FROM ventas.whatsapp_plantillas p WHERE p.id = v_id)
    );
END;
$function$;

ALTER FUNCTION ventas.fn_whatsapp_plantillas_guardar(bigint, varchar, varchar, varchar, varchar, text, integer, boolean, bigint, varchar, varchar, inet, text, uuid) OWNER TO postgres;

-- La fila que perdió su código por el fallo de arriba. Se toca sólo si sigue
-- con el código inventado, para que esto se pueda volver a ejecutar.
UPDATE ventas.whatsapp_plantillas
   SET codigo = 'saludo'
 WHERE id = 1
   AND codigo = 'presentaci_n'
   AND NOT EXISTS (SELECT 1 FROM ventas.whatsapp_plantillas WHERE codigo = 'saludo');

SELECT id, codigo, nombre, orden, activo FROM ventas.whatsapp_plantillas ORDER BY orden, nombre;
