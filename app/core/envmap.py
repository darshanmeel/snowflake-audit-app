"""app/core/envmap.py

Classifies an account name into prod / uat / dev / unknown with word lists from config/settings.yml
(`env_patterns`). Lower-case the name, collapse any run of `_`, `-`, `.` or `/` to one space, then
match whole words in the fixed order prod, uat, dev (first match wins). A None name, or one that
matches no list, is 'unknown': the env is never guessed from a partial match.

    load_env_patterns() -> dict[str, list[str]]   settings env_patterns, read fresh every call
    classify_env(name) -> str                     'prod' | 'uat' | 'dev' | 'unknown'
"""
from __future__ import annotations

import re
from typing import Optional

from app.core import config as app_config

_NORMALIZE_RE = re.compile(r"[-_./]+")
_BUCKET_ORDER = app_config.ENV_BUCKETS


def load_env_patterns() -> dict[str, list[str]]:
    return app_config.load_settings()["env_patterns"]


def _word_boundary_pattern(words: list[str]) -> "re.Pattern[str]":
    # re.ASCII keeps \b ASCII-only, so a non-ASCII letter next to a word never counts as a boundary.
    return re.compile(r"\b(" + "|".join(re.escape(w) for w in words) + r")\b", re.ASCII)


def classify_env(name: Optional[str], patterns: Optional[dict] = None) -> str:
    """'prod' | 'uat' | 'dev' | 'unknown' for `name`; pass `patterns` to skip re-reading settings."""
    if name is None:
        return "unknown"
    if patterns is None:
        patterns = load_env_patterns()
    normalized = _NORMALIZE_RE.sub(" ", name.lower())
    for bucket in _BUCKET_ORDER:
        words = patterns.get(bucket) or []
        if words and _word_boundary_pattern(words).search(normalized):
            return bucket
    return "unknown"
