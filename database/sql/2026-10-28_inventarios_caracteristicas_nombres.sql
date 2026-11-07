-- ============================================================================
-- DICCIONARIO DE NOMBRES DE CARACTERÍSTICAS
-- ============================================================================
-- Fecha: 2026-10-28
--
-- EL PROBLEMA
--
-- Hasta hoy el nombre de cada característica se escribía a mano en cada
-- categoría. Medido antes de esta migración: 98 filas para 19 categorías pero
-- sólo 64 nombres distintos. «Color» escrito 4 veces, «Eficiencia energética»
-- 4, «Potencia (W)» 4, «Tipo» 4. Cada reescritura es una oportunidad de poner
-- «pezo» en vez de «peso», y entonces la reportería de logística no sale.
--
-- Ahora el nombre vive UNA vez en `inventarios.caracteristicas_nombres` y la
-- categoría lo apunta con `nombre_id`. Quien administra el diccionario es
-- sistemas (su propio programa y menú); el usuario del día a día sólo escoge.
--
-- LO QUE SE DESCUBRIÓ EN LOS DATOS, Y POR QUÉ EL DICCIONARIO TIENE TRES CAMPOS
--
-- · 27 de los 64 nombres traían la unidad DENTRO del texto: «Potencia (W)»,
--   «Capacidad (litros)», «Batería (mAh)». Mientras la unidad viva en el
--   nombre, «Potencia (W)» y «Potencia (kW)» son dos características distintas
--   para el sistema. Por eso `unidad` es una columna.
--
-- · 8 nombres no traían una unidad entre paréntesis sino LA LISTA DE VALORES
--   PERMITIDOS, porque no había tipo lista: «Tipo (gas / eléctrica)»,
--   «Tipo (split / portátil / ventana)», «Red (4G / 5G)». Por eso hay `tipo`.
--
-- · Y la lista de valores NO puede ir en el diccionario: «Tipo» significa
--   (gas / eléctrica) en cocinas y (split / portátil / ventana) en aires. Va
--   en `caracteristicas_categorias.valores_lista`, que es donde la categoría
--   dice qué opciones son las suyas. El diccionario sólo dice que «Tipo» es
--   de tipo LISTA.
--
-- · La unidad, en cambio, SÍ va en el diccionario: «Capacidad (litros)» de una
--   refrigeradora y «Capacidad (BTU)» de un aire no son la misma magnitud
--   medida en dos unidades, son dos cosas distintas que comparten la palabra.
--   Juntarlas haría la reportería peor, no mejor: un informe de «capacidad»
--   sumaría litros con BTU.
--
-- CÓMO SE MIGRAN LOS NOMBRES QUE YA HAY (sin inventar ninguno)
--
--   paréntesis con «/»        → tipo LISTA; el nombre pierde el paréntesis
--                               (se FUSIONAN: los 5 «Tipo…» pasan a ser uno)
--                               y las opciones se guardan en la categoría
--   paréntesis con una unidad → tipo NÚMERO, `unidad` aparte, y el nombre
--                               pierde el paréntesis SÓLO si así no choca con
--                               otro nombre existente; si choca se queda
--                               entero (ahí hay que decidir a mano cómo se
--                               llama cada uno, y eso no lo hace un script)
--   cualquier otro            → tipo TEXTO, nombre tal cual
--                               («Dimensiones (alto x ancho x fondo)» cae
--                                aquí: eso son tres números en un campo de
--                                texto y su sitio son columnas del producto,
--                                que es otra tarea)
--
-- No se pierde ningún nombre y no se renombra nada por sorpresa: lo que el
-- script no sabe encajar lo deja igual.
--
-- ORDEN: este fichero, luego `..._nombres_funciones.sql`, luego
-- `..._caracteristicas_al_diccionario.sql` (que es el que borra la columna
-- `nombre` vieja, cuando ya no la nombra ninguna función).
--
-- Se puede volver a correr: la siembra se salta sola si la columna `nombre`
-- ya no existe, que es la señal de que esto ya se migró.
-- ============================================================================
\set ON_ERROR_STOP on

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. NORMALIZAR UN NOMBRE
-- ---------------------------------------------------------------------------
-- El índice único del diccionario va sobre esto, no sobre el texto crudo. Sin
-- normalizar, «Batería», «bateria» y «Bateria » son tres entradas distintas y
-- el combo vuelve a tener basura. El índice que había en
-- caracteristicas_categorias era UPPER(TRIM(nombre)): recoge las mayúsculas y
-- los espacios de los bordes, pero no las tildes ni los espacios dobles.
--
-- IMMUTABLE porque un índice de expresión lo exige. No se usa `unaccent`: no
-- está instalada la extensión (sólo plpgsql) y además es STABLE, no IMMUTABLE,
-- porque depende de un diccionario. Con `translate` basta para el español.
CREATE OR REPLACE FUNCTION inventarios.fn_normalizar_nombre(p_texto text)
RETURNS text
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
AS $$
    SELECT btrim(regexp_replace(
               lower(translate(COALESCE(p_texto, ''),
                     'ÁÉÍÓÚÀÈÌÒÙÄËÏÖÜÂÊÎÔÛÑÇáéíóúàèìòùäëïöüâêîôûñç',
                     'AEIOUAEIOUAEIOUAEIOUNCaeiouaeiouaeiouaeiounc')),
               '\s+', ' ', 'g'));
