"""Parser del export semanal de SIAC (dialecto Oracle) a Parquet crudo.

No ejecuta el script: lee el DDL para conocer columnas y comentarios, y convierte cada
INSERT en una fila. Los valores se guardan como texto, sin interpretar, para que la
tipificación y las reglas de calidad vivan en la capa de staging y queden auditables.
"""
import argparse
import re
from datetime import datetime, timezone
from pathlib import Path

import pandas as pd

INSERT_RE = re.compile(r"^INSERT INTO (\w+) \(([^)]*)\) VALUES \((.*)\);$")
TOKEN_RE = re.compile(r"\s*(?:'((?:[^']|'')*)'|TO_DATE\('([^']*)','[^']*'\)|(NULL)|(-?\d+(?:\.\d+)?))\s*(?:,|$)")
CREATE_RE = re.compile(r"CREATE TABLE (\w+) \((.*?)\n\);", re.S)
COMMENT_RE = re.compile(r"COMMENT ON (TABLE|COLUMN) ([\w.]+) IS '((?:[^']|'')*)';")


def parse_values(raw):
    values, pos = [], 0
    while pos < len(raw):
        m = TOKEN_RE.match(raw, pos)
        if not m:
            raise ValueError(f"No se pudo interpretar: {raw[pos:pos + 80]}")
        text, date, null, number = m.groups()
        if null:
            values.append(None)
        elif date is not None:
            values.append(date)
        elif number is not None:
            values.append(number)
        else:
            values.append(text.replace("''", "'"))
        pos = m.end()
    return values


def parse_ddl(sql):
    tables = {}
    for name, body in CREATE_RE.findall(sql):
        cols = []
        for line in body.strip().splitlines():
            parts = line.strip().rstrip(",").split(None, 1)
            cols.append({"tabla": name, "columna": parts[0], "tipo_oracle": parts[1]})
        tables[name] = cols
    comments = {}
    for kind, target, text in COMMENT_RE.findall(sql):
        comments[(kind, target)] = text.replace("''", "'")
    rows = []
    for name, cols in tables.items():
        for c in cols:
            c["comentario"] = comments.get(("COLUMN", f"{name}.{c['columna']}"))
            c["comentario_tabla"] = comments.get(("TABLE", name))
            rows.append(c)
    return pd.DataFrame(rows)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--file", default="fuentes/registro/siac_export_2026_10_18.sql")
    ap.add_argument("--out", default="data/landing/siac")
    args = ap.parse_args()

    src = Path(args.file)
    sql = src.read_text(encoding="utf-8")
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    loaded_at = datetime.now(timezone.utc).isoformat(timespec="seconds")

    ddl = parse_ddl(sql)
    ddl.to_parquet(out / "_ddl.parquet", index=False)

    rows_by_table, cols_by_table = {}, {}
    for line_no, line in enumerate(sql.splitlines(), 1):
        m = INSERT_RE.match(line)
        if not m:
            continue
        table, cols, raw = m.groups()
        cols = [c.strip() for c in cols.split(",")]
        vals = parse_values(raw)
        if len(cols) != len(vals):
            raise ValueError(f"Línea {line_no}: {len(cols)} columnas y {len(vals)} valores")
        cols_by_table[table] = cols
        rows_by_table.setdefault(table, []).append(vals + [line_no])

    declared = dict(re.findall(r"REM INSERTANDO EN (\w+) \((\d+) REGISTROS\)", sql))
    for table, rows in rows_by_table.items():
        df = pd.DataFrame(rows, columns=cols_by_table[table] + ["_src_line"], dtype="string")
        df["_src_line"] = df["_src_line"].astype("int64")
        df["_src_file"] = src.name
        df["_loaded_at"] = loaded_at
        df.to_parquet(out / f"{table.lower()}.parquet", index=False)
        flag = "" if int(declared.get(table, -1)) == len(df) else f"  (el export declara {declared.get(table)})"
        print(f"{table}: {len(df)} filas{flag}")


if __name__ == "__main__":
    main()
