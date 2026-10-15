"""app/core/data.py

Read-only DuckDB store. Every public function opens a short-lived
`duckdb.connect(db_path, read_only=True)` connection and closes it before returning (or shares one
read-only connection per db file when `share_connection` is on, the API server's mode), so a
refresh can swap the db file out from under a running app. AUDIT_DB and AUDIT_RUN_RESULTS are
re-read from os.environ on every call, never cached at import time.

DuckDB does the work, pandas only holds the displayed slice: every filter, the ORDER BY and the row
cap are pushed into the SQL text with bound parameters; a separate `SELECT count(*)` (same
filters, no LIMIT) supplies `rows_total`. MAP/STRUCT/LIST columns are selected as `to_json(col)`.

The check tables carry the Snowflake account locator in an `account_id` column and dims.dim_account holds one row per account, so the filters, the env
classification and the tag rollup keep one code path for a single account or an organization.

    read_finding(query_id, window_days, account_ids=None, env=None, tag=None, limit=None,
                 attributes=None, job_id=None, statuses=None, *, tag_filter=None, owner=None)
                 -> FindingResult          rows in export order, worst status first
    count_finding(...) -> int / count_finding_ex(...) -> (int, TagApplication)
    finding_window_counts(specs, ...) -> dict[query_id, dict]   bulk counts, one connection
    aggregate_finding(query_id, window_days, group, agg, value=None, ...) -> AggregateResult
                 server-side GROUP BY over every matching row (no LIMIT before aggregating)
    read_dim_account() / read_dim_warehouse() / read_dim_task() -> pandas.DataFrame
    db_state() -> dict           never raises: "no_database" | "build_incomplete" | "ready"
    run_results() -> dict        per-check ok / failed from the loader's run_results sidecar
    direct_export_info() -> dict | None   as_of, as_of_date, includes_today, window coverage
    exported_window_coverage() / window_status(choices) / window_coverage(query_id, window_days)
    truncation_info(query_id, window_days=None) -> dict
    fallback_sources() -> dict
    finding_status(query_id) / not_assessed_status(spec, ...) / checks_not_ok(specs, ...)
    finding_columns(query_id) / finding_columns_batch(query_ids)
    cost_cutoff() -> dict        the one money cut-off: complete days, today partial

query_id is never string-formatted into a filter VALUE: every bound value is a duckdb bind
parameter. query_id itself names a table (`findings."f_<qid>"`), so it must match the charset every
real query_id uses and resolve through app/core/registry.by_id before it is spliced into SQL text.
Column identifiers (group, value, tag attribute keys) are checked against the table's own columns
or config before they are spliced.

Stdlib + duckdb + pandas.
"""
from __future__ import annotations

import copy
import functools
import json
import os
import re
import sys
import threading
from dataclasses import dataclass, field
from datetime import date, datetime, timedelta
from pathlib import Path

import duckdb
import pandas as pd

_ROOT = Path(__file__).resolve().parent.parent.parent
if str(_ROOT) not in sys.path:
    sys.path.insert(0, str(_ROOT))

from app.core import config as app_config  # noqa: E402
from app.core import cost_center as app_cost_center  # noqa: E402  -- lazy-imports this module back
from app.core import datasource  # noqa: E402
from app.core import finding_columns as app_finding_columns  # noqa: E402
from app.core import materiality as app_materiality  # noqa: E402
from app.core import reasons as app_reasons  # noqa: E402
from app.core import registry  # noqa: E402
from app.core import tags as app_core_tags  # noqa: E402  -- tags.py imports this module
from app.core import tag_spend as app_tag_spend  # noqa: E402
                                                            # back only lazily, see its own note

ROOT = _ROOT

_QUERY_ID_RE = re.compile(r"[a-z][a-z0-9_]*")

class FindingNotBuiltError(RuntimeError):
    """findings.f_<query_id> does not exist in the current db_path -- the model failed, was
    skipped, or the db just has not been (re)built yet. Callers render the NOT_ASSESSED card
 instead of crashing; call finding_status(query_id) to find out why."""


@dataclass
class FindingResult:
    df: pd.DataFrame
    rows_total: int
    applicability: dict  # {"has_account_id": bool, "has_tag": bool, "has_job_id": bool}
    # Materiality floor: how many of THESE rows_total rows have their floor column under `min` --
    # 0 when the query has no configured floor or the table does not carry its column (never
    # computed in that case, no extra query run). app/api/service.py's own "floor" field.
    rows_below_floor: int = 0
    # None when no workspace/env/attribute filter applies (or the check is not workspace-
    # filterable), else {"rows": N} -- rows the filter left out for having no resolvable
    # workspace (account_id NULL/'0', or a warehouse/cluster missing from the dims).
    excluded_no_account: dict | None = None


# ---------------------------------------------------------------------------------------------
# Env-var resolution
# ---------------------------------------------------------------------------------------------


def _db_path() -> Path:
    """AUDIT_DB, else the pointer a refresh last wrote (datasource.current_db(), so a restart
    keeps serving what refresh built), else the data folder's own db. First match wins."""
    env = os.environ.get("AUDIT_DB")
    if env:
        return Path(env)
    current = datasource.current_db()
    if current is not None:
        return current
    return datasource.db_path()


def _run_results_path() -> Path:
    env = os.environ.get("AUDIT_RUN_RESULTS")
    return Path(env) if env else datasource.sidecar(_db_path(), "run_results")


# The API server shares one read-only connection per db file: a fresh connection per call re-read
# the catalog and dropped DuckDB's block cache, about 1 s per call. Off for tools and tests, which
# rewrite db files that an open connection would lock.
share_connection = False
_SHARED_CON: duckdb.DuckDBPyConnection | None = None
_SHARED_KEY: tuple | None = None
_SHARED_LOCK = threading.Lock()


def _identity_key(path: str) -> tuple:
    """(path, inode, mtime, size): changes whenever a refresh points _db_path() at a new file,
    or the same path is overwritten in place -- either way the cached connection is stale."""
    try:
        st = os.stat(path)
        return (path, st.st_ino, st.st_mtime_ns, st.st_size)
    except OSError:
        return (path, None, None, None)


def _cap(con: duckdb.DuckDBPyConnection) -> duckdb.DuckDBPyConnection:
    """Read with the load's memory and thread caps (settings load:), not DuckDB's default of 80%
    of RAM and every core."""
    try:
        load = app_config.load_settings()["load"]
        con.execute(f"SET memory_limit = '{load['memory_limit']}'")
        con.execute(f"SET threads = {int(load['threads'])}")
    except Exception:  # noqa: BLE001 -- a settings error is reported elsewhere; reading still works
        pass
    return con


def _connect(read_only: bool = True) -> duckdb.DuckDBPyConnection:
    global _SHARED_CON, _SHARED_KEY
    path = str(_db_path())
    if not (share_connection and read_only):
        return _cap(duckdb.connect(path, read_only=read_only))
    key = _identity_key(path)
    with _SHARED_LOCK:
        if _SHARED_CON is None or _SHARED_KEY != key:
            new_con = _cap(duckdb.connect(path, read_only=True))
            old_con = _SHARED_CON
            _SHARED_CON, _SHARED_KEY = new_con, key
            if old_con is not None:
                old_con.close()  # drop the old file's handle so Windows can delete it
        return _SHARED_CON.cursor()


def _file_cached(path_fn):
    """Memoize on (file, mtime, size, args): the wrapped read only changes when that file does, and
    re-running it on every request made each API call take seconds."""
    def deco(fn):
        cache: dict = {}

        @functools.wraps(fn)
        def wrapper(*args, **kwargs):
            path = path_fn()
            try:
                st = path.stat()
            except OSError:
                return fn(*args, **kwargs)
            key = (str(path), st.st_mtime_ns, st.st_size,
                   repr([a for a in args if not isinstance(a, duckdb.DuckDBPyConnection)]),
                   repr(sorted(kwargs.items())))
            if key not in cache:
                if len(cache) > 4096:
                    cache.clear()
                cache[key] = fn(*args, **kwargs)
            return copy.deepcopy(cache[key])

        wrapper.cache_clear = cache.clear
        return wrapper
    return deco


# ---------------------------------------------------------------------------------------------
# db_state: the one check GET /api/status runs before anything else touches the database, so the
# shell can tell "no database yet" from "a database exists but the load is incomplete" instead of
# both reading as an opaque 500. Never raises.
# ---------------------------------------------------------------------------------------------


def db_state() -> dict:
    """{"state": "no_database"} when _db_path() does not exist; {"state": "build_incomplete",
    "detail": DuckDB's message} when the file cannot be read or has no dims.dim_account (the table
    nearly every other read depends on); {"state": "ready"} otherwise. Every state carries
    "db_path". One missing finding table is not this function's concern: it reads NOT_ASSESSED
    per check (finding_status)."""
    path = _db_path()
    if not path.exists():
        return {"state": "no_database", "db_path": str(path)}
    con = None
    try:
        con = _cap(duckdb.connect(str(path), read_only=True))
        con.execute("SELECT 1 FROM dims.dim_account LIMIT 1")
    except (duckdb.Error, OSError) as exc:
        return {"state": "build_incomplete", "db_path": str(path), "detail": str(exc)}
    finally:
        if con is not None:
            con.close()
    return {"state": "ready", "db_path": str(path)}


# ---------------------------------------------------------------------------------------------
# Identifier validation
# ---------------------------------------------------------------------------------------------


def _validate_query_id(query_id: str) -> registry.QuerySpec:
    if not _QUERY_ID_RE.fullmatch(query_id):
        raise ValueError(f"bad query_id {query_id!r}")
    return registry.by_id(query_id)  # raises KeyError for anything not in the real registry


# ---------------------------------------------------------------------------------------------
# read_finding / count_finding
# ---------------------------------------------------------------------------------------------


@_file_cached(lambda: _db_path())
def _table_columns(con: duckdb.DuckDBPyConnection, query_id: str) -> list[tuple[str, str]]:
    rows = con.execute(
        "SELECT column_name, data_type FROM information_schema.columns "
        "WHERE table_schema = 'findings' AND table_name = ? ORDER BY ordinal_position",
        [f"f_{query_id}"],
    ).fetchall()
    if not rows:
        raise FindingNotBuiltError(
            f'findings."f_{query_id}" does not exist in {_db_path()} -- the model failed, was '
            "skipped, or the db has not been (re)built yet; see finding_status(query_id)."
        )
    return [(r[0], r[1]) for r in rows]


def _is_complex(dtype: str) -> bool:
    d = dtype.upper()
    return d.startswith("MAP(") or d.startswith("STRUCT(") or d.endswith("[]")


def _select_list(cols: list[tuple[str, str]], query_id: str) -> str:
    """The SELECT list for read_finding. Plain columns pass through unchanged (a MAP/STRUCT/LIST
    one as to_json). When a materiality floor or a severity cap applies to this table, "status" is
    instead selected as the EFFECTIVE status -- so a below-floor CRITICAL/WARN row reads OK, and a
    capped report's CRITICAL reads WARN, everywhere a caller reads `status`, the same as it already
    does in status_counts/an aggregate sum -- with the raw value kept alongside as status_raw.
    below_floor (real for an applicable floor, else a flat FALSE) is always appended, so every
    finding row carries it whether or not this query has a floor at all."""
    col_names = [name for name, _ in cols]
    floor = app_materiality.applicable_floor(query_id, col_names)
    effective = floor is not None or app_materiality.severity_cap(query_id) is not None
    parts = []
    for name, dtype in cols:
        if name == "status" and effective:
            parts.append(f'{app_materiality.status_expr(query_id, col_names)} AS "status"')
            parts.append('"status" AS "status_raw"')
        elif _is_complex(dtype):
            parts.append(f'to_json("{name}") AS "{name}"')
        else:
            parts.append(f'"{name}"')
    below_expr = app_materiality.below_floor_expr(query_id, col_names) if floor is not None else None
    parts.append(f'({below_expr}) AS "below_floor"' if below_expr is not None else 'FALSE AS "below_floor"')
    return ", ".join(parts)


def _attribute_canonical_keys() -> set[str]:
    """The whitelist of workspace-attribute column names _build_filters is ever allowed to splice
    into a dims.dim_account WHERE clause as an identifier -- config/tag_aliases.yml's own
    canonical keys, never the caller-supplied
    `attributes` dict's keys directly. That dict arrives from app/api's query params (untrusted
    HTTP input); the column NAME must be checked against this trusted, server-side set before it
    is ever used as anything but a bound parameter VALUE (this module's own rule, see the file
    docstring's "query_id is never string-formatted into a filter VALUE" -- the same discipline
    applies to any identifier)."""
    try:
        return set(app_config.load_tag_aliases().get("canonical", {}))
    except app_config.ConfigError:
        return set()


@dataclass
class TagApplication:
    """what app/core/tags's chain/clause mechanism did for one finding
    table under a `tag_filter`. `chain_kind` is None when no `tag_filter` was given at all
."""
    chain_kind: str | None = None
    chain_words: list = field(default_factory=list)
    chain_label: str | None = None
    reason: str | None = None
    select_sql: str | None = None
    select_params: list = field(default_factory=list)

    @property
    def applied(self) -> bool | None:
        return None if self.chain_kind is None else self.chain_kind != "none"


_NO_TAG_APPLICATION = TagApplication()


