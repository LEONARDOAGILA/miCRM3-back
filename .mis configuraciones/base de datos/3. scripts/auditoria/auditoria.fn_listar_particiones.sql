-- FUNCTION: auditoria.fn_listar_particiones()

-- DROP FUNCTION IF EXISTS auditoria.fn_listar_particiones();

CREATE OR REPLACE FUNCTION auditoria.fn_listar_particiones(
	)
    RETURNS jsonb
    LANGUAGE 'plpgsql'
    COST 100
    VOLATILE PARALLEL UNSAFE
AS $BODY$
DECLARE
    v_resultado JSONB;
BEGIN
    SELECT jsonb_agg(
        jsonb_build_object(
            'particion', c.relname,
            'tamano', pg_size_pretty(pg_total_relation_size(c.oid)),
            'filas', c.reltuples::BIGINT,
            'desde', split_part(pg_get_expr(c.relpartbound, c.oid), 'FROM (', 2),
            'hasta', split_part(split_part(pg_get_expr(c.relpartbound, c.oid), 'TO (', 2), ')', 1)
        ) ORDER BY c.relname DESC
    ) INTO v_resultado
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE c.relname LIKE 'logs_cambios_%'
      AND c.relkind = 'r'
      AND n.nspname = 'auditoria';
    
    RETURN COALESCE(v_resultado, '[]'::jsonb);
END;
$BODY$;

ALTER FUNCTION auditoria.fn_listar_particiones()
    OWNER TO postgres;

