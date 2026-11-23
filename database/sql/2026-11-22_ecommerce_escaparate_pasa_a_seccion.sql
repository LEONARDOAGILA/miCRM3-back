-- ============================================================================
-- «ESCAPARATE» PASA A LLAMARSE «SECCIÓN»
-- ============================================================================
-- Es un cambio de nombre, no de comportamiento: lo que se enseñaba como
-- «escaparate» —un grupo de productos puesto en una página— se llama ahora
-- SECCIÓN, que es como lo llama quien administra la tienda.
--
-- POR DENTRO NO SE QUEDA EN «seccion» A SECAS, y ésa es la única decisión que
-- hay aquí: en este esquema una sección es CUALQUIER bloque de una página
-- —`inicio_secciones`, `fn_inicio_seccion_guardar`— y lo que se renombra es
-- una CLASE de sección. Llamarla igual que la general dejaría dos cosas
-- distintas con el mismo nombre en el mismo fichero. Por eso:
--
--   fn_inicio_escaparate_poner        ->  fn_inicio_seccion_productos_poner
--   fn_inicio_escaparate_quitar       ->  fn_inicio_seccion_productos_quitar
--   fn_inicio_escaparates_disponibles ->  fn_inicio_secciones_productos_disponibles
--
-- Y LAS CLAVES QUE VIAJAN ENTRE CAPAS, que son las que hay que cambiar a la
-- vez en los tres sitios o algo deja de guardarse sin avisar:
--
--   'escaparate_id'  (lo que manda el CRM al crear una página)  ->  'seccion_productos_id'
--   'escaparate'     (el filtro del catálogo, de ?escaparate=)  ->  'seccion_productos'
--   'escaparate'     (lo que la tienda lee de cada sección)     ->  'seccion_productos'
--
-- NO HAY DATOS QUE MIGRAR: ninguna columna ni ninguna fila guarda esa
-- palabra; las tres claves son de ida y vuelta, no se almacenan. Lo único
-- que queda con el nombre viejo es lo que esté en la caché pública, y por eso
-- al final se tira.
--
-- Las funciones salen tal cual de la base (pg_get_functiondef) con la palabra
-- cambiada: no se reescribe el cuerpo de ninguna.
--
-- ----------------------------------------------------------------------------
-- SE EJECUTA A MANO. Para ensayar: comentar el COMMIT y poner un ROLLBACK al
-- final del todo.
--
--   psql -U postgres -d crm3 -f 2026-11-22_ecommerce_escaparate_pasa_a_seccion.sql
-- ============================================================================

BEGIN;

-- ----------------------------------------------------------------------------
-- 1. LAS FUNCIONES, CON LA PALABRA CAMBIADA
-- ----------------------------------------------------------------------------

-- ---------- fn_cuerpo_catalogo_sincronizar ----------
CREATE OR REPLACE FUNCTION ecommerce.fn_cuerpo_catalogo_sincronizar(p_cuerpo_id bigint, p_quiere boolean)
 RETURNS void
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_orden integer;
BEGIN
    IF COALESCE(p_quiere, false) THEN
        -- Al final de lo que haya: es la parte larga de la página y encima de
        -- las secciones de productos los dejaría sin ver.
        SELECT COALESCE(max(orden), 0) + 1 INTO v_orden
          FROM ecommerce.inicio_secciones WHERE cuerpo_id = p_cuerpo_id;

        INSERT INTO ecommerce.inicio_secciones (cuerpo_id, clave, nombre, orden, activo)
        VALUES (p_cuerpo_id, 'catalogo', 'Catálogo', v_orden, true)
        ON CONFLICT (cuerpo_id, clave) DO UPDATE SET activo = true;
    ELSE
        -- SE APAGA, NO SE BORRA: borrarla se llevaría los colores que se le
        -- hubieran puesto, y volver a encender el catálogo los daría por
        -- perdidos sin decir nada.
        UPDATE ecommerce.inicio_secciones
           SET activo = false
         WHERE cuerpo_id = p_cuerpo_id AND clave = 'catalogo';
    END IF;
END;
$function$;

