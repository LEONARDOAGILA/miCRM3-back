-- ===========================================================================
-- LA VALIDACIÓN TAMBIÉN IGNORA LA PAPELERA
-- ===========================================================================
-- Los índices únicos ya son parciales (WHERE deleted_at IS NULL), pero
-- rh.fn_empleados_validar seguía mirando la tabla entera: con el empleado en
-- la papelera, su cédula y su correo quedaban bloqueados para siempre, que es
-- justo lo que la papelera viene a evitar. Y un jefe en la papelera tampoco
-- vale: no se puede depender de alguien que ya no sale en ningún listado.
--
-- El cuerpo es el que había, sacado de la base, con tres AND deleted_at.
-- Se aplica sobre 2026-10-21_rh_empleados_papelera_y_filtros.sql.
\set ON_ERROR_STOP on

BEGIN;

CREATE OR REPLACE FUNCTION rh.fn_empleados_validar(p_id bigint, p_numero_identificacion character varying, p_tipo_identificacion character varying, p_nombres character varying, p_apellidos character varying, p_email character varying, p_genero character, p_cargo_id bigint, p_departamento_id bigint, p_jefe_id bigint, p_fecha_ingreso date, p_fecha_salida date, p_tipo_contrato character varying, p_salario numeric)
 RETURNS void
 LANGUAGE plpgsql
AS $function$
BEGIN
    IF p_nombres IS NULL OR length(TRIM(p_nombres)) < 2 THEN
        RAISE EXCEPTION 'Los nombres son obligatorios (mínimo 2 caracteres)' USING ERRCODE = 'P0001';
    END IF;
    IF p_apellidos IS NULL OR length(TRIM(p_apellidos)) < 2 THEN
        RAISE EXCEPTION 'Los apellidos son obligatorios (mínimo 2 caracteres)' USING ERRCODE = 'P0002';
    END IF;
    IF p_numero_identificacion IS NULL OR TRIM(p_numero_identificacion) = '' THEN
        RAISE EXCEPTION 'El número de identificación es obligatorio' USING ERRCODE = 'P0003';
    END IF;
    IF p_email IS NULL OR TRIM(p_email) = '' THEN
        RAISE EXCEPTION 'El correo electrónico es obligatorio' USING ERRCODE = 'P0004';
    END IF;
    IF EXISTS (SELECT 1 FROM rh.empleados WHERE numero_identificacion = TRIM(p_numero_identificacion)
                  AND tipo_identificacion = COALESCE(p_tipo_identificacion, 'CC')
                  AND deleted_at IS NULL
                  AND (p_id IS NULL OR id <> p_id)) THEN
        RAISE EXCEPTION 'Ya existe un empleado con esa identificación' USING ERRCODE = 'P0006';
    END IF;
    IF EXISTS (SELECT 1 FROM rh.empleados WHERE LOWER(email) = LOWER(TRIM(p_email))
                  AND deleted_at IS NULL
                  AND (p_id IS NULL OR id <> p_id)) THEN
        RAISE EXCEPTION 'Ya existe un empleado con ese correo' USING ERRCODE = 'P0007';
    END IF;
    IF p_cargo_id IS NULL OR NOT EXISTS (SELECT 1 FROM rh.cargos WHERE id = p_cargo_id) THEN
        RAISE EXCEPTION 'Debe asignar un cargo válido' USING ERRCODE = 'P0008';
    END IF;
    IF p_departamento_id IS NULL OR NOT EXISTS (SELECT 1 FROM rh.departamentos WHERE id = p_departamento_id) THEN
        RAISE EXCEPTION 'Debe asignar un departamento válido' USING ERRCODE = 'P0009';
    END IF;
    IF p_jefe_id IS NOT NULL THEN
        IF p_id IS NOT NULL AND p_jefe_id = p_id THEN
            RAISE EXCEPTION 'Un empleado no puede ser su propio jefe' USING ERRCODE = 'P0010';
        END IF;
        IF NOT EXISTS (SELECT 1 FROM rh.empleados WHERE id = p_jefe_id AND deleted_at IS NULL) THEN
            RAISE EXCEPTION 'El jefe seleccionado no existe' USING ERRCODE = 'P0010';
        END IF;
    END IF;
    IF p_fecha_ingreso IS NULL THEN
        RAISE EXCEPTION 'La fecha de ingreso es obligatoria' USING ERRCODE = 'P0011';
    END IF;
    IF p_fecha_salida IS NOT NULL AND p_fecha_salida < p_fecha_ingreso THEN
        RAISE EXCEPTION 'La fecha de salida no puede ser anterior a la de ingreso' USING ERRCODE = 'P0012';
    END IF;
    IF p_salario IS NOT NULL AND p_salario < 0 THEN
        RAISE EXCEPTION 'El salario no puede ser negativo' USING ERRCODE = 'P0015';
    END IF;
    IF COALESCE(p_tipo_contrato, 'INDEFINIDO') NOT IN ('INDEFINIDO', 'TEMPORAL', 'PRACTICAS', 'CONSULTORIA') THEN
        RAISE EXCEPTION 'El tipo de contrato % no es válido', p_tipo_contrato USING ERRCODE = 'P0016';
    END IF;
    IF p_genero IS NOT NULL AND p_genero NOT IN ('M', 'F', 'O') THEN
        RAISE EXCEPTION 'El género % no es válido', p_genero USING ERRCODE = 'P0017';
    END IF;
END;
$function$;

COMMIT;
