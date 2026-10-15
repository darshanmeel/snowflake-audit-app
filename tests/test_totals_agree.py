"""tests/test_totals_agree.py: the same dollars on every screen.

Overview, the cost pages and Waste & savings all read the same priced billing rows, so their totals
must be the same number, not several numbers that happen to be close. Spend, change and possible
waste are separate kinds of dollar and are never added together. A 90-day window the export could
only fill with 30 days says so.

Runs on the fake account's test DB (tests/conftest.py).
"""
from __future__ import annotations

import pytest
from fastapi.testclient import TestClient

from app.api.app import app
from app.core import data as app_core_data

client = TestClient(app)

# Each reports the account's whole priced spend for the window, from a different cut.
TOTAL_SPEND = [
    ("cost_chargeback_by_account", "usd_list"),
    ("cost_chargeback_by_service", "usd_list"),
    ("cost_chargeback_by_service", "usd_list"),
    ("cost_period_over_period", "est_current_usd_list"),
    ("cost_daily_spikes", "est_day_usd_list"),
]
# Warehouse compute only (the serverless services are not in it): two cuts of the same number.
WAREHOUSE_SPEND = [
    ("cost_chargeback_by_warehouse", "usd_list"),
    ("cost_by_hour_of_day", "usd_list"),
]


def _agg(query_id: str, value: str, window: int, **params) -> dict:
    return client.get(f"/api/finding/{query_id}/aggregate",
                      params={"window": window, "agg": "sum", "value": value, **params}).json()


def _total(query_id: str, value: str, window: int, **params) -> float:
    body = _agg(query_id, value, window, **params)
    assert body["outcome"] == "ok_rows", (query_id, body["outcome"])
    return body["total_value"] or 0.0


def _findings(window: int, **params) -> dict[str, dict]:
    return {r["query_id"]: r for r in client.get(
        "/api/findings", params={"window": window, **params}).json()["findings"]}


@pytest.mark.parametrize("window", [7, 30, 90])
def test_total_spend_is_one_number_across_the_cost_pages(window):
    totals = {qid: _total(qid, col, window) for qid, col in TOTAL_SPEND}
    base = totals["cost_chargeback_by_account"]
    assert base > 0
    for qid, total in totals.items():
        assert total == pytest.approx(base, rel=1e-6), (qid, totals)


@pytest.mark.parametrize("window", [7, 30, 90])
def test_warehouse_spend_agrees_and_is_within_total_spend(window):
    totals = {qid: _total(qid, col, window) for qid, col in WAREHOUSE_SPEND}
    assert totals["cost_by_hour_of_day"] == pytest.approx(totals["cost_chargeback_by_warehouse"], rel=1e-6)
    assert 0 < totals["cost_chargeback_by_warehouse"] <= _total("cost_chargeback_by_account", "usd_list", window)


def test_a_longer_window_never_totals_less_than_a_shorter_one():
    seven, thirty, ninety = (_total("cost_chargeback_by_account", "usd_list", w) for w in (7, 30, 90))
    assert 0 < seven < thirty
    assert ninety >= thirty


def test_the_90_day_window_is_the_30_days_the_export_had_and_says_so():
    """90d holds the same rows as 30d, so the two totals match, and every place that shows 90d flags it partial."""
    assert _total("cost_chargeback_by_account", "usd_list", 90) == pytest.approx(
        _total("cost_chargeback_by_account", "usd_list", 30))
    windows = {w["days"]: w for w in client.get("/api/meta").json()["windows"]}
    assert windows[90] == {"days": 90, "available": True, "covered_days": 30, "partial": True}
    assert windows[30]["partial"] is False and windows[7]["partial"] is False
    finding = client.get("/api/finding/cost_chargeback_by_account", params={"window": 90}).json()
    assert finding["window_coverage"]["partial"] is True and finding["window_coverage"]["covered_days"] == 30
    assert finding["window_coverage"]["as_of_date"] == "2026-09-21"
    assert _findings(90)["cost_chargeback_by_account"]["partial"] is True
    assert _findings(30)["cost_chargeback_by_account"]["partial"] is False


def test_the_money_cutoff_is_one_and_today_is_not_in_it():
    cutoff = client.get("/api/meta").json()["cost_cutoff"]
    assert cutoff == {"data_through": "2026-09-20", "partial_day": None, "partial_until": None, "partial_from": None}


@pytest.mark.parametrize("window", [7, 30, 90])
def test_the_account_filter_partitions_the_total(window):
    """Rows for the account plus the rows with no account add back to the unfiltered total."""
    unfiltered = _total("cost_period_over_period", "est_current_usd_list", window)
    mine = _agg("cost_period_over_period", "est_current_usd_list", window, account_ids="FAKE01")
    assert mine["outcome"] == "ok_rows" and mine["excluded_no_account"] is not None
    assert mine["total_value"] + (mine["excluded_no_account"]["value"] or 0.0) == pytest.approx(unfiltered, rel=1e-6)
    other = _agg("cost_period_over_period", "est_current_usd_list", window, account_ids="NOT_AN_ACCOUNT")
    assert other["outcome"] == "ok_empty_filters" and other["rows_in_window"] > 0


