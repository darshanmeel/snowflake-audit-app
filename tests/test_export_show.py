"""The export against a connector-shaped fake cursor: the SHOW path, the visibility probe, --validate
and the as-of cut-off. The cursor refuses fetch_arrow_all after a SHOW, as snowflake.connector does.
"""
from __future__ import annotations

import datetime as dt

import pyarrow as pa
import pytest

from tools import common
from tools import export_results as ex

NOW = dt.datetime(2026, 9, 21, 12, 0, tzinfo=dt.timezone.utc)
CHECK = "sf_wh_idle_minutes"  # its `-- pre:` is SHOW WAREHOUSES and it reads through RESULT_SCAN


class SnowflakeError(Exception):
    def __init__(self, message: str, errno: int):
        super().__init__(message)
        self.errno = errno


class ConnectorCursor:
    def __init__(self, deny: dict[str, int] | None = None):
        self.deny = deny or {}
        self.log: list[str] = []  # ("exec", sql) and ("fetch", sql) in order
        self.last = ""

    def execute(self, sql: str):
        body = ex._COMMENT_RE.sub("", sql).strip()
        self.log.append(("exec", body))
        for needle, errno in self.deny.items():
            if needle in body:
                if errno == 904:
                    raise SnowflakeError(f"SQL compilation error: error line 1 at position 7 invalid identifier '{needle}'", errno)
                raise SnowflakeError(f"SQL compilation error: {needle} does not exist or not authorized.", errno)
        self.last = body
        return self

    def fetch_arrow_all(self) -> pa.Table:
        self.log.append(("fetch", self.last))
        if self.last.upper().startswith("SHOW"):
            raise RuntimeError("fetch_arrow_all is not supported for SHOW results")
        if "CURRENT_ACCOUNT()" in self.last:
            return pa.table({"A": ["ABC12345"], "R": ["AWS_US_EAST_1"], "N": ["ACCT"]})
        if "missing_from_show" in self.last:
            return pa.table({"METERED": [4], "MISSING_FROM_SHOW": [1]})
        return pa.table({"WINDOW_DAYS": [30], "STATUS": ["OK"]})

    @property
    def description(self):
        return None


class Connection:
    def __init__(self, cursor: ConnectorCursor):
        self._cursor = cursor

    def cursor(self):
        return self._cursor

    def close(self):
        pass


def _export(tmp_path, cursor, **kw):
    return ex.run_export(tmp_path / "out", windows=30, only=[CHECK], credit_price=3.0,
                         connect_fn=lambda: Connection(cursor), now=NOW, **kw)


def test_show_is_executed_never_fetched(tmp_path):
    cur = ConnectorCursor()
    manifest = _export(tmp_path, cur)
    assert manifest["findings"][CHECK]["status"] == "ok"
    log = cur.log
    for i, (kind, sql) in enumerate(log):
        if kind == "fetch":
            assert not sql.upper().startswith("SHOW"), "a SHOW result was fetched"
    # The check's SELECT follows its SHOW with nothing in between, so LAST_QUERY_ID() is the SHOW.
    runs = [i for i, (k, s) in enumerate(log) if k == "exec" and "RESULT_SCAN" in s and "WAREHOUSE_METERING_HISTORY" in s
            and "missing_from_show" not in s]
    assert runs
    for i in runs:
        assert log[i - 1] == ("exec", "SHOW WAREHOUSES")


def test_visibility_probe_lands_in_the_manifest(tmp_path):
    manifest = _export(tmp_path, ConnectorCursor())
    vis = manifest["visibility"]
    assert vis["unreadable"] == {} and vis["failed_pre"] == {}
    assert vis["warehouses"] == {"metered": 4, "missing_from_show": 1}
    report = (tmp_path / "out" / "report.md").read_text(encoding="utf-8")
    assert "1 of 4 warehouses" in report


def test_unreadable_view_reads_not_assessed_and_the_check_is_not_run(tmp_path):
    cur = ConnectorCursor(deny={"ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY": 2003})
    manifest = _export(tmp_path, cur)
    entry = manifest["findings"][CHECK]
    assert entry["status"] == "not_assessed" and entry["not_assessed_reason"] == "role_cannot_see"
    assert "WAREHOUSE_METERING_HISTORY" in entry["unreadable"][0]
    assert "does not exist or not authorized" in entry["error"]
    assert "ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY" in manifest["visibility"]["unreadable"]
    assert not any("RESULT_SCAN" in s and k == "exec" for k, s in cur.log), "the blocked check still ran"
    assert not (tmp_path / "out" / "findings" / f"{CHECK}.parquet").exists()


