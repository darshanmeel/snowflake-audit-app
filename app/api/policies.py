"""app/api/policies.py -- masking and row access policies in use: who saw clear text, who can bypass, what changed.

All local: joins sf_gov_policy_hits (enforced policies per user, role and object), sf_secx_policy_body_exemptions
(the roles a policy body lets through), the grant links of explorer.py and the access log's DDL rows.

    GET /api/policies/hits?window=        per policy x role: queries it was enforced on
    GET /api/policies/clear-text?window=  masking hits under an exempt role: the reader saw the value
    GET /api/policies/reach               per policy and protected table: the users who can bypass it
    GET /api/policies/changes?window=     who created, altered or dropped a policy, and when
"""
from __future__ import annotations

import duckdb
from fastapi import APIRouter, HTTPException

from app.api import access_log, explorer
from app.core import identity

router = APIRouter()

HITS = "findings.f_sf_gov_policy_hits"
EXEMPT = "findings.f_sf_secx_policy_body_exemptions"
MASKS = "findings.f_access_column_masks_inventory"
FILTERS = "findings.f_access_row_filters_inventory"


def _rows_or_503(sql: str, params: list, what: str) -> list[dict]:
    try:
        return access_log._rows(sql, params)
    except duckdb.Error:
        raise HTTPException(503, f"No {what} in this export: run it again.")


def _exemptions() -> dict:
    """{policy_fqn: {"check", "roles", "public"}}; empty when the body check did not run."""
    try:
        rows = access_log._rows(f"SELECT policy_fqn, context_check, exempt_roles, exempts_public FROM {EXEMPT}", [])
    except duckdb.Error:
        return {}
    return {str(r["policy_fqn"]).upper(): {"check": r["context_check"], "public": bool(r["exempts_public"]),
                                           "roles": {x.strip().upper() for x in str(r["exempt_roles"] or "").split(",") if x.strip()}}
            for r in rows}


def _graph():
    try:
        return explorer._load(None)
    except HTTPException:
        return None


def _below(g: dict, role: str) -> set:
    """The role and every role it inherits: what IS_ROLE_IN_SESSION sees when it is the primary role."""
    seen, stack = set(), [role]
    while stack:
        r = stack.pop()
        if r not in seen:
            seen.add(r)
            stack.extend(g["children"].get(r, []) if g else [])
    return seen


def _verdict(ex: dict | None, role: str, g) -> tuple[str, str]:
    """(clear | masked | unknown, why) for one masking hit under `role`."""
    if ex is None:
        return "unknown", "the policy body was not read"
    if ex["public"]:
        return "clear", "the body lets every role through (PUBLIC)"
    if ex["check"] == "CURRENT_ROLE":
        return ("clear", "the role is exempt in the body") if role in ex["roles"] else ("masked", "role not named")
    if ex["check"] == "IS_ROLE_IN_SESSION":
        hit = sorted(_below(g, role) & ex["roles"])
        if hit:
            return "clear", "the role is exempt in the body" if hit == [role] else f"the role inherits exempt {', '.join(hit)}"
        return "masked", "role not exempt (secondary roles are not recorded)"
    return "unknown", "the body decides by a lookup or no role check"


@router.get("/api/policies/hits")
def get_hits(window: int = 30) -> dict:
    start, end = access_log._range(window)
    rows = _rows_or_503(
        f"SELECT policy_fqn, policy_kind, role_name, SUM(queries) AS queries, COUNT(DISTINCT user_name) AS users, "
        f"COUNT(DISTINCT object_fqn) AS objects, MAX(last_at) AS last_at FROM {HITS} "
        f"WHERE policy_fqn IS NOT NULL AND usage_date >= ? AND usage_date < ? GROUP BY 1, 2, 3 "
        f"ORDER BY 1, queries DESC", [start, end], "policy use log")
    return {"window": window, "start": start, "end": end, "rows": rows}


