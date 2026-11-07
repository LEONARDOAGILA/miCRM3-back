-- ============================================================================
-- EL VALOR DE UNA CARACTERÍSTICA, CONTRA SU TIPO
-- ============================================================================
-- Fecha: 2026-10-28
-- Va después de `2026-10-28_inventarios_caracteristicas_al_diccionario.sql`.
--
-- El diccionario ya dice que «Peso» es un número en kg, pero hasta ahora el
-- valor se guardaba como texto libre y daba igual: entraban «15», «15 kg» y
-- «15,5» en la misma característica, y entonces logística no puede ni sumar
-- ni ordenar. La pantalla del producto ya pinta el campo que toca y avisa al
-- salir de la celda; esto es el PORTERO, que es otra cosa: la pantalla se
-- puede saltar y la API está abierta a quien tenga el token.
--
-- Qué hace, por tipo:
--
--   NUMERO  la coma pasa a punto («15,5» se guarda «15.5», que es lo que
--           luego se puede castear) y lo que no sea un número se rechaza
--   SI_NO   se guarda «Sí» o «No», se escriba como se escriba
--   LISTA   tiene que ser una de las opciones de ESA categoría, y sólo si la
--           categoría definió alguna (si no, se deja pasar: la lista todavía
--           no existe)
--   TEXTO   lo que sea
--
-- Lo ya guardado NO se toca: esto sólo mira lo que llega. Comprobado antes de
-- escribirlo: los 6 valores que había encajan todos con su tipo.
--
-- Idempotente: es un CREATE OR REPLACE.
-- ============================================================================
\set ON_ERROR_STOP on

BEGIN;

