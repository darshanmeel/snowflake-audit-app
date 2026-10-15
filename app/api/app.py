"""app/api/app.py

The FastAPI application. Every route returns JSON, never HTML; the store is read through
app/core/data.py's functions, and this module never builds SQL itself. app/web's static files are
served from the same process, so `python -m app.api` serves both the API and the front end.

Account ids, filters and fields are the Snowflake account (account_id, account_ids); the legacy workspace_ids parameter and /api/workspaces path still answer.

Routes:
    GET /api/status                     {state, settings_error, database, brand}: the one route the
                                         shell calls first. state is "settings_invalid" |
                                         "no_database" | "build_incomplete" | "ready"
                                         (settings_invalid wins). Never raises.
    GET /api/meta                       as_of, window options and their real availability, check
                                         counts (ok / failed / not built), the tag-attribute keys
                                         at least one account carries, brand, the money cut-off and
                                         the export's own metadata (direct_export).
    GET /api/accounts                   dims.dim_account: account_id (the account locator), name,
                                         env, env_reason, url, env_source, plus one <key>/
                                         <key>_share/<key>_reason column set per canonical tag key
                                         (cost_center follows settings' cost_center_tag_keys).
    GET/PUT /api/settings/privacy       {mask_user_identities, mask_fields, mask_kinds, default}: mask
                                         user names and emails on screen; the kinds of names the next
                                         export or Refresh masks (both off by default)
    GET/PUT /api/settings/cost-center   {keys, default, suggestions}: which raw tag key(s) count as
                                         "cost center". PUT validates 1-5 non-empty keys and writes
                                         config/settings.local.yml, picked up on the next request.
    GET /api/dims                       dims.dim_task and dim_warehouse (names, owner role), for
                                         "names, not ids" in the tab charts.
    GET /api/coverage                   source states x dependent query_ids, plus the run-results
                                         detail. export_mode ("direct" | "none"); checks_not_ok
                                         groups every failed or never-run check by plain reason with
                                         the fix; truncated_query_ids: the export's row-cap hits.
    GET /api/guide                      app/api/guide.py's build_guide(): the Guide tab's whole feed.
    GET /api/rollup, /api/rollup/top, /api/rollup/keys
                                         the nested cost or performance rollup for one tag key.
                                         area=cost (default) or performance; 422 for a bad area, a
                                         missing key or an unknown window.
    GET /api/tag_origins                the dollars the active tag filter keeps, by where each
                                         dollar's value was set; keys [] with no tag filter.
    GET /api/tags                       every tag key/value seen, ?search=, optional ?tag_key=;
                                         503 with a plain detail when the tag tables were not loaded.
    GET /api/findings                   one row per executable registry query: query_id, title,
                                         domain, tier, outcome, status_counts, row_count, money,
                                         affected, not_assessed. Accepts the workspace-attribute
                                         filters (whatever config/tag_aliases.yml declares) and
                                         tag filters: tag_key/tag_value, or repeated `tag=<key>` /
                                         `tag=<key>:<value>` (the same key ORs its values, a
                                         different key ANDs across names).
    GET /api/finding/{query_id}         columns, rows, the four-outcome outcome and the header
                                         fields a panel shows, with every :param token replaced by
                                         the value in effect. Materiality floor: each row's `status`
                                         is the EFFECTIVE (floored) status, the raw value survives
                                         as status_raw, plus below_floor, and the body carries
                                         "floor". Optional job_id scopes to one task, `status`
                                         (repeated) to those status values, tag filters as above.
    GET /api/finding/{query_id}/aggregate
                                         a server-side SUM / COUNT / COUNT DISTINCT over EVERY row
                                         matching the filters, grouped by 0-2 real columns, with a
                                         top-N + "other" fold when `top` is given.
    GET /api/finding/{query_id}/rows.csv
                                         every row of a check as CSV (window and every filter applied,
                                         masking applied, no row cap); 409 when the check is not assessed.
    GET /api/warehouses, /api/databases the pickers for the warehouse and database(+schema) filters,
                                         each entry named "name (id)".
    GET /api/tags/compliance            mandatory-tag compliance: objects missing each required tag and the $
                                         of untagged spend; with no required tags, tag coverage by object type.
    GET/PUT /api/settings/required-tags {keys, default}: the tag names every object must carry.
    GET /api/fix-first                  the "Fix these first" ranking: priced findings, and CRITICAL findings
                                         with no $, in labelled groups.
    /api/findings, /api/finding, /aggregate, rows.csv, /api/fix-first also take warehouse, database and
                                         schema (repeatable); a check with no such column is left unfiltered
                                         and says so (scope.warehouse_applied / dim_applied).
    GET /                               app/web/dist/index.html (the Vite build of web/; StaticFiles,
                                         mounted last so it never shadows an /api/* route). Any other
                                         path that is not a file and not /api/* gets index.html too.

A query_id app/core/registry does not know 404s; any other unexpected failure surfaces as FastAPI's
own 500. A store-level read failure (a locked or corrupt db) is reported by load_outcome and
list_findings as outcome="error" with a 200. A broken config/settings.yml (app_config.ConfigError)
gets its own handler below: a structured 503 naming the offending key and line.
"""
from __future__ import annotations

import dataclasses
import html
import json
import mimetypes
import sys
from pathlib import Path

import duckdb
from fastapi import Depends, FastAPI, HTTPException, Query, Request
from fastapi.responses import JSONResponse, Response
from fastapi.staticfiles import StaticFiles
from starlette.exceptions import HTTPException as StarletteHTTPException

# Windows can map these to text/plain from the registry; a module script and a stylesheet need their real types.
mimetypes.add_type("text/javascript", ".js")
mimetypes.add_type("text/css", ".css")
mimetypes.add_type("font/woff2", ".woff2")

_ROOT = Path(__file__).resolve().parent.parent.parent
if str(_ROOT) not in sys.path:
    sys.path.insert(0, str(_ROOT))

from app.api import guide as guide_api  # noqa: E402
from app.api import refresh as app_refresh  # noqa: E402
from app.api import service  # noqa: E402
from app.core import config as app_config  # noqa: E402
from app.core import cost_center as app_cost_center  # noqa: E402
from app.core import data as app_core_data  # noqa: E402
from app.core import identity as app_identity  # noqa: E402
from app.core import masking as app_masking  # noqa: E402
from app.core import materiality as app_materiality  # noqa: E402
from app.core import pricing as app_pricing  # noqa: E402
from app.core import registry  # noqa: E402
from app.core import rollup as app_rollup  # noqa: E402
from app.core import tag_compliance as app_tag_compliance  # noqa: E402
from app.core import tags as app_core_tags  # noqa: E402

WEB_DIR = _ROOT / "app" / "web" / "dist"

app = FastAPI(title="Crosshire API", version="0.1.0")

# Read-only GETs whose answer depends only on the db file, the settings and the URL: kept once
# built, so a page visited again (or a window switched back) reads in milliseconds.
_CACHED_PREFIXES = ("/api/finding/", "/api/rollup", "/api/tags/")
_RESPONSE_CACHE: dict = {}


def _response_cache_bytes() -> int:
    # settings load.response_cache_mb; 0 turns the cache off.
    try:
        return int(app_config.load_settings()["load"]["response_cache_mb"]) * 1024 * 1024
    except app_config.ConfigError:
        return 0


@app.middleware("http")
async def _cache_read_only(request: Request, call_next):
    if request.method != "GET" or not request.url.path.startswith(_CACHED_PREFIXES) or request.url.path.endswith(".csv"):
        return await call_next(request)
    cap = _response_cache_bytes()
    if cap <= 0:
        return await call_next(request)
    stamp = service.data_stamp()
    if stamp is None:
        return await call_next(request)
    key = (stamp, request.url.path, request.url.query)
    hit = _RESPONSE_CACHE.get(key)
    if hit is not None:
        return Response(hit[1], status_code=200, headers={"content-type": hit[0]})
    response = await call_next(request)
    if response.status_code != 200:
        return response
    body = b"".join([chunk async for chunk in response.body_iterator])
    # Bounded by bytes, not entries: a few large row pages must not fill a small machine's memory.
    if len(body) > cap:  # one oversized page is served, not kept
        return Response(body, status_code=200, headers={
            k: v for k, v in response.headers.items() if k.lower() != "content-length"})
    if sum(len(v[1]) for v in _RESPONSE_CACHE.values()) + len(body) > cap:
        _RESPONSE_CACHE.clear()
    _RESPONSE_CACHE[key] = (response.headers.get("content-type", "application/json"), body)
    return Response(body, status_code=200, headers={
        k: v for k, v in response.headers.items() if k.lower() != "content-length"})

