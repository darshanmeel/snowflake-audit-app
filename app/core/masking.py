"""Mask chosen kinds of names in an export, at export time, so the files never hold the real ones.

Off by default. tools/export_results.py (--mask, or privacy.mask_fields for Refresh) and the export
kit call mask_folder() on the finished results folder, before the manifest and report are written.
This file uses only the standard library and pyarrow: tools/make_export_kit.py copies it into the
kit's single run_export.py.

Kinds: user, warehouse, database, schema, object (tables, views, stages, pipes, streams, dynamic
tables, functions, alerts, notebooks), role, task, account.

- A name becomes the same token everywhere in the export (checks, dims, tag sources, manifest), so
  joins, name (id) labels and per-name totals still work. A user keeps the app's identity format
  "<8 hex> <first 2 chars>***"; every other kind reads "<prefix>_<8 hex>", e.g. wh_3f2a9c1b.
- Names are matched without case (Snowflake folds unquoted names to upper case).
- A full name (DB.SCHEMA.TABLE, a task's full name) is masked part by part.
- Every other text cell (reasons, notes, error text, JSON) gets the same replacement wherever a known
  name appears as a whole word, so a name cannot leak through free text.
- The hash is salted: a random salt per export unless one is given, so a common name such as
  COMPUTE_WH cannot be looked up from its token. The salt is never written anywhere.
- System names are never masked: the SNOWFLAKE database, INFORMATION_SCHEMA, the system roles and
  placeholders such as "(warehouse idle)".
"""
from __future__ import annotations

import hashlib
import re
import secrets
from pathlib import Path

import pyarrow as pa
import pyarrow.parquet as pq

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
