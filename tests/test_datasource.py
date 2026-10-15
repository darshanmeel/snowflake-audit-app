"""app/core/datasource.py's own defaults, and app/core/data.py's use of them when AUDIT_DB (and
friends) are unset -- the "no paths typed" path from export through load to the running app."""
from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from app.core import data as app_core_data  # noqa: E402
from app.core import datasource  # noqa: E402


def test_default_data_dir_windows():
    d = datasource.default_data_dir("win32", environ={"LOCALAPPDATA": r"D:\Profiles\me\AppData\Local"}, home=Path("D:/Profiles/me"))
    assert d == Path(r"D:\Profiles\me\AppData\Local") / "snowflake-audit"


def test_default_data_dir_windows_falls_back_without_localappdata():
    d = datasource.default_data_dir("win32", environ={}, home=Path("D:/Profiles/me"))
    assert d == Path("D:/Profiles/me") / "AppData" / "Local" / "snowflake-audit"


def test_default_data_dir_macos():
    d = datasource.default_data_dir("darwin", environ={}, home=Path("/Users/me"))
    assert d == Path("/Users/me/Library/Application Support/snowflake-audit")


def test_default_data_dir_linux_xdg():
    d = datasource.default_data_dir("linux", environ={"XDG_DATA_HOME": "/data"}, home=Path("/home/me"))
    assert d == Path("/data/snowflake-audit")


def test_default_data_dir_linux_falls_back_without_xdg():
    d = datasource.default_data_dir("linux", environ={}, home=Path("/home/me"))
    assert d == Path("/home/me/.local/share/snowflake-audit")


def test_data_dir_honours_the_env_var(monkeypatch, tmp_path):
    monkeypatch.setenv("AUDIT_DATA_DIR", str(tmp_path))
    assert datasource.data_dir() == tmp_path


def test_results_dir_and_db_path_and_sidecar(monkeypatch, tmp_path):
    monkeypatch.setenv("AUDIT_DATA_DIR", str(tmp_path))
    assert datasource.results_dir() == tmp_path / "results"
    assert datasource.db_path() == tmp_path / "audit.duckdb"
    assert datasource.sidecar(tmp_path / "x.duckdb", "source") == tmp_path / "x.source.json"


def test_inside_repo():
    assert datasource.inside_repo(datasource.ROOT / "app") is True
    assert datasource.inside_repo(datasource.ROOT.parent / "elsewhere") is False


# ------------------------------------------------------------------------------------------
# app/core/data.py: with no AUDIT_DB set, the current-db pointer, then the data folder's audit.duckdb.
# ------------------------------------------------------------------------------------------


def test_db_path_prefers_audit_db_env(monkeypatch, tmp_path):
    monkeypatch.delenv("AUDIT_DB", raising=False)
    monkeypatch.setenv("AUDIT_DATA_DIR", str(tmp_path))
    (tmp_path / "audit.duckdb").touch()
    monkeypatch.setenv("AUDIT_DB", str(tmp_path / "explicit.duckdb"))
    assert app_core_data._db_path() == tmp_path / "explicit.duckdb"




def test_db_path_serves_the_data_folder_db_once_it_exists(monkeypatch, tmp_path):
    monkeypatch.delenv("AUDIT_DB", raising=False)
    monkeypatch.setenv("AUDIT_DATA_DIR", str(tmp_path))
    (tmp_path / "audit.duckdb").touch()
    assert app_core_data._db_path() == tmp_path / "audit.duckdb"




def test_db_path_prefers_the_current_db_pointer_over_the_data_folder_default(monkeypatch, tmp_path):
    monkeypatch.delenv("AUDIT_DB", raising=False)
    monkeypatch.setenv("AUDIT_DATA_DIR", str(tmp_path))
    (tmp_path / "audit.duckdb").touch()
    pointed = tmp_path / "audit-20260101-000000.duckdb"
    pointed.touch()
    datasource.set_current_db(pointed)
    assert app_core_data._db_path() == pointed


def test_db_path_ignores_a_pointer_whose_target_is_gone(monkeypatch, tmp_path):
    monkeypatch.delenv("AUDIT_DB", raising=False)
    monkeypatch.setenv("AUDIT_DATA_DIR", str(tmp_path))
    (tmp_path / "audit.duckdb").touch()
    datasource.set_current_db(tmp_path / "gone.duckdb")
    assert app_core_data._db_path() == tmp_path / "audit.duckdb"


def test_set_current_db_and_current_db_round_trip(monkeypatch, tmp_path):
    monkeypatch.setenv("AUDIT_DATA_DIR", str(tmp_path))
    assert datasource.current_db() is None
    db = tmp_path / "audit-20260101-000000.duckdb"
    db.touch()
    datasource.set_current_db(db)
    assert datasource.current_db() == db


def test_run_results_path_picks_up_the_matching_sidecar(monkeypatch, tmp_path):
    monkeypatch.delenv("AUDIT_RUN_RESULTS", raising=False)
    monkeypatch.delenv("AUDIT_DB", raising=False)
    monkeypatch.setenv("AUDIT_DATA_DIR", str(tmp_path))
    (tmp_path / "audit.duckdb").touch()
    (tmp_path / "audit.run_results.json").write_text("{}", encoding="utf-8")
    assert app_core_data._run_results_path() == tmp_path / "audit.run_results.json"


def test_run_results_path_is_the_sidecar_even_when_it_is_absent(monkeypatch, tmp_path):
    monkeypatch.delenv("AUDIT_RUN_RESULTS", raising=False)
    monkeypatch.delenv("AUDIT_DB", raising=False)
    monkeypatch.setenv("AUDIT_DATA_DIR", str(tmp_path))
    (tmp_path / "audit.duckdb").touch()  # no sidecar next to it
    assert app_core_data._run_results_path() == tmp_path / "audit.run_results.json"
    assert app_core_data.run_results()["available"] is False





