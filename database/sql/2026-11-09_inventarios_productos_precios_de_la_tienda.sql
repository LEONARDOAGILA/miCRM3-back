-- ============================================================================
-- LOS PRECIOS QUE ENSEÑA LA TIENDA, EN LA FICHA DEL PRODUCTO
-- ============================================================================
-- La tarjeta de los escaparates enseña CUATRO cosas de precio:
--
--   · «Tarjeta Crédito» con su importe y, tachado, el de antes;
--   · el cartel del descuento en la esquina de la foto;
--   · y «Crédito Directo — Cuotas desde» con la cuota.
--
-- Todas salían de una cuenta sobre el id del producto. El 08/11/2026 se creó
-- `precio_anterior` y el precio pasó a ser el de verdad, pero la celda del
-- crédito directo se quitó por no tener de dónde sacarla. Con esto vuelve, y
-- la tarjeta queda entera y con datos reales:
--
--   `precio_tarjeta`          lo que cuesta pagando con tarjeta de crédito.
--                             VACÍO = el mismo que `precio`, que es lo normal:
--                             sólo se llena cuando el de tarjeta es distinto.
--   `cuota_credito_directo`   la cuota de «Cuotas desde». VACÍO = este producto
--                             no se ofrece a crédito directo, y entonces esa
--                             celda no se pinta.
--
-- POR QUÉ LA CUOTA SE GUARDA Y NO SE CALCULA. Dividir el precio entre doce
-- sería volver a inventar: el plazo y el interés los pone el negocio, no el
-- programa, y no están en ninguna parte. Guardada, el número que se enseña es
-- el que alguien decidió. El día que haya una tabla de financiación, esta
-- columna se llena desde ahí y la tienda no se entera.
--
-- EL DESCUENTO SIGUE SIN GUARDARSE: se calcula de `precio_anterior` y del
-- precio que se está enseñando. Un porcentaje aparte podría decir «-30 %»
-- sobre dos importes que no se llevan un 30 %.
--
-- Las tres nacen vacías: nadie tenía estos datos y rellenarlos sería inventar
-- otra vez. Se escriben desde la ficha del producto (Inventarios → Productos
-- → pestaña «Precio»).
--
-- Es idempotente: las columnas sólo se añaden si faltan y el resto son
-- funciones.
-- ============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. LAS COLUMNAS
-- ---------------------------------------------------------------------------
ALTER TABLE inventarios.productos
    ADD COLUMN IF NOT EXISTS precio_tarjeta numeric(14, 2);

ALTER TABLE inventarios.productos
    ADD COLUMN IF NOT EXISTS cuota_credito_directo numeric(14, 2);

DO $columnas$
DECLARE
    v_puestas integer := 0;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'productos_precio_tarjeta_check'
                      AND conrelid = 'inventarios.productos'::regclass) THEN
        -- Un precio no puede ser negativo, y el 0 tampoco vale como «no tiene»:
        -- para eso está el vacío. Un «$0,00» en la tarjeta se leería como gratis
        ALTER TABLE inventarios.productos
            ADD CONSTRAINT productos_precio_tarjeta_check
            CHECK (precio_tarjeta IS NULL OR precio_tarjeta > 0);
        v_puestas := v_puestas + 1;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'productos_cuota_credito_directo_check'
                      AND conrelid = 'inventarios.productos'::regclass) THEN
        ALTER TABLE inventarios.productos
            ADD CONSTRAINT productos_cuota_credito_directo_check
            CHECK (cuota_credito_directo IS NULL OR cuota_credito_directo > 0);
        v_puestas := v_puestas + 1;
    END IF;

    RAISE NOTICE 'Columnas de precio de la tienda: % puesta(s), el resto ya estaban.', v_puestas;
END;
$columnas$;

COMMENT ON COLUMN inventarios.productos.precio_tarjeta IS
    'Lo que cuesta pagando con tarjeta de crédito, que es lo que rotula la tienda como «Tarjeta Crédito». NULL = el mismo que «precio».';
COMMENT ON COLUMN inventarios.productos.cuota_credito_directo IS
    'La cuota que la tienda enseña en «Crédito Directo — Cuotas desde». NULL = este producto no se ofrece a crédito directo y esa celda no se pinta. No se calcula del precio: el plazo y el interés los pone el negocio.';

-- ---------------------------------------------------------------------------
-- 2. LA FICHA DEL PRODUCTO LAS DEVUELVE
-- ---------------------------------------------------------------------------
DO $json$
DECLARE
    v_def text;
