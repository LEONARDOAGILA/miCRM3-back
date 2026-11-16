-- ============================================================================
-- LOS FILTROS POR CARACTERÍSTICA, CONTADOS EN LA BASE
--
-- La sección paginada del inicio ya los tenía: «Cilindraje», «Color»,
-- «Memoria RAM»… salen de la ficha de cada producto. Los armaba el navegador,
-- y podía porque la sección se trae TODOS sus productos de una vez.
--
-- /shop no puede: pide doce productos de doscientos sesenta y tres, así que
-- unos filtros armados con lo que hay en pantalla hablarían de doce productos
-- y mentirían en todo —en qué valores existen y en cuántos hay de cada uno—.
-- Por eso se cuentan aquí, sobre el catálogo entero, y la tienda sólo los
-- pinta.
--
-- CÓMO SE CUENTA CADA UNO: «con los demás filtros puestos y sin el suyo».
-- Es lo mismo que ya hacían las marcas y las categorías en esta función, y es
-- lo que hace que marcar «Rojo» no deje la lista de colores con un solo color
-- dentro: mientras se elige DENTRO de un filtro, ese filtro no se cuenta a sí
-- mismo.
--
-- Se consigue apuntando por producto QUÉ FILTROS NO CUMPLE (`claves_fallo`):
--   · no falla ninguno  → el producto está en el resultado;
--   · falla sólo el suyo → sigue contando para los números DE ESE filtro.
--
-- QUÉ FILTROS SE OFRECEN: los que tenga lleno al menos una cuarta parte de los
-- productos que se están mirando, y como mucho doce. El catálogo entero tiene
-- setenta características distintas —las de las motos, las de los televisores,
-- las de las cocinas— y ofrecerlas todas en /shop sería una columna de setenta
-- persianas que no acota nada. Al elegir una categoría, las suyas pasan a
-- estar en el 100% y aparecen solas. Uno que ya esté marcado no se cae nunca
-- de la lista, porque entonces no habría forma de desmarcarlo.
--
-- LO QUE SE MANDA SON DATOS, NO PANTALLAS: el nombre, el tipo, la unidad, los
-- valores con su cuenta y los números que existen. Si eso se pinta con
-- casillas o con una barra de desde–hasta lo sigue decidiendo la tienda, con
-- las mismas reglas que ya usa la sección: así los dos sitios se ven igual y
-- hay UN solo sitio donde se cambian.
--
-- Idempotente: se puede correr dos veces.
-- ============================================================================

BEGIN;

-- ----------------------------------------------------------------------------
-- 1. Cómo se llama un filtro en la dirección: «Memoria RAM» → «memoria-ram»
--
-- TIENE QUE DAR LO MISMO QUE LA TIENDA, que arma la misma clave en TypeScript
-- para leer y escribir el `?filtros=` de la dirección. Si las dos no coinciden,
-- el visitante marca una casilla, la dirección se escribe con una clave y la
-- base busca por otra: el filtro no quita nada y nadie ve un error.
--
-- `fn_normalizar_nombre` ya pone minúsculas y quita tildes; aquí sólo queda
-- cambiar por un guion todo lo que no sea letra o número.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ecommerce.fn_clave_filtro(p_texto text)
RETURNS text
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
AS $fn$
    SELECT btrim(regexp_replace(ecommerce.fn_normalizar_nombre(p_texto),
                                '[^a-z0-9]+', '-', 'g'),
                 '-');
$fn$;

COMMENT ON FUNCTION ecommerce.fn_clave_filtro(text) IS
'El nombre de un filtro, como va en la dirección de la tienda: «Memoria RAM» → «memoria-ram». Tiene que dar lo mismo que claveDeFiltro() de miEcommerce.';

-- ----------------------------------------------------------------------------
-- 2. El valor de una característica, leído como número
--
-- El valor es TEXTO LIBRE: «1500», «1.500», «2,5», «150 cc», «Integrada».
-- Devuelve NULL cuando eso no es un número, y entonces ese valor no entra en
-- ninguna barra de desde–hasta y se sigue filtrando con casillas, aunque el
-- diccionario del CRM diga que la característica es NUMERO.
--
-- Mismo criterio que `aNumero()` en la tienda, y por el mismo motivo que la
-- clave: los dos tienen que estar de acuerdo en qué es un número.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ecommerce.fn_numero_de_texto(p_texto text)
RETURNS numeric
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
AS $fn$
DECLARE
    v text;
