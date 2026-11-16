-- ===========================================================================
-- UNA CATEGORÍA QUE ADMITE PRODUCTOS NO ADMITE SUBCATEGORÍAS
-- ===========================================================================
-- Los productos cuelgan de las HOJAS del árbol. Si una categoría con
-- productos recibiera subcategorías habría que decidir qué pasa con esos
-- productos, y eso no se resuelve solo; y si se le marcara «admite productos»
-- a una que ya tiene subcategorías, productos y subcategorías quedarían
-- colgando de lo mismo.
--
-- Es la misma regla que en el plan de cuentas con «recibe asientos»
-- (contabilidad.fn_plan_cuentas_crear), y se corta en los tres sitios por los
-- que se podía llegar: al crear una subcategoría, al arrastrar una dentro, y
-- al marcar la casilla en la ficha.
--
-- Para convertir una hoja en rama: primero se le quita «admite productos» en
-- su ficha —cosa que el servidor ya impide si tiene productos dentro, así que
-- hay que moverlos antes— y después se le cuelgan subcategorías.
--
-- Al aplicar esto, el árbol de ahora ya cumple la regla: ninguna categoría
-- que admita productos tiene subcategorías.
\set ON_ERROR_STOP on

BEGIN;

CREATE OR REPLACE FUNCTION inventarios.fn_categorias_crear(p_nombre character varying, p_padre_id bigint DEFAULT NULL::bigint, p_descripcion text DEFAULT NULL::text, p_icono character varying DEFAULT NULL::character varying, p_activo boolean DEFAULT true, p_es_transaccion boolean DEFAULT true, p_usuario_id bigint DEFAULT NULL::bigint, p_usuario_login character varying DEFAULT NULL::character varying, p_usuario_nombre character varying DEFAULT NULL::character varying, p_ip_address inet DEFAULT NULL::inet, p_user_agent text DEFAULT NULL::text, p_request_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'inventarios', 'auditoria'
AS $function$
DECLARE
    v_id    bigint;
    v_nivel integer := 0;
    v_orden integer;
    v_nuevo jsonb;
BEGIN
    PERFORM inventarios.fn_contexto_auditoria('inventarios.categorias',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    IF p_nombre IS NULL OR length(TRIM(p_nombre)) < 2 THEN
        RAISE EXCEPTION 'El nombre de la categoría es obligatorio (mínimo 2 caracteres)' USING ERRCODE = 'P0001';
    END IF;

    IF p_padre_id IS NOT NULL THEN
        SELECT nivel + 1 INTO v_nivel FROM inventarios.categorias WHERE id = p_padre_id;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'La categoría padre no existe' USING ERRCODE = 'P0016';
        END IF;
        IF v_nivel > 3 THEN
            RAISE EXCEPTION 'El árbol admite hasta cuatro niveles (0 a 3) y ahí quedaría en el %', v_nivel
                USING ERRCODE = 'P0015';
        END IF;

        -- UNA CATEGORÍA QUE ADMITE PRODUCTOS NO ADMITE SUBCATEGORÍAS. Los
        -- productos cuelgan de las hojas: si se le metiera una subcategoría
        -- debajo habría que decidir qué pasa con los que ya tiene —se quedan,
        -- se reparten, se mueven—, y eso no se hace solo ni en silencio.
        -- Primero se le quita «admite productos», que es una decisión
        -- consciente y que el servidor ya impide si tiene productos dentro.
        IF (SELECT es_transaccion FROM inventarios.categorias WHERE id = p_padre_id) THEN
            RAISE EXCEPTION 'La categoría «%» admite productos y por eso no admite subcategorías. Quítele «admite productos» en su ficha y vuelva a intentarlo.',
                  (SELECT nombre FROM inventarios.categorias WHERE id = p_padre_id)
                USING ERRCODE = 'P0021';
        END IF;
    END IF;

    -- Entre hermanos el nombre no se repite; en otra rama sí puede
    IF EXISTS (SELECT 1 FROM inventarios.categorias
                WHERE padre_id IS NOT DISTINCT FROM p_padre_id
                  AND UPPER(TRIM(nombre)) = UPPER(TRIM(p_nombre))) THEN
        -- Puede estar en la papelera: el índice único también cuenta a las
        -- eliminadas, y sin decirlo el mensaje desconcierta porque ese
        -- nombre no aparece en el árbol.
        IF EXISTS (SELECT 1 FROM inventarios.categorias
                    WHERE padre_id IS NOT DISTINCT FROM p_padre_id
                      AND UPPER(TRIM(nombre)) = UPPER(TRIM(p_nombre))
                      AND deleted_at IS NOT NULL) THEN
            RAISE EXCEPTION 'Ya existe una categoría con ese nombre en el mismo nivel, y está en la papelera de reciclaje' USING ERRCODE = 'P0006';
        END IF;
        RAISE EXCEPTION 'Ya existe una categoría con ese nombre en el mismo nivel' USING ERRCODE = 'P0006';
    END IF;

    -- Al final de sus hermanos, sin pisar el orden de los que ya están
    SELECT COALESCE(MAX(orden), 0) + 1 INTO v_orden
      FROM inventarios.categorias WHERE padre_id IS NOT DISTINCT FROM p_padre_id;

    v_nuevo := jsonb_build_object(
        'padre_id',    p_padre_id,
        'nivel',       v_nivel,
        'orden',       v_orden,
        'nombre',      TRIM(p_nombre),
        'descripcion', NULLIF(TRIM(COALESCE(p_descripcion, '')), ''),
        'icono',       NULLIF(TRIM(COALESCE(p_icono, '')), ''),
        'activo',      COALESCE(p_activo, true),
        'es_transaccion', COALESCE(p_es_transaccion, true)
    );
    PERFORM set_config('app.datos_nuevos', v_nuevo::text, true);

    INSERT INTO inventarios.categorias (padre_id, orden, nivel, nombre, descripcion, icono, activo, es_transaccion)
    VALUES (
        p_padre_id, v_orden, v_nivel,
        TRIM(p_nombre),
        NULLIF(TRIM(COALESCE(p_descripcion, '')), ''),
        NULLIF(TRIM(COALESCE(p_icono, '')), ''),
        COALESCE(p_activo, true),
        COALESCE(p_es_transaccion, true)
    )
    RETURNING id INTO v_id;

    PERFORM set_config('app.datos_nuevos', '', true);

    RETURN jsonb_build_object('success', true, 'message', 'Categoría creada exitosamente',
                              'data', inventarios.fn_categorias_json(v_id));

EXCEPTION
    WHEN unique_violation THEN
        RAISE EXCEPTION 'Ya existe una categoría con ese nombre en el mismo nivel' USING ERRCODE = 'P0006';
END;
$function$;

CREATE OR REPLACE FUNCTION inventarios.fn_categorias_mover(p_id bigint, p_padre_id bigint DEFAULT NULL::bigint, p_antes_de bigint DEFAULT NULL::bigint, p_usuario_id bigint DEFAULT NULL::bigint, p_usuario_login character varying DEFAULT NULL::character varying, p_usuario_nombre character varying DEFAULT NULL::character varying, p_ip_address inet DEFAULT NULL::inet, p_user_agent text DEFAULT NULL::text, p_request_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'inventarios', 'auditoria'
AS $function$
DECLARE
    v_padre_actual bigint;
    v_nivel_nuevo  integer;
    v_profundidad  integer;
    v_max_nivel    constant integer := 3;
    v_pos          integer;
    v_i            integer;
    v_fila         record;
BEGIN
    PERFORM inventarios.fn_contexto_auditoria('inventarios.categorias',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    SELECT padre_id INTO v_padre_actual FROM inventarios.categorias WHERE id = p_id;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'error_code', 'NO_EXISTE', 'message', 'La categoría no existe');
    END IF;

    IF p_padre_id IS NOT NULL THEN
        IF p_padre_id = p_id THEN
            RETURN jsonb_build_object('success', false, 'error_code', 'AUTOREFERENCIA',
                                      'message', 'Una categoría no puede estar dentro de sí misma');
        END IF;
        -- Una categoría de la papelera no es un destino: no se ve en el
        -- árbol, y lo que colgara de ella desaparecería con ella.
        IF NOT EXISTS (SELECT 1 FROM inventarios.categorias WHERE id = p_padre_id AND deleted_at IS NULL) THEN
            RETURN jsonb_build_object('success', false, 'error_code', 'PADRE_NO_EXISTE',
                                      'message', 'La categoría destino no existe');
        END IF;
        -- El destino no puede colgar de la que se mueve (ciclo)
        IF EXISTS (
            WITH RECURSIVE d AS (
                SELECT id FROM inventarios.categorias WHERE padre_id = p_id
                UNION ALL
                SELECT c.id FROM inventarios.categorias c JOIN d ON c.padre_id = d.id
            )
            SELECT 1 FROM d WHERE d.id = p_padre_id
        ) THEN
            RETURN jsonb_build_object('success', false, 'error_code', 'CICLO',
                                      'message', 'No se puede mover una categoría dentro de una de sus propias subcategorías');
        END IF;
        -- Lo mismo que en fn_categorias_crear: una categoría que admite
        -- productos no admite subcategorías
        IF (SELECT es_transaccion FROM inventarios.categorias WHERE id = p_padre_id) THEN
            RETURN jsonb_build_object('success', false, 'error_code', 'PADRE_ADMITE_PRODUCTOS',
                'message', format('«%s» admite productos y por eso no admite subcategorías. Quítale «admite productos» en su ficha y vuelve a intentarlo.',
                                  (SELECT nombre FROM inventarios.categorias WHERE id = p_padre_id)));
        END IF;

        SELECT nivel + 1 INTO v_nivel_nuevo FROM inventarios.categorias WHERE id = p_padre_id;
    ELSE
        v_nivel_nuevo := 0;
    END IF;

    -- Lo hondo que es la rama que se mueve (0 = sin hijos)
    WITH RECURSIVE d AS (
        SELECT id, 1 AS prof FROM inventarios.categorias WHERE padre_id = p_id
        UNION ALL
        SELECT c.id, d.prof + 1 FROM inventarios.categorias c JOIN d ON c.padre_id = d.id
    )
    SELECT COALESCE(MAX(prof), 0) INTO v_profundidad FROM d;

    IF v_nivel_nuevo + v_profundidad > v_max_nivel THEN
        RETURN jsonb_build_object('success', false, 'error_code', 'NIVEL_MAXIMO',
            'message', format('Ahí quedaría en el nivel %s y el árbol admite hasta el %s (lo que mueves tiene %s nivel(es) por debajo)',
                              v_nivel_nuevo + v_profundidad, v_max_nivel, v_profundidad));
    END IF;

    -- El nombre tampoco se puede repetir entre los hermanos NUEVOS
    IF EXISTS (SELECT 1 FROM inventarios.categorias
                WHERE padre_id IS NOT DISTINCT FROM p_padre_id
                  AND id <> p_id
                  AND UPPER(TRIM(nombre)) = (SELECT UPPER(TRIM(nombre)) FROM inventarios.categorias WHERE id = p_id)) THEN
        RETURN jsonb_build_object('success', false, 'error_code', 'NOMBRE_DUPLICADO',
                                  'message', 'Ahí ya hay una categoría con ese nombre');
    END IF;

    -- Padre y nivel; y el nivel de los descendientes, en cascada
    UPDATE inventarios.categorias
       SET padre_id = p_padre_id, nivel = v_nivel_nuevo
     WHERE id = p_id
       AND (padre_id IS DISTINCT FROM p_padre_id OR nivel IS DISTINCT FROM v_nivel_nuevo);

    FOR v_fila IN
        WITH RECURSIVE d AS (
            SELECT id, v_nivel_nuevo + 1 AS nivel_ok FROM inventarios.categorias WHERE padre_id = p_id
            UNION ALL
            SELECT c.id, d.nivel_ok + 1 FROM inventarios.categorias c JOIN d ON c.padre_id = d.id
        )
        SELECT d.id, d.nivel_ok FROM d JOIN inventarios.categorias c ON c.id = d.id
         WHERE c.nivel IS DISTINCT FROM d.nivel_ok
    LOOP
        UPDATE inventarios.categorias SET nivel = v_fila.nivel_ok WHERE id = v_fila.id;
    END LOOP;

    -- Sitio entre los hermanos del destino: se saca el movido, se mete
    -- delante de p_antes_de (o al final) y se renumera 1..N
    CREATE TEMP TABLE IF NOT EXISTS tmp_cat_hermanos (id bigint, pos integer) ON COMMIT DROP;
    DELETE FROM tmp_cat_hermanos;

    INSERT INTO tmp_cat_hermanos (id, pos)
    SELECT id, ROW_NUMBER() OVER (ORDER BY orden, nombre)
      FROM inventarios.categorias
     WHERE padre_id IS NOT DISTINCT FROM p_padre_id AND id <> p_id;

    IF p_antes_de IS NOT NULL AND p_antes_de <> p_id THEN
        SELECT pos INTO v_pos FROM tmp_cat_hermanos WHERE id = p_antes_de;
    END IF;
    IF v_pos IS NULL THEN
        SELECT COALESCE(MAX(pos), 0) + 1 INTO v_pos FROM tmp_cat_hermanos;
    END IF;

    UPDATE tmp_cat_hermanos SET pos = pos + 1 WHERE pos >= v_pos;
    INSERT INTO tmp_cat_hermanos (id, pos) VALUES (p_id, v_pos);

    v_i := 0;
    FOR v_fila IN SELECT id FROM tmp_cat_hermanos ORDER BY pos LOOP
        v_i := v_i + 1;
        UPDATE inventarios.categorias SET orden = v_i WHERE id = v_fila.id AND orden IS DISTINCT FROM v_i;
    END LOOP;

    -- Y los hermanos que dejó atrás, sin huecos
    IF v_padre_actual IS DISTINCT FROM p_padre_id THEN
        v_i := 0;
        FOR v_fila IN
            SELECT id FROM inventarios.categorias
             WHERE padre_id IS NOT DISTINCT FROM v_padre_actual
             ORDER BY orden, nombre
        LOOP
            v_i := v_i + 1;
            UPDATE inventarios.categorias SET orden = v_i WHERE id = v_fila.id AND orden IS DISTINCT FROM v_i;
        END LOOP;
    END IF;

    RETURN jsonb_build_object(
        'success', true,
        'message', CASE WHEN v_padre_actual IS DISTINCT FROM p_padre_id THEN 'Categoría movida' ELSE 'Orden actualizado' END,
        'data', inventarios.fn_categorias_json(p_id)
    );

EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false, 'error_code', SQLSTATE,
                              'message', 'Error al mover la categoría: ' || SQLERRM);
END;
$function$;

CREATE OR REPLACE FUNCTION inventarios.fn_categorias_modificar(p_id bigint, p_nombre character varying, p_descripcion text DEFAULT NULL::text, p_icono character varying DEFAULT NULL::character varying, p_activo boolean DEFAULT true, p_es_transaccion boolean DEFAULT true, p_usuario_id bigint DEFAULT NULL::bigint, p_usuario_login character varying DEFAULT NULL::character varying, p_usuario_nombre character varying DEFAULT NULL::character varying, p_ip_address inet DEFAULT NULL::inet, p_user_agent text DEFAULT NULL::text, p_request_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'inventarios', 'auditoria'
AS $function$
DECLARE
    v_antes  jsonb;
    v_padre  bigint;
    v_nuevo  jsonb;
BEGIN
    PERFORM inventarios.fn_contexto_auditoria('inventarios.categorias',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    SELECT padre_id INTO v_padre FROM inventarios.categorias WHERE id = p_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'La categoría no existe' USING ERRCODE = 'P0013';
    END IF;
    v_antes := inventarios.fn_categorias_json(p_id);

    IF p_nombre IS NULL OR length(TRIM(p_nombre)) < 2 THEN
        RAISE EXCEPTION 'El nombre de la categoría es obligatorio (mínimo 2 caracteres)' USING ERRCODE = 'P0001';
    END IF;
    IF EXISTS (SELECT 1 FROM inventarios.categorias
                WHERE padre_id IS NOT DISTINCT FROM v_padre
                  AND UPPER(TRIM(nombre)) = UPPER(TRIM(p_nombre))
                  AND id <> p_id) THEN
        RAISE EXCEPTION 'Ya existe otra categoría con ese nombre en el mismo nivel' USING ERRCODE = 'P0006';
    END IF;

    -- Y al revés que lo de abajo: marcárselo a una que YA tiene
    -- subcategorías dejaría productos y subcategorías colgando de lo mismo,
    -- que es justo lo que esta regla evita.
    IF COALESCE(p_es_transaccion, true) = true
       AND EXISTS (SELECT 1 FROM inventarios.categorias h
                    WHERE h.padre_id = p_id AND h.deleted_at IS NULL) THEN
        RAISE EXCEPTION 'No se puede marcar «admite productos»: la categoría tiene % subcategoría(s) y los productos van en ellas.',
              (SELECT COUNT(*) FROM inventarios.categorias h WHERE h.padre_id = p_id AND h.deleted_at IS NULL)
            USING ERRCODE = 'P0021';
    END IF;

    -- Quitarle «es transacción» a una categoría que YA tiene productos
    -- dejaría esos productos colgando de algo que el selector no ofrece y
    -- que fn_productos_validar rechaza: no se podrían ni guardar al
    -- editarlos. Primero se mueven los productos.
    IF COALESCE(p_es_transaccion, true) = false
       AND EXISTS (SELECT 1 FROM inventarios.productos p
                    WHERE p.categoria_id = p_id AND p.deleted_at IS NULL) THEN
        RAISE EXCEPTION 'No se puede quitar «es transacción»: la categoría tiene % producto(s). Muévalos antes a otra categoría.',
              (SELECT COUNT(*) FROM inventarios.productos p WHERE p.categoria_id = p_id AND p.deleted_at IS NULL)
              USING ERRCODE = 'P0021';
    END IF;

    v_nuevo := jsonb_build_object(
        'nombre',      TRIM(p_nombre),
        'descripcion', NULLIF(TRIM(COALESCE(p_descripcion, '')), ''),
        'icono',       NULLIF(TRIM(COALESCE(p_icono, '')), ''),
        'activo',      COALESCE(p_activo, true),
        'es_transaccion', COALESCE(p_es_transaccion, true)
    );
    PERFORM set_config('app.datos_anteriores',
        jsonb_build_object('nombre',      v_antes->>'nombre',
                           'descripcion', v_antes->>'descripcion',
                           'icono',       v_antes->>'icono',
                           'activo',      (v_antes->>'activo')::boolean,
                           'es_transaccion', (v_antes->>'es_transaccion')::boolean)::text, true);
    PERFORM set_config('app.datos_nuevos', v_nuevo::text, true);

    UPDATE inventarios.categorias
       SET nombre      = TRIM(p_nombre),
           descripcion = NULLIF(TRIM(COALESCE(p_descripcion, '')), ''),
           icono       = NULLIF(TRIM(COALESCE(p_icono, '')), ''),
           activo      = COALESCE(p_activo, true),
           es_transaccion = COALESCE(p_es_transaccion, true)
     WHERE id = p_id;

    PERFORM set_config('app.datos_anteriores', '', true);
    PERFORM set_config('app.datos_nuevos', '', true);

    RETURN jsonb_build_object('success', true, 'message', 'Categoría actualizada exitosamente',
                              'data', inventarios.fn_categorias_json(p_id));

EXCEPTION
    WHEN unique_violation THEN
        -- El índice único cuenta también a las que están en la papelera
        RAISE EXCEPTION 'Ya existe otra categoría con ese nombre en el mismo nivel (puede estar en la papelera de reciclaje)' USING ERRCODE = 'P0006';
END;
$function$;

COMMIT;
