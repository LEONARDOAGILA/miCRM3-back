-- ============================================================================
-- ECOMMERCE · CATEGORÍAS DESTACADAS
-- ============================================================================
-- Fecha: 2026-11-01
--
-- La sección «Categorías destacadas» de la portada —los círculos de arriba—
-- decía «falta la marca de destacada en las categorías». Ésta es esa marca.
--
-- DOS SECCIONES, DOS COSAS DISTINTAS, y conviene tenerlo claro porque las dos
-- enseñan categorías con su imagen:
--
--   · DESTACADAS: las que marcas tú, a dedo. Son los círculos de arriba del
--     todo, el atajo a lo que quieres empujar esta semana.
--   · MOSAICO: todas las que tengan imagen vigente. Es el escaparate del
--     catálogo, y crece solo según vas programando imágenes.
--
-- Por eso destacada es una marca y el mosaico no la necesita: si hubiera que
-- marcar las dos, acabarían siendo la misma lista escrita dos veces.
--
-- LA IMAGEN ES LA MISMA, la programada en `categorias_imagenes`: una
-- categoría tiene una imagen, no una por sitio donde salga. Si no tiene, la
-- tienda pinta su inicial, que es lo que ya hacía.
--
-- Idempotente.
-- ============================================================================
\set ON_ERROR_STOP on

BEGIN;

-- ----------------------------------------------------------------------------
-- 1. LA MARCA
-- ----------------------------------------------------------------------------
ALTER TABLE ecommerce.categorias_web
    ADD COLUMN IF NOT EXISTS destacada boolean NOT NULL DEFAULT false;

-- ----------------------------------------------------------------------------
-- 2. EL ESTADO DE CADA CATEGORÍA, AHORA CON LA MARCA
-- ----------------------------------------------------------------------------
-- Cambia el tipo que devuelve (una columna más), así que hay que tirarla
-- antes: CREATE OR REPLACE no deja cambiar la firma de salida.
DROP FUNCTION IF EXISTS ecommerce.fn_categorias_web_estado();

CREATE FUNCTION ecommerce.fn_categorias_web_estado()
 RETURNS TABLE(id bigint, padre_id bigint, nivel integer, orden integer,
               nombre text, estado text, destacada boolean)
 LANGUAGE sql
 STABLE SECURITY DEFINER
AS $function$
    WITH RECURSIVE
    vivas AS (
        SELECT c.id, c.padre_id, c.nivel, c.orden, c.nombre, c.es_transaccion, c.activo,
               COALESCE(w.oculta, false) AS oculta,
               COALESCE(w.destacada, false) AS destacada,
               COALESCE(NULLIF(btrim(w.nombre_web), ''), c.nombre) AS nombre_web
          FROM inventarios.categorias c
          LEFT JOIN ecommerce.categorias_web w ON w.categoria_id = c.id
         WHERE c.deleted_at IS NULL
    ),
    -- Apagadas: las que lo están, y todo lo que cuelgue de ellas
    apagadas AS (
        SELECT v.id FROM vivas v WHERE v.oculta OR NOT v.activo
        UNION
        SELECT h.id FROM vivas h JOIN apagadas a ON h.padre_id = a.id
    ),
    -- Las que de verdad llevan productos y no están apagadas
    con_productos AS (
        SELECT v.id, v.padre_id FROM vivas v
         WHERE v.es_transaccion AND v.id NOT IN (SELECT id FROM apagadas)
    ),
    -- Ésas y sus padres: una rama sin ninguna de producto debajo no sale
    visibles AS (
        SELECT p.id, p.padre_id FROM con_productos p
        UNION
        SELECT v.id, v.padre_id
          FROM vivas v
          JOIN visibles s ON s.padre_id = v.id
         WHERE v.id NOT IN (SELECT id FROM apagadas)
    )
    SELECT v.id, v.padre_id, v.nivel, v.orden, v.nombre_web,
           CASE
               WHEN vi.id IS NOT NULL                       THEN 'visible'
               WHEN v.oculta                                THEN 'oculta'
               WHEN NOT v.activo                            THEN 'inactiva'
               WHEN v.id IN (SELECT id FROM apagadas)       THEN 'oculta_por_padre'
               ELSE                                              'sin_categorias_de_producto'
           END,
           v.destacada
      FROM vivas v
      LEFT JOIN (SELECT DISTINCT visibles.id FROM visibles) vi ON vi.id = v.id;
$function$;