$$;

COMMENT ON FUNCTION inventarios.fn_normalizar_nombre(text) IS
  'Minúsculas, sin tildes y con los espacios colapsados. Es la clave única del diccionario de nombres.';

-- ---------------------------------------------------------------------------
-- 2. EL DICCIONARIO
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS inventarios.caracteristicas_nombres (
    id          bigserial     NOT NULL,
    nombre      varchar(100)  NOT NULL,
    -- La unidad SEPARADA del nombre: «Potencia» + «W», no «Potencia (W)».
    -- Así se puede cambiar la unidad sin renombrar, y el informe sabe en qué
    -- está medido lo que suma.
    unidad      varchar(20),
    -- TEXTO  → caja de texto
    -- NUMERO → sólo cifras (lo que logística necesita para poder sumar)
    -- SI_NO  → sí o no
    -- LISTA  → se escoge de las opciones que define cada categoría en
    --          caracteristicas_categorias.valores_lista
    tipo        varchar(10)   NOT NULL DEFAULT 'TEXTO',
    descripcion text,
    activo      boolean       NOT NULL DEFAULT true,
    created_at  timestamp with time zone DEFAULT now(),
    updated_at  timestamp with time zone DEFAULT now(),
    created_by  varchar(100),
    updated_by  varchar(100),
    deleted_at  timestamp with time zone,
    deleted_by  varchar(100),
    CONSTRAINT pk_caracteristicas_nombres PRIMARY KEY (id),
    CONSTRAINT ck_caracteristicas_nombres_tipo
        CHECK (tipo IN ('TEXTO', 'NUMERO', 'SI_NO', 'LISTA')),
    CONSTRAINT ck_caracteristicas_nombres_nombre
        CHECK (length(btrim(nombre)) >= 2)
);

-- Único sobre el nombre normalizado, INCLUIDA la papelera: igual que en
-- categorías y marcas, un nombre en la papelera sigue ocupando su sitio y la
-- función lo dice con un mensaje claro en vez de dejar dos.
CREATE UNIQUE INDEX IF NOT EXISTS uq_caracteristicas_nombres
    ON inventarios.caracteristicas_nombres (inventarios.fn_normalizar_nombre(nombre));

CREATE INDEX IF NOT EXISTS ix_caracteristicas_nombres_activo
    ON inventarios.caracteristicas_nombres (activo) WHERE activo;

