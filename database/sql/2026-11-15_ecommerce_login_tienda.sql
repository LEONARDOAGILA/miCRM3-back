-- ============================================================================
-- LAS CUENTAS DE LA TIENDA
-- ============================================================================
-- Los clientes de la web entran con su CORREO y viven en `seguridad.users`
-- con `type_user = 4` («Usuario de la página web», que ya existía sin usarse).
--
-- MISMA TABLA, OTRA PUERTA. La tabla, porque es donde ya está todo lo que un
-- login necesita y no conviene tener dos veces: el hash de la contraseña, la
-- verificación del correo, el código de recuperación, la papelera, la
-- auditoría y las pantallas del CRM para ver y desactivar gente.
--
-- La puerta aparte, porque el `/login` del CRM hace cuatro cosas que con un
-- cliente salen mal:
--
--   · el middleware de horario devuelve 401 fuera de hora —un cliente no
--     podría entrar a su cuenta un domingo—;
--   · hay un tope de 44 sesiones simultáneas por usuario;
--   · la respuesta lleva los `accesos` del CRM, que no le sirven a la tienda
--     y le cuentan a cualquiera cómo está armado por dentro;
--   · y, sobre todo, ese token sería un JWT válido del CRM: las rutas de
--     administración se protegen con `jwt.auth`, que no mira de qué tipo es
--     el usuario.
--
-- Así que aquí están las funciones de la tienda —registrarse, entrar,
-- verificar el correo y recuperar la contraseña—, y el controlador emite un
-- token con su propio ámbito.
--
-- ----------------------------------------------------------------------------
-- LA FICHA DE CLIENTE SE CREA AL REGISTRARSE
-- ----------------------------------------------------------------------------
-- `ventas.clientes.numero_identificacion` es OBLIGATORIO y ÚNICO, así que el
-- registro pide cédula o RUC. Y como ya hay más de mil clientes cargados,
-- alguien se va a registrar con una identificación que ya está:
--
--   · si el correo de esa ficha ES el mismo que escribe, se enlaza a ella;
--   · si no, NO se crea nada y se le dice que se acerque o escriba.
--
-- Lo segundo no es burocracia: esa ficha lleva crédito, descuento y mañana
-- el historial de compras, y cualquiera puede teclear una cédula ajena.
--
-- ----------------------------------------------------------------------------
-- LAS CONTRASEÑAS NO SE TOCAN AQUÍ
-- ----------------------------------------------------------------------------
-- El hash lo hace PHP (`password_hash`), como en el resto del CRM, y llega
-- hecho. Estas funciones guardan y devuelven el hash, nunca lo calculan ni lo
-- comparan: el día que se cambie el algoritmo, se cambia en un sitio.
--
-- ----------------------------------------------------------------------------
-- SE EJECUTA A MANO. Para ensayar sin guardar, cambiar el COMMIT del final por
-- ROLLBACK; la comprobación crea una cuenta de prueba y la deshace.
-- ============================================================================

BEGIN;

-- ---------- 1. Lo que le falta a la tabla de usuarios ----------

-- A qué cliente corresponde. Nulo en el personal de la empresa; en una cuenta
-- de la tienda se llena al registrarse
ALTER TABLE seguridad.users
    ADD COLUMN IF NOT EXISTS cliente_id bigint NULL REFERENCES ventas.clientes(id);

COMMENT ON COLUMN seguridad.users.cliente_id IS
    'La ficha de ventas.clientes de este usuario. Sólo las cuentas de la tienda (type_user = 4) la tienen.';

-- El código para verificar el correo. APARTE de `recovery_code`, que es el de
-- la contraseña: con uno solo, pedir la contraseña invalidaría la
-- verificación y al revés
ALTER TABLE seguridad.users
    ADD COLUMN IF NOT EXISTS verify_code character varying(10) NULL;
ALTER TABLE seguridad.users
    ADD COLUMN IF NOT EXISTS verify_expires_at timestamp with time zone NULL;

CREATE INDEX IF NOT EXISTS ix_users_cliente ON seguridad.users (cliente_id)
    WHERE cliente_id IS NOT NULL;

