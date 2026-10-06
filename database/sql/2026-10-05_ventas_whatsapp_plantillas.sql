-- ===========================================================================
-- PLANTILLAS DE WHATSAPP
-- ===========================================================================
-- Fecha: 2026-10-05
--
-- Los mensajes que se ofrecen al escribirle a un cliente estaban escritos en
-- el código (ventas/interfaces/plantillasWhatsapp.ts). Eran seis y el propio
-- archivo lo decía: «si algún día hay que editarlos desde la pantalla, se
-- mueven a una tabla». Ese día es hoy: se piden desde la pantalla para poder
-- cambiar el texto, añadir más y quitar las que no se usan.
--
-- Los huecos entre llaves los sigue rellenando el navegador, igual que antes:
--   {cliente}   nombre completo o razón social
--   {nombre}    sólo el primer nombre
--   {vendedor}  quien está usando el CRM
--   {empresa}   la nuestra
--
-- El `codigo` se queda aunque nada apunte a él todavía: es lo que permitirá
-- mañana decir «la plantilla de cobranza» sin depender de un id que cambia de
-- una base a otra.
--
-- Se siembran las seis que había, con su mismo texto, para que el día del
-- cambio nadie note nada.
--
-- Idempotente: CREATE TABLE IF NOT EXISTS, sembrado con ON CONFLICT y
-- CREATE OR REPLACE de las funciones.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- 1. LA TABLA
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS ventas.whatsapp_plantillas (
    id         bigserial    NOT NULL,
    /** Nombre corto y estable, por si algo tiene que pedir una en concreto */
    codigo     varchar(30)  NOT NULL,
    /** Lo que se lee en el menú de WhatsApp */
    nombre     varchar(60)  NOT NULL,
    /** Clase de Font Awesome, la misma que usa la pantalla: fa-hand, fa-heart… */
    icono      varchar(40),
    /** Lo que se escribe en la gestión que queda registrada */
    asunto     varchar(200) NOT NULL,
    /** El mensaje, con sus huecos entre llaves */
    texto      text         NOT NULL,
    orden      integer      NOT NULL DEFAULT 100,
    activo     boolean      NOT NULL DEFAULT true,

    created_at timestamptz           DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamptz           DEFAULT CURRENT_TIMESTAMP,
    created_by varchar(100),
    updated_by varchar(100),

    CONSTRAINT pk_whatsapp_plantillas     PRIMARY KEY (id),
    CONSTRAINT uq_whatsapp_plantillas_cod UNIQUE (codigo),
    CONSTRAINT ck_whatsapp_plantillas_cod CHECK (codigo = LOWER(TRIM(codigo)) AND length(TRIM(codigo)) >= 3)
);

COMMENT ON TABLE ventas.whatsapp_plantillas IS 'Mensajes que se ofrecen al escribir por WhatsApp a un cliente';

CREATE INDEX IF NOT EXISTS ix_whatsapp_plantillas_orden
    ON ventas.whatsapp_plantillas (activo, orden, nombre);


-- ---------------------------------------------------------------------------
-- 2. LAS SEIS QUE YA HABÍA
-- ---------------------------------------------------------------------------
INSERT INTO ventas.whatsapp_plantillas (codigo, nombre, icono, asunto, texto, orden, created_by, updated_by)
VALUES
  ('saludo', 'Presentación', 'fa-hand', 'Presentación por WhatsApp',
   'Hola {nombre}, le saluda {vendedor} de {empresa}. Le escribo para ponerme a sus órdenes; cualquier consulta que tenga, con gusto le ayudo.',
   10, 'sistema', 'sistema'),
  ('seguimiento', 'Seguimiento', 'fa-rotate-right', 'Seguimiento por WhatsApp',
   'Hola {nombre}, le saluda {vendedor} de {empresa}. Le escribo para dar seguimiento a lo que conversamos. ¿Cómo va el tema?',
   20, 'sistema', 'sistema'),
  ('cotizacion', 'Envío de cotización', 'fa-file-invoice-dollar', 'Envío de cotización por WhatsApp',
   'Hola {nombre}, le saluda {vendedor} de {empresa}. Le hago llegar la cotización que me solicitó. Quedo atento a sus comentarios.',
   30, 'sistema', 'sistema'),
  ('pago', 'Recordatorio de pago', 'fa-money-bill', 'Recordatorio de pago por WhatsApp',
   'Estimado/a {nombre}, le saluda {vendedor} de {empresa}. Le recuerdo con respeto que tiene un saldo pendiente con nosotros. ¿Me confirma cuándo podríamos coordinar el pago?',
   40, 'sistema', 'sistema'),
  ('visita', 'Confirmar visita', 'fa-person-walking', 'Confirmación de visita por WhatsApp',
   'Hola {nombre}, le saluda {vendedor} de {empresa}. Le escribo para confirmar nuestra visita. ¿Le queda bien la fecha y hora que acordamos?',
   50, 'sistema', 'sistema'),
  ('gracias', 'Agradecimiento', 'fa-heart', 'Agradecimiento por WhatsApp',
   '{nombre}, gracias por su compra. Le saluda {vendedor} de {empresa}; cualquier cosa que necesite, quedo a sus órdenes.',
   60, 'sistema', 'sistema')