@router.get("/api/policies/clear-text")
def get_clear_text(window: int = 30) -> dict:
    start, end = access_log._range(window)
    rows = _rows_or_503(
        f"SELECT user_name, role_name, policy_fqn, object_fqn, "
        f"array_to_string(list_sort(list_distinct(flatten(list(string_split(COALESCE(columns, ''), ', '))))), ', ') AS columns, "
        f"SUM(queries) AS queries, MAX(last_at) AS last_at FROM {HITS} "
        f"WHERE policy_kind = 'MASKING_POLICY' AND usage_date >= ? AND usage_date < ? GROUP BY 1, 2, 3, 4",
        [start, end], "policy use log")
    ex, g = _exemptions(), _graph()
    out = {"clear": [], "masked": 0, "unknown": 0}
    for r in rows:
        verdict, why = _verdict(ex.get(str(r["policy_fqn"]).upper()), str(r["role_name"]).upper(), g)
        if verdict == "clear":
            out["clear"].append({**r, "user_name": access_log._who(r["user_name"]), "why": why})
        else:
            out[verdict] += 1
    out["clear"].sort(key=lambda r: (-(r["queries"] or 0), r["policy_fqn"]))
    return {"window": window, "start": start, "end": end, "exemptions_read": bool(ex), **out}


@router.get("/api/policies/reach")
def get_reach() -> dict:
    ex, g = _exemptions(), _graph()
    if not ex:
        raise HTTPException(503, "No policy exemptions in this export: run it again with sf_secx_policy_body_exemptions.")
    if g is None:
        raise HTTPException(503, "No grant links in this export: run it again with sf_acc_grant_links.")
    mask = identity.masking_enabled()
    every = sorted(explorer._who(u, mask) for u in g["users"])
    policies = {}
    for fqn, e in ex.items():
        if e["public"]:
            users, how = every, "every user (PUBLIC)"
        elif e["check"] in ("CURRENT_ROLE", "IS_ROLE_IN_SESSION") and e["roles"]:
            holders = explorer._holders_of(g, sorted(e["roles"]), mask)
            users = sorted({h["name"] for h in holders if h["kind"] == "user"})
            how = "as primary role" if e["check"] == "CURRENT_ROLE" else "through any role they hold"
        else:
            users, how = None, "not readable from the body"
        policies[fqn] = {"policy_fqn": fqn, "check": e["check"], "exempt_roles": sorted(e["roles"]), "users": users, "how": how}
    tables = []
    for kind, sql in (
            ("masking", f"SELECT table_catalog || '.' || table_schema || '.' || table_name AS t, "
                                            f"LISTAGG(DISTINCT column_name, ', ') AS cols, mask_name AS p FROM {MASKS} GROUP BY 1, 3"),
            ("row access", f"SELECT table_catalog || '.' || table_schema || '.' || table_name AS t, "
                                                   f"NULL AS cols, filter_name AS p FROM {FILTERS}"),
            # masks that reach a column through a tag are not in the inventory
            ("masking (tag)", f"SELECT table_fqn AS t, LISTAGG(DISTINCT column_name, ', ') AS cols, "
                              f"UNNEST(string_split(masking_policies, ', ')) AS p FROM {access_log.TAGGED} "
                              f"WHERE masked_via LIKE 'tag%' GROUP BY table_fqn, masking_policies")):
        try:
            rows = access_log._rows(sql, [])
        except duckdb.Error:
            continue
        for r in rows:
            p = policies.get(str(r["p"]).upper())
            tables.append({"table": r["t"], "kind": kind, "columns": r["cols"], "policy_fqn": str(r["p"]).upper(),
                           "bypass_users": None if not p or p["users"] is None else len(p["users"])})
    tables.sort(key=lambda t: (-(t["bypass_users"] or 0), t["table"]))
    return {"policies": sorted(policies.values(), key=lambda p: (-len(p["users"] or []), p["policy_fqn"])), "tables": tables}


@router.get("/api/policies/changes")
def get_changes(window: int = 30) -> dict:
    start, end = access_log._range(window)
    rows = _rows_or_503(
        f"SELECT CAST(bucket_start AS DATE) AS day, user_name, role_name, object_domain, object_fqn, "
        f"{access_log._merged('ddl_operations')} AS operations, SUM(ddl_queries) AS ddl, MAX(last_at) AS last_at "
        f"FROM {access_log.LOG} WHERE ddl_queries > 0 AND object_domain LIKE '%POLICY%' "
        f"AND bucket_start >= ? AND bucket_start < ? GROUP BY 1, 2, 3, 4, 5 ORDER BY 1 DESC, 5",
        [start, end], "access log")
    for r in rows:
        r["user_name"] = access_log._who(r["user_name"])
    return {"window": window, "start": start, "end": end, "rows": rows}