-- UN CORREO, UNA CUENTA DE TIENDA. Sólo entre las cuentas de la web: un
-- empleado y un cliente pueden tener el mismo correo —son dos puertas
-- distintas—, pero dos clientes no, porque el correo es con lo que se entra.
CREATE UNIQUE INDEX IF NOT EXISTS uk_users_email_web
    ON seguridad.users (lower(email))
    WHERE type_user = 4 AND deleted_at IS NULL;

-- ---------- 2. El perfil y el horario que la tabla exige ----------
--
-- `perfil_id` y `chorario_id` son NOT NULL porque la tabla se hizo para el
-- personal. Un cliente necesita los dos, así que se le dan los suyos:
--
--   · un perfil SIN UN SOLO ACCESO: si un token de tienda llegara a una ruta
--     del CRM que mira accesos, no hay nada que ejecutar;
--   · y un horario SIEMPRE ABIERTO, que es lo que tiene una tienda en línea.
--
-- El horario se monta con una franja por día de 00:00:00 a 23:59:59.999999,
-- que es el día entero: `ck_dhorarios_horas` no admite que la hora de fin sea
-- igual a la de inicio, y los horarios que ya había usan 23:59, que deja un
-- minuto muerto cada noche. Como la columna guarda microsegundos, así no
-- queda ni un instante fuera.
INSERT INTO seguridad.perfiles (nombre, activo, created_by, updated_by)
SELECT 'Tienda en línea', true, 'sistema', 'sistema'
 WHERE NOT EXISTS (SELECT 1 FROM seguridad.perfiles WHERE nombre = 'Tienda en línea');

INSERT INTO seguridad.chorarios (nombre, descripcion, activo, created_by, updated_by)
SELECT 'Tienda en línea (24/7)', 'Las cuentas de la página web entran a cualquier hora', true, 'sistema', 'sistema'
 WHERE NOT EXISTS (SELECT 1 FROM seguridad.chorarios WHERE nombre = 'Tienda en línea (24/7)');

INSERT INTO seguridad.dhorarios (chorario_id, dia, jornada, hora_inicio, hora_fin, activo, created_by, updated_by)
SELECT c.id, d.dia, 1, '00:00:00'::time, '23:59:59.999999'::time, true, 'sistema', 'sistema'
  FROM seguridad.chorarios c
  CROSS JOIN generate_series(1, 7) AS d(dia)
 WHERE c.nombre = 'Tienda en línea (24/7)'
   AND NOT EXISTS (SELECT 1 FROM seguridad.dhorarios x
                    WHERE x.chorario_id = c.id AND x.dia = d.dia AND x.jornada = 1);

-- ---------- 3. El nombre de usuario que nadie escribe ----------
--
-- `login_user` es NOT NULL y de 30 caracteres, y un correo no cabe. Las
-- cuentas de la tienda entran por correo, así que éste se genera y no se
-- enseña en ninguna parte: «web-000123».
CREATE SEQUENCE IF NOT EXISTS ecommerce.seq_login_tienda START 1;

-- ---------- 4. El perfil y el horario, por su nombre ----------
CREATE OR REPLACE FUNCTION ecommerce.fn_tienda_perfil_id()
RETURNS bigint
LANGUAGE sql
STABLE
SECURITY DEFINER
AS $function$
    SELECT id FROM seguridad.perfiles
     WHERE nombre = 'Tienda en línea' AND deleted_at IS NULL
     ORDER BY id LIMIT 1;
$function$;

CREATE OR REPLACE FUNCTION ecommerce.fn_tienda_horario_id()
RETURNS bigint
LANGUAGE sql
STABLE
SECURITY DEFINER
AS $function$
    SELECT id FROM seguridad.chorarios
     WHERE nombre = 'Tienda en línea (24/7)' AND deleted_at IS NULL
     ORDER BY id LIMIT 1;
$function$;

