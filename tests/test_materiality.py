"""tests/test_materiality.py

config/materiality.yml (app/core/materiality.py, app/core/config.py) -- a CRITICAL/WARN row whose
named column sits under the check's configured floor reads OK instead and carries below_floor=True,
so status_counts/worst-status/the sort order/a WARN+CRITICAL money sum all ignore it. NOT_ASSESSED
and OK rows are never touched by a floor. GET /api/finding exports the EFFECTIVE status as `status`
(the row's raw value survives as `status_raw`) plus a real `below_floor` column, both computed in
SQL (app/core/data.py's read_finding), never in per-row Python.

    TestFloorHelpers          pure app/core/materiality.py functions -- no database.
    TestFloorScalesWithWindow a USD floor is per 30 days; a count floor is never scaled.
    TestFloorAppliedInSql     status_expr/below_floor_expr run against a tiny in-memory table --
                              proves a CRITICAL/WARN row under the floor reads OK while a
                              NOT_ASSESSED row under the same column never does, and that
                              app/core/data.py's ORDER BY ranks on the floored status.
    TestConfigValidation      app/core/config._validate_materiality -- no database.
    TestApiFloor              checks that HAVE a floor (query_cache_coldstart, a count floor;
                              sf_wh_idle_minutes, a USD floor) against
                              tests/db_audit_test.duckdb: counts drop, rows carry
                              status/status_raw/below_floor, the aggregate sum excludes them. A check
                              with NO floor entry is asserted unchanged. Expected numbers are derived
                              from the raw table, never hard-coded.
    TestSeverityCap           a trend/chargeback report never reads worse than WARN.
"""
from __future__ import annotations

import sys
from pathlib import Path

import duckdb
import pytest
from fastapi.testclient import TestClient

ROOT = Path(__file__).resolve().parent.parent
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from app.api.app import app  # noqa: E402
from app.core import config as app_config  # noqa: E402
from app.core import data as app_core_data  # noqa: E402
from app.core import materiality  # noqa: E402
from app.core import registry  # noqa: E402

client = TestClient(app)

FLOOR_QUERY_ID = "sf_wh_idle_minutes"
FLOOR_COLUMN = "est_wasted_usd_list"
COUNT_FLOOR_QUERY_ID = "query_cache_coldstart"
COUNT_FLOOR_COLUMN = "query_count"
NO_FLOOR_QUERY_ID = "sf_wh_auto_suspend_tuning"
WINDOW = 30


def _raw(sql: str) -> list[tuple]:
    """A query straight on the test db, for numbers the API must reproduce."""
    con = duckdb.connect(str(ROOT / "tests" / "db_audit_test.duckdb"), read_only=True)
    try:
        return con.execute(sql).fetchall()
    finally:
        con.close()


# -------------------------------------------------------------------------------------------
# Pure helpers -- no database.
# -------------------------------------------------------------------------------------------


