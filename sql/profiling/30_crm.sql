-- Perfilado de VentasCloud (Comercial). Consultas autocontenidas con CTE.

-- name: C00 | Catálogo de programas del CRM
SELECT programId, name, level, modality, active, createdAt FROM landing.crm_programs ORDER BY programId;

-- name: C01 | Contactos: completitud de los campos que sirven para identificar a la persona
WITH contactos AS (
    SELECT *, regexp_replace(coalesce(documentNumber, ''), '[^0-9]', '', 'g') AS doc_digitos
    FROM landing.crm_contacts
)
SELECT COUNT(*) AS contactos,
       COUNT(*) FILTER (WHERE documentType IS NULL) AS sin_tipo_doc,
       COUNT(*) FILTER (WHERE doc_digitos = '') AS sin_numero_doc,
       COUNT(*) FILTER (WHERE documentType IS NULL AND doc_digitos <> '') AS numero_sin_tipo,
       COUNT(*) FILTER (WHERE email IS NULL) AS sin_email,
       COUNT(*) FILTER (WHERE mobile IS NULL) AS sin_celular,
       COUNT(*) FILTER (WHERE doc_digitos = '' AND email IS NULL AND mobile IS NULL) AS sin_ningun_identificador,
       COUNT(*) FILTER (WHERE NOT consentDataProcessing) AS sin_consentimiento
FROM contactos;

-- name: C02 | Contactos sin documento: ¿por fuente del lead y por año de creación?
WITH contactos AS (
    SELECT leadSource, left(createdAt, 4) AS anio, documentNumber IS NULL AS sin_doc
    FROM landing.crm_contacts
)
SELECT leadSource, COUNT(*) AS contactos, COUNT(*) FILTER (WHERE sin_doc) AS sin_doc,
       round(100.0 * COUNT(*) FILTER (WHERE sin_doc) / COUNT(*), 1) AS pct_sin_doc
FROM contactos GROUP BY leadSource ORDER BY pct_sin_doc DESC;

-- name: C03 | Contactos duplicados: por documento normalizado y por correo
WITH contactos AS (
    SELECT contactId, firstName, lastName, createdAt, ownerName,
           nullif(regexp_replace(coalesce(documentNumber, ''), '[^0-9]', '', 'g'), '') AS doc,
           nullif(lower(trim(email)), '') AS email
    FROM landing.crm_contacts
),
por_doc AS (
    SELECT doc, COUNT(*) AS n FROM contactos WHERE doc IS NOT NULL GROUP BY doc HAVING COUNT(*) > 1
),
por_email AS (
    SELECT email, COUNT(*) AS n FROM contactos WHERE email IS NOT NULL GROUP BY email HAVING COUNT(*) > 1
)
SELECT 'mismo documento' AS criterio, COUNT(*) AS grupos, SUM(n) AS contactos FROM por_doc
UNION ALL
SELECT 'mismo correo', COUNT(*), SUM(n) FROM por_email;

-- name: C03b | Ejemplos de contactos duplicados por correo (¿misma persona?)
WITH contactos AS (
    SELECT contactId, firstName, lastName, documentNumber, mobile, leadSource, createdAt,
           lower(trim(email)) AS email
    FROM landing.crm_contacts WHERE email IS NOT NULL
),
dups AS (
    SELECT email FROM contactos GROUP BY email HAVING COUNT(*) > 1
)
SELECT c.email, list(c.firstName || ' ' || c.lastName ORDER BY c.createdAt) AS nombres,
       list(coalesce(c.documentNumber, '-') ORDER BY c.createdAt) AS documentos,
       list(c.leadSource ORDER BY c.createdAt) AS fuentes, list(left(c.createdAt, 10) ORDER BY c.createdAt) AS creados
FROM contactos c JOIN dups USING (email) GROUP BY c.email ORDER BY c.email LIMIT 15;

-- name: C04 | Contactos: formatos de documento, celular y nombres en minúscula
WITH contactos AS (SELECT * FROM landing.crm_contacts)
SELECT 'documento' AS campo, regexp_replace(documentNumber, '[0-9]', '9', 'g') AS patron, COUNT(*) AS n FROM contactos GROUP BY ALL
UNION ALL
SELECT 'celular', regexp_replace(mobile, '[0-9]', '9', 'g'), COUNT(*) FROM contactos GROUP BY ALL
UNION ALL
SELECT 'nombre', CASE WHEN firstName = lower(firstName) THEN 'minúsculas' WHEN firstName = upper(firstName) THEN 'MAYÚSCULAS' ELSE 'Mixto' END, COUNT(*) FROM contactos GROUP BY ALL
ORDER BY campo, n DESC;

-- name: C05 | Contactos: variantes de ciudad que colapsan al normalizar
WITH ciudades AS (
    SELECT city, upper(strip_accents(trim(city))) AS ciudad_norm FROM landing.crm_contacts WHERE city IS NOT NULL
)
SELECT ciudad_norm, COUNT(DISTINCT city) AS variantes, COUNT(*) AS contactos, list(DISTINCT city) AS como_viene
FROM ciudades GROUP BY ciudad_norm HAVING COUNT(DISTINCT city) > 1 ORDER BY contactos DESC;

-- name: C06 | Programa de interés (texto libre) vs catálogo del CRM
WITH interes AS (
    SELECT upper(strip_accents(trim(programInterest))) AS texto FROM landing.crm_contacts
)
SELECT COUNT(DISTINCT texto) AS variantes_normalizadas,
       (SELECT COUNT(DISTINCT programInterest) FROM landing.crm_contacts) AS variantes_como_vienen,
       (SELECT COUNT(*) FROM landing.crm_programs) AS programas_catalogo,
       COUNT(*) FILTER (WHERE texto IS NULL) AS sin_interes
