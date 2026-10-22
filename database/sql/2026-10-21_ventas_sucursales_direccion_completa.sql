-- ===========================================================================
-- LA DIRECCIÓN ESCRITA A MANO: ventas.sucursales.direccion_completa
-- ===========================================================================
-- `direccion` la escribe Google: es la que devuelve al buscar o al pulsar el
-- mapa, y sirve para volver a encontrar el sitio. Pero «Av. Fray Vicente
-- Solano, Cuenca» no le dice a nadie por dónde se entra.
--
-- `direccion_completa` es para eso: la escribe la persona, con las
-- referencias de aquí —«frente al parque, junto a la farmacia, edificio azul,
-- segundo piso»—, y NINGUNA pantalla la sobrescribe con lo que diga Google.
--
-- Se aplica sobre 2026-10-20_ventas_sucursales_fotos.sql.
\set ON_ERROR_STOP on

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. LA COLUMNA
-- ---------------------------------------------------------------------------
ALTER TABLE ventas.sucursales
    ADD COLUMN IF NOT EXISTS direccion_completa varchar(500);

COMMENT ON COLUMN ventas.sucursales.direccion_completa IS
    'Dirección con referencias, escrita a mano. Google nunca la toca (eso es `direccion`)';

-- ---------------------------------------------------------------------------
-- 2. EL JSON QUE VE LA PANTALLA
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ventas.fn_sucursales_json(p_id bigint)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
AS $function$
    SELECT jsonb_build_object(
        'id',                 s.id,
        'codigo',             s.codigo,
        'nombre',             s.nombre,
        'direccion',          s.direccion,
        'direccion_completa', s.direccion_completa,
        'telefono',           s.telefono,
        'email',              s.email,

        'tipo',              s.tipo,
        'color',             s.color,
        'vertices',          s.vertices,
        'centro_lat',        s.centro_lat,
        'centro_lng',        s.centro_lng,
        'radio_metros',      s.radio_metros,
        'tolerancia_metros', s.tolerancia_metros,

        -- El punto, su enlace y lo que se enseña en la rejilla
        'latitud',           s.latitud,
        'longitud',          s.longitud,
        'link_ubicacion',    s.link_ubicacion,
        'coordenadas',       CASE WHEN s.latitud IS NULL THEN NULL
                                  ELSE to_char(s.latitud,  'FM999990.000000') || ', '
                                    || to_char(s.longitud, 'FM999990.000000') END,

        -- Las fotos: el nombre del fichero y un sí/no para la rejilla
        'foto',              s.foto,
        'mapa_foto',         s.mapa_foto,
        'tiene_foto',        s.foto IS NOT NULL,
        'tiene_mapa',        s.mapa_foto IS NOT NULL,

        -- Lo que la rejilla necesita sin tener que mirar el polígono
        'tiene_perimetro',   (s.tipo = 'POLIGONO' AND s.vertices IS NOT NULL AND jsonb_array_length(s.vertices) >= 3)
                             OR (s.tipo = 'CIRCULO' AND s.centro_lat IS NOT NULL AND s.radio_metros IS NOT NULL),
        'num_vertices',      CASE WHEN s.vertices IS NULL THEN 0 ELSE jsonb_array_length(s.vertices) END,
        'num_empleados',     (SELECT COUNT(*) FROM rh.empleados e WHERE e.sucursal_id = s.id),

        'activo',            s.activo,
        'estado',            CASE WHEN s.activo THEN 'Activa' ELSE 'Inactiva' END,

        'deleted_at',        to_char(s.deleted_at, 'YYYY-MM-DD HH24:MI:SS'),
        'deleted_by',        s.deleted_by,
        'created_by',        s.created_by,
        'updated_by',        s.updated_by,
        'created_at',        to_char(s.created_at, 'YYYY-MM-DD HH24:MI:SS'),
        'updated_at',        to_char(s.updated_at, 'YYYY-MM-DD HH24:MI:SS')
    )
      FROM ventas.sucursales s
     WHERE s.id = p_id;
$function$;

