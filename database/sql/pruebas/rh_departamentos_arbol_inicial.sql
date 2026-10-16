-- ============================================================================
-- ORGANIGRAMA DE ARRANQUE PARA RRHH  —  DATOS DE EJEMPLO
-- ============================================================================
-- Fecha: 2026-10-16
--
-- ESTO NO ES UNA MIGRACIÓN. Está en database/sql/pruebas/ a propósito: es un
-- organigrama inventado para abrir la pantalla del árbol de departamentos y
-- verla con datos de verdad —plegar ramas, arrastrar, filtrar, la papelera—.
-- En la base de producción no se corre.
--
-- ES EL ORGANIGRAMA TÍPICO de una cadena de electrodomésticos y tecnología,
-- el mismo giro que el catálogo de inventarios: comercial con tienda y
-- servicio técnico, logística con bodega e importaciones, administración con
-- crédito y cobranzas, talento humano, sistemas y marketing. Sirve de punto
-- de partida si se quiere conservar.
--
-- NO TOCA NADA DE LO QUE YA HAY. Todo cuelga de una raíz nueva, «Gerencia
-- General», y los códigos empiezan por GG/COM/OPL/ADF/TH/TI/MKT, así que los
-- departamentos que ya existían (Finanzas, Operaciones, Recursos Humanos…)
-- se quedan donde están. Si se quieren meter dentro del organigrama, se
-- arrastran desde la pantalla.
--
-- Se puede volver a correr: si ya está «Gerencia General», no hace nada.
--
-- Cuatro niveles (0 a 3), que es lo que admite el árbol:
--
--   Gerencia General
--     Comercial
--       Ventas Tienda
--         Mostrador y Exhibición
--         Caja y Facturación
--       Ventas Corporativas
--       Servicio Técnico
--         Garantías
--         Reparaciones
--     Operaciones y Logística
--       Bodega Central · Despachos y Transporte · Compras e Importaciones
--     Administración y Finanzas
--       Contabilidad · Tesorería y Cobranzas · Crédito
--     Talento Humano
--       Selección y Contratación · Nómina · Seguridad y Salud Ocupacional
--     Tecnología de la Información
--       Infraestructura y Soporte · Desarrollo de Software
--     Marketing
--       Marketing Digital · Diseño y Publicidad
--
-- PARA DESHACERLO, al final del fichero está el DELETE comentado.
-- ============================================================================

DO $$
DECLARE
    -- Quien firma los movimientos. 4 es el usuario de sistemas; cámbielo si
    -- se corre con otro.
    c_usuario constant bigint  := 4;
    c_login   constant varchar := 'CARGA';
    c_nombre  constant varchar := 'Carga inicial';

    -- Los responsables salen de los empleados activos que haya; si no hay,
    -- los departamentos se quedan sin responsable y no pasa nada.
    v_jefe1 bigint;
    v_jefe2 bigint;
    v_jefe3 bigint;

    r jsonb;
    v_gg  bigint; v_com bigint; v_opl bigint; v_adf bigint;
    v_th  bigint; v_ti  bigint; v_mkt bigint;
    v_tda bigint; v_sat bigint;
