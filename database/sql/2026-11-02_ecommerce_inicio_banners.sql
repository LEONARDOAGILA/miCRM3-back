-- ============================================================================
-- ECOMMERCE · VARIOS BANNERS EN LA PORTADA, NO UNO SOLO
-- ============================================================================
-- Fecha: 2026-11-02
--
-- Hasta hoy «Banner simple» era UNA sección de fábrica atada a UNA galería
-- (`inicio_banner_simple`). Ahora se pueden crear los que haga falta: cada uno
-- con su nombre, sus imágenes y sus fechas, y en el sitio de la portada donde
-- se le ponga.
--
-- CÓMO: una sección de la portada con `galeria_id` ES un banner. Igual que una
-- con `producto_seccion_id` es un escaparate de productos. No hace falta tabla
-- nueva: el contenido de un banner son sus imágenes, y para eso ya está
-- `ecommerce.galerias`, que es dinámica —las páginas de marca crean las suyas
-- al vuelo—.
--
-- LA TIENDA NO SE TOCA. Cada banner sale con la clave `banner_simple`, que es
-- la que ya sabe pintar, y su propia lista de imágenes. La portada recorre las
-- secciones por posición, así que varias con la misma clave no la molestan. Lo
-- que cambia es que ahora puede llegar más de una.
--
-- EL «BANNER SIMPLE» DE SIEMPRE PASA A SER UNO MÁS: se le engancha la galería
-- que ya tenía y, desde ahí, se le puede cambiar el nombre y borrarlo como a
-- los nuevos. Sus imágenes no se mueven de sitio.
--
-- BORRAR UN BANNER SE LLEVA SUS IMÁGENES, y eso no tiene vuelta atrás. Se hace
-- igual que «vaciar la papelera» de una galería, que es la operación que ya
-- existía con esa forma: se quitan las filas. La pantalla lo pregunta diciendo
-- cuántas imágenes se van.
--
-- Idempotente.
-- ============================================================================
\set ON_ERROR_STOP on

BEGIN;

-- ----------------------------------------------------------------------------
-- 1. LA COLUMNA QUE CONVIERTE UNA SECCIÓN EN UN BANNER
-- ----------------------------------------------------------------------------
ALTER TABLE ecommerce.inicio_secciones
    ADD COLUMN IF NOT EXISTS galeria_id bigint;

DO $reglas$
BEGIN
    -- SIN ON DELETE CASCADE, a propósito: borrar una galería a mano no puede
    -- llevarse por delante una fila de la portada sin que nadie se entere. El
    -- camino de borrar un banner es fn_inicio_banner_eliminar, que hace las
    -- dos cosas en orden.
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_inicio_secciones_galeria') THEN
        ALTER TABLE ecommerce.inicio_secciones
            ADD CONSTRAINT fk_inicio_secciones_galeria
            FOREIGN KEY (galeria_id) REFERENCES ecommerce.galerias(id);
    END IF;

    -- Una galería, un banner: dos secciones apuntando a las mismas imágenes
    -- se editarían la una a la otra sin que se vea de dónde viene el cambio
    IF NOT EXISTS (SELECT 1 FROM pg_class WHERE relname = 'uq_inicio_secciones_galeria') THEN
        CREATE UNIQUE INDEX uq_inicio_secciones_galeria
            ON ecommerce.inicio_secciones (galeria_id) WHERE galeria_id IS NOT NULL;
    END IF;
END
$reglas$;

-- El de siempre pasa a ser uno más: se le engancha la galería que ya usaba
UPDATE ecommerce.inicio_secciones s
   SET galeria_id = g.id
  FROM ecommerce.galerias g
 WHERE s.clave = 'banner_simple'
   AND g.clave = 'inicio_banner_simple'
   AND s.galeria_id IS NULL;

