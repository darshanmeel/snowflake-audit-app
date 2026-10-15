#!/usr/bin/env python3
"""Print a fingerprint of the base fake account's rows: it must not change when demo code is added.

    python tools/fake_fingerprint.py
"""
from __future__ import annotations

import hashlib
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from tests.fake_snowflake import data  # noqa: E402


def fingerprint() -> str:
    world = data.World(data.NOW.date())
    h = hashlib.sha1()
    for key in sorted(world.rows):
        h.update(repr(key).encode())
        for row in world.rows[key]:
            h.update(repr(sorted(row.items())).encode())
    return h.hexdigest()


if __name__ == "__main__":
    print(fingerprint())