def test_every_money_figure_in_the_findings_list_matches_the_detail_aggregate():
    """A waste or saving headline is the sum over CRITICAL and WARN rows of the check's money column;
    every other kind is the sum over every row it lists (total rows left out), so a tile and the chart
    under it read the same number."""
    findings = _findings(30)
    checked = flagged_basis = all_basis = 0
    for qid, row in findings.items():
        money = row["money"]
        if not money:
            continue
        flagged = money["basis"] == "flagged"
        body = _agg(qid, money["column"], 30, **({"status": ["WARN", "CRITICAL"]} if flagged else {}))
        if money["usd"] is None:
            # never $0 for a figure nothing priced (or an amount across currencies)
            assert row["money_reason"] == "unpriced" or money["mixed_currency"], (qid, money)
            continue
        if money["unit"] == "currency":
            # invoice-currency checks are single-currency on the fake account: never "mixed"
            assert not money["mixed_currency"], qid
            factor = 1.0
        else:
            factor = 1 - body["discount_pct"]
        expected = round((body["total_value"] or 0.0) * factor, 2) if body["outcome"] == "ok_rows" else 0.0
        flagged_basis += flagged
        all_basis += not flagged
        assert money["usd"] == pytest.approx(expected, abs=0.011), (qid, money)
        checked += 1
    assert checked > 60 and flagged_basis > 0 and all_basis > 0


def test_the_discount_reaches_the_list_and_leaves_the_raw_aggregate_alone(tmp_path, monkeypatch):
    raw = {"sf_wh_idle_minutes": _total("sf_wh_idle_minutes", "est_wasted_usd_list", 30, status=["WARN", "CRITICAL"]),
           "sf_wh_load_utilization": _total("sf_wh_load_utilization", "est_compute_usd_list", 30)}
    cfg = tmp_path / "config"
    cfg.mkdir()
    (cfg / "settings.yml").write_text("discount_pct: 0.25\n", encoding="utf-8")
    monkeypatch.setenv("AUDIT_CONFIG_DIR", str(cfg))
    real_info = app_core_data.direct_export_info
    # The fixture's price is the invoice rate, which is already discounted; a typed-in price is not.
    monkeypatch.setattr(app_core_data, "direct_export_info",
                        lambda: {**real_info(), "pricing": {**real_info()["pricing"], "source": "cli"}})
    findings = _findings(30)
    for qid, total in raw.items():
        assert total > 0
        assert findings[qid]["money"]["usd"] == pytest.approx(round(total * 0.75, 2), abs=0.011), qid
        body = _agg(qid, findings[qid]["money"]["column"], 30,
                    **({"status": ["WARN", "CRITICAL"]} if findings[qid]["money"]["basis"] == "flagged" else {}))
        assert body["total_value"] == pytest.approx(total) and body["discount_pct"] == 0.25


def test_each_finding_carries_one_kind_of_dollar_and_the_kinds_are_never_summed():
    """A check's figure is one column of one kind: a report with spend, change and waste columns never adds them."""
    findings = _findings(30)
    kinds = {row["money"]["kind"] for row in findings.values() if row["money"]}
    assert {"spend", "change", "waste", "saving"} <= kinds
    # cost_period_over_period has current, previous and change columns; its headline is the change alone.
    pop = findings["cost_period_over_period"]["money"]
    assert pop["kind"] == "change" and pop["column"] == "est_change_usd_list"
    change = _total("cost_period_over_period", "est_change_usd_list", 30)
    current = _total("cost_period_over_period", "est_current_usd_list", 30)
    assert pop["usd"] == pytest.approx(round(change, 2), abs=0.011)
    assert pop["usd"] != pytest.approx(round(change + current, 2), abs=0.011)
    # and the waste checks never carry a spend kind
    for qid in ("sf_wh_idle_minutes", "cost_failed_statement_waste"):
        assert findings[qid]["money"]["kind"] == "waste"


def test_no_route_returns_a_total_that_adds_spend_change_and_waste():
    body = client.get("/api/findings", params={"window": 30}).json()
    assert not any(k for k in body if "total" in k or "sum" in k)
    meta = client.get("/api/meta").json()
    assert not any(k for k in meta if "total" in k or "waste" in k or "spend" in k)


def test_a_check_that_failed_has_no_dollar_never_zero():
    row = _findings(30)["sf_org_dormant_accounts"]
    assert row["outcome"] == "not_assessed" and row["money"] is None
    body = client.get("/api/finding/sf_org_dormant_accounts/aggregate",
                      params={"window": 30, "agg": "sum", "value": "amount"}).json()
    assert body["outcome"] == "not_assessed" and "total_value" not in body
