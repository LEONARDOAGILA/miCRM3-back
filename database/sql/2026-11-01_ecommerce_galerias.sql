-- ============================================================================
-- ECOMMERCE · GALERÍAS DE IMÁGENES
-- ============================================================================
-- Fecha: 2026-11-01
--
-- Son los bloques de imágenes repartidos por la tienda: el banner del inicio,
-- las tarjetas de España Motos, los logos de «dónde pagar» del pie, las fotos
-- de cada marca. Trece galerías con diecinueve imágenes.
--
-- LA GALERÍA ES UN SITIO, NO UN CONTENIDO. Cada una tiene una CLAVE fija
-- (`inicio_banner`, `pagos_tarjetas`) con la que la tienda la pide, y existe
-- porque hay un hueco en el diseño esperándola. Por eso las galerías no se
-- crean ni se borran desde el CRM: se crean con la pantalla que las usa. Lo
-- que se administra son sus IMÁGENES.
--
-- CADA IMAGEN PUEDE TENER:
--   · una versión para móvil aparte, porque un banner apaisado no se ve en un
--     teléfono;
--   · un enlace a donde lleva al pincharla;
--   · VIGENCIA (desde / hasta): así se deja preparada la promoción de
--     diciembre en noviembre y se apaga sola en enero, sin que nadie entre a
--     borrarla el día 1;
--   · y, en las galerías de tipo tarjeta, su título, subtítulo, color y botón.
--
-- Igual que en las páginas informativas, las imágenes se guardaban con la
-- dirección ABSOLUTA dentro (con el servidor y todo). Aquí se guarda sólo el
-- nombre del fichero y la dirección la arma el controlador.
--
-- Al final se borran las tablas y funciones viejas.
-- Idempotente.
-- ============================================================================
\set ON_ERROR_STOP on

BEGIN;

