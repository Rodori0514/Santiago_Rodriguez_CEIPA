-- Capa oro: modelo dimensional. Tres hechos (matrícula, recaudo, oportunidad) comparten las dimensiones
-- persona, programa, periodo y fecha. La clave 0 de cada dimensión es el miembro "no identificado".

CREATE SCHEMA IF NOT EXISTS gold;

-- ======================================================================== Dimensiones

CREATE OR REPLACE TABLE gold.dim_periodo AS
WITH periodos AS (
    SELECT cod_per, fec_ini, fec_fin, vigente FROM silver.siac_periodo
    UNION
    SELECT DISTINCT periodo, NULL::DATE, NULL::DATE, false FROM silver.crm_oportunidad
    WHERE periodo NOT IN (SELECT cod_per FROM silver.siac_periodo)
)
SELECT 0 AS periodo_sk, 'N/D' AS cod_per, NULL::INTEGER AS anio, NULL::INTEGER AS semestre,
       NULL::DATE AS fec_ini, NULL::DATE AS fec_fin, false AS vigente
UNION ALL
SELECT row_number() OVER (ORDER BY cod_per)::INTEGER,
       cod_per,
       TRY_CAST(left(cod_per, 4) AS INTEGER),
       TRY_CAST(right(cod_per, 1) AS INTEGER),
       fec_ini, fec_fin, vigente
FROM periodos;

CREATE OR REPLACE TABLE gold.dim_fecha AS
WITH dias AS (
    SELECT unnest(generate_series(DATE '2024-01-01', DATE '2027-12-31', INTERVAL 1 DAY))::DATE AS fecha
)
SELECT 0 AS fecha_sk, NULL::DATE AS fecha, NULL::INTEGER AS anio, NULL::INTEGER AS mes, NULL AS nombre_mes,
       NULL::INTEGER AS trimestre, NULL AS anio_mes, NULL AS periodo_academico
UNION ALL
SELECT (year(d.fecha) * 10000 + month(d.fecha) * 100 + day(d.fecha))::INTEGER,
       d.fecha,
       year(d.fecha),
       month(d.fecha),
       ['Enero', 'Febrero', 'Marzo', 'Abril', 'Mayo', 'Junio', 'Julio', 'Agosto', 'Septiembre', 'Octubre',
        'Noviembre', 'Diciembre'][month(d.fecha)],
       quarter(d.fecha),
       strftime(d.fecha, '%Y-%m'),
       coalesce(p.cod_per, 'Intersemestral')
FROM dias d
LEFT JOIN silver.siac_periodo p ON d.fecha BETWEEN p.fec_ini AND p.fec_fin;

CREATE OR REPLACE TABLE gold.dim_programa AS
WITH codigos AS (
    SELECT programa_id,
           string_agg(codigo_origen, ', ' ORDER BY codigo_origen) FILTER (WHERE sistema = 'SIAC') AS codigos_siac,
           string_agg(codigo_origen, ', ' ORDER BY codigo_origen) FILTER (WHERE sistema = 'CRM') AS codigos_crm
    FROM silver.programa_equivalencia GROUP BY programa_id
)
SELECT 0 AS programa_sk, 'N/D' AS programa_id, 'No identificado' AS programa, NULL AS nivel,
       NULL AS centro_costo, NULL AS codigos_siac, NULL AS codigos_crm
UNION ALL
SELECT row_number() OVER (ORDER BY p.programa_id)::INTEGER,
       p.programa_id, p.programa, p.nivel, p.centro_costo, c.codigos_siac, c.codigos_crm
FROM silver.programa p
LEFT JOIN codigos c USING (programa_id);

CREATE OR REPLACE TABLE gold.dim_concepto AS
WITH conceptos AS (
    SELECT ce.codigo, ce.grupo,
           string_agg(ce.codigo_origen, ', ') FILTER (WHERE ce.codigo_origen <> ce.codigo) AS codigo_anterior
    FROM silver.concepto_equivalencia ce GROUP BY ALL
)
SELECT 0 AS concepto_sk, 'N/D' AS codigo, 'No identificado' AS descripcion, NULL AS grupo,
       NULL AS codigo_anterior, NULL AS cuenta_contable