# One handler for the whole app: every route calls app_config.load_settings() sooner or later, so a
# typo in config/settings.yml would otherwise turn every route into a plain-text 500. A structured
# 503 naming the offending key and line instead, which GET /api/status also uses to build the
# "fix this line" screen.
@app.exception_handler(app_config.ConfigError)
def _config_error_handler(request: Request, exc: app_config.ConfigError) -> JSONResponse:
    return JSONResponse(
        status_code=503,
        content={
            "detail": str(exc),
            "state": "settings_invalid",
            "key": getattr(exc, "key", None),
            "line": getattr(exc, "line", None),
        },
    )


def _validate_window(window: int) -> None:
    if window not in service.WINDOW_CHOICES:
        raise HTTPException(
            422, f"window must be one of {list(service.WINDOW_CHOICES)}, got {window}"
        )


def _resolve_window(window: int | None, settings: dict) -> int:
    resolved = window if window is not None else settings["default_window"]
    _validate_window(resolved)
    return resolved


def _open_window(default_window: int, windows: list[dict]) -> int:
    """The window GET /api/meta opens on: default_window if this db has it, else the largest one
    it does (never a picker stuck on a window the db doesn't have)."""
    available = [w["days"] for w in windows if w["available"]]
    if default_window in available:
        return default_window
    return max(available) if available else default_window


# The status-value vocabulary GET /api/finding and its /aggregate twin accept: the closed set
# service.STATUS_ORDER names (an unknown value is a caller bug worth a 422, not a silent no-match).
def _validate_statuses(statuses: list[str]) -> None:
    bad = [s for s in statuses if s not in service.STATUS_ORDER]
    if bad:
        raise HTTPException(422, f"status must be one of {service.STATUS_ORDER}, got {bad!r}")


def _parse_tag_filter(
    tag_key: str | None, tag_value: str | None, tag: list[str] | None = None
) -> "app_core_tags.TagFilterSet | None":
    """The tag filter: `tag_value` without `tag_key`, or a `tag_key`/`tag` entry that normalises to
    empty, is a 422 --
    app_core_tags.TagFilterSet.from_params' own ValueError, converted here the same way
    service.load_outcome's ValueError already becomes one on the aggregate route. `tag` (repeated):
    "<key>" for All (the key present, any value) or "<key>:<value>" for one value -- repeat the
    same key to OR its values, a different key to AND across names; the legacy `tag_key`/
    `tag_value` pair keeps meaning exactly what it does today and merges into this the same way."""
    try:
        return app_core_tags.TagFilterSet.from_params(tag_key, tag_value, tag)
    except ValueError as exc:
        raise HTTPException(422, str(exc))


def _tag_json(tag: "app_core_tags.TagFilterSet | None") -> dict | None:
    """The `"tag"` object every tag-aware route echoes, or None with no filter. A plain
    single-name request (0 or 1 value) returns the exact {tag_key, display_key, tag_value} shape
    it always has. Several names, or several values on one name, add `groups` and "multi": true;
    tag_key/tag_value (and every per-row tag_match_* column) still describe the FIRST name only, so
    tag_value is that name's first value rather than null -- an older client reading null as "All
    values" would otherwise be wrong."""
    if tag is None:
        return None
    first = tag.groups[0]
    multi = len(tag.groups) > 1 or len(first.values) > 1
    body = {
        "tag_key": first.key,
        "display_key": first.key,  # the exact display spelling lives in tags.tag_index only
        "tag_value": app_core_tags.tag_keys.model_value_to_api(first.values[0]) if first.values else None,
    }
    if multi:
        body["multi"] = True
        body["groups"] = [
            {
                "tag_key": g.key,
                "display_key": g.key,
                "values": [app_core_tags.tag_keys.model_value_to_api(v) for v in g.values],
            }
            for g in tag.groups
        ]
    return body


def account_scope(
    account_ids: list[str] = Query(default=[]),
    workspace_ids: list[str] = Query(default=[], include_in_schema=False),  # legacy spelling of account_ids
) -> list[str]:
    """The account ids a request is scoped to (repeated account_ids, or the legacy workspace_ids)."""
    return list(dict.fromkeys([*account_ids, *workspace_ids]))


def dim_scope(
    warehouse: list[str] = Query(default=[]),
    database: list[str] = Query(default=[]),
    schema: list[str] = Query(default=[]),
) -> "app_core_data.DimFilter | None":
    """The warehouse, database and schema filters (names, repeatable; a schema is DATABASE.SCHEMA)."""
    return app_core_data.DimFilter.of(warehouse, database, schema)


def _dims_json(dims: "app_core_data.DimFilter | None") -> dict:
    return {"warehouses": list(dims.warehouses) if dims else [], "databases": list(dims.databases) if dims else [],
            "schemas": list(dims.schemas) if dims else []}


# -------------------------------------------------------------------------------------------
# Workspace tag-attribute filters (cost_center, team, business_unit, domain: whatever
# config/tag_aliases.yml declares). The key SET is config-driven, so it is read as ordinary query
# params by NAME (request.query_params.getlist), the same repeated-value convention `env` and
# `account_ids` use.
# -------------------------------------------------------------------------------------------


def _canonical_keys() -> list[str]:
    try:
        return sorted(app_config.load_tag_aliases().get("canonical", {}))
    except app_config.ConfigError:
        return []


def _read_attribute_filters(request: Request, canonical_keys: list[str]) -> dict[str, list[str]]:
    out: dict[str, list[str]] = {}
    for key in canonical_keys:
        values = request.query_params.getlist(key)
        if values:
            out[key] = values
    return out


_UNPOPULATED_ATTRIBUTE_VALUES = {"not_tagged", "no_usage"}


def _populated_attribute_keys(canonical_keys: list[str]) -> list[str]:
    """Which canonical keys at least one account actually carries a real value or 'mixed' for,
    never 'not_tagged' (billed, but this key never seen) or 'no_usage' (no billed credits at all).
    The UI hides a key's filter when it is not in this list, rather than offering an empty dropdown
    that reads as "there are no cost centres"."""
    if not canonical_keys:
        return []
    try:
        df = app_core_data.read_dim_account()
    except (duckdb.Error, OSError):
        return []
    populated = []
    for key in canonical_keys:
        if key not in df.columns:
            continue
        if (~df[key].isin(_UNPOPULATED_ATTRIBUTE_VALUES)).any():
            populated.append(key)
    return populated


# -------------------------------------------------------------------------------------------
# GET/PUT /api/settings/cost-center: which raw tag key(s) the team says mean "cost center"
# (config/settings.yml cost_center_tag_keys, app/core/cost_center.py). PUT writes only
# config/settings.local.yml; every route that treats an attribute filter as "cost center" re-reads
# settings on its own next call, so this takes effect at once.
# -------------------------------------------------------------------------------------------


def _cost_center_body() -> dict:
    settings = app_config.load_settings()
    return {
        "keys": settings["cost_center_tag_keys"],
        "default": list(app_config.DEFAULT_SETTINGS["cost_center_tag_keys"]),
        "suggestions": app_cost_center.suggestions(),
    }


@app.get("/api/settings/cost-center")
def get_cost_center_settings() -> dict:
    return _cost_center_body()


@app.put("/api/settings/cost-center")
def put_cost_center_settings(body: dict) -> dict:
    raw_keys = body.get("keys") if isinstance(body, dict) else None
    keys = [k.strip() for k in raw_keys if isinstance(k, str) and k.strip()] if isinstance(raw_keys, list) else []
    try:
        app_config.save_settings_local({"cost_center_tag_keys": keys})
    except app_config.ConfigError as exc:
        raise HTTPException(422, str(exc))
    return _cost_center_body()


# -------------------------------------------------------------------------------------------
# GET/PUT /api/settings/privacy: mask_user_identities masks user names and emails in API output
# (app/core/identity.py); mask_fields lists the kinds of names the next export or Refresh replaces
# with tokens before any file is saved (app/core/masking.py). Both off by default. PUT writes only
# config/settings.local.yml.
# -------------------------------------------------------------------------------------------


