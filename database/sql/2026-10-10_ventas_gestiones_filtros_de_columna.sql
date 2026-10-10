-- ===========================================================================
-- LOS FILTROS DE COLUMNA DE ag-Grid, TAMBIÉN EN HISTORIAL Y PENDIENTES
-- ===========================================================================
-- Fecha: 2026-10-10
-- Se aplica después de 2026-10-10_ventas_clientes_filtros_de_columna.sql.
--
-- El mismo arreglo que ya tienen Ventas > Clientes y el Reparto de Clientes,
-- ahora en las dos rejillas de la ficha del cliente. Las dos piden sus filas
-- al servidor —el historial pagina de quince en quince y lo pendiente trae
-- como mucho cincuenta—, así que a ag-Grid sólo le llega un trozo y sus
-- filtros de cabecera buscaban dentro de ese trozo. Escribir «Llamada» y que
-- salgan dos de cincuenta y tres es peor que no tener filtro.
--
-- Ahora la cabecera sólo recoge lo que el usuario pidió y el filtrado se hace
-- aquí, sobre todas las gestiones del cliente. El modelo llega en p_filtros:
--
--     {"tipo":      {"op":"contains","valor":"llamada"},
--      "estado":    {"op":"equals","valor":"vencida"},
--      "duracion_minutos": {"op":"greaterThan","valor":10}}
--
-- La columna que no esté, no filtra.
--
-- SE FILTRA POR LO QUE SE VE, NO POR LO QUE SE GUARDA. En la rejilla pone
-- «Llamada», «VENCIDA» o «Pide cotización»; en la base dicen LLAMADA,
-- PENDIENTE y COTIZACION. Filtrando sólo por el código, escribir lo que se ve
-- no encontraría nada. Así que donde hay traducción se buscan las dos cosas,
-- igual que ya se hace con tipo_identificacion en el listado de clientes.
--
-- LAS DOS PESTAÑAS COMPARTEN ESTA FUNCIÓN —el mismo endpoint, distinto
-- estado—, así que la lista de columnas es la unión de las dos rejillas: lo
-- que sólo está en una (prioridad, teléfono) simplemente no se pide desde la
-- otra.
--
-- DE PASO SE DEJA DE REPETIR EL WHERE. La definición anterior lo tenía escrito
-- dos veces, una para la cuenta y otra para la página, y había que acordarse
-- de tocar las dos. Ahora salen del mismo CTE y no pueden discrepar.
--
-- SE REUSAN fn_filtro_texto y fn_filtro_numero, que ya existen. Los operadores
-- se llaman igual que en ag-Grid, no hay traducción por el camino.
--
-- NADA DE SQL DINÁMICO: las columnas filtrables están escritas una a una en el
-- WHERE. Y no se paga lo que no se usa, porque cada condición va detrás de
-- `p_filtros->'columna' IS NULL OR …`, que es constante en toda la consulta.
--
-- Cambia la firma —entra un parámetro duodécimo—, así que se suelta la función
-- antes: CREATE OR REPLACE con otros parámetros no reemplaza, crea una segunda
-- con el mismo nombre y las llamadas de once argumentos se quedarían
-- resolviendo a la vieja.
--
-- Idempotente.
-- ===========================================================================

DROP FUNCTION IF EXISTS ventas.fn_gestiones_listar_paginado(
    bigint, integer, integer, text, character varying, character varying,
    date, date, character varying, bigint, bigint);