UNION ALL
SELECT row_number() OVER (ORDER BY c.codigo)::INTEGER,
       c.codigo, cc.descripcion, c.grupo, c.codigo_anterior, cc.cuenta_contable
FROM conceptos c
LEFT JOIN landing.cp_conceptos cc ON cc.codigo = c.codigo;

CREATE OR REPLACE TABLE gold.dim_canal AS
SELECT 0 AS canal_sk, 'Sin canal' AS canal
UNION ALL
SELECT row_number() OVER (ORDER BY canal)::INTEGER, canal
FROM (SELECT DISTINCT canal FROM silver.crm_contacto WHERE canal IS NOT NULL);

-- Persona: un registro por persona institucional. Supervivencia de atributos: SIAC primero, luego CRM y luego
-- ContaPlus; dentro de cada sistema, el registro más reciente.
CREATE OR REPLACE TABLE gold.dim_persona AS
WITH atributos AS (
    SELECT x.persona_key, 1 AS prioridad, p.fec_reg AS vigencia,
           p.nombres || ' ' || p.apellidos AS nombre, p.sexo, p.fec_nac, p.calidad_fec_nac,
           p.email_norm, p.celular_norm, p.municipio_norm AS municipio, NULL::BOOLEAN AS autoriza_datos
    FROM silver.persona_xref x
    JOIN silver.siac_persona p ON x.sistema = 'SIAC' AND p.id_pers::VARCHAR = x.id_origen
    UNION ALL
    SELECT x.persona_key, 2, c.actualizado,
           c.nombres || ' ' || c.apellidos, NULL, NULL, NULL,
           c.email_norm, c.celular_norm, c.ciudad_norm, c.autoriza_datos
    FROM silver.persona_xref x
    JOIN silver.crm_contacto c ON x.sistema = 'CRM' AND c.contact_id = x.id_origen
    UNION ALL
    SELECT x.persona_key, 3, max(r.fecha)::TIMESTAMP,
           any_value(r.nombre_tercero), NULL, NULL, NULL, NULL, NULL, NULL, NULL
    FROM silver.persona_xref x
    JOIN silver.cp_recaudo r ON x.sistema = 'CONTAPLUS' AND r.doc_norm = x.id_origen
    GROUP BY x.persona_key
),
personas AS (
    SELECT persona_key,
           arg_min(nombre, (prioridad, -epoch(coalesce(vigencia, TIMESTAMP '1900-01-01')))) AS nombre,
           arg_min(sexo, (prioridad, -epoch(coalesce(vigencia, TIMESTAMP '1900-01-01'))))
               FILTER (WHERE sexo IS NOT NULL) AS sexo,
           arg_min(fec_nac, prioridad) FILTER (WHERE fec_nac IS NOT NULL) AS fec_nac,
           arg_min(calidad_fec_nac, prioridad) FILTER (WHERE calidad_fec_nac IS NOT NULL) AS calidad_fec_nac,
           arg_max(email_norm, vigencia) FILTER (WHERE email_norm IS NOT NULL) AS email,
           arg_max(celular_norm, vigencia) FILTER (WHERE celular_norm IS NOT NULL) AS celular,
           arg_min(municipio, prioridad) FILTER (WHERE municipio IS NOT NULL) AS municipio,
           bool_and(autoriza_datos) FILTER (WHERE autoriza_datos IS NOT NULL) AS autoriza_datos
    FROM atributos GROUP BY persona_key
),
presencia AS (
    SELECT persona_key,
           bool_or(sistema = 'SIAC') AS en_siac,
           bool_or(sistema = 'CRM') AS en_crm,
           bool_or(sistema = 'CONTAPLUS') AS en_contaplus,
           string_agg(DISTINCT regla_cruce, ', ') AS reglas_cruce,
           COUNT(*) FILTER (WHERE sistema = 'SIAC') AS registros_siac,
           COUNT(*) FILTER (WHERE sistema = 'CRM') AS registros_crm
    FROM silver.persona_xref GROUP BY persona_key
)
SELECT 0 AS persona_sk, 'N/D' AS persona_key, NULL AS doc_norm, 'No identificado' AS nombre, NULL AS sexo,
       NULL::DATE AS fec_nac, NULL AS calidad_fec_nac, NULL AS email, NULL AS celular, NULL AS municipio,
       NULL::BOOLEAN AS autoriza_datos, false AS en_siac, false AS en_crm, false AS en_contaplus,
       NULL AS reglas_cruce, 0::BIGINT AS registros_siac, 0::BIGINT AS registros_crm
