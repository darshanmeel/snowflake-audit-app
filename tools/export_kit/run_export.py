#!/usr/bin/env python3
"""Snowflake audit export: runs the read-only SQL in queries/ and writes parquet files.

Needs Python 3.9+ and:  python -m pip install "snowflake-connector-python[pandas]" pyarrow

Sign-in comes from environment variables or a .env file next to this script:
    SNOWFLAKE_ACCOUNT, SNOWFLAKE_USER, SNOWFLAKE_ROLE, SNOWFLAKE_WAREHOUSE, and one of
    SNOWFLAKE_PRIVATE_KEY_FILE (+ SNOWFLAKE_PRIVATE_KEY_PASSPHRASE), SNOWFLAKE_PASSWORD,
    or SNOWFLAKE_AUTHENTICATOR (default: externalbrowser)

    python run_export.py                       # 30 days, writes sf-audit-out/ and sf-audit-out.zip
    python run_export.py --windows 90 --credit-price 3.0
    python run_export.py --mask user,warehouse,database   # replace those names with tokens

Every statement is a single SELECT, WITH or SHOW; anything else is refused before it is sent.
No query text, secrets or policy bodies are read. Send back the .zip.
"""
from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
import re
import secrets
import shutil
import sys
import time
from pathlib import Path

import pyarrow as pa
import pyarrow.compute as pc
import pyarrow.parquet as pq

HERE = Path(__file__).resolve().parent
QUERIES = HERE / "queries"
TOOL_VERSION = "kit-0.1.0"
ENV_VARS = (
    "SNOWFLAKE_ACCOUNT", "SNOWFLAKE_USER", "SNOWFLAKE_PASSWORD", "SNOWFLAKE_AUTHENTICATOR",
    "SNOWFLAKE_PRIVATE_KEY_FILE", "SNOWFLAKE_PRIVATE_KEY_PASSPHRASE", "SNOWFLAKE_ROLE",
    "SNOWFLAKE_WAREHOUSE",
)
WINDOW_LABELS = (7, 30, 90)
DAYS_PER_MONTH = 30.4
# ACCOUNT_USAGE lags up to 8 h, so the last day is only complete 8 h after midnight UTC.
LAG_HOURS = 8
EDITION_RANK = {"STANDARD": 1, "ENTERPRISE": 2, "BUSINESS_CRITICAL": 3, "VIRTUAL_PRIVATE_SNOWFLAKE": 4}
VIEW_SCHEMAS = {"ACCOUNT_USAGE", "ORGANIZATION_USAGE", "READER_ACCOUNT_USAGE", "DATA_SHARING_USAGE", "TRUST_CENTER", "LOCAL"}
# Columns the app reads in upper case; everything else is lower case.
UPPER_CASE_COLUMNS = {"access_grants_inventory": {"grantee": "GRANTEE"}}

_PARAM_RE = re.compile(r"(?<![:\w]):([a-z_][a-z0-9_]*)")
_COMMENT_RE = re.compile(r"--[^\n]*|/\*.*?\*/", re.S)
_READ_ONLY_RE = re.compile(r"^\s*(SELECT|WITH|SHOW)\b", re.I)
_WASTE_COLUMN_RE = re.compile(r"^(est_)?(wasted|saving)|^(total_)?est_(wasted|saving)|^est_idle_usd", re.I)


class StopExport(RuntimeError):
    """A whole-run problem: printed as one line, then the script stops."""


# ---- masking: a copy of app/core/masking.py, made by tools/make_export_kit.py; edit it there ----
MASK_KINDS = ("user", "warehouse", "database", "schema", "object", "role", "task", "account")
_PREFIX = {"warehouse": "wh", "database": "db", "schema": "sch", "object": "obj", "role": "role",
           "task": "task", "account": "acct"}

# Columns whose whole value is one name of a kind.
_KIND_COLUMNS = {
    "warehouse": {"warehouse_name", "warehouse", "main_warehouse_name", "query_warehouse"},
    "database": {"database_name", "table_catalog", "view_catalog", "tag_database", "db_name"},
    "schema": {"schema_name", "table_schema", "view_schema", "tag_schema", "source_schema"},
    "object": {"table_name", "view_name", "source_table", "target_table", "source_view", "mv_name",
               "dt_name", "stream_name", "stage_name", "pipe_name", "function_name", "alert_name",
               "notebook_name"},
    "task": {"task_name", "root_task_name", "last_first_error_task_name"},
    "role": {"role_name", "granted_role", "grantee_role", "granted_by_role", "resized_by_role", "owner",
             "owner_role", "admin_role", "default_role", "granted_by"},
    "account": {"account_name", "account_locator", "account_id", "reader_account_name",
                "provider_account_name", "provider_account_locator", "owner_account"},
}
# An owner column names the role that owns the object (Snowflake objects are owned by roles).
_OWNER_RE = re.compile(r"^[a-z_]+_owner$")
_NOT_OWNER = {"owner_account", "owner_state"}

# Columns holding several names of one kind, separated by commas.
_LIST_COLUMNS = {
    "role": {"granted_roles", "admin_roles", "direct_role_list", "personal_roles", "usage_roles",
             "exempt_roles", "inherited_admin_roles", "object_owner_roles", "granted_by_roles",
             "grantor_roles", "sample_secondary_roles"},
    "warehouse": {"warehouse_names", "warehouses"},
    "task": {"consumer_tasks"},
    "account": {"allowed_accounts", "consumer_accounts"},
    "object": {"stale_stage_names"},
}

# Full names, masked part by part: (database, schema, last part's kind).
_FQN_LAST_KIND = {"task_full_name": "task", "root_task_full_name": "task", "job_id": "task",
                  "last_first_error_task_name": "task"}
_FQN_RE = re.compile(r"(_fqn|_full_name)$")
_FQN_COLUMNS = {"object_name", "job_id", "sample_tables", "sample_objects", "sample_sources", "sample_targets",
                "source_fqn", "table_fqn"}
# DB.SCHEMA.NAME inside free text: masked by position, so a database that shares a table's name
# still gets the database token.
_DOTTED_RE = re.compile(r'(?<![A-Za-z0-9_$."])((?:"[^"]+"|[A-Za-z_][A-Za-z0-9_$]*)(?:\.(?:"[^"]+"|[A-Za-z_][A-Za-z0-9_$]*)){2})(?![A-Za-z0-9_$"])')

# Person columns (the same rule as app/core/identity.py) and the lists of them.
_PERSON_RE = re.compile(
    r"^(?:(?:[a-z0-9]+_)*user_name|login_name|executed_by|actor|email|top_user|requester|identity_run_as"
    r"|principal|resized_by|created_by|users|sample_users|blocked_users)$",
    re.IGNORECASE,
)
_PERSON_LIST = {"users", "sample_users", "blocked_users"}
# A grantee column names a user or a role, as its type column says.
_GRANTEE_COLUMNS = {"grantee", "grantee_name"}
_GRANTEE_TYPE_COLUMNS = ("grantee_type", "granted_to")

