-- ============================================================================
-- UNA SOLA TARJETA DE PRODUCTO EN TODA LA TIENDA
-- ============================================================================
-- La tienda tenía DOS tarjetas de producto distintas:
--
--   · la de los escaparates del CRM (`fn_producto_seccion_publica`), que es la
--     nueva: marca con logo, referencia, «Tarjeta Crédito» y «Crédito Directo
--     — cuotas desde», el cartel del descuento calculado de los dos precios y
--     los tres caminos de compra;
--   · la del catálogo (`fn_tienda_productos`), que es la vieja: un precio, un
--     tachado y dos botones.
--
-- Se queda la primera, y entonces el catálogo tiene que mandar los mismos
-- datos. Hoy le faltan tres:
--
--   · `precio_tarjeta`          lo que cuesta con tarjeta de crédito, que es EL
--                               importe que la tarjeta enseña en grande. NULL =
--                               el mismo que `precio`, que es lo normal;
--   · `cuota_credito_directo`   la cuota de «Cuotas desde». NULL = este producto
--                               no se ofrece a crédito directo, y esa celda no
--                               se pinta. NO se calcula dividiendo el precio:
--                               el plazo lo pone el negocio;
--   · `marca_logo`              el fichero del logo de la marca, para la
--                               pastilla de debajo del nombre. Sin él se
--                               escribe el nombre, que es el caso normal.
--
-- Son las MISMAS columnas de `inventarios.productos` que ya leen los
-- escaparates: no se crea nada, sólo viajan también por aquí. Con esto la
-- tarjeta del catálogo, la de los relacionados de la ficha, la del buscador y
-- la de las páginas de marca cuentan lo mismo que la de un escaparate, que es
-- lo que hoy no pasa: el mismo producto en oferta se ve tachado en la portada
-- y sin tachar en /shop.
--
-- Y SE ARREGLA EL `precio_anterior` DE LA FICHA, que iba escrito a mano en
-- NULL: la ficha del producto (/product/…) no podía tachar nada aunque el
-- producto estuviera en oferta y su propia tarjeta sí lo tachara.
--
-- Todo son funciones: se puede volver a correr sin consecuencias.
-- ============================================================================

BEGIN;

-- Parchea un trozo de la definición de una función y FALLA si el trozo no
-- aparece EXACTAMENTE UNA VEZ. Sin esto, `replace()` que no encuentra nada
-- devuelve el texto igual, la migración dice que fue bien y la función se queda
-- como estaba.
CREATE OR REPLACE FUNCTION pg_temp.parchar(p_texto text, p_viejo text, p_nuevo text, p_donde text)
RETURNS text
LANGUAGE plpgsql
AS $parchar$
DECLARE
    v_veces int;
BEGIN
    v_veces := (length(p_texto) - length(replace(p_texto, p_viejo, '')))
               / GREATEST(length(p_viejo), 1);

    IF v_veces <> 1 THEN
        RAISE EXCEPTION 'Parche de %: esperaba UNA aparición de «%…» y encontré %',
              p_donde, left(p_viejo, 70), v_veces;
    END IF;

    RETURN replace(p_texto, p_viejo, p_nuevo);
END;
$parchar$;


-- ============================================================================
-- 1. EL CATÁLOGO (fn_tienda_productos)
-- ============================================================================
-- Es la fuente de TODAS las tarjetas que no son de un escaparate: /shop, el
-- desplegable del buscador, los relacionados de la ficha y las páginas de
-- marca pasan por aquí.
DO $catalogo$
DECLARE
    v_def text;
