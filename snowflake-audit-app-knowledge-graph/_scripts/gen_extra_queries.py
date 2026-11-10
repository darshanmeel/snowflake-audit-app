"""Write graph/extra_queries.jsonl: one business_rule node per Snowflake trap, implements edges from the
checks, includes and functions that handle it, and document nodes for the queries slice pages.

    python snowflake-audit-app-knowledge-graph/_scripts/gen_extra_queries.py

Check lists come from a grep of app/queries/checks for each trap's marker; every edge target is checked
against graph/nodes.jsonl so no edge points to a missing node.
"""
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
KG = ROOT / "snowflake-audit-app-knowledge-graph"
CHECKS = ROOT / "app" / "queries" / "checks"

# id, name, summary, evidence path:line, marker regex over checks (or None), extra implementers [(id, evidence)]
RULES = [
    ("price_joined_once", "Price is multiplied in once",
     "Each $/credit is resolved once per export and pasted into the SQL as a literal; checks never join a price table.",
     "tools/export_results.py:600-614", r"__CREDIT_PRICE__",
     [("function:tools/export_results.py:account_context", "tools/export_results.py:821"),
      ("function:tools/export_results.py:render", "tools/export_results.py:608"),
      ("common:cost_lines", "app/queries/common/cost_lines.sql:13")]),
    ("units_never_added", "Credits, TB and $ kinds are never summed together",
     "cost_lines turns every line into usd before summing; the app keeps one money kind per check and never adds spend, change and waste.",
     "app/core/finding_columns.py:15-56", r"is_total_row|is_alt_basis",
     [("common:cost_lines", "app/queries/common/cost_lines.sql:4"),
      ("function:app/core/finding_columns.py:money_column", "app/core/finding_columns.py:135"),
      ("checks:overview_spend_estimate", "app/queries/checks/overview_spend_estimate.sql:24")]),
    ("zero_usage_days", "Days with no usage count as $0 days",
     "A GENERATOR day spine CROSS JOINed with each product and LEFT JOINed to usage fills missing days with 0 before baselines.",
     "app/queries/checks/cost_daily_spikes.sql:47-63", r"GENERATOR\(", []),
    ("one_as_of_date", "One as-of date ends every window",
     "__AS_OF_DATE__ is set once per export (tomorrow with include_today, else now minus 8 h) and is the exclusive end of every window.",
     "tools/export_results.py:1037-1041", None,
     [("function:tools/export_results.py:_cutoff", "tools/export_results.py:1037"),
      ("function:tools/export_results.py:render", "tools/export_results.py:609")]),
    ("cloud_services_billed", "Cloud services priced after the daily 10% adjustment",
     "Warehouse rows are compute + cloud services x that day's billed ratio from METERING_DAILY_HISTORY; totals use CREDITS_BILLED.",
     "app/queries/common/sf_cs_billed_ratio.sql:1-12", r"__INCLUDE_(sf_cs_billed_ratio|sf_cs_window_ratio|cost_lines)__",
     [("common:sf_cs_billed_ratio", "app/queries/common/sf_cs_billed_ratio.sql:4"),
      ("common:sf_cs_window_ratio", "app/queries/common/sf_cs_window_ratio.sql:3"),
      ("common:cost_lines", "app/queries/common/cost_lines.sql:13")]),
    ("attribution_not_total", "Query attribution is not the warehouse bill",
     "Idle = compute - attributed only for hours older than 8 h with a non-NULL split; adaptive or NULL reads NOT_ASSESSED no_query_attribution.",
     "app/queries/checks/sf_cost_warehouse_idle_credits_daily.sql:28-65", r"credits_attributed_compute_queries|no_query_attribution",
     [("common:sf_chg_query_credits", "app/queries/common/sf_chg_query_credits.sql:1"),
      ("shims:WAREHOUSE_METERING_HISTORY", "app/queries/shims/WAREHOUSE_METERING_HISTORY.sql:5")]),
    ("role_visibility", "A source the role cannot see reads NOT_ASSESSED, never clean",
     "The export probes every view with LIMIT 0 and every SHOW; unreadable checks run their fallback or read role_cannot_see; SQL emits *_not_visible rows.",
     "tools/export_results.py:938-985", r"_not_visible|role_cannot_see",
     [("function:tools/export_results.py:probe_visibility", "tools/export_results.py:938"),
      ("function:tools/export_results.py:unreadable_sources", "tools/export_results.py:978")]),
    ("failsafe_null_names", "Fail-safe rows with NULL names are not live tables",
     "Live tables need a name, no drop time and no table_entered_failsafe; dropped-table checks label them 'Fail-safe table (id)'.",
     "app/queries/common/sf_storage_live_tables.sql:25-28", r"table_entered_failsafe|__INCLUDE_sf_storage_live_tables__",
     [("common:sf_storage_live_tables", "app/queries/common/sf_storage_live_tables.sql:25")]),
    ("policy_references_gaps", "Session, password and authentication policies are not read from POLICY_REFERENCES",
     "Session coverage reads NOT_ASSESSED policy_attachment_not_listed when a policy exists; password and authentication come from SHOW ... ON ACCOUNT.",
     "app/queries/checks/sf_secx_session_policy_coverage.sql:13-14", r"policy_attachment_not_listed",
     [("checks:sf_secx_password_policy_posture", "app/queries/checks/sf_secx_password_policy_posture.sql:6"),
      ("checks:sf_secx_authentication_policy_posture", "app/queries/checks/sf_secx_authentication_policy_posture.sql:6")]),
    ("base_table_id_rename", "Read BASE_TABLE_ID or TABLE_ID while the rename rolls out",
     "SEARCH_OPTIMIZATION_HISTORY rows are read as OBJECT_CONSTRUCT(*) and keyed by COALESCE(o:BASE_TABLE_ID, o:TABLE_ID).",
     "app/queries/checks/sf_storage_search_optimization_value.sql:38-46", r"BASE_TABLE_ID", []),
    ("org_lag_settle", "Org billing windows end settle_days (3) before as-of",
     "ORGANIZATION_USAGE money checks take :settle_days (default 3) and end the window at as-of minus settle_days for the 72 h lag.",
     "app/queries/checks/sf_org_warehouse_spend_across_accounts.sql:41-69", r":settle_days", []),
]