def account_filterable(col_names) -> bool:
    """A check follows the account, env and attribute filters when it has account_id, or a
    warehouse_id whose account dims.dim_warehouse knows."""
    return bool(set(col_names or []) & {"account_id", "warehouse_id"})


def _in_accounts(col_names, sub_sql: str) -> str:
    """`sub_sql` selects account ids; the clause keeps this check's rows in those accounts, through
    the warehouse when the check has no account_id of its own."""
    cols = set(col_names or [])
    if "account_id" in cols or not cols:
        return f"account_id IN ({sub_sql})"
    return f"warehouse_id IN (SELECT warehouse_id FROM dims.dim_warehouse WHERE account_id IN ({sub_sql}))"


# The Owner filter: existing owner-like columns, never a new one. A table carries at most one.
_OWNER_COLUMNS = (
    "owner", "owner_role", "table_owner", "run_as", "identity_run_as", "created_by",
    "executed_by", "user_name", "actor", "principal",
)


def _owner_column(col_names) -> str | None:
    cols = set(col_names or [])
    return next((name for name in _OWNER_COLUMNS if name in cols), None)


def _task_column(col_names) -> str | None:
    """The column a check names a task by: task_full_name (Snowflake checks), job_id (the ported
    task checks, where it holds database.schema.task), else root_task_full_name (a graph check)."""
    cols = set(col_names or [])
    return next((name for name in ("task_full_name", "job_id", "root_task_full_name") if name in cols), None)


def owner_filterable(col_names, has_job_id: bool = False) -> bool:
    """Whether an `owner` filter has anywhere to apply: an owner-like column of its own, or a task
    column dims.dim_task can resolve to its owner role."""
    return _owner_column(col_names) is not None or has_job_id


def _no_account_clause(col_names) -> str | None:
    """A workspace/env/attribute filter silently drops a row with no resolvable account: a NULL or
    '0' account_id, or a warehouse missing from its dim. This is that row set's own WHERE text, or
    None when the check has neither column."""
    cols = set(col_names or [])
    if "account_id" in cols:
        return "(account_id IS NULL OR account_id = '0')"
    if "warehouse_id" in cols:
        return "(warehouse_id IS NULL OR warehouse_id NOT IN (SELECT warehouse_id FROM dims.dim_warehouse))"
    return None


@dataclass(frozen=True)
class DimFilter:
    """The warehouse, database and schema filters. Warehouse and database are names (a trailing
    "(id)" is ignored); a schema is "DATABASE.SCHEMA" (or a bare name)."""
    warehouses: tuple = ()
    databases: tuple = ()
    schemas: tuple = ()

    def __bool__(self) -> bool:
        return bool(self.warehouses or self.databases or self.schemas)

    @classmethod
    def of(cls, warehouses=None, databases=None, schemas=None) -> "DimFilter | None":
        clean = lambda values: tuple(dict.fromkeys(v.strip() for v in (values or []) if v and v.strip()))  # noqa: E731
        out = cls(clean(warehouses), clean(databases), clean(schemas))
        return out if out else None


# The column a check names each object by, first match wins. A value may read "NAME (id)".
_WAREHOUSE_COLUMNS = ("warehouse_name", "warehouse", "main_warehouse_name", "query_warehouse")
_DATABASE_COLUMNS = ("database_name", "table_catalog", "view_catalog")
_SCHEMA_COLUMNS = ("schema_name", "table_schema", "view_schema")
_STRIP_ID = r"'\s*\([^)]*\)\s*$'"


def _norm_dim_value(value: str) -> str:
    return re.sub(r"\s*\([^)]*\)\s*$", "", value.strip()).lower()


def _norm_dim_col(col: str) -> str:
    return f'regexp_replace(lower(CAST("{col}" AS VARCHAR)), {_STRIP_ID}, \'\')'


def _first(col_names, candidates) -> str | None:
    cols = set(col_names or [])
    return next((c for c in candidates if c in cols), None)


def dim_applicability(col_names, dims: "DimFilter | None") -> dict:
    """{"warehouse", "database", "schema"}: True when the check has a column the filter can use, False
    when it was asked for and the check has none (it stays unfiltered and says so), None when not asked."""
    out: dict = {"warehouse": None, "database": None, "schema": None}
    if not dims:
        return out
    cols = set(col_names or [])
    if dims.warehouses:
        out["warehouse"] = bool(_first(cols, _WAREHOUSE_COLUMNS) or "warehouse_id" in cols)
    if dims.databases:
        out["database"] = bool(_first(cols, _DATABASE_COLUMNS) or "schema_fqn" in cols)
    if dims.schemas:
        out["schema"] = bool(_first(cols, _SCHEMA_COLUMNS) or "schema_fqn" in cols)
    return out


def _dim_clauses(col_names, dims: "DimFilter | None") -> tuple[list[str], list]:
    """WHERE clauses (and bound values) for the warehouse, database and schema filters, on whichever
    column each check carries; a filter the check cannot apply adds nothing."""
    clauses: list[str] = []
    params: list = []
    if not dims:
        return clauses, params
    cols = set(col_names or [])
    if dims.warehouses:
        values = [_norm_dim_value(v) for v in dims.warehouses]
        marks = ", ".join("?" for _ in values)
        name_col = _first(cols, _WAREHOUSE_COLUMNS)
        if name_col:
            clauses.append(f"{_norm_dim_col(name_col)} IN ({marks})")
            params.extend(values)
        elif "warehouse_id" in cols:
            clauses.append("warehouse_id IN (SELECT warehouse_id FROM dims.dim_warehouse "
                           f"WHERE lower(warehouse_name) IN ({marks}))")
            params.extend(values)
    if dims.databases:
        values = [_norm_dim_value(v) for v in dims.databases]
        marks = ", ".join("?" for _ in values)
        db_col = _first(cols, _DATABASE_COLUMNS)
        if db_col:
            clauses.append(f"{_norm_dim_col(db_col)} IN ({marks})")
            params.extend(values)
        elif "schema_fqn" in cols:
            clauses.append(f"split_part(lower(CAST(\"schema_fqn\" AS VARCHAR)), '.', 1) IN ({marks})")
            params.extend(values)
    if dims.schemas:
        values = [_norm_dim_value(v) for v in dims.schemas]
        qualified = [v for v in values if "." in v]
        bare = [v for v in values if "." not in v]
        sch_col = _first(cols, _SCHEMA_COLUMNS)
        db_col = _first(cols, _DATABASE_COLUMNS)
        parts: list[str] = []
        if "schema_fqn" in cols and not sch_col:
            if qualified:
                parts.append(f"lower(CAST(\"schema_fqn\" AS VARCHAR)) IN ({', '.join('?' for _ in qualified)})")
                params.extend(qualified)
            if bare:
                parts.append(f"split_part(lower(CAST(\"schema_fqn\" AS VARCHAR)), '.', 2) IN ({', '.join('?' for _ in bare)})")
                params.extend(bare)
        elif sch_col:
            if qualified and db_col:
                parts.append(f"({_norm_dim_col(db_col)} || '.' || {_norm_dim_col(sch_col)}) IN "
                             f"({', '.join('?' for _ in qualified)})")
                params.extend(qualified)
            elif qualified:
                bare = bare + [v.split(".", 1)[1] for v in qualified]
            if bare:
                parts.append(f"{_norm_dim_col(sch_col)} IN ({', '.join('?' for _ in bare)})")
                params.extend(bare)
        if parts:
            clauses.append("(" + " OR ".join(parts) + ")")
    return clauses, params


def _build_filters(
    window_days: int,
    account_ids: list[str] | None,
    env: list[str] | str | None,
    tag: dict[str, str] | None,
    has_account_id: bool,
    has_tag: bool,
    attributes: dict[str, list[str]] | None = None,
    job_id: str | None = None,
    has_job_id: bool = False,
    statuses: list[str] | None = None,
    has_status: bool = False,
    *,
    tag_filter: "app_core_tags.TagFilter | app_core_tags.TagFilterSet | None" = None,
    table_sql: str | None = None,
    col_names: list[str] | None = None,
    domain: str | None = None,
    query_id: str | None = None,
    con: duckdb.DuckDBPyConnection | None = None,
    owner: str | None = None,
    tag_prefiltered: bool = False,
    dims: "DimFilter | None" = None,
) -> tuple[str, list, "TagApplication"]:
    """Returns (where_sql, params, tag_application). The legacy positional `tag`/`has_tag`
 stay exactly as they were. The NEW tag filter is
    keyword-only and additive: give `tag_filter` together with `table_sql` (the FROM clause's own
    table, aliased `t` -- data.py's own read/count/aggregate helpers always alias it that way) and
    `col_names` and `domain` to have it compiled via app.core.tags.tag_chain/tag_set_clause.
    `tag_filter` is a TagFilter (one key:value, normalised here into a one-group TagFilterSet) or a
    TagFilterSet outright (several tag names ANDed, each name's own values ORed). Raises
    TagModelsNotBuiltError when the chain needs tags.tag_entity (chain kind "entity") and that
    table does not exist in `con` -- never returns unfiltered rows under an active filter."""
    clauses = ["window_days = ?"]
    params: list = [window_days]

    if has_account_id and account_ids:
        placeholders = ", ".join("?" for _ in account_ids)
        clauses.append(_in_accounts(col_names, placeholders))
        params.extend(account_ids)

    if has_account_id and env:
        envs = [env] if isinstance(env, str) else list(env)
        if envs:
            placeholders = ", ".join("?" for _ in envs)
            clauses.append(_in_accounts(
                col_names, f"SELECT account_id FROM dims.dim_account WHERE env IN ({placeholders})"
            ))
            params.extend(envs)

    # one branch of the exact same shape as the env branch above, joining
    # account_id against dims.dim_account's new <key> column -- never the has_tag/tag_key/
    # tag_value branch below, which is a different mechanism left
    # byte-identical and still unreachable from app/api.
    if has_account_id and attributes:
        allowed = _attribute_canonical_keys()
        for key, values in attributes.items():
            if key not in allowed or not values:
                continue
            # C26: through _in_accounts like the generic branch below, so a warehouse/cluster-
            # keyed check (no account_id of its own) gets the same override a account_id one
            # already did.
            alias = (
                app_cost_center.attribute_filter_sql(con, values)
                if key == "cost_center" and con is not None else None
            )
            if alias is not None:
                sub_sql, sub_params = alias
                clauses.append(_in_accounts(col_names, sub_sql))
                params.extend(sub_params)
                continue
            placeholders = ", ".join("?" for _ in values)
            clauses.append(_in_accounts(
                col_names, f'SELECT account_id FROM dims.dim_account WHERE "{key}" IN ({placeholders})'
            ))
            params.extend(values)

    if has_tag and tag:
        tag_key = tag.get("tag_key")
        tag_value = tag.get("tag_value")
        if tag_key:
            # Spec 5.5: the legacy Streamlit filter (app/ui/filters.py) matches tag_key the same
            # normalised way the new tag search filter's row-tags branch does (app/core/tags.py's
            # _NORM_TAG_KEY_SQL) -- "Cost Center", "cost-center" and "cost_center" are one key
            # here too, not just in the new mechanism. docs/FILTERS.md already documents this.
            clauses.append("regexp_replace(lower(tag_key), '[ _-]+', '', 'g') = ?")
            params.append(app_core_tags.tag_keys.normalize_tag_key(tag_key))
        if tag_value:
            clauses.append("tag_value = ?")
            params.append(tag_value)

    # The task focus filter applies only when the check names a task (_task_column),
    # the same "unaffected, never silently empty" contract as account_id/tag above, so a check
    # with no task in its grain ignores it. Matching server-side keeps a task past the row cap from
    # falling through to a false "not flagged".
    task_col = _task_column(col_names)
    if has_job_id and job_id and task_col:
        clauses.append(f'"{task_col}" = ?')
        params.append(job_id)

    # Owner filter: any owner-like column the check has (case-insensitive equality); on a check
    # with a task column but none of those, through the task's owner role in dims.dim_task. A
    # check with neither is unaffected.
    if owner:
        owner_col = _owner_column(col_names)
        if owner_col is not None:
            clauses.append(f'lower("{owner_col}") = lower(?)')
            params.append(owner)
        elif has_job_id and task_col:
            clauses.append(
                f'"{task_col}" IN (SELECT task_full_name FROM dims.dim_task WHERE lower(owner_role) = lower(?))'
            )
            params.append(owner)

    # Warehouse / database / schema: on the column each check carries; a check with none is unfiltered
    # (dim_applicability says so), never silently emptied.
    dim_clauses, dim_params = _dim_clauses(col_names, dims)
    clauses.extend(dim_clauses)
    params.extend(dim_params)

    # a status filter so a tile that needs only flagged (or only some-status) rows can ask
    # the store for exactly those, instead of fetching an unfiltered page (capped at ui.max_rows)
    # and filtering by status in the browser -- which silently drops flagged rows sitting past the
    # cap on a large finding. Same "unaffected, never silently empty" contract as job_id/tag above:
    # applies only when the table actually has a status column.
    #
    # Materiality floor: filters against the EFFECTIVE status (app/core/materiality.status_expr),
    # not the raw column -- a below-floor CRITICAL row is not WARN/CRITICAL for this purpose, so it
    # drops out of a `statuses=["WARN","CRITICAL"]` money sum/count the same way it drops out of
    # status_counts (finding_window_counts below). The row's own exported `status` column, in a
    # plain SELECT, is never touched by this.
    if has_status and statuses:
        placeholders = ", ".join("?" for _ in statuses)
        status_col = app_materiality.status_expr(query_id or "", col_names or [])
        clauses.append(f"{status_col} IN ({placeholders})")
        params.extend(statuses)

    tag_application = _NO_TAG_APPLICATION
    if tag_filter is not None and tag_prefiltered:
        # table_sql is already app_tag_spend's re-computation over the matching dollars.
        tag_application = TagApplication(
            chain_kind="spend", chain_words=list(app_tag_spend.CHAIN_WORDS),
            chain_label=app_tag_spend.CHAIN_LABEL,
        )
    elif tag_filter is not None and col_names is not None and domain is not None:
        chain = app_core_tags.tag_chain(query_id or "", col_names, domain)
        if chain.kind == "entity" and con is not None:
            exists = con.execute(
                "SELECT count(*) FROM information_schema.tables "
                "WHERE table_schema = 'tags' AND table_name = 'tag_entity'"
            ).fetchone()[0]
            if not exists:
                raise app_core_tags.TagModelsNotBuiltError(
                    "tags.tag_entity does not exist -- rebuild to filter by tag"
                )
        # A bare TagFilter normalises into a one-group TagFilterSet so both compile the same way.
        filter_set = (
            tag_filter if isinstance(tag_filter, app_core_tags.TagFilterSet)
            else app_core_tags.TagFilterSet.single(tag_filter)
        )
        clause = app_core_tags.tag_set_clause(chain, table_sql or "", filter_set)
        if clause is None and chain.kind == "row_tags":
            # Section 5.4/7.5: tag_set_clause returns None here either for `__untagged__` against a
            # row-tags table (cost_chargeback_by_tag today) -- it lists tagged billing rows only,
            # so "untagged" is not a row it could ever show -- or for more than one tag name, since
            # one row carries exactly one (tag_key, tag_value) pair and can never match two names at
            # once. Either way: leave the finding unfiltered and mark it not-applicable, the same as a table the chain cannot reach at all.
            if len(filter_set.groups) > 1:
                reason = "this check lists one tag per row, so several tag names cannot be combined here"
            else:
                reason = 'this check lists tagged billing rows only, so "untagged" cannot be shown here'
            tag_application = TagApplication(chain_kind="none", reason=reason)
        else:
            tag_application = TagApplication(
                chain_kind=chain.kind,
                chain_words=chain.chain_words,
                chain_label=chain.chain_label,
                reason=chain.reason,
            )
            if clause is not None:
                clauses.append(f"({clause.where_sql})")
                params.extend(clause.params)
                tag_application.select_sql = clause.select_sql
                tag_application.select_params = clause.select_params

    return " AND ".join(clauses), params, tag_application


