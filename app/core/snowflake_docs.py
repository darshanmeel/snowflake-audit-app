"""app/core/snowflake_docs.py -- loader for config/snowflake_docs.yml: the lookup table from a
Snowflake source (a view, a SHOW command or a function the checks read) to its docs.snowflake.com
page. Keys are "<schema>.<name>", e.g. "ACCOUNT_USAGE.QUERY_HISTORY" or "SHOW.WAREHOUSES".

Imports nothing from app.core.registry (the registry imports this module)."""
from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parent.parent.parent
_PATH = ROOT / "config" / "snowflake_docs.yml"
_HOST = "https://docs.snowflake.com/"


class DocsError(ValueError):
    """config/snowflake_docs.yml failed validation. Raised at load time, never swallowed."""


@dataclass(frozen=True)
class DocsEntry:
    key: str
    title: str
    url: str


def parse_docs(raw: object) -> dict[str, DocsEntry]:
    """An already yaml.safe_load()-ed mapping -> {key: DocsEntry}."""
    if not isinstance(raw, dict) or not isinstance(raw.get("sources"), list):
        raise DocsError("snowflake_docs.yml must be a mapping with a 'sources' list")
    out: dict[str, DocsEntry] = {}
    for item in raw["sources"]:
        if not isinstance(item, dict) or set(item) != {"key", "title", "url"}:
            raise DocsError(f"a sources entry needs exactly key, title, url: {item!r}")
        key, title, url = item["key"], item["title"], item["url"]
        if not all(isinstance(x, str) and x for x in (key, title, url)):
            raise DocsError(f"{key!r}: key, title and url must be non-empty strings")
        if not url.startswith(_HOST):
            raise DocsError(f"{key}: url must be on {_HOST}, got {url!r}")
        if key in out:
            raise DocsError(f"duplicate key: {key!r}")
        out[key] = DocsEntry(key=key, title=title, url=url)
    return out


_CACHE: tuple[tuple, dict[str, DocsEntry]] | None = None


def load_docs() -> dict[str, DocsEntry]:
    """config/snowflake_docs.yml, parsed and validated; cached on the file's (mtime_ns, size)."""
    global _CACHE
    st = _PATH.stat()
    key = (st.st_mtime_ns, st.st_size)
    if _CACHE is not None and _CACHE[0] == key:
        return _CACHE[1]
    try:
        raw = yaml.safe_load(_PATH.read_text(encoding="utf-8"))
    except yaml.YAMLError as exc:
        raise DocsError(f"config/snowflake_docs.yml is not valid YAML: {exc}") from None
    parsed = parse_docs(raw)
    _CACHE = (key, parsed)
    return parsed


def url_for(key: str) -> str:
    """The docs URL for "<schema>.<name>", or "" when the file has no entry for it."""
    entry = load_docs().get(key)
    return entry.url if entry else ""
