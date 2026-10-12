-- ===========================================================================
-- QUÉ PAPELES PUEDE REPARTIR CADA PERFIL
-- ===========================================================================
-- Fecha: 2026-10-10
-- Se aplica después de 2026-10-10_ventas_asignacion_filtros_de_columna.sql.
--
-- Hasta ahora repartir clientes era todo o nada: o eras administrador y podías
-- repartir los cuatro papeles, o no entrabas. Eso deja fuera el caso normal:
-- que el jefe de cobranzas reparta cobradores y nadie más, o que postventa
-- reparta lo suyo sin poder tocar la cartera de ventas.
--
-- Ahora se elige por perfil y papel a papel, desde el mismo cuadro «Qué ve
-- dentro de un cliente» donde ya se deciden las gestiones, las notas, los
-- archivos, el WhatsApp y la pestaña de Asignación.
--
-- CUATRO DATOS Y NO UNA LISTA. En la pantalla es UN control de multiopción
-- —«puede repartir: vendedor, cobrador…»—, pero aquí abajo son cuatro filas
-- independientes:
--
--     REPARTIR_VENDEDOR    TODO | NINGUNO
--     REPARTIR_COBRADOR    TODO | NINGUNO
--     REPARTIR_ASISTENTE   TODO | NINGUNO
--     REPARTIR_POSTVENTA   TODO | NINGUNO
--
-- La alternativa era un solo dato REPARTIR con 'VENDEDOR,COBRADOR' dentro de
-- `alcance`. Se descartó: esa columna tiene un CHECK con la lista de alcances
-- y meterle una lista separada por comas obliga a levantar el CHECK —y a
-- partir cadenas cada vez que se pregunta—. Cuatro filas se consultan con un
-- igual y las valida la misma restricción que todo lo demás.
--
-- EL DÍA DE LA MIGRACIÓN NO CAMBIA NADA, igual que con ASIGNACION: la
-- convención «sin fila = TODO» aquí regalaría permiso de repartir a todos los
-- perfiles, cuando hoy sólo reparten los administradores. Por eso el paso 6
-- siembra NINGUNO en los perfiles que ya existen. Los administradores siguen
-- repartiendo los cuatro papeles sin configurar nada, porque fn_alcance les
-- devuelve TODO sin mirar la tabla.
--
-- Idempotente.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- 1. El vocabulario nuevo
-- ---------------------------------------------------------------------------
ALTER TABLE seguridad.visibilidad_datos DROP CONSTRAINT IF EXISTS ck_visibilidad_datos_dato;
ALTER TABLE seguridad.visibilidad_datos
    ADD CONSTRAINT ck_visibilidad_datos_dato
    CHECK (dato IN ('GESTION', 'NOTA', 'ARCHIVO', 'WHATSAPP', 'ASIGNACION',
                    'REPARTIR_VENDEDOR', 'REPARTIR_COBRADOR', 'REPARTIR_ASISTENTE', 'REPARTIR_POSTVENTA'));