def _status_rank_sql(status_sql: str) -> str:
    return (
        f"CASE ({status_sql}) WHEN 'CRITICAL' THEN 0 WHEN 'WARN' THEN 1 "
        "WHEN 'NOT_ASSESSED' THEN 2 WHEN 'OK' THEN 3 ELSE 4 END"
    )


def _order_by_clause(query_id: str, col_names: list[str]) -> str:
    """The ORDER BY the store emits: worst status first whenever the table has a status band (on
    the EFFECTIVE, floored status, so a row a materiality floor suppresses also sorts as OK), then
    the export's own row order (`t.rowid`: the loader inserts rows in the order the check's SQL
    returned them). The ordering decides which rows survive the `LIMIT ui.max_rows` cap, so the
    status rank leads: a CRITICAL row past the cap must not be dropped from a panel that exists to
    surface it."""
    if "status" in col_names:
        return f" ORDER BY {_status_rank_sql(app_materiality.status_expr(query_id, col_names))}, t.rowid"
    return " ORDER BY t.rowid"


def read_finding(
    query_id: str,
    window_days: int,
    account_ids: list[str] | None = None,
    env: list[str] | str | None = None,
    tag: dict[str, str] | None = None,
    limit: int | None = None,
    attributes: dict[str, list[str]] | None = None,
    job_id: str | None = None,
    statuses: list[str] | None = None,
    *,
    tag_filter: "app_core_tags.TagFilter | app_core_tags.TagFilterSet | None" = None,
    owner: str | None = None,
    dims: "DimFilter | None" = None,
) -> FindingResult:
    """SELECT ... FROM findings."f_<query_id>" WHERE window_days = ? [AND account_id IN (...)]
    [AND account_id IN (SELECT ... WHERE env IN (...))]
    [AND account_id IN (SELECT ... WHERE "<key>" IN (...)) ...] [AND tag_key = ? [AND tag_value
    = ?]] [AND job_id = ?] [AND <owner column> = ?] [AND status IN (...)] ORDER BY <status rank, then export order> LIMIT <ui.max_rows or `limit`>.
    account_ids/env/attributes apply only when the table has a account_id column; tag applies only
    when tag_key/tag_value columns exist; job_id applies only when a
    job_id column exists; owner matches any owner-like column the check has, case-
    insensitively, else (task checks only) any task dims.dim_task resolves to that owner
    role; statuses applies only when a status column exists -- same contract, and the
    returned `applicability` flags say which.
    `attributes` is {canonical_key: [value, ...]} -- keys not present in
    config/tag_aliases.yml are silently ignored by _build_filters, never trusted as a SQL
    identifier. rows_total is a separate `count(*)` over the SAME filters, without the LIMIT
. Materiality floor (see _select_list): a table a floor applies to returns the
    EFFECTIVE status as "status" (raw kept as "status_raw") and a real "below_floor" column, so a
    caller reading `status` off these rows -- for counting, sorting, or a WARN/CRITICAL sum -- gets
    the same answer status_counts/an aggregate already give; every other table still returns a
    plain "status" plus a flat below_floor=False."""
    spec = _validate_query_id(query_id)
    con = _connect()
    try:
        cols = _table_columns(con, query_id)
        col_names = [c[0] for c in cols]
        has_account_id = account_filterable(col_names)
        has_tag = {"tag_key", "tag_value"}.issubset(col_names)
        has_job_id = _task_column(col_names) is not None
        has_status = "status" in col_names
        spend_table = app_tag_spend.table_sql(con, query_id, window_days, tag_filter)
        table = spend_table or f'findings."f_{query_id}" t'
        where_sql, params, tag_app = _build_filters(
            window_days, account_ids, env, tag, has_account_id, has_tag, attributes,
            job_id, has_job_id, statuses, has_status,
            tag_filter=tag_filter, table_sql=table, col_names=col_names, domain=spec.domain,
            query_id=query_id, con=con, owner=owner, tag_prefiltered=spend_table is not None, dims=dims,
        )

        rows_total = con.execute(f"SELECT count(*) FROM {table} WHERE {where_sql}", params).fetchone()[0]

        # Materiality floor: how many of rows_total have their floor column under `min` -- one
        # extra, cheap count(*), only when this query has a configured floor whose column the
        # table actually carries (app_materiality.below_floor_expr returns None otherwise, and no
        # query runs at all).
        below_expr = app_materiality.below_floor_expr(query_id, col_names)
        rows_below_floor = 0
        if below_expr is not None:
            rows_below_floor = int(
                con.execute(
                    f"SELECT count(*) FROM {table} WHERE {where_sql} AND {below_expr}", params
                ).fetchone()[0]
            )

        excluded_no_account = None
        if has_account_id and (account_ids or env or attributes):
            no_acct_sql = _no_account_clause(col_names)
            if no_acct_sql is not None:
                no_ws_where, no_ws_params, _ = _build_filters(
                    window_days, None, None, tag, has_account_id, has_tag, None,
                    job_id, has_job_id, statuses, has_status,
                    tag_filter=tag_filter, table_sql=table, col_names=col_names, domain=spec.domain,
                    query_id=query_id, con=con, owner=owner, tag_prefiltered=spend_table is not None, dims=dims,
                )
                excl_rows = int(
                    con.execute(
                        f"SELECT count(*) FROM {table} WHERE ({no_ws_where}) AND {no_acct_sql}",
                        no_ws_params,
                    ).fetchone()[0]
                )
                excluded_no_account = {"rows": excl_rows}

        eff_limit = limit if limit is not None else app_config.load_settings()["ui"]["max_rows"]
        select_list = _select_list(cols, query_id)
        if tag_app.select_sql:
            select_list = f"{select_list}, {tag_app.select_sql}"
        order_sql = _order_by_clause(query_id, col_names)
        sql = f"SELECT {select_list} FROM {table} WHERE {where_sql}{order_sql} LIMIT ?"
        df = con.execute(sql, [*tag_app.select_params, *params, eff_limit]).df()
    finally:
        con.close()
    return FindingResult(
        df=df,
        rows_total=int(rows_total),
        rows_below_floor=rows_below_floor,
        excluded_no_account=excluded_no_account,
        applicability={
            "has_account_id": has_account_id, "has_tag": has_tag, "has_job_id": has_job_id,
            "tag_applied": tag_app.applied, "tag_chain": tag_app.chain_words,
            "tag_chain_label": tag_app.chain_label, "tag_not_applicable_reason": tag_app.reason,
            "owner_applied": owner_filterable(col_names, has_job_id) if owner else None,
            "dim_applied": dim_applicability(col_names, dims),
        },
    )


def count_finding(
    query_id: str,
    window_days: int,
    account_ids: list[str] | None = None,
    env: list[str] | str | None = None,
    tag: dict[str, str] | None = None,
    attributes: dict[str, list[str]] | None = None,
    statuses: list[str] | None = None,
    *,
    tag_filter: "app_core_tags.TagFilter | app_core_tags.TagFilterSet | None" = None,
) -> int:
    """Row count only, same filter contract as read_finding (its separate
    `count(*)`), including the `attributes` param, `statuses` and the
    new `tag_filter`."""
    result = count_finding_ex(
        query_id, window_days, account_ids, env, tag, attributes, statuses, tag_filter=tag_filter
    )
    return result[0]


def count_finding_ex(
    query_id: str,
    window_days: int,
    account_ids: list[str] | None = None,
    env: list[str] | str | None = None,
    tag: dict[str, str] | None = None,
    attributes: dict[str, list[str]] | None = None,
    statuses: list[str] | None = None,
    *,
    tag_filter: "app_core_tags.TagFilter | app_core_tags.TagFilterSet | None" = None,
) -> tuple[int, "TagApplication"]:
    """count_finding's own twin that also returns the TagApplication (chain/applied/reason) --
    used by app/api/service.py to fill scope.tag without a second read. count_finding() above is
    the plain, backward-compatible int-only shape every existing caller keeps using."""
    spec = _validate_query_id(query_id)
    con = _connect()
    try:
        cols = _table_columns(con, query_id)
        col_names = [c[0] for c in cols]
        has_account_id = account_filterable(col_names)
        has_tag = {"tag_key", "tag_value"}.issubset(col_names)
        has_status = "status" in col_names
        spend_table = app_tag_spend.table_sql(con, query_id, window_days, tag_filter)
        table = spend_table or f'findings."f_{query_id}" t'
        where_sql, params, tag_app = _build_filters(
            window_days, account_ids, env, tag, has_account_id, has_tag, attributes,
            statuses=statuses, has_status=has_status,
            tag_filter=tag_filter, table_sql=table, col_names=col_names, domain=spec.domain,
            query_id=query_id, con=con, tag_prefiltered=spend_table is not None,
        )
        n = int(con.execute(f"SELECT count(*) FROM {table} WHERE {where_sql}", params).fetchone()[0])
        return n, tag_app
    finally:
        con.close()


def finding_columns(query_id: str) -> list[str]:
    """the column names of findings."f_<query_id>" -- raises FindingNotBuiltError when
    the table is absent, the same contract as read_finding / count_finding."""
    _validate_query_id(query_id)
    con = _connect()
    try:
        return [name for name, _ in _table_columns(con, query_id)]
    finally:
        con.close()


def _dim_scope_count(
    con: duckdb.DuckDBPyConnection, dim_table: str, id_col: str,
    account_ids: list[str] | None, env: list[str] | str | None,
    attributes: dict[str, list[str]] | None,
) -> int:
    """count(DISTINCT id_col) FROM dims.<dim_table>, scoped by account_ids/env/attributes the
    same way _build_filters' own branches do -- for affected.total, against a dim table (no window_days of its own, so
    _build_filters itself does not apply -- same reasoning as region_split's own hand-rolled
    clauses)."""
    clauses: list[str] = []
    params: list = []
    if account_ids:
        placeholders = ", ".join("?" for _ in account_ids)
        clauses.append(f"account_id IN ({placeholders})")
        params.extend(str(w) for w in account_ids)
    envs = [env] if isinstance(env, str) else list(env or [])
    if envs:
        placeholders = ", ".join("?" for _ in envs)
        clauses.append(f"account_id IN (SELECT account_id FROM dims.dim_account WHERE env IN ({placeholders}))")
        params.extend(envs)
    if attributes:
        allowed = _attribute_canonical_keys()
        for key, values in attributes.items():
            if key not in allowed or not values:
                continue
            alias = app_cost_center.attribute_filter_sql(con, values) if key == "cost_center" else None
            if alias is not None:
                sub_sql, sub_params = alias
                clauses.append(f"account_id IN ({sub_sql})")
                params.extend(sub_params)
                continue
            placeholders = ", ".join("?" for _ in values)
            clauses.append(
                f'account_id IN (SELECT account_id FROM dims.dim_account WHERE "{key}" IN ({placeholders}))'
            )
            params.extend(values)
    where = f" WHERE {' AND '.join(clauses)}" if clauses else ""
    try:
        row = con.execute(f"SELECT count(DISTINCT {_entity_key_sql(id_col, True)}) FROM dims.{dim_table}{where}", params).fetchone()
    except duckdb.Error:
        return 0
    return int(row[0]) if row and row[0] is not None else 0


