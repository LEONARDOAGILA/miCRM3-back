-- ===========================================================================
-- LA AGENDA Y EL TABLERO, TAMBIÉN POR VISIBILIDAD
-- ===========================================================================
-- Fecha: 2026-10-08
-- Se aplica después de 2026-10-08_seguridad_visibilidad_datos_crud.sql.
--
-- Las tres funciones de aquí ya recortaban por JERARQUÍA (p_solicitante y
-- fn_usuarios_a_cargo). Lo que les faltaba es el segundo techo, el del alcance
-- del perfil: sin esto, un vendedor con GESTION en PROPIO deja de ver las
-- gestiones del cobrador en la ficha del cliente, pero las sigue viendo en su
-- agenda y las sigue contando en el tablero. Una puerta cerrada y dos abiertas
-- no es media seguridad: es ninguna, y encima confunde.
--
-- NO CAMBIA NINGUNA FIRMA, así que los controladores se quedan igual: las tres
-- ya reciben quién pregunta, que es todo lo que hace falta.
--
-- LOS DOS TECHOS SE CRUZAN, no se eligen: hay que estar dentro de la jerarquía
-- Y dentro del alcance. Con MI_PERFIL, por ejemplo, se ve lo de los del mismo
-- perfil QUE ADEMÁS estén en la jerarquía de quien mira; nadie gana visión
-- sobre gente que antes no veía.
--
-- «LO MÍO» NO SE TOCA (el bloque 'mias' del tablero): los cuatro alcances
-- incluyen siempre al propio usuario, así que filtrarlo sería escribir código
-- que no puede cambiar nada.
--
-- LA CARTERA TAMPOCO: los contadores de clientes van por jerarquía y punto.
-- Un cliente no es ninguno de los cuatro datos que se tapan; de hecho la idea
-- es justo esa, que se siga llegando al cliente y lo de dentro se decida
-- aparte. Por eso 'alcance' sigue diciendo TODO / EQUIPO / PROPIO por la
-- jerarquía, que es lo que describe.
--
-- SE PARCHEAN POR SUSTITUCIÓN y no pegando las funciones enteras: son 93, 123
-- y 208 líneas de las que aquí cambian dos o seis sitios, y copiarlas sería
-- mantener dos versiones. Si una ancla no aparece exactamente las veces
-- esperadas, la migración revienta y no toca nada: más vale que avise a que
-- deje una función a medias.
--
-- Idempotente: si ya nombran a fn_usuarios_visibles, no se vuelven a tocar.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- 1. Las dos agendas
-- ---------------------------------------------------------------------------
-- Las dos tienen la misma forma: resuelven v_ve_todo y v_ambito al principio y
-- después preguntan contra ellos. Basta con recortar v_ambito.
DO $$
DECLARE
    v_nombre  text;
    v_def     text;
    v_nueva   text;
    v_cuantas int;

    c_decl text := '    v_ambito   bigint[] := ''{}''::bigint[];';
    c_ambito text :=
'        IF NOT COALESCE(v_ve_todo, false) THEN
            v_ambito := ventas.fn_usuarios_a_cargo(p_solicitante);
        END IF;
    END IF;';
