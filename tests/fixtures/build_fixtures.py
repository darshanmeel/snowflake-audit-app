#!/usr/bin/env python3
"""Build tests/db_audit_test.duckdb: the app's test database, from the fake Snowflake account.

    python tests/fixtures/build_fixtures.py [--db PATH] [--force]

1. tools/sql_smoke.py runs every check against the fake account (lenient fake, windows 7 and 30, so
   90 is an alias of 30 and the window picker has two real windows plus one partial).
2. A check that failed or returned no rows gets a fallback parquet: its output columns, two or three
   typed fake rows, so every check has data for the API to serve.
3. Two checks are marked failed and one all-NOT_ASSESSED on purpose, to test "-" plus a reason.
4. tools/load_results.py loads the folder into the DB.

The result is cached next to the DB; it is rebuilt only when an input file changes.
"""
from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import shutil
import sys
import tempfile
from pathlib import Path

import pyarrow as pa
import pyarrow.parquet as pq
import sqlglot

ROOT = Path(__file__).resolve().parent.parent.parent
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from app.core import config as app_config  # noqa: E402
from app.core import pricing as app_pricing  # noqa: E402
from app.core import registry as app_registry  # noqa: E402
from tests.fake_snowflake import data as fake_data  # noqa: E402
from tools import export_results as ex  # noqa: E402
from tools import load_results  # noqa: E402
from tools import sql_smoke  # noqa: E402

DB_PATH = ROOT / "tests" / "db_audit_test.duckdb"
STAMP_SUFFIX = ".inputs.sha1"

# Marked failed in the manifest on purpose: the app must show "-" and the reason, never $0.
FAILED_ON_PURPOSE = {
    "sf_org_dormant_accounts": "SQL access control error: Insufficient privileges to operate on "
                               "view 'ORGANIZATION_USAGE.ACCOUNTS'",
    "sf_obj_iceberg_tables": "SQL compilation error: no such view 'ACCOUNT_USAGE.ICEBERG_TABLES' "
                             "in this account",
}
# Every row reads NOT_ASSESSED with its own reason.
NOT_ASSESSED_ON_PURPOSE = "sf_gov_classification_coverage"

_INPUT_GLOBS = (
    "app/queries/**/*", "config/*.yml", "tests/fake_snowflake/*.py", "tests/fixtures/build_fixtures.py",
    "tools/sql_smoke.py", "tools/export_results.py", "tools/load_results.py", "tools/common.py",
    "app/core/registry.py", "app/core/snowflake_docs.py",
)

_NAMES = {
    "warehouse_name": ["WH_ANALYTICS", "WH_ETL", "WH_BI"],
    "database_name": ["SALES_DB", "MARKETING_DB", "RAW_DB"],
    "schema_name": ["PUBLIC", "STAGING", "CURATED"],
    "table_name": ["ORDERS", "CUSTOMERS", "EVENTS"],
    "role_name": ["ANALYST_ROLE", "ETL_ROLE", "SYSADMIN"],
    "user_name": ["ANALYST_ONE", "ETL_SERVICE", "BI_READER"],
    "task_name": ["LOAD_ORDERS", "REFRESH_MARTS", "PURGE_STAGING"],
    "task_full_name": ["SALES_DB.PUBLIC.LOAD_ORDERS", "SALES_DB.PUBLIC.REFRESH_MARTS", "RAW_DB.STAGING.PURGE_STAGING"],
    "pipe_name": ["RAW_DB.STAGING.ORDERS_PIPE", "RAW_DB.STAGING.EVENTS_PIPE", "RAW_DB.STAGING.CLICKS_PIPE"],
    "account_name": ["FAKE_ACCOUNT", "FAKE_ACCOUNT_DEV", "FAKE_ACCOUNT_QA"],
}


# ------------------------------------------------------------------------------------------
# Fallback rows for a check with no data
# ------------------------------------------------------------------------------------------


