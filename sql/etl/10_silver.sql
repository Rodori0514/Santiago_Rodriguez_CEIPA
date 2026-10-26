-- Capa plata: datos tipados, normalizados y homologados. Cada tabla conserva su origen (_src_file, _src_line).
-- Lee de las vistas `landing.*` (sql/00_landing_views.sql) y de las tablas de homologación en `seeds/`.

CREATE SCHEMA IF NOT EXISTS silver;

-- Funciones únicas de normalización: la misma regla para las tres fuentes (gobierno, sección 3.4).
CREATE OR REPLACE MACRO silver.doc_norm(x) AS
    nullif(ltrim(regexp_replace(
        split_part(regexp_replace(upper(trim(x)), '^(CC|CE|TI|PPT|NIT)\s*', ''), '-', 1),
        '[^0-9]', '', 'g'), '0'), '');

CREATE OR REPLACE MACRO silver.tipo_tercero(doc) AS
    CASE WHEN doc IS NULL OR doc = '999999999' THEN 'NO IDENTIFICADO'
         WHEN regexp_matches(doc, '^[89][0-9]{8}$') THEN 'EMPRESA'
         ELSE 'PERSONA' END;

CREATE OR REPLACE MACRO silver.celular_norm(x) AS
    nullif(right(regexp_replace(coalesce(x, ''), '[^0-9]', '', 'g'), 10), '');

CREATE OR REPLACE MACRO silver.texto_norm(x) AS
    nullif(upper(strip_accents(trim(regexp_replace(x, '\s+', ' ', 'g')))), '');

CREATE OR REPLACE MACRO silver.monto_co(x) AS
    TRY_CAST(replace(replace(trim(x), '.', ''), ',', '.') AS DECIMAL(18, 2));

CREATE OR REPLACE MACRO silver.periodo_en_texto(x) AS
    nullif(regexp_replace(regexp_extract(x, '(20[0-9]{2})-?([12])\b', 0), '^(\d{4})-?(\d)$', '\1-\2'), '');

-- Homologaciones versionadas en el repositorio
CREATE OR REPLACE TABLE silver.programa AS
SELECT * FROM read_csv('seeds/programa_institucional.csv', header = true, all_varchar = true);

CREATE OR REPLACE TABLE silver.programa_equivalencia AS
SELECT * FROM read_csv('seeds/programa_equivalencia.csv', header = true, all_varchar = true);

CREATE OR REPLACE TABLE silver.concepto_equivalencia AS
SELECT * FROM read_csv('seeds/concepto_equivalencia.csv', header = true, all_varchar = true);

CREATE OR REPLACE TABLE silver.etapa_equivalencia AS
SELECT * EXCLUDE (orden), orden::INTEGER AS orden
FROM read_csv('seeds/etapa_equivalencia.csv', header = true, all_varchar = true);

-- ============================================================================ SIAC

CREATE OR REPLACE TABLE silver.siac_periodo AS
SELECT cod_per,
       des_per,
       TRY_CAST(fec_ini AS TIMESTAMP)::DATE AS fec_ini,
       TRY_CAST(fec_fin AS TIMESTAMP)::DATE AS fec_fin,
       ind_vigente = 'S' AS vigente,
       _src_file, _src_line
FROM landing.siac_per_acad;

