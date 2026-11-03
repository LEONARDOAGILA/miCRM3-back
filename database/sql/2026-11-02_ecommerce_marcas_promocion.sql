-- ============================================================================
-- ECOMMERCE · MARCAS EN PROMOCIÓN
-- ============================================================================
-- Fecha: 2026-11-02
--
-- Lo mismo que «Categorías en promoción», con marcas: se marcan a dedo en
-- «Marcas de la tienda» y salen en la portada como los mismos carteles
-- verticales, con su foto, su nombre y su botón.
--
-- SE COPIA LA MECÁNICA DE LAS CATEGORÍAS AL PIE DE LA LETRA, porque es la que
-- ya funciona y la que se pidió:
--
--     marcas_web.promocion         marcada a dedo
--     marcas_web.promocion_orden   en qué puesto sale (nulo = al final)
--     fn_marcas_promocion_publicas lo que recibe la tienda
--     sección `marcas_promocion`   su sitio en la portada
--
-- ES OTRA MARCA Y OTRA SECCIÓN que «Nuestras marcas»: una marca puede estar en
-- las dos, en una o en ninguna. Igual que una categoría puede ser destacada y
-- estar en promoción a la vez.
--
-- LA IMAGEN ES LA PROGRAMADA Y, SI NO HAY, EL LOGO DEL CATÁLOGO. Las dos
-- viajan y PHP se queda con una, que es lo que ya hace con «Nuestras marcas»:
-- viven en carpetas distintas y la dirección la arma él.
--
-- HAY QUE RECREAR TRES FUNCIONES, no basta con reemplazarlas: a
-- `fn_marcas_web_estado` le crecen dos columnas y en PostgreSQL eso cambia el
-- tipo de retorno, que CREATE OR REPLACE no admite. Se borran y se vuelven a
-- crear en orden; las que las llaman por nombre no se enteran.
--
-- Idempotente.
-- ============================================================================
\set ON_ERROR_STOP on

BEGIN;

-- ----------------------------------------------------------------------------
-- 1. LAS COLUMNAS
-- ----------------------------------------------------------------------------
ALTER TABLE ecommerce.marcas_web
    ADD COLUMN IF NOT EXISTS promocion       boolean NOT NULL DEFAULT false,
    ADD COLUMN IF NOT EXISTS promocion_orden integer;

-- ----------------------------------------------------------------------------
-- 2. EL ESTADO DE CADA MARCA, CON LO NUEVO
-- ----------------------------------------------------------------------------
DROP FUNCTION IF EXISTS ecommerce.fn_marcas_web_listar();
DROP FUNCTION IF EXISTS ecommerce.fn_marcas_publicas();
DROP FUNCTION IF EXISTS ecommerce.fn_marcas_web_estado();

CREATE OR REPLACE FUNCTION ecommerce.fn_marcas_web_estado()
 RETURNS TABLE(id bigint, nombre text, nombre_catalogo text, logo text, oculta boolean,
               activo boolean, orden_web integer, promocion boolean, promocion_orden integer,
               estado text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
AS $function$
    SELECT m.id,
           COALESCE(NULLIF(btrim(w.nombre_web), ''), m.nombre)::text,
           m.nombre::text,
           m.logo::text,
           COALESCE(w.oculta, false),
           m.activo,
           w.orden_web,
           COALESCE(w.promocion, false),
           w.promocion_orden,
           CASE
               WHEN COALESCE(w.oculta, false) THEN 'oculta'
               WHEN NOT m.activo              THEN 'inactiva'
               ELSE                                'visible'
           END
      FROM inventarios.marcas m
      LEFT JOIN ecommerce.marcas_web w ON w.marca_id = m.id
     WHERE m.deleted_at IS NULL;
$function$;

CREATE OR REPLACE FUNCTION ecommerce.fn_marcas_web_listar()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
AS $function$
    SELECT jsonb_build_object('success', true, 'message', 'Marcas de la tienda',
        'data', COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
                       'id',              e.id,
                       'nombre',          e.nombre,
                       'nombre_catalogo', e.nombre_catalogo,
                       'nombre_web',      w.nombre_web,
                       'logo',            e.logo,
                       'oculta',          e.oculta,
                       'activo',          e.activo,
                       'orden_web',       e.orden_web,
                       'promocion',       e.promocion,
                       'promocion_orden', e.promocion_orden,
                       'estado',          e.estado)
                   -- En el orden de la TIENDA: es el que se administra aquí
                   ORDER BY e.orden_web NULLS LAST, e.nombre)
              FROM ecommerce.fn_marcas_web_estado() e
              LEFT JOIN ecommerce.marcas_web w ON w.marca_id = e.id), '[]'::jsonb));