BEGIN
    v := regexp_replace(COALESCE(p_texto, ''), '\s', '', 'g');
    -- El punto de los miles, y sólo ése: 1.500 → 1500, pero 2.5 se queda
    v := regexp_replace(v, '\.(?=\d{3}(\D|$))', '', 'g');
    v := replace(v, ',', '.');

    IF v ~ '^-?\d+(\.\d+)?$' THEN
        RETURN v::numeric;
    END IF;
    RETURN NULL;
END;
$fn$;

COMMENT ON FUNCTION ecommerce.fn_numero_de_texto(text) IS
'El valor de una característica leído como número, o NULL si no lo es. Mismo criterio que aNumero() de miEcommerce.';

-- ----------------------------------------------------------------------------
-- 3. Para no recorrer la tabla entera por cada filtro pedido
-- ----------------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS ix_caracteristicas_prod_valor
    ON inventarios.caracteristicas_productos (producto_id)
 WHERE NULLIF(btrim(COALESCE(valor, '')), '') IS NOT NULL;

-- ----------------------------------------------------------------------------
-- 4. El catálogo, ahora con sus filtros por característica
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ecommerce.fn_tienda_productos(p_filtros jsonb DEFAULT '{}'::jsonb)
RETURNS jsonb
LANGUAGE sql
STABLE SECURITY DEFINER
AS $fn$
WITH RECURSIVE
param AS (
    SELECT NULLIF(btrim(COALESCE(p_filtros ->> 'marca', '')), '')::bigint            AS marca,
           COALESCE(NULLIF(btrim(COALESCE(p_filtros ->> 'sort', '')), ''), 'recent') AS orden,
           NULLIF(btrim(COALESCE(p_filtros ->> 'price_min', '')), '')::numeric       AS precio_min,
           NULLIF(btrim(COALESCE(p_filtros ->> 'price_max', '')), '')::numeric       AS precio_max,
           GREATEST(1, COALESCE(NULLIF(btrim(COALESCE(p_filtros ->> 'page', '')), '')::int, 1))
                                                                                     AS pagina,
           LEAST(48, GREATEST(1,
               COALESCE(NULLIF(btrim(COALESCE(p_filtros ->> 'per_page', '')), '')::int, 12)))
                                                                                     AS por_pagina
),
-- Qué parte de los productos que se están mirando tiene que llevar lleno un
-- filtro para que se ofrezca, y cuántos filtros se ofrecen como mucho
techos AS (SELECT 0.25::numeric AS parte_minima, 12 AS cuantos_filtros, 20 AS valores_maximos),
-- Las categorías pedidas, con toda su rama debajo: pedir «Tecnología» tiene
-- que traer lo que está en «Laptops»
pedidas AS (
    SELECT COALESCE(array_agg(DISTINCT r.id), ARRAY[]::bigint[]) AS ramas
      FROM regexp_split_to_table(COALESCE(p_filtros ->> 'categoria', ''), ',') AS x(uno)
      CROSS JOIN LATERAL unnest(ecommerce.fn_categorias_rama(NULLIF(btrim(x.uno), '')::bigint)) AS r(id)
     WHERE NULLIF(btrim(x.uno), '') IS NOT NULL
),
-- Lo marcado y lo pedido en las barras, ya desarmado por el controlador:
-- {"listas": {"color": ["Negro","Rojo"]}, "rangos": {"cilindraje": {"desde": 150}}}
filtros_lista AS (
    SELECT k.clave,
           ARRAY(SELECT btrim(v) FROM jsonb_array_elements_text(k.valores) AS v
                  WHERE NULLIF(btrim(v), '') IS NOT NULL) AS valores
      FROM jsonb_each(COALESCE(p_filtros -> 'facetas' -> 'listas', '{}'::jsonb)) AS k(clave, valores)
     WHERE jsonb_typeof(k.valores) = 'array'
),
filtros_lista_ok AS (SELECT * FROM filtros_lista WHERE cardinality(valores) > 0),
filtros_rango AS (
    SELECT k.clave,
           NULLIF(btrim(COALESCE(k.caja ->> 'desde', '')), '')::numeric AS desde,
           NULLIF(btrim(COALESCE(k.caja ->> 'hasta', '')), '')::numeric AS hasta
      FROM jsonb_each(COALESCE(p_filtros -> 'facetas' -> 'rangos', '{}'::jsonb)) AS k(clave, caja)
     WHERE jsonb_typeof(k.caja) = 'object'
),
filtros_rango_ok AS (SELECT * FROM filtros_rango WHERE desde IS NOT NULL OR hasta IS NOT NULL),
visibles AS (
    SELECT e.id, e.nombre FROM ecommerce.fn_categorias_web_estado() e WHERE e.estado = 'visible'
),
-- Cada categoría con la suya y todas las de encima: sirve para contar la rama
sube AS (
    SELECT c.id AS hoja, c.id AS nodo, c.padre_id
      FROM inventarios.categorias c
     WHERE c.deleted_at IS NULL
    UNION ALL
    SELECT s.hoja, pa.id, pa.padre_id
      FROM sube s
      JOIN inventarios.categorias pa ON pa.id = s.padre_id AND pa.deleted_at IS NULL
),
base AS (
    SELECT pr.id, pr.codigo, pr.nombre, pr.precio, pr.precio_anterior, pr.categoria_id, pr.marca_id, pr.created_at,
           pr.precio_tarjeta, pr.cuota_credito_directo,
           NULLIF(btrim(COALESCE(m.logo, '')), '')                    AS marca_logo,
           COALESCE(NULLIF(btrim(m.nombre), ''), '')                  AS marca,
           COALESCE(NULLIF(btrim(cw.nombre_web), ''), cat.nombre, '') AS categoria
      FROM inventarios.productos pr
      JOIN visibles v ON v.id = pr.categoria_id
      LEFT JOIN inventarios.marcas m        ON m.id   = pr.marca_id     AND m.deleted_at IS NULL
      LEFT JOIN inventarios.categorias cat  ON cat.id = pr.categoria_id AND cat.deleted_at IS NULL
      LEFT JOIN ecommerce.categorias_web cw ON cw.categoria_id = pr.categoria_id
     WHERE pr.deleted_at IS NULL
       AND pr.activo
       AND pr.en_paginaweb
),
-- ===== La ficha de cada producto, ya lista para filtrar =====
--
-- EL NOMBRE SALE DEL DICCIONARIO, no de la columna del producto: esa es una
-- foto de cómo se llamaba la característica el día que se rellenó, y si
-- después se renombró, agrupar por ella partiría el filtro en dos. Sólo
-- cuando no hay diccionario —una escrita a mano— se usa la foto.
--
-- SIN VALOR NO ES NADA: desde el 29/10/2026 una fila de caracteristicas_productos
-- significa «esta característica está en la lista de este producto, en esta
-- posición», y el valor puede estar vacío.
fichas_todas AS (
    SELECT c.producto_id,
           ecommerce.fn_clave_filtro(COALESCE(NULLIF(btrim(d.nombre), ''), btrim(c.nombre))) AS clave,
           COALESCE(NULLIF(btrim(d.nombre), ''), btrim(c.nombre))                            AS nombre,
           upper(COALESCE(NULLIF(btrim(d.tipo), ''), ''))                                    AS tipo,
           COALESCE(NULLIF(btrim(d.unidad), ''), '')                                         AS unidad,
           btrim(c.valor)                                                                    AS valor,
           ecommerce.fn_numero_de_texto(c.valor)                                             AS numero,
           c.orden, c.id
      FROM inventarios.caracteristicas_productos c
      JOIN base b ON b.id = c.producto_id
      LEFT JOIN inventarios.caracteristicas_nombres d ON d.id = c.nombre_id AND d.deleted_at IS NULL
     WHERE NULLIF(btrim(COALESCE(c.valor, '')), '') IS NOT NULL
       AND NULLIF(btrim(COALESCE(c.nombre, '')), '') IS NOT NULL
),
-- Un producto con la misma característica dos veces —una del diccionario y
-- otra escrita a mano con el mismo nombre— contaría dos veces en su propio
-- filtro. Se queda con la primera de su ficha, que es la que se le enseña.
fichas AS (
    SELECT DISTINCT ON (producto_id, clave) *
      FROM fichas_todas
     ORDER BY producto_id, clave, orden, id
),
-- ===== Qué filtros NO cumple cada producto =====
--
-- SIN EL DATO NO PASA: quien pide «hasta 30.000 km» no quiere ver las motos
-- que no dicen su kilometraje, igual que quien marca «Negro» no quiere las que
-- no dicen de qué color son. Es la misma regla que la sección del inicio.
--
-- SE MIRA DE UNA VEZ Y NO FILTRO A FILTRO: con un `NOT EXISTS` por cada filtro
-- pedido, la base recorría la ficha entera por cada producto y por cada filtro
-- —cuatro filtros sobre el catálogo eran dos millones de comparaciones y 110 ms
-- de nada—. Cruzando los productos con los filtros pedidos y pegando la ficha
-- UNA vez, el planificador lo resuelve con una sola pasada.
pedidos AS (
    SELECT 'lista'::text AS clase, clave, valores,       NULL::numeric AS desde, NULL::numeric AS hasta
      FROM filtros_lista_ok
    UNION ALL
    SELECT 'rango',              clave, NULL::text[],    desde,                  hasta
      FROM filtros_rango_ok
),
cumplidos AS (
    SELECT b.id, p.clave,
           bool_or(CASE WHEN p.clase = 'lista'
                        THEN f.valor = ANY (p.valores)
                        ELSE f.numero IS NOT NULL
                         AND (p.desde IS NULL OR f.numero >= p.desde)
                         AND (p.hasta IS NULL OR f.numero <= p.hasta)
                   END) AS cumple
      FROM base b
      CROSS JOIN pedidos p
      LEFT JOIN fichas f ON f.producto_id = b.id AND f.clave = p.clave
     GROUP BY b.id, p.clave
),
fallos AS (
    SELECT b.id,
           -- `c.clave IS NOT NULL` NO SOBRA: sin filtros pedidos no hay nada
           -- que cruzar y el LEFT JOIN deja una fila vacía por producto, que
           -- sin esto entra en el array como un NULL y deja TODO el catálogo
           -- fuera
           COALESCE(array_agg(c.clave) FILTER (WHERE c.clave IS NOT NULL
                                                 AND NOT COALESCE(c.cumple, false)),
                    ARRAY[]::text[]) AS claves_fallo
      FROM base b
      LEFT JOIN cumplidos c ON c.id = b.id
     GROUP BY b.id
),
-- Cada filtro por separado, para poder contar «con los demás menos el suyo»
marcados AS (
    SELECT b.*,
           fa.claves_fallo,
           (b.id IN (SELECT c.producto_id
                       FROM ecommerce.fn_tienda_casan(p_filtros ->> 'search') c)) AS pasa_texto,
           (cardinality((SELECT ramas FROM pedidas)) = 0
            OR b.categoria_id = ANY (SELECT unnest(p2.ramas) FROM pedidas p2))    AS pasa_categoria,
           ((SELECT marca FROM param) IS NULL
            OR b.marca_id = (SELECT marca FROM param))                            AS pasa_marca,
           (((SELECT precio_min FROM param) IS NULL OR b.precio >= (SELECT precio_min FROM param))
        AND ((SELECT precio_max FROM param) IS NULL OR b.precio <= (SELECT precio_max FROM param)))
                                                                                  AS pasa_precio
      FROM base b
      JOIN fallos fa ON fa.id = b.id
),
filtrados AS (
    SELECT * FROM marcados
     WHERE pasa_texto AND pasa_categoria AND pasa_marca AND pasa_precio
       AND cardinality(claves_fallo) = 0
),
-- Los productos de los que hablan los filtros por característica: los que
-- pasan lo demás —el texto, la categoría, la marca y el precio—, estén o no
-- dentro de lo marcado en las características
ambito AS (
    SELECT m.id, m.claves_fallo
      FROM marcados m
     WHERE m.pasa_texto AND m.pasa_categoria AND m.pasa_marca AND m.pasa_precio
),
cuenta AS (SELECT count(*)::int AS total FROM filtrados),
cuanto_ambito AS (SELECT count(*)::int AS total FROM ambito),
ultima AS (
    SELECT GREATEST(1, ceil((SELECT total FROM cuenta)::numeric
                            / (SELECT por_pagina FROM param))::int) AS n
),
pagina AS (SELECT LEAST((SELECT n FROM ultima), (SELECT pagina FROM param)) AS n),
lista AS (
    SELECT f.*, row_number() OVER (
               ORDER BY CASE WHEN (SELECT orden FROM param) = 'price_asc'  THEN f.precio END ASC  NULLS LAST,
                        CASE WHEN (SELECT orden FROM param) = 'price_desc' THEN f.precio END DESC NULLS LAST,
                        f.created_at DESC NULLS LAST, f.id DESC) AS puesto
      FROM filtrados f
),
pagina_lista AS (
    SELECT * FROM lista
     WHERE puesto >  ((SELECT n FROM pagina) - 1) * (SELECT por_pagina FROM param)
       AND puesto <=  (SELECT n FROM pagina)      * (SELECT por_pagina FROM param)
),
-- Las carátulas, sólo las de la página: la principal primero
fotos AS (
    SELECT i.producto_id,
           jsonb_agg(btrim(i.archivo) ORDER BY i.principal DESC, i.orden, i.id) AS imagenes
      FROM inventarios.productos_imagenes i
      JOIN pagina_lista pl ON pl.id = i.producto_id
     WHERE NULLIF(btrim(COALESCE(i.archivo, '')), '') IS NOT NULL
     GROUP BY i.producto_id
),
tarjetas AS (
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'pro_id',          pl.id,
               'codigo',          COALESCE(pl.codigo, ''),
               'nombre',          pl.nombre,
               'marca',           pl.marca,
               -- Nombre del fichero: la dirección la arma el controlador
               'marca_logo',      pl.marca_logo,
               'tpr_id',          pl.categoria_id,
               'categoria',       pl.categoria,
               -- Nombres de fichero: la dirección la arma el controlador
               'imagenes',        COALESCE(f.imagenes, '[]'::jsonb),
               'destacado',       false,
               'precio',          round(COALESCE(pl.precio, 0), 2),
               -- El de antes, para tacharlo; NULL = no está en oferta
               'precio_anterior', round(pl.precio_anterior, 2),
               -- Lo que cuesta con tarjeta de crédito, que es EL importe que
               -- enseña la tarjeta; NULL = el mismo que «precio»
               'precio_tarjeta',  round(pl.precio_tarjeta, 2),
               -- La cuota del crédito directo; NULL = no se ofrece y esa
               -- celda no se pinta
               'cuota_credito_directo', round(pl.cuota_credito_directo, 2),
               'stock',           1)
           ORDER BY pl.puesto), '[]'::jsonb) AS lista
      FROM pagina_lista pl
      LEFT JOIN fotos f ON f.producto_id = pl.id
),
op_marcas AS (
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'mar_id', t.marca_id, 'nombre', t.marca, 'cantidad', t.cuantos)
           ORDER BY t.marca), '[]'::jsonb) AS lista
      FROM (SELECT m.marca_id, m.marca, count(*)::int AS cuantos
              FROM marcados m
             WHERE m.pasa_texto AND m.pasa_categoria AND m.pasa_precio
               AND cardinality(m.claves_fallo) = 0
               AND m.marca_id IS NOT NULL AND m.marca <> ''
             GROUP BY m.marca_id, m.marca) t
),
op_categorias AS (
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'tpr_id', t.nodo, 'nombre', t.nombre, 'cantidad', t.cuantos)
           ORDER BY t.nombre), '[]'::jsonb) AS lista
      FROM (SELECT s.nodo, v.nombre, count(*)::int AS cuantos
              FROM marcados m
              JOIN sube s     ON s.hoja = m.categoria_id
              JOIN visibles v ON v.id   = s.nodo
             WHERE m.pasa_texto AND m.pasa_marca AND m.pasa_precio
               AND cardinality(m.claves_fallo) = 0
             GROUP BY s.nodo, v.nombre) t
),
op_precio AS (
    SELECT CASE WHEN count(*) = 0 THEN NULL
                ELSE jsonb_build_object('min', round(min(m.precio), 2),
                                        'max', round(max(m.precio), 2)) END AS caja
      FROM marcados m
     WHERE m.pasa_texto AND m.pasa_categoria AND m.pasa_marca
       AND cardinality(m.claves_fallo) = 0
),
-- ===== Los filtros por característica =====
--
-- Qué hay en el ámbito y cuántos productos lo llevan lleno
nombres_faceta AS (
    SELECT f.clave,
           min(f.nombre)                               AS nombre,
           min(f.tipo) FILTER (WHERE f.tipo <> '')     AS tipo,
           min(f.unidad) FILTER (WHERE f.unidad <> '') AS unidad,
           count(*)::int                               AS llenos,
           count(DISTINCT f.valor)::int                AS distintos
      FROM fichas f
      JOIN ambito a ON a.id = f.producto_id
     GROUP BY f.clave
),
-- Los que se ofrecen: los que lleva lleno una buena parte de lo que se está
-- mirando, más los que YA están marcados —que no se pueden esconder, porque
-- entonces no habría forma de quitarlos—. Y como mucho, doce.
elegidas AS (
    SELECT n.*,
           (n.clave IN (SELECT clave FROM filtros_lista_ok
                        UNION SELECT clave FROM filtros_rango_ok)) AS marcada
      FROM nombres_faceta n
     WHERE n.distintos >= 2
       -- Una lista de doscientas casillas no acota nada; un NÚMERO con muchos
       -- valores sí sirve, porque se pinta como barra de desde–hasta
       AND (COALESCE(n.tipo, '') = 'NUMERO'
            OR n.distintos <= (SELECT valores_maximos FROM techos))
),
facetas_ok AS (
    SELECT * FROM elegidas e
     WHERE e.marcada
        OR e.llenos::numeric >= (SELECT parte_minima FROM techos)
                                * GREATEST(1, (SELECT total FROM cuanto_ambito))
     ORDER BY e.marcada DESC, e.llenos DESC, e.nombre
     LIMIT (SELECT cuantos_filtros FROM techos)
),
-- Todos los valores que existen, con cuántos quedarían CON LOS DEMÁS FILTROS
-- PUESTOS Y SIN EL SUYO. Los que dan cero salen apagados en la tienda, no se
-- esconden: esconderlos movería la lista bajo el dedo a cada clic.
valores_faceta AS (
    SELECT f.clave, f.valor,
           count(*) FILTER (WHERE a.claves_fallo <@ ARRAY[f.clave])::int AS cuantos
      FROM fichas f
      JOIN ambito a     ON a.id    = f.producto_id
      JOIN facetas_ok k ON k.clave = f.clave
     GROUP BY f.clave, f.valor
),
-- Y todos los números distintos, sin filtrar: con ellos decide la tienda si
-- esto se pinta con casillas, con una barra o con dos listas de años
numeros_faceta AS (
    SELECT f.clave, f.numero
      FROM fichas f
      JOIN ambito a     ON a.id    = f.producto_id
      JOIN facetas_ok k ON k.clave = f.clave
     WHERE f.numero IS NOT NULL
     GROUP BY f.clave, f.numero
),
cuentas_faceta AS (
    SELECT f.clave,
           count(*)      FILTER (WHERE a.claves_fallo <@ ARRAY[f.clave])::int AS cuantos,
           min(f.numero) FILTER (WHERE a.claves_fallo <@ ARRAY[f.clave])      AS minimo,
           max(f.numero) FILTER (WHERE a.claves_fallo <@ ARRAY[f.clave])      AS maximo
      FROM fichas f
      JOIN ambito a     ON a.id    = f.producto_id
      JOIN facetas_ok k ON k.clave = f.clave
     GROUP BY f.clave
),
op_facetas AS (
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'clave',   k.clave,
               'nombre',  k.nombre,
               -- Del diccionario del CRM, no de mirar el valor: «Canales»
               -- vale 2.0, 2.1 y 5.1 y parece un número, pero no existe el 2.5
               'tipo',    COALESCE(k.tipo, ''),
               'unidad',  COALESCE(k.unidad, ''),
               'cuantos', COALESCE(c.cuantos, 0),
               'min',     c.minimo,
               'max',     c.maximo,
               'valores', COALESCE(v.lista, '[]'::jsonb),
               'numeros', COALESCE(n.lista, '[]'::jsonb))
           ORDER BY k.llenos DESC, k.nombre), '[]'::jsonb) AS lista
      FROM facetas_ok k
      LEFT JOIN cuentas_faceta c ON c.clave = k.clave
      LEFT JOIN LATERAL (
          SELECT jsonb_agg(jsonb_build_object('valor', vf.valor, 'cuantos', vf.cuantos)
                 ORDER BY vf.valor) AS lista
            FROM valores_faceta vf WHERE vf.clave = k.clave) v ON true
      LEFT JOIN LATERAL (
          SELECT jsonb_agg(nf.numero ORDER BY nf.numero) AS lista
            FROM numeros_faceta nf WHERE nf.clave = k.clave) n ON true
)
SELECT jsonb_build_object(
           'productos',     (SELECT lista FROM tarjetas),
           'total',         (SELECT total FROM cuenta),
           'pagina',        (SELECT n FROM pagina),
           'por_pagina',    (SELECT por_pagina FROM param),
           'ultima_pagina', (SELECT n FROM ultima),
           'opciones', jsonb_build_object(
               'categorias', (SELECT lista FROM op_categorias),
               'marcas',     (SELECT lista FROM op_marcas),
               'precio',     (SELECT caja  FROM op_precio),
               -- Los filtros por característica, contados aquí: la tienda sólo
               -- los pinta
               'facetas',    (SELECT lista FROM op_facetas)));
