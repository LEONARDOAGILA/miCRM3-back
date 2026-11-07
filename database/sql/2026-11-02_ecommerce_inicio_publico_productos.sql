-- ============================================================================
-- ECOMMERCE · LAS SECCIONES DE PRODUCTOS, EN LA PORTADA PÚBLICA
-- ============================================================================
-- Fecha: 2026-11-02
--
-- Las secciones de productos ya se administran en «Inicio de la tienda», pero
-- no salían en lo que lee la tienda. Ahora sí: con la FOTO Y EL NOMBRE de cada
-- producto, y nada más.
--
-- NADA MÁS, A PROPÓSITO. La tarjeta de la tienda lleva precio, precio
-- anterior, descuento, existencias, «destacado» y los botones de comprar, y de
-- eso el catálogo todavía no tiene nada: mandar la tarjeta a medias sacaría
-- todos los productos «Agotado» y a $0. La foto y el nombre sí están, y eso es
-- lo que se pinta mientras llega el resto.
--
-- LA CLAVE QUE VIAJA ES `productos`, NO `seccion_7`. La tienda conmuta por la
-- clave para saber qué pieza pintar, y una clave distinta por sección le
-- obligaría a adivinar. `productos` dice QUÉ ES —una sección de productos— y
-- el `id` dice CUÁL, que es lo que hace falta para distinguirlas.
--
-- QUÉ PRODUCTOS SALEN: los de la sección, en su orden, sin los que estén en la
-- papelera del catálogo y sin los APAGADOS. Un producto inactivo no se vende,
-- así que enseñarlo sería ofrecer algo que no se puede comprar; el CRM ya lo
-- avisa en la rejilla, con su aspa roja y «la tienda no lo enseñaría».
--
-- DE LA FOTO VIAJA EL NOMBRE DEL FICHERO, no la dirección: la arma el
-- controlador, como con las galerías y los logos de marca. En la base no se
-- guarda ninguna dirección completa, que es lo que dejó al CRM viejo lleno de
-- imágenes rotas apuntando a una máquina que ya no estaba.
--
-- Idempotente.
-- ============================================================================
\set ON_ERROR_STOP on

BEGIN;

-- ----------------------------------------------------------------------------
-- 1. LOS PRODUCTOS DE UNA SECCIÓN, PARA LA TIENDA
-- ----------------------------------------------------------------------------
-- Tres campos y ya: el id, el nombre y la foto. No se reutiliza
-- `fn_producto_seccion_productos` —la del CRM— porque ésa trae la ficha
-- entera del catálogo, con el costo dentro: lo que no se manda no se puede
-- filtrar luego por equivocación.
--
-- LA FOTO ES LA PRINCIPAL, y si no hay ninguna marcada, la primera de su
-- orden. Un producto sin fotos viaja con `imagen` en null y la tienda pinta su
-- hueco: quitarlo de la lista haría que el CRM dijera ocho y la tienda
-- enseñara seis, sin que nadie pueda saber por qué.
CREATE OR REPLACE FUNCTION ecommerce.fn_producto_seccion_publica(p_seccion_id bigint)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
AS $function$
    SELECT COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
                   'id',     p.id,
                   'nombre', p.nombre,
                   'imagen', (SELECT i.archivo
                                FROM inventarios.productos_imagenes i
                               WHERE i.producto_id = p.id
                               ORDER BY i.principal DESC, i.orden, i.id
                               LIMIT 1))
               ORDER BY it.orden, p.id)
          FROM ecommerce.producto_secciones_items it
          JOIN inventarios.productos p ON p.id = it.producto_id
         WHERE it.seccion_id = p_seccion_id
           AND p.deleted_at IS NULL
           AND p.activo), '[]'::jsonb);
$function$;

