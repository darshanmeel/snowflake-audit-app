"""tests/test_owner_filter.py

The Owner filter: matches any owner-like column a check has (user_name, executed_by, owner_role...);
on a check with a task column (task_full_name) but none of those, through dims.dim_task's owner_role
instead. A check with neither is unaffected, and reports scope.owner_applied False.
"""
from __future__ import annotations

import pytest
from fastapi.testclient import TestClient

from app.api.app import app

client = TestClient(app)
WINDOW = 30

COLUMN_CHECK = "sf_chg_by_warehouse_and_user_daily"      # has user_name
TASK_CHECK = "sf_task_failures"                           # has task_full_name, no owner column
NEITHER_CHECK = "sf_wh_auto_suspend_tuning"        # warehouse-only


def _rows(query_id: str, **params) -> dict:
    resp = client.get(f"/api/finding/{query_id}", params={"window": WINDOW, "limit": 5000, **params})
    assert resp.status_code == 200
    return resp.json()


def _task_owners() -> dict[str, str]:
    return {t["task_full_name"]: t["owner_role"] for t in client.get("/api/dims").json()["tasks"]}


def test_owner_filter_narrows_a_check_with_an_owner_like_column():
    base = _rows(COLUMN_CHECK)
    assert base["outcome"] == "ok_rows"
    users = sorted({r["user_name"] for r in base["rows"] if r["user_name"]})
    assert len(users) > 1
    owner = users[0]
    filtered = _rows(COLUMN_CHECK, owner=owner)
    assert filtered["outcome"] == "ok_rows"
    assert filtered["scope"]["owner_applied"] is True
    assert 0 < filtered["rows_total"] < base["rows_total"]
    assert {r["user_name"] for r in filtered["rows"]} == {owner}
    assert filtered["rows_total"] == sum(1 for r in base["rows"] if r["user_name"] == owner)


def test_owner_filter_is_case_insensitive():
    base = _rows(COLUMN_CHECK)
    owner = next(r["user_name"] for r in base["rows"] if r["user_name"])
    assert _rows(COLUMN_CHECK, owner=owner.lower())["rows_total"] == _rows(COLUMN_CHECK, owner=owner.upper())["rows_total"] > 0


def test_owner_filter_narrows_a_task_check_through_dim_task():
    base = _rows(TASK_CHECK)
    assert base["outcome"] == "ok_rows"
    owners = _task_owners()
    by_owner: dict[str, set[str]] = {}
    for r in base["rows"]:
        owner = owners.get(r["task_full_name"])
        if owner:
            by_owner.setdefault(owner, set()).add(r["task_full_name"])
    assert len(by_owner) >= 2, "the fake tasks must have more than one owner role"
    owner = sorted(by_owner)[0]
    filtered = _rows(TASK_CHECK, owner=owner)
    assert filtered["outcome"] == "ok_rows"
    assert filtered["scope"]["owner_applied"] is True
    assert 0 < filtered["rows_total"] < base["rows_total"]
    assert {r["task_full_name"] for r in filtered["rows"]} == by_owner[owner]
    assert all(owners[r["task_full_name"]] == owner for r in filtered["rows"])


def test_owner_filter_leaves_a_warehouse_only_check_unaffected():
    base = _rows(NEITHER_CHECK)
    assert base["outcome"] == "ok_rows"
    filtered = _rows(NEITHER_CHECK, owner="nobody@example.com")
    assert filtered["outcome"] == "ok_rows"
    assert filtered["scope"]["owner_applied"] is False
    assert filtered["rows_total"] == base["rows_total"]


def test_an_owner_nobody_has_reads_empty_by_filter_not_empty_window():
    body = _rows(COLUMN_CHECK, owner="NOBODY_HAS_THIS_NAME")
    assert body["outcome"] == "ok_empty_filters"
    assert body["scope"]["owner_applied"] is True
    assert "rows" not in body or body["rows"] == []


def test_no_owner_filter_reports_owner_applied_none():
    assert _rows(COLUMN_CHECK)["scope"]["owner_applied"] is None


def test_owner_filter_reaches_the_findings_list_and_the_aggregate():
    base = _rows(COLUMN_CHECK)
    owner = next(r["user_name"] for r in base["rows"] if r["user_name"])
    expected = _rows(COLUMN_CHECK, owner=owner)["rows_total"]

    findings = {r["query_id"]: r for r in client.get(
        "/api/findings", params={"window": WINDOW, "owner": owner}).json()["findings"]}
    assert findings[COLUMN_CHECK]["row_count"] == expected
    unfiltered = {r["query_id"]: r for r in client.get("/api/findings", params={"window": WINDOW}).json()["findings"]}
    assert findings[NEITHER_CHECK]["row_count"] == unfiltered[NEITHER_CHECK]["row_count"]

    agg = client.get(f"/api/finding/{COLUMN_CHECK}/aggregate",
                     params={"window": WINDOW, "agg": "count", "owner": owner}).json()
    assert agg["matched_rows"] == expected
