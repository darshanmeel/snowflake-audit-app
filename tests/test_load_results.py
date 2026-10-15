"""tools/load_results.py: an export folder (or a zip of one) becomes a DuckDB file the app reads.

Two kinds of test: the session test DB (built from the fake account's real export), and small
hand-made folders that pin the loader's own rules.
"""
from __future__ import annotations

import csv
import datetime as dt
import json
import zipfile
from pathlib import Path

import duckdb
import pyarrow as pa
import pyarrow.parquet as pq
import pytest
from fastapi.testclient import TestClient

from app.api.app import app
from app.core import data as app_core_data
from app.core import datasource, registry
from tests.fixtures import build_fixtures
from tools import load_results as lr
from tools.common import window_aliases_map, window_plan

client = TestClient(app)
ROOT = Path(__file__).resolve().parent.parent

WINDOWED = "sf_wh_idle_minutes"
POINT_IN_TIME = "access_grants_inventory"


def _con(db: Path):
    return duckdb.connect(str(db), read_only=True)


def _sidecar(db: Path) -> dict:
    return json.loads(datasource.sidecar(db, "run_results").read_text(encoding="utf-8"))


# ------------------------------------------------------------------------------------------
# The session test DB: fake account -> export -> load
# ------------------------------------------------------------------------------------------


@pytest.fixture(scope="module")
def db(_app_env) -> Path:
    return _app_env["db_path"]


def test_every_check_but_the_two_failed_on_purpose_is_loaded(db):
    con = _con(db)
    try:
        tables = {n[2:] for (n,) in con.execute(
            "SELECT table_name FROM information_schema.tables WHERE table_schema = 'findings'").fetchall()}
    finally:
        con.close()
    all_ids = {s.query_id for s in registry.load_registry()}
    assert tables == all_ids - set(build_fixtures.FAILED_ON_PURPOSE)


def test_every_findings_table_has_window_days_and_rows(db):
    con = _con(db)
    try:
        for (name,) in con.execute(
                "SELECT table_name FROM information_schema.tables WHERE table_schema = 'findings'").fetchall():
            n, bad = con.execute(
                f'SELECT count(*), count(*) FILTER (WHERE window_days NOT IN (0, 7, 30, 90)) FROM findings."{name}"'
            ).fetchone()
            assert n > 0, f"{name} has no rows"
            assert bad == 0, name
    finally:
        con.close()


def test_windowed_tables_carry_7_30_and_the_90_alias_point_in_time_tables_carry_0(db):
    con = _con(db)
    try:
        windows = {r[0] for r in con.execute(f'SELECT DISTINCT window_days FROM findings."f_{WINDOWED}"').fetchall()}
        assert windows == {7, 30, 90}
        assert {r[0] for r in con.execute(
            f'SELECT DISTINCT window_days FROM findings."f_{POINT_IN_TIME}"').fetchall()} == {0}
        # 90 is a copy of 30: the same rows under another label
        n30 = con.execute(f'SELECT count(*) FROM findings."f_{WINDOWED}" WHERE window_days = 30').fetchone()[0]
        n90 = con.execute(f'SELECT count(*) FROM findings."f_{WINDOWED}" WHERE window_days = 90').fetchone()[0]
        assert n30 == n90 > 0
    finally:
        con.close()


def test_meta_row_carries_as_of_date_includes_today_pricing_and_account(db):
    con = _con(db)
    try:
        row = con.execute(
            "SELECT as_of, as_of_date, includes_today, account, pricing, windows, window_coverage, window_aliases "
            "FROM direct_export_meta").fetchall()
    finally:
        con.close()
    assert len(row) == 1
    as_of, as_of_date, includes_today, account, pricing, windows, coverage, aliases = row[0]
    assert as_of == "2026-09-21T12:00:00Z"
    assert as_of_date == "2026-09-21"          # the first day left out: data runs to 20 Sep
    assert includes_today is False
    assert json.loads(account) == {"id": "FAKE01", "name": "FAKE_ACCOUNT", "account_name": "FAKE_ACCOUNT",
                                   "organization_name": "FAKE_ORG", "cloud": "AWS", "region": "AWS_US_EAST_1"}
    price = json.loads(pricing)
    assert price["source"] == "usage_in_currency_daily"
    assert price["credit_price_usd"] == pytest.approx(3.0, abs=1e-6)
    assert price["storage_price_usd_tb_month"] == pytest.approx(23.0, abs=1e-6)
    assert json.loads(windows) == [7, 30, 90]
    assert json.loads(coverage) == {"7": 7, "30": 30, "90": 30}
    assert json.loads(aliases) == {"90": "30"}