CREATE OR REPLACE TABLE silver.siac_persona AS
WITH base AS (
    SELECT p.*,
           TRY_STRPTIME(fec_nac, '%d/%m/%Y')::DATE AS nac_ddmm,
           TRY_STRPTIME(fec_nac, '%m/%d/%Y')::DATE AS nac_mmdd
    FROM landing.siac_pers p
)
SELECT TRY_CAST(id_pers AS BIGINT) AS id_pers,
       tip_doc,
       num_doc AS num_doc_origen,
       silver.doc_norm(num_doc) AS doc_norm,
       trim(concat_ws(' ', pri_nom, seg_nom)) AS nombres,
       trim(concat_ws(' ', pri_ape, seg_ape)) AS apellidos,
       silver.texto_norm(pri_ape) AS primer_apellido_norm,
       coalesce(nac_ddmm, nac_mmdd) AS fec_nac,
       CASE WHEN fec_nac IS NULL THEN 'sin dato'
            WHEN nac_ddmm IS NULL AND nac_mmdd IS NOT NULL THEN 'MM/DD corregida'
            WHEN nac_ddmm IS NULL THEN 'no interpretable'
            WHEN day(nac_ddmm) <= 12 THEN 'ambigua'
            ELSE 'ok' END AS calidad_fec_nac,
       sexo,
       nullif(lower(trim(email)), '') AS email_norm,
       silver.celular_norm(tel_cel) AS celular_norm,
       silver.texto_norm(municipio) AS municipio_norm,
       TRY_CAST(fec_reg AS TIMESTAMP) AS fec_reg,
       usu_reg,
       ind_anul = 'S' AS anulada,
       _src_file, _src_line
FROM base;

CREATE OR REPLACE TABLE silver.siac_estudiante AS
SELECT e.cod_est,
       TRY_CAST(e.id_pers AS BIGINT) AS id_pers,
       e.cod_prog,
       pe.programa_id,
       e.cod_per_ing,
       e.est_estado,
       TRY_CAST(e.fec_estado AS TIMESTAMP) AS fec_estado,
       TRY_CAST(e.fec_grado AS TIMESTAMP)::DATE AS fec_grado,
       e.ind_anul = 'S' AS anulado,
       e._src_file, e._src_line
FROM landing.siac_est e
LEFT JOIN silver.programa_equivalencia pe ON pe.sistema = 'SIAC' AND pe.codigo_origen = e.cod_prog;

CREATE OR REPLACE TABLE silver.siac_matricula AS
WITH matriculas AS (
    SELECT TRY_CAST(m.id_matr AS BIGINT) AS id_matr,
           m.cod_est, m.cod_per, m.cod_prog,
           TRY_CAST(m.num_sem AS INTEGER) AS num_sem,
           TRY_CAST(m.fec_matr AS TIMESTAMP) AS fec_matr,
           m.tip_matr, m.est_matr, m.usu_reg,
           m.ind_anul = 'S' AS anulada,
           m._src_file, m._src_line
    FROM landing.siac_matr m
)
SELECT m.*,
       e.id_pers,
       p.doc_norm,
       pe.programa_id,
       (m.est_matr = 'M' AND NOT m.anulada AND NOT e.anulado) AS es_valida
FROM matriculas m
JOIN silver.siac_estudiante e USING (cod_est)
JOIN silver.siac_persona p USING (id_pers)
LEFT JOIN silver.programa_equivalencia pe ON pe.sistema = 'SIAC' AND pe.codigo_origen = m.cod_prog;

CREATE OR REPLACE TABLE silver.siac_calificacion AS
WITH notas AS (
    SELECT TRY_CAST(id_calif AS BIGINT) AS id_calif,
           TRY_CAST(id_matr AS BIGINT) AS id_matr,
           cod_asig,
           TRY_CAST(nota_c1 AS DECIMAL(4, 2)) AS nota_c1,
           TRY_CAST(nota_c2 AS DECIMAL(4, 2)) AS nota_c2,
           TRY_CAST(nota_c3 AS DECIMAL(4, 2)) AS nota_c3,
           TRY_CAST(nota_def AS DECIMAL(4, 2)) AS nota_def,
           TRY_CAST(fec_reg AS TIMESTAMP) AS fec_reg,
           usu_reg,
           ind_anul = 'S' AS anulada,
           _src_file, _src_line
    FROM landing.siac_calif
)
SELECT *,
       round(0.3 * nota_c1 + 0.3 * nota_c2 + 0.4 * nota_c3, 1) AS nota_def_calculada,
       nota_def IS NULL AS en_curso,
       coalesce(nota_def NOT BETWEEN 0 AND 5
        OR nota_c1 NOT BETWEEN 0 AND 5 OR nota_c2 NOT BETWEEN 0 AND 5 OR nota_c3 NOT BETWEEN 0 AND 5, false) AS fuera_de_rango
