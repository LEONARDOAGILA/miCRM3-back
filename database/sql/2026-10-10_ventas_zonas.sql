-- ===========================================================================
-- ZONAS DE CLIENTES: ÁREAS DIBUJADAS EN EL MAPA
-- ===========================================================================
-- Fecha: 2026-10-10
--
-- Una zona es un área dibujada en el mapa —un polígono o un círculo— con la
-- que preguntar «¿qué clientes tengo aquí dentro?». Sirve para repartir
-- carteras por territorio, planear una ruta de visitas o ver dónde no se
-- está llegando.
--
-- ---------------------------------------------------------------------------
-- POR QUÉ NO SE USA PostGIS
-- ---------------------------------------------------------------------------
-- Sería lo natural —geography(Polygon,4326) y ST_Contains— pero en este
-- servidor NO está instalado NI está disponible para instalar:
--
--     SELECT * FROM pg_available_extensions WHERE name = 'postgis';   -- 0 filas
--
-- Así que la geometría se guarda en jsonb y las dos cuentas que hacen falta
-- —punto dentro de polígono y distancia entre dos puntos— se escriben aquí.
-- Son veinte líneas cada una y no necesitan nada más.
--
-- Si algún día se instala PostGIS, lo que cambia es el tipo de la columna y
-- el cuerpo de fn_punto_en_zona; la tabla y el resto de funciones siguen.
--
-- ---------------------------------------------------------------------------
-- LA CAJA QUE ENVUELVE A LA ZONA (min_lat, max_lat, min_lng, max_lng)
-- ---------------------------------------------------------------------------
-- No es un dato que se pida: lo calcula fn_zonas_guardar y es lo que hace
-- rápida la consulta. Mirar si un punto está dentro de un polígono de treinta
-- vértices cuesta; mirar si está dentro de un rectángulo son cuatro
-- comparaciones. Primero se descarta con la caja y sólo a los que quedan se
-- les hace la cuenta buena.
--
-- Al guardarse en la tabla no puede descuadrarse con los vértices, porque
-- sale de ellos.
--
-- ---------------------------------------------------------------------------
-- LAS COORDENADAS DE LOS CLIENTES
-- ---------------------------------------------------------------------------
-- Están en ventas.clientes.coordenadas como texto, «-2.896088, -79.003732».
-- Se parten al vuelo con fn_coordenada_lat/lng, que son IMMUTABLE y devuelven
-- NULL si el texto no tiene la forma esperada: un cliente con la coordenada
-- mal escrita no rompe la consulta, simplemente no sale en ninguna zona.
--
-- OJO AL RENDIMIENTO: eso obliga a leer los clientes enteros. Con mil es
-- inmediato; si la cartera crece a ochenta mil, lo que toca es añadir a
-- ventas.clientes dos columnas generadas (lat, lng) con su índice, y aquí
-- sólo cambiarían los dos ventas.fn_coordenada_* por las columnas.
--
-- Idempotente.
-- ===========================================================================


