-- ============================================================================
-- ECOMMERCE · ADMINISTRAR LA PORTADA DE LA TIENDA
-- ============================================================================
-- Fecha: 2026-11-01
--
-- La portada no es una página: es una LISTA DE SECCIONES que se encienden, se
-- apagan y se reordenan. Cada una saca sus datos de otro sitio; aquí sólo se
-- guarda cuáles hay, en qué orden van, qué se lee encima y entre qué fechas
-- se ven.
--
-- LAS SECCIONES NO SE CREAN NI SE BORRAN DESDE EL CRM: cada una existe porque
-- la tienda sabe pintarla, y una clave nueva sin código que la pinte sería un
-- hueco invisible.
--
-- CADA SECCIÓN DICE DE DÓNDE COME. Hoy sólo los dos banners tienen fuente
-- —sus galerías—; las demás esperan a que se traslade la suya (el catálogo,
-- las marcas de la tienda, el mosaico). La pantalla lo enseña tal cual en vez
-- de fingir que se pueden configurar, y `fn_inicio_publico` ya se salta la
-- sección que no tenga nada que enseñar.
--
-- Idempotente.
-- ============================================================================
\set ON_ERROR_STOP on

BEGIN;

-- ----------------------------------------------------------------------------
-- 1. DE DÓNDE COME CADA SECCIÓN
-- ----------------------------------------------------------------------------
-- En una función y no repartido por la pantalla: la tienda, la portada
-- pública y el CRM tienen que estar de acuerdo en esto, y de acuerdo se está
-- mejor desde un solo sitio.
CREATE OR REPLACE FUNCTION ecommerce.fn_inicio_fuente(p_clave text)
 RETURNS jsonb
 LANGUAGE sql
 IMMUTABLE
AS $function$
    SELECT CASE p_clave
        WHEN 'banner_principal' THEN
            jsonb_build_object('tipo', 'galeria', 'galeria', 'inicio_banner')
        WHEN 'banner_simple' THEN
            jsonb_build_object('tipo', 'galeria', 'galeria', 'inicio_banner_simple')
        WHEN 'categorias_destacadas' THEN
            jsonb_build_object('tipo', 'pendiente', 'falta', 'la marca de «destacada» en las categorías')
        WHEN 'mosaico' THEN
            jsonb_build_object('tipo', 'pendiente', 'falta', 'el orden del mosaico de categorías')
        WHEN 'ofertas_flash' THEN
            jsonb_build_object('tipo', 'pendiente', 'falta', 'el catálogo de la tienda (precio y existencias)')
        WHEN 'grilla' THEN
            jsonb_build_object('tipo', 'pendiente', 'falta', 'el catálogo de la tienda (precio y existencias)')
        WHEN 'bloques' THEN
            jsonb_build_object('tipo', 'pendiente', 'falta', 'los bloques de productos destacados')
        WHEN 'marcas' THEN
            jsonb_build_object('tipo', 'pendiente', 'falta', 'las marcas de la tienda')
        ELSE jsonb_build_object('tipo', 'pendiente', 'falta', 'su fuente')
    END;
$function$;

-- ----------------------------------------------------------------------------
-- 2. LO QUE VE LA PANTALLA
-- ----------------------------------------------------------------------------
-- Todas las secciones, encendidas y apagadas, con su estado y con cuántas
-- cosas tiene hoy cada una. El estado es lo que distingue «se me olvidó
-- encenderla» de «ya terminó», que se arreglan de maneras distintas.
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
                       -- Cuántas cosas tiene hoy, cuando se puede saber
                       'cuantas',    CASE WHEN ecommerce.fn_inicio_fuente(s.clave) ->> 'tipo' = 'galeria'
                           THEN (SELECT count(*) FROM ecommerce.galerias_imagenes i
                                   JOIN ecommerce.galerias g ON g.id = i.galeria_id
                                  WHERE g.clave = ecommerce.fn_inicio_fuente(s.clave) ->> 'galeria'
                                    AND i.deleted_at IS NULL)
                           END,
                       'con_contenido', CASE WHEN ecommerce.fn_inicio_fuente(s.clave) ->> 'tipo' = 'galeria'
                           THEN EXISTS (SELECT 1 FROM ecommerce.galerias_imagenes i
                                          JOIN ecommerce.galerias g ON g.id = i.galeria_id
                                         WHERE g.clave = ecommerce.fn_inicio_fuente(s.clave) ->> 'galeria'
                                           AND i.deleted_at IS NULL AND i.activo
                                           AND ecommerce.fn_vigente(i.desde, i.hasta))
                           ELSE false END)
                   ORDER BY s.orden, s.id)
              FROM ecommerce.inicio_secciones s), '[]'::jsonb));
