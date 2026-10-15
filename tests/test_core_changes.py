"""Money kinds and basis, entity counts, total rows, org currency amounts, tag tables, masking and the
new Lineage and Audit checks, on the fake Snowflake account (the test db is built from tools/sql_smoke.py)."""
from __future__ import annotations

import duckdb
import pandas as pd
import pytest
from fastapi.testclient import TestClient

from app.api.app import app
from app.core import finding_columns as fc
from app.core import identity, pricing, registry
from tools import build_tags

client = TestClient(app)
NEW_CHECKS = {
    "sf_lin_blast_radius", "sf_lin_table_flows", "sf_lin_unused_views", "sf_audit_object_ddl_timeline",
    "sf_audit_grant_activity", "sf_audit_admin_signins", "sf_audit_admin_sessions",
}


def _findings(window=30, **params) -> dict[str, dict]:
    body = client.get("/api/findings", params={"window": window, **params}).json()
    return {r["query_id"]: r for r in body["findings"]}


# ---- column rules (no db) -------------------------------------------------------------------------------------------
def test_context_and_month_kinds_are_not_waste():
    assert fc.MONEY_COLUMN_KIND["est_idle_context_usd_list"] == "context"
    assert fc.MONEY_COLUMN_KIND["est_saving_usd_month"] == "saving_month"
    assert fc.MONEY_COLUMN_KIND["est_storage_usd_month"] == "spend_month"
    assert "context" not in fc.FLAGGED_KINDS and "spend_month" not in fc.FLAGGED_KINDS
    assert fc.money_column(["est_idle_context_usd_list"]) == ("est_idle_context_usd_list", "context")


def test_a_declared_money_column_wins_and_a_prior_period_column_never_does():
    cols = ["est_previous_usd_list", "est_current_usd_list", "est_change_usd_list"]
    assert fc.money_column(cols) == ("est_change_usd_list", "change")
    assert fc.money_column(cols, "est_current_usd_list") == ("est_current_usd_list", "spend")
    assert fc.money_column(["prev_amount", "amount"]) == ("amount", "spend")
    assert fc.money_column(["est_previous_usd_list"]) is None


def test_org_currency_amounts_are_money_and_never_discounted():
    for col in ("amount", "prev_amount", "invoice_amount", "est_cost", "prepaid_balance", "storage_amount"):
        assert pricing.is_money(col) and pricing.is_currency_amount(col) and not pricing.is_list_usd(col), col
    assert not pricing.is_money("amount_per_credit") and not pricing.is_money("credit_rate")
    df = pd.DataFrame({"amount": [10.0], "est_usd_list": [10.0]})
    out = pricing.apply(df, 0.5)
    assert "amount_disc" not in out.columns and out["est_usd_list_disc"][0] == 5.0
    assert fc.money_column(["currency", "amount"]) == ("amount", "spend")
    assert fc.money_unit("amount") == "currency" and fc.money_unit("est_usd_list") == "usd"
    assert fc.money_column(["prepaid_balance"]) == ("prepaid_balance", "balance")


def test_entity_spec_uses_the_declared_entity_and_qualifies_a_table():
    spec = fc.entity_spec(["database_name", "schema_name", "table_name", "stream_fqn"],
                          {"noun": "streams", "columns": ["stream_fqn"]})
    assert spec["noun"] == "streams" and spec["columns"] == ["stream_fqn"]
    auto = fc.entity_spec(["database_name", "schema_name", "table_name"])
    assert auto["noun"] == "tables" and auto["columns"] == ["database_name", "schema_name", "table_name"]
    wh = fc.entity_spec(["warehouse_id"])
    assert wh["dim_table"] == "dim_warehouse" and wh["dim_key"] == "warehouse_id"
    assert fc.entity_spec(["usage_date"]) is None


# ---- money summary on the fake account -------------------------------------------------------------------------------
def test_a_spend_check_tile_is_the_sum_of_every_row_it_lists():
    """The tile and the chart read one figure: every row's own column, flagged or not (was $0 vs $36)."""
    f = _findings()["sf_obj_hybrid_tables"]
    assert f["money"]["kind"] == "spend" and f["money"]["basis"] == "all"
    table = client.get("/api/finding/sf_obj_hybrid_tables", params={"window": 30, "limit": 500}).json()
    total = sum(r[f["money"]["column"]] or 0 for r in table["rows"])
    assert f["money"]["usd"] == pytest.approx(total, abs=0.01) and total > 0


def test_a_waste_check_counts_flagged_rows_and_is_the_only_idle_waste_home():
    rows = _findings()
    assert rows["sf_wh_idle_minutes"]["money"]["kind"] == "waste"
    assert rows["sf_wh_idle_minutes"]["money"]["basis"] == "flagged"
    for qid in ("sf_cost_warehouse_idle_credits_daily", "sf_task_warehouse_vs_serverless"):
        assert rows[qid]["money"]["kind"] == "context", qid
    waste_ids = {q for q, r in rows.items() if r["money"] and r["money"]["kind"] == "waste"}
    assert "sf_cost_warehouse_idle_credits_daily" not in waste_ids and "sf_task_warehouse_vs_serverless" not in waste_ids