-- ----------------------------------------------------------------------------
-- 3. LA LISTA DE LA PANTALLA LA TRAE
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ecommerce.fn_categorias_web_listar()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
AS $function$
    SELECT jsonb_build_object('success', true, 'message', 'Categorías de la tienda',
        'data', COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
                       'id',             e.id,
                       'padre_id',       e.padre_id,
                       'nivel',          e.nivel,
                       'orden',          e.orden,
                       -- El de la tienda (el propio si no se cambió)
                       'nombre',         e.nombre,
                       -- El del catálogo, para poder compararlos
                       'nombre_catalogo', c.nombre,
                       'nombre_web',     w.nombre_web,
                       'oculta',         COALESCE(w.oculta, false),
                       'destacada',      e.destacada,
                       'es_transaccion', c.es_transaccion,
                       'activo',         c.activo,
                       'estado',         e.estado)
                   ORDER BY e.nivel, e.orden, e.nombre)
              FROM ecommerce.fn_categorias_web_estado() e
              JOIN inventarios.categorias c ON c.id = e.id
              LEFT JOIN ecommerce.categorias_web w ON w.categoria_id = e.id), '[]'::jsonb));
$function$;

-- ----------------------------------------------------------------------------
-- 4. GUARDARLA
-- ----------------------------------------------------------------------------
-- Un parámetro más al final y con valor por omisión, para que las llamadas
-- de tres argumentos que ya existen sigan funcionando.
CREATE OR REPLACE FUNCTION ecommerce.fn_categorias_web_guardar(
    p_categoria_id bigint, p_oculta boolean, p_nombre_web character varying,
    p_usuario_id bigint DEFAULT NULL, p_usuario_login character varying DEFAULT NULL,
    p_usuario_nombre character varying DEFAULT NULL, p_ip_address inet DEFAULT NULL,
    p_user_agent text DEFAULT NULL, p_request_id uuid DEFAULT NULL,
    p_destacada boolean DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'ecommerce', 'auditoria'
AS $function$
DECLARE
    v_nombre    text;
    v_oculta    boolean := COALESCE(p_oculta, false);
    v_destacada boolean;
    v_catalogo  text;
BEGIN
    PERFORM ecommerce.fn_contexto_auditoria('ecommerce.categorias_web',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    SELECT nombre INTO v_catalogo FROM inventarios.categorias
     WHERE id = p_categoria_id AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'La categoría no existe' USING ERRCODE = 'P0013';
    END IF;

    -- Sin decir nada, se queda como estaba: así quien sólo cambia el nombre
    -- no desmarca la categoría sin querer.
    v_destacada := COALESCE(p_destacada,
                            (SELECT destacada FROM ecommerce.categorias_web
                              WHERE categoria_id = p_categoria_id),
                            false);

    v_nombre := ecommerce.fn_validar_texto(p_nombre_web, 'El nombre para la tienda', 80);

    -- El mismo nombre del catálogo no es «otro nombre»: se guarda como nada,
    -- para que al renombrar la categoría en Inventarios la tienda la siga.
    IF v_nombre IS NOT NULL AND lower(btrim(v_nombre)) = lower(btrim(v_catalogo)) THEN
        v_nombre := NULL;
    END IF;

    IF v_oculta OR v_nombre IS NOT NULL OR v_destacada THEN
        INSERT INTO ecommerce.categorias_web (categoria_id, oculta, nombre_web, destacada)
        VALUES (p_categoria_id, v_oculta, v_nombre, v_destacada)
        ON CONFLICT (categoria_id) DO UPDATE
            SET oculta = EXCLUDED.oculta,
                nombre_web = EXCLUDED.nombre_web,
                destacada = EXCLUDED.destacada;
    ELSE
        -- Visible, con su nombre de siempre y sin destacar: no hay nada que
        -- guardar, y una fila con todo por omisión sólo estorba.
        DELETE FROM ecommerce.categorias_web WHERE categoria_id = p_categoria_id;
    END IF;

    RETURN jsonb_build_object('success', true,
        'message', format('«%s» %s', COALESCE(v_nombre, v_catalogo),
                          CASE WHEN v_oculta THEN 'no saldrá en la tienda' ELSE 'saldrá en la tienda' END),
        'data', (ecommerce.fn_categorias_web_listar() -> 'data'));
END;
$function$;

-- ----------------------------------------------------------------------------
-- 5. LO QUE VE LA TIENDA
-- ----------------------------------------------------------------------------
-- Las marcadas y visibles, con su imagen vigente si la tienen. SIN IMAGEN
-- TAMBIÉN SALEN: la tienda pinta su inicial, y obligar a subir una foto para
-- poder destacar una categoría sería una traba que no ayuda a nadie.
CREATE OR REPLACE FUNCTION ecommerce.fn_categorias_destacadas_publicas()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
AS $function$
    WITH destacadas AS (
        SELECT e.id, e.nombre, e.orden FROM ecommerce.fn_categorias_web_estado() e
         WHERE e.estado = 'visible' AND e.destacada
    ),
    mandona AS (
        SELECT DISTINCT ON (i.categoria_id) i.categoria_id, i.imagen
          FROM ecommerce.categorias_imagenes i
         WHERE i.deleted_at IS NULL AND i.activo
           AND ecommerce.fn_vigente(i.desde, i.hasta)
         ORDER BY i.categoria_id, i.orden, i.id
    )
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'id', d.id, 'nombre', d.nombre, 'imagen', m.imagen)
           ORDER BY d.orden, d.nombre), '[]'::jsonb)
      FROM destacadas d
      LEFT JOIN mandona m ON m.categoria_id = d.id;