FROM notas;

-- ======================================================================= ContaPlus

CREATE OR REPLACE TABLE silver.cp_archivo AS
WITH detalle AS (
    SELECT _src_file AS archivo, COUNT(*) AS filas, SUM(silver.monto_co(valor)) AS suma_detalle
    FROM landing.cp_recaudos GROUP BY ALL
)
SELECT a.archivo,
       a.version_contaplus,
       TRY_STRPTIME(a.fecha_impresion, '%d/%m/%Y %H:%M:%S') AS fecha_impresion,
       d.filas,
       TRY_CAST(a.pie_total_registros AS INTEGER) AS pie_registros,
       d.suma_detalle,
       silver.monto_co(a.pie_total_valor) AS pie_valor,
       d.filas = TRY_CAST(a.pie_total_registros AS INTEGER)
           AND d.suma_detalle = silver.monto_co(a.pie_total_valor) AS cuadra
FROM landing.cp_archivos a
JOIN detalle d USING (archivo);

CREATE OR REPLACE TABLE silver.cp_recaudo AS
WITH filas AS (
    SELECT r.*,
           a.version_contaplus,
           row_number() OVER (PARTITION BY r.comprobante ORDER BY r._src_file, r._src_line) AS copia,
           COUNT(*) OVER (PARTITION BY r.comprobante) AS copias
    FROM landing.cp_recaudos r
    JOIN landing.cp_archivos a ON a.archivo = r._src_file
),
tipadas AS (
    SELECT comprobante,
           TRY_STRPTIME(fecha, '%d/%m/%Y')::DATE AS fecha,
           silver.doc_norm(nit_tercero) AS doc_norm,
           silver.tipo_tercero(silver.doc_norm(nit_tercero)) AS tipo_tercero,
           nit_tercero AS nit_origen,
           nombre_tercero,
           silver.texto_norm(split_part(nombre_tercero, ' ', 1)) AS primer_apellido_norm,
           concepto AS concepto_origen,
           version_contaplus,
           nullif(trim(centro_costo), '') AS centro_costo,
           detalle,
           silver.texto_norm(detalle) AS detalle_norm,
           silver.periodo_en_texto(detalle) AS periodo,
           silver.monto_co(valor) AS valor,
           forma_pago,
           _periodo_archivo AS mes_archivo,
           copias,
           _src_file, _src_line
    FROM filas
    WHERE copia = 1
)
SELECT t.*,
       ce.codigo AS concepto,
       ce.grupo AS grupo_concepto,
       coalesce(
           pe.programa_id,
           CASE WHEN ce.grupo NOT IN ('Matrícula', 'Extensión') THEN NULL
                WHEN t.detalle_norm LIKE '%DIPLOMADO%' THEN 'DAD'
                WHEN t.detalle_norm LIKE '%GERENCIA DE PROYECTOS%' OR t.detalle_norm LIKE '%ESPECIALIZACION%' THEN 'EGP'
                WHEN t.detalle_norm LIKE '%ADMIN%' OR t.detalle_norm LIKE '%ADMON%' THEN 'ADM'
                WHEN t.detalle_norm LIKE '%CONTADUR%' THEN 'CON'
                WHEN t.detalle_norm LIKE '%NEG%INT%' THEN 'NEG'
                WHEN t.detalle_norm LIKE '%MERCADEO%' THEN 'MER'
                WHEN t.detalle_norm LIKE '%INGENIERIA%' OR t.detalle_norm LIKE '%INDUSTRIAL%' THEN 'ING'
           END,
           (SELECT any_value(m.programa_id) FROM silver.siac_matricula m
            WHERE m.es_valida AND m.doc_norm = t.doc_norm AND m.cod_per = t.periodo AND ce.grupo = 'Matrícula')
       ) AS programa_id,
       CASE WHEN pe.programa_id IS NOT NULL THEN 'centro de costo'
            WHEN ce.grupo IN ('Matrícula', 'Extensión') AND t.periodo IS NOT NULL THEN 'detalle o matrícula SIAC'
            ELSE NULL END AS origen_programa,
       t.valor < 0 AS es_devolucion,
       t.detalle_norm LIKE 'CONVENIO EMPRESARIAL%' AS es_convenio,
       TRY_CAST(regexp_extract(t.detalle_norm, '\((\d+) ESTUDIANTES?\)', 1) AS INTEGER) AS estudiantes_convenio