-- ---------------------------------------------------------------------------
-- 2. Los nueve datos en el cuadro del perfil
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION seguridad.fn_visibilidad_datos_obtener(p_perfil_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
AS $function$
DECLARE
    v_data jsonb;
BEGIN
    SELECT jsonb_object_agg(d.dato, COALESCE(v.alcance, 'TODO'))
      INTO v_data
      FROM (VALUES ('GESTION'), ('NOTA'), ('ARCHIVO'), ('WHATSAPP'), ('ASIGNACION'),
                   ('REPARTIR_VENDEDOR'), ('REPARTIR_COBRADOR'),
                   ('REPARTIR_ASISTENTE'), ('REPARTIR_POSTVENTA')) AS d(dato)
      LEFT JOIN seguridad.visibilidad_datos v
             ON v.perfil_id = p_perfil_id AND v.dato = d.dato;

    RETURN jsonb_build_object('success', true,
                              'message', 'Visibilidad obtenida exitosamente',
                              'data', COALESCE(v_data, '{}'::jsonb));
EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object('success', false,
                                  'message', 'Error al obtener la visibilidad: ' || SQLERRM,
                                  'error_code', SQLSTATE);
END;
$function$;


-- ---------------------------------------------------------------------------
-- 3. Y los mismos nueve para el que está mirando
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION seguridad.fn_visibilidad_de_usuario(p_usuario_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
AS $function$
DECLARE
    v_data jsonb;
BEGIN
    SELECT jsonb_object_agg(d.dato, seguridad.fn_alcance(p_usuario_id, d.dato))
      INTO v_data
      FROM (VALUES ('GESTION'), ('NOTA'), ('ARCHIVO'), ('WHATSAPP'), ('ASIGNACION'),
                   ('REPARTIR_VENDEDOR'), ('REPARTIR_COBRADOR'),
                   ('REPARTIR_ASISTENTE'), ('REPARTIR_POSTVENTA')) AS d(dato);

    RETURN jsonb_build_object('success', true,
                              'message', 'Visibilidad obtenida exitosamente',
                              'data', COALESCE(v_data, '{}'::jsonb));
EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object('success', false,
                                  'message', 'Error al obtener la visibilidad: ' || SQLERRM,
                                  'error_code', SQLSTATE);
END;
$function$;


-- ---------------------------------------------------------------------------
-- 4. Que se puedan guardar
-- ---------------------------------------------------------------------------
-- La lista de datos válidos de fn_visibilidad_datos_guardar, por sustitución:
-- de la función sólo cambia esa línea.
DO $$
DECLARE
    v_def   text;
    v_veces int;

    c_viejo constant text := '        IF v_dato NOT IN (''GESTION'', ''NOTA'', ''ARCHIVO'', ''WHATSAPP'', ''ASIGNACION'') THEN';
    c_nuevo constant text := '        IF v_dato NOT IN (''GESTION'', ''NOTA'', ''ARCHIVO'', ''WHATSAPP'', ''ASIGNACION'','
                           || chr(10) ||
                             '                           ''REPARTIR_VENDEDOR'', ''REPARTIR_COBRADOR'','
                           || chr(10) ||
                             '                           ''REPARTIR_ASISTENTE'', ''REPARTIR_POSTVENTA'') THEN';
BEGIN
    SELECT pg_get_functiondef(p.oid) INTO v_def
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'seguridad' AND p.proname = 'fn_visibilidad_datos_guardar' AND p.prokind = 'f';

    IF v_def IS NULL THEN
        RAISE EXCEPTION 'no existe seguridad.fn_visibilidad_datos_guardar';
    END IF;

    IF position('''REPARTIR_VENDEDOR''' IN v_def) > 0 THEN
        RAISE NOTICE 'fn_visibilidad_datos_guardar ya acepta los papeles a repartir';
        RETURN;
    END IF;

    v_veces := (length(v_def) - length(replace(v_def, c_viejo, ''))) / length(c_viejo);
    IF v_veces <> 1 THEN
        RAISE EXCEPTION 'la lista de datos aparece % veces y esperaba 1', v_veces;
    END IF;

    EXECUTE replace(v_def, c_viejo, c_nuevo);
    RAISE NOTICE 'fn_visibilidad_datos_guardar actualizada';
END;
$$;


-- ---------------------------------------------------------------------------
-- 5. Las dos preguntas que hará el servidor
-- ---------------------------------------------------------------------------

-- ¿Puede esta persona repartir ESTE papel?
CREATE OR REPLACE FUNCTION seguridad.fn_puede_repartir(p_usuario_id bigint, p_rol varchar)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'seguridad', 'ventas'
AS $function$
    SELECT CASE
        WHEN p_usuario_id IS NULL THEN false
        WHEN UPPER(COALESCE(p_rol, '')) NOT IN ('VENDEDOR', 'COBRADOR', 'ASISTENTE', 'POSTVENTA') THEN false
        -- fn_alcance ya resuelve el atajo del administrador (TODO sin mirar
        -- la tabla) y el «sin fila = TODO» del resto
        ELSE seguridad.fn_alcance(p_usuario_id, 'REPARTIR_' || UPPER(p_rol)) <> 'NINGUNO'
    END;
$function$;

COMMENT ON FUNCTION seguridad.fn_puede_repartir(bigint, varchar)
    IS 'Si ese usuario puede repartir clientes en ese papel, según el cuadro de su perfil';

-- ¿Cuáles puede repartir? Para que la pantalla ofrezca sólo esos, y para
-- saber si tiene algo que hacer ahí.
CREATE OR REPLACE FUNCTION seguridad.fn_papeles_que_reparte(p_usuario_id bigint)
RETURNS varchar[]
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'seguridad', 'ventas'
AS $function$
    SELECT COALESCE(array_agg(r.rol::varchar ORDER BY r.orden), '{}'::varchar[])
      FROM (VALUES ('VENDEDOR', 1), ('COBRADOR', 2), ('ASISTENTE', 3), ('POSTVENTA', 4)) AS r(rol, orden)
     WHERE seguridad.fn_puede_repartir(p_usuario_id, r.rol);
$function$;

COMMENT ON FUNCTION seguridad.fn_papeles_que_reparte(bigint)
    IS 'Los papeles que ese usuario puede repartir; vacío = no tiene nada que hacer en la pantalla de reparto';


-- ---------------------------------------------------------------------------
-- 6. Que el día de la migración no cambie nada
-- ---------------------------------------------------------------------------
-- Hoy reparten sólo los administradores. Sin esto, «sin fila = TODO» daría
-- permiso de repartir a todos los perfiles de golpe. Se siembra NINGUNO en
-- los que YA existen; uno creado después nace en TODO, que es la convención
-- del resto del cuadro y lo que el formulario deja marcado.
--
-- No pisa lo ya decidido —el NOT EXISTS—, así que se puede volver a correr.
-- created_by no se pone: el trigger trigger_visibilidad_datos_set_users lo
-- rellena con el usuario de la conexión.
INSERT INTO seguridad.visibilidad_datos (perfil_id, dato, alcance)
SELECT p.id, d.dato, 'NINGUNO'
  FROM seguridad.perfiles p
 CROSS JOIN (VALUES ('REPARTIR_VENDEDOR'), ('REPARTIR_COBRADOR'),
                    ('REPARTIR_ASISTENTE'), ('REPARTIR_POSTVENTA')) AS d(dato)
 WHERE NOT EXISTS (
         SELECT 1 FROM seguridad.visibilidad_datos v
          WHERE v.perfil_id = p.id AND v.dato = d.dato);


-- ---------------------------------------------------------------------------
-- COMPROBACIÓN
-- ---------------------------------------------------------------------------
-- Quién puede repartir qué después de aplicar esto: sólo los administradores
SELECT u.login_user,
       COALESCE(g.es_administrador, false) AS es_admin,
       p.nombre AS perfil,
       seguridad.fn_papeles_que_reparte(u.id) AS puede_repartir
  FROM seguridad.users u
  LEFT JOIN seguridad.grupos g ON g.id = u.grupo_id
  LEFT JOIN seguridad.perfiles p ON p.id = u.perfil_id
 WHERE u.deleted_at IS NULL
   AND u.login_user IN ('LAGILA', 'PASTUDILLO', 'VCUENCA1')
 ORDER BY 2 DESC, 1;

-- Y el cuadro completo de un perfil, que es lo que verá la pantalla
SELECT seguridad.fn_visibilidad_datos_obtener(
           (SELECT id FROM seguridad.perfiles WHERE nombre = 'VENDEDOR')) -> 'data' AS cuadro_vendedor;
