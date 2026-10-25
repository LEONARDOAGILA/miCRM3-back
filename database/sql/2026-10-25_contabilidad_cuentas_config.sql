-- ===========================================================================
-- LAS CUENTAS CONTABLES DE CADA COSA (contabilidad.cuentas_config)
-- ===========================================================================
-- Para asentar una factura hacen falta varias cuentas, y cada una se decide
-- mirando algo distinto:
--
--   · el PRODUCTO (por su categoría) dice el inventario, el ingreso, el costo
--     y las devoluciones y descuentos;
--   · el CLIENTE dirá la cuenta por cobrar y los anticipos;
--   · el IMPUESTO dirá el IVA y las retenciones;
--   · la FORMA DE PAGO dirá la caja o el banco.
--
-- Son la misma pregunta con distinto sujeto, así que van en UNA tabla con un
-- ámbito, en lugar de ir añadiendo columnas a categorías, a clientes y a
-- sucursales. Un concepto nuevo —mermas, notas de crédito— es una fila, no
-- una migración; y toda la configuración contable se ve y se audita junta.
--
-- EMPIEZA POR LAS CATEGORÍAS, que es lo que se ata ahora. Los demás ámbitos
-- ya están contemplados y no habrá que tocar la tabla para usarlos.
--
-- LAS CUENTAS SE HEREDAN. Lo normal es que todas las categorías de mercadería
-- usen las mismas cuentas, así que se configuran una vez en el ámbito GLOBAL
-- y cada categoría sólo guarda lo que tenga DISTINTO. El orden de búsqueda es
-- producto → su categoría → las categorías de arriba → global, y lo resuelve
-- fn_cuenta_de para que la factura no tenga que saberlo.
\set ON_ERROR_STOP on

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. LA CUENTA QUE FALTABA EN EL PLAN
-- ---------------------------------------------------------------------------
-- «Devoluciones en compras» es una de las que hay que configurar y no estaba.
-- Va donde le toca: resta de las compras, así que es de COSTO y acreedora,
-- igual que el descuento en compras que tiene al lado.
INSERT INTO contabilidad.plan_cuentas
    (padre_id, orden, nivel, codigo, nombre, descripcion, tipo, naturaleza, es_movimiento, activo, created_by, updated_by)
SELECT p.id,
       (SELECT COALESCE(MAX(orden), 0) + 1 FROM contabilidad.plan_cuentas WHERE padre_id = p.id),
       p.nivel + 1,
       '5.2.05',
       '(-) Devoluciones en compras',
       'Lo que se devuelve al proveedor; resta de las compras, así que es acreedora',
       p.tipo, 'ACREEDORA', true, true, 'cuentas-config', 'cuentas-config'
  FROM contabilidad.plan_cuentas p
 WHERE p.codigo = '5.2'
   AND NOT EXISTS (SELECT 1 FROM contabilidad.plan_cuentas WHERE codigo = '5.2.05');

-- ---------------------------------------------------------------------------
-- 2. LOS CONCEPTOS
-- ---------------------------------------------------------------------------
-- Qué cuentas se le piden a cada cosa. Son datos y no código: añadir
-- «mermas» o «notas de crédito» es insertar una fila.
--
-- `tipos_permitidos` es lo que impide el error que descuadra un balance:
-- apuntar el ingreso a una cuenta de gasto. La validación la hace el
-- disparador de cuentas_config con esta lista.
CREATE TABLE IF NOT EXISTS contabilidad.conceptos_contables (
    codigo           varchar(40)  PRIMARY KEY,
    nombre           varchar(120) NOT NULL,
    descripcion      text,
    /* Dónde se configura: por ahora todos son de producto (CATEGORIA) */
    ambito_natural   varchar(20)  NOT NULL DEFAULT 'CATEGORIA',
    tipos_permitidos varchar(15)[] NOT NULL,
    naturaleza_tipica varchar(10),
    orden            integer      NOT NULL DEFAULT 1,
    activo           boolean      NOT NULL DEFAULT true,

    created_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    created_by varchar(100),
    updated_by varchar(100),

    CONSTRAINT ck_conceptos_ambito CHECK (ambito_natural IN ('CATEGORIA','PRODUCTO','GRUPO_CLIENTE','CLIENTE','SUCURSAL','IMPUESTO','FORMA_PAGO','GLOBAL'))
);

