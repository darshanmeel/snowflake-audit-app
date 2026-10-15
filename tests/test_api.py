"""tests/test_api.py: the FastAPI JSON API on the fake Snowflake account's test DB.

Every route answers 200 on that DB; /api/findings covers every check; the four outcomes
(rows, empty in the window, empty by filters, not assessed) plus the error row read as the
number rules say: a check that did not run shows NOT_ASSESSED with its reason, never 0.

Tests run against tests/conftest.py's DB (AUDIT_DB=tests/db_audit_test.duckdb, its run-results sidecar
beside it). A few need another DB state (a missing table, an empty window, a corrupt file); those use
one module-scoped copy of the DB, mutated once.
"""
from __future__ import annotations

import json
import re
import shutil
import sys
from pathlib import Path

import duckdb
import pytest
from fastapi.testclient import TestClient

ROOT = Path(__file__).resolve().parent.parent
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from app.api import service  # noqa: E402
from app.api.app import WEB_DIR, app  # noqa: E402
from app.core import config as app_config  # noqa: E402
from app.core import data as app_core_data  # noqa: E402
from app.core import datasource, registry  # noqa: E402
from tests.fixtures import build_fixtures  # noqa: E402

client = TestClient(app)

WINDOWS = (7, 30, 90)
STATUSES = {"OK", "WARN", "CRITICAL", "NOT_ASSESSED"}
OUTCOMES = {"ok_rows", "ok_empty_window", "ok_empty_filters", "not_assessed", "error"}
FAILED_ON_PURPOSE = dict(build_fixtures.FAILED_ON_PURPOSE)
ALL_NOT_ASSESSED = build_fixtures.NOT_ASSESSED_ON_PURPOSE
ACCOUNT = "FAKE01"

WINDOWED_CHECK = "sf_wh_idle_minutes"     # windowed, has status and account_id
ACCOUNT_CHECK = "cost_period_over_period"             # windowed, has account_id, 15 rows a window
POINT_IN_TIME_CHECK = "access_broad_grants"           # not windowed, a finding
INVENTORY_CHECK = "access_grants_inventory"           # not windowed, no status band
TASK_CHECK = "sf_task_failures"                       # carries task_full_name
EMPTY_WINDOW_CHECK, EMPTY_WINDOW_AT = "cost_daily_spikes", 7
MISSING_TABLE_CHECK = "sf_wh_oversized"


def _finding(query_id: str, **params) -> dict:
    params.setdefault("window", 30)
    resp = client.get(f"/api/finding/{query_id}", params=params)
    assert resp.status_code == 200, resp.text
    return resp.json()


def _agg(query_id: str, **params) -> dict:
    params.setdefault("window", 30)
    resp = client.get(f"/api/finding/{query_id}/aggregate", params=params)
    assert resp.status_code == 200, resp.text
    return resp.json()


def _raw(sql: str, db: Path | None = None) -> list[tuple]:
    con = duckdb.connect(str(db or app_core_data._db_path()), read_only=True)
    try:
        return con.execute(sql).fetchall()
    finally:
        con.close()


@pytest.fixture(scope="module")
def findings_by_window() -> dict[int, dict]:
    out = {}
    for w in WINDOWS:
        resp = client.get("/api/findings", params={"window": w})
        assert resp.status_code == 200
        out[w] = resp.json()
    return out


# -------------------------------------------------------------------------------------------
# Scenario fixtures
# -------------------------------------------------------------------------------------------


def _copy_db(dest_dir: Path, name: str) -> Path:
    """A copy of the session DB with its run-results sidecar, so a mutated DB still knows what ran."""
    src = app_core_data._db_path()
    dest = dest_dir / f"{name}.duckdb"
    shutil.copy2(src, dest)
    shutil.copy2(datasource.sidecar(src, "run_results"), datasource.sidecar(dest, "run_results"))
    return dest


@pytest.fixture(scope="module")
def mutated_db(tmp_path_factory):
    """One DB copy with EMPTY_WINDOW_CHECK's 7-day rows deleted and MISSING_TABLE_CHECK dropped while the
    run results still say it ran."""
    dest = _copy_db(tmp_path_factory.mktemp("api_scenario_db"), "scenario")
    con = duckdb.connect(str(dest))
    try:
        con.execute(f'DELETE FROM findings."f_{EMPTY_WINDOW_CHECK}" WHERE window_days = {EMPTY_WINDOW_AT}')
        con.execute(f'DROP TABLE findings."f_{MISSING_TABLE_CHECK}"')
        # Rebuild the load-time counts the findings list reads, as a real load would.
        from tools import load_results
        loaded = [q for (q,) in con.execute("SELECT query_id FROM summary.finding_tables").fetchall()
                  if q != MISSING_TABLE_CHECK]
        load_results.build_finding_counts(con, loaded)
    finally:
        con.close()
    return dest


@pytest.fixture
def scenario_env(mutated_db, monkeypatch):
    monkeypatch.setenv("AUDIT_DB", str(mutated_db))


@pytest.fixture
def no_database_env(tmp_path, monkeypatch):
    monkeypatch.setenv("AUDIT_DB", str(tmp_path / "no_such_file.duckdb"))


@pytest.fixture
def corrupt_db_env(tmp_path, monkeypatch):
    bad = tmp_path / "corrupt.duckdb"
    bad.write_bytes(b"not a duckdb file -- api ERROR-outcome scenario")
    monkeypatch.setenv("AUDIT_DB", str(bad))


@pytest.fixture(scope="module")
def no_dim_account_db(tmp_path_factory):
    dest = _copy_db(tmp_path_factory.mktemp("api_no_dim_account_db"), "no_dim_account")
    con = duckdb.connect(str(dest))
    try:
        con.execute("DROP TABLE dims.dim_account")
    finally:
        con.close()
    return dest


@pytest.fixture
def no_dim_account_env(no_dim_account_db, monkeypatch):
    monkeypatch.setenv("AUDIT_DB", str(no_dim_account_db))


@pytest.fixture
def bad_settings_env(tmp_path, monkeypatch):
    cfg_dir = tmp_path / "config"
    cfg_dir.mkdir()
    monkeypatch.setenv("AUDIT_CONFIG_DIR", str(cfg_dir))
    return cfg_dir


def _write_settings(cfg_dir: Path, text: str) -> None:
    (cfg_dir / "settings.yml").write_text(text, encoding="utf-8", newline="\n")


