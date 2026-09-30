-- ===========================================================================
-- BOLETINES: cada imagen decide cuánto se queda en pantalla
--
-- Antes el carrusel pasaba de imagen cada 6 segundos fijos. Ahora el tiempo
-- es un campo de cada imagen, igual que su título o su pie, y las que ya
-- estaban se quedan con los 6 segundos de siempre.
--
--   psql -h 192.168.2.173 -U postgres -d crm3 -f 2026-09-21_core_boletines_segundos.sql
-- ===========================================================================

ALTER TABLE core.boletines_imagenes
    ADD COLUMN IF NOT EXISTS segundos smallint NOT NULL DEFAULT 6;

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'boletines_imagenes_segundos_check') THEN
        ALTER TABLE core.boletines_imagenes
            ADD CONSTRAINT boletines_imagenes_segundos_check CHECK (segundos BETWEEN 1 AND 120);
    END IF;
END $$;

COMMENT ON COLUMN core.boletines_imagenes.segundos IS 'Segundos que la imagen se queda en pantalla dentro del carrusel';

-- ---------------------------------------------------------------------------
-- Las dos funciones que tocan ese campo
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION core.fn_boletines_json(p_id bigint)
RETURNS jsonb
LANGUAGE sql
STABLE
AS $function$
    SELECT jsonb_build_object(
        'id',            b.id,
        'titulo',        b.titulo,
        'descripcion',   b.descripcion,
        'desde',         to_char(b.desde, 'YYYY-MM-DD'),
        'hasta',         to_char(b.hasta, 'YYYY-MM-DD'),
        'prioridad',     b.prioridad,
        'obligatorio',   b.obligatorio,
        'activo',        b.activo,
        'vigente',       (b.activo AND CURRENT_DATE BETWEEN b.desde AND b.hasta),
        'estado',        CASE WHEN NOT b.activo               THEN 'INACTIVO'
                              WHEN CURRENT_DATE < b.desde     THEN 'PROGRAMADO'
                              WHEN CURRENT_DATE > b.hasta     THEN 'CADUCADO'
                              ELSE 'VIGENTE' END,
        'en_papelera',   (b.deleted_at IS NOT NULL),
        'imagenes',      COALESCE((
                            SELECT jsonb_agg(jsonb_build_object(
                                     'id', i.id, 'archivo', i.archivo, 'titulo', i.titulo,
                                     'descripcion', i.descripcion, 'orden', i.orden,
                                     'segundos', i.segundos
                                   ) ORDER BY i.orden, i.id)
                              FROM core.boletines_imagenes i WHERE i.boletin_id = b.id), '[]'::jsonb),
        'usuarios',      COALESCE((
                            SELECT jsonb_agg(jsonb_build_object(
                                     'user_id', u.id, 'login_user', u.login_user,
                                     'name', u.name, 'surname', u.surname, 'isactive', u.isactive
                                   ) ORDER BY u.login_user)
                              FROM core.boletines_usuarios bu
                              JOIN seguridad.users u ON u.id = bu.user_id AND u.deleted_at IS NULL
                             WHERE bu.boletin_id = b.id), '[]'::jsonb),
        'grupos',        COALESCE((
                            SELECT jsonb_agg(jsonb_build_object(
                                     'grupo_id', g.id, 'nombre', g.nombre,
                                     'incluir_subgrupos', bg.incluir_subgrupos
                                   ) ORDER BY g.nombre)
                              FROM core.boletines_grupos bg
                              JOIN seguridad.grupos g ON g.id = bg.grupo_id
                             WHERE bg.boletin_id = b.id), '[]'::jsonb),
        'num_imagenes',  (SELECT COUNT(*) FROM core.boletines_imagenes i WHERE i.boletin_id = b.id),
        'num_usuarios',  (SELECT COUNT(*) FROM core.boletines_usuarios bu WHERE bu.boletin_id = b.id),
        'num_grupos',    (SELECT COUNT(*) FROM core.boletines_grupos bg WHERE bg.boletin_id = b.id),
        'num_vistos',    (SELECT COUNT(*) FROM core.boletines_vistos v WHERE v.boletin_id = b.id),
        'created_by',    b.created_by,
        'updated_by',    b.updated_by,
        'created_at',    to_char(b.created_at, 'YYYY-MM-DD HH24:MI:SS'),
        'updated_at',    to_char(b.updated_at, 'YYYY-MM-DD HH24:MI:SS')
    )
    FROM core.boletines b
    WHERE b.id = p_id;
