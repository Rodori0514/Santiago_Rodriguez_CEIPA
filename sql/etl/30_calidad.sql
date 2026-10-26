-- Reglas de calidad (gobierno, sección 3.3). Cada ejecución agrega su resultado a audit.dq_resultado.
-- El identificador de la ejecución llega en la variable `run_id` (la define src/pipeline.py).

CREATE SCHEMA IF NOT EXISTS audit;

CREATE TABLE IF NOT EXISTS audit.dq_resultado (
    run_id VARCHAR,
    evaluado_en TIMESTAMP,
    regla VARCHAR,
    fuente VARCHAR,
    severidad VARCHAR,
    dueno VARCHAR,
    registros_evaluados BIGINT,
    registros_con_falla BIGINT
);

INSERT INTO audit.dq_resultado
WITH reglas AS (
    SELECT 'R01 Detalle del archivo cuadra con el pie' AS regla, 'ContaPlus' AS fuente, 'bloquea' AS severidad,
           'Financiero' AS dueno, COUNT(*) AS evaluados, COUNT(*) FILTER (WHERE NOT cuadra) AS fallas
    FROM silver.cp_archivo
    UNION ALL
    SELECT 'R02 Comprobante en un solo archivo', 'ContaPlus', 'alerta', 'Financiero',
           COUNT(*), COUNT(*) FILTER (WHERE copias > 1)
    FROM silver.cp_recaudo
    UNION ALL
    SELECT 'R03 Pago con tercero identificado', 'ContaPlus', 'alerta', 'Financiero',
           COUNT(*), COUNT(*) FILTER (WHERE tipo_tercero = 'NO IDENTIFICADO')
    FROM silver.cp_recaudo
    UNION ALL
    SELECT 'R04 Recaudo de matrícula con periodo identificable', 'ContaPlus', 'alerta', 'Financiero',
           COUNT(*), COUNT(*) FILTER (WHERE periodo IS NULL)
    FROM silver.cp_recaudo WHERE grupo_concepto = 'Matrícula'
    UNION ALL
    SELECT 'R05 Concepto dentro de la tabla de homologación', 'ContaPlus', 'bloquea', 'Financiero',
           COUNT(*), COUNT(*) FILTER (WHERE concepto IS NULL)
    FROM silver.cp_recaudo
    UNION ALL
    SELECT 'R06 Nota entre 0 y 5', 'SIAC', 'cuarentena', 'Registro y Control',
           COUNT(*), COUNT(*) FILTER (WHERE fuera_de_rango)
    FROM silver.siac_calificacion WHERE NOT anulada
    UNION ALL
    SELECT 'R07 Definitiva = 30/30/40 (tolerancia 0,1)', 'SIAC', 'alerta', 'Registro y Control',
           COUNT(*), COUNT(*) FILTER (WHERE abs(nota_def - nota_def_calculada) > 0.1)
    FROM silver.siac_calificacion WHERE NOT anulada AND NOT en_curso AND NOT fuera_de_rango
    UNION ALL
    SELECT 'R08 Una persona por documento', 'SIAC', 'alerta', 'Registro y Control',
           COUNT(DISTINCT doc_norm), COUNT(DISTINCT doc_norm) FILTER (WHERE n > 1)
    FROM (SELECT doc_norm, COUNT(*) OVER (PARTITION BY doc_norm) AS n FROM silver.siac_persona WHERE NOT anulada)
    UNION ALL
    SELECT 'R09 Fecha de nacimiento en formato DD/MM/AAAA', 'SIAC', 'alerta', 'Registro y Control',
           COUNT(*), COUNT(*) FILTER (WHERE calidad_fec_nac IN ('MM/DD corregida', 'no interpretable', 'sin dato'))
    FROM silver.siac_persona WHERE NOT anulada
    UNION ALL
    SELECT 'R10 Estado "activo" coherente con la matrícula del periodo vigente', 'SIAC', 'alerta', 'Registro y Control',
           COUNT(*) FILTER (WHERE e.est_estado = 'A'),
           COUNT(*) FILTER (WHERE e.est_estado = 'A' AND NOT EXISTS (
               SELECT 1 FROM silver.siac_matricula m JOIN silver.siac_periodo p USING (cod_per)
               WHERE m.cod_est = e.cod_est AND m.es_valida AND p.vigente))
    FROM silver.siac_estudiante e WHERE NOT e.anulado
    UNION ALL
    SELECT 'R11 Contacto con documento', 'VentasCloud', 'alerta', 'Comercial',
           COUNT(*), COUNT(*) FILTER (WHERE doc_norm IS NULL)
    FROM silver.crm_contacto
    UNION ALL
    SELECT 'R12 Una persona por correo', 'VentasCloud', 'alerta', 'Comercial',
           COUNT(DISTINCT email_norm), COUNT(DISTINCT email_norm) FILTER (WHERE n > 1)
    FROM (SELECT email_norm, COUNT(*) OVER (PARTITION BY email_norm) AS n FROM silver.crm_contacto WHERE email_norm IS NOT NULL)
    UNION ALL
    SELECT 'R13 Etapa dentro del catálogo homologado', 'VentasCloud', 'bloquea', 'Comercial',
           COUNT(*), COUNT(*) FILTER (WHERE etapa IS NULL)
    FROM silver.crm_oportunidad
    UNION ALL
    SELECT 'R14 Etapa en el idioma de la configuración vigente', 'VentasCloud', 'alerta', 'Comercial',
           COUNT(*), COUNT(*) FILTER (WHERE idioma_etapa = 'inglés')
    FROM silver.crm_oportunidad
    UNION ALL
    SELECT 'R15 Oportunidad ganada con matrícula real en el periodo', 'VentasCloud + SIAC', 'alerta', 'Comercial',
           COUNT(*) FILTER (WHERE estado = 'ganada'),
           COUNT(*) FILTER (WHERE estado = 'ganada' AND NOT matricula_confirmada)
    FROM gold.fact_oportunidad
    UNION ALL
    SELECT 'R16 Oportunidad abierta de un periodo ya iniciado (más de 30 días)', 'VentasCloud', 'alerta', 'Comercial',
           COUNT(*) FILTER (WHERE estado = 'abierta'), COUNT(*) FILTER (WHERE abierta_vencida)
    FROM gold.fact_oportunidad
    UNION ALL
    SELECT 'R17 Contacto con autorización de tratamiento de datos', 'VentasCloud', 'alerta', 'Comercial',
           COUNT(*), COUNT(*) FILTER (WHERE autoriza_datos IS DISTINCT FROM true)
    FROM silver.crm_contacto
    UNION ALL
    SELECT 'R18 Graduado sin saldo en cartera', 'SIAC + ContaPlus', 'alerta', 'Registro y Financiero',
           COUNT(DISTINCT e.cod_est),
           COUNT(DISTINCT e.cod_est) FILTER (WHERE c.saldo > 0)
    FROM silver.siac_estudiante e
    JOIN silver.siac_persona p USING (id_pers)
    LEFT JOIN silver.cp_cartera c ON c.doc_norm = p.doc_norm
    WHERE e.fec_grado IS NOT NULL AND NOT e.anulado
)
SELECT getvariable('run_id'), now()::TIMESTAMP, regla, fuente, severidad, dueno, evaluados, fallas
FROM reglas;