# -------------------------------------------------------------------------------------------
# Every route answers 200 on the test DB
# -------------------------------------------------------------------------------------------


@pytest.mark.parametrize("url", [
    "/api/status", "/api/meta", "/api/workspaces", "/api/dims", "/api/coverage", "/api/guide",
    "/api/findings", "/api/findings?window=7", "/api/findings?window=90", "/api/refresh",
    "/api/settings/cost-center", "/api/tag_origins", "/api/rollup/keys?area=cost&window=30",
    "/api/rollup?area=cost&tag_key=cost_center&window=30",
    "/api/rollup/top?area=cost&tag_key=cost_center&window=30",
    f"/api/finding/{WINDOWED_CHECK}", f"/api/finding/{WINDOWED_CHECK}/aggregate?agg=count",
    "/", "/index.html",
])
def test_every_route_returns_200(url):
    resp = client.get(url)
    assert resp.status_code == 200, (url, resp.text[:300])


def test_every_check_has_a_detail_page_that_returns_200():
    """All 199 at 30 days (the window switch itself is tested below on a few checks)."""
    for spec in registry.load_registry():
        resp = client.get(f"/api/finding/{spec.query_id}", params={"window": 30, "limit": 5})
        assert resp.status_code == 200, (spec.query_id, resp.text[:200])
        assert resp.json()["outcome"] in OUTCOMES


def test_detail_pages_answer_at_every_window_for_a_sample():
    for qid in (WINDOWED_CHECK, ACCOUNT_CHECK, TASK_CHECK, INVENTORY_CHECK, POINT_IN_TIME_CHECK, "sf_org_dormant_accounts"):
        for window in WINDOWS:
            resp = client.get(f"/api/finding/{qid}", params={"window": window, "limit": 5})
            assert resp.status_code == 200 and resp.json()["outcome"] in OUTCOMES, (qid, window)


def test_tags_route_answers_from_the_tag_index_the_load_built():
    resp = client.get("/api/tags", params={"search": "cost"})
    assert resp.status_code == 200
    assert any(k["tag_key"] == "costcenter" for k in resp.json()["keys"])


def test_built_assets_are_served_with_their_real_types():
    # Windows can map .js and .css to text/plain from the registry; app.py fixes the types.
    assets = Path(WEB_DIR) / "assets"
    want = {".js": "text/javascript", ".css": "text/css", ".woff2": "font/woff2"}
    for ext, mime in want.items():
        asset = next(assets.glob(f"*{ext}"))
        assert client.get(f"/assets/{asset.name}").headers["content-type"].startswith(mime), ext


def test_index_carries_the_settings_brand_from_the_first_paint(monkeypatch):
    monkeypatch.setattr(app_config, "load_settings", lambda: {"brand": {"name": "Acme </script> <!-- & Co"}})
    for path in ("/", "/some/page"):
        resp = client.get(path)
        assert resp.headers["cache-control"] == "no-cache"
        assert "<title>Acme &lt;/script&gt; &lt;!-- &amp; Co</title>" in resp.text
        assert r'window.APP_BRAND = "Acme \u003c/script> \u003c!-- & Co";' in resp.text, "a brand can never break the script tag"


def test_api_routes_are_not_shadowed_by_the_static_mount():
    assert client.get("/api/meta").headers["content-type"].startswith("application/json")
    assert client.get("/api/does_not_exist").status_code == 404


# -------------------------------------------------------------------------------------------
# GET /api/status and broken states
# -------------------------------------------------------------------------------------------


def test_status_ready_on_the_test_db():
    body = client.get("/api/status").json()
    assert body["state"] == "ready" and body["settings_error"] is None
    assert body["database"]["state"] == "ready"


def test_status_no_database(no_database_env):
    body = client.get("/api/status").json()
    assert body["state"] == "no_database" and body["database"]["state"] == "no_database"


def test_status_build_incomplete_on_a_corrupt_db(corrupt_db_env):
    body = client.get("/api/status").json()
    assert body["state"] == "build_incomplete" and body["database"]["detail"]


def test_status_build_incomplete_when_dim_account_is_missing(no_dim_account_env):
    body = client.get("/api/status").json()
    assert body["state"] == "build_incomplete"
    assert "dim_account" in body["database"]["detail"].lower()


def test_status_settings_invalid_unknown_key_names_key_and_line(bad_settings_env):
    _write_settings(bad_settings_env, "discount_pct: 0.0\ndefault_windw: 30\n")
    body = client.get("/api/status").json()
    assert body["state"] == "settings_invalid"
    assert body["settings_error"]["key"] == "default_windw" and body["settings_error"]["line"] == 2


def test_status_settings_invalid_bad_value_names_key_and_line(bad_settings_env):
    _write_settings(bad_settings_env, "discount_pct: 0.0\ndefault_window: 14\n")
    err = client.get("/api/status").json()["settings_error"]
    assert err["key"] == "default_window" and err["line"] == 2


def test_status_settings_invalid_yaml_syntax_error_reports_line(bad_settings_env):
    _write_settings(bad_settings_env, "discount_pct: 0.0\ndefault_window: 30\n  include_today: true\n")
    body = client.get("/api/status").json()
    assert body["state"] == "settings_invalid" and body["settings_error"]["line"] == 3
    assert body["settings_error"]["key"] is None


def test_status_settings_invalid_wins_over_a_missing_database(bad_settings_env, no_database_env):
    _write_settings(bad_settings_env, "discount_pct: 2.0\n")
    assert client.get("/api/status").json()["state"] == "settings_invalid"


def test_other_routes_503_with_a_structured_body_on_broken_settings(bad_settings_env):
    _write_settings(bad_settings_env, "discount_pct: not_a_number\n")
    for url in ("/api/meta", f"/api/finding/{WINDOWED_CHECK}", "/api/findings"):
        resp = client.get(url)
        assert resp.status_code == 503, url
        body = resp.json()
        assert body["state"] == "settings_invalid" and body["key"] == "discount_pct" and body["detail"]


def test_workspaces_503_not_500_on_a_missing_or_corrupt_database(no_database_env):
    resp = client.get("/api/workspaces")
    assert resp.status_code == 503 and "dim_account" in resp.json()["detail"]


def test_workspaces_503_on_a_corrupt_database(corrupt_db_env):
    assert client.get("/api/workspaces").status_code == 503


