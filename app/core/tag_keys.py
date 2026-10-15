"""app/core/tag_keys.py -- the shared tag vocabulary: key normalisation, the sentinel values, the
rollup level names and the source codes with their on-screen words. Stdlib only.
"""
from __future__ import annotations

import re

# ---- sentinel tag values (never a real tag value: real values never start with "__") ---------
UNTAGGED = "__untagged__"   # the thing exists but carries no value for this key
MIXED = "__mixed__"         # inferred level (account, billed entity): tagged, no dominant value
NONE = "__none__"           # there is no thing at this level (no account, no query, no compute)
EMPTY = "__empty__"         # API/URL spelling of a key-only tag (stored value "")
SENTINELS = frozenset({UNTAGGED, MIXED, NONE})

# ---- levels of the nested rollup, outermost first ---------------------------------------------
LEVELS = ("account", "workspace", "compute", "work")
LEVEL_LABELS = {
    "account": "Account",
    "workspace": "Account tag",
    "compute": "Warehouse tag",
    "work": "Query / task tag",
}

# ---- where a tag value came from ---------------------------------------------------------------
SOURCE_LABELS = {
    "account_inferred": "account tag, inferred from the bill",
    "query_tags": "query tag",
    "warehouse_tags": "warehouse tag",
    "object_tags": "object tag (database, schema, table or task)",
    "user_tags": "user tag",
    "role_tags": "role tag",
    "account_tags": "account tag",
}

_NORM_RE = re.compile(r"[ _-]+")


def normalize_tag_key(raw: str | None) -> str:
    """Lower-cased, every run of spaces, hyphens
    and underscores removed -- "Cost Center", "cost-center" and "cost_center" are one key. Returns
    "" for None or a key made only of separators (the API rejects "")."""
    if raw is None:
        return ""
    return _NORM_RE.sub("", str(raw).lower())


def api_value_to_model(value: str | None) -> str | None:
    """A tag_value query parameter as the models store it: EMPTY -> "" (a key-only tag), anything
    else unchanged (None means "any value of this key")."""
    return "" if value == EMPTY else value


def model_value_to_api(value: str | None) -> str | None:
    """A stored tag value as the API returns it: "" -> EMPTY, anything else unchanged."""
    return EMPTY if value == "" else value


def is_real_value(value: str | None) -> bool:
    """True for a real tag value (including the key-only ""), False for None and every sentinel."""
    return value is not None and value not in SENTINELS