def test_direct_export_info_reads_the_meta_back(db):
    info = app_core_data.direct_export_info()
    assert info["as_of_date"] == "2026-09-21" and info["includes_today"] is False
    assert info["account"]["id"] == "FAKE01" and info["pricing"]["credit_price_usd"] == pytest.approx(3.0, abs=1e-6)
    assert info["window_aliases"] == {"90": "30"}


def test_api_meta_reports_the_export(db):
    body = client.get("/api/meta").json()
    assert body["as_of_date"] == "2026-09-21"
    assert body["export_days"] == 30
    by_days = {w["days"]: w for w in body["windows"]}
    assert by_days[7]["partial"] is False and by_days[30]["partial"] is False
    assert by_days[90]["available"] is True and by_days[90]["partial"] is True and by_days[90]["covered_days"] == 30
    assert body["direct_export"]["pricing"]["credit_price_usd"] == pytest.approx(3.0, abs=1e-6)
    assert body["direct_export"]["account"]["name"] == "FAKE_ACCOUNT"
    total = sum(1 for s in registry.load_registry() if s.executable)
    assert body["checks"]["registry_total"] == total
    assert body["checks"]["failed"] == 2 and body["checks"]["ok"] == total - 2 and body["checks"]["not_built"] == 0


def test_the_run_results_sidecar_records_the_failed_checks_with_their_message(db):
    results = _sidecar(db)["results"]
    by_id = {r["query_id"]: r for r in results}
    total = sum(1 for s in registry.load_registry() if s.executable)
    assert len(by_id) == total
    for qid, message in build_fixtures.FAILED_ON_PURPOSE.items():
        assert by_id[qid]["status"] == "failed" and by_id[qid]["message"] == message
    assert sum(1 for r in results if r["status"] == "ok") == total - 2


def test_dims_are_loaded_with_names(db):
    con = _con(db)
    try:
        wh = con.execute("SELECT warehouse_name FROM dims.dim_warehouse").fetchall()
        tasks = con.execute("SELECT task_full_name, owner_role FROM dims.dim_task").fetchall()
        accounts = con.execute("SELECT account_id, name, env FROM dims.dim_account").fetchall()
    finally:
        con.close()
    assert wh and all(name for (name,) in wh)
    assert tasks and all("." in full for full, _ in tasks)
    assert accounts == [("FAKE01", "FAKE_ACCOUNT", "unknown")]


def test_fallback_checks_and_the_not_assessed_check_read_as_designed(db):
    con = _con(db)
    try:
        status = dict(con.execute(
            f'SELECT status, count(*) FROM findings."f_{build_fixtures.NOT_ASSESSED_ON_PURPOSE}" GROUP BY 1').fetchall())
        assert set(status) == {"NOT_ASSESSED"}
        reasons = con.execute(
            f'SELECT DISTINCT not_assessed_reason FROM findings."f_{build_fixtures.NOT_ASSESSED_ON_PURPOSE}"').fetchall()
        assert reasons and all(r[0] for r in reasons)
        # a fallback check (no rows or failed in the smoke) still has typed rows; an inventory has no status
        got = {r[0] for r in con.execute('SELECT DISTINCT status FROM findings."f_sf_sec_privileged_grant_changes"').fetchall()}
        assert got and got <= {"OK", "WARN"}
        assert con.execute('SELECT count(*) FROM findings."f_cost_audit_self_usage"').fetchone()[0] > 0
    finally:
        con.close()


# ------------------------------------------------------------------------------------------
# Small hand-made folders
# ------------------------------------------------------------------------------------------


