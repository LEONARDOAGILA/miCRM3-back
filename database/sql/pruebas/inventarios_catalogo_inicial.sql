-- ============================================================================
-- CATÁLOGO DE ARRANQUE PARA INVENTARIOS  —  DATOS DE EJEMPLO
-- ============================================================================
-- Fecha: 2026-10-14
--
-- ESTO NO ES UNA MIGRACIÓN. Está en database/sql/pruebas/ a propósito: son
-- marcas, categorías y productos inventados para poder abrir las pantallas y
-- ver cómo se comportan con datos de verdad. En la base de producción no se
-- corre.
--
-- Las categorías y las marcas son las que de verdad se usan en una tienda de
-- electrodomésticos y tecnología en Ecuador, así que el árbol sirve de punto
-- de partida si se quiere conservar. Los productos son de muestra: precios y
-- costos puestos a ojo.
--
-- Se puede volver a correr: no duplica nada.
--
-- PARA DESHACERLO, al final del fichero está el DELETE comentado.
-- ============================================================================

DO $$
DECLARE
    -- Quien firma los movimientos. 4 es el usuario de sistemas; cámbielo si
    -- se corre con otro.
    c_usuario  constant bigint  := 4;
    c_login    constant varchar := 'CARGA';
    c_nombre   constant varchar := 'Carga inicial';

    v_id         bigint;
    v_marca      bigint;
    v_categoria  bigint;
    v_item       record;
    v_hechas     integer := 0;

