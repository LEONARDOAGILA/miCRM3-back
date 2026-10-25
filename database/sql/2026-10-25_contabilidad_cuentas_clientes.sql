-- ===========================================================================
-- LAS CUENTAS CONTABLES POR GRUPO DE CLIENTES
-- ===========================================================================
-- Lo mismo que las cuentas por categoría de producto, pero del lado del
-- cliente y sobre el árbol de ventas.grupos_clientes:
--
--     cliente → su grupo → los grupos de arriba → GLOBAL
--
-- La cuenta por cobrar se pone una vez en «Relacionados» y la usan todos los
-- que cuelguen de ahí; el resto de clientes sigue con la de por omisión.
--
-- Nada de esto cambia lo que ya hacían las categorías: la rama nueva se añade
-- al resolvedor, no sustituye a la que había.
\set ON_ERROR_STOP on

BEGIN;
-- ---------------------------------------------------------------------------
-- 1. LOS CONCEPTOS QUE SE CONFIGURAN POR GRUPO DE CLIENTES
-- ---------------------------------------------------------------------------
-- Los ocho de antes son de la categoría del producto (qué se vende); éstos
-- son del cliente (a quién se le vende y cómo se le cobra). Por eso llevan
-- `ambito_natural = 'GRUPO_CLIENTE'`: cada pantalla ofrece los suyos.
INSERT INTO contabilidad.conceptos_contables
    (codigo, nombre, descripcion, ambito_natural, tipos_permitidos, naturaleza_tipica, orden, created_by, updated_by)
VALUES
    ('CXC_CLIENTE', 'Cta. por cobrar',
     'Dónde queda la deuda al facturar a crédito. Los relacionados y las empresas del grupo suelen ir a una cuenta aparte',
     'GRUPO_CLIENTE', ARRAY['ACTIVO'], 'DEUDORA', 11, 'cuentas-config', 'cuentas-config'),

    ('ANTICIPO_CLIENTE', 'Anticipos de clientes',
     'Lo que el cliente paga antes de la factura: es una deuda con él hasta que se le entrega',
     'GRUPO_CLIENTE', ARRAY['PASIVO'], 'ACREEDORA', 12, 'cuentas-config', 'cuentas-config'),

    ('INTERES_MORA', 'Intereses por mora',
     'Lo que se le cobra por pagar tarde',
     'GRUPO_CLIENTE', ARRAY['INGRESO'], 'ACREEDORA', 13, 'cuentas-config', 'cuentas-config'),

    ('PROVISION_INCOBRABLE', 'Provisión de incobrables',
     'La parte de la cartera que se da por perdida',
     'GRUPO_CLIENTE', ARRAY['ACTIVO','GASTO'], 'ACREEDORA', 14, 'cuentas-config', 'cuentas-config')
ON CONFLICT (codigo) DO NOTHING;
-- ---------------------------------------------------------------------------
-- 2. RESOLVER: DE DÓNDE SALE LA CUENTA
-- ---------------------------------------------------------------------------
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