UNION ALL
SELECT row_number() OVER (ORDER BY p.persona_key)::INTEGER,
       p.persona_key,
       CASE WHEN regexp_matches(p.persona_key, '^[0-9]+$') THEN p.persona_key END,
       p.nombre, p.sexo, p.fec_nac, p.calidad_fec_nac, p.email, p.celular, p.municipio, p.autoriza_datos,
       s.en_siac, s.en_crm, s.en_contaplus, s.reglas_cruce, s.registros_siac, s.registros_crm
FROM personas p JOIN presencia s USING (persona_key);

-- ============================================================================= Hechos

-- Matrícula: una fila por matrícula académica válida (definición oficial de estudiante matriculado).
CREATE OR REPLACE TABLE gold.fact_matricula AS
WITH matriculas AS (
    SELECT m.*, x.persona_key, e.cod_per_ing
    FROM silver.siac_matricula m
    JOIN silver.siac_estudiante e USING (cod_est)
    JOIN silver.persona_xref x ON x.sistema = 'SIAC' AND x.id_origen = m.id_pers::VARCHAR
    WHERE m.es_valida
),
primera AS (
    SELECT persona_key, min(cod_per) AS primer_periodo FROM matriculas GROUP BY persona_key
),
pagos AS (
    SELECT x.persona_key, r.periodo, SUM(r.valor) AS valor_pagado
    FROM silver.cp_recaudo r
    JOIN silver.persona_xref x ON x.sistema = 'CONTAPLUS' AND x.id_origen = r.doc_norm
    WHERE r.grupo_concepto = 'Matrícula' AND r.periodo IS NOT NULL
    GROUP BY ALL
),
cartera AS (
    SELECT doc_norm, periodo, SUM(saldo) AS saldo, max(dias_mora) AS dias_mora
    FROM silver.cp_cartera WHERE concepto = '1105' GROUP BY ALL
),
ganadas AS (
    SELECT x.persona_key, o.periodo,
           arg_min(c.canal, o.cerrada) AS canal,
           min(o.cerrada) AS primera_ganada
    FROM silver.crm_oportunidad o
    JOIN silver.crm_contacto c USING (contact_id)
    JOIN silver.persona_xref x ON x.sistema = 'CRM' AND x.id_origen = o.contact_id
    WHERE o.estado = 'ganada'
    GROUP BY ALL
)
SELECT m.id_matr AS matricula_id,
       coalesce(dp.persona_sk, 0) AS persona_sk,
       coalesce(pr.programa_sk, 0) AS programa_sk,
       coalesce(pe.periodo_sk, 0) AS periodo_sk,
       coalesce(df.fecha_sk, 0) AS fecha_matricula_sk,
       coalesce(ca.canal_sk, 0) AS canal_sk,
       m.cod_est,
       m.cod_prog AS cod_prog_siac,
       m.num_sem AS semestre,
       m.tip_matr AS tipo_matricula_siac,
       (m.cod_per = m.cod_per_ing AND m.cod_per = pm.primer_periodo) AS es_nuevo,
       g.persona_key IS NOT NULL AS tiene_oportunidad_ganada,
       coalesce(p.valor_pagado, 0) AS valor_pagado_matricula,
       coalesce(c.saldo, 0) AS saldo_cartera,
       c.dias_mora,
       1 AS matriculas,
       m._src_file, m._src_line
