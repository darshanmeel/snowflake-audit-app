#!/usr/bin/env python3
"""Run the Snowflake checks (app/queries) against SNOWFLAKE.ACCOUNT_USAGE and write a results
folder (findings/, dims/, manifest.json, report.md) that tools/load_results.py loads.

    python tools/export_results.py --out DIR [--windows 30] [--credit-price 3.0]
    python tools/export_results.py --out DIR --windows 7 --validate    # LIMIT 0 on every check
    python tools/load_results.py DIR --db PATH
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import re
import shutil
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import pyarrow as pa
import pyarrow.compute as pc
import pyarrow.parquet as pq

ROOT = Path(__file__).resolve().parent.parent
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from app.core import config as app_config  # noqa: E402
from app.core import datasource  # noqa: E402
from app.core import masking as app_masking  # noqa: E402
from app.core import reasons as app_reasons  # noqa: E402
from app.core import registry as app_registry  # noqa: E402
from tools.common import (  # noqa: E402
    DEFAULT_MAX_ROWS,
    blank_unflagged_waste,
    git_commit,
    window_aliases_map,
    window_plan,
    window_sources,
)

TOOL_VERSION = "0.1.0"
SQL_DIR = ROOT / "app" / "queries"
DOTENV_PATH = ROOT / ".env"
ENV_VARS = (
    "SNOWFLAKE_ACCOUNT", "SNOWFLAKE_USER", "SNOWFLAKE_PASSWORD", "SNOWFLAKE_AUTHENTICATOR",
    "SNOWFLAKE_PRIVATE_KEY_FILE", "SNOWFLAKE_PRIVATE_KEY_PASSPHRASE", "SNOWFLAKE_ROLE",
    "SNOWFLAKE_WAREHOUSE",
)
DAYS_PER_MONTH = 30.4
# One runaway statement must not block every check after it (and keep a warehouse running): a session cap.
DEFAULT_STATEMENT_TIMEOUT_S = 900
DEFAULT_WORKERS = 4

_HEADER_RE = re.compile(r"^--\s*([a-z_]+)\s*:\s*(.*)$")
_PARAM_RE = re.compile(r"(?<![:\w]):([a-z_][a-z0-9_]*)")
_INCLUDE_RE = re.compile(r"__INCLUDE_([a-z0-9_]+)__")
_COMMENT_RE = re.compile(r"--[^\n]*|/\*.*?\*/", re.S)
_READ_ONLY_RE = re.compile(r"^\s*(SELECT|WITH|SHOW)\b", re.I)


class ExportConfigError(RuntimeError):
    """A whole-run problem, reported before any query runs."""


class ExportConnectionError(RuntimeError):
    """Sign-in or session setup failed: `str()` is the one line to print (error code, then the fix)."""


# ------------------------------------------------------------------------------------------
# Loading and rendering the SQL
# ------------------------------------------------------------------------------------------


def parse_header(text: str) -> dict[str, str]:
    """The leading `-- key: value` lines of a check file."""
    fields: dict[str, str] = {}
    key = None
    for line in text.splitlines():
        if not line.startswith("--"):
            break
        m = _HEADER_RE.match(line)
        if m and not line.startswith("--   "):
            key = m.group(1)
            fields[key] = m.group(2).strip()
        elif key and line.startswith("--   "):
            # A continuation line ("--   ...") belongs to the field above it.
            fields[key] = (fields[key] + " " + line[2:].strip()).strip()
    return fields


def load_checks(sql_dir: Path = SQL_DIR) -> dict[str, str]:
    """{query_id: sql text} for every checks/*.sql file."""
    out = {}
    for path in sorted((sql_dir / "checks").glob("*.sql")):
        text = path.read_text(encoding="utf-8")
        qid = parse_header(text).get("query_id")
        if qid != path.stem:
            raise ExportConfigError(f"{path.name}: header query_id {qid!r} must match the file name")
        out[qid] = text
    return out


def load_fallbacks(sql_dir: Path = SQL_DIR) -> dict[str, str]:
    """{query_id: sql text} for every fallback/*.sql file: the same check read from INFORMATION_SCHEMA,
    run when the role cannot read the check's ACCOUNT_USAGE views. Same columns as the check. A file
    with `-- shim: yes` is the check's own SQL with its views swapped for shims (expand_shims)."""
    out = {}
    for p in sorted((sql_dir / "fallback").glob("*.sql")):
        text = p.read_text(encoding="utf-8")
        out[p.stem] = expand_shims(p.stem, text, sql_dir) if parse_header(text).get("shim") == "yes" else text
    return out


# A string literal, a comment, or an ACCOUNT_USAGE view: only the view is swapped.
_VIEW_TOKEN_RE = re.compile(r"'(?:[^']|'')*'|--[^\n]*|/\*.*?\*/|\bSNOWFLAKE\.ACCOUNT_USAGE\.([A-Z_]+)\b", re.S | re.I)
SHIM_RANGES = {
    # The oldest day the 6-month table functions accept, and the 14-day ones.
    "__SHIM_6_MONTHS__": "DATEADD(day, 1, DATEADD(month, -6, CURRENT_DATE()))",
    "__SHIM_14_DAYS__": "DATEADD(day, -14, CURRENT_DATE())",
}


def load_shims(sql_dir: Path = SQL_DIR) -> dict[str, tuple[dict, str]]:
    """{VIEW: (header, body)} for every shims/*.sql file: an ACCOUNT_USAGE view rebuilt from
    INFORMATION_SCHEMA table functions, with the view's columns (NULL where the function has none)."""
    out = {}
    for p in sorted((sql_dir / "shims").glob("*.sql")):
        text = p.read_text(encoding="utf-8")
        body = "\n".join(line for line in text.splitlines() if not line.lstrip().startswith("--")).strip()
        for key, value in SHIM_RANGES.items():
            body = body.replace(key, value)
        out[p.stem.upper()] = (parse_header(text), body)
    return out


def expand_shims(qid: str, stub: str, sql_dir: Path = SQL_DIR) -> str:
    """The check's own SQL, includes pasted in, with each ACCOUNT_USAGE view replaced by __SHIM_<VIEW>__:
    the result of that shim, which the export runs once before the checks (run_shims). The header gets
    the shims' names, reads, needs and notes, and the check's pre-steps."""
    shims = load_shims(sql_dir)
    check = (sql_dir / "checks" / f"{qid}.sql").read_text(encoding="utf-8")
    lines = check.splitlines()
    start = 0
    while start < len(lines) and (lines[start].startswith("--") or not lines[start].strip()):
        start += 1  # the check's header; the fallback gets its own
    body = _INCLUDE_RE.sub(lambda m: (sql_dir / "common" / f"{m.group(1)}.sql").read_text(encoding="utf-8").strip(),
                           "\n".join(lines[start:]))
    used: list[str] = []

    def swap(m):
        view = m.group(1)
        if not view:
            return m.group(0)
        if view.upper() not in shims:
            raise ExportConfigError(f"fallback/{qid}.sql: no shim for ACCOUNT_USAGE.{view.upper()}")
        if view.upper() not in used:
            used.append(view.upper())
        return f"__SHIM_{view.upper()}__"

    body = _VIEW_TOKEN_RE.sub(swap, body)
    heads = [shims[v][0] for v in used]
    stub_head = parse_header(stub)
    notes = [h.get("note") for h in heads if h.get("note")] + ([stub_head["fallback_note"]] if stub_head.get("fallback_note") else [])
    lines = [f"-- query_id: {qid}",
             "-- shims: " + ", ".join(used),
             "-- reads: INFORMATION_SCHEMA table functions " + ", ".join(dict.fromkeys(
                 fn.strip() for h in heads
                 for fn in re.sub(r"INFORMATION_SCHEMA\.|\(table functions?\)", "", h.get("reads", "")).split(","))),
             "-- fallback_note: " + "; ".join(notes)]
    if any("MONITOR USAGE" in h.get("needs", "") for h in heads):
        lines.append("-- needs: MONITOR USAGE")
    if app_registry.by_id(qid).pre:
        lines.append("-- pre: " + "; ".join(app_registry.by_id(qid).pre))
    return "\n".join(lines) + "\n" + body.strip() + "\n"


_SHIM_TOKEN_RE = re.compile(r"__SHIM_([A-Z_]+)__")


def shims_in(text: str) -> list[str]:
    """The shims a fallback reads."""
    return sorted(set(_SHIM_TOKEN_RE.findall(text)))


def uses_query_feed(text: str) -> bool:
    """Whether a fallback reads the shared INFORMATION_SCHEMA query feed, directly or through its shim."""
    return any(t in text for t in ("__INCLUDE_is_query_history__", "__IS_QUERY_HISTORY_SCANS__",
                                   "__SHIM_QUERY_HISTORY__"))


def info_schema_db(cur) -> str | None:
    """A database whose INFORMATION_SCHEMA the role can call table functions from: the session's own,
    else the first one SHOW DATABASES lists outside SNOWFLAKE (which needs IMPORTED PRIVILEGES)."""
    try:
        cur.execute("SELECT CURRENT_DATABASE()")
        current = cur.fetchone()[0]
        if current:
            return current
        cur.execute("SHOW TERSE DATABASES")
        names = [r[1] for r in cur.fetchall()]
    except Exception:  # noqa: BLE001 -- no database to use means no fallback, never a failed export
        return None
    return next((n for n in names if n.upper() != "SNOWFLAKE"), names[0] if names else None)


def has_monitor_usage(cur, ctx: dict) -> bool:
    """Whether the role sees account-wide usage in INFORMATION_SCHEMA (ACCOUNTADMIN or MONITOR USAGE).
    Every database has a storage row a day, and the table function returns none without the grant."""
    info = '"' + str(ctx.get("info_schema_db") or "").replace('"', '""') + '".INFORMATION_SCHEMA'
    try:
        cur.execute(f"SELECT COUNT(*) FROM TABLE({info}.DATABASE_STORAGE_USAGE_HISTORY("
                    f"DATE_RANGE_START => DATEADD(day, -3, CURRENT_DATE())))")
        return bool(cur.fetchone()[0])
    except Exception:  # noqa: BLE001 -- unreadable reads as no grant, never a failed export
        return False