BEGIN
    -- ---------------- MARCAS ----------------
    FOR v_item IN
        SELECT * FROM (VALUES
            ('Samsung',   'Corea del Sur',  'https://www.samsung.com/ec/'),
            ('LG',        'Corea del Sur',  'https://www.lg.com/ec'),
            ('Indurama',  'Ecuador',        'https://www.indurama.com'),
            ('Whirlpool', 'Estados Unidos', 'https://www.whirlpool.com.ec'),
            ('Mabe',      'México',         'https://www.mabe.ec'),
            ('Electrolux','Suecia',         'https://www.electrolux.com.ec'),
            ('HP',        'Estados Unidos', 'https://www.hp.com/ec-es/'),
            ('Lenovo',    'China',          'https://www.lenovo.com/ec/'),
            ('Dell',      'Estados Unidos', 'https://www.dell.com'),
            ('Apple',     'Estados Unidos', 'https://www.apple.com'),
            ('Xiaomi',    'China',          'https://www.mi.com'),
            ('Epson',     'Japón',          'https://epson.com.ec'),
            ('Sony',      'Japón',          'https://www.sony.com'),
            ('Oster',     'Estados Unidos', 'https://www.oster.com.ec')
        ) AS t(nombre, pais, web)
    LOOP
        IF NOT EXISTS (SELECT 1 FROM inventarios.marcas WHERE UPPER(nombre) = UPPER(v_item.nombre)) THEN
            PERFORM inventarios.fn_marcas_crear(v_item.nombre, NULL, v_item.pais, v_item.web, true,
                                                c_usuario, c_login, c_nombre, NULL, NULL, NULL);
            v_hechas := v_hechas + 1;
        END IF;
    END LOOP;
    RAISE NOTICE 'Marcas nuevas: %', v_hechas;

    -- ---------------- CATEGORÍAS (el árbol) ----------------
    -- Se crean por niveles: primero las raíces, luego sus hijas. El padre se
    -- busca por nombre, que entre hermanas es único.
    v_hechas := 0;
    FOR v_item IN
        SELECT * FROM (VALUES
            -- (padre, nombre, icono)
            (NULL,            'Línea Blanca',    'fa-snowflake'),
            (NULL,            'Línea Café',      'fa-mug-hot'),
            (NULL,            'Tecnología',      'fa-laptop'),
            (NULL,            'Audio y Video',   'fa-tv'),

            ('Línea Blanca',  'Refrigeración',   'fa-temperature-low'),
            ('Línea Blanca',  'Lavado',          'fa-soap'),
            ('Línea Blanca',  'Cocción',         'fa-fire-burner'),
            ('Línea Blanca',  'Climatización',   'fa-wind'),

            ('Línea Café',    'Pequeños Electrodomésticos', 'fa-blender'),
            ('Línea Café',    'Cuidado Personal', 'fa-wand-magic-sparkles'),

            ('Tecnología',    'Computadores',    'fa-desktop'),
            ('Tecnología',    'Celulares',       'fa-mobile-screen'),
            ('Tecnología',    'Impresión',       'fa-print'),
            ('Tecnología',    'Redes',           'fa-wifi'),

            ('Audio y Video', 'Televisores',     'fa-tv'),
            ('Audio y Video', 'Sonido',          'fa-volume-high'),

            ('Refrigeración', 'Refrigeradoras',  NULL),
            ('Refrigeración', 'Congeladores',    NULL),
            ('Lavado',        'Lavadoras',       NULL),
            ('Lavado',        'Secadoras',       NULL),
            ('Cocción',       'Cocinas',         NULL),
            ('Cocción',       'Microondas',      NULL),
            ('Computadores',  'Portátiles',      NULL),
            ('Computadores',  'Escritorio',      NULL),
            ('Computadores',  'Monitores',       NULL),
            ('Computadores',  'Accesorios',      NULL),
            ('Celulares',     'Smartphones',     NULL),
            ('Celulares',     'Accesorios',      NULL)
        ) AS t(padre, nombre, icono)
    LOOP
        v_categoria := NULL;
        IF v_item.padre IS NOT NULL THEN
            SELECT id INTO v_categoria FROM inventarios.categorias
             WHERE UPPER(nombre) = UPPER(v_item.padre) LIMIT 1;
            IF v_categoria IS NULL THEN
                RAISE NOTICE '  saltada «%»: no existe su padre «%»', v_item.nombre, v_item.padre;
                CONTINUE;
            END IF;
        END IF;

        IF NOT EXISTS (SELECT 1 FROM inventarios.categorias
                        WHERE padre_id IS NOT DISTINCT FROM v_categoria
                          AND UPPER(nombre) = UPPER(v_item.nombre)) THEN
            PERFORM inventarios.fn_categorias_crear(v_item.nombre, v_categoria, NULL, v_item.icono, true,
                                                    c_usuario, c_login, c_nombre, NULL, NULL, NULL);
            v_hechas := v_hechas + 1;
        END IF;
    END LOOP;
    RAISE NOTICE 'Categorías nuevas: %', v_hechas;

    -- ---------------- PRODUCTOS ----------------
    v_hechas := 0;
    FOR v_item IN
        SELECT * FROM (VALUES
            -- codigo, nombre, marca, categoria, modelo, costo, precio, garantia, serie, peso
            ('RF-28K',   'Refrigeradora French Door 28 pies No Frost', 'Samsung',   'Refrigeradoras', 'RF28K9070SR', 850.00,  1299.99, 24, true,  118.5),
            ('RF-IND14', 'Refrigeradora Top Mount 14 pies',            'Indurama',  'Refrigeradoras', 'RI-425',      390.00,   599.00, 12, true,   62.0),
            ('LV-LG17',  'Lavadora Carga Superior 17 kg',              'LG',        'Lavadoras',      'WT17DSB',     420.00,   679.00, 24, true,   48.0),
            ('SEC-WP10', 'Secadora Eléctrica 10 kg',                   'Whirlpool', 'Secadoras',      'WED5000DW',   510.00,   799.00, 12, true,   40.0),
            ('COC-MAB4', 'Cocina 4 Quemadores con Horno',              'Mabe',      'Cocinas',        'EMP6120PG',   230.00,   389.00, 12, true,   38.0),
            ('MIC-EL20', 'Microondas 20 litros',                       'Electrolux','Microondas',     'EMDN20',       68.00,   119.00, 12, false,  11.5),
            ('LAP-840',  'Laptop EliteBook 840 G10 i7 16GB',           'HP',        'Portátiles',     '840 G10',     920.00,  1450.00, 12, true,    1.4),
            ('LAP-T14',  'Laptop ThinkPad T14 Ryzen 7',                'Lenovo',    'Portátiles',     'T14 Gen 4',   880.00,  1380.00, 12, true,    1.3),
            ('MON-27D',  'Monitor 27 pulgadas IPS Full HD',            'Dell',      'Monitores',      'S2721H',      135.00,   219.00, 36, true,    4.5),
            ('CEL-A55',  'Smartphone Galaxy A55 256GB',                'Samsung',   'Smartphones',    'SM-A556',     290.00,   449.00, 12, true,    0.2),
            ('CEL-R13',  'Smartphone Redmi Note 13 128GB',             'Xiaomi',    'Smartphones',    'Note 13',     145.00,   229.00, 12, true,    0.2),
            ('IMP-L3250','Impresora Multifunción EcoTank',             'Epson',     'Impresión',      'L3250',       165.00,   259.00, 12, true,    4.2),
            ('TV-55Q',   'Televisor QLED 55 pulgadas 4K',              'Samsung',   'Televisores',    'QN55Q60D',    420.00,   699.00, 24, true,   16.0),
            ('BAR-S40',  'Barra de Sonido 2.1 con Subwoofer',          'Sony',      'Sonido',         'HT-S400',     145.00,   239.00, 12, true,    8.5),
            ('LIC-OST',  'Licuadora 1.5 litros vaso de vidrio',        'Oster',     'Pequeños Electrodomésticos', 'BLSTMG', 38.00, 69.00, 12, false, 3.8),
            ('ACC-HDMI', 'Cable HDMI 2.0 de 2 metros',                 NULL,        'Accesorios',     NULL,            3.50,     9.90,  0, false,  0.2)
        ) AS t(codigo, nombre, marca, categoria, modelo, costo, precio, garantia, serie, peso)
    LOOP
        IF EXISTS (SELECT 1 FROM inventarios.productos WHERE UPPER(codigo) = UPPER(v_item.codigo)) THEN
            CONTINUE;
        END IF;

        v_marca := NULL;
        IF v_item.marca IS NOT NULL THEN
            SELECT id INTO v_marca FROM inventarios.marcas WHERE UPPER(nombre) = UPPER(v_item.marca) LIMIT 1;
        END IF;

        -- «Accesorios» está dos veces en el árbol (Computadores y Celulares):
        -- se coge el primero, que para datos de ejemplo da igual
        SELECT id INTO v_categoria FROM inventarios.categorias
         WHERE UPPER(nombre) = UPPER(v_item.categoria) ORDER BY id LIMIT 1;

        PERFORM inventarios.fn_productos_crear(
            v_item.codigo, v_item.nombre, NULL, NULL,
            v_marca, v_categoria, v_item.modelo, 'UNIDAD',
            v_item.costo, v_item.precio, 15,
            true, 1, NULL,
            v_item.serie, v_item.garantia,
            v_item.peso, NULL, NULL, NULL,
            true, c_usuario, c_login, c_nombre, NULL, NULL, NULL);
        v_hechas := v_hechas + 1;
    END LOOP;
    RAISE NOTICE 'Productos nuevos: %', v_hechas;
