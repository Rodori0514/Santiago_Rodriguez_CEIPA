-- Validación de lo dicho por Comercial (Andrés Gaviria, 24/10/2026) contra los datos del CRM y SIAC.

-- name: V01 | "A mitad de 2025 cambió la configuración": idioma de la etapa según fecha de cierre/actualización
WITH opp AS (
    SELECT stage,
           CASE WHEN stage IN ('Won', 'Closed Won', 'Lost', 'Closed Lost', 'New', 'Contacted', 'Qualified', 'Application Submitted')
                THEN 'inglés' ELSE 'español' END AS idioma,
           left(coalesce(closedAt, updatedAt), 7) AS mes
    FROM landing.crm_opportunities
)
SELECT mes, COUNT(*) FILTER (WHERE idioma = 'inglés') AS ingles, COUNT(*) FILTER (WHERE idioma = 'español') AS espanol
FROM opp GROUP BY mes ORDER BY mes;

-- name: V02 | Idioma de la etapa por periodo de ingreso
WITH opp AS (
    SELECT intakePeriod,
           CASE WHEN stage IN ('Won', 'Closed Won', 'Lost', 'Closed Lost', 'New', 'Contacted', 'Qualified', 'Application Submitted')
                THEN 'inglés' ELSE 'español' END AS idioma
    FROM landing.crm_opportunities
)
SELECT intakePeriod, idioma, COUNT(*) AS n FROM opp GROUP BY ALL ORDER BY ALL;

-- name: V03 | ¿"Ganada" y "Matriculado" son distintas? Comparación contra la matrícula real en SIAC
WITH ganadas AS (
    SELECT o.opportunityId, o.stage, o.intakePeriod, o.closedAt::TIMESTAMP AS cierre,
           ltrim(regexp_replace(c.documentNumber, '[^0-9]', '', 'g'), '0') AS doc
    FROM landing.crm_opportunities o JOIN landing.crm_contacts c USING (contactId)
    WHERE o.stage IN ('Ganada', 'Won', 'Closed Won', 'Matriculado')
      AND regexp_replace(coalesce(c.documentNumber, ''), '[^0-9]', '', 'g') <> ''
),
matriculas AS (
    SELECT ltrim(regexp_replace(p.num_doc, '[^0-9]', '', 'g'), '0') AS doc, m.cod_per,
           MIN(m.fec_matr::TIMESTAMP) AS fec_matr
    FROM landing.siac_matr m JOIN landing.siac_est e USING (cod_est) JOIN landing.siac_pers p USING (id_pers)
    WHERE m.est_matr = 'M' AND m.ind_anul = 'N'
    GROUP BY ALL
),
cruce AS (
    SELECT g.*, m.fec_matr,
           CASE WHEN m.fec_matr IS NULL THEN 'sin matrícula en SIAC'
                WHEN g.cierre < m.fec_matr - INTERVAL 1 DAY THEN 'cerrada antes de matricularse'
                ELSE 'cerrada al matricularse o después' END AS momento
    FROM ganadas g LEFT JOIN matriculas m ON m.doc = g.doc AND m.cod_per = g.intakePeriod
)
SELECT stage, momento, COUNT(*) AS n,
       round(median(date_diff('day', cierre, fec_matr)), 0) AS mediana_dias_antes_de_matricula
FROM cruce GROUP BY ALL ORDER BY stage, momento;

-- name: V04 | Contactos sin cédula según si llegaron por formulario web y si la oportunidad avanzó
WITH contactos AS (
    SELECT c.contactId, c.leadSource,
           regexp_replace(coalesce(c.documentNumber, ''), '[^0-9]', '', 'g') = '' AS sin_doc,
           bool_or(o.stage IN ('Ganada', 'Won', 'Closed Won', 'Matriculado')) AS tiene_ganada
    FROM landing.crm_contacts c LEFT JOIN landing.crm_opportunities o USING (contactId)
    GROUP BY ALL
)
SELECT CASE WHEN tiene_ganada THEN 'con oportunidad ganada' ELSE 'sin ganada' END AS situacion,
       COUNT(*) AS contactos, COUNT(*) FILTER (WHERE sin_doc) AS sin_cedula,
       round(100.0 * COUNT(*) FILTER (WHERE sin_doc) / COUNT(*), 1) AS pct