CREATE INDEX IF NOT EXISTS ix_caracteristicas_nombres_deleted_at
    ON inventarios.caracteristicas_nombres (deleted_at) WHERE deleted_at IS NOT NULL;

COMMENT ON TABLE inventarios.caracteristicas_nombres IS
  'Diccionario de nombres de característica: el nombre se escribe una vez y las categorías lo apuntan. Lo mantiene sistemas.';

-- Los tres disparadores de la casa, igual que en las otras cuatro tablas de
-- inventarios: el contexto app.* lo deja la función plpgsql y éstos lo graban.
DROP TRIGGER IF EXISTS trg_caracteristicas_nombres_audit ON inventarios.caracteristicas_nombres;
CREATE TRIGGER trg_caracteristicas_nombres_audit
    AFTER INSERT OR UPDATE OR DELETE ON inventarios.caracteristicas_nombres
    FOR EACH ROW EXECUTE FUNCTION auditoria.fn_auditar_cambios();

DROP TRIGGER IF EXISTS trg_caracteristicas_nombres_users ON inventarios.caracteristicas_nombres;
CREATE TRIGGER trg_caracteristicas_nombres_users
    BEFORE INSERT OR UPDATE ON inventarios.caracteristicas_nombres
    FOR EACH ROW EXECUTE FUNCTION auditoria.fn_set_audit_users();

DROP TRIGGER IF EXISTS trg_caracteristicas_nombres_updated_at ON inventarios.caracteristicas_nombres;
CREATE TRIGGER trg_caracteristicas_nombres_updated_at
    BEFORE UPDATE ON inventarios.caracteristicas_nombres
    FOR EACH ROW EXECUTE FUNCTION auditoria.fn_update_updated_at_column();

-- ---------------------------------------------------------------------------
-- 3. LAS COLUMNAS NUEVAS DE LA CATEGORÍA
-- ---------------------------------------------------------------------------
ALTER TABLE inventarios.caracteristicas_categorias
    ADD COLUMN IF NOT EXISTS nombre_id     bigint,
    ADD COLUMN IF NOT EXISTS valores_lista text[];

COMMENT ON COLUMN inventarios.caracteristicas_categorias.valores_lista IS
  'Las opciones permitidas cuando el nombre es de tipo LISTA. Son de la CATEGORÍA: «Tipo» es (gas / eléctrica) en cocinas y (split / portátil / ventana) en aires.';

-- El valor del producto guarda también a qué nombre del diccionario apunta,
-- para que un informe pueda agrupar por el diccionario y no por el texto. El
-- `nombre` de esa tabla NO se toca: es una foto de cómo se llamaba cuando se
-- rellenó, y la pantalla del producto ya lo promete así.
ALTER TABLE inventarios.caracteristicas_productos
    ADD COLUMN IF NOT EXISTS nombre_id bigint;

-- ---------------------------------------------------------------------------
-- 4. SEMBRAR EL DICCIONARIO CON LO QUE YA HAY
-- ---------------------------------------------------------------------------
DO $sembrar$
DECLARE
    r            record;
    v_parent     text;
    v_base       text;
    v_unidad     text;
    v_tipo       text;
    v_nombre     text;
    v_cuantos    integer;
    v_id         bigint;
    v_nuevos     integer := 0;
