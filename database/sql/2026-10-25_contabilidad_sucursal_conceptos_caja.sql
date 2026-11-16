-- ===========================================================================
-- UNA SUCURSAL TAMBIEN CONFIGURA LAS CUENTAS DE SUS CAJAS
-- ===========================================================================
-- Los conceptos del ambito PUNTO_VENTA (la caja, las tarjetas, el banco,
-- los sobrantes...) tienen que poder ponerse TAMBIEN en la sucursal. Es lo
-- que hace util la cadena punto de venta -> sucursal -> todos: las tarjetas
-- son las mismas para toda la tienda y se ponen una vez.
--
-- Y es lo unico que puede ensenar la ficha de una caja NUEVA: como todavia
-- no tiene id, se le pregunta a su sucursal que heredaria.
\set ON_ERROR_STOP on

BEGIN;

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
                   'heredada', CASE WHEN p_ambito IN ('CATEGORIA', 'GRUPO_CLIENTE', 'PUNTO_VENTA', 'SUCURSAL')
                       THEN contabilidad.fn_cuenta_heredada_detalle(c.codigo, p_ambito, p_ambito_id) END
               ) AS fila
          FROM contabilidad.conceptos_contables c
         WHERE c.activo
           AND (p_ambito = 'GLOBAL'
             OR c.ambito_natural = p_ambito
             -- Una SUCURSAL configura tambien los conceptos de sus cajas: es
             -- lo que hace util la cadena (las tarjetas o el banco se ponen
             -- una vez por tienda y las heredan todos sus puntos de venta).
             -- Ademas es lo unico que puede ensenar la ficha de una caja
             -- NUEVA, que todavia no tiene id del que colgar nada.
             OR (p_ambito = 'SUCURSAL' AND c.ambito_natural = 'PUNTO_VENTA'))
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

COMMIT;
