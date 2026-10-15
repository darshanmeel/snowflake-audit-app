"""app/api/guide.py -- build_guide(), the whole body of GET /api/guide: one entry per executable
registry query (header fields, first step, docs links, columns) plus the docs.snowflake.com page of
every source the checks read (config/snowflake_docs.yml)."""
from __future__ import annotations

import re

import duckdb
import yaml
from fastapi import APIRouter, HTTPException

from app.api import service
from app.core import config as app_config
from app.core import data as app_core_data
from app.core import finding_columns
from app.core import reasons as app_reasons
from app.core import registry
from app.core import snowflake_docs
from app.core import tag_spend as app_tag_spend
from app.core import tags as app_core_tags

# text for each header `empty_if` vocabulary word: why an empty result can still be a clean pass.
EMPTY_IF_WORDS: dict[str, str] = {
    "edition_too_low": "This view or feature needs a higher Snowflake edition than this account has.",
    "role_cannot_see": "The role only sees what it owns or has been granted, so it may see fewer rows, or none.",
    "org_account_only": "This view is only readable from the organization account or with an organization role.",
    "view_missing": "This view is not in this account yet (region, edition or rollout).",
    "retention_window": "Activity older than this view's retention window has already been purged.",
    "no_activity": "There is genuinely no matching activity in the selected window.",
    "ingestion_lag": "Recent activity has not reached the view yet (ACCOUNT_USAGE views lag by minutes to hours).",
}

# One line per concept page (web/src/components/guide.tsx), shown on a check's page when the check is exposed to it.
CONCEPT_TRAPS: dict[str, str] = {
    "cloud-services": "Cloud services are priced after Snowflake's daily 10% adjustment, so billed credits can be lower than used credits.",
    "attribution": "Query attribution is not a total: it leaves out idle time and queries under about 100 ms, lags up to 8 hours and is NULL on adaptive warehouses.",
    "latency": "This view lags (ACCOUNT_USAGE up to a few hours, organization billing up to 72 hours) and keeps a limited history, so the newest days can be low.",
    "failsafe": "Fail-safe and Time Travel bytes are billed after a drop; Fail-safe tables have no name and can pass as live.",
    "visibility": "SHOW and some views list only what the audit role can see, so a blind role reads Not assessed, never clean.",
    "editions": "Needs Enterprise edition or higher; on Standard this check reads Not assessed and no grant changes that.",
    "adaptive": "Adaptive warehouses have no per-query attribution; the check splits their billed credits instead.",
    "idle": "Idle is possible waste; each auto-suspend option's saving, and the part polls, short runs or dynamic-table refreshes cause, is an estimate on its own, never added to the idle $ or to each other.",
    "backups": "Backup and snapshot storage is an upper bound ('up to'), priced per month and never added to window spend.",
    "money-kinds": "Its dollar column has a kind (spend, change, waste, saving or balance): kinds are never added together.",
    "floors": "Rows under the check's materiality floor read OK and are left out of every count and total.",
}
_ATTRIBUTION_VIEWS = {"QUERY_ATTRIBUTION_HISTORY"}
_CLOUD_VIEWS = {"METERING_HISTORY", "WAREHOUSE_METERING_HISTORY", "METERING_DAILY_HISTORY", "USAGE_IN_CURRENCY_DAILY"}
_STORAGE_VIEWS = {"TABLE_STORAGE_METRICS", "DATABASE_STORAGE_USAGE_HISTORY", "STAGE_STORAGE_USAGE_HISTORY", "STORAGE_USAGE"}
_ADAPTIVE_IDS = {"sf_wh_adaptive_attribution"}
_IDLE_IDS = {"sf_wh_idle_minutes", "sf_wh_auto_suspend_tuning", "sf_wh_keepalive_pollers", "sf_wh_resume_churn",
             "sf_dt_lag_keeps_warehouse_awake"}
_BACKUP_IDS = {"sf_storage_backup_snapshot"}

router = APIRouter()

# Same token rules as tools/export_results.py (the app never imports tools/).
_PARAM_RE = re.compile(r"(?<![:\w]):([a-z_][a-z0-9_]*)")
_INCLUDE_RE = re.compile(r"__INCLUDE_([a-z0-9_]+)__")


# ---------------------------------------------------------------------------------------------
# Header :param substitution: the ONE switch point, so a future change to the substitution rules
# means changing this one function's body, not every call site.
# ---------------------------------------------------------------------------------------------


