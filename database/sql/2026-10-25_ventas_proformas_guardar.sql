-- ===========================================================================
-- PROFORMAS · LO QUE HACE FALTA PARA ARMARLAS Y GUARDARLAS
-- ===========================================================================
--   · fn_proformas_cliente_condiciones: al escoger el cliente, de una sola
--     vuelta sale su foto y con qué condiciones se le vende;
--   · fn_proformas_producto_buscar: lo que usa la rejilla cuando se teclea un
--     código, sin abrir el listado completo;
--   · fn_proformas_guardar: el documento entero, cabecera y líneas.
\set ON_ERROR_STOP on

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. EL CLIENTE Y SUS CONDICIONES, DE UNA SOLA VUELTA
-- ---------------------------------------------------------------------------
-- Al escoger el cliente en la proforma hay que rellenar seis campos de la
-- cabecera y proponer forma de pago, días de crédito y descuento. Eso son dos
-- consultas y una herencia por el árbol de grupos, y hacerlo desde el
-- navegador serían tres vueltas al servidor; aquí es una.
--
-- LA REGLA DE QUIÉN MANDA: el valor del cliente, si lo tiene puesto; si no,
-- el de su grupo (que a su vez lo hereda de los de arriba). En el cliente las
-- cuatro columnas son NOT NULL con cero por omisión, así que un cero no
-- significa «cero por ciento de descuento» sino «no se le puso nada», y es
-- entonces cuando toca mirar el grupo. Con la forma de pago, igual: la cadena
-- vacía es «no se le puso».
CREATE OR REPLACE FUNCTION ventas.fn_proformas_cliente_condiciones(p_cliente_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'pg_catalog', 'ventas'
AS $fn$
DECLARE
    v_id          bigint;
    v_ident       varchar(20);
    v_tipo_ident  varchar(10);
    v_nombre      varchar(255);
    v_direccion   text;
    v_telefono    varchar(30);
    v_email       varchar(100);
    v_estado      varchar(20);
    v_activo      boolean;
    v_borrado     boolean;
    v_vendedor    bigint;
    v_grupo       bigint;
    v_grupo_nom   varchar(100);
    -- Lo que tiene puesto el propio cliente
    v_fp          varchar(20);
    v_lim         numeric;
    v_dias        integer;
    v_desc        numeric;
    -- Lo que dice su grupo
    v_g           jsonb;
    v_avisos      jsonb := '[]'::jsonb;
BEGIN
    SELECT c.id,
           c.numero_identificacion,
           c.tipo_identificacion,
           COALESCE(NULLIF(TRIM(c.razon_social), ''), NULLIF(TRIM(c.nombre_completo), ''), c.nombre_comercial),
           c.direccion,
           COALESCE(NULLIF(TRIM(c.celular), ''), NULLIF(TRIM(c.telefono), '')),
           c.email,
           c.estado,
           c.activo,
           (c.deleted_at IS NOT NULL),
           c.vendedor_usuario_id,
           c.grupo_cliente_id,
           NULLIF(UPPER(TRIM(COALESCE(c.forma_pago, ''))), ''),
           c.limite_credito,
           c.dias_credito,
           c.descuento
      INTO v_id, v_ident, v_tipo_ident, v_nombre, v_direccion, v_telefono, v_email,
           v_estado, v_activo, v_borrado, v_vendedor, v_grupo,
           v_fp, v_lim, v_dias, v_desc
      FROM ventas.clientes c
     WHERE c.id = p_cliente_id;

    IF v_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'message', 'El cliente no existe', 'error_code', 'P0016');
    END IF;

    SELECT g.nombre INTO v_grupo_nom FROM ventas.grupos_clientes g WHERE g.id = v_grupo;

    -- Las condiciones del grupo, heredadas hacia arriba por su propia función
    IF v_grupo IS NOT NULL THEN
        v_g := ventas.fn_grupos_clientes_condiciones(v_grupo);
    END IF;

    -- Los avisos: cosas que el vendedor tiene que ver ANTES de cotizar, no
    -- después. No impiden hacer la proforma —a veces se cotiza a un cliente
    -- que está por reactivarse— pero se dicen.
    IF v_borrado THEN
        v_avisos := v_avisos || jsonb_build_array('Este cliente está en la papelera');
    END IF;
    IF NOT COALESCE(v_activo, true) THEN
        v_avisos := v_avisos || jsonb_build_array('Este cliente está inactivo');
    END IF;
    IF v_estado IS NOT NULL AND v_estado <> 'ACTIVO' THEN
        v_avisos := v_avisos || jsonb_build_array('El cliente está en estado ' || v_estado);
    END IF;

    RETURN jsonb_build_object(
        'success', true,
        'data', jsonb_build_object(
            'cliente', jsonb_build_object(
                'id',                  v_id,
                'identificacion',      v_ident,
                'tipo_identificacion', v_tipo_ident,
                'nombre',              v_nombre,
                'direccion',           v_direccion,
                'telefono',            v_telefono,
                'email',               v_email,
                'estado',              v_estado,
                'activo',              v_activo,
                'vendedor_usuario_id', v_vendedor,
                'vendedor_nombre',     ventas.fn_nombre_usuario(v_vendedor),
                'grupo_cliente_id',    v_grupo,
                'grupo_nombre',        v_grupo_nom
            ),
            -- `valor` es lo que se propone en la proforma y `origen` de dónde
            -- salió, para que la pantalla pueda decir «8 % (de Mayoristas)» y
            -- el vendedor sepa que no se lo inventó nadie.
            'condiciones', jsonb_build_object(
                'forma_pago', jsonb_build_object(
                    'valor',  COALESCE(v_fp, v_g->'forma_pago'->>'efectivo'),
                    'origen', CASE WHEN v_fp IS NOT NULL THEN 'cliente'
                                   WHEN v_g->'forma_pago'->>'efectivo' IS NOT NULL THEN 'grupo' END,
                    'origen_etiqueta', CASE WHEN v_fp IS NULL THEN v_g->'forma_pago'->>'origen_etiqueta' END),
                'dias_credito', jsonb_build_object(
                    'valor',  CASE WHEN COALESCE(v_dias, 0) > 0 THEN v_dias
                                   ELSE (v_g->'dias_credito'->>'efectivo')::integer END,
                    'origen', CASE WHEN COALESCE(v_dias, 0) > 0 THEN 'cliente'
                                   WHEN (v_g->'dias_credito'->>'efectivo') IS NOT NULL THEN 'grupo' END,
                    'origen_etiqueta', CASE WHEN COALESCE(v_dias, 0) = 0 THEN v_g->'dias_credito'->>'origen_etiqueta' END),
                'limite_credito', jsonb_build_object(
                    'valor',  CASE WHEN COALESCE(v_lim, 0) > 0 THEN v_lim
                                   ELSE (v_g->'limite_credito'->>'efectivo')::numeric END,
                    'origen', CASE WHEN COALESCE(v_lim, 0) > 0 THEN 'cliente'
                                   WHEN (v_g->'limite_credito'->>'efectivo') IS NOT NULL THEN 'grupo' END,
                    'origen_etiqueta', CASE WHEN COALESCE(v_lim, 0) = 0 THEN v_g->'limite_credito'->>'origen_etiqueta' END),
                'descuento', jsonb_build_object(
                    'valor',  CASE WHEN COALESCE(v_desc, 0) > 0 THEN v_desc
                                   ELSE (v_g->'descuento'->>'efectivo')::numeric END,
                    'origen', CASE WHEN COALESCE(v_desc, 0) > 0 THEN 'cliente'
                                   WHEN (v_g->'descuento'->>'efectivo') IS NOT NULL THEN 'grupo' END,
                    'origen_etiqueta', CASE WHEN COALESCE(v_desc, 0) = 0 THEN v_g->'descuento'->>'origen_etiqueta' END)
            ),
            'avisos', v_avisos
        )
    );
