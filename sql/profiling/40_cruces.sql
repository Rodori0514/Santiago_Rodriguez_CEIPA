-- Cruces entre fuentes: ¿se puede reconocer a la misma persona en SIAC, CRM y ContaPlus?
-- Llave candidata: número de documento normalizado (solo dígitos, sin ceros a la izquierda,
-- sin prefijo CC/CE/TI y sin el dígito de verificación que Financiero agrega a algunos NIT).

-- name: X01 | Universo de personas por fuente y solapamiento por documento
WITH siac AS (
    SELECT DISTINCT ltrim(regexp_replace(num_doc, '[^0-9]', '', 'g'), '0') AS doc
    FROM landing.siac_pers WHERE ind_anul = 'N'
),
crm AS (
    SELECT DISTINCT ltrim(regexp_replace(documentNumber, '[^0-9]', '', 'g'), '0') AS doc
    FROM landing.crm_contacts WHERE regexp_replace(coalesce(documentNumber, ''), '[^0-9]', '', 'g') <> ''
),
financiero AS (
    SELECT DISTINCT ltrim(regexp_replace(split_part(regexp_replace(upper(trim(nit_tercero)), '^(CC|CE|TI)\s*', ''), '-', 1), '[^0-9]', '', 'g'), '0') AS doc
    FROM landing.cp_recaudos
),
financiero_personas AS (
    SELECT doc FROM financiero
    WHERE doc <> '' AND doc NOT LIKE '999999999%' AND NOT regexp_matches(doc, '^[89][0-9]{8}$')
),
todas AS (
    SELECT doc, 'SIAC' AS fuente FROM siac
    UNION ALL SELECT doc, 'CRM' FROM crm
    UNION ALL SELECT doc, 'FIN' FROM financiero_personas
),
presencia AS (
    SELECT doc, string_agg(fuente, '+' ORDER BY fuente) AS fuentes FROM todas GROUP BY doc
)
SELECT fuentes, COUNT(*) AS personas FROM presencia GROUP BY fuentes ORDER BY personas DESC;

-- name: X02 | Documento coincide pero el nombre no: ¿misma persona o colisión de llave?
WITH siac AS (
    SELECT ltrim(regexp_replace(num_doc, '[^0-9]', '', 'g'), '0') AS doc,
           upper(strip_accents(pri_ape)) AS apellido, upper(strip_accents(pri_nom)) AS nombre
    FROM landing.siac_pers WHERE ind_anul = 'N'
),
crm AS (
    SELECT ltrim(regexp_replace(documentNumber, '[^0-9]', '', 'g'), '0') AS doc,
           upper(strip_accents(split_part(trim(lastName), ' ', 1))) AS apellido,
           upper(strip_accents(split_part(trim(firstName), ' ', 1))) AS nombre
    FROM landing.crm_contacts WHERE documentNumber IS NOT NULL AND documentNumber <> ''
),
pareja AS (
    SELECT s.doc, s.nombre || ' ' || s.apellido AS siac, c.nombre || ' ' || c.apellido AS crm,
           s.apellido = c.apellido AS mismo_apellido, s.nombre = c.nombre AS mismo_nombre
    FROM siac s JOIN crm c USING (doc)
)
SELECT mismo_apellido, mismo_nombre, COUNT(*) AS parejas, list(siac || ' | ' || crm)[1:6] AS ejemplos
FROM pareja GROUP BY ALL ORDER BY ALL;

-- name: X03 | Estudiantes matriculados en SIAC: ¿están en el CRM? (por periodo de ingreso)
WITH primera_matricula AS (
    SELECT e.cod_est, e.cod_prog, e.cod_per_ing,
           ltrim(regexp_replace(p.num_doc, '[^0-9]', '', 'g'), '0') AS doc,
           lower(trim(p.email)) AS email
    FROM landing.siac_est e JOIN landing.siac_pers p USING (id_pers)
    WHERE e.ind_anul = 'N'
),
crm AS (
    SELECT contactId, ltrim(regexp_replace(documentNumber, '[^0-9]', '', 'g'), '0') AS doc, lower(trim(email)) AS email
    FROM landing.crm_contacts
)
SELECT cod_per_ing,
       COUNT(*) AS estudiantes_nuevos,
       COUNT(*) FILTER (WHERE EXISTS (SELECT 1 FROM crm c WHERE c.doc = m.doc AND c.doc <> '')) AS en_crm_por_documento,
       COUNT(*) FILTER (WHERE EXISTS (SELECT 1 FROM crm c WHERE c.doc = m.doc AND c.doc <> '')
                           OR EXISTS (SELECT 1 FROM crm c WHERE c.email = m.email)) AS en_crm_por_doc_o_correo
