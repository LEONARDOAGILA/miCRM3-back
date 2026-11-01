-- ============================================================================
-- CÓMO SE VE EL RÓTULO: TAMAÑO, COLOR Y TIPO DE LETRA
--
-- El rótulo de cada sección ya se escribe desde el CRM. Esto le añade la
-- pinta: de qué tamaño se lee, de qué color y con qué letra, para que una
-- campaña se pueda montar sin pedir un cambio de código.
--
-- VIAJAN CLAVES, NO CSS. El tamaño y la letra son una lista cerrada
-- —«grande», «deportiva»— y la tienda las traduce a sus propias clases. Si
-- esto guardara CSS, cualquiera con permiso de editar la portada estaría
-- escribiendo en la hoja de estilos de la tienda, y un `font-size: 200px` o
-- algo peor saldría publicado. Con una lista cerrada, lo que no está en ella
-- no se guarda.
--
-- EL COLOR ES LO ÚNICO LIBRE, y es un `#rrggbb` comprobado con una expresión
-- regular, en la columna y en la función. Un color no puede traer nada más
-- que seis dígitos.
--
-- EL TAMAÑO NO ES UNA MEDIDA, ES UNA ESCALA. La tienda ya encoge sus títulos
-- en tablet y en celular; guardar «32px» rompería eso y el rótulo saldría
-- gigante en un teléfono. Guardando «grande», cada pantalla lo agranda sobre
-- la medida que le toca.
--
-- Idempotente: las columnas con IF NOT EXISTS y las reglas se rehacen.
-- ============================================================================

BEGIN;

-- ----------------------------------------------------------------------------
-- 1. LAS TRES COLUMNAS, CON SU LISTA CERRADA
-- ----------------------------------------------------------------------------
ALTER TABLE ecommerce.inicio_secciones
    ADD COLUMN IF NOT EXISTS rotulo_tamano varchar(10),
    ADD COLUMN IF NOT EXISTS rotulo_color  varchar(7),
    ADD COLUMN IF NOT EXISTS rotulo_fuente varchar(10);

COMMENT ON COLUMN ecommerce.inicio_secciones.rotulo_tamano IS
    'Escala del rótulo en la tienda: pequeno, normal, grande o enorme. NULL = normal.';
COMMENT ON COLUMN ecommerce.inicio_secciones.rotulo_color IS
    'Color del rótulo en #rrggbb minúsculas. NULL = el de la tienda.';
COMMENT ON COLUMN ecommerce.inicio_secciones.rotulo_fuente IS
    'Letra del rótulo: titulos, texto, deportiva o serif. NULL = la de los títulos.';

-- La regla va en la columna y no sólo en la función que guarda: así tampoco
-- entra por un UPDATE a mano el día que alguien arregle algo desde psql.
ALTER TABLE ecommerce.inicio_secciones
    DROP CONSTRAINT IF EXISTS inicio_secciones_rotulo_tamano_check,
    DROP CONSTRAINT IF EXISTS inicio_secciones_rotulo_color_check,
    DROP CONSTRAINT IF EXISTS inicio_secciones_rotulo_fuente_check;

ALTER TABLE ecommerce.inicio_secciones
    ADD CONSTRAINT inicio_secciones_rotulo_tamano_check
        CHECK (rotulo_tamano IS NULL OR rotulo_tamano IN ('pequeno', 'normal', 'grande', 'enorme')),
    ADD CONSTRAINT inicio_secciones_rotulo_color_check
        CHECK (rotulo_color IS NULL OR rotulo_color ~ '^#[0-9a-f]{6}$'),
    ADD CONSTRAINT inicio_secciones_rotulo_fuente_check
        CHECK (rotulo_fuente IS NULL OR rotulo_fuente IN ('titulos', 'texto', 'deportiva', 'serif'));

-- ----------------------------------------------------------------------------
-- 2. COMPROBAR UNA ELECCIÓN Y UN COLOR
-- ----------------------------------------------------------------------------
-- Devuelven NULL cuando no se eligió nada —que es «lo de fábrica»— y revientan
-- con el nombre del campo cuando llega algo que no está en la lista: el aviso
-- lo lee una persona, así que dice qué campo y qué se admite.
CREATE OR REPLACE FUNCTION ecommerce.fn_validar_opcion(
    p_valor text, p_opciones text[], p_etiqueta text)
 RETURNS text
 LANGUAGE plpgsql
 IMMUTABLE
