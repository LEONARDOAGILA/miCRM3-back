-- ============================================================================
-- ECOMMERCE · CATEGORÍAS DESTACADAS: EN CÍRCULO O EN CUADRO
-- ============================================================================
-- Fecha: 2026-11-05
--
-- Las categorías destacadas se han enseñado siempre en círculos con el nombre
-- debajo. Ahora se puede elegir:
--
--   · `circulo`  — lo de siempre: la foto recortada en redondo y el nombre
--     debajo, en negro.
--   · `cuadrado` — una ficha ancha con la foto a todo el cuadro y el nombre
--     escrito ENCIMA, sobre una franja oscura al pie. Caben menos por fila,
--     porque cada una es mucho más ancha.
--
-- LA COLUMNA SE LLAMA `forma` Y NO `destacadas_forma`: es la forma de las
-- fichas de una sección, y si mañana otra sección quiere elegir la suya no
-- hará falta una segunda columna que signifique lo mismo. Hoy sólo la mira
-- «Categorías destacadas», que es la única que tiene dos maneras de pintarse.
--
-- NULL ES 'circulo', y se resuelve en la base: que la pantalla y la tienda
-- tengan que acordarse cada una de que «vacío es círculo» es la manera de que
-- un día una de las dos se olvide.
--
-- De paso, la etiqueta de los segundos deja de decir «del banner»: desde esta
-- mañana también son de las secciones de productos.
--
-- Idempotente.
-- ============================================================================
\set ON_ERROR_STOP on

BEGIN;

-- ----------------------------------------------------------------------------
-- 1. LA COLUMNA
-- ----------------------------------------------------------------------------
ALTER TABLE ecommerce.inicio_secciones
    ADD COLUMN IF NOT EXISTS forma varchar(10);

DO $reglas$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'ck_inicio_secciones_forma') THEN
        ALTER TABLE ecommerce.inicio_secciones
            ADD CONSTRAINT ck_inicio_secciones_forma
            CHECK (forma IS NULL OR forma IN ('circulo', 'cuadrado'));
    END IF;
END
$reglas$;

COMMENT ON COLUMN ecommerce.inicio_secciones.forma IS
    'La forma de las fichas de la sección: circulo o cuadrado. NULL = circulo. Hoy sólo la miran las categorías destacadas.';

-- ----------------------------------------------------------------------------
-- 2. GUARDAR
-- ----------------------------------------------------------------------------
DO $guardar$
DECLARE
    def   text;
    viejo text := E'                               ''Los segundos del banner'', 2, 60),';
    nuevo text := E'                               ''Los segundos de la sección'', 2, 60),';
BEGIN
    SELECT pg_get_functiondef(p.oid) INTO def
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'ecommerce' AND p.proname = 'fn_inicio_seccion_guardar';

    IF def IS NULL THEN
        RAISE EXCEPTION 'No está ecommerce.fn_inicio_seccion_guardar';
    END IF;

    IF strpos(def, 'forma         = ecommerce.fn_validar_opcion') > 0 THEN
        RAISE NOTICE 'Guardar ya aceptaba la forma: no lo toco.';
        RETURN;
    END IF;

    IF strpos(def, viejo) = 0 THEN
        RAISE EXCEPTION 'No encontré dónde añadir la forma: ¿cambió fn_inicio_seccion_guardar?';
    END IF;

    def := replace(def, viejo, nuevo
        || E'\n           -- En qué forma se pintan sus fichas. Hoy sólo las destacadas.'
        || E'\n           forma         = ecommerce.fn_validar_opcion(p_datos ->> ''forma'','
        || E'\n                               ARRAY[''circulo'', ''cuadrado''], ''La forma de las categorías''),');

    EXECUTE def;
    RAISE NOTICE 'Guardar ya acepta la forma.';
END
$guardar$;

-- ----------------------------------------------------------------------------
-- 3. EL LISTADO DEL CRM
-- ----------------------------------------------------------------------------
-- Resuelta, como `banner_vista`: la pantalla no tiene por qué saber que vacío
-- es círculo.
DO $listar$
DECLARE
    def   text;
    ancla text := E'                       ''segundos'', s.segundos,';