FROM primera_matricula m GROUP BY cod_per_ing ORDER BY cod_per_ing;

-- name: X04 | Oportunidades ganadas en el CRM vs matrícula real en SIAC del mismo periodo
WITH ganadas AS (
    SELECT o.opportunityId, o.intakePeriod, o.stage,
           ltrim(regexp_replace(c.documentNumber, '[^0-9]', '', 'g'), '0') AS doc
    FROM landing.crm_opportunities o JOIN landing.crm_contacts c USING (contactId)
    WHERE o.stage IN ('Ganada', 'Won', 'Closed Won', 'Matriculado')
),
matriculas_siac AS (
    SELECT DISTINCT ltrim(regexp_replace(p.num_doc, '[^0-9]', '', 'g'), '0') AS doc, m.cod_per
    FROM landing.siac_matr m
    JOIN landing.siac_est e USING (cod_est)
    JOIN landing.siac_pers p USING (id_pers)
    WHERE m.est_matr = 'M' AND m.ind_anul = 'N'
)
SELECT g.stage,
       COUNT(*) AS ganadas,
       COUNT(*) FILTER (WHERE g.doc IS NULL OR g.doc = '') AS sin_documento_para_cruzar,
       COUNT(*) FILTER (WHERE ms.doc IS NOT NULL) AS con_matricula_siac_en_el_periodo,
       COUNT(*) FILTER (WHERE g.doc <> '' AND ms.doc IS NULL) AS ganada_sin_matricula_siac
FROM ganadas g LEFT JOIN matriculas_siac ms ON ms.doc = g.doc AND ms.cod_per = g.intakePeriod
GROUP BY g.stage ORDER BY g.stage;

-- name: X05 | Matrículas válidas en SIAC vs pago de matrícula en ContaPlus (mismo periodo)
WITH matriculas AS (
    SELECT DISTINCT ltrim(regexp_replace(p.num_doc, '[^0-9]', '', 'g'), '0') AS doc, m.cod_per, e.cod_prog
    FROM landing.siac_matr m
    JOIN landing.siac_est e USING (cod_est)
    JOIN landing.siac_pers p USING (id_pers)
    WHERE m.est_matr = 'M' AND m.ind_anul = 'N' AND m.cod_per <> '2027-1'
),
pagos AS (
    SELECT DISTINCT ON (comprobante)
           ltrim(regexp_replace(split_part(regexp_replace(upper(trim(nit_tercero)), '^(CC|CE|TI)\s*', ''), '-', 1), '[^0-9]', '', 'g'), '0') AS doc,
           regexp_replace(regexp_extract(detalle, '(20[0-9]{2})-?([12])\b', 0), '^(\d{4})-?(\d)$', '\1-\2') AS periodo,
           TRY_CAST(replace(replace(valor, '.', ''), ',', '.') AS DECIMAL(18, 2)) AS valor
    FROM landing.cp_recaudos WHERE concepto IN ('MAT', '1105')
),
pagado AS (
    SELECT doc, periodo, SUM(valor) AS neto FROM pagos WHERE periodo <> '' GROUP BY ALL
),
cruce AS (
    SELECT m.cod_per, m.cod_prog,
           CASE WHEN p.doc IS NULL THEN 'matriculado sin pago registrado'
                WHEN p.neto <= 0 THEN 'pagó y le devolvieron (neto <= 0)'
                ELSE 'matriculado con pago' END AS caso
    FROM matriculas m LEFT JOIN pagado p ON p.doc = m.doc AND p.periodo = m.cod_per
)
SELECT cod_per, caso, COUNT(*) AS estudiantes FROM cruce GROUP BY ALL ORDER BY cod_per, caso;

