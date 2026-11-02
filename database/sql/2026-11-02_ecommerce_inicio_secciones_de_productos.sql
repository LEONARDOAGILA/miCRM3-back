-- ============================================================================
-- ECOMMERCE · LAS SECCIONES DE PRODUCTOS, EN LA PORTADA
-- ============================================================================
-- Fecha: 2026-11-02
--
-- Hasta hoy la portada eran OCHO SITIOS FIJOS: cada uno existe porque la
-- tienda sabe pintarlo, y desde el CRM sólo se encienden, se ordenan y se les
-- pone rótulo. Los escaparates que se arman en «Productos por sección»
-- —«Los más vendidos», «Ofertas de navidad»— no tenían dónde salir.
--
-- AHORA CADA SECCIÓN DE PRODUCTOS ES UNA FILA MÁS DE LA PORTADA, con su
-- orden, su rótulo, su color, su letra, su alto y su vigencia, como las ocho
-- de siempre. La lista crece sola al crear una y se encoge al mandarla a la
-- papelera.
--
-- Y SE HACE CON UNA FILA DE VERDAD EN `inicio_secciones`, no uniendo dos
-- tablas al vuelo. Es lo que hace que no haya que tocar nada más: ordenar,
-- encender, el rótulo, el alto, el modelado y la portada pública siguen
-- trabajando por `clave` sobre una sola tabla. Con un UNION habría que
-- enseñarle a cada una de esas funciones que hay dos sitios de donde sacar
-- secciones, y la primera que se olvidara dejaría una sección a medias.
--
--     clave                 seccion_<id> de la sección de productos
--     nombre                el nombre de la sección, y se mantiene al día
--     producto_seccion_id   a cuál apunta; NULL en las ocho de siempre
--
-- LA PAPELERA NO BORRA LA FILA DE LA PORTADA: se esconde mientras la sección
-- esté en la papelera y vuelve con su orden y su rótulo si se restaura. Si la
-- sección se borrara de verdad, la clave ajena se lleva la fila.
--
-- LA TIENDA TODAVÍA NO LAS PINTA. Su código ignora las claves que no conoce,
-- así que una sección nueva se administra aquí pero no sale en la web hasta
-- que la tienda tenga un diseño para ellas y el catálogo pueda dar la tarjeta
-- del producto (hoy faltan existencias, «destacado» y el precio anterior).
-- `fn_inicio_publico` las deja fuera a propósito en vez de mandar media
-- tarjeta: una tarjeta sin existencias saldría «Agotado» en todos lados.
--
-- Idempotente.
-- ============================================================================
\set ON_ERROR_STOP on

BEGIN;

-- ----------------------------------------------------------------------------
-- 1. LA COLUMNA
-- ----------------------------------------------------------------------------
ALTER TABLE ecommerce.inicio_secciones
    ADD COLUMN IF NOT EXISTS producto_seccion_id bigint;

DO $ligar$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'fk_inicio_secciones_producto_seccion') THEN
        ALTER TABLE ecommerce.inicio_secciones
            ADD CONSTRAINT fk_inicio_secciones_producto_seccion
            FOREIGN KEY (producto_seccion_id)
            REFERENCES ecommerce.producto_secciones (id) ON DELETE CASCADE;
    END IF;
END
$ligar$;

-- Una sola fila de portada por sección de productos
CREATE UNIQUE INDEX IF NOT EXISTS uq_inicio_secciones_producto_seccion
    ON ecommerce.inicio_secciones (producto_seccion_id)
 WHERE producto_seccion_id IS NOT NULL;

-- ----------------------------------------------------------------------------
-- 2. CUÁNDO CUENTA UNA FILA DE LA PORTADA
-- ----------------------------------------------------------------------------
-- La regla vive aquí y no repetida en cada consulta: la usan el listado, el
-- orden y la portada pública, y son justo las tres que tienen que decir lo
-- mismo. Una de las ocho de siempre (producto_seccion_id NULL) cuenta siempre.
CREATE OR REPLACE FUNCTION ecommerce.fn_inicio_seccion_viva(p_producto_seccion_id bigint)
 RETURNS boolean
 LANGUAGE sql
 STABLE PARALLEL SAFE
