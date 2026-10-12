-- ===========================================================================
-- DATOS DE PRUEBA: COORDENADAS AL AZAR PARA LOS CLIENTES
-- ===========================================================================
-- Fecha: 2026-10-10
--
-- ESTO NO ES UNA MIGRACIÓN. Por eso vive en database/sql/pruebas/ y no en
-- database/sql/: inventa datos. NO SE DEBE CORRER SOBRE DATOS REALES, porque
-- pondría coordenadas falsas a clientes de verdad.
--
-- PARA QUÉ. Las zonas del mapa preguntan qué clientes caen dentro de un área,
-- y eso necesita que los clientes tengan coordenadas. En la base de pruebas
-- sólo las tenían 3 de 1001, así que no había nada que dibujar. Esto reparte
-- a los demás alrededor del centro de SU cantón, que es el que ya tienen
-- puesto: así los puntos salen donde deben y las zonas que se dibujen
-- encima significan algo.
--
-- NO PISA LAS QUE YA ESTÁN. Sólo rellena las vacías: las tres coordenadas de
-- verdad —las que se pusieron con el selector de mapa— se quedan como están.
--
-- CÓMO SE REPARTEN. Cada cliente cae en un cuadrado de ±0,035° alrededor del
-- centro de su cantón, que a esta latitud son unos ±3,9 km: una nube de unos
-- 8 km de lado, que es más o menos como se reparte una cartera urbana y da
-- sitio para dibujar polígonos que dejen fuera a unos y dentro a otros.
--
-- El azar va con `setseed` para que dos pasadas den lo mismo.
--
-- Idempotente: volver a correrlo no cambia a quien ya tiene coordenadas.
-- ===========================================================================

SELECT setseed(0.42);

WITH centros(canton, lat, lng) AS (
    VALUES
    ('Cuenca',                          -2.900500, -79.004500),
    ('Riobamba',                        -1.663500, -78.654600),
    ('Machala',                         -3.258100, -79.955400),
    ('Esmeraldas',                       0.959200, -79.653900),
    ('Guayaquil',                       -2.170900, -79.922400),
    ('Ibarra',                           0.351700, -78.122300),
    ('Loja',                            -3.993100, -79.204200),
    ('Manta',                           -0.967700, -80.708900),
    ('Portoviejo',                      -1.054600, -80.454500),
    ('Quito',                           -0.180700, -78.467800),
    ('Distrito Metropolitano de Quito', -0.180700, -78.467800),
    ('Santo Domingo',                   -0.252200, -79.175700),
    ('Ambato',                          -1.249100, -78.616800)
),
-- A quién le toca: los que no tienen coordenada y sí un cantón conocido
pendientes AS (
    SELECT c.id, k.lat, k.lng
      FROM ventas.clientes c
      JOIN centros k ON k.canton = c.canton
     WHERE c.deleted_at IS NULL
       AND NULLIF(TRIM(COALESCE(c.coordenadas, '')), '') IS NULL
),
-- El punto de cada uno, alrededor del centro de su cantón
puntos AS (
    SELECT p.id,
           ROUND((p.lat + (random() - 0.5) * 0.07)::numeric, 6) AS lat,
           ROUND((p.lng + (random() - 0.5) * 0.07)::numeric, 6) AS lng
      FROM pendientes p
)
UPDATE ventas.clientes c
   SET coordenadas = pt.lat::text || ', ' || pt.lng::text
  FROM puntos pt
 WHERE c.id = pt.id;


-- ---------------------------------------------------------------------------
-- COMPROBACIÓN
-- ---------------------------------------------------------------------------
SELECT c.canton,
       COUNT(*) AS clientes,
       COUNT(NULLIF(TRIM(COALESCE(c.coordenadas, '')), '')) AS con_coordenadas,
       ROUND(MIN(ventas.fn_coordenada_lat(c.coordenadas)), 3) AS lat_min,
       ROUND(MAX(ventas.fn_coordenada_lat(c.coordenadas)), 3) AS lat_max,
       ROUND(MIN(ventas.fn_coordenada_lng(c.coordenadas)), 3) AS lng_min,
       ROUND(MAX(ventas.fn_coordenada_lng(c.coordenadas)), 3) AS lng_max
  FROM ventas.clientes c
 WHERE c.deleted_at IS NULL
 GROUP BY c.canton
 ORDER BY c.canton;
