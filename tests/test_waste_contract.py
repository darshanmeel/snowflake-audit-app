"""tests/test_waste_contract.py: the possible-waste money rule ("stop showing spend as waste").

Driven by what the core defines: app/core/finding_columns.MONEY_COLUMN_KIND says which output columns
carry possible waste, and the registry says which checks emit one. A check's own spend is never a
waste dollar, and spend, change, saving and waste are never added together.

The UI's own list of waste items (WASTE_ITEMS in app/web/components/tab_registry.jsx) is checked
statically at the bottom: each item names its check and the columns that carry its money.
"""
from __future__ import annotations

import re
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from app.api.app import app
from app.core import finding_columns, registry

client = TestClient(app)
ROOT = Path(__file__).resolve().parent.parent
WEB = ROOT / "web" / "src"
WINDOWS = (7, 30, 90)

WASTE_COLUMNS = {c for c, kind in finding_columns.MONEY_COLUMN_KIND.items() if kind == "waste"}
# idle $ that another check already counts as waste: shown as context, never waste
CONTEXT_CHECKS = {"sf_cost_warehouse_idle_credits_daily", "sf_task_warehouse_vs_serverless"}

# The checks that measure possible waste today, each with the one column that carries it.
EXPECTED_WASTE_CHECKS = {
    "sf_wh_idle_minutes": "est_wasted_usd_list",
    "cost_failed_statement_waste": "est_wasted_usd_list",
    "sf_task_noop_runs": "est_wasted_usd_list",
    "sf_dt_unread_refresh_cost": "est_wasted_usd_list",
    "sf_ai_provisioned_throughput_use": "est_idle_usd_list",
}


def _output_columns(spec: registry.QuerySpec) -> set[str]:
    return {m.lower() for m in re.findall(r"\bAS\s+([A-Za-z_][A-Za-z0-9_]*)\s*(?:,|\n|$|--)", spec.body, re.IGNORECASE)}


def _waste_checks() -> dict[str, str]:
    """{query_id: waste column} for every check whose own SQL emits a waste-kind column."""
    out = {}
    for spec in registry.load_registry():
        cols = _output_columns(spec) & WASTE_COLUMNS
        if cols:
            out[spec.query_id] = sorted(cols)[0]
    return out


def _findings(window: int) -> dict[str, dict]:
    return {r["query_id"]: r for r in client.get("/api/findings", params={"window": window}).json()["findings"]}


def test_the_core_defines_waste_columns_and_they_are_only_waste_shaped():
    assert WASTE_COLUMNS == {"est_wasted_usd_list", "total_est_wasted_usd_list", "wasted_usd", "est_idle_usd_list"}
    for col in WASTE_COLUMNS:
        assert "wasted" in col or "idle" in col, col   # never a resource's own spend column


def test_the_waste_checks_are_the_expected_measured_ones():
    found = _waste_checks()
    assert set(EXPECTED_WASTE_CHECKS) <= set(found)
    for qid, col in EXPECTED_WASTE_CHECKS.items():
        assert col in _output_columns(registry.by_id(qid)), f"{qid}: {col} is not an output column of its own SQL"


def test_every_waste_check_names_a_waste_column_that_is_an_output_column_of_its_own_sql():
    for qid, col in _waste_checks().items():
        assert col in WASTE_COLUMNS
        assert col in _output_columns(registry.by_id(qid)), qid


def test_a_spend_column_is_never_classified_as_waste():
    for cols in (["usd_list"], ["est_current_usd_list"], ["est_compute_usd_list"]):
        assert finding_columns.money_column(cols) == (cols[0], "spend")
    assert finding_columns.money_column(["est_storage_usd_month"]) == ("est_storage_usd_month", "spend_month")
    assert finding_columns.money_column(["est_idle_context_usd_list"]) == ("est_idle_context_usd_list", "context")
    assert finding_columns.money_column(["change_usd_list", "usd_list"]) == ("change_usd_list", "change")
    assert finding_columns.money_column(["est_saving_usd_list"]) == ("est_saving_usd_list", "saving")
    assert finding_columns.money_column(["est_wasted_usd_list", "est_compute_usd_list"]) == (
        "est_wasted_usd_list", "waste")
    assert finding_columns.money_column(["warehouse_name", "status"]) is None


@pytest.mark.parametrize("window", WINDOWS)
def test_only_the_waste_checks_carry_a_waste_money_figure_in_the_findings_list(window):
    waste_ids = set(_waste_checks())
    for qid, row in _findings(window).items():
        money = row["money"]
        if money and money["kind"] == "waste":
            assert qid in waste_ids, f"{qid} shows a waste dollar but is not a waste check"
            assert money["column"] in WASTE_COLUMNS
        if qid in waste_ids and money:
            assert money["kind"] == "waste", qid
        if money and money["column"] in ("usd_list", "hour_usd_list"):
            assert money["kind"] == "spend", qid


@pytest.mark.parametrize("window", WINDOWS)
def test_a_waste_figure_is_the_sum_over_warn_and_critical_rows_only(window):
    findings = _findings(window)
    checked = 0
    for qid, col in EXPECTED_WASTE_CHECKS.items():
        money = findings[qid]["money"]
        if money is None:   # a check with no rows in this window carries no figure
            continue
        assert money["kind"] == "waste" and money["basis"] == "flagged", qid
        agg = client.get(f"/api/finding/{qid}/aggregate", params={
            "window": window, "agg": "sum", "value": money["column"], "status": ["WARN", "CRITICAL"]}).json()
        # no WARN/CRITICAL row at all reads ok_empty_filters and a $0 waste figure
        assert agg["outcome"] in ("ok_rows", "ok_empty_filters"), qid
        expected = round(agg["total_value"] or 0.0, 2) if agg["outcome"] == "ok_rows" else 0.0
        assert money["usd"] == pytest.approx(expected, abs=0.01), qid
        checked += 1
    assert checked >= 4


