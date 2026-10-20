-- ===========================================================================
-- RECORRIDOS DEL COBRADOR: POR DÓNDE ANDUVO Y DÓNDE SE PARÓ
-- ===========================================================================
-- Fecha: 2026-10-19
--
-- El celular del cobrador va mandando su posición durante la jornada. Aquí se
-- guardan esas lecturas y se contesta la pregunta que importa: por dónde pasó,
-- cuánto caminó, dónde se detuvo y cuánto rato, y si esas paradas coinciden
-- con clientes de la cartera.
--
-- ---------------------------------------------------------------------------
-- UNA SOLA TABLA DE PUNTOS, SIN CABECERA DE «JORNADA»
-- ---------------------------------------------------------------------------
-- Lo natural parecería una tabla «recorridos» (una fila por cobrador y día) y
-- otra de puntos colgando. No se hace, y la razón es el aparato: el celular
-- pierde señal, se queda sin batería, el sistema mata la aplicación en segundo
-- plano y el cobrador la vuelve a abrir a media mañana. Con cabecera, cada uno
-- de esos cortes obliga a decidir si se abre otra jornada o se reutiliza la de
-- antes, y esa decisión la tendría que tomar el celular, que es justo el que
-- menos sabe.
--
-- Sin cabecera no hay nada que decidir: el celular manda puntos sueltos y el
-- día es el resultado de agruparlos. Si la aplicación estuvo cerrada tres
-- horas, el recorrido tendrá un hueco de tres horas, que es exactamente la
-- verdad y es un dato de control, no un problema que ocultar.
--
-- ---------------------------------------------------------------------------
-- POR QUÉ (usuario_id, fecha_hora) ES ÚNICO
-- ---------------------------------------------------------------------------
-- El celular trabaja sin conexión y manda por lotes cuando la encuentra. Si el
-- envío se corta a la mitad, reintenta el lote entero. Con la restricción única
-- y el ON CONFLICT DO NOTHING de la función de carga, reenviar lo mismo no
-- duplica nada: se puede reintentar tantas veces como haga falta. Sin eso, un
-- túnel y un reintento convierten un recorrido de 8 km en uno de 16.
--
-- ---------------------------------------------------------------------------
-- LA COLUMNA «fecha» NO ES REDUNDANTE
-- ---------------------------------------------------------------------------
-- fecha_hora es timestamptz y el día del cobrador es un día de America/
-- Guayaquil. Convertir en cada consulta (fecha_hora AT TIME ZONE …)::date no
-- es IMMUTABLE, así que ni sirve para una columna generada ni puede indexarse
-- de forma útil. Se guarda el día ya resuelto —lo hace la función de carga, no
-- quien llame— y el índice por (usuario_id, fecha) deja la consulta del día en
-- una lectura de índice.
--
-- ---------------------------------------------------------------------------
-- LAS PARADAS SE CALCULAN, NO SE GUARDAN
-- ---------------------------------------------------------------------------
-- Igual que las zonas no guardan sus clientes. Qué cuenta como parada depende
-- de con qué criterio se mire —60 metros y 5 minutos para una visita, 200 y 20
-- para un almuerzo— y si estuviera guardado habría que recalcular la historia
-- entera cada vez que alguien cambia de opinión. Se pasa el criterio como
-- parámetro y se calcula al vuelo: un día son unos mil puntos.
--
-- Depende de ventas.fn_distancia_metros y ventas.fn_coordenada_lat/lng, que ya
-- existen desde 2026-10-10_ventas_zonas.sql.
--
-- Idempotente.
-- ===========================================================================

BEGIN;

