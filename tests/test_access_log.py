"""tests/test_access_log.py: the access log routes (overview, one object, one person) on the fake account's test DB."""
from __future__ import annotations

import sys
from pathlib import Path

from fastapi.testclient import TestClient

ROOT = Path(__file__).resolve().parent.parent
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from app.api import access_log  # noqa: E402
from app.api.app import app  # noqa: E402

client = TestClient(app)


def test_objects_are_busiest_first_and_flag_sensitive_tables():
    body = client.get("/api/access/log/objects", params={"window": 30}).json()
    busy = [o["reads"] + o["writes"] + o["ddl"] for o in body["objects"]]
    assert busy == sorted(busy, reverse=True) and body["truncated"] is False
    sens = client.get("/api/access/log/objects", params={"window": 30, "sensitive": True}).json()["objects"]
    assert sens and all(o["sensitive"] in ("tagged", "suggested") for o in sens)


def test_one_object_stays_in_the_window_and_its_parts_add_up():
    name = client.get("/api/access/log/objects", params={"window": 7}).json()["objects"][0]["object_fqn"]
    body = client.get("/api/access/log", params={"object": name, "window": 7, "split": "statement"}).json()
    t = body["tiles"]
    total = t["reads"] + t["writes"] + t["ddl"]
    days = {d for s in body["per_day"]["series"] for d in s["values"]}
    assert days and all(body["start"] <= d < body["end"] for d in days)
    assert sum(v for s in body["per_day"]["series"] for v in s["values"].values()) == total
    assert sum(r["reads"] + r["writes"] + r["ddl"] for r in body["who"]) == total
    # a MERGE on its own target is a write, never a read of it
    assert all(s["reads"] == 0 for s in body["statements"] if s["k"] == "MERGE")
    # off hours are judged for people only
    assert all(w["off_hours"] is None for w in body["who"] if not w["is_person"])


def test_off_hours_counts_people_only_and_follow_the_offset():
    base = client.get("/api/access/overview", params={"window": 30, "offset": 0}).json()
    people = {r["user_name"] for r in client.get("/api/access/people", params={"window": 30}).json()["people"] if r["is_person"]}
    assert base["off_hours"] and {p["user_name"] for p in base["off_hours"]} <= people
    shifted = client.get("/api/access/overview", params={"window": 30, "offset": 6}).json()
    assert sum(p["off_hours"] for p in shifted["off_hours"]) != sum(p["off_hours"] for p in base["off_hours"])
    # the heatmap reads None (shown "–") where the person has no grant path to the object
    assert any(v is None for r in base["heat"] for v in r["cells"])


def test_a_person_has_hours_of_use_and_a_service_user_none():
    body = client.get("/api/access/person", params={"user": "ANALYST_DAN", "window": 30}).json()
    assert body["tiles"]["is_person"] and len(body["hours"]["on"]) == 24 and body["objects"]
    assert client.get("/api/access/person", params={"user": "SYSTEM", "window": 30}).json()["hours"] is None


def test_settings_default_to_utc_business_hours():
    assert client.get("/api/access/settings").json() == {"offset": 0, "start": 7, "end": 19}


def test_a_missing_log_reads_503(monkeypatch):
    monkeypatch.setattr(access_log, "LOG", "findings.f_no_such_table")
    assert client.get("/api/access/log/objects").status_code == 503


def test_the_overview_breaks_all_objects_down_and_the_heatmap_can_show_every_object():
    sens = client.get("/api/access/overview", params={"window": 30}).json()
    allo = client.get("/api/access/overview", params={"window": 30, "heat": "all"}).json()
    total = sum(r["reads"] + r["writes"] + r["ddl"] for r in sens["by"]["client"])
    assert total == sens["queries"] == sum(s["queries"] for s in sens["statements"])
    assert set(sens["heat_objects"]) <= set(allo["heat_objects"]) and len(allo["heat_objects"]) >= len(sens["heat_objects"])


def test_rollup_counts_every_kind_and_the_kind_filter_finds_procedures():
    db = client.get("/api/access/rollup", params={"window": 30, "level": "database"}).json()["rows"]
    analytics = next(r for r in db if r["k"] == "ANALYTICS_DB")
    assert analytics["procedures"] >= 1 and analytics["functions"] >= 1 and analytics["tables"] >= 1
    procs = client.get("/api/access/log/objects", params={"window": 30, "kind": "procedure"}).json()["objects"]
    assert [o["object_fqn"] for o in procs] == ["ANALYTICS_DB.PUBLIC.LOAD_ORDERS_SP"]
    scoped = client.get("/api/access/log/objects", params={"window": 30, "prefix": "ANALYTICS_DB.MARTS"}).json()["objects"]
    assert scoped and all(o["object_fqn"].startswith("ANALYTICS_DB.MARTS.") for o in scoped)