-- name: X06 | Pagos de matrícula en ContaPlus sin matrícula válida en SIAC
WITH matriculas AS (
    SELECT DISTINCT ltrim(regexp_replace(p.num_doc, '[^0-9]', '', 'g'), '0') AS doc, m.cod_per
    FROM landing.siac_matr m JOIN landing.siac_est e USING (cod_est) JOIN landing.siac_pers p USING (id_pers)
    WHERE m.est_matr = 'M' AND m.ind_anul = 'N'
),
pagos AS (
    SELECT DISTINCT ON (comprobante) comprobante, nombre_tercero, detalle,
           ltrim(regexp_replace(split_part(regexp_replace(upper(trim(nit_tercero)), '^(CC|CE|TI)\s*', ''), '-', 1), '[^0-9]', '', 'g'), '0') AS doc,
           regexp_replace(regexp_extract(detalle, '(20[0-9]{2})-?([12])\b', 0), '^(\d{4})-?(\d)$', '\1-\2') AS periodo,
           TRY_CAST(replace(replace(valor, '.', ''), ',', '.') AS DECIMAL(18, 2)) AS valor
    FROM landing.cp_recaudos WHERE concepto IN ('MAT', '1105')
),
clasificados AS (
    SELECT p.*,
           CASE WHEN p.doc = '' OR p.doc LIKE '999999999%' THEN 'sin tercero identificado'
                WHEN regexp_matches(p.doc, '^[89][0-9]{8}$') THEN 'empresa (convenio)'
                WHEN p.periodo = '' THEN 'sin periodo en el detalle'
                WHEN p.valor < 0 THEN 'devolución / reversión'
                WHEN m.doc IS NOT NULL THEN 'cruza con matrícula SIAC'
                WHEN EXISTS (SELECT 1 FROM landing.siac_pers sp WHERE ltrim(regexp_replace(sp.num_doc, '[^0-9]', '', 'g'), '0') = p.doc)
                     THEN 'persona en SIAC sin matrícula en ese periodo'
                ELSE 'documento no existe en SIAC' END AS caso
    FROM pagos p LEFT JOIN matriculas m ON m.doc = p.doc AND m.cod_per = p.periodo
)
SELECT caso, COUNT(*) AS pagos, SUM(valor) AS valor FROM clasificados GROUP BY caso ORDER BY pagos DESC;

-- name: X07 | Catálogos de programa: SIAC vs CRM vs centro de costo de Financiero
WITH siac AS (
    SELECT cod_prog, nom_prog, est_prog FROM landing.siac_prog
),
crm AS (
    SELECT programId, name, modality, active FROM landing.crm_programs
),
centro_costo_por_programa AS (
    SELECT regexp_extract(upper(strip_accents(detalle)), 'PAGO MATRICULA 20[0-9]{2}-[12] (.+)$', 1) AS programa_texto,
           centro_costo, COUNT(*) AS n
    FROM landing.cp_recaudos
    WHERE centro_costo IS NOT NULL AND regexp_matches(upper(strip_accents(detalle)), '^PAGO MATRICULA 20[0-9]{2}-[12] .+')
    GROUP BY ALL
)
SELECT programa_texto, list(centro_costo || ' (' || n || ')' ORDER BY n DESC) AS centros_de_costo
FROM centro_costo_por_programa GROUP BY programa_texto ORDER BY programa_texto;

-- name: X08 | Cartera: deudores que figuran como activos o graduados en SIAC
WITH cartera AS (
    SELECT ltrim(regexp_replace(split_part(nit_tercero, '-', 1), '[^0-9]', '', 'g'), '0') AS doc, periodo,
           TRY_CAST(replace(replace(saldo, '.', ''), ',', '.') AS DECIMAL(18, 2)) AS saldo, dias_mora::INT AS dias_mora
    FROM landing.cp_cartera
),
estado_siac AS (
    SELECT ltrim(regexp_replace(p.num_doc, '[^0-9]', '', 'g'), '0') AS doc, e.est_estado,
           EXISTS (SELECT 1 FROM landing.siac_matr m WHERE m.cod_est = e.cod_est AND m.cod_per = '2026-2'
                   AND m.est_matr = 'M' AND m.ind_anul = 'N') AS matriculado_2026_2
    FROM landing.siac_est e JOIN landing.siac_pers p USING (id_pers) WHERE e.ind_anul = 'N'
)
SELECT coalesce(s.est_estado, 'no está en SIAC') AS estado_siac, s.matriculado_2026_2,
       COUNT(*) AS filas_cartera, SUM(c.saldo) AS saldo, MAX(c.dias_mora) AS mora_max
FROM cartera c LEFT JOIN estado_siac s USING (doc) GROUP BY ALL ORDER BY ALL;
