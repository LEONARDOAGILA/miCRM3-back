-- ============================================================================
-- UN CUARTO RESPONSABLE: POSTVENTA
--
-- Al cliente ya lo atendían tres manos —vendedor, cobrador y asistente— y
-- faltaba quien lo atiende DESPUÉS de la venta: garantías, instalaciones y
-- reclamos. Es el mismo mecanismo de siempre, un papel más.
--
-- Al montar los papeles (2026-10-03) quedó escrito que el rol NO lleva CHECK
-- para que añadir un cuarto responsable mañana no costase una migración.
-- Costaba ésta, y por un motivo tonto: tres funciones enumeraban los papeles a
-- mano en un VALUES. Así que además de dar de alta POSTVENTA se les quita la
-- lista. Las tres preguntan ahora a los datos «el titular de cada papel,
-- cualquiera que sea» con DISTINCT ON (rol). El quinto ya no toca la base.
--
--   · DISTINCT ON (rol) aprovecha tal cual el índice que ya existe
--     (ix_asignaciones_cliente_rol: cliente_id, rol, asignado_at DESC, id DESC),
--     así que no se paga nada en la lista paginada de mil y pico clientes.
--
--   · VENDEDOR sigue siendo el único caso especial, y no por la lista: su
--     titular manda desde ventas.clientes.vendedor_usuario_id y no desde la
--     última asignación. Por eso en fn_clientes_responsables se le deja fuera
--     del DISTINCT ON: esa fila sale de la columna del cliente.
--
--   · «Mío» pasa a incluir «soy su postventa». A los cuatro papeles se les
--     asigna el cliente para que lo trabajen, y el que no lo ve no lo trabaja.
--
-- Las firmas no cambian, así que CREATE OR REPLACE reemplaza de verdad y no
-- crea sobrecargas: no hace falta borrar nada antes.
--
-- La lista de papeles vive ahora en dos sitios, y en ninguno más:
--   · el front: RolResponsable y ROLES_RESPONSABLE (ventas/interfaces/gestionModel.ts)
--   · el back:  el «in:» de GestionController@reasignar
--
-- Idempotente: se puede volver a correr.
-- ============================================================================


-- ---------------------------------------------------------------------------
-- 1. ¿Este cliente es de este usuario?
--
-- SQL plano y STABLE para que el planificador la pueda meter dentro de la
-- consulta en vez de llamarla fila por fila.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ventas.fn_cliente_es_de(p_cliente_id bigint, p_usuario_id bigint)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
AS $function$
    SELECT EXISTS (
        SELECT 1 FROM ventas.clientes c
         WHERE c.id = p_cliente_id AND c.vendedor_usuario_id = p_usuario_id
    ) OR EXISTS (
        -- El titular VIGENTE de cada papel, no el histórico: a quien le
        -- quitaron el cliente no tiene por qué seguir viéndolo
        SELECT 1
          FROM (
              SELECT DISTINCT ON (a.rol) a.usuario_nuevo_id
                FROM ventas.asignaciones_clientes a
               WHERE a.cliente_id = p_cliente_id
               ORDER BY a.rol, a.asignado_at DESC, a.id DESC
          ) u
         WHERE u.usuario_nuevo_id = p_usuario_id
    )
$function$;

COMMENT ON FUNCTION ventas.fn_cliente_es_de(bigint, bigint)
    IS 'true si el usuario ocupa ahora mismo alguno de los papeles del cliente: vendedor, cobrador, asistente, postventa…';


-- ---------------------------------------------------------------------------
-- 2. Lo mismo para toda una jerarquía de usuarios
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ventas.fn_cliente_es_de_alguno(p_cliente_id bigint, p_usuarios bigint[])
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
AS $function$
    SELECT EXISTS (
        SELECT 1 FROM ventas.clientes c
         WHERE c.id = p_cliente_id AND c.vendedor_usuario_id = ANY(p_usuarios)
    ) OR EXISTS (
        -- El titular VIGENTE de cada papel, no el histórico: a quien le
        -- quitaron el cliente no tiene por qué seguir viéndolo
        SELECT 1
          FROM (
              SELECT DISTINCT ON (a.rol) a.usuario_nuevo_id
                FROM ventas.asignaciones_clientes a
               WHERE a.cliente_id = p_cliente_id
               ORDER BY a.rol, a.asignado_at DESC, a.id DESC
          ) u
         WHERE u.usuario_nuevo_id = ANY(p_usuarios)
    )
$function$;

COMMENT ON FUNCTION ventas.fn_cliente_es_de_alguno(bigint, bigint[])
    IS 'true si alguno de esos usuarios ocupa ahora mismo algún papel del cliente';


-- ---------------------------------------------------------------------------
-- 3. Quién atiende ahora, por papel
--
-- Antes devolvía SIEMPRE las tres filas, con nulos en los puestos vacíos.
-- Ahora devuelve sólo los papeles que alguna vez se asignaron, y el puesto que
-- nunca se usó no viene. No se pierde nada: la pantalla dibuja una tarjeta por
-- cada papel de SU catálogo y busca la fila por rol, así que el puesto sin
-- estrenar sale igual de vacío («lo atiende nadie», con el borde punteado).
-- Es justo lo que permite que un papel nuevo no pase por aquí.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ventas.fn_clientes_responsables(p_cliente_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'ventas', 'rh'
AS $function$
DECLARE
    v_data jsonb;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM ventas.clientes WHERE id = p_cliente_id AND deleted_at IS NULL) THEN
        RETURN jsonb_build_object('success', false, 'message', 'El cliente no existe o está en la papelera');
    END IF;

    SELECT jsonb_agg(x.fila ORDER BY x.orden, x.rol) INTO v_data
    FROM (
        -- El vendedor manda desde la columna del cliente, no desde el historial
        SELECT 1 AS orden, 'VENDEDOR' AS rol, jsonb_build_object(
                   'rol', 'VENDEDOR',
                   'usuario_id', c.vendedor_usuario_id,
                   'usuario_nombre', ventas.fn_nombre_usuario(c.vendedor_usuario_id),
                   'desde', (SELECT to_char(MAX(a.asignado_at), 'YYYY-MM-DD HH24:MI')
                               FROM ventas.asignaciones_clientes a
                              WHERE a.cliente_id = p_cliente_id AND a.rol = 'VENDEDOR'
                                AND a.usuario_nuevo_id IS NOT DISTINCT FROM c.vendedor_usuario_id)
               ) AS fila
          FROM ventas.clientes c WHERE c.id = p_cliente_id

        UNION ALL

        -- El resto de papeles: el último de cada uno, sin lista que mantener
        SELECT 2, u.rol, jsonb_build_object(
                   'rol', u.rol,
                   'usuario_id', u.usuario_nuevo_id,
                   'usuario_nombre', ventas.fn_nombre_usuario(u.usuario_nuevo_id),
                   'desde', to_char(u.asignado_at, 'YYYY-MM-DD HH24:MI')
               )
          FROM (
              SELECT DISTINCT ON (a.rol) a.rol, a.usuario_nuevo_id, a.asignado_at
                FROM ventas.asignaciones_clientes a
               WHERE a.cliente_id = p_cliente_id AND a.rol <> 'VENDEDOR'
               ORDER BY a.rol, a.asignado_at DESC, a.id DESC
          ) u
    ) x;

    RETURN jsonb_build_object('success', true, 'message', 'Responsables obtenidos exitosamente',
                              'data', COALESCE(v_data, '[]'::jsonb));
EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object('success', false, 'message', 'Error al obtener los responsables: ' || SQLERRM, 'error_code', SQLSTATE);
END;
$function$;