def test_a_procedure_shows_what_its_queries_did_and_rows_name_it_as_via():
    body = client.get("/api/access/log", params={"object": "ANALYTICS_DB.PUBLIC.LOAD_ORDERS_SP", "window": 30}).json()
    did = {r["object_fqn"]: r for r in body["did"]}
    assert body["kind"] == "PROCEDURE" and did["ANALYTICS_DB.CORE.ORDERS"]["writes"] > 0 and did["RAW_DB.LANDING.ORDERS_RAW"]["reads"] > 0
    orders = client.get("/api/access/log", params={"object": "ANALYTICS_DB.CORE.ORDERS", "window": 30}).json()
    assert any("LOAD_ORDERS_SP" in (w["via"] or "") for w in orders["who"])


def test_streamlit_apps_list_who_opened_them_and_what_they_read():
    body = client.get("/api/access/apps", params={"window": 30}).json()
    assert body["app"] == "ANALYTICS_DB.APPS.SALES_DASH"
    assert {w["user_name"] for w in body["who"]} == {"ANALYST_CARA", "ANALYST_DAN", "ADMIN_ALICE", "ANALYST_EVA"}
    assert [o["object_fqn"] for o in body["objects"]] == ["ANALYTICS_DB.CORE.CUSTOMERS"]


def test_a_streamlit_app_shows_shares_who_can_open_who_opened_from_where_and_what_it_ran_as():
    body = client.get("/api/access/apps", params={"window": 30, "app": "ANALYTICS_DB.APPS.SALES_DASH"}).json()
    shares = {(r["grantee_name"], r["privilege"]): r for r in body["shares"]}
    assert shares[("PUBLIC", "USAGE")]["revoked_at"] and not shares[("ANALYST_ROLE", "USAGE")]["revoked_at"]
    assert "ANALYST_CARA" in body["can_open"]
    cara = next(w for w in body["who"] if w["user_name"] == "ANALYST_CARA")
    assert cara["client_ips"] == "203.0.113.21" and cara["runs"] == 4
    assert {(r["user_name"], r["role_name"]) for r in body["runs_as"]} == {("SVC_BI", "BI_ROLE")}


def test_a_role_lists_its_users_and_a_user_lists_kinds_and_apps():
    role = client.get("/api/access/person", params={"role": "ETL_ROLE", "window": 30}).json()
    assert role["role"] == "ETL_ROLE" and role["tiles"]["users"] >= 1 and role["hours"] is None
    user = client.get("/api/access/person", params={"user": "ANALYST_CARA", "window": 30}).json()
    assert {k["kind"] for k in user["kinds"]} >= {"table"} and user["apps"][0]["app_name"] == "ANALYTICS_DB.APPS.SALES_DASH"


def test_each_viewer_shows_the_role_used_and_the_grant_path_to_the_app():
    who = {w["user_name"]: w for w in client.get("/api/access/apps", params={"window": 30}).json()["who"]}
    assert who["ANALYST_CARA"]["roles"] == "ANALYST_ROLE"
    assert ["ANALYST_CARA", "ANALYST_ROLE"] in who["ANALYST_CARA"]["access_paths"]


def test_an_app_with_callers_rights_runs_as_each_viewer_and_a_view_read_by_an_insert_is_its_source():
    body = client.get("/api/access/apps", params={"window": 30, "app": "ANALYTICS_DB.APPS.MARKETING_APP"}).json()
    assert body["rights"] == "caller" and all(w["app_queries"] for w in body["who"])
    assert client.get("/api/access/apps", params={"window": 30, "app": "ANALYTICS_DB.APPS.SALES_DASH"}).json()["rights"] == "owner"
    views = client.get("/api/access/log/objects", params={"window": 30, "kind": "view"}).json()["objects"]
    for v in views:
        kinds = [s["k"] for s in client.get("/api/access/log", params={"object": v["object_fqn"], "window": 30}).json()["statements"]]
        assert not {"INSERT", "MERGE", "UPDATE", "DELETE"} & set(kinds), (v["object_fqn"], kinds)
