-- Validación de lo dicho por Registro y Control (Gloria Restrepo, 24/10/2026) contra los datos de SIAC.

-- name: G01 | "Se inscribieron con TI y luego los registraron otra vez con cédula": personas repetidas por nombre y nacimiento
WITH personas AS (
    SELECT id_pers, tip_doc, usu_reg,
           ltrim(regexp_replace(num_doc, '[^0-9]', '', 'g'), '0') AS doc,
           upper(strip_accents(trim(pri_nom || ' ' || pri_ape || ' ' || coalesce(seg_ape, '')))) AS nombre,
           fec_nac
    FROM landing.siac_pers
    WHERE ind_anul = 'N'
),
grupos AS (
    SELECT nombre, fec_nac, COUNT(*) AS registros,
           COUNT(DISTINCT doc) AS documentos_distintos,
           list(DISTINCT tip_doc ORDER BY tip_doc) AS tipos_doc
    FROM personas
    GROUP BY nombre, fec_nac
    HAVING COUNT(*) > 1
)
SELECT CASE WHEN documentos_distintos = 1 THEN 'mismo documento (formato distinto)'
            WHEN list_contains(tipos_doc, 'TI') THEN 'documento distinto: TI -> CC'
            ELSE 'documento distinto, mismo tipo' END AS caso,
       COUNT(*) AS personas_duplicadas,
       list(nombre)[1:5] AS ejemplos
FROM grupos GROUP BY ALL ORDER BY personas_duplicadas DESC;

-- name: G02 | Personas repetidas por documento normalizado: ¿cambió el tipo de documento entre registros?
WITH personas AS (
    SELECT id_pers, tip_doc, usu_reg, fec_reg,
           ltrim(regexp_replace(num_doc, '[^0-9]', '', 'g'), '0') AS doc
    FROM landing.siac_pers
    WHERE ind_anul = 'N'
),
grupos AS (
    SELECT doc, COUNT(*) AS registros,
           list(tip_doc ORDER BY fec_reg) AS tipos_en_orden,
           list(usu_reg ORDER BY fec_reg) AS usuarios_en_orden
    FROM personas GROUP BY doc HAVING COUNT(*) > 1
)
SELECT array_to_string(tipos_en_orden, ' -> ') AS cambio_tipo_doc,
       COUNT(*) AS personas,
       COUNT(*) FILTER (WHERE usuarios_en_orden[1] ILIKE '%WEB%') AS primero_por_web
FROM grupos GROUP BY ALL ORDER BY personas DESC;

-- name: G03 | "Los grados se hacen en ceremonias en marzo y septiembre": mes de FEC_GRADO
WITH grados AS (
    SELECT cod_est, est_estado, fec_grado,
           coalesce(TRY_STRPTIME(fec_grado, '%d/%m/%Y'), TRY_CAST(fec_grado AS TIMESTAMP)) AS f
    FROM landing.siac_est
    WHERE fec_grado IS NOT NULL AND ind_anul = 'N'
)
SELECT strftime(f, '%Y-%m') AS mes_grado, COUNT(*) AS graduados,
       COUNT(*) FILTER (WHERE est_estado <> 'G') AS estado_distinto_de_g,
       COUNT(*) FILTER (WHERE f IS NULL) AS fecha_no_parsea
FROM grados GROUP BY ALL ORDER BY 1;
