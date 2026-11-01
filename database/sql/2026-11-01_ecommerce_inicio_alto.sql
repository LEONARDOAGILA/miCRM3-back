-- ============================================================================
-- EL ALTO DE CADA SECCIÓN
--
-- Cuánto espacio ocupa una sección en la portada. Hasta ahora todas ocupaban
-- lo mismo: 56 px de aire encima, escritos en la hoja de estilos de la
-- tienda. Apretar la portada para que entren más secciones sin desplazar, o
-- darle aire a una de campaña, era un cambio de código.
--
-- ES EL AIRE, NO EL CONTENIDO. Lo que crece o se encoge es el espacio que la
-- sección deja a su alrededor; las fotos, las tarjetas y los logos siguen
-- midiendo lo que miden. Estirar el contenido sería deformarlo: una foto
-- forzada a 400 px de alto sale aplastada o recortada, y eso no se arregla
-- desde una pantalla de administración.
--
-- VIAJA UNA CLAVE, NO UNA MEDIDA, por lo mismo que el rótulo: la tienda la
-- traduce a su clase, y una lista cerrada no deja escribir CSS desde el CRM.
-- Y guardar «120px» rompería el teléfono, donde el aire de siempre son 40.
--
-- Idempotente: la columna con IF NOT EXISTS y las funciones se rehacen.
-- ============================================================================

BEGIN;

-- ----------------------------------------------------------------------------
-- 1. LA COLUMNA
-- ----------------------------------------------------------------------------
ALTER TABLE ecommerce.inicio_secciones
    ADD COLUMN IF NOT EXISTS alto varchar(10);

COMMENT ON COLUMN ecommerce.inicio_secciones.alto IS
    'Cuánto espacio ocupa la sección: compacta, normal, amplia o extra. NULL = normal.';

ALTER TABLE ecommerce.inicio_secciones
    DROP CONSTRAINT IF EXISTS inicio_secciones_alto_check;

ALTER TABLE ecommerce.inicio_secciones
    ADD CONSTRAINT inicio_secciones_alto_check
        CHECK (alto IS NULL OR alto IN ('compacta', 'normal', 'amplia', 'extra'));

-- ----------------------------------------------------------------------------
-- 2. GUARDAR
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
           alto          = ecommerce.fn_validar_opcion(p_datos ->> 'alto',
                               ARRAY['compacta', 'normal', 'amplia', 'extra'], 'El alto de la sección'),
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
-- 3. LO QUE VE LA PANTALLA
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
                       -- Resuelto, como el estilo: que la pantalla y la tienda
                       -- tengan que acordarse de que NULL es «normal» es la
                       -- manera de que un día una de las dos se olvide
                       'alto',       COALESCE(nullif(btrim(COALESCE(s.alto, '')), ''), 'normal'),
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
-- 4. LA PORTADA QUE LEE LA TIENDA
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
               ecommerce.fn_rotulo_estilo(s.rotulo_tamano, s.rotulo_color, s.rotulo_fuente) AS estilo,
               COALESCE(nullif(btrim(COALESCE(s.alto, '')), ''), 'normal') AS alto
          FROM ecommerce.inicio_secciones s
         WHERE s.activo AND ecommerce.fn_vigente(s.desde, s.hasta)
    ),
    armadas AS (
        SELECT v.orden, v.titulo, v.subtitulo, v.estilo, v.alto,
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
               -- El rótulo, su pinta y el alto se añaden aquí y no en cada
               -- rama: son de la sección, no de lo que la llena, y así no se
               -- olvidan en la siguiente que se traslade
               a.seccion || jsonb_build_object('titulo', a.titulo, 'subtitulo', a.subtitulo,
                                               'estilo', a.estilo, 'alto', a.alto)
               ORDER BY a.orden), '[]'::jsonb))
      FROM armadas a
     WHERE a.seccion IS NOT NULL
       AND (a.seccion -> 'imagenes'   IS NULL OR jsonb_array_length(a.seccion -> 'imagenes') > 0)
       AND (a.seccion -> 'categorias' IS NULL OR jsonb_array_length(a.seccion -> 'categorias') > 0)
       AND (a.seccion -> 'marcas'     IS NULL OR jsonb_array_length(a.seccion -> 'marcas') > 0);
$function$;

-- ----------------------------------------------------------------------------
-- 5. QUE EL ALTO LLEGUE Y QUE NO ENTRE UNO INVENTADO
-- ----------------------------------------------------------------------------
-- Lo que escribe la prueba va dentro de un bloque con EXCEPTION, que en
-- plpgsql es una subtransacción: al salir con un error se deshacen sus UPDATE
-- y las variables se quedan con lo que leyeron.
DO $comprobar$
DECLARE
    v_clave   text;
    v_alto    text;
    v_cuantas integer;
    v_con     integer;
    v_fallo   text;
BEGIN
    SELECT jsonb_array_length(ecommerce.fn_inicio_publico() -> 'secciones') INTO v_cuantas;
    IF COALESCE(v_cuantas, 0) = 0 THEN
        RAISE EXCEPTION 'Hoy no sale ninguna sección en la portada: no se puede comprobar el alto';
    END IF;

    -- Ninguna puede llegar sin alto: la tienda no sabría cuánto aire darle
    SELECT count(*) INTO v_con
      FROM jsonb_array_elements(ecommerce.fn_inicio_publico() -> 'secciones') s
     WHERE COALESCE(s ->> 'alto', '') <> '';
    IF v_con <> v_cuantas THEN
        RAISE EXCEPTION 'De % secciones, sólo % traen su alto', v_cuantas, v_con;
    END IF;

    SELECT s ->> 'clave' INTO v_clave
      FROM jsonb_array_elements(ecommerce.fn_inicio_publico() -> 'secciones') s LIMIT 1;

    BEGIN
        PERFORM ecommerce.fn_inicio_seccion_guardar(v_clave,
            jsonb_build_object('activo', true, 'alto', 'AMPLIA'));
        SELECT s ->> 'alto' INTO v_alto
          FROM jsonb_array_elements(ecommerce.fn_inicio_publico() -> 'secciones') s
         WHERE s ->> 'clave' = v_clave;

        v_fallo := NULL;
        BEGIN
            PERFORM ecommerce.fn_inicio_seccion_guardar(v_clave,
                jsonb_build_object('activo', true, 'alto', 'kilometrica'));
        EXCEPTION WHEN SQLSTATE 'P0015' THEN v_fallo := 'bien';
        END;

        RAISE EXCEPTION 'deshacer la prueba' USING ERRCODE = 'P0001';
    EXCEPTION WHEN SQLSTATE 'P0001' THEN
        NULL;
    END;

    IF v_alto IS DISTINCT FROM 'amplia' THEN
        RAISE EXCEPTION 'El alto no llega a la tienda: llegó «%»', COALESCE(v_alto, 'nada');
    END IF;
    IF v_fallo IS NULL THEN
        RAISE EXCEPTION 'Se tragó un alto que no existe';
    END IF;

    RAISE NOTICE 'Comprobado: las % secciones llevan su alto y lo que no está en la lista no entra.', v_cuantas;
END
$comprobar$;

COMMIT;