-- ---------- 5. Lo que la tienda sabe de una cuenta ----------
--
-- NUNCA EL HASH: esto es lo que acaba viajando al navegador. El hash sale
-- sólo por `fn_tienda_credenciales`, que la usa el controlador para comparar.
CREATE OR REPLACE FUNCTION ecommerce.fn_tienda_yo(p_usuario_id bigint)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
AS $function$
    SELECT jsonb_build_object(
               'id',          u.id,
               'nombres',     u.name,
               'apellidos',   u.surname,
               'full_name',   btrim(u.name || ' ' || u.surname),
               'email',       u.email,
               'telefono',    u.phone,
               -- Con el correo sin verificar se puede entrar y mirar, pero no
               -- terminar un pedido. La tienda lo enseña como un aviso
               'verificado',  u.email_verified_at IS NOT NULL,
               'cliente_id',  u.cliente_id,
               'identificacion', c.numero_identificacion,
               'direccion',   c.direccion)
      FROM seguridad.users u
      LEFT JOIN ventas.clientes c ON c.id = u.cliente_id
     WHERE u.id = p_usuario_id AND u.type_user = 4 AND u.deleted_at IS NULL;
$function$;

COMMENT ON FUNCTION ecommerce.fn_tienda_yo(bigint) IS
    'Los datos de una cuenta de la tienda para el navegador. Nunca lleva el hash de la contraseña.';

