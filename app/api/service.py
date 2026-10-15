"""app/api/service.py

The four-outcome honesty rule, built on app/core alone (app/core/data.py and app/core/registry.py):

    OUTCOME_OK_ROWS / OUTCOME_OK_EMPTY_WINDOW / OUTCOME_OK_EMPTY_FILTERS / OUTCOME_NOT_ASSESSED /
    OUTCOME_ERROR      the five honesty-rule rows (OUTCOME_OK_* is the "OK" row split three ways).
    QueryNotFoundError  raised by get_spec() for an id app/core/registry does not know; the FastAPI
                        layer turns it into a 404, never a 500.
    window_for(spec, window_days)
                        a point-in-time query (windowed=False) is only ever built at window_days=0;
                        forwarding the caller's 7/30/90 filter would read it as falsely empty.
    Outcome             the typed result load_outcome()/list_findings() produce.
    load_outcome(query_id, window_days, account_ids=None, env=None, limit=None, ...)
                        one query_id's full outcome, in the five-step order its docstring gives.
    load_aggregate(query_id, window_days, group, agg, value=None, ...)
                        the same derivation, but an OK_ROWS result carries the server-side
                        GROUP BY groups instead of a row page.
    list_findings(window_days, account_ids=None, env=None, attributes=None, tag=None, ...)
                        one row per executable registry query: outcome, a CRITICAL / WARN /
                        NOT_ASSESSED / OK breakdown, money and affected counts.
    classify_columns(columns, discount_pct)
                        {column: {"kind", "label"}}: money (via app.core.pricing's own regex, so the
                        two modules never disagree about which columns are dollars), id, or a
                        magnitude kind (credits / pct / hours / gb / gb_bytes).
    records(df, kinds)  df -> JSON-safe dicts: NaN/NaT -> None, numpy scalars -> native Python, an
                        id-kind column always a string, a datetime ISO text.
    resolve_params(spec)  {param name: (value in effect, source)} for every :param a header
                        declares: thresholds.yml[query_id], then [_all], then the header default.
    row_cap(query_id)   the :top_n row cap a check runs with, or None when it has none.
    substitute_params(text, resolved) / substitute_header_params(spec, window_days)
                        replace every `:name` token in a header field with the value in effect plus
                        a plain source word, so a header never shows a raw token.

"workspace" in filters and field names means the Snowflake account.

Stdlib + duckdb (for the store's exception classes) + pandas, then app/core.
"""
from __future__ import annotations

import copy
import math
import re
import sys
from dataclasses import dataclass, field
from datetime import date as _dt_date
from datetime import datetime as _dt_datetime
from pathlib import Path
from typing import Any

import duckdb
import pandas as pd

_ROOT = Path(__file__).resolve().parent.parent.parent
if str(_ROOT) not in sys.path:
    sys.path.insert(0, str(_ROOT))

from app.core import config as app_config  # noqa: E402
from app.core import data as app_core_data  # noqa: E402
from app.core import materiality as app_materiality  # noqa: E402
from app.core import identity as app_identity  # noqa: E402
from app.core import pricing as app_pricing  # noqa: E402
from app.core import registry  # noqa: E402
from app.core import tags as app_core_tags  # noqa: E402

OUTCOME_OK_ROWS = "ok_rows"
OUTCOME_OK_EMPTY_WINDOW = "ok_empty_window"
OUTCOME_OK_EMPTY_FILTERS = "ok_empty_filters"
OUTCOME_NOT_ASSESSED = "not_assessed"
OUTCOME_ERROR = "error"

STATUS_ORDER = ["CRITICAL", "WARN", "NOT_ASSESSED", "OK"]
WINDOW_CHOICES = (7, 30, 90)


class QueryNotFoundError(KeyError):
    """query_id does not resolve in app.core.registry -- the API layer's own signal to 404
    rather than let registry.by_id's bare KeyError become an unhandled 500."""


def get_spec(query_id: str) -> registry.QuerySpec:
    try:
        return registry.by_id(query_id)
    except KeyError as exc:
        raise QueryNotFoundError(query_id) from exc


def window_for(spec: registry.QuerySpec, window_days: int) -> int:
    """The window a query must actually be read at: 0 for a point-in-time query (windowed=False),
    else the caller's own filter."""
    return window_days if spec.windowed else 0


# ---------------------------------------------------------------------------------------------
# resolve_params / row_cap: every :param a header declares resolves to config/thresholds.yml
# [query_id][name], then [_all][name], then the header's own default.
# ---------------------------------------------------------------------------------------------


def resolve_params(spec: registry.QuerySpec) -> dict[str, tuple[Any, str]]:
    """{param name: (value in effect, source)} for every `:param` this query's header declares.
    `source` is "your setting" when config/thresholds.yml overrides the header default for this
    query_id (checked first) or `_all` (checked second), else "default" -- never a literal guessed
    here. Reruns the thresholds.yml load per call (cheap: a handful of params, one small YAML file
    already cached by app_config)."""
    try:
        thresholds = app_config.load_thresholds()
    except Exception:
        thresholds = {}
    out: dict[str, tuple[Any, str]] = {}
    for param in spec.params or []:
        name = param.get("name")
        if not name:
            continue
        value, source = param.get("default"), "default"
        for scope in (spec.query_id, "_all"):
            override = (thresholds.get(scope) or {}).get(name)
            if isinstance(override, (int, float)) and not isinstance(override, bool):
                value, source = override, "your setting"
                break
        out[name] = (value, source)
    return out


def row_cap(query_id: str) -> int | None:
    """The :top_n row cap a check runs with, or None when it has no `top_n` param or the id is
    unknown."""
    try:
        spec = get_spec(query_id)
    except QueryNotFoundError:
        return None
    value, _source = resolve_params(spec).get("top_n", (None, None))
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        return int(value)
    return None


# ---------------------------------------------------------------------------------------------
# substitute_header_params: a header's read_this / healthy / investigate_if / actions /
# not_assessed_reasons text carries `:name` tokens for a param whose value a reader can override in
# config/thresholds.yml. Serving the raw token would read the header default whatever the account's
# own setting said; this replaces every token with the value actually in effect, plus a plain word
# for where it came from.
# ---------------------------------------------------------------------------------------------