def account_privileges(cur) -> set[str]:
    """The account-level privileges of the roles in this session, or {"ACCOUNTADMIN"} when it is one of
    them. MANAGE GRANTS is what lets SHOW list every user, role, grant and policy."""
    try:
        cur.execute("SELECT f.value::STRING FROM TABLE(FLATTEN(PARSE_JSON(CURRENT_AVAILABLE_ROLES()))) f "
                    "WHERE IS_ROLE_IN_SESSION(f.value::STRING)")
        roles = [r[0] for r in cur.fetchall()]
    except Exception:  # noqa: BLE001 -- unreadable reads as no privileges, never a failed export
        return set()
    if "ACCOUNTADMIN" in roles:
        return {"ACCOUNTADMIN"}
    privileges = {"MANAGE GRANTS"} if "SECURITYADMIN" in roles else set()
    # SHOW GRANTS ON ACCOUNT is quick; SHOW GRANTS TO ROLE can take a minute on a role with many grants.
    rows = show_rows(cur, ["SHOW GRANTS ON ACCOUNT"], "account privileges")[0] or []
    return privileges | {str(r.get("privilege")).upper() for r in rows
                         if str(r.get("granted_to")).upper() == "ROLE" and r.get("grantee_name") in roles}


def fallback_blocked(head: dict, ctx: dict) -> str | None:
    """Why a fallback cannot give a true answer for this role, or None. A table function that needs
    MONITOR USAGE returns no rows without it, and SHOW without MANAGE GRANTS lists only the objects the
    role holds a privilege on; either would read as "nothing found"."""
    needs = [n.strip().upper() for n in head.get("needs", "").split(",") if n.strip()]
    privileges = ctx.get("account_privileges") or set()
    missing = [n for n in needs if "ACCOUNTADMIN" not in privileges and not (
        ctx.get("monitor_usage") if n == "MONITOR USAGE" else n in privileges)]
    if missing:
        return (f"role_cannot_see: the INFORMATION_SCHEMA fallback ({head.get('reads')}) needs ACCOUNTADMIN "
                f"or the {' and '.join(missing)} privilege{'s' if len(missing) > 1 else ''}, and without it "
                f"returns only part or nothing")
    return None


def load_dims(sql_dir: Path = SQL_DIR) -> dict[str, str]:
    return {p.stem: p.read_text(encoding="utf-8") for p in sorted((sql_dir / "dims").glob("*.sql"))}


def load_tag_sources(sql_dir: Path = SQL_DIR) -> dict[str, str]:
    """{name: sql text} for every tag_sources/*.sql file: the raw tag and cost aggregates the loader
    turns into the tags tables (tools/build_tags.py)."""
    return {p.stem: p.read_text(encoding="utf-8") for p in sorted((sql_dir / "tag_sources").glob("*.sql"))}


def params_for(qid: str, thresholds: dict) -> dict:
    """The check's header defaults (period_days aside), overridden by config/thresholds.yml."""
    values = {k: v for k, v in app_registry.by_id(qid).param_defaults().items() if k != "period_days"}
    for name in list(values):
        override = (thresholds.get(qid) or {}).get(name, (thresholds.get("_all") or {}).get(name))
        if override is not None:
            values[name] = override
    return values


def _literal(value) -> str:
    if value is None:
        return "CAST(NULL AS DOUBLE)"
    if isinstance(value, bool):
        return "TRUE" if value else "FALSE"
    if isinstance(value, (int, float)):
        return repr(value)
    return "'" + str(value).replace("'", "''") + "'"


QUERY_FEED_SCANS = "__IS_QUERY_HISTORY_SCANS__"
QUERY_FEED_SLICES = 28  # six-hour slices over the 7 days QUERY_HISTORY keeps


RUN_ALL_IN_FLIGHT = 40  # statements one session keeps running at once


def run_all(cur, sqls: list[str], label: str) -> list[tuple[str | None, str | None]]:
    """Run the statements at once (async on a live session, at most RUN_ALL_IN_FLIGHT running), each
    under the session's statement timeout. Returns (query id, None) or (None, error) per statement, in
    order. Rows are not fetched: they stay in Snowflake's result cache for RESULT_SCAN."""
    out: list[tuple[str | None, str | None]] = []
    if not hasattr(cur, "execute_async"):
        for sql in sqls:
            try:
                cur.execute(sql)
                out.append((cur.sfqid, None))
            except Exception as exc:  # noqa: BLE001 -- one statement failing drops only its own part
                out.append((None, _short(exc, 200)))
        return out
    conn = cur.connection
    done: dict[int, tuple[str | None, str | None]] = {}
    running: dict[int, str] = {}
    nxt = 0
    last_report = time.monotonic()
    while len(done) < len(sqls):
        while nxt < len(sqls) and len(running) < RUN_ALL_IN_FLIGHT:
            try:
                cur.execute_async(sqls[nxt])
                running[nxt] = cur.sfqid
            except Exception as exc:  # noqa: BLE001 -- e.g. a compile error on submit
                done[nxt] = (None, _short(exc, 200))
            nxt += 1
        for i, sfqid in list(running.items()):
            try:
                if not conn.is_still_running(conn.get_query_status_throw_if_error(sfqid)):
                    done[i] = (sfqid, None)
                    del running[i]
            except Exception as exc:  # noqa: BLE001 -- one statement failing drops only its own part
                done[i] = (None, _short(exc, 200))
                del running[i]
        if len(done) < len(sqls):
            if time.monotonic() - last_report > 10:
                print(f"{label}: {len(done)} of {len(sqls)} done", flush=True)
                last_report = time.monotonic()
            time.sleep(0.5 if len(sqls) > 1 else 1)
    return [done[i] for i in range(len(sqls))]


def _ident(name: str) -> str:
    return '"' + str(name).replace('"', '""') + '"'


def show_rows(cur, sqls: list[str], label: str) -> list[list[dict] | None]:
    """Run SHOW statements at once and fetch their rows as {column: value}; None for one that failed."""
    out: list[list[dict] | None] = []
    for sql, (sfqid, _err) in zip(sqls, run_all(cur, sqls, label)):
        if not sfqid:
            out.append(None)
            continue
        try:
            if hasattr(cur, "get_results_from_sfqid") and hasattr(cur, "execute_async"):
                cur.get_results_from_sfqid(sfqid)
            else:
                cur.execute(sql)
            rows = cur.fetchall()
            names = [c[0] for c in cur.description]  # set only once the rows are fetched
            out.append([dict(zip(names, row)) for row in rows])
        except Exception:  # noqa: BLE001 -- unreadable reads as not listed
            out.append(None)
    return out


# What one call of an `each:` shim is made for, listed with SHOW.
SHIM_ITEM_KINDS = {"database": "database", "warehouse": "warehouse", "role": "role",
                   "database_role": "database role", "policy": "policy"}
_POLICY_KINDS = ("MASKING", "ROW ACCESS", "PROJECTION", "AGGREGATION")


def shim_items(cur, kind: str, ctx: dict) -> list[tuple[str, ...]]:
    """The objects an `each:` shim makes one call for, as name parts: the role's own databases (not
    shared or application ones), its warehouses, account roles, database roles, or data policies."""
    cache = ctx.setdefault("shim_items", {})
    if kind in cache:
        return cache[kind]
    if kind == "database":
        rows = show_rows(cur, ["SHOW TERSE DATABASES"], "databases")[0] or []
        items = [(r["name"],) for r in rows if str(r.get("kind") or "").upper() == "STANDARD"]
    elif kind == "warehouse":
        items = [(r["name"],) for r in show_rows(cur, ["SHOW WAREHOUSES"], "warehouses")[0] or []]
    elif kind == "role":
        items = [(r["name"],) for r in show_rows(cur, ["SHOW ROLES"], "roles")[0] or []]
    elif kind == "database_role":
        dbs = shim_items(cur, "database", ctx)
        lists = show_rows(cur, [f"SHOW DATABASE ROLES IN DATABASE {_ident(db)}" for (db,) in dbs], "database roles")
        items = [(db, r["name"]) for (db,), rows in zip(dbs, lists) for r in rows or []]
    elif kind == "policy":
        lists = show_rows(cur, [f"SHOW {k} POLICIES IN ACCOUNT" for k in _POLICY_KINDS], "policies")
        items = [(r["database_name"], r["schema_name"], r["name"]) for rows in lists for r in rows or []]
    else:
        raise ValueError(f"unknown shim item kind {kind!r}")
    cache[kind] = items
    return items


def _item_sql(text: str, kind: str, parts: tuple[str, ...]) -> str:
    """A shim's statement for one object: its quoted name, name as a string, and SHOW keyword."""
    ident = ".".join(_ident(p) for p in parts)
    return (text.replace("__ITEM_LITERAL__", _literal(ident)).replace("__ITEM_NAME__", _literal(parts[-1]))
            .replace("__ITEM_DB__", _literal(parts[0])).replace("__ITEM_KIND__", kind.upper().replace("_", " "))
            .replace("__ITEM__", ident))


def _empty_sql(columns: str) -> str:
    """A typed empty result from a shim's `columns:` header ("NAME TYPE, ...")."""
    cols = re.findall(r"([A-Za-z0-9_]+) ([A-Za-z_]+(?:\(\d+(?:,\s*\d+)?\))?)", columns)
    return "SELECT " + ", ".join(f'CAST(NULL AS {t}) AS "{n}"' for n, t in cols) + " WHERE FALSE"


SHIM_SHOW_CHUNK = 50  # reads of SHOW results joined into one statement
SHIM_UNION_CHUNK = 100  # results joined per statement when one shim ran in parts


def run_query_feed(cur, ctx: dict, sql_dir: Path = SQL_DIR) -> None:
    """Read the fallbacks' INFORMATION_SCHEMA query history once, as 28 six-hour slices run at once, and
    keep their query ids in ctx, so each fallback check reads them with RESULT_SCAN. A slice that fails
    or times out drops only its six hours; the checks that read the feed say how many are missing."""
    started = time.monotonic()
    text = (sql_dir / "common" / "is_query_history_feed.sql").read_text(encoding="utf-8")
    # One fixed end for every slice; the oldest starts 5 minutes inside the 7-day limit when it runs.
    base = "'" + dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%d %H:%M:%S") + "'::TIMESTAMP_LTZ"
    sqls = []
    for i in range(QUERY_FEED_SLICES):
        start = f"DATEADD(hour, -{6 * (i + 1)}, {base})"
        if i == QUERY_FEED_SLICES - 1:
            start = f"GREATEST({start}, DATEADD(minute, -10075, CURRENT_TIMESTAMP()))"
        end = base if i == 0 else f"DATEADD(hour, -{6 * i}, {base})"
        sql = render(text.replace("__SLICE_START__", start).replace("__SLICE_END__", end),
                     days=7, params={}, ctx=ctx, sql_dir=sql_dir)
        assert_read_only(sql)
        sqls.append(sql)
    try:
        results = run_all(cur, sqls, "query history for the INFORMATION_SCHEMA fallbacks")
    except Exception as exc:  # noqa: BLE001 -- the fallback checks then read "role can't see" with this reason
        results = [(None, _short(exc, 200))] * QUERY_FEED_SLICES
    ids = [i for i, _ in results if i]
    errors = [e for _, e in results if e]
    ctx["query_feed_ids"] = ids
    ctx["query_feed_missing"] = len(errors)
    if errors:
        ctx["query_feed_error"] = errors[0]
        print(f"warning: {len(errors)} of {QUERY_FEED_SLICES} six-hour slices of the INFORMATION_SCHEMA query "
              f"history failed: {errors[0]}", file=sys.stderr)
    print(f"query history for the INFORMATION_SCHEMA fallbacks: {len(ids)} of {QUERY_FEED_SLICES} six-hour "
          f"slices, {time.monotonic() - started:.1f}s", flush=True)