def _entity_key_sql(id_cols, has_account_id: bool) -> str:
    """One entity per account + identifying columns (ids repeat across accounts). NULL when every
    identifying column is NULL, so a row that names no entity is not counted as one."""
    cols = [id_cols] if isinstance(id_cols, str) else list(id_cols)
    parts = [f"COALESCE(CAST(\"{c}\" AS VARCHAR), '')" for c in cols]
    joined = " || ':' || ".join(parts)
    if has_account_id:
        joined = f"COALESCE(CAST(account_id AS VARCHAR), '') || ':' || {joined}"
    any_set = " OR ".join(f'"{c}" IS NOT NULL' for c in cols)
    return f"CASE WHEN {any_set} THEN {joined} END"


def _finding_counts_summary(con: duckdb.DuckDBPyConnection) -> dict[str, dict[int, dict]]:
    """{query_id: {window_days: {raw status: rows}}} from the load's summary tables, for each table
    whose row count still matches them; {} on a db loaded before they existed."""
    try:
        sizes = dict(con.execute(
            "SELECT table_name, estimated_size FROM duckdb_tables() WHERE schema_name = 'findings'"
        ).fetchall())
        totals = dict(con.execute("SELECT query_id, n_rows FROM summary.finding_tables").fetchall())
        rows = con.execute("SELECT query_id, window_days, status, n FROM summary.finding_counts").fetchall()
    except duckdb.Error:
        return {}
    # A table changed after the load (a test inserting rows) is counted live instead.
    out: dict[str, dict[int, dict]] = {q: {} for q, n in totals.items() if sizes.get(f"f_{q}") == n}
    for qid, window_days, status, n in rows:
        if qid in out:
            out[qid].setdefault(window_days, {})[status] = int(n)
    return out


def finding_window_counts(
    specs: list[tuple[str, int]],
    account_ids: list[str] | None = None,
    env: list[str] | str | None = None,
    attributes: dict[str, list[str]] | None = None,
    *,
    tag_filter: "app_core_tags.TagFilter | app_core_tags.TagFilterSet | None" = None,
    owner: str | None = None,
    dims: "DimFilter | None" = None,
) -> dict[str, dict]:
    """Bulk twin of count_finding, for a LIST of (query_id, window_days) pairs, opening exactly
    ONE read-only connection for the whole batch instead of one per pair.

    `attributes` is the same {canonical_key: [value, ...]}
    contract count_finding/read_finding already honour -- applies only on a table that carries
    account_id, via the same _build_filters whitelist-before-splice discipline.

    Added for app/api: the findings-list endpoint reads every executable query's counts on
    every page load (one table per finding); the one-connection-per-call model is the right shape for a
    single finding read (short-lived readers so tools/dbt_run.py's atomic file swap is never
    blocked), but paid per-call connection-open overhead once per table -- plus a separate
    information_schema round-trip per table for its column list -- made that endpoint take over
    90 seconds wall-clock on this checkout. Both are batched here: one connection and one
    information_schema query for every table's columns, still read-only, still opened fresh on
    every request (never held across requests), still built on this module's own _connect/
    _build_filters/_validate_query_id helpers -- just once each instead of ~100+ times.

    `tag_filter` applies the same way to every table in the batch, via the
    same app.core.tags chain/clause mechanism read_finding/count_finding_ex already use --
    tags.tag_entity's existence is checked ONCE for the whole batch (not once per query_id, the
    same one-round-trip discipline as the column-list lookup above), rather than through
    _build_filters' own per-call check -- this function sets `effective_tag_filter` to None ahead
    of any query_id whose chain needs a missing tags.tag_entity, so `_build_filters`' own check
    never has a live tag_filter to raise on for that query_id even though `con` IS now passed
. A query_id whose own
    chain needs tags.tag_entity when that table does not exist gets no tag clause at all (it would
    reference a table that is not there) and instead comes back with `"tag_models_not_built":
    True` -- the caller's job to report NOT_ASSESSED with the tag_models_not_built reason
    (service.list_findings' contract, mirroring load_outcome's own TagModelsNotBuiltError
    handling) rather than silently returning unfiltered counts under an
    active filter.

    Same filter contract as count_finding (account_ids/env apply only when the table has the
    matching column). Returns {query_id: {"rows_in_window": int (window alone, no other filter),
    "rows_total": int (window + account_ids/env + tag_filter), "status_counts": dict[str,int] |
    None (a verified SQL GROUP BY over the SAME rows_total rows -- None when the table has no
    "status" column, or when rows_total is 0), "has_account_id": bool, "tag_applied":
    bool | None (None when no tag_filter was given), "tag_chain": list[str], "tag_chain_label":
    str | None, "tag_models_not_built": bool}}. A query_id absent from
    the result means
    findings.f_<query_id> does not exist in the current db -- the caller's own job to report
    NOT_ASSESSED, the same FindingNotBuiltError contract every other read path in this module
    honours, just without raising per pair here (one bad id must not abort the whole batch)."""
    out: dict[str, dict] = {}
    con = _connect()
    try:
        specs_by_id: dict[str, registry.QuerySpec] = {}
        for query_id, _ in specs:
            specs_by_id[query_id] = _validate_query_id(query_id)

        # One information_schema query for every table's column list, instead of one per table
        # (_table_columns' own per-call shape) -- this loop's real cost, once the connection
        # itself is shared, turned out to be one catalog lookup per table rather than the counts
        # themselves.
        table_names = [f"f_{query_id}" for query_id, _ in specs]
        columns_by_table: dict[str, list[str]] = {}
        if table_names:
            placeholders = ", ".join("?" for _ in table_names)
            for table_name, column_name in con.execute(
                "SELECT table_name, column_name FROM information_schema.columns "
                f"WHERE table_schema = 'findings' AND table_name IN ({placeholders}) "
                "ORDER BY table_name, ordinal_position",
                table_names,
            ).fetchall():
                columns_by_table.setdefault(table_name, []).append(column_name)

        # tags.tag_entity's existence, checked ONCE for the whole batch -- every
        # "entity"-kind chain in this batch needs the same one table, so one information_schema
        # round trip (like the column-list one above) answers it for all of them, instead of
        # _build_filters' own per-call check (bypassed below by never passing it `con`).
        tag_entity_exists = True
        if tag_filter is not None:
            tag_entity_exists = bool(
                con.execute(
                    "SELECT count(*) FROM information_schema.tables "
                    "WHERE table_schema = 'tags' AND table_name = 'tag_entity'"
                ).fetchone()[0]
            )

        # money/affected: one discount read for the whole batch, not once per id.
        try:
            discount_pct = effective_discount_pct(float(app_config.load_settings().get("discount_pct", 0.0)))
        except Exception:  # pragma: no cover -- defensive, matches app/core/rollup.py's own guard
            discount_pct = 0.0
        basis_source = price_basis()["source_short"]
        _prices = price_basis()

        summary = _finding_counts_summary(con)

        for query_id, window_days in specs:
            col_names = columns_by_table.get(f"f_{query_id}")
            if not col_names:
                continue  # findings.f_<query_id> does not exist -- FindingNotBuiltError's contract
            has_status = "status" in col_names
            has_account_id = account_filterable(col_names)
            has_tag = {"tag_key", "tag_value"}.issubset(col_names)
            table = f'findings."f_{query_id}" t'

            raw_counts = summary.get(query_id, {}).get(window_days, {}) if query_id in summary else None
            if raw_counts is not None:
                rows_in_window = sum(raw_counts.values())
            else:
                rows_in_window = int(
                    con.execute(f"SELECT count(*) FROM {table} WHERE window_days = ?", [window_days]).fetchone()[0]
                )

            # A chain that needs tags.tag_entity when this batch already knows it is missing gets
            # no tag clause at all (it would otherwise reference a table that does not exist) --
            # this query_id comes back `tag_models_not_built` instead, same "never silently
            # unfiltered" rule as read_finding/count_finding_ex's own TagModelsNotBuiltError.
            effective_tag_filter = tag_filter
            tag_models_not_built = False
            if tag_filter is not None:
                domain = specs_by_id[query_id].domain
                probe_chain = app_core_tags.tag_chain(query_id, col_names, domain)
                if probe_chain.kind == "entity" and not tag_entity_exists:
                    tag_models_not_built = True
                    effective_tag_filter = None

            spend_table = app_tag_spend.table_sql(con, query_id, window_days, effective_tag_filter)
            filtered_table = spend_table or table
            where_sql, params, tag_app = _build_filters(
                window_days, account_ids, env, None, has_account_id, has_tag, attributes,
                tag_filter=effective_tag_filter, table_sql=filtered_table, col_names=col_names,
                domain=specs_by_id[query_id].domain, query_id=query_id, con=con, owner=owner,
                tag_prefiltered=spend_table is not None, dims=dims,
            )
            # No filter at all: the load-time summary already holds these counts.
            unfiltered = raw_counts is not None and spend_table is None and where_sql == "window_days = ?"
            if unfiltered:
                rows_total = rows_in_window
            else:
                rows_total = int(con.execute(f"SELECT count(*) FROM {filtered_table} WHERE {where_sql}", params).fetchone()[0])

            status_counts = None
            money = None
            affected = None
            floor_info = None
            if has_status and rows_total:
                # Materiality floor: grouped on the EFFECTIVE status, so a below-floor CRITICAL/
                # WARN row counts as OK here -- the same status_counts the findings table's own
                # "worst status" pill is derived from (app/api/service.list_findings).
                status_col = app_materiality.status_expr(query_id, col_names)
                if unfiltered and status_col == 't."status"':
                    status_counts = dict(raw_counts)
                else:
                    status_rows = con.execute(
                        f'SELECT {status_col} AS status, count(*) FROM {filtered_table} WHERE {where_sql} '
                        f'GROUP BY {status_col}',
                        params,
                    ).fetchall()
                    status_counts = {status: int(n) for status, n in status_rows}
                # Rows the floor moved to OK, so the list can read "Under $X" instead of a clean OK.
                floor_obj = app_materiality.applicable_floor(query_id, col_names)
                if floor_obj is not None:
                    below = int(con.execute(
                        f'SELECT count(*) FROM {filtered_table} WHERE ({where_sql}) AND t."status" IN '
                        f"('CRITICAL', 'WARN') AND ({status_col}) = 'OK'", params,
                    ).fetchone()[0])
                    floor_info = {"column": floor_obj.column, "min": floor_obj.min, "unit": floor_obj.unit,
                                  "label": floor_obj.label, "rows_below": below}

                is_flagged = f"(({status_col}) IN ('CRITICAL', 'WARN'))"
                # Rows the check listed but could not judge: part of the base, said apart from it.
                is_na = f"(({status_col}) = 'NOT_ASSESSED')"
                flagged_sql = f"({where_sql}) AND {is_flagged}"
                # A total or tie-out row is never added to the rows it totals or counted as an entity.
                parts_sql = (
                    f'COALESCE("{app_finding_columns.TOTAL_ROW_COLUMN}", FALSE) = FALSE'
                    if app_finding_columns.TOTAL_ROW_COLUMN in col_names else "TRUE"
                )
                declared_money = specs_by_id[query_id].money
                money_col = app_finding_columns.money_column(col_names, declared_money)
                if money_col is not None:
                    col, kind = money_col
                    unit = app_finding_columns.money_unit(col)
                    # One basis per kind, so a tile and the chart under it read the same figure: a
                    # waste or saving is the flagged rows' own; every other kind is every row listed.
                    basis = "flagged" if kind in app_finding_columns.FLAGGED_KINDS else "all"
                    money_where = flagged_sql if basis == "flagged" else where_sql
                    money_where = f"({money_where}) AND {parts_sql}"
                    if app_finding_columns.ALT_BASIS_COLUMN in col_names:
                        money_where += f' AND COALESCE("{app_finding_columns.ALT_BASIS_COLUMN}", FALSE) = FALSE'
                    # The flagged rows' share of an every-row figure rides along, so a tile can say "$x of $y".
                    row = con.execute(
                        f'SELECT SUM("{col}"), count("{col}"), SUM("{col}") FILTER (WHERE {is_flagged}), count(*) '
                        f"FROM {filtered_table} WHERE {money_where}", params
                    ).fetchone()
                    raw = float(row[0]) if row and row[0] is not None else None
                    priced_rows = int(row[1]) if row and row[1] is not None else 0
                    raw_flagged = None
                    if basis == "all" and unit != "currency":
                        raw_flagged = float(row[2]) if row[2] is not None else 0.0
                    currency = None
                    mixed_currency = False
                    cur_col = app_finding_columns.currency_column(col_names) if unit == "currency" else None
                    if unit == "currency":
                        if cur_col is None:
                            mixed_currency = True  # an amount with no currency is never summed as dollars
                        else:
                            codes = [r[0] for r in con.execute(
                                f'SELECT DISTINCT "{cur_col}" FROM {filtered_table} WHERE {money_where} '
                                f'AND "{col}" IS NOT NULL AND "{col}" <> 0 AND "{cur_col}" IS NOT NULL', params
                            ).fetchall()]
                            mixed_currency = len(codes) > 1
                            currency = codes[0] if len(codes) == 1 else None
                    basis_rows = int(row[3]) if row and row[3] is not None else 0
                    # storage figures (per month) need the storage price, the rest the credit price
                    export_priced = unit == "currency" or (
                        (_prices.get("storage_price_usd_tb_month") if "usd_month" in col
                         else _prices.get("credit_price_usd")) is not None)
                    # Never $0 for a figure nothing priced: rows with no non-null value mean unpriced. No
                    # rows at all (nothing flagged) is a real $0 when the export has a price, never "unpriced".
                    reason = "unpriced" if priced_rows == 0 and (basis_rows > 0 or not export_priced) else None
                    if reason and export_priced and basis_rows > 0 and "price_basis" in col_names:
                        # priced rows whose amount is empty (e.g. credits not attributed yet) are not "no price"
                        unpriced_rows = con.execute(
                            f"SELECT count(*) FROM {filtered_table} WHERE {money_where} AND price_basis = 'unpriced'",
                            params).fetchone()[0]
                        reason = "unpriced" if unpriced_rows else "no_amount"
                    if reason:
                        usd = None
                    elif raw is None:
                        usd = 0.0 if basis_rows == 0 else None
                    elif unit == "currency":
                        usd = None if mixed_currency else round(raw, 2)
                    else:
                        usd = round(raw * (1 - discount_pct), 2)
                    usd_flagged = (round(raw_flagged * (1 - discount_pct), 2)
                                   if raw_flagged is not None and usd is not None else None)
                    money = {"column": col, "kind": kind, "usd": usd, "unit": unit, "basis": basis,
                             "usd_flagged": usd_flagged,
                             "currency": currency, "mixed_currency": mixed_currency,
                             # where the $/credit behind this figure came from; a currency amount is the invoice's own
                             "price_basis": "invoice_currency" if unit == "currency" else basis_source}
                    if reason:
                        money["reason"] = reason  # only when set: "unpriced" (no price) or "no_amount" (priced rows with no figure)

                entity = app_finding_columns.entity_spec(col_names, specs_by_id[query_id].entity)
                if entity is not None:
                    noun, dim_table = entity["noun"], entity["dim_table"]
                    key_sql = _entity_key_sql(entity["columns"], "account_id" in col_names)
                    # A remainder row ("(warehouse idle)", "(untagged)") or one that names no entity (no id at all)
                    # stays in the money sum but is not an entity: it is counted as flagged_other.
                    placeholder_sql = (
                        f"(COALESCE(regexp_matches(CAST(\"{entity['columns'][-1]}\" AS VARCHAR), '^[(].*[)]$'), FALSE)"
                        f" OR ({key_sql}) IS NULL)"
                    )
                    ent_sql = f"{parts_sql} AND NOT {placeholder_sql}"
                    # One pass for all four counts: the flagged / not-judged parts are FILTERs over the scope.
                    ent_row = con.execute(
                        f"SELECT count(DISTINCT {key_sql}) FILTER (WHERE {is_flagged} AND {ent_sql}), "
                        f"count(*) FILTER (WHERE {is_flagged} AND NOT ({ent_sql})), "
                        f"count(DISTINCT {key_sql}) FILTER (WHERE {ent_sql}), "
                        f"count(DISTINCT {key_sql}) FILTER (WHERE {is_na} AND {ent_sql}) "
                        f"FROM {filtered_table} WHERE {where_sql}",
                        params,
                    ).fetchone()
                    flagged, flagged_other, own_total, not_assessed_n = (int(v or 0) for v in ent_row)
                    # A check that lists its OK rows too has assessed exactly those objects, so
                    # they are the base; one that lists only flagged rows is measured against
                    # every object of that kind in scope (the dim, never fewer than it saw).
                    lists_unflagged = any(s not in ("CRITICAL", "WARN") for s in status_counts)
                    if lists_unflagged or dim_table is None:
                        total = own_total
                    else:
                        dim_total = _dim_scope_count(
                            con, dim_table, entity["dim_key"], account_ids, env, attributes,
                        )
                        total = max(dim_total, own_total)
                    affected = {"column": entity["columns"][-1], "columns": entity["columns"], "noun": noun,
                                "flagged": flagged, "total": total, "flagged_other": flagged_other,
                                "not_assessed": not_assessed_n}
                else:
                    # No entity column on this table -- the check's own row is the thing being
                    # counted (a grant, a classified column, an event), so fall back to its own
                    # flagged/total row counts instead of leaving affected null.
                    row_counts = con.execute(
                        f"SELECT count(*) FILTER (WHERE {is_flagged} AND {parts_sql}), "
                        f"count(*) FILTER (WHERE {parts_sql}), "
                        f"count(*) FILTER (WHERE {is_na} AND {parts_sql}), "
                        f"count(*) FILTER (WHERE {is_flagged} AND NOT ({parts_sql})) "
                        f"FROM {filtered_table} WHERE {where_sql}",
                        params,
                    ).fetchone()
                    flagged, rows_n, na_n, other_n = (int(v or 0) for v in row_counts)
                    affected = {"column": None, "columns": None, "noun": app_finding_columns.row_noun(col_names),
                                "flagged": flagged, "total": rows_n, "flagged_other": other_n, "not_assessed": na_n}

            out[query_id] = {
                "rows_in_window": rows_in_window,
                "rows_total": rows_total,
                "status_counts": status_counts,
                "has_account_id": has_account_id,
                "tag_applied": tag_app.applied if tag_filter is not None else None,
                "tag_chain": tag_app.chain_words,
                "tag_chain_label": tag_app.chain_label,
                "tag_models_not_built": tag_models_not_built,
                "dim_applied": dim_applicability(col_names, dims),
                "owner_applied": owner_filterable(col_names, _task_column(col_names) is not None) if owner else None,
                "money": money,
                "affected": affected,
                "floor": floor_info,
            }
    finally:
        con.close()
    return out