def test_finding_detail_and_list_read_error_on_a_corrupt_db(corrupt_db_env):
    body = client.get(f"/api/finding/{WINDOWED_CHECK}", params={"window": 30}).json()
    assert body["outcome"] == "error" and body["error"]
    for row in client.get("/api/findings", params={"window": 30}).json()["findings"]:
        assert row["outcome"] in ("error", "not_assessed"), row["query_id"]


# -------------------------------------------------------------------------------------------
# /api/meta, /api/workspaces, /api/dims
# -------------------------------------------------------------------------------------------


def test_meta_endpoint():
    body = client.get("/api/meta").json()
    settings = app_config.load_settings()
    assert body["window_options"] == [7, 30, 90] and body["default_window"] == 30 and body["open_window"] == 30
    assert body["as_of"] == "2026-09-21T12:00:00Z" and body["as_of_date"] == "2026-09-21"
    assert body["cost_cutoff"] == {"data_through": "2026-09-20", "partial_day": None, "partial_until": None, "partial_from": None}
    total = sum(1 for s in registry.load_registry() if s.executable)
    checks = body["checks"]
    assert {k: checks[k] for k in ("registry_total", "run_results_total", "failed", "not_built")} == {
        "registry_total": total, "run_results_total": total, "failed": 2, "not_built": 0}
    assert checks["ok"] == total - 2
    assert body["checks_ran"]["total"] == checks["total"] == total and checks["ran"] == body["checks_ran"]["ran"]
    assert body["max_chart_categories"] == settings["ui"]["max_chart_categories"]
    assert body["brand"] == settings["brand"] and body["run_results_available"] is True
    assert body["direct_export"]["account"]["cloud"] == "AWS"
    assert Path(body["db_path"]) == app_core_data._db_path()


def test_workspaces_endpoint_lists_the_account_by_name_with_an_env():
    rows = client.get("/api/workspaces").json()
    assert [r["account_id"] for r in rows] == [ACCOUNT]
    assert rows[0]["name"] == "FAKE_ACCOUNT" and rows[0]["env"] == "unknown" and rows[0]["env_reason"]
    assert set(rows[0]) >= {"account_id", "name", "url", "env", "env_source", "env_reason"}


def test_dims_endpoint_carries_names_not_only_ids():
    dims = client.get("/api/dims").json()
    assert set(dims) == {"tasks", "warehouses"}
    assert len(dims["warehouses"]) == 12
    for w in dims["warehouses"]:
        assert isinstance(w["warehouse_id"], str) and isinstance(w["account_id"], str) and w["warehouse_name"]
    assert dims["tasks"] and all(t["task_name"] and t["database_name"] and t["owner_role"] for t in dims["tasks"])
    assert all(t["task_full_name"] == f"{t['database_name']}.{t['schema_name']}.{t['task_name']}" for t in dims["tasks"])


def test_dim_records_ids_are_strings_and_other_values_pass_through():
    import pandas as pd

    from app.api import app as api_app

    df = pd.DataFrame({"warehouse_id": [1001, 1002], "warehouse_name": ["WH_A", None]})
    assert api_app._dim_records(df, ("warehouse_id",)) == [
        {"warehouse_id": "1001", "warehouse_name": "WH_A"}, {"warehouse_id": "1002", "warehouse_name": None}]
    assert api_app._dim_records(pd.DataFrame(), ("warehouse_id",)) == []


# -------------------------------------------------------------------------------------------
# /api/coverage
# -------------------------------------------------------------------------------------------


def test_coverage_shape_and_sources():
    body = client.get("/api/coverage").json()
    assert body["export_mode"] == "direct" and body["as_of_date"] == "2026-09-21"
    assert body["run_results_available"] is True and len(body["checks"]) == sum(1 for s in registry.load_registry() if s.executable)
    tables = body["tables"]
    assert "ACCOUNT_USAGE.QUERY_HISTORY" in tables and "SHOW WAREHOUSES" in tables
    assert "SYSTEM$CLIENT_VERSION_INFO()" in tables
    for key, entry in tables.items():
        assert entry["state"] in ("ok", "not_assessed"), key
        assert entry["dependent_query_ids"], key
        assert entry["checks_total"] == len(entry["dependent_query_ids"])
    dependents = {q for entry in tables.values() for q in entry["dependent_query_ids"]}
    assert dependents == {s.query_id for s in registry.load_registry()}


def test_a_source_is_not_assessed_only_when_every_check_reading_it_failed():
    tables = client.get("/api/coverage").json()["tables"]
    for key, entry in tables.items():
        readers_ok = [q for q in entry["dependent_query_ids"] if q not in FAILED_ON_PURPOSE]
        assert (entry["state"] == "ok") == bool(readers_ok), key
        if entry["state"] == "not_assessed":
            assert entry["rows"] is None and entry["reason"] and entry["message"]
        else:
            assert entry["rows"] is not None and entry["rows"] >= 0


def test_coverage_names_the_failed_checks_by_reason_with_a_fix():
    body = client.get("/api/coverage").json()
    not_ok = {c["query_id"]: c for c in body["checks_not_ok"]}
    # A check whose every row reads NOT_ASSESSED did not run either, so it is listed too.
    assert {q for q, c in not_ok.items() if c["reason"] == "build_failed"} == set(FAILED_ON_PURPOSE)
    assert {c["reason"] for c in not_ok.values()} <= {"build_failed", "all_rows_not_assessed"}
    assert "sf_gov_classification_coverage" in not_ok
    assert not_ok["sf_org_dormant_accounts"]["reason"] == "build_failed"
    assert not_ok["sf_org_dormant_accounts"]["reason_label"] == "the role can't see it"
    # The fix is this check's own GRANT (an organization view), not the generic hint.
    assert "ORGANIZATION_USAGE_VIEWER" in not_ok["sf_org_dormant_accounts"]["fix"]
    assert not_ok["sf_org_dormant_accounts"]["fix"].startswith("Run: GRANT")
    assert not_ok["sf_obj_iceberg_tables"]["reason_label"] == "not available in this account"
    for qid in FAILED_ON_PURPOSE:
        entry = not_ok[qid]
        assert entry["message"] and entry["title"] and entry["sources"]
    dormant = body["checks"]["sf_org_dormant_accounts"]
    assert dormant["status"] == "failed" and dormant["message"] == FAILED_ON_PURPOSE["sf_org_dormant_accounts"]
    assert dormant["reason"] == "no_access" and dormant["sources"] == []