BEGIN
    -- Si la columna vieja ya no está, esto ya se corrió: no hay de dónde
    -- sembrar y tampoco hace falta. (Las sentencias de abajo nombran
    -- `k.nombre`, pero plpgsql no las prepara hasta ejecutarlas, así que
    -- salir aquí no revienta nada.)
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                    WHERE table_schema = 'inventarios'
                      AND table_name   = 'caracteristicas_categorias'
                      AND column_name  = 'nombre') THEN
        RAISE NOTICE 'La columna nombre ya no existe: el diccionario ya estaba migrado.';
        RETURN;
    END IF;

    -- El mapa de «nombre viejo normalizado» → «id del diccionario», para
    -- rellenar después nombre_id sin repetir aquí toda la lógica.
    CREATE TEMP TABLE IF NOT EXISTS tmp_mapa_nombres (
        norm      text PRIMARY KEY,
        nombre_id bigint
    ) ON COMMIT DROP;
    DELETE FROM tmp_mapa_nombres;

    FOR r IN
        -- Un nombre por grafía normalizada, quedándose con la forma más usada
        SELECT mode() WITHIN GROUP (ORDER BY nombre) AS nombre,
               inventarios.fn_normalizar_nombre(nombre) AS norm
          FROM inventarios.caracteristicas_categorias
         GROUP BY inventarios.fn_normalizar_nombre(nombre)
         ORDER BY 2
    LOOP
        v_parent := NULLIF(btrim(COALESCE(substring(r.nombre from '\(([^()]*)\)\s*$'), '')), '');
        v_base   := btrim(regexp_replace(r.nombre, '\s*\([^()]*\)\s*$', ''));
        v_unidad := NULL;
        v_tipo   := 'TEXTO';
        v_nombre := r.nombre;

        IF v_parent IS NULL OR length(v_base) < 2 THEN
            -- Sin paréntesis (o el paréntesis ES el nombre): tal cual
            NULL;

        ELSIF position('/' IN v_parent) > 0 THEN
            -- El paréntesis era la lista de opciones: fuera del nombre. Aquí
            -- SÍ se fusiona, porque las opciones pasan a ser de la categoría.
            v_tipo   := 'LISTA';
            v_nombre := v_base;

        ELSIF lower(v_parent) IN ('m²','m2','mah','ah','mp','btu','litros','litro','l',
                                  'kg','g','lb','rpm','hz','khz','mhz','ghz','w','kw',
                                  'pulgadas','pulg','dpi','ppm','°c','c','v','seer',
                                  'cm','mm','m','m³','m3','gb','tb','mb','db','lm','%') THEN
            -- Era una unidad: se guarda aparte y el nombre la suelta... pero
            -- sólo si al soltarla no se confunde con otro nombre que ya
            -- existe. «Capacidad (litros)» y «Capacidad (BTU)» se quedan
            -- enteros a propósito: no son la misma cosa.
            v_tipo := 'NUMERO';
            v_unidad := CASE lower(v_parent)
                WHEN 'm2' THEN 'm²'   WHEN 'm3' THEN 'm³'
                WHEN 'mah' THEN 'mAh' WHEN 'ah' THEN 'Ah'
                WHEN 'mp' THEN 'MP'   WHEN 'btu' THEN 'BTU'
                WHEN 'litro' THEN 'litros' WHEN 'l' THEN 'litros'
                WHEN 'rpm' THEN 'RPM' WHEN 'hz' THEN 'Hz'
                WHEN 'khz' THEN 'kHz' WHEN 'mhz' THEN 'MHz'
                WHEN 'ghz' THEN 'GHz' WHEN 'w' THEN 'W'
                WHEN 'kw' THEN 'kW'   WHEN 'pulg' THEN 'pulgadas'
                WHEN 'dpi' THEN 'DPI' WHEN 'c' THEN '°C'
                WHEN 'v' THEN 'V'     WHEN 'seer' THEN 'SEER'
                WHEN 'gb' THEN 'GB'   WHEN 'tb' THEN 'TB'
                WHEN 'mb' THEN 'MB'   WHEN 'db' THEN 'dB'
                ELSE v_parent
            END;

            -- Se cuentan NOMBRES DE ORIGEN, no cadenas: si se contaran cadenas
            -- distintas, «Batería (mAh)» y «Batería» darían las dos la cadena
            -- «bateria» y el UNION las dejaría en una sola, con lo que el
            -- primero se acortaría y chocaría con el segundo.
            SELECT count(*) INTO v_cuantos
              FROM (SELECT DISTINCT
                           inventarios.fn_normalizar_nombre(nombre) AS propio,
                           inventarios.fn_normalizar_nombre(
                               btrim(regexp_replace(nombre, '\s*\([^()]*\)\s*$', ''))) AS base
                      FROM inventarios.caracteristicas_categorias) s
             WHERE inventarios.fn_normalizar_nombre(v_base) IN (s.propio, s.base);

            -- > 1 significa que ese nombre corto ya lo reclama algo más
            IF v_cuantos = 1 THEN
                v_nombre := v_base;
            END IF;
        END IF;

        -- LISTA gana sobre TEXTO al fusionar: si «Tipo» entró primero suelto
        -- y luego llega «Tipo (gas / eléctrica)», el nombre pasa a ser LISTA.
        INSERT INTO inventarios.caracteristicas_nombres AS cn (nombre, unidad, tipo)
        VALUES (v_nombre, v_unidad, v_tipo)
            ON CONFLICT (inventarios.fn_normalizar_nombre(nombre)) DO UPDATE
               SET tipo   = CASE WHEN EXCLUDED.tipo = 'LISTA' THEN 'LISTA'
                                 ELSE cn.tipo END,
                   unidad = COALESCE(cn.unidad, EXCLUDED.unidad)
        RETURNING cn.id INTO v_id;

        IF v_id IS NULL THEN
            SELECT id INTO v_id FROM inventarios.caracteristicas_nombres
             WHERE inventarios.fn_normalizar_nombre(nombre) = inventarios.fn_normalizar_nombre(v_nombre);
        ELSE
            v_nuevos := v_nuevos + 1;
        END IF;

        INSERT INTO tmp_mapa_nombres (norm, nombre_id) VALUES (r.norm, v_id)
            ON CONFLICT (norm) DO UPDATE SET nombre_id = EXCLUDED.nombre_id;
    END LOOP;

    -- Las opciones, a la categoría: fila por fila, porque cada una tiene su
    -- propia lista aunque el nombre del diccionario sea el mismo.
    UPDATE inventarios.caracteristicas_categorias k
       SET valores_lista = (
            SELECT array_agg(btrim(t.v) ORDER BY t.o)
              FROM unnest(string_to_array(
                       btrim(substring(k.nombre from '\(([^()]*)\)\s*$')), '/'))
                   WITH ORDINALITY AS t(v, o)
             WHERE length(btrim(t.v)) > 0)
     WHERE k.nombre ~ '\([^()]*/[^()]*\)\s*$'
       AND k.valores_lista IS NULL;

    -- Y la categoría, enganchada a su nombre del diccionario.
    UPDATE inventarios.caracteristicas_categorias k
       SET nombre_id = m.nombre_id
      FROM tmp_mapa_nombres m
     WHERE m.norm = inventarios.fn_normalizar_nombre(k.nombre)
       AND k.nombre_id IS DISTINCT FROM m.nombre_id;

    RAISE NOTICE 'diccionario: % entradas tocadas', v_nuevos;