COMMENT ON TABLE contabilidad.conceptos_contables IS 'Qué cuentas se le piden a cada cosa (inventario, ingreso, costo…) y de qué tipo pueden ser';

INSERT INTO contabilidad.conceptos_contables
    (codigo, nombre, descripcion, ambito_natural, tipos_permitidos, naturaleza_tipica, orden, created_by, updated_by)
VALUES
    ('INVENTARIO', 'Cta. Inventario',
     'Dónde entra y de dónde sale la mercadería de esta categoría',
     'CATEGORIA', ARRAY['ACTIVO']::varchar[], 'DEUDORA', 1, 'cuentas-config', 'cuentas-config'),
    ('INGRESO', 'Cta. Ingreso',
     'La venta: se abona al facturar',
     'CATEGORIA', ARRAY['INGRESO']::varchar[], 'ACREEDORA', 2, 'cuentas-config', 'cuentas-config'),
    ('COSTO', 'Cta. Costo',
     'El costo de lo vendido: se carga al facturar, contra el inventario',
     'CATEGORIA', ARRAY['COSTO','GASTO']::varchar[], 'DEUDORA', 3, 'cuentas-config', 'cuentas-config'),
    ('DEV_COMPRA', 'Cuenta Dev. Compras',
     'Lo que se le devuelve al proveedor; resta de las compras',
     'CATEGORIA', ARRAY['COSTO','GASTO']::varchar[], 'ACREEDORA', 4, 'cuentas-config', 'cuentas-config'),
    ('DEV_VENTA', 'Cuenta Dev. Ventas',
     'Lo que devuelve el cliente y vuelve a poder venderse; resta de las ventas',
     'CATEGORIA', ARRAY['INGRESO']::varchar[], 'DEUDORA', 5, 'cuentas-config', 'cuentas-config'),
    ('DEV_VENTA_MAL_ESTADO', 'Cuenta Dev. Ventas mal estado',
     'Lo que devuelve el cliente y YA NO se puede vender: no vuelve al inventario vendible, así que suele ir a una cuenta aparte',
     'CATEGORIA', ARRAY['INGRESO','GASTO','COSTO']::varchar[], NULL, 6, 'cuentas-config', 'cuentas-config'),
    ('DESCUENTO_VENTA', 'Descuento en ventas',
     'El descuento concedido al cliente; resta de las ventas',
     'CATEGORIA', ARRAY['INGRESO']::varchar[], 'DEUDORA', 7, 'cuentas-config', 'cuentas-config'),
    ('DEV_COMPRA_MAL_ESTADO', 'Cuenta Dev. Compras mal estado',
     'Lo que se le devuelve al proveedor por venir dañado',
     'CATEGORIA', ARRAY['COSTO','GASTO']::varchar[], NULL, 8, 'cuentas-config', 'cuentas-config')
ON CONFLICT (codigo) DO NOTHING;

-- ---------------------------------------------------------------------------
-- 3. LA CONFIGURACIÓN
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS contabilidad.cuentas_config (
    id         bigserial   PRIMARY KEY,
    /* Qué decide esta cuenta: una categoría, un cliente, una sucursal… */
    ambito     varchar(20) NOT NULL,
    /* El id dentro de ese ámbito. NULL en GLOBAL, que es el valor por omisión */
    ambito_id  bigint,
    concepto   varchar(40) NOT NULL REFERENCES contabilidad.conceptos_contables(codigo),
    /* SIEMPRE el id, nunca el código: el código cambia al mover la cuenta de
       rama. Va en nulo cuando la fila dice «no aplica». */
    cuenta_id  bigint      REFERENCES contabilidad.plan_cuentas(id),
    /* «Aquí este concepto no existe»: un servicio no mueve inventario. Corta
       la herencia, así que tampoco se busca la cuenta más arriba. */
    no_aplica  boolean     NOT NULL DEFAULT false,

    created_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    created_by varchar(100),
    updated_by varchar(100),

    CONSTRAINT ck_cuentas_config_ambito CHECK (ambito IN ('CATEGORIA','PRODUCTO','GRUPO_CLIENTE','CLIENTE','SUCURSAL','IMPUESTO','FORMA_PAGO','GLOBAL')),
    CONSTRAINT ck_cuentas_config_global CHECK ((ambito = 'GLOBAL') = (ambito_id IS NULL)),
    /* O dice una cuenta, o dice que no aplica; las dos cosas a la vez, no */
    CONSTRAINT ck_cuentas_config_cuenta CHECK ((no_aplica AND cuenta_id IS NULL)
                                            OR (NOT no_aplica AND cuenta_id IS NOT NULL))
);

