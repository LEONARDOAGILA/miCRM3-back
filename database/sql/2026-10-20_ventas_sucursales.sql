-- ===========================================================================
-- SUCURSALES CON PERÍMETRO
-- ===========================================================================
-- Fecha: 2026-10-20
--
-- Una sucursal es el sitio donde trabaja la gente. Además de sus datos lleva
-- un PERÍMETRO dibujado en el mapa (un polígono, o un círculo con centro y
-- radio): a cada empleado se le asigna su sucursal y, al marcar asistencia,
-- sólo se le acepta si está dentro de ese perímetro.
--
-- POR QUÉ SE GUARDA ASÍ. Esta base no tiene PostGIS ni se puede instalar, así
-- que el polígono va como jsonb —la misma forma que ya usa ventas.zonas:
-- [{"lat": …, "lng": …}, …]— y las cuentas se hacen con funciones propias.
-- Se guardan también los extremos (min/max lat/lng) para descartar de un
-- vistazo los puntos que ni se acercan, sin recorrer todos los vértices.
--
-- LA TOLERANCIA. El GPS de un celular se equivoca entre 10 y 50 metros, y
-- dentro de un edificio mucho más. Sin margen, quien está en la puerta no
-- podría marcar. Cada sucursal lleva su `tolerancia_metros` (50 de serie):
-- se acepta el punto que esté dentro, o a menos de esa distancia del borde.
--
-- OJO: existe `core.sucursales` (vacía, con empresa_id y ubicacion_id). Esta
-- es otra tabla, en el esquema ventas y con perímetro, tal como se pidió. Si
-- algún día se unifican, lo que hay que mover es el perímetro, no al revés.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- 1. LA TABLA
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS ventas.sucursales (
    id              bigserial PRIMARY KEY,

    codigo          varchar(20)   NOT NULL,
    nombre          varchar(150)  NOT NULL,
    direccion       varchar(250),
    telefono        varchar(50),
    email           varchar(150),

    -- El perímetro. `tipo` dice cuál de las dos formas se usa.
    tipo            varchar(10)   NOT NULL DEFAULT 'POLIGONO',
    color           varchar(20)   NOT NULL DEFAULT '#348FE2',
    vertices        jsonb,
    centro_lat      numeric(10,7),
    centro_lng      numeric(10,7),
    radio_metros    numeric(10,2),

    -- Los extremos del perímetro: filtro barato antes de las cuentas finas
    min_lat         numeric(10,7),
    max_lat         numeric(10,7),
    min_lng         numeric(10,7),
    max_lng         numeric(10,7),

    -- Margen para el error del GPS, en metros
    tolerancia_metros numeric(10,2) NOT NULL DEFAULT 50,

    activo          boolean       NOT NULL DEFAULT true,

    created_at      timestamptz   NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at      timestamptz   NOT NULL DEFAULT CURRENT_TIMESTAMP,
    created_by      varchar(100),
    updated_by      varchar(100),

    -- Papelera de reciclaje (borrado lógico), como marcas y características
    deleted_at      timestamptz,
    deleted_by      varchar(100),

    CONSTRAINT ck_sucursales_tipo   CHECK (tipo IN ('POLIGONO', 'CIRCULO')),
    CONSTRAINT ck_sucursales_nombre CHECK (length(TRIM(nombre)) >= 3),
    CONSTRAINT ck_sucursales_codigo CHECK (length(TRIM(codigo)) >= 2),
    CONSTRAINT ck_sucursales_radio  CHECK (radio_metros IS NULL OR radio_metros > 0),
    CONSTRAINT ck_sucursales_tolerancia CHECK (tolerancia_metros >= 0 AND tolerancia_metros <= 5000)
);

-- El código no se repite entre las vigentes; las de la papelera no estorban
CREATE UNIQUE INDEX IF NOT EXISTS uk_sucursales_codigo
    ON ventas.sucursales (UPPER(TRIM(codigo))) WHERE deleted_at IS NULL;

CREATE UNIQUE INDEX IF NOT EXISTS uk_sucursales_nombre
    ON ventas.sucursales (UPPER(TRIM(nombre))) WHERE deleted_at IS NULL;

CREATE INDEX IF NOT EXISTS ix_sucursales_activo ON ventas.sucursales (activo) WHERE deleted_at IS NULL;

