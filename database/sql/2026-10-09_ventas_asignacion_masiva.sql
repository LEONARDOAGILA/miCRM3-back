-- ===========================================================================
-- REPARTIR CLIENTES EN BLOQUE
-- ===========================================================================
-- Fecha: 2026-10-09
-- Se aplica después de 2026-10-09_seguridad_visibilidad_asignacion.sql.
--
-- Hasta ahora los clientes se repartían de uno en uno, desde la pestaña
-- Asignación del cliente. Con 1001 clientes y 991 sin vendedor eso no se
-- termina nunca: hace falta elegir muchos y asignarlos de una vez.
--
-- TRES FUNCIONES:
--
--   fn_cliente_responsable_actual   quién tiene hoy al cliente en un papel
--   fn_clientes_asignacion_listar   los clientes a repartir, con sus filtros
--   fn_clientes_reasignar_masivo    el reparto
--
-- LA DE UNO EN UNO SIGUE SIENDO LA QUE MANDA. El reparto no reescribe la
-- lógica: llama a ventas.fn_clientes_reasignar una vez por cliente. Así el
-- rastro en ventas.asignaciones_clientes, el movimiento de la agenda y la
-- auditoría salen idénticos por los dos caminos, y el día que cambie una
-- regla no hay que acordarse de cambiarla en dos sitios.
--
-- DÓNDE VIVE EL RESPONSABLE, que es la trampa de todo esto: el VENDEDOR está
-- en la columna ventas.clientes.vendedor_usuario_id, y los otros tres papeles
-- sólo existen como la última fila de ventas.asignaciones_clientes para ese
-- cliente y ese papel. Son dos sitios distintos. Por eso la pregunta «¿quién
-- lo tiene?» se contesta en UNA función y las tres la llaman: si el listado y
-- el reparto no contestaran lo mismo, el listado enseñaría a uno y el reparto
-- saltaría a otro.
--
-- UN CLIENTE MALO NO TUMBA EL RESTO. Cada cliente va en su propio bloque con
-- EXCEPTION: si uno falla se deshace ése y los demás siguen. Al final se
-- devuelve la cuenta de lo hecho, lo omitido y lo fallido con su motivo, que
-- es lo que hay que poder enseñar después de mover 900 filas.
--
-- Idempotente.
-- ===========================================================================


-- ---------------------------------------------------------------------------
-- 1. ¿Quién tiene hoy a este cliente en este papel?
-- ---------------------------------------------------------------------------
-- La fuente de la verdad para los tres sitios que lo preguntan. En SQL y no en
-- plpgsql a propósito: así el planificador puede meterla dentro de la consulta
-- que la llama en vez de ejecutarla fila por fila.
CREATE OR REPLACE FUNCTION ventas.fn_cliente_responsable_actual(
    p_cliente_id bigint,
    p_rol        varchar
)
RETURNS bigint
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'ventas', 'seguridad'
AS $function$
    SELECT CASE
        -- El vendedor vive en la ficha del cliente
        WHEN UPPER(COALESCE(p_rol, 'VENDEDOR')) = 'VENDEDOR' THEN
            (SELECT c.vendedor_usuario_id
               FROM ventas.clientes c
              WHERE c.id = p_cliente_id)
        -- Los demás papeles, en la última asignación de ese papel
        ELSE
            (SELECT a.usuario_nuevo_id
               FROM ventas.asignaciones_clientes a
              WHERE a.cliente_id = p_cliente_id
                AND a.rol = UPPER(p_rol)
              ORDER BY a.asignado_at DESC, a.id DESC
              LIMIT 1)
    END;
$function$;

COMMENT ON FUNCTION ventas.fn_cliente_responsable_actual(bigint, varchar)
    IS 'Quién atiende hoy al cliente en ese papel. El vendedor sale de la ficha; los demás, de la última asignación';


