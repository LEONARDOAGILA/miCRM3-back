-- ============================================================================
-- PERMISOS POR ARCHIVO (por usuario) — administrador de archivos
-- ----------------------------------------------------------------------------
-- 1. core.archivos: propietario_id (quien lo crea tiene todo) y publico
--    (lo ven todos los usuarios logueados, sin dar permisos uno a uno).
-- 2. seguridad.permisos_archivos: una fila por usuario y archivo/carpeta.
--    En carpetas, `hereda` lo extiende a todo el subárbol; `denegar` es una
--    regla de exclusión que gana sobre cualquier permiso; `vigente_hasta`
--    da accesos temporales.
-- 3. core.archivos_accesos: quién ejecutó o descargó qué y cuándo (reportería).
-- 4. seguridad.fn_permiso_archivo(user, archivo): permiso efectivo resuelto
--    (admin / propietario / la fila más cercana manda: archivo > carpeta padre >
--    abuela… / público). Lo usa el back para filtrar y autorizar; el front sólo oculta.
-- Idempotente: se puede ejecutar más de una vez.
-- ============================================================================

-- ---------- 1. core.archivos ----------
ALTER TABLE core.archivos
    ADD COLUMN IF NOT EXISTS propietario_id bigint
        REFERENCES seguridad.users (id) ON UPDATE NO ACTION ON DELETE SET NULL,
    ADD COLUMN IF NOT EXISTS publico boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN core.archivos.propietario_id IS 'Usuario que creó el archivo/carpeta: siempre tiene todos los permisos sobre él';
COMMENT ON COLUMN core.archivos.publico        IS 'true = lo ven y abren todos los usuarios logueados (sin descargar), sin necesidad de permisos';

CREATE INDEX IF NOT EXISTS idx_archivos_propietario ON core.archivos (propietario_id);

-- ---------- 2. seguridad.permisos_archivos ----------
CREATE TABLE IF NOT EXISTS seguridad.permisos_archivos
(
    id              bigserial NOT NULL,
    archivo_id      bigint    NOT NULL,
    user_id         bigint    NOT NULL,

    ver             boolean   NOT NULL DEFAULT true,
    ejecutar        boolean   NOT NULL DEFAULT true,
    descargar       boolean   NOT NULL DEFAULT false,
    crear           boolean   NOT NULL DEFAULT false,
    editar          boolean   NOT NULL DEFAULT false,
    eliminar        boolean   NOT NULL DEFAULT false,
    administrar     boolean   NOT NULL DEFAULT false,
    restaurar       boolean   NOT NULL DEFAULT false,

    hereda          boolean   NOT NULL DEFAULT true,
    denegar         boolean   NOT NULL DEFAULT false,
    vigente_hasta   timestamp with time zone,

    created_at      timestamp with time zone DEFAULT now(),
    updated_at      timestamp with time zone DEFAULT now(),
    created_by      character varying(100) COLLATE pg_catalog."default",
    updated_by      character varying(100) COLLATE pg_catalog."default",

    CONSTRAINT pk_permisos_archivos PRIMARY KEY (id),
    CONSTRAINT uq_permisos_archivos_archivo_user UNIQUE (archivo_id, user_id),
    CONSTRAINT fk_permisos_archivos_archivo FOREIGN KEY (archivo_id)
        REFERENCES core.archivos (id) MATCH SIMPLE ON UPDATE NO ACTION ON DELETE CASCADE,
    CONSTRAINT fk_permisos_archivos_user FOREIGN KEY (user_id)
        REFERENCES seguridad.users (id) MATCH SIMPLE ON UPDATE NO ACTION ON DELETE CASCADE
)
TABLESPACE pg_default;

ALTER TABLE IF EXISTS seguridad.permisos_archivos OWNER to postgres;

-- Columna añadida después: para bases que ya tenían la tabla
ALTER TABLE seguridad.permisos_archivos ADD COLUMN IF NOT EXISTS restaurar boolean NOT NULL DEFAULT false;