-- ----------------------------------------------------------------------------
-- 2. LA PORTADA PÚBLICA
-- ----------------------------------------------------------------------------
-- Se reescribe entera y no con cirugía: el CASE pasa de conmutar por la clave
-- a ser un CASE buscado, porque la rama de productos no se reconoce por la
-- clave sino por a quién apunta. Cambiar ocho ramas con `replace` es más
-- frágil que escribirlas.
CREATE OR REPLACE FUNCTION ecommerce.fn_inicio_publico()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
AS $function$
    WITH visibles AS (
        SELECT s.clave, s.hasta, s.orden, s.producto_seccion_id,
               nullif(btrim(COALESCE(s.titulo, '')), '')    AS titulo,
               nullif(btrim(COALESCE(s.subtitulo, '')), '') AS subtitulo,
               ecommerce.fn_rotulo_estilo(s.rotulo_tamano, s.rotulo_color, s.rotulo_fuente) AS estilo,
               COALESCE(nullif(btrim(COALESCE(s.alto, '')), ''), 'normal') AS alto
          FROM ecommerce.inicio_secciones s
         WHERE s.activo AND ecommerce.fn_vigente(s.desde, s.hasta)
           AND ecommerce.fn_inicio_seccion_viva(s.producto_seccion_id)
    ),
    armadas AS (
        SELECT v.orden, v.titulo, v.subtitulo, v.estilo, v.alto,
               CASE
                   -- Las de productos van primero y se reconocen por a quién
                   -- apuntan: su clave (`seccion_7`) la fabrica el servidor y
                   -- no hay lista donde buscarla.
                   WHEN v.producto_seccion_id IS NOT NULL THEN
                        jsonb_build_object('clave', 'productos',
                            'id', v.producto_seccion_id,
                            'productos', ecommerce.fn_producto_seccion_publica(v.producto_seccion_id))
                   WHEN v.clave = 'banner_principal' THEN
                        jsonb_build_object('clave', v.clave,
                            'imagenes', COALESCE(ecommerce.fn_galerias_publica('inicio_banner') -> 'imagenes', '[]'::jsonb))
                   WHEN v.clave = 'banner_simple' THEN
                        jsonb_build_object('clave', v.clave,
                            'imagenes', COALESCE(ecommerce.fn_galerias_publica('inicio_banner_simple') -> 'imagenes', '[]'::jsonb))
                   WHEN v.clave = 'mosaico' THEN
                        jsonb_build_object('clave', v.clave,
                            'categorias', ecommerce.fn_categorias_promocion_publicas())
                   WHEN v.clave = 'categorias_destacadas' THEN
                        jsonb_build_object('clave', v.clave,
                            'categorias', ecommerce.fn_categorias_destacadas_publicas())
                   WHEN v.clave = 'marcas' THEN
                        jsonb_build_object('clave', v.clave,
                            'marcas', ecommerce.fn_marcas_publicas())
                   -- Las demás todavía no tienen de dónde sacar datos. Se
                   -- devuelven NULL y se caen en el filtro de abajo; la tienda
                   -- ni se entera.
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
       AND (a.seccion -> 'marcas'     IS NULL OR jsonb_array_length(a.seccion -> 'marcas') > 0)
       -- Una sección de productos vacía no se manda: dejaría su título y nada
       -- debajo, que es peor que no estar.
       AND (a.seccion -> 'productos'  IS NULL OR jsonb_array_length(a.seccion -> 'productos') > 0);
$function$;

-- ----------------------------------------------------------------------------
-- 3. COMPROBACIÓN
-- ----------------------------------------------------------------------------
-- Se crea una sección, se le mete un producto, se mira que salga en la portada
-- pública con su foto y su nombre; se apaga el producto y se mira que la
-- sección se caiga entera. Y se deshace con el truco de la subtransacción
-- (P0099, que no usa nadie: con P0001 el handler se tragaría un fallo de
-- verdad y las comparaciones darían NULL, que no es TRUE).
DO $comprobar$
DECLARE
    v_id        bigint;
    v_p         bigint;
    v_antes     integer;
    v_con       integer;
    v_seccion   jsonb;
    v_producto  jsonb;
    v_apagado   integer;
    v_claves    text;
BEGIN
    -- Un producto activo, con foto si lo hay: así la comprobación mira la foto
    SELECT p.id INTO v_p
      FROM inventarios.productos p
     WHERE p.deleted_at IS NULL AND p.activo
     ORDER BY (EXISTS (SELECT 1 FROM inventarios.productos_imagenes i WHERE i.producto_id = p.id)) DESC,
              p.id
     LIMIT 1;

    IF v_p IS NULL THEN
        RAISE NOTICE 'No hay productos activos con los que comprobar; las funciones están.';
        RETURN;
    END IF;

    SELECT jsonb_array_length(ecommerce.fn_inicio_publico() -> 'secciones') INTO v_antes;

    BEGIN
        v_id := (ecommerce.fn_producto_secciones_crear('ZZ publica ' || clock_timestamp())
                 -> 'data' ->> 'id')::bigint;

        -- Vacía no sale: dejaría su título y nada debajo
        SELECT jsonb_array_length(ecommerce.fn_inicio_publico() -> 'secciones') INTO v_con;
        IF v_con <> v_antes THEN
            RAISE EXCEPTION 'Una sección vacía no puede salir en la portada pública (% vs %)',
                  v_con, v_antes;
        END IF;

        PERFORM ecommerce.fn_producto_seccion_agregar(v_id, jsonb_build_array(v_p));

        SELECT x INTO v_seccion
          FROM jsonb_array_elements(ecommerce.fn_inicio_publico() -> 'secciones') x
         WHERE (x ->> 'id')::bigint = v_id AND x ->> 'clave' = 'productos';

        v_producto := v_seccion -> 'productos' -> 0;
        v_claves := (SELECT string_agg(k, ',' ORDER BY k) FROM jsonb_object_keys(v_producto) k);

        -- Con el producto apagado, la sección se queda sin nada y se cae
        UPDATE inventarios.productos SET activo = false WHERE id = v_p;
        SELECT count(*) INTO v_apagado
          FROM jsonb_array_elements(ecommerce.fn_inicio_publico() -> 'secciones') x
         WHERE (x ->> 'id')::bigint = v_id;

        RAISE EXCEPTION 'deshacer' USING ERRCODE = 'P0099';
    EXCEPTION WHEN SQLSTATE 'P0099' THEN
        NULL;
    END;

    IF v_seccion IS NULL THEN
        RAISE EXCEPTION 'La sección con un producto no salió en la portada pública';
    END IF;
    IF v_seccion ->> 'clave' <> 'productos' THEN
        RAISE EXCEPTION 'La clave que viaja tendría que ser «productos» y es «%»',
              v_seccion ->> 'clave';
    END IF;
    IF v_producto IS NULL OR (v_producto ->> 'id')::bigint <> v_p THEN
        RAISE EXCEPTION 'No salió el producto que se metió (% vs %)', v_producto ->> 'id', v_p;
    END IF;
    -- Ni un campo de más: lo que no se manda no se puede enseñar por error
    IF v_claves IS DISTINCT FROM 'id,imagen,nombre' THEN
        RAISE EXCEPTION 'El producto tendría que viajar con id, nombre e imagen y viaja con: %', v_claves;
    END IF;
    IF (v_producto ->> 'imagen') LIKE 'http%' THEN
        RAISE EXCEPTION 'De la foto viaja el nombre del fichero, no la dirección: %',
              v_producto ->> 'imagen';
    END IF;
    IF v_apagado IS NULL OR v_apagado <> 0 THEN
        RAISE EXCEPTION 'Con su único producto apagado, la sección no puede seguir saliendo';
    END IF;
    IF EXISTS (SELECT 1 FROM ecommerce.producto_secciones WHERE id = v_id) THEN
        RAISE EXCEPTION 'La sección de prueba se quedó en la tabla';
    END IF;

    RAISE NOTICE 'Comprobado: la sección sale como «productos» con id, nombre y la foto en nombre de fichero; vacía o con todo apagado no sale. Producto de prueba: %. No quedó nada.', v_p;
END
$comprobar$;

COMMIT;
