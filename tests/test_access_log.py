"""tests/test_access_log.py: the access log, off-hours and tag explorer routes on the fake account's test DB."""
from __future__ import annotations

import sys
from pathlib import Path

import duckdb
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
    assert busy == sorted(busy, reverse=True) and body["total"] >= len(body["objects"])
    assert body["truncated"] is False
    sens = client.get("/api/access/log/objects", params={"window": 30, "sensitive": True}).json()["objects"]
    assert sens and all(o["sensitive"] in ("tagged", "suggested") for o in sens)


def test_one_object_stays_inside_the_window_and_never_counts_a_merge_target_as_read():
    name = client.get("/api/access/log/objects", params={"window": 7}).json()["objects"][0]["object_fqn"]
    body = client.get("/api/access/log", params={"object": name, "window": 7}).json()
    assert body["buckets"] and all(body["start"] <= b["bucket"][:10] < body["end"] for b in body["buckets"])
    assert sum(b["reads"] for b in body["buckets"]) == sum(w["reads"] for w in body["who"])
    # a user whose every statement on the table is a MERGE has writes, no reads
    merges = [w for w in body["who"] if w["statement_types"] == "MERGE"]
    assert all(w["reads"] == 0 for w in merges)


def test_off_hours_lists_people_only():
    rows = client.get("/api/access/log/offhours", params={"window": 30}).json()["rows"]
    assert rows and all(r["off_hours"] > 0 for r in rows)
    people = {r[0] for r in duckdb.connect(str(access_log.app_core_data._db_path()), read_only=True).execute(
        "SELECT DISTINCT user_name FROM findings.f_sf_use_access_log WHERE is_person").fetchall()}
    assert {r["user_name"] for r in rows} <= people


def test_a_column_tag_lists_who_can_read_and_who_queried():
    tags = client.get("/api/access/tags").json()["tags"]
    tag = next(t for t in tags if "COLUMN" in t["levels"])
    objs = client.get("/api/access/tag", params={"tag": tag["tag_fqn"], "value": tag["tag_value"]}).json()["objects"]
    assert objs and all(o["level"] == "COLUMN" for o in objs)
    assert any(o["can_read"] for o in objs) and all(isinstance(o["queried_by"], list) for o in objs)


def test_a_missing_log_reads_503(monkeypatch):
    monkeypatch.setattr(access_log, "LOG", "findings.f_no_such_table")
    assert client.get("/api/access/log/objects").status_code == 503
