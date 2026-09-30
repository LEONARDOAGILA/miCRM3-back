-- ============================================================================
-- seguridad.fn_menus_mover: mover un menú a otro padre y/o cambiar su orden
-- entre sus hermanos, arrastrando en el listado (allMenus), como en el
-- administrador de archivos.
--
--   p_id        menú que se mueve
--   p_padre_id  nuevo padre (NULL = raíz). Puede ser el mismo que ya tiene:
--               entonces sólo cambia el orden.
--   p_antes_de  hermano (dentro del nuevo padre) delante del cual se coloca;
--               NULL = al final.
--
-- Reglas:
--   - no puede moverse dentro de sí mismo ni de un descendiente (ciclo);
--   - el árbol tiene como máximo 4 niveles (0..3): se comprueba que el
--     subárbol movido quepa;
--   - se recalcula el nivel del menú y de todos sus descendientes;
--   - se renumera 1..N el orden de los hermanos del padre nuevo y, si cambió
--     de padre, también los del antiguo.
-- Mismo contexto de auditoría que fn_menus_modificar (los triggers de la
-- tabla registran cada UPDATE con el usuario real).
-- Idempotente: CREATE OR REPLACE.
-- ============================================================================
CREATE OR REPLACE FUNCTION seguridad.fn_menus_mover(
    p_id             bigint,
    p_padre_id       bigint  DEFAULT NULL,
    p_antes_de       bigint  DEFAULT NULL,
    p_usuario_id     bigint  DEFAULT NULL,
    p_usuario_login  varchar DEFAULT NULL,
    p_usuario_nombre varchar DEFAULT NULL,
    p_ip_address     inet    DEFAULT NULL,
    p_user_agent     text    DEFAULT NULL,
    p_request_id     uuid    DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
    v_padre_actual   bigint;
    v_nivel_nuevo    integer;
    v_profundidad    integer;   -- niveles que cuelgan del menú (0 = sin hijos)
    v_max_nivel      constant integer := 3;
    v_pos            integer;
    v_i              integer;
    v_hijo           record;
    v_resultado      jsonb;
BEGIN
    -- 1. Contexto de auditoría (igual que fn_menus_modificar)
    PERFORM set_config('app.usuario_id',     COALESCE(p_usuario_id::text, ''), true);
    PERFORM set_config('app.usuario_login',  COALESCE(p_usuario_login, current_user), true);
    PERFORM set_config('app.usuario_nombre', COALESCE(p_usuario_nombre, current_user), true);
    PERFORM set_config('app.ip_address',     p_ip_address::text, true);
    PERFORM set_config('app.user_agent',     p_user_agent, true);
    PERFORM set_config('app.request_id',     p_request_id::text, true);
    PERFORM set_config('app.modulo',         'seguridad.menus', true);

    -- 2. Validaciones
    SELECT padre_id INTO v_padre_actual FROM seguridad.menus WHERE id = p_id;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'message', 'El menú no existe', 'error_code', 'MENU_NO_EXISTE');
    END IF;

    IF p_padre_id IS NOT NULL THEN
        IF p_padre_id = p_id THEN
            RETURN jsonb_build_object('success', false, 'message', 'Un menú no puede estar dentro de sí mismo', 'error_code', 'AUTOREFERENCIA');
        END IF;
        IF NOT EXISTS (SELECT 1 FROM seguridad.menus WHERE id = p_padre_id) THEN
            RETURN jsonb_build_object('success', false, 'message', 'El menú destino no existe', 'error_code', 'PADRE_NO_EXISTE');
        END IF;
        -- El destino no puede colgar del menú que se mueve (ciclo)
        IF EXISTS (
            WITH RECURSIVE d AS (
                SELECT id FROM seguridad.menus WHERE padre_id = p_id
                UNION ALL
                SELECT m.id FROM seguridad.menus m JOIN d ON m.padre_id = d.id
            )
            SELECT 1 FROM d WHERE d.id = p_padre_id
        ) THEN
            RETURN jsonb_build_object('success', false, 'message', 'No se puede mover un menú dentro de uno de sus propios submenús', 'error_code', 'CICLO');
        END IF;
        SELECT nivel + 1 INTO v_nivel_nuevo FROM seguridad.menus WHERE id = p_padre_id;
    ELSE
        v_nivel_nuevo := 0;
    END IF;

    -- Profundidad del subárbol que se mueve (0 = sin hijos)
    WITH RECURSIVE d AS (
        SELECT id, 1 AS prof FROM seguridad.menus WHERE padre_id = p_id
        UNION ALL
        SELECT m.id, d.prof + 1 FROM seguridad.menus m JOIN d ON m.padre_id = d.id
    )
    SELECT COALESCE(MAX(prof), 0) INTO v_profundidad FROM d;

    IF v_nivel_nuevo + v_profundidad > v_max_nivel THEN
        RETURN jsonb_build_object('success', false,
            'message', format('Ahí quedaría en el nivel %s y el menú admite hasta el nivel %s (el menú que mueves tiene %s nivel(es) por debajo)',
                              v_nivel_nuevo + v_profundidad, v_max_nivel, v_profundidad),
            'error_code', 'NIVEL_MAXIMO');
    END IF;

    -- 3. Padre y nivel del menú; nivel de sus descendientes en cascada
    UPDATE seguridad.menus
       SET padre_id = p_padre_id, nivel = v_nivel_nuevo, updated_at = CURRENT_TIMESTAMP
     WHERE id = p_id
       AND (padre_id IS DISTINCT FROM p_padre_id OR nivel IS DISTINCT FROM v_nivel_nuevo);

    FOR v_hijo IN
        WITH RECURSIVE d AS (
            SELECT id, v_nivel_nuevo + 1 AS nivel_ok FROM seguridad.menus WHERE padre_id = p_id
            UNION ALL
            SELECT m.id, d.nivel_ok + 1 FROM seguridad.menus m JOIN d ON m.padre_id = d.id
        )
        SELECT d.id, d.nivel_ok FROM d JOIN seguridad.menus m ON m.id = d.id WHERE m.nivel IS DISTINCT FROM d.nivel_ok
    LOOP
        UPDATE seguridad.menus SET nivel = v_hijo.nivel_ok, updated_at = CURRENT_TIMESTAMP WHERE id = v_hijo.id;
    END LOOP;

    -- 4. Orden entre los hermanos del padre nuevo: quitar el movido, colocarlo
    --    delante de p_antes_de (o al final) y renumerar 1..N
    CREATE TEMP TABLE IF NOT EXISTS tmp_hermanos (id bigint, pos integer) ON COMMIT DROP;
    DELETE FROM tmp_hermanos;

    INSERT INTO tmp_hermanos (id, pos)
    SELECT id, ROW_NUMBER() OVER (ORDER BY orden, nombre)
      FROM seguridad.menus
     WHERE padre_id IS NOT DISTINCT FROM p_padre_id
       AND id <> p_id;

    IF p_antes_de IS NOT NULL AND p_antes_de <> p_id THEN
        SELECT pos INTO v_pos FROM tmp_hermanos WHERE id = p_antes_de;
    END IF;
    IF v_pos IS NULL THEN
        SELECT COALESCE(MAX(pos), 0) + 1 INTO v_pos FROM tmp_hermanos;   -- al final
    END IF;

    UPDATE tmp_hermanos SET pos = pos + 1 WHERE pos >= v_pos;   -- hueco
    INSERT INTO tmp_hermanos (id, pos) VALUES (p_id, v_pos);

    v_i := 0;
    FOR v_hijo IN SELECT id FROM tmp_hermanos ORDER BY pos LOOP
        v_i := v_i + 1;
        UPDATE seguridad.menus SET orden = v_i, updated_at = CURRENT_TIMESTAMP
         WHERE id = v_hijo.id AND orden IS DISTINCT FROM v_i;
    END LOOP;

    -- 5. Si cambió de padre, los hermanos que dejó atrás se renumeran sin huecos
    IF v_padre_actual IS DISTINCT FROM p_padre_id THEN
        v_i := 0;
        FOR v_hijo IN
            SELECT id FROM seguridad.menus
             WHERE padre_id IS NOT DISTINCT FROM v_padre_actual
             ORDER BY orden, nombre
        LOOP
            v_i := v_i + 1;
            UPDATE seguridad.menus SET orden = v_i, updated_at = CURRENT_TIMESTAMP
             WHERE id = v_hijo.id AND orden IS DISTINCT FROM v_i;
        END LOOP;
    END IF;

    -- 6. Resultado
    SELECT jsonb_build_object(
        'success', true,
        'message', CASE WHEN v_padre_actual IS DISTINCT FROM p_padre_id THEN 'Menú movido' ELSE 'Orden actualizado' END,
        'data', jsonb_build_object('id', m.id, 'nombre', m.nombre, 'padre_id', m.padre_id, 'nivel', m.nivel, 'orden', m.orden)
    ) INTO v_resultado
    FROM seguridad.menus m WHERE m.id = p_id;

    RETURN v_resultado;

EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object('success', false, 'message', 'Error al mover el menú: ' || SQLERRM, 'error_code', SQLSTATE);
END;
$function$;

ALTER FUNCTION seguridad.fn_menus_mover(bigint, bigint, bigint, bigint, varchar, varchar, inet, text, uuid) OWNER TO postgres;
COMMENT ON FUNCTION seguridad.fn_menus_mover(bigint, bigint, bigint, bigint, varchar, varchar, inet, text, uuid)
    IS 'Mueve un menú a otro padre y/o lo coloca delante de un hermano (arrastrar y soltar en allMenus); recalcula niveles y renumera el orden';