-- ---------- fn_cuerpo_publico ----------
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
          -- ===== Los productos de una sección de productos =====
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
                                 -- productos de la sección: los de la ficha y
                                 -- los tres de la tienda
                                 'facetas',       p.pagina -> 'opciones' -> 'facetas')
                        FROM (SELECT ecommerce.fn_tienda_productos(jsonb_build_object(
                                         'seccion_productos', v.grupo_productos_id,
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

-- ---------- fn_cuerpo_sembrar ----------
CREATE OR REPLACE FUNCTION ecommerce.fn_cuerpo_sembrar(p_cuerpo_id bigint)
 RETURNS integer
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_fila    record;
    v_galeria bigint;
    v_cuantas integer := 0;
BEGIN
    -- El orden se vuelve a numerar 1..n y no se copia tal cual: el del
    -- principal tiene huecos, porque entre sus secciones de fábrica hay
    -- secciones de productos que aquí no se copian. Con huecos, lo siguiente que se
    -- añada cae en un número mayor que la cuenta de filas y cuesta leerlo.
    FOR v_fila IN
        SELECT s.clave, s.nombre, s.galeria_id,
               row_number() OVER (ORDER BY s.orden, s.id) AS orden
          FROM ecommerce.inicio_secciones s
         WHERE s.cuerpo_id = ecommerce.fn_cuerpo_principal_id()
           AND ecommerce.fn_inicio_seccion_de_fabrica(s.clave)
         ORDER BY s.orden, s.id
    LOOP
        v_galeria := NULL;

        IF v_fila.galeria_id IS NOT NULL THEN
            v_galeria := nextval('ecommerce.galerias_id_seq');
            INSERT INTO ecommerce.galerias (id, clave, nombre, descripcion, tipo, maximo)
            SELECT v_galeria, 'inicio_banner_' || v_galeria, g.nombre, g.descripcion, g.tipo, g.maximo
              FROM ecommerce.galerias g WHERE g.id = v_fila.galeria_id;
        END IF;

        INSERT INTO ecommerce.inicio_secciones (cuerpo_id, clave, nombre, orden, activo, galeria_id)
        VALUES (p_cuerpo_id, v_fila.clave, v_fila.nombre, v_fila.orden, false, v_galeria)
           ON CONFLICT (cuerpo_id, clave) DO NOTHING;

        v_cuantas := v_cuantas + 1;
    END LOOP;

    RETURN v_cuantas;
END;
$function$;

-- ---------- fn_cuerpos_guardar ----------
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
    v_seccion_productos bigint;
    v_seccion_nombre text;
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

    -- LA SECCIÓN CON LA QUE NACE LA PÁGINA, si eligieron uno al crearla.
    -- Es un atajo, igual que la casilla del catálogo: lo mismo se puede hacer
    -- después en el editor de secciones, pero una página recién creada está
    -- vacía y es justo el momento en que se le quiere meter algo.
    v_seccion_productos := nullif(btrim(COALESCE(p_datos ->> 'seccion_productos_id', '')), '')::bigint;

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
        -- sección dos veces en la misma página lo rechaza la base.
        --
        -- Y SI LA SECCIÓN NO EXISTE, LA PÁGINA NO SE CREA: `poner` revienta
        -- y se va todo. Es lo que se quiere: una página que se pidió con
        -- productos y nace vacía es peor que un error.
        IF v_seccion_productos IS NOT NULL THEN
            PERFORM ecommerce.fn_inicio_seccion_productos_poner(v_id, v_seccion_productos,
                p_usuario_id, p_usuario_login, p_usuario_nombre,
                p_ip_address, p_user_agent, p_request_id);

            SELECT nombre INTO v_seccion_nombre
              FROM ecommerce.grupos_productos WHERE id = v_seccion_productos;
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
            WHEN v_seccion_nombre IS NOT NULL
                THEN format('Cuerpo «%s» creado con «%s» dentro', v_nombre, v_seccion_nombre)
            WHEN v_sembradas = 0   THEN format('Cuerpo «%s» creado', v_nombre)
            ELSE format('Cuerpo «%s» creado con sus %s secciones apagadas', v_nombre, v_sembradas) END,
        'data', ecommerce.fn_cuerpos_json(v_id));
END;
$function$;

-- ---------- fn_grupos_productos_crear ----------
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
    -- sección se arma aquí y se añade donde se quiera con «Sección»
    -- (fn_inicio_seccion_productos_poner), en la principal igual que en las demás.
    RETURN jsonb_build_object('success', true,
        'message', format('Grupo «%s» creado. Añádelo a las páginas donde quieras que salga', btrim(p_nombre)),
        'data', ecommerce.fn_grupos_productos_json(v_id));
END;
$function$;

-- ---------- fn_inicio_escaparate_poner ----------
CREATE OR REPLACE FUNCTION ecommerce.fn_inicio_seccion_productos_poner(p_cuerpo_id bigint, p_grupo_id bigint, p_usuario_id bigint DEFAULT NULL::bigint, p_usuario_login character varying DEFAULT NULL::character varying, p_usuario_nombre character varying DEFAULT NULL::character varying, p_ip_address inet DEFAULT NULL::inet, p_user_agent text DEFAULT NULL::text, p_request_id uuid DEFAULT NULL::uuid)
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

    -- Nace ENCENDIDA y al final, como cuando se crea la sección: lo que se
    -- acaba de añadir se quiere ver.
    INSERT INTO ecommerce.inicio_secciones (cuerpo_id, clave, nombre, orden, activo, grupo_productos_id)
    VALUES (v_cuerpo, 'grupo_' || p_grupo_id, v_nombre, v_orden, true, p_grupo_id);

    RETURN jsonb_build_object('success', true,
        'message', format('«%s» añadida a «%s»', v_nombre, v_pagina),
        'data', (ecommerce.fn_inicio_listar(v_cuerpo) -> 'data'));
END;
$function$;

-- ---------- fn_inicio_escaparate_quitar ----------
CREATE OR REPLACE FUNCTION ecommerce.fn_inicio_seccion_productos_quitar(p_id bigint, p_usuario_id bigint DEFAULT NULL::bigint, p_usuario_login character varying DEFAULT NULL::character varying, p_usuario_nombre character varying DEFAULT NULL::character varying, p_ip_address inet DEFAULT NULL::inet, p_user_agent text DEFAULT NULL::text, p_request_id uuid DEFAULT NULL::uuid)
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
        RAISE EXCEPTION 'Esa sección no es una sección de productos de productos: no se quita desde aquí'
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

-- ---------- fn_inicio_escaparates_disponibles ----------
CREATE OR REPLACE FUNCTION ecommerce.fn_inicio_secciones_productos_disponibles(p_cuerpo_id bigint DEFAULT NULL::bigint)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
AS $function$
    SELECT jsonb_build_object('success', true, 'message', 'Secciones de productos que se pueden añadir',
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

-- ---------- fn_inicio_listar ----------
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
                       -- A qué sección o a qué galería apunta, y si es de
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
                           -- Los de la sección, sin los que estén en la
                           -- papelera del catálogo: si contara las filas del
                           -- cruce diría ocho y la pantalla enseñaría seis.
                           WHEN 'productos' THEN
                               (SELECT count(*)
                                  FROM ecommerce.grupos_productos_items it
                                  JOIN inventarios.productos p ON p.id = it.producto_id
                                 WHERE it.grupo_id = s.grupo_productos_id
                                   AND p.deleted_at IS NULL
                                   -- Los que la tienda va a enseñar DE VERDAD: un
                                   -- sección lleno de productos apagados es un
                                   -- sección que la tienda se salta
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

-- ---------- fn_tienda_productos ----------
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
           NULLIF(btrim(COALESCE(p_filtros ->> 'seccion_productos', '')), '')::bigint        AS seccion_productos,
           COALESCE(NULLIF(btrim(COALESCE(p_filtros ->> 'sort', '')), ''), 'recent') AS orden,
           NULLIF(btrim(COALESCE(p_filtros ->> 'price_min', '')), '')::numeric       AS precio_min,
           NULLIF(btrim(COALESCE(p_filtros ->> 'price_max', '')), '')::numeric       AS precio_max,
           GREATEST(1, COALESCE(NULLIF(btrim(COALESCE(p_filtros ->> 'page', '')), '')::int, 1))
                                                                                     AS pagina,
           -- EL TECHO SON 120 Y NO 48: /shop pide 12, 24 o 48, pero un
           -- sección del inicio acumula («Ver más productos» añade debajo
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
           -- Doce de la ficha. En una sección de productos van además la categoría, la
           -- marca y el precio, que son de la tienda y no de la ficha: se
           -- SUMAN al techo en vez de quitarle el sitio a tres características
           12 + CASE WHEN (SELECT seccion_productos FROM param) IS NULL THEN 0 ELSE 3 END
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
-- ===== Una sección de productos: la lista de productos que alguien armó a mano =====
--
-- Hasta el 09/11/2026 esas listas viajaban ENTERAS dentro de la página
-- (fn_grupo_productos_publico) y el navegador las filtraba, las contaba y las
-- iba soltando de a doce: noventa y un productos con su ficha entera eran 63 KB
-- de JSON para enseñar doce tarjetas. Ahora una sección de productos es UN FILTRO MÁS del
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
en_la_seccion AS (
    SELECT it.producto_id, min(it.orden) AS orden
      FROM ecommerce.grupos_productos_items it
     WHERE it.grupo_id = (SELECT seccion_productos FROM param)
     GROUP BY it.producto_id
),
base AS (
    SELECT pr.id, pr.codigo, pr.nombre, pr.precio, pr.precio_anterior, pr.categoria_id, pr.marca_id, pr.created_at,
           pr.precio_tarjeta, pr.cuota_credito_directo,
           ee.orden                                                   AS orden_la_seccion,
           NULLIF(btrim(COALESCE(m.logo, '')), '')                    AS marca_logo,
           COALESCE(NULLIF(btrim(m.nombre), ''), '')                  AS marca,
           COALESCE(NULLIF(btrim(cw.nombre_web), ''), cat.nombre, '') AS categoria
      FROM inventarios.productos pr
      -- LEFT y no JOIN: con una sección de productos pedido manda su lista, no el árbol
      LEFT JOIN visibles v                  ON v.id  = pr.categoria_id
      LEFT JOIN en_la_seccion ee            ON ee.producto_id = pr.id
      LEFT JOIN inventarios.marcas m        ON m.id   = pr.marca_id     AND m.deleted_at IS NULL
      LEFT JOIN inventarios.categorias cat  ON cat.id = pr.categoria_id AND cat.deleted_at IS NULL
      LEFT JOIN ecommerce.categorias_web cw ON cw.categoria_id = pr.categoria_id
     WHERE pr.deleted_at IS NULL
       AND pr.activo
       AND pr.en_paginaweb
       AND CASE WHEN (SELECT seccion_productos FROM param) IS NULL
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
-- SÓLO EN UNA SECCIÓN DE PRODUCTOS. En /shop esos tres tienen su propio sitio en el panel
-- de la izquierda —con el árbol de categorías, que una sección de productos no tiene— y
-- ofrecerlos además como persiana sería tenerlos dos veces.
--
-- En una sección de productos no hay panel: está todo en el cajón de los filtros, y ahí
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
     WHERE (SELECT seccion_productos FROM param) IS NOT NULL
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
                        -- El de una sección de productos es el que se arrastró en el CRM;
                        -- sin sección es NULL para todos y no pinta nada
                        f.orden_la_seccion ASC NULLS LAST,
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
-- 2. Y FUERA LAS TRES QUE CAMBIARON DE NOMBRE
-- ----------------------------------------------------------------------------
-- Se tiran DESPUÉS de crear las nuevas: entre medias hay una función que
-- llama a otra (fn_cuerpos_guardar llama a «poner»), y al revés quedaría un
-- momento sin la que necesita.
-- ----------------------------------------------------------------------------
DROP FUNCTION IF EXISTS ecommerce.fn_inicio_escaparate_poner(bigint, bigint, bigint, character varying, character varying, inet, text, uuid);
DROP FUNCTION IF EXISTS ecommerce.fn_inicio_escaparate_quitar(bigint, bigint, character varying, character varying, inet, text, uuid);
DROP FUNCTION IF EXISTS ecommerce.fn_inicio_escaparates_disponibles(bigint);


-- ----------------------------------------------------------------------------
-- COMPROBACIÓN
-- ----------------------------------------------------------------------------
DO $comprobar$
DECLARE
    v_falta text[] := ARRAY[]::text[];
    v_resto text;
BEGIN
    -- No queda ninguna función con la palabra vieja, ni en el nombre ni dentro
    SELECT string_agg(p.proname, ', ') INTO v_resto
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'ecommerce'
       AND (p.proname ILIKE '%escaparate%' OR p.prosrc ILIKE '%escaparate%');
    IF v_resto IS NOT NULL THEN
        v_falta := array_append(v_falta, 'siguen con la palabra vieja: ' || v_resto);
    END IF;

    -- Y las tres nuevas existen
    FOREACH v_resto IN ARRAY ARRAY['fn_inicio_seccion_productos_poner',
                                   'fn_inicio_seccion_productos_quitar',
                                   'fn_inicio_secciones_productos_disponibles'] LOOP
        IF NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                        WHERE n.nspname = 'ecommerce' AND p.proname = v_resto) THEN
            v_falta := array_append(v_falta, 'falta ' || v_resto);
        END IF;
    END LOOP;

    -- EL CATÁLOGO SIGUE ENTENDIENDO EL FILTRO, ahora con su nombre nuevo: con
    -- una sección que no existe no puede devolver nada, y sin filtro sí. Si la
    -- clave se hubiera quedado con el nombre viejo, la nueva se ignoraría y
    -- las dos contestarían lo mismo.
    IF (ecommerce.fn_tienda_productos(jsonb_build_object('seccion_productos', '0')) ->> 'total')::int <> 0 THEN
        v_falta := array_append(v_falta, 'el catálogo se salta el filtro de sección');
    END IF;
    IF (ecommerce.fn_tienda_productos('{}'::jsonb) ->> 'total')::int = 0 THEN
        v_falta := array_append(v_falta, 'el catálogo no devuelve nada ni sin filtros: algo más se rompió');
    END IF;

    IF array_length(v_falta, 1) IS NULL THEN
        RAISE NOTICE 'Comprobado: no queda ninguna función con «escaparate», las tres nuevas están y el catálogo entiende el filtro con su nombre nuevo';
    ELSE
        RAISE EXCEPTION 'FALTA: %', array_to_string(v_falta, ' | ');
    END IF;
END
$comprobar$;

COMMIT;