def _substituted(spec: registry.QuerySpec) -> dict:
    """read_this/healthy/investigate_if/actions/not_assessed_reasons, every :param token replaced
    by its value in effect (service.substitute_header_params)."""
    return service.substitute_header_params(spec)


# ---------------------------------------------------------------------------------------------
# summary_line -- line 1 of a finding's 2-line panel summary.
# ---------------------------------------------------------------------------------------------

_SNAKE_TOKEN_RE = re.compile(r"\b[a-z][a-z0-9]*(?:_[a-z0-9]+)+\b")
_ONE_ROW_RE = re.compile(r"^One row\s*(?:=|is)\s*", re.IGNORECASE)
_COMBO_RE = re.compile(
    r"\b(?:a|one)\s+\(\s*([a-z][a-z0-9_]*(?:\s*,\s*[a-z][a-z0-9_]*)+)\s*\)\s+(?:combination|group|pair)\b",
    re.IGNORECASE,
)
_OTHER_BRACKET_RE = re.compile(r"\s*\(\s*[a-z][a-z0-9_]*(?:\s*,\s*[a-z][a-z0-9_]*)+\s*\)")
_ID_TOKEN_RE = re.compile(r"\b(DEC-\d+|T-\d+|P4-\d+)\b")
_PARAM_LEFTOVER_RE = re.compile(r":[A-Za-z_]\w*")

# ---------------------------------------------------------------------------------------------
# _clean_prose -- the Guide's own reference-documentation pass over a header's free text. Never
# touches the .sql header itself, and never runs on summary_line()'s output (that has its own,
# separately tested, allow-listed rules) -- only on what _finding_json sends out below.
# ---------------------------------------------------------------------------------------------

# A decision, task or plan id: DEC-66.3, T-75B, P4-01, P3-WASTEUSD.
_ID = r"(?:DEC-\d+(?:\.\d+)*|T-\d+[A-Z]?|P\d-(?:\d+|[A-Z][A-Z0-9]*(?:-[A-Z0-9]+)*))"
_COMMIT_RE = re.compile(r",?\s*\bcommits?\s+[0-9a-f]{7,40}(?:\s*/\s*[0-9a-f]{7,40})*")
_ID_PER_RE = re.compile(rf"\s+(?:per|see)\s+{_ID}(?![\w-]|\.\d)")
_ID_OWNER_RE = re.compile(rf"\b{_ID}'s\b")
_PAREN_ID_ONLY_RE = re.compile(rf"\(\s*{_ID}\s*\)")
_ID_INLINE_RE = re.compile(rf"\b{_ID}(?![\w-]|\.\d)\s*[-:]?\s*")
_PAREN_LEFTOVER_RE = re.compile(r"\s*\(\s*[,;]?\s*\)|\s*,\s*(?=\))")
_DOUBLE_DASH_RE = re.compile(r"\s+--\s+")
_SHOUTED_BOOL_RE = re.compile(r"\b(TRUE|FALSE)\b")
_SENTENCE_START_RE = re.compile(r"(^|[.!?]\s+)([a-z])")


def _clean_prose(text: str | None) -> str:
    """A DEC-nn/T-nn/P4-nn id dropped (a lone "(id)" dropped whole), " -- " read as a real em
    dash, and shouted TRUE/FALSE read as plain words. Column names are left exactly as the header
    wrote them -- guide.tsx puts those in code font instead of rewording them."""
    if not text:
        return text or ""
    cleaned = _COMMIT_RE.sub("", text)
    cleaned = _ID_PER_RE.sub("", cleaned)
    cleaned = _ID_OWNER_RE.sub("the app's", cleaned)
    cleaned = _PAREN_ID_ONLY_RE.sub("", cleaned)
    cleaned = _ID_INLINE_RE.sub("", cleaned)
    cleaned = re.sub(r"\(\s*,\s*", "(", cleaned)
    cleaned = _PAREN_LEFTOVER_RE.sub("", cleaned)
    cleaned = re.sub(r"[ \t]+(?=[:,]|\.(?:\s|$))", "", cleaned)
    cleaned = _DOUBLE_DASH_RE.sub(" — ", cleaned)
    cleaned = _SHOUTED_BOOL_RE.sub(lambda m: m.group(1).lower(), cleaned)
    cleaned = re.sub(r"[ \t]{2,}", " ", cleaned).strip()

    def _cap(m: "re.Match[str]") -> str:
        # never capitalize into a column name (a snake_case identifier stays lower -- guide.tsx
        # renders it in code font, verbatim) -- only a stripped id can leave a sentence lowercase.
        if _SNAKE_TOKEN_RE.match(cleaned[m.start(2):m.start(2) + 40]):
            return m.group(0)
        return m.group(1) + m.group(2).upper()

    return _SENTENCE_START_RE.sub(_cap, cleaned)


