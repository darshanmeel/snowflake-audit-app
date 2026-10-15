#!/usr/bin/env python3
"""Render every check with sample values and parse it as Snowflake SQL; exit 1 on any failure.

    python tools/check_queries.py            # all checks
    python tools/check_queries.py 'sf_cost_*'
"""
from __future__ import annotations

import sys
from pathlib import Path

import sqlglot

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from app.core import registry  # noqa: E402
from tools import export_results as ex  # noqa: E402

SAMPLE_CTX = {"as_of_date": "2026-01-15", "account_id": "ACME01", "cloud": "AWS",
              "credit_price_usd": 3.0, "ai_credit_price_usd": 2.0, "storage_price_usd_tb_month": 23.0}


def main(argv: list[str]) -> int:
    pattern = argv[0] if argv else "*"
    failed = 0
    paths = sorted((ex.SQL_DIR / "checks").glob(f"{pattern}.sql")) + sorted((ex.SQL_DIR / "dims").glob("*.sql"))
    for path in paths:
        try:
            text = path.read_text(encoding="utf-8")
            is_check = path.parent.name == "checks"
            spec = registry.by_id(path.stem) if is_check else None
            params = ex.params_for(path.stem, {}) if is_check else {}
            sql = ex.render(text, days=30, params=params, ctx=SAMPLE_CTX)
            ex.assert_read_only(sql)
            sqlglot.parse_one(sql, read="snowflake")
            if spec is not None and not spec.title:
                raise ValueError("missing title")
        except Exception as exc:  # noqa: BLE001 -- report every file, then fail once
            failed += 1
            print(f"FAIL {path.stem}: {str(exc)[:300]}")
    print(f"{len(paths) - failed} ok, {failed} failed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
