"""app/core/cost_center.py -- the configured cost_center_tag_keys setting (config/settings.yml),
resolved against the generic per-key account tag data tags.tag_account so a raw key
other than the shipped default "cost_center" counts as the cost-center attribute everywhere the
app already has one without a
rebuild: tags.tag_account already carries one row per (account, raw tag key) it has ever seen,
computed generically, not per a registered alias list.

When the configuration is still the shipped default, every function here is a no-op and the
existing config/tag_aliases.yml-driven dims.dim_account.cost_center column stays
the only source, byte-identical to today -- this module only takes over once the team points
cost_center_tag_keys at something else.

Stdlib + this repo's own app.core modules only; app.core.data is imported lazily (inside
`suggestions()`, the one function that opens its own connection) to avoid a circular import, the
same discipline app/core/tags.py already follows.
"""
from __future__ import annotations

import duckdb

from app.core import config as app_config
from app.core import tag_keys

DEFAULT_KEYS = ("cost_center",)
_SENTINEL_WORDS = {tag_keys.UNTAGGED: "not_tagged", tag_keys.MIXED: "mixed"}


def configured_keys() -> list[str]:
    """The raw cost_center_tag_keys settings value, falling back to the shipped default on a
    broken settings.yml (never raises -- callers never need a try/except of their own)."""
    try:
        settings = app_config.load_settings()
    except app_config.ConfigError:
        return list(DEFAULT_KEYS)
    return list(settings.get("cost_center_tag_keys") or DEFAULT_KEYS)


_STORED: dict = {}


def _stored_under() -> dict[str, str]:
    """{raw key spelling, lower-case: the tag_key it is stored under}. A tag alias can file a raw
    key such as team_space_name under another name, so a configured raw key still finds it."""
    from app.core import data as app_core_data  # local: data imports this module

    path = app_core_data._db_path()
    try:
        cache_key = (str(path), path.stat().st_mtime_ns)
    except OSError:
        return {}
    if cache_key not in _STORED:
        try:
            con = app_core_data._connect()
            try:
                rows = con.execute("SELECT DISTINCT lower(display_key), tag_key FROM tags.tag_index").fetchall()
            finally:
                con.close()
        except duckdb.Error:
            rows = []
        _STORED.clear()
        _STORED[cache_key] = {spelling: key for spelling, key in rows if spelling}
    return _STORED[cache_key]


def normalized_keys() -> list[str]:
    """configured_keys() as the tag_key each is stored under, in order, de-duplicated -- the form
    tags.tag_account's own tag_key column is already stored in."""
    seen: dict[str, None] = {}
    stored = _stored_under()
    for key in configured_keys():
        norm = stored.get(key.strip().lower()) or tag_keys.normalize_tag_key(key)
        if norm:
            seen.setdefault(norm, None)
    return list(seen)


def is_default() -> bool:
    """True when the configured keys normalise to exactly the shipped default -- the existing
    config/tag_aliases.yml-driven dims.dim_account.cost_center column already covers this case,
    so nothing here needs to override it."""
    return normalized_keys() == [tag_keys.normalize_tag_key(k) for k in DEFAULT_KEYS]


def tag_account_exists(con: duckdb.DuckDBPyConnection) -> bool:
    return bool(
        con.execute(
            "SELECT count(*) FROM information_schema.tables "
            "WHERE table_schema = 'tags' AND table_name = 'tag_account'"
        ).fetchone()[0]
    )


def _dim_account_has_cost_center(con: duckdb.DuckDBPyConnection) -> bool:
    return bool(
        con.execute(
            "SELECT count(*) FROM information_schema.columns WHERE table_schema = 'dims' "
            "AND table_name = 'dim_account' AND column_name = 'cost_center'"
        ).fetchone()[0]
    )


def _should_override(con: duckdb.DuckDBPyConnection) -> bool:
    """False only when the configuration is still the shipped default AND dims.dim_account
    already carries its own cost_center column --
    the common case, left byte-identical. True once the team configures anything else, OR
    whenever dim_account never built the column at all -- a real gap on at least one account
    this app already runs against (an older build, or one whose tag_aliases.yml carried no
    canonical keys at build time): "costcenter", the default's own normalised spelling, is then
    the ONLY place this data exists, and nothing needs preserving."""
    if not is_default():
        return True
    return not _dim_account_has_cost_center(con)


def account_values(con: duckdb.DuckDBPyConnection) -> dict[str, dict]:
    """{account_id: {"value", "share", "coverage", "reason"}}, one entry per workspace that
    carries ANY of the configured keys in tags.tag_account -- the FIRST configured key (in list
    order) that has a row for that workspace wins. `value` is already mapped to dim_account's own
    words (__untagged__ -> not_tagged, __mixed__ -> mixed) so a caller can treat it exactly like
    dim_account.cost_center. {} when nothing should be overridden (see _should_override) or
    tags.tag_account was never built."""
    norm_keys = normalized_keys()
    if not norm_keys or not tag_account_exists(con) or not _should_override(con):
        return {}
    placeholders = ", ".join("?" for _ in norm_keys)
    rows = con.execute(
        f"""
        SELECT account_id, tag_key, tag_value, share, coverage, reason
        FROM tags.tag_account
        WHERE tag_key IN ({placeholders})
        """,
        norm_keys,
    ).fetchall()
    rank = {key: i for i, key in enumerate(norm_keys)}
    best: dict[str, tuple] = {}
    for account_id, key, value, share, coverage, reason in rows:
        r = rank.get(key, len(rank))
        if account_id not in best or r < best[account_id][0]:
            best[account_id] = (r, value, share, coverage, reason)
    return {
        ws: {
            "value": _SENTINEL_WORDS.get(value, value),
            "share": share,
            "coverage": coverage,
            "reason": reason,
        }
        for ws, (_, value, share, coverage, reason) in best.items()
    }


