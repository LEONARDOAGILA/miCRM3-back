-- ===========================================================================
-- BOLETINES: el check «No volver a mostrar» se configura por boletín
--
-- Hasta ahora el visor enseñaba siempre esa casilla, así que cualquier
-- boletín se podía ocultar para siempre con un clic. Con la nueva columna
-- cada boletín decide si la ofrece: los informativos sí, los que tienen que
-- llegar a todo el mundo no.
--
-- OJO con el nombre, que se repite en dos tablas y significan cosas distintas:
--   · core.boletines.no_mostrar         → ¿este boletín OFRECE la casilla?
--   · core.boletines_vistos.no_mostrar  → este usuario YA la marcó
--
--   psql -h 192.168.2.173 -U postgres -d crm3 -f 2026-09-24_core_boletines_no_mostrar.sql
-- ===========================================================================

ALTER TABLE core.boletines
    ADD COLUMN IF NOT EXISTS no_mostrar boolean NOT NULL DEFAULT true;

COMMENT ON COLUMN core.boletines.no_mostrar IS
    'Si el visor ofrece la casilla «No volver a mostrar». Los boletines que ya existían la mantienen';


-- ---------------------------------------------------------------------------
-- El JSON que lee el front
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
        -- ¿Se le ofrece al usuario la casilla de no volver a verlo?
        'no_mostrar',    b.no_mostrar,
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


-- ---------------------------------------------------------------------------
-- Alta
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION core.fn_boletines_crear(
    p_datos jsonb,
    p_usuario_id bigint DEFAULT NULL::bigint,
    p_usuario_login character varying DEFAULT NULL::character varying,
    p_usuario_nombre character varying DEFAULT NULL::character varying,
    p_ip_address inet DEFAULT NULL::inet,
    p_user_agent text DEFAULT NULL::text,
    p_request_id uuid DEFAULT NULL::uuid
)
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

    INSERT INTO core.boletines (titulo, descripcion, desde, hasta, orden, obligatorio, no_mostrar, activo)
    VALUES (v_titulo,
            NULLIF(TRIM(COALESCE(p_datos->>'descripcion', '')), ''),
            v_desde,
            v_hasta,
            COALESCE((p_datos->>'orden')::integer,
                     (SELECT COALESCE(MAX(orden), 0) + 1 FROM core.boletines)),
            COALESCE((p_datos->>'obligatorio')::boolean, false),
            -- Si no se dice nada, se ofrece: es como venía funcionando
            COALESCE((p_datos->>'no_mostrar')::boolean, true),
            COALESCE((p_datos->>'activo')::boolean, true))
    RETURNING id INTO v_id;

    PERFORM core.fn_boletines_guardar_detalle(v_id, p_datos);

    RETURN jsonb_build_object('success', true, 'message', 'Boletín creado con éxito', 'data', core.fn_boletines_json(v_id));
END;
$function$;


-- ---------------------------------------------------------------------------
-- Modificación
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION core.fn_boletines_modificar(
    p_id bigint,
    p_datos jsonb,
    p_usuario_id bigint DEFAULT NULL::bigint,
    p_usuario_login character varying DEFAULT NULL::character varying,
    p_usuario_nombre character varying DEFAULT NULL::character varying,
    p_ip_address inet DEFAULT NULL::inet,
    p_user_agent text DEFAULT NULL::text,
    p_request_id uuid DEFAULT NULL::uuid
)
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
           no_mostrar  = COALESCE((p_datos->>'no_mostrar')::boolean, no_mostrar),
           activo      = COALESCE((p_datos->>'activo')::boolean, activo)
     WHERE id = p_id;

    PERFORM core.fn_boletines_guardar_detalle(p_id, p_datos);

    RETURN jsonb_build_object('success', true, 'message', 'Boletín modificado con éxito', 'data', core.fn_boletines_json(p_id));
END;
$function$;


-- ---------------------------------------------------------------------------
-- Registrar la lectura
--
-- Un boletín que no ofrece la casilla tampoco puede quedar oculto: si llega
-- un «no_mostrar» de un front viejo o de una petición a mano, se ignora.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION core.fn_boletines_marcar_visto(
    p_boletin_id bigint,
    p_user_id bigint,
    p_no_mostrar boolean DEFAULT false
)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_lo_ofrece  boolean;
    v_no_mostrar boolean;
BEGIN
    IF p_boletin_id IS NULL OR p_user_id IS NULL THEN
        RAISE EXCEPTION 'Faltan el boletín o el usuario' USING ERRCODE = 'P0001';
    END IF;

    SELECT b.no_mostrar INTO v_lo_ofrece
      FROM core.boletines b
     WHERE b.id = p_boletin_id AND b.deleted_at IS NULL;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'El boletín no existe' USING ERRCODE = 'P0013';
    END IF;

    v_no_mostrar := COALESCE(p_no_mostrar, false) AND COALESCE(v_lo_ofrece, true);

    INSERT INTO core.boletines_vistos (boletin_id, user_id, no_mostrar)
    VALUES (p_boletin_id, p_user_id, v_no_mostrar)
    ON CONFLICT (boletin_id, user_id) DO UPDATE
       SET visto_at   = now(),
           veces      = core.boletines_vistos.veces + 1,
           no_mostrar = core.boletines_vistos.no_mostrar OR EXCLUDED.no_mostrar;

    RETURN jsonb_build_object('success', true, 'message', 'Lectura registrada', 'data', NULL);
END;
$function$;
