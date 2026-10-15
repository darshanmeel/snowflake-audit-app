"""Shared parser for the Snowflake SQL header schema.

Every check file in app/queries/checks/*.sql opens with a comment header. This module
parses that header into a dict. It is the single source of truth for the header contract:
build_manifest.py and lint_headers.py both import it. The domain comes from the header, not the folder.

Stdlib only — no third-party dependencies.
"""
from __future__ import annotations

import re
from pathlib import Path

# The 14 canonical header fields, in schema order. `tier` rides on the `domain:` line.
FIELDS = [
    "query_id",
    "title",
    "domain",
    "reads",
    "requires",
    "params",
    "confidence",
    "confidence_note",
    "read_this",
    "healthy",
    "investigate_if",
    "actions",
    "next",
    "caveats",
]

# Optional header fields (absent => a default).
#   runnable: false   copy-paste-only query, kept out of the runner (default true).
#   empty_if          coverage reasons a query can return zero rows (EMPTY_IF_VOCAB).
#   not_assessed_reasons  code -> plain words for every value the query's own
#                     `not_assessed_reason` column can carry.
#   windowed: yes|no  yes = the period_days selector drives the query (default no).
#   pre               a SHOW statement run first on the same cursor so RESULT_SCAN can read it;
#                     the line may repeat, order is kept.
#   money: <column>   the one output column that is the check's headline money figure (tiles and charts
#                     both read it); a check that names none falls back to the column-name maps in
#                     app/core/finding_columns.py.
#   entity: <noun> = <col>[, <col>]   what one row of the table is an instance of, and the column(s)
#                     that identify it (the "N of M <noun>" count); a check that names none falls back
#                     to the entity columns in app/core/finding_columns.py.
OPTIONAL_FIELDS = ["runnable", "empty_if", "not_assessed_reasons", "windowed", "pre", "money", "entity"]
LIST_FIELDS = {"pre"}

# Controlled vocabulary for the optional `empty_if:` field: the machine-checkable reasons a check
# can come back empty, so an empty result reads as a real gap and not as "nothing there".
EMPTY_IF_VOCAB = {
    "edition_too_low",         # the view or feature needs a higher Snowflake edition (e.g. Enterprise)
    "role_cannot_see",         # the export role lacks the privilege; it sees fewer rows or none
    "org_account_only",        # ORGANIZATION_USAGE is readable only from the organization account
    "view_missing",            # the view does not exist in this account / region yet
    "retention_window",        # activity older than the view's retention is gone
    "no_activity",             # genuinely no matching activity in the window
    "ingestion_lag",           # recent activity not yet in the view
}

CONFIDENCE_ENUM = {"confirmed", "needs_confirmation"}
TIER_ENUM = {"lite", "standard", "deep"}
DOMAINS = {
    "cost",
    "performance",
    "compute",
    "jobs_pipelines",
    "serving_ai",
    "storage",
    "governance_access",
}

_FIELD_RE = re.compile(r"^--\s*(" + "|".join(FIELDS + OPTIONAL_FIELDS) + r")\s*:\s?(.*)$")
_DOMAIN_RE = re.compile(r"^\s*(\S+)\s+tier\s*:\s*(\S+)\s*$")
_PARAM_RE = re.compile(r":(\w+)\s*\(default\s+([^)]+)\)\s*(.*)")
# not_assessed_reasons: one "code: plain words" entry per not_assessed_reason value, ";"-separated
# (the same split style as `params:`) -- code is the exact string the query's own CASE emits.
_REASON_RE = re.compile(r"^([a-z][a-z0-9_]*)\s*:\s*(.+)$", re.I)
# A next-token is a query_id optionally followed by a parenthetical condition.
# The condition may itself contain commas, so we split the field only on TOP-LEVEL commas.
_NEXT_SPLIT_RE = re.compile(r",(?![^(]*\))")
_NEXT_RE = re.compile(r"^([a-z0-9_]+)\s*(?:\(\s*(?:if\s+)?(.*?)\s*\))?$", re.I)
_ACTION_SPLIT_RE = re.compile(r"\s*\d+\)\s*")


