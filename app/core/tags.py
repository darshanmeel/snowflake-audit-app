"""app/core/tags.py -- the tag search index reader,
the per-finding "which tag reaches this row" chain, and the WHERE-clause/SELECT builder the tag
filter uses on /api/findings, /api/finding/{id} and /aggregate.

    TagFilter(key, value)               a validated, normalised tag filter
    TagFilter.from_params(tag_key, tag_value)   builds one from raw query params; ValueError on a
                                         bad combination (the API turns that into a 422)
    TagFilterSet(groups)                several tag NAMES: OR within one name's values, AND across
                                         names (TagFilterSet.from_params(tag_key, tag_value, tag)) --
                                         additive to TagFilter, which still means exactly what it
                                         did (TagFilterSet.single wraps one as a one-group set)
    tag_group_clause / tag_set_clause   the OR-within-a-name / AND-across-names SQL, built by
                                         calling tag_clause() once per (key, value) and combining
    read_tag_index(search, tag_key, limit_keys, limit_values) -> dict   the GET /api/tags body
    tag_chain(query_id, col_names, domain) -> TagChain   which tags.tag_entity lookups (in order)
                                         reach this finding table's rows, or the row-tags branch,
                                         or "not applicable"
    tag_clause(chain, table_sql, tag_filter) -> TagClause   the bound WHERE/SELECT SQL fragments

Every identifier ever spliced into SQL text here comes from this module's own closed vocabulary
(tag_keys.SOURCE_LABELS' codes, the fixed column names the chain lists) or from the calling
table's OWN information_schema columns (already whitelisted by app/core/data.py's caller) -- never
from the tag_key/tag_value VALUES, which are always bound parameters.

Stdlib + this repo's own app.core modules only.
"""
from __future__ import annotations

import sys
from dataclasses import dataclass, field
from pathlib import Path
from urllib.parse import unquote

_ROOT = Path(__file__).resolve().parent.parent.parent
if str(_ROOT) not in sys.path:
    sys.path.insert(0, str(_ROOT))

from app.core import tag_keys  # noqa: E402

# app.core.data is imported lazily, inside the one function that needs it (_tag_index_connect),
# not at module level: data.py itself imports this module (app/core/tags.py) at module level for
# tag_chain/tag_clause, and a module-level import here in the other direction would be circular.


class TagModelsNotBuiltError(RuntimeError):
    """tags.tag_entity (or tags.tag_index) does not exist in the current db -- the tags models
    were never built or failed. Callers report NOT_ASSESSED with reason `tag_models_not_built`
 rather than silently returning unfiltered rows."""


# ---------------------------------------------------------------------------------------------
# TagFilter
# ---------------------------------------------------------------------------------------------


@dataclass(frozen=True)
class TagFilter:
    key: str                 # normalised (tag_keys.normalize_tag_key)
    value: str | None        # None = any value; "" = key-only; tag_keys.UNTAGGED; or a real value

    @staticmethod
    def from_params(tag_key: str | None, tag_value: str | None) -> "TagFilter | None":
        """Section 4.4: `tag_value` without `tag_key` is a ValueError (-> 422). An empty
        `tag_key` after normalising is also a ValueError. No `tag_key` at all (and so no
        `tag_value`) means no filter -- returns None."""
        if tag_key is None:
            if tag_value is not None:
                raise ValueError("tag_value given without tag_key")
            return None
        norm = tag_keys.normalize_tag_key(tag_key)
        if not norm:
            raise ValueError(f"tag_key {tag_key!r} normalises to empty")
        value = tag_keys.api_value_to_model(tag_value) if tag_value is not None else None
        return TagFilter(key=norm, value=value)


# ---------------------------------------------------------------------------------------------
# TagFilterSet -- several tag NAMES: OR within one name's values, AND across names. Additive to
# TagFilter above (still the single key:value shape every existing caller/test uses unchanged);
# _build_filters (app/core/data.py) normalises a bare TagFilter into a one-group set before
# compiling it, so both go through the same tag_group_clause/tag_set_clause machinery below.
# ---------------------------------------------------------------------------------------------


