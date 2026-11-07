-- ===========================================================================
-- LA SUCURSAL SOBRE EL TERRENO: SU PUNTO, SU ENLACE DE GOOGLE Y SUS FOTOS
-- ===========================================================================
-- Hasta aquí la sucursal sólo tenía el perímetro, que sirve para decidir si
-- alguien puede marcar. Falta lo que hace falta para LLEGAR y para RECONOCER
-- el local:
--
--   latitud / longitud  el punto de la sucursal (la puerta), que puede no ser
--                       el centro del perímetro. Si no se dice, se deduce del
--                       perímetro: el centro del círculo o el promedio de las
--                       esquinas del área.
--   link_ubicacion      el enlace de Google Maps a ese punto. Se arma AQUÍ, al
--                       guardar, igual que en rh.marcaciones: así el listado,
--                       un reporte o un WhatsApp lo llevan hecho y nadie tiene
--                       que recomponerlo.
--   mapa_foto           la captura del mapa con el perímetro dibujado.
--   foto                una foto del local, de la galería.
--
-- LAS IMÁGENES NO SE GUARDAN EN LA BASE: aquí va sólo el nombre del fichero,
-- como en inventarios.marcas (logo) y rh.empleados (foto). El fichero vive en
-- storage/app/public/img/sucursales.
--
-- Se aplica sobre 2026-10-20_ventas_sucursales.sql.
\set ON_ERROR_STOP on

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. LAS COLUMNAS
-- ---------------------------------------------------------------------------
ALTER TABLE ventas.sucursales
    ADD COLUMN IF NOT EXISTS latitud        numeric(10,7),
    ADD COLUMN IF NOT EXISTS longitud       numeric(10,7),
    ADD COLUMN IF NOT EXISTS link_ubicacion text,
    ADD COLUMN IF NOT EXISTS foto           varchar(150),
    ADD COLUMN IF NOT EXISTS mapa_foto      varchar(150);

COMMENT ON COLUMN ventas.sucursales.latitud        IS 'El punto de la sucursal (la puerta); si no se indica, se deduce del perímetro';
COMMENT ON COLUMN ventas.sucursales.longitud       IS 'El punto de la sucursal (la puerta); si no se indica, se deduce del perímetro';
COMMENT ON COLUMN ventas.sucursales.link_ubicacion IS 'Enlace de Google Maps al punto; lo arma la base al guardar';
COMMENT ON COLUMN ventas.sucursales.foto           IS 'Nombre del fichero de la foto del local (storage/app/public/img/sucursales)';
COMMENT ON COLUMN ventas.sucursales.mapa_foto      IS 'Nombre del fichero de la captura del mapa';

-- El punto tiene que caer en el mundo; los dos o ninguno
ALTER TABLE ventas.sucursales DROP CONSTRAINT IF EXISTS ck_sucursales_punto;
ALTER TABLE ventas.sucursales ADD CONSTRAINT ck_sucursales_punto CHECK (
    (latitud IS NULL AND longitud IS NULL)
 OR (latitud BETWEEN -90 AND 90 AND longitud BETWEEN -180 AND 180));

-- ---------------------------------------------------------------------------
-- 2. EL ENLACE DE GOOGLE
-- ---------------------------------------------------------------------------
-- FM999990.000000 y no ::text: el `to_char` por defecto mete espacios y notación
-- rara en los negativos, y una coordenada mal escrita en la url lleva a otro
-- sitio sin avisar. Es el mismo formato que usa rh.fn_marcaciones_registrar.
CREATE OR REPLACE FUNCTION ventas.fn_sucursales_link(p_lat numeric, p_lng numeric)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $function$
    SELECT CASE WHEN p_lat IS NULL OR p_lng IS NULL THEN NULL
                ELSE 'https://www.google.com/maps/search/?api=1&query='
                     || to_char(p_lat, 'FM999990.000000') || ','
                     || to_char(p_lng, 'FM999990.000000')
           END;
$function$;