class TestFloorHelpers:
    def test_floor_for_known_and_unknown(self):
        floor = materiality.floor_for(FLOOR_QUERY_ID)
        assert floor is not None
        assert floor.column == FLOOR_COLUMN
        assert floor.min == 50
        assert materiality.floor_for(NO_FLOOR_QUERY_ID) is None

    def test_applicable_floor_requires_status_and_floor_column(self):
        # Both the floor's own column AND a "status" column must be present -- a stale config
        # entry, or a table that dropped its status band, is unaffected rather than erroring.
        assert materiality.applicable_floor(FLOOR_QUERY_ID, ["status", FLOOR_COLUMN]) is not None
        assert materiality.applicable_floor(FLOOR_QUERY_ID, [FLOOR_COLUMN]) is None  # no "status"
        assert materiality.applicable_floor(FLOOR_QUERY_ID, ["status"]) is None  # no floor column
        assert materiality.applicable_floor(NO_FLOOR_QUERY_ID, ["status", "est_usd_list"]) is None

    def test_status_expr_no_floor_is_bare_column(self):
        assert materiality.status_expr(NO_FLOOR_QUERY_ID, ["status", "est_usd_list"]) == 't."status"'

    def test_status_expr_missing_column_is_bare_column(self):
        # The table has `status` but not the floor's own column -- unaffected, never an error.
        assert materiality.status_expr(FLOOR_QUERY_ID, ["status"]) == 't."status"'

    def test_status_expr_applies_floor_only_to_critical_or_warn(self):
        expr = materiality.status_expr(FLOOR_QUERY_ID, ["status", FLOOR_COLUMN])
        assert expr == (
            f"CASE WHEN t.\"status\" IN ('CRITICAL', 'WARN') AND t.\"{FLOOR_COLUMN}\" < 50 "
            'THEN \'OK\' ELSE t."status" END'
        )

    def test_below_floor_expr(self):
        assert materiality.below_floor_expr(NO_FLOOR_QUERY_ID, ["status"]) is None
        expr = materiality.below_floor_expr(FLOOR_QUERY_ID, ["status", FLOOR_COLUMN])
        assert expr == f"t.\"status\" IN ('CRITICAL', 'WARN') AND t.\"{FLOOR_COLUMN}\" < 50"

    def test_floors_are_cached_until_the_file_changes(self, tmp_path, monkeypatch):
        cfg_dir = tmp_path / "config"
        cfg_dir.mkdir()
        monkeypatch.setenv("AUDIT_CONFIG_DIR", str(cfg_dir))
        app_config.save_materiality({FLOOR_QUERY_ID: {
            "column": FLOOR_COLUMN, "min": 10, "unit": "USD", "label": "x",
        }})
        first = materiality._floors()
        assert materiality._floors() is first  # same object -- no re-read/re-validate
        app_config.save_materiality({FLOOR_QUERY_ID: {
            "column": FLOOR_COLUMN, "min": 12345, "unit": "USD", "label": "x",
        }})
        second = materiality._floors()
        assert second is not first
        assert second[FLOOR_QUERY_ID].min == 12345


# -------------------------------------------------------------------------------------------
# A USD floor is per 30 days; status_expr reads the table's own window_days column.
# -------------------------------------------------------------------------------------------


class TestFloorScalesWithWindow:
    def _query_id(self, monkeypatch):
        query_id = "test_floor_scaled_query"
        floor = materiality.Floor(query_id=query_id, column="est_usd_list", min=50, unit="USD", label="x")
        monkeypatch.setattr(materiality, "_floors", lambda: {query_id: floor})
        return query_id

    def test_usd_floor_scales_down_at_a_shorter_window(self, monkeypatch):
        query_id = self._query_id(monkeypatch)
        con = duckdb.connect()
        con.execute(
            'CREATE TABLE f_test_floor_scaled_query '
            "(window_days INTEGER, status VARCHAR, est_usd_list DOUBLE, id VARCHAR)"
        )
        con.execute(
            "INSERT INTO f_test_floor_scaled_query VALUES "
            "(30, 'CRITICAL', 30.0, 'thirty_day'), "
            "(7, 'CRITICAL', 30.0, 'seven_day')"
        )
        cols = [("window_days", "INTEGER"), ("status", "VARCHAR"), ("est_usd_list", "DOUBLE"), ("id", "VARCHAR")]
        select_list = app_core_data._select_list(cols, query_id)
        rows = con.execute(
            f"SELECT {select_list} FROM f_test_floor_scaled_query t ORDER BY id"
        ).df().set_index("id")
        # $50/30d is $11.67 at 7d -- the same $30 row is immaterial at 30d but still flagged at 7d.
        assert rows.loc["thirty_day", "status"] == "OK"
        assert rows.loc["seven_day", "status"] == "CRITICAL"

    def test_non_usd_floor_is_never_scaled(self, monkeypatch):
        query_id = "test_floor_count_query"
        floor = materiality.Floor(query_id=query_id, column="scaling_events", min=20, unit="count", label="x")
        monkeypatch.setattr(materiality, "_floors", lambda: {query_id: floor})
        con = duckdb.connect()
        con.execute(
            'CREATE TABLE f_test_floor_count_query '
            "(window_days INTEGER, status VARCHAR, scaling_events INTEGER, id VARCHAR)"
        )
        con.execute("INSERT INTO f_test_floor_count_query VALUES (7, 'CRITICAL', 15, 'seven_day')")
        cols = [("window_days", "INTEGER"), ("status", "VARCHAR"), ("scaling_events", "INTEGER"), ("id", "VARCHAR")]
        select_list = app_core_data._select_list(cols, query_id)
        rows = con.execute(
            f"SELECT {select_list} FROM f_test_floor_count_query t ORDER BY id"
        ).df().set_index("id")
        # 15 < 20 at ANY window -- a count floor never scales with window_days.
        assert rows.loc["seven_day", "status"] == "OK"