def _table(window_label: int = 30, n: int = 3, **extra) -> pa.Table:
    cols = {"window_days": pa.array([window_label] * n, pa.int32()),
            "warehouse_name": pa.array([f"WH_{i}" for i in range(n)]),
            "status": pa.array(["OK", "WARN", "OK"][:n])}
    cols.update({k: pa.array(v) for k, v in extra.items()})
    return pa.table(cols)


def _make_export(tmp_path: Path, findings: dict[str, dict], *, days: int = 30, dims: bool = True,
                 extra_manifest: dict | None = None) -> Path:
    """findings: {qid: {"status": "ok"|"failed"|"empty", "table": pa.Table | None, ...manifest fields}}."""
    root = tmp_path / "export"
    (root / "findings").mkdir(parents=True)
    (root / "dims").mkdir()
    entries = {}
    for qid, spec in findings.items():
        spec = dict(spec)
        table = spec.pop("table", None)
        if table is not None:
            pq.write_table(table, root / "findings" / f"{qid}.parquet")
        entries[qid] = {"status": "ok", "error": None, "truncated": False, "truncated_windows": [], **spec}
    plan = window_plan(days)
    manifest = {
        "as_of": "2026-09-21T12:00:00Z", "as_of_date": "2026-09-21", "includes_today": False,
        "windows": [w for w, _ in plan], "window_coverage": {str(w): d for w, d in plan},
        "window_aliases": {str(a): str(s) for a, s in window_aliases_map(plan).items()},
        "days": days, "max_rows": 50000, "findings": entries, "dims": {"available": []},
        "account": {"id": "A1", "name": "ACME_PROD", "cloud": "AWS", "region": "AWS_US_EAST_1"},
        "pricing": {"source": "cli", "credit_price_usd": 2.5, "storage_price_usd_tb_month": 40.0},
    }
    if dims:
        pq.write_table(pa.table({"account_id": ["A1"], "name": ["ACME_PROD"], "url": [None]}),
                       root / "dims" / "dim_account.parquet")
        manifest["dims"]["available"] = ["dim_account"]
    manifest.update(extra_manifest or {})
    (root / "manifest.json").write_text(json.dumps(manifest), encoding="utf-8")
    return root


def test_db_path_inside_repo_is_refused_outside_data():
    assert lr.db_path_allowed(ROOT / "tests" / "x.duckdb") is False
    assert lr.db_path_allowed(ROOT / "data" / "x.duckdb") is True
    assert lr.db_path_allowed(Path("/somewhere/else/x.duckdb")) is True


def test_load_folder_shape_and_run_results(tmp_path):
    export = _make_export(tmp_path, {
        WINDOWED: {"table": _table(30)},
        "sf_wh_oversized": {"status": "failed", "error": "SQL access control error: Insufficient privileges"},
        "cost_daily_spikes": {"status": "empty", "table": _table(30, n=0)},
        POINT_IN_TIME: {"table": _table(0)},
    })
    db = tmp_path / "out" / "audit.duckdb"
    summary = lr.load_folder(export, db)
    assert sorted(summary["loaded"]) == sorted([WINDOWED, "cost_daily_spikes", POINT_IN_TIME])
    assert summary["not_built"] == ["sf_wh_oversized"]
    assert summary["failed_in_export"] == {"sf_wh_oversized": "SQL access control error: Insufficient privileges"}
    assert summary["dims_available"] == ["dim_account"]
    assert summary["dims_missing"] == ["dim_task", "dim_warehouse", "dim_user", "dim_database"]
    con = _con(db)
    try:
        assert con.execute("SELECT count(*) FROM dims.dim_task").fetchone()[0] == 0   # empty stand-in
        assert con.execute("SELECT count(*) FROM information_schema.tables "
                           "WHERE table_schema = 'findings' AND table_name = 'f_sf_wh_oversized'").fetchone()[0] == 0
        assert con.execute("SELECT count(*) FROM findings.f_cost_daily_spikes").fetchone()[0] == 0
    finally:
        con.close()
    by_id = {r["query_id"]: r for r in _sidecar(db)["results"]}
    assert by_id["sf_wh_oversized"]["status"] == "failed" and "Insufficient privileges" in by_id["sf_wh_oversized"]["message"]
    assert by_id[WINDOWED]["status"] == "ok" and by_id["cost_daily_spikes"]["status"] == "ok"