def test_findings_and_coverage_name_a_gap_the_same_way(findings_by_window):
    listed = {r["query_id"]: r["not_assessed"] for r in findings_by_window[30]["findings"] if r["not_assessed"]}
    covered = {c["query_id"]: c for c in client.get("/api/coverage").json()["checks_not_ok"]}
    for qid in FAILED_ON_PURPOSE:
        assert listed[qid]["code"] == covered[qid]["reason"]
        assert listed[qid]["label"] == covered[qid]["reason_label"]


@pytest.mark.parametrize("message,reason", [
    (None, "not_exported"),
    ("SQL access control error: Insufficient privileges to operate on view X", "no_access"),
    ("Object 'SNOWFLAKE.ACCOUNT_USAGE.X' does not exist or not authorized", "no_access"),
    ("SQL compilation error: no such view 'X'", "view_missing"),
    ("Statement reached its statement or warehouse timeout of 60 second(s)", "timeout"),
    ("something odd", "unknown"),
])
def test_coverage_reason_classifies_the_export_message(message, reason):
    assert app_core_data.coverage_reason(message) == reason
    assert reason in app_core_data.COVERAGE_REASON_FIX


def test_coverage_truncated_ids_are_empty_on_this_export():
    assert client.get("/api/coverage").json()["truncated_query_ids"] == []


# -------------------------------------------------------------------------------------------
# /api/findings: every check, statuses, failed checks
# -------------------------------------------------------------------------------------------


def test_findings_cover_all_registry_ids_once(findings_by_window):
    ids = [r["query_id"] for r in findings_by_window[30]["findings"]]
    assert len(ids) == len(set(ids)) == findings_by_window[30]["count"] == sum(
        1 for s in registry.load_registry() if s.executable)
    assert set(ids) == {s.query_id for s in registry.load_registry()}


@pytest.mark.parametrize("window", WINDOWS)
def test_finding_outcomes_and_statuses_are_from_the_known_vocabulary(findings_by_window, window):
    body = findings_by_window[window]
    assert body["window_days"] == window
    for row in body["findings"]:
        qid = row["query_id"]
        assert row["outcome"] in OUTCOMES, qid
        assert row["window_days"] == (window if row["windowed"] else 0), qid
        if row["status_counts"] is not None:
            assert set(row["status_counts"]) <= STATUSES, qid
            assert sum(row["status_counts"].values()) == row["row_count"] > 0, qid


def test_every_check_of_the_test_db_reads_ok_rows_except_the_two_failed(findings_by_window):
    by_outcome = {}
    for row in findings_by_window[30]["findings"]:
        by_outcome.setdefault(row["outcome"], set()).add(row["query_id"])
    assert by_outcome == {"ok_rows": {s.query_id for s in registry.load_registry()} - set(FAILED_ON_PURPOSE),
                          "not_assessed": set(FAILED_ON_PURPOSE)}


def test_a_finding_has_a_status_band_and_an_inventory_does_not(findings_by_window):
    rows = {r["query_id"]: r for r in findings_by_window[30]["findings"]}
    assert rows[INVENTORY_CHECK]["is_finding"] is False and rows[INVENTORY_CHECK]["status_counts"] is None
    assert rows[INVENTORY_CHECK]["row_count"] > 0
    assert rows[WINDOWED_CHECK]["is_finding"] is True and set(rows[WINDOWED_CHECK]["status_counts"]) == {"CRITICAL", "WARN", "NOT_ASSESSED"}  # the adaptive warehouse
    assert rows[WINDOWED_CHECK]["row_count"] == 12 and rows[WINDOWED_CHECK]["has_account_id"] is True
    for row in rows.values():
        assert row["status_counts"] is None or row["is_finding"], row["query_id"]


def test_findings_span_every_status_across_the_library(findings_by_window):
    seen = {s for r in findings_by_window[30]["findings"] for s in (r["status_counts"] or {})}
    assert seen == STATUSES


def test_a_failed_check_reads_not_assessed_with_its_reason_never_zero(findings_by_window):
    rows = {r["query_id"]: r for r in findings_by_window[30]["findings"]}
    for qid in FAILED_ON_PURPOSE:
        row = rows[qid]
        assert row["outcome"] == "not_assessed" and row["not_assessed_reason"] == "model_failed"
        assert row["status_counts"] is None and row["money"] is None and row["affected"] is None
        assert row["not_assessed"]["code"] == "build_failed" and row["not_assessed"]["label"]
    # the window it failed in makes no difference
    for w in WINDOWS:
        assert {r["query_id"]: r for r in findings_by_window[w]["findings"]}[
            "sf_obj_iceberg_tables"]["outcome"] == "not_assessed"


def test_a_failed_check_detail_is_not_assessed_with_the_export_message_and_no_rows():
    for qid, message in FAILED_ON_PURPOSE.items():
        body = _finding(qid)
        assert body["outcome"] == "not_assessed"
        assert body["status_info"]["status"] == "failed" and body["status_info"]["message"] == message
        assert not ({"rows", "rows_total", "columns"} & set(body))
        assert body["header"]["title"]           # the page still explains the check


def test_a_failed_check_aggregate_is_not_assessed_with_no_total():
    body = _agg("sf_org_dormant_accounts", agg="sum", value="amount")
    assert body["outcome"] == "not_assessed" and "total_value" not in body and "groups" not in body


def test_an_all_not_assessed_check_says_so_in_the_list(findings_by_window):
    row = {r["query_id"]: r for r in findings_by_window[30]["findings"]}[ALL_NOT_ASSESSED]
    assert set(row["status_counts"]) == {"NOT_ASSESSED"}
    assert row["not_assessed"]["code"] == "all_rows_not_assessed"
    assert row["affected"]["flagged"] == 0
    body = _finding(ALL_NOT_ASSESSED, limit=500)
    assert {r["status"] for r in body["rows"]} == {"NOT_ASSESSED"}
    assert all(r["not_assessed_reason"] for r in body["rows"])


def test_findings_default_window_comes_from_settings_and_a_bad_window_is_422():
    assert client.get("/api/findings").json()["window_days"] == 30
    for bad in (14, 0, 365):
        assert client.get("/api/findings", params={"window": bad}).status_code == 422