@dataclass(frozen=True)
class TagValueGroup:
    """One AND'd term: `key` (normalised) matches when the entity's tag resolves to ANY of
    `values` (OR within the name) -- an empty tuple means "All" (the key is present, any real
    value; UNTAGGED excluded), the same meaning as a bare TagFilter(key, value=None)."""

    key: str
    values: tuple[str, ...] = ()


@dataclass(frozen=True)
class TagFilterSet:
    """Several TagValueGroup, ANDed together. Never empty when not None -- from_params returns
    None instead (no filter at all), same as TagFilter.from_params."""

    groups: tuple[TagValueGroup, ...]

    @staticmethod
    def single(tf: "TagFilter") -> "TagFilterSet":
        """Wraps one legacy TagFilter as a one-group set -- what _build_filters normalises a bare
        TagFilter into before calling tag_set_clause."""
        return TagFilterSet(groups=(TagValueGroup(key=tf.key, values=() if tf.value is None else (tf.value,)),))

    @staticmethod
    def from_params(
        tag_key: str | None, tag_value: str | None, tag: list[str] | None = None
    ) -> "TagFilterSet | None":
        """Builds the set from the legacy `tag_key`/`tag_value` pair (still a ValueError the same
        way TagFilter.from_params is -- `tag_value` without `tag_key` or a `tag_key` normalising to
        empty) plus zero or more repeated `tag` entries, each "<key>" (All) or "<key>:<value>" (one
        value -- split on the FIRST ':', so a value may itself contain ':'; a key containing ':'
        must be percent-encoded, e.g. "aws%3Aowner:alice"). Two entries sharing a normalised key OR
        their values; "All" on a key swallows any specific values also given for it. None (no
        filter) when nothing at all was given."""
        by_key: dict[str, list[str] | None] = {}  # None = "All" for that key

        def _add(norm: str, value: str | None) -> None:
            if norm not in by_key:
                by_key[norm] = None if value is None else [value]
            elif value is None:
                by_key[norm] = None  # "All" swallows whatever specific values were collected so far
            elif by_key[norm] is not None:
                by_key[norm].append(value)
            # else: already "All" and a specific value arrives -- stays "All", nothing to add.

        if tag_key is not None or tag_value is not None:
            legacy = TagFilter.from_params(tag_key, tag_value)  # raises the same ValueErrors as today
            if legacy is not None:
                _add(legacy.key, legacy.value)

        for entry in tag or []:
            raw_key, sep, raw_value = entry.partition(":")
            norm = tag_keys.normalize_tag_key(unquote(raw_key))
            if not norm:
                raise ValueError(f"tag {entry!r} normalises to an empty key")
            value = tag_keys.api_value_to_model(raw_value) if sep else None
            _add(norm, value)

        if not by_key:
            return None
        groups = tuple(TagValueGroup(key=k, values=() if v is None else tuple(v)) for k, v in by_key.items())
        return TagFilterSet(groups=groups)


# ---------------------------------------------------------------------------------------------
# read_tag_index -- GET /api/tags
# ---------------------------------------------------------------------------------------------


def _tag_index_connect():
    """One read-only connection, same short-lived-per-call discipline as app/core/data.py.
    Raises TagModelsNotBuiltError when tags.tag_index does not exist -- the caller (the API
    route) turns that into the 503."""
    from app.core import data as app_core_data  # local: see the module docstring's import note

    con = app_core_data._connect()  # noqa: SLF001 -- this module is data.py's own sibling
    exists = con.execute(
        "SELECT count(*) FROM information_schema.tables "
        "WHERE table_schema = 'tags' AND table_name = 'tag_index'"
    ).fetchone()[0]
    if not exists:
        con.close()
        raise TagModelsNotBuiltError("tags.tag_index does not exist -- rebuild to search tags")
    return con