-- Para las bases donde la tabla ya existía sin «no aplica»
ALTER TABLE contabilidad.cuentas_config ADD COLUMN IF NOT EXISTS no_aplica boolean NOT NULL DEFAULT false;
ALTER TABLE contabilidad.cuentas_config ALTER COLUMN cuenta_id DROP NOT NULL;
ALTER TABLE contabilidad.cuentas_config DROP CONSTRAINT IF EXISTS ck_cuentas_config_cuenta;
ALTER TABLE contabilidad.cuentas_config ADD CONSTRAINT ck_cuentas_config_cuenta
    CHECK ((no_aplica AND cuenta_id IS NULL) OR (NOT no_aplica AND cuenta_id IS NOT NULL));

COMMENT ON TABLE contabilidad.cuentas_config IS 'Qué cuenta usa cada categoría / cliente / impuesto… para cada concepto. GLOBAL es el valor por omisión';

-- Una cuenta por concepto y por cosa. En GLOBAL el ambito_id es NULL, y un
-- índice único normal no lo vería repetido: por eso van dos.
CREATE UNIQUE INDEX IF NOT EXISTS uq_cuentas_config
    ON contabilidad.cuentas_config (ambito, ambito_id, concepto) WHERE ambito_id IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS uq_cuentas_config_global
    ON contabilidad.cuentas_config (ambito, concepto) WHERE ambito_id IS NULL;
CREATE INDEX IF NOT EXISTS ix_cuentas_config_cuenta ON contabilidad.cuentas_config (cuenta_id);

DROP TRIGGER IF EXISTS trigger_cuentas_config_set_users  ON contabilidad.cuentas_config;
DROP TRIGGER IF EXISTS trigger_cuentas_config_updated_at ON contabilidad.cuentas_config;
DROP TRIGGER IF EXISTS trg_cuentas_config_audit          ON contabilidad.cuentas_config;

CREATE TRIGGER trigger_cuentas_config_set_users
    BEFORE INSERT OR UPDATE ON contabilidad.cuentas_config
    FOR EACH ROW EXECUTE FUNCTION auditoria.fn_set_audit_users();
CREATE TRIGGER trigger_cuentas_config_updated_at
    BEFORE UPDATE ON contabilidad.cuentas_config
    FOR EACH ROW EXECUTE FUNCTION auditoria.fn_update_updated_at_column();
CREATE TRIGGER trg_cuentas_config_audit
    AFTER INSERT OR UPDATE OR DELETE ON contabilidad.cuentas_config
    FOR EACH ROW EXECUTE FUNCTION auditoria.fn_auditar_cambios();

-- ---------------------------------------------------------------------------
-- 4. LO QUE NO SE DEJA GUARDAR
-- ---------------------------------------------------------------------------
-- Tres comprobaciones que son las que evitan el asiento descuadrado, y que
-- van en la base y no en la pantalla: la cuenta tiene que existir vigente,
-- ser DE MOVIMIENTO —las de grupo no reciben asientos— y ser DEL TIPO que
-- admite el concepto.
CREATE OR REPLACE FUNCTION contabilidad.fn_cuentas_config_validar()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_c      record;
    v_tipos  varchar[];
    v_nombre varchar;
BEGIN
    -- «No aplica»: no hay cuenta, así que no hay nada que comprobar. El CHECK
    -- de la tabla ya garantiza que entonces no_aplica está puesto.
    IF NEW.cuenta_id IS NULL THEN
        RETURN NEW;
    END IF;

    SELECT codigo, nombre, tipo, es_movimiento, activo, deleted_at INTO v_c
      FROM contabilidad.plan_cuentas WHERE id = NEW.cuenta_id;

    IF v_c.deleted_at IS NOT NULL THEN
        RAISE EXCEPTION 'La cuenta «% %» está en la papelera', v_c.codigo, v_c.nombre USING ERRCODE = 'P0013';
    END IF;
    IF NOT v_c.activo THEN
        RAISE EXCEPTION 'La cuenta «% %» está inactiva', v_c.codigo, v_c.nombre USING ERRCODE = 'P0021';
    END IF;
    IF NOT v_c.es_movimiento THEN
        RAISE EXCEPTION 'La cuenta «% %» es de grupo: agrupa y no recibe asientos. Elija una de las que cuelgan de ella.',
              v_c.codigo, v_c.nombre USING ERRCODE = 'P0021';
    END IF;

    SELECT tipos_permitidos, nombre INTO v_tipos, v_nombre
      FROM contabilidad.conceptos_contables WHERE codigo = NEW.concepto;
    IF NOT (v_c.tipo = ANY(v_tipos)) THEN
        RAISE EXCEPTION '«%» tiene que ser una cuenta de tipo %, y «% %» es de tipo %',
              v_nombre, array_to_string(v_tipos, ' o '), v_c.codigo, v_c.nombre, v_c.tipo
            USING ERRCODE = 'P0022';
    END IF;

    RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_cuentas_config_validar ON contabilidad.cuentas_config;