COMMENT ON TABLE  seguridad.permisos_archivos               IS 'Permisos de un usuario sobre un archivo o carpeta del administrador de archivos';
COMMENT ON COLUMN seguridad.permisos_archivos.id            IS 'Identificador único (PK)';
COMMENT ON COLUMN seguridad.permisos_archivos.archivo_id    IS 'Archivo o carpeta (FK core.archivos)';
COMMENT ON COLUMN seguridad.permisos_archivos.user_id       IS 'Usuario al que se concede (FK seguridad.users)';
COMMENT ON COLUMN seguridad.permisos_archivos.ver           IS 'Lo ve en el árbol y la lista';
COMMENT ON COLUMN seguridad.permisos_archivos.ejecutar      IS 'Lo abre en el visor';
COMMENT ON COLUMN seguridad.permisos_archivos.descargar     IS 'Puede descargarlo / abrirlo en otra pestaña (si proteger_url lo permite)';
COMMENT ON COLUMN seguridad.permisos_archivos.crear         IS 'Puede crear dentro (sólo carpetas)';
COMMENT ON COLUMN seguridad.permisos_archivos.editar        IS 'Puede modificarlo';
COMMENT ON COLUMN seguridad.permisos_archivos.eliminar      IS 'Puede enviarlo a la papelera';
COMMENT ON COLUMN seguridad.permisos_archivos.administrar   IS 'Puede dar permisos a otros sobre este nodo';
COMMENT ON COLUMN seguridad.permisos_archivos.restaurar     IS 'Puede ver la papelera y restaurar lo que se eliminó de aquí (y de lo que cuelga, si hereda)';
COMMENT ON COLUMN seguridad.permisos_archivos.hereda        IS 'En carpetas: el permiso vale para todo el subárbol';
COMMENT ON COLUMN seguridad.permisos_archivos.denegar       IS 'Regla de exclusión: si esta fila es la que manda (la más cercana), el usuario no puede nada';
COMMENT ON COLUMN seguridad.permisos_archivos.vigente_hasta IS 'Caducidad del permiso; NULL = sin caducidad';
COMMENT ON COLUMN seguridad.permisos_archivos.created_at    IS 'Fecha y hora de creación del registro';
COMMENT ON COLUMN seguridad.permisos_archivos.updated_at    IS 'Fecha y hora de última actualización del registro';
COMMENT ON COLUMN seguridad.permisos_archivos.created_by    IS 'Usuario que creó el registro';
COMMENT ON COLUMN seguridad.permisos_archivos.updated_by    IS 'Usuario que actualizó el registro';

CREATE INDEX IF NOT EXISTS idx_permisos_archivos_user    ON seguridad.permisos_archivos (user_id);
CREATE INDEX IF NOT EXISTS idx_permisos_archivos_archivo ON seguridad.permisos_archivos (archivo_id);

-- Mismos triggers que core.archivos: auditoría, created_by/updated_by, updated_at
CREATE OR REPLACE TRIGGER trg_permisos_archivos_audit
    AFTER INSERT OR DELETE OR UPDATE ON seguridad.permisos_archivos
    FOR EACH ROW EXECUTE FUNCTION auditoria.fn_auditar_cambios();

CREATE OR REPLACE TRIGGER trigger_permisos_archivos_set_users
    BEFORE INSERT OR UPDATE ON seguridad.permisos_archivos
    FOR EACH ROW EXECUTE FUNCTION auditoria.fn_set_audit_users();

CREATE OR REPLACE TRIGGER trigger_permisos_archivos_updated_at
    BEFORE UPDATE ON seguridad.permisos_archivos
    FOR EACH ROW EXECUTE FUNCTION auditoria.fn_update_updated_at_column();

