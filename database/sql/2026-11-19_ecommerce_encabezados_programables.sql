-- ============================================================================
-- LOS ENCABEZADOS SE PROGRAMAN: UNO POR CAMPAÑA, CON SUS FECHAS
-- ============================================================================
-- Había UN encabezado y punto: una fila con el id 1 y una regla que impedía
-- que hubiera otra. Para una campaña había que entrar a cambiarle los colores
-- a mano el día que empezaba y volver a cambiarlos el día que terminaba, y
-- acordarse de los dos días.
--
-- AHORA HAY LOS QUE HAGAN FALTA, cada uno con su nombre y sus fechas: uno de
-- Navidad del 1 de diciembre al 6 de enero, uno de Black Friday de tres días,
-- y el de siempre debajo. Se encienden y se apagan solos.
--
-- CUÁL SE VE, por orden:
--
--   1. el que esté ACTIVO y DENTRO DE SUS FECHAS; si hay varios, el que haya
--      empezado más tarde (una campaña de tres días metida dentro de la de
--      Navidad gana esos tres días, que es lo que se quiere);
--   2. si ninguno tiene fechas puestas, EL PREDETERMINADO;
--   3. y si no hubiera ninguno utilizable, el predeterminado igual: la tienda
--      tiene que pintar un encabezado siempre, aunque alguien lo apague.
--
-- EL PREDETERMINADO NO SE APAGA NI SE BORRA, por eso mismo. Sólo se cambia por
-- otro, y al hacerlo el nuevo se enciende.
--
-- EL MENÚ SIGUE SIENDO UNO SOLO para todos —añadir una categoría se hace una
-- vez—, pero AHORA CADA ENLACE PUEDE TENER SUS FECHAS: «Regalos» aparece el 1
-- de diciembre y se va solo el 6 de enero, sin tocar nada y sin duplicar el
-- menú en cada encabezado.
--
-- ----------------------------------------------------------------------------
-- SE EJECUTA A MANO. Para ensayar sin guardar, cambiar el COMMIT del final por
-- ROLLBACK: la comprobación se hace igual y no queda rastro.
-- ============================================================================

BEGIN;

-- ---------- 1. La tabla admite muchos ----------
ALTER TABLE ecommerce.encabezado DROP CONSTRAINT IF EXISTS ck_encabezado_fila_unica;

-- El id venía con DEFAULT 1, que era toda la «secuencia» que hacía falta
CREATE SEQUENCE IF NOT EXISTS ecommerce.encabezado_id_seq OWNED BY ecommerce.encabezado.id;
SELECT setval('ecommerce.encabezado_id_seq', GREATEST(COALESCE((SELECT max(id) FROM ecommerce.encabezado), 1), 1));
ALTER TABLE ecommerce.encabezado ALTER COLUMN id SET DEFAULT nextval('ecommerce.encabezado_id_seq');

ALTER TABLE ecommerce.encabezado
    ADD COLUMN IF NOT EXISTS nombre    character varying(60) NOT NULL DEFAULT 'Encabezado',
    ADD COLUMN IF NOT EXISTS desde     timestamp with time zone,
    ADD COLUMN IF NOT EXISTS hasta     timestamp with time zone,
    ADD COLUMN IF NOT EXISTS activo    boolean NOT NULL DEFAULT true,
    ADD COLUMN IF NOT EXISTS principal boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN ecommerce.encabezado.nombre IS 'Cómo se llama aquí dentro: «El de siempre», «Navidad». El cliente no lo lee.';
COMMENT ON COLUMN ecommerce.encabezado.desde IS 'Desde cuándo se ve. Vacío = desde siempre.';
COMMENT ON COLUMN ecommerce.encabezado.hasta IS 'Hasta cuándo. Vacío = para siempre.';
COMMENT ON COLUMN ecommerce.encabezado.principal IS 'El predeterminado: el que se ve cuando no hay ninguna campaña en fecha. Hay exactamente uno y no se apaga ni se borra.';

ALTER TABLE ecommerce.encabezado DROP CONSTRAINT IF EXISTS ck_encabezado_vigencia;
ALTER TABLE ecommerce.encabezado
    ADD CONSTRAINT ck_encabezado_vigencia
    CHECK (desde IS NULL OR hasta IS NULL OR hasta >= desde);

ALTER TABLE ecommerce.encabezado DROP CONSTRAINT IF EXISTS ck_encabezado_nombre;
ALTER TABLE ecommerce.encabezado
    ADD CONSTRAINT ck_encabezado_nombre CHECK (length(btrim(nombre::text)) >= 1);

-- El que había pasa a ser el predeterminado
UPDATE ecommerce.encabezado
   SET principal = true,
       nombre = CASE WHEN nombre = 'Encabezado' THEN 'El de siempre' ELSE nombre END
 WHERE id = 1
   AND NOT EXISTS (SELECT 1 FROM ecommerce.encabezado WHERE principal);

-- Uno y sólo uno
CREATE UNIQUE INDEX IF NOT EXISTS uq_encabezado_principal
    ON ecommerce.encabezado (principal) WHERE principal;

-- ---------- 2. Y cada enlace del menú, sus fechas ----------
ALTER TABLE ecommerce.encabezado_enlaces
    ADD COLUMN IF NOT EXISTS desde timestamp with time zone,
    ADD COLUMN IF NOT EXISTS hasta timestamp with time zone;

COMMENT ON COLUMN ecommerce.encabezado_enlaces.desde IS 'Desde cuándo sale en el menú. Vacío = siempre.';

ALTER TABLE ecommerce.encabezado_enlaces DROP CONSTRAINT IF EXISTS ck_encabezado_enlaces_vigencia;
ALTER TABLE ecommerce.encabezado_enlaces
    ADD CONSTRAINT ck_encabezado_enlaces_vigencia
    CHECK (desde IS NULL OR hasta IS NULL OR hasta >= desde);

-- ---------- 3. Cuál manda hoy ----------
CREATE OR REPLACE FUNCTION ecommerce.fn_encabezado_vigente_id()
 RETURNS bigint
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'ecommerce'
AS $function$
    -- EL ORDEN ES LA REGLA, escrita una sola vez y en un solo sitio:
    --
    --   grupo 0  los que tienen fechas puestas y están en ellas: una campaña
    --   grupo 1  los que no tienen ninguna: valen siempre
    --
    -- Dentro del grupo 0 gana el que empezó más tarde, porque una campaña
    -- corta metida dentro de una larga es la que se quiso para esos días.
    -- Dentro del 1 gana el predeterminado, que es justo lo que significa.
    --
    -- Y SI NO QUEDA NINGUNO —todos apagados o fuera de fecha—, el
    -- predeterminado igual: la tienda tiene que pintar un encabezado siempre.
    SELECT COALESCE(
        (SELECT e.id
           FROM ecommerce.encabezado e
          WHERE e.activo AND ecommerce.fn_vigente(e.desde, e.hasta)
          ORDER BY CASE WHEN e.desde IS NOT NULL OR e.hasta IS NOT NULL THEN 0 ELSE 1 END,
                   e.desde DESC NULLS LAST,
                   e.principal DESC,
                   e.id DESC
          LIMIT 1),
        (SELECT e.id FROM ecommerce.encabezado e WHERE e.principal),
        (SELECT min(e.id) FROM ecommerce.encabezado e));