$function$;

-- ----------------------------------------------------------------------------
-- 6. LA SECCIÓN YA NO ESTÁ PENDIENTE
-- ----------------------------------------------------------------------------
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
        -- Las dos se llenan en «Categorías de la tienda», pero no con lo
        -- mismo: el mosaico lo llena cualquiera con imagen vigente, y las
        -- destacadas sólo las que marcas a dedo.
        WHEN 'mosaico' THEN
            jsonb_build_object('tipo', 'categorias', 'pantalla', 'allCategoriasWeb')
        WHEN 'categorias_destacadas' THEN
            jsonb_build_object('tipo', 'destacadas', 'pantalla', 'allCategoriasWeb')
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
                       'cuantas',    CASE ecommerce.fn_inicio_fuente(s.clave) ->> 'tipo'
                           WHEN 'galeria' THEN
                               (SELECT count(*) FROM ecommerce.galerias_imagenes i
                                  JOIN ecommerce.galerias g ON g.id = i.galeria_id
                                 WHERE g.clave = ecommerce.fn_inicio_fuente(s.clave) ->> 'galeria'
                                   AND i.deleted_at IS NULL)
                           WHEN 'categorias' THEN
                               jsonb_array_length(ecommerce.fn_categorias_imagenes_publicas())
                           WHEN 'destacadas' THEN
                               jsonb_array_length(ecommerce.fn_categorias_destacadas_publicas())
                           END,
                       'con_contenido', CASE ecommerce.fn_inicio_fuente(s.clave) ->> 'tipo'
                           WHEN 'galeria' THEN
                               EXISTS (SELECT 1 FROM ecommerce.galerias_imagenes i
                                         JOIN ecommerce.galerias g ON g.id = i.galeria_id
                                        WHERE g.clave = ecommerce.fn_inicio_fuente(s.clave) ->> 'galeria'
                                          AND i.deleted_at IS NULL AND i.activo
                                          AND ecommerce.fn_vigente(i.desde, i.hasta))
                           WHEN 'categorias' THEN
                               jsonb_array_length(ecommerce.fn_categorias_imagenes_publicas()) > 0
                           WHEN 'destacadas' THEN
                               jsonb_array_length(ecommerce.fn_categorias_destacadas_publicas()) > 0
                           ELSE false END)
                   ORDER BY s.orden, s.id)
              FROM ecommerce.inicio_secciones s), '[]'::jsonb));
$function$;

