-- FUNCTION: seguridad.update_updated_at_column()

-- DROP FUNCTION IF EXISTS seguridad.update_updated_at_column();

CREATE OR REPLACE FUNCTION seguridad.update_updated_at_column()
    RETURNS trigger
    LANGUAGE 'plpgsql'
    COST 100
    VOLATILE NOT LEAKPROOF
AS $BODY$
BEGIN
    NEW.updated_at = CURRENT_TIMESTAMP;
    RETURN NEW;
END;
$BODY$;

ALTER FUNCTION seguridad.update_updated_at_column()
    OWNER TO postgres;