AS $function$
    SELECT p_producto_seccion_id IS NULL
        OR EXISTS (SELECT 1 FROM ecommerce.producto_secciones ps
                    WHERE ps.id = p_producto_seccion_id AND ps.deleted_at IS NULL);
$function$;

-- ----------------------------------------------------------------------------
-- 3. DE DÓNDE COME CADA SECCIÓN
-- ----------------------------------------------------------------------------
-- Gana un segundo parámetro. La vieja de un solo argumento se borra: con las
-- dos puestas y un DEFAULT, una llamada con un argumento sería ambigua y
-- Postgres se niega a elegir.
DROP FUNCTION IF EXISTS ecommerce.fn_inicio_fuente(text);

CREATE OR REPLACE FUNCTION ecommerce.fn_inicio_fuente(
    p_clave text, p_producto_seccion_id bigint DEFAULT NULL)
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
        WHEN p_clave = 'banner_principal' THEN
            jsonb_build_object('tipo', 'galeria', 'galeria', 'inicio_banner')
        WHEN p_clave = 'banner_simple' THEN
            jsonb_build_object('tipo', 'galeria', 'galeria', 'inicio_banner_simple')
        WHEN p_clave = 'mosaico' THEN
            jsonb_build_object('tipo', 'promocion', 'pantalla', 'allCategoriasWeb')
        WHEN p_clave = 'categorias_destacadas' THEN
            jsonb_build_object('tipo', 'destacadas', 'pantalla', 'allCategoriasWeb')
        WHEN p_clave = 'marcas' THEN
            jsonb_build_object('tipo', 'marcas', 'pantalla', 'allMarcasWeb')
        WHEN p_clave = 'ofertas_flash' THEN
            jsonb_build_object('tipo', 'pendiente', 'falta', 'el catálogo de la tienda (precio y existencias)')
        WHEN p_clave = 'grilla' THEN
            jsonb_build_object('tipo', 'pendiente', 'falta', 'el catálogo de la tienda (precio y existencias)')
        WHEN p_clave = 'bloques' THEN
            jsonb_build_object('tipo', 'pendiente', 'falta', 'los bloques de productos destacados')
        ELSE jsonb_build_object('tipo', 'pendiente', 'falta', 'su fuente')
    END;
$function$;

-- ----------------------------------------------------------------------------
-- 4. EL LISTADO DE LA PORTADA
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
                       -- A qué escaparate apunta, y si es de las ocho de
                       -- siempre. `fija` lo decide el servidor: la pantalla no
                       -- tiene por qué saber que «de fábrica» significa «sin
                       -- sección de productos detrás».
                       'producto_seccion_id', s.producto_seccion_id,
                       'fija',       s.producto_seccion_id IS NULL,
                       'estado',     CASE
                           WHEN NOT s.activo THEN 'oculta'
                           WHEN s.desde IS NOT NULL AND CURRENT_TIMESTAMP < s.desde THEN 'programada'
                           WHEN s.hasta IS NOT NULL AND CURRENT_TIMESTAMP > s.hasta THEN 'terminada'
                           ELSE 'visible' END,
                       'fuente',     ecommerce.fn_inicio_fuente(s.clave, s.producto_seccion_id),
                       'cuantas',    CASE ecommerce.fn_inicio_fuente(s.clave, s.producto_seccion_id) ->> 'tipo'
                           WHEN 'galeria' THEN
                               (SELECT count(*) FROM ecommerce.galerias_imagenes i
                                  JOIN ecommerce.galerias g ON g.id = i.galeria_id
                                 WHERE g.clave = ecommerce.fn_inicio_fuente(s.clave, s.producto_seccion_id) ->> 'galeria'
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
                       'con_contenido', CASE ecommerce.fn_inicio_fuente(s.clave, s.producto_seccion_id) ->> 'tipo'
                           WHEN 'galeria' THEN
                               EXISTS (SELECT 1 FROM ecommerce.galerias_imagenes i
                                         JOIN ecommerce.galerias g ON g.id = i.galeria_id
                                        WHERE g.clave = ecommerce.fn_inicio_fuente(s.clave, s.producto_seccion_id) ->> 'galeria'
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
             WHERE ecommerce.fn_inicio_seccion_viva(s.producto_seccion_id)), '[]'::jsonb));