def read_tag_index(
    search: str | None = None,
    tag_key: str | None = None,
    limit_keys: int = 20,
    limit_values: int = 50,
) -> dict:
    """The body of GET /api/tags. `search` matches case-insensitively over the
    display key, every raw key spelling, and values. `tag_key` (any spelling; normalised here)
    restricts to one key's values ("all values"). With neither, returns the top `limit_keys` keys
    by total credits, then object_count, then display_key.

    Raises TagModelsNotBuiltError when tags.tag_index is missing."""
    norm_key = tag_keys.normalize_tag_key(tag_key) if tag_key else None
    needle = (search or "").strip().lower()

    con = _tag_index_connect()
    try:
        where = []
        params: list = []
        if norm_key:
            where.append("tag_key = ?")
            params.append(norm_key)
        where_sql = f"WHERE {' AND '.join(where)}" if where else ""

        key_rows = con.execute(
            f"""
            SELECT tag_key, ANY_VALUE(display_key) AS display_key,
                   ANY_VALUE(raw_keys) AS raw_keys,
                   list(DISTINCT source) AS sources,
                   SUM(COALESCE(credits, 0)) AS total_credits,
                   SUM(object_count) AS total_objects
            FROM tags.tag_index
            {where_sql}
            GROUP BY tag_key
            """,
            params,
        ).fetchall()

        def _matches_key(display_key: str, raw_keys: str) -> bool:
            if not needle:
                return True
            if needle in (display_key or "").lower():
                return True
            return any(needle in rk.lower() for rk in (raw_keys or "").split(","))

        keys_out = []
        truncated = False
        # Keys matching the search directly (by key spelling) come first; a key whose VALUE
        # matches (but not its own spelling) is included too, once we know it has a matching
        # value below -- there is no requirement for a strict two-pass order beyond "keys
        # ordered by total credits, then object_count, then display_key", so both groups share that
        # same ordering.
        candidate_keys = sorted(
            key_rows, key=lambda r: (-(r[4] or 0), -(r[5] or 0), (r[1] or r[0]))
        )

        for tag_key_norm, display_key, raw_keys, sources, total_credits, total_objects in candidate_keys:
            value_rows = con.execute(
                """
                SELECT tag_value, source, object_count, account_count, credits
                FROM tags.tag_index
                WHERE tag_key = ?
                ORDER BY object_count DESC, tag_value, source
                """,
                [tag_key_norm],
            ).fetchall()

            key_spelling_matches = _matches_key(display_key, raw_keys)
            value_matches = [v for v in value_rows if needle and needle in (v[0] or "").lower()]
            if needle and not key_spelling_matches and not value_matches:
                continue
            if norm_key and tag_key_norm != norm_key:
                continue

            by_value: dict[str, dict] = {}
            order: list[str] = []
            for tag_value, source, object_count, account_count, credits in value_rows:
                api_value = tag_keys.model_value_to_api(tag_value)
                if api_value not in by_value:
                    by_value[api_value] = {
                        "tag_value": api_value,
                        "sources": [],
                        "object_count": 0,
                    }
                    order.append(api_value)
                by_value[api_value]["sources"].append(
                    {
                        "source": source,
                        "object_count": object_count,
                        "account_count": account_count,
                        "credits": credits,
                    }
                )
                by_value[api_value]["object_count"] += object_count

            if not norm_key:
                # A bare search (no tag_key given): only the top values are listed for each
                # matching key, ranked so a matching value surfaces first.
                order = sorted(
                    order,
                    key=lambda v: (0 if needle and needle in v.lower() else 1, -by_value[v]["object_count"]),
                )
                values_out = order[:limit_values]
            else:
                order = sorted(
                    order,
                    key=lambda v: (0 if needle and needle in v.lower() else 1, -by_value[v]["object_count"]),
                )
                values_out = order[:limit_values]

            keys_out.append(
                {
                    "tag_key": tag_key_norm,
                    "display_key": display_key,
                    "raw_keys": (raw_keys or "").split(",") if raw_keys else [],
                    "sources": sorted(sources or []),
                    "value_count": len(order),
                    "values_truncated": len(order) > limit_values,
                    "values": [by_value[v] for v in values_out],
                    "untagged": {"tag_value": tag_keys.UNTAGGED, "label": "untagged"},
                    "any": {"tag_value": None, "label": "any value"},
                }
            )

        if len(keys_out) > limit_keys:
            truncated = True
            keys_out = keys_out[:limit_keys]

        return {
            "search": search or "",
            "truncated": truncated,
            "keys": keys_out,
            # Section 4.3: the on-screen words for each raw source code (e.g. "billing:cluster" ->
            # "cluster tag, as billed ..."). Sent once per response rather than baked into each
            # key's own `sources` list, which stays the raw codes app/web's Tip title uses.
            "source_labels": tag_keys.SOURCE_LABELS,
        }
    finally:
        con.close()


