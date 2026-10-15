"""Refresh tests/fake_snowflake/live_catalog.json from a live account.

Reads column names and types only: SNOWFLAKE.INFORMATION_SCHEMA.COLUMNS for the system views, and
DESCRIBE RESULT of each SHOW a check runs for the SHOW outputs. No rows are kept. Views and SHOWs
this role cannot see keep their old entry, so a smaller role never shrinks the catalog.

    python tools/dump_live_catalog.py
"""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from tests.fake_snowflake import schema  # noqa: E402
from tools.export_results import connect  # noqa: E402

CATALOG = ROOT / "tests" / "fake_snowflake" / "live_catalog.json"
_SKIP_SCHEMAS = {"INFORMATION_SCHEMA"}


def _type(data_type: str, precision, scale) -> str:
    return f"NUMBER({precision},{scale})" if data_type == "NUMBER" else re.sub(r"\(\d+\)$", "", data_type)


def _pre_statements() -> dict[str, str]:
    """SHOW table -> the first `-- pre:` statement that fills it."""
    out = {}
    for path in sorted((ROOT / "app" / "queries").rglob("*.sql")):
        for m in re.finditer(r"^-- pre: (SHOW .*?)\s*(?:\(.*)?$", path.read_text(encoding="utf-8"), re.M):
            stmt = m.group(1).strip()
            key = re.sub(r"\s+(LIKE\s+'[^']*'|IN\s+ACCOUNT|ON\s+ACCOUNT)", "", stmt).strip()
            table = schema.SHOW_TABLE_FOR_PRE.get(key)
            if table and (table not in out or "LIKE" in out[table]):
                out[table] = stmt
    return out


def dump(cur) -> dict:
    cur.execute("SELECT table_schema, table_name, column_name, data_type, numeric_precision, numeric_scale "
                "FROM SNOWFLAKE.INFORMATION_SCHEMA.COLUMNS ORDER BY table_schema, table_name, ordinal_position")
    views: dict = {}
    for sch, view, col, data_type, precision, scale in cur.fetchall():
        if sch not in _SKIP_SCHEMAS:
            views.setdefault(sch.lower(), {}).setdefault(view, []).append(f"{col}:{_type(data_type, precision, scale)}")
    shows = {}
    for table, stmt in _pre_statements().items():
        try:
            cur.execute(stmt)
            cur.execute(f"DESCRIBE RESULT '{cur.sfqid}'")
            shows[table] = [f"{r[0]}:{_type(r[1].split('(')[0], *_num(r[1]))}" for r in cur.fetchall()]
        except Exception as exc:  # the role cannot run it: keep the old entry
            print(f"skip {stmt}: {str(exc).splitlines()[0]}")
    return {"views": views, "shows": shows}


def _num(t: str):
    m = re.fullmatch(r"NUMBER\((\d+),(\d+)\)", t)
    return (m.group(1), m.group(2)) if m else (None, None)


def write(new: dict) -> None:
    old = json.loads(CATALOG.read_text(encoding="utf-8")) if CATALOG.exists() else {"views": {}, "shows": {}}
    for sch, views in new["views"].items():
        old["views"].setdefault(sch, {}).update({v: " ".join(cols) for v, cols in views.items()})
    old["shows"].update({t: " ".join(cols) for t, cols in new["shows"].items()})
    lines = ["{", '"views": {']
    schemas = sorted(old["views"].items())
    for i, (sch, views) in enumerate(schemas):
        lines.append(f' "{sch}": {{')
        items = sorted(views.items())
        lines += [f'  "{v}": {json.dumps(s)}' + ("," if j < len(items) - 1 else "") for j, (v, s) in enumerate(items)]
        lines.append(" }" + ("," if i < len(schemas) - 1 else ""))
    lines += ["},", '"shows": {']
    items = sorted(old["shows"].items())
    lines += [f' "{t}": {json.dumps(s)}' + ("," if j < len(items) - 1 else "") for j, (t, s) in enumerate(items)]
    lines += ["}", "}"]
    CATALOG.write_text("\n".join(lines) + "\n", encoding="utf-8", newline="\n")


def main() -> int:
    con = connect()
    try:
        new = dump(con.cursor())
    finally:
        con.close()
    write(new)
    print(f"{CATALOG.relative_to(ROOT)}: {sum(len(v) for v in new['views'].values())} views, {len(new['shows'])} SHOWs")
    return 0


if __name__ == "__main__":
    sys.exit(main())