$function$;

-- ---------- 4. La lista, y el que se está editando ----------
CREATE OR REPLACE FUNCTION ecommerce.fn_encabezados_listar()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'ecommerce'
AS $function$
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'id',        e.id,
               'nombre',    e.nombre,
               'desde',     to_char(e.desde, 'YYYY-MM-DD"T"HH24:MI'),
               'hasta',     to_char(e.hasta, 'YYYY-MM-DD"T"HH24:MI'),
               'activo',    e.activo,
               'principal', e.principal,
               -- En qué estado está, resuelto aquí y no en la pantalla
               'estado',    CASE
                   WHEN NOT e.activo THEN 'oculto'
                   WHEN e.desde IS NOT NULL AND CURRENT_TIMESTAMP < e.desde THEN 'programado'
                   WHEN e.hasta IS NOT NULL AND CURRENT_TIMESTAMP > e.hasta THEN 'terminado'
                   ELSE 'visible' END,
               -- Y CUÁL ES EL QUE SE ESTÁ VIENDO AHORA MISMO en la tienda: es
               -- la pregunta que se hace quien entra a esta pantalla, y con
               -- cuatro campañas no se contesta mirando fechas
               'manda',     e.id = ecommerce.fn_encabezado_vigente_id(),
               'logo',      e.logo,
               'updated_at', to_char(e.updated_at, 'YYYY-MM-DD HH24:MI'),
               'updated_by', e.updated_by)
           -- El predeterminado primero y las campañas por fecha: es el orden en
           -- que se leen, no el de creación
           ORDER BY e.principal DESC, e.desde NULLS FIRST, e.id), '[]'::jsonb)
      FROM ecommerce.encabezado e;
$function$;

CREATE OR REPLACE FUNCTION ecommerce.fn_encabezado_obtener(p_id bigint DEFAULT NULL::bigint)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'ecommerce'
AS $function$
    -- Sin id, el predeterminado: es el que se abre al entrar a la pantalla
    SELECT jsonb_build_object('success', true, 'message', 'Encabezado',
        'data', jsonb_build_object(
            'id',      e.id,
            'nombre',  e.nombre,
            'desde',   to_char(e.desde, 'YYYY-MM-DD"T"HH24:MI'),
            'hasta',   to_char(e.hasta, 'YYYY-MM-DD"T"HH24:MI'),
            'activo',  e.activo,
            'principal', e.principal,
            'manda',   e.id = ecommerce.fn_encabezado_vigente_id(),
            'config',  e.config,
            -- El fichero del logo, o NULL para el de la casa. La dirección la
            -- arma el controlador, como con el resto de imágenes del ecommerce
            'logo',    e.logo,
            -- TODOS, para poder cambiar de uno a otro sin otra llamada
            'encabezados', ecommerce.fn_encabezados_listar(),
            -- El menú es UNO SOLO y vale para todos: no cuelga de ninguno
            'enlaces', ecommerce.fn_encabezado_enlaces_json(),
            'updated_at', to_char(e.updated_at, 'YYYY-MM-DD HH24:MI:SS'),
            'updated_by', e.updated_by))
      FROM ecommerce.encabezado e
     WHERE e.id = COALESCE(p_id, (SELECT x.id FROM ecommerce.encabezado x WHERE x.principal),
                                 (SELECT min(x.id) FROM ecommerce.encabezado x));
$function$;

-- La de cero argumentos se va: con las dos, llamarla sin id es ambiguo
DROP FUNCTION IF EXISTS ecommerce.fn_encabezado_obtener();

-- Y de paso, la de modificar que quedó de la versión anterior del módulo:
-- escribe en columnas que esta tabla ya no tiene (enc_config, usu_id), así que
-- lo único que puede hacer es fallar
DROP FUNCTION IF EXISTS ecommerce.fn_encabezado_modificar(jsonb);