def output_columns(qid: str) -> list[str]:
    """The check's output column names, read from its SQL (top-level SELECT, or the first branch of a UNION)."""
    ctx = {"as_of_date": fake_data.NOW.date().isoformat(), "account_id": fake_data.ACCOUNT_LOCATOR,
           "cloud": "AWS", "credit_price_usd": fake_data.CREDIT_PRICE, "storage_price_usd_tb_month": 23.0}
    sql = ex.render(ex.load_checks()[qid], days=30, params=ex.params_for(qid, app_config.load_thresholds()),
                    ctx=ctx)
    names = sqlglot.parse_one(sql, read="snowflake").named_selects
    if not names or "*" in names:
        raise ValueError(f"{qid}: cannot read its output columns from the SQL")
    return [n.lower() for n in names]


def _column_type(name: str) -> pa.DataType:
    if name == "window_days":
        return pa.int32()
    if name in ("day", "date") or name.endswith("_date") or name.endswith("_day"):
        return pa.date32()
    if name.endswith(("_time", "_at", "_ts", "_on")) or name in ("first_seen", "last_seen"):
        return pa.timestamp("us")
    if app_pricing.is_money(name) or name.endswith(("_amount", "_units")):
        return pa.float64()
    if name.endswith(("_pct", "_share", "_ratio", "_rate")) or "usd" in name or "credits" in name \
            or name.endswith(("_gb", "_tb", "_hours", "_minutes", "_avg", "_s", "_secs")):
        return pa.float64()
    if name.endswith(("_count", "_sum", "_bytes", "_rows", "_total", "_runs", "_days", "_size_mb", "_queries")) \
            or name.startswith(("num_", "n_")) or name in ("weekday_num", "hour_of_day"):
        return pa.int64()
    if name.startswith(("is_", "has_")):
        return pa.bool_()
    return pa.string()


def _cell(name: str, dtype: pa.DataType, i: int, window: int, status: str):
    """One typed fake value; i (0-based) varies rows, window fills window_days."""
    if name == "window_days":
        return window
    if name == "status":
        return status
    if name == "account_id":
        return fake_data.ACCOUNT_LOCATOR
    if name in _NAMES:
        return _NAMES[name][i % 3]
    if name.endswith("_id"):
        return f"{name[:-3].upper()}_{i + 1}"
    if pa.types.is_date(dtype):
        return fake_data.NOW.date() - dt.timedelta(days=i + 1)
    if pa.types.is_timestamp(dtype):
        return (fake_data.NOW - dt.timedelta(days=i + 1)).replace(tzinfo=None)
    if pa.types.is_boolean(dtype):
        return i % 2 == 0
    if pa.types.is_floating(dtype):
        return round((12.5 + 7.25 * i) * (2 if "usd" in name else 1), 2)
    if pa.types.is_integer(dtype):
        return 10 + 5 * i
    if name == "price_basis":
        return "list"
    if name == "not_assessed_reason":
        return None
    if name in ("reasons", "reason", "read_this"):
        return "Fake row for the test database"
    return f"{name}_{i + 1}"


def fallback_table(qid: str, columns: list[str]) -> pa.Table:
    """Two WARN/OK rows per window (7 and 30) for a windowed check, three rows otherwise."""
    spec = app_registry.by_id(qid)
    if "window_days" not in columns:
        columns = ["window_days", *columns]
    windows = [7, 30] if spec.windowed else [0]
    statuses = ["WARN", "OK", "OK"]
    per_window = 2 if spec.windowed else 3
    types = {c: _column_type(c) for c in columns}
    data: dict[str, list] = {c: [] for c in columns}
    for w in windows:
        for i in range(per_window):
            for c in columns:
                data[c].append(_cell(c, types[c], i, w, statuses[i]))
    return pa.table({c: pa.array(data[c], type=types[c]) for c in columns})


def _fill_fallbacks(export: Path, manifest: dict) -> list[str]:
    filled = []
    for qid, entry in manifest["findings"].items():
        if entry["status"] == "ok":
            continue
        columns = entry.get("columns") or output_columns(qid)
        table = fallback_table(qid, columns)
        pq.write_table(table, export / "findings" / f"{qid}.parquet")
        entry.update({"status": "ok", "exported_rows": table.num_rows, "columns": table.column_names,
                      "not_assessed_rows": 0, "error": None})
        filled.append(qid)
    return filled


# ------------------------------------------------------------------------------------------
# The deliberate gaps
# ------------------------------------------------------------------------------------------


