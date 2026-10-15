-- ============================================================================
-- MÓDULO INVENTARIOS — ESQUEMA Y TABLAS
-- ============================================================================
-- Fecha: 2026-10-14
--
-- El catálogo de una empresa que vende electrodomésticos, computadores y
-- línea tecnológica. Tres cosas que mantener:
--
--   inventarios.categorias          JERÁRQUICA, como seguridad.menus: Línea
--                                   Blanca > Refrigeración > Refrigeradoras
--   inventarios.marcas              Samsung, LG, HP, Indurama…
--   inventarios.productos           la ficha, con su galería de fotos en
--   inventarios.productos_imagenes  una tabla aparte
--
-- DECISIONES QUE NO SE VEN LEYENDO EL DDL
--
-- · `numeric` en todo lo que es plata o cantidad, NUNCA `double precision`:
--   con flotante, 0.1 + 0.2 no es 0.3 y un inventario valorado acaba
--   descuadrando por céntimos que nadie sabe de dónde salen.
--
-- · El código (SKU) es único y obligatorio; el código de barras es único
--   PERO OPCIONAL, con índice parcial `WHERE codigo_barras IS NOT NULL`: un
--   UNIQUE normal dejaría meter un solo producto sin código de barras, y
--   aquí la mayoría de los accesorios no traen.
--
-- · En categorías el nombre es único ENTRE HERMANOS, no en toda la tabla.
--   «Accesorios» tiene que poder existir colgando de Computadores y de
--   Celulares; lo que no puede haber es dos «Accesorios» bajo el mismo padre.
--
-- · El nivel se GUARDA, no se calcula al vuelo. La rejilla pinta la sangría
--   con él (igual que allMenus) y recalcularlo en cada listado obligaría a
--   un recursivo por consulta. Lo mantienen las funciones fn_categorias_*.
--
-- · Las imágenes van en su propia tabla con `orden` y una marcada como
--   `principal`, y un índice único parcial garantiza que no haya dos
--   principales en el mismo producto. El fichero vive en storage; aquí sólo
--   queda su nombre.
--
-- · IVA por defecto 15%, que es el vigente en Ecuador. Va en el producto y
--   no en una constante del código porque cambia por decreto y hay partidas
--   con tarifa 0.
--
-- Las tres funciones de auditoría de la casa van en las cuatro tablas, igual
-- que en rh y ventas: las funciones PL/pgSQL dejan el contexto app.* y los
-- datos_anteriores/datos_nuevos, y el disparador los graba.
--
-- Idempotente: se puede volver a correr.
-- ============================================================================

CREATE SCHEMA IF NOT EXISTS inventarios;
COMMENT ON SCHEMA inventarios IS 'Catálogo de productos: categorías, marcas y fichas';


-- ---------------------------------------------------------------------------
-- CATEGORÍAS (jerárquica)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS inventarios.categorias (
    id          bigserial    PRIMARY KEY,
    padre_id    bigint       NULL REFERENCES inventarios.categorias(id),
    orden       integer      NOT NULL DEFAULT 1,
    nivel       integer      NOT NULL DEFAULT 0,
    nombre      varchar(100) NOT NULL,
    descripcion text         NULL,
    icono       varchar(50)  NULL,
    activo      boolean      NOT NULL DEFAULT true,

    created_at  timestamptz  NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at  timestamptz  NOT NULL DEFAULT CURRENT_TIMESTAMP,
    created_by  varchar(100) NULL,
    updated_by  varchar(100) NULL,

    CONSTRAINT ck_categorias_nivel     CHECK (nivel BETWEEN 0 AND 3),
    CONSTRAINT ck_categorias_no_padre_si_misma CHECK (padre_id IS NULL OR padre_id <> id)
);

COMMENT ON TABLE  inventarios.categorias IS 'Árbol de categorías: Línea Blanca > Refrigeración > Refrigeradoras';
COMMENT ON COLUMN inventarios.categorias.nivel IS 'Profundidad 0..3; la mantienen las funciones, la usa la rejilla para la sangría';
COMMENT ON COLUMN inventarios.categorias.orden IS 'Posición entre sus hermanos';

-- Un nombre no se repite ENTRE HERMANOS. Dos índices porque en SQL
-- NULL <> NULL: con padre_id nulo (las raíces) el UNIQUE normal no agrupa.
CREATE UNIQUE INDEX IF NOT EXISTS uq_categorias_nombre_hermano
    ON inventarios.categorias (padre_id, UPPER(TRIM(nombre)))
 WHERE padre_id IS NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS uq_categorias_nombre_raiz
    ON inventarios.categorias (UPPER(TRIM(nombre)))
 WHERE padre_id IS NULL;

CREATE INDEX IF NOT EXISTS ix_categorias_padre ON inventarios.categorias (padre_id, orden);


