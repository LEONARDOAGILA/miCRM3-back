-- ============================================================================
-- «SECCIÓN DE PRODUCTOS» PASA A LLAMARSE «GRUPO DE PRODUCTOS»
-- ============================================================================
-- SÓLO ES UN CAMBIO DE NOMBRE: no cambia ni una regla ni un dato de negocio.
--
-- La palabra «sección» quedaba pedida dos veces: las SECCIONES DE UN CUERPO
-- —lo que se ve en una página de la tienda, una debajo de otra— y estas otras,
-- que no son nada de la página sino una LISTA DE PRODUCTOS con nombre que
-- luego un cuerpo puede enseñar. Desde hoy la palabra «sección» es sólo de las
-- primeras, y estas listas son GRUPOS DE PRODUCTOS.
--
-- Lo que cambia de nombre:
--
--   ecommerce.producto_secciones          →  ecommerce.grupos_productos
--   ecommerce.producto_secciones_items    →  ecommerce.grupos_productos_items
--   …_items.seccion_id                    →  …_items.grupo_id
--   inicio_secciones.producto_seccion_id  →  inicio_secciones.grupo_productos_id
--   fn_producto_secciones_*               →  fn_grupos_productos_*   (la lista)
--   fn_producto_seccion_*                 →  fn_grupo_productos_*    (uno suyo)
--
-- CON UNA EXCEPCIÓN: fn_producto_seccion_productos —los productos que el grupo
-- tiene dentro— se llama ahora fn_grupo_productos_CONTENIDO, porque
-- fn_grupo_productos_productos no se puede leer.
--
-- Y dos cosas que SE QUEDAN como están, porque son de las otras secciones:
-- ecommerce.inicio_secciones (las de un cuerpo), fn_inicio_seccion_* y
-- fn_secciones_publicas. Las funciones de esa familia que nombran a un grupo
-- se vuelven a crear aquí sólo para que apunten al nombre nuevo.
--
-- LOS DATOS TAMBIÉN: la clave que lleva una sección de cuerpo que enseña un
-- grupo pasa de «seccion_7» a «grupo_7», y la ruta del menú del CRM, de
-- «ecommerce/producto-por-seccion» a «ecommerce/grupo-productos».
--
-- ----------------------------------------------------------------------------
-- SE EJECUTA A MANO. Para ensayar sin guardar: comentar el COMMIT y poner un
-- ROLLBACK al FINAL DEL TODO, detrás de la comprobación.
-- ============================================================================

BEGIN;

-- Las funciones se borran y se vuelven a crear en un orden cualquiera, y unas
-- llaman a otras: sin esto, crear la primera que llama a una que todavía no
-- existe para la transacción se cae. Lo que hacen por dentro se comprueba al
-- final, llamándolas.
SET LOCAL check_function_bodies = off;

-- ----------------------------------------------------------------------------
-- 1. LAS TABLAS, con todo lo que cuelga de ellas
-- ----------------------------------------------------------------------------
-- Un ALTER TABLE ... RENAME no toca los nombres de sus índices, sus
-- restricciones, sus secuencias ni sus disparadores: se quedarían hablando de
-- secciones dentro de una tabla de grupos, que es justo lo que se viene a
-- arreglar. Se renombran uno a uno.
ALTER TABLE ecommerce.producto_secciones       RENAME TO grupos_productos;
ALTER TABLE ecommerce.producto_secciones_items RENAME TO grupos_productos_items;

ALTER TABLE ecommerce.grupos_productos_items RENAME COLUMN seccion_id TO grupo_id;
ALTER TABLE ecommerce.inicio_secciones RENAME COLUMN producto_seccion_id TO grupo_productos_id;

ALTER SEQUENCE ecommerce.producto_secciones_id_seq       RENAME TO grupos_productos_id_seq;
ALTER SEQUENCE ecommerce.producto_secciones_items_id_seq RENAME TO grupos_productos_items_id_seq;

ALTER INDEX ecommerce.pk_producto_secciones                RENAME TO pk_grupos_productos;
ALTER INDEX ecommerce.pk_producto_secciones_items          RENAME TO pk_grupos_productos_items;
ALTER INDEX ecommerce.uq_producto_secciones_items          RENAME TO uq_grupos_productos_items;
ALTER INDEX ecommerce.ix_producto_secciones_items_producto RENAME TO ix_grupos_productos_items_producto;

ALTER TABLE ecommerce.grupos_productos
    RENAME CONSTRAINT ck_producto_secciones_vigencia TO ck_grupos_productos_vigencia;
ALTER TABLE ecommerce.grupos_productos_items
    RENAME CONSTRAINT fk_producto_secciones_items_producto TO fk_grupos_productos_items_producto;
ALTER TABLE ecommerce.grupos_productos_items
    RENAME CONSTRAINT fk_producto_secciones_items_seccion TO fk_grupos_productos_items_grupo;

ALTER TRIGGER trg_producto_secciones_audit       ON ecommerce.grupos_productos       RENAME TO trg_grupos_productos_audit;
ALTER TRIGGER trg_producto_secciones_updated_at  ON ecommerce.grupos_productos       RENAME TO trg_grupos_productos_updated_at;
ALTER TRIGGER trg_producto_secciones_users       ON ecommerce.grupos_productos       RENAME TO trg_grupos_productos_users;
ALTER TRIGGER trg_producto_secciones_items_audit ON ecommerce.grupos_productos_items RENAME TO trg_grupos_productos_items_audit;
ALTER TRIGGER trg_producto_secciones_items_users ON ecommerce.grupos_productos_items RENAME TO trg_grupos_productos_items_users;

-- Las de NOT NULL las puso la base con su propio nombre; se renombran igual
-- para que no quede ninguna hablando de secciones
DO $renombrar$
DECLARE
    v_con record;
BEGIN
    FOR v_con IN
        SELECT c.conname, t.relname
          FROM pg_constraint c JOIN pg_class t ON t.oid = c.conrelid
          JOIN pg_namespace n ON n.oid = t.relnamespace
         WHERE n.nspname = 'ecommerce'
           AND t.relname IN ('grupos_productos', 'grupos_productos_items')
           AND c.conname LIKE 'producto_secciones%'
    LOOP
        EXECUTE format('ALTER TABLE ecommerce.%I RENAME CONSTRAINT %I TO %I',
            v_con.relname, v_con.conname,
            replace(replace(v_con.conname, 'producto_secciones_items', 'grupos_productos_items'),
                    'producto_secciones', 'grupos_productos'));
    END LOOP;
END;
$renombrar$;