class HeaderError(ValueError):
    pass


def _raw_fields(text: str) -> dict:
    """Extract raw (string) field values from the leading comment block."""
    fields: dict[str, str] = {}
    current: str | None = None
    for line in text.splitlines():
        if not line.startswith("--"):
            # First non-comment line ends the header block.
            break
        m = _FIELD_RE.match(line)
        if m:
            current = m.group(1)
            if current in LIST_FIELDS:
                fields.setdefault(current, []).append(m.group(2).strip())
            else:
                fields[current] = m.group(2).strip()
        else:
            # Continuation line: append to the field (or the last repeat of a list field).
            cont = line[2:].strip()
            if current is not None and cont:
                if current in LIST_FIELDS:
                    fields[current][-1] = (fields[current][-1] + " " + cont).strip()
                else:
                    fields[current] = (fields[current] + " " + cont).strip()
    return fields


def parse_params(value: str) -> list[dict]:
    """":name (default X) meaning; :name2 (default Y) meaning2" -> [{name, default, meaning}].
    "none" (a check with no tunable value) -> []."""
    out = []
    for chunk in value.split(";"):
        chunk = chunk.strip()
        if not chunk:
            continue
        m = _PARAM_RE.search(chunk)
        if not m:
            continue
        name, default, meaning = m.group(1), m.group(2).strip(), m.group(3).strip()
        val: object = default
        try:
            val = int(default)
        except ValueError:
            try:
                val = float(default)
            except ValueError:
                val = default
        out.append({"name": name, "default": val, "meaning": meaning})
    return out


def parse_next(value: str) -> list[dict]:
    out = []
    if not value or value.strip().lower().startswith(("n/a", "none")):
        return out
    # Split on TOP-LEVEL commas only (_NEXT_SPLIT_RE): a next-token's "(if ...)" condition may
    # itself contain commas, and a plain str.split(",") would shred it and silently drop the
    # target. A non-empty token that still fails to parse is a malformed next-entry (typo,
    # unbalanced paren) and is raised loudly rather than dropped — a broken cross-link must fail
    # the linter, not vanish into an empty list that quietly passes.
    for token in _NEXT_SPLIT_RE.split(value):
        token = token.strip()
        if not token:
            continue
        m = _NEXT_RE.match(token)
        if not m:
            raise HeaderError(f"malformed next-entry token {token!r}")
        out.append({"query_id": m.group(1), "if": (m.group(2) or "").strip()})
    return out


def parse_actions(value: str) -> list[str]:
    if not value or value.strip().lower().startswith("n/a"):
        return []
    parts = [p.strip().rstrip(";").rstrip() for p in _ACTION_SPLIT_RE.split(value) if p.strip()]
    return parts


def parse_entity(value: str) -> dict | None:
    """"dynamic tables = database_name, schema_name, dt_name" -> {"noun", "columns"}; absent -> None.
    A value that is not "<noun> = <col>[, <col>]" is a typo in the header and is raised loudly."""
    value = (value or "").strip()
    if not value:
        return None
    noun, sep, cols = value.partition("=")
    columns = [c.strip() for c in cols.split(",") if c.strip()]
    if not sep or not noun.strip() or not columns:
        raise HeaderError(f"malformed entity {value!r} (want '<noun> = <column>[, <column>]')")
    return {"noun": noun.strip(), "columns": columns}


def parse_reads(value: str) -> list[str]:
    return [r.strip() for r in value.split(",") if r.strip()]