def _privacy_body() -> dict:
    privacy = app_config.load_settings()["privacy"]
    return {"mask_user_identities": bool(privacy["mask_user_identities"]),
            "mask_fields": list(privacy.get("mask_fields") or []),
            "mask_kinds": list(app_masking.MASK_KINDS),
            # What the loaded export masked; the setting above applies from the next export.
            "loaded_masked": list((app_core_data.direct_export_info() or {}).get("masked") or []),
            "default": bool(app_config.DEFAULT_SETTINGS["privacy"]["mask_user_identities"])}


@app.get("/api/settings/privacy")
def get_privacy_settings() -> dict:
    return _privacy_body()


@app.put("/api/settings/privacy")
def put_privacy_settings(body: dict) -> dict:
    if not isinstance(body, dict):
        raise HTTPException(422, "body must be an object")
    privacy = dict(app_config.load_settings()["privacy"])
    if "mask_user_identities" in body:
        if not isinstance(body["mask_user_identities"], bool):
            raise HTTPException(422, "mask_user_identities must be true or false")
        privacy["mask_user_identities"] = body["mask_user_identities"]
    if "mask_fields" in body:
        try:
            privacy["mask_fields"] = app_masking.parse_kinds(body["mask_fields"] or [])
        except (ValueError, TypeError) as exc:
            raise HTTPException(422, str(exc))
    try:
        app_config.save_settings_local({"privacy": privacy})
    except app_config.ConfigError as exc:
        raise HTTPException(422, str(exc))
    return _privacy_body()


# -------------------------------------------------------------------------------------------
# GET/PUT /api/settings/required-tags: the tag names every object must carry (settings
# required_tag_keys; empty = show tag coverage only). PUT writes config/settings.local.yml.
# -------------------------------------------------------------------------------------------


def _required_tags_body() -> dict:
    return {"keys": list(app_config.load_settings()["required_tag_keys"]),
            "default": list(app_config.DEFAULT_SETTINGS["required_tag_keys"]),
            "max": app_config.REQUIRED_TAG_KEYS_MAX}


@app.get("/api/settings/required-tags")
def get_required_tags_settings() -> dict:
    return _required_tags_body()


@app.put("/api/settings/required-tags")
def put_required_tags_settings(body: dict) -> dict:
    raw = body.get("keys") if isinstance(body, dict) else None
    if not isinstance(raw, list):
        raise HTTPException(422, "keys must be a list of tag names")
    keys = list(dict.fromkeys(k.strip() for k in raw if isinstance(k, str) and k.strip()))
    try:
        app_config.save_settings_local({"required_tag_keys": keys})
    except app_config.ConfigError as exc:
        raise HTTPException(422, str(exc))
    return _required_tags_body()


# -------------------------------------------------------------------------------------------
# GET /api/status: the shell calls this FIRST and renders a friendly screen for anything but
# "ready", instead of reaching a route that would 500 or hang.
# -------------------------------------------------------------------------------------------


@app.get("/api/status")
def get_status() -> dict:
    # settings.yml is checked first and reported on its own, not through the ConfigError handler
    # above: that handler is for every other route, which has no honest answer once settings.yml is
    # broken; this route's job is to have one regardless.
    settings_error = None
    settings = None
    try:
        settings = app_config.load_settings()
    except app_config.ConfigError as exc:
        settings_error = {
            "message": str(exc),
            "key": getattr(exc, "key", None),
            "line": getattr(exc, "line", None),
        }
    database = app_core_data.db_state()
    if settings_error is not None:
        # With settings.yml broken every other route 503s whether or not the database is fine, so
        # this is the one state worth reporting.
        state = "settings_invalid"
    else:
        state = database["state"]
    return {
        "state": state,
        "settings_error": settings_error,
        "database": database,
        "brand": settings["brand"] if settings is not None else None,
    }


# -------------------------------------------------------------------------------------------
# GET /api/meta
# -------------------------------------------------------------------------------------------


@app.get("/api/refresh")
def get_refresh() -> dict:
    return app_refresh.status()


@app.post("/api/refresh")
def post_refresh(days: int = Query(default=30, ge=1, le=90)) -> dict:
    """Export the last `days` days from Snowflake and load them; the page reloads when done."""
    return app_refresh.start(days)


# -------------------------------------------------------------------------------------------


@app.get("/api/meta")
def get_meta() -> dict:
    results = app_core_data.run_results()
    settings = app_config.load_settings()

    checks = results.get("checks", {})
    total = len(checks)
    ok = sum(1 for c in checks.values() if c.get("status") == "ok")
    failed = sum(1 for c in checks.values() if c.get("status") == "failed")
    registry_total = sum(1 for s in registry.load_registry() if s.executable)
    ran_summary = app_core_data.checks_ran_summary(results=results)
    canonical_keys = _canonical_keys()
    direct = app_core_data.direct_export_info()
    windows = app_core_data.window_status(service.WINDOW_CHOICES, direct)
    exported_coverage = app_core_data.exported_window_coverage(direct)
    # the window range labels need an end date
    as_of_date = (direct.get("as_of_date") or str(direct["as_of"] or "")[:10] or None) if direct else None

    return {
        "as_of": direct["as_of"] if direct else None,
        "as_of_date": as_of_date,
        # How many days the export actually captured, so the UI can mark a window it cannot fill:
        # windows are always built for 7/30/90 whatever the export span, so a 7-day export read at
        # 30d would return 7 days of money under a "30d" label unless something says otherwise.
        "export_days": max(exported_coverage.values()) if exported_coverage else None,
        "window_options": list(service.WINDOW_CHOICES),
        "default_window": settings["default_window"],
        # each WINDOW_CHOICES label's real availability under THIS db (an export may not have run
        # every one); open_window is the window the app should open on.
        "windows": windows,
        "open_window": _open_window(settings["default_window"], windows),
        "discount_pct": settings["discount_pct"],
        # The discount actually applied (0 when the $/credit is the invoice rate), and where the price came from.
        "discount": app_core_data.discount_info(settings["discount_pct"]),
        "price_basis": app_core_data.price_basis(),
        "edition": (direct or {}).get("edition"),
        "brand": settings["brand"],
        "privacy": {"mask_user_identities": bool(settings["privacy"]["mask_user_identities"])},
        # The canonical tag-attribute keys at least one account actually carries: the filter bar
        # renders one picker per entry, never one for a key with zero real data.
        "attribute_keys_populated": _populated_attribute_keys(canonical_keys),
        # The top-N-plus-Other cap every chart's aggregation helper respects.
        "max_chart_categories": settings["ui"]["max_chart_categories"],
        "run_results_available": bool(results.get("available")),
        "generated_at": results.get("generated_at"),
        # The one cut-off every money figure shares: complete days through data_through, today
        # partial when the export kept it.
        "cost_cutoff": app_core_data.cost_cutoff(),
        "direct_export": direct,
        "db_path": str(app_core_data._db_path()),
        "checks": {
            "registry_total": registry_total,
            "run_results_total": total,
            "ok": ok,
            "failed": failed,
            "not_built": max(registry_total - total, 0),
            # THE checks-that-ran count (independent of the window and filters): use it everywhere.
            "ran": ran_summary["ran"],
            "total": ran_summary["total"],
            "unit": ran_summary["unit"],
            "not_ran": ran_summary["not_ran"],
        },
        "checks_ran": ran_summary,
    }


# -------------------------------------------------------------------------------------------
# GET /api/accounts (legacy path /api/workspaces)
# -------------------------------------------------------------------------------------------


_ACCOUNT_FIXED_COLUMNS = ("account_id", "name", "url", "env", "env_source", "env_reason")