BEGIN
    IF EXISTS (SELECT 1 FROM rh.departamentos WHERE codigo = 'GG') THEN
        RAISE NOTICE 'El organigrama de ejemplo ya está cargado: no se hace nada.';
        RETURN;
    END IF;

    SELECT id INTO v_jefe1 FROM rh.empleados WHERE activo ORDER BY id LIMIT 1;
    SELECT id INTO v_jefe2 FROM rh.empleados WHERE activo ORDER BY id OFFSET 1 LIMIT 1;
    SELECT id INTO v_jefe3 FROM rh.empleados WHERE activo ORDER BY id OFFSET 2 LIMIT 1;

    -- =====================================================================
    -- NIVEL 0
    -- =====================================================================
    r := rh.fn_departamentos_crear('Gerencia General', 'GG',
         'Dirección de la empresa: de ella cuelgan todas las áreas',
         v_jefe2, true, NULL, c_usuario, c_login, c_nombre, NULL, 'carga', NULL);
    v_gg := (r->'data'->>'id')::bigint;

    -- =====================================================================
    -- NIVEL 1 — las áreas
    -- =====================================================================
    r := rh.fn_departamentos_crear('Comercial', 'COM',
         'Ventas en tienda, ventas a empresas y servicio técnico',
         v_jefe1, true, v_gg, c_usuario, c_login, c_nombre, NULL, 'carga', NULL);
    v_com := (r->'data'->>'id')::bigint;

    r := rh.fn_departamentos_crear('Operaciones y Logística', 'OPL',
         'Bodega, despachos e importaciones',
         NULL, true, v_gg, c_usuario, c_login, c_nombre, NULL, 'carga', NULL);
    v_opl := (r->'data'->>'id')::bigint;

    r := rh.fn_departamentos_crear('Administración y Finanzas', 'ADF',
         'Contabilidad, tesorería y el crédito de los clientes',
         NULL, true, v_gg, c_usuario, c_login, c_nombre, NULL, 'carga', NULL);
    v_adf := (r->'data'->>'id')::bigint;

    r := rh.fn_departamentos_crear('Talento Humano', 'TH',
         'Selección, nómina y seguridad ocupacional',
         NULL, true, v_gg, c_usuario, c_login, c_nombre, NULL, 'carga', NULL);
    v_th := (r->'data'->>'id')::bigint;

    r := rh.fn_departamentos_crear('Tecnología de la Información', 'TI',
         'Infraestructura, soporte y desarrollo',
         NULL, true, v_gg, c_usuario, c_login, c_nombre, NULL, 'carga', NULL);
    v_ti := (r->'data'->>'id')::bigint;

    r := rh.fn_departamentos_crear('Marketing', 'MKT',
         'Publicidad, redes y campañas de temporada',
         NULL, true, v_gg, c_usuario, c_login, c_nombre, NULL, 'carga', NULL);
    v_mkt := (r->'data'->>'id')::bigint;

    -- =====================================================================
    -- NIVEL 2 — COMERCIAL
    -- =====================================================================
    r := rh.fn_departamentos_crear('Ventas Tienda', 'COM-TDA',
         'Piso de ventas: asesores, mostrador y caja',
         NULL, true, v_com, c_usuario, c_login, c_nombre, NULL, 'carga', NULL);
    v_tda := (r->'data'->>'id')::bigint;

    PERFORM rh.fn_departamentos_crear('Ventas Corporativas', 'COM-CORP',
            'Ventas a empresas e instituciones, con crédito y factura',
            NULL, true, v_com, c_usuario, c_login, c_nombre, NULL, 'carga', NULL);

    r := rh.fn_departamentos_crear('Servicio Técnico', 'COM-SAT',
         'Garantías, reparaciones e instalaciones a domicilio',
         v_jefe3, true, v_com, c_usuario, c_login, c_nombre, NULL, 'carga', NULL);
    v_sat := (r->'data'->>'id')::bigint;

    -- --------- NIVEL 3 — lo más hondo que admite el árbol ---------
    PERFORM rh.fn_departamentos_crear('Mostrador y Exhibición', 'COM-TDA-MOS',
            'Atención en sala y cuidado de la exhibición',
            NULL, true, v_tda, c_usuario, c_login, c_nombre, NULL, 'carga', NULL);

    PERFORM rh.fn_departamentos_crear('Caja y Facturación', 'COM-TDA-CAJ',
            'Cobro, facturación electrónica y cierre de caja',
            NULL, true, v_tda, c_usuario, c_login, c_nombre, NULL, 'carga', NULL);

    PERFORM rh.fn_departamentos_crear('Garantías', 'COM-SAT-GAR',
            'Trámite de garantías con marcas y proveedores',
            NULL, true, v_sat, c_usuario, c_login, c_nombre, NULL, 'carga', NULL);

    PERFORM rh.fn_departamentos_crear('Reparaciones', 'COM-SAT-REP',
            'Taller: línea blanca, audio y computadoras',
            NULL, true, v_sat, c_usuario, c_login, c_nombre, NULL, 'carga', NULL);

    -- =====================================================================
    -- NIVEL 2 — OPERACIONES Y LOGÍSTICA
    -- =====================================================================
    PERFORM rh.fn_departamentos_crear('Bodega Central', 'OPL-BOD',
            'Recepción, almacenamiento e inventarios',
            NULL, true, v_opl, c_usuario, c_login, c_nombre, NULL, 'carga', NULL);

    PERFORM rh.fn_departamentos_crear('Despachos y Transporte', 'OPL-DES',
            'Entregas a domicilio y rutas de reparto',
            NULL, true, v_opl, c_usuario, c_login, c_nombre, NULL, 'carga', NULL);

    PERFORM rh.fn_departamentos_crear('Compras e Importaciones', 'OPL-COM',
            'Compra a proveedores locales e importación directa',
            NULL, true, v_opl, c_usuario, c_login, c_nombre, NULL, 'carga', NULL);

    -- =====================================================================
    -- NIVEL 2 — ADMINISTRACIÓN Y FINANZAS
    -- =====================================================================
    PERFORM rh.fn_departamentos_crear('Contabilidad', 'ADF-CTB',
            'Libros, impuestos y conciliaciones',
            NULL, true, v_adf, c_usuario, c_login, c_nombre, NULL, 'carga', NULL);

    PERFORM rh.fn_departamentos_crear('Tesorería y Cobranzas', 'ADF-TES',
            'Pagos, bancos y recuperación de cartera',
            NULL, true, v_adf, c_usuario, c_login, c_nombre, NULL, 'carga', NULL);

    PERFORM rh.fn_departamentos_crear('Crédito', 'ADF-CRE',
            'Evaluación y calificación de clientes para la venta a crédito',
            NULL, true, v_adf, c_usuario, c_login, c_nombre, NULL, 'carga', NULL);

    -- =====================================================================
    -- NIVEL 2 — TALENTO HUMANO
    -- =====================================================================
    PERFORM rh.fn_departamentos_crear('Selección y Contratación', 'TH-SEL',
            'Vacantes, entrevistas y contratos',
            NULL, true, v_th, c_usuario, c_login, c_nombre, NULL, 'carga', NULL);

    PERFORM rh.fn_departamentos_crear('Nómina', 'TH-NOM',
            'Roles de pago, beneficios y liquidaciones',
            NULL, true, v_th, c_usuario, c_login, c_nombre, NULL, 'carga', NULL);

    PERFORM rh.fn_departamentos_crear('Seguridad y Salud Ocupacional', 'TH-SSO',
            'Prevención de riesgos y salud en el trabajo',
            NULL, true, v_th, c_usuario, c_login, c_nombre, NULL, 'carga', NULL);

    -- =====================================================================
    -- NIVEL 2 — TECNOLOGÍA DE LA INFORMACIÓN
    -- =====================================================================
    PERFORM rh.fn_departamentos_crear('Infraestructura y Soporte', 'TI-INF',
            'Redes, servidores y soporte a usuarios',
            NULL, true, v_ti, c_usuario, c_login, c_nombre, NULL, 'carga', NULL);

    PERFORM rh.fn_departamentos_crear('Desarrollo de Software', 'TI-DEV',
            'El CRM y las integraciones con facturación',
            NULL, true, v_ti, c_usuario, c_login, c_nombre, NULL, 'carga', NULL);

    -- =====================================================================
    -- NIVEL 2 — MARKETING
    -- =====================================================================
    PERFORM rh.fn_departamentos_crear('Marketing Digital', 'MKT-DIG',
            'Redes sociales, pauta y tienda en línea',
            NULL, true, v_mkt, c_usuario, c_login, c_nombre, NULL, 'carga', NULL);

    -- Éste se queda INACTIVO a propósito: así se ve en la rejilla cómo salen
    -- los departamentos apagados (en gris y tachados) sin tener que apagar
    -- uno de verdad.
    PERFORM rh.fn_departamentos_crear('Diseño y Publicidad', 'MKT-PUB',
            'Artes, catálogos y material de punto de venta',
            NULL, false, v_mkt, c_usuario, c_login, c_nombre, NULL, 'carga', NULL);

    RAISE NOTICE 'Organigrama de ejemplo cargado: % departamentos nuevos',
                 (SELECT COUNT(*) FROM rh.departamentos WHERE codigo LIKE 'GG'
                     OR codigo LIKE 'COM%' OR codigo LIKE 'OPL%' OR codigo LIKE 'ADF%'
                     OR codigo LIKE 'TH%' OR codigo LIKE 'TI%' OR codigo LIKE 'MKT%');
