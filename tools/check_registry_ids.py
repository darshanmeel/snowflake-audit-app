#!/usr/bin/env python3
"""Fail when the UI registry and the check manifest disagree.

Every query_id in app/queries/manifest.json must sit in exactly one `ids`/`refIds` list of
web/src/components/tab_registry.tsx, every id there must be a real check, and every WASTE_ITEMS id
must be homed on a sub-tab. Exit 0 = in step.

    python tools/check_registry_ids.py
"""
from __future__ import annotations

import json
import re
import sys
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
REGISTRY = ROOT / "web" / "src" / "components" / "tab_registry.tsx"
MANIFEST = ROOT / "app" / "queries" / "manifest.json"

_LIST_RE = re.compile(r"\b(?:ids|refIds|[A-Z_]*_IDS)\s*[:=]\s*\[(?P<body>[^\]]*)\]")
_ID_RE = re.compile(r'"([a-z][a-z0-9_]*)"')


def manifest_ids() -> set[str]:
    data = json.loads(MANIFEST.read_text(encoding="utf-8"))
    return {e["query_id"] for entries in data.values() for e in entries}


def registry_ids(text: str) -> Counter:
    """Every id inside an ids/refIds/*_IDS list, outside the WASTE_ITEMS block."""
    text = re.sub(r"const WASTE_ITEMS(?::[^=]+)? = \[.*?\n\];", "", text, flags=re.DOTALL)
    counts: Counter = Counter()
    for m in _LIST_RE.finditer(text):
        counts.update(_ID_RE.findall(m.group("body")))
    return counts


def waste_ids(text: str) -> list[str]:
    m = re.search(r"const WASTE_ITEMS(?::[^=]+)? = \[(?P<body>.*?)\n\];", text, re.DOTALL)
    return re.findall(r'\{\s*id:\s*"([a-z0-9_]+)"', m.group("body")) if m else []


def main() -> int:
    text = REGISTRY.read_text(encoding="utf-8")
    want = manifest_ids()
    have = registry_ids(text)
    problems = []
    missing = sorted(want - set(have))
    extra = sorted(set(have) - want)
    dup = sorted(i for i, n in have.items() if n > 1)
    if missing:
        problems.append(f"in the manifest but not placed ({len(missing)}): {', '.join(missing)}")
    if extra:
        problems.append(f"placed but not a check ({len(extra)}): {', '.join(extra)}")
    if dup:
        problems.append(f"placed more than once ({len(dup)}): {', '.join(dup)}")
    unhomed = sorted(i for i in waste_ids(text) if i not in have)
    if unhomed:
        problems.append(f"WASTE_ITEMS ids with no home: {', '.join(unhomed)}")
    if problems:
        print("\n".join(problems))
        return 1
    print(f"registry ids == manifest ids ({len(want)} checks, each placed once; {len(waste_ids(text))} waste items)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
