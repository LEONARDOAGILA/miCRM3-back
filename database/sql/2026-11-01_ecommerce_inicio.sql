-- ============================================================================
-- ECOMMERCE · LA PORTADA DE LA TIENDA
-- ============================================================================
-- Fecha: 2026-11-01
--
-- La portada no es una página: es una LISTA DE SECCIONES que marketing
-- enciende, apaga y reordena —banner, categorías destacadas, ofertas de la
-- semana, mosaico, marcas—. Cada una saca sus datos de otro sitio; aquí sólo
-- se guarda cuáles hay, en qué orden van y si se ven.
--
-- LAS SECCIONES NO SE CREAN NI SE BORRAN desde el CRM, igual que las galerías:
-- cada una existe porque la tienda sabe pintarla. Lo que se administra es su
-- orden, su título y su vigencia.
--
-- SE SIRVE LO QUE HAY, Y YA. De las ocho secciones, hoy sólo tienen de dónde
-- sacar datos las dos de banner, porque el resto tira de cosas que todavía no
-- están trasladadas:
--
--     banner_principal        galería inicio_banner            LISTA
--     banner_simple           galería inicio_banner_simple     LISTA
--     categorias_destacadas   falta la marca de «destacada»    pendiente
--     mosaico                 falta el orden del mosaico       pendiente
--     ofertas_flash           CATÁLOGO (precio y existencias)  pendiente
--     grilla                  CATÁLOGO                          pendiente
--     bloques                 tabla bloque_producto             pendiente
--     marcas                  tabla marca_web                   pendiente
--
-- Y eso NO es un apaño: es como está diseñada la tienda. Su propio código lo
-- dice —«una clave desconocida se ignora», «sólo las secciones visibles»— y
-- el CRM viejo ya se saltaba la sección que no tuviera nada que enseñar. La
-- portada irá creciendo sola según se migre cada fuente, sin tocar esto.
--
-- Idempotente.
-- ============================================================================
\set ON_ERROR_STOP on

BEGIN;