$function$;

CREATE OR REPLACE FUNCTION ecommerce.fn_marcas_publicas()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
AS $function$
    WITH visibles AS (
        SELECT e.id, e.nombre, e.logo, e.orden_web
          FROM ecommerce.fn_marcas_web_estado() e
         WHERE e.estado = 'visible'
    ),
    mandona AS (
        SELECT DISTINCT ON (i.marca_id) i.marca_id, i.imagen
          FROM ecommerce.marcas_imagenes i
         WHERE i.deleted_at IS NULL AND i.activo
           AND ecommerce.fn_vigente(i.desde, i.hasta)
         ORDER BY i.marca_id, i.orden, i.id
    )
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'id', v.id,
               'nombre', v.nombre,
               -- La programada, si hay; el controlador le pone img/ecommerce
               'imagen', m.imagen,
               -- El del catálogo, que vive en img/marcas
               'logo', v.logo,
               'enlace', '/shop?marca=' || v.id)
           ORDER BY v.orden_web NULLS LAST, v.nombre), '[]'::jsonb)
      FROM visibles v
      LEFT JOIN mandona m ON m.marca_id = v.id;
$function$;

-- ----------------------------------------------------------------------------
-- 3. LAS QUE ESTÁN EN PROMOCIÓN, PARA LA TIENDA
-- ----------------------------------------------------------------------------
-- Calcada de fn_categorias_promocion_publicas: mismas llaves y mismo orden,
-- porque la tienda las pinta con la misma pieza.
CREATE OR REPLACE FUNCTION ecommerce.fn_marcas_promocion_publicas()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
AS $function$
    WITH enPromocion AS (
        SELECT e.id, e.nombre, e.logo, e.orden_web, e.promocion_orden
          FROM ecommerce.fn_marcas_web_estado() e
         -- Oculta o inactiva no sale, aunque esté marcada: lo que no se ve en
         -- la tienda no puede salir en un cartel de la portada
         WHERE e.estado = 'visible' AND e.promocion
    ),
    mandona AS (
        SELECT DISTINCT ON (i.marca_id) i.marca_id, i.imagen
          FROM ecommerce.marcas_imagenes i
         WHERE i.deleted_at IS NULL AND i.activo
           AND ecommerce.fn_vigente(i.desde, i.hasta)
         ORDER BY i.marca_id, i.orden, i.id
    )
    -- SÓLO LA IMAGEN PROGRAMADA, SIN EL LOGO DE RESPALDO, y es a propósito:
    -- el cartel pone la foto a sangre, de arriba abajo, y un logo —ancho y
    -- con sus márgenes— sale recortado por la mitad. Sin foto el cartel se
    -- pinta igual con su color y su nombre, que es exactamente lo que hacen
    -- las categorías. Para que una marca salga con foto, se le programa una
    -- imagen, igual que a una categoría.
    --
    -- Al no venir la llave `logo`, el controlador no tiene nada con lo que
    -- rellenar y deja la imagen en null: no hace falta que sepa de esto.
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'id', p.id,
               'nombre', p.nombre,
               'imagen', m.imagen)
           ORDER BY p.promocion_orden NULLS LAST, p.orden_web NULLS LAST, p.nombre), '[]'::jsonb)
      FROM enPromocion p
      LEFT JOIN mandona m ON m.marca_id = p.id;