CREATE OR REPLACE FUNCTION inventarios.fn_productos_caracteristicas_guardar(
    p_producto_id    bigint,
    p_items          jsonb,
    p_usuario_id     bigint  DEFAULT NULL,
    p_usuario_login  character varying DEFAULT NULL,
    p_usuario_nombre character varying DEFAULT NULL,
    p_ip_address     inet    DEFAULT NULL,
    p_user_agent     text    DEFAULT NULL,
    p_request_id     uuid    DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'inventarios', 'auditoria'
AS $$
DECLARE
    v_guardadas integer := 0;
    v_borradas  integer := 0;
    v_huerfano  text;
    v_malo      text;
BEGIN
    PERFORM inventarios.fn_contexto_auditoria('inventarios.caracteristicas_productos',
        p_usuario_id, p_usuario_login, p_usuario_nombre, p_ip_address, p_user_agent, p_request_id);

    IF NOT EXISTS (SELECT 1 FROM inventarios.productos WHERE id = p_producto_id) THEN
        RAISE EXCEPTION 'El producto no existe' USING ERRCODE = 'P0013';
    END IF;

    -- Lo que viene con valor, en una tabla de trabajo
    CREATE TEMP TABLE IF NOT EXISTS tmp_carac_prod (
        caracteristica_id bigint,
        nombre_id         bigint,
        nombre            varchar(100),
        valor             text,
        orden             integer
    ) ON COMMIT DROP;
    DELETE FROM tmp_carac_prod;

    INSERT INTO tmp_carac_prod (caracteristica_id, nombre_id, nombre, valor, orden)
    SELECT NULLIF(e->>'caracteristica_id', '')::bigint,
           NULLIF(e->>'nombre_id', '')::bigint,
           TRIM(COALESCE(e->>'nombre', '')),
           NULLIF(TRIM(COALESCE(e->>'valor', '')), ''),
           COALESCE(NULLIF(e->>'orden', '')::integer, 1)
      FROM jsonb_array_elements(COALESCE(p_items, '[]'::jsonb)) e
     WHERE NULLIF(TRIM(COALESCE(e->>'valor', '')), '') IS NOT NULL
       AND (NULLIF(e->>'caracteristica_id', '') IS NOT NULL
         OR NULLIF(e->>'nombre_id', '') IS NOT NULL
         OR length(TRIM(COALESCE(e->>'nombre', ''))) > 0);

    -- El nombre del diccionario: de la plantilla cuando viene de ella, y si no
    -- por el id que mandó la pantalla o por el texto (que es como se guardaban
    -- las sueltas antes).
    UPDATE tmp_carac_prod t
       SET nombre_id = k.nombre_id, nombre = k.nombre
      FROM inventarios.caracteristicas_categorias k
     WHERE k.id = t.caracteristica_id;

    UPDATE tmp_carac_prod t
       SET nombre_id = n.id, nombre = n.nombre
      FROM inventarios.caracteristicas_nombres n
     WHERE t.caracteristica_id IS NULL
       AND t.nombre_id IS NULL
       AND n.deleted_at IS NULL
       AND inventarios.fn_normalizar_nombre(n.nombre) = inventarios.fn_normalizar_nombre(t.nombre);

    UPDATE tmp_carac_prod t
       SET nombre = n.nombre
      FROM inventarios.caracteristicas_nombres n
     WHERE t.nombre_id = n.id
       AND t.nombre IS DISTINCT FROM n.nombre;

    SELECT string_agg(DISTINCT t.nombre, ', ') INTO v_huerfano
      FROM tmp_carac_prod t WHERE t.nombre_id IS NULL;

    IF v_huerfano IS NOT NULL THEN
        RAISE EXCEPTION 'No está en el diccionario de características: %. Créelo en Inventarios → Nombres de característica', v_huerfano
            USING ERRCODE = 'P0016';
    END IF;

    -- ---------------------------------------------------------------
    -- EL VALOR, CONTRA EL TIPO
    -- ---------------------------------------------------------------

    -- NUMERO: la coma a punto ANTES de comprobar, que «15,5» es un número
    -- escrito como se escribe aquí.
    UPDATE tmp_carac_prod t
       SET valor = replace(t.valor, ',', '.')
      FROM inventarios.caracteristicas_nombres n
     WHERE n.id = t.nombre_id AND n.tipo = 'NUMERO' AND t.valor LIKE '%,%';

    SELECT string_agg(format('«%s» tiene que ser un número y dice «%s»', t.nombre, t.valor), '; ')
      INTO v_malo
      FROM tmp_carac_prod t
      JOIN inventarios.caracteristicas_nombres n ON n.id = t.nombre_id
     WHERE n.tipo = 'NUMERO'
       AND t.valor !~ '^-?[0-9]+(\.[0-9]+)?$';

    IF v_malo IS NOT NULL THEN
        RAISE EXCEPTION '%', v_malo USING ERRCODE = 'P0015';
    END IF;

    -- SI_NO: se guarda siempre igual, se escriba como se escriba
    UPDATE tmp_carac_prod t
       SET valor = CASE WHEN inventarios.fn_normalizar_nombre(t.valor) IN ('si', 's', 'true', '1')
                        THEN 'Sí' ELSE 'No' END
      FROM inventarios.caracteristicas_nombres n
     WHERE n.id = t.nombre_id AND n.tipo = 'SI_NO'
       AND inventarios.fn_normalizar_nombre(t.valor) IN ('si', 's', 'true', '1', 'no', 'n', 'false', '0');

    SELECT string_agg(format('«%s» tiene que ser Sí o No, y dice «%s»', t.nombre, t.valor), '; ')
      INTO v_malo
      FROM tmp_carac_prod t
      JOIN inventarios.caracteristicas_nombres n ON n.id = t.nombre_id
     WHERE n.tipo = 'SI_NO' AND t.valor NOT IN ('Sí', 'No');

    IF v_malo IS NOT NULL THEN
        RAISE EXCEPTION '%', v_malo USING ERRCODE = 'P0015';
    END IF;

    -- LISTA: una de las opciones de ESA categoría. Las sueltas no tienen
    -- categoría detrás, así que no hay lista que exigirles.
    SELECT string_agg(format('«%s» tiene que ser una de: %s', t.nombre,
                             array_to_string(k.valores_lista, ', ')), '; ')
      INTO v_malo
      FROM tmp_carac_prod t
      JOIN inventarios.caracteristicas_categorias k ON k.id = t.caracteristica_id
      JOIN inventarios.caracteristicas_nombres n ON n.id = k.nombre_id
     WHERE n.tipo = 'LISTA'
       AND COALESCE(array_length(k.valores_lista, 1), 0) > 0
       AND NOT EXISTS (SELECT 1 FROM unnest(k.valores_lista) o
                        WHERE inventarios.fn_normalizar_nombre(o)
                            = inventarios.fn_normalizar_nombre(t.valor));

    IF v_malo IS NOT NULL THEN
        RAISE EXCEPTION '%', v_malo USING ERRCODE = 'P0015';
    END IF;

    -- Y se guarda la opción TAL COMO ESTÁ ESCRITA EN LA CATEGORÍA: si la
    -- lista dice «Gas» y llega «gas», se guarda «Gas». Si no, agrupar por el
    -- valor daría dos grupos para la misma opción.
    UPDATE tmp_carac_prod t
       SET valor = o.opcion
      FROM inventarios.caracteristicas_categorias k
      JOIN inventarios.caracteristicas_nombres n ON n.id = k.nombre_id
      CROSS JOIN LATERAL unnest(k.valores_lista) AS o(opcion)
     WHERE k.id = t.caracteristica_id
       AND n.tipo = 'LISTA'
       AND inventarios.fn_normalizar_nombre(o.opcion) = inventarios.fn_normalizar_nombre(t.valor)
       AND o.opcion IS DISTINCT FROM t.valor;

    -- ---------------------------------------------------------------

    -- Fuera lo que ya no está (vaciado o quitado de la lista)
    DELETE FROM inventarios.caracteristicas_productos v
     WHERE v.producto_id = p_producto_id
       AND NOT EXISTS (
           SELECT 1 FROM tmp_carac_prod t
            WHERE (t.caracteristica_id IS NOT NULL AND t.caracteristica_id = v.caracteristica_id)
               OR (t.caracteristica_id IS NULL AND v.caracteristica_id IS NULL
                   AND (t.nombre_id = v.nombre_id
                     OR (v.nombre_id IS NULL
                         AND UPPER(TRIM(t.nombre)) = UPPER(TRIM(v.nombre))))));
    GET DIAGNOSTICS v_borradas = ROW_COUNT;

    -- Las que vienen de la plantilla: una fila por característica
    INSERT INTO inventarios.caracteristicas_productos
                (producto_id, caracteristica_id, nombre_id, nombre, valor, orden)
    SELECT p_producto_id, t.caracteristica_id, t.nombre_id, t.nombre, t.valor, t.orden
      FROM tmp_carac_prod t
     WHERE t.caracteristica_id IS NOT NULL
        ON CONFLICT (producto_id, caracteristica_id) WHERE caracteristica_id IS NOT NULL
        DO UPDATE SET nombre_id = EXCLUDED.nombre_id,
                      nombre    = EXCLUDED.nombre,
                      valor     = EXCLUDED.valor,
                      orden     = EXCLUDED.orden;
    GET DIAGNOSTICS v_guardadas = ROW_COUNT;

    -- Las sueltas (sin plantilla detrás), por id del diccionario
    INSERT INTO inventarios.caracteristicas_productos
                (producto_id, caracteristica_id, nombre_id, nombre, valor, orden)
    SELECT p_producto_id, NULL, t.nombre_id, t.nombre, t.valor, t.orden
      FROM tmp_carac_prod t
     WHERE t.caracteristica_id IS NULL
        ON CONFLICT (producto_id, nombre_id)
             WHERE caracteristica_id IS NULL AND nombre_id IS NOT NULL
        DO UPDATE SET nombre = EXCLUDED.nombre,
                      valor  = EXCLUDED.valor,
                      orden  = EXCLUDED.orden;

    RETURN jsonb_build_object('success', true,
        'message', 'Características guardadas',
        'data', jsonb_build_object('guardadas', v_guardadas, 'borradas', v_borradas));
END;
$$;

COMMIT;
