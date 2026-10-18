-- ===========================================================================
-- USUARIOS: FILTROS DE COLUMNA EN EL SERVIDOR
-- ===========================================================================
-- Fecha: 2026-10-16
-- Se aplica después de 2026-10-16_inventarios_marcas_filtros_y_papelera.sql.
--
-- Lo mismo que ya tienen clientes, productos, categorías y marcas, ahora en
-- usuarios: LOS FILTROS DE LA CABECERA SE APLICAN AQUÍ, no en el navegador.
-- La pantalla pagina, así que ag-Grid sólo tiene las filas de la página y
-- filtrar ahí buscaría dentro de quince. El modelo llega en p_filtros, ya
-- traducido por el controlador:
--
--     {"login_user": {"op":"contains","valor":"lagi"},
--      "id":         {"op":"greaterThan","valor":"10"}}
--
-- Se reusan ventas.fn_filtro_texto y ventas.fn_filtro_numero (comparan sin
-- tildes y sin distinguir mayúsculas).
--
-- SE FILTRA POR LO QUE SE VE, NO POR LO QUE HAY DEBAJO. Tres columnas de la
-- rejilla no son columnas de la tabla y se filtran por su texto:
--   · «Tipo Usuario» enseña el NOMBRE del tipo (un badge), no el número que
--     guarda users.type_user; se filtra por ese nombre.
--   · «Perfil», «Horario» y «Grupo» salen de sus tablas por el id.
--   · «Grupo» sin asignar se enseña como «Sin grupo»: se filtra igual, así
--     que escribir «sin grupo» saca a los que no tienen ninguno.
--
-- La papelera de usuarios ya existe (2026-09-19_seguridad_usuarios_papelera);
-- aquí sólo cambia el listado, que sigue sin enseñar lo que está en ella.
--
-- Cambia la firma del listado, así que se suelta la función antes: un
-- CREATE OR REPLACE con otra firma deja DOS funciones y la llamada de tres
-- argumentos se vuelve ambigua. El único que la llama es UserController.
-- Idempotente.
-- ===========================================================================

DROP FUNCTION IF EXISTS seguridad.fn_usuarios_listar_paginado(integer, integer, text);

