-- ===========================================================================
-- UN SOLO FORMATO PARA ENSEÑAR UN USUARIO: LOGIN-APELLIDOS NOMBRES
-- ===========================================================================
-- Fecha: 2026-10-09
-- Se aplica después de 2026-10-09_ventas_gestiones_responsable.sql.
--
-- En las pantallas de ventas un usuario se veía de dos maneras: unas veces el
-- nombre («Vendedor Cuenca Uno») y otras el login a secas («VCUENCA1»), según
-- el campo. Desde aquí se enseña siempre igual:
--
--     LAGILA  -  AGILA ASTUDILLO LEONARDO PATRICIO
--     └login┘    └ apellidos ───────┘ └ nombres ┘
--
-- EL SEPARADOR ES «  -  », con dos espacios a cada lado. En el navegador se
-- verán como uno —el HTML junta los espacios seguidos—, pero así salen
-- separados en lo que no los junta: el Excel, el CSV y el PDF.
--
-- EL LOGIN VA DELANTE porque es lo corto y lo único que no se repite: ordena
-- bien, se busca escribiendo tres letras y desempata a dos homónimos. Y como
-- el formato lo lleva dentro, los campos que antes enseñaban sólo el login no
-- pierden nada al pasarse a éste.
--
-- SE CAMBIA EN UN SOLO SITIO: ventas.fn_nombre_usuario, que es de donde salen
-- los nombres de usuario de todo el módulo. Con eso quedan en el formato
-- nuevo el responsable de la gestión, el vendedor del cliente, la lista de
-- asignables, los responsables, las reasignaciones, el tablero y el listado de
-- clientes. No hay que tocar ocho funciones.
--
-- Y SE AÑADE LA HERMANA PARA created_by (fn_nombre_usuario_login): ese campo
-- guarda el login en texto, no el id, así que para enseñarlo en el mismo
-- formato hay que resolverlo. Lo que no corresponda a un usuario —«postgres»,
-- una carga antigua— se enseña tal cual: es mejor un login raro que un hueco.
--
-- Idempotente.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- 1. El formato, por id
-- ---------------------------------------------------------------------------
-- El regexp_replace junta los espacios dobles: sin él, un usuario sin apellido
-- sale «PFULANO- NOMBRE» con el hueco a la vista.
CREATE OR REPLACE FUNCTION ventas.fn_nombre_usuario(p_id bigint)
RETURNS text
LANGUAGE sql
STABLE
SECURITY DEFINER
AS $function$
    SELECT CASE
             -- Sin nombre ni apellido cargados, al menos el login: un hueco en
             -- blanco en la pantalla no le dice nada a nadie
             WHEN NULLIF(TRIM(COALESCE(u.surname, '') || ' ' || COALESCE(u.name, '')), '') IS NULL
               THEN u.login_user
             ELSE u.login_user || '  -  ' ||
                  TRIM(regexp_replace(COALESCE(u.surname, '') || ' ' || COALESCE(u.name, ''), '\s+', ' ', 'g'))
           END
      FROM seguridad.users u
     WHERE u.id = p_id
$function$;

COMMENT ON FUNCTION ventas.fn_nombre_usuario(bigint)
    IS 'Cómo se enseña un usuario en todo el módulo: LOGIN-APELLIDOS NOMBRES';


-- ---------------------------------------------------------------------------
-- 2. El mismo formato, resolviendo por login (para created_by)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ventas.fn_nombre_usuario_login(p_login character varying)
RETURNS text
LANGUAGE sql
STABLE
SECURITY DEFINER
AS $function$
    SELECT COALESCE(
               (SELECT ventas.fn_nombre_usuario(u.id)
                  FROM seguridad.users u
                 WHERE UPPER(u.login_user) = UPPER(TRIM(p_login))
                 ORDER BY u.deleted_at NULLS FIRST
                 LIMIT 1),
               NULLIF(TRIM(COALESCE(p_login, '')), '')
           )
$function$;

