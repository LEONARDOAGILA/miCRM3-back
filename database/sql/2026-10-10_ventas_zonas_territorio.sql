-- ===========================================================================
-- LAS ZONAS GUARDAN EN QUÉ PAÍS, PROVINCIA Y CANTÓN ESTÁN
-- ===========================================================================
-- Fecha: 2026-10-10
-- Se aplica después de 2026-10-10_ventas_zonas.sql.
--
-- Una zona dibujada sólo sabía de sí misma: unas coordenadas y un nombre. Con
-- veinte zonas repartidas por el país, la lista no se puede ni ordenar ni
-- buscar por territorio, y dos zonas que se llaman «Centro» no se distinguen
-- hasta que se pulsan.
--
-- SON TEXTO LIBRE, no una referencia a un catálogo, porque en esta base NO HAY
-- catálogo de provincias: ventas.clientes.provincia y .canton también son
-- varchar y se llenan con lo que devuelve Google («Manabí», «Sto. Domingo»).
-- Poner aquí una tabla de códigos obligaría a traducir en los dos sentidos
-- para comparar una zona con sus clientes, que es justo lo que se querrá
-- hacer. Se escriben igual que allí y ya está.
--
-- EL PAÍS ES NUEVO EN EL PROYECTO: ventas.clientes no lo tiene. Por defecto
-- «Ecuador», que es lo único que hay hoy (el buscador del mapa va con
-- includedRegionCodes = ['ec']), pero se guarda porque una zona SÍ puede
-- quedar fuera el día que haya clientes en otro país, y rellenarlo después
-- sobre zonas ya dibujadas es peor.
--
-- QUIÉN LOS RELLENA: la pantalla, preguntándole a Google por el centro de la
-- zona recién dibujada (geocodificación inversa), y el usuario los puede
-- corregir. El servidor sólo los guarda: aquí no se puede preguntar a Google.
--
-- Cambia la firma de fn_zonas_guardar, así que se suelta antes: CREATE OR
-- REPLACE con otros parámetros no reemplaza, añade una sobrecarga.
--
-- Idempotente.
-- ===========================================================================

-- ===========================================================================
-- 1. LAS COLUMNAS
-- ===========================================================================
ALTER TABLE ventas.zonas ADD COLUMN IF NOT EXISTS pais      varchar(80);
ALTER TABLE ventas.zonas ADD COLUMN IF NOT EXISTS provincia varchar(100);
ALTER TABLE ventas.zonas ADD COLUMN IF NOT EXISTS canton    varchar(100);

-- Las que ya existieran se quedan en Ecuador, y de ahí en adelante por defecto
UPDATE ventas.zonas SET pais = 'Ecuador' WHERE pais IS NULL;
ALTER TABLE ventas.zonas ALTER COLUMN pais SET DEFAULT 'Ecuador';

COMMENT ON COLUMN ventas.zonas.pais      IS 'Dónde cae la zona. Por defecto Ecuador; ventas.clientes no guarda país';
COMMENT ON COLUMN ventas.zonas.provincia IS 'Texto libre, escrito igual que ventas.clientes.provincia (no hay catálogo)';
COMMENT ON COLUMN ventas.zonas.canton    IS 'Texto libre, escrito igual que ventas.clientes.canton';

-- Para listar y agrupar por territorio. Son pocas zonas, pero el índice no
-- cuesta nada y es la ordenación natural de la pantalla.
CREATE INDEX IF NOT EXISTS idx_zonas_territorio
    ON ventas.zonas (pais, provincia, canton);


-- ===========================================================================
-- 2. GUARDAR: tres parámetros más
-- ===========================================================================
DROP FUNCTION IF EXISTS ventas.fn_zonas_guardar(
    bigint, varchar, text, varchar, varchar, jsonb, numeric, numeric, numeric,
    boolean, bigint, varchar, varchar, inet, text, uuid);