@app.get("/api/accounts")
@app.get("/api/workspaces")  # legacy path of /api/accounts
def get_accounts() -> list[dict]:
    # A missing or corrupt db, or a load that never reached dims.dim_account, gets a clear 503
    # rather than an opaque 500. The shell checks GET /api/status first and never reaches this
    # route in that state, but the guard stays for a load that fails mid-session.
    try:
        df = app_core_data.read_dim_account()
    except (duckdb.Error, OSError) as exc:
        raise HTTPException(503, f"dims.dim_account could not be read: {exc}")
    # The <key>/<key>_share/<key>_reason columns are config-driven (whatever config/tag_aliases.yml
    # declares at the last load), so they are carried through generically rather than named here.
    extra_columns = [c for c in df.columns if c not in _ACCOUNT_FIXED_COLUMNS]
    out: list[dict] = []
    for _, row in df.iterrows():
        rec = {
            "account_id": str(row["account_id"]),
            "workspace_id": str(row["account_id"]),  # legacy key of account_id
            "name": service._json_scalar(row.get("name")),
            "url": service._json_scalar(row.get("url")),
            "env": service._json_scalar(row.get("env")),
            "env_source": service._json_scalar(row.get("env_source")),
            "env_reason": service._json_scalar(row.get("env_reason")),
        }
        for col in extra_columns:
            rec[col] = service._json_scalar(row.get(col))
        out.append(rec)
    return out


# -------------------------------------------------------------------------------------------
# GET /api/dims: dims.dim_task and dim_warehouse, for "names, not ids" in the tab charts. Each dim
# is queried independently, so one missing dim (a duckdb CatalogException, app/core/data.py's own
# contract for these readers) never blanks out the other; the caller sees an empty list for it.
# No dim carries a person's name, so nothing here is masked.
#
# _dim_records is column-vectorised (no per-cell iterrows() loop), the two readers share one
# connection, and _DIMS_CACHE below skips recomputing while the db file (path + mtime) stays the
# same.
# -------------------------------------------------------------------------------------------


def _dim_records(df, id_cols: tuple[str, ...]) -> list[dict]:
    """df -> JSON-safe records, column at a time (NaN -> None, id_cols -> str) instead of
    df.iterrows()'s per-cell loop -- the same values _json_scalar produced, since every dim
    column here is plain text or null, never a Timestamp/numpy scalar."""
    if df.empty:
        return []
    columns = list(df.columns)
    arrays: list[list] = []
    for col in columns:
        values = df[col].tolist()
        if col in id_cols:
            values = [None if (v is None or v != v) else str(v) for v in values]
        else:
            values = [None if (v is None or (isinstance(v, float) and v != v)) else v for v in values]
        arrays.append(values)
    return [dict(zip(columns, row)) for row in zip(*arrays)]


def _dim_or_empty(loader, con: duckdb.DuckDBPyConnection | None, id_cols: tuple[str, ...]) -> list[dict]:
    try:
        return _dim_records(loader(con), id_cols)
    except (duckdb.Error, OSError):
        return []


# db path (str) + mtime -> the last get_dims() response computed for it. A single entry: an old db
# is never coming back, so nothing is gained by keeping more than the most recent.
_DIMS_CACHE: dict[tuple[str, float | None], dict] = {}


@app.get("/api/dims")
def get_dims() -> dict:
    db_path = app_core_data._db_path()
    try:
        mtime = db_path.stat().st_mtime
    except OSError:
        mtime = None
    key = (str(db_path), mtime)
    cached = _DIMS_CACHE.get(key)
    if cached is not None:
        return cached

    try:
        con = app_core_data._connect()
    except duckdb.Error:
        con = None  # each read_dim_* below opens (and fails on) its own connection instead
    try:
        result = {
            "tasks": _dim_or_empty(app_core_data.read_dim_task, con, ("account_id",)),
            "warehouses": _dim_or_empty(
                app_core_data.read_dim_warehouse, con, ("account_id", "warehouse_id")
            ),
        }
    finally:
        if con is not None:
            con.close()

    if con is not None:
        # Only a working connection is worth remembering: a total connect failure (db mid-load,
        # briefly locked) should retry on the very next call.
        _DIMS_CACHE.clear()
        _DIMS_CACHE[key] = result
    return result


# -------------------------------------------------------------------------------------------
# GET /api/coverage: source states x dependent query_ids, plus the run-results detail /api/meta only
# summarises as counts. Read-only, JSON-only: no DuckDB connection of its own except
# direct_source_states' and truncated_query_ids' short-lived ones. A source's state comes from the
# run results: which checks reading it actually succeeded.
# -------------------------------------------------------------------------------------------


@app.get("/api/coverage")
def get_coverage() -> dict:
    results = app_core_data.run_results()
    direct = app_core_data.direct_export_info()
    specs = [s for s in registry.load_registry() if s.executable]

    dependents: dict[str, list[str]] = {}
    for s in specs:
        for schema, name in s.sources:
            dependents.setdefault(app_core_data.source_key(schema, name), []).append(s.query_id)

    if direct is not None:
        export_mode = "direct"
        tables_out = app_core_data.direct_source_states(dependents, results)
    else:
        export_mode = "none"
        tables_out = {
            key: {"state": "not_assessed", "rows": None, "reason": "no export yet", "dependent_query_ids": ids}
            for key, ids in dependents.items()
        }

    return {
        "export_mode": export_mode,
        "as_of": (direct or {}).get("as_of"),
        "as_of_date": (direct or {}).get("as_of_date"),
        "tables": tables_out,
        "run_results_available": results.get("available"),
        "generated_at": results.get("generated_at"),
        "checks": results.get("checks", {}),
        # Every check not run cleanly this export, grouped by its own plain reason with the fix:
        # the Couldn't-check panel's feed.
        "checks_not_ok": app_core_data.checks_not_ok(specs, results),
        # THE checks-that-ran count, the same one /api/meta and /api/findings carry.
        "checks_ran": app_core_data.checks_ran_summary(specs, results),
        # What the export's role could read: unreadable sources with their GRANT, the billed-versus-listed
        # warehouse gap, and the account's edition (STANDARD, ENTERPRISE, ... or null when unknown).
        "visibility": app_core_data.visibility_summary(direct),
        "edition": (direct or {}).get("edition"),
        "truncated_query_ids": app_core_data.truncated_query_ids() if export_mode == "direct" else [],
    }


# -------------------------------------------------------------------------------------------
# GET /api/guide -- the Guide tab's one feed, entirely built by app/api/guide.build_guide().
# -------------------------------------------------------------------------------------------


@app.get("/api/guide")
def get_guide() -> dict:
    return guide_api.build_guide()


app.include_router(guide_api.router)


# -------------------------------------------------------------------------------------------
# GET /api/rollup / GET /api/rollup/keys. Thin
# wrappers over app/core/rollup.py: the window is resolved the same way as every other route
# (_resolve_window), and a bad area/tag_key/window from app/core/rollup.RollupError becomes a 422
# here, never an opaque 500.
# -------------------------------------------------------------------------------------------


@app.get("/api/rollup")
def get_rollup(
    request: Request,
    area: str = Query(default="cost"),
    tag_key: str = Query(...),
    window: int | None = Query(default=None),
    # tag_value (repeatable): a single value keeps marking one `selected` entry exactly as before;
    # several OR-mark every matching entry into the new `selected_values` list too (rollup always
    # builds the tree for this ONE tag_key -- there is no second name to AND against here).
    tag_value: list[str] = Query(default=[]),
    account_ids: list[str] = Depends(account_scope),
    env: list[str] = Query(default=[]),
    # The SAME active tag filter /api/finding's aggregate applies: distinct from tag_key/tag_value
    # above, which pick which value this rollup marks `selected`.
    tag: list[str] = Query(default=[]),
) -> dict:
    settings = app_config.load_settings()
    eff_window = _resolve_window(window, settings)
    attributes = _read_attribute_filters(request, _canonical_keys()) or None
    tag_filter = _parse_tag_filter(None, None, tag)
    try:
        body = app_rollup.rollup(
            area, tag_key, eff_window,
            tag_value=tag_value[0] if tag_value else None, tag_values=tag_value or None,
            account_ids=account_ids or None, env=env or None, attributes=attributes,
            tag_filter=tag_filter,
        )
    except app_rollup.RollupError as exc:
        raise HTTPException(422, str(exc))
    body["cut_sources"] = list((app_core_data.direct_export_info() or {}).get("tag_sources_cut") or [])
    return body


