-- name: S00 | Programas y periodos
SELECT * EXCLUDE (_src_file, _loaded_at, _src_line) FROM landing.siac_prog;

-- name: S00b | Periodos
SELECT * EXCLUDE (_src_file, _loaded_at, _src_line) FROM landing.siac_per_acad;

-- name: S01 | Personas: completitud por columna
SELECT COUNT(*) AS filas,
       COUNT(*) FILTER (WHERE seg_nom IS NULL) AS sin_seg_nom,
       COUNT(*) FILTER (WHERE fec_nac IS NULL) AS sin_fec_nac,
       COUNT(*) FILTER (WHERE sexo IS NULL) AS sin_sexo,
       COUNT(*) FILTER (WHERE email IS NULL) AS sin_email,
       COUNT(*) FILTER (WHERE tel_cel IS NULL) AS sin_cel,
       COUNT(*) FILTER (WHERE municipio IS NULL) AS sin_municipio,
       COUNT(*) FILTER (WHERE ind_anul = 'S') AS anuladas
FROM landing.siac_pers;

-- name: S02 | Personas: distribución de tipo de documento, sexo, anulación, usuario
SELECT 'tip_doc' AS campo, tip_doc AS valor, COUNT(*) n FROM landing.siac_pers GROUP BY ALL
UNION ALL SELECT 'sexo', sexo, COUNT(*) FROM landing.siac_pers GROUP BY ALL
UNION ALL SELECT 'ind_anul', ind_anul, COUNT(*) FROM landing.siac_pers GROUP BY ALL
UNION ALL SELECT 'usu_reg', usu_reg, COUNT(*) FROM landing.siac_pers GROUP BY ALL
ORDER BY campo, n DESC;

-- name: S03 | Personas: formatos de NUM_DOC (dígitos -> 9)
SELECT regexp_replace(num_doc, '[0-9]', '9', 'g') AS patron, COUNT(*) n, MIN(num_doc) ejemplo
FROM landing.siac_pers GROUP BY 1 ORDER BY n DESC;

-- name: S04 | Personas: documento duplicado (normalizado a solo dígitos)
WITH p AS (SELECT *, regexp_replace(num_doc, '[^0-9]', '', 'g') AS doc_norm FROM landing.siac_pers)
SELECT doc_norm, COUNT(*) n, list(id_pers ORDER BY id_pers) ids, list(DISTINCT tip_doc) tipos,
       list(pri_nom || ' ' || pri_ape ORDER BY id_pers) nombres, list(ind_anul ORDER BY id_pers) anul
FROM p GROUP BY doc_norm HAVING COUNT(*) > 1 ORDER BY n DESC, doc_norm;

-- name: S05 | Personas: formatos de FEC_NAC (texto)
SELECT regexp_replace(fec_nac, '[0-9]', '9', 'g') AS patron, COUNT(*) n, MIN(fec_nac) ej_min, MAX(fec_nac) ej_max
FROM landing.siac_pers GROUP BY 1 ORDER BY n DESC;

-- name: S06 | Personas: FEC_NAC no parseable como DD/MM/AAAA o edad implausible
WITH p AS (SELECT id_pers, fec_nac, TRY_STRPTIME(fec_nac, '%d/%m/%Y') AS f FROM landing.siac_pers WHERE fec_nac IS NOT NULL)
SELECT CASE WHEN f IS NULL THEN 'no parsea DD/MM/AAAA'
            WHEN date_diff('year', f, DATE '2026-10-17') < 14 THEN 'edad < 14'
            WHEN date_diff('year', f, DATE '2026-10-17') > 80 THEN 'edad > 80' END AS problema,
       COUNT(*) n, list(fec_nac)[1:8] ejemplos
FROM p WHERE f IS NULL OR date_diff('year', f, DATE '2026-10-17') NOT BETWEEN 14 AND 80 GROUP BY 1;

-- name: S07 | Personas: correos inválidos o duplicados
SELECT 'formato inválido' tipo, COUNT(*) n, list(email)[1:8] ej FROM landing.siac_pers
WHERE email IS NOT NULL AND NOT regexp_matches(email, '^[^@\s]+@[^@\s]+\.[a-zA-Z]{2,}$')
UNION ALL
SELECT 'correo repetido (lower/trim)', COUNT(*), list(e)[1:8] FROM (
  SELECT lower(trim(email)) e FROM landing.siac_pers WHERE email IS NOT NULL GROUP BY 1 HAVING COUNT(*) > 1)
