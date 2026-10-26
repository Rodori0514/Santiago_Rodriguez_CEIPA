"""Extractor de VentasCloud API v1: descarga completa o incremental a JSON crudo (landing)."""
import argparse
import json
import os
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

ENDPOINTS = {"programs": "programId", "contacts": "contactId", "opportunities": "opportunityId"}


def load_env(path=".env"):
    if Path(path).exists():
        for line in Path(path).read_text(encoding="utf-8").splitlines():
            if "=" in line and not line.lstrip().startswith("#"):
                k, v = line.split("=", 1)
                os.environ.setdefault(k.strip(), v.strip())


def get(base, key, endpoint, params, max_retries=5):
    url = f"{base}/{endpoint}?{urllib.parse.urlencode(params)}"
    for attempt in range(max_retries):
        req = urllib.request.Request(url, headers={"X-API-Key": key})
        try:
            with urllib.request.urlopen(req, timeout=30) as r:
                remaining = int(r.headers.get("X-RateLimit-Remaining", "60"))
                if remaining <= 1:
                    time.sleep(5)
                return json.loads(r.read().decode("utf-8"))
        except urllib.error.HTTPError as e:
            if e.code == 429:
                wait = int(e.headers.get("Retry-After", "10"))
                print(f"  429 rate_limited, esperando {wait}s")
                time.sleep(wait)
                continue
            if e.code >= 500 and attempt < max_retries - 1:
                time.sleep(2 ** attempt)
                continue
            raise RuntimeError(f"{endpoint} HTTP {e.code}: {e.read().decode()[:300]}") from e
    raise RuntimeError(f"{endpoint}: reintentos agotados")


def extract(base, key, endpoint, updated_since=None, page_size=100):
    params = {"page_size": page_size} if endpoint != "programs" else {}
    if updated_since and endpoint != "programs":
        params["updated_since"] = updated_since
    rows, pages, total_estimate = [], 0, None
    while True:
        payload = get(base, key, endpoint, params)
        pages += 1
        rows.extend(payload["data"])
        total_estimate = payload.get("total_estimate", total_estimate)
        cursor = payload.get("next_cursor")
        if not cursor:
            break
        params = {**params, "cursor": cursor}
    return rows, pages, total_estimate


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="fuentes/comercial")
    ap.add_argument("--updated-since", help="ISO 8601, p. ej. 2026-09-01T00:00:00Z")
    args = ap.parse_args()

    load_env()
    key = os.environ["VENTASCLOUD_API_KEY"]
    base = os.environ.get("VENTASCLOUD_BASE_URL", "https://prueba-datos-ceipa.vercel.app/api/crm/v1")
    extracted_at = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)

    for ep, id_field in ENDPOINTS.items():
        rows, pages, est = extract(base, key, ep, args.updated_since)
        ids = [r[id_field] for r in rows]
        print(f"{ep}: {len(rows)} registros, {pages} páginas, total_estimate={est}, ids únicos={len(set(ids))}")
        (out / f"{ep}.json").write_text(
            json.dumps(
                {"extracted_at": extracted_at, "updated_since": args.updated_since,
                 "total_estimate": est, "pages": pages, "data": rows},
                ensure_ascii=False, indent=1),
            encoding="utf-8")


if __name__ == "__main__":
    main()
