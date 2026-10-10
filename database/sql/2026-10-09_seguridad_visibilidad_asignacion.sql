-- ===========================================================================
-- LA PESTAÑA «ASIGNACIÓN», AL CUADRO DE VISIBILIDAD DEL PERFIL
-- ===========================================================================
-- Fecha: 2026-10-09
-- Se aplica después de 2026-10-09_ventas_cerrar_seguimiento_responsable.sql.
--
-- La pestaña de Asignación (quién ha atendido al cliente y desde cuándo) se
-- enseñaba sólo a los administradores, y eso estaba escrito en el código de la
-- pantalla. Ahora es un dato más del cuadro «Qué ve dentro de un cliente» del
-- perfil, al lado de Gestiones, Notas, Archivos y WhatsApp: lo decide el
-- administrador por perfil y sin tocar código.
--
-- DOS AÑADIDOS AL VOCABULARIO:
--
--   dato    ASIGNACION   el historial de responsables del cliente
--   alcance NINGUNO      no ve nada de ese dato
--
-- NINGUNO hacía falta. Los cuatro alcances de antes (PROPIO, MI_PERFIL,
-- A_CARGO, TODO) dicen DE QUIÉN se ven las filas, y para la asignación la
-- pregunta no es de quién: es si se ve la pestaña o no. Con NINGUNO eso se
-- dice en el mismo vocabulario —y de paso se puede decir «este perfil no ve
-- ninguna nota», que antes no se podía—.
--
-- Para ASIGNACION la pantalla ofrece sólo TODO y NINGUNO, que son las dos
-- respuestas que tienen sentido. Si alguien pusiera A_CARGO a mano, se trata
-- como «la ve»: lo que se compara es «<> NINGUNO».
--
-- SE CIERRA TAMBIÉN LA PUERTA DE ATRÁS. La pestaña estaba escondida, pero
-- `ventas/gestion/asignaciones/{cliente}` no comprobaba nada: con el token de
-- cualquier usuario devolvía el historial de responsables. El controlador pasa
-- a mirar el alcance, porque esconder una pestaña no cierra una ruta.
--
-- EL DÍA DE LA MIGRACIÓN NO CAMBIA NADA. La convención del resto del cuadro
-- es «sin fila = TODO», y se puso para que nadie pierda un acceso por
-- descuido. Aquí haría lo contrario: regalarlo. La pestaña hoy la ven sólo los
-- administradores, así que dejarla sin fila la abriría de golpe a los 50
-- usuarios que no lo son, con el historial de reasignaciones de todos los
-- clientes dentro. Por eso el paso 6 siembra NINGUNO en los perfiles que ya
-- existen: se queda como está y es el administrador quien abre los que quiera,
-- perfil por perfil, desde la pantalla. Los administradores la siguen viendo
-- igual, porque fn_alcance les devuelve TODO sin mirar la tabla.
--
-- Idempotente.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- 1. El vocabulario nuevo
-- ---------------------------------------------------------------------------
ALTER TABLE seguridad.visibilidad_datos DROP CONSTRAINT IF EXISTS ck_visibilidad_datos_dato;
ALTER TABLE seguridad.visibilidad_datos
    ADD CONSTRAINT ck_visibilidad_datos_dato
    CHECK (dato IN ('GESTION', 'NOTA', 'ARCHIVO', 'WHATSAPP', 'ASIGNACION'));

ALTER TABLE seguridad.visibilidad_datos DROP CONSTRAINT IF EXISTS ck_visibilidad_datos_alc;
ALTER TABLE seguridad.visibilidad_datos
    ADD CONSTRAINT ck_visibilidad_datos_alc
    CHECK (alcance IN ('NINGUNO', 'PROPIO', 'MI_PERFIL', 'A_CARGO', 'TODO'));

COMMENT ON TABLE seguridad.visibilidad_datos
    IS 'Qué alcance tiene cada perfil sobre cada tipo de dato dentro de un cliente. Sin fila: TODO';