# ---------------------------------------------------------------------------------------------
# tag_chain -- which tag reaches which finding, per area
# ---------------------------------------------------------------------------------------------


@dataclass(frozen=True)
class ChainTerm:
    tag_word: str        # the short word used in scope.tag.chain and the label ("query", "job", ...)
    label: str            # the human phrase used in chain_label ("query tag", "warehouse tag", ...)
    entity_type: str      # tags.tag_entity.entity_type this term looks up
    id_expr: str          # the finding table's own column (or expression) supplying entity_id
    account_scoped: bool = True   # also require e.account_id = table.account_id


@dataclass(frozen=True)
class TagChain:
    kind: str                       # "entity" | "row_tags" | "none"
    terms: list = field(default_factory=list)   # list[ChainTerm], kind == "entity" only
    reason: str | None = None       # kind == "none" only

    @property
    def applied(self) -> bool:
        return self.kind != "none"

    @property
    def chain_words(self) -> list[str]:
        if self.kind == "row_tags":
            return ["row"]
        return [t.tag_word for t in self.terms]

    @property
    def chain_label(self) -> str | None:
        if self.kind == "row_tags":
            # A plain label, never None: app/web/components/finding_detail.jsx's TagScopeLine
            # renders `Tag filter applied by: ${chain_label}.` for every chain kind but "none",
            # so a bare None here used to print the literal text "Tag filter applied by: null."
            # on cost_chargeback_by_tag (the one row-tags finding today).
            return "the tag on each billing row"
        if not self.terms:
            return None
        return ", then ".join(f"{t.label}" for t in self.terms)


_NOT_APPLICABLE_REASON = (
    "this check has no account, warehouse, task, query or object column, so no tag can reach its rows"
)

_OBJECT_LABELS = {
    "task": "task tag",
    "table": "table tag",
    "schema": "schema tag",
    "database": "database tag",
}


def _object_cascade(col_names: set[str]) -> list[tuple[str, str]]:
    """The object-tag fallback cascade this table's own columns support, deepest first: a table,
    then its schema, then its database (a task stands alone). [] when the table names no tagged
    object at all. Each `id_expr` is the lower-cased dotted name and references the caller's table
    alias `t`."""
    for name in ("task_full_name", "job_id"):
        if name in col_names:
            return [("task", f'lower(t."{name}")')]
    db, sch, tbl = (
        ("database_name", "schema_name", "table_name") if {"database_name", "schema_name", "table_name"} <= col_names
        else ("table_catalog", "table_schema", "table_name")
    )
    if {db, sch, tbl} <= col_names:
        schema_id = f'lower(t."{db}") || \'.\' || lower(t."{sch}")'
        return [
            ("table", f'{schema_id} || \'.\' || lower(t."{tbl}")'),
            ("schema", schema_id),
            ("database", f'lower(t."{db}")'),
        ]
    if {"database_name", "schema_name"} <= col_names:
        schema_id = 'lower(t."database_name") || \'.\' || lower(t."schema_name")'
        return [("schema", schema_id), ("database", 'lower(t."database_name")')]
    if "database_name" in col_names:
        return [("database", 'lower(t."database_name")')]
    return []