$fn$;

COMMENT ON FUNCTION ecommerce.fn_tienda_productos(jsonb) IS
'Una página del catálogo público con las opciones del panel: categorías, marcas, precio y los filtros por característica, todos contados «con los demás puestos y sin el suyo».';

-- ============================================================================
-- Que esto hace lo que dice
-- ============================================================================
DO $comprobar$
DECLARE
    v_todo      jsonb;
    v_facetas   jsonb;
    v_una       jsonb;
    v_clave     text;
    v_valor     text;
    v_antes     int;
    v_despues   int;
    v_cuantos   int;
BEGIN
    -- --- La clave de un filtro es la que espera la tienda ---
    IF ecommerce.fn_clave_filtro('Memoria RAM') <> 'memoria-ram' THEN
        RAISE EXCEPTION 'fn_clave_filtro: «Memoria RAM» dio «%»', ecommerce.fn_clave_filtro('Memoria RAM');
    END IF;
    IF ecommerce.fn_clave_filtro('Año de fabricación') <> 'ano-de-fabricacion' THEN
        RAISE EXCEPTION 'fn_clave_filtro: «Año de fabricación» dio «%»', ecommerce.fn_clave_filtro('Año de fabricación');
    END IF;
    IF ecommerce.fn_clave_filtro('Capacidad (BTU)') <> 'capacidad-btu' THEN
        RAISE EXCEPTION 'fn_clave_filtro: «Capacidad (BTU)» dio «%»', ecommerce.fn_clave_filtro('Capacidad (BTU)');
    END IF;

    -- --- Y los números se leen como los escribe cualquiera ---
    IF ecommerce.fn_numero_de_texto('1.500') <> 1500 THEN
        RAISE EXCEPTION 'fn_numero_de_texto: «1.500» dio %', ecommerce.fn_numero_de_texto('1.500');
    END IF;
    IF ecommerce.fn_numero_de_texto('2,5') <> 2.5 THEN
        RAISE EXCEPTION 'fn_numero_de_texto: «2,5» dio %', ecommerce.fn_numero_de_texto('2,5');
    END IF;
    IF ecommerce.fn_numero_de_texto('150 cc') IS NOT NULL THEN
        RAISE EXCEPTION 'fn_numero_de_texto: «150 cc» tenía que no ser número y dio %',
                        ecommerce.fn_numero_de_texto('150 cc');
    END IF;
    IF ecommerce.fn_numero_de_texto('Integrada') IS NOT NULL THEN
        RAISE EXCEPTION 'fn_numero_de_texto: «Integrada» tenía que no ser número';
    END IF;

    -- --- El catálogo sigue contestando, y ahora con filtros ---
    v_todo := ecommerce.fn_tienda_productos('{"per_page":1}'::jsonb);

    IF v_todo -> 'opciones' -> 'facetas' IS NULL THEN
        RAISE EXCEPTION 'La respuesta del catálogo no trae «opciones.facetas»';
    END IF;

    v_facetas := v_todo -> 'opciones' -> 'facetas';
    v_antes   := (v_todo ->> 'total')::int;

    IF v_antes < 1 THEN
        RAISE EXCEPTION 'El catálogo no devolvió ningún producto: no se puede comprobar nada';
    END IF;

    IF jsonb_array_length(v_facetas) = 0 THEN
        RAISE EXCEPTION 'El catálogo entero no ofrece ni un filtro por característica';
    END IF;

    IF jsonb_array_length(v_facetas) > 12 THEN
        RAISE EXCEPTION 'El catálogo ofrece % filtros, y el techo son 12', jsonb_array_length(v_facetas);
    END IF;

    -- --- Filtrar por el primer valor del primer filtro deja menos productos,
    --- y ese valor sigue contando lo mismo que contaba (es el suyo) ---
    v_una   := v_facetas -> 0;
    v_clave := v_una ->> 'clave';
    v_valor := v_una -> 'valores' -> 0 ->> 'valor';
    v_cuantos := (v_una -> 'valores' -> 0 ->> 'cuantos')::int;

    IF v_clave IS NULL OR v_valor IS NULL THEN
        RAISE EXCEPTION 'El primer filtro vino sin clave o sin valores: %', v_una;
    END IF;

    v_todo := ecommerce.fn_tienda_productos(
        jsonb_build_object('per_page', 1,
                           'facetas', jsonb_build_object(
                               'listas', jsonb_build_object(v_clave, jsonb_build_array(v_valor)))));
    v_despues := (v_todo ->> 'total')::int;

    IF v_despues <> v_cuantos THEN
        RAISE EXCEPTION 'Marcar «%» en «%» dejó % productos, y el filtro decía %',
                        v_valor, v_clave, v_despues, v_cuantos;
    END IF;

    IF v_despues >= v_antes THEN
        RAISE EXCEPTION 'Marcar «%» en «%» no quitó nada: % de %', v_valor, v_clave, v_despues, v_antes;
    END IF;

    -- --- Y su propio filtro se sigue contando SIN ÉL MISMO: los demás valores
    --- de esa lista tienen que seguir enseñando lo que enseñaban ---
    v_facetas := v_todo -> 'opciones' -> 'facetas';
    v_una := (SELECT x FROM jsonb_array_elements(v_facetas) AS x WHERE x ->> 'clave' = v_clave);

    IF v_una IS NULL THEN
        RAISE EXCEPTION 'El filtro «%», que está marcado, desapareció de la lista', v_clave;
    END IF;

    IF (v_una -> 'valores' -> 0 ->> 'cuantos')::int <> v_cuantos THEN
        RAISE EXCEPTION 'Con «%» marcado, su propia lista pasó a decir % en vez de %',
                        v_clave, (v_una -> 'valores' -> 0 ->> 'cuantos')::int, v_cuantos;
    END IF;

    -- --- Un filtro que no lleva ningún producto no rompe la página: deja el
    --- catálogo vacío, que es lo mismo que pedir un color que nadie tiene ---
    v_todo := ecommerce.fn_tienda_productos(
        jsonb_build_object('per_page', 1,
                           'facetas', jsonb_build_object(
                               'listas', jsonb_build_object('no-existe-este-filtro',
                                                            jsonb_build_array('nada')))));
    IF (v_todo ->> 'total')::int <> 0 THEN
        RAISE EXCEPTION 'Un filtro inventado tenía que no dejar nada y dejó %', (v_todo ->> 'total')::int;
    END IF;

    RAISE NOTICE 'Todo bien: % filtros por característica sobre % productos', jsonb_array_length(v_facetas), v_antes;
END;
$comprobar$;

COMMIT;
