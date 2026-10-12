-- ===========================================================================
-- QUIÉN ESCRIBIÓ CADA NOTA Y QUIÉN SUBIÓ CADA ARCHIVO (usuario_id)
-- ===========================================================================
-- Fecha: 2026-10-08
-- Se aplica después de 2026-10-07_ventas_asunto_importacion_whatsapp.sql.
--
-- Las gestiones ya saben de quién son: tienen usuario_id. Las notas y los
-- archivos no: sólo guardan created_by, que es el LOGIN en texto. Con un texto
-- no se puede preguntar «¿esta nota es de alguien por debajo de mi grupo?»,
-- que es justo lo que hará falta para que un vendedor no vea lo del cobrador.
--
-- Por eso esto va primero: sin el id, el filtro por jerarquía no se puede ni
-- escribir.
--
-- NO SE QUITA created_by. Sigue siendo lo que se enseña en la tarjeta («LAGILA
-- · 06/10/2026») y lo que queda si algún día se borra el usuario. El id es para
-- decidir; el texto, para leer.
--
-- EL RELLENO ES POR LOGIN y se puede hacer con confianza: comprobado antes de
-- escribir esto, las 6 notas y los 80 archivos mapean a un usuario y no hay dos
-- usuarios con el mismo login. Lo que no mapee se queda en NULL, que el filtro
-- tratará como «de nadie» —lo verán sólo los administradores—, que es lo
-- prudente para una fila de la que no se sabe quién la hizo.
--
-- Idempotente.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- 1. La columna
-- ---------------------------------------------------------------------------
ALTER TABLE ventas.notas_clientes
    ADD COLUMN IF NOT EXISTS usuario_id bigint;

ALTER TABLE ventas.archivos_clientes
    ADD COLUMN IF NOT EXISTS usuario_id bigint;

-- ON DELETE SET NULL y no CASCADE: si se borra un usuario no se llevan por
-- delante las notas del cliente, que son del cliente y no suyas.
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_notas_clientes_usuario') THEN
        ALTER TABLE ventas.notas_clientes
            ADD CONSTRAINT fk_notas_clientes_usuario
            FOREIGN KEY (usuario_id) REFERENCES seguridad.users(id) ON DELETE SET NULL;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_archivos_clientes_usuario') THEN
        ALTER TABLE ventas.archivos_clientes
            ADD CONSTRAINT fk_archivos_clientes_usuario
            FOREIGN KEY (usuario_id) REFERENCES seguridad.users(id) ON DELETE SET NULL;
    END IF;
END;
$$;

-- El filtro preguntará «de este cliente, lo de estos usuarios»: el índice va
-- por las dos columnas y en ese orden.
CREATE INDEX IF NOT EXISTS ix_notas_clientes_cliente_usuario
    ON ventas.notas_clientes (cliente_id, usuario_id);

CREATE INDEX IF NOT EXISTS ix_archivos_clientes_cliente_usuario
    ON ventas.archivos_clientes (cliente_id, usuario_id);


-- ---------------------------------------------------------------------------
-- 2. El relleno de lo que ya había
-- ---------------------------------------------------------------------------
UPDATE ventas.notas_clientes n
   SET usuario_id = u.id
  FROM seguridad.users u
 WHERE n.usuario_id IS NULL
   AND u.login_user = n.created_by;

UPDATE ventas.archivos_clientes a
   SET usuario_id = u.id
  FROM seguridad.users u
 WHERE a.usuario_id IS NULL
   AND u.login_user = a.created_by;


-- ---------------------------------------------------------------------------
-- 3. Que lo nuevo venga ya con dueño
-- ---------------------------------------------------------------------------
-- Las dos funciones de guardar YA reciben p_usuario_id (lo usan para la
-- auditoría); lo único que faltaba era guardarlo también en la fila.
--
-- Se parchean por sustitución sobre su propia definición en vez de pegarlas
-- enteras: son largas, de ellas sólo cambia el INSERT, y copiarlas aquí
-- significaría mantener dos versiones y arriesgarse a que la de este fichero se
-- quede atrás respecto a la de la base.
--
-- Las dos cadenas aparecen UNA sola vez en cada función (comprobado antes de
-- escribir esto), y las dos funciones las escriben igual:
--
--     ... created_by, updated_by )  VALUES ( ... p_usuario_login, p_usuario_login )
--
-- Sólo se toca el INSERT: al MODIFICAR una nota el dueño no cambia, que sigue
-- siendo quien la escribió.
DO $$
DECLARE
    v_nombre  text;
    v_def     text;
    v_nueva   text;
    v_tocadas int := 0;
BEGIN
    FOREACH v_nombre IN ARRAY ARRAY['fn_notas_clientes_guardar', 'fn_archivos_clientes_guardar'] LOOP
        SELECT pg_get_functiondef(p.oid) INTO v_def
          FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
         WHERE n.nspname = 'ventas' AND p.proname = v_nombre;

        IF v_def IS NULL THEN
            RAISE NOTICE 'no existe %', v_nombre;
            CONTINUE;
        END IF;

        IF position('created_by, updated_by, usuario_id' IN v_def) > 0 THEN
            RAISE NOTICE '% ya guarda usuario_id', v_nombre;
            CONTINUE;
        END IF;

        -- Si no está lo que se espera, no se toca: más vale que la migración
        -- avise a que deje una función rota
        IF position('created_by, updated_by' IN v_def) = 0
           OR position('p_usuario_login, p_usuario_login' IN v_def) = 0 THEN
            RAISE EXCEPTION '% no tiene el INSERT que esperaba: hay que mirarla a mano', v_nombre;
        END IF;

        v_nueva := replace(v_def, 'created_by, updated_by', 'created_by, updated_by, usuario_id');
        v_nueva := replace(v_nueva, 'p_usuario_login, p_usuario_login', 'p_usuario_login, p_usuario_login, p_usuario_id');

        EXECUTE v_nueva;
        v_tocadas := v_tocadas + 1;
        RAISE NOTICE '% actualizada', v_nombre;
    END LOOP;

    RAISE NOTICE 'funciones actualizadas: %', v_tocadas;
END;
$$;


-- ---------------------------------------------------------------------------
-- COMPROBACIÓN
-- ---------------------------------------------------------------------------
SELECT 'notas'    AS tabla, count(*) AS filas, count(usuario_id) AS con_dueno FROM ventas.notas_clientes
UNION ALL
SELECT 'archivos', count(*), count(usuario_id) FROM ventas.archivos_clientes;