$function$;

-- ----------------------------------------------------------------------------
-- 5. EL ORDEN
-- ----------------------------------------------------------------------------
-- Sigue exigiendo que lleguen TODAS, porque el orden es la posición en la
-- lista y una que falte se quedaría con el número viejo. Lo que cambia es qué
-- son «todas»: las que se ven, sin las que estén en la papelera.
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
     WHERE clave IN (SELECT x FROM jsonb_array_elements_text(p_claves) x)
       AND ecommerce.fn_inicio_seccion_viva(producto_seccion_id);

    SELECT count(*) INTO v_todas FROM ecommerce.inicio_secciones
     WHERE ecommerce.fn_inicio_seccion_viva(producto_seccion_id);

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
-- 6. LA PORTADA PÚBLICA
-- ----------------------------------------------------------------------------
-- Una sección cuya sección de productos esté en la papelera no sale, igual que
-- no sale en el listado. Hoy daría lo mismo —la tienda ignora las claves que
-- no conoce y éstas se caen igual en el filtro de abajo—, pero el día que
-- aprenda a pintarlas ya no habría que acordarse de esto.
--
-- Se le hace cirugía en vez de reescribirla: esa función la han ido ampliando
-- el rótulo y el alto, y volver a escribirla aquí entera es la forma de
-- perder algo por el camino.
DO $publica$
DECLARE
    def   text;
    ancla text := E'         WHERE s.activo AND ecommerce.fn_vigente(s.desde, s.hasta)';
BEGIN
    SELECT pg_get_functiondef(p.oid) INTO def
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'ecommerce' AND p.proname = 'fn_inicio_publico';

    IF def IS NULL THEN
        RAISE EXCEPTION 'No está ecommerce.fn_inicio_publico';
    END IF;

    -- El aviso de «ya estaba» y el de «hecho» dicen cosas DISTINTAS a
    -- propósito: con el mismo texto, al volver a ejecutar esto no hay forma de
    -- saber si la cirugía se aplicó o si se saltó, y lo único que queda es ir
    -- a mirar la función a la base.
    IF strpos(def, 'fn_inicio_seccion_viva') > 0 THEN
        RAISE NOTICE 'La portada pública ya estaba hecha: no la toco.';
        RETURN;
    END IF;

    IF strpos(def, ancla) = 0 THEN
        RAISE EXCEPTION 'No encontré el WHERE de las visibles: ¿cambió fn_inicio_publico?';
    END IF;

    def := replace(def, ancla,
        ancla || E'\n           AND ecommerce.fn_inicio_seccion_viva(s.producto_seccion_id)');

    EXECUTE def;
    RAISE NOTICE 'La portada pública ya se salta las secciones en la papelera.';
END
$publica$;

