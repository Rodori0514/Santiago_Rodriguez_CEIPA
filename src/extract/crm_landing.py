"""Aplana los JSON extraídos de VentasCloud a Parquet crudo (un archivo por endpoint)."""
import argparse
import json
from pathlib import Path

import pandas as pd


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--src", default="fuentes/comercial")
    ap.add_argument("--out", default="data/landing/crm")
    args = ap.parse_args()

    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    for name in ("programs", "contacts", "opportunities"):
        payload = json.loads((Path(args.src) / f"{name}.json").read_text(encoding="utf-8"))
        df = pd.json_normalize(payload["data"])
        for col in df.columns:
            if df[col].dtype == object:
                df[col] = df[col].astype("string")
        df["_extracted_at"] = payload["extracted_at"]
        df.to_parquet(out / f"{name}.parquet", index=False)
        print(f"{name}: {len(df)} filas")


if __name__ == "__main__":
    main()
