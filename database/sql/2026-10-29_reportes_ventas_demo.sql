-- ============================================================================
-- REPORTES: VENTAS DE DEMOSTRACIÓN
-- ============================================================================
-- Fecha: 2026-10-29
--
-- Una tabla ancha de ventas inventadas para montar encima el tablero de
-- reportes: la misma idea que el ejemplo de ag-Grid Studio, pero con el
-- trabajo donde este CRM lo hace bien.
--
-- POR QUÉ LA AGREGACIÓN VA EN LA BASE Y NO EN LA REJILLA
--
-- Agrupar, totalizar y pivotar en ag-Grid es de la edición ENTERPRISE, que es
-- de pago; aquí está la Community. Y aunque estuviera la de pago, pivotar en
-- el navegador obliga a bajarse TODAS las filas: con 5.000 da igual, con
-- 500.000 no. PostgreSQL agrupa 5.000 filas en milisegundos y manda de vuelta
-- las doce que se ven.
--
-- Son datos INVENTADOS y se nota a propósito: `ventas_demo`, en su esquema
-- aparte, sin relación con ventas.proformas ni con nada real. Se puede borrar
-- entera sin que se caiga nada.
--
-- Idempotente: se puede volver a correr (vuelve a sembrar desde cero).
-- ============================================================================
\set ON_ERROR_STOP on

BEGIN;

CREATE SCHEMA IF NOT EXISTS reportes;

COMMENT ON SCHEMA reportes IS 'Tableros y datos de ejemplo para reportería. Nada de aquí es un dato real de la empresa.';

-- ---------------------------------------------------------------------------
-- 1. LA TABLA
-- ---------------------------------------------------------------------------
DROP TABLE IF EXISTS reportes.ventas_demo;

CREATE TABLE reportes.ventas_demo (
    id              bigserial    NOT NULL,
    fecha           date         NOT NULL,
    -- Calculadas: así agrupar por año o trimestre no recorre la tabla
    -- haciendo cuentas. `to_char` no vale para una columna generada (es
    -- STABLE, no IMMUTABLE), así que el mes lo arma la función del pivote.
    anio            integer      GENERATED ALWAYS AS (EXTRACT(YEAR    FROM fecha)::integer) STORED,
    trimestre       integer      GENERATED ALWAYS AS (EXTRACT(QUARTER FROM fecha)::integer) STORED,
    mes_numero      integer      GENERATED ALWAYS AS (EXTRACT(MONTH   FROM fecha)::integer) STORED,

    region          varchar(40)  NOT NULL,
    ciudad          varchar(60)  NOT NULL,
    vendedor        varchar(60)  NOT NULL,
    canal           varchar(20)  NOT NULL,
    categoria       varchar(40)  NOT NULL,
    producto        varchar(80)  NOT NULL,
    cliente         varchar(80)  NOT NULL,
    forma_pago      varchar(20)  NOT NULL,

    cantidad        integer      NOT NULL,
    precio_unitario numeric(12,2) NOT NULL,
    costo_unitario  numeric(12,2) NOT NULL,
    descuento       numeric(12,2) NOT NULL DEFAULT 0,
    -- `numeric` en todo lo que es plata, NUNCA `double precision`: con
    -- flotante, 0.1 + 0.2 no es 0.3 y un informe acaba descuadrando por
    -- céntimos que nadie sabe de dónde salen.
    total           numeric(14,2) GENERATED ALWAYS AS (cantidad * precio_unitario - descuento) STORED,
    costo           numeric(14,2) GENERATED ALWAYS AS (cantidad * costo_unitario) STORED,
    margen          numeric(14,2) GENERATED ALWAYS AS (cantidad * precio_unitario - descuento - cantidad * costo_unitario) STORED,

    created_at      timestamp with time zone DEFAULT now(),

    CONSTRAINT pk_ventas_demo PRIMARY KEY (id)
);

COMMENT ON TABLE reportes.ventas_demo IS 'Ventas INVENTADAS para el tablero de reportes. No es un dato real: se puede borrar y volver a sembrar.';

CREATE INDEX ix_ventas_demo_fecha     ON reportes.ventas_demo (fecha);
CREATE INDEX ix_ventas_demo_region    ON reportes.ventas_demo (region);
CREATE INDEX ix_ventas_demo_categoria ON reportes.ventas_demo (categoria);
CREATE INDEX ix_ventas_demo_vendedor  ON reportes.ventas_demo (vendedor);