def finding_columns_batch(query_ids: list[str]) -> dict[str, list[str]]:
    """The batch twin of finding_columns(): one connection for every id in `query_ids`. A query_id
    whose findings.f_<id> was never built is simply absent, not a FindingNotBuiltError."""
    out: dict[str, list[str]] = {}
    if not query_ids:
        return out
    con = _connect()
    try:
        for qid in query_ids:
            _validate_query_id(qid)
        table_names = [f"f_{qid}" for qid in query_ids]
        placeholders = ", ".join("?" for _ in table_names)
        for table_name, column_name in con.execute(
            "SELECT table_name, column_name FROM information_schema.columns "
            f"WHERE table_schema = 'findings' AND table_name IN ({placeholders}) "
            "ORDER BY table_name, ordinal_position",
            table_names,
        ).fetchall():
            out.setdefault(table_name[2:], []).append(column_name)
    finally:
        con.close()
    return out


# ---------------------------------------------------------------------------------------------
# aggregate_finding -- "cost figures come from full totals, not a 5,000-row slice". A tile
# or chart that needs a SUM/COUNT over a finding's rows must never derive it by fetching
# ui.max_rows (default 5000) rows and reducing them in the browser -- on a query whose grain is
# fine (day x workspace x product x tag, e.g. cost_chargeback_by_tag), that page can be a single
# day for the first few workspaces alphabetically while the chart is presented as covering the
# whole window. GROUP BY in SQL has no such cap: it scans every row matching the filters before
# ever truncating, so the numbers this function returns are exact, whatever the underlying finding
# table's row count.
# ---------------------------------------------------------------------------------------------

_AGG_FUNCS = ("sum", "count", "count_distinct")
_MAX_GROUP_COLS = 6
_MAX_EXTRA_COLS = 8


@dataclass
class AggregateGroup:
    key: tuple | None   # one value per `group` column, in table order; None for the "other" bucket
    value: object        # the aggregate result (sum/count), raw (undiscounted for a money column)
    row_count: int        # how many underlying detail rows fed this one group
    # for agg="sum" only, how many of this group's row_count rows had a NULL
    # `value` column -- 0 for agg="count"/"count_distinct" (row_count already answers "how many",
    # there is no separate NULL-vs-zero question for a count). SUM ignores NULLs (they never count
    # as a $0), so a group whose 5 rows are 4 real dollar amounts and 1 unpriced NULL reports the
    # same `value` a group of 4 fully-priced rows would -- a reader summing tile totals cannot tell
    # "this total is short some unpriced rows" from "this total is complete" without this field. See
    # aggregate_finding's own docstring for the SQL.
    null_rows: int = 0
    # `also` sums and `pick` values per group, by column name (None when neither was asked for).
    also: dict | None = None
    pick: dict | None = None


@dataclass
class AggregateResult:
    groups: list[AggregateGroup]
    other: AggregateGroup | None   # the folded remainder past `top`, or None if nothing was cut
    total_value: object             # sum(g.value for g in every group, incl. `other`) -- the TRUE total
    group_count: int                 # how many distinct groups exist BEFORE `top` folds the tail --
                                       # "N SKUs"/"N tag values" etc., not just len(groups) after the fold
    rows_total: int                  # rows matching window + account_ids/env/attributes (no status filter)
    matched_rows: int                 # rows matching window + every filter INCLUDING statuses -- what
                                       # the aggregate actually scanned; == sum of every group's row_count
    null_value_rows: int = 0          # sum(g.null_rows for g in every group INCLUDING the folded tail,
                                       # i.e. before `top` folds it) -- "how many of matched_rows never
                                       # entered total_value at all" (agg="sum" only; 0 otherwise)
    tag_application: "TagApplication" = field(default_factory=lambda: _NO_TAG_APPLICATION)
    floor: "app_materiality.Floor | None" = None   # this check's configured floor, or None
    excluded_no_account: dict | None = None   # None, or {"rows", "value"} 


