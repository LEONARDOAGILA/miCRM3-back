-- ============================================================================
-- LOS ESCAPARATES PAGINADOS, PAGINADOS DESDE LA BASE
--
-- Un escaparate es una lista de productos que alguien arma a mano en el CRM
-- («Recomendados para ti», «Motos»). Hay dos maneras de enseñarlo:
--
--   · DE FILA —izquierda, derecha, cartel, sola—: tres, cuatro, diez
--     productos que se ven todos de una pasada con las flechas. Viajan
--     enteros, y así se quedan.
--   · PAGINADO: hace de catálogo. Enseña doce en rejilla, con sus filtros y
--     un botón «Ver más productos».
--
-- EL PAGINADO TAMBIÉN VIAJABA ENTERO. La página de /tecnologia mandaba sus
-- noventa y un productos CON LA FICHA DE CADA UNO —63 KB de JSON— para pintar
-- doce tarjetas, y el navegador los filtraba, los contaba y los iba soltando.
-- Con trescientos productos en una campaña eso son 200 KB antes de ver nada.
--
-- Desde hoy un escaparate es UN FILTRO MÁS DEL CATÁLOGO: fn_tienda_productos
-- acepta «escaparate» y hace con esa lista lo mismo que hace con /shop
-- —paginar, filtrar y contar los filtros «con los demás puestos y sin el
-- suyo»—, respetando el orden que se arrastró en el CRM.
--
-- LA PRIMERA PÁGINA SIGUE VIAJANDO CON LA PÁGINA, sin filtros: es lo que se ve
-- al entrar, y pedirla aparte dejaría /motos con su encabezado y un hueco. Lo
-- demás —otra página, un filtro marcado— lo pide la tienda al catálogo.
--
-- Y LA CATEGORÍA, LA MARCA Y EL PRECIO entran como filtros por característica
-- cuando se pide un escaparate. En /shop esos tres tienen su propio sitio en el
-- panel de la izquierda; en el cajón de un escaparate son persianas como las
-- demás, y entrando por el mismo camino no hay nada que traducir: lo que se
-- marca se escribe en la dirección igual que el resto («marca:Bajaj») y se
-- cuenta igual.
--
-- Idempotente: se puede correr dos veces.
-- ============================================================================

BEGIN;

