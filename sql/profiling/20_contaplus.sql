-- Perfilado de ContaPlus (Financiero). Cada consulta es autocontenida: los CTE iniciales
-- normalizan lo mínimo para poder medir (montos 1.234.567,89 y NIT con prefijos/puntos/DV),
-- y el SELECT final responde una sola pregunta de calidad.

-- name: F00 | Inventario de archivos: versión, columnas, filas y pie de página
SELECT archivo, version_contaplus, fecha_impresion, fecha_corte,
       filas_detalle, pie_total_registros, pie_total_valor, pie_total_terceros, pie_total_saldo,
       columnas LIKE '%CENTRO_COSTO%' AS trae_centro_costo
FROM landing.cp_archivos
ORDER BY archivo;

-- name: F01 | Conciliación por archivo: detalle vs pie de página (Martha: "siempre cuadran")
WITH recaudos AS (
    SELECT _src_file AS archivo,
           TRY_CAST(replace(replace(valor, '.', ''), ',', '.') AS DECIMAL(18, 2)) AS valor
    FROM landing.cp_recaudos
),
detalle AS (
    SELECT archivo, COUNT(*) AS filas, SUM(valor) AS valor
    FROM recaudos GROUP BY archivo
),
pie AS (
    SELECT archivo,
           pie_total_registros::INT AS filas,
           TRY_CAST(replace(replace(pie_total_valor, '.', ''), ',', '.') AS DECIMAL(18, 2)) AS valor
    FROM landing.cp_archivos WHERE archivo LIKE 'recaudos%'
)
SELECT COUNT(*) AS archivos,
       COUNT(*) FILTER (WHERE d.filas = p.filas AND d.valor = p.valor) AS cuadran,
       SUM(d.valor) AS valor_total_detalle
FROM detalle d JOIN pie p USING (archivo);

-- name: F02 | Recaudos cuya fecha no corresponde al mes del archivo
WITH recaudos AS (
    SELECT _src_file AS archivo, _periodo_archivo AS mes_archivo, comprobante,
           strptime(fecha, '%d/%m/%Y')::DATE AS fecha
    FROM landing.cp_recaudos
)
SELECT archivo, mes_archivo, strftime(fecha, '%Y-%m') AS mes_real,
       COUNT(*) AS filas, MIN(comprobante) AS desde, MAX(comprobante) AS hasta
FROM recaudos
WHERE strftime(fecha, '%Y-%m') <> mes_archivo
GROUP BY ALL ORDER BY archivo;

-- name: F03 | Comprobantes que aparecen en más de un archivo (doble carga)
WITH recaudos AS (
    SELECT comprobante, _src_file AS archivo, fecha, nit_tercero, concepto, valor,
           TRY_CAST(replace(replace(valor, '.', ''), ',', '.') AS DECIMAL(18, 2)) AS valor_num
    FROM landing.cp_recaudos
),
repetidos AS (
    SELECT comprobante,
           COUNT(*) AS veces,
           COUNT(DISTINCT archivo) AS archivos,
           COUNT(DISTINCT (fecha, nit_tercero, concepto, valor)) = 1 AS filas_identicas,
           MIN(archivo) AS primer_archivo, MAX(archivo) AS segundo_archivo,
           ANY_VALUE(valor_num) AS valor
    FROM recaudos GROUP BY comprobante HAVING COUNT(*) > 1
)
SELECT primer_archivo, segundo_archivo, COUNT(*) AS comprobantes, bool_and(filas_identicas) AS todas_identicas,
       MIN(comprobante) AS desde, MAX(comprobante) AS hasta, SUM(valor) AS valor_duplicado
FROM repetidos GROUP BY ALL;

-- name: F04 | Consecutivo de comprobantes: huecos (recibos faltantes)
WITH consecutivos AS (
    SELECT DISTINCT replace(comprobante, 'RC-', '')::INT AS n FROM landing.cp_recaudos
),
saltos AS (
    SELECT n, n - LAG(n) OVER (ORDER BY n) AS salto FROM consecutivos
)
SELECT MIN(n) AS primero, MAX(n) AS ultimo, COUNT(*) AS distintos, MAX(n) - MIN(n) + 1 AS esperados,
       COUNT(*) FILTER (WHERE salto > 1) AS huecos
FROM saltos;

-- name: F05 | Formatos del NIT del tercero (dígitos -> 9)
SELECT regexp_replace(nit_tercero, '[0-9]', '9', 'g') AS patron, COUNT(*) AS filas, MIN(nit_tercero) AS ejemplo
FROM landing.cp_recaudos
GROUP BY patron ORDER BY filas DESC;