_PARAM_TOKEN_RE = re.compile(r":([a-z][a-z0-9_]*)")


def _fmt_param_value(value: Any) -> str:
    if isinstance(value, float) and value.is_integer():
        return str(int(value))
    return str(value)


def substitute_params(text: str | None, resolved: dict[str, tuple[Any, str]]) -> str | None:
    """Replace every `:name` token this query declares as a param with `"<value> (<source>)"`
    (resolve_params' own value/source pair). A `:name` this query's header does NOT declare as a
    param is left untouched rather than silently eaten -- it is either plain prose that happens to
    start with a colon-letter, or a lint_headers.py bug, never this function's call to guess."""
    if not text:
        return text

    def _sub(m: "re.Match[str]") -> str:
        name = m.group(1)
        if name not in resolved:
            return m.group(0)
        value, source = resolved[name]
        return f"{_fmt_param_value(value)} ({source})"

    return _PARAM_TOKEN_RE.sub(_sub, text)


def substitute_header_params(spec: registry.QuerySpec, window_days: int | None = None) -> dict[str, Any]:
    """The header fields a reader actually sees -- read_this, healthy, investigate_if, actions and
    not_assessed_reasons -- with every `:param` token replaced by resolve_params()'s value/source.
    caveats and confidence_note are left alone: they are reference text, not part of a tile or the
    panel's headline guidance.

    `:period_days` is not a thresholds.yml setting: the export maps it to the window the reader
    picked (7/30/90), so resolve_params() alone would always read "30 (default)". When the caller
    passes the effective `window_days` for a windowed spec, it overrides that entry with the value in
    effect, sourced as "the window you picked". When the export never ran the full window (a 10-day
    export read at 30d) the token carries the days actually covered, so the header never claims a
    fuller query than what ran."""
    resolved = resolve_params(spec)
    if window_days is not None and spec.windowed and "period_days" in resolved:
        coverage = app_core_data.exported_window_coverage()
        covered = coverage.get(window_days) if coverage else None
        if covered is not None and covered < window_days:
            resolved["period_days"] = (
                covered, f"the export covered {covered} of the {window_days} days you picked",
            )
        else:
            resolved["period_days"] = (window_days, "the window you picked")
    return {
        "read_this": substitute_params(spec.read_this, resolved),
        "healthy": substitute_params(spec.healthy, resolved),
        "investigate_if": substitute_params(spec.investigate_if, resolved),
        "actions": [substitute_params(a, resolved) for a in (spec.actions or [])],
        "not_assessed_reasons": {
            code: substitute_params(words, resolved)
            for code, words in (spec.not_assessed_reasons or {}).items()
        },
        # the values in effect, so a page draws a check's own line instead of a hard-coded default
        "params": {name: {"value": value, "source": source} for name, (value, source) in resolved.items()},
    }


def _not_built_reason(query_id: str) -> str:
    return "Not in this export yet: this check is newer than the export. The next export includes it."


def _not_exported_reason(eff_window: int, coverage: dict[int, int] | None) -> str | None:
    """None unless the export's own window_coverage never ran eff_window at all: a plain reason
    ("the export covered N days; the <w>-day window was not exported"), never read as
    ok_empty_window's "nothing in this window". `coverage` is load_outcome's own
    exported_window_coverage() read, passed in rather than re-fetched."""
    if coverage is None or eff_window in coverage:
        return None
    covered = max(coverage.values())
    return f"the export covered {covered} days; the {eff_window}-day window was not exported"


# ---------------------------------------------------------------------------------------------
# Why a check reads NOT_ASSESSED, as list_findings' short code.
# ---------------------------------------------------------------------------------------------

NA_MODEL_FAILED = "model_failed"
NA_NOT_BUILT = "not_built"
# The export never ran this window at all (as opposed to running it partially), e.g. a 10-day
# export asked for the 90-day window. Never "nothing in this window".
NA_NOT_EXPORTED = "not_exported"
# A tag filter whose chain needs tags.tag_entity when the tag tables were never loaded: never a
# silently-unfiltered count.
NA_TAG_MODELS_NOT_BUILT = "tag_models_not_built"


@dataclass
class Outcome:
    """One query_id's fully-derived outcome -- the FastAPI layer switches on `outcome` and
    serialises exactly the fields that outcome names, never a generic 'no data' response."""

    outcome: str
    spec: registry.QuerySpec
    window_days: int
    status_info: dict | None = None
    window_coverage: dict | None = None
    df: pd.DataFrame = field(default_factory=pd.DataFrame)
    rows_total: int = 0          # rows matching window + every filter (read_finding's own count)
    rows_in_window: int = 0      # rows matching window alone, filters ignored
    error: str | None = None
    scope: dict | None = None    # {"has_account_id", "tag", "owner_applied"}
    rows_below_floor: int = 0    # materiality floor: how many of rows_total (app_core_data's own
                                  # read_finding.rows_below_floor) -- 0 when this query has none
    excluded_no_account: dict | None = None  # app_core_data.FindingResult's own field


def _scope_tag(
    tag: "app_core_tags.TagFilter | app_core_tags.TagFilterSet | None", applied: bool | None, chain_words: list | None,
    chain_label: str | None, reason: str | None,
) -> dict | None:
    """The `scope.tag` object, or None when no tag filter was requested at all."""
    if tag is None:
        return None
    return {"applied": bool(applied), "chain": list(chain_words or []), "chain_label": chain_label, "reason": reason}


def _scope_tag_from_applicability(tag: "app_core_tags.TagFilter | app_core_tags.TagFilterSet | None", applicability: dict) -> dict | None:
    return _scope_tag(
        tag, applicability.get("tag_applied"), applicability.get("tag_chain"),
        applicability.get("tag_chain_label"), applicability.get("tag_not_applicable_reason"),
    )


_TAG_MODELS_NOT_BUILT_REASON = "tag_models_not_built: the tag index was not built; rebuild to filter by tag"


