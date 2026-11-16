-- ============================================================================
-- EL CARRITO DE LA TIENDA
-- ============================================================================
-- La tienda tenía el carrito ENTERO pintado —la página, el minicarrito del
-- encabezado, los botones de «Añadir al carrito» de cada tarjeta— y ni una
-- línea detrás: los componentes decían «PENDIENTE: conectar a la API» y los
-- botones no hacían nada. Esto es lo que les faltaba.
--
-- ----------------------------------------------------------------------------
-- EL CARRITO VIVE EN EL SERVIDOR, no en el navegador
-- ----------------------------------------------------------------------------
-- Y la razón no es el capricho de tener una tabla: es que EL PRECIO LO PONE LA
-- TIENDA. Un carrito guardado en el navegador guarda también sus precios, y
-- entonces el importe que ve el cliente es el que su navegador se apuntó el
-- martes pasado —o el que alguien escriba con la consola abierta—. Aquí el
-- navegador sólo guarda un token; precios, impuestos y totales salen del
-- catálogo en cada lectura.
--
-- De paso: el carrito sobrevive a cerrar el navegador, el CRM puede mirar lo
-- que la gente deja a medias, y el día que haya cuentas de cliente basta con
-- llenar `cliente_id` para que sea suyo.
--
-- ----------------------------------------------------------------------------
-- EL TOKEN LO DA EL SERVIDOR
-- ----------------------------------------------------------------------------
-- El primer «agregar» sin token crea el carrito y devuelve el suyo. Si llega
-- un token que no existe, NO se crea uno con él: se crea otro nuevo con un
-- token del servidor. Dejar que el navegador elija su propio identificador es
-- dejar que dos visitantes compartan carrito escribiendo el mismo número.
--
-- ----------------------------------------------------------------------------
-- LO QUE SE GUARDA DE CADA LÍNEA
-- ----------------------------------------------------------------------------
-- El producto y la cantidad, y nada más… salvo `precio_agregado`, que es el
-- precio que tenía cuando se metió. No se usa para cobrar —el que manda es el
-- de hoy— sino para poder decir «ojo, esto cambió de precio desde que lo
-- pusiste», que es lo que una tienda seria avisa.
--
-- El IVA y el descuento viajan POR LÍNEA en el JSON aunque hoy el carrito no
-- los sume: el día que esto se convierta en una proforma de `ventas`, la
-- proforma los necesita línea por línea y no habrá que recalcularlos.
--
-- ----------------------------------------------------------------------------
-- LAS EXISTENCIAS NO EXISTEN TODAVÍA
-- ----------------------------------------------------------------------------
-- `inventarios.productos` sabe si un producto maneja stock y sus topes, pero
-- no CUÁNTO hay: no hay tabla de existencias. Así que el carrito no promete
-- ninguna: cada línea viaja con `stock` en null, que la tienda entiende como
-- «no se sabe», y la cantidad va de 1 a 99. El día que haya inventario, se
-- llena ese campo y la pantalla ya sabe avisar.
--
-- ----------------------------------------------------------------------------
-- SE EJECUTA A MANO. Para ensayar sin guardar, cambiar el COMMIT del final por
-- ROLLBACK; la comprobación arma un carrito de prueba y lo deshace.
-- ============================================================================

BEGIN;

-- ---------- Las dos tablas ----------
--
-- SIN LOS DISPARADORES DE AUDITORÍA del resto de la casa, a propósito: estas
-- dos las escribe gente ANÓNIMA desde la tienda, sin usuario con el que
-- llenar `created_by`, y un carrito a medio armar no es un dato que haya que
-- poder auditar. Lo que sí se guarda es cuándo se tocó por última vez, que es
-- lo que hace falta para limpiar los viejos.
CREATE TABLE IF NOT EXISTS ecommerce.carritos (
    id          bigserial    PRIMARY KEY,
    -- Lo único que guarda el navegador. Lo pone el servidor
    token       uuid         NOT NULL DEFAULT gen_random_uuid(),
    -- El día que la tienda tenga cuentas de cliente. Hasta entonces, NULL
    cliente_id  bigint       NULL REFERENCES ventas.clientes(id),
    estado      varchar(20)  NOT NULL DEFAULT 'abierto',
    created_at  timestamptz  NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at  timestamptz  NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT uq_carritos_token  UNIQUE (token),
    CONSTRAINT ck_carritos_estado CHECK (estado IN ('abierto', 'convertido', 'abandonado'))
);

