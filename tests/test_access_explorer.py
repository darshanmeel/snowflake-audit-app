"""tests/test_access_explorer.py: the Access explorer's graph walk and its two routes.

The walk is tested on small hand-made graphs; the routes on the fake account's test DB (tests/conftest.py).
"""
from __future__ import annotations

import sys
from pathlib import Path

from fastapi.testclient import TestClient

ROOT = Path(__file__).resolve().parent.parent
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from app.api import explorer  # noqa: E402
from app.api.app import app  # noqa: E402

client = TestClient(app)


def _graph(user_roles: dict, role_roles: list, grants: list) -> dict:
    """A graph as _load builds it: user_roles {user: [roles]}, role_roles [(parent, child)],
    grants [(role, privilege, granted_on, object)]."""
    g = {"account_id": "T", "accounts": ["T"], "activity": {}, "kinds": {}, "children": {}, "parents": {},
         "grants": {}, "holders": {}, "users": {u: {"user_type": "PERSON", "is_disabled": False,
                                                    "default_role": None, "last_success_login": None}
                                                for u in user_roles},
         "user_roles": {u: list(r) for u, r in user_roles.items()}}
    for parent, child in role_roles:
        g["children"].setdefault(parent, []).append(child)
        g["parents"].setdefault(child, []).append(parent)
    for role, priv, on, obj in grants:
        g["grants"].setdefault(role, []).append((priv, on, obj, False))
        g["holders"].setdefault(obj, []).append((role, priv, on, False))
        g["kinds"][obj] = on
    return g


# EVA reaches T through BI -> ANALYST and through ADMIN -> BI -> ANALYST; MO holds ANALYST only.
G = _graph({"EVA": ["BI", "ADMIN"], "MO": ["ANALYST"], "ZED": ["OTHER"]},
           [("ADMIN", "BI"), ("BI", "ANALYST")],
           [("ANALYST", "SELECT", "TABLE", "DB.S.T"), ("OTHER", "SELECT", "TABLE", "DB.S.U")])


def test_priv_class():
    assert explorer.priv_class("SELECT", "TABLE") == "read"
    assert explorer.priv_class("USAGE", "DATABASE") == "read"
    assert explorer.priv_class("USAGE", "WAREHOUSE") == "use"
    assert explorer.priv_class("INSERT", "TABLE") == "write"
    assert explorer.priv_class("CREATE TABLE", "SCHEMA") == "write"
    assert explorer.priv_class("OWNERSHIP", "TABLE") == "own"
    assert explorer.priv_class("MONITOR USAGE", "ACCOUNT") == "own"


def test_walk_keeps_shortest_paths_first_and_counts_all():
    out = explorer._walk([["EVA", "BI"], ["EVA", "ADMIN"]], G["children"])
    paths, n = out["ANALYST"]
    assert n == 2
    assert paths == [["EVA", "BI", "ANALYST"], ["EVA", "ADMIN", "BI", "ANALYST"]]


def test_walk_caps_paths_and_survives_a_loop():
    # 12 roles each grant HUB: past MAX_PATHS only the count grows. A -> B -> A must not loop.
    many = _graph({}, [(f"R{i}", "HUB") for i in range(12)] + [("A", "B"), ("B", "A")], [])
    paths, n = explorer._walk([[f"R{i}"] for i in range(12)], many["children"])["HUB"]
    assert len(paths) == explorer.MAX_PATHS and n >= explorer.MAX_PATHS
    assert set(explorer._walk([["A"]], many["children"])) == {"A", "B"}


def test_users_per_role_counts_each_user_once_through_any_route():
    count = explorer._users_per_role(G)
    assert count["ANALYST"] == 2      # EVA by two routes, MO directly
    assert count["BI"] == 1 and count["ADMIN"] == 1 and count["OTHER"] == 1
    looped = _graph({"U": ["A"]}, [("A", "B"), ("B", "A")], [])
    assert explorer._users_per_role(looped) == {"A": 1, "B": 1}