def run_shims(cur, ctx: dict, views: list[str], sql_dir: Path = SQL_DIR) -> None:
    """Run each shim the fallbacks need once, all at once, and keep its query id in ctx["shim_ids"], so
    every fallback reads it instead of calling the table functions again. A shim with `each:` runs once
    per database, warehouse, role or policy (after its `show:` statement when it has one), and the parts
    are joined; a part that fails drops only that object, and ctx["shim_gaps"] says how many. A shim
    that needs a privilege the role lacks is not run; a failure is kept and named by each check."""
    shims = load_shims(sql_dir)
    for key in ("shim_ids", "shim_errors", "shim_gaps", "shim_sql"):
        ctx.setdefault(key, {})
    started = time.monotonic()
    plans: dict[str, tuple[dict, str, list]] = {}
    for view in views:
        head, body = shims[view]
        if fallback_blocked(head, ctx):
            continue
        try:
            items: list = [None]
            if head.get("each"):
                items = [(k, parts) for k in (x.strip() for x in head["each"].split(","))
                         for parts in shim_items(cur, k, ctx)]
            plans[view] = (head, body, items)
        except Exception as exc:  # noqa: BLE001 -- the listing failing reads as the role gap
            ctx["shim_errors"][view] = _short(exc, 200)
    if not plans:
        return
    # 1. The SHOW statements, all at once.
    show_jobs = [(view, i, _item_sql(head["show"], *item) if item else head["show"])
                 for view, (head, _b, items) in plans.items() if head.get("show") for i, item in enumerate(items)]
    for *_, sql in show_jobs:
        assert_read_only(sql)
    show_ids = dict(zip([(v, i) for v, i, _ in show_jobs],
                        run_all(cur, [s for *_, s in show_jobs], "SHOW for the INFORMATION_SCHEMA stand-ins")))
    # 2. The bodies: one statement per object, or one per chunk of SHOW reads.
    jobs: list[tuple[str, str, int]] = []
    failed: dict[str, list[str]] = {}
    lost: dict[str, int] = {}
    for view, (head, body, items) in plans.items():
        parts = []
        for i, item in enumerate(items):
            sql = _item_sql(body, *item) if item else body
            if head.get("show"):
                sfqid, err = show_ids[(view, i)]
                if not sfqid:
                    failed.setdefault(view, []).append(err or "failed")
                    lost[view] = lost.get(view, 0) + 1
                    continue
                sql = sql.replace("__SHOW__", f"TABLE(RESULT_SCAN({_literal(sfqid)}))")
            try:
                sql = render(sql, days=7, params={}, ctx=ctx, sql_dir=sql_dir)
                assert_read_only(sql)
            except Exception as exc:  # noqa: BLE001 -- e.g. the query feed it reads did not run
                failed.setdefault(view, []).append(_short(exc, 200))
                lost[view] = lost.get(view, 0) + 1
                continue
            parts.append(sql)
        if head.get("show"):
            jobs += [(view, " UNION ALL ".join(f"SELECT * FROM ({p})" for p in parts[k:k + SHIM_SHOW_CHUNK]),
                      len(parts[k:k + SHIM_SHOW_CHUNK])) for k in range(0, len(parts), SHIM_SHOW_CHUNK)]
        else:
            jobs += [(view, p, 1) for p in parts]
    results = run_all(cur, [sql for _, sql, _n in jobs], "INFORMATION_SCHEMA stand-ins for the fallbacks") if jobs else []
    ids: dict[str, list[str]] = {view: [] for view in plans}
    for (view, _sql, n), (sfqid, err) in zip(jobs, results):
        if sfqid:
            ids[view].append(sfqid)
        else:
            failed.setdefault(view, []).append(err or "failed")
            lost[view] = lost.get(view, 0) + n
    # 3. Join the parts of each shim, a hundred results a statement, until one is left.
    while any(len(v) > 1 for v in ids.values()):
        joins = [(view, " UNION ALL ".join(f"SELECT * FROM TABLE(RESULT_SCAN({_literal(i)}))"
                                             for i in v[k:k + SHIM_UNION_CHUNK]))
                 for view, v in ids.items() if len(v) > 1 for k in range(0, len(v), SHIM_UNION_CHUNK)]
        for view in {v for v, _ in joins}:
            ids[view] = []
        for (view, _sql), (sfqid, err) in zip(joins, run_all(cur, [s for _, s in joins], "joining the stand-ins")):
            if sfqid:
                ids[view].append(sfqid)
            else:
                ids[view] = [None]  # a join failing loses the whole shim
                failed.setdefault(view, []).append(err or "failed")
        for view in [v for v, x in ids.items() if None in x]:
            ids[view] = []
    for view, (head, _b, items) in plans.items():
        errs = failed.get(view) or []
        if ids[view]:
            ctx["shim_ids"][view] = ids[view][0]
            ctx["shim_sql"][view] = shim_rows_sql(cur, ids[view][0])
        elif items == [] and head.get("columns"):
            ctx["shim_ids"][view] = "empty"
            ctx["shim_sql"][view] = "(" + _empty_sql(head["columns"]) + ")"
        else:
            ctx["shim_errors"][view] = errs[0] if errs else "nothing to read"
            print(f"warning: the INFORMATION_SCHEMA stand-in for {view} failed: {ctx['shim_errors'][view]}",
                  file=sys.stderr)
            continue
        if lost.get(view) and head.get("each"):
            kinds = " or ".join(SHIM_ITEM_KINDS.get(k.strip(), k.strip()) for k in head["each"].split(","))
            ctx["shim_gaps"][view] = f"{lost[view]} of {len(items)} ({kinds}) could not be read: {errs[0]}"
    print(f"INFORMATION_SCHEMA stand-ins: {len(ctx['shim_ids'])} of {len(views)} ran, "
          f"{time.monotonic() - started:.1f}s", flush=True)


def shim_gap_note(text: str, ctx: dict) -> str | None:
    """The note a fallback adds when a shim it reads lost some of its parts."""
    gaps = [f"{v}: {ctx['shim_gaps'][v]}" for v in shims_in(text) if (ctx.get("shim_gaps") or {}).get(v)]
    return "; ".join(gaps) or None


SHIM_INLINE_ROWS = 5000
_SHIM_TYPES = {0: "NUMBER(38, {scale})", 1: "FLOAT", 2: "VARCHAR", 3: "DATE", 6: "TIMESTAMP_LTZ",
               7: "TIMESTAMP_LTZ", 8: "TIMESTAMP_LTZ", 13: "BOOLEAN"}


def _value_literal(value) -> str:
    if value is None:
        return "NULL"
    if isinstance(value, (dt.datetime, dt.date)):
        return "'" + value.isoformat() + "'"
    if isinstance(value, bool):
        return "TRUE" if value else "FALSE"
    if isinstance(value, (int, float)) or type(value).__name__ == "Decimal":
        return str(value)
    return "'" + str(value).replace("'", "''") + "'"


def shim_rows_sql(cur, sfqid: str) -> str:
    """How the checks read a shim's result: its rows as literal VALUES when it is small, else RESULT_SCAN.
    Snowflake aborts with an internal error (300010) when a statement reads table-function rows through
    a CTE used twice; literal rows avoid that."""
    scan = f"(SELECT * FROM TABLE(RESULT_SCAN({_literal(sfqid)})))"
    try:
        cur.execute(f"SELECT * FROM TABLE(RESULT_SCAN({_literal(sfqid)})) LIMIT {SHIM_INLINE_ROWS + 1}")
        rows = cur.fetchall()
        types = [_SHIM_TYPES[c.type_code].format(scale=c.scale or 0) for c in cur.description]
        names = [c.name for c in cur.description]
    except Exception:  # noqa: BLE001 -- an unknown type or a test cursor: read the result as is
        return scan
    if len(rows) > SHIM_INLINE_ROWS:
        return scan
    if not rows:
        return "(SELECT " + ", ".join(f'CAST(NULL AS {t}) AS "{n}"' for t, n in zip(types, names)) + " WHERE FALSE)"
    cols = ", ".join(f'CAST(column{i + 1} AS {t}) AS "{n}"' for i, (t, n) in enumerate(zip(types, names)))
    values = ", ".join("(" + ", ".join(_value_literal(v) for v in row) + ")" for row in rows)
    return f"(SELECT {cols} FROM VALUES {values})"


def query_feed_gap(ctx: dict) -> str | None:
    """The note a feed-reading fallback adds when some slices failed."""
    missing = ctx.get("query_feed_missing") or 0
    if not missing or not ctx.get("query_feed_ids"):
        return None
    return (f"{missing * 6} of the last 168 hours are missing (a six-hour slice of the query history "
            f"failed or timed out: {ctx.get('query_feed_error')})")