FROM interes;

-- name: C07 | Oportunidades: etapas (mezcla de idiomas y sinónimos)
WITH etapas AS (
    SELECT stage, closedAt IS NOT NULL AS cerrada, amount IS NULL AS sin_monto, lostReason IS NOT NULL AS con_motivo
    FROM landing.crm_opportunities
)
SELECT stage, COUNT(*) AS n, COUNT(*) FILTER (WHERE cerrada) AS con_closedAt,
       COUNT(*) FILTER (WHERE sin_monto) AS sin_monto, COUNT(*) FILTER (WHERE con_motivo) AS con_motivo_perdida
FROM etapas GROUP BY stage ORDER BY n DESC;

-- name: C08 | Oportunidades: reglas de consistencia por etapa homologada
WITH opp AS (
    SELECT *,
           CASE WHEN stage IN ('Ganada', 'Won', 'Closed Won', 'Matriculado') THEN 'ganada'
                WHEN stage IN ('Perdida', 'Lost', 'Closed Lost') THEN 'perdida'
                ELSE 'abierta' END AS etapa
    FROM landing.crm_opportunities
)
SELECT etapa, COUNT(*) AS n,
       COUNT(*) FILTER (WHERE etapa <> 'abierta' AND closedAt IS NULL) AS cerrada_sin_closedAt,
       COUNT(*) FILTER (WHERE etapa = 'abierta' AND closedAt IS NOT NULL) AS abierta_con_closedAt,
       COUNT(*) FILTER (WHERE etapa = 'perdida' AND lostReason IS NULL) AS perdida_sin_motivo,
       COUNT(*) FILTER (WHERE etapa <> 'perdida' AND lostReason IS NOT NULL) AS motivo_sin_perder,
       COUNT(*) FILTER (WHERE etapa = 'ganada' AND amount IS NULL) AS ganada_sin_monto,
       COUNT(*) FILTER (WHERE programId IS NULL) AS sin_programa,
       COUNT(*) FILTER (WHERE ownerName IS NULL) AS sin_asesor,
       COUNT(*) FILTER (WHERE closedAt < createdAt) AS cierre_antes_de_creacion
FROM opp GROUP BY etapa ORDER BY etapa;

-- name: C09 | Oportunidades abiertas de periodos ya iniciados (pipeline "zombie")
WITH opp AS (
    SELECT intakePeriod, stage FROM landing.crm_opportunities
    WHERE stage NOT IN ('Ganada', 'Won', 'Closed Won', 'Matriculado', 'Perdida', 'Lost', 'Closed Lost')
)
SELECT intakePeriod, COUNT(*) AS abiertas, list(DISTINCT stage) AS etapas
FROM opp GROUP BY intakePeriod ORDER BY intakePeriod;

-- name: C10 | Oportunidades: más de una por contacto y periodo
WITH opp AS (
    SELECT contactId, intakePeriod, COUNT(*) AS n, list(stage) AS etapas, list(programId) AS programas
    FROM landing.crm_opportunities GROUP BY contactId, intakePeriod HAVING COUNT(*) > 1
)
SELECT COUNT(*) AS grupos, SUM(n) AS oportunidades, list(etapas)[1:5] AS ejemplos_etapas, list(programas)[1:5] AS ejemplos_programas
FROM opp;

-- name: C11 | Oportunidades: monto vs periodo y programa (¿es el valor de la matrícula?)
WITH opp AS (
    SELECT o.intakePeriod, p.name AS programa, o.amount
    FROM landing.crm_opportunities o LEFT JOIN landing.crm_programs p USING (programId)
    WHERE o.amount IS NOT NULL
)
SELECT programa, intakePeriod, COUNT(*) AS n, MIN(amount) AS minimo, median(amount) AS mediana, MAX(amount) AS maximo
FROM opp GROUP BY ALL ORDER BY programa, intakePeriod;

-- name: C12 | Oportunidades: programa inactivo o de educación continua
WITH opp AS (
    SELECT o.*, p.name, p.active, p.level FROM landing.crm_opportunities o JOIN landing.crm_programs p USING (programId)
)
SELECT name, level, active, stage, COUNT(*) AS n FROM opp
WHERE NOT active OR level NOT IN ('Pregrado', 'Posgrado') GROUP BY ALL ORDER BY ALL;

-- name: C13 | Contactos sin consentimiento con oportunidades activas o ganadas
WITH sin_consentimiento AS (
    SELECT contactId FROM landing.crm_contacts WHERE NOT consentDataProcessing
)
SELECT o.stage, COUNT(*) AS oportunidades
FROM landing.crm_opportunities o JOIN sin_consentimiento USING (contactId) GROUP BY o.stage ORDER BY 2 DESC;

-- name: C14 | Frescura: fechas máximas (¿la extracción incremental por updatedAt es confiable?)
WITH c AS (SELECT MAX(updatedAt) mx, MIN(createdAt) mn, COUNT(*) FILTER (WHERE updatedAt < createdAt) inv FROM landing.crm_contacts),
     o AS (SELECT MAX(updatedAt) mx, MIN(createdAt) mn, COUNT(*) FILTER (WHERE updatedAt < createdAt) inv FROM landing.crm_opportunities)
SELECT 'contacts' AS entidad, mn AS primer_creado, mx AS ultima_actualizacion, inv AS actualizado_antes_de_creado FROM c
UNION ALL SELECT 'opportunities', mn, mx, inv FROM o;
