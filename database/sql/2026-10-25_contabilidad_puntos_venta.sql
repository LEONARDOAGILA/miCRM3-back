-- ===========================================================================
-- LAS CUENTAS DE UN PUNTO DE VENTA (ámbito PUNTO_VENTA)
-- ===========================================================================
-- El mecanismo de cuentas ya existía y es el mismo de siempre: un CONCEPTO
-- («la caja», «los sobrantes») que cada cosa resuelve a una cuenta del plan,
-- con herencia y con el tercer estado «no aplica». Aquí sólo se le añade un
-- ámbito más y sus conceptos.
--
-- LA CADENA ES: punto de venta → su sucursal → lo que valga para todos.
--
-- Es lo que hace que esto se pueda mantener de verdad. Las tarjetas, el
-- banco, los sobrantes y los faltantes son los mismos para toda la empresa
-- (o para una tienda), así que se ponen UNA VEZ; de cada caja sólo hay que
-- decir cuál es su cuenta de efectivo, que es lo único que de verdad es
-- suya. Un punto de venta nuevo nace con todo heredado menos eso.
--
-- QUÉ CUENTAS NECESITA UNA CAJA, y por qué cada una:
--
--   CAJA_PV            el dinero que hay dentro del cajón. ES LA ÚNICA QUE
--                      CASI SIEMPRE ES PROPIA: si dos cajas comparten
--                      cuenta, no hay manera de saber cuál cuadró y cuál no.
--   FONDO_CAMBIO       el fondo fijo para dar vueltos. Se separa de la caja
--                      porque no es venta del día: está ahí todas las
--                      mañanas y vuelve al cierre.
--   TARJETA_CREDITO    lo cobrado con tarjeta de crédito. NO es efectivo: es
--                      una cuenta POR COBRAR a la procesadora hasta que
--                      acredite, y se concilia contra su liquidación.
--   TARJETA_DEBITO     lo mismo con débito, que suele acreditar en otro
--                      plazo y con otra comisión.
--   TRANSFERENCIA      lo que el cliente deposita o transfiere: entra
--                      directo al banco, no pasa por el cajón.
--   CHEQUE_RECIBIDO    cheques en mano, pendientes de depositar.
--   EFECTIVO_TRANSITO  lo que sale de la caja camino del banco o de la
--                      bóveda y todavía no llegó. Sin esta cuenta, el
--                      efectivo «desaparece» entre el cierre y el depósito.
--   SOBRANTE_CAJA      lo que sobra al cuadrar (ingreso).
--   FALTANTE_CAJA      lo que falta al cuadrar (gasto). Van separadas a
--                      propósito: netearlas esconde justo lo que hay que
--                      vigilar.
--   REDONDEO           los centavos que se perdonan al cobrar en efectivo.
--
-- Lo que NO va aquí porque ya está en otro ámbito: el ingreso, el costo y el
-- inventario salen de la CATEGORÍA del producto; la cuenta por cobrar y los
-- anticipos, del GRUPO del cliente. Una caja no decide eso.
\set ON_ERROR_STOP on

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. EL ÁMBITO NUEVO
-- ---------------------------------------------------------------------------
ALTER TABLE contabilidad.conceptos_contables DROP CONSTRAINT IF EXISTS ck_conceptos_ambito;
ALTER TABLE contabilidad.conceptos_contables
    ADD CONSTRAINT ck_conceptos_ambito CHECK (ambito_natural IN (
        'CATEGORIA','PRODUCTO','GRUPO_CLIENTE','CLIENTE','SUCURSAL','PUNTO_VENTA','IMPUESTO','FORMA_PAGO','GLOBAL'));

ALTER TABLE contabilidad.cuentas_config DROP CONSTRAINT IF EXISTS ck_cuentas_config_ambito;
ALTER TABLE contabilidad.cuentas_config
    ADD CONSTRAINT ck_cuentas_config_ambito CHECK (ambito IN (
        'CATEGORIA','PRODUCTO','GRUPO_CLIENTE','CLIENTE','SUCURSAL','PUNTO_VENTA','IMPUESTO','FORMA_PAGO','GLOBAL'));

