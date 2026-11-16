-- ===========================================================================
-- EMPLEADOS: FILTROS DE COLUMNA EN EL SERVIDOR
-- ===========================================================================
-- El listado paginado pasa a aceptar `p_filtros`, el modelo de filtros de la
-- cabecera de ag-Grid, con la misma lista blanca que clientes y sucursales:
-- lo que no esté aquí se ignora, aunque la pantalla lo mande.
--
-- Se filtra POR LO QUE SE VE: el cargo por su nombre y no por su id, las
-- fechas como texto («2026-10» busca el mes), el estado por su palabra.
--
-- Y, de paso, los listados dejan de enseñar lo que está en la papelera.
-- Se aplica sobre 2026-10-21_rh_empleados_papelera_y_filtros.sql.
\set ON_ERROR_STOP on

BEGIN;

-- Cambia la firma (un parámetro nuevo), así que se tira y se vuelve a crear:
-- con CREATE OR REPLACE quedarían dos versiones y la llamada sería ambigua.
DROP FUNCTION IF EXISTS rh.fn_empleados_listar_paginado(integer, integer, text);

CREATE OR REPLACE FUNCTION rh.fn_empleados_listar_paginado(
    p_page     integer DEFAULT 1,
    p_per_page integer DEFAULT 15,
    p_search   text    DEFAULT '',
    p_filtros  jsonb   DEFAULT '{}'::jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'rh', 'ventas'
AS $function$
DECLARE
    v_offset integer;
    v_total  bigint;
    v_data   jsonb;
    v_filtro text;
BEGIN
    v_offset := (GREATEST(p_page, 1) - 1) * GREATEST(p_per_page, 1);
    v_filtro := NULLIF(TRIM(COALESCE(p_search, '')), '');

    WITH filtradas AS (
        SELECT e.*,
               c.nombre AS cargo_nombre,
               d.nombre AS departamento_nombre,
               s.nombre AS sucursal_nombre,
               NULLIF(TRIM(CONCAT_WS(' ', j.nombres, j.apellidos)), '') AS jefe_nombre
          FROM rh.empleados e
          LEFT JOIN rh.cargos c         ON c.id = e.cargo_id
          LEFT JOIN rh.departamentos d  ON d.id = e.departamento_id
          LEFT JOIN ventas.sucursales s ON s.id = e.sucursal_id
          LEFT JOIN rh.empleados j      ON j.id = e.jefe_id
         WHERE e.deleted_at IS NULL              -- lo de la papelera no sale
           AND (v_filtro IS NULL
                OR CONCAT_WS(' ', e.nombres, e.apellidos) ILIKE '%' || v_filtro || '%'
                OR CONCAT_WS(' ', e.apellidos, e.nombres) ILIKE '%' || v_filtro || '%'
                OR e.numero_identificacion ILIKE '%' || v_filtro || '%'
                OR e.email   ILIKE '%' || v_filtro || '%'
                OR e.celular ILIKE '%' || v_filtro || '%'
                OR c.nombre  ILIKE '%' || v_filtro || '%'
                OR d.nombre  ILIKE '%' || v_filtro || '%'
                OR s.nombre  ILIKE '%' || v_filtro || '%'
                OR e.id::text ILIKE '%' || v_filtro || '%')

           -- ---------- LOS FILTROS DE LA CABECERA ----------
           AND (p_filtros->'id' IS NULL OR ventas.fn_filtro_numero(e.id, p_filtros->'id'))
           AND (p_filtros->'salario' IS NULL OR ventas.fn_filtro_numero(e.salario, p_filtros->'salario'))

           AND (p_filtros->'numero_identificacion' IS NULL OR ventas.fn_filtro_texto(e.numero_identificacion, p_filtros->'numero_identificacion'))
           AND (p_filtros->'tipo_identificacion'   IS NULL OR ventas.fn_filtro_texto(e.tipo_identificacion,   p_filtros->'tipo_identificacion'))
           AND (p_filtros->'nombres'               IS NULL OR ventas.fn_filtro_texto(e.nombres,               p_filtros->'nombres'))
           AND (p_filtros->'apellidos'             IS NULL OR ventas.fn_filtro_texto(e.apellidos,             p_filtros->'apellidos'))
           AND (p_filtros->'nombre_completo'       IS NULL OR ventas.fn_filtro_texto(TRIM(CONCAT_WS(' ', e.nombres, e.apellidos)), p_filtros->'nombre_completo'))
           AND (p_filtros->'email'                 IS NULL OR ventas.fn_filtro_texto(e.email,                 p_filtros->'email'))
           AND (p_filtros->'celular'               IS NULL OR ventas.fn_filtro_texto(e.celular,               p_filtros->'celular'))
           AND (p_filtros->'telefono'              IS NULL OR ventas.fn_filtro_texto(e.telefono,              p_filtros->'telefono'))
           AND (p_filtros->'estado'                IS NULL OR ventas.fn_filtro_texto(e.estado,                p_filtros->'estado'))
           AND (p_filtros->'tipo_contrato'         IS NULL OR ventas.fn_filtro_texto(e.tipo_contrato,         p_filtros->'tipo_contrato'))
           AND (p_filtros->'created_by'            IS NULL OR ventas.fn_filtro_texto(e.created_by,            p_filtros->'created_by'))
           AND (p_filtros->'updated_by'            IS NULL OR ventas.fn_filtro_texto(e.updated_by,            p_filtros->'updated_by'))

           -- Lo de las tablas de al lado, por su NOMBRE: es lo que se ve
           AND (p_filtros->'cargo_nombre'          IS NULL OR ventas.fn_filtro_texto(c.nombre, p_filtros->'cargo_nombre'))
           AND (p_filtros->'departamento_nombre'   IS NULL OR ventas.fn_filtro_texto(d.nombre, p_filtros->'departamento_nombre'))
           AND (p_filtros->'jefe_nombre'           IS NULL OR ventas.fn_filtro_texto(TRIM(CONCAT_WS(' ', j.nombres, j.apellidos)), p_filtros->'jefe_nombre'))
           -- Sin sucursal también se busca: «sin» no encuentra un NULL, así
           -- que la columna se mira con el texto que enseña la rejilla
           AND (p_filtros->'sucursal_nombre'       IS NULL OR ventas.fn_filtro_texto(COALESCE(s.nombre, 'Sin sucursal'), p_filtros->'sucursal_nombre'))

           -- Las fechas, como texto sobre lo que se ve
           AND (p_filtros->'fecha_ingreso' IS NULL OR ventas.fn_filtro_texto(to_char(e.fecha_ingreso, 'YYYY-MM-DD'), p_filtros->'fecha_ingreso'))
           AND (p_filtros->'fecha_salida'  IS NULL OR ventas.fn_filtro_texto(to_char(e.fecha_salida,  'YYYY-MM-DD'), p_filtros->'fecha_salida'))
           AND (p_filtros->'created_at'    IS NULL OR ventas.fn_filtro_texto(to_char(e.created_at, 'YYYY-MM-DD HH24:MI:SS'), p_filtros->'created_at'))
           AND (p_filtros->'updated_at'    IS NULL OR ventas.fn_filtro_texto(to_char(e.updated_at, 'YYYY-MM-DD HH24:MI:SS'), p_filtros->'updated_at'))
    )
    SELECT COUNT(*),
           COALESCE((SELECT jsonb_agg(
               jsonb_build_object(
                   'id',                    t.id,
                   'numero_identificacion', t.numero_identificacion,
                   'tipo_identificacion',   t.tipo_identificacion,
                   'nombres',               t.nombres,
                   'apellidos',             t.apellidos,
                   'nombre_completo',       TRIM(CONCAT_WS(' ', t.nombres, t.apellidos)),
                   'email',                 t.email,
                   'email_personal',        t.email_personal,
                   'telefono',              t.telefono,
                   'celular',               t.celular,
                   'fecha_nacimiento',      to_char(t.fecha_nacimiento, 'YYYY-MM-DD'),
                   'genero',                t.genero,
                   'direccion',             t.direccion,
                   'cargo_id',              t.cargo_id,
                   'cargo_nombre',          t.cargo_nombre,
                   'sucursal_id',           t.sucursal_id,
                   'sucursal_nombre',       t.sucursal_nombre,
                   'departamento_id',       t.departamento_id,
                   'departamento_nombre',   t.departamento_nombre,
                   'jefe_id',               t.jefe_id,
                   'jefe_nombre',           t.jefe_nombre,
                   'fecha_ingreso',         to_char(t.fecha_ingreso, 'YYYY-MM-DD'),
                   'fecha_salida',          to_char(t.fecha_salida, 'YYYY-MM-DD'),
                   'estado',                t.estado,
                   'tipo_contrato',         t.tipo_contrato,
                   'salario',               t.salario,
                   'foto',                  t.foto,
                   'activo',                t.activo,
                   'created_by',            t.created_by,
                   'updated_by',            t.updated_by,
                   'created_at',            to_char(t.created_at, 'YYYY-MM-DD HH24:MI:SS'),
                   'updated_at',            to_char(t.updated_at, 'YYYY-MM-DD HH24:MI:SS')
               ) ORDER BY t.id DESC
             ) FROM (SELECT * FROM filtradas ORDER BY id DESC
                      LIMIT GREATEST(p_per_page, 1) OFFSET v_offset) t), '[]'::jsonb)
      INTO v_total, v_data
      FROM filtradas;

    RETURN jsonb_build_object(
        'data', v_data,
        'meta', jsonb_build_object(
            'total',        v_total,
            'per_page',     GREATEST(p_per_page, 1),
            'current_page', GREATEST(p_page, 1),
            'last_page',    CASE WHEN v_total = 0 THEN 1
                                 ELSE ceil(v_total::numeric / GREATEST(p_per_page, 1)) END
        )
    );
EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object('success', false,
                                  'message', 'Error al listar empleados: ' || SQLERRM,
                                  'error_code', SQLSTATE);
END;
$function$;

-- La lista simple (selectores de jefe, combos): tampoco ofrece lo que está
-- en la papelera. Si no, se podría elegir como jefe a alguien que ya no sale.
CREATE OR REPLACE FUNCTION rh.fn_empleados_listar(p_solo_activos boolean DEFAULT true)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
AS $function$
DECLARE
    v_data jsonb;
BEGIN
    SELECT COALESCE(jsonb_agg(
        jsonb_build_object(
            'id', e.id,
            'nombre', TRIM(CONCAT_WS(' ', e.nombres, e.apellidos)),
            'numero_identificacion', e.numero_identificacion,
            'cargo_nombre', c.nombre,
            'sucursal_id',  e.sucursal_id,
            'sucursal_nombre', s.nombre,
            'departamento_nombre', d.nombre,
            'activo', e.activo
        ) ORDER BY e.apellidos, e.nombres
    ), '[]'::jsonb) INTO v_data
    FROM rh.empleados e
    LEFT JOIN rh.cargos c        ON c.id = e.cargo_id
    LEFT JOIN ventas.sucursales s ON s.id = e.sucursal_id
    LEFT JOIN rh.departamentos d ON d.id = e.departamento_id
    WHERE e.deleted_at IS NULL
      AND (NOT p_solo_activos OR (e.activo AND COALESCE(e.estado, 'ACTIVO') = 'ACTIVO'));

    RETURN jsonb_build_object('success', true, 'message', 'Empleados obtenidos exitosamente', 'data', v_data);
EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object('success', false, 'message', 'Error al listar empleados: ' || SQLERRM, 'error_code', SQLSTATE);
END;
$function$;

COMMIT;
