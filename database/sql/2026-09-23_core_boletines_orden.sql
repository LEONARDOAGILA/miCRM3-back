-- ===========================================================================
-- BOLETINES: «prioridad» pasa a ser «orden»
--
-- La prioridad (mayor primero) casi no se usaba y obligaba a pensar al revés.
-- En su lugar queda una posición que se cambia arrastrando la fila en la
-- grilla, como en el administrador de archivos: menor primero.
--
--   psql -h 192.168.2.173 -U postgres -d crm3 -f 2026-09-23_core_boletines_orden.sql
-- ===========================================================================

ALTER TABLE core.boletines RENAME COLUMN prioridad TO orden;
ALTER TABLE core.boletines ALTER COLUMN orden TYPE integer;
ALTER TABLE core.boletines ALTER COLUMN orden SET DEFAULT 0;

-- Lo que había: se respeta el orden en que se venían mostrando
WITH puestos AS (
    SELECT id, row_number() OVER (ORDER BY orden DESC, desde DESC, id DESC) AS puesto
      FROM core.boletines
)
UPDATE core.boletines b SET orden = p.puesto FROM puestos p WHERE p.id = b.id;

COMMENT ON COLUMN core.boletines.orden IS 'Posición en la lista y en el carrusel: el menor se muestra primero';

-- ---------------------------------------------------------------------------
-- Las funciones que miraban la prioridad
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION core.fn_boletines_json(p_id bigint)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
AS $function$
    SELECT jsonb_build_object(
        'id',            b.id,
        'titulo',        b.titulo,
        'descripcion',   b.descripcion,
        'desde',         to_char(b.desde, 'YYYY-MM-DD'),
        'hasta',         to_char(b.hasta, 'YYYY-MM-DD'),
        'orden',         b.orden,
        'obligatorio',   b.obligatorio,
        'activo',        b.activo,
        'vigente',       (b.activo AND CURRENT_DATE BETWEEN b.desde AND b.hasta),
        'estado',        CASE WHEN NOT b.activo               THEN 'INACTIVO'
                              WHEN CURRENT_DATE < b.desde     THEN 'PROGRAMADO'
                              WHEN CURRENT_DATE > b.hasta     THEN 'CADUCADO'
                              ELSE 'VIGENTE' END,
        'en_papelera',   (b.deleted_at IS NOT NULL),
        -- Para la papelera: cuándo y quién lo eliminó
        'deleted_at',    to_char(b.deleted_at, 'YYYY-MM-DD HH24:MI'),
        'deleted_by',    b.deleted_by,
        'imagenes',      COALESCE((
                            SELECT jsonb_agg(jsonb_build_object(
                                     'id', i.id, 'archivo', i.archivo, 'titulo', i.titulo,
                                     'descripcion', i.descripcion, 'orden', i.orden,
                                     'segundos', i.segundos, 'tipo', i.tipo
                                   ) ORDER BY i.orden, i.id)
                              FROM core.boletines_imagenes i WHERE i.boletin_id = b.id), '[]'::jsonb),
        'usuarios',      COALESCE((
                            SELECT jsonb_agg(jsonb_build_object(
                                     'user_id', u.id, 'login_user', u.login_user,
                                     'name', u.name, 'surname', u.surname, 'isactive', u.isactive
                                   ) ORDER BY u.login_user)
                              FROM core.boletines_usuarios bu
                              JOIN seguridad.users u ON u.id = bu.user_id AND u.deleted_at IS NULL
                             WHERE bu.boletin_id = b.id), '[]'::jsonb),
        'grupos',        COALESCE((
                            SELECT jsonb_agg(jsonb_build_object(
                                     'grupo_id', g.id, 'nombre', g.nombre,
                                     'incluir_subgrupos', bg.incluir_subgrupos
                                   ) ORDER BY g.nombre)
                              FROM core.boletines_grupos bg
                              JOIN seguridad.grupos g ON g.id = bg.grupo_id
                             WHERE bg.boletin_id = b.id), '[]'::jsonb),
        'num_imagenes',  (SELECT COUNT(*) FROM core.boletines_imagenes i WHERE i.boletin_id = b.id),
        'num_usuarios',  (SELECT COUNT(*) FROM core.boletines_usuarios bu WHERE bu.boletin_id = b.id),
        'num_grupos',    (SELECT COUNT(*) FROM core.boletines_grupos bg WHERE bg.boletin_id = b.id),
        'num_vistos',    (SELECT COUNT(*) FROM core.boletines_vistos v WHERE v.boletin_id = b.id),
        'created_by',    b.created_by,
        'updated_by',    b.updated_by,
        'created_at',    to_char(b.created_at, 'YYYY-MM-DD HH24:MI:SS'),
        'updated_at',    to_char(b.updated_at, 'YYYY-MM-DD HH24:MI:SS')
    )
    FROM core.boletines b
    WHERE b.id = p_id;
