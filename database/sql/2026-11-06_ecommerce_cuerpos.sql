-- ============================================================================
-- ECOMMERCE · LOS CUERPOS DE LA TIENDA
-- ============================================================================
-- Fecha: 2026-11-06
--
-- Hasta hoy la tienda tenía UNA portada: `inicio_secciones` era la lista de
-- secciones de la página de entrada y su `clave` era única en toda la tabla.
--
-- AHORA HAY VARIOS CUERPOS. Un cuerpo es una lista de secciones con su propia
-- dirección. Uno está marcado como PRINCIPAL y es el que sale al abrir la
-- tienda; los demás son páginas que se llegan por su dirección:
--
--     Inicio      principal              /              (la de siempre)
--     Movilidad   categoría Movilidad    /movilidad
--     Bajaj       marca Bajaj            /bajaj
--     Navidad     suelto                 /navidad
--
-- A QUÉ APUNTA UN CUERPO ES LO QUE HACE QUE LOS ENLACES SALGAN SOLOS. Si un
-- cuerpo dice «yo soy la categoría Movilidad», el clic en Movilidad —en el
-- menú, en las destacadas, en el mosaico— lleva a /movilidad en vez de a
-- /shop, sin tener que enlazarlo a mano en cada sitio. La categoría o la
-- marca que no tenga cuerpo sigue yendo a /shop como siempre.
--
-- EL PRINCIPAL NO APUNTA A NADA. Es la entrada de la tienda: si además fuera
-- la página de una categoría, la misma lista de secciones viviría en dos
-- direcciones y Google las vería como contenido repetido. Se prohíbe en la
-- tabla, no en el PHP.
--
-- LA DIRECCIÓN LA ESCRIBE EL USUARIO, como en las páginas de marca
-- (`fn_pagina_marca_direccion`): «movilidad» se lee y «/categoria/12» no. Se
-- comprueba contra las direcciones que la tienda ya usa para sus pantallas
-- —/shop, /cart…—, que están en la lista de abajo y en app.routes.ts.
--
-- QUÉ ENSEÑA CADA SECCIÓN. «Categorías destacadas» y «Marcas» sacaban lo de
-- toda la tienda. En un cuerpo amarrado a una categoría eso queda raro, así
-- que cada sección lleva su ALCANCE: «tienda» (lo de siempre) o «cuerpo» (lo
-- que cuelga de su categoría o de su marca).
--
-- ESTE FICHERO NO CAMBIA NINGUNA FUNCIÓN DE LA PORTADA. Al terminar, la
-- tienda y el CRM siguen trabajando igual, con un solo cuerpo. Pasar las
-- funciones a trabajar por `id` en vez de por `clave` va en el siguiente
-- (2026-11-06_ecommerce_secciones_por_cuerpo.sql), y lo público en el tercero.
--
-- OJO AL VOLVER A PASARLO SUELTO: `fn_cuerpos_guardar` se define aquí y los
-- ficheros siguientes la rehacen —el 2 le añade la siembra de secciones y
-- `_cuerpo_fondo` el color de fondo—. Pasar éste solo la deja como estaba el
-- 06-11 y un cuerpo nuevo nacería vacío. Si se pasa éste, se pasan los demás
-- detrás, en su orden.
--
-- Idempotente.
-- ============================================================================
\set ON_ERROR_STOP on

BEGIN;

-- ----------------------------------------------------------------------------
-- 1. LA TABLA
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS ecommerce.cuerpos (
    id           bigint       NOT NULL,
    -- Cómo lo llamamos en el CRM. No se ve en la tienda.
    nombre       varchar(100) NOT NULL,
    -- Su dirección en la tienda: «movilidad» → /movilidad
    ruta         varchar(60)  NOT NULL,
    -- El que sale al abrir la tienda. Sólo uno.
    principal    boolean      NOT NULL DEFAULT false,
    -- A qué apunta: una cosa o la otra, o ninguna (una página suelta)
    categoria_id bigint,
    marca_id     bigint,
    -- Lo que lee el visitante arriba de la página. Vacío, la tienda no pone
    -- encabezado y la página empieza por su primera sección.
    titulo       varchar(120),
    descripcion  text,
    -- Debajo de las secciones, la rejilla de productos de su categoría o de
    -- su marca, con filtros y paginación, como /shop
    catalogo     boolean      NOT NULL DEFAULT false,
    activo       boolean      NOT NULL DEFAULT true,
    created_at   timestamptz  NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at   timestamptz  NOT NULL DEFAULT CURRENT_TIMESTAMP,
    created_by   varchar(100),
    updated_by   varchar(100),
    deleted_at   timestamptz,
    deleted_by   varchar(100),
    CONSTRAINT pk_cuerpos PRIMARY KEY (id),
    -- Minúsculas, números y guiones; empieza por letra o número. Es lo que va
    -- en la barra del navegador.
    CONSTRAINT ck_cuerpos_ruta CHECK (ruta ~ '^[a-z0-9][a-z0-9-]*$'),
    -- A una categoría O a una marca, nunca a las dos
    CONSTRAINT ck_cuerpos_destino CHECK (categoria_id IS NULL OR marca_id IS NULL),
    -- Y el principal, a nada: es la entrada de la tienda
    CONSTRAINT ck_cuerpos_principal
        CHECK (NOT principal OR (categoria_id IS NULL AND marca_id IS NULL)),
    CONSTRAINT fk_cuerpos_categoria FOREIGN KEY (categoria_id)
        REFERENCES inventarios.categorias (id),
    CONSTRAINT fk_cuerpos_marca FOREIGN KEY (marca_id)
        REFERENCES inventarios.marcas (id)
);

COMMENT ON TABLE ecommerce.cuerpos IS
    'Las páginas de secciones de la tienda. Una es la principal; las demás se llegan por su dirección.';

CREATE SEQUENCE IF NOT EXISTS ecommerce.cuerpos_id_seq OWNED BY ecommerce.cuerpos.id;
ALTER TABLE ecommerce.cuerpos ALTER COLUMN id SET DEFAULT nextval('ecommerce.cuerpos_id_seq');

-- Lo único de cada cosa, y SÓLO entre los que no están en la papelera: uno
-- borrado no puede impedir que su dirección se vuelva a usar.
CREATE UNIQUE INDEX IF NOT EXISTS uq_cuerpos_ruta
    ON ecommerce.cuerpos (ruta) WHERE deleted_at IS NULL;