def load_outcome(
    query_id: str,
    window_days: int,
    account_ids: list[str] | None = None,
    env: list[str] | None = None,
    limit: int | None = None,
    attributes: dict[str, list[str]] | None = None,
    job_id: str | None = None,
    statuses: list[str] | None = None,
    tag: "app_core_tags.TagFilter | app_core_tags.TagFilterSet | None" = None,
    owner: str | None = None,
    dims: "app_core_data.DimFilter | None" = None,
) -> Outcome:
    """Derive the honesty-rule outcome for one query_id:

    1. NOT_ASSESSED first: the check failed in the export (run results), or the export never ran
       this window at all.
    2. A local read failure while counting/reading rows (findings.f_<qid> missing despite the run
       results) also lands on NOT_ASSESSED via FindingNotBuiltError; any other DuckDB/OS-level
       failure (a locked file, a corrupt db) is ERROR instead.
    3. OK, empty in window: rows_in_window (window alone, no other filter) is 0.
    4. OK, empty by filters: rows_in_window > 0 but the caller's own filters exclude every row.
    5. OK, rows: otherwise.

    `attributes` ({canonical_key: [value, ...]}) applies the same way env does: only on a finding
    that carries account_id, never reducing one that does not. `job_id` scopes to one task
    server-side, the same way (a finding whose window has rows but none for this task reads
    OUTCOME_OK_EMPTY_FILTERS). `statuses` scopes to those status values, again only on a finding
    with a status column, so a tile that needs only CRITICAL/WARN rows can ask the store for exactly
    those instead of filtering a capped page in the browser.

    Raises QueryNotFoundError for an unknown query_id (the FastAPI layer's job to 404).

    Every Outcome carries `scope` = {"has_account_id": bool | None (None when the table was not
    read), "tag", "owner_applied"}."""
    spec = get_spec(query_id)
    eff_window = window_for(spec, window_days)
    status_info = app_core_data.finding_status(query_id)
    # Row-cap info from the loader (app.core.data.truncation_info).
    status_info.update(app_core_data.truncation_info(query_id, eff_window))
    # One read for the whole call: _not_exported_reason and window_coverage() below share it.
    exported_coverage = app_core_data.exported_window_coverage()
    scope: dict = {"has_account_id": None, "tag": None, "owner_applied": None,
                   "warehouse_applied": None, "database_applied": None, "schema_applied": None}

    # "not_built" is deliberately NOT treated as bad here: it only means the run results have no
    # entry for this check. If the table really is absent, count_finding below raises
    # FindingNotBuiltError and we report NOT_ASSESSED from that, which is evidence. Only an
    # explicit failed verdict counts.
    if status_info["status"] == "failed":
        return Outcome(OUTCOME_NOT_ASSESSED, spec, eff_window, status_info=status_info, scope=scope)

    # Checked after failed, so a check that failed in the export reads model_failed everywhere,
    # never not_exported here and model_failed there for the same query_id.
    if spec.windowed:
        not_exported = _not_exported_reason(eff_window, exported_coverage)
        if not_exported is not None:
            info = dict(status_info)
            info["not_exported_reason"] = not_exported
            # The not-assessed card renders not_built_reason: same sentence in both keys.
            info["not_built_reason"] = not_exported
            return Outcome(OUTCOME_NOT_ASSESSED, spec, eff_window, status_info=info, scope=scope)

    try:
        has_account_id = app_core_data.account_filterable(app_core_data.finding_columns(query_id))
        rows_in_window = app_core_data.count_finding(query_id, eff_window)
    except app_core_data.FindingNotBuiltError:
        info = dict(status_info)
        info["not_built_reason"] = _not_built_reason(query_id)
        return Outcome(OUTCOME_NOT_ASSESSED, spec, eff_window, status_info=info, scope=scope)
    except (duckdb.Error, OSError) as exc:
        return Outcome(
            OUTCOME_ERROR, spec, eff_window, status_info=status_info, error=str(exc), scope=scope
        )

    scope["has_account_id"] = has_account_id

    if rows_in_window == 0:
        try:
            coverage = app_core_data.window_coverage(query_id, eff_window, exported_coverage)
        except Exception:
            coverage = None
        return Outcome(
            OUTCOME_OK_EMPTY_WINDOW, spec, eff_window, status_info=status_info,
            window_coverage=coverage, scope=scope,
        )

    try:
        result = app_core_data.read_finding(
            query_id, eff_window, account_ids, env, None, limit, attributes=attributes,
            job_id=job_id, statuses=statuses, tag_filter=tag, owner=owner, dims=dims,
        )
    except app_core_tags.TagModelsNotBuiltError:
        # Never return unfiltered rows under an active filter: NOT_ASSESSED with a plain reason
        # instead (never read "we could not check" as "untagged").
        info = dict(status_info)
        info["not_built_reason"] = _TAG_MODELS_NOT_BUILT_REASON
        return Outcome(OUTCOME_NOT_ASSESSED, spec, eff_window, status_info=info, scope=scope)
    except app_core_data.FindingNotBuiltError:
        info = dict(status_info)
        info["not_built_reason"] = _not_built_reason(query_id)
        return Outcome(OUTCOME_NOT_ASSESSED, spec, eff_window, status_info=info, scope=scope)
    except (duckdb.Error, OSError) as exc:
        return Outcome(
            OUTCOME_ERROR, spec, eff_window, status_info=status_info, error=str(exc), scope=scope
        )

    scope["tag"] = _scope_tag_from_applicability(tag, result.applicability)
    scope["owner_applied"] = result.applicability.get("owner_applied")
    applied = result.applicability.get("dim_applied") or {}
    scope["warehouse_applied"] = applied.get("warehouse")
    scope["database_applied"] = applied.get("database")
    scope["schema_applied"] = applied.get("schema")

    if result.rows_total == 0:
        # Only the status scope matched nothing: the check ran and flagged nothing, no user filter.
        user_filter = bool(account_ids or env or attributes or job_id or tag is not None or owner or dims)
        scope["none_flagged"] = bool(statuses) and not user_filter
        return Outcome(
            OUTCOME_OK_EMPTY_FILTERS,
            spec,
            eff_window,
            status_info=status_info,
            rows_in_window=rows_in_window,
            scope=scope,
            excluded_no_account=result.excluded_no_account,
        )

    # Coverage is attached to a finding WITH rows too, not only to an empty one: a 7-day export read
    # at a 30-day window returns plenty of rows, just 7 days of them under a "30d" label, which is
    # where a partial window is most dangerous.
    try:
        coverage = app_core_data.window_coverage(query_id, eff_window, exported_coverage)
    except Exception:
        coverage = None

    return Outcome(
        OUTCOME_OK_ROWS,
        spec,
        eff_window,
        status_info=status_info,
        df=result.df,
        rows_total=result.rows_total,
        rows_in_window=rows_in_window,
        window_coverage=coverage,
        scope=scope,
        rows_below_floor=result.rows_below_floor,
        excluded_no_account=result.excluded_no_account,
    )