def apply_alias(con: duckdb.DuckDBPyConnection, df) -> None:
    """Overwrites a dims.dim_account-shaped DataFrame's cost_center/cost_center_share/
    cost_center_coverage/cost_center_reason columns IN PLACE with the configured-key values above,
    ADDING those columns when the build never carried them at all (an older build, or one whose
    config/tag_aliases.yml had no canonical keys at the time -- real on at least one account this
    app already runs against). A workspace missing from account_values() reads 'no_usage' when
    dim_account's own base value already said so (no billed credits at all -- true regardless of
    which key means cost center), else 'not_tagged'. A no-op (df untouched) when the configuration
    is still the default or tags.tag_account is missing."""
    values = account_values(con)
    if not values:
        return
    if "cost_center" not in df.columns:
        df["cost_center"] = "not_tagged"
        df["cost_center_share"] = None
        df["cost_center_reason"] = "no dims.dim_account.cost_center column in this build"
    has_coverage = "cost_center_coverage" in df.columns
    for i, account_id in enumerate(df["account_id"]):
        entry = values.get(account_id)
        if entry is not None:
            df.at[i, "cost_center"] = entry["value"]
            df.at[i, "cost_center_share"] = entry["share"]
            if has_coverage:
                df.at[i, "cost_center_coverage"] = entry["coverage"]
            df.at[i, "cost_center_reason"] = entry["reason"]
        elif df.at[i, "cost_center"] != "no_usage":
            df.at[i, "cost_center"] = "not_tagged"
            df.at[i, "cost_center_share"] = None
            if has_coverage:
                df.at[i, "cost_center_coverage"] = None
            df.at[i, "cost_center_reason"] = (
                "no usage row on this workspace carried any of the configured cost-center tag key(s)"
            )


def attribute_filter_sql(con: duckdb.DuckDBPyConnection, values: list[str]) -> tuple[str, list] | None:
    """A `SELECT account_id FROM ...` fragment (and its bound params) that replaces the plain
    `dims.dim_account."cost_center" IN (...)` join: the workspace ids the configured keys' own
    values resolve to. The caller wraps it itself -- `account_id IN (...)` when its own table has
    a bare account_id column (app/core/data.region_split_or_none), or through
    app/core/data._in_accounts otherwise. None when
    there is nothing to override (see _should_override) or tags.tag_account is missing -- the
    caller then falls back to the dim_account-only join, unaffected."""
    norm_keys = normalized_keys()
    if not norm_keys or not values or not tag_account_exists(con) or not _should_override(con):
        return None
    key_placeholders = ", ".join("?" for _ in norm_keys)
    value_placeholders = ", ".join("?" for _ in values)
    order_case = " ".join(f"WHEN ? THEN {i}" for i in range(len(norm_keys)))
    sql = (
        "SELECT account_id FROM ("
        "SELECT account_id, "
        f"CASE tag_value WHEN '{tag_keys.UNTAGGED}' THEN 'not_tagged' "
        f"WHEN '{tag_keys.MIXED}' THEN 'mixed' ELSE tag_value END AS value, "
        f"ROW_NUMBER() OVER (PARTITION BY account_id ORDER BY CASE tag_key {order_case} END) AS rn "
        f"FROM tags.tag_account WHERE tag_key IN ({key_placeholders})"
        f") ranked WHERE rn = 1 AND value IN ({value_placeholders})"
    )
    params = list(norm_keys) + list(norm_keys) + list(values)
    return sql, params


def suggestions(limit: int = 40) -> list[dict]:
    """Tag keys seen anywhere in the data (tags.tag_index), normalised + display spelling, each
    with its total credits and object count -- both already pre-aggregated in tags.tag_index, so this
    is cheap. [] when the tag index was never built."""
    from app.core import data as app_core_data  # local: avoids a circular import at module level

    con = app_core_data._connect()  # noqa: SLF001 -- this module is data.py's own sibling
    try:
        exists = con.execute(
            "SELECT count(*) FROM information_schema.tables "
            "WHERE table_schema = 'tags' AND table_name = 'tag_index'"
        ).fetchone()[0]
        if not exists:
            return []
        rows = con.execute(
            """
            SELECT tag_key, ANY_VALUE(display_key) AS display_key,
                   SUM(COALESCE(credits, 0)) AS credits, SUM(object_count) AS object_count
            FROM tags.tag_index
            GROUP BY tag_key
            ORDER BY credits DESC, object_count DESC, display_key
            LIMIT ?
            """,
            [limit],
        ).fetchall()
        return [
            {
                "tag_key": key,
                "display_key": display_key,
                "credits": float(credits or 0),
                "object_count": int(object_count or 0),
            }
            for key, display_key, credits, object_count in rows
        ]
    finally:
        con.close()
