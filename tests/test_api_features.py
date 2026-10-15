"""The API for the newer features: warehouse and database filters and their pickers, row CSV, tag
compliance, "fix these first", the price basis and discount rule, and the one checks-that-ran count.
"""
from __future__ import annotations

import csv
import io

import pytest
from fastapi.testclient import TestClient

from app.api.app import app
from app.core import data as app_core_data
from app.core import registry

client = TestClient(app)
W = {"window": 30}
WH_CHECK = "sf_wh_idle_minutes"           # keyed by warehouse_id (name through dims.dim_warehouse)
NAME_CHECK = "sf_cost_warehouse_idle_credits_daily"   # carries warehouse_name
DB_CHECK = "sf_chg_by_database_schema"     # carries database_name and schema_name
FAILED_CHECK = "sf_org_dormant_accounts"   # marked failed on purpose in the fixture


def _findings(**params) -> dict[str, dict]:
    body = client.get("/api/findings", params={**W, **params}).json()
    return {r["query_id"]: r for r in body["findings"]}


@pytest.fixture
def settings_restored():
    """Settings a test PUTs are put back afterwards."""
    before = client.get("/api/settings/privacy").json()["mask_user_identities"]
    required = client.get("/api/settings/required-tags").json()["keys"]
    yield
    client.put("/api/settings/privacy", json={"mask_user_identities": before})
    client.put("/api/settings/required-tags", json={"keys": required})


# ---- warehouse and database filters ------------------------------------------------------------------


def test_warehouse_picker_names_every_warehouse_with_its_id():
    body = client.get("/api/warehouses").json()
    assert body["unit"] == "warehouses" and body["count"] == len(body["warehouses"]) >= 3
    by_name = {w["warehouse_name"]: w for w in body["warehouses"]}
    assert by_name["WH_ETL"]["label"] == "WH_ETL (1001)"
    assert all(w["source"] in ("listed", "billing") for w in body["warehouses"])


def test_database_picker_lists_databases_with_their_schemas():
    body = client.get("/api/databases").json()
    assert body["unit"] == "databases" and body["count"] >= 3
    names = {d["database_name"] for d in body["databases"]}
    assert {"RAW_DB", "SANDBOX_DB"} <= names
    raw = next(d for d in body["databases"] if d["database_name"] == "RAW_DB")
    assert any(s["fqn"] == "RAW_DB.LANDING" for s in raw["schemas"])
    assert not any(n.startswith("(") for n in names), "a placeholder is not a database"


def test_warehouse_filter_keeps_only_that_warehouse_and_says_so():
    everything, one = _findings(), _findings(warehouse="WH_ETL")
    assert one[NAME_CHECK]["dim_applied"] == {"warehouse": True, "database": None, "schema": None}
    assert 0 < one[NAME_CHECK]["row_count"] < everything[NAME_CHECK]["row_count"]
    rows = client.get(f"/api/finding/{NAME_CHECK}", params={**W, "warehouse": "WH_ETL", "limit": 5000}).json()["rows"]
    assert rows and {r["warehouse_name"] for r in rows} == {"WH_ETL"}
    # A check keyed by warehouse_id follows the filter through dims.dim_warehouse.
    assert one[WH_CHECK]["dim_applied"]["warehouse"] is True
    assert one[WH_CHECK]["row_count"] < everything[WH_CHECK]["row_count"]


def test_a_name_may_carry_its_id_and_case_is_ignored():
    assert _findings(warehouse="wh_etl (1001)")[NAME_CHECK]["row_count"] == _findings(warehouse="WH_ETL")[NAME_CHECK]["row_count"]


def test_a_check_with_no_warehouse_column_is_left_unfiltered_and_says_not_filtered():
    everything, one = _findings(), _findings(warehouse="WH_ETL")
    qid = "cost_daily_spikes"
    cols = app_core_data.finding_columns(qid)
    assert not {"warehouse_name", "warehouse", "warehouse_id"} & set(cols)
    assert one[qid]["dim_applied"]["warehouse"] is False
    assert one[qid]["row_count"] == everything[qid]["row_count"]
    detail = client.get(f"/api/finding/{qid}", params={**W, "warehouse": "WH_ETL"}).json()
    assert detail["scope"]["warehouse_applied"] is False and detail["dims"]["warehouses"] == ["WH_ETL"]