# ---------------------------------------------------------------------------------------------
# load_aggregate: the server-side SUM/COUNT. A tile or chart that summed the (capped) row page a
# plain /api/finding fetch returns would total only `ui.max_rows` rows; app/core/data.
# aggregate_finding's GROUP BY scans every matching row instead.
# ---------------------------------------------------------------------------------------------


@dataclass
class AggregateOutcome:
    """Same outcome vocabulary as Outcome above (the FastAPI layer switches on `outcome` the same
    way for both endpoints) -- an OK_ROWS result additionally carries `groups`/`other`/
    `total_value`/`matched_rows` instead of a row page."""

    outcome: str
    spec: registry.QuerySpec
    window_days: int
    status_info: dict | None = None
    window_coverage: dict | None = None
    rows_in_window: int = 0
    rows_total: int = 0
    matched_rows: int = 0
    group_count: int = 0
    groups: list = field(default_factory=list)   # list[app_core_data.AggregateGroup]
    other: Any = None                              # app_core_data.AggregateGroup | None
    total_value: Any = None
    null_value_rows: int = 0   # app_core_data.AggregateResult.null_value_rows
    error: str | None = None
    scope: dict | None = None    # scope.tag, mirroring Outcome.scope
    floor: "app_materiality.Floor | None" = None   # this check's configured floor, or None
    excluded_no_account: dict | None = None  # app_core_data.AggregateResult's own field


def load_aggregate(
    query_id: str,
    window_days: int,
    group: list[str],
    agg: str,
    value: str | None = None,
    *,
    account_ids: list[str] | None = None,
    env: list[str] | None = None,
    attributes: dict[str, list[str]] | None = None,
    statuses: list[str] | None = None,
    top: int | None = None,
    tag: "app_core_tags.TagFilter | app_core_tags.TagFilterSet | None" = None,
    below_floor: bool = False,
    owner: str | None = None,
    include_totals: bool = False,
    dims: "app_core_data.DimFilter | None" = None,
) -> AggregateOutcome:
    """Derive the honesty-rule outcome exactly as load_outcome does (reruns it at limit=1 -- cheap,
    and it is the same tested branch order, so an aggregate and a plain finding read for the same
    query_id+filters can never disagree about NOT_ASSESSED/ERROR/empty-window/empty-filters), then
    for OUTCOME_OK_ROWS runs app_core_data.aggregate_finding for the real numbers.

    A bad `group`/`agg`/`value` raises ValueError (app_core_data.aggregate_finding's own
    validation) -- the FastAPI layer turns that into a 422, same as an unknown query_id (via
    QueryNotFoundError, raised by the load_outcome() call below) turns into a 404.

    `tag` follows load_outcome's own `tag` contract exactly, including TagModelsNotBuiltError ->
    NOT_ASSESSED (via the `base` call below)."""
    base = load_outcome(
        query_id, window_days, account_ids, env, limit=1, attributes=attributes, statuses=statuses,
        tag=tag, owner=owner, dims=dims,
    )
    if base.outcome != OUTCOME_OK_ROWS:
        return AggregateOutcome(
            base.outcome, base.spec, base.window_days,
            status_info=base.status_info, window_coverage=base.window_coverage,
            rows_in_window=base.rows_in_window, rows_total=base.rows_total, error=base.error,
            scope=base.scope, excluded_no_account=base.excluded_no_account,
        )

    try:
        agg_result = app_core_data.aggregate_finding(
            query_id, base.window_days, group, agg, value,
            account_ids=account_ids, env=env, attributes=attributes,
            statuses=statuses, top=top, tag_filter=tag, below_floor=below_floor, owner=owner,
            include_totals=include_totals, dims=dims,
        )
    except app_core_tags.TagModelsNotBuiltError:
        info = dict(base.status_info or {})
        info["not_built_reason"] = _TAG_MODELS_NOT_BUILT_REASON
        return AggregateOutcome(OUTCOME_NOT_ASSESSED, base.spec, base.window_days, status_info=info)
    except (duckdb.Error, OSError) as exc:
        return AggregateOutcome(
            OUTCOME_ERROR, base.spec, base.window_days, status_info=base.status_info, error=str(exc)
        )

    return AggregateOutcome(
        OUTCOME_OK_ROWS, base.spec, base.window_days,
        status_info=base.status_info, window_coverage=base.window_coverage,
        rows_in_window=base.rows_in_window, rows_total=agg_result.rows_total,
        matched_rows=agg_result.matched_rows, group_count=agg_result.group_count,
        groups=agg_result.groups, other=agg_result.other, total_value=agg_result.total_value,
        null_value_rows=agg_result.null_value_rows, scope=base.scope, floor=agg_result.floor,
        excluded_no_account=agg_result.excluded_no_account,
    )


