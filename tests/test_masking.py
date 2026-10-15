"""Export-time masking (app/core/masking.py): chosen kinds of names become the same token in every
file, no real name is left anywhere in the results folder, and the results still load and add up.
"""
from __future__ import annotations

import importlib.util
import json
import re
from pathlib import Path

import pyarrow as pa
import pyarrow.parquet as pq
import pytest

from app.core import identity, masking
from tools import export_results as ex
from tools import load_results, make_export_kit, sql_smoke
from tests.fake_snowflake import data as fake_data

CHECKS = ["access_grants_inventory", "sf_sec_admin_role_holders", "query_top_by_cost", "sf_wh_idle_minutes",
          "sf_task_failures", "sf_storage_unused_tables", "sf_cost_query_attribution_by_user", "access_broad_grants",
          "sf_lin_table_flows", "sf_wh_config_current", "sf_gov_ownership_concentration",
          "sf_storage_stale_stage_files", "sf_pipe_inactive", "sf_sec_users_without_mfa",
          "cost_chargeback_by_warehouse", "sf_dt_unread_refresh_cost"]


# ---- the masker -------------------------------------------------------------------------------------------------
def test_kinds_parse_and_reject_unknown():
    assert masking.parse_kinds("warehouse, USER") == ["user", "warehouse"]
    assert masking.parse_kinds("all") == list(masking.MASK_KINDS)
    assert masking.parse_kinds(None) == [] and masking.parse_kinds("") == []
    with pytest.raises(ValueError, match="unknown mask kind"):
        masking.parse_kinds("warehouse,colour")


def test_person_rule_matches_identity():
    # The kit carries a copy of the masking module, so its person rule must equal the app's.
    assert masking._PERSON_RE.pattern == identity._PERSON_COLUMN_RE.pattern


def _folder(tmp_path):
    pq.write_table(pa.table({
        "warehouse_name": ["ETL_WH", "(warehouse idle)", None], "warehouse_id": ["1", "2", "3"],
        "reasons": ["ETL_WH idle for role LOADER on SALES", "x", None],
        "table_fqn": ['SALES.RAW."Orders.2024"', "SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY", None],
        "user_name": ["alice@example.com", "bob", None], "granted_roles": ["LOADER, ACCOUNTADMIN,ANALYST", None, None],
        "grantee_name": ["LOADER", "carol", None], "granted_to": ["ROLE", "USER", None],
        "credits": [1.5, 2.0, None],
    }), tmp_path / "a.parquet")
    pq.write_table(pa.table({"role_name": ["loader", "ANALYST", "SYSADMIN"], "database_name": ["sales", "SNOWFLAKE", None]}),
                   tmp_path / "b.parquet")
    return tmp_path


def test_the_same_name_gets_the_same_token_in_every_file_and_in_free_text(tmp_path):
    folder = _folder(tmp_path)
    manifest = masking.mask_folder(folder, "all", "fixed", {"account": {"id": "AB12345"}, "note": "LOADER on ETL_WH"})
    a = pq.read_table(folder / "a.parquet").to_pylist()
    b = pq.read_table(folder / "b.parquet").to_pylist()
    wh, role = a[0]["warehouse_name"], a[0]["grantee_name"]
    assert re.fullmatch(r"wh_[0-9a-f]{8}", wh) and re.fullmatch(r"role_[0-9a-f]{8}", role)
    assert b[0]["role_name"] == role, "names match without case, across files"
    db = b[0]["database_name"]
    assert a[0]["reasons"] == f"{wh} idle for role {role} on {db}"
    assert a[0]["table_fqn"].split(".")[0] == db and a[0]["table_fqn"].count(".") == 2
    assert a[1]["table_fqn"] == "SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY", "Snowflake's own views stay"
    assert a[1]["warehouse_name"] == "(warehouse idle)" and b[2]["role_name"] == "SYSADMIN" and b[1]["database_name"] == "SNOWFLAKE"
    assert a[0]["granted_roles"].split(", ")[0] == role and "ACCOUNTADMIN" in a[0]["granted_roles"]
    assert a[1]["grantee_name"].endswith("***"), "a user grantee is masked as a user"
    assert a[0]["user_name"].endswith("***") and "alice" not in a[0]["user_name"]
    assert a[0]["warehouse_id"] == "1" and a[0]["credits"] == 1.5, "ids and numbers stay"
    assert manifest["note"] == f"{role} on {wh}" and manifest["account"]["id"].startswith("acct_")


def test_a_kind_not_asked_for_is_left_alone(tmp_path):
    folder = _folder(tmp_path)
    masking.mask_folder(folder, "warehouse")
    a = pq.read_table(folder / "a.parquet").to_pylist()
    assert a[0]["warehouse_name"].startswith("wh_") and a[0]["grantee_name"] == "LOADER" and a[0]["user_name"] == "alice@example.com"
    assert a[0]["reasons"].startswith("wh_") and "LOADER" in a[0]["reasons"]


def test_tokens_are_salted(tmp_path):
    m1, m2, m3 = masking.Masker(["warehouse"]), masking.Masker(["warehouse"]), masking.Masker(["warehouse"], "s")
    assert m1.token("warehouse", "ETL_WH") != m2.token("warehouse", "ETL_WH"), "a random salt per export"
    assert m3.token("warehouse", "ETL_WH") == masking.Masker(["warehouse"], "s").token("warehouse", "ETL_WH")
    assert masking.mask_folder(tmp_path, []) is None and masking.mask_folder(tmp_path, None, manifest={"a": 1}) == {"a": 1}


