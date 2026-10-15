-- ===========================================================================
-- LOS MENÚS DE INVENTARIOS
-- ===========================================================================
-- Fecha: 2026-10-14
-- Se aplica después de los tres ficheros de inventarios.
--
-- NO HAY TABLA DE PROGRAMAS: el programa ES la fila de seguridad.menus. El
-- nombre sale del segundo tramo de la url —inventarios/allMarcas da
-- ALLMARCAS— y así lo busca findByProgramProfile. Por eso la url tiene que
-- escribirse IGUAL que el `path` de la ruta de Angular; si no coinciden, la
-- pantalla manda a /access-deny y parece un fallo del código.
--
-- `ejecutar` ES EL QUE ABRE LA PUERTA: el resolver de Angular mira ese campo
-- y no `ver`. Sin ejecutar = true no se entra, aunque todo lo demás esté.
--
-- SE LE DA A SISTEMAS (1), que es desde donde se prueba. El resto de perfiles
-- se añaden desde la pantalla de Perfiles; aquí no se reparten accesos a
-- ciegas.
--
-- El menú raíz de Inventarios ya existe (id 59, inventarios/home-inventarios).
--
-- Idempotente: se puede volver a correr.
-- ===========================================================================

DO $$
DECLARE
    c_padre constant bigint := 59;    -- Inventarios
    v_menu  bigint;
    v_orden integer;
    v_item  record;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM seguridad.menus WHERE id = c_padre) THEN
        RAISE EXCEPTION 'No existe el menú padre % (Inventarios)', c_padre;
    END IF;

    FOR v_item IN
        SELECT * FROM (VALUES
            ('inventarios/allCategorias', '🗂️ Categorías', 'Árbol de categorías del catálogo'),
            ('inventarios/allMarcas',     '🏷️ Marcas',     'Marcas de los productos'),
            ('inventarios/allProductos',  '📦 Productos',  'Catálogo de productos')
        ) AS t(url, nombre, descripcion)
    LOOP
        SELECT m.id INTO v_menu FROM seguridad.menus m WHERE m.url = v_item.url;

        IF v_menu IS NULL THEN
            -- Al final de los hermanos, sin pisar el orden de los que ya están
            SELECT COALESCE(MAX(m.orden), 0) + 1 INTO v_orden
              FROM seguridad.menus m WHERE m.padre_id = c_padre;

            INSERT INTO seguridad.menus (padre_id, orden, nivel, nombre, url, descripcion)
            VALUES (c_padre, v_orden, 1, v_item.nombre, v_item.url, v_item.descripcion)
            RETURNING id INTO v_menu;

            RAISE NOTICE 'Menú % creado con id % en el orden %', v_item.url, v_menu, v_orden;
        ELSE
            RAISE NOTICE 'El menú % ya existía (id %)', v_item.url, v_menu;
        END IF;

        IF NOT EXISTS (SELECT 1 FROM seguridad.accesos a WHERE a.menu_id = v_menu AND a.perfil_id = 1) THEN
            INSERT INTO seguridad.accesos
                   (perfil_id, menu_id, ver, crear, editar, eliminar, listar, reporte, auditar, ejecutar, papelera)
            VALUES (1, v_menu, true, true, true, true, true, true, true, true, false);
            RAISE NOTICE '  acceso dado al perfil SISTEMAS';
        END IF;
    END LOOP;
END $$;


-- ---------------------------------------------------------------------------
-- COMPROBACIÓN
-- ---------------------------------------------------------------------------
SELECT m.id, m.padre_id, m.orden, m.nivel, m.nombre, m.url
  FROM seguridad.menus m
 WHERE m.id = 59 OR m.padre_id = 59
 ORDER BY m.padre_id NULLS FIRST, m.orden;

-- Lo que contestará findByProgramProfile al entrar en cada pantalla
SELECT UPPER(SPLIT_PART(m.url, '/', 2)) AS programa,
       a.perfil_id, p.nombre AS perfil, a.ejecutar, a.ver, a.crear, a.editar, a.eliminar, a.auditar
  FROM seguridad.accesos a
  JOIN seguridad.menus m    ON m.id = a.menu_id
  JOIN seguridad.perfiles p ON p.id = a.perfil_id
 WHERE m.url LIKE 'inventarios/%'
 ORDER BY 1, 2;