def aggregate_group_json(group_cols: list[str], g) -> dict[str, Any]:
    """One app_core_data.AggregateGroup -> a JSON-safe dict. A group column matching the "id"
    heuristic (_ID_RE, the same regex classify_columns() uses) renders its key value as a string,
    same "IDs are strings" rule records() applies to a row page -- so a bigint
    account_id/job_id group key never loses precision to float/scientific-notation JSON
    encoding. `g.key` is None for the folded "other" bucket (no single group it stands for).
    `null_rows` is 0 for every agg but "sum" -- see AggregateGroup's own
    docstring for what it counts."""
    key = None
    if g.key is not None:
        key = []
        for col, val in zip(group_cols, g.key):
            if _ID_RE.search(col):
                key.append(None if _json_scalar(val) is None else str(val))
            else:
                key.append(_json_scalar(val))
        key = app_identity.mask_group_key(group_cols, key)
    return {"key": key, "value": _json_scalar(g.value), "row_count": g.row_count, "null_rows": g.null_rows}


# ---------------------------------------------------------------------------------------------
# list_findings -- the findings table's one row per query_id.
# ---------------------------------------------------------------------------------------------


@dataclass
class FindingRow:
    query_id: str
    title: str
    domain: str
    tier: str
    stars: bool
    origin: str
    is_finding: bool
    windowed: bool
    window_days: int
    outcome: str
    row_count: int
    status_counts: dict[str, int] | None
    has_account_id: bool | None = None     # None when the table was not read
    not_assessed_reason: str | None = None   # set only when outcome is not_assessed
    partial: bool = False                    # the export covered fewer days than the window; never
                                              # set together with not_assessed_reason
    # None (never set) unless `tag` was given to list_findings; mirrors app/core/data.TagApplication.
    tag_applied: bool | None = None
    tag_chain: list = field(default_factory=list)
    tag_chain_label: str | None = None
    # null | {code, label, partial}: app_core_data.not_assessed_status()'s vocabulary, the same one
    # /api/coverage's checks_not_ok builds from, so the two screens name one gap one way.
    not_assessed: dict | None = None
    # null | {column, kind, usd}: discounted SUM of the check's headline money column over
    # CRITICAL/WARN rows. null | {column, noun, flagged, total} for `affected`.
    money: dict | None = None
    money_reason: str | None = None   # "unpriced" (no price) or "no_amount" (priced, no figure yet) when money.usd is null
    affected: dict | None = None
    # null | {limited, note, billed, visible, unit}: the role sees only part of what this check lists.
    visibility: dict | None = None
    # null | {source, reads, note}: the export read this check from INFORMATION_SCHEMA, not ACCOUNT_USAGE.
    source: dict | None = None
    # {warehouse, database, schema}: True applied, False asked for but the check has no such column, None not asked.
    dim_applied: dict | None = None
    owner_applied: bool | None = None  # with an owner filter: whether it narrows this check
    # null | {column, min, unit, label, rows_below}: this check's materiality floor and the rows it moved to OK.
    floor: dict | None = None


_LIST_CACHE: dict = {}


def data_stamp() -> tuple | None:
    """(db file, run results) as (path, mtime, size), the key every server-side cache is kept by;
    None outside the running server (tools and tests patch data in memory) or with no db file."""
    if not app_core_data.share_connection:
        return None
    stamp = []
    for path in (app_core_data._db_path(), app_core_data._run_results_path()):  # noqa: SLF001
        try:
            st = path.stat()
            stamp.append((str(path), st.st_mtime_ns, st.st_size))
        except OSError:
            stamp.append((str(path), None))
    if stamp[0][1] is None:
        return None
    return (tuple(stamp), repr(app_config.load_settings()))


def list_findings(*args, **kwargs) -> list[FindingRow]:
    """_list_findings_uncached(), kept per (db file, settings, arguments): every page asks for the same
    list and building it reads all checks, several seconds on a large export."""
    stamp = data_stamp()
    if stamp is None:
        return _list_findings_uncached(*args, **kwargs)
    key = (stamp, repr(args), repr(sorted(kwargs.items())))
    if key not in _LIST_CACHE:
        if len(_LIST_CACHE) > 64:
            _LIST_CACHE.clear()
        _LIST_CACHE[key] = _list_findings_uncached(*args, **kwargs)
    return copy.deepcopy(_LIST_CACHE[key])