_SYSTEM = {
    "database": {"SNOWFLAKE", "SNOWFLAKE_SAMPLE_DATA"},
    "schema": {"INFORMATION_SCHEMA", "ACCOUNT_USAGE", "ORGANIZATION_USAGE", "READER_ACCOUNT_USAGE",
               "DATA_SHARING_USAGE", "PUBLIC"},
    "role": {"ACCOUNTADMIN", "SECURITYADMIN", "SYSADMIN", "USERADMIN", "ORGADMIN", "GLOBALORGADMIN",
             "PUBLIC"},
}
# A system name stays whatever column it is in (PUBLIC is both a role and a schema).
_ALL_SYSTEM = set().union(*_SYSTEM.values())
_PLACEHOLDER_RE = re.compile(r"^\(.*\)$")
_USER_MASKED_RE = re.compile(r"^\S+ .{0,2}\*\*\*$")
_TOKEN_RE = re.compile(r"^(?:wh|db|sch|obj|role|task|acct)_[0-9a-f]{8}$")
# Shorter names are masked in their own columns but not searched for in free text (too many false hits).
_MIN_TEXT_LEN = 3
_WORD = r"A-Za-z0-9_$"


def parse_kinds(text: str | list | None) -> list[str]:
    """`user,warehouse` (or a list) as a checked list of kinds; `all` means every kind."""
    if not text:
        return []
    items = list(text) if isinstance(text, (list, tuple, set)) else str(text).split(",")
    kinds = [str(k).strip().lower() for k in items if str(k).strip()]
    if "all" in kinds:
        return list(MASK_KINDS)
    unknown = sorted(set(kinds) - set(MASK_KINDS))
    if unknown:
        raise ValueError(f"unknown mask kind(s): {', '.join(unknown)}; use {', '.join(MASK_KINDS)} or all")
    return [k for k in MASK_KINDS if k in kinds]


def _skip(kind: str, value: str) -> bool:
    v = value.strip()
    return (not v or _PLACEHOLDER_RE.match(v) is not None or v.upper() in _ALL_SYSTEM
            or _TOKEN_RE.match(v) is not None or (kind == "user" and _USER_MASKED_RE.match(v) is not None))


def _split_fqn(value: str) -> list[str]:
    """DB.SCHEMA."My.Table" -> ['DB', 'SCHEMA', '"My.Table"']: dots inside double quotes stay."""
    parts, cur, quoted = [], "", False
    for ch in value:
        if ch == '"':
            quoted = not quoted
        if ch == "." and not quoted:
            parts.append(cur)
            cur = ""
        else:
            cur += ch
    parts.append(cur)
    return parts


def _fqn_kinds(n: int, last: str) -> list[str]:
    if n >= 3:
        return ["database", "schema"] + [last] * (n - 2)
    if n == 2:
        return ["database", "schema"] if last == "schema" else ["schema", last]
    return [last]


def _split_list(value: str) -> list[str]:
    """'a, b,c' -> ['a', ', ', 'b', ',', 'c']: names and the separators between them, kept as they were."""
    return re.split(r"(\s*,\s*)", value)


class Masker:
    """The name -> token map for one export, filled from every file before any file is rewritten."""

    def __init__(self, kinds, salt: str | None = None):
        self.kinds = set(parse_kinds(kinds))
        self.salt = salt if salt is not None else secrets.token_hex(16)
        self.names: dict[str, dict[str, str]] = {k: {} for k in MASK_KINDS}  # kind -> {lower name: token}
        self._text_re = None
        self._text_map: dict[str, str] = {}

    # -- tokens -------------------------------------------------------------------------------
    def token(self, kind: str, value):
        if value is None or not isinstance(value, str) or kind not in self.kinds or _skip(kind, value):
            return value
        key = value.strip().lower()
        known = self.names[kind].get(key)
        if known:
            return known
        digest = hashlib.sha256(f"{self.salt}|{kind}|{key}".encode("utf-8")).hexdigest()[:8]
        tok = f"{digest} {value.strip()[:2]}***" if kind == "user" else f"{_PREFIX[kind]}_{digest}"
        self.names[kind][key] = tok
        return tok

    # -- which column holds what --------------------------------------------------------------
    def column_rule(self, name: str, columns: list[str]):
        """(handler, kind) for a column: 'one', 'list', 'fqn', 'grantee' or 'text'."""
        col = name.lower()
        if col in _GRANTEE_COLUMNS and any(t in columns for t in _GRANTEE_TYPE_COLUMNS):
            return "grantee", None
        if _PERSON_RE.match(col):
            return ("list" if col in _PERSON_LIST else "one"), "user"
        if col in _FQN_COLUMNS or _FQN_RE.search(col):
            return "fqn", _FQN_LAST_KIND.get(col, "schema" if col == "schema_fqn" else "object")
        for kind, cols in _KIND_COLUMNS.items():
            if col in cols:
                return "one", kind
        if _OWNER_RE.match(col) and col not in _NOT_OWNER:
            return "one", "role"
        for kind, cols in _LIST_COLUMNS.items():
            if col in cols:
                return "list", kind
        return "text", None

    def _grantee_kind(self, row_type) -> str | None:
        t = str(row_type or "").upper()
        return "user" if t == "USER" else "role" if t in ("ROLE", "DATABASE_ROLE") else None

    def cell(self, handler: str, kind, value, row_type=None):
        """One cell masked by its column's rule ('text' cells need the full map: see text())."""
        if value is None or not isinstance(value, str):
            return value
        if handler == "one":
            return self.token(kind, value)
        if handler == "list":
            return "".join(p if i % 2 else self.token(kind, p) for i, p in enumerate(_split_list(value)))
        if handler == "fqn":
            if ", " in value:  # a list of full names
                return ", ".join(self.cell("fqn", kind, v) for v in value.split(", "))
            parts = _split_fqn(value)
            if len(parts) >= 2 and parts[0].strip().upper() in _SYSTEM["database"]:
                return value  # a SNOWFLAKE.* view or function is Snowflake's, not the account's
            return ".".join(self.token(k, p) for p, k in zip(parts, _fqn_kinds(len(parts), kind)))
        if handler == "grantee":
            gk = self._grantee_kind(row_type)
            return self.token(gk, value) if gk else self.text(value)
        return self.text(value)

    # -- free text ----------------------------------------------------------------------------
    def freeze(self) -> None:
        """Build the free-text matcher from every name collected so far."""
        mapping: dict[str, str] = {}
        for kind in MASK_KINDS:  # a later kind wins when two kinds share a name
            for key, tok in self.names[kind].items():
                if len(key) >= _MIN_TEXT_LEN:
                    mapping[key] = tok
        self._text_map = mapping
        if mapping:
            alt = "|".join(re.escape(k) for k in sorted(mapping, key=len, reverse=True))
            self._text_re = re.compile(rf"(?<![{_WORD}])(?:{alt})(?![{_WORD}])", re.IGNORECASE)
        else:
            self._text_re = None

    def text(self, value):
        if value is None or not isinstance(value, str) or self._text_re is None:
            return value
        # Full names first, part by part; only names this export knows change, so a version
        # number or a SNOWFLAKE.* view stays as it is.
        value = _DOTTED_RE.sub(lambda m: self._known_fqn(m.group(1)), value)
        return self._text_re.sub(lambda m: self._text_map[m.group(0).lower()], value)

    def _known_fqn(self, text: str) -> str:
        parts = _split_fqn(text)
        if parts[0].strip().upper() in _SYSTEM["database"] or not self._known(parts[0], "database"):
            return text
        last = "task" if self._known(parts[-1], "task") and not self._known(parts[-1], "object") else "object"
        kinds = _fqn_kinds(len(parts), last)
        return ".".join(self.names[k].get(p.strip().lower(), p) if k in self.kinds else p for p, k in zip(parts, kinds))

    def _known(self, name: str, kind: str) -> bool:
        return name.strip().lower() in self.names[kind]

    # -- tables -------------------------------------------------------------------------------
    def collect(self, table: pa.Table) -> None:
        """Pass 1: learn every name in a table's name columns."""
        self._apply(table, collect_only=True)

    def mask_table(self, table: pa.Table) -> pa.Table:
        """Pass 2: the table with every text column masked (call freeze() first)."""
        return self._apply(table, collect_only=False)

    def _apply(self, table: pa.Table, collect_only: bool):
        names = table.column_names
        lower = [c.lower() for c in names]
        type_col = next((names[lower.index(t)] for t in _GRANTEE_TYPE_COLUMNS if t in lower), None)
        row_types = table.column(type_col).to_pylist() if type_col else None
        out = []
        for field in table.schema:
            col = table.column(field.name)
            if not (pa.types.is_string(field.type) or pa.types.is_large_string(field.type)):
                out.append(col)
                continue
            handler, kind = self.column_rule(field.name, lower)
            if collect_only and handler == "text":
                continue
            values = col.to_pylist()
            if handler == "grantee":
                masked = [self.cell(handler, kind, v, t) for v, t in zip(values, row_types or [None] * len(values))]
            else:
                cache: dict = {}
                masked = []
                for v in values:
                    if v not in cache:
                        cache[v] = self.cell(handler, kind, v)
                    masked.append(cache[v])
            if not collect_only:
                out.append(pa.array(masked, type=field.type))
        if collect_only:
            return None
        return pa.Table.from_arrays(out, schema=table.schema)

    def mask_json(self, obj):
        """A JSON-like object (the manifest) with names masked: name keys by their kind, the rest as text."""
        if isinstance(obj, dict):
            out = {}
            for k, v in obj.items():
                handler, kind = self.column_rule(str(k), [])
                out[k] = self.cell(handler, kind, v) if isinstance(v, str) and handler != "text" else self.mask_json(v)
            return out
        if isinstance(obj, list):
            return [self.mask_json(v) for v in obj]
        if isinstance(obj, str):
            return self.text(obj)
        return obj