-- ===========================================================================
-- 1. LA TABLA
-- ===========================================================================
CREATE TABLE IF NOT EXISTS ventas.recorrido_puntos (
    id           bigserial     NOT NULL,

    -- De quién es el recorrido. No se limita a los de tipo «AGENTE COBRADOR»:
    -- un vendedor que sale a la calle deja el mismo rastro y la pantalla sirve
    -- igual. Quién puede verlo es cosa de los permisos, no de la tabla.
    usuario_id   bigint        NOT NULL,

    -- Cuándo lo midió el aparato, NO cuándo llegó al servidor. Es la
    -- diferencia entre reconstruir el recorrido y reconstruir el orden en que
    -- se recuperó la señal.
    fecha_hora   timestamptz   NOT NULL,

    -- El día del cobrador, en hora de Ecuador. Lo pone fn_recorridos_registrar.
    fecha        date          NOT NULL,

    lat          numeric(10,7) NOT NULL,
    lng          numeric(10,7) NOT NULL,

    -- Radio de error que declara el GPS, en metros. Importa para el control:
    -- una «parada» construida con lecturas de 500 m de error no prueba nada, y
    -- la pantalla avisa en vez de dar por buena una visita que no se puede
    -- sostener.
    precision_m  numeric(8,2),

    altitud      numeric(8,2),
    -- m/s, tal como lo da el aparato
    velocidad    numeric(6,2),
    -- grados desde el norte
    rumbo        numeric(5,1),

    -- Para saber si el hueco en el recorrido fue el cobrador o fue el celular
    bateria      smallint,
    dispositivo  varchar(120),

    created_at   timestamptz   DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT pk_recorrido_puntos PRIMARY KEY (id),

    CONSTRAINT fk_recorrido_puntos_usuario
        FOREIGN KEY (usuario_id) REFERENCES seguridad.users (id)
        ON UPDATE NO ACTION ON DELETE CASCADE,

    -- Reenviar un lote no duplica. Ver la cabecera.
    CONSTRAINT uq_recorrido_puntos_lectura UNIQUE (usuario_id, fecha_hora),

    CONSTRAINT ck_recorrido_puntos_grados CHECK (
        lat BETWEEN -90 AND 90 AND lng BETWEEN -180 AND 180
    ),

    -- Un punto exactamente en (0,0) es el Golfo de Guinea: siempre es un GPS
    -- que contestó sin tener posición, nunca un cobrador.
    CONSTRAINT ck_recorrido_puntos_nulo CHECK (NOT (lat = 0 AND lng = 0)),

    CONSTRAINT ck_recorrido_puntos_precision CHECK (precision_m IS NULL OR precision_m >= 0),
    CONSTRAINT ck_recorrido_puntos_bateria   CHECK (bateria IS NULL OR bateria BETWEEN 0 AND 100)
);

COMMENT ON TABLE  ventas.recorrido_puntos IS 'Lecturas de GPS del celular del cobrador; el recorrido se arma agrupándolas';
COMMENT ON COLUMN ventas.recorrido_puntos.fecha_hora  IS 'Cuándo lo midió el aparato, no cuándo llegó al servidor';
COMMENT ON COLUMN ventas.recorrido_puntos.fecha       IS 'El día del cobrador en America/Guayaquil; lo resuelve la función de carga';
COMMENT ON COLUMN ventas.recorrido_puntos.precision_m IS 'Radio de error del GPS en metros; por encima de ~50 una parada no prueba una visita';
COMMENT ON COLUMN ventas.recorrido_puntos.bateria     IS 'Para distinguir un hueco del cobrador de un hueco del celular';

-- La consulta de la pantalla es siempre «este cobrador, este día, en orden».
CREATE INDEX IF NOT EXISTS idx_recorrido_puntos_dia
    ON ventas.recorrido_puntos (usuario_id, fecha, fecha_hora);

-- Y el listado de «quién anduvo tal día»
CREATE INDEX IF NOT EXISTS idx_recorrido_puntos_fecha
    ON ventas.recorrido_puntos (fecha);

-- ===========================================================================
-- 2. CARGA: LO QUE MANDA EL CELULAR
-- ===========================================================================

-- La firma cambió el 2026-10-19 (se separó el cobrador del usuario que
-- audita). CREATE OR REPLACE no puede cambiar la lista de parámetros.
DROP FUNCTION IF EXISTS ventas.fn_recorridos_registrar(bigint, jsonb, varchar, numeric, varchar, varchar, inet, text, uuid);