AS $function$
DECLARE
    v text := lower(btrim(COALESCE(p_valor, '')));
BEGIN
    IF v = '' THEN
        RETURN NULL;
    END IF;

    IF NOT (v = ANY (p_opciones)) THEN
        RAISE EXCEPTION '%: «%» no es una opción (se admite %)',
              p_etiqueta, p_valor, array_to_string(p_opciones, ', ')
              USING ERRCODE = 'P0015';
    END IF;

    RETURN v;
END;
$function$;

CREATE OR REPLACE FUNCTION ecommerce.fn_validar_color(p_valor text, p_etiqueta text)
 RETURNS text
 LANGUAGE plpgsql
 IMMUTABLE
AS $function$
DECLARE
    v text := lower(btrim(COALESCE(p_valor, '')));
BEGIN
    IF v = '' THEN
        RETURN NULL;
    END IF;

    -- Se admite con y sin almohadilla, porque los dos se escriben a mano
    IF v ~ '^[0-9a-f]{6}$' THEN
        v := '#' || v;
    END IF;

    IF v !~ '^#[0-9a-f]{6}$' THEN
        RAISE EXCEPTION '%: «%» no es un color. Va en seis dígitos, como #df1122',
              p_etiqueta, p_valor USING ERRCODE = 'P0015';
    END IF;

    RETURN v;
END;
$function$;

-- ----------------------------------------------------------------------------
-- 3. LA PINTA DEL RÓTULO, EN UN SOLO SITIO
-- ----------------------------------------------------------------------------
-- La usan la pantalla y la tienda, y por eso devuelve SIEMPRE tamaño y letra,
-- con lo de fábrica resuelto. Que cada lado tuviera que acordarse de que NULL
-- es «normal» era la manera de que un día uno de los dos se olvidara.
--
-- El color sí puede ir en NULL: ahí lo de fábrica no es un color concreto sino
-- el que la tienda use en esa sección, y eso no se puede escribir aquí.
CREATE OR REPLACE FUNCTION ecommerce.fn_rotulo_estilo(
    p_tamano text, p_color text, p_fuente text)
 RETURNS jsonb
 LANGUAGE sql
 IMMUTABLE
AS $function$
    SELECT jsonb_build_object(
        'tamano', COALESCE(nullif(btrim(COALESCE(p_tamano, '')), ''), 'normal'),
        'color',  nullif(btrim(COALESCE(p_color, '')), ''),
        'fuente', COALESCE(nullif(btrim(COALESCE(p_fuente, '')), ''), 'titulos'));
$function$;

