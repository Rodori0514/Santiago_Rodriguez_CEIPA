"""Ejecuta archivos .sql sobre la base DuckDB y muestra cada resultado.

Cada consulta dentro de un archivo se separa con una línea `-- name: <id> | <descripción>`.
"""
import argparse
import re
import sys
from pathlib import Path

import duckdb

NAME_RE = re.compile(r"^--\s*name:\s*(.+)$", re.M)


def split_queries(text):
    parts = NAME_RE.split(text)
    if len(parts) == 1:
        return [("(sin nombre)", text)]
    preamble = [("(preámbulo)", parts[0])] if parts[0].strip() else []
    return preamble + [(parts[i].strip(), parts[i + 1]) for i in range(1, len(parts), 2)]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("files", nargs="+")
    ap.add_argument("--db", default="data/warehouse.duckdb")
    ap.add_argument("--max-rows", type=int, default=30)
    args = ap.parse_args()

    con = duckdb.connect(args.db)
    failed = False
    for f in args.files:
        for name, sql in split_queries(Path(f).read_text(encoding="utf-8")):
            if not sql.strip().strip(";").strip():
                continue
            print(f"\n=== {Path(f).name} :: {name}")
            try:
                rel = con.sql(sql)
                if rel is not None:
                    rel.show(max_rows=args.max_rows, max_width=250)
            except duckdb.Error as e:
                failed = True
                print(f"ERROR: {e}")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
