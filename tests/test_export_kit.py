"""The export kit (tools/make_export_kit.py) runs on its own and writes what tools/export_results.py
writes: same statuses, same parquet, same manifest fields the loader reads. Both run on the fake account.
"""
from __future__ import annotations

import importlib.util
import json
import shutil

import pyarrow.parquet as pq
import pytest

from tools import export_results as ex
from tools import make_export_kit, sql_smoke
from tests.fake_snowflake import data as fake_data

CHECKS = ["cost_audit_self_usage", "query_warehouse_pressure", "sf_acct_budgets", "access_login_concentration",
          "sf_ai_cowork_spend"]


@pytest.fixture(scope="module")
def kit():
    return make_export_kit.KIT


def _runner(kit):
    spec = importlib.util.spec_from_file_location("kit_run_export", kit / "run_export.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def _files(root):
    return {p.relative_to(root).as_posix(): p.read_bytes().replace(b"\r\n", b"\n")
            for p in root.rglob("*") if p.is_file() and "__pycache__" not in p.parts}


def test_the_committed_kit_is_up_to_date(tmp_path):
    fresh = make_export_kit.build(tmp_path / "export_kit")
    committed = {k: v for k, v in _files(make_export_kit.KIT).items()
                 if not k.startswith(("sf-audit-out", ".env"))}
    assert committed == _files(fresh), "the kit is out of date: run python tools/make_export_kit.py"


def test_the_kit_holds_one_script_and_only_sql(kit):
    names = sorted(p.name for p in kit.iterdir() if p.name not in ("__pycache__", ".env")
                   and not p.name.startswith("sf-audit-out"))
    assert names == ["README.md", "grants.sql", "queries", "run_export.py", "verify"]
    assert [p.name for p in kit.rglob("*.py")] == ["run_export.py"], "one Python file only"
    index = json.loads((kit / "queries" / "index.json").read_text(encoding="utf-8"))
    assert len(index["checks"]) == len(ex.load_checks())
    assert not any("__INCLUDE_" in p.read_text(encoding="utf-8") for p in kit.rglob("*.sql"))
    source = (kit / "run_export.py").read_text(encoding="utf-8")
    assert "from app" not in source and "from tools" not in source
    readme = (kit / "README.md").read_text(encoding="utf-8")
    assert "## How to run it" in readme and "## Roles and privileges" in readme and "--validate" not in readme


def test_the_zip_leaves_out_local_files(tmp_path):
    import zipfile
    archive = make_export_kit.zip_kit(tmp_path)
    names = zipfile.ZipFile(archive).namelist()
    assert "export_kit/run_export.py" in names and "export_kit/grants.sql" in names
    assert not [n for n in names if n.endswith((".env", ".p8")) or "sf-audit-out" in n]


def test_the_kit_writes_what_the_export_writes(kit, tmp_path):
    con = sql_smoke.build_fake_db(fake_data.NOW.date())
    connect = lambda: sql_smoke.FakeConnection(con)  # noqa: E731
    main = ex.run_export(tmp_path / "main", windows=30, only=CHECKS, connect_fn=connect,
                         include_today=False, now=fake_data.NOW)
    mine = _runner(kit).run_export(tmp_path / "kit", windows=30, only=CHECKS, connect_fn=connect,
                                   include_today=False, now=fake_data.NOW)
    for key in ("as_of_date", "windows", "window_coverage", "window_aliases", "account", "pricing", "edition",
                "visibility", "dims", "tag_sources", "max_rows"):
        assert mine[key] == main[key], key
    for qid in CHECKS:
        a, b = main["findings"][qid], mine["findings"][qid]
        assert (b["status"], b["exported_rows"], b.get("columns")) == (a["status"], a["exported_rows"], a.get("columns")), qid
    for sub in ("findings", "dims", "tags_src"):
        names = sorted(p.name for p in (tmp_path / "main" / sub).glob("*.parquet"))
        assert names == sorted(p.name for p in (tmp_path / "kit" / sub).glob("*.parquet")), sub
        for name in names:
            # Row order is not fixed for a query without ORDER BY, so compare sorted rows.
            a, b = (pq.read_table(tmp_path / d / sub / name) for d in ("main", "kit"))
            assert a.schema == b.schema, name
            assert sorted(map(repr, a.to_pylist())) == sorted(map(repr, b.to_pylist())), name


def test_the_kit_refuses_a_write(kit):
    runner = _runner(kit)
    with pytest.raises(runner.StopExport):
        runner.assert_read_only("DELETE FROM t")


def _broken_kit(kit, tmp_path):
    copy = tmp_path / "kit"
    shutil.copytree(kit, copy, ignore=shutil.ignore_patterns("__pycache__"))
    q = copy / "queries"
    (q / "checks" / "cost_audit_self_usage.sql").write_text("SELECT FROM WHERE", encoding="utf-8")
    (q / "checks" / "sf_acct_budgets.sql").write_text("SELECT * FROM SNOWFLAKE.ACCOUNT_USAGE.NO_SUCH_VIEW",
                                                      encoding="utf-8")
    (q / "checks" / "access_login_concentration.sql").unlink()
    (q / "dims" / "dim_task.sql").write_text("SELECT nope FROM nowhere", encoding="utf-8")
    return copy


def test_errors_are_recorded_and_the_run_goes_on(kit, tmp_path):
    copy = _broken_kit(kit, tmp_path)
    con = sql_smoke.build_fake_db(fake_data.NOW.date())
    out = tmp_path / "out"
    manifest = _runner(copy).run_export(out, windows=30, only=CHECKS, include_today=False, now=fake_data.NOW,
                                        connect_fn=lambda: sql_smoke.FakeConnection(con))
    status = {q: f["status"] for q, f in manifest["findings"].items()}
    assert status == {"cost_audit_self_usage": "failed", "sf_acct_budgets": "failed",
                      "access_login_concentration": "failed", "query_warehouse_pressure": "ok",
                      "sf_ai_cowork_spend": "ok"}
    assert "dim_task" in manifest["dims_failed"] and "dim_account" in manifest["dims"]["available"]
    report = (out / "report.md").read_text(encoding="utf-8")
    assert "## Errors (3 checks, 1 other)" in report
    assert "NO_SUCH_VIEW" in report and "FileNotFoundError" in report and "dim dim_task" in report
    assert (out / "findings" / "sf_ai_cowork_spend.parquet").exists()


def test_ctrl_c_keeps_what_ran_and_writes_the_report(kit, tmp_path):
    con = sql_smoke.build_fake_db(fake_data.NOW.date())

    class Interrupting(sql_smoke.FakeCursor):
        def execute(self, sql):
            if "COWORK" in sql.upper() and "LIMIT 0" not in sql:
                raise KeyboardInterrupt
            return super().execute(sql)

    class Conn(sql_smoke.FakeConnection):
        def cursor(self):
            return Interrupting(self.con)

    order = ["query_warehouse_pressure", "sf_ai_cowork_spend", "sf_acct_budgets"]
    out = tmp_path / "out"
    manifest = _runner(kit).run_export(out, windows=30, only=order, include_today=False, now=fake_data.NOW,
                                       connect_fn=lambda: Conn(con))
    f = manifest["findings"]
    assert f["query_warehouse_pressure"]["status"] == "ok"
    assert "stopped during" in f["sf_ai_cowork_spend"]["error"]
    assert "stopped before" in f["sf_acct_budgets"]["error"]
    assert manifest["stopped_early"] is True
    assert "stopped before the end" in (out / "report.md").read_text(encoding="utf-8")


class _NoAccessCursor(sql_smoke.FakeCursor):
    """A role that can run statements but read nothing in the SNOWFLAKE database and no SHOW."""

    def execute(self, sql, *args, **kwargs):
        text = sql.upper()
        if "SNOWFLAKE." in text or text.lstrip().startswith("SHOW"):
            raise RuntimeError("SQL compilation error: Object does not exist or not authorized.")
        return super().execute(sql, *args, **kwargs)


class _NoAccessConnection(sql_smoke.FakeConnection):
    def cursor(self):
        return _NoAccessCursor(self.con, self.strict)


def test_a_role_that_can_read_nothing_still_finishes_with_every_check_not_assessed(kit, tmp_path):
    con = sql_smoke.build_fake_db(fake_data.NOW.date())
    out = tmp_path / "out"
    manifest = _runner(kit).run_export(out, windows=30, only=CHECKS, include_today=False, now=fake_data.NOW,
                                       connect_fn=lambda: _NoAccessConnection(con))
    status = {q: f["status"] for q, f in manifest["findings"].items()}
    assert set(status) == set(CHECKS)
    assert set(status.values()) == {"not_assessed"}, "a missing grant reads 'role can't see it', never an error"
    assert all(f["not_assessed_reason"] == "role_cannot_see" for f in manifest["findings"].values())
    assert not list((out / "findings").glob("*.parquet")), "no file for a check that could not read its view"
    assert (out / "manifest.json").exists() and (out / "report.md").exists()