def render(text: str, *, days: int, params: dict, ctx: dict, sql_dir: Path = SQL_DIR) -> str:
    """Resolve includes, context placeholders and :params into one runnable statement."""
    def include(m):
        return (sql_dir / "common" / f"{m.group(1)}.sql").read_text(encoding="utf-8").strip()

    sql = _INCLUDE_RE.sub(include, text)
    values = dict(params, period_days=days)
    sql = _PARAM_RE.sub(lambda m: _literal(values[m.group(1)]) if m.group(1) in values else m.group(0), sql)
    replacements = {
        "__AS_OF_DATE__": f"CAST('{ctx['as_of_date']}' AS DATE)",
        "__ACCOUNT_ID__": _literal(ctx["account_id"]),
        "__CLOUD__": _literal(ctx["cloud"]),
        "__CREDIT_PRICE__": _literal(ctx.get("credit_price_usd")),
        "__AI_CREDIT_PRICE__": _literal(ctx.get("ai_credit_price_usd")),
        "__INFO_SCHEMA__": '"' + str(ctx.get("info_schema_db") or "").replace('"', '""') + '".INFORMATION_SCHEMA',
        "__STORAGE_PRICE_TB_MONTH__": _literal(ctx.get("storage_price_usd_tb_month")),
        "__QUERY_SOURCE__": _literal(app_config.query_source()),
        # Task health checks leave out Snowflake's own tasks (SNOWFLAKE database) unless this is on.
        "__WITH_SNOWFLAKE_TASKS__": _literal(bool(ctx.get("include_snowflake_tasks", False))),
    }
    for key, value in replacements.items():
        sql = sql.replace(key, value)
    if QUERY_FEED_SCANS in sql:
        # The fallback's shared query feed ran before the checks, in slices; read them all.
        if not ctx.get("query_feed_ids"):
            raise ExportConfigError("the INFORMATION_SCHEMA query history did not run: "
                                    + str(ctx.get("query_feed_error") or "not started"))
        sql = sql.replace(QUERY_FEED_SCANS, " UNION ALL ".join(
            f"SELECT * FROM TABLE(RESULT_SCAN({_literal(i)}))" for i in ctx["query_feed_ids"]))
    for view in shims_in(sql):
        # A shim ran once before the checks; read its result.
        if not (ctx.get("shim_ids") or {}).get(view):
            raise ExportConfigError(f"the INFORMATION_SCHEMA stand-in for {view} did not run: "
                                    + str((ctx.get("shim_errors") or {}).get(view) or "not started"))
        sql = sql.replace(f"__SHIM_{view}__", (ctx.get("shim_sql") or {}).get(view)
                          or f"(SELECT * FROM TABLE(RESULT_SCAN({_literal(ctx['shim_ids'][view])})))")
    leftover = _PARAM_RE.findall(_COMMENT_RE.sub("", sql))
    if leftover:
        raise ExportConfigError(f"unresolved parameter(s): {sorted(set(leftover))}")
    return sql.strip().rstrip(";")


def assert_read_only(sql: str) -> None:
    """Refuse anything but one SELECT/WITH/SHOW statement: the export must never write."""
    body = _COMMENT_RE.sub("", sql).strip().rstrip(";")
    unquoted = re.sub(r"'(?:[^']|'')*'", "''", body)
    if not _READ_ONLY_RE.match(body) or ";" in unquoted:
        raise ExportConfigError("refusing a statement that is not a single SELECT, WITH or SHOW")


# ------------------------------------------------------------------------------------------
# Talking to Snowflake
# ------------------------------------------------------------------------------------------


def _load_env() -> dict:
    env = {k: v for k, v in os.environ.items() if k in ENV_VARS}
    if DOTENV_PATH.exists():
        for raw in DOTENV_PATH.read_text(encoding="utf-8-sig").splitlines():
            key, sep, value = raw.strip().removeprefix("export ").partition("=")
            key = key.strip()
            if sep and key in ENV_VARS and not env.get(key):
                env[key] = value.strip().strip("'\"")
    missing = [k for k in ("SNOWFLAKE_ACCOUNT", "SNOWFLAKE_USER") if not env.get(k)]
    if missing:
        raise ExportConfigError("missing " + ", ".join(missing) + " (environment or .env)")
    return env


_statement_timeout_s = DEFAULT_STATEMENT_TIMEOUT_S


def connect(env: dict | None = None):
    """A connector session pinned to UTC and tagged, so its own queries are easy to find, with a
    per-statement timeout."""
    import snowflake.connector  # only needed for a live export

    env = env or _load_env()
    kwargs = {
        "account": env["SNOWFLAKE_ACCOUNT"], "user": env["SNOWFLAKE_USER"],
        "role": env.get("SNOWFLAKE_ROLE"), "warehouse": env.get("SNOWFLAKE_WAREHOUSE"),
        "session_parameters": {"TIMEZONE": "UTC", "QUERY_TAG": app_config.query_source(),
                               "STATEMENT_TIMEOUT_IN_SECONDS": int(_statement_timeout_s)},
        "application": "Crosshire",
    }
    if env.get("SNOWFLAKE_PRIVATE_KEY_FILE"):
        kwargs["private_key_file"] = env["SNOWFLAKE_PRIVATE_KEY_FILE"]
        if env.get("SNOWFLAKE_PRIVATE_KEY_PASSPHRASE"):
            kwargs["private_key_file_pwd"] = env["SNOWFLAKE_PRIVATE_KEY_PASSPHRASE"]
    elif env.get("SNOWFLAKE_PASSWORD"):
        kwargs["password"] = env["SNOWFLAKE_PASSWORD"]
    else:
        kwargs["authenticator"] = env.get("SNOWFLAKE_AUTHENTICATOR", "externalbrowser")
    return snowflake.connector.connect(**{k: v for k, v in kwargs.items() if v is not None})


# Columns the app reads in upper case; everything else is lower case.
UPPER_CASE_COLUMNS = {"access_grants_inventory": {"grantee": "GRANTEE"}}


def run_show(cur, sql: str) -> str | None:
    """Run a `-- pre:` SHOW so the check's RESULT_SCAN can read it, and return its query id. Never
    fetched: the connector refuses fetch_arrow_all on SHOW output, and the check reads it server side."""
    assert_read_only(sql)
    cur.execute(sql)
    return getattr(cur, "sfqid", None)


_LAST_QUERY_ID = re.compile(r"LAST_QUERY_ID\(\s*(-\d+)?\s*\)", re.IGNORECASE)


def pin_result_scans(sql: str, show_ids: list[str | None]) -> str:
    """Swap LAST_QUERY_ID() / LAST_QUERY_ID(-n) for the SHOW's own query id, so RESULT_SCAN reads
    exactly that SHOW and nothing run in between. Left as is when an id is unknown."""
    def swap(m: re.Match) -> str:
        n = int(m.group(1) or -1)
        if -n > len(show_ids) or not show_ids[n]:
            return m.group(0)
        return f"'{show_ids[n]}'"
    return _LAST_QUERY_ID.sub(swap, sql)


def run_sql(cur, sql: str, qid: str | None = None) -> pa.Table:
    assert_read_only(sql)
    cur.execute(sql)
    table = cur.fetch_arrow_all()
    if table is None:
        cols = [d[0] for d in cur.description or []]
        table = pa.table({c: pa.array([], pa.null()) for c in cols})
    return normalise(table, UPPER_CASE_COLUMNS.get(qid or "", {}))


def normalise(table: pa.Table, renames: dict[str, str] | None = None) -> pa.Table:
    """Lower-case names (Snowflake upper-cases them) and turn NUMBER into int64/float64."""
    renames = renames or {}
    cols, names = [], []
    for field in table.schema:
        col = table.column(field.name)
        if pa.types.is_decimal(field.type):
            col = pc.cast(col, pa.int64() if field.type.scale == 0 else pa.float64())
        cols.append(col)
        names.append(renames.get(field.name.lower(), field.name.lower()))
    return pa.Table.from_arrays(cols, names=names)


def explain_connection_error(exc: Exception) -> str:
    """One line for a sign-in or session failure: what Snowflake said (with its code), then the fix."""
    text = " ".join(str(exc).split())
    code = error_code(exc)
    low = text.lower()
    if isinstance(exc, ImportError):
        fix = "install the connector: python -m pip install -r requirements.txt"
    elif isinstance(exc, (FileNotFoundError, PermissionError)) or "private key" in low or "pkcs" in low:
        fix = ("check SNOWFLAKE_PRIVATE_KEY_FILE points at the .p8 file "
               "(and SNOWFLAKE_PRIVATE_KEY_PASSPHRASE if it is encrypted)")
    elif code == "390144" or "jwt token is invalid" in low:
        fix = ("the public key on the user does not match this private key: "
               "ALTER USER <user> SET RSA_PUBLIC_KEY='<public key without the BEGIN/END lines>'")
    elif code in ("390100", "390101") or "incorrect username or password" in low:
        fix = "check SNOWFLAKE_USER and the key pair (or password); the user may be disabled or the key not attached"
    elif code in ("390189", "390201", "390186") or ("role" in low and "not granted" in low):
        fix = "the role in SNOWFLAKE_ROLE is not granted to this user: GRANT ROLE <role> TO USER <user>"
    elif code == "606" or "no active warehouse" in low:
        fix = ("set SNOWFLAKE_WAREHOUSE to a warehouse the role can use: "
               "GRANT USAGE ON WAREHOUSE <warehouse> TO ROLE <role>")
    elif code in ("250001", "250003") or "failed to connect" in low or "could not connect" in low:
        fix = "check SNOWFLAKE_ACCOUNT (orgname-accountname, or locator.region) and the network or proxy"
    elif "network policy" in low or code == "390422":
        fix = "the account's network policy blocks this IP: ask the security admin to allow it"
    else:
        fix = "check the SNOWFLAKE_* settings in .env"
    label = type(exc).__name__ + (f" {code}" if code else "")
    return f"{label}: {text[:200]} -- fix: {fix}"


def detect_edition(cur) -> dict:
    """The account's edition: read from ORGANIZATION_USAGE.ACCOUNTS when the role can, else inferred from
    features only Enterprise or higher has. {"edition": "STANDARD"|"ENTERPRISE"|...|None, "source",
    "evidence"}. A missing feature never proves Standard, so the fallback reports at most "ENTERPRISE"
    (meaning: at least) or None (unknown)."""
    try:
        rows = run_sql(cur, "SELECT edition FROM SNOWFLAKE.ORGANIZATION_USAGE.ACCOUNTS "
                            "WHERE account_locator = CURRENT_ACCOUNT() AND deleted_on IS NULL").to_pylist()
        edition = app_reasons.normalise_edition(next((r.get("edition") for r in rows if r.get("edition")), None))
        if edition:
            return {"edition": edition, "source": "organization_usage.accounts", "evidence": []}
    except Exception:  # noqa: BLE001 -- no ORGADMIN access is normal; fall back to feature evidence
        pass
    evidence: list[str] = []
    probes = (
        ("multi-cluster warehouse", "SELECT COUNT(*) AS n FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_EVENTS_HISTORY "
                                   "WHERE cluster_number > 1 AND timestamp >= DATEADD(day, -30, CURRENT_TIMESTAMP())"),
        ("masking policy", "SELECT COUNT(*) AS n FROM SNOWFLAKE.ACCOUNT_USAGE.MASKING_POLICIES WHERE deleted IS NULL"),
        ("time travel above 1 day", "SELECT COUNT(*) AS n FROM SNOWFLAKE.ACCOUNT_USAGE.TABLES "
                                    "WHERE retention_time > 1 AND deleted IS NULL"),
    )
    for name, sql in probes:
        try:
            row = run_sql(cur, sql).to_pylist()[0]
            if next(iter(row.values()), 0):
                evidence.append(name)
        except Exception:  # noqa: BLE001 -- a probe the role cannot read proves nothing
            continue
    if evidence:
        return {"edition": "ENTERPRISE", "source": "feature_evidence", "evidence": evidence}
    return {"edition": None, "source": None, "evidence": []}