def parse_not_assessed_reasons(value: str) -> dict[str, str]:
    """"code: words; code2: words2" -> {code: words}. Empty/absent/"n/a" -> {} (most queries carry
    no `not_assessed_reason` column at all). A non-empty chunk that does not match "code: words" is
    a typo in the header, not a silently-dropped entry -- raised loudly, the same discipline
    parse_next uses for a malformed next-entry."""
    out: dict[str, str] = {}
    if not value or value.strip().lower().startswith("n/a"):
        return out
    for chunk in value.split(";"):
        chunk = chunk.strip()
        if not chunk:
            continue
        m = _REASON_RE.match(chunk)
        if not m:
            raise HeaderError(f"malformed not_assessed_reasons entry {chunk!r}")
        out[m.group(1)] = m.group(2).strip()
    return out


def parse_header(text: str, *, path: str = "<memory>") -> dict:
    """Parse a full SQL file's text into a structured header dict.

    Raises HeaderError on a structurally-broken header (missing required field or
    malformed domain line). Value-level validation lives in lint_headers.py.
    """
    raw = _raw_fields(text)
    for f in FIELDS:
        if f not in raw:
            raise HeaderError(f"{path}: missing required header field '{f}'")

    dm = _DOMAIN_RE.match(raw["domain"])
    if not dm:
        raise HeaderError(
            f"{path}: 'domain:' line must read '<domain>   tier: <tier>', got {raw['domain']!r}"
        )
    domain, tier = dm.group(1), dm.group(2)

    try:
        nxt = parse_next(raw["next"])
    except HeaderError as e:
        raise HeaderError(f"{path}: {e}") from None

    # Optional: `windowed: yes|no` (default no) and `pre:` SHOW statements (list, in order).
    windowed = raw.get("windowed", "no").strip().lower().startswith("yes")
    pre = [p for p in raw.get("pre", []) if p]
    # Optional: `runnable: false` (default true) excludes a copy-paste-only query from the runner.
    runnable = not raw.get("runnable", "true").strip().lower().startswith("false")
    # Optional: `empty_if: <token>, ...` — machine-checkable coverage reasons the query can be empty.
    empty_if = [t.strip().lower() for t in raw.get("empty_if", "").split(",") if t.strip()]
    # Optional: `not_assessed_reasons: code: words; ...` — plain words for this query's own
    # not_assessed_reason codes, if it carries that column at all.
    try:
        not_assessed_reasons = parse_not_assessed_reasons(raw.get("not_assessed_reasons", ""))
    except HeaderError as e:
        raise HeaderError(f"{path}: {e}") from None

    try:
        entity = parse_entity(raw.get("entity", ""))
    except HeaderError as e:
        raise HeaderError(f"{path}: {e}") from None
    money = raw.get("money", "").strip() or None

    return {
        "query_id": raw["query_id"].strip(),
        "title": raw["title"].strip(),
        "domain": domain,
        "tier": tier,
        "windowed": windowed,
        "pre": pre,
        "runnable": runnable,
        "empty_if": empty_if,
        "not_assessed_reasons": not_assessed_reasons,
        "money": money,
        "entity": entity,
        "reads": parse_reads(raw["reads"]),
        "requires": raw["requires"].strip(),
        "params": parse_params(raw["params"]),
        "confidence": raw["confidence"].strip(),
        "confidence_note": raw["confidence_note"].strip(),
        "read_this": raw["read_this"].strip(),
        "healthy": raw["healthy"].strip(),
        "investigate_if": raw["investigate_if"].strip(),
        "actions": parse_actions(raw["actions"]),
        "next": nxt,
        "caveats": raw["caveats"].strip(),
        "_raw": raw,
    }


def iter_query_files(queries_dir: Path):
    for p in sorted(queries_dir.glob("*.sql")):
        yield p


def load_all(queries_dir: Path) -> dict[str, dict]:
    """query_id -> parsed header, for every .sql directly in queries_dir."""
    out = {}
    for p in iter_query_files(queries_dir):
        hdr = parse_header(p.read_text(encoding="utf-8"), path=str(p))
        out[hdr["query_id"]] = hdr
    return out
