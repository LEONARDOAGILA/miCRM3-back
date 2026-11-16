-- ============================================================================
-- ECOMMERCE · LA PAPELERA DEL PIE
-- ============================================================================
-- Fecha: 2026-11-01
--
-- Al migrar el pie dejé el borrado SUAVE —columnas y enlaces se marcan con
-- `deleted_at`— pero sin nada para verlos ni devolverlos. Eso es lo peor de
-- las dos opciones: lo borrado no se puede recuperar Y se queda ahí ocupando
-- sitio para siempre, sin que nadie sepa que está.
--
-- Esto lo completa, con la misma forma que el encabezado y las páginas
-- informativas: un solo cesto para columnas y enlaces, porque borrar una
-- columna se lleva los suyos y hay que verlos juntos para entender qué pasó.
--
-- Idempotente.
-- ============================================================================
\set ON_ERROR_STOP on

BEGIN;

CREATE OR REPLACE FUNCTION ecommerce.fn_pie_papelera_listar()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
AS $function$
    SELECT jsonb_build_object('success', true, 'message', 'Papelera del pie',
        'data', COALESCE((
            SELECT jsonb_agg(x ORDER BY x ->> 'deleted_at' DESC, x ->> 'texto')
              FROM (
                SELECT jsonb_build_object(
                           'tipo', 'columna', 'id', c.id, 'texto', c.titulo, 'detalle', NULL,
                           'deleted_at', to_char(c.deleted_at, 'YYYY-MM-DD HH24:MI:SS'),
                           'deleted_by', c.deleted_by) AS x
                  FROM ecommerce.pie_columnas c WHERE c.deleted_at IS NOT NULL
                UNION ALL
                SELECT jsonb_build_object(
                           'tipo', 'enlace', 'id', l.id, 'texto', l.texto, 'detalle', l.enlace,
                           'columna_id', l.columna_id,
                           'deleted_at', to_char(l.deleted_at, 'YYYY-MM-DD HH24:MI:SS'),
                           'deleted_by', l.deleted_by)
                  FROM ecommerce.pie_enlaces l WHERE l.deleted_at IS NOT NULL
              ) t), '[]'::jsonb));
$function$;