def _desnake_word(word: str) -> str:
    """Drops a trailing _id and turns _ into a space (e.g. "termination_code" -> "termination code")."""
    word = re.sub(r"_id$", "", word)
    return word.replace("_", " ")


def _join_words(names: list) -> str:
    words = [_desnake_word(n.strip()) for n in names]
    if len(words) == 1:
        return words[0]
    return ", ".join(words[:-1]) + " and " + words[-1]


def _combo_sub(m: "re.Match[str]") -> str:
    return "one " + _join_words(m.group(1).split(","))


def _first_sentence(text: str) -> str:
    if not text:
        return ""
    m = re.match(r"^(.*?[.!?])(\s|$)", text.strip())
    return (m.group(1) if m else text.strip()).strip()


def _auto_summary(read_this: str) -> str:
    """The first sentence of read_this: "One row is" -> "Each row is", a (x, y, z) combination ->
    "one x, y and z", any other bracketed snake_case list dropped, everything else desnaked."""
    line = _first_sentence(read_this)
    line = _ONE_ROW_RE.sub("Each row is ", line)
    line = _COMBO_RE.sub(_combo_sub, line)
    line = _OTHER_BRACKET_RE.sub("", line)
    line = _SNAKE_TOKEN_RE.sub(lambda m: _desnake_word(m.group(0)), line)
    return re.sub(r"\s{2,}", " ", line).strip()


def _summary_checks(line: str) -> list:
    """[] means `line` is a fine automatic summary; otherwise names why it needs a summary: override."""
    problems = []
    if not line.startswith("Each row is"):
        problems.append("does not start with 'Each row is'")
    if len(line) > 140:
        problems.append(f"is {len(line)} characters, over the 140 limit")
    if line.count("(") != line.count(")"):
        problems.append("brackets are not balanced")
    if _ID_TOKEN_RE.search(line):
        problems.append("still carries a DEC-/T-/P4- id")
    if _PARAM_LEFTOVER_RE.search(line):
        problems.append("still carries a :param token")
    if _SNAKE_TOKEN_RE.search(line):
        problems.append("still carries snake_case")
    return problems


def summary_line(spec: registry.QuerySpec, header_summary: str | None = None) -> dict:
    """`header_summary` (a header's own optional override) verbatim when given, else the
    auto-derived first sentence of read_this. `problems` is [] when the text needs no override."""
    if header_summary and header_summary.strip():
        return {"text": header_summary.strip(), "source": "header", "problems": []}
    # runs on the same substituted read_this the panel and the Guide both show
    text = _auto_summary(_substituted(spec)["read_this"])
    return {"text": text, "source": "auto", "problems": _summary_checks(text)}


# ---------------------------------------------------------------------------------------------
# first_step -- line 2's "first step".
# ---------------------------------------------------------------------------------------------

_TIER_WORDS = ("free", "config", "spend")
_ANYWHERE_TIER_BRACKET_RE = re.compile(r"\(([^()]*(?:free|config|spend)[^()]*)\)", re.IGNORECASE)
_TRAILING_BRACKET_RE = re.compile(r"\s*\(([^()]*)\)\s*[;.]?\s*$")
_CUT_SEP_RE = re.compile(r": |; | - ")


def _action_tier(raw: str) -> str | None:
    t = (raw or "").lower()
    for word in _TIER_WORDS:
        if word in t:
            return word
    return None


def _cap_words(text: str, limit: int = 100) -> str:
    if len(text) <= limit:
        return text
    cut = text[:limit]
    last_space = cut.rfind(" ")
    head = cut[:last_space] if last_space > 40 else cut
    return re.sub(r"[\s,;:.–-]+$", "", head) + "..."