# ---- the export --------------------------------------------------------------------------------------------------
def _rows(table: pa.Table, cols=None) -> list[str]:
    """Sorted rows with floats rounded: DuckDB sums in no fixed order, so the last digit can differ run to run."""
    t = table.select(cols) if cols is not None else table
    norm = lambda v: round(v, 6) if isinstance(v, float) else v  # noqa: E731
    return sorted(repr({k: norm(v) for k, v in r.items()}) for r in t.to_pylist())


def _strings(folder: Path) -> list[str]:
    out = []
    for f in folder.rglob("*.parquet"):
        t = pq.read_table(f)
        for field in t.schema:
            if pa.types.is_string(field.type):
                out.extend(v for v in t.column(field.name).to_pylist() if isinstance(v, str))
    for name in ("manifest.json", "report.md"):
        out.append((folder / name).read_text(encoding="utf-8"))
    return out


@pytest.fixture(scope="module")
def exports(tmp_path_factory):
    base = tmp_path_factory.mktemp("masking")
    con = sql_smoke.build_fake_db(fake_data.NOW.date())
    connect = lambda: sql_smoke.FakeConnection(con)  # noqa: E731
    plain = ex.run_export(base / "plain", windows=30, only=CHECKS, connect_fn=connect, include_today=False, now=fake_data.NOW)
    masked = ex.run_export(base / "masked", windows=30, only=CHECKS, connect_fn=connect, include_today=False,
                           now=fake_data.NOW, mask=["all"], mask_salt="test-salt")
    return base, plain, masked, connect


def test_no_real_name_is_left_anywhere_in_a_masked_export(exports):
    base, _, masked, _ = exports
    learn = masking.Masker(list(masking.MASK_KINDS), "x")
    for f in (base / "plain").rglob("*.parquet"):
        learn.collect(pq.read_table(f))
    names = {k for kind in masking.MASK_KINDS if kind != "user" for k in learn.names[kind] if len(k) >= 3}
    assert len(names) > 20, "the fake account has names to hide"
    pattern = re.compile(r"(?<![A-Za-z0-9_$])(?:" + "|".join(map(re.escape, sorted(names, key=len, reverse=True)))
                         + r")(?![A-Za-z0-9_$])", re.IGNORECASE)
    leaks = sorted({m.group(0) for s in _strings(base / "masked") for m in pattern.finditer(s)})
    assert leaks == [], f"real names left in the masked export: {leaks[:20]}"
    assert masked["masked"] == list(masking.MASK_KINDS)


def test_a_masked_export_has_the_same_results_and_loads(exports, tmp_path):
    base, plain, masked, _ = exports
    for qid in CHECKS:
        a, b = plain["findings"][qid], masked["findings"][qid]
        assert (a["status"], a["exported_rows"], a["columns"]) == (b["status"], b["exported_rows"], b["columns"]), qid
    num = lambda t: _rows(t, [f.name for f in t.schema if not pa.types.is_string(f.type)])  # noqa: E731
    for f in (base / "plain" / "findings").glob("*.parquet"):
        assert num(pq.read_table(f)) == num(pq.read_table(base / "masked" / "findings" / f.name)), f.name
    db = tmp_path / "masked.duckdb"
    load_results.main([str(base / "masked"), "--db", str(db)])
    import duckdb
    con = duckdb.connect(str(db), read_only=True)
    assert json.loads(con.execute("SELECT masked FROM main.direct_export_meta").fetchone()[0]) == list(masking.MASK_KINDS)


def test_the_kit_masks_exactly_like_the_export(exports, tmp_path):
    base, _, _, connect = exports
    kit = make_export_kit.KIT
    spec = importlib.util.spec_from_file_location("kit_run_export_mask", kit / "run_export.py")
    runner = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(runner)
    runner.run_export(tmp_path / "kit", windows=30, only=CHECKS, connect_fn=connect, include_today=False,
                      now=fake_data.NOW, mask=["all"], mask_salt="test-salt")
    for f in (base / "masked" / "findings").glob("*.parquet"):
        a, b = pq.read_table(f), pq.read_table(tmp_path / "kit" / "findings" / f.name)
        # Lists inside a cell (LISTAGG) have no fixed order, so compare each column's words.
        for col in a.column_names:
            words = lambda t: sorted(w for v in t.column(col).to_pylist() for w in re.findall(r"[A-Za-z0-9_$*@.-]+", str(v)))  # noqa: E731
            if pa.types.is_string(a.schema.field(col).type) and not col.startswith("sample_"):  # a sample picks names in no fixed order
                assert words(a) == words(b), (f.name, col)


def test_a_bad_kind_stops_the_export_before_it_connects(tmp_path):
    with pytest.raises(ex.ExportConfigError, match="unknown mask kind"):
        ex.run_export(tmp_path / "out", mask=["colour"], connect_fn=lambda: (_ for _ in ()).throw(AssertionError("connected")))


def test_refresh_uses_the_setting(monkeypatch):
    from app.core import config as app_config
    monkeypatch.setattr(app_config, "load_settings", lambda: {"privacy": {"mask_fields": ["role", "warehouse"]}})
    assert ex.mask_kinds(None) == ["warehouse", "role"]
    assert ex.mask_kinds("") == [] and ex.mask_kinds("all") == list(masking.MASK_KINDS)
