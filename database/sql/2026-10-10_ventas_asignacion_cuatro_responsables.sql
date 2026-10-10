-- ===========================================================================
-- LOS CUATRO RESPONSABLES A LA VEZ, EN COLUMNAS Y EN FILTROS
-- ===========================================================================
-- Fecha: 2026-10-10
-- Se aplica después de 2026-10-10_ventas_asignacion_filtros_geograficos.sql.
--
-- Hasta ahora la pantalla enseñaba UNA columna, «hoy lo atiende», y era la del
-- papel que se estaba repartiendo. Eso obligaba a cambiar de papel para ver
-- quién cobra, y no dejaba hacer la pregunta que de verdad se hace al
-- repartir: «¿cuáles tienen vendedor pero no tienen cobrador?».
--
-- Ahora salen los cuatro —vendedor, cobrador, asistente y postventa— como
-- cuatro columnas, y cada uno tiene su propio filtro. Los cuatro filtros se
-- suman, así que se pueden cruzar.
--
-- EL PAPEL QUE SE REPARTE YA NO FILTRA NADA. Antes p_rol hacía dos trabajos:
-- decir qué columna enseñar y a qué papel se referían los filtros. Ahora las
-- columnas son las cuatro y los filtros van por su cuenta, así que el papel
-- sólo sirve para el reparto y desaparece de esta función. Un parámetro que
-- hace dos cosas es un parámetro que se acaba usando mal.
--
-- CÓMO SE PIDEN LOS FILTROS: p_responsables es un jsonb con el papel como
-- clave y, como valor, 'nadie' o el id de la persona.
--
--     {"VENDEDOR": "nadie", "COBRADOR": "37"}
--     -> los que no tienen vendedor y los cobra el usuario 37
--
-- Un papel que no está en el jsonb no filtra. Se eligió jsonb y no ocho
-- parámetros sueltos porque ocho parámetros en posición son ocho ocasiones de
-- cruzarlos sin que nadie se entere.
--
-- LAS OPCIONES DE CADA DESPLEGABLE SE CRUZAN AL REVÉS: las de zona se
-- calculan con los filtros de responsable puestos, y las de responsable con
-- los de zona puestos. Así cada grupo refleja lo que el otro ya recortó y
-- ninguno se queda ofreciendo algo que daría cero.
--
-- SE SUELTA LA FUNCIÓN ANTES DE CREARLA: cambian los parámetros, y
-- CREATE OR REPLACE con otra firma no reemplaza, crea una segunda.
--
-- Idempotente.
-- ===========================================================================

DROP FUNCTION IF EXISTS ventas.fn_clientes_asignacion_listar(integer, integer, text, text, varchar, bigint, boolean, text, text, text, boolean, bigint);

