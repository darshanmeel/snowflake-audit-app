"""app/core/config.py

YAML load/save for config/settings.yml (plus the untracked settings.local.yml the app writes),
config/thresholds.yml, config/tag_aliases.yml and config/materiality.yml. Every load/save re-reads
AUDIT_CONFIG_DIR from os.environ on every call, never caching it at import time, so tests can
point a whole session at a temporary config/ copy. Writes are atomic: a temp file in the same
directory, then os.replace().

  config/settings.yml:
    discount_pct: float in [0, 1)          # presentation-only
    default_window: int                    # one of 7, 30, 90
    include_today: bool                    # the export keeps today's partial day
    include_snowflake_tasks: bool          # task health checks keep Snowflake's own tasks
    ui: {max_rows, max_chart_categories}   # row cap per read; charts group the rest into "Other"
    tag_share_floor / tag_coverage_floor   # floors for the tag-attribute inference, in [0, 1]
    brand: {name, url, contact_name, contact_email}
    privacy: {mask_user_identities,        # masks user names and emails on screen
              mask_fields}                # kinds of names the export (and Refresh) masks; [] = none
    cost_center_tag_keys: list[str]        # 1-5 raw tag keys that mean "cost center"
    query_source: str | None               # the QUERY_TAG on this app's queries
    export_tag_keys: list[str] | None      # tag names the export keeps; None = all
    credit_price_usd / ai_credit_price_usd / storage_price_usd_tb_month: number > 0 | None
                                           # the export's price when the org billing view is unreadable
    required_tag_keys: list[str]           # tags every object should carry; [] = show tag coverage only
    env_patterns: {prod, uat, dev: [word]} # word lists that classify an account name into an env

  config/settings.local.yml: the keys the running app saved; merged over settings.yml.
  Unknown keys and wrong types raise SettingsError with `.key` and `.line` when known.

  config/tag_aliases.yml: {canonical: {cost_center|team|business_unit|domain: [raw key spellings]}}
  config/thresholds.yml: {<query_id>: {<param>: number}, _all: {<param>: number}} overrides of the
    check headers' own defaults.
  config/materiality.yml: {<query_id>: {column, min, unit, label}} floors applied at read time by
    app/core/materiality.py; query_id must resolve in app.core.registry.

Stdlib + pyyaml, plus a local import of app.core.registry inside materiality validation only.
"""
from __future__ import annotations

import copy

import os
import re
import tempfile
from pathlib import Path

import yaml

from app.core import masking as app_masking

ROOT = Path(__file__).resolve().parent.parent.parent


class ConfigError(ValueError):
    """A settings/thresholds/tag_aliases file (or an in-memory dict about to be saved) failed
    validation: an unknown key, a wrong type, or a value outside its allowed set."""


class SettingsError(ConfigError):
    """config/settings.yml specifically failed to load -- either it is not valid YAML at all, or
    it parsed but failed _validate_settings. A subclass of ConfigError (every existing `except
    app_config.ConfigError` elsewhere in the app still catches this unchanged) that additionally
    carries, when known:
      key   the offending top-level key ("discount_pct"), or a dotted "ui.max_rows" path for one
            nested under `ui:`. None for a whole-document problem (e.g. settings.yml is a list,
            not a mapping).
      line  the 1-indexed line it appears on in the raw file. Set directly by load_settings() for
            a YAML syntax error (PyYAML's own parser already knows the position); derived from
            `key` via _find_key_line() for a semantic error (_validate_settings works off the
            already-parsed dict and has no text position of its own).
    GET /api/status reads both so app/web's shell can say exactly what to fix instead
    of just "config/settings.yml is invalid"."""

    def __init__(self, message: str, key: str | None = None, line: int | None = None):
        super().__init__(message)
        self.key = key
        self.line = line


# ---------------------------------------------------------------------------------------------
# Shared helpers
# ---------------------------------------------------------------------------------------------


def _config_dir() -> Path:
    env = os.environ.get("AUDIT_CONFIG_DIR")
    return Path(env) if env else ROOT / "config"


def materiality_path() -> Path:
    """config/materiality.yml's own path (under AUDIT_CONFIG_DIR) -- exposed so app/core/materiality
    can cache floors against this file's (mtime, size) without duplicating _config_dir()'s env
    lookup."""
    return _config_dir() / "materiality.yml"