-- name: F05b | NIT normalizado: cuántos terceros se "fusionan" al limpiar el formato
WITH nits AS (
    SELECT nit_tercero AS original,
           regexp_replace(upper(trim(nit_tercero)), '^(CC|CE|TI|NIT)\s*', '') AS sin_prefijo
    FROM landing.cp_recaudos
),
normalizados AS (
    SELECT original,
           ltrim(regexp_replace(split_part(sin_prefijo, '-', 1), '[^0-9]', '', 'g'), '0') AS nit_base,
           nullif(split_part(sin_prefijo, '-', 2), '') AS dv
    FROM nits
)
SELECT COUNT(DISTINCT original) AS nits_como_vienen,
       COUNT(DISTINCT nit_base) FILTER (WHERE nit_base <> '') AS nits_normalizados,
       COUNT(*) FILTER (WHERE nit_base = '') AS filas_sin_nit,
       COUNT(*) FILTER (WHERE dv IS NOT NULL) AS filas_con_dv,
       COUNT(*) FILTER (WHERE dv IS NOT NULL AND length(nit_base) <> 9) AS dv_en_documento_de_persona
FROM normalizados;

-- name: F06 | Pagos sin tercero identificable: NIT 999999999 o vacío
WITH recaudos AS (
    SELECT _periodo_archivo AS mes, concepto, detalle, nombre_tercero, forma_pago,
           regexp_replace(nit_tercero, '[^0-9]', '', 'g') AS nit_digitos,
           TRY_CAST(replace(replace(valor, '.', ''), ',', '.') AS DECIMAL(18, 2)) AS valor
    FROM landing.cp_recaudos
),
sin_identificar AS (
    SELECT *, CASE WHEN nit_digitos = '' THEN 'NIT vacío' ELSE 'NIT 999999999' END AS caso
    FROM recaudos WHERE nit_digitos = '' OR nit_digitos LIKE '999999999%'
)
SELECT caso, COUNT(*) AS filas, SUM(valor) AS valor, MIN(mes) AS desde, MAX(mes) AS hasta,
       list(DISTINCT nombre_tercero)[1:4] AS nombres, list(DISTINCT detalle)[1:5] AS detalles
FROM sin_identificar GROUP BY caso;

-- name: F07 | Conceptos por versión del software (cambio de códigos en jul-2025)
WITH recaudos AS (
    SELECT concepto, detalle, _periodo_archivo AS mes,
           CASE WHEN centro_costo IS NULL THEN 'v3.2' ELSE 'v3.2.7' END AS version,
           TRY_CAST(replace(replace(valor, '.', ''), ',', '.') AS DECIMAL(18, 2)) AS valor
    FROM landing.cp_recaudos
)
SELECT version, concepto, c.descripcion, COUNT(*) AS filas, SUM(valor) AS valor,
       MIN(mes) AS desde, MAX(mes) AS hasta
FROM recaudos r LEFT JOIN landing.cp_conceptos c ON c.codigo = r.concepto
GROUP BY ALL ORDER BY version, concepto;

-- name: F08 | Centro de costo vacío en la versión que sí lo exige
WITH v327 AS (
    SELECT * FROM landing.cp_recaudos WHERE centro_costo IS NOT NULL
)
SELECT concepto, _periodo_archivo AS mes, COUNT(*) AS filas, list(DISTINCT detalle)[1:4] AS detalles
FROM v327 WHERE trim(centro_costo) = ''
GROUP BY ALL ORDER BY mes;

-- name: F09 | Montos: negativos (devoluciones/reversiones) y rango por concepto
WITH recaudos AS (
    SELECT concepto, detalle,
           TRY_CAST(replace(replace(valor, '.', ''), ',', '.') AS DECIMAL(18, 2)) AS valor
    FROM landing.cp_recaudos
)
SELECT concepto,
       COUNT(*) AS filas,
       COUNT(*) FILTER (WHERE valor IS NULL) AS no_parsea,
       COUNT(*) FILTER (WHERE valor < 0) AS negativos,
       SUM(valor) FILTER (WHERE valor < 0) AS valor_negativo,
       MIN(valor) AS minimo, median(valor) AS mediana, MAX(valor) AS maximo
FROM recaudos GROUP BY concepto ORDER BY concepto;

-- name: F09b | Detalle de los montos negativos
WITH negativos AS (
    SELECT _periodo_archivo AS mes, concepto, detalle,
           TRY_CAST(replace(replace(valor, '.', ''), ',', '.') AS DECIMAL(18, 2)) AS valor
    FROM landing.cp_recaudos
)
SELECT regexp_replace(upper(detalle), '20[0-9]{2}-?[12]', '<PER>', 'g') AS tipo, concepto,
       COUNT(*) AS filas, SUM(valor) AS valor, MIN(mes) AS desde, MAX(mes) AS hasta