def test_meta_is_stored_from_the_manifest(tmp_path):
    export = _make_export(tmp_path, {WINDOWED: {"table": _table(30)}},
                          extra_manifest={"includes_today": True, "as_of_date": "2026-09-22"})
    db = tmp_path / "audit.duckdb"
    lr.load_folder(export, db)
    con = _con(db)
    try:
        as_of, as_of_date, includes_today, account, pricing = con.execute(
            "SELECT as_of, as_of_date, includes_today, account, pricing FROM direct_export_meta").fetchone()
    finally:
        con.close()
    assert (as_of, as_of_date, includes_today) == ("2026-09-21T12:00:00Z", "2026-09-22", True)
    assert json.loads(account)["name"] == "ACME_PROD"
    assert json.loads(pricing) == {"source": "cli", "credit_price_usd": 2.5, "storage_price_usd_tb_month": 40.0}


def test_a_shorter_export_fills_longer_windows_for_windowed_checks_only(tmp_path):
    export = _make_export(tmp_path, {WINDOWED: {"table": _table(7)}, POINT_IN_TIME: {"table": _table(0)}}, days=7)
    db = tmp_path / "audit.duckdb"
    lr.load_folder(export, db)
    con = _con(db)
    try:
        assert {r[0] for r in con.execute(f'SELECT window_days FROM findings."f_{WINDOWED}"').fetchall()} == {7, 30, 90}
        assert {r[0] for r in con.execute(f'SELECT window_days FROM findings."f_{POINT_IN_TIME}"').fetchall()} == {0}
        aliases = con.execute("SELECT window_aliases FROM direct_export_meta").fetchone()[0]
    finally:
        con.close()
    assert json.loads(aliases) == {"30": "7", "90": "7"}


def test_truncation_flows_to_findings_meta(tmp_path):
    export = _make_export(tmp_path, {
        WINDOWED: {"table": _table(30), "truncated": True, "truncated_windows": [30]},
        POINT_IN_TIME: {"table": _table(0)},
    }, extra_manifest={"max_rows": 3})
    db = tmp_path / "audit.duckdb"
    summary = lr.load_folder(export, db)
    assert summary["truncated"] == [WINDOWED] and summary["max_rows"] == 3
    con = _con(db)
    try:
        rows = {q: (t, m, json.loads(w)) for q, t, m, w in con.execute(
            "SELECT query_id, truncated, max_rows, truncated_windows FROM direct_export_findings_meta").fetchall()}
    finally:
        con.close()
    assert rows[WINDOWED] == (True, 3, [30]) and rows[POINT_IN_TIME] == (False, 3, [])
    assert "kept the first 3 rows" in {r["query_id"]: r for r in _sidecar(db)["results"]}[WINDOWED]["message"]


def test_timestamps_are_stored_as_naive_utc(tmp_path):
    aware = pa.array([dt.datetime(2026, 9, 20, 23, 30, tzinfo=dt.timezone(dt.timedelta(hours=2)))],
                     pa.timestamp("us", tz="Europe/Berlin"))
    table = pa.table({"window_days": pa.array([30], pa.int32()), "first_seen": aware, "status": ["OK"]})
    export = _make_export(tmp_path, {WINDOWED: {"table": table}})
    db = tmp_path / "audit.duckdb"
    lr.load_folder(export, db)
    con = _con(db)
    try:
        dtype = con.execute(f'SELECT typeof(first_seen) FROM findings."f_{WINDOWED}" LIMIT 1').fetchone()[0]
        value = con.execute(f'SELECT first_seen FROM findings."f_{WINDOWED}" WHERE window_days = 30').fetchone()[0]
    finally:
        con.close()
    assert dtype == "TIMESTAMP" and value == dt.datetime(2026, 9, 20, 21, 30)