COMMENT ON TABLE ecommerce.carritos IS
    'Un carrito de la tienda. El navegador guarda sólo el token; los precios salen del catálogo en cada lectura.';

CREATE TABLE IF NOT EXISTS ecommerce.carritos_items (
    id              bigserial     PRIMARY KEY,
    carrito_id      bigint        NOT NULL REFERENCES ecommerce.carritos(id) ON DELETE CASCADE,
    producto_id     bigint        NOT NULL REFERENCES inventarios.productos(id),
    cantidad        integer       NOT NULL DEFAULT 1,
    -- Lo que costaba al meterlo: sólo para avisar de que cambió
    precio_agregado numeric(14,2) NULL,
    created_at      timestamptz   NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at      timestamptz   NOT NULL DEFAULT CURRENT_TIMESTAMP,
    -- UN PRODUCTO, UNA LÍNEA: volver a agregarlo suma cantidad en vez de
    -- repetir la fila, que es lo que espera cualquiera que pulse dos veces
    CONSTRAINT uq_carritos_items_producto UNIQUE (carrito_id, producto_id),
    CONSTRAINT ck_carritos_items_cantidad CHECK (cantidad BETWEEN 1 AND 99)
);

COMMENT ON COLUMN ecommerce.carritos_items.precio_agregado IS
    'El precio que tenía el producto al meterlo. No se cobra con él: sirve para avisar de que cambió.';

CREATE INDEX IF NOT EXISTS ix_carritos_items_carrito ON ecommerce.carritos_items (carrito_id);
CREATE INDEX IF NOT EXISTS ix_carritos_actividad     ON ecommerce.carritos (updated_at);

-- ---------- Lo que la tienda puede meter en un carrito ----------
--
-- LA MISMA REGLA QUE LA FICHA Y LA REJILLA (fn_tienda_producto): activo, en la
-- web, sin borrar y de una categoría que la tienda enseñe. Está en su propia
-- función para que no haya dos sitios donde decidir qué es un producto
-- público: el día que la regla cambie, cambia aquí.
CREATE OR REPLACE FUNCTION ecommerce.fn_producto_comprable(p_id bigint)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
AS $function$
    SELECT EXISTS (
        SELECT 1
          FROM inventarios.productos pr
          JOIN (SELECT e.id FROM ecommerce.fn_categorias_web_estado() e WHERE e.estado = 'visible') v
               ON v.id = pr.categoria_id
         WHERE pr.id = p_id
           AND pr.deleted_at IS NULL
           AND pr.activo
           AND pr.en_paginaweb);
$function$;

COMMENT ON FUNCTION ecommerce.fn_producto_comprable(bigint) IS
    'Si la tienda puede vender ese producto: activo, en la web y de una categoría visible. La misma regla que la ficha.';