FROM negativos WHERE valor < 0 GROUP BY ALL ORDER BY filas DESC;

-- name: F10 | El periodo académico solo vive en texto libre (DETALLE)
WITH recaudos AS (
    SELECT CASE WHEN concepto IN ('MAT', '1105') THEN 'matrícula'
                WHEN concepto IN ('INS', '1110') THEN 'inscripción'
                ELSE 'otros' END AS grupo,
           regexp_extract(detalle, '(20[0-9]{2})-?([12])\b', 0) AS periodo_texto
    FROM landing.cp_recaudos
)
SELECT grupo, COUNT(*) AS filas,
       COUNT(*) FILTER (WHERE periodo_texto <> '') AS con_periodo,
       COUNT(*) FILTER (WHERE periodo_texto <> '' AND periodo_texto NOT LIKE '____-_') AS periodo_sin_guion
FROM recaudos GROUP BY grupo ORDER BY grupo;

-- name: F11 | Mismo NIT normalizado con nombres distintos
WITH recaudos AS (
    SELECT nombre_tercero,
           ltrim(regexp_replace(split_part(regexp_replace(upper(trim(nit_tercero)), '^(CC|CE|TI|NIT)\s*', ''), '-', 1), '[^0-9]', '', 'g'), '0') AS nit
    FROM landing.cp_recaudos
),
nombres AS (
    SELECT nit, COUNT(DISTINCT nombre_tercero) AS variantes, list(DISTINCT nombre_tercero) AS ejemplos
    FROM recaudos WHERE nit <> '' AND nit NOT LIKE '999999999%' GROUP BY nit
)
SELECT COUNT(*) AS nits, COUNT(*) FILTER (WHERE variantes > 1) AS nits_con_varios_nombres,
       list(ejemplos) FILTER (WHERE variantes > 1)[1:6] AS ejemplos
FROM nombres;

-- name: F12 | Pagadores persona jurídica: convenios empresariales (un pago cubre varios estudiantes)
WITH recaudos AS (
    SELECT nit_tercero, nombre_tercero, detalle, _periodo_archivo AS mes,
           ltrim(regexp_replace(split_part(nit_tercero, '-', 1), '[^0-9]', '', 'g'), '0') AS nit,
           TRY_CAST(replace(replace(valor, '.', ''), ',', '.') AS DECIMAL(18, 2)) AS valor
    FROM landing.cp_recaudos
)
SELECT nit_tercero, nombre_tercero, COUNT(*) AS pagos, SUM(valor) AS valor,
       list(regexp_extract(detalle, '\((\d+) ESTUDIANTES\)', 1)) AS estudiantes_por_pago
FROM recaudos
WHERE regexp_matches(nit, '^[89][0-9]{8}$') AND nit NOT LIKE '999999999%'
GROUP BY ALL ORDER BY valor DESC;

-- name: F13 | Tarifas: cambios de precio por concepto y año
WITH recaudos AS (
    SELECT left(_periodo_archivo, 4) AS anio,
           CASE WHEN concepto IN ('INS', '1110') THEN 'inscripción'
                WHEN concepto IN ('CER', '1130') THEN 'certificados' END AS grupo,
           TRY_CAST(replace(replace(valor, '.', ''), ',', '.') AS DECIMAL(18, 2)) AS valor
    FROM landing.cp_recaudos
)
SELECT grupo, anio, valor, COUNT(*) AS filas
FROM recaudos WHERE grupo IS NOT NULL AND valor > 0
GROUP BY ALL ORDER BY grupo, anio, filas DESC;

-- name: F14 | Cartera: consistencia interna (saldo, mora, pie de página)
WITH cartera AS (
    SELECT nit_tercero, periodo, acuerdo_pago, dias_mora::INT AS dias_mora,
           strptime(fecha_vencimiento, '%d/%m/%Y')::DATE AS vencimiento,
           TRY_CAST(replace(replace(valor_facturado, '.', ''), ',', '.') AS DECIMAL(18, 2)) AS facturado,
           TRY_CAST(replace(replace(valor_abonado, '.', ''), ',', '.') AS DECIMAL(18, 2)) AS abonado,
           TRY_CAST(replace(replace(saldo, '.', ''), ',', '.') AS DECIMAL(18, 2)) AS saldo
    FROM landing.cp_cartera
),
pie AS (
    SELECT pie_total_terceros::INT AS terceros,
           TRY_CAST(replace(replace(pie_total_saldo, '.', ''), ',', '.') AS DECIMAL(18, 2)) AS saldo
    FROM landing.cp_archivos WHERE archivo LIKE 'cartera%'
)
SELECT COUNT(*) AS filas,
       COUNT(DISTINCT nit_tercero) AS nits_distintos,
       (SELECT terceros FROM pie) AS pie_terceros,
       SUM(saldo) AS saldo_detalle, (SELECT saldo FROM pie) AS pie_saldo,
       COUNT(*) FILTER (WHERE facturado - abonado <> saldo) AS saldo_inconsistente,
       COUNT(*) FILTER (WHERE date_diff('day', vencimiento, DATE '2026-09-30') <> dias_mora) AS mora_inconsistente,
       COUNT(*) FILTER (WHERE abonado > 0 AND acuerdo_pago = 'N') AS abono_sin_acuerdo,
       COUNT(*) FILTER (WHERE abonado = 0 AND acuerdo_pago = 'S') AS acuerdo_sin_abono
