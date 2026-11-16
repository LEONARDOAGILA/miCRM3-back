-- ============================================================================
-- ECOMMERCE · LA FICHA DE LA SECCIÓN, CON SU TIPO Y SU UNIDAD
-- ============================================================================
-- Fecha: 2026-11-07
--
-- La sección paginada de la portada arma sus filtros con la ficha de cada
-- producto: lo que esté lleno en el CRM, filtra. Hasta hoy de cada línea
-- viajaba sólo `nombre` y `valor`, y con eso la tienda no puede distinguir un
-- NÚMERO de un texto: «Potencia 600», «Kilometraje 24800» y «Color Negro» le
-- llegan igual, así que a los tres les pinta la misma lista de casillas.
--
-- Y UNA LISTA DE CASILLAS NO SIRVE PARA UN NÚMERO. Con el kilometraje cada
-- moto trae el suyo, así que serían doscientas casillas de un solo producto
-- cada una —la tienda, de hecho, las tira por pasarse de valores distintos— y
-- nadie puede pedir «de 0 a 30.000 km», que es lo único que se quiere pedir.
--
-- ASÍ QUE VIAJAN DOS COSAS MÁS, Y LAS DOS SALEN DEL DICCIONARIO
-- (`inventarios.caracteristicas_nombres`), que es donde ya se declaran:
--
--   · `tipo`    TEXTO | NUMERO | LISTA | SI_NO. Con NUMERO la tienda pinta
--     una barra de desde/hasta en vez de casillas. NO SE ADIVINA MIRANDO EL
--     VALOR a propósito: «Canales» vale 2.0 / 2.1 / 5.1 y parece un número,
--     pero es un texto —no existe el 2.5— y en casillas se lee mejor. Quien
--     sabe eso es quien creó la característica, y lo dijo ahí.
--
--   · `unidad`  W, km, litros, pulgadas… Para rotular la barra: «de 0 a
--     30.000 km». SIGUE SIN IR PEGADA AL VALOR, que es lo de siempre: si el
--     valor fuera «1500 W» y «1500», serían dos filtros distintos.
--
-- Una característica escrita a mano, de las que no están en el diccionario
-- (`nombre_id` nulo), sale con `tipo` y `unidad` en null: la tienda la trata
-- como texto, que es lo que ha hecho hasta hoy.
--
-- LO DEMÁS DE LA FUNCIÓN NO SE TOCA. Es la misma de antes con dos claves más
-- en cada línea de la ficha, así que la tienda de hoy sigue funcionando sin
-- cambiar nada: las lee quien las entiende.
--
-- Idempotente: es un CREATE OR REPLACE y se puede volver a correr.
-- ============================================================================

BEGIN;

CREATE OR REPLACE FUNCTION ecommerce.fn_producto_seccion_publica(p_seccion_id bigint)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
AS $funcion$
    SELECT COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
                   -- `id` es además la REFERENCIA que se lee en la tarjeta
                   'id',     p.id,
                   'nombre', p.nombre,
                   -- La del catálogo. La tienda la usa SÓLO para saber si el
                   -- producto es una moto y enseñar nada más el botón de
                   -- WhatsApp; no se pinta en ningún sitio.
                   'categoria_id', p.categoria_id,
                   -- Y su nombre, que SÍ se pinta: es un filtro de la sección
                   -- paginada. El de la tienda si se le puso otro.
                   'categoria', nullif(btrim(COALESCE(cw.nombre_web, cat.nombre, '')), ''),
                   -- La marca, para la pastilla de debajo del nombre. Van el
                   -- nombre Y el fichero del logo: casi ninguna marca tiene
                   -- logo todavía, y sin el nombre esas tarjetas se quedarían
                   -- con un hueco. Además es lo que describe al logo para
                   -- quien no ve la pantalla.
                   'marca',       nullif(btrim(COALESCE(m.nombre, '')), ''),
                   'marca_logo',  nullif(btrim(COALESCE(m.logo, '')), ''),
                   -- Lo que se llenó de su ficha, para los filtros de la
                   -- sección paginada: sólo las que tienen valor, en el orden
                   -- de la plantilla de su categoría
                   'caracteristicas', COALESCE(fichas.lista, '[]'::jsonb),
                   -- Las dos primeras de su galería, en el mismo orden con el
                   -- que se eligen en el CRM. Una sola consulta con LIMIT 2 y
                   -- no dos subconsultas: así no hay forma de que la «segunda»
                   -- acabe siendo la misma que la primera.
                   'imagen',             fotos.primera,
                   'imagen_secundaria',  fotos.segunda)
               ORDER BY it.orden, p.id)
          FROM ecommerce.producto_secciones_items it
          JOIN inventarios.productos p ON p.id = it.producto_id
          -- LEFT: un producto sin marca sigue siendo un producto y su tarjeta
          -- tiene que salir igual
          LEFT JOIN inventarios.marcas m ON m.id = p.marca_id AND m.deleted_at IS NULL
          LEFT JOIN inventarios.categorias cat ON cat.id = p.categoria_id AND cat.deleted_at IS NULL
          LEFT JOIN ecommerce.categorias_web cw ON cw.categoria_id = p.categoria_id
          LEFT JOIN LATERAL (
              SELECT jsonb_agg(jsonb_build_object(
                         'nombre', c.nombre,
                         'valor',  btrim(c.valor),
                         -- Del diccionario, no del valor. LEFT: una escrita a
                         -- mano no está en él y sale en null, que la tienda
                         -- lee como texto
                         'tipo',   nullif(btrim(upper(COALESCE(dic.tipo, ''))), ''),
                         'unidad', nullif(btrim(COALESCE(dic.unidad, '')), ''))
                     ORDER BY c.orden, c.id) AS lista
                FROM inventarios.caracteristicas_productos c
                LEFT JOIN inventarios.caracteristicas_nombres dic
                       ON dic.id = c.nombre_id AND dic.deleted_at IS NULL
               WHERE c.producto_id = p.id
                 AND nullif(btrim(COALESCE(c.valor, '')), '') IS NOT NULL
                 AND nullif(btrim(COALESCE(c.nombre, '')), '') IS NOT NULL
          ) fichas ON true
          LEFT JOIN LATERAL (
              SELECT min(g.archivo) FILTER (WHERE g.puesto = 1) AS primera,
                     min(g.archivo) FILTER (WHERE g.puesto = 2) AS segunda
                FROM (SELECT i.archivo,
                             row_number() OVER (ORDER BY i.principal DESC, i.orden, i.id) AS puesto
                        FROM inventarios.productos_imagenes i
                       WHERE i.producto_id = p.id) g
               WHERE g.puesto <= 2
          ) fotos ON true
         WHERE it.seccion_id = p_seccion_id
           AND p.deleted_at IS NULL
           AND p.activo), '[]'::jsonb);