/**
 * Guarda un lote de lecturas.
 *
 * p_puntos es un array de objetos, tal y como los entrega el GPS del celular:
 *
 *   [{"fecha_hora":"2026-10-19T08:15:00-05:00","lat":-2.1709,"lng":-79.9224,
 *     "precision_m":12.5,"altitud":30,"velocidad":1.2,"rumbo":180,"bateria":85}, …]
 *
 * Obligatorios: fecha_hora, lat y lng. Lo demás viaja si el aparato lo sabe.
 *
 * Reenviar el mismo lote no duplica: ON CONFLICT DO NOTHING sobre
 * (usuario_id, fecha_hora). Devuelve cuántos entraron y cuántos ya estaban,
 * que es lo que el celular necesita para saber si puede borrar su cola.
 *
 * Los puntos imposibles se descartan en silencio en vez de tumbar el lote
 * entero: un GPS que contesta (0,0) o una lectura con 2.000 m de error no
 * valen nada, pero el resto del lote sí, y rechazarlo todo dejaría al celular
 * reintentando para siempre un lote que nunca va a entrar.
 */
CREATE OR REPLACE FUNCTION ventas.fn_recorridos_registrar(
    -- De quién es el recorrido. Hoy el controlador manda aquí el mismo
    -- usuario del token que en p_usuario_id, porque un cobrador sólo sube lo
    -- suyo; van separados para no cerrar la puerta a que mañana un supervisor
    -- cargue el recorrido de otro, y para que la auditoría siga diciendo
    -- QUIÉN escribió y no sólo DE QUIÉN era.
    p_cobrador_id     bigint   DEFAULT NULL,
    p_puntos          jsonb    DEFAULT NULL,
    p_dispositivo     varchar  DEFAULT NULL,
    p_precision_max   numeric  DEFAULT 1000,
    -- Los mismos seis parámetros de auditoría que el resto del módulo
    p_usuario_id      bigint   DEFAULT NULL,
    p_usuario_login   varchar  DEFAULT NULL,
    p_usuario_nombre  varchar  DEFAULT NULL,
    p_ip_address      inet     DEFAULT NULL,
    p_user_agent      text     DEFAULT NULL,
    p_request_id      uuid     DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'ventas', 'seguridad', 'auditoria'
AS $function$
DECLARE
    v_guardados  integer := 0;
    v_repetidos  integer := 0;
    v_descartados integer := 0;
    v_total      integer := 0;
BEGIN
    PERFORM ventas.fn_gestiones_contexto(p_usuario_id, p_usuario_login, p_usuario_nombre,
                                         p_ip_address, p_user_agent, p_request_id,
                                         'ventas.recorrido_puntos');

    IF p_cobrador_id IS NULL THEN
        RAISE EXCEPTION 'Falta el usuario del recorrido' USING ERRCODE = 'P0001';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM seguridad.users u WHERE u.id = p_cobrador_id) THEN
        RAISE EXCEPTION 'El usuario no existe' USING ERRCODE = 'P0013';
    END IF;

    IF p_puntos IS NULL OR jsonb_typeof(p_puntos) <> 'array' THEN
        RAISE EXCEPTION 'Los puntos deben venir en una lista' USING ERRCODE = 'P0001';
    END IF;

    v_total := jsonb_array_length(p_puntos);
    IF v_total = 0 THEN
        RETURN jsonb_build_object(
            'success', true, 'message', 'No había puntos que guardar',
            'data', jsonb_build_object('recibidos', 0, 'guardados', 0, 'repetidos', 0, 'descartados', 0));
    END IF;

    -- Primero se limpia el lote y después se inserta de una vez. Hacerlo
    -- punto a punto en un bucle serían mil INSERT por jornada.
    WITH crudo AS (
        SELECT
            (p->>'fecha_hora')::timestamptz        AS fecha_hora,
            (p->>'lat')::numeric                   AS lat,
            (p->>'lng')::numeric                   AS lng,
            NULLIF(p->>'precision_m', '')::numeric AS precision_m,
            NULLIF(p->>'altitud', '')::numeric     AS altitud,
            NULLIF(p->>'velocidad', '')::numeric   AS velocidad,
            NULLIF(p->>'rumbo', '')::numeric       AS rumbo,
            NULLIF(p->>'bateria', '')::smallint    AS bateria
        FROM jsonb_array_elements(p_puntos) AS p
        WHERE p->>'fecha_hora' IS NOT NULL
          AND p->>'lat' IS NOT NULL
          AND p->>'lng' IS NOT NULL
    ),
    bueno AS (
        SELECT * FROM crudo
         WHERE lat BETWEEN -90 AND 90
           AND lng BETWEEN -180 AND 180
           AND NOT (lat = 0 AND lng = 0)
           AND (precision_m IS NULL OR precision_m <= COALESCE(p_precision_max, 1000))
           -- Una lectura del futuro es el reloj del celular mal puesto. Se
           -- deja un margen de una hora por si va adelantado de verdad.
           AND fecha_hora <= CURRENT_TIMESTAMP + interval '1 hour'
    ),
    metido AS (
        INSERT INTO ventas.recorrido_puntos
            (usuario_id, fecha_hora, fecha, lat, lng, precision_m, altitud, velocidad, rumbo, bateria, dispositivo)
        SELECT
            p_cobrador_id,
            b.fecha_hora,
            (b.fecha_hora AT TIME ZONE 'America/Guayaquil')::date,
            b.lat, b.lng, b.precision_m, b.altitud, b.velocidad, b.rumbo, b.bateria,
            NULLIF(TRIM(COALESCE(p_dispositivo, '')), '')
        FROM bueno b
        ON CONFLICT ON CONSTRAINT uq_recorrido_puntos_lectura DO NOTHING
        RETURNING 1
    )
    SELECT
        (SELECT COUNT(*) FROM metido),
        (SELECT COUNT(*) FROM bueno)
    INTO v_guardados, v_repetidos;

    -- v_repetidos traía los que pasaron el filtro; los repetidos son los que
    -- pasaron menos los que entraron.
    v_descartados := v_total - v_repetidos;
    v_repetidos   := v_repetidos - v_guardados;

    RETURN jsonb_build_object(
        'success', true,
        'message', 'Recorrido recibido',
        'data', jsonb_build_object(
            'recibidos',   v_total,
            'guardados',   v_guardados,
            'repetidos',   v_repetidos,
            'descartados', v_descartados
        ));