-- ---------------------------------------------------------------------------
-- 3. LA QUE QUEDARÍA SI SE QUITARA LA PROPIA
-- ---------------------------------------------------------------------------
-- La de dos parámetros sigue siendo la de categorías. Ésta, de tres, vale
-- para las dos pantallas: sin ella, al vaciar un campo la ficha enseñaría
-- como «heredada» justo la cuenta que se acaba de quitar.
CREATE OR REPLACE FUNCTION contabilidad.fn_cuenta_heredada_detalle(
    p_concepto character varying,
    p_ambito   character varying,
    p_ambito_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'contabilidad'
AS $function$
DECLARE
    v_padre bigint;
    v       jsonb;
BEGIN
    IF p_ambito = 'CATEGORIA' THEN
        RETURN contabilidad.fn_cuenta_heredada_detalle(p_concepto, p_ambito_id);
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
$function$;
-- ---------------------------------------------------------------------------
-- 4. LA FICHA DE UN GRUPO (y la de una categoría, que no cambia)
-- ---------------------------------------------------------------------------
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
                   'heredada', CASE WHEN p_ambito IN ('CATEGORIA', 'GRUPO_CLIENTE')
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
        ELSE jsonb_build_object('etiqueta', p_ambito || ' ' || COALESCE(p_ambito_id::text, ''))
    END;

    RETURN jsonb_build_object('success', true, 'message', 'Configuración contable',
                              'data', jsonb_build_object('ambito', p_ambito, 'ambito_id', p_ambito_id,
                                                         'donde', v_donde, 'conceptos', v_data));
END;
$function$
;

-- ---------------------------------------------------------------------------
-- 5. EL ÁRBOL DE GRUPOS CON SUS CUENTAS (lo que pinta la rejilla)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION contabilidad.fn_cuentas_config_grupos(p_solo_activos boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'contabilidad'
AS $function$
DECLARE
    v_data jsonb;
BEGIN
    WITH RECURSIVE arbol AS (
        SELECT c.id, c.padre_id, c.orden, c.nivel, c.nombre, c.activo,
               LPAD(c.orden::text, 5, '0') AS ruta_orden
          FROM ventas.grupos_clientes c
         WHERE c.padre_id IS NULL AND c.deleted_at IS NULL
        UNION ALL
        SELECT h.id, h.padre_id, h.orden, h.nivel, h.nombre, h.activo,
               a.ruta_orden || '.' || LPAD(h.orden::text, 5, '0')
          FROM ventas.grupos_clientes h
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
                   'num_hijos',      (SELECT COUNT(*) FROM ventas.grupos_clientes h
                                       WHERE h.padre_id = a.id AND h.deleted_at IS NULL),
                   'num_clientes',   (SELECT COUNT(*) FROM ventas.clientes c
                                       WHERE c.grupo_cliente_id = a.id AND c.deleted_at IS NULL),
                   -- Cuántas cuentas tiene puestas ella misma
                   'propias',        (SELECT COUNT(*) FROM contabilidad.cuentas_config cc
                                       WHERE cc.ambito = 'GRUPO_CLIENTE' AND cc.ambito_id = a.id),
                   -- Y la que se usa de verdad para cada concepto
                   'cuentas',        (SELECT jsonb_object_agg(c.codigo,
                                                contabilidad.fn_cuenta_de_detalle(c.codigo, 'GRUPO_CLIENTE', a.id))
                                        FROM contabilidad.conceptos_contables c
                                       WHERE c.activo AND c.ambito_natural = 'GRUPO_CLIENTE')
               ) ORDER BY a.ruta_orden), '[]'::jsonb)
      INTO v_data
      FROM arbol a
     WHERE NOT p_solo_activos OR a.activo;

    RETURN jsonb_build_object('success', true, 'data', v_data);

EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false, 'message', 'Error al listar las cuentas por grupo de clientes: ' || SQLERRM,
                              'error_code', SQLSTATE);
END;
$function$
;

-- ---------------------------------------------------------------------------
-- 6. GUARDAR
-- ---------------------------------------------------------------------------
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
    IF p_ambito = 'GRUPO_CLIENTE'
       AND NOT EXISTS (SELECT 1 FROM ventas.grupos_clientes WHERE id = p_ambito_id AND deleted_at IS NULL) THEN
        RAISE EXCEPTION 'El grupo de clientes no existe' USING ERRCODE = 'P0016';
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

-- ---------------------------------------------------------------------------
-- 7. LO QUE VALE PARA TODOS, Y UN CASO PROPIO
-- ---------------------------------------------------------------------------
-- El GLOBAL es el que usa cualquier cliente del que nadie haya dicho nada.
-- «Relacionados» lleva su propia cuenta por cobrar porque la plantilla ya la
-- trae separada (1.1.02.01.02 Clientes relacionados): es justo el caso que
-- explica para qué sirve esta pantalla.
INSERT INTO contabilidad.cuentas_config (ambito, ambito_id, concepto, cuenta_id, no_aplica, created_by, updated_by)
SELECT 'GLOBAL', NULL, x.concepto, p.id, false, 'cuentas-config', 'cuentas-config'
  FROM (VALUES
        ('CXC_CLIENTE',          '1.1.02.01.01'),
        ('ANTICIPO_CLIENTE',     '2.1.04.01'),
        ('INTERES_MORA',         '4.2.01'),
        ('PROVISION_INCOBRABLE', '1.1.02.03')
  ) AS x(concepto, codigo)
  JOIN contabilidad.plan_cuentas p ON p.codigo = x.codigo AND p.deleted_at IS NULL
 WHERE NOT EXISTS (SELECT 1 FROM contabilidad.cuentas_config cc
                    WHERE cc.ambito = 'GLOBAL' AND cc.concepto = x.concepto);

INSERT INTO contabilidad.cuentas_config (ambito, ambito_id, concepto, cuenta_id, no_aplica, created_by, updated_by)
SELECT 'GRUPO_CLIENTE', g.id, 'CXC_CLIENTE', p.id, false, 'cuentas-config', 'cuentas-config'
  FROM ventas.grupos_clientes g
  JOIN contabilidad.plan_cuentas p ON p.codigo = '1.1.02.01.02' AND p.deleted_at IS NULL
 WHERE g.nombre = 'Relacionados' AND g.deleted_at IS NULL
   AND NOT EXISTS (SELECT 1 FROM contabilidad.cuentas_config cc
                    WHERE cc.ambito = 'GRUPO_CLIENTE' AND cc.ambito_id = g.id AND cc.concepto = 'CXC_CLIENTE');
COMMIT;