END
$sembrar$;

-- ---------------------------------------------------------------------------
-- 5. LOS VALORES YA RELLENOS DE LOS PRODUCTOS
-- ---------------------------------------------------------------------------
-- Para que un informe pueda
-- agrupar por el diccionario. Los que vengan de una plantilla salen de ella;
-- los sueltos, por el nombre, y si no está en el diccionario se quedan en NULL
-- (su `nombre` sigue enseñándose igual).
UPDATE inventarios.caracteristicas_productos v
   SET nombre_id = k.nombre_id
  FROM inventarios.caracteristicas_categorias k
 WHERE k.id = v.caracteristica_id
   AND v.nombre_id IS NULL;

UPDATE inventarios.caracteristicas_productos v
   SET nombre_id = n.id
  FROM inventarios.caracteristicas_nombres n
 WHERE v.caracteristica_id IS NULL
   AND v.nombre_id IS NULL
   AND inventarios.fn_normalizar_nombre(n.nombre) = inventarios.fn_normalizar_nombre(v.nombre);

-- ---------------------------------------------------------------------------
-- 6. QUE NO QUEDE NINGUNA SUELTA
-- ---------------------------------------------------------------------------
DO $comprobar$
DECLARE v_huerfanas integer;
BEGIN
    SELECT count(*) INTO v_huerfanas
      FROM inventarios.caracteristicas_categorias WHERE nombre_id IS NULL;
    IF v_huerfanas > 0 THEN
        RAISE EXCEPTION 'Quedan % características sin nombre del diccionario', v_huerfanas;
    END IF;