def aggregate_finding(
    query_id: str,
    window_days: int,
    group: list[str],
    agg: str,
    value: str | None = None,
    *,
    account_ids: list[str] | None = None,
    env: list[str] | str | None = None,
    attributes: dict[str, list[str]] | None = None,
    statuses: list[str] | None = None,
    top: int | None = None,
    tag_filter: "app_core_tags.TagFilter | app_core_tags.TagFilterSet | None" = None,
    below_floor: bool = False,
    owner: str | None = None,
    include_totals: bool = False,
    dims: "DimFilter | None" = None,
    also: list[str] | None = None,
    pick: list[str] | None = None,
) -> AggregateResult:
    """`SELECT <group...>, <agg>("<value>") AS agg_value, count(*) AS row_count FROM
    findings."f_<query_id>" WHERE <read_finding's own filter set, minus the row LIMIT>
    GROUP BY <group> ORDER BY agg_value DESC` -- no LIMIT on the group-by itself, so every group
    the table actually has is scanned and returned (unless `top` folds the tail into `other`,
    which still keeps every row's value in the total -- see AggregateResult.total_value).

    `include_totals`: false (default) leaves out rows the check marks `is_total_row`.
    `below_floor`: when true, scans only the rows this check's materiality floor
    moved from CRITICAL/WARN to OK (app_materiality.below_floor_expr) -- "how much did the floor
    hide". A query with no applicable floor then matches nothing (never an error). Never combine
    with `statuses`: below_floor already implies the row's raw status was CRITICAL or WARN.

    `group` is 0-3 column names (_MAX_GROUP_COLS); each is validated against this table's OWN
    information_schema columns (via _table_columns, exactly the whitelist-before-splice discipline
    every other identifier in this module follows) and rejected if it names a MAP/STRUCT/LIST
    column (_is_complex) -- ValueError, never spliced unchecked. `agg` is one of _AGG_FUNCS:
    "sum"/"count_distinct" require `value` (also column-whitelisted); "count" ignores `value` and
    counts rows. `statuses` filters to those status values, same unaffected-if-no-status-column
    contract as read_finding's own `statuses` param -- applied to matched_rows/the aggregate
    itself, but NOT to `rows_total` (which mirrors read_finding's rows_total: window + workspace/
    env/attributes only, no status filter -- "how many rows exist here at all" vs "how many did
    this particular aggregate scan").

    Raises ValueError for a bad group/agg/value (the API layer turns that into a 422); anything
    else (a locked file, a genuine type mismatch DuckDB itself rejects) raises duckdb.Error/OSError
    same as every other read in this module. `tag_filter` applies to both `rows_total`
    and the aggregate itself, same as account_ids/env/attributes -- the fix for
    "aggregate_finding currently passes None [for tag]"."""
    spec = _validate_query_id(query_id)
    if len(group) > _MAX_GROUP_COLS:
        raise ValueError(f"group accepts at most {_MAX_GROUP_COLS} columns, got {len(group)}")
    if agg not in _AGG_FUNCS:
        raise ValueError(f"agg must be one of {_AGG_FUNCS}, got {agg!r}")
    if agg in ("sum", "count_distinct") and not value:
        raise ValueError(f"agg={agg!r} requires a value column")
    if top is not None and top < 1:
        raise ValueError(f"top must be >= 1, got {top}")
    # `also`: more columns summed per group in the same scan; `pick`: one value per group, taken
    # from the row with the largest `value` (a group of one row reads that row's own value).
    also = list(also or [])
    pick = list(pick or [])
    if len(also) > _MAX_EXTRA_COLS or len(pick) > _MAX_EXTRA_COLS:
        raise ValueError(f"also/pick accept at most {_MAX_EXTRA_COLS} columns each")

    con = _connect()
    try:
        cols = _table_columns(con, query_id)
        col_lookup = {name: dtype for name, dtype in cols}
        col_names = list(col_lookup)

        for g in group:
            if g not in col_lookup:
                raise ValueError(f"unknown group column {g!r} on {query_id}")
            if _is_complex(col_lookup[g]):
                raise ValueError(f"cannot group on complex column {g!r} on {query_id}")
        if value is not None and value not in col_lookup:
            raise ValueError(f"unknown value column {value!r} on {query_id}")
        # A column an older export lacks reads NULL, so one new column never fails the whole chart.
        for c in also + pick:
            if c in col_lookup and _is_complex(col_lookup[c]):
                raise ValueError(f"cannot read complex column {c!r} on {query_id}")

        has_account_id = account_filterable(col_names)
        has_tag = {"tag_key", "tag_value"}.issubset(col_names)
        has_status = "status" in col_names
        spend_table = app_tag_spend.table_sql(con, query_id, window_days, tag_filter)
        table = spend_table or f'findings."f_{query_id}" t'
        floor = app_materiality.applicable_floor(query_id, col_names)

        base_where_sql, base_params, _base_tag_app = _build_filters(
            window_days, account_ids, env, None, has_account_id, has_tag, attributes,
            tag_filter=tag_filter, table_sql=table, col_names=col_names, domain=spec.domain,
            query_id=query_id, con=con, owner=owner, tag_prefiltered=spend_table is not None, dims=dims,
        )
        rows_total = int(con.execute(f"SELECT count(*) FROM {table} WHERE {base_where_sql}", base_params).fetchone()[0])

        where_sql, params, tag_app = _build_filters(
            window_days, account_ids, env, None, has_account_id, has_tag, attributes,
            statuses=statuses, has_status=has_status,
            tag_filter=tag_filter, table_sql=table, col_names=col_names, domain=spec.domain,
            query_id=query_id, con=con, owner=owner, tag_prefiltered=spend_table is not None, dims=dims,
        )
        if below_floor:
            below_expr = app_materiality.below_floor_expr(query_id, col_names)
            if below_expr is not None:
                where_sql = f"({where_sql}) AND ({below_expr})"
            else:
                where_sql, params = "FALSE", []
        # A total or tie-out row is never added to its parts (same rule as the tile's money).
        if not include_totals and app_finding_columns.TOTAL_ROW_COLUMN in col_names:
            where_sql = f'({where_sql}) AND COALESCE("{app_finding_columns.TOTAL_ROW_COLUMN}", FALSE) = FALSE'
        # A sum never adds the same credits under a second allocation basis.
        if not include_totals and agg == "sum" and app_finding_columns.ALT_BASIS_COLUMN in col_names:
            where_sql = f'({where_sql}) AND COALESCE("{app_finding_columns.ALT_BASIS_COLUMN}", FALSE) = FALSE'

        # Materiality floor: a group-by on "status" itself groups on the EFFECTIVE status (a
        # below-floor row's group moves to OK), same as every other status read in this module.
        group_sql = ", ".join(
            app_materiality.status_expr(query_id, col_names) if g == "status" else f'"{g}"'
            for g in group
        )
        if agg == "sum":
            agg_expr = f'sum("{value}")'
        elif agg == "count_distinct":
            agg_expr = f'count(DISTINCT "{value}")'
        else:
            agg_expr = "count(*)"

        excluded_no_account = None
        if has_account_id and (account_ids or env or attributes):
            no_acct_sql = _no_account_clause(col_names)
            if no_acct_sql is not None:
                no_ws_where, no_ws_params, _ = _build_filters(
                    window_days, None, None, None, has_account_id, has_tag, None,
                    statuses=statuses, has_status=has_status,
                    tag_filter=tag_filter, table_sql=table, col_names=col_names, domain=spec.domain,
                    query_id=query_id, con=con, owner=owner, tag_prefiltered=spend_table is not None, dims=dims,
                )
                if below_floor:
                    excl_below_expr = app_materiality.below_floor_expr(query_id, col_names)
                    if excl_below_expr is not None:
                        no_ws_where = f"({no_ws_where}) AND ({excl_below_expr})"
                    else:
                        no_ws_where, no_ws_params = "FALSE", []
                excl_row = con.execute(
                    f"SELECT {agg_expr} AS agg_value, count(*) FROM {table} "
                    f"WHERE ({no_ws_where}) AND {no_acct_sql}",
                    no_ws_params,
                ).fetchone()
                excluded_no_account = {"rows": int(excl_row[1]), "value": excl_row[0]}

        # agg="sum" only, count("<value>") alongside count(*) -- SQL's
        # count(col) skips NULLs the same way sum(col) does, so row_count - value_rows is exactly
        # how many of this group's rows never entered the sum at all (a real, undisclosed gap a
        # bare SUM cannot distinguish from "every row here was priced"). "count"/"count_distinct"
        # already answer "how many" directly, so no extra column for those.
        has_value_rows = agg == "sum"
        status_sql = app_materiality.status_expr(query_id, col_names)

        def _pick_sql(c: str) -> str:
            if c not in col_lookup:
                return "NULL"
            col = status_sql if c == "status" else f't."{c}"'
            return f'coalesce(arg_max({col}, t."{value}"), any_value({col}))' if value else f"any_value({col})"

        extra_sql = "".join(f', sum(t."{c}")' if c in col_lookup else ", NULL" for c in also) + "".join(f", {_pick_sql(c)}" for c in pick)
        select_list = (
            (f"{group_sql}, " if group_sql else "")
            + f"{agg_expr} AS agg_value, count(*) AS row_count"
            + (f', count("{value}") AS value_rows' if has_value_rows else "")
            + extra_sql
        )
        group_by_sql = f" GROUP BY {group_sql}" if group_sql else ""
        sql = f"SELECT {select_list} FROM {table} WHERE {where_sql}{group_by_sql} ORDER BY agg_value DESC{', ' + group_sql if group_sql else ''}"
        rows = con.execute(sql, params).fetchall()
    finally:
        con.close()

    n = len(group)
    x0 = n + (3 if has_value_rows else 2)
    all_groups = []
    for r in rows:
        row_count = int(r[n + 1])
        null_rows = (row_count - int(r[n + 2])) if has_value_rows else 0
        also_vals = dict(zip(also, r[x0:x0 + len(also)])) if also else None
        pick_vals = dict(zip(pick, r[x0 + len(also):x0 + len(also) + len(pick)])) if pick else None
        all_groups.append(
            AggregateGroup(key=tuple(r[:n]) if n else (), value=r[n], row_count=row_count, null_rows=null_rows,
                           also=also_vals, pick=pick_vals)
        )
    matched_rows = sum(g.row_count for g in all_groups)
    null_value_rows = sum(g.null_rows for g in all_groups)
    # Every value NULL (an unpriced $ column): the total is unknown, never 0.
    all_null = has_value_rows and matched_rows > 0 and null_value_rows == matched_rows
    total_value = None if all_null else (sum((g.value or 0) for g in all_groups) if all_groups else 0)

    if top is not None and len(all_groups) > top:
        head = all_groups[:top]
        tail = all_groups[top:]
        other = AggregateGroup(
            key=None,
            value=sum((g.value or 0) for g in tail),
            row_count=sum(g.row_count for g in tail),
            null_rows=sum(g.null_rows for g in tail),
            also={c: sum((g.also[c] or 0) for g in tail) for c in also} if also else None,
        )
    else:
        head = all_groups
        other = None

    return AggregateResult(
        groups=head, other=other, total_value=total_value, group_count=len(all_groups),
        rows_total=rows_total, matched_rows=matched_rows, null_value_rows=null_value_rows,
        tag_application=tag_app, floor=floor, excluded_no_account=excluded_no_account,
    )


# ---------------------------------------------------------------------------------------------
# read_dim_account
# ---------------------------------------------------------------------------------------------


def read_dim_account() -> pd.DataFrame:
    """dims.dim_account: account_id (the account locator), name, url, env, env_source, env_reason,
    plus one <key>/<key>_share/<key>_reason column set per canonical tag key -- `SELECT *`, since
    that key set is config-driven and not enumerable here."""
    con = _connect()
    try:
        df = con.execute("SELECT * FROM dims.dim_account ORDER BY account_id").df()
        app_cost_center.apply_alias(con, df)
        return df
    finally:
        con.close()


def tag_spend_ready() -> bool:
    """True when the spend checks can follow the full tag order (tags.cost_day is built)."""
    con = _connect()
    try:
        return app_tag_spend.available(con)
    finally:
        con.close()


def read_tag_origins(tag_filter, window_days: int, workspace_scope: set[str] | None) -> dict | None:
    """Where the dollars a tag filter keeps got their tag (app/core/tag_spend.origins)."""
    con = _connect()
    try:
        return app_tag_spend.origins(con, tag_filter, window_days, workspace_scope)
    finally:
        con.close()


# ---------------------------------------------------------------------------------------------
# read_dim_warehouse / read_dim_task: the object-name dims a finding frame joins names from. A
# short-lived read-only connection unless the caller passes one in (GET /api/dims shares one), no
# caching, and no special-casing for "the dim is not built": a missing dims.* table raises
# duckdb.CatalogException like any other missing table, and callers degrade. Warehouse and task
# names are never masked (only person columns are).
# ---------------------------------------------------------------------------------------------


def read_dim_warehouse(con: duckdb.DuckDBPyConnection | None = None) -> pd.DataFrame:
    """dims.dim_warehouse: account_id, warehouse_id, warehouse_name. Callers join on
    warehouse_id alone (a warehouse id is unique within an account). `con`: reuse an open
    connection instead of opening and closing a new one."""
    owns_con = con is None
    if owns_con:
        con = _connect()
    try:
        return con.execute(
            "SELECT account_id, warehouse_id, warehouse_name FROM dims.dim_warehouse ORDER BY warehouse_id"
        ).df()
    finally:
        if owns_con:
            con.close()


def read_dim_task(con: duckdb.DuckDBPyConnection | None = None) -> pd.DataFrame:
    """dims.dim_task: account_id, task_full_name (database.schema.task, the join key), task_name,
    database_name, schema_name, owner_role. `con`: see read_dim_warehouse."""
    owns_con = con is None
    if owns_con:
        con = _connect()
    try:
        return con.execute(
            "SELECT account_id, task_full_name, task_id, task_name, database_name, schema_name, owner_role "
            "FROM dims.dim_task ORDER BY account_id, task_full_name"
        ).df()
    finally:
        if owns_con:
            con.close()


# ---------------------------------------------------------------------------------------------
# Export metadata: direct_export_meta / direct_export_findings_meta, written by tools/load_results.py
# ---------------------------------------------------------------------------------------------


@_file_cached(lambda: _db_path())
def direct_export_info() -> dict | None:
    """{"as_of", "as_of_date", "includes_today", "window_coverage", "windows", "window_aliases",
    "account", "pricing", "masked", "tag_sources_cut"} from direct_export_meta, else None. account is {id, name, cloud, region},
    pricing {source, credit_price_usd, storage_price_usd_tb_month}. as_of_date is the first day the export left out (a range's
    exclusive end); with includes_today, today up to as_of is in and partial. window_coverage is
    {"<label>": days_used}; `windows` is the manifest's labels list, exported_window_coverage()'s
    fallback when window_coverage is absent; window_aliases is {"<alias label>": "<source label>"}
    for a label the export reused another's rows for."""
    con = None
    try:
        con = _connect()
        cur = con.execute("SELECT * FROM main.direct_export_meta LIMIT 1")
        names = [d[0] for d in cur.description]
        fetched = cur.fetchone()
        rec = dict(zip(names, fetched)) if fetched else None
    except duckdb.Error:  # no such table, or the db is missing or locked
        return None
    finally:
        if con is not None:
            con.close()
    if not rec:
        return None
    try:
        aliases = json.loads(rec["window_aliases"]) if rec.get("window_aliases") else {}
    except ValueError:
        aliases = {}
    return {
        "as_of": rec.get("as_of"),
        "as_of_date": rec.get("as_of_date"),
        "includes_today": bool(rec.get("includes_today")),
        "last_complete_day": rec.get("last_complete_day"),
        "lag_hours": rec.get("lag_hours"),
        "window_coverage": json.loads(rec["window_coverage"]) if rec.get("window_coverage") else None,
        "windows": json.loads(rec["windows"]) if rec.get("windows") else None,
        "window_aliases": aliases,
        "account": json.loads(rec["account"]) if rec.get("account") else None,
        "pricing": json.loads(rec["pricing"]) if rec.get("pricing") else None,
        "visibility": json.loads(rec["visibility"]) if rec.get("visibility") else None,
        "edition": json.loads(rec["edition"]) if rec.get("edition") else None,
        # The kinds of names the export replaced with tokens (app/core/masking.py); [] = none.
        "masked": json.loads(rec["masked"]) if rec.get("masked") else [],
        # Tag sources the export cut at its row limit: spend by tag can read low.
        "tag_sources_cut": json.loads(rec["tag_sources_cut"]) if rec.get("tag_sources_cut") else [],
    }


# "not passed" (fetch it) vs "passed as None" (confirmed: no export meta) for the pre-fetch params
# below -- None alone can't carry both meanings.
_UNSET = object()


