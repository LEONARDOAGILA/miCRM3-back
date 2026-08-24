-- FUNCTION: auditoria.fn_registrar_evento(character varying, bigint, character varying, jsonb, jsonb, bigint, character varying, character varying, inet, text, uuid, character varying)

-- DROP FUNCTION IF EXISTS auditoria.fn_registrar_evento(character varying, bigint, character varying, jsonb, jsonb, bigint, character varying, character varying, inet, text, uuid, character varying);

CREATE OR REPLACE FUNCTION auditoria.fn_registrar_evento(
	p_tabla_afectada character varying,
	p_id_registro_afectado bigint,
	p_tipo_operacion character varying,
	p_datos_anteriores jsonb DEFAULT NULL::jsonb,
	p_datos_nuevos jsonb DEFAULT NULL::jsonb,
	p_usuario_id bigint DEFAULT NULL::bigint,
	p_usuario_login character varying DEFAULT NULL::character varying,
	p_usuario_nombre character varying DEFAULT NULL::character varying,
	p_ip_address inet DEFAULT NULL::inet,
	p_user_agent text DEFAULT NULL::text,
	p_request_id uuid DEFAULT NULL::uuid,
	p_modulo character varying DEFAULT NULL::character varying)
    RETURNS void
    LANGUAGE 'plpgsql'
    COST 100
    VOLATILE SECURITY DEFINER PARALLEL UNSAFE
AS $BODY$
BEGIN
    INSERT INTO auditoria.auditoria (
        tabla_afectada,
        id_registro_afectado,
        tipo_operacion,
        datos_anteriores,
        datos_nuevos,
        fecha_operacion,
        usuario_operador,
        ip_address,
        user_agent,
        request_id,
        modulo
    ) VALUES (
        p_tabla_afectada,
        p_id_registro_afectado,
        p_tipo_operacion,
        p_datos_anteriores,
        p_datos_nuevos,
        CURRENT_TIMESTAMP,
        CONCAT_WS(' - ', p_usuario_id, p_usuario_login, p_usuario_nombre),
        p_ip_address,
        p_user_agent,
        p_request_id,
        COALESCE(p_modulo, p_tabla_afectada)
    );
END;
$BODY$;

ALTER FUNCTION auditoria.fn_registrar_evento(character varying, bigint, character varying, jsonb, jsonb, bigint, character varying, character varying, inet, text, uuid, character varying)
    OWNER TO postgres;