def account_context(cur, *, as_of: dt.date, credit_price: float | None,
                    storage_price: float | None, ai_credit_price: float | None = None) -> dict:
    """Account id, cloud and the effective prices. Each price is the CLI value, else the invoice view,
    else config/settings.yml, else unpriced, and carries its own source; a price read from the invoice
    is invoice-derived, so a discount what-if never stacks on it. The AI price is for AI credits."""
    row = run_sql(cur, "SELECT CURRENT_ACCOUNT() AS a, CURRENT_REGION() AS r, "
                       "CURRENT_ACCOUNT_NAME() AS n, CURRENT_ORGANIZATION_NAME() AS o").to_pylist()[0]
    region = (row.get("r") or "").upper()
    # AWS_US_WEST_2, or PUBLIC.AWS_US_WEST_2 when the account sits in a region group.
    cloud = next((c for c in ("AWS", "AZURE", "GCP") if region.rsplit(".", 1)[-1].startswith(c)), None)
    try:
        settings = app_config.load_settings()
    except Exception:  # noqa: BLE001 -- a broken settings file must not block the export
        settings = {}
    prices = {"credit": [credit_price, "cli" if credit_price is not None else None],
              "storage": [storage_price, "cli" if storage_price is not None else None],
              "ai": [ai_credit_price, "cli" if ai_credit_price is not None else None]}
    by_type: dict = {}
    sheet: dict = {}
    if any(v[0] is None for v in prices.values()):
        try:
            rates = run_sql(cur, org_rate_sql(row["a"], as_of)).to_pylist()
        except Exception as exc:  # noqa: BLE001 -- no ORGADMIN access is normal; fall back
            print(f"note: no org billing access ({_short(exc, 120)}); using the prices in settings", file=sys.stderr)
            rates = []
        by_type = {r.get("usage_kind"): r for r in rates if r.get("rate") is not None}
        try:
            sheet = {r.get("usage_kind"): r for r in run_sql(cur, rate_sheet_sql(row["a"], as_of)).to_pylist()
                     if r.get("rate") is not None}
        except Exception:  # noqa: BLE001 -- the rate sheet is optional; the invoice average stands
            sheet = {}
    invoice = {"credit": "compute", "storage": "storage", "ai": "ai"}
    setting = {"credit": "credit_price_usd", "storage": "storage_price_usd_tb_month", "ai": "ai_credit_price_usd"}
    for key, slot in prices.items():
        if slot[0] is not None:
            continue
        found = by_type.get(invoice[key])
        if key != "storage" and sheet.get(invoice[key]) is not None:
            slot[:] = [float(sheet[invoice[key]]["rate"]), "rate_sheet_daily"]
        elif found is not None:
            rate = float(found["rate"])
            slot[:] = [rate * DAYS_PER_MONTH if key == "storage" else rate, "usage_in_currency_daily"]
        elif settings.get(setting[key]):
            slot[:] = [float(settings[setting[key]]), "settings"]
    return {"account_id": row["a"], "account_name": row.get("n") or row["a"], "true_account_name": row.get("n"),
            "organization_name": row.get("o"),
            "region": region,
            "cloud": cloud, "as_of_date": as_of.isoformat(),
            "credit_price_usd": prices["credit"][0], "price_source": prices["credit"][1],
            "storage_price_usd_tb_month": prices["storage"][0], "storage_price_source": prices["storage"][1],
            "ai_credit_price_usd": prices["ai"][0], "ai_price_source": prices["ai"][1],
            "rate_basis": {k: {"days": v.get("days"), "usage": v.get("usage")} for k, v in by_type.items()} or None,
            "include_snowflake_tasks": bool(settings.get("include_snowflake_tasks", False))}


def rate_sheet_sql(account_locator: str, as_of: dt.date) -> str:
    """The contract's latest USD rate per credit (warehouse compute) and per AI credit from the rate
    sheet: exact, where the invoice view's daily amounts are rounded to cents."""
    return f"""
SELECT kind AS usage_kind, MAX_BY(effective_rate, "DATE") AS rate
FROM (
  SELECT IFF(LOWER(rating_type) = 'ai_compute', 'ai', 'compute') AS kind, "DATE", effective_rate
  FROM SNOWFLAKE.ORGANIZATION_USAGE.RATE_SHEET_DAILY
  WHERE account_locator = {_literal(account_locator)} AND currency = 'USD'
    AND "DATE" < CAST('{as_of.isoformat()}' AS DATE)
    AND LOWER(billing_type) = 'consumption' AND COALESCE(is_adjustment, FALSE) = FALSE
    AND (LOWER(rating_type) = 'ai_compute'
         OR (LOWER(rating_type) = 'compute' AND service_type = 'WAREHOUSE_METERING'))
)
GROUP BY kind
"""


def org_rate_sql(account_locator: str, as_of: dt.date) -> str:
    """Effective USD per credit (and per TB-day of storage) over the last 90 days of the invoice view.

    Only priced consumption counts: rating_type compute or storage, billing_type consumption (rebates,
    support and deployment fees are not the price of a credit), not an adjustment, and not overage
    (on-demand overage is billed at another rate). AI service types are left out of the compute rate;
    rating_type AI_COMPUTE (AI credits) gives the AI rate."""
    return f"""
SELECT CASE LOWER(rating_type) WHEN 'ai_compute' THEN 'ai' ELSE LOWER(rating_type) END AS usage_kind,
       SUM(usage_in_currency) / NULLIF(SUM(usage), 0) AS rate,
       SUM(usage) AS usage,
       COUNT(DISTINCT usage_date) AS days
FROM SNOWFLAKE.ORGANIZATION_USAGE.USAGE_IN_CURRENCY_DAILY
WHERE account_locator = {_literal(account_locator)} AND currency = 'USD'
  AND usage_date >= DATEADD(day, -90, CAST('{as_of.isoformat()}' AS DATE))
  AND usage_date < CAST('{as_of.isoformat()}' AS DATE)
  -- the view stores these in upper case (COMPUTE, CONSUMPTION)
  AND LOWER(rating_type) IN ('compute', 'storage', 'ai_compute')
  AND LOWER(billing_type) = 'consumption'
  AND COALESCE(is_adjustment, FALSE) = FALSE
  AND COALESCE(LOWER(balance_source), '') <> 'overage'
  AND (LOWER(rating_type) = 'ai_compute' OR NOT REGEXP_LIKE(COALESCE(service_type, ''), '(^|_)(AI|CORTEX)(_|$)'))
GROUP BY 1
"""


# ------------------------------------------------------------------------------------------
# What the role can read
# ------------------------------------------------------------------------------------------

_VIEW_SCHEMAS = {"ACCOUNT_USAGE", "ORGANIZATION_USAGE", "READER_ACCOUNT_USAGE", "DATA_SHARING_USAGE",
                 "TRUST_CENTER", "LOCAL"}


def error_code(exc: Exception) -> str | None:
    """The Snowflake error number (or SQLSTATE) on a connector exception, for the report."""
    code = getattr(exc, "errno", None) or getattr(exc, "sqlstate", None)
    return str(code) if code else None


def _short(exc: Exception, limit: int = 160) -> str:
    return " ".join(str(exc).split())[:limit]


def probe_visibility(cur, specs, *, as_of: dt.date) -> dict:
    """Which views and SHOW commands the role can read, before any check runs.

    Every source a check reads is opened with LIMIT 0 (a view) or run without fetching (a SHOW).
    Also compares the warehouses that billed in the last 30 days with those SHOW WAREHOUSES lists:
    SHOW returns only what the role holds a privilege on, so a gap means a partial view.
    Returns {"unreadable": {source: message}, "failed_pre": {statement: message}, "probed": n,
    "warehouses": {...}}.
    """
    views = sorted({(sch, name) for spec in specs for sch, name in spec.sources if sch in _VIEW_SCHEMAS})
    shows = sorted({stmt for spec in specs for stmt in spec.pre})
    out: dict = {"probed": len(views) + len(shows), "unreadable": {}, "failed_pre": {}, "warehouses": None}
    for sch, name in views:
        try:
            cur.execute(f"SELECT 1 FROM SNOWFLAKE.{sch}.{name} LIMIT 0")
        except Exception as exc:  # noqa: BLE001 -- any error means the check cannot read it
            code = error_code(exc)
            out["unreadable"][f"{sch}.{name}"] = (f"{_short(exc)} (error {code})" if code else _short(exc))
    for stmt in shows:
        try:
            run_show(cur, stmt)
        except Exception as exc:  # noqa: BLE001
            out["failed_pre"][stmt] = _short(exc)
    if not any("SHOW WAREHOUSES" in st.upper() for st in out["failed_pre"]) and             "ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY" not in out["unreadable"]:
        try:
            show_id = run_show(cur, "SHOW WAREHOUSES")
            row = run_sql(cur, pin_result_scans(f"""
SELECT COUNT(DISTINCT m.warehouse_name) AS metered,
       COUNT(DISTINCT IFF(s."name" IS NULL, m.warehouse_name, NULL)) AS missing_from_show
FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY m
LEFT JOIN TABLE(RESULT_SCAN(LAST_QUERY_ID())) s ON s."name" = m.warehouse_name
WHERE m.start_time >= DATEADD(day, -30, CAST('{as_of.isoformat()}' AS DATE))
  AND m.start_time < CAST('{as_of.isoformat()}' AS DATE)
  AND m.warehouse_name <> 'CLOUD_SERVICES_ONLY'""", [show_id])).to_pylist()[0]
            out["warehouses"] = {"metered": row["metered"], "missing_from_show": row["missing_from_show"]}
        except Exception as exc:  # noqa: BLE001 -- the probe is advice; it must not stop the export
            print(f"note: warehouse visibility probe failed ({_short(exc, 100)})", file=sys.stderr)
    return out


def unreadable_sources(spec, visibility: dict) -> list[str]:
    """The sources of one check the probe found unreadable (views, and its own `pre` SHOW lines)."""
    bad = [f"{sch}.{name}" for sch, name in spec.sources if f"{sch}.{name}" in visibility["unreadable"]]
    return bad + [stmt for stmt in spec.pre if stmt in visibility["failed_pre"]]