CREATE OR REPLACE FUNCTION ecommerce.fn_inicio_publico()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
AS $function$
    WITH visibles AS (
        SELECT s.clave, s.titulo, s.subtitulo, s.hasta, s.orden
          FROM ecommerce.inicio_secciones s
         WHERE s.activo AND ecommerce.fn_vigente(s.desde, s.hasta)
    ),
    armadas AS (
        SELECT v.orden, v.clave,
               CASE v.clave
                   -- Los dos banners salen de su galería. `imagenes` trae el
                   -- NOMBRE del fichero; el controlador le pone la dirección.
                   WHEN 'banner_principal' THEN
                        jsonb_build_object('clave', v.clave,
                            'imagenes', COALESCE(ecommerce.fn_galerias_publica('inicio_banner') -> 'imagenes', '[]'::jsonb))
                   WHEN 'banner_simple' THEN
                        jsonb_build_object('clave', v.clave,
                            'imagenes', COALESCE(ecommerce.fn_galerias_publica('inicio_banner_simple') -> 'imagenes', '[]'::jsonb))
                   -- Una tarjeta por categoría con imagen vigente hoy
                   WHEN 'mosaico' THEN
                        jsonb_build_object('clave', v.clave,
                            'categorias', ecommerce.fn_categorias_imagenes_publicas())
                   -- Los círculos de arriba: sólo las marcadas a dedo
                   WHEN 'categorias_destacadas' THEN
                        jsonb_build_object('clave', v.clave,
                            'categorias', ecommerce.fn_categorias_destacadas_publicas())
                   -- Las demás todavía no tienen de dónde sacar datos. Se
                   -- devuelven como NULL y se caen en el filtro de abajo; la
                   -- tienda ni se entera.
                   ELSE NULL
               END AS seccion
          FROM visibles v
    )
    SELECT jsonb_build_object('secciones', COALESCE(jsonb_agg(a.seccion ORDER BY a.orden), '[]'::jsonb))
      FROM armadas a
     WHERE a.seccion IS NOT NULL
       -- Y si la sección se quedó sin contenido, tampoco sale: un título con
       -- nada debajo es peor que no estar.
       AND (a.seccion -> 'imagenes'   IS NULL OR jsonb_array_length(a.seccion -> 'imagenes') > 0)
       AND (a.seccion -> 'categorias' IS NULL OR jsonb_array_length(a.seccion -> 'categorias') > 0);
$function$;

-- ----------------------------------------------------------------------------
-- 7. QUE HAGA LO QUE DICE
-- ----------------------------------------------------------------------------
-- Todo se cuenta sin condiciones, para que un NULL no deje pasar la prueba en
-- verde. Lo que marca, lo desmarca.
DO $comprobar$
DECLARE
    v_cat     bigint;
    v_antes   boolean;
    v_cuantas integer;
    v_salia   integer;
    v_fuente  text;
BEGIN
    SELECT ecommerce.fn_inicio_fuente('categorias_destacadas') ->> 'tipo' INTO v_fuente;
    IF v_fuente IS DISTINCT FROM 'destacadas' THEN
        RAISE EXCEPTION 'Las destacadas siguen sin fuente (dicen «%»)', COALESCE(v_fuente, 'nada');
    END IF;

    SELECT count(*) INTO v_salia
      FROM jsonb_array_elements(ecommerce.fn_inicio_publico() -> 'secciones') s
     WHERE s ->> 'clave' = 'categorias_destacadas';

    -- Una categoría que de verdad esté en la tienda
    SELECT e.id INTO v_cat FROM ecommerce.fn_categorias_web_estado() e
     WHERE e.estado = 'visible' ORDER BY e.orden, e.id LIMIT 1;
    IF v_cat IS NULL THEN
        RAISE EXCEPTION 'No hay ninguna categoría visible con la que comprobar';
    END IF;

    SELECT COALESCE(destacada, false) INTO v_antes
      FROM ecommerce.categorias_web WHERE categoria_id = v_cat;
    v_antes := COALESCE(v_antes, false);

    -- Marcarla la mete en la sección
    PERFORM ecommerce.fn_categorias_web_guardar(v_cat, false, NULL,
                NULL, NULL, NULL, NULL, NULL, NULL, true);

    SELECT jsonb_array_length(s -> 'categorias') INTO v_cuantas
      FROM jsonb_array_elements(ecommerce.fn_inicio_publico() -> 'secciones') s
     WHERE s ->> 'clave' = 'categorias_destacadas';

    -- Y quitar la marca la saca. Se deshace antes de juzgar, para no dejar
    -- marcada una categoría si la comprobación falla.
    PERFORM ecommerce.fn_categorias_web_guardar(v_cat, false, NULL,
                NULL, NULL, NULL, NULL, NULL, NULL, v_antes);

    IF v_cuantas IS NULL OR v_cuantas < 1 THEN
        RAISE EXCEPTION 'Con una categoría destacada, la sección debería traerla (trajo %)',
              COALESCE(v_cuantas::text, 'nada');
    END IF;

    IF COALESCE((SELECT destacada FROM ecommerce.categorias_web WHERE categoria_id = v_cat), false)
       IS DISTINCT FROM v_antes THEN
        RAISE EXCEPTION 'La comprobación dejó la marca cambiada';
    END IF;

    RAISE NOTICE 'Comprobado: marcar una categoría la mete en destacadas (% salieron) y quitarla la saca.',
          v_cuantas;
END
$comprobar$;

COMMIT;
