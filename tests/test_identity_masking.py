"""masking_enabled() reads settings.yml's privacy.mask_user_identities (off by default); the export
and loader mask person columns only (tools/common.apply_masking) with identity.format_identity.
"""
from __future__ import annotations

import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from app.core import identity as app_identity  # noqa: E402


@pytest.fixture
def config_dir(tmp_path, monkeypatch):
    monkeypatch.setenv("AUDIT_CONFIG_DIR", str(tmp_path))
    return tmp_path


def test_masking_enabled_defaults_false(config_dir):
    assert app_identity.masking_enabled() is False


def test_masking_enabled_true_when_set(config_dir):
    (config_dir / "settings.yml").write_text("privacy:\n  mask_user_identities: true\n", encoding="utf-8")
    assert app_identity.masking_enabled() is True


def test_apply_masking_off_is_the_callers_choice_and_masks_person_columns_only():
    from tools.common import apply_masking
    import pyarrow as pa

    table = pa.table({"user_name": ["person@example.com"], "warehouse_name": ["WH_ONE"], "role_name": ["SYSADMIN"]})
    out = apply_masking(table).to_pydict()
    assert out["user_name"][0].endswith("***") and out["user_name"][0] != "person@example.com"
    assert out["warehouse_name"] == ["WH_ONE"] and out["role_name"] == ["SYSADMIN"]


def test_format_identity_is_stable_and_idempotent():
    once = app_identity.format_identity("person@example.com")
    assert once.endswith("pe***") and len(once.split(" ")[0]) == 8
    assert app_identity.format_identity(once) == once
    assert app_identity.format_identity(None) is None
    assert app_identity.format_identity("person@example.com", real_id="42") == "42 pe***"