-- ---------------------------------------------------------------------------
-- 2. LOS CONCEPTOS
-- ---------------------------------------------------------------------------
-- `tipos_permitidos` no es un adorno: es lo que impide poner una cuenta de
-- gasto donde va la caja. El desplegable de la pantalla sólo ofrece las de
-- esos tipos, y el servidor lo vuelve a comprobar al guardar.
INSERT INTO contabilidad.conceptos_contables
    (codigo, nombre, descripcion, ambito_natural, tipos_permitidos, naturaleza_tipica, orden, created_by, updated_by)
VALUES
    ('CAJA_PV', 'Caja del punto de venta',
     'El efectivo que hay en el cajón de esta caja. Normalmente es propia de cada punto: si dos comparten cuenta, no se sabe cuál cuadró.',
     'PUNTO_VENTA', ARRAY['ACTIVO']::varchar[], 'DEUDORA', 21, 'postgres', 'postgres'),

    ('FONDO_CAMBIO', 'Fondo de cambio',
     'El fondo fijo para dar vueltos. No es venta del día: está ahí cada mañana y vuelve al cierre.',
     'PUNTO_VENTA', ARRAY['ACTIVO']::varchar[], 'DEUDORA', 22, 'postgres', 'postgres'),

    ('TARJETA_CREDITO', 'Cobros con tarjeta de crédito',
     'Por cobrar a la procesadora hasta que acredite. No es efectivo: se concilia contra la liquidación del banco.',
     'PUNTO_VENTA', ARRAY['ACTIVO']::varchar[], 'DEUDORA', 23, 'postgres', 'postgres'),

    ('TARJETA_DEBITO', 'Cobros con tarjeta de débito',
     'Lo mismo que el crédito, pero suele acreditar en otro plazo y con otra comisión.',
     'PUNTO_VENTA', ARRAY['ACTIVO']::varchar[], 'DEUDORA', 24, 'postgres', 'postgres'),

    ('TRANSFERENCIA', 'Cobros por transferencia o depósito',
     'Entra directo a la cuenta del banco, sin pasar por el cajón.',
     'PUNTO_VENTA', ARRAY['ACTIVO']::varchar[], 'DEUDORA', 25, 'postgres', 'postgres'),

    ('CHEQUE_RECIBIDO', 'Cheques recibidos',
     'Cheques en mano, pendientes de depositar.',
     'PUNTO_VENTA', ARRAY['ACTIVO']::varchar[], 'DEUDORA', 26, 'postgres', 'postgres'),

    ('EFECTIVO_TRANSITO', 'Efectivo en tránsito',
     'Lo que salió de la caja camino del banco o de la bóveda y todavía no llegó. Sin esta cuenta el efectivo desaparece entre el cierre y el depósito.',
     'PUNTO_VENTA', ARRAY['ACTIVO']::varchar[], 'DEUDORA', 27, 'postgres', 'postgres'),

    ('SOBRANTE_CAJA', 'Sobrantes de caja',
     'Lo que sobra al cuadrar.',
     'PUNTO_VENTA', ARRAY['INGRESO']::varchar[], 'ACREEDORA', 28, 'postgres', 'postgres'),

    ('FALTANTE_CAJA', 'Faltantes de caja',
     'Lo que falta al cuadrar. Va separado de los sobrantes a propósito: netearlos esconde justo lo que hay que vigilar.',
     'PUNTO_VENTA', ARRAY['GASTO']::varchar[], 'DEUDORA', 29, 'postgres', 'postgres'),

    ('REDONDEO', 'Redondeo en cobros',
     'Los centavos que se perdonan al cobrar en efectivo. Admite cuenta de ingreso o de gasto, según cómo se lleve.',
     'PUNTO_VENTA', ARRAY['INGRESO','GASTO']::varchar[], NULL, 30, 'postgres', 'postgres')
ON CONFLICT (codigo) DO NOTHING;

