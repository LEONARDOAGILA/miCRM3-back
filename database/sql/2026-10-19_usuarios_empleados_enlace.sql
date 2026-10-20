-- ===========================================================================
-- CADA USUARIO, ENLAZADO A SU EMPLEADO
-- ===========================================================================
-- Fecha: 2026-10-19
--
-- «Marcar desde mi celular» (rh/registroMarcaciones) y rh/marcacion/miEmpleado
-- preguntan al servidor QUIÉN es quien ha entrado, y eso sale de
-- seguridad.users.empleado_id. Estaba vacío en los 52 usuarios, así que la
-- pantalla no servía para nadie.
--
-- ESTO ES UNA BASE DE PRUEBAS: a quien no tenga ficha se le crea una con lo
-- que se sabe de su usuario. En producción esto se haría al revés (primero
-- el empleado, después su usuario), así que las fichas creadas aquí se
-- reconocen a simple vista:
--   · cédula  «USR000123» (el id del usuario)
--   · cargo y departamento «Sin asignar»
--   · created_by = 'enlace-usuarios'
--
-- El enlace se busca en tres pasos, de más seguro a menos:
--   1. Por correo exacto.
--   2. Por nombre: primera palabra del nombre Y del apellido, sin tildes.
--      Un empleado no se enlaza a dos usuarios.
--   3. Lo que quede: ficha nueva.
--
-- Se puede volver a ejecutar: sólo toca usuarios con empleado_id vacío.
-- ===========================================================================
\set ON_ERROR_STOP on
\pset tuples_only on
\pset format unaligned

BEGIN;

-- ---------------------------------------------------------------------------
-- 0. Un cargo y un departamento donde poner a los que se creen
-- ---------------------------------------------------------------------------
-- Mejor «Sin asignar» que colgarlos de «Gerente General», que es lo que
-- saldría al usar el primer id que hubiera.
INSERT INTO rh.cargos (nombre)
SELECT 'Sin asignar'
 WHERE NOT EXISTS (SELECT 1 FROM rh.cargos WHERE nombre = 'Sin asignar');

INSERT INTO rh.departamentos (nombre)
SELECT 'Sin asignar'
 WHERE NOT EXISTS (SELECT 1 FROM rh.departamentos WHERE nombre = 'Sin asignar');

-- ---------------------------------------------------------------------------
-- 1. Por correo
-- ---------------------------------------------------------------------------
UPDATE seguridad.users u
   SET empleado_id = e.id
  FROM rh.empleados e
 WHERE u.deleted_at IS NULL
   AND u.empleado_id IS NULL
   AND LOWER(TRIM(u.email)) = LOWER(TRIM(e.email))
   -- Ese empleado no puede estar ya enlazado a otro usuario
   AND NOT EXISTS (SELECT 1 FROM seguridad.users x WHERE x.empleado_id = e.id);

-- ---------------------------------------------------------------------------
-- 2. Por nombre y apellido (sin tildes, primera palabra de cada uno)
-- ---------------------------------------------------------------------------
WITH parejas AS (
    SELECT u.id AS usuario, e.id AS empleado,
           ROW_NUMBER() OVER (PARTITION BY u.id ORDER BY e.id) AS cual
      FROM seguridad.users u
      JOIN rh.empleados e
        ON ventas.fn_sin_tildes(UPPER(SPLIT_PART(TRIM(u.name), ' ', 1)))
         = ventas.fn_sin_tildes(UPPER(SPLIT_PART(TRIM(e.nombres), ' ', 1)))
       AND ventas.fn_sin_tildes(UPPER(SPLIT_PART(TRIM(u.surname), ' ', 1)))
         = ventas.fn_sin_tildes(UPPER(SPLIT_PART(TRIM(e.apellidos), ' ', 1)))
     WHERE u.deleted_at IS NULL
       AND u.empleado_id IS NULL
       AND NOT EXISTS (SELECT 1 FROM seguridad.users x WHERE x.empleado_id = e.id)
)
UPDATE seguridad.users u
   SET empleado_id = p.empleado
  FROM parejas p
 WHERE u.id = p.usuario
   AND p.cual = 1;

-- ---------------------------------------------------------------------------
-- 3. Ficha nueva para los que quedan
-- ---------------------------------------------------------------------------
INSERT INTO rh.empleados (
    numero_identificacion, tipo_identificacion, nombres, apellidos, email,
    cargo_id, departamento_id, fecha_ingreso, tipo_contrato, estado, activo,
    created_by, updated_by)
SELECT 'USR' || LPAD(u.id::text, 6, '0'),
       'CC',
       -- La tabla exige dos caracteres: si el usuario no los trae, su login
       CASE WHEN length(TRIM(COALESCE(u.name, ''))) >= 2    THEN TRIM(u.name)    ELSE u.login_user END,
       CASE WHEN length(TRIM(COALESCE(u.surname, ''))) >= 2 THEN TRIM(u.surname) ELSE u.login_user END,
       LOWER(TRIM(u.email)),
       (SELECT id FROM rh.cargos        WHERE nombre = 'Sin asignar'),
       (SELECT id FROM rh.departamentos WHERE nombre = 'Sin asignar'),
       CURRENT_DATE,
       'INDEFINIDO',
       -- Un usuario apagado no debería poder marcar
       CASE WHEN COALESCE(u.isactive, true) THEN 'ACTIVO' ELSE 'INACTIVO' END,
       COALESCE(u.isactive, true),
       'enlace-usuarios', 'enlace-usuarios'
  FROM seguridad.users u
 WHERE u.deleted_at IS NULL
   AND u.empleado_id IS NULL
   AND NOT EXISTS (SELECT 1 FROM rh.empleados e
                    WHERE e.numero_identificacion = 'USR' || LPAD(u.id::text, 6, '0')
                       OR LOWER(TRIM(e.email)) = LOWER(TRIM(u.email)));

UPDATE seguridad.users u
   SET empleado_id = e.id
  FROM rh.empleados e
 WHERE u.deleted_at IS NULL
   AND u.empleado_id IS NULL
   AND e.numero_identificacion = 'USR' || LPAD(u.id::text, 6, '0');

-- ---------------------------------------------------------------------------
-- 4. Cómo quedó
-- ---------------------------------------------------------------------------
SELECT 'usuarios vivos: ' || COUNT(*)
     || ' · enlazados: ' || COUNT(*) FILTER (WHERE empleado_id IS NOT NULL)
     || ' · sin enlazar: ' || COUNT(*) FILTER (WHERE empleado_id IS NULL)
  FROM seguridad.users WHERE deleted_at IS NULL;

-- El created_by lo pisa el trigger de auditoría con el usuario de la
-- sesión, así que las fichas nuevas se reconocen por su cédula USR……
SELECT 'fichas creadas por este guion: ' || COUNT(*)
  FROM rh.empleados WHERE numero_identificacion LIKE 'USR%';

SELECT 'empleados en total: ' || COUNT(*)
     || ' · enlazados a un usuario: ' || COUNT(*) FILTER (
            WHERE EXISTS (SELECT 1 FROM seguridad.users u WHERE u.empleado_id = rh.empleados.id))
  FROM rh.empleados;

-- Nadie puede quedar compartiendo ficha
SELECT 'OJO: el empleado ' || empleado_id || ' está enlazado a ' || COUNT(*) || ' usuarios'
  FROM seguridad.users
 WHERE empleado_id IS NOT NULL AND deleted_at IS NULL
 GROUP BY empleado_id HAVING COUNT(*) > 1;

COMMIT;