COMMENT ON FUNCTION ventas.fn_nombre_usuario_login(character varying)
    IS 'Lo mismo que fn_nombre_usuario pero partiendo del login (created_by). Si no es de un usuario, devuelve el texto tal cual';


-- ---------------------------------------------------------------------------
-- 3. Que la gestión lleve también el nombre de quien la registró
-- ---------------------------------------------------------------------------
-- created_by se queda como está —es el login, y es lo que compara el filtro
-- «Registrado por»—, y al lado viaja el nombre para enseñar.
DO $$
DECLARE
    v_def     text;
    v_cuantas int;
    c_ancla   constant text := '        ''created_by'',        g.created_by,';
BEGIN
    SELECT pg_get_functiondef(p.oid) INTO v_def
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'ventas' AND p.proname = 'fn_gestiones_json' AND p.prokind = 'f';

    IF v_def IS NULL THEN
        RAISE NOTICE 'no existe fn_gestiones_json';
        RETURN;
    END IF;

    IF position('registrado_por_nombre' IN v_def) > 0 THEN
        RAISE NOTICE 'fn_gestiones_json ya lleva registrado_por_nombre';
        RETURN;
    END IF;

    v_cuantas := (length(v_def) - length(replace(v_def, c_ancla, ''))) / length(c_ancla);
    IF v_cuantas <> 1 THEN
        RAISE EXCEPTION 'fn_gestiones_json : el ancla aparece % veces y esperaba 1', v_cuantas;
    END IF;

    EXECUTE replace(v_def, c_ancla, c_ancla || '
        -- El login se queda (lo usa el filtro); al lado, cómo se enseña
        ''registrado_por_nombre'', ventas.fn_nombre_usuario_login(g.created_by),');
    RAISE NOTICE 'fn_gestiones_json actualizada';
END;
$$;


-- ---------------------------------------------------------------------------
-- 4. El desplegable «Registrado por», con nombre y con login
-- ---------------------------------------------------------------------------
-- Antes era una lista de logins que servía de etiqueta y de valor a la vez.
-- Ahora cada uno lleva las dos cosas: `login` es lo que se manda al filtrar
-- —la consulta compara con g.created_by— y `etiqueta` es lo que se lee.
DO $$
DECLARE
    v_def     text;
    v_cuantas int;
    c_ancla   constant text :=
'    SELECT COALESCE(jsonb_agg(x.quien ORDER BY x.quien), ''[]''::jsonb) INTO v_registradores';
    c_nueva   constant text :=
'    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               ''login'',    x.quien,
               ''etiqueta'', ventas.fn_nombre_usuario_login(x.quien)
           ) ORDER BY ventas.fn_nombre_usuario_login(x.quien)), ''[]''::jsonb) INTO v_registradores';
