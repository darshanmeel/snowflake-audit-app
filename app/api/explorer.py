"""app/api/explorer.py -- the Access explorer: who has what, and through which path.

Walks the grant links of sf_acc_grant_links (user -> role, role -> role, role -> object) in Python.

    GET /api/access/names                  users, roles and objects to pick from
    GET /api/access/explore?kind=&name=    kind user | role: every privilege it can use, with every path
                                           (a role also lists who holds it); kind object: every user and
                                           role that holds a privilege on it, with every path
Both take an optional account_id (default: the first account in the export).
"""
from __future__ import annotations

from collections import deque

import duckdb
from fastapi import APIRouter, HTTPException

from app.core import data as app_core_data
from app.core import identity

router = APIRouter()

TABLE = "f_sf_acc_grant_links"
ADMIN = {"ACCOUNTADMIN", "SECURITYADMIN", "USERADMIN", "SYSADMIN", "ORGADMIN", "GLOBALORGADMIN"}
MAX_PATHS = 10       # paths kept per role reached; the count says how many there were
MAX_DEPTH = 25       # role hops; Snowflake forbids cycles, the cap guards a malformed export
READ = {"SELECT", "REFERENCES", "READ"}
WRITE = {"INSERT", "UPDATE", "DELETE", "TRUNCATE", "WRITE", "MODIFY", "REBUILD"}
_cache: dict = {}


def priv_class(priv: str, granted_on: str) -> str:
    """read | write | own | use: the badge a privilege gets."""
    p = (priv or "").upper()
    if p == "OWNERSHIP" or granted_on == "ACCOUNT" or p.startswith("MANAGE") or p.startswith("APPLY"):
        return "own"
    if p in READ or (p == "USAGE" and granted_on in ("DATABASE", "SCHEMA")):
        return "read"
    if p in WRITE or p.startswith("CREATE"):
        return "write"
    return "use"


def _load(account_id: str | None) -> dict:
    """The graph for one account, cached until the data file changes."""
    try:
        con = app_core_data._connect()
        path = app_core_data._db_path()
        key = (str(path), path.stat().st_mtime, account_id)
        if key in _cache:
            return _cache[key]
        accounts = [r[0] for r in con.execute(f"SELECT DISTINCT account_id FROM findings.{TABLE} ORDER BY 1").fetchall()]
        acct = account_id if account_id in accounts else (accounts[0] if accounts else None)
        rows = con.execute(f"SELECT link_kind, grantee, grantee_type, name, granted_on, privilege, grant_option, "
                           f"user_type, is_disabled, last_success_login, default_role "
                           f"FROM findings.{TABLE} WHERE account_id IS NOT DISTINCT FROM ?", [acct]).fetchall()
        try:  # queries per table, so the graph can show the most used ones; none when Activity did not run
            activity = dict(con.execute(
                "SELECT table_fqn, SUM(COALESCE(read_queries, 0) + COALESCE(write_queries, 0) + COALESCE(ddl_queries, 0)) "
                "FROM findings.f_sf_use_table_activity WHERE row_level = 'table' AND window_days = 30 "
                "AND account_id IS NOT DISTINCT FROM ? GROUP BY 1", [acct]).fetchall())
        except duckdb.Error:
            activity = {}
    except (duckdb.Error, OSError):
        raise HTTPException(503, "No grant links in this export: run it again with sf_acc_grant_links.")
    g = {"account_id": acct, "accounts": accounts, "users": {}, "user_roles": {}, "children": {}, "parents": {},
         "grants": {}, "holders": {}, "kinds": {}, "activity": activity}
    for kind, grantee, gkind, name, on, priv, opt, utype, disabled, login, default in rows:
        if kind == "user":
            g["users"][grantee] = {"user_type": utype, "is_disabled": bool(disabled), "default_role": default,
                                   "last_success_login": str(login)[:10] if login else None}
        elif kind == "user_role":
            g["user_roles"].setdefault(grantee, []).append(name)
        elif kind == "role_role":
            g["children"].setdefault(grantee, []).append(name)
            g["parents"].setdefault(name, []).append(grantee)
        else:
            g["grants"].setdefault(grantee, []).append((priv, on, name, bool(opt)))
            g["holders"].setdefault(name, []).append((grantee, priv, on, bool(opt)))
            g["kinds"][name] = on
    for u in g["users"]:                 # every user holds PUBLIC without a grant row
        g["user_roles"].setdefault(u, []).append("PUBLIC")
    _cache.clear()
    _cache[key] = g
    return g