BEGIN
    SELECT pg_get_functiondef(p.oid) INTO v_def
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'ecommerce' AND p.proname = 'fn_tienda_productos';

    IF v_def IS NULL THEN
        RAISE EXCEPTION 'No existe ecommerce.fn_tienda_productos' USING ERRCODE = 'P0001';
    END IF;

    IF position('''precio_tarjeta''' IN v_def) > 0 THEN
        RAISE NOTICE 'fn_tienda_productos ya mandaba los precios de la tarjeta.';
        RETURN;
    END IF;

    -- Las columnas, en el CTE que lee el catálogo
    v_def := pg_temp.parchar(v_def,
        'pr.marca_id, pr.created_at,',
        'pr.marca_id, pr.created_at,' || E'\n'
        || '           pr.precio_tarjeta, pr.cuota_credito_directo,' || E'\n'
        || '           NULLIF(btrim(COALESCE(m.logo, '''')), '''')                    AS marca_logo,',
        'fn_tienda_productos (columnas)');

    -- El logo, junto al nombre de la marca. Van los dos a propósito: casi
    -- ninguna marca tiene logo cargado todavía, y sin el nombre la mayoría de
    -- las tarjetas dejaría ese hueco en blanco
    v_def := pg_temp.parchar(v_def,
        'pl.marca,',
        'pl.marca,' || E'\n'
        || '               -- Nombre del fichero: la dirección la arma el controlador' || E'\n'
        || '               ''marca_logo'',      pl.marca_logo,',
        'fn_tienda_productos (marca_logo)');

    -- Y los dos precios que faltaban
    v_def := pg_temp.parchar(v_def,
        '''stock'',',
        '-- Lo que cuesta con tarjeta de crédito, que es EL importe que' || E'\n'
        || '               -- enseña la tarjeta; NULL = el mismo que «precio»' || E'\n'
        || '               ''precio_tarjeta'',  round(pl.precio_tarjeta, 2),' || E'\n'
        || '               -- La cuota del crédito directo; NULL = no se ofrece y esa' || E'\n'
        || '               -- celda no se pinta' || E'\n'
        || '               ''cuota_credito_directo'', round(pl.cuota_credito_directo, 2),' || E'\n'
        || '               ''stock'',',
        'fn_tienda_productos (precios)');

    EXECUTE v_def;
    RAISE NOTICE 'fn_tienda_productos: manda precio_tarjeta, cuota_credito_directo y marca_logo.';
END;
$catalogo$;


-- ============================================================================
-- 2. LA FICHA DE UN PRODUCTO (fn_tienda_producto)
-- ============================================================================
-- Aquí había un `'precio_anterior', NULL` escrito a mano: la ficha no podía
-- tachar nada aunque el producto estuviera en oferta. Se le dan los tres
-- precios, los mismos que la tarjeta.
DO $ficha$
DECLARE
    v_def text;
BEGIN
    SELECT pg_get_functiondef(p.oid) INTO v_def
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'ecommerce' AND p.proname = 'fn_tienda_producto';

    IF v_def IS NULL THEN
        RAISE EXCEPTION 'No existe ecommerce.fn_tienda_producto' USING ERRCODE = 'P0001';
    END IF;

    IF position('''precio_tarjeta''' IN v_def) > 0 THEN
        RAISE NOTICE 'fn_tienda_producto ya mandaba los precios de la tarjeta.';
        RETURN;
    END IF;

    v_def := pg_temp.parchar(v_def,
        'pr.descripcion, pr.precio, pr.categoria_id,',
        'pr.descripcion, pr.precio, pr.categoria_id,' || E'\n'
        || '           pr.precio_anterior, pr.precio_tarjeta, pr.cuota_credito_directo,',
        'fn_tienda_producto (columnas)');

    v_def := pg_temp.parchar(v_def,
        '''precio_anterior'', NULL,',
        '-- EL DE ANTES, DE VERDAD. Hasta el 09/11/2026 aquí iba un NULL' || E'\n'
        || '               -- escrito a mano y la ficha no tachaba nada, aunque el' || E'\n'
        || '               -- producto estuviera en oferta y su tarjeta sí lo tachara' || E'\n'
        || '               ''precio_anterior'', round(u.precio_anterior, 2),' || E'\n'
        || '               ''precio_tarjeta'',  round(u.precio_tarjeta, 2),' || E'\n'
        || '               ''cuota_credito_directo'', round(u.cuota_credito_directo, 2),',
        'fn_tienda_producto (precios)');

    EXECUTE v_def;
    RAISE NOTICE 'fn_tienda_producto: precio_anterior de verdad y los dos precios nuevos.';
END;
$ficha$;


-- ============================================================================
-- COMPROBAR
-- ============================================================================
-- Sólo lee. Si algo no cuadra, revienta y el BEGIN de arriba se deshace.
--
-- SE COMPRUEBA CONTRA UN PRODUCTO AL QUE SE LE PONEN LOS PRECIOS A MANO y se
-- le devuelven los suyos al terminar: hoy las tres columnas están vacías en
-- todo el catálogo, y una aserción contra NULL no falla nunca —la comparación
-- da NULL, el IF no entra y la prueba pasa sin haber probado nada—.
--
-- LO QUE HABÍA SE GUARDA Y SE VUELVE A ESCRIBIR, no se pone a NULL: puede
-- haber alguien poniéndole precios a ese producto desde el CRM mientras esto
-- corre, y dejárselos vacíos sería borrarle el trabajo.
DO $comprobar$
DECLARE
    v_fallos text[] := ARRAY[]::text[];
    v_id     bigint;
    v_antes  numeric;
    v_tarj   numeric;
    v_cuota  numeric;
    v_card   jsonb;
    v_ficha  jsonb;