CREATE OR REPLACE FUNCTION ventas.fn_gestiones_listar_paginado(
    p_cliente_id      bigint,
    p_page            integer,
    p_per_page        integer,
    p_search          text,
    p_tipo            character varying,
    p_estado          character varying,
    p_desde           date,
    p_hasta           date,
    p_resultado       character varying,
    p_responsable_id  bigint,
    p_usuario_id      bigint DEFAULT NULL::bigint,
    -- Los filtros de la cabecera de ag-Grid, columna por columna
    p_filtros         jsonb  DEFAULT '{}'::jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
    v_offset        integer;
    v_total         bigint;
    v_data          jsonb;
    v_filtro        text;
    v_registradores jsonb;
    v_gestiones     bigint[];
    v_whatsapp      bigint[];
BEGIN
    v_offset := (GREATEST(p_page, 1) - 1) * p_per_page;
    v_filtro := NULLIF(TRIM(COALESCE(p_search, '')), '');

    -- Una vez, no por fila. NULL = sin filtro (alcance TODO)
    v_gestiones := seguridad.fn_usuarios_visibles(p_usuario_id, 'GESTION');
    v_whatsapp  := seguridad.fn_usuarios_visibles(p_usuario_id, 'WHATSAPP');

    -- UNA sola sentencia: la cuenta y la página salen del mismo CTE, así no
    -- pueden discrepar.
    WITH base AS (
        SELECT g.*
          FROM ventas.gestiones g
         WHERE g.cliente_id = p_cliente_id
           AND (CASE WHEN g.modo_registro = 'IMPORTADA'
                     THEN (v_whatsapp  IS NULL OR g.usuario_id = ANY(v_whatsapp))
                     ELSE (v_gestiones IS NULL OR g.usuario_id = ANY(v_gestiones))
                END)
           AND (p_tipo           IS NULL OR g.tipo       = p_tipo)
           AND (p_estado         IS NULL OR g.estado     = p_estado)
           AND (p_resultado      IS NULL OR g.resultado  = p_resultado)
           AND (p_responsable_id IS NULL OR g.usuario_id = p_responsable_id)
           AND (p_desde  IS NULL OR COALESCE(g.fecha_realizada, g.fecha_programada) >= p_desde::timestamptz)
           AND (p_hasta  IS NULL OR COALESCE(g.fecha_realizada, g.fecha_programada) < (p_hasta + 1)::timestamptz)
           AND (v_filtro IS NULL
                OR ventas.fn_gestion_buscable(g.id) LIKE '%' || ventas.fn_sin_tildes(v_filtro) || '%')
    ),
    -- Los filtros de la cabecera, uno por columna y escritos a mano
    filtrados AS (
        SELECT t.* FROM base t
         WHERE (p_filtros->'id'               IS NULL OR ventas.fn_filtro_numero(t.id,               p_filtros->'id'))
           AND (p_filtros->'duracion_minutos' IS NULL OR ventas.fn_filtro_numero(t.duracion_minutos, p_filtros->'duracion_minutos'))

           -- A quién le toca. Lo mismo que calcula fn_gestiones_json: el
           -- usuario si lo hay, y si no el empleado de las gestiones viejas.
           AND (p_filtros->'responsable_nombre' IS NULL OR ventas.fn_filtro_texto(
                   COALESCE(ventas.fn_nombre_usuario(t.usuario_id),
                            (SELECT TRIM(COALESCE(e.nombres, '') || ' ' || COALESCE(e.apellidos, ''))
                               FROM rh.empleados e WHERE e.id = t.empleado_id)),
                   p_filtros->'responsable_nombre'))

           -- En la rejilla una PENDIENTE pone VENCIDA o PROGRAMADA según la
           -- hora, y lo demás REALIZADA. Se busca por el código y por lo que
           -- se ve, que son palabras distintas.
           AND (p_filtros->'estado' IS NULL OR ventas.fn_filtro_texto(
                   COALESCE(t.estado, '') || ' ' || CASE
                       WHEN t.estado = 'PENDIENTE' AND t.fecha_programada < CURRENT_TIMESTAMP THEN 'VENCIDA'
                       WHEN t.estado = 'PENDIENTE'                                            THEN 'PROGRAMADA'
                       WHEN t.estado = 'CANCELADA'                                            THEN 'CANCELADA'
                       ELSE 'REALIZADA'
                   END,
                   p_filtros->'estado'))

           -- El código y el nombre del catálogo: en la celda pone «Llamada»
           -- pero en la base dice LLAMADA, y el catálogo se puede editar.
           AND (p_filtros->'tipo' IS NULL OR ventas.fn_filtro_texto(
                   COALESCE(t.tipo, '') || ' ' ||
                   COALESCE((SELECT gt.nombre FROM ventas.gestiones_tipos gt WHERE gt.codigo = t.tipo), ''),
                   p_filtros->'tipo'))

           -- La columna «Cuándo» no es un campo: enseña la fecha realizada y,
           -- si no la hay, la programada. Se filtra sobre ese mismo texto, así
           -- «2026-10» busca el mes y «22:» la hora.
           AND (p_filtros->'cuando' IS NULL OR ventas.fn_filtro_texto(
                   to_char(COALESCE(t.fecha_realizada, t.fecha_programada), 'YYYY-MM-DD HH24:MI'),
                   p_filtros->'cuando'))

           AND (p_filtros->'fecha_programada' IS NULL OR ventas.fn_filtro_texto(
                   to_char(t.fecha_programada, 'YYYY-MM-DD HH24:MI'), p_filtros->'fecha_programada'))

           AND (p_filtros->'asunto' IS NULL OR ventas.fn_filtro_texto(t.asunto, p_filtros->'asunto'))

           -- Cómo terminó. Los nombres son los de RESULTADOS_GESTION en la
           -- pantalla: si allí se cambia una etiqueta, aquí también.
           AND (p_filtros->'resultado' IS NULL OR ventas.fn_filtro_texto(
                   COALESCE(t.resultado, '') || ' ' || CASE t.resultado
                       WHEN 'CONTACTADO'      THEN 'Contactado'
                       WHEN 'NO_CONTESTA'     THEN 'No contesta'
                       WHEN 'BUZON'           THEN 'Buzón de voz'
                       WHEN 'NUMERO_ERRADO'   THEN 'Número errado'
                       WHEN 'VOLVER_A_LLAMAR' THEN 'Volver a llamar'
                       WHEN 'INTERESADO'      THEN 'Interesado'
                       WHEN 'NO_INTERESADO'   THEN 'No interesado'
                       WHEN 'COTIZACION'      THEN 'Pide cotización'
                       WHEN 'VENTA'           THEN 'Cerró venta'
                       WHEN 'RECLAMO'         THEN 'Reclamo'
                       WHEN 'OTRO'            THEN 'Otro'
                       ELSE ''
                   END,
                   p_filtros->'resultado'))

           -- Sólo está en la rejilla de lo pendiente
           AND (p_filtros->'prioridad' IS NULL OR ventas.fn_filtro_texto(
                   COALESCE(t.prioridad, '') || ' ' || CASE t.prioridad
                       WHEN 'ALTA'  THEN 'Alta'
                       WHEN 'MEDIA' THEN 'Media'
                       WHEN 'BAJA'  THEN 'Baja'
                       ELSE ''
                   END,
                   p_filtros->'prioridad'))

           AND (p_filtros->'telefono' IS NULL OR ventas.fn_filtro_texto(t.telefono, p_filtros->'telefono'))

           AND (p_filtros->'contacto_nombre' IS NULL OR ventas.fn_filtro_texto(
                   (SELECT cc.nombres FROM ventas.contactos_clientes cc WHERE cc.id = t.contacto_id),
                   p_filtros->'contacto_nombre'))

           -- La nota se escribe con editor, así que trae etiquetas. En la celda
           -- se ven quitadas; si aquí se buscara en crudo, escribir «p» daría
           -- todas las que tienen un párrafo.
           AND (p_filtros->'nota' IS NULL OR ventas.fn_filtro_texto(
                   TRIM(regexp_replace(
                       replace(COALESCE(t.nota, ''), '&nbsp;', ' '),
                       '<[^>]*>', ' ', 'g')),
                   p_filtros->'nota'))

           AND (p_filtros->'registrado_por_nombre' IS NULL OR ventas.fn_filtro_texto(
                   ventas.fn_nombre_usuario_login(t.created_by), p_filtros->'registrado_por_nombre'))
    ),
    pagina AS (
        SELECT f.id,
               ROW_NUMBER() OVER (ORDER BY COALESCE(f.fecha_realizada, f.fecha_programada) DESC NULLS LAST,
                                           f.id DESC) AS orden
          FROM filtrados f
         ORDER BY orden
         LIMIT p_per_page OFFSET v_offset
    )
    SELECT (SELECT COUNT(*) FROM filtrados),
           COALESCE((SELECT jsonb_agg(ventas.fn_gestiones_json(p.id) ORDER BY p.orden) FROM pagina p), '[]'::jsonb)
      INTO v_total, v_data;

    -- El desplegable «Responsable»: también filtrado, o el menú delataría los
    -- nombres de la gente cuyas gestiones no se pueden ver.
    --
    -- A propósito SIN los filtros de arriba: si se recortara con ellos, elegir
    -- a alguien dejaría el menú con un solo nombre y ya no habría forma de
    -- cambiar de persona sin quitar el filtro primero.
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'id',       x.quien,
               'etiqueta', ventas.fn_nombre_usuario(x.quien)
           ) ORDER BY ventas.fn_nombre_usuario(x.quien)), '[]'::jsonb) INTO v_registradores
      FROM (
        SELECT DISTINCT g.usuario_id AS quien
          FROM ventas.gestiones g
         WHERE g.cliente_id = p_cliente_id
           AND g.usuario_id IS NOT NULL
           AND (CASE WHEN g.modo_registro = 'IMPORTADA'
                     THEN (v_whatsapp  IS NULL OR g.usuario_id = ANY(v_whatsapp))
                     ELSE (v_gestiones IS NULL OR g.usuario_id = ANY(v_gestiones))
                END)
      ) x;

    RETURN jsonb_build_object(
        'success', true,
        'message', 'Gestiones obtenidas exitosamente',
        'data', v_data,
        'meta', jsonb_build_object(
            'total',        v_total,
            'per_page',     p_per_page,
            'current_page', GREATEST(p_page, 1),
            'last_page',    GREATEST(CEIL(v_total::numeric / NULLIF(p_per_page, 0))::integer, 1)
        ),
        'filtros', jsonb_build_object('responsables', v_registradores)
    );
EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object('success', false, 'message', 'Error al listar las gestiones: ' || SQLERRM, 'error_code', SQLSTATE);
END;
$function$;
