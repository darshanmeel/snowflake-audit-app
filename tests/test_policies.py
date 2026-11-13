"""tests/test_policies.py: who saw clear text, who can bypass a policy, policy use and changes, on the test DB."""
from __future__ import annotations

import sys
from pathlib import Path

from fastapi.testclient import TestClient

ROOT = Path(__file__).resolve().parent.parent
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from app.api import policies  # noqa: E402
from app.api.app import app  # noqa: E402

client = TestClient(app)
MASK = "ANALYTICS_DB.PUBLIC.MASK_PII_TAG"   # exempts ACCOUNTADMIN through IS_ROLE_IN_SESSION


def test_an_exempt_role_saw_clear_text_and_another_role_did_not():
    body = client.get("/api/policies/clear-text", params={"window": 30}).json()
    clear = {(r["user_name"], r["role_name"]) for r in body["clear"] if r["policy_fqn"] == MASK}
    assert ("ADMIN_ALICE", "ACCOUNTADMIN") in clear
    assert ("ANALYST_DAN", "ANALYST_ROLE") not in clear and body["masked"] >= 1


def test_the_verdict_follows_the_body_check():
    g = {"children": {"SYSADMIN": ["PII_READER"]}}
    in_session = {"check": "IS_ROLE_IN_SESSION", "public": False, "roles": {"PII_READER"}}
    assert policies._verdict(in_session, "SYSADMIN", g)[0] == "clear"          # inherited counts
    current = {**in_session, "check": "CURRENT_ROLE"}
    assert policies._verdict(current, "SYSADMIN", g)[0] == "masked"            # primary role only
    assert policies._verdict({**in_session, "check": "LOOKUP"}, "SYSADMIN", g)[0] == "unknown"
    assert policies._verdict(None, "SYSADMIN", g)[0] == "unknown"
    assert policies._verdict({**in_session, "public": True}, "ANYONE", g)[0] == "clear"


def test_reach_lists_who_can_bypass_and_the_tables_it_protects():
    body = client.get("/api/policies/reach").json()
    pol = next(p for p in body["policies"] if p["policy_fqn"] == MASK)
    assert "ADMIN_ALICE" in pol["users"]
    assert any(t["policy_fqn"] == MASK and t["bypass_users"] == len(pol["users"]) for t in body["tables"])


def test_hits_count_row_access_too_and_changes_list_policy_ddl():
    kinds = {r["policy_kind"] for r in client.get("/api/policies/hits", params={"window": 30}).json()["rows"]}
    assert {"MASKING_POLICY", "ROW_ACCESS_POLICY"} <= kinds
    rows = client.get("/api/policies/changes", params={"window": 30}).json()["rows"]
    assert any(r["object_fqn"].endswith("MASK_EMAIL") and "ALTER" in r["operations"] for r in rows)