def _atomic_write_yaml(path: Path, data: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_name = tempfile.mkstemp(dir=str(path.parent), prefix=f".{path.name}.", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as fh:
            yaml.safe_dump(data, fh, default_flow_style=False, sort_keys=False)
        os.replace(tmp_name, path)
    except Exception:
        if os.path.exists(tmp_name):
            os.remove(tmp_name)
        raise


def _is_number(value: object) -> bool:
    return isinstance(value, (int, float)) and not isinstance(value, bool)


# ---------------------------------------------------------------------------------------------
# settings.yml
# ---------------------------------------------------------------------------------------------

SETTINGS_KEYS = {
    "discount_pct", "default_window", "ui",
    "tag_share_floor",  # share floor for the tag-attribute inference
    "tag_coverage_floor",  # coverage floor for the same
    "brand",
    "privacy",
    "cost_center_tag_keys",  # which raw tag key(s) mean "cost center"
    "query_source",  # the QUERY_TAG on this app's queries
    "export_tag_keys",  # tag names the export keeps per object; None = all
    "include_today",  # export today's partial day too
    "include_snowflake_tasks",  # task health checks keep the SNOWFLAKE database's own tasks
    "credit_price_usd",  # USD per credit for the export when the org billing view is unreadable
    "ai_credit_price_usd",  # USD per AI credit, same
    "storage_price_usd_tb_month",  # USD per TB-month, same
    "required_tag_keys",  # tag names every object should carry (tag compliance)
    "env_patterns",  # word lists that classify an account name into prod / uat / dev
    "load",  # DuckDB memory and threads for the load and the app, and the app's response cache
}
ENV_BUCKETS = ("prod", "uat", "dev")
UI_KEYS = {"max_rows", "max_chart_categories"}
BRAND_KEYS = {"name", "url", "contact_name", "contact_email"}
PRIVACY_KEYS = {"mask_user_identities", "mask_fields"}
LOAD_KEYS = {"memory_limit", "threads", "response_cache_mb"}
WINDOW_CHOICES = (7, 30, 90)
COST_CENTER_KEYS_MIN, COST_CENTER_KEYS_MAX = 1, 5
REQUIRED_TAG_KEYS_MAX = 20

DEFAULT_SETTINGS: dict = {
    "discount_pct": 0.0,
    "default_window": 30,
    "ui": {"max_rows": 500, "max_chart_categories": 8},
    "tag_share_floor": 0.6,
    "tag_coverage_floor": 0.5,
    "brand": {
        "name": "Crosshire",
        "url": "https://crosshire.ch",
        "contact_name": "Darshan Singh",
        "contact_email": "",
    },
    "privacy": {"mask_user_identities": False, "mask_fields": []},
    "cost_center_tag_keys": ["cost_center"],
    "query_source": "crosshire-audit",
    "export_tag_keys": None,  # None = every tag
    "include_today": True,
    "include_snowflake_tasks": False,
    "credit_price_usd": None,
    "ai_credit_price_usd": None,
    "storage_price_usd_tb_month": None,
    "required_tag_keys": [],
    "env_patterns": {
        "prod": ["prod", "prd", "production", "live"],
        "uat": ["uat", "test", "qa", "stag", "staging", "stage", "sandbox", "sit", "nonprod", "preprod"],
        "dev": ["dev", "devel"],
    },
    "load": {"memory_limit": "1GB", "threads": 4, "response_cache_mb": 64},
}


def _find_key_line(text: str, key: str) -> int | None:
    """Best-effort 1-indexed line number of `key` in raw settings.yml `text`. config/settings.yml
    is flat -- `ui:`/`brand:` nest one level, no deeper -- so this is a plain per-line scan, not
    a real YAML-position lookup: a dotted "ui.max_rows" key is searched for only inside the
    `ui:` block; anything else is searched for at the top level. Returns None when the key's own
    line cannot be found -- display-only, never worth raising over."""
    if not isinstance(key, str):
        # _validate_settings always str()s `.key` before raising (see the sites above), so this
        # only guards a future/other SettingsError raiser that does not -- never worth raising
        # over here either, same as the "not found" case.
        return None
    top_key, _, sub_key = key.partition(".")
    lines = text.splitlines()
    if not sub_key:
        pattern = re.compile(rf"^{re.escape(top_key)}\s*:")
        for i, line in enumerate(lines):
            if pattern.match(line):
                return i + 1
        return None
    block_start = re.compile(rf"^{re.escape(top_key)}\s*:")
    sub_pattern = re.compile(rf"^\s+{re.escape(sub_key)}\s*:")
    in_block = False
    for i, line in enumerate(lines):
        if block_start.match(line):
            in_block = True
            continue
        if in_block:
            if line.strip() and not line[0].isspace():
                break  # left the block
            if sub_pattern.match(line):
                return i + 1
    return None


def _validate_settings(settings: dict) -> dict:
    if not isinstance(settings, dict):
        raise SettingsError("settings.yml must be a mapping")
    unknown = set(settings) - SETTINGS_KEYS
    if unknown:
        # YAML 1.1 reads some unquoted scalars (2, on, yes, ...) as int/bool, not str, so an
        # unknown key is not guaranteed to be a string -- str() every key before sorting (a mixed
        # int/str set raises TypeError from sorted() itself) and before using it as `.key`, which
        # _find_key_line() and every caller downstream (GET /api/status) assumes is a str.
        bad = sorted(str(k) for k in unknown)
        raise SettingsError(f"settings.yml has unknown key(s): {bad}", key=bad[0])
    out = dict(DEFAULT_SETTINGS)
    out.update(settings)
    if not _is_number(out["discount_pct"]) or not (0 <= out["discount_pct"] < 1):
        raise SettingsError("discount_pct must be a number in [0, 1)", key="discount_pct")
    patterns = out["env_patterns"]
    if not isinstance(patterns, dict) or set(patterns) - set(ENV_BUCKETS) or not all(
        isinstance(patterns.get(b, []), list) and all(isinstance(w, str) and w for w in patterns.get(b, []))
        for b in ENV_BUCKETS
    ):
        raise SettingsError("env_patterns must map prod, uat and dev to lists of words", key="env_patterns")
    # It is spliced into a SQL string literal and a connector user agent, so keep it plain.
    if out["query_source"] is not None and (
        not isinstance(out["query_source"], str) or not re.fullmatch(r"[A-Za-z0-9_-]{1,40}", out["query_source"])
    ):
        raise SettingsError("query_source must be 1-40 letters, digits, _ or -", key="query_source")
    keys = out["export_tag_keys"]
    if keys is not None and (
        not isinstance(keys, list) or not keys
        or not all(isinstance(k, str) and k.strip() and len(k) <= 128 for k in keys)
    ):
        raise SettingsError("export_tag_keys must be a list of tag names", key="export_tag_keys")
    for price_key in ("credit_price_usd", "ai_credit_price_usd", "storage_price_usd_tb_month"):
        if out[price_key] is not None and (not _is_number(out[price_key]) or out[price_key] <= 0):
            raise SettingsError(f"{price_key} must be a number above 0, or empty", key=price_key)
    required = out["required_tag_keys"]
    if required is None:
        required = []
    if (not isinstance(required, list) or len(required) > REQUIRED_TAG_KEYS_MAX
            or not all(isinstance(k, str) and k.strip() and len(k) <= 128 for k in required)):
        raise SettingsError(f"required_tag_keys must be a list of up to {REQUIRED_TAG_KEYS_MAX} tag names",
                            key="required_tag_keys")
    out["required_tag_keys"] = [k.strip() for k in required]
    if not isinstance(out["include_today"], bool):
        raise SettingsError("include_today must be true or false", key="include_today")
    if not isinstance(out["include_snowflake_tasks"], bool):
        raise SettingsError("include_snowflake_tasks must be true or false", key="include_snowflake_tasks")
    if out["default_window"] not in WINDOW_CHOICES:
        raise SettingsError(f"default_window must be one of {WINDOW_CHOICES}", key="default_window")
    if not _is_number(out["tag_share_floor"]) or not (0 <= out["tag_share_floor"] <= 1):
        raise SettingsError("tag_share_floor must be a number in [0, 1]", key="tag_share_floor")
    if not _is_number(out["tag_coverage_floor"]) or not (0 <= out["tag_coverage_floor"] <= 1):
        raise SettingsError("tag_coverage_floor must be a number in [0, 1]", key="tag_coverage_floor")
    ui = out["ui"]
    if not isinstance(ui, dict):
        raise SettingsError("ui must be a mapping", key="ui")
    unknown_ui = set(ui) - UI_KEYS
    if unknown_ui:
        bad_ui = sorted(str(k) for k in unknown_ui)
        raise SettingsError(f"ui has unknown key(s): {bad_ui}", key=f"ui.{bad_ui[0]}")
    merged_ui = dict(DEFAULT_SETTINGS["ui"])
    merged_ui.update(ui)
    for key in UI_KEYS:
        if not isinstance(merged_ui[key], int) or isinstance(merged_ui[key], bool) or merged_ui[key] <= 0:
            raise SettingsError(f"ui.{key} must be a positive integer", key=f"ui.{key}")
    out["ui"] = merged_ui
    brand = out["brand"]
    if brand is None:  # a bare `brand:` (all sub-keys commented out) means the defaults
        brand = {}
    if not isinstance(brand, dict):
        raise SettingsError("brand must be a mapping", key="brand")
    unknown_brand = set(brand) - BRAND_KEYS
    if unknown_brand:
        bad_brand = sorted(str(k) for k in unknown_brand)
        raise SettingsError(f"brand has unknown key(s): {bad_brand}", key=f"brand.{bad_brand[0]}")
    merged_brand = dict(DEFAULT_SETTINGS["brand"])
    merged_brand.update(brand)
    for key in BRAND_KEYS:
        if merged_brand[key] is None:  # a bare `contact_email:` in YAML means "none"
            merged_brand[key] = ""
        elif not isinstance(merged_brand[key], str):
            raise SettingsError(f"brand.{key} must be a string", key=f"brand.{key}")
    out["brand"] = merged_brand
    privacy = out["privacy"]
    if privacy is None:  # a bare `privacy:` means the defaults
        privacy = {}
    if not isinstance(privacy, dict):
        raise SettingsError("privacy must be a mapping", key="privacy")
    unknown_privacy = set(privacy) - PRIVACY_KEYS
    if unknown_privacy:
        bad_privacy = sorted(str(k) for k in unknown_privacy)
        raise SettingsError(f"privacy has unknown key(s): {bad_privacy}", key=f"privacy.{bad_privacy[0]}")
    merged_privacy = dict(DEFAULT_SETTINGS["privacy"])
    merged_privacy.update(privacy)
    if not isinstance(merged_privacy["mask_user_identities"], bool):
        raise SettingsError(
            "privacy.mask_user_identities must be true or false", key="privacy.mask_user_identities"
        )
    fields = merged_privacy["mask_fields"]
    if fields is None:
        fields = []
    if not isinstance(fields, list) or not all(isinstance(k, str) for k in fields):
        raise SettingsError("privacy.mask_fields must be a list of names", key="privacy.mask_fields")
    try:
        merged_privacy["mask_fields"] = app_masking.parse_kinds(fields)
    except ValueError as exc:
        raise SettingsError(f"privacy.mask_fields: {exc}", key="privacy.mask_fields") from exc
    out["privacy"] = merged_privacy
    cc_keys = out["cost_center_tag_keys"]
    if (
        not isinstance(cc_keys, list)
        or not (COST_CENTER_KEYS_MIN <= len(cc_keys) <= COST_CENTER_KEYS_MAX)
        or not all(isinstance(k, str) and k.strip() for k in cc_keys)
    ):
        raise SettingsError(
            f"cost_center_tag_keys must be a list of {COST_CENTER_KEYS_MIN}-{COST_CENTER_KEYS_MAX} "
            "non-empty strings",
            key="cost_center_tag_keys",
        )
    out["cost_center_tag_keys"] = list(cc_keys)
    load = out["load"]
    if load is None:  # a bare `load:` means the defaults
        load = {}
    if not isinstance(load, dict):
        raise SettingsError("load must be a mapping", key="load")
    unknown_load = set(load) - LOAD_KEYS
    if unknown_load:
        bad_load = sorted(str(k) for k in unknown_load)
        raise SettingsError(f"load has unknown key(s): {bad_load}", key=f"load.{bad_load[0]}")
    merged_load = dict(DEFAULT_SETTINGS["load"])
    merged_load.update(load)
    # Spliced into a SET statement, so only a plain size passes.
    mem = merged_load["memory_limit"]
    if not isinstance(mem, str) or not re.fullmatch(r"\d+(\.\d+)?\s*(MB|GB)", mem.strip(), re.I):
        raise SettingsError("load.memory_limit must be a size such as 1GB or 1500MB", key="load.memory_limit")
    merged_load["memory_limit"] = mem.strip().replace(" ", "")
    for key, low, top in (("threads", 1, 64), ("response_cache_mb", 0, 4096)):
        v = merged_load[key]
        if not isinstance(v, int) or isinstance(v, bool) or not (low <= v <= top):
            raise SettingsError(f"load.{key} must be a whole number from {low} to {top}", key=f"load.{key}")
    out["load"] = merged_load
    return out


LOCAL_SETTINGS_FILENAME = "settings.local.yml"


def _local_settings_path() -> Path:
    return _config_dir() / LOCAL_SETTINGS_FILENAME


def _load_local_settings() -> dict:
    """config/settings.local.yml (under AUDIT_CONFIG_DIR, gitignored): whichever top-level keys
    the app itself has saved there (save_settings_local) -- never seeded, {} when absent. Merged
    over settings.yml by load_settings so a setting the UI changes never touches the tracked
    settings.yml file."""
    path = _local_settings_path()
    if not path.exists():
        return {}
    try:
        raw = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
    except yaml.YAMLError as exc:
        raise SettingsError(f"settings.local.yml is not valid YAML: {exc}") from exc
    if not isinstance(raw, dict):
        raise SettingsError("settings.local.yml must be a mapping")
    return raw


_SETTINGS_CACHE: dict = {}


def load_settings() -> dict:
    """load_settings_uncached(), re-read only when settings.yml or settings.local.yml changes on disk
    (pages call it dozens of times per request). Returns a copy, so a caller can never edit the cache."""
    def _stamp(p: Path):
        try:
            st = p.stat()
            return (st.st_mtime_ns, st.st_size)
        except OSError:
            return None
    key = (str(_config_dir()), _stamp(_config_dir() / "settings.yml"), _stamp(_local_settings_path()))
    if _SETTINGS_CACHE.get("key") != key or key[1] is None:
        _SETTINGS_CACHE.clear()
        value = load_settings_uncached()
        key = (key[0], _stamp(_config_dir() / "settings.yml"), key[2])
        _SETTINGS_CACHE.update(key=key, value=value)
    return copy.deepcopy(_SETTINGS_CACHE["value"])


def load_settings_uncached() -> dict:
    """Load config/settings.yml (under AUDIT_CONFIG_DIR), then merge config/settings.local.yml's
    own keys on top (only the keys it sets -- everything else still comes from settings.yml).
    Seeds settings.yml with DEFAULT_SETTINGS the first time it is called with no file present --
    this is the one place on the whole board that creates settings.yml (no earlier task does).

    an invalid file raises SettingsError with `.key`/`.line` filled in wherever they
    can be determined -- a YAML syntax error carries PyYAML's own line (`problem_mark`); a
    semantic error (unknown key, wrong type) comes back from _validate_settings with `.key` set
    but `.line` still None until this function looks it up in the raw text via _find_key_line().
    GET /api/status is the one caller that reads `.key`/`.line`; every existing
    `except app_config.ConfigError` elsewhere still catches this unchanged (SettingsError is a
    ConfigError)."""
    path = _config_dir() / "settings.yml"
    if not path.exists():
        seeded = {
            **DEFAULT_SETTINGS,
            "ui": dict(DEFAULT_SETTINGS["ui"]),
            "brand": dict(DEFAULT_SETTINGS["brand"]),
            "privacy": dict(DEFAULT_SETTINGS["privacy"]),
            "load": dict(DEFAULT_SETTINGS["load"]),
        }
        save_settings(seeded)
        text = ""
        raw = dict(seeded)
    else:
        text = path.read_text(encoding="utf-8")
        try:
            raw = yaml.safe_load(text) or {}
        except yaml.YAMLError as exc:
            mark = getattr(exc, "problem_mark", None)
            line = (mark.line + 1) if mark is not None else None
            raise SettingsError(f"settings.yml is not valid YAML: {exc}", line=line) from exc

    merged = {**raw, **_load_local_settings()}
    try:
        return _validate_settings(merged)
    except SettingsError as exc:
        if exc.line is None and exc.key is not None:
            exc.line = _find_key_line(text, exc.key) if text else None
        raise


def save_settings(settings: dict) -> None:
    """Validate and atomically write settings to config/settings.yml (under AUDIT_CONFIG_DIR)."""
    _atomic_write_yaml(_config_dir() / "settings.yml", _validate_settings(settings))


def save_settings_local(overrides: dict) -> dict:
    """Merges `overrides` over the current local overrides, validates the RESULT against
    settings.yml's own values (so a bad override is rejected before anything is written), then
    atomically writes only the merged overrides to config/settings.local.yml -- settings.yml
    itself is never touched. Returns the new effective (merged) settings."""
    base_path = _config_dir() / "settings.yml"
    base_raw = yaml.safe_load(base_path.read_text(encoding="utf-8")) if base_path.exists() else {}
    new_local = {**_load_local_settings(), **overrides}
    effective = _validate_settings({**(base_raw or {}), **new_local})
    _atomic_write_yaml(_local_settings_path(), new_local)
    return effective


# ---------------------------------------------------------------------------------------------
# thresholds.yml
# ---------------------------------------------------------------------------------------------

DEFAULT_THRESHOLDS: dict = {}


def _validate_thresholds(thresholds: dict) -> dict:
    if not isinstance(thresholds, dict):
        raise ConfigError("thresholds.yml must be a mapping")
    for key, params in thresholds.items():
        if not isinstance(key, str):
            raise ConfigError("thresholds.yml top-level keys must be strings (query_id or '_all')")
        if not isinstance(params, dict):
            raise ConfigError(f"thresholds.yml[{key!r}] must be a mapping of param -> number")
        for pname, pval in params.items():
            if not isinstance(pname, str):
                raise ConfigError(f"thresholds.yml[{key!r}] has a non-string param name")
            if not _is_number(pval):
                raise ConfigError(f"thresholds.yml[{key!r}][{pname!r}] must be a number")
    return thresholds


def query_source() -> str:
    """The QUERY_TAG on this app's queries: settings query_source, else the default."""
    try:
        settings = load_settings()
    except ConfigError:
        settings = DEFAULT_SETTINGS
    return settings.get("query_source") or DEFAULT_SETTINGS["query_source"]


def load_thresholds() -> dict:
    """Load config/thresholds.yml (under AUDIT_CONFIG_DIR); an empty file is written the first time
    when none is present."""
    path = _config_dir() / "thresholds.yml"
    if not path.exists():
        seeded = {k: dict(v) for k, v in DEFAULT_THRESHOLDS.items()}
        save_thresholds(seeded)
        return seeded
    raw = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
    return _validate_thresholds(raw)


def save_thresholds(thresholds: dict) -> None:
    """Validate and atomically write thresholds to config/thresholds.yml (under
    AUDIT_CONFIG_DIR): exactly what it is given, once validated."""
    _atomic_write_yaml(_config_dir() / "thresholds.yml", _validate_thresholds(thresholds))


# ---------------------------------------------------------------------------------------------
# materiality.yml -- the per-check materiality-floor register (app/core/materiality.py applies
# these at read time). See config/materiality.yml's own header for which checks were left out and
# why (already gated in the query's own SQL, or a governance/existence signal that matters at any
# size).
# ---------------------------------------------------------------------------------------------

_MATERIALITY_FIELDS = {"column", "min", "unit", "label"}
_COLUMN_NAME_RE = re.compile(r"^[a-z][a-z0-9_]*$")

def _load_default_materiality() -> dict:
    """DEFAULT_MATERIALITY, read straight from the repo's OWN config/materiality.yml (ROOT/config,
    never AUDIT_CONFIG_DIR) instead of a second hand-copied dict -- so the seed used for a fresh
    AUDIT_CONFIG_DIR can never drift from the file that already ships in the repo."""
    path = ROOT / "config" / "materiality.yml"
    return yaml.safe_load(path.read_text(encoding="utf-8")) or {}


DEFAULT_MATERIALITY: dict = _load_default_materiality()


def _validate_materiality(data: dict) -> dict:
    if not isinstance(data, dict):
        raise ConfigError("materiality.yml must be a mapping of query_id -> floor")
    from app.core import registry  # local: keeps every OTHER function here free of this import

    known_ids = {s.query_id for s in registry.load_registry()}
    out: dict = {}
    for query_id, entry in data.items():
        if not isinstance(query_id, str) or not query_id:
            raise ConfigError(f"materiality.yml has a non-string or empty query_id key: {query_id!r}")
        if query_id not in known_ids:
            raise ConfigError(
                f"materiality.yml: query_id {query_id!r} is not in app.core.registry (unknown query id)"
            )
        if not isinstance(entry, dict):
            raise ConfigError(f"materiality.yml[{query_id!r}] must be a mapping")
        missing = _MATERIALITY_FIELDS - set(entry)
        if missing:
            raise ConfigError(
                f"materiality.yml[{query_id!r}] is missing field(s): {sorted(missing)}"
            )
        unknown = set(entry) - _MATERIALITY_FIELDS
        if unknown:
            raise ConfigError(
                f"materiality.yml[{query_id!r}] has unknown field(s): {sorted(unknown)}"
            )
        column = entry["column"]
        if not isinstance(column, str) or not _COLUMN_NAME_RE.match(column):
            raise ConfigError(
                f"materiality.yml[{query_id!r}]['column'] must be a lowercase_snake_case "
                f"column name, got {column!r}"
            )
        min_value = entry["min"]
        if not _is_number(min_value) or min_value <= 0:
            raise ConfigError(f"materiality.yml[{query_id!r}]['min'] must be a positive number")
        unit = entry["unit"]
        if not isinstance(unit, str) or not unit.strip():
            raise ConfigError(f"materiality.yml[{query_id!r}]['unit'] must be a non-empty string")
        label = entry["label"]
        if not isinstance(label, str) or not label.strip():
            raise ConfigError(f"materiality.yml[{query_id!r}]['label'] must be a non-empty string")
        out[query_id] = {"column": column, "min": min_value, "unit": unit, "label": label}
    return out


def load_materiality() -> dict:
    """Load config/materiality.yml (under AUDIT_CONFIG_DIR). Seeds the file with DEFAULT_MATERIALITY
    the first time it is called with no file present -- this module never removes or overwrites an
    existing file's contents on load, only on an explicit save_materiality() call."""
    path = materiality_path()
    if not path.exists():
        seeded = {k: dict(v) for k, v in DEFAULT_MATERIALITY.items()}
        save_materiality(seeded)
        return seeded
    raw = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
    return _validate_materiality(raw)


def save_materiality(data: dict) -> None:
    """Validate and atomically write floors to config/materiality.yml (under AUDIT_CONFIG_DIR)."""
    _atomic_write_yaml(materiality_path(), _validate_materiality(data))


# ---------------------------------------------------------------------------------------------
# tag_aliases.yml
# ---------------------------------------------------------------------------------------------

TAG_ALIAS_CANONICAL_KEYS = {"cost_center", "team", "business_unit", "domain"}


def _validate_tag_aliases(data: dict) -> dict:
    if not isinstance(data, dict) or set(data) != {"canonical"}:
        raise ConfigError("tag_aliases.yml must have exactly one top-level key: 'canonical'")
    canonical = data["canonical"]
    if not isinstance(canonical, dict):
        raise ConfigError("tag_aliases.yml['canonical'] must be a mapping")
    unknown = set(canonical) - TAG_ALIAS_CANONICAL_KEYS
    if unknown:
        raise ConfigError(f"tag_aliases.yml['canonical'] has unknown key(s): {sorted(unknown)}")
    out_canonical: dict = {}
    for key in TAG_ALIAS_CANONICAL_KEYS:
        values = canonical.get(key, [])
        if not isinstance(values, list) or not all(isinstance(v, str) for v in values):
            raise ConfigError(f"tag_aliases.yml['canonical'][{key!r}] must be a list of strings")
        out_canonical[key] = list(values)
    return {"canonical": out_canonical}


def load_tag_aliases() -> dict:
    """Load config/tag_aliases.yml (under AUDIT_CONFIG_DIR). Seeds with the empty-default
    shape (canonical: {cost_center: [], team: [], business_unit: []}) the first time it is called
    with no file present -- this is the one place on the whole board that creates this file."""
    path = _config_dir() / "tag_aliases.yml"
    if not path.exists():
        seeded = {"canonical": {k: [] for k in TAG_ALIAS_CANONICAL_KEYS}}
        save_tag_aliases(seeded)
        return seeded
    raw = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
    return _validate_tag_aliases(raw)


def save_tag_aliases(data: dict) -> None:
    """Validate and atomically write tag aliases to config/tag_aliases.yml (under
    AUDIT_CONFIG_DIR)."""
    _atomic_write_yaml(_config_dir() / "tag_aliases.yml", _validate_tag_aliases(data))