-- El punto que se guarda: el que digan, o el del perímetro.
CREATE OR REPLACE FUNCTION ventas.fn_sucursales_punto(
    p_lat numeric, p_lng numeric,
    p_tipo varchar, p_vertices jsonb, p_centro_lat numeric, p_centro_lng numeric
)
RETURNS numeric[]
LANGUAGE plpgsql
IMMUTABLE
AS $function$
DECLARE v_lat numeric; v_lng numeric;
BEGIN
    IF p_lat IS NOT NULL AND p_lng IS NOT NULL THEN
        RETURN ARRAY[p_lat, p_lng];
    END IF;

    IF UPPER(COALESCE(p_tipo, 'POLIGONO')) = 'CIRCULO' THEN
        RETURN ARRAY[p_centro_lat, p_centro_lng];
    END IF;

    -- El promedio de las esquinas. No es el centroide exacto de un polígono
    -- irregular, pero cae dentro de un local y es con lo que se abre el mapa.
    IF p_vertices IS NOT NULL AND jsonb_typeof(p_vertices) = 'array'
       AND jsonb_array_length(p_vertices) >= 3 THEN
        SELECT round(avg((v->>'lat')::numeric), 7), round(avg((v->>'lng')::numeric), 7)
          INTO v_lat, v_lng
          FROM jsonb_array_elements(p_vertices) AS v;
        RETURN ARRAY[v_lat, v_lng];
    END IF;

    RETURN ARRAY[NULL::numeric, NULL::numeric];
END;
$function$;

-- Las que ya existen: su punto sale del perímetro que tengan
UPDATE ventas.sucursales s
   SET latitud  = (ventas.fn_sucursales_punto(NULL, NULL, s.tipo, s.vertices, s.centro_lat, s.centro_lng))[1],
       longitud = (ventas.fn_sucursales_punto(NULL, NULL, s.tipo, s.vertices, s.centro_lat, s.centro_lng))[2]
 WHERE s.latitud IS NULL;

UPDATE ventas.sucursales
   SET link_ubicacion = ventas.fn_sucursales_link(latitud, longitud)
 WHERE latitud IS NOT NULL AND link_ubicacion IS NULL;

-- ---------------------------------------------------------------------------
-- 3. EL JSON QUE VE LA PANTALLA
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
-- 4. VALIDAR, CREAR Y MODIFICAR CON EL PUNTO
-- ---------------------------------------------------------------------------
-- Se tiran y se vuelven a crear porque cambian los parámetros: con
-- CREATE OR REPLACE quedarían DOS versiones y la llamada sería ambigua.
DROP FUNCTION IF EXISTS ventas.fn_sucursales_validar(bigint, varchar, varchar, varchar, jsonb, numeric, numeric, numeric);

CREATE OR REPLACE FUNCTION ventas.fn_sucursales_validar(
    p_id bigint, p_codigo varchar, p_nombre varchar, p_tipo varchar,
    p_vertices jsonb, p_centro_lat numeric, p_centro_lng numeric, p_radio numeric,
    p_latitud numeric DEFAULT NULL, p_longitud numeric DEFAULT NULL
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

    -- El punto de la sucursal: los dos o ninguno, y dentro del mundo
    IF (p_latitud IS NULL) <> (p_longitud IS NULL) THEN
        RAISE EXCEPTION 'La ubicación necesita latitud y longitud' USING ERRCODE = 'P0015';
    END IF;
    IF p_latitud IS NOT NULL
       AND (p_latitud NOT BETWEEN -90 AND 90 OR p_longitud NOT BETWEEN -180 AND 180) THEN
        RAISE EXCEPTION 'Las coordenadas de la sucursal están fuera de rango' USING ERRCODE = 'P0015';
    END IF;
END;
$function$;

DROP FUNCTION IF EXISTS ventas.fn_sucursales_crear(varchar, varchar, varchar, varchar, varchar, varchar, varchar, jsonb, numeric, numeric, numeric, numeric, boolean, bigint, varchar, varchar, inet, text, uuid);

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
    p_latitud         numeric DEFAULT NULL,      -- el punto de la sucursal
    p_longitud        numeric DEFAULT NULL,
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
        codigo, nombre, direccion, telefono, email,
        tipo, color, vertices, centro_lat, centro_lng, radio_metros,
        min_lat, max_lat, min_lng, max_lng, tolerancia_metros, activo,
        latitud, longitud, link_ubicacion)
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