def _mark_failed(export: Path, manifest: dict) -> None:
    for qid, message in FAILED_ON_PURPOSE.items():
        (export / "findings" / f"{qid}.parquet").unlink(missing_ok=True)
        manifest["findings"][qid].update({"status": "failed", "exported_rows": None, "columns": None,
                                          "not_assessed_rows": None, "error": message})


def _mark_not_assessed(export: Path, manifest: dict) -> None:
    qid = NOT_ASSESSED_ON_PURPOSE
    reasons = app_registry.by_id(qid).not_assessed_reasons
    code = next(iter(reasons)) if reasons else "not_assessed"
    path = export / "findings" / f"{qid}.parquet"
    table = pq.read_table(path)
    n = table.num_rows
    for name, values in (("status", ["NOT_ASSESSED"] * n), ("not_assessed_reason", [code] * n)):
        pos = table.column_names.index(name) if name in table.column_names else None
        col = pa.array(values, type=pa.string())
        table = table.set_column(pos, name, col) if pos is not None else table.append_column(name, col)
    pq.write_table(table, path)
    manifest["findings"][qid].update({"columns": table.column_names, "not_assessed_rows": n})


# ------------------------------------------------------------------------------------------
# Build
# ------------------------------------------------------------------------------------------


def inputs_hash() -> str:
    h = hashlib.sha1()
    for pattern in _INPUT_GLOBS:
        for path in sorted(ROOT.glob(pattern)):
            if path.is_file():
                h.update(path.relative_to(ROOT).as_posix().encode())
                h.update(path.read_bytes())
    return h.hexdigest()


def _stamp_path(db_path: Path) -> Path:
    return db_path.with_name(db_path.name + STAMP_SUFFIX)


def is_current(db_path: Path) -> bool:
    stamp = _stamp_path(db_path)
    return (db_path.exists() and stamp.exists() and stamp.read_text().strip() == inputs_hash()
            and db_path.with_name(db_path.stem + ".run_results.json").exists())


_orig_status_counts = sql_smoke._status_counts


def _tolerant_counts(path: Path) -> dict:
    """A check the export did not run (not assessed: the role, edition or a view is missing) has no
    result file; the smoke's per-status count reads it as empty instead of failing the whole build."""
    return _orig_status_counts(path) if path.exists() else {}


def build(db_path: Path = DB_PATH, *, force: bool = False) -> dict:
    """Build db_path from the fake account; returns a summary. A no-op when nothing it reads changed."""
    if not force and is_current(db_path):
        return {"db_path": db_path, "rebuilt": False}
    work = Path(tempfile.mkdtemp(prefix="audit_fixture_"))
    try:
        export = work / "export"
        sql_smoke._status_counts = _tolerant_counts
        # windows=30: window labels 7 and 30 are real, 90 is an alias of 30 (a partial window).
        result = sql_smoke.run_smoke(windows=30, export_to=export, lenient=True)
        manifest = json.loads((export / "manifest.json").read_text(encoding="utf-8"))
        filled = _fill_fallbacks(export, manifest)
        _mark_not_assessed(export, manifest)
        _mark_failed(export, manifest)
        (export / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
        summary = load_results.load_folder(export, db_path)
    finally:
        sql_smoke._status_counts = _orig_status_counts
        shutil.rmtree(work, ignore_errors=True)
    _stamp_path(db_path).write_text(inputs_hash(), encoding="utf-8")
    summary.update({"rebuilt": True, "fallbacks": filled, "smoke_failed": [
        q for q, f in result["manifest"]["findings"].items() if f["status"] == "failed"]})
    return summary


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--db", type=Path, default=DB_PATH, help="DuckDB file to write (default tests/db_audit_test.duckdb)")
    ap.add_argument("--force", action="store_true", help="rebuild even when nothing changed")
    args = ap.parse_args(argv)
    summary = build(args.db.resolve(), force=args.force)
    if not summary["rebuilt"]:
        print(f"{summary['db_path']} is current")
        return 0
    print(f"built {summary['db_path']}: {len(summary['loaded'])} checks loaded, "
          f"{len(summary['failed_in_export'])} failed on purpose, fallback rows for {summary['fallbacks']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
