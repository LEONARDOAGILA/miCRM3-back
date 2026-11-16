-- ============================================================================
-- LOS ESCAPARATES, CON EL PRECIO DE VERDAD
-- ============================================================================
-- Las secciones de productos del CRM («Productos de la Semana», «Productos
-- para Navidad»…) enseñaban en la tienda PRECIOS INVENTADOS: la tarjeta se
-- los calculaba sola a partir del id del producto —`((id * 137) % 1500) + 9.9`—
-- porque cuando se hizo el diseño el catálogo todavía no daba precio.
--
-- Ya lo da: inventarios.productos.precio. Así que la sección pasa a pedirlo, y
-- del lado de la tienda se borra la cuenta inventada entera.
--
-- `precio_anterior`: EL TACHADO, AHORA DE VERDAD. La tarjeta enseña un precio
-- tachado y un «-30 %» en la esquina, y los dos salían también del invento. No
-- había ninguna columna donde guardar ese precio de antes, así que se crea:
--
--   · vacía quiere decir «este producto no está en oferta», y entonces ni se
--     tacha nada ni sale el cartel del descuento;
--   · el descuento NO se guarda: se calcula de los dos precios. Un número
--     aparte podría decir «-30 %» sobre dos importes que no se llevan un 30 %,
--     que es justo lo que no puede pasar en una tienda.
--
-- Nace en NULL para todos: nadie tenía una oferta guardada, y ponerle un
-- precio de antes a los 1.001 productos sería inventar otra vez.
--
-- SE ARREGLA TAMBIÉN /shop, que es la otra pantalla que ya tenía el hueco
-- preparado: su tarjeta pinta el tachado desde `precio_anterior`, pero la
-- función se lo mandaba siempre en NULL. Es la misma columna; dejarlo a medias
-- sería tener la oferta guardada y que se viera en un escaparate y no en el
-- catálogo.
--
-- Es idempotente: la columna sólo se añade si falta y el resto son funciones.
-- ============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. EL PRECIO DE ANTES
-- ---------------------------------------------------------------------------
ALTER TABLE inventarios.productos
    ADD COLUMN IF NOT EXISTS precio_anterior numeric(14, 2);

DO $columna$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'productos_precio_anterior_check'
                      AND conrelid = 'inventarios.productos'::regclass) THEN
        -- Un precio no puede ser negativo. El 0 tampoco vale como «sin oferta»:
        -- para eso está NULL, y un 0 tachado al lado del precio sería un -100 %
        ALTER TABLE inventarios.productos
            ADD CONSTRAINT productos_precio_anterior_check
            CHECK (precio_anterior IS NULL OR precio_anterior > 0);
        RAISE NOTICE 'Columna «precio_anterior» puesta, vacía para todos.';
    ELSE
        RAISE NOTICE 'La columna «precio_anterior» ya estaba.';
    END IF;
END;
$columna$;

COMMENT ON COLUMN inventarios.productos.precio_anterior IS
    'El precio de antes, el que va TACHADO en la tienda. NULL = este producto no está en oferta. El porcentaje del descuento no se guarda: se saca de éste y de «precio».';

-- ---------------------------------------------------------------------------
-- 2. LOS ESCAPARATES
-- ---------------------------------------------------------------------------
DO $seccion$
DECLARE
    v_def text;