# ------------------------------------------------------------------------------------------
# The export
# ------------------------------------------------------------------------------------------


def _run_check(cur, qid: str, text: str, *, labels_days: list[tuple[int, int]], params: dict,
               ctx: dict, max_rows: int, sql_dir: Path, pre: list[str] | None = None) -> tuple[pa.Table, list[int]]:
    pre = app_registry.by_id(qid).pre if pre is None else pre
    tables, truncated = [], []
    for label, days in labels_days:
        show_ids = [run_show(cur, stmt) for stmt in pre]
        sql = pin_result_scans(render(text, days=days, params=params, ctx=ctx, sql_dir=sql_dir), show_ids)
        table = run_sql(cur, f"{sql}\nLIMIT {int(max_rows) + 1}", qid)
        if table.num_rows > max_rows:
            table, truncated = table.slice(0, max_rows), truncated + [label]
        if "window_days" in table.column_names:
            idx = table.column_names.index("window_days")
            table = table.set_column(idx, "window_days", pa.array([label] * table.num_rows, pa.int32()))
        tables.append(blank_unflagged_waste(qid, table))
    return pa.concat_tables(tables, promote_options="permissive"), truncated


def _run_source(cur, name: str, text: str, *, windows: int, ctx: dict, max_rows: int,
                sql_dir: Path) -> tuple[pa.Table, bool]:
    """One tag source over every window (a `-- windowed: yes` file) or once; window_days carries the label.
    Also returns whether any window was cut at max_rows."""
    windowed = parse_header(text).get("windowed", "no").strip().lower().startswith("yes")
    labels_days = window_sources(window_plan(int(windows))) if windowed else [(0, int(windows))]
    tables, cut = [], False
    for label, days in labels_days:
        sql = render(text, days=days, params={}, ctx=ctx, sql_dir=sql_dir)
        table = run_sql(cur, f"{sql}\nLIMIT {int(max_rows) + 1}", name)
        if table.num_rows > max_rows:
            table, cut = table.slice(0, max_rows), True
        if "window_days" in table.column_names:
            idx = table.column_names.index("window_days")
            table = table.set_column(idx, "window_days", pa.array([label] * table.num_rows, pa.int32()))
        tables.append(table)
    return pa.concat_tables(tables, promote_options="permissive"), cut


def include_today_setting() -> bool:
    """config/settings.yml's include_today: keep today's partial day in the export."""
    try:
        return bool(app_config.load_settings()["include_today"])
    except Exception:  # noqa: BLE001 -- an unreadable settings file must not block the export
        return True


# ACCOUNT_USAGE lags up to 8 h (query attribution), so an hour after midnight the last day is unfinished.
LAG_HOURS = 8


def _cutoff(now: dt.datetime, include_today: bool) -> dt.date:
    """The first day the export leaves out: the day after the last complete one (now minus the
    lag), or tomorrow when today's partial day is kept."""
    return (now + dt.timedelta(days=1) if include_today else now - dt.timedelta(hours=LAG_HOURS)).date()


def not_assessed_rows(table: pa.Table) -> int:
    """Rows whose status column reads NOT_ASSESSED (the check could not look, which is not clean)."""
    if "status" not in table.column_names:
        return 0
    return sum(1 for v in table.column("status").to_pylist() if str(v or "").upper() == "NOT_ASSESSED")


def _visibility_lines(visibility: dict | None) -> list[str]:
    """The report's what-the-role-can-see block: unreadable sources and the warehouse gap."""
    if not visibility:
        return []
    lines = [f"role visibility: {visibility['probed']} sources probed, "
             f"{len(visibility['unreadable']) + len(visibility['failed_pre'])} unreadable"]
    lines += [f"- cannot read {src}: {_md_cell(msg, 140)}" for src, msg in visibility["unreadable"].items()]
    lines += [f"- cannot run {stmt}: {_md_cell(msg, 140)}" for stmt, msg in visibility["failed_pre"].items()]
    wh = visibility.get("warehouses")
    if wh and wh.get("missing_from_show"):
        lines.append(f"- {wh['missing_from_show']} of {wh['metered']} warehouses that billed in the last 30 days "
                     "are not in SHOW WAREHOUSES (dropped, or the role cannot see them: grant MONITOR)")
    return lines + [""]


def _md_cell(text, limit: int = 120) -> str:
    s = (text or "").replace("|", "\\|").replace("\n", " ")
    return s[:limit - 3] + "..." if len(s) > limit else s


def _price_line(manifest: dict) -> str:
    """One line: the credit price and where it came from, the edition, and the per-statement timeout."""
    pricing = manifest.get("pricing") or {}
    price = pricing.get("credit_price_usd")
    credit = (f"${price:.4g} per credit ({pricing.get('source')})" if price is not None
              else "no credit price: $ columns are empty")
    edition = (manifest.get("edition") or {}).get("edition") or "unknown"
    return f"price: {credit}  edition: {edition}  statement timeout: {manifest.get('statement_timeout_s')} s"


def render_report(manifest: dict, started: str, finished: str) -> str:
    """report.md: one row per check, failed first, then not assessed, then the rest."""
    def rank(item):
        qid, f = item
        if f["status"] == "failed":
            return (0, qid)
        if f["status"] == "not_assessed":
            return (1, qid)
        rows = f.get("exported_rows") or 0
        return (2 if rows and f.get("not_assessed_rows") == rows else 3, qid)

    entries = sorted(manifest["findings"].items(), key=rank)
    by_status: dict[str, int] = {}
    for _, f in entries:
        by_status[f["status"]] = by_status.get(f["status"], 0) + 1
    lines = [
        "# Snowflake export report", "",
        f"days: {manifest['days']}  as of: {manifest['as_of_date']} "
        f"({'today partial' if manifest['includes_today'] else 'complete days only'})",
        f"started: {started}  finished: {finished}", "",
        _price_line(manifest), "",
        f"**{len(entries)} checks** -- " + ", ".join(f"{k}: {v}" for k, v in sorted(by_status.items())), "",
    ] + _visibility_lines(manifest.get("visibility")) + [
        "| check | domain | status | rows | not assessed rows | seconds | error |",
        "|---|---|---|---|---|---|---|",
    ]
    for qid, f in entries:
        lines.append(f"| {qid} | {f.get('domain')} | {f['status']} | {f.get('exported_rows')} | "
                     f"{f.get('not_assessed_rows')} | {f.get('duration_s')} | {_md_cell(f.get('error'))} |")
    return "\n".join(lines) + "\n"