CREATE UNIQUE INDEX IF NOT EXISTS uq_cuerpos_nombre
    ON ecommerce.cuerpos (lower(nombre)) WHERE deleted_at IS NULL;
CREATE UNIQUE INDEX IF NOT EXISTS uq_cuerpos_principal
    ON ecommerce.cuerpos (principal) WHERE principal AND deleted_at IS NULL;
CREATE UNIQUE INDEX IF NOT EXISTS uq_cuerpos_categoria
    ON ecommerce.cuerpos (categoria_id) WHERE categoria_id IS NOT NULL AND deleted_at IS NULL;
CREATE UNIQUE INDEX IF NOT EXISTS uq_cuerpos_marca
    ON ecommerce.cuerpos (marca_id) WHERE marca_id IS NOT NULL AND deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_cuerpos_deleted_at
    ON ecommerce.cuerpos (deleted_at) WHERE deleted_at IS NOT NULL;

DO $disparadores$
BEGIN
    DROP TRIGGER IF EXISTS trg_cuerpos_audit ON ecommerce.cuerpos;
    CREATE TRIGGER trg_cuerpos_audit AFTER INSERT OR UPDATE OR DELETE
        ON ecommerce.cuerpos FOR EACH ROW EXECUTE FUNCTION auditoria.fn_auditar_cambios();

    DROP TRIGGER IF EXISTS trg_cuerpos_updated_at ON ecommerce.cuerpos;
    CREATE TRIGGER trg_cuerpos_updated_at BEFORE UPDATE
        ON ecommerce.cuerpos FOR EACH ROW EXECUTE FUNCTION auditoria.fn_update_updated_at_column();

    DROP TRIGGER IF EXISTS trg_cuerpos_users ON ecommerce.cuerpos;
    CREATE TRIGGER trg_cuerpos_users BEFORE INSERT OR UPDATE
        ON ecommerce.cuerpos FOR EACH ROW EXECUTE FUNCTION auditoria.fn_set_audit_users();
END
$disparadores$;

-- ----------------------------------------------------------------------------
-- 2. EL CUERPO QUE YA HABÍA
-- ----------------------------------------------------------------------------
-- La portada de siempre pasa a ser el cuerpo principal. Se crea una sola vez:
-- si la tabla tiene algo, este fichero ya se pasó.
INSERT INTO ecommerce.cuerpos (nombre, ruta, principal, created_by, updated_by)
SELECT 'Inicio', 'inicio', true, 'migracion', 'migracion'
 WHERE NOT EXISTS (SELECT 1 FROM ecommerce.cuerpos);

-- El id del principal, que hace falta en todas partes. Función y no una
-- constante: cambia cuando se cambia de principal.
CREATE OR REPLACE FUNCTION ecommerce.fn_cuerpo_principal_id()
 RETURNS bigint
 LANGUAGE sql
 STABLE
AS $function$
    SELECT c.id FROM ecommerce.cuerpos c
     WHERE c.principal AND c.deleted_at IS NULL;
$function$;

COMMENT ON FUNCTION ecommerce.fn_cuerpo_principal_id() IS
    'El cuerpo que sale al abrir la tienda. Hay uno y sólo uno.';

-- ----------------------------------------------------------------------------
-- 3. CADA SECCIÓN ES DE UN CUERPO
-- ----------------------------------------------------------------------------
ALTER TABLE ecommerce.inicio_secciones
    ADD COLUMN IF NOT EXISTS cuerpo_id bigint;

-- Lo que había es del principal
UPDATE ecommerce.inicio_secciones
   SET cuerpo_id = ecommerce.fn_cuerpo_principal_id()
 WHERE cuerpo_id IS NULL;

ALTER TABLE ecommerce.inicio_secciones ALTER COLUMN cuerpo_id SET NOT NULL;

DO $ligar$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_inicio_secciones_cuerpo') THEN
        -- CASCADE para el vaciado de la papelera: al borrar un cuerpo de
        -- verdad se van sus secciones. Mientras está EN la papelera no se
        -- borra nada, que es lo que hace que restaurar lo devuelva entero.
        ALTER TABLE ecommerce.inicio_secciones
            ADD CONSTRAINT fk_inicio_secciones_cuerpo
            FOREIGN KEY (cuerpo_id) REFERENCES ecommerce.cuerpos (id) ON DELETE CASCADE;
    END IF;
END
$ligar$;

CREATE INDEX IF NOT EXISTS ix_inicio_secciones_cuerpo
    ON ecommerce.inicio_secciones (cuerpo_id, orden);

-- La clave ya no es única en la tabla: es única DENTRO del cuerpo. Cada
-- cuerpo tiene su «banner_principal» y sus «categorias_destacadas».
DROP INDEX IF EXISTS ecommerce.uq_inicio_secciones_clave;
CREATE UNIQUE INDEX IF NOT EXISTS uq_inicio_secciones_cuerpo_clave
    ON ecommerce.inicio_secciones (cuerpo_id, clave);

-- Y un escaparate de «Productos por sección» puede enseñarse en VARIOS
-- cuerpos, cada uno con su rótulo, su alto y su orden; antes sólo en uno.
DROP INDEX IF EXISTS ecommerce.uq_inicio_secciones_producto_seccion;
CREATE UNIQUE INDEX IF NOT EXISTS uq_inicio_secciones_cuerpo_producto_seccion
    ON ecommerce.inicio_secciones (cuerpo_id, producto_seccion_id)
 WHERE producto_seccion_id IS NOT NULL;

-- ----------------------------------------------------------------------------
-- 4. QUÉ ENSEÑA UNA SECCIÓN: LO DE LA TIENDA O LO DE SU CUERPO
-- ----------------------------------------------------------------------------
ALTER TABLE ecommerce.inicio_secciones
    ADD COLUMN IF NOT EXISTS alcance varchar(10);

DO $alcance$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'ck_inicio_secciones_alcance') THEN
        -- NULL = «tienda», como todo lo demás de esta tabla: el valor de
        -- siempre no se escribe en las filas que ya estaban.
        ALTER TABLE ecommerce.inicio_secciones
            ADD CONSTRAINT ck_inicio_secciones_alcance
            CHECK (alcance IS NULL OR alcance IN ('tienda', 'cuerpo'));
    END IF;