def test_findings_list_carries_tier_domain_and_cap(findings_by_window):
    rows = {r["query_id"]: r for r in findings_by_window[30]["findings"]}
    assert {r["tier"] for r in rows.values()} == {"lite", "standard", "deep"}
    assert {r["domain"] for r in rows.values()} == {
        "cost", "governance_access", "jobs_pipelines", "performance", "storage", "compute", "serving_ai"}
    assert rows["cost_period_over_period"]["severity_cap"] == "WARN" and rows[WINDOWED_CHECK]["severity_cap"] is None
    assert all(r["origin"] == "checks" for r in rows.values())


def test_findings_money_and_affected_shapes(findings_by_window):
    rows = {r["query_id"]: r for r in findings_by_window[30]["findings"]}
    money = rows[WINDOWED_CHECK]["money"]
    assert money["column"] == "est_wasted_usd_list" and money["kind"] == "waste"
    assert money["usd"] == pytest.approx(13827.60, abs=0.01)
    assert rows[WINDOWED_CHECK]["affected"] == {"column": "warehouse_id", "columns": ["warehouse_id"], "noun": "warehouses",
                                                  "flagged": 5, "total": 12, "flagged_other": 0,
                                                  "not_assessed": rows[WINDOWED_CHECK]["affected"].get("not_assessed")}
    assert rows[INVENTORY_CHECK]["money"] is None
    for r in rows.values():
        if r["money"]:
            # storage checks also carry overlap_usd / overlap_tables (a table two checks both price)
            assert set(r["money"]) - {"overlap_usd", "overlap_tables"} == {"column", "kind", "usd", "unit", "basis", "currency", "mixed_currency", "price_basis", "usd_flagged"}
            assert r["money"]["usd"] is not None or r["money_reason"] == "unpriced" or r["money"]["mixed_currency"]
        if r["affected"]:
            assert set(r["affected"]) == {"column", "columns", "noun", "flagged", "total", "flagged_other", "not_assessed"}
            assert 0 <= r["affected"]["flagged"] <= r["affected"]["total"], r["query_id"]


# -------------------------------------------------------------------------------------------
# Window switching
# -------------------------------------------------------------------------------------------


def test_switching_the_window_changes_a_windowed_checks_rows_and_money(findings_by_window):
    by_window = {w: {r["query_id"]: r for r in findings_by_window[w]["findings"]} for w in WINDOWS}
    daily = [by_window[w]["cost_daily_spikes"]["row_count"] for w in WINDOWS]
    assert daily[0] < daily[1] == daily[2]           # 7 < 30, and 90 is the 30 days the export had
    usd = [by_window[w][WINDOWED_CHECK]["money"]["usd"] for w in WINDOWS]
    assert usd[0] < usd[1] == pytest.approx(usd[2])
    assert usd[0] == pytest.approx(3217.80, abs=0.01)


def test_a_point_in_time_check_reads_the_same_at_every_window(findings_by_window):
    rows = [{r["query_id"]: r for r in findings_by_window[w]["findings"]}[POINT_IN_TIME_CHECK] for w in WINDOWS]
    assert {r["window_days"] for r in rows} == {0}
    assert rows[0]["row_count"] == rows[1]["row_count"] == rows[2]["row_count"] > 0
    assert rows[0]["status_counts"] == rows[1]["status_counts"] == rows[2]["status_counts"]
    detail = [_finding(POINT_IN_TIME_CHECK, window=w) for w in WINDOWS]
    assert {d["window_days"] for d in detail} == {0} and [d["requested_window_days"] for d in detail] == list(WINDOWS)
    assert detail[0]["rows_total"] == detail[2]["rows_total"]


def test_the_90_day_window_is_partial_where_the_export_has_30_days(findings_by_window):
    for w, partial in ((7, False), (30, False), (90, True)):
        for row in findings_by_window[w]["findings"]:
            if row["windowed"] and row["outcome"] == "ok_rows":
                assert row["partial"] is partial, (w, row["query_id"])
            else:
                assert row["partial"] is False


def test_the_header_period_days_reads_the_window_on_screen_and_the_days_covered():
    text = lambda w: json.dumps(_finding("cost_chargeback_by_account", window=w)["header"]["params"]["period_days"])
    assert json.loads(text(7)) == {"value": 7, "source": "the window you picked"}
    assert json.loads(text(30)) == {"value": 30, "source": "the window you picked"}
    ninety = json.loads(text(90))
    assert ninety["value"] == 30 and "30 of the 90 days" in ninety["source"]


def test_finding_detail_bad_window_and_unknown_id():
    assert client.get(f"/api/finding/{WINDOWED_CHECK}", params={"window": 14}).status_code == 422
    assert client.get("/api/finding/no_such_check", params={"window": 30}).status_code == 404
    assert client.get("/api/finding/no_such_check/aggregate", params={"window": 30}).status_code == 404


# -------------------------------------------------------------------------------------------
# /api/finding/{id}
# -------------------------------------------------------------------------------------------


def test_finding_detail_ok_rows():
    body = _finding(WINDOWED_CHECK)
    assert body["outcome"] == "ok_rows" and body["rows_total"] == body["rows_in_window"] == body["returned"] == 12
    assert body["is_finding"] and body["windowed"] and body["window_days"] == body["requested_window_days"] == 30
    assert [c["name"] for c in body["columns"]] == list(body["rows"][0])
    kinds = {c["name"]: c["kind"] for c in body["columns"]}
    assert kinds["est_wasted_usd_list"] == "money" and kinds["warehouse_id"] == "id"
    assert all(isinstance(r["warehouse_id"], str) for r in body["rows"])
    assert body["header"]["title"] and body["header"]["actions"] and body["header"]["domain"] == "compute"
    assert body["scope"] == {"has_account_id": True, "tag": None, "owner_applied": None,
                             "warehouse_applied": None, "database_applied": None, "schema_applied": None}
    assert body["truncated"] is False and body["window_coverage"]["partial"] is False


def test_finding_rows_are_ordered_worst_status_first():
    rank = {"CRITICAL": 0, "WARN": 1, "NOT_ASSESSED": 2, "OK": 3}
    rows = _finding("query_pruning_effectiveness", limit=500)["rows"]
    ranks = [rank[r["status"]] for r in rows]
    assert ranks == sorted(ranks) and ranks[0] == 0