def _walk(starts: list[list[str]], step: dict) -> dict:
    """Every role reachable from the start paths along `step` (children down, parents up): {role: (paths, n)}.
    Breadth first, so the MAX_PATHS paths kept are the shortest; n counts the paths found, and stops growing
    once a role is past the cap (n >= MAX_PATHS means "at least")."""
    out: dict = {}
    stack = deque(starts)
    while stack:
        path = stack.popleft()
        role = path[-1]
        paths, n = out.get(role, ([], 0))
        if len(paths) < MAX_PATHS:
            paths.append(path)
        out[role] = (paths, n + 1)
        if len(path) <= MAX_DEPTH and n < MAX_PATHS:   # past the cap only count, don't walk again
            stack.extend(path + [c] for c in step.get(role, []) if c not in path)
    return {r: (p, n) for r, (p, n) in out.items()}


def _who(name: str, mask: bool) -> str:
    return identity.format_identity(name) if mask else name


def _real_user(g: dict, name: str, mask: bool) -> str | None:
    if name in g["users"]:
        return name
    if mask:
        return next((u for u in g["users"] if identity.format_identity(u) == name), None)
    return None


def _grants_from(g: dict, starts: list[list[str]], is_user: bool, mask: bool) -> tuple[list, list]:
    """(privilege rows, roles reached) for a user or role, each with its paths."""
    reached = _walk(starts, g["children"])
    by: dict = {}
    for role, (paths, n) in reached.items():
        for priv, on, obj, opt in g["grants"].get(role, []):
            row = by.setdefault((priv, on, obj), {"privilege": priv, "granted_on": on, "object": obj,
                                                  "cls": priv_class(priv, on), "grant_option": False,
                                                  "holders": [], "paths": [], "path_count": 0})
            row["holders"].append(role)
            row["grant_option"] = row["grant_option"] or opt
            row["paths"].extend(p + [obj] for p in paths)
            row["path_count"] += n
            row["capped"] = row.get("capped", False) or n >= MAX_PATHS
    off = 1 if is_user else 0
    fix = (lambda p: [_who(p[0], mask)] + p[1:]) if is_user else (lambda p: p)
    rows = []
    for row in by.values():
        row["paths"] = [fix(p) for p in sorted(row["paths"], key=len)[:MAX_PATHS]]
        row["depth"] = len(row["paths"][0]) - 1 - off
        row["direct"] = row["depth"] == 1
        row["admin"] = any(r in ADMIN for p in row["paths"] for r in p[off:-1])
        row["queries"] = g["activity"].get(row["object"])
        rows.append(row)
    rows.sort(key=lambda r: (r["object"], r["privilege"]))
    # depth: steps from the start; a user's granted roles and a role's own children are 1, the role itself 0
    roles = [{"role": r, "depth": len(p[0]) - 1, "admin": r in ADMIN, "paths": [fix(x) for x in p], "path_count": n,
              "capped": n >= MAX_PATHS}
             for r, (p, n) in reached.items()]
    roles.sort(key=lambda r: (r["depth"], r["role"]))
    return rows, roles


def _holders_of(g: dict, roles: list[str], mask: bool) -> list:
    """Users and roles that can use any of `roles`, with paths ending at that role (top first)."""
    up = _walk([[r] for r in roles], g["parents"])
    out = []
    for role, (paths, n) in up.items():
        out.append({"kind": "role", "name": role, "admin": role in ADMIN, "depth": len(paths[0]) - 1,
                    "paths": [list(reversed(p)) for p in paths], "path_count": n, "capped": n >= MAX_PATHS})
    users: dict = {}
    capped: set = set()
    for u, held in g["user_roles"].items():
        for r in held:
            paths, n = up.get(r, ([], 0))
            if n >= MAX_PATHS:
                capped.add(u)
            for p in paths:
                users.setdefault(u, []).append([_who(u, mask)] + list(reversed(p)))
    for u, paths in users.items():
        paths.sort(key=len)
        info = g["users"].get(u, {})
        out.append({"kind": "user", "name": _who(u, mask), **info, "depth": len(paths[0]) - 1,
                    "admin": any(r in ADMIN for p in paths for r in p[1:]), "paths": paths[:MAX_PATHS],
                    "path_count": len(paths), "capped": u in capped})
    out.sort(key=lambda h: (h["kind"] != "user", h["depth"], h["name"]))
    return out