DOCS = [
    ("modules/queries.md", "SQL checks module", "Folder layout, header format, includes, params, windows, money/entity, per-domain check tables."),
    ("logic/snowflake-traps.md", "Snowflake traps", "Where the SQL handles each CLAUDE.md money bug class and Snowflake trap, with examples and gaps."),
    ("data/snowflake-views.md", "Snowflake views read", "Every SNOWFLAKE.* view the checks read, reader counts, edition and privilege notes."),
]


def first_line(path: Path, rx: re.Pattern) -> int | None:
    for i, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if rx.search(line) and not line.startswith("--"):
            return i
    return None


def main() -> None:
    known = {json.loads(l)["id"] for l in (KG / "graph" / "nodes.jsonl").read_text(encoding="utf-8").splitlines() if l.strip()}
    out, missing = [], []
    for rid, name, summary, ev, marker, extra in RULES:
        node_id = f"business_rule:snowflake_trap:{rid}"
        path, _, lines = ev.partition(":")
        a, _, b = lines.partition("-")
        out.append({"kind": "node", "id": node_id, "type": "business_rule", "name": name, "path": path,
                    "line": int(a), "line_end": int(b or a), "summary": summary, "status": "verified"})
        out.append({"kind": "edge", "from": "document:logic/snowflake-traps.md", "to": node_id, "type": "documents",
                    "evidence": f"snowflake-audit-app-knowledge-graph/logic/snowflake-traps.md:1", "status": "verified"})
        srcs = list(extra)
        if marker:
            rx = re.compile(marker)
            for p in sorted(CHECKS.glob("*.sql")):
                n = first_line(p, rx)
                if n:
                    srcs.append((f"checks:{p.stem}", f"app/queries/checks/{p.name}:{n}"))
        seen = set()
        for src, evidence in srcs:
            if src in seen:
                continue
            seen.add(src)
            if src not in known:
                missing.append(src)
                continue
            out.append({"kind": "edge", "from": src, "to": node_id, "type": "implements", "evidence": evidence,
                        "status": "extracted" if marker else "verified"})
    for rel, name, summary in DOCS:
        did = f"document:{rel}"
        out.append({"kind": "node", "id": did, "type": "document", "name": name,
                    "path": f"snowflake-audit-app-knowledge-graph/{rel}", "line": 1, "line_end": 1,
                    "summary": summary, "status": "verified"})
        out.append({"kind": "edge", "from": did, "to": "document:app/queries/README.md", "type": "derived_from",
                    "evidence": "app/queries/README.md:1", "status": "verified"})
    (KG / "graph" / "extra_queries.jsonl").write_text("\n".join(json.dumps(o) for o in out) + "\n", encoding="utf-8", newline="\n")
    print(f"{sum(o['kind'] == 'node' for o in out)} nodes, {sum(o['kind'] == 'edge' for o in out)} edges; missing ids: {missing}")


if __name__ == "__main__":
    main()