-- ===========================================================================
-- 1. LA TABLA
-- ===========================================================================
CREATE TABLE IF NOT EXISTS ventas.zonas (
    id            bigserial    NOT NULL,

    nombre        varchar(120) NOT NULL,
    descripcion   text,

    -- Con qué color se pinta en el mapa y en los listados
    color         varchar(9)   NOT NULL DEFAULT '#00ACAC',

    -- POLIGONO: un área dibujada a mano, vértice a vértice.
    -- CIRCULO:  un centro y un radio, que es como se dice «a 2 km de aquí».
    tipo          varchar(10)  NOT NULL DEFAULT 'POLIGONO',

    -- Los vértices del polígono, EN ORDEN y tal y como los da Google Maps:
    --   [{"lat": -2.1709, "lng": -79.9224}, …]
    -- No hace falta repetir el primero al final: se cierra sola.
    vertices      jsonb,

    -- El círculo
    centro_lat    numeric(10,7),
    centro_lng    numeric(10,7),
    radio_metros  numeric(12,2),

    -- La caja que la envuelve. La calcula fn_zonas_guardar; no se pide.
    min_lat       numeric(10,7) NOT NULL,
    max_lat       numeric(10,7) NOT NULL,
    min_lng       numeric(10,7) NOT NULL,
    max_lng       numeric(10,7) NOT NULL,

    activo        boolean      NOT NULL DEFAULT true,

    created_at    timestamptz  DEFAULT CURRENT_TIMESTAMP,
    updated_at    timestamptz  DEFAULT CURRENT_TIMESTAMP,
    created_by    varchar(100),
    updated_by    varchar(100),

    CONSTRAINT pk_zonas PRIMARY KEY (id),

    CONSTRAINT ck_zonas_tipo  CHECK (tipo IN ('POLIGONO', 'CIRCULO')),

    -- Cada tipo necesita lo suyo, y la base no se fía de que lo mande quien
    -- llame: un polígono sin vértices o un círculo sin radio no es una zona.
    CONSTRAINT ck_zonas_forma CHECK (
        (tipo = 'POLIGONO' AND vertices IS NOT NULL
                           AND jsonb_typeof(vertices) = 'array'
                           AND jsonb_array_length(vertices) >= 3)
        OR
        (tipo = 'CIRCULO'  AND centro_lat IS NOT NULL AND centro_lng IS NOT NULL
                           AND radio_metros IS NOT NULL AND radio_metros > 0)
    ),

    CONSTRAINT ck_zonas_caja  CHECK (min_lat <= max_lat AND min_lng <= max_lng),

    CONSTRAINT ck_zonas_grados CHECK (
        min_lat BETWEEN  -90 AND  90 AND max_lat BETWEEN  -90 AND  90 AND
        min_lng BETWEEN -180 AND 180 AND max_lng BETWEEN -180 AND 180
    ),

    CONSTRAINT ck_zonas_nombre CHECK (length(TRIM(nombre)) >= 3)
);

COMMENT ON TABLE  ventas.zonas IS 'Áreas dibujadas en el mapa para saber qué clientes caen dentro';
COMMENT ON COLUMN ventas.zonas.vertices IS 'Polígono: [{"lat":…,"lng":…}, …] en orden. Se cierra solo.';
COMMENT ON COLUMN ventas.zonas.min_lat  IS 'Caja que envuelve la zona; la calcula fn_zonas_guardar para descartar rápido';

-- Dos zonas no pueden llamarse igual, mire como mire el que la escribió
CREATE UNIQUE INDEX IF NOT EXISTS uq_zonas_nombre
    ON ventas.zonas (UPPER(TRIM(nombre)));

-- Las consultas empiezan siempre por «las activas», y de ahí por la caja
CREATE INDEX IF NOT EXISTS idx_zonas_activas
    ON ventas.zonas (activo, min_lat, max_lat, min_lng, max_lng);

-- Los mismos tres de las demás tablas de ventas: la auditoría, quién tocó y
-- la fecha de modificación
DROP TRIGGER IF EXISTS trg_zonas_audit        ON ventas.zonas;
DROP TRIGGER IF EXISTS trigger_zonas_set_users ON ventas.zonas;
DROP TRIGGER IF EXISTS trigger_zonas_updated_at ON ventas.zonas;

CREATE TRIGGER trg_zonas_audit        AFTER INSERT OR UPDATE OR DELETE ON ventas.zonas
    FOR EACH ROW EXECUTE FUNCTION auditoria.fn_auditar_cambios();
CREATE TRIGGER trigger_zonas_set_users BEFORE INSERT OR UPDATE ON ventas.zonas
    FOR EACH ROW EXECUTE FUNCTION auditoria.fn_set_audit_users();
CREATE TRIGGER trigger_zonas_updated_at BEFORE UPDATE ON ventas.zonas
    FOR EACH ROW EXECUTE FUNCTION auditoria.fn_update_updated_at_column();


-- ===========================================================================
-- 2. LAS DOS CUENTAS DE GEOMETRÍA
-- ===========================================================================

/**
 * El texto «-2.896088, -79.003732» partido en dos números.
 *
 * Devuelve NULL si no tiene esa forma. Es a propósito: una coordenada mal
 * escrita en la ficha de un cliente no puede reventar la consulta de toda una
 * zona; ese cliente simplemente no cae en ninguna.
 *
 * IMMUTABLE para que el planificador pueda resolverla una vez por fila y,
 * el día que haga falta, para poder usarla en una columna generada.
 */
CREATE OR REPLACE FUNCTION ventas.fn_coordenada_lat(p_texto text)
RETURNS numeric
LANGUAGE sql
IMMUTABLE
AS $function$
    SELECT CASE
        WHEN p_texto ~ '^\s*-?\d{1,3}(\.\d+)?\s*,\s*-?\d{1,3}(\.\d+)?\s*$'
        THEN TRIM(split_part(p_texto, ',', 1))::numeric
    END;
