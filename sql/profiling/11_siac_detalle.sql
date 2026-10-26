-- name: S30 | Administración: ADM01 (inactivo) vs ADE10 por periodo de ingreso y de matrícula
SELECT e.cod_prog, e.cod_per_ing, m.cod_per, COUNT(*) matriculas
FROM landing.siac_matr m JOIN landing.siac_est e USING (cod_est)
WHERE e.cod_prog IN ('ADM01', 'ADE10') AND m.ind_anul = 'N' AND m.est_matr = 'M'
GROUP BY ALL ORDER BY 1, 2, 3;

-- name: S31 | Notas negativas y fuera de escala: detalle
SELECT c.id_calif, m.cod_per, c.cod_asig, c.nota_c1, c.nota_c2, c.nota_c3, c.nota_def, c.usu_reg, c.ind_anul
FROM landing.siac_calif c JOIN landing.siac_matr m USING (id_matr)
WHERE least(c.nota_c1::DOUBLE, c.nota_c2::DOUBLE, c.nota_c3::DOUBLE, c.nota_def::DOUBLE) < 0
   OR greatest(c.nota_c1::DOUBLE, c.nota_c2::DOUBLE, c.nota_c3::DOUBLE, c.nota_def::DOUBLE) > 5
ORDER BY c.nota_def::DOUBLE LIMIT 40;

-- name: S31b | Notas fuera de escala por usuario que registra
SELECT usu_reg,
       COUNT(*) total,
       COUNT(*) FILTER (WHERE nota_def::DOUBLE > 5) def_mayor_5,
       COUNT(*) FILTER (WHERE least(nota_c1::DOUBLE, nota_c2::DOUBLE, nota_c3::DOUBLE, nota_def::DOUBLE) < 0) negativas
FROM landing.siac_calif GROUP BY 1 ORDER BY 1;

-- name: S32 | Calificaciones repetidas (matrícula+asignatura) vs anulación
SELECT COUNT(*) grupos, COUNT(*) FILTER (WHERE n_anul = 1 AND n = 2) una_anulada_una_valida,
       COUNT(*) FILTER (WHERE n_anul = 0) ninguna_anulada
FROM (SELECT id_matr, cod_asig, COUNT(*) n, COUNT(*) FILTER (WHERE ind_anul = 'S') n_anul
      FROM landing.siac_calif GROUP BY 1, 2 HAVING COUNT(*) > 1);

-- name: S32b | ¿Las notas anuladas difieren de la válida?
SELECT a.nota_def anulada, v.nota_def valida, COUNT(*) n
FROM landing.siac_calif a JOIN landing.siac_calif v ON v.id_matr = a.id_matr AND v.cod_asig = a.cod_asig AND v.ind_anul = 'N'
WHERE a.ind_anul = 'S' GROUP BY ALL ORDER BY n DESC LIMIT 15;

-- name: S33 | Personas duplicadas: ¿ambos registros tienen estudiante? diferencias en otros campos
WITH p AS (SELECT *, regexp_replace(num_doc, '[^0-9]', '', 'g') doc_norm FROM landing.siac_pers),
d AS (SELECT doc_norm FROM p GROUP BY 1 HAVING COUNT(*) > 1)
SELECT p.doc_norm, p.id_pers, p.tip_doc, p.num_doc, p.pri_nom, p.pri_ape, p.fec_nac, p.email, p.fec_reg, p.usu_reg, p.ind_anul,
       (SELECT string_agg(e.cod_est || ':' || e.cod_prog || ':' || e.est_estado, ',') FROM landing.siac_est e WHERE e.id_pers = p.id_pers) estudiante
FROM p JOIN d USING (doc_norm) ORDER BY p.doc_norm, p.id_pers LIMIT 40;

-- name: S33b | Personas duplicadas: cuántos grupos tienen estudiantes en ambos registros
WITH p AS (SELECT *, regexp_replace(num_doc, '[^0-9]', '', 'g') doc_norm,
                  EXISTS (SELECT 1 FROM landing.siac_est e WHERE e.id_pers = siac_pers.id_pers) tiene_est
           FROM landing.siac_pers)
SELECT n_con_est, COUNT(*) grupos FROM (
  SELECT doc_norm, COUNT(*) FILTER (WHERE tiene_est) n_con_est FROM p GROUP BY 1 HAVING COUNT(*) > 1)
GROUP BY 1 ORDER BY 1;

-- name: S34 | Posibles duplicados con documento distinto (mismo nombre + fecha de nacimiento)
WITH p AS (SELECT *, upper(strip_accents(trim(pri_nom || ' ' || coalesce(seg_nom,'') || ' ' || pri_ape || ' ' || coalesce(seg_ape,'')))) nom FROM landing.siac_pers)
SELECT nom, fec_nac, COUNT(*) n, list(num_doc) docs, list(tip_doc) tipos
FROM p WHERE fec_nac IS NOT NULL GROUP BY 1, 2
HAVING COUNT(DISTINCT regexp_replace(num_doc, '[^0-9]', '', 'g')) > 1 ORDER BY n DESC LIMIT 20;

-- name: S35 | Tipo de documento vs edad (TI = menor de edad)
SELECT tip_doc,
       COUNT(*) FILTER (WHERE date_diff('year', TRY_STRPTIME(fec_nac, '%d/%m/%Y'), DATE '2026-10-17') >= 18) mayores_18,
       COUNT(*) FILTER (WHERE date_diff('year', TRY_STRPTIME(fec_nac, '%d/%m/%Y'), DATE '2026-10-17') < 18) menores_18,
       COUNT(*) FILTER (WHERE TRY_STRPTIME(fec_nac, '%d/%m/%Y') IS NULL) sin_fecha_valida
FROM landing.siac_pers GROUP BY 1;

-- name: S36 | Matrículas tipo N que no son la primera: detalle
WITH m AS (SELECT *, ROW_NUMBER() OVER (PARTITION BY cod_est ORDER BY cod_per, id_matr::INT) rn FROM landing.siac_matr)
SELECT cod_est, list(cod_per || ':' || tip_matr || ':' || est_matr || ':' || ind_anul ORDER BY cod_per, id_matr::INT) historia
FROM m WHERE cod_est IN (SELECT cod_est FROM m WHERE tip_matr = 'N' AND rn > 1) GROUP BY 1;

-- name: S37 | Estado A con matrícula solo cancelada/anulada en 2026-2 o sin matrícula reciente
SELECT est_estado, ultima_matr_valida, COUNT(*) n FROM (
  SELECT e.est_estado, e.cod_est,
         coalesce(max(m.cod_per) FILTER (WHERE m.est_matr = 'M' AND m.ind_anul = 'N'), 'ninguna') ultima_matr_valida
  FROM landing.siac_est e LEFT JOIN landing.siac_matr m USING (cod_est)
  WHERE e.est_estado IN ('A', 'I') AND e.ind_anul = 'N' GROUP BY 1, 2)
GROUP BY ALL ORDER BY ALL;
