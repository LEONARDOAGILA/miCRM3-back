-- ===========================================================================
-- EL BUSCADOR DEL HISTORIAL: POR CUALQUIER CAMPO DE LA REJILLA
-- ===========================================================================
-- Fecha: 2026-10-09
-- Se aplica después de 2026-10-09_ventas_historial_filtro_responsable.sql.
--
-- fn_gestiones_listar_paginado ya recibía p_search, pero sólo miraba el asunto
-- y la nota —y la pantalla ni lo mandaba—. El historial enseña diez columnas,
-- así que buscar «VENTA», «1527» o «vencida» no encontraba nada.
--
-- Ahora el término se busca en TODO lo que se ve en la rejilla: el id, el
-- responsable, el estado, el tipo, el asunto, la nota, el resultado, la
-- prioridad, la duración, las fechas y quién la registró.
--
-- LA BÚSQUEDA ES DEL SERVIDOR, no del navegador. El historial se pagina en el
-- servidor: filtrar en el navegador buscaría sólo en las diez filas que están
-- a la vista, que es justo lo que haría pensar que no hay resultados.
--
-- SE ARMA EN UNA FUNCIÓN (fn_gestion_buscable) y no con una tira de OR en cada
-- consulta: la condición va en la del total y en la de la página, y con doce
-- campos esa tira duplicada son veinticuatro sitios donde olvidarse de añadir
-- la columna nueva. Así es uno.
--
-- SIN TILDES Y SIN MAYÚSCULAS, los dos lados. Nadie escribe «cotización» con
-- tilde en un buscador, y antes de esto «cotizacion» no encontraba nada.
-- Se hace con translate y no con la extensión unaccent —que está disponible
-- pero no instalada— para no añadirle a la base una dependencia que luego hay
-- que acordarse de instalar también en la oficina.
--
-- Idempotente, y se puede aplicar tanto sobre la versión original (la que
-- busca sólo en asunto y nota) como sobre una intermedia.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- 1. Quitar tildes y bajar a minúsculas
-- ---------------------------------------------------------------------------
-- Se baja a minúsculas ANTES de traducir: así basta con la lista de
-- minúsculas y no hay que mantener las dos, que es donde se descuadran las
-- cadenas de translate (tienen que medir lo mismo, carácter a carácter).
--
-- La ñ se trata como n a propósito: quien escribe «manana» quiere encontrar
-- «mañana».
CREATE OR REPLACE FUNCTION ventas.fn_sin_tildes(p_texto text)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $function$
    SELECT translate(lower(COALESCE(p_texto, '')),
                     'áéíóúüàèìòùâêîôûäëïöãõñç',
                     'aeiouuaeiouaeiouaeioaonc');
$function$;

COMMENT ON FUNCTION ventas.fn_sin_tildes(text)
    IS 'Minúsculas y sin tildes, para comparar lo que se busca con lo que hay';


-- ---------------------------------------------------------------------------
-- 2. Todo lo que se ve de una gestión, en un solo texto
-- ---------------------------------------------------------------------------
-- concat_ws se come los NULL sin dejar separadores dobles, que es justo lo que
-- hace falta aquí: casi toda gestión tiene la mitad de los campos vacíos.
--
-- Las fechas van en los dos formatos, el de la pantalla y el ISO: quien busca
-- «09/10» y quien busca «2026-10» están buscando lo mismo.
--
-- El tipo se busca por su código Y por su nombre del catálogo, porque la
-- rejilla enseña el nombre («Llamada») y la columna guarda el código
-- («LLAMADA»): sin el nombre, buscar lo que se lee no encontraría nada.
--
-- VENCIDA no es una columna, es lo que pinta la rejilla cuando una pendiente
-- se pasó de fecha. Se añade al texto para que buscar «vencida» funcione.
CREATE OR REPLACE FUNCTION ventas.fn_gestion_buscable(p_id bigint)
RETURNS text
LANGUAGE sql
STABLE
SECURITY DEFINER
AS $function$
    SELECT ventas.fn_sin_tildes(concat_ws(' ',
               g.id::text,
               g.tipo,
               (SELECT t.nombre FROM ventas.gestiones_tipos t WHERE t.codigo = g.tipo),
               g.estado,
               CASE WHEN g.estado = 'PENDIENTE' AND g.fecha_programada < CURRENT_TIMESTAMP
                    THEN 'VENCIDA' END,
               g.prioridad,
               g.asunto,
               g.nota,
               g.resultado,
               g.duracion_minutos::text,
               ventas.fn_nombre_usuario(g.usuario_id),
               g.created_by,
               ventas.fn_nombre_usuario_login(g.created_by),
               to_char(g.fecha_programada, 'DD/MM/YYYY HH24:MI'),
               to_char(g.fecha_programada, 'YYYY-MM-DD'),
               to_char(g.fecha_realizada,  'DD/MM/YYYY HH24:MI'),
               to_char(g.fecha_realizada,  'YYYY-MM-DD'),
               g.modo_registro
           ))
      FROM ventas.gestiones g
     WHERE g.id = p_id;
$function$;

COMMENT ON FUNCTION ventas.fn_gestion_buscable(bigint)
    IS 'Todo lo que se ve de una gestión en un solo texto, en minúsculas y sin tildes, para el buscador del historial';


