-- ============================================================================
-- ECOMMERCE · EL BUSCADOR DE LA TIENDA (y el catálogo que le hacía falta)
-- ============================================================================
-- Fecha: 2026-11-07
--
-- La tienda tiene su caja de buscar desde el primer día, pero no buscaba: al
-- enviar iba a `/shop?search=…`, y /shop pide `publico/productos`, que no
-- existía. Salía la página vacía.
--
-- Aquí va lo que faltaba, y es más que el buscador:
--
--   · `fn_tienda_casan`      LA REGLA DE QUÉ CASA CON LO ESCRITO, en un solo
--     sitio. La usan el catálogo y el desplegable, así que no pueden acabar
--     buscando de dos maneras distintas.
--
--   · `fn_tienda_productos`  EL CATÁLOGO PÚBLICO. Una página de productos con
--     sus filtros y, al lado, CUÁNTOS habría con cada opción del panel. Es lo
--     que piden /shop, las páginas de marca y España Motos. El contrato (los
--     nombres `pro_id`, `tpr_id`, `opciones`…) lo escribió el CRM anterior y
--     la tienda ya lo habla: se respeta tal cual para no tocar la tienda.
--
--   · `fn_tienda_buscador`   LO QUE SALE MIENTRAS SE ESCRIBE: unas pocas
--     sugerencias y las primeras fichas, como en marcimex.com. Por dentro
--     llama al catálogo, así que el desplegable y lo que sale al pulsar «ver
--     todos los N productos» no se pueden contradecir.
--
-- CÓMO SE BUSCA. Sin tildes y sin mayúsculas, por TROZOS DE PALABRA y con
-- TODAS las palabras: «barra sonido samsung» encuentra la barra de sonido de
-- Samsung aunque en el nombre vayan en otro orden y la marca no esté en el
-- nombre. Se mira el nombre, la marca, la categoría, el código y el modelo.
-- No hace falta `unaccent` ni `pg_trgm` (no están instalados en esta base):
-- con 218 productos recorrerlos todos no se nota, y el día que sean miles lo
-- que toca es un índice sobre `fn_texto_plano(nombre)`, no otra función.
--
-- QUÉ PRODUCTOS SALEN. Los activos, no borrados y de CATEGORÍA VISIBLE, que
-- es la misma regla del menú del encabezado (`fn_categorias_web_estado`): si
-- una categoría está oculta en el CRM, sus productos no se buscan.
--
-- DOS COSAS QUE EL CATÁLOGO TODAVÍA NO TIENE, y se mandan en claro:
--   · `stock` va a 1. No hay existencias en la base —ni tabla, ni kardex—, y
--     mandar 0 sacaría TODO como «Agotado», que es una mentira peor.
--   · `precio_anterior` va a null y `destacado` a false: tampoco hay de dónde
--     sacarlos, y la tienda sabe pintar sin ellos (sin tachado y sin chapa).
--     El precio SÍ es el de verdad, el de `inventarios.productos`. Ojo: las
--     secciones de la portada siguen enseñando un precio DE MUESTRA calculado
--     sobre el id; eso es de la tienda y se arregla aparte.
--
-- Idempotente.
-- ============================================================================
\set ON_ERROR_STOP on

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. TEXTO PLANO: lo que se compara
-- ---------------------------------------------------------------------------
-- Minúsculas, sin tildes y sin nada que no sea letra o número. Lo mismo se le
-- hace a lo que escribe quien busca y a lo que hay guardado, así que
-- «Televisión 55"» y «television 55» acaban siendo el mismo texto.
--
-- IMMUTABLE a propósito: así el día que haga falta se le puede poner un índice
-- encima sin cambiar nada de esto.
CREATE OR REPLACE FUNCTION ecommerce.fn_texto_plano(p_texto text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
AS $function$
    SELECT btrim(regexp_replace(
               translate(lower(COALESCE(p_texto, '')),
                         'áàäâãéèëêíìïîóòöôõúùüûñç',
                         'aaaaaeeeeiiiiooooouuuunc'),
               '[^a-z0-9]+', ' ', 'g'));
$function$;

-- ---------------------------------------------------------------------------
-- 2. QUÉ PRODUCTOS CASAN CON LO ESCRITO
-- ---------------------------------------------------------------------------
-- La regla de la búsqueda, en un solo sitio: la usan el catálogo (para
-- filtrar y para contar) y el desplegable (para las sugerencias).
--
-- SIN TEXTO DEVUELVE TODOS, que es lo que quiere decir «no filtres por texto»
-- y evita que quien llama tenga que preguntar si hay texto o no.
--
-- Devuelve sólo el id: quien lo usa ya tiene el producto a mano y lo que
-- necesita de aquí es el sí o el no.
CREATE OR REPLACE FUNCTION ecommerce.fn_tienda_casan(p_texto text)
 RETURNS TABLE(producto_id bigint)
 LANGUAGE sql
 STABLE
AS $function$
    WITH palabras AS (
        SELECT array_remove(string_to_array(ecommerce.fn_texto_plano(p_texto), ' '), '') AS lista
    )
    SELECT pr.id
      FROM inventarios.productos pr
      LEFT JOIN inventarios.marcas m        ON m.id   = pr.marca_id     AND m.deleted_at IS NULL
      LEFT JOIN inventarios.categorias cat  ON cat.id = pr.categoria_id AND cat.deleted_at IS NULL
      LEFT JOIN ecommerce.categorias_web cw ON cw.categoria_id = pr.categoria_id
     WHERE pr.deleted_at IS NULL
       AND pr.activo
       AND COALESCE((
           SELECT bool_and(ecommerce.fn_texto_plano(
                      concat_ws(' ', pr.nombre, m.nombre, cat.nombre,
                                     cw.nombre_web, pr.codigo, pr.modelo)) LIKE '%' || w || '%')
             FROM unnest((SELECT lista FROM palabras)) AS w), true);
$function$;

-- ---------------------------------------------------------------------------
-- 3. LA BASE DE ESPAÑA MOTOS
-- ---------------------------------------------------------------------------
-- El micro-sitio de motos busca con `motos=solo`: sólo lo que cuelga de las
-- categorías de sus pestañas. Sin pestañas configuradas no hay base, y
-- entonces `motos=solo` no devuelve nada: es la verdad —ahí no hay catálogo de
-- motos todavía— y no el catálogo entero disfrazado de motos.
CREATE OR REPLACE FUNCTION ecommerce.fn_tienda_motos_categorias()
 RETURNS bigint[]
 LANGUAGE sql
 STABLE
AS $function$
    SELECT COALESCE(array_agg(DISTINCT r.id), ARRAY[]::bigint[])
      FROM ecommerce.espana_motos_pestanas p
      CROSS JOIN LATERAL unnest(p.categorias) AS c(id)
      CROSS JOIN LATERAL unnest(ecommerce.fn_categorias_rama(c.id::bigint)) AS r(id)
     WHERE p.deleted_at IS NULL
       AND p.activo;
$function$;

-- ---------------------------------------------------------------------------
-- 4. EL CATÁLOGO PÚBLICO
-- ---------------------------------------------------------------------------
-- Entra un jsonb con lo que mandó la tienda en la dirección (`search`,
-- `categoria`, `marca`, `sort`, `price_min`, `price_max`, `page`, `per_page`,
-- `motos`) y sale la página pedida más las opciones del panel.
--
-- LAS OPCIONES SE CUENTAN CON LOS DEMÁS FILTROS, MENOS EL SUYO. Es lo que
-- espera la tienda y es lo que hace que el panel sirva: si las marcas se
-- contaran con la marca elegida puesta, todas saldrían a 0 menos una y no se
-- podría cambiar de marca sin quitar antes el filtro.
--
-- LA CANTIDAD DE UNA CATEGORÍA ES LA DE TODA SU RAMA: «Tecnología 26» cuenta
-- los de sus hijas, que es lo que alguien espera al verlo en el panel.
--
-- UNA PÁGINA FUERA DE SITIO DEVUELVE LA ÚLTIMA. Pedir la 9 de 3 páginas pasa
-- al llegar por una dirección vieja, y una lista vacía ahí parece un fallo.
CREATE OR REPLACE FUNCTION ecommerce.fn_tienda_productos(p_filtros jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
AS $function$
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
                                                                                     AS por_pagina,
           (COALESCE(p_filtros ->> 'motos', '') = 'solo')                            AS solo_motos
),
-- Las categorías pedidas, con toda su rama debajo: pedir «Tecnología» tiene
-- que traer lo que está en «Laptops»
pedidas AS (
    SELECT COALESCE(array_agg(DISTINCT r.id), ARRAY[]::bigint[]) AS ramas
      FROM regexp_split_to_table(COALESCE(p_filtros ->> 'categoria', ''), ',') AS x(uno)
      CROSS JOIN LATERAL unnest(ecommerce.fn_categorias_rama(NULLIF(btrim(x.uno), '')::bigint)) AS r(id)
     WHERE NULLIF(btrim(x.uno), '') IS NOT NULL
),
motos AS (
    SELECT CASE WHEN (SELECT solo_motos FROM param)
                THEN ecommerce.fn_tienda_motos_categorias()
                ELSE NULL::bigint[] END AS ramas
),
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
    SELECT pr.id, pr.codigo, pr.nombre, pr.precio, pr.categoria_id, pr.marca_id, pr.created_at,
           COALESCE(NULLIF(btrim(m.nombre), ''), '')                  AS marca,
           COALESCE(NULLIF(btrim(cw.nombre_web), ''), cat.nombre, '') AS categoria
      FROM inventarios.productos pr
      JOIN visibles v ON v.id = pr.categoria_id
      LEFT JOIN inventarios.marcas m        ON m.id   = pr.marca_id     AND m.deleted_at IS NULL
      LEFT JOIN inventarios.categorias cat  ON cat.id = pr.categoria_id AND cat.deleted_at IS NULL
      LEFT JOIN ecommerce.categorias_web cw ON cw.categoria_id = pr.categoria_id
     WHERE pr.deleted_at IS NULL
       AND pr.activo
),
-- Cada filtro por separado, para poder contar «con los demás menos el suyo»
marcados AS (
    SELECT b.*,
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
     WHERE (SELECT ramas FROM motos) IS NULL
        OR b.categoria_id = ANY (SELECT unnest(m2.ramas) FROM motos m2)
),
filtrados AS (
    SELECT * FROM marcados WHERE pasa_texto AND pasa_categoria AND pasa_marca AND pasa_precio
),
cuenta AS (SELECT count(*)::int AS total FROM filtrados),
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
               'tpr_id',          pl.categoria_id,
               'categoria',       pl.categoria,
               -- Nombres de fichero: la dirección la arma el controlador
               'imagenes',        COALESCE(f.imagenes, '[]'::jsonb),
               'destacado',       false,
               'precio',          round(COALESCE(pl.precio, 0), 2),
               'precio_anterior', NULL,
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
             GROUP BY s.nodo, v.nombre) t
),
op_precio AS (
    SELECT CASE WHEN count(*) = 0 THEN NULL
                ELSE jsonb_build_object('min', round(min(m.precio), 2),
                                        'max', round(max(m.precio), 2)) END AS caja
      FROM marcados m
     WHERE m.pasa_texto AND m.pasa_categoria AND m.pasa_marca
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
               'precio',     (SELECT caja  FROM op_precio)));