END $$;


-- ---------------------------------------------------------------------------
-- CÓMO QUEDÓ
-- ---------------------------------------------------------------------------
SELECT repeat('    ', nivel) || nombre AS organigrama,
       codigo,
       nivel,
       (SELECT COUNT(*) FROM rh.departamentos h WHERE h.padre_id = d.id AND h.deleted_at IS NULL) AS subdepartamentos,
       CASE WHEN activo THEN 'activo' ELSE 'inactivo' END AS estado
  FROM rh.departamentos d
 WHERE d.deleted_at IS NULL
   AND (d.codigo = 'GG' OR d.codigo LIKE 'COM%' OR d.codigo LIKE 'OPL%'
     OR d.codigo LIKE 'ADF%' OR d.codigo LIKE 'TH%' OR d.codigo LIKE 'TI%'
     OR d.codigo LIKE 'MKT%')
 ORDER BY (SELECT string_agg(LPAD(x.orden::text, 5, '0'), '.' ORDER BY x.nivel)
             FROM (WITH RECURSIVE subida AS (
                       SELECT d2.id, d2.padre_id, d2.orden, d2.nivel FROM rh.departamentos d2 WHERE d2.id = d.id
                       UNION ALL
                       SELECT p.id, p.padre_id, p.orden, p.nivel FROM rh.departamentos p JOIN subida s ON p.id = s.padre_id)
                   SELECT * FROM subida) x);


-- ---------------------------------------------------------------------------
-- PARA DESHACERLO (descomentar y correr)
-- ---------------------------------------------------------------------------
-- De lo más hondo a lo más alto, que es como lo deja pasar la clave ajena.
-- Si algún departamento tiene empleados asignados, primero hay que moverlos.
--
-- DELETE FROM rh.departamentos WHERE nivel = 3 AND (codigo LIKE 'COM-%');
-- DELETE FROM rh.departamentos WHERE nivel = 2 AND (codigo LIKE 'COM-%' OR codigo LIKE 'OPL-%'
--     OR codigo LIKE 'ADF-%' OR codigo LIKE 'TH%' OR codigo LIKE 'TI%' OR codigo LIKE 'MKT-%');
-- DELETE FROM rh.departamentos WHERE nivel = 1 AND codigo IN ('COM','OPL','ADF','TH','TI','MKT');
-- DELETE FROM rh.departamentos WHERE codigo = 'GG';