BEGIN
    SELECT pg_get_functiondef(p.oid) INTO v_def
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'inventarios' AND p.proname = 'fn_productos_json';

    IF v_def IS NULL THEN
        RAISE EXCEPTION 'No existe inventarios.fn_productos_json' USING ERRCODE = 'P0015';
    END IF;

    IF v_def LIKE '%precio_tarjeta%' THEN
        RAISE NOTICE 'fn_productos_json ya devolvía los precios de la tienda.';
        RETURN;
    END IF;

    v_def := replace(v_def,
'        ''precio'',          p.precio,',
'        ''precio'',          p.precio,
        -- Los tres de la tienda. Vacíos mientras nadie los llene: la tarjeta
        -- se apaña con el precio normal y no enseña ni tachado ni cuota
        ''precio_anterior'',       p.precio_anterior,
        ''precio_tarjeta'',        p.precio_tarjeta,
        ''cuota_credito_directo'', p.cuota_credito_directo,');

    IF v_def NOT LIKE '%precio_tarjeta%' THEN
        RAISE EXCEPTION 'fn_productos_json no es como se esperaba: revísala a mano' USING ERRCODE = 'P0015';
    END IF;

    EXECUTE v_def;
    RAISE NOTICE 'fn_productos_json: la ficha ya trae los precios de la tienda.';
END;
$json$;

-- ---------------------------------------------------------------------------
-- 3. GUARDARLOS: CREAR Y MODIFICAR
-- ---------------------------------------------------------------------------
-- Los tres parámetros van AL FINAL y con valor por defecto, para que lo que ya
-- llamaba a estas funciones sin ellos siga funcionando. Cambiar la firma
-- obliga a borrar la anterior: con CREATE OR REPLACE quedarían las dos y la
-- llamada sería ambigua.
DO $guardar$
DECLARE
    v_def   text;
    v_firma text;
    v_fn    text;
BEGIN
    FOREACH v_fn IN ARRAY ARRAY['fn_productos_crear', 'fn_productos_modificar'] LOOP
        SELECT pg_get_functiondef(p.oid), p.oid::regprocedure::text
          INTO v_def, v_firma
          FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
         WHERE n.nspname = 'inventarios' AND p.proname = v_fn;

        IF v_def IS NULL THEN
            RAISE EXCEPTION 'No existe inventarios.%', v_fn USING ERRCODE = 'P0015';
        END IF;

        IF v_def LIKE '%p_precio_tarjeta%' THEN
            RAISE NOTICE '%: ya guardaba los precios de la tienda.', v_fn;
            CONTINUE;
        END IF;

        -- a) Los parámetros nuevos, detrás del último
        v_def := replace(v_def,
            'p_request_id uuid DEFAULT NULL::uuid)',
            'p_request_id uuid DEFAULT NULL::uuid, '
            || 'p_precio_anterior numeric DEFAULT NULL::numeric, '
            || 'p_precio_tarjeta numeric DEFAULT NULL::numeric, '
            || 'p_cuota_credito_directo numeric DEFAULT NULL::numeric)');

        -- b) Y que lleguen a la fila
        IF v_fn = 'fn_productos_crear' THEN
            v_def := replace(v_def,
'        unidad, costo, precio, impuesto,',
'        unidad, costo, precio, impuesto,
        precio_anterior, precio_tarjeta, cuota_credito_directo,');
            v_def := replace(v_def,
'        COALESCE(p_costo, 0), COALESCE(p_precio, 0), COALESCE(p_impuesto, true),',
'        COALESCE(p_costo, 0), COALESCE(p_precio, 0), COALESCE(p_impuesto, true),
        -- Los tres de la tienda: vacío significa «no tiene», no cero
        nullif(p_precio_anterior, 0), nullif(p_precio_tarjeta, 0), nullif(p_cuota_credito_directo, 0),');
        ELSE
            v_def := replace(v_def,
'           precio         = COALESCE(p_precio, 0),',
'           precio         = COALESCE(p_precio, 0),
           -- Los tres de la tienda: vacío significa «no tiene», no cero
           precio_anterior       = nullif(p_precio_anterior, 0),
           precio_tarjeta        = nullif(p_precio_tarjeta, 0),
           cuota_credito_directo = nullif(p_cuota_credito_directo, 0),');
        END IF;

        IF v_def NOT LIKE '%p_precio_tarjeta%' OR v_def NOT LIKE '%precio_tarjeta %' THEN
            RAISE EXCEPTION '% no es como se esperaba: revísala a mano', v_fn USING ERRCODE = 'P0015';
        END IF;

        EXECUTE 'DROP FUNCTION ' || v_firma;
        EXECUTE v_def;
        RAISE NOTICE '%: ya guarda los precios de la tienda.', v_fn;
    END LOOP;
END;
$guardar$;

-- ---------------------------------------------------------------------------
-- 4. LOS ESCAPARATES LOS MANDAN A LA TIENDA
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

    IF v_def LIKE '%precio_tarjeta%' THEN
        RAISE NOTICE 'fn_producto_seccion_publica ya mandaba los precios de la tienda.';
        RETURN;
    END IF;

    v_def := replace(v_def,
'                   ''precio_anterior'', round(p.precio_anterior, 2),',
'                   ''precio_anterior'', round(p.precio_anterior, 2),
                   -- Lo que cuesta con tarjeta de crédito; vacío = el mismo
                   -- que el precio, y la tarjeta ya lo resuelve
                   ''precio_tarjeta'', round(p.precio_tarjeta, 2),
                   -- La cuota del crédito directo; vacío = no se ofrece y esa
                   -- celda no se pinta
                   ''cuota_credito_directo'', round(p.cuota_credito_directo, 2),');

    IF v_def NOT LIKE '%precio_tarjeta%' THEN
        RAISE EXCEPTION 'fn_producto_seccion_publica no es como se esperaba: revísala a mano'
            USING ERRCODE = 'P0015';
    END IF;

    EXECUTE v_def;
    RAISE NOTICE 'fn_producto_seccion_publica: los escaparates mandan los tres precios.';
END;
$seccion$;

-- ---------------------------------------------------------------------------
-- COMPROBACIÓN
-- ---------------------------------------------------------------------------
DO $comprobar$
DECLARE
    v_id      bigint;
    v_seccion bigint;
    v_precio  numeric;
    v_tarjeta jsonb;
    v_ficha   jsonb;
    v_coló    boolean;
BEGIN
    SELECT p.id, i.seccion_id, p.precio INTO v_id, v_seccion, v_precio
      FROM ecommerce.producto_secciones_items i
      JOIN inventarios.productos p ON p.id = i.producto_id AND p.deleted_at IS NULL
     WHERE p.precio > 0
     ORDER BY p.id
     LIMIT 1;

    IF v_id IS NULL THEN
        RAISE NOTICE 'Comprobado: las columnas y las funciones cambiaron. (Ningún escaparate tiene productos con precio, así que la prueba con datos se salta.)';
        RETURN;
    END IF;

    -- Vacías: la tienda no recibe ni tachado, ni precio de tarjeta, ni cuota
    SELECT x INTO v_tarjeta
      FROM jsonb_array_elements(ecommerce.fn_producto_seccion_publica(v_seccion)) x
     WHERE (x ->> 'id')::bigint = v_id;

    IF v_tarjeta ->> 'precio_tarjeta' IS NOT NULL
       OR v_tarjeta ->> 'cuota_credito_directo' IS NOT NULL THEN
        RAISE EXCEPTION 'Sin llenarlas, las columnas nuevas tenían que venir vacías' USING ERRCODE = 'P0015';
    END IF;

    -- Llenas: viajan por el camino entero (guardar → ficha → escaparate).
    -- Se deshace en el sitio: nadie se queda con precios puestos.
    BEGIN
        UPDATE inventarios.productos
           SET precio_anterior       = round(v_precio * 1.3, 2),
               precio_tarjeta        = round(v_precio * 1.05, 2),
               cuota_credito_directo = round(v_precio / 12, 2)
         WHERE id = v_id;

        SELECT x INTO v_tarjeta
          FROM jsonb_array_elements(ecommerce.fn_producto_seccion_publica(v_seccion)) x
         WHERE (x ->> 'id')::bigint = v_id;

        IF (v_tarjeta ->> 'precio_tarjeta')::numeric <> round(v_precio * 1.05, 2) THEN
            RAISE EXCEPTION 'El precio de tarjeta no llega al escaparate: %', v_tarjeta ->> 'precio_tarjeta'
                USING ERRCODE = 'P0015';
        END IF;
        IF (v_tarjeta ->> 'cuota_credito_directo')::numeric <> round(v_precio / 12, 2) THEN
            RAISE EXCEPTION 'La cuota no llega al escaparate: %', v_tarjeta ->> 'cuota_credito_directo'
                USING ERRCODE = 'P0015';
        END IF;

        -- Y la ficha del CRM los lee, que es desde donde se escriben
        v_ficha := inventarios.fn_productos_json(v_id);
        IF v_ficha ->> 'cuota_credito_directo' IS NULL THEN
            RAISE EXCEPTION 'La ficha del CRM no devuelve la cuota' USING ERRCODE = 'P0015';
        END IF;

        RAISE EXCEPTION 'deshacer la prueba' USING ERRCODE = 'P0100';
    EXCEPTION WHEN sqlstate 'P0100' THEN
        NULL;   -- los UPDATE quedan deshechos
    END;

    -- Y una cuota de 0 no se puede guardar: en la tarjeta se leería «gratis»
    BEGIN
        UPDATE inventarios.productos SET cuota_credito_directo = 0 WHERE id = v_id;
        v_coló := true;
    EXCEPTION WHEN check_violation THEN
        v_coló := false;
    END;
    IF v_coló THEN
        RAISE EXCEPTION 'Una cuota de 0 no debería poder guardarse' USING ERRCODE = 'P0015';
    END IF;

    RAISE NOTICE 'Comprobado con el producto %: vacías no viajan, llenas llegan al escaparate y a la ficha del CRM, y el 0 no se guarda.', v_id;
END;
$comprobar$;

COMMIT;