-- ---------- El carrito, tal como lo ve la tienda ----------
--
-- TODO SE CALCULA AQUÍ, en la lectura: precio, descuento, IVA y totales salen
-- del catálogo de ahora mismo. Lo guardado es sólo qué productos y cuántos.
--
-- EL TOTAL ES LA SUMA DE LO QUE SE VE EN LAS TARJETAS (precio × cantidad), ni
-- un centavo más: el IVA viaja aparte, informativo, porque la tienda hoy
-- enseña el precio del catálogo tal cual y el carrito no puede decir otra cosa
-- que la vitrina.
--
-- UNA LÍNEA QUE DEJÓ DE SER PÚBLICA NO SE BORRA SOLA: se queda con su aviso.
-- Que un producto desaparezca del carrito sin decir nada es peor que verlo
-- marcado, y la página ya sabe apagar «Proceder al pago» cuando hay avisos.
CREATE OR REPLACE FUNCTION ecommerce.fn_carrito_publico(p_token uuid)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
AS $function$
    WITH carrito AS (
        SELECT c.id, c.token
          FROM ecommerce.carritos c
         WHERE c.token = p_token AND c.estado = 'abierto'
    ),
    lineas AS (
        SELECT i.id,
               i.producto_id,
               i.cantidad,
               pr.nombre,
               COALESCE(NULLIF(btrim(cw.nombre_web), ''), cat.nombre) AS categoria,
               round(COALESCE(pr.precio, 0), 2)        AS precio,
               round(pr.precio_anterior, 2)            AS precio_anterior,
               COALESCE(pr.iva_porcentaje, 0)          AS iva_porcentaje,
               i.precio_agregado,
               ecommerce.fn_producto_comprable(i.producto_id) AS comprable,
               (SELECT btrim(im.archivo)
                  FROM inventarios.productos_imagenes im
                 WHERE im.producto_id = pr.id
                   AND NULLIF(btrim(COALESCE(im.archivo, '')), '') IS NOT NULL
                 ORDER BY im.principal DESC, im.orden, im.id
                 LIMIT 1)                              AS imagen
          FROM ecommerce.carritos_items i
          JOIN carrito c                        ON c.id = i.carrito_id
          JOIN inventarios.productos pr         ON pr.id = i.producto_id
          LEFT JOIN inventarios.categorias cat  ON cat.id = pr.categoria_id AND cat.deleted_at IS NULL
          LEFT JOIN ecommerce.categorias_web cw ON cw.categoria_id = pr.categoria_id
    ),
    -- El aviso de cada línea, en un solo sitio
    con_aviso AS (
        SELECT l.*,
               round(l.precio * l.cantidad, 2) AS subtotal,
               CASE
                   WHEN NOT l.comprable
                       THEN 'Ya no está disponible en la tienda'
                   WHEN l.precio_agregado IS NOT NULL AND l.precio > l.precio_agregado
                       THEN 'Subió de precio desde que lo agregaste'
                   WHEN l.precio_agregado IS NOT NULL AND l.precio < l.precio_agregado
                       THEN 'Bajó de precio desde que lo agregaste'
               END AS aviso
          FROM lineas l
    )
    SELECT jsonb_build_object(
        'token', (SELECT token FROM carrito),
        'items', COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
                       'id',              a.id,
                       'producto_id',     a.producto_id,
                       'nombre',          a.nombre,
                       'categoria',       a.categoria,
                       'imagen',          a.imagen,
                       'cantidad',        a.cantidad,
                       'precio',          a.precio,
                       'precio_anterior', a.precio_anterior,
                       -- Para la proforma del día de mañana; el carrito no lo suma
                       'iva_porcentaje',  a.iva_porcentaje,
                       'subtotal',        a.subtotal,
                       -- No hay existencias en la base: «no se sabe»
                       'stock',           NULL,
                       'aviso',           a.aviso)
                   ORDER BY a.id)
              FROM con_aviso a), '[]'::jsonb),
        'totales', (SELECT jsonb_build_object(
                        'lineas',   COALESCE(count(*), 0),
                        'unidades', COALESCE(sum(a.cantidad), 0),
                        'subtotal', round(COALESCE(sum(a.subtotal), 0), 2),
                        -- Informativo: lo que llevaría dentro si los precios
                        -- del catálogo fueran sin IVA
                        'iva',      round(COALESCE(sum(a.subtotal * a.iva_porcentaje / 100), 0), 2),
                        'total',    round(COALESCE(sum(a.subtotal), 0), 2),
                        'avisos',   COALESCE(count(*) FILTER (WHERE a.aviso IS NOT NULL), 0))
                      FROM con_aviso a));
$function$;

COMMENT ON FUNCTION ecommerce.fn_carrito_publico(uuid) IS
    'El carrito que ve la tienda: líneas con el precio de HOY, sus avisos y los totales. No crea nada.';

-- ---------- Encontrar (o abrir) el carrito ----------
--
-- Un token desconocido NO se usa: se abre un carrito nuevo con uno del
-- servidor. Así nadie elige el identificador de su carrito.
CREATE OR REPLACE FUNCTION ecommerce.fn_carrito_abrir(p_token uuid)
RETURNS ecommerce.carritos
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'ecommerce'
AS $function$
DECLARE
    v_carrito ecommerce.carritos;
BEGIN
    IF p_token IS NOT NULL THEN
        SELECT * INTO v_carrito FROM ecommerce.carritos
         WHERE token = p_token AND estado = 'abierto';
        IF FOUND THEN
            RETURN v_carrito;
        END IF;
    END IF;

    INSERT INTO ecommerce.carritos DEFAULT VALUES RETURNING * INTO v_carrito;
    RETURN v_carrito;