EXCEPTION
    WHEN SQLSTATE 'P0001' OR SQLSTATE 'P0013' THEN
        RAISE;
    WHEN OTHERS THEN
        RETURN jsonb_build_object('success', false,
            'message', 'Error al guardar el recorrido: ' || SQLERRM, 'error_code', SQLSTATE);
END;
$function$;


-- ===========================================================================
-- 3. LEER: QUIÉN ANDUVO Y QUÉ DÍAS
-- ===========================================================================

/**
 * Los usuarios que dejaron rastro en un rango de fechas, con un resumen.
 *
 * Es lo que llena el desplegable de la pantalla. No lista «los cobradores»
 * sino «los que tienen recorrido»: un desplegable con cuarenta nombres de los
 * que treinta y ocho no mandaron nada obliga a ir probando uno por uno.
 */
CREATE OR REPLACE FUNCTION ventas.fn_recorridos_cobradores(
    p_desde date DEFAULT NULL,
    p_hasta date DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'ventas', 'seguridad'
AS $function$
DECLARE
    v_desde date := COALESCE(p_desde, CURRENT_DATE - 30);
    v_hasta date := COALESCE(p_hasta, CURRENT_DATE);
    v_data  jsonb;
BEGIN
    SELECT COALESCE(jsonb_agg(x ORDER BY x->>'nombre'), '[]'::jsonb) INTO v_data
    FROM (
        SELECT jsonb_build_object(
            'usuario_id', u.id,
            'login_user', u.login_user,
            'nombre',     TRIM(COALESCE(u.name, '') || ' ' || COALESCE(u.surname, '')),
            'type_user',  u.type_user,
            'dias',       COUNT(DISTINCT rp.fecha),
            'puntos',     COUNT(*),
            'primer_dia', MIN(rp.fecha)::text,
            'ultimo_dia', MAX(rp.fecha)::text
        ) AS x
        FROM ventas.recorrido_puntos rp
        JOIN seguridad.users u ON u.id = rp.usuario_id
        WHERE rp.fecha BETWEEN v_desde AND v_hasta
        GROUP BY u.id, u.login_user, u.name, u.surname, u.type_user
    ) s;

    RETURN jsonb_build_object('success', true, 'message', 'Cobradores con recorrido', 'data', v_data);
EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object('success', false,
            'message', 'Error al listar los cobradores: ' || SQLERRM, 'error_code', SQLSTATE);
END;
$function$;


/**
 * Qué días tiene recorrido un usuario, con los kilómetros de cada uno.
 *
 * Sirve para el calendario de la pantalla: se ve de un vistazo qué días salió
 * y cuáles no, que es la mitad del control.
 */
CREATE OR REPLACE FUNCTION ventas.fn_recorridos_dias(
    p_usuario_id bigint DEFAULT NULL,
    p_desde      date   DEFAULT NULL,
    p_hasta      date   DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'ventas'
AS $function$
DECLARE
    v_desde date := COALESCE(p_desde, CURRENT_DATE - 30);
    v_hasta date := COALESCE(p_hasta, CURRENT_DATE);
    v_data  jsonb;
BEGIN
    IF p_usuario_id IS NULL THEN
        RAISE EXCEPTION 'Falta el usuario' USING ERRCODE = 'P0001';
    END IF;

    -- Los metros del día se suman aquí con una ventana: la distancia de cada
    -- punto al anterior. Es la misma cuenta que hace fn_recorridos_del_dia,
    -- pero sin traerse los puntos, que para pintar un calendario sobran.
    WITH tramos AS (
        SELECT
            rp.fecha,
            ventas.fn_distancia_metros(
                LAG(rp.lat) OVER (PARTITION BY rp.fecha ORDER BY rp.fecha_hora),
                LAG(rp.lng) OVER (PARTITION BY rp.fecha ORDER BY rp.fecha_hora),
                rp.lat, rp.lng) AS metros
        FROM ventas.recorrido_puntos rp
        WHERE rp.usuario_id = p_usuario_id
          AND rp.fecha BETWEEN v_desde AND v_hasta
    )
    SELECT COALESCE(jsonb_agg(x ORDER BY x->>'fecha' DESC), '[]'::jsonb) INTO v_data
    FROM (
        SELECT jsonb_build_object(
            'fecha',  t.fecha::text,
            'puntos', COUNT(*),
            'metros', ROUND(COALESCE(SUM(t.metros), 0), 0),
            -- Los km salen de los metros YA redondeados, igual que en
            -- fn_recorridos_del_dia. Dividiendo la suma cruda, el mismo día
            -- sale 0,73 en el desplegable y 0,74 en el resumen, y quien lo ve
            -- deja de creerse los dos números.
            'km',     ROUND(ROUND(COALESCE(SUM(t.metros), 0), 0) / 1000.0, 2)
        ) AS x
        FROM tramos t
        GROUP BY t.fecha
    ) s;

    RETURN jsonb_build_object('success', true, 'message', 'Días con recorrido', 'data', v_data);
EXCEPTION
    WHEN SQLSTATE 'P0001' THEN
        RAISE;
    WHEN OTHERS THEN
        RETURN jsonb_build_object('success', false,
            'message', 'Error al listar los días: ' || SQLERRM, 'error_code', SQLSTATE);
END;
$function$;


-- ===========================================================================
-- 4. EL RECORRIDO DE UN DÍA, QUE ES LO QUE SE VIENE A BUSCAR
-- ===========================================================================

/**
 * El recorrido de un usuario en un día: los puntos, el resumen y las paradas.
 *
 * QUÉ CUENTA COMO PARADA. Se recorren las lecturas en orden con un ancla. Una
 * lectura que cae a menos de p_radio_parada metros del ancla alarga la parada;
 * la primera que se sale, la cierra. Si duró al menos p_minutos_parada, se
 * emite. El centro que se devuelve es el promedio de sus lecturas, no el
 * ancla: el GPS quieto sigue bailando unos metros y el promedio cae más cerca
 * de donde el cobrador estuvo de verdad.
 *
 * Los valores por defecto —60 metros y 5 minutos— son los de una visita a un
 * cliente. Un semáforo largo no llega a 5 minutos y un almuerzo se ve como una
 * parada de 40; ambas cosas se quieren ver, y distinguirlas es de quien mira.
 *
 * EL CLIENTE DE CADA PARADA. Se busca el cliente con coordenadas más cercano
 * al centro de la parada dentro de p_radio_cliente metros. Es la pregunta de
 * control: paró aquí veinte minutos, ¿hay un cliente aquí? Que no salga
 * ninguno no prueba nada malo —pudo almorzar, cargar gasolina o visitar a uno
 * sin coordenadas en la ficha—, y por eso se devuelve el dato, no un veredicto.
 */
CREATE OR REPLACE FUNCTION ventas.fn_recorridos_del_dia(
    p_usuario_id     bigint  DEFAULT NULL,
    p_fecha          date    DEFAULT NULL,
    p_radio_parada   numeric DEFAULT 60,
    p_minutos_parada integer DEFAULT 5,
    p_radio_cliente  numeric DEFAULT 80
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'ventas', 'seguridad'
AS $function$
DECLARE
    v_fecha    date    := COALESCE(p_fecha, CURRENT_DATE);
    v_radio    numeric := GREATEST(COALESCE(p_radio_parada, 60), 5);
    v_minutos  integer := GREATEST(COALESCE(p_minutos_parada, 5), 1);
    v_rcliente numeric := GREATEST(COALESCE(p_radio_cliente, 80), 5);

    v_usuario  jsonb;
    v_puntos   jsonb;
    v_resumen  jsonb;
    v_paradas  jsonb := '[]'::jsonb;

    v_total    integer := 0;
    v_metros   numeric := 0;
    v_inicio   timestamptz;
    v_fin      timestamptz;
    v_malas    integer := 0;

    r          record;
    v_alat numeric; v_alng numeric;
    v_desde timestamptz; v_hasta timestamptz;
    v_slat numeric; v_slng numeric;
    v_cuenta integer := 0;
    v_peor numeric;
    v_abierta boolean := false;

    v_crudas jsonb[] := ARRAY[]::jsonb[];
    v_p jsonb;
    v_cliente jsonb;
    v_orden integer := 0;
BEGIN
    IF p_usuario_id IS NULL THEN
        RAISE EXCEPTION 'Falta el usuario del recorrido' USING ERRCODE = 'P0001';
    END IF;

    SELECT jsonb_build_object(
        'usuario_id', u.id,
        'login_user', u.login_user,
        'nombre',     TRIM(COALESCE(u.name, '') || ' ' || COALESCE(u.surname, '')),
        'type_user',  u.type_user
    ) INTO v_usuario
    FROM seguridad.users u WHERE u.id = p_usuario_id;

    IF v_usuario IS NULL THEN
        RAISE EXCEPTION 'El usuario no existe' USING ERRCODE = 'P0013';
    END IF;

    -- --------------------------------------------------------------
    -- Los puntos y los metros, en una pasada
    -- --------------------------------------------------------------
    WITH base AS (
        SELECT rp.*,
               ROW_NUMBER() OVER (ORDER BY rp.fecha_hora) AS orden,
               ventas.fn_distancia_metros(
                   LAG(rp.lat) OVER (ORDER BY rp.fecha_hora),
                   LAG(rp.lng) OVER (ORDER BY rp.fecha_hora),
                   rp.lat, rp.lng) AS tramo
          FROM ventas.recorrido_puntos rp
         WHERE rp.usuario_id = p_usuario_id AND rp.fecha = v_fecha
    )
    SELECT
        COUNT(*),
        ROUND(COALESCE(SUM(b.tramo), 0), 0),
        MIN(b.fecha_hora),
        MAX(b.fecha_hora),
        COUNT(*) FILTER (WHERE b.precision_m > 50),
        COALESCE(jsonb_agg(jsonb_build_object(
            'orden',       b.orden,
            'lat',         b.lat,
            'lng',         b.lng,
            'fecha_hora',  to_char(b.fecha_hora, 'YYYY-MM-DD HH24:MI:SS'),
            'hora',        to_char(b.fecha_hora, 'HH24:MI'),
            'precision_m', b.precision_m,
            'altitud',     b.altitud,
            'velocidad_kmh', CASE WHEN b.velocidad IS NULL THEN NULL
                                  ELSE ROUND(b.velocidad * 3.6, 1) END,
            'rumbo',       b.rumbo,
            'bateria',     b.bateria,
            'tramo_m',     ROUND(COALESCE(b.tramo, 0), 1)
        ) ORDER BY b.orden), '[]'::jsonb)
    INTO v_total, v_metros, v_inicio, v_fin, v_malas, v_puntos
    FROM base b;

    IF v_total = 0 THEN
        RETURN jsonb_build_object(
            'success', true,
            'message', 'Sin recorrido ese día',
            'data', jsonb_build_object(
                'usuario', v_usuario,
                'fecha',   v_fecha::text,
                'puntos',  '[]'::jsonb,
                'paradas', '[]'::jsonb,
                'resumen', jsonb_build_object(
                    'puntos', 0, 'metros', 0, 'km', 0,
                    'inicio', NULL, 'fin', NULL, 'minutos', 0,
                    'paradas', 0, 'minutos_parado', 0,
                    'velocidad_media_kmh', 0, 'lecturas_imprecisas', 0)
            ));
    END IF;

    -- --------------------------------------------------------------
    -- Las paradas: una pasada con ancla
    -- --------------------------------------------------------------
    FOR r IN
        SELECT rp.lat, rp.lng, rp.fecha_hora, rp.precision_m
          FROM ventas.recorrido_puntos rp
         WHERE rp.usuario_id = p_usuario_id AND rp.fecha = v_fecha
         ORDER BY rp.fecha_hora
    LOOP
        IF NOT v_abierta THEN
            v_alat := r.lat; v_alng := r.lng;
            v_desde := r.fecha_hora; v_hasta := r.fecha_hora;
            v_slat := r.lat; v_slng := r.lng; v_cuenta := 1;
            v_peor := r.precision_m;
            v_abierta := true;
        ELSIF ventas.fn_distancia_metros(v_alat, v_alng, r.lat, r.lng) <= v_radio THEN
            v_hasta := r.fecha_hora;
            v_slat := v_slat + r.lat; v_slng := v_slng + r.lng;
            v_cuenta := v_cuenta + 1;
            v_peor := GREATEST(COALESCE(v_peor, 0), COALESCE(r.precision_m, 0));
        ELSE
            IF EXTRACT(EPOCH FROM (v_hasta - v_desde)) >= v_minutos * 60 THEN
                v_crudas := v_crudas || jsonb_build_object(
                    'lat', ROUND(v_slat / v_cuenta, 7),
                    'lng', ROUND(v_slng / v_cuenta, 7),
                    'desde_ts', v_desde, 'hasta_ts', v_hasta,
                    'lecturas', v_cuenta, 'peor_precision_m', v_peor);
            END IF;
            v_alat := r.lat; v_alng := r.lng;
            v_desde := r.fecha_hora; v_hasta := r.fecha_hora;
            v_slat := r.lat; v_slng := r.lng; v_cuenta := 1;
            v_peor := r.precision_m;
        END IF;
    END LOOP;

    -- La última no la cierra ningún movimiento: suele ser el final de la
    -- jornada, que es justo la parada que interesa ver.
    IF v_abierta AND EXTRACT(EPOCH FROM (v_hasta - v_desde)) >= v_minutos * 60 THEN
        v_crudas := v_crudas || jsonb_build_object(
            'lat', ROUND(v_slat / v_cuenta, 7),
            'lng', ROUND(v_slng / v_cuenta, 7),
            'desde_ts', v_desde, 'hasta_ts', v_hasta,
            'lecturas', v_cuenta, 'peor_precision_m', v_peor);
    END IF;

    -- --------------------------------------------------------------
    -- A cada parada, su cliente más cercano (si lo hay)
    -- --------------------------------------------------------------
    FOREACH v_p IN ARRAY v_crudas LOOP
        v_orden := v_orden + 1;
        v_cliente := NULL;

        SELECT jsonb_build_object(
                   'id', c.id, 'nombre_completo', c.nombre_completo,
                   'direccion', c.direccion, 'celular', c.celular,
                   'metros', ROUND(c.d, 0))
          INTO v_cliente
          FROM (
            SELECT cl.id, cl.nombre_completo, cl.direccion, cl.celular,
                   ventas.fn_distancia_metros(
                       (v_p->>'lat')::numeric, (v_p->>'lng')::numeric,
                       ventas.fn_coordenada_lat(cl.coordenadas),
                       ventas.fn_coordenada_lng(cl.coordenadas)) AS d
              FROM ventas.clientes cl
             WHERE cl.deleted_at IS NULL
               AND cl.coordenadas IS NOT NULL
               -- Caja primero, igual que en las zonas: descarta casi todo sin
               -- hacer la cuenta buena. Un grado de latitud son ~111.320 m.
               AND ventas.fn_coordenada_lat(cl.coordenadas)
                     BETWEEN (v_p->>'lat')::numeric - (v_rcliente / 111320.0)
                         AND (v_p->>'lat')::numeric + (v_rcliente / 111320.0)
               AND ventas.fn_coordenada_lng(cl.coordenadas)
                     BETWEEN (v_p->>'lng')::numeric - (v_rcliente / (111320.0 * COS(RADIANS((v_p->>'lat')::numeric))))
                         AND (v_p->>'lng')::numeric + (v_rcliente / (111320.0 * COS(RADIANS((v_p->>'lat')::numeric))))
          ) c
         WHERE c.d IS NOT NULL AND c.d <= v_rcliente
         ORDER BY c.d
         LIMIT 1;

        v_paradas := v_paradas || jsonb_build_object(
            'orden',   v_orden,
            'lat',     (v_p->>'lat')::numeric,
            'lng',     (v_p->>'lng')::numeric,
            'desde',   to_char((v_p->>'desde_ts')::timestamptz, 'HH24:MI'),
            'hasta',   to_char((v_p->>'hasta_ts')::timestamptz, 'HH24:MI'),
            'minutos', ROUND(EXTRACT(EPOCH FROM ((v_p->>'hasta_ts')::timestamptz
                                               - (v_p->>'desde_ts')::timestamptz)) / 60.0, 1),
            'lecturas', (v_p->>'lecturas')::integer,
            'peor_precision_m', (v_p->>'peor_precision_m')::numeric,
            'cliente', COALESCE(v_cliente, 'null'::jsonb));
    END LOOP;

    -- --------------------------------------------------------------
    -- El resumen
    -- --------------------------------------------------------------
    SELECT jsonb_build_object(
        'puntos',  v_total,
        'metros',  v_metros,
        'km',      ROUND(v_metros / 1000.0, 2),
        'inicio',  to_char(v_inicio, 'HH24:MI'),
        'fin',     to_char(v_fin, 'HH24:MI'),
        'minutos', ROUND(EXTRACT(EPOCH FROM (v_fin - v_inicio)) / 60.0, 0),
        'paradas', jsonb_array_length(v_paradas),
        'minutos_parado', COALESCE((
            SELECT ROUND(SUM((p->>'minutos')::numeric), 0)
              FROM jsonb_array_elements(v_paradas) p), 0),
        -- Media sobre el tiempo de jornada, no sobre el tiempo en movimiento:
        -- es la que sirve para comparar días entre sí.
        'velocidad_media_kmh', CASE
            WHEN v_fin <= v_inicio THEN 0
            ELSE ROUND((v_metros / 1000.0) / (EXTRACT(EPOCH FROM (v_fin - v_inicio)) / 3600.0), 1)
        END,
        'lecturas_imprecisas', v_malas
    ) INTO v_resumen;

    RETURN jsonb_build_object(
        'success', true,
        'message', 'Recorrido obtenido',
        'data', jsonb_build_object(
            'usuario', v_usuario,
            'fecha',   v_fecha::text,
            'puntos',  v_puntos,
            'paradas', v_paradas,
            'resumen', v_resumen
        ));
EXCEPTION
    WHEN SQLSTATE 'P0001' OR SQLSTATE 'P0013' THEN
        RAISE;
    WHEN OTHERS THEN
        RETURN jsonb_build_object('success', false,
            'message', 'Error al obtener el recorrido: ' || SQLERRM, 'error_code', SQLSTATE);
END;
$function$;


-- ===========================================================================
-- 5. PROPIETARIO DE LAS FUNCIONES
-- ===========================================================================
ALTER FUNCTION ventas.fn_recorridos_registrar(bigint, jsonb, varchar, numeric, bigint, varchar, varchar, inet, text, uuid) OWNER TO postgres;
ALTER FUNCTION ventas.fn_recorridos_cobradores(date, date)                           OWNER TO postgres;
ALTER FUNCTION ventas.fn_recorridos_dias(bigint, date, date)                         OWNER TO postgres;
ALTER FUNCTION ventas.fn_recorridos_del_dia(bigint, date, numeric, integer, numeric) OWNER TO postgres;

COMMIT;
