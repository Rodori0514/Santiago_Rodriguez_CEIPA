# Prueba técnica Ingeniero(a) de Datos · CEIPA

Santiago Rodríguez Zapata

Diagnóstico, calidad, gobierno y arquitectura de datos para las tres fuentes de CEIPA (Registro y Control en
SIAC, Financiero en ContaPlus y Comercial en VentasCloud), más una bodega local con modelo estrella y un proceso
de carga reproducible.

## Entregables

|Punto|Dónde|
|-|-|
|1 a 4: diagnóstico de fuentes, hallazgos de calidad, gobierno de datos y arquitectura en Azure, más el uso de IA|[`docs/documento\_entrega.md`](docs/documento_entrega.md)|
|Conversaciones con las áreas y contraste con los datos|[`docs/entrevistas.md`](docs/entrevistas.md)|
|Consultas que respaldan cada cifra del documento|[`sql/profiling/`](sql/profiling/)|
|Bonus: bodega local con modelo estrella y carga reproducible|Este README, `src/` y `sql/etl/`|

## Requisitos

* Python 3.11 o superior (probado con 3.14).
* No hace falta servidor de base de datos: la bodega es un archivo DuckDB.

```bash
python -m venv .venv
# Windows
.venv\\Scripts\\activate
# Linux / macOS
source .venv/bin/activate

pip install -r requirements.txt
```

## Ejecutar todo

```bash
python src/pipeline.py
```

En unos 15 segundos el proceso:

1. Descomprime la carpeta de ContaPlus desde el ZIP si todavía no existe.
2. Registra la huella SHA-256 de cada archivo de entrada (`audit.archivo\_fuente`).
3. Lleva las tres fuentes a la capa landing en Parquet, con todo como texto y con archivo, línea y fecha de carga
en cada fila (`data/landing/`).
4. Construye la capa plata (`sql/etl/10\_silver.sql`), la capa oro con el modelo estrella (`sql/etl/20\_gold.sql`)
y evalúa las 18 reglas de calidad (`sql/etl/30\_calidad.sql`).
5. Muestra las filas de cada tabla de oro, los indicadores por periodo y el resultado de las reglas de calidad.

El resultado queda en `data/warehouse.duckdb`. Se puede ejecutar las veces que se quiera: cada ejecución
reconstruye plata y oro desde los archivos de origen y agrega su bitácora en `audit` con un `run\_id` propio.

> En Windows con PowerShell, si la consola muestra mal las tildes, ejecute antes `$env:PYTHONUTF8=1`.

### Volver a extraer el CRM desde la API

Los JSON del CRM ya están en `fuentes/comercial/`, así que la carga funciona sin conexión. Para traerlos de
nuevo desde VentasCloud:

```bash
cp .env.example .env          # y poner la key personal en VENTASCLOUD\_API\_KEY
python src/pipeline.py --crm-api
```

El extractor (`src/extract/ventascloud.py`) pagina con cursor de 100 en 100, respeta el límite de 60 solicitudes
por minuto y el `Retry-After` de las respuestas 429. Con `--updated-since` hace una extracción incremental. La key
se lee solo de la variable de entorno; `.env` está excluido del repositorio.

## Estructura del repositorio

```text
fuentes/                 datos tal como los entregó cada área (export SIAC, ZIP de ContaPlus, JSON del CRM)
seeds/                   tablas de homologación acordadas: programas, conceptos de ContaPlus y etapas del CRM
src/
  pipeline.py            orquestador de la carga completa
  run\_sql.py             ejecuta archivos .sql y muestra cada resultado
  extract/               un extractor por fuente hacia landing (siac, contaplus, crm\_landing, ventascloud)
sql/
  00\_landing\_views.sql   vistas sobre los Parquet de landing
  etl/                   plata, oro y reglas de calidad
  profiling/             consultas del diagnóstico; cada hallazgo del documento cita la consulta que lo prueba
docs/                    documento de entrega y conversaciones con las áreas
data/                    se genera al ejecutar (landing y bodega); no se versiona
```