UNION ALL
SELECT 'con mayúsculas o espacios', COUNT(*), list(email)[1:5] FROM landing.siac_pers
WHERE email <> lower(trim(email));

-- name: S08 | Personas: formatos de celular
SELECT regexp_replace(tel_cel, '[0-9]', '9', 'g') AS patron, COUNT(*) n, MIN(tel_cel) ej
FROM landing.siac_pers GROUP BY 1 ORDER BY n DESC;

-- name: S09 | Personas: variantes de municipio
SELECT municipio, COUNT(*) n FROM landing.siac_pers GROUP BY 1 ORDER BY lower(strip_accents(municipio)), n DESC;

-- name: S10 | Personas sin registro de estudiante (aspirantes) y anuladas con estudiante
SELECT 'persona sin estudiante' caso, COUNT(*) n FROM landing.siac_pers p
WHERE NOT EXISTS (SELECT 1 FROM landing.siac_est e WHERE e.id_pers = p.id_pers)
UNION ALL
SELECT 'persona anulada con estudiante', COUNT(*) FROM landing.siac_pers p
WHERE p.ind_anul = 'S' AND EXISTS (SELECT 1 FROM landing.siac_est e WHERE e.id_pers = p.id_pers)
UNION ALL
SELECT 'estudiante con persona inexistente', COUNT(*) FROM landing.siac_est e
WHERE NOT EXISTS (SELECT 1 FROM landing.siac_pers p WHERE p.id_pers = e.id_pers);

-- name: S11 | Estudiantes: estado, programa, anulación
SELECT e.cod_prog, p.est_prog, e.est_estado, e.ind_anul, COUNT(*) n,
       COUNT(e.fec_grado) con_fec_grado
FROM landing.siac_est e JOIN landing.siac_prog p USING (cod_prog)
GROUP BY ALL ORDER BY 1, 3, 4;

-- name: S12 | Estudiantes: inconsistencias estado vs fecha de grado
SELECT CASE WHEN est_estado = 'G' AND fec_grado IS NULL THEN 'G sin FEC_GRADO'
            WHEN est_estado <> 'G' AND fec_grado IS NOT NULL THEN 'FEC_GRADO con estado ' || est_estado END caso,
       COUNT(*) n, list(cod_est)[1:8] ej
FROM landing.siac_est
WHERE (est_estado = 'G' AND fec_grado IS NULL) OR (est_estado <> 'G' AND fec_grado IS NOT NULL)
GROUP BY 1;

-- name: S13 | Estudiantes: misma persona con más de un registro (por programa)
SELECT n_registros, mismo_programa, COUNT(*) personas FROM (
  SELECT e.id_pers, COUNT(*) n_registros, COUNT(*) > COUNT(DISTINCT e.cod_prog) mismo_programa
  FROM landing.siac_est e GROUP BY 1 HAVING COUNT(*) > 1)
GROUP BY ALL ORDER BY 1;

-- name: S13b | Detalle: personas con varios registros de estudiante
SELECT e.id_pers, list(e.cod_est || ':' || e.cod_prog || ':' || e.est_estado || ':' || coalesce(e.cod_per_ing,'-') ORDER BY e.cod_est) registros
FROM landing.siac_est e GROUP BY 1 HAVING COUNT(*) > 1 ORDER BY 1 LIMIT 25;

-- name: S14 | Estudiantes: COD_EST vs periodo de ingreso (regla AAAAP + consecutivo)
SELECT regexp_replace(cod_est, '[0-9]', '9', 'g') patron_cod, COUNT(*) n,
       COUNT(*) FILTER (WHERE cod_per_ing IS NULL) sin_per_ing,
       COUNT(*) FILTER (WHERE cod_per_ing IS NOT NULL AND left(cod_est, 5) <> replace(cod_per_ing, '-', '')) cod_no_coincide_ingreso,
       COUNT(*) FILTER (WHERE cod_per_ing NOT IN (SELECT cod_per FROM landing.siac_per_acad)) per_ing_fuera_catalogo,
       MIN(cod_est) ej
FROM landing.siac_est GROUP BY 1 ORDER BY n DESC;

-- name: S14b | Estudiantes: periodo de ingreso distribución
SELECT cod_per_ing, COUNT(*) n FROM landing.siac_est GROUP BY 1 ORDER BY 1;

-- name: S15 | Matrículas: distribución por periodo, estado, tipo, anulación
SELECT cod_per, est_matr, tip_matr, ind_anul, COUNT(*) n FROM landing.siac_matr GROUP BY ALL ORDER BY ALL;