CREATE TRIGGER trg_cuentas_config_validar
    BEFORE INSERT OR UPDATE ON contabilidad.cuentas_config
    FOR EACH ROW EXECUTE FUNCTION contabilidad.fn_cuentas_config_validar();

-- ---------------------------------------------------------------------------
-- 5. LOS CONCEPTOS, PARA LA PANTALLA
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION contabilidad.fn_conceptos_contables_listar(p_ambito varchar DEFAULT NULL::varchar)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
AS $function$
    SELECT jsonb_build_object('success', true, 'data', COALESCE(jsonb_agg(
               jsonb_build_object(
                   'codigo',            c.codigo,
                   'nombre',            c.nombre,
                   'descripcion',       c.descripcion,
                   'ambito_natural',    c.ambito_natural,
                   'tipos_permitidos',  to_jsonb(c.tipos_permitidos),
                   'naturaleza_tipica', c.naturaleza_tipica,
                   'orden',             c.orden
               ) ORDER BY c.orden, c.codigo), '[]'::jsonb))
      FROM contabilidad.conceptos_contables c
     WHERE c.activo
       AND (p_ambito IS NULL OR c.ambito_natural = p_ambito);
$function$;

-- ---------------------------------------------------------------------------
-- 6. EL RESOLUTOR: qué cuenta usa esto, y de dónde sale
-- ---------------------------------------------------------------------------
-- Devuelve la cuenta Y DE DÓNDE VIENE, que es lo que hace entendible la
-- pantalla: «1.1.03.01, heredada de la categoría Línea Blanca».
--
-- El orden es: lo propio, luego lo de arriba en el árbol de categorías, y al
-- final el global. La primera que aparece gana.
CREATE OR REPLACE FUNCTION contabilidad.fn_cuenta_de_detalle(
    p_concepto varchar,
    p_ambito varchar DEFAULT 'GLOBAL'::varchar,
    p_ambito_id bigint DEFAULT NULL::bigint)
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
$function$;