END;
$fn$;

-- ---------------------------------------------------------------------------
-- 2. UN PRODUCTO, COMO LO NECESITA UNA LÍNEA DE PROFORMA
-- ---------------------------------------------------------------------------
-- Recibe la fila entera del producto para no repetir la lista de columnas en
-- cada consulta que lo devuelva. Los nombres son los de la LÍNEA, no los del
-- catálogo —`descripcion` es el nombre del producto y `precio_unitario` su
-- precio—, porque es lo que va a rellenar la rejilla.
CREATE OR REPLACE FUNCTION ventas.fn_proformas_producto_json(p inventarios.productos)
RETURNS jsonb
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO 'pg_catalog', 'ventas', 'inventarios'
AS $fn$
    SELECT jsonb_build_object(
        'producto_id',     p.id,
        'codigo',          p.codigo,
        'codigo_barras',   p.codigo_barras,
        'descripcion',     p.nombre,
        'detalle',         p.descripcion,
        'modelo',          p.modelo,
        'unidad',          COALESCE(NULLIF(TRIM(p.unidad), ''), 'UNIDAD'),
        'precio_unitario', p.precio,
        'iva_porcentaje',  COALESCE(p.iva_porcentaje, 0),
        'maneja_stock',    COALESCE(p.maneja_stock, false),
        'maneja_serie',    COALESCE(p.maneja_serie, false),
        'garantia_meses',  p.garantia_meses,
        'marca',           (SELECT m.nombre FROM inventarios.marcas    m WHERE m.id = p.marca_id),
        'categoria',       (SELECT c.nombre FROM inventarios.categorias c WHERE c.id = p.categoria_id)
    );