@app.get("/api/rollup/top")
def get_rollup_top(
    request: Request,
    area: str = Query(default="cost"),
    tag_key: str = Query(...),
    window: int | None = Query(default=None),
    top: int = Query(default=10, ge=1, le=100),
    account_ids: list[str] = Depends(account_scope),
    env: list[str] = Query(default=[]),
    tag: list[str] = Query(default=[]),
) -> dict:
    settings = app_config.load_settings()
    eff_window = _resolve_window(window, settings)
    attributes = _read_attribute_filters(request, _canonical_keys()) or None
    tag_filter = _parse_tag_filter(None, None, tag)
    try:
        return app_rollup.by_tag_top(
            area, tag_key, eff_window, top=top,
            account_ids=account_ids or None, env=env or None, attributes=attributes,
            tag_filter=tag_filter,
        )
    except app_rollup.RollupError as exc:
        raise HTTPException(422, str(exc))


@app.get("/api/tag_origins")
def get_tag_origins(
    request: Request,
    window: int | None = Query(default=None),
    account_ids: list[str] = Depends(account_scope),
    env: list[str] = Query(default=[]),
    tag: list[str] = Query(default=[]),
) -> dict:
    eff_window = _resolve_window(window, app_config.load_settings())
    attributes = _read_attribute_filters(request, _canonical_keys()) or None
    tag_filter = _parse_tag_filter(None, None, tag)
    scope = app_rollup._resolve_account_scope(account_ids or None, env or None, attributes)
    found = app_core_data.read_tag_origins(tag_filter, eff_window, scope)
    return found or {"window_days": eff_window, "usd": 0.0, "keys": []}


@app.get("/api/rollup/keys")
def get_rollup_keys(
    area: str = Query(default="cost"),
    window: int | None = Query(default=None),
) -> dict:
    settings = app_config.load_settings()
    eff_window = _resolve_window(window, settings)
    try:
        return app_rollup.rollup_keys(area, eff_window)
    except app_rollup.RollupError as exc:
        raise HTTPException(422, str(exc))


# -------------------------------------------------------------------------------------------
# GET /api/tags: the tag search picker's own feed: every tag key and value seen, no configuration.
# -------------------------------------------------------------------------------------------


@app.get("/api/tags")
def get_tags(
    search: str = Query(default=""),
    tag_key: str | None = Query(default=None),
    limit_keys: int = Query(default=20, ge=1, le=200),
    limit_values: int = Query(default=50, ge=1, le=500),
) -> dict:
    try:
        return app_core_tags.read_tag_index(search or None, tag_key, limit_keys, limit_values)
    except app_core_tags.TagModelsNotBuiltError:
        raise HTTPException(503, "the tag index was not built; rebuild to search tags")


# -------------------------------------------------------------------------------------------
# GET /api/findings
# -------------------------------------------------------------------------------------------


def _not_assessed_json(na: dict | None) -> dict | None:
    if na is None:
        return None
    return {"code": na["code"], "label": na["label"], "partial": na["partial"], "fix": na.get("fix"),
            "requires": na.get("requires"), "grants": na.get("grants") or [], "sources": na.get("sources") or [],
            "cause": na.get("reason")}


def _finding_json(r) -> dict:
    return {
        "query_id": r.query_id,
        "title": r.title,
        "domain": r.domain,
        "tier": r.tier,
        "stars": r.stars,
        "origin": r.origin,
        "is_finding": r.is_finding,
        "windowed": r.windowed,
        "window_days": r.window_days,
        "outcome": r.outcome,
        "row_count": r.row_count,
        "status_counts": r.status_counts,
        "has_account_id": r.has_account_id,
        "not_assessed_reason": r.not_assessed_reason,
        # True when the export ran the window but not in full; never true together with
        # not_assessed_reason.
        "partial": r.partial,
        # None/[]/None (never true/false) unless `tag` was given.
        "tag_applied": r.tag_applied,
        "tag_chain": r.tag_chain,
        "tag_chain_label": r.tag_chain_label,
        # A trend/chargeback report never reads worse than WARN (app_materiality); null
        # for every other check. status_counts above already reflects the cap.
        "severity_cap": app_materiality.severity_cap(r.query_id),
        # null | {code, label, partial, fix, requires, grants, sources, cause}: the same vocabulary
        # /api/coverage's checks_not_ok names this same gap with; `requires` is the check's own access
        # line and `grants` the GRANT lines that open its sources.
        "not_assessed": _not_assessed_json(r.not_assessed),
        # null | {column, kind, usd, unit, basis, currency, mixed_currency, price_basis}: the findings
        # table's own money column; price_basis is where the $/credit came from (invoice | cli | settings |
        # unpriced | invoice_currency).
        "money": r.money,
        "money_reason": r.money_reason,
        "affected": r.affected,
        # null | {limited, note, billed, visible, unit}: the role sees only part of what this check lists.
        "visibility": r.visibility,
        # null | {source, reads, note}: read from INFORMATION_SCHEMA because the role cannot read ACCOUNT_USAGE.
        "source": r.source,
        # {warehouse, database, schema}: True applied, False asked for but this check has no such column
        # ("not filtered by warehouse"), None not asked.
        "dim_applied": r.dim_applied,
        "owner_applied": r.owner_applied,
        # null | {column, min, unit, label, rows_below}: rows the materiality floor moved to OK.
        "floor": r.floor,
    }


@app.get("/api/findings")
def get_findings(
    request: Request,
    window: int | None = Query(default=None),
    account_ids: list[str] = Depends(account_scope),
    env: list[str] = Query(default=[]),
    # Any spelling; the server normalises it. tag_value without tag_key is a 422
    # (_parse_tag_filter). Same contract as GET /api/finding's own tag_key/tag_value.
    tag_key: str | None = Query(default=None),
    tag_value: str | None = Query(default=None),
    # Several tag names (repeatable): "<key>" for All, "<key>:<value>" for one value -- same key
    # repeated ORs its values, a different key ANDs across names; merges with tag_key/tag_value.
    tag: list[str] = Query(default=[]),
    owner: str | None = Query(default=None),
    dims: "app_core_data.DimFilter | None" = Depends(dim_scope),
) -> dict:
    settings = app_config.load_settings()
    eff_window = _resolve_window(window, settings)
    # One query param per canonical key, the same _read_attribute_filters convention GET
    # /api/finding and its /aggregate twin use.
    attributes = _read_attribute_filters(request, _canonical_keys()) or None
    tag_filter = _parse_tag_filter(tag_key, tag_value, tag)
    rows = service.list_findings(
        eff_window, account_ids or None, env or None, attributes, tag=tag_filter, owner=owner, dims=dims,
    )
    return {
        "window_days": eff_window,
        "account_ids": account_ids,
        "env": env,
        "attributes": attributes or {},
        "tag": _tag_json(tag_filter),
        "dims": _dims_json(dims),
        "count": len(rows),
        # THE checks-that-ran count: the same on every page (see /api/meta checks.ran).
        "checks_ran": app_core_data.checks_ran_summary(),
        "price_basis": app_core_data.price_basis(),
        "discount": app_core_data.discount_info(settings["discount_pct"]),
        "findings": [_finding_json(r) for r in rows],
    }


# -------------------------------------------------------------------------------------------
# GET /api/fix-first: what to do first. Priced findings (by $), and CRITICAL findings with no $ figure
# (an admin without MFA), in labelled groups that are never added together.
# -------------------------------------------------------------------------------------------


@app.get("/api/fix-first")
def get_fix_first(
    request: Request,
    window: int | None = Query(default=None),
    limit: int = Query(default=10, ge=1, le=1000),
    account_ids: list[str] = Depends(account_scope),
    env: list[str] = Query(default=[]),
    tag_key: str | None = Query(default=None),
    tag_value: str | None = Query(default=None),
    tag: list[str] = Query(default=[]),
    owner: str | None = Query(default=None),
    dims: "app_core_data.DimFilter | None" = Depends(dim_scope),
) -> dict:
    settings = app_config.load_settings()
    eff_window = _resolve_window(window, settings)
    attributes = _read_attribute_filters(request, _canonical_keys()) or None
    tag_filter = _parse_tag_filter(tag_key, tag_value, tag)
    rows = service.list_findings(
        eff_window, account_ids or None, env or None, attributes, tag=tag_filter, owner=owner, dims=dims,
    )
    body = service.fix_first(rows, limit)
    body.update({"window_days": eff_window, "price_basis": app_core_data.price_basis(),
                 "discount": app_core_data.discount_info(settings["discount_pct"])})
    return body