-- ---------------------------------------------------------------------------
-- 3. LAS FUNCIONES, CON EL ÁMBITO NUEVO
-- ---------------------------------------------------------------------------
-- 3.1 El resolvedor: una caja hereda de su sucursal
CREATE OR REPLACE FUNCTION contabilidad.fn_cuenta_de_detalle(p_concepto character varying, p_ambito character varying DEFAULT 'GLOBAL'::character varying, p_ambito_id bigint DEFAULT NULL::bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'contabilidad'
AS $function$
DECLARE
    v_cuenta    bigint;
    v_no_aplica boolean := false;
    /* Se mira esto y no `v_cuenta IS NULL`: una fila que dice «no aplica» no
       tiene cuenta, y aun así es una respuesta y corta la búsqueda. */
    v_hay       boolean := false;
    v_origen    varchar;
    v_origen_id bigint;
    v_etiqueta  varchar;
    v_categoria bigint;
    v_grupo     bigint;
    v_sucursal  bigint;
BEGIN
    -- 1) Lo que tenga la propia cosa
    IF p_ambito_id IS NOT NULL THEN
        SELECT cuenta_id, no_aplica INTO v_cuenta, v_no_aplica
          FROM contabilidad.cuentas_config
         WHERE ambito = p_ambito AND ambito_id = p_ambito_id AND concepto = p_concepto;
        IF FOUND THEN
            v_hay := true;
            v_origen := p_ambito; v_origen_id := p_ambito_id;
            v_etiqueta := CASE WHEN v_no_aplica THEN 'No aplica aquí' ELSE 'Propia' END;
        END IF;
    END IF;

    -- 2) Un producto hereda de su categoría
    IF NOT v_hay AND p_ambito = 'PRODUCTO' AND p_ambito_id IS NOT NULL THEN
        SELECT categoria_id INTO v_categoria FROM inventarios.productos WHERE id = p_ambito_id;
    ELSIF p_ambito = 'CATEGORIA' THEN
        v_categoria := p_ambito_id;
    END IF;

    -- 3) Y una categoría, de las de arriba: se configura una vez en la rama
    IF NOT v_hay AND v_categoria IS NOT NULL THEN
        WITH RECURSIVE sube AS (
            SELECT c.id, c.padre_id, 0 AS salto
              FROM inventarios.categorias c WHERE c.id = v_categoria
            UNION ALL
            SELECT p.id, p.padre_id, s.salto + 1
              FROM inventarios.categorias p JOIN sube s ON p.id = s.padre_id
        )
        SELECT cc.cuenta_id, cc.no_aplica, s.id, c.nombre
          INTO v_cuenta, v_no_aplica, v_origen_id, v_etiqueta
          FROM sube s
          JOIN contabilidad.cuentas_config cc
            ON cc.ambito = 'CATEGORIA' AND cc.ambito_id = s.id AND cc.concepto = p_concepto
          JOIN inventarios.categorias c ON c.id = s.id
         ORDER BY s.salto
         LIMIT 1;

        IF FOUND THEN
            v_hay := true;
            v_origen := 'CATEGORIA';
            IF p_ambito = 'CATEGORIA' AND v_origen_id = p_ambito_id THEN
                v_etiqueta := CASE WHEN v_no_aplica THEN 'No aplica aquí' ELSE 'Propia' END;
            ELSE
                v_etiqueta := CASE WHEN v_no_aplica THEN 'No aplica (desde ' || v_etiqueta || ')'
                                   ELSE 'Heredada de ' || v_etiqueta END;
            END IF;
        END IF;
    END IF;

    -- 3 bis) LOS CLIENTES. Un cliente hereda de su grupo comercial, y un
    -- grupo de los de arriba: la cuenta por cobrar se pone una vez en
    -- «Relacionados» y la usan todos los que cuelgan de ahí.
    IF NOT v_hay AND p_ambito = 'CLIENTE' AND p_ambito_id IS NOT NULL THEN
        SELECT grupo_cliente_id INTO v_grupo FROM ventas.clientes WHERE id = p_ambito_id;
    ELSIF p_ambito = 'GRUPO_CLIENTE' THEN
        v_grupo := p_ambito_id;
    END IF;

    IF NOT v_hay AND v_grupo IS NOT NULL THEN
        WITH RECURSIVE sube AS (
            SELECT g.id, g.padre_id, 0 AS salto
              FROM ventas.grupos_clientes g WHERE g.id = v_grupo
            UNION ALL
            SELECT p.id, p.padre_id, s.salto + 1
              FROM ventas.grupos_clientes p JOIN sube s ON p.id = s.padre_id
        )
        SELECT cc.cuenta_id, cc.no_aplica, s.id, g.nombre
          INTO v_cuenta, v_no_aplica, v_origen_id, v_etiqueta
          FROM sube s
          JOIN contabilidad.cuentas_config cc
            ON cc.ambito = 'GRUPO_CLIENTE' AND cc.ambito_id = s.id AND cc.concepto = p_concepto
          JOIN ventas.grupos_clientes g ON g.id = s.id
         ORDER BY s.salto
         LIMIT 1;

        IF FOUND THEN
            v_hay := true;
            v_origen := 'GRUPO_CLIENTE';
            IF p_ambito = 'GRUPO_CLIENTE' AND v_origen_id = p_ambito_id THEN
                v_etiqueta := CASE WHEN v_no_aplica THEN 'No aplica aquí' ELSE 'Propia' END;
            ELSE
                v_etiqueta := CASE WHEN v_no_aplica THEN 'No aplica (desde ' || v_etiqueta || ')'
                                   ELSE 'Heredada de ' || v_etiqueta END;
            END IF;
        END IF;
    END IF;

    -- 3 ter) LOS PUNTOS DE VENTA. Una caja hereda de SU SUCURSAL, y la
    -- sucursal de lo que valga para todos. Es la cadena que hace que esto se
    -- pueda mantener: las tarjetas, el banco y los sobrantes se ponen una vez
    -- —para toda la empresa o para la tienda— y de cada caja sólo hay que
    -- decir cuál es SU cuenta de efectivo, que es lo único que de verdad es
    -- suyo.
    IF NOT v_hay AND p_ambito = 'PUNTO_VENTA' AND p_ambito_id IS NOT NULL THEN
        SELECT pv.sucursal_id INTO v_sucursal
          FROM core.puntos_venta pv WHERE pv.id = p_ambito_id;

        IF v_sucursal IS NOT NULL THEN
            SELECT cc.cuenta_id, cc.no_aplica INTO v_cuenta, v_no_aplica
              FROM contabilidad.cuentas_config cc
             WHERE cc.ambito = 'SUCURSAL' AND cc.ambito_id = v_sucursal
               AND cc.concepto = p_concepto;

            IF FOUND THEN
                v_hay := true;
                v_origen := 'SUCURSAL';
                v_origen_id := v_sucursal;
                SELECT s.nombre INTO v_etiqueta FROM ventas.sucursales s WHERE s.id = v_sucursal;
                v_etiqueta := CASE WHEN v_no_aplica THEN 'No aplica (desde ' || v_etiqueta || ')'
                                   ELSE 'Heredada de ' || v_etiqueta END;
            END IF;
        END IF;
    END IF;

    -- 4) Y si nadie dijo nada, lo que valga para todos
    IF NOT v_hay THEN
        SELECT cuenta_id, no_aplica INTO v_cuenta, v_no_aplica
          FROM contabilidad.cuentas_config
         WHERE ambito = 'GLOBAL' AND concepto = p_concepto;
        IF FOUND THEN
            v_hay := true;
            v_origen := 'GLOBAL'; v_origen_id := NULL;
            v_etiqueta := CASE WHEN v_no_aplica THEN 'No aplica (por omisión)' ELSE 'Por omisión' END;
        END IF;
    END IF;

    -- Nadie dijo nada: ni cuenta ni «no aplica». Falta configurarlo.
    IF NOT v_hay THEN
        RETURN jsonb_build_object('cuenta_id', NULL, 'no_aplica', false,
                                  'origen', NULL, 'origen_id', NULL, 'origen_etiqueta', NULL);
    END IF;

    -- Dijeron que aquí este concepto no existe: no hay cuenta, y es correcto
    IF v_no_aplica THEN
        RETURN jsonb_build_object('cuenta_id', NULL, 'no_aplica', true,
                                  'origen', v_origen, 'origen_id', v_origen_id,
                                  'origen_etiqueta', v_etiqueta);
    END IF;

    RETURN jsonb_build_object(
        'cuenta_id',       v_cuenta,
        'no_aplica',       false,
        'origen',          v_origen,
        'origen_id',       v_origen_id,
        'origen_etiqueta', v_etiqueta,
        'codigo',          (SELECT codigo FROM contabilidad.plan_cuentas WHERE id = v_cuenta),
        'nombre',          (SELECT nombre FROM contabilidad.plan_cuentas WHERE id = v_cuenta),
        'tipo',            (SELECT tipo   FROM contabilidad.plan_cuentas WHERE id = v_cuenta)
    );