-- ----------------------------------------------------------------------------
-- 1. El catálogo, que ahora sabe de escaparates
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ecommerce.fn_tienda_productos(p_filtros jsonb DEFAULT '{}'::jsonb)
RETURNS jsonb
LANGUAGE sql
STABLE SECURITY DEFINER
AS $fn$
WITH RECURSIVE
param AS (
    SELECT NULLIF(btrim(COALESCE(p_filtros ->> 'marca', '')), '')::bigint            AS marca,
           -- La lista de productos que alguien armó a mano en el CRM
           -- (ecommerce.producto_secciones). Sin esto, el catálogo entero
           NULLIF(btrim(COALESCE(p_filtros ->> 'escaparate', '')), '')::bigint        AS escaparate,
           COALESCE(NULLIF(btrim(COALESCE(p_filtros ->> 'sort', '')), ''), 'recent') AS orden,
           NULLIF(btrim(COALESCE(p_filtros ->> 'price_min', '')), '')::numeric       AS precio_min,
           NULLIF(btrim(COALESCE(p_filtros ->> 'price_max', '')), '')::numeric       AS precio_max,
           GREATEST(1, COALESCE(NULLIF(btrim(COALESCE(p_filtros ->> 'page', '')), '')::int, 1))
                                                                                     AS pagina,
           -- EL TECHO SON 120 Y NO 48: /shop pide 12, 24 o 48, pero un
           -- escaparate del inicio acumula («Ver más productos» añade debajo
           -- en vez de reemplazar), así que al volver a una dirección con
           -- diez páginas pulsadas pide las diez de una vez. Más allá de 120
           -- se recorta: una sola petición no puede traer el catálogo entero
           LEAST(120, GREATEST(1,
               COALESCE(NULLIF(btrim(COALESCE(p_filtros ->> 'per_page', '')), '')::int, 12)))
                                                                                     AS por_pagina
),
-- Qué parte de los productos que se están mirando tiene que llevar lleno un
-- filtro para que se ofrezca, y cuántos filtros se ofrecen como mucho
techos AS (
    SELECT 0.25::numeric AS parte_minima,
           -- Doce de la ficha. En un escaparate van además la categoría, la
           -- marca y el precio, que son de la tienda y no de la ficha: se
           -- SUMAN al techo en vez de quitarle el sitio a tres características
           12 + CASE WHEN (SELECT escaparate FROM param) IS NULL THEN 0 ELSE 3 END
                                AS cuantos_filtros,
           20                   AS valores_maximos
),
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
-- ===== Un escaparate: la lista de productos que alguien armó a mano =====
--
-- Hasta el 09/11/2026 esas listas viajaban ENTERAS dentro de la página
-- (fn_producto_seccion_publica) y el navegador las filtraba, las contaba y las
-- iba soltando de a doce: noventa y un productos con su ficha entera eran 63 KB
-- de JSON para enseñar doce tarjetas. Ahora un escaparate es UN FILTRO MÁS del
-- catálogo, con la misma paginación, los mismos filtros y las mismas cuentas
-- que /shop.
--
-- SU ORDEN ES EL QUE SE ELIGIÓ EN EL CRM, no el del catálogo: quien arma una
-- campaña pone primero lo que quiere que se vea primero. Pedir un orden por
-- precio sigue mandando sobre él.
--
-- Y NO SE LE EXIGE QUE LA CATEGORÍA ESTÉ VISIBLE EN LA TIENDA, que es la única
-- diferencia con el catálogo: son productos elegidos uno a uno, y el árbol de
-- categorías es para navegar. Esconder una categoría del menú no puede
-- vaciarle la campaña a quien la armó.
en_escaparate AS (
    SELECT it.producto_id, min(it.orden) AS orden
      FROM ecommerce.producto_secciones_items it
     WHERE it.seccion_id = (SELECT escaparate FROM param)
     GROUP BY it.producto_id
),
base AS (
    SELECT pr.id, pr.codigo, pr.nombre, pr.precio, pr.precio_anterior, pr.categoria_id, pr.marca_id, pr.created_at,
           pr.precio_tarjeta, pr.cuota_credito_directo,
           ee.orden                                                   AS orden_escaparate,
           NULLIF(btrim(COALESCE(m.logo, '')), '')                    AS marca_logo,
           COALESCE(NULLIF(btrim(m.nombre), ''), '')                  AS marca,
           COALESCE(NULLIF(btrim(cw.nombre_web), ''), cat.nombre, '') AS categoria
      FROM inventarios.productos pr
      -- LEFT y no JOIN: con un escaparate pedido manda su lista, no el árbol
      LEFT JOIN visibles v                  ON v.id  = pr.categoria_id
      LEFT JOIN en_escaparate ee            ON ee.producto_id = pr.id
      LEFT JOIN inventarios.marcas m        ON m.id   = pr.marca_id     AND m.deleted_at IS NULL
      LEFT JOIN inventarios.categorias cat  ON cat.id = pr.categoria_id AND cat.deleted_at IS NULL
      LEFT JOIN ecommerce.categorias_web cw ON cw.categoria_id = pr.categoria_id
     WHERE pr.deleted_at IS NULL
       AND pr.activo
       AND pr.en_paginaweb
       AND CASE WHEN (SELECT escaparate FROM param) IS NULL
                THEN v.id IS NOT NULL
                ELSE ee.orden IS NOT NULL END
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
-- ===== Y LOS TRES DE LA TIENDA: categoría, marca y precio =====
--
-- SÓLO EN UN ESCAPARATE. En /shop esos tres tienen su propio sitio en el panel
-- de la izquierda —con el árbol de categorías, que un escaparate no tiene— y
-- ofrecerlos además como persiana sería tenerlos dos veces.
--
-- En un escaparate no hay panel: está todo en el cajón de los filtros, y ahí
-- la marca es una persiana de casillas como el color y el precio una barra como
-- el cilindraje. Entrando por aquí no hay que traducir nada: lo que se marca se
-- escribe en la dirección igual que lo demás («marca:Bajaj»), viaja igual y se
-- cuenta igual. Antes del 09/11/2026 esto lo armaba el navegador, y era la
-- razón por la que necesitaba todos los productos.
--
-- EL PRECIO NO TIENE TEXTO, sólo número: es el único filtro que no sale de la
-- ficha de nadie —todos los productos tienen precio— y se pide siempre con una
-- barra de desde–hasta. Y es EL QUE SE LEE EN LA TARJETA, el de tarjeta de
-- crédito: acotar por otro dejaría fuera productos que el visitante está viendo
-- dentro del rango.
fichas_tienda AS (
    SELECT b.id AS producto_id, t.clave, t.nombre, t.tipo, ''::text AS unidad,
           t.valor, t.numero,
           -- Antes que cualquier característica, y con id 0: si alguien llamó
           -- «Marca» a una característica, manda la de la tienda
           t.orden, 0::bigint AS id
      FROM base b
      CROSS JOIN LATERAL (VALUES
          ('categoria', 'Categoría', '',       NULLIF(btrim(b.categoria), ''), NULL::numeric, -3),
          ('marca',     'Marca',     '',       NULLIF(btrim(b.marca), ''),     NULL::numeric, -2),
          ('precio',    'Precio',    'NUMERO', NULL::text, COALESCE(b.precio_tarjeta, b.precio), -1)
      ) AS t(clave, nombre, tipo, valor, numero, orden)
     WHERE (SELECT escaparate FROM param) IS NOT NULL
       AND (t.valor IS NOT NULL OR t.numero IS NOT NULL)
),
-- Un producto con la misma característica dos veces —una del diccionario y
-- otra escrita a mano con el mismo nombre— contaría dos veces en su propio
-- filtro. Se queda con la primera de su ficha, que es la que se le enseña.
fichas AS (
    SELECT DISTINCT ON (producto_id, clave) *
      FROM (SELECT * FROM fichas_todas UNION ALL SELECT * FROM fichas_tienda) todas
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
                        -- El de un escaparate es el que se arrastró en el CRM;
                        -- sin escaparate es NULL para todos y no pinta nada
                        f.orden_escaparate ASC NULLS LAST,
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
           -- Por el número cuando no hay texto: el precio no tiene valores que
           -- marcar, y contando sólo textos saldría con cero valores distintos
           -- y se caería del filtro de abajo
           count(DISTINCT COALESCE(f.valor, f.numero::text))::int AS distintos
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
     -- El precio no tiene: sólo números. Sin esto saldría una casilla vacía
     WHERE f.valor IS NOT NULL
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
'Una página del catálogo público con las opciones del panel: categorías, marcas, precio y los filtros por característica, todos contados «con los demás puestos y sin el suyo». Con «escaparate» son los productos de esa lista del CRM, en su orden, y la categoría, la marca y el precio salen también como filtros por característica.';


-- ----------------------------------------------------------------------------
-- 2. Los escaparates DE FILA, con la MISMA tarjeta que el catálogo
--
-- Dos cambios, y los dos para que la tienda tenga una sola forma de tarjeta:
--
-- SE VA LA FICHA DE CADA PRODUCTO. Viajaba para que el navegador armara los
-- filtros, y un escaparate de fila no tiene filtros: eran 51 KB de las 63 de
-- /tecnologia. Los paginados ya no pasan por aquí, y los suyos los cuenta la
-- base.
--
-- Y LA TARJETA ES LA DEL CATÁLOGO: `pro_id`, `tpr_id`, `imagenes`… las mismas
-- claves que manda fn_tienda_productos. Había dos formas de decir lo mismo
-- —`id` y `imagen`/`imagen_secundaria` aquí, `pro_id` e `imagenes` allá— y la
-- tienda tenía dos conversiones que mantener en paralelo; desde que los
-- escaparates paginados piden su página al catálogo, el mismo componente
-- recibiría las dos.
--
-- SÓLO LAS DOS PRIMERAS FOTOS, que es lo que pinta la tarjeta: la que se ve y
-- la que sale al pasar el mouse por encima. El catálogo manda la galería
-- entera porque de ahí sale también la ficha del producto.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ecommerce.fn_producto_seccion_publica(p_seccion_id bigint)
RETURNS jsonb
LANGUAGE sql
STABLE SECURITY DEFINER
AS $fn$
    SELECT COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
                   -- `pro_id` es además la REFERENCIA que se lee en la tarjeta,
                   -- y con él y el nombre la tienda arma sola la dirección de
                   -- la ficha
                   'pro_id',          p.id,
                   'codigo',          COALESCE(p.codigo, ''),
                   'nombre',          p.nombre,
                   -- La marca, para la pastilla de debajo del nombre. Van el
                   -- nombre Y el fichero del logo: casi ninguna marca tiene
                   -- logo todavía, y sin el nombre esas tarjetas se quedarían
                   -- con un hueco. Además es lo que describe al logo para
                   -- quien no ve la pantalla.
                   'marca',           COALESCE(NULLIF(btrim(m.nombre), ''), ''),
                   -- Nombre del fichero: la dirección la arma el controlador
                   'marca_logo',      NULLIF(btrim(COALESCE(m.logo, '')), ''),
                   -- La tienda lo usa SÓLO para saber si el producto es una
                   -- moto y enseñar nada más el botón de WhatsApp
                   'tpr_id',          p.categoria_id,
                   'categoria',       COALESCE(NULLIF(btrim(cw.nombre_web), ''), cat.nombre, ''),
                   -- SÓLO LAS DOS PRIMERAS de su galería: la que se ve y la que
                   -- sale al pasar el mouse por encima, que es lo único que
                   -- pinta la tarjeta. El catálogo manda la galería entera
                   -- porque de ahí sale también la ficha; aquí serían bytes
                   -- para nadie. Una sola consulta con LIMIT 2 y no dos
                   -- subconsultas: así no hay forma de que la «segunda» acabe
                   -- siendo la misma que la primera.
                   'imagenes',        COALESCE(fotos.lista, '[]'::jsonb),
                   'destacado',       false,
                   -- EL PRECIO DE VERDAD, el del catálogo. Hasta el 08/11/2026
                   -- la tarjeta se lo inventaba a partir del id porque esto no
                   -- se mandaba.
                   'precio',          round(COALESCE(p.precio, 0), 2),
                   -- Y el de antes, para tacharlo. NULL = no está en oferta, y
                   -- entonces la tarjeta no tacha nada ni saca el descuento.
                   'precio_anterior', round(p.precio_anterior, 2),
                   -- Lo que cuesta con tarjeta de crédito, que es EL importe
                   -- que enseña la tarjeta; NULL = el mismo que «precio»
                   'precio_tarjeta',  round(p.precio_tarjeta, 2),
                   -- La cuota del crédito directo; NULL = no se ofrece y esa
                   -- celda no se pinta
                   'cuota_credito_directo', round(p.cuota_credito_directo, 2),
                   'stock',           1)
               ORDER BY it.orden, p.id)
          FROM ecommerce.producto_secciones_items it
          JOIN inventarios.productos p ON p.id = it.producto_id
          -- LEFT: un producto sin marca sigue siendo un producto y su tarjeta
          -- tiene que salir igual
          LEFT JOIN inventarios.marcas m         ON m.id   = p.marca_id     AND m.deleted_at IS NULL
          LEFT JOIN inventarios.categorias cat   ON cat.id = p.categoria_id AND cat.deleted_at IS NULL
          LEFT JOIN ecommerce.categorias_web cw  ON cw.categoria_id = p.categoria_id
          LEFT JOIN LATERAL (
              SELECT jsonb_agg(g.archivo ORDER BY g.puesto) AS lista
                FROM (SELECT btrim(i.archivo) AS archivo,
                             row_number() OVER (ORDER BY i.principal DESC, i.orden, i.id) AS puesto
                        FROM inventarios.productos_imagenes i
                       WHERE i.producto_id = p.id
                         AND NULLIF(btrim(COALESCE(i.archivo, '')), '') IS NOT NULL) g
               WHERE g.puesto <= 2
          ) fotos ON true
         WHERE it.seccion_id = p_seccion_id
           AND p.deleted_at IS NULL
           AND p.activo
           AND p.en_paginaweb), '[]'::jsonb);