def first_step(actions: list) -> dict | None:
    """Rung 1 of an actions ladder (ported from overview_tile.tsx's firstAction()): tier bracket
    stripped when trailing, cut at the first ": "/"; "/" - ", snake_case -> words, 100-char cap.
    None when there is no ladder, or rung 1 is blank/"n/a"."""
    if not actions:
        return None
    full = str(actions[0]).strip()
    if not full or full.lower().startswith("n/a"):
        return None

    tier = None
    anywhere = _ANYWHERE_TIER_BRACKET_RE.search(full)
    if anywhere:
        tier = _action_tier(anywhere.group(1))
    trailing = _TRAILING_BRACKET_RE.search(full)
    if trailing and _action_tier(trailing.group(1)):
        full = full[: trailing.start()].strip()
    full = re.sub(r"[;.]+$", "", full).strip()
    if not full:
        return None

    text = full
    cut = _CUT_SEP_RE.search(text)
    if cut and cut.start() >= 25:
        text = text[: cut.start()]
    text = _SNAKE_TOKEN_RE.sub(lambda m: _desnake_word(m.group(0)), text)
    text = _cap_words(text)
    return {"text": text, "full": full, "tier": tier}


# ---------------------------------------------------------------------------------------------
# build_guide -- GET /api/guide's whole body.
# ---------------------------------------------------------------------------------------------


def _safe_thresholds() -> dict:
    try:
        return app_config.load_thresholds()
    except app_config.ConfigError:
        return {}


def _safe_materiality_count() -> int:
    try:
        return len(app_config.load_materiality())
    except app_config.ConfigError:
        return 0


def _param_json(query_id: str, param: dict, thresholds: dict) -> dict:
    name = param["name"]
    per_query = thresholds.get(query_id) or {}
    all_ = thresholds.get("_all") or {}
    if name in per_query:
        value, source = per_query[name], "your setting"
    elif name in all_:
        value, source = all_[name], "your setting"
    else:
        value, source = param.get("default"), "default"
    return {"name": name, "meaning": param.get("meaning"), "value": value, "source": source}


# `windowed` (registry.py) only says the app's period_days selector drives the query: a check
# with a calendar-month grain still has a period without period_days, so windowed=False alone would
# misread as "no period at all" (the article's window chip).
FIXED_PERIOD_QUERY_IDS = frozenset({"cost_monthly_actuals"})


def period_kind(spec: registry.QuerySpec) -> str:
    """"days" (the app's 7/30/90-day window), "fixed" (its own period the window selector never
    touches, e.g. calendar months) or "current" (current state, no period at all)."""
    if spec.windowed:
        return "days"
    if spec.query_id in FIXED_PERIOD_QUERY_IDS:
        return "fixed"
    return "current"


def _money_column(names: list | None, declared: str | None = None) -> dict | None:
    """The one column a Guide article treats as this check's own dollar figure -- the SAME rule
    /api/findings' bulk money field uses (finding_columns.money_column), so the Guide and All
    findings never name a different column for the same check. None when the check has none."""
    col = finding_columns.money_column(names or [], declared)
    return {"column": col[0], "kind": col[1]} if col else None


def _idle_gap_seconds(specs: list, thresholds: dict):
    """The idle-gap threshold, read off whichever query's header names a param called
    idle_gap_seconds; None if no query has one."""
    for spec in specs:
        for param in spec.params:
            if param["name"] == "idle_gap_seconds":
                return _param_json(spec.query_id, param, thresholds)["value"]
    return None


def _tag_reach(spec: registry.QuerySpec, names: list | None, spend_ready: bool) -> dict | None:
    """Which tag levels a tag filter follows for this check, as /api/finding would apply them;
    None when the check is not built, so its columns are unknown."""
    if spend_ready and app_tag_spend.has_variant(spec.query_id):
        return {"kind": "spend", "words": list(app_tag_spend.CHAIN_WORDS), "reason": None}
    if names is None:
        return None
    chain = app_core_tags.tag_chain(spec.query_id, names, spec.domain)
    return {"kind": chain.kind, "words": chain.chain_words, "reason": chain.reason}


def _traps_for(spec: registry.QuerySpec, names: list | None, floor: dict | None, needs_ent: bool) -> list:
    """Concept pages this check is exposed to, each with its one-line warning."""
    views = {name for _schema, name in spec.sources}
    slugs = []
    if views & _CLOUD_VIEWS:
        slugs.append("cloud-services")
    if views & _ATTRIBUTION_VIEWS:
        slugs.append("attribution")
    if views & _STORAGE_VIEWS:
        slugs.append("failsafe")
    if spec.query_id in _ADAPTIVE_IDS:
        slugs.append("adaptive")
    if spec.query_id in _IDLE_IDS:
        slugs.append("idle")
    if spec.query_id in _BACKUP_IDS:
        slugs.append("backups")
    slugs.append("latency")
    if any(schema == "SHOW" for schema, _name in spec.sources):
        slugs.append("visibility")
    if needs_ent:
        slugs.append("editions")
    if spec.money or any(n.startswith("est_") for n in (names or [])):
        slugs.append("money-kinds")
    if floor:
        slugs.append("floors")
    return [{"concept": s, "text": CONCEPT_TRAPS[s]} for s in slugs]