FROM tipadas t
LEFT JOIN silver.concepto_equivalencia ce ON ce.codigo_origen = t.concepto_origen
LEFT JOIN silver.programa_equivalencia pe ON pe.sistema = 'CONTAPLUS' AND pe.codigo_origen = t.centro_costo;

CREATE OR REPLACE TABLE silver.cp_cartera AS
SELECT silver.doc_norm(c.nit_tercero) AS doc_norm,
       c.nombre_tercero,
       ce.codigo AS concepto,
       nullif(trim(c.centro_costo), '') AS centro_costo,
       pe.programa_id,
       c.periodo,
       TRY_STRPTIME(c.fecha_vencimiento, '%d/%m/%Y')::DATE AS fecha_vencimiento,
       silver.monto_co(c.valor_facturado) AS valor_facturado,
       silver.monto_co(c.valor_abonado) AS valor_abonado,
       silver.monto_co(c.saldo) AS saldo,
       TRY_CAST(c.dias_mora AS INTEGER) AS dias_mora,
       c.acuerdo_pago = 'S' AS acuerdo_pago,
       a.fecha_corte,
       c._src_file, c._src_line
FROM landing.cp_cartera c
LEFT JOIN landing.cp_archivos a ON a.archivo = c._src_file
LEFT JOIN silver.concepto_equivalencia ce ON ce.codigo_origen = c.concepto
LEFT JOIN silver.programa_equivalencia pe ON pe.sistema = 'CONTAPLUS' AND pe.codigo_origen = c.centro_costo;

-- ===================================================================== VentasCloud

CREATE OR REPLACE TABLE silver.crm_contacto AS
SELECT contactId AS contact_id,
       firstName AS nombres,
       lastName AS apellidos,
       silver.texto_norm(split_part(trim(lastName), ' ', 1)) AS primer_apellido_norm,
       documentType AS tipo_doc,
       silver.doc_norm(documentNumber) AS doc_norm,
       nullif(lower(trim(email)), '') AS email_norm,
       silver.celular_norm(mobile) AS celular_norm,
       silver.texto_norm(city) AS ciudad_norm,
       programInterest AS programa_interes_texto,
       leadSource AS canal,
       ownerName AS asesor,
       consentDataProcessing AS autoriza_datos,
       TRY_CAST(replace(createdAt, 'Z', '') AS TIMESTAMP) AS creado,
       TRY_CAST(replace(updatedAt, 'Z', '') AS TIMESTAMP) AS actualizado,
       TRY_CAST(replace(_extracted_at, 'Z', '') AS TIMESTAMP) AS extraido
FROM landing.crm_contacts;