def test_no_filter_asks_nothing():
    row = _findings()[WH_CHECK]
    assert row["dim_applied"] is None
    detail = client.get(f"/api/finding/{WH_CHECK}", params=W).json()
    assert detail["scope"]["warehouse_applied"] is None


def test_database_and_schema_filters_follow_the_database_column():
    everything = _findings()
    only = _findings(database="RAW_DB")
    assert only[DB_CHECK]["dim_applied"]["database"] is True
    assert 0 < only[DB_CHECK]["row_count"] < everything[DB_CHECK]["row_count"]
    rows = client.get(f"/api/finding/{DB_CHECK}", params={**W, "database": "RAW_DB", "limit": 5000}).json()["rows"]
    assert {r["database_name"] for r in rows} == {"RAW_DB"}
    schema = client.get(f"/api/finding/{DB_CHECK}", params={**W, "schema": "RAW_DB.LANDING", "limit": 5000}).json()
    assert schema["scope"]["schema_applied"] is True
    assert {(r["database_name"], r["schema_name"]) for r in schema["rows"]} == {("RAW_DB", "LANDING")}


def test_the_filters_reach_the_aggregate_too():
    plain = client.get(f"/api/finding/{NAME_CHECK}/aggregate", params={**W, "agg": "count"}).json()
    one = client.get(f"/api/finding/{NAME_CHECK}/aggregate",
                     params={**W, "agg": "count", "warehouse": "WH_ETL"}).json()
    assert one["scope"]["warehouse_applied"] is True and 0 < one["total_value"] < plain["total_value"]


# ---- row CSV -----------------------------------------------------------------------------------------


def _csv(qid: str, **params):
    resp = client.get(f"/api/finding/{qid}/rows.csv", params={**W, **params})
    return resp, list(csv.DictReader(io.StringIO(resp.text))) if resp.status_code == 200 else []


def test_csv_has_every_row_not_just_one_page():
    resp, rows = _csv(NAME_CHECK)
    total = client.get(f"/api/finding/{NAME_CHECK}", params={**W, "limit": 1}).json()["rows_total"]
    assert resp.status_code == 200 and resp.headers["content-type"].startswith("text/csv")
    assert "attachment" in resp.headers["content-disposition"] and NAME_CHECK in resp.headers["content-disposition"]
    assert len(rows) == total == int(resp.headers["x-rows"]) and resp.headers["x-truncated"] == "false"
    assert {"warehouse_name", "status"} <= set(rows[0])


def test_csv_honours_the_window_and_the_filters():
    _, all_rows = _csv(NAME_CHECK)
    _, one = _csv(NAME_CHECK, warehouse="WH_ETL")
    assert 0 < len(one) < len(all_rows) and {r["warehouse_name"] for r in one} == {"WH_ETL"}
    _, seven = _csv(NAME_CHECK, window=7)
    assert {r["window_days"] for r in seven} == {"7"}
    _, critical = _csv(NAME_CHECK, status="CRITICAL")
    assert critical and {r["status"] for r in critical} == {"CRITICAL"}


def test_csv_masks_user_names_when_masking_is_on(settings_restored):
    qid = "sf_cost_query_attribution_by_user"
    _, plain = _csv(qid)
    assert client.put("/api/settings/privacy", json={"mask_user_identities": True}).status_code == 200
    _, masked = _csv(qid)
    col = "user_name"
    assert plain and len(plain) == len(masked)
    real = {r[col] for r in plain if r[col] and not r[col].startswith("(")}
    assert real and not real & {r[col] for r in masked}, "a real user name reached the CSV"
    assert all("***" in r[col] for r in masked if r[col] and not r[col].startswith("("))


def test_csv_of_a_check_that_was_not_assessed_is_409_and_unknown_is_404():
    assert client.get(f"/api/finding/{FAILED_CHECK}/rows.csv", params=W).status_code == 409
    assert client.get("/api/finding/no_such_check/rows.csv", params=W).status_code == 404
    assert client.get(f"/api/finding/{NAME_CHECK}/rows.csv", params={"window": 5}).status_code == 422


