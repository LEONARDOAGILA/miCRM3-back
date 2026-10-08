-- ===========================================================================
-- CONVERSACIONES IMPORTADAS (modo_registro = 'IMPORTADA')
-- ===========================================================================
-- Fecha: 2026-10-07
-- Se aplica después de 2026-10-06_ventas_gestiones_num_adjuntos.sql.
--
-- Una conversación de WhatsApp traída con «Importar» ya se guarda como una
-- gestión, y eso está bien: entra en el historial y cuenta en las estadísticas
-- como cualquier otra. Lo que falta es poder distinguirla, por dos motivos:
--
--   1. En la pestaña de WhatsApp hay que poder enseñar lo importado aparte de
--      lo que registra el servicio miCRM3-wa.
--   2. No se edita. Lo que hay ahí dentro es lo que dijo el cliente, copiado
--      de WhatsApp; dejar que alguien lo cambie convertiría el historial en
--      algo que ya no es prueba de nada.
--
-- El sitio para eso es modo_registro, que ya existe justamente para decir CÓMO
-- se registró la gestión:
--
--   'AHORA'       se registró mientras pasaba
--   'YA_HECHA'    se anotó después, a mano
--   'PROGRAMADA'  se dejó agendada
--   'IMPORTADA'   se trajo de un fichero                  <-- lo nuevo
--
-- Lo anterior a octubre de 2026 lo tiene en NULL y sigue valiendo: la
-- restricción deja pasar el nulo.
--
-- Idempotente: la restricción se tira y se vuelve a crear, y la función va con
-- CREATE OR REPLACE sobre la misma firma.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- 1. El modo nuevo
-- ---------------------------------------------------------------------------
ALTER TABLE ventas.gestiones DROP CONSTRAINT IF EXISTS ck_gestiones_modo_registro;

ALTER TABLE ventas.gestiones ADD CONSTRAINT ck_gestiones_modo_registro
    CHECK (modo_registro IS NULL
           OR modo_registro IN ('AHORA', 'YA_HECHA', 'PROGRAMADA', 'IMPORTADA'));


-- ---------------------------------------------------------------------------
-- 2. Las importadas de un cliente
-- ---------------------------------------------------------------------------
-- Función aparte y no un filtro más en fn_gestiones_listar_paginado: aquí no
-- hace falta paginar ni filtrar ni contar —son unas pocas por cliente y se
-- enseñan todas—, y meterle un parámetro más a la del historial obligaba a
-- tocar una función de cien líneas que ya funciona.
--
-- De la más nueva a la más vieja: la última conversación es la que se consulta.
CREATE OR REPLACE FUNCTION ventas.fn_gestiones_importadas(p_cliente_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    v_data jsonb;
BEGIN
    SELECT COALESCE(jsonb_agg(ventas.fn_gestiones_json(t.id) ORDER BY t.orden), '[]'::jsonb)
      INTO v_data
      FROM (
        SELECT g.id,
               ROW_NUMBER() OVER (ORDER BY COALESCE(g.fecha_realizada, g.created_at) DESC,
                                           g.id DESC) AS orden
          FROM ventas.gestiones g
         WHERE g.cliente_id    = p_cliente_id
           AND g.modo_registro = 'IMPORTADA'
      ) t;

    RETURN jsonb_build_object('success', true,
                              'message', 'Conversaciones importadas obtenidas exitosamente',
                              'data', v_data);
EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object('success', false,
                                  'message', 'Error al obtener las conversaciones importadas: ' || SQLERRM,
                                  'error_code', SQLSTATE);
END;
$function$;


-- ---------------------------------------------------------------------------
-- COMPROBACIÓN
-- ---------------------------------------------------------------------------
-- SELECT jsonb_array_length(ventas.fn_gestiones_importadas(1055) -> 'data');