-- ---------- 5. Crear, guardar, encender, predeterminar y borrar ----------
CREATE OR REPLACE FUNCTION ecommerce.fn_encabezados_crear(p_nombre text, p_copiar_de bigint DEFAULT NULL::bigint, p_usuario_id bigint DEFAULT NULL::bigint, p_usuario_login character varying DEFAULT NULL::character varying, p_usuario_nombre character varying DEFAULT NULL::character varying, p_ip_address inet DEFAULT NULL::inet, p_user_agent text DEFAULT NULL::text, p_request_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'ecommerce', 'auditoria'
AS $function$
DECLARE
    v_nombre text;
    v_de     bigint;
    v_id     bigint;
BEGIN
    PERFORM ecommerce.fn_contexto_auditoria('ecommerce.encabezado',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    v_nombre := ecommerce.fn_validar_texto(p_nombre, 'El nombre del encabezado', 60, true);

    -- NACE COPIANDO a otro, el predeterminado mientras no se diga: un
    -- encabezado en blanco sale con la tienda sin colores y sin logo, y lo
    -- primero que habría que hacer es volver a escribirlo todo.
    v_de := COALESCE(p_copiar_de, (SELECT id FROM ecommerce.encabezado WHERE principal));

    IF NOT EXISTS (SELECT 1 FROM ecommerce.encabezado WHERE id = v_de) THEN
        RAISE EXCEPTION 'El encabezado del que se quiere copiar no existe' USING ERRCODE = 'P0013';
    END IF;

    INSERT INTO ecommerce.encabezado (nombre, config, logo, activo, principal)
    SELECT v_nombre, e.config, e.logo, true, false
      FROM ecommerce.encabezado e WHERE e.id = v_de
    RETURNING id INTO v_id;

    RETURN jsonb_build_object('success', true,
        'message', format('«%s» creado, copiando el de «%s». Ponle sus fechas', v_nombre,
                          (SELECT nombre FROM ecommerce.encabezado WHERE id = v_de)),
        'id', v_id,
        'data', (ecommerce.fn_encabezado_obtener(v_id) -> 'data'));
END;
$function$;

CREATE OR REPLACE FUNCTION ecommerce.fn_encabezados_guardar(p_id bigint, p_datos jsonb, p_usuario_id bigint DEFAULT NULL::bigint, p_usuario_login character varying DEFAULT NULL::character varying, p_usuario_nombre character varying DEFAULT NULL::character varying, p_ip_address inet DEFAULT NULL::inet, p_user_agent text DEFAULT NULL::text, p_request_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'ecommerce', 'auditoria'
AS $function$
DECLARE
    v_nombre    text;
    v_desde     timestamptz;
    v_hasta     timestamptz;
    v_activo    boolean;
    v_principal boolean;
BEGIN
    PERFORM ecommerce.fn_contexto_auditoria('ecommerce.encabezado',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    SELECT principal INTO v_principal FROM ecommerce.encabezado WHERE id = p_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Ese encabezado no existe' USING ERRCODE = 'P0013';
    END IF;

    v_nombre := ecommerce.fn_validar_texto(p_datos ->> 'nombre', 'El nombre del encabezado', 60, true);
    v_desde  := nullif(btrim(COALESCE(p_datos ->> 'desde', '')), '')::timestamptz;
    v_hasta  := nullif(btrim(COALESCE(p_datos ->> 'hasta', '')), '')::timestamptz;
    v_activo := COALESCE((p_datos ->> 'activo')::boolean, true);

    IF v_desde IS NOT NULL AND v_hasta IS NOT NULL AND v_hasta < v_desde THEN
        RAISE EXCEPTION 'Las fechas van al revés: «hasta» es anterior a «desde»' USING ERRCODE = 'P0015';
    END IF;

    -- EL PREDETERMINADO NO SE APAGA: es el que se ve cuando no hay ninguna
    -- campaña en fecha, así que apagarlo dejaría la tienda sin encabezado.
    -- Para quitarlo de en medio se nombra predeterminado a otro.
    IF v_principal AND NOT v_activo THEN
        RAISE EXCEPTION 'El predeterminado no se puede apagar: nombra predeterminado a otro primero'
            USING ERRCODE = 'P0016';
    END IF;

    UPDATE ecommerce.encabezado
       SET nombre = v_nombre, desde = v_desde, hasta = v_hasta, activo = v_activo
     WHERE id = p_id;

    RETURN jsonb_build_object('success', true, 'message', format('«%s» guardado', v_nombre),
                              'data', (ecommerce.fn_encabezado_obtener(p_id) -> 'data'));
END;
$function$;

CREATE OR REPLACE FUNCTION ecommerce.fn_encabezados_activar(p_id bigint, p_activo boolean DEFAULT NULL::boolean, p_usuario_id bigint DEFAULT NULL::bigint, p_usuario_login character varying DEFAULT NULL::character varying, p_usuario_nombre character varying DEFAULT NULL::character varying, p_ip_address inet DEFAULT NULL::inet, p_user_agent text DEFAULT NULL::text, p_request_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'ecommerce', 'auditoria'
AS $function$
DECLARE
    v_fila   record;
    v_activo boolean;
BEGIN
    PERFORM ecommerce.fn_contexto_auditoria('ecommerce.encabezado',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    SELECT * INTO v_fila FROM ecommerce.encabezado WHERE id = p_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Ese encabezado no existe' USING ERRCODE = 'P0013';
    END IF;

    -- Sin valor, alterna: es lo que hace el interruptor de la lista
    v_activo := COALESCE(p_activo, NOT v_fila.activo);

    IF v_fila.principal AND NOT v_activo THEN
        RAISE EXCEPTION 'El predeterminado no se puede apagar: nombra predeterminado a otro primero'
            USING ERRCODE = 'P0016';
    END IF;

    UPDATE ecommerce.encabezado SET activo = v_activo WHERE id = p_id;

    RETURN jsonb_build_object('success', true,
        'message', format('«%s» %s', v_fila.nombre, CASE WHEN v_activo THEN 'encendido' ELSE 'apagado' END),
        'data', (ecommerce.fn_encabezado_obtener(p_id) -> 'data'));
END;
$function$;

CREATE OR REPLACE FUNCTION ecommerce.fn_encabezados_principal(p_id bigint, p_usuario_id bigint DEFAULT NULL::bigint, p_usuario_login character varying DEFAULT NULL::character varying, p_usuario_nombre character varying DEFAULT NULL::character varying, p_ip_address inet DEFAULT NULL::inet, p_user_agent text DEFAULT NULL::text, p_request_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'ecommerce', 'auditoria'
AS $function$
DECLARE
    v_nombre text;
BEGIN
    PERFORM ecommerce.fn_contexto_auditoria('ecommerce.encabezado',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    SELECT nombre INTO v_nombre FROM ecommerce.encabezado WHERE id = p_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Ese encabezado no existe' USING ERRCODE = 'P0013';
    END IF;

    -- Primero se quita el que había: el índice único no admite dos a la vez
    UPDATE ecommerce.encabezado SET principal = false WHERE principal AND id <> p_id;
    -- Y EL NUEVO SE ENCIENDE: un predeterminado apagado dejaría la tienda sin
    -- encabezado el día que no haya ninguna campaña
    UPDATE ecommerce.encabezado SET principal = true, activo = true WHERE id = p_id;

    RETURN jsonb_build_object('success', true,
        'message', format('«%s» es el predeterminado', v_nombre),
        'data', (ecommerce.fn_encabezado_obtener(p_id) -> 'data'));
END;
$function$;

CREATE OR REPLACE FUNCTION ecommerce.fn_encabezados_eliminar(p_id bigint, p_usuario_id bigint DEFAULT NULL::bigint, p_usuario_login character varying DEFAULT NULL::character varying, p_usuario_nombre character varying DEFAULT NULL::character varying, p_ip_address inet DEFAULT NULL::inet, p_user_agent text DEFAULT NULL::text, p_request_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'ecommerce', 'auditoria'
AS $function$
DECLARE
    v_fila record;
BEGIN
    PERFORM ecommerce.fn_contexto_auditoria('ecommerce.encabezado',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    SELECT * INTO v_fila FROM ecommerce.encabezado WHERE id = p_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Ese encabezado no existe' USING ERRCODE = 'P0013';
    END IF;

    IF v_fila.principal THEN
        RAISE EXCEPTION 'El predeterminado no se borra: nombra predeterminado a otro primero'
            USING ERRCODE = 'P0016';
    END IF;

    -- NO HAY PAPELERA, y es a propósito: un encabezado es un puñado de colores
    -- y un logo, y el logo sigue en la biblioteca de imágenes. Lo que se pierde
    -- se vuelve a elegir en un minuto.
    DELETE FROM ecommerce.encabezado WHERE id = p_id;

    RETURN jsonb_build_object('success', true,
        'message', format('«%s» borrado', v_fila.nombre),
        'data', (ecommerce.fn_encabezado_obtener(NULL) -> 'data'));
END;
$function$;

-- ---------- 6. El config y el logo, de UNO ----------
CREATE OR REPLACE FUNCTION ecommerce.fn_encabezado_modificar(p_id bigint, p_config jsonb, p_usuario_id bigint DEFAULT NULL::bigint, p_usuario_login character varying DEFAULT NULL::character varying, p_usuario_nombre character varying DEFAULT NULL::character varying, p_ip_address inet DEFAULT NULL::inet, p_user_agent text DEFAULT NULL::text, p_request_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'ecommerce', 'auditoria'
AS $function$
DECLARE
    v_id bigint;
BEGIN
    PERFORM ecommerce.fn_contexto_auditoria('ecommerce.encabezado',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    -- Sin id, el predeterminado: así la llamada de siempre sigue valiendo
    v_id := COALESCE(p_id, (SELECT id FROM ecommerce.encabezado WHERE principal));

    UPDATE ecommerce.encabezado
       SET config = ecommerce.fn_encabezado_validar_config(p_config)
     WHERE id = v_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Ese encabezado no existe' USING ERRCODE = 'P0013';
    END IF;

    RETURN jsonb_build_object('success', true, 'message', 'Encabezado actualizado',
                              'data', (ecommerce.fn_encabezado_obtener(v_id) -> 'data'));
END;
$function$;

DROP FUNCTION IF EXISTS ecommerce.fn_encabezado_modificar(jsonb, bigint, character varying, character varying, inet, text, uuid);

CREATE OR REPLACE FUNCTION ecommerce.fn_encabezado_logo(p_id bigint, p_archivo text, p_usuario_id bigint DEFAULT NULL::bigint, p_usuario_login character varying DEFAULT NULL::character varying, p_usuario_nombre character varying DEFAULT NULL::character varying, p_ip_address inet DEFAULT NULL::inet, p_user_agent text DEFAULT NULL::text, p_request_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'ecommerce', 'auditoria'
AS $function$
DECLARE
    v_id       bigint;
    v_anterior text;
BEGIN
    PERFORM ecommerce.fn_contexto_auditoria('ecommerce.encabezado',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    v_id := COALESCE(p_id, (SELECT id FROM ecommerce.encabezado WHERE principal));

    SELECT logo INTO v_anterior FROM ecommerce.encabezado WHERE id = v_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Ese encabezado no existe' USING ERRCODE = 'P0013';
    END IF;

    -- CADA ENCABEZADO TIENE SU LOGO: el de Navidad puede llevar el del gorro y
    -- el de siempre el de siempre. El fichero anterior lo borra el controlador,
    -- y por eso se devuelve.
    UPDATE ecommerce.encabezado
       SET logo = nullif(btrim(COALESCE(p_archivo, '')), '')
     WHERE id = v_id;

    RETURN jsonb_build_object(
        'success', true,
        'message', CASE WHEN p_archivo IS NULL THEN 'Logo quitado' ELSE 'Logo actualizado' END,
        'anterior', v_anterior,
        'data', (ecommerce.fn_encabezado_obtener(v_id) -> 'data'));
END;
$function$;

DROP FUNCTION IF EXISTS ecommerce.fn_encabezado_logo(text, bigint, character varying, character varying, inet, text, uuid);

-- ---------- 7. El menú: un solo menú, con fechas por enlace ----------
CREATE OR REPLACE FUNCTION ecommerce.fn_encabezado_enlaces_json()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
AS $function$
    WITH RECURSIVE arbol AS (
        SELECT e.id, e.padre_id, e.texto, e.enlace, e.icono, e.nueva_pestana,
               e.orden, e.activo, e.destacado, e.desde, e.hasta, 0 AS nivel,
               ARRAY[lpad(e.orden::text, 6, '0') || '-' || lpad(e.id::text, 12, '0')] AS camino
          FROM ecommerce.encabezado_enlaces e
         WHERE e.padre_id IS NULL AND e.deleted_at IS NULL
        UNION ALL
        SELECT h.id, h.padre_id, h.texto, h.enlace, h.icono, h.nueva_pestana,
               h.orden, h.activo, h.destacado, h.desde, h.hasta, a.nivel + 1,
               a.camino || (lpad(h.orden::text, 6, '0') || '-' || lpad(h.id::text, 12, '0'))
          FROM ecommerce.encabezado_enlaces h
          JOIN arbol a ON h.padre_id = a.id
         WHERE h.deleted_at IS NULL
    )
    -- El árbol completo, apagados incluidos: esto es la pantalla de
    -- administración, no la tienda. Lo de ocultar pasa en fn_secciones_publicas.
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'id',            a.id,
               'padre_id',      a.padre_id,
               -- El texto del padre, para decir de dónde cuelga sin tener que
               -- buscarlo en la pantalla
               'padre',         (SELECT p.texto FROM ecommerce.encabezado_enlaces p WHERE p.id = a.padre_id),
               'texto',         a.texto,
               'enlace',        a.enlace,
               'icono',         a.icono,
               'nueva_pestana', a.nueva_pestana,
               'orden',         a.orden,
               'activo',        a.activo,
               -- ENTRE QUÉ FECHAS SE VE, como en las secciones de la portada:
               -- un enlace de campaña se enciende y se apaga solo. Vacías, se
               -- ve siempre, que es como ha ido el menú hasta hoy
               'desde',         to_char(a.desde, 'YYYY-MM-DD"T"HH24:MI'),
               'hasta',         to_char(a.hasta, 'YYYY-MM-DD"T"HH24:MI'),
               -- Y en qué estado está, resuelto aquí: que la pantalla tenga que
               -- comparar fechas con el reloj del navegador es la manera de que
               -- diga «se ve» cuando el servidor cree que no
               'estado',        CASE
                   WHEN NOT a.activo THEN 'oculto'
                   WHEN a.desde IS NOT NULL AND CURRENT_TIMESTAMP < a.desde THEN 'programado'
                   WHEN a.hasta IS NOT NULL AND CURRENT_TIMESTAMP > a.hasta THEN 'terminado'
                   ELSE 'visible' END,
               -- Sólo los principales pueden ir destacados: dentro de un
               -- desplegable no hay barra donde poner una píldora
               'destacado',     a.destacado,
               'nivel',         a.nivel,
               -- CUÁNTOS CUELGAN DE ÉL, no quiénes: es lo que necesita la
               -- rejilla para pintar el +/- y para avisar al borrarlo
               'hijos',         (SELECT count(*) FROM ecommerce.encabezado_enlaces c
                                  WHERE c.padre_id = a.id AND c.deleted_at IS NULL))
           ORDER BY a.camino), '[]'::jsonb)
      FROM arbol a;
$function$;

DROP FUNCTION IF EXISTS ecommerce.fn_encabezado_enlaces_guardar(bigint, bigint, character varying, character varying, character varying, boolean, boolean, boolean, bigint, character varying, character varying, inet, text, uuid);

CREATE OR REPLACE FUNCTION ecommerce.fn_encabezado_enlaces_guardar(p_id bigint, p_padre_id bigint, p_texto character varying, p_enlace character varying, p_icono character varying, p_activo boolean, p_nueva_pestana boolean, p_destacado boolean, p_desde timestamp with time zone, p_hasta timestamp with time zone, p_usuario_id bigint DEFAULT NULL::bigint, p_usuario_login character varying DEFAULT NULL::character varying, p_usuario_nombre character varying DEFAULT NULL::character varying, p_ip_address inet DEFAULT NULL::inet, p_user_agent text DEFAULT NULL::text, p_request_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'ecommerce', 'auditoria'
AS $function$
DECLARE
    v_id     bigint := p_id;
    v_texto  text;
    v_enlace text;
    v_icono  text;
    v_padre  bigint := p_padre_id;
    v_nuevo  boolean := p_id IS NULL;
    v_destacado boolean;
BEGIN
    PERFORM ecommerce.fn_contexto_auditoria('ecommerce.encabezado_enlaces',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    v_texto  := ecommerce.fn_validar_texto(p_texto, 'El texto del enlace', 60, true);
    v_enlace := ecommerce.fn_validar_enlace(p_enlace, 'El enlace');
    v_icono  := ecommerce.fn_validar_texto(p_icono, 'El icono', 40);

    IF v_icono IS NOT NULL AND v_icono !~ '^[a-z0-9-]+$' THEN
        RAISE EXCEPTION 'El icono sólo admite letras minúsculas, números y guiones' USING ERRCODE = 'P0015';
    END IF;

    IF NOT v_nuevo THEN
        -- El padre no se cambia al modificar: mover un enlace de sitio es
        -- arrastrarlo, y mezclarlo aquí dejaría dos caminos para lo mismo.
        SELECT padre_id INTO v_padre FROM ecommerce.encabezado_enlaces
         WHERE id = p_id AND deleted_at IS NULL;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'El enlace no existe' USING ERRCODE = 'P0013';
        END IF;
    END IF;

    -- LAS FECHAS, AL DERECHO: con «hasta» antes que «desde» el enlace no se
    -- vería nunca, y nadie entendería por qué
    IF p_desde IS NOT NULL AND p_hasta IS NOT NULL AND p_hasta < p_desde THEN
        RAISE EXCEPTION 'Las fechas van al revés: «hasta» es anterior a «desde»' USING ERRCODE = 'P0015';
    END IF;

    -- DESTACADO ES SÓLO DE LOS PRINCIPALES: es una píldora al final de la
    -- barra roja, y dentro de un desplegable no hay barra donde ponerla.
    v_destacado := COALESCE(p_destacado, false) AND v_padre IS NULL;

    -- EL ÁRBOL YA NO TIENE DOS NIVELES: un enlace puede colgar de cualquier
    -- otro, al fondo que haga falta. Lo único que se mira es que el padre
    -- exista; que no se meta dentro de sí mismo lo mira `mover`, que es por
    -- donde se cambia de padre.
    IF v_padre IS NOT NULL THEN
        IF NOT EXISTS (SELECT 1 FROM ecommerce.encabezado_enlaces
                        WHERE id = v_padre AND deleted_at IS NULL) THEN
            RAISE EXCEPTION 'El enlace del que debería colgar no existe' USING ERRCODE = 'P0016';
        END IF;
    END IF;

    -- LA DIRECCIÓN ES OPCIONAL EN TODOS LOS NIVELES, y antes sólo lo era en
    -- los principales. Con el árbol sin límite hace falta: «MARCAS → Motos →
    -- Honda» se arma de arriba abajo, y «Motos» nace sin hijos todavía, así
    -- que exigirle dirección era impedir construirlo. Un enlace sin hijos y
    -- sin dirección no se enseña en la tienda, y la rejilla del CRM lo dice
    -- en su fila.

    IF v_nuevo THEN
        INSERT INTO ecommerce.encabezado_enlaces
               (padre_id, texto, enlace, icono, activo, nueva_pestana, destacado, desde, hasta, orden)
        VALUES (v_padre, v_texto, v_enlace, v_icono,
                COALESCE(p_activo, true),
                ecommerce.fn_nueva_pestana(v_enlace, p_nueva_pestana),
                v_destacado, p_desde, p_hasta,
                (SELECT COALESCE(max(orden), 0) + 1 FROM ecommerce.encabezado_enlaces
                  WHERE padre_id IS NOT DISTINCT FROM v_padre AND deleted_at IS NULL))
        RETURNING id INTO v_id;
    ELSE
        UPDATE ecommerce.encabezado_enlaces
           SET texto = v_texto, enlace = v_enlace, icono = v_icono,
               activo = COALESCE(p_activo, true),
               nueva_pestana = ecommerce.fn_nueva_pestana(v_enlace, p_nueva_pestana),
               destacado = v_destacado,
               desde = p_desde, hasta = p_hasta
         WHERE id = v_id;
    END IF;

    RETURN jsonb_build_object('success', true,
        'message', CASE WHEN v_nuevo THEN 'Enlace creado' ELSE 'Enlace actualizado' END,
        -- SÓLO EL MENÚ, que es lo único que cambia aquí: el menú es uno solo
        -- y los encabezados son varios, así que devolver «el encabezado» le
        -- repintaría a quien edita el de Navidad los colores de otro
        'data', jsonb_build_object('enlaces', ecommerce.fn_encabezado_enlaces_json()));
END;
$function$;

CREATE OR REPLACE FUNCTION ecommerce.fn_encabezado_menu_publico(p_padre bigint DEFAULT NULL::bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'ecommerce'
AS $function$
DECLARE
    v_salida jsonb := '[]'::jsonb;
    v_hijos  jsonb;
    v_fila   record;
BEGIN
    FOR v_fila IN
        SELECT e.id, e.texto, e.enlace, e.icono, e.nueva_pestana, e.destacado
          FROM ecommerce.encabezado_enlaces e
         WHERE e.padre_id IS NOT DISTINCT FROM p_padre
           AND e.activo AND e.deleted_at IS NULL
           -- Y DENTRO DE SUS FECHAS: un enlace de campaña se apaga solo. Sin
           -- fechas, fn_vigente dice que sí siempre
           AND ecommerce.fn_vigente(e.desde, e.hasta)
         ORDER BY e.orden, e.id
    LOOP
        v_hijos := ecommerce.fn_encabezado_menu_publico(v_fila.id);

        IF v_hijos <> '[]'::jsonb THEN
            v_salida := v_salida || jsonb_build_object(
                'texto',         v_fila.texto,
                'enlace',        NULL,
                'icono',         v_fila.icono,
                'nueva_pestana', false,
                'destacado',     false,
                'hijos',         v_hijos);

        ELSIF v_fila.enlace IS NOT NULL
              AND ecommerce.fn_enlace_a_pagina_visible(v_fila.enlace) THEN
            v_salida := v_salida || jsonb_build_object(
                'texto',         v_fila.texto,
                'enlace',        v_fila.enlace,
                'icono',         v_fila.icono,
                'nueva_pestana', v_fila.nueva_pestana,
                'destacado',     v_fila.destacado AND p_padre IS NULL,
                'hijos',         '[]'::jsonb);
        END IF;
    END LOOP;

    RETURN v_salida;
END;
$function$;

CREATE OR REPLACE FUNCTION ecommerce.fn_encabezado_enlaces_activar(p_id bigint, p_activo boolean DEFAULT NULL::boolean, p_usuario_id bigint DEFAULT NULL::bigint, p_usuario_login character varying DEFAULT NULL::character varying, p_usuario_nombre character varying DEFAULT NULL::character varying, p_ip_address inet DEFAULT NULL::inet, p_user_agent text DEFAULT NULL::text, p_request_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'ecommerce', 'auditoria'
AS $function$
DECLARE
    v_actual boolean;
    v_texto  text;
    v_nuevo  boolean;
BEGIN
    PERFORM ecommerce.fn_contexto_auditoria('ecommerce.encabezado_enlaces',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    SELECT activo, texto INTO v_actual, v_texto
      FROM ecommerce.encabezado_enlaces WHERE id = p_id AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'El enlace no existe' USING ERRCODE = 'P0013';
    END IF;

    v_nuevo := COALESCE(p_activo, NOT v_actual);
    UPDATE ecommerce.encabezado_enlaces SET activo = v_nuevo WHERE id = p_id;

    RETURN jsonb_build_object('success', true,
        'message', format('«%s» %s', v_texto, CASE WHEN v_nuevo THEN 'se ve en el menú' ELSE 'oculto en el menú' END),
        'data', jsonb_build_object('enlaces', ecommerce.fn_encabezado_enlaces_json()));
END;
$function$;

CREATE OR REPLACE FUNCTION ecommerce.fn_encabezado_enlaces_eliminar(p_id bigint, p_usuario_id bigint DEFAULT NULL::bigint, p_usuario_login character varying DEFAULT NULL::character varying, p_usuario_nombre character varying DEFAULT NULL::character varying, p_ip_address inet DEFAULT NULL::inet, p_user_agent text DEFAULT NULL::text, p_request_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'ecommerce', 'auditoria'
AS $function$
DECLARE
    v_texto text;
    v_fecha timestamptz := CURRENT_TIMESTAMP;
    v_hijos integer;
BEGIN
    PERFORM ecommerce.fn_contexto_auditoria('ecommerce.encabezado_enlaces',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    SELECT texto INTO v_texto FROM ecommerce.encabezado_enlaces
     WHERE id = p_id AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'El enlace no existe' USING ERRCODE = 'P0013';
    END IF;

    -- LA RAMA ENTERA se va con él, a cualquier profundidad: dejar a los
    -- nietos colgando de un padre que ya no está los haría invisibles sin
    -- estar borrados. Antes sólo se llevaba a los hijos directos porque el
    -- árbol era de dos niveles y no había nietos.
    WITH RECURSIVE rama AS (
        SELECT id FROM ecommerce.encabezado_enlaces
         WHERE padre_id = p_id AND deleted_at IS NULL
        UNION ALL
        SELECT h.id FROM ecommerce.encabezado_enlaces h
          JOIN rama r ON h.padre_id = r.id
         WHERE h.deleted_at IS NULL
    )
    UPDATE ecommerce.encabezado_enlaces e
       SET deleted_at = v_fecha, deleted_by = p_usuario_login
      FROM rama
     WHERE e.id = rama.id;
    GET DIAGNOSTICS v_hijos = ROW_COUNT;

    UPDATE ecommerce.encabezado_enlaces
       SET deleted_at = v_fecha, deleted_by = p_usuario_login WHERE id = p_id;

    RETURN jsonb_build_object('success', true,
        'message', CASE v_hijos
                       WHEN 0 THEN format('«%s» va a la papelera', v_texto)
                       WHEN 1 THEN format('«%s» va a la papelera con el enlace que colgaba de él', v_texto)
                       ELSE format('«%s» va a la papelera con los %s enlaces que colgaban de él', v_texto, v_hijos) END,
        'data', jsonb_build_object('enlaces', ecommerce.fn_encabezado_enlaces_json()));
END;
$function$;

CREATE OR REPLACE FUNCTION ecommerce.fn_encabezado_enlaces_ordenar(p_ids jsonb, p_usuario_id bigint DEFAULT NULL::bigint, p_usuario_login character varying DEFAULT NULL::character varying, p_usuario_nombre character varying DEFAULT NULL::character varying, p_ip_address inet DEFAULT NULL::inet, p_user_agent text DEFAULT NULL::text, p_request_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'ecommerce', 'auditoria'
AS $function$
DECLARE
    v integer;
BEGIN
    PERFORM ecommerce.fn_contexto_auditoria('ecommerce.encabezado_enlaces',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    IF jsonb_typeof(p_ids) <> 'array' THEN
        RAISE EXCEPTION 'Se esperaba la lista de enlaces en el orden nuevo' USING ERRCODE = 'P0015';
    END IF;

    UPDATE ecommerce.encabezado_enlaces e
       SET orden = t.posicion
      FROM (SELECT valor::bigint AS id, ordinalidad::integer AS posicion
              FROM jsonb_array_elements_text(p_ids) WITH ORDINALITY AS x(valor, ordinalidad)) t
     WHERE e.id = t.id AND e.deleted_at IS NULL;
    GET DIAGNOSTICS v = ROW_COUNT;

    RETURN jsonb_build_object('success', true,
        'message', CASE v WHEN 1 THEN 'Enlace movido' ELSE format('%s enlaces reordenados', v) END,
        'data', jsonb_build_object('enlaces', ecommerce.fn_encabezado_enlaces_json()));
END;
$function$;

CREATE OR REPLACE FUNCTION ecommerce.fn_encabezado_enlaces_mover(p_id bigint, p_padre_id bigint DEFAULT NULL::bigint, p_antes_de bigint DEFAULT NULL::bigint, p_usuario_id bigint DEFAULT NULL::bigint, p_usuario_login character varying DEFAULT NULL::character varying, p_usuario_nombre character varying DEFAULT NULL::character varying, p_ip_address inet DEFAULT NULL::inet, p_user_agent text DEFAULT NULL::text, p_request_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'ecommerce', 'auditoria'
AS $function$
DECLARE
    v_padre_actual bigint;
    v_texto        text;
    v_pos          integer;
    v_i            integer := 0;
    v_fila         record;
BEGIN
    PERFORM ecommerce.fn_contexto_auditoria('ecommerce.encabezado_enlaces',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    SELECT padre_id, texto INTO v_padre_actual, v_texto
      FROM ecommerce.encabezado_enlaces WHERE id = p_id AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'El enlace no existe' USING ERRCODE = 'P0013';
    END IF;

    IF p_padre_id IS NOT NULL THEN
        IF p_padre_id = p_id THEN
            RAISE EXCEPTION 'Un enlace no puede colgar de sí mismo' USING ERRCODE = 'P0015';
        END IF;
        IF NOT EXISTS (SELECT 1 FROM ecommerce.encabezado_enlaces
                        WHERE id = p_padre_id AND deleted_at IS NULL) THEN
            RAISE EXCEPTION 'El enlace del que debería colgar no existe' USING ERRCODE = 'P0016';
        END IF;
        -- EL DESTINO NO PUEDE COLGAR DEL QUE SE MUEVE: sería una rama suelta,
        -- fuera del menú y sin manera de volver a sacarla
        IF EXISTS (
            WITH RECURSIVE rama AS (
                SELECT id FROM ecommerce.encabezado_enlaces
                 WHERE padre_id = p_id AND deleted_at IS NULL
                UNION ALL
                SELECT h.id FROM ecommerce.encabezado_enlaces h
                  JOIN rama r ON h.padre_id = r.id
                 WHERE h.deleted_at IS NULL
            )
            SELECT 1 FROM rama WHERE rama.id = p_padre_id
        ) THEN
            RAISE EXCEPTION 'No se puede meter «%» dentro de algo que cuelga de él', v_texto
                  USING ERRCODE = 'P0015';
        END IF;
    END IF;

    -- Dentro de un desplegable no hay barra donde poner la píldora: lo que
    -- deja de ser principal deja de estar destacado
    UPDATE ecommerce.encabezado_enlaces
       SET padre_id = p_padre_id,
           destacado = destacado AND p_padre_id IS NULL
     WHERE id = p_id;

    -- Los hermanos de donde cae: se le hace sitio delante de `p_antes_de` y se
    -- renumeran todos del 1 al N, sin huecos
    CREATE TEMP TABLE IF NOT EXISTS tmp_hermanos_enc (id bigint, pos integer) ON COMMIT DROP;
    DELETE FROM tmp_hermanos_enc;

    INSERT INTO tmp_hermanos_enc (id, pos)
    SELECT id, row_number() OVER (ORDER BY orden, id)
      FROM ecommerce.encabezado_enlaces
     WHERE padre_id IS NOT DISTINCT FROM p_padre_id
       AND deleted_at IS NULL AND id <> p_id;

    IF p_antes_de IS NOT NULL AND p_antes_de <> p_id THEN
        SELECT pos INTO v_pos FROM tmp_hermanos_enc WHERE id = p_antes_de;
    END IF;
    IF v_pos IS NULL THEN
        SELECT COALESCE(max(pos), 0) + 1 INTO v_pos FROM tmp_hermanos_enc;
    END IF;

    UPDATE tmp_hermanos_enc SET pos = pos + 1 WHERE pos >= v_pos;
    INSERT INTO tmp_hermanos_enc (id, pos) VALUES (p_id, v_pos);

    FOR v_fila IN SELECT id FROM tmp_hermanos_enc ORDER BY pos LOOP
        v_i := v_i + 1;
        UPDATE ecommerce.encabezado_enlaces SET orden = v_i
         WHERE id = v_fila.id AND orden IS DISTINCT FROM v_i;
    END LOOP;

    -- Y los que deja atrás, también sin huecos
    IF v_padre_actual IS DISTINCT FROM p_padre_id THEN
        v_i := 0;
        FOR v_fila IN
            SELECT id FROM ecommerce.encabezado_enlaces
             WHERE padre_id IS NOT DISTINCT FROM v_padre_actual AND deleted_at IS NULL
             ORDER BY orden, id
        LOOP
            v_i := v_i + 1;
            UPDATE ecommerce.encabezado_enlaces SET orden = v_i
             WHERE id = v_fila.id AND orden IS DISTINCT FROM v_i;
        END LOOP;
    END IF;

    RETURN jsonb_build_object('success', true,
        'message', CASE WHEN v_padre_actual IS DISTINCT FROM p_padre_id
                        THEN format('«%s» movido', v_texto)
                        ELSE format('«%s» cambió de sitio', v_texto) END,
        'data', jsonb_build_object('enlaces', ecommerce.fn_encabezado_enlaces_json()));
END;
$function$;

CREATE OR REPLACE FUNCTION ecommerce.fn_encabezado_enlaces_restaurar(p_ids jsonb, p_usuario_id bigint DEFAULT NULL::bigint, p_usuario_login character varying DEFAULT NULL::character varying, p_usuario_nombre character varying DEFAULT NULL::character varying, p_ip_address inet DEFAULT NULL::inet, p_user_agent text DEFAULT NULL::text, p_request_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'ecommerce', 'auditoria'
AS $function$
DECLARE
    v integer;
BEGIN
    PERFORM ecommerce.fn_contexto_auditoria('ecommerce.encabezado_enlaces',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    IF jsonb_typeof(p_ids) <> 'array' OR jsonb_array_length(p_ids) = 0 THEN
        RAISE EXCEPTION 'No se indicó qué restaurar' USING ERRCODE = 'P0015';
    END IF;

    -- Un desplegable cuyo principal sigue en la papelera vuelve como
    -- PRINCIPAL: restaurarlo bajo un padre que no se ve sería restaurarlo a
    -- ninguna parte. Y si no tiene dirección propia, no se puede: se dice.
    UPDATE ecommerce.encabezado_enlaces h
       SET deleted_at = NULL, deleted_by = NULL,
           padre_id = CASE WHEN EXISTS (SELECT 1 FROM ecommerce.encabezado_enlaces p
                                         WHERE p.id = h.padre_id AND p.deleted_at IS NULL)
                           THEN h.padre_id END
     WHERE h.deleted_at IS NOT NULL
       AND h.id IN (SELECT valor::bigint FROM jsonb_array_elements_text(p_ids) AS x(valor));
    GET DIAGNOSTICS v = ROW_COUNT;

    IF v = 0 THEN
        RAISE EXCEPTION 'Ninguno de esos enlaces está en la papelera' USING ERRCODE = 'P0019';
    END IF;

    RETURN jsonb_build_object('success', true,
        'message', CASE v WHEN 1 THEN 'Enlace restaurado' ELSE format('%s enlaces restaurados', v) END,
        'data', jsonb_build_object('enlaces', ecommerce.fn_encabezado_enlaces_json()));
END;
$function$;

-- ---------- 8. Y la tienda pide el que toque hoy ----------
CREATE OR REPLACE FUNCTION ecommerce.fn_secciones_publicas()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
AS $function$
    -- Una columna del pie, montada una sola vez y usada por las dos franjas
    WITH columnas AS (
        SELECT c.zona, c.orden, c.id,
               jsonb_build_object(
                   'titulo', c.titulo,
                   'imagen', CASE WHEN nullif(btrim(COALESCE(c.imagen, '')), '') IS NOT NULL
                                  THEN jsonb_build_object(
                                      'archivo',       c.imagen,
                                      'alt',           c.imagen_alt,
                                      'enlace',        c.imagen_enlace,
                                      'nueva_pestana', c.imagen_nueva_pestana)
                             END,
                   'items', COALESCE((
                       SELECT jsonb_agg(jsonb_build_object(
                                  'texto', l.texto, 'enlace', l.enlace,
                                  'icono', l.icono, 'nueva_pestana', l.nueva_pestana)
                              ORDER BY l.orden, l.id)
                         FROM ecommerce.pie_enlaces l
                        WHERE l.columna_id = c.id AND l.activo AND l.deleted_at IS NULL
                          AND ecommerce.fn_enlace_a_pagina_visible(l.enlace)), '[]'::jsonb)) AS grupo
          FROM ecommerce.pie_columnas c
         WHERE c.activo AND c.deleted_at IS NULL
    )
    SELECT jsonb_build_array(
        jsonb_build_object(
            'clave', 'header', 'tipo', 'header', 'ubicacion', 'arriba', 'orden', 1, 'titulo', 'Header',
            -- EL ENCABEZADO QUE TOQUE HOY, no el único que había: manda el
            -- que esté en fecha y, si no hay ninguno de campaña, el
            -- predeterminado. Lo decide fn_encabezado_vigente_id
            'config', (SELECT config FROM ecommerce.encabezado WHERE id = ecommerce.fn_encabezado_vigente_id()),
            -- El logo que se subió en el CRM; sin él, la tienda pinta el suyo
            'logo', (SELECT logo FROM ecommerce.encabezado WHERE id = ecommerce.fn_encabezado_vigente_id()),
            -- EL MENÚ ENTERO, con los niveles que tenga: lo arma una función
            -- que se llama a sí misma, porque aquí ya no se sabe cuántos hay
            'menu', ecommerce.fn_encabezado_menu_publico(NULL),
            'grupos', '[]'::jsonb),
        jsonb_build_object(
            'clave', 'footer', 'tipo', 'footer', 'ubicacion', 'abajo', 'orden', 1, 'titulo', 'Footer',
            'config', jsonb_build_object(
                'titulo_redes', (SELECT config ->> 'titulo_redes' FROM ecommerce.pie WHERE id = 1),
                'titulo_redes_estilo', (SELECT COALESCE(config -> 'titulo_redes_estilo', '{}'::jsonb)
                                          FROM ecommerce.pie WHERE id = 1),
                -- Los derechos reservados, de la configuración del pie
                'barra_inferior', (SELECT COALESCE(config -> 'barra_inferior', '{}'::jsonb)
                                     FROM ecommerce.pie WHERE id = 1),
                'redes', COALESCE((
                    SELECT jsonb_agg(jsonb_build_object(
                               'icono',  r ->> 'icono',
                               'nombre', r ->> 'nombre',
                               'enlace', r ->> 'enlace'))
                      FROM ecommerce.pie p, jsonb_array_elements(COALESCE(p.config -> 'redes', '[]'::jsonb)) r
                     WHERE p.id = 1 AND (r -> 'activo') = 'true'::jsonb), '[]'::jsonb)),
            'menu', '[]'::jsonb,
            'grupos', COALESCE((SELECT jsonb_agg(c.grupo ORDER BY c.orden, c.id)
                                  FROM columnas c WHERE c.zona = 'arriba'), '[]'::jsonb),
            'grupos_abajo', COALESCE((SELECT jsonb_agg(c.grupo ORDER BY c.orden, c.id)
                                        FROM columnas c WHERE c.zona = 'abajo'), '[]'::jsonb))
    );
$function$;

COMMIT;


-- ============================================================================
-- COMPROBACIÓN — no escribe nada
-- ============================================================================
DO $comprobar$
DECLARE
    v_falta   text[] := '{}';
    v_principal bigint;
    v_campana bigint;
    v_enlace  bigint;
    v_json    jsonb;
    v_texto   text;
BEGIN
    SELECT id INTO v_principal FROM ecommerce.encabezado WHERE principal;
    IF v_principal IS NULL THEN
        v_falta := array_append(v_falta, 'no hay predeterminado');
    END IF;

    -- Las columnas nuevas
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                    WHERE table_schema = 'ecommerce' AND table_name = 'encabezado'
                      AND column_name = 'principal') THEN
        v_falta := array_append(v_falta, 'no están las columnas del encabezado');
    END IF;
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                    WHERE table_schema = 'ecommerce' AND table_name = 'encabezado_enlaces'
                      AND column_name = 'hasta') THEN
        v_falta := array_append(v_falta, 'no están las fechas de los enlaces');
    END IF;

    -- Sin campañas, manda el predeterminado
    IF ecommerce.fn_encabezado_vigente_id() IS DISTINCT FROM v_principal
       AND NOT EXISTS (SELECT 1 FROM ecommerce.encabezado
                        WHERE activo AND (desde IS NOT NULL OR hasta IS NOT NULL)
                          AND ecommerce.fn_vigente(desde, hasta)) THEN
        v_falta := array_append(v_falta, 'sin campañas no manda el predeterminado');
    END IF;

    -- Se prueba de verdad y se deshace: una campaña que empieza hoy tiene que
    -- ganarle al predeterminado, y al borrarla tiene que volver él
    BEGIN
        v_json := ecommerce.fn_encabezados_crear('ZZ prueba de campaña');
        v_campana := (v_json ->> 'id')::bigint;

        IF (v_json -> 'data' ->> 'principal')::boolean THEN
            v_falta := array_append(v_falta, 'el nuevo nació de predeterminado');
        END IF;
        IF (v_json -> 'data' ->> 'config') IS NULL THEN
            v_falta := array_append(v_falta, 'el nuevo nació sin copiar la pinta');
        END IF;

        PERFORM ecommerce.fn_encabezados_guardar(v_campana, jsonb_build_object(
            'nombre', 'ZZ prueba de campaña',
            'desde', to_char(CURRENT_TIMESTAMP - interval '1 hour', 'YYYY-MM-DD"T"HH24:MI'),
            'hasta', to_char(CURRENT_TIMESTAMP + interval '1 hour', 'YYYY-MM-DD"T"HH24:MI'),
            'activo', true));

        IF ecommerce.fn_encabezado_vigente_id() IS DISTINCT FROM v_campana THEN
            v_falta := array_append(v_falta, 'la campaña en fecha no le gana al predeterminado');
        END IF;

        -- Y la tienda recibe la suya
        SELECT s -> 'config' INTO v_json
          FROM jsonb_array_elements(ecommerce.fn_secciones_publicas()) s
         WHERE s ->> 'clave' = 'header';
        IF v_json IS NULL THEN
            v_falta := array_append(v_falta, 'la tienda no recibe el config del encabezado');
        END IF;

        -- El predeterminado no se apaga ni se borra
        BEGIN
            PERFORM ecommerce.fn_encabezados_activar(v_principal, false);
            v_falta := array_append(v_falta, 'se dejó apagar el predeterminado');
        EXCEPTION WHEN sqlstate 'P0016' THEN NULL;
        END;
        BEGIN
            PERFORM ecommerce.fn_encabezados_eliminar(v_principal);
            v_falta := array_append(v_falta, 'se dejó borrar el predeterminado');
        EXCEPTION WHEN sqlstate 'P0016' THEN NULL;
        END;

        -- Un enlace con fechas pasadas no sale en el menú
        v_json := ecommerce.fn_encabezado_enlaces_guardar(NULL, NULL, 'ZZ enlace de prueba', '/motos',
                      NULL, true, false, false,
                      CURRENT_TIMESTAMP - interval '2 days', CURRENT_TIMESTAMP - interval '1 day');
        SELECT (e ->> 'id')::bigint INTO v_enlace
          FROM jsonb_array_elements(v_json -> 'data' -> 'enlaces') e
         WHERE e ->> 'texto' = 'ZZ enlace de prueba';

        IF v_enlace IS NULL THEN
            v_falta := array_append(v_falta, 'no se pudo crear el enlace de prueba');
        ELSE
            SELECT e ->> 'estado' INTO v_texto
              FROM jsonb_array_elements(ecommerce.fn_encabezado_enlaces_json()) e
             WHERE (e ->> 'id')::bigint = v_enlace;
            IF v_texto IS DISTINCT FROM 'terminado' THEN
                v_falta := array_append(v_falta, 'el enlace fuera de fecha dice «' || COALESCE(v_texto, 'NULL') || '»');
            END IF;

            IF ecommerce.fn_encabezado_menu_publico(NULL)::text LIKE '%ZZ enlace de prueba%' THEN
                v_falta := array_append(v_falta, 'el enlace fuera de fecha sale en el menú de la tienda');
            END IF;
        END IF;

        RAISE EXCEPTION 'deshacer la prueba';
    EXCEPTION WHEN others THEN
        IF SQLERRM <> 'deshacer la prueba' THEN
            v_falta := array_append(v_falta, 'probando: ' || SQLERRM);
        END IF;
    END;

    IF array_length(v_falta, 1) > 0 THEN
        RAISE EXCEPTION 'Los encabezados programables no quedaron bien: %', array_to_string(v_falta, '; ');
    END IF;

    RAISE NOTICE 'Los encabezados ya se programan, y cada enlace del menú tiene sus fechas';
END;
$comprobar$;