def tag_chain(query_id: str, col_names: list[str], domain: str) -> TagChain:
    """The ordered list of tags.tag_entity lookups that can reach this finding table's rows, built
    from the table's OWN columns (kept only when the column exists), never from a hard-coded
    per-query_id table, so a new query with the same column shape is covered for free.

    Three outcomes:
      - kind="row_tags": the table carries its own tag_key/tag_value columns -- filtered directly,
        no tags.tag_entity lookup, `__untagged__` not applicable.
      - kind="entity": one or more ChainTerm, in priority order (the first allocating value on a
        row wins -- see tag_clause's COALESCE): query tag, then warehouse tag, then the object
        cascade, then the account tag.
      - kind="none": not applicable, with a plain reason -- the finding is returned unfiltered.
    """
    cols = set(col_names)
    if {"tag_key", "tag_value"} <= cols:
        return TagChain(kind="row_tags")

    terms: list[ChainTerm] = []
    # The account match is OPTIONAL (`[AND e.account_id = <table>.account_id]`): a finding
    # table with no account_id column must never emit that AND, since DuckDB has no column to
    # bind it against and the tag filter would turn into OUTCOME_ERROR. Passed to every
    # account-scoped term below (an object's own tag is never account-scoped).
    ws = "account_id" in cols

    # Most specific first: query tag, object tag, warehouse tag, user or role tag, account tag.
    if "query_tag" in cols:
        terms.append(ChainTerm("query", "query tag", "query_tag", 't."query_tag"', account_scoped=ws))

    for entity_type, id_expr in _object_cascade(cols):
        terms.append(ChainTerm("object", _OBJECT_LABELS[entity_type], entity_type, id_expr, account_scoped=False))

    if "warehouse_id" in cols:
        terms.append(ChainTerm("compute", "warehouse tag", "warehouse", 't."warehouse_id"', account_scoped=ws))
    elif "warehouse_name" in cols:
        terms.append(ChainTerm("compute", "warehouse tag", "warehouse", 'lower(t."warehouse_name")', account_scoped=ws))

    if "user_name" in cols:
        terms.append(ChainTerm("user", "user tag", "user", 'lower(t."user_name")', account_scoped=False))
    if "role_name" in cols:
        terms.append(ChainTerm("role", "role tag", "role", 'lower(t."role_name")', account_scoped=False))

    if "account_id" in cols:
        terms.append(ChainTerm("account", "account tag", "account", 't."account_id"', account_scoped=ws))
    elif "warehouse_id" in cols:
        # No account column: the warehouse's own account, as the account filter finds it.
        terms.append(ChainTerm(
            "account", "account tag", "account",
            '(SELECT max(d.account_id) FROM dims.dim_warehouse d WHERE d.warehouse_id = t."warehouse_id")',
            account_scoped=False,
        ))

    if not terms:
        return TagChain(kind="none", reason=_NOT_APPLICABLE_REASON)
    return TagChain(kind="entity", terms=terms)


# ---------------------------------------------------------------------------------------------
# tag_clause -- the bound SQL a chain compiles to
# ---------------------------------------------------------------------------------------------


@dataclass(frozen=True)
class TagClause:
    where_sql: str | None          # None when the filter cannot apply (kind == "none")
    params: list
    select_sql: str | None         # tag_match_value/level/source CASE expressions, or None
    select_params: list


# DuckDB-only tag-key normalisation --
# app/core/data.py's store is always a DuckDB file, so this module inlines the SQL to run against it
_NORM_TAG_KEY_SQL = "regexp_replace(lower({col}), '[ _-]+', '', 'g')"


def _entity_subquery(term: ChainTerm, tag_key: str) -> tuple[str, list]:
    """One scalar subquery: the allocating tag value tags.tag_entity holds for this
    term's entity, or NULL. Two bound params, (entity_type, tag_key), in that order."""
    ws_clause = ' AND e."account_id" = t."account_id"' if term.account_scoped else ""
    sql = (
        '(SELECT min(e."tag_value") FROM tags.tag_entity e '
        'WHERE e."entity_type" = ? AND e."tag_key" = ? AND e."is_allocating"'
        f' AND e."entity_id" = CAST({term.id_expr} AS VARCHAR){ws_clause})'
    )
    return sql, [term.entity_type, tag_key]


def _source_subquery(term: ChainTerm, tag_key: str) -> tuple[str, list]:
    """The source code behind this term's winning value, same shape as
    _entity_subquery but selecting `source`."""
    ws_clause = ' AND e."account_id" = t."account_id"' if term.account_scoped else ""
    sql = (
        '(SELECT min(e."source") FROM tags.tag_entity e '
        'WHERE e."entity_type" = ? AND e."tag_key" = ? AND e."is_allocating"'
        f' AND e."entity_id" = CAST({term.id_expr} AS VARCHAR){ws_clause})'
    )
    return sql, [term.entity_type, tag_key]