def test_csv_of_a_filter_that_matches_nothing_is_the_header_alone():
    resp, rows = _csv(NAME_CHECK, warehouse="NO_SUCH_WAREHOUSE")
    assert resp.status_code == 200 and rows == [] and resp.text.startswith("window_days,")


# ---- tag compliance ----------------------------------------------------------------------------------


def test_tag_compliance_with_no_required_tags_shows_coverage_by_object_type(settings_restored):
    client.put("/api/settings/required-tags", json={"keys": []})
    body = client.get("/api/tags/compliance", params=W).json()
    assert body["available"] and body["mode"] == "coverage" and body["configured_keys"] == []
    assert body["keys"], "the most used tag keys are listed"
    types = {t["entity_type"]: t for t in body["object_types"]}
    assert {"warehouse", "database"} <= set(types)
    assert types["warehouse"]["total"] >= 3 and types["warehouse"]["noun"] == "warehouses"
    assert body["spend"]["unit"] == "usd" and body["spend"]["price_basis"] in ("invoice", "cli", "settings")


def test_required_tags_are_a_setting_and_drive_the_compliance(settings_restored):
    put = client.put("/api/settings/required-tags", json={"keys": ["cost_center", "team", "cost-center"]})
    assert put.status_code == 200 and put.json()["keys"] == ["cost_center", "team", "cost-center"]
    body = client.get("/api/tags/compliance", params=W).json()
    assert body["mode"] == "required" and [k["tag_key"] for k in body["keys"]] == ["costcenter", "team"]
    wh = next(t for t in body["object_types"] if t["entity_type"] == "warehouse")
    cc = next(k for k in wh["per_key"] if k["tag_key"] == "costcenter")
    assert cc["tagged"] + cc["missing"] == wh["total"] and cc["missing"] >= 1
    assert cc["missing_examples"] and all("(" in name for name in cc["missing_examples"][:1]), "names carry their id"
    assert cc["missing_usd"] is not None and cc["missing_usd"] >= 0
    team = next(k for k in wh["per_key"] if k["tag_key"] == "team")
    assert team["tagged"] == 0 and team["missing"] == wh["total"]
    spend = body["spend"]
    per = {k["tag_key"]: k for k in spend["per_key"]}
    assert spend["total_usd"] > 0 and per["team"]["untagged_usd"] == pytest.approx(spend["total_usd"], abs=0.01)
    assert per["costcenter"]["covered_usd"] + per["costcenter"]["untagged_usd"] == pytest.approx(spend["total_usd"], abs=0.02)
    assert 0 < per["costcenter"]["untagged_usd"] < spend["total_usd"]


def test_keys_in_the_request_override_the_setting_and_a_bad_put_is_422(settings_restored):
    body = client.get("/api/tags/compliance", params={**W, "keys": ["pii"]}).json()
    assert body["mode"] == "required" and body["configured_keys"] == ["pii"]
    assert client.put("/api/settings/required-tags", json={"keys": "cost_center"}).status_code == 422
    too_many = [f"k{i}" for i in range(30)]
    assert client.put("/api/settings/required-tags", json={"keys": too_many}).status_code == 422


def test_an_unbuilt_tag_table_says_so_instead_of_reading_clean(monkeypatch):
    real = app_core_data._connect

    class NoTags:
        def __init__(self, con):
            self.con = con

        def execute(self, sql, params=None):
            if "information_schema.tables" in sql and params and params[0] == "tags":
                return self.con.execute("SELECT 0")
            return self.con.execute(sql, params) if params is not None else self.con.execute(sql)

        def close(self):
            self.con.close()

    monkeypatch.setattr(app_core_data, "_connect", lambda *a, **k: NoTags(real(*a, **k)))
    body = client.get("/api/tags/compliance", params=W).json()
    assert body["available"] is False and "not built" in body["reason"] and "object_types" not in body


# ---- fix these first ---------------------------------------------------------------------------------