def _finding_json(spec: registry.QuerySpec, by_id: dict, docs: dict, thresholds: dict,
                   columns_by_id: dict, discount_pct: float, spend_ready: bool = False,
                   floors: dict | None = None) -> dict:
    sub = _substituted(spec)
    summary = summary_line(spec, getattr(spec, "summary", None))
    step = first_step(sub["actions"])
    reads = [app_core_data.source_key(schema, name) for schema, name in spec.sources]

    names = columns_by_id.get(spec.query_id)
    columns = None
    if names is not None:
        kinds = service.classify_columns(names, discount_pct)
        columns = [{"name": n, "kind": kinds[n]["kind"]} for n in names]

    next_list = []
    for n in spec.next:
        target = by_id.get(n["query_id"])
        # Only checks with a Guide page of their own; a link to any other falls back to the home.
        if target is None or not target.executable:
            continue
        next_list.append({
            "query_id": n["query_id"],
            "title": target.title if target else None,
            "if": n.get("if", ""),
        })

    floor = (floors or {}).get(spec.query_id)
    needs_ent = app_reasons.needs_enterprise(spec.requires, spec.empty_if)
    return {
        "query_id": spec.query_id,
        "title": spec.title,
        "domain": spec.domain,
        "tier": spec.tier,
        "is_finding": spec.is_finding,
        "windowed": spec.windowed,
        "period_kind": period_kind(spec),
        # _clean_prose here too: an auto-derived summary (unlike header_summary) can still carry
        # an inline id or shouted bool from read_this, same as every other prose field below.
        "summary": _clean_prose(summary["text"]),
        "summary_source": summary["source"],
        "first_step": step,
        "read_this": _clean_prose(sub["read_this"]),
        "healthy": _clean_prose(sub["healthy"]),
        "investigate_if": _clean_prose(sub["investigate_if"]),
        "actions": [_clean_prose(a) for a in sub["actions"]],
        "not_assessed_reasons": [_clean_prose(r) for r in sub["not_assessed_reasons"].values()],
        "empty_if": list(spec.empty_if),
        "empty_if_words": [EMPTY_IF_WORDS.get(token, token) for token in spec.empty_if],
        "caveats": _clean_prose(spec.caveats),
        "confidence": spec.confidence,
        "confidence_note": _clean_prose(spec.confidence_note),
        # Every check is the app's own SQL (one flat folder), so the reviewer row reads "app".
        "origin": "app",
        "requires": _clean_prose(spec.requires),
        "params": [_param_json(spec.query_id, p, thresholds) for p in spec.params],
        "next": next_list,
        "reads": reads,
        "docs": [f"{schema}.{name}" for schema, name in spec.sources if f"{schema}.{name}" in docs],
        "learn_url": spec.learn_url,
        "columns": columns,
        "money": _money_column(names, spec.money),
        "tag_reach": _tag_reach(spec, names, spend_ready),
        "grants": app_reasons.grants_for(reads),
        "needs_enterprise": needs_ent,
        "floor": {"column": floor.get("column"), "label": floor.get("label")} if floor else None,
        "traps": _traps_for(spec, names, floor, needs_ent),
    }


def _concept_docs() -> dict:
    """{slug: {title, url}} from the `concepts` list of config/snowflake_docs.yml (docs.snowflake.com
    only); {} when the file or the list is unreadable, so the Guide loses links, never pages."""
    try:
        raw = yaml.safe_load(snowflake_docs._PATH.read_text(encoding="utf-8")) or {}  # noqa: SLF001
    except (OSError, yaml.YAMLError):
        return {}
    out = {}
    for item in (raw.get("concepts") if isinstance(raw, dict) else None) or []:
        if isinstance(item, dict) and str(item.get("url", "")).startswith("https://docs.snowflake.com/"):
            out[str(item.get("key"))] = {"title": item.get("title") or item.get("key"), "url": item["url"]}
    return out


def _literal(value) -> str:
    if value is None:
        return "NULL"
    if isinstance(value, bool):
        return "TRUE" if value else "FALSE"
    if isinstance(value, (int, float)):
        return repr(value)
    return "'" + str(value).replace("'", "''") + "'"