-- ---------- 3. core.archivos_accesos (registro de uso) ----------
CREATE TABLE IF NOT EXISTS core.archivos_accesos
(
    id             bigserial NOT NULL,
    archivo_id     bigint    NOT NULL,
    user_id        bigint,
    usuario_login  character varying(100) COLLATE pg_catalog."default",
    accion         character varying(20)  COLLATE pg_catalog."default" NOT NULL,
    ip_address     inet,
    user_agent     text COLLATE pg_catalog."default",
    created_at     timestamp with time zone NOT NULL DEFAULT now(),

    CONSTRAINT pk_archivos_accesos PRIMARY KEY (id),
    CONSTRAINT ck_archivos_accesos_accion CHECK (accion IN ('EJECUTAR', 'DESCARGAR')),
    CONSTRAINT fk_archivos_accesos_archivo FOREIGN KEY (archivo_id)
        REFERENCES core.archivos (id) MATCH SIMPLE ON UPDATE NO ACTION ON DELETE CASCADE,
    CONSTRAINT fk_archivos_accesos_user FOREIGN KEY (user_id)
        REFERENCES seguridad.users (id) MATCH SIMPLE ON UPDATE NO ACTION ON DELETE SET NULL
)
TABLESPACE pg_default;

ALTER TABLE IF EXISTS core.archivos_accesos OWNER to postgres;

COMMENT ON TABLE  core.archivos_accesos            IS 'Quién abrió (EJECUTAR) o descargó (DESCARGAR) cada archivo y cuándo';
COMMENT ON COLUMN core.archivos_accesos.accion     IS 'EJECUTAR (abrir en el visor) o DESCARGAR (fichero / zip)';
COMMENT ON COLUMN core.archivos_accesos.usuario_login IS 'Login en el momento del acceso (se conserva aunque el usuario se borre)';