FROM cartera;

-- name: F14b | Cartera: composición por periodo y acuerdo de pago
WITH cartera AS (
    SELECT periodo, acuerdo_pago, dias_mora::INT AS dias_mora,
           TRY_CAST(replace(replace(saldo, '.', ''), ',', '.') AS DECIMAL(18, 2)) AS saldo
    FROM landing.cp_cartera
)
SELECT periodo, acuerdo_pago, COUNT(*) AS filas, SUM(saldo) AS saldo, MIN(dias_mora) AS mora_min, MAX(dias_mora) AS mora_max
FROM cartera GROUP BY ALL ORDER BY ALL;

-- name: F15 | Cartera vs recaudos: ¿el abono de cartera coincide con los pagos de matrícula del periodo?
WITH cartera AS (
    SELECT ltrim(regexp_replace(split_part(nit_tercero, '-', 1), '[^0-9]', '', 'g'), '0') AS nit, periodo,
           TRY_CAST(replace(replace(valor_abonado, '.', ''), ',', '.') AS DECIMAL(18, 2)) AS abonado
    FROM landing.cp_cartera
),
pagos AS (
    SELECT ltrim(regexp_replace(split_part(regexp_replace(upper(nit_tercero), '^(CC|CE|TI)\s*', ''), '-', 1), '[^0-9]', '', 'g'), '0') AS nit,
           regexp_replace(regexp_extract(detalle, '(20[0-9]{2})-?([12])\b', 0), '^(\d{4})-?(\d)$', '\1-\2') AS periodo,
           TRY_CAST(replace(replace(valor, '.', ''), ',', '.') AS DECIMAL(18, 2)) AS valor,
           comprobante
    FROM landing.cp_recaudos
    WHERE concepto IN ('MAT', '1105')
),
pagos_unicos AS (
    SELECT DISTINCT ON (comprobante) * FROM pagos
),
pagado AS (
    SELECT nit, periodo, SUM(valor) AS pagado FROM pagos_unicos WHERE periodo <> '' GROUP BY ALL
)
SELECT CASE WHEN p.pagado IS NULL THEN 'cartera sin pagos de matrícula en recaudos'
            WHEN p.pagado = c.abonado THEN 'abono de cartera = pagos en recaudos'
            ELSE 'abono de cartera <> pagos en recaudos' END AS caso,
       COUNT(*) AS filas, SUM(c.abonado) AS abonado_cartera, SUM(p.pagado) AS pagado_recaudos
FROM cartera c LEFT JOIN pagado p USING (nit, periodo)
GROUP BY caso;

-- name: F16 | Valores de matrícula por centro de costo y año frente a la tarifa plena (descuentos 10/15 % y cuotas 40/30/30)
WITH pagos AS (
    SELECT DISTINCT ON (comprobante)
           coalesce(centro_costo, '(sin cc)') AS cc, right(fecha, 4) AS anio,
           TRY_CAST(replace(replace(valor, '.', ''), ',', '.') AS DECIMAL(18, 2)) AS valor
    FROM landing.cp_recaudos
    WHERE concepto IN ('MAT', '1105')
),
tarifas AS (
    SELECT cc, anio, valor, COUNT(*) AS n FROM pagos WHERE valor > 0 GROUP BY ALL
),
plena AS (
    SELECT cc, anio, max(valor) AS tarifa FROM tarifas WHERE n >= 5 GROUP BY ALL
)
SELECT t.cc, t.anio, p.tarifa, t.valor, t.n, round(t.valor / p.tarifa, 3) AS proporcion_de_la_tarifa
FROM tarifas t JOIN plena p USING (cc, anio)
WHERE t.n >= 3 AND t.cc <> '(sin cc)'
ORDER BY t.cc, t.anio, t.valor DESC;

-- name: F17 | Valor real del Diplomado en Analítica de Datos
SELECT concepto, detalle, valor, COUNT(*) AS pagos
FROM landing.cp_recaudos
WHERE upper(detalle) LIKE '%DIPLOM%'
GROUP BY ALL ORDER BY pagos DESC;