BEGIN
    SELECT pg_get_functiondef(p.oid) INTO v_def
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'ecommerce' AND p.proname = 'fn_producto_seccion_publica';

    IF v_def IS NULL THEN
        RAISE EXCEPTION 'No existe ecommerce.fn_producto_seccion_publica' USING ERRCODE = 'P0015';
    END IF;

    IF v_def LIKE '%''precio''%' THEN
        RAISE NOTICE 'fn_producto_seccion_publica ya mandaba el precio.';
        RETURN;
    END IF;

    v_def := replace(v_def,
'                   ''nombre'', p.nombre,',
'                   ''nombre'', p.nombre,
                   -- EL PRECIO DE VERDAD, el del catálogo. Hasta el 08/11/2026
                   -- la tarjeta se lo inventaba a partir del id porque esto no
                   -- se mandaba.
                   ''precio'', round(COALESCE(p.precio, 0), 2),
                   -- Y el de antes, para tacharlo. NULL = no está en oferta, y
                   -- entonces la tarjeta no tacha nada ni saca el descuento.
                   ''precio_anterior'', round(p.precio_anterior, 2),');

    IF v_def NOT LIKE '%''precio''%' THEN
        RAISE EXCEPTION 'La lista de fn_producto_seccion_publica no es la esperada: revísala a mano'
            USING ERRCODE = 'P0015';
    END IF;

    EXECUTE v_def;
    RAISE NOTICE 'fn_producto_seccion_publica: los escaparates ya mandan el precio.';
END;
$seccion$;

-- ---------------------------------------------------------------------------
-- 3. EL CATÁLOGO (/shop), QUE TENÍA EL HUECO ESPERANDO
-- ---------------------------------------------------------------------------
DO $catalogo$
DECLARE
    v_def text;
BEGIN
    SELECT pg_get_functiondef(p.oid) INTO v_def
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'ecommerce' AND p.proname = 'fn_tienda_productos';

    IF v_def IS NULL THEN
        RAISE EXCEPTION 'No existe ecommerce.fn_tienda_productos' USING ERRCODE = 'P0015';
    END IF;

    IF v_def NOT LIKE '%''precio_anterior'', NULL%' THEN
        RAISE NOTICE 'fn_tienda_productos ya no manda el precio anterior en NULL.';
        RETURN;
    END IF;

    -- La columna, al CTE de donde sale todo: `base` elige campo a campo, y los
    -- de abajo heredan con SELECT *. Sin esto, `pl.precio_anterior` no existe.
    v_def := replace(v_def,
        'SELECT pr.id, pr.codigo, pr.nombre, pr.precio, pr.categoria_id,',
        'SELECT pr.id, pr.codigo, pr.nombre, pr.precio, pr.precio_anterior, pr.categoria_id,');

    IF v_def NOT LIKE '%pr.precio_anterior%' THEN
        RAISE EXCEPTION 'No se pudo añadir la columna al CTE «base» de fn_tienda_productos'
            USING ERRCODE = 'P0015';
    END IF;

    v_def := replace(v_def,
'               ''precio_anterior'', NULL,',
'               -- El de antes, para tacharlo; NULL = no está en oferta
               ''precio_anterior'', round(pl.precio_anterior, 2),');

    IF v_def LIKE '%''precio_anterior'', NULL%' THEN
        RAISE EXCEPTION 'No se pudo cambiar el precio anterior de fn_tienda_productos'
            USING ERRCODE = 'P0015';
    END IF;

    EXECUTE v_def;
    RAISE NOTICE 'fn_tienda_productos: el precio anterior sale de la columna.';
END;
$catalogo$;

-- ---------------------------------------------------------------------------
-- COMPROBACIÓN
-- ---------------------------------------------------------------------------
DO $comprobar$
DECLARE
    v_id      bigint;
    v_seccion bigint;
    v_precio  numeric;
    v_json    jsonb;
    v_tarjeta jsonb;
    v_coló    boolean;
BEGIN
    -- Un producto que esté de verdad en un escaparate
    SELECT p.id, i.seccion_id, p.precio INTO v_id, v_seccion, v_precio
      FROM ecommerce.producto_secciones_items i
      JOIN inventarios.productos p ON p.id = i.producto_id AND p.deleted_at IS NULL
     WHERE p.precio > 0
     ORDER BY p.id
     LIMIT 1;

    IF v_id IS NULL THEN
        RAISE NOTICE 'Comprobado: las funciones cambiaron. (Ningún escaparate tiene productos con precio, así que la prueba con datos se salta.)';
        RETURN;
    END IF;

    v_json := ecommerce.fn_producto_seccion_publica(v_seccion);
    SELECT x INTO v_tarjeta FROM jsonb_array_elements(v_json) x WHERE (x ->> 'id')::bigint = v_id;

    IF v_tarjeta IS NULL THEN
        RAISE EXCEPTION 'El producto % no salió en su escaparate', v_id USING ERRCODE = 'P0015';
    END IF;
    IF (v_tarjeta ->> 'precio')::numeric <> round(v_precio, 2) THEN
        RAISE EXCEPTION 'El escaparate manda % y el producto vale %',
            v_tarjeta ->> 'precio', v_precio USING ERRCODE = 'P0015';
    END IF;
    IF v_tarjeta ->> 'precio_anterior' IS NOT NULL THEN
        RAISE EXCEPTION 'Sin oferta guardada, el precio anterior tenía que venir vacío, y vino %',
            v_tarjeta ->> 'precio_anterior' USING ERRCODE = 'P0015';
    END IF;

    -- Y con una oferta puesta, que viaje. Se deshace en el sitio.
    BEGIN
        UPDATE inventarios.productos SET precio_anterior = round(v_precio * 1.25, 2) WHERE id = v_id;

        v_json := ecommerce.fn_producto_seccion_publica(v_seccion);
        SELECT x INTO v_tarjeta FROM jsonb_array_elements(v_json) x WHERE (x ->> 'id')::bigint = v_id;
        IF (v_tarjeta ->> 'precio_anterior')::numeric <> round(v_precio * 1.25, 2) THEN
            RAISE EXCEPTION 'La oferta no llega al escaparate: %', v_tarjeta ->> 'precio_anterior'
                USING ERRCODE = 'P0015';
        END IF;

        -- Y al catálogo
        v_json := ecommerce.fn_tienda_productos(jsonb_build_object('per_page', '48'));
        SELECT x INTO v_tarjeta
          FROM jsonb_array_elements(v_json -> 'productos') x
         WHERE (x ->> 'pro_id')::bigint = v_id;
        IF v_tarjeta IS NOT NULL AND v_tarjeta ->> 'precio_anterior' IS NULL THEN
            RAISE EXCEPTION 'La oferta no llega a /shop' USING ERRCODE = 'P0015';
        END IF;

        RAISE EXCEPTION 'deshacer la prueba' USING ERRCODE = 'P0100';
    EXCEPTION WHEN sqlstate 'P0100' THEN
        NULL;   -- el UPDATE queda deshecho: nadie se queda con una oferta puesta
    END;

    -- Un precio anterior en 0 no puede guardarse: sería un -100 %
    BEGIN
        UPDATE inventarios.productos SET precio_anterior = 0 WHERE id = v_id;
        v_coló := true;
    EXCEPTION WHEN check_violation THEN
        v_coló := false;
    END;
    IF v_coló THEN
        RAISE EXCEPTION 'Un precio anterior de 0 no debería poder guardarse' USING ERRCODE = 'P0015';
    END IF;

    RAISE NOTICE 'Comprobado con el producto %: el escaparate manda su precio real (%), el tachado vacío mientras no haya oferta, y con oferta llega a los dos sitios.',
                 v_id, round(v_precio, 2);
END;
$comprobar$;

COMMIT;