@_file_cached(lambda: _db_path())
def _measured_window_days(labels) -> dict[int, int]:
    """{label: actual distinct usage_date span} measured off cost_dollarized_by_service_day (every
    export carries it): a manifest's `windows` list only names which labels were RUN, not how many
    days each one captured, so trusting label == days covered would turn a real 10-day export
    stored under window 30 into a false "30d, fully covered". Empty on any read problem -- callers
    fall back to the label itself."""
    con = None
    try:
        con = _connect()
        rows = con.execute(
            "SELECT window_days, MIN(usage_date), MAX(usage_date) FROM findings.f_cost_dollarized_by_service_day "
            "WHERE window_days = ANY(?) GROUP BY window_days",
            [[int(w) for w in labels]],
        ).fetchall()
    except duckdb.Error:
        return {}
    finally:
        if con is not None:
            con.close()
    return {
        int(label): (hi - lo).days + 1 for label, lo, hi in rows if lo is not None and hi is not None
    }


def exported_window_coverage(direct: dict | None = _UNSET) -> dict[int, int] | None:
    """{label: days_used} from the export's own window_coverage meta, keys as ints; None when the
    db has no export meta (every label then reads as fully built). A manifest that predates
    window_coverage falls back to the real span measured off its own data. `direct`, when given, is
    an already-read direct_export_info() result (None included) -- skips a second connection."""
    if direct is _UNSET:
        direct = direct_export_info()
    if direct is None:
        return None
    coverage = direct.get("window_coverage")
    if coverage:
        return {int(label): days_used for label, days_used in coverage.items()}
    windows = direct.get("windows")
    if isinstance(windows, list) and windows:
        measured = _measured_window_days(windows)
        return {int(w): measured.get(int(w), int(w)) for w in windows}
    return None


def window_status(choices: tuple[int, ...], direct: dict | None = _UNSET) -> list[dict]:
    """Per label in `choices`: {"days", "available", "covered_days", "partial"} -- the window
    control's own feed. A label the export never ran reads available=False rather than a silent
    empty read. `direct`: see exported_window_coverage."""
    coverage = exported_window_coverage(direct)
    out = []
    for w in choices:
        if coverage is None:
            out.append({"days": w, "available": True, "covered_days": w, "partial": False})
            continue
        covered = coverage.get(w)
        if covered is None:
            out.append({"days": w, "available": False, "covered_days": None, "partial": False})
        else:
            out.append({"days": w, "available": True, "covered_days": covered, "partial": covered < w})
    return out


_NO_TRUNCATION = {"truncated": False, "max_rows": None}


@_file_cached(lambda: _db_path())
def truncation_info(query_id: str, window_days: int | None = None) -> dict:
    """{"truncated", "max_rows"} recorded by tools/load_results.py for this query_id from the
    export's own row cap; _NO_TRUNCATION when the id was never loaded. `window_days`, when given,
    answers for that window alone against truncated_windows (e.g. only the 90d run hit the cap)."""
    con = None
    try:
        con = _connect()
        row = con.execute(
            "SELECT truncated, max_rows, truncated_windows FROM main.direct_export_findings_meta "
            "WHERE query_id = ?",
            [query_id],
        ).fetchone()
    except duckdb.Error:
        return dict(_NO_TRUNCATION)
    finally:
        if con is not None:
            con.close()
    if not row:
        return dict(_NO_TRUNCATION)
    truncated, max_rows, windows_json = row
    windows = json.loads(windows_json) if windows_json else None
    if window_days is not None and windows:
        return {"truncated": window_days in windows, "max_rows": max_rows}
    return {"truncated": bool(truncated), "max_rows": max_rows}


@_file_cached(lambda: _db_path())
def fallback_sources() -> dict:
    """{query_id: {"source", "reads", "note"}} for the checks the export read from INFORMATION_SCHEMA
    because the role could not read their ACCOUNT_USAGE views; {} for an older db without the column."""
    con = None
    try:
        con = _connect()
        rows = con.execute(
            "SELECT query_id, source FROM main.direct_export_findings_meta WHERE source IS NOT NULL"
        ).fetchall()
    except duckdb.Error:
        return {}
    finally:
        if con is not None:
            con.close()
    return {qid: json.loads(src) for qid, src in rows}


def truncated_query_ids() -> list[str]:
    """query_ids the export's own row cap hit (direct_export_findings_meta.truncated)."""
    con = None
    try:
        con = _connect()
        rows = con.execute(
            "SELECT query_id FROM main.direct_export_findings_meta WHERE truncated ORDER BY query_id"
        ).fetchall()
    except duckdb.Error:
        return []
    finally:
        if con is not None:
            con.close()
    return [r[0] for r in rows]


# ---------------------------------------------------------------------------------------------
# run_results / finding_status
# ---------------------------------------------------------------------------------------------

_UNAVAILABLE_RUN_RESULTS = {"available": False, "generated_at": None, "checks": {}}


def run_results() -> dict:
    """The loader's run_results sidecar: {"available": bool, "generated_at": str | None,
    "checks": {<query_id>: {"status": "ok" | "failed", "message"}}}. Missing or unparsable file ->
    {"available": False, "checks": {}}, never an exception."""
    path = _run_results_path()
    if not path.exists():
        return dict(_UNAVAILABLE_RUN_RESULTS)
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return dict(_UNAVAILABLE_RUN_RESULTS)
    checks = {
        r["query_id"]: {"status": r.get("status", ""), "message": r.get("message"),
                        "reason": r.get("reason"), "sources": r.get("sources") or [],
                        "all_rows_not_assessed": bool(r.get("all_rows_not_assessed"))}
        for r in data.get("results", []) if r.get("query_id")
    }
    return {"available": True, "generated_at": data.get("generated_at"), "checks": checks}


# reason code -> (plain label, the fix a reader can act on). Snowflake reports a view the role
# cannot see and a view the account lacks in almost the same words, so one code names the access
# case and the other the absence. The fix of a no_access reason is rewritten per check with its own
# GRANT (see reason_fix).
COVERAGE_REASON_FIX: dict[str, tuple[str, str]] = {
    "no_access": (
        "the role can't see it",
        "Grant the audit role IMPORTED PRIVILEGES on the SNOWFLAKE database and the MONITOR grants in the README.",
    ),
    "view_missing": (
        "not available in this account",
        "The view or feature is not in this account: it may need a higher edition or an organization account.",
    ),
    "edition_too_low": (
        "needs a higher Snowflake edition",
        "This feature needs Enterprise Edition or higher; no grant changes that.",
    ),
    "timeout": ("timed out reading it", "Re-run the export with a shorter window."),
    "not_exported": ("not run in this export", "Re-run the export: this check produced no result last time."),
    "unknown": ("failed in the export", "Re-run the export and check its own error output for this check."),
}
# The stored cause an export or validate wrote, in this vocabulary (a real SQL error reads "unknown").
_CAUSE_TO_REASON = {"no_access": "no_access", "view_missing": "view_missing", "timeout": "timeout",
                    "edition_too_low": "edition_too_low", "sql_error": "unknown"}


def coverage_reason(message: str | None, stored: str | None = None) -> str:
    """An export error message -> one of COVERAGE_REASON_FIX's keys. `stored` is the cause the export
    recorded (it wins over the message). `message` is None for a check absent from the run results
    entirely (never attempted) -- "not_exported", never "unknown"."""
    if stored in _CAUSE_TO_REASON:
        return _CAUSE_TO_REASON[stored]
    if message is None:
        return "not_exported"
    return _CAUSE_TO_REASON[app_reasons.classify_error(message)]


def export_edition(direct: dict | None = None) -> str | None:
    """The account's edition when the export found it (STANDARD, ENTERPRISE, ...), else None."""
    info = direct if direct is not None else direct_export_info()
    return ((info or {}).get("edition") or {}).get("edition")


def resolve_reason(spec: "registry.QuerySpec", message: str | None, stored: str | None,
                   edition: str | None) -> str:
    """coverage_reason, with the edition applied: a check that needs Enterprise on a known Standard
    account is edition_too_low whatever Snowflake's message said (a grant would not help)."""
    reason = coverage_reason(message, stored)
    if (reason in ("no_access", "view_missing")
            and app_reasons.edition_at_least(edition, "ENTERPRISE") is False
            and app_reasons.needs_enterprise(spec.requires, spec.empty_if)):
        return "edition_too_low"
    return reason


def spec_source_keys(spec: "registry.QuerySpec") -> list[str]:
    return [source_key(schema, name) for schema, name in spec.sources if schema != "FUNCTION"]


def reason_fix(reason: str, spec: "registry.QuerySpec", sources: list[str] | None = None) -> str:
    """The fix a reader can act on for this check: its own GRANT lines for an access problem."""
    generic = COVERAGE_REASON_FIX[reason][1]
    if reason != "no_access":
        return generic
    grants = app_reasons.grants_for(sources or spec_source_keys(spec))
    return ("Run: " + " ".join(grants)) if grants else generic


def source_key(schema: str, name: str) -> str:
    """One source as the coverage feed names it: ACCOUNT_USAGE.QUERY_HISTORY, SHOW WAREHOUSES,
    SYSTEM$CLIENT_VERSION_INFO()."""
    if schema == "SHOW":
        return f"SHOW {name}"
    if schema == "FUNCTION":
        return f"{name}()"
    return f"{schema}.{name}"


def direct_source_states(dependents: dict[str, list[str]], results: dict | None = None) -> dict[str, dict]:
    """Coverage & Gaps' per-source state, keyed by source_key: {"state" ("ok" or "not_assessed"),
    "rows" (the summed row count of every reading check that succeeded, None when none did),
    "reason", "message", "dependent_query_ids", "checks_ok"/"checks_total", "covers" ("window" when
    a windowed check reads it, else "current"), "window_days"}. `dependents` is the coverage
    route's own source -> [query_id, ...] map.

    A source is "ok" the moment ANY reading check succeeded, however many rows it returned ("empty"
    is for the caller to derive from rows == 0). It is "not_assessed" only when EVERY reading check
    failed or was never run."""
    results = run_results() if results is None else results
    checks = results.get("checks", {})
    export = direct_export_info()
    window_days = max(export["windows"]) if export and export.get("windows") else None
    qid_rows: dict[str, int] = {}
    con = None
    if any(checks.get(qid, {}).get("status") == "ok" for ids in dependents.values() for qid in ids):
        try:
            con = _connect()
        except duckdb.Error:
            con = None

    def rows_for(qid: str) -> int | None:
        if qid in qid_rows:
            return qid_rows[qid]
        if con is None:
            return None
        try:
            n = int(con.execute(f'SELECT count(*) FROM findings."f_{qid}"').fetchone()[0])
        except duckdb.Error:
            return None
        qid_rows[qid] = n
        return n

    out: dict[str, dict] = {}
    try:
        for key, qids in dependents.items():
            rows_sum = 0
            ok_count = 0
            rows_known = False
            fail_message = None
            for qid in qids:
                check = checks.get(qid)
                if not check or check.get("status") != "ok":
                    if fail_message is None and ok_count == 0:
                        fail_message = check.get("message") if check else None
                    continue
                ok_count += 1
                n = rows_for(qid)
                if n is not None:
                    rows_sum += n
                    rows_known = True
            any_ok = ok_count > 0
            is_window = any(registry.by_id(q).windowed for q in qids)
            out[key] = {
                "state": "ok" if any_ok else "not_assessed",
                "rows": (rows_sum if rows_known else None) if any_ok else None,
                "reason": None if any_ok else coverage_reason(fail_message),
                "message": None if any_ok else fail_message,
                "dependent_query_ids": qids,
                "checks_ok": ok_count,
                "checks_total": len(qids),
                "covers": "window" if is_window else "current",
                "window_days": window_days if is_window else None,
            }
    finally:
        if con is not None:
            con.close()
    return out


def finding_status(query_id: str, results: dict | None = None) -> dict:
    """One check's run state: {"query_id", "status" ("ok" | "failed" | "not_built" when absent from
    the run results), "message", "run_results_available"}. `results` lets a caller looping over many
    ids read the sidecar once. NOT_ASSESSED must mean "we know we could not look", never "we have
    no metadata": with no sidecar, a table that exists is still read."""
    _validate_query_id(query_id)
    results = run_results() if results is None else results
    check = results["checks"].get(query_id)
    if check is None:
        status, message = "not_built", None
    else:
        status, message = check["status"], check["message"]
    return {
        "query_id": query_id,
        "status": status,
        "message": message,
        "reason": (check or {}).get("reason"),
        "sources": (check or {}).get("sources") or [],
        "all_rows_not_assessed": bool((check or {}).get("all_rows_not_assessed")),
        "run_results_available": bool(results.get("available")),
    }


NOT_EXPORTED_FIX = ("not run in this export", "Re-run the export: this window was never captured.")
ALL_ROWS_NOT_ASSESSED_FIX = (
    "every row not assessed",
    "This check could not judge any row in scope: see its own confidence note.",
)
NOT_BUILT_FIX = ("not in this export", "Re-run the export; this check is newer than it.")


def _na(spec, code, label, fix, partial: bool = False, sources: list[str] | None = None) -> dict:
    """One not-assessed verdict, with what the check needs to read: its own `requires` line and the
    GRANT lines that open its sources."""
    keys = sources or spec_source_keys(spec)
    return {"code": code, "label": label, "fix": fix, "partial": partial,
            "requires": spec.requires, "grants": app_reasons.grants_for(keys), "sources": keys}


