"""Every check in app/queries/checks runs against the fake Snowflake data (tools/sql_smoke.py).

Two runs share one fake account: strict (the fake follows the view catalog, so a check that reads a
column or type the catalog says is absent fails) and lenient (the fake also has those columns, so a
check gets past its first error). A failure outside the lists below is new breakage.
"""
from __future__ import annotations

import json

import duckdb
import pyarrow.parquet as pq
import pytest

from app.core import registry
from tools import sql_smoke

# Strict run: checks that read something the catalog says is wrong. Empty: every check follows the
# catalog. A check that must be parked goes here as {query_id: (error needle, why)}.
KNOWN_FAILURES: dict[str, tuple[str, str]] = {}

# Lenient run: what still fails once the catalog differences are papered over.
KNOWN_LENIENT_FAILURES: dict[str, str] = {}

# NOT_ASSESSED rows with no not_assessed_reason, which the number rules ask every such row to carry.
KNOWN_NO_REASON: dict[str, str] = {}

STATUSES = {"OK", "WARN", "CRITICAL", "NOT_ASSESSED"}
WINDOWS = {0, 7, 30, 90}


@pytest.fixture(scope="module")
def strict(tmp_path_factory):
    return sql_smoke.run_smoke(export_to=tmp_path_factory.mktemp("smoke") / "strict")


@pytest.fixture(scope="module")
def lenient(tmp_path_factory):
    return sql_smoke.run_smoke(export_to=tmp_path_factory.mktemp("smoke") / "lenient", lenient=True)


def _failed(result) -> set[str]:
    return {q for q, f in result["manifest"]["findings"].items() if f["status"] == "failed"}


def test_the_role_can_read_every_source_on_the_fake_account(strict):
    vis = strict["manifest"]["visibility"]
    assert vis["unreadable"] == {} and vis["failed_pre"] == {}
    assert not [q for q, f in strict["manifest"]["findings"].items() if f["status"] == "not_assessed"]


def test_no_check_exports_a_text_column_of_a_statement(strict):
    banned = ("query_text", "sample_query_text", "sample_statement_text", "sample_text", "policy_body")
    bad = {q: [c for c in f["columns"] if c in banned]
           for q, f in strict["manifest"]["findings"].items() if f["status"] != "failed"}
    assert not {q: c for q, c in bad.items() if c}


def test_error_text_columns_are_masked_in_sql(strict):
    """An error message can echo SQL literals or emails, so a check exporting one must mask it."""
    from pathlib import Path
    sql_dir = Path(registry.__file__).resolve().parents[1] / "queries" / "checks"
    bad = [q for q, f in strict["manifest"]["findings"].items()
           if f["status"] != "failed" and any(c.endswith("error_message") or c.endswith("copy_error")
                                              or c.startswith("error_message") for c in f["columns"] or [])
           and "REGEXP_REPLACE" not in (sql_dir / f"{q}.sql").read_text(encoding="utf-8")]
    assert not bad, bad


def test_every_check_is_run(strict):
    expected = {s.query_id for s in registry.load_registry()}
    assert set(strict["manifest"]["findings"]) == expected


def test_strict_failures_are_all_known(strict):
    failed = _failed(strict)
    new = sorted(failed - set(KNOWN_FAILURES))
    assert not new, "new SQL failures on the fake account: " + "; ".join(
        f"{q}: {strict['manifest']['findings'][q]['error'][:160]}" for q in new)


def test_known_failures_still_fail(strict):
    fixed = sorted(set(KNOWN_FAILURES) - _failed(strict))
    assert not fixed, f"fixed, remove from KNOWN_FAILURES: {fixed}"


def test_known_failures_fail_for_the_known_reason(strict):
    findings = strict["manifest"]["findings"]
    other = {q: findings[q]["error"][:200] for q, (needle, _) in KNOWN_FAILURES.items()
             if findings[q]["status"] == "failed" and needle not in (findings[q]["error"] or "").lower()}
    assert not other, f"known failures now failing for another reason: {other}"