-- ----------------------------------------------------------------------------
-- 2. DE DÓNDE SACA SUS DATOS CADA SECCIÓN
-- ----------------------------------------------------------------------------
-- Gana un tercer argumento: la clave de su galería. Se la pasa quien llama
-- —que ya tiene la fila delante— en vez de buscarla aquí dentro: así la
-- función sigue sin leer tablas y se puede llamar una vez por fila.
CREATE OR REPLACE FUNCTION ecommerce.fn_inicio_fuente(
    p_clave text,
    p_producto_seccion_id bigint DEFAULT NULL::bigint,
    p_galeria_clave text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE sql
 IMMUTABLE PARALLEL SAFE
AS $function$
    SELECT CASE
        -- Las de productos se reconocen por a quién apuntan, no por su clave:
        -- la clave la fabrica el servidor y no debería haber dos sitios que
        -- sepan cómo se escribe.
        WHEN p_producto_seccion_id IS NOT NULL THEN
            jsonb_build_object('tipo', 'productos',
                               'pantalla', 'producto-por-seccion',
                               'seccion_id', p_producto_seccion_id)
        -- Y los banners, por su galería. Va ANTES que las claves de fábrica
        -- porque «banner_simple» tiene las dos cosas: es de fábrica y tiene
        -- galería, y lo que manda es la galería.
        WHEN nullif(btrim(COALESCE(p_galeria_clave, '')), '') IS NOT NULL THEN
            jsonb_build_object('tipo', 'galeria', 'galeria', p_galeria_clave)
        WHEN p_clave = 'banner_principal' THEN
            jsonb_build_object('tipo', 'galeria', 'galeria', 'inicio_banner')
        WHEN p_clave = 'mosaico' THEN
            jsonb_build_object('tipo', 'promocion', 'pantalla', 'allCategoriasWeb')
        WHEN p_clave = 'categorias_destacadas' THEN
            jsonb_build_object('tipo', 'destacadas', 'pantalla', 'allCategoriasWeb')
        WHEN p_clave = 'marcas' THEN
            jsonb_build_object('tipo', 'marcas', 'pantalla', 'allMarcasWeb')
        ELSE jsonb_build_object('tipo', 'pendiente', 'falta', 'su fuente')
    END;
$function$;

-- ----------------------------------------------------------------------------
-- 3. CREAR UN BANNER
-- ----------------------------------------------------------------------------
-- Crea la galería y la fila de la portada de una vez: una galería suelta sin
-- sección no la vería nadie, y una sección sin galería sería un hueco.
CREATE OR REPLACE FUNCTION ecommerce.fn_inicio_banner_crear(
    p_nombre         text,
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
    v_nombre  text;
    v_galeria bigint;
    v_orden   integer;
BEGIN
    PERFORM ecommerce.fn_contexto_auditoria('ecommerce.inicio_secciones',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    v_nombre := ecommerce.fn_validar_texto(p_nombre, 'El nombre del banner', 100);
    IF v_nombre IS NULL THEN
        RAISE EXCEPTION 'Hace falta el nombre del banner' USING ERRCODE = 'P0001';
    END IF;

    -- El id se pide antes para poder meterlo en la clave: así la galería de un
    -- banner se reconoce de un vistazo y nunca choca con otra
    v_galeria := nextval('ecommerce.galerias_id_seq');

    INSERT INTO ecommerce.galerias (id, clave, nombre, descripcion, tipo, maximo)
    VALUES (v_galeria, 'inicio_banner_' || v_galeria, v_nombre,
            'Inicio: banner simple (rota; cada imagen con su vigencia).', 'banner', 10);

    SELECT COALESCE(max(orden), 0) + 1 INTO v_orden FROM ecommerce.inicio_secciones;

    -- Nace APAGADA: se enciende cuando tenga imágenes. Encendida y vacía la
    -- tienda se la salta igual, pero la lista diría que está en la portada.
    INSERT INTO ecommerce.inicio_secciones (clave, nombre, galeria_id, orden, activo)
    VALUES ('banner_' || v_galeria, v_nombre, v_galeria, v_orden, false);

    -- Se devuelve la lista entera y nada más, como el resto: la respuesta HTTP
    -- de la casa sólo lleva `message` y `data`, así que una clave suelta aquí
    -- no llegaría a ninguna parte. Quien necesite saber cuál es la nueva la
    -- reconoce porque antes no estaba.
    RETURN jsonb_build_object('success', true,
        'message', format('Banner «%s» creado', v_nombre),
        'data', (ecommerce.fn_inicio_listar() -> 'data'));
END;
$function$;

-- ----------------------------------------------------------------------------
-- 4. CAMBIARLE EL NOMBRE
-- ----------------------------------------------------------------------------
-- El nombre va en los dos sitios: la fila de la portada y la galería. Si sólo
-- cambiara uno, la pantalla de galerías seguiría llamándolo como antes.
CREATE OR REPLACE FUNCTION ecommerce.fn_inicio_banner_nombre(
    p_clave          text,
    p_nombre         text,
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
    v_galeria bigint;
    v_nombre  text;
BEGIN
    PERFORM ecommerce.fn_contexto_auditoria('ecommerce.inicio_secciones',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    SELECT galeria_id INTO v_galeria
      FROM ecommerce.inicio_secciones WHERE clave = btrim(COALESCE(p_clave, ''));
    IF NOT FOUND THEN
        RAISE EXCEPTION 'La sección «%» no existe', p_clave USING ERRCODE = 'P0013';
    END IF;
    IF v_galeria IS NULL THEN
        RAISE EXCEPTION 'Esa sección no es un banner: su nombre no se cambia' USING ERRCODE = 'P0015';
    END IF;

    v_nombre := ecommerce.fn_validar_texto(p_nombre, 'El nombre del banner', 100);
    IF v_nombre IS NULL THEN
        RAISE EXCEPTION 'Hace falta el nombre del banner' USING ERRCODE = 'P0001';
    END IF;

    UPDATE ecommerce.inicio_secciones SET nombre = v_nombre WHERE clave = btrim(p_clave);
    UPDATE ecommerce.galerias SET nombre = v_nombre WHERE id = v_galeria;

    RETURN jsonb_build_object('success', true,
        'message', format('Banner «%s» guardado', v_nombre),
        'data', (ecommerce.fn_inicio_listar() -> 'data'));
END;
$function$;

-- ----------------------------------------------------------------------------
-- 5. BORRARLO
-- ----------------------------------------------------------------------------
-- SE LLEVA SUS IMÁGENES Y NO TIENE VUELTA ATRÁS. Es la misma forma que
-- «vaciar la papelera» de una galería —se quitan las filas—, y por eso no hay
-- papelera de banners: la papelera de una galería vive dentro de la galería,
-- y aquí la galería también se va.
CREATE OR REPLACE FUNCTION ecommerce.fn_inicio_banner_eliminar(
    p_clave          text,
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
    v_galeria bigint;
    v_nombre  text;
    v_cuantas integer;
BEGIN
    PERFORM ecommerce.fn_contexto_auditoria('ecommerce.inicio_secciones',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    SELECT galeria_id, nombre INTO v_galeria, v_nombre
      FROM ecommerce.inicio_secciones WHERE clave = btrim(COALESCE(p_clave, ''));
    IF NOT FOUND THEN
        RAISE EXCEPTION 'La sección «%» no existe', p_clave USING ERRCODE = 'P0013';
    END IF;
    IF v_galeria IS NULL THEN
        RAISE EXCEPTION 'Esa sección no es un banner: no se puede borrar desde aquí'
              USING ERRCODE = 'P0015';
    END IF;

    SELECT count(*) INTO v_cuantas
      FROM ecommerce.galerias_imagenes WHERE galeria_id = v_galeria;

    -- En orden: primero lo que cuelga, al final la fila de la portada
    DELETE FROM ecommerce.galerias_imagenes WHERE galeria_id = v_galeria;
    DELETE FROM ecommerce.inicio_secciones  WHERE clave = btrim(p_clave);
    DELETE FROM ecommerce.galerias          WHERE id = v_galeria;

    -- El orden se compacta para que no queden huecos
    WITH nuevo AS (
        SELECT clave, row_number() OVER (ORDER BY orden, id) AS n
          FROM ecommerce.inicio_secciones
    )
    UPDATE ecommerce.inicio_secciones s
       SET orden = nuevo.n
      FROM nuevo
     WHERE nuevo.clave = s.clave AND s.orden <> nuevo.n;

    RETURN jsonb_build_object('success', true,
        'message', format('Banner «%s» borrado con sus %s imágenes', v_nombre, v_cuantas),
        'data', (ecommerce.fn_inicio_listar() -> 'data'));
END;
$function$;

-- ----------------------------------------------------------------------------
-- 6. EL LISTADO DEL CRM
-- ----------------------------------------------------------------------------
-- Se reescribe entera, y no por cirugía, por dos motivos: hay que engancharle
-- la galería (un LEFT JOIN), y `fn_inicio_fuente` se llamaba SIETE veces por
-- fila para preguntarle lo mismo. Ahora se llama una vez en un LATERAL y las
-- siete leen de ahí.
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
                       -- A qué escaparate o a qué galería apunta, y si es de
                       -- las de fábrica. `fija` lo decide el servidor: la
                       -- pantalla no tiene por qué saber que «de fábrica»
                       -- significa «sin nada propio detrás».
                       'producto_seccion_id', s.producto_seccion_id,
                       'galeria_id', s.galeria_id,
                       -- Un banner se crea y se borra desde la portada; las de
                       -- productos, en su pantalla; las demás no se tocan
                       'es_banner',  s.galeria_id IS NOT NULL,
                       'fija',       s.producto_seccion_id IS NULL AND s.galeria_id IS NULL,
                       'botones',    ecommerce.fn_botones_colores(
                                           s.boton_favorito_color, s.boton_favorito_texto,
                                           s.boton_carrito_color,  s.boton_carrito_texto,
                                           s.boton_whatsapp_color, s.boton_whatsapp_texto,
                                           s.boton_tarjeta_color,  s.boton_tarjeta_texto),
                       'tarjeta',    ecommerce.fn_tarjeta_colores(
                                           s.tarjeta_fondo_color, s.tarjeta_borde_color,
                                           s.descuento_color,     s.descuento_texto,
                                           s.etiqueta, s.etiqueta_color, s.etiqueta_texto),
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
                           -- Los del escaparate, sin los que estén en la
                           -- papelera del catálogo: si contara las filas del
                           -- cruce diría ocho y la pantalla enseñaría seis.
                           WHEN 'productos' THEN
                               (SELECT count(*)
                                  FROM ecommerce.producto_secciones_items it
                                  JOIN inventarios.productos p ON p.id = it.producto_id
                                 WHERE it.seccion_id = s.producto_seccion_id
                                   AND p.deleted_at IS NULL)
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
                           -- La tienda sólo pinta las que tienen logo: una
                           -- marca sin imagen no cuenta como contenido.
                           WHEN 'marcas' THEN
                               EXISTS (SELECT 1 FROM jsonb_array_elements(ecommerce.fn_marcas_publicas()) m
                                        WHERE COALESCE(m ->> 'imagen', m ->> 'logo') IS NOT NULL)
                           WHEN 'productos' THEN
                               EXISTS (SELECT 1
                                         FROM ecommerce.producto_secciones_items it
                                         JOIN inventarios.productos p ON p.id = it.producto_id
                                        WHERE it.seccion_id = s.producto_seccion_id
                                          AND p.deleted_at IS NULL)
                           ELSE false END)
                   ORDER BY s.orden, s.id)
              FROM ecommerce.inicio_secciones s
              LEFT JOIN ecommerce.galerias g ON g.id = s.galeria_id
              CROSS JOIN LATERAL (
                  SELECT ecommerce.fn_inicio_fuente(s.clave, s.producto_seccion_id, g.clave) AS f
              ) fu
             WHERE ecommerce.fn_inicio_seccion_viva(s.producto_seccion_id)), '[]'::jsonb));
$function$;

-- ----------------------------------------------------------------------------
-- 7. LA PORTADA PÚBLICA
-- ----------------------------------------------------------------------------
-- La rama fija de `banner_simple` se cambia por una que vale para todos: lo
-- que decide es tener galería, no cómo se llame la sección. Todos salen con la
-- clave `banner_simple`, que es la que la tienda sabe pintar.
DO $publica$
DECLARE
    def    text;
    ancla1 text := E'        SELECT s.clave, s.hasta, s.orden, s.producto_seccion_id,';
    ancla2 text := E'                   WHEN v.clave = ''banner_simple'' THEN\n                        jsonb_build_object(''clave'', v.clave,\n                            ''imagenes'', COALESCE(ecommerce.fn_galerias_publica(''inicio_banner_simple'') -> ''imagenes'', ''[]''::jsonb))';
    ancla3 text := E'          FROM ecommerce.inicio_secciones s\n         WHERE s.activo AND ecommerce.fn_vigente(s.desde, s.hasta)';
BEGIN
    SELECT pg_get_functiondef(p.oid) INTO def
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'ecommerce' AND p.proname = 'fn_inicio_publico';

    IF def IS NULL THEN
        RAISE EXCEPTION 'No está ecommerce.fn_inicio_publico';
    END IF;

    IF strpos(def, 'galeria_clave') > 0 THEN
        RAISE NOTICE 'La portada pública ya servía varios banners: no la toco.';
        RETURN;
    END IF;

    IF strpos(def, ancla1) = 0 OR strpos(def, ancla2) = 0 OR strpos(def, ancla3) = 0 THEN
        RAISE EXCEPTION 'No encontré los tres sitios que hay que tocar: ¿cambió fn_inicio_publico?';
    END IF;

    -- La fila se lleva además su galería
    def := replace(def, ancla1,
        E'        SELECT s.clave, s.hasta, s.orden, s.producto_seccion_id, g.clave AS galeria_clave,');
    def := replace(def, ancla3,
        E'          FROM ecommerce.inicio_secciones s\n          LEFT JOIN ecommerce.galerias g ON g.id = s.galeria_id\n         WHERE s.activo AND ecommerce.fn_vigente(s.desde, s.hasta)');

    -- Y la rama deja de mirar la clave de la sección para mirar la galería
    def := replace(def, ancla2,
        E'                   -- Cualquier sección con galería es un banner, y sale con\n'
        || E'                   -- la clave que la tienda sabe pintar. Pueden ser varios.\n'
        || E'                   WHEN v.galeria_clave IS NOT NULL THEN\n'
        || E'                        jsonb_build_object(''clave'', ''banner_simple'',\n'
        || E'                            ''imagenes'', COALESCE(ecommerce.fn_galerias_publica(v.galeria_clave) -> ''imagenes'', ''[]''::jsonb))');

    EXECUTE def;
    RAISE NOTICE 'La portada pública ya sirve varios banners.';
END
$publica$;

-- ----------------------------------------------------------------------------
-- 8. COMPROBACIÓN
-- ----------------------------------------------------------------------------
DO $comprobar$
DECLARE
    v_r        jsonb;
    v_clave    text;
    v_galeria  bigint;
    v_fila     jsonb;
    v_viejo    jsonb;
    v_publicas text;
    v_malo     text := NULL;
BEGIN
    -- El de siempre tiene que haberse convertido en banner
    SELECT x INTO v_viejo
      FROM jsonb_array_elements(ecommerce.fn_inicio_listar() -> 'data') x
     WHERE x ->> 'clave' = 'banner_simple';
    IF v_viejo IS NULL THEN
        RAISE EXCEPTION 'Se perdió el «Banner simple» de siempre';
    END IF;
    IF (v_viejo ->> 'es_banner')::boolean IS NOT TRUE THEN
        RAISE EXCEPTION 'El de siempre no quedó como banner: %', v_viejo;
    END IF;
    IF v_viejo -> 'fuente' ->> 'galeria' <> 'inicio_banner_simple' THEN
        RAISE EXCEPTION 'El de siempre perdió su galería: %', v_viejo -> 'fuente';
    END IF;
    IF (v_viejo ->> 'fija')::boolean IS NOT FALSE THEN
        RAISE EXCEPTION 'El de siempre tendría que dejar de ser fija: %', v_viejo;
    END IF;

    BEGIN
        v_r := ecommerce.fn_inicio_banner_crear('ZZ banner nuevo');

        SELECT clave, galeria_id INTO v_clave, v_galeria
          FROM ecommerce.inicio_secciones WHERE nombre = 'ZZ banner nuevo';

        SELECT x INTO v_fila
          FROM jsonb_array_elements(v_r -> 'data') x WHERE x ->> 'clave' = v_clave;

        -- Con galería propia y nombre propio
        IF v_fila IS NULL THEN
            RAISE EXCEPTION 'El banner nuevo no sale en el listado';
        END IF;
        IF (v_fila ->> 'es_banner')::boolean IS NOT TRUE
           OR v_fila -> 'fuente' ->> 'galeria' <> 'inicio_banner_' || v_galeria THEN
            RAISE EXCEPTION 'El banner nuevo no apunta a su galería: %', v_fila -> 'fuente';
        END IF;
        IF (v_fila ->> 'activo')::boolean IS NOT FALSE THEN
            RAISE EXCEPTION 'Un banner recién creado tendría que nacer apagado: %', v_fila;
        END IF;
        IF (v_fila ->> 'cuantas')::int <> 0 THEN
            RAISE EXCEPTION 'Y sin imágenes: %', v_fila;
        END IF;

        -- Cambiarle el nombre lo cambia en los dos sitios
        PERFORM ecommerce.fn_inicio_banner_nombre(v_clave, 'ZZ banner de navidad');
        IF (SELECT nombre FROM ecommerce.galerias WHERE id = v_galeria) <> 'ZZ banner de navidad' THEN
            RAISE EXCEPTION 'El nombre no llegó a la galería';
        END IF;

        -- Una sección que NO es banner no se puede borrar por esta puerta
        BEGIN
            PERFORM ecommerce.fn_inicio_banner_eliminar('banner_principal');
            v_malo := 'se pudo borrar una sección de fábrica como si fuera un banner';
        EXCEPTION WHEN SQLSTATE 'P0015' THEN
            NULL;
        END;

        -- Y borrarlo se lleva la galería
        PERFORM ecommerce.fn_inicio_banner_eliminar(v_clave);
        IF EXISTS (SELECT 1 FROM ecommerce.galerias WHERE id = v_galeria) THEN
            RAISE EXCEPTION 'La galería del banner borrado se quedó';
        END IF;
        IF EXISTS (SELECT 1 FROM ecommerce.inicio_secciones WHERE clave = v_clave) THEN
            RAISE EXCEPTION 'La fila del banner borrado se quedó';
        END IF;

        RAISE EXCEPTION 'deshacer' USING ERRCODE = 'P0099';
    EXCEPTION WHEN SQLSTATE 'P0099' THEN
        NULL;
    END;

    IF v_malo IS NOT NULL THEN
        RAISE EXCEPTION '%', v_malo;
    END IF;

    -- La tienda sigue recibiendo su banner simple de siempre
    -- Con ORDINALITY haría falta nombrar las dos columnas (x(valor, n)); el
    -- orden ya viene dado dentro del jsonb, así que no hace falta
    SELECT string_agg(x ->> 'clave', ', ') INTO v_publicas
      FROM jsonb_array_elements(ecommerce.fn_inicio_publico() -> 'secciones') x;

    RAISE NOTICE 'Comprobado: el de siempre es ahora un banner con su galería, se crean apagados y con su propia galería, el nombre llega a los dos sitios, una sección de fábrica no se puede borrar por esta puerta y la tienda ve «%». No quedó nada.', v_publicas;
END
$comprobar$;

COMMIT;