END;
$function$;

-- ---------- Agregar ----------
--
-- Volver a agregar SUMA a lo que ya había: es lo que espera quien pulsa dos
-- veces el mismo botón, y lo contrario —una segunda línea igual— es como se
-- llenan los carritos de duplicados.
CREATE OR REPLACE FUNCTION ecommerce.fn_carrito_agregar(
    p_token       uuid,
    p_producto_id bigint,
    p_cantidad    integer DEFAULT 1)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'ecommerce'
AS $function$
DECLARE
    v_carrito  ecommerce.carritos;
    v_cantidad integer := GREATEST(1, LEAST(COALESCE(p_cantidad, 1), 99));
    v_nombre   text;
    v_precio   numeric(14,2);
    v_lineas   integer;
BEGIN
    IF NOT ecommerce.fn_producto_comprable(p_producto_id) THEN
        RAISE EXCEPTION 'Ese producto ya no está a la venta en la tienda' USING ERRCODE = 'P0013';
    END IF;

    SELECT nombre, round(COALESCE(precio, 0), 2) INTO v_nombre, v_precio
      FROM inventarios.productos WHERE id = p_producto_id;

    v_carrito := ecommerce.fn_carrito_abrir(p_token);

    -- Un tope de líneas: el carrito es de una persona comprando, no un sitio
    -- donde dejar cien mil filas desde un script
    SELECT count(*) INTO v_lineas FROM ecommerce.carritos_items WHERE carrito_id = v_carrito.id;
    IF v_lineas >= 50 AND NOT EXISTS (SELECT 1 FROM ecommerce.carritos_items
                                       WHERE carrito_id = v_carrito.id AND producto_id = p_producto_id) THEN
        RAISE EXCEPTION 'El carrito ya tiene 50 productos distintos' USING ERRCODE = 'P0015';
    END IF;

    INSERT INTO ecommerce.carritos_items (carrito_id, producto_id, cantidad, precio_agregado)
    VALUES (v_carrito.id, p_producto_id, v_cantidad, v_precio)
    ON CONFLICT (carrito_id, producto_id) DO UPDATE
       SET cantidad   = LEAST(ecommerce.carritos_items.cantidad + v_cantidad, 99),
           updated_at = CURRENT_TIMESTAMP;

    UPDATE ecommerce.carritos SET updated_at = CURRENT_TIMESTAMP WHERE id = v_carrito.id;

    RETURN jsonb_build_object('success', true,
        'message', format('«%s» se agregó al carrito', v_nombre),
        'data', ecommerce.fn_carrito_publico(v_carrito.token));
END;
$function$;

-- ---------- Cambiar la cantidad ----------
-- Con 0 se quita: es lo que hace el botón de restar cuando llega a uno y lo
-- que escribe quien borra el número a mano.
CREATE OR REPLACE FUNCTION ecommerce.fn_carrito_cantidad(
    p_token       uuid,
    p_producto_id bigint,
    p_cantidad    integer)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'ecommerce'
AS $function$
DECLARE
    v_carrito  ecommerce.carritos;
    v_cantidad integer := LEAST(COALESCE(p_cantidad, 1), 99);
BEGIN
    SELECT * INTO v_carrito FROM ecommerce.carritos
     WHERE token = p_token AND estado = 'abierto';
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Ese carrito ya no existe' USING ERRCODE = 'P0013';
    END IF;

    IF v_cantidad < 1 THEN
        DELETE FROM ecommerce.carritos_items
         WHERE carrito_id = v_carrito.id AND producto_id = p_producto_id;
    ELSE
        UPDATE ecommerce.carritos_items
           SET cantidad = v_cantidad, updated_at = CURRENT_TIMESTAMP
         WHERE carrito_id = v_carrito.id AND producto_id = p_producto_id;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'Ese producto no está en el carrito' USING ERRCODE = 'P0013';
        END IF;
    END IF;

    UPDATE ecommerce.carritos SET updated_at = CURRENT_TIMESTAMP WHERE id = v_carrito.id;

    RETURN jsonb_build_object('success', true,
        'message', CASE WHEN v_cantidad < 1 THEN 'Producto quitado' ELSE 'Cantidad actualizada' END,
        'data', ecommerce.fn_carrito_publico(v_carrito.token));