def _duck(sql, shows=(), strict=True):
    con = duckdb.connect()
    con.execute("CREATE TABLE a (id BIGINT, n BIGINT, s VARCHAR)")
    con.execute("CREATE TABLE b (id BIGINT, n BIGINT)")
    con.execute("INSERT INTO a VALUES (1, 5, '7')")
    con.execute("INSERT INTO b VALUES (1, 6)")
    return con.execute(sql_smoke.to_duckdb(sql, list(shows), strict)).fetchall()


@pytest.mark.parametrize("sql", [
    "SELECT TRY_TO_NUMBER(n) FROM a",
    "SELECT TRY_TO_DOUBLE(n) FROM a",
    "SELECT TRY_TO_TIMESTAMP_LTZ(n) FROM a",
    "SELECT COALESCE(n, '') FROM a",
    "SELECT IFNULL(n, 'none') FROM a",
    "SELECT n FROM a JOIN b ON a.id = b.id",
])
def test_shims_keep_snowflake_errors(sql):
    with pytest.raises((duckdb.Error, ValueError)):
        _duck(sql)


def test_shims_accept_what_snowflake_accepts():
    assert _duck("SELECT TRY_TO_NUMBER(s), COALESCE(s, ''), TRY_TO_NUMBER('x') FROM a") == [(7, "7", None)]
    assert _duck("SELECT TRY_TO_NUMBER(n) FROM a", strict=False) == [(5,)]


def test_flatten_and_variant_reads_behave_like_snowflake():
    con = duckdb.connect()
    for m in sql_smoke.MACROS:
        con.execute(m)
    con.execute("""CREATE TABLE p AS SELECT 'IN (''ANALYST'', ''HR'')' AS body,
                   CAST('[{"policyId": 1}, {"columns": [{"policies": [{"policyId": 2}]}]}]' AS JSON) AS refs""")
    con.execute("CREATE TABLE t AS SELECT 'DB' AS d, 'TBL' AS BASE_TABLE_NAME, NULL::VARCHAR AS TABLE_NAME")

    def run(sql):
        return sorted(con.execute(sql_smoke.to_duckdb(sql, [])).fetchall())
    # recursive => TRUE reaches nested keys
    assert run("SELECT TRY_TO_NUMBER(TO_VARCHAR(f.value:policyId)) FROM p, "
               "LATERAL FLATTEN(input => p.refs, recursive => TRUE) f WHERE f.value:policyId IS NOT NULL") == [(1,), (2,)]
    # a flattened string reads without its JSON quotes
    assert run("SELECT TO_VARCHAR(f.value) FROM p, LATERAL FLATTEN(input => "
               "REGEXP_SUBSTR_ALL(p.body, '''([A-Z]+)''', 1, 1, 'e', 1)) f") == [("ANALYST",), ("HR",)]
    assert run("SELECT d || '.' || COALESCE(o:BASE_TABLE_NAME, o:TABLE_NAME)::VARCHAR "
               "FROM (SELECT OBJECT_CONSTRUCT(*) AS o, d FROM t)") == [("DB.TBL",)]


def test_result_scan_reads_only_a_show_just_run():
    show = "SELECT 1 AS x"
    assert _duck("SELECT * FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))", [show]) == [(1,)]
    # A SELECT ran after the SHOW: Snowflake would scan that SELECT, so the fake refuses.
    with pytest.raises(ValueError):
        sql_smoke.to_duckdb("SELECT * FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))", [show, None])
    with pytest.raises(ValueError):
        sql_smoke.to_duckdb("SELECT * FROM TABLE(RESULT_SCAN(LAST_QUERY_ID(-2)))", [show])


def test_lenient_failures_are_all_known(lenient):
    failed = _failed(lenient)
    new = sorted(failed - set(KNOWN_LENIENT_FAILURES))
    assert not new, "new SQL failures once the catalog differences are allowed: " + "; ".join(
        f"{q}: {lenient['manifest']['findings'][q]['error'][:160]}" for q in new)
    assert failed == set(KNOWN_LENIENT_FAILURES)