-- ---------------------------------------------------------------------------
-- 2. NINGUNO en el filtro de usuarios
-- ---------------------------------------------------------------------------
-- Devuelve el array vacío, que es «de nadie»: las consultas que filtran con
-- `x.usuario_id = ANY(v_usuarios)` no sacan ninguna fila. Va ANTES que los
-- demás alcances para no depender del orden de los IF.
CREATE OR REPLACE FUNCTION seguridad.fn_usuarios_visibles(p_usuario_id bigint, p_dato varchar)
RETURNS bigint[]
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
AS $function$
DECLARE
    v_alcance varchar;
    v_perfil  bigint;
BEGIN
    v_alcance := seguridad.fn_alcance(p_usuario_id, p_dato);

    IF v_alcance = 'TODO' THEN
        RETURN NULL;              -- sin filtro
    END IF;

    IF v_alcance = 'NINGUNO' THEN
        RETURN '{}'::bigint[];    -- de nadie: ni lo propio
    END IF;

    IF p_usuario_id IS NULL THEN
        RETURN '{}'::bigint[];
    END IF;

    IF v_alcance = 'PROPIO' THEN
        RETURN ARRAY[p_usuario_id];
    END IF;

    IF v_alcance = 'A_CARGO' THEN
        RETURN ventas.fn_usuarios_a_cargo(p_usuario_id);
    END IF;

    -- MI_PERFIL: los de su mismo perfil, y él (por si se quedó sin perfil)
    SELECT u.perfil_id INTO v_perfil FROM seguridad.users u WHERE u.id = p_usuario_id;

    RETURN ARRAY(
        SELECT u.id FROM seguridad.users u
         WHERE u.deleted_at IS NULL
           AND (u.id = p_usuario_id OR (v_perfil IS NOT NULL AND u.perfil_id = v_perfil))
    );
END;
$function$;

COMMENT ON FUNCTION seguridad.fn_usuarios_visibles(bigint, varchar)
    IS 'De qué usuarios puede ver las filas de ese dato. NULL = sin filtro (TODO); {} = de nadie (NINGUNO)';


-- ---------------------------------------------------------------------------
-- 3. Los cinco datos en el cuadro del perfil
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
      FROM (VALUES ('GESTION'), ('NOTA'), ('ARCHIVO'), ('WHATSAPP'), ('ASIGNACION')) AS d(dato)
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
-- 4. Y que se puedan guardar
-- ---------------------------------------------------------------------------
-- Las dos listas de fn_visibilidad_datos_guardar, por sustitución: de la
-- función sólo cambian esas dos líneas.
DO $$
DECLARE
    v_def     text;
    v_nueva   text;
    v_cuantas int;

    c_dato_viejo constant text := '        IF v_dato NOT IN (''GESTION'', ''NOTA'', ''ARCHIVO'', ''WHATSAPP'') THEN';
    c_dato_nuevo constant text := '        IF v_dato NOT IN (''GESTION'', ''NOTA'', ''ARCHIVO'', ''WHATSAPP'', ''ASIGNACION'') THEN';

    c_alc_viejo constant text := '        IF v_alcance NOT IN (''PROPIO'', ''MI_PERFIL'', ''A_CARGO'', ''TODO'') THEN';
    c_alc_nuevo constant text := '        IF v_alcance NOT IN (''NINGUNO'', ''PROPIO'', ''MI_PERFIL'', ''A_CARGO'', ''TODO'') THEN';