$function$;

CREATE OR REPLACE FUNCTION core.fn_boletines_guardar_detalle(p_id bigint, p_datos jsonb)
RETURNS void
LANGUAGE plpgsql
AS $function$
DECLARE
    v_item jsonb;
    v_i    integer := 0;
BEGIN
    -- Imágenes: se reemplazan por las que manda la pantalla, en su orden
    IF p_datos ? 'imagenes' THEN
        DELETE FROM core.boletines_imagenes
         WHERE boletin_id = p_id
           AND (p_datos->'imagenes' = '[]'::jsonb
                OR id NOT IN (SELECT (x->>'id')::bigint
                                FROM jsonb_array_elements(p_datos->'imagenes') x
                               WHERE x->>'id' IS NOT NULL));

        FOR v_item IN SELECT * FROM jsonb_array_elements(p_datos->'imagenes') LOOP
            v_i := v_i + 1;
            IF v_item->>'id' IS NOT NULL THEN
                UPDATE core.boletines_imagenes
                   SET titulo      = NULLIF(TRIM(COALESCE(v_item->>'titulo', '')), ''),
                       descripcion = NULLIF(TRIM(COALESCE(v_item->>'descripcion', '')), ''),
                       orden       = v_i,
                       segundos    = GREATEST(1, LEAST(120, COALESCE(NULLIF(v_item->>'segundos', '')::smallint, segundos)))
                 WHERE id = (v_item->>'id')::bigint AND boletin_id = p_id;
            ELSE
                IF NULLIF(TRIM(COALESCE(v_item->>'archivo', '')), '') IS NULL THEN
                    RAISE EXCEPTION 'Cada imagen necesita su fichero' USING ERRCODE = 'P0001';
                END IF;
                INSERT INTO core.boletines_imagenes (boletin_id, archivo, titulo, descripcion, orden, segundos)
                VALUES (p_id,
                        v_item->>'archivo',
                        NULLIF(TRIM(COALESCE(v_item->>'titulo', '')), ''),
                        NULLIF(TRIM(COALESCE(v_item->>'descripcion', '')), ''),
                        v_i,
                        GREATEST(1, LEAST(120, COALESCE(NULLIF(v_item->>'segundos', '')::smallint, 6))));
            END IF;
        END LOOP;
    END IF;

    -- Destinatarios uno a uno
    IF p_datos ? 'usuarios' THEN
        DELETE FROM core.boletines_usuarios
         WHERE boletin_id = p_id
           AND (p_datos->'usuarios' = '[]'::jsonb
                OR user_id NOT IN (SELECT (x)::bigint FROM jsonb_array_elements_text(p_datos->'usuarios') x));

        INSERT INTO core.boletines_usuarios (boletin_id, user_id)
        SELECT p_id, (x)::bigint
          FROM jsonb_array_elements_text(p_datos->'usuarios') x
         WHERE EXISTS (SELECT 1 FROM seguridad.users u WHERE u.id = (x)::bigint AND u.deleted_at IS NULL)
        ON CONFLICT (boletin_id, user_id) DO NOTHING;
    END IF;

    -- Destinatarios por grupo
    IF p_datos ? 'grupos' THEN
        DELETE FROM core.boletines_grupos
         WHERE boletin_id = p_id
           AND (p_datos->'grupos' = '[]'::jsonb
                OR grupo_id NOT IN (SELECT (x->>'grupo_id')::bigint
                                      FROM jsonb_array_elements(p_datos->'grupos') x));

        FOR v_item IN SELECT * FROM jsonb_array_elements(p_datos->'grupos') LOOP
            IF NOT EXISTS (SELECT 1 FROM seguridad.grupos g WHERE g.id = (v_item->>'grupo_id')::bigint) THEN
                CONTINUE;
            END IF;
            INSERT INTO core.boletines_grupos (boletin_id, grupo_id, incluir_subgrupos)
            VALUES (p_id, (v_item->>'grupo_id')::bigint, COALESCE((v_item->>'incluir_subgrupos')::boolean, true))
            ON CONFLICT (boletin_id, grupo_id)
            DO UPDATE SET incluir_subgrupos = EXCLUDED.incluir_subgrupos;
        END LOOP;
    END IF;
END;
$function$;