def test_finding_detail_pagination_offset():
    everything = _finding("cost_daily_spikes", limit=100)
    page = _finding("cost_daily_spikes", limit=10, offset=5)
    assert page["returned"] == 10 and page["offset"] == 5 and page["rows_total"] == everything["rows_total"]
    assert page["rows"] == everything["rows"][5:15]
    assert client.get(f"/api/finding/{WINDOWED_CHECK}", params={"limit": 0}).status_code == 422
    assert client.get(f"/api/finding/{WINDOWED_CHECK}", params={"limit": 5001}).status_code == 422


def test_finding_detail_carries_discounted_money_columns_and_labels(tmp_path, monkeypatch):
    plain = _finding(WINDOWED_CHECK)
    labels = {c["name"]: c["label"] for c in plain["columns"] if c["kind"] == "money"}
    assert labels["est_wasted_usd_list"] == "list price (effective)"
    assert labels["est_wasted_usd_list_disc"] == "list price (effective)" and plain["discount_pct"] == 0.0
    cfg = tmp_path / "config"
    cfg.mkdir()
    (cfg / "settings.yml").write_text("discount_pct: 0.125\n", encoding="utf-8")
    monkeypatch.setenv("AUDIT_CONFIG_DIR", str(cfg))
    real_info = app_core_data.direct_export_info
    # The fixture's price is the invoice rate, which is already discounted; a typed-in price is not.
    monkeypatch.setattr(app_core_data, "direct_export_info",
                        lambda: {**real_info(), "pricing": {**real_info()["pricing"], "source": "cli"}})
    body = _finding(WINDOWED_CHECK)
    labels = {c["name"]: c["label"] for c in body["columns"] if c["kind"] == "money"}
    assert labels["est_wasted_usd_list"] == "list price (effective)"
    assert labels["est_wasted_usd_list_disc"] == "what-if: list price (effective), -12.5%"
    for raw, row in zip(plain["rows"], body["rows"]):
        if raw["est_wasted_usd_list"] is None:  # not assessed or not flagged: no $, and no discount on it
            assert row["est_wasted_usd_list"] is None and row["est_wasted_usd_list_disc"] is None
            continue
        assert row["est_wasted_usd_list"] == pytest.approx(raw["est_wasted_usd_list"])
        assert row["est_wasted_usd_list_disc"] == pytest.approx(raw["est_wasted_usd_list"] * 0.875)


def test_json_scalar_nat_and_nan_are_null_not_text():
    import pandas as pd

    assert service._json_scalar(pd.NaT) is None and service._json_scalar(float("nan")) is None
    assert service._json_scalar(pd.Timestamp("2026-09-20 01:02:03")) == "2026-09-20T01:02:03"


def test_finding_detail_workspace_filter():
    everything = _finding(ACCOUNT_CHECK, limit=500)
    mine = _finding(ACCOUNT_CHECK, account_ids=ACCOUNT, limit=500)
    assert mine["rows_total"] == everything["rows_total"] and mine["excluded_no_account"] == {"rows": 0, "value": None}
    other = _finding(ACCOUNT_CHECK, account_ids="NOT_AN_ACCOUNT")
    assert other["outcome"] == "ok_empty_filters" and other["rows_in_window"] == everything["rows_total"]
    assert other["row_cap"] is None and "rows" not in other
    listed = {r["query_id"]: r for r in client.get(
        "/api/findings", params={"window": 30, "account_ids": "NOT_AN_ACCOUNT"}).json()["findings"]}
    assert listed[ACCOUNT_CHECK]["outcome"] == "ok_empty_filters" and listed[ACCOUNT_CHECK]["row_count"] == 0


def test_env_filter_follows_the_account_env():
    assert _finding(ACCOUNT_CHECK, env="unknown")["outcome"] == "ok_rows"
    assert _finding(ACCOUNT_CHECK, env="prod")["outcome"] == "ok_empty_filters"


def test_a_check_with_no_account_column_ignores_the_account_filter():
    everything = _finding("cost_chargeback_by_service")
    filtered = _finding("cost_chargeback_by_service", account_ids="NOT_AN_ACCOUNT")
    assert filtered["scope"]["has_account_id"] is False
    assert filtered["rows_total"] == everything["rows_total"] and filtered["excluded_no_account"] is None


def test_task_filter_scopes_to_one_task_and_no_match_is_empty_by_filters():
    full = "ANALYTICS_DB.MARTS.T_FLAKY"
    body = _finding(TASK_CHECK, job_id=full)
    assert body["outcome"] == "ok_rows" and {r["task_full_name"] for r in body["rows"]} == {full}
    none = _finding(TASK_CHECK, job_id="NO_DB.NO_SCHEMA.NO_TASK")
    assert none["outcome"] == "ok_empty_filters" and none["rows_in_window"] > 0


def test_task_filter_scopes_the_graph_check_by_its_root_task():
    full = "ANALYTICS_DB.MARTS.T_FLAKY"
    body = _finding("sf_task_graph_health", job_id=full)
    assert body["outcome"] == "ok_rows" and {r["root_task_full_name"] for r in body["rows"]} == {full}


def test_task_filter_is_ignored_on_a_check_without_a_task_column():
    base = _finding(WINDOWED_CHECK)
    assert _finding(WINDOWED_CHECK, job_id="ANY.THING.AT_ALL")["rows_total"] == base["rows_total"]


def test_status_filter_rows_match_and_agree_with_the_bulk_counts(findings_by_window):
    counts = {r["query_id"]: r for r in findings_by_window[30]["findings"]}["query_pruning_effectiveness"]["status_counts"]
    for status, n in counts.items():
        body = _finding("query_pruning_effectiveness", status=status, limit=5000)
        assert body["rows_total"] == n and {r["status"] for r in body["rows"]} == {status}
    both = _finding("query_pruning_effectiveness", status=["WARN", "CRITICAL"], limit=5000)
    assert both["rows_total"] == counts.get("WARN", 0) + counts.get("CRITICAL", 0)


def test_status_filter_bad_value_is_422_and_absent_column_is_ignored():
    assert client.get(f"/api/finding/{WINDOWED_CHECK}", params={"status": "BROKEN"}).status_code == 422
    base = _finding(INVENTORY_CHECK, limit=500)
    assert _finding(INVENTORY_CHECK, status="CRITICAL", limit=500)["rows_total"] == base["rows_total"]


