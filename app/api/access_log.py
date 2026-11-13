"""app/api/access_log.py -- who touched what and when (Activity › Access log), and the tag explorer.

Reads findings.f_sf_use_access_log (object x user x role x client x statement x UTC day) and
findings.f_sf_use_access_hours (people only, per UTC hour), so a page never loads either whole. Off-hours is
recounted here at the offset the page asks for: every hours row keeps its UTC date and hour.

    GET /api/access/settings                          business hours and UTC offset from config
    GET /api/access/log/objects?window=&search=       objects to pick from, busiest first
    GET /api/access/overview?window=&offset=          tiles, off-hours use by person, hours of use
    GET /api/access/log?object=&window=&offset=       one object: per day, by client/role/user, statements, who
    GET /api/access/rollup?window=&level=             objects rolled up by schema or database, per kind
    GET /api/access/apps?window=&app=                 Streamlit apps: who opened which, when; what one app read
    GET /api/access/people?window=                    people and other users to pick from
    GET /api/access/person?user=&window=&offset=      one user: per day, objects, hours of use
    GET /api/access/tags, /api/access/tag?tag=        tag values; one tag's objects, who can read, who did
"""
from __future__ import annotations

from datetime import date, timedelta

import duckdb
from fastapi import APIRouter, HTTPException

from app.api import explorer
from app.core import config as app_config
from app.core import data as app_core_data
from app.core import identity
from app.core import registry

router = APIRouter()

LOG = "findings.f_sf_use_access_log"
HOURS = "findings.f_sf_use_access_hours"
APPS = "findings.f_sf_use_streamlit_access"
SHARES = "findings.f_sf_acc_streamlit_shares"
# object kinds the page filters and rolls up by, from ACCESS_HISTORY's objectDomain
KINDS = {"table": "('TABLE', 'DYNAMIC TABLE', 'ICEBERG TABLE', 'EXTERNAL TABLE', 'HYBRID TABLE')",
         "view": "('VIEW', 'MATERIALIZED VIEW', 'SECURE VIEW')", "stage": "('STAGE')", "procedure": "('PROCEDURE')",
         "function": "('FUNCTION', 'EXTERNAL FUNCTION')", "stream": "('STREAM')"}
TAGS = "findings.f_sf_gov_tag_objects"
TAGGED = "findings.f_sf_gov_sensitive_columns_unprotected"
SUGGESTED = "findings.f_sf_gov_sensitive_suggestions"
SPLITS = {"user": "user_name", "role": "role_name", "client": "client", "statement": "statement_type",
          "object": "object_fqn"}
TOP = 4   # series before Other: the chart folds past five itself
Q = "(read_queries + write_queries + ddl_queries)"


def _rows(sql: str, params: list) -> list[dict]:
    con = app_core_data._connect()
    cur = con.execute(sql, params)
    names = [d[0] for d in cur.description]
    return [dict(zip(names, r)) for r in cur.fetchall()]


def _range(window: int) -> tuple[str, str]:
    """[start, end) of the window, ending at the export's as-of date (the one money cut-off)."""
    info = app_core_data.direct_export_info() or {}
    if not info.get("as_of_date"):
        raise HTTPException(503, "This export has no as-of date: load it again.")
    end = date.fromisoformat(str(info["as_of_date"])[:10])
    return str(end - timedelta(days=int(window))), str(end)


def _log_or_503(sql: str, params: list) -> list[dict]:
    try:
        return _rows(sql, params)
    except duckdb.Error:
        raise HTTPException(503, "No access log in this export: run it again with sf_use_access_log.")


def _cut() -> dict:
    """Whether the export cut the log at its row cap, and from when it is complete (it keeps the newest)."""
    if not app_core_data.truncation_info("sf_use_access_log").get("truncated"):
        return {"truncated": False, "complete_from": None}
    first = _log_or_503(f"SELECT MIN(bucket_start) AS b FROM {LOG}", [])[0]["b"]
    # the oldest bucket kept may be partial, so the log is complete from the next one
    return {"truncated": True, "complete_from": str(first)[:10] if first else None}


def _sensitive() -> dict:
    """{table_fqn: 'tagged' | 'suggested'}; tagged wins."""
    out: dict = {}
    for table, kind in ((SUGGESTED, "suggested"), (TAGGED, "tagged")):
        try:
            for r in _rows(f"SELECT DISTINCT database_name || '.' || schema_name || '.' || table_name AS f "
                           f"FROM {table} WHERE table_name IS NOT NULL", []):
                out[r["f"]] = kind
        except duckdb.Error:
            pass
    return out


