-- ===========================================================================
-- AL CERRAR UNA GESTIÓN, EL SEGUIMIENTO PUEDE QUEDAR A CARGO DE OTRO
-- ===========================================================================
-- Fecha: 2026-10-09
-- Se aplica después de 2026-10-09_ventas_historial_buscador.sql.
--
-- fn_gestiones_cerrar ya creaba la gestión de seguimiento con el asunto del
-- catálogo (p_siguiente->>'asunto_id', y comprueba que pertenezca al tipo
-- nuevo), pero el RESPONSABLE lo heredaba a la fuerza de la gestión que se
-- estaba cerrando.
--
-- Eso deja a medias lo que ahora se puede hacer al registrar: elegir a quién
-- le toca. El caso es el de siempre —el vendedor cierra una llamada y el
-- seguimiento es una cobranza, que le toca al cobrador—, y obligaba a crear el
-- seguimiento y luego editarlo para cambiarle el responsable.
--
-- SIGUE HEREDÁNDOLO SI NO SE INDICA: el COALESCE deja el comportamiento de
-- antes cuando el jsonb no trae `usuario_id`, que es lo que mandan las
-- pantallas que no preguntan por él.
--
-- QUIÉN PUEDE SER RESPONSABLE lo valida el controlador con
-- ventas.fn_gestion_puede_asignar, la misma regla que al registrar: aquí sólo
-- se guarda lo que llega.
--
-- Idempotente.
-- ===========================================================================

DO $$
DECLARE
    v_def     text;
    v_cuantas int;

    c_viejo constant text := '            v_actual.usuario_id,';
    c_nuevo constant text :=
'            -- El responsable del seguimiento: el que se haya elegido o, si no
            -- se indicó, el de la gestión que se cierra
            COALESCE(NULLIF(p_siguiente->>''usuario_id'', '''')::bigint, v_actual.usuario_id),';
BEGIN
    SELECT pg_get_functiondef(p.oid) INTO v_def
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'ventas' AND p.proname = 'fn_gestiones_cerrar' AND p.prokind = 'f';

    IF v_def IS NULL THEN
        RAISE EXCEPTION 'no existe ventas.fn_gestiones_cerrar';
    END IF;

    IF position('p_siguiente->>''usuario_id''' IN v_def) > 0 THEN
        RAISE NOTICE 'fn_gestiones_cerrar ya acepta el responsable del seguimiento';
        RETURN;
    END IF;

    v_cuantas := (length(v_def) - length(replace(v_def, c_viejo, ''))) / length(c_viejo);
    IF v_cuantas <> 1 THEN
        RAISE EXCEPTION 'el ancla del responsable aparece % veces y esperaba 1', v_cuantas;
    END IF;

    EXECUTE replace(v_def, c_viejo, c_nuevo);
    RAISE NOTICE 'fn_gestiones_cerrar actualizada: el seguimiento acepta responsable';
END;
$$;


-- ---------------------------------------------------------------------------
-- COMPROBACIÓN
-- ---------------------------------------------------------------------------
-- Cerrar una pendiente dejando el seguimiento a otro, y deshacerlo:
--
--   BEGIN;
--     SELECT ventas.fn_gestiones_cerrar(
--              (SELECT id FROM ventas.gestiones WHERE estado='PENDIENTE' AND cliente_id=1055 LIMIT 1),
--              'VOLVER_A_LLAMAR', 'prueba', 5, now(),
--              jsonb_build_object('fecha', now() + interval '2 days', 'usuario_id', 39),
--              46, 'VCUENCA1', 'Vendedor', NULL, NULL, NULL) -> 'data';
--   ROLLBACK;