def mask_folder(folder: Path, kinds, salt: str | None = None, manifest: dict | None = None) -> dict | None:
    """Mask every parquet file under folder in place, in two passes so a name seen in any file is
    masked in all of them, and return the manifest (when given) with the same names masked. Does
    nothing when kinds is empty. Write report.md from the returned manifest, never from the original."""
    kinds = parse_kinds(kinds)
    if not kinds:
        return manifest
    masker = Masker(kinds, salt)
    files = sorted(Path(folder).rglob("*.parquet"))
    for f in files:
        masker.collect(pq.read_table(f))
    if manifest is not None:
        # The manifest's account block names the account; learn it so free text masks it too.
        acct = manifest.get("account") or {}
        for key in ("id", "name", "account_name", "organization_name"):
            masker.token("account", acct.get(key))
    masker.freeze()
    for f in files:
        pq.write_table(masker.mask_table(pq.read_table(f)), f)
    return masker.mask_json(manifest) if manifest is not None else None
# ---- end of masking ----


# ---- the SQL -------------------------------------------------------------------------------


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


def run_all(cur, sqls: list[str], label: str) -> tuple[list[str], list[str]]:
    """Run the statements at once (async on a live session), each under the session's statement timeout.
    Returns the query ids that finished and the errors of those that did not. Rows are not fetched:
    they stay in Snowflake's result cache for RESULT_SCAN."""
    ids: list[str] = []
    errors: list[str] = []
    if not hasattr(cur, "execute_async"):
        for sql in sqls:
            try:
                cur.execute(sql)
                ids.append(cur.sfqid)
            except Exception as exc:  # noqa: BLE001 -- one statement failing drops only its own part
                errors.append(short(exc, 200))
        return ids, errors
    conn = cur.connection
    pending = []
    for sql in sqls:
        cur.execute_async(sql)
        pending.append(cur.sfqid)
    while pending:
        for sfqid in list(pending):
            try:
                running = conn.is_still_running(conn.get_query_status_throw_if_error(sfqid))
            except Exception as exc:  # noqa: BLE001 -- one statement failing drops only its own part
                errors.append(short(exc, 200))
                pending.remove(sfqid)
                continue
            if not running:
                ids.append(sfqid)
                pending.remove(sfqid)
        if pending:
            print(f"{label}: {len(ids) + len(errors)} of {len(sqls)} done", flush=True)
            time.sleep(5)
    return ids, errors


def run_query_feed(cur, ctx: dict, queries: Path) -> None:
    """Read the fallbacks' INFORMATION_SCHEMA query history once, as 28 six-hour slices run at once, and
    keep their query ids in ctx, so each fallback check reads them with RESULT_SCAN. A slice that fails
    or times out drops only its six hours; the checks that read the feed say how many are missing."""
    started = time.monotonic()
    text = (queries / "common" / "is_query_history_feed.sql").read_text(encoding="utf-8")
    # One fixed end for every slice; the oldest starts 5 minutes inside the 7-day limit when it runs.
    base = "'" + dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%d %H:%M:%S") + "'::TIMESTAMP_LTZ"
    sqls = []
    for i in range(QUERY_FEED_SLICES):
        start = f"DATEADD(hour, -{6 * (i + 1)}, {base})"
        if i == QUERY_FEED_SLICES - 1:
            start = f"GREATEST({start}, DATEADD(minute, -10075, CURRENT_TIMESTAMP()))"
        end = base if i == 0 else f"DATEADD(hour, -{6 * i}, {base})"
        sql = render(text.replace("__SLICE_START__", start).replace("__SLICE_END__", end),
                     days=7, params={}, ctx=ctx)
        assert_read_only(sql)
        sqls.append(sql)
    try:
        ids, errors = run_all(cur, sqls, "query history for the INFORMATION_SCHEMA fallbacks")
    except Exception as exc:  # noqa: BLE001 -- the fallback checks then read "role can't see" with this reason
        ids, errors = [], [short(exc, 200)]
    ctx["query_feed_ids"] = ids
    ctx["query_feed_missing"] = len(errors)
    if errors:
        ctx["query_feed_error"] = errors[0]
        print(f"warning: {len(errors)} of {QUERY_FEED_SLICES} six-hour slices of the INFORMATION_SCHEMA query "
              f"history failed: {errors[0]}", file=sys.stderr)
    print(f"query history for the INFORMATION_SCHEMA fallbacks: {len(ids)} of {QUERY_FEED_SLICES} six-hour "
          f"slices, {time.monotonic() - started:.1f}s", flush=True)