def _merged(col: str) -> str:
    """The distinct items of a comma-listed column across the grouped rows."""
    return (f"array_to_string(list_sort(list_filter(list_distinct(flatten(list(string_split(COALESCE({col}, ''), "
            f"', ')))), x -> x <> '')), ', ')")


def _who(name):
    return identity.format_identity(name) if identity.masking_enabled() else name


def _real_user(name: str) -> str:
    """The stored user name behind a name the page shows (masked when masking is on)."""
    if not identity.masking_enabled():
        return name
    for r in _log_or_503(f"SELECT DISTINCT user_name FROM {LOG} WHERE user_name IS NOT NULL", []):
        if identity.format_identity(r["user_name"]) == name:
            return r["user_name"]
    return name


def hours_settings() -> dict:
    """Business hours and UTC offset: the check's header defaults, overridden by config/thresholds.yml."""
    try:
        values = dict(registry.by_id("sf_use_access_hours").param_defaults())
        values.update((app_config.load_thresholds().get("sf_use_access_hours") or {}))
    except Exception:  # noqa: BLE001 -- a broken config falls back to the defaults, the page still shows
        values = {}
    return {"offset": int(values.get("business_utc_offset", 0)), "start": int(values.get("business_start_hour", 7)),
            "end": int(values.get("business_end_hour", 19))}


def _off(offset: int, start: int, end: int) -> tuple[str, list]:
    """SQL for 'this hours row is off hours' at an offset, and its params: weekends and outside start..end."""
    lt = "(CAST(usage_date AS TIMESTAMP) + to_hours(CAST(hour_utc AS BIGINT) + ?))"
    return f"(isodow({lt}) >= 6 OR hour({lt}) < ? OR hour({lt}) >= ?)", [offset, offset, start, offset, end]


def _hours_or_none(sql: str, params: list) -> list[dict] | None:
    try:
        return _rows(sql, params)
    except duckdb.Error:
        return None


def _series(where: str, params: list, split: str) -> dict:
    """Queries per day split by one dimension: {days, series: [{name, values}]}, the top keys and Other."""
    if split == "action":
        rows = _log_or_503(
            f"SELECT CAST(bucket_start AS DATE) AS d, k, SUM(v) AS q FROM (SELECT bucket_start, 'Read' AS k, read_queries AS v "
            f"{where} UNION ALL SELECT bucket_start, 'Write', write_queries {where} UNION ALL "
            f"SELECT bucket_start, 'DDL', ddl_queries {where}) GROUP BY 1, 2", params * 3)
    else:
        col = SPLITS.get(split, "user_name")
        rows = _log_or_503(f"SELECT CAST(bucket_start AS DATE) AS d, {col} AS k, SUM({Q}) AS q {where} GROUP BY 1, 2", params)
    total: dict = {}
    for r in rows:
        total[r["k"]] = total.get(r["k"], 0) + (r["q"] or 0)
    keep = [k for k, _ in sorted(total.items(), key=lambda kv: -kv[1])[:TOP]]
    by: dict = {}
    for r in rows:
        k = r["k"] if r["k"] in keep else "Other"
        by.setdefault(k, {}).setdefault(str(r["d"]), 0)
        by[k][str(r["d"])] += r["q"] or 0
    names = keep + (["Other"] if "Other" in by else [])
    shown = (lambda k: _who(k)) if split == "user" else (lambda k: k)
    return {"split": split, "series": [{"name": str(shown(k)), "values": by.get(k, {})} for k in names]}


def _by(where: str, params: list) -> dict:
    """Reads, writes and DDL grouped by client, role and user, with how many users, roles and objects."""
    by = {dim: _log_or_503(
        f"SELECT {col} AS k, SUM(read_queries) AS reads, SUM(write_queries) AS writes, SUM(ddl_queries) AS ddl, "
        f"COUNT(DISTINCT user_name) AS users, COUNT(DISTINCT object_fqn) AS objects, "
        f"array_to_string(list_sort(list(DISTINCT role_name)), ', ') AS roles, "
        f"array_to_string(list_sort(list(DISTINCT client)), ', ') AS clients "
        f"{where} GROUP BY 1 ORDER BY reads + writes + ddl DESC", params) for dim, col in
        (("client", "client"), ("role", "role_name"), ("user", "user_name"))}
    for r in by["user"]:
        r["k"] = _who(r["k"])
    return by


