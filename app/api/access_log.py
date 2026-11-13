"""app/api/access_log.py -- who touched an object, and the tag explorer.

Reads findings.f_sf_use_access_log (one row per object x user x role x client x day or hour), so a page
never loads the whole log.

    GET /api/access/log/objects?window=&search=&sensitive=   objects to pick from, busiest first
    GET /api/access/log?object=&window=                      one object: counts per bucket, and who
    GET /api/access/log/offhours?window=                     people using objects outside business hours
    GET /api/access/tags                                     tag values on databases, schemas, tables, columns
    GET /api/access/tag?tag=&value=&window=                  one tag: its objects, who can read them, who did
"""
from __future__ import annotations

from datetime import date, timedelta

import duckdb
from fastapi import APIRouter, HTTPException

from app.api import explorer
from app.core import data as app_core_data
from app.core import identity

router = APIRouter()

LOG = "findings.f_sf_use_access_log"
TAGS = "findings.f_sf_gov_tag_objects"
TAGGED = "findings.f_sf_gov_sensitive_columns_unprotected"
SUGGESTED = "findings.f_sf_gov_sensitive_suggestions"


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


def _log_or_503(sql: str, params: list) -> list[dict]:
    try:
        return _rows(sql, params)
    except duckdb.Error:
        raise HTTPException(503, "No access log in this export: run it again with sf_use_access_log.")


@router.get("/api/access/log/objects")
def get_objects(window: int = 30, search: str = "", sensitive: bool = False, limit: int = 200) -> dict:
    start, end = _range(window)
    rows = _log_or_503(
        f"SELECT object_fqn, MAX(object_domain) AS object_domain, SUM(read_queries) AS reads, "
        f"SUM(write_queries) AS writes, SUM(ddl_queries) AS ddl, COUNT(DISTINCT user_name) AS users, "
        f"COUNT(DISTINCT role_name) AS roles, MAX(last_at) AS last_at, MAX(grain) AS grain "
        f"FROM {LOG} WHERE object_fqn IS NOT NULL AND bucket_start >= ? AND bucket_start < ? "
        f"AND object_fqn ILIKE ? GROUP BY object_fqn ORDER BY reads + writes + ddl DESC, object_fqn",
        [start, end, f"%{search.strip()}%"])
    sens = _sensitive()
    for r in rows:
        r["sensitive"] = sens.get(r["object_fqn"])
    if sensitive:
        rows = [r for r in rows if r["sensitive"]]
    return {"window": window, "start": start, "end": end, "grain": rows[0]["grain"] if rows else None,
            "total": len(rows), "objects": rows[:max(1, min(limit, 2000))], **_cut()}


@router.get("/api/access/log")
def get_log(object: str, window: int = 30) -> dict:
    start, end = _range(window)
    where = f"FROM {LOG} WHERE object_fqn = ? AND bucket_start >= ? AND bucket_start < ?"
    buckets = _log_or_503(
        f"SELECT bucket_start AS bucket, SUM(read_queries) AS reads, SUM(write_queries) AS writes, "
        f"SUM(ddl_queries) AS ddl, COUNT(DISTINCT user_name) AS users {where} GROUP BY 1 ORDER BY 1",
        [object, start, end])
    who = _log_or_503(
        f"SELECT user_name, role_name, client, BOOL_OR(is_person) AS is_person, SUM(read_queries) AS reads, "
        f"SUM(write_queries) AS writes, SUM(off_hours_queries) AS off_hours, "
        f"SUM(ddl_queries) AS ddl, COUNT(DISTINCT bucket_start) AS buckets, MIN(first_at) AS first_at, "
        f"{_merged('statement_types')} AS statement_types, {_merged('ddl_operations')} AS ddl_operations, "
        f"MAX(last_at) AS last_at {where} GROUP BY 1, 2, 3 ORDER BY reads + writes + ddl DESC, 1, 2, 3",
        [object, start, end])
    for w in who:
        w["user_name"] = _who(w["user_name"])
    grain = _log_or_503(f"SELECT MAX(grain) AS g FROM {LOG}", [])[0]["g"]
    return {"object": object, "window": window, "start": start, "end": end, "grain": grain,
            "sensitive": _sensitive().get(object), "buckets": buckets, "who": who, **_cut()}


@router.get("/api/access/log/offhours")
def get_offhours(window: int = 30) -> dict:
    start, end = _range(window)
    rows = _log_or_503(
        f"SELECT user_name, object_fqn, MAX(object_domain) AS object_domain, "
        f"array_to_string(list_sort(list(DISTINCT role_name)), ', ') AS roles, SUM(off_hours_queries) AS off_hours, "
        f"SUM(read_queries) AS reads, SUM(write_queries) AS writes, SUM(ddl_queries) AS ddl, "
        f"{_merged('statement_types')} AS statement_types, {_merged('ddl_operations')} AS ddl_operations, "
        f"MAX(last_at) AS last_at FROM {LOG} WHERE is_person AND off_hours_queries > 0 "
        f"AND bucket_start >= ? AND bucket_start < ? GROUP BY 1, 2", [start, end])
    sens = _sensitive()
    for r in rows:
        r["sensitive"] = sens.get(r["object_fqn"])
        r["user_name"] = _who(r["user_name"])
    # sensitive objects first, then changes (DDL, writes) before reads, then the most off-hours queries
    rows.sort(key=lambda r: (r["sensitive"] is None, not ((r["ddl"] or 0) + (r["writes"] or 0)), -(r["off_hours"] or 0)))
    return {"window": window, "start": start, "end": end, "rows": rows,
            "users": len({r["user_name"] for r in rows}), "objects": len({r["object_fqn"] for r in rows}), **_cut()}


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