-- ----------------------------------------------------------------------------
-- 4. GUARDAR UNA SECCIÓN, AHORA TAMBIÉN CON SU PINTA
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ecommerce.fn_inicio_seccion_guardar(
    p_clave text, p_datos jsonb,
    p_usuario_id bigint DEFAULT NULL, p_usuario_login character varying DEFAULT NULL,
    p_usuario_nombre character varying DEFAULT NULL, p_ip_address inet DEFAULT NULL,
    p_user_agent text DEFAULT NULL, p_request_id uuid DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'ecommerce', 'auditoria'
AS $function$
DECLARE
    v_nombre text;
    v_desde  timestamptz;
    v_hasta  timestamptz;
BEGIN
    PERFORM ecommerce.fn_contexto_auditoria('ecommerce.inicio_secciones',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    SELECT nombre INTO v_nombre FROM ecommerce.inicio_secciones WHERE clave = btrim(COALESCE(p_clave, ''));
    IF v_nombre IS NULL THEN
        RAISE EXCEPTION 'La sección «%» no existe', p_clave USING ERRCODE = 'P0013';
    END IF;

    v_desde := nullif(btrim(COALESCE(p_datos ->> 'desde', '')), '')::timestamptz;
    v_hasta := nullif(btrim(COALESCE(p_datos ->> 'hasta', '')), '')::timestamptz;
    IF v_desde IS NOT NULL AND v_hasta IS NOT NULL AND v_hasta < v_desde THEN
        RAISE EXCEPTION 'Las fechas van al revés: «hasta» es anterior a «desde»' USING ERRCODE = 'P0015';
    END IF;

    UPDATE ecommerce.inicio_secciones
       SET titulo        = ecommerce.fn_validar_texto(p_datos ->> 'titulo', 'El título', 80),
           subtitulo     = ecommerce.fn_validar_texto(p_datos ->> 'subtitulo', 'El subtítulo', 80),
           rotulo_tamano = ecommerce.fn_validar_opcion(p_datos ->> 'rotulo_tamano',
                               ARRAY['pequeno', 'normal', 'grande', 'enorme'], 'El tamaño del rótulo'),
           rotulo_color  = ecommerce.fn_validar_color(p_datos ->> 'rotulo_color', 'El color del rótulo'),
           rotulo_fuente = ecommerce.fn_validar_opcion(p_datos ->> 'rotulo_fuente',
                               ARRAY['titulos', 'texto', 'deportiva', 'serif'], 'La letra del rótulo'),
           activo        = COALESCE((p_datos ->> 'activo')::boolean, true),
           desde         = v_desde,
           hasta         = v_hasta
     WHERE clave = btrim(p_clave);

    RETURN jsonb_build_object('success', true,
        'message', format('«%s» guardada', v_nombre),
        'data', (ecommerce.fn_inicio_listar() -> 'data'));
END;
$function$;

-- ----------------------------------------------------------------------------
-- 5. LO QUE VE LA PANTALLA
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ecommerce.fn_inicio_listar()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
AS $function$
    SELECT jsonb_build_object('success', true, 'message', 'Portada de la tienda',
        'data', COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
                       'id',         s.id,
                       'clave',      s.clave,
                       'nombre',     s.nombre,
                       'titulo',     s.titulo,
                       'subtitulo',  s.subtitulo,
                       'estilo',     ecommerce.fn_rotulo_estilo(s.rotulo_tamano, s.rotulo_color, s.rotulo_fuente),
                       'orden',      s.orden,
                       'activo',     s.activo,
                       'desde',      to_char(s.desde, 'YYYY-MM-DD"T"HH24:MI'),
                       'hasta',      to_char(s.hasta, 'YYYY-MM-DD"T"HH24:MI'),
                       'updated_at', to_char(s.updated_at, 'YYYY-MM-DD HH24:MI'),
                       'updated_by', s.updated_by,
                       'estado',     CASE
                           WHEN NOT s.activo THEN 'oculta'
                           WHEN s.desde IS NOT NULL AND CURRENT_TIMESTAMP < s.desde THEN 'programada'
                           WHEN s.hasta IS NOT NULL AND CURRENT_TIMESTAMP > s.hasta THEN 'terminada'
                           ELSE 'visible' END,
                       'fuente',     ecommerce.fn_inicio_fuente(s.clave),
                       'cuantas',    CASE ecommerce.fn_inicio_fuente(s.clave) ->> 'tipo'
                           WHEN 'galeria' THEN
                               (SELECT count(*) FROM ecommerce.galerias_imagenes i
                                  JOIN ecommerce.galerias g ON g.id = i.galeria_id
                                 WHERE g.clave = ecommerce.fn_inicio_fuente(s.clave) ->> 'galeria'
                                   AND i.deleted_at IS NULL)
                           WHEN 'promocion' THEN
                               jsonb_array_length(ecommerce.fn_categorias_promocion_publicas())
                           WHEN 'destacadas' THEN
                               jsonb_array_length(ecommerce.fn_categorias_destacadas_publicas())
                           WHEN 'marcas' THEN
                               jsonb_array_length(ecommerce.fn_marcas_publicas())
                           END,
                       'con_contenido', CASE ecommerce.fn_inicio_fuente(s.clave) ->> 'tipo'
                           WHEN 'galeria' THEN
                               EXISTS (SELECT 1 FROM ecommerce.galerias_imagenes i
                                         JOIN ecommerce.galerias g ON g.id = i.galeria_id
                                        WHERE g.clave = ecommerce.fn_inicio_fuente(s.clave) ->> 'galeria'
                                          AND i.deleted_at IS NULL AND i.activo
                                          AND ecommerce.fn_vigente(i.desde, i.hasta))
                           WHEN 'promocion' THEN
                               jsonb_array_length(ecommerce.fn_categorias_promocion_publicas()) > 0
                           WHEN 'destacadas' THEN
                               jsonb_array_length(ecommerce.fn_categorias_destacadas_publicas()) > 0
                           -- La tienda sólo pinta las que tienen logo: una
                           -- marca sin imagen no cuenta como contenido.
                           WHEN 'marcas' THEN
                               EXISTS (SELECT 1 FROM jsonb_array_elements(ecommerce.fn_marcas_publicas()) m
                                        WHERE COALESCE(m ->> 'imagen', m ->> 'logo') IS NOT NULL)
                           ELSE false END)
                   ORDER BY s.orden, s.id)
              FROM ecommerce.inicio_secciones s), '[]'::jsonb));