$function$;

-- ----------------------------------------------------------------------------
-- 3. GUARDAR UNA SECCIÓN
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
       SET titulo    = ecommerce.fn_validar_texto(p_datos ->> 'titulo', 'El título', 80),
           subtitulo = ecommerce.fn_validar_texto(p_datos ->> 'subtitulo', 'El subtítulo', 80),
           activo    = COALESCE((p_datos ->> 'activo')::boolean, true),
           desde     = v_desde,
           hasta     = v_hasta
     WHERE clave = btrim(p_clave);

    RETURN jsonb_build_object('success', true,
        'message', format('«%s» guardada', v_nombre),
        'data', (ecommerce.fn_inicio_listar() -> 'data'));
END;
$function$;

-- Encender o apagar, sin tocar lo demás. Es lo que más se usa.
CREATE OR REPLACE FUNCTION ecommerce.fn_inicio_seccion_activar(
    p_clave text, p_activo boolean,
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
    v_nuevo  boolean;
BEGIN
    PERFORM ecommerce.fn_contexto_auditoria('ecommerce.inicio_secciones',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    SELECT nombre, COALESCE(p_activo, NOT activo) INTO v_nombre, v_nuevo
      FROM ecommerce.inicio_secciones WHERE clave = btrim(COALESCE(p_clave, ''));
    IF v_nombre IS NULL THEN
        RAISE EXCEPTION 'La sección «%» no existe', p_clave USING ERRCODE = 'P0013';
    END IF;

    UPDATE ecommerce.inicio_secciones SET activo = v_nuevo WHERE clave = btrim(p_clave);

    RETURN jsonb_build_object('success', true,
        'message', format('«%s» %s', v_nombre,
                          CASE WHEN v_nuevo THEN 'se verá en la portada' ELSE 'ya no se ve' END),
        'data', (ecommerce.fn_inicio_listar() -> 'data'));
END;
$function$;

-- ----------------------------------------------------------------------------
-- 4. EL ORDEN
-- ----------------------------------------------------------------------------
-- Llega entero, por clave y como se ve en la pantalla. Tienen que estar TODAS:
-- un orden a medias dejaría las que faltan en un sitio que nadie eligió.
CREATE OR REPLACE FUNCTION ecommerce.fn_inicio_ordenar(
    p_claves jsonb,
    p_usuario_id bigint DEFAULT NULL, p_usuario_login character varying DEFAULT NULL,
    p_usuario_nombre character varying DEFAULT NULL, p_ip_address inet DEFAULT NULL,
    p_user_agent text DEFAULT NULL, p_request_id uuid DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'ecommerce', 'auditoria'
AS $function$
DECLARE
    v_recibidas integer;
    v_conocidas integer;
    v_todas     integer;
BEGIN
    PERFORM ecommerce.fn_contexto_auditoria('ecommerce.inicio_secciones',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    IF p_claves IS NULL OR jsonb_typeof(p_claves) <> 'array' OR jsonb_array_length(p_claves) = 0 THEN
        RAISE EXCEPTION 'Hace falta el orden de las secciones' USING ERRCODE = 'P0001';
    END IF;

    v_recibidas := jsonb_array_length(p_claves);

    SELECT count(*) INTO v_conocidas FROM ecommerce.inicio_secciones
     WHERE clave IN (SELECT x FROM jsonb_array_elements_text(p_claves) x);

    SELECT count(*) INTO v_todas FROM ecommerce.inicio_secciones;

    IF v_conocidas <> v_recibidas OR v_recibidas <> v_todas THEN
        RAISE EXCEPTION 'El orden tiene que traer las % secciones, y trae % válidas de %',
              v_todas, v_conocidas, v_recibidas USING ERRCODE = 'P0016';
    END IF;

    UPDATE ecommerce.inicio_secciones s
       SET orden = n.pos
      FROM (SELECT x.clave, x.pos
              FROM jsonb_array_elements_text(p_claves) WITH ORDINALITY AS x(clave, pos)) n
     WHERE s.clave = n.clave;

    RETURN jsonb_build_object('success', true, 'message', 'Orden de la portada guardado',
                              'data', (ecommerce.fn_inicio_listar() -> 'data'));
END;
$function$;

-- ----------------------------------------------------------------------------
-- 5. QUE HAGA LO QUE DICE
-- ----------------------------------------------------------------------------
DO $comprobar$
DECLARE
    v_datos    jsonb;
    v_antes    jsonb;
    v_claves   jsonb;
    v_primera  text;
    v_estado   text;
    v_cuantas  integer;
    v_fallo    text;
BEGIN
    v_antes := ecommerce.fn_inicio_listar() -> 'data';
    SELECT count(*) INTO v_cuantas FROM jsonb_array_elements(v_antes);
    IF v_cuantas IS NULL OR v_cuantas = 0 THEN
        RAISE EXCEPTION 'La portada no devuelve ninguna sección';
    END IF;

    -- El banner principal sabe de dónde come y cuántas imágenes tiene
    SELECT s ->> 'cuantas' INTO v_estado
      FROM jsonb_array_elements(v_antes) s WHERE s ->> 'clave' = 'banner_principal';
    IF v_estado IS NULL THEN
        RAISE EXCEPTION 'El banner principal no dice cuántas imágenes tiene';
    END IF;

    -- Una sección que no existe no se guarda
    v_fallo := NULL;
    BEGIN
        PERFORM ecommerce.fn_inicio_seccion_guardar('seccion_inventada', '{}'::jsonb);
    EXCEPTION WHEN SQLSTATE 'P0013' THEN v_fallo := 'bien';
    END;
    IF v_fallo IS NULL THEN
        RAISE EXCEPTION 'Se tragó una sección que no existe';
    END IF;

    -- Las fechas al revés tampoco
    v_fallo := NULL;
    BEGIN
        PERFORM ecommerce.fn_inicio_seccion_guardar('grilla',
            jsonb_build_object('desde', '2026-12-01 00:00', 'hasta', '2026-11-01 00:00'));
    EXCEPTION WHEN SQLSTATE 'P0015' THEN v_fallo := 'bien';
    END;
    IF v_fallo IS NULL THEN
        RAISE EXCEPTION 'Se tragó un «hasta» anterior al «desde»';
    END IF;

    -- Un orden a medias no entra
    v_fallo := NULL;
    BEGIN
        PERFORM ecommerce.fn_inicio_ordenar(jsonb_build_array('grilla', 'marcas'));
    EXCEPTION WHEN SQLSTATE 'P0016' THEN v_fallo := 'bien';
    END;
    IF v_fallo IS NULL THEN
        RAISE EXCEPTION 'Se tragó un orden con sólo dos secciones';
    END IF;

    -- Y el entero sí: se da la vuelta y se deja como estaba
    SELECT jsonb_agg(s ->> 'clave' ORDER BY (s ->> 'orden')::int DESC) INTO v_claves
      FROM jsonb_array_elements(v_antes) s;

    v_datos := ecommerce.fn_inicio_ordenar(v_claves) -> 'data';
    SELECT s ->> 'clave' INTO v_primera FROM jsonb_array_elements(v_datos) s
     WHERE (s ->> 'orden')::int = 1;

    IF v_primera IS DISTINCT FROM (v_claves ->> 0) THEN
        RAISE EXCEPTION 'El orden no se guardó: arriba quedó «%» y se pidió «%»',
              COALESCE(v_primera, 'nada'), v_claves ->> 0;
    END IF;

    SELECT jsonb_agg(s ->> 'clave' ORDER BY (s ->> 'orden')::int) INTO v_claves
      FROM jsonb_array_elements(v_antes) s;
    PERFORM ecommerce.fn_inicio_ordenar(v_claves);

    RAISE NOTICE 'Comprobado: % secciones, el banner dice su fuente, y el orden entra entero o no entra.',
          v_cuantas;
END
$comprobar$;

COMMIT;