-- ---------------------------------------------------------------------------
-- 2. LOS DATOS
-- ---------------------------------------------------------------------------
-- Dos años de ventas con cosas que se parecen a la realidad y que hacen que
-- el tablero enseñe ALGO: diciembre vende más, la Sierra pesa más que el
-- Oriente, los accesorios tienen más margen que los televisores y el canal
-- online crece con el tiempo. Un dato plano y uniforme hace un gráfico
-- aburrido del que no se aprende nada.
DO $sembrar$
DECLARE
    v_regiones    text[] := ARRAY['Sierra', 'Costa', 'Oriente', 'Austro', 'Insular'];
    v_pesoRegion  int[]  := ARRAY[38, 32, 8, 20, 2];     -- de cada 100 ventas
    v_ciudades    jsonb  := '{
        "Sierra":  ["Quito", "Ambato", "Riobamba", "Ibarra"],
        "Costa":   ["Guayaquil", "Manta", "Machala", "Portoviejo"],
        "Oriente": ["Tena", "Puyo", "Lago Agrio"],
        "Austro":  ["Cuenca", "Loja", "Azogues"],
        "Insular": ["Puerto Ayora", "San Cristóbal"]
    }'::jsonb;
    v_vendedores  text[] := ARRAY['Ana Torres', 'Luis Pérez', 'Marta Díaz', 'Carlos Ruiz',
                                  'Sofía Mena', 'Jorge Lema', 'Paula Vega', 'Iván Cobo'];
    v_canales     text[] := ARRAY['Tienda', 'Online', 'Mayorista', 'Teléfono'];
    v_pagos       text[] := ARRAY['Efectivo', 'Tarjeta', 'Crédito', 'Transferencia'];
    v_clientes    text[] := ARRAY['Comercial Andina', 'Distribuidora Pacífico', 'Almacenes Rivas',
                                  'Tecno Hogar', 'Grupo Delta', 'Megatienda Sur', 'Casa Blanca',
                                  'Importadora Sol', 'Electro Centro', 'Consumidor final'];

    -- categoría, producto, precio, margen bruto de la categoría
    v_catalogo jsonb := '[
        {"categoria":"Línea Blanca","producto":"Refrigeradora No Frost 14p","precio":599,"margen":0.22},
        {"categoria":"Línea Blanca","producto":"Lavadora 17 kg","precio":679,"margen":0.24},
        {"categoria":"Línea Blanca","producto":"Secadora 10 kg","precio":799,"margen":0.21},
        {"categoria":"Línea Blanca","producto":"Cocina 4 quemadores","precio":449,"margen":0.26},
        {"categoria":"Televisores","producto":"TV QLED 55 4K","precio":699,"margen":0.15},
        {"categoria":"Televisores","producto":"TV LED 43","precio":349,"margen":0.17},
        {"categoria":"Televisores","producto":"TV OLED 65","precio":1499,"margen":0.13},
        {"categoria":"Computación","producto":"Laptop EliteBook i7","precio":1450,"margen":0.18},
        {"categoria":"Computación","producto":"Laptop ThinkPad Ryzen 7","precio":1380,"margen":0.19},
        {"categoria":"Computación","producto":"Monitor 27 IPS","precio":219,"margen":0.28},
        {"categoria":"Celulares","producto":"Galaxy A55 256GB","precio":449,"margen":0.16},
        {"categoria":"Celulares","producto":"Redmi Note 13","precio":229,"margen":0.18},
        {"categoria":"Celulares","producto":"iPhone 15 128GB","precio":999,"margen":0.12},
        {"categoria":"Audio y Video","producto":"Barra de sonido 2.1","precio":239,"margen":0.30},
        {"categoria":"Audio y Video","producto":"Audífonos inalámbricos","precio":89,"margen":0.38},
        {"categoria":"Accesorios","producto":"Cable HDMI 2 m","precio":9.90,"margen":0.55},
        {"categoria":"Accesorios","producto":"Soporte de pared TV","precio":39,"margen":0.45},
        {"categoria":"Accesorios","producto":"Protector de voltaje","precio":24,"margen":0.42}
    ]'::jsonb;

    v_fila        jsonb;
    v_region      text;
    v_ciudad      text;
    v_canal       text;
    v_fecha       date;
    v_cantidad    int;
    v_precio      numeric(12,2);
    v_costo       numeric(12,2);
    v_descuento   numeric(12,2);
    v_estacion    numeric;
    v_dado        int;
    v_acumulado   int;
    v_i           int;
    v_cuantas     int := 5000;
    v_desde       date := (date_trunc('month', CURRENT_DATE) - interval '23 months')::date;