-- ---------------------------------------------------------------------------
-- MARCAS
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS inventarios.marcas (
    id          bigserial    PRIMARY KEY,
    nombre      varchar(100) NOT NULL,
    descripcion text         NULL,
    pais_origen varchar(60)  NULL,
    sitio_web   varchar(200) NULL,
    -- Sólo el nombre del fichero; vive en storage/app/public/img/marcas
    logo        varchar(150) NULL,
    activo      boolean      NOT NULL DEFAULT true,

    created_at  timestamptz  NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at  timestamptz  NOT NULL DEFAULT CURRENT_TIMESTAMP,
    created_by  varchar(100) NULL,
    updated_by  varchar(100) NULL
);

COMMENT ON TABLE  inventarios.marcas IS 'Marcas del catálogo: Samsung, LG, HP, Indurama…';
COMMENT ON COLUMN inventarios.marcas.logo IS 'Nombre del fichero en storage/app/public/img/marcas';

CREATE UNIQUE INDEX IF NOT EXISTS uq_marcas_nombre
    ON inventarios.marcas (UPPER(TRIM(nombre)));


-- ---------------------------------------------------------------------------
-- PRODUCTOS
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS inventarios.productos (
    id              bigserial     PRIMARY KEY,

    -- Identificación
    codigo          varchar(30)   NOT NULL,          -- SKU interno
    codigo_barras   varchar(50)   NULL,              -- EAN / UPC de fábrica
    nombre          varchar(150)  NOT NULL,
    descripcion     text          NULL,

    -- Clasificación
    marca_id        bigint        NULL REFERENCES inventarios.marcas(id),
    categoria_id    bigint        NULL REFERENCES inventarios.categorias(id),
    modelo          varchar(80)   NULL,

    -- Comercial
    unidad          varchar(15)   NOT NULL DEFAULT 'UNIDAD',
    costo           numeric(14,4) NOT NULL DEFAULT 0,
    precio          numeric(14,4) NOT NULL DEFAULT 0,
    iva_porcentaje  numeric(5,2)  NOT NULL DEFAULT 15,

    -- Existencias
    maneja_stock    boolean       NOT NULL DEFAULT true,
    stock_minimo    numeric(14,4) NOT NULL DEFAULT 0,
    stock_maximo    numeric(14,4) NULL,

    -- Propio del giro: electrodomésticos y computadores
    maneja_serie    boolean       NOT NULL DEFAULT false,   -- serie / IMEI por unidad
    garantia_meses  integer       NOT NULL DEFAULT 0,

    -- Para el despacho y la bodega
    peso_kg         numeric(10,3) NULL,
    alto_cm         numeric(10,2) NULL,
    ancho_cm        numeric(10,2) NULL,
    profundidad_cm  numeric(10,2) NULL,

    activo          boolean       NOT NULL DEFAULT true,

    created_at      timestamptz   NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at      timestamptz   NOT NULL DEFAULT CURRENT_TIMESTAMP,
    created_by      varchar(100)  NULL,
    updated_by      varchar(100)  NULL,

    CONSTRAINT ck_productos_costo     CHECK (costo  >= 0),
    CONSTRAINT ck_productos_precio    CHECK (precio >= 0),
    CONSTRAINT ck_productos_iva       CHECK (iva_porcentaje BETWEEN 0 AND 100),
    CONSTRAINT ck_productos_garantia  CHECK (garantia_meses BETWEEN 0 AND 600),
    CONSTRAINT ck_productos_stock_min CHECK (stock_minimo >= 0),
    CONSTRAINT ck_productos_stock_max CHECK (stock_maximo IS NULL OR stock_maximo >= stock_minimo)
);

COMMENT ON TABLE  inventarios.productos IS 'Ficha de producto del catálogo';
COMMENT ON COLUMN inventarios.productos.codigo IS 'SKU interno, obligatorio y único';
COMMENT ON COLUMN inventarios.productos.codigo_barras IS 'EAN/UPC de fábrica; único cuando existe, pero la mayoría de accesorios no traen';
COMMENT ON COLUMN inventarios.productos.maneja_serie IS 'true cuando cada unidad se controla por número de serie o IMEI (garantías)';
COMMENT ON COLUMN inventarios.productos.iva_porcentaje IS 'Tarifa del producto; 15 es la vigente en Ecuador, pero hay partidas con 0';

CREATE UNIQUE INDEX IF NOT EXISTS uq_productos_codigo
    ON inventarios.productos (UPPER(TRIM(codigo)));

-- Parcial: el código de barras es opcional, y un UNIQUE normal sólo dejaría
-- UN producto sin él
CREATE UNIQUE INDEX IF NOT EXISTS uq_productos_barras
    ON inventarios.productos (UPPER(TRIM(codigo_barras)))
 WHERE codigo_barras IS NOT NULL AND TRIM(codigo_barras) <> '';