# -------------------------------------------------------------------------------------------
# GET /api/finding/{query_id}
# -------------------------------------------------------------------------------------------


def _clean_header_prose(fields: dict) -> dict:
    """Internal ticket and commit ids never reach the screen; the header text is otherwise as written."""
    out = dict(fields)
    for key in ("read_this", "healthy", "investigate_if"):
        if out.get(key):
            out[key] = guide_api._clean_prose(out[key])  # noqa: SLF001
    out["actions"] = [guide_api._clean_prose(a) for a in out.get("actions") or []]  # noqa: SLF001
    return out


@app.get("/api/finding/{query_id}")
def get_finding(
    request: Request,
    query_id: str,
    window: int | None = Query(default=None),
    account_ids: list[str] = Depends(account_scope),
    env: list[str] = Query(default=[]),
    limit: int = Query(default=200, ge=1, le=5000),
    offset: int = Query(default=0, ge=0, le=1_000_000),
    # The task focus filter: scopes a finding to one task server-side, on a finding that carries
    # task_full_name or job_id (ignored, never an error, on one that does not). Matching in the
    # browser would read a task past the page's row cap as "not flagged".
    job_id: str | None = Query(default=None),
    # Scopes a finding to only these status values server-side, on a finding that carries a status
    # column (same unaffected-if-absent contract), so a tile that needs only flagged rows does not
    # filter a capped page in the browser and silently drop flagged rows past the cap.
    status: list[str] = Query(default=[]),
    # Any spelling; the server normalises it. tag_value without tag_key is a 422
    # (_parse_tag_filter); absent tag_value means "any value of this key".
    tag_key: str | None = Query(default=None),
    tag_value: str | None = Query(default=None),
    # Several tag names (repeatable): "<key>" for All, "<key>:<value>" for one value -- same key
    # repeated ORs its values, a different key ANDs across names; merges with tag_key/tag_value.
    tag: list[str] = Query(default=[]),
    owner: str | None = Query(default=None),
    dims: "app_core_data.DimFilter | None" = Depends(dim_scope),
) -> dict:
    settings = app_config.load_settings()
    requested_window = _resolve_window(window, settings)
    _validate_statuses(status)
    # One query param per canonical key (e.g. ?cost_center=engineering&cost_center=sales), read by
    # name since the key set is config-driven. Applies only on a finding that carries account_id.
    attributes = _read_attribute_filters(request, _canonical_keys()) or None
    tag_filter = _parse_tag_filter(tag_key, tag_value, tag)

    try:
        outcome = service.load_outcome(
            query_id, requested_window, account_ids or None, env or None,
            limit=offset + limit, attributes=attributes, job_id=job_id, statuses=status or None,
            tag=tag_filter, owner=owner, dims=dims,
        )
    except service.QueryNotFoundError:
        raise HTTPException(404, f"unknown query_id: {query_id!r}")

    spec = outcome.spec
    body: dict = {
        "query_id": query_id,
        "outcome": outcome.outcome,
        "window_days": outcome.window_days,
        "requested_window_days": requested_window,
        "is_finding": spec.is_finding,
        "windowed": spec.windowed,
        "attributes": attributes or {},
        "tag": _tag_json(tag_filter),
        "dims": _dims_json(dims),
        "scope": outcome.scope,
        "status": status,
        "header": {
            "title": spec.title,
            "domain": spec.domain,
            "tier": spec.tier,
            "stars": spec.stars,
            "origin": spec.origin,
            "confidence": spec.confidence,
            "confidence_note": spec.confidence_note,
            # read_this/healthy/investigate_if/actions/not_assessed_reasons carry every :param
            # token replaced by the value in effect, plus its source (see
            # service.substitute_header_params). outcome.window_days is the EFFECTIVE window
            # (7/30/90, 0 for a point-in-time spec), so :period_days reads the window on screen.
            **_clean_header_prose(service.substitute_header_params(spec, outcome.window_days)),
            "next": spec.next,
            "caveats": guide_api._clean_prose(spec.caveats) or spec.caveats,
            "empty_if": spec.empty_if,
        },
    }

    if outcome.outcome == service.OUTCOME_NOT_ASSESSED:
        body["status_info"] = outcome.status_info
        return body

    if outcome.outcome == service.OUTCOME_ERROR:
        body["error"] = outcome.error
        return body

    if outcome.outcome == service.OUTCOME_OK_EMPTY_WINDOW:
        body["window_coverage"] = outcome.window_coverage
        return body

    if outcome.outcome == service.OUTCOME_OK_EMPTY_FILTERS:
        body["rows_in_window"] = outcome.rows_in_window
        # Tells a real "not flagged" from a task this query's own :top_n row cap may have cut
        # before the task filter ever saw it.
        body["row_cap"] = service.row_cap(query_id)
        # A filter can read as "nothing matches" purely because every candidate row had no
        # resolvable account: this is what tells the two cases apart.
        body["excluded_no_account"] = (
            {"rows": outcome.excluded_no_account["rows"], "value": None}
            if outcome.excluded_no_account is not None else None
        )
        return body

    # OUTCOME_OK_ROWS: apply the list-price discount before a table is rendered or downloaded, then
    # page the already-capped frame in Python (never a second SQL OFFSET: the API layer builds no
    # SQL of its own).
    discount = app_core_data.discount_info(settings["discount_pct"])
    df = app_pricing.apply(outcome.df, discount["effective"])
    page_df = df.iloc[offset : offset + limit]
    kinds = service.classify_columns(list(df.columns), discount["effective"])
    # Materiality floor (config/materiality.yml): app/core/data.read_finding already selected the
    # EFFECTIVE status as "status" (raw kept as status_raw) and a real "below_floor" column; both
    # land in `rows` below like any other column.
    rows = service.records(page_df, kinds)
    body.update(
        {
            "rows_total": outcome.rows_total,
            "rows_in_window": outcome.rows_in_window,
            "limit": limit,
            "offset": offset,
            "returned": len(page_df),
            "columns": [{"name": c, **kinds[c]} for c in df.columns],
            "rows": rows,
            # {"column","min","unit","label","rows_below"} or None: rows_below is out of rows_total
            # above, not just this page.
            "floor": service.floor_json(query_id, list(df.columns), outcome.rows_below_floor),
            # null when no account/env/attribute filter applies (or the check is not account-
            # filterable), else {rows, value}: rows the filter left out for having no resolvable
            # account; value is always null here (no aggregation on this endpoint).
            "excluded_no_account": (
                {"rows": outcome.excluded_no_account["rows"], "value": None}
                if outcome.excluded_no_account is not None else None
            ),
            "discount_pct": discount["effective"],
            "discount": discount,
            "price_basis": app_core_data.price_basis(),
            # The same row_cap the ok_empty_filters branch above carries.
            "row_cap": service.row_cap(query_id),
            # A finding WITH rows still needs to say whether the export reaches back far enough to
            # fill the window it is labelled with: 7 days of rows under a "30d" heading is the quiet
            # failure this field exists to prevent.
            "window_coverage": outcome.window_coverage,
            # The export's own row cap (app.core.data.truncation_info).
            "truncated": (outcome.status_info or {}).get("truncated", False),
            "truncated_max_rows": (outcome.status_info or {}).get("max_rows"),
        }
    )
    return body


# -------------------------------------------------------------------------------------------
# GET /api/finding/{query_id}/aggregate: a server-side GROUP BY/SUM over EVERY row matching the
# filters, so a tile or chart no longer sums the (capped) page a plain /api/finding fetch returns.
# Same four-outcome shape as GET /api/finding, an OK_ROWS body carrying `groups`/`other`/
# `total_value` instead of `rows`.
# -------------------------------------------------------------------------------------------