-- name: S16 | Matrículas duplicadas (mismo estudiante y periodo)
SELECT cod_est, cod_per, COUNT(*) n, list(id_matr ORDER BY id_matr) ids, list(est_matr) est, list(ind_anul) anul, list(fec_matr) fechas
FROM landing.siac_matr GROUP BY 1, 2 HAVING COUNT(*) > 1 ORDER BY n DESC, 1 LIMIT 30;

-- name: S16b | Matrículas duplicadas: resumen
SELECT COUNT(*) grupos, SUM(n) filas, SUM(n) FILTER (WHERE todas_validas) filas_en_grupos_sin_anular FROM (
  SELECT cod_est, cod_per, COUNT(*) n, bool_and(ind_anul = 'N' AND est_matr = 'M') todas_validas
  FROM landing.siac_matr GROUP BY 1, 2 HAVING COUNT(*) > 1);

-- name: S17 | Matrículas: programa distinto al del estudiante
SELECT m.cod_prog matr_prog, e.cod_prog est_prog, COUNT(*) n
FROM landing.siac_matr m JOIN landing.siac_est e USING (cod_est)
WHERE m.cod_prog <> e.cod_prog GROUP BY ALL ORDER BY n DESC;

-- name: S18 | Matrículas: fecha fuera de ventana razonable del periodo
SELECT m.cod_per,
       COUNT(*) FILTER (WHERE m.fec_matr::TIMESTAMP > p.fec_fin::TIMESTAMP) despues_fin,
       COUNT(*) FILTER (WHERE m.fec_matr::TIMESTAMP < p.fec_ini::TIMESTAMP - INTERVAL 120 DAY) mas_120d_antes_inicio,
       MIN(m.fec_matr) min_fec, MAX(m.fec_matr) max_fec
FROM landing.siac_matr m JOIN landing.siac_per_acad p USING (cod_per) GROUP BY 1 ORDER BY 1;

-- name: S19 | Matrículas: después del grado o de retiro, o de estudiantes anulados
SELECT 'matrícula posterior a FEC_GRADO' caso, COUNT(*) n FROM landing.siac_matr m JOIN landing.siac_est e USING (cod_est)
JOIN landing.siac_per_acad p ON p.cod_per = m.cod_per
WHERE e.fec_grado IS NOT NULL AND p.fec_ini::TIMESTAMP > e.fec_grado::TIMESTAMP
UNION ALL
SELECT 'matrícula de estudiante anulado', COUNT(*) FROM landing.siac_matr m JOIN landing.siac_est e USING (cod_est) WHERE e.ind_anul = 'S'
UNION ALL
SELECT 'matrícula anterior al periodo de ingreso', COUNT(*) FROM landing.siac_matr m JOIN landing.siac_est e USING (cod_est)
WHERE e.cod_per_ing IS NOT NULL AND m.cod_per < e.cod_per_ing
UNION ALL
SELECT 'tipo N (nuevo) que no es su primera matrícula', COUNT(*) FROM (
  SELECT tip_matr, ROW_NUMBER() OVER (PARTITION BY cod_est ORDER BY cod_per, id_matr::INT) rn FROM landing.siac_matr) WHERE tip_matr = 'N' AND rn > 1
UNION ALL
SELECT 'NUM_SEM mayor que semestres del programa', COUNT(*) FROM landing.siac_matr m JOIN landing.siac_prog p USING (cod_prog)
WHERE m.num_sem::INT > p.num_sem::INT;

-- name: S20 | Calificaciones: rangos y nulos
SELECT COUNT(*) filas,
       COUNT(*) FILTER (WHERE nota_def IS NULL) def_nula,
       COUNT(*) FILTER (WHERE nota_c1 IS NULL OR nota_c2 IS NULL OR nota_c3 IS NULL) algun_corte_nulo,
       COUNT(*) FILTER (WHERE greatest(nota_c1::DOUBLE, nota_c2::DOUBLE, nota_c3::DOUBLE, nota_def::DOUBLE) > 5) mayor_5,
       COUNT(*) FILTER (WHERE least(nota_c1::DOUBLE, nota_c2::DOUBLE, nota_c3::DOUBLE, nota_def::DOUBLE) < 0) menor_0,
       COUNT(*) FILTER (WHERE ind_anul = 'S') anuladas,
       MIN(nota_def::DOUBLE) min_def, MAX(nota_def::DOUBLE) max_def
FROM landing.siac_calif;