END;
$function$;

-- ---------- Quitar una línea ----------
CREATE OR REPLACE FUNCTION ecommerce.fn_carrito_quitar(p_token uuid, p_producto_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'ecommerce'
AS $function$
BEGIN
    RETURN ecommerce.fn_carrito_cantidad(p_token, p_producto_id, 0);
END;
$function$;

-- ---------- Vaciarlo ----------
CREATE OR REPLACE FUNCTION ecommerce.fn_carrito_vaciar(p_token uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'ecommerce'
AS $function$
DECLARE
    v_carrito ecommerce.carritos;
BEGIN
    SELECT * INTO v_carrito FROM ecommerce.carritos
     WHERE token = p_token AND estado = 'abierto';
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Ese carrito ya no existe' USING ERRCODE = 'P0013';
    END IF;

    DELETE FROM ecommerce.carritos_items WHERE carrito_id = v_carrito.id;
    UPDATE ecommerce.carritos SET updated_at = CURRENT_TIMESTAMP WHERE id = v_carrito.id;

    RETURN jsonb_build_object('success', true, 'message', 'Carrito vaciado',
        'data', ecommerce.fn_carrito_publico(v_carrito.token));
END;
$function$;

-- ---------- La limpieza ----------
--
-- Un carrito VACÍO que nadie toca en un día es basura: lo dejó un visitante
-- que abrió la tienda y se fue. Uno CON productos se guarda mucho más, que es
-- justo lo que se quiere mirar («carritos abandonados»). Se llama a mano o
-- desde una tarea; no hay nada programado todavía.
CREATE OR REPLACE FUNCTION ecommerce.fn_carritos_limpiar(
    p_dias_vacios integer DEFAULT 1,
    p_dias_llenos integer DEFAULT 90)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'ecommerce'
AS $function$
DECLARE
    v_vacios integer;
    v_llenos integer;
BEGIN
    DELETE FROM ecommerce.carritos c
     WHERE c.updated_at < CURRENT_TIMESTAMP - make_interval(days => GREATEST(p_dias_vacios, 1))
       AND NOT EXISTS (SELECT 1 FROM ecommerce.carritos_items i WHERE i.carrito_id = c.id);
    GET DIAGNOSTICS v_vacios = ROW_COUNT;

    DELETE FROM ecommerce.carritos c
     WHERE c.updated_at < CURRENT_TIMESTAMP - make_interval(days => GREATEST(p_dias_llenos, 7));
    GET DIAGNOSTICS v_llenos = ROW_COUNT;

    RETURN jsonb_build_object('success', true,
        'message', format('%s carritos vacíos y %s viejos borrados', v_vacios, v_llenos));
END;
$function$;

COMMIT;


-- ============================================================================
-- COMPROBACIÓN — arma un carrito de prueba y lo deshace
-- ============================================================================
DO $comprobar$
DECLARE
    v_falta    text[] := '{}';
    v_producto bigint;
    v_otro     bigint;
    v_res      jsonb;
    v_token    uuid;
    v_carrito  jsonb;
BEGIN
    SELECT pr.id INTO v_producto
      FROM inventarios.productos pr
     WHERE ecommerce.fn_producto_comprable(pr.id)
     ORDER BY pr.id LIMIT 1;

    SELECT pr.id INTO v_otro
      FROM inventarios.productos pr
     WHERE ecommerce.fn_producto_comprable(pr.id) AND pr.id <> v_producto
     ORDER BY pr.id LIMIT 1;

    IF v_producto IS NULL THEN
        RAISE EXCEPTION 'No hay ni un producto a la venta en la tienda: la prueba no puede correr';
    END IF;

    BEGIN
        -- ---------- Agregar sin token abre carrito ----------
        v_res   := ecommerce.fn_carrito_agregar(NULL, v_producto, 2);
        v_token := ((v_res -> 'data') ->> 'token')::uuid;
        v_carrito := v_res -> 'data';

        IF v_token IS NULL THEN
            v_falta := array_append(v_falta, 'agregar sin token no devolvió un carrito');
        END IF;
        IF (v_carrito -> 'totales' ->> 'unidades')::int <> 2 THEN
            v_falta := array_append(v_falta, 'las unidades no son 2: ' || COALESCE(v_carrito -> 'totales' ->> 'unidades', '(nada)'));
        END IF;
        IF (v_carrito -> 'items' -> 0 ->> 'subtotal')::numeric
           <> round((v_carrito -> 'items' -> 0 ->> 'precio')::numeric * 2, 2) THEN
            v_falta := array_append(v_falta, 'el subtotal de la línea no es precio × cantidad');
        END IF;

        -- ---------- El mismo producto SUMA, no repite ----------
        v_carrito := ecommerce.fn_carrito_agregar(v_token, v_producto, 3) -> 'data';
        IF jsonb_array_length(v_carrito -> 'items') <> 1 THEN
            v_falta := array_append(v_falta, 'agregar dos veces el mismo producto hizo dos líneas');
        END IF;
        IF (v_carrito -> 'items' -> 0 ->> 'cantidad')::int <> 5 THEN
            v_falta := array_append(v_falta, 'la cantidad no se sumó: ' || COALESCE(v_carrito -> 'items' -> 0 ->> 'cantidad', '(nada)'));
        END IF;

        -- ---------- Un token inventado NO se usa: abre otro carrito ----------
        v_res := ecommerce.fn_carrito_agregar('00000000-0000-4000-8000-000000000000'::uuid, v_producto, 1);
        IF ((v_res -> 'data') ->> 'token')::uuid = '00000000-0000-4000-8000-000000000000'::uuid THEN
            v_falta := array_append(v_falta, 'dejó que el navegador eligiera el token de su carrito');
        END IF;

        -- ---------- Cambiar la cantidad y quitar ----------
        v_carrito := ecommerce.fn_carrito_cantidad(v_token, v_producto, 7) -> 'data';
        IF (v_carrito -> 'totales' ->> 'unidades')::int <> 7 THEN
            v_falta := array_append(v_falta, 'no se pudo fijar la cantidad');
        END IF;

        IF v_otro IS NOT NULL THEN
            v_carrito := ecommerce.fn_carrito_agregar(v_token, v_otro, 1) -> 'data';
            IF jsonb_array_length(v_carrito -> 'items') <> 2 THEN
                v_falta := array_append(v_falta, 'no se pudo meter un segundo producto');
            END IF;
            v_carrito := ecommerce.fn_carrito_quitar(v_token, v_otro) -> 'data';
            IF jsonb_array_length(v_carrito -> 'items') <> 1 THEN
                v_falta := array_append(v_falta, 'quitar no quitó la línea');
            END IF;
        END IF;

        -- ---------- Un producto que no está a la venta no entra ----------
        BEGIN
            PERFORM ecommerce.fn_carrito_agregar(v_token, -1, 1);
            v_falta := array_append(v_falta, 'dejó agregar un producto que no existe');
        EXCEPTION WHEN others THEN
            NULL;   -- tenía que reventar
        END;

        -- ---------- Vaciar ----------
        v_carrito := ecommerce.fn_carrito_vaciar(v_token) -> 'data';
        IF jsonb_array_length(v_carrito -> 'items') <> 0
           OR (v_carrito -> 'totales' ->> 'total')::numeric <> 0 THEN
            v_falta := array_append(v_falta, 'vaciar no dejó el carrito en cero');
        END IF;

        -- ---------- Un token que no existe no revienta al leer ----------
        IF ecommerce.fn_carrito_publico(gen_random_uuid()) -> 'items' <> '[]'::jsonb THEN
            v_falta := array_append(v_falta, 'un token desconocido devolvió algo');
        END IF;

        -- Y se deshace: la prueba no deja carritos
        RAISE EXCEPTION 'deshacer la prueba';
    EXCEPTION WHEN others THEN
        IF SQLERRM <> 'deshacer la prueba' THEN
            RAISE;
        END IF;
    END;

    IF EXISTS (SELECT 1 FROM ecommerce.carritos) THEN
        v_falta := array_append(v_falta, 'la prueba dejó carritos en la base');
    END IF;

    IF array_length(v_falta, 1) > 0 THEN
        RAISE EXCEPTION 'El carrito no quedó bien: %', array_to_string(v_falta, '; ');
    END IF;

    RAISE NOTICE 'El carrito de la tienda funciona: agregar, sumar, cambiar, quitar y vaciar.';
END;
$comprobar$;