CREATE INDEX IF NOT EXISTS ix_productos_marca     ON inventarios.productos (marca_id);
CREATE INDEX IF NOT EXISTS ix_productos_categoria ON inventarios.productos (categoria_id);
CREATE INDEX IF NOT EXISTS ix_productos_nombre    ON inventarios.productos (UPPER(nombre));


-- ---------------------------------------------------------------------------
-- IMÁGENES DEL PRODUCTO (galería)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS inventarios.productos_imagenes (
    id              bigserial    PRIMARY KEY,
    producto_id     bigint       NOT NULL REFERENCES inventarios.productos(id) ON DELETE CASCADE,
    -- Nombre del fichero en storage/app/public/img/productos
    archivo         varchar(150) NOT NULL,
    nombre_original varchar(200) NULL,
    orden           integer      NOT NULL DEFAULT 1,
    principal       boolean      NOT NULL DEFAULT false,

    created_at      timestamptz  NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at      timestamptz  NOT NULL DEFAULT CURRENT_TIMESTAMP,
    created_by      varchar(100) NULL,
    updated_by      varchar(100) NULL
);

COMMENT ON TABLE inventarios.productos_imagenes IS 'Galería del producto; el fichero vive en storage, aquí sólo su nombre';

-- ON DELETE CASCADE borra las filas, pero NO los ficheros: eso lo hace el
-- controlador antes de llamar a eliminar. Si algún día se borra un producto
-- por SQL a mano, quedarán ficheros huérfanos en storage.

CREATE UNIQUE INDEX IF NOT EXISTS uq_prod_imagenes_archivo
    ON inventarios.productos_imagenes (producto_id, archivo);

-- Una sola principal por producto, garantizado por la base y no por cuidado
-- al escribir: dos pestañas abiertas marcando a la vez bastan para romperlo
CREATE UNIQUE INDEX IF NOT EXISTS uq_prod_imagenes_principal
    ON inventarios.productos_imagenes (producto_id)
 WHERE principal;

CREATE INDEX IF NOT EXISTS ix_prod_imagenes_producto
    ON inventarios.productos_imagenes (producto_id, orden);


-- ---------------------------------------------------------------------------
-- DISPARADORES DE AUDITORÍA (los tres de la casa, en las cuatro tablas)
-- DROP + CREATE porque CREATE TRIGGER no admite IF NOT EXISTS en PG < 14.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    v_tabla text;
BEGIN
    FOREACH v_tabla IN ARRAY ARRAY['categorias', 'marcas', 'productos', 'productos_imagenes'] LOOP
        EXECUTE format('DROP TRIGGER IF EXISTS trigger_%s_set_users  ON inventarios.%I', v_tabla, v_tabla);
        EXECUTE format('DROP TRIGGER IF EXISTS trigger_%s_updated_at ON inventarios.%I', v_tabla, v_tabla);
        EXECUTE format('DROP TRIGGER IF EXISTS trg_%s_audit          ON inventarios.%I', v_tabla, v_tabla);

        EXECUTE format('CREATE TRIGGER trigger_%s_set_users BEFORE INSERT OR UPDATE ON inventarios.%I
                        FOR EACH ROW EXECUTE FUNCTION auditoria.fn_set_audit_users()', v_tabla, v_tabla);

        EXECUTE format('CREATE TRIGGER trigger_%s_updated_at BEFORE UPDATE ON inventarios.%I
                        FOR EACH ROW EXECUTE FUNCTION auditoria.fn_update_updated_at_column()', v_tabla, v_tabla);

        EXECUTE format('CREATE TRIGGER trg_%s_audit AFTER INSERT OR UPDATE OR DELETE ON inventarios.%I
                        FOR EACH ROW EXECUTE FUNCTION auditoria.fn_auditar_cambios()', v_tabla, v_tabla);
    END LOOP;
END $$;


-- ---------------------------------------------------------------------------
-- PROPIEDAD
-- ---------------------------------------------------------------------------
ALTER SCHEMA inventarios                     OWNER TO postgres;
ALTER TABLE  inventarios.categorias          OWNER TO postgres;
ALTER TABLE  inventarios.marcas              OWNER TO postgres;
ALTER TABLE  inventarios.productos           OWNER TO postgres;
ALTER TABLE  inventarios.productos_imagenes  OWNER TO postgres;


-- ---------------------------------------------------------------------------
-- COMPROBACIÓN
-- ---------------------------------------------------------------------------
SELECT c.relname AS tabla,
       (SELECT COUNT(*) FROM pg_trigger t WHERE t.tgrelid = c.oid AND NOT t.tgisinternal) AS disparadores
  FROM pg_class c
 WHERE c.relnamespace = 'inventarios'::regnamespace AND c.relkind = 'r'
 ORDER BY 1;