def query_feed_gap(ctx: dict) -> str | None:
    """The note a feed-reading fallback adds when some slices failed."""
    missing = ctx.get("query_feed_missing") or 0
    if not missing or not ctx.get("query_feed_ids"):
        return None
    return (f"{missing * 6} of the last 168 hours are missing (a six-hour slice of the query history "
            f"failed or timed out: {ctx.get('query_feed_error')})")


def render(text: str, *, days: int, params: dict, ctx: dict) -> str:
    """Fill :params and the __PLACEHOLDERS__ into one runnable statement."""
    values = dict(params, period_days=days)
    sql = _PARAM_RE.sub(lambda m: _literal(values[m.group(1)]) if m.group(1) in values else m.group(0), text)
    for key, value in {
        "__AS_OF_DATE__": f"CAST('{ctx['as_of_date']}' AS DATE)",
        "__ACCOUNT_ID__": _literal(ctx["account_id"]),
        "__CLOUD__": _literal(ctx["cloud"]),
        "__CREDIT_PRICE__": _literal(ctx.get("credit_price_usd")),
        "__AI_CREDIT_PRICE__": _literal(ctx.get("ai_credit_price_usd")),
        "__INFO_SCHEMA__": '"' + str(ctx.get("info_schema_db") or "").replace('"', '""') + '".INFORMATION_SCHEMA',
        "__STORAGE_PRICE_TB_MONTH__": _literal(ctx.get("storage_price_usd_tb_month")),
        # Task health checks leave out Snowflake's own tasks (SNOWFLAKE database).
        "__WITH_SNOWFLAKE_TASKS__": _literal(bool(ctx.get("include_snowflake_tasks", False))),
    }.items():
        sql = sql.replace(key, value)
    if QUERY_FEED_SCANS in sql:
        # The fallback's shared query feed ran before the checks, in slices; read them all.
        if not ctx.get("query_feed_ids"):
            raise StopExport("the INFORMATION_SCHEMA query history did not run: "
                             + str(ctx.get("query_feed_error") or "not started"))
        sql = sql.replace(QUERY_FEED_SCANS, " UNION ALL ".join(
            f"SELECT * FROM TABLE(RESULT_SCAN({_literal(i)}))" for i in ctx["query_feed_ids"]))
    leftover = _PARAM_RE.findall(_COMMENT_RE.sub("", sql))
    if leftover:
        raise StopExport(f"unresolved parameter(s): {sorted(set(leftover))}")
    return sql.strip().rstrip(";")


def assert_read_only(sql: str) -> None:
    """Refuse anything but one SELECT, WITH or SHOW statement."""
    body = _COMMENT_RE.sub("", sql).strip().rstrip(";")
    unquoted = re.sub(r"'(?:[^']|'')*'", "''", body)
    if not _READ_ONLY_RE.match(body) or ";" in unquoted:
        raise StopExport("refusing a statement that is not a single SELECT, WITH or SHOW")


def window_plan(days: int) -> list:
    """Each window label with the days it can use, e.g. 30 -> [(7,7),(30,30),(90,30)]."""
    return [(w, min(w, days)) for w in WINDOW_LABELS]


def window_sources(plan: list) -> list:
    """One (label, days) per distinct days value, at the smallest label that has it."""
    first: dict = {}
    for label, days in plan:
        first.setdefault(days, label)
    return [(label, days) for days, label in first.items()]


def window_aliases(plan: list) -> dict:
    source = {days: label for label, days in window_sources(plan)}
    return {label: source[days] for label, days in plan if source[days] != label}


# ---- talking to Snowflake ------------------------------------------------------------------


def load_env() -> dict:
    env = {k: v for k, v in os.environ.items() if k in ENV_VARS}
    dotenv = HERE / ".env"
    if dotenv.exists():
        for raw in dotenv.read_text(encoding="utf-8-sig").splitlines():
            key, sep, value = raw.strip().removeprefix("export ").partition("=")
            if sep and key.strip() in ENV_VARS and not env.get(key.strip()):
                env[key.strip()] = value.strip().strip("'\"")
    missing = [k for k in ("SNOWFLAKE_ACCOUNT", "SNOWFLAKE_USER") if not env.get(k)]
    if missing:
        raise StopExport("missing " + ", ".join(missing) + " (environment or .env next to this script)")
    return env


