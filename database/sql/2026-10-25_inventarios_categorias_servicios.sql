-- ===========================================================================
-- CATEGORÍAS DE SERVICIOS, PARA PROBAR QUE LAS CUENTAS CAMBIAN POR RAMA
-- ===========================================================================
-- Un servicio no se asienta como una mercadería: la venta va a «Prestación de
-- servicios» y no a «Venta de bienes», y su costo no sale de un inventario
-- —no hay nada que dar de baja— sino de lo que cuesta prestarlo.
--
-- Esto crea una rama «Servicios» con cuatro categorías y le pone SÓLO esas
-- dos cuentas en la raíz de la rama. Las cuatro de abajo no guardan nada: las
-- heredan. Y lo que no se toca —devoluciones, descuentos— sigue viniendo de
-- las cuentas por omisión, que es justo lo que había que poder comprobar.
--
-- Se puede volver a ejecutar: si la rama ya existe, no hace nada.
--
-- PARA BORRARLO después de mirarlo:
--   DELETE FROM contabilidad.cuentas_config
--    WHERE ambito = 'CATEGORIA'
--      AND ambito_id IN (SELECT id FROM inventarios.categorias WHERE created_by = 'datos-servicios');
--   DELETE FROM inventarios.categorias WHERE created_by = 'datos-servicios';
--   DELETE FROM contabilidad.plan_cuentas WHERE codigo = '5.1.02';
\set ON_ERROR_STOP on

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. LA CUENTA DE COSTO QUE LES FALTA
-- ---------------------------------------------------------------------------
-- El costo de un servicio no viene del inventario: son las horas, los
-- repuestos consumidos o lo que se le paga al técnico. Cuenta aparte, al lado
-- del costo de ventas de mercaderías.
INSERT INTO contabilidad.plan_cuentas
    (padre_id, orden, nivel, codigo, nombre, descripcion, tipo, naturaleza, es_movimiento, activo, created_by, updated_by)
SELECT p.id,
       (SELECT COALESCE(MAX(orden), 0) + 1 FROM contabilidad.plan_cuentas WHERE padre_id = p.id),
       p.nivel + 1,
       '5.1.02',
       'Costo de servicios prestados',
       'Lo que cuesta prestar el servicio: mano de obra, repuestos consumidos, subcontratos',
       p.tipo, 'DEUDORA', true, true, 'datos-servicios', 'datos-servicios'
  FROM contabilidad.plan_cuentas p
 WHERE p.codigo = '5.1'
   AND NOT EXISTS (SELECT 1 FROM contabilidad.plan_cuentas WHERE codigo = '5.1.02');

-- ---------------------------------------------------------------------------
-- 2. LA RAMA DE SERVICIOS
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    v_raiz bigint;
    v_fila record;
    v_n    integer := 0;
BEGIN
    IF EXISTS (SELECT 1 FROM inventarios.categorias
                WHERE UPPER(TRIM(nombre)) = 'SERVICIOS' AND padre_id IS NULL) THEN
        RAISE NOTICE 'La rama de Servicios ya existe: no se toca';
        RETURN;
    END IF;

    PERFORM set_config('app.usuario_login',  'datos-servicios', true);
    PERFORM set_config('app.usuario_nombre', 'Datos de servicios', true);

    -- La raíz AGRUPA: una categoría que admite productos no admite
    -- subcategorías, así que la de arriba tiene que nacer agrupando
    v_raiz := ((inventarios.fn_categorias_crear(
        'Servicios',
        NULL,
        'Lo que se vende sin entregar mercadería: se factura como un producto más, pero no mueve inventario',
        'fa-screwdriver-wrench',
        true,                       -- activa
        false,                      -- agrupa: de ella cuelgan categorías, no productos
        NULL, 'datos-servicios'))->'data'->>'id')::bigint;

    FOR v_fila IN
        SELECT * FROM (VALUES
            ('Instalación',         'fa-screwdriver-wrench',
             'Instalación y puesta en marcha de lo vendido'),
            ('Mantenimiento',       'fa-gears',
             'Mantenimiento preventivo y correctivo, con o sin contrato'),
            ('Garantía extendida',  'fa-shield-halved',
             'La garantía que se vende aparte de la del fabricante'),
            ('Capacitación',        'fa-chalkboard-user',
             'Formación al cliente sobre lo que se le vendió')
        ) AS s(nombre, icono, descripcion)
    LOOP
        PERFORM inventarios.fn_categorias_crear(
            v_fila.nombre, v_raiz, v_fila.descripcion, v_fila.icono,
            true,                   -- activa
            true,                   -- admite productos: aquí cuelgan los servicios
            NULL, 'datos-servicios');
        v_n := v_n + 1;
    END LOOP;

    RAISE NOTICE 'Rama de Servicios creada: 1 raíz y % categorías debajo', v_n;
END
$$;

-- ---------------------------------------------------------------------------
-- 3. SUS CUENTAS, EN LA RAÍZ DE LA RAMA
-- ---------------------------------------------------------------------------
-- Sólo las dos que cambian. Las cuatro categorías de abajo no guardan nada y
-- las heredan de aquí; el resto de conceptos siguen saliendo de las cuentas
-- por omisión.
DO $$
DECLARE
    v_raiz    bigint;
    v_ingreso bigint;
    v_costo   bigint;
BEGIN
    SELECT id INTO v_raiz FROM inventarios.categorias
     WHERE UPPER(TRIM(nombre)) = 'SERVICIOS' AND padre_id IS NULL AND deleted_at IS NULL;
    IF v_raiz IS NULL THEN
        RAISE NOTICE 'No encuentro la rama de Servicios: no se configuran cuentas';
        RETURN;
    END IF;

    SELECT id INTO v_ingreso FROM contabilidad.plan_cuentas WHERE codigo = '4.1.02' AND deleted_at IS NULL;
    SELECT id INTO v_costo   FROM contabilidad.plan_cuentas WHERE codigo = '5.1.02' AND deleted_at IS NULL;

    IF v_ingreso IS NULL OR v_costo IS NULL THEN
        RAISE EXCEPTION 'Faltan las cuentas de servicios (4.1.02 / 5.1.02)';
    END IF;

    PERFORM contabilidad.fn_cuentas_config_guardar(
        'CATEGORIA', v_raiz,
        jsonb_build_object('INGRESO', v_ingreso, 'COSTO', v_costo),
        NULL, 'datos-servicios');

    RAISE NOTICE 'Cuentas de la rama de Servicios: ingreso 4.1.02, costo 5.1.02';
END
$$;

COMMIT;
