-- ===========================================================================
-- ELEGIR EL RESPONSABLE DE UNA GESTIÓN
-- ===========================================================================
-- Fecha: 2026-10-09
-- Se aplica después de 2026-10-09_seguridad_tipos_usuarios_crud.sql.
--
-- La columna ya existía: ventas.gestiones.usuario_id es «a quién le TOCA» —es
-- lo que mira la agenda y lo que decide la visibilidad—, y las funciones de
-- crear y modificar ya reciben p_usuario_responsable_id. Lo que faltaba era
-- poder elegirlo: la pantalla mandaba siempre el vendedor del cliente, y si el
-- cliente no tenía vendedor, la gestión se guardaba SIN RESPONSABLE.
--
-- Esto añade tres cosas:
--
-- 1. QUIÉN PUEDE SER RESPONSABLE (fn_gestiones_asignables). No cualquiera: una
--    gestión asignada entra en la agenda de otra persona, así que la lista es
--    la jerarquía de quien asigna más los responsables de ese cliente —para
--    poder pasarle algo al cobrador del cliente aunque no esté por debajo—, y
--    todos si quien asigna es administrador.
--
-- 2. LA MISMA REGLA, PARA VALIDAR (fn_gestion_puede_asignar). La usa el
--    controlador antes de guardar: si la comprobación viviera sólo en la
--    pantalla, una petición a mano podría meterle trabajo a cualquiera.
--
-- 3. QUE NUNCA SE QUEDE SIN RESPONSABLE:
--      al CREAR     si no se elige, es quien la crea (antes: NULL)
--      al MODIFICAR si no viene, se deja el que tenía (antes: lo borraba)
--
--    El NULL de antes no era inofensivo: desde que la visibilidad filtra por
--    usuario_id, una gestión sin responsable sólo la ven los administradores.
--    De las 1448 gestiones de hoy, 1395 están así —las sembradas de prueba—, y
--    la causa es justo ésta.
--
-- Idempotente.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- 1. A quién se le puede asignar
-- ---------------------------------------------------------------------------
-- p_cliente_id es opcional: sin él la lista es sólo la jerarquía. Se pasa
-- siempre desde la ficha de la gestión, que sí sabe de qué cliente es.
CREATE OR REPLACE FUNCTION ventas.fn_gestiones_asignables(
    p_usuario_id bigint,
    p_cliente_id bigint DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'ventas'
AS $function$
DECLARE
    v_admin  boolean := false;
    v_data   jsonb;
BEGIN
    IF p_usuario_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'message', 'No se sabe quién pregunta', 'data', '[]'::jsonb);
    END IF;

    SELECT COALESCE(g.es_administrador, false) INTO v_admin
      FROM seguridad.users u
      LEFT JOIN seguridad.grupos g ON g.id = u.grupo_id
     WHERE u.id = p_usuario_id;

    WITH candidatos AS (
        -- Uno mismo, siempre: lo normal es quedarse la gestión
        SELECT p_usuario_id AS id, 'YO'::text AS origen
        UNION
        -- Su jerarquía (él y los grupos por debajo). Para un administrador,
        -- todos los usuarios vivos
        SELECT u.id, 'EQUIPO'
          FROM seguridad.users u
         WHERE u.deleted_at IS NULL
           AND u.isactive IS TRUE
           AND (v_admin OR u.id = ANY(ventas.fn_usuarios_a_cargo(p_usuario_id)))
        UNION
        -- Y los responsables de ESTE cliente, aunque no estén en su jerarquía:
        -- es el caso de pasarle una cobranza al cobrador del cliente
        SELECT r.usuario_id, 'CLIENTE'
          FROM (
              SELECT c.vendedor_usuario_id AS usuario_id
                FROM ventas.clientes c
               WHERE c.id = p_cliente_id
              UNION
              -- El DISTINCT ON va en su propia subconsulta: su ORDER BY es
              -- suyo, y suelto dentro del UNION se leería como el orden de la
              -- unión entera, donde el alias «a» ya no existe
              SELECT z.usuario_id
                FROM (
                    SELECT DISTINCT ON (a.rol) a.usuario_nuevo_id AS usuario_id
                      FROM ventas.asignaciones_clientes a
                     WHERE a.cliente_id = p_cliente_id AND a.rol <> 'VENDEDOR'
                     ORDER BY a.rol, a.asignado_at DESC
                ) z
          ) r
         WHERE p_cliente_id IS NOT NULL AND r.usuario_id IS NOT NULL
    )
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'id',            u.id,
               'login_user',    u.login_user,
               'nombre',        ventas.fn_nombre_usuario(u.id),
               'perfil_nombre', p.nombre,
               'es_yo',         u.id = p_usuario_id,
               -- Para poder rotular «(vendedor de este cliente)» en la lista
               'rol_cliente',   (SELECT string_agg(x.rol, ', ' ORDER BY x.rol) FROM (
                                    SELECT 'VENDEDOR' AS rol FROM ventas.clientes c
                                     WHERE c.id = p_cliente_id AND c.vendedor_usuario_id = u.id
                                    UNION
                                    SELECT a.rol FROM ventas.asignaciones_clientes a
                                     WHERE a.cliente_id = p_cliente_id AND a.usuario_nuevo_id = u.id
                                       AND a.rol <> 'VENDEDOR'
                                 ) x)
           ) ORDER BY (u.id = p_usuario_id) DESC, ventas.fn_nombre_usuario(u.id)), '[]'::jsonb)
      INTO v_data
      FROM (SELECT DISTINCT id FROM candidatos WHERE id IS NOT NULL) c
      JOIN seguridad.users u ON u.id = c.id AND u.deleted_at IS NULL
      LEFT JOIN seguridad.perfiles p ON p.id = u.perfil_id;

    RETURN jsonb_build_object('success', true,
                              'message', 'Usuarios asignables obtenidos exitosamente',
                              'data', v_data);
EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object('success', false,
                                  'message', 'Error al obtener los usuarios asignables: ' || SQLERRM,
                                  'error_code', SQLSTATE);
END;
$function$;

COMMENT ON FUNCTION ventas.fn_gestiones_asignables(bigint, bigint)
    IS 'A qué usuarios puede ese usuario asignar una gestión de ese cliente: su jerarquía, los responsables del cliente y él mismo; todos si es administrador';


-- ---------------------------------------------------------------------------
-- 2. La misma regla, para validar al guardar
-- ---------------------------------------------------------------------------
-- Sale de la lista de arriba a propósito: una regla escrita dos veces se
-- separa en cuanto una de las dos cambie.
CREATE OR REPLACE FUNCTION ventas.fn_gestion_puede_asignar(
    p_usuario_id      bigint,
    p_responsable_id  bigint,
    p_cliente_id      bigint DEFAULT NULL
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
AS $function$
    SELECT CASE
             -- Sin responsable elegido no hay nada que validar: la función de
             -- crear pone a quien la crea
             WHEN p_responsable_id IS NULL THEN true
             WHEN p_responsable_id = p_usuario_id THEN true
             ELSE EXISTS (
                 SELECT 1
                   FROM jsonb_array_elements(
                            ventas.fn_gestiones_asignables(p_usuario_id, p_cliente_id) -> 'data') AS x
                  WHERE (x ->> 'id')::bigint = p_responsable_id)
           END;
$function$;

COMMENT ON FUNCTION ventas.fn_gestion_puede_asignar(bigint, bigint, bigint)
    IS 'Si ese usuario puede dejar la gestión a cargo de ese otro';


-- ---------------------------------------------------------------------------
-- 3. Que la gestión nunca se quede sin responsable
-- ---------------------------------------------------------------------------
-- Dos sustituciones de una línea cada una, sobre la definición que hay en la
-- base. Se comprueba que el ancla aparezca exactamente una vez antes de tocar
-- nada: si no, la migración revienta y no deja una función a medias.
DO $$
DECLARE
    v_def     text;
    v_cuantas int;

    c_crear_viejo constant text := '        p_usuario_responsable_id,';
    c_crear_nuevo constant text :=
'        -- Si no se eligió responsable, es de quien la crea. Nunca NULL: una
        -- gestión sin responsable no entra en ninguna agenda y, desde que la
        -- visibilidad filtra por usuario_id, sólo la ven los administradores
        COALESCE(p_usuario_responsable_id, p_usuario_id),';

    c_modif_viejo constant text := '           usuario_id       = p_usuario_responsable_id,';
    c_modif_nuevo constant text :=
'           -- Lo que no viene no se borra: una pantalla que no manda el
           -- responsable deja el que ya tenía
           usuario_id       = COALESCE(p_usuario_responsable_id, usuario_id),';
BEGIN
    -- ---- crear ----
    SELECT pg_get_functiondef(p.oid) INTO v_def
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'ventas' AND p.proname = 'fn_gestiones_crear' AND p.prokind = 'f';

    IF position('COALESCE(p_usuario_responsable_id, p_usuario_id)' IN v_def) > 0 THEN
        RAISE NOTICE 'fn_gestiones_crear ya pone responsable por omisión';
    ELSE
        v_cuantas := (length(v_def) - length(replace(v_def, c_crear_viejo, ''))) / length(c_crear_viejo);
        IF v_cuantas <> 1 THEN
            RAISE EXCEPTION 'fn_gestiones_crear : el ancla aparece % veces y esperaba 1', v_cuantas;
        END IF;
        EXECUTE replace(v_def, c_crear_viejo, c_crear_nuevo);
        RAISE NOTICE 'fn_gestiones_crear actualizada';
    END IF;

    -- ---- modificar ----
    SELECT pg_get_functiondef(p.oid) INTO v_def
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'ventas' AND p.proname = 'fn_gestiones_modificar' AND p.prokind = 'f';

    IF position('COALESCE(p_usuario_responsable_id, usuario_id)' IN v_def) > 0 THEN
        RAISE NOTICE 'fn_gestiones_modificar ya conserva el responsable';
    ELSE
        v_cuantas := (length(v_def) - length(replace(v_def, c_modif_viejo, ''))) / length(c_modif_viejo);
        IF v_cuantas <> 1 THEN
            RAISE EXCEPTION 'fn_gestiones_modificar : el ancla aparece % veces y esperaba 1', v_cuantas;
        END IF;
        EXECUTE replace(v_def, c_modif_viejo, c_modif_nuevo);
        RAISE NOTICE 'fn_gestiones_modificar actualizada';
    END IF;
END;
$$;


-- ---------------------------------------------------------------------------
-- COMPROBACIÓN
-- ---------------------------------------------------------------------------
-- A quién puede asignar un vendedor en uno de sus clientes, y a quién un
-- administrador:
--
--   SELECT jsonb_array_length(ventas.fn_gestiones_asignables(46, 1055) -> 'data') AS ve_vcuenca1,
--          jsonb_array_length(ventas.fn_gestiones_asignables(4,  1055) -> 'data') AS ve_lagila;
--
--   SELECT ventas.fn_gestion_puede_asignar(46, 46, 1055) AS a_si_mismo_si,
--          ventas.fn_gestion_puede_asignar(46,  4, 1055) AS a_su_jefe_no;