END
$alcance$;

-- ----------------------------------------------------------------------------
-- 5. LO QUE SE COMPRUEBA DE UN CUERPO
-- ----------------------------------------------------------------------------
-- En un solo sitio: lo usan crear, modificar y restaurar.
CREATE OR REPLACE FUNCTION ecommerce.fn_cuerpos_validar(
    p_id           bigint,
    p_nombre       text,
    p_ruta         text,
    p_categoria_id bigint DEFAULT NULL,
    p_marca_id     bigint DEFAULT NULL)
 RETURNS void
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
    -- Las direcciones que la tienda YA usa para sus pantallas. Si se añade
    -- una ruta en miEcommerce/src/app/app.routes.ts, va también aquí: un
    -- cuerpo llamado «shop» se guardaría y luego no se abriría nunca, porque
    -- la pantalla de siempre gana.
    c_tomadas text[] := ARRAY[
        'shop', 'cart', 'login', 'register', 'product', 'marca', 'paginas',
        'documentos', 'tiendas', 'conocenos', 'espana-motos', 'vista-previa',
        'terminos-y-condiciones', 'politicas-de-garantia', 'garantia-extendida',
        'beneficios-para-empresa', 'proteccion-de-datos', 'assets', 'api'];
    v_nombre text;
    v_ruta   text;
BEGIN
    v_nombre := ecommerce.fn_validar_texto(p_nombre, 'El nombre del cuerpo', 100, true);

    v_ruta := lower(btrim(COALESCE(p_ruta, '')));
    IF v_ruta = '' THEN
        RAISE EXCEPTION 'Hace falta la dirección del cuerpo' USING ERRCODE = 'P0001';
    END IF;
    IF length(v_ruta) > 60 THEN
        RAISE EXCEPTION 'La dirección no puede pasar de 60 letras' USING ERRCODE = 'P0015';
    END IF;
    IF v_ruta !~ '^[a-z0-9][a-z0-9-]*$' THEN
        RAISE EXCEPTION 'La dirección sólo lleva letras sin tilde, números y guiones, y empieza por letra o número'
              USING ERRCODE = 'P0015';
    END IF;
    IF v_ruta = ANY (c_tomadas) THEN
        RAISE EXCEPTION 'La dirección «%» ya es de una pantalla de la tienda: elige otra', v_ruta
              USING ERRCODE = 'P0015';
    END IF;

    IF EXISTS (SELECT 1 FROM ecommerce.cuerpos c
                WHERE lower(c.nombre) = lower(v_nombre) AND c.deleted_at IS NULL
                  AND (p_id IS NULL OR c.id <> p_id)) THEN
        RAISE EXCEPTION 'Ya hay un cuerpo llamado «%»', v_nombre USING ERRCODE = 'P0015';
    END IF;
    IF EXISTS (SELECT 1 FROM ecommerce.cuerpos c
                WHERE c.ruta = v_ruta AND c.deleted_at IS NULL
                  AND (p_id IS NULL OR c.id <> p_id)) THEN
        RAISE EXCEPTION 'Ya hay un cuerpo en la dirección «/%»', v_ruta USING ERRCODE = 'P0015';
    END IF;

    IF p_categoria_id IS NOT NULL AND p_marca_id IS NOT NULL THEN
        RAISE EXCEPTION 'Un cuerpo apunta a una categoría o a una marca, no a las dos'
              USING ERRCODE = 'P0015';
    END IF;

    IF p_categoria_id IS NOT NULL THEN
        IF NOT EXISTS (SELECT 1 FROM inventarios.categorias
                        WHERE id = p_categoria_id AND deleted_at IS NULL) THEN
            RAISE EXCEPTION 'Esa categoría no existe' USING ERRCODE = 'P0013';
        END IF;
        IF EXISTS (SELECT 1 FROM ecommerce.cuerpos c
                    WHERE c.categoria_id = p_categoria_id AND c.deleted_at IS NULL
                      AND (p_id IS NULL OR c.id <> p_id)) THEN
            RAISE EXCEPTION 'La categoría «%» ya tiene su cuerpo: «%»',
                  inventarios.fn_categoria_ruta(p_categoria_id),
                  (SELECT nombre FROM ecommerce.cuerpos
                    WHERE categoria_id = p_categoria_id AND deleted_at IS NULL)
                  USING ERRCODE = 'P0015';
        END IF;
    END IF;

    IF p_marca_id IS NOT NULL THEN
        IF NOT EXISTS (SELECT 1 FROM inventarios.marcas
                        WHERE id = p_marca_id AND deleted_at IS NULL) THEN
            RAISE EXCEPTION 'Esa marca no existe' USING ERRCODE = 'P0013';
        END IF;
        IF EXISTS (SELECT 1 FROM ecommerce.cuerpos c
                    WHERE c.marca_id = p_marca_id AND c.deleted_at IS NULL
                      AND (p_id IS NULL OR c.id <> p_id)) THEN
            RAISE EXCEPTION 'La marca «%» ya tiene su cuerpo: «%»',
                  (SELECT nombre FROM inventarios.marcas WHERE id = p_marca_id),
                  (SELECT nombre FROM ecommerce.cuerpos
                    WHERE marca_id = p_marca_id AND deleted_at IS NULL)
                  USING ERRCODE = 'P0015';
        END IF;
    END IF;
END;
$function$;