def run_export(out_dir: Path, *, windows: int = 30, max_rows: int = DEFAULT_MAX_ROWS,
               credit_price: float | None = None, storage_price: float | None = None,
               ai_credit_price: float | None = None, use_fallbacks: bool = False,
               only: list[str] | None = None, mask: list[str] | None = None, mask_salt: str | None = None,
               connect_fn=None, workers: int = 1,
               include_today: bool = False, progress=None,
               now: dt.datetime | None = None, sql_dir: Path = SQL_DIR) -> dict:
    """Run every check into out_dir; a failed check is recorded, never fatal. `progress(i, n, qid, entry)`
    is called after each check. `workers` sessions run checks at once. `mask` lists the kinds of names to mask (app/core/masking.py); the files
    are masked before the manifest and report are written, so no real name is left in out_dir."""
    try:
        mask = app_masking.parse_kinds(mask)
    except ValueError as exc:
        raise ExportConfigError(str(exc)) from exc
    now = now or dt.datetime.now(dt.timezone.utc)
    as_of = _cutoff(now, include_today)
    if datasource.inside_repo(out_dir):
        raise ExportConfigError(f"{out_dir} is inside the repository; choose a folder outside it")
    checks = load_checks(sql_dir)
    if only:
        unknown = sorted(set(only) - set(checks))
        if unknown:
            raise ExportConfigError(f"no Snowflake check for: {unknown}")
        checks = {q: checks[q] for q in only}
    thresholds = app_config.load_thresholds()
    plan = window_plan(int(windows))
    sources = window_sources(plan)
    aliases = window_aliases_map(plan)

    work = out_dir.with_name(out_dir.name + ".tmp")
    if work.exists():
        shutil.rmtree(work)
    (work / "findings").mkdir(parents=True)
    (work / "dims").mkdir()

    try:
        conn = (connect_fn or connect)()
        cur = conn.cursor()
    except ExportConfigError:
        shutil.rmtree(work, ignore_errors=True)
        raise
    except Exception as exc:  # noqa: BLE001 -- sign-in and session setup: one line, never a traceback
        shutil.rmtree(work, ignore_errors=True)
        raise ExportConnectionError(explain_connection_error(exc)) from exc
    try:
        try:
            ctx = account_context(cur, as_of=as_of, credit_price=credit_price, storage_price=storage_price,
                                  ai_credit_price=ai_credit_price)
        except Exception as exc:  # noqa: BLE001 -- the first statement failing is a session problem
            shutil.rmtree(work, ignore_errors=True)
            raise ExportConnectionError(explain_connection_error(exc)) from exc
        visibility = probe_visibility(cur, [app_registry.by_id(q) for q in checks], as_of=as_of)
        edition = detect_edition(cur)
        fallbacks = {q: t for q, t in load_fallbacks(sql_dir).items() if q in checks}
        ctx["info_schema_db"] = info_schema_db(cur) if fallbacks else None
        ctx["monitor_usage"] = has_monitor_usage(cur, ctx) if ctx["info_schema_db"] else False
        ctx["account_privileges"] = account_privileges(cur) if ctx["info_schema_db"] else set()
        to_run = [fb for q, fb in fallbacks.items()
                  if use_fallbacks or unreadable_sources(app_registry.by_id(q), visibility)]
        if ctx["info_schema_db"] and any(uses_query_feed(fb) for fb in to_run):
            run_query_feed(cur, ctx, sql_dir)
        if ctx["info_schema_db"]:
            run_shims(cur, ctx, sorted({v for fb in to_run for v in shims_in(fb)}), sql_dir)
        findings: dict[str, dict] = {}
        total_checks = len(checks)
        lock = threading.Lock()
        done = [0]
        local = threading.local()
        extra_conns: list = []

        def worker_cursor():
            # A SHOW pre-step and its RESULT_SCAN must share a session, so each thread has its own.
            if workers <= 1:
                return cur
            if not hasattr(local, "cur"):
                c = (connect_fn or connect)()
                with lock:
                    extra_conns.append(c)
                local.cur = c.cursor()
            return local.cur

        def run_one(qid: str, text: str) -> None:
            started = time.monotonic()
            spec = app_registry.by_id(qid)
            labels_days = sources if spec.windowed else [(0, int(windows))]
            blocked = unreadable_sources(spec, visibility)
            too_low = (app_reasons.edition_at_least(edition["edition"], "ENTERPRISE") is False
                       and app_reasons.needs_enterprise(spec.requires, spec.empty_if))
            if too_low:
                # Not run: the account's edition lacks the feature, and a grant changes nothing.
                entry = {"status": "not_assessed", "exported_rows": None, "truncated": False,
                         "truncated_windows": [], "columns": None, "not_assessed_rows": None,
                         "not_assessed_reason": "edition_too_low", "cause": "edition_too_low",
                         "unreadable": [],
                         "error": f"edition_too_low: needs Enterprise Edition or higher; this account is "
                                  f"{edition['edition']}",
                         "duration_s": 0.0, "domain": _domain(qid, text)}
            elif (blocked or use_fallbacks) and qid in fallbacks and ctx.get("info_schema_db"):
                # The role cannot read ACCOUNT_USAGE here: read the same check from INFORMATION_SCHEMA.
                fb = fallbacks[qid]
                head = parse_header(fb)
                note = head.get("fallback_note")
                if uses_query_feed(fb) and query_feed_gap(ctx):
                    note = f"{note}; {query_feed_gap(ctx)}"
                if shim_gap_note(fb, ctx):
                    note = f"{note}; {shim_gap_note(fb, ctx)}"
                try:
                    if fallback_blocked(head, ctx):
                        raise ExportConfigError(fallback_blocked(head, ctx))
                    table, truncated = _run_check(
                        worker_cursor(), qid, fb, labels_days=labels_days, params=params_for(qid, thresholds),
                        ctx=ctx, max_rows=max_rows, sql_dir=sql_dir,
                        pre=[x.strip() for x in head.get("pre", "").split(";") if x.strip()])
                    pq.write_table(table, work / "findings" / f"{qid}.parquet")
                    entry = {"status": "ok" if table.num_rows else "empty",
                             "exported_rows": table.num_rows, "truncated": bool(truncated),
                             "truncated_windows": truncated, "columns": table.column_names,
                             "not_assessed_rows": not_assessed_rows(table), "error": None}
                except Exception as exc:  # noqa: BLE001 -- the fallback failing reads as the role gap
                    entry = {"status": "not_assessed", "exported_rows": None, "truncated": False,
                             "truncated_windows": [], "columns": None, "not_assessed_rows": None,
                             "not_assessed_reason": "role_cannot_see", "cause": "no_access",
                             "error": (fallback_blocked(head, ctx) or
                                       f"role_cannot_see; the INFORMATION_SCHEMA fallback failed too: {_short(exc, 300)}")}
                entry.update({"source": "information_schema", "source_reads": head.get("reads"),
                              "source_note": note, "unreadable": blocked,
                              "duration_s": round(time.monotonic() - started, 3), "domain": _domain(qid, text)})
            elif blocked:
                # Not run: reading it would error, and "nothing found" would be a false all-clear.
                entry = {"status": "not_assessed", "exported_rows": None, "truncated": False,
                         "truncated_windows": [], "columns": None, "not_assessed_rows": None,
                         "not_assessed_reason": "role_cannot_see", "cause": "no_access",
                         "unreadable": blocked,
                         "error": ("role_cannot_see: " + "; ".join(
                             f"{src}: " + {**visibility["unreadable"], **visibility["failed_pre"]}.get(src, "unreadable")
                             for src in blocked))[:500],
                         "duration_s": 0.0, "domain": _domain(qid, text)}
            else:
                try:
                    table, truncated = _run_check(
                        worker_cursor(), qid, text, labels_days=labels_days, params=params_for(qid, thresholds),
                        ctx=ctx, max_rows=max_rows, sql_dir=sql_dir)
                    pq.write_table(table, work / "findings" / f"{qid}.parquet")
                    entry = {"status": "ok" if table.num_rows else "empty",
                             "exported_rows": table.num_rows, "truncated": bool(truncated),
                             "truncated_windows": truncated, "columns": table.column_names,
                             "not_assessed_rows": not_assessed_rows(table), "error": None}
                except Exception as exc:  # noqa: BLE001 -- one check's failure must not stop the rest
                    entry = {"status": "failed", "exported_rows": None, "truncated": False,
                             "truncated_windows": [], "columns": None, "not_assessed_rows": None,
                             "error": str(exc)[:500], "error_code": error_code(exc),
                             "cause": app_reasons.classify_error(str(exc), error_code(exc))}
                entry["duration_s"] = round(time.monotonic() - started, 3)
                entry["domain"] = _domain(qid, text)
            with lock:
                findings[qid] = entry
                done[0] += 1
                if progress:
                    progress(done[0], total_checks, qid, entry)

        try:
            if workers <= 1:
                for qid, text in checks.items():
                    run_one(qid, text)
            else:
                with ThreadPoolExecutor(max_workers=workers) as pool:
                    for f in [pool.submit(run_one, q, t) for q, t in checks.items()]:
                        f.result()
        finally:
            for c in extra_conns:
                try:
                    c.close()
                except Exception:  # noqa: BLE001 -- closing a worker session must not hide the result
                    pass
        tag_sources_ok: list[str] = []
        tag_sources_failed: dict[str, str] = {}
        tag_sources_cut: list[str] = []
        (work / "tags_src").mkdir()
        for name, text in load_tag_sources(sql_dir).items():
            try:
                table, cut = _run_source(cur, name, text, windows=int(windows), ctx=ctx, max_rows=max_rows, sql_dir=sql_dir)
                pq.write_table(table, work / "tags_src" / f"{name}.parquet")
                tag_sources_ok.append(name)
                if cut:
                    tag_sources_cut.append(name)
                    print(f"warning: tag source {name} was cut at {max_rows} rows; spend by tag can read low", file=sys.stderr)
            except Exception as exc:  # noqa: BLE001 -- a missing source leaves the tag tables unbuilt, never fatal
                tag_sources_failed[name] = str(exc)[:300]
                print(f"warning: tag source {name} failed: {str(exc)[:200]}", file=sys.stderr)
        dims_ok = []
        for name, text in load_dims(sql_dir).items():
            try:
                table = run_sql(cur, render(text, days=int(windows), params={}, ctx=ctx, sql_dir=sql_dir))
                pq.write_table(table, work / "dims" / f"{name}.parquet")
                dims_ok.append(name)
            except Exception as exc:  # noqa: BLE001 -- a missing dim falls back to the loader's stub
                print(f"warning: dim {name} failed: {str(exc)[:200]}", file=sys.stderr)
    finally:
        conn.close()

    manifest = {
        "tool": "tools/export_results.py", "tool_version": TOOL_VERSION,
        "git_commit": git_commit(),
        "as_of": now.strftime("%Y-%m-%dT%H:%M:%SZ"),
        # The first day left out; with includes_today, today up to as_of is in and partial.
        "as_of_date": as_of.isoformat(), "includes_today": include_today, "mode": "query",
        # The last day the windows fully cover, and the lag that set the cut-off.
        "last_complete_day": ((now - dt.timedelta(hours=LAG_HOURS)).date() - dt.timedelta(days=1)).isoformat(),
        "export_date": now.date().isoformat(), "lag_hours": LAG_HOURS, "visibility": visibility,
        "edition": edition, "statement_timeout_s": int(_statement_timeout_s),
        "monitor_usage": ctx.get("monitor_usage"),
        "manage_grants": bool({"ACCOUNTADMIN", "MANAGE GRANTS"} & (ctx.get("account_privileges") or set())),
        "windows": [w for w, _ in plan], "window_coverage": {str(w): d for w, d in plan},
        "window_aliases": {str(a): str(s) for a, s in aliases.items()}, "days": int(windows),
        "account": {"id": ctx["account_id"], "name": ctx["account_name"], "account_name": ctx.get("true_account_name"),
                    "organization_name": ctx.get("organization_name"), "cloud": ctx["cloud"],
                    "region": ctx["region"]},
        "pricing": {"source": ctx["price_source"], "credit_price_usd": ctx["credit_price_usd"],
                    "storage_price_usd_tb_month": ctx["storage_price_usd_tb_month"],
                    "storage_source": ctx["storage_price_source"],
                    "ai_credit_price_usd": ctx.get("ai_credit_price_usd"), "ai_source": ctx.get("ai_price_source"),
                    "rate_basis": ctx["rate_basis"]},
        "max_rows": max_rows, "masked": mask, "include_snowflake_tasks": bool(ctx.get("include_snowflake_tasks")),
        "findings": dict(sorted(findings.items())),
        "dims": {"available": dims_ok},
        "tag_sources": {"available": tag_sources_ok, "failed": tag_sources_failed, "truncated": tag_sources_cut},
    }
    manifest = app_masking.mask_folder(work, mask, mask_salt, manifest)
    (work / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    finished = dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    (work / "report.md").write_text(
        render_report(manifest, now.strftime("%Y-%m-%dT%H:%M:%SZ"), finished), encoding="utf-8")
    if out_dir.exists():
        shutil.rmtree(out_dir)
    os.rename(work, out_dir)
    return manifest


def _source_keys(spec) -> list[str]:
    """A check's sources as the grant table names them: ACCOUNT_USAGE.QUERY_HISTORY, SHOW WAREHOUSES."""
    return [f"SHOW {name}" if sch == "SHOW" else f"{sch}.{name}" for sch, name in spec.sources if sch != "FUNCTION"]


CAUSE_TITLES = {
    "no_access": "The role can't read it",
    "view_missing": "Not in this account",
    "edition_too_low": "Needs a higher Snowflake edition (no grant changes this)",
    "timeout": "Timed out",
}


def run_validate(out_dir: Path, *, windows: int = 7, only: list[str] | None = None,
                 credit_price: float | None = None, storage_price: float | None = None,
                 ai_credit_price: float | None = None,
                 connect_fn=None, include_today: bool = False, now: dt.datetime | None = None,
                 sql_dir: Path = SQL_DIR) -> dict:
    """Run every check and dim with LIMIT 0 (compiles and binds, reads no rows). Each statement is ok,
    unreadable (the role, the account or the edition cannot read a source: not a fault) or failed (a
    real SQL error). Writes validate.json and validate.md into out_dir."""
    now = now or dt.datetime.now(dt.timezone.utc)
    as_of = _cutoff(now, include_today)
    if datasource.inside_repo(out_dir):
        raise ExportConfigError(f"{out_dir} is inside the repository; choose a folder outside it")
    checks = load_checks(sql_dir)
    if only:
        unknown = sorted(set(only) - set(checks))
        if unknown:
            raise ExportConfigError(f"no Snowflake check for: {unknown}")
        checks = {q: checks[q] for q in only}
    thresholds = app_config.load_thresholds()
    try:
        conn = (connect_fn or connect)()
        cur = conn.cursor()
    except Exception as exc:  # noqa: BLE001 -- sign-in and session setup: one line, never a traceback
        raise ExportConnectionError(explain_connection_error(exc)) from exc
    results: dict[str, dict] = {}
    try:
        try:
            ctx = account_context(cur, as_of=as_of, credit_price=credit_price, storage_price=storage_price,
                                  ai_credit_price=ai_credit_price)
        except Exception as exc:  # noqa: BLE001
            raise ExportConnectionError(explain_connection_error(exc)) from exc
        visibility = probe_visibility(cur, [app_registry.by_id(q) for q in checks], as_of=as_of)
        edition = detect_edition(cur)
        jobs = [(qid, text, app_registry.by_id(qid).pre, params_for(qid, thresholds)) for qid, text in checks.items()]
        jobs += [(f"dim:{name}", text, [], {}) for name, text in load_dims(sql_dir).items()]
        for qid, text, pre, params in jobs:
            spec = app_registry.by_id(qid) if not qid.startswith("dim:") else None
            try:
                show_ids = [run_show(cur, stmt) for stmt in pre]
                sql = pin_result_scans(render(text, days=int(windows), params=params, ctx=ctx, sql_dir=sql_dir), show_ids)
                assert_read_only(sql)
                cur.execute(f"{sql}\nLIMIT 0")
                results[qid] = {"status": "ok", "cause": None, "error": None, "error_code": None,
                                "sources": [], "grants": []}
            except Exception as exc:  # noqa: BLE001 -- record and go on to the next check
                code = error_code(exc)
                cause = app_reasons.classify_error(str(exc), code)
                if (cause in ("no_access", "view_missing") and spec is not None
                        and app_reasons.edition_at_least(edition["edition"], "ENTERPRISE") is False
                        and app_reasons.needs_enterprise(spec.requires, spec.empty_if)):
                    cause = "edition_too_low"
                sources: list[str] = []
                if spec is not None and cause in ("no_access", "view_missing"):
                    sources = unreadable_sources(spec, visibility) or _source_keys(spec)
                results[qid] = {"status": "failed" if cause == "sql_error" else "unreadable", "cause": cause,
                                "error": str(exc)[:500], "error_code": code, "sources": sources,
                                "grants": app_reasons.grants_for(sources) if cause == "no_access" else []}
    finally:
        conn.close()
    summary = {"as_of_date": as_of.isoformat(), "days": int(windows), "visibility": visibility,
               "edition": edition, "checks": dict(sorted(results.items()))}
    out_dir.mkdir(parents=True, exist_ok=True)
    (out_dir / "validate.json").write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")
    (out_dir / "validate.md").write_text(render_validate(summary), encoding="utf-8")
    return summary


def validate_groups(summary: dict) -> dict:
    """{"ok": [ids], "failed": {id: entry}, "unreadable": {cause: {"checks": [ids], "grants": [lines]}}}."""
    out: dict = {"ok": [], "failed": {}, "unreadable": {}}
    for qid, entry in summary["checks"].items():
        if entry["status"] == "ok":
            out["ok"].append(qid)
        elif entry["status"] == "failed":
            out["failed"][qid] = entry
        else:
            group = out["unreadable"].setdefault(entry["cause"], {"checks": [], "grants": []})
            group["checks"].append(qid)
            for line in entry.get("grants") or []:
                if line not in group["grants"]:
                    group["grants"].append(line)
    return out


def render_validate(summary: dict) -> str:
    """validate.md: real SQL errors first, then the unreadable checks grouped by cause with the one
    GRANT for each, then what the role sees."""
    groups = validate_groups(summary)
    n = len(summary["checks"])
    unreadable = sum(len(g["checks"]) for g in groups["unreadable"].values())
    lines = ["# Snowflake validate report (LIMIT 0)", "",
             f"days: {summary['days']}  as of: {summary['as_of_date']}", "",
             f"**{n} statements**: {len(groups['ok'])} ok, {unreadable} not readable by this role or account, "
             f"{len(groups['failed'])} SQL errors", ""]
    edition = (summary.get("edition") or {}).get("edition")
    if edition:
        lines += [f"edition: {edition}", ""]
    if groups["failed"]:
        lines += ["## SQL errors (a fault in the statement: fix these)", "",
                  "| check | error code | error |", "|---|---|---|"]
        for qid, f in groups["failed"].items():
            lines.append(f"| {qid} | {f.get('error_code') or ''} | {_md_cell(f.get('error'))} |")
        lines.append("")
    for cause, group in groups["unreadable"].items():
        lines += [f"## {CAUSE_TITLES.get(cause, cause)}: {len(group['checks'])} statements", ""]
        if group["grants"]:
            lines += ["```sql", *group["grants"], "```", ""]
        lines += [", ".join(group["checks"]), ""]
    lines += _visibility_lines(summary.get("visibility"))
    return "\n".join(lines) + "\n"


def _domain(qid: str, text: str) -> str:
    return app_registry.by_id(qid).domain


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("--out", required=True, type=Path, help="results folder, outside the repo")
    p.add_argument("--windows", type=int, default=30, help="days of history (default 30; 90 fills every window)")
    p.add_argument("--credit-price", type=float, help="USD per credit when the org billing view is not readable")
    p.add_argument("--ai-credit-price", type=float, help="USD per AI credit (Cortex, Copilot), same")
    p.add_argument("--use-fallbacks", action="store_true",
                   help="read the checks that have one from INFORMATION_SCHEMA even when ACCOUNT_USAGE is readable "
                        "(to test the fallbacks)")
    p.add_argument("--storage-price", type=float, help="USD per TB-month of storage")
    p.add_argument("--max-rows", type=int, default=DEFAULT_MAX_ROWS)
    p.add_argument("--statement-timeout", type=int, default=DEFAULT_STATEMENT_TIMEOUT_S, metavar="SECONDS",
                   help="cancel any one statement after this long (default %(default)s)")
    p.add_argument("--only", nargs="+", help="run just these check ids")
    p.add_argument("--workers", type=int, default=DEFAULT_WORKERS,
                   help="checks run at once, each on its own session (default %(default)s; 1 runs them one by one)")
    p.add_argument("--mask", metavar="KINDS", default=None,
                   help="mask these kinds of names, comma-separated: " + ", ".join(app_masking.MASK_KINDS)
                   + " or all (default: privacy.mask_fields in config/settings.yml, which Refresh uses)")
    p.add_argument("--mask-salt", metavar="TEXT",
                   help="salt for the mask tokens, to keep them the same across exports (default: random)")
    p.add_argument("--validate", action="store_true",
                   help="run each check with LIMIT 0 and report ok / not readable / SQL error; exports nothing")
    return p


def _print_progress(index: int, total: int, qid: str, entry: dict) -> None:
    """One line per check, so a long export never looks hung."""
    status = entry["status"]
    if status == "failed":
        detail = f"failed [{entry.get('error_code') or entry.get('cause') or '-'}]"
    elif status == "not_assessed":
        detail = f"not assessed ({entry.get('not_assessed_reason')})"
    else:
        detail = f"{status}, {entry.get('exported_rows')} rows"
    print(f"[{index}/{total}] {qid}: {detail}, {entry.get('duration_s')}s", flush=True)


def mask_kinds(arg: str | None) -> list[str]:
    """--mask when given (an empty string masks nothing), else privacy.mask_fields from settings."""
    try:
        if arg is not None:
            return app_masking.parse_kinds(arg)
        return app_masking.parse_kinds(app_config.load_settings().get("privacy", {}).get("mask_fields") or [])
    except ValueError as exc:
        raise ExportConfigError(str(exc)) from exc


def main(argv: list[str] | None = None) -> int:
    global _statement_timeout_s
    args = build_parser().parse_args(argv)
    _statement_timeout_s = max(int(args.statement_timeout), 1)
    if args.validate:
        try:
            summary = run_validate(args.out, windows=args.windows, only=args.only,
                                   credit_price=args.credit_price, storage_price=args.storage_price,
                                   ai_credit_price=args.ai_credit_price,
                                   include_today=include_today_setting())
        except ExportConfigError as exc:
            print(f"error: {exc}", file=sys.stderr)
            return 2
        except ExportConnectionError as exc:
            print(f"error: {exc}", file=sys.stderr)
            return 1
        groups = validate_groups(summary)
        unreadable = sum(len(g["checks"]) for g in groups["unreadable"].values())
        print(f"validated {len(summary['checks'])} statements: {len(groups['ok'])} ok, "
              f"{unreadable} not readable by this role or account, {len(groups['failed'])} SQL errors")
        for cause, group in groups["unreadable"].items():
            print(f"{CAUSE_TITLES.get(cause, cause)}: {len(group['checks'])} statements")
            for line in group["grants"]:
                print(f"  {line}")
        for q, f in groups["failed"].items():
            print(f"SQL ERROR {q} [{f.get('error_code') or '-'}]: {_md_cell(f['error'], 160)}")
        print(f"report: {args.out / 'validate.md'}")
        # A source the role cannot read is normal; only a fault in a statement fails the run.
        return 1 if groups["failed"] else 0
    try:
        manifest = run_export(args.out, windows=args.windows, max_rows=args.max_rows,
                              credit_price=args.credit_price, storage_price=args.storage_price,
                              ai_credit_price=args.ai_credit_price, use_fallbacks=args.use_fallbacks,
                              only=args.only, mask=mask_kinds(args.mask), mask_salt=args.mask_salt,
                              workers=max(int(args.workers), 1), include_today=include_today_setting(), progress=_print_progress)
    except ExportConfigError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2
    except ExportConnectionError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1
    counts: dict[str, int] = {}
    for entry in manifest["findings"].values():
        counts[entry["status"]] = counts.get(entry["status"], 0) + 1
    print(f"wrote {args.out}: " + ", ".join(f"{n} {s}" for s, n in sorted(counts.items())))
    if manifest["pricing"]["credit_price_usd"] is None:
        print("note: no credit price, so $ columns are empty; pass --credit-price or set credit_price_usd "
              "in config/settings.yml", file=sys.stderr)
    print(f"next: python tools/load_results.py {args.out} --db PATH")
    return 0


if __name__ == "__main__":
    sys.exit(main())
