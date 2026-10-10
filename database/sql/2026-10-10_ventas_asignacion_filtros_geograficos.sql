-- ===========================================================================
-- MÁS FILTROS PARA EL REPARTO: PROVINCIA, CANTÓN, PARROQUIA Y UBICACIÓN
-- ===========================================================================
-- Fecha: 2026-10-10
-- Se aplica después de 2026-10-09_seguridad_menu_asignacion_masiva.sql.
--
-- Repartir por zona es la forma natural de repartir una cartera: el vendedor
-- de Manabí se queda con Manabí. Los 1001 clientes tienen provincia, cantón y
-- parroquia puestos —11, 12 y 6 valores distintos—, así que el dato está ahí
-- y sólo faltaba poder filtrar por él.
--
-- LOS TRES DESPLEGABLES SALEN DE LOS DATOS, no de una lista escrita a mano, y
-- VAN EN CASCADA: los cantones son los de la provincia elegida y las
-- parroquias las del cantón. Se calculan además sobre el resto de filtros ya
-- aplicados, así que si se está mirando «los que no tiene nadie», la lista de
-- provincias sólo trae las que tienen clientes sueltos. Elegir una opción no
-- puede llevar a cero resultados.
--
-- SE SUELTA LA FUNCIÓN ANTES DE CREARLA. Cambian los parámetros, y
-- CREATE OR REPLACE con otra firma no reemplaza: crea una SEGUNDA función con
-- el mismo nombre. Luego la llamada se vuelve ambigua o entra por la vieja, y
-- el fallo aparece lejos de aquí.
--
-- Idempotente.
-- ===========================================================================

-- La firma de antes, para que no quede una sobrecarga conviviendo con la nueva
DROP FUNCTION IF EXISTS ventas.fn_clientes_asignacion_listar(integer, integer, text, text, varchar, bigint, boolean, bigint);

