-- ===========================================================================
-- USUARIOS POR GRUPO: FILTROS DE COLUMNA EN EL SERVIDOR
-- ===========================================================================
-- Fecha: 2026-10-17
-- Se aplica después de 2026-10-17_seguridad_perfiles_filtros_y_papelera.sql.
--
-- La rejilla de la derecha de «Usuarios y grupos» es otra función distinta de
-- la del listado de usuarios: ésta filtra por el grupo del árbol (y sus
-- subgrupos, si se pide). Le faltaban los filtros de la cabecera, que se
-- aplican AQUÍ y no en el navegador: la pantalla pagina, así que ag-Grid sólo
-- tiene las filas de la página y filtrar ahí buscaría dentro de diez.
--
-- El modelo llega en p_filtros, ya traducido por el controlador, y se suma a
-- lo que ya había: el grupo elegido en el árbol y la búsqueda de arriba.
--
-- SE FILTRA POR LO QUE SE VE, que aquí no es lo que guarda la tabla:
--   · «Tipo» enseña el NOMBRE del tipo de usuario, no el número de
--     users.type_user.
--   · «Grupo», «Perfil» y «Horario» salen de sus tablas por el id; el grupo
--     sin asignar se enseña y se filtra como «Sin grupo».
--   · «Último login» se filtra como texto sobre lo que se ve.
--
-- Las mismas columnas y los mismos nombres que en el listado de usuarios
-- (2026-10-16_seguridad_usuarios_filtros_de_columna), para que filtrar
-- signifique lo mismo en las dos pantallas.
--
-- Cambia la firma, así que se suelta la función antes: un CREATE OR REPLACE
-- con otra firma deja DOS funciones y la llamada de cinco argumentos se
-- vuelve ambigua. El único que la llama es UserController.
-- Idempotente.
-- ===========================================================================

DROP FUNCTION IF EXISTS seguridad.fn_usuarios_listar_por_grupo(bigint, boolean, integer, integer, text);

CREATE OR REPLACE FUNCTION seguridad.fn_usuarios_listar_por_grupo(
    p_grupo_id          bigint  DEFAULT NULL,
    p_incluir_subgrupos boolean DEFAULT false,
    p_page              integer DEFAULT 1,
    p_per_page          integer DEFAULT 15,
    p_search            text    DEFAULT '',
    -- Los filtros de la cabecera de ag-Grid, columna por columna
    p_filtros           jsonb   DEFAULT '{}'::jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'seguridad', 'ventas'
AS $function$
DECLARE
    v_offset integer;
    v_total  bigint;
    v_data   jsonb;
    v_filtro text;
    v_grupos bigint[];
BEGIN
    v_offset := (GREATEST(COALESCE(p_page, 1), 1) - 1) * GREATEST(COALESCE(p_per_page, 15), 1);
    v_filtro := NULLIF(TRIM(COALESCE(p_search, '')), '');

    IF p_grupo_id IS NOT NULL AND p_grupo_id > 0 THEN
        IF p_incluir_subgrupos THEN
            WITH RECURSIVE d AS (
                SELECT id FROM seguridad.grupos WHERE id = p_grupo_id
                UNION ALL
                SELECT g.id FROM seguridad.grupos g JOIN d ON g.padre_id = d.id
            )
            SELECT array_agg(id) INTO v_grupos FROM d;
        ELSE
            v_grupos := ARRAY[p_grupo_id];
        END IF;
    END IF;

    CREATE TEMP TABLE IF NOT EXISTS tmp_usuarios_grupo (id bigint) ON COMMIT DROP;
    DELETE FROM tmp_usuarios_grupo;

    INSERT INTO tmp_usuarios_grupo (id)
    SELECT u.id
      FROM seguridad.users u
      -- Las mismas uniones que usa fn_usuarios_json para pintar la fila: se
      -- filtra por el texto que sale en la rejilla.
      LEFT JOIN seguridad.perfiles       pe ON pe.id = u.perfil_id
      LEFT JOIN seguridad.chorarios      ho ON ho.id = u.chorario_id
      LEFT JOIN seguridad.grupos         gr ON gr.id = u.grupo_id
      LEFT JOIN seguridad.tipos_usuarios tu ON tu.id = u.type_user
     WHERE u.deleted_at IS NULL
       AND (   p_grupo_id IS NULL
            OR (p_grupo_id = 0 AND u.grupo_id IS NULL)
            OR (v_grupos IS NOT NULL AND u.grupo_id = ANY (v_grupos)))
       AND seguridad.fn_usuarios_coincide(u, v_filtro)

       -- ---------- LOS FILTROS DE LA CABECERA ----------
       AND (p_filtros->'login_user'      IS NULL OR ventas.fn_filtro_texto(u.login_user,      p_filtros->'login_user'))
       AND (p_filtros->'surname'         IS NULL OR ventas.fn_filtro_texto(u.surname,         p_filtros->'surname'))
       AND (p_filtros->'name'            IS NULL OR ventas.fn_filtro_texto(u.name,            p_filtros->'name'))
       AND (p_filtros->'email'           IS NULL OR ventas.fn_filtro_texto(u.email,           p_filtros->'email'))
       -- El nombre del tipo, que es lo que enseña el badge
       AND (p_filtros->'type_user'       IS NULL OR ventas.fn_filtro_texto(tu.nombre,         p_filtros->'type_user'))
       AND (p_filtros->'perfil_nombre'   IS NULL OR ventas.fn_filtro_texto(pe.nombre,         p_filtros->'perfil_nombre'))
       AND (p_filtros->'chorario_nombre' IS NULL OR ventas.fn_filtro_texto(ho.nombre,         p_filtros->'chorario_nombre'))
       -- Sin grupo se enseña así en la rejilla, y así se filtra
       AND (p_filtros->'grupo_nombre'    IS NULL OR ventas.fn_filtro_texto(
               COALESCE(gr.nombre, 'Sin grupo'), p_filtros->'grupo_nombre'))
       -- Las fechas, como texto sobre lo que se ve: «2026-10» busca el mes
       AND (p_filtros->'last_login_at'   IS NULL OR ventas.fn_filtro_texto(
               to_char(u.last_login_at, 'YYYY-MM-DD HH24:MI:SS'), p_filtros->'last_login_at'));

    SELECT COUNT(*) INTO v_total FROM tmp_usuarios_grupo;

    SELECT COALESCE(jsonb_agg(seguridad.fn_usuarios_json(t.id) ORDER BY t.surname, t.name, t.id), '[]'::jsonb)
      INTO v_data
      FROM (
        SELECT u.id, u.surname, u.name
          FROM seguridad.users u
          JOIN tmp_usuarios_grupo f ON f.id = u.id
         ORDER BY u.surname, u.name, u.id
         LIMIT GREATEST(COALESCE(p_per_page, 15), 1) OFFSET v_offset
      ) t;

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

ALTER FUNCTION seguridad.fn_usuarios_listar_por_grupo(bigint, boolean, integer, integer, text, jsonb) OWNER TO postgres;

COMMENT ON FUNCTION seguridad.fn_usuarios_listar_por_grupo(bigint, boolean, integer, integer, text, jsonb) IS
'Usuarios de un grupo (y sus subgrupos si se pide); p_filtros trae los filtros de columna de ag-Grid y se aplican sobre todos los del grupo, no sobre la página';