def test_a_table_without_window_days_or_with_a_bad_one_is_rejected_as_failed(tmp_path):
    export = _make_export(tmp_path, {
        WINDOWED: {"table": pa.table({"warehouse_name": ["WH_1"], "status": ["OK"]})},
        "cost_daily_spikes": {"table": _table(45)},
        POINT_IN_TIME: {"table": _table(0)},
    })
    db = tmp_path / "audit.duckdb"
    summary = lr.load_folder(export, db)
    assert summary["loaded"] == [POINT_IN_TIME]
    assert summary["failed_in_export"] == {WINDOWED: "missing column window_days",
                                           "cost_daily_spikes": "window_days must be 0, 7, 30 or 90"}


def test_a_check_recorded_ok_with_no_file_is_reported_missing(tmp_path):
    export = _make_export(tmp_path, {WINDOWED: {}, POINT_IN_TIME: {"table": _table(0)}})
    summary = lr.load_folder(export, tmp_path / "audit.duckdb")
    assert summary["missing_file"] == [WINDOWED] and summary["loaded"] == [POINT_IN_TIME]


def test_a_query_id_that_is_not_an_identifier_is_refused_not_spliced(tmp_path):
    export = _make_export(tmp_path, {POINT_IN_TIME: {"table": _table(0)}, 'x"; DROP TABLE y; --': {}})
    summary = lr.load_folder(export, tmp_path / "audit.duckdb")
    assert summary["loaded"] == [POINT_IN_TIME]
    assert summary["missing_file"] == ['x"; DROP TABLE y; --']


def test_dims_not_declared_in_the_manifest_are_not_picked_up(tmp_path):
    export = _make_export(tmp_path, {POINT_IN_TIME: {"table": _table(0)}}, dims=False)
    pq.write_table(pa.table({"account_id": ["STALE"], "name": ["STALE_ACCOUNT"], "url": [None]}),
                   export / "dims" / "dim_account.parquet")   # left over from an earlier, partly failed export
    db = tmp_path / "audit.duckdb"
    summary = lr.load_folder(export, db)
    assert summary["dims_available"] == [] and summary["dims_missing"] == list(lr.DIM_TABLE_NAMES)
    con = _con(db)
    try:
        # the stale file is ignored; the account is named by the manifest alone
        assert con.execute("SELECT count(*) FROM dims.dim_account WHERE account_id = 'STALE'").fetchone()[0] == 0
    finally:
        con.close()


def test_the_account_env_is_classified_by_name(tmp_path):
    export = _make_export(tmp_path, {POINT_IN_TIME: {"table": _table(0)}})
    db = tmp_path / "audit.duckdb"
    lr.load_folder(export, db)
    con = _con(db)
    try:
        row = con.execute("SELECT name, env, env_source, env_reason FROM dims.dim_account").fetchone()
    finally:
        con.close()
    assert row[:3] == ("ACME_PROD", "prod", "name") and "ACME_PROD" in row[3]


def test_user_names_are_masked_only_when_the_setting_is_on(tmp_path, monkeypatch):
    table = pa.table({"window_days": pa.array([0], pa.int32()), "user_name": ["person@example.com"],
                      "warehouse_name": ["WH_ONE"], "status": ["OK"]})
    export = _make_export(tmp_path, {POINT_IN_TIME: {"table": table}})
    plain = tmp_path / "plain.duckdb"
    lr.load_folder(export, plain)
    config = tmp_path / "config"
    config.mkdir()
    (config / "settings.yml").write_text("privacy:\n  mask_user_identities: true\n", encoding="utf-8")
    monkeypatch.setenv("AUDIT_CONFIG_DIR", str(config))
    masked = tmp_path / "masked.duckdb"
    lr.load_folder(export, masked)
    read = lambda p: _con(p).execute(f'SELECT user_name, warehouse_name FROM findings."f_{POINT_IN_TIME}"').fetchone()
    assert read(plain) == ("person@example.com", "WH_ONE")
    user, warehouse = read(masked)
    assert user.endswith("pe***") and user != "person@example.com" and warehouse == "WH_ONE"