def _list_findings_uncached(
    window_days: int,
    account_ids: list[str] | None = None,
    env: list[str] | None = None,
    attributes: dict[str, list[str]] | None = None,
    tag: "app_core_tags.TagFilter | app_core_tags.TagFilterSet | None" = None,
    owner: str | None = None,
    dims: "app_core_data.DimFilter | None" = None,
) -> list[FindingRow]:
    """One row per executable registry query (every domain, no curated subset), each carrying its own
    honesty-rule outcome and, for a query with a status band, a verified CRITICAL / WARN /
    NOT_ASSESSED / OK breakdown.

    NOT_ASSESSED is decided per query from finding_status() (run results, no DuckDB connection), but
    every OK-path count and breakdown is read through ONE app.core.data.finding_window_counts() batch
    call: a single connection for the whole page instead of one per query.

    Each row carries has_account_id and not_assessed_reason (NA_MODEL_FAILED, NA_NOT_EXPORTED,
    NA_NOT_BUILT or NA_TAG_MODELS_NOT_BUILT; None unless the outcome is not_assessed). `partial` is
    True (never together with not_assessed_reason) when the export ran the window but not in full.

    `attributes` reaches the bulk row and status counts the same way account_ids and env do, so
    selecting a cost centre narrows this table exactly the way selecting an account does, for every
    query that carries account_id. `tag` reaches finding_window_counts the same way; every row also
    carries tag_applied/tag_chain/tag_chain_label (None/[]/None when `tag` is None). A query whose
    chain needs tags.tag_entity when that table was never loaded is NOT_ASSESSED with reason
    NA_TAG_MODELS_NOT_BUILT, never a silently-unfiltered count."""
    specs = [s for s in registry.load_registry() if s.executable]
    eff_windows = {s.query_id: window_for(s, window_days) for s in specs}
    exported_coverage = app_core_data.exported_window_coverage()  # None: the db has no export meta

    bad_reasons: dict[str, str] = {}
    partial_flags: dict[str, bool] = {}
    # Read the run results ONCE for this whole request and pass them into every status call below,
    # instead of re-reading the file per check. No caching across requests.
    rr = app_core_data.run_results()
    for s in specs:
        info = app_core_data.finding_status(s.query_id, rr)
        # Same rule as load_outcome: "not_built" only means the run results have no entry for this
        # check, not that the table is missing; the bulk count below decides that.
        if info["status"] == "failed":
            bad_reasons[s.query_id] = NA_MODEL_FAILED
        elif s.windowed and exported_coverage is not None and eff_windows[s.query_id] not in exported_coverage:
            bad_reasons[s.query_id] = NA_NOT_EXPORTED
        # A window the export ran but not in full (e.g. 10 of 30 days) is `partial`, never
        # `not_exported` (a window never run at all) and never indistinguishable from a full read.
        eff = eff_windows[s.query_id]
        if (
            s.query_id not in bad_reasons and s.windowed and exported_coverage is not None
            and exported_coverage.get(eff, eff) < eff
        ):
            partial_flags[s.query_id] = True

    pairs = [(s.query_id, eff_windows[s.query_id]) for s in specs if s.query_id not in bad_reasons]

    bulk: dict[str, dict] = {}
    bulk_error: str | None = None
    if pairs:
        try:
            bulk = app_core_data.finding_window_counts(
                pairs, account_ids, env, attributes, tag_filter=tag, owner=owner, dims=dims,
            )
        except (duckdb.Error, OSError) as exc:
            bulk_error = str(exc)

    # not_assessed_status()'s verdict per spec: the SAME function /api/coverage's checks_not_ok
    # names a gap with. table_exists comes from the bulk count above, so a table the export loaded
    # never reads not_built just because the run results have no entry for it. The loop below layers
    # all_rows_not_assessed on top where it needs live data this pass does not have.
    edition = app_core_data.export_edition()
    na_status: dict[str, dict | None] = {
        s.query_id: app_core_data.not_assessed_status(
            s, rr, window_days=eff_windows[s.query_id], exported_coverage=exported_coverage,
            table_exists=(s.query_id in bulk) if bulk_error is None else None, edition=edition,
        )
        for s in specs
    }

    rows: list[FindingRow] = []
    visibility = app_core_data.visibility_summary()
    for s in specs:
        eff_window = eff_windows[s.query_id]
        base = (s.query_id, s.title, s.domain, s.tier, s.stars, s.origin, s.is_finding, s.windowed, eff_window)

        if s.query_id in bad_reasons:
            rows.append(
                FindingRow(
                    *base, OUTCOME_NOT_ASSESSED, 0, None, None, bad_reasons[s.query_id],
                    not_assessed=na_status.get(s.query_id),
                )
            )
            continue
        if bulk_error is not None:
            rows.append(FindingRow(*base, OUTCOME_ERROR, 0, None, None, None))
            continue
        info = bulk.get(s.query_id)
        if info is None:
            # findings.f_<id> does not exist despite the run results (a stale sidecar, or a load in
            # progress): FindingNotBuiltError's own contract.
            rows.append(
                FindingRow(
                    *base, OUTCOME_NOT_ASSESSED, 0, None, None, NA_NOT_BUILT,
                    not_assessed=na_status.get(s.query_id),
                )
            )
            continue
        has_ws = info["has_account_id"]
        if tag is not None and info.get("tag_models_not_built"):
            rows.append(
                FindingRow(*base, OUTCOME_NOT_ASSESSED, 0, None, has_ws, NA_TAG_MODELS_NOT_BUILT)
            )
            continue
        tag_kwargs = (
            {
                "tag_applied": info.get("tag_applied"),
                "tag_chain": info.get("tag_chain") or [],
                "tag_chain_label": info.get("tag_chain_label"),
            }
            if tag is not None
            else {}
        )
        partial = partial_flags.get(s.query_id, False)
        if info["rows_in_window"] == 0:
            rows.append(
                FindingRow(
                    *base, OUTCOME_OK_EMPTY_WINDOW, 0, None, has_ws, None, partial,
                    **tag_kwargs, not_assessed=na_status.get(s.query_id),
                )
            )
            continue
        if info["rows_total"] == 0:
            rows.append(
                FindingRow(
                    *base, OUTCOME_OK_EMPTY_FILTERS, 0, None, has_ws, None, partial,
                    **tag_kwargs, not_assessed=na_status.get(s.query_id),
                )
            )
            continue
        status_counts = info["status_counts"] if s.is_finding else None
        all_na = bool(status_counts) and set(status_counts) == {"NOT_ASSESSED"}
        na = (
            app_core_data.not_assessed_status(
                s, rr, window_days=eff_window, exported_coverage=exported_coverage,
                all_rows_not_assessed=True, edition=edition,
            )
            if all_na else na_status.get(s.query_id)
        )
        money_info = dict(info["money"]) if info.get("money") else None
        money_reason = money_info.pop("reason", None) if money_info else None
        rows.append(
            FindingRow(
                *base, OUTCOME_OK_ROWS, info["rows_total"], status_counts, has_ws, None, partial,
                **tag_kwargs, not_assessed=na, money=money_info, money_reason=money_reason,
                affected=info.get("affected"),
                floor=info.get("floor"),
            )
        )
    by_id = {s.query_id: s for s in specs}
    fallbacks = app_core_data.fallback_sources()
    for row in rows:
        row.visibility = app_core_data.finding_visibility(by_id[row.query_id], visibility)
        row.source = fallbacks.get(row.query_id)
        info = bulk.get(row.query_id) or {}
        row.dim_applied = info.get("dim_applied") if dims else None
        row.owner_applied = info.get("owner_applied")
    _mark_storage_overlap(rows, window_days, account_ids, env, attributes, tag, owner, dims)
    return rows


# Storage checks priced per month whose flagged rows can name the same table: dropping an unused
# table also frees its Time Travel and Fail-safe, so a monthly total keeps each table's largest $ once.
_STORAGE_TABLE_CHECKS = (
    "sf_storage_unused_tables", "sf_use_unused_clones", "sf_storage_dropped_not_purged",
    "sf_storage_failsafe_on_staging", "sf_storage_churn_unread",
)