-- name: S20b | Calificaciones mayores a 5 (¿escala 0-50 o 0-100?)
SELECT nota_c1, nota_c2, nota_c3, nota_def, COUNT(*) n FROM landing.siac_calif
WHERE greatest(nota_c1::DOUBLE, nota_c2::DOUBLE, nota_c3::DOUBLE, nota_def::DOUBLE) > 5 GROUP BY ALL ORDER BY n DESC LIMIT 15;

-- name: S21 | Calificaciones: NOTA_DEF distinta de 30/30/40
SELECT round(abs(nota_def::DOUBLE - (0.3*nota_c1::DOUBLE + 0.3*nota_c2::DOUBLE + 0.4*nota_c3::DOUBLE)), 1) diferencia, COUNT(*) n
FROM landing.siac_calif WHERE nota_c1 IS NOT NULL AND nota_c2 IS NOT NULL AND nota_c3 IS NOT NULL AND nota_def IS NOT NULL
GROUP BY 1 ORDER BY 1;

-- name: S22 | Calificaciones: asignatura de otro programa, duplicadas, sobre matrícula cancelada/anulada
SELECT 'asignatura de otro programa' caso, COUNT(*) n FROM landing.siac_calif c
JOIN landing.siac_matr m USING (id_matr) JOIN landing.siac_asig a ON a.cod_asig = c.cod_asig WHERE a.cod_prog <> m.cod_prog
UNION ALL
SELECT 'misma matrícula y asignatura repetida', COUNT(*) FROM (SELECT id_matr, cod_asig FROM landing.siac_calif GROUP BY 1, 2 HAVING COUNT(*) > 1)
UNION ALL
SELECT 'nota sobre matrícula cancelada', COUNT(*) FROM landing.siac_calif c JOIN landing.siac_matr m USING (id_matr) WHERE m.est_matr = 'C'
UNION ALL
SELECT 'nota sobre matrícula anulada', COUNT(*) FROM landing.siac_calif c JOIN landing.siac_matr m USING (id_matr) WHERE m.ind_anul = 'S'
UNION ALL
SELECT 'nota del periodo vigente (2026-2, en curso)', COUNT(*) FROM landing.siac_calif c JOIN landing.siac_matr m USING (id_matr) WHERE m.cod_per = '2026-2'
UNION ALL
SELECT 'matrícula vigente sin ninguna nota', COUNT(*) FROM landing.siac_matr m WHERE m.est_matr = 'M' AND m.ind_anul = 'N'
AND NOT EXISTS (SELECT 1 FROM landing.siac_calif c WHERE c.id_matr = m.id_matr);

-- name: S22b | Calificaciones del periodo en curso por completitud de cortes
SELECT m.cod_per, (c.nota_c1 IS NOT NULL)::INT + (c.nota_c2 IS NOT NULL)::INT + (c.nota_c3 IS NOT NULL)::INT cortes, c.nota_def IS NOT NULL tiene_def, COUNT(*) n
FROM landing.siac_calif c JOIN landing.siac_matr m USING (id_matr) GROUP BY ALL ORDER BY ALL;

-- name: S23 | Asignaturas: programa inactivo y nombres repetidos entre programas
SELECT a.cod_prog, p.est_prog, COUNT(*) asignaturas, COUNT(DISTINCT a.nom_asig) nombres_distintos
FROM landing.siac_asig a JOIN landing.siac_prog p USING (cod_prog) GROUP BY ALL ORDER BY 1;

-- name: S24 | "Activo" según PKG_ESTADO_ESTUDIANTE vs EST_ESTADO del registro
WITH vig AS (SELECT '2026-2' AS per_vig, '2026-1' AS per_ant),
pkg AS (
  SELECT e.cod_est, e.est_estado, e.ind_anul,
    CASE WHEN e.fec_grado IS NOT NULL THEN 'GRADUADO'
         WHEN e.est_estado = 'R' THEN 'RETIRADO'
         WHEN EXISTS (SELECT 1 FROM landing.siac_matr m, vig WHERE m.cod_est = e.cod_est AND m.cod_per IN (vig.per_vig, vig.per_ant)) THEN 'ACTIVO'
         ELSE 'INACTIVO' END AS estado_pkg,
    EXISTS (SELECT 1 FROM landing.siac_matr m WHERE m.cod_est = e.cod_est AND m.cod_per = '2026-2' AND m.est_matr = 'M' AND m.ind_anul = 'N') AS matr_valida_2026_2
  FROM landing.siac_est e)
SELECT estado_pkg, est_estado, ind_anul, matr_valida_2026_2, COUNT(*) n FROM pkg GROUP BY ALL ORDER BY ALL;