def test_storage_month_dollars_have_their_own_kinds():
    rows = _findings()
    assert rows["sf_storage_retention_policy"]["money"]["kind"] in ("spend_month", "saving_month")
    kinds = {r["money"]["kind"] for q, r in rows.items() if r["money"] and q.startswith("sf_storage_")}
    assert not kinds & {"waste", "saving"}


def test_a_total_row_is_not_added_to_its_parts():
    f = _findings()["sf_cost_invoice_vs_metered"]
    assert f["money"]["column"] == "invoice_amount" and f["money"]["unit"] == "currency"
    con = duckdb.connect(str(__import__("os").environ["AUDIT_DB"]), read_only=True)
    try:
        parts = con.execute('SELECT SUM(invoice_amount) FROM findings."f_sf_cost_invoice_vs_metered" '
                            "WHERE window_days = 30 AND NOT is_total_row").fetchone()[0]
        every = con.execute('SELECT SUM(invoice_amount) FROM findings."f_sf_cost_invoice_vs_metered" '
                            "WHERE window_days = 30").fetchone()[0]
    finally:
        con.close()
    assert f["money"]["usd"] == pytest.approx(parts, abs=0.01) and every > parts


def test_org_amounts_carry_their_currency_and_are_not_discounted():
    f = _findings()["sf_org_spend_by_account"]
    assert f["money"]["unit"] == "currency" and f["money"]["currency"] == "USD" and not f["money"]["mixed_currency"]
    kinds = {c["name"]: c for c in client.get("/api/finding/sf_org_spend_by_account", params={"window": 30, "limit": 5}).json()["columns"]}
    assert kinds["amount"]["kind"] == "money" and "not discounted" in kinds["amount"]["label"]


def test_affected_counts_name_the_entity_not_rows_or_schemas():
    rows = _findings()
    nouns = {q: r["affected"]["noun"] for q, r in rows.items() if r["affected"]}
    assert nouns["sf_dt_cost"] == "dynamic tables"
    assert nouns["sf_stream_stale"] == "streams"
    assert nouns["sf_secx_unused_policies"] == "policies"
    assert nouns["sf_chg_by_database_schema"] == "databases"
    assert nouns["sf_wh_idle_minutes"] == "warehouses"
    assert nouns["sf_lin_unused_views"] == "views"
    assert all(n != "schemas" for q, n in nouns.items() if q not in ("sf_govx_schema_grant_control", "sf_storage_schema_sprawl"))
    # a total row is never counted as a service
    inv = rows["sf_cost_invoice_vs_metered"]["affected"]
    assert inv["noun"] == "usage types" and inv["total"] == 4


# ---- tags -----------------------------------------------------------------------------------------------------------
def test_query_tags_parse_json_pairs_and_single_keys_only():
    assert build_tags.parse_query_tag('{"team": "a", "n": 3, "nested": {"x": 1}, "off": null}') == [("team", "a"), ("n", "3")]
    assert build_tags.parse_query_tag("team=fin; env=prod") == [("team", "fin"), ("env", "prod")]
    assert build_tags.parse_query_tag("bi:looker:finance") == [("bi", "looker:finance")]
    assert build_tags.parse_query_tag("just some words") == []
    assert build_tags.parse_query_tag("https://example.com") == []
    assert build_tags.parse_query_tag("") == []


def test_the_tag_tables_are_built_and_reconcile():
    con = duckdb.connect(str(__import__("os").environ["AUDIT_DB"]), read_only=True)
    try:
        have = {r[0] for r in con.execute("SELECT table_name FROM information_schema.tables WHERE table_schema = 'tags'").fetchall()}
        assert {"tag_entity", "tag_index", "tag_account", "cost_unit", "cost_unit_tag", "cost_reconciliation",
                "perf_unit", "perf_unit_tag"} <= have
        billing, units = con.execute("SELECT billing_usd, unit_usd FROM tags.cost_reconciliation WHERE window_days = 30").fetchone()
        assert billing == pytest.approx(units, rel=1e-6)
        sources = {r[0] for r in con.execute("SELECT DISTINCT source FROM tags.tag_entity").fetchall()}
        assert {"warehouse_tags", "user_tags", "role_tags", "object_tags", "query_tags"} <= sources
    finally:
        con.close()


def test_tag_filter_follows_the_warehouse_tag_and_the_account_tag_order():
    r = client.get("/api/findings", params={"window": 30, "tag_key": "costcenter", "tag_value": "ANALYTICS"}).json()
    row = next(x for x in r["findings"] if x["query_id"] == "sf_wh_idle_minutes")
    assert row["outcome"] == "ok_rows" and row["tag_chain"][:1] == ["compute"] and row["tag_chain"][-1] == "account"
    assert row["affected"]["flagged"] >= 1 and row["affected"]["total"] > row["affected"]["flagged"] - 1
    chain = registry and __import__("app.core.tags", fromlist=["tag_chain"]).tag_chain(
        "x", ["query_tag", "table_name", "database_name", "schema_name", "warehouse_id", "user_name", "role_name", "account_id"], "cost")
    assert chain.chain_words == ["query", "object", "object", "object", "compute", "user", "role", "account"]