-- Lo que heredaría una categoría SI SE LE QUITARA lo suyo: se resuelve desde
-- la de arriba, saltándose ésta. Es lo que la ficha enseña debajo del campo
-- —«si la vacías, se usará ésta»—, y sin ello enseñaría como heredada justo
-- la cuenta que se acaba de quitar.
CREATE OR REPLACE FUNCTION contabilidad.fn_cuenta_heredada_detalle(p_concepto varchar, p_categoria_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'contabilidad'
AS $function$
DECLARE
    v_padre bigint;
    v       jsonb;
BEGIN
    SELECT padre_id INTO v_padre FROM inventarios.categorias WHERE id = p_categoria_id;
    IF v_padre IS NULL THEN
        RETURN contabilidad.fn_cuenta_de_detalle(p_concepto, 'GLOBAL', NULL);
    END IF;

    v := contabilidad.fn_cuenta_de_detalle(p_concepto, 'CATEGORIA', v_padre);

    -- Lo que para la de arriba es «propia», para ésta es heredada. Y si lo
    -- de arriba es un «no aplica», no se hereda una cuenta: se hereda que
    -- aquí no hay nada que asentar.
    IF v->>'origen' = 'CATEGORIA' THEN
        v := jsonb_set(v, '{origen_etiqueta}',
                       to_jsonb(CASE WHEN (v->>'no_aplica')::boolean THEN 'desde ' ELSE 'Heredada de ' END ||
                                (SELECT nombre FROM inventarios.categorias WHERE id = (v->>'origen_id')::bigint)));
    END IF;
    RETURN v;
END;
$function$;

-- La misma, para quien sólo quiere el id (el asiento)
CREATE OR REPLACE FUNCTION contabilidad.fn_cuenta_de(
    p_concepto varchar,
    p_ambito varchar DEFAULT 'GLOBAL'::varchar,
    p_ambito_id bigint DEFAULT NULL::bigint)
 RETURNS bigint
 LANGUAGE sql
 STABLE SECURITY DEFINER
AS $function$
    SELECT ((contabilidad.fn_cuenta_de_detalle(p_concepto, p_ambito, p_ambito_id))->>'cuenta_id')::bigint;
$function$;

-- ---------------------------------------------------------------------------
-- 7. LA FICHA: los conceptos de una cosa, con lo propio y lo heredado
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION contabilidad.fn_cuentas_config_obtener(
    p_ambito varchar,
    p_ambito_id bigint DEFAULT NULL::bigint)
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
                   'heredada', CASE WHEN p_ambito = 'CATEGORIA'
                       THEN contabilidad.fn_cuenta_heredada_detalle(c.codigo, p_ambito_id) END
               ) AS fila
          FROM contabilidad.conceptos_contables c
         WHERE c.activo
           AND (p_ambito = 'GLOBAL' OR c.ambito_natural = p_ambito)
      ) x;

    -- De qué se están configurando las cuentas, para el título de la ficha
    v_donde := CASE
        WHEN p_ambito = 'GLOBAL' THEN jsonb_build_object('etiqueta', 'Todas las categorías (por omisión)')
        WHEN p_ambito = 'CATEGORIA' THEN
            (SELECT jsonb_build_object('etiqueta', c.nombre, 'ruta', c.nombre,
                                       'es_transaccion', c.es_transaccion, 'nivel', c.nivel)
               FROM inventarios.categorias c WHERE c.id = p_ambito_id)
        ELSE jsonb_build_object('etiqueta', p_ambito || ' ' || COALESCE(p_ambito_id::text, ''))
    END;

    RETURN jsonb_build_object('success', true, 'message', 'Configuración contable',
                              'data', jsonb_build_object('ambito', p_ambito, 'ambito_id', p_ambito_id,
                                                         'donde', v_donde, 'conceptos', v_data));
END;
$function$;

-- ---------------------------------------------------------------------------
-- 8. GUARDAR
-- ---------------------------------------------------------------------------
-- p_cuentas es {"INGRESO": 123, "COSTO": null, "INVENTARIO": "NO_APLICA"}:
--
--   · un id        → ésa es la cuenta;
--   · null         → QUITAR lo propio y volver a heredar;
--   · "NO_APLICA"  → aquí este concepto no existe, y no se hereda nada.
--
-- Lo que no venga en el objeto no se toca, así que la pantalla puede mandar
-- sólo lo que cambió.
CREATE OR REPLACE FUNCTION contabilidad.fn_cuentas_config_guardar(
    p_ambito varchar,
    p_ambito_id bigint,
    p_cuentas jsonb,
    p_usuario_id bigint DEFAULT NULL::bigint,
    p_usuario_login character varying DEFAULT NULL::character varying,
    p_usuario_nombre character varying DEFAULT NULL::character varying,
    p_ip_address inet DEFAULT NULL::inet,
    p_user_agent text DEFAULT NULL::text,
    p_request_id uuid DEFAULT NULL::uuid)
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

    IF p_ambito NOT IN ('CATEGORIA','PRODUCTO','GRUPO_CLIENTE','CLIENTE','SUCURSAL','IMPUESTO','FORMA_PAGO','GLOBAL') THEN
        RAISE EXCEPTION 'Ámbito no válido: %', p_ambito USING ERRCODE = 'P0001';
    END IF;
    IF (p_ambito = 'GLOBAL') <> (p_ambito_id IS NULL) THEN
        RAISE EXCEPTION 'El ámbito GLOBAL no lleva id, y los demás lo necesitan' USING ERRCODE = 'P0001';
    END IF;
    IF p_ambito = 'CATEGORIA'
       AND NOT EXISTS (SELECT 1 FROM inventarios.categorias WHERE id = p_ambito_id AND deleted_at IS NULL) THEN
        RAISE EXCEPTION 'La categoría no existe' USING ERRCODE = 'P0016';
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
$function$;