## Capas

|Capa|Dónde|Qué contiene|
|-|-|-|
|Landing (bronce)|`data/landing/\*.parquet` y esquema `landing`|Copia fiel del origen, todo como texto, con `\_src\_file`, `\_src\_line` y `\_loaded\_at`|
|Plata|esquema `silver`|Tipos convertidos, documentos normalizados, catálogos homologados, recaudos sin duplicados, notas recalculadas y la tabla de identidad `persona\_xref`|
|Oro|esquema `gold`|Modelo estrella y vista de indicadores|
|Auditoría|esquema `audit`|`run\_log` (pasos y tiempos), `archivo\_fuente` (huellas) y `dq\_resultado` (reglas de calidad por ejecución)|

## Modelo estrella

```mermaid
erDiagram
    dim\_persona ||--o{ fact\_matricula : ""
    dim\_persona ||--o{ fact\_recaudo : ""
    dim\_persona ||--o{ fact\_oportunidad : ""
    dim\_persona ||--o{ fact\_calificacion : ""
    dim\_programa ||--o{ fact\_matricula : ""
    dim\_programa ||--o{ fact\_recaudo : ""
    dim\_programa ||--o{ fact\_oportunidad : ""
    dim\_programa ||--o{ fact\_calificacion : ""
    dim\_periodo ||--o{ fact\_matricula : ""
    dim\_periodo ||--o{ fact\_recaudo : ""
    dim\_periodo ||--o{ fact\_oportunidad : ""
    dim\_periodo ||--o{ fact\_calificacion : ""
    dim\_fecha ||--o{ fact\_matricula : "fecha de matrícula"
    dim\_fecha ||--o{ fact\_recaudo : "fecha de pago"
    dim\_fecha ||--o{ fact\_oportunidad : "creación y cierre"
    dim\_fecha ||--o{ fact\_calificacion : "registro"
    dim\_concepto ||--o{ fact\_recaudo : ""
    dim\_canal ||--o{ fact\_matricula : "canal de la oportunidad ganada"
    dim\_canal ||--o{ fact\_oportunidad : ""

    dim\_persona {
        int persona\_sk PK
        varchar persona\_key "documento normalizado o SISTEMA:id"
        varchar doc\_norm
        varchar nombre
        boolean en\_siac
        boolean en\_crm
        boolean en\_contaplus
        varchar reglas\_cruce
    }
    dim\_programa {
        int programa\_sk PK
        varchar programa\_id "ADM, CON, NEG, MER, ING, EGP, TGC, DAD"
        varchar nivel
        varchar centro\_costo
        varchar codigos\_siac
        varchar codigos\_crm
    }
    dim\_periodo {
        int periodo\_sk PK
        varchar cod\_per
        date fec\_ini
        date fec\_fin
    }
    dim\_fecha {
        int fecha\_sk PK "AAAAMMDD"
        date fecha
        varchar periodo\_academico
    }
    dim\_concepto {
        int concepto\_sk PK
        varchar codigo "código v3.2.7"
        varchar codigo\_anterior "código v3.2"
        varchar grupo
        varchar cuenta\_contable
    }
    dim\_canal {
        int canal\_sk PK
        varchar canal
    }
    fact\_matricula {
        int matricula\_id "una fila por matrícula válida"
        boolean es\_nuevo
        boolean tiene\_oportunidad\_ganada
        decimal valor\_pagado\_matricula
        decimal saldo\_cartera
    }
    fact\_recaudo {
        varchar comprobante "una fila por comprobante"
        decimal valor
        boolean es\_devolucion
        boolean es\_convenio
        int veces\_en\_archivos
    }
    fact\_oportunidad {
        varchar oportunidad\_id
        varchar etapa
        varchar estado
        boolean matricula\_confirmada
        int dias\_cierre\_a\_matricula
        boolean abierta\_vencida
    }
    fact\_calificacion {
        int calificacion\_id
        decimal nota\_def\_siac
        decimal nota\_def\_calculada "30/30/40"
        boolean fuera\_de\_rango
        boolean definitiva\_inconsistente
    }
```