$function$;

CREATE OR REPLACE FUNCTION ventas.fn_coordenada_lng(p_texto text)
RETURNS numeric
LANGUAGE sql
IMMUTABLE
AS $function$
    SELECT CASE
        WHEN p_texto ~ '^\s*-?\d{1,3}(\.\d+)?\s*,\s*-?\d{1,3}(\.\d+)?\s*$'
        THEN TRIM(split_part(p_texto, ',', 2))::numeric
    END;
$function$;


/**
 * ¿Está el punto dentro del polígono?
 *
 * Algoritmo del rayo: se lanza una semirrecta hacia el este desde el punto y
 * se cuentan los lados que cruza. Impar = dentro, par = fuera. Es el mismo
 * que usa Google Maps en su geometry.poly.containsLocation.
 *
 * Los grados se tratan como coordenadas planas. A la escala de una zona de
 * reparto —kilómetros, no cientos— la curvatura de la Tierra no mueve el
 * resultado; lo que sí importaría es cerca de los polos o cruzando el
 * meridiano 180, y ninguna de las dos cosas pasa en Ecuador.
 *
 * El polígono se cierra solo: el último vértice se une con el primero, así
 * que no hay que repetirlo al guardarlo.
 */
CREATE OR REPLACE FUNCTION ventas.fn_punto_en_poligono(
    p_lat      numeric,
    p_lng      numeric,
    p_vertices jsonb
)
RETURNS boolean
LANGUAGE plpgsql
IMMUTABLE
AS $function$
DECLARE
    v_n      integer;
    v_i      integer;
    v_j      integer;
    v_dentro boolean := false;
    xi numeric; yi numeric;
    xj numeric; yj numeric;
BEGIN
    IF p_lat IS NULL OR p_lng IS NULL THEN RETURN false; END IF;
    IF p_vertices IS NULL OR jsonb_typeof(p_vertices) <> 'array' THEN RETURN false; END IF;

    v_n := jsonb_array_length(p_vertices);
    IF v_n < 3 THEN RETURN false; END IF;

    v_j := v_n - 1;                      -- el anterior; al principio, el último
    FOR v_i IN 0 .. v_n - 1 LOOP
        yi := (p_vertices -> v_i ->> 'lat')::numeric;
        xi := (p_vertices -> v_i ->> 'lng')::numeric;
        yj := (p_vertices -> v_j ->> 'lat')::numeric;
        xj := (p_vertices -> v_j ->> 'lng')::numeric;

        -- El lado cruza la horizontal del punto, y el cruce queda a su derecha
        IF ((yi > p_lat) <> (yj > p_lat))
           AND (p_lng < (xj - xi) * (p_lat - yi) / NULLIF(yj - yi, 0) + xi)
        THEN
            v_dentro := NOT v_dentro;
        END IF;

        v_j := v_i;
    END LOOP;

    RETURN v_dentro;
END;
$function$;


/**
 * Metros entre dos puntos (fórmula del semiverseno).
 *
 * Para los círculos. Con el radio medio de la Tierra el error es de metros en
 * distancias de kilómetros, que es de sobra para decir si un cliente está
 * dentro de un radio de reparto.
 */
CREATE OR REPLACE FUNCTION ventas.fn_distancia_metros(
    p_lat1 numeric, p_lng1 numeric,
    p_lat2 numeric, p_lng2 numeric
)
RETURNS numeric
LANGUAGE sql
IMMUTABLE
AS $function$
    SELECT CASE
        WHEN p_lat1 IS NULL OR p_lng1 IS NULL OR p_lat2 IS NULL OR p_lng2 IS NULL THEN NULL
        ELSE 6371000 * 2 * asin(sqrt(
                 power(sin(radians(p_lat2 - p_lat1) / 2), 2)
               + cos(radians(p_lat1)) * cos(radians(p_lat2))
               * power(sin(radians(p_lng2 - p_lng1) / 2), 2)
             ))::numeric
    END;
$function$;


-- ===========================================================================
-- 3. ¿ESTÁ ESTE PUNTO EN ESTA ZONA?
-- ===========================================================================

