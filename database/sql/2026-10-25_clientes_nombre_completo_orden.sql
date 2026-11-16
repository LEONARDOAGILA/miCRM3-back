-- ===========================================================================
-- EL NOMBRE COMPLETO, PRIMERO LOS APELLIDOS (ventas.clientes.nombre_completo)
-- ===========================================================================
-- `nombre_completo` es una columna GENERADA: no se escribe, la calcula la
-- base a partir del tipo de cliente y de los nombres. Hasta hoy, en las
-- personas salía «Juan Pérez»; pasa a salir «Pérez Juan», que es como se
-- busca y como se ordena una lista de clientes.
--
-- Las empresas no cambian: siguen siendo su razón social o, si no la tienen,
-- su nombre comercial.
--
-- SE CAMBIA LA EXPRESIÓN, no se borra la columna: así no hay que tocar el
-- índice `idx_clientes_nombre_completo`, ni la vista
-- core.vista_ubicaciones_completas, ni las catorce funciones que la leen.
-- PostgreSQL vuelve a calcular las 1.000 filas y a reconstruir el índice.
\set ON_ERROR_STOP on

BEGIN;

ALTER TABLE ventas.clientes
  ALTER COLUMN nombre_completo
  SET EXPRESSION AS (
    CASE
        WHEN tipo_cliente = 'EMPRESA'
            THEN COALESCE(NULLIF(TRIM(razon_social), ''), NULLIF(TRIM(nombre_comercial), ''), '')
        ELSE TRIM(COALESCE(apellidos, '') || ' ' || COALESCE(nombres, ''))
    END
  );

COMMENT ON COLUMN ventas.clientes.nombre_completo IS
  'Generada: apellidos + nombres en las personas, razón social (o nombre comercial) en las empresas. No se escribe';

COMMIT;