def test_grants_from_a_user_lists_every_path():
    rows, roles = explorer._grants_from(G, [["EVA", r] for r in G["user_roles"]["EVA"]], True, False)
    (row,) = rows
    assert (row["object"], row["privilege"], row["cls"]) == ("DB.S.T", "SELECT", "read")
    assert row["path_count"] == 2 and row["depth"] == 2 and not row["direct"]
    assert row["paths"][0] == ["EVA", "BI", "ANALYST", "DB.S.T"]
    assert {r["role"] for r in roles} == {"BI", "ADMIN", "ANALYST"}


def test_holders_of_a_role_has_users_and_roles_above_it():
    holders = explorer._holders_of(G, ["ANALYST"], False)
    users = {h["name"]: h for h in holders if h["kind"] == "user"}
    assert set(users) == {"EVA", "MO"}
    assert users["EVA"]["path_count"] == 2 and users["MO"]["depth"] == 1
    assert users["EVA"]["paths"][0] == ["EVA", "BI", "ANALYST"]
    assert {h["name"] for h in holders if h["kind"] == "role"} == {"ANALYST", "BI", "ADMIN"}


# --- the routes, on the fake account ---

def test_names_lists_users_roles_and_objects_with_user_counts():
    r = client.get("/api/access/names")
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["users"] and body["objects"]
    roles = {x["name"]: x for x in body["roles"]}
    assert all("users" in x and x["users"] >= 0 for x in roles.values())
    assert roles["PUBLIC"]["users"] == len(body["users"])   # every user holds PUBLIC
    assert roles["ACCOUNTADMIN"]["admin"]


def test_explore_object_user_and_role_agree():
    names = client.get("/api/access/names").json()
    obj = next(o["name"] for o in names["objects"] if o["granted_on"] == "TABLE")
    holders = client.get("/api/access/explore", params={"kind": "object", "name": obj}).json()["holders"]
    user = next(h for h in holders if h["kind"] == "user")
    assert all(p[0] == user["name"] and p[-1] == obj for p in user["paths"])
    mine = client.get("/api/access/explore", params={"kind": "user", "name": user["name"]}).json()
    assert obj in {g["object"] for g in mine["grants"]}
    role = user["paths"][0][-2]
    theirs = client.get("/api/access/explore", params={"kind": "role", "name": role}).json()
    assert user["name"] in {h["name"] for h in theirs["holders"] if h["kind"] == "user"}


def test_explore_unknown_names_and_kind():
    for kind in ("user", "role", "object"):
        assert client.get("/api/access/explore", params={"kind": kind, "name": "NO_SUCH_THING"}).status_code == 404
    assert client.get("/api/access/explore", params={"kind": "table", "name": "X"}).status_code == 422


def test_masking_on_hides_user_names_in_the_explorer_and_in_aggregate_keys():
    real = [u["name"] for u in client.get("/api/access/names").json()["users"]]
    assert real
    before = client.get("/api/settings/privacy").json()["mask_user_identities"]
    client.put("/api/settings/privacy", json={"mask_user_identities": True})
    try:
        names = client.get("/api/access/names").json()
        agg = client.get("/api/finding/sf_chg_by_warehouse_and_user_daily/aggregate",
                         params={"window": 30, "group": "user_name", "agg": "count"})
        assert agg.status_code == 200, agg.text
        for text in (str(names), agg.text):
            assert not [n for n in real if len(n) >= 4 and n in text], "a real user name is on screen"
        assert len(names["users"]) == len(real), (len(names["users"]), len(real))
        masked = names["users"][0]["name"]
        mine = client.get("/api/access/explore", params={"kind": "user", "name": masked})
        assert mine.status_code == 200, mine.text   # a masked name still finds its user
    finally:
        client.put("/api/settings/privacy", json={"mask_user_identities": before})