class TestFloorAppliedInSql:
    @staticmethod
    def _table(con):
        con.execute(
            'CREATE TABLE f_test_floor_query '
            "(window_days INTEGER, status VARCHAR, est_wasted_usd_list DOUBLE, id VARCHAR)"
        )
        con.execute(
            "INSERT INTO f_test_floor_query VALUES "
            "(30, 'CRITICAL', 264.0, 'crit_above'), "
            "(30, 'CRITICAL', 5.0, 'crit_below'), "
            "(30, 'WARN', 2.0, 'warn_below'), "
            "(30, 'NOT_ASSESSED', 1.0, 'na_below'), "
            "(30, 'OK', 3.0, 'ok_below')"
        )

    def _query_id(self, monkeypatch):
        # A floor keyed on a query_id that will never collide with a real one, applied via a
        # monkeypatched materiality._floors() -- no config/materiality.yml round-trip needed.
        query_id = "test_floor_query"
        floor = materiality.Floor(
            query_id=query_id, column="est_wasted_usd_list", min=10, unit="USD", label="x",
        )
        monkeypatch.setattr(materiality, "_floors", lambda: {query_id: floor})
        return query_id

    def test_not_assessed_row_under_the_floor_stays_not_assessed(self, monkeypatch):
        query_id = self._query_id(monkeypatch)
        con = duckdb.connect()
        self._table(con)
        cols = [("window_days", "INTEGER"), ("status", "VARCHAR"),
                ("est_wasted_usd_list", "DOUBLE"), ("id", "VARCHAR")]
        select_list = app_core_data._select_list(cols, query_id)
        rows = con.execute(
            f"SELECT {select_list} FROM f_test_floor_query t ORDER BY id"
        ).df().set_index("id")
        # CRITICAL/WARN under the floor read OK and are flagged; NOT_ASSESSED/OK under the SAME
        # floor are untouched -- a floor can only ever move a row TOWARDS a healthier verdict it
        # already earned via a CRITICAL/WARN status, never manufacture one for an unjudged row.
        assert rows.loc["crit_above", "status"] == "CRITICAL"
        assert not rows.loc["crit_above", "below_floor"]
        assert rows.loc["crit_below", ["status", "status_raw", "below_floor"]].tolist() == ["OK", "CRITICAL", True]
        assert rows.loc["warn_below", ["status", "status_raw", "below_floor"]].tolist() == ["OK", "WARN", True]
        assert rows.loc["na_below", "status"] == "NOT_ASSESSED"
        assert not rows.loc["na_below", "below_floor"]
        assert rows.loc["ok_below", "status"] == "OK"
        assert not rows.loc["ok_below", "below_floor"]  # already OK -- the floor suppressed nothing

    def test_order_by_ranks_on_the_floored_status(self, monkeypatch):
        query_id = self._query_id(monkeypatch)
        con = duckdb.connect()
        self._table(con)
        col_names = ["window_days", "status", "est_wasted_usd_list", "id"]
        cols = [(c, "VARCHAR") for c in col_names]
        select_list = app_core_data._select_list(cols, query_id)
        order_sql = app_core_data._order_by_clause(query_id, col_names)
        ids = con.execute(
            f"SELECT {select_list} FROM f_test_floor_query t{order_sql}"
        ).df()["id"].tolist()
        # crit_below/warn_below now read OK (rank 3), so they sort AFTER na_below (NOT_ASSESSED,
        # rank 2) -- a raw CRITICAL/WARN rank would keep them ahead of it.
        assert ids.index("crit_above") < ids.index("na_below") < ids.index("crit_below")
        assert ids.index("na_below") < ids.index("warn_below")


