"""Spend checks under a tag filter.

The Snowflake export has no tag-spend variants yet: no check is re-computed over the dollars a tag
keeps, so every function here reports "not available" and the callers read the check's own table
under the tag filter as they do for any other check. The names stay so app/core/data.py and
app/api/guide.py keep one code path for when variants exist.
"""
from __future__ import annotations

CHAIN_WORDS = ["query", "object", "warehouse", "user or role", "account"]
CHAIN_LABEL = "the most specific tag on each billed dollar: query, object, warehouse, user or role, then account"


def has_variant(query_id: str) -> bool:
    return False


def available(con) -> bool:
    return False


def origins(con, tag_filter, window_days: int, workspace_scope: set[str] | None = None) -> dict | None:
    return None


def table_sql(con, query_id: str, window_days: int, tag_filter) -> str | None:
    return None
