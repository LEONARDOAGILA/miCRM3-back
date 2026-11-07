-- ============================================================================
-- LOS PESOS QUE TENIAN LOS PRODUCTOS, ANTES DE QUITAR LA COLUMNA
-- ============================================================================
-- Fecha: 2026-10-29
--
-- Las columnas peso_kg / alto_cm / ancho_cm / profundidad_cm de
-- inventarios.productos se quitaron el 29/10/2026: ahora el peso y las
-- medidas se llevan como CARACTERISTICAS, que ya tienen unidad y tipo de
-- dato propios.
--
-- Alto, ancho y fondo estaban VACIOS en los 15 productos, asi que no habia
-- nada que guardar. El peso SI estaba relleno en todos, y es lo que queda
-- aqui para no perderlo:
--
--   RF-28K       Refrigeradora French Door 28 pies No Frost     118.500 kg
--   RF-IND14     Refrigeradora Top Mount 14 pies                62.000 kg
--   LV-LG17      Lavadora Carga Superior 17 kg                  48.000 kg
--   SEC-WP10     Secadora Eléctrica 10 kg                       40.000 kg
--   COC-MAB4     Cocina 4 Quemadores con Horno                  38.000 kg
--   MIC-EL20     Microondas 20 litros                           11.500 kg
--   LAP-840      Laptop EliteBook 840 G10 i7 16GB               1.400 kg
--   LAP-T14      Laptop ThinkPad T14 Ryzen 7                    1.300 kg
--   MON-27D      Monitor 27 pulgadas IPS Full HD                4.500 kg
--   CEL-A55      Smartphone Galaxy A55 256GB                    0.200 kg
--   CEL-R13      Smartphone Redmi Note 13 128GB                 0.200 kg
--   IMP-L3250    Impresora Multifunción EcoTank                 4.200 kg
--   TV-55Q       Televisor QLED 55 pulgadas 4K                  16.000 kg
--   BAR-S40      Barra de Sonido 2.1 con Subwoofer              8.500 kg
--   LIC-OST      Licuadora 1.5 litros vaso de vidrio            3.800 kg
--   ACC-HDMI     Cable HDMI 2.0 de 2 metros                     0.200 kg
--
-- COMO VOLVER A METERLOS COMO CARACTERISTICA
--
-- 1. En Inventarios -> Nombres de caracteristica, el nombre con el que se
--    quiera: «Peso», tipo Numero, unidad kg.
-- 2. En Inventarios -> Caracteristicas, anadirlo a las categorias que lo
--    necesiten.
-- 3. Y correr esto, cambiando el nombre si se le puso otro:
--
-- INSERT INTO inventarios.caracteristicas_productos
--             (producto_id, caracteristica_id, nombre_id, nombre, valor, orden)
-- SELECT v.producto_id, k.id, n.id, n.nombre, to_char(v.peso, "'FM9990.000'"), 99
--   FROM (VALUES
(11, 'RF-28K', 118.500),
    (12, 'RF-IND14', 62.000),
    (13, 'LV-LG17', 48.000),
    (14, 'SEC-WP10', 40.000),
    (15, 'COC-MAB4', 38.000),
    (16, 'MIC-EL20', 11.500),
    (17, 'LAP-840', 1.400),
    (18, 'LAP-T14', 1.300),
    (19, 'MON-27D', 4.500),
    (20, 'CEL-A55', 0.200),
    (21, 'CEL-R13', 0.200),
    (22, 'IMP-L3250', 4.200),
    (23, 'TV-55Q', 16.000),
    (24, 'BAR-S40', 8.500),
    (25, 'LIC-OST', 3.800),
    (26, 'ACC-HDMI', 0.200)
--        ) AS v(producto_id, codigo, peso)
--   JOIN inventarios.productos p ON p.id = v.producto_id
--   JOIN inventarios.caracteristicas_nombres n
--     ON inventarios.fn_normalizar_nombre(n.nombre) = "'peso'"
--   JOIN inventarios.caracteristicas_categorias k
--     ON k.categoria_id = p.categoria_id AND k.nombre_id = n.id AND k.deleted_at IS NULL
-- ON CONFLICT DO NOTHING;
-- ============================================================================
