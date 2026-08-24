-- FUNCTION: auditoria.fn_crear_particion_mes_siguiente()

-- DROP FUNCTION IF EXISTS auditoria.fn_crear_particion_mes_siguiente();

CREATE OR REPLACE FUNCTION auditoria.fn_crear_particion_mes_siguiente(
	)
    RETURNS jsonb
    LANGUAGE 'plpgsql'
    COST 100
    VOLATILE PARALLEL UNSAFE
AS $BODY$
DECLARE
    v_fecha_inicio DATE;
    v_fecha_fin DATE;
    v_nombre_particion TEXT;
    v_mes_actual TEXT;
    v_resultado JSONB;
    v_existe BOOLEAN;
BEGIN
    -- Calcular primer día del próximo mes
    v_fecha_inicio := date_trunc('month', CURRENT_DATE + INTERVAL '1 month');
    v_fecha_fin := v_fecha_inicio + INTERVAL '1 month';
    v_mes_actual := to_char(v_fecha_inicio, 'YYYY_MM');
    v_nombre_particion := 'logs_cambios_' || v_mes_actual;
    
    -- Verificar si la partición ya existe
    SELECT EXISTS(
        SELECT 1 FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'auditoria' 
          AND c.relname = v_nombre_particion
          AND c.relkind = 'r'
    ) INTO v_existe;
    
    IF NOT v_existe THEN
        -- Crear la partición
        EXECUTE format('
            CREATE TABLE IF NOT EXISTS auditoria.fn_%I PARTITION OF auditoria.logs_cambios
            FOR VALUES FROM (%L) TO (%L)',
            v_nombre_particion,
            v_fecha_inicio,
            v_fecha_fin
        );
        
        -- Crear índices en la nueva partición (opcional, se heredan automáticamente)
        EXECUTE format('
            CREATE INDEX IF NOT EXISTS idx_%I_registro ON auditoria.fn_%I (schema_nombre, tabla_nombre, registro_id)',
            v_nombre_particion, v_nombre_particion
        );
        
        EXECUTE format('
            CREATE INDEX IF NOT EXISTS idx_%I_fecha ON auditoria.fn_%I (fecha_operacion)',
            v_nombre_particion, v_nombre_particion
        );
        
        v_resultado := jsonb_build_object(
            'success', true,
            'message', 'Partición creada exitosamente',
            'particion', v_nombre_particion,
            'desde', v_fecha_inicio,
            'hasta', v_fecha_fin
        );
    ELSE
        v_resultado := jsonb_build_object(
            'success', false,
            'message', 'La partición ya existe',
            'particion', v_nombre_particion,
            'desde', v_fecha_inicio,
            'hasta', v_fecha_fin
        );
    END IF;
    
    RETURN v_resultado;
    
EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object(
            'success', false,
            'message', 'Error al crear partición: ' || SQLERRM,
            'error_code', SQLSTATE
        );
END;
$BODY$;

ALTER FUNCTION auditoria.fn_crear_particion_mes_siguiente()
    OWNER TO postgres;