/**
 * La pregunta completa, para una zona ya leída.
 *
 * Se le pasan los campos y no el id a propósito: así se puede usar dentro de
 * un JOIN sin releer la tabla por cada cliente.
 */
CREATE OR REPLACE FUNCTION ventas.fn_punto_en_zona(
    p_lat          numeric,
    p_lng          numeric,
    p_tipo         varchar,
    p_vertices     jsonb,
    p_centro_lat   numeric,
    p_centro_lng   numeric,
    p_radio_metros numeric
)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
AS $function$
    SELECT CASE
        WHEN p_lat IS NULL OR p_lng IS NULL THEN false
        WHEN p_tipo = 'CIRCULO'
            THEN ventas.fn_distancia_metros(p_centro_lat, p_centro_lng, p_lat, p_lng) <= p_radio_metros
        ELSE ventas.fn_punto_en_poligono(p_lat, p_lng, p_vertices)
    END;
$function$;


-- ===========================================================================
-- 4. GUARDAR
-- ===========================================================================

/**
 * Crea o modifica una zona.
 *
 * La caja que la envuelve NO se pide: se calcula aquí a partir de la forma,
 * así no puede llegar descuadrada ni hay dos sitios desde los que mantenerla.
 *
 * Mismos seis parámetros de auditoría que el resto del módulo.
 */