def _statements(where: str, params: list) -> list[dict]:
    return _log_or_503(
        f"SELECT statement_type AS k, SUM({Q}) AS queries, SUM(read_queries) AS reads, SUM(write_queries) AS writes, "
        f"SUM(ddl_queries) AS ddl, COUNT(DISTINCT user_name || role_name || client) AS combos, "
        f"COUNT(DISTINCT object_fqn) AS objects {where} GROUP BY 1 ORDER BY 2 DESC", params)


@router.get("/api/access/settings")
def get_settings() -> dict:
    return hours_settings()


@router.get("/api/access/log/objects")
def get_objects(window: int = 30, search: str = "", sensitive: bool = False, limit: int = 200,
                kind: str = "", prefix: str = "") -> dict:
    start, end = _range(window)
    kind_sql = (f" AND object_domain IN {KINDS[kind]}" if kind in KINDS else
                " AND object_domain NOT IN (" + ", ".join(v.strip("()") for v in KINDS.values()) + ")" if kind == "other" else "")
    rows = _log_or_503(
        f"SELECT object_fqn, MAX(object_domain) AS object_domain, SUM(read_queries) AS reads, "
        f"SUM(write_queries) AS writes, SUM(ddl_queries) AS ddl, COUNT(DISTINCT user_name) AS users, "
        f"COUNT(DISTINCT role_name) AS roles, COUNT(DISTINCT client) AS clients, MAX(last_at) AS last_at "
        f"FROM {LOG} WHERE object_fqn IS NOT NULL AND bucket_start >= ? AND bucket_start < ? "
        f"AND object_fqn ILIKE ? AND (object_fqn = ? OR object_fqn LIKE ? || '.%' OR ? = ''){kind_sql} "
        f"GROUP BY object_fqn ORDER BY reads + writes + ddl DESC, object_fqn",
        [start, end, f"%{search.strip()}%", prefix, prefix, prefix])
    sens = _sensitive()
    for r in rows:
        r["sensitive"] = sens.get(r["object_fqn"])
    if sensitive:
        rows = [r for r in rows if r["sensitive"]]
    return {"window": window, "start": start, "end": end, "total": len(rows),
            "objects": rows[:max(1, min(limit, 2000))], **_cut()}


