-- ===========================================================================
-- CUÁNTOS ADJUNTOS TIENE CADA GESTIÓN (ventas.fn_gestiones_json)
-- ===========================================================================
-- Fecha: 2026-10-06
-- Se aplica después de 2026-10-06_ventas_archivos_gestiones.sql.
--
-- En el historial y en los pendientes hay que poder ver de un vistazo qué
-- gestiones llevan algo adjunto, y poder abrirlo sin entrar a modificar la
-- gestión. Para eso la fila necesita traer la cuenta: con un clip dibujado
-- siempre, el vendedor tiene que pulsar una por una para descubrir que no hay
-- nada, y eso es justo lo que no hace nadie.
--
-- Se toca UNA función y no las dos listas: tanto fn_gestiones_listar_paginado
-- (historial) como fn_gestiones_agenda_paginado (pendientes) arman cada fila
-- llamando a fn_gestiones_json, así que el campo sale en las dos.
--
-- Sólo se cuentan los activos: desactivar un adjunto lo esconde de la pantalla
-- pero deja el fichero, igual que en la pestaña de Archivos.
--
-- Es una subconsulta por fila, no un JOIN: fn_gestiones_json devuelve una sola
-- gestión y la llama el jsonb_agg de la lista, que ya está paginada a 10-50
-- filas. Con el índice por gestion_id que creó la migración anterior, cada
-- cuenta es una lectura del índice.
--
-- Idempotente: CREATE OR REPLACE con la MISMA firma (p_id bigint), así que
-- reemplaza en vez de crear una sobrecarga.
-- ===========================================================================

CREATE OR REPLACE FUNCTION ventas.fn_gestiones_json(p_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    v_data jsonb;
BEGIN
    SELECT jsonb_build_object(
        'id',                g.id,
        'cliente_id',        g.cliente_id,
        'cliente_nombre',    c.nombre_completo,
        -- A quién le toca. usuario_* es lo vigente; empleado_* se queda por
        -- las gestiones anteriores al cambio de modelo, para que su
        -- RESPONSABLE se siga pudiendo leer. La pantalla usa responsable_nombre,
        -- que sirve para las de antes y las de ahora.
        'usuario_id',        g.usuario_id,
        'usuario_nombre',    ventas.fn_nombre_usuario(g.usuario_id),
        'empleado_id',       g.empleado_id,
        'empleado_nombre',   (SELECT TRIM(COALESCE(e.nombres, '') || ' ' || COALESCE(e.apellidos, ''))
                                FROM rh.empleados e WHERE e.id = g.empleado_id),
        'responsable_nombre', COALESCE(ventas.fn_nombre_usuario(g.usuario_id),
                                       (SELECT TRIM(COALESCE(e.nombres, '') || ' ' || COALESCE(e.apellidos, ''))
                                          FROM rh.empleados e WHERE e.id = g.empleado_id)),
        'contacto_id',       g.contacto_id,
        'contacto_nombre',   (SELECT cc.nombres FROM ventas.contactos_clientes cc WHERE cc.id = g.contacto_id),
        'tipo',              g.tipo,
        'estado',            g.estado,
        'prioridad',         g.prioridad,
        'asunto',            g.asunto,
        -- Para agrupar en informes; el texto de arriba es el que se vio ese día
        'asunto_id',         g.asunto_id,
        'nota',              g.nota,
        'telefono',          g.telefono,
        'fecha_programada',  to_char(g.fecha_programada, 'YYYY-MM-DD HH24:MI'),
        'fecha_realizada',   to_char(g.fecha_realizada,  'YYYY-MM-DD HH24:MI'),
        'duracion_minutos',  g.duracion_minutos,
        'resultado',         g.resultado,
        -- Cómo nació: AHORA, YA_HECHA o PROGRAMADA (NULL en lo anterior)
        'modo_registro',     g.modo_registro,
        'gestion_origen_id', g.gestion_origen_id,
        -- Pendiente cuya hora ya pasó: la pantalla la pinta en rojo
        'vencida',           (g.estado = 'PENDIENTE' AND g.fecha_programada < CURRENT_TIMESTAMP),
        -- Lo que se le mandó al cliente en esta conversación. La pantalla pinta
        -- el clip sólo si pasa de cero, y el número al lado cuando hay varios.
        'num_adjuntos',      (SELECT COUNT(*)
                                FROM ventas.archivos_clientes a
                               WHERE a.gestion_id = g.id
                                 AND a.activo),
        'created_by',        g.created_by,
        'updated_by',        g.updated_by,
        'created_at',        to_char(g.created_at, 'YYYY-MM-DD HH24:MI:SS'),
        'updated_at',        to_char(g.updated_at, 'YYYY-MM-DD HH24:MI:SS')
    ) INTO v_data
    FROM ventas.gestiones g
    JOIN ventas.clientes c ON c.id = g.cliente_id
    WHERE g.id = p_id;

    RETURN v_data;
END;
$function$;


-- ---------------------------------------------------------------------------
-- COMPROBACIÓN
-- ---------------------------------------------------------------------------
-- SELECT ventas.fn_gestiones_json(id) -> 'num_adjuntos'
--   FROM ventas.gestiones ORDER BY id DESC LIMIT 5;