def _mark_storage_overlap(rows, window_days, account_ids, env, attributes, tag, owner, dims) -> None:
    """Set money.overlap_usd / overlap_tables on each storage check: the $ of its flagged tables that
    another storage check prices higher, so a total subtracts it and counts every table once."""
    per_table: dict[tuple[str, str], list[tuple[float, str]]] = {}
    priced = [r for r in rows if r.query_id in _STORAGE_TABLE_CHECKS and r.money and r.money.get("kind") == "saving_month"
              and r.money.get("basis") == "flagged" and r.money.get("usd") is not None]
    if len(priced) < 2:
        return
    for row in priced:
        col = row.money["column"]
        try:
            out = load_outcome(row.query_id, window_days, account_ids, env, None, attributes,
                               statuses=["CRITICAL", "WARN"], tag=tag, owner=owner, dims=dims)
        except (duckdb.Error, OSError):
            continue
        df = out.df
        if out.outcome != OUTCOME_OK_ROWS or col not in df.columns or "table_id" not in df.columns:
            continue
        if "is_total_row" in df.columns:
            df = df[~df["is_total_row"].fillna(False).astype(bool)]
        accts = df["account_id"] if "account_id" in df.columns else pd.Series([None] * len(df), index=df.index)
        for acct, tid, v in zip(accts, df["table_id"], df[col]):
            if pd.isna(tid) or pd.isna(v):
                continue
            per_table.setdefault((str(acct), str(tid)), []).append((float(v), row.query_id))
    overlap: dict[str, list[float]] = {}
    for vals in per_table.values():
        if len(vals) < 2:
            continue
        keep = max(range(len(vals)), key=lambda i: vals[i][0])
        for i, (v, qid) in enumerate(vals):
            if i != keep:
                acc = overlap.setdefault(qid, [0.0, 0])
                acc[0] += v
                acc[1] += 1
    disc = discount_pct()
    for row in priced:
        usd, n = overlap.get(row.query_id, (0.0, 0))
        row.money["overlap_usd"] = round(usd * (1 - disc), 2)
        row.money["overlap_tables"] = int(n)


# ---------------------------------------------------------------------------------------------
# Column classification + JSON-safe row serialisation.
# ---------------------------------------------------------------------------------------------

# Money columns are decided by app.core.pricing's own regex (the exact set pricing.apply() adds a
# "_disc" column for) plus its NON_DISCOUNT_MONEY_LABELS own-basis columns (never discounted,
# labelled by what they are; empty today). `_disc` is pricing.apply()'s suffix for the discounted
# twin of a raw list-price column.
_ID_RE = re.compile(r"(^id$)|(_id$)")
_MAGNITUDE: dict[str, re.Pattern] = {
    "pct": re.compile(r"(pct|percent)", re.IGNORECASE),
    "credits": re.compile(r"^(?!.*price).*credits?(_|$)", re.IGNORECASE),
    "hours": re.compile(r"hours?$", re.IGNORECASE),
    "gb": re.compile(r"_gb$", re.IGNORECASE),
    "gb_bytes": re.compile(r"bytes", re.IGNORECASE),
}
_DISC_SUFFIX = "_disc"


def est_label(discount_pct: float | None) -> str:
    """"list price (effective)" at the 0% default, or "what-if: list price (effective), -X%" once
    discount_pct is set away from 0 -- the same wording web/src/format.tsx's own client-side estLabel
    uses, so a price basis never reads two ways depending which side rendered it. X =
    round(discount_pct * 100, 1), trailing zeros dropped (not plain round(x*100): banker's rounding
    gave -12% for a 12.5% discount); None/0/0.0 alone returns the base label."""
    if not discount_pct:
        return "list price (effective)"
    pct_off = round(discount_pct * 100, 1)
    return f"what-if: list price (effective), -{pct_off:g}%"


def _money_label(col: str, discount_pct: float) -> str | None:
    is_disc = col.endswith(_DISC_SUFFIX)
    base = col[: -len(_DISC_SUFFIX)] if is_disc else col
    # An own-basis column (an invoice-currency amount, not the list price) is labelled by what it is.
    own_label = app_pricing.own_basis_label(base)
    if own_label is not None:
        return None if is_disc else own_label
    # Reuses app.core.pricing's regex, so the two modules never disagree about what counts as a
    # discountable dollar column.
    if not app_pricing.is_list_usd(base):
        return None
    return est_label(discount_pct if is_disc else 0.0)


def classify_columns(columns: list[str], discount_pct: float) -> dict[str, dict[str, str | None]]:
    """{column: {"kind": "money"|"id"|"credits"|"pct"|"hours"|"gb"|"gb_bytes"|None, "label": str|None}}
    -- money's label is its own-basis text (never discounted) or the "list price (effective)" /
    "what-if: ..." suffix (the raw column is always at 0%; only the "_disc" twin carries the
    caller's real discount_pct); every other kind's label is None (the client formats it)."""
    out: dict[str, dict[str, str | None]] = {}
    for col in columns:
        label = _money_label(col, discount_pct)
        if label is not None:
            out[col] = {"kind": "money", "label": label}
            continue
        if _ID_RE.search(col):
            out[col] = {"kind": "id", "label": None}
            continue
        kind = None
        for name, pattern in _MAGNITUDE.items():
            if pattern.search(col):
                kind = name
                break
        out[col] = {"kind": kind, "label": None}
    return out


def _json_scalar(value: Any) -> Any:
    if value is None:
        return None
    # pd.NaT is not a pd.Timestamp but IS a datetime.datetime, so without this it would render as
    # the literal text "NaT" in every cell an empty timestamp column produced.
    if value is pd.NaT:
        return None
    if isinstance(value, float) and math.isnan(value):
        return None
    if hasattr(value, "item"):  # numpy scalar (int64/float64/bool_/...)
        value = value.item()
        if isinstance(value, float) and math.isnan(value):
            return None
        return value
    if isinstance(value, pd.Timestamp):
        return None if pd.isna(value) else value.isoformat()
    # aggregate_group_json's own values come from duckdb.fetchall() directly (never through
    # a pandas DataFrame, unlike every other reader in this module), so a DATE/TIMESTAMP group key
    # arrives as a plain stdlib date/datetime, not a pd.Timestamp -- isoformat() it explicitly the
    # same way, rather than relying on FastAPI's own jsonable_encoder to catch it implicitly.
    if isinstance(value, (_dt_date, _dt_datetime)):
        return value.isoformat()
    try:
        if pd.isna(value):
            return None
    except (TypeError, ValueError):
        pass
    return value