-- ----------------------------------------------------------------------------
-- 6. UN CUERPO, COMO LO VE EL CRM
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ecommerce.fn_cuerpos_json(p_id bigint)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
AS $function$
    SELECT jsonb_build_object(
        'id',           c.id,
        'nombre',       c.nombre,
        'ruta',         c.ruta,
        'principal',    c.principal,
        -- La dirección de verdad, armada aquí: el principal vive en la raíz y
        -- que lo sepan la pantalla y la tienda por separado es pedir que un
        -- día una de las dos se olvide.
        'url',          CASE WHEN c.principal THEN '/' ELSE '/' || c.ruta END,
        -- Lo decide el servidor, como `fija` en las secciones
        'destino',      CASE WHEN c.principal              THEN 'inicio'
                             WHEN c.categoria_id IS NOT NULL THEN 'categoria'
                             WHEN c.marca_id IS NOT NULL     THEN 'marca'
                             ELSE 'libre' END,
        'categoria_id', c.categoria_id,
        -- Con su ruta entera («Vehículos > Movilidad»): fuera del árbol, el
        -- nombre suelto no dice de qué categoría se habla
        'categoria',    inventarios.fn_categoria_ruta(c.categoria_id),
        'marca_id',     c.marca_id,
        'marca',        (SELECT m.nombre FROM inventarios.marcas m WHERE m.id = c.marca_id),
        'titulo',       c.titulo,
        'descripcion',  c.descripcion,
        'catalogo',     c.catalogo,
        'activo',       c.activo,
        'secciones',    (SELECT count(*) FROM ecommerce.inicio_secciones s
                          WHERE s.cuerpo_id = c.id
                            AND ecommerce.fn_inicio_seccion_viva(s.producto_seccion_id)),
        'estado',       CASE WHEN c.deleted_at IS NOT NULL THEN 'papelera'
                             WHEN NOT c.activo             THEN 'oculto'
                             WHEN c.principal              THEN 'principal'
                             ELSE 'visible' END,
        'deleted_at',   to_char(c.deleted_at, 'YYYY-MM-DD HH24:MI'),
        'deleted_by',   c.deleted_by,
        'updated_at',   to_char(c.updated_at, 'YYYY-MM-DD HH24:MI'),
        'updated_by',   c.updated_by)
      FROM ecommerce.cuerpos c
     WHERE c.id = p_id;
$function$;

CREATE OR REPLACE FUNCTION ecommerce.fn_cuerpos_listar()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
AS $function$
    SELECT jsonb_build_object('success', true, 'message', 'Cuerpos de la tienda',
        'data', COALESCE((
            SELECT jsonb_agg(ecommerce.fn_cuerpos_json(c.id)
                             -- El principal primero: es el que se abre más
                             ORDER BY c.principal DESC, lower(c.nombre))
              FROM ecommerce.cuerpos c
             WHERE c.deleted_at IS NULL), '[]'::jsonb));
$function$;

CREATE OR REPLACE FUNCTION ecommerce.fn_cuerpos_papelera_listar()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
AS $function$
    SELECT jsonb_build_object('success', true, 'message', 'Papelera de cuerpos',
        'data', COALESCE((
            SELECT jsonb_agg(ecommerce.fn_cuerpos_json(c.id) ORDER BY c.deleted_at DESC)
              FROM ecommerce.cuerpos c
             WHERE c.deleted_at IS NOT NULL), '[]'::jsonb));
$function$;