-- ---------- 6. Registrarse ----------
CREATE OR REPLACE FUNCTION ecommerce.fn_tienda_registrar(
    p_nombres            character varying,
    p_apellidos          character varying,
    p_email              character varying,
    p_telefono           character varying,
    p_identificacion     character varying,
    p_password_hash      character varying,
    p_verify_code        character varying,
    p_tipo_identificacion character varying DEFAULT 'CC',
    p_tipo_cliente       character varying DEFAULT 'PERSONA',
    p_horas_codigo       integer DEFAULT 48,
    p_ip_address         inet DEFAULT NULL,
    p_user_agent         text DEFAULT NULL,
    p_request_id         uuid DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'ecommerce', 'seguridad', 'ventas', 'auditoria'
AS $function$
DECLARE
    v_email      text := lower(btrim(COALESCE(p_email, '')));
    v_ident      text := upper(btrim(COALESCE(p_identificacion, '')));
    v_nombres    text := btrim(COALESCE(p_nombres, ''));
    v_apellidos  text := btrim(COALESCE(p_apellidos, ''));
    v_telefono   text := btrim(COALESCE(p_telefono, ''));
    v_cliente    record;
    v_cliente_id bigint;
    v_perfil     bigint := ecommerce.fn_tienda_perfil_id();
    v_horario    bigint := ecommerce.fn_tienda_horario_id();
    v_login      text;
    v_id         bigint;
BEGIN
    -- ---------- Lo que no puede faltar ----------
    IF length(v_nombres) < 2 OR length(v_apellidos) < 2 THEN
        RAISE EXCEPTION 'Escribe tu nombre y tu apellido' USING ERRCODE = 'P0001';
    END IF;
    IF v_email !~ '^[^@\s]+@[^@\s]+\.[a-zA-Z]{2,}$' THEN
        RAISE EXCEPTION 'Ese correo no parece válido' USING ERRCODE = 'P0003';
    END IF;
    IF v_ident = '' THEN
        RAISE EXCEPTION 'Hace falta tu cédula o RUC' USING ERRCODE = 'P0001';
    END IF;
    IF v_telefono = '' THEN
        RAISE EXCEPTION 'Hace falta un teléfono de contacto' USING ERRCODE = 'P0001';
    END IF;
    IF COALESCE(btrim(p_password_hash), '') = '' THEN
        RAISE EXCEPTION 'Falta la contraseña' USING ERRCODE = 'P0001';
    END IF;
    IF v_perfil IS NULL OR v_horario IS NULL THEN
        RAISE EXCEPTION 'Falta el perfil o el horario de la tienda en la configuración' USING ERRCODE = 'P0016';
    END IF;

    -- ---------- ¿Ese correo ya tiene cuenta? ----------
    IF EXISTS (SELECT 1 FROM seguridad.users
                WHERE lower(email) = v_email AND type_user = 4 AND deleted_at IS NULL) THEN
        RAISE EXCEPTION 'Ese correo ya tiene una cuenta. Inicia sesión o recupera tu contraseña'
              USING ERRCODE = 'P0006';
    END IF;

    -- ---------- La ficha de cliente ----------
    SELECT id, lower(btrim(COALESCE(email, ''))) AS email, deleted_at
      INTO v_cliente
      FROM ventas.clientes
     WHERE numero_identificacion = v_ident;

    IF FOUND THEN
        -- YA HAY FICHA CON ESA IDENTIFICACIÓN: sólo se enlaza si el correo es
        -- el mismo. Si no, no se crea nada: esa ficha lleva crédito,
        -- descuento y mañana el historial, y una cédula se teclea en dos
        -- segundos
        IF v_cliente.deleted_at IS NOT NULL OR v_cliente.email IS DISTINCT FROM v_email THEN
            RAISE EXCEPTION 'Ya tenemos un cliente registrado con esa identificación. Acércate a una de nuestras tiendas o escríbenos para activar tu cuenta'
                  USING ERRCODE = 'P0015';
        END IF;

        IF EXISTS (SELECT 1 FROM seguridad.users
                    WHERE cliente_id = v_cliente.id AND type_user = 4 AND deleted_at IS NULL) THEN
            RAISE EXCEPTION 'Ese cliente ya tiene una cuenta en la tienda' USING ERRCODE = 'P0006';
        END IF;

        v_cliente_id := v_cliente.id;
    ELSE
        -- Se crea con la función de siempre (ventas.fn_clientes_crear): sus
        -- reglas, su auditoría y sus valores por defecto. Sin vendedor: nadie
        -- se la asignó todavía
        v_cliente_id := ((ventas.fn_clientes_crear(
                p_tipo_cliente        => COALESCE(p_tipo_cliente, 'PERSONA'),
                p_numero_identificacion => v_ident,
                p_tipo_identificacion => COALESCE(p_tipo_identificacion, 'CC'),
                p_nombres             => v_nombres,
                p_apellidos           => v_apellidos,
                p_email               => v_email,
                p_celular             => v_telefono,
                p_observaciones       => 'Se registró en la página web',
                p_usuario_login       => 'tienda',
                p_usuario_nombre      => 'Tienda en línea',
                p_ip_address          => p_ip_address,
                p_user_agent          => p_user_agent,
                p_request_id          => p_request_id)
            -> 'data' ->> 'id')::bigint);
    END IF;

    -- ---------- La cuenta ----------
    v_login := 'web-' || lpad(nextval('ecommerce.seq_login_tienda')::text, 6, '0');

    INSERT INTO seguridad.users (
        login_user, password, name, surname, email, phone,
        type_user, isactive, perfil_id, chorario_id, cliente_id,
        verify_code, verify_expires_at, created_by, updated_by)
    VALUES (
        v_login, p_password_hash, v_nombres, v_apellidos, v_email, v_telefono,
        4, true, v_perfil, v_horario, v_cliente_id,
        nullif(btrim(COALESCE(p_verify_code, '')), ''),
        CASE WHEN nullif(btrim(COALESCE(p_verify_code, '')), '') IS NULL THEN NULL
             ELSE CURRENT_TIMESTAMP + make_interval(hours => GREATEST(COALESCE(p_horas_codigo, 48), 1)) END,
        'tienda', 'tienda')
    RETURNING id INTO v_id;

    RETURN jsonb_build_object('success', true,
        'message', 'Cuenta creada. Te enviamos un correo para confirmarla',
        'data', ecommerce.fn_tienda_yo(v_id));
END;
$function$;

COMMENT ON FUNCTION ecommerce.fn_tienda_registrar(character varying, character varying, character varying, character varying, character varying, character varying, character varying, character varying, character varying, integer, inet, text, uuid) IS
    'Crea una cuenta de la tienda y su ficha de cliente. Si la identificación ya existe, sólo enlaza cuando el correo coincide.';

-- ---------- 7. Entrar ----------
--
-- DEVUELVE EL HASH y no compara nada: la comparación la hace PHP con
-- `password_verify`, que es quien sabe con qué algoritmo se guardó.
CREATE OR REPLACE FUNCTION ecommerce.fn_tienda_credenciales(p_email character varying)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
AS $function$
    SELECT jsonb_build_object(
               'id',       u.id,
               'hash',     u.password,
               'isactive', u.isactive,
               'verificado', u.email_verified_at IS NOT NULL)
      FROM seguridad.users u
     WHERE lower(u.email) = lower(btrim(p_email))
       AND u.type_user = 4
       AND u.deleted_at IS NULL;
$function$;

/** La entrada quedó registrada; no hay sesiones activas que anotar. */
CREATE OR REPLACE FUNCTION ecommerce.fn_tienda_marcar_entrada(p_usuario_id bigint)
RETURNS void
LANGUAGE sql
SECURITY DEFINER
AS $function$
    UPDATE seguridad.users
       SET last_login_at = CURRENT_TIMESTAMP
     WHERE id = p_usuario_id AND type_user = 4;
$function$;

-- ---------- 8. Verificar el correo ----------
--
-- GUARDA UN CÓDIGO NUEVO (al registrarse o al pedir reenvío) y lo CANJEA.
-- El código lo genera y lo envía PHP: aquí sólo se guarda, para que no viaje
-- en ninguna respuesta.
CREATE OR REPLACE FUNCTION ecommerce.fn_tienda_codigo_verificar(
    p_email        character varying,
    p_codigo       character varying,
    p_horas        integer DEFAULT 48)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'ecommerce', 'seguridad'
AS $function$
DECLARE
    v_id bigint;
BEGIN
    SELECT id INTO v_id FROM seguridad.users
     WHERE lower(email) = lower(btrim(p_email)) AND type_user = 4 AND deleted_at IS NULL;

    IF v_id IS NULL THEN
        RAISE EXCEPTION 'No hay ninguna cuenta con ese correo' USING ERRCODE = 'P0013';
    END IF;
    IF EXISTS (SELECT 1 FROM seguridad.users WHERE id = v_id AND email_verified_at IS NOT NULL) THEN
        RAISE EXCEPTION 'Esa cuenta ya está confirmada' USING ERRCODE = 'P0015';
    END IF;

    UPDATE seguridad.users
       SET verify_code = btrim(p_codigo),
           verify_expires_at = CURRENT_TIMESTAMP + make_interval(hours => GREATEST(COALESCE(p_horas, 48), 1))
     WHERE id = v_id;

    RETURN jsonb_build_object('success', true, 'message', 'Código de confirmación guardado',
                              'data', jsonb_build_object('id', v_id));
END;
$function$;

CREATE OR REPLACE FUNCTION ecommerce.fn_tienda_verificar(
    p_email  character varying,
    p_codigo character varying)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'ecommerce', 'seguridad'
AS $function$
DECLARE
    v_usuario record;
BEGIN
    SELECT id, verify_code, verify_expires_at, email_verified_at INTO v_usuario
      FROM seguridad.users
     WHERE lower(email) = lower(btrim(p_email)) AND type_user = 4 AND deleted_at IS NULL;

    IF v_usuario.id IS NULL THEN
        RAISE EXCEPTION 'No hay ninguna cuenta con ese correo' USING ERRCODE = 'P0013';
    END IF;
    IF v_usuario.email_verified_at IS NOT NULL THEN
        -- Ya estaba: no es un error para quien pulsa dos veces el enlace
        RETURN jsonb_build_object('success', true, 'message', 'Tu cuenta ya estaba confirmada',
                                  'data', ecommerce.fn_tienda_yo(v_usuario.id));
    END IF;
    IF v_usuario.verify_code IS NULL
       OR v_usuario.verify_code IS DISTINCT FROM btrim(p_codigo) THEN
        RAISE EXCEPTION 'Ese código no es el de tu cuenta' USING ERRCODE = 'P0015';
    END IF;
    IF v_usuario.verify_expires_at IS NULL OR v_usuario.verify_expires_at < CURRENT_TIMESTAMP THEN
        RAISE EXCEPTION 'Ese código ya caducó. Pide uno nuevo' USING ERRCODE = 'P0015';
    END IF;

    UPDATE seguridad.users
       SET email_verified_at = CURRENT_TIMESTAMP,
           verify_code = NULL,
           verify_expires_at = NULL
     WHERE id = v_usuario.id;

    RETURN jsonb_build_object('success', true, 'message', 'Listo, tu correo quedó confirmado',
                              'data', ecommerce.fn_tienda_yo(v_usuario.id));
END;
$function$;

-- ---------- 9. La contraseña ----------
--
-- Se apoya en `recovery_code` y `recovery_code_expires_at`, que ya existían
-- en la tabla para esto mismo en el CRM.
CREATE OR REPLACE FUNCTION ecommerce.fn_tienda_recuperar_pedir(
    p_email  character varying,
    p_codigo character varying,
    p_horas  integer DEFAULT 2)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'ecommerce', 'seguridad'
AS $function$
DECLARE
    v_id bigint;
BEGIN
    SELECT id INTO v_id FROM seguridad.users
     WHERE lower(email) = lower(btrim(p_email)) AND type_user = 4 AND deleted_at IS NULL AND isactive;

    -- NO SE DICE SI EXISTE O NO: contestar «ese correo no está» le confirma a
    -- cualquiera qué correos tienen cuenta. Quien llame se encarga de
    -- contestar siempre lo mismo
    IF v_id IS NULL THEN
        RETURN jsonb_build_object('success', true, 'message', 'Si ese correo tiene cuenta, le llegará un mensaje',
                                  'data', NULL);
    END IF;

    UPDATE seguridad.users
       SET recovery_code = btrim(p_codigo),
           recovery_code_expires_at = (CURRENT_TIMESTAMP + make_interval(hours => GREATEST(COALESCE(p_horas, 2), 1)))::timestamp
     WHERE id = v_id;

    RETURN jsonb_build_object('success', true, 'message', 'Si ese correo tiene cuenta, le llegará un mensaje',
                              'data', jsonb_build_object('id', v_id));
END;
$function$;

CREATE OR REPLACE FUNCTION ecommerce.fn_tienda_recuperar_cambiar(
    p_email         character varying,
    p_codigo        character varying,
    p_password_hash character varying)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'ecommerce', 'seguridad'
AS $function$
DECLARE
    v_usuario record;
BEGIN
    SELECT id, recovery_code, recovery_code_expires_at INTO v_usuario
      FROM seguridad.users
     WHERE lower(email) = lower(btrim(p_email)) AND type_user = 4 AND deleted_at IS NULL;

    IF v_usuario.id IS NULL
       OR v_usuario.recovery_code IS NULL
       OR v_usuario.recovery_code IS DISTINCT FROM btrim(p_codigo) THEN
        RAISE EXCEPTION 'Ese código no sirve para esta cuenta' USING ERRCODE = 'P0015';
    END IF;
    IF v_usuario.recovery_code_expires_at IS NULL
       OR v_usuario.recovery_code_expires_at < CURRENT_TIMESTAMP THEN
        RAISE EXCEPTION 'Ese código ya caducó. Pide uno nuevo' USING ERRCODE = 'P0015';
    END IF;
    IF COALESCE(btrim(p_password_hash), '') = '' THEN
        RAISE EXCEPTION 'Falta la contraseña nueva' USING ERRCODE = 'P0001';
    END IF;

    UPDATE seguridad.users
       SET password = p_password_hash,
           recovery_code = NULL,
           recovery_code_expires_at = NULL,
           -- Quien pudo leer el correo del código, demostró que es suyo
           email_verified_at = COALESCE(email_verified_at, CURRENT_TIMESTAMP)
     WHERE id = v_usuario.id;

    RETURN jsonb_build_object('success', true, 'message', 'Tu contraseña quedó cambiada',
                              'data', ecommerce.fn_tienda_yo(v_usuario.id));
END;
$function$;

-- ---------- 10. El carrito pasa a ser suyo ----------
--
-- Al entrar, el carrito anónimo que traía se amarra a su cliente. No se
-- mezcla con ningún otro: si ya tenía uno de antes, se queda el que trae
-- puesto, que es el que acaba de llenar.
CREATE OR REPLACE FUNCTION ecommerce.fn_carrito_asociar(p_token uuid, p_cliente_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'ecommerce'
AS $function$
BEGIN
    UPDATE ecommerce.carritos
       SET cliente_id = p_cliente_id, updated_at = CURRENT_TIMESTAMP
     WHERE token = p_token AND estado = 'abierto';

    RETURN jsonb_build_object('success', true, 'message', 'Carrito asociado',
                              'data', ecommerce.fn_carrito_publico(p_token));
END;
$function$;

COMMIT;


-- ============================================================================
-- COMPROBACIÓN — crea una cuenta de prueba y la deshace
-- ============================================================================
DO $comprobar$
DECLARE
    v_falta  text[] := '{}';
    v_res    jsonb;
    v_id     bigint;
    v_cli    bigint;
    v_ajeno  bigint;
    v_ident  text := 'ZZ' || to_char(clock_timestamp(), 'HH24MISSUS');
    v_correo text := 'zz.prueba.' || to_char(clock_timestamp(), 'HH24MISSUS') || '@ejemplo.com';
BEGIN
    IF ecommerce.fn_tienda_perfil_id() IS NULL OR ecommerce.fn_tienda_horario_id() IS NULL THEN
        v_falta := array_append(v_falta, 'falta el perfil o el horario de la tienda');
    END IF;

    -- El horario tiene que dejar entrar AHORA, sea la hora que sea
    IF NOT ((seguridad.fn_horarios_puede_entrar(ecommerce.fn_tienda_horario_id()) ->> 'permitido')::boolean) THEN
        v_falta := array_append(v_falta, 'el horario de la tienda no deja entrar a esta hora');
    END IF;
    IF NOT ((seguridad.fn_horarios_puede_entrar(ecommerce.fn_tienda_horario_id(),
                 date_trunc('day', CURRENT_TIMESTAMP) + interval '3 hours') ->> 'permitido')::boolean) THEN
        v_falta := array_append(v_falta, 'el horario de la tienda no deja entrar de madrugada');
    END IF;

    BEGIN
        -- ---------- Registrarse ----------
        v_res := ecommerce.fn_tienda_registrar(
            'Prueba', 'Automática', v_correo, '0999999999', v_ident, '$2y$10$hashdeprueba', '123456');
        v_id  := (v_res -> 'data' ->> 'id')::bigint;
        v_cli := (v_res -> 'data' ->> 'cliente_id')::bigint;

        IF v_id IS NULL OR v_cli IS NULL THEN
            v_falta := array_append(v_falta, 'el registro no devolvió usuario y cliente');
        END IF;
        IF (v_res -> 'data' ->> 'verificado')::boolean THEN
            v_falta := array_append(v_falta, 'la cuenta nació verificada');
        END IF;
        IF (SELECT type_user FROM seguridad.users WHERE id = v_id) <> 4 THEN
            v_falta := array_append(v_falta, 'la cuenta no quedó como usuario de la web');
        END IF;
        IF (SELECT login_user FROM seguridad.users WHERE id = v_id) !~ '^web-[0-9]{6}$' THEN
            v_falta := array_append(v_falta, 'el login generado no tiene la forma esperada');
        END IF;

        -- ---------- El mismo correo, otra vez ----------
        BEGIN
            PERFORM ecommerce.fn_tienda_registrar(
                'Otra', 'Persona', v_correo, '0988888888', v_ident || 'B', '$2y$10$hash2', '123456');
            v_falta := array_append(v_falta, 'dejó registrar dos cuentas con el mismo correo');
        EXCEPTION WHEN others THEN NULL;
        END;

        -- ---------- Una cédula ajena ----------
        -- (la del cliente recién creado, pero con OTRO correo)
        BEGIN
            PERFORM ecommerce.fn_tienda_registrar(
                'Intruso', 'Cualquiera', 'zz.intruso.' || v_ident || '@ejemplo.com',
                '0977777777', v_ident, '$2y$10$hash3', '123456');
            v_falta := array_append(v_falta, 'dejó reclamar la ficha de otro con su cédula');
        EXCEPTION WHEN others THEN NULL;
        END;

        -- ---------- Entrar ----------
        IF (ecommerce.fn_tienda_credenciales(upper(v_correo)) ->> 'hash') <> '$2y$10$hashdeprueba' THEN
            v_falta := array_append(v_falta, 'no se recuperan las credenciales por correo (sin importar mayúsculas)');
        END IF;
        IF ecommerce.fn_tienda_credenciales('nadie' || v_correo) IS NOT NULL THEN
            v_falta := array_append(v_falta, 'devolvió credenciales de un correo que no existe');
        END IF;

        -- ---------- Verificar ----------
        BEGIN
            PERFORM ecommerce.fn_tienda_verificar(v_correo, '999999');
            v_falta := array_append(v_falta, 'aceptó un código de verificación equivocado');
        EXCEPTION WHEN others THEN NULL;
        END;

        v_res := ecommerce.fn_tienda_verificar(v_correo, '123456');
        IF NOT (v_res -> 'data' ->> 'verificado')::boolean THEN
            v_falta := array_append(v_falta, 'el código bueno no verificó la cuenta');
        END IF;

        -- ---------- La contraseña ----------
        PERFORM ecommerce.fn_tienda_recuperar_pedir(v_correo, '654321', 2);
        v_res := ecommerce.fn_tienda_recuperar_cambiar(v_correo, '654321', '$2y$10$hashnuevo');
        IF (SELECT password FROM seguridad.users WHERE id = v_id) <> '$2y$10$hashnuevo' THEN
            v_falta := array_append(v_falta, 'no se cambió la contraseña');
        END IF;
        IF (SELECT recovery_code FROM seguridad.users WHERE id = v_id) IS NOT NULL THEN
            v_falta := array_append(v_falta, 'el código de recuperación se quedó guardado');
        END IF;

        -- Pedir la contraseña de un correo que no existe no delata nada
        IF NOT ((ecommerce.fn_tienda_recuperar_pedir('nadie' || v_correo, '111111') ->> 'success')::boolean) THEN
            v_falta := array_append(v_falta, 'recuperar delata si el correo existe o no');
        END IF;

        -- ---------- Un empleado NO entra por aquí ----------
        SELECT id INTO v_ajeno FROM seguridad.users WHERE type_user = 3 AND deleted_at IS NULL LIMIT 1;
        IF v_ajeno IS NOT NULL THEN
            IF ecommerce.fn_tienda_credenciales(
                   (SELECT email FROM seguridad.users WHERE id = v_ajeno)) IS NOT NULL THEN
                v_falta := array_append(v_falta, 'la puerta de la tienda deja pasar a un usuario del CRM');
            END IF;
            IF ecommerce.fn_tienda_yo(v_ajeno) IS NOT NULL THEN
                v_falta := array_append(v_falta, 'la tienda devuelve datos de un usuario del CRM');
            END IF;
        END IF;

        RAISE EXCEPTION 'deshacer la prueba';
    EXCEPTION WHEN others THEN
        IF SQLERRM <> 'deshacer la prueba' THEN
            RAISE;
        END IF;
    END;

    IF EXISTS (SELECT 1 FROM seguridad.users WHERE type_user = 4) THEN
        v_falta := array_append(v_falta, 'la prueba dejó cuentas de tienda en la base');
    END IF;
    IF EXISTS (SELECT 1 FROM ventas.clientes WHERE numero_identificacion LIKE 'ZZ%') THEN
        v_falta := array_append(v_falta, 'la prueba dejó clientes en la base');
    END IF;

    IF array_length(v_falta, 1) > 0 THEN
        RAISE EXCEPTION 'Las cuentas de la tienda no quedaron bien: %', array_to_string(v_falta, '; ');
    END IF;

    RAISE NOTICE 'Las cuentas de la tienda funcionan: registro, ficha de cliente, entrada, verificación y contraseña.';
END;
$comprobar$;