def test_row_cap_field_is_present_and_null_for_a_check_without_top_n():
    assert all(s.query_id and service.row_cap(s.query_id) is None for s in registry.load_registry()
               if not any(p["name"] == "top_n" for p in s.params))
    assert _finding(WINDOWED_CHECK)["row_cap"] is None
    assert service.row_cap("no_such_check") is None


def test_header_params_are_substituted_not_raw():
    body = _finding("sf_wh_oversized")
    text = json.dumps(body["header"]["read_this"]) + json.dumps(body["header"]["investigate_if"])
    assert not re.search(r"(?<![\w:]):[a-z_]{3,}\b", text)
    spec = registry.by_id("sf_wh_oversized")
    assert set(body["header"]["params"]) == {p["name"] for p in spec.params}
    assert all(p["source"] for p in body["header"]["params"].values())


def test_a_thresholds_override_shows_as_your_setting_in_the_header(tmp_path, monkeypatch):
    spec = registry.by_id("sf_wh_oversized")
    name = next(p["name"] for p in spec.params if p["name"] != "period_days" and isinstance(p["default"], (int, float)))
    cfg = tmp_path / "config"
    cfg.mkdir()
    (cfg / "thresholds.yml").write_text(f"sf_wh_oversized:\n  {name}: 77\n", encoding="utf-8")
    monkeypatch.setenv("AUDIT_CONFIG_DIR", str(cfg))
    params = _finding("sf_wh_oversized")["header"]["params"]
    assert params[name] == {"value": 77, "source": "your setting"}


def test_substitute_params_leaves_an_undeclared_token_untouched():
    assert service.substitute_params("keep :not_a_param and use :top_n", {"top_n": (10, "default")}) == (
        "keep :not_a_param and use 10 (default)")


# -------------------------------------------------------------------------------------------
# Owner filter (see also tests/test_owner_filter.py)
# -------------------------------------------------------------------------------------------


def test_owner_filter_narrows_the_detail_and_reports_owner_applied():
    user = next(r["user_name"] for r in _finding("sf_chg_by_warehouse_and_user_daily", limit=500)["rows"])
    body = _finding("sf_chg_by_warehouse_and_user_daily", owner=user, limit=500)
    assert body["scope"]["owner_applied"] is True and {r["user_name"] for r in body["rows"]} == {user}
    assert _finding(WINDOWED_CHECK, owner=user)["scope"]["owner_applied"] is False


# -------------------------------------------------------------------------------------------
# Scenarios: a missing table, an empty window
# -------------------------------------------------------------------------------------------


def test_empty_window_reads_ok_empty_window_not_zero(scenario_env):
    body = _finding(EMPTY_WINDOW_CHECK, window=EMPTY_WINDOW_AT)
    assert body["outcome"] == "ok_empty_window" and "rows" not in body
    assert body["window_coverage"]["covered_days"] == 7 and body["window_coverage"]["as_of_date"] == "2026-09-21"
    assert _finding(EMPTY_WINDOW_CHECK, window=30)["outcome"] == "ok_rows"
    listed = {r["query_id"]: r for r in client.get("/api/findings", params={"window": EMPTY_WINDOW_AT}).json()["findings"]}
    assert listed[EMPTY_WINDOW_CHECK]["outcome"] == "ok_empty_window" and listed[EMPTY_WINDOW_CHECK]["row_count"] == 0
    assert listed[EMPTY_WINDOW_CHECK]["money"] is None


def test_aggregate_ok_empty_window(scenario_env):
    assert _agg(EMPTY_WINDOW_CHECK, window=EMPTY_WINDOW_AT, agg="count")["outcome"] == "ok_empty_window"


def test_a_missing_table_reads_not_assessed_with_a_reason(scenario_env):
    body = _finding(MISSING_TABLE_CHECK)
    assert body["outcome"] == "not_assessed" and "Not in this export" in body["status_info"]["not_built_reason"]
    listed = {r["query_id"]: r for r in client.get("/api/findings", params={"window": 30}).json()["findings"]}
    assert listed[MISSING_TABLE_CHECK]["outcome"] == "not_assessed"
    assert listed[MISSING_TABLE_CHECK]["not_assessed_reason"] == "not_built"
    assert listed[MISSING_TABLE_CHECK]["row_count"] == 0 and listed[MISSING_TABLE_CHECK]["money"] is None


def test_aggregate_not_assessed_on_a_missing_table(scenario_env):
    body = _agg(MISSING_TABLE_CHECK, agg="count")
    assert body["outcome"] == "not_assessed" and "total_value" not in body


def test_a_check_missing_from_the_run_results_and_the_db_is_not_built(tmp_path, monkeypatch):
    src = app_core_data._db_path()
    dest = tmp_path / "trimmed.duckdb"
    shutil.copy2(src, dest)
    sidecar = json.loads(datasource.sidecar(src, "run_results").read_text(encoding="utf-8"))
    sidecar["results"] = [r for r in sidecar["results"] if r["query_id"] != WINDOWED_CHECK]
    datasource.sidecar(dest, "run_results").write_text(json.dumps(sidecar), encoding="utf-8")
    con = duckdb.connect(str(dest))
    con.execute(f'DROP TABLE findings."f_{WINDOWED_CHECK}"')
    con.close()
    monkeypatch.setenv("AUDIT_DB", str(dest))
    assert client.get("/api/meta").json()["checks"]["not_built"] == 1
    body = _finding(WINDOWED_CHECK)
    assert body["outcome"] == "not_assessed"
    entry = next(c for c in client.get("/api/coverage").json()["checks_not_ok"] if c["query_id"] == WINDOWED_CHECK)
    assert entry["reason"] == "not_built" and entry["reason_label"] == "not in this export"


def test_no_run_results_sidecar_still_reads_a_table_that_exists(tmp_path, monkeypatch):
    dest = tmp_path / "no_sidecar.duckdb"
    shutil.copy2(app_core_data._db_path(), dest)
    monkeypatch.setenv("AUDIT_DB", str(dest))
    assert _finding(WINDOWED_CHECK)["outcome"] == "ok_rows"
    assert client.get("/api/meta").json()["run_results_available"] is False


# -------------------------------------------------------------------------------------------
# /api/finding/{id}/aggregate
# -------------------------------------------------------------------------------------------