@pytest.mark.parametrize("window", WINDOWS)
def test_idle_context_is_never_waste_and_counts_every_row(window):
    findings = _findings(window)
    for qid in CONTEXT_CHECKS:
        money = findings[qid]["money"]
        if money is not None:
            assert money["kind"] == "context" and money["basis"] == "all", qid


def test_a_chargeback_report_reads_as_spend_not_waste():
    row = _findings(30)["cost_chargeback_by_warehouse"]
    assert row["money"]["kind"] == "spend"
    assert row["money"]["column"] == "usd_list"


def test_waste_spend_and_change_are_reported_apart_never_as_one_total():
    """Each finding carries one money figure with its own kind; the payload has no cross-kind total."""
    body = client.get("/api/findings", params={"window": 30}).json()
    assert not any("total" in k for k in body)
    kinds = set()
    for row in body["findings"]:
        if row["money"]:
            # storage checks also carry overlap_usd / overlap_tables (a table two checks both price)
            assert set(row["money"]) - {"overlap_usd", "overlap_tables"} == {"column", "kind", "usd", "unit", "basis", "currency", "mixed_currency", "price_basis", "usd_flagged"}
            kinds.add(row["money"]["kind"])
    assert {"waste", "spend", "change"} <= kinds


def test_a_waste_check_that_did_not_run_shows_no_dollar():
    """A failed check has no money figure at all (never $0)."""
    for qid in ("sf_org_dormant_accounts", "sf_obj_iceberg_tables"):
        row = _findings(30)[qid]
        assert row["outcome"] == "not_assessed" and row["money"] is None and row["affected"] is None


# ------------------------------------------------------------------------------------------
# The UI's WASTE_ITEMS list: static contract, kept for the UI rebuild.
# ------------------------------------------------------------------------------------------

WASTE_ITEM_RE = re.compile(
    r'\{\s*id:\s*"(?P<id>[a-z0-9_]+)"\s*,\s*area:\s*"(?P<area>[a-z_]+)"\s*,\s*'
    r'dollarCol:\s*(?P<dollarCol>"[a-z0-9_]+"|null)\s*,\s*'
    r'creditCol:\s*(?P<creditCol>"[a-z0-9_]+"|null)\s*,\s*'
    r'savingCol:\s*(?P<savingCol>"[a-z0-9_]+"|null)\s*,\s*'
    r'monthCol:\s*(?P<monthCol>"[a-z0-9_]+"|null)\s*,'
)
MONEY_FIELDS = ("dollarCol", "creditCol", "savingCol", "monthCol")


def _js_str_or_none(raw: str) -> str | None:
    return None if raw == "null" else raw.strip('"')


def _load_waste_items() -> list[dict]:
    text = (WEB / "components" / "tab_registry.tsx").read_text(encoding="utf-8")
    m = re.search(r"const WASTE_ITEMS(?::[^=]+)? = \[(?P<body>.*?)\n\];", text, re.DOTALL)
    assert m, "WASTE_ITEMS array not found (or its shape changed) in tab_registry.tsx"
    items = [
        {"id": mm.group("id"), "area": mm.group("area"), **{f: _js_str_or_none(mm.group(f)) for f in MONEY_FIELDS}}
        for mm in WASTE_ITEM_RE.finditer(m.group("body"))
    ]
    assert len(items) == m.group("body").count("{ id:"), "an item does not match the WASTE_ITEMS shape"
    assert len(items) >= 5
    return items


def test_ui_waste_items_dollar_column_is_only_a_waste_column():
    for item in _load_waste_items():
        assert item["dollarCol"] in (None, *WASTE_COLUMNS), item
        assert item["savingCol"] in (None, "est_saving_usd_list"), item
        assert item["monthCol"] is None or item["monthCol"].endswith("_usd_month"), item
        # one unit per item: waste, saving or per month, never two
        assert sum(item[f] is not None for f in ("dollarCol", "savingCol", "monthCol")) <= 1, item


def test_ui_waste_items_are_real_checks_with_their_column_in_their_own_sql():
    for item in _load_waste_items():
        spec = registry.by_id(item["id"])
        for f in MONEY_FIELDS:
            col = item[f]
            if col is not None:
                assert col in _output_columns(spec), f"{item['id']}: {col!r} is not an output column"


def test_ui_waste_items_carry_every_waste_check_the_core_defines():
    assert set(EXPECTED_WASTE_CHECKS) <= {item["id"] for item in _load_waste_items()}


def test_ui_overview_no_longer_projects_a_monthly_waste_figure():
    text = (WEB / "tabs" / "tab_overview.tsx").read_text(encoding="utf-8")
    assert "monthlyWaste" not in text and '"/mo"' not in text


def test_ui_is_waste_dollar_column_is_defined_only_in_waste_total():
    hits = [p.name for p in WEB.rglob("*.ts*")
            if "function isWasteDollarColumn" in p.read_text(encoding="utf-8")]
    assert hits == ["waste_total.tsx"]