$function$;

-- ----------------------------------------------------------------------------
-- 4. GUARDAR LA MARCA DESDE EL CRM
-- ----------------------------------------------------------------------------
-- Se borra la vieja en vez de dejar las dos: con un argumento más y valor por
-- defecto, las dos firmas valdrían para la misma llamada y PostgreSQL no
-- sabría cuál. Las categorías arrastran tres por no haberlo hecho.
DROP FUNCTION IF EXISTS ecommerce.fn_marcas_web_guardar(bigint, boolean, varchar, bigint, varchar, varchar, inet, text, uuid);

CREATE OR REPLACE FUNCTION ecommerce.fn_marcas_web_guardar(
    p_marca_id       bigint,
    p_oculta         boolean,
    p_nombre_web     varchar,
    p_usuario_id     bigint      DEFAULT NULL,
    p_usuario_login  varchar     DEFAULT NULL,
    p_usuario_nombre varchar     DEFAULT NULL,
    p_ip_address     inet        DEFAULT NULL,
    p_user_agent     text        DEFAULT NULL,
    p_request_id     uuid        DEFAULT NULL,
    p_promocion      boolean     DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'ecommerce', 'auditoria'
AS $function$
DECLARE
    v_nombre text;
BEGIN
    PERFORM ecommerce.fn_contexto_auditoria('ecommerce.marcas_web',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    SELECT m.nombre INTO v_nombre
      FROM inventarios.marcas m WHERE m.id = p_marca_id AND m.deleted_at IS NULL;
    IF v_nombre IS NULL THEN
        RAISE EXCEPTION 'La marca no existe' USING ERRCODE = 'P0013';
    END IF;

    INSERT INTO ecommerce.marcas_web (marca_id, oculta, nombre_web, promocion)
    VALUES (p_marca_id, COALESCE(p_oculta, false),
            nullif(btrim(COALESCE(p_nombre_web, '')), ''),
            COALESCE(p_promocion, false))
    ON CONFLICT (marca_id) DO UPDATE
       SET oculta     = COALESCE(p_oculta, ecommerce.marcas_web.oculta),
           nombre_web = nullif(btrim(COALESCE(p_nombre_web, '')), ''),
           -- NULL es «no me lo mandes»: así una pantalla que no conozca la
           -- promoción no la apaga sin querer al guardar el nombre
           promocion  = COALESCE(p_promocion, ecommerce.marcas_web.promocion);

    RETURN jsonb_build_object('success', true,
        'message', format('«%s» guardada', v_nombre),
        'data', (ecommerce.fn_marcas_web_listar() -> 'data'));
END;
$function$;

-- ----------------------------------------------------------------------------
-- 5. EL ORDEN DE LOS CARTELES
-- ----------------------------------------------------------------------------
-- Llega la lista entera de las marcadas, en el orden en que se ven. Las que no
-- vengan se quedan sin puesto y caen al final, que es lo mismo que hacen las
-- categorías.
CREATE OR REPLACE FUNCTION ecommerce.fn_marcas_promocion_ordenar(
    p_ids            jsonb,
    p_usuario_id     bigint      DEFAULT NULL,
    p_usuario_login  varchar     DEFAULT NULL,
    p_usuario_nombre varchar     DEFAULT NULL,
    p_ip_address     inet        DEFAULT NULL,
    p_user_agent     text        DEFAULT NULL,
    p_request_id     uuid        DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'ecommerce', 'auditoria'
AS $function$
DECLARE
    v_cuantas integer;
BEGIN
    PERFORM ecommerce.fn_contexto_auditoria('ecommerce.marcas_web',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    IF p_ids IS NULL OR jsonb_typeof(p_ids) <> 'array' THEN
        RAISE EXCEPTION 'Hace falta la lista de marcas' USING ERRCODE = 'P0001';
    END IF;

    WITH puestos AS (
        SELECT (valor)::bigint AS marca_id, ordinalidad::int AS puesto
          FROM jsonb_array_elements_text(p_ids) WITH ORDINALITY AS t(valor, ordinalidad)
    )
    UPDATE ecommerce.marcas_web w
       SET promocion_orden = p.puesto
      FROM puestos p
     WHERE p.marca_id = w.marca_id;
    GET DIAGNOSTICS v_cuantas = ROW_COUNT;

    RETURN jsonb_build_object('success', true,
        'message', format('Orden de %s marcas en promoción guardado', v_cuantas),
        'data', (ecommerce.fn_marcas_web_listar() -> 'data'));
END;
$function$;

-- ----------------------------------------------------------------------------
-- 6. SU SITIO EN LA PORTADA
-- ----------------------------------------------------------------------------
-- Nace APAGADA y al final: sin marcas puestas no tendría nada que enseñar, y
-- encenderla sola movería la portada de alguien sin que lo pidiera.
INSERT INTO ecommerce.inicio_secciones (clave, nombre, orden, activo)
SELECT 'marcas_promocion', 'Marcas en promoción',
       (SELECT COALESCE(max(orden), 0) + 1 FROM ecommerce.inicio_secciones), false
 WHERE NOT EXISTS (SELECT 1 FROM ecommerce.inicio_secciones WHERE clave = 'marcas_promocion');

-- De dónde saca sus datos: se llena en la misma pantalla que las otras marcas
DO $fuente$
DECLARE
    def   text;
    ancla text := E'        WHEN p_clave = ''marcas'' THEN\n            jsonb_build_object(''tipo'', ''marcas'', ''pantalla'', ''allMarcasWeb'')';
BEGIN
    SELECT pg_get_functiondef(p.oid) INTO def
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'ecommerce' AND p.proname = 'fn_inicio_fuente';

    IF def IS NULL THEN
        RAISE EXCEPTION 'No está ecommerce.fn_inicio_fuente';
    END IF;

    IF strpos(def, 'marcas_promocion') > 0 THEN
        RAISE NOTICE 'La fuente ya conocía las marcas en promoción: no la toco.';
        RETURN;
    END IF;

    IF strpos(def, ancla) = 0 THEN
        RAISE EXCEPTION 'No encontré dónde añadirla: ¿cambió fn_inicio_fuente?';
    END IF;

    -- Tipo propio y no 'marcas': el listado del CRM cuenta cuántas tiene cada
    -- sección según el tipo, y con el mismo diría las de «Nuestras marcas»
    def := replace(def, ancla,
        E'        WHEN p_clave = ''marcas_promocion'' THEN\n'
        || E'            jsonb_build_object(''tipo'', ''marcas_promocion'', ''pantalla'', ''allMarcasWeb'')\n'
        || ancla);

    EXECUTE def;
    RAISE NOTICE 'La fuente ya conoce las marcas en promoción.';
END
$fuente$;

-- Cuántas tiene y si tiene algo que enseñar, en el listado del CRM
DO $listar$
DECLARE
    def    text;
    ancla1 text := E'                           WHEN ''marcas'' THEN\n                               jsonb_array_length(ecommerce.fn_marcas_publicas())';
    ancla2 text := E'                           -- La tienda sólo pinta las que tienen logo: una\n                           -- marca sin imagen no cuenta como contenido.\n                           WHEN ''marcas'' THEN';
    cuenta text := E'                           WHEN ''marcas_promocion'' THEN\n                               jsonb_array_length(ecommerce.fn_marcas_promocion_publicas())';
    contenido text := E'                           -- Aquí basta con que haya alguna marcada: el cartel se\n                           -- pinta con su color aunque no tenga foto, igual que\n                           -- el de una categoría.\n                           WHEN ''marcas_promocion'' THEN\n                               jsonb_array_length(ecommerce.fn_marcas_promocion_publicas()) > 0';
    viejo text := E'                           -- Igual que arriba: una marca en promoción sin\n                           -- ninguna imagen no cuenta como contenido.\n                           WHEN ''marcas_promocion'' THEN\n                               EXISTS (SELECT 1 FROM jsonb_array_elements(ecommerce.fn_marcas_promocion_publicas()) m\n                                        WHERE COALESCE(m ->> ''imagen'', m ->> ''logo'') IS NOT NULL)';
    v_hecho boolean := false;
BEGIN
    SELECT pg_get_functiondef(p.oid) INTO def
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'ecommerce' AND p.proname = 'fn_inicio_listar';

    IF def IS NULL THEN
        RAISE EXCEPTION 'No está ecommerce.fn_inicio_listar';
    END IF;

    -- SON DOS PARCHES INDEPENDIENTES, cada uno con su propia comprobación:
    -- así, si una versión anterior de este fichero dejó uno de los dos mal,
    -- volver a pasarlo lo arregla en vez de darlo por hecho y marcharse.
    IF strpos(def, cuenta) = 0 THEN
        IF strpos(def, ancla1) = 0 THEN
            RAISE EXCEPTION 'No encontré dónde contar: ¿cambió fn_inicio_listar?';
        END IF;
        def := replace(def, ancla1, ancla1 || E'\n' || cuenta);
        v_hecho := true;
    END IF;

    IF strpos(def, contenido) = 0 THEN
        -- La primera versión miraba si la marca tenía imagen o logo. Ya no:
        -- el cartel se pinta con su color aunque no tenga foto, como el de
        -- una categoría. Si está la vieja, se cambia por la buena.
        IF strpos(def, viejo) > 0 THEN
            def := replace(def, viejo, contenido);
            RAISE NOTICE 'El listado tenía la versión vieja de «con contenido»: la cambio.';
        ELSE
            IF strpos(def, ancla2) = 0 THEN
                RAISE EXCEPTION 'No encontré dónde mirar el contenido: ¿cambió fn_inicio_listar?';
            END IF;
            def := replace(def, ancla2, contenido || E'\n' || ancla2);
        END IF;
        v_hecho := true;
    END IF;

    IF NOT v_hecho THEN
        RAISE NOTICE 'El listado ya contaba las marcas en promoción: no lo toco.';
        RETURN;
    END IF;

    EXECUTE def;
    RAISE NOTICE 'El listado del CRM ya cuenta las marcas en promoción.';
END
$listar$;

-- Y lo que recibe la tienda
DO $publica$
DECLARE
    def   text;
    ancla text := E'                   WHEN v.clave = ''marcas'' THEN\n                        jsonb_build_object(''clave'', v.clave,\n                            ''marcas'', ecommerce.fn_marcas_publicas())';
BEGIN
    SELECT pg_get_functiondef(p.oid) INTO def
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'ecommerce' AND p.proname = 'fn_inicio_publico';

    IF def IS NULL THEN
        RAISE EXCEPTION 'No está ecommerce.fn_inicio_publico';
    END IF;

    IF strpos(def, 'marcas_promocion') > 0 THEN
        RAISE NOTICE 'La portada pública ya servía las marcas en promoción: no la toco.';
        RETURN;
    END IF;

    IF strpos(def, ancla) = 0 THEN
        RAISE EXCEPTION 'No encontré la rama de marcas: ¿cambió fn_inicio_publico?';
    END IF;

    -- La llave se llama `marcas` a propósito: el filtro de abajo ya descarta
    -- las secciones con esa llave vacía, y PHP ya sabe convertir esa lista en
    -- direcciones de imagen. Lo que la distingue es la CLAVE de la sección.
    def := replace(def, ancla,
        E'                   WHEN v.clave = ''marcas_promocion'' THEN\n'
        || E'                        jsonb_build_object(''clave'', v.clave,\n'
        || E'                            ''marcas'', ecommerce.fn_marcas_promocion_publicas())\n'
        || ancla);

    EXECUTE def;
    RAISE NOTICE 'La portada pública ya sirve las marcas en promoción.';
END
$publica$;

-- ----------------------------------------------------------------------------
-- 7. COMPROBACIÓN
-- ----------------------------------------------------------------------------
DO $comprobar$
DECLARE
    v_m        bigint;
    v_antes    jsonb;
    v_despues  jsonb;
    v_fila     jsonb;
    v_seccion  jsonb;
    v_nuestras jsonb;
BEGIN
    SELECT e.id INTO v_m FROM ecommerce.fn_marcas_web_estado() e
     WHERE e.estado = 'visible' ORDER BY e.id LIMIT 1;
    IF v_m IS NULL THEN
        RAISE NOTICE 'No hay marcas visibles con las que comprobar; las columnas están.';
        RETURN;
    END IF;

    BEGIN
        v_antes := ecommerce.fn_marcas_promocion_publicas();

        PERFORM ecommerce.fn_marcas_web_guardar(v_m, false, NULL,
                NULL, NULL, NULL, NULL, NULL, NULL, true);

        v_despues := ecommerce.fn_marcas_promocion_publicas();

        SELECT x INTO v_fila
          FROM jsonb_array_elements(ecommerce.fn_marcas_web_listar() -> 'data') x
         WHERE (x ->> 'id')::bigint = v_m;

        -- Encendida la sección, la tienda tiene que recibirla
        UPDATE ecommerce.inicio_secciones SET activo = true WHERE clave = 'marcas_promocion';
        SELECT x INTO v_seccion
          FROM jsonb_array_elements(ecommerce.fn_inicio_publico() -> 'secciones') x
         WHERE x ->> 'clave' = 'marcas_promocion';

        SELECT x INTO v_nuestras
          FROM jsonb_array_elements(ecommerce.fn_inicio_publico() -> 'secciones') x
         WHERE x ->> 'clave' = 'marcas';

        RAISE EXCEPTION 'deshacer' USING ERRCODE = 'P0099';
    EXCEPTION WHEN SQLSTATE 'P0099' THEN
        NULL;
    END;

    IF jsonb_array_length(v_antes) <> 0 THEN
        RAISE NOTICE 'Ya había marcas en promoción antes de la prueba (%): se comprueba igual.',
              jsonb_array_length(v_antes);
    END IF;
    IF jsonb_array_length(v_despues) <> jsonb_array_length(v_antes) + 1 THEN
        RAISE EXCEPTION 'Marcarla tendría que añadir una: % → %',
              jsonb_array_length(v_antes), jsonb_array_length(v_despues);
    END IF;
    IF (v_fila ->> 'promocion')::boolean IS NOT TRUE THEN
        RAISE EXCEPTION 'El CRM no ve la marca en promoción: %', v_fila;
    END IF;
    IF v_seccion IS NULL THEN
        RAISE EXCEPTION 'La tienda no recibe la sección de marcas en promoción';
    END IF;
    IF jsonb_array_length(v_seccion -> 'marcas') <> jsonb_array_length(v_despues) THEN
        RAISE EXCEPTION 'La sección no trae las mismas: % vs %',
              jsonb_array_length(v_seccion -> 'marcas'), jsonb_array_length(v_despues);
    END IF;
    -- Y «Nuestras marcas» sigue siendo otra cosa
    IF v_nuestras IS NOT NULL
       AND jsonb_array_length(v_nuestras -> 'marcas') = jsonb_array_length(v_seccion -> 'marcas')
       AND jsonb_array_length(v_despues) = jsonb_array_length(ecommerce.fn_marcas_publicas()) THEN
        RAISE NOTICE 'Las dos secciones traen lo mismo, pero es que hoy todas las marcas están en promoción.';
    END IF;
    IF EXISTS (SELECT 1 FROM ecommerce.marcas_web WHERE marca_id = v_m AND promocion) THEN
        RAISE EXCEPTION 'La marca de prueba se quedó marcada';
    END IF;

    RAISE NOTICE 'Comprobado: se marca una marca en promoción, el CRM la ve, la tienda recibe su sección con las mismas, y «Nuestras marcas» sigue aparte. No quedó nada.';
END
$comprobar$;

COMMIT;