CREATE OR REPLACE FUNCTION ventas.fn_clientes_asignacion_listar(
    p_page            integer DEFAULT 1,
    p_per_page        integer DEFAULT 20,
    p_search          text    DEFAULT ''::text,
    p_estado          text    DEFAULT NULL,
    -- {"VENDEDOR":"nadie","COBRADOR":"37"} — el papel que no esté, no filtra
    p_responsables    jsonb   DEFAULT '{}'::jsonb,
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

    v_offset     integer;
    v_filtro     text;
    v_estado     text;
    v_provincia  text;
    v_canton     text;
    v_parroquia  text;
    v_ve_todo    boolean := false;
    v_usuarios   bigint[] := '{}'::bigint[];

    -- Un par por papel: el modo ('nadie' / 'persona' / NULL = no filtra) y
    -- el id cuando es una persona. Resueltos UNA vez, no dentro del WHERE.
    v_mod_ven text; v_id_ven bigint;
    v_mod_cob text; v_id_cob bigint;
    v_mod_asi text; v_id_asi bigint;
    v_mod_pos text; v_id_pos bigint;
    v_crudo   text;

    v_total      bigint;
    v_data       jsonb;
    v_ids        jsonb;
    v_provincias jsonb;
    v_cantones   jsonb;
    v_parroquias jsonb;
    v_quienes    jsonb;
    v_truncados  boolean := false;
BEGIN
    v_offset    := (GREATEST(p_page, 1) - 1) * GREATEST(p_per_page, 1);
    v_filtro    := NULLIF(TRIM(COALESCE(p_search, '')), '');
    v_estado    := NULLIF(TRIM(UPPER(COALESCE(p_estado, ''))), '');
    v_provincia := NULLIF(TRIM(COALESCE(p_provincia, '')), '');
    v_canton    := NULLIF(TRIM(COALESCE(p_canton, '')), '');
    v_parroquia := NULLIF(TRIM(COALESCE(p_parroquia, '')), '');

    -- ---------------- los cuatro filtros de responsable ----------------
    -- Se repite cuatro veces a conciencia: un bucle exigiría armar el WHERE
    -- con SQL dinámico, y eso es mucho peor de leer y de auditar que esto.
    v_crudo := NULLIF(TRIM(COALESCE(p_responsables->>'VENDEDOR', '')), '');
    IF v_crudo IS NOT NULL THEN
        IF LOWER(v_crudo) = 'nadie' THEN v_mod_ven := 'nadie';
        ELSE v_mod_ven := 'persona'; v_id_ven := v_crudo::bigint; END IF;
    END IF;

    v_crudo := NULLIF(TRIM(COALESCE(p_responsables->>'COBRADOR', '')), '');
    IF v_crudo IS NOT NULL THEN
        IF LOWER(v_crudo) = 'nadie' THEN v_mod_cob := 'nadie';
        ELSE v_mod_cob := 'persona'; v_id_cob := v_crudo::bigint; END IF;
    END IF;

    v_crudo := NULLIF(TRIM(COALESCE(p_responsables->>'ASISTENTE', '')), '');
    IF v_crudo IS NOT NULL THEN
        IF LOWER(v_crudo) = 'nadie' THEN v_mod_asi := 'nadie';
        ELSE v_mod_asi := 'persona'; v_id_asi := v_crudo::bigint; END IF;
    END IF;

    v_crudo := NULLIF(TRIM(COALESCE(p_responsables->>'POSTVENTA', '')), '');
    IF v_crudo IS NOT NULL THEN
        IF LOWER(v_crudo) = 'nadie' THEN v_mod_pos := 'nadie';
        ELSE v_mod_pos := 'persona'; v_id_pos := v_crudo::bigint; END IF;
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

    -- UNA sola sentencia: la cuenta, la página, los ids y todos los
    -- desplegables salen del mismo sitio, así no pueden discrepar. Sin tabla
    -- temporal a propósito: esta función es STABLE —no escribe nada— y crear
    -- una tabla la convertiría en una función que escribe.
    WITH base AS (
        SELECT c.id, c.nombre_completo, c.numero_identificacion, c.tipo_cliente,
               c.celular, c.estado, c.provincia, c.canton, c.parroquia,
               c.coordenadas, c.link_coordenadas,
               -- Los cuatro, de una pasada. El vendedor vive en la ficha y
               -- los otros tres en la última asignación de su papel; esa
               -- diferencia la esconde fn_cliente_responsable_actual.
               ventas.fn_cliente_responsable_actual(c.id, 'VENDEDOR')  AS vendedor_id,
               ventas.fn_cliente_responsable_actual(c.id, 'COBRADOR')  AS cobrador_id,
               ventas.fn_cliente_responsable_actual(c.id, 'ASISTENTE') AS asistente_id,
               ventas.fn_cliente_responsable_actual(c.id, 'POSTVENTA') AS postventa_id
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
    -- Sólo la zona. Sobre esto se calculan los desplegables de PERSONAS, para
    -- que al acotar a Manta se ofrezca quién atiende en Manta.
    por_zona AS (
        SELECT b.* FROM base b
         WHERE (v_provincia IS NULL OR b.provincia = v_provincia)
           AND (v_canton    IS NULL OR b.canton    = v_canton)
           AND (v_parroquia IS NULL OR b.parroquia = v_parroquia)
           AND (p_con_coordenadas IS NULL
                OR (p_con_coordenadas AND NULLIF(TRIM(COALESCE(b.coordenadas, '')), '') IS NOT NULL)
                OR (NOT p_con_coordenadas AND NULLIF(TRIM(COALESCE(b.coordenadas, '')), '') IS NULL))
    ),
    -- Sólo los responsables. Sobre esto se calculan los desplegables de ZONA,
    -- para que al pedir «sin cobrador» salgan las provincias que tienen
    -- clientes sin cobrador.
    por_responsable AS (
        SELECT b.* FROM base b
         WHERE (v_mod_ven IS NULL
                OR (v_mod_ven = 'nadie'   AND b.vendedor_id IS NULL)
                OR (v_mod_ven = 'persona' AND b.vendedor_id = v_id_ven))
           AND (v_mod_cob IS NULL
                OR (v_mod_cob = 'nadie'   AND b.cobrador_id IS NULL)
                OR (v_mod_cob = 'persona' AND b.cobrador_id = v_id_cob))
           AND (v_mod_asi IS NULL
                OR (v_mod_asi = 'nadie'   AND b.asistente_id IS NULL)
                OR (v_mod_asi = 'persona' AND b.asistente_id = v_id_asi))
           AND (v_mod_pos IS NULL
                OR (v_mod_pos = 'nadie'   AND b.postventa_id IS NULL)
                OR (v_mod_pos = 'persona' AND b.postventa_id = v_id_pos))
    ),
    -- Lo que de verdad se enseña: las dos cosas a la vez
    filtrados AS (
        SELECT z.* FROM por_zona z
         WHERE z.id IN (SELECT r.id FROM por_responsable r)
    ),
    pagina AS (
        SELECT f.* FROM filtrados f
         ORDER BY f.id DESC
         LIMIT GREATEST(p_per_page, 1) OFFSET v_offset
    ),
    -- Quién atiende algo dentro de la zona elegida, con su papel. De aquí
    -- salen los cuatro desplegables de personas.
    quienes AS (
        SELECT 'VENDEDOR'::text AS rol, z.vendedor_id  AS uid FROM por_zona z WHERE z.vendedor_id  IS NOT NULL
        UNION ALL
        SELECT 'COBRADOR',            z.cobrador_id         FROM por_zona z WHERE z.cobrador_id  IS NOT NULL
        UNION ALL
        SELECT 'ASISTENTE',           z.asistente_id        FROM por_zona z WHERE z.asistente_id IS NOT NULL
        UNION ALL
        SELECT 'POSTVENTA',           z.postventa_id        FROM por_zona z WHERE z.postventa_id IS NOT NULL
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
                'vendedor_id',           t.vendedor_id,
                'vendedor_nombre',       ventas.fn_nombre_usuario(t.vendedor_id),
                'cobrador_id',           t.cobrador_id,
                'cobrador_nombre',       ventas.fn_nombre_usuario(t.cobrador_id),
                'asistente_id',          t.asistente_id,
                'asistente_nombre',      ventas.fn_nombre_usuario(t.asistente_id),
                'postventa_id',          t.postventa_id,
                'postventa_nombre',      ventas.fn_nombre_usuario(t.postventa_id),
                -- Lo que se movería con él si se marca «llevarse la agenda»
                'pendientes',            (SELECT COUNT(*) FROM ventas.gestiones g
                                           WHERE g.cliente_id = t.id AND g.estado = 'PENDIENTE')
            ) ORDER BY t.id DESC), '[]'::jsonb)
           FROM pagina t),

        (SELECT COALESCE(jsonb_agg(z.id ORDER BY z.id DESC), '[]'::jsonb)
           FROM (SELECT f.id FROM filtrados f ORDER BY f.id DESC LIMIT c_tope_ids) z),

        -- ---- zona, en cascada y con los filtros de responsable puestos ----
        (SELECT COALESCE(jsonb_agg(jsonb_build_object('valor', x.v, 'clientes', x.n) ORDER BY x.v), '[]'::jsonb)
           FROM (SELECT r.provincia AS v, COUNT(*) AS n FROM por_responsable r
                  WHERE r.provincia IS NOT NULL GROUP BY r.provincia) x),

        (SELECT COALESCE(jsonb_agg(jsonb_build_object('valor', x.v, 'clientes', x.n) ORDER BY x.v), '[]'::jsonb)
           FROM (SELECT r.canton AS v, COUNT(*) AS n FROM por_responsable r
                  WHERE r.canton IS NOT NULL
                    AND (v_provincia IS NULL OR r.provincia = v_provincia)
                  GROUP BY r.canton) x),

        (SELECT COALESCE(jsonb_agg(jsonb_build_object('valor', x.v, 'clientes', x.n) ORDER BY x.v), '[]'::jsonb)
           FROM (SELECT r.parroquia AS v, COUNT(*) AS n FROM por_responsable r
                  WHERE r.parroquia IS NOT NULL
                    AND (v_provincia IS NULL OR r.provincia = v_provincia)
                    AND (v_canton    IS NULL OR r.canton    = v_canton)
                  GROUP BY r.parroquia) x),

        -- ---- las personas de cada papel, dentro de la zona elegida ----
        (SELECT COALESCE(jsonb_object_agg(y.rol, y.gente), '{}'::jsonb)
           FROM (SELECT q.rol,
                        jsonb_agg(jsonb_build_object(
                            'id',       q.uid,
                            'etiqueta', ventas.fn_nombre_usuario(q.uid),
                            'clientes', q.n) ORDER BY ventas.fn_nombre_usuario(q.uid)) AS gente
                   FROM (SELECT rol, uid, COUNT(*) AS n FROM quienes GROUP BY rol, uid) q
                  GROUP BY q.rol) y)

      INTO v_total, v_data, v_ids, v_provincias, v_cantones, v_parroquias, v_quienes;

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
                'ids',           v_ids,
                'ids_truncados', v_truncados,
                'filtros',       jsonb_build_object(
                    'provincias',   v_provincias,
                    'cantones',     v_cantones,
                    'parroquias',   v_parroquias,
                    'responsables', COALESCE(v_quienes, '{}'::jsonb)
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

COMMENT ON FUNCTION ventas.fn_clientes_asignacion_listar(integer, integer, text, text, jsonb, text, text, text, boolean, bigint)
    IS 'Clientes para el reparto: los cuatro responsables en columnas, un filtro por cada uno, zona en cascada y todos los ids del filtro';


-- ---------------------------------------------------------------------------
-- COMPROBACIÓN
-- ---------------------------------------------------------------------------
-- Que no quedó una sobrecarga
SELECT COUNT(*) AS versiones_de_la_funcion
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname = 'ventas' AND p.proname = 'fn_clientes_asignacion_listar';

-- La pregunta que antes no se podía hacer: con vendedor pero sin cobrador
SELECT (ventas.fn_clientes_asignacion_listar(
            1, 1, '', NULL,
            '{"COBRADOR":"nadie"}'::jsonb,
            NULL, NULL, NULL, NULL,
            (SELECT id FROM seguridad.users WHERE login_user = 'LAGILA')
        ) -> 'data' -> 'meta' ->> 'total') AS sin_cobrador;
