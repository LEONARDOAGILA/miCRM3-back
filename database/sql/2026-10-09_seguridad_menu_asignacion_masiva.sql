-- ===========================================================================
-- EL MENÚ DE «REPARTIR CLIENTES»
-- ===========================================================================
-- Fecha: 2026-10-09
-- Se aplica después de 2026-10-09_ventas_asignacion_masiva.sql.
--
-- La pantalla de reparto en bloque pasa a ser un programa con su entrada de
-- menú, debajo de Ventas.
--
-- NO HAY TABLA DE PROGRAMAS: el programa ES la fila de seguridad.menus. El
-- nombre sale del segundo tramo de la url —ventas/asignacionClienteMasiva da
-- ASIGNACIONCLIENTEMASIVA— y así lo busca findByProgramProfile. Por eso la
-- url tiene que escribirse igual que el `path` de la ruta de Angular; si no
-- coinciden, la pantalla manda a /access-deny y parece un fallo del código.
--
-- `ejecutar` ES EL QUE ABRE LA PUERTA. El resolver de Angular mira ese campo y
-- no `ver`: sin ejecutar = true no se entra, aunque todo lo demás esté puesto.
--
-- SÓLO AL PERFIL SISTEMAS, a propósito. El reparto lo cierra el servidor a los
-- administradores (es_administrador del GRUPO) y hoy los tres administradores
-- están en ese perfil. Dárselo a GERENCIA o a VENDEDOR sería enseñarles un
-- menú que al abrirlo contesta «Sólo un administrador puede repartir
-- clientes»: un camino que no lleva a ninguna parte. Si mañana otro grupo pasa
-- a ser administrador, el acceso se añade desde la pantalla de Perfiles sin
-- tocar esto.
--
-- Idempotente: se puede volver a correr.
-- ===========================================================================

DO $$
DECLARE
    c_url    constant varchar := 'ventas/asignacionClienteMasiva';
    c_padre  constant bigint  := 58;    -- Ventas
    v_menu   bigint;
    v_orden  integer;
BEGIN
    -- ---------------- la entrada del menú ----------------
    SELECT m.id INTO v_menu FROM seguridad.menus m WHERE m.url = c_url;

    IF v_menu IS NULL THEN
        IF NOT EXISTS (SELECT 1 FROM seguridad.menus WHERE id = c_padre) THEN
            RAISE EXCEPTION 'No existe el menú padre % (Ventas)', c_padre;
        END IF;

        -- Al final de los hermanos, sin pisar el orden de los que ya están
        SELECT COALESCE(MAX(m.orden), 0) + 1 INTO v_orden
          FROM seguridad.menus m WHERE m.padre_id = c_padre;

        INSERT INTO seguridad.menus (padre_id, orden, nivel, nombre, url, descripcion)
        VALUES (c_padre, v_orden, 1, '🔀 Reparto de Clientes', c_url,
                'Asignar vendedor, cobrador, asistente o postventa a muchos clientes de una vez')
        RETURNING id INTO v_menu;

        RAISE NOTICE 'Menú creado con id % en el orden %', v_menu, v_orden;
    ELSE
        RAISE NOTICE 'El menú ya existía (id %)', v_menu;
    END IF;

    -- ---------------- quién entra ----------------
    -- Sólo SISTEMAS (1), que es donde están hoy los administradores.
    -- ejecutar = true o el resolver manda a /access-deny.
    IF NOT EXISTS (SELECT 1 FROM seguridad.accesos a WHERE a.menu_id = v_menu AND a.perfil_id = 1) THEN
        INSERT INTO seguridad.accesos
               (perfil_id, menu_id, ver, crear, editar, eliminar, listar, reporte, auditar, ejecutar, papelera)
        VALUES (1, v_menu, true, false, true, false, true, false, true, true, false);
        RAISE NOTICE 'Acceso dado al perfil SISTEMAS';
    ELSE
        RAISE NOTICE 'El perfil SISTEMAS ya tenía acceso';
    END IF;
END $$;


-- ---------------------------------------------------------------------------
-- COMPROBACIÓN
-- ---------------------------------------------------------------------------
-- Cómo queda el menú de Ventas
SELECT m.id, m.padre_id, m.orden, m.nombre, m.url
  FROM seguridad.menus m
 WHERE m.id = 58 OR m.padre_id = 58
 ORDER BY m.padre_id NULLS FIRST, m.orden;

-- Y lo que contestará findByProgramProfile al entrar
SELECT a.perfil_id, p.nombre AS perfil,
       UPPER(SPLIT_PART(m.url, '/', 2)) AS programa,
       a.ejecutar, a.ver, a.editar
  FROM seguridad.accesos a
  JOIN seguridad.menus m    ON m.id = a.menu_id
  JOIN seguridad.perfiles p ON p.id = a.perfil_id
 WHERE m.url = 'ventas/asignacionClienteMasiva'
 ORDER BY a.perfil_id;