BEGIN
    FOREACH v_nombre IN ARRAY ARRAY['fn_gestiones_agenda', 'fn_gestiones_agenda_paginado'] LOOP
        SELECT pg_get_functiondef(p.oid) INTO v_def
          FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
         WHERE n.nspname = 'ventas' AND p.proname = v_nombre AND p.prokind = 'f';

        IF v_def IS NULL THEN
            RAISE NOTICE 'no existe %', v_nombre;
            CONTINUE;
        END IF;

        IF position('fn_usuarios_visibles' IN v_def) > 0 THEN
            RAISE NOTICE '% ya mira la visibilidad', v_nombre;
            CONTINUE;
        END IF;

        v_cuantas := (length(v_def) - length(replace(v_def, c_decl, ''))) / length(c_decl);
        IF v_cuantas <> 1 THEN
            RAISE EXCEPTION '% : esperaba 1 declaración de v_ambito y hay %', v_nombre, v_cuantas;
        END IF;

        v_cuantas := (length(v_def) - length(replace(v_def, c_ambito, ''))) / length(c_ambito);
        IF v_cuantas <> 1 THEN
            RAISE EXCEPTION '% : esperaba 1 bloque de ámbito y hay %', v_nombre, v_cuantas;
        END IF;

        v_nueva := replace(v_def, c_decl, c_decl || '
    v_visibles bigint[];');

        v_nueva := replace(v_nueva, c_ambito,
'        IF NOT COALESCE(v_ve_todo, false) THEN
            v_ambito := ventas.fn_usuarios_a_cargo(p_solicitante);
        END IF;

        -- El segundo techo: el alcance del perfil. NULL es «sin filtro»
        -- (alcance TODO), que es lo de los administradores y lo de todo el
        -- mundo mientras nadie configure nada; entonces esto no hace nada.
        --
        -- Se CRUZA con la jerarquía en vez de sustituirla: hay que estar en
        -- las dos listas. Si el cruce queda vacío no se ve ninguna gestión de
        -- nadie, que es lo prudente y lo que hace el historial.
        v_visibles := seguridad.fn_usuarios_visibles(p_solicitante, ''GESTION'');
        IF v_visibles IS NOT NULL THEN
            v_ve_todo := false;
            v_ambito  := ARRAY(SELECT x FROM unnest(v_ambito)   AS x
                               INTERSECT
                               SELECT y FROM unnest(v_visibles) AS y);
        END IF;
    END IF;');

        EXECUTE v_nueva;
        RAISE NOTICE '% actualizada', v_nombre;
    END LOOP;
END;
$$;


-- ---------------------------------------------------------------------------
-- 2. El tablero
-- ---------------------------------------------------------------------------
-- Aquí el ámbito es de CLIENTES (v_ids), no de usuarios, así que no se puede
-- recortar en un sitio: hay que añadir el filtro en cada bloque que cuente
-- gestiones. Son cinco consultas, y 'mias' se queda fuera a propósito.
DO $$
DECLARE
    v_def   text;
    v_nueva text;

    FUNCION  constant text := 'fn_estadisticas_generales';

    -- (ancla, reemplazo, veces que debe aparecer)
    c_anclas text[] := ARRAY[
        -- la declaración
        '    v_ids     bigint[] := ''{}''::bigint[];',
        -- el total de gestiones
        '    FROM ventas.gestiones
    WHERE v_todo OR cliente_id = ANY(v_ids);',
        -- la serie por día (dos subconsultas, las dos iguales)
        '                               AND (v_todo OR g.cliente_id = ANY(v_ids))',
        -- por tipo
        '         WHERE v_todo OR cliente_id = ANY(v_ids)
         GROUP BY tipo',
        -- por resultado
        '           AND (v_todo OR cliente_id = ANY(v_ids))
         GROUP BY resultado',
        -- las pendientes de cada vendedor
        '                   AND (v_todo OR c2.id = ANY(v_ids))) AS pendientes'
    ];
    c_veces int[] := ARRAY[1, 1, 2, 1, 1, 1];
    i int;
    v_cuantas int;
BEGIN
    SELECT pg_get_functiondef(p.oid) INTO v_def
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'ventas' AND p.proname = FUNCION AND p.prokind = 'f';

    IF v_def IS NULL THEN
        RAISE NOTICE 'no existe %', FUNCION;
        RETURN;
    END IF;

    IF position('fn_usuarios_visibles' IN v_def) > 0 THEN
        RAISE NOTICE '% ya mira la visibilidad', FUNCION;
        RETURN;
    END IF;

    -- Primero se comprueban TODAS las anclas, y sólo después se toca algo
    FOR i IN 1 .. array_length(c_anclas, 1) LOOP
        v_cuantas := (length(v_def) - length(replace(v_def, c_anclas[i], ''))) / length(c_anclas[i]);
        IF v_cuantas <> c_veces[i] THEN
            RAISE EXCEPTION '% : el ancla % aparece % veces y esperaba %', FUNCION, i, v_cuantas, c_veces[i];
        END IF;
    END LOOP;

    v_nueva := replace(v_def, c_anclas[1], c_anclas[1] || '
    v_visibles bigint[];');

    -- El alcance se resuelve una vez, justo antes de la etiqueta del ámbito
    v_nueva := replace(v_nueva, '    v_alcance := CASE',
'    -- El segundo techo: qué gestiones puede ver, además de de qué clientes.
    -- NULL es «sin filtro» (alcance TODO) y entonces nada de abajo cambia.
    v_visibles := seguridad.fn_usuarios_visibles(p_solicitante, ''GESTION'');

    v_alcance := CASE');

    v_nueva := replace(v_nueva, c_anclas[2],
'    FROM ventas.gestiones
    WHERE (v_todo OR cliente_id = ANY(v_ids))
      AND (v_visibles IS NULL OR usuario_id = ANY(v_visibles));');

    -- replace cambia las dos de la serie por día de una vez, que es lo que se quiere
    v_nueva := replace(v_nueva, c_anclas[3],
'                               AND (v_todo OR g.cliente_id = ANY(v_ids))
                               AND (v_visibles IS NULL OR g.usuario_id = ANY(v_visibles))');

    v_nueva := replace(v_nueva, c_anclas[4],
'         WHERE (v_todo OR cliente_id = ANY(v_ids))
           AND (v_visibles IS NULL OR usuario_id = ANY(v_visibles))
         GROUP BY tipo');

    v_nueva := replace(v_nueva, c_anclas[5],
'           AND (v_todo OR cliente_id = ANY(v_ids))
           AND (v_visibles IS NULL OR usuario_id = ANY(v_visibles))
         GROUP BY resultado');

    v_nueva := replace(v_nueva, c_anclas[6],
'                   AND (v_todo OR c2.id = ANY(v_ids))
                   AND (v_visibles IS NULL OR g.usuario_id = ANY(v_visibles))) AS pendientes');

    EXECUTE v_nueva;
    RAISE NOTICE '% actualizada', FUNCION;
END;
$$;


-- ---------------------------------------------------------------------------
-- COMPROBACIÓN
-- ---------------------------------------------------------------------------
-- Las tres tienen que nombrar ya a fn_usuarios_visibles:
--
--   SELECT p.proname, position('fn_usuarios_visibles' IN pg_get_functiondef(p.oid)) > 0 AS filtra
--     FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
--    WHERE n.nspname = 'ventas' AND p.prokind = 'f'
--      AND p.proname IN ('fn_gestiones_agenda', 'fn_gestiones_agenda_paginado', 'fn_estadisticas_generales');
--
-- Y con la tabla de visibilidad vacía, los números no se mueven.