def test_aggregate_sum_matches_direct_sql():
    expected = _raw(f'SELECT sum(usd_list), count(*) FROM findings.f_cost_chargeback_by_service WHERE window_days = 30')[0]
    body = _agg("cost_chargeback_by_service", agg="sum", value="usd_list")
    assert body["outcome"] == "ok_rows" and body["total_value"] == pytest.approx(expected[0])
    assert body["matched_rows"] == expected[1] and body["group"] == [] and body["null_value_rows"] == 0


def test_aggregate_groups_sum_to_the_total_and_carry_the_key():
    body = _agg("cost_chargeback_by_service", agg="sum", value="usd_list", group="billing_origin_product")
    assert body["group_count"] == len(body["groups"]) > 1
    assert sum(g["value"] for g in body["groups"]) == pytest.approx(body["total_value"])
    expected = {r[0] for r in _raw("SELECT DISTINCT billing_origin_product FROM findings.f_cost_chargeback_by_service "
                                   "WHERE window_days = 30")}
    assert {tuple(g["key"]) for g in body["groups"]} == {(v,) for v in expected}


def test_aggregate_count_ignores_a_missing_value():
    body = _agg(WINDOWED_CHECK, agg="count")
    assert body["total_value"] == 12 and body["matched_rows"] == 12


def test_aggregate_top_folds_the_remainder_but_keeps_the_true_total():
    full = _agg("cost_chargeback_by_service", agg="sum", value="usd_list", group="billing_origin_product")
    top = _agg("cost_chargeback_by_service", agg="sum", value="usd_list", group="billing_origin_product", top=3)
    assert len(top["groups"]) == 3 and top["other"] is not None
    assert top["total_value"] == pytest.approx(full["total_value"])
    assert sum(g["value"] for g in top["groups"]) + top["other"]["value"] == pytest.approx(top["total_value"])
    assert top["group_count"] == full["group_count"]


def test_aggregate_status_filter_matches_the_bulk_counts(findings_by_window):
    counts = {r["query_id"]: r for r in findings_by_window[30]["findings"]}["query_pruning_effectiveness"]["status_counts"]
    body = _agg("query_pruning_effectiveness", agg="count", status=["WARN", "CRITICAL"])
    assert body["matched_rows"] == counts["WARN"] + counts["CRITICAL"]


def test_aggregate_status_on_a_table_with_no_status_is_ignored():
    base = _agg(INVENTORY_CHECK, agg="count")
    assert _agg(INVENTORY_CHECK, agg="count", status="CRITICAL")["matched_rows"] == base["matched_rows"] > 0


def test_aggregate_with_no_matching_status_is_ok_empty_filters():
    body = _agg("cost_chargeback_by_account", agg="count", status="CRITICAL")
    assert body["outcome"] == "ok_empty_filters" and body["rows_in_window"] == 1


@pytest.mark.parametrize("params", [
    {"group": "no_such_column", "agg": "count"},
    # more than six group columns
    {"group": ["window_days", "status", "price_basis", "billing_origin_product", "account_id", "usd_list", "credits"], "agg": "count"},
    {"agg": "median", "value": "usd_list"},
    {"agg": "sum"},
    {"agg": "count", "status": "BROKEN"},
    {"agg": "count", "window": 14},
    {"agg": "sum", "value": "not a column; DROP TABLE x"},
])
def test_aggregate_bad_input_is_422(params):
    resp = client.get("/api/finding/cost_chargeback_by_service/aggregate", params={"window": 30, **params})
    assert resp.status_code == 422, (params, resp.text)


def test_aggregate_reports_rows_with_no_value_as_null_rows():
    """A sum over a column with NULLs says how many rows never entered the total."""
    rows = _raw("SELECT count(*) FILTER (WHERE est_wasted_usd_list IS NULL), count(*) FROM "
                f'findings."f_{WINDOWED_CHECK}" WHERE window_days = 30')[0]
    body = _agg(WINDOWED_CHECK, agg="sum", value="est_wasted_usd_list")
    assert body["null_value_rows"] == rows[0] and body["matched_rows"] == rows[1]


def test_aggregate_workspace_filter_agrees_with_the_detail():
    assert _agg(ACCOUNT_CHECK, agg="count", account_ids=ACCOUNT)["matched_rows"] == _finding(
        ACCOUNT_CHECK, account_ids=ACCOUNT)["rows_total"]


def test_aggregate_error_on_a_corrupt_db(corrupt_db_env):
    body = _agg(WINDOWED_CHECK, agg="count")
    assert body["outcome"] == "error" and body["error"]


def test_a_group_bigger_than_a_detail_page_is_fully_counted_by_the_aggregate(tmp_path, monkeypatch):
    """A detail fetch is capped at 5,000 rows; the aggregate is a GROUP BY over every row."""
    dest = _copy_db(tmp_path, "flood")
    table = "f_cost_chargeback_by_service"
    con = duckdb.connect(str(dest))
    try:
        cols = [r[0] for r in con.execute(
            "SELECT column_name FROM information_schema.columns WHERE table_schema = 'findings' "
            "AND table_name = ? ORDER BY ordinal_position", [table]).fetchall()]
        overrides = {"window_days": "30", "billing_origin_product": "'FLOOD'", "usd_list": "1.0", "status": "'OK'"}
        select_list = ", ".join(overrides.get(c, f'tmpl."{c}"') for c in cols)
        con.execute(f'INSERT INTO findings."{table}" SELECT {select_list} '
                    f'FROM (SELECT * FROM findings."{table}" LIMIT 1) AS tmpl, range(5100) AS r')
    finally:
        con.close()
    monkeypatch.setenv("AUDIT_DB", str(dest))
    assert _finding("cost_chargeback_by_service", limit=5000)["returned"] == 5000
    body = _agg("cost_chargeback_by_service", agg="count", group="billing_origin_product", top=100)
    flood = [g for g in body["groups"] if "FLOOD" in json.dumps(g)]
    assert len(flood) == 1 and flood[0]["value"] == 5100


# -------------------------------------------------------------------------------------------
# Static front end
# -------------------------------------------------------------------------------------------


def test_static_index_and_app_bundle_are_served():
    index = client.get("/")
    assert index.status_code == 200 and "<html" in index.text.lower()
    asset = re.search(r'src="(/assets/[^"]+\.js)"', index.text).group(1)
    assert client.get(asset).status_code == 200
    assert client.get("/costs/any/page").text == index.text, "a page path gets index.html"
    assert client.get("/api/no-such-route").status_code == 404