def sql_text(query_id: str) -> dict:
    """The check's own read-only SQL (the audit's statement, never customer query text), includes
    expanded and every :param filled with the value in effect. Raises KeyError for an unknown id."""
    spec = next((s for s in registry.load_registry() if s.query_id == query_id and s.executable), None)
    if spec is None:
        raise KeyError(query_id)
    resolved = {name: value for name, (value, _src) in service.resolve_params(spec).items()}
    resolved.setdefault("period_days", 30)
    common = registry.QUERIES_DIR / "common"
    direct = app_core_data.direct_export_info()
    as_of = str(direct["as_of"])[:10] if direct and direct.get("as_of") else None
    price = (direct or {}).get("pricing") or {}
    ctx = {
        "__AS_OF_DATE__": f"CAST('{as_of}' AS DATE)" if as_of else "CURRENT_DATE()",
        "__ACCOUNT_ID__": "'<account_id>'",
        "__CLOUD__": "'<cloud>'",
        "__CREDIT_PRICE__": _literal(price.get("credit_price_usd")),
        "__STORAGE_PRICE_TB_MONTH__": _literal(price.get("storage_price_usd_tb_month")),
        "__QUERY_SOURCE__": "'<query_tag>'",
        "__WITH_SNOWFLAKE_TASKS__": _literal(bool((direct or {}).get("include_snowflake_tasks"))),
    }

    def fill(text: str) -> str:
        text = _INCLUDE_RE.sub(lambda m: (common / f"{m.group(1)}.sql").read_text(encoding="utf-8").strip(), text)
        text = _PARAM_RE.sub(lambda m: _literal(resolved[m.group(1)]) if m.group(1) in resolved else m.group(0), text)
        for key, value in ctx.items():
            text = text.replace(key, value)
        return text.strip().rstrip(";")

    return {
        "query_id": query_id,
        "pre": [fill(p) for p in spec.pre],
        "sql": fill(spec.body),
        "params": dict(resolved),
        "note": "The audit's own read-only statement with the values in effect filled in; it never holds customer query text.",
    }


@router.get("/api/guide/sql/{query_id}")
def get_guide_sql(query_id: str) -> dict:
    """GET /api/guide/sql/{query_id}: the check's own SQL, params filled with their defaults."""
    try:
        return sql_text(query_id)
    except KeyError:
        raise HTTPException(status_code=404, detail=f"No check named {query_id}") from None


def build_guide() -> dict:
    """GET /api/guide's whole body: one executable-registry entry per finding, the docs.snowflake.com
    page of every source the checks read, and the app-level numbers the Guide's prose quotes."""
    try:
        settings = app_config.load_settings()
    except app_config.ConfigError:
        settings = app_config.DEFAULT_SETTINGS
    all_specs = registry.load_registry()
    by_id = {s.query_id: s for s in all_specs}
    specs = [s for s in all_specs if s.executable]
    thresholds = _safe_thresholds()

    docs_error = None
    try:
        docs = snowflake_docs.load_docs()
    except (snowflake_docs.DocsError, OSError) as exc:
        docs = {}
        docs_error = str(exc)
    discount_pct = float(settings["discount_pct"])

    columns_available = True
    try:
        columns_by_id = app_core_data.finding_columns_batch([s.query_id for s in specs])
    except (duckdb.Error, OSError):
        columns_by_id = {}
        columns_available = False

    docs_json = {key: {"title": entry.title, "url": entry.url} for key, entry in docs.items()}

    try:
        spend_ready = app_core_data.tag_spend_ready()
    except (duckdb.Error, OSError):
        spend_ready = False
    try:
        floors = app_config.load_materiality()
    except app_config.ConfigError:
        floors = {}
    findings = [
        _finding_json(s, by_id, docs, thresholds, columns_by_id, discount_pct, spend_ready, floors)
        for s in specs
    ]

    direct = app_core_data.direct_export_info()
    return {
        "app": {
            "as_of": direct["as_of"] if direct else None,
            "direct_export": direct,
            "window_options": list(service.WINDOW_CHOICES),
            "default_window": settings["default_window"],
            "discount_pct": discount_pct,
            "idle_gap_seconds": _idle_gap_seconds(specs, thresholds),
            "columns_available": columns_available,
            "docs_error": docs_error,
            "materiality_floors_configured": _safe_materiality_count(),
        },
        "docs": docs_json,
        "concept_docs": _concept_docs(),
        "findings": findings,
    }
