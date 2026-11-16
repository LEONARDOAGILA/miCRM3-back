-- ===========================================================================
-- ORDEN DE ESQUEMAS: SUCURSALES A CORE, BODEGAS A INVENTARIOS
-- ===========================================================================
-- UNA TABLA, UN ESQUEMA, Y EL ESQUEMA ES EL MÓDULO DUEÑO DEL DATO.
--
--   · Las SUCURSALES son la estructura de la empresa: las usan ventas, rh,
--     inventarios y contabilidad. Tenerlas en `ventas` obligaba a que
--     recursos humanos dependiera del esquema de ventas (rh.empleados y
--     rh.empleados_marcacion_sucursal apuntan a ellas). Se van a `core`.
--
--   · Las BODEGAS son sitios donde hay stock: nacen y mueren con el
--     inventario. Se van a `inventarios`, al lado de los productos.
--
--   · `core.sucursales` era un cascarón: 0 filas, 0 funciones y un solo FK
--     que le apuntaba (desde core.bodegas, también vacía). No es un
--     conflicto que haya que fusionar, es un cadáver: se borra.
--
-- LO QUE SE MUEVE SOLO (no hay que tocarlo):
--   ALTER TABLE ... SET SCHEMA se lleva datos, índices, constraints, los
--   triggers y la secuencia propia; y los FK que apuntan a la tabla siguen
--   funcionando porque Postgres los sigue por OID, no por nombre. Así que
--   rh.empleados, ventas.proformas y core.puntos_venta ni se enteran.
--
-- LO QUE HAY QUE REHACER A MANO:
--   Las funciones que escriben `ventas.sucursales` en el cuerpo. El ALTER no
--   se queja —el cuerpo de una función es texto— y la rotura aparece el día
--   que alguien abre la pantalla. Por eso se regeneran aquí mismo, en el
--   mismo golpe, volcándolas con pg_get_functiondef.
--
-- Son 36 cuerpos: 15 en ventas, 10 en rh, 8 en core y 3 en contabilidad.
-- ===========================================================================
\set ON_ERROR_STOP on

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. EL CADÁVER
-- ---------------------------------------------------------------------------
ALTER TABLE core.bodegas DROP CONSTRAINT IF EXISTS fk_sucursales_bodegas_id;
DROP TABLE IF EXISTS core.sucursales;

-- ---------------------------------------------------------------------------
-- 2. LA TABLA VIVA, A CORE
-- ---------------------------------------------------------------------------
ALTER TABLE ventas.sucursales SET SCHEMA core;

-- ---------------------------------------------------------------------------
-- 3. LAS BODEGAS, A INVENTARIOS
-- ---------------------------------------------------------------------------
ALTER TABLE core.bodegas SET SCHEMA inventarios;

-- El FK vuelve, ahora a la sucursal de verdad. Y con nombre nuevo: el viejo
-- (fk_sucursales_bodegas_id) decía al revés quién apunta a quién.
ALTER TABLE inventarios.bodegas
  ADD CONSTRAINT fk_bodegas_sucursal
      FOREIGN KEY (sucursal_id) REFERENCES core.sucursales(id);

-- ---------------------------------------------------------------------------
-- 4. LAS FUNCIONES DEL MÓDULO SE VAN CON SU TABLA
-- ---------------------------------------------------------------------------
-- Las 17 `fn_sucursales_*` son el módulo de sucursales. Dejarlas en `ventas`
-- con la tabla en `core` sería cambiar un desorden por otro.
DO $mover$
DECLARE r record;
BEGIN
    FOR r IN SELECT p.oid::regprocedure AS firma
               FROM pg_proc p
               JOIN pg_namespace n ON n.oid = p.pronamespace
              WHERE n.nspname = 'ventas'
                AND p.proname LIKE 'fn_sucursales%'
              ORDER BY 1
    LOOP
        EXECUTE format('ALTER FUNCTION %s SET SCHEMA core', r.firma);
        RAISE NOTICE 'movida a core: %', r.firma;
    END LOOP;
END
$mover$;

-- ---------------------------------------------------------------------------
-- 5. Y LOS CUERPOS QUE LAS NOMBRABAN
-- ---------------------------------------------------------------------------
-- Se vuelca cada función con pg_get_functiondef, se cambia el nombre viejo
-- por el nuevo y se vuelve a crear. `CREATE OR REPLACE` la sustituye en su
-- sitio, así que no hace falta borrar nada ni se pierden permisos.
--
-- Los dos textos no se solapan ('ventas.sucursales' no es parte de
-- 'ventas.fn_sucursales'), así que el orden de los reemplazos da igual.
--
-- Al search_path se le ANTEPONE 'core' en vez de quitarle 'ventas': las
-- funciones movidas pueden nombrar sin calificar cosas que siguen en ventas,
-- y quitándolo se romperían en silencio. Anteponer es seguro porque después
-- de esta migración no queda ningún nombre de tabla repetido entre los dos
-- esquemas (el único era `sucursales`).
DO $cuerpos$
DECLARE
    r       record;
    def     text;
    cuantas integer := 0;
BEGIN
    FOR r IN SELECT p.oid
               FROM pg_proc p
               JOIN pg_namespace n ON n.oid = p.pronamespace
              WHERE n.nspname NOT IN ('pg_catalog', 'information_schema')
                AND (p.prosrc LIKE '%ventas.sucursales%'
                  OR p.prosrc LIKE '%ventas.fn_sucursales%')
    LOOP
        def := pg_get_functiondef(r.oid);
        def := replace(def, 'ventas.sucursales',    'core.sucursales');
        def := replace(def, 'ventas.fn_sucursales', 'core.fn_sucursales');
        def := replace(def,
                       'SET search_path TO ''pg_catalog'', ''ventas''',
                       'SET search_path TO ''pg_catalog'', ''core'', ''ventas''');
        EXECUTE def;
        cuantas := cuantas + 1;
    END LOOP;
    RAISE NOTICE 'cuerpos regenerados: %', cuantas;
END
$cuerpos$;

-- ---------------------------------------------------------------------------
-- 6. QUE NO QUEDE NINGUNO
-- ---------------------------------------------------------------------------
DO $comprobar$
DECLARE pendientes integer;
BEGIN
    SELECT count(*) INTO pendientes
      FROM pg_proc p
      JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname NOT IN ('pg_catalog', 'information_schema')
       AND (p.prosrc LIKE '%ventas.sucursales%' OR p.prosrc LIKE '%ventas.fn_sucursales%');

    IF pendientes > 0 THEN
        RAISE EXCEPTION 'Quedan % funciones nombrando ventas.sucursales', pendientes;
    END IF;

    IF EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                WHERE n.nspname = 'ventas' AND p.proname LIKE 'fn_sucursales%') THEN
        RAISE EXCEPTION 'Quedan funciones fn_sucursales_* en el esquema ventas';
    END IF;
END
$comprobar$;

COMMENT ON TABLE core.sucursales   IS 'Sucursales de la empresa. En core porque las usan ventas, rh, inventarios y contabilidad.';
COMMENT ON TABLE inventarios.bodegas IS 'Bodegas: los sitios donde hay stock. En inventarios porque nacen y mueren con el inventario.';

COMMIT;