$funcion$;

COMMENT ON FUNCTION ecommerce.fn_producto_seccion_publica(bigint) IS
'Los productos de una sección del inicio, para la tienda. Cada línea de la ficha lleva nombre, valor, tipo y unidad: con tipo = NUMERO la tienda filtra por rango en vez de por casillas.';

-- ----------------------------------------------------------------------------
-- COMPROBACIÓN (sólo lee)
-- ----------------------------------------------------------------------------
DO $comprobar$
DECLARE
    v_seccion    bigint;
    v_lista      jsonb;
    v_fichas     jsonb;
    v_numeros    int;
    v_sin_claves int;
BEGIN
    -- La sección con más productos: es la que de verdad tiene fichas llenas
    SELECT it.seccion_id INTO v_seccion
      FROM ecommerce.producto_secciones_items it
     GROUP BY it.seccion_id
     ORDER BY count(*) DESC
     LIMIT 1;

    IF v_seccion IS NULL THEN
        RAISE NOTICE 'No hay ninguna sección con productos: no hay nada que comprobar.';
        RETURN;
    END IF;

    v_lista := ecommerce.fn_producto_seccion_publica(v_seccion);

    IF jsonb_typeof(v_lista) <> 'array' OR jsonb_array_length(v_lista) = 0 THEN
        RAISE EXCEPTION 'La sección % no devolvió productos', v_seccion;
    END IF;

    -- Todas las líneas de ficha de todos los productos de la sección
    SELECT COALESCE(jsonb_agg(c), '[]'::jsonb) INTO v_fichas
      FROM jsonb_array_elements(v_lista) prod,
           jsonb_array_elements(prod -> 'caracteristicas') c;

    -- 1. Las cuatro claves, en todas
    SELECT count(*) INTO v_sin_claves
      FROM jsonb_array_elements(v_fichas) c
     WHERE NOT (c ? 'nombre' AND c ? 'valor' AND c ? 'tipo' AND c ? 'unidad');

    IF v_sin_claves > 0 THEN
        RAISE EXCEPTION 'A % líneas de la ficha les falta alguna de las cuatro claves', v_sin_claves;
    END IF;

    -- 2. Y el tipo tiene que venir del diccionario de verdad: si saliera todo
    --    en null, la tienda no pintaría ni un rango y esto habría sido un
    --    cambio sin efecto
    SELECT count(*) INTO v_numeros
      FROM jsonb_array_elements(v_fichas) c
     WHERE c ->> 'tipo' = 'NUMERO';

    IF v_numeros = 0 THEN
        RAISE EXCEPTION 'Ninguna línea de la sección % salió como NUMERO: el diccionario no está llegando', v_seccion;
    END IF;

    -- 3. Lo de antes sigue entero: nombre y valor con algo dentro
    IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_fichas) c
                WHERE COALESCE(c ->> 'nombre', '') = '' OR COALESCE(c ->> 'valor', '') = '') THEN
        RAISE EXCEPTION 'Alguna línea de la ficha salió sin nombre o sin valor';
    END IF;

    RAISE NOTICE 'Comprobado en la sección %: % líneas de ficha, % de ellas NUMERO, todas con tipo y unidad.',
          v_seccion, jsonb_array_length(v_fichas), v_numeros;
END
$comprobar$;

COMMIT;