CREATE OR REPLACE FUNCTION ventas.fn_clientes_asignacion_listar(
    p_page            integer DEFAULT 1,
    p_per_page        integer DEFAULT 20,
    p_search          text    DEFAULT ''::text,
    p_estado          text    DEFAULT NULL,
    p_rol             varchar DEFAULT 'VENDEDOR',
    p_responsable_id  bigint  DEFAULT NULL,
    p_sin_responsable boolean DEFAULT false,
    p_provincia       text    DEFAULT NULL,
    p_canton          text    DEFAULT NULL,
    p_parroquia       text    DEFAULT NULL,
    -- NULL = da igual; true = sólo los que tienen ubicación; false = sólo los que no
    p_con_coordenadas boolean DEFAULT NULL,
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

    v_rol        varchar;
    v_offset     integer;
    v_filtro     text;
    v_estado     text;
    v_provincia  text;
    v_canton     text;
    v_parroquia  text;
    v_ve_todo    boolean := false;
    v_usuarios   bigint[] := '{}'::bigint[];
    v_total      bigint;
    v_data       jsonb;
    v_ids        jsonb;
    v_provincias jsonb;
    v_cantones   jsonb;
    v_parroquias jsonb;
    v_truncados  boolean := false;
BEGIN
    v_rol       := UPPER(COALESCE(NULLIF(TRIM(p_rol), ''), 'VENDEDOR'));
    v_offset    := (GREATEST(p_page, 1) - 1) * GREATEST(p_per_page, 1);
    v_filtro    := NULLIF(TRIM(COALESCE(p_search, '')), '');
    v_estado    := NULLIF(TRIM(UPPER(COALESCE(p_estado, ''))), '');
    v_provincia := NULLIF(TRIM(COALESCE(p_provincia, '')), '');
    v_canton    := NULLIF(TRIM(COALESCE(p_canton, '')), '');
    v_parroquia := NULLIF(TRIM(COALESCE(p_parroquia, '')), '');

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

    -- UNA sola sentencia: la cuenta, la página, los ids y los tres
    -- desplegables salen del mismo sitio, así no pueden discrepar. Sin tabla
    -- temporal a propósito: esta función es STABLE —no escribe nada— y crear
    -- una tabla la convertiría en una función que escribe.
    WITH base AS (
        SELECT c.id, c.nombre_completo, c.numero_identificacion, c.tipo_cliente,
               c.celular, c.estado, c.provincia, c.canton, c.parroquia,
               c.coordenadas, c.link_coordenadas,
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
            OR c.direccion             ILIKE '%' || v_filtro || '%'
            OR c.id::text              ILIKE '%' || v_filtro || '%')
    ),
    -- De quién son. Va antes que la geografía porque los desplegables de
    -- zona se calculan sobre esto: si se miran «los sueltos», las provincias
    -- que se ofrecen son las que tienen sueltos.
    con_responsable AS (
        SELECT b.* FROM base b
         WHERE (NOT COALESCE(p_sin_responsable, false) OR b.actual_id IS NULL)
           AND (COALESCE(p_sin_responsable, false)
                OR p_responsable_id IS NULL
                OR b.actual_id = p_responsable_id)
    ),
    -- El conjunto final, ya con la zona y la ubicación
    filtrados AS (
        SELECT r.* FROM con_responsable r
         WHERE (v_provincia IS NULL OR r.provincia = v_provincia)
           AND (v_canton    IS NULL OR r.canton    = v_canton)
           AND (v_parroquia IS NULL OR r.parroquia = v_parroquia)
           AND (p_con_coordenadas IS NULL
                OR (p_con_coordenadas AND NULLIF(TRIM(COALESCE(r.coordenadas, '')), '') IS NOT NULL)
                OR (NOT p_con_coordenadas AND NULLIF(TRIM(COALESCE(r.coordenadas, '')), '') IS NULL))
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
                'provincia',             t.provincia,
                'canton',                t.canton,
                'parroquia',             t.parroquia,
                'coordenadas',           t.coordenadas,
                'link_coordenadas',      t.link_coordenadas,
                'actual_id',             t.actual_id,
                'actual_nombre',         ventas.fn_nombre_usuario(t.actual_id),
                -- Lo que se movería con él si se marca «llevarse la agenda»
                'pendientes',            (SELECT COUNT(*) FROM ventas.gestiones g
                                           WHERE g.cliente_id = t.id AND g.estado = 'PENDIENTE')
            ) ORDER BY t.id DESC), '[]'::jsonb)
           FROM pagina t),

        (SELECT COALESCE(jsonb_agg(z.id ORDER BY z.id DESC), '[]'::jsonb)
           FROM (SELECT f.id FROM filtrados f ORDER BY f.id DESC LIMIT c_tope_ids) z),

        -- ---- los tres desplegables, en cascada ----
        -- Cada uno se calcula SIN su propio filtro: así elegir una provincia
        -- no borra las demás de la lista y se puede cambiar de idea.
        (SELECT COALESCE(jsonb_agg(jsonb_build_object('valor', x.v, 'clientes', x.n) ORDER BY x.v), '[]'::jsonb)
           FROM (SELECT r.provincia AS v, COUNT(*) AS n FROM con_responsable r
                  WHERE r.provincia IS NOT NULL GROUP BY r.provincia) x),

        (SELECT COALESCE(jsonb_agg(jsonb_build_object('valor', x.v, 'clientes', x.n) ORDER BY x.v), '[]'::jsonb)
           FROM (SELECT r.canton AS v, COUNT(*) AS n FROM con_responsable r
                  WHERE r.canton IS NOT NULL
                    AND (v_provincia IS NULL OR r.provincia = v_provincia)
                  GROUP BY r.canton) x),

        (SELECT COALESCE(jsonb_agg(jsonb_build_object('valor', x.v, 'clientes', x.n) ORDER BY x.v), '[]'::jsonb)
           FROM (SELECT r.parroquia AS v, COUNT(*) AS n FROM con_responsable r
                  WHERE r.parroquia IS NOT NULL
                    AND (v_provincia IS NULL OR r.provincia = v_provincia)
                    AND (v_canton    IS NULL OR r.canton    = v_canton)
                  GROUP BY r.parroquia) x)

      INTO v_total, v_data, v_ids, v_provincias, v_cantones, v_parroquias;

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
                'ids_truncados', v_truncados,
                'filtros',       jsonb_build_object(
                    'provincias', v_provincias,
                    'cantones',   v_cantones,
                    'parroquias', v_parroquias
                )
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

COMMENT ON FUNCTION ventas.fn_clientes_asignacion_listar(integer, integer, text, text, varchar, bigint, boolean, text, text, text, boolean, bigint)
    IS 'Clientes para el reparto en bloque: quién los tiene hoy, filtros de zona en cascada y todos los ids que cumplen el filtro';


-- ---------------------------------------------------------------------------
-- COMPROBACIÓN
-- ---------------------------------------------------------------------------
-- Que no quedó una sobrecarga de la función vieja
SELECT COUNT(*) AS versiones_de_la_funcion
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname = 'ventas' AND p.proname = 'fn_clientes_asignacion_listar';

-- Las provincias que se ofrecerán al mirar los clientes sin vendedor
SELECT jsonb_pretty(
    ventas.fn_clientes_asignacion_listar(
        1, 1, '', NULL, 'VENDEDOR', NULL, true, NULL, NULL, NULL, NULL,
        (SELECT id FROM seguridad.users WHERE login_user = 'LAGILA')
    ) -> 'data' -> 'meta' -> 'filtros' -> 'provincias');
