-- ============================================================================
-- ECOMMERCE · FUERA LAS TRES SECCIONES QUE NUNCA TUVIERON DE DÓNDE SACAR DATOS
-- ============================================================================
-- Fecha: 2026-11-02
--
-- Se quitan de la portada:
--
--     bloques         «Bloques destacados»
--     ofertas_flash   «Ofertas flash» / «Ofertas de la semana»
--     grilla          «Grilla de productos» / «Todo para ti»
--
-- LAS TRES ERAN HUECOS. Nacieron en 2026-11-01 como «pendientes»: esperaban al
-- catálogo de la tienda y a la tabla de bloques, y mientras tanto
-- `fn_inicio_publico` las dejaba caer en su rama ELSE NULL. Nunca salieron de
-- aquí: la tienda jamás recibió una sección con ninguna de esas tres claves.
--
-- Y YA NO HACEN FALTA, que es lo que cambia hoy: las SECCIONES DE PRODUCTOS
-- («Productos por sección») hacen lo mismo y mejor —se arman a mano, se les
-- eligen los colores, llevan imagen al lado— y además funcionan. Tres filas
-- apagadas esperando algo que ya llegó por otro camino sólo sirven para que
-- quien abra la portada se pregunte por qué están apagadas.
--
-- NO SE TOCA `ecommerce.inicio_seccion` (la vieja, con prefijo `ise_`): es del
-- CRM anterior y de ahí salió la copia inicial. Lo que se hace es que la copia
-- NO las vuelva a traer, y eso está en el fichero que las copió
-- (2026-11-01_ecommerce_inicio.sql); si no, volver a pasarlo las resucitaría.
--
-- LAS TRES ESTABAN APAGADAS cuando se escribió esto, así que la tienda no
-- cambia en nada. Aun así el borrado va con su comprobación: si alguna
-- estuviera encendida, lo que desaparece es algo que alguien está mirando.
--
-- Idempotente.
-- ============================================================================
\set ON_ERROR_STOP on

BEGIN;

-- ----------------------------------------------------------------------------
-- 1. AVISO SI ALGUNA ESTABA ENCENDIDA
-- ----------------------------------------------------------------------------
-- No se impide: la tienda nunca las pintó, así que encendida o apagada da
-- igual de cara al cliente. Pero que quede en el registro de la ejecución.
DO $aviso$
DECLARE
    v text;
BEGIN
    SELECT string_agg(clave, ', ' ORDER BY clave) INTO v
      FROM ecommerce.inicio_secciones
     WHERE clave IN ('bloques', 'ofertas_flash', 'grilla') AND activo;

    IF v IS NOT NULL THEN
        RAISE NOTICE 'OJO: estaban encendidas (aunque la tienda no las pintaba): %', v;
    END IF;
END
$aviso$;

-- ----------------------------------------------------------------------------
-- 2. FUERA
-- ----------------------------------------------------------------------------
DELETE FROM ecommerce.inicio_secciones
 WHERE clave IN ('bloques', 'ofertas_flash', 'grilla');

-- El orden se compacta: no es obligatorio —la portada ordena por `orden` y los
-- huecos no molestan— pero deja la lista como la va a reescribir el primer
-- arrastre, y así no parece que falte algo.
WITH nuevo AS (
    SELECT clave, row_number() OVER (ORDER BY orden, id) AS n
      FROM ecommerce.inicio_secciones
)
UPDATE ecommerce.inicio_secciones s
   SET orden = nuevo.n
  FROM nuevo
 WHERE nuevo.clave = s.clave AND s.orden <> nuevo.n;

-- ----------------------------------------------------------------------------
-- 3. LA FUENTE DE CADA SECCIÓN, SIN LAS TRES
-- ----------------------------------------------------------------------------
-- Se reescribe entera y no por cirugía: lo que se quita son tres ramas
-- seguidas, y dejarlas ahí describiría secciones que ya no existen. El ELSE
-- sigue cubriendo cualquier clave que no se conozca.
CREATE OR REPLACE FUNCTION ecommerce.fn_inicio_fuente(
    p_clave text, p_producto_seccion_id bigint DEFAULT NULL::bigint)
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
        ELSE jsonb_build_object('tipo', 'pendiente', 'falta', 'su fuente')
    END;
$function$;

-- ----------------------------------------------------------------------------
-- 4. COMPROBACIÓN
-- ----------------------------------------------------------------------------
DO $comprobar$
DECLARE
    v_quedan   int;
    v_claves   text;
    v_orden    text;
    v_huecos   int;
    v_publicas text;
BEGIN
    SELECT count(*) INTO v_quedan
      FROM ecommerce.inicio_secciones
     WHERE clave IN ('bloques', 'ofertas_flash', 'grilla');
    IF v_quedan > 0 THEN
        RAISE EXCEPTION 'Quedan % de las tres secciones', v_quedan;
    END IF;

    -- Lo que ve el CRM: ni rastro de ellas y con el orden seguido
    SELECT string_agg(x ->> 'clave', ', ' ORDER BY (x ->> 'orden')::int),
           string_agg((x ->> 'orden'), ',' ORDER BY (x ->> 'orden')::int)
      INTO v_claves, v_orden
      FROM jsonb_array_elements(ecommerce.fn_inicio_listar() -> 'data') x;

    IF v_claves ~ '(bloques|ofertas_flash|grilla)' THEN
        RAISE EXCEPTION 'El listado del CRM todavía las trae: %', v_claves;
    END IF;

    SELECT count(*) INTO v_huecos
      FROM (SELECT orden, row_number() OVER (ORDER BY orden) AS n
              FROM ecommerce.inicio_secciones) t
     WHERE t.orden <> t.n;
    IF v_huecos > 0 THEN
        RAISE EXCEPTION 'El orden quedó con huecos: %', v_orden;
    END IF;

    -- Y la tienda sigue recibiendo lo mismo: nunca recibió esas tres
    SELECT string_agg(x ->> 'clave', ', ') INTO v_publicas
      FROM jsonb_array_elements(ecommerce.fn_inicio_publico() -> 'secciones') x;
    IF COALESCE(v_publicas, '') ~ '(bloques|ofertas_flash|grilla)' THEN
        RAISE EXCEPTION 'La portada pública las traía: %', v_publicas;
    END IF;

    -- Y la fuente ya no las conoce
    IF ecommerce.fn_inicio_fuente('ofertas_flash') ->> 'falta' <> 'su fuente' THEN
        RAISE EXCEPTION 'fn_inicio_fuente sigue sabiendo de ofertas_flash: %',
              ecommerce.fn_inicio_fuente('ofertas_flash');
    END IF;

    RAISE NOTICE 'Comprobado: las tres fuera, el orden seguido (%), el CRM ve «%» y la tienda «%».',
          v_orden, v_claves, COALESCE(v_publicas, '(ninguna)');
END
$comprobar$;

COMMIT;