def _case_over_terms(terms: list, tag_key: str, then_fn) -> tuple[str, list]:
    """CASE WHEN <term's subquery> IS NOT NULL THEN <then_fn(term)> ... END (no ELSE -- the
    caller supplies one), built left to right so the returned params line up with the `?`
    placeholders in the returned SQL text in the same order. `then_fn(term)` returns (sql, params)
    for one branch's THEN expression."""
    parts: list[str] = []
    params: list = []
    for term in terms:
        when_sql, when_params = _entity_subquery(term, tag_key)
        then_sql, then_params = then_fn(term)
        parts.append(f"WHEN {when_sql} IS NOT NULL THEN {then_sql}")
        params.extend(when_params)
        params.extend(then_params)
    return " ".join(parts), params


def _entity_coalesce(chain: TagChain, tag_key: str) -> tuple[str, list]:
    """COALESCE(term1, term2, ..., '__untagged__') -- the scalar every entity-chain value
    comparison reduces to. Built once so tag_group_clause can compare it with several values
    (IN (...)) instead of repeating one subquery set per value."""
    subqueries: list[str] = []
    params: list = []
    for term in chain.terms:
        sub_sql, sub_params = _entity_subquery(term, tag_key)
        subqueries.append(sub_sql)
        params.extend(sub_params)
    return f"COALESCE({', '.join(subqueries)}, '{tag_keys.UNTAGGED}')", params


def _entity_select(chain: TagChain, tag_key: str) -> tuple[str, list]:
    """tag_match_value/level/source: the first term whose subquery is non-NULL wins, same order.
    Depends only on the chain and key, never the value being matched."""
    value_case_sql, value_params = _case_over_terms(
        chain.terms, tag_key, lambda term: _entity_subquery(term, tag_key)
    )
    level_case_sql, level_params = _case_over_terms(
        chain.terms, tag_key, lambda term: (f"'{term.tag_word}'", [])
    )
    source_case_sql, source_params = _case_over_terms(
        chain.terms, tag_key, lambda term: _source_subquery(term, tag_key)
    )
    select_sql = (
        f"CASE {value_case_sql} ELSE '{tag_keys.UNTAGGED}' END AS tag_match_value, "
        f"CASE {level_case_sql} ELSE NULL END AS tag_match_level, "
        f"CASE {source_case_sql} ELSE NULL END AS tag_match_source"
    )
    return select_sql, value_params + level_params + source_params


def tag_clause(chain: TagChain, table_sql: str, tag_filter: TagFilter) -> TagClause | None:
    """Builds the bound WHERE/SELECT fragments for `tag_filter` against a table already aliased
    `t` in the caller's FROM clause (`table_sql` is documentation only here -- the caller supplies
    the alias). Returns None when the chain is not applicable at all (kind == "none"), OR when a
    row-tags chain is asked for `__untagged__` -- in both cases the caller (app/core/data.py's
    _build_filters) must leave the finding unfiltered and say so,
    never emit a `1 = 0`-style clause that empties the table in a way indistinguishable from a
    real "no rows match this value".
    """
    if chain.kind == "none":
        return None

    if chain.kind == "row_tags":
        # The original branch, now with a normalised key.
        if tag_filter.value == tag_keys.UNTAGGED:
            return None
        clauses = [_NORM_TAG_KEY_SQL.format(col='"t"."tag_key"') + " = ?"]
        params: list = [tag_filter.key]
        if tag_filter.value is not None:
            clauses.append('"t"."tag_value" = ?')
            params.append(tag_filter.value)
        return TagClause(where_sql=" AND ".join(clauses), params=params, select_sql=None, select_params=[])

    # kind == "entity": COALESCE(term1, term2, ..., '__untagged__') <cmp> ?
    coalesce, params = _entity_coalesce(chain, tag_filter.key)

    if tag_filter.value is None:
        where_sql = f"{coalesce} <> '{tag_keys.UNTAGGED}'"
    elif tag_filter.value == tag_keys.UNTAGGED:
        where_sql = f"{coalesce} = '{tag_keys.UNTAGGED}'"
    else:
        where_sql = f"{coalesce} = ?"
        params.append(tag_filter.value)

    select_sql, select_params = _entity_select(chain, tag_filter.key)
    return TagClause(where_sql=where_sql, params=params, select_sql=select_sql, select_params=select_params)