BEGIN
    SELECT pg_get_functiondef(p.oid) INTO def
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'ecommerce' AND p.proname = 'fn_inicio_listar';

    IF def IS NULL THEN
        RAISE EXCEPTION 'No está ecommerce.fn_inicio_listar';
    END IF;

    IF strpos(def, E'''forma'', COALESCE') > 0 THEN
        RAISE NOTICE 'El listado ya traía la forma: no lo toco.';
        RETURN;
    END IF;

    IF strpos(def, ancla) = 0 THEN
        RAISE EXCEPTION 'No encontré dónde añadir la forma: ¿cambió fn_inicio_listar?';
    END IF;

    def := replace(def, ancla, ancla
        || E'\n                       ''forma'', COALESCE(nullif(btrim(COALESCE(s.forma, '''')), ''''), ''circulo''),');

    EXECUTE def;
    RAISE NOTICE 'El listado del CRM ya trae la forma.';
END
$listar$;

-- ----------------------------------------------------------------------------
-- 4. LO QUE RECIBE LA TIENDA
-- ----------------------------------------------------------------------------
DO $publico$
DECLARE
    def           text;
    anclaVisibles text := E'               s.segundos,';
    anclaDestacadas text := E'                            ''categorias'', ecommerce.fn_categorias_destacadas_publicas())';
BEGIN
    SELECT pg_get_functiondef(p.oid) INTO def
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'ecommerce' AND p.proname = 'fn_inicio_publico';

    IF def IS NULL THEN
        RAISE EXCEPTION 'No está ecommerce.fn_inicio_publico';
    END IF;

    IF strpos(def, E'''forma'', v.forma') > 0 THEN
        RAISE NOTICE 'La tienda ya recibía la forma: no la toco.';
        RETURN;
    END IF;

    IF strpos(def, anclaVisibles) = 0 OR strpos(def, anclaDestacadas) = 0 THEN
        RAISE EXCEPTION 'No encontré dónde añadir la forma: ¿cambió fn_inicio_publico?';
    END IF;

    def := replace(def, anclaVisibles, anclaVisibles
        || E'\n               COALESCE(nullif(btrim(COALESCE(s.forma, '''')), ''''), ''circulo'') AS forma,');

    def := replace(def, anclaDestacadas,
           E'                            -- En círculo (lo de siempre) o en cuadros con el nombre encima\n'
        || E'                            ''forma'', v.forma,\n' || anclaDestacadas);

    EXECUTE def;
    RAISE NOTICE 'La tienda ya recibe la forma de las destacadas.';
END
$publico$;

-- ----------------------------------------------------------------------------
-- 5. COMPROBACIÓN
-- ----------------------------------------------------------------------------
DO $comprobar$
DECLARE
    v_antes   text;
    v_crm     jsonb;
    v_tienda  jsonb;
    v_vuelta  jsonb;
    v_malo    text := NULL;
BEGIN
    SELECT forma INTO v_antes FROM ecommerce.inicio_secciones WHERE clave = 'categorias_destacadas';

    BEGIN
        PERFORM ecommerce.fn_inicio_seccion_guardar('categorias_destacadas',
                jsonb_build_object('forma', 'cuadrado'));

        SELECT x INTO v_crm
          FROM jsonb_array_elements(ecommerce.fn_inicio_listar() -> 'data') x
         WHERE x ->> 'clave' = 'categorias_destacadas';

        SELECT x INTO v_tienda
          FROM jsonb_array_elements(ecommerce.fn_inicio_publico() -> 'secciones') x
         WHERE x ->> 'clave' = 'categorias_destacadas';

        -- Vaciarla devuelve el círculo
        PERFORM ecommerce.fn_inicio_seccion_guardar('categorias_destacadas',
                jsonb_build_object('forma', ''));

        SELECT x INTO v_vuelta
          FROM jsonb_array_elements(ecommerce.fn_inicio_publico() -> 'secciones') x
         WHERE x ->> 'clave' = 'categorias_destacadas';

        -- Un triángulo no entra
        BEGIN
            PERFORM ecommerce.fn_inicio_seccion_guardar('categorias_destacadas',
                    jsonb_build_object('forma', 'triangulo'));
            v_malo := 'entró una forma que no existe';
        EXCEPTION WHEN SQLSTATE 'P0015' THEN
            NULL;
        END;

        RAISE EXCEPTION 'deshacer' USING ERRCODE = 'P0099';
    EXCEPTION WHEN SQLSTATE 'P0099' THEN
        NULL;
    END;

    IF v_crm ->> 'forma' <> 'cuadrado' THEN
        RAISE EXCEPTION 'El CRM no lee la forma: %', v_crm -> 'forma';
    END IF;
    IF v_tienda ->> 'forma' <> 'cuadrado' THEN
        RAISE EXCEPTION 'La tienda no la recibe: %', v_tienda -> 'forma';
    END IF;
    IF v_vuelta ->> 'forma' <> 'circulo' THEN
        RAISE EXCEPTION 'Vaciarla tendría que devolver el círculo, y salió %', v_vuelta -> 'forma';
    END IF;
    IF v_malo IS NOT NULL THEN
        RAISE EXCEPTION '%', v_malo;
    END IF;
    IF (SELECT forma FROM ecommerce.inicio_secciones WHERE clave = 'categorias_destacadas')
       IS DISTINCT FROM v_antes THEN
        RAISE EXCEPTION 'Las categorías destacadas se quedaron cambiadas';
    END IF;

    RAISE NOTICE 'Comprobado: la forma se guarda, la leen el CRM y la tienda, vaciarla devuelve el círculo y un «triangulo» no entra. Las destacadas quedaron como estaban.';
END
$comprobar$;

COMMIT;