END $$;


-- ---------------------------------------------------------------------------
-- LO QUE QUEDÓ
-- ---------------------------------------------------------------------------
SELECT 'marcas' AS que, COUNT(*) FROM inventarios.marcas
UNION ALL SELECT 'categorías', COUNT(*) FROM inventarios.categorias
UNION ALL SELECT 'productos',  COUNT(*) FROM inventarios.productos;

-- El árbol, como lo pinta la pantalla
SELECT lpad('', nivel * 3) || nombre AS arbol, nivel, orden
  FROM (
    WITH RECURSIVE a AS (
        SELECT c.*, LPAD(c.orden::text, 5, '0') AS ruta FROM inventarios.categorias c WHERE c.padre_id IS NULL
        UNION ALL
        SELECT h.*, a.ruta || '.' || LPAD(h.orden::text, 5, '0') FROM inventarios.categorias h JOIN a ON h.padre_id = a.id
    )
    SELECT * FROM a ORDER BY ruta
  ) t;


-- ---------------------------------------------------------------------------
-- PARA DESHACERLO (descomentar y correr)
-- ---------------------------------------------------------------------------
-- Las imágenes se van solas con los productos (ON DELETE CASCADE), pero los
-- FICHEROS de storage no: ésos hay que borrarlos a mano de
-- storage/app/public/img/productos.
--
-- DELETE FROM inventarios.productos;
-- DELETE FROM inventarios.categorias WHERE padre_id IS NOT NULL;   -- hijas primero
-- DELETE FROM inventarios.categorias;
-- DELETE FROM inventarios.marcas;