ON CONFLICT (codigo) DO NOTHING;


-- ---------------------------------------------------------------------------
-- 3. LISTAR
--
-- Con p_incluir_inactivos = false devuelve lo que ve el vendedor en el menú;
-- con true, lo que ve el CRUD.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ventas.fn_whatsapp_plantillas_listar(p_incluir_inactivos boolean DEFAULT true)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'ventas'
AS $function$
DECLARE
    v_data jsonb;
BEGIN
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'id',         p.id,
               'codigo',     p.codigo,
               'nombre',     p.nombre,
               'icono',      p.icono,
               'asunto',     p.asunto,
               'texto',      p.texto,
               'orden',      p.orden,
               'activo',     p.activo,
               'created_by', p.created_by,
               'updated_by', p.updated_by,
               'updated_at', to_char(p.updated_at, 'YYYY-MM-DD HH24:MI')
           ) ORDER BY p.orden, p.nombre), '[]'::jsonb) INTO v_data
      FROM ventas.whatsapp_plantillas p
     WHERE (p_incluir_inactivos OR p.activo);

    RETURN jsonb_build_object('success', true, 'message', 'Plantillas obtenidas exitosamente', 'data', v_data);
END;
$function$;


-- ---------------------------------------------------------------------------
-- 4. GUARDAR (crear y modificar, como en el catálogo de gestiones)
-- ---------------------------------------------------------------------------
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

    -- Sin código se inventa uno a partir del nombre: quien crea una plantilla
    -- está pensando en el mensaje, no en darle un nombre interno
    IF v_codigo IS NULL THEN
        v_codigo := LOWER(REGEXP_REPLACE(TRIM(COALESCE(p_nombre, '')), '[^a-zA-Z0-9]+', '_', 'g'));
        v_codigo := TRIM(BOTH '_' FROM v_codigo);
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
               orden  = COALESCE(p_orden, orden),
               activo = COALESCE(p_activo, activo),
               updated_by = p_usuario_login, updated_at = v_fecha
         WHERE id = p_id;

        v_id := p_id;
    END IF;

    RETURN jsonb_build_object(
        'success', true,
        'message', CASE WHEN p_id IS NULL THEN 'Plantilla creada exitosamente' ELSE 'Plantilla actualizada exitosamente' END,
        'data', (SELECT jsonb_build_object('id', id, 'codigo', codigo, 'nombre', nombre, 'icono', icono,
                                           'asunto', asunto, 'texto', texto, 'orden', orden, 'activo', activo)
                   FROM ventas.whatsapp_plantillas WHERE id = v_id)
    );
END;
$function$;


-- ---------------------------------------------------------------------------
-- 5. ELIMINAR
--
-- Aquí sí se borra de verdad, al revés que en el catálogo de gestiones: una
-- plantilla no es parte del historial. Lo que queda escrito en la gestión es
-- el texto que se envió, copiado en su momento; borrar la plantilla no cambia
-- lo que se dijo. Quien la quiera conservar sin ofrecerla tiene el «activo».
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ventas.fn_whatsapp_plantillas_eliminar(
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
    v_nombre varchar;
BEGIN
    PERFORM ventas.fn_gestiones_contexto(p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    SELECT nombre INTO v_nombre FROM ventas.whatsapp_plantillas WHERE id = p_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'La plantilla no existe' USING ERRCODE = 'P0013';
    END IF;

    DELETE FROM ventas.whatsapp_plantillas WHERE id = p_id;

    RETURN jsonb_build_object(
        'success', true,
        'message', 'Plantilla «' || v_nombre || '» eliminada exitosamente',
        'data', jsonb_build_object('id', p_id)
    );
END;
$function$;