$function$;

-- ----------------------------------------------------------------------------
-- 6. LA PORTADA QUE LEE LA TIENDA
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ecommerce.fn_inicio_publico()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
AS $function$
    WITH visibles AS (
        SELECT s.clave, s.hasta, s.orden,
               nullif(btrim(COALESCE(s.titulo, '')), '')    AS titulo,
               nullif(btrim(COALESCE(s.subtitulo, '')), '') AS subtitulo,
               ecommerce.fn_rotulo_estilo(s.rotulo_tamano, s.rotulo_color, s.rotulo_fuente) AS estilo
          FROM ecommerce.inicio_secciones s
         WHERE s.activo AND ecommerce.fn_vigente(s.desde, s.hasta)
    ),
    armadas AS (
        SELECT v.orden, v.titulo, v.subtitulo, v.estilo,
               CASE v.clave
                   WHEN 'banner_principal' THEN
                        jsonb_build_object('clave', v.clave,
                            'imagenes', COALESCE(ecommerce.fn_galerias_publica('inicio_banner') -> 'imagenes', '[]'::jsonb))
                   WHEN 'banner_simple' THEN
                        jsonb_build_object('clave', v.clave,
                            'imagenes', COALESCE(ecommerce.fn_galerias_publica('inicio_banner_simple') -> 'imagenes', '[]'::jsonb))
                   WHEN 'mosaico' THEN
                        jsonb_build_object('clave', v.clave,
                            'categorias', ecommerce.fn_categorias_promocion_publicas())
                   WHEN 'categorias_destacadas' THEN
                        jsonb_build_object('clave', v.clave,
                            'categorias', ecommerce.fn_categorias_destacadas_publicas())
                   WHEN 'marcas' THEN
                        jsonb_build_object('clave', v.clave,
                            'marcas', ecommerce.fn_marcas_publicas())
                   ELSE NULL
               END AS seccion
          FROM visibles v
    )
    SELECT jsonb_build_object('secciones', COALESCE(jsonb_agg(
               -- El rótulo y su pinta se añaden aquí y no en cada rama: son de
               -- la sección, no de lo que la llena, y así no se olvidan en la
               -- siguiente que se traslade
               a.seccion || jsonb_build_object('titulo', a.titulo, 'subtitulo', a.subtitulo, 'estilo', a.estilo)
               ORDER BY a.orden), '[]'::jsonb))
      FROM armadas a
     WHERE a.seccion IS NOT NULL
       AND (a.seccion -> 'imagenes'   IS NULL OR jsonb_array_length(a.seccion -> 'imagenes') > 0)
       AND (a.seccion -> 'categorias' IS NULL OR jsonb_array_length(a.seccion -> 'categorias') > 0)
       AND (a.seccion -> 'marcas'     IS NULL OR jsonb_array_length(a.seccion -> 'marcas') > 0);
$function$;

