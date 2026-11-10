#!/usr/bin/env python3
"""Build demo databases from the larger fake account, to look at every page and every state.

    python tools/build_demo_db.py                           the full account, data/demo/db_audit_demo.duckdb
    python tools/build_demo_db.py --scenario limited_role   one other kind of account, data/demo/limited_role/
    python tools/build_demo_db.py --scenario all            all of them, and data/demo/coverage_report.md
    python tools/build_demo_db.py --list                    what the scenarios are
    python tools/build_demo_db.py --report                  rewrite the report from what is built

Each also writes <db>.coverage.json: rows and statuses per check. Then start the app on one:
AUDIT_DB=data/demo/db_audit_demo.duckdb python -m app.api

The fake account is the test one plus the demo areas in tests/fake_snowflake/demo_*.py. Unlike the
test DB, nothing is padded: a check with no rows reads as empty, as it would on a real account.
"""
from __future__ import annotations

import argparse
import collections
import json
import re
import subprocess
import sys
from pathlib import Path

import pyarrow.parquet as pq

ROOT = Path(__file__).resolve().parent.parent
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from app.core import datasource  # noqa: E402
from tests.fake_snowflake import demo_scenarios  # noqa: E402
from tools import load_results, sql_smoke  # noqa: E402

DEFAULT_DB = ROOT / "data" / "demo" / "db_audit_demo.duckdb"
CHECKS_DIR = ROOT / "app" / "queries" / "checks"
STATUSES = ("OK", "WARN", "CRITICAL", "NOT_ASSESSED")
# Sorting or filtering on a status names it without being able to give it.
_READS_STATUS = re.compile(r"CASE\s+status\s+WHEN.*?END|\bstatus\s*(=|<>|!=)\s*'\w+'|\bstatus\s+(NOT\s+)?IN\s*\([^)]*\)", re.I | re.S)


def db_for(scenario: str) -> Path:
    return DEFAULT_DB if scenario == "full" else DEFAULT_DB.parent / scenario / DEFAULT_DB.name


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


def report() -> Path:
    """Which statuses each check reaches across the built scenarios, and what none of them reaches."""
    built = {s: json.loads(db_for(s).with_suffix(".coverage.json").read_text(encoding="utf-8"))
             for s in demo_scenarios.SCENARIOS if db_for(s).with_suffix(".coverage.json").exists()}
    lines = ["# Demo data coverage", "", "| scenario | what it is | checks with rows | no rows | not assessed | failed |",
             "|---|---|---:|---:|---:|---:|"]
    for s, cov in built.items():
        states = collections.Counter(c["status"] for c in cov.values())
        lines.append(f"| {s} | {demo_scenarios.SCENARIOS[s].about} | {sum(1 for c in cov.values() if c['rows'])} | "
                     f"{states['empty']} | {states['not_assessed']} | {states['failed']} |")
    reached = collections.defaultdict(set)
    for cov in built.values():
        for q, c in cov.items():
            reached[q] |= set(c["statuses"])
    missing = collections.defaultdict(list)
    for q in sorted(reached):
        lines_sql = (CHECKS_DIR / f"{q}.sql").read_text(encoding="utf-8").splitlines()
        body = "\n".join(x for x in lines_sql if not x.startswith("--"))
        body = _READS_STATUS.sub("", body)
        for st in STATUSES:
            if f"'{st}'" in body and st not in reached[q]:
                missing[st].append(q)
    lines += ["", "## Statuses a check's SQL can give that no built scenario reaches", ""]
    lines += [f"- **{st}** ({len(missing[st])}): {', '.join(missing[st])}" for st in STATUSES if missing[st]] or ["None."]
    no_rows = sorted(q for q in reached if not any(cov.get(q, {}).get("rows") for cov in built.values()))
    lines += ["", f"## Checks with no rows in any scenario ({len(no_rows)})", "", ", ".join(no_rows) or "None."]
    path = DEFAULT_DB.parent / "coverage_report.md"
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return path


def build(db_path: Path = DEFAULT_DB, windows: int = 90, export: Path | None = None, scenario: str | None = None) -> dict:
    export = export or db_path.parent / "export"
    result = sql_smoke.run_smoke(windows=windows, export_to=export, lenient=True, demo=True,
                                 scenario=None if scenario in (None, "full") else scenario)
    db_path.parent.mkdir(parents=True, exist_ok=True)
    summary = load_results.load_folder(export, db_path)
    summary["manifest"] = result["manifest"]
    summary["coverage"] = coverage(export, result["manifest"])
    db_path.with_suffix(".coverage.json").write_text(json.dumps(summary["coverage"], indent=1), encoding="utf-8")
    return summary


def build_all(windows: int, jobs: int) -> int:
    """One process per scenario, because each loads the whole fake account into memory."""
    waiting, running, bad = list(demo_scenarios.SCENARIOS), [], []
    while waiting or running:
        while waiting and len(running) < max(jobs, 1):
            name = waiting.pop(0)
            running.append((name, subprocess.Popen([sys.executable, __file__, "--scenario", name, "--windows", str(windows)])))
        name, proc = running.pop(0)
        if proc.wait():
            bad.append(name)
    print(report())
    if bad:
        print("failed: " + ", ".join(bad), file=sys.stderr)
    return 1 if bad else 0


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--db", type=Path, help="DuckDB file to write (default data/demo/db_audit_demo.duckdb)")
    ap.add_argument("--scenario", default="full", choices=[*demo_scenarios.SCENARIOS, "all"], help="kind of account (default full)")
    ap.add_argument("--jobs", type=int, default=1, help="scenarios built at once with --scenario all; each needs several GB of memory (default 1)")
    ap.add_argument("--list", action="store_true", help="list the scenarios")
    ap.add_argument("--report", action="store_true", help="rewrite data/demo/coverage_report.md from what is built")
    ap.add_argument("--windows", type=int, default=90, help="days of history to export (default 90)")
    args = ap.parse_args(argv)
    if args.list:
        for name, s in demo_scenarios.SCENARIOS.items():
            print(f"{name:21} {s.about}")
        return 0
    if args.report:
        print(report())
        return 0
    if args.scenario == "all":
        return build_all(args.windows, args.jobs)
    args.db = args.db or db_for(args.scenario)
    db_path = args.db.resolve()
    if not load_results.db_path_allowed(db_path):
        print(f"error: {db_path} is inside the repository (outside the git-ignored data/ folder)", file=sys.stderr)
        return 2
    if db_path == datasource.db_path().resolve():
        print(f"error: {db_path} is where real results load; pick another file", file=sys.stderr)
        return 2
    summary = build(db_path, args.windows, scenario=args.scenario)
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