def connect(timeout_s: int, query_tag: str):
    import snowflake.connector

    env = load_env()
    kwargs = {
        "account": env["SNOWFLAKE_ACCOUNT"], "user": env["SNOWFLAKE_USER"],
        "role": env.get("SNOWFLAKE_ROLE"), "warehouse": env.get("SNOWFLAKE_WAREHOUSE"),
        "session_parameters": {"TIMEZONE": "UTC", "QUERY_TAG": query_tag,
                               "STATEMENT_TIMEOUT_IN_SECONDS": int(timeout_s)},
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


def normalise(table: pa.Table, renames: dict | None = None) -> pa.Table:
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


def run_show(cur, sql: str) -> None:
    """A SHOW that a check then reads with RESULT_SCAN; never fetched here."""
    assert_read_only(sql)
    cur.execute(sql)


def run_sql(cur, sql: str, name: str = "") -> pa.Table:
    assert_read_only(sql)
    cur.execute(sql)
    table = cur.fetch_arrow_all()
    if table is None:
        table = pa.table({d[0]: pa.array([], pa.null()) for d in cur.description or []})
    return normalise(table, UPPER_CASE_COLUMNS.get(name, {}))


def error_code(exc: Exception) -> str | None:
    code = getattr(exc, "errno", None) or getattr(exc, "sqlstate", None)
    return str(code) if code else None


def short(exc: Exception, limit: int = 160) -> str:
    return " ".join(str(exc).split())[:limit]


def normalise_edition(value) -> str | None:
    text = re.sub(r"[\s-]+", "_", str(value or "").strip().upper())
    if text in ("VPS", "VIRTUAL_PRIVATE_SNOWFLAKE"):
        return "VIRTUAL_PRIVATE_SNOWFLAKE"
    return text if text in EDITION_RANK else None


def detect_edition(cur) -> dict:
    """The edition from ORGANIZATION_USAGE.ACCOUNTS, else "at least Enterprise" from features only it has."""
    try:
        rows = run_sql(cur, "SELECT edition FROM SNOWFLAKE.ORGANIZATION_USAGE.ACCOUNTS "
                            "WHERE account_locator = CURRENT_ACCOUNT() AND deleted_on IS NULL").to_pylist()
        edition = normalise_edition(next((r.get("edition") for r in rows if r.get("edition")), None))
        if edition:
            return {"edition": edition, "source": "organization_usage.accounts", "evidence": []}
    except Exception:  # noqa: BLE001 -- no ORGADMIN access is normal
        pass
    evidence = []
    probes = (
        ("multi-cluster warehouse", "SELECT COUNT(*) AS n FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_EVENTS_HISTORY "
                                   "WHERE cluster_number > 1 AND timestamp >= DATEADD(day, -30, CURRENT_TIMESTAMP())"),
        ("masking policy", "SELECT COUNT(*) AS n FROM SNOWFLAKE.ACCOUNT_USAGE.MASKING_POLICIES WHERE deleted IS NULL"),
        ("time travel above 1 day", "SELECT COUNT(*) AS n FROM SNOWFLAKE.ACCOUNT_USAGE.TABLES "
                                    "WHERE retention_time > 1 AND deleted IS NULL"),
    )
    for name, sql in probes:
        try:
            if next(iter(run_sql(cur, sql).to_pylist()[0].values()), 0):
                evidence.append(name)
        except Exception:  # noqa: BLE001 -- a probe the role cannot read proves nothing
            continue
    if evidence:
        return {"edition": "ENTERPRISE", "source": "feature_evidence", "evidence": evidence}
    return {"edition": None, "source": None, "evidence": []}


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
    """Effective USD per credit, per AI credit and per TB-day over 90 days of priced consumption
    (no overage or fees). The view stores rating and billing types in upper case."""
    day = as_of.isoformat()
    return f"""
SELECT CASE LOWER(rating_type) WHEN 'ai_compute' THEN 'ai' ELSE LOWER(rating_type) END AS usage_kind,
       SUM(usage_in_currency) / NULLIF(SUM(usage), 0) AS rate,
       SUM(usage) AS usage, COUNT(DISTINCT usage_date) AS days
FROM SNOWFLAKE.ORGANIZATION_USAGE.USAGE_IN_CURRENCY_DAILY
WHERE account_locator = {_literal(account_locator)} AND currency = 'USD'
  AND usage_date >= DATEADD(day, -90, CAST('{day}' AS DATE)) AND usage_date < CAST('{day}' AS DATE)
  AND LOWER(rating_type) IN ('compute', 'storage', 'ai_compute') AND LOWER(billing_type) = 'consumption'
  AND COALESCE(is_adjustment, FALSE) = FALSE
  AND COALESCE(LOWER(balance_source), '') <> 'overage'
  AND (LOWER(rating_type) = 'ai_compute' OR NOT REGEXP_LIKE(COALESCE(service_type, ''), '(^|_)(AI|CORTEX)(_|$)'))
GROUP BY 1
"""


def account_context(cur, *, as_of: dt.date, credit_price, storage_price, ai_credit_price=None,
                    defaults: dict | None = None) -> dict:
    """Account, cloud, and the prices: each is the command line, else the invoice view, else the kit's
    defaults, else unpriced."""
    defaults = defaults or {}
    row = run_sql(cur, "SELECT CURRENT_ACCOUNT() AS a, CURRENT_REGION() AS r, "
                       "CURRENT_ACCOUNT_NAME() AS n, CURRENT_ORGANIZATION_NAME() AS o").to_pylist()[0]
    region = (row.get("r") or "").upper()
    cloud = next((c for c in ("AWS", "AZURE", "GCP") if region.rsplit(".", 1)[-1].startswith(c)), None)
    prices = {"credit": [credit_price, "cli" if credit_price is not None else None],
              "storage": [storage_price, "cli" if storage_price is not None else None],
              "ai": [ai_credit_price, "cli" if ai_credit_price is not None else None]}
    by_type: dict = {}
    sheet: dict = {}
    if any(v[0] is None for v in prices.values()):
        try:
            rates = run_sql(cur, org_rate_sql(row["a"], as_of)).to_pylist()
        except Exception as exc:  # noqa: BLE001 -- no ORGADMIN access is normal
            print(f"note: no org billing access ({short(exc, 120)}); using the kit's default prices", file=sys.stderr)
            rates = []
        by_type = {r.get("usage_kind"): r for r in rates if r.get("rate") is not None}
        try:
            sheet = {r.get("usage_kind"): r for r in run_sql(cur, rate_sheet_sql(row["a"], as_of)).to_pylist()
                     if r.get("rate") is not None}
        except Exception:  # noqa: BLE001 -- the rate sheet is optional; the invoice average stands
            sheet = {}
    invoice = {"credit": "compute", "storage": "storage", "ai": "ai"}
    default = {"credit": "credit_price_usd", "storage": "storage_price_usd_tb_month", "ai": "ai_credit_price_usd"}
    for key, slot in prices.items():
        if slot[0] is not None:
            continue
        found = by_type.get(invoice[key])
        if key != "storage" and sheet.get(invoice[key]) is not None:
            slot[:] = [float(sheet[invoice[key]]["rate"]), "rate_sheet_daily"]
        elif found is not None:
            rate = float(found["rate"])
            slot[:] = [rate * DAYS_PER_MONTH if key == "storage" else rate, "usage_in_currency_daily"]
        elif defaults.get(default[key]):
            slot[:] = [float(defaults[default[key]]), "settings"]
    return {"account_id": row["a"], "account_name": row.get("n") or row["a"], "true_account_name": row.get("n"),
            "organization_name": row.get("o"), "region": region, "cloud": cloud, "as_of_date": as_of.isoformat(),
            "credit_price_usd": prices["credit"][0], "price_source": prices["credit"][1],
            "storage_price_usd_tb_month": prices["storage"][0], "storage_price_source": prices["storage"][1],
            "ai_credit_price_usd": prices["ai"][0], "ai_price_source": prices["ai"][1],
            "rate_basis": {k: {"days": v.get("days"), "usage": v.get("usage")} for k, v in by_type.items()} or None}


def info_schema_db(cur) -> str | None:
    """A database whose INFORMATION_SCHEMA the role can call table functions from: the session's own,
    else the first one SHOW DATABASES lists outside SNOWFLAKE."""
    try:
        cur.execute("SELECT CURRENT_DATABASE()")
        current = cur.fetchone()[0]
        if current:
            return current
        cur.execute("SHOW TERSE DATABASES")
        names = [r[1] for r in cur.fetchall()]
    except Exception:  # noqa: BLE001 -- no database to use means no fallback
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


def fallback_blocked(head: dict, ctx: dict) -> str | None:
    """Why a fallback cannot give a true answer for this role, or None. A table function that needs
    MONITOR USAGE returns no rows without it, which would read as "nothing found"."""
    if "MONITOR USAGE" in head.get("needs", "").upper() and not ctx.get("monitor_usage"):
        return (f"role_cannot_see: the INFORMATION_SCHEMA fallback ({head.get('reads')}) needs ACCOUNTADMIN "
                f"or the MONITOR USAGE privilege, and returns nothing without it")
    return None


def probe_visibility(cur, checks: dict, *, as_of: dt.date) -> dict:
    """Which views and SHOW commands the role can read (LIMIT 0), and warehouses SHOW leaves out."""
    views = sorted({src for c in checks.values() for src in c["sources"] if src.split(".")[0] in VIEW_SCHEMAS})
    shows = sorted({stmt for c in checks.values() for stmt in c["pre"]})
    out = {"probed": len(views) + len(shows), "unreadable": {}, "failed_pre": {}, "warehouses": None}
    for src in views:
        try:
            cur.execute(f"SELECT 1 FROM SNOWFLAKE.{src} LIMIT 0")
        except Exception as exc:  # noqa: BLE001 -- any error means the check cannot read it
            code = error_code(exc)
            out["unreadable"][src] = f"{short(exc)} (error {code})" if code else short(exc)
    for stmt in shows:
        try:
            run_show(cur, stmt)
        except Exception as exc:  # noqa: BLE001
            out["failed_pre"][stmt] = short(exc)
    if not any("SHOW WAREHOUSES" in s.upper() for s in out["failed_pre"]) and \
            "ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY" not in out["unreadable"]:
        try:
            run_show(cur, "SHOW WAREHOUSES")
            row = run_sql(cur, f"""
SELECT COUNT(DISTINCT m.warehouse_name) AS metered,
       COUNT(DISTINCT IFF(s."name" IS NULL, m.warehouse_name, NULL)) AS missing_from_show
FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY m
LEFT JOIN TABLE(RESULT_SCAN(LAST_QUERY_ID())) s ON s."name" = m.warehouse_name
WHERE m.start_time >= DATEADD(day, -30, CAST('{as_of.isoformat()}' AS DATE))
  AND m.start_time < CAST('{as_of.isoformat()}' AS DATE)
  AND m.warehouse_name <> 'CLOUD_SERVICES_ONLY'""").to_pylist()[0]
            out["warehouses"] = {"metered": row["metered"], "missing_from_show": row["missing_from_show"]}
        except Exception as exc:  # noqa: BLE001 -- advice only
            print(f"note: warehouse visibility probe failed ({short(exc, 100)})", file=sys.stderr)
    return out


# ---- the export ----------------------------------------------------------------------------


def blank_unflagged_waste(table: pa.Table) -> pa.Table:
    """NULL the waste and saving $ on rows that are not WARN or CRITICAL, so sums count flagged rows only."""
    if "status" not in table.column_names:
        return table
    flagged = [str(v or "").upper() in ("WARN", "CRITICAL") for v in table.column("status").to_pylist()]
    for name in table.column_names:
        if _WASTE_COLUMN_RE.search(name):
            idx = table.column_names.index(name)
            values = [v if keep else None for v, keep in zip(table.column(name).to_pylist(), flagged)]
            table = table.set_column(idx, name, pa.array(values, type=table.schema.field(name).type))
    return table


def _labelled(table: pa.Table, label: int) -> pa.Table:
    if "window_days" in table.column_names:
        idx = table.column_names.index("window_days")
        table = table.set_column(idx, "window_days", pa.array([label] * table.num_rows, pa.int32()))
    return table


def run_windows(cur, name: str, text: str, *, labels_days, params, pre, ctx, max_rows, check: bool):
    tables, truncated = [], []
    for label, days in labels_days:
        for stmt in pre:
            run_show(cur, stmt)
        sql = render(text, days=days, params=params, ctx=ctx)
        table = run_sql(cur, f"{sql}\nLIMIT {int(max_rows) + 1}", name)
        if table.num_rows > max_rows:
            table, truncated = table.slice(0, max_rows), truncated + [label]
        table = _labelled(table, label)
        tables.append(blank_unflagged_waste(table) if check else table)
    return pa.concat_tables(tables, promote_options="permissive"), truncated


def not_assessed_rows(table: pa.Table) -> int:
    if "status" not in table.column_names:
        return 0
    return sum(1 for v in table.column("status").to_pylist() if str(v or "").upper() == "NOT_ASSESSED")


def _skipped(reason: str, cause: str, error: str, domain: str, unreadable=None) -> dict:
    return {"status": "not_assessed", "exported_rows": None, "truncated": False, "truncated_windows": [],
            "columns": None, "not_assessed_rows": None, "not_assessed_reason": reason, "cause": cause,
            "unreadable": unreadable or [], "error": error[:500], "duration_s": 0.0, "domain": domain}


def _md(text, limit: int = 120) -> str:
    s = (text or "").replace("|", "\\|").replace("\n", " ")
    return s[:limit - 3] + "..." if len(s) > limit else s


def render_report(manifest: dict) -> str:
    """report.md: failed first, then not assessed, then the rest."""
    order = {"failed": 0, "not_assessed": 1}
    entries = sorted(manifest["findings"].items(), key=lambda kv: (order.get(kv[1]["status"], 2), kv[0]))
    counts: dict = {}
    for _, f in entries:
        counts[f["status"]] = counts.get(f["status"], 0) + 1
    pricing = manifest["pricing"]
    price = (f"${pricing['credit_price_usd']:.4g} per credit ({pricing['source']})"
             if pricing.get("credit_price_usd") is not None else "no credit price: $ columns are empty")
    vis = manifest["visibility"]
    lines = ["# Snowflake export report", "",
             f"days: {manifest['days']}  as of: {manifest['as_of_date']}  exported: {manifest['as_of']}",
             f"price: {price}  edition: {manifest['edition'].get('edition') or 'unknown'}", "",
             f"**{len(entries)} checks** -- " + ", ".join(f"{k}: {v}" for k, v in sorted(counts.items())), "",
             f"role visibility: {vis['probed']} sources probed, "
             f"{len(vis['unreadable']) + len(vis['failed_pre'])} unreadable"]
    lines += [f"- cannot read {s}: {_md(m, 140)}" for s, m in vis["unreadable"].items()]
    lines += [f"- cannot run {s}: {_md(m, 140)}" for s, m in vis["failed_pre"].items()]
    if manifest.get("stopped_early"):
        lines += ["", "**The export was stopped before the end**: the checks marked not run have no data."]
    failed = [(qid, f) for qid, f in entries if f["status"] == "failed"]
    other = {**{f"tag source {k}": v for k, v in manifest["tag_sources"]["failed"].items()},
             **{f"dim {k}": v for k, v in (manifest.get("dims_failed") or {}).items()}}
    if failed or other:
        # The full error, so a syntax error or a missing table can be fixed from this file alone.
        lines += ["", f"## Errors ({len(failed)} checks, {len(other)} other)", ""]
        lines += [f"- **{qid}** [{f.get('error_code') or '-'}]: {' '.join((f.get('error') or '').split())}"
                  for qid, f in failed]
        lines += [f"- **{k}**: {' '.join((v or '').split())}" for k, v in other.items()]
    lines += ["", "## All checks", "", "| check | status | rows | seconds | error |", "|---|---|---|---|---|"]
    for qid, f in entries:
        lines.append(f"| {qid} | {f['status']} | {f.get('exported_rows')} | {f.get('duration_s')} | {_md(f.get('error'))} |")
    return "\n".join(lines) + "\n"


def run_export(out_dir: Path, *, windows: int = 30, max_rows: int | None = None, credit_price=None,
               storage_price=None, ai_credit_price=None, use_fallbacks: bool = False, only=None, include_today: bool | None = None, timeout_s: int = 900,
               connect_fn=None, now: dt.datetime | None = None, queries: Path = QUERIES,
               mask=None, mask_salt: str | None = None) -> dict:
    """Run every check, tag source and dim into out_dir; one failure is recorded and the rest go on.
    `mask` lists the kinds of names to replace with tokens before the manifest and report are written."""
    try:
        mask = parse_kinds(mask)
    except ValueError as exc:
        raise StopExport(str(exc)) from exc
    index = json.loads((queries / "index.json").read_text(encoding="utf-8"))
    defaults = index["defaults"]
    max_rows = int(max_rows or defaults["max_rows"])
    include_today = defaults["include_today"] if include_today is None else include_today
    now = now or dt.datetime.now(dt.timezone.utc)
    # The first day left out: tomorrow when today's partial day is kept, else the day after the last full one.
    as_of = (now + dt.timedelta(days=1) if include_today else now - dt.timedelta(hours=LAG_HOURS)).date()
    checks = index["checks"]
    if only:
        unknown = sorted(set(only) - set(checks))
        if unknown:
            raise StopExport(f"no check called: {unknown}")
        checks = {q: checks[q] for q in only}
    plan = window_plan(int(windows))
    sources = window_sources(plan)

    work = out_dir.with_name(out_dir.name + ".tmp")
    if work.exists():
        shutil.rmtree(work)
    for sub in ("findings", "dims", "tags_src"):
        (work / sub).mkdir(parents=True)
    try:
        conn = (connect_fn or (lambda: connect(timeout_s, defaults["query_tag"])))()
        cur = conn.cursor()
    except StopExport:
        raise
    except Exception as exc:  # noqa: BLE001 -- sign-in: one line, never a traceback
        raise StopExport(f"could not sign in: {type(exc).__name__} {error_code(exc) or ''} {short(exc, 200)}") from exc
    try:
        try:
            ctx = account_context(cur, as_of=as_of, credit_price=credit_price, storage_price=storage_price,
                                  ai_credit_price=ai_credit_price, defaults=defaults)
        except Exception as exc:  # noqa: BLE001
            raise StopExport(f"the session cannot run a query (check SNOWFLAKE_WAREHOUSE and the role): "
                             f"{short(exc, 200)}") from exc
        visibility = probe_visibility(cur, checks, as_of=as_of)
        edition = detect_edition(cur)
        known = normalise_edition(edition["edition"])
        below_enterprise = known is not None and EDITION_RANK[known] < EDITION_RANK["ENTERPRISE"]
        ctx["info_schema_db"] = info_schema_db(cur) if any(m.get("fallback") for m in checks.values()) else None
        ctx["monitor_usage"] = has_monitor_usage(cur, ctx) if ctx["info_schema_db"] else False
        if ctx["info_schema_db"] and any(
                (m.get("fallback") or {}).get("query_feed")
                and (use_fallbacks or any(s in visibility["unreadable"] for s in m["sources"]))
                for m in checks.values()):
            run_query_feed(cur, ctx, queries)
        findings: dict = {}
        stopped = False
        for i, (qid, meta) in enumerate(checks.items(), start=1):
            if stopped:
                findings[qid] = {"status": "failed", "exported_rows": None, "truncated": False,
                                 "truncated_windows": [], "columns": None, "not_assessed_rows": None,
                                 "error": "not run: the export was stopped before this check",
                                 "duration_s": 0.0, "domain": meta["domain"]}
                continue
            started = time.monotonic()
            blocked = [s for s in meta["sources"] if s in visibility["unreadable"]]
            blocked += [s for s in meta["pre"] if s in visibility["failed_pre"]]
            if below_enterprise and meta["needs_enterprise"]:
                findings[qid] = _skipped("edition_too_low", "edition_too_low",
                                         f"edition_too_low: needs Enterprise Edition or higher; this account is "
                                         f"{edition['edition']}", meta["domain"])
            elif (blocked or use_fallbacks) and meta.get("fallback") and ctx.get("info_schema_db"):
                # The role cannot read ACCOUNT_USAGE here: read the same check from INFORMATION_SCHEMA.
                fb = meta["fallback"]
                head = {"needs": fb.get("needs") or "", "reads": fb.get("reads")}
                note = fb.get("note")
                if fb.get("query_feed") and query_feed_gap(ctx):
                    note = f"{note}; {query_feed_gap(ctx)}"
                try:
                    if fallback_blocked(head, ctx):
                        raise StopExport(fallback_blocked(head, ctx))
                    text = (queries / "fallback" / f"{qid}.sql").read_text(encoding="utf-8")
                    table, truncated = run_windows(
                        cur, qid, text, labels_days=sources if meta["windowed"] else [(0, int(windows))],
                        params=meta["params"], pre=fb["pre"], ctx=ctx, max_rows=max_rows, check=True)
                    pq.write_table(table, work / "findings" / f"{qid}.parquet")
                    entry = {"status": "ok" if table.num_rows else "empty", "exported_rows": table.num_rows,
                             "truncated": bool(truncated), "truncated_windows": truncated,
                             "columns": table.column_names, "not_assessed_rows": not_assessed_rows(table),
                             "error": None}
                except KeyboardInterrupt:
                    # Ctrl+C: keep what ran, mark the rest not run, and still write the report.
                    stopped = True
                    print("stopped: writing the report for the checks that ran", file=sys.stderr)
                    entry = {"status": "failed", "exported_rows": None, "truncated": False,
                             "truncated_windows": [], "columns": None, "not_assessed_rows": None,
                             "error": "not run: the export was stopped during this check"}
                except Exception as exc:  # noqa: BLE001 -- the fallback failing reads as the role gap
                    entry = _skipped("role_cannot_see", "no_access", fallback_blocked(head, ctx) or
                                     f"role_cannot_see; the INFORMATION_SCHEMA fallback failed too: {short(exc, 300)}",
                                     meta["domain"], blocked)
                entry.update({"source": "information_schema", "source_reads": fb.get("reads"),
                              "source_note": note, "unreadable": blocked,
                              "duration_s": round(time.monotonic() - started, 3), "domain": meta["domain"]})
                findings[qid] = entry
            elif blocked:
                why = {**visibility["unreadable"], **visibility["failed_pre"]}
                findings[qid] = _skipped("role_cannot_see", "no_access", "role_cannot_see: " + "; ".join(
                    f"{s}: {why.get(s, 'unreadable')}" for s in blocked), meta["domain"], blocked)
            else:
                try:
                    text = (queries / "checks" / f"{qid}.sql").read_text(encoding="utf-8")
                    table, truncated = run_windows(
                        cur, qid, text, labels_days=sources if meta["windowed"] else [(0, int(windows))],
                        params=meta["params"], pre=meta["pre"], ctx=ctx, max_rows=max_rows, check=True)
                    pq.write_table(table, work / "findings" / f"{qid}.parquet")
                    findings[qid] = {"status": "ok" if table.num_rows else "empty", "exported_rows": table.num_rows,
                                     "truncated": bool(truncated), "truncated_windows": truncated,
                                     "columns": table.column_names, "not_assessed_rows": not_assessed_rows(table),
                                     "error": None}
                except KeyboardInterrupt:
                    # Ctrl+C: keep what ran, mark the rest not run, and still write the report.
                    stopped = True
                    print("stopped: writing the report for the checks that ran", file=sys.stderr)
                    findings[qid] = {"status": "failed", "exported_rows": None, "truncated": False,
                                     "truncated_windows": [], "columns": None, "not_assessed_rows": None,
                                     "error": "not run: the export was stopped during this check"}
                except Exception as exc:  # noqa: BLE001 -- one check's failure must not stop the rest
                    # No cause here: the app's loader classifies the error text itself.
                    findings[qid] = {"status": "failed", "exported_rows": None, "truncated": False,
                                     "truncated_windows": [], "columns": None, "not_assessed_rows": None,
                                     "error": f"{type(exc).__name__}: {exc}"[:500], "error_code": error_code(exc)}
                findings[qid]["duration_s"] = round(time.monotonic() - started, 3)
                findings[qid]["domain"] = meta["domain"]
            f = findings[qid]
            detail = (f"failed [{f.get('error_code') or '-'}]" if f["status"] == "failed"
                      else f"not assessed ({f.get('not_assessed_reason')})" if f["status"] == "not_assessed"
                      else f"{f['status']}, {f['exported_rows']} rows")
            print(f"[{i}/{len(checks)}] {qid}: {detail}, {f['duration_s']}s", flush=True)

        tags_ok, tags_failed, tags_cut, dims_ok, dims_failed = [], {}, [], [], {}
        for name, windowed in ({} if stopped else index["tag_sources"]).items():
            try:
                text = (queries / "tag_sources" / f"{name}.sql").read_text(encoding="utf-8")
                table, cut = run_windows(cur, name, text, labels_days=sources if windowed else [(0, int(windows))],
                                         params={}, pre=[], ctx=ctx, max_rows=max_rows, check=False)
                pq.write_table(table, work / "tags_src" / f"{name}.parquet")
                tags_ok.append(name)
                if cut:
                    tags_cut.append(name)
                    print(f"warning: tag source {name} was cut at {max_rows} rows; spend by tag can read low", file=sys.stderr)
            except KeyboardInterrupt:
                stopped = True
                break
            except Exception as exc:  # noqa: BLE001 -- a missing source only leaves the tag pages empty
                tags_failed[name] = str(exc)[:300]
                print(f"warning: tag source {name} failed: {short(exc, 200)}", file=sys.stderr)
        for name in index["dims"]:
            if stopped:
                break
            try:
                text = (queries / "dims" / f"{name}.sql").read_text(encoding="utf-8")
                pq.write_table(run_sql(cur, render(text, days=int(windows), params={}, ctx=ctx)),
                               work / "dims" / f"{name}.parquet")
                dims_ok.append(name)
            except KeyboardInterrupt:
                stopped = True
                break
            except Exception as exc:  # noqa: BLE001 -- the app falls back to a stub
                dims_failed[name] = str(exc)[:300]
                print(f"warning: dim {name} failed: {short(exc, 200)}", file=sys.stderr)
    finally:
        try:
            conn.close()
        except Exception:  # noqa: BLE001 -- a dropped connection must not lose the results
            pass

    manifest = {
        "tool": "run_export.py", "tool_version": TOOL_VERSION, "git_commit": index.get("git_commit"),
        "as_of": now.strftime("%Y-%m-%dT%H:%M:%SZ"), "as_of_date": as_of.isoformat(),
        "includes_today": bool(include_today), "mode": "query",
        "last_complete_day": ((now - dt.timedelta(hours=LAG_HOURS)).date() - dt.timedelta(days=1)).isoformat(),
        "export_date": now.date().isoformat(), "lag_hours": LAG_HOURS, "visibility": visibility,
        "edition": edition, "statement_timeout_s": int(timeout_s),
        "monitor_usage": ctx.get("monitor_usage"),
        "windows": [w for w, _ in plan], "window_coverage": {str(w): d for w, d in plan},
        "window_aliases": {str(a): str(s) for a, s in window_aliases(plan).items()}, "days": int(windows),
        "account": {"id": ctx["account_id"], "name": ctx["account_name"], "account_name": ctx["true_account_name"],
                    "organization_name": ctx["organization_name"], "cloud": ctx["cloud"], "region": ctx["region"]},
        "pricing": {"source": ctx["price_source"], "credit_price_usd": ctx["credit_price_usd"],
                    "storage_price_usd_tb_month": ctx["storage_price_usd_tb_month"],
                    "storage_source": ctx["storage_price_source"],
                    "ai_credit_price_usd": ctx["ai_credit_price_usd"], "ai_source": ctx["ai_price_source"],
                    "rate_basis": ctx["rate_basis"]},
        "max_rows": max_rows, "masked": mask, "include_snowflake_tasks": bool(ctx.get("include_snowflake_tasks")),
        "findings": dict(sorted(findings.items())),
        "dims": {"available": dims_ok}, "dims_failed": dims_failed, "stopped_early": stopped,
        "tag_sources": {"available": tags_ok, "failed": tags_failed, "truncated": tags_cut},
    }
    manifest = mask_folder(work, mask, mask_salt, manifest)
    (work / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    (work / "report.md").write_text(render_report(manifest), encoding="utf-8")
    if out_dir.exists():
        shutil.rmtree(out_dir)
    os.rename(work, out_dir)
    return manifest


def main(argv=None) -> int:
    p = argparse.ArgumentParser(description="Run the Snowflake audit SQL and write parquet files.")
    p.add_argument("--out", type=Path, default=Path("sf-audit-out"), help="output folder (default sf-audit-out)")
    p.add_argument("--windows", type=int, default=30, help="days of history (default 30; 90 fills every window)")
    p.add_argument("--credit-price", type=float, help="USD per credit, when the org billing view is not readable")
    p.add_argument("--ai-credit-price", type=float, help="USD per AI credit (Cortex, Copilot), same")
    p.add_argument("--use-fallbacks", action="store_true",
                   help="read the checks that have one from INFORMATION_SCHEMA even when ACCOUNT_USAGE is readable")
    p.add_argument("--storage-price", type=float, help="USD per TB-month of storage")
    p.add_argument("--only", nargs="+", help="run just these check ids")
    p.add_argument("--max-rows", type=int, help="rows kept per check and window")
    p.add_argument("--statement-timeout", type=int, default=900, metavar="SECONDS",
                   help="cancel any one statement after this long (default %(default)s)")
    p.add_argument("--no-zip", action="store_true", help="skip writing <out>.zip")
    p.add_argument("--mask", metavar="KINDS", help="replace these kinds of names with tokens, comma-separated: "
                   + ", ".join(MASK_KINDS) + " or all")
    p.add_argument("--mask-salt", metavar="TEXT", help="salt for the tokens, to keep them the same across runs")
    args = p.parse_args(argv)
    try:
        manifest = run_export(args.out, windows=args.windows, max_rows=args.max_rows,
                              credit_price=args.credit_price, storage_price=args.storage_price,
                              ai_credit_price=args.ai_credit_price, use_fallbacks=args.use_fallbacks,
                              only=args.only, timeout_s=max(args.statement_timeout, 1),
                              mask=args.mask, mask_salt=args.mask_salt)
    except StopExport as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1
    counts: dict = {}
    for f in manifest["findings"].values():
        counts[f["status"]] = counts.get(f["status"], 0) + 1
    print(f"wrote {args.out}: " + ", ".join(f"{n} {s}" for s, n in sorted(counts.items())))
    if manifest["pricing"]["credit_price_usd"] is None:
        print("note: no credit price, so $ columns are empty; run again with --credit-price", file=sys.stderr)
    if not args.no_zip:
        zipped = shutil.make_archive(str(args.out), "zip", root_dir=args.out.parent, base_dir=args.out.name)
        print(f"send back: {zipped}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