FROM matriculas m
JOIN primera pm USING (persona_key)
LEFT JOIN pagos p ON p.persona_key = m.persona_key AND p.periodo = m.cod_per
LEFT JOIN cartera c ON c.doc_norm = m.doc_norm AND c.periodo = m.cod_per
LEFT JOIN ganadas g ON g.persona_key = m.persona_key AND g.periodo = m.cod_per
LEFT JOIN gold.dim_persona dp ON dp.persona_key = m.persona_key
LEFT JOIN gold.dim_programa pr ON pr.programa_id = m.programa_id
LEFT JOIN gold.dim_periodo pe ON pe.cod_per = m.cod_per
LEFT JOIN gold.dim_fecha df ON df.fecha = m.fec_matr::DATE
LEFT JOIN gold.dim_canal ca ON ca.canal = g.canal;

-- Recaudo: una fila por comprobante de caja (sin duplicados entre archivos).
CREATE OR REPLACE TABLE gold.fact_recaudo AS
SELECT r.comprobante,
       coalesce(df.fecha_sk, 0) AS fecha_sk,
       coalesce(dp.persona_sk, 0) AS persona_sk,
       coalesce(pr.programa_sk, 0) AS programa_sk,
       coalesce(pe.periodo_sk, 0) AS periodo_sk,
       coalesce(dc.concepto_sk, 0) AS concepto_sk,
       r.tipo_tercero,
       r.nombre_tercero,
       r.forma_pago,
       r.version_contaplus,
       r.es_devolucion,
       r.es_convenio,
       r.estudiantes_convenio,
       r.valor,
       r.copias AS veces_en_archivos,
       r._src_file, r._src_line
FROM silver.cp_recaudo r
LEFT JOIN silver.persona_xref x ON x.sistema = 'CONTAPLUS' AND x.id_origen = r.doc_norm AND r.tipo_tercero = 'PERSONA'
LEFT JOIN gold.dim_persona dp ON dp.persona_key = x.persona_key
LEFT JOIN gold.dim_programa pr ON pr.programa_id = r.programa_id
LEFT JOIN gold.dim_periodo pe ON pe.cod_per = r.periodo
LEFT JOIN gold.dim_concepto dc ON dc.codigo = r.concepto
LEFT JOIN gold.dim_fecha df ON df.fecha = r.fecha;

-- Oportunidad: una fila por oportunidad del CRM, con la verificación contra la matrícula real en SIAC.
CREATE OR REPLACE TABLE gold.fact_oportunidad AS
WITH matricula_real AS (
    SELECT x.persona_key, m.cod_per, min(m.fec_matr) AS fec_matr
    FROM silver.siac_matricula m
    JOIN silver.persona_xref x ON x.sistema = 'SIAC' AND x.id_origen = m.id_pers::VARCHAR
    WHERE m.es_valida
    GROUP BY ALL
)
SELECT o.oportunidad_id,
       coalesce(dp.persona_sk, 0) AS persona_sk,
       coalesce(pr.programa_sk, 0) AS programa_sk,
       coalesce(pe.periodo_sk, 0) AS periodo_sk,
       coalesce(ca.canal_sk, 0) AS canal_sk,
       coalesce(fc.fecha_sk, 0) AS fecha_creacion_sk,
       coalesce(fx.fecha_sk, 0) AS fecha_cierre_sk,
       o.asesor,
       o.modalidad,
       o.etapa_origen,
       o.idioma_etapa,
       o.etapa,
       o.estado,
       o.motivo_perdida,
       o.monto_digitado,
       x.regla_cruce,
       mr.fec_matr IS NOT NULL AS matricula_confirmada,
       CASE WHEN o.estado = 'ganada' THEN date_diff('day', o.cerrada::DATE, mr.fec_matr::DATE) END AS dias_cierre_a_matricula,
       (o.estado = 'abierta' AND o.extraida::DATE > p.fec_ini + INTERVAL 30 DAY) AS abierta_vencida,
       1 AS oportunidades