@app.get("/api/finding/{query_id}/aggregate")
def get_finding_aggregate(
    request: Request,
    query_id: str,
    window: int | None = Query(default=None),
    account_ids: list[str] = Depends(account_scope),
    env: list[str] = Query(default=[]),
    # 0-3 real column names on the finding table (app/core/data.aggregate_finding's own
    # _MAX_GROUP_COLS whitelist-before-splice check -- a bad name raises ValueError -> 422 below).
    group: list[str] = Query(default=[]),
    agg: str = Query(default="sum"),
    value: str | None = Query(default=None),
    status: list[str] = Query(default=[]),
    top: int | None = Query(default=None, ge=1, le=10_000),
    tag_key: str | None = Query(default=None),
    tag_value: str | None = Query(default=None),
    # Several tag names (repeatable): "<key>" for All, "<key>:<value>" for one value -- same key
    # repeated ORs its values, a different key ANDs across names; merges with tag_key/tag_value.
    tag: list[str] = Query(default=[]),
    # Sums only the rows this check's materiality floor moved from CRITICAL/WARN to OK: how much
    # the floor hid. A check with no floor then matches nothing.
    below_floor: bool = Query(default=False),
    owner: str | None = Query(default=None),
    # true keeps the rows a check marks is_total_row (default: left out, like the tile's figure).
    include_totals: bool = Query(default=False),
    dims: "app_core_data.DimFilter | None" = Depends(dim_scope),
    # More columns summed per group, and columns read from each group's largest row, so a chart
    # needs one aggregate call instead of every row.
    also: list[str] = Query(default=[]),
    pick: list[str] = Query(default=[]),
) -> dict:
    settings = app_config.load_settings()
    requested_window = _resolve_window(window, settings)
    _validate_statuses(status)
    attributes = _read_attribute_filters(request, _canonical_keys()) or None
    tag_filter = _parse_tag_filter(tag_key, tag_value, tag)
    filters = dict(
        account_ids=account_ids or None, env=env or None, attributes=attributes,
        statuses=status or None, below_floor=below_floor, owner=owner,
        include_totals=include_totals, dims=dims,
    )

    try:
        if also or pick:
            # A cheap count settles the outcome; the real aggregate then carries the extra columns.
            outcome = service.load_aggregate(query_id, requested_window, [], "count", None, tag=tag_filter, **filters)
            if outcome.outcome == service.OUTCOME_OK_ROWS:
                outcome = _aggregate_with_extras(outcome, query_id, group, agg, value, top, tag_filter, also, pick, filters)
        else:
            outcome = service.load_aggregate(
                query_id, requested_window, group, agg, value, top=top, tag=tag_filter, **filters,
            )
    except service.QueryNotFoundError:
        raise HTTPException(404, f"unknown query_id: {query_id!r}")
    except ValueError as exc:
        raise HTTPException(422, str(exc))

    body: dict = {
        "query_id": query_id,
        "outcome": outcome.outcome,
        "window_days": outcome.window_days,
        "requested_window_days": requested_window,
        "group": group,
        "agg": agg,
        "value": value,
        "status": status,
        "tag": _tag_json(tag_filter),
        "scope": outcome.scope,
    }

    if outcome.outcome == service.OUTCOME_NOT_ASSESSED:
        body["status_info"] = outcome.status_info
        return body

    if outcome.outcome == service.OUTCOME_ERROR:
        body["error"] = outcome.error
        return body

    if outcome.outcome == service.OUTCOME_OK_EMPTY_WINDOW:
        body["window_coverage"] = outcome.window_coverage
        return body

    if outcome.outcome == service.OUTCOME_OK_EMPTY_FILTERS:
        body["rows_in_window"] = outcome.rows_in_window
        body["excluded_no_account"] = (
            {"rows": outcome.excluded_no_account["rows"], "value": None}
            if outcome.excluded_no_account is not None else None
        )
        return body

    # OUTCOME_OK_ROWS: groups/other/total_value are RAW (undiscounted), same as a plain /api/finding
    # row; `discount_pct` is returned alongside so a money-column caller applies (1 - discount_pct)
    # itself, exactly as it does for a row page.
    body.update(
        {
            "groups": [_group_json(group, g) for g in outcome.groups],
            "other": _group_json(group, outcome.other) if outcome.other else None,
            "total_value": service._json_scalar(outcome.total_value),
            "group_count": outcome.group_count,
            "rows_total": outcome.rows_total,
            "matched_rows": outcome.matched_rows,
            "floor": (
                {
                    "min": outcome.floor.min, "unit": outcome.floor.unit,
                    "label": outcome.floor.label, "per_days": 30,
                }
                if outcome.floor is not None else None
            ),
            # null when no account/env/attribute filter applies (or the check is not account-
            # filterable), else {rows, value}: rows this filter left out for having no resolvable
            # account, and the same agg over them.
            "excluded_no_account": (
                {
                    "rows": outcome.excluded_no_account["rows"],
                    "value": service._json_scalar(outcome.excluded_no_account["value"]),
                }
                if outcome.excluded_no_account is not None else None
            ),
            # How many of matched_rows never entered total_value at all (agg="sum" only, 0
            # otherwise); see app_core_data.AggregateResult's own docstring.
            "null_value_rows": outcome.null_value_rows,
            "rows_in_window": outcome.rows_in_window,
            "discount_pct": app_core_data.effective_discount_pct(settings["discount_pct"]),
            "discount": app_core_data.discount_info(settings["discount_pct"]),
            "price_basis": app_core_data.price_basis(),
            "window_coverage": outcome.window_coverage,
            # The export's own row cap: the aggregate only ever summed the rows that made it into
            # the finding table, so a tile must label this a lower bound.
            "truncated": (outcome.status_info or {}).get("truncated", False),
            "truncated_max_rows": (outcome.status_info or {}).get("max_rows"),
        }
    )
    return body


def _aggregate_with_extras(outcome, query_id, group, agg, value, top, tag_filter, also, pick, filters):
    """Re-run the aggregate with `also`/`pick` columns on an outcome that already reads ok_rows."""
    try:
        res = app_core_data.aggregate_finding(
            query_id, outcome.window_days, group, agg, value, top=top, tag_filter=tag_filter,
            also=also, pick=pick, **filters,
        )
    except (duckdb.Error, OSError) as exc:
        return dataclasses.replace(outcome, outcome=service.OUTCOME_ERROR, error=str(exc))
    return dataclasses.replace(
        outcome, groups=res.groups, other=res.other, total_value=res.total_value,
        group_count=res.group_count, rows_total=res.rows_total, matched_rows=res.matched_rows,
        null_value_rows=res.null_value_rows, floor=res.floor, excluded_no_account=res.excluded_no_account,
    )


def _group_json(group: list[str], g) -> dict:
    """service.aggregate_group_json plus the group's `also` sums and `pick` values (masked like a key)."""
    out = service.aggregate_group_json(group, g)
    if getattr(g, "also", None) is not None:
        out["also"] = {c: service._json_scalar(v) for c, v in g.also.items()}
    if getattr(g, "pick", None) is not None:
        cols = list(g.pick)
        vals = app_identity.mask_group_key(cols, [service._json_scalar(v) for v in g.pick.values()])
        out["pick"] = dict(zip(cols, vals))
    return out


# -------------------------------------------------------------------------------------------
# GET /api/finding/{query_id}/rows.csv: every row of one check, the filters applied, masking applied.
# -------------------------------------------------------------------------------------------

CSV_MAX_ROWS = 1_000_000


@app.get("/api/finding/{query_id}/rows.csv")
def get_finding_rows_csv(
    request: Request,
    query_id: str,
    window: int | None = Query(default=None),
    account_ids: list[str] = Depends(account_scope),
    env: list[str] = Query(default=[]),
    job_id: str | None = Query(default=None),
    status: list[str] = Query(default=[]),
    tag_key: str | None = Query(default=None),
    tag_value: str | None = Query(default=None),
    tag: list[str] = Query(default=[]),
    owner: str | None = Query(default=None),
    dims: "app_core_data.DimFilter | None" = Depends(dim_scope),
) -> Response:
    settings = app_config.load_settings()
    requested_window = _resolve_window(window, settings)
    _validate_statuses(status)
    attributes = _read_attribute_filters(request, _canonical_keys()) or None
    tag_filter = _parse_tag_filter(tag_key, tag_value, tag)
    try:
        outcome = service.load_outcome(
            query_id, requested_window, account_ids or None, env or None, limit=CSV_MAX_ROWS,
            attributes=attributes, job_id=job_id, statuses=status or None, tag=tag_filter, owner=owner, dims=dims,
        )
    except service.QueryNotFoundError:
        raise HTTPException(404, f"unknown query_id: {query_id!r}")
    if outcome.outcome == service.OUTCOME_NOT_ASSESSED:
        info = outcome.status_info or {}
        raise HTTPException(409, f"{query_id} was not assessed: "
                                 f"{info.get('not_built_reason') or info.get('message') or 'see Coverage'}")
    if outcome.outcome == service.OUTCOME_ERROR:
        raise HTTPException(500, outcome.error or "the data file could not be read")
    if outcome.outcome == service.OUTCOME_OK_ROWS:
        discount = app_core_data.effective_discount_pct(settings["discount_pct"])
        text = service.rows_csv(outcome, discount)
        returned = len(outcome.df)
    else:
        # Nothing matches: the header row only, so the file still says which columns the check has.
        text = ",".join(app_core_data.finding_columns(query_id)) + "\n"
        returned = 0
    return Response(
        content=text, media_type="text/csv; charset=utf-8",
        headers={"Content-Disposition": f'attachment; filename="{query_id}_{outcome.window_days}d.csv"',
                 "X-Rows": str(returned), "X-Rows-Matching": str(outcome.rows_total),
                 "X-Truncated": "true" if outcome.rows_total > returned else "false"},
    )