def test_load_a_hand_made_csv_folder_with_no_manifest(tmp_path):
    root = tmp_path / "csv_export"
    (root / "findings").mkdir(parents=True)
    with (root / "findings" / f"{WINDOWED}.csv").open("w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["window_days", "warehouse_id", "warehouse_name", "est_wasted_usd_list", "status"])
        w.writerow([7, "1001", "WH_ANALYTICS", "12.5", "WARN"])
    db = tmp_path / "audit.duckdb"
    summary = lr.load_folder(root, db)
    assert summary["loaded"] == [WINDOWED]
    con = _con(db)
    try:
        row = con.execute(f'SELECT warehouse_id, typeof(warehouse_id), est_wasted_usd_list FROM findings."f_{WINDOWED}" '
                          "WHERE window_days = 7").fetchone()
        windows = {r[0] for r in con.execute(f'SELECT window_days FROM findings."f_{WINDOWED}"').fetchall()}
    finally:
        con.close()
    assert row == ("1001", "VARCHAR", 12.5)      # an id stays text so it still joins to the dims
    assert windows == {7, 30, 90}                # no manifest: a 7-day file fills the longer windows


def test_a_folder_with_no_recognised_files_is_rejected(tmp_path):
    (tmp_path / "empty").mkdir()
    with pytest.raises(lr.LoadConfigError):
        lr.load_folder(tmp_path / "empty", tmp_path / "audit.duckdb")
    with pytest.raises(lr.LoadConfigError):
        lr.load_folder(tmp_path / "does_not_exist", tmp_path / "audit.duckdb")


def _zip_folder(folder: Path, dest: Path, prefix: str = "") -> Path:
    with zipfile.ZipFile(dest, "w") as zf:
        for p in folder.rglob("*"):
            if p.is_file():
                zf.write(p, prefix + p.relative_to(folder).as_posix())
    return dest


def test_load_a_zip_of_an_export_and_one_wrapped_in_a_folder(tmp_path):
    export = _make_export(tmp_path, {WINDOWED: {"table": _table(30)}})
    for name, prefix in (("plain.zip", ""), ("wrapped.zip", "results-2026-09-21/")):
        summary = lr.load_folder(_zip_folder(export, tmp_path / name, prefix), tmp_path / f"{name}.duckdb")
        assert summary["loaded"] == [WINDOWED]
        assert summary["as_of"] == "2026-09-21T12:00:00Z"


def test_unsafe_zip_entries_are_refused(tmp_path):
    bad = tmp_path / "bad.zip"
    with zipfile.ZipFile(bad, "w") as zf:
        zf.writestr("../escape.txt", "x")
    with pytest.raises(lr.LoadConfigError, match="unsafe path"):
        lr.load_folder(bad, tmp_path / "audit.duckdb")
    not_a_zip = tmp_path / "junk.zip"
    not_a_zip.write_text("not a zip")
    with pytest.raises(lr.LoadConfigError, match="not a readable zip"):
        lr.load_folder(not_a_zip, tmp_path / "audit.duckdb")


def test_a_reload_replaces_the_db_and_leaves_no_temp_files(tmp_path):
    export = _make_export(tmp_path, {WINDOWED: {"table": _table(30)}})
    db = tmp_path / "audit.duckdb"
    lr.load_folder(export, db)
    lr.load_folder(export, db)
    assert sorted(p.name for p in tmp_path.iterdir() if p.name.startswith("audit")) == [
        "audit.duckdb", "audit.run_results.json"]


def test_main_defaults_to_the_data_folder_and_points_the_app_at_it(tmp_path, monkeypatch, capsys):
    data_dir = tmp_path / "appdata"
    monkeypatch.setenv("AUDIT_DATA_DIR", str(data_dir))
    _make_export(data_dir, {WINDOWED: {"table": _table(30)}})
    (data_dir / "export").rename(data_dir / "results")
    assert lr.main([]) == 0
    assert (data_dir / "audit.duckdb").exists()
    assert datasource.current_db() == (data_dir / "audit.duckdb").resolve()
    assert "loaded 1 finding(s)" in capsys.readouterr().out


def test_main_refuses_a_db_inside_the_repo(tmp_path, capsys):
    export = _make_export(tmp_path, {WINDOWED: {"table": _table(30)}})
    assert lr.main([str(export), "--db", str(ROOT / "tests" / "should_not_exist.duckdb")]) == 2
    assert "inside the repository" in capsys.readouterr().err
    assert not (ROOT / "tests" / "should_not_exist.duckdb").exists()


def test_main_leaves_the_current_db_pointer_alone_for_a_db_outside_the_data_folder(tmp_path, monkeypatch):
    data_dir = tmp_path / "appdata"
    monkeypatch.setenv("AUDIT_DATA_DIR", str(data_dir))
    export = _make_export(tmp_path, {WINDOWED: {"table": _table(30)}})
    assert lr.main([str(export), "--db", str(tmp_path / "elsewhere.duckdb")]) == 0
    assert datasource.current_db() is None


# ------------------------------------------------------------------------------------------
# A loaded folder, read back through the app
# ------------------------------------------------------------------------------------------


@pytest.fixture
def small_db(tmp_path, monkeypatch):
    export = _make_export(tmp_path, {
        WINDOWED: {"table": _table(30)},
        "sf_wh_oversized": {"status": "failed", "error": "SQL access control error: Insufficient privileges"},
    })
    db = tmp_path / "small.duckdb"
    lr.load_folder(export, db)
    monkeypatch.setenv("AUDIT_DB", str(db))
    monkeypatch.delenv("AUDIT_RUN_RESULTS", raising=False)
    return db


def test_a_loaded_and_a_failed_finding_read_back_through_the_api(small_db):
    ok = client.get(f"/api/finding/{WINDOWED}", params={"window": 30}).json()
    assert ok["outcome"] == "ok_rows" and ok["rows_total"] == 3
    failed = client.get("/api/finding/sf_wh_oversized", params={"window": 30}).json()
    assert failed["outcome"] == "not_assessed" and "rows" not in failed
    assert "Insufficient privileges" in failed["status_info"]["message"]


def test_a_check_missing_from_the_run_results_and_the_db_is_not_built(small_db):
    body = client.get("/api/finding/cost_daily_spikes", params={"window": 30}).json()
    assert body["outcome"] == "not_assessed" and "rows" not in body
    meta = client.get("/api/meta").json()
    total = sum(1 for s in registry.load_registry() if s.executable)
    assert meta["checks"]["registry_total"] == total and meta["checks"]["not_built"] == total - 2


def test_with_no_src_the_loader_reads_the_newest_export(tmp_path, monkeypatch):
    monkeypatch.setenv("AUDIT_DATA_DIR", str(tmp_path))
    for stamp in ("20260901T000000Z", "20260902T000000Z", "20260903T000000Z"):
        (tmp_path / "results" / stamp).mkdir(parents=True)
    for stamp in ("20260901T000000Z", "20260902T000000Z"):
        (tmp_path / "results" / stamp / "manifest.json").write_text("{}", encoding="utf-8")
    assert lr._newest_results().name == "20260902T000000Z", "the newest folder with a manifest"


def test_export_tag_keys_always_keeps_the_tags_the_app_reads(monkeypatch):
    from app.core import config as app_config
    monkeypatch.setattr(app_config, "load_tag_aliases", lambda: {"canonical": {"team": ["squad"], "cost_center": []}})
    settings = {"export_tag_keys": ["env"], "cost_center_tag_keys": ["cc"], "required_tag_keys": ["owner"]}
    assert lr._tag_key_filter(settings) == ["env", "cc", "owner", "team", "cost_center", "squad"]
    assert lr._tag_key_filter({"export_tag_keys": None}) is None


def test_a_tag_source_parquet_loads_in_duckdb_with_timestamps_as_naive_utc(tmp_path):
    path = tmp_path / "tag_refs.parquet"
    ts = dt.datetime(2026, 9, 1, 23, 30, tzinfo=dt.timezone(dt.timedelta(hours=-2)))
    pq.write_table(pa.table({"tag_name": ["COST_CENTER"], "created": pa.array([ts], pa.timestamp("us", tz="-02:00"))}), path)
    con = duckdb.connect()
    con.execute("SET TimeZone = 'UTC'")
    con.execute("CREATE SCHEMA tags_src")
    lr._create_from_parquet(con, 'tags_src."tag_refs"', path)
    assert con.execute('SELECT tag_name, created FROM tags_src."tag_refs"').fetchall() == [
        ("COST_CENTER", dt.datetime(2026, 9, 2, 1, 30))]