COMMENT ON TABLE  ventas.sucursales IS 'Sucursales con su perímetro en el mapa; los empleados marcan asistencia dentro de él.';
COMMENT ON COLUMN ventas.sucursales.vertices IS 'Polígono como [{"lat":…,"lng":…}, …], igual que ventas.zonas. Sin PostGIS en esta base.';
COMMENT ON COLUMN ventas.sucursales.tolerancia_metros IS 'Margen para el error del GPS: se acepta el punto que esté a menos de esto del borde.';

-- Auditoría: los mismos tres de todas las tablas del sistema
DROP TRIGGER IF EXISTS trigger_sucursales_set_users ON ventas.sucursales;
CREATE TRIGGER trigger_sucursales_set_users
    BEFORE INSERT OR UPDATE ON ventas.sucursales
    FOR EACH ROW EXECUTE FUNCTION auditoria.fn_set_audit_users();

DROP TRIGGER IF EXISTS trigger_sucursales_updated_at ON ventas.sucursales;
CREATE TRIGGER trigger_sucursales_updated_at
    BEFORE UPDATE ON ventas.sucursales
    FOR EACH ROW EXECUTE FUNCTION auditoria.fn_update_updated_at_column();

DROP TRIGGER IF EXISTS trg_sucursales_audit ON ventas.sucursales;
CREATE TRIGGER trg_sucursales_audit
    AFTER INSERT OR UPDATE OR DELETE ON ventas.sucursales
    FOR EACH ROW EXECUTE FUNCTION auditoria.fn_auditar_cambios();

-- ---------------------------------------------------------------------------
-- 1b. EL EMPLEADO Y SU SUCURSAL
-- ---------------------------------------------------------------------------
-- Va aquí y no en el fichero de marcaciones porque la ficha de la sucursal
-- cuenta cuántos empleados tiene: sin la columna, la función no se puede ni
-- crear.
ALTER TABLE rh.empleados
    ADD COLUMN IF NOT EXISTS sucursal_id bigint;

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_empleados_sucursal') THEN
        ALTER TABLE rh.empleados
            ADD CONSTRAINT fk_empleados_sucursal
            FOREIGN KEY (sucursal_id) REFERENCES ventas.sucursales(id);
    END IF;
END $$;

CREATE INDEX IF NOT EXISTS ix_empleados_sucursal ON rh.empleados (sucursal_id);

COMMENT ON COLUMN rh.empleados.sucursal_id
IS 'Dónde trabaja. Si su sucursal tiene perímetro, sólo puede marcar asistencia dentro de él.';

