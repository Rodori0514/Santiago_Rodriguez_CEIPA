"""Parser de los informes planos de ContaPlus (carpeta compartida de Financiero) a Parquet crudo.

Los informes traen 3 líneas de encabezado (título con versión, fecha de impresión/corte y
una línea de guiones), la fila de nombres de columna, el detalle y una línea de totales.
Los valores se conservan como texto; el pie de página se guarda aparte para conciliar.
"""
import argparse
import re
from datetime import datetime, timezone
from pathlib import Path

import pandas as pd

ENCODING = "cp1252"
VERSION_RE = re.compile(r"CONTAPLUS v([\d.]+)")
PRINT_RE = re.compile(r"FECHA DE IMPRESION: (\d{2}/\d{2}/\d{4} \d{2}:\d{2}:\d{2})")
CORTE_RE = re.compile(r"CORTE: (\d{2}/\d{2}/\d{4})")


def read_report(path):
    lines = path.read_text(encoding=ENCODING).splitlines()
    title, info = lines[0], lines[1]
    columns = lines[3].split(";")
    data, footer = [], {}
    for line_no, line in enumerate(lines[4:], 5):
        if line.startswith("TOTAL"):
            for part in line.split(";"):
                k, v = part.split(":", 1)
                footer[k.strip()] = v.strip()
            continue
        if line.strip():
            data.append(line.split(";") + [line_no])
    df = pd.DataFrame(data, columns=columns + ["_src_line"], dtype="string")
    df["_src_line"] = df["_src_line"].astype("int64")
    df["_src_file"] = path.name
    meta = {
        "archivo": path.name,
        "version_contaplus": (VERSION_RE.search(title) or [None, None])[1],
        "fecha_impresion": (PRINT_RE.search(info) or [None, None])[1],
        "fecha_corte": (CORTE_RE.search(info) or [None, None])[1],
        "columnas": ";".join(columns),
        "filas_detalle": len(df),
        **{f"pie_{k.lower().replace(' ', '_')}": v for k, v in footer.items()},
    }
    return df, meta


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dir", default="fuentes/financiero/financiero_carpeta_compartida")
    ap.add_argument("--out", default="data/landing/contaplus")
    args = ap.parse_args()

    src, out = Path(args.dir), Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    loaded_at = datetime.now(timezone.utc).isoformat(timespec="seconds")

    recaudos, metas = [], []
    for f in sorted(src.glob("recaudos_*.txt")):
        df, meta = read_report(f)
        df["_periodo_archivo"] = re.search(r"(\d{4})_(\d{2})", f.name).group(0).replace("_", "-")
        recaudos.append(df)
        metas.append(meta)
    rec = pd.concat(recaudos, ignore_index=True)
    rec["_loaded_at"] = loaded_at
    rec.to_parquet(out / "recaudos.parquet", index=False)
    print(f"recaudos: {len(rec)} filas en {len(recaudos)} archivos")

    for name in ("cartera_corte_2026_09", "conceptos"):
        df, meta = read_report(src / f"{name}.txt")
        df["_loaded_at"] = loaded_at
        df.to_parquet(out / f"{name.split('_corte')[0]}.parquet", index=False)
        metas.append(meta)
        print(f"{name}: {len(df)} filas")

    pd.DataFrame(metas).astype("string").to_parquet(out / "_archivos.parquet", index=False)


if __name__ == "__main__":
    main()