FROM contactos GROUP BY ALL ORDER BY 1;

-- name: V05 | "La gente llena el formulario varias veces": fuentes de los contactos duplicados por correo
WITH contactos AS (
    SELECT contactId, leadSource, createdAt, lower(trim(email)) AS email
    FROM landing.crm_contacts WHERE email IS NOT NULL
),
grupos AS (
    SELECT email, COUNT(*) AS n,
           list(leadSource ORDER BY createdAt) AS fuentes,
           COUNT(DISTINCT leadSource) AS fuentes_distintas,
           bool_and(leadSource = 'Formulario web') AS todos_web
    FROM contactos GROUP BY email HAVING COUNT(*) > 1
)
SELECT CASE WHEN todos_web THEN 'todas por formulario web'
            WHEN fuentes_distintas = 1 THEN 'misma fuente (no web)'
            WHEN list_contains(fuentes, 'Formulario web') THEN 'web + otra fuente'
            ELSE 'fuentes distintas sin web' END AS patron,
       COUNT(*) AS correos_duplicados
FROM grupos GROUP BY ALL ORDER BY 2 DESC;

-- name: V06 | "Convenios y los que llegan caminando no pasan por el CRM": fuentes Convenio/Visita en el CRM
WITH contactos AS (
    SELECT c.contactId, c.leadSource, bool_or(o.stage IN ('Ganada', 'Won', 'Closed Won', 'Matriculado')) AS tiene_ganada
    FROM landing.crm_contacts c LEFT JOIN landing.crm_opportunities o USING (contactId)
    WHERE c.leadSource IN ('Convenio empresarial', 'Visita presencial')
    GROUP BY ALL
)
SELECT leadSource, COUNT(*) AS contactos, COUNT(*) FILTER (WHERE tiene_ganada) AS con_ganada
FROM contactos GROUP BY ALL;

-- name: V07 | Estudiantes nuevos fuera del CRM vs estudiantes cubiertos por convenio (cuentas de cobro en Financiero)
WITH nuevos AS (
    SELECT e.cod_per_ing AS periodo,
           ltrim(regexp_replace(p.num_doc, '[^0-9]', '', 'g'), '0') AS doc,
           lower(trim(p.email)) AS email
    FROM landing.siac_est e JOIN landing.siac_pers p USING (id_pers)
    WHERE e.ind_anul = 'N'
),
crm AS (
    SELECT ltrim(regexp_replace(coalesce(documentNumber, ''), '[^0-9]', '', 'g'), '0') AS doc, lower(trim(email)) AS email
    FROM landing.crm_contacts
),
fuera_crm AS (
    SELECT periodo, COUNT(*) AS nuevos,
           COUNT(*) FILTER (WHERE NOT EXISTS (SELECT 1 FROM crm c WHERE (c.doc = n.doc AND c.doc <> '') OR c.email = n.email)) AS fuera_del_crm
    FROM nuevos n GROUP BY periodo
),
convenios AS (
    SELECT DISTINCT ON (comprobante)
           regexp_extract(detalle, '(20[0-9]{2}-[12])', 1) AS periodo,
           TRY_CAST(regexp_extract(detalle, '\((\d+) ESTUDIANTES?\)', 1) AS INTEGER) AS estudiantes
    FROM landing.cp_recaudos
    WHERE detalle LIKE 'CONVENIO EMPRESARIAL%'
),
por_periodo AS (
    SELECT periodo, COUNT(*) AS cuentas_cobro, SUM(estudiantes) AS estudiantes_convenio FROM convenios GROUP BY periodo
)
SELECT f.periodo, f.nuevos, f.fuera_del_crm, coalesce(c.estudiantes_convenio, 0) AS estudiantes_convenio,
       f.fuera_del_crm - coalesce(c.estudiantes_convenio, 0) AS sin_explicar_por_convenio
FROM fuera_crm f LEFT JOIN por_periodo c USING (periodo)
ORDER BY f.periodo;
