"""settings `sources:`: SNOWFLAKE views read from the customer's own copies, in the export and the kit."""
from __future__ import annotations

import importlib.util
from pathlib import Path

import pytest

from app.core import config as app_config
from tools import export_results as ex

ROOT = Path(__file__).resolve().parent.parent
SQL = ("SELECT * FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY q JOIN snowflake.account_usage.tables t "
       "JOIN SNOWFLAKE.ORGANIZATION_USAGE.RATE_SHEET_DAILY r JOIN SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY_X x")


def _kit():
    spec = importlib.util.spec_from_file_location("kit_sources", ROOT / "tools" / "export_kit" / "run_export.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def test_a_view_line_wins_over_its_schema_and_other_schemas_stay():
    sources = app_config.parse_sources({"ACCOUNT_USAGE": "MY_DB.AU",
                                        "snowflake.account_usage.query_history": 'MY_DB.AUDIT."Q H"'})
    assert sources == {"ACCOUNT_USAGE": "MY_DB.AU", "ACCOUNT_USAGE.QUERY_HISTORY": 'MY_DB.AUDIT."Q H"'}
    out = app_config.apply_sources(SQL, sources)
    assert 'FROM MY_DB.AUDIT."Q H" q' in out and "MY_DB.AU.TABLES t" in out
    assert "SNOWFLAKE.ORGANIZATION_USAGE.RATE_SHEET_DAILY" in out
    assert "MY_DB.AU.QUERY_HISTORY_X" in out       # a longer name is its own view, not the mapped one
    assert app_config.apply_sources(SQL, None) == SQL


@pytest.mark.parametrize("raw", [
    {"ACCOUNT_USAGE": "A.B.C"},                     # a schema maps to db.schema
    {"ACCOUNT_USAGE.QUERY_HISTORY": "A.B"},         # a view maps to db.schema.view
    {"ACCOUNT_USAGE": "A.B; DROP TABLE X"},         # spliced into SQL: plain names only
    {"ACCOUNT USAGE": "A.B"},
    ["ACCOUNT_USAGE"],
])
def test_a_bad_mapping_is_refused(raw):
    with pytest.raises(ValueError):
        app_config.parse_sources(raw)


def test_settings_reject_a_bad_mapping_with_its_key():
    with pytest.raises(app_config.SettingsError) as err:
        app_config._validate_settings({**app_config.DEFAULT_SETTINGS, "sources": {"ACCOUNT_USAGE": "X"}})
    assert err.value.key == "sources"
    assert app_config._validate_settings(dict(app_config.DEFAULT_SETTINGS))["sources"] is None


def test_the_kit_swaps_the_same_way():
    kit = _kit()
    raw = {"ACCOUNT_USAGE": "MY_DB.AU", "ACCOUNT_USAGE.QUERY_HISTORY": "MY_DB.AUDIT.QH"}
    assert kit.parse_sources(raw) == app_config.parse_sources(raw)
    assert kit.apply_sources(SQL, kit.parse_sources(raw)) == app_config.apply_sources(SQL, app_config.parse_sources(raw))


def test_the_export_renders_checks_and_reads_prices_from_the_copies(monkeypatch):
    monkeypatch.setattr(ex, "_SOURCES", {"ACCOUNT_USAGE": "MY_DB.AU"})
    text = ex.load_checks()["sf_use_table_heaviest"]
    ctx = {"as_of_date": "2026-09-21", "account_id": "T", "cloud": "aws"}
    sql = ex.render(text, days=7, params=ex.params_for("sf_use_table_heaviest", {}), ctx=ctx)
    assert "SNOWFLAKE.ACCOUNT_USAGE" not in sql.upper()
    assert "MY_DB.AU.TABLE_QUERY_PRUNING_HISTORY" in sql and "MY_DB.AU.QUERY_HISTORY" in sql

    class Cur:
        description = []

        def execute(self, sql):
            self.sql = sql

        def fetch_arrow_all(self):
            return None
    cur = Cur()
    ex.run_sql(cur, "SELECT 1 FROM SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY")
    assert cur.sql == "SELECT 1 FROM MY_DB.AU.METERING_DAILY_HISTORY"