CREATE OR REPLACE FUNCTION ventas.fn_zonas_guardar(
    p_id             bigint       DEFAULT NULL,
    p_nombre         varchar      DEFAULT NULL,
    p_descripcion    text         DEFAULT NULL,
    -- Dónde cae. Lo averigua la pantalla preguntándole a Google por el centro.
    p_pais           varchar      DEFAULT NULL,
    p_provincia      varchar      DEFAULT NULL,
    p_canton         varchar      DEFAULT NULL,
    p_color          varchar      DEFAULT NULL,
    p_tipo           varchar      DEFAULT 'POLIGONO',
    p_vertices       jsonb        DEFAULT NULL,
    p_centro_lat     numeric      DEFAULT NULL,
    p_centro_lng     numeric      DEFAULT NULL,
    p_radio_metros   numeric      DEFAULT NULL,
    p_activo         boolean      DEFAULT true,
    p_usuario_id     bigint       DEFAULT NULL,
    p_usuario_login  varchar      DEFAULT NULL,
    p_usuario_nombre varchar      DEFAULT NULL,
    p_ip_address     inet         DEFAULT NULL,
    p_user_agent     text         DEFAULT NULL,
    p_request_id     uuid         DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'ventas', 'auditoria'
AS $function$
DECLARE
    v_id     bigint;
    v_nombre varchar := NULLIF(TRIM(COALESCE(p_nombre, '')), '');
    v_tipo   varchar;
    v_pais   varchar := COALESCE(NULLIF(TRIM(COALESCE(p_pais, '')), ''), 'Ecuador');
    v_min_lat numeric; v_max_lat numeric;
    v_min_lng numeric; v_max_lng numeric;
    v_dlat numeric; v_dlng numeric;
BEGIN
    PERFORM ventas.fn_gestiones_contexto(p_usuario_id, p_usuario_login, p_usuario_nombre,
                                         p_ip_address, p_user_agent, p_request_id, 'ventas.zonas');

    v_tipo := UPPER(COALESCE(NULLIF(TRIM(COALESCE(p_tipo, '')), ''), 'POLIGONO'));

    IF v_nombre IS NULL OR length(v_nombre) < 3 THEN
        RAISE EXCEPTION 'El nombre de la zona es obligatorio (mínimo 3 caracteres)' USING ERRCODE = 'P0001';
    END IF;
    IF v_tipo NOT IN ('POLIGONO', 'CIRCULO') THEN
        RAISE EXCEPTION 'El tipo de zona debe ser POLIGONO o CIRCULO' USING ERRCODE = 'P0001';
    END IF;
    IF EXISTS (SELECT 1 FROM ventas.zonas
                WHERE UPPER(TRIM(nombre)) = UPPER(v_nombre) AND id IS DISTINCT FROM p_id) THEN
        RAISE EXCEPTION 'Ya existe una zona que se llama %', v_nombre USING ERRCODE = 'P0020';
    END IF;

    -- ---------- La caja, a partir de la forma ----------
    IF v_tipo = 'POLIGONO' THEN
        IF p_vertices IS NULL OR jsonb_typeof(p_vertices) <> 'array'
           OR jsonb_array_length(p_vertices) < 3 THEN
            RAISE EXCEPTION 'Un polígono necesita al menos tres puntos' USING ERRCODE = 'P0001';
        END IF;

        SELECT MIN((v->>'lat')::numeric), MAX((v->>'lat')::numeric),
               MIN((v->>'lng')::numeric), MAX((v->>'lng')::numeric)
          INTO v_min_lat, v_max_lat, v_min_lng, v_max_lng
          FROM jsonb_array_elements(p_vertices) AS v;

        IF v_min_lat IS NULL OR v_min_lng IS NULL THEN
            RAISE EXCEPTION 'Los puntos del polígono deben traer lat y lng numéricos' USING ERRCODE = 'P0001';
        END IF;
    ELSE
        IF p_centro_lat IS NULL OR p_centro_lng IS NULL
           OR p_radio_metros IS NULL OR p_radio_metros <= 0 THEN
            RAISE EXCEPTION 'Un círculo necesita centro y radio' USING ERRCODE = 'P0001';
        END IF;

        -- Un grado de latitud son ~111.320 m en cualquier sitio; uno de
        -- longitud, eso multiplicado por el coseno de la latitud.
        v_dlat := p_radio_metros / 111320.0;
        v_dlng := p_radio_metros / (111320.0 * GREATEST(cos(radians(p_centro_lat)), 0.000001));

        v_min_lat := GREATEST(p_centro_lat - v_dlat, -90);
        v_max_lat := LEAST   (p_centro_lat + v_dlat,  90);
        v_min_lng := GREATEST(p_centro_lng - v_dlng, -180);
        v_max_lng := LEAST   (p_centro_lng + v_dlng,  180);
    END IF;

    -- ---------- Guardar ----------
    IF p_id IS NULL THEN
        INSERT INTO ventas.zonas (
            nombre, descripcion, pais, provincia, canton, color, tipo, vertices,
            centro_lat, centro_lng, radio_metros,
            min_lat, max_lat, min_lng, max_lng, activo, created_by, updated_by
        ) VALUES (
            v_nombre, NULLIF(TRIM(COALESCE(p_descripcion, '')), ''),
            v_pais,
            NULLIF(TRIM(COALESCE(p_provincia, '')), ''),
            NULLIF(TRIM(COALESCE(p_canton, '')), ''),
            COALESCE(NULLIF(TRIM(COALESCE(p_color, '')), ''), '#00ACAC'),
            v_tipo,
            CASE WHEN v_tipo = 'POLIGONO' THEN p_vertices END,
            CASE WHEN v_tipo = 'CIRCULO'  THEN p_centro_lat END,
            CASE WHEN v_tipo = 'CIRCULO'  THEN p_centro_lng END,
            CASE WHEN v_tipo = 'CIRCULO'  THEN p_radio_metros END,
            v_min_lat, v_max_lat, v_min_lng, v_max_lng,
            COALESCE(p_activo, true), p_usuario_login, p_usuario_login
        ) RETURNING id INTO v_id;
    ELSE
        UPDATE ventas.zonas
           SET nombre       = v_nombre,
               descripcion  = NULLIF(TRIM(COALESCE(p_descripcion, '')), ''),
               pais         = v_pais,
               provincia    = NULLIF(TRIM(COALESCE(p_provincia, '')), ''),
               canton       = NULLIF(TRIM(COALESCE(p_canton, '')), ''),
               color        = COALESCE(NULLIF(TRIM(COALESCE(p_color, '')), ''), color),
               tipo         = v_tipo,
               vertices     = CASE WHEN v_tipo = 'POLIGONO' THEN p_vertices END,
               centro_lat   = CASE WHEN v_tipo = 'CIRCULO'  THEN p_centro_lat END,
               centro_lng   = CASE WHEN v_tipo = 'CIRCULO'  THEN p_centro_lng END,
               radio_metros = CASE WHEN v_tipo = 'CIRCULO'  THEN p_radio_metros END,
               min_lat = v_min_lat, max_lat = v_max_lat,
               min_lng = v_min_lng, max_lng = v_max_lng,
               activo = COALESCE(p_activo, activo),
               updated_by = p_usuario_login
         WHERE id = p_id;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'La zona no existe' USING ERRCODE = 'P0013';
        END IF;
        v_id := p_id;
    END IF;

    RETURN jsonb_build_object(
        'success', true,
        'message', CASE WHEN p_id IS NULL THEN 'Zona creada exitosamente' ELSE 'Zona actualizada exitosamente' END,
        'data', ventas.fn_zonas_json(v_id)
    );
END;
$function$;


-- ===========================================================================
-- 3. LEER: que salgan en el JSON
-- ===========================================================================
CREATE OR REPLACE FUNCTION ventas.fn_zonas_json(p_id bigint)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'ventas'
AS $function$
    SELECT jsonb_build_object(
        'id',           z.id,
        'nombre',       z.nombre,
        'descripcion',  z.descripcion,
        'pais',         z.pais,
        'provincia',    z.provincia,
        'canton',       z.canton,
        'color',        z.color,
        'tipo',         z.tipo,
        'vertices',     z.vertices,
        'centro_lat',   z.centro_lat,
        'centro_lng',   z.centro_lng,
        'radio_metros', z.radio_metros,
        -- La caja, para que el mapa pueda encuadrarla sin recorrer los vértices
        'min_lat',      z.min_lat,
        'max_lat',      z.max_lat,
        'min_lng',      z.min_lng,
        'max_lng',      z.max_lng,
        'activo',       z.activo,
        'clientes',     ventas.fn_zonas_contar_clientes(z.id),
        'created_at',   to_char(z.created_at, 'YYYY-MM-DD HH24:MI'),
        'created_by',   z.created_by,
        'updated_at',   to_char(z.updated_at, 'YYYY-MM-DD HH24:MI'),
        'updated_by',   z.updated_by
    )
    FROM ventas.zonas z WHERE z.id = p_id;
$function$;


-- ===========================================================================
-- 4. LISTAR: ordenadas por territorio, que es como se buscan
-- ===========================================================================
CREATE OR REPLACE FUNCTION ventas.fn_zonas_listar(p_incluir_inactivas boolean DEFAULT true)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'ventas'
AS $function$
DECLARE
    v_data jsonb;
BEGIN
    -- Por provincia y cantón primero: con veinte zonas repartidas por el país,
    -- las del mismo sitio tienen que salir juntas. Las que no lo tienen puesto
    -- van al final, no mezcladas.
    SELECT COALESCE(jsonb_agg(ventas.fn_zonas_json(z.id)
                              ORDER BY z.provincia NULLS LAST, z.canton NULLS LAST, z.nombre),
                    '[]'::jsonb)
      INTO v_data
      FROM ventas.zonas z
     WHERE (COALESCE(p_incluir_inactivas, true) OR z.activo);

    RETURN jsonb_build_object('success', true, 'message', 'Zonas obtenidas exitosamente', 'data', v_data);
EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object('success', false, 'message', 'Error al listar las zonas: ' || SQLERRM, 'error_code', SQLSTATE);
END;
$function$;