def test_a_show_the_role_cannot_run_blocks_its_checks(tmp_path):
    cur = ConnectorCursor(deny={"SHOW WAREHOUSES": 3001})
    entry = _export(tmp_path, cur)["findings"][CHECK]
    assert entry["status"] == "not_assessed" and entry["unreadable"] == ["SHOW WAREHOUSES"]


def test_failed_check_records_the_error_code(tmp_path):
    cur = ConnectorCursor(deny={"credits_attributed_compute_queries": 904})
    entry = _export(tmp_path, cur)["findings"][CHECK]
    assert entry["status"] == "failed" and entry["error_code"] == "904"


def test_validate_runs_limit_0_and_records_codes(tmp_path):
    cur = ConnectorCursor(deny={"credits_attributed_compute_queries": 904})
    summary = ex.run_validate(tmp_path / "v", windows=7, only=[CHECK, "cost_by_hour_of_day"], credit_price=3.0,
                              connect_fn=lambda: Connection(cur), now=NOW)
    checks = summary["checks"]
    assert checks[CHECK]["status"] == "failed" and checks[CHECK]["error_code"] == "904"
    assert checks["cost_by_hour_of_day"]["status"] == "ok"
    selects = [s for k, s in cur.log if k == "exec" and "cost_by_hour_of_day" not in s and s.endswith("LIMIT 0")]
    assert selects, "no statement ended in LIMIT 0"
    assert not any(k == "fetch" and s.endswith("LIMIT 0") for k, s in cur.log)
    text = (tmp_path / "v" / "validate.md").read_text(encoding="utf-8")
    assert CHECK in text and "904" in text
    assert not (tmp_path / "v" / "findings").exists(), "validate must export nothing"


@pytest.mark.parametrize("now,include_today,expected", [
    (dt.datetime(2026, 9, 21, 12, 0, tzinfo=dt.timezone.utc), False, "2026-09-21"),
    (dt.datetime(2026, 9, 21, 3, 0, tzinfo=dt.timezone.utc), False, "2026-09-20"),  # yesterday is not yet complete
    (dt.datetime(2026, 9, 21, 3, 0, tzinfo=dt.timezone.utc), True, "2026-09-22"),
])
def test_as_of_is_the_first_day_after_the_last_complete_one(now, include_today, expected):
    assert ex._cutoff(now, include_today).isoformat() == expected


def test_manifest_names_both_dates(tmp_path):
    early = dt.datetime(2026, 9, 21, 3, 0, tzinfo=dt.timezone.utc)
    manifest = ex.run_export(tmp_path / "o", windows=30, only=[CHECK], credit_price=3.0,
                             connect_fn=lambda: Connection(ConnectorCursor()), now=early)
    assert manifest["as_of_date"] == "2026-09-20" and manifest["last_complete_day"] == "2026-09-19"
    assert manifest["export_date"] == "2026-09-21" and manifest["lag_hours"] == 8


def test_unflagged_rows_carry_no_waste_or_saving():
    table = pa.table({"status": ["OK", "WARN", "NOT_ASSESSED", "CRITICAL"],
                      "est_saving_usd_list": [5.0, 6.0, 7.0, 8.0], "est_compute_usd_list": [1.0] * 4})
    out = common.blank_unflagged_waste("sf_wh_oversized", table).to_pydict()
    assert out["est_saving_usd_list"] == [None, 6.0, None, 8.0]
    assert out["est_compute_usd_list"] == [1.0] * 4, "spend is not waste"
    context = pa.table({"status": ["OK", "WARN"], "est_idle_context_usd_list": [5.0, 6.0]})
    trend = common.blank_unflagged_waste("sf_cost_warehouse_idle_credits_daily", context).to_pydict()
    assert trend["est_idle_context_usd_list"] == [5.0, 6.0], "idle context is not waste, so no row is blanked"
