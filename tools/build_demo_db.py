#!/usr/bin/env python3
"""Build a demo database from the larger fake account, to look at every page with varied data.

    python tools/build_demo_db.py [--db data/demo/db_audit_demo.duckdb]

It also writes <db>.coverage.json: rows and statuses per check. Then start the app on it:  AUDIT_DB=data/demo/db_audit_demo.duckdb python -m app.api

The fake account is the test one plus the demo areas in tests/fake_snowflake/demo_*.py. Unlike the
test DB, nothing is padded: a check with no rows reads as empty, as it would on a real account.
"""
from __future__ import annotations

import argparse
import collections
import json
import sys
from pathlib import Path

import pyarrow.parquet as pq

ROOT = Path(__file__).resolve().parent.parent
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from app.core import datasource  # noqa: E402
from tools import load_results, sql_smoke  # noqa: E402

DEFAULT_DB = ROOT / "data" / "demo" / "db_audit_demo.duckdb"


def coverage(export: Path, manifest: dict) -> dict:
    """{check id: {domain, status, rows, statuses}}: what each check got from the demo account."""
    out = {}
    for qid, f in sorted(manifest["findings"].items()):
        path = export / "findings" / f"{qid}.parquet"
        rows, statuses = 0, {}
        if path.exists():
            rows = pq.read_metadata(path).num_rows
            if "status" in pq.read_schema(path).names:
                statuses = dict(collections.Counter(str(v) for v in pq.read_table(path, columns=["status"]).column("status").to_pylist()))
        out[qid] = {"domain": f.get("domain"), "status": f["status"], "rows": rows, "statuses": statuses,
                    "error": f.get("error")}
    return out


def build(db_path: Path = DEFAULT_DB, windows: int = 90, export: Path | None = None) -> dict:
    export = export or db_path.parent / "export"
    orig = sql_smoke._status_counts
    sql_smoke._status_counts = lambda p: orig(p) if p.exists() else {}   # a check that did not run has no file
    try:
        result = sql_smoke.run_smoke(windows=windows, export_to=export, lenient=True, demo=True)
    finally:
        sql_smoke._status_counts = orig
    db_path.parent.mkdir(parents=True, exist_ok=True)
    summary = load_results.load_folder(export, db_path)
    summary["manifest"] = result["manifest"]
    summary["coverage"] = coverage(export, result["manifest"])
    db_path.with_suffix(".coverage.json").write_text(json.dumps(summary["coverage"], indent=1), encoding="utf-8")
    return summary


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--db", type=Path, default=DEFAULT_DB, help="DuckDB file to write (default data/demo/db_audit_demo.duckdb)")
    ap.add_argument("--windows", type=int, default=90, help="days of history to export (default 90)")
    args = ap.parse_args(argv)
    db_path = args.db.resolve()
    if not load_results.db_path_allowed(db_path):
        print(f"error: {db_path} is inside the repository (outside the git-ignored data/ folder)", file=sys.stderr)
        return 2
    if db_path == datasource.db_path().resolve():
        print(f"error: {db_path} is where real results load; pick another file", file=sys.stderr)
        return 2
    summary = build(db_path, args.windows)
    cov = summary["coverage"]
    print(f"{sum(1 for c in cov.values() if c['rows'])} of {len(cov)} checks have rows, "
          f"{sum(1 for c in cov.values() if {'WARN', 'CRITICAL'} & set(c['statuses']))} flag something; "
          f"per check: {args.db.resolve().with_suffix('.coverage.json')}")
    by = collections.Counter(f["status"] for f in summary["manifest"]["findings"].values())
    print(f"built {args.db}: " + ", ".join(f"{n} {s}" for s, n in sorted(by.items())))
    for q, f in sorted(summary["manifest"]["findings"].items()):
        if f["status"] == "failed":
            print(f"FAILED {q}: {str(f.get('error'))[:200]}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