# The base account's only broad grants go to PUBLIC, which sf_gov_public_role_grants owns.
EMPTY_ON_BASE = {"access_broad_grants",
                 # Sources the frozen base account has no rows for (agents_info, SNOWFLAKE.LOCAL, lifecycle
                 # policy runs, listing time, AI failed-query credits, dynamic table readers); the demo has rows.
                 "sf_ai_credits_on_failed_queries", "sf_dt_downstream_orphans", "sf_gov_ai_agent_data_access",
                 "sf_gov_dmf_expectation_failures", "sf_load_copy_listing_overhead",
                 "sf_storage_lifecycle_policy_failures"}


def test_fake_data_reaches_every_check(lenient):
    empty = sorted(q for q, f in lenient["manifest"]["findings"].items() if f["status"] == "empty" and q not in EMPTY_ON_BASE)
    assert not empty, f"no rows from the fake account: {empty}"


def test_fake_data_reaches_warn_and_critical_paths(lenient):
    with_findings = [q for q, counts in lenient["status_counts"].items() if counts.get("WARN") or counts.get("CRITICAL")]
    assert len(with_findings) >= 100, f"only {len(with_findings)} checks show a WARN or CRITICAL row"


@pytest.mark.parametrize("run", ["strict", "lenient"])
def test_output_has_the_columns_the_app_needs(run, request):
    result = request.getfixturevalue(run)
    problems = []
    for qid, entry in result["manifest"]["findings"].items():
        if entry["status"] == "failed":
            continue
        cols = entry["columns"]
        if "window_days" not in cols:
            problems.append(f"{qid}: no window_days")
        if registry.by_id(qid).is_finding and "status" not in cols:
            problems.append(f"{qid}: header says it is a finding but there is no status column")
    assert not problems, problems


@pytest.mark.parametrize("run", ["strict", "lenient"])
def test_status_and_window_values_are_valid(run, request):
    result = request.getfixturevalue(run)
    folder = result["export_dir"] / "findings"
    problems = []
    for qid, entry in result["manifest"]["findings"].items():
        if entry["status"] == "failed":
            continue
        table = pq.read_table(folder / f"{qid}.parquet")
        spec = registry.by_id(qid)
        windows = set(table.column("window_days").to_pylist())
        allowed = {7, 30, 90} if spec.windowed else {0}
        if not windows <= allowed:
            problems.append(f"{qid}: window_days {sorted(windows)} not in {sorted(allowed)}")
        if "status" in table.column_names:
            bad = set(table.column("status").to_pylist()) - STATUSES
            if bad:
                problems.append(f"{qid}: status values {sorted(map(str, bad))}")
    assert not problems, problems


def test_not_assessed_rows_say_why(lenient):
    folder = lenient["export_dir"] / "findings"
    missing = []
    for qid, entry in lenient["manifest"]["findings"].items():
        if entry["status"] == "failed" or not entry["not_assessed_rows"]:
            continue
        table = pq.read_table(folder / f"{qid}.parquet").to_pylist()
        if any(r["status"] == "NOT_ASSESSED" and not r.get("not_assessed_reason") for r in table):
            missing.append(qid)
    assert set(missing) == set(KNOWN_NO_REASON), f"NOT_ASSESSED rows with no not_assessed_reason: {missing}"


def test_export_folder_has_the_export_results_layout(strict):
    folder = strict["export_dir"]
    manifest = json.loads((folder / "manifest.json").read_text(encoding="utf-8"))
    for key in ("as_of", "as_of_date", "includes_today", "windows", "pricing", "account", "findings"):
        assert key in manifest, key
    assert manifest["as_of_date"] == "2026-09-21" and manifest["includes_today"] is False
    assert manifest["windows"] == [7, 30, 90]
    assert manifest["pricing"]["credit_price_usd"] == pytest.approx(3.0, abs=0.01)
    assert {p.stem for p in (folder / "dims").glob("*.parquet")} == {"dim_account", "dim_task", "dim_warehouse", "dim_user", "dim_database"}
    ok = [q for q, f in manifest["findings"].items() if f["status"] == "ok"]
    assert all((folder / "findings" / f"{q}.parquet").exists() for q in ok)