-- ---------------------------------------------------------------------------
-- 3. CREAR Y MODIFICAR
-- ---------------------------------------------------------------------------
-- Se tiran y se vuelven a crear porque cambian los parámetros: con
-- CREATE OR REPLACE quedarían DOS versiones y la llamada sería ambigua.
-- El parámetro nuevo va JUNTO a p_direccion, que es su sitio; quien lee la
-- firma ve las dos direcciones seguidas y entiende para qué es cada una.
DROP FUNCTION IF EXISTS ventas.fn_sucursales_crear(varchar, varchar, varchar, varchar, varchar, varchar, varchar, jsonb, numeric, numeric, numeric, numeric, boolean, numeric, numeric, bigint, varchar, varchar, inet, text, uuid);

CREATE OR REPLACE FUNCTION ventas.fn_sucursales_crear(
    p_codigo             varchar,
    p_nombre             varchar,
    p_direccion          varchar DEFAULT NULL,   -- la que escribe Google
    p_direccion_completa varchar DEFAULT NULL,   -- la que escribe la persona
    p_telefono           varchar DEFAULT NULL,
    p_email              varchar DEFAULT NULL,
    p_tipo               varchar DEFAULT 'POLIGONO',
    p_color              varchar DEFAULT '#348FE2',
    p_vertices           jsonb   DEFAULT NULL,
    p_centro_lat         numeric DEFAULT NULL,
    p_centro_lng         numeric DEFAULT NULL,
    p_radio_metros       numeric DEFAULT NULL,
    p_tolerancia         numeric DEFAULT 50,
    p_activo             boolean DEFAULT true,
    p_latitud            numeric DEFAULT NULL,   -- el punto de la sucursal
    p_longitud           numeric DEFAULT NULL,
    p_usuario_id         bigint  DEFAULT NULL,
    p_usuario_login      varchar DEFAULT NULL,
    p_usuario_nombre     varchar DEFAULT NULL,
    p_ip_address         inet    DEFAULT NULL,
    p_user_agent         text    DEFAULT NULL,
    p_request_id         uuid    DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'ventas', 'auditoria'
AS $function$
DECLARE
    v_id    bigint;
    v_tipo  varchar(10) := UPPER(COALESCE(p_tipo, 'POLIGONO'));
    v_min_lat numeric; v_max_lat numeric; v_min_lng numeric; v_max_lng numeric;
    v_dlat numeric; v_dlng numeric;
    v_punto numeric[];
BEGIN
    PERFORM ventas.fn_contexto_auditoria('ventas.sucursales',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    PERFORM ventas.fn_sucursales_validar(NULL, p_codigo, p_nombre, v_tipo,
                                         p_vertices, p_centro_lat, p_centro_lng, p_radio_metros,
                                         p_latitud, p_longitud);

    -- Los extremos: con ellos se descarta de un vistazo lo que ni se acerca
    IF v_tipo = 'POLIGONO' AND p_vertices IS NOT NULL THEN
        SELECT MIN((v->>'lat')::numeric), MAX((v->>'lat')::numeric),
               MIN((v->>'lng')::numeric), MAX((v->>'lng')::numeric)
          INTO v_min_lat, v_max_lat, v_min_lng, v_max_lng
          FROM jsonb_array_elements(p_vertices) AS v;
    ELSIF v_tipo = 'CIRCULO' AND p_centro_lat IS NOT NULL AND p_radio_metros IS NOT NULL THEN
        v_dlat := p_radio_metros / 111320.0;
        v_dlng := p_radio_metros / (111320.0 * GREATEST(cos(radians(p_centro_lat)), 0.000001));
        v_min_lat := GREATEST(p_centro_lat - v_dlat, -90);
        v_max_lat := LEAST   (p_centro_lat + v_dlat,  90);
        v_min_lng := GREATEST(p_centro_lng - v_dlng, -180);
        v_max_lng := LEAST   (p_centro_lng + v_dlng,  180);
    END IF;

    v_punto := ventas.fn_sucursales_punto(p_latitud, p_longitud, v_tipo,
                                          p_vertices, p_centro_lat, p_centro_lng);

    INSERT INTO ventas.sucursales (
        codigo, nombre, direccion, direccion_completa, telefono, email,
        tipo, color, vertices, centro_lat, centro_lng, radio_metros,
        min_lat, max_lat, min_lng, max_lng, tolerancia_metros, activo,
        latitud, longitud, link_ubicacion)
    VALUES (
        UPPER(TRIM(p_codigo)), TRIM(p_nombre),
        NULLIF(TRIM(COALESCE(p_direccion, '')), ''),
        NULLIF(TRIM(COALESCE(p_direccion_completa, '')), ''),
        NULLIF(TRIM(COALESCE(p_telefono, '')), ''),
        NULLIF(TRIM(COALESCE(p_email, '')), ''),
        v_tipo, COALESCE(NULLIF(TRIM(COALESCE(p_color, '')), ''), '#348FE2'),
        CASE WHEN v_tipo = 'POLIGONO' THEN p_vertices END,
        CASE WHEN v_tipo = 'CIRCULO'  THEN p_centro_lat END,
        CASE WHEN v_tipo = 'CIRCULO'  THEN p_centro_lng END,
        CASE WHEN v_tipo = 'CIRCULO'  THEN p_radio_metros END,
        v_min_lat, v_max_lat, v_min_lng, v_max_lng,
        COALESCE(p_tolerancia, 50), COALESCE(p_activo, true),
        v_punto[1], v_punto[2], ventas.fn_sucursales_link(v_punto[1], v_punto[2]))
    RETURNING id INTO v_id;

    RETURN jsonb_build_object('success', true, 'message', 'Sucursal creada exitosamente',
                              'data', ventas.fn_sucursales_json(v_id));

EXCEPTION
    WHEN unique_violation THEN
        RAISE EXCEPTION 'Ya existe una sucursal con ese código o ese nombre' USING ERRCODE = 'P0006';
END;
$function$;

DROP FUNCTION IF EXISTS ventas.fn_sucursales_modificar(bigint, varchar, varchar, varchar, varchar, varchar, varchar, varchar, jsonb, numeric, numeric, numeric, numeric, boolean, numeric, numeric, bigint, varchar, varchar, inet, text, uuid);

CREATE OR REPLACE FUNCTION ventas.fn_sucursales_modificar(
    p_id                 bigint,
    p_codigo             varchar,
    p_nombre             varchar,
    p_direccion          varchar DEFAULT NULL,
    p_direccion_completa varchar DEFAULT NULL,
    p_telefono           varchar DEFAULT NULL,
    p_email              varchar DEFAULT NULL,
    p_tipo               varchar DEFAULT 'POLIGONO',
    p_color              varchar DEFAULT '#348FE2',
    p_vertices           jsonb   DEFAULT NULL,
    p_centro_lat         numeric DEFAULT NULL,
    p_centro_lng         numeric DEFAULT NULL,
    p_radio_metros       numeric DEFAULT NULL,
    p_tolerancia         numeric DEFAULT 50,
    p_activo             boolean DEFAULT true,
    p_latitud            numeric DEFAULT NULL,
    p_longitud           numeric DEFAULT NULL,
    p_usuario_id         bigint  DEFAULT NULL,
    p_usuario_login      varchar DEFAULT NULL,
    p_usuario_nombre     varchar DEFAULT NULL,
    p_ip_address         inet    DEFAULT NULL,
    p_user_agent         text    DEFAULT NULL,
    p_request_id         uuid    DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'ventas', 'auditoria'
AS $function$
DECLARE
    v_antes jsonb;
    v_tipo  varchar(10) := UPPER(COALESCE(p_tipo, 'POLIGONO'));
    v_min_lat numeric; v_max_lat numeric; v_min_lng numeric; v_max_lng numeric;
    v_dlat numeric; v_dlng numeric;
    v_punto numeric[];
BEGIN
    PERFORM ventas.fn_contexto_auditoria('ventas.sucursales',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    v_antes := ventas.fn_sucursales_json(p_id);
    IF v_antes IS NULL THEN
        RAISE EXCEPTION 'La sucursal no existe' USING ERRCODE = 'P0013';
    END IF;

    PERFORM ventas.fn_sucursales_validar(p_id, p_codigo, p_nombre, v_tipo,
                                         p_vertices, p_centro_lat, p_centro_lng, p_radio_metros,
                                         p_latitud, p_longitud);

    IF v_tipo = 'POLIGONO' AND p_vertices IS NOT NULL THEN
        SELECT MIN((v->>'lat')::numeric), MAX((v->>'lat')::numeric),
               MIN((v->>'lng')::numeric), MAX((v->>'lng')::numeric)
          INTO v_min_lat, v_max_lat, v_min_lng, v_max_lng
          FROM jsonb_array_elements(p_vertices) AS v;
    ELSIF v_tipo = 'CIRCULO' AND p_centro_lat IS NOT NULL AND p_radio_metros IS NOT NULL THEN
        v_dlat := p_radio_metros / 111320.0;
        v_dlng := p_radio_metros / (111320.0 * GREATEST(cos(radians(p_centro_lat)), 0.000001));
        v_min_lat := GREATEST(p_centro_lat - v_dlat, -90);
        v_max_lat := LEAST   (p_centro_lat + v_dlat,  90);
        v_min_lng := GREATEST(p_centro_lng - v_dlng, -180);
        v_max_lng := LEAST   (p_centro_lng + v_dlng,  180);
    END IF;

    v_punto := ventas.fn_sucursales_punto(p_latitud, p_longitud, v_tipo,
                                          p_vertices, p_centro_lat, p_centro_lng);

    UPDATE ventas.sucursales
       SET codigo        = UPPER(TRIM(p_codigo)),
           nombre        = TRIM(p_nombre),
           direccion     = NULLIF(TRIM(COALESCE(p_direccion, '')), ''),
           direccion_completa = NULLIF(TRIM(COALESCE(p_direccion_completa, '')), ''),
           telefono      = NULLIF(TRIM(COALESCE(p_telefono, '')), ''),
           email         = NULLIF(TRIM(COALESCE(p_email, '')), ''),
           tipo          = v_tipo,
           color         = COALESCE(NULLIF(TRIM(COALESCE(p_color, '')), ''), '#348FE2'),
           vertices      = CASE WHEN v_tipo = 'POLIGONO' THEN p_vertices END,
           centro_lat    = CASE WHEN v_tipo = 'CIRCULO'  THEN p_centro_lat END,
           centro_lng    = CASE WHEN v_tipo = 'CIRCULO'  THEN p_centro_lng END,
           radio_metros  = CASE WHEN v_tipo = 'CIRCULO'  THEN p_radio_metros END,
           min_lat = v_min_lat, max_lat = v_max_lat,
           min_lng = v_min_lng, max_lng = v_max_lng,
           tolerancia_metros = COALESCE(p_tolerancia, 50),
           activo        = COALESCE(p_activo, true),
           latitud        = v_punto[1],
           longitud       = v_punto[2],
           link_ubicacion = ventas.fn_sucursales_link(v_punto[1], v_punto[2])
     WHERE id = p_id;

    RETURN jsonb_build_object('success', true, 'message', 'Sucursal actualizada exitosamente',
                              'data', ventas.fn_sucursales_json(p_id));

EXCEPTION
    WHEN unique_violation THEN
        RAISE EXCEPTION 'Ya existe otra sucursal con ese código o ese nombre' USING ERRCODE = 'P0006';
END;
$function$;

-- ---------------------------------------------------------------------------
-- 4. EL BUSCADOR DEL LISTADO TAMBIÉN MIRA AHÍ
-- ---------------------------------------------------------------------------
-- Quien busca «junto al parque» lo escribió en esta columna, no en la de
-- Google: si el buscador no la mira, la referencia no sirve para encontrar
-- nada. El filtro de columna NO se toca (no hay columna nueva en la rejilla).
CREATE OR REPLACE FUNCTION ventas.fn_sucursales_listar_paginado(p_page integer DEFAULT 1, p_per_page integer DEFAULT 15, p_search text DEFAULT ''::text, p_filtros jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'ventas', 'rh'
AS $function$
DECLARE
    v_offset integer;
    v_total  bigint;
    v_data   jsonb;
    v_filtro text;
BEGIN
    v_offset := (GREATEST(p_page, 1) - 1) * GREATEST(p_per_page, 1);
    v_filtro := NULLIF(TRIM(COALESCE(p_search, '')), '');

    WITH filtradas AS (
        SELECT s.id, s.nombre
          FROM ventas.sucursales s
         WHERE s.deleted_at IS NULL            -- lo de la papelera no sale
           AND (v_filtro IS NULL
                OR s.nombre    ILIKE '%' || v_filtro || '%'
                OR s.codigo    ILIKE '%' || v_filtro || '%'
                OR s.direccion ILIKE '%' || v_filtro || '%'
                -- La escrita a mano también: quien busca «junto al parque» lo
                -- escribió ahí, no en la que devuelve Google
                OR s.direccion_completa ILIKE '%' || v_filtro || '%'
                OR s.telefono  ILIKE '%' || v_filtro || '%'
                OR s.email     ILIKE '%' || v_filtro || '%'
                OR s.id::text  ILIKE '%' || v_filtro || '%')

           -- ---------- LOS FILTROS DE LA CABECERA ----------
           -- Se filtra por lo que SE VE: el estado por su palabra y el
           -- perímetro por «Sí»/«No».
           AND (p_filtros->'id'        IS NULL OR ventas.fn_filtro_numero(s.id,        p_filtros->'id'))
           AND (p_filtros->'codigo'    IS NULL OR ventas.fn_filtro_texto(s.codigo,     p_filtros->'codigo'))
           AND (p_filtros->'nombre'    IS NULL OR ventas.fn_filtro_texto(s.nombre,     p_filtros->'nombre'))
           AND (p_filtros->'direccion' IS NULL OR ventas.fn_filtro_texto(s.direccion,  p_filtros->'direccion'))
           AND (p_filtros->'telefono'  IS NULL OR ventas.fn_filtro_texto(s.telefono,   p_filtros->'telefono'))
           AND (p_filtros->'email'     IS NULL OR ventas.fn_filtro_texto(s.email,      p_filtros->'email'))
           AND (p_filtros->'estado'    IS NULL OR ventas.fn_filtro_texto(
                   CASE WHEN s.activo THEN 'Activa' ELSE 'Inactiva' END, p_filtros->'estado'))
           AND (p_filtros->'tiene_perimetro' IS NULL OR ventas.fn_filtro_texto(
                   CASE WHEN (s.tipo = 'POLIGONO' AND s.vertices IS NOT NULL AND jsonb_array_length(s.vertices) >= 3)
                             OR (s.tipo = 'CIRCULO' AND s.centro_lat IS NOT NULL AND s.radio_metros IS NOT NULL)
                        THEN 'Sí' ELSE 'No' END, p_filtros->'tiene_perimetro'))
           AND (p_filtros->'num_empleados' IS NULL OR ventas.fn_filtro_numero(
                   (SELECT COUNT(*) FROM rh.empleados e WHERE e.sucursal_id = s.id), p_filtros->'num_empleados'))
           AND (p_filtros->'created_by' IS NULL OR ventas.fn_filtro_texto(s.created_by, p_filtros->'created_by'))
           AND (p_filtros->'updated_by' IS NULL OR ventas.fn_filtro_texto(s.updated_by, p_filtros->'updated_by'))
           -- Las fechas, como texto sobre lo que se ve: «2026-10» busca el mes
           AND (p_filtros->'created_at' IS NULL OR ventas.fn_filtro_texto(
                   to_char(s.created_at, 'YYYY-MM-DD HH24:MI:SS'), p_filtros->'created_at'))
           AND (p_filtros->'updated_at' IS NULL OR ventas.fn_filtro_texto(
                   to_char(s.updated_at, 'YYYY-MM-DD HH24:MI:SS'), p_filtros->'updated_at'))
    )
    SELECT COUNT(*),
           COALESCE((SELECT jsonb_agg(ventas.fn_sucursales_json(t.id) ORDER BY t.nombre)
                       FROM (SELECT f.id, f.nombre FROM filtradas f
                              ORDER BY f.nombre
                              LIMIT GREATEST(p_per_page, 1) OFFSET v_offset) t), '[]'::jsonb)
      INTO v_total, v_data
      FROM filtradas;

    RETURN jsonb_build_object(
        'data', v_data,
        'meta', jsonb_build_object(
            'total',        v_total,
            'per_page',     GREATEST(p_per_page, 1),
            'current_page', GREATEST(p_page, 1),
            'last_page',    CASE WHEN v_total = 0 THEN 1
                                 ELSE ceil(v_total::numeric / GREATEST(p_per_page, 1)) END
        )
    );

EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false,
                              'message', 'Error al listar sucursales: ' || SQLERRM,
                              'error_code', SQLSTATE);
END;
$function$;

COMMIT;