def test_fix_first_labels_priced_and_critical_no_usd_apart():
    body = client.get("/api/fix-first", params={**W, "limit": 50}).json()
    assert set(body["counts"]) == {"priced_window", "priced_month", "critical_no_usd", "unit"}
    priced = body["priced_window"]
    assert priced and [i["usd"] for i in priced] == sorted((i["usd"] for i in priced), reverse=True)
    assert all(i["group"] == "priced_window" and i["kind"] in ("waste", "saving", "gap") and i["per"] == "window"
               for i in priced)
    assert all(i["group"] == "priced_month" and i["kind"] == "saving_month" and i["per"] == "month"
               for i in body["priced_month"])
    critical = body["critical_no_usd"]
    assert critical, "the fixture has CRITICAL findings with no waste or saving figure"
    assert all(i["group"] == "critical_no_usd" and i["critical"] > 0 for i in critical)
    ids = [i["query_id"] for g in ("priced_window", "priced_month", "critical_no_usd") for i in body[g]]
    assert len(ids) == len(set(ids)), "a finding is in one group only"
    assert [i["query_id"] for i in body["items"]] == ids
    assert [i["critical"] for i in critical] == sorted((i["critical"] for i in critical), reverse=True)


def test_fix_first_dollars_are_the_findings_own_dollars():
    body = client.get("/api/fix-first", params={**W, "limit": 50}).json()
    findings = _findings()
    for item in body["priced_window"] + body["priced_month"]:
        assert item["usd"] == findings[item["query_id"]]["money"]["usd"]


def test_fix_first_limit_and_filters():
    body = client.get("/api/fix-first", params={**W, "limit": 2}).json()
    assert all(len(body[g]) <= 2 for g in ("priced_window", "priced_month", "critical_no_usd"))
    assert client.get("/api/fix-first", params={**W, "limit": 0}).status_code == 422
    assert client.get("/api/fix-first", params={**W, "warehouse": "WH_ETL"}).status_code == 200


# ---- price basis and the discount what-if ------------------------------------------------------------


def test_every_priced_figure_names_its_price_basis():
    findings = _findings()
    usd = [r for r in findings.values() if r["money"] and r["money"]["unit"] == "usd"]
    assert usd and {r["money"]["price_basis"] for r in usd} <= {"invoice", "cli", "settings", "unpriced"}
    cur = [r for r in findings.values() if r["money"] and r["money"]["unit"] == "currency"]
    assert all(r["money"]["price_basis"] == "invoice_currency" for r in cur)
    basis = client.get("/api/findings", params=W).json()["price_basis"]
    assert basis["invoice_derived"] is True and basis["source_short"] == "invoice" and basis["credit_price_usd"] > 0


def _pricing(source, credit=3.0):
    return {"pricing": {"source": source, "credit_price_usd": credit, "storage_price_usd_tb_month": 23.0}}


def test_a_discount_never_stacks_on_an_invoice_rate(monkeypatch):
    monkeypatch.setattr(app_core_data, "direct_export_info", lambda: _pricing("usage_in_currency_daily"))
    assert app_core_data.effective_discount_pct(0.2) == 0.0
    info = app_core_data.discount_info(0.2)
    assert info == {"configured": 0.2, "effective": 0.0, "ignored": True, "reason": info["reason"]} and info["reason"]
    monkeypatch.setattr(app_core_data, "direct_export_info", lambda: _pricing("cli"))
    assert app_core_data.effective_discount_pct(0.2) == 0.2
    assert app_core_data.discount_info(0.2)["ignored"] is False
    monkeypatch.setattr(app_core_data, "direct_export_info", lambda: _pricing("settings"))
    assert app_core_data.price_basis()["source_short"] == "settings"
    monkeypatch.setattr(app_core_data, "direct_export_info", lambda: {"pricing": {"source": None, "credit_price_usd": None}})
    assert app_core_data.price_basis()["source_short"] == "unpriced"


