"""tests/conftest.py

Session-scoped setup every test relies on:

  * The fake-account test DB (tests/db_audit_test.duckdb) is built once per session by
    tests/fixtures/build_fixtures.py; it is rebuilt only when one of its inputs changed.
  * AUDIT_DB points the app at it. The run-results sidecar sits next to it, written by the loader,
    so the deliberately failed checks read as failed.
  * AUDIT_CONFIG_DIR points at a session-scoped COPY of the repo's config/, so no test ever writes
    the repo's own config files.

Every test module gets this through the autouse session fixture below.
"""
from __future__ import annotations

import os
import shutil
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

DB_PATH = ROOT / "tests" / "db_audit_test.duckdb"

AS_OF = "2026-09-21T12:00:00"
AS_OF_DATE = "2026-09-21"


def _seed_config_dir(dest: Path) -> None:
    dest.mkdir(parents=True, exist_ok=True)
    src = ROOT / "config"
    for name in ("settings.yml", "thresholds.yml", "tag_aliases.yml", "materiality.yml", "snowflake_docs.yml"):
        source_path = src / name
        if source_path.exists():
            shutil.copy2(source_path, dest / name)


@pytest.fixture(scope="session", autouse=True)
def _app_env(tmp_path_factory: pytest.TempPathFactory):
    """Autouse so every test gets these env vars without asking; yields the paths for direct use."""
    from tests.fixtures import build_fixtures

    build_fixtures.build(DB_PATH)

    config_dir = tmp_path_factory.mktemp("audit_session") / "config"
    _seed_config_dir(config_dir)

    env_keys = ("AUDIT_DB", "AUDIT_CONFIG_DIR", "AUDIT_RUN_RESULTS", "AUDIT_DATA_DIR")
    previous = {key: os.environ.get(key) for key in env_keys}
    # No test reads or writes the real data/ folder.
    os.environ["AUDIT_DATA_DIR"] = str(config_dir.parent / "data")
    os.environ["AUDIT_DB"] = str(DB_PATH)
    os.environ["AUDIT_CONFIG_DIR"] = str(config_dir)
    os.environ.pop("AUDIT_RUN_RESULTS", None)
    try:
        yield {"db_path": DB_PATH, "config_dir": config_dir}
    finally:
        for key, value in previous.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value