$fn$;

COMMENT ON FUNCTION ecommerce.fn_producto_seccion_publica(bigint) IS
'Los productos de un escaparate DE FILA del inicio, enteros y en su orden, con la MISMA tarjeta que manda el catálogo (fn_tienda_productos) y sólo las dos fotos que ésta pinta. Los escaparates paginados no pasan por aquí: piden una página al catálogo con «escaparate».';


-- ----------------------------------------------------------------------------
-- 3. La página, que ya no manda listas enteras
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ecommerce.fn_cuerpo_publico(p_ruta text DEFAULT NULL::text)
RETURNS jsonb
LANGUAGE sql
STABLE SECURITY DEFINER
AS $fn$
    WITH elegido AS (
        SELECT c.*
          FROM ecommerce.cuerpos c
         WHERE c.deleted_at IS NULL AND c.activo
           AND CASE WHEN nullif(btrim(COALESCE(p_ruta, '')), '') IS NULL
                    THEN c.principal
                    ELSE c.ruta = lower(btrim(p_ruta)) END
    ),
    visibles AS (
        SELECT s.clave, s.hasta, s.orden, s.producto_seccion_id, g.clave AS galeria_clave,
               -- En crudo y no sólo dentro de `imagen`: 'paginada' es la única
               -- manera de enseñar que pagina, y de eso depende si sus
               -- productos viajan enteros o de a una página
               s.disposicion,
               COALESCE(nullif(btrim(COALESCE(s.banner_vista, '')), ''), 'rotativo') AS banner_vista,
               s.segundos, s.por_pagina,
               COALESCE(nullif(btrim(COALESCE(s.forma, '')), ''), 'circulo') AS forma,
               COALESCE(nullif(btrim(COALESCE(s.alcance, '')), ''), 'tienda') AS alcance,
               nullif(btrim(COALESCE(s.titulo, '')), '')    AS titulo,
               nullif(btrim(COALESCE(s.subtitulo, '')), '') AS subtitulo,
               ecommerce.fn_rotulo_estilo(s.rotulo_tamano, s.rotulo_color, s.rotulo_fuente) AS estilo,
               ecommerce.fn_botones_colores(s.boton_favorito_color, s.boton_favorito_texto,
                                            s.boton_carrito_color,  s.boton_carrito_texto,
                                            s.boton_whatsapp_color, s.boton_whatsapp_texto,
                                            s.boton_tarjeta_color,  s.boton_tarjeta_texto) AS botones,
               ecommerce.fn_tarjeta_colores(s.tarjeta_fondo_color, s.tarjeta_borde_color,
                                            s.descuento_color,     s.descuento_texto,
                                            s.etiqueta, s.etiqueta_color, s.etiqueta_texto) AS tarjeta,
               ecommerce.fn_seccion_imagen(s.disposicion, s.imagen, s.imagen_alt,
                                           s.imagen_enlace, s.imagen_nueva_pestana) AS imagen,
               COALESCE(nullif(btrim(COALESCE(s.alto, '')), ''), 'normal') AS alto,
               e.categoria_id, e.marca_id
          FROM elegido e
          JOIN ecommerce.inicio_secciones s ON s.cuerpo_id = e.id
          LEFT JOIN ecommerce.galerias g ON g.id = s.galeria_id
         WHERE s.activo AND ecommerce.fn_vigente(s.desde, s.hasta)
           AND ecommerce.fn_inicio_seccion_viva(s.producto_seccion_id)
    ),
    armadas AS (
        SELECT v.orden, v.titulo, v.subtitulo, v.estilo, v.alto,
               CASE
                   -- Las de productos van primero y se reconocen por a quién
                   -- apuntan: su clave (`seccion_7`) la fabrica el servidor y
                   -- no hay lista donde buscarla.
                   WHEN v.producto_seccion_id IS NOT NULL THEN
                        jsonb_build_object('clave', 'productos',
                            'id', v.producto_seccion_id,
                            -- Cada cuántos segundos pasa sola de tarjeta; null = quieta
                            'segundos', v.segundos,
                            -- Cuántas tarjetas antes del botón «Ver más productos»
                            'por_pagina', v.por_pagina,
                            'botones', v.botones,
                            'tarjeta', v.tarjeta,
                            'imagen', v.imagen) || pag.datos
                   WHEN v.clave = 'banner_principal' THEN
                        jsonb_build_object('clave', v.clave,
                            'segundos', v.segundos,
                            -- Cuántas tarjetas antes del botón «Ver más productos»
                            'por_pagina', v.por_pagina,
                            -- Su galería; «inicio_banner» sólo si todavía no la
                            -- tiene enganchada
                            'imagenes', COALESCE(ecommerce.fn_galerias_publica(
                                COALESCE(v.galeria_clave, 'inicio_banner')) -> 'imagenes', '[]'::jsonb))
                   -- Cualquier otra sección con galería es un banner, y sale con
                   -- la clave que la tienda sabe pintar. Pueden ser varios.
                   WHEN v.galeria_clave IS NOT NULL THEN
                        jsonb_build_object('clave', 'banner_simple',
                            -- Rotando o en carteles. La tienda pinta una cosa u
                            -- otra con las MISMAS imágenes y sus mismos enlaces.
                            'vista', v.banner_vista,
                            -- Cada cuántos segundos cambia; null = el de la tienda
                            'segundos', v.segundos,
                            -- Cuántas tarjetas antes del botón «Ver más productos»
                            'por_pagina', v.por_pagina,
                            'imagenes', COALESCE(ecommerce.fn_galerias_publica(v.galeria_clave) -> 'imagenes', '[]'::jsonb))
                   WHEN v.clave = 'mosaico' THEN
                        jsonb_build_object('clave', v.clave,
                            'categorias', CASE
                                WHEN v.alcance = 'cuerpo' AND v.categoria_id IS NOT NULL
                                     THEN ecommerce.fn_categorias_promocion_hijas_publicas(v.categoria_id)
                                ELSE ecommerce.fn_categorias_promocion_publicas() END)
                   WHEN v.clave = 'categorias_destacadas' THEN
                        jsonb_build_object('clave', v.clave,
                            -- En círculo (lo de siempre) o en cuadros con el nombre encima
                            'forma', v.forma,
                            'categorias', CASE
                                -- Lo que cuelga de su categoría, o lo que tiene
                                -- productos de su marca
                                WHEN v.alcance = 'cuerpo' AND v.categoria_id IS NOT NULL
                                     THEN ecommerce.fn_categorias_hijas_publicas(v.categoria_id)
                                WHEN v.alcance = 'cuerpo' AND v.marca_id IS NOT NULL
                                     THEN ecommerce.fn_categorias_de_marca_publicas(v.marca_id)
                                ELSE ecommerce.fn_categorias_destacadas_publicas() END)
                   WHEN v.clave = 'marcas_promocion' THEN
                        jsonb_build_object('clave', v.clave,
                            'marcas', ecommerce.fn_marcas_promocion_publicas())
                   WHEN v.clave = 'marcas' THEN
                        jsonb_build_object('clave', v.clave,
                            'marcas', CASE
                                WHEN v.alcance = 'cuerpo' AND v.categoria_id IS NOT NULL
                                     THEN ecommerce.fn_marcas_de_categoria_publicas(v.categoria_id)
                                ELSE ecommerce.fn_marcas_publicas() END)
                   -- EL CATÁLOGO. Sus productos NO van aquí: los pide la
                   -- tienda, paginados, porque son cientos. Lo que viaja es
                   -- cómo se pinta y de qué habla la página, que sale del
                   -- cuerpo (sin categoría ni marca: todo el catálogo).
                   WHEN v.clave = 'catalogo' THEN
                        jsonb_build_object('clave', 'catalogo',
                            -- Cuántas tarjetas antes de «Ver más productos»
                            'por_pagina', v.por_pagina,
                            'botones', v.botones,
                            'tarjeta', v.tarjeta)
                   -- Las demás todavía no tienen de dónde sacar datos. Se
                   -- devuelven NULL y se caen en el filtro de abajo; la tienda
                   -- ni se entera.
                   ELSE NULL
               END AS seccion
          FROM visibles v
          -- ===== Los productos de un escaparate =====
          --
          -- LOS DE FILA VIAJAN ENTEROS: son tres, cuatro, diez, los que alguien
          -- eligió para que se vean todos de una pasada con las flechas.
          --
          -- LOS PAGINADOS, UNA PÁGINA, y con sus filtros ya contados sobre la
          -- lista entera. Son los que hacen de catálogo: hasta el 09/11/2026
          -- también viajaban enteros y el navegador los iba soltando de a doce,
          -- y el de /tecnologia eran 63 KB para pintar doce tarjetas.
          --
          -- LA PRIMERA PÁGINA VIAJA CON LA PÁGINA, SIN FILTROS, a propósito: es
          -- lo que se ve al entrar, y pedirla aparte dejaría /motos con su
          -- encabezado y un hueco hasta que llegara la segunda petición. Lo que
          -- la dirección pida de más —otra página, algo marcado— ya lo pide la
          -- tienda. Por eso tampoco depende de la dirección: esta respuesta se
          -- guarda un minuto y la comparten todos los visitantes.
          LEFT JOIN LATERAL (
              SELECT CASE
                  WHEN v.producto_seccion_id IS NULL THEN NULL
                  WHEN v.disposicion = 'paginada' THEN (
                      SELECT jsonb_build_object(
                                 'productos',     p.pagina -> 'productos',
                                 'total',         p.pagina -> 'total',
                                 'por_pagina',    p.pagina -> 'por_pagina',
                                 'ultima_pagina', p.pagina -> 'ultima_pagina',
                                 -- Los filtros, contados en la base sobre los
                                 -- productos del escaparate: los de la ficha y
                                 -- los tres de la tienda
                                 'facetas',       p.pagina -> 'opciones' -> 'facetas')
                        FROM (SELECT ecommerce.fn_tienda_productos(jsonb_build_object(
                                         'escaparate', v.producto_seccion_id,
                                         'per_page',   COALESCE(v.por_pagina, 12))) AS pagina) p)
                  ELSE jsonb_build_object('productos',
                           ecommerce.fn_producto_seccion_publica(v.producto_seccion_id))
              END AS datos
          ) pag ON true
    )
    SELECT jsonb_build_object(
        -- De qué página se habla: su título, su texto y si debajo va el
        -- catálogo. La tienda lo necesita antes de pintar nada.
        'cuerpo', (SELECT jsonb_build_object(
                       'id',          e.id,
                       'ruta',        e.ruta,
                       'url',         CASE WHEN e.principal THEN '/' ELSE '/' || e.ruta END,
                       'principal',   e.principal,
                       'titulo',      e.titulo,
                       'descripcion', e.descripcion,
                       -- El fondo de la página; null = blanco
                       'fondo',       e.fondo,
                       'catalogo',    e.catalogo,
                       'categoria_id', e.categoria_id,
                       -- El nombre con el que la tienda la llama, que puede no
                       -- ser el del catálogo
                       'categoria',   (SELECT COALESCE(w.nombre_web, c.nombre)
                                         FROM inventarios.categorias c
                                         LEFT JOIN ecommerce.categorias_web w ON w.categoria_id = c.id
                                        WHERE c.id = e.categoria_id),
                       'categoria_ruta', inventarios.fn_categoria_ruta(e.categoria_id),
                       -- La categoría Y TODAS LAS QUE CUELGAN de ella: los
                       -- productos cuelgan de las hojas, así que el catálogo
                       -- de Movilidad son los de sus hijas y sus nietas
                       'categorias_base', to_jsonb(ecommerce.fn_categorias_rama(e.categoria_id)),
                       'marca_id',    e.marca_id,
                       'marca',       (SELECT m.nombre FROM inventarios.marcas m WHERE m.id = e.marca_id))
                     FROM elegido e),
        'secciones', COALESCE((
            SELECT jsonb_agg(
                       -- El rótulo, su pinta y el alto se añaden aquí y no en
                       -- cada rama: son de la sección, no de lo que la llena, y
                       -- así no se olvidan en la siguiente que se traslade
                       a.seccion || jsonb_build_object('titulo', a.titulo, 'subtitulo', a.subtitulo,
                                                       'estilo', a.estilo, 'alto', a.alto)
                       ORDER BY a.orden)
              FROM armadas a
             WHERE a.seccion IS NOT NULL
               AND (a.seccion -> 'imagenes'   IS NULL OR jsonb_array_length(a.seccion -> 'imagenes') > 0)
               AND (a.seccion -> 'categorias' IS NULL OR jsonb_array_length(a.seccion -> 'categorias') > 0)
               AND (a.seccion -> 'marcas'     IS NULL OR jsonb_array_length(a.seccion -> 'marcas') > 0)
               -- Una sección de productos vacía no se manda: dejaría su título
               -- y nada debajo, que es peor que no estar.
               AND (a.seccion -> 'productos'  IS NULL OR jsonb_array_length(a.seccion -> 'productos') > 0)
            ), '[]'::jsonb))
      -- Sin página no se devuelve un objeto vacío: se devuelve nada, y el
      -- controlador contesta 404
     WHERE EXISTS (SELECT 1 FROM elegido);