$function$;

CREATE OR REPLACE FUNCTION core.fn_boletines_listar_paginado(p_page integer DEFAULT 1, p_per_page integer DEFAULT 15, p_search text DEFAULT ''::text, p_estado text DEFAULT 'TODOS'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
    v_offset integer;
    v_total  bigint;
    v_filtro text;
    v_estado text;
    v_data   jsonb;
BEGIN
    v_offset := (GREATEST(p_page, 1) - 1) * p_per_page;
    v_filtro := NULLIF(TRIM(COALESCE(p_search, '')), '');
    v_estado := UPPER(COALESCE(NULLIF(TRIM(p_estado), ''), 'TODOS'));

    SELECT COUNT(*) INTO v_total
      FROM core.boletines b
     WHERE b.deleted_at IS NULL
       AND (v_filtro IS NULL
            OR b.titulo ILIKE '%' || v_filtro || '%'
            OR b.descripcion ILIKE '%' || v_filtro || '%'
            OR b.id::text ILIKE '%' || v_filtro || '%')
       AND (v_estado = 'TODOS'
            OR (v_estado = 'VIGENTE'    AND b.activo AND CURRENT_DATE BETWEEN b.desde AND b.hasta)
            OR (v_estado = 'PROGRAMADO' AND b.activo AND CURRENT_DATE < b.desde)
            OR (v_estado = 'CADUCADO'   AND b.activo AND CURRENT_DATE > b.hasta)
            OR (v_estado = 'INACTIVO'   AND NOT b.activo));

    SELECT COALESCE(jsonb_agg(core.fn_boletines_json(t.id) ORDER BY t.orden, t.id), '[]'::jsonb)
      INTO v_data
      FROM (
        SELECT b.id, b.orden
          FROM core.boletines b
         WHERE b.deleted_at IS NULL
           AND (v_filtro IS NULL
                OR b.titulo ILIKE '%' || v_filtro || '%'
                OR b.descripcion ILIKE '%' || v_filtro || '%'
                OR b.id::text ILIKE '%' || v_filtro || '%')
           AND (v_estado = 'TODOS'
                OR (v_estado = 'VIGENTE'    AND b.activo AND CURRENT_DATE BETWEEN b.desde AND b.hasta)
                OR (v_estado = 'PROGRAMADO' AND b.activo AND CURRENT_DATE < b.desde)
                OR (v_estado = 'CADUCADO'   AND b.activo AND CURRENT_DATE > b.hasta)
                OR (v_estado = 'INACTIVO'   AND NOT b.activo))
         ORDER BY b.orden, b.id
         LIMIT p_per_page OFFSET v_offset
      ) t;

    RETURN jsonb_build_object(
        'success', true,
        'message', 'La solicitud ha tenido éxito',
        'data', jsonb_build_object(
            'data', v_data,
            'current_page', GREATEST(p_page, 1),
            'per_page', p_per_page,
            'total', v_total,
            'last_page', GREATEST(CEIL(v_total::numeric / NULLIF(p_per_page, 0))::int, 1),
            -- Para el contador del botón de la papelera, sin pedir otra vuelta
            'en_papelera', (SELECT COUNT(*) FROM core.boletines WHERE deleted_at IS NOT NULL)
        )
    );
END;
$function$;

CREATE OR REPLACE FUNCTION core.fn_boletines_crear(p_datos jsonb, p_usuario_id bigint DEFAULT NULL::bigint, p_usuario_login character varying DEFAULT NULL::character varying, p_usuario_nombre character varying DEFAULT NULL::character varying, p_ip_address inet DEFAULT NULL::inet, p_user_agent text DEFAULT NULL::text, p_request_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_id     bigint;
    v_titulo varchar(200);
    v_desde  date;
    v_hasta  date;
BEGIN
    PERFORM core.fn_boletines_contexto_auditoria(p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    v_titulo := NULLIF(TRIM(COALESCE(p_datos->>'titulo', '')), '');
    IF v_titulo IS NULL THEN
        RAISE EXCEPTION 'El título del boletín es obligatorio' USING ERRCODE = 'P0001';
    END IF;

    v_desde := COALESCE((p_datos->>'desde')::date, CURRENT_DATE);
    v_hasta := (p_datos->>'hasta')::date;
    IF v_hasta IS NULL THEN
        RAISE EXCEPTION 'La fecha hasta la que rige el boletín es obligatoria' USING ERRCODE = 'P0001';
    END IF;
    IF v_hasta < v_desde THEN
        RAISE EXCEPTION 'La vigencia termina antes de empezar' USING ERRCODE = 'P0010';
    END IF;

    INSERT INTO core.boletines (titulo, descripcion, desde, hasta, orden, obligatorio, activo)
    VALUES (v_titulo,
            NULLIF(TRIM(COALESCE(p_datos->>'descripcion', '')), ''),
            v_desde,
            v_hasta,
            COALESCE((p_datos->>'orden')::integer,
                     (SELECT COALESCE(MAX(orden), 0) + 1 FROM core.boletines)),
            COALESCE((p_datos->>'obligatorio')::boolean, false),
            COALESCE((p_datos->>'activo')::boolean, true))
    RETURNING id INTO v_id;

    PERFORM core.fn_boletines_guardar_detalle(v_id, p_datos);

    RETURN jsonb_build_object('success', true, 'message', 'Boletín creado con éxito', 'data', core.fn_boletines_json(v_id));
END;
$function$;

CREATE OR REPLACE FUNCTION core.fn_boletines_modificar(p_id bigint, p_datos jsonb, p_usuario_id bigint DEFAULT NULL::bigint, p_usuario_login character varying DEFAULT NULL::character varying, p_usuario_nombre character varying DEFAULT NULL::character varying, p_ip_address inet DEFAULT NULL::inet, p_user_agent text DEFAULT NULL::text, p_request_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_actual core.boletines;
    v_desde  date;
    v_hasta  date;
BEGIN
    PERFORM core.fn_boletines_contexto_auditoria(p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    SELECT * INTO v_actual FROM core.boletines WHERE id = p_id AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'El boletín no existe' USING ERRCODE = 'P0013';
    END IF;

    v_desde := COALESCE((p_datos->>'desde')::date, v_actual.desde);
    v_hasta := COALESCE((p_datos->>'hasta')::date, v_actual.hasta);
    IF v_hasta < v_desde THEN
        RAISE EXCEPTION 'La vigencia termina antes de empezar' USING ERRCODE = 'P0010';
    END IF;

    UPDATE core.boletines
       SET titulo      = COALESCE(NULLIF(TRIM(COALESCE(p_datos->>'titulo', '')), ''), titulo),
           descripcion = CASE WHEN p_datos ? 'descripcion'
                              THEN NULLIF(TRIM(COALESCE(p_datos->>'descripcion', '')), '')
                              ELSE descripcion END,
           desde       = v_desde,
           hasta       = v_hasta,
           orden       = COALESCE((p_datos->>'orden')::integer, orden),
           obligatorio = COALESCE((p_datos->>'obligatorio')::boolean, obligatorio),
           activo      = COALESCE((p_datos->>'activo')::boolean, activo)
     WHERE id = p_id;

    PERFORM core.fn_boletines_guardar_detalle(p_id, p_datos);

    RETURN jsonb_build_object('success', true, 'message', 'Boletín modificado con éxito', 'data', core.fn_boletines_json(p_id));
END;
$function$;

CREATE OR REPLACE FUNCTION core.fn_boletines_mios(p_user_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE v_data jsonb;
BEGIN
    SELECT COALESCE(jsonb_agg(core.fn_boletines_json(t.id) ORDER BY t.orden, t.id), '[]'::jsonb)
      INTO v_data
      FROM (
        SELECT DISTINCT b.id, b.orden
          FROM core.boletines b
         WHERE b.deleted_at IS NULL
           AND b.activo
           AND CURRENT_DATE BETWEEN b.desde AND b.hasta
           AND EXISTS (SELECT 1 FROM core.boletines_imagenes i WHERE i.boletin_id = b.id)
           AND (
                EXISTS (SELECT 1 FROM core.boletines_usuarios bu
                         WHERE bu.boletin_id = b.id AND bu.user_id = p_user_id)
             OR EXISTS (SELECT 1 FROM core.boletines_grupos bg
                          CROSS JOIN LATERAL core.fn_boletines_usuarios_de_grupo(bg.grupo_id, bg.incluir_subgrupos) g
                         WHERE bg.boletin_id = b.id AND g.user_id = p_user_id)
               )
           AND NOT EXISTS (SELECT 1 FROM core.boletines_vistos v
                            WHERE v.boletin_id = b.id AND v.user_id = p_user_id AND v.no_mostrar)
      ) t;

    RETURN jsonb_build_object('success', true, 'message', 'La solicitud ha tenido éxito', 'data', v_data);
END;
$function$;

CREATE OR REPLACE FUNCTION core.fn_boletines_reordenar(
    p_ids bigint[],
    p_usuario_id bigint DEFAULT NULL, p_usuario_login varchar DEFAULT NULL, p_usuario_nombre varchar DEFAULT NULL,
    p_ip_address inet DEFAULT NULL, p_user_agent text DEFAULT NULL, p_request_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
AS $function$
DECLARE v_cambiados integer;
BEGIN
    PERFORM core.fn_boletines_contexto_auditoria(p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    IF p_ids IS NULL OR array_length(p_ids, 1) IS NULL THEN
        RAISE EXCEPTION 'No se recibió ningún boletín que ordenar' USING ERRCODE = 'P0001';
    END IF;

    WITH pedidos AS (
        SELECT id, ordinality AS posicion
          FROM unnest(p_ids) WITH ORDINALITY AS t(id, ordinality)
    ),
    huecos AS (
        SELECT b.orden, row_number() OVER (ORDER BY b.orden, b.id) AS posicion
          FROM core.boletines b
          JOIN pedidos p ON p.id = b.id
         WHERE b.deleted_at IS NULL
    ),
    nuevos AS (
        SELECT p.id, h.orden
          FROM pedidos p
          JOIN huecos h ON h.posicion = p.posicion
    ),
    cambios AS (
        UPDATE core.boletines b
           SET orden = n.orden
          FROM nuevos n
         WHERE b.id = n.id
           AND b.orden IS DISTINCT FROM n.orden
        RETURNING 1
    )
    SELECT COUNT(*) INTO v_cambiados FROM cambios;

    RETURN jsonb_build_object('success', true,
                              'message', CASE WHEN v_cambiados = 0 THEN 'El orden no cambió'
                                              ELSE 'Orden actualizado' END,
                              'data', jsonb_build_object('cambiados', v_cambiados));
END;
$function$;