# -------------------------------------------------------------------------------------------
# config/materiality.yml validation -- no database.
# -------------------------------------------------------------------------------------------


class TestConfigValidation:
    def test_repo_file_loads_clean(self):
        floors = app_config.load_materiality()
        assert floors[FLOOR_QUERY_ID] == {
            "column": FLOOR_COLUMN, "min": 50, "unit": "USD",
            "label": "$50 possible waste per 30 days",
        }
        assert COUNT_FLOOR_QUERY_ID in floors

    def test_every_floor_names_a_real_check_and_one_of_its_columns(self):
        for query_id, floor in app_config.load_materiality().items():
            spec = registry.by_id(query_id)
            assert f"AS {floor['column']}" in spec.body or f"as {floor['column']}" in spec.body.lower(), query_id

    def test_unknown_query_id_rejected(self):
        with pytest.raises(app_config.ConfigError, match="not in app.core.registry"):
            app_config._validate_materiality(
                {"this_query_id_does_not_exist": {
                    "column": "x", "min": 1, "unit": "USD", "label": "y",
                }}
            )

    def test_missing_field_rejected(self):
        with pytest.raises(app_config.ConfigError, match="missing field"):
            app_config._validate_materiality({FLOOR_QUERY_ID: {"column": FLOOR_COLUMN, "min": 50}})

    def test_unknown_field_rejected(self):
        with pytest.raises(app_config.ConfigError, match="unknown field"):
            app_config._validate_materiality(
                {FLOOR_QUERY_ID: {
                    "column": FLOOR_COLUMN, "min": 50, "unit": "USD", "label": "y", "extra": 1,
                }}
            )

    def test_non_positive_min_rejected(self):
        with pytest.raises(app_config.ConfigError, match="positive number"):
            app_config._validate_materiality(
                {FLOOR_QUERY_ID: {"column": FLOOR_COLUMN, "min": 0, "unit": "USD", "label": "y"}}
            )

    def test_bad_column_shape_rejected(self):
        with pytest.raises(app_config.ConfigError, match="column name"):
            app_config._validate_materiality(
                {FLOOR_QUERY_ID: {"column": "Not Valid", "min": 50, "unit": "USD", "label": "y"}}
            )


# -------------------------------------------------------------------------------------------
# API -- checks WITH a floor, and a control check with none. Expected numbers come from the raw
# table (_raw), so the API's own SQL is compared with an independent count.
# -------------------------------------------------------------------------------------------


def _floored_counts(query_id: str, column: str, floor_min: float, window: int = WINDOW) -> tuple[dict, int, float]:
    """(status counts after the floor, rows the floor hid, their summed `column`) from the raw table."""
    rows = _raw(f'SELECT status, "{column}" FROM findings."f_{query_id}" WHERE window_days = {window}')
    counts: dict[str, int] = {}
    hidden, hidden_sum = 0, 0.0
    for status, value in rows:
        if status in ("CRITICAL", "WARN") and value is not None and value < floor_min:
            status, hidden, hidden_sum = "OK", hidden + 1, hidden_sum + value
        counts[status] = counts.get(status, 0) + 1
    return counts, hidden, hidden_sum


def _findings_by_id(window: int = WINDOW) -> dict[str, dict]:
    return {r["query_id"]: r for r in client.get("/api/findings", params={"window": window}).json()["findings"]}