@router.get("/api/access/overview")
def get_overview(window: int = 30, offset: int | None = None, start_hour: int | None = None,
                 end_hour: int | None = None, heat: str = "sensitive") -> dict:
    start, end = _range(window)
    cfg = hours_settings()
    offset, start_hour, end_hour = (cfg["offset"] if offset is None else offset,
                                    cfg["start"] if start_hour is None else start_hour, cfg["end"] if end_hour is None else end_hour)
    top = _log_or_503(
        f"SELECT COUNT(DISTINCT object_fqn) AS objects, COUNT(DISTINCT user_name) AS users, "
        f"SUM({Q}) AS queries FROM {LOG} WHERE bucket_start >= ? AND bucket_start < ?", [start, end])[0]
    busiest = _log_or_503(
        f"SELECT object_fqn, SUM({Q}) AS queries, COUNT(DISTINCT user_name) AS users FROM {LOG} "
        f"WHERE bucket_start >= ? AND bucket_start < ? GROUP BY 1 ORDER BY 2 DESC LIMIT 1", [start, end])
    off_sql, off_params = _off(offset, start_hour, end_hour)
    hrs = _hours_or_none(
        f"SELECT user_name, object_fqn, MAX(object_domain) AS object_domain, SUM(queries) AS off_hours, "
        f"SUM(read_queries) AS reads, SUM(write_queries) AS writes, SUM(ddl_queries) AS ddl, "
        f"array_to_string(list_sort(list(DISTINCT statement_type)), ', ') AS statements, "
        f"array_to_string(list_sort(list(DISTINCT role_name)), ', ') AS roles, MAX(usage_date) AS last_day "
        f"FROM {HOURS} WHERE user_name IS NOT NULL AND usage_date >= ? AND usage_date < ? AND {off_sql} GROUP BY 1, 2",
        [start, end, *off_params])
    sens = _sensitive()
    people: dict = {}
    for r in hrs or []:
        r["sensitive"] = sens.get(r["object_fqn"])
        p = people.setdefault(r["user_name"], {"user_name": _who(r["user_name"]), "off_hours": 0, "objects": []})
        p["off_hours"] += r["off_hours"] or 0
        p["objects"].append({k: v for k, v in r.items() if k != "user_name"})
    for p in people.values():
        # sensitive objects first, then changes before reads, then the most off-hours queries
        p["objects"].sort(key=lambda o: (o["sensitive"] is None, not ((o["ddl"] or 0) + (o["writes"] or 0)), -(o["off_hours"] or 0)))
    by_person = sorted(people.values(), key=lambda p: -p["off_hours"])
    # who touched which object off hours (sensitive ones, or all); "–" where the person has no grant path to it
    sens_objs = sorted({o["object_fqn"] for p in by_person for o in p["objects"] if heat == "all" or o["sensitive"]},
                       key=lambda f: -sum(o["off_hours"] for p in by_person for o in p["objects"] if o["object_fqn"] == f))[:10]
    try:
        g = explorer._load(None)
    except HTTPException:
        g = None
    readers: dict = {}
    for f in sens_objs:
        if g is not None and g["holders"].get(f):
            roles = [r for r, priv, on, _ in g["holders"][f] if explorer.priv_class(priv, on) in ("read", "own")]
            readers[f] = {h["name"] for h in explorer._holders_of(g, roles, identity.masking_enabled()) if h["kind"] == "user"}
    heat_rows = [{"user_name": p["user_name"], "cells": [
        next((o["off_hours"] for o in p["objects"] if o["object_fqn"] == f), 0 if (f not in readers or p["user_name"] in readers[f]) else None)
        for f in sens_objs]} for p in by_person]
    all_where = (f"FROM {LOG} WHERE bucket_start >= ? AND bucket_start < ?", [start, end])
    profile = _hours_or_none(
        f"SELECT user_name, CAST(hour(CAST(usage_date AS TIMESTAMP) + to_hours(CAST(hour_utc AS BIGINT) + ?)) AS INT) AS h, "
        f"SUM(queries) FILTER (WHERE {off_sql}) AS off, SUM(queries) FILTER (WHERE NOT {off_sql}) AS on_hours "
        f"FROM {HOURS} WHERE user_name IS NOT NULL AND usage_date >= ? AND usage_date < ? GROUP BY 1, 2",
        [offset, *off_params, *off_params, start, end])
    hours: dict = {}
    for r in profile or []:
        u = hours.setdefault(r["user_name"], {"user_name": _who(r["user_name"]), "on": [0] * 24, "off": [0] * 24})
        u["on"][r["h"]] += r["on_hours"] or 0
        u["off"][r["h"]] += r["off"] or 0
    for u in hours.values():
        tot = sum(u["on"]) + sum(u["off"])
        u["off_share"] = round(sum(u["off"]) / tot, 3) if tot else None
    return {"window": window, "start": start, "end": end, "offset": offset, "start_hour": start_hour, "end_hour": end_hour,
            "settings": cfg, "objects": top["objects"] or 0, "users": top["users"] or 0, "queries": top["queries"] or 0,
            "busiest": busiest[0] if busiest else None, "hours_available": hrs is not None,
            "people_off_hours": len(by_person), "objects_off_hours": len({o["object_fqn"] for p in by_person for o in p["objects"]}),
            "off_hours": by_person, "heat_objects": sens_objs, "heat": heat_rows, "heat_kind": heat,
            "by": _by(*all_where), "statements": _statements(*all_where),
            "hours": sorted(hours.values(), key=lambda u: -(u["off_share"] or 0)), **_cut()}


