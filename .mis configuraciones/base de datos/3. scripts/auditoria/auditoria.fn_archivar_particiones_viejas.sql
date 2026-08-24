-- FUNCTION: auditoria.fn_archivar_particiones_viejas(integer)

-- DROP FUNCTION IF EXISTS auditoria.fn_archivar_particiones_viejas(integer);

CREATE OR REPLACE FUNCTION auditoria.fn_archivar_particiones_viejas(
	p_meses_a_mantener integer DEFAULT 12)
    RETURNS jsonb
    LANGUAGE 'plpgsql'
    COST 100
    VOLATILE PARALLEL UNSAFE
AS $BODY$
DECLARE
    v_fecha_limite DATE;
    v_particion RECORD;
    v_resultado JSONB := '[]'::jsonb;
    v_fecha_particion DATE;
    v_anio INTEGER;
    v_mes INTEGER;
BEGIN
    -- Calcular fecha límite (primer día del mes, hace N meses)
    v_fecha_limite := date_trunc('month', CURRENT_DATE - (p_meses_a_mantener || ' months')::INTERVAL);
    
    -- Buscar particiones
    FOR v_particion IN 
        SELECT 
            c.relname as partition_name,
            pg_get_expr(c.relpartbound, c.oid) as range
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE c.relname LIKE 'logs_cambios_%'
          AND c.relkind = 'r'
          AND n.nspname = 'auditoria'
        ORDER BY c.relname
    LOOP
        -- Extraer año y mes del nombre de la partición (formato: logs_cambios_2026_03)
        BEGIN
            v_anio := split_part(v_particion.partition_name, '_', 3)::INTEGER;
            v_mes := split_part(v_particion.partition_name, '_', 4)::INTEGER;
            v_fecha_particion := make_date(v_anio, v_mes, 1);
            
            -- Si la partición es anterior a la fecha límite
            IF v_fecha_particion < v_fecha_limite THEN
                -- Detachar la partición (separar de la tabla principal)
                EXECUTE format('ALTER TABLE auditoria.logs_cambios DETACH PARTITION auditoria.fn_%I', 
                              v_particion.partition_name);
                
                v_resultado := v_resultado || jsonb_build_object(
                    'particion', v_particion.partition_name,
                    'fecha_particion', v_fecha_particion,
                    'accion', 'DETACHED',
                    'fecha_limite', v_fecha_limite,
                    'meses_a_mantener', p_meses_a_mantener
                );
            END IF;
        EXCEPTION WHEN OTHERS THEN
            -- Si no se puede parsear, continuar con la siguiente
            v_resultado := v_resultado || jsonb_build_object(
                'particion', v_particion.partition_name,
                'error', 'No se pudo parsear la fecha',
                'accion', 'SKIPPED'
            );
        END;
    END LOOP;
    
    RETURN v_resultado;
END;
$BODY$;

ALTER FUNCTION auditoria.fn_archivar_particiones_viejas(integer)
    OWNER TO postgres;