-- ----------------------------------------------------------------------------
-- 1. LAS TABLAS
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS ecommerce.galerias (
    id          bigint       NOT NULL,
    -- Con la que la pide la tienda. No se cambia: está escrita en su código.
    clave       varchar(50)  NOT NULL,
    nombre      varchar(80)  NOT NULL,
    descripcion varchar(200),
    -- 'banner', 'tarjetas', 'fotos'… lo que decide cómo se pinta
    tipo        varchar(20),
    -- Cuántas enseñar como mucho (null = todas) y cuántas se pueden cargar
    mostrar     integer,
    maximo      integer,
    created_at  timestamptz  NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at  timestamptz  NOT NULL DEFAULT CURRENT_TIMESTAMP,
    created_by  varchar(100),
    updated_by  varchar(100),
    CONSTRAINT pk_galerias PRIMARY KEY (id),
    CONSTRAINT ck_galerias_clave CHECK (clave ~ '^[a-z0-9_]+$')
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_galerias_clave ON ecommerce.galerias (clave);

CREATE SEQUENCE IF NOT EXISTS ecommerce.galerias_id_seq OWNED BY ecommerce.galerias.id;
ALTER TABLE ecommerce.galerias ALTER COLUMN id SET DEFAULT nextval('ecommerce.galerias_id_seq');

CREATE TABLE IF NOT EXISTS ecommerce.galerias_imagenes (
    id            bigint       NOT NULL,
    galeria_id    bigint       NOT NULL,
    -- SÓLO EL NOMBRE del fichero; la dirección la arma el controlador
    imagen        varchar(200) NOT NULL,
    imagen_movil  varchar(200),
    -- Lo que se lee en voz alta si no carga
    nombre        varchar(100),
    enlace        varchar(250),
    nueva_pestana boolean      NOT NULL DEFAULT false,
    -- Donde se ensena. El vocabulario lo pone la tienda, que es quien lo
    -- pinta: 'todos', 'computadora' o 'celular'.
    mostrar_en    varchar(12)  NOT NULL DEFAULT 'todos',
    -- Vigencia; null por los dos lados = siempre
    desde         timestamptz,
    hasta         timestamptz,
    titulo        varchar(40),
    subtitulo     varchar(80),
    color         varchar(10),
    boton         varchar(20),
    orden         integer      NOT NULL DEFAULT 0,
    activo        boolean      NOT NULL DEFAULT true,
    created_at    timestamptz  NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at    timestamptz  NOT NULL DEFAULT CURRENT_TIMESTAMP,
    created_by    varchar(100),
    updated_by    varchar(100),
    deleted_at    timestamptz,
    deleted_by    varchar(100),
    CONSTRAINT pk_galerias_imagenes PRIMARY KEY (id),
    CONSTRAINT fk_galerias_imagenes_galeria
        FOREIGN KEY (galeria_id) REFERENCES ecommerce.galerias(id),
    CONSTRAINT ck_galerias_imagenes_mostrar_en
        CHECK (mostrar_en IN ('todos', 'computadora', 'celular')),
    -- Una vigencia al revés no se ve nunca, y nadie entiende por qué
    CONSTRAINT ck_galerias_imagenes_vigencia
        CHECK (desde IS NULL OR hasta IS NULL OR hasta >= desde)
);

CREATE SEQUENCE IF NOT EXISTS ecommerce.galerias_imagenes_id_seq
    OWNED BY ecommerce.galerias_imagenes.id;
ALTER TABLE ecommerce.galerias_imagenes
    ALTER COLUMN id SET DEFAULT nextval('ecommerce.galerias_imagenes_id_seq');

CREATE INDEX IF NOT EXISTS ix_galerias_imagenes_galeria
    ON ecommerce.galerias_imagenes (galeria_id);
CREATE INDEX IF NOT EXISTS ix_galerias_imagenes_deleted_at
    ON ecommerce.galerias_imagenes (deleted_at) WHERE deleted_at IS NOT NULL;

DO $disparadores$
DECLARE
    t text;
BEGIN
    FOREACH t IN ARRAY ARRAY['galerias', 'galerias_imagenes'] LOOP
        EXECUTE format('DROP TRIGGER IF EXISTS trg_%1$s_audit ON ecommerce.%1$I', t);
        EXECUTE format('CREATE TRIGGER trg_%1$s_audit AFTER INSERT OR UPDATE OR DELETE ON ecommerce.%1$I
                        FOR EACH ROW EXECUTE FUNCTION auditoria.fn_auditar_cambios()', t);
        EXECUTE format('DROP TRIGGER IF EXISTS trg_%1$s_updated_at ON ecommerce.%1$I', t);
        EXECUTE format('CREATE TRIGGER trg_%1$s_updated_at BEFORE UPDATE ON ecommerce.%1$I
                        FOR EACH ROW EXECUTE FUNCTION auditoria.fn_update_updated_at_column()', t);
        EXECUTE format('DROP TRIGGER IF EXISTS trg_%1$s_users ON ecommerce.%1$I', t);
        EXECUTE format('CREATE TRIGGER trg_%1$s_users BEFORE INSERT OR UPDATE ON ecommerce.%1$I
                        FOR EACH ROW EXECUTE FUNCTION auditoria.fn_set_audit_users()', t);
    END LOOP;
END
$disparadores$;

-- ----------------------------------------------------------------------------
-- 2. EL DATO QUE YA ESTÁ
-- ----------------------------------------------------------------------------
DO $copiar$
DECLARE
    v_g integer := 0;
    v_i integer := 0;
BEGIN
    IF to_regclass('ecommerce.galeria') IS NULL THEN
        RAISE NOTICE 'Las tablas viejas ya no están: el dato ya se copió.';
        RETURN;
    END IF;

    INSERT INTO ecommerce.galerias (id, clave, nombre, descripcion, tipo, mostrar, maximo)
    SELECT g.gal_id, g.gal_clave, g.gal_nombre, g.gal_descripcion, g.gal_tipo, g.gal_mostrar, g.gal_maximo
      FROM ecommerce.galeria g
     ON CONFLICT (id) DO NOTHING;
    GET DIAGNOSTICS v_g = ROW_COUNT;

    INSERT INTO ecommerce.galerias_imagenes
           (id, galeria_id, imagen, imagen_movil, nombre, enlace, nueva_pestana,
            mostrar_en, desde, hasta, titulo, subtitulo, color, boton, orden, activo,
            created_at, updated_at, deleted_at)
    SELECT i.gim_id, i.gal_id,
           -- Sólo el nombre del fichero: fuera el servidor y la ruta
           regexp_replace(i.gim_imagen, '^.*/', ''),
           regexp_replace(i.gim_imagen_movil, '^.*/', ''),
           i.gim_nombre, i.gim_enlace, i.gim_nueva_pestana,
           COALESCE(NULLIF(i.gim_mostrar_en, ''), 'todos'),
           i.gim_desde, i.gim_hasta, i.gim_titulo, i.gim_subtitulo, i.gim_color, i.gim_boton,
           i.gim_orden, i.gim_activo,
           i.gim_fecha_creacion, COALESCE(i.gim_fecha_modificacion, i.gim_fecha_creacion),
           i.gim_eliminado_en
      FROM ecommerce.galeria_imagen i
     ON CONFLICT (id) DO NOTHING;
    GET DIAGNOSTICS v_i = ROW_COUNT;

    PERFORM setval('ecommerce.galerias_id_seq',
                   GREATEST((SELECT COALESCE(max(id), 0) FROM ecommerce.galerias), 1));
    PERFORM setval('ecommerce.galerias_imagenes_id_seq',
                   GREATEST((SELECT COALESCE(max(id), 0) FROM ecommerce.galerias_imagenes), 1));

    RAISE NOTICE 'Copiadas % galerías y % imágenes.', v_g, v_i;
END
$copiar$;

-- ----------------------------------------------------------------------------
-- 3. LO QUE LEE LA TIENDA
-- ----------------------------------------------------------------------------
-- Una imagen está VIGENTE si no tiene fechas, o si hoy cae dentro de ellas.
-- Se mira contra la hora de la base y no contra la del navegador: la de quien
-- mira puede estar en cualquier sitio, y la promoción empieza cuando lo diga
-- el servidor.
CREATE OR REPLACE FUNCTION ecommerce.fn_vigente(p_desde timestamptz, p_hasta timestamptz)
 RETURNS boolean
 LANGUAGE sql
 STABLE
AS $function$
    SELECT (p_desde IS NULL OR CURRENT_TIMESTAMP >= p_desde)
       AND (p_hasta IS NULL OR CURRENT_TIMESTAMP <= p_hasta);
$function$;

CREATE OR REPLACE FUNCTION ecommerce.fn_galerias_publica(p_clave text)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
AS $function$
    -- NULL si la clave no existe: el controlador lo convierte en 404, que no
    -- es lo mismo que una galería que existe y está vacía.
    SELECT CASE WHEN g.id IS NULL THEN NULL ELSE
        jsonb_build_object(
            'clave',  g.clave,
            'nombre', g.nombre,
            'tipo',   g.tipo,
            'imagenes', COALESCE((
                SELECT jsonb_agg(jsonb_build_object(
                           'imagen',        i.imagen,
                           'imagen_movil',  i.imagen_movil,
                           'nombre',        i.nombre,
                           'enlace',        i.enlace,
                           'nueva_pestana', i.nueva_pestana,
                           'mostrar_en',    i.mostrar_en,
                           'titulo',        i.titulo,
                           'subtitulo',     i.subtitulo,
                           'color',         i.color,
                           'boton',         i.boton)
                       ORDER BY i.orden, i.id)
                  FROM (SELECT * FROM ecommerce.galerias_imagenes x
                         WHERE x.galeria_id = g.id
                           AND x.deleted_at IS NULL
                           AND x.activo
                           AND ecommerce.fn_vigente(x.desde, x.hasta)
                         ORDER BY x.orden, x.id
                         -- `mostrar` null = todas
                         LIMIT g.mostrar) i), '[]'::jsonb))
        END
      FROM (SELECT * FROM ecommerce.galerias WHERE clave = p_clave) g
     RIGHT JOIN (SELECT 1) u ON true;
$function$;

-- ----------------------------------------------------------------------------
-- 4. QUE DE VERDAD DEVUELVA LO QUE PIDE LA TIENDA
-- ----------------------------------------------------------------------------
DO $comprobar$
DECLARE
    v jsonb;
    v_n integer;
BEGIN
    SELECT count(*) INTO v_n FROM ecommerce.galerias;
    IF v_n = 0 THEN
        RAISE EXCEPTION 'No quedó ninguna galería';
    END IF;

    -- Las dos del pie, que son las que hoy dan 404
    FOR v IN SELECT ecommerce.fn_galerias_publica(c)
               FROM unnest(ARRAY['pagos_depositos', 'pagos_tarjetas']) AS c LOOP
        IF v IS NULL THEN
            RAISE EXCEPTION 'Falta una de las galerías de pagos';
        END IF;
        IF jsonb_array_length(v -> 'imagenes') = 0 THEN
            RAISE NOTICE 'Aviso: la galería % no tiene imágenes vigentes.', v ->> 'clave';
        END IF;
    END LOOP;

    -- Una clave inventada tiene que dar NULL, no una galería vacía
    IF ecommerce.fn_galerias_publica('no_existe_esta_galeria') IS NOT NULL THEN
        RAISE EXCEPTION 'Una clave que no existe debería devolver NULL';
    END IF;

    -- Y no puede quedar ninguna dirección absoluta guardada
    IF EXISTS (SELECT 1 FROM ecommerce.galerias_imagenes
                WHERE imagen LIKE '%/%' OR imagen_movil LIKE '%/%') THEN
        RAISE EXCEPTION 'Quedan imágenes con la ruta o el servidor dentro';
    END IF;

    RAISE NOTICE 'Galerías: % con % imágenes.', v_n,
          (SELECT count(*) FROM ecommerce.galerias_imagenes WHERE deleted_at IS NULL);
END
$comprobar$;

-- ----------------------------------------------------------------------------
-- 5. LO VIEJO SE APARTA, NO SE BORRA
-- ----------------------------------------------------------------------------
-- Aquí NO se puede borrar todavía, al revés que en las tajadas anteriores:
-- `espana_motos` y `pagina_marca` —que siguen sin migrar— tienen clave ajena
-- contra `ecommerce.galeria`. Quitar esas claves para poder borrar dejaría
-- sin protección dos tablas que todavía están en uso, que es peor.
--
-- Se renombran con el sufijo `_legado`, que conserva las claves ajenas y deja
-- claro cuál es cuál: tener `galeria` y `galerias` una al lado de la otra es
-- pedir que alguien toque la que no es. Se borran de verdad cuando se migren
-- esas dos pantallas.
--
-- Las funciones viejas sí se van: ya no las llama nadie.
DO $apartar$
DECLARE
    r record;
BEGIN
    FOR r IN SELECT p.oid::regprocedure::text AS firma
               FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
              WHERE n.nspname = 'ecommerce' AND p.prokind = 'f'
                AND p.proname LIKE 'fn\_galeria\_%' LOOP
        EXECUTE 'DROP FUNCTION IF EXISTS ' || r.firma;
    END LOOP;

    IF to_regclass('ecommerce.galeria_imagen') IS NOT NULL THEN
        ALTER TABLE ecommerce.galeria_imagen RENAME TO galeria_imagen_legado;
    END IF;
    IF to_regclass('ecommerce.galeria') IS NOT NULL THEN
        ALTER TABLE ecommerce.galeria RENAME TO galeria_legado;
        COMMENT ON TABLE ecommerce.galeria_legado IS
            'VIEJA. Se queda porque espana_motos y pagina_marca aún le apuntan. Bórrala al migrar esas dos.';
    END IF;

    RAISE NOTICE 'Las viejas quedan como *_legado: aún les apuntan espana_motos y pagina_marca.';
END
$apartar$;

COMMIT;