# -------------------------------------------------------------------------------------------
# GET /api/warehouses, /api/databases: the pickers for the warehouse and database(+schema) filters.
# -------------------------------------------------------------------------------------------


def _placeholder(name) -> bool:
    return not name or str(name).startswith("(")


@app.get("/api/warehouses")
def get_warehouses(account_ids: list[str] = Depends(account_scope)) -> dict:
    """Every warehouse the export knows, as `name (id)`: the ones SHOW WAREHOUSES listed, plus any that
    billed but the role cannot see (source "billing": they still filter checks that name them)."""
    try:
        con = app_core_data._connect()
    except duckdb.Error as exc:
        raise HTTPException(503, f"the data file could not be read: {exc}")
    try:
        found: dict[str, dict] = {}
        try:
            for aid, wid, name in con.execute(
                    "SELECT account_id, warehouse_id, warehouse_name FROM dims.dim_warehouse ORDER BY warehouse_name"
            ).fetchall():
                if account_ids and str(aid) not in account_ids:
                    continue
                found[str(name).lower()] = {"account_id": str(aid), "warehouse_id": None if wid is None else str(wid),
                                            "warehouse_name": name, "source": "listed"}
        except duckdb.Error:
            pass
        try:
            for aid, wid, name in con.execute(
                    "SELECT DISTINCT account_id, warehouse_id, warehouse_name "
                    "FROM findings.f_sf_cost_warehouse_idle_credits_daily WHERE warehouse_name IS NOT NULL").fetchall():
                if account_ids and str(aid) not in account_ids:
                    continue
                found.setdefault(str(name).lower(), {
                    "account_id": str(aid), "warehouse_id": None if wid is None else str(wid),
                    "warehouse_name": name, "source": "billing"})
        except duckdb.Error:
            pass
    finally:
        con.close()
    rows = sorted(found.values(), key=lambda r: r["warehouse_name"].lower())
    for r in rows:
        r["label"] = f"{r['warehouse_name']} ({r['warehouse_id']})" if r["warehouse_id"] else r["warehouse_name"]
    return {"count": len(rows), "unit": "warehouses", "warehouses": rows}


# Findings that list databases and schemas, and the columns to read: (table, database, schema, database id).
_DATABASE_SOURCES = (
    ("f_sf_chg_by_database_schema", "database_name", "schema_name", "database_id"),
    ("f_sf_storage_schema_sprawl", "database_name", "schema_name", "database_id"),
    ("f_table_inventory_type", "table_catalog", "table_schema", None),
)


@app.get("/api/databases")
def get_databases() -> dict:
    """Every database (with its schemas) the export names, as `name (id)` where the id is known. The
    schema value to filter by is `fqn` (DATABASE.SCHEMA)."""
    try:
        con = app_core_data._connect()
    except duckdb.Error as exc:
        raise HTTPException(503, f"the data file could not be read: {exc}")
    dbs: dict[str, dict] = {}

    def add(db, schema, db_id=None) -> None:
        if _placeholder(db):
            return
        entry = dbs.setdefault(str(db).lower(), {"database_name": db, "database_id": None, "schemas": {}})
        if db_id is not None and entry["database_id"] is None:
            entry["database_id"] = str(db_id)
        if not _placeholder(schema):
            entry["schemas"].setdefault(str(schema).lower(), {"schema_name": schema, "fqn": f"{db}.{schema}"})

    try:
        for table, db_col, sch_col, id_col in _DATABASE_SOURCES:
            try:
                id_sql = f', "{id_col}"' if id_col else ", NULL"
                for row in con.execute(
                        f'SELECT DISTINCT "{db_col}", "{sch_col}"{id_sql} FROM findings."{table}"').fetchall():
                    add(row[0], row[1], row[2])
            except duckdb.Error:
                continue
        try:
            for db, sch in con.execute("SELECT DISTINCT database_name, schema_name FROM dims.dim_task").fetchall():
                add(db, sch)
        except duckdb.Error:
            pass
    finally:
        con.close()
    out = []
    for key in sorted(dbs):
        d = dbs[key]
        out.append({"database_name": d["database_name"], "database_id": d["database_id"],
                    "label": f"{d['database_name']} ({d['database_id']})" if d["database_id"] else d["database_name"],
                    "schemas": [d["schemas"][k] for k in sorted(d["schemas"])]})
    return {"count": len(out), "unit": "databases", "databases": out}


# -------------------------------------------------------------------------------------------
# GET /api/tags/compliance
# -------------------------------------------------------------------------------------------


@app.get("/api/tags/compliance")
def get_tags_compliance(
    window: int | None = Query(default=None),
    # Raw tag names (repeatable) to check instead of the settings' required_tag_keys.
    keys: list[str] = Query(default=[]),
    account_ids: list[str] = Depends(account_scope),
) -> dict:
    settings = app_config.load_settings()
    eff_window = _resolve_window(window, settings)
    return app_tag_compliance.compliance(eff_window, keys or None, account_ids or None)


# -------------------------------------------------------------------------------------------
# Static front end -- mounted LAST so it never shadows an /api/* route above.
# -------------------------------------------------------------------------------------------

class _WebFiles(StaticFiles):
    """The built front end. index.html is never cached (it names the hashed bundles, which can be);
    a path that is not a file and not /api/* gets index.html, so a reload on any page works."""

    async def get_response(self, path, scope):
        # StaticFiles hands over an OS path (backslashes on Windows).
        parts = path.replace("\\", "/").split("/")
        # /api/* and missing files (a name with an extension) keep their 404; a page path gets index.html.
        keep_404 = parts[0] == "api" or "." in parts[-1]
        try:
            resp = await super().get_response(path, scope)
        except StarletteHTTPException as exc:
            if exc.status_code != 404 or keep_404:
                raise
            resp = await super().get_response("index.html", scope)
        else:
            if resp.status_code == 404 and not keep_404:
                resp = await super().get_response("index.html", scope)
        if "text/html" in resp.headers.get("content-type", ""):
            return _branded_index()
        return resp


def _branded_index() -> Response:
    """index.html with the settings brand in <title> and window.APP_BRAND, so the first paint
    already reads it. Never cached: it names the hashed bundles."""
    try:
        name = str((app_config.load_settings().get("brand") or {}).get("name") or "Crosshire")
    except Exception:  # noqa: BLE001 -- a broken settings file still serves the page
        name = "Crosshire"
    text = (WEB_DIR / "index.html").read_text(encoding="utf-8")
    text = text.replace("<title>Crosshire</title>", f"<title>{html.escape(name)}</title>", 1)
    # Every < is escaped so a brand name can never close the script tag or open a comment in it.
    value = json.dumps(name).replace("<", "\\u003c")
    text = text.replace("</head>", f"  <script>window.APP_BRAND = {value};</script>\n</head>", 1)
    return Response(text, media_type="text/html", headers={"Cache-Control": "no-cache"})


if WEB_DIR.exists():
    app.mount("/", _WebFiles(directory=str(WEB_DIR), html=True), name="web")
else:
    @app.get("/", include_in_schema=False)
    def _no_build() -> Response:
        return Response("The UI is not built. Run: cd web && npm ci && npm run build", status_code=404,
                        media_type="text/plain")