-- ----------------------------------------------------------------------------
-- 2. LAS FUNCIONES
-- ----------------------------------------------------------------------------
-- Salen de la base tal como estaban, con su nombre nuevo y apuntando a las
-- tablas nuevas. Las que no son del grupo pero lo nombran se vuelven a crear
-- igual, sin cambiar de nombre.
-- fn_cuerpo_publico (se queda con su nombre: no es del grupo, lo usa)
DROP FUNCTION IF EXISTS ecommerce.fn_cuerpo_publico(p_ruta text);
CREATE OR REPLACE FUNCTION ecommerce.fn_cuerpo_publico(p_ruta text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
AS $function$
    WITH elegido AS (
        SELECT c.*
          FROM ecommerce.cuerpos c
         WHERE c.deleted_at IS NULL AND c.activo
           AND CASE WHEN nullif(btrim(COALESCE(p_ruta, '')), '') IS NULL
                    THEN c.principal
                    ELSE c.ruta = lower(btrim(p_ruta)) END
    ),
    visibles AS (
        SELECT s.clave, s.hasta, s.orden, s.grupo_productos_id, g.clave AS galeria_clave,
               -- En crudo y no sólo dentro de `imagen`: 'paginada' es la única
               -- manera de enseñar que pagina, y de eso depende si sus
               -- productos viajan enteros o de a una página
               s.disposicion,
               COALESCE(nullif(btrim(COALESCE(s.banner_vista, '')), ''), 'rotativo') AS banner_vista,
               s.segundos, s.por_pagina,
               COALESCE(nullif(btrim(COALESCE(s.forma, '')), ''), 'circulo') AS forma,
               COALESCE(nullif(btrim(COALESCE(s.alcance, '')), ''), 'tienda') AS alcance,
               nullif(btrim(COALESCE(s.titulo, '')), '')    AS titulo,
               nullif(btrim(COALESCE(s.subtitulo, '')), '') AS subtitulo,
               ecommerce.fn_rotulo_estilo(s.rotulo_tamano, s.rotulo_color, s.rotulo_fuente) AS estilo,
               ecommerce.fn_botones_colores(s.boton_favorito_color, s.boton_favorito_texto,
                                            s.boton_carrito_color,  s.boton_carrito_texto,
                                            s.boton_whatsapp_color, s.boton_whatsapp_texto,
                                            s.boton_tarjeta_color,  s.boton_tarjeta_texto) AS botones,
               ecommerce.fn_tarjeta_colores(s.tarjeta_fondo_color, s.tarjeta_borde_color,
                                            s.descuento_color,     s.descuento_texto,
                                            s.etiqueta, s.etiqueta_color, s.etiqueta_texto,
                                            s.tarjeta_sombra) AS tarjeta,
               ecommerce.fn_seccion_imagen(s.disposicion, s.imagen, s.imagen_alt,
                                           s.imagen_enlace, s.imagen_nueva_pestana) AS imagen,
               COALESCE(nullif(btrim(COALESCE(s.alto, '')), ''), 'normal') AS alto,
               COALESCE(nullif(btrim(COALESCE(s.alto_imagen, '')), ''), 'imagen') AS alto_imagen,
               e.categoria_id, e.marca_id
          FROM elegido e
          JOIN ecommerce.inicio_secciones s ON s.cuerpo_id = e.id
          LEFT JOIN ecommerce.galerias g ON g.id = s.galeria_id
         WHERE s.activo AND ecommerce.fn_vigente(s.desde, s.hasta)
           AND ecommerce.fn_inicio_seccion_viva(s.grupo_productos_id)
    ),
    armadas AS (
        SELECT v.orden, v.titulo, v.subtitulo, v.estilo, v.alto,
               CASE
                   -- Las de productos van primero y se reconocen por a quién
                   -- apuntan: su clave (`grupo_7`) la fabrica el servidor y
                   -- no hay lista donde buscarla.
                   WHEN v.grupo_productos_id IS NOT NULL THEN
                        jsonb_build_object('clave', 'productos',
                            'id', v.grupo_productos_id,
                            -- Cada cuántos segundos pasa sola de tarjeta; null = quieta
                            'segundos', v.segundos,
                            -- Cuántas tarjetas antes del botón «Ver más productos»
                            'por_pagina', v.por_pagina,
                            'botones', v.botones,
                            'tarjeta', v.tarjeta,
                            'imagen', v.imagen) || pag.datos
                   WHEN v.clave = 'banner_principal' THEN
                        jsonb_build_object('clave', v.clave,
                            -- Qué alto tiene su franja de imágenes. Va aquí y
                            -- no con el rótulo porque sólo lo tienen los dos
                            -- banners: en una grupo de productos no hay
                            -- ninguna franja que medir
                            'alto_imagen', v.alto_imagen,
                            'segundos', v.segundos,
                            -- Cuántas tarjetas antes del botón «Ver más productos»
                            'por_pagina', v.por_pagina,
                            -- Su galería; «inicio_banner» sólo si todavía no la
                            -- tiene enganchada
                            'imagenes', COALESCE(ecommerce.fn_galerias_publica(
                                COALESCE(v.galeria_clave, 'inicio_banner')) -> 'imagenes', '[]'::jsonb))
                   -- Cualquier otra sección con galería es un banner, y sale con
                   -- la clave que la tienda sabe pintar. Pueden ser varios.
                   WHEN v.galeria_clave IS NOT NULL THEN
                        jsonb_build_object('clave', 'banner_simple',
                            -- Rotando o en carteles. La tienda pinta una cosa u
                            -- otra con las MISMAS imágenes y sus mismos enlaces.
                            'vista', v.banner_vista,
                            -- Y de qué alto, en las tres maneras
                            'alto_imagen', v.alto_imagen,
                            -- Cada cuántos segundos cambia; null = el de la tienda
                            'segundos', v.segundos,
                            -- Cuántas tarjetas antes del botón «Ver más productos»
                            'por_pagina', v.por_pagina,
                            'imagenes', COALESCE(ecommerce.fn_galerias_publica(v.galeria_clave) -> 'imagenes', '[]'::jsonb))
                   WHEN v.clave = 'mosaico' THEN
                        jsonb_build_object('clave', v.clave,
                            'categorias', CASE
                                WHEN v.alcance = 'cuerpo' AND v.categoria_id IS NOT NULL
                                     THEN ecommerce.fn_categorias_promocion_hijas_publicas(v.categoria_id)
                                ELSE ecommerce.fn_categorias_promocion_publicas() END)
                   WHEN v.clave = 'categorias_destacadas' THEN
                        jsonb_build_object('clave', v.clave,
                            -- En círculo (lo de siempre) o en cuadros con el nombre encima
                            'forma', v.forma,
                            'categorias', CASE
                                -- Lo que cuelga de su categoría, o lo que tiene
                                -- productos de su marca
                                WHEN v.alcance = 'cuerpo' AND v.categoria_id IS NOT NULL
                                     THEN ecommerce.fn_categorias_hijas_publicas(v.categoria_id)
                                WHEN v.alcance = 'cuerpo' AND v.marca_id IS NOT NULL
                                     THEN ecommerce.fn_categorias_de_marca_publicas(v.marca_id)
                                ELSE ecommerce.fn_categorias_destacadas_publicas() END)
                   WHEN v.clave = 'marcas_promocion' THEN
                        jsonb_build_object('clave', v.clave,
                            'marcas', ecommerce.fn_marcas_promocion_publicas())
                   WHEN v.clave = 'marcas' THEN
                        jsonb_build_object('clave', v.clave,
                            'marcas', CASE
                                WHEN v.alcance = 'cuerpo' AND v.categoria_id IS NOT NULL
                                     THEN ecommerce.fn_marcas_de_categoria_publicas(v.categoria_id)
                                ELSE ecommerce.fn_marcas_publicas() END)
                   -- EL CATÁLOGO. Sus productos NO van aquí: los pide la
                   -- tienda, paginados, porque son cientos. Lo que viaja es
                   -- cómo se pinta y de qué habla la página, que sale del
                   -- cuerpo (sin categoría ni marca: todo el catálogo).
                   WHEN v.clave = 'catalogo' THEN
                        jsonb_build_object('clave', 'catalogo',
                            -- Cuántas tarjetas antes de «Ver más productos»
                            'por_pagina', v.por_pagina,
                            'botones', v.botones,
                            'tarjeta', v.tarjeta)
                   -- Las demás todavía no tienen de dónde sacar datos. Se
                   -- devuelven NULL y se caen en el filtro de abajo; la tienda
                   -- ni se entera.
                   ELSE NULL
               END AS seccion
          FROM visibles v
          -- ===== Los productos de un escaparate =====
          --
          -- LOS DE FILA VIAJAN ENTEROS: son tres, cuatro, diez, los que alguien
          -- eligió para que se vean todos de una pasada con las flechas.
          --
          -- LOS PAGINADOS, UNA PÁGINA, y con sus filtros ya contados sobre la
          -- lista entera. Son los que hacen de catálogo: hasta el 09/11/2026
          -- también viajaban enteros y el navegador los iba soltando de a doce,
          -- y el de /tecnologia eran 63 KB para pintar doce tarjetas.
          --
          -- LA PRIMERA PÁGINA VIAJA CON LA PÁGINA, SIN FILTROS, a propósito: es
          -- lo que se ve al entrar, y pedirla aparte dejaría /motos con su
          -- encabezado y un hueco hasta que llegara la segunda petición. Lo que
          -- la dirección pida de más —otra página, algo marcado— ya lo pide la
          -- tienda. Por eso tampoco depende de la dirección: esta respuesta se
          -- guarda un minuto y la comparten todos los visitantes.
          LEFT JOIN LATERAL (
              SELECT CASE
                  WHEN v.grupo_productos_id IS NULL THEN NULL
                  WHEN v.disposicion = 'paginada' THEN (
                      SELECT jsonb_build_object(
                                 'productos',     p.pagina -> 'productos',
                                 'total',         p.pagina -> 'total',
                                 'por_pagina',    p.pagina -> 'por_pagina',
                                 'ultima_pagina', p.pagina -> 'ultima_pagina',
                                 -- Los filtros, contados en la base sobre los
                                 -- productos del escaparate: los de la ficha y
                                 -- los tres de la tienda
                                 'facetas',       p.pagina -> 'opciones' -> 'facetas')
                        FROM (SELECT ecommerce.fn_tienda_productos(jsonb_build_object(
                                         'escaparate', v.grupo_productos_id,
                                         'per_page',   COALESCE(v.por_pagina, 12))) AS pagina) p)
                  ELSE jsonb_build_object('productos',
                           ecommerce.fn_grupo_productos_publico(v.grupo_productos_id))
              END AS datos
          ) pag ON true
    )
    SELECT jsonb_build_object(
        -- De qué página se habla: su título, su texto y si debajo va el
        -- catálogo. La tienda lo necesita antes de pintar nada.
        'cuerpo', (SELECT jsonb_build_object(
                       'id',          e.id,
                       'ruta',        e.ruta,
                       'url',         CASE WHEN e.principal THEN '/' ELSE '/' || e.ruta END,
                       'principal',   e.principal,
                       'titulo',      e.titulo,
                       'descripcion', e.descripcion,
                       -- El fondo de la página; null = blanco
                       'fondo',       e.fondo,
                       'catalogo',    e.catalogo,
                       'categoria_id', e.categoria_id,
                       -- El nombre con el que la tienda la llama, que puede no
                       -- ser el del catálogo
                       'categoria',   (SELECT COALESCE(w.nombre_web, c.nombre)
                                         FROM inventarios.categorias c
                                         LEFT JOIN ecommerce.categorias_web w ON w.categoria_id = c.id
                                        WHERE c.id = e.categoria_id),
                       'categoria_ruta', inventarios.fn_categoria_ruta(e.categoria_id),
                       -- La categoría Y TODAS LAS QUE CUELGAN de ella: los
                       -- productos cuelgan de las hojas, así que el catálogo
                       -- de Movilidad son los de sus hijas y sus nietas
                       'categorias_base', to_jsonb(ecommerce.fn_categorias_rama(e.categoria_id)),
                       'marca_id',    e.marca_id,
                       'marca',       (SELECT m.nombre FROM inventarios.marcas m WHERE m.id = e.marca_id))
                     FROM elegido e),
        'secciones', COALESCE((
            SELECT jsonb_agg(
                       -- El rótulo, su pinta y el alto se añaden aquí y no en
                       -- cada rama: son de la sección, no de lo que la llena, y
                       -- así no se olvidan en la siguiente que se traslade
                       a.seccion || jsonb_build_object('titulo', a.titulo, 'subtitulo', a.subtitulo,
                                                       'estilo', a.estilo, 'alto', a.alto)
                       ORDER BY a.orden)
              FROM armadas a
             WHERE a.seccion IS NOT NULL
               AND (a.seccion -> 'imagenes'   IS NULL OR jsonb_array_length(a.seccion -> 'imagenes') > 0)
               AND (a.seccion -> 'categorias' IS NULL OR jsonb_array_length(a.seccion -> 'categorias') > 0)
               AND (a.seccion -> 'marcas'     IS NULL OR jsonb_array_length(a.seccion -> 'marcas') > 0)
               -- Una grupo de productos vacía no se manda: dejaría su título
               -- y nada debajo, que es peor que no estar.
               AND (a.seccion -> 'productos'  IS NULL OR jsonb_array_length(a.seccion -> 'productos') > 0)
            ), '[]'::jsonb))
      -- Sin página no se devuelve un objeto vacío: se devuelve nada, y el
      -- controlador contesta 404
     WHERE EXISTS (SELECT 1 FROM elegido);
$function$;

-- fn_cuerpos_guardar (se queda con su nombre: no es del grupo, lo usa)
DROP FUNCTION IF EXISTS ecommerce.fn_cuerpos_guardar(p_id bigint, p_datos jsonb, p_usuario_id bigint, p_usuario_login character varying, p_usuario_nombre character varying, p_ip_address inet, p_user_agent text, p_request_id uuid);
CREATE OR REPLACE FUNCTION ecommerce.fn_cuerpos_guardar(p_id bigint, p_datos jsonb, p_usuario_id bigint DEFAULT NULL::bigint, p_usuario_login character varying DEFAULT NULL::character varying, p_usuario_nombre character varying DEFAULT NULL::character varying, p_ip_address inet DEFAULT NULL::inet, p_user_agent text DEFAULT NULL::text, p_request_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'ecommerce', 'auditoria'
AS $function$
DECLARE
    v_id        bigint := p_id;
    v_nombre    text;
    v_ruta      text;
    v_categoria bigint;
    v_marca     bigint;
    v_principal boolean := false;
    v_fijo      boolean := false;
    v_ruta_vieja text;
    v_sembradas integer := 0;
    v_escaparate bigint;
    v_escaparate_nombre text;
BEGIN
    PERFORM ecommerce.fn_contexto_auditoria('ecommerce.cuerpos',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    IF p_id IS NOT NULL THEN
        SELECT principal, fijo, ruta INTO v_principal, v_fijo, v_ruta_vieja
          FROM ecommerce.cuerpos
         WHERE id = p_id AND deleted_at IS NULL;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'Ese cuerpo no existe' USING ERRCODE = 'P0013';
        END IF;
    END IF;

    v_nombre    := btrim(COALESCE(p_datos ->> 'nombre', ''));
    v_ruta      := lower(btrim(COALESCE(p_datos ->> 'ruta', '')));
    v_categoria := nullif(btrim(COALESCE(p_datos ->> 'categoria_id', '')), '')::bigint;
    v_marca     := nullif(btrim(COALESCE(p_datos ->> 'marca_id', '')), '')::bigint;

    -- EL ESCAPARATE CON EL QUE NACE LA PÁGINA, si eligieron uno al crearla.
    -- Es un atajo, igual que la casilla del catálogo: lo mismo se puede hacer
    -- después en el editor de secciones, pero una página recién creada está
    -- vacía y es justo el momento en que se le quiere meter algo.
    v_escaparate := nullif(btrim(COALESCE(p_datos ->> 'escaparate_id', '')), '')::bigint;

    -- El principal no apunta a nada, y se dice aquí para que el mensaje
    -- explique qué hacer; la tabla lo prohíbe igual por si entra por otro lado
    IF v_principal AND (v_categoria IS NOT NULL OR v_marca IS NOT NULL) THEN
        RAISE EXCEPTION 'El cuerpo principal es la entrada de la tienda: no puede ser además la página de una categoría o de una marca'
              USING ERRCODE = 'P0015';
    END IF;

    -- Una página fija no se muda: /shop es a donde apuntan el menú, el
    -- buscador y cada filtro, y moverla los rompería todos de golpe. Lo
    -- demás —nombre, título, fondo, secciones— se cambia con libertad.
    IF v_fijo AND v_ruta IS DISTINCT FROM v_ruta_vieja THEN
        RAISE EXCEPTION '«%» es una página que la tienda necesita: su dirección «/%» no se puede cambiar',
              v_nombre, v_ruta_vieja USING ERRCODE = 'P0015';
    END IF;

    PERFORM ecommerce.fn_cuerpos_validar(p_id, v_nombre, v_ruta, v_categoria, v_marca);

    IF p_id IS NULL THEN
        INSERT INTO ecommerce.cuerpos (nombre, ruta, categoria_id, marca_id, titulo, descripcion, fondo,
                                       catalogo, activo)
        VALUES (v_nombre, v_ruta, v_categoria, v_marca,
                ecommerce.fn_validar_texto(p_datos ->> 'titulo', 'El título de la página', 120),
                nullif(btrim(COALESCE(p_datos ->> 'descripcion', '')), ''),
                ecommerce.fn_validar_color(p_datos ->> 'fondo', 'El fondo de la página'),
                COALESCE((p_datos ->> 'catalogo')::boolean, false),
                COALESCE((p_datos ->> 'activo')::boolean, true))
        RETURNING id INTO v_id;

        -- Con las secciones que la tienda sabe pintar, apagadas: así se
        -- enciende lo que haga falta en vez de empezar con un hueco
        v_sembradas := ecommerce.fn_cuerpo_sembrar(v_id);

        -- SÓLO AL CREAR. En una página que ya existe esto sería un segundo
        -- sitio donde decir lo que dice el editor de secciones, y el mismo
        -- escaparate dos veces en la misma página lo rechaza la base.
        --
        -- Y SI EL ESCAPARATE NO EXISTE, LA PÁGINA NO SE CREA: `poner` revienta
        -- y se va todo. Es lo que se quiere: una página que se pidió con
        -- productos y nace vacía es peor que un error.
        IF v_escaparate IS NOT NULL THEN
            PERFORM ecommerce.fn_inicio_escaparate_poner(v_id, v_escaparate,
                p_usuario_id, p_usuario_login, p_usuario_nombre,
                p_ip_address, p_user_agent, p_request_id);

            SELECT nombre INTO v_escaparate_nombre
              FROM ecommerce.grupos_productos WHERE id = v_escaparate;
        END IF;
    ELSE
        UPDATE ecommerce.cuerpos
           SET nombre       = v_nombre,
               ruta         = v_ruta,
               categoria_id = v_categoria,
               marca_id     = v_marca,
               titulo       = ecommerce.fn_validar_texto(p_datos ->> 'titulo', 'El título de la página', 120),
               descripcion  = nullif(btrim(COALESCE(p_datos ->> 'descripcion', '')), ''),
               -- El fondo de ESTA página; vacío, blanco
               fondo        = ecommerce.fn_validar_color(p_datos ->> 'fondo', 'El fondo de la página'),
               catalogo     = COALESCE((p_datos ->> 'catalogo')::boolean, false),
               -- El principal no se puede apagar: la tienda se quedaría sin
               -- página de entrada
               activo       = CASE WHEN principal THEN true
                                   ELSE COALESCE((p_datos ->> 'activo')::boolean, true) END
         WHERE id = p_id;
    END IF;

    -- El catálogo es una SECCIÓN; la casilla sólo la crea o la apaga
    PERFORM ecommerce.fn_cuerpo_catalogo_sincronizar(
        v_id, COALESCE((p_datos ->> 'catalogo')::boolean, false));

    RETURN jsonb_build_object('success', true,
        'message', CASE
            WHEN p_id IS NOT NULL THEN format('Cuerpo «%s» guardado', v_nombre)
            WHEN v_escaparate_nombre IS NOT NULL
                THEN format('Cuerpo «%s» creado con «%s» dentro', v_nombre, v_escaparate_nombre)
            WHEN v_sembradas = 0   THEN format('Cuerpo «%s» creado', v_nombre)
            ELSE format('Cuerpo «%s» creado con sus %s secciones apagadas', v_nombre, v_sembradas) END,
        'data', ecommerce.fn_cuerpos_json(v_id));
END;
$function$;

-- fn_cuerpos_json (se queda con su nombre: no es del grupo, lo usa)
DROP FUNCTION IF EXISTS ecommerce.fn_cuerpos_json(p_id bigint);
CREATE OR REPLACE FUNCTION ecommerce.fn_cuerpos_json(p_id bigint)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
AS $function$
    SELECT jsonb_build_object(
        'id',           c.id,
        'nombre',       c.nombre,
        'ruta',         c.ruta,
        'principal',    c.principal,
        -- La dirección de verdad, armada aquí: el principal vive en la raíz y
        -- que lo sepan la pantalla y la tienda por separado es pedir que un
        -- día una de las dos se olvide.
        'url',          CASE WHEN c.principal THEN '/' ELSE '/' || c.ruta END,
        -- Lo decide el servidor, como `fija` en las secciones
        'destino',      CASE WHEN c.principal              THEN 'inicio'
                             WHEN c.categoria_id IS NOT NULL THEN 'categoria'
                             WHEN c.marca_id IS NOT NULL     THEN 'marca'
                             ELSE 'libre' END,
        'categoria_id', c.categoria_id,
        -- Con su ruta entera («Vehículos > Movilidad»): fuera del árbol, el
        -- nombre suelto no dice de qué categoría se habla
        'categoria',    inventarios.fn_categoria_ruta(c.categoria_id),
        'marca_id',     c.marca_id,
        'marca',        (SELECT m.nombre FROM inventarios.marcas m WHERE m.id = c.marca_id),
        'titulo',       c.titulo,
        'descripcion',  c.descripcion,
        'fondo',        c.fondo,
        'catalogo',     c.catalogo,
        'activo',       c.activo,
        'secciones',    (SELECT count(*) FROM ecommerce.inicio_secciones s
                          WHERE s.cuerpo_id = c.id
                            AND ecommerce.fn_inicio_seccion_viva(s.grupo_productos_id)),
        'estado',       CASE WHEN c.deleted_at IS NOT NULL THEN 'papelera'
                             WHEN NOT c.activo             THEN 'oculto'
                             WHEN c.principal              THEN 'principal'
                             ELSE 'visible' END,
        'deleted_at',   to_char(c.deleted_at, 'YYYY-MM-DD HH24:MI'),
        'deleted_by',   c.deleted_by,
        'updated_at',   to_char(c.updated_at, 'YYYY-MM-DD HH24:MI'),
        'updated_by',   c.updated_by)
      FROM ecommerce.cuerpos c
     WHERE c.id = p_id;
$function$;

-- fn_inicio_escaparate_poner (se queda con su nombre: no es del grupo, lo usa)
DROP FUNCTION IF EXISTS ecommerce.fn_inicio_escaparate_poner(p_cuerpo_id bigint, p_seccion_id bigint, p_usuario_id bigint, p_usuario_login character varying, p_usuario_nombre character varying, p_ip_address inet, p_user_agent text, p_request_id uuid);
CREATE OR REPLACE FUNCTION ecommerce.fn_inicio_escaparate_poner(p_cuerpo_id bigint, p_grupo_id bigint, p_usuario_id bigint DEFAULT NULL::bigint, p_usuario_login character varying DEFAULT NULL::character varying, p_usuario_nombre character varying DEFAULT NULL::character varying, p_ip_address inet DEFAULT NULL::inet, p_user_agent text DEFAULT NULL::text, p_request_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'ecommerce', 'auditoria'
AS $function$
DECLARE
    v_cuerpo  bigint := COALESCE(p_cuerpo_id, ecommerce.fn_cuerpo_principal_id());
    v_nombre  text;
    v_pagina  text;
    v_orden   integer;
BEGIN
    PERFORM ecommerce.fn_contexto_auditoria('ecommerce.inicio_secciones',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    SELECT nombre INTO v_pagina FROM ecommerce.cuerpos
     WHERE id = v_cuerpo AND deleted_at IS NULL;
    IF v_pagina IS NULL THEN
        RAISE EXCEPTION 'Ese cuerpo no existe' USING ERRCODE = 'P0013';
    END IF;

    SELECT nombre INTO v_nombre FROM ecommerce.grupos_productos
     WHERE id = p_grupo_id AND deleted_at IS NULL;
    IF v_nombre IS NULL THEN
        RAISE EXCEPTION 'Ese grupo de productos no existe o está en la papelera' USING ERRCODE = 'P0013';
    END IF;

    IF EXISTS (SELECT 1 FROM ecommerce.inicio_secciones
                WHERE cuerpo_id = v_cuerpo AND grupo_productos_id = p_grupo_id) THEN
        RAISE EXCEPTION '«%» ya está en «%»', v_nombre, v_pagina USING ERRCODE = 'P0015';
    END IF;

    SELECT COALESCE(max(orden), 0) + 1 INTO v_orden
      FROM ecommerce.inicio_secciones WHERE cuerpo_id = v_cuerpo;

    -- Nace ENCENDIDA y al final, como cuando se crea el escaparate: lo que se
    -- acaba de añadir se quiere ver.
    INSERT INTO ecommerce.inicio_secciones (cuerpo_id, clave, nombre, orden, activo, grupo_productos_id)
    VALUES (v_cuerpo, 'grupo_' || p_grupo_id, v_nombre, v_orden, true, p_grupo_id);

    RETURN jsonb_build_object('success', true,
        'message', format('«%s» añadida a «%s»', v_nombre, v_pagina),
        'data', (ecommerce.fn_inicio_listar(v_cuerpo) -> 'data'));
END;
$function$;

-- fn_inicio_escaparate_quitar (se queda con su nombre: no es del grupo, lo usa)
DROP FUNCTION IF EXISTS ecommerce.fn_inicio_escaparate_quitar(p_id bigint, p_usuario_id bigint, p_usuario_login character varying, p_usuario_nombre character varying, p_ip_address inet, p_user_agent text, p_request_id uuid);
CREATE OR REPLACE FUNCTION ecommerce.fn_inicio_escaparate_quitar(p_id bigint, p_usuario_id bigint DEFAULT NULL::bigint, p_usuario_login character varying DEFAULT NULL::character varying, p_usuario_nombre character varying DEFAULT NULL::character varying, p_ip_address inet DEFAULT NULL::inet, p_user_agent text DEFAULT NULL::text, p_request_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'ecommerce', 'auditoria'
AS $function$
DECLARE
    v_cuerpo   bigint;
    v_nombre   text;
    v_pagina   text;
    v_apunta   bigint;
BEGIN
    PERFORM ecommerce.fn_contexto_auditoria('ecommerce.inicio_secciones',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    SELECT cuerpo_id, nombre, grupo_productos_id
      INTO v_cuerpo, v_nombre, v_apunta
      FROM ecommerce.inicio_secciones WHERE id = p_id;
    IF v_nombre IS NULL THEN
        RAISE EXCEPTION 'Esa sección no existe' USING ERRCODE = 'P0013';
    END IF;
    IF v_apunta IS NULL THEN
        RAISE EXCEPTION 'Esa sección no es un escaparate de productos: no se quita desde aquí'
              USING ERRCODE = 'P0015';
    END IF;

    SELECT nombre INTO v_pagina FROM ecommerce.cuerpos WHERE id = v_cuerpo;

    DELETE FROM ecommerce.inicio_secciones WHERE id = p_id;

    -- El orden se compacta para que no queden huecos, sólo en su cuerpo
    WITH nuevo AS (
        SELECT id, row_number() OVER (ORDER BY orden, id) AS n
          FROM ecommerce.inicio_secciones WHERE cuerpo_id = v_cuerpo
    )
    UPDATE ecommerce.inicio_secciones s
       SET orden = nuevo.n
      FROM nuevo
     WHERE nuevo.id = s.id AND s.orden <> nuevo.n;

    RETURN jsonb_build_object('success', true,
        'message', format('«%s» ya no sale en «%s». Sus productos siguen en «Grupos de productos»',
                          v_nombre, v_pagina),
        'data', (ecommerce.fn_inicio_listar(v_cuerpo) -> 'data'));
END;
$function$;

-- fn_inicio_escaparates_disponibles (se queda con su nombre: no es del grupo, lo usa)
DROP FUNCTION IF EXISTS ecommerce.fn_inicio_escaparates_disponibles(p_cuerpo_id bigint);
CREATE OR REPLACE FUNCTION ecommerce.fn_inicio_escaparates_disponibles(p_cuerpo_id bigint DEFAULT NULL::bigint)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
AS $function$
    SELECT jsonb_build_object('success', true, 'message', 'Escaparates que se pueden añadir',
        'data', COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
                       'id', s.id,
                       'nombre', s.nombre,
                       'cuantos', (SELECT count(*)
                                     FROM ecommerce.grupos_productos_items it
                                     JOIN inventarios.productos p ON p.id = it.producto_id
                                    WHERE it.grupo_id = s.id AND p.deleted_at IS NULL),
                       -- En cuántas páginas sale ya, para no repetirlo sin querer
                       'en_paginas', (SELECT count(*) FROM ecommerce.inicio_secciones i
                                       WHERE i.grupo_productos_id = s.id))
                   ORDER BY s.orden, s.id)
              FROM ecommerce.grupos_productos s
             WHERE s.deleted_at IS NULL
               AND NOT EXISTS (
                   SELECT 1 FROM ecommerce.inicio_secciones i
                    WHERE i.grupo_productos_id = s.id
                      AND i.cuerpo_id = COALESCE(p_cuerpo_id, ecommerce.fn_cuerpo_principal_id()))
            ), '[]'::jsonb));
$function$;

-- fn_inicio_fuente (se queda con su nombre: no es del grupo, lo usa)
DROP FUNCTION IF EXISTS ecommerce.fn_inicio_fuente(p_clave text, p_producto_seccion_id bigint);
CREATE OR REPLACE FUNCTION ecommerce.fn_inicio_fuente(p_clave text, p_grupo_productos_id bigint DEFAULT NULL::bigint)
 RETURNS jsonb
 LANGUAGE sql
 IMMUTABLE PARALLEL SAFE
AS $function$
    SELECT CASE
        -- Las de productos se reconocen por a quién apuntan, no por su clave:
        -- la clave la fabrica el servidor y no debería haber dos sitios que
        -- sepan cómo se escribe.
        WHEN p_grupo_productos_id IS NOT NULL THEN
            jsonb_build_object('tipo', 'productos',
                               'pantalla', 'grupo-productos',
                               'grupo_id', p_grupo_productos_id)
        WHEN p_clave = 'banner_principal' THEN
            jsonb_build_object('tipo', 'galeria', 'galeria', 'inicio_banner')
        WHEN p_clave = 'banner_simple' THEN
            jsonb_build_object('tipo', 'galeria', 'galeria', 'inicio_banner_simple')
        -- El catálogo no se llena en ninguna pantalla: son TODOS los
        -- productos publicados, y lo que se elige aquí es su pinta
        WHEN p_clave = 'catalogo' THEN
            jsonb_build_object('tipo', 'catalogo', 'pantalla', 'allProductos')
        WHEN p_clave = 'mosaico' THEN
            jsonb_build_object('tipo', 'promocion', 'pantalla', 'allCategoriasWeb')
        WHEN p_clave = 'categorias_destacadas' THEN
            jsonb_build_object('tipo', 'destacadas', 'pantalla', 'allCategoriasWeb')
        WHEN p_clave = 'marcas_promocion' THEN
            jsonb_build_object('tipo', 'marcas_promocion', 'pantalla', 'allMarcasWeb')
        WHEN p_clave = 'marcas' THEN
            jsonb_build_object('tipo', 'marcas', 'pantalla', 'allMarcasWeb')
        ELSE jsonb_build_object('tipo', 'pendiente', 'falta', 'su fuente')
    END;
$function$;

-- fn_inicio_fuente (se queda con su nombre: no es del grupo, lo usa)
DROP FUNCTION IF EXISTS ecommerce.fn_inicio_fuente(p_clave text, p_producto_seccion_id bigint, p_galeria_clave text);
CREATE OR REPLACE FUNCTION ecommerce.fn_inicio_fuente(p_clave text, p_grupo_productos_id bigint DEFAULT NULL::bigint, p_galeria_clave text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE sql
 IMMUTABLE PARALLEL SAFE
AS $function$
    SELECT CASE
        -- Las de productos se reconocen por a quién apuntan, no por su clave:
        -- la clave la fabrica el servidor y no debería haber dos sitios que
        -- sepan cómo se escribe.
        WHEN p_grupo_productos_id IS NOT NULL THEN
            jsonb_build_object('tipo', 'productos',
                               'pantalla', 'grupo-productos',
                               'grupo_id', p_grupo_productos_id)
        -- Y los banners, por su galería. Va ANTES que las claves de fábrica
        -- porque «banner_simple» tiene las dos cosas: es de fábrica y tiene
        -- galería, y lo que manda es la galería.
        WHEN nullif(btrim(COALESCE(p_galeria_clave, '')), '') IS NOT NULL THEN
            jsonb_build_object('tipo', 'galeria', 'galeria', p_galeria_clave)
        WHEN p_clave = 'banner_principal' THEN
            jsonb_build_object('tipo', 'galeria', 'galeria', 'inicio_banner')
        -- El catálogo no se llena en ninguna pantalla: son TODOS los
        -- productos publicados, y lo que se elige aquí es su pinta
        WHEN p_clave = 'catalogo' THEN
            jsonb_build_object('tipo', 'catalogo', 'pantalla', 'allProductos')
        WHEN p_clave = 'mosaico' THEN
            jsonb_build_object('tipo', 'promocion', 'pantalla', 'allCategoriasWeb')
        WHEN p_clave = 'categorias_destacadas' THEN
            jsonb_build_object('tipo', 'destacadas', 'pantalla', 'allCategoriasWeb')
        WHEN p_clave = 'marcas' THEN
            jsonb_build_object('tipo', 'marcas', 'pantalla', 'allMarcasWeb')
        ELSE jsonb_build_object('tipo', 'pendiente', 'falta', 'su fuente')
    END;
$function$;

-- fn_inicio_listar (se queda con su nombre: no es del grupo, lo usa)
DROP FUNCTION IF EXISTS ecommerce.fn_inicio_listar(p_cuerpo_id bigint);
CREATE OR REPLACE FUNCTION ecommerce.fn_inicio_listar(p_cuerpo_id bigint DEFAULT NULL::bigint)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
AS $function$
    SELECT jsonb_build_object('success', true, 'message', 'Secciones del cuerpo',
        'data', COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
                       'id',         s.id,
                       'cuerpo_id',  s.cuerpo_id,
                       'clave',      s.clave,
                       'nombre',     s.nombre,
                       'titulo',     s.titulo,
                       'subtitulo',  s.subtitulo,
                       'estilo',     ecommerce.fn_rotulo_estilo(s.rotulo_tamano, s.rotulo_color, s.rotulo_fuente),
                       -- Resuelto, como el estilo: que la pantalla y la tienda
                       -- tengan que acordarse de que NULL es «normal» es la
                       -- manera de que un día una de las dos se olvide
                       'alto',       COALESCE(nullif(btrim(COALESCE(s.alto, '')), ''), 'normal'),
                       -- El alto de sus imágenes, resuelto igual. Sólo lo
                       -- miran los banners; 'imagen' es «el que traiga cada una»
                       'alto_imagen', COALESCE(nullif(btrim(COALESCE(s.alto_imagen, '')), ''), 'imagen'),
                       'orden',      s.orden,
                       'activo',     s.activo,
                       'desde',      to_char(s.desde, 'YYYY-MM-DD"T"HH24:MI'),
                       'hasta',      to_char(s.hasta, 'YYYY-MM-DD"T"HH24:MI'),
                       'updated_at', to_char(s.updated_at, 'YYYY-MM-DD HH24:MI'),
                       'updated_by', s.updated_by,
                       -- A qué escaparate o a qué galería apunta, y si es de
                       -- las de fábrica. `fija` lo decide el servidor: la
                       -- pantalla no tiene por qué saber cómo se escribe una
                       -- clave fabricada.
                       'grupo_productos_id', s.grupo_productos_id,
                       'galeria_id', s.galeria_id,
                       -- Con galería, la pantalla enseña sus imágenes
                       'es_banner',  s.galeria_id IS NOT NULL,
                       -- De fábrica: se apaga, no se borra ni se renombra
                       'fija',       ecommerce.fn_inicio_seccion_de_fabrica(s.clave),
                       'banner_vista', COALESCE(nullif(btrim(COALESCE(s.banner_vista, '')), ''), 'rotativo'),
                       'segundos', s.segundos,
                       'por_pagina', s.por_pagina,
                       'forma', COALESCE(nullif(btrim(COALESCE(s.forma, '')), ''), 'circulo'),
                       -- Lo de toda la tienda o lo que cuelga de la categoría
                       -- o la marca del cuerpo. Sólo lo miran las secciones de
                       -- categorías y de marcas.
                       'alcance', COALESCE(nullif(btrim(COALESCE(s.alcance, '')), ''), 'tienda'),
                       'botones',    ecommerce.fn_botones_colores(
                                           s.boton_favorito_color, s.boton_favorito_texto,
                                           s.boton_carrito_color,  s.boton_carrito_texto,
                                           s.boton_whatsapp_color, s.boton_whatsapp_texto,
                                           s.boton_tarjeta_color,  s.boton_tarjeta_texto),
                       'tarjeta',    ecommerce.fn_tarjeta_colores(
                                           s.tarjeta_fondo_color, s.tarjeta_borde_color,
                                           s.descuento_color,     s.descuento_texto,
                                           s.etiqueta, s.etiqueta_color, s.etiqueta_texto,
                                           s.tarjeta_sombra),
                       'imagen',     ecommerce.fn_seccion_imagen(s.disposicion, s.imagen,
                                           s.imagen_alt, s.imagen_enlace, s.imagen_nueva_pestana),
                       'estado',     CASE
                           WHEN NOT s.activo THEN 'oculta'
                           WHEN s.desde IS NOT NULL AND CURRENT_TIMESTAMP < s.desde THEN 'programada'
                           WHEN s.hasta IS NOT NULL AND CURRENT_TIMESTAMP > s.hasta THEN 'terminada'
                           ELSE 'visible' END,
                       'fuente',     fu.f,
                       'cuantas',    CASE fu.f ->> 'tipo'
                           WHEN 'galeria' THEN
                               (SELECT count(*) FROM ecommerce.galerias_imagenes i
                                  JOIN ecommerce.galerias gg ON gg.id = i.galeria_id
                                 WHERE gg.clave = fu.f ->> 'galeria'
                                   AND i.deleted_at IS NULL)
                           WHEN 'promocion' THEN
                               jsonb_array_length(ecommerce.fn_categorias_promocion_publicas())
                           WHEN 'destacadas' THEN
                               jsonb_array_length(ecommerce.fn_categorias_destacadas_publicas())
                           WHEN 'marcas' THEN
                               jsonb_array_length(ecommerce.fn_marcas_publicas())
                           WHEN 'marcas_promocion' THEN
                               jsonb_array_length(ecommerce.fn_marcas_promocion_publicas())
                           -- Los del escaparate, sin los que estén en la
                           -- papelera del catálogo: si contara las filas del
                           -- cruce diría ocho y la pantalla enseñaría seis.
                           WHEN 'productos' THEN
                               (SELECT count(*)
                                  FROM ecommerce.grupos_productos_items it
                                  JOIN inventarios.productos p ON p.id = it.producto_id
                                 WHERE it.grupo_id = s.grupo_productos_id
                                   AND p.deleted_at IS NULL
                                   -- Los que la tienda va a enseñar DE VERDAD: un
                                   -- escaparate lleno de productos apagados es un
                                   -- escaparate que la tienda se salta
                                   AND p.activo AND p.en_paginaweb)
                           -- El catálogo no se llena a mano: son todos los publicados
                           WHEN 'catalogo' THEN
                               (SELECT count(*) FROM inventarios.productos p
                                 WHERE p.deleted_at IS NULL AND p.activo AND p.en_paginaweb)
                           END,
                       'con_contenido', CASE fu.f ->> 'tipo'
                           WHEN 'galeria' THEN
                               EXISTS (SELECT 1 FROM ecommerce.galerias_imagenes i
                                         JOIN ecommerce.galerias gg ON gg.id = i.galeria_id
                                        WHERE gg.clave = fu.f ->> 'galeria'
                                          AND i.deleted_at IS NULL AND i.activo
                                          AND ecommerce.fn_vigente(i.desde, i.hasta))
                           WHEN 'promocion' THEN
                               jsonb_array_length(ecommerce.fn_categorias_promocion_publicas()) > 0
                           WHEN 'destacadas' THEN
                               jsonb_array_length(ecommerce.fn_categorias_destacadas_publicas()) > 0
                           -- Aquí basta con que haya alguna marcada: el cartel se
                           -- pinta con su color aunque no tenga foto, igual que
                           -- el de una categoría.
                           WHEN 'marcas_promocion' THEN
                               jsonb_array_length(ecommerce.fn_marcas_promocion_publicas()) > 0
                           -- La tienda sólo pinta las que tienen logo: una
                           -- marca sin imagen no cuenta como contenido.
                           WHEN 'marcas' THEN
                               EXISTS (SELECT 1 FROM jsonb_array_elements(ecommerce.fn_marcas_publicas()) m
                                        WHERE COALESCE(m ->> 'imagen', m ->> 'logo') IS NOT NULL)
                           WHEN 'productos' THEN
                               EXISTS (SELECT 1
                                         FROM ecommerce.grupos_productos_items it
                                         JOIN inventarios.productos p ON p.id = it.producto_id
                                        WHERE it.grupo_id = s.grupo_productos_id
                                          AND p.deleted_at IS NULL
                                          AND p.activo AND p.en_paginaweb)
                           WHEN 'catalogo' THEN
                               EXISTS (SELECT 1 FROM inventarios.productos p
                                        WHERE p.deleted_at IS NULL AND p.activo AND p.en_paginaweb)
                           ELSE false END)
                   ORDER BY s.orden, s.id)
              FROM ecommerce.inicio_secciones s
              LEFT JOIN ecommerce.galerias g ON g.id = s.galeria_id
              CROSS JOIN LATERAL (
                  SELECT ecommerce.fn_inicio_fuente(s.clave, s.grupo_productos_id, g.clave) AS f
              ) fu
             WHERE s.cuerpo_id = COALESCE(p_cuerpo_id, ecommerce.fn_cuerpo_principal_id())
               AND ecommerce.fn_inicio_seccion_viva(s.grupo_productos_id)), '[]'::jsonb));