-- ---------------------------------------------------------------------------
-- 9. EL LISTADO: el árbol de categorías con sus cuentas
-- ---------------------------------------------------------------------------
-- El mismo árbol que la pantalla de categorías —en el orden en que se dibuja
-- y con su `nivel`— y, en cada fila, la cuenta EFECTIVA de cada concepto con
-- su origen. Así se ve de un vistazo qué está configurado, qué se hereda y
-- qué falta.
CREATE OR REPLACE FUNCTION contabilidad.fn_cuentas_config_categorias(p_solo_transaccion boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'contabilidad'
AS $function$
DECLARE
    v_data jsonb;
BEGIN
    WITH RECURSIVE arbol AS (
        SELECT c.id, c.padre_id, c.orden, c.nivel, c.nombre, c.activo, c.es_transaccion,
               LPAD(c.orden::text, 5, '0') AS ruta_orden
          FROM inventarios.categorias c
         WHERE c.padre_id IS NULL AND c.deleted_at IS NULL
        UNION ALL
        SELECT h.id, h.padre_id, h.orden, h.nivel, h.nombre, h.activo, h.es_transaccion,
               a.ruta_orden || '.' || LPAD(h.orden::text, 5, '0')
          FROM inventarios.categorias h
          JOIN arbol a ON h.padre_id = a.id
         WHERE h.deleted_at IS NULL
    )
    SELECT COALESCE(jsonb_agg(
               jsonb_build_object(
                   'id',             a.id,
                   'padre_id',       a.padre_id,
                   'orden',          a.orden,
                   'nivel',          a.nivel,
                   'nombre',         a.nombre,
                   'activo',         a.activo,
                   'es_transaccion', a.es_transaccion,
                   'num_hijos',      (SELECT COUNT(*) FROM inventarios.categorias h
                                       WHERE h.padre_id = a.id AND h.deleted_at IS NULL),
                   'num_productos',  (SELECT COUNT(*) FROM inventarios.productos p
                                       WHERE p.categoria_id = a.id AND p.deleted_at IS NULL),
                   -- Cuántas cuentas tiene puestas ella misma
                   'propias',        (SELECT COUNT(*) FROM contabilidad.cuentas_config cc
                                       WHERE cc.ambito = 'CATEGORIA' AND cc.ambito_id = a.id),
                   -- Y la que se usa de verdad para cada concepto
                   'cuentas',        (SELECT jsonb_object_agg(c.codigo,
                                                contabilidad.fn_cuenta_de_detalle(c.codigo, 'CATEGORIA', a.id))
                                        FROM contabilidad.conceptos_contables c
                                       WHERE c.activo AND c.ambito_natural = 'CATEGORIA')
               ) ORDER BY a.ruta_orden), '[]'::jsonb)
      INTO v_data
      FROM arbol a
     WHERE NOT p_solo_transaccion OR a.es_transaccion;

    RETURN jsonb_build_object('success', true, 'data', v_data);

EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false, 'message', 'Error al listar las cuentas por categoría: ' || SQLERRM,
                              'error_code', SQLSTATE);
END;
$function$;

-- ---------------------------------------------------------------------------
-- 10. LAS CUENTAS POR OMISIÓN
-- ---------------------------------------------------------------------------
-- Lo normal es que toda la mercadería use las mismas, así que se dejan aquí
-- una vez y cada categoría sólo guarda lo que tenga distinto. Sólo se ponen
-- si no hay nada configurado: esto no pisa lo que ya esté puesto.
INSERT INTO contabilidad.cuentas_config (ambito, ambito_id, concepto, cuenta_id, created_by, updated_by)
SELECT 'GLOBAL', NULL, x.concepto, p.id, 'cuentas-config', 'cuentas-config'
  FROM (VALUES
        ('INVENTARIO',      '1.1.03.01'),
        ('INGRESO',         '4.1.01'),
        ('COSTO',           '5.1.01'),
        ('DEV_COMPRA',      '5.2.05'),
        ('DEV_VENTA',       '4.1.04'),
        ('DESCUENTO_VENTA', '4.1.03')
       ) AS x(concepto, codigo)
  JOIN contabilidad.plan_cuentas p ON p.codigo = x.codigo AND p.deleted_at IS NULL
 WHERE NOT EXISTS (SELECT 1 FROM contabilidad.cuentas_config cc
                    WHERE cc.ambito = 'GLOBAL' AND cc.concepto = x.concepto);

COMMIT;
