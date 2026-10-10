-- ===========================================================================
-- EL HISTORIAL SE FILTRA POR RESPONSABLE, NO POR QUIÉN LO REGISTRÓ
-- ===========================================================================
-- Fecha: 2026-10-09
-- Se aplica después de 2026-10-09_ventas_formato_nombre_usuario.sql.
--
-- El desplegable del historial filtraba por created_by —quién teclea la
-- gestión— y lo que se busca es por RESPONSABLE: a quién le toca. Son cosas
-- distintas desde que se puede crear una gestión para otro, y se nota en los
-- datos: de las 45 gestiones de un cliente, 44 las registró LAGILA y el
-- responsable es VCUENCA1. Filtrando por el que las escribió salían las 44
-- juntas; por responsable sale lo que de verdad se quiere ver.
--
-- La columna «Registrado por» se queda en la rejilla: enseñar quién la tecleó
-- sigue valiendo, lo que no valía era filtrar por ahí.
--
-- QUÉ CAMBIA EN LA FIRMA: el décimo parámetro pasa de
--
--     p_creado_por character varying   (un login)
--   a
--     p_responsable_id bigint          (un id de usuario)
--
-- Y como la firma cambia, hay que TIRAR la función antes de crearla: con otra
-- firma, CREATE OR REPLACE no reemplaza, añade una sobrecarga, y las llamadas
-- de diez argumentos se quedarían resolviendo a la vieja.
--
-- EL DESPLEGABLE pasa de una lista de logins a una de responsables
-- (`filtros.responsables`, con id y etiqueta), y se sigue recortando por la
-- visibilidad de quien mira: el menú no puede delatar a gente cuyas gestiones
-- no se pueden ver.
--
-- SE PARCHEA POR SUSTITUCIÓN sobre la definición que hay en la base, que es de
-- noventa líneas y de las que cambian cuatro. Si un ancla no aparece las veces
-- esperadas, revienta y no toca nada.
--
-- Idempotente.
-- ===========================================================================

DO $$
DECLARE
    v_def     text;
    v_nueva   text;
    v_firma   text;
    v_cuantas int;

    -- 1. La firma
    c_param_viejo constant text := 'p_resultado character varying, p_creado_por character varying';
    c_param_nuevo constant text := 'p_resultado character varying, p_responsable_id bigint';

    -- 2. El filtro, en la consulta del total y en la de la página
    c_filtro_viejo constant text := 'AND (p_creado_por IS NULL OR g.created_by = p_creado_por)';
    c_filtro_nuevo constant text := 'AND (p_responsable_id IS NULL OR g.usuario_id = p_responsable_id)';

    -- 3. El desplegable
    c_lista_vieja constant text :=