BEGIN
    SELECT pg_get_functiondef(p.oid) INTO v_def
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'seguridad' AND p.proname = 'fn_visibilidad_datos_guardar' AND p.prokind = 'f';

    IF v_def IS NULL THEN
        RAISE EXCEPTION 'no existe seguridad.fn_visibilidad_datos_guardar';
    END IF;

    IF position('''ASIGNACION''' IN v_def) > 0 THEN
        RAISE NOTICE 'fn_visibilidad_datos_guardar ya acepta ASIGNACION';
        RETURN;
    END IF;

    v_cuantas := (length(v_def) - length(replace(v_def, c_dato_viejo, ''))) / length(c_dato_viejo);
    IF v_cuantas <> 1 THEN RAISE EXCEPTION 'la lista de datos aparece % veces y esperaba 1', v_cuantas; END IF;

    v_cuantas := (length(v_def) - length(replace(v_def, c_alc_viejo, ''))) / length(c_alc_viejo);
    IF v_cuantas <> 1 THEN RAISE EXCEPTION 'la lista de alcances aparece % veces y esperaba 1', v_cuantas; END IF;

    v_nueva := replace(v_def,   c_dato_viejo, c_dato_nuevo);
    v_nueva := replace(v_nueva, c_alc_viejo,  c_alc_nuevo);

    EXECUTE v_nueva;
    RAISE NOTICE 'fn_visibilidad_datos_guardar actualizada';
END;
$$;


-- ---------------------------------------------------------------------------
-- 5. Qué alcances tiene el que está mirando
-- ---------------------------------------------------------------------------
-- La pantalla necesita saber si enseña la pestaña de Asignación, y en adelante
-- cualquier otra cosa que dependa de un alcance. Se devuelven los cinco de una
-- vez para no acabar con una petición por pregunta.
--
-- Pasa por fn_alcance, así que un administrador recibe TODO en los cinco sin
-- mirar la tabla, igual que en el resto del modelo.
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
      FROM (VALUES ('GESTION'), ('NOTA'), ('ARCHIVO'), ('WHATSAPP'), ('ASIGNACION')) AS d(dato);

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

COMMENT ON FUNCTION seguridad.fn_visibilidad_de_usuario(bigint)
    IS 'Los cinco alcances de ese usuario, para que la pantalla sepa qué enseñar';


-- ---------------------------------------------------------------------------
-- 6. Que el día de la migración no cambie nada
-- ---------------------------------------------------------------------------
-- Se siembra NINGUNO en los perfiles que YA existen, que es lo que hoy ven:
-- nada, porque la pestaña era de administradores. A partir de aquí se abre
-- desde la pantalla del perfil, uno por uno.
--
-- Sólo los que ya existen: un perfil creado después nace sin fila, o sea en
-- TODO, que es la convención del resto del cuadro y lo que el formulario del
-- perfil deja marcado por defecto.
--
-- No pisa lo que ya esté decidido —el NOT EXISTS—, así que se puede volver a
-- correr y se puede aplicar después de haber abierto algún perfil a mano.
--
-- created_by no se pone aquí: el trigger trigger_visibilidad_datos_set_users lo
-- rellena con el usuario de la conexión, y en una migración por psql eso es
-- «postgres». Dar un valor sería escribir algo que el trigger va a pisar.
INSERT INTO seguridad.visibilidad_datos (perfil_id, dato, alcance)
SELECT p.id, 'ASIGNACION', 'NINGUNO'
  FROM seguridad.perfiles p
 WHERE NOT EXISTS (
         SELECT 1 FROM seguridad.visibilidad_datos v
          WHERE v.perfil_id = p.id AND v.dato = 'ASIGNACION');


-- ---------------------------------------------------------------------------
-- COMPROBACIÓN
-- ---------------------------------------------------------------------------
-- Quién ve la pestaña después de aplicar esto: sólo los administradores.
SELECT COALESCE(g.es_administrador, false) AS es_administrador,
       seguridad.fn_alcance(u.id, 'ASIGNACION') AS alcance,
       count(*) AS usuarios
  FROM seguridad.users u
  LEFT JOIN seguridad.grupos g ON g.id = u.grupo_id
 WHERE u.deleted_at IS NULL
 GROUP BY 1, 2
 ORDER BY 1 DESC;

-- Y el cuadro de cada perfil, que es lo que se verá en la pantalla.
SELECT p.id, p.nombre,
       seguridad.fn_visibilidad_datos_obtener(p.id) -> 'data' AS cuadro
  FROM seguridad.perfiles p
 ORDER BY p.id;