-- ---------------------------------------------------------------------------
-- 3. Que el buscador del historial mire ahí
-- ---------------------------------------------------------------------------
-- La condición está en la consulta del total y en la de la página, con sangría
-- distinta, así que son dos sustituciones por forma. Se intentan las dos
-- formas de partida —la original y una intermedia— y se comprueba cada ancla
-- antes de tocar nada.
--
-- LIKE y no ILIKE: los dos lados vienen ya en minúsculas, y así el índice de
-- texto que algún día se ponga sí podría usarse.
DO $$
DECLARE
    v_def     text;
    v_nueva   text;
    v_cuantas int;
    v_hechas  int := 0;

    -- Forma original: buscaba sólo en el asunto y la nota
    c_a1 constant text :=
'       AND (v_filtro IS NULL
            OR g.asunto ILIKE ''%'' || v_filtro || ''%''
            OR g.nota   ILIKE ''%'' || v_filtro || ''%'')';
    c_a2 constant text :=
'           AND (v_filtro IS NULL
                OR g.asunto ILIKE ''%'' || v_filtro || ''%''
                OR g.nota   ILIKE ''%'' || v_filtro || ''%'')';

    -- Forma intermedia: ya usaba fn_gestion_buscable, pero con ILIKE y sin
    -- quitar las tildes del término
    c_b constant text :=
'OR ventas.fn_gestion_buscable(g.id) ILIKE ''%'' || v_filtro || ''%'')';

    -- La final
    c_f1 constant text :=
'       AND (v_filtro IS NULL
            OR ventas.fn_gestion_buscable(g.id) LIKE ''%'' || ventas.fn_sin_tildes(v_filtro) || ''%'')';
    c_f2 constant text :=
'           AND (v_filtro IS NULL
                OR ventas.fn_gestion_buscable(g.id) LIKE ''%'' || ventas.fn_sin_tildes(v_filtro) || ''%'')';
    c_bf constant text :=
'OR ventas.fn_gestion_buscable(g.id) LIKE ''%'' || ventas.fn_sin_tildes(v_filtro) || ''%'')';
BEGIN
    SELECT pg_get_functiondef(p.oid) INTO v_def
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'ventas' AND p.proname = 'fn_gestiones_listar_paginado' AND p.prokind = 'f';

    IF v_def IS NULL THEN
        RAISE EXCEPTION 'no existe ventas.fn_gestiones_listar_paginado';
    END IF;

    IF position('fn_sin_tildes(v_filtro)' IN v_def) > 0 THEN
        RAISE NOTICE 'fn_gestiones_listar_paginado ya busca por todos los campos, sin tildes';
        RETURN;
    END IF;

    v_nueva := v_def;

    -- Desde la forma original
    IF position(c_a1 IN v_nueva) > 0 THEN
        v_cuantas := (length(v_nueva) - length(replace(v_nueva, c_a1, ''))) / length(c_a1);
        IF v_cuantas <> 1 THEN RAISE EXCEPTION 'la condición del total aparece % veces y esperaba 1', v_cuantas; END IF;
        v_nueva  := replace(v_nueva, c_a1, c_f1);
        v_hechas := v_hechas + 1;

        v_cuantas := (length(v_nueva) - length(replace(v_nueva, c_a2, ''))) / length(c_a2);
        IF v_cuantas <> 1 THEN RAISE EXCEPTION 'la condición de la página aparece % veces y esperaba 1', v_cuantas; END IF;
        v_nueva  := replace(v_nueva, c_a2, c_f2);
        v_hechas := v_hechas + 1;
    END IF;

    -- O desde la intermedia (las dos de golpe: la cadena es la misma)
    IF position(c_b IN v_nueva) > 0 THEN
        v_cuantas := (length(v_nueva) - length(replace(v_nueva, c_b, ''))) / length(c_b);
        IF v_cuantas <> 2 THEN RAISE EXCEPTION 'la condición intermedia aparece % veces y esperaba 2', v_cuantas; END IF;
        v_nueva  := replace(v_nueva, c_b, c_bf);
        v_hechas := v_hechas + 2;
    END IF;

    IF v_hechas <> 2 THEN
        RAISE EXCEPTION 'no se reconoció la condición de búsqueda (sustituciones: %)', v_hechas;
    END IF;

    EXECUTE v_nueva;
    RAISE NOTICE 'fn_gestiones_listar_paginado actualizada: busca por todos los campos, sin tildes';
END;
$$;


-- ---------------------------------------------------------------------------
-- COMPROBACIÓN
-- ---------------------------------------------------------------------------
--   SELECT ventas.fn_gestion_buscable(1527);
--
--   SELECT (ventas.fn_gestiones_listar_paginado(1055,1,10,NULL,        NULL,NULL,NULL,NULL,NULL,NULL,4) -> 'meta' ->> 'total') AS todas,
--          (ventas.fn_gestiones_listar_paginado(1055,1,10,'1527',      NULL,NULL,NULL,NULL,NULL,NULL,4) -> 'meta' ->> 'total') AS por_id,
--          (ventas.fn_gestiones_listar_paginado(1055,1,10,'cotizacion',NULL,NULL,NULL,NULL,NULL,NULL,4) -> 'meta' ->> 'total') AS sin_tilde,
--          (ventas.fn_gestiones_listar_paginado(1055,1,10,'VENCIDA',   NULL,NULL,NULL,NULL,NULL,NULL,4) -> 'meta' ->> 'total') AS vencidas;