BEGIN
    -- Semilla fija: dos ejecuciones dan los mismos datos, y así una captura
    -- de pantalla de hoy sigue valiendo mañana.
    PERFORM setseed(0.42);

    FOR v_i IN 1..v_cuantas LOOP
        -- La región, con su peso
        v_dado := 1 + floor(random() * 100)::int;
        v_acumulado := 0;
        v_region := v_regiones[array_length(v_regiones, 1)];
        FOR v_dado IN 1..array_length(v_pesoRegion, 1) LOOP
            v_acumulado := v_acumulado + v_pesoRegion[v_dado];
            IF (1 + floor(random() * 100)::int) <= v_acumulado THEN
                v_region := v_regiones[v_dado];
                EXIT;
            END IF;
        END LOOP;

        v_ciudad := (v_ciudades -> v_region) ->> floor(random() * jsonb_array_length(v_ciudades -> v_region))::int;

        -- La fecha, dentro de los 24 meses, y con más ventas en diciembre
        v_fecha := v_desde + (floor(random() * 730))::int;
        v_estacion := CASE EXTRACT(MONTH FROM v_fecha)
                          WHEN 12 THEN 1.8 WHEN 11 THEN 1.3 WHEN 5 THEN 1.2
                          WHEN 1  THEN 0.7 WHEN 2  THEN 0.8 ELSE 1.0 END;
        -- Se descarta parte de las ventas de los meses flojos: así la curva
        -- del gráfico tiene forma en vez de ser una línea plana con ruido.
        CONTINUE WHEN random() > v_estacion / 1.8;

        -- El canal: el online pesa más cuanto más reciente es la venta
        IF random() < 0.15 + 0.35 * (v_fecha - v_desde)::numeric / 730 THEN
            v_canal := 'Online';
        ELSE
            v_canal := v_canales[1 + floor(random() * array_length(v_canales, 1))::int];
        END IF;

        v_fila := v_catalogo -> floor(random() * jsonb_array_length(v_catalogo))::int;

        v_cantidad := CASE WHEN (v_fila ->> 'categoria') = 'Accesorios'
                           THEN 1 + floor(random() * 8)::int
                           ELSE 1 + floor(random() * 3)::int END;
        IF v_canal = 'Mayorista' THEN v_cantidad := v_cantidad * (3 + floor(random() * 5)::int); END IF;

        v_precio := (v_fila ->> 'precio')::numeric;
        v_costo  := round(v_precio * (1 - (v_fila ->> 'margen')::numeric), 2);
        -- Un descuento de vez en cuando, mayor en mayorista
        -- El ::numeric no es decorativo: `random()` devuelve double, y round()
        -- con dos argumentos sólo existe para numeric.
        v_descuento := CASE WHEN random() < CASE WHEN v_canal = 'Mayorista' THEN 0.5 ELSE 0.18 END
                            THEN round((v_cantidad * v_precio * (0.03 + random() * 0.12))::numeric, 2)
                            ELSE 0 END;

        INSERT INTO reportes.ventas_demo
            (fecha, region, ciudad, vendedor, canal, categoria, producto, cliente,
             forma_pago, cantidad, precio_unitario, costo_unitario, descuento)
        VALUES (
            v_fecha, v_region, v_ciudad,
            v_vendedores[1 + floor(random() * array_length(v_vendedores, 1))::int],
            v_canal,
            v_fila ->> 'categoria',
            v_fila ->> 'producto',
            CASE WHEN v_canal = 'Tienda' AND random() < 0.6 THEN 'Consumidor final'
                 ELSE v_clientes[1 + floor(random() * array_length(v_clientes, 1))::int] END,
            v_pagos[1 + floor(random() * array_length(v_pagos, 1))::int],
            v_cantidad, v_precio, v_costo, v_descuento);
    END LOOP;

    RAISE NOTICE 'ventas de ejemplo sembradas: %', (SELECT count(*) FROM reportes.ventas_demo);
END
$sembrar$;

ANALYZE reportes.ventas_demo;

SELECT 'ventas: ' || count(*) ||
       ' · desde ' || min(fecha) || ' hasta ' || max(fecha) ||
       ' · total $' || to_char(sum(total), 'FM999G999G999D00') ||
       ' · margen $' || to_char(sum(margen), 'FM999G999G999D00')
  FROM reportes.ventas_demo;

COMMIT;