def test_cost_center_filter_and_rollup_have_data():
    accounts = client.get("/api/accounts").json()
    assert accounts[0]["cost_center"] == "DATA_PLATFORM" and accounts[0]["workspace_id"] == accounts[0]["account_id"]
    keys = client.get("/api/rollup/keys", params={"area": "cost", "window": 30}).json()["keys"]
    assert any(k["tag_key"] == "costcenter" and k["compute"]["usd"] > 0 for k in keys)
    body = client.get("/api/rollup", params={"area": "cost", "window": 30, "tag_key": "costcenter"}).json()
    assert body["reconciliation"]["reconciled"] is True


def test_the_legacy_workspace_parameter_still_filters():
    a = client.get("/api/findings", params={"window": 30, "account_ids": "NO_SUCH"}).json()
    b = client.get("/api/findings", params={"window": 30, "workspace_ids": "NO_SUCH"}).json()
    assert a["account_ids"] == b["account_ids"] == ["NO_SUCH"]


# ---- masking --------------------------------------------------------------------------------------------------------
def test_masking_is_off_by_default_and_only_touches_person_columns(monkeypatch):
    assert client.get("/api/settings/privacy").json()["mask_user_identities"] is False
    df = pd.DataFrame({"user_name": ["ALICE", None], "warehouse_name": ["WH_ETL", "WH_BI"], "role_name": ["R1", "R2"],
                       "user_type": ["PERSON", "SERVICE"], "sample_users": ["ALICE, BOB", None],
                       "grantee": ["ALICE", "PUBLIC"], "grantee_type": ["USER", "ROLE"]})
    assert identity.mask_dataframe(df).equals(df)
    monkeypatch.setattr(identity, "masking_enabled", lambda: True)
    out = identity.mask_dataframe(df)
    assert out["user_name"][0] != "ALICE" and out["user_name"][0].endswith("***") and pd.isna(out["user_name"][1])
    assert list(out["warehouse_name"]) == ["WH_ETL", "WH_BI"] and list(out["role_name"]) == ["R1", "R2"]
    assert list(out["user_type"]) == ["PERSON", "SERVICE"]
    assert all(p.endswith("***") for p in out["sample_users"][0].split(", "))
    assert out["grantee"][0].endswith("***") and out["grantee"][1] == "PUBLIC"


def test_the_privacy_setting_masks_api_rows_and_can_be_turned_off_again():
    try:
        assert client.put("/api/settings/privacy", json={"mask_user_identities": True}).json()["mask_user_identities"] is True
        assert client.get("/api/meta").json()["privacy"]["mask_user_identities"] is True
        rows = client.get("/api/finding/sf_sec_stale_users", params={"window": 30, "limit": 20}).json()["rows"]
        assert rows and all(str(r["user_name"]).endswith("***") for r in rows)
        rows = client.get("/api/finding/sf_wh_idle_minutes", params={"window": 30, "limit": 20}).json()["rows"]
        assert rows and all("***" not in str(r["warehouse_id"]) for r in rows)
    finally:
        client.put("/api/settings/privacy", json={"mask_user_identities": False})
    assert client.get("/api/settings/privacy").json()["mask_user_identities"] is False
    assert client.put("/api/settings/privacy", json={"mask_user_identities": "yes"}).status_code == 422


# ---- the new checks and the fixes -----------------------------------------------------------------------------------
def test_the_new_lineage_and_audit_checks_are_in_the_registry_with_rows():
    ids = {s.query_id for s in registry.load_registry()}
    assert NEW_CHECKS <= ids
    rows = _findings()
    for qid in NEW_CHECKS:
        assert rows[qid]["outcome"] in ("ok_rows", "not_assessed"), (qid, rows[qid]["outcome"])
    assert rows["sf_audit_object_ddl_timeline"]["status_counts"].get("CRITICAL")


def test_retried_queries_are_not_failed_statement_waste():
    cols = registry.by_id("cost_failed_statement_waste").body
    assert "FAIL_RETRIED" in cols and "query_retry_time" in cols
    assert "retried" in registry.by_id("sf_perf_query_retries").read_this.lower()


def test_unknown_user_and_query_acceleration_are_their_own_columns():
    con = duckdb.connect(str(__import__("os").environ["AUDIT_DB"]), read_only=True)
    try:
        cols = {r[0] for r in con.execute("SELECT column_name FROM information_schema.columns "
                                          "WHERE table_name = 'f_sf_cost_query_attribution_by_user'").fetchall()}
    finally:
        con.close()
    assert "query_acceleration_credits" in cols
    assert "(unknown user)" in registry.by_id("sf_cost_query_attribution_by_user").body


def test_cost_cutoff_uses_the_last_complete_day():
    cutoff = client.get("/api/meta").json()["cost_cutoff"]
    assert cutoff["data_through"] and "partial_from" in cutoff
    direct = client.get("/api/meta").json()["direct_export"]
    assert "last_complete_day" in direct and "lag_hours" in direct