def not_assessed_status(
    spec: "registry.QuerySpec",
    results: dict | None = None,
    *,
    window_days: int | None = None,
    exported_coverage: dict[int, int] | None = None,
    all_rows_not_assessed: bool = False,
    table_exists: bool | None = None,
    edition: str | None = _UNSET,
) -> dict | None:
    """None when `spec` is cleanly assessed; else {"code", "label", "fix", "partial", "requires",
    "grants", "sources"}.

    code is one of not_built (missing from the run results and table_exists is not True),
    build_failed (the check errored in the export; label and fix come from the stored cause, the error
    message and the account's edition), not_exported (a windowed check this window's export never ran)
    or all_rows_not_assessed (every row in scope reads NOT_ASSESSED). `partial` is True with code/label/
    fix all None for a check that ran and reads fine but the export covered fewer days than the window --
    still assessed, just incomplete. `window_days`/`exported_coverage` are the caller's own per-request
    window and exported_window_coverage(); omitted, the window checks are skipped (right for
    /api/coverage, which has no window). `table_exists` is the caller's own live check for
    findings.f_<id> and suppresses not_built when the run results have no entry for it."""
    results = run_results() if results is None else results
    info = finding_status(spec.query_id, results)
    if edition is _UNSET:
        edition = export_edition()

    if info["status"] == "not_built" and table_exists is not True:
        label, fix = NOT_BUILT_FIX
        return _na(spec, "not_built", label, fix)
    if info["status"] == "failed":
        reason = resolve_reason(spec, info["message"], info.get("reason"), edition)
        label = COVERAGE_REASON_FIX[reason][0]
        return _na(spec, "build_failed", label, reason_fix(reason, spec, info.get("sources")),
                   sources=info.get("sources") or None) | {"reason": reason}
    if (
        spec.windowed and window_days is not None and exported_coverage is not None
        and window_days not in exported_coverage
    ):
        label, fix = NOT_EXPORTED_FIX
        return _na(spec, "not_exported", label, fix)
    if all_rows_not_assessed or info.get("all_rows_not_assessed"):
        label, fix = ALL_ROWS_NOT_ASSESSED_FIX
        return _na(spec, "all_rows_not_assessed", label, fix)
    window_partial = (
        spec.windowed and window_days is not None and exported_coverage is not None
        and exported_coverage.get(window_days, window_days) < window_days
    )
    if window_partial:
        return {"code": None, "label": None, "fix": None, "partial": True,
                "requires": spec.requires, "grants": [], "sources": []}
    return None


def checks_not_ok(specs: list[registry.QuerySpec], results: dict | None = None) -> list[dict]:
    """Coverage & Gaps' "Couldn't check" feed: one entry per spec not_assessed_status flags with a
    code, as {"query_id", "title", "reason", "reason_label", "fix", "message", "sources"}. The same
    function drives /api/findings' per-row not_assessed field, so the two screens never name one
    gap two ways. A DB error reading the table list falls back to the run results alone."""
    results = run_results() if results is None else results
    checks = results.get("checks", {})
    edition = export_edition()
    try:
        table_cols = finding_columns_batch([s.query_id for s in specs])
    except (duckdb.Error, OSError):
        table_cols = None
    out: list[dict] = []
    for spec in specs:
        table_exists = (spec.query_id in table_cols) if table_cols is not None else None
        info = not_assessed_status(spec, results, table_exists=table_exists, edition=edition)
        if info is None or info["code"] is None:
            continue  # clean, or merely partial (still assessed)
        check = checks.get(spec.query_id)
        out.append({
            "query_id": spec.query_id,
            "title": spec.title,
            "reason": info["code"],
            "reason_label": info["label"],
            "fix": info["fix"],
            "cause": info.get("reason"),
            "requires": info["requires"],
            "grants": info["grants"],
            "message": check.get("message") if check else None,
            "sources": [source_key(schema, name) for schema, name in spec.sources],
            "unreadable_sources": info["sources"] if info["code"] == "build_failed" else [],
        })
    return out


def _parse_date(value: object) -> date | None:
    if not value:
        return None
    if isinstance(value, datetime):
        return value.date()
    if isinstance(value, date):
        return value
    text = str(value).strip()
    try:
        return datetime.fromisoformat(text.replace("Z", "+00:00")).date()
    except ValueError:
        try:
            return date.fromisoformat(text[:10])
        except ValueError:
            return None


def window_coverage(query_id: str, window_days: int, exported: dict[int, int] | None = _UNSET) -> dict:
    """{"query_id", "window_days", "as_of_date", "partial", "covered_days", "sources"}: `partial`
    when the export covered fewer days than the window (a 10-day export read at 30d says so).
    `exported`, when given, is an already-read exported_window_coverage() result (None included)."""
    _validate_query_id(query_id)
    if exported is _UNSET:
        exported = exported_window_coverage()
    covered = exported.get(window_days) if exported is not None else None
    if covered is None:
        covered = window_days
    direct = direct_export_info()
    return {
        "query_id": query_id,
        "window_days": window_days,
        "as_of_date": direct.get("as_of_date") if direct else None,
        "partial": covered < window_days,
        "covered_days": covered,
        "sources": {},
    }


# ---------------------------------------------------------------------------------------------
# cost_cutoff
# ---------------------------------------------------------------------------------------------


def cost_cutoff() -> dict:
    """The one money cut-off: {"data_through" (the last complete day), "partial_day" (today, when
    the export kept it), "partial_until" (HH:MM UTC of the export)}, all None without an export.
    as_of_date is the first day the export left out, so data through as_of_date - 1 is in: with
    includes_today that day is today and partial, else it is complete."""
    empty = {"data_through": None, "partial_day": None, "partial_until": None, "partial_from": None}
    direct = direct_export_info()
    if not direct:
        return empty
    as_of_date = _parse_date(direct.get("as_of_date"))
    if as_of_date is None and _parse_date(direct.get("as_of")):
        as_of_date = _parse_date(direct.get("as_of")) + timedelta(days=1 if direct.get("includes_today") else 0)
    if as_of_date is None:
        return empty
    last_in = as_of_date - timedelta(days=1)
    last_complete = _parse_date(direct.get("last_complete_day"))
    if not direct.get("includes_today"):
        through = min(last_in, last_complete) if last_complete else last_in
        return {"data_through": through.isoformat(), "partial_day": None, "partial_until": None,
                "partial_from": None}
    partial_until = None
    try:
        partial_until = datetime.fromisoformat(str(direct["as_of"]).replace("Z", "+00:00")).strftime("%H:%M")
    except (ValueError, TypeError):
        pass
    # Yesterday is complete only once the view lag has passed; until then it is part of the partial span.
    through = last_in - timedelta(days=1)
    if last_complete is not None:
        through = min(through, last_complete)
    return {
        "data_through": through.isoformat(),
        "partial_day": last_in.isoformat(),
        "partial_until": partial_until,
        "partial_from": (through + timedelta(days=1)).isoformat(),
    }


# ---------------------------------------------------------------------------------------------
# Price basis: where the $/credit behind every money figure came from, and the discount what-if
# ---------------------------------------------------------------------------------------------

_PRICE_SOURCE_LABELS = {
    "cli": "the credit price you passed to the export",
    "settings": "the default credit price in config/settings.yml, not your invoice",
    "usage_in_currency_daily": "your effective rate from the last 90 days of the invoice view (after your discounts)",
    "rate_sheet_daily": "your contract rate from the organization rate sheet (after your discounts)",
}


def price_basis() -> dict:
    """The one price basis every money figure shares: {"credit_price_usd", "source" (the export's own
    word), "source_short" ("invoice" | "cli" | "settings" | "unpriced"), "label", "invoice_derived",
    "ai_credit_price_usd", "ai_source", "storage_price_usd_tb_month", "storage_source"}. A rate read from the invoice is already net of
    the customer's discounts, so a discount what-if never applies to it (effective_discount_pct)."""
    pricing = (direct_export_info() or {}).get("pricing") or {}
    price = pricing.get("credit_price_usd")
    source = pricing.get("source") if price is not None else None
    invoice = source in ("usage_in_currency_daily", "rate_sheet_daily")
    short = "unpriced" if price is None else ("invoice" if invoice else (source or "cli"))
    return {
        "credit_price_usd": price,
        "source": source,
        "source_short": short,
        "label": _PRICE_SOURCE_LABELS.get(source) if price is not None else "no credit price: $ figures are not shown",
        "invoice_derived": invoice,
        "ai_credit_price_usd": pricing.get("ai_credit_price_usd"),
        "ai_source": pricing.get("ai_source"),
        "storage_price_usd_tb_month": pricing.get("storage_price_usd_tb_month"),
        "storage_source": pricing.get("storage_source") or (pricing.get("source") if pricing.get("storage_price_usd_tb_month") is not None else None),
    }


def effective_discount_pct(configured: float | None = None) -> float:
    """The discount to apply: the configured what-if, except 0 when the credit price came from the
    invoice (it is already discounted; applying the what-if again would stack)."""
    if configured is None:
        configured = float(app_config.load_settings().get("discount_pct", 0.0) or 0.0)
    return 0.0 if price_basis()["invoice_derived"] else float(configured)


def discount_info(configured: float | None = None) -> dict:
    """{"configured", "effective", "ignored", "reason"} for the response body."""
    if configured is None:
        configured = float(app_config.load_settings().get("discount_pct", 0.0) or 0.0)
    effective = effective_discount_pct(configured)
    ignored = bool(configured) and effective == 0.0
    return {"configured": float(configured), "effective": effective, "ignored": ignored,
            "reason": ("the $/credit is your invoice rate, which already includes your discounts"
                       if ignored else None)}


# ---------------------------------------------------------------------------------------------
# Checks that ran: ONE definition for every page
# ---------------------------------------------------------------------------------------------


def checks_ran_summary(specs: list["registry.QuerySpec"] | None = None, results: dict | None = None) -> dict:
    """{"ran", "total", "unit", "not_ran": {code: n}, "definition"}. A check RAN when this export ran it
    and it produced a table whose rows are not all NOT_ASSESSED. Independent of the window and the
    filters, so the top bar, Overview, Coverage and the Guide print the same number."""
    specs = specs if specs is not None else [s for s in registry.load_registry() if s.executable]
    results = run_results() if results is None else results
    edition = export_edition()
    try:
        table_cols = finding_columns_batch([s.query_id for s in specs])
    except (duckdb.Error, OSError):
        table_cols = None
    ran = 0
    not_ran: dict[str, int] = {}
    for spec in specs:
        exists = (spec.query_id in table_cols) if table_cols is not None else None
        info = not_assessed_status(spec, results, table_exists=exists, edition=edition)
        if info is None or info["code"] is None:
            ran += 1
        else:
            not_ran[info["code"]] = not_ran.get(info["code"], 0) + 1
    return {"ran": ran, "total": len(specs), "unit": "checks", "not_ran": not_ran,
            "definition": "checks that ran: the export ran the check and at least one row is assessed"}


# ---------------------------------------------------------------------------------------------
# What the role can see
# ---------------------------------------------------------------------------------------------


def visibility_summary(direct: dict | None = None) -> dict | None:
    """The export's role-visibility probe, ready for the Coverage page: unreadable sources and SHOW
    statements with the GRANT that opens each, and the billed-versus-listed warehouse gap. None when the
    export has no probe (an older export)."""
    info = direct if direct is not None else direct_export_info()
    vis = (info or {}).get("visibility")
    if not vis:
        return None
    unreadable = [{"source": src, "message": msg,
                   "grant": app_reasons.grant_for(src)} for src, msg in (vis.get("unreadable") or {}).items()]
    failed = [{"source": stmt, "message": msg, "grant": app_reasons.grant_for(stmt)}
              for stmt, msg in (vis.get("failed_pre") or {}).items()]
    wh = vis.get("warehouses")
    warehouses = None
    if wh and wh.get("metered") is not None:
        missing = int(wh.get("missing_from_show") or 0)
        metered = int(wh["metered"])
        # Prose only: the grant's own SQL comment ("-- one per warehouse") never reaches the screen.
        grant_stmt = (app_reasons.grant_for("SHOW WAREHOUSES") or "").split("--")[0].strip()
        warehouses = {
            "billed": metered, "visible": metered - missing, "missing": missing, "unit": "warehouses",
            "note": (f"Role sees {metered - missing} of {metered} billed warehouses. To see the rest, run "
                     f"{grant_stmt} for each warehouse.") if missing else None,
            "grant": grant_stmt or None,
        }
    return {"probed": vis.get("probed"), "unreadable": unreadable + failed, "warehouses": warehouses,
            "edition": (info or {}).get("edition")}


def finding_visibility(spec: "registry.QuerySpec", summary: dict | None) -> dict | None:
    """A per-check role-limited note, or None: a check that lists warehouses through SHOW WAREHOUSES
    sees only the ones the role holds MONITOR on."""
    if not summary or not summary.get("warehouses") or not summary["warehouses"]["missing"]:
        return None
    reads_show_wh = ("SHOW", "WAREHOUSES") in [tuple(x) for x in spec.sources]
    if not reads_show_wh and "monitor on the warehouses" not in (spec.requires or "").lower():
        return None
    return {"limited": True, "note": summary["warehouses"]["note"], "billed": summary["warehouses"]["billed"],
            "visible": summary["warehouses"]["visible"], "unit": "warehouses"}
