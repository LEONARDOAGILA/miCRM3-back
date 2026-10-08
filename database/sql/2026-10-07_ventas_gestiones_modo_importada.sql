-- ===========================================================================
-- QUE LAS FUNCIONES ACEPTEN modo_registro = 'IMPORTADA'
-- ===========================================================================
-- Fecha: 2026-10-07
-- Se aplica después de 2026-10-07_ventas_gestiones_importadas.sql.
--
-- Aquella migración añadió 'IMPORTADA' a la restricción de la tabla y creó
-- fn_gestiones_importadas, pero se dejó la mitad del camino: fn_gestiones_crear
-- y fn_gestiones_modificar llevan SU PROPIA lista de modos válidos y seguían
-- con los tres de antes, así que al importar una conversación saltaba
--
--     ERROR: El modo de registro no es válido   (SQLSTATE P0022)
--
-- y la pantalla devolvía un 422. La restricción de la tabla no se llegaba a
-- probar nunca porque la función corta antes.
--
-- SE PARCHEA POR SUSTITUCIÓN, no pegando las funciones enteras. Son dos
-- funciones de ciento y pico líneas de las que sólo cambia una condición;
-- copiarlas aquí significaría mantener dos copias y arriesgarse a que la de
-- este fichero se quede atrás respecto a la de la base. Así se toma la que hay,
-- se le cambia esa línea y se vuelve a crear con la misma firma.
--
-- Idempotente: si ya dice 'IMPORTADA' no hace nada y lo avisa.
-- ===========================================================================

DO $$
DECLARE
    v_nombre    text;
    v_def       text;
    v_nueva     text;
    v_viejo     text := 'NOT IN (''AHORA'', ''YA_HECHA'', ''PROGRAMADA'')';
    v_nuevo     text := 'NOT IN (''AHORA'', ''YA_HECHA'', ''PROGRAMADA'', ''IMPORTADA'')';
    v_tocadas   int  := 0;
BEGIN
    FOR v_nombre, v_def IN
        SELECT p.proname, pg_get_functiondef(p.oid)
          FROM pg_proc p
          JOIN pg_namespace n ON n.oid = p.pronamespace
         WHERE n.nspname = 'ventas'
           AND p.proname IN ('fn_gestiones_crear', 'fn_gestiones_modificar')
    LOOP
        IF position(v_viejo IN v_def) = 0 THEN
            RAISE NOTICE '% ya acepta IMPORTADA (o no valida el modo): no se toca', v_nombre;
            CONTINUE;
        END IF;

        v_nueva := replace(v_def, v_viejo, v_nuevo);
        EXECUTE v_nueva;
        v_tocadas := v_tocadas + 1;
        RAISE NOTICE '% actualizada', v_nombre;
    END LOOP;

    RAISE NOTICE 'funciones actualizadas: %', v_tocadas;
END;
$$;


-- ---------------------------------------------------------------------------
-- COMPROBACIÓN
-- ---------------------------------------------------------------------------
-- Ninguna de las dos debe seguir con la lista de tres:
--
-- SELECT p.proname
--   FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
--  WHERE n.nspname = 'ventas'
--    AND p.proname IN ('fn_gestiones_crear', 'fn_gestiones_modificar')
--    AND pg_get_functiondef(p.oid) LIKE '%NOT IN (''AHORA'', ''YA_HECHA'', ''PROGRAMADA'')%';