CREATE INDEX IF NOT EXISTS idx_archivos_accesos_archivo ON core.archivos_accesos (archivo_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_archivos_accesos_user    ON core.archivos_accesos (user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_archivos_accesos_fecha   ON core.archivos_accesos (created_at DESC);

-- ---------- 4. Permiso efectivo ----------
-- Devuelve una fila con las 7 banderas resueltas y de dónde salen:
--   ADMIN       usuario de tipo 1 (super usuario) o 2 (administrador): todo
--   PROPIETARIO el archivo es suyo: todo
--   DIRECTO     tiene fila propia en el archivo: manda ella (y sólo ella)
--   HEREDADO    no tiene fila propia: manda la fila de la carpeta MÁS CERCANA
--               que tenga `hereda` (padre antes que abuela, etc.)
--   DENEGADO    la fila que manda (directa o la heredada más cercana) es `denegar`
--   PUBLICO     sin filas, pero el archivo (o un ancestro) es público: ver + ejecutar
--   NINGUNO     nada
-- Como en Windows: la regla más específica gana. Una fila en el archivo
-- sobrescribe por completo lo que venga de sus carpetas (para quitar o para
-- dar); una carpeta cercana sobrescribe a una lejana.
-- Sólo cuenta lo vivo (deleted_at IS NULL) y lo vigente (vigente_hasta).
-- p_en_papelera = true: el archivo puede estar en la papelera (para saber si se
-- puede restaurar); por defecto sólo cuenta lo vivo.
CREATE OR REPLACE FUNCTION seguridad.fn_permiso_archivo(p_user_id bigint, p_archivo_id bigint, p_en_papelera boolean DEFAULT false)
RETURNS TABLE (
    ver boolean, ejecutar boolean, descargar boolean, crear boolean,
    editar boolean, eliminar boolean, administrar boolean, restaurar boolean, origen text
)
LANGUAGE plpgsql STABLE
AS $function$
DECLARE
    v_tipo        integer;
    v_propietario bigint;
    v_publico     boolean;
    r             record;
BEGIN
    SELECT u.type_user INTO v_tipo FROM seguridad.users u WHERE u.id = p_user_id;
    IF v_tipo IN (1, 2) THEN
        RETURN QUERY SELECT true, true, true, true, true, true, true, true, 'ADMIN'::text;
        RETURN;
    END IF;

    SELECT a.propietario_id INTO v_propietario FROM core.archivos a
     WHERE a.id = p_archivo_id AND (p_en_papelera OR a.deleted_at IS NULL);
    IF NOT FOUND THEN
        RETURN QUERY SELECT false, false, false, false, false, false, false, false, 'NINGUNO'::text;
        RETURN;
    END IF;
    IF v_propietario = p_user_id THEN
        RETURN QUERY SELECT true, true, true, true, true, true, true, true, 'PROPIETARIO'::text;
        RETURN;
    END IF;

    -- El archivo y todos sus ancestros (profundidad 0 = él mismo); se toma
    -- la fila vigente del usuario más cercana
    WITH RECURSIVE cadena AS (
        SELECT a.id, a.padre, a.publico, 0 AS prof FROM core.archivos a WHERE a.id = p_archivo_id
        UNION ALL
        SELECT a.id, a.padre, a.publico, c.prof + 1 FROM core.archivos a JOIN cadena c ON a.id = c.padre
    )
    SELECT p.ver, p.ejecutar, p.descargar, p.crear, p.editar, p.eliminar, p.administrar, p.restaurar, p.denegar, c.prof
    INTO r
    FROM cadena c
    JOIN seguridad.permisos_archivos p
      ON p.archivo_id = c.id
     AND p.user_id = p_user_id
     AND (c.prof = 0 OR p.hereda)                                     -- los de ancestros sólo si heredan
     AND (p.vigente_hasta IS NULL OR p.vigente_hasta > now())
    ORDER BY c.prof
    LIMIT 1;

    IF FOUND THEN
        IF r.denegar THEN
            RETURN QUERY SELECT false, false, false, false, false, false, false, false, 'DENEGADO'::text;
        ELSE
            RETURN QUERY SELECT r.ver, r.ejecutar, r.descargar, r.crear, r.editar, r.eliminar, r.administrar, r.restaurar,
                                CASE WHEN r.prof = 0 THEN 'DIRECTO' ELSE 'HEREDADO' END::text;
        END IF;
        RETURN;
    END IF;

    -- Sin filas: público si él o algún ancestro lo es
    WITH RECURSIVE cadena AS (
        SELECT a.id, a.padre, a.publico FROM core.archivos a WHERE a.id = p_archivo_id
        UNION ALL
        SELECT a.id, a.padre, a.publico FROM core.archivos a JOIN cadena c ON a.id = c.padre
    )
    SELECT bool_or(c.publico) INTO v_publico FROM cadena c;

    IF COALESCE(v_publico, false) THEN
        RETURN QUERY SELECT true, true, false, false, false, false, false, false, 'PUBLICO'::text;
        RETURN;
    END IF;

    RETURN QUERY SELECT false, false, false, false, false, false, false, false, 'NINGUNO'::text;
END;
$function$;

COMMENT ON FUNCTION seguridad.fn_permiso_archivo(bigint, bigint, boolean) IS 'Permiso efectivo de un usuario sobre un archivo/carpeta (admin, propietario, denegar, propio+heredado, público)';

-- Ids de los archivos vivos que un usuario puede VER (para armar su árbol)
CREATE OR REPLACE FUNCTION seguridad.fn_archivos_visibles(p_user_id bigint)
RETURNS TABLE (archivo_id bigint)
LANGUAGE sql STABLE
AS $function$
    SELECT a.id
    FROM core.archivos a
    WHERE a.deleted_at IS NULL
      AND (SELECT p.ver FROM seguridad.fn_permiso_archivo(p_user_id, a.id) p);
$function$;

COMMENT ON FUNCTION seguridad.fn_archivos_visibles(bigint) IS 'Ids de core.archivos que el usuario puede ver (permiso efectivo ver = true)';

-- ---------- 5. core.archivos.deleted_by: quién envió el registro a la papelera ----------
-- Lo graba el back al eliminar (login del usuario), y se limpia al restaurar.
ALTER TABLE core.archivos ADD COLUMN IF NOT EXISTS deleted_by character varying(100) COLLATE pg_catalog."default";
COMMENT ON COLUMN core.archivos.deleted_by IS 'Usuario (login) que envió el registro a la papelera; NULL si está vivo';