-- ----------------------------------------------------------------------------
-- 1. LA TABLA
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS ecommerce.inicio_secciones (
    id          bigint       NOT NULL,
    -- Con la que la tienda sabe cuál es. No se cambia: está en su código.
    clave       varchar(50)  NOT NULL,
    nombre      varchar(100) NOT NULL,
    -- Lo que se lee encima de la sección, cuando lleva
    titulo      varchar(80),
    subtitulo   varchar(80),
    orden       integer      NOT NULL DEFAULT 0,
    activo      boolean      NOT NULL DEFAULT true,
    -- Vigencia: para dejar preparada la sección de navidad y que se apague sola
    desde       timestamptz,
    hasta       timestamptz,
    created_at  timestamptz  NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at  timestamptz  NOT NULL DEFAULT CURRENT_TIMESTAMP,
    created_by  varchar(100),
    updated_by  varchar(100),
    CONSTRAINT pk_inicio_secciones PRIMARY KEY (id),
    CONSTRAINT ck_inicio_secciones_clave CHECK (clave ~ '^[a-z0-9_]+$'),
    CONSTRAINT ck_inicio_secciones_vigencia
        CHECK (desde IS NULL OR hasta IS NULL OR hasta >= desde)
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_inicio_secciones_clave ON ecommerce.inicio_secciones (clave);

CREATE SEQUENCE IF NOT EXISTS ecommerce.inicio_secciones_id_seq OWNED BY ecommerce.inicio_secciones.id;
ALTER TABLE ecommerce.inicio_secciones ALTER COLUMN id SET DEFAULT nextval('ecommerce.inicio_secciones_id_seq');

DO $disparadores$
BEGIN
    DROP TRIGGER IF EXISTS trg_inicio_secciones_audit ON ecommerce.inicio_secciones;
    CREATE TRIGGER trg_inicio_secciones_audit AFTER INSERT OR UPDATE OR DELETE
        ON ecommerce.inicio_secciones FOR EACH ROW EXECUTE FUNCTION auditoria.fn_auditar_cambios();
    DROP TRIGGER IF EXISTS trg_inicio_secciones_updated_at ON ecommerce.inicio_secciones;
    CREATE TRIGGER trg_inicio_secciones_updated_at BEFORE UPDATE
        ON ecommerce.inicio_secciones FOR EACH ROW EXECUTE FUNCTION auditoria.fn_update_updated_at_column();
    DROP TRIGGER IF EXISTS trg_inicio_secciones_users ON ecommerce.inicio_secciones;
    CREATE TRIGGER trg_inicio_secciones_users BEFORE INSERT OR UPDATE
        ON ecommerce.inicio_secciones FOR EACH ROW EXECUTE FUNCTION auditoria.fn_set_audit_users();
END
$disparadores$;

-- ----------------------------------------------------------------------------
-- 2. EL DATO QUE YA ESTÁ
-- ----------------------------------------------------------------------------
DO $copiar$
DECLARE
    v integer := 0;
BEGIN
    IF to_regclass('ecommerce.inicio_seccion') IS NULL THEN
        RAISE NOTICE 'La tabla vieja ya no está: el dato ya se copió.';
        RETURN;
    END IF;

    INSERT INTO ecommerce.inicio_secciones (clave, nombre, titulo, subtitulo, orden, activo, desde, hasta, updated_at)
    SELECT s.ise_clave, s.ise_nombre, s.ise_titulo, s.ise_subtitulo,
           s.ise_orden, s.ise_activo, s.ise_desde, s.ise_hasta,
           COALESCE(s.ise_fecha_modificacion, CURRENT_TIMESTAMP)
      FROM ecommerce.inicio_seccion s
     ON CONFLICT (clave) DO NOTHING;
    GET DIAGNOSTICS v = ROW_COUNT;

    RAISE NOTICE 'Copiadas % secciones de la portada.', v;
END
$copiar$;

-- ----------------------------------------------------------------------------
-- 3. LA PORTADA QUE LEE LA TIENDA
-- ----------------------------------------------------------------------------
-- Devuelve SÓLO las secciones visibles —encendidas y en vigencia— que de
-- verdad tienen algo que enseñar. Una sección encendida pero vacía no sale:
-- dejaría un hueco con su título y nada debajo.
CREATE OR REPLACE FUNCTION ecommerce.fn_inicio_publico()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
AS $function$
    WITH visibles AS (
        SELECT s.clave, s.titulo, s.subtitulo, s.hasta, s.orden
          FROM ecommerce.inicio_secciones s
         WHERE s.activo AND ecommerce.fn_vigente(s.desde, s.hasta)
    ),
    armadas AS (
        SELECT v.orden, v.clave,
               CASE v.clave
                   -- Los dos banners salen de su galería. `imagenes` trae el
                   -- NOMBRE del fichero; el controlador le pone la dirección.
                   WHEN 'banner_principal' THEN
                        jsonb_build_object('clave', v.clave,
                            'imagenes', COALESCE(ecommerce.fn_galerias_publica('inicio_banner') -> 'imagenes', '[]'::jsonb))
                   WHEN 'banner_simple' THEN
                        jsonb_build_object('clave', v.clave,
                            'imagenes', COALESCE(ecommerce.fn_galerias_publica('inicio_banner_simple') -> 'imagenes', '[]'::jsonb))
                   -- Las demás todavía no tienen de dónde sacar datos (ver la
                   -- cabecera del fichero). Se devuelven como NULL y se caen
                   -- en el filtro de abajo; la tienda ni se entera.
                   ELSE NULL
               END AS seccion
          FROM visibles v
    )
    SELECT jsonb_build_object('secciones', COALESCE(jsonb_agg(a.seccion ORDER BY a.orden), '[]'::jsonb))
      FROM armadas a
     WHERE a.seccion IS NOT NULL
       -- Y si la sección se quedó sin contenido, tampoco sale
       AND (a.seccion -> 'imagenes' IS NULL OR jsonb_array_length(a.seccion -> 'imagenes') > 0);
$function$;

-- ----------------------------------------------------------------------------
-- 4. QUE DEVUELVA ALGO Y CON LA FORMA BUENA
-- ----------------------------------------------------------------------------
DO $comprobar$
DECLARE
    v jsonb;
    v_n integer;
BEGIN
    SELECT count(*) INTO v_n FROM ecommerce.inicio_secciones;
    IF v_n = 0 THEN
        RAISE EXCEPTION 'No quedó ninguna sección de portada';
    END IF;

    v := ecommerce.fn_inicio_publico();

    IF v -> 'secciones' IS NULL OR jsonb_typeof(v -> 'secciones') <> 'array' THEN
        RAISE EXCEPTION 'La portada no devuelve una lista de secciones';
    END IF;

    -- Toda sección que salga tiene que traer su clave: sin ella la tienda la
    -- descarta y el hueco no se ve venir
    IF EXISTS (SELECT 1 FROM jsonb_array_elements(v -> 'secciones') s
                WHERE COALESCE(s ->> 'clave', '') = '') THEN
        RAISE EXCEPTION 'Hay secciones sin clave';
    END IF;

    RAISE NOTICE 'Portada: % secciones configuradas, % con contenido hoy.',
          v_n, jsonb_array_length(v -> 'secciones');
END
$comprobar$;

-- ----------------------------------------------------------------------------
-- 5. FUERA LA VIEJA
-- ----------------------------------------------------------------------------
DO $limpiar$
DECLARE
    r record;
BEGIN
    FOR r IN SELECT p.oid::regprocedure::text AS firma
               FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
              WHERE n.nspname = 'ecommerce' AND p.prokind = 'f'
                AND p.proname LIKE 'fn\_inicio\_seccion\_%' LOOP
        EXECUTE 'DROP FUNCTION IF EXISTS ' || r.firma;
    END LOOP;

    DROP TABLE IF EXISTS ecommerce.inicio_seccion;
    RAISE NOTICE 'Borrada la tabla vieja de secciones de portada.';
END
$limpiar$;

COMMIT;