BEGIN
    SELECT pg_get_functiondef(p.oid) INTO v_def
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'ventas' AND p.proname = 'fn_gestiones_listar_paginado' AND p.prokind = 'f';

    IF position('''etiqueta'', ventas.fn_nombre_usuario_login' IN v_def) > 0 THEN
        RAISE NOTICE 'fn_gestiones_listar_paginado ya manda la etiqueta';
        RETURN;
    END IF;

    v_cuantas := (length(v_def) - length(replace(v_def, c_ancla, ''))) / length(c_ancla);
    IF v_cuantas <> 1 THEN
        RAISE EXCEPTION 'fn_gestiones_listar_paginado : el ancla aparece % veces y esperaba 1', v_cuantas;
    END IF;

    EXECUTE replace(v_def, c_ancla, c_nueva);
    RAISE NOTICE 'fn_gestiones_listar_paginado actualizada';
END;
$$;


-- ---------------------------------------------------------------------------
-- 5. Y «Lo hizo», en las reasignaciones
-- ---------------------------------------------------------------------------
-- La regla, aquí y en la gestión: created_by es SIEMPRE el login tal cual —es
-- lo que se compara— y el nombre para enseñar va al lado, en un campo con
-- sufijo _nombre. Dos convenciones distintas para lo mismo es lo que crea la
-- inconsistencia que esto viene a arreglar.
DO $$
DECLARE
    v_def     text;
    v_cuantas int;
    c_ancla   constant text := '            ''created_by'',           a.created_by';
BEGIN
    SELECT pg_get_functiondef(p.oid) INTO v_def
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'ventas' AND p.proname = 'fn_asignaciones_listar' AND p.prokind = 'f';

    IF v_def IS NULL THEN
        RAISE NOTICE 'no existe fn_asignaciones_listar';
        RETURN;
    END IF;

    IF position('created_by_nombre' IN v_def) > 0 THEN
        RAISE NOTICE 'fn_asignaciones_listar ya lleva created_by_nombre';
        RETURN;
    END IF;

    v_cuantas := (length(v_def) - length(replace(v_def, c_ancla, ''))) / length(c_ancla);
    IF v_cuantas <> 1 THEN
        RAISE EXCEPTION 'fn_asignaciones_listar : el ancla aparece % veces y esperaba 1', v_cuantas;
    END IF;

    EXECUTE replace(v_def, c_ancla, c_ancla || ',
            ''created_by_nombre'',    ventas.fn_nombre_usuario_login(a.created_by)');
    RAISE NOTICE 'fn_asignaciones_listar actualizada';
END;
$$;


-- ---------------------------------------------------------------------------
-- 6. Las notas y los archivos, que se enseñan en tarjetas
-- ---------------------------------------------------------------------------
-- Las tarjetas de la pestaña Notas, la lista de archivos y el visor de notas
-- ponían «VCUENCA1 · 06/10/2026» al pie. Misma regla: created_by se queda, y
-- al lado el nombre para enseñar.
DO $$
DECLARE
    v_nombre  text;
    v_alias   text;
    v_def     text;
    v_ancla   text;
    v_cuantas int;
BEGIN
    FOREACH v_nombre IN ARRAY ARRAY['fn_notas_clientes_json', 'fn_archivos_clientes_json'] LOOP
        -- Cada una usa su propio alias y su propia sangría
        v_alias := CASE v_nombre WHEN 'fn_notas_clientes_json' THEN 'n' ELSE 'a' END;
        v_ancla := CASE v_nombre
                     WHEN 'fn_notas_clientes_json' THEN '        ''created_by'',      n.created_by,'
                     ELSE '        ''created_by'',  a.created_by,'
                   END;

        SELECT pg_get_functiondef(p.oid) INTO v_def
          FROM pg_proc p JOIN pg_namespace n2 ON n2.oid = p.pronamespace
         WHERE n2.nspname = 'ventas' AND p.proname = v_nombre AND p.prokind = 'f';

        IF v_def IS NULL THEN
            RAISE NOTICE 'no existe %', v_nombre;
            CONTINUE;
        END IF;

        IF position('registrado_por_nombre' IN v_def) > 0 THEN
            RAISE NOTICE '% ya lleva registrado_por_nombre', v_nombre;
            CONTINUE;
        END IF;

        v_cuantas := (length(v_def) - length(replace(v_def, v_ancla, ''))) / length(v_ancla);
        IF v_cuantas <> 1 THEN
            RAISE EXCEPTION '% : el ancla aparece % veces y esperaba 1', v_nombre, v_cuantas;
        END IF;

        EXECUTE replace(v_def, v_ancla, v_ancla || '
        ''registrado_por_nombre'', ventas.fn_nombre_usuario_login(' || v_alias || '.created_by),');
        RAISE NOTICE '% actualizada', v_nombre;
    END LOOP;
END;
$$;


-- ---------------------------------------------------------------------------
-- COMPROBACIÓN
-- ---------------------------------------------------------------------------
SELECT u.id, u.login_user, ventas.fn_nombre_usuario(u.id) AS asi_se_ve
  FROM seguridad.users u
 WHERE u.login_user IN ('LAGILA', 'VCUENCA1', 'PASTUDILLO')
 ORDER BY u.id;