END;
$function$
;

-- 3.2 Lo que quedaría si se le quita lo suyo
CREATE OR REPLACE FUNCTION contabilidad.fn_cuenta_heredada_detalle(p_concepto character varying, p_ambito character varying, p_ambito_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'contabilidad'
AS $function$
DECLARE
    v_padre    bigint;
    v_sucursal bigint;
    v          jsonb;
BEGIN
    IF p_ambito = 'CATEGORIA' THEN
        RETURN contabilidad.fn_cuenta_heredada_detalle(p_concepto, p_ambito_id);
    END IF;

    -- Una caja: lo que quedaría es lo de su sucursal, y si la sucursal no
    -- dice nada, lo que valga para todos (de eso ya se encarga
    -- fn_cuenta_de_detalle cuando se le pregunta por la sucursal).
    IF p_ambito = 'PUNTO_VENTA' THEN
        SELECT pv.sucursal_id INTO v_sucursal
          FROM core.puntos_venta pv WHERE pv.id = p_ambito_id;

        IF v_sucursal IS NULL THEN
            RETURN contabilidad.fn_cuenta_de_detalle(p_concepto, 'GLOBAL', NULL);
        END IF;

        v := contabilidad.fn_cuenta_de_detalle(p_concepto, 'SUCURSAL', v_sucursal);

        -- Lo que para la sucursal es «propia», para la caja es heredada
        IF v->>'origen' = 'SUCURSAL' THEN
            v := jsonb_set(v, '{origen_etiqueta}',
                           to_jsonb(CASE WHEN (v->>'no_aplica')::boolean
                                         THEN 'No aplica (desde ' || (SELECT s.nombre FROM ventas.sucursales s
                                                                       WHERE s.id = (v->>'origen_id')::bigint) || ')'
                                         ELSE 'Heredada de ' || (SELECT s.nombre FROM ventas.sucursales s
                                                                  WHERE s.id = (v->>'origen_id')::bigint) END));
        END IF;
        RETURN v;
    END IF;

    IF p_ambito <> 'GRUPO_CLIENTE' THEN
        RETURN contabilidad.fn_cuenta_de_detalle(p_concepto, 'GLOBAL', NULL);
    END IF;

    SELECT padre_id INTO v_padre FROM ventas.grupos_clientes WHERE id = p_ambito_id;
    IF v_padre IS NULL THEN
        RETURN contabilidad.fn_cuenta_de_detalle(p_concepto, 'GLOBAL', NULL);
    END IF;

    v := contabilidad.fn_cuenta_de_detalle(p_concepto, 'GRUPO_CLIENTE', v_padre);

    -- Lo que para el de arriba es «propia», para éste es heredada. Y si lo de
    -- arriba es un «no aplica», no se hereda una cuenta: se hereda que aquí
    -- no hay nada que asentar.
    IF v->>'origen' = 'GRUPO_CLIENTE' THEN
        v := jsonb_set(v, '{origen_etiqueta}',
                       to_jsonb(CASE WHEN (v->>'no_aplica')::boolean THEN 'desde ' ELSE 'Heredada de ' END ||
                                (SELECT nombre FROM ventas.grupos_clientes WHERE id = (v->>'origen_id')::bigint)));
    END IF;
    RETURN v;
END;
$function$
;

-- 3.3 La ficha de configuración
CREATE OR REPLACE FUNCTION contabilidad.fn_cuentas_config_obtener(p_ambito character varying, p_ambito_id bigint DEFAULT NULL::bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'contabilidad'
AS $function$
DECLARE
    v_data  jsonb;
    v_donde jsonb;
BEGIN
    SELECT COALESCE(jsonb_agg(x.fila ORDER BY x.orden), '[]'::jsonb) INTO v_data
      FROM (
        SELECT c.orden,
               jsonb_build_object(
                   'concepto',          c.codigo,
                   'nombre',            c.nombre,
                   'descripcion',       c.descripcion,
                   'tipos_permitidos',  to_jsonb(c.tipos_permitidos),
                   'naturaleza_tipica', c.naturaleza_tipica,
                   -- Lo que tiene puesto ESTA cosa, que es lo único editable aquí
                   'propia', (SELECT CASE WHEN cc.no_aplica
                                          THEN jsonb_build_object('no_aplica', true)
                                          ELSE jsonb_build_object('cuenta_id', p.id, 'codigo', p.codigo,
                                                                  'nombre', p.nombre, 'tipo', p.tipo,
                                                                  'no_aplica', false) END
                                FROM contabilidad.cuentas_config cc
                                LEFT JOIN contabilidad.plan_cuentas p ON p.id = cc.cuenta_id
                               WHERE cc.ambito = p_ambito
                                 AND cc.ambito_id IS NOT DISTINCT FROM p_ambito_id
                                 AND cc.concepto = c.codigo),
                   -- Y la que se usaría de verdad, venga de donde venga
                   'efectiva', contabilidad.fn_cuenta_de_detalle(c.codigo, p_ambito, p_ambito_id),
                   -- La que quedaría SI SE QUITARA la propia: se resuelve
                   -- desde la categoría de arriba, saltándose ésta. Sin esto,
                   -- al vaciar el campo la pantalla enseñaría como «heredada»
                   -- justo la cuenta que se acaba de quitar.
                   'heredada', CASE WHEN p_ambito IN ('CATEGORIA', 'GRUPO_CLIENTE', 'PUNTO_VENTA')
                       THEN contabilidad.fn_cuenta_heredada_detalle(c.codigo, p_ambito, p_ambito_id) END
               ) AS fila
          FROM contabilidad.conceptos_contables c
         WHERE c.activo
           AND (p_ambito = 'GLOBAL' OR c.ambito_natural = p_ambito)
      ) x;

    -- De qué se están configurando las cuentas, para el título de la ficha
    v_donde := CASE
        -- GLOBAL es el mismo para los dos árboles, pero se lee en la pantalla
        -- que lo abrió: ahí se dice de qué se está hablando.
        WHEN p_ambito = 'GLOBAL' THEN jsonb_build_object('etiqueta', 'Por omisión (vale para todos)')
        WHEN p_ambito = 'CATEGORIA' THEN
            (SELECT jsonb_build_object('etiqueta', c.nombre, 'ruta', c.nombre,
                                       'es_transaccion', c.es_transaccion, 'nivel', c.nivel)
               FROM inventarios.categorias c WHERE c.id = p_ambito_id)
        WHEN p_ambito = 'GRUPO_CLIENTE' THEN
            (SELECT jsonb_build_object('etiqueta', g.nombre,
                                       'ruta', (ventas.fn_grupos_clientes_json(g.id))->>'ruta',
                                       'nivel', g.nivel,
                                       'num_clientes', (SELECT COUNT(*) FROM ventas.clientes c
                                                         WHERE c.grupo_cliente_id = g.id AND c.deleted_at IS NULL))
               FROM ventas.grupos_clientes g WHERE g.id = p_ambito_id)
        WHEN p_ambito = 'PUNTO_VENTA' THEN
            (SELECT jsonb_build_object('etiqueta', pv.nombre,
                                       'ruta', COALESCE(s.nombre || ' > ', '') || pv.nombre,
                                       'codigo', pv.codigo,
                                       'numero', pv.numero,
                                       'sucursal_id', pv.sucursal_id,
                                       'sucursal', s.nombre)
               FROM core.puntos_venta pv
               LEFT JOIN ventas.sucursales s ON s.id = pv.sucursal_id
              WHERE pv.id = p_ambito_id)
        WHEN p_ambito = 'SUCURSAL' THEN
            (SELECT jsonb_build_object('etiqueta', s.nombre, 'ruta', s.nombre, 'codigo', s.codigo)
               FROM ventas.sucursales s WHERE s.id = p_ambito_id)
        ELSE jsonb_build_object('etiqueta', p_ambito || ' ' || COALESCE(p_ambito_id::text, ''))
    END;

    RETURN jsonb_build_object('success', true, 'message', 'Configuración contable',
                              'data', jsonb_build_object('ambito', p_ambito, 'ambito_id', p_ambito_id,
                                                         'donde', v_donde, 'conceptos', v_data));
END;
$function$
;

-- 3.4 Al guardar: ámbito admitido y que la caja exista
CREATE OR REPLACE FUNCTION contabilidad.fn_cuentas_config_guardar(p_ambito character varying, p_ambito_id bigint, p_cuentas jsonb, p_usuario_id bigint DEFAULT NULL::bigint, p_usuario_login character varying DEFAULT NULL::character varying, p_usuario_nombre character varying DEFAULT NULL::character varying, p_ip_address inet DEFAULT NULL::inet, p_user_agent text DEFAULT NULL::text, p_request_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'contabilidad', 'auditoria'
AS $function$
DECLARE
    v_par      record;
    v_cuenta   bigint;
    v_accion   varchar;
    v_puestas  integer := 0;
    v_quitadas integer := 0;
    v_na       integer := 0;
BEGIN
    PERFORM contabilidad.fn_contexto_auditoria('contabilidad.cuentas_config',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    IF p_ambito NOT IN ('CATEGORIA','PRODUCTO','GRUPO_CLIENTE','CLIENTE','SUCURSAL','PUNTO_VENTA','IMPUESTO','FORMA_PAGO','GLOBAL') THEN
        RAISE EXCEPTION 'Ámbito no válido: %', p_ambito USING ERRCODE = 'P0001';
    END IF;
    IF (p_ambito = 'GLOBAL') <> (p_ambito_id IS NULL) THEN
        RAISE EXCEPTION 'El ámbito GLOBAL no lleva id, y los demás lo necesitan' USING ERRCODE = 'P0001';
    END IF;
    IF p_ambito = 'CATEGORIA'
       AND NOT EXISTS (SELECT 1 FROM inventarios.categorias WHERE id = p_ambito_id AND deleted_at IS NULL) THEN
        RAISE EXCEPTION 'La categoría no existe' USING ERRCODE = 'P0016';
    END IF;
    IF p_ambito = 'GRUPO_CLIENTE'
       AND NOT EXISTS (SELECT 1 FROM ventas.grupos_clientes WHERE id = p_ambito_id AND deleted_at IS NULL) THEN
        RAISE EXCEPTION 'El grupo de clientes no existe' USING ERRCODE = 'P0016';
    END IF;
    IF p_ambito = 'PUNTO_VENTA'
       AND NOT EXISTS (SELECT 1 FROM core.puntos_venta WHERE id = p_ambito_id AND deleted_at IS NULL) THEN
        RAISE EXCEPTION 'El punto de venta no existe' USING ERRCODE = 'P0016';
    END IF;
    IF p_cuentas IS NULL OR jsonb_typeof(p_cuentas) <> 'object' THEN
        RAISE EXCEPTION 'No se indicó ninguna cuenta' USING ERRCODE = 'P0001';
    END IF;

    FOR v_par IN SELECT key AS concepto, value FROM jsonb_each(p_cuentas) LOOP
        IF NOT EXISTS (SELECT 1 FROM contabilidad.conceptos_contables WHERE codigo = v_par.concepto AND activo) THEN
            RAISE EXCEPTION 'Concepto contable desconocido: %', v_par.concepto USING ERRCODE = 'P0001';
        END IF;

        -- Qué pidió la pantalla para este concepto
        v_cuenta := NULL;
        IF jsonb_typeof(v_par.value) = 'null' THEN
            v_accion := 'HEREDAR';
        ELSIF jsonb_typeof(v_par.value) = 'string'
              AND UPPER(TRIM(v_par.value #>> '{}')) IN ('NO_APLICA', 'NO APLICA', 'N/A') THEN
            v_accion := 'NO_APLICA';
        ELSE
            v_cuenta := NULLIF(TRIM(v_par.value #>> '{}'), '')::bigint;
            v_accion := CASE WHEN v_cuenta IS NULL THEN 'HEREDAR' ELSE 'CUENTA' END;
        END IF;

        IF v_accion = 'HEREDAR' THEN
            -- Quitar lo propio: vuelve a heredar
            DELETE FROM contabilidad.cuentas_config
             WHERE ambito = p_ambito AND ambito_id IS NOT DISTINCT FROM p_ambito_id
               AND concepto = v_par.concepto;
            IF FOUND THEN v_quitadas := v_quitadas + 1; END IF;

        ELSIF v_accion = 'NO_APLICA' THEN
            -- Aquí este concepto no existe: sin cuenta y sin heredar
            IF EXISTS (SELECT 1 FROM contabilidad.cuentas_config
                        WHERE ambito = p_ambito AND ambito_id IS NOT DISTINCT FROM p_ambito_id
                          AND concepto = v_par.concepto) THEN
                UPDATE contabilidad.cuentas_config SET cuenta_id = NULL, no_aplica = true
                 WHERE ambito = p_ambito AND ambito_id IS NOT DISTINCT FROM p_ambito_id
                   AND concepto = v_par.concepto
                   AND (cuenta_id IS NOT NULL OR NOT no_aplica);
                -- Sólo cuenta si de verdad cambió: la ficha manda los ocho
                -- conceptos cada vez, y decir «8 guardadas» cuando se tocó
                -- uno no ayuda a nadie
                IF FOUND THEN v_na := v_na + 1; END IF;
            ELSE
                INSERT INTO contabilidad.cuentas_config (ambito, ambito_id, concepto, cuenta_id, no_aplica)
                VALUES (p_ambito, p_ambito_id, v_par.concepto, NULL, true);
                v_na := v_na + 1;
            END IF;

        ELSE
            -- Existe o no existe, en dos pasos: el índice único es PARCIAL
            -- —GLOBAL lleva el ambito_id en nulo y los demás no—, y un
            -- ON CONFLICT no sabe a cuál de los dos agarrarse.
            IF EXISTS (SELECT 1 FROM contabilidad.cuentas_config
                        WHERE ambito = p_ambito AND ambito_id IS NOT DISTINCT FROM p_ambito_id
                          AND concepto = v_par.concepto) THEN
                UPDATE contabilidad.cuentas_config SET cuenta_id = v_cuenta, no_aplica = false
                 WHERE ambito = p_ambito AND ambito_id IS NOT DISTINCT FROM p_ambito_id
                   AND concepto = v_par.concepto
                   AND (cuenta_id IS DISTINCT FROM v_cuenta OR no_aplica);
                IF FOUND THEN v_puestas := v_puestas + 1; END IF;
            ELSE
                INSERT INTO contabilidad.cuentas_config (ambito, ambito_id, concepto, cuenta_id, no_aplica)
                VALUES (p_ambito, p_ambito_id, v_par.concepto, v_cuenta, false);
                v_puestas := v_puestas + 1;
            END IF;
        END IF;
    END LOOP;

    RETURN jsonb_build_object('success', true,
        'message', COALESCE(NULLIF(concat_ws(' · ',
                CASE WHEN v_puestas  > 0 THEN format('%s cuenta(s) guardada(s)', v_puestas) END,
                CASE WHEN v_na       > 0 THEN format('%s marcada(s) como «no aplica»', v_na) END,
                CASE WHEN v_quitadas > 0 THEN format('%s devuelta(s) a la heredada', v_quitadas) END),
            ''), 'Cuentas contables guardadas'),
        'data', (contabilidad.fn_cuentas_config_obtener(p_ambito, p_ambito_id))->'data');
END;
$function$
;

COMMIT;
