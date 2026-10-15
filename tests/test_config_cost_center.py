"""tests/test_config_cost_center.py -- config/settings.yml's cost_center_tag_keys (default
["cost_center"]) and its config/settings.local.yml override (app/core/config.py). Fully isolated
via a private tmp_path AUDIT_CONFIG_DIR -- never touches the shared session config dir tests/
conftest.py seeds, so these tests can run in any order relative to the rest of the suite.
"""
from __future__ import annotations

import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from app.core import config as app_config  # noqa: E402


@pytest.fixture
def cfg_dir(tmp_path, monkeypatch):
    monkeypatch.setenv("AUDIT_CONFIG_DIR", str(tmp_path))
    return tmp_path


def test_default_cost_center_tag_keys(cfg_dir):
    settings = app_config.load_settings()
    assert settings["cost_center_tag_keys"] == ["cost_center"]


def test_settings_yml_accepts_a_custom_list(cfg_dir):
    settings = app_config.load_settings()
    app_config.save_settings({**settings, "cost_center_tag_keys": ["made_up_key", "another_one"]})
    reloaded = app_config.load_settings()
    assert reloaded["cost_center_tag_keys"] == ["made_up_key", "another_one"]


@pytest.mark.parametrize("bad", [[], ["a", "b", "c", "d", "e", "f"], ["", "x"], [123], "cost_center"])
def test_settings_yml_rejects_bad_cost_center_tag_keys(cfg_dir, bad):
    settings = app_config.load_settings()
    with pytest.raises(app_config.ConfigError):
        app_config.save_settings({**settings, "cost_center_tag_keys": bad})


# -------------------------------------------------------------------------------------------
# config/settings.local.yml: the app writes user changes there, settings.yml stays untouched.
# -------------------------------------------------------------------------------------------


def test_save_settings_local_never_touches_settings_yml(cfg_dir):
    app_config.load_settings()  # seeds settings.yml
    before = (cfg_dir / "settings.yml").read_text(encoding="utf-8")

    effective = app_config.save_settings_local({"cost_center_tag_keys": ["made_up_key"]})

    assert effective["cost_center_tag_keys"] == ["made_up_key"]
    assert (cfg_dir / "settings.yml").read_text(encoding="utf-8") == before
    local_path = cfg_dir / "settings.local.yml"
    assert local_path.exists()
    assert "made_up_key" in local_path.read_text(encoding="utf-8")


def test_load_settings_merges_local_over_base(cfg_dir):
    app_config.save_settings_local({"cost_center_tag_keys": ["made_up_key"]})
    settings = app_config.load_settings()
    assert settings["cost_center_tag_keys"] == ["made_up_key"]
    # every other key still comes from the (untouched) base file's defaults
    assert settings["discount_pct"] == 0.0
    assert settings["default_window"] == 30


def test_save_settings_local_only_writes_the_keys_it_is_given(cfg_dir):
    app_config.save_settings_local({"cost_center_tag_keys": ["made_up_key"]})
    app_config.save_settings_local({"discount_pct": 0.1})
    local_raw = (cfg_dir / "settings.local.yml").read_text(encoding="utf-8")
    assert "made_up_key" in local_raw  # the first override survives the second, unrelated one
    settings = app_config.load_settings()
    assert settings["cost_center_tag_keys"] == ["made_up_key"]
    assert settings["discount_pct"] == 0.1


def test_save_settings_local_rejects_bad_values_without_writing(cfg_dir):
    app_config.load_settings()
    with pytest.raises(app_config.ConfigError):
        app_config.save_settings_local({"cost_center_tag_keys": []})
    assert not (cfg_dir / "settings.local.yml").exists()
