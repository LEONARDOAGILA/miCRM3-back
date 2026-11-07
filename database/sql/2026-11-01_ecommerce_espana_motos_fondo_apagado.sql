-- ============================================================================
-- ESPAÑA MOTOS: el fondo nace APAGADO
-- ----------------------------------------------------------------------------
-- La fila nacía con `fondo_visible = true` y sin imagen, y
-- `fn_espana_motos_modificar` se niega a guardar eso («Para enseñar el fondo
-- hace falta su imagen»), con razón: encendido y sin imagen quedaría una
-- franja en blanco con el título flotando.
--
-- Pero juntas, las dos cosas dejaban la pantalla en un estado del que no se
-- puede salir guardando: se abre, se toca cualquier otra palanca, se guarda y
-- el servidor se queja de una imagen que nadie ha pedido. Y la queja es de un
-- campo que no se estaba tocando.
--
-- La tienda ya sólo enseña el fondo si hay imagen, así que el valor de verdad
-- de este campo mientras no hay imagen es «apagado». Que lo diga también la
-- base.
--
-- Se puede volver a ejecutar sin romper nada.
-- ============================================================================
\set ON_ERROR_STOP on
\pset tuples_only on
\pset format unaligned
BEGIN;

ALTER TABLE ecommerce.espana_motos
      ALTER COLUMN fondo_visible SET DEFAULT false;

-- Las que ya están encendidas sin imagen: no se puede guardar nada mientras
-- sigan así
UPDATE ecommerce.espana_motos
   SET fondo_visible = false
 WHERE fondo_visible
   AND fondo_imagen IS NULL;

-- ---------------------------------------------------------------------------
-- Comprobación. Las cuentas se calculan siempre, para que un NULL no deje
-- pasar la comprobación en verde.
-- ---------------------------------------------------------------------------
DO $c$
DECLARE
    v_defecto text;
    v_rotas   integer;
BEGIN
    SELECT column_default INTO v_defecto
      FROM information_schema.columns
     WHERE table_schema = 'ecommerce'
       AND table_name   = 'espana_motos'
       AND column_name  = 'fondo_visible';

    IF v_defecto IS NULL OR v_defecto NOT LIKE 'false%' THEN
        RAISE EXCEPTION 'El valor por defecto del fondo no quedó apagado (es %)',
              COALESCE(v_defecto, 'nulo');
    END IF;

    SELECT count(*) INTO v_rotas
      FROM ecommerce.espana_motos
     WHERE fondo_visible AND fondo_imagen IS NULL;

    IF v_rotas IS NULL OR v_rotas > 0 THEN
        RAISE EXCEPTION 'Quedan % filas con el fondo encendido y sin imagen', v_rotas;
    END IF;

    RAISE NOTICE 'Comprobado: el fondo nace apagado y no queda ninguna fila sin imagen encendida.';
END
$c$;

COMMIT;