CREATE OR REPLACE FUNCTION seguridad.fn_usuarios_listar_paginado(
    p_page     integer DEFAULT 1,
    p_per_page integer DEFAULT 15,
    p_search   text    DEFAULT '',
    -- Los filtros de la cabecera de ag-Grid, columna por columna
    p_filtros  jsonb   DEFAULT '{}'::jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'seguridad', 'ventas'
AS $function$
DECLARE
    v_offset integer;
    v_total  bigint;
    v_data   jsonb;
    v_filtro text;
BEGIN
    v_offset := (GREATEST(COALESCE(p_page, 1), 1) - 1) * GREATEST(COALESCE(p_per_page, 15), 1);
    v_filtro := NULLIF(TRIM(COALESCE(p_search, '')), '');

    WITH filtrados AS (
        SELECT u.id
          FROM seguridad.users u
          -- Las mismas uniones que usa fn_usuarios_json para pintar la fila:
          -- se filtra por el texto que sale en la rejilla.
          LEFT JOIN seguridad.perfiles       pe ON pe.id = u.perfil_id
          LEFT JOIN seguridad.chorarios      ho ON ho.id = u.chorario_id
          LEFT JOIN seguridad.grupos         gr ON gr.id = u.grupo_id
          LEFT JOIN seguridad.tipos_usuarios tu ON tu.id = u.type_user
         WHERE u.deleted_at IS NULL                       -- lo de la papelera no sale
           AND seguridad.fn_usuarios_coincide(u, v_filtro)

           -- ---------- LOS FILTROS DE LA CABECERA ----------
           AND (p_filtros->'id'              IS NULL OR ventas.fn_filtro_numero(u.id,             p_filtros->'id'))
           AND (p_filtros->'login_user'      IS NULL OR ventas.fn_filtro_texto(u.login_user,      p_filtros->'login_user'))
           AND (p_filtros->'surname'         IS NULL OR ventas.fn_filtro_texto(u.surname,         p_filtros->'surname'))
           AND (p_filtros->'name'            IS NULL OR ventas.fn_filtro_texto(u.name,            p_filtros->'name'))
           AND (p_filtros->'email'           IS NULL OR ventas.fn_filtro_texto(u.email,           p_filtros->'email'))
           AND (p_filtros->'phone'           IS NULL OR ventas.fn_filtro_texto(u.phone,           p_filtros->'phone'))
           -- El nombre del tipo, que es lo que enseña el badge
           AND (p_filtros->'type_user'       IS NULL OR ventas.fn_filtro_texto(tu.nombre,         p_filtros->'type_user'))
           AND (p_filtros->'perfil_nombre'   IS NULL OR ventas.fn_filtro_texto(pe.nombre,         p_filtros->'perfil_nombre'))
           AND (p_filtros->'chorario_nombre' IS NULL OR ventas.fn_filtro_texto(ho.nombre,         p_filtros->'chorario_nombre'))
           -- Sin grupo se enseña así en la rejilla, y así se filtra
           AND (p_filtros->'grupo_nombre'    IS NULL OR ventas.fn_filtro_texto(
                   COALESCE(gr.nombre, 'Sin grupo'), p_filtros->'grupo_nombre'))
           -- Las fechas, como texto sobre lo que se ve: «2026-10» busca el mes
           AND (p_filtros->'last_login_at'   IS NULL OR ventas.fn_filtro_texto(
                   to_char(u.last_login_at, 'YYYY-MM-DD HH24:MI:SS'), p_filtros->'last_login_at'))
           AND (p_filtros->'created_at'      IS NULL OR ventas.fn_filtro_texto(
                   to_char(u.created_at,    'YYYY-MM-DD HH24:MI:SS'), p_filtros->'created_at'))
           AND (p_filtros->'updated_at'      IS NULL OR ventas.fn_filtro_texto(
                   to_char(u.updated_at,    'YYYY-MM-DD HH24:MI:SS'), p_filtros->'updated_at'))
           AND (p_filtros->'created_by'      IS NULL OR ventas.fn_filtro_texto(u.created_by,      p_filtros->'created_by'))
           AND (p_filtros->'updated_by'      IS NULL OR ventas.fn_filtro_texto(u.updated_by,      p_filtros->'updated_by'))
    )
    SELECT COUNT(*),
           COALESCE((SELECT jsonb_agg(seguridad.fn_usuarios_json(t.id) ORDER BY t.id DESC)
                       FROM (SELECT f.id FROM filtrados f
                              ORDER BY f.id DESC
                              LIMIT GREATEST(COALESCE(p_per_page, 15), 1) OFFSET v_offset) t), '[]'::jsonb)
      INTO v_total, v_data
      FROM filtrados;

    RETURN jsonb_build_object(
        'data', v_data,
        'meta', jsonb_build_object(
            'total',        v_total,
            'per_page',     GREATEST(COALESCE(p_per_page, 15), 1),
            'current_page', GREATEST(COALESCE(p_page, 1), 1),
            'last_page',    CASE WHEN v_total = 0 THEN 1
                                 ELSE ceil(v_total::numeric / GREATEST(COALESCE(p_per_page, 15), 1)) END
        )
    );
END;
$function$;

ALTER FUNCTION seguridad.fn_usuarios_listar_paginado(integer, integer, text, jsonb) OWNER TO postgres;

COMMENT ON FUNCTION seguridad.fn_usuarios_listar_paginado(integer, integer, text, jsonb) IS
'Listado paginado de usuarios; p_filtros trae los filtros de columna de ag-Grid y se aplican sobre todos los usuarios, no sobre la página';