FROM silver.crm_oportunidad o
JOIN silver.crm_contacto c USING (contact_id)
JOIN silver.persona_xref x ON x.sistema = 'CRM' AND x.id_origen = o.contact_id
LEFT JOIN matricula_real mr ON mr.persona_key = x.persona_key AND mr.cod_per = o.periodo
LEFT JOIN silver.siac_periodo p ON p.cod_per = o.periodo
LEFT JOIN gold.dim_persona dp ON dp.persona_key = x.persona_key
LEFT JOIN gold.dim_programa pr ON pr.programa_id = o.programa_id
LEFT JOIN gold.dim_periodo pe ON pe.cod_per = o.periodo
LEFT JOIN gold.dim_canal ca ON ca.canal = c.canal
LEFT JOIN gold.dim_fecha fc ON fc.fecha = o.creada::DATE
LEFT JOIN gold.dim_fecha fx ON fx.fecha = o.cerrada::DATE;

-- Calificación: una fila por nota no anulada de una matrícula válida. Hereda las llaves de fact_matricula.
-- Las notas fuera de 0-5 quedan marcadas y sin definitiva calculada (Registro las corrige con el docente).
CREATE OR REPLACE TABLE gold.fact_calificacion AS
SELECT c.id_calif AS calificacion_id,
       c.id_matr AS matricula_id,
       fm.persona_sk,
       fm.programa_sk,
       fm.periodo_sk,
       coalesce(df.fecha_sk, 0) AS fecha_registro_sk,
       c.cod_asig AS asignatura,
       c.nota_c1, c.nota_c2, c.nota_c3,
       c.nota_def AS nota_def_siac,
       CASE WHEN NOT c.fuera_de_rango THEN c.nota_def_calculada END AS nota_def_calculada,
       c.en_curso,
       c.fuera_de_rango,
       (NOT c.en_curso AND NOT c.fuera_de_rango AND abs(c.nota_def - c.nota_def_calculada) > 0.1) AS definitiva_inconsistente,
       c._src_file, c._src_line
FROM silver.siac_calificacion c
JOIN gold.fact_matricula fm ON fm.matricula_id = c.id_matr
LEFT JOIN gold.dim_fecha df ON df.fecha = c.fec_reg::DATE
WHERE NOT c.anulada;

-- ============================================================== Indicadores de ejemplo

CREATE OR REPLACE VIEW gold.v_indicadores_periodo AS
WITH matricula AS (
    SELECT periodo_sk,
           COUNT(DISTINCT persona_sk) AS matriculados,
           COUNT(DISTINCT persona_sk) FILTER (WHERE es_nuevo) AS nuevos,
           COUNT(DISTINCT persona_sk) FILTER (WHERE es_nuevo AND tiene_oportunidad_ganada) AS nuevos_con_oportunidad_ganada,
           COUNT(DISTINCT persona_sk) FILTER (WHERE valor_pagado_matricula <= 0) AS matriculados_sin_pago_identificado
    FROM gold.fact_matricula GROUP BY periodo_sk
),
comercial AS (
    SELECT periodo_sk,
           COUNT(*) AS oportunidades,
           COUNT(*) FILTER (WHERE estado = 'ganada') AS ganadas_en_crm,
           COUNT(*) FILTER (WHERE estado = 'ganada' AND matricula_confirmada) AS ganadas_con_matricula_real
    FROM gold.fact_oportunidad GROUP BY periodo_sk
),
recaudo AS (
    SELECT r.periodo_sk, SUM(r.valor) AS recaudo_matricula
    FROM gold.fact_recaudo r JOIN gold.dim_concepto c USING (concepto_sk)
    WHERE c.grupo = 'Matrícula' GROUP BY r.periodo_sk
)
SELECT p.cod_per AS periodo,
       m.matriculados, m.nuevos, m.nuevos_con_oportunidad_ganada, m.matriculados_sin_pago_identificado,
       c.oportunidades, c.ganadas_en_crm, c.ganadas_con_matricula_real,
       round(100.0 * c.ganadas_con_matricula_real / nullif(c.oportunidades, 0), 1) AS conversion_real_pct,
       r.recaudo_matricula
FROM gold.dim_periodo p
LEFT JOIN matricula m USING (periodo_sk)
LEFT JOIN comercial c USING (periodo_sk)
LEFT JOIN recaudo r USING (periodo_sk)
WHERE p.periodo_sk > 0
  AND coalesce(m.matriculados, c.oportunidades, r.recaudo_matricula) IS NOT NULL
ORDER BY p.cod_per;