$function$;

-- fn_inicio_ordenar (se queda con su nombre: no es del grupo, lo usa)
DROP FUNCTION IF EXISTS ecommerce.fn_inicio_ordenar(p_ids jsonb, p_cuerpo_id bigint, p_usuario_id bigint, p_usuario_login character varying, p_usuario_nombre character varying, p_ip_address inet, p_user_agent text, p_request_id uuid);
CREATE OR REPLACE FUNCTION ecommerce.fn_inicio_ordenar(p_ids jsonb, p_cuerpo_id bigint DEFAULT NULL::bigint, p_usuario_id bigint DEFAULT NULL::bigint, p_usuario_login character varying DEFAULT NULL::character varying, p_usuario_nombre character varying DEFAULT NULL::character varying, p_ip_address inet DEFAULT NULL::inet, p_user_agent text DEFAULT NULL::text, p_request_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'ecommerce', 'auditoria'
AS $function$
DECLARE
    v_cuerpo    bigint := COALESCE(p_cuerpo_id, ecommerce.fn_cuerpo_principal_id());
    v_recibidas integer;
    v_conocidas integer;
    v_todas     integer;
BEGIN
    PERFORM ecommerce.fn_contexto_auditoria('ecommerce.inicio_secciones',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    IF p_ids IS NULL OR jsonb_typeof(p_ids) <> 'array' OR jsonb_array_length(p_ids) = 0 THEN
        RAISE EXCEPTION 'Hace falta el orden de las secciones' USING ERRCODE = 'P0001';
    END IF;

    v_recibidas := jsonb_array_length(p_ids);

    -- Las que llegan Y son de este cuerpo: así un id de otro cuerpo no
    -- reordena nada a escondidas, se queja
    SELECT count(*) INTO v_conocidas FROM ecommerce.inicio_secciones
     WHERE cuerpo_id = v_cuerpo
       AND id IN (SELECT x::bigint FROM jsonb_array_elements_text(p_ids) x)
       AND ecommerce.fn_inicio_seccion_viva(grupo_productos_id);

    SELECT count(*) INTO v_todas FROM ecommerce.inicio_secciones
     WHERE cuerpo_id = v_cuerpo
       AND ecommerce.fn_inicio_seccion_viva(grupo_productos_id);

    IF v_conocidas <> v_recibidas OR v_recibidas <> v_todas THEN
        RAISE EXCEPTION 'El orden tiene que traer las % secciones del cuerpo, y trae % válidas de %',
              v_todas, v_conocidas, v_recibidas USING ERRCODE = 'P0016';
    END IF;

    UPDATE ecommerce.inicio_secciones s
       SET orden = n.pos
      FROM (SELECT x.id::bigint AS id, x.pos
              FROM jsonb_array_elements_text(p_ids) WITH ORDINALITY AS x(id, pos)) n
     WHERE s.id = n.id AND s.cuerpo_id = v_cuerpo;

    RETURN jsonb_build_object('success', true, 'message', 'Orden guardado',
                              'data', (ecommerce.fn_inicio_listar(v_cuerpo) -> 'data'));
END;
$function$;

-- fn_inicio_seccion_de_fabrica (se queda con su nombre: no es del grupo, lo usa)
DROP FUNCTION IF EXISTS ecommerce.fn_inicio_seccion_de_fabrica(p_clave text);
CREATE OR REPLACE FUNCTION ecommerce.fn_inicio_seccion_de_fabrica(p_clave text)
 RETURNS boolean
 LANGUAGE sql
 IMMUTABLE PARALLEL SAFE
AS $function$
    SELECT COALESCE(p_clave, '') !~ '^(banner|grupo)_[0-9]+$';
$function$;

-- fn_inicio_seccion_viva (se queda con su nombre: no es del grupo, lo usa)
DROP FUNCTION IF EXISTS ecommerce.fn_inicio_seccion_viva(p_producto_seccion_id bigint);
CREATE OR REPLACE FUNCTION ecommerce.fn_inicio_seccion_viva(p_grupo_productos_id bigint)
 RETURNS boolean
 LANGUAGE sql
 STABLE PARALLEL SAFE
AS $function$
    SELECT p_grupo_productos_id IS NULL
        OR EXISTS (SELECT 1 FROM ecommerce.grupos_productos ps
                    WHERE ps.id = p_grupo_productos_id AND ps.deleted_at IS NULL);
$function$;

-- fn_producto_seccion_agregar  →  fn_grupo_productos_agregar
DROP FUNCTION IF EXISTS ecommerce.fn_producto_seccion_agregar(p_seccion_id bigint, p_producto_ids jsonb, p_usuario_id bigint, p_usuario_login character varying, p_usuario_nombre character varying, p_ip_address inet, p_user_agent text, p_request_id uuid);
CREATE OR REPLACE FUNCTION ecommerce.fn_grupo_productos_agregar(p_grupo_id bigint, p_producto_ids jsonb, p_usuario_id bigint DEFAULT NULL::bigint, p_usuario_login character varying DEFAULT NULL::character varying, p_usuario_nombre character varying DEFAULT NULL::character varying, p_ip_address inet DEFAULT NULL::inet, p_user_agent text DEFAULT NULL::text, p_request_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'ecommerce', 'auditoria'
AS $function$
DECLARE
    v_nombre    text;
    v_pedidos   bigint[];
    v_faltan    bigint[];
    v_base      integer;
    v_metidos   integer;
BEGIN
    PERFORM ecommerce.fn_contexto_auditoria('ecommerce.grupos_productos_items',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    SELECT nombre INTO v_nombre FROM ecommerce.grupos_productos
     WHERE id = p_grupo_id AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'El grupo no existe' USING ERRCODE = 'P0013';
    END IF;

    IF jsonb_typeof(p_producto_ids) <> 'array' THEN
        RAISE EXCEPTION 'Se esperaba la lista de productos' USING ERRCODE = 'P0015';
    END IF;

    SELECT array_agg(DISTINCT valor::bigint) INTO v_pedidos
      FROM jsonb_array_elements_text(p_producto_ids) AS x(valor);

    IF v_pedidos IS NULL OR cardinality(v_pedidos) = 0 THEN
        RAISE EXCEPTION 'No se eligió ningún producto' USING ERRCODE = 'P0001';
    END IF;

    -- Un id que no existe es un fallo del cliente, no un caso normal: se
    -- avisa en vez de meter los demás y callarse, porque entonces la pantalla
    -- diría «40 agregados» de los 41 que se pidieron y nadie lo notaría.
    SELECT array_agg(id) INTO v_faltan
      FROM unnest(v_pedidos) AS id
     WHERE NOT EXISTS (SELECT 1 FROM inventarios.productos p
                        WHERE p.id = id AND p.deleted_at IS NULL);
    IF v_faltan IS NOT NULL THEN
        RAISE EXCEPTION 'Estos productos ya no están en el catálogo: %',
            array_to_string(v_faltan, ', ') USING ERRCODE = 'P0013';
    END IF;

    -- Al final del grupo, en el orden en que llegaron
    SELECT COALESCE(max(orden), 0) INTO v_base
      FROM ecommerce.grupos_productos_items WHERE grupo_id = p_grupo_id;

    INSERT INTO ecommerce.grupos_productos_items (grupo_id, producto_id, orden)
    SELECT p_grupo_id, t.id, v_base + t.posicion
      FROM (SELECT id, row_number() OVER (ORDER BY id)::integer AS posicion
              FROM unnest(v_pedidos) AS id) t
        ON CONFLICT (grupo_id, producto_id) DO NOTHING;
    GET DIAGNOSTICS v_metidos = ROW_COUNT;

    RETURN jsonb_build_object('success', true,
        'message', CASE
            WHEN v_metidos = 0 THEN format('Ya estaban todos en «%s»', v_nombre)
            WHEN v_metidos = cardinality(v_pedidos) AND v_metidos = 1
                THEN format('1 producto agregado a «%s»', v_nombre)
            WHEN v_metidos = cardinality(v_pedidos)
                THEN format('%s productos agregados a «%s»', v_metidos, v_nombre)
            ELSE format('%s agregados a «%s»; %s ya estaban', v_metidos, v_nombre,
                        cardinality(v_pedidos) - v_metidos) END,
        'data', jsonb_build_object(
            'grupo',   ecommerce.fn_grupos_productos_json(p_grupo_id),
            'agregados', v_metidos,
            'repetidos', cardinality(v_pedidos) - v_metidos));
END;
$function$;

-- fn_producto_seccion_agregar_filtro  →  fn_grupo_productos_agregar_filtro
DROP FUNCTION IF EXISTS ecommerce.fn_producto_seccion_agregar_filtro(p_seccion_id bigint, p_filtro jsonb, p_usuario_id bigint, p_usuario_login character varying, p_usuario_nombre character varying, p_ip_address inet, p_user_agent text, p_request_id uuid);
CREATE OR REPLACE FUNCTION ecommerce.fn_grupo_productos_agregar_filtro(p_grupo_id bigint, p_filtro jsonb, p_usuario_id bigint DEFAULT NULL::bigint, p_usuario_login character varying DEFAULT NULL::character varying, p_usuario_nombre character varying DEFAULT NULL::character varying, p_ip_address inet DEFAULT NULL::inet, p_user_agent text DEFAULT NULL::text, p_request_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'ecommerce', 'auditoria', 'inventarios'
AS $function$
DECLARE
    v_search     text;
    v_marcas     bigint[];
    v_categorias bigint[];
    v_filtros    jsonb;
    v_total      bigint;
    v_ids        jsonb;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM ecommerce.grupos_productos
                    WHERE id = p_grupo_id AND deleted_at IS NULL) THEN
        RAISE EXCEPTION 'El grupo no existe' USING ERRCODE = 'P0013';
    END IF;

    p_filtro := COALESCE(p_filtro, '{}'::jsonb);
    IF jsonb_typeof(p_filtro) <> 'object' THEN
        RAISE EXCEPTION 'Se esperaba el filtro del panel' USING ERRCODE = 'P0015';
    END IF;

    v_search  := COALESCE(p_filtro ->> 'search', '');
    v_filtros := CASE WHEN jsonb_typeof(p_filtro -> 'filtros') = 'object'
                      THEN p_filtro -> 'filtros' ELSE '{}'::jsonb END;

    SELECT array_agg(valor::bigint) INTO v_marcas
      FROM jsonb_array_elements_text(
               CASE WHEN jsonb_typeof(p_filtro -> 'marca_ids') = 'array'
                    THEN p_filtro -> 'marca_ids' ELSE '[]'::jsonb END) AS x(valor);

    SELECT array_agg(valor::bigint) INTO v_categorias
      FROM jsonb_array_elements_text(
               CASE WHEN jsonb_typeof(p_filtro -> 'categoria_ids') = 'array'
                    THEN p_filtro -> 'categoria_ids' ELSE '[]'::jsonb END) AS x(valor);

    -- Primero cuántos son: `p_per_page` tiene que ser un número de verdad y
    -- pedir «todos» con un tope inventado dejaría fuera lo que pase del tope
    -- sin avisar de nada.
    v_total := (inventarios.fn_productos_listar_paginado(
                    1, 1, v_search, v_marcas, v_categorias, v_filtros,
                    (p_filtro ->> 'precio_min')::numeric, (p_filtro ->> 'precio_max')::numeric,
                    (p_filtro ->> 'costo_min')::numeric,  (p_filtro ->> 'costo_max')::numeric
                ) -> 'meta' ->> 'total')::bigint;

    IF v_total IS NULL THEN
        RAISE EXCEPTION 'No pude contar los productos del filtro' USING ERRCODE = 'P0015';
    END IF;
    IF v_total = 0 THEN
        RAISE EXCEPTION 'Con ese filtro no hay ningún producto que agregar' USING ERRCODE = 'P0001';
    END IF;

    SELECT jsonb_agg(fila -> 'id') INTO v_ids
      FROM jsonb_array_elements(
               inventarios.fn_productos_listar_paginado(
                   1, v_total::integer, v_search, v_marcas, v_categorias, v_filtros,
                   (p_filtro ->> 'precio_min')::numeric, (p_filtro ->> 'precio_max')::numeric,
                   (p_filtro ->> 'costo_min')::numeric,  (p_filtro ->> 'costo_max')::numeric
               ) -> 'data') AS x(fila);

    RETURN ecommerce.fn_grupo_productos_agregar(p_grupo_id, v_ids,
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);
END;
$function$;

-- fn_producto_seccion_ids  →  fn_grupo_productos_ids
DROP FUNCTION IF EXISTS ecommerce.fn_producto_seccion_ids(p_seccion_id bigint);
CREATE OR REPLACE FUNCTION ecommerce.fn_grupo_productos_ids(p_grupo_id bigint)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
AS $function$
    SELECT jsonb_build_object('success', true, 'message', 'Productos del grupo',
        'data', COALESCE((
            SELECT jsonb_agg(i.producto_id ORDER BY i.orden, i.producto_id)
              FROM ecommerce.grupos_productos_items i
             WHERE i.grupo_id = p_grupo_id), '[]'::jsonb));
$function$;

-- fn_producto_seccion_ordenar  →  fn_grupo_productos_ordenar
DROP FUNCTION IF EXISTS ecommerce.fn_producto_seccion_ordenar(p_seccion_id bigint, p_producto_ids jsonb, p_usuario_id bigint, p_usuario_login character varying, p_usuario_nombre character varying, p_ip_address inet, p_user_agent text, p_request_id uuid);
CREATE OR REPLACE FUNCTION ecommerce.fn_grupo_productos_ordenar(p_grupo_id bigint, p_producto_ids jsonb, p_usuario_id bigint DEFAULT NULL::bigint, p_usuario_login character varying DEFAULT NULL::character varying, p_usuario_nombre character varying DEFAULT NULL::character varying, p_ip_address inet DEFAULT NULL::inet, p_user_agent text DEFAULT NULL::text, p_request_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'ecommerce', 'auditoria'
AS $function$
DECLARE
    v_cuantos integer;
BEGIN
    PERFORM ecommerce.fn_contexto_auditoria('ecommerce.grupos_productos_items',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    IF NOT EXISTS (SELECT 1 FROM ecommerce.grupos_productos
                    WHERE id = p_grupo_id AND deleted_at IS NULL) THEN
        RAISE EXCEPTION 'El grupo no existe' USING ERRCODE = 'P0013';
    END IF;

    IF jsonb_typeof(p_producto_ids) <> 'array' THEN
        RAISE EXCEPTION 'Se esperaba la lista de productos en el orden nuevo' USING ERRCODE = 'P0015';
    END IF;

    UPDATE ecommerce.grupos_productos_items i
       SET orden = t.posicion
      FROM (SELECT valor::bigint AS id, ordinalidad::integer AS posicion
              FROM jsonb_array_elements_text(p_producto_ids) WITH ORDINALITY AS x(valor, ordinalidad)) t
     WHERE i.grupo_id = p_grupo_id AND i.producto_id = t.id;
    GET DIAGNOSTICS v_cuantos = ROW_COUNT;

    RETURN jsonb_build_object('success', true,
        'message', CASE v_cuantos WHEN 1 THEN 'Producto movido'
                                  ELSE format('%s productos reordenados', v_cuantos) END,
        'data', (ecommerce.fn_grupo_productos_contenido(p_grupo_id) -> 'data'));
END;
$function$;

-- fn_producto_seccion_productos  →  fn_grupo_productos_contenido
DROP FUNCTION IF EXISTS ecommerce.fn_producto_seccion_productos(p_seccion_id bigint);
CREATE OR REPLACE FUNCTION ecommerce.fn_grupo_productos_contenido(p_grupo_id bigint)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
AS $function$
    SELECT jsonb_build_object('success', true, 'message', 'Productos del grupo',
        'data', COALESCE((
            SELECT jsonb_agg(inventarios.fn_productos_json(p.id)
                             || jsonb_build_object('orden_grupo', i.orden)
                             ORDER BY i.orden, p.id)
              FROM ecommerce.grupos_productos_items i
              JOIN inventarios.productos p ON p.id = i.producto_id
             WHERE i.grupo_id = p_grupo_id
               AND p.deleted_at IS NULL), '[]'::jsonb));
$function$;

-- fn_producto_seccion_publica  →  fn_grupo_productos_publico
DROP FUNCTION IF EXISTS ecommerce.fn_producto_seccion_publica(p_seccion_id bigint);
CREATE OR REPLACE FUNCTION ecommerce.fn_grupo_productos_publico(p_grupo_id bigint)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
AS $function$
    SELECT COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
                   -- `pro_id` es además la REFERENCIA que se lee en la tarjeta,
                   -- y con él y el nombre la tienda arma sola la dirección de
                   -- la ficha
                   'pro_id',          p.id,
                   'codigo',          COALESCE(p.codigo, ''),
                   'nombre',          p.nombre,
                   -- La marca, para la pastilla de debajo del nombre. Van el
                   -- nombre Y el fichero del logo: casi ninguna marca tiene
                   -- logo todavía, y sin el nombre esas tarjetas se quedarían
                   -- con un hueco. Además es lo que describe al logo para
                   -- quien no ve la pantalla.
                   'marca',           COALESCE(NULLIF(btrim(m.nombre), ''), ''),
                   -- Nombre del fichero: la dirección la arma el controlador
                   'marca_logo',      NULLIF(btrim(COALESCE(m.logo, '')), ''),
                   -- La tienda lo usa SÓLO para saber si el producto es una
                   -- moto y enseñar nada más el botón de WhatsApp
                   'tpr_id',          p.categoria_id,
                   'categoria',       COALESCE(NULLIF(btrim(cw.nombre_web), ''), cat.nombre, ''),
                   -- SÓLO LAS DOS PRIMERAS de su galería: la que se ve y la que
                   -- sale al pasar el mouse por encima, que es lo único que
                   -- pinta la tarjeta. El catálogo manda la galería entera
                   -- porque de ahí sale también la ficha; aquí serían bytes
                   -- para nadie. Una sola consulta con LIMIT 2 y no dos
                   -- subconsultas: así no hay forma de que la «segunda» acabe
                   -- siendo la misma que la primera.
                   'imagenes',        COALESCE(fotos.lista, '[]'::jsonb),
                   'destacado',       false,
                   -- EL PRECIO DE VERDAD, el del catálogo. Hasta el 08/11/2026
                   -- la tarjeta se lo inventaba a partir del id porque esto no
                   -- se mandaba.
                   'precio',          round(COALESCE(p.precio, 0), 2),
                   -- Y el de antes, para tacharlo. NULL = no está en oferta, y
                   -- entonces la tarjeta no tacha nada ni saca el descuento.
                   'precio_anterior', round(p.precio_anterior, 2),
                   -- Lo que cuesta con tarjeta de crédito, que es EL importe
                   -- que enseña la tarjeta; NULL = el mismo que «precio»
                   'precio_tarjeta',  round(p.precio_tarjeta, 2),
                   -- La cuota del crédito directo; NULL = no se ofrece y esa
                   -- celda no se pinta
                   'cuota_credito_directo', round(p.cuota_credito_directo, 2),
                   'stock',           1)
               ORDER BY it.orden, p.id)
          FROM ecommerce.grupos_productos_items it
          JOIN inventarios.productos p ON p.id = it.producto_id
          -- LEFT: un producto sin marca sigue siendo un producto y su tarjeta
          -- tiene que salir igual
          LEFT JOIN inventarios.marcas m         ON m.id   = p.marca_id     AND m.deleted_at IS NULL
          LEFT JOIN inventarios.categorias cat   ON cat.id = p.categoria_id AND cat.deleted_at IS NULL
          LEFT JOIN ecommerce.categorias_web cw  ON cw.categoria_id = p.categoria_id
          LEFT JOIN LATERAL (
              SELECT jsonb_agg(g.archivo ORDER BY g.puesto) AS lista
                FROM (SELECT btrim(i.archivo) AS archivo,
                             row_number() OVER (ORDER BY i.principal DESC, i.orden, i.id) AS puesto
                        FROM inventarios.productos_imagenes i
                       WHERE i.producto_id = p.id
                         AND NULLIF(btrim(COALESCE(i.archivo, '')), '') IS NOT NULL) g
               WHERE g.puesto <= 2
          ) fotos ON true
         WHERE it.grupo_id = p_grupo_id
           AND p.deleted_at IS NULL
           AND p.activo
           AND p.en_paginaweb), '[]'::jsonb);
$function$;

-- fn_producto_seccion_quitar  →  fn_grupo_productos_quitar
DROP FUNCTION IF EXISTS ecommerce.fn_producto_seccion_quitar(p_seccion_id bigint, p_producto_ids jsonb, p_usuario_id bigint, p_usuario_login character varying, p_usuario_nombre character varying, p_ip_address inet, p_user_agent text, p_request_id uuid);
CREATE OR REPLACE FUNCTION ecommerce.fn_grupo_productos_quitar(p_grupo_id bigint, p_producto_ids jsonb, p_usuario_id bigint DEFAULT NULL::bigint, p_usuario_login character varying DEFAULT NULL::character varying, p_usuario_nombre character varying DEFAULT NULL::character varying, p_ip_address inet DEFAULT NULL::inet, p_user_agent text DEFAULT NULL::text, p_request_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'ecommerce', 'auditoria'
AS $function$
DECLARE
    v_nombre  text;
    v_pedidos bigint[];
    v_fuera   integer;
BEGIN
    PERFORM ecommerce.fn_contexto_auditoria('ecommerce.grupos_productos_items',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    SELECT nombre INTO v_nombre FROM ecommerce.grupos_productos
     WHERE id = p_grupo_id AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'El grupo no existe' USING ERRCODE = 'P0013';
    END IF;

    IF jsonb_typeof(p_producto_ids) <> 'array' THEN
        RAISE EXCEPTION 'Se esperaba la lista de productos' USING ERRCODE = 'P0015';
    END IF;

    SELECT array_agg(DISTINCT valor::bigint) INTO v_pedidos
      FROM jsonb_array_elements_text(p_producto_ids) AS x(valor);

    IF v_pedidos IS NULL OR cardinality(v_pedidos) = 0 THEN
        RAISE EXCEPTION 'No se eligió ningún producto' USING ERRCODE = 'P0001';
    END IF;

    -- Quitar algo que no estaba no es un error: el producto acaba fuera, que
    -- es lo que se pedía. Lo que se dice es cuántos se fueron de verdad.
    DELETE FROM ecommerce.grupos_productos_items
     WHERE grupo_id = p_grupo_id AND producto_id = ANY(v_pedidos);
    GET DIAGNOSTICS v_fuera = ROW_COUNT;

    -- Renumerar: si no, quitar del medio deja huecos y el siguiente que se
    -- agregue cae con un orden que ya pasó.
    WITH nuevo AS (
        SELECT producto_id, row_number() OVER (ORDER BY orden, producto_id)::integer AS posicion
          FROM ecommerce.grupos_productos_items WHERE grupo_id = p_grupo_id)
    UPDATE ecommerce.grupos_productos_items i
       SET orden = n.posicion
      FROM nuevo n
     WHERE i.grupo_id = p_grupo_id AND i.producto_id = n.producto_id
       AND i.orden <> n.posicion;

    RETURN jsonb_build_object('success', true,
        'message', CASE
            WHEN v_fuera = 0 THEN format('Ninguno de esos productos estaba en «%s»', v_nombre)
            WHEN v_fuera = 1 THEN format('1 producto fuera de «%s»', v_nombre)
            ELSE format('%s productos fuera de «%s»', v_fuera, v_nombre) END,
        'data', jsonb_build_object(
            'grupo',  ecommerce.fn_grupos_productos_json(p_grupo_id),
            'quitados', v_fuera));
END;
$function$;

-- fn_producto_secciones_activar  →  fn_grupos_productos_activar
DROP FUNCTION IF EXISTS ecommerce.fn_producto_secciones_activar(p_id bigint, p_activo boolean, p_usuario_id bigint, p_usuario_login character varying, p_usuario_nombre character varying, p_ip_address inet, p_user_agent text, p_request_id uuid);
CREATE OR REPLACE FUNCTION ecommerce.fn_grupos_productos_activar(p_id bigint, p_activo boolean DEFAULT NULL::boolean, p_usuario_id bigint DEFAULT NULL::bigint, p_usuario_login character varying DEFAULT NULL::character varying, p_usuario_nombre character varying DEFAULT NULL::character varying, p_ip_address inet DEFAULT NULL::inet, p_user_agent text DEFAULT NULL::text, p_request_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'ecommerce', 'auditoria'
AS $function$
DECLARE
    v_antes  boolean;
    v_nombre text;
BEGIN
    PERFORM ecommerce.fn_contexto_auditoria('ecommerce.grupos_productos',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    SELECT activo, nombre INTO v_antes, v_nombre
      FROM ecommerce.grupos_productos WHERE id = p_id AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'El grupo no existe' USING ERRCODE = 'P0013';
    END IF;

    UPDATE ecommerce.grupos_productos
       SET activo = COALESCE(p_activo, NOT v_antes) WHERE id = p_id;

    RETURN jsonb_build_object('success', true,
        'message', format('Sección «%s» %s', v_nombre,
            CASE WHEN COALESCE(p_activo, NOT v_antes) THEN 'encendida' ELSE 'apagada' END),
        'data', ecommerce.fn_grupos_productos_json(p_id));
END;
$function$;

-- fn_producto_secciones_crear  →  fn_grupos_productos_crear
DROP FUNCTION IF EXISTS ecommerce.fn_producto_secciones_crear(p_nombre character varying, p_desde timestamp with time zone, p_hasta timestamp with time zone, p_usuario_id bigint, p_usuario_login character varying, p_usuario_nombre character varying, p_ip_address inet, p_user_agent text, p_request_id uuid);
CREATE OR REPLACE FUNCTION ecommerce.fn_grupos_productos_crear(p_nombre character varying, p_desde timestamp with time zone DEFAULT NULL::timestamp with time zone, p_hasta timestamp with time zone DEFAULT NULL::timestamp with time zone, p_usuario_id bigint DEFAULT NULL::bigint, p_usuario_login character varying DEFAULT NULL::character varying, p_usuario_nombre character varying DEFAULT NULL::character varying, p_ip_address inet DEFAULT NULL::inet, p_user_agent text DEFAULT NULL::text, p_request_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'ecommerce', 'auditoria'
AS $function$
DECLARE
    v_id bigint;
BEGIN
    PERFORM ecommerce.fn_contexto_auditoria('ecommerce.grupos_productos',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    PERFORM ecommerce.fn_grupos_productos_validar(NULL, p_nombre, p_desde, p_hasta);

    INSERT INTO ecommerce.grupos_productos (nombre, desde, hasta, orden)
    VALUES (btrim(p_nombre), p_desde, p_hasta,
            (SELECT COALESCE(max(orden), 0) + 1 FROM ecommerce.grupos_productos
              WHERE deleted_at IS NULL))
    RETURNING id INTO v_id;

    -- AQUÍ NO SE LE DA SITIO EN NINGUNA PÁGINA, y es lo que cambió: el
    -- escaparate se arma aquí y se añade donde se quiera con «Escaparate»
    -- (fn_inicio_escaparate_poner), en la principal igual que en las demás.
    RETURN jsonb_build_object('success', true,
        'message', format('Sección «%s» creada. Añádela a las páginas donde quieras que salga', btrim(p_nombre)),
        'data', ecommerce.fn_grupos_productos_json(v_id));
END;
$function$;

-- fn_producto_secciones_eliminar  →  fn_grupos_productos_eliminar
DROP FUNCTION IF EXISTS ecommerce.fn_producto_secciones_eliminar(p_id bigint, p_usuario_id bigint, p_usuario_login character varying, p_usuario_nombre character varying, p_ip_address inet, p_user_agent text, p_request_id uuid);
CREATE OR REPLACE FUNCTION ecommerce.fn_grupos_productos_eliminar(p_id bigint, p_usuario_id bigint DEFAULT NULL::bigint, p_usuario_login character varying DEFAULT NULL::character varying, p_usuario_nombre character varying DEFAULT NULL::character varying, p_ip_address inet DEFAULT NULL::inet, p_user_agent text DEFAULT NULL::text, p_request_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'ecommerce', 'auditoria'
AS $function$
DECLARE
    v_nombre text;
    v_items  integer;
BEGIN
    PERFORM ecommerce.fn_contexto_auditoria('ecommerce.grupos_productos',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    SELECT nombre INTO v_nombre FROM ecommerce.grupos_productos
     WHERE id = p_id AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'El grupo no existe' USING ERRCODE = 'P0013';
    END IF;

    SELECT count(*) INTO v_items FROM ecommerce.grupos_productos_items WHERE grupo_id = p_id;

    UPDATE ecommerce.grupos_productos
       SET deleted_at = CURRENT_TIMESTAMP, deleted_by = p_usuario_login
     WHERE id = p_id;

    RETURN jsonb_build_object('success', true,
        'message', CASE v_items
            WHEN 0 THEN format('Sección «%s» enviada a la papelera', v_nombre)
            WHEN 1 THEN format('Sección «%s» enviada a la papelera con su producto', v_nombre)
            ELSE format('Sección «%s» enviada a la papelera con sus %s productos', v_nombre, v_items) END,
        'data', ecommerce.fn_grupos_productos_json(p_id));
END;
$function$;

-- fn_producto_secciones_json  →  fn_grupos_productos_json
DROP FUNCTION IF EXISTS ecommerce.fn_producto_secciones_json(p_id bigint);
CREATE OR REPLACE FUNCTION ecommerce.fn_grupos_productos_json(p_id bigint)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
AS $function$
    SELECT jsonb_build_object(
        'id',         s.id,
        'nombre',     s.nombre,
        'orden',      s.orden,
        'activo',     s.activo,
        'desde',      to_char(s.desde, 'YYYY-MM-DD"T"HH24:MI'),
        'hasta',      to_char(s.hasta, 'YYYY-MM-DD"T"HH24:MI'),
        -- Encendida Y en fechas: es lo que decide si el cliente la vería
        'visible',    s.activo AND ecommerce.fn_vigente(s.desde, s.hasta),
        'productos',  (SELECT count(*)
                         FROM ecommerce.grupos_productos_items i
                         JOIN inventarios.productos p ON p.id = i.producto_id
                        WHERE i.grupo_id = s.id AND p.deleted_at IS NULL),
        'deleted_at', to_char(s.deleted_at, 'YYYY-MM-DD HH24:MI:SS'),
        'deleted_by', s.deleted_by,
        'created_by', s.created_by,
        'updated_by', s.updated_by,
        'created_at', to_char(s.created_at, 'YYYY-MM-DD HH24:MI:SS'),
        'updated_at', to_char(s.updated_at, 'YYYY-MM-DD HH24:MI:SS')
    )
      FROM ecommerce.grupos_productos s
     WHERE s.id = p_id;
$function$;

-- fn_producto_secciones_listar  →  fn_grupos_productos_listar
DROP FUNCTION IF EXISTS ecommerce.fn_producto_secciones_listar();
CREATE OR REPLACE FUNCTION ecommerce.fn_grupos_productos_listar()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
AS $function$
    SELECT jsonb_build_object('success', true, 'message', 'Grupos de productos',
        'data', COALESCE((
            SELECT jsonb_agg(ecommerce.fn_grupos_productos_json(s.id) ORDER BY s.orden, s.id)
              FROM ecommerce.grupos_productos s
             WHERE s.deleted_at IS NULL), '[]'::jsonb));
$function$;

-- fn_producto_secciones_modificar  →  fn_grupos_productos_modificar
DROP FUNCTION IF EXISTS ecommerce.fn_producto_secciones_modificar(p_id bigint, p_nombre character varying, p_desde timestamp with time zone, p_hasta timestamp with time zone, p_usuario_id bigint, p_usuario_login character varying, p_usuario_nombre character varying, p_ip_address inet, p_user_agent text, p_request_id uuid);
CREATE OR REPLACE FUNCTION ecommerce.fn_grupos_productos_modificar(p_id bigint, p_nombre character varying, p_desde timestamp with time zone DEFAULT NULL::timestamp with time zone, p_hasta timestamp with time zone DEFAULT NULL::timestamp with time zone, p_usuario_id bigint DEFAULT NULL::bigint, p_usuario_login character varying DEFAULT NULL::character varying, p_usuario_nombre character varying DEFAULT NULL::character varying, p_ip_address inet DEFAULT NULL::inet, p_user_agent text DEFAULT NULL::text, p_request_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'ecommerce', 'auditoria'
AS $function$
BEGIN
    PERFORM ecommerce.fn_contexto_auditoria('ecommerce.grupos_productos',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    IF NOT EXISTS (SELECT 1 FROM ecommerce.grupos_productos
                    WHERE id = p_id AND deleted_at IS NULL) THEN
        RAISE EXCEPTION 'El grupo no existe' USING ERRCODE = 'P0013';
    END IF;

    PERFORM ecommerce.fn_grupos_productos_validar(p_id, p_nombre, p_desde, p_hasta);

    UPDATE ecommerce.grupos_productos
       SET nombre = btrim(p_nombre), desde = p_desde, hasta = p_hasta
     WHERE id = p_id;

    UPDATE ecommerce.inicio_secciones
       SET nombre = btrim(p_nombre)
     WHERE grupo_productos_id = p_id AND nombre IS DISTINCT FROM btrim(p_nombre);

    RETURN jsonb_build_object('success', true, 'message', 'Sección actualizada',
        'data', ecommerce.fn_grupos_productos_json(p_id));
END;
$function$;

-- fn_producto_secciones_ordenar  →  fn_grupos_productos_ordenar
DROP FUNCTION IF EXISTS ecommerce.fn_producto_secciones_ordenar(p_ids jsonb, p_usuario_id bigint, p_usuario_login character varying, p_usuario_nombre character varying, p_ip_address inet, p_user_agent text, p_request_id uuid);
CREATE OR REPLACE FUNCTION ecommerce.fn_grupos_productos_ordenar(p_ids jsonb, p_usuario_id bigint DEFAULT NULL::bigint, p_usuario_login character varying DEFAULT NULL::character varying, p_usuario_nombre character varying DEFAULT NULL::character varying, p_ip_address inet DEFAULT NULL::inet, p_user_agent text DEFAULT NULL::text, p_request_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'ecommerce', 'auditoria'
AS $function$
DECLARE
    v_cuantas integer;
BEGIN
    PERFORM ecommerce.fn_contexto_auditoria('ecommerce.grupos_productos',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    IF jsonb_typeof(p_ids) <> 'array' THEN
        RAISE EXCEPTION 'Se esperaba la lista de grupos en el orden nuevo' USING ERRCODE = 'P0015';
    END IF;

    -- El orden es la POSICIÓN en la lista que llega, no un número del cliente:
    -- así no hay huecos ni empates aunque se arrastre varias veces.
    UPDATE ecommerce.grupos_productos s
       SET orden = t.posicion
      FROM (SELECT valor::bigint AS id, ordinalidad::integer AS posicion
              FROM jsonb_array_elements_text(p_ids) WITH ORDINALITY AS x(valor, ordinalidad)) t
     WHERE s.id = t.id AND s.deleted_at IS NULL;
    GET DIAGNOSTICS v_cuantas = ROW_COUNT;

    RETURN jsonb_build_object('success', true,
        'message', CASE v_cuantas WHEN 1 THEN 'Sección movida'
                                  ELSE format('%s grupos reordenados', v_cuantas) END,
        'data', (ecommerce.fn_grupos_productos_listar() -> 'data'));
END;
$function$;

-- fn_producto_secciones_papelera_listar  →  fn_grupos_productos_papelera_listar
DROP FUNCTION IF EXISTS ecommerce.fn_producto_secciones_papelera_listar();
CREATE OR REPLACE FUNCTION ecommerce.fn_grupos_productos_papelera_listar()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
AS $function$
    SELECT jsonb_build_object('success', true, 'message', 'Papelera de grupos',
        'data', COALESCE((
            SELECT jsonb_agg(ecommerce.fn_grupos_productos_json(s.id) ORDER BY s.deleted_at DESC)
              FROM ecommerce.grupos_productos s
             WHERE s.deleted_at IS NOT NULL), '[]'::jsonb));
$function$;

-- fn_producto_secciones_restaurar  →  fn_grupos_productos_restaurar
DROP FUNCTION IF EXISTS ecommerce.fn_producto_secciones_restaurar(p_id bigint, p_usuario_id bigint, p_usuario_login character varying, p_usuario_nombre character varying, p_ip_address inet, p_user_agent text, p_request_id uuid);
CREATE OR REPLACE FUNCTION ecommerce.fn_grupos_productos_restaurar(p_id bigint, p_usuario_id bigint DEFAULT NULL::bigint, p_usuario_login character varying DEFAULT NULL::character varying, p_usuario_nombre character varying DEFAULT NULL::character varying, p_ip_address inet DEFAULT NULL::inet, p_user_agent text DEFAULT NULL::text, p_request_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'ecommerce', 'auditoria'
AS $function$
DECLARE
    v_nombre text;
    v_fecha  timestamptz;
BEGIN
    PERFORM ecommerce.fn_contexto_auditoria('ecommerce.grupos_productos',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    SELECT nombre, deleted_at INTO v_nombre, v_fecha
      FROM ecommerce.grupos_productos WHERE id = p_id;
    IF NOT FOUND OR v_fecha IS NULL THEN
        RAISE EXCEPTION 'Ese grupo no está en la papelera' USING ERRCODE = 'P0019';
    END IF;

    -- Mientras estaba en la papelera pudieron crear otra con el mismo nombre
    PERFORM ecommerce.fn_grupos_productos_validar(p_id, v_nombre);

    UPDATE ecommerce.grupos_productos
       SET deleted_at = NULL, deleted_by = NULL WHERE id = p_id;

    RETURN jsonb_build_object('success', true,
        'message', format('Sección «%s» restaurada', v_nombre),
        'data', ecommerce.fn_grupos_productos_json(p_id));
END;
$function$;

-- fn_producto_secciones_validar  →  fn_grupos_productos_validar
DROP FUNCTION IF EXISTS ecommerce.fn_producto_secciones_validar(p_id bigint, p_nombre character varying, p_desde timestamp with time zone, p_hasta timestamp with time zone);
CREATE OR REPLACE FUNCTION ecommerce.fn_grupos_productos_validar(p_id bigint, p_nombre character varying, p_desde timestamp with time zone DEFAULT NULL::timestamp with time zone, p_hasta timestamp with time zone DEFAULT NULL::timestamp with time zone)
 RETURNS void
 LANGUAGE plpgsql
 STABLE
AS $function$
BEGIN
    IF p_nombre IS NULL OR length(btrim(p_nombre)) < 2 THEN
        RAISE EXCEPTION 'El nombre del grupo es obligatorio (mínimo 2 caracteres)'
            USING ERRCODE = 'P0001';
    END IF;
    IF length(btrim(p_nombre)) > 80 THEN
        RAISE EXCEPTION 'El nombre del grupo no puede pasar de 80 caracteres'
            USING ERRCODE = 'P0015';
    END IF;
    -- Sin tildes ni mayúsculas: «Más vendidos» y «mas vendidos» son la misma,
    -- y dos grupos con el mismo nombre no se distinguen en la lista.
    IF EXISTS (SELECT 1 FROM ecommerce.grupos_productos
                WHERE ecommerce.fn_normalizar_nombre(nombre) = ecommerce.fn_normalizar_nombre(p_nombre)
                  AND deleted_at IS NULL
                  AND (p_id IS NULL OR id <> p_id)) THEN
        RAISE EXCEPTION 'Ya existe un grupo llamado «%»', btrim(p_nombre)
            USING ERRCODE = 'P0006';
    END IF;
    IF p_desde IS NOT NULL AND p_hasta IS NOT NULL AND p_hasta < p_desde THEN
        RAISE EXCEPTION 'La fecha «hasta» no puede ser anterior a la fecha «desde»'
            USING ERRCODE = 'P0015';
    END IF;
END;
$function$;

-- fn_resumen (se queda con su nombre: no es del grupo, lo usa)
DROP FUNCTION IF EXISTS ecommerce.fn_resumen();
CREATE OR REPLACE FUNCTION ecommerce.fn_resumen()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
AS $function$
DECLARE
    v jsonb := '{}'::jsonb;
    n bigint;
    m bigint;
BEGIN
    -- ---------- Lo ya migrado ----------
    SELECT count(*) FILTER (WHERE deleted_at IS NULL),
           count(*) FILTER (WHERE deleted_at IS NULL AND NOT activo)
      INTO n, m FROM ecommerce.paginas_informativas;
    v := v || jsonb_build_object('paginas', jsonb_build_object('total', n, 'ocultas', m));

    SELECT count(*) FILTER (WHERE deleted_at IS NULL),
           count(*) FILTER (WHERE deleted_at IS NULL AND NOT activo)
      INTO n, m FROM ecommerce.encabezado_enlaces;
    v := v || jsonb_build_object('encabezado', jsonb_build_object('enlaces', n, 'ocultos', m));

    SELECT count(*) FILTER (WHERE deleted_at IS NULL) INTO n FROM ecommerce.pie_columnas;
    SELECT count(*) FILTER (WHERE deleted_at IS NULL) INTO m FROM ecommerce.pie_enlaces;
    v := v || jsonb_build_object('pie', jsonb_build_object('columnas', n, 'enlaces', m));

    SELECT count(*) FILTER (WHERE estado = 'visible'), count(*)
      INTO n, m FROM ecommerce.fn_categorias_web_estado();
    v := v || jsonb_build_object('categorias', jsonb_build_object('visibles', n, 'total', m));

    SELECT count(*) INTO n FROM ecommerce.galerias;
    SELECT count(*) FILTER (WHERE deleted_at IS NULL) INTO m FROM ecommerce.galerias_imagenes;
    v := v || jsonb_build_object('galerias', jsonb_build_object('galerias', n, 'imagenes', m));

    SELECT count(*) FILTER (WHERE activo), count(*)
      INTO n, m FROM ecommerce.inicio_secciones
     WHERE ecommerce.fn_inicio_seccion_viva(grupo_productos_id);
    v := v || jsonb_build_object('inicio', jsonb_build_object('visibles', n, 'total', m));

    -- ---------- Lo que todavía lee de las tablas viejas ----------
    -- Cuando se migre cada una, esta parte se cambia por la nueva. Mientras
    -- tanto, `to_regclass` evita que la portada entera reviente.
    IF to_regclass('ecommerce.sucursal') IS NOT NULL THEN
        EXECUTE 'SELECT count(*) FILTER (WHERE suc_eliminado_en IS NULL) FROM ecommerce.sucursal' INTO n;
        EXECUTE 'SELECT count(*) FILTER (WHERE sci_eliminado_en IS NULL) FROM ecommerce.sucursal_ciudad' INTO m;
        v := v || jsonb_build_object('sucursales', jsonb_build_object('tiendas', n, 'ciudades', m));
    END IF;

    IF to_regclass('ecommerce.pagina_marca') IS NOT NULL THEN
        EXECUTE 'SELECT count(*) FILTER (WHERE pma_eliminado_en IS NULL) FROM ecommerce.pagina_marca' INTO n;
        v := v || jsonb_build_object('paginas_marca', jsonb_build_object('paginas', n));
    END IF;

    IF to_regclass('ecommerce.franjas_detalle') IS NOT NULL THEN
        EXECUTE 'SELECT count(*) FILTER (WHERE fde_eliminado_en IS NULL) FROM ecommerce.franjas_detalle' INTO n;
        v := v || jsonb_build_object('franjas', jsonb_build_object('franjas', n));
    END IF;

    IF to_regclass('ecommerce.bloque_producto') IS NOT NULL THEN
        EXECUTE 'SELECT count(*) FILTER (WHERE bpr_eliminado_en IS NULL) FROM ecommerce.bloque_producto' INTO n;
        v := v || jsonb_build_object('bloques', jsonb_build_object('bloques', n));
    END IF;

    -- El catálogo sale de inventarios, que es de otro módulo
    SELECT count(*) FILTER (WHERE deleted_at IS NULL) INTO n FROM inventarios.productos;
    SELECT count(*) FILTER (WHERE deleted_at IS NULL) INTO m FROM inventarios.marcas;
    v := v || jsonb_build_object('productos', jsonb_build_object('productos', n),
                                 'marcas_tienda', jsonb_build_object('marcas', m));

    v := v || jsonb_build_object('grupos_productos', jsonb_build_object(
            'grupos', (SELECT count(*) FROM ecommerce.grupos_productos
                             WHERE deleted_at IS NULL),
            'productos',  (SELECT count(*) FROM ecommerce.grupos_productos_items i
                             JOIN ecommerce.grupos_productos s ON s.id = i.grupo_id
                             JOIN inventarios.productos p ON p.id = i.producto_id
                            WHERE s.deleted_at IS NULL AND p.deleted_at IS NULL)));
    RETURN jsonb_build_object('success', true, 'message', 'Resumen de la página web', 'data', v);
END;
$function$;

-- fn_tienda_productos (se queda con su nombre: no es del grupo, lo usa)
DROP FUNCTION IF EXISTS ecommerce.fn_tienda_productos(p_filtros jsonb);
CREATE OR REPLACE FUNCTION ecommerce.fn_tienda_productos(p_filtros jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
AS $function$
WITH RECURSIVE
param AS (
    SELECT NULLIF(btrim(COALESCE(p_filtros ->> 'marca', '')), '')::bigint            AS marca,
           -- La lista de productos que alguien armó a mano en el CRM
           -- (ecommerce.grupos_productos). Sin esto, el catálogo entero
           NULLIF(btrim(COALESCE(p_filtros ->> 'escaparate', '')), '')::bigint        AS escaparate,
           COALESCE(NULLIF(btrim(COALESCE(p_filtros ->> 'sort', '')), ''), 'recent') AS orden,
           NULLIF(btrim(COALESCE(p_filtros ->> 'price_min', '')), '')::numeric       AS precio_min,
           NULLIF(btrim(COALESCE(p_filtros ->> 'price_max', '')), '')::numeric       AS precio_max,
           GREATEST(1, COALESCE(NULLIF(btrim(COALESCE(p_filtros ->> 'page', '')), '')::int, 1))
                                                                                     AS pagina,
           -- EL TECHO SON 120 Y NO 48: /shop pide 12, 24 o 48, pero un
           -- escaparate del inicio acumula («Ver más productos» añade debajo
           -- en vez de reemplazar), así que al volver a una dirección con
           -- diez páginas pulsadas pide las diez de una vez. Más allá de 120
           -- se recorta: una sola petición no puede traer el catálogo entero
           LEAST(120, GREATEST(1,
               COALESCE(NULLIF(btrim(COALESCE(p_filtros ->> 'per_page', '')), '')::int, 12)))
                                                                                     AS por_pagina
),
-- Qué parte de los productos que se están mirando tiene que llevar lleno un
-- filtro para que se ofrezca, y cuántos filtros se ofrecen como mucho
techos AS (
    SELECT 0.25::numeric AS parte_minima,
           -- Doce de la ficha. En un escaparate van además la categoría, la
           -- marca y el precio, que son de la tienda y no de la ficha: se
           -- SUMAN al techo en vez de quitarle el sitio a tres características
           12 + CASE WHEN (SELECT escaparate FROM param) IS NULL THEN 0 ELSE 3 END
                                AS cuantos_filtros,
           20                   AS valores_maximos
),
-- Las categorías pedidas, con toda su rama debajo: pedir «Tecnología» tiene
-- que traer lo que está en «Laptops»
pedidas AS (
    SELECT COALESCE(array_agg(DISTINCT r.id), ARRAY[]::bigint[]) AS ramas
      FROM regexp_split_to_table(COALESCE(p_filtros ->> 'categoria', ''), ',') AS x(uno)
      CROSS JOIN LATERAL unnest(ecommerce.fn_categorias_rama(NULLIF(btrim(x.uno), '')::bigint)) AS r(id)
     WHERE NULLIF(btrim(x.uno), '') IS NOT NULL
),
-- Lo marcado y lo pedido en las barras, ya desarmado por el controlador:
-- {"listas": {"color": ["Negro","Rojo"]}, "rangos": {"cilindraje": {"desde": 150}}}
filtros_lista AS (
    SELECT k.clave,
           ARRAY(SELECT btrim(v) FROM jsonb_array_elements_text(k.valores) AS v
                  WHERE NULLIF(btrim(v), '') IS NOT NULL) AS valores
      FROM jsonb_each(COALESCE(p_filtros -> 'facetas' -> 'listas', '{}'::jsonb)) AS k(clave, valores)
     WHERE jsonb_typeof(k.valores) = 'array'
),
filtros_lista_ok AS (SELECT * FROM filtros_lista WHERE cardinality(valores) > 0),
filtros_rango AS (
    SELECT k.clave,
           NULLIF(btrim(COALESCE(k.caja ->> 'desde', '')), '')::numeric AS desde,
           NULLIF(btrim(COALESCE(k.caja ->> 'hasta', '')), '')::numeric AS hasta
      FROM jsonb_each(COALESCE(p_filtros -> 'facetas' -> 'rangos', '{}'::jsonb)) AS k(clave, caja)
     WHERE jsonb_typeof(k.caja) = 'object'
),
filtros_rango_ok AS (SELECT * FROM filtros_rango WHERE desde IS NOT NULL OR hasta IS NOT NULL),
visibles AS (
    SELECT e.id, e.nombre FROM ecommerce.fn_categorias_web_estado() e WHERE e.estado = 'visible'
),
-- Cada categoría con la suya y todas las de encima: sirve para contar la rama
sube AS (
    SELECT c.id AS hoja, c.id AS nodo, c.padre_id
      FROM inventarios.categorias c
     WHERE c.deleted_at IS NULL
    UNION ALL
    SELECT s.hoja, pa.id, pa.padre_id
      FROM sube s
      JOIN inventarios.categorias pa ON pa.id = s.padre_id AND pa.deleted_at IS NULL
),
-- ===== Un escaparate: la lista de productos que alguien armó a mano =====
--
-- Hasta el 09/11/2026 esas listas viajaban ENTERAS dentro de la página
-- (fn_grupo_productos_publico) y el navegador las filtraba, las contaba y las
-- iba soltando de a doce: noventa y un productos con su ficha entera eran 63 KB
-- de JSON para enseñar doce tarjetas. Ahora un escaparate es UN FILTRO MÁS del
-- catálogo, con la misma paginación, los mismos filtros y las mismas cuentas
-- que /shop.
--
-- SU ORDEN ES EL QUE SE ELIGIÓ EN EL CRM, no el del catálogo: quien arma una
-- campaña pone primero lo que quiere que se vea primero. Pedir un orden por
-- precio sigue mandando sobre él.
--
-- Y NO SE LE EXIGE QUE LA CATEGORÍA ESTÉ VISIBLE EN LA TIENDA, que es la única
-- diferencia con el catálogo: son productos elegidos uno a uno, y el árbol de
-- categorías es para navegar. Esconder una categoría del menú no puede
-- vaciarle la campaña a quien la armó.
en_escaparate AS (
    SELECT it.producto_id, min(it.orden) AS orden
      FROM ecommerce.grupos_productos_items it
     WHERE it.grupo_id = (SELECT escaparate FROM param)
     GROUP BY it.producto_id
),
base AS (
    SELECT pr.id, pr.codigo, pr.nombre, pr.precio, pr.precio_anterior, pr.categoria_id, pr.marca_id, pr.created_at,
           pr.precio_tarjeta, pr.cuota_credito_directo,
           ee.orden                                                   AS orden_escaparate,
           NULLIF(btrim(COALESCE(m.logo, '')), '')                    AS marca_logo,
           COALESCE(NULLIF(btrim(m.nombre), ''), '')                  AS marca,
           COALESCE(NULLIF(btrim(cw.nombre_web), ''), cat.nombre, '') AS categoria
      FROM inventarios.productos pr
      -- LEFT y no JOIN: con un escaparate pedido manda su lista, no el árbol
      LEFT JOIN visibles v                  ON v.id  = pr.categoria_id
      LEFT JOIN en_escaparate ee            ON ee.producto_id = pr.id
      LEFT JOIN inventarios.marcas m        ON m.id   = pr.marca_id     AND m.deleted_at IS NULL
      LEFT JOIN inventarios.categorias cat  ON cat.id = pr.categoria_id AND cat.deleted_at IS NULL
      LEFT JOIN ecommerce.categorias_web cw ON cw.categoria_id = pr.categoria_id
     WHERE pr.deleted_at IS NULL
       AND pr.activo
       AND pr.en_paginaweb
       AND CASE WHEN (SELECT escaparate FROM param) IS NULL
                THEN v.id IS NOT NULL
                ELSE ee.orden IS NOT NULL END
),
-- ===== La ficha de cada producto, ya lista para filtrar =====
--
-- EL NOMBRE SALE DEL DICCIONARIO, no de la columna del producto: esa es una
-- foto de cómo se llamaba la característica el día que se rellenó, y si
-- después se renombró, agrupar por ella partiría el filtro en dos. Sólo
-- cuando no hay diccionario —una escrita a mano— se usa la foto.
--
-- SIN VALOR NO ES NADA: desde el 29/10/2026 una fila de caracteristicas_productos
-- significa «esta característica está en la lista de este producto, en esta
-- posición», y el valor puede estar vacío.
fichas_todas AS (
    SELECT c.producto_id,
           ecommerce.fn_clave_filtro(COALESCE(NULLIF(btrim(d.nombre), ''), btrim(c.nombre))) AS clave,
           COALESCE(NULLIF(btrim(d.nombre), ''), btrim(c.nombre))                            AS nombre,
           upper(COALESCE(NULLIF(btrim(d.tipo), ''), ''))                                    AS tipo,
           COALESCE(NULLIF(btrim(d.unidad), ''), '')                                         AS unidad,
           btrim(c.valor)                                                                    AS valor,
           ecommerce.fn_numero_de_texto(c.valor)                                             AS numero,
           c.orden, c.id
      FROM inventarios.caracteristicas_productos c
      JOIN base b ON b.id = c.producto_id
      LEFT JOIN inventarios.caracteristicas_nombres d ON d.id = c.nombre_id AND d.deleted_at IS NULL
     WHERE NULLIF(btrim(COALESCE(c.valor, '')), '') IS NOT NULL
       AND NULLIF(btrim(COALESCE(c.nombre, '')), '') IS NOT NULL
),
-- ===== Y LOS TRES DE LA TIENDA: categoría, marca y precio =====
--
-- SÓLO EN UN ESCAPARATE. En /shop esos tres tienen su propio sitio en el panel
-- de la izquierda —con el árbol de categorías, que un escaparate no tiene— y
-- ofrecerlos además como persiana sería tenerlos dos veces.
--
-- En un escaparate no hay panel: está todo en el cajón de los filtros, y ahí
-- la marca es una persiana de casillas como el color y el precio una barra como
-- el cilindraje. Entrando por aquí no hay que traducir nada: lo que se marca se
-- escribe en la dirección igual que lo demás («marca:Bajaj»), viaja igual y se
-- cuenta igual. Antes del 09/11/2026 esto lo armaba el navegador, y era la
-- razón por la que necesitaba todos los productos.
--
-- EL PRECIO NO TIENE TEXTO, sólo número: es el único filtro que no sale de la
-- ficha de nadie —todos los productos tienen precio— y se pide siempre con una
-- barra de desde–hasta. Y es EL QUE SE LEE EN LA TARJETA, el de tarjeta de
-- crédito: acotar por otro dejaría fuera productos que el visitante está viendo
-- dentro del rango.
fichas_tienda AS (
    SELECT b.id AS producto_id, t.clave, t.nombre, t.tipo, ''::text AS unidad,
           t.valor, t.numero,
           -- Antes que cualquier característica, y con id 0: si alguien llamó
           -- «Marca» a una característica, manda la de la tienda
           t.orden, 0::bigint AS id
      FROM base b
      CROSS JOIN LATERAL (VALUES
          ('categoria', 'Categoría', '',       NULLIF(btrim(b.categoria), ''), NULL::numeric, -3),
          ('marca',     'Marca',     '',       NULLIF(btrim(b.marca), ''),     NULL::numeric, -2),
          ('precio',    'Precio',    'NUMERO', NULL::text, COALESCE(b.precio_tarjeta, b.precio), -1)
      ) AS t(clave, nombre, tipo, valor, numero, orden)
     WHERE (SELECT escaparate FROM param) IS NOT NULL
       AND (t.valor IS NOT NULL OR t.numero IS NOT NULL)
),
-- Un producto con la misma característica dos veces —una del diccionario y
-- otra escrita a mano con el mismo nombre— contaría dos veces en su propio
-- filtro. Se queda con la primera de su ficha, que es la que se le enseña.
fichas AS (
    SELECT DISTINCT ON (producto_id, clave) *
      FROM (SELECT * FROM fichas_todas UNION ALL SELECT * FROM fichas_tienda) todas
     ORDER BY producto_id, clave, orden, id
),
-- ===== Qué filtros NO cumple cada producto =====
--
-- SIN EL DATO NO PASA: quien pide «hasta 30.000 km» no quiere ver las motos
-- que no dicen su kilometraje, igual que quien marca «Negro» no quiere las que
-- no dicen de qué color son. Es la misma regla que la sección del inicio.
--
-- SE MIRA DE UNA VEZ Y NO FILTRO A FILTRO: con un `NOT EXISTS` por cada filtro
-- pedido, la base recorría la ficha entera por cada producto y por cada filtro
-- —cuatro filtros sobre el catálogo eran dos millones de comparaciones y 110 ms
-- de nada—. Cruzando los productos con los filtros pedidos y pegando la ficha
-- UNA vez, el planificador lo resuelve con una sola pasada.
pedidos AS (
    SELECT 'lista'::text AS clase, clave, valores,       NULL::numeric AS desde, NULL::numeric AS hasta
      FROM filtros_lista_ok
    UNION ALL
    SELECT 'rango',              clave, NULL::text[],    desde,                  hasta
      FROM filtros_rango_ok
),
cumplidos AS (
    SELECT b.id, p.clave,
           bool_or(CASE WHEN p.clase = 'lista'
                        THEN f.valor = ANY (p.valores)
                        ELSE f.numero IS NOT NULL
                         AND (p.desde IS NULL OR f.numero >= p.desde)
                         AND (p.hasta IS NULL OR f.numero <= p.hasta)
                   END) AS cumple
      FROM base b
      CROSS JOIN pedidos p
      LEFT JOIN fichas f ON f.producto_id = b.id AND f.clave = p.clave
     GROUP BY b.id, p.clave
),
fallos AS (
    SELECT b.id,
           -- `c.clave IS NOT NULL` NO SOBRA: sin filtros pedidos no hay nada
           -- que cruzar y el LEFT JOIN deja una fila vacía por producto, que
           -- sin esto entra en el array como un NULL y deja TODO el catálogo
           -- fuera
           COALESCE(array_agg(c.clave) FILTER (WHERE c.clave IS NOT NULL
                                                 AND NOT COALESCE(c.cumple, false)),
                    ARRAY[]::text[]) AS claves_fallo
      FROM base b
      LEFT JOIN cumplidos c ON c.id = b.id
     GROUP BY b.id
),
-- Cada filtro por separado, para poder contar «con los demás menos el suyo»
marcados AS (
    SELECT b.*,
           fa.claves_fallo,
           (b.id IN (SELECT c.producto_id
                       FROM ecommerce.fn_tienda_casan(p_filtros ->> 'search') c)) AS pasa_texto,
           (cardinality((SELECT ramas FROM pedidas)) = 0
            OR b.categoria_id = ANY (SELECT unnest(p2.ramas) FROM pedidas p2))    AS pasa_categoria,
           ((SELECT marca FROM param) IS NULL
            OR b.marca_id = (SELECT marca FROM param))                            AS pasa_marca,
           (((SELECT precio_min FROM param) IS NULL OR b.precio >= (SELECT precio_min FROM param))
        AND ((SELECT precio_max FROM param) IS NULL OR b.precio <= (SELECT precio_max FROM param)))
                                                                                  AS pasa_precio
      FROM base b
      JOIN fallos fa ON fa.id = b.id
),
filtrados AS (
    SELECT * FROM marcados
     WHERE pasa_texto AND pasa_categoria AND pasa_marca AND pasa_precio
       AND cardinality(claves_fallo) = 0
),
-- Los productos de los que hablan los filtros por característica: los que
-- pasan lo demás —el texto, la categoría, la marca y el precio—, estén o no
-- dentro de lo marcado en las características
ambito AS (
    SELECT m.id, m.claves_fallo
      FROM marcados m
     WHERE m.pasa_texto AND m.pasa_categoria AND m.pasa_marca AND m.pasa_precio
),
cuenta AS (SELECT count(*)::int AS total FROM filtrados),
cuanto_ambito AS (SELECT count(*)::int AS total FROM ambito),
ultima AS (
    SELECT GREATEST(1, ceil((SELECT total FROM cuenta)::numeric
                            / (SELECT por_pagina FROM param))::int) AS n
),
pagina AS (SELECT LEAST((SELECT n FROM ultima), (SELECT pagina FROM param)) AS n),
lista AS (
    SELECT f.*, row_number() OVER (
               ORDER BY CASE WHEN (SELECT orden FROM param) = 'price_asc'  THEN f.precio END ASC  NULLS LAST,
                        CASE WHEN (SELECT orden FROM param) = 'price_desc' THEN f.precio END DESC NULLS LAST,
                        -- El de un escaparate es el que se arrastró en el CRM;
                        -- sin escaparate es NULL para todos y no pinta nada
                        f.orden_escaparate ASC NULLS LAST,
                        f.created_at DESC NULLS LAST, f.id DESC) AS puesto
      FROM filtrados f
),
pagina_lista AS (
    SELECT * FROM lista
     WHERE puesto >  ((SELECT n FROM pagina) - 1) * (SELECT por_pagina FROM param)
       AND puesto <=  (SELECT n FROM pagina)      * (SELECT por_pagina FROM param)
),
-- Las carátulas, sólo las de la página: la principal primero
fotos AS (
    SELECT i.producto_id,
           jsonb_agg(btrim(i.archivo) ORDER BY i.principal DESC, i.orden, i.id) AS imagenes
      FROM inventarios.productos_imagenes i
      JOIN pagina_lista pl ON pl.id = i.producto_id
     WHERE NULLIF(btrim(COALESCE(i.archivo, '')), '') IS NOT NULL
     GROUP BY i.producto_id
),
tarjetas AS (
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'pro_id',          pl.id,
               'codigo',          COALESCE(pl.codigo, ''),
               'nombre',          pl.nombre,
               'marca',           pl.marca,
               -- Nombre del fichero: la dirección la arma el controlador
               'marca_logo',      pl.marca_logo,
               'tpr_id',          pl.categoria_id,
               'categoria',       pl.categoria,
               -- Nombres de fichero: la dirección la arma el controlador
               'imagenes',        COALESCE(f.imagenes, '[]'::jsonb),
               'destacado',       false,
               'precio',          round(COALESCE(pl.precio, 0), 2),
               -- El de antes, para tacharlo; NULL = no está en oferta
               'precio_anterior', round(pl.precio_anterior, 2),
               -- Lo que cuesta con tarjeta de crédito, que es EL importe que
               -- enseña la tarjeta; NULL = el mismo que «precio»
               'precio_tarjeta',  round(pl.precio_tarjeta, 2),
               -- La cuota del crédito directo; NULL = no se ofrece y esa
               -- celda no se pinta
               'cuota_credito_directo', round(pl.cuota_credito_directo, 2),
               'stock',           1)
           ORDER BY pl.puesto), '[]'::jsonb) AS lista
      FROM pagina_lista pl
      LEFT JOIN fotos f ON f.producto_id = pl.id
),
op_marcas AS (
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'mar_id', t.marca_id, 'nombre', t.marca, 'cantidad', t.cuantos)
           ORDER BY t.marca), '[]'::jsonb) AS lista
      FROM (SELECT m.marca_id, m.marca, count(*)::int AS cuantos
              FROM marcados m
             WHERE m.pasa_texto AND m.pasa_categoria AND m.pasa_precio
               AND cardinality(m.claves_fallo) = 0
               AND m.marca_id IS NOT NULL AND m.marca <> ''
             GROUP BY m.marca_id, m.marca) t
),
op_categorias AS (
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'tpr_id', t.nodo, 'nombre', t.nombre, 'cantidad', t.cuantos)
           ORDER BY t.nombre), '[]'::jsonb) AS lista
      FROM (SELECT s.nodo, v.nombre, count(*)::int AS cuantos
              FROM marcados m
              JOIN sube s     ON s.hoja = m.categoria_id
              JOIN visibles v ON v.id   = s.nodo
             WHERE m.pasa_texto AND m.pasa_marca AND m.pasa_precio
               AND cardinality(m.claves_fallo) = 0
             GROUP BY s.nodo, v.nombre) t
),
op_precio AS (
    SELECT CASE WHEN count(*) = 0 THEN NULL
                ELSE jsonb_build_object('min', round(min(m.precio), 2),
                                        'max', round(max(m.precio), 2)) END AS caja
      FROM marcados m
     WHERE m.pasa_texto AND m.pasa_categoria AND m.pasa_marca
       AND cardinality(m.claves_fallo) = 0
),
-- ===== Los filtros por característica =====
--
-- Qué hay en el ámbito y cuántos productos lo llevan lleno
nombres_faceta AS (
    SELECT f.clave,
           min(f.nombre)                               AS nombre,
           min(f.tipo) FILTER (WHERE f.tipo <> '')     AS tipo,
           min(f.unidad) FILTER (WHERE f.unidad <> '') AS unidad,
           count(*)::int                               AS llenos,
           -- Por el número cuando no hay texto: el precio no tiene valores que
           -- marcar, y contando sólo textos saldría con cero valores distintos
           -- y se caería del filtro de abajo
           count(DISTINCT COALESCE(f.valor, f.numero::text))::int AS distintos
      FROM fichas f
      JOIN ambito a ON a.id = f.producto_id
     GROUP BY f.clave
),
-- Los que se ofrecen: los que lleva lleno una buena parte de lo que se está
-- mirando, más los que YA están marcados —que no se pueden esconder, porque
-- entonces no habría forma de quitarlos—. Y como mucho, doce.
elegidas AS (
    SELECT n.*,
           (n.clave IN (SELECT clave FROM filtros_lista_ok
                        UNION SELECT clave FROM filtros_rango_ok)) AS marcada
      FROM nombres_faceta n
     WHERE n.distintos >= 2
       -- Una lista de doscientas casillas no acota nada; un NÚMERO con muchos
       -- valores sí sirve, porque se pinta como barra de desde–hasta
       AND (COALESCE(n.tipo, '') = 'NUMERO'
            OR n.distintos <= (SELECT valores_maximos FROM techos))
),
facetas_ok AS (
    SELECT * FROM elegidas e
     WHERE e.marcada
        OR e.llenos::numeric >= (SELECT parte_minima FROM techos)
                                * GREATEST(1, (SELECT total FROM cuanto_ambito))
     ORDER BY e.marcada DESC, e.llenos DESC, e.nombre
     LIMIT (SELECT cuantos_filtros FROM techos)
),
-- Todos los valores que existen, con cuántos quedarían CON LOS DEMÁS FILTROS
-- PUESTOS Y SIN EL SUYO. Los que dan cero salen apagados en la tienda, no se
-- esconden: esconderlos movería la lista bajo el dedo a cada clic.
valores_faceta AS (
    SELECT f.clave, f.valor,
           count(*) FILTER (WHERE a.claves_fallo <@ ARRAY[f.clave])::int AS cuantos
      FROM fichas f
      JOIN ambito a     ON a.id    = f.producto_id
      JOIN facetas_ok k ON k.clave = f.clave
     -- El precio no tiene: sólo números. Sin esto saldría una casilla vacía
     WHERE f.valor IS NOT NULL
     GROUP BY f.clave, f.valor
),
-- Y todos los números distintos, sin filtrar: con ellos decide la tienda si
-- esto se pinta con casillas, con una barra o con dos listas de años
numeros_faceta AS (
    SELECT f.clave, f.numero
      FROM fichas f
      JOIN ambito a     ON a.id    = f.producto_id
      JOIN facetas_ok k ON k.clave = f.clave
     WHERE f.numero IS NOT NULL
     GROUP BY f.clave, f.numero
),
cuentas_faceta AS (
    SELECT f.clave,
           count(*)      FILTER (WHERE a.claves_fallo <@ ARRAY[f.clave])::int AS cuantos,
           min(f.numero) FILTER (WHERE a.claves_fallo <@ ARRAY[f.clave])      AS minimo,
           max(f.numero) FILTER (WHERE a.claves_fallo <@ ARRAY[f.clave])      AS maximo
      FROM fichas f
      JOIN ambito a     ON a.id    = f.producto_id
      JOIN facetas_ok k ON k.clave = f.clave
     GROUP BY f.clave
),
op_facetas AS (
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'clave',   k.clave,
               'nombre',  k.nombre,
               -- Del diccionario del CRM, no de mirar el valor: «Canales»
               -- vale 2.0, 2.1 y 5.1 y parece un número, pero no existe el 2.5
               'tipo',    COALESCE(k.tipo, ''),
               'unidad',  COALESCE(k.unidad, ''),
               'cuantos', COALESCE(c.cuantos, 0),
               'min',     c.minimo,
               'max',     c.maximo,
               'valores', COALESCE(v.lista, '[]'::jsonb),
               'numeros', COALESCE(n.lista, '[]'::jsonb))
           ORDER BY k.llenos DESC, k.nombre), '[]'::jsonb) AS lista
      FROM facetas_ok k
      LEFT JOIN cuentas_faceta c ON c.clave = k.clave
      LEFT JOIN LATERAL (
          SELECT jsonb_agg(jsonb_build_object('valor', vf.valor, 'cuantos', vf.cuantos)
                 ORDER BY vf.valor) AS lista
            FROM valores_faceta vf WHERE vf.clave = k.clave) v ON true
      LEFT JOIN LATERAL (
          SELECT jsonb_agg(nf.numero ORDER BY nf.numero) AS lista
            FROM numeros_faceta nf WHERE nf.clave = k.clave) n ON true
)
SELECT jsonb_build_object(
           'productos',     (SELECT lista FROM tarjetas),
           'total',         (SELECT total FROM cuenta),
           'pagina',        (SELECT n FROM pagina),
           'por_pagina',    (SELECT por_pagina FROM param),
           'ultima_pagina', (SELECT n FROM ultima),
           'opciones', jsonb_build_object(
               'categorias', (SELECT lista FROM op_categorias),
               'marcas',     (SELECT lista FROM op_marcas),
               'precio',     (SELECT caja  FROM op_precio),
               -- Los filtros por característica, contados aquí: la tienda sólo
               -- los pinta
               'facetas',    (SELECT lista FROM op_facetas)));
$function$;

-- ----------------------------------------------------------------------------
-- 3. LOS DATOS QUE LLEVAN LA PALABRA DENTRO
-- ----------------------------------------------------------------------------
-- La clave de una sección de cuerpo que enseña un grupo la fabrica el servidor
-- («seccion_7»). Ahora se fabrica «grupo_7», así que las que hay se cambian: si
-- no, las viejas y las nuevas se llamarían distinto haciendo lo mismo.
UPDATE ecommerce.inicio_secciones
   SET clave = 'grupo_' || grupo_productos_id
 WHERE grupo_productos_id IS NOT NULL
   AND clave LIKE 'seccion\_%';

-- Y la ruta de la pantalla en el menú del CRM
UPDATE seguridad.menus
   SET url = 'ecommerce/grupo-productos'
 WHERE url = 'ecommerce/producto-por-seccion';

COMMIT;

-- ============================================================================
-- COMPROBACIÓN — no escribe nada
-- ============================================================================
DO $comprobar$
DECLARE
    v_falta text[] := '{}';
    v_n     integer;
    v_json  jsonb;
BEGIN
    -- Nada con el nombre viejo
    SELECT count(*) INTO v_n FROM information_schema.tables
     WHERE table_schema = 'ecommerce' AND table_name LIKE 'producto_seccion%';
    IF v_n > 0 THEN v_falta := array_append(v_falta, 'quedan tablas con el nombre viejo'); END IF;

    SELECT count(*) INTO v_n FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'ecommerce' AND p.proname LIKE '%producto_seccion%';
    IF v_n > 0 THEN v_falta := array_append(v_falta, 'quedan funciones con el nombre viejo'); END IF;

    SELECT count(*) INTO v_n FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'ecommerce' AND p.prosrc LIKE '%producto_seccion%';
    IF v_n > 0 THEN v_falta := array_append(v_falta,
        'hay funciones que todavía nombran producto_seccion por dentro'); END IF;

    SELECT count(*) INTO v_n FROM information_schema.columns
     WHERE table_schema = 'ecommerce' AND column_name = 'producto_seccion_id';
    IF v_n > 0 THEN v_falta := array_append(v_falta, 'queda la columna vieja'); END IF;

    -- Y las nuevas están y responden
    IF to_regclass('ecommerce.grupos_productos') IS NULL
       OR to_regclass('ecommerce.grupos_productos_items') IS NULL THEN
        v_falta := array_append(v_falta, 'no están las tablas nuevas');
    END IF;

    v_json := ecommerce.fn_grupos_productos_listar();
    IF (v_json -> 'success') <> 'true'::jsonb THEN
        v_falta := array_append(v_falta, 'la lista de grupos no responde');
    END IF;

    -- El contenido de uno de verdad, si hay alguno
    IF EXISTS (SELECT 1 FROM ecommerce.grupos_productos WHERE deleted_at IS NULL) THEN
        v_json := ecommerce.fn_grupo_productos_contenido(
            (SELECT id FROM ecommerce.grupos_productos WHERE deleted_at IS NULL ORDER BY id LIMIT 1));
        IF (v_json -> 'success') <> 'true'::jsonb THEN
            v_falta := array_append(v_falta, 'el contenido de un grupo no responde');
        END IF;
    END IF;

    -- Lo que lee la tienda sigue armándose: el cuerpo público y el inicio
    PERFORM ecommerce.fn_cuerpo_publico(NULL);
    PERFORM ecommerce.fn_inicio_listar();
    PERFORM ecommerce.fn_resumen();
    PERFORM ecommerce.fn_secciones_publicas();

    -- La fuente de una sección de cuerpo apunta a la pantalla nueva
    -- Con los tres argumentos: hay dos con este nombre y con dos no se sabe
    -- cuál se quiere
    v_json := ecommerce.fn_inicio_fuente('lo que sea'::text, 7::bigint, NULL::text);
    IF (v_json ->> 'pantalla') <> 'grupo-productos' OR (v_json ->> 'grupo_id') <> '7' THEN
        v_falta := array_append(v_falta, 'la fuente no apunta al grupo: ' || v_json::text);
    END IF;

    -- Y ninguna clave vieja
    SELECT count(*) INTO v_n FROM ecommerce.inicio_secciones
     WHERE clave LIKE 'seccion\_%';
    IF v_n > 0 THEN v_falta := array_append(v_falta, 'quedan ' || v_n || ' claves «seccion_N»'); END IF;

    SELECT count(*) INTO v_n FROM seguridad.menus
     WHERE url = 'ecommerce/producto-por-seccion';
    IF v_n > 0 THEN v_falta := array_append(v_falta, 'el menú sigue apuntando a la ruta vieja'); END IF;

    IF array_length(v_falta, 1) > 0 THEN
        RAISE EXCEPTION 'El cambio de nombre no quedó completo: %', array_to_string(v_falta, '; ');
    END IF;

    RAISE NOTICE 'Las secciones de productos son ya grupos de productos';
END;
$comprobar$;