$function$;

-- ---------------------------------------------------------------------------
-- 5. EL DESPLEGABLE DE MIENTRAS SE ESCRIBE
-- ---------------------------------------------------------------------------
-- Tres cosas, y cada una tiene su por qué:
--
--   `productos`    las primeras fichas, porque muchas veces lo que se busca
--                  está ahí mismo y no hace falta ir a ninguna lista.
--   `total`        cuántos hay en total, que es lo que se escribe en el
--                  «Ver todos los N productos» del pie.
--   `sugerencias`  a dónde ir si lo de arriba no era:
--                    · `palabra`    cómo sigue lo que se está escribiendo
--                                   («lapt» → «laptop»), sacado de los
--                                   nombres de los productos que casan: no
--                                   hay diccionario que mantener y nunca
--                                   sugiere algo que no exista.
--                    · `categoria`  con SU CAMINO («Tecnología › Laptops»),
--                                   que es lo que distingue dos categorías
--                                   que se llaman parecido.
--                    · `marca`
--
-- CADA SUGERENCIA LLEVA SU ENLACE YA ARMADO y cuántos productos hay detrás.
-- Lo de «ya armado» es lo mismo que se hizo con el menú del encabezado: si
-- una categoría tiene su propia página de cuerpo se va a ella, y si no, al
-- catálogo filtrado. La tienda no tiene que saber nada de eso.
CREATE OR REPLACE FUNCTION ecommerce.fn_tienda_buscador(p_texto text, p_cuantos integer DEFAULT 6)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
AS $function$
WITH RECURSIVE
param AS (
    SELECT btrim(COALESCE(p_texto, ''))                        AS escrito,
           ecommerce.fn_texto_plano(p_texto)                   AS texto,
           LEAST(12, GREATEST(1, COALESCE(p_cuantos, 6)))      AS cuantos
),
-- La misma búsqueda del catálogo, para que las fichas de arriba y el «ver
-- todos» cuenten lo mismo
busqueda AS (
    SELECT ecommerce.fn_tienda_productos(jsonb_build_object(
               'search',   (SELECT escrito  FROM param),
               'page',     1,
               'per_page', (SELECT cuantos FROM param))) AS r
),
casan AS (
    SELECT pr.id, pr.nombre, pr.marca_id, pr.categoria_id,
           COALESCE(NULLIF(btrim(m.nombre), ''), '') AS marca
      FROM ecommerce.fn_tienda_casan((SELECT escrito FROM param)) c
      JOIN inventarios.productos pr ON pr.id = c.producto_id
      JOIN (SELECT e.id FROM ecommerce.fn_categorias_web_estado() e WHERE e.estado = 'visible') v
           ON v.id = pr.categoria_id
      LEFT JOIN inventarios.marcas m ON m.id = pr.marca_id AND m.deleted_at IS NULL
     WHERE (SELECT texto FROM param) <> ''
),
visibles AS (
    SELECT e.id, e.nombre FROM ecommerce.fn_categorias_web_estado() e WHERE e.estado = 'visible'
),
sube AS (
    SELECT c.id AS hoja, c.id AS nodo, c.padre_id, 0 AS salto
      FROM inventarios.categorias c
     WHERE c.deleted_at IS NULL
    UNION ALL
    SELECT s.hoja, pa.id, pa.padre_id, s.salto + 1
      FROM sube s
      JOIN inventarios.categorias pa ON pa.id = s.padre_id AND pa.deleted_at IS NULL
),
-- «Tecnología › Computadoras» para la categoría «Laptops»: lo de ENCIMA, de
-- arriba abajo. Sin padres queda null y la sugerencia sale sin camino
caminos AS (
    SELECT s.hoja, string_agg(v.nombre, ' › ' ORDER BY s.salto DESC) AS camino
      FROM sube s
      JOIN visibles v ON v.id = s.nodo
     WHERE s.salto > 0
     GROUP BY s.hoja
),
-- Cómo sigue la palabra que se está escribiendo. Se parten los nombres de los
-- productos que casan y se queda con las que EMPIEZAN por lo escrito; la que
-- es exactamente lo escrito no se sugiere (ya está escrita)
ultima_palabra AS (
    SELECT COALESCE((string_to_array((SELECT texto FROM param), ' '))
                    [cardinality(string_to_array((SELECT texto FROM param), ' '))], '') AS trozo
),
-- Lo escrito MENOS la última palabra. La sugerencia se completa sobre esto y
-- no sobre la palabra suelta: escribiendo «barra son», lo que se ofrece es
-- «barra sonido» y no «sonido», que buscaría otra cosa
prefijo AS (
    SELECT btrim(left((SELECT texto FROM param),
                      length((SELECT texto FROM param))
                      - length((SELECT trozo FROM ultima_palabra)))) AS antes
),
palabras AS (
    SELECT w.palabra, count(*)::int AS cuantos
      FROM casan c
      CROSS JOIN LATERAL unnest(string_to_array(ecommerce.fn_texto_plano(c.nombre), ' ')) AS w(palabra)
     WHERE (SELECT trozo FROM ultima_palabra) <> ''
       AND length(w.palabra) > 2
       AND w.palabra LIKE (SELECT trozo FROM ultima_palabra) || '%'
       AND w.palabra <> (SELECT trozo FROM ultima_palabra)
     GROUP BY w.palabra
     ORDER BY count(*) DESC, w.palabra
     LIMIT 4
),
sug_palabras AS (
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'tipo',    'palabra',
               'texto',   t.completo,
               'camino',  NULL,
               'cuantos', t.cuantos,
               -- El espacio es lo ÚNICO que hay que escapar: `completo` sale
               -- de `fn_texto_plano`, que deja sólo letras, números y espacios
               'enlace',  '/shop?search=' || replace(t.completo, ' ', '%20'))
           ORDER BY t.cuantos DESC, t.completo), '[]'::jsonb) AS lista
      FROM (SELECT CASE WHEN (SELECT antes FROM prefijo) = '' THEN p.palabra
                        ELSE (SELECT antes FROM prefijo) || ' ' || p.palabra END AS completo,
                   p.cuantos
              FROM palabras p) t
),
-- Las categorías que tienen productos de los que casan, contando la rama
sug_categorias AS (
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'tipo',    'categoria',
               'texto',   t.nombre,
               'camino',  t.camino,
               'cuantos', t.cuantos,
               'enlace',  COALESCE(ecommerce.fn_cuerpo_de_categoria(t.nodo),
                                   '/shop?categoria=' || t.nodo))
           ORDER BY t.cuantos DESC, t.nombre), '[]'::jsonb) AS lista
      FROM (SELECT s.nodo, v.nombre, cm.camino, count(*)::int AS cuantos
              FROM casan c
              JOIN sube s     ON s.hoja = c.categoria_id
              JOIN visibles v ON v.id   = s.nodo
              LEFT JOIN caminos cm ON cm.hoja = s.nodo
             GROUP BY s.nodo, v.nombre, cm.camino
             ORDER BY count(*) DESC, v.nombre
             LIMIT 4) t
),
sug_marcas AS (
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'tipo',    'marca',
               'texto',   t.marca,
               'camino',  NULL,
               'cuantos', t.cuantos,
               'enlace',  '/shop?marca=' || t.marca_id)
           ORDER BY t.cuantos DESC, t.marca), '[]'::jsonb) AS lista
      FROM (SELECT c.marca_id, c.marca, count(*)::int AS cuantos
              FROM casan c
             WHERE c.marca_id IS NOT NULL AND c.marca <> ''
             GROUP BY c.marca_id, c.marca
             ORDER BY count(*) DESC, c.marca
             LIMIT 3) t
)
SELECT jsonb_build_object(
           'texto',     (SELECT escrito FROM param),
           'total',     (SELECT (r ->> 'total')::int FROM busqueda),
           'productos', (SELECT r -> 'productos' FROM busqueda),
           -- Primero cómo sigue lo escrito, luego dónde mirar: es el orden en
           -- el que se lee la columna de la izquierda
           'sugerencias', (SELECT lista FROM sug_palabras)
                       || (SELECT lista FROM sug_categorias)
                       || (SELECT lista FROM sug_marcas));