'    -- El desplegable «Registrado por»: también filtrado, o el menú delataría
    -- los nombres de quienes escribieron lo que no se puede ver
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               ''login'',    x.quien,
               ''etiqueta'', ventas.fn_nombre_usuario_login(x.quien)
           ) ORDER BY ventas.fn_nombre_usuario_login(x.quien)), ''[]''::jsonb) INTO v_registradores
      FROM (
        SELECT DISTINCT g.created_by AS quien
          FROM ventas.gestiones g
         WHERE g.cliente_id = p_cliente_id
           AND g.created_by IS NOT NULL';
    c_lista_nueva constant text :=
'    -- El desplegable «Responsable»: también filtrado, o el menú delataría los
    -- nombres de la gente cuyas gestiones no se pueden ver
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               ''id'',       x.quien,
               ''etiqueta'', ventas.fn_nombre_usuario(x.quien)
           ) ORDER BY ventas.fn_nombre_usuario(x.quien)), ''[]''::jsonb) INTO v_registradores
      FROM (
        SELECT DISTINCT g.usuario_id AS quien
          FROM ventas.gestiones g
         WHERE g.cliente_id = p_cliente_id
           AND g.usuario_id IS NOT NULL';

    -- 4. Y el nombre con el que viaja en la respuesta
    c_salida_vieja constant text := '''filtros'', jsonb_build_object(''registradores'', v_registradores)';
    c_salida_nueva constant text := '''filtros'', jsonb_build_object(''responsables'', v_registradores)';
BEGIN
    SELECT pg_get_functiondef(p.oid) INTO v_def
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'ventas' AND p.proname = 'fn_gestiones_listar_paginado' AND p.prokind = 'f';

    IF v_def IS NULL THEN
        RAISE EXCEPTION 'no existe ventas.fn_gestiones_listar_paginado';
    END IF;

    IF position('p_responsable_id' IN v_def) > 0 THEN
        RAISE NOTICE 'fn_gestiones_listar_paginado ya filtra por responsable';
        RETURN;
    END IF;

    -- Se comprueban TODAS las anclas antes de tocar nada
    v_cuantas := (length(v_def) - length(replace(v_def, c_param_viejo, ''))) / length(c_param_viejo);
    IF v_cuantas <> 1 THEN RAISE EXCEPTION 'la firma aparece % veces y esperaba 1', v_cuantas; END IF;

    v_cuantas := (length(v_def) - length(replace(v_def, c_filtro_viejo, ''))) / length(c_filtro_viejo);
    IF v_cuantas <> 2 THEN RAISE EXCEPTION 'el filtro aparece % veces y esperaba 2 (total y página)', v_cuantas; END IF;

    v_cuantas := (length(v_def) - length(replace(v_def, c_lista_vieja, ''))) / length(c_lista_vieja);
    IF v_cuantas <> 1 THEN RAISE EXCEPTION 'el desplegable aparece % veces y esperaba 1', v_cuantas; END IF;

    v_cuantas := (length(v_def) - length(replace(v_def, c_salida_vieja, ''))) / length(c_salida_vieja);
    IF v_cuantas <> 1 THEN RAISE EXCEPTION 'la salida aparece % veces y esperaba 1', v_cuantas; END IF;

    v_nueva := replace(v_def,   c_param_viejo,  c_param_nuevo);
    v_nueva := replace(v_nueva, c_filtro_viejo, c_filtro_nuevo);   -- las dos
    v_nueva := replace(v_nueva, c_lista_vieja,  c_lista_nueva);
    v_nueva := replace(v_nueva, c_salida_vieja, c_salida_nueva);

    IF position('p_creado_por' IN v_nueva) > 0 THEN
        RAISE EXCEPTION 'quedó alguna referencia a p_creado_por';
    END IF;

    -- Fuera la de la firma vieja, o quedarían las dos
    FOR v_firma IN
        SELECT 'ventas.fn_gestiones_listar_paginado(' || pg_get_function_identity_arguments(p.oid) || ')'
          FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
         WHERE n.nspname = 'ventas' AND p.proname = 'fn_gestiones_listar_paginado' AND p.prokind = 'f'
    LOOP
        EXECUTE 'DROP FUNCTION IF EXISTS ' || v_firma;
        RAISE NOTICE 'tirada %', v_firma;
    END LOOP;

    EXECUTE v_nueva;
    RAISE NOTICE 'fn_gestiones_listar_paginado actualizada: filtra por responsable';
END;
$$;


-- ---------------------------------------------------------------------------
-- COMPROBACIÓN
-- ---------------------------------------------------------------------------
-- Sin filtro y filtrando por un responsable, con el desplegable que sale:
--
--   SELECT (ventas.fn_gestiones_listar_paginado(1055,1,10,NULL,NULL,NULL,NULL,NULL,NULL,NULL,46) -> 'meta' ->> 'total') AS todas,
--          (ventas.fn_gestiones_listar_paginado(1055,1,10,NULL,NULL,NULL,NULL,NULL,NULL,46,46)   -> 'meta' ->> 'total') AS de_vcuenca1,
--          (ventas.fn_gestiones_listar_paginado(1055,1,10,NULL,NULL,NULL,NULL,NULL,NULL,NULL,46) -> 'filtros') AS responsables;