-- Restaurar vale para los dos: la pantalla manda el tipo y el id.
CREATE OR REPLACE FUNCTION ecommerce.fn_pie_restaurar(
    p_tipo text, p_id bigint,
    p_usuario_id bigint DEFAULT NULL, p_usuario_login character varying DEFAULT NULL,
    p_usuario_nombre character varying DEFAULT NULL, p_ip_address inet DEFAULT NULL,
    p_user_agent text DEFAULT NULL, p_request_id uuid DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'ecommerce', 'auditoria'
AS $function$
DECLARE
    v_fecha timestamptz;
    v_texto text;
    v_hijos integer := 0;
BEGIN
    IF p_tipo NOT IN ('columna', 'enlace') THEN
        RAISE EXCEPTION 'Sólo se restauran columnas o enlaces' USING ERRCODE = 'P0015';
    END IF;

    PERFORM ecommerce.fn_contexto_auditoria('ecommerce.pie_' || p_tipo || 's',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    IF p_tipo = 'columna' THEN
        SELECT deleted_at, titulo INTO v_fecha, v_texto
          FROM ecommerce.pie_columnas WHERE id = p_id;
        IF NOT FOUND OR v_fecha IS NULL THEN
            RAISE EXCEPTION 'Esa columna no está en la papelera' USING ERRCODE = 'P0019';
        END IF;

        -- Vuelven sólo los enlaces que se fueron CON ella, por la marca de
        -- tiempo: los que ya estaban borrados antes se quedan donde están.
        UPDATE ecommerce.pie_enlaces
           SET deleted_at = NULL, deleted_by = NULL
         WHERE columna_id = p_id AND deleted_at = v_fecha;
        GET DIAGNOSTICS v_hijos = ROW_COUNT;

        UPDATE ecommerce.pie_columnas
           SET deleted_at = NULL, deleted_by = NULL WHERE id = p_id;
    ELSE
        SELECT deleted_at, texto INTO v_fecha, v_texto
          FROM ecommerce.pie_enlaces WHERE id = p_id;
        IF NOT FOUND OR v_fecha IS NULL THEN
            RAISE EXCEPTION 'Ese enlace no está en la papelera' USING ERRCODE = 'P0019';
        END IF;

        -- Un enlace cuya columna sigue en la papelera no puede volver: en el
        -- pie no hay «sin columna», se pinta DENTRO de una. Se dice en vez de
        -- restaurarlo a un sitio que no se ve.
        IF NOT EXISTS (SELECT 1 FROM ecommerce.pie_columnas c
                        JOIN ecommerce.pie_enlaces l ON l.columna_id = c.id
                       WHERE l.id = p_id AND c.deleted_at IS NULL) THEN
            RAISE EXCEPTION 'Primero hay que restaurar la columna donde iba «%»', v_texto
                  USING ERRCODE = 'P0016';
        END IF;

        UPDATE ecommerce.pie_enlaces
           SET deleted_at = NULL, deleted_by = NULL WHERE id = p_id;
    END IF;

    RETURN jsonb_build_object('success', true,
        'message', CASE WHEN p_tipo = 'columna' AND v_hijos > 0
                        THEN format('Columna «%s» restaurada con sus %s enlaces', v_texto, v_hijos)
                        ELSE format('«%s» restaurado', v_texto) END,
        'data', (ecommerce.fn_pie_obtener() -> 'data'));
END;
$function$;

CREATE OR REPLACE FUNCTION ecommerce.fn_pie_papelera_vaciar(
    p_usuario_id bigint DEFAULT NULL, p_usuario_login character varying DEFAULT NULL,
    p_usuario_nombre character varying DEFAULT NULL, p_ip_address inet DEFAULT NULL,
    p_user_agent text DEFAULT NULL, p_request_id uuid DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'ecommerce', 'auditoria'
AS $function$
DECLARE
    v_e integer;
    v_c integer;
BEGIN
    PERFORM ecommerce.fn_contexto_auditoria('ecommerce.pie_columnas',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    -- Los enlaces primero: apuntan a la columna con clave ajena
    DELETE FROM ecommerce.pie_enlaces WHERE deleted_at IS NOT NULL;
    GET DIAGNOSTICS v_e = ROW_COUNT;

    DELETE FROM ecommerce.pie_columnas WHERE deleted_at IS NOT NULL;
    GET DIAGNOSTICS v_c = ROW_COUNT;

    RETURN jsonb_build_object('success', true,
        'message', format('Papelera del pie vaciada: %s y %s',
            CASE v_e WHEN 1 THEN '1 enlace' ELSE v_e || ' enlaces' END,
            CASE v_c WHEN 1 THEN '1 columna' ELSE v_c || ' columnas' END),
        'data', jsonb_build_object('enlaces', v_e, 'columnas', v_c));
END;
$function$;

-- Que de verdad vaya y venga
DO $comprobar$
DECLARE
    v_col bigint;
    v_enl bigint;
    v    jsonb;
BEGIN
    -- Una columna propia con un enlace dentro
    INSERT INTO ecommerce.pie_columnas (titulo, orden) VALUES ('ZZ prueba papelera', 999)
    RETURNING id INTO v_col;
    INSERT INTO ecommerce.pie_enlaces (columna_id, texto, enlace, orden)
    VALUES (v_col, 'ZZ enlace', '/zz', 1) RETURNING id INTO v_enl;

    PERFORM ecommerce.fn_pie_columnas_eliminar(v_col);

    v := ecommerce.fn_pie_papelera_listar() -> 'data';
    IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v) x
                    WHERE (x ->> 'id')::bigint = v_col AND x ->> 'tipo' = 'columna') THEN
        RAISE EXCEPTION 'La columna borrada no aparece en la papelera';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v) x
                    WHERE (x ->> 'id')::bigint = v_enl AND x ->> 'tipo' = 'enlace') THEN
        RAISE EXCEPTION 'El enlace que se fue con ella no aparece en la papelera';
    END IF;

    PERFORM ecommerce.fn_pie_restaurar('columna', v_col);
    IF (SELECT deleted_at FROM ecommerce.pie_enlaces WHERE id = v_enl) IS NOT NULL THEN
        RAISE EXCEPTION 'El enlace no volvió con su columna';
    END IF;

    -- Y se limpia lo de la prueba, sólo lo mío
    DELETE FROM ecommerce.pie_enlaces  WHERE id = v_enl;
    DELETE FROM ecommerce.pie_columnas WHERE id = v_col;

    RAISE NOTICE 'Comprobado: la columna va a la papelera con su enlace y vuelve con él.';
END
$comprobar$;

COMMIT;