class TestApiFloor:
    def test_findings_status_counts_reflect_a_count_floor(self):
        floor = materiality.floor_for(COUNT_FLOOR_QUERY_ID)
        assert floor is not None and floor.unit == "count" and floor.column == COUNT_FLOOR_COLUMN
        expected, hidden, _ = _floored_counts(COUNT_FLOOR_QUERY_ID, COUNT_FLOOR_COLUMN, floor.min)
        assert hidden > 0, "the fake data must put a CRITICAL/WARN row under the floor"
        raw = dict(_raw(f'SELECT status, count(*) FROM findings."f_{COUNT_FLOOR_QUERY_ID}" '
                        f"WHERE window_days = {WINDOW} GROUP BY 1"))
        assert _findings_by_id()[COUNT_FLOOR_QUERY_ID]["status_counts"] == expected != raw

    def test_a_check_with_no_floor_reads_its_raw_counts(self):
        assert materiality.floor_for(NO_FLOOR_QUERY_ID) is None
        raw = dict(_raw(f'SELECT status, count(*) FROM findings."f_{NO_FLOOR_QUERY_ID}" '
                        f"WHERE window_days = {WINDOW} GROUP BY 1"))
        assert _findings_by_id()[NO_FLOOR_QUERY_ID]["status_counts"] == raw

    def test_finding_rows_carry_floored_status_status_raw_and_floor_object(self):
        floor = materiality.floor_for(COUNT_FLOOR_QUERY_ID)
        _, hidden, _ = _floored_counts(COUNT_FLOOR_QUERY_ID, COUNT_FLOOR_COLUMN, floor.min)
        body = client.get(f"/api/finding/{COUNT_FLOOR_QUERY_ID}", params={"window": WINDOW, "limit": 500}).json()
        assert body["outcome"] == "ok_rows"
        assert body["floor"] == {"column": COUNT_FLOOR_COLUMN, "min": floor.min, "unit": "count",
                                 "label": floor.label, "rows_below": hidden}
        below = [r for r in body["rows"] if r["below_floor"]]
        assert len(below) == hidden
        # A suppressed row reads OK while its raw verdict survives as status_raw.
        assert all(r["status"] == "OK" and r["status_raw"] in ("CRITICAL", "WARN") for r in below)
        assert all(r[COUNT_FLOOR_COLUMN] < floor.min for r in below)
        # An already-OK row under the floor had nothing to suppress: present, not flagged.
        already_ok_small = [r for r in body["rows"] if r["status_raw"] == "OK" and r[COUNT_FLOOR_COLUMN] < floor.min]
        assert already_ok_small and all(not r["below_floor"] for r in already_ok_small)

    def test_finding_no_floor_check_has_no_floor_object_or_flag(self):
        body = client.get(f"/api/finding/{NO_FLOOR_QUERY_ID}", params={"window": WINDOW, "limit": 5}).json()
        assert body["floor"] is None and body["rows"]
        assert all(r["below_floor"] is False for r in body["rows"])
        assert all("status_raw" not in r for r in body["rows"])

    def test_aggregate_sum_excludes_below_floor_rows(self):
        floor = materiality.floor_for(COUNT_FLOOR_QUERY_ID)
        material = _raw(
            f'SELECT count(*), sum("{COUNT_FLOOR_COLUMN}") FROM findings."f_{COUNT_FLOOR_QUERY_ID}" '
            f"WHERE window_days = {WINDOW} AND status IN ('CRITICAL', 'WARN') AND {COUNT_FLOOR_COLUMN} >= {floor.min}")[0]
        body = client.get(f"/api/finding/{COUNT_FLOOR_QUERY_ID}/aggregate", params={
            "window": WINDOW, "agg": "sum", "value": COUNT_FLOOR_COLUMN, "status": ["WARN", "CRITICAL"]}).json()
        assert body["matched_rows"] == material[0]
        assert body["total_value"] == pytest.approx(material[1])

    def test_below_floor_aggregate_sums_only_the_suppressed_rows(self):
        floor = materiality.floor_for(COUNT_FLOOR_QUERY_ID)
        _, hidden, hidden_sum = _floored_counts(COUNT_FLOOR_QUERY_ID, COUNT_FLOOR_COLUMN, floor.min)
        body = client.get(f"/api/finding/{COUNT_FLOOR_QUERY_ID}/aggregate", params={
            "window": WINDOW, "agg": "sum", "value": COUNT_FLOOR_COLUMN, "below_floor": "true"}).json()
        assert body["matched_rows"] == hidden > 0
        assert body["total_value"] == pytest.approx(hidden_sum)
        assert body["floor"] == {"min": floor.min, "unit": "count", "label": floor.label, "per_days": 30}

    def test_below_floor_aggregate_matches_nothing_without_a_floor(self):
        body = client.get(f"/api/finding/{NO_FLOOR_QUERY_ID}/aggregate",
                          params={"window": WINDOW, "agg": "count", "below_floor": "true"}).json()
        assert body["matched_rows"] == 0 and body["floor"] is None

    def test_aggregate_count_no_floor_check_unchanged(self):
        raw = _raw(f'SELECT count(*) FROM findings."f_{NO_FLOOR_QUERY_ID}" '
                   f"WHERE window_days = {WINDOW} AND status IN ('WARN', 'CRITICAL')")[0][0]
        body = client.get(f"/api/finding/{NO_FLOOR_QUERY_ID}/aggregate",
                          params={"window": WINDOW, "agg": "count", "status": ["WARN", "CRITICAL"]}).json()
        assert body["matched_rows"] == raw > 0

    def test_a_usd_floor_scales_with_the_window(self, tmp_path, monkeypatch):
        """A $1000-per-30-days floor is $1000 at 30d and about $233 at 7d: the same rows floor differently."""
        cfg = tmp_path / "config"
        cfg.mkdir()
        monkeypatch.setenv("AUDIT_CONFIG_DIR", str(cfg))
        app_config.save_materiality(
            {FLOOR_QUERY_ID: {"column": FLOOR_COLUMN, "min": 1000, "unit": "USD", "label": "x"}})
        hidden_by_window = {}
        for window in (7, 30):
            expected, hidden, _ = _floored_counts(FLOOR_QUERY_ID, FLOOR_COLUMN, 1000 * window / 30, window)
            assert hidden > 0
            assert _findings_by_id(window)[FLOOR_QUERY_ID]["status_counts"] == expected, window
            hidden_by_window[window] = hidden
        # 7d figures are a quarter of the 30d ones, but so is the floor: a flat $1000 would hide all six at 7d
        assert hidden_by_window[7] < 6