$function$;

-- ---------------------------------------------------------------------------
-- 6. LA FICHA DE UN PRODUCTO
-- ---------------------------------------------------------------------------
-- Lo que pinta /product/:slug. Va aquí y no en otro fichero porque es la otra
-- mitad de lo mismo: sin ficha, buscar lleva a una página que no existe.
--
-- DEVUELVE NULL SI NO SE PUEDE VER —no existe, está borrado, está apagado o su
-- categoría está oculta— y el controlador contesta 404. La tienda ya sabe
-- pintar su «no encontrado»: es mejor eso que una ficha a medias.
--
-- `franjas` VA VACÍA: son las cintas de la columna de compra («18 meses sin
-- intereses»…) y todavía no hay dónde escribirlas en el CRM. La tienda no
-- pinta el bloque si no llegan.
--
-- `relacionados` SALE DEL MISMO CATÁLOGO DE ARRIBA, pidiéndole su categoría:
-- así respeta las mismas reglas de qué se puede ver y tiene la misma forma de
-- tarjeta, sin una segunda consulta que mantener.
CREATE OR REPLACE FUNCTION ecommerce.fn_tienda_producto(p_id bigint)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
AS $function$
WITH
uno AS (
    SELECT pr.id, pr.codigo, pr.nombre, pr.descripcion, pr.precio, pr.categoria_id,
           COALESCE(NULLIF(btrim(cw.nombre_web), ''), cat.nombre, '') AS categoria,
           m.id AS marca_id, m.nombre AS marca, NULLIF(btrim(COALESCE(m.logo, '')), '') AS logo
      FROM inventarios.productos pr
      JOIN (SELECT e.id FROM ecommerce.fn_categorias_web_estado() e WHERE e.estado = 'visible') v
           ON v.id = pr.categoria_id
      LEFT JOIN inventarios.marcas m        ON m.id   = pr.marca_id     AND m.deleted_at IS NULL
      LEFT JOIN inventarios.categorias cat  ON cat.id = pr.categoria_id AND cat.deleted_at IS NULL
      LEFT JOIN ecommerce.categorias_web cw ON cw.categoria_id = pr.categoria_id
     WHERE pr.id = p_id
       AND pr.deleted_at IS NULL
       AND pr.activo
),
fotos AS (
    SELECT COALESCE(jsonb_agg(btrim(i.archivo) ORDER BY i.principal DESC, i.orden, i.id), '[]'::jsonb) AS lista
      FROM inventarios.productos_imagenes i
     WHERE i.producto_id = p_id
       AND NULLIF(btrim(COALESCE(i.archivo, '')), '') IS NOT NULL
),
-- La ficha técnica: lo que se llenó, con la unidad que vive en el diccionario
-- («1500» + «W»). Sin valor no es una fila, es un hueco
ficha AS (
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'nombre', c.nombre,
               'valor',  btrim(c.valor),
               'unidad', NULLIF(btrim(COALESCE(n.unidad, '')), ''))
           ORDER BY c.orden, c.id), '[]'::jsonb) AS lista
      FROM inventarios.caracteristicas_productos c
      LEFT JOIN inventarios.caracteristicas_nombres n ON n.id = c.nombre_id
     WHERE c.producto_id = p_id
       AND NULLIF(btrim(COALESCE(c.valor, '')), '') IS NOT NULL
       AND NULLIF(btrim(COALESCE(c.nombre, '')), '') IS NOT NULL
),
relacionados AS (
    SELECT COALESCE(jsonb_agg(x.t ORDER BY x.ord), '[]'::jsonb) AS lista
      FROM (SELECT t, row_number() OVER () AS ord
              FROM jsonb_array_elements(
                       ecommerce.fn_tienda_productos(jsonb_build_object(
                           'categoria', (SELECT categoria_id FROM uno),
                           'per_page',  9)) -> 'productos') AS t
             WHERE (t ->> 'pro_id')::bigint <> p_id
             LIMIT 8) x
)
SELECT jsonb_build_object(
           'producto', jsonb_build_object(
               'pro_id',          u.id,
               'codigo',          COALESCE(u.codigo, ''),
               'nombre',          u.nombre,
               'descripcion',     NULLIF(btrim(COALESCE(u.descripcion, '')), ''),
               'tpr_id',          u.categoria_id,
               'categoria',       u.categoria,
               'destacado',       false,
               'imagenes',        (SELECT lista FROM fotos),
               'ficha',           (SELECT lista FROM ficha),
               'precio',          round(COALESCE(u.precio, 0), 2),
               'precio_anterior', NULL,
               'marca', CASE WHEN u.marca_id IS NULL THEN NULL ELSE jsonb_build_object(
                   'mar_id', u.marca_id,
                   'nombre', u.marca,
                   'logo',   u.logo,
                   -- Al catálogo filtrado y no a /marca/…: esa página todavía
                   -- no tiene de dónde sacar sus datos
                   'enlace', '/shop?marca=' || u.marca_id) END),
           'franjas',      '[]'::jsonb,
           'relacionados', (SELECT lista FROM relacionados))
  FROM uno u;
