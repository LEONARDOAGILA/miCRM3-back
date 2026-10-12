-- ===========================================================================
-- EL ASUNTO DE LAS CONVERSACIONES IMPORTADAS
-- ===========================================================================
-- Fecha: 2026-10-07
-- Se aplica después de 2026-10-07_ventas_gestiones_modo_importada.sql.
--
-- Al importar una conversación de WhatsApp el vendedor ya no elige el asunto:
-- siempre es el mismo, porque siempre es lo mismo —traer al historial lo que ya
-- se habló—. Preguntarlo sólo conseguía que cada importación acabara bajo un
-- asunto distinto («Cobranza», «Enviar cotización») y que después no hubiera
-- forma de contarlas ni de encontrarlas.
--
-- Se crea como un asunto más del catálogo porque la gestión EXIGE un asunto del
-- catálogo (fn_gestiones_crear lo comprueba): no vale un texto suelto.
--
-- VA ACTIVO, pero la pantalla lo deja fuera del menú de respuestas de WhatsApp:
-- ese menú es para elegir QUÉ MANDARLE al cliente, y esto no se le manda a
-- nadie. Inactivo no serviría: el catálogo que lee el front sólo devuelve los
-- activos, así que la pantalla no podría ni saber su id.
--
-- El orden 900 lo deja al final de cualquier lista ordenada por orden.
--
-- Idempotente: si ya existe no hace nada.
-- ===========================================================================

INSERT INTO ventas.gestiones_asuntos (tipo_id, nombre, orden, activo, created_by)
SELECT t.id, 'Importación de mensajes de WhatsApp', 900, true, 'SISTEMA'
  FROM ventas.gestiones_tipos t
 WHERE t.codigo = 'WHATSAPP'
   AND NOT EXISTS (
        SELECT 1
          FROM ventas.gestiones_asuntos a
         WHERE a.tipo_id = t.id
           AND lower(a.nombre) = lower('Importación de mensajes de WhatsApp')
   );


-- ---------------------------------------------------------------------------
-- COMPROBACIÓN
-- ---------------------------------------------------------------------------
SELECT a.id, a.nombre, a.activo, a.orden
  FROM ventas.gestiones_asuntos a
  JOIN ventas.gestiones_tipos t ON t.id = a.tipo_id
 WHERE t.codigo = 'WHATSAPP'
   AND lower(a.nombre) = lower('Importación de mensajes de WhatsApp');