DROP FUNCTION IF EXISTS ventas.fn_sucursales_modificar(bigint, varchar, varchar, varchar, varchar, varchar, varchar, varchar, jsonb, numeric, numeric, numeric, numeric, boolean, bigint, varchar, varchar, inet, text, uuid);

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
    p_latitud         numeric DEFAULT NULL,
    p_longitud        numeric DEFAULT NULL,
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
-- 5. LAS FOTOS
-- ---------------------------------------------------------------------------
-- Una sola función para las dos, con el campo por parámetro: lo que cambia es
-- la columna, y tener dos funciones gemelas sólo garantiza que una se quede
-- atrás. `p_archivo` nulo quita la foto.
CREATE OR REPLACE FUNCTION ventas.fn_sucursales_foto(
    p_id             bigint,
    p_campo          text,                       -- 'foto' | 'mapa'
    p_archivo        varchar DEFAULT NULL,
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
    v_campo text := LOWER(COALESCE(p_campo, ''));
    v_antes varchar;
BEGIN
    IF v_campo NOT IN ('foto', 'mapa') THEN
        RAISE EXCEPTION 'La foto debe ser «foto» o «mapa»' USING ERRCODE = 'P0015';
    END IF;

    PERFORM ventas.fn_contexto_auditoria('ventas.sucursales',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    SELECT CASE WHEN v_campo = 'foto' THEN foto ELSE mapa_foto END
      INTO v_antes
      FROM ventas.sucursales WHERE id = p_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'La sucursal no existe' USING ERRCODE = 'P0013';
    END IF;

    UPDATE ventas.sucursales
       SET foto      = CASE WHEN v_campo = 'foto' THEN p_archivo ELSE foto END,
           mapa_foto = CASE WHEN v_campo = 'mapa' THEN p_archivo ELSE mapa_foto END
     WHERE id = p_id;

    RETURN jsonb_build_object('success', true,
        'message', CASE WHEN p_archivo IS NULL
                        THEN 'Imagen quitada'
                        ELSE CASE WHEN v_campo = 'foto' THEN 'Foto de la sucursal guardada'
                                  ELSE 'Captura del mapa guardada' END END,
        'data', ventas.fn_sucursales_json(p_id) || jsonb_build_object('anterior', v_antes));
END;
$function$;

-- ---------------------------------------------------------------------------
-- 6. AL BORRAR DE VERDAD, QUE SE LLEVEN SUS FICHEROS
-- ---------------------------------------------------------------------------
-- La base no puede borrar un fichero del disco: devuelve sus nombres y el
-- controlador los borra, igual que hace el de marcas con los logotipos.
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
    v_nombres   text[];
    v_ficheros  text[];
    v_cuantas   integer;
BEGIN
    PERFORM ventas.fn_contexto_auditoria('ventas.sucursales',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    SELECT array_agg(nombre),
           array_remove(array_agg(foto) || array_agg(mapa_foto), NULL)
      INTO v_nombres, v_ficheros
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
        'data', jsonb_build_object('nombres', to_jsonb(v_nombres),
                                   'ficheros', to_jsonb(COALESCE(v_ficheros, ARRAY[]::text[])),
                                   'eliminadas', v_cuantas));
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
DECLARE
    v_cuantas  integer;
    v_ficheros text[];
BEGIN
    PERFORM ventas.fn_contexto_auditoria('ventas.sucursales',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    -- Las que todavía tienen gente asignada no se van: romperían la ficha
    -- de esos empleados.
    WITH borradas AS (
        DELETE FROM ventas.sucursales s
         WHERE s.deleted_at IS NOT NULL
           AND NOT EXISTS (SELECT 1 FROM rh.empleados e WHERE e.sucursal_id = s.id)
        RETURNING s.foto, s.mapa_foto
    )
    SELECT COUNT(*)::integer,
           array_remove(array_agg(foto) || array_agg(mapa_foto), NULL)
      INTO v_cuantas, v_ficheros
      FROM borradas;

    RETURN jsonb_build_object('success', true,
        'message', 'Papelera vaciada: ' || v_cuantas || ' sucursal(es) eliminada(s)',
        'data', jsonb_build_object('eliminadas', v_cuantas,
                                   'ficheros', to_jsonb(COALESCE(v_ficheros, ARRAY[]::text[]))));
END;
$function$;

COMMIT;

-- ===========================================================================
-- COMPROBAR
-- ===========================================================================
-- SELECT id, codigo, coordenadas, link_ubicacion, tiene_foto, tiene_mapa
--   FROM ventas.sucursales s, LATERAL jsonb_to_record(ventas.fn_sucursales_json(s.id))
--        AS x(coordenadas text, link_ubicacion text, tiene_foto boolean, tiene_mapa boolean);