@router.get("/api/access/log")
def get_log(object: str, window: int = 30, split: str = "user", offset: int | None = None) -> dict:
    start, end = _range(window)
    where = f"FROM {LOG} WHERE object_fqn = ? AND bucket_start >= ? AND bucket_start < ?"
    params = [object, start, end]
    tiles = _log_or_503(
        f"SELECT SUM(read_queries) AS reads, SUM(write_queries) AS writes, SUM(ddl_queries) AS ddl, "
        f"COUNT(DISTINCT user_name) AS users, COUNT(DISTINCT role_name) AS roles, COUNT(DISTINCT client) AS clients, "
        f"COUNT(DISTINCT statement_type) AS statements, {_merged('ddl_operations')} AS ddl_operations, "
        f"array_to_string(list_sort(list(DISTINCT client)), ', ') AS client_list {where}", params)[0]
    by = _by(where, params)
    statements = _statements(where, params)
    matrix = _log_or_503(f"SELECT role_name AS r, client AS c, SUM({Q}) AS q {where} GROUP BY 1, 2", params)
    days = _log_or_503(
        f"SELECT CAST(bucket_start AS DATE) AS d, SUM(write_queries) AS writes, SUM(read_queries) AS reads, "
        f"SUM(ddl_queries) AS ddl {where} GROUP BY 1 ORDER BY 1", params)
    who = _log_or_503(
        f"SELECT user_name, MAX(user_type) AS user_type, BOOL_OR(is_person) AS is_person, role_name, client, "
        f"array_to_string(list_sort(list(DISTINCT statement_type)), ', ') AS statements, SUM(read_queries) AS reads, "
        f"SUM(write_queries) AS writes, SUM(ddl_queries) AS ddl, COUNT(DISTINCT CAST(bucket_start AS DATE)) AS days, "
        f"MIN(first_at) AS first_at, MAX(last_at) AS last_at, {_merged('ddl_operations')} AS ddl_operations, "
        f"array_to_string(list_sort(list(DISTINCT via) FILTER (WHERE via IS NOT NULL)), ', ') AS via "
        f"{where} GROUP BY user_name, role_name, client ORDER BY reads + writes + ddl DESC", params)
    cfg = hours_settings()
    off_sql, off_params = _off(cfg["offset"] if offset is None else offset, cfg["start"], cfg["end"])
    off = _hours_or_none(f"SELECT user_name, role_name, client, SUM(queries) AS q FROM {HOURS} WHERE object_fqn = ? "
                         f"AND usage_date >= ? AND usage_date < ? AND {off_sql} GROUP BY 1, 2, 3", [*params, *off_params])
    offmap = {(r["user_name"], r["role_name"], r["client"]): r["q"] for r in off or []}
    for w in who:
        w["off_hours"] = offmap.get((w["user_name"], w["role_name"], w["client"]), 0) if w["is_person"] and off is not None else None
        w["user_name"] = _who(w["user_name"])
    # a procedure: what its queries read and wrote (they carry it as via)
    did = _log_or_503(
        f"SELECT object_fqn, MAX(object_domain) AS object_domain, SUM(read_queries) AS reads, SUM(write_queries) AS writes, "
        f"SUM(ddl_queries) AS ddl, array_to_string(list_sort(list(DISTINCT statement_type)), ', ') AS statements, "
        f"array_to_string(list_sort(list(DISTINCT role_name)), ', ') AS roles, MAX(last_at) AS last_at FROM {LOG} "
        f"WHERE via = ? AND bucket_start >= ? AND bucket_start < ? GROUP BY 1 ORDER BY writes DESC, reads DESC",
        [f"procedure {object}", start, end])
    kind = _log_or_503(f"SELECT MAX(object_domain) AS d {where}", params)[0]["d"]
    return {"object": object, "kind": kind, "did": did, "window": window, "start": start, "end": end, "sensitive": _sensitive().get(object),
            "tiles": tiles, "by": by, "statements": statements, "matrix": matrix, "days": days, "who": who,
            "per_day": _series(where, params, split), **_cut()}


@router.get("/api/access/rollup")
def get_rollup(window: int = 30, level: str = "schema") -> dict:
    """Every object's activity rolled up to its schema or database: objects of each kind, reads, writes, DDL."""
    start, end = _range(window)
    key = "database_name" if level == "database" else "database_name || '.' || schema_name"
    kinds = ", ".join(f"COUNT(DISTINCT object_fqn) FILTER (WHERE object_domain IN {v}) AS {k}s" for k, v in KINDS.items())
    rows = _log_or_503(
        f"SELECT {key} AS k, COUNT(DISTINCT object_fqn) AS objects, {kinds}, SUM(read_queries) AS reads, "
        f"SUM(write_queries) AS writes, SUM(ddl_queries) AS ddl, COUNT(DISTINCT user_name) AS users, "
        f"COUNT(DISTINCT client) AS clients, COUNT(DISTINCT via) AS vias, MAX(last_at) AS last_at FROM {LOG} "
        f"WHERE bucket_start >= ? AND bucket_start < ? AND schema_name IS NOT NULL AND schema_name <> '' "
        f"GROUP BY 1 ORDER BY reads + writes + ddl DESC", [start, end])
    sens = _sensitive()
    for r in rows:
        r["sensitive_objects"] = sum(1 for f in sens if f == r["k"] or f.startswith(f"{r['k']}."))
    return {"window": window, "start": start, "end": end, "level": "database" if level == "database" else "schema",
            "kinds": list(KINDS), "rows": rows}