def _users_per_role(g: dict) -> dict:
    """{role: users who can use it, directly or through other roles}: who else a cut on that role touches."""
    below: dict = {}

    def reach(role: str) -> set:
        if role not in below:
            below[role] = {role}   # set first, so a loop in the role graph stops here
            for c in g["children"].get(role, []):
                below[role] |= reach(c)
        return below[role]
    count: dict = {}
    for held in g["user_roles"].values():
        for r in set().union(*(reach(r) for r in held)) if held else ():
            count[r] = count.get(r, 0) + 1
    return count


@router.get("/api/access/names")
def get_names(account_id: str | None = None) -> dict:
    g = _load(account_id)
    mask = identity.masking_enabled()
    roles = set(g["grants"]) | set(g["children"]) | set(g["parents"]) | {r for v in g["user_roles"].values() for r in v}
    per_role = _users_per_role(g)
    users = [{"name": _who(u, mask), **info, "roles": len(g["user_roles"].get(u, []))} for u, info in g["users"].items()]
    return {"account_id": g["account_id"], "accounts": g["accounts"],
            "users": sorted(users, key=lambda u: u["name"]),
            "roles": [{"name": r, "admin": r in ADMIN, "privileges": len(g["grants"].get(r, [])),
                       "users": per_role.get(r, 0)} for r in sorted(roles)],
            "objects": [{"name": o, "granted_on": k} for o, k in sorted(g["kinds"].items())]}


@router.get("/api/access/explore")
def get_explore(kind: str, name: str, account_id: str | None = None) -> dict:
    g = _load(account_id)
    mask = identity.masking_enabled()
    if kind == "user":
        u = _real_user(g, name, mask)
        if u is None:
            raise HTTPException(404, f"no user {name} in this export")
        rows, roles = _grants_from(g, [[u, r] for r in g["user_roles"].get(u, [])], True, mask)
        return {"kind": kind, "name": _who(u, mask), "user": g["users"][u], "grants": rows, "roles": roles}
    if kind == "role":
        if name not in g["grants"] and name not in g["children"] and name not in g["parents"] and \
                not any(name in v for v in g["user_roles"].values()):
            raise HTTPException(404, f"no role {name} in this export")
        rows, roles = _grants_from(g, [[name]], False, mask)
        return {"kind": kind, "name": name, "grants": rows, "roles": roles, "holders": _holders_of(g, [name], mask)}
    if kind == "object":
        held = g["holders"].get(name)
        if not held:
            raise HTTPException(404, f"no grants on {name} in this export")
        by: dict = {}
        for role, priv, on, opt in held:
            for h in _holders_of(g, [role], mask):
                row = by.setdefault((h["kind"], h["name"], priv), {**h, "privilege": priv, "cls": priv_class(priv, on),
                                                                   "grant_option": False, "paths": [], "path_count": 0, "capped": False})
                row["capped"] = row["capped"] or h["capped"]
                row["grant_option"] = row["grant_option"] or opt
                row["paths"].extend(p + [name] for p in h["paths"])
                row["path_count"] += h["path_count"]
                row["admin"] = row["admin"] or h["admin"]
        rows = list(by.values())
        for r in rows:
            r["paths"] = sorted(r["paths"], key=len)[:MAX_PATHS]
            r["depth"] = len(r["paths"][0]) - 2
        rows.sort(key=lambda r: (r["kind"] != "user", r["name"], r["privilege"]))
        return {"kind": kind, "name": name, "granted_on": g["kinds"].get(name), "holders": rows}
    raise HTTPException(422, "kind must be user, role or object")