-- ---------------------------------------------------------------------------
-- 2. EL CONTEXTO DE AUDITORÍA DEL ESQUEMA
-- ---------------------------------------------------------------------------
-- El mismo que ya tienen inventarios y rh: deja en la sesión quién hace el
-- cambio para que lo recojan los triggers.
CREATE OR REPLACE FUNCTION ventas.fn_contexto_auditoria(
    p_modulo         text,
    p_usuario_id     bigint  DEFAULT NULL,
    p_usuario_login  varchar DEFAULT NULL,
    p_usuario_nombre varchar DEFAULT NULL,
    p_ip_address     inet    DEFAULT NULL,
    p_user_agent     text    DEFAULT NULL,
    p_request_id     uuid    DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
AS $function$
BEGIN
    PERFORM set_config('app.usuario_id',     COALESCE(p_usuario_id::text, ''), true);
    PERFORM set_config('app.usuario_login',  COALESCE(p_usuario_login, current_user), true);
    PERFORM set_config('app.usuario_nombre', COALESCE(p_usuario_nombre, current_user), true);
    PERFORM set_config('app.ip_address',     COALESCE(p_ip_address::text, ''), true);
    PERFORM set_config('app.user_agent',     COALESCE(p_user_agent, ''), true);
    PERFORM set_config('app.request_id',     COALESCE(p_request_id::text, ''), true);
    PERFORM set_config('app.modulo',         p_modulo, true);
END;
$function$;

-- ---------------------------------------------------------------------------
-- 3. GEOMETRÍA: ¿ESTÁ DENTRO, Y SI NO, A CUÁNTO?
-- ---------------------------------------------------------------------------

/**
 * Metros entre dos puntos (haversine). Para las distancias de una ciudad
 * sobra de sobra y no necesita PostGIS.
 */
CREATE OR REPLACE FUNCTION ventas.fn_metros_entre(
    p_lat1 numeric, p_lng1 numeric, p_lat2 numeric, p_lng2 numeric
)
RETURNS numeric
LANGUAGE sql
IMMUTABLE
AS $function$
    SELECT 6371000 * 2 * asin(sqrt(
             power(sin(radians(p_lat2 - p_lat1) / 2), 2)
           + cos(radians(p_lat1)) * cos(radians(p_lat2))
           * power(sin(radians(p_lng2 - p_lng1) / 2), 2)))::numeric;
$function$;

/**
 * Metros desde un punto hasta el BORDE más cercano de un polígono.
 *
 * Se proyecta a metros con la aproximación plana (lat/lng por el factor de
 * la latitud): a escala de barrio el error es de centímetros, y evita meter
 * una librería geográfica para decidir si alguien está en la puerta.
 */
CREATE OR REPLACE FUNCTION ventas.fn_metros_a_poligono(
    p_lat numeric, p_lng numeric, p_vertices jsonb
)
RETURNS numeric
LANGUAGE plpgsql
IMMUTABLE
AS $function$
DECLARE
    v_n        integer;
    v_i        integer;
    v_j        integer;
    v_mlat     numeric := 111320;              -- metros por grado de latitud
    v_mlng     numeric;
    px numeric; py numeric;
    x1 numeric; y1 numeric;      -- un extremo del lado
    x2 numeric; y2 numeric;      -- el otro
    dx numeric; dy numeric;
    t  numeric;
    d  numeric;
    v_min numeric := NULL;
BEGIN
    IF p_vertices IS NULL OR jsonb_typeof(p_vertices) <> 'array' THEN RETURN NULL; END IF;
    v_n := jsonb_array_length(p_vertices);
    IF v_n < 2 THEN RETURN NULL; END IF;

    v_mlng := v_mlat * cos(radians(p_lat));    -- los grados de longitud se acortan con la latitud
    px := p_lng * v_mlng;
    py := p_lat * v_mlat;

    v_j := v_n - 1;
    FOR v_i IN 0 .. v_n - 1 LOOP
        x1 := (p_vertices -> v_j ->> 'lng')::numeric * v_mlng;
        y1 := (p_vertices -> v_j ->> 'lat')::numeric * v_mlat;
        x2 := (p_vertices -> v_i ->> 'lng')::numeric * v_mlng;
        y2 := (p_vertices -> v_i ->> 'lat')::numeric * v_mlat;

        dx := x2 - x1;
        dy := y2 - y1;

        IF dx = 0 AND dy = 0 THEN
            d := sqrt(power(px - x1, 2) + power(py - y1, 2));       -- el lado es un punto
        ELSE
            -- Dónde cae la proyección del punto sobre el lado (0 = A, 1 = B)
            t := ((px - x1) * dx + (py - y1) * dy) / (dx * dx + dy * dy);
            t := GREATEST(0, LEAST(1, t));
            d := sqrt(power(px - (x1 + t * dx), 2) + power(py - (y1 + t * dy), 2));
        END IF;

        IF v_min IS NULL OR d < v_min THEN v_min := d; END IF;
        v_j := v_i;
    END LOOP;

    RETURN ROUND(v_min, 2);
END;
$function$;

/**
 * ¿Ese punto vale para esa sucursal?
 *
 * Devuelve siempre un jsonb con el porqué, que es lo que necesita quien
 * rechaza una marcación para poder explicarla:
 *   { exige, dentro, distancia_m, tolerancia_m, sucursal, motivo }
 *
 * `exige` es false cuando la sucursal no tiene perímetro dibujado: entonces
 * no se le pide la ubicación a nadie.
 */
CREATE OR REPLACE FUNCTION ventas.fn_sucursales_contiene(
    p_sucursal_id bigint, p_lat numeric, p_lng numeric
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
AS $function$
DECLARE
    s        record;
    v_dentro boolean := false;
    v_dist   numeric;
BEGIN
    SELECT * INTO s FROM ventas.sucursales WHERE id = p_sucursal_id AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('exige', false, 'dentro', true, 'motivo', 'La sucursal no existe');
    END IF;

    -- Sin perímetro no hay nada que exigir
    IF (s.tipo = 'POLIGONO' AND (s.vertices IS NULL OR jsonb_array_length(s.vertices) < 3))
       OR (s.tipo = 'CIRCULO' AND (s.centro_lat IS NULL OR s.radio_metros IS NULL)) THEN
        RETURN jsonb_build_object('exige', false, 'dentro', true, 'sucursal', s.nombre,
                                  'motivo', 'La sucursal no tiene perímetro dibujado');
    END IF;

    IF p_lat IS NULL OR p_lng IS NULL THEN
        RETURN jsonb_build_object('exige', true, 'dentro', false, 'sucursal', s.nombre,
                                  'tolerancia_m', s.tolerancia_metros,
                                  'motivo', 'No llegó la ubicación');
    END IF;

    IF s.tipo = 'CIRCULO' THEN
        v_dist   := ventas.fn_metros_entre(p_lat, p_lng, s.centro_lat, s.centro_lng);
        v_dentro := v_dist <= s.radio_metros + s.tolerancia_metros;
        -- Lo que se informa es lo que falta para entrar, no la distancia al centro
        v_dist   := GREATEST(0, ROUND(v_dist - s.radio_metros, 2));
    ELSE
        v_dentro := ventas.fn_punto_en_poligono(p_lat, p_lng, s.vertices);
        IF v_dentro THEN
            v_dist := 0;
        ELSE
            v_dist   := ventas.fn_metros_a_poligono(p_lat, p_lng, s.vertices);
            -- Fuera pero pegado al borde: el GPS pudo correrlo
            v_dentro := v_dist IS NOT NULL AND v_dist <= s.tolerancia_metros;
        END IF;
    END IF;

    RETURN jsonb_build_object(
        'exige', true, 'dentro', v_dentro, 'distancia_m', v_dist,
        'tolerancia_m', s.tolerancia_metros, 'sucursal', s.nombre,
        'motivo', CASE WHEN v_dentro THEN 'Dentro del perímetro' ELSE 'Fuera del perímetro' END);
END;
$function$;

-- ---------------------------------------------------------------------------
-- 4. LA FICHA
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ventas.fn_sucursales_json(p_id bigint)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
AS $function$
    SELECT jsonb_build_object(
        'id',                s.id,
        'codigo',            s.codigo,
        'nombre',            s.nombre,
        'direccion',         s.direccion,
        'telefono',          s.telefono,
        'email',             s.email,

        'tipo',              s.tipo,
        'color',             s.color,
        'vertices',          s.vertices,
        'centro_lat',        s.centro_lat,
        'centro_lng',        s.centro_lng,
        'radio_metros',      s.radio_metros,
        'tolerancia_metros', s.tolerancia_metros,

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

CREATE OR REPLACE FUNCTION ventas.fn_sucursales_obtener(p_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
AS $function$
DECLARE v_data jsonb;
BEGIN
    v_data := ventas.fn_sucursales_json(p_id);
    IF v_data IS NULL THEN
        RAISE EXCEPTION 'La sucursal no existe' USING ERRCODE = 'P0013';
    END IF;
    RETURN jsonb_build_object('success', true, 'message', 'Sucursal encontrada', 'data', v_data);
END;
$function$;

-- Lista simple, para los desplegables (asignar la sucursal a un empleado)
CREATE OR REPLACE FUNCTION ventas.fn_sucursales_listar(p_solo_activas boolean DEFAULT true)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
AS $function$
DECLARE v_data jsonb;
BEGIN
    SELECT COALESCE(jsonb_agg(ventas.fn_sucursales_json(s.id) ORDER BY s.nombre), '[]'::jsonb)
      INTO v_data
      FROM ventas.sucursales s
     WHERE s.deleted_at IS NULL
       AND (NOT p_solo_activas OR s.activo);

    RETURN jsonb_build_object('success', true, 'message', 'Sucursales', 'data', v_data);
END;
$function$;

-- ---------------------------------------------------------------------------
-- 5. EL LISTADO DE LA PANTALLA: paginado, con buscador y filtros de columna
-- ---------------------------------------------------------------------------
-- La paginación y los filtros se hacen AQUÍ, no en la rejilla: la pantalla
-- sólo tiene las filas de su página.
CREATE OR REPLACE FUNCTION ventas.fn_sucursales_listar_paginado(
    p_page     integer DEFAULT 1,
    p_per_page integer DEFAULT 15,
    p_search   text    DEFAULT ''::text,
    p_filtros  jsonb   DEFAULT '{}'::jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
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

-- ---------------------------------------------------------------------------
-- 6. CREAR Y MODIFICAR
-- ---------------------------------------------------------------------------
-- Las dos comparten la validación del perímetro, que es lo delicado: un
-- polígono de dos puntos o un círculo sin radio no encierran nada, y una
-- sucursal con un perímetro roto dejaría a su gente sin poder marcar.
CREATE OR REPLACE FUNCTION ventas.fn_sucursales_validar(
    p_id bigint, p_codigo varchar, p_nombre varchar, p_tipo varchar,
    p_vertices jsonb, p_centro_lat numeric, p_centro_lng numeric, p_radio numeric
)
RETURNS void
LANGUAGE plpgsql
STABLE
AS $function$
BEGIN
    IF p_codigo IS NULL OR length(TRIM(p_codigo)) < 2 THEN
        RAISE EXCEPTION 'El código de la sucursal es obligatorio (mínimo 2 caracteres)' USING ERRCODE = 'P0001';
    END IF;
    IF p_nombre IS NULL OR length(TRIM(p_nombre)) < 3 THEN
        RAISE EXCEPTION 'El nombre de la sucursal es obligatorio (mínimo 3 caracteres)' USING ERRCODE = 'P0001';
    END IF;
    IF UPPER(COALESCE(p_tipo, 'POLIGONO')) NOT IN ('POLIGONO', 'CIRCULO') THEN
        RAISE EXCEPTION 'El perímetro debe ser POLIGONO o CIRCULO' USING ERRCODE = 'P0015';
    END IF;

    IF EXISTS (SELECT 1 FROM ventas.sucursales
                WHERE UPPER(TRIM(codigo)) = UPPER(TRIM(p_codigo))
                  AND deleted_at IS NULL
                  AND (p_id IS NULL OR id <> p_id)) THEN
        RAISE EXCEPTION 'Ya existe una sucursal con el código %', UPPER(TRIM(p_codigo)) USING ERRCODE = 'P0006';
    END IF;

    IF EXISTS (SELECT 1 FROM ventas.sucursales
                WHERE UPPER(TRIM(nombre)) = UPPER(TRIM(p_nombre))
                  AND deleted_at IS NULL
                  AND (p_id IS NULL OR id <> p_id)) THEN
        RAISE EXCEPTION 'Ya existe una sucursal que se llama %', TRIM(p_nombre) USING ERRCODE = 'P0006';
    END IF;

    -- El perímetro es opcional, pero a medias no vale
    IF UPPER(COALESCE(p_tipo, 'POLIGONO')) = 'POLIGONO' AND p_vertices IS NOT NULL THEN
        IF jsonb_typeof(p_vertices) <> 'array' OR jsonb_array_length(p_vertices) < 3 THEN
            RAISE EXCEPTION 'Un polígono necesita al menos tres puntos' USING ERRCODE = 'P0015';
        END IF;
        IF EXISTS (SELECT 1 FROM jsonb_array_elements(p_vertices) v
                    WHERE (v->>'lat') IS NULL OR (v->>'lng') IS NULL) THEN
            RAISE EXCEPTION 'Los puntos del perímetro deben traer lat y lng' USING ERRCODE = 'P0015';
        END IF;
    END IF;

    IF UPPER(COALESCE(p_tipo, 'POLIGONO')) = 'CIRCULO'
       AND (p_centro_lat IS NOT NULL OR p_radio IS NOT NULL)
       AND (p_centro_lat IS NULL OR p_centro_lng IS NULL OR COALESCE(p_radio, 0) <= 0) THEN
        RAISE EXCEPTION 'Un círculo necesita centro y radio' USING ERRCODE = 'P0015';
    END IF;
END;
$function$;

CREATE OR REPLACE FUNCTION ventas.fn_sucursales_crear(
    p_codigo          varchar,
    p_nombre          varchar,
    p_direccion       varchar DEFAULT NULL,
    p_telefono        varchar DEFAULT NULL,
    p_email           varchar DEFAULT NULL,
    p_tipo            varchar DEFAULT 'POLIGONO',
    p_color           varchar DEFAULT '#348FE2',
    p_vertices        jsonb   DEFAULT NULL,
    p_centro_lat      numeric DEFAULT NULL,
    p_centro_lng      numeric DEFAULT NULL,
    p_radio_metros    numeric DEFAULT NULL,
    p_tolerancia      numeric DEFAULT 50,
    p_activo          boolean DEFAULT true,
    p_usuario_id      bigint  DEFAULT NULL,
    p_usuario_login   varchar DEFAULT NULL,
    p_usuario_nombre  varchar DEFAULT NULL,
    p_ip_address      inet    DEFAULT NULL,
    p_user_agent      text    DEFAULT NULL,
    p_request_id      uuid    DEFAULT NULL
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
BEGIN
    PERFORM ventas.fn_contexto_auditoria('ventas.sucursales',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    PERFORM ventas.fn_sucursales_validar(NULL, p_codigo, p_nombre, v_tipo,
                                         p_vertices, p_centro_lat, p_centro_lng, p_radio_metros);

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

    INSERT INTO ventas.sucursales (
        codigo, nombre, direccion, telefono, email,
        tipo, color, vertices, centro_lat, centro_lng, radio_metros,
        min_lat, max_lat, min_lng, max_lng, tolerancia_metros, activo)
    VALUES (
        UPPER(TRIM(p_codigo)), TRIM(p_nombre),
        NULLIF(TRIM(COALESCE(p_direccion, '')), ''),
        NULLIF(TRIM(COALESCE(p_telefono, '')), ''),
        NULLIF(TRIM(COALESCE(p_email, '')), ''),
        v_tipo, COALESCE(NULLIF(TRIM(COALESCE(p_color, '')), ''), '#348FE2'),
        CASE WHEN v_tipo = 'POLIGONO' THEN p_vertices END,
        CASE WHEN v_tipo = 'CIRCULO'  THEN p_centro_lat END,
        CASE WHEN v_tipo = 'CIRCULO'  THEN p_centro_lng END,
        CASE WHEN v_tipo = 'CIRCULO'  THEN p_radio_metros END,
        v_min_lat, v_max_lat, v_min_lng, v_max_lng,
        COALESCE(p_tolerancia, 50), COALESCE(p_activo, true))
    RETURNING id INTO v_id;

    RETURN jsonb_build_object('success', true, 'message', 'Sucursal creada exitosamente',
                              'data', ventas.fn_sucursales_json(v_id));

EXCEPTION
    WHEN unique_violation THEN
        RAISE EXCEPTION 'Ya existe una sucursal con ese código o ese nombre' USING ERRCODE = 'P0006';
END;
$function$;

CREATE OR REPLACE FUNCTION ventas.fn_sucursales_modificar(
    p_id              bigint,
    p_codigo          varchar,
    p_nombre          varchar,
    p_direccion       varchar DEFAULT NULL,
    p_telefono        varchar DEFAULT NULL,
    p_email           varchar DEFAULT NULL,
    p_tipo            varchar DEFAULT 'POLIGONO',
    p_color           varchar DEFAULT '#348FE2',
    p_vertices        jsonb   DEFAULT NULL,
    p_centro_lat      numeric DEFAULT NULL,
    p_centro_lng      numeric DEFAULT NULL,
    p_radio_metros    numeric DEFAULT NULL,
    p_tolerancia      numeric DEFAULT 50,
    p_activo          boolean DEFAULT true,
    p_usuario_id      bigint  DEFAULT NULL,
    p_usuario_login   varchar DEFAULT NULL,
    p_usuario_nombre  varchar DEFAULT NULL,
    p_ip_address      inet    DEFAULT NULL,
    p_user_agent      text    DEFAULT NULL,
    p_request_id      uuid    DEFAULT NULL
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
BEGIN
    PERFORM ventas.fn_contexto_auditoria('ventas.sucursales',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    v_antes := ventas.fn_sucursales_json(p_id);
    IF v_antes IS NULL THEN
        RAISE EXCEPTION 'La sucursal no existe' USING ERRCODE = 'P0013';
    END IF;

    PERFORM ventas.fn_sucursales_validar(p_id, p_codigo, p_nombre, v_tipo,
                                         p_vertices, p_centro_lat, p_centro_lng, p_radio_metros);

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

    UPDATE ventas.sucursales
       SET codigo        = UPPER(TRIM(p_codigo)),
           nombre        = TRIM(p_nombre),
           direccion     = NULLIF(TRIM(COALESCE(p_direccion, '')), ''),
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
           activo        = COALESCE(p_activo, true)
     WHERE id = p_id;

    RETURN jsonb_build_object('success', true, 'message', 'Sucursal actualizada exitosamente',
                              'data', ventas.fn_sucursales_json(p_id));

EXCEPTION
    WHEN unique_violation THEN
        RAISE EXCEPTION 'Ya existe otra sucursal con ese código o ese nombre' USING ERRCODE = 'P0006';
END;
$function$;

-- ---------------------------------------------------------------------------
-- 7. ACTIVAR / DESACTIVAR
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ventas.fn_sucursales_activar(
    p_id             bigint,
    p_activo         boolean DEFAULT NULL,
    p_usuario_id     bigint  DEFAULT NULL,
    p_usuario_login  varchar DEFAULT NULL,
    p_usuario_nombre varchar DEFAULT NULL,
    p_ip_address     inet    DEFAULT NULL,
    p_user_agent     text    DEFAULT NULL,
    p_request_id     uuid    DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'ventas', 'auditoria'
AS $function$
DECLARE v_nuevo boolean;
BEGIN
    PERFORM ventas.fn_contexto_auditoria('ventas.sucursales',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    SELECT COALESCE(p_activo, NOT activo) INTO v_nuevo
      FROM ventas.sucursales WHERE id = p_id AND deleted_at IS NULL;

    IF v_nuevo IS NULL THEN
        RAISE EXCEPTION 'La sucursal no existe' USING ERRCODE = 'P0013';
    END IF;

    UPDATE ventas.sucursales SET activo = v_nuevo WHERE id = p_id;

    RETURN jsonb_build_object('success', true,
        'message', CASE WHEN v_nuevo THEN 'Sucursal activada' ELSE 'Sucursal desactivada' END,
        'data', ventas.fn_sucursales_json(p_id));
END;
$function$;

-- ---------------------------------------------------------------------------
-- 8. PAPELERA DE RECICLAJE
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ventas.fn_sucursales_eliminar(
    p_id             bigint,
    p_usuario_id     bigint  DEFAULT NULL,
    p_usuario_login  varchar DEFAULT NULL,
    p_usuario_nombre varchar DEFAULT NULL,
    p_ip_address     inet    DEFAULT NULL,
    p_user_agent     text    DEFAULT NULL,
    p_request_id     uuid    DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'ventas', 'rh', 'auditoria'
AS $function$
DECLARE
    v_data     jsonb;
    v_empleados integer;
BEGIN
    PERFORM ventas.fn_contexto_auditoria('ventas.sucursales',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    v_data := ventas.fn_sucursales_json(p_id);
    IF v_data IS NULL OR v_data->>'deleted_at' IS NOT NULL THEN
        RAISE EXCEPTION 'La sucursal no existe o ya está en la papelera' USING ERRCODE = 'P0013';
    END IF;

    -- Con gente dentro no se borra: esos empleados se quedarían sin poder marcar
    SELECT COUNT(*) INTO v_empleados FROM rh.empleados WHERE sucursal_id = p_id;
    IF v_empleados > 0 THEN
        RAISE EXCEPTION 'La sucursal «%» tiene % empleado(s) asignado(s): cámbielos de sucursal antes de eliminarla',
              v_data->>'nombre', v_empleados USING ERRCODE = 'P0021';
    END IF;

    UPDATE ventas.sucursales
       SET deleted_at = CURRENT_TIMESTAMP,
           deleted_by = COALESCE(p_usuario_login, current_user)
     WHERE id = p_id;

    RETURN jsonb_build_object('success', true, 'message', 'Sucursal enviada a la papelera de reciclaje',
                              'data', ventas.fn_sucursales_json(p_id));
END;
$function$;

CREATE OR REPLACE FUNCTION ventas.fn_sucursales_papelera_listar()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
AS $function$
DECLARE v_data jsonb;
BEGIN
    SELECT COALESCE(jsonb_agg(ventas.fn_sucursales_json(s.id) ORDER BY s.deleted_at DESC), '[]'::jsonb)
      INTO v_data FROM ventas.sucursales s WHERE s.deleted_at IS NOT NULL;

    RETURN jsonb_build_object('success', true, 'message', 'Papelera de sucursales', 'data', v_data);
END;
$function$;

CREATE OR REPLACE FUNCTION ventas.fn_sucursales_restaurar(
    p_ids            jsonb,
    p_usuario_id     bigint  DEFAULT NULL,
    p_usuario_login  varchar DEFAULT NULL,
    p_usuario_nombre varchar DEFAULT NULL,
    p_ip_address     inet    DEFAULT NULL,
    p_user_agent     text    DEFAULT NULL,
    p_request_id     uuid    DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'ventas', 'auditoria'
AS $function$
DECLARE
    v_nombres text[];
    v_cuantas integer;
BEGIN
    PERFORM ventas.fn_contexto_auditoria('ventas.sucursales',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    -- Restaurar una vigente no significa nada
    SELECT array_agg(nombre) INTO v_nombres
      FROM ventas.sucursales
     WHERE id IN (SELECT (jsonb_array_elements_text(p_ids))::bigint)
       AND deleted_at IS NOT NULL;

    IF v_nombres IS NULL THEN
        RAISE EXCEPTION 'No hay nada que restaurar: esas sucursales no están en la papelera' USING ERRCODE = 'P0019';
    END IF;

    -- El código y el nombre son únicos entre las vigentes: si alguien creó
    -- otra con los mismos mientras ésta estaba en la papelera, se avisa.
    IF EXISTS (
        SELECT 1 FROM ventas.sucursales p
          JOIN ventas.sucursales v
            ON v.deleted_at IS NULL
           AND (UPPER(TRIM(v.codigo)) = UPPER(TRIM(p.codigo)) OR UPPER(TRIM(v.nombre)) = UPPER(TRIM(p.nombre)))
         WHERE p.id IN (SELECT (jsonb_array_elements_text(p_ids))::bigint)
           AND p.deleted_at IS NOT NULL) THEN
        RAISE EXCEPTION 'Ya existe una sucursal vigente con ese código o ese nombre' USING ERRCODE = 'P0006';
    END IF;

    UPDATE ventas.sucursales
       SET deleted_at = NULL, deleted_by = NULL
     WHERE id IN (SELECT (jsonb_array_elements_text(p_ids))::bigint)
       AND deleted_at IS NOT NULL;

    GET DIAGNOSTICS v_cuantas = ROW_COUNT;

    RETURN jsonb_build_object('success', true,
        'message', v_cuantas || ' sucursal(es) restaurada(s)',
        'data', jsonb_build_object('nombres', to_jsonb(v_nombres), 'restauradas', v_cuantas));
END;
$function$;

CREATE OR REPLACE FUNCTION ventas.fn_sucursales_eliminar_definitivo(
    p_ids            jsonb,
    p_usuario_id     bigint  DEFAULT NULL,
    p_usuario_login  varchar DEFAULT NULL,
    p_usuario_nombre varchar DEFAULT NULL,
    p_ip_address     inet    DEFAULT NULL,
    p_user_agent     text    DEFAULT NULL,
    p_request_id     uuid    DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'ventas', 'rh', 'auditoria'
AS $function$
DECLARE
    v_nombres text[];
    v_cuantas integer;
BEGIN
    PERFORM ventas.fn_contexto_auditoria('ventas.sucursales',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    SELECT array_agg(nombre) INTO v_nombres
      FROM ventas.sucursales
     WHERE id IN (SELECT (jsonb_array_elements_text(p_ids))::bigint)
       AND deleted_at IS NOT NULL;

    IF v_nombres IS NULL THEN
        RAISE EXCEPTION 'Sólo se puede eliminar definitivamente lo que está en la papelera' USING ERRCODE = 'P0019';
    END IF;

    IF EXISTS (SELECT 1 FROM rh.empleados e
                WHERE e.sucursal_id IN (SELECT (jsonb_array_elements_text(p_ids))::bigint)) THEN
        RAISE EXCEPTION 'Alguna de esas sucursales todavía tiene empleados asignados' USING ERRCODE = 'P0021';
    END IF;

    DELETE FROM ventas.sucursales
     WHERE id IN (SELECT (jsonb_array_elements_text(p_ids))::bigint)
       AND deleted_at IS NOT NULL;

    GET DIAGNOSTICS v_cuantas = ROW_COUNT;

    RETURN jsonb_build_object('success', true,
        'message', v_cuantas || ' sucursal(es) eliminada(s) definitivamente',
        'data', jsonb_build_object('nombres', to_jsonb(v_nombres), 'eliminadas', v_cuantas));
END;
$function$;

CREATE OR REPLACE FUNCTION ventas.fn_sucursales_papelera_vaciar(
    p_usuario_id     bigint  DEFAULT NULL,
    p_usuario_login  varchar DEFAULT NULL,
    p_usuario_nombre varchar DEFAULT NULL,
    p_ip_address     inet    DEFAULT NULL,
    p_user_agent     text    DEFAULT NULL,
    p_request_id     uuid    DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'ventas', 'rh', 'auditoria'
AS $function$
DECLARE v_cuantas integer;
BEGIN
    PERFORM ventas.fn_contexto_auditoria('ventas.sucursales',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    -- Las que todavía tienen gente asignada no se van: romperían la ficha
    -- de esos empleados.
    DELETE FROM ventas.sucursales s
     WHERE s.deleted_at IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM rh.empleados e WHERE e.sucursal_id = s.id);

    GET DIAGNOSTICS v_cuantas = ROW_COUNT;

    RETURN jsonb_build_object('success', true,
        'message', 'Papelera vaciada: ' || v_cuantas || ' sucursal(es) eliminada(s)',
        'data', jsonb_build_object('eliminadas', v_cuantas));
END;
$function$;