@router.get("/api/access/apps")
def get_apps(window: int = 30, app: str = "") -> dict:
    """Streamlit apps: who they are shared with, who can open them, who opened them (when, from where), what
    they ran as, and what they read. Opens are the viewer's own query; the app's queries run as its owner."""
    start, end = _range(window)
    try:
        apps = _rows(f"SELECT app_name, COUNT(DISTINCT user_name) FILTER (WHERE kind = 'open') AS users, "
                     f"SUM(queries) FILTER (WHERE kind = 'open') AS runs, SUM(queries) FILTER (WHERE kind = 'app_query') AS queries, "
                     f"COUNT(DISTINCT usage_date) FILTER (WHERE kind = 'open') AS days, MAX(last_at) AS last_at FROM {APPS} "
                     f"WHERE app_name IS NOT NULL AND usage_date >= ? AND usage_date < ? GROUP BY 1 ORDER BY users DESC, runs DESC",
                     [start, end])
    except duckdb.Error:
        raise HTTPException(503, "No Streamlit app log in this export: run it again with sf_use_streamlit_access.")
    try:  # shared apps nobody opened in the window still list
        shared = [r["app_name"] for r in _rows(f"SELECT DISTINCT app_name FROM {SHARES}", [])]
    except duckdb.Error:
        shared = []
    for n in shared:
        if n not in {r["app_name"] for r in apps}:
            apps.append({"app_name": n, "users": 0, "runs": 0, "queries": 0, "days": 0, "last_at": None})
    name = app or (apps[0]["app_name"] if apps else "")
    if not name:
        return {"window": window, "start": start, "end": end, "apps": apps, "app": "", "who": [], "runs_as": [], "objects": [],
                "shares": None, "can_open": None}
    who = _rows(f"SELECT user_name, MAX(user_type) AS user_type, array_to_string(list_sort(list(DISTINCT role_name)), ', ') AS roles, "
                f"SUM(queries) AS runs, SUM(sessions) AS sessions, COUNT(DISTINCT usage_date) AS days, MIN(first_at) AS first_at, "
                f"MAX(last_at) AS last_at, {_merged('clients')} AS clients, {_merged('client_ips')} AS client_ips, "
                f"list(DISTINCT CAST(usage_date AS VARCHAR)) AS dates FROM {APPS} WHERE app_name = ? AND kind = 'open' "
                f"AND usage_date >= ? AND usage_date < ? GROUP BY 1 ORDER BY runs DESC", [name, start, end])
    for w in who:
        w["user_name"] = _who(w["user_name"])
        w["dates"] = sorted(w["dates"] or [])
    runs_as = _rows(f"SELECT user_name, role_name, SUM(queries) AS queries, MAX(last_at) AS last_at FROM {APPS} "
                    f"WHERE app_name = ? AND kind = 'app_query' AND usage_date >= ? AND usage_date < ? GROUP BY 1, 2", [name, start, end])
    for w in runs_as:
        w["user_name"] = _who(w["user_name"])
    try:
        shares = _rows(f"SELECT privilege, grantee_name, granted_to, granted_by, granted_at, revoked_at, status FROM {SHARES} "
                       f"WHERE app_name = ? ORDER BY granted_at DESC", [name])
    except duckdb.Error:
        shares = None
    can_open = None
    try:
        g = explorer._load(None)
        roles = [r for r, priv, on, _ in g["holders"].get(name, []) if priv in ("USAGE", "OWNERSHIP")]
        can_open = sorted({h["name"] for h in explorer._holders_of(g, roles, identity.masking_enabled()) if h["kind"] == "user"}) if roles else []
    except HTTPException:
        pass
    read = _log_or_503(
        f"SELECT object_fqn, MAX(object_domain) AS object_domain, SUM(read_queries) AS reads, SUM(write_queries) AS writes, "
        f"SUM(ddl_queries) AS ddl, COUNT(DISTINCT user_name) AS users, MAX(last_at) AS last_at FROM {LOG} WHERE via = ? "
        f"AND bucket_start >= ? AND bucket_start < ? GROUP BY 1 ORDER BY reads + writes + ddl DESC",
        [f"streamlit {name}", start, end])
    sens = _sensitive()
    for r in read:
        r["sensitive"] = sens.get(r["object_fqn"])
    return {"window": window, "start": start, "end": end, "apps": apps, "app": name, "who": who, "runs_as": runs_as,
            "shares": shares, "can_open": can_open, "objects": read}


