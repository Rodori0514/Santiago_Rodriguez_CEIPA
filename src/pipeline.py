"""Proceso de carga completo y reproducible: fuentes -> landing -> plata -> oro -> reglas de calidad.

Uso:
    python src/pipeline.py              # usa los archivos ya descargados en fuentes/
    python src/pipeline.py --crm-api    # vuelve a extraer el CRM por API (requiere VENTASCLOUD_API_KEY en .env)

Cada ejecución queda registrada en audit.run_log (pasos y tiempos), audit.archivo_fuente (huella SHA-256 de
cada archivo de entrada) y audit.dq_resultado (resultado de las reglas de calidad).
"""
import argparse
import hashlib
import os
import subprocess
import sys
import time
import uuid
import zipfile
from datetime import datetime
from pathlib import Path

import duckdb

ROOT = Path(__file__).resolve().parent.parent
CONTAPLUS_ZIP = Path("fuentes/financiero/financiero_carpeta_compartida.zip")
CONTAPLUS_DIR = Path("fuentes/financiero/financiero_carpeta_compartida")
EXTRACTORES = ["src/extract/siac.py", "src/extract/contaplus.py", "src/extract/crm_landing.py"]
SQL_PASOS = ["sql/00_landing_views.sql", "sql/etl/10_silver.sql", "sql/etl/20_gold.sql", "sql/etl/30_calidad.sql"]
TABLAS_ORO = ["dim_persona", "dim_programa", "dim_periodo", "dim_fecha", "dim_concepto", "dim_canal",
              "fact_matricula", "fact_recaudo", "fact_oportunidad", "fact_calificacion"]

AUDIT_DDL = """
CREATE SCHEMA IF NOT EXISTS audit;
CREATE TABLE IF NOT EXISTS audit.run_log (
    run_id VARCHAR, paso VARCHAR, inicio TIMESTAMP, fin TIMESTAMP, segundos DOUBLE, estado VARCHAR, detalle VARCHAR);
CREATE TABLE IF NOT EXISTS audit.archivo_fuente (
    run_id VARCHAR, archivo VARCHAR, bytes BIGINT, sha256 VARCHAR, registrado TIMESTAMP);
"""


def run(con, sql, params=None):
    """Ejecuta y consume el resultado completo (DuckDB 2.x no admite resultados a medio leer)."""
    return con.execute(sql, params or []).fetchall()


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


class Corrida:
    def __init__(self, con):
        self.con = con
        self.run_id = datetime.now().strftime("%Y%m%d_%H%M%S_") + uuid.uuid4().hex[:6]

    def paso(self, nombre, fn):
        inicio = datetime.now()
        t0 = time.perf_counter()
        print(f"-> {nombre}")
        try:
            detalle = fn()
            estado = "ok"
        except Exception as e:
            detalle, estado = str(e)[:500], "error"
        run(self.con, "INSERT INTO audit.run_log VALUES (?, ?, ?, ?, ?, ?, ?)",
            [self.run_id, nombre, inicio, datetime.now(), round(time.perf_counter() - t0, 2), estado, detalle])
        if estado == "error":
            raise SystemExit(f"Falló el paso '{nombre}': {detalle}")


def preparar_contaplus():
    if not CONTAPLUS_DIR.exists():
        with zipfile.ZipFile(CONTAPLUS_ZIP) as z:
            z.extractall(CONTAPLUS_DIR.parent)
        return "carpeta descomprimida desde el ZIP"
    return "carpeta ya disponible"


def registrar_fuentes(con, run_id):
    archivos = sorted(p for p in Path("fuentes").rglob("*") if p.is_file() and p.suffix in {".sql", ".txt", ".json"})
    for p in archivos:
        run(con, "INSERT INTO audit.archivo_fuente VALUES (?, ?, ?, ?, now())",
            [run_id, p.as_posix(), p.stat().st_size, sha256(p)])
    return f"{len(archivos)} archivos"


def ejecutar_script(script):
    r = subprocess.run([sys.executable, script], capture_output=True, text=True, encoding="utf-8")
    if r.returncode != 0:
        raise RuntimeError(r.stderr.strip()[-500:])
    return " | ".join(line for line in r.stdout.splitlines() if line.strip())[:500]


def ejecutar_sql(con, archivo):
    run(con, Path(archivo).read_text(encoding="utf-8"))
    return archivo


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--db", default="data/warehouse.duckdb")
    ap.add_argument("--crm-api", action="store_true", help="re-extraer VentasCloud por API antes de cargar")
    args = ap.parse_args()

    os.chdir(ROOT)
    os.environ.setdefault("PYTHONUTF8", "1")
    Path(args.db).parent.mkdir(parents=True, exist_ok=True)
    con = duckdb.connect(args.db)
    run(con, AUDIT_DDL)
    corrida = Corrida(con)
    run(con, "SET VARIABLE run_id = ?", [corrida.run_id])
    print(f"Ejecución {corrida.run_id}")

    if args.crm_api:
        corrida.paso("extraer VentasCloud (API)", lambda: ejecutar_script("src/extract/ventascloud.py"))
    corrida.paso("preparar carpeta de ContaPlus", preparar_contaplus)
    corrida.paso("registrar huella de las fuentes", lambda: registrar_fuentes(con, corrida.run_id))
    for script in EXTRACTORES:
        corrida.paso(f"landing: {Path(script).stem}", lambda s=script: ejecutar_script(s))
    for archivo in SQL_PASOS:
        corrida.paso(f"sql: {archivo}", lambda a=archivo: ejecutar_sql(con, a))

    print("\nFilas en la capa oro:")
    for t in TABLAS_ORO:
        print(f"  gold.{t:<18} {run(con, f'SELECT COUNT(*) FROM gold.{t}')[0][0]:>7,}")

    print("\nIndicadores por periodo (gold.v_indicadores_periodo):")
    con.sql("SELECT * FROM gold.v_indicadores_periodo").show(max_width=250)

    print("Reglas de calidad de esta ejecución (audit.dq_resultado):")
    con.sql("""
        SELECT regla, fuente, severidad, registros_evaluados AS evaluados, registros_con_falla AS fallas
        FROM audit.dq_resultado WHERE run_id = getvariable('run_id') ORDER BY regla
    """).show(max_rows=50, max_width=250)
    con.close()


if __name__ == "__main__":
    main()
