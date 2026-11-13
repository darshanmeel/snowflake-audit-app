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
