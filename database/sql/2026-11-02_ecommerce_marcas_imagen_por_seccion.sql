-- ============================================================================
-- ECOMMERCE · CADA SECCIÓN DE MARCAS CON SU IMAGEN
-- ============================================================================
-- Fecha: 2026-11-02
--
-- Las dos secciones de marcas dejan de pelearse por la misma imagen:
--
--     «Nuestras marcas»      el LOGO del catálogo (el del CRUD de marcas)
--     «Marcas en promoción»  la imagen PROGRAMADA de la marca
--
-- ANTES «Nuestras marcas» usaba la programada y, si no había, el logo. Eso
-- tenía sentido cuando era la única sección de marcas: la programada servía
-- para tapar el logo durante una campaña. Ahora que la campaña tiene su propia
-- sección, cada una usa lo suyo y no hay que elegir.
--
-- Y SE NOTA EN CUÁNTAS SALEN: de las 15 marcas visibles, 5 tienen logo y 2
-- tienen imagen programada. Así que la tira de logos pasa a enseñar 5, y los
-- carteles de promoción saldrán con foto sólo en las que tengan una
-- programada; las demás salen con su color y su nombre, como las categorías
-- sin foto. No es una pérdida: es que cada hueco pide una imagen distinta y
-- ahora se ve cuál falta.
--
-- `fn_marcas_promocion_publicas` YA ESTABA BIEN: sólo devuelve la programada.
-- Aquí se toca únicamente la otra.
--
-- Idempotente.
-- ============================================================================
\set ON_ERROR_STOP on

BEGIN;

-- ----------------------------------------------------------------------------
-- 1. «NUESTRAS MARCAS»: EL LOGO DEL CATÁLOGO
-- ----------------------------------------------------------------------------
-- Se deja de buscar la imagen programada. Al no viajar la llave `imagen`, el
-- controlador se queda con el logo sin saber nada de esto: ya hacía
-- `imagen ?? logo` y ahora sólo le llega lo segundo.
CREATE OR REPLACE FUNCTION ecommerce.fn_marcas_publicas()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
AS $function$
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'id', e.id,
               'nombre', e.nombre,
               -- El del catálogo de Inventarios, que vive en img/marcas. Es el
               -- que se sube en el CRUD de marcas y el que se quiere ver aquí:
               -- esta sección es una tira de logos.
               'logo', e.logo,
               'enlace', '/shop?marca=' || e.id)
           ORDER BY e.orden_web NULLS LAST, e.nombre), '[]'::jsonb)
      FROM ecommerce.fn_marcas_web_estado() e
     WHERE e.estado = 'visible';
$function$;

-- ----------------------------------------------------------------------------
-- 2. COMPROBACIÓN
-- ----------------------------------------------------------------------------
DO $comprobar$
DECLARE
    v_m         bigint;
    v_nuestras  jsonb;
    v_promo     jsonb;
    v_una       jsonb;
    v_conLogo   int;
    v_conProg   int;
BEGIN
    SELECT count(*) FILTER (WHERE nullif(btrim(COALESCE(e.logo, '')), '') IS NOT NULL),
           count(*) FILTER (WHERE EXISTS (SELECT 1 FROM ecommerce.marcas_imagenes i
                                           WHERE i.marca_id = e.id AND i.deleted_at IS NULL
                                             AND i.activo AND ecommerce.fn_vigente(i.desde, i.hasta)))
      INTO v_conLogo, v_conProg
      FROM ecommerce.fn_marcas_web_estado() e WHERE e.estado = 'visible';

    v_nuestras := ecommerce.fn_marcas_publicas();

    -- «Nuestras marcas» ya no manda la programada
    SELECT x INTO v_una FROM jsonb_array_elements(v_nuestras) x LIMIT 1;
    IF v_una IS NOT NULL AND (v_una ? 'imagen') THEN
        RAISE EXCEPTION '«Nuestras marcas» sigue mandando la programada: %', v_una;
    END IF;
    IF v_una IS NOT NULL AND NOT (v_una ? 'logo') THEN
        RAISE EXCEPTION '«Nuestras marcas» tiene que mandar el logo: %', v_una;
    END IF;

    -- Y la de promoción sigue mandando la programada y NO el logo
    SELECT e.id INTO v_m FROM ecommerce.fn_marcas_web_estado() e
     WHERE e.estado = 'visible' ORDER BY e.id LIMIT 1;

    BEGIN
        PERFORM ecommerce.fn_marcas_web_guardar(v_m, false, NULL,
                NULL, NULL, NULL, NULL, NULL, NULL, true);
        v_promo := ecommerce.fn_marcas_promocion_publicas();
        RAISE EXCEPTION 'deshacer' USING ERRCODE = 'P0099';
    EXCEPTION WHEN SQLSTATE 'P0099' THEN
        NULL;
    END;

    SELECT x INTO v_una FROM jsonb_array_elements(v_promo) x LIMIT 1;
    IF v_una IS NULL THEN
        RAISE EXCEPTION 'No se pudo comprobar la de promoción: vino vacía';
    END IF;
    IF NOT (v_una ? 'imagen') THEN
        RAISE EXCEPTION 'La de promoción tiene que mandar la programada: %', v_una;
    END IF;
    IF v_una ? 'logo' THEN
        RAISE EXCEPTION 'La de promoción no puede mandar el logo: %', v_una;
    END IF;

    RAISE NOTICE 'Comprobado: «Nuestras marcas» manda el logo y nada más, «Marcas en promoción» manda la programada y nada más. De % marcas visibles, % tienen logo y % tienen imagen programada.',
          jsonb_array_length(v_nuestras), v_conLogo, v_conProg;
END
$comprobar$;

COMMIT;
