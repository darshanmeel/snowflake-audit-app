"""tools/export_shared.py -- the export helpers tools/export_results.py and the export kit share.

tools/make_export_kit.py copies this file (without its docstring and imports) into
tools/export_kit/run_export.py, which must run without the repository: edit it here, never in the kit.
Standard library and pyarrow only."""
from __future__ import annotations

import datetime as dt
import re
import time

import pyarrow as pa
import pyarrow.compute as pc


_SHIM_TOKEN_RE = re.compile(r"__SHIM_([A-Z_]+)__")


def shims_in(text: str) -> list[str]:
    """The shims a fallback reads."""
    return sorted(set(_SHIM_TOKEN_RE.findall(text)))


def info_schema_db(cur) -> str | None:
    """A database whose INFORMATION_SCHEMA the role can call table functions from: the session's own,
    else the first one SHOW DATABASES lists outside SNOWFLAKE (which needs IMPORTED PRIVILEGES)."""
    try:
        cur.execute("SELECT CURRENT_DATABASE()")
        current = cur.fetchone()[0]
        if current:
            return current
        cur.execute("SHOW TERSE DATABASES")
        rows = cur.fetchall()
        # A standard database first: a shared or application one may not run the table functions.
        names = ([r[1] for r in rows if len(r) > 2 and str(r[2] or "").upper() == "STANDARD"]
                 + [r[1] for r in rows])
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


def _literal(value) -> str:
    if value is None:
        return "CAST(NULL AS DOUBLE)"
    if isinstance(value, bool):
        return "TRUE" if value else "FALSE"
    if isinstance(value, (int, float)):
        return repr(value)
    return "'" + str(value).replace("'", "''") + "'"


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
                out.append((None, short(exc, 200)))
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
                done[nxt] = (None, short(exc, 200))
            nxt += 1
        for i, sfqid in list(running.items()):
            try:
                if not conn.is_still_running(conn.get_query_status_throw_if_error(sfqid)):
                    done[i] = (sfqid, None)
                    del running[i]
            except Exception as exc:  # noqa: BLE001 -- one statement failing drops only its own part
                done[i] = (None, short(exc, 200))
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


def short(exc: Exception, limit: int = 160) -> str:
    return " ".join(str(exc).split())[:limit]