@router.get("/api/access/people")
def get_people(window: int = 30) -> dict:
    start, end = _range(window)
    rows = _log_or_503(
        f"SELECT user_name, MAX(user_type) AS user_type, BOOL_OR(is_person) AS is_person, SUM({Q}) AS queries, "
        f"COUNT(DISTINCT object_fqn) AS objects FROM {LOG} WHERE user_name IS NOT NULL AND bucket_start >= ? "
        f"AND bucket_start < ? GROUP BY 1 ORDER BY queries DESC", [start, end])
    for r in rows:
        r["user_name"] = _who(r["user_name"])
    roles = _log_or_503(
        f"SELECT role_name, SUM({Q}) AS queries, COUNT(DISTINCT user_name) AS users, COUNT(DISTINCT object_fqn) AS objects "
        f"FROM {LOG} WHERE role_name IS NOT NULL AND bucket_start >= ? AND bucket_start < ? GROUP BY 1 ORDER BY queries DESC", [start, end])
    return {"window": window, "people": rows, "roles": roles}


@router.get("/api/access/person")
def get_person(user: str = "", role: str = "", window: int = 30, split: str = "object", offset: int | None = None) -> dict:
    """One user, or one role (every user's queries under it): what they touched, when and how."""
    start, end = _range(window)
    if not user and not role:
        raise HTTPException(422, "Give a user or a role.")
    real = _real_user(user) if user else role
    where = f"FROM {LOG} WHERE {'user_name' if user else 'role_name'} = ? AND bucket_start >= ? AND bucket_start < ?"
    params = [real, start, end]
    tiles = _log_or_503(
        f"SELECT SUM(read_queries) AS reads, SUM(write_queries) AS writes, SUM(ddl_queries) AS ddl, "
        f"COUNT(DISTINCT object_fqn) AS objects, COUNT(DISTINCT role_name) AS roles, COUNT(DISTINCT client) AS clients, "
        f"COUNT(DISTINCT user_name) AS users, array_to_string(list_sort(list(DISTINCT user_name)), ', ') AS user_list, "
        f"MAX(user_type) AS user_type, BOOL_OR(is_person) AS is_person, "
        f"array_to_string(list_sort(list(DISTINCT client)), ', ') AS client_list {where}", params)[0]
    objects = _log_or_503(
        f"SELECT object_fqn, MAX(object_domain) AS object_domain, SUM(read_queries) AS reads, SUM(write_queries) AS writes, "
        f"SUM(ddl_queries) AS ddl, array_to_string(list_sort(list(DISTINCT role_name)), ', ') AS roles, "
        f"array_to_string(list_sort(list(DISTINCT client)), ', ') AS clients, "
        f"array_to_string(list_sort(list(DISTINCT statement_type)), ', ') AS statements, "
        f"COUNT(DISTINCT CAST(bucket_start AS DATE)) AS days, MAX(last_at) AS last_at {where} GROUP BY 1 "
        f"ORDER BY reads + writes + ddl DESC", params)
    sens = _sensitive()
    for o in objects:
        o["sensitive"] = sens.get(o["object_fqn"])
    kinds = []
    for k, v in KINDS.items():
        r = _log_or_503(f"SELECT COUNT(DISTINCT object_fqn) AS objects, SUM(read_queries) AS reads, SUM(write_queries) AS writes, "
                        f"SUM(ddl_queries) AS ddl, MAX(last_at) AS last_at {where} AND object_domain IN {v}", params)[0]
        if r["objects"]:
            kinds.append({"kind": k, **r})
    apps = []
    if user:
        try:
            apps = _rows(f"SELECT app_name, SUM(queries) AS runs, COUNT(DISTINCT usage_date) AS days, MAX(last_at) AS last_at FROM {APPS} "
                         f"WHERE kind = 'open' AND user_name = ? AND usage_date >= ? AND usage_date < ? GROUP BY 1 ORDER BY runs DESC", params)
        except duckdb.Error:
            apps = []
    cfg = hours_settings()
    offset = cfg["offset"] if offset is None else offset
    off_sql, off_params = _off(offset, cfg["start"], cfg["end"])
    prof = _hours_or_none(
        f"SELECT CAST(hour(CAST(usage_date AS TIMESTAMP) + to_hours(CAST(hour_utc AS BIGINT) + ?)) AS INT) AS h, "
        f"SUM(queries) FILTER (WHERE {off_sql}) AS off, SUM(queries) FILTER (WHERE NOT {off_sql}) AS on_hours "
        f"FROM {HOURS} WHERE user_name = ? AND usage_date >= ? AND usage_date < ? GROUP BY 1",
        [offset, *off_params, *off_params, *params])
    hours = None
    if prof is not None and tiles["is_person"] and user:
        hours = {"on": [0] * 24, "off": [0] * 24}
        for r in prof:
            hours["on"][r["h"]] += r["on_hours"] or 0
            hours["off"][r["h"]] += r["off"] or 0
    if not user:
        tiles["user_list"] = ", ".join(_who(u) for u in str(tiles.get("user_list") or "").split(", ") if u)
    return {"user": _who(real) if user else None, "role": role or None, "window": window, "start": start, "end": end,
            "offset": offset, "tiles": tiles, "objects": objects, "kinds": kinds, "apps": apps, "hours": hours, "per_day": _series(where, params, split), **_cut()}