def records(df: pd.DataFrame, kinds: dict[str, dict[str, str | None]]) -> list[dict[str, Any]]:
    """df -> JSON-safe records. Every "id"-kind column renders as a string (it avoids float or
    scientific-notation precision loss on a large bigint id);
    everything else is converted through _json_scalar (NaN/NaT -> None, numpy -> native Python,
    a Timestamp -> ISO text)."""
    out: list[dict[str, Any]] = []
    id_cols = {c for c, info in kinds.items() if info.get("kind") == "id"}
    df = app_identity.mask_dataframe(df)  # user names and emails only, and only when masking is on
    for _, row in df.iterrows():
        rec: dict[str, Any] = {}
        for col in df.columns:
            val = row[col]
            if col in id_cols:
                rec[col] = None if _json_scalar(val) is None else str(val)
            else:
                rec[col] = _json_scalar(val)
        out.append(rec)
    return out


def discount_pct() -> float:
    return float(app_config.load_settings()["discount_pct"])


# ---------------------------------------------------------------------------------------------
# Materiality floor (config/materiality.yml, app/core/materiality.py): app/core/data.py already
# applies the floor everywhere a row is read (status, below_floor, status_counts, an aggregate sum);
# this is the one remaining Python-side spot, the "floor" summary GET /api/finding carries.
# ---------------------------------------------------------------------------------------------


def floor_json(query_id: str, columns, rows_below: int) -> dict[str, Any] | None:
    """{"column", "min", "unit", "label", "rows_below"} for GET /api/finding's body, or None when
    this query has no floor applicable to this table (app_materiality.applicable_floor -- no
    configured floor, no "status" column, or the built table does not carry the floor's own
    column) -- so the page can say e.g. "412 rows under 100 GB not judged" without recomputing
    anything itself."""
    floor = app_materiality.applicable_floor(query_id, columns)
    if floor is None:
        return None
    return {
        "column": floor.column, "min": floor.min, "unit": floor.unit, "label": floor.label,
        "rows_below": rows_below,
    }



# ---------------------------------------------------------------------------------------------
# Fix these first: priced findings and CRITICAL findings with no dollar figure, labelled apart
# ---------------------------------------------------------------------------------------------

# Money kinds that are a saving or a waste (something to act on), by the period they are priced over.
_FIX_WINDOW_KINDS = ("waste", "saving", "gap")
_FIX_MONTH_KINDS = ("saving_month",)


def _fix_item(row: FindingRow, group: str) -> dict:
    counts = row.status_counts or {}
    money = row.money or {}
    return {
        "query_id": row.query_id, "title": row.title, "domain": row.domain, "group": group,
        "critical": int(counts.get("CRITICAL", 0)), "warn": int(counts.get("WARN", 0)),
        "usd": money.get("usd"), "kind": money.get("kind"), "unit": money.get("unit"),
        "column": money.get("column"), "basis": money.get("basis"), "price_basis": money.get("price_basis"),
        "per": "month" if money.get("kind") in _FIX_MONTH_KINDS else ("window" if group != "critical_no_usd" else None),
        "affected": row.affected, "money_reason": row.money_reason,
    }


def fix_first(rows: list[FindingRow], limit: int = 10) -> dict:
    """The ranking behind "Fix these first". Three labelled groups, never added together:

    priced_window   flagged waste, saving and gap findings by $ in the window (usd desc)
    priced_month    flagged storage savings by $ per month (usd desc)
    critical_no_usd CRITICAL findings that carry no $ at all (an admin without MFA, heavy spill): by
                    CRITICAL rows, then domain governance_access first

    `items` is the flat list a screen shows: the priced ones, then the CRITICAL ones with no $, each
    carrying its `group`. A finding that is not assessed is in none of them."""
    window, month, critical = [], [], []
    for row in rows:
        if row.outcome != OUTCOME_OK_ROWS or not row.is_finding:
            continue
        counts = row.status_counts or {}
        flagged = int(counts.get("CRITICAL", 0)) + int(counts.get("WARN", 0))
        money = row.money or {}
        kind, usd = money.get("kind"), money.get("usd")
        priced = kind in _FIX_WINDOW_KINDS + _FIX_MONTH_KINDS and usd is not None and usd > 0 and flagged > 0
        if priced:
            (month if kind in _FIX_MONTH_KINDS else window).append(_fix_item(row, "priced_month" if kind in _FIX_MONTH_KINDS else "priced_window"))
        elif int(counts.get("CRITICAL", 0)) > 0 and not (usd and kind in ("spend", "context")):
            # A spend or context $ is a view of money a priced check already ranks (idle credits by day).
            critical.append(_fix_item(row, "critical_no_usd"))
    window.sort(key=lambda i: (-i["usd"], i["title"]))
    month.sort(key=lambda i: (-i["usd"], i["title"]))
    critical.sort(key=lambda i: (-i["critical"], 0 if i["domain"] == "governance_access" else 1, i["title"]))
    return {
        "limit": limit,
        "priced_window": window[:limit], "priced_month": month[:limit], "critical_no_usd": critical[:limit],
        "items": window[:limit] + month[:limit] + critical[:limit],
        "counts": {"priced_window": len(window), "priced_month": len(month), "critical_no_usd": len(critical),
                   "unit": "findings"},
        "note": "Dollars are possible waste or savings in the window (or per month for storage); a CRITICAL "
                "finding with no dollar figure is listed apart. Groups are never added together.",
    }


def rows_csv(outcome: "Outcome", discount: float) -> str:
    """Every row of a finding (the filters applied, no row cap) as CSV, user names masked when masking
    is on, money columns discounted the way the table shows them."""
    df = app_pricing.apply(outcome.df, discount) if discount else outcome.df
    df = app_identity.mask_dataframe(df)
    return df.to_csv(index=False, lineterminator="\n")