def test_the_discount_is_not_applied_to_the_test_db_because_its_rate_is_the_invoice(settings_restored):
    from app.core import config as app_config
    app_config.save_settings_local({"discount_pct": 0.25})
    try:
        meta = client.get("/api/meta").json()
        assert meta["discount_pct"] == 0.25 and meta["discount"]["effective"] == 0.0 and meta["discount"]["ignored"]
        detail = client.get(f"/api/finding/{NAME_CHECK}", params=W).json()
        assert detail["discount_pct"] == 0.0 and detail["discount"]["configured"] == 0.25
        plain = _findings()[WH_CHECK]["money"]["usd"]
        assert plain > 0, "the priced waste is the same with or without the what-if"
    finally:
        app_config.save_settings_local({"discount_pct": 0.0})


def test_the_rollup_carries_its_price_basis_and_the_reconciliation():
    body = client.get("/api/rollup", params={"area": "cost", "tag_key": "cost_center", "window": 30}).json()
    assert body["price_basis"]["source_short"] in ("invoice", "cli", "settings")
    rec = body["reconciliation"]
    assert rec is not None and {"billing_usd", "rollup_usd", "reconciled"} <= set(rec)


# ---- one checks-that-ran count -----------------------------------------------------------------------


def test_one_ran_count_on_every_route():
    meta = client.get("/api/meta").json()
    findings = client.get("/api/findings", params=W).json()
    coverage = client.get("/api/coverage").json()
    assert meta["checks_ran"] == findings["checks_ran"] == coverage["checks_ran"]
    ran = meta["checks_ran"]
    assert meta["checks"]["ran"] == ran["ran"] and meta["checks"]["total"] == ran["total"]
    assert ran["unit"] == "checks" and ran["total"] == sum(1 for s in registry.load_registry() if s.executable)
    assert ran["ran"] + sum(ran["not_ran"].values()) == ran["total"]
    assert ran["not_ran"].get("build_failed", 0) >= 2, "the two failed checks are not counted as run"
    # The count does not move with the window.
    assert client.get("/api/findings", params={"window": 7}).json()["checks_ran"] == ran


# ---- what the role could see, edition, per-check requires --------------------------------------------


def test_a_not_assessed_check_names_its_requires_grant_and_cause():
    row = _findings()[FAILED_CHECK]
    na = row["not_assessed"]
    assert na["code"] == "build_failed" and na["cause"] in ("no_access", "edition_too_low")
    assert na["requires"] and "IMPORTED PRIVILEGES" in na["requires"]
    assert na["grants"] and all(g.startswith("GRANT") for g in na["grants"])
    assert any("ORGANIZATION_USAGE" in s for s in na["sources"])
    coverage = client.get("/api/coverage").json()
    entry = next(c for c in coverage["checks_not_ok"] if c["query_id"] == FAILED_CHECK)
    assert entry["requires"] == na["requires"] and entry["grants"] == na["grants"]


def test_coverage_carries_the_visibility_probe_and_the_edition():
    body = client.get("/api/coverage").json()
    vis = body["visibility"]
    assert vis is not None and vis["probed"] > 50
    assert isinstance(vis["unreadable"], list)
    assert body["edition"] is None or "edition" in body["edition"]
    assert client.get("/api/meta").json()["price_basis"]["label"]


def test_the_warehouse_gap_becomes_a_per_check_note(monkeypatch):
    real = app_core_data.direct_export_info
    fake = {**(real() or {}), "visibility": {"probed": 9, "unreadable": {}, "failed_pre": {},
                                             "warehouses": {"metered": 40, "missing_from_show": 8}}}
    monkeypatch.setattr(app_core_data, "direct_export_info", lambda: fake)
    summary = app_core_data.visibility_summary()
    assert summary["warehouses"] == {"billed": 40, "visible": 32, "missing": 8, "unit": "warehouses",
                                     "note": summary["warehouses"]["note"], "grant": summary["warehouses"]["grant"]}
    assert summary["warehouses"]["note"].startswith("Role sees 32 of 40 billed warehouses")
    limited = [s.query_id for s in registry.load_registry() if app_core_data.finding_visibility(s, summary)]
    assert WH_CHECK in limited and "cost_daily_spikes" not in limited
    body = client.get("/api/findings", params=W).json()
    assert {r["query_id"]: r["visibility"] for r in body["findings"]}[WH_CHECK]["note"].startswith("Role sees 32 of 40")