BEGIN
    -- El primero que la tienda enseñaría, sea cual sea
    SELECT (p -> 'productos' -> 0 ->> 'pro_id')::bigint
      INTO v_id
      FROM (SELECT ecommerce.fn_tienda_productos('{"per_page":1}'::jsonb) AS p) t;

    IF v_id IS NULL THEN
        RAISE EXCEPTION 'El catálogo público no devolvió ningún producto: no hay con qué comprobar';
    END IF;

    SELECT precio_anterior, precio_tarjeta, cuota_credito_directo
      INTO v_antes, v_tarj, v_cuota
      FROM inventarios.productos
     WHERE id = v_id
       FOR UPDATE;

    -- Los precios de prueba, sólo durante esta transacción
    UPDATE inventarios.productos
       SET precio_anterior       = 999.99,
           precio_tarjeta        = 888.88,
           cuota_credito_directo = 77.77
     WHERE id = v_id;

    -- Se vuelve a pedir LA MISMA primera página: el orden de fábrica es por
    -- fecha y por id, y los precios no lo mueven, así que el producto que sale
    -- es el mismo de antes. Buscar por su código podría traer varios y la
    -- tarjeta de al lado no lleva los precios de prueba
    SELECT (ecommerce.fn_tienda_productos('{"per_page":1}'::jsonb) -> 'productos' -> 0)
      INTO v_card;

    IF v_card IS NULL OR (v_card ->> 'pro_id')::bigint <> v_id THEN
        v_fallos := array_append(v_fallos,
            'no se pudo recuperar la tarjeta del producto ' || v_id || ' para comprobarla');
    ELSE
        IF (v_card ->> 'precio_tarjeta')::numeric IS DISTINCT FROM 888.88 THEN
            v_fallos := array_append(v_fallos,
                'la tarjeta del catálogo no manda precio_tarjeta (llegó «'
                || COALESCE(v_card ->> 'precio_tarjeta', '<NULL>') || '»)');
        END IF;
        IF (v_card ->> 'cuota_credito_directo')::numeric IS DISTINCT FROM 77.77 THEN
            v_fallos := array_append(v_fallos,
                'la tarjeta del catálogo no manda cuota_credito_directo (llegó «'
                || COALESCE(v_card ->> 'cuota_credito_directo', '<NULL>') || '»)');
        END IF;
        IF (v_card ->> 'precio_anterior')::numeric IS DISTINCT FROM 999.99 THEN
            v_fallos := array_append(v_fallos,
                'la tarjeta del catálogo no manda precio_anterior (llegó «'
                || COALESCE(v_card ->> 'precio_anterior', '<NULL>') || '»)');
        END IF;
        IF NOT v_card ? 'marca_logo' THEN
            v_fallos := array_append(v_fallos, 'la tarjeta del catálogo no trae la clave marca_logo');
        END IF;
    END IF;

    -- Y la ficha, que es la que mentía con el NULL escrito a mano
    v_ficha := ecommerce.fn_tienda_producto(v_id) -> 'producto';

    IF v_ficha IS NULL THEN
        v_fallos := array_append(v_fallos, 'la ficha del producto ' || v_id || ' no devolvió nada');
    ELSE
        IF (v_ficha ->> 'precio_anterior')::numeric IS DISTINCT FROM 999.99 THEN
            v_fallos := array_append(v_fallos,
                'la ficha sigue sin mandar precio_anterior (llegó «'
                || COALESCE(v_ficha ->> 'precio_anterior', '<NULL>') || '»)');
        END IF;
        IF (v_ficha ->> 'precio_tarjeta')::numeric IS DISTINCT FROM 888.88 THEN
            v_fallos := array_append(v_fallos,
                'la ficha no manda precio_tarjeta (llegó «'
                || COALESCE(v_ficha ->> 'precio_tarjeta', '<NULL>') || '»)');
        END IF;
        IF (v_ficha ->> 'cuota_credito_directo')::numeric IS DISTINCT FROM 77.77 THEN
            v_fallos := array_append(v_fallos,
                'la ficha no manda cuota_credito_directo (llegó «'
                || COALESCE(v_ficha ->> 'cuota_credito_directo', '<NULL>') || '»)');
        END IF;
    END IF;

    -- Y los relacionados, que salen del catálogo: la misma tarjeta
    IF NOT ((ecommerce.fn_tienda_producto(v_id) -> 'relacionados' -> 0) ? 'precio_tarjeta'
            OR jsonb_array_length(ecommerce.fn_tienda_producto(v_id) -> 'relacionados') = 0) THEN
        v_fallos := array_append(v_fallos, 'los relacionados de la ficha no traen precio_tarjeta');
    END IF;

    -- Se devuelve el producto a como estaba, con LO QUE TENÍA
    UPDATE inventarios.productos
       SET precio_anterior       = v_antes,
           precio_tarjeta        = v_tarj,
           cuota_credito_directo = v_cuota
     WHERE id = v_id;

    IF cardinality(v_fallos) > 0 THEN
        RAISE EXCEPTION 'La tarjeta única no quedó bien:%', E'\n - ' || array_to_string(v_fallos, E'\n - ');
    END IF;

    RAISE NOTICE 'Comprobado con el producto %: el catálogo, la ficha y los relacionados mandan los tres precios y el logo.', v_id;
END;
$comprobar$;

COMMIT;
