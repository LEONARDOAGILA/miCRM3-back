-- ===========================================================================
-- REPARTIR SÓLO LOS CLIENTES DE UNA ZONA
-- ===========================================================================
-- Fecha: 2026-10-10
-- Se aplica después de 2026-10-10_ventas_zonas.sql.
--
-- La pantalla de reparto en bloque pasa a poder abrirse desde el mapa de
-- zonas, acotada al área que se haya dibujado: se marca un polígono, se pulsa
-- «Clientes en la zona» y se reparten ésos y nada más.
--
-- Lo único que cambia en la base es un parámetro más, p_zona_id. Sin él la
-- función hace exactamente lo de siempre, así que la pantalla de Ventas >
-- Reparto de Clientes no se entera.
--
-- EL FILTRO ES EL MISMO QUE USA LA ZONA para contar sus clientes: primero la
-- caja que la envuelve —cuatro comparaciones que descartan casi todo— y
-- después la cuenta buena con fn_punto_en_zona. No se repite la geometría
-- aquí; se llama a lo que ya existe.
--
-- SE PARCHEA POR SUSTITUCIÓN sobre la definición que hay en la base, que es
-- de ciento sesenta líneas y de las que cambian dos. Si un ancla no aparece
-- las veces esperadas, revienta y no toca nada.
--
-- Cambia la firma, así que hay que TIRAR la función antes: con otra firma,
-- CREATE OR REPLACE no reemplaza, añade una sobrecarga y las llamadas de
-- cinco argumentos se quedarían resolviendo a la vieja.
--
-- Idempotente.
-- ===========================================================================

DO $$
DECLARE
    v_def   text;
    v_nueva text;

    -- 1. La firma: un parámetro más, al final, con valor por defecto
    c_firma_vieja constant text :=
        'p_filtros jsonb DEFAULT ''{}''::jsonb, p_usuario_id bigint DEFAULT NULL::bigint)';
    c_firma_nueva constant text :=
        'p_filtros jsonb DEFAULT ''{}''::jsonb, p_usuario_id bigint DEFAULT NULL::bigint, p_zona_id bigint DEFAULT NULL::bigint)';

    -- 2. El filtro, justo detrás del techo de visibilidad
    c_filtro_viejo constant text :=
        '           AND (p_usuario_id IS NULL OR v_ve_todo OR ventas.fn_cliente_es_de_alguno(c.id, v_usuarios))';
    c_filtro_nuevo constant text :=
'           AND (p_usuario_id IS NULL OR v_ve_todo OR ventas.fn_cliente_es_de_alguno(c.id, v_usuarios))
           -- Acotado a una zona del mapa, si se pidió. Primero la caja que la
           -- envuelve, que descarta casi todo sin mirar el polígono.
           AND (p_zona_id IS NULL OR EXISTS (
                   SELECT 1 FROM ventas.zonas z
                    WHERE z.id = p_zona_id
                      AND ventas.fn_coordenada_lat(c.coordenadas) BETWEEN z.min_lat AND z.max_lat
                      AND ventas.fn_coordenada_lng(c.coordenadas) BETWEEN z.min_lng AND z.max_lng
                      AND ventas.fn_punto_en_zona(
                              ventas.fn_coordenada_lat(c.coordenadas),
                              ventas.fn_coordenada_lng(c.coordenadas),
                              z.tipo, z.vertices, z.centro_lat, z.centro_lng, z.radio_metros)))';
BEGIN
    SELECT pg_get_functiondef(p.oid) INTO v_def
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'ventas' AND p.proname = 'fn_clientes_asignacion_listar';

    IF v_def IS NULL THEN
        RAISE EXCEPTION 'No existe ventas.fn_clientes_asignacion_listar';
    END IF;

    -- Ya parcheada: no se hace nada (idempotente)
    IF position('p_zona_id' in v_def) > 0 THEN
        RAISE NOTICE 'La función ya aceptaba p_zona_id; no se toca';
        RETURN;
    END IF;

    IF (length(v_def) - length(replace(v_def, c_firma_vieja, ''))) / length(c_firma_vieja) <> 1 THEN
        RAISE EXCEPTION 'La firma no aparece exactamente una vez; no se toca nada';
    END IF;
    IF (length(v_def) - length(replace(v_def, c_filtro_viejo, ''))) / length(c_filtro_viejo) <> 1 THEN
        RAISE EXCEPTION 'El ancla del filtro no aparece exactamente una vez; no se toca nada';
    END IF;

    v_nueva := replace(v_def, c_firma_vieja, c_firma_nueva);
    v_nueva := replace(v_nueva, c_filtro_viejo, c_filtro_nuevo);

    -- La firma cambia: hay que soltar la vieja o queda una sobrecarga
    DROP FUNCTION IF EXISTS ventas.fn_clientes_asignacion_listar(integer, integer, text, jsonb, bigint);

    EXECUTE v_nueva;
    RAISE NOTICE 'fn_clientes_asignacion_listar acepta ahora p_zona_id';
END $$;


-- ---------------------------------------------------------------------------
-- COMPROBACIÓN
-- ---------------------------------------------------------------------------
SELECT p.proname || '(' || pg_get_function_arguments(p.oid) || ')' AS firma
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname = 'ventas' AND p.proname = 'fn_clientes_asignacion_listar';