-- ----------------------------------------------------------------------------
-- 7. CREAR Y RENOMBRAR UNA SECCIÓN DE PRODUCTOS
-- ----------------------------------------------------------------------------
-- Crear una sección CREA TAMBIÉN SU FILA EN LA PORTADA, encendida y al final.
-- Nace encendida a propósito: es lo que se acaba de pedir, y una sección sin
-- productos la tienda ya se la salta, así que encendida y vacía no enseña un
-- hueco. Apagada obligaría a acordarse de encenderla después de llenarla.
CREATE OR REPLACE FUNCTION ecommerce.fn_producto_secciones_crear(
    p_nombre character varying,
    p_desde timestamptz DEFAULT NULL, p_hasta timestamptz DEFAULT NULL,
    p_usuario_id bigint DEFAULT NULL, p_usuario_login character varying DEFAULT NULL,
    p_usuario_nombre character varying DEFAULT NULL, p_ip_address inet DEFAULT NULL,
    p_user_agent text DEFAULT NULL, p_request_id uuid DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'ecommerce', 'auditoria'
AS $function$
DECLARE
    v_id bigint;
BEGIN
    PERFORM ecommerce.fn_contexto_auditoria('ecommerce.producto_secciones',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    PERFORM ecommerce.fn_producto_secciones_validar(NULL, p_nombre, p_desde, p_hasta);

    INSERT INTO ecommerce.producto_secciones (nombre, desde, hasta, orden)
    VALUES (btrim(p_nombre), p_desde, p_hasta,
            (SELECT COALESCE(max(orden), 0) + 1 FROM ecommerce.producto_secciones
              WHERE deleted_at IS NULL))
    RETURNING id INTO v_id;

    -- Su sitio en la portada. La vigencia NO se copia: la de la sección dice
    -- hasta cuándo es el escaparate, y la de la portada hasta cuándo se ve;
    -- juntarlas aquí dejaría dos fechas que hay que cambiar a la vez.
    INSERT INTO ecommerce.inicio_secciones (clave, nombre, orden, activo, producto_seccion_id)
    VALUES ('seccion_' || v_id, btrim(p_nombre),
            (SELECT COALESCE(max(orden), 0) + 1 FROM ecommerce.inicio_secciones
              WHERE ecommerce.fn_inicio_seccion_viva(producto_seccion_id)),
            true, v_id)
       ON CONFLICT (clave) DO NOTHING;

    RETURN jsonb_build_object('success', true,
        'message', format('Sección «%s» creada, y puesta al final de la portada', btrim(p_nombre)),
        'data', ecommerce.fn_producto_secciones_json(v_id));
END;
$function$;

-- Renombrar la sección renombra su fila de la portada: es la misma cosa vista
-- desde dos pantallas, y dos nombres distintos para lo mismo es lo que hace
-- que alguien ordene la portada sin saber qué está moviendo.
CREATE OR REPLACE FUNCTION ecommerce.fn_producto_secciones_modificar(
    p_id bigint, p_nombre character varying,
    p_desde timestamptz DEFAULT NULL, p_hasta timestamptz DEFAULT NULL,
    p_usuario_id bigint DEFAULT NULL, p_usuario_login character varying DEFAULT NULL,
    p_usuario_nombre character varying DEFAULT NULL, p_ip_address inet DEFAULT NULL,
    p_user_agent text DEFAULT NULL, p_request_id uuid DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'ecommerce', 'auditoria'
AS $function$
BEGIN
    PERFORM ecommerce.fn_contexto_auditoria('ecommerce.producto_secciones',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    IF NOT EXISTS (SELECT 1 FROM ecommerce.producto_secciones
                    WHERE id = p_id AND deleted_at IS NULL) THEN
        RAISE EXCEPTION 'La sección no existe' USING ERRCODE = 'P0013';
    END IF;

    PERFORM ecommerce.fn_producto_secciones_validar(p_id, p_nombre, p_desde, p_hasta);

    UPDATE ecommerce.producto_secciones
       SET nombre = btrim(p_nombre), desde = p_desde, hasta = p_hasta
     WHERE id = p_id;

    UPDATE ecommerce.inicio_secciones
       SET nombre = btrim(p_nombre)
     WHERE producto_seccion_id = p_id AND nombre IS DISTINCT FROM btrim(p_nombre);

    RETURN jsonb_build_object('success', true, 'message', 'Sección actualizada',
        'data', ecommerce.fn_producto_secciones_json(p_id));
END;
$function$;

-- ----------------------------------------------------------------------------
-- 8. LAS QUE YA ESTABAN
-- ----------------------------------------------------------------------------
-- Las secciones creadas antes de esta migración no tienen fila en la portada.
-- Se les hace una, al final y encendidas, en el orden en que se crearon.
DO $alcanzar$
DECLARE
    v integer := 0;
BEGIN
    INSERT INTO ecommerce.inicio_secciones (clave, nombre, orden, activo, producto_seccion_id)
    SELECT 'seccion_' || s.id, s.nombre,
           (SELECT COALESCE(max(orden), 0) FROM ecommerce.inicio_secciones)
               + row_number() OVER (ORDER BY s.orden, s.id),
           true, s.id
      FROM ecommerce.producto_secciones s
     WHERE s.deleted_at IS NULL
       AND NOT EXISTS (SELECT 1 FROM ecommerce.inicio_secciones i
                        WHERE i.producto_seccion_id = s.id)
       ON CONFLICT (clave) DO NOTHING;
    GET DIAGNOSTICS v = ROW_COUNT;

    RAISE NOTICE 'Puestas en la portada % secciones de productos que ya existían.', v;
END
$alcanzar$;

-- ----------------------------------------------------------------------------
-- 9. LA CUENTA DE LA PORTADA DEL MÓDULO
-- ----------------------------------------------------------------------------
-- La tarjeta «Inicio de la tienda» contaba todas las filas de la tabla. Con
-- las de productos dentro, una sección en la papelera seguiría sumando y la
-- tarjeta diría «10 secciones» de las que sólo se ven nueve.
DO $resumen$
DECLARE
    def   text;
    ancla text := E'      INTO n, m FROM ecommerce.inicio_secciones;';
BEGIN
    SELECT pg_get_functiondef(p.oid) INTO def
      FROM pg_proc p JOIN pg_namespace n2 ON n2.oid = p.pronamespace
     WHERE n2.nspname = 'ecommerce' AND p.proname = 'fn_resumen';

    IF def IS NULL THEN
        RAISE NOTICE 'No está ecommerce.fn_resumen.';
        RETURN;
    END IF;

    IF strpos(def, 'fn_inicio_seccion_viva') > 0 THEN
        RAISE NOTICE 'La cuenta del resumen ya estaba hecha: no la toco.';
        RETURN;
    END IF;

    IF strpos(def, ancla) = 0 THEN
        RAISE EXCEPTION 'No encontré la cuenta de la portada: ¿cambió fn_resumen?';
    END IF;

    def := replace(def, ancla,
        E'      INTO n, m FROM ecommerce.inicio_secciones'
        || E'\n     WHERE ecommerce.fn_inicio_seccion_viva(producto_seccion_id);');

    EXECUTE def;
    RAISE NOTICE 'El resumen ya se salta las secciones en la papelera.';
END
$resumen$;

-- ----------------------------------------------------------------------------
-- 10. COMPROBACIÓN
-- ----------------------------------------------------------------------------
-- Se crea una sección, se mira que aparezca en la portada con su fuente y su
-- cuenta, se renombra, se manda a la papelera, se restaura, y se deshace todo
-- con el truco de la subtransacción (P0099, que no usa nadie: con P0001 el
-- handler se tragaría un fallo de verdad y las comparaciones darían NULL, que
-- no es TRUE, y esto pasaría en verde sin comprobar nada).
DO $comprobar$
DECLARE
    v_antes     integer;
    v_despues   integer;
    v_id        bigint;
    v_clave     text;
    v_fila      jsonb;
    v_renombre  text;
    v_papelera  integer;
    v_vuelta    integer;
    v_orden     integer;
    v_publica   integer;
BEGIN
    SELECT jsonb_array_length(ecommerce.fn_inicio_listar() -> 'data') INTO v_antes;

    BEGIN
        v_id    := (ecommerce.fn_producto_secciones_crear('ZZ comprobar ' || clock_timestamp())
                    -> 'data' ->> 'id')::bigint;
        v_clave := 'seccion_' || v_id;

        SELECT jsonb_array_length(ecommerce.fn_inicio_listar() -> 'data') INTO v_despues;

        SELECT x INTO v_fila
          FROM jsonb_array_elements(ecommerce.fn_inicio_listar() -> 'data') x
         WHERE x ->> 'clave' = v_clave;

        -- Va al final: es donde se la deja al crearla
        v_orden := (SELECT max((x ->> 'orden')::integer)
                      FROM jsonb_array_elements(ecommerce.fn_inicio_listar() -> 'data') x);

        -- Renombrar la sección renombra su fila de la portada
        PERFORM ecommerce.fn_producto_secciones_modificar(v_id, 'ZZ renombrada');
        SELECT x ->> 'nombre' INTO v_renombre
          FROM jsonb_array_elements(ecommerce.fn_inicio_listar() -> 'data') x
         WHERE x ->> 'clave' = v_clave;

        -- A la papelera: desaparece de la portada
        PERFORM ecommerce.fn_producto_secciones_eliminar(v_id);
        SELECT jsonb_array_length(ecommerce.fn_inicio_listar() -> 'data') INTO v_papelera;
        SELECT count(*) INTO v_publica
          FROM jsonb_array_elements(ecommerce.fn_inicio_publico() -> 'secciones') x
         WHERE x ->> 'clave' = v_clave;

        -- Y vuelve con su fila, su orden y su nombre
        PERFORM ecommerce.fn_producto_secciones_restaurar(v_id);
        SELECT jsonb_array_length(ecommerce.fn_inicio_listar() -> 'data') INTO v_vuelta;

        RAISE EXCEPTION 'deshacer' USING ERRCODE = 'P0099';
    EXCEPTION WHEN SQLSTATE 'P0099' THEN
        NULL;
    END;

    IF v_despues IS NULL OR v_despues <> v_antes + 1 THEN
        RAISE EXCEPTION 'Crear una sección tendría que dejar % filas en la portada y deja %',
              v_antes + 1, v_despues;
    END IF;
    IF v_fila IS NULL THEN
        RAISE EXCEPTION 'La sección nueva no salió en la portada';
    END IF;
    IF v_fila -> 'fuente' ->> 'tipo' <> 'productos' THEN
        RAISE EXCEPTION 'Su fuente tendría que ser «productos» y es «%»',
              v_fila -> 'fuente' ->> 'tipo';
    END IF;
    IF (v_fila ->> 'fija')::boolean THEN
        RAISE EXCEPTION 'La sección nueva no puede salir como «fija»';
    END IF;
    IF (v_fila ->> 'cuantas')::integer <> 0 OR (v_fila ->> 'con_contenido')::boolean THEN
        RAISE EXCEPTION 'Recién creada tendría que estar vacía y dice % productos',
              v_fila ->> 'cuantas';
    END IF;
    IF (v_fila ->> 'orden')::integer <> v_orden THEN
        RAISE EXCEPTION 'La sección nueva tendría que quedar la última (orden %) y quedó en %',
              v_orden, v_fila ->> 'orden';
    END IF;
    IF v_renombre IS DISTINCT FROM 'ZZ renombrada' THEN
        RAISE EXCEPTION 'Renombrar la sección no renombró su fila de la portada: «%»', v_renombre;
    END IF;
    IF v_papelera IS NULL OR v_papelera <> v_antes THEN
        RAISE EXCEPTION 'En la papelera tendría que desaparecer de la portada (% filas, esperaba %)',
              v_papelera, v_antes;
    END IF;
    IF v_publica IS NULL OR v_publica <> 0 THEN
        RAISE EXCEPTION 'Una sección en la papelera no puede salir en la portada pública';
    END IF;
    IF v_vuelta IS NULL OR v_vuelta <> v_antes + 1 THEN
        RAISE EXCEPTION 'Al restaurarla tendría que volver a la portada (% filas, esperaba %)',
              v_vuelta, v_antes + 1;
    END IF;
    IF EXISTS (SELECT 1 FROM ecommerce.inicio_secciones WHERE clave = v_clave) THEN
        RAISE EXCEPTION 'La fila de prueba se quedó en la portada';
    END IF;

    RAISE NOTICE 'Comprobado: la sección nueva entra en la portada la última y con su fuente, renombrarla renombra su fila, la papelera la esconde —también en la pública— y restaurarla la devuelve. La portada tiene % secciones y no quedó nada de la prueba.', v_antes;
END
$comprobar$;

COMMIT;