$function$;

-- ---------------------------------------------------------------------------
-- COMPROBACIÓN
-- ---------------------------------------------------------------------------
-- Todo lo de aquí es de lectura: no hace falta deshacer nada.
DO $comprobar$
DECLARE
    v_r       jsonb;
    v_total   int;
    v_uno     jsonb;
    v_nombre  text;
BEGIN
    -- 1. El texto plano
    IF ecommerce.fn_texto_plano('Televisión 55" Súper') <> 'television 55 super' THEN
        RAISE EXCEPTION 'fn_texto_plano no deja el texto como debe: «%»',
              ecommerce.fn_texto_plano('Televisión 55" Súper');
    END IF;

    -- 2. El catálogo: el contrato que habla la tienda
    v_r := ecommerce.fn_tienda_productos('{}'::jsonb);
    IF NOT (v_r ? 'productos' AND v_r ? 'total' AND v_r ? 'pagina'
            AND v_r ? 'por_pagina' AND v_r ? 'ultima_pagina' AND v_r ? 'opciones') THEN
        RAISE EXCEPTION 'Al catálogo le falta alguna clave del contrato: %',
              (SELECT string_agg(k, ', ') FROM jsonb_object_keys(v_r) k);
    END IF;
    IF NOT (v_r -> 'opciones' ? 'categorias' AND v_r -> 'opciones' ? 'marcas'
            AND v_r -> 'opciones' ? 'precio') THEN
        RAISE EXCEPTION 'A las opciones del panel les falta algo: %', v_r -> 'opciones';
    END IF;

    v_total := (v_r ->> 'total')::int;
    IF v_total = 0 THEN
        RAISE NOTICE 'No hay productos visibles: me salto el resto de la comprobación.';
        RETURN;
    END IF;

    v_uno := v_r -> 'productos' -> 0;
    IF NOT (v_uno ? 'pro_id' AND v_uno ? 'nombre' AND v_uno ? 'precio'
            AND v_uno ? 'imagenes' AND v_uno ? 'stock' AND v_uno ? 'tpr_id') THEN
        RAISE EXCEPTION 'A la tarjeta le falta alguna clave: %', v_uno;
    END IF;
    IF (v_uno ->> 'stock')::int <= 0 THEN
        RAISE EXCEPTION 'El stock no puede salir en 0: la tienda pondría «Agotado» en todo';
    END IF;

    -- 3. Una página fuera de sitio devuelve la última, no una lista vacía
    v_r := ecommerce.fn_tienda_productos('{"page": 999, "per_page": 12}'::jsonb);
    IF (v_r ->> 'pagina')::int <> (v_r ->> 'ultima_pagina')::int THEN
        RAISE EXCEPTION 'La página 999 tenía que volver a la última y volvió a la %',
              v_r ->> 'pagina';
    END IF;
    IF jsonb_array_length(v_r -> 'productos') = 0 THEN
        RAISE EXCEPTION 'La última página salió vacía';
    END IF;

    -- 4. Buscar por un trozo del nombre de un producto que existe, sin tildes
    --    y en minúsculas, tiene que encontrarlo
    SELECT p.nombre INTO v_nombre
      FROM inventarios.productos p
      JOIN (SELECT e.id FROM ecommerce.fn_categorias_web_estado() e WHERE e.estado = 'visible') v
           ON v.id = p.categoria_id
     WHERE p.deleted_at IS NULL AND p.activo
     ORDER BY p.id
     LIMIT 1;

    v_r := ecommerce.fn_tienda_productos(
               jsonb_build_object('search', ecommerce.fn_texto_plano(v_nombre)));
    IF (v_r ->> 'total')::int = 0 THEN
        RAISE EXCEPTION 'Buscar «%» no encontró ni el producto del que salió', v_nombre;
    END IF;

    -- 5. El desplegable: las mismas cuentas y sus sugerencias
    v_r := ecommerce.fn_tienda_buscador(split_part(v_nombre, ' ', 1), 4);
    IF NOT (v_r ? 'texto' AND v_r ? 'total' AND v_r ? 'productos' AND v_r ? 'sugerencias') THEN
        RAISE EXCEPTION 'Al desplegable le falta alguna clave: %', v_r;
    END IF;
    IF jsonb_array_length(v_r -> 'productos') > 4 THEN
        RAISE EXCEPTION 'El desplegable mandó % fichas y se le pidieron 4',
              jsonb_array_length(v_r -> 'productos');
    END IF;
    IF (v_r ->> 'total')::int <> (ecommerce.fn_tienda_productos(
           jsonb_build_object('search', split_part(v_nombre, ' ', 1))) ->> 'total')::int THEN
        RAISE EXCEPTION 'El desplegable y el catálogo no cuentan lo mismo';
    END IF;
    IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_r -> 'sugerencias') s
                WHERE NULLIF(btrim(COALESCE(s ->> 'enlace', '')), '') IS NULL) THEN
        RAISE EXCEPTION 'Una sugerencia salió sin enlace: %', v_r -> 'sugerencias';
    END IF;

    -- 6. Sin texto no se sugiere nada, pero el catálogo sigue entero
    v_r := ecommerce.fn_tienda_buscador('', 6);
    IF jsonb_array_length(v_r -> 'sugerencias') <> 0 THEN
        RAISE EXCEPTION 'Sin texto no puede haber sugerencias: %', v_r -> 'sugerencias';
    END IF;

    -- 7. La ficha del primer producto del catálogo
    v_uno := ecommerce.fn_tienda_productos('{"per_page": 1}'::jsonb) -> 'productos' -> 0;
    v_r := ecommerce.fn_tienda_producto((v_uno ->> 'pro_id')::bigint);
    IF v_r IS NULL THEN
        RAISE EXCEPTION 'La ficha del producto % salió vacía y está en el catálogo',
              v_uno ->> 'pro_id';
    END IF;
    IF NOT (v_r ? 'producto' AND v_r ? 'franjas' AND v_r ? 'relacionados') THEN
        RAISE EXCEPTION 'A la ficha le falta alguna clave: %',
              (SELECT string_agg(k, ', ') FROM jsonb_object_keys(v_r) k);
    END IF;
    IF (v_r -> 'producto' ->> 'pro_id') <> (v_uno ->> 'pro_id') THEN
        RAISE EXCEPTION 'La ficha devolvió otro producto';
    END IF;
    -- Un producto no puede ser su propio relacionado
    IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_r -> 'relacionados') r
                WHERE r ->> 'pro_id' = v_uno ->> 'pro_id') THEN
        RAISE EXCEPTION 'El producto salió entre sus propios relacionados';
    END IF;

    -- 8. Un id que no existe no es una ficha vacía: es NULL, y el controlador
    --    contesta 404
    IF ecommerce.fn_tienda_producto(-1) IS NOT NULL THEN
        RAISE EXCEPTION 'La ficha de un id que no existe tenía que salir NULL';
    END IF;

    RAISE NOTICE 'Comprobado: catálogo de % productos, búsqueda sin tildes, página fuera de sitio y desplegable.',
          v_total;
END
$comprobar$;

COMMIT;