Decisiones del modelo:

* **Una persona, tres sistemas.** La llave es el documento normalizado: sin prefijos de tipo, sin dígito de
verificación y sin ceros a la izquierda. Si no hay documento, se cruza por correo y primer apellido y luego por
celular y primer apellido. Cada cruce queda en `silver.persona\_xref` con la regla que lo produjo. Los atributos
de la persona se toman primero de SIAC, luego del CRM y luego de ContaPlus.
* **Miembro "no identificado" (`sk = 0`)** en todas las dimensiones. Así ningún hecho se pierde: por ejemplo, los
pagos con tercero 999999999 o con NIT de empresa quedan en `fact\_recaudo` con `persona\_sk = 0`.
* **Granos:** una matrícula válida de SIAC (estado M, no anulada); un comprobante de caja (los 88 comprobantes
repetidos entre archivos quedan una sola vez, con `veces\_en\_archivos`); una oportunidad del CRM; una nota no
anulada.
* **Homologaciones en `seeds/`:** son las tablas que el documento propone acordar con cada dueño (el código de
Administración que cambió en 2025-2, los conceptos de ContaPlus v3.2 frente a v3.2.7 y las etapas del CRM en
inglés y en español). Al ser CSV versionados, un cambio acordado con el área queda en el historial de Git.
* **Trazabilidad:** los hechos conservan `\_src\_file` y `\_src\_line`, así que cualquier cifra se puede seguir hasta
la línea exacta del archivo de origen.

Validación de la carga actual: llaves únicas en las dimensiones y en los hechos, cero llaves foráneas huérfanas,
612 matriculados en 2026-2 (la misma cifra del perfilado) y los 3.317 renglones de recaudo reducidos a 3.229
comprobantes.

## Consultas de ejemplo

```bash
python src/run\_sql.py sql/profiling/40\_cruces.sql      # cualquier archivo de perfilado
```

Desde Python o cualquier cliente de DuckDB (por ejemplo, DBeaver) sobre `data/warehouse.duckdb`:

```sql
-- Matriculados nuevos por programa y canal en 2026-2
SELECT p.programa, c.canal, SUM(f.matriculas) AS nuevos
FROM gold.fact\_matricula f
JOIN gold.dim\_programa p USING (programa\_sk)
JOIN gold.dim\_periodo pe USING (periodo\_sk)
JOIN gold.dim\_canal c USING (canal\_sk)
WHERE pe.cod\_per = '2026-2' AND f.es\_nuevo
GROUP BY ALL ORDER BY nuevos DESC;

-- Reglas de calidad de la última ejecución
SELECT \* FROM audit.dq\_resultado
WHERE run\_id = (SELECT max(run\_id) FROM audit.dq\_resultado)
ORDER BY regla;
```

## Paso a Azure

El proceso está escrito para trasladarse a la arquitectura del punto 4 sin reescribirlo:

* `data/landing/` se convierte en el contenedor de bronce de ADLS Gen2, con la misma estructura de Parquet.
* Los extractores y `pipeline.py` corren como Azure Container Apps Jobs, programados por Data Factory. El SIAC y
la carpeta de ContaPlus llegan a bronce a través del Self-hosted Integration Runtime.
* Los SQL de plata, oro y calidad se ejecutan igual con DuckDB sobre ADLS. Si se prefiere, se trasladan casi
sin cambios a Azure SQL o a Fabric, porque solo usan SQL estándar con CTE.
* La key del CRM pasa de `.env` a Key Vault, y `audit.run\_log` y `audit.dq\_resultado` alimentan Log Analytics y
el tablero de calidad de cada dueño.

## Seguridad

El repositorio no contiene la API key ni ningún otro secreto. `.env` está en `.gitignore` y `.env.example` solo
muestra el nombre de la variable.