-- ----------------------------------------------------------------------------
-- 7. QUE LA PINTA LLEGUE, Y QUE LO QUE NO ESTÁ EN LA LISTA NO ENTRE
-- ----------------------------------------------------------------------------
-- Las pruebas que escriben van dentro de un bloque con EXCEPTION, que en
-- plpgsql es una subtransacción: al salir con un error se deshacen sus UPDATE
-- y las variables se quedan con lo que leyeron. Así la sección no se queda con
-- un color de prueba ni con un «último cambio» que nadie hizo.
DO $comprobar$
DECLARE
    v_clave   text;
    v_estilo  jsonb;
    v_leido   jsonb;
    v_cuantas integer;
    v_con     integer;
    v_fallo   text;
BEGIN
    SELECT jsonb_array_length(ecommerce.fn_inicio_publico() -> 'secciones') INTO v_cuantas;
    IF COALESCE(v_cuantas, 0) = 0 THEN
        RAISE EXCEPTION 'Hoy no sale ninguna sección en la portada: no se puede comprobar la pinta del rótulo';
    END IF;

    -- Todas tienen que traer su pinta resuelta: a la tienda no le puede llegar
    -- una sección sin tamaño ni letra, porque entonces no sabe cómo pintarla
    SELECT count(*) INTO v_con
      FROM jsonb_array_elements(ecommerce.fn_inicio_publico() -> 'secciones') s
     WHERE COALESCE(s -> 'estilo' ->> 'tamano', '') <> ''
       AND COALESCE(s -> 'estilo' ->> 'fuente', '') <> '';
    IF v_con <> v_cuantas THEN
        RAISE EXCEPTION 'De % secciones, sólo % traen tamaño y letra', v_cuantas, v_con;
    END IF;

    SELECT s ->> 'clave' INTO v_clave
      FROM jsonb_array_elements(ecommerce.fn_inicio_publico() -> 'secciones') s LIMIT 1;

    BEGIN
        PERFORM ecommerce.fn_inicio_seccion_guardar(v_clave, jsonb_build_object(
            'titulo', 'ZZ pinta de prueba', 'activo', true,
            'rotulo_tamano', 'ENORME', 'rotulo_color', 'DF1122', 'rotulo_fuente', 'deportiva'));

        SELECT s -> 'estilo' INTO v_estilo
          FROM jsonb_array_elements(ecommerce.fn_inicio_publico() -> 'secciones') s
         WHERE s ->> 'clave' = v_clave;

        -- Y lo que no está en la lista no entra
        v_fallo := NULL;
        BEGIN
            PERFORM ecommerce.fn_inicio_seccion_guardar(v_clave, jsonb_build_object(
                'activo', true, 'rotulo_tamano', 'gigantesco'));
        EXCEPTION WHEN SQLSTATE 'P0015' THEN v_fallo := 'bien';
        END;

        RAISE EXCEPTION 'deshacer la prueba' USING ERRCODE = 'P0001';
    EXCEPTION WHEN SQLSTATE 'P0001' THEN
        NULL;
    END;

    -- Mayúsculas y color sin almohadilla: se guardan como los espera la tienda
    IF v_estilo ->> 'tamano' IS DISTINCT FROM 'enorme'
       OR v_estilo ->> 'color' IS DISTINCT FROM '#df1122'
       OR v_estilo ->> 'fuente' IS DISTINCT FROM 'deportiva' THEN
        RAISE EXCEPTION 'La pinta no llega a la tienda: llegó %', COALESCE(v_estilo::text, 'nada');
    END IF;
    IF v_fallo IS NULL THEN
        RAISE EXCEPTION 'Se tragó un tamaño que no existe';
    END IF;

    -- Y la sección se quedó como estaba
    SELECT s -> 'estilo' INTO v_leido
      FROM jsonb_array_elements(ecommerce.fn_inicio_publico() -> 'secciones') s
     WHERE s ->> 'clave' = v_clave;
    IF v_leido ->> 'tamano' = 'enorme' AND v_leido ->> 'color' = '#df1122' THEN
        RAISE EXCEPTION 'La prueba dejó su pinta puesta en «%»', v_clave;
    END IF;

    RAISE NOTICE 'Comprobado: las % secciones llevan su pinta, el color se normaliza y lo que no está en la lista no entra.',
          v_cuantas;
END
$comprobar$;

COMMIT;