-- ----------------------------------------------------------------------------
-- 7. CREAR Y MODIFICAR
-- ----------------------------------------------------------------------------
-- Una sola puerta: `p_id` NULL es uno nuevo. Es el mismo formulario en el
-- CRM, así que partirlo en dos funciones sería repetir las validaciones.
CREATE OR REPLACE FUNCTION ecommerce.fn_cuerpos_guardar(
    p_id             bigint,
    p_datos          jsonb,
    p_usuario_id     bigint     DEFAULT NULL,
    p_usuario_login  varchar    DEFAULT NULL,
    p_usuario_nombre varchar    DEFAULT NULL,
    p_ip_address     inet       DEFAULT NULL,
    p_user_agent     text       DEFAULT NULL,
    p_request_id     uuid       DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'ecommerce', 'auditoria'
AS $function$
DECLARE
    v_id        bigint := p_id;
    v_nombre    text;
    v_ruta      text;
    v_categoria bigint;
    v_marca     bigint;
    v_principal boolean := false;
BEGIN
    PERFORM ecommerce.fn_contexto_auditoria('ecommerce.cuerpos',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    IF p_id IS NOT NULL THEN
        SELECT principal INTO v_principal FROM ecommerce.cuerpos
         WHERE id = p_id AND deleted_at IS NULL;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'Ese cuerpo no existe' USING ERRCODE = 'P0013';
        END IF;
    END IF;

    v_nombre    := btrim(COALESCE(p_datos ->> 'nombre', ''));
    v_ruta      := lower(btrim(COALESCE(p_datos ->> 'ruta', '')));
    v_categoria := nullif(btrim(COALESCE(p_datos ->> 'categoria_id', '')), '')::bigint;
    v_marca     := nullif(btrim(COALESCE(p_datos ->> 'marca_id', '')), '')::bigint;

    -- El principal no apunta a nada, y se dice aquí para que el mensaje
    -- explique qué hacer; la tabla lo prohíbe igual por si entra por otro lado
    IF v_principal AND (v_categoria IS NOT NULL OR v_marca IS NOT NULL) THEN
        RAISE EXCEPTION 'El cuerpo principal es la entrada de la tienda: no puede ser además la página de una categoría o de una marca'
              USING ERRCODE = 'P0015';
    END IF;

    PERFORM ecommerce.fn_cuerpos_validar(p_id, v_nombre, v_ruta, v_categoria, v_marca);

    IF p_id IS NULL THEN
        INSERT INTO ecommerce.cuerpos (nombre, ruta, categoria_id, marca_id, titulo, descripcion,
                                       catalogo, activo)
        VALUES (v_nombre, v_ruta, v_categoria, v_marca,
                ecommerce.fn_validar_texto(p_datos ->> 'titulo', 'El título de la página', 120),
                nullif(btrim(COALESCE(p_datos ->> 'descripcion', '')), ''),
                COALESCE((p_datos ->> 'catalogo')::boolean, false),
                COALESCE((p_datos ->> 'activo')::boolean, true))
        RETURNING id INTO v_id;
    ELSE
        UPDATE ecommerce.cuerpos
           SET nombre       = v_nombre,
               ruta         = v_ruta,
               categoria_id = v_categoria,
               marca_id     = v_marca,
               titulo       = ecommerce.fn_validar_texto(p_datos ->> 'titulo', 'El título de la página', 120),
               descripcion  = nullif(btrim(COALESCE(p_datos ->> 'descripcion', '')), ''),
               catalogo     = COALESCE((p_datos ->> 'catalogo')::boolean, false),
               -- El principal no se puede apagar: la tienda se quedaría sin
               -- página de entrada
               activo       = CASE WHEN principal THEN true
                                   ELSE COALESCE((p_datos ->> 'activo')::boolean, true) END
         WHERE id = p_id;
    END IF;

    RETURN jsonb_build_object('success', true,
        'message', format('Cuerpo «%s» %s', v_nombre,
                          CASE WHEN p_id IS NULL THEN 'creado' ELSE 'guardado' END),
        'data', ecommerce.fn_cuerpos_json(v_id));
END;
$function$;

-- ----------------------------------------------------------------------------
-- 8. CUÁL ES EL PRINCIPAL
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ecommerce.fn_cuerpos_principal(
    p_id             bigint,
    p_usuario_id     bigint  DEFAULT NULL,
    p_usuario_login  varchar DEFAULT NULL,
    p_usuario_nombre varchar DEFAULT NULL,
    p_ip_address     inet    DEFAULT NULL,
    p_user_agent     text    DEFAULT NULL,
    p_request_id     uuid    DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'ecommerce', 'auditoria'
AS $function$
DECLARE
    v_nombre    text;
    v_categoria bigint;
    v_marca     bigint;
    v_antes     text;
BEGIN
    PERFORM ecommerce.fn_contexto_auditoria('ecommerce.cuerpos',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    SELECT nombre, categoria_id, marca_id INTO v_nombre, v_categoria, v_marca
      FROM ecommerce.cuerpos WHERE id = p_id AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Ese cuerpo no existe' USING ERRCODE = 'P0013';
    END IF;

    IF v_categoria IS NOT NULL OR v_marca IS NOT NULL THEN
        RAISE EXCEPTION '«%» es la página de una categoría o de una marca. Quítale eso primero y entonces puede ser la entrada de la tienda',
              v_nombre USING ERRCODE = 'P0015';
    END IF;

    SELECT nombre INTO v_antes FROM ecommerce.cuerpos
     WHERE principal AND deleted_at IS NULL AND id <> p_id;

    -- Primero se suelta el de antes: el índice único no admite dos
    UPDATE ecommerce.cuerpos SET principal = false
     WHERE principal AND deleted_at IS NULL AND id <> p_id;
    -- Y el nuevo se enciende: el principal siempre se ve
    UPDATE ecommerce.cuerpos SET principal = true, activo = true WHERE id = p_id;

    RETURN jsonb_build_object('success', true,
        'message', CASE WHEN v_antes IS NULL
                        THEN format('«%s» es la entrada de la tienda', v_nombre)
                        ELSE format('«%s» es la entrada de la tienda, en vez de «%s»', v_nombre, v_antes) END,
        'data', (ecommerce.fn_cuerpos_listar() -> 'data'));
END;
$function$;

-- ----------------------------------------------------------------------------
-- 9. ENCENDER Y APAGAR
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ecommerce.fn_cuerpos_activar(
    p_id             bigint,
    p_activo         boolean DEFAULT NULL,
    p_usuario_id     bigint  DEFAULT NULL,
    p_usuario_login  varchar DEFAULT NULL,
    p_usuario_nombre varchar DEFAULT NULL,
    p_ip_address     inet    DEFAULT NULL,
    p_user_agent     text    DEFAULT NULL,
    p_request_id     uuid    DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'ecommerce', 'auditoria'
AS $function$
DECLARE
    v_nombre    text;
    v_principal boolean;
    v_nuevo     boolean;
BEGIN
    PERFORM ecommerce.fn_contexto_auditoria('ecommerce.cuerpos',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    SELECT nombre, principal, COALESCE(p_activo, NOT activo)
      INTO v_nombre, v_principal, v_nuevo
      FROM ecommerce.cuerpos WHERE id = p_id AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Ese cuerpo no existe' USING ERRCODE = 'P0013';
    END IF;

    IF v_principal AND NOT v_nuevo THEN
        RAISE EXCEPTION 'No se puede apagar el cuerpo principal: la tienda se quedaría sin página de entrada. Pon otro como principal y entonces apaga éste'
              USING ERRCODE = 'P0015';
    END IF;

    UPDATE ecommerce.cuerpos SET activo = v_nuevo WHERE id = p_id;

    RETURN jsonb_build_object('success', true,
        'message', format('«%s» %s', v_nombre,
                          CASE WHEN v_nuevo THEN 'se ve en la tienda' ELSE 'ya no se ve' END),
        'data', ecommerce.fn_cuerpos_json(p_id));
END;
$function$;

-- ----------------------------------------------------------------------------
-- 10. PAPELERA
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ecommerce.fn_cuerpos_eliminar(
    p_id             bigint,
    p_usuario_id     bigint  DEFAULT NULL,
    p_usuario_login  varchar DEFAULT NULL,
    p_usuario_nombre varchar DEFAULT NULL,
    p_ip_address     inet    DEFAULT NULL,
    p_user_agent     text    DEFAULT NULL,
    p_request_id     uuid    DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'ecommerce', 'auditoria'
AS $function$
DECLARE
    v_nombre    text;
    v_principal boolean;
    v_cuantas   integer;
BEGIN
    PERFORM ecommerce.fn_contexto_auditoria('ecommerce.cuerpos',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    SELECT nombre, principal INTO v_nombre, v_principal
      FROM ecommerce.cuerpos WHERE id = p_id AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Ese cuerpo no existe' USING ERRCODE = 'P0013';
    END IF;
    IF v_principal THEN
        RAISE EXCEPTION 'No se puede borrar el cuerpo principal: es la página de entrada de la tienda'
              USING ERRCODE = 'P0015';
    END IF;

    SELECT count(*) INTO v_cuantas FROM ecommerce.inicio_secciones WHERE cuerpo_id = p_id;

    -- A la papelera, con sus secciones intactas: restaurar lo devuelve entero
    UPDATE ecommerce.cuerpos
       SET deleted_at = CURRENT_TIMESTAMP, deleted_by = p_usuario_login
     WHERE id = p_id;

    RETURN jsonb_build_object('success', true,
        'message', CASE v_cuantas
            WHEN 0 THEN format('Cuerpo «%s» enviado a la papelera', v_nombre)
            WHEN 1 THEN format('Cuerpo «%s» enviado a la papelera con su sección', v_nombre)
            ELSE format('Cuerpo «%s» enviado a la papelera con sus %s secciones', v_nombre, v_cuantas) END,
        'data', ecommerce.fn_cuerpos_json(p_id));
END;
$function$;

CREATE OR REPLACE FUNCTION ecommerce.fn_cuerpos_restaurar(
    p_id             bigint,
    p_usuario_id     bigint  DEFAULT NULL,
    p_usuario_login  varchar DEFAULT NULL,
    p_usuario_nombre varchar DEFAULT NULL,
    p_ip_address     inet    DEFAULT NULL,
    p_user_agent     text    DEFAULT NULL,
    p_request_id     uuid    DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'ecommerce', 'auditoria'
AS $function$
DECLARE
    v_nombre    text;
    v_ruta      text;
    v_categoria bigint;
    v_marca     bigint;
    v_fecha     timestamptz;
BEGIN
    PERFORM ecommerce.fn_contexto_auditoria('ecommerce.cuerpos',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    -- Campo a campo y no `SELECT * INTO` sobre un registro: si no hay fila, un
    -- registro sin asignar revienta con 55000 al mirarlo, y aquí hay que
    -- mirarlo para saber si está en la papelera
    SELECT nombre, ruta, categoria_id, marca_id, deleted_at
      INTO v_nombre, v_ruta, v_categoria, v_marca, v_fecha
      FROM ecommerce.cuerpos WHERE id = p_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Ese cuerpo no existe' USING ERRCODE = 'P0013';
    END IF;
    IF v_fecha IS NULL THEN
        RAISE EXCEPTION 'Ese cuerpo no está en la papelera' USING ERRCODE = 'P0019';
    END IF;

    -- Mientras estaba en la papelera pudieron coger su nombre, su dirección o
    -- su categoría: se comprueba otra vez y se dice cuál es el estorbo
    PERFORM ecommerce.fn_cuerpos_validar(p_id, v_nombre, v_ruta, v_categoria, v_marca);

    UPDATE ecommerce.cuerpos SET deleted_at = NULL, deleted_by = NULL WHERE id = p_id;

    RETURN jsonb_build_object('success', true,
        'message', format('Cuerpo «%s» restaurado', v_nombre),
        'data', ecommerce.fn_cuerpos_json(p_id));
END;
$function$;

-- Vacía la papelera ENTERA, sin ids: es lo que hace el botón del CRM.
CREATE OR REPLACE FUNCTION ecommerce.fn_cuerpos_papelera_vaciar(
    p_usuario_id     bigint  DEFAULT NULL,
    p_usuario_login  varchar DEFAULT NULL,
    p_usuario_nombre varchar DEFAULT NULL,
    p_ip_address     inet    DEFAULT NULL,
    p_user_agent     text    DEFAULT NULL,
    p_request_id     uuid    DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'ecommerce', 'auditoria'
AS $function$
DECLARE
    v_cuerpos   integer := 0;
    v_secciones integer := 0;
    v_galerias  bigint[];
BEGIN
    PERFORM ecommerce.fn_contexto_auditoria('ecommerce.cuerpos',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    SELECT count(*) INTO v_secciones FROM ecommerce.inicio_secciones s
      JOIN ecommerce.cuerpos c ON c.id = s.cuerpo_id
     WHERE c.deleted_at IS NOT NULL;

    -- Las galerías de sus banners se van a mano: la sección apunta a la
    -- galería y no al revés, así que el CASCADE no las alcanza y se quedarían
    -- ahí para siempre, sin dueño y sin pantalla desde donde borrarlas.
    --
    -- En cuatro órdenes seguidas y no en un WITH con varios DELETE: las ramas
    -- de un WITH se ejecutan en el orden que quiera el motor, y aquí el orden
    -- es lo único que impide que la galería se vaya antes que quien la
    -- referencia.
    v_galerias := ARRAY(SELECT DISTINCT s.galeria_id
                          FROM ecommerce.inicio_secciones s
                          JOIN ecommerce.cuerpos c ON c.id = s.cuerpo_id
                         WHERE c.deleted_at IS NOT NULL AND s.galeria_id IS NOT NULL);

    DELETE FROM ecommerce.galerias_imagenes WHERE galeria_id = ANY (v_galerias);

    DELETE FROM ecommerce.inicio_secciones s
     USING ecommerce.cuerpos c
     WHERE c.id = s.cuerpo_id AND c.deleted_at IS NOT NULL;

    DELETE FROM ecommerce.galerias WHERE id = ANY (v_galerias);

    DELETE FROM ecommerce.cuerpos WHERE deleted_at IS NOT NULL;
    GET DIAGNOSTICS v_cuerpos = ROW_COUNT;

    RETURN jsonb_build_object('success', true,
        'message', CASE WHEN v_cuerpos = 0 THEN 'La papelera ya estaba vacía'
                        ELSE format('Borrados %s cuerpo(s) con sus %s sección(es)', v_cuerpos, v_secciones) END,
        'data', (ecommerce.fn_cuerpos_papelera_listar() -> 'data'));
END;
$function$;

-- ----------------------------------------------------------------------------
-- 11. LAS DOS FUNCIONES QUE METEN FILAS EN UNA PÁGINA
-- ----------------------------------------------------------------------------
-- Se arreglan AQUÍ y no en el fichero siguiente porque este mismo cambio las
-- rompe: insertaban sin cuerpo (ahora obligatorio) y una de ellas resolvía el
-- choque `ON CONFLICT (clave)`, que ya no es un índice.
--
-- EL BANNER nace en el cuerpo que se le diga —el que se esté mirando—, que es
-- donde se pulsó «Banner».
--
-- EL ESCAPARATE YA NO NACE EN NINGUNA PÁGINA. Antes, crear una sección de
-- productos la metía sola al final de la portada; ahora se crea en «Productos
-- por sección» y se añade a mano, con «Escaparate», a las páginas donde se
-- quiera —la principal incluida—. Son dos decisiones distintas —qué productos
-- van juntos, y en qué páginas sale ese grupo— y con el añadido automático la
-- segunda estaba tomada de antemano: lo nuevo aparecía en la portada aunque se
-- estuviera armando para otra página.
CREATE OR REPLACE FUNCTION ecommerce.fn_inicio_banner_crear(
    p_nombre         text,
    p_usuario_id     bigint  DEFAULT NULL,
    p_usuario_login  varchar DEFAULT NULL,
    p_usuario_nombre varchar DEFAULT NULL,
    p_ip_address     inet    DEFAULT NULL,
    p_user_agent     text    DEFAULT NULL,
    p_request_id     uuid    DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'ecommerce', 'auditoria'
AS $function$
DECLARE
    v_nombre  text;
    v_galeria bigint;
    v_orden   integer;
    v_cuerpo  bigint := ecommerce.fn_cuerpo_principal_id();
BEGIN
    PERFORM ecommerce.fn_contexto_auditoria('ecommerce.inicio_secciones',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    v_nombre := ecommerce.fn_validar_texto(p_nombre, 'El nombre del banner', 100);
    IF v_nombre IS NULL THEN
        RAISE EXCEPTION 'Hace falta el nombre del banner' USING ERRCODE = 'P0001';
    END IF;

    -- El id se pide antes para poder meterlo en la clave: así la galería de un
    -- banner se reconoce de un vistazo y nunca choca con otra
    v_galeria := nextval('ecommerce.galerias_id_seq');

    INSERT INTO ecommerce.galerias (id, clave, nombre, descripcion, tipo, maximo)
    VALUES (v_galeria, 'inicio_banner_' || v_galeria, v_nombre,
            'Inicio: banner simple (rota; cada imagen con su vigencia).', 'banner', 10);

    -- El orden es DENTRO del cuerpo: cada uno tiene su primera y su última
    SELECT COALESCE(max(orden), 0) + 1 INTO v_orden
      FROM ecommerce.inicio_secciones WHERE cuerpo_id = v_cuerpo;

    -- Nace APAGADA: se enciende cuando tenga imágenes. Encendida y vacía la
    -- tienda se la salta igual, pero la lista diría que está en la portada.
    INSERT INTO ecommerce.inicio_secciones (cuerpo_id, clave, nombre, galeria_id, orden, activo)
    VALUES (v_cuerpo, 'banner_' || v_galeria, v_nombre, v_galeria, v_orden, false);

    -- Se devuelve la lista entera y nada más, como el resto: la respuesta HTTP
    -- de la casa sólo lleva `message` y `data`, así que una clave suelta aquí
    -- no llegaría a ninguna parte. Quien necesite saber cuál es la nueva la
    -- reconoce porque antes no estaba.
    RETURN jsonb_build_object('success', true,
        'message', format('Banner «%s» creado', v_nombre),
        'data', (ecommerce.fn_inicio_listar() -> 'data'));
END;
$function$;

CREATE OR REPLACE FUNCTION ecommerce.fn_producto_secciones_crear(
    p_nombre         varchar,
    p_desde          timestamptz DEFAULT NULL,
    p_hasta          timestamptz DEFAULT NULL,
    p_usuario_id     bigint      DEFAULT NULL,
    p_usuario_login  varchar     DEFAULT NULL,
    p_usuario_nombre varchar     DEFAULT NULL,
    p_ip_address     inet        DEFAULT NULL,
    p_user_agent     text        DEFAULT NULL,
    p_request_id     uuid        DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'ecommerce', 'auditoria'
AS $function$
DECLARE
    v_id bigint;
BEGIN
    PERFORM ecommerce.fn_contexto_auditoria('ecommerce.producto_secciones',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    PERFORM ecommerce.fn_producto_secciones_validar(NULL, p_nombre, p_desde, p_hasta);

    INSERT INTO ecommerce.producto_secciones (nombre, desde, hasta, orden)
    VALUES (btrim(p_nombre), p_desde, p_hasta,
            (SELECT COALESCE(max(orden), 0) + 1 FROM ecommerce.producto_secciones
              WHERE deleted_at IS NULL))
    RETURNING id INTO v_id;

    -- AQUÍ NO SE LE DA SITIO EN NINGUNA PÁGINA, y es lo que cambió: el
    -- escaparate se arma aquí y se añade donde se quiera con «Escaparate»
    -- (fn_inicio_escaparate_poner), en la principal igual que en las demás.
    RETURN jsonb_build_object('success', true,
        'message', format('Sección «%s» creada. Añádela a las páginas donde quieras que salga', btrim(p_nombre)),
        'data', ecommerce.fn_producto_secciones_json(v_id));
END;
$function$;

-- ----------------------------------------------------------------------------
-- 12. COMPROBACIÓN
-- ----------------------------------------------------------------------------
-- Todo dentro de una subtransacción que se deshace: la base queda como estaba.
DO $comprobar$
DECLARE
    v_principal bigint;
    v_nuevo     jsonb;
    v_id        bigint;
    v_malo      text;
    v_lista     jsonb;
BEGIN
    v_principal := ecommerce.fn_cuerpo_principal_id();
    IF v_principal IS NULL THEN
        RAISE EXCEPTION 'No hay cuerpo principal: la tienda no tendría de dónde sacar la portada';
    END IF;
    IF EXISTS (SELECT 1 FROM ecommerce.inicio_secciones WHERE cuerpo_id IS NULL) THEN
        RAISE EXCEPTION 'Quedan secciones sin cuerpo';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_indexes
                    WHERE schemaname = 'ecommerce' AND indexname = 'uq_inicio_secciones_cuerpo_clave') THEN
        RAISE EXCEPTION 'Falta el índice de clave por cuerpo';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_indexes
                WHERE schemaname = 'ecommerce' AND indexname = 'uq_inicio_secciones_clave') THEN
        RAISE EXCEPTION 'El índice viejo de clave única sigue ahí: la clave no podría repetirse entre cuerpos';
    END IF;

    BEGIN
        -- Uno nuevo, suelto
        v_nuevo := ecommerce.fn_cuerpos_guardar(NULL, jsonb_build_object(
                       'nombre', 'ZZ prueba claude', 'ruta', 'zz-prueba-claude',
                       'titulo', 'Prueba', 'catalogo', true));
        v_id := (v_nuevo -> 'data' ->> 'id')::bigint;
        IF v_id IS NULL THEN
            RAISE EXCEPTION 'No devolvió el cuerpo creado: %', v_nuevo;
        END IF;
        IF v_nuevo -> 'data' ->> 'url' <> '/zz-prueba-claude' THEN
            RAISE EXCEPTION 'La dirección del secundario tiene que ser /su-ruta: %', v_nuevo -> 'data' -> 'url';
        END IF;
        IF v_nuevo -> 'data' ->> 'destino' <> 'libre' THEN
            RAISE EXCEPTION 'Sin categoría ni marca, el destino es «libre»: %', v_nuevo -> 'data' -> 'destino';
        END IF;
        IF (v_nuevo -> 'data' ->> 'secciones')::integer <> 0 THEN
            RAISE EXCEPTION 'Un cuerpo nuevo nace sin secciones: %', v_nuevo -> 'data' -> 'secciones';
        END IF;

        -- El principal se ve en la raíz
        IF ecommerce.fn_cuerpos_json(v_principal) ->> 'url' <> '/' THEN
            RAISE EXCEPTION 'El principal vive en la raíz: %', ecommerce.fn_cuerpos_json(v_principal) -> 'url';
        END IF;

        -- La dirección no se puede repetir
        BEGIN
            PERFORM ecommerce.fn_cuerpos_guardar(NULL, jsonb_build_object(
                'nombre', 'ZZ otro claude', 'ruta', 'zz-prueba-claude'));
            v_malo := 'entraron dos cuerpos en la misma dirección';
        EXCEPTION WHEN SQLSTATE 'P0015' THEN NULL;
        END;

        -- Ni ser una pantalla de la tienda
        BEGIN
            PERFORM ecommerce.fn_cuerpos_guardar(NULL, jsonb_build_object(
                'nombre', 'ZZ shop claude', 'ruta', 'shop'));
            v_malo := COALESCE(v_malo, 'entró un cuerpo en /shop, que es una pantalla de la tienda');
        EXCEPTION WHEN SQLSTATE 'P0015' THEN NULL;
        END;

        -- Ni llevar tilde o espacio
        BEGIN
            PERFORM ecommerce.fn_cuerpos_guardar(NULL, jsonb_build_object(
                'nombre', 'ZZ tilde claude', 'ruta', 'línea blanca'));
            v_malo := COALESCE(v_malo, 'entró una dirección con tilde y espacio');
        EXCEPTION WHEN SQLSTATE 'P0015' THEN NULL;
        END;

        -- El principal no se apaga ni se borra
        BEGIN
            PERFORM ecommerce.fn_cuerpos_activar(v_principal, false);
            v_malo := COALESCE(v_malo, 'se pudo apagar el cuerpo principal');
        EXCEPTION WHEN SQLSTATE 'P0015' THEN NULL;
        END;
        BEGIN
            PERFORM ecommerce.fn_cuerpos_eliminar(v_principal);
            v_malo := COALESCE(v_malo, 'se pudo borrar el cuerpo principal');
        EXCEPTION WHEN SQLSTATE 'P0015' THEN NULL;
        END;

        -- Cambiar de principal deja UNO solo
        PERFORM ecommerce.fn_cuerpos_principal(v_id);
        IF (SELECT count(*) FROM ecommerce.cuerpos WHERE principal AND deleted_at IS NULL) <> 1 THEN
            RAISE EXCEPTION 'Tras cambiar de principal no queda exactamente uno';
        END IF;
        IF ecommerce.fn_cuerpo_principal_id() <> v_id THEN
            RAISE EXCEPTION 'El principal no es el que se marcó';
        END IF;
        -- Y el de antes vuelve a su dirección propia
        IF ecommerce.fn_cuerpos_json(v_principal) ->> 'url' = '/' THEN
            RAISE EXCEPTION 'El que dejó de ser principal sigue en la raíz';
        END IF;
        PERFORM ecommerce.fn_cuerpos_principal(v_principal);

        -- A la papelera y de vuelta
        PERFORM ecommerce.fn_cuerpos_eliminar(v_id);
        v_lista := ecommerce.fn_cuerpos_listar() -> 'data';
        IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_lista) c
                    WHERE (c ->> 'id')::bigint = v_id) THEN
            RAISE EXCEPTION 'El cuerpo de la papelera sigue en la lista';
        END IF;
        IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(ecommerce.fn_cuerpos_papelera_listar() -> 'data') c
                        WHERE (c ->> 'id')::bigint = v_id) THEN
            RAISE EXCEPTION 'El cuerpo no apareció en la papelera';
        END IF;
        -- Con él en la papelera, su dirección se puede volver a usar
        PERFORM ecommerce.fn_cuerpos_guardar(NULL, jsonb_build_object(
            'nombre', 'ZZ reusa claude', 'ruta', 'zz-prueba-claude'));
        -- Y entonces restaurarlo tiene que quejarse, no reventar por el índice
        BEGIN
            PERFORM ecommerce.fn_cuerpos_restaurar(v_id);
            v_malo := COALESCE(v_malo, 'se restauró un cuerpo con la dirección ya cogida');
        EXCEPTION WHEN SQLSTATE 'P0015' THEN NULL;
        END;

        RAISE EXCEPTION 'deshacer' USING ERRCODE = 'P0099';
    EXCEPTION WHEN SQLSTATE 'P0099' THEN
        NULL;
    END;

    IF v_malo IS NOT NULL THEN
        RAISE EXCEPTION '%', v_malo;
    END IF;
    IF EXISTS (SELECT 1 FROM ecommerce.cuerpos WHERE nombre LIKE 'ZZ %claude') THEN
        RAISE EXCEPTION 'Los cuerpos de prueba se quedaron en la base';
    END IF;
    IF ecommerce.fn_cuerpo_principal_id() <> v_principal THEN
        RAISE EXCEPTION 'El principal cambió y no volvió a su sitio';
    END IF;
    -- Crear un escaparate ya no le da sitio en ninguna página: se añade a mano
    IF EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                WHERE n.nspname = 'ecommerce' AND p.proname = 'fn_producto_secciones_crear'
                  AND pg_get_functiondef(p.oid) LIKE '%INSERT INTO ecommerce.inicio_secciones%') THEN
        RAISE EXCEPTION 'Crear un escaparate sigue metiéndolo solo en una página';
    END IF;

    RAISE NOTICE 'Comprobado: el principal vive en /, un secundario en /su-ruta, la dirección no se repite ni pisa una pantalla de la tienda, el principal no se apaga ni se borra, cambiar de principal deja uno solo y la papelera devuelve el cuerpo entero. No quedó nada.';
END
$comprobar$;

COMMIT;