CREATE OR REPLACE TABLE silver.crm_oportunidad AS
SELECT o.opportunityId AS oportunidad_id,
       o.contactId AS contact_id,
       o.programId AS program_id_crm,
       pe.programa_id,
       pe.modalidad,
       o.intakePeriod AS periodo,
       o.stage AS etapa_origen,
       ee.idioma AS idioma_etapa,
       ee.etapa,
       ee.estado,
       o.amount AS monto_digitado,
       o.ownerName AS asesor,
       o.lostReason AS motivo_perdida,
       TRY_CAST(replace(o.createdAt, 'Z', '') AS TIMESTAMP) AS creada,
       TRY_CAST(replace(o.updatedAt, 'Z', '') AS TIMESTAMP) AS actualizada,
       TRY_CAST(replace(o.closedAt, 'Z', '') AS TIMESTAMP) AS cerrada,
       TRY_CAST(replace(o._extracted_at, 'Z', '') AS TIMESTAMP) AS extraida
FROM landing.crm_opportunities o
LEFT JOIN silver.etapa_equivalencia ee ON ee.etapa_origen = o.stage
LEFT JOIN silver.programa_equivalencia pe ON pe.sistema = 'CRM' AND pe.codigo_origen = o.programId;

-- ============================================================ Identidad de personas
-- Nivel 1: documento normalizado. Niveles 2 y 3 (solo registros sin documento): correo o celular igual a un
-- registro con documento y mismo primer apellido, cuando el candidato es único. Si no hay cruce, la persona
-- queda identificada solo por su registro de origen.

CREATE OR REPLACE TABLE silver.persona_xref AS
WITH registros AS (
    SELECT 'SIAC' AS sistema, id_pers::VARCHAR AS id_origen, doc_norm, email_norm, celular_norm, primer_apellido_norm
    FROM silver.siac_persona WHERE NOT anulada
    UNION ALL
    SELECT 'CRM', contact_id, doc_norm, email_norm, celular_norm, primer_apellido_norm
    FROM silver.crm_contacto
    UNION ALL
    SELECT DISTINCT 'CONTAPLUS', doc_norm, doc_norm, NULL, NULL, NULL
    FROM silver.cp_recaudo WHERE tipo_tercero = 'PERSONA'
),
clasificados AS (
    SELECT *, doc_norm IS NOT NULL AND silver.tipo_tercero(doc_norm) = 'PERSONA' AND length(doc_norm) >= 5 AS doc_valido
    FROM registros
),
con_documento AS (
    SELECT * FROM clasificados WHERE doc_valido
),
por_correo AS (
    SELECT s.sistema, s.id_origen, any_value(d.doc_norm) AS doc_norm
    FROM clasificados s
    JOIN con_documento d ON d.email_norm = s.email_norm AND d.primer_apellido_norm = s.primer_apellido_norm
    WHERE NOT s.doc_valido AND s.email_norm IS NOT NULL
    GROUP BY ALL HAVING COUNT(DISTINCT d.doc_norm) = 1
),
por_celular AS (
    SELECT s.sistema, s.id_origen, any_value(d.doc_norm) AS doc_norm
    FROM clasificados s
    JOIN con_documento d ON d.celular_norm = s.celular_norm AND d.primer_apellido_norm = s.primer_apellido_norm
    WHERE NOT s.doc_valido AND s.celular_norm IS NOT NULL
    GROUP BY ALL HAVING COUNT(DISTINCT d.doc_norm) = 1
)
SELECT c.sistema,
       c.id_origen,
       c.doc_norm AS doc_norm_origen,
       CASE WHEN c.doc_valido THEN c.doc_norm
            WHEN pc.doc_norm IS NOT NULL THEN pc.doc_norm
            WHEN pl.doc_norm IS NOT NULL THEN pl.doc_norm
            ELSE c.sistema || ':' || c.id_origen END AS persona_key,
       CASE WHEN c.doc_valido THEN 'documento'
            WHEN pc.doc_norm IS NOT NULL THEN 'correo + apellido'
            WHEN pl.doc_norm IS NOT NULL THEN 'celular + apellido'
            ELSE 'sin cruce' END AS regla_cruce
FROM clasificados c
LEFT JOIN por_correo pc USING (sistema, id_origen)
LEFT JOIN por_celular pl USING (sistema, id_origen);