$fn$;

-- ---------------------------------------------------------------------------
-- 3. BUSCAR UN PRODUCTO DESDE LA REJILLA
-- ---------------------------------------------------------------------------
-- Dos usos en una función, porque son el mismo gesto visto de dos maneras:
--
--   · se teclea un código y se pulsa Enter: si hay UNO que coincide exacto
--     —por código o por código de barras—, viene con `exacto: true` y la
--     línea se rellena sola, sin preguntar nada;
--   · no coincide exacto: vienen los parecidos (hasta p_limite) para que la
--     pantalla los ofrezca o abra el listado completo.
--
-- Devuelve YA CALCULADO lo que la línea necesita: precio, IVA y unidad. Así
-- la rejilla no tiene que saber de dónde sale cada cosa.
CREATE OR REPLACE FUNCTION ventas.fn_proformas_producto_buscar(
    p_texto  text,
    p_limite integer DEFAULT 10
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'pg_catalog', 'ventas', 'inventarios'
AS $fn$
DECLARE
    v_texto  text;
    v_lim    integer := LEAST(GREATEST(COALESCE(p_limite, 10), 1), 50);
    v_exacto jsonb;
    v_lista  jsonb;
BEGIN
    v_texto := NULLIF(TRIM(COALESCE(p_texto, '')), '');
    IF v_texto IS NULL THEN
        RETURN jsonb_build_object('success', true,
                                  'data', jsonb_build_object('exacto', false, 'productos', '[]'::jsonb));
    END IF;

    -- El exacto: por código o por código de barras, sin distinguir mayúsculas
    SELECT ventas.fn_proformas_producto_json(pr)
      INTO v_exacto
      FROM inventarios.productos pr
     WHERE pr.deleted_at IS NULL
       AND pr.activo
       AND (UPPER(TRIM(pr.codigo)) = UPPER(v_texto) OR UPPER(TRIM(COALESCE(pr.codigo_barras, ''))) = UPPER(v_texto))
     ORDER BY pr.id
     LIMIT 1;

    IF v_exacto IS NOT NULL THEN
        RETURN jsonb_build_object('success', true,
                                  'data', jsonb_build_object('exacto', true,
                                                             'productos', jsonb_build_array(v_exacto)));
    END IF;

    -- Los parecidos. Primero los que empiezan por lo escrito —que es lo que
    -- uno espera al teclear media referencia— y después el resto.
    SELECT COALESCE(jsonb_agg(x.p ORDER BY x.prioridad, x.nombre), '[]'::jsonb)
      INTO v_lista
      FROM (SELECT ventas.fn_proformas_producto_json(pr) AS p,
                   pr.nombre,
                   CASE WHEN ventas.fn_sin_tildes(pr.codigo) LIKE ventas.fn_sin_tildes(v_texto) || '%' THEN 0
                        WHEN ventas.fn_sin_tildes(pr.nombre) LIKE ventas.fn_sin_tildes(v_texto) || '%' THEN 1
                        ELSE 2 END AS prioridad
              FROM inventarios.productos pr
             WHERE pr.deleted_at IS NULL
               AND pr.activo
               AND (ventas.fn_sin_tildes(pr.codigo)      LIKE '%' || ventas.fn_sin_tildes(v_texto) || '%'
                 OR ventas.fn_sin_tildes(pr.nombre)      LIKE '%' || ventas.fn_sin_tildes(v_texto) || '%'
                 OR ventas.fn_sin_tildes(pr.descripcion) LIKE '%' || ventas.fn_sin_tildes(v_texto) || '%')
             ORDER BY prioridad, pr.nombre
             LIMIT v_lim) x;

    RETURN jsonb_build_object('success', true,
                              'data', jsonb_build_object('exacto', false, 'productos', v_lista));
END;
$fn$;

-- ---------------------------------------------------------------------------
-- 4. GUARDAR EL DOCUMENTO ENTERO
-- ---------------------------------------------------------------------------
-- Una sola función para crear y para modificar, con p_id nulo o no. En un
-- documento no tiene sentido separarlas: lo que cambia entre las dos es el
-- número —que se saca de la secuencia la primera vez— y nada más.
--
-- LAS LÍNEAS SE BORRAN Y SE VUELVEN A ESCRIBIR. Parece bruto, pero es lo
-- correcto aquí: no son registros con vida propia —nadie las referencia por
-- id— y el alternativo (casar lo que vino con lo que había, línea por línea)
-- es código delicado para no ganar nada. Lo que sí importa es que la
-- transacción es una: o queda el documento completo, o no queda nada.
--
-- DE LO QUE MANDA LA PANTALLA SE USA cantidad, precio, descuento e IVA; los
-- subtotales y el total que venga en el jsonb SE IGNORAN y se recalculan.
CREATE OR REPLACE FUNCTION ventas.fn_proformas_guardar(
    p_id             bigint,
    p_datos          jsonb,
    p_detalle        jsonb,
    p_usuario_id     bigint             DEFAULT NULL,
    p_usuario_login  character varying  DEFAULT NULL,
    p_usuario_nombre character varying  DEFAULT NULL,
    p_ip_address     inet               DEFAULT NULL,
    p_user_agent     text               DEFAULT NULL,
    p_request_id     uuid               DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'ventas', 'inventarios', 'auditoria'
AS $fn$
DECLARE
    v_id       bigint  := p_id;
    v_nuevo    boolean := (p_id IS NULL);
    v_estado   varchar(20);
    v_cliente  bigint;
    v_cli      jsonb;
    v_c        jsonb;            -- el nodo «cliente» de las condiciones
    v_desc_gen numeric;          -- el descuento propuesto en la cabecera

    v_linea  jsonb;
    v_calc   jsonb;
    v_orden  integer := 0;
    v_n      integer := 0;

    -- Lo que dice el catálogo del producto de la línea
    v_pcodigo varchar(30);
    v_pnombre varchar(150);
    v_punidad varchar(15);
    v_pprecio numeric;
    v_piva    numeric;

    -- Lo que acaba guardándose en la línea
    v_prod    bigint;
    v_codigo  varchar(50);
    v_descrip varchar(500);
    v_unidad  varchar(20);
    v_cant    numeric;
    v_precio  numeric;
    v_dto     numeric;
    v_iva     numeric;
BEGIN
    PERFORM ventas.fn_contexto_auditoria('ventas.proformas',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    -- ---- A quién -----------------------------------------------------------
    v_cliente := NULLIF(p_datos->>'cliente_id', '')::bigint;
    IF v_cliente IS NULL THEN
        RAISE EXCEPTION 'Hay que decir a qué cliente se le hace la proforma' USING ERRCODE = 'P0001';
    END IF;

    -- La foto sale de la misma función que usa la pantalla al escoger el
    -- cliente, así lo que se guarda es exactamente lo que el vendedor vio
    v_cli := ventas.fn_proformas_cliente_condiciones(v_cliente);
    IF NOT COALESCE((v_cli->>'success')::boolean, false) THEN
        RAISE EXCEPTION 'El cliente de la proforma no existe' USING ERRCODE = 'P0016';
    END IF;
    v_c := v_cli->'data'->'cliente';

    -- ---- Sin líneas no hay documento --------------------------------------
    IF p_detalle IS NULL OR jsonb_typeof(p_detalle) <> 'array' OR jsonb_array_length(p_detalle) = 0 THEN
        RAISE EXCEPTION 'La proforma no tiene ninguna línea' USING ERRCODE = 'P0001';
    END IF;

    -- ---- ¿Se puede tocar? --------------------------------------------------
    -- Un borrador se cambia cuantas veces haga falta, y una enviada también
    -- —se corrige y se vuelve a enviar—. Pero lo que el cliente ya aprobó o
    -- rechazó NO SE TOCA: para eso está duplicar.
    IF NOT v_nuevo THEN
        SELECT p.estado INTO v_estado
          FROM ventas.proformas p WHERE p.id = p_id AND p.deleted_at IS NULL;

        IF v_estado IS NULL THEN
            RAISE EXCEPTION 'La proforma no existe o está en la papelera' USING ERRCODE = 'P0016';
        END IF;
        IF v_estado NOT IN ('BORRADOR', 'ENVIADA') THEN
            RAISE EXCEPTION 'Esta proforma está % y ya no se puede cambiar: duplíquela para hacer una nueva',
                            lower(ventas.fn_proformas_estado_etiqueta(v_estado))
                USING ERRCODE = 'P0007';
        END IF;
    END IF;

    -- ---- Las condiciones que no vengan, se heredan ------------------------
    -- Si la pantalla no manda la forma de pago, los días de crédito o el
    -- descuento, se usan los del cliente (que a su vez salen de su grupo).
    -- Por eso se distingue entre «no vino la clave» y «vino vacía»: lo
    -- primero es «lo que corresponda», lo segundo es «quítalo».
    IF p_datos ? 'descuento_porcentaje' THEN
        v_desc_gen := COALESCE(NULLIF(p_datos->>'descuento_porcentaje', '')::numeric, 0);
    ELSIF NOT v_nuevo THEN
        SELECT p.descuento_porcentaje INTO v_desc_gen FROM ventas.proformas p WHERE p.id = p_id;
    ELSE
        v_desc_gen := COALESCE((v_cli->'data'->'condiciones'->'descuento'->>'valor')::numeric, 0);
    END IF;

    IF v_desc_gen < 0 OR v_desc_gen > 100 THEN
        RAISE EXCEPTION 'El descuento de la proforma va de 0 a 100' USING ERRCODE = 'P0001';
    END IF;

    -- ---- La cabecera -------------------------------------------------------
    IF v_nuevo THEN
        INSERT INTO ventas.proformas (
            numero, cliente_id, cliente_identificacion, cliente_nombre, cliente_direccion,
            cliente_telefono, cliente_email, grupo_cliente_id,
            vendedor_usuario_id, sucursal_id, bodega_id,
            fecha, validez_dias, forma_pago, dias_credito, descuento_porcentaje, moneda,
            observaciones, condiciones
        ) VALUES (
            ventas.fn_proformas_numero_nuevo(),
            v_cliente,
            v_c->>'identificacion', v_c->>'nombre', v_c->>'direccion',
            v_c->>'telefono', v_c->>'email',
            NULLIF(v_c->>'grupo_cliente_id', '')::bigint,
            -- El vendedor: el que diga la pantalla, el que tenga asignado el
            -- cliente, o quien está guardando. En ese orden.
            COALESCE(NULLIF(p_datos->>'vendedor_usuario_id', '')::bigint,
                     NULLIF(v_c->>'vendedor_usuario_id', '')::bigint,
                     p_usuario_id),
            NULLIF(p_datos->>'sucursal_id', '')::bigint,
            NULLIF(p_datos->>'bodega_id', '')::bigint,
            COALESCE(NULLIF(p_datos->>'fecha', '')::date, CURRENT_DATE),
            COALESCE(NULLIF(p_datos->>'validez_dias', '')::integer, 15),
            CASE WHEN p_datos ? 'forma_pago'
                 THEN NULLIF(UPPER(TRIM(COALESCE(p_datos->>'forma_pago', ''))), '')
                 ELSE v_cli->'data'->'condiciones'->'forma_pago'->>'valor' END,
            CASE WHEN p_datos ? 'dias_credito'
                 THEN NULLIF(p_datos->>'dias_credito', '')::integer
                 ELSE (v_cli->'data'->'condiciones'->'dias_credito'->>'valor')::integer END,
            v_desc_gen,
            COALESCE(NULLIF(UPPER(TRIM(COALESCE(p_datos->>'moneda', ''))), ''), 'USD'),
            NULLIF(TRIM(COALESCE(p_datos->>'observaciones', '')), ''),
            NULLIF(TRIM(COALESCE(p_datos->>'condiciones', '')), '')
        )
        RETURNING id INTO v_id;
    ELSE
        -- La foto del cliente se vuelve a tomar: puede que hayan cambiado el
        -- cliente de la proforma, o que le hayan corregido la dirección antes
        -- de imprimirla. Mientras es borrador o está enviada, eso es correcto.
        UPDATE ventas.proformas SET
            cliente_id             = v_cliente,
            cliente_identificacion = v_c->>'identificacion',
            cliente_nombre         = v_c->>'nombre',
            cliente_direccion      = v_c->>'direccion',
            cliente_telefono       = v_c->>'telefono',
            cliente_email          = v_c->>'email',
            grupo_cliente_id       = NULLIF(v_c->>'grupo_cliente_id', '')::bigint,
            -- Lo que no venga en el jsonb se queda como estaba: así se puede
            -- mandar sólo lo que cambió sin borrar el resto sin querer
            vendedor_usuario_id    = COALESCE(NULLIF(p_datos->>'vendedor_usuario_id', '')::bigint, vendedor_usuario_id),
            sucursal_id            = CASE WHEN p_datos ? 'sucursal_id'   THEN NULLIF(p_datos->>'sucursal_id', '')::bigint   ELSE sucursal_id   END,
            bodega_id              = CASE WHEN p_datos ? 'bodega_id'     THEN NULLIF(p_datos->>'bodega_id', '')::bigint     ELSE bodega_id     END,
            fecha                  = COALESCE(NULLIF(p_datos->>'fecha', '')::date, fecha),
            validez_dias           = COALESCE(NULLIF(p_datos->>'validez_dias', '')::integer, validez_dias),
            forma_pago             = CASE WHEN p_datos ? 'forma_pago'    THEN NULLIF(UPPER(TRIM(COALESCE(p_datos->>'forma_pago', ''))), '') ELSE forma_pago   END,
            dias_credito           = CASE WHEN p_datos ? 'dias_credito'  THEN NULLIF(p_datos->>'dias_credito', '')::integer ELSE dias_credito END,
            descuento_porcentaje   = v_desc_gen,
            moneda                 = COALESCE(NULLIF(UPPER(TRIM(COALESCE(p_datos->>'moneda', ''))), ''), moneda),
            observaciones          = CASE WHEN p_datos ? 'observaciones' THEN NULLIF(TRIM(COALESCE(p_datos->>'observaciones', '')), '') ELSE observaciones END,
            condiciones            = CASE WHEN p_datos ? 'condiciones'   THEN NULLIF(TRIM(COALESCE(p_datos->>'condiciones', '')), '')   ELSE condiciones   END
          WHERE id = v_id;
    END IF;

    -- ---- Las líneas --------------------------------------------------------
    DELETE FROM ventas.proformas_detalle WHERE proforma_id = v_id;

    FOR v_linea IN SELECT value FROM jsonb_array_elements(p_detalle) LOOP
        v_n := v_n + 1;

        v_prod    := NULLIF(v_linea->>'producto_id', '')::bigint;
        v_pcodigo := NULL; v_pnombre := NULL; v_punidad := NULL;
        v_pprecio := NULL; v_piva := NULL;

        -- Si la línea dice de qué producto es, el catálogo rellena lo que la
        -- pantalla no haya mandado (y de paso se comprueba que siga existiendo)
        IF v_prod IS NOT NULL THEN
            SELECT pr.codigo, pr.nombre, pr.unidad, pr.precio, COALESCE(pr.iva_porcentaje, 0)
              INTO v_pcodigo, v_pnombre, v_punidad, v_pprecio, v_piva
              FROM inventarios.productos pr
             WHERE pr.id = v_prod AND pr.deleted_at IS NULL;

            IF v_pnombre IS NULL THEN
                RAISE EXCEPTION 'Línea %: ese producto ya no existe en el catálogo', v_n
                    USING ERRCODE = 'P0016';
            END IF;
        END IF;

        v_codigo  := COALESCE(NULLIF(TRIM(COALESCE(v_linea->>'codigo', '')), ''), v_pcodigo);
        v_descrip := COALESCE(NULLIF(TRIM(COALESCE(v_linea->>'descripcion', '')), ''), v_pnombre);
        IF v_descrip IS NULL THEN
            RAISE EXCEPTION 'Línea %: hay que escribir qué se está cotizando', v_n USING ERRCODE = 'P0001';
        END IF;

        v_unidad := COALESCE(NULLIF(TRIM(COALESCE(v_linea->>'unidad', '')), ''), v_punidad, 'UNIDAD');
        v_cant   := COALESCE(NULLIF(v_linea->>'cantidad', '')::numeric, 0);
        v_precio := COALESCE(NULLIF(v_linea->>'precio_unitario', '')::numeric, v_pprecio, 0);
        -- Si la línea no dice nada de descuento, lleva el que se propuso en la
        -- cabecera; si no dice nada de IVA, el que tenga el producto
        v_dto    := COALESCE(NULLIF(v_linea->>'descuento_porcentaje', '')::numeric, v_desc_gen);
        v_iva    := COALESCE(NULLIF(v_linea->>'iva_porcentaje', '')::numeric, v_piva, 0);

        IF v_cant <= 0 THEN
            RAISE EXCEPTION 'Línea % (%): la cantidad tiene que ser mayor que cero', v_n, v_descrip
                USING ERRCODE = 'P0001';
        END IF;
        IF v_precio < 0 THEN
            RAISE EXCEPTION 'Línea % (%): el precio no puede ser negativo', v_n, v_descrip
                USING ERRCODE = 'P0001';
        END IF;
        IF v_dto < 0 OR v_dto > 100 THEN
            RAISE EXCEPTION 'Línea % (%): el descuento va de 0 a 100', v_n, v_descrip
                USING ERRCODE = 'P0001';
        END IF;
        IF v_iva < 0 OR v_iva > 100 THEN
            RAISE EXCEPTION 'Línea % (%): el IVA va de 0 a 100', v_n, v_descrip
                USING ERRCODE = 'P0001';
        END IF;

        v_orden := v_orden + 1;
        v_calc  := ventas.fn_proformas_linea_calcular(v_cant, v_precio, v_dto, v_iva);

        INSERT INTO ventas.proformas_detalle (
            proforma_id, orden, producto_id, codigo, descripcion, unidad,
            cantidad, precio_unitario, descuento_porcentaje, iva_porcentaje,
            subtotal, descuento_valor, base, iva_valor, total, observacion
        ) VALUES (
            v_id, v_orden, v_prod, v_codigo, v_descrip, v_unidad,
            v_cant, v_precio, v_dto, v_iva,
            (v_calc->>'subtotal')::numeric,
            (v_calc->>'descuento_valor')::numeric,
            (v_calc->>'base')::numeric,
            (v_calc->>'iva_valor')::numeric,
            (v_calc->>'total')::numeric,
            NULLIF(TRIM(COALESCE(v_linea->>'observacion', '')), '')
        );
    END LOOP;

    PERFORM ventas.fn_proformas_recalcular(v_id);

    RETURN jsonb_build_object(
        'success', true,
        'message', CASE WHEN v_nuevo THEN 'Proforma creada exitosamente'
                                     ELSE 'Proforma actualizada exitosamente' END,
        'data',    ventas.fn_proformas_json(v_id));
END;
$fn$;

COMMENT ON FUNCTION ventas.fn_proformas_guardar(bigint,jsonb,jsonb,bigint,character varying,character varying,inet,text,uuid) IS
'Crea (p_id nulo) o modifica una proforma completa. Recalcula todos los importes: lo que venga en subtotal/total se ignora.';

COMMIT;