# ---------------------------------------------------------------------------------------------
# tag_group_clause / tag_set_clause -- the multi-name filter's own SQL, built by calling
# tag_clause() once per (key, value) and combining: OR within a TagValueGroup's values, AND across
# a TagFilterSet's groups. select_sql/select_params never depend on the VALUE tried (only on the
# chain and the key -- see _case_over_terms above), so every attempt yields the same select_sql;
# the first one that succeeds is kept.
# ---------------------------------------------------------------------------------------------


def tag_group_clause(chain: TagChain, table_sql: str, group: TagValueGroup) -> TagClause | None:
    """OR across `group.values` (empty = "All"), reusing tag_clause per value. None the moment ANY
    one value cannot be represented on this chain -- the caller must then treat the whole filter as not applicable, never
    silently drop the inapplicable value and apply the rest."""
    if not group.values:
        return tag_clause(chain, table_sql, TagFilter(key=group.key, value=None))

    if len(group.values) > 1 and chain.kind == "entity":
        # One COALESCE of per-level lookups, compared with IN (...), instead of tag_clause's whole
        # per-value COALESCE repeated once per value.
        coalesce, coalesce_params = _entity_coalesce(chain, group.key)
        real_values = [v for v in group.values if v != tag_keys.UNTAGGED]
        want_untagged = len(real_values) != len(group.values)
        where_parts: list[str] = []
        params: list = []
        if real_values:
            placeholders = ", ".join("?" for _ in real_values)
            where_parts.append(f"{coalesce} IN ({placeholders})")
            params.extend(coalesce_params)
            params.extend(real_values)
        if want_untagged:
            where_parts.append(f"{coalesce} = '{tag_keys.UNTAGGED}'")
            params.extend(coalesce_params)
        select_sql, select_params = _entity_select(chain, group.key)
        return TagClause(
            where_sql=" OR ".join(where_parts), params=params,
            select_sql=select_sql, select_params=select_params,
        )

    if len(group.values) > 1 and chain.kind == "row_tags" and tag_keys.UNTAGGED not in group.values:
        # One row carries exactly one tag_value for this key -- IN (...), no per-value repeats.
        placeholders = ", ".join("?" for _ in group.values)
        where_sql = (
            _NORM_TAG_KEY_SQL.format(col='"t"."tag_key"') + " = ? AND "
            f'"t"."tag_value" IN ({placeholders})'
        )
        return TagClause(where_sql=where_sql, params=[group.key, *group.values], select_sql=None, select_params=[])

    where_parts: list[str] = []
    params: list = []
    select_sql: str | None = None
    select_params: list = []
    for value in group.values:
        clause = tag_clause(chain, table_sql, TagFilter(key=group.key, value=value))
        if clause is None:
            return None
        where_parts.append(f"({clause.where_sql})")
        params.extend(clause.params)
        if select_sql is None:
            select_sql, select_params = clause.select_sql, clause.select_params
    return TagClause(where_sql=" OR ".join(where_parts), params=params, select_sql=select_sql, select_params=select_params)


def tag_set_clause(chain: TagChain, table_sql: str, filter_set: TagFilterSet) -> TagClause | None:
    """AND across `filter_set.groups` (several tag names). None (not applicable at all) the moment
    ANY one group is -- the same "never partially apply" rule tag_clause itself follows for a
    single group, now extended across several. Also None on a row-tags chain with more than one
    group: cost_chargeback_by_tag holds one (tag_key, tag_value) pair per row, so two different
    tag names can never both match the same row."""
    if chain.kind == "row_tags" and len(filter_set.groups) > 1:
        return None
    where_parts: list[str] = []
    params: list = []
    select_sql: str | None = None
    select_params: list = []
    for group in filter_set.groups:
        clause = tag_group_clause(chain, table_sql, group)
        if clause is None:
            return None
        where_parts.append(f"({clause.where_sql})")
        params.extend(clause.params)
        if select_sql is None:
            select_sql, select_params = clause.select_sql, clause.select_params
    return TagClause(where_sql=" AND ".join(where_parts), params=params, select_sql=select_sql, select_params=select_params)