END
$comprobar$;

ALTER TABLE inventarios.caracteristicas_categorias
    ALTER COLUMN nombre_id SET NOT NULL;

ALTER TABLE inventarios.caracteristicas_categorias
    DROP CONSTRAINT IF EXISTS fk_caracteristicas_nombre;
ALTER TABLE inventarios.caracteristicas_categorias
    ADD CONSTRAINT fk_caracteristicas_nombre
        FOREIGN KEY (nombre_id) REFERENCES inventarios.caracteristicas_nombres (id);

ALTER TABLE inventarios.caracteristicas_productos
    DROP CONSTRAINT IF EXISTS fk_caracteristicas_prod_nombre;
ALTER TABLE inventarios.caracteristicas_productos
    ADD CONSTRAINT fk_caracteristicas_prod_nombre
        FOREIGN KEY (nombre_id) REFERENCES inventarios.caracteristicas_nombres (id);

-- ---------------------------------------------------------------------------
-- 7. EL ÚNICO, AHORA POR ID
-- ---------------------------------------------------------------------------
-- Antes: (categoria_id, UPPER(TRIM(nombre))). Ahora el nombre es un id, así
-- que no hace falta normalizar nada aquí: lo hace el diccionario.
DROP INDEX IF EXISTS inventarios.uq_caracteristicas_cat_nombre;
CREATE UNIQUE INDEX IF NOT EXISTS uq_caracteristicas_cat_nombre_id
    ON inventarios.caracteristicas_categorias (categoria_id, nombre_id);

-- La suelta de un producto, también por id. La vieja iba por el texto, que es
-- la segunda puerta por la que entraba «pezo».
DROP INDEX IF EXISTS inventarios.uq_caracteristicas_prod_suelta;
CREATE UNIQUE INDEX IF NOT EXISTS uq_caracteristicas_prod_suelta
    ON inventarios.caracteristicas_productos (producto_id, nombre_id)
 WHERE caracteristica_id IS NULL AND nombre_id IS NOT NULL;

-- Las sueltas viejas que no se pudieron enganchar al diccionario siguen
-- necesitando no repetirse entre ellas.
CREATE UNIQUE INDEX IF NOT EXISTS uq_caracteristicas_prod_suelta_vieja
    ON inventarios.caracteristicas_productos (producto_id, (UPPER(btrim(nombre))))
 WHERE caracteristica_id IS NULL AND nombre_id IS NULL;

-- ---------------------------------------------------------------------------
-- 8. QUÉ QUEDÓ
-- ---------------------------------------------------------------------------
SELECT 'diccionario: ' || count(*) || ' nombres · ' ||
       count(*) FILTER (WHERE tipo = 'NUMERO') || ' numéricos · ' ||
       count(*) FILTER (WHERE tipo = 'LISTA')  || ' de lista · ' ||
       count(*) FILTER (WHERE unidad IS NOT NULL) || ' con unidad'
  FROM inventarios.caracteristicas_nombres;

SELECT 'características de categoría: ' || count(*) || ' filas, ' ||
       count(DISTINCT nombre_id) || ' nombres distintos, ' ||
       count(*) FILTER (WHERE valores_lista IS NOT NULL) || ' con opciones'
  FROM inventarios.caracteristicas_categorias;

COMMIT;