@router.get("/api/access/tags")
def get_tags() -> dict:
    try:
        rows = _rows(f"SELECT tag_fqn, tag_value, COUNT(*) AS objects, SUM(column_count) AS columns, "
                     f"LISTAGG(DISTINCT level, ', ') AS levels FROM {TAGS} GROUP BY 1, 2 ORDER BY 1, 2", [])
    except duckdb.Error:
        raise HTTPException(503, "No tag inventory in this export: run it again with sf_gov_tag_objects.")
    return {"tags": rows}


@router.get("/api/access/tag")
def get_tag(tag: str, value: str | None = None, window: int = 30) -> dict:
    try:
        objs = _rows(f"SELECT tag_value, level, database_name, schema_name, table_name, columns, column_count, "
                     f"apply_method FROM {TAGS} WHERE tag_fqn = ? AND (? IS NULL OR tag_value = ?) "
                     f"ORDER BY database_name, schema_name, table_name", [tag, value, value])
    except duckdb.Error:
        raise HTTPException(503, "No tag inventory in this export: run it again with sf_gov_tag_objects.")
    start, end = _range(window)
    try:
        g = explorer._load(None)
    except HTTPException:
        g = None
    mask = identity.masking_enabled()
    for o in objs:
        o["object"] = ".".join(p for p in (o["database_name"], o["schema_name"], o["table_name"]) if p)
    # a database or schema row stands for every table in it, matched by prefix; a table or column row exactly
    exact = {}
    for o in objs:
        exact[o["object"]] = exact.get(o["object"], False) or o["level"] in ("TABLE", "COLUMN")
    used: dict | None = {}
    if exact:
        try:  # one scan for every object
            for u in _rows(
                    f"SELECT o.prefix, l.user_name, l.role_name, SUM(l.read_queries) AS reads, "
                    f"SUM(l.write_queries) AS writes FROM {LOG} l "
                    f"JOIN (SELECT UNNEST(?::VARCHAR[]) AS prefix, UNNEST(?::BOOLEAN[]) AS exact) o "
                    f"ON l.object_fqn = o.prefix OR (NOT o.exact AND l.object_fqn LIKE o.prefix || '.%') "
                    f"WHERE l.bucket_start >= ? AND l.bucket_start < ? GROUP BY 1, 2, 3 ORDER BY 4 + 5 DESC",
                    [list(exact), list(exact.values()), start, end]):
                used.setdefault(u.pop("prefix"), []).append({**u, "user_name": _who(u["user_name"])})
        except duckdb.Error:
            used = None
    for o in objs:
        prefix = o["object"]
        o["queried_by"] = None if used is None else used.get(prefix, [])
        o["can_read"] = None
        if g is not None and o["level"] in ("TABLE", "COLUMN") and g["holders"].get(prefix):
            roles = [r for r, priv, on, _ in g["holders"][prefix] if explorer.priv_class(priv, on) in ("read", "own")]
            holders = explorer._holders_of(g, roles, mask) if roles else []
            o["can_read"] = sorted({h["name"] for h in holders if h["kind"] == "user"})
    return {"tag": tag, "value": value, "window": window, "start": start, "end": end, "objects": objs}