CREATE OR REPLACE FUNCTION ventas.fn_zonas_guardar(
    p_id             bigint       DEFAULT NULL,
    p_nombre         varchar      DEFAULT NULL,
    p_descripcion    text         DEFAULT NULL,
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
        -- longitud, eso multiplicado por el coseno de la latitud (en el
        -- ecuador lo mismo, hacia los polos cada vez menos).
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
            nombre, descripcion, color, tipo, vertices,
            centro_lat, centro_lng, radio_metros,
            min_lat, max_lat, min_lng, max_lng, activo, created_by, updated_by
        ) VALUES (
            v_nombre, NULLIF(TRIM(COALESCE(p_descripcion, '')), ''),
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
-- 5. LEER
-- ===========================================================================

/** Cuántos clientes caen dentro. Es la cuenta de fn_zonas_clientes. */
CREATE OR REPLACE FUNCTION ventas.fn_zonas_contar_clientes(p_zona_id bigint)
RETURNS bigint
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'ventas'
AS $function$
    SELECT COUNT(*)
      FROM ventas.zonas z
      JOIN ventas.clientes c
        ON c.deleted_at IS NULL
       -- Primero la caja: cuatro comparaciones descartan casi todo
       AND ventas.fn_coordenada_lat(c.coordenadas) BETWEEN z.min_lat AND z.max_lat
       AND ventas.fn_coordenada_lng(c.coordenadas) BETWEEN z.min_lng AND z.max_lng
       -- Y a los que quedan, la cuenta buena
       AND ventas.fn_punto_en_zona(
               ventas.fn_coordenada_lat(c.coordenadas),
               ventas.fn_coordenada_lng(c.coordenadas),
               z.tipo, z.vertices, z.centro_lat, z.centro_lng, z.radio_metros)
     WHERE z.id = p_zona_id;
$function$;


/** Una zona en JSON, con cuántos clientes le caen dentro. */
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


/** El listado de zonas. */
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
    SELECT COALESCE(jsonb_agg(ventas.fn_zonas_json(z.id) ORDER BY z.nombre), '[]'::jsonb)
      INTO v_data
      FROM ventas.zonas z
     WHERE (COALESCE(p_incluir_inactivas, true) OR z.activo);

    RETURN jsonb_build_object('success', true, 'message', 'Zonas obtenidas exitosamente', 'data', v_data);
EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object('success', false, 'message', 'Error al listar las zonas: ' || SQLERRM, 'error_code', SQLSTATE);
END;
$function$;


-- ===========================================================================
-- 6. LO QUE SE VIENE A BUSCAR: LOS CLIENTES DE UNA ZONA
-- ===========================================================================

/**
 * Los clientes que caen dentro de la zona, paginados.
 *
 * Mismo formato que el resto de listados: { data, meta }.
 *
 * SE DEVUELVEN LAS COORDENADAS porque quien pregunta esto suele ser un mapa:
 * con ellas puede pintar un marcador por cliente sin pedir cada ficha.
 */
CREATE OR REPLACE FUNCTION ventas.fn_zonas_clientes(
    p_zona_id  bigint,
    p_page     integer DEFAULT 1,
    p_per_page integer DEFAULT 50,
    p_search   text    DEFAULT ''
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'ventas'
AS $function$
DECLARE
    v_page     integer := GREATEST(COALESCE(p_page, 1), 1);
    v_per_page integer := LEAST(GREATEST(COALESCE(p_per_page, 50), 1), 500);
    v_filtro   text    := NULLIF(TRIM(COALESCE(p_search, '')), '');
    v_total    bigint;
    v_data     jsonb;
    v_zona     jsonb;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM ventas.zonas WHERE id = p_zona_id) THEN
        RAISE EXCEPTION 'La zona no existe' USING ERRCODE = 'P0013';
    END IF;

    WITH z AS (
        SELECT * FROM ventas.zonas WHERE id = p_zona_id
    ),
    dentro AS (
        SELECT c.id, c.nombre_completo, c.numero_identificacion, c.celular, c.telefono,
               c.direccion, c.provincia, c.canton, c.parroquia, c.estado, c.activo,
               ventas.fn_coordenada_lat(c.coordenadas) AS lat,
               ventas.fn_coordenada_lng(c.coordenadas) AS lng
          FROM ventas.clientes c, z
         WHERE c.deleted_at IS NULL
           AND ventas.fn_coordenada_lat(c.coordenadas) BETWEEN z.min_lat AND z.max_lat
           AND ventas.fn_coordenada_lng(c.coordenadas) BETWEEN z.min_lng AND z.max_lng
           AND ventas.fn_punto_en_zona(
                   ventas.fn_coordenada_lat(c.coordenadas),
                   ventas.fn_coordenada_lng(c.coordenadas),
                   z.tipo, z.vertices, z.centro_lat, z.centro_lng, z.radio_metros)
           AND (v_filtro IS NULL
                OR ventas.fn_sin_tildes(c.nombre_completo)       LIKE '%' || ventas.fn_sin_tildes(v_filtro) || '%'
                OR ventas.fn_sin_tildes(c.numero_identificacion) LIKE '%' || ventas.fn_sin_tildes(v_filtro) || '%'
                OR ventas.fn_sin_tildes(c.direccion)             LIKE '%' || ventas.fn_sin_tildes(v_filtro) || '%')
    ),
    pagina AS (
        SELECT * FROM dentro ORDER BY nombre_completo
         LIMIT v_per_page OFFSET (v_page - 1) * v_per_page
    )
    SELECT (SELECT COUNT(*) FROM dentro),
           COALESCE((SELECT jsonb_agg(to_jsonb(p) ORDER BY p.nombre_completo) FROM pagina p), '[]'::jsonb)
      INTO v_total, v_data;

    SELECT ventas.fn_zonas_json(p_zona_id) INTO v_zona;

    RETURN jsonb_build_object(
        'success', true,
        'message', 'Clientes de la zona obtenidos exitosamente',
        'data', v_data,
        'zona', v_zona,
        'meta', jsonb_build_object(
            'total',        v_total,
            'per_page',     v_per_page,
            'current_page', v_page,
            'last_page',    GREATEST(CEIL(v_total::numeric / v_per_page)::integer, 1)
        )
    );
END;
$function$;


-- ===========================================================================
-- 7. BORRAR
-- ===========================================================================

/**
 * Borra la zona.
 *
 * Se borra de verdad y no con `deleted_at`: una zona no la referencia nada
 * —los clientes no guardan a qué zona pertenecen, se calcula— así que no deja
 * huérfanos. Y la auditoría se queda con el antes y el después.
 */
CREATE OR REPLACE FUNCTION ventas.fn_zonas_eliminar(
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
SET search_path TO 'pg_catalog', 'ventas', 'auditoria'
AS $function$
DECLARE
    v_nombre varchar;
BEGIN
    PERFORM ventas.fn_gestiones_contexto(p_usuario_id, p_usuario_login, p_usuario_nombre,
                                         p_ip_address, p_user_agent, p_request_id, 'ventas.zonas');

    SELECT nombre INTO v_nombre FROM ventas.zonas WHERE id = p_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'La zona no existe' USING ERRCODE = 'P0013';
    END IF;

    DELETE FROM ventas.zonas WHERE id = p_id;

    RETURN jsonb_build_object('success', true, 'message', 'Zona «' || v_nombre || '» eliminada');
END;
$function$;