$fn$;


-- ============================================================================
-- Que esto hace lo que dice
-- ============================================================================
DO $comprobar$
DECLARE
    v_esc       bigint;
    v_cuantos   int;
    v_pagina    jsonb;
    v_todo      jsonb;
    v_facetas   jsonb;
    v_una       jsonb;
    v_clave     text;
    v_valor     text;
    v_promete   int;
    v_deja      int;
    v_cuerpo    jsonb;
    v_seccion   jsonb;
BEGIN
    -- El escaparate con más productos, que es el que tiene algo que paginar
    SELECT it.seccion_id, count(*)::int
      INTO v_esc, v_cuantos
      FROM ecommerce.producto_secciones_items it
      JOIN inventarios.productos p ON p.id = it.producto_id
     WHERE p.deleted_at IS NULL AND p.activo AND p.en_paginaweb
     GROUP BY it.seccion_id
     ORDER BY count(*) DESC
     LIMIT 1;

    IF v_esc IS NULL OR v_cuantos < 13 THEN
        RAISE EXCEPTION 'No hay ningún escaparate con más de doce productos: no se puede comprobar la paginación';
    END IF;

    -- --- Una página es una página, y el total es la lista entera ---
    v_pagina := ecommerce.fn_tienda_productos(
        jsonb_build_object('escaparate', v_esc, 'per_page', 12));

    IF jsonb_array_length(v_pagina -> 'productos') <> 12 THEN
        RAISE EXCEPTION 'El escaparate % devolvió % tarjetas pidiendo 12',
                        v_esc, jsonb_array_length(v_pagina -> 'productos');
    END IF;

    IF (v_pagina ->> 'total')::int <> v_cuantos THEN
        RAISE EXCEPTION 'El escaparate % tiene % productos y dijo que tenía %',
                        v_esc, v_cuantos, (v_pagina ->> 'total')::int;
    END IF;

    -- --- Y es la lista del CRM, no el catálogo ---
    IF (v_pagina ->> 'total')::int >=
       (ecommerce.fn_tienda_productos('{"per_page":1}'::jsonb) ->> 'total')::int THEN
        RAISE EXCEPTION 'Pedir el escaparate % trajo tanto como el catálogo entero: no acotó nada', v_esc;
    END IF;

    -- --- En el orden que se arrastró en el CRM ---
    IF (v_pagina -> 'productos' -> 0 ->> 'pro_id')::bigint <>
       (SELECT it.producto_id
          FROM ecommerce.producto_secciones_items it
          JOIN inventarios.productos p ON p.id = it.producto_id
         WHERE it.seccion_id = v_esc
           AND p.deleted_at IS NULL AND p.activo AND p.en_paginaweb
         ORDER BY it.orden, p.id
         LIMIT 1) THEN
        RAISE EXCEPTION 'La primera tarjeta del escaparate % no es la primera de su lista', v_esc;
    END IF;

    -- --- La segunda página es otra, y la última cuadra ---
    IF ecommerce.fn_tienda_productos(jsonb_build_object('escaparate', v_esc, 'per_page', 12, 'page', 2))
           -> 'productos' -> 0 ->> 'pro_id'
       = v_pagina -> 'productos' -> 0 ->> 'pro_id' THEN
        RAISE EXCEPTION 'La página 2 del escaparate % empieza por la misma tarjeta que la 1', v_esc;
    END IF;

    IF (v_pagina ->> 'ultima_pagina')::int <> ceil(v_cuantos::numeric / 12)::int THEN
        RAISE EXCEPTION 'El escaparate % con % productos de a 12 dijo % páginas',
                        v_esc, v_cuantos, (v_pagina ->> 'ultima_pagina')::int;
    END IF;

    -- --- Trae sus filtros contados, y entre ellos los tres de la tienda ---
    v_facetas := v_pagina -> 'opciones' -> 'facetas';

    IF v_facetas IS NULL OR jsonb_array_length(v_facetas) = 0 THEN
        RAISE EXCEPTION 'El escaparate % no trajo ningún filtro', v_esc;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_facetas) x WHERE x ->> 'clave' = 'precio') THEN
        RAISE EXCEPTION 'El escaparate % no trajo el filtro del precio: %', v_esc, v_facetas;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_facetas) x WHERE x ->> 'clave' = 'marca') THEN
        RAISE EXCEPTION 'El escaparate % no trajo el filtro de la marca: %', v_esc, v_facetas;
    END IF;

    -- El precio se pide con una barra, así que no tiene valores que marcar
    v_una := (SELECT x FROM jsonb_array_elements(v_facetas) x WHERE x ->> 'clave' = 'precio');

    IF jsonb_array_length(v_una -> 'valores') <> 0 THEN
        RAISE EXCEPTION 'El filtro del precio trajo % valores de casilla: %',
                        jsonb_array_length(v_una -> 'valores'), v_una;
    END IF;

    IF (v_una ->> 'min') IS NULL OR (v_una ->> 'max') IS NULL THEN
        RAISE EXCEPTION 'El filtro del precio vino sin extremos: %', v_una;
    END IF;

    -- --- Y lo que un filtro promete es lo que deja ---
    v_una := (SELECT x FROM jsonb_array_elements(v_facetas) x WHERE x ->> 'clave' = 'marca');
    v_valor   := v_una -> 'valores' -> 0 ->> 'valor';
    v_promete := (v_una -> 'valores' -> 0 ->> 'cuantos')::int;

    IF v_valor IS NULL THEN
        RAISE EXCEPTION 'El filtro de la marca vino sin valores: %', v_una;
    END IF;

    v_todo := ecommerce.fn_tienda_productos(jsonb_build_object(
        'escaparate', v_esc, 'per_page', 1,
        'facetas', jsonb_build_object('listas', jsonb_build_object('marca', jsonb_build_array(v_valor)))));
    v_deja := (v_todo ->> 'total')::int;

    IF v_deja <> v_promete THEN
        RAISE EXCEPTION 'Marcar la marca «%» en el escaparate % dejó % productos, y el filtro decía %',
                        v_valor, v_esc, v_deja, v_promete;
    END IF;

    IF v_deja >= v_cuantos THEN
        RAISE EXCEPTION 'Marcar la marca «%» en el escaparate % no quitó nada: % de %',
                        v_valor, v_esc, v_deja, v_cuantos;
    END IF;

    -- --- Y su propia lista se sigue contando sin él mismo ---
    v_una := (SELECT x FROM jsonb_array_elements(v_todo -> 'opciones' -> 'facetas') x
               WHERE x ->> 'clave' = 'marca');

    IF v_una IS NULL THEN
        RAISE EXCEPTION 'La marca, que está marcada, desapareció de los filtros del escaparate %', v_esc;
    END IF;

    IF (v_una -> 'valores' -> 0 ->> 'cuantos')::int <> v_promete THEN
        RAISE EXCEPTION 'Con la marca marcada, su propia lista pasó a decir % en vez de %',
                        (v_una -> 'valores' -> 0 ->> 'cuantos')::int, v_promete;
    END IF;

    -- --- El catálogo de /shop sigue siendo el catálogo ---
    v_todo := ecommerce.fn_tienda_productos('{"per_page":12}'::jsonb);

    IF jsonb_array_length(v_todo -> 'productos') <> 12 THEN
        RAISE EXCEPTION 'El catálogo devolvió % tarjetas pidiendo 12',
                        jsonb_array_length(v_todo -> 'productos');
    END IF;

    IF jsonb_array_length(v_todo -> 'opciones' -> 'facetas') > 12 THEN
        RAISE EXCEPTION 'El catálogo ofrece % filtros, y su techo son 12',
                        jsonb_array_length(v_todo -> 'opciones' -> 'facetas');
    END IF;

    -- Y SIN los tres del escaparate: en /shop tienen su propio sitio en el panel
    IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_todo -> 'opciones' -> 'facetas') x
                WHERE x ->> 'clave' IN ('precio', 'marca', 'categoria')) THEN
        RAISE EXCEPTION 'El catálogo trajo el precio, la marca o la categoría como persiana: %',
                        v_todo -> 'opciones' -> 'facetas';
    END IF;

    -- --- Un escaparate de FILA sigue viajando entero, y sin la ficha ---
    IF jsonb_array_length(ecommerce.fn_producto_seccion_publica(v_esc)) <> v_cuantos THEN
        RAISE EXCEPTION 'fn_producto_seccion_publica dio % productos del escaparate % y tiene %',
                        jsonb_array_length(ecommerce.fn_producto_seccion_publica(v_esc)), v_esc, v_cuantos;
    END IF;

    IF (ecommerce.fn_producto_seccion_publica(v_esc) -> 0) ? 'caracteristicas' THEN
        RAISE EXCEPTION 'Un escaparate de fila sigue mandando la ficha de cada producto';
    END IF;

    -- Y es LA MISMA tarjeta que manda el catálogo, clave por clave: la tienda
    -- tiene una sola conversión y el mismo componente recibe las dos
    IF (SELECT array_agg(k ORDER BY k)
          FROM jsonb_object_keys(ecommerce.fn_producto_seccion_publica(v_esc) -> 0) k)
       IS DISTINCT FROM
       (SELECT array_agg(k ORDER BY k)
          FROM jsonb_object_keys(
                   ecommerce.fn_tienda_productos(
                       jsonb_build_object('escaparate', v_esc, 'per_page', 1)) -> 'productos' -> 0) k) THEN
        RAISE EXCEPTION 'La tarjeta de un escaparate de fila y la del catálogo ya no dicen lo mismo: % contra %',
                        (SELECT array_agg(k ORDER BY k)
                           FROM jsonb_object_keys(ecommerce.fn_producto_seccion_publica(v_esc) -> 0) k),
                        (SELECT array_agg(k ORDER BY k)
                           FROM jsonb_object_keys(
                                    ecommerce.fn_tienda_productos(
                                        jsonb_build_object('escaparate', v_esc, 'per_page', 1)) -> 'productos' -> 0) k);
    END IF;

    -- Pero con DOS fotos y no la galería entera: es lo único que pinta
    IF jsonb_array_length(ecommerce.fn_producto_seccion_publica(v_esc) -> 0 -> 'imagenes') > 2 THEN
        RAISE EXCEPTION 'Un escaparate de fila manda % fotos por tarjeta, y la tarjeta pinta dos',
                        jsonb_array_length(ecommerce.fn_producto_seccion_publica(v_esc) -> 0 -> 'imagenes');
    END IF;

    -- --- Y la página de la tienda manda una página, no la lista ---
    FOR v_cuerpo IN
        SELECT ecommerce.fn_cuerpo_publico(CASE WHEN c.principal THEN NULL ELSE c.ruta END)
          FROM ecommerce.cuerpos c WHERE c.deleted_at IS NULL AND c.activo
    LOOP
        FOR v_seccion IN SELECT x FROM jsonb_array_elements(v_cuerpo -> 'secciones') x
        LOOP
            CONTINUE WHEN v_seccion ->> 'clave' <> 'productos';

            IF v_seccion -> 'imagen' ->> 'lado' = 'paginada' THEN
                IF v_seccion -> 'facetas' IS NULL THEN
                    RAISE EXCEPTION 'El escaparate paginado % viajó sin sus filtros', v_seccion ->> 'id';
                END IF;
                IF (v_seccion ->> 'total')::int < jsonb_array_length(v_seccion -> 'productos') THEN
                    RAISE EXCEPTION 'El escaparate paginado % dice tener % productos y manda %',
                                    v_seccion ->> 'id', v_seccion ->> 'total',
                                    jsonb_array_length(v_seccion -> 'productos');
                END IF;
                IF jsonb_array_length(v_seccion -> 'productos')
                   > COALESCE((v_seccion ->> 'por_pagina')::int, 12) THEN
                    RAISE EXCEPTION 'El escaparate paginado % mandó % tarjetas y su página son %',
                                    v_seccion ->> 'id', jsonb_array_length(v_seccion -> 'productos'),
                                    v_seccion ->> 'por_pagina';
                END IF;
                IF NOT (v_seccion -> 'productos' -> 0) ? 'pro_id' THEN
                    RAISE EXCEPTION 'El escaparate paginado % no manda la tarjeta del catálogo: %',
                                    v_seccion ->> 'id', v_seccion -> 'productos' -> 0;
                END IF;
            ELSE
                IF v_seccion -> 'facetas' IS NOT NULL THEN
                    RAISE EXCEPTION 'El escaparate de fila % viajó con filtros, que no tiene',
                                    v_seccion ->> 'id';
                END IF;
                IF NOT (v_seccion -> 'productos' -> 0) ? 'pro_id' THEN
                    RAISE EXCEPTION 'El escaparate de fila % no manda la tarjeta de la tienda: %',
                                    v_seccion ->> 'id', v_seccion -> 'productos' -> 0;
                END IF;
                IF v_seccion -> 'total' IS NOT NULL THEN
                    RAISE EXCEPTION 'El escaparate de fila % viajó con un total, que no pagina',
                                    v_seccion ->> 'id';
                END IF;
            END IF;
        END LOOP;
    END LOOP;

    RAISE NOTICE 'Todo bien: el escaparate % pagina % productos de a 12 con % filtros',
                 v_esc, v_cuantos, jsonb_array_length(v_facetas);
END;
$comprobar$;

COMMIT;