-- ---------------------------------------------------------------------------
-- 2. Los clientes a repartir
-- ---------------------------------------------------------------------------
-- Paginado como el resto, pero con dos filtros que no tiene el listado normal
-- y que son los que se usan de verdad aquí:
--
--   p_responsable_id    los que hoy atiende esa persona en ese papel
--   p_sin_responsable   los que no tiene nadie
--
-- Porque el caso real no es «busco un cliente», es «se fue Pedro, ¿qué tenía?»
-- o «¿cuáles están sueltos?».
--
-- DEVUELVE TAMBIÉN TODOS LOS ids QUE CUMPLEN EL FILTRO, no sólo los de la
-- página. Sin eso, «seleccionar los 991» obligaría a pasar por 50 páginas
-- marcando casillas. Se cortan en 5000 y se avisa con ids_truncados, para que
-- la pantalla no reciba un millón de números si algún día hay esa cantidad.
CREATE OR REPLACE FUNCTION ventas.fn_clientes_asignacion_listar(
    p_page            integer DEFAULT 1,
    p_per_page        integer DEFAULT 20,
    p_search          text    DEFAULT ''::text,
    p_estado          text    DEFAULT NULL,
    p_rol             varchar DEFAULT 'VENDEDOR',
    p_responsable_id  bigint  DEFAULT NULL,
    p_sin_responsable boolean DEFAULT false,
    p_usuario_id      bigint  DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'ventas', 'seguridad'
AS $function$
DECLARE
    c_tope_ids constant integer := 5000;

    v_rol       varchar;
    v_offset    integer;
    v_filtro    text;
    v_estado    text;
    v_ve_todo   boolean := false;
    v_usuarios  bigint[] := '{}'::bigint[];
    v_total     bigint;
    v_data      jsonb;
    v_ids       jsonb;
    v_truncados boolean := false;
BEGIN
    v_rol    := UPPER(COALESCE(NULLIF(TRIM(p_rol), ''), 'VENDEDOR'));
    v_offset := (GREATEST(p_page, 1) - 1) * GREATEST(p_per_page, 1);
    v_filtro := NULLIF(TRIM(COALESCE(p_search, '')), '');
    v_estado := NULLIF(TRIM(UPPER(COALESCE(p_estado, ''))), '');

    IF v_rol NOT IN ('VENDEDOR', 'COBRADOR', 'ASISTENTE', 'POSTVENTA') THEN
        RETURN jsonb_build_object('success', false, 'message', 'El papel ' || v_rol || ' no existe');
    END IF;

    -- El mismo alcance que el listado normal de clientes, resuelto una vez.
    -- Repartir es cosa de administradores y para ellos esto no filtra nada,
    -- pero si mañana se abre a más gente no se enseñan carteras ajenas.
    IF p_usuario_id IS NOT NULL THEN
        SELECT COALESCE(g.es_administrador, false) INTO v_ve_todo
          FROM seguridad.users u
          LEFT JOIN seguridad.grupos g ON g.id = u.grupo_id
         WHERE u.id = p_usuario_id;

        IF NOT COALESCE(v_ve_todo, false) THEN
            v_usuarios := ventas.fn_usuarios_a_cargo(p_usuario_id);
        END IF;
    END IF;

    -- UNA sola sentencia: la cuenta, la página y la lista de ids salen del
    -- mismo CTE, así no pueden discrepar. Sin tabla temporal a propósito:
    -- esta función es STABLE —no escribe nada— y crear una tabla la
    -- convertiría en una función que escribe.
    WITH base AS (
        SELECT c.id, c.nombre_completo, c.numero_identificacion, c.tipo_cliente,
               c.celular, c.estado,
               ventas.fn_cliente_responsable_actual(c.id, v_rol) AS actual_id
          FROM ventas.clientes c
         WHERE c.deleted_at IS NULL
           AND (p_usuario_id IS NULL OR v_ve_todo OR ventas.fn_cliente_es_de_alguno(c.id, v_usuarios))
           AND (v_estado IS NULL OR c.estado = v_estado)
           AND (v_filtro IS NULL
            OR c.nombre_completo       ILIKE '%' || v_filtro || '%'
            OR c.razon_social          ILIKE '%' || v_filtro || '%'
            OR c.nombre_comercial      ILIKE '%' || v_filtro || '%'
            OR c.numero_identificacion ILIKE '%' || v_filtro || '%'
            OR c.email                 ILIKE '%' || v_filtro || '%'
            OR c.celular               ILIKE '%' || v_filtro || '%'
            OR c.telefono              ILIKE '%' || v_filtro || '%'
            OR c.id::text              ILIKE '%' || v_filtro || '%')
    ),
    -- Los dos filtros propios de esta pantalla, ya con el responsable resuelto
    filtrados AS (
        SELECT b.* FROM base b
         WHERE (NOT COALESCE(p_sin_responsable, false) OR b.actual_id IS NULL)
           AND (COALESCE(p_sin_responsable, false)
                OR p_responsable_id IS NULL
                OR b.actual_id = p_responsable_id)
    ),
    pagina AS (
        SELECT f.* FROM filtrados f
         ORDER BY f.id DESC
         LIMIT GREATEST(p_per_page, 1) OFFSET v_offset
    )
    SELECT
        (SELECT COUNT(*) FROM filtrados),
        (SELECT COALESCE(jsonb_agg(
            jsonb_build_object(
                'id',                    t.id,
                'nombre_completo',       t.nombre_completo,
                'numero_identificacion', t.numero_identificacion,
                'tipo_cliente',          t.tipo_cliente,
                'celular',               t.celular,
                'estado',                t.estado,
                'actual_id',             t.actual_id,
                'actual_nombre',         ventas.fn_nombre_usuario(t.actual_id),
                -- Lo que se movería con él si se marca «llevarse la agenda»
                'pendientes',            (SELECT COUNT(*) FROM ventas.gestiones g
                                           WHERE g.cliente_id = t.id AND g.estado = 'PENDIENTE')
            ) ORDER BY t.id DESC), '[]'::jsonb)
           FROM pagina t),
        (SELECT COALESCE(jsonb_agg(z.id ORDER BY z.id DESC), '[]'::jsonb)
           FROM (SELECT f.id FROM filtrados f ORDER BY f.id DESC LIMIT c_tope_ids) z)
      INTO v_total, v_data, v_ids;

    v_truncados := v_total > c_tope_ids;

    RETURN jsonb_build_object(
        'success', true,
        'message', 'Clientes obtenidos exitosamente',
        'data', jsonb_build_object(
            'data', v_data,
            'meta', jsonb_build_object(
                'total',         v_total,
                'per_page',      GREATEST(p_per_page, 1),
                'current_page',  GREATEST(p_page, 1),
                'last_page',     CASE WHEN v_total = 0 THEN 1 ELSE ceil(v_total::numeric / GREATEST(p_per_page, 1)) END,
                'rol',           v_rol,
                'ids',           v_ids,
                'ids_truncados', v_truncados
            )
        )
    );
EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object('success', false,
                                  'message', 'Error al listar los clientes a repartir: ' || SQLERRM,
                                  'error_code', SQLSTATE);
END;
$function$;

COMMENT ON FUNCTION ventas.fn_clientes_asignacion_listar(integer, integer, text, text, varchar, bigint, boolean, bigint)
    IS 'Clientes para el reparto en bloque, con quién los tiene hoy en ese papel y todos los ids que cumplen el filtro';


-- ---------------------------------------------------------------------------
-- 3. El reparto
-- ---------------------------------------------------------------------------
-- p_ids       los clientes elegidos
-- p_destinos  a quién van. UNO: todos a esa persona. VARIOS: por turnos, en el
--             orden en que llegan. VACÍO o null: se les quita el responsable.
--
-- POR TURNOS Y NO «EL PRIMERO SE LLEVA LA MITAD»: con 991 clientes sueltos y
-- siete vendedores, lo que se quiere es repartir, no amontonar. El turno va
-- por la posición del cliente en la lista, así que el reparto queda parejo
-- aunque alguno se omita por el camino.
--
-- NO SE VALIDA AQUÍ QUIÉN PUEDE HACERLO: eso lo cierra el controlador, igual
-- que en la reasignación de uno en uno.
CREATE OR REPLACE FUNCTION ventas.fn_clientes_reasignar_masivo(
    p_ids            jsonb,
    p_destinos       jsonb    DEFAULT '[]'::jsonb,
    p_rol            varchar  DEFAULT 'VENDEDOR',
    p_motivo         text     DEFAULT NULL,
    p_mover_agenda   boolean  DEFAULT true,
    p_usuario_id     bigint   DEFAULT NULL,
    p_usuario_login  varchar  DEFAULT NULL,
    p_usuario_nombre varchar  DEFAULT NULL,
    p_ip_address     inet     DEFAULT NULL,
    p_user_agent     text     DEFAULT NULL,
    p_request_id     uuid     DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'ventas', 'seguridad', 'auditoria'
AS $function$
DECLARE
    c_tope constant integer := 2000;

    v_rol       varchar;
    v_ids       bigint[];
    v_destinos  bigint[];
    v_n         integer;
    v_cuantos   integer;
    v_id        bigint;
    v_destino   bigint;
    v_actual    bigint;
    v_r         jsonb;
    v_i         integer := 0;

    v_asignados integer := 0;
    v_omitidos  integer := 0;
    v_fallidos  integer := 0;
    v_movidas   integer := 0;
    v_fallos    jsonb   := '[]'::jsonb;
    v_reparto   jsonb;
    v_hechos    bigint[] := '{}'::bigint[];   -- a quién fue cada cliente, para el resumen
BEGIN
    v_rol := UPPER(COALESCE(NULLIF(TRIM(p_rol), ''), 'VENDEDOR'));

    IF v_rol NOT IN ('VENDEDOR', 'COBRADOR', 'ASISTENTE', 'POSTVENTA') THEN
        RAISE EXCEPTION 'El papel % no existe', v_rol USING ERRCODE = 'P0017';
    END IF;

    -- Los clientes, sin repetir y respetando el orden en que llegaron: ese
    -- orden es el que decide los turnos del reparto
    SELECT COALESCE(array_agg(t.id ORDER BY t.pos), '{}'::bigint[]) INTO v_ids
      FROM (SELECT DISTINCT ON (e.valor::bigint)
                   e.valor::bigint AS id, e.pos
              FROM jsonb_array_elements_text(COALESCE(p_ids, '[]'::jsonb)) WITH ORDINALITY e(valor, pos)
             ORDER BY e.valor::bigint, e.pos) t;

    v_cuantos := COALESCE(array_length(v_ids, 1), 0);

    IF v_cuantos = 0 THEN
        RAISE EXCEPTION 'No se eligió ningún cliente' USING ERRCODE = 'P0018';
    END IF;

    IF v_cuantos > c_tope THEN
        RAISE EXCEPTION 'Son % clientes y el máximo por tanda es %. Acote el filtro y repita.', v_cuantos, c_tope
            USING ERRCODE = 'P0019';
    END IF;

    -- Los destinos. Vacío significa quitarles el responsable.
    SELECT COALESCE(array_agg(e.valor::bigint ORDER BY e.pos), '{}'::bigint[]) INTO v_destinos
      FROM jsonb_array_elements_text(COALESCE(p_destinos, '[]'::jsonb)) WITH ORDINALITY e(valor, pos)
     WHERE e.valor IS NOT NULL AND TRIM(e.valor) <> '';

    v_n := COALESCE(array_length(v_destinos, 1), 0);

    -- Que existan, y decirlo ANTES de tocar nada: enterarse en el cliente 400
    -- de que el usuario no existe deja el trabajo a medias
    FOR v_i IN 1 .. v_n LOOP
        IF ventas.fn_nombre_usuario(v_destinos[v_i]) IS NULL THEN
            RAISE EXCEPTION 'El usuario % no existe', v_destinos[v_i] USING ERRCODE = 'P0016';
        END IF;
    END LOOP;

    -- ---------------- el reparto, cliente por cliente ----------------
    FOR v_i IN 1 .. v_cuantos LOOP
        v_id := v_ids[v_i];

        -- Por turnos. Con un solo destino sale siempre el mismo.
        v_destino := CASE WHEN v_n = 0 THEN NULL ELSE v_destinos[((v_i - 1) % v_n) + 1] END;

        -- Ya lo tiene: no es un error, es que no hay nada que hacer. La
        -- función de uno en uno levantaría excepción y aquí eso cortaría la
        -- tanda, así que se mira antes de llamarla.
        v_actual := ventas.fn_cliente_responsable_actual(v_id, v_rol);
        IF v_actual IS NOT DISTINCT FROM v_destino THEN
            v_omitidos := v_omitidos + 1;
            CONTINUE;
        END IF;

        BEGIN
            v_r := ventas.fn_clientes_reasignar(
                     v_id, v_destino, p_motivo, COALESCE(p_mover_agenda, true), v_rol,
                     p_usuario_id, p_usuario_login, p_usuario_nombre,
                     p_ip_address, p_user_agent, p_request_id);

            v_asignados := v_asignados + 1;
            v_movidas   := v_movidas + COALESCE((v_r->'data'->>'gestiones_movidas')::integer, 0);
            -- Sólo cuenta para el resumen si fue A alguien: quitar el
            -- responsable no es un destino y no debe salir como tal
            IF v_destino IS NOT NULL THEN
                v_hechos := v_hechos || v_destino;
            END IF;

        EXCEPTION WHEN OTHERS THEN
            -- Se deshace SÓLO este cliente; los demás siguen
            v_fallidos := v_fallidos + 1;
            IF jsonb_array_length(v_fallos) < 50 THEN
                v_fallos := v_fallos || jsonb_build_object('cliente_id', v_id, 'motivo', SQLERRM);
            END IF;
        END;
    END LOOP;

    -- Cuántos se llevó cada uno, que es lo primero que se quiere comprobar
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'usuario_id', x.uid,
               'usuario',    ventas.fn_nombre_usuario(x.uid),
               'clientes',   x.cuantos) ORDER BY x.cuantos DESC), '[]'::jsonb)
      INTO v_reparto
      FROM (SELECT u AS uid, COUNT(*) AS cuantos
              FROM unnest(v_hechos) u
             GROUP BY u) x;

    RETURN jsonb_build_object(
        'success', true,
        'message',
            CASE WHEN v_asignados = 0 THEN 'No se cambió ningún cliente'
                 WHEN v_n = 0         THEN 'Se quitó el responsable a ' || v_asignados || ' cliente(s)'
                 ELSE v_asignados || ' cliente(s) repartidos como ' || INITCAP(v_rol)
            END
            || CASE WHEN v_omitidos  > 0 THEN '; ' || v_omitidos || ' ya lo tenían' ELSE '' END
            || CASE WHEN v_fallidos  > 0 THEN '; ' || v_fallidos || ' con error'    ELSE '' END
            || CASE WHEN v_movidas   > 0 THEN ' (' || v_movidas || ' gestión(es) pendientes se movieron)' ELSE '' END,
        'data', jsonb_build_object(
            'rol',               v_rol,
            'pedidos',           v_cuantos,
            'asignados',         v_asignados,
            'omitidos',          v_omitidos,
            'fallidos',          v_fallidos,
            'gestiones_movidas', v_movidas,
            'reparto',           v_reparto,
            'fallos',            v_fallos
        )
    );
END;
$function$;

COMMENT ON FUNCTION ventas.fn_clientes_reasignar_masivo(jsonb, jsonb, varchar, text, boolean, bigint, varchar, varchar, inet, text, uuid)
    IS 'Reparte varios clientes en un papel: a una persona o por turnos entre varias. Un cliente que falle no tumba la tanda';


-- ---------------------------------------------------------------------------
-- COMPROBACIÓN
-- ---------------------------------------------------------------------------
-- Cuántos hay sueltos en cada papel, que es lo que la pantalla enseñará de
-- entrada.
SELECT r.rol,
       COUNT(*) FILTER (WHERE ventas.fn_cliente_responsable_actual(c.id, r.rol) IS NULL)     AS sin_nadie,
       COUNT(*) FILTER (WHERE ventas.fn_cliente_responsable_actual(c.id, r.rol) IS NOT NULL) AS asignados
  FROM ventas.clientes c
 CROSS JOIN (VALUES ('VENDEDOR'), ('COBRADOR'), ('ASISTENTE'), ('POSTVENTA')) AS r(rol)
 WHERE c.deleted_at IS NULL
 GROUP BY r.rol
 ORDER BY r.rol;