# -------------------------------------------------------------------------------------------
# Severity cap -- a trend/chargeback report never reads worse than WARN.
# -------------------------------------------------------------------------------------------

CAPPED_QUERY_ID = "cost_period_over_period"


class TestSeverityCap:
    def test_capped_report_has_no_critical_in_status_counts(self):
        assert materiality.severity_cap(CAPPED_QUERY_ID) == "WARN"
        assert materiality.severity_cap(NO_FLOOR_QUERY_ID) is None
        raw = dict(_raw(f'SELECT status, count(*) FROM findings."f_{CAPPED_QUERY_ID}" '
                        f"WHERE window_days = {WINDOW} GROUP BY 1"))
        assert raw.get("CRITICAL", 0) > 0, "the fake data must give the report a raw CRITICAL row"
        rows = _findings_by_id()
        row = rows[CAPPED_QUERY_ID]
        assert row["severity_cap"] == "WARN" and rows[NO_FLOOR_QUERY_ID]["severity_cap"] is None
        assert "CRITICAL" not in row["status_counts"]
        assert row["status_counts"]["WARN"] == raw["CRITICAL"]

    def test_capped_report_rows_keep_the_raw_status(self):
        body = client.get(f"/api/finding/{CAPPED_QUERY_ID}", params={"window": WINDOW, "limit": 500}).json()
        assert body["outcome"] == "ok_rows"
        assert not any(r["status"] == "CRITICAL" for r in body["rows"])
        raw_critical = [r for r in body["rows"] if r.get("status_raw") == "CRITICAL"]
        assert raw_critical and all(r["status"] == "WARN" for r in raw_critical)

    def test_every_capped_id_is_a_real_check(self):
        assert materiality.REPORT_IDS_CAPPED_AT_WARN <= {s.query_id for s in registry.load_registry()}
