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


# Fallbacks read the query feed and the shims through RESULT_SCAN; any query id renders.
FALLBACK_CTX = dict(SAMPLE_CTX, info_schema_db="DB", query_feed_ids=["q0"])


def lint(name: str, render) -> bool:
    try:
        sql = render()
        ex.assert_read_only(sql)
        sqlglot.parse_one(sql, read="snowflake")
        return True
    except Exception as exc:  # noqa: BLE001 -- report every file, then fail once
        print(f"FAIL {name}: {str(exc)[:300]}")
        return False


def check(path: Path) -> str:
    text = path.read_text(encoding="utf-8")
    is_check = path.parent.name == "checks"
    if is_check and not registry.by_id(path.stem).title:
        raise ValueError("missing title")
    params = ex.params_for(path.stem, {}) if is_check else {}
    return ex.render(text, days=30, params=params, ctx=SAMPLE_CTX)


def fallback(qid: str, text: str) -> str:
    ctx = dict(FALLBACK_CTX, shim_ids={v: "q0" for v in ex.shims_in(text)})
    return ex.render(text, days=30, params=ex.params_for(qid, {}), ctx=ctx)


def shim(body: str) -> str:
    sql = ex._item_sql(body, "database", ("DB", "SCH", "OBJ")).replace("__SHOW__", "TABLE(RESULT_SCAN('q0'))")
    return ex.render(sql, days=7, params={}, ctx=FALLBACK_CTX)


def main(argv: list[str]) -> int:
    pattern = argv[0] if argv else "*"
    paths = sorted((ex.SQL_DIR / "checks").glob(f"{pattern}.sql")) + sorted((ex.SQL_DIR / "dims").glob("*.sql"))
    results = [lint(p.stem, lambda p=p: check(p)) for p in paths]
    fallbacks = {q: t for q, t in ex.load_fallbacks().items() if Path(q).match(pattern)}
    results += [lint(f"fallback/{q}", lambda q=q, t=t: fallback(q, t)) for q, t in fallbacks.items()]
    if not argv:
        results += [lint(f"shims/{v}", lambda b=b: shim(b)) for v, (_h, b) in ex.load_shims().items()]
    failed = results.count(False)
    print(f"{len(results) - failed} ok, {failed} failed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
